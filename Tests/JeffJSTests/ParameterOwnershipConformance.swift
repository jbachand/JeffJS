// ParameterOwnershipConformance.swift
// JeffJS — "ParameterOwnership": storing into a parameter slot.
//
// A frame's argument slots used to hold the caller's borrowed references
// only, so a store into a parameter could not release the value it replaced:
// every value but the last leaked (`e = e.next` list walks leaked each
// node), and on the native-call path the last one too. Functions that can
// store into a parameter (put_arg/set_arg, mapped `arguments`, a closure or
// direct eval capturing a parameter) now own their argument slots: the call
// paths dup the arguments in and release them at exit, and stores release
// the replaced value (see "Argument slots" in JeffJSInterpreter.swift). The
// failure mode to guard against is the opposite one: releasing a value the
// caller still owns. Every case below keeps the caller's objects and checks
// they survive many calls through each call path.
//
// Every case is (name, JS expression that must evaluate to `true`). The
// async case observes its result synchronously on JeffJS (its `await` on a
// settled value continues in place); a spec-deferring engine sees 0.

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let parameterOwnershipCases: [(String, String)] = [
        ("put_arg releases the old value, the caller's object survives",
         "(function(){ var o = { v: 1 }; function f(a){ a = { v: 2 }; a = { v: 3 }; return a.v; } var s = 0; for (var i = 0; i < 2000; i++) s += f(o); return s === 6000 && o.v === 1; })()"),
        ("list walk through a parameter keeps the list intact",
         "(function(){ var l = { v: 1, next: { v: 2, next: { v: 3, next: null } } }; function sum(e){ var s = 0; while (e) { s += e.v; e = e.next; } return s; } var t = 0; for (var i = 0; i < 2000; i++) t += sum(l); return t === 12000 && l.next.next.v === 3; })()"),
        ("native callers (forEach, call, apply, Reflect.apply, bind) own the reassigned slot",
         "(function(){ var o = { v: 5 }; function f(a){ var x = a.v; a = { v: x + 1 }; return a.v; } var s = 0; for (var i = 0; i < 500; i++) { [o].forEach(function(e){ s += f(e); }); s += f.call(null, o) + f.apply(null, [o]) + Reflect.apply(f, null, [o]) + f.bind(null, o)(); [o].forEach(f); } return s === 500 * 30 && o.v === 5; })()"),
        ("missing and surplus arguments assigned",
         "(function(){ function f(a, b, c){ b = { v: 1 }; c = { v: 2 }; a = b; return a.v + b.v + c.v + arguments.length; } var s = 0; for (var i = 0; i < 1000; i++) s += f() + f(1) + f(1, 2, 3, 4, 5); return s === 1000 * (4 + 5 + 9); })()"),
        ("set_arg (assignment used as a value)",
         "(function(){ var o = { v: 1 }; function f(a){ var y = (a = { v: 7 }); return y.v + a.v; } var s = 0; for (var i = 0; i < 1000; i++) s += f(o); return s === 14000 && o.v === 1; })()"),
        ("parameter assigned in a loop (trace)",
         "(function(){ function f(a){ var s = 0; for (var i = 0; i < 50; i++) { a = { i: i }; s += a.i; } return s + a.i; } var t = 0; for (var k = 0; k < 200; k++) t += f(null); return t === 200 * (1225 + 49); })()"),
        ("mapped arguments alias the parameter both ways",
         "(function(){ function f(a, b){ arguments[0] = { v: 2 }; var x = a; a = { v: 3 }; var y = arguments[0]; b = { v: 4 }; return x.v * 100 + y.v * 10 + arguments[1].v; } var s = 0, o = { v: 1 }; for (var i = 0; i < 1000; i++) s += f(o, o); return s === 1000 * 234 && o.v === 1; })()"),
        ("mapped arguments with a missing argument stay unmapped",
         "(function(){ function f(a, b){ b = { v: 1 }; arguments[1] = { v: 9 }; return b.v + (arguments.length === 1 ? 10 : 0); } var s = 0; for (var i = 0; i < 1000; i++) s += f({}); return s === 11000; })()"),
        ("strict arguments do not alias",
         "(function(){ 'use strict'; function f(a){ arguments[0] = { v: 2 }; a = { v: 3 }; return a.v * 10 + arguments[0].v; } var s = 0; for (var i = 0; i < 1000; i++) s += f({ v: 1 }); return s === 32000; })()"),
        ("closure writes a captured parameter",
         "(function(){ function f(a){ var set = function(v){ a = v; }; var get = function(){ return a; }; set({ v: 2 }); set({ v: 3 }); var r = get().v; return [r, get, set]; } var s = 0, keep; for (var i = 0; i < 1000; i++) { var r = f({ v: 1 }); s += r[0]; keep = r; } keep[2]({ v: 9 }); return s === 3000 && keep[1]().v === 9; })()"),
        ("parameter captured then reassigned in the frame",
         "(function(){ function f(a){ var g = function(){ return a.v; }; a = { v: 2 }; a = { v: 3 }; return g; } var s = 0; for (var i = 0; i < 1000; i++) s += f({ v: 1 })(); return s === 3000; })()"),
        ("default parameter closure sees body assignments to the parameter",
         "(function(){ function f(a, g = function(){ return a; }){ a = { v: 2 }; return g().v; } var s = 0; for (var i = 0; i < 1000; i++) s += f({ v: 1 }); return s === 2000; })()"),
        ("default parameter value is reassigned",
         "(function(){ function f(a = { v: 1 }){ var x = a.v; a = { v: x + 1 }; return a.v; } var s = 0; for (var i = 0; i < 1000; i++) s += f() + f({ v: 5 }); return s === 1000 * 8; })()"),
        ("rest parameter and a reassigned parameter",
         "(function(){ function f(a, ...r){ a = r; r = { length: 9 }; return a.length + r.length; } var s = 0; for (var i = 0; i < 1000; i++) s += f(0, {}, {}); return s === 11000; })()"),
        ("direct eval assigns a parameter",
         "(function(){ function f(a){ eval('a = { v: a.v + 1 }'); a = { v: a.v + 1 }; return a.v; } var s = 0, o = { v: 1 }; for (var i = 0; i < 200; i++) s += f(o); return s === 600 && o.v === 1; })()"),
        ("eval in a nested function assigns the outer parameter",
         "(function(){ function f(a){ (function(){ eval('a = { v: 4 }'); })(); return a.v; } var s = 0; for (var i = 0; i < 200; i++) s += f({ v: 1 }); return s === 800; })()"),
        ("exceptions unwind frames with reassigned parameters",
         "(function(){ function g(a){ a = { v: 2 }; throw a; } function f(a){ a = { v: 1 }; return g(a); } var s = 0, o = { v: 0 }; for (var i = 0; i < 1000; i++) { try { f(o); } catch (e) { s += e.v; } } return s === 2000 && o.v === 0; })()"),
        ("generator parameters reassigned across yields",
         "(function(){ function* g(a){ a = { v: a.v + 1 }; yield a.v; a = { v: a.v + 1 }; yield a.v; } var s = 0, o = { v: 1 }; for (var i = 0; i < 500; i++) { var it = g(o); s += it.next().value + it.next().value; it.next(); var it2 = g(o); it2.next(); } return s === 500 * 5 && o.v === 1; })()"),
        ("async parameters reassigned across await",
         "(function(){ var out = 0; async function f(a){ a = { v: a.v + 1 }; await null; a = { v: a.v + 1 }; await Promise.resolve(0); out += a.v; return a; } var o = { v: 1 }; for (var i = 0; i < 500; i++) f(o); return (out === 1500 || out === 0) && o.v === 1; })()"),
        ("recursion deep enough to leave the carved stack",
         "(function(){ function d(n, a){ a = { n: n }; return n > 0 ? d(n - 1, a) + a.n : 0; } var s = 0; for (var i = 0; i < 50; i++) s += d(150, null); return s === 50 * 11325; })()"),
        ("methods, constructors and derived constructors",
         "(function(){ var o = { m: function(a){ a = { v: 2 }; return a.v; } }; function K(a){ a = { v: 3 }; this.v = a.v; } class B { constructor(a){ a = { v: 4 }; this.b = a.v; } } class D extends B { constructor(a){ a = { v: 5 }; super(a); a = { v: 6 }; this.d = a.v; } } var s = 0; for (var i = 0; i < 500; i++) { var x = new D({}); s += o.m({}) + new K({}).v + x.b + x.d; } return s === 500 * 15; })()"),
        ("arrow functions and tail calls",
         "(function(){ var ar = (a) => { a = { v: 2 }; return a.v; }; function t(a){ a = { v: 1 }; return ar(a); } var s = 0; for (var i = 0; i < 1000; i++) s += t({}) + ar(null); return s === 4000; })()"),
        ("a returned parameter is the caller's to keep",
         "(function(){ function f(a){ a = { v: 2 }; a = { v: 3 }; return a; } var keep = []; for (var i = 0; i < 1000; i++) keep.push(f({})); return keep.every(function(x){ return x.v === 3; }); })()"),
    ]

    mutating func testParameterOwnership() {
        runTrueCases("ParameterOwnership", JeffJSTestRunner.parameterOwnershipCases)
    }
}
