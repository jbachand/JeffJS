// CookieJarTests.swift
// JeffJS — JeffJSMemoryCookieJar: RFC 6265bis parsing, storage, retrieval,
// document.cookie, persistence and per-site partitions.
//
// Usage:
//   swift test --filter CookieJarTests

import XCTest
@testable import JeffJS

final class CookieJarTests: XCTestCase {

    /// A settable clock (seconds since 1970).
    final class Clock: @unchecked Sendable {
        var now: Double = 1_800_000_000
        var date: Date { Date(timeIntervalSince1970: now) }
    }

    private func jar(_ clock: Clock = Clock(), site: String? = "example.com", max: Int = 300) -> JeffJSMemoryCookieJar {
        JeffJSMemoryCookieJar(site: site, maxCookies: max, clock: { clock.date })
    }

    private let page = URL(string: "https://www.example.com/shop/cart/view")!

    // MARK: parsing

    func testAttributeParsing() {
        let clock = Clock()
        let j = jar(clock)
        j.store(setCookieLines: [
            "a=1; Domain=.Example.com; Path=/shop; Secure; HttpOnly; SameSite=Strict",
            "b = two words ; max-age=60",
            "c=3; Expires=Wed, 21 Oct 2099 07:28:00 GMT",
            "d=4",
            "noequals",
        ], for: page)
        let all = Dictionary(uniqueKeysWithValues: j.allCookies.map { ($0.name, $0) })
        XCTAssertEqual(all["a"]?.domain, "example.com")
        XCTAssertEqual(all["a"]?.hostOnly, false)
        XCTAssertEqual(all["a"]?.path, "/shop")
        XCTAssertEqual(all["a"]?.secure, true)
        XCTAssertEqual(all["a"]?.httpOnly, true)
        XCTAssertEqual(all["a"]?.sameSite, .strict)
        XCTAssertEqual(all["b"]?.value, "two words")
        XCTAssertEqual(all["b"]?.expires, clock.now + 60)
        // Expires is capped at 400 days.
        XCTAssertEqual(all["c"]?.expires, clock.now + 400 * 86400)
        XCTAssertEqual(all["d"]?.hostOnly, true)
        XCTAssertEqual(all["d"]?.domain, "www.example.com")
        XCTAssertEqual(all["d"]?.path, "/shop/cart", "default-path is the directory of the request path")
        XCTAssertNil(all["d"]?.expires, "no Expires/Max-Age = session cookie")
        XCTAssertEqual(all[""]?.value, "noequals", "a pair without '=' is a nameless cookie")
    }

    func testCookieDates() {
        let expected = 1445412480.0   // 2015-10-21 07:28:00 UTC
        for s in ["Wed, 21 Oct 2015 07:28:00 GMT", "Wednesday, 21-Oct-15 07:28:00 GMT",
                  "Wed Oct 21 07:28:00 2015", "21 oct 2015 07:28:00"] {
            XCTAssertEqual(JeffJSCookieParsing.parseCookieDate(s), expected, s)
        }
        XCTAssertNil(JeffJSCookieParsing.parseCookieDate("Wed, 31 Feb 2015 07:28:00 GMT"))
        XCTAssertNil(JeffJSCookieParsing.parseCookieDate("garbage"))
    }

    func testMaxAgeWinsOverExpiresAndDeletes() {
        let clock = Clock()
        let j = jar(clock)
        j.store(setCookieLines: ["x=1; Max-Age=10; Expires=Wed, 21 Oct 2099 07:28:00 GMT"], for: page)
        XCTAssertEqual(j.allCookies.first?.expires, clock.now + 10)
        j.store(setCookieLines: ["x=1; Max-Age=0"], for: page)
        XCTAssertTrue(j.allCookies.isEmpty)
        j.store(setCookieLines: ["y=1"], for: page)
        j.store(setCookieLines: ["y=1; Expires=Thu, 01 Jan 1970 00:00:00 GMT"], for: page)
        XCTAssertTrue(j.allCookies.isEmpty, "an Expires in the past deletes")
    }

    func testRejectedCookies() {
        let j = jar()
        j.store(setCookieLines: [
            "a=1; Domain=other.com",                  // does not domain-match
            "b=1; Domain=com",                        // public suffix
            "c=1; Secure",                            // fine over https
            "__Host-d=1; Secure; Path=/; Domain=example.com",   // __Host- with Domain
            "__Secure-e=1",                           // __Secure- without Secure
        ], for: page)
        XCTAssertEqual(j.allCookies.map(\.name), ["c"])
        let insecure = jar()
        insecure.store(setCookieLines: ["s=1; Secure"], for: URL(string: "http://example.com/")!)
        XCTAssertTrue(insecure.allCookies.isEmpty, "Secure needs a secure origin")
        let suffix = jar()
        suffix.store(setCookieLines: ["p=1; Domain=co.uk"], for: URL(string: "https://bbc.co.uk/")!)
        XCTAssertTrue(suffix.allCookies.isEmpty)
    }

    func testSplitCombinedSetCookie() {
        let joined = "a=1; Expires=Wed, 21 Oct 2099 07:28:00 GMT; Path=/, b=2, c=3; HttpOnly"
        XCTAssertEqual(JeffJSCookieParsing.splitSetCookieHeader(joined),
                       ["a=1; Expires=Wed, 21 Oct 2099 07:28:00 GMT; Path=/", "b=2", "c=3; HttpOnly"])
        XCTAssertEqual(JeffJSCookieParsing.splitSetCookieHeader("a=1\nb=2"), ["a=1", "b=2"])
    }

    // MARK: retrieval

    func testDomainAndPathMatching() {
        let j = jar()
        j.store(setCookieLines: ["dom=1; Domain=example.com; Path=/", "host=1; Path=/",
                                 "shop=1; Path=/shop", "deep=1; Path=/shop/cart/"], for: page)
        XCTAssertEqual(j.cookieHeader(for: URL(string: "https://www.example.com/shop/cart/x")!, sameSite: true),
                       "deep=1; shop=1; dom=1; host=1", "longer paths first, then creation order")
        XCTAssertEqual(j.cookieHeader(for: URL(string: "https://api.example.com/shopping")!, sameSite: true),
                       "dom=1", "host-only stays on its host; /shop does not path-match /shopping")
        XCTAssertNil(j.cookieHeader(for: URL(string: "https://example.org/")!, sameSite: true))
        XCTAssertEqual(j.cookieHeader(for: URL(string: "https://www.example.com/shop")!, sameSite: true), "shop=1; dom=1; host=1")
        XCTAssertEqual(j.cookieHeader(for: URL(string: "https://example.com/shop")!, sameSite: true), "dom=1")
    }

    func testSecureAndSameSiteOnRetrieval() {
        let j = jar()
        j.store(setCookieLines: ["sec=1; Secure; Path=/", "strict=1; SameSite=Strict; Path=/",
                                 "lax=1; SameSite=Lax; Path=/", "none=1; SameSite=None; Secure; Path=/"], for: page)
        XCTAssertEqual(j.cookieHeader(for: URL(string: "http://www.example.com/")!, sameSite: true), "strict=1; lax=1")
        XCTAssertEqual(j.cookieHeader(for: URL(string: "https://www.example.com/")!, sameSite: false), "sec=1; none=1")
    }

    func testExpiredCookiesArePurgedAndNotSent() {
        let clock = Clock()
        let j = jar(clock)
        j.store(setCookieLines: ["short=1; Max-Age=5; Path=/", "long=1; Max-Age=500; Path=/"], for: page)
        XCTAssertEqual(j.cookieHeader(for: page, sameSite: true), "short=1; long=1")
        clock.now += 10
        XCTAssertEqual(j.cookieHeader(for: page, sameSite: true), "long=1")
        XCTAssertEqual(j.allCookies.map(\.name), ["long"], "expired cookies are purged from the store")
    }

    // MARK: document.cookie

    func testHttpOnlyHiddenFromDocumentCookie() {
        let j = jar()
        j.store(setCookieLines: ["srv=1; Path=/; HttpOnly"], for: page)
        j.setDocumentCookie("js=1; path=/", for: page)
        XCTAssertEqual(j.documentCookie(for: page), "js=1")
        XCTAssertEqual(j.cookieHeader(for: page, sameSite: true), "srv=1; js=1")
        // Script can neither create an HttpOnly cookie nor overwrite one.
        j.setDocumentCookie("srv=2; path=/", for: page)
        j.setDocumentCookie("h=1; HttpOnly", for: page)
        XCTAssertEqual(j.cookieHeader(for: page, sameSite: true), "srv=1; js=1")
        j.setDocumentCookie("js=1; path=/; max-age=0", for: page)
        XCTAssertEqual(j.documentCookie(for: page), "")
        XCTAssertEqual(j.cookieHeader(for: page, sameSite: true), "srv=1")
    }

    func testReplacementKeepsCreationOrder() {
        let clock = Clock()
        let j = jar(clock)
        j.setDocumentCookie("a=1; path=/", for: page)
        clock.now += 1
        j.setDocumentCookie("b=1; path=/", for: page)
        clock.now += 1
        j.setDocumentCookie("a=2; path=/", for: page)
        XCTAssertEqual(j.documentCookie(for: page), "a=2; b=1")
    }

    @MainActor
    func testDocumentCookieThroughTheEngine() {
        let env = JeffJSEnvironment(configuration: .init(baseURL: URL(string: "https://www.example.com/a/b.html")!,
                                                         storageScope: "jeffjs.cookietest.\(UUID().uuidString)"))
        env.cookieJar?.store(setCookieLines: ["srv=1; Path=/; HttpOnly"], for: URL(string: "https://www.example.com/")!)
        let r = env.eval("""
        document.cookie = 'a=1; path=/';
        document.cookie = 'b=2; expires=Thu, 01 Jan 1970 00:00:00 GMT';
        document.cookie = 'c=3';
        var s1 = document.cookie;
        document.cookie = 'c=3; max-age=0';
        typeof document.cookie + '|' + s1 + '|' + document.cookie;
        """)
        guard case .success(let s) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(s, "string|c=3; a=1|a=1")
    }

    /// WebIDL §3.7.6: `cookie` and `referrer` are accessors on Document.prototype,
    /// not own properties of the document; the page document is an HTMLDocument.
    /// Akamai's sensor calls `Object.getOwnPropertyDescriptor(Document.prototype,
    /// 'cookie').get` (akamai navigation fix, 2026-09-29).
    @MainActor
    func testDocumentCookieIsAnAccessorOnDocumentPrototype() {
        let env = JeffJSEnvironment(configuration: .init(baseURL: URL(string: "https://www.example.com/p")!,
                                                         storageScope: "jeffjs.cookietest.\(UUID().uuidString)"))
        let r = env.eval("""
        var d = Object.getOwnPropertyDescriptor(Document.prototype, 'cookie');
        var rd = Object.getOwnPropertyDescriptor(Document.prototype, 'referrer');
        d.set.call(document, 'k=v');
        var threw = ''; try { d.get.call(undefined); } catch (e) { threw = e.name; }
        [typeof d.get, typeof d.set, d.enumerable, d.configurable, d.get.call(document), document.cookie,
         d.get.call({}), threw, typeof rd.get, rd.set === undefined, document.referrer,
         Object.prototype.hasOwnProperty.call(document, 'cookie'), Object.prototype.hasOwnProperty.call(document, 'referrer'),
         document instanceof HTMLDocument, document instanceof Document,
         Object.getPrototypeOf(document) === HTMLDocument.prototype,
         Object.getPrototypeOf(HTMLDocument.prototype) === Document.prototype,
         Object.prototype.toString.call(document)].join('|');
        """)
        guard case .success(let s) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(s, "function|function|true|true|k=v|k=v||TypeError|function|true||false|false|true|true|true|true|[object HTMLDocument]")
    }

    // MARK: partitions and persistence

    /// The same third-party host embedded on two sites gets two cookies.
    func testPartitionIsolation() {
        let siteA = jar(site: "a.com"), siteB = jar(site: "b.com")
        let tracker = URL(string: "https://t.tracker.net/pixel")!
        siteA.store(setCookieLines: ["uid=A; Path=/; SameSite=None; Secure"], for: tracker)
        siteB.store(setCookieLines: ["uid=B; Path=/; SameSite=None; Secure"], for: tracker)
        XCTAssertEqual(siteA.cookieHeader(for: tracker, sameSite: false), "uid=A")
        XCTAssertEqual(siteB.cookieHeader(for: tracker, sameSite: false), "uid=B")
    }

    func testPersistenceRoundTripSkipsSessionCookies() {
        let clock = Clock()
        let j = jar(clock)
        j.store(setCookieLines: ["keep=1; Max-Age=3600; Path=/", "session=1; Path=/",
                                 "gone=1; Max-Age=5; Path=/"], for: page)
        clock.now += 10
        let data = j.persistentData()
        XCTAssertNotNil(data)
        let restored = JeffJSMemoryCookieJar(site: "example.com", persistentData: data, clock: { clock.date })
        XCTAssertEqual(restored.cookieHeader(for: page, sameSite: true), "keep=1")
        // A byte budget keeps the most recently used cookies.
        for i in 0..<50 { j.store(setCookieLines: ["k\(i)=\(String(repeating: "v", count: 40)); Max-Age=3600"], for: page) }
        let small = j.persistentData(maxBytes: 600)
        XCTAssertLessThanOrEqual(small?.count ?? 0, 600)
    }

    func testCapEvictsLeastRecentlyUsed() {
        let clock = Clock()
        let j = jar(clock, max: 3)
        for n in ["a", "b", "c"] { clock.now += 1; j.store(setCookieLines: ["\(n)=1; Path=/"], for: page) }
        clock.now += 1
        _ = j.cookieHeader(for: page, sameSite: true)   // touches a, b, c
        clock.now += 1
        j.store(setCookieLines: ["d=1; Path=/"], for: page)
        XCTAssertEqual(j.allCookies.count, 3)
        XCTAssertTrue(j.allCookies.contains { $0.name == "d" })
    }

    func testRegistrableDomain() {
        XCTAssertEqual(JeffJSCookieParsing.registrableDomain(ofHost: "www.apple.com"), "apple.com")
        XCTAssertEqual(JeffJSCookieParsing.registrableDomain(ofHost: "news.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(JeffJSCookieParsing.registrableDomain(ofHost: "jeff.github.io"), "jeff.github.io")
        XCTAssertEqual(JeffJSCookieParsing.registrableDomain(ofHost: "127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(JeffJSCookieParsing.registrableDomain(ofHost: "localhost"), "localhost")
        XCTAssertEqual(JeffJSCookieParsing.site(of: URL(string: "file:///tmp/x.html")!), "file")
    }
}
