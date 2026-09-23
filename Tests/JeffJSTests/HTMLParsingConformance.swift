// HTMLParsingConformance.swift
// JeffJS — conformance group "HTMLParsing": the HTML Standard §13.2 parser and
// §13.3 serialiser as the DOM bridge exposes them (the app's spec-ladder rung
// 14 defects 14-1 … 14-8): input-stream preprocessing, EOF inside tags,
// comments and DOCTYPEs, DocumentType nodes, DOMParser documents (scripting
// disabled, their own compatMode), createHTMLDocument, namespaces and
// createElementNS, template contents, fragment-serialisation escaping, and
// textarea's value.
//
// Runs inside EngineTests/testConformance. The DOM bridge is main-actor bound,
// so the group builds a JeffJSEnvironment on the main thread.

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    /// Helpers every case can use: `el(tag, html)`, `dp(src)` (a DOMParser
    /// document via the bridge's native entry point), `names(list)`.
    static let htmlParsingPrelude = """
        var SVGNS = 'http://www.w3.org/2000/svg', MATHNS = 'http://www.w3.org/1998/Math/MathML', XHTMLNS = 'http://www.w3.org/1999/xhtml';
        function el(tag, html) { var e = document.createElement(tag); if (html != null) e.innerHTML = html; return e; }
        function dp(src) { return __nativeParseHTMLDocument(src); }
        function names(list) { var o = []; for (var i = 0; i < list.length; i++) o.push(list[i].nodeName); return o.join(','); }
        """

    /// (name, JS expression that must evaluate to `true`).
    static let htmlParsingCases: [(String, String)] = [
        // ---- 14-1 input stream preprocessing (§13.2.3.5)
        ("CRLF and lone CR become LF before tokenising", """
            (function(){ var d = el('div', 'a\\r\\nb\\rc\\n<pre>\\r\\nx</pre>');
              return d.firstChild.data === 'a\\nb\\nc\\n' && d.lastChild.firstChild.data === 'x'; })()
            """),
        ("CR in attribute values and comments is normalised", """
            (function(){ var d = el('div', '<p title="a\\r\\nb\\rc"></p><!--x\\r\\ny-->');
              return d.firstChild.getAttribute('title') === 'a\\nb\\nc' && d.lastChild.data === 'x\\ny'; })()
            """),
        ("&#13; still produces a CR", "el('div', 'a&#13;b').firstChild.data === 'a\\rb'"),

        // ---- 14-2 EOF inside tags, comments and DOCTYPEs (§13.2.5)
        ("EOF in an attribute value drops the tag", """
            (function(){ var d = el('div', 'x<a b=c'); return d.childNodes.length === 1 && d.firstChild.data === 'x'; })()
            """),
        ("EOF in a quoted value / tag name / end tag drops it", """
            el('div', 'x<div class="a').innerHTML === 'x' && el('div', 'x<spa').innerHTML === 'x' &&
            el('div', 'x</div').innerHTML === 'x' && el('div', 'x<br/').innerHTML === 'x'
            """),
        ("EOF after `</script ` drops the end tag; `</script` stays text", """
            el('div', '<script>a</script ').firstChild.textContent === 'a' &&
            el('div', '<script>a</script').firstChild.textContent === 'a</script'
            """),
        ("EOF in a comment: the closing dashes are not data", """
            el('div', '<!--a-').firstChild.data === 'a' && el('div', '<!--a--').firstChild.data === 'a' &&
            el('div', '<!--a---').firstChild.data === 'a-' && el('div', '<!--a--!').firstChild.data === 'a' &&
            el('div', '<!--').firstChild.data === '' && el('div', '<!---').firstChild.data === ''
            """),
        ("EOF / abrupt `>` in a DOCTYPE forces quirks", """
            dp('<!DOCTYPE html').compatMode === 'BackCompat' && dp('<!DOCTYPE html').doctype.name === 'html' &&
            dp('<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01//EN" "x').compatMode === 'BackCompat' &&
            dp('<!DOCTYPE html PUBLIC "abc>').compatMode === 'BackCompat' &&
            dp('<!DOCTYPE html SYSTEM "about:legacy-compat"').compatMode === 'BackCompat' &&
            dp('<!DOCTYPE html SYSTEM "about:legacy-compat">').compatMode === 'CSS1Compat' &&
            dp('<!DOCTYPE html>').compatMode === 'CSS1Compat'
            """),

        // ---- 14-3 DocumentType nodes (§13.2.6.4.1, DOM §4.6)
        ("the parser creates a DocumentType node", """
            (function(){ var d = dp('<!DOCTYPE html><p>x'), t = d.doctype;
              return t !== null && t.nodeType === 10 && t.nodeName === 'html' && t.name === 'html' &&
                t.publicId === '' && t.systemId === '' && d.childNodes.length === 2 && d.firstChild === t &&
                t.nextSibling === d.documentElement && t.parentNode === d && t.nodeValue === null; })()
            """),
        ("DOCTYPE public and system identifiers", """
            (function(){ var t = dp('<!DOCTYPE HTML PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd"><p>').doctype;
              return t.name === 'html' && t.publicId === '-//W3C//DTD XHTML 1.0 Transitional//EN' &&
                t.systemId === 'http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd'; })()
            """),
        ("comments before the DOCTYPE stay before it; no DOCTYPE -> null", """
            (function(){ var d = dp('<!--a--><!DOCTYPE html><!--b--><html>');
              return names(d.childNodes) === '#comment,html,#comment,HTML' && dp('<p>').doctype === null &&
                dp('<p>').firstChild.nodeName === 'HTML'; })()
            """),
        ("a second DOCTYPE is ignored", "names(dp('<!DOCTYPE html><!DOCTYPE foo><p>').childNodes) === 'html,HTML'"),
        ("document serialisation includes the DOCTYPE", """
            dp('<!DOCTYPE html><title>t</title>').innerHTML === '<!DOCTYPE html><html><head><title>t</title></head><body></body></html>'
            """),
        ("DocumentType clones", """
            (function(){ var t = dp('<!DOCTYPE html PUBLIC "p" "s">').doctype.cloneNode();
              return t.nodeType === 10 && t.name === 'html' && t.publicId === 'p' && t.systemId === 's'; })()
            """),
        ("document.doctype on the page document is a node or null", "document.doctype === null"),

        // ---- 14-4 DOMParser documents and createHTMLDocument
        ("DOMParser parses with scripting disabled: noscript content is markup", """
            (function(){ var n = dp('<!doctype html><body><noscript><b>x</b></noscript>').querySelector('noscript');
              return n.firstChild.nodeName === 'B' && n.firstChild.firstChild.data === 'x'; })()
            """),
        ("DOMParser in-head noscript (scripting disabled)", """
            (function(){ var d = dp('<!doctype html><head><noscript><link rel=x></noscript></head>');
              return d.head.firstChild.nodeName === 'NOSCRIPT' && d.head.firstChild.firstChild.nodeName === 'LINK'; })()
            """),
        ("DOMParser compatMode follows the document's own DOCTYPE", """
            [dp('<p>').compatMode, dp('<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN"><p>').compatMode,
             dp('<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd"><p>').compatMode,
             dp('<!DOCTYPE html>').compatMode].join('|') === 'BackCompat|BackCompat|CSS1Compat|CSS1Compat'
            """),
        ("DOMParser quirks decision shows in the tree (p/table)", """
            names(dp('<p><table>').body.childNodes) === 'P' && names(dp('<!DOCTYPE html><p><table>').body.childNodes) === 'P,TABLE'
            """),
        ("createHTMLDocument(title): doctype, title with a Text node, no-quirks", """
            (function(){ var d = document.implementation.createHTMLDocument('');
              d.body.innerHTML = '<p>x';
              return d.compatMode === 'CSS1Compat' && d.doctype.name === 'html' && d.firstChild === d.doctype &&
                names(d.documentElement.firstChild.childNodes) === 'TITLE' &&
                d.querySelector('title').childNodes.length === 1 && d.querySelector('title').firstChild.data === '' &&
                d.innerHTML === '<!DOCTYPE html><html><head><title></title></head><body><p>x</p></body></html>'; })()
            """),
        ("createHTMLDocument() without a title has no title element", """
            (function(){ var d = document.implementation.createHTMLDocument(), e = document.implementation.createHTMLDocument('T');
              return d.head.childNodes.length === 0 && e.title === 'T'; })()
            """),

        // ---- 14-5 namespaces
        ("parser namespaces: svg, foreignObject content, math, back to HTML", """
            (function(){ var d = el('div', '<svg><circle/><foreignObject><div></div></foreignObject></svg><math><mi></mi></math><p></p>');
              var s = d.firstChild, m = s.nextSibling;
              var list = [s, s.firstChild, s.lastChild, s.lastChild.firstChild, m, m.firstChild, m.nextSibling];
              return list.map(function (n) { var u = n.namespaceURI;
                return u === SVGNS ? 'svg' : u === MATHNS ? 'math' : u === XHTMLNS ? 'html' : String(u); }).join(' ') ===
                'svg svg svg html math math html'; })()
            """),
        ("tagName keeps foreign case; HTML is uppercased", """
            (function(){ var d = el('div', '<svg><foreignObject></foreignObject><clipPath></clipPath><linearGradient/></svg><div></div><my-el></my-el>');
              var s = d.firstChild;
              return [s.firstChild.tagName, s.nextSibling.tagName, s.nextSibling.nextSibling.tagName, s.childNodes[1].tagName,
                      s.lastChild.nodeName, s.lastChild.localName, s.tagName].join('|') ===
                'foreignObject|DIV|MY-EL|clipPath|linearGradient|linearGradient|svg'; })()
            """),
        ("createElementNS carries the namespace and the local name's case", """
            (function(){ var s = document.createElementNS(SVGNS, 'svg'), g = document.createElementNS(SVGNS, 'linearGradient'),
                  h = document.createElementNS(XHTMLNS, 'div'), n = document.createElementNS(null, 'Foo'),
                  m = document.createElementNS(MATHNS, 'mi'), p = document.createElementNS(SVGNS, 'svg:rect');
              return s.namespaceURI === SVGNS && s.tagName === 'svg' && g.tagName === 'linearGradient' && g.localName === 'linearGradient' &&
                h.namespaceURI === XHTMLNS && h.tagName === 'DIV' && n.namespaceURI === null && n.tagName === 'Foo' &&
                m.namespaceURI === MATHNS && p.localName === 'rect' && document.createElement('DIV').localName === 'div' &&
                document.createElement('div').namespaceURI === XHTMLNS; })()
            """),
        ("an svg context element fragment-parses as foreign content", """
            (function(){ var s = document.createElementNS(SVGNS, 'svg'); s.innerHTML = '<circle/><div>x</div>';
              return names(s.childNodes) === 'circle,DIV' && s.firstChild.namespaceURI === SVGNS &&
                s.lastChild.namespaceURI === XHTMLNS && s.lastChild.firstChild.data === 'x'; })()
            """),
        ("breakout from a parsed svg context (no re-dispatch loop)", """
            (function(){ var d = el('div', '<svg></svg>'); d.firstChild.innerHTML = '<rect/><p>q</p><g><b>z</b></g>';
              return names(d.firstChild.childNodes) === 'rect,P,g,B' && d.firstChild.childNodes[1].namespaceURI === XHTMLNS; })()
            """),
        ("svg context: <div>, <br>, text and nested svg don't recurse", """
            (function(){ var s = document.createElementNS(SVGNS, 'svg'); s.innerHTML = 'a<br>b<div>c</div><g>d</g><p>e';
              var ok = names(s.childNodes) === '#text,BR,#text,DIV,g,P' && s.childNodes[1].namespaceURI === XHTMLNS &&
                s.childNodes[4].namespaceURI === SVGNS && s.firstChild.data === 'a';
              var g = document.createElementNS(SVGNS, 'g'); g.innerHTML = '<rect/><span>x</span></g>';
              return ok && names(g.childNodes) === 'rect,SPAN'; })()
            """),
        ("math context: mi stays MathML, <div> breaks out", """
            (function(){ var m = document.createElementNS(MATHNS, 'math'); m.innerHTML = '<mi>x</mi><div>y</div>t';
              return names(m.childNodes) === 'mi,DIV,#text' && m.firstChild.namespaceURI === MATHNS &&
                m.childNodes[1].namespaceURI === XHTMLNS; })()
            """),
        ("template contents keep their parent pointers", """
            (function(){ var d = el('div', '<template><p>a</p><i>b</i></template>'), t = d.firstChild, c = t.content;
              return c.firstChild.parentNode === c && c.lastChild.parentNode === c && t.content === c &&
                c.firstChild.nextSibling === c.lastChild && t.childNodes.length === 0; })()
            """),
        ("foreignObject context stays an HTML integration point", """
            (function(){ var f = el('div', '<svg><foreignObject></foreignObject></svg>').firstChild.firstChild;
              f.innerHTML = '<div>a</div>'; return f.firstChild.namespaceURI === XHTMLNS && f.firstChild.tagName === 'DIV'; })()
            """),
        ("adjusted SVG attributes appear once with their case", """
            (function(){ var s = el('div', '<svg viewbox="0 0 1 1" preserveaspectratio=none></svg>').firstChild;
              var n = s.getAttributeNames().sort().join(',');
              return n === 'preserveAspectRatio,viewBox' && s.getAttribute('viewBox') === '0 0 1 1' &&
                s.outerHTML === '<svg preserveAspectRatio="none" viewBox="0 0 1 1"></svg>'; })()
            """),
        ("setAttribute on an SVG element keeps the name's case", """
            (function(){ var s = document.createElementNS(SVGNS, 'svg'); s.setAttribute('viewBox', '0 0 2 2');
              var ok1 = s.getAttributeNames().join() === 'viewBox' && s.outerHTML === '<svg viewBox="0 0 2 2"></svg>' && s.hasAttribute('viewBox');
              s.removeAttribute('viewBox'); var d = document.createElement('div'); d.setAttribute('dataFoo', '1');
              return ok1 && s.getAttributeNames().length === 0 && d.getAttributeNames().join() === 'datafoo'; })()
            """),
        ("getElementsByTagName matches foreign names case-sensitively", """
            (function(){ var d = el('div', '<svg><linearGradient/></svg><div></div>');
              return d.getElementsByTagName('linearGradient').length === 1 && d.getElementsByTagName('DIV').length === 1; })()
            """),

        // ---- 14-6 template
        ("template.innerHTML parses with the template as context (m06)", """
            (function(){ var t = document.createElement('template'); t.innerHTML = '<td>a</td>';
              return [t.childNodes.length, t.content.childNodes.length, t.innerHTML, t.content.firstChild && t.content.firstChild.nodeName].join('|') === '0|1|<td>a</td>|TD'; })()
            """),
        ("template keeps rows, cols, captions and row groups", """
            (function(){ var t = document.createElement('template'); t.innerHTML = '<tr><td>x';
              var u = document.createElement('template'); u.innerHTML = '<col><col span=2>'; var w = document.createElement('template'); w.innerHTML = '<caption>c</caption><tbody>';
              return t.innerHTML === '<tr><td>x</td></tr>' && t.content.nodeType === 11 && names(u.content.childNodes) === 'COL,COL' && names(w.content.childNodes) === 'CAPTION,TBODY'; })()
            """),
        ("template outerHTML and cloneNode carry the contents", """
            (function(){ var d = el('div', '<template><td>a</td></template>'), t = d.firstChild, c = t.cloneNode(true);
              return t.outerHTML === '<template><td>a</td></template>' && c.innerHTML === '<td>a</td>' &&
                c.content.firstChild !== t.content.firstChild && t.cloneNode(false).innerHTML === ''; })()
            """),

        // ---- 14-7 serialisation (§13.3)
        ("text escaping: & < > and U+00A0, quotes kept", """
            el('div', '<p>x &amp; &lt; &gt; &quot; &nbsp; \\'</p>').innerHTML === '<p>x &amp; &lt; &gt; " &nbsp; \\'</p>'
            """),
        ("attribute escaping: &, quote and U+00A0", """
            el('div', '<p title="a&amp;b&quot;c&nbsp;d\\'e"></p>').innerHTML === '<p title="a&amp;b&quot;c&nbsp;d\\'e"></p>'
            """),
        ("void elements, boolean attributes", """
            el('div', '<br><img src=x><input disabled><hr><wbr><p></p>').innerHTML === '<br><img src="x"><input disabled=""><hr><wbr><p></p>'
            """),
        ("raw text parents are written verbatim (scripting on)", """
            el('div', '<script>a<b&amp;</' + 'script><style>&lt;</style><noscript><b>&amp;</b></noscript><textarea><b>&amp;</textarea>').innerHTML ===
              '<script>a<b&amp;</script><style>&lt;</style><noscript><b>&amp;</b></noscript><textarea>&lt;b&gt;&amp;</textarea>'
            """),
        ("xmp, iframe, noembed, noframes, plaintext are raw too", """
            el('div', '<xmp>a&b<</xmp><iframe>&amp;</iframe><noembed><i></noembed><noframes>&</noframes>').innerHTML ===
              '<xmp>a&b<</xmp><iframe>&amp;</iframe><noembed><i></noembed><noframes>&</noframes>' &&
            el('div', '<plaintext>a<b>&amp;').innerHTML === '<plaintext>a<b>&amp;</plaintext>'
            """),
        ("script-created text in a script element is raw; in a div escaped", """
            (function(){ var s = document.createElement('script'), d = document.createElement('div');
              s.appendChild(document.createTextNode('1 < 2 && 3')); d.appendChild(document.createTextNode('1 < 2 && 3'));
              return s.outerHTML === '<script>1 < 2 && 3</script>' && d.outerHTML === '<div>1 &lt; 2 &amp;&amp; 3</div>'; })()
            """),
        ("noscript text is escaped where scripting is disabled (DOMParser)", """
            dp('<body><noscript>&lt;b&gt;</noscript>').body.innerHTML === '<noscript>&lt;b&gt;</noscript>'
            """),
        ("foreign elements serialise with their case", """
            el('div', '<svg viewBox="0 0 1 1"><foreignObject><div>x</div></foreignObject></svg>').innerHTML ===
              '<svg viewBox="0 0 1 1"><foreignObject><div>x</div></foreignObject></svg>'
            """),

        // ---- 14-8 textarea value
        ("textarea.value is the child text (leading newline dropped by the parser)", """
            el('div', '<textarea>\\n\\nx</textarea>').firstChild.value + '|' + el('div', '<textarea>\\nx</textarea>').firstChild.value === '\\nx|x'
            """),
        ("textarea ignores its value attribute; defaultValue mirrors the text", """
            (function(){ var t = el('div', '<textarea value="v">x</textarea>').firstChild;
              return t.value === 'x' && t.defaultValue === 'x'; })()
            """),
        ("textarea: defaultValue writes the text until value is set (dirty)", """
            (function(){ var t = document.createElement('textarea'); t.defaultValue = 'd';
              var a = t.value === 'd' && t.textContent === 'd';
              t.value = 'z'; t.defaultValue = 'e';
              return a && t.value === 'z' && t.defaultValue === 'e' && t.textContent === 'e'; })()
            """),
    ]

    mutating func testHTMLParsing() {
        // Parser-level checks that need no JS.
        let doc = HTMLParser.parse("<!--a--><!DOCTYPE html PUBLIC \"p\" \"s\"><p>x")
        let kids = doc.children
        assert(kids.count == 3 && kids[1].isDocumentType && kids[1].nodeType == .comment
               && kids[1].doctypeName == "html" && kids[1].doctypePublicId == "p" && kids[1].doctypeSystemId == "s"
               && doc.doctype === kids[1],
               "HTMLParsing: DocumentType node in the parsed Document")
        assert(HTMLParser.parse("<p>x").doctype == nil && HTMLParser.parse("<p>x").quirksMode == .quirks,
               "HTMLParsing: no DOCTYPE -> no node, quirks")
        let crlf = HTMLParser.parseFragment("a\r\nb\rc", context: "div")
        assert(crlf.count == 1 && crlf[0].textContent == "a\nb\nc", "HTMLParsing: CR/CRLF normalised (Swift)")
        let svgFrag = HTMLParser.parseFragment("<circle/><div>x</div>", context: "svg", contextNamespace: DOMNode.svgNamespace)
        assert(svgFrag.count == 2 && svgFrag[0].namespaceURI == DOMNode.svgNamespace && svgFrag[1].isHTMLNamespace,
               "HTMLParsing: svg-context fragment")
        let foTokens: [HTMLToken] = { var t = HTMLTokenizer("x<a b=c"); return t.tokenize() }()
        assert(foTokens.count == 1, "HTMLParsing: EOF in tag emits no tag token (got \(foTokens.count) tokens)")

        var outcomes: [(Bool, String)] = []
        let run = {
            MainActor.assumeIsolated {
                let env = JeffJSEnvironment()
                _ = env.eval(JeffJSTestRunner.htmlParsingPrelude, filename: "<html-parsing-prelude>")
                for (name, js) in JeffJSTestRunner.htmlParsingCases {
                    switch env.eval(js, filename: "<html-parsing>") {
                    case .success(let value):
                        outcomes.append((value == "true", "HTMLParsing: \(name) -> \(value ?? "undefined")"))
                    case .exception(let message):
                        outcomes.append((false, "HTMLParsing: \(name) threw \(message)"))
                    }
                }
            }
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.sync(execute: run) }
        for (ok, message) in outcomes { assert(ok, message) }
    }
}
