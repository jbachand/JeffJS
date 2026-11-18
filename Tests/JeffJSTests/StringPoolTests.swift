// StringPoolTests.swift
// JeffJS — short Latin-1 strings that die are parked, object and code-unit
// block together, and taken by the next short string (JeffJSStringPool.swift).
// What must hold: a reused string starts over (contents, length, hash, count);
// a string anything else still references is never reused; wide, long, empty
// and interned strings take the ordinary path; results do not depend on the
// pool.

import XCTest
@testable import JeffJS

final class StringPoolTests: XCTestCase {

    private func text(_ s: JeffJSString) -> String {
        String(decoding: UnsafeBufferPointer(start: s.units8, count: s.len), as: UTF8.self)
    }

    func testAReusedStringStartsOver() throws {
        try XCTSkipUnless(jeffJSStringPoolEnabled)
        #if canImport(Darwin)
        // Drain whatever earlier tests parked in this size class.
        var drained: [JeffJSString] = []
        while let s = jeffJS_stringPoolTake(5) { drained.append(s) }
        let v = JeffJSValue.makeString(JeffJSString.latin1(5) { memcpy($0, "hello", 5) })
        let p = v.stringValue.map { Unmanaged.passUnretained($0).toOpaque() }
        v.stringValue!.hash = jeffJS_computeHash(str: v.stringValue!)
        v.freeValue()                                   // parked
        let t = JeffJSString.latin1(3) { memcpy($0, "abc", 3) }
        XCTAssertEqual(Unmanaged.passUnretained(t).toOpaque(), p, "the parked string is taken")
        XCTAssertEqual(text(t), "abc")
        XCTAssertEqual(t.len, 3)
        XCTAssertEqual(t.refCount, 1)
        XCTAssertEqual(t.hash, 0)
        XCTAssertFalse(t.isWideChar)
        // Growing past the block still works.
        t.appendInPlace(JeffJSString(swiftString: String(repeating: "z", count: 200)))
        XCTAssertEqual(t.len, 203)
        XCTAssertEqual(text(t).prefix(4), "abcz")
        _ = drained
        #endif
    }

    func testAStringSomethingElseHoldsIsNotReused() throws {
        try XCTSkipUnless(jeffJSStringPoolEnabled)
        var drained: [JeffJSString] = []
        while let s = jeffJS_stringPoolTake(6) { drained.append(s) }
        let held = JeffJSString.latin1(6) { memcpy($0, "keepme", 6) }
        let v = JeffJSValue.makeString(held)
        v.freeValue()                                   // the JS reference goes; `held` remains
        let other = JeffJSString.latin1(6) { memcpy($0, "others", 6) }
        XCTAssertFalse(other === held)
        XCTAssertEqual(text(held), "keepme")
        XCTAssertEqual(text(other), "others")
        _ = drained
    }

    func testWideLongAndEmptyStringsTakeTheOrdinaryPath() {
        let wide = JeffJSValue.makeString(JeffJSString(swiftString: "\u{3b1}\u{3b2}"))
        let long = JeffJSValue.makeString(JeffJSString.latin1(300) { memset($0, 0x61, 300) })
        let empty = JeffJSValue.makeString(JeffJSString.latin1(0) { _ in })
        XCTAssertEqual(long.stringValue?.len, 300)
        XCTAssertEqual(empty.stringValue?.len, 0)
        wide.freeValue(); long.freeValue(); empty.freeValue()
        let s = JeffJSString.latin1(64) { memset($0, 0x62, 64) }
        XCTAssertEqual(text(s), String(repeating: "b", count: 64))
    }

    func testScriptsComputeTheSameWithShortStringChurn() {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        let src = #"""
            (function () {
              var m = new Map(), o = {}, out = [];
              for (var i = 0; i < 400; i++) { m.set("k" + i, i); o["p" + (i % 37)] = "v" + i; }
              var s = 0; for (var j = 0; j < 400; j++) { s += m.get("k" + (j % 400)); }
              var parts = []; for (var k = 0; k < 50; k++) { parts.push(("x" + k).toUpperCase() + String(k * 7).slice(-2) + "abcdef".charAt(k % 6)); }
              var keys = Object.keys(o).length, sym = Symbol("d" + 1).description;
              var held = []; for (var q = 0; q < 100; q++) { held.push("h" + q); } var chk = held.join("").length;
              return [s, keys, o.p5, parts.join("").length, parts[49], sym, chk, ("a" + 1) === "a1", ("é" + 2).length].join();
            })()
            """#
        for _ in 0..<3 {
            let r = ctx.eval(input: "JSON.stringify(" + src + ")", filename: "<pool>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            XCTAssertFalse(r.isException)
            XCTAssertEqual(ctx.toSwiftString(r), #""79800,37,v375,288,X4943b,d1,290,true,2""#)
            r.freeValue()
            rt.runGC()
        }
    }
}
