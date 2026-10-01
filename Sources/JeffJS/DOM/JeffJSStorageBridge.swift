// JeffJSStorageBridge.swift
// JeffJS Storage Bridge — `__nativeStorage` behind localStorage/sessionStorage.
//
// Registers `__nativeStorage` on the global object with methods
//   get, set, remove, clear, keys, length, key
// consumed by the JS-side localStorage/sessionStorage shims (the host's
// polyfill or `JeffJSPolyfills.fetchAndXHRPolyfill`).
//
// Web Storage (HTML §12.2), like Safari:
// - `local_storage` (and the legacy `cookies` / `chrome_storage_*` namespaces)
//   live in a host-supplied `JeffJSWebStorageStore` keyed by the document's
//   origin (`JeffJSStorageBridge.defaultStore`: in memory unless the host
//   installs a persistent one — React Natively's is file-backed per origin).
// - `session_storage` is in memory per (top-level browsing context, origin).
// - A write past the origin's quota throws a `QuotaExceededError` DOMException
//   and changes nothing.
// - A change fires a `storage` event (a task) at every *other* live document
//   of the origin that shares the area (same store; for sessionStorage the
//   same browsing context), with key/oldValue/newValue/url/storageArea.
// Never `UserDefaults` (see JeffJSWebStorage.swift).

import Foundation

// MARK: - JeffJSStorageBridge

@MainActor
final class JeffJSStorageBridge {

    // MARK: - Shared state

    /// The persistent store new bridges use (the host replaces it at startup).
    static var defaultStore: any JeffJSWebStorageStore = JeffJSMemoryWebStorage()
    /// sessionStorage areas, keyed by `<browsing context> <origin>`. They live
    /// for the process (a relaunch starts a new session, like a new tab).
    nonisolated static let sessionStore = JeffJSMemoryWebStorage(quotaBytes: JeffJSConfig.storageSessionQuotaBytes)

    private final class WeakBridge { weak var bridge: JeffJSStorageBridge?; init(_ b: JeffJSStorageBridge) { bridge = b } }
    /// Live bridges, for `storage` events.
    private static var live: [WeakBridge] = []

    nonisolated static let debug = JeffJSConfig.storageDebug

    // MARK: - State

    /// The document's serialized origin (`JeffJSWebStorageOrigin.key(for:)`).
    let origin: String
    /// The top-level browsing context the document belongs to.
    let browsingContext: String
    /// `StorageEvent.url` of the events this document's changes fire.
    var documentURL: String
    let store: any JeffJSWebStorageStore
    private weak var ctx: JeffJSContext?

    private var sessionOrigin: String { "\(browsingContext) \(origin)" }
    private func isSession(_ namespace: String) -> Bool { namespace == "session_storage" || namespace == "session" }

    // MARK: - Init

    /// - Parameters:
    ///   - origin: the document's origin, `JeffJSWebStorageOrigin.key(for:)`.
    ///   - documentURL: the document's URL (`StorageEvent.url`).
    ///   - browsingContext: the top-level browsing context (sessionStorage).
    ///   - store: the persistent store; nil = `defaultStore`.
    init(origin: String, documentURL: String = "", browsingContext: String = "top",
         store: (any JeffJSWebStorageStore)? = nil) {
        self.origin = origin
        self.documentURL = documentURL
        self.browsingContext = browsingContext
        self.store = store ?? Self.defaultStore
    }

    /// The document at `url` (its origin keys the storage).
    convenience init(url: URL, browsingContext: String = "top", store: (any JeffJSWebStorageStore)? = nil) {
        self.init(origin: JeffJSWebStorageOrigin.key(for: url), documentURL: url.absoluteString,
                  browsingContext: browsingContext, store: store)
    }

    /// Legacy: a storage key that is not an origin (the old root-domain scope).
    convenience init(scope: String) {
        self.init(origin: scope)
    }

    // MARK: - Registration

    /// Registers `__nativeStorage` on the JeffJS context's global object.
    func register(on ctx: JeffJSContext) {
        self.ctx = ctx
        Self.live.removeAll { $0.bridge == nil }
        Self.live.append(WeakBridge(self))

        let global = ctx.getGlobalObject()
        defer { global.freeValue() }
        let storageObj = ctx.newPlainObject()

        // get(namespace, key) -> string | null
        // A missing key MUST be JS `null` (not ""), matching JavaScriptCore and
        // the Web Storage spec: `JSON.parse(localStorage.getItem(k))` on a
        // missing key must yield null. A stored empty string returns "".
        ctx.setPropertyFunc(obj: storageObj, name: "get", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.null }
            let ns = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            let key = self.extractString(ctx: ctx, args: args, index: 1) ?? ""
            guard let value = self.get(ns, key) else { return JeffJSValue.null }
            return ctx.newStringValue(value)
        }, length: 2)

        // set(namespace, key, value) -> undefined; throws QuotaExceededError.
        ctx.setPropertyFunc(obj: storageObj, name: "set", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            let ns = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            let key = self.extractString(ctx: ctx, args: args, index: 1) ?? ""
            let val = self.extractString(ctx: ctx, args: args, index: 2) ?? ""
            do {
                try self.set(ns, key, val)
            } catch {
                return Self.throwQuotaExceeded(ctx: ctx)
            }
            return JeffJSValue.undefined
        }, length: 3)

        // remove(namespace, key) -> undefined
        ctx.setPropertyFunc(obj: storageObj, name: "remove", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            let ns = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            let key = self.extractString(ctx: ctx, args: args, index: 1) ?? ""
            self.remove(ns, key)
            return JeffJSValue.undefined
        }, length: 2)

        // clear(namespace) -> undefined
        ctx.setPropertyFunc(obj: storageObj, name: "clear", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            let ns = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            self.clear(ns)
            return JeffJSValue.undefined
        }, length: 1)

        // keys(namespace) -> array of strings, in the area's order
        ctx.setPropertyFunc(obj: storageObj, name: "keys", fn: { [weak self] ctx, _, args in
            guard let self else { return ctx.newArray() }
            let ns = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            let keyList = self.keys(ns)
            let arr = ctx.newArray()
            for (i, k) in keyList.enumerated() {
                _ = ctx.setPropertyUint32(obj: arr, index: UInt32(i), value: ctx.newStringValue(k))
            }
            _ = ctx.setPropertyStr(obj: arr, name: "length", value: .newInt32(Int32(keyList.count)))
            return arr
        }, length: 1)

        // length(namespace) -> number of items
        ctx.setPropertyFunc(obj: storageObj, name: "length", fn: { [weak self] ctx, _, args in
            guard let self else { return .newInt32(0) }
            let ns = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            return .newInt32(Int32(clamping: self.count(ns)))
        }, length: 1)

        // key(namespace, index) -> string | null
        ctx.setPropertyFunc(obj: storageObj, name: "key", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.null }
            let ns = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            // WebIDL `unsigned long`: ToNumber, NaN/±Infinity → 0, truncate, modulo 2^32.
            var n = args.count > 1 ? (ctx.toSwiftString(args[1]).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? 0) : 0
            if !n.isFinite { n = 0 }
            n = n.rounded(.towardZero).truncatingRemainder(dividingBy: 4294967296)
            if n < 0 { n += 4294967296 }
            guard n < Double(Int32.max), let k = self.key(ns, Int(n)) else { return JeffJSValue.null }
            return ctx.newStringValue(k)
        }, length: 2)

        _ = ctx.setPropertyStr(obj: global, name: "__nativeStorage", value: storageObj)

        // __nativeStorage.dispatch(area, key, oldValue, newValue, url): fires
        // the `storage` event at this realm's window (called from a task).
        let installed = ctx.eval(input: Self.dispatcherSource, filename: "<storage-events>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        if installed.isException {
            let exc = ctx.getException()
            exc.freeValue()
        }
        installed.freeValue()
    }

    private static let dispatcherSource = #"""
    (function (ns) {
      if (!ns || typeof ns !== 'object') return;
      Object.defineProperty(ns, 'dispatch', { configurable: true, writable: true, value: function (area, key, oldValue, newValue, url) {
        var w = typeof window !== 'undefined' ? window : globalThis;
        var sa = null;
        try { sa = area === 'session_storage' ? w.sessionStorage : w.localStorage; } catch (e) {}
        var init = { key: key, oldValue: oldValue, newValue: newValue, url: url, storageArea: sa }, ev = null;
        try { if (typeof w.StorageEvent === 'function') ev = new w.StorageEvent('storage', init); } catch (e) { ev = null; }
        if (!ev && typeof w.Event === 'function') {
          ev = new w.Event('storage');
          for (var k in init) { try { Object.defineProperty(ev, k, { value: init[k], enumerable: true, configurable: true }); } catch (e) {} }
        }
        if (ev && typeof w.dispatchEvent === 'function') w.dispatchEvent(ev);
      } });
    })(globalThis.__nativeStorage);
    """#

    // MARK: - Storage Operations

    func get(_ namespace: String, _ key: String) -> String? {
        if isSession(namespace) { return Self.sessionStore.getItem(key, origin: sessionOrigin, area: "session_storage") }
        return store.getItem(key, origin: origin, area: namespace)
    }

    /// Stores `value` and fires the `storage` events; throws
    /// `JeffJSWebStorageError.quotaExceeded` (nothing changed) past the quota.
    func set(_ namespace: String, _ key: String, _ value: String) throws {
        let old: String?
        do {
            if isSession(namespace) {
                old = try Self.sessionStore.setItem(value, forKey: key, origin: sessionOrigin, area: "session_storage")
            } else {
                old = try store.setItem(value, forKey: key, origin: origin, area: namespace)
            }
        } catch {
            if case JeffJSWebStorageError.quotaExceeded(let needed, let quota) = error {
                print("[WebStorage] quota exceeded origin=\(origin) area=\(namespace) key=\(key.prefix(60)) needed=\(needed) quota=\(quota)")
            }
            throw error
        }
        if Self.debug {
            print("[WebStorage] set origin=\(origin) area=\(namespace) key=\(key.prefix(60)) len=\(value.utf16.count)")
        }
        if old != value { notifyOthers(namespace, key: key, oldValue: old, newValue: value) }
    }

    func remove(_ namespace: String, _ key: String) {
        let old: String?
        if isSession(namespace) {
            old = Self.sessionStore.removeItem(key, origin: sessionOrigin, area: "session_storage")
        } else {
            old = store.removeItem(key, origin: origin, area: namespace)
        }
        if old != nil { notifyOthers(namespace, key: key, oldValue: old, newValue: nil) }
    }

    func clear(_ namespace: String) {
        let changed: Bool
        if isSession(namespace) {
            changed = Self.sessionStore.clear(origin: sessionOrigin, area: "session_storage")
        } else {
            changed = store.clear(origin: origin, area: namespace)
        }
        if changed { notifyOthers(namespace, key: nil, oldValue: nil, newValue: nil) }
    }

    func keys(_ namespace: String) -> [String] {
        if isSession(namespace) { return Self.sessionStore.keys(origin: sessionOrigin, area: "session_storage") }
        return store.keys(origin: origin, area: namespace)
    }

    func count(_ namespace: String) -> Int {
        if isSession(namespace) { return Self.sessionStore.count(origin: sessionOrigin, area: "session_storage") }
        return store.count(origin: origin, area: namespace)
    }

    func key(_ namespace: String, _ index: Int) -> String? {
        if isSession(namespace) { return Self.sessionStore.key(at: index, origin: sessionOrigin, area: "session_storage") }
        return store.key(at: index, origin: origin, area: namespace)
    }

    // MARK: - Legacy cookie namespace (`RN_COOKIES_LEGACY=1` hosts)

    func cookieString() -> String {
        let names = keys("cookies")
        return names.compactMap { name in
            guard let value = get("cookies", name) else { return nil }
            return "\(name)=\(value)"
        }.joined(separator: "; ")
    }

    func setCookieString(_ cookieInput: String) {
        let trimmed = cookieInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let firstPart = trimmed.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        guard let eq = firstPart.firstIndex(of: "=") else { return }
        let name = String(firstPart[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(firstPart[firstPart.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        try? set("cookies", name, value)
    }

    // MARK: - Storage events

    /// HTML §12.2.1 "broadcast": every other document whose Storage object
    /// shares the area gets a `storage` event in a task.
    private func notifyOthers(_ namespace: String, key: String?, oldValue: String?, newValue: String?) {
        guard namespace == "local_storage" || isSession(namespace) else { return }
        let session = isSession(namespace)
        let targets = Self.live.compactMap { $0.bridge }.filter { other in
            other !== self && other.ctx != nil && other.origin == origin
                && (session ? other.browsingContext == browsingContext : other.store === store)
        }
        guard !targets.isEmpty else { return }
        let area = session ? "session_storage" : "local_storage"
        let url = documentURL
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for t in targets { t.deliver(area: area, key: key, oldValue: oldValue, newValue: newValue, url: url) }
            }
        }
    }

    private func deliver(area: String, key: String?, oldValue: String?, newValue: String?, url: String) {
        guard let ctx else { return }
        let global = ctx.getGlobalObject()
        defer { global.freeValue() }
        let ns = ctx.getPropertyStr(obj: global, name: "__nativeStorage")
        defer { ns.freeValue() }
        guard ns.isObject else { return }
        let fn = ctx.getPropertyStr(obj: ns, name: "dispatch")
        defer { fn.freeValue() }
        guard fn.isFunction else { return }
        let args = [ctx.newStringValue(area),
                    key.map { ctx.newStringValue($0) } ?? JeffJSValue.null,
                    oldValue.map { ctx.newStringValue($0) } ?? JeffJSValue.null,
                    newValue.map { ctx.newStringValue($0) } ?? JeffJSValue.null,
                    ctx.newStringValue(url)]
        let result = ctx.callRetained(fn, this: JeffJSValue.undefined, args: args)
        if result.isException {
            let exc = ctx.getException()
            exc.freeValue()
        }
        result.freeValue()
        for a in args { a.freeValue() }
        _ = ctx.rt.executePendingJobs()
    }

    // MARK: - Helpers

    /// `QuotaExceededError` DOMException (legacy code 22), or an Error named
    /// so when the realm has no DOMException yet.
    private static func throwQuotaExceeded(ctx: JeffJSContext) -> JeffJSValue {
        let message = "The quota has been exceeded."
        let global = ctx.getGlobalObject()
        let ctor = ctx.getPropertyStr(obj: global, name: "DOMException")
        global.freeValue()
        defer { ctor.freeValue() }
        if ctor.isFunction {
            let msg = ctx.newStringValue(message)
            let nm = ctx.newStringValue("QuotaExceededError")
            let err = ctx.callConstructor(ctor, args: [msg, nm])
            msg.freeValue()
            nm.freeValue()
            if err.isException { return err }
            return ctx.throwValue(err)
        }
        let r = ctx.eval(input: "(function(){ var e = new Error('\(message)'); e.name = 'QuotaExceededError'; e.code = 22; return e; })()",
                         filename: "<storage-quota>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        if r.isException { return r }
        return ctx.throwValue(r)
    }

    private func extractString(ctx: JeffJSContext, args: [JeffJSValue], index: Int) -> String? {
        guard index < args.count else { return nil }
        return ctx.toSwiftString(args[index])
    }
}
