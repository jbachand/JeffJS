// AkamaiSensorConformance.swift
// JeffJS — conformance group "AkamaiSensor" (akamai sensor 2 fixer, 2026-09-30).
// homedepot.com's Akamai Bot Manager sensor (and its sec-cpt challenge script)
// probe the shape of the builtins, compare it with what the UA claims, and walk
// `Error().stack`. Every case below is a JavaScriptCore behaviour (checked with
// `jsc` and the WKWebView reference) that JeffJS did differently; the sensor's
// payload under JeffJS now matches WebKit's field for field on these checks.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let akamaiSensorCases: [(String, String)] = [
        // Number::toString(radix) — JSC's toStringWithRadix: exact integer digits,
        // shortest fraction that still identifies the double, round half to even.
        ("Number.prototype.toString(radix) prints JSC's digits",
         #"(123.456).toString(36) === '3f.gez4w97ry' && (0.1).toString(36) === '0.3lllllllllm' && Math.pow(2, 60).toString(36) === '8rc4kbdvss1s' && (1e21).toString(36) === '5v1j4f4ds79m9s' && (0.5).toString(3) === '0.11111111111111111111111111111111112' && (-255.5).toString(16) === '-ff.8' && (4503599627370495.5).toString(3) === '210212120220220211102011121012020.1' && (2251799813685248.5).toString(7) === '1245210111363416531.4' && Math.PI.toString(2).length === 51"#),
        ("JSON.stringify writes numbers with Number::toString",
         #"JSON.stringify([1e-7, 1e-6, 1.5e-10, 1e21, -0, 123e-20]) === '[1e-7,0.000001,1.5e-10,1e+21,0,1.23e-18]'"#),
        ("RegExp source is EscapeRegExpPattern'd once",
         #"String(/a\/b/) === '/a\\/b/' && new RegExp('a/b').source === 'a\\/b' && new RegExp('\n').source === '\\n' && String(new RegExp('[/]')) === '/[/]/' && new RegExp('').source === '(?:)' && String(new RegExp('\\/')) === '/\\//'"#),
        ("a builtin that is not a constructor has no [[Construct]]",
         #"[Math.max, JSON.stringify, Object.keys, Array.prototype.push, Function.prototype.toString, String.prototype.indexOf].every(function(f){ try { new f(); return false; } catch (e) { return e instanceof TypeError && e.message.indexOf('function is not a constructor') === 0; } }) && typeof new Map() === 'object' && new Date(0).getTime() === 0 && new Error('x').message === 'x'"#),
        ("a builtin's length / name are non-writable, non-enumerable, in the order length, name",
         #"[Math.max, JSON.parse, Object.keys, Array.prototype.map, Object.prototype.hasOwnProperty].every(function(f){ var n = Object.getOwnPropertyDescriptor(f, 'name'), l = Object.getOwnPropertyDescriptor(f, 'length'); return !n.writable && !n.enumerable && n.configurable && !l.writable && !l.enumerable && l.configurable && Object.getOwnPropertyNames(f).join() === 'length,name'; }) && Object.getOwnPropertyNames(function(){}.bind()).join() === 'length,name'"#),
        ("methods, accessors and arrows are not constructors and have no prototype",
         #"(function(){ var o = { m(){}, get g(){ return 1; } }, g = Object.getOwnPropertyDescriptor(o, 'g').get; class C { m(){} } function F(){} var bad = [o.m, g, () => 1, C.prototype.m].every(function(f){ try { new f(); return false; } catch (e) { return e instanceof TypeError && !('prototype' in f); } }); return bad && typeof new F() === 'object' && typeof new C() === 'object' && typeof new (class extends C {})() === 'object' && Object.getOwnPropertyNames(o.m).join() === 'length,name'; })()"#),
        ("Function.prototype.caller / arguments follow JSC",
         #"(function(){ function f(){ return f.caller; } function g(){ return f(); } function a(){ return a.arguments.length; } var t = 0; [Math.max, () => 1, { m(){} }.m, function(){ 'use strict'; }].forEach(function(x){ try { x.caller; } catch (e) { if (e.message === "'arguments', 'callee', and 'caller' cannot be accessed in this context.") t++; } }); return g() === g && a(1, 2, 3) === 3 && a.arguments === null && t === 4; })()"#),
        ("[[SetPrototypeOf]] refuses a cycle and Object.prototype (JSC text); Reflect answers false",
         #"(function(){ var o = {}, a, b; try { Object.setPrototypeOf(o, Object.create(o)); } catch (e) { a = e.message; } try { Object.setPrototypeOf(Object.prototype, {}); } catch (e) { b = e.message; } var c; try { o.__proto__ = Object.create(o); } catch (e) { c = e.message; } return a === 'cyclic __proto__ value' && b === 'Cannot set prototype of immutable prototype object' && c === 'cyclic __proto__ value' && Reflect.setPrototypeOf(o, Object.create(o)) === false && Reflect.setPrototypeOf(Object.preventExtensions({}), {}) === false && Reflect.setPrototypeOf(o, Array.prototype) === true && Object.getPrototypeOf(o) === Array.prototype; })()"#),
        ("Function.prototype.toString: 'Type error' for a non-function, ProxyObject for a callable proxy, 'get ' kept for builtin accessors",
         #"(function(){ var m; try { Function.prototype.toString.call(Object.create(Math.max)); } catch (e) { m = e.message; } var d = function(o, k){ return Object.getOwnPropertyDescriptor(o, k).get; }; return m === 'Type error' && Function.prototype.toString.call(new Proxy(Math.max, {})) === 'function ProxyObject() {\n    [native code]\n}' && String(d(Map.prototype, 'size')) === 'function get size() {\n    [native code]\n}' && String(d(Object.prototype, '__proto__')) === 'function get __proto__() {\n    [native code]\n}' && d(ArrayBuffer.prototype, 'byteLength').name === 'get byteLength'; })()"#),
        ("the global object's built-ins are not enumerable; unescape is the function",
         #"['Object', 'Math', 'JSON', 'parseInt', 'globalThis', 'unescape', 'escape', 'Date', 'ArrayBuffer'].every(function(k){ var d = Object.getOwnPropertyDescriptor(globalThis, k); return d && !d.enumerable; }) && typeof unescape === 'function' && unescape('%41') === 'A' && Object.prototype.toString.call(Math) === '[object Math]'"#),
        ("Intl objects are shaped like JSC's (no own properties, bound format getter, tags, native members)",
         #"typeof Intl === 'undefined' || (function(){ var d = new Intl.DateTimeFormat('en-US'), f = d.format, P = Intl.DateTimeFormat.prototype; return Object.getOwnPropertyNames(d).length === 0 && Object.prototype.toString.call(d) === '[object Intl.DateTimeFormat]' && typeof f === 'function' && f(new Date(0)).length > 0 && P.resolvedOptions.name === 'resolvedOptions' && Object.keys(P).length === 0 && String(P.resolvedOptions) === 'function resolvedOptions() {\n    [native code]\n}' && !('prototype' in P.resolvedOptions) && String(Date.prototype.toLocaleString) === 'function toLocaleString() {\n    [native code]\n}' && Object.getOwnPropertyNames(new Intl.Collator()).length === 0 && ['b', 'a'].sort(new Intl.Collator().compare).join() === 'a,b'; })()"#),
    ]

    /// Error.stack cases need a script URL (placeholder names print `name@`).
    static let akamaiSensorStackCases: [(String, String)] = [
        ("a call frame reports the call's divot column (just past the callee)",
         "function f(){ return new Error().stack.split('\\n')[1]; }\nvar o = { g: f, h: { k: f } };\nvar r1 = o.g(), r2 = o.h.k (1), r3 = (function(){ return new Error().stack.split('\\n')[0]; })();\nr1 === 'global code@https://t.test/s.js:3:13' && r2 === 'global code@https://t.test/s.js:3:27' && r3 === '@https://t.test/s.js:3:67'"),
        ("a strict tail call has no frame; a sloppy one keeps it (JSC proper tail calls)",
         "function f(){ return new Error().stack.split('\\n'); }\nfunction s(){ 'use strict'; return f(); }\nfunction u(){ return f(); }\nfunction t(){ 'use strict'; return f.call(null); }\nvar a = s(), b = u(), c = t();\na[1].indexOf('global code@') === 0 && b[1].indexOf('u@') === 0 && c[1].indexOf('global code@') === 0"),
        ("host (native) functions appear as name@[native code]; Error itself does not",
         "function nat(){ return [1].map(function m(){ return new Error().stack; })[0].split('\\n'); }\nvar s = nat();\nvar t; try { Function.prototype.toString.call({}); } catch (e) { t = e.stack.split('\\n'); }\ns[0].indexOf('m@') === 0 && s[1] === 'map@[native code]' && s[2].indexOf('nat@') === 0 && t[0] === 'toString@[native code]' && t[1].indexOf('global code@') === 0"),
    ]

    mutating func testAkamaiSensor() {
        runTrueCases("AkamaiSensor", JeffJSTestRunner.akamaiSensorCases)
        let (_, ctx) = makeCtx()
        for (name, js) in JeffJSTestRunner.akamaiSensorStackCases {
            JeffJSStackDiag.currentLabel = "AkamaiSensor: \(name)"
            let result = ctx.eval(input: js, filename: "https://t.test/s.js", evalFlags: JS_EVAL_TYPE_GLOBAL)
            if result.isException {
                let exc = ctx.getException()
                assert(false, "AkamaiSensor: \(name) threw \(ctx.toSwiftString(exc) ?? "?")")
                exc.freeValue()
            } else {
                assert(result.isBool && result.toBool(), "AkamaiSensor: \(name) -> \(ctx.toSwiftString(result) ?? "?")")
            }
            result.freeValue()
        }
        // markPlatformFunction: a host polyfill shaped like a WebKit native.
        let mark = ctx.eval(input: "(function(){ var op = { f: function(a, b){ return a + b; } }.f, C = function Iface(){}; globalThis.__akOp = op; globalThis.__akC = C; return [op, C]; })()",
                            filename: "<AkamaiSensor>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        let op = ctx.getPropertyStr(obj: ctx.globalObj, name: "__akOp")
        let iface = ctx.getPropertyStr(obj: ctx.globalObj, name: "__akC")
        ctx.markPlatformFunction(op, isConstructor: false)
        ctx.markPlatformFunction(iface, isConstructor: true)
        op.freeValue(); iface.freeValue(); mark.freeValue()
        let check = ctx.eval(input: "[String(__akOp) === 'function f() {\\n    [native code]\\n}', !('prototype' in __akOp), (function(){ try { new __akOp(); return false; } catch (e) { return e instanceof TypeError; } })(), __akOp(1, 2) === 3, String(__akC) === 'function Iface() {\\n    [native code]\\n}', typeof new __akC() === 'object', typeof __akC.prototype === 'object'].join()",
                             filename: "<AkamaiSensor>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        let got = ctx.toSwiftString(check) ?? "?"
        assert(got == "true,true,true,true,true,true,true", "AkamaiSensor: markPlatformFunction shapes a host function like a native -> \(got)")
        check.freeValue()
    }
}
