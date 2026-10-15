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

    /// Script-level let/const/class are global lexical bindings (QuickJS
    /// `global_var_obj`): shared by every script of the context, checked before
    /// the global object, in their TDZ until initialised, const read-only,
    /// redeclaration a SyntaxError at script instantiation. Each step is a
    /// separate global-code eval on one context (the way pages load several
    /// scripts); loops warm a get_var inline-cache site before the lexical
    /// binding appears.
    mutating func testGlobalLexicalCache() {
        let (_, ctx) = makeCtx()
        /// Result of a script as text, or "EXC:<name>" when it threw.
        func run(_ label: String, _ js: String) -> String {
            JeffJSStackDiag.currentLabel = "GlobalVarCache lexical: \(label)"
            let r = ctx.eval(input: js, filename: "<GlobalLexical>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            if r.isException {
                let ex = ctx.getException()
                let n = ctx.getPropertyStr(obj: ex, name: "name")
                let name = ctx.toSwiftString(n) ?? "?"
                n.freeValue(); ex.freeValue()
                return "EXC:" + name
            }
            let out = ctx.toSwiftString(r) ?? "?"
            r.freeValue()
            return out
        }
        func check(_ label: String, _ js: String, _ want: String) {
            let got = run(label, js)
            assert(got == want, "GlobalVarCache lexical: \(label) -> \(got), want \(want)")
        }
        let rd = { (n: String) in "function rd_\(n)(){ var s = 0; for (var i = 0; i < 400; i++) s += \(n); return s; }" }

        // Visibility across scripts: let, const and class.
        check("define", "let a1 = 5; const c1 = 7; class K1 {}", "undefined")
        check("read across scripts", "typeof a1 + ' ' + a1 + ' ' + c1 + ' ' + typeof K1", "number 5 7 function")
        check("not on the global object", "String(globalThis.a1) + String('c1' in globalThis) + String('K1' in globalThis)", "undefinedfalsefalse")
        check("let assignment across scripts", "a1 = 6; String(a1) + ',' + globalThis.a1", "6,undefined")
        check("const assignment is a TypeError", "var e; try { c1 = 9; } catch (x) { e = x.name; } e + ',' + c1", "TypeError,7")
        check("class binding is writable", "var K1save = K1; K1 = 1; var r = K1; K1 = K1save; String(r) + ',' + typeof K1", "1,function")
        check("closures see later script bindings", "function readA1(){ return a1; } readA1() + c1", "13")
        check("delete of a lexical identifier is false", "String(delete a1) + ',' + a1", "false,6")

        // A lexical binding shadows a global-object property read through a warmed site.
        check("warm property", "globalThis.gl1 = 1; \(rd("gl1")) rd_gl1()", "400")
        check("let shadows the property", "let gl1 = 5; String(rd_gl1()) + ',' + globalThis.gl1 + ',' + gl1", "2000,1,5")
        check("write reaches the lexical", "gl1 = 6; String(rd_gl1()) + ',' + globalThis.gl1", "2400,1")
        // const read through a warmed site.
        check("const warm", "globalThis.gc2 = 2; \(rd("gc2")) rd_gc2()", "800")
        check("const shadows the property", "const gc2 = 3; String(rd_gc2()) + ',' + globalThis.gc2", "1200,2")
        check("const stays read-only through the cache", "var e; try { gc2 = 9; } catch (x) { e = x.name; } e + ',' + rd_gc2()", "TypeError,1200")
        // TDZ through the cache.
        check("tdz warm", "globalThis.gt1 = 7; \(rd("gt1")) rd_gt1()", "2800")
        check("tdz initializer read throws", "let gt1 = rd_gt1();", "EXC:ReferenceError")
        check("tdz persists for readers", "var e; try { rd_gt1(); } catch (x) { e = x.name; } e", "ReferenceError")
        check("tdz typeof throws", "var e; try { typeof gt1; } catch (x) { e = x.name; } e", "ReferenceError")
        check("tdz assignment throws", "var e; try { gt1 = 1; } catch (x) { e = x.name; } e", "ReferenceError")
        check("tdz binding is not on the global object", "String(globalThis.gt1)", "7")
        // globalThis.x versus a lexical x of the same name.
        check("globalThis vs lexical", "globalThis.gl2 = 1; \(rd("gl2")) let gl9 = 0; rd_gl2() + gl9", "400")
        check("lexical wins after both exist", "let gl2 = 2; String(gl2) + ',' + globalThis.gl2 + ',' + rd_gl2()", "2,1,800")
        // Redeclaration across scripts is a SyntaxError at instantiation, before any binding is made.
        check("var declared", "var rv1 = 1; function rf1() {}", "undefined")
        check("let over var", "let rn1 = 1; let rv1 = 2;", "EXC:SyntaxError")
        check("nothing was created", "typeof rn1", "undefined")
        check("let over function", "let rf1 = 2;", "EXC:SyntaxError")
        check("let over let", "let a1 = 2;", "EXC:SyntaxError")
        check("var over let", "var a1 = 2;", "EXC:SyntaxError")
        check("function over let", "function a1() {}", "EXC:SyntaxError")
        check("class over let", "class a1 {}", "EXC:SyntaxError")
        check("let over a non-configurable global", "let NaN = 1;", "EXC:SyntaxError")
        check("let over a configurable builtin", "let Array = 1; String(Array) + ',' + typeof globalThis.Array", "1,function")
        check("same-script duplicates", "let d1 = 1; let d1 = 2;", "EXC:SyntaxError")
        // Strict code assigning another script's bindings, through a warmed put_var site too.
        check("strict define", "let sl1 = 1; const sc3 = 2; function lf1() { return 'lf' + sl1; }", "undefined")
        check("strict assign hits the lexical", "'use strict'; for (var i = 0; i < 400; i++) sl1 = i; String(sl1) + ',' + globalThis.sl1", "399,undefined")
        check("strict const is a TypeError", "'use strict'; var e; try { for (var i = 0; i < 400; i++) sc3 = i; } catch (x) { e = x.name; } e + ',' + sc3", "TypeError,2")
        check("strict undeclared is a ReferenceError", "'use strict'; var e; try { undeclaredStrictName = 1; } catch (x) { e = x.name; } e + ',' + typeof undeclaredStrictName", "ReferenceError,undefined")
        check("strict tdz assignment", "'use strict'; var e; try { tdzS = 1; } catch (x) { e = x.name; } let tdzS = 0; e", "ReferenceError")
        // `with` over an object that lacks the name falls through to the lexical.
        check("with miss reads the lexical", "var r; with ({}) { r = sl1; } String(r)", "399")
        check("with miss assigns the lexical", "with ({}) { sl1 = 7; } String(sl1) + ',' + globalThis.sl1", "7,undefined")
        check("with hit assigns the object", "var o = { sl1: 1 }; with (o) { sl1 = 9; } String(o.sl1) + ',' + sl1", "9,7")
        check("with compound assignment", "with ({}) { sl1++; sl1 += 2; } String(sl1)", "10")
        check("with const is a TypeError", "var e; try { with ({}) { sc3 = 1; } } catch (x) { e = x.name; } e + ',' + sc3", "TypeError,2")
        check("with calls a lexical function", "var r; with ({}) { r = lf1(); } r", "lf10")
        check("with tdz", "var e1, e2; try { with ({}) { tdzW = 1; } } catch (x) { e1 = x.name; } try { with ({}) { tdzW; } } catch (x) { e2 = x.name; } let tdzW = 0; e1 + ',' + e2", "ReferenceError,ReferenceError")
        // Lexical-slot inline caches (get_var / put_var sites warmed on a script-level binding).
        check("lexical ic define", "let li1 = 1; const li2 = 5; function rdLi(){ var s = 0; for (var i = 0; i < 400; i++) s += li1 + li2; return s; } function wrLi(v){ for (var i = 0; i < 400; i++) li1 = v + i; } function wrLc(){ for (var i = 0; i < 400; i++) li2 = i; } rdLi()", "2400")
        check("lexical ic read sees other-script writes", "li1 = 2; String(rdLi())", "2800")
        check("lexical ic warmed put", "wrLi(10); String(li1) + ',' + rdLi()", "409,165600")
        check("lexical ic const put still throws", "var e; try { wrLc(); } catch (x) { e = x.name; } e + ',' + li2", "TypeError,5")
        check("lexical ic bindings added later keep slots valid", "let li3 = 1; let li4 = 2; String(rdLi()) + ',' + li3 + li4", "165600,12")
        // Eval code keeps its own lexical scope.
        check("indirect eval let is local", "(0, eval)('let ev1 = 1; ev1') + ',' + typeof ev1", "1,undefined")
        check("direct eval let is local", "eval('let ev2 = 2; ev2') + ',' + typeof ev2", "2,undefined")
        check("new Function let is local", "new Function('let nf1 = 3; return nf1')() + ',' + typeof nf1", "3,undefined")
        // Uninitialised-binding failure leaves later scripts working.
        check("typeof undeclared", "typeof neverDeclared", "undefined")
        check("block let is still local", "{ let bl1 = 1; } typeof bl1", "undefined")
        check("same-script closure over let", "let sc1 = 1; function incSc(){ return ++sc1; } incSc(); incSc(); String(sc1)", "3")
    }
}
