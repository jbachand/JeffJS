// JeffJSWebSocketBridge.swift
// JeffJS WebSocket Bridge — Registers __nativeWebSocket on a JeffJS context.
//
// This bridges URLSessionWebSocketTask to JavaScript running in JeffJS,
// providing connect/send/close methods that the WebSocket polyfill calls.
// Port of JSWebSocketBridge (JSC version) to JeffJS native function API.

import Foundation

// MARK: - JeffJSWebSocketBridge

/// Registers `__nativeWebSocket` on a JeffJS context so the JS WebSocket
/// polyfill can create real network connections via URLSessionWebSocketTask.
///
/// Callback protocol (the host polyfill's `WebSocket`, HTML §9.3 "The WebSocket interface"):
///   ('open', protocol, null, extensions)        — after the opening handshake (not before it)
///   ('message', string | ArrayBuffer)            — a text frame, or a binary frame as an ArrayBuffer
///   ('sent', null, byteCount)                    — a queued frame went out (bufferedAmount)
///   ('error', message)                           — "fail the WebSocket connection"
///   ('close', null, code, reason, wasClean)      — exactly once per socket
/// `send(id, data)` takes a string (text frame) or an ArrayBuffer / TypedArray / DataView
/// (binary frame, the view's bytes only). Until 2026-10-18 every frame was a string: a typed array
/// went out as its `toString()` ("1,2,-1,127") and a binary frame came back as UTF-8 text, so binary
/// protocols (Facebook Lite's gateway socket) never got past their first message.
@JeffJSHostActor
final class JeffJSWebSocketBridge {

    // MARK: - State

    private struct Socket {
        var task: URLSessionWebSocketTask
        /// Close code/reason the page asked for (`close()`), or nil.
        var requestedClose: (code: Int, reason: String)?
        var opened = false
    }

    private var nextID: Int = 1
    private var sockets: [Int: Socket] = [:]
    /// Stored callback JeffJSValues keyed by socket ID.
    /// These are JS functions that receive (type, data, code, reason, wasClean) events.
    private var callbacks: [Int: JeffJSValue] = [:]
    /// The page's cookie jar: the opening handshake carries its cookies for the
    /// socket URL (and nothing from URLSession's shared storage). Nil = legacy.
    var cookieJar: (any JeffJSCookieJar)?
    /// The document URL (SameSite: a cross-site socket gets no Strict/Lax cookies) and the handshake's `Origin`.
    var documentURL: URL?
    private weak var ctx: JeffJSContext?
    private let session: URLSession
    private let events: JeffJSWebSocketEvents

    var activeCount: Int { sockets.count }
    /// The browser's User-Agent for the opening handshake (the host's, so every
    /// request path sends one UA); nil = URLSession's default.
    var userAgent: String?

    /// Largest message accepted (URLSession's default is 1 MiB; WebKit has no small limit).
    nonisolated static let maximumMessageSize = 64 << 20

    // MARK: - Init

    init() {
        let events = JeffJSWebSocketEvents()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        self.events = events
        self.session = URLSession(configuration: .default, delegate: events, delegateQueue: queue)
        events.bridge = self
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: - Registration

    /// Registers `__nativeWebSocket` object on the JeffJS context's global scope
    /// with `connect`, `send`, and `close` methods.
    func register(on ctx: JeffJSContext) {
        self.ctx = ctx
        let global = ctx.getGlobalObject()
        let wsObj = ctx.newObject()

        // connect(url, protocols, callback) -> id
        ctx.setPropertyFunc(obj: wsObj, name: "connect", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.newInt32(0) }
            let url = args.count > 0 ? ctx.toSwiftString(args[0]) ?? "" : ""
            let protocols = args.count > 1 ? ctx.toSwiftString(args[1]) ?? "" : ""
            let callback = args.count > 2 ? args[2] : JeffJSValue.undefined
            let id = self.connect(url: url, protocols: protocols, callback: callback, ctx: ctx)
            return JeffJSValue.newFloat64(id)
        }, length: 3)

        // send(id, data): string → text frame, ArrayBuffer / view → binary frame. Returns the byte count.
        ctx.setPropertyFunc(obj: wsObj, name: "send", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            let id = args.count > 0 ? (ctx.toInt32(args[0]).map(Int.init) ?? 0) : 0
            let message = Self.outgoingMessage(ctx: ctx, args.count > 1 ? args[1] : .undefined)
            self.send(id: id, message: message)
            return JeffJSValue.newInt32(Int32(clamping: Self.byteCount(message)))
        }, length: 2)

        // close(id, code, reason)
        ctx.setPropertyFunc(obj: wsObj, name: "close", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            let id = args.count > 0 ? (ctx.toInt32(args[0]).map(Int.init) ?? 0) : 0
            let code = args.count > 1 ? (ctx.toInt32(args[1]).map(Int.init) ?? 1000) : 1000
            let reason = args.count > 2 ? ctx.toSwiftString(args[2]) ?? "" : ""
            self.close(id: id, code: code, reason: reason)
            return JeffJSValue.undefined
        }, length: 3)

        ctx.setPropertyStr(obj: global, name: "__nativeWebSocket", value: wsObj)
    }

    // MARK: - Frames

    /// The frame `send(data)` puts on the wire: binary for an ArrayBuffer / TypedArray / DataView
    /// (only the view's bytes), text for anything else (the polyfill has already stringified it).
    static func outgoingMessage(ctx: JeffJSContext, _ value: JeffJSValue) -> URLSessionWebSocketTask.Message {
        if let bytes = ctx.arrayBufferBytes(of: value) { return .data(Data(bytes)) }
        return .string(ctx.toSwiftString(value) ?? "")
    }

    /// The `message` event's data: a string for a text frame, a new ArrayBuffer for a binary one.
    static func incomingValue(ctx: JeffJSContext, _ message: URLSessionWebSocketTask.Message) -> JeffJSValue {
        switch message {
        case .string(let text): return ctx.newStringValue(text)
        case .data(let data): return ctx.newArrayBufferValue(bytes: [UInt8](data))
        @unknown default: return ctx.newStringValue("")
        }
    }

    /// Bytes a frame adds to `bufferedAmount` (UTF-8 length for text).
    nonisolated static func byteCount(_ message: URLSessionWebSocketTask.Message) -> Int {
        switch message {
        case .string(let text): return text.utf8.count
        case .data(let data): return data.count
        @unknown default: return 0
        }
    }

    // MARK: - Connect

    private func connect(url: String, protocols: String, callback: JeffJSValue, ctx: JeffJSContext) -> Double {
        guard let wsURL = URL(string: url) else { return 0 }
        let id = nextID
        nextID += 1

        // Store the callback (dup to prevent GC)
        callbacks[id] = callback.dupValue()

        var request = URLRequest(url: wsURL)
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        let protocolList = protocols.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !protocolList.isEmpty {
            request.setValue(protocolList.joined(separator: ", "),
                            forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        // RFC 6455 §4.1 step 8 / Fetch: a browser's handshake carries the document's origin.
        if let doc = documentURL, let scheme = doc.scheme, let host = doc.host,
           scheme == "http" || scheme == "https" {
            let port = doc.port.map { ":\($0)" } ?? ""
            request.setValue("\(scheme)://\(host)\(port)", forHTTPHeaderField: "Origin")
        }

        if let jar = cookieJar {
            request.httpShouldHandleCookies = false
            let docSite = documentURL.flatMap(JeffJSCookieParsing.site(of:))
            let sameSite = docSite == nil || JeffJSCookieParsing.site(of: wsURL) == docSite
            if let header = jar.cookieHeader(for: wsURL, sameSite: sameSite) {
                request.setValue(header, forHTTPHeaderField: "Cookie")
            }
        }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = Self.maximumMessageSize
        sockets[id] = Socket(task: task)
        events.register(task: task, id: id)
        task.resume()
        // `open` fires from the delegate once the handshake succeeded; the receive loop starts then.
        return Double(id)
    }

    // MARK: - Delegate events (hopped from the session's queue)

    fileprivate func didOpen(id: Int, protocol proto: String?) {
        guard var socket = sockets[id], !socket.opened, let ctx, let cb = callbacks[id] else { return }
        socket.opened = true
        sockets[id] = socket
        fireCallback(ctx: ctx, cb: cb, type: "open", data: ctx.newStringValue(proto ?? ""), code: nil, reason: "")
        receiveLoop(id: id)
    }

    fileprivate func didClose(id: Int, code: Int, reason: String) {
        finish(id: id, code: code, reason: reason, clean: true, error: nil)
    }

    fileprivate func didComplete(id: Int, error: Error?) {
        guard let socket = sockets[id] else { return }
        let task = socket.task
        if task.closeCode != .invalid {
            finish(id: id, code: task.closeCode.rawValue, reason: Self.reasonText(task.closeReason), clean: true, error: nil)
        } else if let requested = socket.requestedClose {
            finish(id: id, code: requested.code, reason: requested.reason, clean: true, error: nil)
        } else {
            finish(id: id, code: 1006, reason: "", clean: false, error: error?.localizedDescription ?? "connection closed")
        }
    }

    // MARK: - Receive Loop

    private func receiveLoop(id: Int) {
        guard let task = sockets[id]?.task else { return }
        task.receive { [weak self] result in
            Task { @JeffJSHostActor [weak self] in
                guard let self, let ctx = self.ctx, let cb = self.callbacks[id] else { return }
                switch result {
                case .success(let message):
                    // A message that arrives after close() was called is still delivered (§9.3.4:
                    // only `readyState` changes); after the close event nothing is.
                    self.fireCallback(ctx: ctx, cb: cb, type: "message", data: Self.incomingValue(ctx: ctx, message), code: nil, reason: nil)
                    self.receiveLoop(id: id)
                case .failure(let error):
                    self.didCompleteAfterReceiveFailure(id: id, error: error)
                }
            }
        }
    }

    private func didCompleteAfterReceiveFailure(id: Int, error: Error) {
        guard let socket = sockets[id] else { return }
        // The closing handshake ends the receive loop with an error too; the delegate's close
        // (code + reason) usually lands first, else it is read off the task here.
        if socket.task.closeCode != .invalid || socket.requestedClose != nil {
            didComplete(id: id, error: nil)
        } else {
            finish(id: id, code: 1006, reason: "", clean: false, error: error.localizedDescription)
        }
    }

    // MARK: - Send

    func send(id: Int, data: String) {
        send(id: id, message: .string(data))
    }

    func send(id: Int, message: URLSessionWebSocketTask.Message) {
        guard let socket = sockets[id], socket.requestedClose == nil else { return }
        let count = Self.byteCount(message)
        socket.task.send(message) { error in
            Task { @JeffJSHostActor [weak self] in
                guard let self, let ctx = self.ctx, let cb = self.callbacks[id] else { return }
                if let error {
                    self.finish(id: id, code: 1006, reason: "", clean: false, error: error.localizedDescription)
                } else {
                    self.fireCallback(ctx: ctx, cb: cb, type: "sent", data: nil, code: count, reason: nil)
                }
            }
        }
    }

    // MARK: - Close

    func close(id: Int, code: Int, reason: String) {
        guard var socket = sockets[id], socket.requestedClose == nil else { return }
        socket.requestedClose = (code, reason)
        sockets[id] = socket
        // Start the closing handshake. The close event fires from the delegate / task completion
        // (URLSessionWebSocketTask does not wait for the server's close frame, so a page-initiated
        // close reports the page's code and reason), or after 3 s if neither arrives.
        socket.task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure,
                           reason: reason.data(using: .utf8))
        Task { @JeffJSHostActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.sockets[id] != nil else { return }
            self.didComplete(id: id, error: nil)
        }
    }

    // MARK: - Close All

    func closeAll() {
        for (id, socket) in sockets {
            socket.task.cancel(with: .goingAway, reason: nil)
            cleanup(id: id)
        }
    }

    // MARK: - Helpers

    /// Fires `error` (when the connection failed) then `close`, once per socket, and forgets it.
    private func finish(id: Int, code: Int, reason: String, clean: Bool, error: String?) {
        guard sockets[id] != nil else { return }
        guard let ctx, let cb = callbacks[id] else { cleanup(id: id); return }
        // Two calls with the same table value: hold it across both
        // (the error handler may close every socket).
        cb.dupValue()
        if let error {
            fireCallback(ctx: ctx, cb: cb, type: "error", data: ctx.newStringValue(error), code: nil, reason: nil)
        }
        fireCallback(ctx: ctx, cb: cb, type: "close", data: nil, code: code, reason: reason, wasClean: clean)
        cleanup(id: id)
        cb.freeValue()
    }

    nonisolated static func reasonText(_ data: Data?) -> String {
        data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Invoke the JS callback with (type, data, code, reason, wasClean) arguments,
    /// matching the JSC bridge's callback signature. Takes ownership of `data`.
    private func fireCallback(ctx: JeffJSContext, cb: JeffJSValue, type: String,
                              data: JeffJSValue?, code: Int?, reason: String?, wasClean: Bool? = nil) {
        let typeArg = ctx.newStringValue(type)
        let dataArg = data ?? JeffJSValue.null
        let codeArg = code.map { JeffJSValue.newInt32(Int32(clamping: $0)) } ?? JeffJSValue.null
        let reasonArg = reason.map { ctx.newStringValue($0) } ?? JeffJSValue.null
        let cleanArg = wasClean.map { JeffJSValue.newBool($0) } ?? JeffJSValue.null
        // `cb` is borrowed from `callbacks`, which cleanup(id)/closeAll()
        // release: call retained so the running callback outlives that.
        let result = ctx.callRetained(cb, this: JeffJSValue.undefined,
                                      args: [typeArg, dataArg, codeArg, reasonArg, cleanArg])
        result.freeValue()
        typeArg.freeValue()
        dataArg.freeValue()
        reasonArg.freeValue()
        _ = ctx.rt.executePendingJobs()
    }

    private func cleanup(id: Int) {
        if let socket = sockets.removeValue(forKey: id) { events.unregister(task: socket.task) }
        if let cb = callbacks.removeValue(forKey: id) {
            // Free the duped callback value
            cb.freeValue()
        }
    }
}

// MARK: - URLSession delegate

/// The session delegate: maps tasks to socket IDs and hops the handshake / close events to the
/// bridge's actor (the session calls it on its own serial queue).
nonisolated final class JeffJSWebSocketEvents: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    weak var bridge: JeffJSWebSocketBridge?
    private let lock = NSLock()
    private var ids: [Int: Int] = [:]   // task identifier → socket id

    func register(task: URLSessionTask, id: Int) {
        lock.lock(); ids[task.taskIdentifier] = id; lock.unlock()
    }

    func unregister(task: URLSessionTask) {
        lock.lock(); ids.removeValue(forKey: task.taskIdentifier); lock.unlock()
    }

    private func socketID(_ task: URLSessionTask) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return ids[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        guard let id = socketID(webSocketTask) else { return }
        Task { @JeffJSHostActor [weak self] in self?.bridge?.didOpen(id: id, protocol: `protocol`) }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard let id = socketID(webSocketTask) else { return }
        let text = JeffJSWebSocketBridge.reasonText(reason)
        Task { @JeffJSHostActor [weak self] in self?.bridge?.didClose(id: id, code: closeCode.rawValue, reason: text) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = socketID(task) else { return }
        Task { @JeffJSHostActor [weak self] in self?.bridge?.didComplete(id: id, error: error) }
    }
}
