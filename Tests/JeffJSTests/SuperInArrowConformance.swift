// SuperInArrowConformance.swift
// JeffJS — conformance group "SuperInArrow" (ES §15.3 arrow functions have no
// own [[HomeObject]]; `super.x` inside one is the enclosing method's, through
// GetThisEnvironment / §13.3.7.1 MakeSuperPropertyReference). google.com's
// history store wraps every storage call as `get(a){pMa(this,()=>c=super.get(a))}`;
// each one threw "undefined is not a function" and was swallowed by google.ml.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let superInArrowCases: [(String, String)] = [
        ("class method: super.m() inside an arrow",
         "(function(){ class A { get(k) { return 'A' + k; } } class B extends A { get(k) { var c = null; var f = () => c = super.get(k); f(); return c; } } return new B().get(1) === 'A1'; })()"),
        ("the google.com shape: default parameter + arrow passed to a helper",
         "(function(){ function run(o, f) { try { f(); } catch (e) { o.err = e; } } class A { get(a, b) { return a + ':' + b; } } class B extends A { get(a, b = !1) { var c = null; run(this, () => c = super.get(a, b)); return c; } } var x = new B(); return x.get('k') === 'k:false' && x.err === undefined; })()"),
        ("nested arrows",
         "(function(){ class A { m() { return 7; } } class B extends A { m() { return (() => () => super.m())()(); } } return new B().m() === 7; })()"),
        ("static method: super is the parent constructor",
         "(function(){ class A { static s() { return 'S'; } } class B extends A { static s() { return (() => super.s())(); } } return B.s() === 'S'; })()"),
        ("object literal method",
         "(function(){ var o = { __proto__: { m() { return 'p'; } }, m() { return (() => super.m())(); } }; return o.m() === 'p'; })()"),
        ("super property assignment in an arrow sets on this",
         "(function(){ class A {} class B extends A { set(v) { (() => { super.x = v; })(); return this.x; } } return new B().set(5) === 5; })()"),
        ("an arrow in a constructor after super()",
         "(function(){ class A { hi() { return 'hi'; } } class B extends A { constructor() { super(); this.r = (() => super.hi())(); } } return new B().r === 'hi'; })()"),
    ]

    mutating func testSuperInArrow() {
        runTrueCases("SuperInArrow", JeffJSTestRunner.superInArrowCases)
    }
}
