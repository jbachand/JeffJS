// JeffJSStorageBridge.swift
// JeffJS Storage Bridge — Registers localStorage/sessionStorage on a JeffJS context.
//
// Port of JSStorageBridge (JSScriptEngine.swift) from JavaScriptCore to JeffJS.
// Uses the same UserDefaults-based storage with domain scoping.
//
// Registers `__nativeStorage` on the global object with methods:
//   get, set, remove, clear, keys
// These are consumed by the JS-side localStorage/sessionStorage shims.

import Foundation

// MARK: - JeffJSStorageBridge

/// Bridges browser localStorage/sessionStorage to UserDefaults via JeffJS native functions.
///
/// Usage:
/// ```swift
/// let bridge = JeffJSStorageBridge(scope: "example.com")
/// bridge.register(on: ctx)
/// ```
@MainActor
final class JeffJSStorageBridge {

    // MARK: - State

    private let scope: String
    private let defaults = UserDefaults.standard

    // MARK: - Init

    init(scope: String) {
        self.scope = scope
    }

    // MARK: - Registration

    /// Registers `__nativeStorage` on the JeffJS context's global object.
    func register(on ctx: JeffJSContext) {
        let global = ctx.getGlobalObject()
        let storageObj = ctx.newPlainObject()

        // get(namespace, key) -> string | ""
        ctx.setPropertyFunc(obj: storageObj, name: "get", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return ctx.newStringValue("") }
            let ns = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            let key = self.extractString(ctx: ctx, args: args, index: 1) ?? ""
            let value = self.get(ns, key) ?? ""
            return ctx.newStringValue(value)
        }, length: 2)

        // set(namespace, key, value) -> undefined
        ctx.setPropertyFunc(obj: storageObj, name: "set", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            let ns = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            let key = self.extractString(ctx: ctx, args: args, index: 1) ?? ""
            let val = self.extractString(ctx: ctx, args: args, index: 2) ?? ""
            self.set(ns, key, val)
            return JeffJSValue.undefined
        }, length: 3)

        // remove(namespace, key) -> undefined
        ctx.setPropertyFunc(obj: storageObj, name: "remove", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            let ns = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            let key = self.extractString(ctx: ctx, args: args, index: 1) ?? ""
            self.remove(ns, key)
            return JeffJSValue.undefined
        }, length: 2)

        // clear(namespace) -> undefined
        ctx.setPropertyFunc(obj: storageObj, name: "clear", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            let ns = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            self.clear(ns)
            return JeffJSValue.undefined
        }, length: 1)

        // keys(namespace) -> array of strings
        ctx.setPropertyFunc(obj: storageObj, name: "keys", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return ctx.newArray() }
            let ns = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            let keyList = self.keys(ns)
            let arr = ctx.newArray()
            for (i, k) in keyList.enumerated() {
                _ = ctx.setPropertyUint32(obj: arr, index: UInt32(i), value: ctx.newStringValue(k))
            }
            // Set length explicitly
            _ = ctx.setPropertyStr(obj: arr, name: "length", value: .newInt32(Int32(keyList.count)))
            return arr
        }, length: 1)

        _ = ctx.setPropertyStr(obj: global, name: "__nativeStorage", value: storageObj)
    }

    // MARK: - Storage Operations (mirrors JSStorageBridge)

    func get(_ namespace: String, _ key: String) -> String? {
        defaults.string(forKey: storageKey(namespace: namespace, key: key))
    }

    func set(_ namespace: String, _ key: String, _ value: String) {
        defaults.set(value, forKey: storageKey(namespace: namespace, key: key))
    }

    func remove(_ namespace: String, _ key: String) {
        defaults.removeObject(forKey: storageKey(namespace: namespace, key: key))
    }

    func clear(_ namespace: String) {
        let prefix = "\(scope).\(namespace)."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    func keys(_ namespace: String) -> [String] {
        let prefix = "\(scope).\(namespace)."
        return defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .sorted()
    }

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
        set("cookies", name, value)
    }

    // MARK: - Helpers

    private func storageKey(namespace: String, key: String) -> String {
        "\(scope).\(namespace).\(key)"
    }

    private func extractString(ctx: JeffJSContext, args: [JeffJSValue], index: Int) -> String? {
        guard index < args.count else { return nil }
        return ctx.toSwiftString(args[index])
    }
}
