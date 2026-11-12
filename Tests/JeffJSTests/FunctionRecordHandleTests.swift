// FunctionRecordHandleTests.swift
// JeffJS — the dispatch reads the running function's bytecode record through
// an uncounted handle under JEFFJS_MANUAL_MEMORY (Core/JeffJSFBRef.swift;
// quickjs JS_CallInternal's borrowed `b`). The record is kept alive by the
// function object the caller holds, so these cases drop, replace or collect
// every other reference to a function while it is running and then keep
// using it: constants, closures created after the drop, inline-cache sites,
// the trace tier, tail calls, generators and async functions.

import XCTest
@testable import JeffJS

final class FunctionRecordHandleTests: XCTestCase {

    static let cases: [(String, String)] = [
        ("a function that clears its only binding keeps running", """
            (function(){ var o = { f: function(n){ o.f = null; o = null; var s = "k" + n; var g = function(){ return s + 1; }; return g() + [1,2,3].map(function(x){ return x * n; }).join(""); } };
              return o.f(2) === "k21246"; })()
            """),
        ("a function replaced while it runs finishes with its own body", """
            (function(){ var holder = {};
              holder.f = function(n){ holder.f = function(){ return -1; }; var t = 0; for (var i = 0; i < 2000; i++) { t += i % 7; } return t + n + holder.f(); };
              return holder.f(5) === 5995 + 5 - 1 && holder.f() === -1; })()
            """),
        ("recursion through a binding that is reassigned mid-flight", """
            (function(){ var f = function(n){ if (n === 3) { var old = f; f = function(m){ return 100 + m; }; return old(n - 1) + 1; } return n <= 0 ? 0 : f(n - 1) + n; };
              var first = f(5);
              return first === 5 + 4 + 1 + 2 + 101 && f(1) === 101; })()
            """),
        ("callbacks dropped by their caller while still on the stack", """
            (function(){ var out = []; var arr = [1,2,3,4];
              arr.forEach(function cb(v, i, a){ if (i === 0) { a.length = 4; } var k = { v: v }; out.push((function(){ return k.v * 2; })()); });
              var fns = []; for (var i = 0; i < 300; i++) { fns.push(function(x){ fns.length = 0; return x + 1; }); }
              var last = fns[299]; var r = last(41);
              return out.join(",") === "2,4,6,8" && r === 42 && fns.length === 0; })()
            """),
        ("a tail call from a function that has just lost its binding", """
            (function(){ "use strict"; var o = {}; function g(a, b){ return a * b; }
              o.f = function(n){ delete o.f; return g(n, 7); };
              var f = o.f; var r = f(6); f = null;
              var s = 0; for (var i = 0; i < 500; i++) { var h = function(q){ return g(q, 2); }; s += h(i); h = null; }
              return r === 42 && s === 249500; })()
            """),
        ("a generator whose function object is gone before it resumes", """
            (function(){ function mk(){ return function*(n){ var a = "a" + n; yield a; var b = [n, n + 1].map(function(x){ return x * 2; }); yield b.join("-"); return a + b.length; }; }
              var it = mk()(4); var junk = []; for (var i = 0; i < 400; i++) { junk.push(mk()); } junk = null;
              var r1 = it.next().value, r2 = it.next().value, r3 = it.next();
              return r1 === "a4" && r2 === "8-10" && r3.value === "a42" && r3.done === true; })()
            """),
        ("hot loop entering the trace tier inside a dropped function", """
            (function(){ var box = { run: function(n){ box = null; var t = 0; for (var i = 0; i < n; i++) { t = (t + i * 3) % 1000003; } var u = 0; for (var j = 0; j < n; j++) { u += (function(z){ return z & 3; })(j); } return t + u; } };
              var a = box.run(20000); return a === (function(n){ var t = 0; for (var i = 0; i < n; i++) { t = (t + i * 3) % 1000003; } var u = 0; for (var j = 0; j < n; j++) { u += j & 3; } return t + u; })(20000); })()
            """),
        ("global reads through the cache across a shape change", """
            (function(){ globalThis.__fh_a = 1; globalThis.__fh_b = 2;
              function rd(){ return __fh_a + __fh_b; }
              var s = 0; for (var i = 0; i < 300; i++) { s += rd(); if (i === 150) { globalThis["__fh_x" + i] = i; __fh_a = 10; } }
              delete globalThis.__fh_a; var threw = false; try { rd(); } catch (e) { threw = e instanceof ReferenceError; }
              return s === 151 * 3 + 149 * 12 && threw; })()
            """),
    ]

    func testFunctionsOutliveTheirBindings() {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        for (name, src) in Self.cases {
            let r = ctx.eval(input: src, filename: "<fb-handle>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            if r.isException {
                let e = ctx.getException()
                XCTFail("\(name): threw \(ctx.toSwiftString(e) ?? "?")")
                e.freeValue()
                continue
            }
            XCTAssertTrue(r.isBool && r.toBool(), "\(name): not true")
            r.freeValue()
        }
    }

    func testAsyncFunctionDroppedBeforeItResumes() {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        let src = """
            globalThis.__fh_out = "";
            (function(){ var o = { f: async function(n){ o = null; var a = "p" + n; await null; var b = [1,2].map(function(x){ return x + n; }); await Promise.resolve(1); globalThis.__fh_out = a + b.join(""); } };
              o.f(3); })();
            """
        let r = ctx.eval(input: src, filename: "<fb-handle-async>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        XCTAssertFalse(r.isException)
        r.freeValue()
        _ = rt.executePendingJobs()
        let v = ctx.eval(input: "__fh_out", filename: "<fb-handle-async>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        XCTAssertEqual(ctx.toSwiftString(v), "p345")
        v.freeValue()
    }
}
