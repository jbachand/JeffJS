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
/// Usage:
/// ```swift
/// let bridge = JeffJSWebSocketBridge()
/// bridge.register(on: ctx)
/// ```
@MainActor
final class JeffJSWebSocketBridge {

    // MARK: - State

    private var nextID: Int = 1
    private var activeSockets: [Int: URLSessionWebSocketTask] = [:]
    /// Stored callback JeffJSValues keyed by socket ID.
    /// These are JS functions that receive (type, data, code, reason) events.
    private var callbacks: [Int: JeffJSValue] = [:]
    private weak var ctx: JeffJSContext?
    private let session: URLSession

    var activeCount: Int { activeSockets.count }

    // MARK: - Init

    init() {
        self.session = URLSession(configuration: .default)
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

        // send(id, data)
        ctx.setPropertyFunc(obj: wsObj, name: "send", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            let id = args.count > 0 ? (ctx.toInt32(args[0]).map(Int.init) ?? 0) : 0
            let data = args.count > 1 ? ctx.toSwiftString(args[1]) ?? "" : ""
            self.send(id: id, data: data)
            return JeffJSValue.undefined
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

    // MARK: - Connect

    private func connect(url: String, protocols: String, callback: JeffJSValue, ctx: JeffJSContext) -> Double {
        guard let wsURL = URL(string: url) else { return 0 }
        let id = nextID
        nextID += 1

        // Store the callback (dup to prevent GC)
        callbacks[id] = callback.dupValue()

        var request = URLRequest(url: wsURL)
        let protocolList = protocols.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !protocolList.isEmpty {
            request.setValue(protocolList.joined(separator: ", "),
                            forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }

        let task = session.webSocketTask(with: request)
        activeSockets[id] = task
        task.resume()

        // Fire open after connection establishes
        Task { @MainActor [weak self] in
            guard let self, let ctx = self.ctx, let cb = self.callbacks[id] else { return }
            self.fireCallback(ctx: ctx, cb: cb, type: "open", data: nil, code: nil, reason: nil)
            self.receiveLoop(id: id)
        }

        return Double(id)
    }

    // MARK: - Receive Loop

    private func receiveLoop(id: Int) {
        guard let task = activeSockets[id] else { return }
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, let ctx = self.ctx, let cb = self.callbacks[id] else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.fireCallback(ctx: ctx, cb: cb, type: "message", data: text, code: nil, reason: nil)
                    case .data(let data):
                        let text = String(data: data, encoding: .utf8) ?? ""
                        self.fireCallback(ctx: ctx, cb: cb, type: "message", data: text, code: nil, reason: nil)
                    @unknown default:
                        break
                    }
                    self.receiveLoop(id: id)
                case .failure(let error):
                    self.fireCallback(ctx: ctx, cb: cb, type: "error", data: error.localizedDescription, code: nil, reason: nil)
                    self.fireCallback(ctx: ctx, cb: cb, type: "close", data: nil, code: 1006, reason: error.localizedDescription)
                    self.cleanup(id: id)
                }
            }
        }
    }

    // MARK: - Send

    func send(id: Int, data: String) {
        guard let task = activeSockets[id] else { return }
        task.send(.string(data)) { error in
            if let error {
                Task { @MainActor [weak self] in
                    guard let self, let ctx = self.ctx, let cb = self.callbacks[id] else { return }
                    self.fireCallback(ctx: ctx, cb: cb, type: "error", data: error.localizedDescription, code: nil, reason: nil)
                }
            }
        }
    }

    // MARK: - Close

    func close(id: Int, code: Int, reason: String) {
        guard let task = activeSockets[id] else { return }
        task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure,
                    reason: reason.data(using: .utf8))
        Task { @MainActor [weak self] in
            guard let self, let ctx = self.ctx, let cb = self.callbacks[id] else { return }
            self.fireCallback(ctx: ctx, cb: cb, type: "close", data: nil, code: code, reason: reason)
            self.cleanup(id: id)
        }
    }

    // MARK: - Close All

    func closeAll() {
        for (id, task) in activeSockets {
            task.cancel(with: .goingAway, reason: nil)
            cleanup(id: id)
        }
    }

    // MARK: - Helpers

    /// Invoke the JS callback with (type, data, code, reason) arguments,
    /// matching the JSC bridge's callback signature.
    private func fireCallback(ctx: JeffJSContext, cb: JeffJSValue, type: String,
                              data: String?, code: Int?, reason: String?) {
        let typeArg = ctx.newStringValue(type)
        let dataArg = data.map { ctx.newStringValue($0) } ?? JeffJSValue.null
        let codeArg = code.map { JeffJSValue.newInt32(Int32($0)) } ?? JeffJSValue.null
        let reasonArg = reason.map { ctx.newStringValue($0) } ?? JeffJSValue.null
        _ = ctx.call(cb, this: JeffJSValue.undefined,
                     args: [typeArg, dataArg, codeArg, reasonArg])
        _ = ctx.rt.executePendingJobs()
    }

    private func cleanup(id: Int) {
        activeSockets.removeValue(forKey: id)
        if let cb = callbacks.removeValue(forKey: id) {
            // Free the duped callback value
            cb.freeValue()
        }
    }
}
