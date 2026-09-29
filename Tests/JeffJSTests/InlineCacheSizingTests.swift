// InlineCacheSizingTests.swift
// JeffJS — inline-cache tables sized to the function's bytecode (IC table size
// fix, 2026-09-29). A table has the next power of two >= the bytecode length
// (8 ... 512) slots instead of a fixed 512 x 56 B; `JEFFJS_INTERP_ICTABLEFIXED=1`
// restores the fixed size.
//
//   swift test -c release --filter InlineCacheSizingTests

import XCTest
@testable import JeffJS

final class InlineCacheSizingTests: XCTestCase {

    func testCapacityForBytecodeLength() {
        guard !JeffJSConfig.icTableFixed else { return }
        XCTAssertEqual(JeffJSInlineCache.capacity(forBytecodeLength: 0), 8)
        XCTAssertEqual(JeffJSInlineCache.capacity(forBytecodeLength: 8), 8)
        XCTAssertEqual(JeffJSInlineCache.capacity(forBytecodeLength: 9), 16)
        XCTAssertEqual(JeffJSInlineCache.capacity(forBytecodeLength: 100), 128)
        XCTAssertEqual(JeffJSInlineCache.capacity(forBytecodeLength: 512), 512)
        XCTAssertEqual(JeffJSInlineCache.capacity(forBytecodeLength: 5000), 512)
    }

    /// A slot past the table is never read or written (a miss, not a stray access).
    func testOutOfTableSlotIsAMiss() {
        let ic = JeffJSInlineCache(capacity: 8)
        XCTAssertEqual(ic.capacity, 8)
        XCTAssertEqual(ic.lookup(300).pc, -1)
    }

    /// Small functions get small tables; every property read still hits its
    /// own slot (the answers and the table count prove both).
    @MainActor
    func testSmallFunctionsGetSmallTables() {
        let env = JeffJSEnvironment()
        let before = JeffJSEnvironment.inlineCacheStats
        let src = """
            var fs = [];
            for (var i = 0; i < 300; i++) fs.push(new Function('o', 'return o.a + o.b + ' + i));
            var acc = 0, o = { a: 1, b: 2 };
            for (var r = 0; r < 3; r++) for (var i = 0; i < fs.length; i++) acc += fs[i](o);
            String(acc)
            """
        guard case .success(let value) = env.eval(src, filename: "<ic-small>") else {
            return XCTFail("eval threw")
        }
        // 3 * sum_{i<300} (3 + i) = 3 * (900 + 44850)
        XCTAssertEqual(value, String(3 * (900 + 44850)))
        let after = JeffJSEnvironment.inlineCacheStats
        let tables = after.tables - before.tables
        let bytes = after.bytes - before.bytes
        XCTAssertGreaterThanOrEqual(tables, 300)
        if !JeffJSConfig.icTableFixed {
            // Each of these bodies is a few dozen bytes: <= 64 slots.
            XCTAssertLessThanOrEqual(bytes, tables * 64 * MemoryLayout<JeffJSICEntry>.stride)
        }
    }

    /// A function longer than 512 bytes keeps a 512-slot table (pc & 511 folds
    /// its sites together) and stays correct, including polymorphic receivers,
    /// prototype hits, keyed and store sites.
    @MainActor
    func testLargeFunctionStaysCorrect() {
        let env = JeffJSEnvironment()
        var body = "var s = 0;\n"
        for i in 0..<220 {
            body += "s += o.p\(i % 7) + q['k\(i % 5)'];\n"
            if i % 11 == 0 { body += "o.w\(i % 3) = s & 7; s += o.w\(i % 3);\n" }
        }
        body += "return s + o.inherited;"
        let src = """
            var P = { inherited: 1000 };
            function mk(extra) {
                var o = Object.create(P);
                if (extra) o.x = 1;
                for (var i = 0; i < 7; i++) o['p' + i] = i;
                return o;
            }
            var big = new Function('o', 'q', \(jsString(body)));
            var q = { k0: 1, k1: 2, k2: 3, k3: 4, k4: 5 };
            var a = [], b = [];
            for (var r = 0; r < 20; r++) { a.push(big(mk(false), q)); b.push(big(mk(r & 1), q)); }
            JSON.stringify([a[0] === a[19], b[0] === b[19], a[0] === b[0], a[0]])
            """
        guard case .success(let value) = env.eval(src, filename: "<ic-large>") else {
            return XCTFail("eval threw")
        }
        guard let v = value, v.hasPrefix("[true,true,true,") else { return XCTFail("got \(value ?? "nil")") }
        // Reference value: the same body with every cache defeated (a fresh
        // shape per call through `delete`), compared in the same engine.
        let check = """
            function slow(o, q) { \(body) }
            var o2 = mk(false); o2.tmp = 1; delete o2.tmp;
            String(slow(o2, q))
            """
        guard case .success(let reference) = env.eval(check, filename: "<ic-large-ref>") else {
            return XCTFail("reference eval threw")
        }
        XCTAssertEqual(v, "[true,true,true,\(reference ?? "?")]")
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
