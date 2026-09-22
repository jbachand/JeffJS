// HTMLParserTests.swift
// JeffJS — the HTML tokenizer and tree builder against the WHATWG HTML
// parsing spec (§13.2) and WebKit's observable behaviour. Expectations are
// written by hand from the spec; the tricky trees were cross-checked against
// html5lib's tree dumps for apple.com, en.wikipedia.org and news.ycombinator.com.
//
// Usage:
//   swift test --filter HTMLParserTests

import XCTest
@testable import JeffJS

final class HTMLParserTests: XCTestCase {

    // MARK: - Helpers

    private func parse(_ html: String, scripting: Bool = true) -> DOMNode {
        HTMLParser.parse(html, scriptingEnabled: scripting)
    }

    /// html5lib's test-tree format, so a whole tree can be asserted at once.
    private func dump(_ root: DOMNode) -> String {
        var out = ""
        func walk(_ node: DOMNode, _ indent: Int) {
            let pad = String(repeating: " ", count: indent)
            switch node.nodeType {
            case .document, .documentFragment:
                break
            case .element:
                var name = node.tagName ?? ""
                if node.namespaceURI == DOMNode.svgNamespace { name = "svg " + name }
                if node.namespaceURI == DOMNode.mathmlNamespace { name = "math " + name }
                out += "| \(pad)<\(name)>\n"
                for (key, value) in node.enumerableAttributes.sorted(by: { $0.key < $1.key }) {
                    out += "| \(pad)  \(key)=\"\(value)\"\n"
                }
            case .text:
                out += "| \(pad)\"\(node.textContent ?? "")\"\n"
            case .comment:
                out += "| \(pad)<!-- \(node.textContent ?? "") -->\n"
            }
            let next = (node.nodeType == .document || node.nodeType == .documentFragment) ? indent : indent + 2
            for child in node.children { walk(child, next) }
        }
        for child in root.children { walk(child, 0) }
        return out
    }

    private func tags(_ node: DOMNode, _ selector: String) -> [String] {
        node.querySelectorAll(selector).map { $0.tagName ?? "" }
    }

    @MainActor
    private func evalString(_ env: JeffJSEnvironment, _ js: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        switch env.eval(js) {
        case .success(let value): return value ?? "undefined"
        case .exception(let message):
            XCTFail("JS threw: \(message) — while evaluating: \(js)", file: file, line: line)
            return "<exception>"
        }
    }

    @MainActor
    private func makeEnvironment() -> JeffJSEnvironment {
        JeffJSEnvironment(configuration: .init(viewportWidth: 390, viewportHeight: 844))
    }

    // MARK: - 1. <noscript> is raw text when scripting is enabled

    /// The whole of apple.com's duplicated `picture` elements: with scripting
    /// on, `<noscript>` is a RAWTEXT element, so its markup is one text node
    /// and produces no elements at all.
    func testNoscriptIsRawTextWhenScriptingEnabled() {
        let doc = parse("<!doctype html><body><noscript><picture class=static><source srcset=a.jpg><img src=b.jpg></picture></noscript>")
        guard let noscript = doc.querySelector("noscript") else { return XCTFail("no <noscript>") }
        XCTAssertEqual(noscript.children.count, 1)
        XCTAssertEqual(noscript.children.first?.nodeType, .text)
        XCTAssertEqual(doc.querySelectorAll("picture").count, 0)
        XCTAssertEqual(doc.querySelectorAll("img").count, 0)
        XCTAssertEqual(doc.querySelectorAll("source").count, 0)
        XCTAssertTrue((noscript.children.first?.textContent ?? "").contains("<picture class=static>"))
    }

    /// Nested markup inside `<noscript>` never closes it early either — only
    /// `</noscript>` does.
    func testNoscriptRawTextSurvivesNestedMarkup() {
        let doc = parse("<!doctype html><body><noscript><div><span>x</span></div></noscript><p>after")
        XCTAssertEqual(doc.querySelectorAll("div").count, 0)
        XCTAssertEqual(doc.querySelectorAll("span").count, 0)
        XCTAssertEqual(doc.querySelector("p")?.textDescendants, "after")
    }

    /// `<noscript>` in `<head>` is raw text too, so a `<link>` inside it is not
    /// a real element.
    func testNoscriptInHeadIsRawText() {
        let doc = parse("<!doctype html><html><head><noscript><link rel=stylesheet href=a.css></noscript></head><body>y")
        XCTAssertEqual(doc.querySelectorAll("link").count, 0)
        XCTAssertNotNil(doc.querySelector("head > noscript"))
    }

    /// With scripting disabled the contents are parsed normally, which is what
    /// a text-mode / no-JS parse wants.
    func testNoscriptParsesNormallyWhenScriptingDisabled() {
        let doc = parse("<!doctype html><body><noscript><picture><img src=b.jpg></picture></noscript>", scripting: false)
        XCTAssertEqual(doc.querySelectorAll("picture").count, 1)
        XCTAssertEqual(doc.querySelectorAll("img").count, 1)
    }

    // MARK: - 2. Tokenizer states

    func testScriptDataKeepsMarkupAsTextAndEndsAtScriptEndTag() {
        let doc = parse("<body><script>var s = \"<b>not a tag</b>\";</script><p>after")
        XCTAssertEqual(doc.querySelectorAll("b").count, 0)
        XCTAssertEqual(doc.querySelector("script")?.rawTextDescendants, "var s = \"<b>not a tag</b>\";")
        XCTAssertEqual(doc.querySelector("p")?.textDescendants, "after")
    }

    /// A `</script` inside a string still ends the element — the tokenizer's
    /// script data state has no idea about JS string literals, which is why
    /// `var s = "</script>"` breaks a real page.
    func testScriptEndsAtClosingScriptInsideAStringLiteral() {
        let doc = parse("<body><script>var s = \"</script>\";</script><p>after")
        XCTAssertEqual(doc.querySelector("script")?.rawTextDescendants, "var s = \"")
        XCTAssertTrue((doc.querySelector("body")?.textDescendants ?? "").contains("\";"))
    }

    /// `</scr` + `ipt` is not the appropriate end tag, so it stays text.
    func testScriptIgnoresNonMatchingEndTagPrefix() {
        let doc = parse("<body><script>var s = \"</scr\" + \"ipt>\";</script><p>after")
        XCTAssertEqual(doc.querySelector("script")?.rawTextDescendants, "var s = \"</scr\" + \"ipt>\";")
    }

    /// `<!--` opens the script data escape ladder; `<script` inside it opens
    /// the double escape where `</script>` no longer closes the element, and
    /// `-->` drops straight back to the plain script data state.
    func testScriptDataDoubleEscapeLadder() {
        let source = "<!-- <script> var x = 1; </script> --> after();"
        let doc = parse("<body><script>\(source)</script><p>tail")
        XCTAssertEqual(doc.querySelector("script")?.rawTextDescendants, source)
        XCTAssertEqual(doc.querySelector("p")?.textDescendants, "tail")
    }

    func testStyleIsRawText() {
        let doc = parse("<body><style>a::after { content: \"<b>\" } </style><p>x")
        XCTAssertEqual(doc.querySelectorAll("b").count, 0)
        XCTAssertEqual(doc.querySelector("style")?.rawTextDescendants, "a::after { content: \"<b>\" } ")
    }

    func testRawTextElements() {
        for tag in ["xmp", "iframe", "noembed", "noframes"] {
            let doc = parse("<body><\(tag)><b>raw</b></\(tag)>")
            XCTAssertEqual(doc.querySelectorAll("b").count, 0, "\(tag) should be RAWTEXT")
            XCTAssertEqual(doc.querySelector(tag)?.rawTextDescendants, "<b>raw</b>", "\(tag)")
        }
    }

    /// RCDATA: entities are decoded, tags are not.
    func testTextareaAndTitleAreRCDATA() {
        let doc = parse("<head><title>&lt;b&gt;&amp;</title></head><body><textarea>&amp;<b>x</b></textarea>")
        XCTAssertEqual(doc.querySelector("title")?.rawTextDescendants, "<b>&")
        XCTAssertEqual(doc.querySelectorAll("b").count, 0)
        XCTAssertEqual(doc.querySelector("textarea")?.rawTextDescendants, "&<b>x</b>")
    }

    /// A newline immediately after `<textarea>`/`<pre>` is dropped.
    func testLeadingNewlineAfterTextareaAndPreIsDropped() {
        XCTAssertEqual(parse("<body><textarea>\nfirst</textarea>").querySelector("textarea")?.rawTextDescendants, "first")
        XCTAssertEqual(parse("<body><pre>\ncode</pre>").querySelector("pre")?.rawTextDescendants, "code")
        // Only the *first* newline — and a `&#10;` reference produces the same
        // character token, so it is dropped too.
        XCTAssertEqual(parse("<body><pre>\n\ncode</pre>").querySelector("pre")?.rawTextDescendants, "\ncode")
        XCTAssertEqual(parse("<body><pre>&#10;code</pre>").querySelector("pre")?.rawTextDescendants, "code")
    }

    func testPlaintextSwallowsTheRestOfTheDocument() {
        let doc = parse("<body><plaintext><p>never an element</p>")
        XCTAssertEqual(doc.querySelectorAll("p").count, 0)
        XCTAssertEqual(doc.querySelector("plaintext")?.rawTextDescendants, "<p>never an element</p>")
    }

    /// `<![CDATA[…]]>` is a CDATA section only inside foreign content; in HTML
    /// content it is a bogus comment whose data starts with `[CDATA[`.
    func testCDATAOnlyInForeignContent() {
        let foreign = parse("<body><svg><![CDATA[raw <b> text]]></svg>")
        XCTAssertEqual(foreign.querySelector("svg")?.rawTextDescendants, "raw <b> text")
        XCTAssertEqual(foreign.querySelectorAll("b").count, 0)

        let html = parse("<body><![CDATA[x]]>")
        let comment = html.querySelector("body")?.children.first
        XCTAssertEqual(comment?.nodeType, .comment)
        XCTAssertEqual(comment?.textContent, "[CDATA[x]]")
    }

    /// `<!-->`, `<!--->`, `--!>` and bogus comments (§13.2.5.43–13.2.5.51).
    func testCommentEdgeCases() {
        func firstComment(_ html: String) -> String? {
            parse("<body>\(html)").querySelector("body")?.children.first(where: { $0.nodeType == .comment })?.textContent
        }
        XCTAssertEqual(firstComment("<!-->"), "")
        XCTAssertEqual(firstComment("<!--->"), "")
        XCTAssertEqual(firstComment("<!---->"), "")
        XCTAssertEqual(firstComment("<!--a--!>"), "a")
        XCTAssertEqual(firstComment("<!--a--->"), "a-")
        XCTAssertEqual(firstComment("<!--a--b-->"), "a--b")
        XCTAssertEqual(firstComment("<!c>"), "c")            // incorrectly-opened-comment
        XCTAssertEqual(firstComment("<?pi>"), "?pi")          // the `?` is part of the data
        XCTAssertEqual(firstComment("<!--unterminated"), "unterminated")
        // `</>` is dropped entirely rather than becoming a comment.
        XCTAssertNil(firstComment("</>"))
    }

    // MARK: - DOCTYPE and compatMode

    func testQuirksModeDetermination() {
        XCTAssertEqual(parse("<!doctype html><p>x").compatMode, "CSS1Compat")
        XCTAssertEqual(parse("<!DOCTYPE HTML><p>x").quirksMode, .noQuirks)
        // No DOCTYPE at all — news.ycombinator.com's situation.
        XCTAssertEqual(parse("<html><body><p>x").quirksMode, .quirks)
        XCTAssertEqual(parse("<html><body><p>x").compatMode, "BackCompat")
        // A DOCTYPE that is not `html`.
        XCTAssertEqual(parse("<!doctype xml><p>x").quirksMode, .quirks)
        // Legacy public identifiers.
        XCTAssertEqual(parse("<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.0 Transitional//EN\">").quirksMode, .quirks)
        XCTAssertEqual(
            parse("<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\">").quirksMode,
            .quirks,
            "no system identifier -> quirks"
        )
        XCTAssertEqual(
            parse("<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\" \"http://www.w3.org/TR/html4/loose.dtd\">").quirksMode,
            .limitedQuirks,
            "with a system identifier -> limited quirks"
        )
        XCTAssertEqual(
            parse("<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Transitional//EN\" \"x\">").quirksMode,
            .limitedQuirks
        )
        XCTAssertEqual(parse("<!DOCTYPE html SYSTEM \"about:legacy-compat\"><p>x").quirksMode, .noQuirks)
        // A DOCTYPE the tokenizer had to bail out of forces quirks.
        XCTAssertEqual(parse("<!DOCTYPE html PUBLIC>").quirksMode, .quirks)
    }

    /// Only a DOCTYPE at the very start counts; one after markup is ignored
    /// (and the document is already in quirks mode by then).
    func testDoctypeAfterMarkupIsIgnored() {
        XCTAssertEqual(parse("<p>x<!doctype html>").quirksMode, .quirks)
    }

    // MARK: - Attributes

    func testUnquotedAttributeValueKeepsSlashes() {
        // `/` is an ordinary character in an unquoted value, so the href here
        // is "/foo/" and the element is not self-closing.
        let doc = parse("<body><a href=/foo/ class=b>x</a>")
        XCTAssertEqual(doc.querySelector("a")?.attributes["href"], "/foo/")
        XCTAssertEqual(doc.querySelector("a")?.attributes["class"], "b")
        XCTAssertEqual(doc.querySelector("a")?.textDescendants, "x")
    }

    func testDuplicateAttributesKeepTheFirst() {
        let doc = parse("<body><p a=1 a=2 A=3 b=4>x</p>")
        XCTAssertEqual(doc.querySelector("p")?.attributes["a"], "1")
        XCTAssertEqual(doc.querySelector("p")?.attributes["b"], "4")
    }

    func testAttributeNameAndValueSpacing() {
        let doc = parse("<body><a b = \"c\" d =e f= g >x</a>")
        let a = doc.querySelector("a")
        XCTAssertEqual(a?.attributes["b"], "c")
        XCTAssertEqual(a?.attributes["d"], "e")
        XCTAssertEqual(a?.attributes["f"], "g")
    }

    /// Ambiguous ampersand: in an attribute a semicolon-less name followed by
    /// an alphanumeric or `=` is left alone; in text it is still expanded.
    func testEntityDecodingInAttributesUsesTheLegacyRules() {
        XCTAssertEqual(parse("<body><p title='a&ampb'>").querySelector("p")?.attributes["title"], "a&ampb")
        XCTAssertEqual(parse("<body><p title='a&amp;b'>").querySelector("p")?.attributes["title"], "a&b")
        XCTAssertEqual(parse("<body><p title='a&amp'>").querySelector("p")?.attributes["title"], "a&")
        XCTAssertEqual(parse("<body><p title='a&amp=b'>").querySelector("p")?.attributes["title"], "a&amp=b")
        XCTAssertEqual(parse("<body><p title='&notit;'>").querySelector("p")?.attributes["title"], "&notit;")
        XCTAssertEqual(parse("<body><p title='&not;'>").querySelector("p")?.attributes["title"], "\u{00AC}")
    }

    func testEntityDecodingInText() {
        let body = { (html: String) in self.parse("<body>\(html)").querySelector("body")?.textDescendants }
        XCTAssertEqual(body("&amp;amp;"), "&amp;")
        XCTAssertEqual(body("&ampx"), "&x")            // legacy `&amp` then a literal x
        XCTAssertEqual(body("&notit;"), "\u{00AC}it;") // longest match is the legacy `&not`
        XCTAssertEqual(body("&AMP;&AMP"), "&&")
        XCTAssertEqual(body("&nbsp;"), "\u{00A0}")
        XCTAssertEqual(body("&bogus;"), "&bogus;")
        XCTAssertEqual(body("&CounterClockwiseContourIntegral;"), "\u{2233}")
    }

    /// Numeric references: the Windows-1252 remap, surrogates and
    /// out-of-range values (§13.2.5.80).
    func testNumericCharacterReferences() {
        let body = { (html: String) in self.parse("<body>\(html)").querySelector("body")?.textDescendants }
        XCTAssertEqual(body("&#65;&#x42;&#X43;"), "ABC")
        XCTAssertEqual(body("&#0065;"), "A")
        XCTAssertEqual(body("&#65"), "A")                   // missing semicolon still decodes
        XCTAssertEqual(body("&#153;"), "\u{2122}")          // C1 -> Windows-1252 trademark
        XCTAssertEqual(body("&#128;"), "\u{20AC}")          // euro
        XCTAssertEqual(body("&#x80;"), "\u{20AC}")
        XCTAssertEqual(body("&#0;"), "\u{FFFD}")
        XCTAssertEqual(body("&#xD800;"), "\u{FFFD}")        // lone surrogate
        XCTAssertEqual(body("&#x110000;"), "\u{FFFD}")      // out of range
        XCTAssertEqual(body("&#99999999999999;"), "\u{FFFD}")
        XCTAssertEqual(body("&#;"), "&#;")                  // no digits: literal
    }

    /// NUL is dropped in HTML content, becomes U+FFFD in RAWTEXT/RCDATA and in
    /// foreign content, and becomes U+FFFD in tag and attribute names.
    func testNulHandling() {
        XCTAssertEqual(parse("<body>a\0b").querySelector("body")?.textDescendants, "ab")
        XCTAssertEqual(parse("<body><style>a\0b</style>").querySelector("style")?.rawTextDescendants, "a\u{FFFD}b")
        XCTAssertEqual(parse("<body><textarea>a\0b</textarea>").querySelector("textarea")?.rawTextDescendants, "a\u{FFFD}b")
        XCTAssertEqual(parse("<body><svg>a\0b</svg>").querySelector("svg")?.rawTextDescendants, "a\u{FFFD}b")
        XCTAssertEqual(parse("<body><p a=\"x\0y\">").querySelector("p")?.attributes["a"], "x\u{FFFD}y")
    }

    // MARK: - 3. Tree construction

    /// The adoption agency: `<b><i></b></i>` reopens the `<i>` outside the
    /// `<b>` rather than nesting the close tags.
    func testAdoptionAgencyReordersMisnestedFormatting() {
        let doc = parse("<!doctype html><body><p><b><i>x</b>y</i>z")
        XCTAssertEqual(dump(doc), """
        | <html>
        |   <head>
        |   <body>
        |     <p>
        |       <b>
        |         <i>
        |           "x"
        |       <i>
        |         "y"
        |       "z"

        """)
    }

    /// An `<a>` inside an `<a>` closes the outer one (§13.2.6.4.7's special
    /// case) instead of nesting.
    func testAnchorInsideAnchorClosesTheOuterOne() {
        let doc = parse("<!doctype html><body><a href=1>one<a href=2>two</a>")
        let anchors = doc.querySelectorAll("a")
        XCTAssertEqual(anchors.count, 2)
        XCTAssertEqual(anchors.map { $0.attributes["href"] ?? "" }, ["1", "2"])
        XCTAssertEqual(anchors[0].parent?.tagName, "body")
        XCTAssertEqual(anchors[1].parent?.tagName, "body", "the second <a> is a sibling, not a child")
        XCTAssertEqual(anchors[0].textDescendants, "one")
        XCTAssertEqual(anchors[1].textDescendants, "two")
    }

    /// `</b>` inside the `<p>` it opened: the adoption agency splits the `<b>`
    /// so the paragraph keeps its own copy.
    func testFormattingIsSplitAcrossBlockBoundaries() {
        let doc = parse("<!doctype html><body><b>1<p>2</b>3")
        XCTAssertEqual(doc.querySelectorAll("b").count, 2)
        XCTAssertEqual(doc.querySelector("p > b")?.textDescendants, "2")
        XCTAssertEqual(doc.querySelector("p")?.textDescendants, "23")
        XCTAssertEqual(doc.querySelectorAll("b")[0].parent?.tagName, "body")

        // A properly nested `<p>` keeps the single `<b>` around it.
        let nested = parse("<!doctype html><body><b>1<p>2</p>3</b>")
        XCTAssertEqual(nested.querySelectorAll("b").count, 1)
        XCTAssertEqual(nested.querySelector("b > p")?.textDescendants, "2")
    }

    func testImpliedEndTagsForParagraphsAndListItems() {
        let paragraphs = parse("<!doctype html><body><p>a<div>b</div>")
        XCTAssertEqual(paragraphs.querySelector("p")?.textDescendants, "a")
        XCTAssertEqual(paragraphs.querySelector("div")?.parent?.tagName, "body")

        let list = parse("<!doctype html><body><ul><li>a<li>b</ul>")
        XCTAssertEqual(list.querySelectorAll("li").count, 2)
        XCTAssertEqual(list.querySelectorAll("li").map { $0.textDescendants }, ["a", "b"])
        XCTAssertEqual(list.querySelector("li")?.parent?.tagName, "ul")

        let definitions = parse("<!doctype html><body><dl><dt>a<dd>b<dt>c</dl>")
        XCTAssertEqual(tags(definitions, "dl > *"), ["dt", "dd", "dt"])

        let options = parse("<!doctype html><body><select><option>a<option>b</select>")
        XCTAssertEqual(options.querySelectorAll("option").count, 2)
        XCTAssertEqual(tags(options, "select > *"), ["option", "option"])

        let rows = parse("<!doctype html><table><tr><td>1<td>2<tr><td>3</table>")
        XCTAssertEqual(rows.querySelectorAll("tr").count, 2)
        XCTAssertEqual(rows.querySelectorAll("td").count, 3)
        XCTAssertEqual(rows.querySelectorAll("tr")[0].childElements.count, 2)
    }

    /// `<p>` is only closed within *button scope*, so a `<p>` inside a
    /// `<button>` is untouched by the button's own scope boundary.
    func testParagraphInsideButton() {
        let doc = parse("<!doctype html><body><button><p>inside</p></button>")
        XCTAssertEqual(doc.querySelector("button > p")?.textDescendants, "inside")

        let nested = parse("<!doctype html><body><p>a<button><p>b")
        XCTAssertEqual(nested.querySelectorAll("p").count, 2)
        XCTAssertEqual(nested.querySelector("button > p")?.textDescendants, "b")
    }

    /// Foster parenting: text and non-table elements inside a `<table>` are
    /// moved *before* the table.
    func testFosterParenting() {
        let doc = parse("<!doctype html><body><table>text<tr><td>cell</table>")
        XCTAssertEqual(dump(doc), """
        | <html>
        |   <head>
        |   <body>
        |     "text"
        |     <table>
        |       <tbody>
        |         <tr>
        |           <td>
        |             "cell"

        """)

        let elements = parse("<!doctype html><body><table><b>bold</b><tr><td>c</table>")
        XCTAssertEqual(elements.querySelector("b")?.parent?.tagName, "body")
        XCTAssertNil(elements.querySelector("table b"))

        // Whitespace-only text stays inside the table.
        let whitespace = parse("<!doctype html><body><table>\n  <tr><td>c</table>")
        XCTAssertEqual(whitespace.querySelector("body")?.children.first?.tagName, "table")
    }

    func testTableSectionsAndImplicitTbody() {
        let doc = parse("<!doctype html><body><table><tr><td>a</table>")
        XCTAssertEqual(doc.querySelector("table")?.childElements.first?.tagName, "tbody")
        XCTAssertNotNil(doc.querySelector("table > tbody > tr > td"))

        let full = parse("<!doctype html><table><caption>c</caption><colgroup><col></colgroup><thead><tr><th>h</thead><tbody><tr><td>d</table>")
        XCTAssertEqual(tags(full, "table > *"), ["caption", "colgroup", "thead", "tbody"])
        XCTAssertEqual(full.querySelector("caption")?.textDescendants, "c")
    }

    /// Duplicate `<html>`/`<head>`/`<body>` tags merge their attributes into
    /// the element that already exists.
    func testDuplicateHtmlHeadBodyTagsMergeAttributes() {
        let doc = parse("<!doctype html><html lang=en><head></head><body id=b><html dir=rtl><body class=c>x")
        XCTAssertEqual(doc.querySelectorAll("html").count, 1)
        XCTAssertEqual(doc.querySelectorAll("head").count, 1)
        XCTAssertEqual(doc.querySelectorAll("body").count, 1)
        let html = doc.querySelector("html")
        XCTAssertEqual(html?.attributes["lang"], "en")
        XCTAssertEqual(html?.attributes["dir"], "rtl")
        let body = doc.querySelector("body")
        XCTAssertEqual(body?.attributes["id"], "b")
        XCTAssertEqual(body?.attributes["class"], "c")
    }

    /// An existing attribute is never overwritten by the duplicate tag.
    func testDuplicateBodyDoesNotOverwriteAttributes() {
        let doc = parse("<!doctype html><body id=first><body id=second>x")
        XCTAssertEqual(doc.querySelector("body")?.attributes["id"], "first")
    }

    func testImpliedHtmlHeadAndBodyAlwaysExist() {
        for source in ["", "<!doctype html>", "x", "<p>x", "<!-- c -->"] {
            let doc = parse(source)
            XCTAssertNotNil(doc.querySelector("html"), "source: \(source)")
            XCTAssertNotNil(doc.querySelector("head"), "source: \(source)")
            XCTAssertNotNil(doc.querySelector("body"), "source: \(source)")
        }
    }

    /// `<template>` uses its own insertion mode, so table markup inside it
    /// survives instead of being foster-parented away.
    func testTemplateContentKeepsTableMarkup() {
        let doc = parse("<!doctype html><body><template><tr><td>x</td></tr></template>")
        guard let template = doc.querySelector("template") else { return XCTFail("no <template>") }
        XCTAssertEqual(template.querySelectorAll("tr").count, 1)
        XCTAssertEqual(template.querySelector("td")?.textDescendants, "x")
        XCTAssertNil(doc.querySelector("table"))
    }

    func testTemplateInHeadAndNestedTemplates() {
        let doc = parse("<!doctype html><template><template><p>deep</p></template></template>")
        XCTAssertEqual(doc.querySelectorAll("template").count, 2)
        XCTAssertEqual(doc.querySelector("template template > p")?.textDescendants, "deep")
    }

    /// The form pointer: a second `<form>` while one is open is dropped.
    func testNestedFormIsIgnored() {
        let doc = parse("<!doctype html><body><form action=a><input name=x><form action=b><input name=y></form>")
        XCTAssertEqual(doc.querySelectorAll("form").count, 1)
        XCTAssertEqual(doc.querySelector("form")?.attributes["action"], "a")
        XCTAssertEqual(doc.querySelectorAll("input").count, 2)
    }

    /// A `<form>` directly inside a `<table>` is inserted but not pushed, so
    /// the rows are unaffected.
    func testFormInsideTable() {
        let doc = parse("<!doctype html><body><table><form action=a><tr><td>x</table>")
        XCTAssertEqual(doc.querySelectorAll("form").count, 1)
        XCTAssertNotNil(doc.querySelector("table > tbody > tr > td"))
    }

    func testSelectInsertionMode() {
        // Everything that is not option/optgroup/script is dropped inside a select.
        let doc = parse("<!doctype html><body><select><option>1<div>nope</div><optgroup><option>2</select>")
        XCTAssertEqual(doc.querySelectorAll("div").count, 0)
        XCTAssertEqual(doc.querySelectorAll("option").count, 2)
        XCTAssertEqual(doc.querySelector("optgroup > option")?.textDescendants, "2")

        // An <input> closes the select and is inserted after it.
        let closed = parse("<!doctype html><body><select><option>1<input name=x>")
        XCTAssertEqual(closed.querySelector("input")?.parent?.tagName, "body")

        // A <select> inside a table cell still ends up in the cell.
        let table = parse("<!doctype html><table><tr><td><select><option>a</select></td></tr></table>")
        XCTAssertNotNil(table.querySelector("td > select > option"))
    }

    /// `<rb>`/`<rtc>` generate implied end tags; `<rp>`/`<rt>` do too but keep
    /// an open `<rtc>`.
    func testRubyImpliedEndTags() {
        let doc = parse("<!doctype html><body><ruby><rb>b<rt>t<rtc>c<rp>p</ruby>")
        XCTAssertEqual(tags(doc, "ruby > *"), ["rb", "rt", "rtc"])
        XCTAssertEqual(doc.querySelector("rtc > rp")?.textDescendants, "p")
    }

    // MARK: - Foreign content

    /// SVG attribute names keep their authored case, and a lowercase alias is
    /// registered so `attributes["viewbox"]` keeps resolving.
    func testForeignContentPreservesAttributeCase() {
        let doc = parse("<!doctype html><body><svg viewBox=\"0 0 24 24\" preserveAspectRatio=\"none\"><circle cx=1/></svg>")
        guard let svg = doc.querySelector("svg") else { return XCTFail("no <svg>") }
        XCTAssertEqual(svg.attributes["viewBox"], "0 0 24 24")
        XCTAssertEqual(svg.attributes["viewbox"], "0 0 24 24", "lowercase alias must keep working")
        XCTAssertEqual(svg.attributes["preserveAspectRatio"], "none")
        XCTAssertEqual(svg.attributes["preserveaspectratio"], "none")
        // The alias is hidden from enumeration so it never doubles up.
        XCTAssertEqual(svg.enumerableAttributes.count, 2)
        XCTAssertEqual(svg.namespaceURI, DOMNode.svgNamespace)
        XCTAssertEqual(doc.querySelector("circle")?.namespaceURI, DOMNode.svgNamespace)
    }

    /// The source spelling does not matter: `VIEWBOX` and `viewbox` both
    /// become `viewBox`.
    func testForeignAttributeCaseIsNormalisedFromAnySpelling() {
        for spelling in ["VIEWBOX", "viewbox", "ViewBox"] {
            let doc = parse("<body><svg \(spelling)=\"1 2 3 4\"></svg>")
            XCTAssertEqual(doc.querySelector("svg")?.attributes["viewBox"], "1 2 3 4", spelling)
            XCTAssertEqual(doc.querySelector("svg")?.attributes["viewbox"], "1 2 3 4", spelling)
        }
    }

    func testForeignElementNamesKeepTheirCase() {
        let doc = parse("<body><svg><linearGradient/><clipPath/><foreignObject><div>html</div></foreignObject></svg>")
        XCTAssertNotNil(doc.querySelector("svg")?.children.first(where: { $0.tagName == "linearGradient" }))
        XCTAssertNotNil(doc.querySelector("svg")?.children.first(where: { $0.tagName == "clipPath" }))
        // An HTML integration point puts HTML elements back in the HTML namespace.
        let div = doc.querySelectorAll("div").first
        XCTAssertEqual(div?.namespaceURI, nil)
        XCTAssertEqual(div?.textDescendants, "html")
    }

    func testMathMLIntegrationPoints() {
        let doc = parse("<body><math><mi>x</mi><annotation-xml encoding=\"text/html\"><p>y</p></annotation-xml></math>")
        XCTAssertEqual(doc.querySelector("math")?.namespaceURI, DOMNode.mathmlNamespace)
        let p = doc.querySelectorAll("p").first
        XCTAssertEqual(p?.namespaceURI, nil, "text/html annotation-xml is an HTML integration point")
        XCTAssertEqual(p?.textDescendants, "y")
    }

    /// A breakout tag (`<p>`, `<div>`, …) inside foreign content pops back to
    /// HTML rules instead of becoming an SVG element.
    func testForeignContentBreakout() {
        let doc = parse("<!doctype html><body><svg><circle/><p>out</p>")
        XCTAssertEqual(doc.querySelector("circle")?.namespaceURI, DOMNode.svgNamespace)
        let p = doc.querySelector("p")
        XCTAssertEqual(p?.namespaceURI, nil)
        XCTAssertEqual(p?.parent?.tagName, "body")
    }

    // MARK: - Odds and ends the spec calls out by name

    func testBrEndTagBecomesAStartTag() {
        let doc = parse("<!doctype html><body><div>x</div></br>")
        XCTAssertEqual(doc.querySelectorAll("br").count, 1)
        XCTAssertEqual(doc.querySelector("br")?.parent?.tagName, "body")
    }

    func testImageBecomesImg() {
        let doc = parse("<!doctype html><body><image src=a.png>")
        XCTAssertEqual(doc.querySelectorAll("img").count, 1)
        XCTAssertEqual(doc.querySelectorAll("image").count, 0)
        XCTAssertEqual(doc.querySelector("img")?.attributes["src"], "a.png")
    }

    func testStrayEndTagsAreIgnored() {
        let doc = parse("<!doctype html><body><p>a</p></p></div></span>b")
        XCTAssertEqual(doc.querySelector("body")?.textDescendants, "ab")
        XCTAssertEqual(doc.querySelectorAll("p").count, 2, "the stray </p> opens and closes an empty one")
    }

    // MARK: - Fragment parsing (innerHTML)

    func testFragmentParsingUsesTheContextElement() {
        let rows = HTMLParser.parseFragment("<tr><td>a</td></tr>", context: "table")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.tagName, "tbody")
        XCTAssertEqual(rows.first?.querySelector("td")?.textDescendants, "a")

        let inBody = HTMLParser.parseFragment("<tr><td>a</td></tr>", context: "tbody")
        XCTAssertEqual(inBody.first?.tagName, "tr")

        let cells = HTMLParser.parseFragment("<td>a</td><td>b</td>", context: "tr")
        XCTAssertEqual(cells.map { $0.tagName ?? "" }, ["td", "td"])

        // Without a table context the rows are dropped and only the text survives.
        let loose = HTMLParser.parseFragment("<tr><td>a</td></tr>", context: "div")
        XCTAssertEqual(loose.count, 1)
        XCTAssertEqual(loose.first?.nodeType, .text)
    }

    func testFragmentParsingInRawTextContext() {
        let title = HTMLParser.parseFragment("<b>x</b>", context: "title")
        XCTAssertEqual(title.count, 1)
        XCTAssertEqual(title.first?.nodeType, .text)
        XCTAssertEqual(title.first?.textContent, "<b>x</b>")
    }

    // MARK: - 4. Performance

    /// The parser has to stay linear: doubling a 300 KB document must not do
    /// much more than double the work. (apple.com is 305 KB.)
    func testParsingStaysLinearOnALargeDocument() {
        let block = """
        <section class="row" data-index="1"><div class="col"><h2>Heading</h2>\
        <p>Some <b>bold</b> and <i>italic</i> text with an &amp; entity and a \
        <a href="/link/path?a=1&amp;b=2">link</a>.</p><ul><li>one<li>two<li>three</ul>\
        <table><tr><td>a<td>b<tr><td>c<td>d</table>\
        <svg viewBox="0 0 10 10"><circle cx="5" cy="5" r="4"/></svg>\
        <script>var x = "</scr" + "ipt>"; /* <!-- <script> --> */</script>\
        <noscript><picture><img src="fallback.png"></picture></noscript></div></section>
        """
        var small = "<!doctype html><html><body>"
        while small.utf8.count < 300_000 { small += block }
        small += "</body></html>"
        let large = small + small

        func time(_ html: String) -> TimeInterval {
            let start = Date()
            let doc = HTMLParser.parse(html)
            XCTAssertNotNil(doc.querySelector("body"))
            return Date().timeIntervalSince(start)
        }

        _ = HTMLParser.parse("&amp;")   // warm the named-entity table
        let smallTime = max(time(small), 0.001)
        let largeTime = time(large)
        let ratio = largeTime / smallTime
        XCTAssertLessThan(
            ratio, 3.0,
            "doubling the input took \(String(format: "%.1fx", ratio)) as long — the parser is not linear"
        )

        // The noscript/script raw-text handling has to hold at this size too.
        let doc = HTMLParser.parse(small)
        XCTAssertEqual(doc.querySelectorAll("picture").count, 0)
        XCTAssertEqual(doc.querySelectorAll("svg circle").count, doc.querySelectorAll("section").count)
    }

    // MARK: - 5. Through JeffJSEnvironment

    @MainActor
    func testInnerHTMLUsesTheContextElement() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          var t = document.createElement('table');
          t.innerHTML = '<tr><td>a</td><td>b</td></tr>';
          return [t.querySelectorAll('tr').length, t.querySelectorAll('td').length,
                  t.children[0].tagName.toLowerCase()].join(',');
        })()
        """), "1,2,tbody")

        XCTAssertEqual(evalString(env, """
        (function() {
          var b = document.createElement('tbody');
          b.innerHTML = '<tr><td>a</td></tr>';
          return b.children[0].tagName.toLowerCase();
        })()
        """), "tr")

        XCTAssertEqual(evalString(env, """
        (function() {
          var d = document.createElement('div');
          d.innerHTML = '<tr><td>a</td></tr>';
          return String(d.querySelectorAll('tr').length) + ',' + d.textContent;
        })()
        """), "0,a")
    }

    @MainActor
    func testNoscriptThroughTheDOMBridge() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          document.body.innerHTML = '<noscript><picture><img src="a.png"></picture></noscript><p>after</p>';
          return [document.querySelectorAll('picture').length,
                  document.querySelectorAll('img').length,
                  document.querySelector('noscript').childNodes.length,
                  document.querySelector('p').textContent].join(',');
        })()
        """), "0,0,1,after")
    }

    @MainActor
    func testAdoptionAgencyThroughTheDOMBridge() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          document.body.innerHTML = '<p><b><i>x</b>y</i>z</p>';
          return [document.querySelectorAll('b').length,
                  document.querySelectorAll('i').length,
                  document.querySelectorAll('b > i').length,
                  document.querySelector('p').textContent].join(',');
        })()
        """), "1,2,1,xyz")
    }

    @MainActor
    func testDocumentCompatModeIsExposed() {
        let env = makeEnvironment()
        // A synthetic document with no DOCTYPE is still standards mode here;
        // the value comes from the parsed root rather than a source-text guess.
        XCTAssertEqual(evalString(env, "document.compatMode"), "CSS1Compat")
        XCTAssertEqual(HTMLParser.parse("<html><body>x").compatMode, "BackCompat")
        XCTAssertEqual(HTMLParser.parse("<!doctype html><body>x").compatMode, "CSS1Compat")
    }

    @MainActor
    func testForeignContentAttributeCaseThroughTheDOMBridge() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          document.body.innerHTML = '<svg viewBox="0 0 24 24"><circle cx="1"/></svg>';
          var svg = document.querySelector('svg');
          return [svg.getAttribute('viewBox'), svg.getAttribute('viewbox')].join('|');
        })()
        """), "0 0 24 24|0 0 24 24")
    }

    @MainActor
    func testTableFosterParentingThroughTheDOMBridge() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function() {
          document.body.innerHTML = '<table>stray<tr><td>cell</td></tr></table>';
          return [document.body.childNodes[0].nodeType,
                  document.body.childNodes[0].textContent,
                  document.querySelectorAll('table td').length].join(',');
        })()
        """), "3,stray,1")
    }
}
