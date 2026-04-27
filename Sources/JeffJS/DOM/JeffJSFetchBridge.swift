// JeffJSFetchBridge.swift
// JeffJS Fetch Bridge — Registers native fetch APIs on a JeffJS context.
//
// This bridges URLSession networking to JavaScript running in JeffJS, providing:
//   __nativeFetch.fetch(url, opts, callback)
//   __nativeFetch.startFetch(requestJSON, callback)
//   __nativeFetch.cancelFetch(id)
//
// Follows the same patterns as JeffJSDOMBridge for native function registration.
// Ports the JSC JSFetchBridge logic (JSScriptEngine.swift) to JeffJS's native API.

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

// MARK: - JeffJSFetchBridge

/// Registers fetch APIs on a JeffJS context so that JavaScript can make HTTP
/// requests through the native networking stack.
///
/// Usage:
/// ```swift
/// let bridge = JeffJSFetchBridge(fetcher: htmlFetcher, userAgent: ua)
/// bridge.register(on: ctx)
/// ```
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
    /// Network log callback for diagnostics.
    var onNetworkLog: (@MainActor @Sendable (JeffJSNetworkLogEntry) -> Void)?
    /// Console log callback for surfacing fetch bridge diagnostics in the app's console UI.
    var onConsoleLog: ((_ level: String, _ message: String) -> Void)?
    var baseURL: URL?

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

    // MARK: - Init

    init(userAgent: String) {
        self.userAgent = userAgent
    }

    // MARK: - Registration

    /// Register `__nativeFetch` on the JeffJS global object with methods:
    /// fetch(url, opts, callback), startFetch(requestJSON, callback), cancelFetch(id)
    func register(on ctx: JeffJSContext) {
        self.ctx = ctx
        let global = ctx.getGlobalObject()
        let fetchObj = ctx.newPlainObject()

        // fetch(url, optsJSON, callback)
        ctx.setPropertyFunc(obj: fetchObj, name: "fetch", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            let url = ctx.toSwiftString(args.count > 0 ? args[0] : .undefined) ?? ""
            let optsJSON = ctx.toSwiftString(args.count > 1 ? args[1] : .undefined) ?? "{}"
            let callback = args.count > 2 ? args[2] : JeffJSValue.undefined
            self.fetch(ctx: ctx, url: url, optionsJSON: optsJSON, callback: callback)
            return JeffJSValue.undefined
        }, length: 3)

        // startFetch(requestJSON, callback) -> requestID
        ctx.setPropertyFunc(obj: fetchObj, name: "startFetch", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.newFloat64(0) }
            let requestJSON = ctx.toSwiftString(args.count > 0 ? args[0] : .undefined) ?? "{}"
            let callback = args.count > 1 ? args[1] : JeffJSValue.undefined
            let requestID = self.startFetch(ctx: ctx, requestJSON: requestJSON, callback: callback)
            return JeffJSValue.newFloat64(Double(requestID))
        }, length: 2)

        // startFetchDirect(url, optsJSON, callback) -> requestID
        // Bypasses JSON bundling — URL and options passed as separate native args
        // to avoid JeffJS variable capture issues with JSON.stringify.
        ctx.setPropertyFunc(obj: fetchObj, name: "startFetchDirect", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.newFloat64(0) }
            let url = ctx.toSwiftString(args.count > 0 ? args[0] : .undefined) ?? ""
            let optsJSON = ctx.toSwiftString(args.count > 1 ? args[1] : .undefined) ?? "{}"
            let callback = args.count > 2 ? args[2] : JeffJSValue.undefined
            let requestID = self.startFetchDirect(ctx: ctx, url: url, optionsJSON: optsJSON, callback: callback)
            return JeffJSValue.newFloat64(Double(requestID))
        }, length: 3)

        // cancelFetch(id)
        ctx.setPropertyFunc(obj: fetchObj, name: "cancelFetch", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            let idVal = args.count > 0 ? args[0] : .undefined
            let requestID: Int
            if let intVal = ctx.toInt32(idVal) {
                requestID = Int(intVal)
            } else if let dblStr = ctx.toSwiftString(idVal), let dbl = Double(dblStr) {
                requestID = Int(dbl)
            } else {
                return JeffJSValue.undefined
            }
            self.cancelFetch(requestID)
            return JeffJSValue.undefined
        }, length: 1)

        _ = ctx.setPropertyStr(obj: global, name: "__nativeFetch", value: fetchObj)
    }

    // MARK: - Fetch Operations

    private func fetch(ctx: JeffJSContext, url: String, optionsJSON: String, callback: JeffJSValue) {
        let requestID = reserveRequestID()
        storedCallbacks[requestID] = callback.dupValue()

        let task = Task { [weak self] in
            guard let self else { return }
            let result = await self.performFetch(url: url, optionsJSON: optionsJSON)
            await MainActor.run {
                defer {
                    self.releaseCallback(for: requestID)
                    self.activeTasks.removeValue(forKey: requestID)
                }

                guard !Task.isCancelled, let cb = self.storedCallbacks[requestID], let ctx = self.ctx else { return }
                // Ensure the runtime is active for object creation during the callback
                JeffJSGCObjectHeader.activeRuntime = ctx.rt
                let idArg = JeffJSValue.newFloat64(Double(requestID))
                switch result {
                case .success(let payload):
                    self.invokeCallback(ctx: ctx, cb: cb, args: [idArg, ctx.newStringValue(payload), .null], label: "fetch(\(requestID))")
                case .failure(let error):
                    self.invokeCallback(ctx: ctx, cb: cb, args: [idArg, .null, ctx.newStringValue(error.localizedDescription)], label: "fetch(\(requestID))")
                }
                self.drainJobs(ctx: ctx, label: "fetch(\(requestID))")
            }
        }
        activeTasks[requestID] = task
    }

    private func startFetchDirect(ctx: JeffJSContext, url: String, optionsJSON: String, callback: JeffJSValue) -> Int {
        let requestID = reserveRequestID()
        storedCallbacks[requestID] = callback.dupValue()
        let task = Task { [weak self] in
            guard let self else { return }
            let result = await self.performFetch(url: url, optionsJSON: optionsJSON)
            await MainActor.run {
                defer {
                    self.releaseCallback(for: requestID)
                    self.activeTasks.removeValue(forKey: requestID)
                }
                guard let cb = self.storedCallbacks[requestID], let ctx = self.ctx else { return }
                JeffJSGCObjectHeader.activeRuntime = ctx.rt
                if Task.isCancelled {
                    self.invokeCallback(ctx: ctx, cb: cb, args: [.null, ctx.newStringValue("AbortError")], label: "fetchDirect(\(requestID)) abort")
                    self.drainJobs(ctx: ctx, label: "fetchDirect(\(requestID)) abort")
                    return
                }
                let idArg = JeffJSValue.newFloat64(Double(requestID))
                switch result {
                case .success(let payload):
                    self.invokeCallback(ctx: ctx, cb: cb, args: [idArg, ctx.newStringValue(payload), .null], label: "fetchDirect(\(requestID))")
                case .failure(let error):
                    self.invokeCallback(ctx: ctx, cb: cb, args: [idArg, .null, ctx.newStringValue(error.localizedDescription)], label: "fetchDirect(\(requestID)) error")
                }
                self.drainJobs(ctx: ctx, label: "fetchDirect(\(requestID))")
            }
        }
        activeTasks[requestID] = task
        return requestID
    }

    private func startFetch(ctx: JeffJSContext, requestJSON: String, callback: JeffJSValue) -> Int {
        let requestID = reserveRequestID()
        storedCallbacks[requestID] = callback.dupValue()
        let task = Task { [weak self] in
            guard let self else { return }
            let (url, optionsJSON) = self.parseRequestPayload(requestJSON)
            let result = await self.performFetch(url: url, optionsJSON: optionsJSON)
            await MainActor.run {
                defer {
                    self.releaseCallback(for: requestID)
                    self.activeTasks.removeValue(forKey: requestID)
                }

                guard let cb = self.storedCallbacks[requestID], let ctx = self.ctx else {
                    self.onConsoleLog?("warn", "[JeffJS Fetch] callback or ctx gone for request \(requestID)")
                    return
                }
                // Ensure the runtime is active for object creation during the callback
                JeffJSGCObjectHeader.activeRuntime = ctx.rt
                if Task.isCancelled {
                    self.invokeCallback(ctx: ctx, cb: cb, args: [.null, ctx.newStringValue("AbortError")], label: "startFetch(\(requestID)) abort")
                    self.drainJobs(ctx: ctx, label: "startFetch(\(requestID)) abort")
                    return
                }

                let idArg = JeffJSValue.newFloat64(Double(requestID))
                switch result {
                case .success(let payload):
                    self.invokeCallback(ctx: ctx, cb: cb, args: [idArg, ctx.newStringValue(payload), .null], label: "startFetch(\(requestID))")
                case .failure(let error):
                    self.invokeCallback(ctx: ctx, cb: cb, args: [idArg, .null, ctx.newStringValue(error.localizedDescription)], label: "startFetch(\(requestID)) error")
                }
                self.drainJobs(ctx: ctx, label: "startFetch(\(requestID))")
            }
        }
        activeTasks[requestID] = task
        return requestID
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
            // A job threw — clear the exception and keep draining so the
            // fetch's .then() handler isn't blocked by an unrelated failure.
            let exc = ctx.getException()
            let errMsg = ctx.toSwiftString(exc) ?? "unknown"
            onConsoleLog?("warn", "[JeffJS Fetch] \(label) microtask threw: \(errMsg)")
            exc.freeValue()
            drained = ctx.rt.executePendingJobs()
            retries += 1
        }
    }

    private func cancelFetch(_ requestID: Int) {
        activeTasks[requestID]?.cancel()
        activeTasks.removeValue(forKey: requestID)
        releaseCallback(for: requestID)
    }

    /// Cancel all in-flight fetch requests. Called on navigation teardown.
    func cancelAll() {
        for (_, task) in activeTasks { task.cancel() }
        activeTasks.removeAll()
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

    private func performFetch(url: String, optionsJSON: String) async -> Result<String, Error> {
        // Resolve relative URLs against the page's base URL
        let targetURL: URL
        if let absolute = URL(string: url), absolute.scheme != nil {
            targetURL = absolute
        } else if url.isEmpty, let base = baseURL {
            // Empty URL = current page (browser spec behavior)
            targetURL = base
        } else if let base = baseURL, let resolved = URL(string: url, relativeTo: base) {
            targetURL = resolved.absoluteURL
        } else {
            let reason = baseURL == nil ? "baseURL is nil" : "URL(string: \"\(url)\", relativeTo: \"\(baseURL!)\") failed"
            await MainActor.run {
                onConsoleLog?("error", "[JeffJS Fetch] Relative URL resolution failed for '\(url)': \(reason)")
                onNetworkLog?(JeffJSNetworkLogEntry(
                    method: "GET", url: url, statusCode: 0, statusText: "",
                    durationMs: 0, responseSize: 0, error: "Invalid URL: \(reason)"
                ))
            }
            return .failure(URLError(.badURL))
        }

        var request = URLRequest(url: targetURL)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        if !optionsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let data = optionsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let method = obj["method"] as? String, !method.isEmpty {
                request.httpMethod = method.uppercased()
            }
            if let headers = obj["headers"] as? [String: Any] {
                for (key, value) in headers {
                    request.setValue(String(describing: value), forHTTPHeaderField: key)
                }
            }
            if let body = obj["body"] as? String {
                request.httpBody = body.data(using: .utf8)
            }
        }

        let method = request.httpMethod ?? "GET"
        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let session = (request.httpMethod ?? "GET") == "GET" ? Self.cachedSession : URLSession.shared
            let (data, response) = try await session.data(for: request)
            let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            let body = String(data: data, encoding: .utf8) ?? ""

            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            http?.allHeaderFields.forEach { key, value in
                headers[String(describing: key)] = String(describing: value)
            }

            let statusCode = http?.statusCode ?? 0
            let statusText = HTTPURLResponse.localizedString(forStatusCode: statusCode)

            await MainActor.run {
                onNetworkLog?(JeffJSNetworkLogEntry(
                    method: method, url: url, statusCode: statusCode,
                    statusText: statusText, durationMs: durationMs,
                    responseSize: data.count, error: nil
                ))
            }

            let payload: [String: Any] = [
                "ok": (http.map { 200...299 ~= $0.statusCode } ?? true),
                "status": statusCode,
                "statusText": statusText,
                "url": http?.url?.absoluteString ?? request.url?.absoluteString ?? "",
                "headers": headers,
                "body": body
            ]

            let jsonData = try JSONSerialization.data(withJSONObject: payload)
            return .success(String(data: jsonData, encoding: .utf8) ?? "{}")
        } catch {
            let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            await MainActor.run {
                onNetworkLog?(JeffJSNetworkLogEntry(
                    method: method, url: url, statusCode: 0, statusText: "",
                    durationMs: durationMs, responseSize: 0,
                    error: error.localizedDescription
                ))
            }
            return .failure(error)
        }
    }
}
