// ProgramCompletionConformance.swift
// JeffJS — conformance group "ProgramCompletion" (ES §16.1.6 ScriptEvaluation /
// §19.2.1.1 PerformEval return the completion value; §14.6-14.15 each statement's
// UpdateEmpty rules).
//
// The completion value used to sit at the bottom of the operand stack, reached by
// rewriting every "tail" `drop` into `nip`. When the last statement of a script or
// eval was a for-of / for-in loop, a `nip` in its body replaced the iterator
// record's `next` method instead: `for (var c of list) console.log(eval(c))`
// failed on the second iteration with "undefined is not a function" (the Google
// results agent's "object-literal getter" case — the getter was a red herring),
// `for (x of a) { try { throw 0 } catch {} }` called the exception, and other
// shapes underflowed the stack ("VM stack underflow op=nip"). Now a hidden local
// holds it, as in QuickJS. Removing the stack slot exposed the interpreter's
// "chained store" lookahead (a store followed by any store kept its operand),
// which is gone: stores always consume their operand.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let programCompletionCases: [(String, String)] = [
        ("for-of as the last statement: a direct eval in the body (object-literal getter)",
         #"(function(){ var r = (0, eval)("var __pcOut = []; var __pcList = ['({get a(){return 1}}).a', '2']; for (var __pcC of __pcList) __pcOut.push(eval(__pcC));"); return r === 2 && __pcOut.join() === '1,2'; })()"#),
        ("for-of as the last statement: try/throw/catch without a binding",
         #"(function(){ var n = 0; globalThis.__pcN = 0; (0, eval)("for (var __pcS of [1, 2, 3]) { try { throw __pcS; } catch { __pcN++; } }"); return __pcN === 3; })()"#),
        ("for-of / for-in as the last statement, statement values in the body",
         #"(function(){ return (0, eval)("var __pcA = 0; for (var __pcV of [7, 8]) { __pcA += __pcV; }") === 15 && (0, eval)("for (var __pcK in { a: 1, b: 2 }) { __pcK; }") === 'b' && (0, eval)("for (var __pcW of []) { 1; }") === undefined; })()"#),
        ("catch with a pattern / finally / break inside a last for-of",
         #"(function(){ globalThis.__pcM = ''; (0, eval)("for (var __pcX of ['a', 'b']) { try { throw { message: __pcX }; } catch ({ message }) { __pcM += message; } finally { __pcM += '.'; } if (__pcX === 'b') break; }"); return __pcM === 'a.b.'; })()"#),
        ("an arrow closing over the catch parameter in a last for-of (was an endless loop)",
         #"(function(){ var r = (0, eval)("var __pcF = []; for (var __pcY of [1, 2]) { try { throw __pcY; } catch (e) { __pcF.push(() => e); } } __pcF.map(function(f){ return f(); }).join()"); return r === '1,2'; })()"#),
        ("a direct eval of a for-of inside a function",
         #"(function(){ var got = []; eval("for (var q of [1, 2]) { try { throw q; } catch { got.push(q); } }"); return got.join() === '1,2'; })()"#),
        ("completion values: expression, var, if, loops",
         #"(function(){ var ev = function(s){ return (0, eval)(s); }; return ev('1;') === 1 && ev('1; var __pcZ;') === 1 && ev('1; if (true) {}') === undefined && ev('1; if (true) { 2 }') === 2 && ev('1; if (false) { 2 }') === undefined && ev('1; while (false) {}') === undefined && ev('1; do { 2 } while (false)') === 2 && ev('1; for (;false;) {}') === undefined; })()"#),
        ("completion values: switch, try/catch/finally, blocks, labels, with",
         #"(function(){ var ev = function(s){ return (0, eval)(s); }; return ev('1; switch (1) { case 1: 5 }') === 5 && ev('1; switch (1) { case 2: 5 }') === undefined && ev('1; try { 2 } finally { 3 }') === 2 && ev('1; try { throw 0 } catch (e) { 3 }') === 3 && ev('1; try { throw 0 } catch (e) { }') === undefined && ev('1; try { 2; throw 0 } catch (e) { }') === undefined && ev('1; {}') === 1 && ev('1; { 2 }') === 2 && ev('1; foo: { 2; break foo; }') === 2 && ev('1; with ({}) { 4 }') === 4 && ev('1; function __pcG(){}') === 1 && ev("'use strict'") === 'use strict'; })()"#),
        ("completion values: break / continue carry UpdateEmpty(…, undefined) (V8, spec)",
         #"(function(){ var ev = function(s){ return (0, eval)(s); }; return ev('1; for (var __pcI of [1, 2]) { if (__pcI == 2) break; __pcI }') === undefined && ev('1; while (true) { 2; break }') === 2; })()"#),
        ("adjacent stores each consume their value (a hot loop keeps its stack)",
         #"(function(){ var r = (0, eval)("var __pcP, __pcQ = 0; for (var __pcJ = 0; __pcJ < 100000; __pcJ++) { __pcQ += __pcJ; __pcP = __pcQ; } __pcP"); var o = {}, a, b; for (var i = 0; i < 1000; i++) { a = b = i; o.x = o.y = i; } return r === 4999950000 && a === 999 && b === 999 && o.x === 999 && o.y === 999; })()"#),
        ("a destructuring assignment's value, and the store after it",
         #"(function(){ var a, b, v; for (var i = 0; i < 100; i++) { v = ({ a, b } = { a: i, b: 2 }); } return a === 99 && b === 2 && v.a === 99; })()"#),
    ]

    mutating func testProgramCompletion() {
        runTrueCases("ProgramCompletion", JeffJSTestRunner.programCompletionCases)
    }
}
