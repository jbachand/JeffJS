// NamedEvaluationConformance.swift
// JeffJS — conformance group "NamedEvaluation" (ES §8.4.3
// IsAnonymousFunctionDefinition, §8.4.5 NamedEvaluation, §10.2.9 SetFunctionName).
// One rule: an anonymous function, arrow, async/generator function or class
// definition in an IsAnonymousFunctionDefinition position gets the binding or
// property name. The parser named only `var x = function(){}`, `x = function(){}`,
// `{ m: function(){} }` and default parameters: every class was left "", and
// logical assignment, computed keys, destructuring defaults and class fields were
// never named; `(0, function(){})` wrongly was. A named class set its name after
// its static elements, so `class A { static name(){} }` lost the method.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let namedEvaluationCases: [(String, String)] = [
        ("var / let / const initializers name classes",
         #"(function(){ var x = class {}; let y = class {}; const z = class { static m(){} }; return x.name === 'x' && y.name === 'y' && z.name === 'z'; })()"#),
        ("assignment to an identifier names a class",
         #"(function(){ var x; x = class {}; return x.name === 'x'; })()"#),
        ("a static name member wins over the class name (named and anonymous)",
         #"(function(){ class A { static name(){ return 1; } } var B = class { static name(){ return 2; } }; var C = class { static name = 'field'; }; return typeof A.name === 'function' && typeof B.name === 'function' && C.name === 'field'; })()"#),
        ("the name is set before static initializers run",
         #"(function(){ var x = class { static n = this.name; }; class Y { static n = this.name; } return x.n === 'x' && Y.n === 'Y'; })()"#),
        ("anonymous class and function definitions own a name property \"\"",
         #"(function(){ var c = [class {}][0], f = [function(){}][0]; return Object.prototype.hasOwnProperty.call(c, 'name') && c.name === '' && Object.prototype.hasOwnProperty.call(f, 'name') && f.name === ''; })()"#),
        ("a comma expression is not an anonymous function definition",
         #"(function(){ var x = (0, function(){}); var y = (0, class {}); var z; z = (1, () => 1); return x.name === '' && y.name === '' && z.name === ''; })()"#),
        ("parentheses are transparent",
         #"(function(){ var x = (function(){}); var y = ((class {})); return x.name === 'x' && y.name === 'y'; })()"#),
        ("logical assignment names the function",
         #"(function(){ var a, b = 0, c = 1; a ??= function(){}; b ||= class {}; c &&= () => 1; return a.name === 'a' && b.name === 'b' && c.name === 'c'; })()"#),
        ("member targets are never named",
         #"(function(){ var o = {}; o.p = function(){}; o['q'] = class {}; o.r ??= () => 1; return o.p.name === '' && o.q.name === '' && o.r.name === ''; })()"#),
        ("object literal: data, class, computed string / symbol / number keys",
         #"(function(){ var s = Symbol('s'), e = Symbol(); var o = { a: function(){}, b: class {}, ['c' + 1]: () => 0, [s]: function(){}, [e]: () => 1, 5: function(){}, [6]: class {} }; return o.a.name === 'a' && o.b.name === 'b' && o.c1.name === 'c1' && o[s].name === '[s]' && o[e].name === '' && o[5].name === '5' && o[6].name === '6'; })()"#),
        ("the computed key is evaluated once, before the value",
         #"(function(){ var log = []; var k = { toString: function(){ log.push('k'); return 'kk'; } }; var o = { [k]: (log.push('v'), function(){}) }; var p = { [k]: function(){} }; return log.join() === 'k,v,k' && o.kk.name === '' && p.kk.name === 'kk'; })()"#),
        ("destructuring defaults (binding and assignment patterns)",
         #"(function(){ var { q = class {} } = {}; var [r = () => {}] = []; let { s = function(){} } = {}; var { t: u = function(){} } = {}; var v, w; ({ v = function(){} } = {}); [w = class {}] = []; return q.name === 'q' && r.name === 'r' && s.name === 's' && u.name === 'u' && v.name === 'v' && w.name === 'w'; })()"#),
        ("a destructuring default is named only when it is used",
         #"(function(){ var f0 = function(){}; var { f = function(){} } = { f: f0 }; return f === f0 && f.name === 'f0'; })()"#),
        ("parameters: plain and destructured defaults",
         #"(function(){ function f(p = function(){}, { q = class {} } = {}, [r = () => 1] = []) { return p.name + q.name + r.name; } return f() === 'pqr'; })()"#),
        ("class fields: public, static, private, computed (symbol too), numeric",
         #"(function(){ var k = 'ck', sy = Symbol('ss'); class K { static m = function(){}; n = class {}; #p = function(){}; [k] = () => 1; static [sy] = function(){}; 7 = function(){}; getP(){ return this.#p.name; } } var o = new K(); return K.m.name === 'm' && o.n.name === 'n' && o.getP() === '#p' && o.ck.name === 'ck' && K[sy].name === '[ss]' && o[7].name === '7'; })()"#),
        ("a symbol-keyed computed field is keyed by the symbol",
         #"(function(){ var s = Symbol('ss'); class K { static [s] = 1; [s] = 2; } return Object.getOwnPropertySymbols(K).length === 1 && K[s] === 1 && new K()[s] === 2 && !('ss' in K); })()"#),
        ("async, generator and arrow definitions",
         #"(function(){ var a = async function(){}, g = function*(){}, ag = async () => 1, gen = { *m(){} }; return a.name === 'a' && g.name === 'g' && ag.name === 'ag' && gen.m.name === 'm'; })()"#),
        ("an own name is never overwritten",
         #"(function(){ var x = function foo(){}; var y = class Bar {}; var o = { p: function q(){} }; return x.name === 'foo' && y.name === 'Bar' && o.p.name === 'q'; })()"#),
        ("a conditional or logical expression is not a definition",
         #"(function(){ var x = true ? function(){} : 0; var y = function(){} || 0; return x.name === '' && y.name === ''; })()"#),
        ("function length/name/prototype property order",
         #"(function(){ return Object.getOwnPropertyNames(function(){}).join() === 'length,name,prototype'; })()"#),
    ]

    mutating func testNamedEvaluation() {
        runTrueCases("NamedEvaluation", JeffJSTestRunner.namedEvaluationCases)
    }
}
