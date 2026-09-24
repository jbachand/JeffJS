// StringConcatConformance.swift
// JeffJS — "StringConcat": a string value never changes after it is made.
//
// Long `s += x` results are kept in an append buffer (JeffJSStringBuffer) so
// building a string is O(n). The concat fast path used to append into the
// left operand's buffer whenever it was one, which changed that string for
// every other holder: `var b = a; b += 'z'` also grew `a`, and netflix's
// emotion serializer, which returns `{styles: l}` and later computes
// `n.styles + ";"`, grew the cached style text on every render, so its class
// hashes never matched the server's (1,397 insertRule calls instead of 15).
// Appends are now in place only when the interpreter can see the caller holds
// every reference (`l = l + x` into the same local); otherwise the storage is
// handed to a new buffer and the old value stays a frozen prefix view.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let stringConcatCases: [(String, String)] = [
        ("copy then append keeps the copy",
         "(function(){ var a = ''; for (var i = 0; i < 200; i++) a += 'ab' + i + ';'; var n = a.length, b = a; b += 'z'; return a.length === n && b.length === n + 1 && b.slice(0, n) === a; })()"),
        ("emotion shape: a cached styles string read and appended to per render",
         "(function(){ function g(){ var l = ''; for (var i = 0; i < 80; i++) l += 'k' + i + ':v;'; return { name: 'x', styles: l }; } var o = g(), n = o.styles.length; function f(x){ return x.styles + ';'; } var r = []; for (var k = 0; k < 5; k++) r.push(f(o) + '&{};;;;'); return o.styles.length === n && r[0] === r[4] && r[0].length === n + 8; })()"),
        ("c = l + m and d = l + m give equal strings and leave l",
         "(function(){ var l = ''; for (var i = 0; i < 200; i++) l += 'ab' + i; var n = l.length, m = 'tail'; var c = l + m, d = l + m, e = l + 'x'; return l.length === n && c === d && e.length === n + 1 && c.slice(0, n) === l; })()"),
        ("property, array element, closure and Map key keep their value",
         "(function(){ var l = ''; for (var i = 0; i < 200; i++) l += 'ab' + i; var n = l.length, o = { s: l }, a = [l], m = new Map([[l, 1]]), k = l, get = (function(v){ return function(){ return v; }; })(l); l += 'q'; l += 'r'; return o.s.length === n && a[0].length === n && get().length === n && m.get(k) === 1 && !m.has(l) && l.length === n + 2; })()"),
        ("an argument appended inside the callee leaves the caller's string",
         "(function(){ var l = ''; for (var i = 0; i < 200; i++) l += 'ab' + i; var n = l.length; function f(s){ s += '!'; return s; } var a = f(l), b = f(l); return l.length === n && a === b && a.length === n + 1; })()"),
        ("captured, property and global accumulators",
         "(function(){ var s = ''; function add(x){ s += x; } var o = { t: '' }, snap = []; for (var i = 0; i < 3000; i++) { add('ab'); o.t += 'cd'; if (i % 1000 === 999) snap.push(s, o.t); } return s.length === 6000 && o.t.length === 6000 && snap[0].length === 2000 && snap[1].length === 2000 && snap[2].length === 4000 && snap[4] === s; })()"),
        ("l = l + x + y, l += l, template literals and concat()",
         "(function(){ var l = '', x = 'a', y = 'b'; for (var i = 0; i < 2000; i++) l = l + x + y; var n = l.length, t = `${l}x`, c = l.concat('y'); var d = l; d += d; return n === 4000 && t.length === n + 1 && c.length === n + 1 && d.length === 2 * n && l.length === n; })()"),
        ("wide characters appended to an accumulator and to a shared copy",
         "(function(){ var l = ''; for (var i = 0; i < 300; i++) l += 'ab'; var n = l.length, a = l; l += '\\u00e9\\u4e2d'; var b = a + String.fromCharCode(0xd83d, 0xde00); return a.length === n && a.indexOf('\\u4e2d') < 0 && l.length === n + 2 && l.charCodeAt(n + 1) === 0x4e2d && b.length === n + 2 && b.charCodeAt(n) === 0xd83d; })()"),
        ("building a long string stays linear",
         "(function(){ var t0 = Date.now(), s = '', o = { s: '' }; for (var i = 0; i < 200000; i++) { s += 'abc'; o.s += 'x'; } return s.length === 600000 && o.s.length === 200000 && Date.now() - t0 < 5000; })()"),
    ]

    mutating func testStringConcat() {
        runTrueCases("StringConcat", JeffJSTestRunner.stringConcatCases)
    }
}
