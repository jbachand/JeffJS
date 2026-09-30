// OfIdentifierConformance.swift
// JeffJS — conformance group "OfIdentifier" (ES §12.7.2, §14.7.5): `of` is not a reserved word.
// It is an ordinary IdentifierName that only a for-of head reads as the `of` keyword, so it is
// a valid BindingIdentifier in patterns, parameters, catch clauses, arrows and declarations.
// The tokenizer made it a keyword token and every binding site that wants an identifier token
// refused it: homedepot's PLP bundle (`const{array:G0t,bool:Lm,string:of,…}=l`) died with
// "Unexpected identifier 'of'" and the product grid never mounted (homedepot agent, 2026-09-30).
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let ofIdentifierCases: [(String, String)] = [
        ("object pattern target: const {string: of} = …",
         #"(function(){ const {string: of, number: n} = {string: 1, number: 2}; return of + n === 3; })()"#),
        ("nested object and array patterns, defaults",
         #"(function(){ var {x: {y: of = 5}} = {x: {}}; let [a, of2] = [1, 2]; const [of3] = [8]; return of === 5 && of3 === 8 && of2 === 2; })()"#),
        ("parameters, rest, arrow and catch bindings",
         #"(function(of){ var f = (of) => of * 2, g = (...of) => of.length; try { throw 3; } catch (of) { return of === 3 && f(of) === 6 && g(1, 2) === 2 && arguments[0] === 7; } })(7)"#),
        ("function and variable declarations named of",
         #"(function(){ function of(){ return 9; } var r = of(); { let of = 4; r += of; } return r === 13; })()"#),
        ("for-of still reads `of` as the keyword, also with of as the binding",
         #"(function(){ var s = 0; for (const x of [1, 2, 3]) s += x; var r = []; for (let of of [5]) r.push(of); for (var [a, b] of [[1, 2]]) s += a + b; return s === 9 && r[0] === 5; })()"#),
        ("of as a property name, shorthand and method",
         #"(function(){ var of = 1; var o = { of, x: { of: 2 }, of2(){ return 3; } }; class A { of(){ return 4; } static of = 5; } return o.of === 1 && o.x.of === 2 && new A().of() + A.of === 9 && Array.of(6)[0] === 6; })()"#),
    ]

    mutating func testOfIdentifier() {
        runTrueCases("OfIdentifier", JeffJSTestRunner.ofIdentifierCases)
    }
}
