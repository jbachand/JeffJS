// ClassConstructorCallConformance.swift
// JeffJS — conformance group "ClassConstructorCall" (ES §10.2.1 [[Call]] step 2:
// calling a class constructor without `new` throws a TypeError before anything
// in it runs; §15.7.14 makes every class constructor a "classConstructor").
// JeffJS ran the body: `class A {}; A()` returned undefined and a derived
// constructor called as a function failed later with "super() already called".
// The text is JavaScriptCore's (the app presents a Safari UA): "Cannot call a
// class constructor A without |new|" with the class's own name from its head,
// and no name for an anonymous class (even one NamedEvaluation named).
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let classConstructorCallCases: [(String, String)] = [
        ("a base class called without new throws a TypeError (JSC text)",
         #"(function(){ class A {} try { A(); return false; } catch (e) { return e instanceof TypeError && e.message === 'Cannot call a class constructor A without |new|'; } })()"#),
        ("an explicit constructor, and a derived class",
         #"(function(){ class A { constructor(){ this.x = 1; } } class B extends Array {} class C extends Object { constructor(){ super(); } } var n = 0; [function(){ A(); }, function(){ B.call({}); }, function(){ C(); }].forEach(function(f){ try { f(); } catch (e) { if (e instanceof TypeError && /^Cannot call a class constructor [ABC] without \|new\|$/.test(e.message)) n++; } }); return n === 3; })()"#),
        ("an anonymous class has no name in the message",
         #"(function(){ var X = class {}; try { X(); return false; } catch (e) { return X.name === 'X' && e.message === 'Cannot call a class constructor without |new|'; } })()"#),
        ("nothing runs: parameter defaults and field initializers",
         #"(function(){ var hit = 0; class A { f = hit++; constructor(a = hit++){ hit++; } } try { A(); } catch (e) {} return hit === 0; })()"#),
        ("call, apply, Reflect.apply, bound and method calls throw too",
         #"(function(){ class A {} var o = { A: A }; var n = 0; [function(){ A.call(null); }, function(){ A.apply(null, []); }, function(){ Reflect.apply(A, null, []); }, function(){ A.bind(null)(); }, function(){ o.A(); }].forEach(function(f){ try { f(); } catch (e) { if (e instanceof TypeError) n++; } }); return n === 5; })()"#),
        ("a hot call site keeps throwing (inline call path)",
         #"(function(){ class A {} var n = 0; for (var i = 0; i < 500; i++) { try { A(); } catch (e) { n++; } } return n === 500; })()"#),
        ("new, super(), Reflect.construct and static methods are unaffected",
         #"(function(){ class A { constructor(x){ this.x = x; } static m(){ return 'm'; } } class B extends A { constructor(){ super(5); } } var C = class extends B {}; var s = 0; for (var i = 0; i < 300; i++) s += new B().x; return new A(1).x === 1 && new C().x === 5 && Reflect.construct(A, [2]).x === 2 && A.m() === 'm' && s === 1500; })()"#),
    ]

    mutating func testClassConstructorCall() {
        runTrueCases("ClassConstructorCall", JeffJSTestRunner.classConstructorCallCases)
    }
}
