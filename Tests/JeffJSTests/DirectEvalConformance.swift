// DirectEvalConformance.swift
// JeffJS — "DirectEval": PerformEval with direct = true (ES §19.2.1.1).
//
// `eval(src)` whose callee is the identifier `eval` resolving to %eval% runs
// `src` in the caller's scope: it sees the caller's locals, parameters,
// `let`/`const` (TDZ included), `this`, `arguments`, `new.target` and home
// object. In sloppy code its `var` and function declarations land in the
// caller's variable environment (a var object the function carries when it
// contains a direct eval; the global object at the top level); in strict
// code (caller or eval text) they stay inside the eval. Its `let`/`const`
// are always local to it. Any other callee form — `(0, eval)`, an alias,
// a shadowing local — is an ordinary call (indirect eval: global scope).
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let directEvalCases: [(String, String)] = [
        ("direct eval sees the caller's locals and parameters",
         #"(function(a){ var c = 9; return eval("c + a"); })(1) === 10"#),
        ("assignments reach the caller's bindings",
         #"(function(){ var a = 1; let b = 2; eval("a = 5; b = 6"); return a === 5 && b === 6; })()"#),
        ("a sloppy var is added to the caller's var environment",
         #"(function(){ eval("var z = 1"); z += 2; return z === 3 && typeof z === 'number'; })()"#),
        ("an eval var is visible to closures, even ones created before the eval",
         #"(function(){ var get = () => late; eval("var late = 4"); return get() === 4 && (function(){ return late; })() === 4; })()"#),
        ("an eval var shadows an outer binding without touching it",
         #"(function(){ var x = 'outer'; var r = (function(){ eval("var x = 'inner'"); return x; })(); return r === 'inner' && x === 'outer'; })()"#),
        ("a var the caller already has is reused",
         #"(function(p){ var v = 1; eval("var v = 2; var p = 3"); return v === 2 && p === 3; })(0)"#),
        ("function declarations are hoisted into the caller",
         #"(function(){ eval("function fd1(){ return 11; }"); var fd2 = 1; eval("function fd2(){ return 12; }"); return fd1() === 11 && fd2() === 12; })()"#),
        ("eval vars are deletable, repeated declarations keep the value",
         #"(function(){ eval("var dv = 1"); eval("var dv"); var kept = dv === 1; var r = delete dv; return kept && r === true && typeof dv === 'undefined'; })()"#),
        ("let, const and class stay local to the eval",
         #"(function(){ var a = 1; var r = eval("let a = 2; const q = 3; class K {} a + q"); return r === 5 && a === 1 && typeof q === 'undefined' && typeof K === 'undefined'; })()"#),
        ("strict caller or strict eval code keeps vars inside the eval",
         #"(function(){ 'use strict'; eval("var s1 = 1; function sf(){}"); return typeof s1 === 'undefined' && typeof sf === 'undefined'; })() && (function(){ eval("'use strict'; var s2 = 1"); return typeof s2 === 'undefined'; })()"#),
        ("the caller's let is in its TDZ before its declaration",
         #"(function(){ try { eval("tz"); } catch (e) { return e instanceof ReferenceError; } let tz = 1; return false; })()"#),
        ("assigning the caller's const throws TypeError",
         #"(function(){ const k = 1; try { eval("k = 2"); } catch (e) { return e instanceof TypeError && k === 1; } return false; })()"#),
        ("a var over a lexical binding is a SyntaxError, a catch parameter is fine",
         #"(function(){ let lc = 1; try { eval("var lc = 2"); return false; } catch (e) { if (!(e instanceof SyntaxError)) return false; } { let bc = 1; try { eval("function bc(){}"); return false; } catch (e) { if (!(e instanceof SyntaxError)) return false; } } try { throw 1; } catch (cp) { eval("var cp = 5"); return cp === 5 && lc === 1; } })()"#),
        ("this, arguments and new.target are the caller's",
         #"({ v: 3, m(){ return eval("this.v"); } }).m() === 3 && (function(a, b){ return eval("arguments.length + a + b"); })(1, 2) === 5 && new (function(){ this.t = eval("new.target"); })().t !== undefined"#),
        ("inside an arrow: the enclosing function's this and arguments",
         #"({ v: 7, m(){ return (() => eval("this.v"))(); } }).m() === 7 && (function(){ return (() => eval("arguments[0]"))(); })(42) === 42"#),
        ("super property access in a method",
         #"(function(){ class A { f(){ return 1; } } class B extends A { f(){ return eval("super.f()") + 1; } } return new B().f() === 2; })()"#),
        ("private names of the enclosing class",
         #"(function(){ class C { #p = 41; m(){ return eval("this.#p + 1"); } } return new C().m() === 42; })()"#),
        ("eval in parameter defaults sees earlier parameters",
         #"(function(a, b = eval("a * 3")){ return b; })(2) === 6 && ((a, b = eval("a + 1")) => b)(4) === 5"#),
        ("a var from a parameter default lives outside the parameters",
         #"(function(a = eval("var pd = 2; pd"), b = pd){ return a === 2 && b === 2; })() && (function(a = eval("var pq = 1"), b = () => pq){ var pq = 5; return b() === 1 && pq === 5; })()"#),
        ("nested direct eval shares the scope",
         #"(function(){ var x = 1; eval("eval('var n = x + 1')"); return n === 2 && eval("eval('x')") === 1; })()"#),
        ("closures made by eval keep the caller's bindings after it returns",
         #"(function(){ var f = (function(){ var q = 10; return eval("() => q++"); })(); f(); return f() === 11; })()"#),
        ("eval sees per-iteration let bindings",
         #"(function(){ var fs = []; for (let i = 0; i < 3; i++) fs.push(eval("() => i")); var s = 0; for (let j = 0; j < 3; j++) eval("s += j"); return fs.map(f => f()).join() === '0,1,2' && s === 3; })()"#),
        ("grandparent bindings and generators",
         #"(function(){ var gp = 1; return (function(){ return (function(){ return eval("gp + 1"); })(); })(); })() === 2 && (function(){ function* g(){ var x = 1; yield eval("x"); x = 2; yield eval("x"); } return [...g()].join() === '1,2'; })()"#),
        ("with: the eval code resolves through the with object",
         #"(function(){ var o = { wx: 5, wv: 5 }; with (o) { var r = eval("wx"); eval("var wv = 6"); } return r === 5 && o.wv === 6 && typeof wv === 'undefined'; })()"#),
        ("indirect forms run in the global scope",
         #"(function(){ var c = 9; var e2 = eval; var n = 0; try { (0, eval)("c"); } catch (e) { n += e instanceof ReferenceError; } try { e2("c"); } catch (e) { n += e instanceof ReferenceError; } return n === 2 && (eval)("c") === 9; })()"#),
        ("a local named eval is an ordinary call",
         #"(function(eval){ var c = 1; return eval("c"); })(s => s + '!') === 'c!'"#),
        ("spread arguments, non-string and missing arguments",
         #"(function(){ var c = 3; return eval(...["c"]) === 3 && eval(42) === 42 && eval() === undefined; })()"#),
        ("typeof of an undeclared name inside and around eval",
         #"eval("typeof undeclaredDE") === 'undefined' && (function(){ try { typeof eval("undeclaredDE"); } catch (e) { return e instanceof ReferenceError; } return false; })()"#),
        ("return at the top of eval code is a SyntaxError",
         #"(function(){ try { eval("return 1"); } catch (e) { return e instanceof SyntaxError; } return false; })()"#),
        ("completion value and exceptions",
         #"(function(){ var r = eval("1; if (true) { 2 }"); try { eval("throw new TypeError('boom')"); } catch (e) { return r === 2 && e.message === 'boom'; } })()"#),
        ("top-level direct eval defines globals and sees top-level lets",
         #"(function(){ return (0, eval)("let tl = 5; var r = eval('tl + 1'); eval('var gde = 1'); r === 6 && globalThis.gde === 1"); })()"#),
        ("recursion through eval",
         #"(function(){ function f(n){ return n ? eval("f(n - 1) + 1") : 0; } return f(20) === 20; })()"#),
    ]

    mutating func testDirectEval() {
        runTrueCases("DirectEval", JeffJSTestRunner.directEvalCases)
    }
}
