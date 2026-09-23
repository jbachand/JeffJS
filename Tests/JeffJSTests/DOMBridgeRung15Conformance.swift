// DOMBridgeRung15Conformance.swift
// JeffJS — conformance group "DOMBridgeRung15": the DOM bridge's interaction
// surface (the app's spec-ladder rung 15, JeffJS-bridge side):
//   15-11 EventTarget: passive, default-passive touch/wheel targets,
//         composedPath/currentTarget after dispatch, listeners surviving
//         removal (and collection of unreachable detached nodes)
//   15-14 HTMLElement.click() + activation behaviour
//   15-15 focus()/blur(), activeElement, focus events, autofocus
//   15-18 innerText getter/setter
//   15-19 MutationObserver
//   15-20 dataset (and Proxy [[OwnPropertyKeys]] underneath it)
//   15-22 fragments, templates, adoptNode/importNode, ownerDocument
//   15-25 <details> toggle
//   rung 14 leftovers: attribute order, </br> and </p> in foreign content
//
// Runs inside EngineTests/testConformance on the conformance thread; every JS
// step runs on the main thread (the bridges are main-actor bound). Microtask
// cases split setup and check into two evals (eval drains the job queue);
// task cases wait on the conformance thread so the main run loop can run the
// queued `setTimeout(…, 0)`.

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let rung15Prelude = """
        function $(id) { return document.getElementById(id); }
        function nl(s) { return String(s).replace(/\\n/g, '\\\\n').replace(/\\t/g, '\\\\t'); }
        var R15 = document.createElement('div'); R15.id = 'r15'; document.body.appendChild(R15);
        function fx(html) { var d = document.createElement('div'); d.innerHTML = html; R15.appendChild(d); return d; }
        """

    /// (name, JS expression that must evaluate to `true`).
    static let rung15SyncCases: [(String, String)] = [
        // ---- 15-11 EventTarget
        ("passive listener: preventDefault is a no-op inside and after", """
            (function(){ var d = fx('<i></i>').firstChild, inside = 'none';
              d.addEventListener('x04', function (e) { e.preventDefault(); inside = e.defaultPrevented; }, { passive: true });
              var r = d.dispatchEvent(new Event('x04', { cancelable: true }));
              return inside === false && r === true; })()
            """),
        ("touchstart/touchmove/wheel on window/document/body default to passive", """
            (function(){ var w = 'none', d = 'none', b = 'none', x = 'none', exp = 'none';
              function f(e) { e.preventDefault(); w = e.defaultPrevented; window.removeEventListener('touchstart', f); }
              window.addEventListener('touchstart', f);
              document.body.dispatchEvent(new Event('touchstart', { bubbles: true, cancelable: true }));
              function g(e) { e.preventDefault(); d = e.defaultPrevented; }
              document.addEventListener('wheel', g); document.body.dispatchEvent(new Event('wheel', { bubbles: true, cancelable: true }));
              document.removeEventListener('wheel', g);
              function h(e) { e.preventDefault(); b = e.defaultPrevented; }
              document.body.addEventListener('touchmove', h); document.body.dispatchEvent(new Event('touchmove', { cancelable: true }));
              document.body.removeEventListener('touchmove', h);
              var el = fx('<i></i>').firstChild; el.addEventListener('touchstart', function (e) { e.preventDefault(); x = e.defaultPrevented; });
              el.dispatchEvent(new Event('touchstart', { cancelable: true }));
              function k(e) { e.preventDefault(); exp = e.defaultPrevented; }
              window.addEventListener('touchstart', k, { passive: false });
              window.dispatchEvent(new Event('touchstart', { cancelable: true })); window.removeEventListener('touchstart', k);
              return w === false && d === false && b === false && x === true && exp === true; })()
            """),
        ("composedPath() is [] and currentTarget null after dispatch", """
            (function(){ var d = fx('<a><b><i></i></b></a>'), i = d.querySelector('i'), p = [];
              i.addEventListener('x06', function (e) { p = e.composedPath(); });
              var ev = new Event('x06', { bubbles: true }); i.dispatchEvent(ev);
              return p.length === 9 && p[0] === i && p[p.length - 1] === window && ev.composedPath().length === 0 &&
                ev.currentTarget === null && ev.eventPhase === 0 && ev.target === i; })()
            """),
        ("returnValue = false cancels; returnValue reads !defaultPrevented", """
            (function(){ var d = fx('<i></i>').firstChild, rv = 'none';
              d.addEventListener('rv', function (e) { e.returnValue = false; rv = e.defaultPrevented; });
              var ev = new Event('rv', { cancelable: true });
              var r = d.dispatchEvent(ev); var nc = new Event('q'); nc.returnValue = false;
              return rv === true && r === false && ev.returnValue === false && nc.defaultPrevented === false && nc.returnValue === true; })()
            """),
        ("the engine's Event is marked real; UI event constructors exist", """
            (function(){ var m = new MouseEvent('click', { clientX: 5, bubbles: true }), f = new FocusEvent('focus', { relatedTarget: document.body }),
                t = new ToggleEvent('toggle', { oldState: 'closed', newState: 'open' }), k = new KeyboardEvent('keydown', { key: 'a' });
              return Event.__jeffjsReal === true && m instanceof MouseEvent && m instanceof UIEvent && m instanceof Event &&
                m.clientX === 5 && m.button === 0 && m.bubbles === true && f.relatedTarget === document.body &&
                t.newState === 'open' && k.key === 'a' && new PointerEvent('pointerdown') instanceof MouseEvent &&
                new TouchEvent('touchstart').touches.length === 0; })()
            """),
        ("listeners survive removeChild / re-append / innerHTML / remove() (m13)", """
            (function(){ var n = 0, c = fx(''), el = document.createElement('div');
              el.addEventListener('click', function () { n++; });
              c.appendChild(el); el.dispatchEvent(new Event('click')); var z = n; c.removeChild(el); c.appendChild(el);
              el.dispatchEvent(new Event('click')); var a = n;
              c.innerHTML = ''; c.appendChild(el); el.dispatchEvent(new Event('click')); var b = n;
              var q = fx('<div><p></p></div>'), p = q.querySelector('p'), par = p.parentNode; p.addEventListener('click', function () { n++; });
              p.remove(); par.appendChild(p); p.dispatchEvent(new Event('click'));
              return [z, a, b, n].join('_') === '1_2_3_4' && c.firstChild === el; })()
            """),
        ("listeners survive replaceChild, textContent and a removed ancestor", """
            (function(){ var n = 0, c = fx('<div><span><b></b></span></div>'), span = c.querySelector('span'), b = c.querySelector('b');
              b.addEventListener('x', function () { n++; });
              c.firstChild.replaceChild(document.createElement('i'), span); b.dispatchEvent(new Event('x'));
              c.textContent = ''; c.appendChild(span); b.dispatchEvent(new Event('x', { bubbles: true }));
              return n === 2 && b.parentNode === span && span.parentNode === c; })()
            """),

        // ---- 15-14 click()
        ("checkbox click(): toggles before listeners, input then change (e09)", """
            (function(){ var d = fx('<input type="checkbox"><input type="checkbox">'), a = d.firstChild, b = d.lastChild, L = [], inClick = 'none';
              a.addEventListener('click', function (e) { inClick = a.checked; e.preventDefault(); });
              a.addEventListener('input', function () { L.push('i'); }); a.addEventListener('change', function () { L.push('c'); });
              a.click(); var r1 = [inClick, a.checked, L.length].join('-');
              var M = [];
              b.addEventListener('click', function (e) { M.push('k' + [e.isTrusted, e.bubbles, e.cancelable, e instanceof MouseEvent].join('')); });
              b.addEventListener('input', function (e) { M.push('i' + e.bubbles); }); b.addEventListener('change', function (e) { M.push('c' + e.bubbles); });
              b.click();
              return r1 + '_' + M.join('-') + '_' + b.checked === 'true-false-0_kfalsetruetruetrue-itrue-ctrue_true'; })()
            """),
        ("label click() clicks its control; control / labels (fm14)", """
            (function(){ var d = fx('<label id="r15l1" for="r15c">A</label><label id="r15l2"><input type="checkbox" id="r15c"> B</label><label>x<input id="r15t"></label>');
              var l1 = $('r15l1'), c = $('r15c'), k = 0; c.addEventListener('click', function () { k++; });
              l1.click();
              var inner = 0; $('r15l2').addEventListener('click', function () { inner++; }); c.click();
              return l1.control === c && c.labels.length === 2 && c.checked === false && k === 2 && inner === 1 &&
                $('r15t').labels.length === 1 && $('r15t').labels[0].control === $('r15t') && document.createElement('div').labels === null; })()
            """),
        ("radio click(): checks it, unchecks the group; a canceled click restores", """
            (function(){ var d = fx('<form><input type="radio" name="g" checked><input type="radio" name="g"></form>'), r = d.querySelectorAll('input'), ch = 0;
              r[1].addEventListener('change', function () { ch++; }); r[1].click(); var s1 = [r[0].checked, r[1].checked, ch].join();
              r[0].addEventListener('click', function (e) { e.preventDefault(); }); r[0].click();
              r[1].click();
              return s1 === 'false,true,1' && r[0].checked === false && r[1].checked === true && ch === 1; })()
            """),
        ("click(): disabled controls do nothing; host API reports cancelation", """
            (function(){ var d = fx('<button disabled>x</button><fieldset disabled><button>y</button></fieldset><span></span>'), n = 0;
              var bs = d.querySelectorAll('button'); bs[0].addEventListener('click', function () { n++; }); bs[1].addEventListener('click', function () { n++; });
              bs[0].click(); bs[1].click();
              var s = d.querySelector('span'); s.addEventListener('click', function (e) { e.preventDefault(); });
              return n === 0 && __nativeEventBridge.click(s) === false && __nativeEventBridge.click(d) === true; })()
            """),
        ("click(): submit buttons use form.requestSubmit, links the activation hook", """
            (function(){ var d = fx('<form><button id="r15s">go</button><input type="reset" id="r15r"></form><a href="#x" id="r15a"><b>l</b></a>'), got = [];
              var f = d.querySelector('form'); f.requestSubmit = function (s) { got.push('submit:' + s.id); }; f.reset = function () { got.push('reset'); };
              window.__nativeActivationBehavior = function (el, kind) { got.push(kind + ':' + el.id); return true; };
              $('r15s').click(); $('r15r').click(); d.querySelector('b').click();
              var a = $('r15a'); a.addEventListener('click', function (e) { e.preventDefault(); }); a.click();
              delete window.__nativeActivationBehavior;
              return got.join() === 'submit:r15s,reset,hyperlink:r15a'; })()
            """),

        // ---- 15-15 focus
        ("focus()/blur(): event order, activeElement, focusability (e10)", """
            (function(){ var d = fx('<input><input><div id="r15n"></div><div id="r15t" tabindex="-1"></div>'), a = d.childNodes[0], b = d.childNodes[1], L = [];
              function key(t) { return t === a ? 'a' : t === b ? 'b' : t === document.body ? 'bd' : (t && t.id) || String(t); }
              ['focus', 'blur'].forEach(function (t) { d.addEventListener(t, function (e) { L.push(t.charAt(0).toUpperCase() + key(e.target)); }, true); });
              d.addEventListener('focusin', function (e) { L.push('I' + key(e.target)); });
              d.addEventListener('focusout', function (e) { L.push('O' + key(e.target)); });
              var ae0 = key(document.activeElement);
              a.focus(); b.focus(); var ae1 = key(document.activeElement); b.blur(); var ae2 = key(document.activeElement);
              var l1 = L.join('');
              $('r15n').focus(); var ae3 = key(document.activeElement); $('r15t').focus(); var ae4 = key(document.activeElement); $('r15t').blur();
              return [ae0, l1, ae1, ae2, ae3, ae4].join('_') === 'bd_FaIaBaOaFbIbBbOb_b_bd_bd_r15t'; })()
            """),
        ("focus events: bubbling, relatedTarget, trusted", """
            (function(){ var d = fx('<input><input>'), a = d.firstChild, b = d.lastChild, s = [];
              b.addEventListener('focus', function (e) { s.push(e.relatedTarget === a, e.bubbles, e.isTrusted, e instanceof FocusEvent, document.activeElement === b); });
              a.addEventListener('blur', function (e) { s.push(e.relatedTarget === b, document.activeElement === document.body); });
              d.addEventListener('focusin', function (e) { s.push(e.bubbles); });
              a.focus(); s.length = 0; b.focus(); b.blur();
              return s.join() === 'true,true,true,false,true,true,true,true'; })()
            """),
        ("not focusable: disabled, hidden, display:none, visibility:hidden, a without href", """
            (function(){ var d = fx('<input disabled><input hidden><div style="display:none"><input></div><input style="visibility:hidden">' +
                '<a>x</a><a href="#">y</a><button>z</button><fieldset disabled><legend><input></legend><input></fieldset>');
              var r = [];
              d.querySelectorAll('input,a,button').forEach(function (e) { e.focus(); r.push(document.activeElement === e ? 1 : 0); e.blur(); });
              return r.join('') === '000001110'; })()
            """),
        ("activeElement falls back to body when the focused element is removed", """
            (function(){ var d = fx('<input>'), i = d.firstChild; i.focus(); var s1 = document.activeElement === i;
              d.removeChild(i); var s2 = document.activeElement === document.body; d.appendChild(i);
              return s1 && s2 && document.activeElement === document.body; })()
            """),
        ("host focus/blur (__nativeEventBridge) runs the same steps", """
            (function(){ var d = fx('<input><input>'), a = d.firstChild, b = d.lastChild, L = [];
              d.addEventListener('focusin', function (e) { L.push('in' + (e.target === a ? 'a' : 'b')); });
              d.addEventListener('focusout', function (e) { L.push('out' + (e.target === a ? 'a' : 'b')); });
              __nativeEventBridge.focus(a); __nativeEventBridge.focus(b); var ae = document.activeElement === b;
              __nativeEventBridge.blur(b);
              return ae && document.activeElement === document.body && L.join() === 'ina,outa,inb,outb'; })()
            """),

        // ---- 15-18 innerText
        ("innerText: display:none dropped, <br> = \\\\n, whitespace collapsed (m08)", """
            (function(){ var b = fx('<div>a<span style="display:none">x</span><br>b  c</div>').firstChild;
              return b.textContent === 'axb  c' && b.innerText === 'a\\nb c'; })()
            """),
        ("innerText: visibility:hidden, text-transform, block boundaries (m09)", """
            (function(){ var b = fx('<div><span style="visibility:hidden">h</span><span style="text-transform:uppercase">ab</span><div>c</div></div>').firstChild;
              return nl(b.innerText) === 'AB\\\\nc\\\\n'; })()
            """),
        ("innerText: paragraphs, table cells, pre, leading/trailing space", """
            (function(){ var p = fx('<div>  x <p>one</p><p>two</p>y</div>').firstChild;
              var t = fx('<table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>').firstChild;
              var pre = fx('<pre>a  b\\n c</pre>').firstChild; var ws = fx('<div style="white-space:pre-line">a  b\\n  c</div>').firstChild;
              return nl(p.innerText) === 'x\\\\n\\\\none\\\\n\\\\ntwo\\\\n\\\\ny' && nl(t.innerText) === 'a\\\\tb\\\\nc\\\\td' &&
                nl(pre.innerText) === 'a  b\\\\n c' && nl(ws.innerText) === 'a b\\\\nc'; })()
            """),
        ("innerText of a detached / display:none element is its textContent", """
            (function(){ var d = document.createElement('div'); d.innerHTML = 'a<br><span style="display:none">b</span>';
              var h = fx('<div style="display:none">x <b>y</b></div>').firstChild;
              return d.innerText === 'ab' && h.innerText === 'x y'; })()
            """),
        ("innerText setter: text + <br> per line break", """
            (function(){ var d = fx('<b>old</b>'); d.innerText = 'a\\nb\\r\\nc'; var e = fx('x'); e.innerText = '';
              return d.innerHTML === 'a<br>b<br>c' && d.childNodes.length === 5 && e.childNodes.length === 0; })()
            """),

        // ---- 15-20 dataset
        ("dataset: camelCase, delete, in, Object.keys, for-in (m03)", """
            (function(){ var b = fx('<div data-abc-def="y" data-x-1="z" data-Q="q"></div>').firstChild; b.dataset.fooBar = 'x';
              var r = [b.getAttribute('data-foo-bar'), b.dataset.abcDef];
              delete b.dataset.fooBar;
              r.push(b.hasAttribute('data-foo-bar'), 'abcDef' in b.dataset, Object.keys(b.dataset).join('+'));
              var ks = []; for (var k in b.dataset) ks.push(k);
              return r.join('_') === 'x_y_false_true_abcDef+x-1+q' && ks.join('+') === 'abcDef+x-1+q' &&
                b.dataset === b.dataset && b.dataset['abc-def'] === undefined && 'toString' in b.dataset &&
                JSON.stringify(Object.entries(b.dataset)) === '[["abcDef","y"],["x-1","z"],["q","q"]]'; })()
            """),
        ("dataset: invalid names throw SyntaxError; numbers stringify", """
            (function(){ var b = document.createElement('div'), n;
              try { b.dataset['a-b'] = 1; } catch (e) { n = e.name; }
              b.dataset.num = 5; b.dataset.aB = null;
              return n === 'SyntaxError' && b.getAttribute('data-num') === '5' && b.getAttribute('data-a-b') === 'null'; })()
            """),
        ("Proxy [[OwnPropertyKeys]]: Object.keys / Reflect.ownKeys / for-in use the traps", """
            (function(){ var p = new Proxy({}, { ownKeys: function () { return ['a', 'b', 'h']; },
                getOwnPropertyDescriptor: function (t, k) { return { value: k, enumerable: k !== 'h', configurable: true, writable: true }; } });
              var fi = []; for (var k in p) fi.push(k);
              return Object.keys(p).join() === 'a,b' && Reflect.ownKeys(p).join() === 'a,b,h' &&
                Object.getOwnPropertyNames(p).join() === 'a,b,h' && fi.join() === 'a,b'; })()
            """),

        // ---- 15-22 fragments, templates, adoption
        ("appendChild(fragment) moves the children, returns the fragment (m14)", """
            (function(){ var f = document.createDocumentFragment(), c = fx('');
              for (var k = 0; k < 3; k++) f.appendChild(document.createElement('div'));
              var r = c.appendChild(f); var g = document.createDocumentFragment(); g.append('t', document.createElement('b'));
              c.insertBefore(g, c.firstChild);
              return [f.childNodes.length, c.children.length, r === f, c.firstChild.nodeType, c.childNodes.length].join('_') === '0_4_true_3_5'; })()
            """),
        ("template: content clone inserts every child; content has its own document (m15)", """
            (function(){ var d = fx('<template><div class="tc">x</div><div class="tc">y</div></template><div></div>'), t = d.firstChild, c = d.lastChild;
              var n0 = t.content.childNodes.length; c.appendChild(t.content.cloneNode(true));
              var od = t.content.ownerDocument;
              return [n0, t.content.childNodes.length, od !== document, t.childNodes.length, c.children.length].join('_') === '2_2_true_0_2' &&
                od.nodeType === 9 && t.content.firstChild.ownerDocument === od && od.createElement('p').ownerDocument === od &&
                c.firstChild.ownerDocument === document; })()
            """),
        ("adoptNode / importNode update ownerDocument (m17)", """
            (function(){ var d2 = document.implementation.createHTMLDocument('x');
              var n = d2.createElement('div'); d2.body.appendChild(n); d2.body.appendChild(d2.createElement('p'));
              var pre = n.ownerDocument === d2; var q = d2.createElement('q'); d2.body.appendChild(q); d2.body.removeChild(q);
              var a = document.adoptNode(n); var imp = document.importNode(d2.body, true);
              return pre && q.ownerDocument === d2 && [a === n, n.ownerDocument === document, n.parentNode === null, imp.ownerDocument === document,
                imp.childNodes.length, d2.body.childNodes.length].join('_') === 'true_true_true_true_1_1' &&
                d2.importNode(document.createElement('i')).ownerDocument === d2 && document.ownerDocument === undefined; })()
            """),
        ("append/prepend/before/after/replaceWith keep order; hierarchy errors throw", """
            (function(){ var c = fx('<i id="r15o"></i>'), a = $('r15o');
              function mk(x) { var d = document.createElement('b'); d.id = 'r15x' + x; return d; }
              c.append(mk('b')); c.prepend(mk('c')); a.before(mk('d')); a.after(mk('e'));
              $('r15xb').replaceWith(mk('f')); c.insertBefore(mk('g'), a); c.append('z');
              var ids = []; for (var k = 0; k < c.children.length; k++) ids.push(c.children[k].id === 'r15o' ? 'a' : c.children[k].id.slice(4));
              var err; try { a.appendChild(c); } catch (e) { err = e.name; }
              return ids.join('') + '_' + c.childNodes.length === 'cdgaef_7' && err === 'HierarchyRequestError'; })()
            """),

        // ---- rung 14 leftovers
        ("attributes serialise in source order, then append order", """
            (function(){ var d = fx('<p z="1" a="2" m="3"></p>'), p = d.firstChild; p.setAttribute('b', '4'); p.removeAttribute('a'); p.setAttribute('a', '5');
              return d.innerHTML === '<p z="1" m="3" b="4" a="5"></p>' && p.getAttributeNames().join() === 'z,m,b,a' &&
                p.cloneNode().outerHTML === '<p z="1" m="3" b="4" a="5"></p>'; })()
            """),
        ("</br> and </p> break out of foreign content", """
            (function(){ return fx('<svg><g></br>x</g></svg>').innerHTML === '<svg><g></g></svg><br>x' &&
              fx('<svg><g></p>x</g></svg>').innerHTML === '<svg><g></g></svg><p></p>x' &&
              fx('<math><mi></br></mi></math>').innerHTML === '<math><mi><br></mi></math>'; })()
            """),
    ]

    /// Microtask cases: (name, setup, check). The check runs in a later eval,
    /// after the setup's microtasks drained.
    static let rung15MicrotaskCases: [(String, String, String)] = [
        ("MutationObserver: attribute/characterData oldValue, record order (m11)", """
            (function(){ var o = [], b = fx('<div>a</div>').firstChild;
              var mo = new MutationObserver(function (r) { for (var k = 0; k < r.length; k++) o.push(r[k].type.charAt(0) + (r[k].oldValue === null ? 'N' : r[k].oldValue)); });
              mo.observe(b, { attributes: true, attributeOldValue: true, characterData: true, characterDataOldValue: true, subtree: true });
              b.setAttribute('data-a', '1'); b.setAttribute('data-a', '2'); b.removeAttribute('data-a'); b.removeAttribute('nope');
              b.firstChild.data = 'b'; b.firstChild.data = 'c';
              window.__m11 = o; window.__m11mo = mo; })()
            """, "(function(){ window.__m11mo.disconnect(); return window.__m11.join('_') === 'aN_a1_a2_ca_cb'; })()"),
        ("MutationObserver: attributeFilter + subtree; takeRecords empties the queue (m12)", """
            (function(){ var n = 0, d = fx('<div><div></div></div>'), p = d.firstChild, c = p.firstChild; c.id = 'r15m12c';
              var mo = new MutationObserver(function () { n++; });
              mo.observe(p, { attributes: true, subtree: true, attributeFilter: ['data-x'] });
              c.title = 't'; c.setAttribute('data-x', '1'); p.setAttribute('data-y', '1');
              var tr = mo.takeRecords();
              window.__m12 = function () { return [tr.length, tr[0].target.id + '.' + tr[0].attributeName, tr[0].oldValue, n, mo.takeRecords().length].join('_'); };
              window.__m12mo = mo; })()
            """, "(function(){ window.__m12mo.disconnect(); return window.__m12() === '1_r15m12c.data-x__0_0'; })()"),
        ("MutationObserver: delivered as one microtask before later promises (m10)", """
            (function(){ var L = [], b = fx(''); window.__m10 = L;
              var mo = new MutationObserver(function (recs) { var t = ''; for (var k = 0; k < recs.length; k++) t += recs[k].type.charAt(0); L.push('mo' + recs.length + t); });
              mo.observe(b, { childList: true });
              var x = document.createElement('i'); b.appendChild(x); b.removeChild(x); L.push('sync');
              Promise.resolve().then(function () { L.push('p'); mo.disconnect(); }); })()
            """, "window.__m10.join('_') === 'sync_mo2cc_p'"),
        ("MutationObserver: childList records for fragments and innerHTML", """
            (function(){ var c = fx('<i></i>'), recs = []; window.__mcl = recs;
              var mo = new MutationObserver(function (r) { for (var k = 0; k < r.length; k++) recs.push(r[k]); });
              mo.observe(c, { childList: true });
              var f = document.createDocumentFragment(); f.append('a', document.createElement('b'), document.createElement('u'));
              c.appendChild(f); c.innerHTML = '<s></s>'; c.firstChild.remove(); window.__mclmo = mo; })()
            """, """
            (function(){ window.__mclmo.disconnect(); var r = window.__mcl;
              return r.length === 3 && r[0].addedNodes.length === 3 && r[0].previousSibling.nodeName === 'I' && r[0].nextSibling === null &&
                r[1].removedNodes.length === 4 && r[1].addedNodes.length === 1 && r[1].addedNodes[0].nodeName === 'S' &&
                r[2].removedNodes[0].nodeName === 'S' && r[0].oldValue === null; })()
            """),
        ("MutationObserver: transient registration sees a removed subtree until delivery", """
            (function(){ var d = fx('<div><p></p></div>'), p = d.querySelector('p'), got = []; window.__mtr = got;
              var mo = new MutationObserver(function (r) { for (var k = 0; k < r.length; k++) got.push(r[k].type + ':' + r[k].target.nodeName); });
              mo.observe(d, { subtree: true, attributes: true, childList: true });
              d.firstChild.removeChild(p); p.setAttribute('x', '1');
              Promise.resolve().then(function () { p.setAttribute('y', '1'); }); window.__mtrmo = mo; })()
            """, "(function(){ window.__mtrmo.disconnect(); return window.__mtr.join() === 'childList:DIV,attributes:P'; })()"),
        ("MutationObserver: observers called in creation order; disconnect; option errors", """
            (function(){ var L = [], c = fx(''); window.__mord = L;
              var A = new MutationObserver(function () { L.push('A'); }), B = new MutationObserver(function () { L.push('B'); }),
                  C = new MutationObserver(function () { L.push('C'); });
              B.observe(c, { attributes: true }); A.observe(c, { attributes: true }); C.observe(c, { attributes: true });
              c.setAttribute('q', '1'); C.disconnect();
              var errs = 0; [{}, { attributeOldValue: true, attributes: false }, { characterDataOldValue: true, characterData: false }].forEach(function (o) {
                try { A.observe(c, o); } catch (e) { if (e instanceof TypeError) errs++; } });
              try { A.observe({}, { attributes: true }); } catch (e) { if (e instanceof TypeError) errs++; }
              window.__mordErr = errs; window.__mordAB = [A, B]; })()
            """, """
            (function(){ window.__mordAB.forEach(function (m) { m.disconnect(); });
              return window.__mord.join('') === 'AB' && window.__mordErr === 4; })()
            """),
        ("MutationObserver: observe(document), characterData via textContent, attributeOldValue implies attributes", """
            (function(){ var L = []; window.__mdoc = L; var t = fx('x').firstChild;
              var mo = new MutationObserver(function (r) { for (var k = 0; k < r.length; k++) L.push(r[k].type + ':' + r[k].oldValue); });
              mo.observe(document, { subtree: true, characterDataOldValue: true, attributeOldValue: true });
              t.textContent = 'y'; t.parentNode.setAttribute('k', 'v'); window.__mdocmo = mo; })()
            """, "(function(){ window.__mdocmo.disconnect(); return window.__mdoc.join() === 'characterData:x,attributes:null'; })()"),
    ]

    /// Task cases: (name, setup, check); the check runs after queued
    /// `setTimeout(…, 0)` tasks had a chance to run.
    static let rung15TaskCases: [(String, String, String)] = [
        ("details: toggle is queued, non-bubbling, coalesced; .open and attribute (m20)", """
            (function(){ var d = fx('<details><summary>s</summary><div>c</div></details>').firstChild, L = [], bub = 0; window.__m20 = L;
              d.parentNode.addEventListener('toggle', function () { bub++; });
              d.addEventListener('toggle', function (e) { L.push(e.oldState + '>' + e.newState + (e instanceof ToggleEvent)); });
              d.open = true; d.open = false; d.open = true; L.push('sync' + L.length + d.open);
              var e = fx('<details open><summary>t</summary></details>').firstChild;
              e.addEventListener('toggle', function (ev) { L.push('attr:' + ev.newState); }); e.removeAttribute('open');
              var s = fx('<details><summary>u</summary></details>').firstChild; s.addEventListener('toggle', function () { L.push('summary'); });
              s.firstChild.click(); L.push('s' + s.open); window.__m20b = function () { return bub; }; })()
            """, "window.__m20.join() === 'sync0true,strue,closed>opentrue,attr:closed,summary' && window.__m20b() === 0"),
    ]

    mutating func testDOMBridgeRung15() {
        var outcomes: [(Bool, String)] = []
        var env: JeffJSEnvironment?
        func onMain(_ body: @escaping @MainActor () -> Void) {
            if Thread.isMainThread { MainActor.assumeIsolated { body() } } else { DispatchQueue.main.sync { MainActor.assumeIsolated { body() } } }
        }
        func waitForTasks() {
            if Thread.isMainThread {
                RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            } else {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        func record(_ result: JeffJSEvalResult, _ name: String) {
            switch result {
            case .success(let value): outcomes.append((value == "true", "DOMBridgeRung15: \(name) -> \(value ?? "undefined")"))
            case .exception(let message): outcomes.append((false, "DOMBridgeRung15: \(name) threw \(message)"))
            }
        }

        onMain {
            let e = JeffJSEnvironment()
            env = e
            _ = e.eval(JeffJSTestRunner.rung15Prelude, filename: "<rung15-prelude>")
            for (name, js) in JeffJSTestRunner.rung15SyncCases {
                record(e.eval(js, filename: "<rung15>"), name)
            }
            for (name, setup, check) in JeffJSTestRunner.rung15MicrotaskCases {
                if case .exception(let m) = e.eval(setup, filename: "<rung15-setup>") {
                    outcomes.append((false, "DOMBridgeRung15: \(name) setup threw \(m)"))
                    continue
                }
                record(e.eval(check, filename: "<rung15-check>"), name)
            }
            for (_, setup, _) in JeffJSTestRunner.rung15TaskCases {
                _ = e.eval(setup, filename: "<rung15-task-setup>")
            }
        }
        waitForTasks()
        onMain {
            guard let e = env else { return }
            for (name, _, check) in JeffJSTestRunner.rung15TaskCases {
                record(e.eval(check, filename: "<rung15-task-check>"), name)
            }

            // Autofocus runs as a task once parsing ends (readyState interactive).
            _ = e.eval("fx('<input id=\"r15af\" autofocus>'); document.activeElement.blur && document.activeElement.blur();",
                       filename: "<rung15-autofocus>")
            if let dom = e.domBridge, let doc = dom.documentJSValue {
                dom.setReadyState("interactive", on: doc, ctx: e.context)
            }
        }
        waitForTasks()
        onMain {
            guard let e = env, let dom = e.domBridge, let events = e.eventBridge else { return }
            record(e.eval("document.activeElement === document.getElementById('r15af')", filename: "<rung15-autofocus-check>"),
                   "autofocus focuses the first [autofocus] element after parsing")

            // Node lifetimes: an unreachable detached subtree is released with
            // its listeners; one still held keeps them (and its identity).
            dom.collectDetachedNodes()
            let wrappersBefore = dom.wrapperCount
            let listenersBefore = events.listenerTargetCount
            _ = e.eval("""
                (function(){ var host = fx('');
                  for (var i = 0; i < 300; i++) { var el = document.createElement('div'); el.dataset.k = 'v'; el.classList.add('c');
                    el.addEventListener('click', function () {}); el.appendChild(document.createElement('span'));
                    host.appendChild(el); if (i % 2) host.innerHTML = ''; else el.remove(); }
                  var kept = document.createElement('p'); window.__kept = kept; window.__keptN = 0;
                  kept.addEventListener('click', function () { window.__keptN++; }); host.appendChild(kept); kept.remove(); })()
                """, filename: "<rung15-lifetime>")
            dom.collectDetachedNodes()
            let wrappersAfter = dom.wrapperCount
            let listenersAfter = events.listenerTargetCount
            // 300 elements (+ spans, lists, datasets) were created and dropped;
            // only the fixture host and the kept <p> may remain.
            outcomes.append((wrappersAfter - wrappersBefore <= 4 && listenersAfter - listenersBefore == 1,
                             "DOMBridgeRung15: unreachable detached nodes are collected (wrappers \(wrappersBefore)->\(wrappersAfter), listener targets \(listenersBefore)->\(listenersAfter))"))
            record(e.eval("""
                (function(){ var h = fx(''); h.appendChild(window.__kept); window.__kept.dispatchEvent(new Event('click'));
                  return window.__keptN === 1 && h.firstChild === window.__kept; })()
                """, filename: "<rung15-lifetime-check>"), "a held detached node keeps its listeners through a sweep")
        }
        for (ok, message) in outcomes { assert(ok, message) }
    }
}
