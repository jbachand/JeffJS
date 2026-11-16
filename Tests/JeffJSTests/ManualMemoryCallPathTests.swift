// ManualMemoryCallPathTests.swift
// JeffJS — the manual-memory core's call path (JeffJS issue #1 step 3,
// JEFFJS_MANUAL_MEMORY): a closure's body and home object in fields
// instead of the payload enum (quickjs js_closure2 /
// js_bytecode_function_finalizer), recycled closures parked on their closure
// root shape, the frame through an uncounted handle (JS_CallInternal's `sf`),
// borrowed closure-variable and global-variable accesses. The JS cases pin
// behaviour across closure recycling and frame reuse (every expression must
// be `true`; each agrees with QuickJS and JavaScriptCore); the Swift cases
// pin the representation.

import XCTest
import ObjectiveC
@testable import JeffJS

final class ManualMemoryCallPathTests: XCTestCase {

    static let cases: [(String, String)] = [
        ("recycled closures get their own body, captures and name", #"""
            (function(){
              var keep = [];
              for (var r = 0; r < 300; r++) {
                let rr = r;
                (function a(x){ return x + rr; })(1);                // dies at once: parked, reused below
                var g = function named(y){ return y * 2 + rr; };
                if (r % 50 === 0) keep.push(g);
                var h = (z) => z - rr;
                if (r % 75 === 0) keep.push(h);
              }
              var s = 0; for (var i = 0; i < keep.length; i++) s += keep[i](10);
              return keep.length === 10 && keep[0].name === "named" && keep[1].name === "h" && keep[0].length === 1
                  && s === (20+0)+(10-0)+(20+50)+(10-75)+(20+100)+(20+150)+(10-150)+(20+200)+(10-225)+(20+250);
            })()
            """#),
        ("a closure parked after its prototype changed comes back on Function.prototype", #"""
            (function(){
              var P = { marker: 1 };
              for (var i = 0; i < 200; i++) { var f = function(){ return i; }; Object.setPrototypeOf(f, P); f = null; }
              var ok = true;
              for (var j = 0; j < 400; j++) {
                var g = function(){ return j; };
                if (Object.getPrototypeOf(g) !== Function.prototype || g.marker !== undefined || typeof g.call !== "function") ok = false;
              }
              return ok;
            })()
            """#),
        ("a closure parked with own properties comes back clean", #"""
            (function(){
              for (var i = 0; i < 200; i++) { var f = function(a, b){ return a; }; f.extra = i; f.name; f.length; f.prototype; f = null; }
              var ok = true;
              for (var j = 0; j < 400; j++) {
                var g = function q(a, b, c){ return c; };
                if (Object.keys(g).length !== 0 || g.extra !== undefined || g.length !== 3 || g.name !== "q") ok = false;
                if (!g.hasOwnProperty("prototype") || g.prototype.constructor !== g) ok = false;
              }
              return ok;
            })()
            """#),
        ("generator, async and plain closures interleaved keep their own prototypes", #"""
            (function(){
              var GenProto = Object.getPrototypeOf(function*(){}), AsyncProto = Object.getPrototypeOf(async function(){});
              var ok = true;
              for (var i = 0; i < 300; i++) {
                var p = function(){}, g = function*(){ yield i; }, a = async function(){ return i; }, ar = () => i;
                if (Object.getPrototypeOf(p) !== Function.prototype) ok = false;
                if (Object.getPrototypeOf(g) !== GenProto) ok = false;
                if (Object.getPrototypeOf(a) !== AsyncProto) ok = false;
                if (Object.getPrototypeOf(ar) !== Function.prototype) ok = false;
                if (p.hasOwnProperty("prototype") !== true || ar.hasOwnProperty("prototype") !== false) ok = false;
                if (g().next().value !== i) ok = false;
              }
              return ok;
            })()
            """#),
        ("methods keep their home object; arrows inherit it; recycling does not leak it", #"""
            (function(){
              class A { v(){ return 1; } w(){ return 10; } }
              class B extends A {
                v(){ return super.v() + 1; }
                w(){ var f = () => super.w() + 5; return f(); }
                static make(){ return [1,2,3].map((x) => x + super.name.length); }
              }
              var o = { __proto__: { k(){ return 7; } }, k(){ return super.k() * 2; }, viaArrow(){ return (() => super.k())(); } };
              var b = new B(), s = 0;
              for (var i = 0; i < 300; i++) { s += b.v() + b.w() + o.k() + o.viaArrow(); (function(){ return i; })(); }
              var plain = function(){ return typeof super_is_not_here; };
              return s === 300 * (2 + 15 + 14 + 7) && B.make().join() === "2,3,4" && plain() === "undefined";
            })()
            """#),
        ("Function.prototype.toString and bind see a recycled closure's own body", #"""
            (function(){
              var srcs = [];
              for (var i = 0; i < 120; i++) {
                var f = i % 2 ? function odd(a){ return a + 1; } : function even(a, b){ return a - b; };
                if (i > 115) srcs.push(f.toString().indexOf(i % 2 ? "odd" : "even") >= 0 && f.bind(null, 5)(2) === (i % 2 ? 6 : 3));
              }
              return srcs.length === 4 && srcs.every(Boolean);
            })()
            """#),
        ("global writes: writable, read-only, accessor, deleted and re-created globals", #"""
            (function(){
              var g = (0, eval)("this");
              g.__gw_a = 1; var s = 0;
              for (var i = 0; i < 400; i++) { __gw_a = __gw_a + i; s += __gw_a; if (i === 200) { g["__gw_pad" + i] = i; } }
              Object.defineProperty(g, "__gw_ro", { value: 5, writable: false, configurable: true });
              for (var j = 0; j < 50; j++) { __gw_ro = j; }
              var hits = 0;
              Object.defineProperty(g, "__gw_acc", { get(){ return 3; }, set(v){ hits += v; }, configurable: true });
              for (var k = 0; k < 50; k++) { __gw_acc = 2; }
              delete g.__gw_a; var threw = false;
              try { (function(){ "use strict"; __gw_a = 1; })(); } catch (e) { threw = e instanceof ReferenceError; }
              __gw_a = 9;
              var strictThrew = false;
              try { (function(){ "use strict"; __gw_ro = 1; })(); } catch (e) { strictThrew = e instanceof TypeError; }
              var want = 0, a = 1; for (var q = 0; q < 400; q++) { a = a + q; want += a; }
              return s === want && __gw_ro === 5 && hits === 100 && __gw_acc === 3 && threw && __gw_a === 9 && strictThrew;
            })()
            """#),
        ("captured variables through every closure-variable opcode after the frame is gone", #"""
            (function(){
              function mk(){
                var a = 1, b = 2, c = 3, d = 4, e = 5; let t = 10; const k = 7;
                return {
                  get: function(){ return a + b + c + d + e + t + k; },
                  put: function(v){ a = v; b = v + 1; c = v + 2; d = v + 3; e = v + 4; t = v + 5; },
                  inc: function(){ return (a++) + (++b) + (c += 2) + (d = e); },
                  tdz: function(){ try { return u; } catch (x) { return x instanceof ReferenceError; } let u = 1; }
                };
              }
              var o = mk(), p = mk(), r1 = o.get(); o.put(100); var r2 = o.get(), r3 = o.inc(), r4 = o.get();
              for (var i = 0; i < 200; i++) mk().put(i);
              return r1 === 32 && r2 === 100+101+102+103+104+105+7 && r3 === 100 + 102 + 104 + 104 && r4 === 101+102+104+104+104+105+7
                  && p.get() === 32 && o.tdz() === true;
            })()
            """#),
        ("deep and mutual recursion, exceptions through inline frames, arguments objects", #"""
            (function(){
              function depth(n){ return n === 0 ? 0 : 1 + depth(n - 1); }
              function even(n){ return n === 0 ? true : odd(n - 1); } function odd(n){ return n === 0 ? false : even(n - 1); }
              function thrower(n){ if (n === 0) throw new Error("bottom"); return thrower(n - 1) + 1; }
              function args(){ var a = arguments; return (function(){ return a.length + arguments.length + a[0]; })(1, 2); }
              var caught = 0;
              for (var i = 0; i < 50; i++) { try { thrower(30 + i); } catch (e) { if (e.message === "bottom") caught++; } }
              var after = depth(200);   // the frame chain must be intact after the unwinds
              function outer(){ var v = 0; function inner(k){ if (k > 0) { v += k; inner(k - 1); } } inner(40); return v; }
              return depth(500) === 500 && even(300) && !odd(300) && caught === 50 && after === 200 && args(5, 6, 7) === 3 + 2 + 5 && outer() === 820;
            })()
            """#),
        ("natives called through call/apply/bind and callbacks keep the native callee and results", #"""
            (function(){
              var a = [3, 1, 2], s = 0;
              for (var i = 0; i < 300; i++) {
                s += Math.max.call(null, i, 3) + Array.prototype.indexOf.call(a, 2) + Math.abs.apply(null, [-i]) + [].concat.call(a, [i]).length;
                s += a.map(Math.abs).length + a.filter(Boolean).length + Object.prototype.hasOwnProperty.call(a, "length") * 1;
              }
              var stack = ""; try { null.x; } catch (e) { stack = String(e && e.message); }
              var want = 0; for (var j = 0; j < 300; j++) { want += Math.max(j, 3) + 2 + j + 4 + 3 + 3 + 1; }
              return s === want && stack.length > 0;
            })()
            """#),
    ]

    private func eval(_ ctx: JeffJSContext, _ src: String) -> JeffJSValue {
        ctx.eval(input: src, filename: "<mm-call-path>", evalFlags: JS_EVAL_TYPE_GLOBAL)
    }

    func testBehaviourAcrossRecycling() {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        for round in 0..<2 {
            for (name, src) in Self.cases {
                let r = eval(ctx, src)
                if r.isException {
                    let e = ctx.getException()
                    XCTFail("\(name) (round \(round)): threw \(ctx.toSwiftString(e) ?? "?")")
                    e.freeValue()
                    continue
                }
                XCTAssertTrue(r.isBool && r.toBool(), "\(name) (round \(round)): not true")
                r.freeValue()
                rt.runGC()
            }
        }
        XCTAssertNil(ctx.currentFrame, "no frame is current once every call has returned")
        XCTAssertEqual(ctx.callDepth, 0)
    }

    /// Readers still see a bytecode function as the `.bytecodeFunc` payload:
    /// its body, no var-ref list (the closure's var-refs are its raw
    /// buffer), its home object; `fbFast` is that same body once called.
    func testClosureBodyReadsAsThePayload() {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        let f = eval(ctx, "var __f = (function(){ var c = 1; return function(a){ return a + c; }; })(); __f(1); __f")
        defer { f.freeValue() }
        guard let fo = f.toObject() else { return XCTFail("no function") }
        guard case .bytecodeFunc(let body?, let refs, let home) = fo.payload else { return XCTFail("not a bytecodeFunc payload") }
        XCTAssertTrue(refs.isEmpty)
        XCTAssertNil(home)
        XCTAssertTrue(fo.fbFast === body, "fbFast is the payload's body")
        XCTAssertEqual(fo.varRefsRawCount, 1, "the captured variable lives in the raw buffer")

        let m = eval(ctx, "class __A { m(){ return 1; } } class __B extends __A { m(){ return super.m() + 1; } } new __B().m(); __B.prototype.m")
        defer { m.freeValue() }
        let proto = eval(ctx, "__B.prototype")
        defer { proto.freeValue() }
        guard let mo = m.toObject(), case .bytecodeFunc(let mbody?, _, let mhome) = mo.payload else { return XCTFail("method payload") }
        XCTAssertTrue(mhome === proto.toObject(), "the method's home object is its class prototype")
        XCTAssertTrue(mo.fbFast === mbody)

        // Rewriting the payload keeps the body and fbFast, and can drop the home object.
        mo.payload = .bytecodeFunc(functionBytecode: mbody, varRefs: [], homeObject: nil)
        guard case .bytecodeFunc(let again?, _, let noHome) = mo.payload else { return XCTFail("payload after rewrite") }
        XCTAssertTrue(again === mbody)
        XCTAssertNil(noHome)
        XCTAssertTrue(mo.fbFast === mbody, "the same body keeps its fast-path mirror")
        mo.payload = .bytecodeFunc(functionBytecode: mbody, varRefs: [], homeObject: proto.toObject())
        let r = eval(ctx, "new __B().m()")
        XCTAssertEqual(r.toInt32(), 2); r.freeValue()

        XCTAssertLessThanOrEqual(class_getInstanceSize(JeffJSObjectAux.self), 128, "the side box stays in its 128-byte class")
    }

    /// A closure that dies on its realm's closure root shape is parked with
    /// it and reused without a shape reference on either side; teardown
    /// gives every parked owner count back.
    func testParkedClosuresKeepTheirRootShape() {
        guard JeffJSConfig.manualMemory else { return }
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        let r = eval(ctx, "var __s = 0; for (var i = 0; i < 64; i++) { __s += (function(x){ return x; })(i); } __s")
        XCTAssertEqual(r.toInt32(), 2016); r.freeValue()
        XCTAssertGreaterThan(rt.functionPool.count, 0, "the dead closure is parked")
        guard let root = ctx.closureRootShapeRaw else { ctx.free(); rt.free(); return XCTFail("no closure root shape") }
        var onRoot = 0
        rt.functionPool.forEachUnretained { u in
            u._withUnsafeGuaranteedRef { o in
                if o.shapeIdentity == root { onRoot += 1 } else { XCTAssertNil(o.shapeIdentity, "a parked closure keeps the root shape or none") }
                XCTAssertEqual(o.propValues.count, 0)
                if case .opaque(let any) = o.payload { XCTAssertNil(any) } else { XCTFail("a parked closure has no payload") }
                XCTAssertNil(o.fbFast)
            }
        }
        XCTAssertGreaterThan(onRoot, 0, "parked on the closure root shape")
        // A closure whose prototype changed is not parked on its (foreign) root shape.
        let p = eval(ctx, "for (var j = 0; j < 8; j++) { var g = function(){}; Object.setPrototypeOf(g, {}); g = null; } 1")
        p.freeValue()
        rt.functionPool.forEachUnretained { u in
            u._withUnsafeGuaranteedRef { o in
                XCTAssertTrue(o.shapeIdentity == nil || o.shapeIdentity == root)
            }
        }
        ctx.free(); rt.free()
    }

    /// One runtime, two contexts: the function pool is the runtime's, the
    /// closure root shape each context's. A closure parked by one context
    /// and reused by the other must come back on the right prototype.
    func testTwoContextsShareTheFunctionPool() {
        let rt = JeffJSRuntime()
        let a = rt.newContext()
        let b = rt.newContext()
        defer { b.free(); a.free(); rt.free() }
        let probe = """
            (function(){ var ok = true;
              for (var i = 0; i < 40; i++) { var f = function(x){ return x + i; };
                if (Object.getPrototypeOf(f) !== Function.prototype || f(1) !== 1 + i || !(f instanceof Function)) ok = false; }
              return ok; })()
            """
        for round in 0..<4 {
            for (label, ctx) in [("a", a), ("b", b)] {
                let r = eval(ctx, probe)
                XCTAssertTrue(r.isBool && r.toBool(), "context \(label), round \(round)")
                r.freeValue()
            }
        }
    }
}
