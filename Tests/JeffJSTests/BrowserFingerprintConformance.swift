// BrowserFingerprintConformance.swift
// JeffJS — conformance group "BrowserFingerprint" (akamai navigation fix,
// 2026-09-29). Bot-defence scripts (Akamai Bot Manager on homedepot/lowes) and
// the polyfills they ship (core-js) read the shape of the builtins; JeffJS stands
// in for JavaScriptCore under a Safari UA, so these answers are JSC's:
// - String / Number / Boolean are functions whose [[Prototype]] is
//   Function.prototype with `name` / `length` (ES §10.2.9-10, §22.1.1, §21.1.1,
//   §20.3.1): they had a null prototype, so `String + ""` threw "Cannot convert
//   object to primitive value" (core-js's inspectSource does `String(String)`).
// - Date / Symbol / Proxy have their names; Date.length is 7.
// - A native function prints as JSC prints it: an accessor's "get x" is "x", a
//   bound function's "bound f" is "f".
// - Date.prototype.toString ends with JSC's " (<time zone name>)" and still
//   round-trips through Date.parse.
// - performance.now() is whole milliseconds, like WebKit without cross-origin
//   isolation (checked in the app, which has `performance`).
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let browserFingerprintCases: [(String, String)] = [
        // device profile agent (2026-09-30): Akamai's homedepot challenge does
        // `this["dR"]^=this["qR"]` at a column where the expression span's end
        // offset had a low byte of 0x43 (get_field): the compound assignment
        // compiled as a field store with no dup2 → VM stack underflow → 403.
        // Every padding 0…299 puts that byte at every value.
        ("compound assignment to obj[\"k\"] at any source offset (expression-span bytes are not opcodes)",
         #"(function(){ for (var n = 0; n < 300; n++) { var o = {k: 3, j: 5}; var f = new Function('o', ' '.repeat(n) + 'o["k"] ^= o["j"]; o["k"] += 1; return o.k;'); if (f(o) !== 7) return false; var g = new Function(' '.repeat(n) + 'this["dR"] ^= this["qR"]; this.PO = 1; return this.dR;'), p = {dR: 3, qR: 5}; if (g.call(p) !== 6 || p.PO !== 1) return false; } return true; })()"#),
        ("String/Number/Boolean inherit from Function.prototype and have name/length",
         #"[String, Number, Boolean].every(function(C){ return Object.getPrototypeOf(C) === Function.prototype && C.length === 1 && typeof C.name === 'string' && C.name.length > 0 && typeof C.call === 'function'; }) && String.name === 'String' && Number.name === 'Number' && Boolean.name === 'Boolean'"#),
        ("String(String) and template interpolation of a constructor (core-js inspectSource)",
         #"String(String) === 'function String() {\n    [native code]\n}' && (Number + '') === 'function Number() {\n    [native code]\n}' && `${Boolean}`.indexOf('function Boolean()') === 0 && String(String).split('String').length === 2"#),
        ("Date, Symbol and Proxy have their names; Date.length is 7",
         #"Date.name === 'Date' && Date.length === 7 && Symbol.name === 'Symbol' && Symbol.length === 0 && Proxy.name === 'Proxy' && !Object.prototype.hasOwnProperty.call(Symbol, 'Symbol')"#),
        ("native accessors and bound functions print JSC's names",
         #"(function(){ var g = Object.getOwnPropertyDescriptor(Map.prototype, 'size').get; function f(){} return g.name === 'get size' && Function.prototype.toString.call(g) === 'function size() {\n    [native code]\n}' && f.bind(null).name === 'bound f' && f.bind(null).toString() === 'function f() {\n    [native code]\n}'; })()"#),
        ("Date.prototype.toString ends with a time zone name and round-trips",
         #"(function(){ var d = new Date(1790000000000), s = d.toString(); return /GMT[+-]\d{4} \([^)]+\)$/.test(s) && /GMT[+-]\d{4} \([^)]+\)$/.test(d.toTimeString()) && Date.parse(s) === 1790000000000; })()"#),
        ("stack overflow is JSC's RangeError 'Maximum call stack size exceeded.' (no InternalError)",
         #"(function(){ function r(){ r(); } try { r(); return false; } catch (e) { return e instanceof RangeError && e.name === 'RangeError' && e.message === 'Maximum call stack size exceeded.'; } })()"#),
        ("Function.prototype has length 0, name '', constructor, Symbol.hasInstance, arguments/caller",
         #"(function(){ var fp = Function.prototype, names = Object.getOwnPropertyNames(fp); var h = Object.getOwnPropertyDescriptor(fp, Symbol.hasInstance); return fp.length === 0 && fp.name === '' && fp.constructor === Function && (function(){}).constructor === Function && typeof h.value === 'function' && !h.writable && !h.configurable && !h.enumerable && names.indexOf('@@hasInstance') < 0 && ['apply','arguments','bind','call','caller','constructor','length','name','toString'].every(function(n){ return names.indexOf(n) >= 0; }) && fp[Symbol.hasInstance].call(Array, []) === true; })()"#),
        ("an error carries own line / column / stack (JSC); Error.captureStackTrace, stackTraceLimit",
         #"(function(){ var e = new Error('x'), names = Object.getOwnPropertyNames(e); var o = {}; Error.captureStackTrace(o); return typeof Error.captureStackTrace === 'function' && Error.stackTraceLimit === 100 && names.indexOf('stack') >= 0 && names.indexOf('message') >= 0 && (names.indexOf('line') < 0 || typeof e.line === 'number') && typeof o.stack === 'string'; })()"#),
        ("toLocaleTimeString writes an ASCII space before AM/PM (WebKit), not U+202F",
         #"(function(){ var s = new Date(0).toLocaleTimeString('en-US'); return s.indexOf(' ') < 0 && / [AP]M$/.test(s); })()"#),
    ]

    mutating func testBrowserFingerprint() {
        runTrueCases("BrowserFingerprint", JeffJSTestRunner.browserFingerprintCases)
    }
}
