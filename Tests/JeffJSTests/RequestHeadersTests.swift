// RequestHeadersTests.swift
// JeffJS — Referer (Referrer Policy) and Fetch Metadata (`Sec-Fetch-*`) request
// headers: the pure helper (`JeffJSRequestHeaders`) and fetch()/XHR end to end
// against a loopback server that echoes the request headers as JSON.
//
// Usage:
//   swift test --filter RequestHeadersTests

import XCTest
import Network
@testable import JeffJS

final class RequestHeadersTests: XCTestCase {

    private func u(_ s: String) -> URL { URL(string: s)! }

    private func referer(_ source: String, _ target: String, _ policy: JeffJSReferrerPolicy) -> String? {
        JeffJSRequestHeaders.referrerValue(source: u(source), target: u(target), policy: policy)
    }

    // MARK: Referrer Policy §8.3 — every policy × same-origin / cross-origin / downgrade

    func testEveryPolicyAgainstSameOriginCrossOriginAndDowngrade() {
        let page = "https://www.example.com/a/b.html?q=1"
        let same = "https://www.example.com/api"
        let cross = "https://cdn.other.net/x.js"
        let down = "http://www.example.com/insecure"
        let full = page
        let origin = "https://www.example.com/"
        // policy: (same-origin, cross-origin https, https→http)
        let table: [(JeffJSReferrerPolicy, String?, String?, String?)] = [
            (.empty,                        full, origin, nil),
            (.strictOriginWhenCrossOrigin,  full, origin, nil),
            (.noReferrer,                   nil,  nil,    nil),
            (.noReferrerWhenDowngrade,      full, full,   nil),
            (.sameOrigin,                   full, nil,    nil),
            (.origin,                       origin, origin, origin),
            (.strictOrigin,                 origin, origin, nil),
            (.originWhenCrossOrigin,        full, origin, origin),
            (.unsafeURL,                    full, full,   full),
        ]
        for (policy, s, c, d) in table {
            XCTAssertEqual(referer(page, same, policy), s, "\(policy.rawValue) same-origin")
            XCTAssertEqual(referer(page, cross, policy), c, "\(policy.rawValue) cross-origin")
            XCTAssertEqual(referer(page, down, policy), d, "\(policy.rawValue) downgrade")
        }
    }

    func testHTTPPageToHTTPSIsNotADowngrade() {
        XCTAssertEqual(referer("http://example.com/p", "https://example.com/p", .empty), "http://example.com/")
        XCTAssertEqual(referer("http://example.com/p", "http://other.org/", .strictOrigin), "http://example.com/")
        XCTAssertEqual(referer("http://example.com/p", "http://example.com/q", .empty), "http://example.com/p")
    }

    func testReferrerIsStrippedOfCredentialsFragmentAndDefaultPort() {
        let src = "https://user:pw@Example.com:443/path/p.html?x=1#section"
        XCTAssertEqual(referer(src, "https://example.com/y", .unsafeURL), "https://example.com/path/p.html?x=1")
        XCTAssertEqual(referer(src, "https://example.org/y", .empty), "https://example.com/")
        XCTAssertEqual(referer("https://example.com:8443/p", "https://example.org/", .empty), "https://example.com:8443/")
        XCTAssertEqual(referer("https://example.com", "https://example.com/y", .unsafeURL), "https://example.com/")
    }

    func testNonHTTPReferrerSourcesSendNothing() {
        XCTAssertNil(referer("file:///tmp/fixture/index.html", "https://example.com/", .unsafeURL))
        XCTAssertNil(referer("about:blank", "https://example.com/", .unsafeURL))
        XCTAssertNil(referer("data:text/html,hi", "https://example.com/", .unsafeURL))
    }

    func testLongReferrerIsCutToItsOrigin() {
        let long = "https://example.com/p?" + String(repeating: "a", count: 5000)
        XCTAssertEqual(referer(long, "https://example.com/q", .unsafeURL), "https://example.com/")
    }

    // MARK: Policy parsing

    func testPolicyParsing() {
        XCTAssertEqual(JeffJSReferrerPolicy(token: "No-Referrer"), .noReferrer)
        XCTAssertNil(JeffJSReferrerPolicy(token: "bogus"))
        XCTAssertEqual(JeffJSReferrerPolicy.fromHeader("unsafe-url, bogus, origin"), .origin)
        XCTAssertEqual(JeffJSReferrerPolicy.fromHeader("same-origin, bogus"), .sameOrigin)
        XCTAssertNil(JeffJSReferrerPolicy.fromHeader("bogus"))
        XCTAssertEqual(JeffJSReferrerPolicy.fromMetaContent("NEVER"), .noReferrer)
        XCTAssertEqual(JeffJSReferrerPolicy.fromMetaContent("always"), .unsafeURL)
        XCTAssertEqual(JeffJSReferrerPolicy.fromMetaContent("default"), .strictOriginWhenCrossOrigin)
        XCTAssertEqual(JeffJSReferrerPolicy.fromMetaContent("origin-when-crossorigin"), .originWhenCrossOrigin)
        XCTAssertEqual(JeffJSReferrerPolicy.fromMetaContent(" Origin "), .origin)
        XCTAssertNil(JeffJSReferrerPolicy.fromMetaContent(""))
        XCTAssertNil(JeffJSReferrerPolicy.fromMetaContent("nope"))
        XCTAssertEqual(JeffJSReferrerPolicy.effective(request: .empty, document: .empty), .strictOriginWhenCrossOrigin)
        XCTAssertEqual(JeffJSReferrerPolicy.effective(request: .empty, document: .origin), .origin)
        XCTAssertEqual(JeffJSReferrerPolicy.effective(request: .unsafeURL, document: .origin), .unsafeURL)
    }

    func testFetchInitReferrer() {
        let client = u("https://a.example/page")
        XCTAssertEqual(JeffJSRequestReferrer.fromInit(nil, baseURL: client, clientURL: client), .client)
        XCTAssertEqual(JeffJSRequestReferrer.fromInit("", baseURL: client, clientURL: client), .noReferrer)
        XCTAssertEqual(JeffJSRequestReferrer.fromInit("about:client", baseURL: client, clientURL: client), .client)
        XCTAssertEqual(JeffJSRequestReferrer.fromInit("/other?x", baseURL: client, clientURL: client),
                       .url(u("https://a.example/other?x")))
        // A cross-origin referrer URL falls back to the client (Fetch, Request constructor).
        XCTAssertEqual(JeffJSRequestReferrer.fromInit("https://evil.example/", baseURL: client, clientURL: client), .client)
    }

    // MARK: Sites

    func testRegistrableDomain() {
        typealias H = JeffJSRequestHeaders
        XCTAssertEqual(H.registrableDomain("www.apple.com"), "apple.com")
        XCTAssertEqual(H.registrableDomain("images.apple.com"), "apple.com")
        XCTAssertEqual(H.registrableDomain("apple.com"), "apple.com")
        XCTAssertEqual(H.registrableDomain("www.bbc.co.uk"), "bbc.co.uk")
        XCTAssertNil(H.registrableDomain("co.uk"))
        XCTAssertEqual(H.registrableDomain("user.github.io"), "user.github.io")
        XCTAssertNil(H.registrableDomain("127.0.0.1"))
        XCTAssertNil(H.registrableDomain("localhost"))
        XCTAssertNil(H.registrableDomain("::1"))
    }

    func testSecFetchSiteClassification() {
        typealias H = JeffJSRequestHeaders
        let doc = u("https://www.apple.com/iphone/")
        XCTAssertEqual(H.fetchSite(initiator: doc, urls: [u("https://www.apple.com/x.js")]), "same-origin")
        XCTAssertEqual(H.fetchSite(initiator: doc, urls: [u("https://images.apple.com/a.png")]), "same-site")
        XCTAssertEqual(H.fetchSite(initiator: doc, urls: [u("https://www.apple.com:8443/a")]), "same-site")
        XCTAssertEqual(H.fetchSite(initiator: doc, urls: [u("https://cdn.example.net/a")]), "cross-site")
        XCTAssertEqual(H.fetchSite(initiator: doc, urls: [u("https://a.github.io/")]), "cross-site")
        XCTAssertEqual(H.fetchSite(initiator: u("https://a.github.io/"), urls: [u("https://b.github.io/")]), "cross-site")
        XCTAssertEqual(H.fetchSite(initiator: u("https://www.bbc.co.uk/"), urls: [u("https://static.bbc.co.uk/")]), "same-site")
        XCTAssertEqual(H.fetchSite(initiator: u("https://bbc.co.uk/"), urls: [u("https://itv.co.uk/")]), "cross-site")
        // Schemeful: http and https of one host are not the same site.
        XCTAssertEqual(H.fetchSite(initiator: u("http://www.apple.com/"), urls: [u("https://www.apple.com/")]), "cross-site")
        // A file: document has an opaque origin.
        XCTAssertEqual(H.fetchSite(initiator: u("file:///tmp/index.html"), urls: [u("https://www.apple.com/")]), "cross-site")
        // Redirect chain: the worst hop wins.
        XCTAssertEqual(H.fetchSite(initiator: doc, urls: [u("https://cdn.example.net/r"), u("https://www.apple.com/final")]), "cross-site")
        XCTAssertEqual(H.fetchSite(initiator: doc, urls: [u("https://images.apple.com/r"), u("https://www.apple.com/final")]), "same-site")
    }

    func testPotentiallyTrustworthy() {
        typealias H = JeffJSRequestHeaders
        XCTAssertTrue(H.isPotentiallyTrustworthy(u("https://example.com/")))
        XCTAssertTrue(H.isPotentiallyTrustworthy(u("wss://example.com/")))
        XCTAssertTrue(H.isPotentiallyTrustworthy(u("http://localhost:8000/")))
        XCTAssertTrue(H.isPotentiallyTrustworthy(u("http://app.localhost/")))
        XCTAssertTrue(H.isPotentiallyTrustworthy(u("http://127.0.0.1:9/")))
        XCTAssertTrue(H.isPotentiallyTrustworthy(u("http://127.1.2.3/")))
        XCTAssertTrue(H.isPotentiallyTrustworthy(u("http://[::1]:80/")))
        XCTAssertFalse(H.isPotentiallyTrustworthy(u("http://example.com/")))
        XCTAssertFalse(H.isPotentiallyTrustworthy(u("http://192.168.1.2/")))
        XCTAssertFalse(H.isPotentiallyTrustworthy(u("ws://example.com/")))
    }

    // MARK: Header sets (Dest / Mode / Site / User)

    func testDestinationAndModeMapping() {
        let doc = u("https://www.apple.com/")
        let cases: [(String, String, String)] = [
            ("no-cors", "script", "script"), ("no-cors", "style", "style"), ("no-cors", "image", "image"),
            ("cors", "font", "font"), ("cors", "", "empty"), ("cors", "script", "script"),
        ]
        for (mode, dest, sentDest) in cases {
            let h = JeffJSRequestHeaders.headers(documentURL: doc, target: u("https://www.apple.com/r"),
                                                 mode: mode, destination: dest)
            XCTAssertEqual(h["Sec-Fetch-Mode"], mode)
            XCTAssertEqual(h["Sec-Fetch-Dest"], sentDest)
            XCTAssertEqual(h["Sec-Fetch-Site"], "same-origin")
            XCTAssertEqual(h["Referer"], "https://www.apple.com/")
            XCTAssertNil(h["Sec-Fetch-User"])
        }
    }

    func testNavigationHeaders() {
        let h = JeffJSRequestHeaders.headers(documentURL: nil, target: u("https://www.apple.com/"),
                                             mode: "navigate", destination: "document",
                                             userNavigation: true, sendUserHeader: true)
        XCTAssertEqual(h, ["Sec-Fetch-Site": "none", "Sec-Fetch-Mode": "navigate",
                           "Sec-Fetch-Dest": "document", "Sec-Fetch-User": "?1"])
        let noUser = JeffJSRequestHeaders.headers(documentURL: u("https://a.example/"), target: u("https://www.apple.com/"),
                                                  mode: "navigate", destination: "document", userNavigation: true)
        XCTAssertNil(noUser["Sec-Fetch-User"])
        XCTAssertNil(noUser["Referer"], "a user navigation has no referrer")
        XCTAssertEqual(noUser["Sec-Fetch-Site"], "none")
    }

    func testHTTPTargetGetsNoFetchMetadata() {
        let h = JeffJSRequestHeaders.headers(documentURL: u("http://example.com/p"), target: u("http://example.com/api"),
                                             mode: "cors", destination: "")
        XCTAssertNil(h["Sec-Fetch-Site"])
        XCTAssertNil(h["Sec-Fetch-Mode"])
        XCTAssertNil(h["Sec-Fetch-Dest"])
        XCTAssertEqual(h["Referer"], "http://example.com/p")
        // https page → http subresource: neither Referer (downgrade) nor Sec-Fetch-*.
        XCTAssertEqual(JeffJSRequestHeaders.headers(documentURL: u("https://example.com/p"),
                                                    target: u("http://img.example.com/a.png"),
                                                    mode: "no-cors", destination: "image"), [:])
    }

    func testWebKitTrimsCrossSiteReferrerToOrigin() {
        let doc = u("https://www.example.com/a/page?x=1")
        func ref(_ target: String, trim: Bool = true) -> String? {
            JeffJSRequestHeaders.headers(documentURL: doc, target: u(target), mode: "cors", destination: "",
                                         policy: .unsafeURL, trimCrossSiteReferrer: trim)["Referer"]
        }
        XCTAssertEqual(ref("https://cdn.other.net/x"), "https://www.example.com/")
        XCTAssertEqual(ref("https://cdn.other.net/x", trim: false), "https://www.example.com/a/page?x=1")
        // Same site (another subdomain) keeps what the policy allows.
        XCTAssertEqual(ref("https://img.example.com/x"), "https://www.example.com/a/page?x=1")
    }

    func testApplyReplacesPageSetForbiddenHeaders() {
        var r = URLRequest(url: u("https://cdn.other.net/x"))
        r.setValue("https://spoof.example/", forHTTPHeaderField: "Referer")
        r.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        r.setValue("keep", forHTTPHeaderField: "X-Custom")
        JeffJSRequestHeaders.apply(to: &r, documentURL: u("https://www.example.com/page?x"),
                                   mode: "cors", destination: "")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Referer"), "https://www.example.com/")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Sec-Fetch-Site"), "cross-site")
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-Custom"), "keep")
    }

    // MARK: fetch() / XHR end to end

    private var server: HeaderEchoServer?

    override func setUp() {
        super.setUp()
        server = HeaderEchoServer()
    }

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    @JeffJSHostActor
    private func runJS(_ env: JeffJSEnvironment, _ js: String) async -> String {
        switch env.eval("globalThis.__out = undefined;\n" + js) {
        case .exception(let msg): XCTFail("JS threw: \(msg)"); return ""
        case .success: break
        }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            env.drainJobs()
            if case .success(let s) = env.eval("typeof globalThis.__out === 'string' ? globalThis.__out : ''"),
               let s, !s.isEmpty, s != "undefined" { return s }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for __out")
        return ""
    }

    private func decode(_ json: String) -> [String: String] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]) ?? [:]
    }

    @JeffJSHostActor
    func testFetchAndXHRSendRefererAndFetchMetadata() async throws {
        let server = try XCTUnwrap(server, "could not bind a loopback port")
        let base = "http://127.0.0.1:\(server.port)"
        let cross = "http://localhost:\(server.port)"
        let env = JeffJSEnvironment(configuration: .init(
            baseURL: URL(string: base + "/dir/page.html?q=1")!,
            userAgent: "TestUA/1.0",
            storageScope: "jeffjs.reqheaders.\(UUID().uuidString)"))

        let out = await runJS(env, """
        function h(u, o) { return fetch(u, o).then(function(r){ return r.text(); }); }
        var x = new Promise(function(res) {
          var q = new XMLHttpRequest(); q.open('GET', '/xhr'); q.onload = function(){ res(q.responseText); }; q.send();
        });
        Promise.all([
          h('/same'),
          h('\(cross)/cross'),
          h('/none', { referrer: '' }),
          h('\(cross)/unsafe', { referrerPolicy: 'unsafe-url' }),
          h('/explicit', { referrer: '/other?z=1' }),
          h('/spoof', { headers: { 'Referer': 'https://spoof.example/', 'X-A': 'b' } }),
          x
        ]).then(function(v){ globalThis.__out = JSON.stringify(v); })
          .catch(function(e){ globalThis.__out = 'ERR ' + e; });
        """)
        guard let list = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String], list.count == 7 else {
            return XCTFail("bad result: \(out)")
        }
        let page = base + "/dir/page.html?q=1"
        let same = decode(list[0])
        XCTAssertEqual(same["referer"], page)
        XCTAssertEqual(same["sec-fetch-site"], "same-origin")
        XCTAssertEqual(same["sec-fetch-mode"], "cors")
        XCTAssertEqual(same["sec-fetch-dest"], "empty")
        XCTAssertEqual(same["user-agent"], "TestUA/1.0")
        let crossH = decode(list[1])
        XCTAssertEqual(crossH["referer"], base + "/")
        XCTAssertEqual(crossH["sec-fetch-site"], "cross-site")
        XCTAssertNil(decode(list[2])["referer"])
        // unsafe-url to another site: WebKit trims it to the origin (ITP).
        XCTAssertEqual(decode(list[3])["referer"], base + "/")
        XCTAssertEqual(decode(list[4])["referer"], base + "/other?z=1")
        let spoof = decode(list[5])
        XCTAssertEqual(spoof["referer"], page)
        XCTAssertEqual(spoof["x-a"], "b")
        let xhr = decode(list[6])
        XCTAssertEqual(xhr["referer"], page)
        XCTAssertEqual(xhr["sec-fetch-mode"], "cors")
        XCTAssertEqual(xhr["sec-fetch-dest"], "empty")

        // The document's policy (host-set, e.g. <meta name=referrer content=origin>).
        env.fetchBridge?.referrerPolicy = .origin
        let o = decode(await runJS(env, "fetch('/p').then(function(r){return r.text();}).then(function(t){ globalThis.__out = t; });"))
        XCTAssertEqual(o["referer"], base + "/")

        // Legacy switch: nothing emitted.
        env.fetchBridge?.sendsRequestMetadata = false
        let l = decode(await runJS(env, "fetch('/l').then(function(r){return r.text();}).then(function(t){ globalThis.__out = t; });"))
        XCTAssertNil(l["referer"])
        XCTAssertNil(l["sec-fetch-site"])
    }
}

/// Loopback HTTP/1.1 server answering every request with its headers as a JSON
/// object (lowercase names), `Access-Control-Allow-Origin: *`.
final class HeaderEchoServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "jeffjs.headerecho")
    private(set) var port: UInt16 = 0

    init?() {
        let params = NWParameters.tcp
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
            conn.start(queue: self.queue)
            self.receive(conn, [])
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, port != 0 else { return nil }
    }

    func stop() { listener.cancel() }

    private func receive(_ conn: NWConnection, _ buffer: [UInt8]) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(contentsOf: data) }
            if error != nil { conn.cancel(); return }
            let text = String(decoding: buf, as: UTF8.self)
            guard let end = text.range(of: "\r\n\r\n") else {
                if done { conn.cancel() } else { self.receive(conn, buf) }
                return
            }
            var headers: [String: String] = [:]
            for line in text[..<end.lowerBound].components(separatedBy: "\r\n").dropFirst() {
                guard let c = line.firstIndex(of: ":") else { continue }
                headers[line[..<c].lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            }
            let body = (try? JSONSerialization.data(withJSONObject: headers)) ?? Data("{}".utf8)
            var head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nAccess-Control-Allow-Origin: *\r\n"
            head += "Cache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}
