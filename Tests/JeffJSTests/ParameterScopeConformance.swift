// ParameterScopeConformance.swift
// JeffJS — "ParameterScope": FunctionDeclarationInstantiation (ES §10.2.11)
// for functions whose formals contain expressions (defaults, patterns with
// defaults or computed keys).
//
//   - Steps 19-28: the parameters live in their own environment. A body
//     `var` of a parameter's name is a separate binding that starts with the
//     parameter's value; closures created in the parameter list keep seeing
//     the parameter (`function f(a, b = () => a) { var a = 9; return b() }`
//     returned 9, not 3), and parameter expressions never see body vars
//     (`function f(a = x) { var x = 1 }` read the undefined body `x`, not an
//     outer one).
//   - Step 26: parameters are initialised left to right, each in its TDZ
//     until then (`function f(a = b, b) {}` must throw ReferenceError).
//   - Steps 15-18: a parameter named `arguments` suppresses the arguments
//     object (`function f(arguments) { return arguments }` returned the
//     object); a body function/lexical `arguments` suppresses it only
//     without parameter expressions, a plain `var arguments` never does.
//   - Mapped (sloppy, simple list) versus unmapped arguments objects, and
//     arrows inheriting `arguments`.
//   - A base-class constructor initialises its fields before its parameter
//     initializers (§10.2.2 step 6.b): `constructor(a = this.f)`.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let parameterScopeCases: [(String, String)] = [
        ("a closure in the parameter list sees the parameter, not the body var",
         "(function(a, b = () => a){ var a = 9; return b() === 3 && a === 9; })(3)"),
        ("a body var starts with the parameter's value",
         "(function(a, b = () => a){ var a; return a; })(3) === 3"),
        ("a write through a parameter closure does not reach the body var",
         "(function(a, set = (v) => { a = v; }, get = () => a){ var a = 1; set(5); return a === 1 && get() === 5; })(3)"),
        ("without a body var the body and the closures share the parameter",
         "(function(a, b = () => a){ a = 9; return b(); })(3) === 9"),
        ("parameter expressions do not see body vars",
         "(function(){ var x = 'outer'; function f(a = x){ var x = 1; return a; } return f(); })() === 'outer'"),
        ("patterns, rest and arrows get the same parameter scope",
         "(function({a}, b = () => a){ var a = 9; return b(); })({a: 3}) === 3 && (function(b = () => r, ...r){ var r = 9; return b().length; })(undefined, 1, 2) === 2 && ((a, b = () => a) => { var a = 9; return b(); })(3) === 3"),
        ("methods, generators and derived constructors too",
         "({ m(a, b = () => a){ var a = 9; return b(); } }).m(3) === 3 && (function*(a, b = () => a){ var a = 9; yield b(); })(3).next().value === 3 && (function(){ class A { constructor(v){ this.v = v; } } class B extends A { constructor(a = 1, g = () => a){ super(a); var a = 5; this.x = g(); } } var o = new B(); return o.v === 1 && o.x === 1; })()"),
        ("a body function named like a parameter wins in the body only",
         "(function(a, b = () => a){ function a(){} return typeof a === 'function' && b() === 3; })(3)"),
        ("a later parameter is in its TDZ",
         "(function(){ function f(a = b, b){} try { f(); return false; } catch (e) { return e instanceof ReferenceError; } })()"),
        ("a parameter read by its own initializer is in its TDZ",
         "(function(){ function f(a = a){} try { f(); return false; } catch (e) { return e instanceof ReferenceError; } })()"),
        ("typeof and an immediately called closure see the TDZ, a later call does not",
         "(function(){ function f(a = typeof b, b){} function g(a = (() => b)(), b){} function h(a = () => b, b = 2){ return a(); } var n = 0; try { f(); } catch (e) { n += e instanceof ReferenceError; } try { g(); } catch (e) { n += e instanceof ReferenceError; } return n === 2 && h() === 2; })()"),
        ("a parameter shadows an outer binding in the whole list",
         "(function(){ let q = 1; function f(a = q, q = 2){ return a; } try { f(); return false; } catch (e) { return e instanceof ReferenceError; } })()"),
        ("earlier parameters and a named function expression are visible",
         "(function(a, b = a + 1){ return b; })(1) === 2 && (function h(a = typeof h){ return a; })() === 'function'"),
        ("a parameter named arguments suppresses the arguments object",
         "(function(arguments){ return arguments; })(7) === 7 && (function(arguments = 4){ return arguments; })() === 4 && (function(...arguments){ return arguments.length; })(1, 2, 3) === 3 && (function({arguments}){ return arguments; })({arguments: 5}) === 5"),
        ("a var arguments is the arguments object",
         "(function(){ var arguments; return arguments.length; })(1, 2) === 2 && (function(a = 0){ var arguments; return arguments.length; })(1, 2, 3) === 3"),
        ("body function and lexical arguments",
         "(function(){ function arguments(){} return typeof arguments; })(1) === 'function' && (function(){ let arguments = 5; return arguments; })(1) === 5 && (function(a = () => arguments){ let arguments = 5; return arguments === 5 && a().length === 2; })(undefined, 2) && (function(a = arguments){ function arguments(){} return a.length === 2 && typeof arguments === 'function'; })(undefined, 2)"),
        ("arrows inherit arguments",
         "(function(){ return (() => arguments[0])(9) === 1 && ((a = arguments[0]) => a)() === 1 && (() => arguments.length)() === 2; })(1, 2)"),
        ("mapped arguments alias simple sloppy parameters",
         "(function(a){ arguments[0] = 9; var r1 = a; a = 7; return r1 === 9 && arguments[0] === 7; })(1) && (function(a){ a = 9; return arguments[0]; })() === undefined"),
        ("strict or non-simple parameters get unmapped arguments",
         "(function(a){ 'use strict'; arguments[0] = 9; return a; })(1) === 1 && (function(a, b = 1){ a = 9; return arguments[0]; })(1) === 1 && (function(a, ...r){ arguments[0] = 9; return a; })(1) === 1 && (function(a, {b}){ a = 9; return arguments[0]; })(1, {}) === 1"),
        ("a default names an anonymous function after the parameter",
         "(function(a = function(){}, b = () => {}){ return a.name + b.name; })() === 'ab'"),
        ("base-class fields are initialised before parameter initializers",
         "(function(){ class C { f = 7; constructor(a = this.f){ this.a = a; } } return new C().a === 7; })()"),
    ]

    mutating func testParameterScope() {
        runTrueCases("ParameterScope", JeffJSTestRunner.parameterScopeCases)
    }
}
