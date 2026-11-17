// ManualMemoryPropertyTests.swift
// JeffJS — the manual-memory core's property paths (JeffJS issue #1 step 4,
// JEFFJS_MANUAL_MEMORY): [[Get]], [[Set]] and [[HasProperty]] borrow the object,
// its shape and every prototype they walk (quickjs JS_GetPropertyInternal /
// JS_SetPropertyInternal / JS_HasProperty hold no reference either), accessors
// are called through uncounted handles, the polymorphic cache, array elements
// and typed arrays are read through guaranteed references. What must not
// change: accessors that delete or redefine themselves or cut the prototype
// chain while they run, a Proxy met on the chain, polymorphic sites, frozen
// and growing arrays, constants read in loops. Expected values are QuickJS's.

import XCTest
@testable import JeffJS

final class ManualMemoryPropertyTests: XCTestCase {

    static let cases: [(String, String, String)] = [
        ("accessorsOnChain", #"""
            (function () {
              var log = [];
              var A = { get g() { return this.v + 1; }, set s(x) { this.v = x * 2; } };
              var B = Object.create(A); var C = Object.create(B); C.v = 1;
              var s = 0;
              for (var i = 0; i < 300; i++) { C.s = i; s += C.g; if (i === 100) Object.defineProperty(B, "g", { get: function () { return -1; }, configurable: true }); if (i === 200) delete B.g; }
              return s + ":" + C.v + ":" + ("g" in C) + ("s" in C) + ("zz" in C) + C.hasOwnProperty("g");
            })()
            """#, #""59700:598:truetruefalsefalse""#),
        ("getterThatDeletesItself", #"""
            (function () {
              var o = { get x() { delete this.x; return 7; }, y: 1 };
              var p = Object.create({ get q() { Object.setPrototypeOf(r, null); return 9; } }); var r = Object.create(p);
              return o.x + ":" + o.x + ":" + r.q + ":" + r.q;
            })()
            """#, #""7:undefined:9:undefined""#),
        ("setterThatRedefines", #"""
            (function () {
              var n = 0;
              var o = { set x(v) { n += v; Object.defineProperty(this, "x", { value: v, writable: true, configurable: true }); } };
              o.x = 5; o.x = 6;
              var base = { set y(v) { n += 100; } }; var d = Object.create(base); d.y = 1; d.y = 2;
              return n + ":" + o.x + ":" + d.hasOwnProperty("y");
            })()
            """#, #""205:6:false""#),
        ("proxyOnChain", #"""
            (function () {
              var seen = [];
              var target = { a: 1 };
              var px = new Proxy(target, {
                get: function (t, k, r) { seen.push("get:" + String(k)); return k === "a" ? 10 : undefined; },
                has: function (t, k) { seen.push("has:" + String(k)); return k === "a"; },
                set: function (t, k, v, r) { seen.push("set:" + String(k)); t[k] = v; return true; }
              });
              var o = Object.create(px); o.own = 1;
              var s = o.a + (o.b === undefined ? 1 : 0) + o.own + ("a" in o ? 100 : 0) + ("c" in o ? 1000 : 0);
              o.z = 5;
              return s + ":" + seen.join(",") + ":" + target.z + ":" + Object.prototype.hasOwnProperty.call(o, "z");
            })()
            """#, #""NaN:set:own,get:a,get:b,get:own,has:a,has:c,set:z:5:false""#),
        ("polymorphicReads", #"""
            (function () {
              function P1() { this.a = 1; } P1.prototype.m = function () { return 1; };
              function P2() { this.b = 2; this.a = 2; } P2.prototype.m = function () { return 2; };
              function P3() { this.c = 3; this.b = 0; this.a = 3; } P3.prototype = Object.create(P1.prototype); Object.defineProperty(P3.prototype, "k", { get: function () { return this.a * 10; } });
              var objs = [new P1(), new P2(), new P3(), { a: 4, m: function () { return 4; } }], s = 0;
              for (var i = 0; i < 2000; i++) { var o = objs[i & 3]; s += o.a + o.m() + (o.k || 0); }
              return s;
            })()
            """#, #"24000"#),
        ("arraysAndTypedArrays", #"""
            (function () {
              var a = [1, 2, 3, , 5], t = new Float64Array(8), u = new Uint8Array(4), s = 0;
              for (var i = 0; i < 400; i++) {
                a[i % 5] = i; t[i & 7] = i * 0.5; u[i & 3] = i;
                s += (a[(i + 1) % 5] || 0) + t[(i + 3) & 7] + u[(i + 1) & 3] + a.length + t.length;
                if (i === 150) a.push(9, 9); if (i === 250) Object.freeze(a);
              }
              var b = [...a, ...[7, 8]], c = []; for (var j = 0; j < 50; j++) c.push(j); c = [...c, ...b];
              return s + ":" + a.join("|") + ":" + b.length + ":" + c.length + ":" + (3 in [1, 2, 3, , 5]) + (0 in u) + (9 in u);
            })()
            """#, #""154460.5:250|246|247|248|249|9|9:9:59:falsetruefalse""#),
        ("constantsInLoops", #"""
            (function () {
              var s = "", n = 0;
              for (var i = 0; i < 300; i++) { n += 1234567 + 0.5; if ((i & 31) === 0) s += "k" + 100000 + "x"; n = n % 1000003; }
              return s.length + ":" + n;
            })()
            """#, #""80:369140""#),
        // `new` with the arguments left on the stack (quickjs JS_CallConstructorInternal, argc / argv)
        ("constructors", #"""
            (function () {
              function F(a, b) { this.a = a; this.b = b === undefined ? "u" : b; this.n = arguments.length; }
              function G(a) { this.a = a; return { other: a }; }
              function H(a) { this.a = a; return 5; }
              class A { constructor(x, y) { this.x = x; this.y = y; this.t = new.target === A ? "A" : new.target.name; } }
              class B extends A { constructor(x) { super(x, x + 1); this.z = 1; } get sum() { return this.x + this.y + this.z; } }
              class C extends B { }
              var Bd = F.bind(null, 7), out = [], s = 0;
              for (var i = 0; i < 400; i++) {
                var f = new F(i), f2 = new F(i, 2, 3, 4), g = new G(i), h = new H(i), b = new B(i), c = new C(i), d = new Bd(i);
                s += f.a + f.n + f2.n + f2.b + g.other + (g.a === undefined ? 1 : 0) + h.a + b.sum + c.sum + d.a + d.b;
                if (i === 399) out.push(f.b, b.t, c.t, b instanceof A, c instanceof B, g instanceof G, h instanceof H, Object.getPrototypeOf(d) === F.prototype);
              }
              var rc = Reflect.construct(F, [1, 2], B); out.push(Object.getPrototypeOf(rc) === B.prototype, rc.n);
              var errs = [];
              [function () { new (function* () {})(); }, function () { new (() => 1)(); }, function () { new Math.max(); }, function () { A(); }, function () { new (class extends A { constructor() { this.q = 1; } })(); }, function () { new 5; }]
                .forEach(function (t) { try { t(); errs.push("no"); } catch (e) { errs.push(e instanceof TypeError ? "T" : e instanceof ReferenceError ? "R" : "?"); } });
              var deep = 0; function D(n) { this.n = n; if (n > 0) this.c = new D(n - 1); deep++; } new D(100);
              return s + ":" + out.join(",") + ":" + errs.join("") + ":" + deep;
            })()
            """#, #""646000:u,B,C,true,true,false,true,true,true,2:TTTTRT:101""#),
    ]

    private func run(_ ctx: JeffJSContext, _ name: String, _ src: String, _ want: String, _ label: String) {
        let r = ctx.eval(input: "JSON.stringify(" + src + ")", filename: "<mm-props>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        if r.isException {
            let e = ctx.getException()
            XCTFail("\(name) (\(label)): threw \(ctx.toSwiftString(e) ?? "?")")
            e.freeValue()
            return
        }
        XCTAssertEqual(ctx.toSwiftString(r), want, "\(name) (\(label))")
        r.freeValue()
    }

    func testPropertyPathsComputeWhatQuickJSComputes() {
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

    func testPropertyPathsFromCold() {
        for (name, src, want) in Self.cases {
            let rt = JeffJSRuntime()
            let ctx = rt.newContext()
            run(ctx, name, src, want, "cold")
            ctx.free(); rt.free()
        }
    }
}
