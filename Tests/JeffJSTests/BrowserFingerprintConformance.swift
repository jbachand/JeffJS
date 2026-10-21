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
        // google on JeffJS (2026-10-06): google's /search challenge VM reads the class string
        // of the builtin prototypes and Function.prototype's callability / key order.
        ("Function.prototype is a callable, non-constructible function (ES §20.2.3)",
         #"typeof Function.prototype === 'function' && Function.prototype() === undefined && Function.prototype(1, 2) === undefined && Object.prototype.toString.call(Function.prototype) === '[object Function]' && (function(){ try { new Function.prototype(); return false; } catch (e) { return e instanceof TypeError; } })() && Function.prototype.toString.call(Function.prototype) === 'function () {\n    [native code]\n}'"#),
        ("Error / NativeError / Date prototypes are ordinary objects (ES §20.5.3, §20.5.6.3, §21.4.4)",
         #"Object.prototype.toString.call(Error.prototype) === '[object Object]' && Object.prototype.toString.call(TypeError.prototype) === '[object Object]' && Object.prototype.toString.call(RangeError.prototype) === '[object Object]' && Object.prototype.toString.call(Date.prototype) === '[object Object]' && Object.prototype.toString.call(new TypeError('x')) === '[object Error]' && Object.prototype.toString.call(new Date(0)) === '[object Date]' && (function(){ try { Date.prototype.getTime(); return false; } catch (e) { return e instanceof TypeError; } })() && Error.prototype.toString() === 'Error' && new RangeError('m') instanceof Error"#),
        ("Function.prototype / Error.prototype own keys in JSC's order",
         #"Object.getOwnPropertyNames(Function.prototype).join() === 'length,name,toString,apply,call,bind,arguments,caller,constructor' && Object.getOwnPropertyNames(Error.prototype).join() === 'toString,name,message,constructor' && Object.keys(Function.prototype).length === 0"#),
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
        // JSC keeps "get " for ECMAScript builtin accessors (`function get size()`)
        // and drops it for DOM attributes (`function cookie()`); akamai sensor 2 fix.
        ("native accessors and bound functions print JSC's names",
         #"(function(){ var g = Object.getOwnPropertyDescriptor(Map.prototype, 'size').get; function f(){} return g.name === 'get size' && Function.prototype.toString.call(g) === 'function get size() {\n    [native code]\n}' && f.bind(null).name === 'bound f' && f.bind(null).toString() === 'function f() {\n    [native code]\n}'; })()"#),
        ("Date.prototype.toString ends with a time zone name and round-trips",
         #"(function(){ var d = new Date(1790000000000), s = d.toString(); return /GMT[+-]\d{4} \([^)]+\)$/.test(s) && /GMT[+-]\d{4} \([^)]+\)$/.test(d.toTimeString()) && Date.parse(s) === 1790000000000; })()"#),
        ("stack overflow is JSC's RangeError 'Maximum call stack size exceeded.' (no InternalError)",
         #"(function(){ function r(){ r(); } try { r(); return false; } catch (e) { return e instanceof RangeError && e.name === 'RangeError' && e.message === 'Maximum call stack size exceeded.'; } })()"#),
        // deep recursion (2026-10-21): the inline-call depth was a hard-coded 10 000 (Facebook Lite's comment
        // renderer recursed deeper: "Maximum call stack size exceeded"); it is stack.maxInlineDepth now, and
        // recursion below it — plain and method calls — completes.
        ("recursion just under stack.maxInlineDepth (default 10 000; plain and method calls) completes",
         #"(function(){ var n = 9900; function r(k){ return k === 0 ? 0 : 1 + r(k - 1); } var o = { m: function(k){ return k === 0 ? 0 : 1 + this.m(k - 1); } }; return r(n) === n && o.m(n) === n; })()"#),
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
