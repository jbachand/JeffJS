// CallThisConformance.swift
// JeffJS — "CallThis": which calls pass the property's object as `this`.
//
// ES §13.3.6.1: a call passes a receiver only when the callee is a property
// *reference*: `o.m()`, `o[k]()`, and a parenthesised reference `(o.m)()`.
// A comma, `||`, `&&`, `??`, `?:` or assignment produces a value, so
// `(0, o.m)()` and `(a || o.m)()` call with `this` undefined. JeffJS used to
// rewrite, after the fact, every get_field whose value reached a call as the
// callee into get_field2 + call_method; that also rewrote `(a || o.m)()` and,
// when the `||` took its left side, called call_method with one value on the
// stack (VM stack underflow; netflix's `(t._loggerOptions.getClientTime ||
// t._getClientTime)()`). The parser now decides method calls itself.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let callThisCases: [(String, String)] = [
        ("o.m() and o[k]() pass o",
         "(function(){ var o = { m: function(){ return this; } }; return o.m() === o && o['m']() === o; })()"),
        ("(o.m)() and ((o.m))() and (o[k])() pass o",
         "(function(){ var o = { m: function(){ return this; } }; return (o.m)() === o && ((o.m))() === o && (o['m'])() === o; })()"),
        ("(0, o.m)() passes undefined",
         "(function(){ var o = { m: function(){ 'use strict'; return this; } }; return (0, o.m)() === undefined && (0, o['m'])() === undefined; })()"),
        ("(a || o.m)() passes undefined whichever side is taken",
         "(function(){ var o = { m: function(){ 'use strict'; return this; }, n: null }; return (o.n || o.m)() === undefined && (o.m || o.n)() === undefined && (o.n ?? o.m)() === undefined && (o && o.m)() === undefined; })()"),
        ("(c ? o.m : o.n)() and (x = o.m)() pass undefined",
         "(function(){ var x, o = { m: function(){ 'use strict'; return this; }, n: null }; return (o.n ? o.n : o.m)() === undefined && (1 ? o.m : o.n)() === undefined && (x = o.m)() === undefined; })()"),
        ("netflix logger shape: (t.opts.getClientTime || t._getClientTime)() with a missing option",
         "(function(){ var t = { opts: {}, _getClientTime: function(){ 'use strict'; return typeof this; } }; var r = []; for (var i = 0; i < 3; i++) r.push((t.opts.getClientTime || t._getClientTime)() + 1); return r.join() === 'undefined1,undefined1,undefined1'; })()"),
        ("sloppy-mode callee gets the global object, not o",
         "(function(){ var g = (0, eval)('this'); var o = { m: function(){ return this; }, n: 0 }; return (o.n || o.m)() === g && (o.m)() === o; })()"),
        ("tagged templates follow the same rule",
         "(function(){ var o = { m: function(){ 'use strict'; return this; }, n: null }; return (o.m)`x` === o && (o.n || o.m)`x` === undefined && o.m`x` === o; })()"),
        ("(o.m)?.() passes o; (o.n || o.m)?.() passes undefined",
         "(function(){ var o = { m: function(){ 'use strict'; return this; }, n: null }; return (o.m)?.() === o && (o.n || o.m)?.() === undefined && o.m?.() === o && o.x?.() === undefined; })()"),
        ("a zero-argument call after a property read in the arguments of another call",
         "(function(){ var o = { k: function(){ 'use strict'; return this; } }; function f(v){ 'use strict'; return [this, v]; } var g = o.k; var r = f(o.k); return r[0] === undefined && r[1] === o.k && g() === undefined; })()"),
        ("new (o.n || o.C)() and new o.C() still construct",
         "(function(){ var o = { n: null, C: function(){ this.k = 1; } }; return new (o.n || o.C)().k === 1 && new o.C().k === 1 && new (o.C)().k === 1; })()"),
        ("method calls with branches in the arguments keep the receiver",
         "(function(){ var o = { v: 3, m: function(a, b){ return this.v + a + (b || 0); } }, c = 0; return o.m(c ? 1 : 2, c || 5) === 10 && o['m'](c && 1, 1) === 4; })()"),
        ("super.m() and private #m() calls keep this",
         "(function(){ class A { m(){ return this; } } class B extends A { #p(){ return this; } m(){ return super.m(); } q(){ return this.#p(); } } var b = new B(); return b.m() === b && b.q() === b; })()"),
    ]

    mutating func testCallThis() {
        runTrueCases("CallThis", JeffJSTestRunner.callThisCases)
    }
}
