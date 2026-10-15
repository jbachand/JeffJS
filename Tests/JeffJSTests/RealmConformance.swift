// RealmConformance.swift
// JeffJS — conformance group "Realms" (iframe realms, 2026-09-30).
// ES §9.3 realms / HTML §7.1: every global object (an `<iframe>`'s window, a
// worker's global) has its own intrinsics. `JeffJSRuntime.newRealm()` makes
// one next to the main context; values pass between them by reference, and a
// call runs in the callee's realm (ES §10.2.1.1 PrepareForOrdinaryCall, §10.3.1
// for built-ins). Each case runs in a main context where `w` is a second
// realm's global object; every case is a JS expression that must be `true`
// (the answers are WebKit's for `w = iframe.contentWindow`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let realmCases: [(String, String)] = [
        ("a realm has its own global and intrinsics",
         "w !== globalThis && w.Array !== Array && w.Object !== Object && w.Function !== Function && w.Array.prototype !== Array.prototype && typeof w.Array === 'function' && w.globalThis === w"),
        ("the Function constructor compiles in its own realm",
         "w.Function('return this')() === w && new w.Function('a', 'return a + 1')(1) === 2 && Object.getPrototypeOf(w.Function('return 1')) === w.Function.prototype"),
        ("indirect eval runs in the eval function's realm",
         "w.eval('this') === w && (w.eval('var zzRealm = 5'), w.zzRealm === 5 && typeof zzRealm === 'undefined') && w.eval('[1, 2]') instanceof w.Array && !(w.eval('[1]') instanceof Array) && Array.isArray(w.eval('[1]'))"),
        ("a sloppy function's this is its own realm's global",
         "w.eval('(function(){ return this; })')() === w && (function(){ return this; })() === globalThis && w.eval('(function(f){ return f(); })')(function(){ return this; }) === globalThis"),
        ("constructors and literals create objects in the callee's realm",
         "new w.Array() instanceof w.Array && !(new w.Array() instanceof Array) && Object.getPrototypeOf(w.eval('({})')) === w.Object.prototype && w.eval('/x/') instanceof w.RegExp && w.eval('(function(){})') instanceof w.Function && new w.Map() instanceof w.Map"),
        ("built-ins create their results in their own realm",
         "w.JSON.parse('[]') instanceof w.Array && w.Object.keys({ a: 1 }) instanceof w.Array && JSON.parse('[]') instanceof Array && w.Array.of(1) instanceof w.Array && w.Promise.resolve(1) instanceof w.Promise && !(w.Promise.resolve(1) instanceof Promise)"),
        ("changing one realm's prototypes does not touch the other",
         "(w.eval('Array.prototype.__realmMark = 1'), [].__realmMark === undefined && w.eval('[].__realmMark') === 1)"),
        ("Function.prototype.toString of another realm reads this realm's functions",
         "w.Function.prototype.toString.call(Math.max) === 'function max() {\\n    [native code]\\n}' && w.Function.prototype.toString.call(function f(a){ return a; }) === 'function f(a){ return a; }' && Function.prototype.toString.call(w.Math.max) === 'function max() {\\n    [native code]\\n}'"),
        ("cross-realm instanceof and identity follow the prototypes",
         "!(w.eval('[]') instanceof Array) && w.eval('[]') instanceof w.Array && Object.prototype.toString.call(w.eval('[]')) === '[object Array]' && w.Array.isArray([]) && w.Symbol.iterator === Symbol.iterator && w.Symbol.for('x') === Symbol.for('x')"),
        ("a generator from another realm runs there",
         "(function(){ var g = w.eval('(function*(){ yield this === globalThis; yield [] instanceof Array; })'); var it = g(); return it.next().value === true && it.next().value === true && Object.getPrototypeOf(it) === g.prototype; })()"),
        ("errors thrown in a realm are that realm's error objects and cross back",
         "(function(){ try { w.eval('null.x'); return false; } catch (e) { return e instanceof w.TypeError && !(e instanceof TypeError) && e.message.length > 0; } })() && (function(){ try { w.eval('(function(f){ f(); })')(function(){ throw new RangeError('r'); }); return false; } catch (e) { return e instanceof RangeError && e.message === 'r'; } })()"),
        ("a call stack spans realms (Error().stack, fn.caller)",
         "(function outerMain(){ var s = w.eval('(function inW(f){ return f(); })')(function innerMain(){ return new Error().stack; }); return s.indexOf('innerMain') >= 0 && s.indexOf('inW') >= 0 && s.indexOf('outerMain') >= 0; })()"),
        ("callbacks passed to another realm's built-ins run in their own realm",
         "[1, 2].map(w.eval('(function(x){ return [] instanceof Array && this === globalThis; })')).join() === 'true,true' && w.eval('[1]').map(function(){ return [] instanceof Array; })[0] === true"),
    ]

    /// DOM: `w` is a second realm whose document is a separate DOMNode tree
    /// (`JeffJSEnvironment.makeChildRealm`, as a host does for an iframe).
    static let realmDOMCases: [(String, String)] = [
        ("each realm has its own document and wrappers",
         "w.document !== document && w.document.body !== document.body && w.eval('document') === w.document && w.document.body.parentNode.parentNode === w.document && !document.contains(w.document.body)"),
        ("elements are made with their own realm's prototypes",
         "Object.getPrototypeOf(w.document.createElement('div')) !== Object.getPrototypeOf(document.createElement('div')) && w.document.createElement('div').ownerDocument === w.document && w.eval(`document.createElement('i')`) instanceof w.Object"),
        ("a node keeps its wrapper when it moves to another realm's document",
         "(function(){ var p = document.createElement('p'); w.document.body.appendChild(p); return w.document.body.lastChild === p && p.parentNode === w.document.body && w.document.querySelector('p') === p; })()"),
        ("nodes of the nested document read from the embedder are the nested realm's",
         "(function(){ var s = w.document.createElement('span'); s.id = 'realmspan'; w.document.body.appendChild(s); var got = w.document.getElementById('realmspan'); return got === s && Object.getPrototypeOf(got) === Object.getPrototypeOf(w.document.body) && w.eval(`document.getElementById('realmspan')`) === s; })()"),
    ]

    mutating func testRealmsDOM() {
        var outcomes: [(Bool, String)] = []
        func onMain(_ body: @escaping @JeffJSHostActor () -> Void) {
            if Thread.isMainThread { JeffJSHostActor.assumeIsolated { body() } } else { DispatchQueue.main.sync { JeffJSHostActor.assumeIsolated { body() } } }
        }
        onMain {
            let e = JeffJSEnvironment()
            let child = DOMNode.document()
            let html = DOMNode.element(tag: "html")
            html.appendChild(DOMNode.element(tag: "head"))
            html.appendChild(DOMNode.element(tag: "body"))
            child.appendChild(html)
            guard let wg = e.makeChildRealm(document: child) else { outcomes.append((false, "RealmsDOM: no realm")); return }
            let ctx = e.context
            let g = ctx.getGlobalObject()
            ctx.setPropertyStr(obj: g, name: "w", value: wg)
            g.freeValue()
            for (name, js) in JeffJSTestRunner.realmDOMCases {
                switch e.eval(js, filename: "<realms-dom>") {
                case .success(let v): outcomes.append((v == "true", "RealmsDOM: \(name) -> \(v ?? "undefined")"))
                case .exception(let m): outcomes.append((false, "RealmsDOM: \(name) threw \(m)"))
                }
            }
        }
        for (ok, message) in outcomes { assert(ok, message) }
    }

    mutating func testRealms() {
        // A runtime of its own: the shared test context stays single-realm.
        let rt = JeffJSRuntime()
        rt.setInterruptHandler { _ in Date() > JeffJSTestRunner.evalDeadline }
        let ctx = rt.newContext()
        guard let realm = rt.newRealm() else {
            assert(false, "Realms: newRealm() returned nil")
            return
        }
        let mainGlobal = ctx.getGlobalObject()
        let realmGlobal = realm.getGlobalObject()
        ctx.setPropertyStr(obj: mainGlobal, name: "w", value: realmGlobal.dupValue())
        for (name, js) in JeffJSTestRunner.realmCases {
            JeffJSStackDiag.currentLabel = "Realms: \(name)"
            let result = ctx.eval(input: js, filename: "<Realms>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            if result.isException {
                let exc = ctx.getException()
                assert(false, "Realms: \(name) threw \(ctx.toSwiftString(exc) ?? "?")")
                exc.freeValue()
            } else {
                let ok = result.isBool && result.toBool()
                assert(ok, "Realms: \(name) -> \(ctx.toSwiftString(result) ?? "?")")
            }
            result.freeValue()
        }
        realmGlobal.freeValue()
        mainGlobal.freeValue()
    }
}
