// ArclessVarRefTests.swift
// JeffJS — closure var-refs on a manual hold count (JEFFJS_MANUAL_MEMORY,
// Core/JeffJSVarRefHold.swift; quickjs js_closure2 / close_var_refs /
// free_var_ref). A var-ref's lifetime is its hold count (closure entries +
// the frame's live list); one that dies — live or detached — is parked and
// reused. These cases pin the bindings' semantics across that reuse, the ARC
// holders the count does not see (mapped `arguments`, generator / async
// saved state, eval), the cycle collector, and the counts themselves.

import XCTest
@testable import JeffJS

final class ArclessVarRefTests: XCTestCase {

    private func evalBool(_ ctx: JeffJSContext, _ src: String, _ name: String,
                          file: StaticString = #filePath, line: UInt = #line) {
        let r = ctx.eval(input: src, filename: "<arcless>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        if r.isException {
            let e = ctx.getException()
            XCTFail("\(name): threw \(ctx.toSwiftString(e) ?? "?")", file: file, line: line)
            e.freeValue()
            return
        }
        XCTAssertTrue(r.isBool && r.toBool(), "\(name): not true", file: file, line: line)
        r.freeValue()
    }

    /// Each expression must evaluate to `true`. Every case recycles var-refs
    /// (closures that die before or after their frame) and then reads
    /// bindings that must not have been disturbed by the reuse.
    static let cases: [(String, String)] = [
        ("loop closures keep their own binding after the callbacks die", """
            (function(){ var keep = [];
              for (var r = 0; r < 50; r++) {
                [1,2,3].forEach(function(v){ var t = v * r; return function(){ return t; }; });
                let rr = r; for (let i = 0; i < 4; i++) { if (rr % 7 === 0) keep.push(function(){ return i + rr * 10; }); }
              }
              var s = 0; for (var k = 0; k < keep.length; k++) s += keep[k]();
              return keep.length === 32 && s === 7888; })()
            """),
        ("two closures share one detached binding", """
            (function(){ function mk(){ var n = 0; return [function(){ return ++n; }, function(){ return n; }]; }
              var a = mk(), b = mk(); a[0](); a[0](); b[0]();
              for (var j = 0; j < 100; j++) mk()[0]();   // dying var-refs, parked and reused
              return a[1]() === 2 && b[1]() === 1 && a[0]() === 3 && a[1]() === 3; })()
            """),
        ("binding outlives one of its two closures", """
            (function(){ function mk(){ var o = {v: 1}; var g = function(){ return o; };
                return [g, function(x){ o = {v: x}; }]; }
              var p = mk(); var set = p[1]; p = p[0];   // the setter survives, then dies
              set(5); set = null;
              for (var j = 0; j < 200; j++) mk();
              return p().v === 5; })()
            """),
        ("closure over a parameter with a mapped arguments object", """
            (function(){ function f(x){ var a = arguments; var g = function(){ return x; }; a[0] = 9; return [g, a]; }
              var r = f(1); var g = r[0]; r = null;
              for (var j = 0; j < 100; j++) f(j);
              function h(x){ var a = arguments; return function(){ return a[0] + x; }; }
              var k = h(4);
              for (var j = 0; j < 100; j++) h(j)();
              return g() === 9 && k() === 8; })()
            """),
        ("arguments object outlives the frame and the closures", """
            (function(){ function f(x){ var c = function(){ x++; }; c(); return arguments; }
              var a = f(10); for (var j = 0; j < 100; j++) f(j);
              return a[0] === 11 && a.length === 1; })()
            """),
        ("generator: closures over its locals across yields", """
            (function(){ function* g(){ var n = 1; var get = function(){ return n; };
                yield get; n = 2; yield get; var inc = function(){ n += 10; }; inc(); yield get; }
              var it = g(); var f = it.next().value; var a = f();
              for (var j = 0; j < 50; j++) { var t = g(); t.next(); t.next(); }
              it.next(); var b = f(); it.next(); var c = f(); it.next();
              return a === 1 && b === 2 && c === 12; })()
            """),
        ("async function: closure over a local across await", """
            (function(){ var out = [];
              async function f(){ var n = 1; var get = function(){ return n; }; out.push(get);
                await null; n = 2; await null; n = 3; }
              f(); for (var j = 0; j < 20; j++) f();
              return out.length === 21 && out[0]() === 1; })()
            """),
        ("eval code captures the caller's locals", """
            (function(){ function f(){ var a = 3; var g = eval("(function(){ return a * 2; })"); a = 4; return g; }
              var g = f(); for (var j = 0; j < 50; j++) f()();
              return g() === 8; })()
            """),
        ("close_loc: per-iteration bindings, parked when unread", """
            (function(){ var fs = [];
              for (let i = 0; i < 20; i++) { let k = i * 2; (function(){ return k; })(); if (i & 1) fs.push(function(){ return k; }); }
              var s = 0; for (var j = 0; j < fs.length; j++) s += fs[j]();
              return fs.length === 10 && s === 2*(1+3+5+7+9+11+13+15+17+19); })()
            """),
        ("cycles through captured bindings are collected and the rest survive", """
            (function(){ var live = null;
              for (var j = 0; j < 300; j++) { (function(){ var node = {}; node.cb = function(){ return node; }; })();
                if (j === 150) live = (function(){ var node = {t: 7}; node.cb = function(){ return node; }; return node; })(); }
              if (typeof std !== 'undefined' && std.gc) std.gc();
              return live.cb() === live && live.cb().t === 7; })()
            """),
    ]

    /// (The A/B switch is a process-wide constant: the ARC lifetime is run
    /// through the same cases by the CLI by a build without JEFFJS_MANUAL_MEMORY.)
    func testBindingsAcrossReuse() {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        for (name, src) in Self.cases {
            evalBool(ctx, src, name)
            rt.runGC()
        }
        ctx.free(); rt.free()
    }

    /// The hold count is exactly the number of counted holders, and a
    /// var-ref whose last hold goes is parked and handed to the next capture.
    func testHoldCountsAndReuse() {
        guard jeffJSArclessVarRefs else { return }
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        let r = ctx.eval(input: """
            var pair = (function(){ var x = {v: 1}; return [function(){ return x; }, function(){ return x; }]; })();
            """, filename: "<holds>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        XCTAssertFalse(r.isException); r.freeValue()

        func varRefOf(_ expr: String) -> JeffJSVarRef? {
            let v = ctx.eval(input: expr, filename: "<holds>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            defer { v.freeValue() }
            guard let o = v.toObject(), o.varRefsRawCount > 0, let raw = o.varRefsRaw else { return nil }
            return raw[0]?.takeUnretainedValue()
        }
        guard let vr = varRefOf("pair[0]") else { return XCTFail("no var-ref") }
        XCTAssertTrue(vr === varRefOf("pair[1]"), "one var-ref for the shared binding")
        XCTAssertTrue(vr.isDetached, "the frame returned: the binding is detached")
        XCTAssertEqual(vr.holdCount, 2, "two closures hold it, the frame no longer does")
        XCTAssertNotEqual(vr.gcListIndex, -1, "a detached var-ref is a GC node")

        let pooledBefore = rt.varRefPool.count
        let d = ctx.eval(input: "pair[1] = null; pair[0] = null; 0", filename: "<holds>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        d.freeValue()
        XCTAssertEqual(rt.varRefPool.count, pooledBefore + 1, "the dead var-ref is parked")
        XCTAssertFalse(vr.isDetached)
        XCTAssertEqual(vr.gcListIndex, -1, "a parked var-ref is off the GC list")
        XCTAssertTrue(vr.value.isUndefined, "its detached copy was released")

        let n = ctx.eval(input: """
            var again = (function(){ var y = 42; return function(){ return y; }; })(); again()
            """, filename: "<holds>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        XCTAssertEqual(n.toInt32(), 42); n.freeValue()
        XCTAssertTrue(varRefOf("again") === vr, "the next capture reuses the parked var-ref")
        XCTAssertEqual(vr.holdCount, 1)
    }

    /// An ARC holder the count does not see (here a mapped `arguments`
    /// slot) keeps the var-ref out of the pool: it must still read the
    /// binding after every closure over it is gone.
    func testColdHolderIsNeverParked() {
        guard jeffJSArclessVarRefs else { return }
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        let r = ctx.eval(input: """
            function f(x){ var c = function(){ return x; }; return [arguments, c]; }
            var p = f({k: 5}); var args = p[0]; p = null;
            for (var j = 0; j < 100; j++) f(j);
            args[0].k
            """, filename: "<cold>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        XCTAssertEqual(r.toInt32(), 5); r.freeValue()
    }
}
