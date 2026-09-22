// DOMEventConformance.swift
// JeffJS — conformance group "DOMEvents": the DOM EventTarget interface on
// window, document, elements and the polyfill targets (AbortSignal,
// XMLHttpRequest, MediaQueryList, MessagePort), plus Event / CustomEvent.
//
// Runs inside EngineTests/testConformance. The DOM bridges are main-actor
// bound, so the group builds a JeffJSEnvironment on the main thread (the
// conformance thread waits on it; XCTest's wait spins the main run loop).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    /// (name, JS expression that must evaluate to `true`).
    static let domEventCases: [(String, String)] = [
        // The spec-ladder defect: document had add/removeEventListener but no dispatchEvent.
        ("document.dispatchEvent (minimal repro)", """
            (function(){ var hit = 0; document.addEventListener('x', function(){ hit++; });
              var r = document.dispatchEvent(new Event('x')); return hit === 1 && r === true; })()
            """),
        ("one EventTarget for window, document, elements", """
            (function(){ var d = document.createElement('div'); var P = EventTarget.prototype;
              return window.addEventListener === P.addEventListener && window.dispatchEvent === P.dispatchEvent &&
                document.dispatchEvent === P.dispatchEvent && document.removeEventListener === P.removeEventListener &&
                d.addEventListener === P.addEventListener && d.dispatchEvent === P.dispatchEvent &&
                d instanceof EventTarget && document instanceof EventTarget; })()
            """),
        ("element event bubbles to document then window", """
            (function(){ var log = []; var d = document.createElement('div'); document.body.appendChild(d);
              var f = function(e){ log.push('d' + e.eventPhase + (e.currentTarget === document) + (e.target === d)); };
              var w = function(e){ log.push('w' + e.eventPhase + (e.currentTarget === window)); };
              document.addEventListener('bub', f); window.addEventListener('bub', w);
              d.dispatchEvent(new Event('bub', { bubbles: true }));
              document.removeEventListener('bub', f); window.removeEventListener('bub', w);
              return log.join() === 'd3truetrue,w3true'; })()
            """),
        ("non-bubbling event stays at target", """
            (function(){ var n = 0; var d = document.createElement('div'); document.body.appendChild(d);
              var f = function(){ n++; }; document.addEventListener('nb', f); window.addEventListener('nb', f);
              d.dispatchEvent(new Event('nb'));
              document.removeEventListener('nb', f); window.removeEventListener('nb', f); return n === 0; })()
            """),
        ("capture window>document>html>body>target, then bubble back", """
            (function(){ var log = []; var d = document.createElement('div'); document.body.appendChild(d);
              var ts = [[window,'w'],[document,'d'],[document.documentElement,'h'],[document.body,'b'],[d,'t']], fs = [];
              ts.forEach(function(p){
                var c = function(e){ log.push(p[1] + 'c' + e.eventPhase); }, b = function(e){ log.push(p[1] + 'b' + e.eventPhase); };
                fs.push([p[0], c, b]); p[0].addEventListener('ord', c, true); p[0].addEventListener('ord', b); });
              d.dispatchEvent(new Event('ord', { bubbles: true }));
              fs.forEach(function(x){ x[0].removeEventListener('ord', x[1], true); x[0].removeEventListener('ord', x[2]); });
              return log.join(' ') === 'wc1 dc1 hc1 bc1 tc2 tb2 bb3 hb3 db3 wb3'; })()
            """),
        ("document target: capture on window, bubble to window", """
            (function(){ var log = []; var c = function(e){ log.push('c' + e.eventPhase); }, b = function(e){ log.push('b' + e.eventPhase); },
              t = function(e){ log.push('t' + e.eventPhase); };
              window.addEventListener('dt', c, true); window.addEventListener('dt', b); document.addEventListener('dt', t);
              document.dispatchEvent(new Event('dt', { bubbles: true }));
              window.removeEventListener('dt', c, true); window.removeEventListener('dt', b); document.removeEventListener('dt', t);
              return log.join() === 'c1,t2,b3'; })()
            """),
        ("window target path is [window]", """
            (function(){ var n = 0, p; var f = function(e){ n++; p = e.composedPath(); };
              document.addEventListener('wd', f); window.addEventListener('wd', f);
              window.dispatchEvent(new Event('wd', { bubbles: true }));
              document.removeEventListener('wd', f); window.removeEventListener('wd', f);
              return n === 1 && p.length === 1 && p[0] === window; })()
            """),
        ("detached subtree does not reach document", """
            (function(){ var n = 0; var p = document.createElement('div'), c = document.createElement('span'); p.appendChild(c);
              var f = function(){ n += 10; }, g = function(){ n++; };
              document.addEventListener('det', f); p.addEventListener('det', g);
              c.dispatchEvent(new Event('det', { bubbles: true })); document.removeEventListener('det', f); return n === 1; })()
            """),
        ("composedPath during dispatch, empty after", """
            (function(){ var d = document.createElement('span'); document.body.appendChild(d); var p = null;
              d.addEventListener('cp', function(e){ p = e.composedPath(); }); var ev = new Event('cp'); d.dispatchEvent(ev);
              return p.length === 5 && p[0] === d && p[1] === document.body && p[2] === document.documentElement &&
                p[3] === document && p[4] === window && ev.composedPath().length === 0; })()
            """),
        ("target/currentTarget/eventPhase during and after dispatch", """
            (function(){ var d = document.createElement('p'), s; var ev = new Event('z');
              d.addEventListener('z', function(e){ s = [e.target === d, e.currentTarget === d, e.eventPhase === 2, this === d]; });
              d.dispatchEvent(ev);
              return s.join() === 'true,true,true,true' && ev.target === d && ev.currentTarget === null && ev.eventPhase === 0; })()
            """),
        ("stopPropagation finishes the current target, stops the path", """
            (function(){ var n = 0; var d = document.createElement('div'); document.body.appendChild(d); var f = function(){ n += 100; };
              d.addEventListener('sp', function(e){ e.stopPropagation(); }); d.addEventListener('sp', function(){ n += 1; });
              document.addEventListener('sp', f); d.dispatchEvent(new Event('sp', { bubbles: true }));
              document.removeEventListener('sp', f); return n === 1; })()
            """),
        ("stopPropagation in a capture listener stops the target", """
            (function(){ var n = 0; var d = document.createElement('div'); document.body.appendChild(d);
              var f = function(e){ e.stopPropagation(); }; document.addEventListener('spc', f, true);
              d.addEventListener('spc', function(){ n++; }); d.dispatchEvent(new Event('spc', { bubbles: true }));
              document.removeEventListener('spc', f, true); return n === 0; })()
            """),
        ("stopImmediatePropagation", """
            (function(){ var n = 0; var d = document.createElement('div');
              d.addEventListener('si', function(e){ n++; e.stopImmediatePropagation(); }); d.addEventListener('si', function(){ n += 10; });
              d.dispatchEvent(new Event('si')); return n === 1; })()
            """),
        ("stop flags cleared after dispatch (re-dispatch works)", """
            (function(){ var n = 0; var d = document.createElement('div'); d.addEventListener('rd', function(e){ n++; e.stopPropagation(); });
              var ev = new Event('rd'); d.dispatchEvent(ev); d.dispatchEvent(ev); return n === 2 && ev.cancelBubble === false; })()
            """),
        ("preventDefault on cancelable: dispatchEvent returns false", """
            (function(){ var d = document.createElement('div'); d.addEventListener('pd', function(e){ e.preventDefault(); });
              var ev = new Event('pd', { cancelable: true }); return d.dispatchEvent(ev) === false && ev.defaultPrevented === true; })()
            """),
        ("preventDefault on non-cancelable is ignored", """
            (function(){ var d = document.createElement('div'); d.addEventListener('pd2', function(e){ e.preventDefault(); });
              var ev = new Event('pd2'); return d.dispatchEvent(ev) === true && ev.defaultPrevented === false; })()
            """),
        ("passive listener cannot cancel", """
            (function(){ var d = document.createElement('div'), seen;
              d.addEventListener('ps', function(e){ e.preventDefault(); seen = e.defaultPrevented; }, { passive: true });
              var ev = new Event('ps', { cancelable: true });
              return d.dispatchEvent(ev) === true && ev.defaultPrevented === false && seen === false; })()
            """),
        ("once", """
            (function(){ var n = 0; var d = document.createElement('div'); d.addEventListener('o', function(){ n++; }, { once: true });
              d.dispatchEvent(new Event('o')); d.dispatchEvent(new Event('o')); return n === 1; })()
            """),
        ("once listener re-registering itself", """
            (function(){ var n = 0; var d = document.createElement('div');
              var f = function(){ n++; if (n < 3) d.addEventListener('o2', f, { once: true }); };
              d.addEventListener('o2', f, { once: true });
              for (var i = 0; i < 4; i++) d.dispatchEvent(new Event('o2')); return n === 3; })()
            """),
        ("same type/callback/capture registers once", """
            (function(){ var n = 0; var d = document.createElement('div'); var f = function(){ n++; };
              d.addEventListener('dd', f); d.addEventListener('dd', f); d.addEventListener('dd', f, false);
              d.addEventListener('dd', f, { capture: false, once: true }); d.dispatchEvent(new Event('dd'));
              d.dispatchEvent(new Event('dd')); return n === 2; })()
            """),
        ("capture is part of listener identity", """
            (function(){ var n = 0; var d = document.createElement('div'); var f = function(){ n++; };
              d.addEventListener('cf', f); d.addEventListener('cf', f, true); d.dispatchEvent(new Event('cf'));
              d.removeEventListener('cf', f); d.dispatchEvent(new Event('cf'));
              d.removeEventListener('cf', f, { capture: true }); d.dispatchEvent(new Event('cf')); return n === 3; })()
            """),
        ("handleEvent object listener", """
            (function(){ var d = document.createElement('div');
              var o = { n: 0, handleEvent: function(e){ this.n++; this.t = e.type; this.self = this === o; } };
              d.addEventListener('he', o); d.addEventListener('he', o); d.dispatchEvent(new Event('he'));
              d.removeEventListener('he', o); d.dispatchEvent(new Event('he')); return o.n === 1 && o.t === 'he' && o.self; })()
            """),
        ("signal option removes the listener on abort", """
            (function(){ var n = 0; var ac = new AbortController(); var d = document.createElement('div'); var f = function(){ n++; };
              d.addEventListener('sg', f, { signal: ac.signal }); d.dispatchEvent(new Event('sg')); ac.abort();
              d.dispatchEvent(new Event('sg')); d.addEventListener('sg', f); d.dispatchEvent(new Event('sg')); return n === 2; })()
            """),
        ("already-aborted signal adds nothing", """
            (function(){ var n = 0; var ac = new AbortController(); ac.abort(); var d = document.createElement('div');
              d.addEventListener('sg2', function(){ n++; }, { signal: ac.signal }); d.dispatchEvent(new Event('sg2')); return n === 0; })()
            """),
        ("listener removed mid-dispatch does not run", """
            (function(){ var n = 0; var d = document.createElement('div'); var g = function(){ n += 10; };
              d.addEventListener('rm', function(){ n++; d.removeEventListener('rm', g); }); d.addEventListener('rm', g);
              d.dispatchEvent(new Event('rm')); return n === 1; })()
            """),
        ("listener added mid-dispatch to the same target does not run", """
            (function(){ var n = 0; var d = document.createElement('div');
              d.addEventListener('ad', function(){ n++; d.addEventListener('ad', function(){ n += 10; }); });
              d.dispatchEvent(new Event('ad')); return n === 1; })()
            """),
        ("a throwing listener does not stop the others", """
            (function(){ var n = 0; var d = document.createElement('div');
              d.addEventListener('ex', function(){ throw new Error('boom'); }); d.addEventListener('ex', function(){ n++; });
              d.dispatchEvent(new Event('ex')); return n === 1; })()
            """),
        ("on<type> handler attribute runs", """
            (function(){ var d = document.createElement('div'), n = 0; d.onclick = function(e){ n += (this === d && e.type === 'click') ? 1 : 100; };
              d.dispatchEvent(new Event('click')); return n === 1; })()
            """),
        ("script events: isTrusted false, timeStamp, defaults, constants", """
            (function(){ var e = new Event('q'); return e.isTrusted === false && typeof e.timeStamp === 'number' &&
              e.eventPhase === 0 && e.bubbles === false && e.cancelable === false && e.defaultPrevented === false &&
              Event.NONE === 0 && Event.CAPTURING_PHASE === 1 && Event.AT_TARGET === 2 && e.BUBBLING_PHASE === 3; })()
            """),
        ("Event init dictionary", """
            (function(){ var e = new Event('q', { bubbles: true, cancelable: true, composed: true });
              return e.type === 'q' && e.bubbles && e.cancelable && e.composed; })()
            """),
        ("new Event() without a type throws TypeError", """
            (function(){ try { new Event(); return false; } catch (e) { return e instanceof TypeError; } })()
            """),
        ("CustomEvent detail", """
            (function(){ var got; var d = document.createElement('div'); d.addEventListener('ce', function(e){ got = e.detail; });
              var e = new CustomEvent('ce', { detail: { a: 1 } }); d.dispatchEvent(e);
              return got.a === 1 && e instanceof Event && e instanceof CustomEvent && new CustomEvent('x').detail === null; })()
            """),
        ("initEvent", """
            (function(){ var e = new Event(''); e.initEvent('ie', true, true); var d = document.createElement('div'), n = 0;
              d.addEventListener('ie', function(ev){ n++; ev.preventDefault(); }); return d.dispatchEvent(e) === false && n === 1 && e.bubbles; })()
            """),
        ("dispatchEvent argument checks", """
            (function(){ var a, b, c;
              try { document.dispatchEvent({}); } catch (e) { a = e instanceof TypeError; }
              try { document.dispatchEvent(); } catch (e) { b = e instanceof TypeError; }
              try { document.addEventListener('x'); } catch (e) { c = e instanceof TypeError; }
              document.addEventListener('x', null); return a && b && c; })()
            """),
        ("re-dispatching an event mid-dispatch throws InvalidStateError", """
            (function(){ var d = document.createElement('div'), name;
              d.addEventListener('rr', function(e){ try { d.dispatchEvent(e); } catch (x) { name = x.name; } });
              d.dispatchEvent(new Event('rr')); return name === 'InvalidStateError'; })()
            """),
        ("new EventTarget() and subclasses", """
            (function(){ var et = new EventTarget(), n = 0;
              et.addEventListener('a', function(e){ n += (e.target === et && e.currentTarget === et) ? 1 : 100; });
              class Foo extends EventTarget { constructor(){ super(); this.x = 1; } }
              var f = new Foo(); f.addEventListener('b', function(){ n += 10; }); f.dispatchEvent(new Event('b'));
              return et.dispatchEvent(new Event('a', { bubbles: true })) === true && n === 11 &&
                f instanceof EventTarget && Object.keys(et).length === 0; })()
            """),
        ("a plain EventTarget does not bubble to window", """
            (function(){ var et = new EventTarget(), n = 0; var w = function(){ n++; };
              window.addEventListener('nb2', w); et.dispatchEvent(new Event('nb2', { bubbles: true }));
              window.removeEventListener('nb2', w); return n === 0; })()
            """),
        ("bare addEventListener/dispatchEvent target window", """
            (function(){ var n = 0; var f = function(){ n++; }; addEventListener('bare', f); dispatchEvent(new Event('bare'));
              removeEventListener('bare', f); dispatchEvent(new Event('bare')); return n === 1; })()
            """),
        ("DOMContentLoaded at document reaches document then window", """
            (function(){ var log = []; var a = function(){ log.push('d'); }, b = function(){ log.push('w'); };
              document.addEventListener('DOMContentLoaded', a); window.addEventListener('DOMContentLoaded', b);
              document.dispatchEvent(new Event('DOMContentLoaded', { bubbles: true }));
              document.removeEventListener('DOMContentLoaded', a); window.removeEventListener('DOMContentLoaded', b);
              return log.join() === 'd,w'; })()
            """),
        ("AbortSignal is an EventTarget (onabort + listeners)", """
            (function(){ var ac = new AbortController(), n = 0;
              ac.signal.onabort = function(e){ n += e.type === 'abort' ? 1 : 100; };
              ac.signal.addEventListener('abort', function(){ n += 10; }); ac.abort(); ac.abort();
              return n === 11 && ac.signal.aborted && ac.signal instanceof EventTarget; })()
            """),
        ("MediaQueryList is an EventTarget", """
            (function(){ var m = matchMedia('(min-width: 1px)'), n = 0; var f = function(){ n++; };
              m.addListener(f); m.addEventListener('change', f); m.onchange = function(){ n += 10; };
              m.dispatchEvent(new Event('change')); return n === 11 && m instanceof EventTarget; })()
            """),
        ("XMLHttpRequest is an EventTarget", """
            (function(){ var x = new XMLHttpRequest(), n = 0; x.addEventListener('readystatechange', function(){ n++; });
              x.onreadystatechange = function(){ n += 10; }; x.open('GET', 'about:blank');
              return n === 11 && x instanceof EventTarget && x.readyState === 1; })()
            """),
        ("MessagePort is an EventTarget", """
            (function(){ var mc = new MessageChannel(), n = 0; mc.port1.addEventListener('message', function(){ n++; });
              mc.port1.onmessage = function(){ n += 10; }; mc.port1.dispatchEvent(new Event('message'));
              return n === 11 && mc.port1 instanceof EventTarget; })()
            """),
        ("native bridge: trusted event bubbles from element to document", """
            (function(){ var d = document.createElement('div'); document.body.appendChild(d); var n = 0, tr;
              var f = function(e){ n++; tr = e.isTrusted; e.preventDefault(); }; document.addEventListener('click', f);
              var r = __nativeEventBridge.dispatchEventByName(d, 'click'); document.removeEventListener('click', f);
              return n === 1 && tr === true && r === false; })()
            """),
        ("native bridge: dispatchEvent(target, event) and click sequence", """
            (function(){ var d = document.createElement('div'); document.body.appendChild(d); var log = [];
              ['mousedown', 'mouseup', 'click'].forEach(function(t){ d.addEventListener(t, function(){ log.push(t); }); });
              __nativeEventBridge.dispatchClickSequence(d);
              var n = 0; var g = function(){ n++; }; __nativeEventBridge.addEventListener(document, 'lc', g, false);
              __nativeEventBridge.dispatchEvent(document, new Event('lc'));
              __nativeEventBridge.removeEventListener(document, 'lc', g, false); document.dispatchEvent(new Event('lc'));
              return log.join() === 'mousedown,mouseup,click' && n === 1; })()
            """),
    ]

    mutating func testDOMEvents() {
        var outcomes: [(Bool, String)] = []
        let run = {
            MainActor.assumeIsolated {
                let env = JeffJSEnvironment()
                for (name, js) in JeffJSTestRunner.domEventCases {
                    switch env.eval(js, filename: "<dom-events>") {
                    case .success(let value):
                        outcomes.append((value == "true", "DOMEvents: \(name) -> \(value ?? "undefined")"))
                    case .exception(let message):
                        outcomes.append((false, "DOMEvents: \(name) threw \(message)"))
                    }
                }
            }
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.sync(execute: run) }
        for (ok, message) in outcomes { assert(ok, message) }
    }
}
