// StringIteratorConformance.swift
// JeffJS — conformance group "StringIterator" (ES2024 §22.1.3.35
// String.prototype[@@iterator] and §22.1.5 %StringIteratorPrototype%: a string is
// iterated by code points — a surrogate pair is one element, a lone surrogate its
// own). The method was installed under the *string* key "[Symbol.iterator]", so
// `'ab'[Symbol.iterator]` was undefined: for-of and spread survived on an
// interpreter fallback for primitives, `Array.from(str)` split surrogate pairs,
// and page code that calls the method (google.com) threw.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let stringIteratorCases: [(String, String)] = [
        ("String.prototype[Symbol.iterator] is a function named [Symbol.iterator], length 0",
         #"(function(){ var f = String.prototype[Symbol.iterator]; return typeof f === 'function' && f.name === '[Symbol.iterator]' && f.length === 0; })()"#),
        ("the property is writable, configurable, not enumerable",
         #"(function(){ var d = Object.getOwnPropertyDescriptor(String.prototype, Symbol.iterator); return d.writable && d.configurable && !d.enumerable && !Object.prototype.hasOwnProperty.call(String.prototype, '[Symbol.iterator]'); })()"#),
        ("spread yields code points",
         #"(function(){ var s = 'a' + String.fromCharCode(0xD83D, 0xDE00) + 'b'; var r = [...s]; return r.length === 3 && r[1].length === 2; })()"#),
        ("for-of yields code points",
         #"(function(){ var n = []; for (const c of 'x' + String.fromCharCode(0xD83D, 0xDE00)) n.push(c.length); return n.join() === '1,2'; })()"#),
        ("Array.from(str) uses the iterator (no split surrogate pair)",
         #"(function(){ var r = Array.from('a' + String.fromCharCode(0xD83D, 0xDE00)); return r.length === 2 && r[1].codePointAt(0) === 0x1F600; })()"#),
        ("new Set(str) / array destructuring",
         #"(function(){ var [a, b] = String.fromCharCode(0xD83D, 0xDE00) + 'z'; return new Set('aab').size === 2 && a.length === 2 && b === 'z'; })()"#),
        ("lone surrogates are their own elements",
         #"(function(){ var s = String.fromCharCode(0xDE00, 0xD83D); var r = [...s]; return r.length === 2 && r[0] === String.fromCharCode(0xDE00) && r[1] === String.fromCharCode(0xD83D); })()"#),
        ("next() results and exhaustion",
         #"(function(){ var it = 'ab'[Symbol.iterator](); var a = it.next(), b = it.next(), c = it.next(), d = it.next(); return a.value === 'a' && !a.done && b.value === 'b' && c.done && c.value === undefined && d.done && Object.keys(a).join() === 'value,done'; })()"#),
        ("the iterator has no own properties; its prototype is %StringIteratorPrototype%",
         #"(function(){ var it = ''[Symbol.iterator](); var p = Object.getPrototypeOf(it); return Object.getOwnPropertyNames(it).length === 0 && Object.getOwnPropertyNames(p).join() === 'next' && Object.prototype.toString.call(it) === '[object String Iterator]' && p[Symbol.toStringTag] === 'String Iterator'; })()"#),
        ("%StringIteratorPrototype% inherits %IteratorPrototype%",
         #"(function(){ var ip = Object.getPrototypeOf(Object.getPrototypeOf([][Symbol.iterator]())); var it = 'ab'[Symbol.iterator](); return Object.getPrototypeOf(Object.getPrototypeOf(it)) === ip && it[Symbol.iterator]() === it && it.toArray().join() === 'a,b'; })()"#),
        ("RequireObjectCoercible / ToString on this",
         #"(function(){ var f = String.prototype[Symbol.iterator]; var threw = false; try { f.call(null); } catch (e) { threw = e instanceof TypeError; } return threw && [...f.call(12)].join() === '1,2' && [...f.call({ toString: function(){ return 'ok'; } })].join('') === 'ok'; })()"#),
        ("next() on a foreign receiver throws a TypeError",
         #"(function(){ var n = ''[Symbol.iterator]().next; try { n.call({}); return false; } catch (e) { return e instanceof TypeError; } })()"#),
        ("a String object and a patched method are honoured",
         #"(function(){ var o = String.prototype[Symbol.iterator]; String.prototype[Symbol.iterator] = function*(){ yield 'P'; }; try { return [...'ab'].join() === 'P' && [...new String('xy')].join() === 'P'; } finally { String.prototype[Symbol.iterator] = o; } })()"#),
        ("a string whose method was deleted is not iterable",
         #"(function(){ var o = String.prototype[Symbol.iterator]; delete String.prototype[Symbol.iterator]; try { [...'ab']; return false; } catch (e) { return e instanceof TypeError; } finally { String.prototype[Symbol.iterator] = o; } })()"#),
        ("a rope string iterates its whole value",
         #"(function(){ var s = ''; for (var i = 0; i < 50; i++) s += 'ab'; var n = 0; for (var c of s) n++; return n === 100; })()"#),
    ]

    mutating func testStringIterator() {
        runTrueCases("StringIterator", JeffJSTestRunner.stringIteratorCases)
    }
}
