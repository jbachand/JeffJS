// LazyPayloadTests.swift
// JeffJS — lazy JSON payloads (JeffJSLazyPayload.swift): memory proportional to
// what is read, eviction that rebuilds identically, collection of unreachable
// payloads, lazy literals, inline caches that never key on a stub, teardown.
// The semantic corners (order, identity, writes, reviver, unicode, numbers,
// duplicate / __proto__ keys, malformed input, big arrays) are the conformance
// group "LazyPayload" (LazyPayloadConformance.swift).
//
//   swift test -c release --filter LazyPayloadTests

import XCTest
@testable import JeffJS

final class LazyPayloadTests: XCTestCase {

    private static let makeText = """
        function lpItems(n){ var a = []; for (var i = 0; i < n; i++) a.push({ id: i, name: "n" + i, tags: ["t" + (i % 3), i % 2 === 0], sub: { x: i * 1.5, y: null, z: "z" + i } }); return a; }
        var lpText = JSON.stringify({ items: lpItems(3000), meta: { count: 3000 } });
        """

    /// The payload counts below assume the default 16 KB thresholds (a stress
    /// run with tiny thresholds makes the setup code's literals lazy too).
    private static var defaultThresholds: Bool {
        jeffJS_jsonLazyThreshold == 16384 && jeffJS_lazyLiteralMinBytes == 16384
    }

    private func evalBool(_ ctx: JeffJSContext, _ js: String, _ what: String,
                          file: StaticString = #filePath, line: UInt = #line) {
        let r = ctx.eval(input: js, filename: "<lazy-test>", evalFlags: 0)
        if r.isException {
            let e = ctx.getException()
            XCTFail("\(what) threw \(ctx.toSwiftString(e) ?? "?")", file: file, line: line)
            e.freeValue()
            return
        }
        XCTAssertTrue(r.isBool && r.toBool(), "\(what) -> \(ctx.toSwiftString(r) ?? "?")", file: file, line: line)
        r.freeValue()
    }

    private func liveObjects(_ rt: JeffJSRuntime) -> Int {
        runGC(rt); runGC(rt)
        var n = 0
        for u in rt.gcObjects where u.takeUnretainedValue().gcObjType == .jsObject { n += 1 }
        return n
    }

    /// Reading one field of one item of a 3000-item payload builds a handful
    /// of objects, not 12 000.
    func testParseCostsWhatIsRead() throws {
        try XCTSkipUnless(jeffJS_jsonLazyEnabled, "JEFFJS_JSON_LAZY=0")
        try XCTSkipUnless(Self.defaultThresholds, "counts assume the default thresholds")
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        evalBool(ctx, Self.makeText + "true", "setup")
        let before = liveObjects(rt)
        evalBool(ctx, "var o = JSON.parse(lpText); o.items[1234].sub.z === 'z1234'", "one read")
        let after = liveObjects(rt)
        let st = rt.lazyPayload
        XCTAssertEqual(st.payloads, 1)
        // root, items (3000 stubs), meta, items[1234], its tags and sub.
        XCTAssertLessThanOrEqual(st.objectsMaterialized + st.arraysMaterialized, 4)
        XCTAssertLessThan(after - before, 3100, "live objects grew by \(after - before)")
        // Fully read: 3 objects per item (item, tags, sub), as eager.
        evalBool(ctx, "JSON.stringify(o) === lpText", "full read equals the text")
        XCTAssertGreaterThan(liveObjects(rt) - before, 9_000)
    }

    /// Pristine materialized objects revert to stubs and rebuild identically;
    /// written ones, externally held ones' identity and weak keys survive.
    func testEvictionRebuildsIdentically() throws {
        try XCTSkipUnless(jeffJS_jsonLazyEnabled, "JEFFJS_JSON_LAZY=0")
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        evalBool(ctx, Self.makeText + """
            var o = JSON.parse(lpText); var s1 = JSON.stringify(o);
            var keep = o.items[5]; var keepSub = o.items[6].sub;
            o.items[7].name = 'w';
            var wm = new WeakMap(); wm.set(o.items[8].sub, 'k');
            true
            """, "setup")
        let full = liveObjects(rt)
        let n = rt.evictLazyPayloads()
        XCTAssertGreaterThan(n, 8000, "reverted \(n)")
        let evicted = liveObjects(rt)
        // `keep` pins items[5], so the items array stays materialized (its
        // 3000 children as stubs); every item's tags and sub go.
        XCTAssertLessThan(evicted, full - 5500, "live objects \(full) -> \(evicted)")
        evalBool(ctx, """
            JSON.stringify(o) === s1.replace('"name":"n7"', '"name":"w"') &&
            o.items[5] === keep && o.items[6].sub === keepSub && keep.sub.z === 'z5' &&
            o.items[7].name === 'w' && wm.get(o.items[8].sub) === 'k' &&
            JSON.stringify(o.items[9]) === JSON.stringify(lpItems(10)[9])
            """, "rebuilt equal, identity kept")
        XCTAssertGreaterThan(rt.lazyPayload.evicted, 0)
    }

    /// An unreachable payload is collected and its buffer released.
    func testUnreachablePayloadIsCollected() throws {
        try XCTSkipUnless(jeffJS_jsonLazyEnabled, "JEFFJS_JSON_LAZY=0")
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        evalBool(ctx, Self.makeText + """
            (function(){ var o = JSON.parse(lpText); var s = 0; for (var i = 0; i < 100; i++) s += o.items[i].id; return s === 4950; })()
            """, "read and drop")
        runGC(rt); runGC(rt)
        XCTAssertEqual(rt.lazyPayload.records.count, 0)
        XCTAssertEqual(rt.lazyPayload.buffers.compactMap { $0 }.count, 0)
    }

    /// A large pure-data literal compiles to a lazy payload equal to the parse.
    func testLargeLiteralIsLazy() throws {
        try XCTSkipUnless(jeffJS_lazyLiteralsEnabled, "JEFFJS_COMPILE_LAZYLITERALS=0")
        try XCTSkipUnless(Self.defaultThresholds, "counts assume the default thresholds")
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        evalBool(ctx, Self.makeText + "true", "setup")
        let lit = ctx.eval(input: "lpText", filename: "<lazy-test>", evalFlags: 0)
        let text = ctx.toSwiftString(lit) ?? ""
        lit.freeValue()
        evalBool(ctx, "var big = " + text + ";\nbig.items[42].sub.z === 'z42' && JSON.stringify(big) === lpText",
                 "literal equals the text")
        XCTAssertEqual(rt.lazyPayload.literalPayloads, 1)
    }

    /// Inline caches never key on a stub's sentinel shape; a stub read by a
    /// site trained on ordinary objects of the same shape still hits after
    /// materialization.
    func testInlineCachesNeverSeeSentinels() throws {
        try XCTSkipUnless(jeffJS_jsonLazyEnabled, "JEFFJS_JSON_LAZY=0")
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        evalBool(ctx, Self.makeText + """
            function f(x){ return x.toString === Object.prototype.toString ? x.id : -1; }
            var o = JSON.parse(lpText), s = 0;
            for (var r = 0; r < 3; r++) for (var i = 0; i < 3000; i++) s += f(o.items[i]) + o.items[i].tags.length;
            s === 3 * (4498500 + 6000)
            """, "hot loop over lazy objects")
        XCTAssertFalse(ctx.lazyObjectSentinel?.icCached ?? false)
        XCTAssertFalse(ctx.lazyArraySentinel?.icCached ?? false)
    }

    /// Tearing down a runtime with live stubs and materialized objects.
    func testTeardownWithLivePayloads() throws {
        for _ in 0..<3 {
            let rt = JeffJSRuntime()
            let ctx = rt.newContext()
            evalBool(ctx, Self.makeText + "var keep = JSON.parse(lpText); keep.items[3].name === 'n3'", "setup")
            ctx.free()
            rt.free()
        }
    }
}
