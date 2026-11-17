// DerivedConstructorTests.swift
// JeffJS — derived-class construction (quickjs OP_special_object,
// JS_SetPropertyInternal). `super(...)`, `super.x` and `new.target` read the
// frame's fields without building the frame's argument and variable arrays
// (only the arguments objects need those), and a property add walks ordinary
// prototypes that lack the name with one shape lookup per level. What must
// not change: the arguments objects, setters, getters without setters and
// proxies met on the chain, functions and errors (deferred own properties)
// on the chain. Expected values are QuickJS's.

import XCTest
@testable import JeffJS

final class DerivedConstructorTests: XCTestCase {

    static let cases: [(String, String, String)] = [
        ("superCallSuperPropertyNewTarget", #"""
            (function () {
              class A { constructor(x) { this.x = x; this.nt = new.target === B ? "B" : new.target === A ? "A" : "?"; } m() { return "A.m" + this.x; } static s() { return "As"; } }
              class B extends A { constructor(x) { super(x); this.y = 1; } m() { return "B>" + super.m(); } static s() { return "B>" + super.s(); } get g() { return super.m() + "!"; } }
              class C extends B { constructor() { super(...arguments); this.z = arguments.length; } }
              var s = 0; for (var i = 0; i < 300; i++) { var q = new B(i); s += q.x + q.y; }
              var b = new B(3), c = new C(7, 8, 9);
              return [s, b.x, b.y, b.nt, b.m(), B.s(), b.g, c.x, c.y, c.z, c.nt, c.m()].join();
            })()
            """#, #""45150,3,1,B,B>A.m3,B>As,A.m3!,7,1,3,?,B>A.m7""#),
        ("argumentsObjectsStillSeeTheFrame", #"""
            (function () {
              function F(a, b) { this.n = arguments.length; this.t = new.target === F; }
              function G(a) { arguments[0] = 9; return a + ":" + arguments.length; }
              function H(a) { "use strict"; arguments[0] = 9; return a + ":" + arguments.length; }
              class K { constructor(a) { this.args = Array.prototype.slice.call(arguments).join("/"); } }
              class L extends K { constructor(a, b) { super(b, a, arguments.length); this.own = arguments[1]; } }
              var f = new F(1, 2, 3), l = new L("p", "q");
              return [f.n, f.t, G(1, 2), H(1, 2), l.args, l.own].join();
            })()
            """#, #""3,true,9:2,1:2,q/p/2,q""#),
        ("addsUnderSettersGettersAndProxies", #"""
            (function () {
              var log = [];
              var P1 = { set v(x) { log.push("set" + x); } }; var o1 = Object.create(Object.create(P1)); o1.v = 1; o1.w = 2;
              var P3 = { get q() { return 1; } }; var o3 = Object.create(P3); o3.q = 2;
              var o4; var px = new Proxy({}, { set: function (t, k, v, r) { log.push("trap:" + String(k) + (r === o4)); return true; } });
              o4 = Object.create(px); o4.zz = 1;
              class D { constructor() { this.a = 1; } } D.prototype.b = 5; var d = new D(); d.b = 6;
              return [log.join(), Object.keys(o1), o3.q, Object.keys(o3).length, Object.keys(o4).length, d.b, D.prototype.b, Object.keys(d).join("/")].join(";");
            })()
            """#, #""set1,trap:zztrue;w;1;0;0;6;5;a/b""#),
        ("constructorsThatReturnOrExtendBuiltins", #"""
            (function () {
              class E extends Array { constructor(n) { super(n); this.tag = "e"; } } var e = new E(3);
              class X { constructor() { return { r: 1 }; } } class Y extends X { constructor() { super(); this.w = 2; } } var y = new Y();
              var early = "";
              class A { constructor(x) { this.x = x; } }
              class Z extends A { constructor() { try { this.x = 1; } catch (err) { early = String(err instanceof ReferenceError); } super(1); } }
              return [e.length, e.tag, e instanceof Array, y.r, y.w, y instanceof Y, new Z().x, early].join();
            })()
            """#, #""3,e,true,1,2,false,1,true""#),
    ]

    private func run(_ ctx: JeffJSContext, _ name: String, _ src: String, _ want: String, _ label: String) {
        let r = ctx.eval(input: "JSON.stringify(" + src + ")", filename: "<derived>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        if r.isException {
            let e = ctx.getException()
            XCTFail("\(name) (\(label)): threw \(ctx.toSwiftString(e) ?? "?")")
            e.freeValue()
            return
        }
        XCTAssertEqual(ctx.toSwiftString(r), want, "\(name) (\(label))")
        r.freeValue()
    }

    func testDerivedConstructionComputesWhatQuickJSComputes() {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        for round in 0..<3 {
            for (name, src, want) in Self.cases { run(ctx, name, src, want, "round \(round)") }
            rt.runGC()
        }
        XCTAssertNil(ctx.currentFrame)
        XCTAssertEqual(ctx.callDepth, 0)
    }

    func testDerivedConstructionFromCold() {
        for (name, src, want) in Self.cases {
            let rt = JeffJSRuntime()
            let ctx = rt.newContext()
            run(ctx, name, src, want, "cold")
            ctx.free(); rt.free()
        }
    }
}
