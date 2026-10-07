// InlineCacheOrdinalTests.swift
// JeffJS — inline-cache tables indexed by IC-site ordinal (perf/bytecode-paging).
// A function's table has one entry per IC site found in its final bytecode
// (plus the never-hit slot 0) and a pc -> slot map below the entries; the
// bytecode-offset tables before it were ~95 % empty.
// `JEFFJS_INTERP_ICORDINALTABLES=0` = the bytecode-offset tables.
//
//   swift test --filter InlineCacheOrdinalTests

import XCTest
@testable import JeffJS

final class InlineCacheOrdinalTests: XCTestCase {

    @MainActor
    private func function(_ env: JeffJSEnvironment, _ name: String) -> JeffJSFunctionBytecode? {
        let ctx = env.context
        let v = ctx.getPropertyStr(obj: ctx.globalObj, name: name)
        defer { v.freeValue() }
        return v.toObject()?.fbFast
    }

    /// Every IC site of a function gets its own slot, in bytecode order;
    /// offsets that are not sites map to the never-hit slot 0.
    @MainActor
    func testSitesGetDistinctSlots() {
        guard JeffJSConfig.icOrdinalTables, !JeffJSConfig.icTableFixed else { return }
        let env = JeffJSEnvironment()
        let src = """
            var G = 1;
            function f(o, k, s) {
                var a = o.x + o.y;           // get_field x2
                o.z = a;                     // put_field
                var b = o[k];                // get_array_el
                o[k] = b + G;                // put_array_el, get_var
                G = a;                       // put_var
                return s.length + a + b;     // get_length
            }
            var o = { x: 1, y: 2, q: 3 };
            for (var i = 0; i < 5; i++) f(o, 'q', 'abc');
            """
        guard case .success = env.eval(src, filename: "<ic-ord>") else { return XCTFail("eval threw") }
        guard let fb = function(env, "f"), let ic = fb.ic else { return XCTFail("no table") }
        let bc = fb.bytecodePtr
        let sites = JeffJSInlineCache.sitePCs(bc, fb.bytecodeLen)
        XCTAssertGreaterThanOrEqual(sites.count, 8)
        XCTAssertTrue(ic.isOrdinal)
        XCTAssertEqual(ic.siteCount, sites.count)
        XCTAssertEqual(ic.capacity, sites.count)
        XCTAssertEqual(ic.entries.count, sites.count + 1)
        var seen = Set<Int>()
        for pc in sites { seen.insert(ic.slot(Int(pc))) }
        XCTAssertEqual(seen.count, sites.count, "one slot per site")
        XCTAssertFalse(seen.contains(0))
        let siteSet = Set(sites.map { Int($0) })
        for pc in 0 ..< fb.bytecodeLen where !siteSet.contains(pc) {
            XCTAssertEqual(ic.slot(pc), 0, "pc \(pc) is not a site")
        }
        XCTAssertEqual(ic.slot(-1), 0)
        XCTAssertEqual(ic.slot(fb.bytecodeLen + 100), 0)
        // The table is far smaller than a bytecode-offset table of the same function.
        let offsetSlots = JeffJSInlineCache.capacity(forBytecodeLength: fb.bytecodeLen)
        XCTAssertLessThan(ic.capacity, offsetSlots)
    }

    /// Every cache store the interpreter makes lands on a site slot: the
    /// site-opcode list covers every handler that caches (named, keyed,
    /// global, `length`, string receivers, define_field, fused reads, the
    /// traces). A miss here would silently lose caching for that opcode.
    @MainActor
    func testNoStoreFallsOutsideTheSites() {
        guard JeffJSConfig.icOrdinalTables, !JeffJSConfig.icTableFixed else { return }
        let env = JeffJSEnvironment()
        let before = JeffJSInlineCache.unmappedStores.load(ordering: .relaxed)
        let src = """
            var counter = 0;
            class P { constructor(v) { this.v = v; this.w = v * 2; } get g() { return this.v; } m() { return this.w; } }
            class Q extends P { constructor(v) { super(v); this.extra = 1; } }
            function hot(arr, key, s) {
                var t = 0;
                for (var i = 0; i < arr.length; i++) {
                    var o = arr[i];
                    t += o.v + o.w + o.g + o.m() + o[key] + this['v'];
                    o.v = o.v + 1; o[key] = i;
                    t += s.length + s.charCodeAt(i % s.length);
                    counter = counter + 1;
                }
                return t;
            }
            var arr = [];
            for (var i = 0; i < 50; i++) arr.push(i & 1 ? new Q(i) : new P(i));
            var r = 0;
            for (var j = 0; j < 40; j++) r += hot.call({ v: 3 }, arr, 'w', 'hello');
            var obj = {};
            for (var k = 0; k < 100; k++) { obj = { a: k, b: k + 1 }; r += obj.a; }
            String(r) + ':' + counter
            """
        guard case .success(let v) = env.eval(src, filename: "<ic-ord-cover>") else { return XCTFail("eval threw") }
        XCTAssertNotNil(v)
        let after = JeffJSInlineCache.unmappedStores.load(ordering: .relaxed)
        XCTAssertEqual(after - before, 0, "cache stores at offsets that are not IC sites")
    }

    /// A function with more sites than `maxOrdinalSlots` folds them onto
    /// the table and stays correct (collisions are misses).
    @MainActor
    func testFoldedTableStaysCorrect() {
        guard JeffJSConfig.icOrdinalTables, !JeffJSConfig.icTableFixed else { return }
        let env = JeffJSEnvironment()
        let n = JeffJSInlineCache.maxOrdinalSlots + 300
        var body = "var s = 0;\n"
        for i in 0 ..< n { body += "s += o.p\(i % 13);\n" }
        body += "return s;"
        let src = """
            var big = new Function('o', \(jsString(body)));
            var o = {}; for (var i = 0; i < 13; i++) o['p' + i] = i;
            var a = big(o), b = big(o), c = big(o);
            var o2 = { zz: 0 }; for (var i = 0; i < 13; i++) o2['p' + i] = i;
            String(a === b && b === c && big(o2) === a ? a : -1)
            """
        guard case .success(let v) = env.eval(src, filename: "<ic-ord-fold>") else { return XCTFail("eval threw") }
        // sum over i < n of (i % 13)
        var expect = 0
        for i in 0 ..< n { expect += i % 13 }
        XCTAssertEqual(v, String(expect))
        guard let fb = function(env, "big"), let ic = fb.ic else { return XCTFail("no table") }
        XCTAssertEqual(ic.capacity, JeffJSInlineCache.maxOrdinalSlots)
        XCTAssertGreaterThan(ic.siteCount, JeffJSInlineCache.maxOrdinalSlots)
    }

    /// A body whose bytecode is replaced (idle reclaim + recompile) gets a
    /// new table built for the new bytecode, never the old map.
    @MainActor
    func testReplacedBytecodeDropsTheTable() {
        let env = JeffJSEnvironment()
        let src = """
            function g(o) { return o.a + o.b; }
            var o = { a: 1, b: 2 }, r = 0;
            for (var i = 0; i < 10; i++) r += g(o);
            String(r)
            """
        guard case .success(let v) = env.eval(src, filename: "<ic-ord-reset>") else { return XCTFail("eval threw") }
        XCTAssertEqual(v, "30")
        guard let fb = function(env, "g") else { return XCTFail("no function") }
        XCTAssertNotNil(fb.ic)
        fb.resetBytecodeBuffer()
        XCTAssertNil(fb.ic, "the pc -> slot map belongs to the old bytecode")
        guard case .success(let v2) = env.eval("var r2 = 0; for (var i = 0; i < 10; i++) r2 += g(o); String(r2)",
                                                filename: "<ic-ord-reset-2>") else { return XCTFail("eval threw") }
        XCTAssertEqual(v2, "30")
    }

    private func jsString(_ s: String) -> String {
        var out = "'"
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            default: out.append(ch)
            }
        }
        return out + "'"
    }
}
