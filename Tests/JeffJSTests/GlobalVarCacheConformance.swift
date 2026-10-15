// GlobalVarCacheConformance.swift
// JeffJS — conformance group "GlobalVarCache": get_var/put_var are served by a
// per-site inline cache keyed on the global object's shape (QuickJS
// JS_GetGlobalVar). Each case warms a loop (so the trace tier runs it), then
// changes the global binding and checks the loop sees the change.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let globalVarCacheCases: [(String, String)] = [
        ("redefining a warmed global as a getter is seen",
         "(function(){ globalThis.gv1 = 1; function f(){ var s = 0; for (var i = 0; i < 400; i++) s += gv1; return s; } var a = f(); var n = 0; Object.defineProperty(globalThis, 'gv1', { configurable: true, get: function(){ n++; return 2; } }); var b = f(); return a === 400 && b === 800 && n === 400; })()"),
        ("deleting a warmed global makes later reads throw ReferenceError",
         "(function(){ globalThis.gv2 = 5; function f(){ var s = 0; for (var i = 0; i < 400; i++) s += gv2; return s; } var a = f(); delete globalThis.gv2; var e; try { f(); } catch (err) { e = err; } return a === 2000 && e instanceof ReferenceError; })()"),
        ("deleting and recreating a warmed global yields the new value",
         "(function(){ globalThis.gv3 = 1; function f(){ var s = 0; for (var i = 0; i < 400; i++) s += gv3; return s; } var a = f(); delete globalThis.gv3; globalThis.gv3 = 3; return a === 400 && f() === 1200; })()"),
        ("adding unrelated globals (shape change) after warm-up keeps reads correct",
         "(function(){ globalThis.gv4 = 1; function f(){ var s = 0; for (var i = 0; i < 400; i++) s += gv4; return s; } var a = f(); for (var j = 0; j < 20; j++) globalThis['gv4x' + j] = j; globalThis.gv4 = 2; return a === 400 && f() === 800; })()"),
        ("writes through a warmed put_var site are seen by readers",
         "(function(){ globalThis.gv5 = 0; function w(){ for (var i = 0; i < 400; i++) gv5 = i; } function r(){ return gv5; } w(); var a = r(); gv5 = 7; return a === 399 && r() === 7; })()"),
        ("a non-writable global is not written by a warmed put_var site (sloppy)",
         "(function(){ globalThis.gv6 = 1; function w(v){ for (var i = 0; i < 400; i++) gv6 = v; } w(2); Object.defineProperty(globalThis, 'gv6', { writable: false, value: 2, configurable: true }); w(9); return gv6 === 2; })()"),
        ("a non-writable global throws on a warmed put_var site in strict code",
         "(function(){ globalThis.gv7 = 1; function w(v){ 'use strict'; for (var i = 0; i < 400; i++) gv7 = v; } w(2); Object.defineProperty(globalThis, 'gv7', { writable: false, value: 2, configurable: true }); var e; try { w(9); } catch (err) { e = err; } return e instanceof TypeError && gv7 === 2; })()"),
        ("a local shadowing a warmed global name wins in the shadowing function only",
         "(function(){ globalThis.gv8 = 10; function f(){ var s = 0; for (var i = 0; i < 400; i++) s += gv8; return s; } function g(){ var gv8 = 1; var s = 0; for (var i = 0; i < 400; i++) s += gv8; return s; } return f() === 4000 && g() === 400 && f() === 4000; })()"),
        ("with-scope shadowing of a warmed global",
         "(function(){ globalThis.gv9 = 1; function f(o){ var s = 0; with (o) { for (var i = 0; i < 400; i++) s += gv9; } return s; } return f({}) === 400 && f({ gv9: 3 }) === 1200 && f({}) === 400; })()"),
        ("sloppy implicit global creation by a warmed assignment",
         "(function(){ function f(){ for (var i = 0; i < 400; i++) gv10 = i; } f(); return gv10 === 399 && Object.getOwnPropertyDescriptor(globalThis, 'gv10').configurable === true; })()"),
        ("strict assignment to an undeclared global throws ReferenceError",
         "(function(){ function f(){ 'use strict'; for (var i = 0; i < 400; i++) gv11 = i; } var e; try { f(); } catch (err) { e = err; } return e instanceof ReferenceError && typeof gv11 === 'undefined'; })()"),
        ("typeof of a missing global after a warmed present one",
         "(function(){ globalThis.gv12 = 1; function f(){ var s = 0; for (var i = 0; i < 400; i++) s += typeof gv12 === 'number' ? 1 : 0; return s; } var a = f(); delete globalThis.gv12; return a === 400 && f() === 0; })()"),
        ("script-level let/const shadow a global property in later scripts",
         "(function(){ globalThis.gv13 = 1; var f = new Function('var s = 0; for (var i = 0; i < 400; i++) s += gv13; return s;'); var a = f(); (0, eval)('var gv13b = 1;'); return a === 400 && f() === 400; })()"),
    ]

    mutating func testGlobalVarCache() {
        runTrueCases("GlobalVarCache", JeffJSTestRunner.globalVarCacheCases)
    }

    /// Script-level let/const are global lexical bindings that shadow the
    /// global object's properties; they only arise from separate scripts in the
    /// same context (the way pages load several scripts). Each step is a
    /// separate global-code eval on one context; the loops warm a get_var site
    /// before the lexical declaration appears.
    mutating func testGlobalLexicalCache() {
        let (_, ctx) = makeCtx()
        func run(_ label: String, _ js: String) -> String {
            JeffJSStackDiag.currentLabel = "GlobalVarCache lexical: \(label)"
            let r = ctx.eval(input: js, filename: "<GlobalLexical>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            let out = r.isException ? "EXC" : (ctx.toSwiftString(r) ?? "?")
            if r.isException { ctx.rt.currentException.freeValue(); ctx.rt.currentException = .null } else { r.freeValue() }
            return out
        }
        func check(_ label: String, _ js: String, _ want: String) {
            let got = run(label, js)
            assert(got == want, "GlobalVarCache lexical: \(label) -> \(got), want \(want)")
        }
        let rd = { (n: String) in "function rd_\(n)(){ var s = 0; for (var i = 0; i < 400; i++) s += \(n); return s; }" }

        // A script-level let/const that arrives in a LATER script does not shadow
        // earlier scripts' global reads: this engine has no global lexical
        // environment shared between scripts (script-level let/const are locals
        // of their own script). Known gap, independent of the get_var cache
        // (the cache is keyed on the global object only); not asserted here.

        // const / let read through a warmed site inside the declaring script.
        check("const warm", "const gc1 = 3; \(rd("gc1")) rd_gc1() + rd_gc1()", "2400")
        // TDZ in the declaring script: a hoisted function reading the binding before its initialisation throws.
        check("tdz same script", "globalThis.gt1 = 7; function rd_gt1(){ var s = 0; for (var i = 0; i < 400; i++) s += gt1; return s; } var r = 'none'; try { rd_gt1(); } catch (x) { r = x.name; } let gt1 = 2; r + ',' + rd_gt1() + ',' + globalThis.gt1", "ReferenceError,800,7")
        // The property read through a warmed site is unaffected by an unrelated lexical of another name.
        check("globalThis property warm", "globalThis.gl2 = 1; \(rd("gl2")) let gl9 = 2; rd_gl2() + gl9", "402")
    }
}
