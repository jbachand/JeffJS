// ClassStaticElementConformance.swift
// JeffJS — conformance group "ClassStaticElements" (ES §15.7.14
// ClassDefinitionEvaluation: every static ClassElement is defined on F, the
// class constructor, whatever its position relative to `constructor(){}`).
// The parser made a default constructor closure at the class head, defined
// statics on it as they were parsed, then swapped in the explicit constructor's
// closure: every static method / accessor / static private brand written before
// `constructor` was lost. google.com's Wiz controllers are
// `pG=class extends _.Nr{static Ta(){return{controller:...}}constructor(a){...}}`;
// Wiz reads `ctor.hasOwnProperty("Ta")`, fell back to `()=>({})` and constructed
// the search box controller without its dependencies (no trending searches).
// A computed static method (`static [k](){}`) also corrupted the stack.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let classStaticElementCases: [(String, String)] = [
        ("static method before the constructor (declaration)",
         "(function(){ class A { static s(){ return 'A'; } constructor(){ this.x = 1; } } return A.hasOwnProperty('s') && A.s() === 'A' && new A().x === 1; })()"),
        ("the google.com shape: anonymous class expression, extends, static Ta() before constructor",
         "(function(){ var _ = {}; _.Nr = class { static Ta(){ return {}; } }; var pG = class extends _.Nr { static Ta(){ return { controller: { Fn: 1 } }; } constructor(a){ super(); this.Fn = a.controller.Fn; } }; var dep = pG.hasOwnProperty('Ta') ? pG.Ta : function(){ return {}; }; return new pG(dep.call(pG)).Fn === 1; })()"),
        ("static getter and setter before the constructor",
         "(function(){ class A { static get g(){ return 7; } static set s(v){ this._s = v; } constructor(){} } A.s = 3; return A.g === 7 && A._s === 3; })()"),
        ("statics before and after the constructor all land on the class",
         "(function(){ class A { static a(){} static b(){} constructor(){} static c(){} } return ['a','b','c'].every(function(k){ return A.hasOwnProperty(k); }); })()"),
        ("derived class: super in a static method before the constructor",
         "(function(){ class B { static who(){ return 'B'; } constructor(v){ this.v = v; } } class D extends B { static who(){ return 'D>' + super.who(); } constructor(){ super(5); } } return D.who() === 'D>B' && new D().v === 5; })()"),
        ("static private method before the constructor (brand on the class)",
         "(function(){ class P { static #p(){ return 'p'; } static s(){ return P.#p(); } constructor(){ this.x = 1; } } return P.s() === 'p' && new P().x === 1; })()"),
        ("computed static method",
         "(function(){ var k = 'comp'; class A { static [k](){ return 1; } } return A.hasOwnProperty('comp') && A.comp() === 1; })()"),
        ("computed static accessors before the constructor",
         "(function(){ var k = 'g'; class B { static get [k + 'x'](){ return 7; } static set [k + 'y'](v){ this._y = v; } constructor(){} } B.gy = 3; return B.gx === 7 && B._y === 3; })()"),
        ("static [Symbol.hasInstance]",
         "(function(){ class C { static [Symbol.hasInstance](o){ return o === 1; } } return (1 instanceof C) && !({} instanceof C); })()"),
        ("the explicit constructor is the class (prototype.constructor, instances, static fields)",
         "(function(){ class G { x = 1; static y = 2; static s(){ return 3; } constructor(){ this.z = this.x + G.y; } } var g = new G(); return g.z === 3 && G.prototype.constructor === G && Object.getPrototypeOf(g) === G.prototype && G.s() === 3; })()"),
        ("a class has at most one constructor (early error)",
         "(function(){ try { eval('(class { constructor(){} constructor(){} })'); return false; } catch (e) { return e instanceof SyntaxError; } })()"),
    ]

    mutating func testClassStaticElements() {
        runTrueCases("ClassStaticElements", JeffJSTestRunner.classStaticElementCases)
    }
}
