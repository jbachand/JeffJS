// WebStorageConformance.swift
// JeffJS — conformance group "WebStorage" (Web Storage fix, 2026-10-01).
// HTML §12.2: localStorage per origin in the host's store with a quota
// (QuotaExceededError, nothing changed), sessionStorage per top-level
// browsing context, keys in a stable order, `storage` events at the *other*
// documents of the origin, and areas that survive a store round trip.
// Every JS case is an expression that must be `true` (WebKit's answers).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    /// Run in a document of `https://a.example` whose store has a 4096-byte quota.
    static let webStorageSyncCases: [(String, String)] = [
        ("a missing key is null, values are strings",
         "localStorage.getItem('nope') === null && (localStorage.setItem('n', 5), localStorage.getItem('n') === '5') && (localStorage.setItem('e', ''), localStorage.getItem('e') === '')"),
        ("a write past the quota throws QuotaExceededError and changes nothing",
         """
         (function () {
           localStorage.clear(); localStorage.setItem('keep', 'old');
           var e1 = null, e2 = null;
           try { localStorage.setItem('big', 'x'.repeat(5000)); } catch (e) { e1 = e; }
           try { localStorage.setItem('keep', 'y'.repeat(5000)); } catch (e) { e2 = e; }
           return e1 !== null && e1.name === 'QuotaExceededError' && e1.code === 22 && e1 instanceof DOMException
             && e2 !== null && e2.name === 'QuotaExceededError'
             && localStorage.getItem('big') === null && localStorage.getItem('keep') === 'old' && localStorage.length === 1;
         })()
         """),
        ("the quota counts Latin-1 strings at one byte per unit, others at two",
         """
         (function () {
           localStorage.clear();
           var ok1 = true, ok2 = false;
           try { localStorage.setItem('k', '\\u00e9'.repeat(4000)); } catch (e) { ok1 = false; }
           localStorage.clear();
           try { localStorage.setItem('k', '\\u4e00'.repeat(2100)); } catch (e) { ok2 = e.name === 'QuotaExceededError'; }
           localStorage.clear();
           return ok1 && ok2;
         })()
         """),
        ("an overwrite that frees bytes fits again after a rejection",
         "(function(){ localStorage.clear(); localStorage.setItem('a', 'x'.repeat(4000)); var t = false; try { localStorage.setItem('b', 'x'.repeat(200)); } catch (e) { t = true; } localStorage.setItem('a', 'x'); localStorage.setItem('b', 'x'.repeat(200)); var r = t && localStorage.length === 2; localStorage.clear(); return r; })()"),
        ("keys keep insertion order; an update keeps its place",
         """
         (function () {
           localStorage.clear();
           localStorage.setItem('c', '1'); localStorage.setItem('a', '2'); localStorage.setItem('b', '3');
           localStorage.setItem('a', '4');
           var o1 = [localStorage.key(0), localStorage.key(1), localStorage.key(2)].join();
           localStorage.removeItem('c'); localStorage.setItem('c', '5');
           var o2 = [localStorage.key(0), localStorage.key(1), localStorage.key(2)].join();
           return o1 === 'c,a,b' && o2 === 'a,b,c' && localStorage.length === 3
             && localStorage.key(3) === null && localStorage.key(-1) === null && localStorage.key('1') === 'b' && localStorage.key(1.9) === 'b';
         })()
         """),
        ("clear empties the area",
         "(localStorage.setItem('q', '1'), localStorage.clear(), localStorage.length === 0 && localStorage.getItem('q') === null)"),
        ("sessionStorage is a separate area",
         "(localStorage.setItem('s', 'L'), sessionStorage.setItem('s', 'S'), localStorage.getItem('s') === 'L' && sessionStorage.getItem('s') === 'S' && (sessionStorage.removeItem('s'), localStorage.getItem('s') === 'L'))"),
        ("a Proxy over a Storage-shaped target keeps its interface (the host's Storage exotic object)",
         """
         (function () {
           var P = {}; Object.defineProperty(P, Symbol.toStringTag, { value: 'Storage', configurable: true });
           function F() {} F.prototype = P;
           var t = Object.create(P), seen = [];
           var px = new Proxy(t, { get: function (t, k, r) { seen.push(typeof k); return Reflect.get(t, k, r); } });
           var bare = new Proxy(t, {});
           var hooked = new Proxy(t, { getPrototypeOf: function () { return Array.prototype; } });
           return px instanceof F && Object.getPrototypeOf(px) === P && Object.prototype.toString.call(px) === '[object Storage]'
             && seen.indexOf('symbol') >= 0 && bare instanceof F && Object.getPrototypeOf(bare) === P
             && hooked instanceof Array && !(hooked instanceof F) && Object.getPrototypeOf(hooked) === Array.prototype
             && new Proxy(px, {}) instanceof F;
         })()
         """),
        ("sessionStorage has the quota too",
         "(function(){ var t = false; try { sessionStorage.setItem('big', 'x'.repeat(5 * 1024 * 1024 + 1)); } catch (e) { t = e.name === 'QuotaExceededError'; } return t && sessionStorage.getItem('big') === null; })()"),
    ]

    mutating func testWebStorage() {
        var outcomes: [(Bool, String)] = []
        func onMain(_ body: @escaping @MainActor () -> Void) {
            if Thread.isMainThread { MainActor.assumeIsolated { body() } } else { DispatchQueue.main.sync { MainActor.assumeIsolated { body() } } }
        }
        func waitForTasks() {
            if Thread.isMainThread { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) } else { Thread.sleep(forTimeInterval: 0.3) }
        }
        func record(_ result: JeffJSEvalResult, _ name: String) {
            switch result {
            case .success(let value): outcomes.append((value == "true", "WebStorage: \(name) -> \(value ?? "undefined")"))
            case .exception(let message): outcomes.append((false, "WebStorage: \(name) threw \(message)"))
            }
        }

        // Swift-level: origins and the area model.
        let originCases: [(String, String)] = [
            ("https://en.wikipedia.org/wiki/Swift", "https://en.wikipedia.org"),
            ("https://EN.Wikipedia.org:443/x", "https://en.wikipedia.org"),
            ("http://127.0.0.1:8123/a/b.html", "http://127.0.0.1:8123"),
            ("http://localhost:80/", "http://localhost"),
            ("file:///Users/x/index.html", "file://"),
            ("blob:https://a.example/123-456", "https://a.example"),
        ]
        for (u, want) in originCases {
            let got = JeffJSWebStorageOrigin.key(for: URL(string: u)!)
            outcomes.append((got == want, "WebStorage: origin of \(u) = \(got) (want \(want))"))
        }
        var area = JeffJSWebStorageArea()
        _ = try? area.set("k1", "v1", quota: nil)
        _ = try? area.set("k2", "\u{4e00}", quota: nil)
        let restored = JeffJSWebStorageArea(pairs: area.pairs)
        outcomes.append((restored == area && restored.bytes == 2 + 2 + 2 + 2,
                         "WebStorage: an area survives a pairs round trip (bytes \(restored.bytes))"))
        let clipped = JeffJSWebStorageArea(pairs: [("a", "1234"), ("b", "123456789"), ("c", "12")], quota: 10)
        outcomes.append((clipped.keys == ["a", "c"], "WebStorage: a restore drops the items past the quota (\(clipped.keys))"))

        let store = JeffJSMemoryWebStorage(quotaBytes: 4096)
        let other = JeffJSMemoryWebStorage(quotaBytes: 4096)
        var a: JeffJSEnvironment?, b: JeffJSEnvironment?, c: JeffJSEnvironment?, d: JeffJSEnvironment?, x: JeffJSEnvironment?
        onMain {
            @MainActor func env(_ url: String, _ s: JeffJSMemoryWebStorage, _ bc: String) -> JeffJSEnvironment {
                JeffJSEnvironment(configuration: .init(baseURL: URL(string: url)!, webStorage: s, browsingContext: bc))
            }
            a = env("https://a.example/one.html", store, "tab1")
            b = env("https://a.example/two.html", store, "tab2")      // same origin, other tab
            c = env("https://b.example/", store, "tab1")             // other origin
            d = env("https://a.example/frame.html", store, "tab1")   // same origin, same tab
            x = env("https://a.example/three.html", other, "tab3")   // same origin, another store
            guard let a else { return }
            for (name, js) in Self.webStorageSyncCases { record(a.eval(js, filename: "<webstorage>"), name) }
            _ = a.eval("localStorage.clear(); sessionStorage.clear(); 1", filename: "<webstorage>")
        }
        waitForTasks()   // the sync cases' own events are delivered before anyone listens
        onMain {
            guard let a else { return }
            let listen = """
            window.__ev = []; window.addEventListener('storage', function (e) {
              window.__ev.push([e.key, e.oldValue, e.newValue, e.url, e.storageArea === localStorage ? 'L' : e.storageArea === sessionStorage ? 'S' : '?',
                                e instanceof StorageEvent, e.type].join('|'));
            }); 1
            """
            for e in [a, b, c, d, x].compactMap({ $0 }) { _ = e.eval(listen, filename: "<webstorage-listen>") }
            _ = a.eval("""
            localStorage.setItem('e1', 'v1'); localStorage.setItem('e1', 'v1'); localStorage.setItem('e1', 'v2');
            localStorage.removeItem('e1'); localStorage.removeItem('nope');
            localStorage.setItem('z', '1'); localStorage.clear(); localStorage.clear();
            sessionStorage.setItem('s1', 'a'); 1
            """, filename: "<webstorage-writes>")
            record(a.eval("window.__ev.length === 0", filename: "<webstorage>"), "the writing document gets no storage event, synchronously or later (sync part)")
        }
        waitForTasks()
        onMain {
            guard let a, let b, let c, let d, let x else { outcomes.append((false, "WebStorage: environments")); return }
            record(a.eval("window.__ev.length === 0", filename: "<webstorage>"), "the writing document gets no storage event")
            record(b.eval("""
            window.__ev.join('\\n') === [
              'e1||v1|https://a.example/one.html|L|true|storage',
              'e1|v1|v2|https://a.example/one.html|L|true|storage',
              'e1|v2||https://a.example/one.html|L|true|storage',
              'z||1|https://a.example/one.html|L|true|storage',
              '|||https://a.example/one.html|L|true|storage'].join('\\n') || window.__ev.join(' / ')
            """, filename: "<webstorage>"), "another document of the origin gets one event per change (none for no-ops), in order")
            record(c.eval("window.__ev.length === 0", filename: "<webstorage>"), "a document of another origin gets none")
            record(x.eval("window.__ev.length === 0 && localStorage.getItem('z') === null", filename: "<webstorage>"),
                   "a document over another store shares nothing")
            record(d.eval("window.__ev.length === 6 && window.__ev[5] === 's1||a|https://a.example/one.html|S|true|storage' && sessionStorage.getItem('s1') === 'a'",
                          filename: "<webstorage>"), "the same tab's documents share sessionStorage and get its events")
            record(b.eval("sessionStorage.getItem('s1') === null && window.__ev.length === 5", filename: "<webstorage>"),
                   "another tab has its own sessionStorage")
            _ = a.eval("localStorage.setItem('p', 'persist'); 1", filename: "<webstorage>")
            let reopened = JeffJSEnvironment(configuration: .init(baseURL: URL(string: "https://a.example/again.html")!,
                                                                  webStorage: store, browsingContext: "tab9"))
            record(reopened.eval("localStorage.getItem('p') === 'persist' && localStorage.length === 1", filename: "<webstorage>"),
                   "a new document of the origin reads what the store kept")
            // Not torn down: like the other groups, contexts are dropped without
            // the runtime-teardown path.
            _ = (a, b, c, d, x)
        }
        for (ok, message) in outcomes { assert(ok, message) }
    }
}
