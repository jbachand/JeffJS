// ShadowDOMConformance.swift
// JeffJS — conformance group "ShadowDOM" (DOM §4.2.2 shadow trees, §4.2.2.3-4
// slots, §4.8 Element.attachShadow/shadowRoot, §4.4 getRootNode, §4.3 subtree
// observers, HTML §4.13.6 custom element reaction hook). Shadow roots were the
// app's JS polyfill: a plain object whose children were detached nodes the
// renderer never saw, `getRootNode()` could not return it, `isConnected` was
// false inside it, slots returned their fallback. Now a shadow root is a real
// DocumentFragment node (`DOMNode+Shadow.swift`) whose stored parent is its host.

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let shadowDOMCases: [(String, String)] = [
        ("attachShadow returns a ShadowRoot fragment; open roots are exposed, closed ones are not",
         #"(function(){ var a = document.createElement('div'), b = document.createElement('x-c'); var sa = a.attachShadow({ mode: 'open' }), sb = b.attachShadow({ mode: 'closed' }); return sa instanceof ShadowRoot && sa.nodeType === 11 && sa.nodeName === '#document-fragment' && sa.host === a && sa.mode === 'open' && a.shadowRoot === sa && b.shadowRoot === null && sb.mode === 'closed' && sb.host === b && sa.parentNode === null && sa.parentElement === null && sa.delegatesFocus === false && sa.slotAssignment === 'named'; })()"#),
        ("attachShadow validates the host and the mode, and refuses a second root",
         #"(function(){ function t(f, name){ try { f(); return false; } catch (e) { return name ? e.name === name : e instanceof TypeError; } } var d = document.createElement('div'); d.attachShadow({ mode: 'open' }); return t(function(){ document.createElement('img').attachShadow({ mode: 'open' }); }, 'NotSupportedError') && t(function(){ document.createElement('div').attachShadow({ mode: 'x' }); }) && t(function(){ document.createElement('div').attachShadow({}); }) && t(function(){ d.attachShadow({ mode: 'open' }); }, 'NotSupportedError') && !!document.createElement('span').attachShadow({ mode: 'open', delegatesFocus: true }).delegatesFocus; })()"#),
        ("shadow children: innerHTML, getRootNode, isConnected, contains, getElementById",
         #"(function(){ var h = document.createElement('div'); document.body.appendChild(h); var r = h.attachShadow({ mode: 'open' }); r.innerHTML = '<p id=in><b>x</b></p>'; var p = r.firstChild, b = p.firstChild; var ok = p.parentNode === r && b.getRootNode() === r && b.getRootNode({ composed: true }) === document && b.isConnected && r.isConnected && !document.contains(b) && r.contains(b) && !h.contains(b) && r.getElementById('in') === p && document.getElementById('in') === null && document.querySelector('#in') === null && h.querySelector('b') === null && r.querySelector('b') === b && h.childNodes.length === 0 && h.innerHTML === '' && r.innerHTML === '<p id=\"in\"><b>x</b></p>'; h.remove(); return ok && !b.isConnected; })()"#),
        ("closest and selectors do not cross the shadow boundary",
         #"(function(){ var h = document.createElement('div'); h.className = 'outer'; document.body.appendChild(h); var r = h.attachShadow({ mode: 'open' }); r.innerHTML = '<section><i></i></section>'; var i = r.querySelector('i'); var ok = i.closest('.outer') === null && i.closest('section') === r.firstChild && !i.matches('.outer i') && i.matches('section i') && !i.matches('div i') && r.querySelectorAll('div i').length === 0; h.remove(); return ok; })()"#),
        ("named slot assignment: first slot per name, default slot takes text and unnamed elements",
         #"(function(){ var h = document.createElement('div'); h.innerHTML = '<span slot=a>A</span>t<b>B</b><i slot=zz>Z</i>'; var r = h.attachShadow({ mode: 'open' }); r.innerHTML = '<slot name=a></slot><slot></slot><slot name=a id=second></slot>'; var sa = r.firstChild, sd = sa.nextSibling, s2 = r.getElementById('second'); var an = sd.assignedNodes(); return sa.assignedNodes().length === 1 && sa.assignedNodes()[0] === h.firstChild && an.length === 2 && an[0].nodeType === 3 && an[1].tagName === 'B' && sd.assignedElements().length === 1 && s2.assignedNodes().length === 0 && h.firstChild.assignedSlot === sa && h.querySelector('i').assignedSlot === null; })()"#),
        ("assignment follows mutations: slot attribute, slot name, new light children, removed slots",
         #"(function(){ var h = document.createElement('div'); h.innerHTML = '<span>x</span>'; var r = h.attachShadow({ mode: 'open' }); r.innerHTML = '<slot name=n></slot><slot></slot>'; var sn = r.firstChild, sd = r.lastChild, sp = h.firstChild; var a = sd.assignedNodes().length === 1 && sn.assignedNodes().length === 0; sp.setAttribute('slot', 'n'); var b = sn.assignedNodes()[0] === sp && sd.assignedNodes().length === 0; sn.setAttribute('name', 'm'); var c = sn.assignedNodes().length === 0; h.appendChild(document.createElement('em')); var d = sd.assignedNodes().length === 1; sd.remove(); var e = h.lastChild.assignedSlot === null; return a && b && c && d && e; })()"#),
        ("flattened assigned nodes through nested slots, fallback content",
         #"(function(){ var outer = document.createElement('div'); outer.innerHTML = '<x-in><slot></slot></x-in>'; var inner = outer.firstChild; var ri = inner.attachShadow({ mode: 'open' }); ri.innerHTML = '<slot><em>fallback</em></slot>'; var innerSlot = ri.firstChild; var ro = outer.attachShadow({ mode: 'open' }); ro.appendChild(inner); outer.appendChild(document.createElement('u')); var fl = innerSlot.assignedNodes({ flatten: true }); var empty = document.createElement('div').attachShadow({ mode: 'open' }); empty.innerHTML = '<slot><b>fb</b></slot>'; return innerSlot.assignedNodes().length === 1 && innerSlot.assignedNodes()[0].tagName === 'SLOT' && fl.length === 1 && fl[0].tagName === 'U' && empty.firstChild.assignedNodes().length === 0 && empty.firstChild.assignedNodes({ flatten: true })[0].tagName === 'B'; })()"#),
        ("manual slot assignment with slot.assign()",
         #"(function(){ var h = document.createElement('div'); h.innerHTML = '<p>1</p><p slot=x>2</p>'; var r = h.attachShadow({ mode: 'open', slotAssignment: 'manual' }); r.innerHTML = '<slot></slot><slot></slot>'; var s1 = r.firstChild, s2 = r.lastChild; var before = s1.assignedNodes().length === 0; s1.assign(h.lastChild); s2.assign(h.lastChild, h.firstChild); return r.slotAssignment === 'manual' && before && s1.assignedNodes().length === 0 && s2.assignedNodes().length === 2 && s2.assignedNodes()[0] === h.lastChild; })()"#),
        ("slotchange fires (bubbling, in a microtask) when a slot's assigned nodes change",
         #"(async function(){ var h = document.createElement('div'); document.body.appendChild(h); var r = h.attachShadow({ mode: 'open' }); r.innerHTML = '<slot></slot>'; var log = []; r.addEventListener('slotchange', function(e){ log.push(e.target.tagName + ':' + e.bubbles); }); await 0; log.length = 0; h.appendChild(document.createElement('b')); var sync = log.length; await 0; await 0; h.remove(); return sync === 0 && log.join() === 'SLOT:true'; })()"#),
        ("a subtree MutationObserver on the document does not see shadow tree mutations",
         #"(async function(){ var h = document.createElement('div'); document.body.appendChild(h); var r = h.attachShadow({ mode: 'open' }); var recs = []; var mo = new MutationObserver(function(l){ recs = recs.concat(l); }); mo.observe(document.body, { childList: true, subtree: true, attributes: true }); r.appendChild(document.createElement('i')); r.firstChild.setAttribute('x', '1'); var mo2 = new MutationObserver(function(){}); mo2.observe(r, { childList: true, subtree: true }); r.firstChild.appendChild(document.createElement('b')); var own = mo2.takeRecords().length; await 0; mo.disconnect(); mo2.disconnect(); h.remove(); return recs.length === 0 && own === 1; })()"#),
        ("the event path crosses the shadow root to the host",
         #"(function(){ var h = document.createElement('div'); document.body.appendChild(h); var r = h.attachShadow({ mode: 'open' }); r.innerHTML = '<button>b</button>'; var seen = []; h.addEventListener('ping', function(){ seen.push('host'); }); r.addEventListener('ping', function(){ seen.push('root'); }); r.firstChild.dispatchEvent(new Event('ping', { bubbles: true, composed: true })); h.remove(); return seen.join() === 'root,host'; })()"#),
        ("inserting a host into its own shadow tree is a HierarchyRequestError",
         #"(function(){ var h = document.createElement('div'); var r = h.attachShadow({ mode: 'open' }); var threw = false; try { r.appendChild(h); } catch (e) { threw = e.name === 'HierarchyRequestError'; } return threw && r.childNodes.length === 0; })()"#),
        ("custom element reaction hook: connected / disconnected / attribute, in shadow-including tree order (host, its shadow tree, then its children)",
         #"(function(){ var log = []; document.__rnSetCEHook(function(kind, a, name, o, v){ if (kind === 'attribute') log.push('attr:' + a.localName + ':' + name + ':' + o + '>' + v); else log.push(kind + ':' + Array.prototype.map.call(a, function(e){ return e.localName; }).join('+')); }); var w = document.createElement('div'); w.innerHTML = '<x-a><x-b></x-b></x-a>'; var sr = w.firstChild.attachShadow({ mode: 'open' }); sr.innerHTML = '<x-s></x-s>'; document.body.appendChild(w); w.firstChild.setAttribute('k', '1'); w.remove(); document.createElement('x-d').setAttribute('q', '2'); document.__rnSetCEHook(null); document.body.appendChild(document.createElement('x-e')); return log.join(' ') === 'connected:x-a+x-s+x-b attr:x-a:k:null>1 disconnected:x-a+x-s+x-b attr:x-d:q:null>2'; })()"#),
    ]

    mutating func testShadowDOM() {
        var outcomes: [(Bool, String)] = []
        func onMain(_ body: @escaping @MainActor () -> Void) {
            if Thread.isMainThread { MainActor.assumeIsolated { body() } } else { DispatchQueue.main.sync { MainActor.assumeIsolated { body() } } }
        }
        onMain {
            let e = JeffJSEnvironment()
            for (name, js) in JeffJSTestRunner.shadowDOMCases {
                let isAsync = js.hasPrefix("(async")
                let src = isAsync ? "globalThis.__sdr = 'pending'; " + js + ".then(function(v){ globalThis.__sdr = String(v); }, function(e){ globalThis.__sdr = 'threw ' + e; }); 0" : js
                switch e.eval(src, filename: "<shadow-dom>") {
                case .success(let v):
                    if isAsync {
                        e.drainJobs()
                        let r = e.eval("globalThis.__sdr", filename: "<shadow-dom>")
                        if case .success(let rv) = r { outcomes.append((rv == "true", "ShadowDOM: \(name) -> \(rv ?? "undefined")")) }
                        else { outcomes.append((false, "ShadowDOM: \(name) no result")) }
                    } else {
                        outcomes.append((v == "true", "ShadowDOM: \(name) -> \(v ?? "undefined")"))
                    }
                case .exception(let m): outcomes.append((false, "ShadowDOM: \(name) threw \(m)"))
                }
            }
        }
        for (ok, message) in outcomes { assert(ok, message) }
    }
}
