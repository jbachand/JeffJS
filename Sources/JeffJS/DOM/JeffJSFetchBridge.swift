// JeffJSFetchBridge.swift
// JeffJS Fetch Bridge — Registers native fetch APIs on a JeffJS context.
//
// This bridges URLSession networking to JavaScript running in JeffJS, providing:
//   __nativeFetch.fetch(url, opts, callback)
//   __nativeFetch.startFetch(requestJSON, callback)
//   __nativeFetch.startFetchDirect(url, optsJSONOrObject, callback)   -> requestID
//   __nativeFetch.startFetchObject(url, optsObject, callback)         -> requestID
//   __nativeFetch.cancelFetch(id)
//   __nativeFetch.abortSignal(signalId)
//   __nativeFetch.decodeBytes(arrayBuffer, charset?)                  -> String
//   __nativeFetch.encodeUTF8(string)                                  -> ArrayBuffer
//   __nativeFetch.setEnforceCORS(bool) / setOrigin(url) / getOrigin()
//
// The callback is invoked as:
//   callback(requestID, payloadJSON | null, errorText | null,
//            payloadObject | null, errorName | null)
//
// `payloadObject` (new, preferred) is a native object:
//   { ok, status, statusText, url, redirected, type, headers,
//     bodyBytes: ArrayBuffer, byteLength, mimeType, charset,
//     bodyText(): string, body: string (legacy, "" for binary) }
//
// `payloadJSON` keeps the historical string shape
//   { ok, status, statusText, url, redirected, type, headers, byteLength, body }
// so existing JS glue keeps working while it migrates to bytes.
//
// Request options (object form — the JSON-string form still works and adds
// `bodyBase64` for bytes):
//   { method, headers: { name: value } | [[name, value], ...],
//     body: String | ArrayBuffer | TypedArray | DataView
//           | { __blobParts: [...], type } | { parts: [...], type, size }
//           | { __formEntries: [{ name, value, filename, type }] } | { _entries: [...] }
//           | { __urlSearchParams: "a=b&c=d" },
//     credentials: "omit" | "same-origin" (default) | "include",
//     mode: "cors" (default) | "no-cors" | "same-origin",
//     cache: "default" | "no-store" | "reload" | "no-cache" | "force-cache" | "only-if-cached",
//     redirect: "follow" (default) | "manual" | "error",
//     signalId: String,          // pair with __nativeFetch.abortSignal(id)
//     responseType: String }     // XHR hint, echoed back untouched
//
// XHR responseType mapping (the JS side picks the field it needs):
//   ""/"text"     -> payload.bodyText()
//   "arraybuffer" -> payload.bodyBytes
//   "blob"        -> new Blob([payload.bodyBytes], { type: payload.mimeType })
//   "json"        -> JSON.parse(payload.bodyText())
//   "document"    -> payload.bodyText() (the host app parses it)
//
// Follows the same patterns as JeffJSDOMBridge for native function registration.

import Foundation

// MARK: - Network Log Entry

/// Log entry for fetch request diagnostics.
public struct JeffJSNetworkLogEntry: Sendable {
    public let method: String
    public let url: String
    public let statusCode: Int
    public let statusText: String
    public let durationMs: Double
    public let responseSize: Int
    public let error: String?

    public init(method: String, url: String, statusCode: Int, statusText: String,
                durationMs: Double, responseSize: Int, error: String?) {
        self.method = method
        self.url = url
        self.statusCode = statusCode
        self.statusText = statusText
        self.durationMs = durationMs
        self.responseSize = responseSize
        self.error = error
    }
}

// MARK: - Errors

/// A fetch failure with a DOM-style `name` so JS can build the right error
/// object (`TypeError`, `AbortError`, ...).
struct JeffJSFetchFailure: LocalizedError {
    let name: String
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Request / response value types

/// A fully resolved request, built on the main actor from JS values so the
/// networking half never touches the JS heap.
struct JeffJSFetchSpec {
    var urlString: String
    var method: String = "GET"
    var headers: [(name: String, value: String)] = []
    var body: [UInt8]? = nil
    var bodyContentType: String? = nil
    var credentials: String = "same-origin"   // omit | same-origin | include
    var mode: String = "cors"                 // cors | no-cors | same-origin | navigate
    var cache: String = "default"
    var redirect: String = "follow"           // follow | manual | error
    var signalID: String? = nil
    var responseType: String = "text"
    var cookieHeader: String? = nil           // from the bridge's cookie store
}

/// The network result, before it is turned into JS values.
struct JeffJSFetchResult {
    var status: Int
    var statusText: String
    var url: String
    var redirected: Bool
    var type: String                 // basic | cors | opaque | opaqueredirect
    var headers: [String: String]    // lowercase keys, set-cookie joined with "\n"
    var bytes: [UInt8]
    var mimeType: String
    var charset: String?
}

// MARK: - Redirect delegate

/// Implements `redirect: follow | manual | error` and records whether any
/// redirect happened so the response can report `redirected` / final `url`.
final class JeffJSRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let mode: String
    private(set) var didRedirect = false
    private(set) var blockedRedirect: HTTPURLResponse?
    private let lock = NSLock()

    init(mode: String) { self.mode = mode }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        if mode == "follow" {
            didRedirect = true
            lock.unlock()
            completionHandler(request)
        } else {
            blockedRedirect = response
            lock.unlock()
            completionHandler(nil)   // URLSession returns the 3xx itself
        }
    }

    var redirected: Bool { lock.lock(); defer { lock.unlock() }; return didRedirect }
    var blocked: HTTPURLResponse? { lock.lock(); defer { lock.unlock() }; return blockedRedirect }
}

// MARK: - JeffJSFetchBridge

/// Registers fetch APIs on a JeffJS context so that JavaScript can make HTTP
/// requests through the native networking stack.
@MainActor
final class JeffJSFetchBridge {

    // MARK: - State

    private let userAgent: String
    private weak var ctx: JeffJSContext?
    private var nextRequestID: Int = 1
    private var activeTasks: [Int: Task<Void, Never>] = [:]
    /// Stored JS callback references keyed by request ID so they stay alive
    /// for the duration of async operations.
    private var storedCallbacks: [Int: JeffJSValue] = [:]
    /// requestID -> AbortSignal id passed by JS (`opts.signalId`).
    private var requestSignals: [Int: String] = [:]
    /// Network log callback for diagnostics.
    var onNetworkLog: (@MainActor @Sendable (JeffJSNetworkLogEntry) -> Void)?
    /// Console log callback for surfacing fetch bridge diagnostics in the app's console UI.
    var onConsoleLog: ((_ level: String, _ message: String) -> Void)?
    var baseURL: URL?
    /// Enforce browser CORS rules for cross-origin requests. Set false to
    /// debug against servers that do not send CORS headers.
    var enforceCORS: Bool = true
    /// Explicit document origin ("scheme://host[:port]"); defaults to baseURL's.
    var originOverride: String?
    /// Cookie jar used when the host app keeps cookies itself.
    weak var storageBridge: JeffJSStorageBridge?

    /// Preflight (OPTIONS) results, keyed by origin|url|method|headers.
    private static var preflightCache: [String: Date] = [:]

    /// Shared aggressive URLCache for all fetch requests.
    /// 50 MB memory + 200 MB disk.
    private static let sharedResourceCache: URLCache = URLCache(
        memoryCapacity: 50 * 1024 * 1024,
        diskCapacity: 200 * 1024 * 1024
    )

    /// Cached session for JS-initiated fetches — uses the shared aggressive
    /// resource cache so fetch() calls for scripts/CSS/assets get cached.
    private static let cachedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = sharedResourceCache
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    /// Number of in-flight fetch requests.
    var activeCount: Int { activeTasks.count }

    /// The document origin used for `Origin:` and CORS checks.
    var documentOrigin: String? {
        if let originOverride { return originOverride }
        guard let baseURL else { return nil }
        return Self.origin(of: baseURL)
    }

    // MARK: - Init

    init(userAgent: String) {
        self.userAgent = userAgent
    }

    // MARK: - Registration

    func register(on ctx: JeffJSContext) {
        self.ctx = ctx
        let global = ctx.getGlobalObject()
        let fetchObj = ctx.newPlainObject()

        // fetch(url, opts, callback) — legacy entry, no request id returned.
        ctx.setPropertyFunc(obj: fetchObj, name: "fetch", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            let url = ctx.toSwiftString(args.count > 0 ? args[0] : .undefined) ?? ""
            let opts = args.count > 1 ? args[1] : JeffJSValue.undefined
            let callback = args.count > 2 ? args[2] : JeffJSValue.undefined
            _ = self.start(ctx: ctx, url: url, opts: opts, callback: callback, label: "fetch")
            return JeffJSValue.undefined
        }, length: 3)

        // startFetch(requestJSON, callback) -> requestID
        ctx.setPropertyFunc(obj: fetchObj, name: "startFetch", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.newFloat64(0) }
            let requestJSON = ctx.toSwiftString(args.count > 0 ? args[0] : .undefined) ?? "{}"
            let callback = args.count > 1 ? args[1] : JeffJSValue.undefined
            let (url, optionsJSON) = self.parseRequestPayload(requestJSON)
            let optsVal = ctx.newStringValue(optionsJSON)
            defer { optsVal.freeValue() }
            let id = self.start(ctx: ctx, url: url, opts: optsVal, callback: callback, label: "startFetch")
            return JeffJSValue.newFloat64(Double(id))
        }, length: 2)

        // startFetchDirect(url, optsJSONOrObject, callback) -> requestID
        ctx.setPropertyFunc(obj: fetchObj, name: "startFetchDirect", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.newFloat64(0) }
            let url = ctx.toSwiftString(args.count > 0 ? args[0] : .undefined) ?? ""
            let opts = args.count > 1 ? args[1] : JeffJSValue.undefined
            let callback = args.count > 2 ? args[2] : JeffJSValue.undefined
            let id = self.start(ctx: ctx, url: url, opts: opts, callback: callback, label: "fetchDirect")
            return JeffJSValue.newFloat64(Double(id))
        }, length: 3)

        // startFetchObject(url, optsObject, callback) -> requestID
        // Same as startFetchDirect but named for the binary-capable path: the
        // options object may carry an ArrayBuffer/TypedArray/Blob/FormData body.
        ctx.setPropertyFunc(obj: fetchObj, name: "startFetchObject", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.newFloat64(0) }
            let url = ctx.toSwiftString(args.count > 0 ? args[0] : .undefined) ?? ""
            let opts = args.count > 1 ? args[1] : JeffJSValue.undefined
            let callback = args.count > 2 ? args[2] : JeffJSValue.undefined
            let id = self.start(ctx: ctx, url: url, opts: opts, callback: callback, label: "fetchObject")
            return JeffJSValue.newFloat64(Double(id))
        }, length: 3)

        // cancelFetch(id)
        ctx.setPropertyFunc(obj: fetchObj, name: "cancelFetch", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            let idVal = args.count > 0 ? args[0] : .undefined
            if let requestID = Self.intValue(ctx: ctx, idVal) { self.cancelFetch(requestID) }
            return JeffJSValue.undefined
        }, length: 1)

        // abortSignal(signalId) — cancel every request bound to that signal.
        ctx.setPropertyFunc(obj: fetchObj, name: "abortSignal", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            let sig = ctx.toSwiftString(args.count > 0 ? args[0] : .undefined) ?? ""
            guard !sig.isEmpty else { return JeffJSValue.undefined }
            for (rid, s) in self.requestSignals where s == sig { self.cancelFetch(rid) }
            return JeffJSValue.undefined
        }, length: 1)

        // decodeBytes(arrayBufferOrView, charset?) -> string
        ctx.setPropertyFunc(obj: fetchObj, name: "decodeBytes", fn: { ctx, _, args in
            guard args.count > 0, let bytes = ctx.arrayBufferBytes(of: args[0]) else {
                return ctx.newStringValue("")
            }
            let charset = args.count > 1 ? ctx.toSwiftString(args[1]) : nil
            return ctx.newStringValue(JeffJSFetchText.decode(bytes: bytes, charset: charset))
        }, length: 2)

        // encodeUTF8(string) -> ArrayBuffer
        ctx.setPropertyFunc(obj: fetchObj, name: "encodeUTF8", fn: { ctx, _, args in
            let s = ctx.toSwiftString(args.count > 0 ? args[0] : .undefined) ?? ""
            return ctx.newArrayBufferValue(bytes: Array(s.utf8))
        }, length: 1)

        // setEnforceCORS(bool) / getOrigin() / setOrigin(url)
        ctx.setPropertyFunc(obj: fetchObj, name: "setEnforceCORS", fn: { [weak self] ctx, _, args in
            self?.enforceCORS = args.count > 0 ? ctx.toBool(args[0]) : true
            return JeffJSValue.undefined
        }, length: 1)
        ctx.setPropertyFunc(obj: fetchObj, name: "setOrigin", fn: { [weak self] ctx, _, args in
            let s = ctx.toSwiftString(args.count > 0 ? args[0] : .undefined) ?? ""
            if s.isEmpty {
                self?.originOverride = nil
            } else if let u = URL(string: s), u.scheme != nil {
                self?.originOverride = JeffJSFetchBridge.origin(of: u)
            } else {
                self?.originOverride = s
            }
            return JeffJSValue.undefined
        }, length: 1)
        ctx.setPropertyFunc(obj: fetchObj, name: "getOrigin", fn: { [weak self] ctx, _, _ in
            ctx.newStringValue(self?.documentOrigin ?? "")
        }, length: 0)

        // setPropertyStr consumes `fetchObj` (see JeffJSContext.setPropertyStr).
        _ = ctx.setPropertyStr(obj: global, name: "__nativeFetch", value: fetchObj)
    }

    // MARK: - Fetch driver

    /// Build the request spec from JS values (main actor), then run it.
    private func start(ctx: JeffJSContext, url: String, opts: JeffJSValue,
                       callback: JeffJSValue, label: String) -> Int {
        let requestID = reserveRequestID()
        storedCallbacks[requestID] = callback.dupValue()

        var spec = buildSpec(ctx: ctx, url: url, opts: opts)
        if let sig = spec.signalID { requestSignals[requestID] = sig }
        spec.cookieHeader = cookieHeaderForRequest(spec: spec)

        let task = Task { [weak self] in
            guard let self else { return }
            let result = await self.performFetch(spec: spec)
            await MainActor.run {
                defer {
                    self.releaseCallback(for: requestID)
                    self.activeTasks.removeValue(forKey: requestID)
                    self.requestSignals.removeValue(forKey: requestID)
                }
                guard let cb = self.storedCallbacks[requestID], let ctx = self.ctx else { return }
                // Ensure the runtime is active for object creation during the callback
                JeffJSGCObjectHeader.activeRuntime = ctx.rt
                let idArg = JeffJSValue.newFloat64(Double(requestID))

                if Task.isCancelled {
                    self.deliverError(ctx: ctx, cb: cb, idArg: idArg,
                                      name: "AbortError",
                                      message: "AbortError",
                                      label: "\(label)(\(requestID)) abort")
                    return
                }

                switch result {
                case .success(let res):
                    let payloadJSON = ctx.newStringValue(self.legacyJSON(for: res))
                    let payloadObj = self.buildPayloadObject(ctx: ctx, result: res)
                    self.invokeCallback(ctx: ctx, cb: cb,
                                        args: [idArg, payloadJSON, .null, payloadObj, .null],
                                        label: "\(label)(\(requestID))")
                    payloadJSON.freeValue()
                    payloadObj.freeValue()
                    self.drainJobs(ctx: ctx, label: "\(label)(\(requestID))")
                case .failure(let error):
                    let failure = error as? JeffJSFetchFailure
                    let name = failure?.name ?? ((error as? URLError)?.code == .cancelled ? "AbortError" : "TypeError")
                    let message = failure?.message ?? error.localizedDescription
                    self.deliverError(ctx: ctx, cb: cb, idArg: idArg,
                                      name: name,
                                      message: name == "AbortError" ? "AbortError" : message,
                                      label: "\(label)(\(requestID)) error")
                }
            }
        }
        activeTasks[requestID] = task
        return requestID
    }

    private func deliverError(ctx: JeffJSContext, cb: JeffJSValue, idArg: JeffJSValue,
                              name: String, message: String, label: String) {
        let msgVal = ctx.newStringValue(message)
        let nameVal = ctx.newStringValue(name)
        invokeCallback(ctx: ctx, cb: cb, args: [idArg, .null, msgVal, .null, nameVal], label: label)
        msgVal.freeValue()
        nameVal.freeValue()
        drainJobs(ctx: ctx, label: label)
    }

    /// Invoke a JS callback and check for exceptions.
    private func invokeCallback(ctx: JeffJSContext, cb: JeffJSValue, args: [JeffJSValue], label: String) {
        let result = ctx.call(cb, this: .undefined, args: args)
        if result.isException {
            let exc = ctx.getException()
            let errMsg = ctx.toSwiftString(exc) ?? "unknown"
            onConsoleLog?("error", "[JeffJS Fetch] \(label) callback threw: \(errMsg)")
            exc.freeValue()
        }
        result.freeValue()
    }

    /// Drain the microtask queue, retrying past any throwing jobs so that
    /// fetch Promise handlers are not blocked by unrelated failures.
    private func drainJobs(ctx: JeffJSContext, label: String) {
        var drained = ctx.rt.executePendingJobs()
        var retries = 0
        while drained < 0 && ctx.rt.isJobPending() && retries < 10 {
            let exc = ctx.getException()
            let errMsg = ctx.toSwiftString(exc) ?? "unknown"
            onConsoleLog?("warn", "[JeffJS Fetch] \(label) microtask threw: \(errMsg)")
            exc.freeValue()
            drained = ctx.rt.executePendingJobs()
            retries += 1
        }
    }

    private func cancelFetch(_ requestID: Int) {
        // Keep the callback: the task's completion path delivers AbortError.
        activeTasks[requestID]?.cancel()
    }

    /// Cancel all in-flight fetch requests. Called on navigation teardown.
    func cancelAll() {
        for (_, task) in activeTasks { task.cancel() }
        activeTasks.removeAll()
        requestSignals.removeAll()
        let keys = Array(storedCallbacks.keys)
        for key in keys { releaseCallback(for: key) }
    }

    // MARK: - Internals

    private func releaseCallback(for requestID: Int) {
        if let cb = storedCallbacks.removeValue(forKey: requestID) {
            cb.freeValue()
        }
    }

    private func reserveRequestID() -> Int {
        let id = nextRequestID
        nextRequestID += 1
        return id
    }

    private static func intValue(ctx: JeffJSContext, _ v: JeffJSValue) -> Int? {
        if let i = ctx.toInt32(v) { return Int(i) }
        if let s = ctx.toSwiftString(v), let d = Double(s) { return Int(d) }
        return nil
    }

    private func parseRequestPayload(_ requestJSON: String) -> (String, String) {
        guard
            let data = requestJSON.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ("", "")
        }
        let url = obj["url"] as? String ?? ""
        let options = obj["options"] as? [String: Any] ?? [:]
        let optionsData = (try? JSONSerialization.data(withJSONObject: options)) ?? Data("{}".utf8)
        let optionsJSON = String(data: optionsData, encoding: .utf8) ?? "{}"
        return (url, optionsJSON)
    }

    // MARK: - Spec building (JS -> Swift)

    /// Build a request spec from either a JSON options string (legacy) or a
    /// JS options object (binary-capable).
    private func buildSpec(ctx: JeffJSContext, url: String, opts: JeffJSValue) -> JeffJSFetchSpec {
        var spec = JeffJSFetchSpec(urlString: url)

        if opts.isString {
            let json = ctx.toSwiftString(opts) ?? "{}"
            applyJSONOptions(json, to: &spec)
            return spec
        }
        guard opts.isObject else { return spec }

        func str(_ name: String) -> String? {
            let v = ctx.getPropertyStr(obj: opts, name: name)
            defer { v.freeValue() }
            if v.isUndefined || v.isNull { return nil }
            let s = ctx.toSwiftString(v) ?? ""
            return s.isEmpty ? nil : s
        }

        if let m = str("method") { spec.method = m.uppercased() }
        if let c = str("credentials") { spec.credentials = c }
        if let m = str("mode") { spec.mode = m }
        if let c = str("cache") { spec.cache = c }
        if let r = str("redirect") { spec.redirect = r }
        if let s = str("signalId") ?? str("signalID") { spec.signalID = s }
        if let rt = str("responseType") { spec.responseType = rt }

        // headers: plain object { name: value } or an array of [name, value].
        let headersVal = ctx.getPropertyStr(obj: opts, name: "headers")
        defer { headersVal.freeValue() }
        if headersVal.isObject {
            let len = Int(ctx.getArrayLength(headersVal))
            let isPairArray: Bool = {
                guard len > 0 else { return false }
                let first = ctx.getPropertyUint32(obj: headersVal, index: 0)
                defer { first.freeValue() }
                return first.isObject && ctx.getArrayLength(first) == 2
            }()
            if isPairArray {
                for i in 0..<len {
                    let pair = ctx.getPropertyUint32(obj: headersVal, index: UInt32(i))
                    defer { pair.freeValue() }
                    let k = ctx.getPropertyUint32(obj: pair, index: 0)
                    let v = ctx.getPropertyUint32(obj: pair, index: 1)
                    defer { k.freeValue(); v.freeValue() }
                    if let name = ctx.toSwiftString(k), !name.isEmpty {
                        spec.headers.append((name, ctx.toSwiftString(v) ?? ""))
                    }
                }
            } else {
                for name in ctx.getOwnPropertyNames(obj: headersVal) {
                    let v = ctx.getPropertyStr(obj: headersVal, name: name)
                    defer { v.freeValue() }
                    if v.isUndefined || v.isNull { continue }
                    spec.headers.append((name, ctx.toSwiftString(v) ?? ""))
                }
            }
        }

        // body: string | ArrayBuffer | TypedArray | DataView | Blob | FormData
        let bodyVal = ctx.getPropertyStr(obj: opts, name: "body")
        defer { bodyVal.freeValue() }
        if let extracted = JeffJSFetchBodyExtractor.extract(ctx: ctx, value: bodyVal) {
            spec.body = extracted.bytes
            spec.bodyContentType = extracted.contentType
        }
        return spec
    }

    /// Legacy JSON options (string body, or `bodyBase64` for bytes).
    private func applyJSONOptions(_ json: String, to spec: inout JeffJSFetchSpec) {
        guard !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let method = obj["method"] as? String, !method.isEmpty { spec.method = method.uppercased() }
        if let headers = obj["headers"] as? [String: Any] {
            for (key, value) in headers { spec.headers.append((key, String(describing: value))) }
        }
        if let b64 = obj["bodyBase64"] as? String, let d = Data(base64Encoded: b64) {
            spec.body = Array(d)
        } else if let body = obj["body"] as? String {
            spec.body = Array(body.utf8)
            spec.bodyContentType = "text/plain;charset=UTF-8"
        }
        if let v = obj["contentType"] as? String { spec.bodyContentType = v }
        if let v = obj["credentials"] as? String { spec.credentials = v }
        if let v = obj["mode"] as? String { spec.mode = v }
        if let v = obj["cache"] as? String { spec.cache = v }
        if let v = obj["redirect"] as? String { spec.redirect = v }
        if let v = obj["responseType"] as? String { spec.responseType = v }
        if let v = obj["signalId"] { spec.signalID = String(describing: v) }
    }

    private func cookieHeaderForRequest(spec: JeffJSFetchSpec) -> String? {
        guard spec.credentials != "omit", let storageBridge else { return nil }
        // The bridge jar has no domain scoping: only send it same-origin, or
        // cross-origin when the caller explicitly asked to include credentials.
        let target = resolveURL(spec.urlString)
        let cross = isCrossOrigin(target)
        if cross && spec.credentials != "include" { return nil }
        let cookies = storageBridge.cookieString()
        return cookies.isEmpty ? nil : cookies
    }

    // MARK: - Origin helpers

    static func origin(of url: URL) -> String {
        guard let scheme = url.scheme?.lowercased(), let host = url.host else { return "null" }
        guard scheme == "http" || scheme == "https" else { return "null" }
        let defaultPort = (scheme == "https") ? 443 : 80
        let port = url.port ?? defaultPort
        return port == defaultPort ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
    }

    private func isCrossOrigin(_ url: URL?) -> Bool {
        guard let url, let docOrigin = documentOrigin else { return false }
        return Self.origin(of: url) != docOrigin
    }

    private func resolveURL(_ url: String) -> URL? {
        if let absolute = URL(string: url), absolute.scheme != nil { return absolute }
        if url.isEmpty, let base = baseURL { return base }
        if let base = baseURL, let resolved = URL(string: url, relativeTo: base) {
            return resolved.absoluteURL
        }
        return nil
    }

    // MARK: - CORS rules

    private static let simpleMethods: Set<String> = ["GET", "HEAD", "POST"]
    private static let safelistedRequestHeaders: Set<String> = [
        "accept", "accept-language", "content-language", "content-type", "range"
    ]
    private static let simpleContentTypes: Set<String> = [
        "application/x-www-form-urlencoded", "multipart/form-data", "text/plain"
    ]
    private static let safelistedResponseHeaders: Set<String> = [
        "cache-control", "content-language", "content-length", "content-type",
        "expires", "last-modified", "pragma"
    ]

    private static func needsPreflight(method: String, headers: [(name: String, value: String)]) -> Bool {
        if !simpleMethods.contains(method.uppercased()) { return true }
        for (name, value) in headers {
            let lower = name.lowercased()
            if !safelistedRequestHeaders.contains(lower) { return true }
            if lower == "content-type" {
                let mime = JeffJSFetchText.mimeType(fromContentType: value)
                if !simpleContentTypes.contains(mime) { return true }
            }
        }
        return false
    }

    private static func allowOriginOK(_ headers: [String: String], origin: String,
                                      credentials: Bool) -> Bool {
        guard let allow = headers["access-control-allow-origin"]?
            .trimmingCharacters(in: .whitespaces) else { return false }
        if credentials {
            guard allow == origin else { return false }
            let creds = headers["access-control-allow-credentials"]?
                .trimmingCharacters(in: .whitespaces).lowercased()
            return creds == "true"
        }
        return allow == "*" || allow == origin
    }

    // MARK: - Networking

    private func performFetch(spec: JeffJSFetchSpec) async -> Result<JeffJSFetchResult, Error> {
        guard let targetURL = resolveURL(spec.urlString) else {
            let reason = baseURL == nil ? "baseURL is nil" : "cannot resolve \"\(spec.urlString)\""
            onConsoleLog?("error", "[JeffJS Fetch] Relative URL resolution failed for '\(spec.urlString)': \(reason)")
            onNetworkLog?(JeffJSNetworkLogEntry(method: spec.method, url: spec.urlString,
                                                statusCode: 0, statusText: "", durationMs: 0,
                                                responseSize: 0, error: "Invalid URL: \(reason)"))
            return .failure(JeffJSFetchFailure(name: "TypeError", message: "Failed to parse URL: \(spec.urlString)"))
        }

        let docOrigin = documentOrigin
        let crossOrigin = docOrigin != nil && Self.origin(of: targetURL) != docOrigin!
        let corsActive = enforceCORS && crossOrigin && docOrigin != nil
        var mode = spec.mode.isEmpty ? "cors" : spec.mode

        if corsActive && mode == "same-origin" {
            return .failure(JeffJSFetchFailure(
                name: "TypeError",
                message: "Failed to fetch: request mode is 'same-origin' but the URL is cross-origin"))
        }
        if !enforceCORS && mode == "no-cors" { mode = "cors" }

        // no-cors downgrades the request to the simple subset.
        var method = spec.method.isEmpty ? "GET" : spec.method.uppercased()
        var headers = spec.headers
        if corsActive && mode == "no-cors" {
            if !Self.simpleMethods.contains(method) { method = "GET" }
            headers = headers.filter { Self.safelistedRequestHeaders.contains($0.name.lowercased()) }
        }

        // Preflight for non-simple cross-origin requests.
        if corsActive && mode == "cors" {
            var preflightHeaders = headers
            if let ct = spec.bodyContentType, !headers.contains(where: { $0.name.lowercased() == "content-type" }) {
                preflightHeaders.append(("content-type", ct))
            }
            if Self.needsPreflight(method: method, headers: preflightHeaders) {
                if let failure = await preflight(url: targetURL, method: method,
                                                 headers: preflightHeaders,
                                                 origin: docOrigin!,
                                                 credentials: spec.credentials == "include") {
                    return .failure(failure)
                }
            }
        }

        var request = URLRequest(url: targetURL)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body = spec.body {
            request.httpBody = Data(body)
            if let ct = spec.bodyContentType,
               request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue(ct, forHTTPHeaderField: "Content-Type")
            }
        }
        // Origin: always cross-origin, and for same-origin state-changing methods
        // (matches browsers).
        if let docOrigin, crossOrigin || !["GET", "HEAD"].contains(method) {
            request.setValue(docOrigin, forHTTPHeaderField: "Origin")
        }
        // Credentials / cookies.
        switch spec.credentials {
        case "omit":
            request.httpShouldHandleCookies = false
            request.setValue(nil, forHTTPHeaderField: "Cookie")
        case "include":
            request.httpShouldHandleCookies = true
            if let cookie = spec.cookieHeader { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        default: // same-origin
            request.httpShouldHandleCookies = !crossOrigin
            if !crossOrigin, let cookie = spec.cookieHeader {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
        }
        applyCachePolicy(spec.cache, to: &request)

        let startTime = CFAbsoluteTimeGetCurrent()
        let redirectMode = spec.redirect.isEmpty ? "follow" : spec.redirect
        let delegate = JeffJSRedirectDelegate(mode: redirectMode)

        do {
            let session = (method == "GET" && spec.cache != "no-store") ? Self.cachedSession : URLSession.shared
            let (data, response) = try await session.data(for: request, delegate: delegate)
            let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            let http = response as? HTTPURLResponse

            // Blocked redirect (redirect: manual | error).
            if let blocked = delegate.blocked {
                onNetworkLog?(JeffJSNetworkLogEntry(method: method, url: spec.urlString,
                                                    statusCode: blocked.statusCode,
                                                    statusText: HTTPURLResponse.localizedString(forStatusCode: blocked.statusCode),
                                                    durationMs: durationMs, responseSize: 0, error: nil))
                if redirectMode == "error" {
                    return .failure(JeffJSFetchFailure(
                        name: "TypeError",
                        message: "Failed to fetch: redirect was not followed (redirect: \"error\")"))
                }
                // manual -> opaque redirect, exactly like a browser.
                return .success(JeffJSFetchResult(
                    status: 0, statusText: "", url: targetURL.absoluteString,
                    redirected: false, type: "opaqueredirect", headers: [:],
                    bytes: [], mimeType: "", charset: nil))
            }

            let statusCode = http?.statusCode ?? 0
            let statusText = HTTPURLResponse.localizedString(forStatusCode: statusCode)
            var headerMap: [String: String] = [:]
            if let http {
                for (key, value) in http.allHeaderFields {
                    let k = String(describing: key).lowercased()
                    let v = String(describing: value)
                    if k == "set-cookie", let existing = headerMap[k] {
                        headerMap[k] = existing + "\n" + v   // set-cookie combined
                    } else {
                        headerMap[k] = v
                    }
                }
            }

            onNetworkLog?(JeffJSNetworkLogEntry(method: method, url: spec.urlString,
                                                statusCode: statusCode, statusText: statusText,
                                                durationMs: durationMs, responseSize: data.count,
                                                error: nil))

            // no-cors -> opaque response: the request went out, the answer is hidden.
            if corsActive && mode == "no-cors" {
                return .success(JeffJSFetchResult(
                    status: 0, statusText: "", url: "", redirected: false, type: "opaque",
                    headers: [:], bytes: [], mimeType: "", charset: nil))
            }

            if corsActive && mode == "cors" {
                guard Self.allowOriginOK(headerMap, origin: docOrigin!,
                                         credentials: spec.credentials == "include") else {
                    let allow = headerMap["access-control-allow-origin"] ?? "<missing>"
                    return .failure(JeffJSFetchFailure(
                        name: "TypeError",
                        message: "Failed to fetch: CORS check failed for \(targetURL.absoluteString) — Access-Control-Allow-Origin: \(allow) does not allow origin \(docOrigin!)"))
                }
                headerMap = Self.filterCORSResponseHeaders(headerMap,
                                                           credentials: spec.credentials == "include")
            }

            let contentType = headerMap["content-type"]
            return .success(JeffJSFetchResult(
                status: statusCode,
                statusText: statusText,
                url: http?.url?.absoluteString ?? targetURL.absoluteString,
                redirected: delegate.redirected,
                type: crossOrigin ? "cors" : "basic",
                headers: headerMap,
                bytes: Array(data),
                mimeType: JeffJSFetchText.mimeType(fromContentType: contentType),
                charset: JeffJSFetchText.charset(fromContentType: contentType)))
        } catch {
            let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            onNetworkLog?(JeffJSNetworkLogEntry(method: method, url: spec.urlString,
                                                statusCode: 0, statusText: "",
                                                durationMs: durationMs, responseSize: 0,
                                                error: error.localizedDescription))
            if (error as? URLError)?.code == .cancelled {
                return .failure(JeffJSFetchFailure(name: "AbortError", message: "AbortError"))
            }
            return .failure(error)
        }
    }

    /// Browsers only expose safelisted response headers plus the ones named by
    /// Access-Control-Expose-Headers.
    private static func filterCORSResponseHeaders(_ headers: [String: String],
                                                  credentials: Bool) -> [String: String] {
        var exposed = safelistedResponseHeaders
        if let list = headers["access-control-expose-headers"] {
            let names = list.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
            if names.contains("*") && !credentials { return headers }
            exposed.formUnion(names)
        }
        return headers.filter { exposed.contains($0.key) }
    }

    private func applyCachePolicy(_ cache: String, to request: inout URLRequest) {
        switch cache {
        case "no-store", "reload":  request.cachePolicy = .reloadIgnoringLocalCacheData
        case "no-cache":            request.cachePolicy = .reloadRevalidatingCacheData
        case "force-cache":         request.cachePolicy = .returnCacheDataElseLoad
        case "only-if-cached":      request.cachePolicy = .returnCacheDataDontLoad
        default: break
        }
    }

    /// Send the CORS preflight (OPTIONS) unless a cached result still applies.
    /// Returns a failure when the preflight denies the request.
    private func preflight(url: URL, method: String,
                           headers: [(name: String, value: String)],
                           origin: String, credentials: Bool) async -> JeffJSFetchFailure? {
        let headerNames = headers.map { $0.name.lowercased() }
            .filter { !Self.safelistedRequestHeaders.contains($0) || $0 == "content-type" }
            .sorted()
        let cacheKey = "\(origin)|\(url.absoluteString)|\(method)|\(headerNames.joined(separator: ","))|\(credentials)"
        if let expiry = Self.preflightCache[cacheKey] {
            if expiry > Date() { return nil }
            Self.preflightCache.removeValue(forKey: cacheKey)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "OPTIONS"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(origin, forHTTPHeaderField: "Origin")
        req.setValue(method, forHTTPHeaderField: "Access-Control-Request-Method")
        if !headerNames.isEmpty {
            req.setValue(headerNames.joined(separator: ","), forHTTPHeaderField: "Access-Control-Request-Headers")
        }
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.httpShouldHandleCookies = credentials

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return JeffJSFetchFailure(name: "TypeError", message: "Failed to fetch: preflight did not return an HTTP response")
            }
            var map: [String: String] = [:]
            for (k, v) in http.allHeaderFields { map[String(describing: k).lowercased()] = String(describing: v) }

            guard (200...299).contains(http.statusCode) else {
                return JeffJSFetchFailure(name: "TypeError",
                    message: "Failed to fetch: preflight returned HTTP \(http.statusCode)")
            }
            guard Self.allowOriginOK(map, origin: origin, credentials: credentials) else {
                return JeffJSFetchFailure(name: "TypeError",
                    message: "Failed to fetch: preflight Access-Control-Allow-Origin does not allow \(origin)")
            }
            let allowedMethods = Set((map["access-control-allow-methods"] ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() })
            if !(allowedMethods.contains(method.uppercased())
                 || (allowedMethods.contains("*") && !credentials)
                 || Self.simpleMethods.contains(method.uppercased())) {
                return JeffJSFetchFailure(name: "TypeError",
                    message: "Failed to fetch: method \(method) is not allowed by Access-Control-Allow-Methods")
            }
            let allowedHeaders = Set((map["access-control-allow-headers"] ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            let wildcardHeaders = allowedHeaders.contains("*") && !credentials
            for name in headerNames where !Self.safelistedRequestHeaders.contains(name) {
                if !wildcardHeaders && !allowedHeaders.contains(name) {
                    return JeffJSFetchFailure(name: "TypeError",
                        message: "Failed to fetch: header \(name) is not allowed by Access-Control-Allow-Headers")
                }
            }
            let maxAge = min(Double(map["access-control-max-age"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 5), 600)
            if maxAge > 0 {
                Self.preflightCache[cacheKey] = Date().addingTimeInterval(maxAge)
            }
            return nil
        } catch {
            return JeffJSFetchFailure(name: "TypeError",
                message: "Failed to fetch: preflight request failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Result -> JS

    /// Legacy JSON payload (string body). Binary media types yield "".
    private func legacyJSON(for result: JeffJSFetchResult) -> String {
        let body: String
        if result.bytes.isEmpty || JeffJSFetchText.isBinaryMime(result.mimeType) {
            body = ""
        } else {
            body = JeffJSFetchText.decode(bytes: result.bytes, charset: result.charset)
        }
        let payload: [String: Any] = [
            "ok": (200...299).contains(result.status),
            "status": result.status,
            "statusText": result.statusText,
            "url": result.url,
            "redirected": result.redirected,
            "type": result.type,
            "headers": result.headers,
            "byteLength": result.bytes.count,
            "body": body
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// The native response object handed to JS as the callback's 4th argument.
    private func buildPayloadObject(ctx: JeffJSContext, result: JeffJSFetchResult) -> JeffJSValue {
        let obj = ctx.newPlainObject()

        func setString(_ name: String, _ value: String) {
            let v = ctx.newStringValue(value)
            _ = ctx.setPropertyStr(obj: obj, name: name, value: v)
        }
        setString("statusText", result.statusText)
        setString("url", result.url)
        setString("type", result.type)
        setString("mimeType", result.mimeType)
        setString("charset", result.charset ?? "")
        _ = ctx.setPropertyStr(obj: obj, name: "status", value: .newInt32(Int32(result.status)))
        _ = ctx.setPropertyStr(obj: obj, name: "ok", value: .newBool((200...299).contains(result.status)))
        _ = ctx.setPropertyStr(obj: obj, name: "redirected", value: .newBool(result.redirected))
        _ = ctx.setPropertyStr(obj: obj, name: "byteLength", value: .newInt32(Int32(result.bytes.count)))

        // headers: { lowercase-name: value }, set-cookie values joined with "\n"
        let headersObj = ctx.newPlainObject()
        for (k, v) in result.headers.sorted(by: { $0.key < $1.key }) {
            let hv = ctx.newStringValue(v)
            _ = ctx.setPropertyStr(obj: headersObj, name: k, value: hv)
        }
        _ = ctx.setPropertyStr(obj: obj, name: "headers", value: headersObj)

        // bodyBytes: a real ArrayBuffer.
        let buffer = ctx.newArrayBufferValue(bytes: result.bytes)
        _ = ctx.setPropertyStr(obj: obj, name: "bodyBytes", value: buffer)

        // bodyText(): lazily decoded, cached in the closure.
        let bytes = result.bytes
        let charset = result.charset
        var cachedText: String? = nil
        ctx.setPropertyFunc(obj: obj, name: "bodyText", fn: { c, _, _ in
            if let cachedText { return c.newStringValue(cachedText) }
            let text = JeffJSFetchText.decode(bytes: bytes, charset: charset)
            cachedText = text
            return c.newStringValue(text)
        }, length: 0)

        // body: legacy eager string ("" for binary media types).
        let legacyBody = (result.bytes.isEmpty || JeffJSFetchText.isBinaryMime(result.mimeType))
            ? "" : JeffJSFetchText.decode(bytes: result.bytes, charset: result.charset)
        setString("body", legacyBody)

        return obj
    }
}
