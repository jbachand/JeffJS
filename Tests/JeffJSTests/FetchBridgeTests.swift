// FetchBridgeTests.swift
// JeffJS — fetch/XHR bridge: binary bodies, redirects, CORS, credentials, abort.
//
// Everything runs against a tiny in-process HTTP/1.1 server (Network.framework
// NWListener on an ephemeral port). If no port can be bound the tests skip.
//
// Usage:
//   swift test --filter FetchBridgeTests

import XCTest
import Network
@testable import JeffJS

// MARK: - Tiny in-process HTTP server

/// Minimal HTTP/1.1 server: one request per connection, `Connection: close`.
final class TinyHTTPServer: @unchecked Sendable {

    struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]   // lowercase keys
        var body: [UInt8]
    }

    struct Response {
        var status: Int = 200
        var reason: String = "OK"
        var headers: [(String, String)] = []
        var body: [UInt8] = []
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "jeffjs.tinyhttp")
    private(set) var port: UInt16 = 0
    private let lock = NSLock()
    private var counters: [String: Int] = [:]

    func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counters[key] ?? 0 }
    private var beacons: [Request] = []
    /// Requests to `/beacon*` in arrival order (sendBeacon tests).
    var receivedBeacons: [Request] { lock.lock(); defer { lock.unlock() }; return beacons }
    private func bump(_ key: String) { lock.lock(); counters[key, default: 0] += 1; lock.unlock() }

    init?() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: .any) else { return nil }
        listener = l

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.signal()
            }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, port != 0 else { return nil }
    }

    func stop() { listener.cancel() }

    // MARK: connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: [])
    }

    private func receive(_ conn: NWConnection, buffer: [UInt8]) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(contentsOf: data) }
            if error != nil { conn.cancel(); return }

            if let request = Self.parse(buf) {
                self.bump(request.method + " " + request.path)
                let response = self.route(request)
                self.send(conn, response)
                return
            }
            if isComplete { conn.cancel(); return }
            self.receive(conn, buffer: buf)
        }
    }

    /// Parse a complete request, or nil when more bytes are needed.
    private static func parse(_ bytes: [UInt8]) -> Request? {
        let sep: [UInt8] = Array("\r\n\r\n".utf8)
        guard let headerEnd = find(sep, in: bytes) else { return nil }
        let headerText = String(decoding: bytes[0..<headerEnd], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0])
        let target = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<colon]).lowercased().trimmingCharacters(in: .whitespaces)
            let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[k] = headers[k].map { $0 + ", " + v } ?? v
        }

        let bodyStart = headerEnd + sep.count
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard bytes.count >= bodyStart + contentLength else { return nil }
        let body = Array(bytes[bodyStart..<(bodyStart + contentLength)])

        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            for pair in target[target.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                query[key] = value
            }
        }
        return Request(method: method, path: path, query: query, headers: headers, body: body)
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        for i in 0...(haystack.count - needle.count) where Array(haystack[i..<i+needle.count]) == needle {
            return i
        }
        return nil
    }

    private func send(_ conn: NWConnection, _ response: Response) {
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        for (k, v) in response.headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Array(head.utf8)
        out.append(contentsOf: response.body)
        conn.send(content: Data(out), completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: routes

    private func route(_ req: Request) -> Response {
        let origin = req.headers["origin"] ?? ""

        switch req.path {
        case "/echo":
            // Echo the body back with the request's content type.
            return Response(status: 200, reason: "OK", headers: [
                ("Content-Type", req.headers["content-type"] ?? "application/octet-stream"),
                ("X-Echo-Method", req.method),
                ("Access-Control-Allow-Origin", "*")
            ], body: req.body)

        case "/bin":
            return Response(status: 200, reason: "OK", headers: [
                ("Content-Type", "application/octet-stream"),
                ("Access-Control-Allow-Origin", "*")
            ], body: (0...255).map { UInt8($0) })

        case "/text":
            let text = req.query["t"] ?? "héllo — ✓"
            switch req.query["cs"] ?? "utf-8" {
            case "utf-16":
                var bytes: [UInt8] = [0xFF, 0xFE]   // UTF-16LE BOM
                bytes.append(contentsOf: Array(text.data(using: .utf16LittleEndian) ?? Data()))
                return Response(headers: [("Content-Type", "text/plain; charset=utf-16")], body: bytes)
            case "latin1":
                let bytes = Array(text.data(using: .windowsCP1252) ?? Data())
                return Response(headers: [("Content-Type", "text/plain; charset=iso-8859-1")], body: bytes)
            case "bom":
                var bytes: [UInt8] = [0xEF, 0xBB, 0xBF]
                bytes.append(contentsOf: Array(text.utf8))
                return Response(headers: [("Content-Type", "text/plain")], body: bytes)
            default:
                return Response(headers: [("Content-Type", "text/plain; charset=utf-8")],
                                body: Array(text.utf8))
            }

        case "/redirect":
            let to = req.query["to"] ?? "/bin"
            return Response(status: 302, reason: "Found",
                            headers: [("Location", to), ("Access-Control-Allow-Origin", "*")],
                            body: [])

        case "/cors":
            var headers: [(String, String)] = [("Content-Type", "text/plain")]
            switch req.query["allow"] ?? "" {
            case "*":       headers.append(("Access-Control-Allow-Origin", "*"))
            case "origin":  headers.append(("Access-Control-Allow-Origin", origin))
            default:        break   // deny: no ACAO at all
            }
            if req.query["creds"] == "1" {
                headers.append(("Access-Control-Allow-Credentials", "true"))
            }
            return Response(headers: headers, body: Array("cors-ok".utf8))

        case "/preflight":
            if req.method == "OPTIONS" {
                bump("preflight")
                return Response(status: 204, reason: "No Content", headers: [
                    ("Access-Control-Allow-Origin", origin),
                    ("Access-Control-Allow-Methods", "PUT, POST, DELETE"),
                    ("Access-Control-Allow-Headers", "x-custom, content-type"),
                    ("Access-Control-Max-Age", "60")
                ], body: [])
            }
            bump("preflight-actual")
            return Response(headers: [
                ("Content-Type", "text/plain"),
                ("Access-Control-Allow-Origin", origin)
            ], body: Array("method=\(req.method);custom=\(req.headers["x-custom"] ?? "")".utf8))

        case "/cookie":
            return Response(headers: [
                ("Content-Type", "text/plain"),
                ("Access-Control-Allow-Origin", origin),
                ("Access-Control-Allow-Credentials", "true")
            ], body: Array("cookie=\(req.headers["cookie"] ?? "")".utf8))

        case "/setcookie":
            // Sets an HttpOnly server cookie (and `c` when asked), echoes the Cookie header.
            var headers: [(String, String)] = [
                ("Content-Type", "text/plain"),
                ("Set-Cookie", "srv=1; Path=/; HttpOnly")
            ]
            if let extra = req.query["c"] { headers.append(("Set-Cookie", extra)) }
            return Response(headers: headers, body: Array("cookie=\(req.headers["cookie"] ?? "")".utf8))

        case "/redirect-setcookie":
            return Response(status: 302, reason: "Found",
                            headers: [("Location", "/cookie"), ("Set-Cookie", "hop=1; Path=/")],
                            body: [])

        case "/origin":
            return Response(headers: [
                ("Content-Type", "text/plain"),
                ("Access-Control-Allow-Origin", "*")
            ], body: Array("origin=\(origin)".utf8))

        case "/beacon", "/beacon-slow":
            lock.lock(); beacons.append(req); lock.unlock()
            if req.path == "/beacon-slow" { Thread.sleep(forTimeInterval: 1.5) }
            return Response(status: 204, reason: "No Content", headers: [("Set-Cookie", "after=1; Path=/")], body: [])

        case "/slow":
            Thread.sleep(forTimeInterval: 1.5)
            return Response(headers: [("Content-Type", "text/plain")], body: Array("slow".utf8))

        default:
            return Response(status: 404, reason: "Not Found",
                            headers: [("Content-Type", "text/plain"),
                                      ("Access-Control-Allow-Origin", "*")],
                            body: Array("not found".utf8))
        }
    }
}

// MARK: - Tests

final class FetchBridgeTests: XCTestCase {

    private var server: TinyHTTPServer!

    override func setUp() {
        super.setUp()
        server = TinyHTTPServer()
    }

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    private var base: String { "http://127.0.0.1:\(server.port)" }
    private var crossOrigin: String { "http://localhost:\(server.port)" }

    @MainActor
    private func makeEnvironment() -> JeffJSEnvironment {
        let scope = "jeffjs.fetchtest.\(UUID().uuidString)"
        return JeffJSEnvironment(configuration: .init(
            baseURL: URL(string: base + "/index.html")!,
            storageScope: scope))
    }

    /// Run `js` (which must eventually set `globalThis.__out` to a string),
    /// pumping the main actor until it appears.
    @MainActor
    @discardableResult
    private func runJS(_ env: JeffJSEnvironment, _ js: String,
                       timeout: TimeInterval = 15,
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

    private func skipIfNoServer() throws {
        try XCTSkipIf(server == nil, "could not bind a local port for the test HTTP server")
    }

    // MARK: binary

    @MainActor
    func testBinaryResponseBytes() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        let out = await runJS(env, """
        fetch('\(base)/bin').then(function(r){ return r.arrayBuffer(); }).then(function(buf){
          var u = new Uint8Array(buf);
          globalThis.__out = u.length + ':' + u[0] + ':' + u[1] + ':' + u[255];
        }).catch(function(e){ globalThis.__out = 'ERR ' + e; });
        """)
        XCTAssertEqual(out, "256:0:1:255")
    }

    @MainActor
    func testBinaryRequestEchoRoundTrip() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        let out = await runJS(env, """
        var src = new Uint8Array([0, 1, 127, 128, 254, 255]);
        fetch('\(base)/echo', { method: 'POST', body: src })
          .then(function(r){ return r.arrayBuffer(); })
          .then(function(buf){
            var u = new Uint8Array(buf);
            globalThis.__out = u.length + ':' + Array.prototype.join.call(u, ',');
          }).catch(function(e){ globalThis.__out = 'ERR ' + e; });
        """)
        XCTAssertEqual(out, "6:0,1,127,128,254,255")
    }

    @MainActor
    func testArrayBufferAndBlobBodies() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        let out = await runJS(env, """
        var ab = new Uint8Array([9, 8, 7]).buffer;
        fetch('\(base)/echo', { method: 'POST', body: ab })
          .then(function(r){ return r.arrayBuffer(); })
          .then(function(b){
            var u = new Uint8Array(b);
            return fetch('\(base)/echo', { method: 'POST', body: new Blob(['ab', new Uint8Array([0,255])], {type:'application/x-test'}) })
              .then(function(r2){ return r2.arrayBuffer().then(function(b2){
                 var u2 = new Uint8Array(b2);
                 globalThis.__out = Array.prototype.join.call(u, ',') + '|' +
                                    Array.prototype.join.call(u2, ',') + '|' +
                                    r2.headers.get('content-type');
              }); });
          }).catch(function(e){ globalThis.__out = 'ERR ' + e; });
        """)
        XCTAssertEqual(out, "9,8,7|97,98,0,255|application/x-test")
    }

    @MainActor
    func testTextDecodingCharsetAndBOM() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        let out = await runJS(env, """
        Promise.all([
          fetch('\(base)/text?cs=utf-16').then(function(r){ return r.text(); }),
          fetch('\(base)/text?cs=bom').then(function(r){ return r.text(); }),
          fetch('\(base)/text?cs=latin1&t=caf%C3%A9%20cr%C3%A8me').then(function(r){ return r.text(); })
        ]).then(function(v){ globalThis.__out = v.join('|'); })
          .catch(function(e){ globalThis.__out = 'ERR ' + e; });
        """)
        let expected = "héllo — ✓"
        let parts = out.components(separatedBy: "|")
        XCTAssertEqual(parts.count, 3, "got \(out)")
        XCTAssertEqual(parts.first, expected)
        XCTAssertEqual(parts.dropFirst().first, expected)
        XCTAssertEqual(parts.last, "café crème", "latin1 charset decode")
    }

    @MainActor
    func testMultipartUpload() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        let out = await runJS(env, """
        var fd = new FormData();
        fd.append('field', 'value1');
        fd.append('file', new Blob([new Uint8Array([1,2,3,0,255])], {type:'application/octet-stream'}), 'a.bin');
        fetch('\(base)/echo', { method: 'POST', body: fd })
          .then(function(r){
            var ct = r.headers.get('content-type') || '';
            return r.arrayBuffer().then(function(buf){
              var u = new Uint8Array(buf);
              var s = '';
              for (var i = 0; i < u.length; i++) s += String.fromCharCode(u[i]);
              globalThis.__out = JSON.stringify({
                ct: ct.split(';')[0],
                hasBoundary: ct.indexOf('boundary=') >= 0,
                field: s.indexOf('name="field"') >= 0,
                filename: s.indexOf('filename="a.bin"') >= 0,
                partType: s.indexOf('Content-Type: application/octet-stream') >= 0,
                rawBytes: s.indexOf(String.fromCharCode(1,2,3,0,255)) >= 0
              });
            });
          }).catch(function(e){ globalThis.__out = 'ERR ' + e; });
        """)
        XCTAssertTrue(out.contains("\"ct\":\"multipart/form-data\""), out)
        XCTAssertTrue(out.contains("\"hasBoundary\":true"), out)
        XCTAssertTrue(out.contains("\"field\":true"), out)
        XCTAssertTrue(out.contains("\"filename\":true"), out)
        XCTAssertTrue(out.contains("\"partType\":true"), out)
        XCTAssertTrue(out.contains("\"rawBytes\":true"), out)
    }

    /// The host app's own Blob/FormData polyfills use `parts` / `_entries`
    /// instead of `__blobParts` / `__formEntries`; both shapes are accepted.
    @MainActor
    func testHostAppBlobAndFormDataShapes() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        let out = await runJS(env, """
        var blobLike = { parts: ['ab', new Uint8Array([0, 255])], type: 'application/x-app', size: 4 };
        var formLike = { _entries: [{ name: 'f', value: 'v' }] };
        // A file part whose Blob uses the host app's `parts` field.
        var fileForm = { _entries: [{ name: 'file', filename: 'a.txt',
                                      value: { parts: ['hello'], type: 'text/plain', size: 5 } }] };
        var usp = new URLSearchParams({ a: '1', b: 'x y' });
        var acc = [];
        function post(body){ return fetch('\(base)/echo', { method: 'POST', body: body }); }
        post(blobLike)
          .then(function(r){ return r.arrayBuffer().then(function(b){
            acc.push(Array.prototype.join.call(new Uint8Array(b), ','));
            acc.push(r.headers.get('content-type'));
          }); })
          .then(function(){ return post(formLike).then(function(r2){ return r2.text().then(function(t){
            acc.push((t.indexOf('name="f"') >= 0) + ',' + (t.indexOf('v') >= 0));
            acc.push((r2.headers.get('content-type') || '').split(';')[0]);
          }); }); })
          .then(function(){ return post(fileForm).then(function(r3){ return r3.text().then(function(t3){
            acc.push((t3.indexOf('filename="a.txt"') >= 0) + ',' + (t3.indexOf('hello') >= 0));
          }); }); })
          .then(function(){ return post(usp).then(function(r4){ return r4.text().then(function(t4){
            acc.push(t4);
            acc.push(r4.headers.get('content-type') || '');
            globalThis.__out = acc.join('|');
          }); }); })
          .catch(function(e){ globalThis.__out = 'ERR ' + e; });
        """)
        XCTAssertEqual(out, "97,98,0,255|application/x-app|true,true|multipart/form-data"
                            + "|true,true|a=1&b=x+y|application/x-www-form-urlencoded;charset=UTF-8")
    }

    // MARK: redirects

    @MainActor
    func testRedirectFollow() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        let out = await runJS(env, """
        fetch('\(base)/redirect?to=/bin').then(function(r){
          return r.arrayBuffer().then(function(b){
            globalThis.__out = r.status + '|' + r.redirected + '|' + (r.url.indexOf('/bin') > 0) + '|' + b.byteLength;
          });
        }).catch(function(e){ globalThis.__out = 'ERR ' + e; });
        """)
        XCTAssertEqual(out, "200|true|true|256")
    }

    @MainActor
    func testRedirectManualIsOpaqueRedirect() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        let out = await runJS(env, """
        fetch('\(base)/redirect', { redirect: 'manual' }).then(function(r){
          globalThis.__out = r.status + '|' + r.type + '|' + r.ok;
        }).catch(function(e){ globalThis.__out = 'ERR ' + e; });
        """)
        XCTAssertEqual(out, "0|opaqueredirect|false")
    }

    @MainActor
    func testRedirectErrorRejects() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        let out = await runJS(env, """
        fetch('\(base)/redirect', { redirect: 'error' })
          .then(function(r){ globalThis.__out = 'RESOLVED ' + r.status; })
          .catch(function(e){ globalThis.__out = 'REJECTED ' + e.name; });
        """)
        XCTAssertEqual(out, "REJECTED TypeError")
    }

    // MARK: CORS

    @MainActor
    func testCORSAllowedCrossOrigin() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        let out = await runJS(env, """
        fetch('\(crossOrigin)/cors?allow=*').then(function(r){
          return r.text().then(function(t){ globalThis.__out = r.type + '|' + r.status + '|' + t; });
        }).catch(function(e){ globalThis.__out = 'ERR ' + e; });
        """)
        XCTAssertEqual(out, "cors|200|cors-ok")
    }

    @MainActor
    func testCORSDeniedCrossOrigin() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        let out = await runJS(env, """
        fetch('\(crossOrigin)/cors')
          .then(function(r){ globalThis.__out = 'RESOLVED ' + r.status; })
          .catch(function(e){ globalThis.__out = 'REJECTED ' + e.name; });
        """)
        XCTAssertEqual(out, "REJECTED TypeError")
    }

    @MainActor
    func testEnforceCORSFlagDisablesChecks() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        env.fetchBridge?.enforceCORS = false
        let out = await runJS(env, """
        fetch('\(crossOrigin)/cors').then(function(r){
          return r.text().then(function(t){ globalThis.__out = r.status + '|' + t; });
        }).catch(function(e){ globalThis.__out = 'ERR ' + e; });
        """)
        XCTAssertEqual(out, "200|cors-ok")
    }

    @MainActor
    func testSameOriginModeRejectsCrossOrigin() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        let out = await runJS(env, """
        fetch('\(crossOrigin)/cors?allow=*', { mode: 'same-origin' })
          .then(function(r){ globalThis.__out = 'RESOLVED'; })
          .catch(function(e){ globalThis.__out = 'REJECTED ' + e.name; });
        """)
        XCTAssertEqual(out, "REJECTED TypeError")
    }

    @MainActor
    func testNoCorsGivesOpaqueResponseButSendsRequest() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        let before = server.count("GET /cors")
        let out = await runJS(env, """
        fetch('\(crossOrigin)/cors', { mode: 'no-cors' }).then(function(r){
          return r.text().then(function(t){
            globalThis.__out = r.type + '|' + r.status + '|' + r.ok + '|len=' + t.length;
          });
        }).catch(function(e){ globalThis.__out = 'ERR ' + e; });
        """)
        XCTAssertEqual(out, "opaque|0|false|len=0")
        XCTAssertEqual(server.count("GET /cors"), before + 1, "no-cors must still send the request")
    }

    @MainActor
    func testPreflightForNonSimpleRequestAndCache() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        let out = await runJS(env, """
        function go(){ return fetch('\(crossOrigin)/preflight', {
            method: 'PUT', headers: { 'X-Custom': 'yes' }, body: 'data'
          }).then(function(r){ return r.text(); }); }
        go().then(function(a){ return go().then(function(b){ globalThis.__out = a + '||' + b; }); })
            .catch(function(e){ globalThis.__out = 'ERR ' + e; });
        """)
        XCTAssertEqual(out, "method=PUT;custom=yes||method=PUT;custom=yes")
        XCTAssertEqual(server.count("preflight"), 1, "the second request must reuse the cached preflight")
        XCTAssertEqual(server.count("preflight-actual"), 2)
    }

    @MainActor
    func testOriginHeaderIsSent() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        let out = await runJS(env, """
        fetch('\(crossOrigin)/origin').then(function(r){ return r.text(); })
          .then(function(t){ globalThis.__out = t; })
          .catch(function(e){ globalThis.__out = 'ERR ' + e; });
        """)
        XCTAssertEqual(out, "origin=\(base)")
    }

    // MARK: sendBeacon (W3C Beacon §3.2)

    @MainActor
    private func waitForBeacons(_ n: Int, timeout: TimeInterval = 10) async -> [TinyHTTPServer.Request] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let got = server.receivedBeacons
            if got.count >= n { return got }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return server.receivedBeacons
    }

    /// POST, the body's Content-Type, credentials "include" (a cross-origin cookie from the
    /// page's jar), `Origin`, no-cors for a safelisted type, nothing exposed.
    @MainActor
    func testSendBeaconPostsBodyWithCredentials() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        env.cookieJar?.store(setCookieLines: ["sid=abc123; Path=/"], for: URL(string: crossOrigin + "/")!)
        let out = await runJS(env, """
        var p = new URLSearchParams(); p.append('a', '1'); p.append('b', 'two words');
        globalThis.__out = [navigator.sendBeacon('\(crossOrigin)/beacon?k=text', 'hi \\u2713'),
                            navigator.sendBeacon('\(crossOrigin)/beacon?k=usp', p),
                            navigator.sendBeacon('\(crossOrigin)/beacon?k=none'),
                            navigator.sendBeacon.length].join(',');
        """)
        XCTAssertEqual(out, "true,true,true,1")
        let got = await waitForBeacons(3)
        XCTAssertEqual(got.count, 3)
        guard let text = got.first(where: { $0.query["k"] == "text" }),
              let usp = got.first(where: { $0.query["k"] == "usp" }),
              let none = got.first(where: { $0.query["k"] == "none" }) else { return XCTFail("missing beacons \(got.map(\.query))") }
        XCTAssertEqual(text.method, "POST")
        XCTAssertEqual(text.headers["content-type"], "text/plain;charset=UTF-8")
        XCTAssertEqual(String(decoding: text.body, as: UTF8.self), "hi \u{2713}")
        XCTAssertTrue((text.headers["cookie"] ?? "").contains("sid=abc123"), "credentials include: \(text.headers)")
        XCTAssertEqual(text.headers["origin"], base)
        XCTAssertEqual(usp.headers["content-type"], "application/x-www-form-urlencoded;charset=UTF-8")
        XCTAssertEqual(String(decoding: usp.body, as: UTF8.self), "a=1&b=two+words")
        XCTAssertNil(none.headers["content-type"])
        XCTAssertTrue(none.body.isEmpty)
    }

    /// TypeErrors for bad URLs / schemes / no arguments; false past the 64 KiB keepalive quota
    /// (one body over it, or one that does not fit next to a body still in flight).
    @MainActor
    func testSendBeaconErrorsAndKeepaliveQuota() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        let out = await runJS(env, """
        function t(f) { try { return String(f()); } catch (e) { return e.name; } }
        function s(n) { var x = ''; while (x.length < n) x += 'abcdefghij'; return x.slice(0, n); }
        globalThis.__out = [t(function() { return navigator.sendBeacon(); }),
                            t(function() { return navigator.sendBeacon('ftp://example.com/'); }),
                            t(function() { return navigator.sendBeacon('http://[::1'); }),
                            t(function() { return navigator.sendBeacon('\(base)/beacon?k=over', s(65537)); }),
                            t(function() { return navigator.sendBeacon('\(base)/beacon-slow?k=a', s(40000)); }),
                            t(function() { return navigator.sendBeacon('\(base)/beacon?k=b', s(30000)); }),
                            t(function() { return navigator.sendBeacon('\(base)/beacon?k=c', s(20000)); })].join(',');
        """)
        XCTAssertEqual(out, "TypeError,TypeError,TypeError,false,true,false,true")
        let got = await waitForBeacons(2)
        XCTAssertEqual(Set(got.compactMap { $0.query["k"] }), ["a", "c"])
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, env.fetchBridge?.keepaliveInflightBytes != 0 { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(env.fetchBridge?.keepaliveInflightBytes, 0, "the quota is given back when the requests finish")
    }

    /// A beacon is not cancelled by the navigation teardown (`cancelAll`), unlike a fetch.
    @MainActor
    func testSendBeaconSurvivesCancelAll() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        let out = await runJS(env, """
        fetch('\(base)/beacon-slow?k=fetch').catch(function() {});
        globalThis.__out = String(navigator.sendBeacon('\(base)/beacon-slow?k=beacon', 'bye'));
        """)
        XCTAssertEqual(out, "true")
        env.fetchBridge?.cancelAll()
        let got = await waitForBeacons(1)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(server.receivedBeacons.compactMap { $0.query["k"] }, ["beacon"], "got \(got.map(\.query))")
    }

    // MARK: credentials

    @MainActor
    func testCredentialsIncludeSendsCookiesCrossOrigin() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        // The target host's cookie, in this page's jar (partition).
        env.cookieJar?.store(setCookieLines: ["sid=abc123; Path=/"], for: URL(string: crossOrigin + "/")!)
        let out = await runJS(env, """
        Promise.all([
          fetch('\(crossOrigin)/cookie', { credentials: 'include' }).then(function(r){ return r.text(); }),
          fetch('\(crossOrigin)/cookie?x=1', { credentials: 'omit' }).then(function(r){ return r.text(); })
        ]).then(function(v){ globalThis.__out = v.join('||'); })
          .catch(function(e){ globalThis.__out = 'ERR ' + e; });
        """)
        let parts = out.components(separatedBy: "||")
        XCTAssertEqual(parts.count, 2, out)
        XCTAssertTrue(parts[0].contains("sid=abc123"), "credentials:include should send cookies — got \(parts[0])")
        XCTAssertFalse(parts[1].contains("sid=abc123"), "credentials:omit must not send cookies — got \(parts[1])")
    }

    /// One jar: a server HttpOnly cookie and a script cookie are both sent
    /// (an explicit Cookie header used to replace URLSession's stored ones),
    /// document.cookie sees only the script one, max-age=0 deletes it.
    @MainActor
    func testServerAndScriptCookiesShareOneJar() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        let out = await runJS(env, """
        fetch('/setcookie').then(function(r){ return r.text(); }).then(function(first){
          var headersSeen = '';
          document.cookie = 'js=1';
          var dc1 = document.cookie;
          return fetch('/cookie').then(function(r){ return r.text(); }).then(function(second){
            document.cookie = 'js=1; max-age=0';
            var dc2 = document.cookie;
            return fetch('/cookie').then(function(r){ return r.text(); }).then(function(third){
              globalThis.__out = [first, dc1, second, dc2, third].join('||');
            });
          });
        }).catch(function(e){ globalThis.__out = 'ERR ' + e; });
        """)
        let parts = out.components(separatedBy: "||")
        XCTAssertEqual(parts.count, 5, out)
        guard parts.count == 5 else { return }
        XCTAssertEqual(parts[0], "cookie=")
        XCTAssertEqual(parts[1], "js=1", "document.cookie must not show the HttpOnly srv cookie")
        let sent = Set(parts[2].dropFirst("cookie=".count).components(separatedBy: "; "))
        XCTAssertEqual(sent, ["srv=1", "js=1"], parts[2])
        XCTAssertEqual(parts[3], "")
        XCTAssertEqual(parts[4], "cookie=srv=1")
    }

    /// Set-Cookie on a followed redirect is stored and sent on the next hop;
    /// the Set-Cookie header itself is not exposed to script.
    @MainActor
    func testRedirectSetCookieIsStoredAndSent() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        let out = await runJS(env, """
        fetch('/redirect-setcookie').then(function(r){
          return r.text().then(function(t){ globalThis.__out = t + '||' + r.headers.get('set-cookie') + '||' + document.cookie; });
        }).catch(function(e){ globalThis.__out = 'ERR ' + e; });
        """)
        XCTAssertEqual(out, "cookie=hop=1||null||hop=1")
    }

    /// A `document.cookie` read before the fetch (the getter's cached string)
    /// does not survive the response's Set-Cookie: the next read shows it.
    @MainActor
    func testDocumentCookieReadAfterResponseSetCookie() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        let out = await runJS(env, """
        document.cookie = 'pre=1; path=/';
        var before = document.cookie;
        fetch('/setcookie?c=' + encodeURIComponent('vis=1; Path=/')).then(function(r){ return r.text(); }).then(function(t){
          globalThis.__out = [before, document.cookie, document.cookie, t].join('||');
        }).catch(function(e){ globalThis.__out = 'ERR ' + e; });
        """)
        XCTAssertEqual(out, "pre=1||pre=1; vis=1||pre=1; vis=1||cookie=pre=1")
    }

    /// credentials: 'omit' neither sends nor stores cookies.
    @MainActor
    func testCredentialsOmitDoesNotStore() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        let out = await runJS(env, """
        fetch('/setcookie?c=' + encodeURIComponent('vis=1; Path=/'), { credentials: 'omit' })
          .then(function(){ globalThis.__out = 'dc=' + document.cookie; })
          .catch(function(e){ globalThis.__out = 'ERR ' + e; });
        """)
        XCTAssertEqual(out, "dc=")
    }

    // MARK: abort

    @MainActor
    func testAbortSignalRejectsWithAbortError() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        let out = await runJS(env, """
        var c = new AbortController();
        fetch('\(base)/slow', { signal: c.signal })
          .then(function(r){ globalThis.__out = 'RESOLVED ' + r.status; })
          .catch(function(e){ globalThis.__out = 'REJECTED ' + e.name; });
        c.abort();
        """)
        XCTAssertEqual(out, "REJECTED AbortError")
    }

    // MARK: XHR

    @MainActor
    func testXHRResponseTypes() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        let out = await runJS(env, """
        var x = new XMLHttpRequest();
        x.open('GET', '\(base)/bin');
        x.responseType = 'arraybuffer';
        x.onload = function(){
          var u = new Uint8Array(x.response);
          var y = new XMLHttpRequest();
          y.open('POST', '\(base)/echo');
          y.setRequestHeader('Content-Type', 'text/plain');
          y.onload = function(){
            globalThis.__out = x.status + '|' + u.length + '|' + u[255] + '|' +
                               y.responseText + '|' + (y.getResponseHeader('x-echo-method') || '');
          };
          y.send('hello');
        };
        x.send();
        """)
        XCTAssertEqual(out, "200|256|255|hello|POST")
    }

    // MARK: leak scan

    /// 200 sequential fetches; with JEFFJS_TRACK_RC=1 the atexit refcount
    /// report must not grow with the loop.
    @MainActor
    func testTwoHundredFetchesComplete() async throws {
        try skipIfNoServer()
        let env = makeEnvironment()
        // JEFFJS_FETCH_LOOP lets the refcount scan compare two loop sizes.
        let iterations = Int(ProcessInfo.processInfo.environment["JEFFJS_FETCH_LOOP"] ?? "") ?? 200
        // JEFFJS_FETCH_MODE=text runs the same loop through the text path only,
        // which the pre-bytes bridge also supports (used for A/B leak scans).
        let textOnly = ProcessInfo.processInfo.environment["JEFFJS_FETCH_MODE"] == "text"
        let out = await runJS(env, """
        globalThis.__n = 0;
        function step(){
          if (globalThis.__n >= \(iterations)) { globalThis.__out = 'done:' + globalThis.__n; return; }
          \(textOnly
            ? "fetch('\(base)/text?t=x').then(function(r){ return r.text(); }).then(function(t){ if (t !== 'x') { globalThis.__out = 'MISMATCH at ' + globalThis.__n; return; } globalThis.__n++; step(); })"
            : """
          fetch('\(base)/echo', { method: 'POST', body: new Uint8Array([globalThis.__n & 255]) })
            .then(function(r){ return r.arrayBuffer(); })
            .then(function(b){
              if (new Uint8Array(b)[0] !== (globalThis.__n & 255)) { globalThis.__out = 'MISMATCH at ' + globalThis.__n; return; }
              globalThis.__n++;
              step();
            })
          """)
            .catch(function(e){ globalThis.__out = 'ERR ' + e; });
        }
        step();
        """, timeout: 120)
        XCTAssertEqual(out, "done:\(iterations)")
        XCTAssertEqual(env.fetchBridge?.activeCount, 0, "every request must be retired")
        // Tear the runtime down so a JEFFJS_TRACK_RC=1 run reports what the
        // fetch path actually retains past teardown (should not scale with the
        // loop size).
        env.teardown()
    }
}
