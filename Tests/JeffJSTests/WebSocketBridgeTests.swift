// WebSocketBridgeTests.swift
// JeffJS — `__nativeWebSocket` (JeffJSWebSocketBridge): binary frames, handshake-timed `open`,
// one `close` with the closing handshake's code / reason.
//
// Regression (Facebook Lite web, 2026-10-18): every frame was a string — `send(new Int8Array(…))`
// put "1,2,-1,127" on the wire and a binary frame came back as UTF-8 text — and `open` fired
// before the handshake. Runs against an in-process WebSocket echo server (Network.framework
// NWListener + NWProtocolWebSocket on an ephemeral port); skips if no port can be bound.
//
// Usage:
//   swift test --filter WebSocketBridgeTests

import XCTest
import Network
@testable import JeffJS

/// Echo server: every text/binary message is sent back with the same opcode; a client close is
/// answered with close code 4001 reason "bye" (so the test sees the server's close frame).
final class TinyWebSocketEchoServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "jeffjs.tinyws")
    private(set) var port: UInt16 = 0
    private var connections: [NWConnection] = []

    init?() {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: .any) else { return nil }
        listener = l
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.port = self?.listener.port?.rawValue ?? 0; ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.connections.append(conn)
            conn.start(queue: self.queue)
            self.receive(conn)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        if port == 0 { listener.cancel(); return nil }
    }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil,
                  let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata else { return }
            switch meta.opcode {
            case .text, .binary:
                let reply = NWProtocolWebSocket.Metadata(opcode: meta.opcode)
                let ctx = NWConnection.ContentContext(identifier: "echo", metadata: [reply])
                conn.send(content: data ?? Data(), contentContext: ctx, isComplete: true, completion: .idempotent)
                self.receive(conn)
            case .close:
                let reply = NWProtocolWebSocket.Metadata(opcode: .close)
                reply.closeCode = .privateCode(4001)
                let ctx = NWConnection.ContentContext(identifier: "close", metadata: [reply])
                conn.send(content: Data("bye".utf8), contentContext: ctx, isComplete: true,
                          completion: .contentProcessed { _ in conn.cancel() })
            default:
                self.receive(conn)
            }
        }
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
    }
}

final class WebSocketBridgeTests: XCTestCase {

    private var server: TinyWebSocketEchoServer!

    override func setUp() {
        super.setUp()
        server = TinyWebSocketEchoServer()
    }

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    @JeffJSHostActor
    private func makeEnvironment() -> JeffJSEnvironment {
        JeffJSEnvironment(configuration: .init(
            baseURL: URL(string: "http://127.0.0.1/index.html")!,
            storageScope: "jeffjs.wstest.\(UUID().uuidString)"))
    }

    /// Runs `js`, then pumps until `globalThis.__out` is a non-empty string.
    @JeffJSHostActor
    private func runJS(_ env: JeffJSEnvironment, _ js: String, timeout: TimeInterval = 15,
                       file: StaticString = #filePath, line: UInt = #line) async -> String {
        switch env.eval("globalThis.__out = undefined;\n" + js) {
        case .exception(let msg):
            XCTFail("JS threw: \(msg)", file: file, line: line)
            return ""
        case .success: break
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            env.drainJobs()
            if case .success(let s) = env.eval("typeof globalThis.__out === 'string' ? globalThis.__out : ''"),
               let s, !s.isEmpty, s != "undefined" {
                return s
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for __out", file: file, line: line)
        return ""
    }

    private var url: String { "ws://127.0.0.1:\(server.port)/ws" }

    /// A recorder over the raw bridge: every callback is logged as one string; binary data as
    /// `AB[<bytes>]`, so the log shows what the page would get.
    private func recorder(_ body: String) -> String {
        """
        var log = [];
        function show(d) {
          if (d instanceof ArrayBuffer) return 'AB[' + Array.prototype.join.call(new Uint8Array(d), ',') + ']';
          return typeof d === 'string' ? JSON.stringify(d) : String(d);
        }
        var id = __nativeWebSocket.connect('\(url)', '', function(type, data, code, reason, wasClean) {
          if (type === 'sent') return;
          log.push(type + (data === null ? '' : ' ' + show(data))
                   + (type === 'close' ? ' ' + code + ' ' + JSON.stringify(reason) + ' ' + wasClean : ''));
          \(body)
        });
        log.push('connected');
        """
    }

    // The bridge sends a typed array's bytes (its view only) as one binary frame and hands a binary
    // frame back as an ArrayBuffer; strings stay text frames.
    @JeffJSHostActor
    func testBinaryFramesRoundTripAsArrayBuffers() async throws {
        try XCTSkipIf(server == nil, "could not bind a local port for the WebSocket server")
        let env = makeEnvironment()
        let out = await runJS(env, recorder("""
          if (type === 'open') {
            __nativeWebSocket.send(id, new Int8Array([1, 2, -1, 127]));
            var big = new Uint8Array([9, 9, 7, 8, 9]);
            __nativeWebSocket.send(id, new Uint8Array(big.buffer, 2, 3));
            __nativeWebSocket.send(id, new DataView(new Uint8Array([5, 6]).buffer));
            __nativeWebSocket.send(id, 'hi');
          }
          if (log.length === 6) globalThis.__out = log.join(' | ');
        """))
        XCTAssertEqual(out, #"connected | open "" | message AB[1,2,255,127] | message AB[7,8,9] | message AB[5,6] | message "hi""#)
    }

    // `open` waits for the handshake (nothing before `connect` returns), and close() ends with one
    // clean `close`. URLSessionWebSocketTask.cancel(with:) does not wait for the server's close frame,
    // so the event carries the code/reason the page sent (WebKit reports the server's echo, which an
    // echoing server makes the same code).
    @JeffJSHostActor
    func testOpenAfterHandshakeAndOneCloseWithServerCode() async throws {
        try XCTSkipIf(server == nil, "could not bind a local port for the WebSocket server")
        let env = makeEnvironment()
        let out = await runJS(env, recorder("""
          if (type === 'open') __nativeWebSocket.close(id, 1000, 'done');
          if (type === 'close') setTimeout(function() { globalThis.__out = log.join(' | '); }, 200);
        """))
        XCTAssertEqual(out, #"connected | open "" | close 1000 "done" true"#)
    }

    // A refused connection is "fail the WebSocket connection": error, then close 1006 not clean.
    @JeffJSHostActor
    func testRefusedConnectionFailsWith1006() async throws {
        try XCTSkipIf(server == nil, "could not bind a local port for the WebSocket server")
        let port = server.port
        server.stop()
        let env = makeEnvironment()
        let out = await runJS(env, """
        var log = [];
        __nativeWebSocket.connect('ws://127.0.0.1:\(port)/ws', '', function(type, data, code, reason, wasClean) {
          log.push(type + (type === 'close' ? ' ' + code + ' ' + wasClean : ''));
          if (type === 'close') globalThis.__out = log.join(' | ');
        });
        """)
        XCTAssertEqual(out, "error | close 1006 false")
    }
}
