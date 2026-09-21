// DOMAPITests.swift
// JeffJS — the DOM surface real sites reach for beyond the core tree:
// document.implementation / detached documents, <template>.content, classList,
// insertAdjacent*, closest/matches, compareDocumentPosition, NodeList shape.
//
// Usage:
//   swift test --filter DOMAPITests

import XCTest
@testable import JeffJS

final class DOMAPITests: XCTestCase {

    // MARK: - Helpers

    @MainActor
    private func evalString(_ env: JeffJSEnvironment, _ js: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        switch env.eval(js) {
        case .success(let s): return s ?? "undefined"
        case .exception(let msg):
            XCTFail("JS threw: \(msg) — while evaluating: \(js)", file: file, line: line)
            return "<exception>"
        }
    }

    @MainActor
    private func makeEnvironment() -> JeffJSEnvironment {
        let env = JeffJSEnvironment(configuration: .init(viewportWidth: 390, viewportHeight: 844))
        _ = evalString(env, """
        document.body.innerHTML =
          '<div id="root" class="a b" data-foo="1">' +
            '<span class="x">hello</span><span class="y">world</span>' +
          '</div>';
        """)
        return env
    }

    // MARK: - document.implementation

    @MainActor
    func testCreateHTMLDocumentProducesRealDocument() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, "typeof document.implementation.createHTMLDocument"), "function")
        XCTAssertEqual(evalString(env, "document.implementation.createHTMLDocument('T').title"), "T")
        XCTAssertEqual(evalString(env, "String(document.implementation.createHTMLDocument('').nodeType)"), "9")
        XCTAssertEqual(evalString(env, """
        (function() {
          var d = document.implementation.createHTMLDocument('');
          return [!!d.body, !!d.head, !!d.documentElement].join(',');
        })()
        """), "true,true,true")
    }

    /// jQuery 3's `support.createHTMLDocument` probe: two sibling <form>s must
    /// survive as two children of the created document's body.
    @MainActor
    func testCreateHTMLDocumentSupportsFormProbe() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var body = document.implementation.createHTMLDocument('').body;
          body.innerHTML = '<form></form><form></form>';
          return String(body.childNodes.length);
        })()
        """), "2")
    }

    /// The rest of jQuery.parseHTML: a <base> appended to the created head, then
    /// a fragment built from that document.
    @MainActor
    func testCreateHTMLDocumentParseHTMLContext() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var ctxDoc = document.implementation.createHTMLDocument('');
          var base = ctxDoc.createElement('base');
          base.href = 'https://example.com/a/b';
          ctxDoc.head.appendChild(base);
          var frag = ctxDoc.createDocumentFragment();
          var tmp = frag.appendChild(ctxDoc.createElement('div'));
          tmp.innerHTML = '<p class="pp">x</p><p class="pp">y</p>';
          return [ctxDoc.head.childNodes.length,
                  frag.querySelectorAll('p.pp').length,
                  base.getAttribute('href')].join('|');
        })()
        """), "2|2|https://example.com/a/b")
    }

    @MainActor
    func testDetachedDocumentQueriesAreScoped() {
        let env = makeEnvironment()
        // #root exists in the live page but must not leak into the new document.
        XCTAssertEqual(evalString(env, """
        (function() {
          var d = document.implementation.createHTMLDocument('');
          d.body.innerHTML = '<p id="q">hi</p>';
          return [d.getElementById('q') ? 'found' : 'missing',
                  d.getElementById('root') ? 'leak' : 'scoped',
                  d.querySelector('#q').textContent,
                  d.body.ownerDocument === d].join('|');
        })()
        """), "found|scoped|hi|true")
    }

    @MainActor
    func testNativeParseHTMLDocument() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var d = __nativeParseHTMLDocument('<html><head><meta charset="utf-8"></head><body><div id="z">Q</div></body></html>');
          return [d.nodeType, !!d.head, d.getElementById('z').textContent].join('|');
        })()
        """), "9|true|Q")
        // A bare fragment still gets an html/head/body skeleton.
        XCTAssertEqual(evalString(env, "String(__nativeParseHTMLDocument('<p>x</p>').body.childNodes.length)"), "1")
    }

    // MARK: - classList

    /// Regression: classList used to be materialised once against the shared
    /// element prototype, so every element saw the same empty object.
    @MainActor
    func testClassListIsPerElementAndOrdered() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var a = document.createElement('div');
          var b = document.createElement('div');
          a.classList.add('one');
          return [a.className, b.className === '' ? 'empty' : b.className].join('|');
        })()
        """), "one|empty")

        // Document order, not alphabetical.
        XCTAssertEqual(evalString(env, """
        (function() {
          var d = document.createElement('div');
          d.classList.add('zz'); d.classList.add('aa');
          return d.className;
        })()
        """), "zz aa")
    }

    @MainActor
    func testClassListMutatorsAndSnapshot() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var d = document.querySelector('#root');
          var before = d.classList.length;
          d.classList.toggle('c', true);
          d.classList.toggle('c', true);
          var replaced = d.classList.replace('a', 'z');
          d.classList.remove('b');
          return [before, d.classList.length, replaced, d.classList.contains('z'),
                  d.classList.value, d.classList.item(0)].join('|');
        })()
        """), "2|2|true|true|z c|z")
    }

    // MARK: - Element APIs

    @MainActor
    func testMatchesWorksOnDetachedElements() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var d = document.createElement('div');
          d.className = 'solo';
          d.setAttribute('data-k', 'v');
          return [d.matches('div.solo'), d.matches('div[data-k="v"]'), d.matches('span')].join('|');
        })()
        """), "true|true|false")
    }

    @MainActor
    func testClosest() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var s = document.querySelector('.x');
          return [s.closest('#root') === document.querySelector('#root'),
                  s.closest('.x') === s,
                  String(s.closest('#nope'))].join('|');
        })()
        """), "true|true|null")
    }

    @MainActor
    func testInsertAdjacentPositions() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var p = document.createElement('div');
          var c = document.createElement('span');
          p.appendChild(c);
          c.insertAdjacentHTML('beforebegin', '<i></i>');
          c.insertAdjacentHTML('afterend', '<b></b>');
          c.insertAdjacentElement('afterbegin', document.createElement('u'));
          c.insertAdjacentText('beforeend', 'txt');
          var tags = [];
          for (var i = 0; i < p.children.length; i++) tags.push(p.children[i].tagName.toLowerCase());
          return tags.join(',') + '|' + c.textContent;
        })()
        """), "i,span,b|txt")
    }

    @MainActor
    func testReplaceChildrenAndOuterHTMLSetter() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var p = document.createElement('div');
          p.appendChild(document.createElement('span'));
          p.replaceChildren(document.createElement('b'), document.createElement('i'));
          var afterReplace = p.children.length;
          p.children[0].outerHTML = '<em id="nb"></em>';
          return [afterReplace, p.children.length, p.children[0].tagName.toLowerCase(), p.children[0].id].join('|');
        })()
        """), "2|2|em|nb")
    }

    @MainActor
    func testAttributeHelpers() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var d = document.createElement('div');
          var empty = d.hasAttributes();
          d.toggleAttribute('hidden');
          var on = d.hasAttribute('hidden');
          d.toggleAttribute('hidden');
          var off = d.hasAttribute('hidden');
          d.toggleAttribute('x', true);
          d.toggleAttribute('x', true);
          return [empty, on, off, d.getAttributeNames().join(','), d.hasAttributes()].join('|');
        })()
        """), "false|true|false|x|true")
    }

    @MainActor
    func testCompareDocumentPosition() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var root = document.querySelector('#root');
          var a = document.querySelector('.x'), b = document.querySelector('.y');
          return [a.compareDocumentPosition(b) & 4,
                  b.compareDocumentPosition(a) & 2,
                  root.compareDocumentPosition(a) & 16,
                  a.compareDocumentPosition(root) & 8,
                  a.compareDocumentPosition(a)].join('|');
        })()
        """), "4|2|16|8|0")
    }

    @MainActor
    func testTemplateContent() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var t = document.createElement('template');
          t.innerHTML = '<li>a</li><li>b</li>';
          return [t.content.nodeType, t.content.childNodes.length,
                  t.childNodes.length, t.innerHTML.indexOf('<li>') === 0].join('|');
        })()
        """), "11|2|0|true")
    }

    @MainActor
    func testNodeListShapeAndConstants() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var list = document.querySelectorAll('span');
          var byId = document.getElementsByTagName('div');
          return [list.length, list.item(0).className, String(list.item(9)),
                  byId.namedItem('root').id, typeof list.forEach].join('|');
        })()
        """), "2|x|null|root|function")
        XCTAssertEqual(evalString(env, "[document.body.ELEMENT_NODE, document.body.TEXT_NODE, document.body.DOCUMENT_FRAGMENT_NODE].join(',')"), "1,3,11")
    }

    @MainActor
    func testDocumentExtras() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, "document.contains(document.querySelector('#root')) + '|' + document.contains(document.createElement('p'))"), "true|false")
        XCTAssertEqual(evalString(env, "document.documentElement.parentNode === document"), "true")
        XCTAssertEqual(evalString(env, """
        (function() {
          var d = document.implementation.createHTMLDocument('');
          d.body.innerHTML = '<b id="ii">x</b>';
          var n = document.importNode(d.getElementById('ii'), true);
          return [n.id, n.textContent, String(n.parentNode)].join('|');
        })()
        """), "ii|x|null")
        XCTAssertEqual(evalString(env, "String(document.currentScript)"), "null")
    }

    // MARK: - Proxy deleteProperty (backs `delete element.dataset.foo`)

    @MainActor
    func testProxyDeletePropertyTrap() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var seen = [];
          var store = { a: 1 };
          var p = new Proxy(store, {
            deleteProperty: function(t, k) { seen.push(k); delete t[k]; return true; }
          });
          var ok = delete p.a;
          return [ok, seen.join(','), 'a' in store].join('|');
        })()
        """), "true|a|false")
    }

    // MARK: - Reflected IDL attributes

    /// apple.com's global header reads `meta.name` / `meta.content` off every
    /// `meta[name^="globalnav-"]`; both answered undefined, so building the
    /// flyout died on `Cannot read properties of undefined (reading 'replace')`.
    @MainActor
    func testMetaNameAndContentReflectAttributes() {
        let env = makeEnvironment()
        _ = evalString(env, """
        document.head.innerHTML =
          '<meta name="globalnav-store-key" content="SFX9">' +
          '<meta name="viewport" content="width=device-width">';
        """)
        XCTAssertEqual(evalString(env, """
        Array.from(document.querySelectorAll('meta[name^="globalnav-"]'))
             .map(function(m) { return m.name + '=' + m.content; }).join(',')
        """), "globalnav-store-key=SFX9")
        XCTAssertEqual(evalString(env,
            "document.querySelector('meta[name=viewport]').content"), "width=device-width")
        // Writable, and the write lands on the content attribute.
        XCTAssertEqual(evalString(env, """
        (function() {
          var m = document.querySelector('meta[name=viewport]');
          m.content = m.content + ',initial-scale=1';
          return m.getAttribute('content');
        })()
        """), "width=device-width,initial-scale=1")
    }

    /// `<template>.content` must still be the DocumentFragment, not a string.
    @MainActor
    func testTemplateContentStillAFragment() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var t = document.createElement('template');
          t.innerHTML = '<i>hi</i>';
          return [typeof t.content, String(t.content.nodeType), t.content.firstChild.tagName].join('|');
        })()
        """), "object|11|I")
    }

    @MainActor
    func testStringReflectedElementAttributes() {
        let env = makeEnvironment()
        _ = evalString(env, """
        document.body.innerHTML =
          '<img id="im" src="a.png" alt="A" title="T">' +
          '<input id="in" placeholder="P" name="q">' +
          '<input id="in2" type="checkbox">' +
          '<button id="bt"></button>';
        """)
        XCTAssertEqual(evalString(env, """
        (function() { var i = document.getElementById('im');
          return [i.alt, i.title, i.name].join('|'); })()
        """), "A|T|")
        XCTAssertEqual(evalString(env, """
        (function() { var i = document.getElementById('in');
          return [i.placeholder, i.name, i.type].join('|'); })()
        """), "P|q|text")
        XCTAssertEqual(evalString(env, "document.getElementById('in2').type"), "checkbox")
        XCTAssertEqual(evalString(env, "document.getElementById('bt').type"), "submit")
        XCTAssertEqual(evalString(env, """
        (function() { var i = document.getElementById('im'); i.alt = 'B'; i.name = 'n';
          return [i.getAttribute('alt'), i.getAttribute('name')].join('|'); })()
        """), "B|n")
        // document.title is the document's own accessor, not the element one.
        XCTAssertEqual(evalString(env, "(function(){ document.title = 'Doc'; return document.title; })()"), "Doc")
    }
}
