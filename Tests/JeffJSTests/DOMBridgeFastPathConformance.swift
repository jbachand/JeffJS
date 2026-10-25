// DOMBridgeFastPathConformance.swift
// JeffJS — behaviour of the DOM bridge paths made cheaper for framework
// commits (DOMBridgeBenchTests measures them): DOMTokenList on a shared
// prototype, tree mutations without observers, character data and attribute
// writes. Each case checks what WebKit does.
//
// Usage:
//   swift test --filter DOMBridgeFastPathConformance

import XCTest
@testable import JeffJS

final class DOMBridgeFastPathConformance: XCTestCase {

    @JeffJSHostActor
    private func evalString(_ env: JeffJSEnvironment, _ js: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        switch env.eval(js) {
        case .success(let s): return s ?? "undefined"
        case .exception(let msg):
            XCTFail("JS threw: \(msg) — while evaluating: \(js)", file: file, line: line)
            return "<exception>"
        }
    }

    @JeffJSHostActor
    private func makeEnvironment() -> JeffJSEnvironment {
        JeffJSEnvironment(configuration: .init(viewportWidth: 390, viewportHeight: 844))
    }

    // MARK: - DOMTokenList

    @JeffJSHostActor
    func testTokenListMethodsLiveOnOneSharedPrototype() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var a = document.createElement('div'), b = document.createElement('a');
          a.className = 'x y';
          var p = Object.getPrototypeOf(a.classList);
          return [p === Object.getPrototypeOf(b.classList), p === Object.getPrototypeOf(b.relList),
                  a.classList === a.classList, a.classList.add === b.classList.add,
                  Object.getOwnPropertyNames(a.classList).join(','),
                  typeof p.add, typeof p.toggle, typeof p[Symbol.iterator],
                  Object.getOwnPropertyDescriptor(p, 'length').get !== undefined,
                  Object.prototype.propertyIsEnumerable.call(p, 'add')].join('|');
        })()
        """), "true|true|true|true|0,1|function|function|function|true|false")
    }

    @JeffJSHostActor
    func testTokenListFollowsTheAttribute() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          // Indices are refreshed by the classList getter and the methods
          // (not live between them: an own-property snapshot).
          var e = document.createElement('div'), cl = e.classList, out = [];
          e.setAttribute('class', '  a\\tb a ');
          out.push(cl.length, e.classList[0], cl[1], String(cl[2]), cl.value);
          cl.add('c', 'a'); out.push(e.getAttribute('class'));
          cl.remove('a'); out.push(e.className, cl.length, String(cl[2]));
          out.push(cl.toggle('b'), cl.toggle('z', true), cl.toggle('z', true), e.className);
          out.push(cl.replace('c', 'q'), cl.replace('nope', 'r'), e.className);
          out.push(cl.contains('q'), cl.contains('c'), cl.item(1), String(cl.item(5)));
          var it = []; for (var t of cl) it.push(t); out.push(it.join('+'));
          var fe = []; cl.forEach(function(t, i, l) { fe.push(i + t + (l === cl)); }); out.push(fe.join('+'));
          out.push(Array.from(cl.entries()).join('/'), Array.from(cl.keys()).join('/'));
          cl.value = 'm n'; out.push(e.getAttribute('class'), e.classList[1], String(cl));
          e.className = 'k'; out.push(e.classList[0], String(e.classList[1]), e.classList.length);
          return out.join('|');
        })()
        """), "2|a|b|undefined|  a\tb a |a b c|b c|2|undefined|false|true|true|c z|true|false|q z|true|false|z|null|q+z|0qtrue+1ztrue|0,q/1,z|0/1|m n|n|m n|k|undefined|1")
    }

    @JeffJSHostActor
    func testTokenListEmptySetCreatesNoAttribute() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var e = document.createElement('div');
          e.classList.remove('a');
          var r1 = e.hasAttribute('class');
          e.classList.toggle('a'); e.classList.toggle('a');
          return [r1, e.hasAttribute('class'), JSON.stringify(e.getAttribute('class'))].join('|');
        })()
        """), "false|true|\"\"")
    }

    @JeffJSHostActor
    func testTokenListValidationAndIllegalInvocation() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var e = document.createElement('div'), out = [];
          try { e.classList.add(''); } catch (x) { out.push(x.name); }
          try { e.classList.add('a b'); } catch (x) { out.push(x.name); }
          try { e.classList.replace('a'); } catch (x) { out.push(x.name); }
          var add = e.classList.add;
          try { add('x'); } catch (x) { out.push(x.name); }
          try { add.call({}, 'x'); } catch (x) { out.push(x.name); }
          add.call(document.createElement('p').classList, 'ok');
          out.push(e.hasAttribute('class'));
          return out.join('|');
        })()
        """), "SyntaxError|InvalidCharacterError|TypeError|TypeError|TypeError|false")
    }

    @JeffJSHostActor
    func testTokenListMutationsReachObservers() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var e = document.createElement('div'); document.body.appendChild(e);
          var mo = new MutationObserver(function() {});
          mo.observe(e, { attributes: true, attributeOldValue: true });
          e.classList.add('a'); e.classList.toggle('b'); e.relList.add('r');
          var rs = mo.takeRecords();
          return rs.map(function(r) { return r.attributeName + ':' + r.oldValue; }).join(',');
        })()
        """), "class:null,class:a,rel:null")
    }

    // MARK: - Tree mutations

    /// Removal and insertion records carry the right siblings whether or not
    /// the parent's sibling positions are current (the bridge reads them only
    /// while an observer is registered).
    @JeffJSHostActor
    func testChildListRecordSiblings() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var p = document.createElement('div'); document.body.appendChild(p);
          var k = []; for (var i = 0; i < 6; i++) { var c = document.createElement('i'); c.id = 'c' + i; p.appendChild(c); k.push(c); }
          var n = function(x) { return x ? x.id : '-'; };
          void k[3].nextSibling;   // stamp the positions
          var mo = new MutationObserver(function() {});
          mo.observe(p, { childList: true });
          p.removeChild(k[2]);                 // stamps stale after this
          p.insertBefore(k[2], k[5]);
          p.removeChild(k[0]);
          p.appendChild(k[0]);
          k[4].remove();
          p.insertBefore(k[4], k[1]);
          return mo.takeRecords().map(function(r) {
            return (r.addedNodes.length ? '+' + n(r.addedNodes[0]) : '-' + n(r.removedNodes[0])) +
                   '(' + n(r.previousSibling) + ',' + n(r.nextSibling) + ')';
          }).join(' ') + ' | ' + Array.prototype.map.call(p.childNodes, n).join('');
        })()
        """), "-c2(c1,c3) +c2(c4,c5) -c0(-,c1) +c0(c5,-) -c4(c3,c2) +c4(-,c1) | c4c1c3c2c5c0")
    }

    /// The same moves with no observer leave the same tree and sibling links.
    @JeffJSHostActor
    func testMovesWithoutObserversKeepTheTree() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var host = document.createElement('div'), p = document.createElement('div'), a = document.createElement('a');
          document.body.appendChild(host); p.appendChild(a);
          var els = []; for (var i = 0; i < 300; i++) { var e = document.createElement('b'); e.id = 'e' + i; host.appendChild(e); els.push(e); }
          for (var i = 0; i < 300; i += 3) { p.insertBefore(els[i], a); }
          for (var i = 0; i < 300; i += 6) { p.removeChild(els[i]); host.insertBefore(els[i], host.firstChild); }
          var ids = []; for (var n = host.firstChild; n; n = n.nextSibling) ids.push(n.id);
          var back = []; for (var n = host.lastChild; n; n = n.previousSibling) back.push(n.id);
          var pk = []; for (var n = p.firstChild; n; n = n.nextSibling) pk.push(n.id || n.tagName);
          return [host.childNodes.length, ids.slice(0, 3).join(','), ids[ids.length - 1],
                  back.reverse().join() === ids.join(), pk.length, pk[0], pk[pk.length - 1],
                  els[3].parentNode === p, els[6].parentNode === host, els[1].parentNode === host].join('|');
        })()
        """), "250|e294,e288,e282|e299|true|51|e3|A|true|true|true")
    }

    // MARK: - Character data

    @JeffJSHostActor
    func testWholeDataWrites() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var t = document.createTextNode('abé'), p = document.createElement('p');
          p.appendChild(t); document.body.appendChild(p);
          var mo = new MutationObserver(function() {});
          mo.observe(t, { characterData: true, characterDataOldValue: true });
          t.data = 'x😀y'; var l1 = t.length;
          t.nodeValue = null; var l2 = t.length;
          t.data = 42;
          t.textContent = 'z';
          t.replaceData(0, 0, 'q');
          return mo.takeRecords().map(function(r) { return JSON.stringify(r.oldValue); }).join(',') +
                 '|' + l1 + '|' + l2 + '|' + t.data + '|' + p.textContent;
        })()
        """), "\"ab\u{00e9}\",\"x\u{0001F600}y\",\"\",\"42\",\"z\"|4|0|qz|qz")
    }

    // MARK: - Node collection

    /// Collected nodes release their listeners whether or not other nodes
    /// still have some (the store skips the per-node key while no node has a
    /// listener), and a listener added later is found again.
    @JeffJSHostActor
    func testCollectionReleasesNodeListenersByCount() {
        let env = makeEnvironment()
        guard let dom = env.domBridge, let events = env.eventBridge else { return XCTFail("no bridges") }
        dom.collectDetachedNodes()
        let base = events.listenerTargetCount
        _ = evalString(env, """
        (function() {
          var f = function() {};
          var a = document.createElement('div'); a.addEventListener('x', f); a.removeEventListener('x', f);
          for (var i = 0; i < 50; i++) document.createElement('b');
          window.__h = document.createElement('i'); window.__h.addEventListener('x', function() { window.__n = (window.__n || 0) + 1; });
          for (var i = 0; i < 50; i++) { var e = document.createElement('u'); e.addEventListener('x', f); }
        })()
        """)
        dom.collectDetachedNodes()
        XCTAssertEqual(events.listenerTargetCount - base, 1)
        XCTAssertEqual(evalString(env, "window.__h.dispatchEvent(new Event('x')); String(window.__n)"), "1")
        _ = evalString(env, "window.__h = null")
        dom.collectDetachedNodes()
        XCTAssertEqual(events.listenerTargetCount, base)
    }

    /// A wrapper's interface prototype is chosen by the element's
    /// ASCII-lowercase tag name.
    @JeffJSHostActor
    func testInterfacePrototypeByLowercaseTag() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var EP = Object.getPrototypeOf(document.createElement('div'));
          var D = Object.create(EP), U = Object.create(EP);
          __rnSetNodeInterfaces({ div: D }, U, null, null);
          return [Object.getPrototypeOf(document.createElement('DiV')) === D,
                  Object.getPrototypeOf(document.createElement('blink')) === U,
                  Object.getPrototypeOf(document.createElement('x-y')) === EP].join();
        })()
        """), "true,true,true")
    }
}
