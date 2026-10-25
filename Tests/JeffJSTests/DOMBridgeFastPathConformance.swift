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
}
