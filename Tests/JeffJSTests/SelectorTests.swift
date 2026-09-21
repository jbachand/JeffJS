// SelectorTests.swift
// JeffJS — CSS selector engine coverage, driven two ways:
//   * through the JS bridge (document.querySelectorAll / matches / closest),
//     which is what pages and React see;
//   * directly through CSSSelector / CSSSelectorMatcher / CSSSpecificity,
//     which is what the app's StyleResolver uses.
// Expectations are written by hand from the Selectors Level 4 / HTML specs and
// WebKit's observable behaviour.
//
// Usage:
//   swift test --filter SelectorTests

import XCTest
@testable import JeffJS

final class SelectorTests: XCTestCase {

    // MARK: - Helpers

    override func setUp() {
        super.setUp()
        DOMNode.resetInteractionState()
    }

    override func tearDown() {
        DOMNode.resetInteractionState()
        super.tearDown()
    }

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
    private func makeEnvironment(body: String = "") -> JeffJSEnvironment {
        let env = JeffJSEnvironment(configuration: .init(viewportWidth: 390, viewportHeight: 844))
        if !body.isEmpty {
            let escaped = body
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
            _ = evalString(env, "document.body.innerHTML = '\(escaped)';")
        }
        return env
    }

    /// Parses HTML into a document node for the Swift-side (StyleResolver) API.
    private func tree(_ html: String) -> DOMNode {
        HTMLParser.parse(html)
    }

    /// Swift-side `querySelectorAll`, returning ids (or tag names) in document order.
    private func ids(_ root: DOMNode, _ selector: String) -> [String] {
        root.querySelectorAll(selector).map { $0.idAttribute ?? ($0.tagName ?? "?") }
    }

    private func node(_ root: DOMNode, id: String) -> DOMNode {
        guard let found = root.querySelector("#\(id)") else {
            XCTFail("no element #\(id)")
            return DOMNode.element(tag: "div")
        }
        return found
    }

    private func spec(_ selector: String) -> [Int] {
        guard let s = CSSSelector.specificity(of: selector) else { return [-1, -1, -1] }
        return [s.ids, s.classes, s.elements]
    }

    // MARK: - 1. Token lists: ASCII whitespace splitting

    /// apple.com's globalnav writes `class="\n\tfoo\n\tbar"`. Splitting on " "
    /// alone produced one bogus token and no rule matched.
    @MainActor
    func testClassAttributeSplitsOnAllASCIIWhitespace() {
        let env = makeEnvironment()
        _ = evalString(env, """
        document.body.innerHTML =
          '<div id="a" class="\\n\\tglobalnav\\n\\tglobalnav-open\\r\\n"></div>' +
          '<div id="b" class="\\u000Cff  gg\\t"></div>';
        """)
        XCTAssertEqual(evalString(env, "document.querySelectorAll('.globalnav').length"), "1")
        XCTAssertEqual(evalString(env, "document.querySelectorAll('.globalnav-open').length"), "1")
        XCTAssertEqual(evalString(env, "document.getElementById('a').classList.length"), "2")
        XCTAssertEqual(evalString(env, "document.getElementById('a').classList.contains('globalnav')"), "true")
        XCTAssertEqual(evalString(env, "document.getElementById('b').classList.length"), "2")
        XCTAssertEqual(evalString(env, "document.querySelectorAll('.ff.gg').length"), "1")
        // Empty tokens are dropped, not counted.
        XCTAssertEqual(evalString(env, "document.getElementById('b').classList.item(0)"), "ff")
        XCTAssertEqual(evalString(env, "document.getElementById('b').classList.item(1)"), "gg")
        XCTAssertEqual(evalString(env, "String(document.getElementById('b').classList.item(2))"), "null")
    }

    func testClassListSplittingSwiftAPI() {
        let root = tree("<div id='a' class='\n\tfoo\n\tbar\r'></div><div id='b' class='  '></div>")
        let a = node(root, id: "a")
        XCTAssertEqual(a.classNames, ["foo", "bar"])
        XCTAssertEqual(a.classList, ["foo", "bar"])
        XCTAssertTrue(a.matchesSelector(".foo.bar"))
        XCTAssertEqual(node(root, id: "b").classNames, [])
        // A non-breaking space is *not* an HTML space character: one token.
        let nbsp = tree("<div id='c' class='a\u{00A0}b'></div>")
        XCTAssertEqual(node(nbsp, id: "c").classNames, ["a\u{00A0}b"])
        // Duplicates collapse (DOMTokenList is an ordered set).
        let dupes = tree("<div id='d' class='x y x'></div>")
        XCTAssertEqual(node(dupes, id: "d").classNames, ["x", "y"])
    }

    func testTokenListsForRelAndHeaders() {
        let root = tree("""
        <a id='a' rel='\n noopener\tnoreferrer '>x</a>
        <table><tr><td id='c' headers='h1\nh2'>v</td></tr></table>
        """)
        XCTAssertEqual(node(root, id: "a").relList, ["noopener", "noreferrer"])
        XCTAssertEqual(node(root, id: "a").tokenList(for: "rel"), ["noopener", "noreferrer"])
        XCTAssertEqual(node(root, id: "c").headersList, ["h1", "h2"])
        // [attr~=] splits the same way.
        XCTAssertTrue(node(root, id: "a").matchesSelector("[rel~='noreferrer']"))
        XCTAssertTrue(node(root, id: "c").matchesSelector("[headers~='h2']"))
    }

    @MainActor
    func testDOMTokenListSurface() {
        let env = makeEnvironment(body: "<div id='a' class='one two'></div><a id='l' rel='noopener'>x</a>")
        XCTAssertEqual(evalString(env, "typeof document.getElementById('a').classList.forEach"), "function")
        XCTAssertEqual(evalString(env, """
        (function () {
          var el = document.getElementById('a'), out = [];
          el.classList.forEach(function (t, i) { out.push(i + ':' + t); });
          return out.join(',');
        })()
        """), "0:one,1:two")
        XCTAssertEqual(evalString(env, "Array.from(document.getElementById('a').classList).join('|')"), "one|two")
        XCTAssertEqual(evalString(env, "[...document.getElementById('a').classList].join('|')"), "one|two")
        XCTAssertEqual(evalString(env, """
        (function () {
          var cl = document.getElementById('a').classList;
          cl.add('three'); cl.toggle('two'); cl.replace('one', 'uno');
          return cl.value + '|' + cl.length + '|' + cl.contains('two');
        })()
        """), "uno three|2|false")
        // className reflects the attribute both ways.
        XCTAssertEqual(evalString(env, """
        (function () {
          var el = document.getElementById('a');
          el.className = 'p\\tq';
          return el.className + '|' + el.classList.length + '|' + document.querySelectorAll('.q').length;
        })()
        """), "p\tq|2|1")
        // relList
        XCTAssertEqual(evalString(env, """
        (function () {
          var l = document.getElementById('l');
          l.relList.add('noreferrer');
          return l.rel + '|' + l.relList.length + '|' + l.relList.contains('noopener');
        })()
        """), "noopener noreferrer|2|true")
    }

    // MARK: - 2. :has()

    @MainActor
    func testHasRelativeSelectorsThroughBridge() {
        let env = makeEnvironment(body: """
        <section id='s1'><p id='p1'><span class='x'>a</span></p><h2 id='h2a'>t</h2></section>
        <section id='s2'><p id='p2'>b</p></section>
        <div id='d1'><i class='y'></i></div>
        <div id='d2'></div><div id='d3' class='x'></div>
        """)
        XCTAssertEqual(evalString(env, "document.querySelectorAll('section:has(.x)').length"), "1")
        XCTAssertEqual(evalString(env, "document.querySelector('section:has(.x)').id"), "s1")
        XCTAssertEqual(evalString(env, "document.querySelectorAll('p:has(> .x)').length"), "1")
        XCTAssertEqual(evalString(env, "document.querySelector('p:has(> .x)').id"), "p1")
        // `section:has(> .x)` — .x is a grandchild, so no match.
        XCTAssertEqual(evalString(env, "document.querySelectorAll('section:has(> .x)').length"), "0")
        // Adjacent sibling: #d2 is followed by #d3.x
        XCTAssertEqual(evalString(env, "document.querySelector('div:has(+ .x)').id"), "d2")
        XCTAssertEqual(evalString(env, "document.querySelectorAll('div:has(~ .x)').length"), "2")
        // Descendant chain inside :has
        XCTAssertEqual(evalString(env, "document.querySelector('body:has(section p .x)') ? 'yes' : 'no'"), "yes")
        // Negated :has
        XCTAssertEqual(evalString(env, """
        Array.prototype.map.call(document.querySelectorAll('section:not(:has(.x))'), function (e) { return e.id; }).join(',')
        """), "s2")
        // matches()/closest() honour :has too
        XCTAssertEqual(evalString(env, "document.getElementById('s1').matches(':has(h2)')"), "true")
        XCTAssertEqual(evalString(env, "document.getElementById('p1').closest(':has(> .x)').id"), "p1")
    }

    func testHasRelativeSelectorsSwiftAPI() {
        let root = tree("""
        <ul id='u'>
          <li id='l1'><a href='#' class='cta'>go</a></li>
          <li id='l2'>plain</li>
          <li id='l3'><span><a href='#' class='cta'>deep</a></span></li>
        </ul>
        """)
        XCTAssertEqual(ids(root, "li:has(.cta)"), ["l1", "l3"])
        XCTAssertEqual(ids(root, "li:has(> .cta)"), ["l1"])
        XCTAssertEqual(ids(root, "li:has(span .cta)"), ["l3"])
        XCTAssertEqual(ids(root, "li:has(+ li)"), ["l1", "l2"])
        XCTAssertEqual(ids(root, "li:has(~ #l3)"), ["l1", "l2"])
        XCTAssertEqual(ids(root, "li:not(:has(.cta))"), ["l2"])
        XCTAssertEqual(ids(root, "ul:has(li:has(> .cta))"), ["u"])
        // :has() inside :is()
        XCTAssertEqual(ids(root, ":is(li:has(> .cta))"), ["l1"])
        // The per-pass cache must not change results.
        CSSSelectorMatcher.beginMatchPass()
        XCTAssertEqual(ids(root, "li:has(.cta)"), ["l1", "l3"])
        XCTAssertEqual(ids(root, "li:has(.cta)"), ["l1", "l3"])
        CSSSelectorMatcher.endMatchPass()
    }

    // MARK: - 3a. :is / :where / :not

    func testIsWhereNotSelectorLists() {
        let root = tree("""
        <div id='w'><h1 id='h1'>a</h1><h2 id='h2'>b</h2><p id='p' class='lead'>c</p><p id='q'>d</p></div>
        """)
        XCTAssertEqual(ids(root, ":is(h1, h2)"), ["h1", "h2"])
        XCTAssertEqual(ids(root, ":where(h1, h2)"), ["h1", "h2"])
        XCTAssertEqual(ids(root, "p:not(.lead)"), ["q"])
        XCTAssertEqual(ids(root, "p:not(.lead, #q)"), [])
        XCTAssertEqual(ids(root, "#w :is(p.lead, h1)"), ["h1", "p"])
        // :is() is forgiving; an unknown argument just never matches.
        XCTAssertEqual(ids(root, ":is(h1, :totally-bogus)"), ["h1"])
    }

    // MARK: - 3b. Structural pseudo-classes

    func testStructuralPseudoClasses() {
        let root = tree("""
        <ul id='u'>
          <li id='a'>1</li><li id='b'>2</li><li id='c'>3</li><li id='d'>4</li><li id='e'>5</li>
        </ul>
        <div id='mix'><span id='s1'>x</span><b id='b1'>y</b><span id='s2'>z</span><b id='b2'>w</b></div>
        <div id='empty'></div><div id='cmt'><!-- hi --></div><div id='txt'>t</div>
        <div id='only'><p id='onlyp'>solo</p></div>
        """)
        XCTAssertEqual(ids(root, "li:first-child"), ["a"])
        XCTAssertEqual(ids(root, "li:last-child"), ["e"])
        XCTAssertEqual(ids(root, "li:nth-child(2)"), ["b"])
        XCTAssertEqual(ids(root, "li:nth-child(odd)"), ["a", "c", "e"])
        XCTAssertEqual(ids(root, "li:nth-child(even)"), ["b", "d"])
        XCTAssertEqual(ids(root, "li:nth-child(2n+1)"), ["a", "c", "e"])
        XCTAssertEqual(ids(root, "li:nth-child(-n+2)"), ["a", "b"])
        XCTAssertEqual(ids(root, "li:nth-last-child(1)"), ["e"])
        XCTAssertEqual(ids(root, "li:nth-last-child(2n)"), ["b", "d"])
        XCTAssertEqual(ids(root, "#mix span:first-of-type"), ["s1"])
        XCTAssertEqual(ids(root, "#mix span:last-of-type"), ["s2"])
        XCTAssertEqual(ids(root, "#mix b:nth-of-type(2)"), ["b2"])
        XCTAssertEqual(ids(root, "#mix b:nth-last-of-type(1)"), ["b2"])
        XCTAssertEqual(ids(root, "#only p:only-child"), ["onlyp"])
        XCTAssertEqual(ids(root, "#only p:only-of-type"), ["onlyp"])
        // :empty — comments and empty text nodes do not count, real text does.
        XCTAssertTrue(node(root, id: "empty").matchesSelector(":empty"))
        XCTAssertTrue(node(root, id: "cmt").matchesSelector(":empty"))
        XCTAssertFalse(node(root, id: "txt").matchesSelector(":empty"))
        // :root is the document element — exactly one per document, even when
        // the markup has several top-level elements.
        XCTAssertEqual(root.querySelectorAll(":root").count, 1)
        XCTAssertEqual(root.querySelectorAll(":root")[0].tagName, "ul")
        let page = tree("<html><body><div id='d'>x</div></body></html>")
        XCTAssertEqual(page.querySelectorAll(":root").map { $0.tagName }, ["html"])
        XCTAssertFalse(node(page, id: "d").matchesSelector(":root"))
        // A detached element is not :root.
        XCTAssertFalse(DOMNode.element(tag: "div").matchesSelector(":root"))
    }

    func testNthChildOfSelector() {
        let root = tree("""
        <ul id='u'>
          <li id='a' class='hit'>1</li><li id='b'>2</li><li id='c' class='hit'>3</li>
          <li id='d' class='hit'>4</li><li id='e'>5</li><li id='f' class='hit'>6</li>
        </ul>
        """)
        XCTAssertEqual(ids(root, "li:nth-child(2 of .hit)"), ["c"])
        XCTAssertEqual(ids(root, "li:nth-child(odd of .hit)"), ["a", "d"])
        XCTAssertEqual(ids(root, "li:nth-last-child(1 of .hit)"), ["f"])
        XCTAssertEqual(ids(root, "li:nth-last-child(2 of .hit)"), ["d"])
        // An element that does not match S never matches, whatever its index.
        XCTAssertFalse(node(root, id: "b").matchesSelector(":nth-child(2 of .hit)"))
    }

    // MARK: - 3c. Link / interaction / target state

    func testLinkAndInteractionPseudoClasses() {
        let root = tree("""
        <div id='wrap'><a id='link' href='/x'>go</a><a id='anchor'>no href</a>
        <input id='field'><span id='sib'>s</span></div>
        """)
        let link = node(root, id: "link")
        XCTAssertTrue(link.matchesSelector(":link"))
        XCTAssertTrue(link.matchesSelector(":any-link"))
        // :visited must never match — a privacy rule, not an oversight.
        XCTAssertFalse(link.matchesSelector(":visited"))
        XCTAssertFalse(node(root, id: "anchor").matchesSelector(":any-link"))

        // Nothing is hovered/focused until the host says so.
        XCTAssertEqual(ids(root, ":hover"), [])
        XCTAssertEqual(ids(root, ":focus"), [])

        DOMNode.hoveredNode = link
        // :hover matches the hovered element and its ancestors, like WebKit.
        XCTAssertTrue(link.matchesSelector(":hover"))
        XCTAssertTrue(node(root, id: "wrap").matchesSelector(":hover"))
        XCTAssertFalse(node(root, id: "sib").matchesSelector(":hover"))
        XCTAssertEqual(ids(root, "a:hover"), ["link"])

        let field = node(root, id: "field")
        DOMNode.focusedNode = field
        XCTAssertTrue(field.matchesSelector(":focus"))
        XCTAssertTrue(field.matchesSelector(":focus-visible"))
        XCTAssertTrue(node(root, id: "wrap").matchesSelector(":focus-within"))
        XCTAssertFalse(node(root, id: "wrap").matchesSelector(":focus"))
        DOMNode.focusVisible = false
        XCTAssertFalse(field.matchesSelector(":focus-visible"))
        XCTAssertTrue(field.matchesSelector(":focus"))

        DOMNode.activeNode = link
        XCTAssertTrue(link.matchesSelector(":active"))

        // :target follows the host-settable fragment.
        XCTAssertFalse(node(root, id: "wrap").matchesSelector(":target"))
        DOMNode.targetFragment = "wrap"
        XCTAssertTrue(node(root, id: "wrap").matchesSelector(":target"))
        XCTAssertTrue(node(root, id: "wrap").matchesSelector(":target-within"))
        XCTAssertFalse(link.matchesSelector(":target"))
    }

    // MARK: - 3d. Form state pseudo-classes

    func testFormStatePseudoClasses() {
        let root = tree("""
        <form id='f'>
          <input id='cb' type='checkbox' checked>
          <input id='cb2' type='checkbox'>
          <input id='ind' type='checkbox' indeterminate>
          <input id='txt' type='text' placeholder='name'>
          <input id='filled' type='text' placeholder='name' value='jeff'>
          <input id='ro' type='text' readonly>
          <input id='req' type='text' required>
          <input id='dis' type='text' disabled>
          <select id='sel'><option id='o1' selected>a</option><option id='o2'>b</option></select>
          <fieldset id='fs' disabled><input id='inner'></fieldset>
          <button id='submit' type='submit'>go</button>
          <button id='plain' type='button'>x</button>
          <p id='para'>text</p>
        </form>
        """)
        XCTAssertEqual(ids(root, ":checked"), ["cb", "o1"])
        XCTAssertTrue(node(root, id: "cb2").matchesSelector(":not(:checked)"))
        XCTAssertTrue(node(root, id: "txt").matchesSelector(":placeholder-shown"))
        XCTAssertFalse(node(root, id: "filled").matchesSelector(":placeholder-shown"))
        XCTAssertTrue(node(root, id: "req").matchesSelector(":required"))
        XCTAssertFalse(node(root, id: "req").matchesSelector(":optional"))
        XCTAssertTrue(node(root, id: "txt").matchesSelector(":optional"))
        XCTAssertTrue(node(root, id: "ro").matchesSelector(":read-only"))
        XCTAssertFalse(node(root, id: "ro").matchesSelector(":read-write"))
        XCTAssertTrue(node(root, id: "txt").matchesSelector(":read-write"))
        // Non-editable elements are :read-only, per CSS UI.
        XCTAssertTrue(node(root, id: "para").matchesSelector(":read-only"))
        XCTAssertTrue(node(root, id: "dis").matchesSelector(":disabled"))
        XCTAssertFalse(node(root, id: "dis").matchesSelector(":enabled"))
        XCTAssertTrue(node(root, id: "txt").matchesSelector(":enabled"))
        // disabled is inherited from an ancestor <fieldset disabled>
        XCTAssertTrue(node(root, id: "inner").matchesSelector(":disabled"))
        XCTAssertTrue(node(root, id: "ind").matchesSelector(":indeterminate"))
        XCTAssertFalse(node(root, id: "cb").matchesSelector(":indeterminate"))
        // :default — checked boxes, selected options, the form's first submit button
        XCTAssertTrue(node(root, id: "cb").matchesSelector(":default"))
        XCTAssertTrue(node(root, id: "o1").matchesSelector(":default"))
        XCTAssertTrue(node(root, id: "submit").matchesSelector(":default"))
        XCTAssertFalse(node(root, id: "plain").matchesSelector(":default"))
        // contenteditable is :read-write, and it is inherited
        let editable = tree("<div id='ed' contenteditable='true'><span id='in'>x</span></div>")
        XCTAssertTrue(node(editable, id: "ed").matchesSelector(":read-write"))
        XCTAssertTrue(node(editable, id: "in").matchesSelector(":read-write"))
    }

    @MainActor
    func testFormStateThroughBridge() {
        let env = makeEnvironment(body: "<input id='a' type='checkbox'><input id='b' type='text' disabled>")
        XCTAssertEqual(evalString(env, "document.querySelectorAll(':checked').length"), "0")
        XCTAssertEqual(evalString(env, """
        (function () {
          document.getElementById('a').checked = true;
          return document.querySelectorAll('input:checked').length;
        })()
        """), "1")
        XCTAssertEqual(evalString(env, "document.querySelector(':disabled').id"), "b")
        XCTAssertEqual(evalString(env, "document.getElementById('a').matches(':enabled')"), "true")
    }

    // MARK: - 3e. :lang / :dir / :defined

    func testLangDirDefined() {
        let root = tree("""
        <div id='outer' lang='en-GB' dir='rtl'>
          <p id='inner'>x</p>
          <p id='fr' lang='fr'>y</p>
          <p id='ltr' dir='ltr'>z</p>
        </div>
        <my-widget id='w'>c</my-widget><div id='plain'>p</div>
        """)
        XCTAssertTrue(node(root, id: "outer").matchesSelector(":lang(en)"))
        XCTAssertTrue(node(root, id: "outer").matchesSelector(":lang(en-GB)"))
        XCTAssertTrue(node(root, id: "inner").matchesSelector(":lang(en)"), "lang is inherited")
        XCTAssertFalse(node(root, id: "fr").matchesSelector(":lang(en)"))
        XCTAssertTrue(node(root, id: "fr").matchesSelector(":lang(fr, de)"))
        XCTAssertTrue(node(root, id: "fr").matchesSelector(":lang('fr')"))
        XCTAssertTrue(node(root, id: "outer").matchesSelector(":dir(rtl)"))
        XCTAssertTrue(node(root, id: "inner").matchesSelector(":dir(rtl)"))
        XCTAssertTrue(node(root, id: "ltr").matchesSelector(":dir(ltr)"))
        // :defined — built-ins always, custom elements only once registered.
        XCTAssertTrue(node(root, id: "plain").matchesSelector(":defined"))
        XCTAssertFalse(node(root, id: "w").matchesSelector(":defined"))
        DOMNode.definedCustomElements = ["my-widget"]
        XCTAssertTrue(node(root, id: "w").matchesSelector(":defined"))
    }

    // MARK: - 3f. Attribute selectors

    func testAttributeSelectorsAllOperatorsAndFlags() {
        let root = tree("""
        <a id='a1' href='https://example.com/a.PDF' data-role='Primary Nav' title='x'></a>
        <a id='a2' href='/b.pdf' data-role='primary'></a>
        <div id='d1' lang='en-US' class='a b'></div>
        """)
        XCTAssertEqual(ids(root, "[title]"), ["a1"])
        XCTAssertEqual(ids(root, "[data-role='primary']"), ["a2"])
        XCTAssertEqual(ids(root, "[data-role~='Nav']"), ["a1"])
        XCTAssertEqual(ids(root, "[lang|='en']"), ["d1"])
        XCTAssertEqual(ids(root, "[href^='https']"), ["a1"])
        XCTAssertEqual(ids(root, "[href$='.pdf']"), ["a2"])
        XCTAssertEqual(ids(root, "[href*='example']"), ["a1"])
        // `i` flag, and `s` forcing case-sensitivity back on
        XCTAssertEqual(ids(root, "[href$='.pdf' i]"), ["a1", "a2"])
        XCTAssertEqual(ids(root, "[data-role='PRIMARY' i]"), ["a2"])
        XCTAssertEqual(ids(root, "[data-role='PRIMARY' s]"), [])
        // Legacy HTML attributes match case-insensitively by default (WebKit).
        let types = tree("<input id='i1' type='TEXT'><input id='i2' type='checkbox'>")
        XCTAssertEqual(ids(types, "[type='text']"), ["i1"])
        XCTAssertEqual(ids(root, "[class='A B']"), [], "class stays case-sensitive")
        // Empty values never match the substring-style operators.
        XCTAssertEqual(ids(root, "[href^='']"), [])
        XCTAssertEqual(ids(root, "[href*='']"), [])
        XCTAssertEqual(ids(root, "[href~='']"), [])
    }

    // MARK: - 3g. Escapes, case-insensitive tags, namespaces, universal

    func testEscapedIdentifiersAndTagCasing() {
        let root = tree("""
        <div id='a' class='hover:bg-blue'></div>
        <div id='10' class='w-1/2'></div>
        <DIV id='caps'></DIV>
        """)
        // Tailwind-style class names need `\:` and `\/`
        XCTAssertEqual(ids(root, ".hover\\:bg-blue"), ["a"])
        XCTAssertEqual(ids(root, ".w-1\\/2"), ["10"])
        // `\31 0` is the id "10" (hex escape + a single terminating space)
        XCTAssertEqual(ids(root, "#\\31 0"), ["10"])
        // HTML type selectors are case-insensitive
        XCTAssertEqual(ids(root, "DIV").count, 3)
        XCTAssertEqual(ids(root, "div").count, 3)
        // universal and namespace-free `|`
        XCTAssertEqual(root.querySelectorAll("*").count, root.querySelectorAll("*|*").count)
        XCTAssertEqual(ids(root, "|div").count, 3)
        XCTAssertEqual(ids(root, "*|div").count, 3)
    }

    // MARK: - 3h. Combinators

    func testCombinatorsAndWhitespaceVariants() {
        let root = tree("""
        <div id='root'>
          <section id='s'><p id='p1'>a</p><p id='p2'>b</p><span id='sp'>c</span><p id='p3'>d</p></section>
          <article id='art'><div id='deep'><p id='p4'>e</p></div></article>
        </div>
        """)
        XCTAssertEqual(ids(root, "#s > p"), ["p1", "p2", "p3"])
        XCTAssertEqual(ids(root, "#s>p"), ["p1", "p2", "p3"])
        XCTAssertEqual(ids(root, "#s   >   p"), ["p1", "p2", "p3"])
        XCTAssertEqual(ids(root, "#root > section > p"), ["p1", "p2", "p3"])
        XCTAssertEqual(ids(root, "#p1 + p"), ["p2"])
        XCTAssertEqual(ids(root, "#p1+p"), ["p2"])
        XCTAssertEqual(ids(root, "#p1 ~ p"), ["p2", "p3"])
        XCTAssertEqual(ids(root, "#p1~*"), ["p2", "sp", "p3"])
        XCTAssertEqual(ids(root, "#root p"), ["p1", "p2", "p3", "p4"])
        XCTAssertEqual(ids(root, "article p"), ["p4"])
        // Descendant matching must backtrack: the nearest div ancestor of #p4 is
        // #deep, which has no #root parent — but #root itself does match.
        XCTAssertEqual(ids(root, "#root div p"), ["p4"])
        // Selector lists with mixed specificity
        XCTAssertEqual(ids(root, "#p1, span, article p"), ["p1", "sp", "p4"])
    }

    // MARK: - 3i. Pseudo-elements

    func testPseudoElementsParseAndDoNotMatchElements() {
        let cases: [(String, CSSPseudoElement)] = [
            ("p::before", .before),
            ("p::after", .after),
            ("li::marker", .marker),
            ("input::placeholder", .placeholder),
            ("p::selection", .selection),
            ("p::first-line", .firstLine),
            ("p::first-letter", .firstLetter),
            // Legacy single-colon spellings are pseudo-elements too.
            ("p:before", .before),
            ("p:after", .after),
            ("p:first-line", .firstLine),
            ("p:first-letter", .firstLetter)
        ]
        for (selector, expected) in cases {
            let list = CSSSelector.parse(selector)
            XCTAssertEqual(list.selectors.count, 1, selector)
            XCTAssertEqual(list.selectors.first?.pseudoElement, expected, selector)
            XCTAssertTrue(CSSSelector.isSupported(selector), selector)
        }
        // querySelectorAll never returns anything for a pseudo-element selector.
        let root = tree("<p id='p'>x</p>")
        XCTAssertEqual(root.querySelectorAll("p::before").count, 0)
        XCTAssertFalse(node(root, id: "p").matchesSelector("p::before"))
        // ...but the style resolver can still find the originating element.
        let selector = CSSSelector.parse("p::before").selectors[0]
        XCTAssertTrue(CSSSelectorMatcher.matches(selector, node: node(root, id: "p")))
    }

    // MARK: - 3j. @supports selector()

    func testIsSupported() {
        for selector in [
            "div", "*", ".a.b", "#id", "a:hover", "input:checked", "li:nth-child(2n+1)",
            "li:nth-child(2n of .x)", "p:is(.a, .b)", "p:where(.a)", "p:not(.a, .b)",
            "section:has(> .x)", ":root", ":scope > a", "[href$='.pdf' i]", "::before",
            "::marker", "::placeholder", ":visited", ":lang(en)", ":dir(rtl)", ":defined",
            "a ~ b + c > d e"
        ] {
            XCTAssertTrue(CSSSelector.isSupported(selector), "expected supported: \(selector)")
        }
        for selector in [
            ":blink", "::slotted(a)", "::part(foo)", ":host", "div >", "", "   ",
            "p::-webkit-scrollbar", "svg|rect", ":has()", "div..a"
        ] {
            XCTAssertFalse(CSSSelector.isSupported(selector), "expected unsupported: \(selector)")
        }
    }

    // MARK: - 4. Specificity

    func testSpecificity() {
        XCTAssertEqual(spec("*"), [0, 0, 0])
        XCTAssertEqual(spec("div"), [0, 0, 1])
        XCTAssertEqual(spec("ul li"), [0, 0, 2])
        XCTAssertEqual(spec(".cls"), [0, 1, 0])
        XCTAssertEqual(spec("#id"), [1, 0, 0])
        XCTAssertEqual(spec("[type='text']"), [0, 1, 0])
        XCTAssertEqual(spec("a:hover"), [0, 1, 1])
        XCTAssertEqual(spec("li:nth-child(2)"), [0, 1, 1])
        // :is()/:not() take their most specific argument...
        XCTAssertEqual(spec(":is(.a, #b)"), [1, 0, 0])
        XCTAssertEqual(spec(":not(.a, div)"), [0, 1, 0])
        XCTAssertEqual(spec("p:is(.a, div em)"), [0, 1, 1])
        // ...:where() contributes nothing...
        XCTAssertEqual(spec(":where(#b, .a)"), [0, 0, 0])
        XCTAssertEqual(spec("p:where(#b)"), [0, 0, 1])
        // ...:has() behaves like :is()...
        XCTAssertEqual(spec("div:has(#x)"), [1, 0, 1])
        XCTAssertEqual(spec("div:has(> .x)"), [0, 1, 1])
        // ...and :nth-child(of S) is (0,1,0) plus S.
        XCTAssertEqual(spec("li:nth-child(2n of .hit)"), [0, 2, 1])
        XCTAssertEqual(spec("li:nth-last-child(1 of #x)"), [1, 1, 1])
        // Pseudo-elements count as elements even though they are lifted out of
        // the component list during parsing.
        XCTAssertEqual(spec("::before"), [0, 0, 1])
        XCTAssertEqual(spec("p::before"), [0, 0, 2])
        XCTAssertEqual(spec("p.lead::first-line"), [0, 1, 2])
        // Ordering is what the style resolver sorts on.
        XCTAssertTrue(CSSSelector.specificity(of: "#a")! > CSSSelector.specificity(of: ".a.b.c")!)
        XCTAssertTrue(CSSSelector.specificity(of: ".a")! > CSSSelector.specificity(of: "div span")!)
        // A selector list reports its most specific member.
        XCTAssertEqual(spec("div, #a"), [1, 0, 0])
    }

    // MARK: - 5. Detached trees, fragments, :scope, document order

    @MainActor
    func testDetachedTreesAndFragmentsThroughBridge() {
        let env = makeEnvironment(body: "<div id='root'><a id='a1' href='#'>x</a></div>")
        // Detached element tree
        XCTAssertEqual(evalString(env, """
        (function () {
          var d = document.createElement('div');
          d.className = 'outer';
          d.innerHTML = '<span class="in">a</span><span class="in">b</span>';
          return [d.querySelectorAll('.in').length,
                  d.querySelector('.in').textContent,
                  d.matches('.outer'),
                  d.firstChild.closest('.outer') === d].join(',');
        })()
        """), "2,a,true,true")
        // DocumentFragment
        XCTAssertEqual(evalString(env, """
        (function () {
          var f = document.createDocumentFragment();
          var p = document.createElement('p'); p.id = 'fp';
          var s = document.createElement('span'); s.className = 'q';
          p.appendChild(s); f.appendChild(p);
          return [f.querySelectorAll('p').length, f.querySelector('.q').className,
                  s.closest('p').id].join(',');
        })()
        """), "1,q,fp")
        // querySelectorAll never returns the element it was called on
        XCTAssertEqual(evalString(env, "document.getElementById('root').querySelectorAll('#root').length"), "0")
        XCTAssertEqual(evalString(env, "document.getElementById('root').querySelectorAll('div').length"), "0")
        // :scope in a relative selector
        XCTAssertEqual(evalString(env, "document.getElementById('root').querySelectorAll(':scope > a').length"), "1")
        XCTAssertEqual(evalString(env, "document.getElementById('root').matches(':scope')"), "true")
    }

    func testDetachedTreesAndScopeSwiftAPI() {
        // A tree built by hand, never attached to a document.
        let root = DOMNode.element(tag: "div", attributes: ["class": "outer", "id": "root"])
        let a = DOMNode.element(tag: "p", attributes: ["id": "a"])
        let b = DOMNode.element(tag: "p", attributes: ["id": "b", "class": "hit"])
        let deep = DOMNode.element(tag: "span", attributes: ["id": "deep", "class": "hit"])
        root.appendChild(a)
        root.appendChild(b)
        a.appendChild(deep)

        XCTAssertTrue(root.matchesSelector(".outer"))
        XCTAssertEqual(ids(root, ".hit"), ["deep", "b"])
        XCTAssertEqual(ids(root, ":scope > .hit"), ["b"])
        XCTAssertEqual(ids(root, ":scope p"), ["a", "b"])
        XCTAssertEqual(root.querySelectorAll("#root").count, 0)
        XCTAssertEqual(deep.closestMatching("p")?.idAttribute, "a")
        XCTAssertEqual(deep.closestMatching(".outer")?.idAttribute, "root")
        XCTAssertNil(deep.closestMatching("article"))
        XCTAssertEqual(deep.closestMatching(":scope")?.idAttribute, "deep")

        // Document fragments behave the same.
        let fragment = DOMNode.documentFragment()
        let li = DOMNode.element(tag: "li", attributes: ["id": "li1"])
        fragment.appendChild(li)
        XCTAssertEqual(ids(fragment, "li"), ["li1"])
        XCTAssertEqual(ids(fragment, ":scope > li"), ["li1"])
    }

    func testQuerySelectorAllReturnsDocumentOrder() {
        let root = tree("""
        <div id='n1'><div id='n2'><div id='n3'></div></div><div id='n4'></div></div>
        <div id='n5'><div id='n6'></div></div>
        """)
        XCTAssertEqual(ids(root, "div"), ["n1", "n2", "n3", "n4", "n5", "n6"])
        // A selector list must still come back in tree order, not list order.
        XCTAssertEqual(ids(root, "#n5, #n2, #n6"), ["n2", "n5", "n6"])
    }

    @MainActor
    func testQuerySelectorAllDocumentOrderThroughBridge() {
        let env = makeEnvironment(body: "<i id='a'></i><b id='b'></b><i id='c'></i>")
        XCTAssertEqual(evalString(env, """
        Array.prototype.map.call(document.querySelectorAll('b, i'), function (e) { return e.id; }).join(',')
        """), "a,b,c")
    }
}
