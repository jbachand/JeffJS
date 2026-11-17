// InheritedReadOnlySetTests.swift
// JeffJS — OrdinarySetWithOwnDescriptor step 2.a (quickjs
// JS_SetPropertyInternal `read_only_prop`): a write to a name that is a
// non-writable data property on a prototype is refused (a TypeError in strict
// code) instead of creating an own property on the receiver, and a function's
// or error's deferred own properties count when they are met on the chain.
// Expected values are QuickJS's.

import XCTest
@testable import JeffJS

final class InheritedReadOnlySetTests: XCTestCase {

    static let cases: [(String, String, String)] = [
        ("sloppyWriteIsIgnored", #"""
            (function () {
              var P = {}; Object.defineProperty(P, "r", { value: 1, writable: false });
              var o = Object.create(Object.create(P)); o.r = 5; o["r"] = 6; var k = "r"; o[k] = 7; o.w = 2;
              return [o.r, Object.keys(o).join("/"), Reflect.set(o, "r", 8), Reflect.set(o, "z", 8), o.z].join();
            })()
            """#, #""1,w,false,true,8""#),
        ("strictWriteThrows", #"""
            (function () {
              "use strict";
              var out = [];
              var P = Object.freeze({ k: 1 }); var q = Object.create(P);
              try { q.k = 2; out.push("no"); } catch (e) { out.push(e instanceof TypeError, q.k, Object.keys(q).length); }
              Object.defineProperty(q, "k", { value: 3, writable: true, configurable: true, enumerable: true }); q.k = 4; out.push(q.k);
              function V() { try { this.ro = 2; out.push("no"); } catch (e) { out.push(e instanceof TypeError); } }
              Object.defineProperty(V.prototype, "ro", { value: 1 }); new V();
              var m = Object.create(Math); try { m.PI = 3; out.push("no"); } catch (e) { out.push(e instanceof TypeError); } m.abs = 1; out.push(m.abs);
              return out.join();
            })()
            """#, #""true,1,0,4,true,true,1""#),
        ("writablePrototypePropertiesStillShadow", #"""
            (function () {
              "use strict";
              function D() { this.a = 1; } D.prototype.b = 5; var d = new D(); d.b = 6;
              var e2 = Object.create(new Error("m")); e2.message = "x"; e2.stack = "s";
              var acc = Object.create({ get q() { return 1; }, set q(v) { this._q = v; } }); acc.q = 9;
              return [d.b, D.prototype.b, Object.keys(d).join("/"), e2.message + e2.stack, acc._q, acc.q].join();
            })()
            """#, #""6,5,a/b,xs,9,1""#),
        ("functionsOnTheChain", #"""
            (function () {
              var fn = function f(a, b) {}; var o = Object.create(fn);
              var before = [o.name, o.length, typeof o.prototype].join("/");
              o.prototype = 1; o.name = "n"; o.length = 9; o.other = 2;
              return [before, Object.keys(o).join("/"), o.name, o.length, typeof fn.prototype].join();
            })()
            """#, #""f/2/object,prototype/other,f,2,object""#),
    ]

    private func run(_ ctx: JeffJSContext, _ name: String, _ src: String, _ want: String, _ label: String) {
        let r = ctx.eval(input: "JSON.stringify(" + src + ")", filename: "<inherited-ro>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        if r.isException {
            let e = ctx.getException()
            XCTFail("\(name) (\(label)): threw \(ctx.toSwiftString(e) ?? "?")")
            e.freeValue()
            return
        }
        XCTAssertEqual(ctx.toSwiftString(r), want, "\(name) (\(label))")
        r.freeValue()
    }

    func testInheritedReadOnlyWritesMatchQuickJS() {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        for round in 0..<2 {
            for (name, src, want) in Self.cases { run(ctx, name, src, want, "round \(round)") }
            rt.runGC()
        }
        XCTAssertNil(ctx.currentFrame)
    }

    func testInheritedReadOnlyWritesFromCold() {
        for (name, src, want) in Self.cases {
            let rt = JeffJSRuntime()
            let ctx = rt.newContext()
            run(ctx, name, src, want, "cold")
            ctx.free(); rt.free()
        }
    }
}
