// HomedepotAkamaiConformance.swift
// JeffJS — conformance group "HomedepotAkamai" (homedepot fixer, 2026-10-06).
// homedepot.com's Akamai SBSD script (and Google's challenge VM) read engine and DOM
// details that JeffJS answered differently from JavaScriptCore / WebKit:
//  - RangeError texts of Number.prototype.toFixed / toString(radix) (SBSD counted the
//    message length: 84 vs WebKit's 77);
//  - Promise.prototype.catch / finally must Invoke `then` (ES §27.2.5.1/.3), and finally
//    rethrows the original reason (it threw a TypeError built from the reason's text);
//  - Error.stack frames and Error#sourceURL print the script URL without its query and
//    fragment (JSC StackFrame::sourceURLStripped);
//  - a node wrapper has no own properties (nodeType/nodeName/tagName/localName/style are
//    prototype accessors) and the host can give wrappers their interface prototypes
//    (`window.__rnSetNodeInterfaces`, used by the app's Safari surface pass).
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let homedepotAkamaiCases: [(String, String)] = [
        ("Number RangeError texts are JSC's",
         #"(function(){ function m(f){ try { f(); } catch (e) { return e instanceof RangeError ? e.message : 'not RangeError'; } return 'no throw'; } return m(function(){ (-1).toFixed(-1); }) === 'toFixed() argument must be between 0 and 100' && m(function(){ (1).toFixed(101); }) === 'toFixed() argument must be between 0 and 100' && m(function(){ (1).toString(1); }) === 'toString() radix argument must be between 2 and 36' && m(function(){ (1).toPrecision(0); }) === 'toPrecision() argument must be between 1 and 100' && m(function(){ (1).toExponential(-1); }) === 'toExponential() argument must be between 0 and 100'; })()"#),
        ("Promise.prototype.catch and finally Invoke `then` on the receiver",
         #"(function(){ var p = Promise.resolve(1), n = 0, T = Promise.prototype.then; p.then = function(a, b){ n++; return T.call(this, a, b); }; p.catch(function(){}); p.finally(function(){}); p.finally(); var th = { then: function(a, b){ return 'th:' + typeof a + ',' + typeof b; } }; return n === 3 && Promise.prototype.catch.call(th, function(){}) === 'th:undefined,function' && Promise.prototype.finally.call(th, function(){}) === 'th:function,function' && Promise.prototype.finally.call(th, 5) === 'th:number,number'; })()"#),
        ("Promise.prototype.finally on a non-object throws a TypeError",
         #"(function(){ try { Promise.prototype.finally.call(1, function(){}); return false; } catch (e) { return e instanceof TypeError; } })()"#),
        ("Promise.prototype.finally: setup (rethrows the original reason, keeps the value)",
         #"(function(){ var e = new RangeError('boom'); globalThis.__fin = []; Promise.reject(e).finally(function(){ __fin.push('f1'); }).then(function(){ __fin.push('fulfilled'); }, function(r){ __fin.push(r === e ? 'same' : 'other:' + r); }); Promise.resolve(7).finally(function(){ return 9; }).then(function(v){ __fin.push('v' + v); }); Promise.resolve(1).finally(function(){ throw 'x'; }).then(null, function(r){ __fin.push('t' + r); }); return true; })()"#),
        ("Promise.prototype.finally: check",
         #"__fin.indexOf('same') >= 0 && __fin.indexOf('v7') >= 0 && __fin.indexOf('tx') >= 0 && __fin.indexOf('fulfilled') < 0"#),
    ]

    mutating func testHomedepotAkamai() {
        runTrueCases("HomedepotAkamai", JeffJSTestRunner.homedepotAkamaiCases)

        // Error.stack / sourceURL strip the query and fragment of the script URL.
        let (_, ctx) = makeCtx()
        let js = "function f(){ return new Error('x'); }\nvar e = f();\nvar s = e.stack.split('\\n');\ns[0] === 'f@https://t.test/s.js:1:31' && s[1].indexOf('global code@https://t.test/s.js:2:') === 0 && e.sourceURL === 'https://t.test/s.js' && e.line === 1"
        let r = ctx.eval(input: js, filename: "https://t.test/s.js?v=9eddd5b5&t=223#frag", evalFlags: JS_EVAL_TYPE_GLOBAL)
        if r.isException {
            let exc = ctx.getException()
            assert(false, "HomedepotAkamai: stack URL without query threw \(ctx.toSwiftString(exc) ?? "?")")
            exc.freeValue()
        } else {
            let probe = ctx.eval(input: "(function(){ try { return f().stack + ' | ' + f().sourceURL; } catch (x) { return String(x); } })()", filename: "<probe>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            assert(r.isBool && r.toBool(), "HomedepotAkamai: Error.stack / sourceURL without the URL's query and fragment -> \(ctx.toSwiftString(probe) ?? "?")")
            probe.freeValue()
        }
        r.freeValue()

        // DOM: wrappers without own properties; interface prototypes from the host.
        var outcomes: [(Bool, String)] = []
        func onMain(_ body: @escaping @MainActor () -> Void) {
            if Thread.isMainThread { MainActor.assumeIsolated { body() } } else { DispatchQueue.main.sync { MainActor.assumeIsolated { body() } } }
        }
        let domCases: [(String, String)] = [
            ("a node wrapper has no own properties; identity attributes are prototype accessors", """
                (function(){ var d = document.createElement('div'), t = document.createTextNode('x'), c = document.createComment('y');
                  var P = Object.getPrototypeOf(d), g = function(k){ for (var o = P; o; o = Object.getPrototypeOf(o)) { var x = Object.getOwnPropertyDescriptor(o, k); if (x) return x; } return null; };
                  return Object.getOwnPropertyNames(d).length === 0 && Object.getOwnPropertyNames(t).length === 0 &&
                    d.nodeType === 1 && d.nodeName === 'DIV' && d.tagName === 'DIV' && d.localName === 'div' &&
                    t.nodeType === 3 && t.nodeName === '#text' && t.tagName === undefined && c.nodeType === 8 && c.nodeName === '#comment' &&
                    typeof g('nodeType').get === 'function' && typeof g('tagName').get === 'function' && typeof g('style').get === 'function' &&
                    typeof d.nativeNodeID === 'string' && d.nativeNodeID.length === 36 && t.style === undefined; })()
                """),
            ("el.style is one object per element and `el.style = text` sets its cssText", """
                (function(){ var d = document.createElement('div'); var s = d.style; d.style = 'color: red; width: 5px';
                  return s === d.style && d.style.color === 'red' && d.style.width === '5px' && d.getAttribute('style').indexOf('color') >= 0 &&
                    !Object.prototype.hasOwnProperty.call(d, 'style'); })()
                """),
            ("__rnSetNodeInterfaces gives wrappers their interface prototypes (new and cached ones)", """
                (function(){ var before = document.createElement('div'), span0 = document.createElement('span'), t0 = document.createTextNode('');
                  var EP = Object.getPrototypeOf(before);
                  var PD = Object.create(EP), PU = Object.create(EP), PT = Object.create(EP), PC = Object.create(EP);
                  Object.defineProperty(PD, Symbol.toStringTag, { value: 'HTMLDivElement' });
                  Object.defineProperty(PU, Symbol.toStringTag, { value: 'HTMLUnknownElement' });
                  Object.defineProperty(PT, Symbol.toStringTag, { value: 'Text' });
                  var ok = typeof __rnSetNodeInterfaces === 'function' && __rnSetNodeInterfaces({ div: PD, span: EP }, PU, PT, PC) === true;
                  var d = document.createElement('div'), u = document.createElement('foo'), x = document.createElement('x-foo'), t = document.createTextNode('');
                  return ok && Object.getPrototypeOf(d) === PD && Object.getPrototypeOf(before) === PD &&
                    Object.prototype.toString.call(d) === '[object HTMLDivElement]' && Object.getPrototypeOf(u) === PU &&
                    Object.getPrototypeOf(x) === EP && Object.getPrototypeOf(span0) === EP && Object.getPrototypeOf(t) === PT &&
                    Object.getPrototypeOf(t0) === PT && Object.getPrototypeOf(document.createComment('')) === PC &&
                    d.tagName === 'DIV' && typeof d.appendChild === 'function'; })()
                """),
        ]
        onMain {
            let e = JeffJSEnvironment()
            for (name, js) in domCases {
                switch e.eval(js, filename: "<HomedepotAkamai>") {
                case .success(let value): outcomes.append((value == "true", "HomedepotAkamai: \(name) -> \(value ?? "undefined")"))
                case .exception(let message): outcomes.append((false, "HomedepotAkamai: \(name) threw \(message)"))
                }
            }
        }
        for (ok, message) in outcomes { assert(ok, message) }
    }
}
