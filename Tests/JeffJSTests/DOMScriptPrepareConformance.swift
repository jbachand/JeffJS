// DOMScriptPrepareConformance.swift
// JeffJS — conformance group "DOMScriptPrepare": the app's spec-ladder rung 16
// (wiki-1, wiki-2) on the DOM bridge side:
//   - HTML §4.12.1.1 "prepare the script element" for script-inserted scripts
//     on every insertion path, "already started", currentScript, load/error,
//     the host notification contract (`onScriptExecution`)
//   - HTMLScriptElement IDL (async/non-blocking, defer, text)
//   - DOMTokenList (multiple tokens, validation, live indices), CSS.escape,
//     hidden="until-found", on* handler accessors (window/document/element),
//     handler return values
//   - DocumentFragment insertion on every method, performance.timeOrigin,
//     the host's content-attribute override for form controls
//
// Same driver shape as DOMBridgeRung15Conformance: every JS step runs on the
// main thread; task cases wait so the queued `setTimeout(…, 0)` tasks run.

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let scriptPreparePrelude = """
        var RAN = {};
        var SP = document.createElement('div'); SP.id = 'sp'; document.body.appendChild(SP);
        function sx(code) { var s = document.createElement('script'); s.text = code; return s; }
        """

    /// (name, JS expression that must evaluate to `true`).
    static let scriptPrepareSyncCases: [(String, String)] = [
        ("appendChild of an inline script runs it synchronously with currentScript = it", """
            (function(){ var s = sx('RAN.a1 = (RAN.a1 || 0) + 1; RAN.a1cs = document.currentScript;'); document.head.appendChild(s);
              var a = RAN.a1; s.parentNode.removeChild(s);
              return a === 1 && RAN.a1cs === s && document.currentScript === null; })()
            """),
        ("a started script never runs again (move, clone)", """
            (function(){ var s = sx('RAN.a2 = (RAN.a2 || 0) + 1;'); SP.appendChild(s); SP.insertBefore(s, SP.firstChild);
              document.head.appendChild(s); SP.appendChild(s.cloneNode(true));
              return RAN.a2 === 1; })()
            """),
        ("insertBefore / replaceChild / append / prepend / before / after / replaceWith / insertAdjacentElement all prepare", """
            (function(){ var n = 0; window.__spn = function () { n++; };
              var host = document.createElement('div'); SP.appendChild(host); var ref = document.createElement('i'); host.appendChild(ref);
              host.insertBefore(sx('__spn()'), ref); host.replaceChild(sx('__spn()'), ref);
              host.append(sx('__spn()')); host.prepend(sx('__spn()'));
              var k = host.lastChild; k.before(sx('__spn()')); k.after(sx('__spn()'));
              var r = document.createElement('b'); host.appendChild(r); r.replaceWith(sx('__spn()'));
              host.insertAdjacentElement('beforeend', sx('__spn()'));
              host.replaceChildren(sx('__spn()'));
              return n === 9; })()
            """),
        ("a detached insertion does not run; connecting the subtree runs its scripts in tree order", """
            (function(){ var L = []; window.__spo = L;
              var d = document.createElement('div'), p = document.createElement('p');
              p.appendChild(sx('__spo.push(1)')); d.appendChild(p); d.appendChild(sx('__spo.push(2)'));
              var before = L.length; SP.appendChild(d);
              return before === 0 && L.join() === '1,2'; })()
            """),
        ("DocumentFragment insertion runs the fragment's scripts and empties it", """
            (function(){ var L = []; window.__spf = L; var f = document.createDocumentFragment();
              f.appendChild(document.createElement('p')).appendChild(sx('__spf.push("a")')); f.appendChild(sx('__spf.push("b")'));
              SP.appendChild(f); return L.join() === 'a,b' && f.childNodes.length === 0; })()
            """),
        ("a script inserted by an earlier script of the same batch is not run twice; a removed later one does not run", """
            (function(){ var L = []; window.__spb = L; var f = document.createDocumentFragment();
              f.appendChild(sx('__spb.push(1); var t = document.getElementById("spb2"); t.parentNode.removeChild(t);'));
              var s2 = sx('__spb.push(2)'); s2.id = 'spb2'; f.appendChild(s2);
              SP.appendChild(f); return L.join() === '1'; })()
            """),
        ("innerHTML / outerHTML / insertAdjacentHTML / DOMParser scripts are already started", """
            (function(){ var d = document.createElement('div'); SP.appendChild(d);
              d.innerHTML = '<script>RAN.h1 = 1<\\/script>'; d.insertAdjacentHTML('beforeend', '<script>RAN.h2 = 1<\\/script>');
              var o = document.createElement('i'); d.appendChild(o); o.outerHTML = '<script>RAN.h3 = 1<\\/script>';
              var moved = d.querySelector('script'); SP.appendChild(moved);
              var pd = typeof __nativeParseHTMLDocument === 'function' ? __nativeParseHTMLDocument('<script>RAN.h4 = 1<\\/script>') : null;
              if (pd) SP.appendChild(pd.querySelector('script'));
              return RAN.h1 === undefined && RAN.h2 === undefined && RAN.h3 === undefined && RAN.h4 === undefined; })()
            """),
        ("__createContextualFragment leaves scripts startable (document.write / Range)", """
            (function(){ var f = document.__createContextualFragment(document.body, '<p>x</p><script>RAN.cf = document.currentScript.previousSibling.textContent<\\/script>');
              var none = RAN.cf; SP.appendChild(f); return none === undefined && RAN.cf === 'x'; })()
            """),
        ("children changed: text added to a connected empty script runs it once", """
            (function(){ var s = document.createElement('script'); SP.appendChild(s); var before = RAN.cc;
              s.textContent = 'RAN.cc = (RAN.cc || 0) + 1'; s.appendChild(document.createTextNode(';RAN.cc2 = 1'));
              return before === undefined && RAN.cc === 1 && RAN.cc2 === undefined; })()
            """),
        ("script types: text/plain, JSON and a bad type do not start; fixing the type and re-inserting runs it", """
            (function(){ var s = sx('RAN.ty = 1'); s.type = 'text/plain'; SP.appendChild(s);
              var j = sx('RAN.ty2 = 1'); j.type = 'application/json'; SP.appendChild(j);
              var none = RAN.ty === undefined && RAN.ty2 === undefined;
              s.remove(); s.type = ' TEXT/JavaScript '; SP.appendChild(s);
              var l = sx('RAN.ty3 = 1'); l.setAttribute('language', 'javascript'); SP.appendChild(l);
              var e = sx('RAN.ty4 = 1'); e.type = ''; SP.appendChild(e);
              return none && RAN.ty === 1 && RAN.ty3 === 1 && RAN.ty4 === 1; })()
            """),
        ("nomodule classic scripts do not run", """
            (function(){ var s = sx('RAN.nm = 1'); s.noModule = true; SP.appendChild(s); return RAN.nm === undefined && s.noModule === true; })()
            """),
        ("an exception in an inserted script is reported, the inserting code continues", """
            (function(){ SP.appendChild(sx('throw new Error("sp-boom")')); return true; })()
            """),
        ("script IDL: async is non-blocking by default, text, defer (wiki-1 d2/d10)", """
            (function(){ var s = document.createElement('script'), p = SP.firstChild;
              var a = [s.async, s.hasAttribute('async')].join();
              s.async = false; var b = [s.async, s.hasAttribute('async')].join(); s.async = true; var c = [s.async, s.getAttribute('async')].join();
              var t = document.createElement('script'); t.src = 'd10p.js'; t.text = 'x'; t.defer = true;
              var d = [t.getAttribute('src'), t.textContent, t.text, t.hasAttribute('defer'), t.async, t.getAttribute('async') === null].join();
              var h = document.createElement('div'); h.innerHTML = '<script>1<\\/script>';
              var parserAsync = h.firstChild.async;
              var div = document.createElement('div'); div.text = 'e';
              return a === 'true,false' && b === 'false,false' && c === 'true,' && d === 'd10p.js,x,x,true,true,true' &&
                parserAsync === false && div.text === 'e' && !div.hasAttribute('text') && /d10p\\.js$/.test(t.src); })()
            """),
        ("script.text on a connected started script does not run it again", """
            (function(){ var s = sx('RAN.tx = (RAN.tx || 0) + 1'); SP.appendChild(s); s.text = 'RAN.tx = 100'; return RAN.tx === 1; })()
            """),

        // ---- wiki-2
        ("classList.add/remove take several tokens; length, value, indices stay live (x1, x2)", """
            (function(){ var e = document.createElement('div'); var cl = e.classList; cl.add('a', 'b', 'c');
              var one = [e.className, cl.length, cl[0], cl[2], cl.value].join('_');
              cl.remove('a', 'c'); var two = [e.className, cl.length, cl[0], cl[1] === undefined].join('_');
              e.setAttribute('class', 'x y'); var three = [e.classList[1], e.classList.length].join('_');
              return one === 'a b c_3_a_c_a b c' && two === 'b_1_b_true' && three === 'y_2'; })()
            """),
        ("DOMTokenList: toggle force, replace, contains, iteration (x3)", """
            (function(){ var e = document.createElement('span'); e.classList.add('p', 'q');
              var r = [e.classList.contains('q'), e.classList.toggle('p'), e.classList.replace('q', 'r'), e.className].join('_');
              var f = [e.classList.toggle('z', true), e.classList.toggle('z', true), e.classList.toggle('z', false), e.classList.toggle('z', false)].join();
              var m = document.createElement('i'); m.className = 'a b c'; m.classList.replace('c', 'a'); var rep = m.className;
              var it = []; for (var t of m.classList) it.push(t); var ks = Array.from(m.classList.keys()).join();
              var fe = []; m.classList.forEach(function (v, i) { fe.push(i + v); });
              return r === 'true_false_true_r' && f === 'true,true,false,false' && rep === 'a b' && it.join() === 'a,b' &&
                ks === '0,1' && fe.join() === '0a,1b' && m.classList.item(1) === 'b' && m.classList.item(5) === null; })()
            """),
        ("DOMTokenList validation and no class attribute for an empty set", """
            (function(){ var e = document.createElement('div'), n1 = '', n2 = '';
              try { e.classList.add('ok', ''); } catch (x) { n1 = x.name; }
              try { e.classList.remove('a b'); } catch (x) { n2 = x.name; }
              var none = !e.hasAttribute('class'); e.classList.remove('q'); e.classList.toggle('q', false);
              return n1 === 'SyntaxError' && n2 === 'InvalidCharacterError' && none && !e.hasAttribute('class'); })()
            """),
        ("multi-class span found by querySelector / selector lists (x4)", """
            (function(){ var b = document.createElement('button'), s = document.createElement('span');
              s.classList.add('mf-icon', 'mf-icon--small', 'mf-collapsible-icon'); b.appendChild(s); SP.appendChild(b);
              return b.querySelector('.mf-collapsible-icon') === s && SP.querySelectorAll('button .mf-icon--small, button .x').length === 1; })()
            """),
        ("ontouchstart & co. on window / document / elements (x5)", """
            (function(){ return ['ontouchstart' in window, 'ontouchstart' in document.documentElement, 'ontouchstart' in document,
                typeof TouchEvent, window.ontouchstart === null, document.body.ontouchend === null, 'onpopstate' in window,
                'onreadystatechange' in document, document.body.hasOwnProperty('onclick')].join() ===
                'true,true,true,function,true,true,true,true,false'; })()
            """),
        ("on* accessors: set/replace/clear, non-objects become null, one call per dispatch", """
            (function(){ var n = [], el = document.createElement('div'), f = function () { n.push('f'); }, g = function () { n.push('g'); };
              el.onclick = f; var same = el.onclick === f; el.onclick = g; el.dispatchEvent(new Event('click'));
              el.onclick = 'code'; var str = el.onclick; el.onclick = f; el.onclick = null; el.dispatchEvent(new Event('click'));
              window.onfoo_test = 1;
              var w = 0; window.onmessage = function () { w++; }; window.dispatchEvent(new Event('message')); window.onmessage = null;
              var dcount = 0; document.onreadystatechange = function () { dcount++; }; document.dispatchEvent(new Event('readystatechange')); document.onreadystatechange = null;
              return same && n.join() === 'g' && str === null && el.onclick === null && w === 1 && dcount === 1; })()
            """),
        ("a handler returning false cancels; window.onerror returning true cancels", """
            (function(){ var el = document.createElement('a'), e1 = new Event('click', { cancelable: true }), e2 = new Event('click', { cancelable: true });
              el.onclick = function () { return false; }; el.dispatchEvent(e1);
              el.onclick = function () { return true; }; el.dispatchEvent(e2);
              var e3 = new Event('error', { cancelable: true }); window.onerror = function () { return true; }; window.dispatchEvent(e3);
              var e4 = new Event('error', { cancelable: true }); window.onerror = function () { return false; }; window.dispatchEvent(e4);
              window.onerror = null;
              return e1.defaultPrevented && !e2.defaultPrevented && e3.defaultPrevented && !e4.defaultPrevented; })()
            """),
        ("hidden = 'until-found' reflects; true / false / '' (x6)", """
            (function(){ var e = document.createElement('div'); e.hidden = 'until-found'; var a = [e.getAttribute('hidden'), e.hidden].join('_');
              e.setAttribute('hidden', 'UNTIL-FOUND'); var b = e.hidden;
              var f = document.createElement('div'); f.hidden = true; var c = [f.getAttribute('hidden'), f.hidden].join('_');
              f.setAttribute('hidden', 'x'); var d = f.hidden; f.hidden = ''; var g = f.hasAttribute('hidden'); f.hidden = 'yes';
              return a === 'until-found_until-found' && b === 'until-found' && c === '_true' && d === true && g === false &&
                f.getAttribute('hidden') === '' && document.createElement('p').hidden === false; })()
            """),
        ("CSS.escape (CSSOM §2.1, x7)", """
            (function(){ var r = [CSS.escape('1a'), CSS.escape('a.b'), CSS.escape('-'), CSS.escape('-1x'), CSS.escape('--a'),
                CSS.escape('\\0x'), CSS.escape('a\\u0001b\\u007f'), CSS.escape('é☃'), CSS.escape('_-a9Z'), CSS.escape('a b#c'), CSS.escape(''),
                CSS.escape(12)];
              var thrown = false; try { CSS.escape(); } catch (e) { thrown = e instanceof TypeError; }
              return thrown && r.join('|') === '\\\\31 a|a\\\\.b|\\\\-|-\\\\31 x|--a|\\ufffdx|a\\\\1 b\\\\7f |é☃|_-a9Z|a\\\\ b\\\\#c||\\\\31 2'; })()
            """),
        ("closest() with a selector list (x8)", """
            (function(){ var d = document.createElement('div'); d.className = 'x'; var s = document.createElement('span'); d.appendChild(s);
              var c = s.closest('.collapsible-headings-collapsed, .x'); return c === d; })()
            """),

        // ---- DocumentFragment insertion on every method (15-22)
        ("every insertion method moves a fragment's children and empties it", """
            (function(){ function frag() { var f = document.createDocumentFragment(); f.appendChild(document.createElement('b')); f.appendChild(document.createTextNode('t')); return f; }
              var host = document.createElement('div'); SP.appendChild(host); var ref = document.createElement('i'); host.appendChild(ref);
              var out = [], f;
              f = frag(); host.appendChild(f); out.push(f.childNodes.length);
              f = frag(); host.insertBefore(f, ref); out.push(f.childNodes.length);
              f = frag(); var r2 = document.createElement('u'); host.appendChild(r2); host.replaceChild(f, r2); out.push(f.childNodes.length);
              f = frag(); host.append(f); out.push(f.childNodes.length);
              f = frag(); host.prepend(f); out.push(f.childNodes.length);
              f = frag(); ref.before(f); out.push(f.childNodes.length);
              f = frag(); ref.after(f); out.push(f.childNodes.length);
              f = frag(); var r3 = document.createElement('s'); host.appendChild(r3); r3.replaceWith(f); out.push(f.childNodes.length);
              f = frag(); host.insertAdjacentElement('afterbegin', f); out.push(f.childNodes.length);
              var bs = host.getElementsByTagName('b').length;
              f = frag(); host.replaceChildren(f); out.push(f.childNodes.length, host.childNodes.length);
              return out.join() === '0,0,0,0,0,0,0,0,0,0,2' && bs === 9 && host.firstChild.nodeName === 'B'; })()
            """),

        // ---- performance.timeOrigin (HR-Time §5)
        ("performance.timeOrigin is on the Unix epoch", """
            Math.abs(performance.timeOrigin + performance.now() - Date.now()) < 1000
            """),
    ]

    /// Task cases: (name, setup, check).
    static func scriptPrepareTaskCases(dir: String) -> [(String, String, String)] {
        [
            ("external script-inserted script: fetched, run, then load; missing file: error only (wiki-1 d1/d5)", """
                (function(){ var ev = []; window.__spx = ev;
                  var s = document.createElement('script'); s.src = 'file://\(dir)/x1.js';
                  s.onload = function () { ev.push('load' + (window.__x1 || 0)); if (s.parentNode) s.parentNode.removeChild(s); };
                  s.onerror = function () { ev.push('error'); }; document.head.appendChild(s);
                  var m = document.createElement('script'); m.src = 'file://\(dir)/missing.js';
                  m.onload = function () { ev.push('mload'); }; m.addEventListener('error', function (e) { ev.push('merror' + e.bubbles); });
                  document.head.appendChild(m); ev.push('sync' + (window.__x1 || 0)); window.__spxs = s; })()
                """, "window.__spx.join() === 'sync0,load1,merrorfalse' && window.__spxs.parentNode === null"),
            ("src set after insertion prepares; currentScript is the element (wiki-1 d8/d9)", """
                (function(){ var s = document.createElement('script'), ev = []; window.__sp9 = ev;
                  s.onload = function () { ev.push('load'); }; document.head.appendChild(s); s.src = 'file://\(dir)/x9.js'; window.__sp9s = s; })()
                """, "window.__x9cs === window.__sp9s && window.__sp9.join() === 'load' && document.currentScript === null"),
            ("scripts inserted by an external script run too (wiki-1 d3)", """
                (function(){ var s = document.createElement('script'); s.src = 'file://\(dir)/boot.js'; document.head.appendChild(s); })()
                """, "window.__bootRan === 1 && window.__bootInner === 1"),
        ]
    }

    mutating func testDOMScriptPrepare() {
        var outcomes: [(Bool, String)] = []
        var env: JeffJSEnvironment?
        var errors: [String] = []
        let dir = NSTemporaryDirectory() + "jeffjs-script-prepare-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let files = [
            "x1.js": "window.__x1 = (window.__x1 || 0) + 1;",
            "x9.js": "window.__x9cs = document.currentScript;",
            "boot.js": "window.__bootRan = 1; var i = document.createElement('script'); i.text = 'window.__bootInner = (window.__bootInner || 0) + 1'; document.head.appendChild(i);",
        ]
        for (name, body) in files { try? body.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8) }
        defer { try? FileManager.default.removeItem(atPath: dir) }

        func onMain(_ body: @escaping @MainActor () -> Void) {
            if Thread.isMainThread { MainActor.assumeIsolated { body() } } else { DispatchQueue.main.sync { MainActor.assumeIsolated { body() } } }
        }
        func waitForTasks() {
            if Thread.isMainThread { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) } else { Thread.sleep(forTimeInterval: 0.3) }
        }
        func record(_ result: JeffJSEvalResult, _ name: String) {
            switch result {
            case .success(let value): outcomes.append((value == "true", "DOMScriptPrepare: \(name) -> \(value ?? "undefined")"))
            case .exception(let message): outcomes.append((false, "DOMScriptPrepare: \(name) threw \(message)"))
            }
        }
        let taskCases = Self.scriptPrepareTaskCases(dir: dir)

        onMain {
            let e = JeffJSEnvironment()
            env = e
            e.onConsoleMessage = { level, msg in if level == "error" { errors.append(msg) } }
            _ = e.eval(JeffJSTestRunner.scriptPreparePrelude, filename: "<sp-prelude>")
            for (name, js) in JeffJSTestRunner.scriptPrepareSyncCases {
                record(e.eval(js, filename: "<sp>"), name)
            }
            for (_, setup, _) in taskCases { _ = e.eval(setup, filename: "<sp-task-setup>") }
        }
        waitForTasks()
        onMain {
            guard let e = env else { return }
            for (name, _, check) in taskCases { record(e.eval(check, filename: "<sp-task-check>"), name) }
            outcomes.append((errors.contains { $0.contains("sp-boom") },
                             "DOMScriptPrepare: an inserted script's exception is reported (\(errors.count) errors)"))

            // The host contract: one notification per prepared <script>, the
            // element itself, in tree order, already started; none for the
            // parent, for innerHTML scripts, or for a second insertion.
            let h = JeffJSEnvironment()
            var seen: [String] = []
            var startedWhenSeen = true
            h.onScriptExecution = { node in
                seen.append(node.attributes["id"] ?? "?")
                startedWhenSeen = startedWhenSeen && node.scriptAlreadyStarted
            }
            record(h.eval("""
                (function(){ var d = document.createElement('div'), a = document.createElement('script'); a.id = 'a'; a.src = 'a.js';
                  var b = document.createElement('script'); b.id = 'b'; b.text = '1'; var c = document.createElement('script'); c.id = 'c';
                  var p = document.createElement('p'); p.appendChild(b); d.appendChild(a); d.appendChild(p); d.appendChild(c);
                  document.body.appendChild(d); document.body.appendChild(d); c.text = 'x'; c.text = 'y';
                  d.insertAdjacentHTML('beforeend', '<script id="h">1<\\/script>');
                  var q = document.createElement('script'); q.id = 'q'; document.head.appendChild(q); q.src = 'q.js'; q.src = 'q2.js';
                  return true; })()
                """, filename: "<sp-contract>"), "contract eval")
            outcomes.append((seen == ["a", "b", "c", "q"] && startedWhenSeen,
                             "DOMScriptPrepare: onScriptExecution gets each script once, in tree order, already started (got \(seen))"))

            // Content attribute override (form control state kept in attributes).
            if let dom = h.domBridge {
                dom.contentAttributeOverride = { node, name in
                    guard node.attributes["id"] == "fc", name == "value" else { return .none }
                    return .some("page")
                }
                record(h.eval("""
                    (function(){ var i = document.createElement('input'); i.id = 'fc'; i.setAttribute('value', 'state'); document.body.appendChild(i);
                      var c = document.createElement('input'); c.id = 'fc2'; c.setAttribute('value', 'v2');
                      var w = document.createElement('div'); w.appendChild(i.cloneNode());
                      return i.getAttribute('value') === 'page' && i.hasAttribute('value') && i.getAttributeNames().join() === 'id,value' &&
                        /value="page"/.test(i.outerHTML) && c.getAttribute('value') === 'v2'; })()
                    """, filename: "<sp-override>"), "content attribute override reaches getAttribute / serializer")
            }
        }
        for (ok, message) in outcomes { assert(ok, message) }
    }
}
