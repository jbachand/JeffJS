// InlineStyleHostConformance.swift
// JeffJS — `element.style` over a host's parsed declaration blocks
// (JeffJSDOMBridge+InlineStyle.swift): one native per property write, the
// `style` attribute and its MutationObserver records as before, the cache
// dropped whenever the attribute changes another way. The test host is a
// small CSSOM model (ordered declarations, "bad" values invalid).
//
// Usage:
//   swift test --filter InlineStyleHostConformance

import XCTest
@testable import JeffJS

/// Ordered `name: value [!important];` declarations; a value containing
/// "bad" or ";" is invalid (ignored), as an unparsable value is in CSSOM.
final class TestInlineStyleBlock: JeffJSInlineStyleBlock {
    struct Decl { var name: String; var value: String; var important: Bool }
    var decls: [Decl] = []
    static var parses = 0

    init(_ text: String) {
        TestInlineStyleBlock.parses += 1
        for part in text.split(separator: ";") {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let name = part[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            var important = false
            if value.hasSuffix("!important") { important = true; value = String(value.dropLast(10)).trimmingCharacters(in: .whitespaces) }
            guard !name.isEmpty, !value.isEmpty, !value.contains("bad") else { continue }
            decls.removeAll { $0.name == name }
            decls.append(Decl(name: name, value: value, important: important))
        }
    }

    func setProperty(_ rawName: String, value rawValue: String, priority: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespaces).lowercased()
        let value = rawValue.trimmingCharacters(in: .whitespaces)
        if value.isEmpty {
            guard let i = decls.firstIndex(where: { $0.name == name }) else { return false }
            decls.remove(at: i)
            return true
        }
        guard priority.isEmpty || priority == "important", !value.contains("bad"), !value.contains(";") else { return false }
        decls.removeAll { $0.name == name }
        decls.append(Decl(name: name, value: value, important: priority == "important"))
        return true
    }
    func propertyValue(_ name: String) -> String { decls.first { $0.name == name.lowercased() }?.value ?? "" }
    func propertyPriority(_ name: String) -> String { decls.first { $0.name == name.lowercased() }?.important == true ? "important" : "" }
    var cssText: String { decls.map { "\($0.name): \($0.value)\($0.important ? " !important" : "");" }.joined(separator: " ") }
}

final class TestInlineStyleHost: JeffJSInlineStyleHost {
    func parseInlineStyle(_ text: String) -> JeffJSInlineStyleBlock { TestInlineStyleBlock(text) }
}

final class InlineStyleHostConformance: XCTestCase {

    @JeffJSHostActor
    private func evalString(_ env: JeffJSEnvironment, _ js: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        switch env.eval(js) {
        case .success(let s): return s ?? "undefined"
        case .exception(let msg):
            XCTFail("JS threw: \(msg) — while evaluating: \(js)", file: file, line: line)
            return "<exception>"
        }
    }

    /// An environment whose bridge has the test host before any `el.style` read.
    @JeffJSHostActor
    static func makeEnvironment(host: JeffJSInlineStyleHost = TestInlineStyleHost()) -> JeffJSEnvironment {
        let env = JeffJSEnvironment(configuration: .init(viewportWidth: 390, viewportHeight: 844))
        env.domBridge?.inlineStyleHost = host
        return env
    }

    @JeffJSHostActor
    func testWritesGoThroughTheBlockAndTheAttribute() {
        let env = Self.makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var e = document.createElement('div'); document.body.appendChild(e);
          var mo = new MutationObserver(function() {});
          mo.observe(e, { attributes: true, attributeOldValue: true });
          var s = e.style, out = [];
          s.color = 'red'; s.setProperty('margin-top', '4px', 'important'); s.color = 'blue';
          out.push(e.getAttribute('style'), s.cssText, s.getPropertyValue('color'), s.getPropertyPriority('margin-top'));
          s.color = 'bad'; s.setProperty('width', '1px', 'nope'); s.removeProperty('height');
          out.push(e.getAttribute('style'));
          out.push(s.removeProperty('color'), e.getAttribute('style'));
          s.setProperty('top', null); s.setProperty('left', '2px', undefined);
          out.push(e.getAttribute('style'));
          out.push(mo.takeRecords().map(function(r) { return r.attributeName + '<' + r.oldValue; }).join(','));
          return out.join('|');
        })()
        """), "margin-top: 4px !important; color: blue;|margin-top: 4px !important; color: blue;|blue|important|margin-top: 4px !important; color: blue;|blue|margin-top: 4px !important;|margin-top: 4px !important; left: 2px;|style<null,style<color: red;,style<color: red; margin-top: 4px !important;,style<margin-top: 4px !important; color: blue;,style<margin-top: 4px !important;")
    }

    @JeffJSHostActor
    func testOtherAttributeWritesInvalidateTheBlock() {
        let env = Self.makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var e = document.createElement('div'), s = e.style, out = [];
          s.color = 'red';
          e.setAttribute('style', 'width: 3px; height: bad');
          out.push(s.width, s.color, s.cssText);
          s.top = '1px'; out.push(e.getAttribute('style'));
          e.removeAttribute('style'); out.push(s.cssText === '', s.top === '');
          s.cssText = 'a: 1; b: bad; c: 2'; out.push(e.getAttribute('style'), s.getPropertyValue('c'));
          e.style = 'z: 9'; out.push(e.getAttribute('style'));
          s.cssText = null; out.push(JSON.stringify(e.getAttribute('style')));
          var p = document.createElement('p'); p.innerHTML = '<i style="color: green"></i>';
          out.push(p.firstChild.style.color);
          return out.join('|');
        })()
        """), "3px||width: 3px;|width: 3px; top: 1px;|true|true|a: 1; c: 2;|2|z: 9;|\"\"|green")
    }

    @JeffJSHostActor
    func testOneParsePerElementAcrossWrites() {
        let env = Self.makeEnvironment()
        TestInlineStyleBlock.parses = 0
        _ = evalString(env, """
        (function() { var e = document.createElement('div');
          for (var i = 0; i < 100; i++) { e.style.setProperty('p' + (i % 10), i + 'px'); e.style.color = 'red'; void e.style.color; } })()
        """)
        XCTAssertEqual(TestInlineStyleBlock.parses, 1)
    }

    @JeffJSHostActor
    func testMembersAreEnumerableNativesThatCheckThis() {
        let env = Self.makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var p = Object.getPrototypeOf(document.createElement('div').style), out = [];
          ['setProperty', 'removeProperty', 'getPropertyValue', 'getPropertyPriority'].forEach(function(n) {
            var d = Object.getOwnPropertyDescriptor(p, n);
            out.push(n + ':' + d.enumerable + d.writable + d.configurable + d.value.length);
          });
          var c = Object.getOwnPropertyDescriptor(p, 'cssText'); out.push(typeof c.get + typeof c.set + c.enumerable);
          try { p.setProperty.call({}, 'a', 'b'); } catch (x) { out.push(x.name); }
          return out.join(',');
        })()
        """), "setProperty:truetruetrue3,removeProperty:truetruetrue1,getPropertyValue:truetruetrue1,getPropertyPriority:truetruetrue1,functionfunctiontrue,TypeError")
    }

    /// Without a host the engine's own members stay.
    @JeffJSHostActor
    func testNoHostKeepsTheEngineMembers() {
        let env = JeffJSEnvironment(configuration: .init(viewportWidth: 390, viewportHeight: 844))
        XCTAssertEqual(evalString(env, """
        (function() { var e = document.createElement('div'); e.style.color = 'red'; e.style.width = 5;
          return e.getAttribute('style') + '|' + Object.getOwnPropertyDescriptor(Object.getPrototypeOf(e.style), 'setProperty').enumerable; })()
        """), "color: red; width: 5px|false")
    }
}
