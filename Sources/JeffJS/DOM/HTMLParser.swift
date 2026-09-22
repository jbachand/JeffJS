import Foundation

/// Builds a DOM tree from HTML, following the HTML Standard §13.2.6 tree
/// construction algorithm: insertion modes, the list of active formatting
/// elements, the adoption agency, foster parenting, and foreign content.
public struct HTMLParser: Sendable {

    /// Parse a whole document. `scriptingEnabled` mirrors the flag in
    /// §13.2.6.4.4: with scripting on (a browser's default, and ours) the
    /// contents of `<noscript>` are *raw text* and never become elements.
    public static func parse(_ html: String, scriptingEnabled: Bool = true) -> DOMNode {
        let builder = HTMLTreeBuilder(html: html, scriptingEnabled: scriptingEnabled)
        return builder.buildDocument()
    }

    /// The HTML fragment parsing algorithm (§13.2.6.4.13) — what
    /// `element.innerHTML = …` runs. `context` is the context element's tag
    /// name; `"table"`/`"tbody"`/`"tr"` are what make a bare `<tr>` survive.
    public static func parseFragment(
        _ html: String,
        context: String? = nil,
        contextNamespace: String? = nil,
        scriptingEnabled: Bool = true
    ) -> [DOMNode] {
        let builder = HTMLTreeBuilder(html: html, scriptingEnabled: scriptingEnabled)
        return builder.buildFragment(context: context, contextNamespace: contextNamespace)
    }
}

// MARK: - Element categories

enum HTMLElements {

    /// §13.2.4.2 "special" — the elements the adoption agency and the
    /// `</p>`-style implied-end-tag rules treat as block-ish boundaries.
    static let special: Set<String> = [
        "address", "applet", "area", "article", "aside", "base", "basefont", "bgsound",
        "blockquote", "body", "br", "button", "caption", "center", "col", "colgroup",
        "dd", "details", "dir", "div", "dl", "dt", "embed", "fieldset", "figcaption",
        "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5",
        "h6", "head", "header", "hgroup", "hr", "html", "iframe", "img", "input",
        "keygen", "li", "link", "listing", "main", "marquee", "menu", "meta", "nav",
        "noembed", "noframes", "noscript", "object", "ol", "p", "param", "plaintext",
        "pre", "script", "search", "section", "select", "source", "style", "summary",
        "table", "tbody", "td", "template", "textarea", "tfoot", "th", "thead", "title",
        "tr", "track", "ul", "wbr", "xmp",
    ]

    /// MathML elements that are also "special".
    static let mathmlSpecial: Set<String> = ["mi", "mo", "mn", "ms", "mtext", "annotation-xml"]
    /// SVG elements that are also "special".
    static let svgSpecial: Set<String> = ["foreignObject", "desc", "title"]

    /// §13.2.4.3 formatting elements — the ones the adoption agency reopens.
    static let formatting: Set<String> = [
        "a", "b", "big", "code", "em", "font", "i", "nobr", "s", "small",
        "strike", "strong", "tt", "u",
    ]

    /// Tags that end an open `<p>`/`<li>`/… via "generate implied end tags".
    static let impliedEndTags: Set<String> = [
        "dd", "dt", "li", "optgroup", "option", "p", "rb", "rp", "rt", "rtc",
    ]

    /// "generate all implied end tags thoroughly" adds these.
    static let impliedEndTagsThorough: Set<String> = [
        "caption", "colgroup", "dd", "dt", "li", "optgroup", "option", "p",
        "rb", "rp", "rt", "rtc", "tbody", "td", "tfoot", "th", "thead", "tr",
    ]

    /// Elements that scope lookups never escape (§13.2.4.2 default scope).
    static let scopeBoundary: Set<String> = [
        "applet", "caption", "html", "table", "td", "th", "marquee", "object", "template",
    ]

    /// `<h1>`…`<h6>`.
    static let headings: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]

    /// MathML text integration points.
    static let mathmlTextIntegration: Set<String> = ["mi", "mo", "mn", "ms", "mtext"]
}

// MARK: - Tree builder

/// One parse. Mutable state lives here rather than on the `HTMLParser` facade
/// so the facade can stay a `Sendable` struct of static entry points.
final class HTMLTreeBuilder {

    enum InsertionMode {
        case initial, beforeHTML, beforeHead, inHead, inHeadNoscript, afterHead
        case inBody, text, inTable, inTableText, inCaption, inColumnGroup
        case inTableBody, inRow, inCell, inSelect, inSelectInTable, inTemplate
        case afterBody, inFrameset, afterFrameset, afterAfterBody, afterAfterFrameset
    }

    /// An entry in the list of active formatting elements. The attributes are
    /// kept because reconstruction creates a *new* element from the same token.
    struct FormattingEntry {
        var element: DOMNode?          // nil = marker
        var tag: String
        var attributes: [HTMLAttribute]
        var isMarker: Bool { element == nil }

        static let marker = FormattingEntry(element: nil, tag: "", attributes: [])
    }

    private var tokenizer: HTMLTokenizer
    private let scriptingEnabled: Bool

    private let document = DOMNode.document()
    private var openElements: [DOMNode] = []
    private var activeFormatting: [FormattingEntry] = []

    private var mode: InsertionMode = .initial
    private var originalMode: InsertionMode = .initial
    private var templateModes: [InsertionMode] = []

    private var headElement: DOMNode?
    private var formElement: DOMNode?
    private var framesetOK = true
    private var fosterParenting = false
    private var pendingTableCharacters: [String] = []
    private var pendingTableCharactersAreWhitespaceOnly = true

    /// Set after `<pre>`/`<listing>`/`<textarea>`: a newline immediately after
    /// the start tag is dropped (§13.2.6.4.7).
    private var ignoreNextLF = false
    private var fragmentParsing = false
    private var contextElement: DOMNode?

    init(html: String, scriptingEnabled: Bool) {
        self.tokenizer = HTMLTokenizer(html)
        self.scriptingEnabled = scriptingEnabled
    }

    // MARK: Entry points

    func buildDocument() -> DOMNode {
        run()
        return document
    }

    func buildFragment(context: String?, contextNamespace: String?) -> [DOMNode] {
        fragmentParsing = true
        document.quirksMode = .noQuirks

        let contextTag = (context ?? "body").lowercased()
        let ctx = DOMNode.element(tag: contextTag, namespace: contextNamespace)
        contextElement = ctx

        // The tokenizer starts in the state the context element implies.
        switch contextTag {
        case "title", "textarea": tokenizer.contentState = .rcdata
        case "style", "xmp", "iframe", "noembed", "noframes": tokenizer.contentState = .rawtext
        case "script": tokenizer.contentState = .scriptData
        case "noscript": if scriptingEnabled { tokenizer.contentState = .rawtext }
        case "plaintext": tokenizer.contentState = .plaintext
        default: break
        }

        let root = DOMNode.element(tag: "html")
        document.appendChild(root)
        openElements = [root]
        if contextTag == "template" { templateModes.append(.inTemplate) }
        resetInsertionModeAppropriately()

        // The form pointer is seeded from the context element's ancestors; a
        // detached innerHTML context has none, so this is just the element.
        if contextTag == "form" { formElement = ctx }

        run()
        return root.children
    }

    private func run() {
        while true {
            tokenizer.allowCDATA = shouldAllowCDATA()
            guard let token = tokenizer.nextToken() else { break }
            dispatch(token)
        }
        finishAtEOF()
    }

    private func shouldAllowCDATA() -> Bool {
        guard let node = adjustedCurrentNode else { return false }
        return !node.isHTMLNamespace
    }

    private func finishAtEOF() {
        // Flush any buffered table text and close out open elements. Nothing
        // here creates nodes except the implied <html>/<head>/<body>.
        if mode == .inTableText { flushPendingTableCharacters() }
        if mode == .initial {
            document.quirksMode = .quirks
            mode = .beforeHTML
        }
        if mode == .beforeHTML, !fragmentParsing {
            let html = DOMNode.element(tag: "html")
            document.appendChild(html)
            openElements.append(html)
            mode = .beforeHead
        }
        if !fragmentParsing, mode == .beforeHead || mode == .inHead || mode == .afterHead {
            ensureBody()
        }
    }

    // MARK: Stack helpers

    var currentNode: DOMNode? { openElements.last }

    /// The context element stands in for the (absent) current node while a
    /// fragment parse still has only the synthetic `<html>` on the stack.
    var adjustedCurrentNode: DOMNode? {
        if fragmentParsing, openElements.count == 1 { return contextElement }
        return openElements.last
    }

    private func isHTMLElement(_ node: DOMNode, _ name: String) -> Bool {
        node.isHTMLNamespace && node.tagName == name
    }

    private func popUntil(_ name: String) {
        while let node = openElements.last {
            openElements.removeLast()
            if isHTMLElement(node, name) { return }
        }
    }

    private func popUntilAny(_ names: Set<String>) {
        while let node = openElements.last {
            openElements.removeLast()
            if node.isHTMLNamespace, let tag = node.tagName, names.contains(tag) { return }
        }
    }

    private func hasInScope(_ name: String, extra: Set<String> = []) -> Bool {
        hasInScope({ self.isHTMLElement($0, name) }, extra: extra)
    }

    private func hasInScope(_ match: (DOMNode) -> Bool, extra: Set<String>) -> Bool {
        for node in openElements.reversed() {
            if match(node) { return true }
            if node.isHTMLNamespace, let tag = node.tagName {
                if HTMLElements.scopeBoundary.contains(tag) || extra.contains(tag) { return false }
            } else if let tag = node.tagName {
                if node.namespaceURI == DOMNode.mathmlNamespace, HTMLElements.mathmlSpecial.contains(tag), tag != "annotation-xml" { return false }
                if node.namespaceURI == DOMNode.mathmlNamespace, tag == "annotation-xml" { return false }
                if node.namespaceURI == DOMNode.svgNamespace, HTMLElements.svgSpecial.contains(tag) { return false }
            }
        }
        return false
    }

    private func hasInListItemScope(_ name: String) -> Bool { hasInScope(name, extra: ["ol", "ul"]) }
    private func hasInButtonScope(_ name: String) -> Bool { hasInScope(name, extra: ["button"]) }

    private func hasInTableScope(_ names: Set<String>) -> Bool {
        for node in openElements.reversed() {
            guard node.isHTMLNamespace, let tag = node.tagName else { continue }
            if names.contains(tag) { return true }
            if tag == "html" || tag == "table" || tag == "template" { return false }
        }
        return false
    }

    private func hasInSelectScope(_ name: String) -> Bool {
        for node in openElements.reversed() {
            guard node.isHTMLNamespace, let tag = node.tagName else { return false }
            if tag == name { return true }
            if tag != "optgroup" && tag != "option" { return false }
        }
        return false
    }

    private func generateImpliedEndTags(except exception: String? = nil) {
        while let node = currentNode, node.isHTMLNamespace, let tag = node.tagName,
              HTMLElements.impliedEndTags.contains(tag), tag != exception {
            openElements.removeLast()
        }
    }

    private func generateImpliedEndTagsThoroughly() {
        while let node = currentNode, node.isHTMLNamespace, let tag = node.tagName,
              HTMLElements.impliedEndTagsThorough.contains(tag) {
            openElements.removeLast()
        }
    }

    private func closeAPElementIfOpen() {
        guard hasInButtonScope("p") else { return }
        generateImpliedEndTags(except: "p")
        popUntil("p")
    }

    // MARK: Insertion

    /// §13.2.6.1 "appropriate place for inserting a node", including foster
    /// parenting: text and stray elements inside a `<table>` land *before* the
    /// table, not inside it.
    private func appropriateInsertionPlace(overrideTarget: DOMNode? = nil) -> (parent: DOMNode, before: DOMNode?) {
        let target = overrideTarget ?? currentNode ?? document
        guard fosterParenting, target.isHTMLNamespace,
              let tag = target.tagName,
              tag == "table" || tag == "tbody" || tag == "tfoot" || tag == "thead" || tag == "tr"
        else {
            return (target, nil)
        }
        // Last template / last table on the stack.
        var lastTemplate: Int?
        var lastTable: Int?
        for (i, node) in openElements.enumerated() where node.isHTMLNamespace {
            if node.tagName == "template" { lastTemplate = i }
            if node.tagName == "table" { lastTable = i }
        }
        if let t = lastTemplate, lastTable == nil || t > lastTable! {
            return (openElements[t], nil)
        }
        guard let tableIndex = lastTable else {
            return (openElements.first ?? document, nil)
        }
        let table = openElements[tableIndex]
        if let parent = table.parent {
            return (parent, table)
        }
        // Table was popped off its parent: insert into the element before it.
        return (openElements[max(0, tableIndex - 1)], nil)
    }

    private func insert(_ node: DOMNode, overrideTarget: DOMNode? = nil) {
        let place = appropriateInsertionPlace(overrideTarget: overrideTarget)
        if let before = place.before {
            place.parent.insertChild(node, before: before)
        } else {
            place.parent.appendChild(node)
        }
    }

    @discardableResult
    private func insertElement(
        tag: String,
        attributes: [HTMLAttribute],
        namespace: String? = nil,
        preserveCase: Bool = false,
        push: Bool = true
    ) -> DOMNode {
        let element = createElement(tag: tag, attributes: attributes, namespace: namespace, preserveCase: preserveCase)
        insert(element)
        if push { openElements.append(element) }
        return element
    }

    private func createElement(
        tag: String,
        attributes: [HTMLAttribute],
        namespace: String? = nil,
        preserveCase: Bool = false
    ) -> DOMNode {
        // The tokenizer already ASCII-lowercased the name and the foreign
        // adjustment tables already re-cased it, so `preserveCase: true` here
        // just avoids a `lowercased()` allocation per element.
        let element = DOMNode.element(tag: tag, preserveCase: true, namespace: namespace)
        for attribute in attributes {
            if preserveCase, attribute.name.contains(where: { $0.isUppercase }) {
                // Foreign content: keep `viewBox` as authored and register the
                // lowercase alias so `attributes["viewbox"]` still resolves.
                element.setAttributePreservingCase(name: attribute.name, value: attribute.value)
            } else if element.attributes[attribute.name] == nil {
                element.attributes[attribute.name] = attribute.value
            }
        }
        return element
    }

    /// Characters go into the trailing text node when there is one, which is
    /// what keeps `a&amp;b` a single text node.
    private func insertCharacters(_ text: String) {
        guard !text.isEmpty else { return }
        let place = appropriateInsertionPlace()
        if let before = place.before {
            if let previous = place.parent.childBefore(before), previous.nodeType == .text {
                previous.textContent = (previous.textContent ?? "") + text
                return
            }
            place.parent.insertChild(DOMNode.text(text), before: before)
            return
        }
        if let last = place.parent.lastChildNode, last.nodeType == .text {
            last.textContent = (last.textContent ?? "") + text
            return
        }
        place.parent.appendChild(DOMNode.text(text))
    }

    private func insertComment(_ data: String, target: DOMNode? = nil) {
        let comment = DOMNode.comment(data)
        if let target {
            target.appendChild(comment)
        } else {
            insert(comment)
        }
    }

    // MARK: Active formatting elements

    private func pushActiveFormatting(_ element: DOMNode, tag: String, attributes: [HTMLAttribute]) {
        // Noah's Ark: at most three identical entries since the last marker.
        var matches: [Int] = []
        for index in stride(from: activeFormatting.count - 1, through: 0, by: -1) {
            let entry = activeFormatting[index]
            if entry.isMarker { break }
            if entry.tag == tag, sameAttributes(entry.attributes, attributes) { matches.append(index) }
        }
        if matches.count >= 3, let oldest = matches.last {
            activeFormatting.remove(at: oldest)
        }
        activeFormatting.append(FormattingEntry(element: element, tag: tag, attributes: attributes))
    }

    private func sameAttributes(_ a: [HTMLAttribute], _ b: [HTMLAttribute]) -> Bool {
        guard a.count == b.count else { return false }
        var lhs = [String: String](minimumCapacity: a.count)
        for attribute in a { lhs[attribute.name] = attribute.value }
        for attribute in b where lhs[attribute.name] != attribute.value { return false }
        return true
    }

    private func clearActiveFormattingToMarker() {
        while let last = activeFormatting.last {
            activeFormatting.removeLast()
            if last.isMarker { return }
        }
    }

    /// §13.2.6.4.3 — reopens `<b>`/`<i>`/… that an end tag closed out of order,
    /// which is why `<b>1<p>2` puts a fresh `<b>` inside the `<p>`.
    private func reconstructActiveFormatting() {
        guard let last = activeFormatting.last, !last.isMarker else { return }
        if let element = last.element, openElements.contains(where: { $0 === element }) { return }

        var index = activeFormatting.count - 1
        while index > 0 {
            let entry = activeFormatting[index - 1]
            if entry.isMarker { break }
            if let element = entry.element, openElements.contains(where: { $0 === element }) { break }
            index -= 1
        }
        while index < activeFormatting.count {
            let entry = activeFormatting[index]
            let element = insertElement(tag: entry.tag, attributes: entry.attributes)
            activeFormatting[index].element = element
            index += 1
        }
    }

    private func removeFromActiveFormatting(_ element: DOMNode) {
        activeFormatting.removeAll { $0.element === element }
    }

    // MARK: - Dispatcher

    private func dispatch(_ token: HTMLToken) {
        var token = token
        if ignoreNextLF {
            ignoreNextLF = false
            if case .text(let text) = token, text.hasPrefix("\n") {
                let rest = String(text.dropFirst())
                if rest.isEmpty { return }
                token = .text(rest)
            }
        }
        if useForeignRules(for: token) {
            foreignContent(token)
            return
        }
        process(token, in: mode)
    }

    private func reprocess(_ token: HTMLToken, in newMode: InsertionMode) {
        mode = newMode
        dispatch(token)
    }

    /// §13.2.6 tree construction dispatcher: the foreign-content branch.
    private func useForeignRules(for token: HTMLToken) -> Bool {
        guard let node = adjustedCurrentNode, !node.isHTMLNamespace else { return false }
        guard let tag = node.tagName else { return false }

        if node.namespaceURI == DOMNode.mathmlNamespace,
           HTMLElements.mathmlTextIntegration.contains(tag) {
            if case .startTag(let name, _, _) = token, name != "mglyph", name != "malignmark" { return false }
            if case .text = token { return false }
        }
        if node.namespaceURI == DOMNode.mathmlNamespace, tag == "annotation-xml",
           case .startTag(let name, _, _) = token, name == "svg" { return false }
        if isHTMLIntegrationPoint(node) {
            if case .startTag = token { return false }
            if case .text = token { return false }
        }
        return true
    }

    private func isHTMLIntegrationPoint(_ node: DOMNode) -> Bool {
        guard let tag = node.tagName else { return false }
        if node.namespaceURI == DOMNode.mathmlNamespace, tag == "annotation-xml" {
            let encoding = (node.attributes["encoding"] ?? "").lowercased()
            return encoding == "text/html" || encoding == "application/xhtml+xml"
        }
        if node.namespaceURI == DOMNode.svgNamespace {
            return tag == "foreignObject" || tag == "desc" || tag == "title"
        }
        return false
    }

    private func process(_ token: HTMLToken, in mode: InsertionMode) {
        switch mode {
        case .initial: initialMode(token)
        case .beforeHTML: beforeHTMLMode(token)
        case .beforeHead: beforeHeadMode(token)
        case .inHead: inHeadMode(token)
        case .inHeadNoscript: inHeadNoscriptMode(token)
        case .afterHead: afterHeadMode(token)
        case .inBody: inBodyMode(token)
        case .text: textMode(token)
        case .inTable: inTableMode(token)
        case .inTableText: inTableTextMode(token)
        case .inCaption: inCaptionMode(token)
        case .inColumnGroup: inColumnGroupMode(token)
        case .inTableBody: inTableBodyMode(token)
        case .inRow: inRowMode(token)
        case .inCell: inCellMode(token)
        case .inSelect: inSelectMode(token)
        case .inSelectInTable: inSelectInTableMode(token)
        case .inTemplate: inTemplateMode(token)
        case .afterBody: afterBodyMode(token)
        case .inFrameset: inFramesetMode(token)
        case .afterFrameset: afterFramesetMode(token)
        case .afterAfterBody: afterAfterBodyMode(token)
        case .afterAfterFrameset: afterAfterFramesetMode(token)
        }
    }

    // MARK: Text helpers

    private static func isASCIIWhitespaceOnly(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where !DOMNode.isASCIIWhitespace(scalar) { return false }
        return true
    }

    private static func splitLeadingWhitespace(_ text: String) -> (String, String) {
        var index = text.startIndex
        while index < text.endIndex, DOMNode.isASCIIWhitespace(text[index]) {
            index = text.index(after: index)
        }
        return (String(text[text.startIndex..<index]), String(text[index...]))
    }

    /// NUL character tokens are dropped in HTML content (§13.2.6.4.7).
    private static func strippingNulls(_ text: String) -> String {
        text.contains("\0") ? text.replacingOccurrences(of: "\0", with: "") : text
    }

    // MARK: - "initial"

    private func initialMode(_ token: HTMLToken) {
        switch token {
        case .text(let text):
            let (_, rest) = Self.splitLeadingWhitespace(text)
            if rest.isEmpty { return }
            document.quirksMode = .quirks
            reprocess(.text(rest), in: .beforeHTML)
        case .comment(let data):
            insertComment(data, target: document)
        case .doctype(let doctype):
            // No DocumentType node is materialised (nothing downstream reads
            // one); the DOCTYPE's whole effect is the quirks-mode decision.
            document.quirksMode = Self.quirksMode(for: doctype)
            mode = .beforeHTML
        default:
            document.quirksMode = .quirks
            reprocess(token, in: .beforeHTML)
        }
    }

    // MARK: - "before html"

    private func beforeHTMLMode(_ token: HTMLToken) {
        switch token {
        case .doctype: return
        case .comment(let data): insertComment(data, target: document)
        case .text(let text):
            let (_, rest) = Self.splitLeadingWhitespace(text)
            if rest.isEmpty { return }
            createHTMLRoot(attributes: [])
            reprocess(.text(rest), in: .beforeHead)
        case .startTag(let name, let attributes, _) where name == "html":
            createHTMLRoot(attributes: attributes)
            mode = .beforeHead
        case .endTag(let name) where name == "head" || name == "body" || name == "html" || name == "br":
            createHTMLRoot(attributes: [])
            reprocess(token, in: .beforeHead)
        case .endTag: return
        default:
            createHTMLRoot(attributes: [])
            reprocess(token, in: .beforeHead)
        }
    }

    private func createHTMLRoot(attributes: [HTMLAttribute]) {
        let html = createElement(tag: "html", attributes: attributes)
        document.appendChild(html)
        openElements.append(html)
    }

    // MARK: - "before head"

    private func beforeHeadMode(_ token: HTMLToken) {
        switch token {
        case .doctype: return
        case .comment(let data): insertComment(data)
        case .text(let text):
            let (_, rest) = Self.splitLeadingWhitespace(text)
            if rest.isEmpty { return }
            startHead(attributes: [])
            reprocess(.text(rest), in: .inHead)
        case .startTag(let name, let attributes, _) where name == "html":
            inBodyMode(.startTag(name: name, attributes: attributes, selfClosing: false))
        case .startTag(let name, let attributes, _) where name == "head":
            startHead(attributes: attributes)
            mode = .inHead
        case .endTag(let name) where name == "head" || name == "body" || name == "html" || name == "br":
            startHead(attributes: [])
            reprocess(token, in: .inHead)
        case .endTag: return
        default:
            startHead(attributes: [])
            reprocess(token, in: .inHead)
        }
    }

    private func startHead(attributes: [HTMLAttribute]) {
        headElement = insertElement(tag: "head", attributes: attributes)
    }

    // MARK: - "in head"

    private func inHeadMode(_ token: HTMLToken) {
        switch token {
        case .doctype: return
        case .comment(let data): insertComment(data)
        case .text(let text):
            let (whitespace, rest) = Self.splitLeadingWhitespace(text)
            if !whitespace.isEmpty { insertCharacters(whitespace) }
            if rest.isEmpty { return }
            openElements.removeLast() // pop <head>
            reprocess(.text(rest), in: .afterHead)

        case .startTag(let name, let attributes, let selfClosing):
            switch name {
            case "html":
                inBodyMode(token)
            case "base", "basefont", "bgsound", "link", "meta":
                insertElement(tag: name, attributes: attributes, push: false)
                _ = selfClosing
            case "title":
                parseGenericText(tag: name, attributes: attributes, rawText: false)
            case "noscript":
                if scriptingEnabled {
                    parseGenericText(tag: name, attributes: attributes, rawText: true)
                } else {
                    insertElement(tag: name, attributes: attributes)
                    mode = .inHeadNoscript
                }
            case "noframes", "style":
                parseGenericText(tag: name, attributes: attributes, rawText: true)
            case "script":
                insertElement(tag: name, attributes: attributes)
                tokenizer.contentState = .scriptData
                originalMode = mode
                mode = .text
            case "template":
                insertElement(tag: name, attributes: attributes)
                activeFormatting.append(.marker)
                framesetOK = false
                mode = .inTemplate
                templateModes.append(.inTemplate)
            case "head":
                return
            default:
                popHeadAndReprocess(token)
            }

        case .endTag(let name):
            switch name {
            case "head":
                openElements.removeLast()
                mode = .afterHead
            case "body", "html", "br":
                popHeadAndReprocess(token)
            case "template":
                closeTemplate()
            default:
                return
            }
        }
    }

    private func popHeadAndReprocess(_ token: HTMLToken) {
        openElements.removeLast()
        reprocess(token, in: .afterHead)
    }

    /// Generic RCDATA / RAWTEXT element parsing (§13.2.6.2).
    private func parseGenericText(tag: String, attributes: [HTMLAttribute], rawText: Bool) {
        insertElement(tag: tag, attributes: attributes)
        tokenizer.contentState = rawText ? .rawtext : .rcdata
        originalMode = mode
        mode = .text
    }

    private func closeTemplate() {
        guard openElements.contains(where: { isHTMLElement($0, "template") }) else { return }
        generateImpliedEndTagsThoroughly()
        popUntil("template")
        clearActiveFormattingToMarker()
        if !templateModes.isEmpty { templateModes.removeLast() }
        resetInsertionModeAppropriately()
    }

    // MARK: - "in head noscript" (scripting disabled)

    private func inHeadNoscriptMode(_ token: HTMLToken) {
        switch token {
        case .doctype: return
        case .startTag(let name, _, _) where name == "html":
            inBodyMode(token)
        case .endTag(let name) where name == "noscript":
            openElements.removeLast()
            mode = .inHead
        case .text(let text) where Self.isASCIIWhitespaceOnly(text):
            inHeadMode(token)
        case .comment:
            inHeadMode(token)
        case .startTag(let name, _, _)
            where ["basefont", "bgsound", "link", "meta", "noframes", "style"].contains(name):
            inHeadMode(token)
        case .endTag(let name) where name == "br":
            openElements.removeLast()
            reprocess(token, in: .inHead)
        default:
            openElements.removeLast()
            reprocess(token, in: .inHead)
        }
    }

    // MARK: - "after head"

    private func afterHeadMode(_ token: HTMLToken) {
        switch token {
        case .doctype: return
        case .comment(let data): insertComment(data)
        case .text(let text):
            let (whitespace, rest) = Self.splitLeadingWhitespace(text)
            if !whitespace.isEmpty { insertCharacters(whitespace) }
            if rest.isEmpty { return }
            startBody(attributes: [])
            reprocess(.text(rest), in: .inBody)

        case .startTag(let name, let attributes, _):
            switch name {
            case "html":
                inBodyMode(token)
            case "body":
                startBody(attributes: attributes)
                framesetOK = false
                mode = .inBody
            case "frameset":
                insertElement(tag: name, attributes: attributes)
                mode = .inFrameset
            case "base", "basefont", "bgsound", "link", "meta", "noframes", "script",
                 "style", "template", "title":
                if let head = headElement {
                    openElements.append(head)
                    inHeadMode(token)
                    openElements.removeAll { $0 === head }
                } else {
                    inHeadMode(token)
                }
            case "head":
                return
            default:
                startBody(attributes: [])
                reprocess(token, in: .inBody)
            }

        case .endTag(let name):
            switch name {
            case "template":
                inHeadMode(token)
            case "body", "html", "br":
                startBody(attributes: [])
                reprocess(token, in: .inBody)
            default:
                return
            }
        }
    }

    private func startBody(attributes: [HTMLAttribute]) {
        insertElement(tag: "body", attributes: attributes)
    }

    private func ensureBody() {
        let html: DOMNode
        if let existing = document.children.first(where: { $0.nodeType == .element && $0.tagName == "html" }) {
            html = existing
        } else {
            html = DOMNode.element(tag: "html")
            document.appendChild(html)
        }
        if !html.children.contains(where: { $0.tagName == "head" }) {
            html.appendChild(DOMNode.element(tag: "head"))
        }
        if !html.children.contains(where: { $0.tagName == "body" }) {
            html.appendChild(DOMNode.element(tag: "body"))
        }
    }

    // MARK: - "text" (RAWTEXT / RCDATA / script contents)

    private func textMode(_ token: HTMLToken) {
        switch token {
        case .text(let text):
            insertCharacters(text)
        case .endTag:
            openElements.removeLast()
            mode = originalMode
        default:
            openElements.removeLast()
            mode = originalMode
            dispatch(token)
        }
    }

    // MARK: - "in body"

    private static let blockScopeClosers: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details", "dialog",
        "dir", "div", "dl", "fieldset", "figcaption", "figure", "footer", "header",
        "hgroup", "main", "menu", "nav", "ol", "p", "search", "section", "summary", "ul",
    ]

    private static let blockEndTags: Set<String> = [
        "address", "article", "aside", "blockquote", "button", "center", "details",
        "dialog", "dir", "div", "dl", "fieldset", "figcaption", "figure", "footer",
        "header", "hgroup", "listing", "main", "menu", "nav", "ol", "pre", "search",
        "section", "summary", "ul",
    ]

    private func inBodyMode(_ token: HTMLToken) {
        switch token {
        case .doctype:
            return

        case .comment(let data):
            insertComment(data)

        case .text(let raw):
            let text = Self.strippingNulls(raw)
            guard !text.isEmpty else { return }
            reconstructActiveFormatting()
            insertCharacters(text)
            if !Self.isASCIIWhitespaceOnly(text) { framesetOK = false }

        case .startTag(let name, let attributes, let selfClosing):
            inBodyStartTag(name: name, attributes: attributes, selfClosing: selfClosing)

        case .endTag(let name):
            inBodyEndTag(name: name)
        }
    }

    private func inBodyStartTag(name: String, attributes: [HTMLAttribute], selfClosing: Bool) {
        switch name {
        case "html":
            guard !openElements.contains(where: { isHTMLElement($0, "template") }) else { return }
            mergeAttributes(attributes, into: openElements.first)

        case "base", "basefont", "bgsound", "link", "meta", "noframes", "script",
             "style", "template", "title":
            inHeadMode(.startTag(name: name, attributes: attributes, selfClosing: selfClosing))

        case "body":
            guard openElements.count > 1, isHTMLElement(openElements[1], "body"),
                  !openElements.contains(where: { isHTMLElement($0, "template") }) else { return }
            framesetOK = false
            mergeAttributes(attributes, into: openElements[1])

        case "frameset":
            guard framesetOK, openElements.count > 1, isHTMLElement(openElements[1], "body") else { return }
            let body = openElements[1]
            body.parent?.removeChild(body)
            openElements.removeSubrange(1...)
            insertElement(tag: name, attributes: attributes)
            mode = .inFrameset

        case _ where Self.blockScopeClosers.contains(name):
            closeAPElementIfOpen()
            insertElement(tag: name, attributes: attributes)

        case _ where HTMLElements.headings.contains(name):
            closeAPElementIfOpen()
            if let current = currentNode, current.isHTMLNamespace, let tag = current.tagName,
               HTMLElements.headings.contains(tag) {
                openElements.removeLast()
            }
            insertElement(tag: name, attributes: attributes)

        case "pre", "listing":
            closeAPElementIfOpen()
            insertElement(tag: name, attributes: attributes)
            ignoreNextLF = true
            framesetOK = false

        case "form":
            let hasTemplate = openElements.contains(where: { isHTMLElement($0, "template") })
            // Nested <form> is dropped: the form pointer is already set.
            if formElement != nil, !hasTemplate { return }
            closeAPElementIfOpen()
            let element = insertElement(tag: name, attributes: attributes)
            if !hasTemplate { formElement = element }

        case "li":
            framesetOK = false
            for node in openElements.reversed() {
                guard node.isHTMLNamespace, let tag = node.tagName else { break }
                if tag == "li" {
                    generateImpliedEndTags(except: "li")
                    popUntil("li")
                    break
                }
                if HTMLElements.special.contains(tag), tag != "address", tag != "div", tag != "p" { break }
            }
            closeAPElementIfOpen()
            insertElement(tag: name, attributes: attributes)

        case "dd", "dt":
            framesetOK = false
            for node in openElements.reversed() {
                guard node.isHTMLNamespace, let tag = node.tagName else { break }
                if tag == "dd" || tag == "dt" {
                    generateImpliedEndTags(except: tag)
                    popUntil(tag)
                    break
                }
                if HTMLElements.special.contains(tag), tag != "address", tag != "div", tag != "p" { break }
            }
            closeAPElementIfOpen()
            insertElement(tag: name, attributes: attributes)

        case "plaintext":
            closeAPElementIfOpen()
            insertElement(tag: name, attributes: attributes)
            tokenizer.contentState = .plaintext

        case "button":
            if hasInScope("button") {
                generateImpliedEndTags()
                popUntil("button")
            }
            reconstructActiveFormatting()
            insertElement(tag: name, attributes: attributes)
            framesetOK = false

        case "a":
            if let index = lastActiveFormattingIndex(of: "a") {
                let element = activeFormatting[index].element
                adoptionAgency(for: "a")
                if let element {
                    removeFromActiveFormatting(element)
                    openElements.removeAll { $0 === element }
                }
            }
            reconstructActiveFormatting()
            let element = insertElement(tag: name, attributes: attributes)
            pushActiveFormatting(element, tag: name, attributes: attributes)

        case _ where HTMLElements.formatting.contains(name) && name != "nobr":
            reconstructActiveFormatting()
            let element = insertElement(tag: name, attributes: attributes)
            pushActiveFormatting(element, tag: name, attributes: attributes)

        case "nobr":
            reconstructActiveFormatting()
            if hasInScope("nobr") {
                adoptionAgency(for: "nobr")
                reconstructActiveFormatting()
            }
            let element = insertElement(tag: name, attributes: attributes)
            pushActiveFormatting(element, tag: name, attributes: attributes)

        case "applet", "marquee", "object":
            reconstructActiveFormatting()
            insertElement(tag: name, attributes: attributes)
            activeFormatting.append(.marker)
            framesetOK = false

        case "table":
            if document.quirksMode != .quirks { closeAPElementIfOpen() }
            insertElement(tag: name, attributes: attributes)
            framesetOK = false
            mode = .inTable

        case "area", "br", "embed", "img", "keygen", "wbr":
            reconstructActiveFormatting()
            insertElement(tag: name, attributes: attributes, push: false)
            framesetOK = false

        case "input":
            reconstructActiveFormatting()
            insertElement(tag: name, attributes: attributes, push: false)
            let type = attributes.first { $0.name == "type" }?.value.lowercased()
            if type != "hidden" { framesetOK = false }

        case "param", "source", "track":
            insertElement(tag: name, attributes: attributes, push: false)

        case "hr":
            closeAPElementIfOpen()
            insertElement(tag: name, attributes: attributes, push: false)
            framesetOK = false

        case "image":
            // The spec's own words: "this is an error, don't ask".
            inBodyStartTag(name: "img", attributes: attributes, selfClosing: selfClosing)

        case "textarea":
            insertElement(tag: name, attributes: attributes)
            ignoreNextLF = true
            tokenizer.contentState = .rcdata
            framesetOK = false
            originalMode = mode
            mode = .text

        case "xmp":
            closeAPElementIfOpen()
            reconstructActiveFormatting()
            framesetOK = false
            parseGenericText(tag: name, attributes: attributes, rawText: true)

        case "iframe":
            framesetOK = false
            parseGenericText(tag: name, attributes: attributes, rawText: true)

        case "noembed":
            parseGenericText(tag: name, attributes: attributes, rawText: true)

        case "noscript":
            if scriptingEnabled {
                parseGenericText(tag: name, attributes: attributes, rawText: true)
            } else {
                reconstructActiveFormatting()
                insertElement(tag: name, attributes: attributes)
            }

        case "select":
            reconstructActiveFormatting()
            insertElement(tag: name, attributes: attributes)
            framesetOK = false
            switch mode {
            case .inTable, .inCaption, .inTableBody, .inRow, .inCell:
                mode = .inSelectInTable
            default:
                mode = .inSelect
            }

        case "optgroup", "option":
            if let current = currentNode, isHTMLElement(current, "option") {
                openElements.removeLast()
            }
            reconstructActiveFormatting()
            insertElement(tag: name, attributes: attributes)

        case "rb", "rtc":
            if hasInScope("ruby") { generateImpliedEndTags() }
            insertElement(tag: name, attributes: attributes)

        case "rp", "rt":
            if hasInScope("ruby") { generateImpliedEndTags(except: "rtc") }
            insertElement(tag: name, attributes: attributes)

        case "math":
            reconstructActiveFormatting()
            insertForeignElement(tag: name, attributes: attributes,
                                 namespace: DOMNode.mathmlNamespace, selfClosing: selfClosing)

        case "svg":
            reconstructActiveFormatting()
            insertForeignElement(tag: name, attributes: attributes,
                                 namespace: DOMNode.svgNamespace, selfClosing: selfClosing)

        case "caption", "col", "colgroup", "frame", "head", "tbody", "td", "tfoot", "th", "thead", "tr":
            return

        default:
            reconstructActiveFormatting()
            insertElement(tag: name, attributes: attributes)
        }
    }

    private func inBodyEndTag(name: String) {
        switch name {
        case "template":
            inHeadMode(.endTag(name: name))

        case "body", "html":
            guard hasInScope("body") else { return }
            mode = .afterBody
            if name == "html" { dispatch(.endTag(name: name)) }

        case _ where Self.blockEndTags.contains(name):
            guard hasInScope(name) else { return }
            generateImpliedEndTags()
            popUntil(name)

        case "form":
            if !openElements.contains(where: { isHTMLElement($0, "template") }) {
                let node = formElement
                formElement = nil
                guard let node, openElements.contains(where: { $0 === node }),
                      hasInScope({ $0 === node }, extra: []) else { return }
                generateImpliedEndTags()
                openElements.removeAll { $0 === node }
            } else {
                guard hasInScope("form") else { return }
                generateImpliedEndTags()
                popUntil("form")
            }

        case "p":
            if !hasInButtonScope("p") {
                insertElement(tag: "p", attributes: [])
            }
            generateImpliedEndTags(except: "p")
            popUntil("p")

        case "li":
            guard hasInListItemScope("li") else { return }
            generateImpliedEndTags(except: "li")
            popUntil("li")

        case "dd", "dt":
            guard hasInScope(name) else { return }
            generateImpliedEndTags(except: name)
            popUntil(name)

        case _ where HTMLElements.headings.contains(name):
            guard HTMLElements.headings.contains(where: { hasInScope($0) }) else { return }
            generateImpliedEndTags()
            popUntilAny(HTMLElements.headings)

        case _ where HTMLElements.formatting.contains(name):
            adoptionAgency(for: name)

        case "applet", "marquee", "object":
            guard hasInScope(name) else { return }
            generateImpliedEndTags()
            popUntil(name)
            clearActiveFormattingToMarker()

        case "br":
            // `</br>` is treated as `<br>`.
            inBodyStartTag(name: "br", attributes: [], selfClosing: false)

        default:
            anyOtherEndTag(name)
        }
    }

    /// §13.2.6.4.7 "any other end tag": walk down the stack, closing the first
    /// matching element, but stop dead at a "special" element.
    private func anyOtherEndTag(_ name: String) {
        var index = openElements.count - 1
        while index >= 0 {
            let node = openElements[index]
            if node.isHTMLNamespace, node.tagName == name {
                generateImpliedEndTags(except: name)
                openElements.removeSubrange(index...)
                return
            }
            if node.isHTMLNamespace, let tag = node.tagName, HTMLElements.special.contains(tag) { return }
            index -= 1
        }
    }

    private func lastActiveFormattingIndex(of tag: String) -> Int? {
        for index in stride(from: activeFormatting.count - 1, through: 0, by: -1) {
            let entry = activeFormatting[index]
            if entry.isMarker { return nil }
            if entry.tag == tag { return index }
        }
        return nil
    }

    private func mergeAttributes(_ attributes: [HTMLAttribute], into node: DOMNode?) {
        guard let node else { return }
        for attribute in attributes where node.attributes[attribute.name] == nil {
            node.attributes[attribute.name] = attribute.value
        }
    }

    // MARK: - Table modes

    private func clearStackBackToTableContext() {
        while let node = currentNode, node.isHTMLNamespace, let tag = node.tagName,
              tag != "table", tag != "template", tag != "html" {
            openElements.removeLast()
        }
    }

    private func clearStackBackToTableBodyContext() {
        while let node = currentNode, node.isHTMLNamespace, let tag = node.tagName,
              tag != "tbody", tag != "tfoot", tag != "thead", tag != "template", tag != "html" {
            openElements.removeLast()
        }
    }

    private func clearStackBackToTableRowContext() {
        while let node = currentNode, node.isHTMLNamespace, let tag = node.tagName,
              tag != "tr", tag != "template", tag != "html" {
            openElements.removeLast()
        }
    }

    private func inTableMode(_ token: HTMLToken) {
        switch token {
        case .text:
            if let node = currentNode, node.isHTMLNamespace, let tag = node.tagName,
               ["table", "tbody", "template", "tfoot", "thead", "tr"].contains(tag) {
                pendingTableCharacters = []
                pendingTableCharactersAreWhitespaceOnly = true
                originalMode = mode
                reprocess(token, in: .inTableText)
            } else {
                inTableAnythingElse(token)
            }

        case .comment(let data): insertComment(data)
        case .doctype: return

        case .startTag(let name, let attributes, let selfClosing):
            switch name {
            case "caption":
                clearStackBackToTableContext()
                activeFormatting.append(.marker)
                insertElement(tag: name, attributes: attributes)
                mode = .inCaption
            case "colgroup":
                clearStackBackToTableContext()
                insertElement(tag: name, attributes: attributes)
                mode = .inColumnGroup
            case "col":
                clearStackBackToTableContext()
                insertElement(tag: "colgroup", attributes: [])
                reprocess(token, in: .inColumnGroup)
            case "tbody", "tfoot", "thead":
                clearStackBackToTableContext()
                insertElement(tag: name, attributes: attributes)
                mode = .inTableBody
            case "td", "th", "tr":
                clearStackBackToTableContext()
                insertElement(tag: "tbody", attributes: [])
                reprocess(token, in: .inTableBody)
            case "table":
                guard hasInTableScope(["table"]) else { return }
                popUntil("table")
                resetInsertionModeAppropriately()
                dispatch(token)
            case "style", "script", "template":
                inHeadMode(token)
            case "input":
                let type = attributes.first { $0.name == "type" }?.value.lowercased()
                guard type == "hidden" else {
                    inTableAnythingElse(token)
                    return
                }
                insertElement(tag: name, attributes: attributes, push: false)
                _ = selfClosing
            case "form":
                guard formElement == nil,
                      !openElements.contains(where: { isHTMLElement($0, "template") }) else { return }
                let element = insertElement(tag: name, attributes: attributes)
                formElement = element
                openElements.removeLast()
            default:
                inTableAnythingElse(token)
            }

        case .endTag(let name):
            switch name {
            case "table":
                guard hasInTableScope(["table"]) else { return }
                popUntil("table")
                resetInsertionModeAppropriately()
            case "body", "caption", "col", "colgroup", "html", "tbody", "td", "tfoot", "th", "thead", "tr":
                return
            case "template":
                inHeadMode(token)
            default:
                inTableAnythingElse(token)
            }
        }
    }

    /// Foster parenting: anything that does not belong in a table is inserted
    /// *before* the table instead of inside it.
    private func inTableAnythingElse(_ token: HTMLToken) {
        let saved = fosterParenting
        fosterParenting = true
        inBodyMode(token)
        fosterParenting = saved
    }

    private func inTableTextMode(_ token: HTMLToken) {
        if case .text(let raw) = token {
            let text = Self.strippingNulls(raw)
            guard !text.isEmpty else { return }
            if !Self.isASCIIWhitespaceOnly(text) { pendingTableCharactersAreWhitespaceOnly = false }
            pendingTableCharacters.append(text)
            return
        }
        flushPendingTableCharacters()
        reprocess(token, in: originalMode)
    }

    private func flushPendingTableCharacters() {
        let text = pendingTableCharacters.joined()
        pendingTableCharacters = []
        guard !text.isEmpty else { return }
        if pendingTableCharactersAreWhitespaceOnly {
            insertCharacters(text)
        } else {
            let saved = fosterParenting
            fosterParenting = true
            reconstructActiveFormatting()
            insertCharacters(text)
            framesetOK = false
            fosterParenting = saved
        }
        pendingTableCharactersAreWhitespaceOnly = true
    }

    private func inCaptionMode(_ token: HTMLToken) {
        switch token {
        case .endTag(let name) where name == "caption":
            guard hasInTableScope(["caption"]) else { return }
            generateImpliedEndTags()
            popUntil("caption")
            clearActiveFormattingToMarker()
            mode = .inTable
        case .startTag(let name, _, _)
            where ["caption", "col", "colgroup", "tbody", "td", "tfoot", "th", "thead", "tr"].contains(name):
            guard hasInTableScope(["caption"]) else { return }
            generateImpliedEndTags()
            popUntil("caption")
            clearActiveFormattingToMarker()
            reprocess(token, in: .inTable)
        case .endTag(let name) where name == "table":
            guard hasInTableScope(["caption"]) else { return }
            generateImpliedEndTags()
            popUntil("caption")
            clearActiveFormattingToMarker()
            reprocess(token, in: .inTable)
        case .endTag(let name)
            where ["body", "col", "colgroup", "html", "tbody", "td", "tfoot", "th", "thead", "tr"].contains(name):
            return
        default:
            inBodyMode(token)
        }
    }

    private func inColumnGroupMode(_ token: HTMLToken) {
        switch token {
        case .text(let text):
            let (whitespace, rest) = Self.splitLeadingWhitespace(text)
            if !whitespace.isEmpty { insertCharacters(whitespace) }
            if rest.isEmpty { return }
            columnGroupAnythingElse(.text(rest))
        case .comment(let data): insertComment(data)
        case .doctype: return
        case .startTag(let name, let attributes, _):
            switch name {
            case "html": inBodyMode(token)
            case "col": insertElement(tag: name, attributes: attributes, push: false)
            case "template": inHeadMode(token)
            default: columnGroupAnythingElse(token)
            }
        case .endTag(let name):
            switch name {
            case "colgroup":
                guard let node = currentNode, isHTMLElement(node, "colgroup") else { return }
                openElements.removeLast()
                mode = .inTable
            case "col": return
            case "template": inHeadMode(token)
            default: columnGroupAnythingElse(token)
            }
        }
    }

    private func columnGroupAnythingElse(_ token: HTMLToken) {
        guard let node = currentNode, isHTMLElement(node, "colgroup") else { return }
        openElements.removeLast()
        reprocess(token, in: .inTable)
    }

    private func inTableBodyMode(_ token: HTMLToken) {
        switch token {
        case .startTag(let name, let attributes, _):
            switch name {
            case "tr":
                clearStackBackToTableBodyContext()
                insertElement(tag: name, attributes: attributes)
                mode = .inRow
            case "th", "td":
                clearStackBackToTableBodyContext()
                insertElement(tag: "tr", attributes: [])
                reprocess(token, in: .inRow)
            case "caption", "col", "colgroup", "tbody", "tfoot", "thead":
                guard hasInTableScope(["tbody", "thead", "tfoot"]) else { return }
                clearStackBackToTableBodyContext()
                openElements.removeLast()
                reprocess(token, in: .inTable)
            default:
                inTableMode(token)
            }
        case .endTag(let name):
            switch name {
            case "tbody", "tfoot", "thead":
                guard hasInTableScope([name]) else { return }
                clearStackBackToTableBodyContext()
                openElements.removeLast()
                mode = .inTable
            case "table":
                guard hasInTableScope(["tbody", "thead", "tfoot"]) else { return }
                clearStackBackToTableBodyContext()
                openElements.removeLast()
                reprocess(token, in: .inTable)
            case "body", "caption", "col", "colgroup", "html", "td", "th", "tr":
                return
            default:
                inTableMode(token)
            }
        default:
            inTableMode(token)
        }
    }

    private func inRowMode(_ token: HTMLToken) {
        switch token {
        case .startTag(let name, let attributes, _):
            switch name {
            case "th", "td":
                clearStackBackToTableRowContext()
                insertElement(tag: name, attributes: attributes)
                mode = .inCell
                activeFormatting.append(.marker)
            case "caption", "col", "colgroup", "tbody", "tfoot", "thead", "tr":
                guard hasInTableScope(["tr"]) else { return }
                clearStackBackToTableRowContext()
                openElements.removeLast()
                reprocess(token, in: .inTableBody)
            default:
                inTableMode(token)
            }
        case .endTag(let name):
            switch name {
            case "tr":
                guard hasInTableScope(["tr"]) else { return }
                clearStackBackToTableRowContext()
                openElements.removeLast()
                mode = .inTableBody
            case "table":
                guard hasInTableScope(["tr"]) else { return }
                clearStackBackToTableRowContext()
                openElements.removeLast()
                reprocess(token, in: .inTableBody)
            case "tbody", "tfoot", "thead":
                guard hasInTableScope([name]), hasInTableScope(["tr"]) else { return }
                clearStackBackToTableRowContext()
                openElements.removeLast()
                reprocess(token, in: .inTableBody)
            case "body", "caption", "col", "colgroup", "html", "td", "th":
                return
            default:
                inTableMode(token)
            }
        default:
            inTableMode(token)
        }
    }

    private func closeCell() {
        generateImpliedEndTags()
        popUntilAny(["td", "th"])
        clearActiveFormattingToMarker()
        mode = .inRow
    }

    private func inCellMode(_ token: HTMLToken) {
        switch token {
        case .endTag(let name) where name == "td" || name == "th":
            guard hasInTableScope([name]) else { return }
            generateImpliedEndTags()
            popUntil(name)
            clearActiveFormattingToMarker()
            mode = .inRow
        case .startTag(let name, _, _)
            where ["caption", "col", "colgroup", "tbody", "td", "tfoot", "th", "thead", "tr"].contains(name):
            guard hasInTableScope(["td", "th"]) else { return }
            closeCell()
            dispatch(token)
        case .endTag(let name) where ["body", "caption", "col", "colgroup", "html"].contains(name):
            return
        case .endTag(let name) where ["table", "tbody", "tfoot", "thead", "tr"].contains(name):
            guard hasInTableScope([name]) else { return }
            closeCell()
            dispatch(token)
        default:
            inBodyMode(token)
        }
    }

    // MARK: - Select modes

    private func inSelectMode(_ token: HTMLToken) {
        switch token {
        case .text(let raw):
            let text = Self.strippingNulls(raw)
            if !text.isEmpty { insertCharacters(text) }
        case .comment(let data): insertComment(data)
        case .doctype: return
        case .startTag(let name, let attributes, _):
            switch name {
            case "html": inBodyMode(token)
            case "option":
                if let node = currentNode, isHTMLElement(node, "option") { openElements.removeLast() }
                insertElement(tag: name, attributes: attributes)
            case "optgroup":
                if let node = currentNode, isHTMLElement(node, "option") { openElements.removeLast() }
                if let node = currentNode, isHTMLElement(node, "optgroup") { openElements.removeLast() }
                insertElement(tag: name, attributes: attributes)
            case "select":
                guard hasInSelectScope("select") else { return }
                popUntil("select")
                resetInsertionModeAppropriately()
            case "input", "keygen", "textarea":
                guard hasInSelectScope("select") else { return }
                popUntil("select")
                resetInsertionModeAppropriately()
                dispatch(token)
            case "script", "template":
                inHeadMode(token)
            default:
                return
            }
        case .endTag(let name):
            switch name {
            case "optgroup":
                if openElements.count >= 2,
                   isHTMLElement(openElements[openElements.count - 1], "option"),
                   isHTMLElement(openElements[openElements.count - 2], "optgroup") {
                    openElements.removeLast()
                }
                if let node = currentNode, isHTMLElement(node, "optgroup") { openElements.removeLast() }
            case "option":
                if let node = currentNode, isHTMLElement(node, "option") { openElements.removeLast() }
            case "select":
                guard hasInSelectScope("select") else { return }
                popUntil("select")
                resetInsertionModeAppropriately()
            case "template":
                inHeadMode(token)
            default:
                return
            }
        }
    }

    private func inSelectInTableMode(_ token: HTMLToken) {
        let tableish: Set<String> = ["caption", "table", "tbody", "tfoot", "thead", "tr", "td", "th"]
        switch token {
        case .startTag(let name, _, _) where tableish.contains(name):
            popUntil("select")
            resetInsertionModeAppropriately()
            dispatch(token)
        case .endTag(let name) where tableish.contains(name):
            guard hasInTableScope([name]) else { return }
            popUntil("select")
            resetInsertionModeAppropriately()
            dispatch(token)
        default:
            inSelectMode(token)
        }
    }

    // MARK: - "in template"

    private func inTemplateMode(_ token: HTMLToken) {
        switch token {
        case .text, .comment, .doctype:
            inBodyMode(token)
        case .startTag(let name, _, _):
            switch name {
            case "base", "basefont", "bgsound", "link", "meta", "noframes", "script",
                 "style", "template", "title":
                inHeadMode(token)
            case "caption", "colgroup", "tbody", "tfoot", "thead":
                switchTemplateMode(to: .inTable, reprocessing: token)
            case "col":
                switchTemplateMode(to: .inColumnGroup, reprocessing: token)
            case "tr":
                switchTemplateMode(to: .inTableBody, reprocessing: token)
            case "td", "th":
                switchTemplateMode(to: .inRow, reprocessing: token)
            default:
                switchTemplateMode(to: .inBody, reprocessing: token)
            }
        case .endTag(let name):
            if name == "template" { inHeadMode(token) }
        }
    }

    private func switchTemplateMode(to newMode: InsertionMode, reprocessing token: HTMLToken) {
        if !templateModes.isEmpty { templateModes.removeLast() }
        templateModes.append(newMode)
        reprocess(token, in: newMode)
    }

    // MARK: - After body / frameset modes

    private func afterBodyMode(_ token: HTMLToken) {
        switch token {
        case .text(let text) where Self.isASCIIWhitespaceOnly(text):
            inBodyMode(token)
        case .comment(let data):
            insertComment(data, target: openElements.first ?? document)
        case .doctype: return
        case .startTag(let name, _, _) where name == "html":
            inBodyMode(token)
        case .endTag(let name) where name == "html":
            if fragmentParsing { return }
            mode = .afterAfterBody
        default:
            reprocess(token, in: .inBody)
        }
    }

    private func inFramesetMode(_ token: HTMLToken) {
        switch token {
        case .text(let text):
            let (whitespace, _) = Self.splitLeadingWhitespace(text)
            if !whitespace.isEmpty { insertCharacters(whitespace) }
        case .comment(let data): insertComment(data)
        case .doctype: return
        case .startTag(let name, let attributes, _):
            switch name {
            case "html": inBodyMode(token)
            case "frameset": insertElement(tag: name, attributes: attributes)
            case "frame": insertElement(tag: name, attributes: attributes, push: false)
            case "noframes": inHeadMode(token)
            default: return
            }
        case .endTag(let name) where name == "frameset":
            guard let node = currentNode, !isHTMLElement(node, "html") else { return }
            openElements.removeLast()
            if !fragmentParsing, let node = currentNode, !isHTMLElement(node, "frameset") {
                mode = .afterFrameset
            }
        case .endTag: return
        }
    }

    private func afterFramesetMode(_ token: HTMLToken) {
        switch token {
        case .text(let text):
            let (whitespace, _) = Self.splitLeadingWhitespace(text)
            if !whitespace.isEmpty { insertCharacters(whitespace) }
        case .comment(let data): insertComment(data)
        case .doctype: return
        case .startTag(let name, _, _) where name == "html": inBodyMode(token)
        case .startTag(let name, _, _) where name == "noframes": inHeadMode(token)
        case .endTag(let name) where name == "html": mode = .afterAfterFrameset
        default: return
        }
    }

    private func afterAfterBodyMode(_ token: HTMLToken) {
        switch token {
        case .comment(let data): insertComment(data, target: document)
        case .doctype: return
        case .text(let text) where Self.isASCIIWhitespaceOnly(text): inBodyMode(token)
        case .startTag(let name, _, _) where name == "html": inBodyMode(token)
        default: reprocess(token, in: .inBody)
        }
    }

    private func afterAfterFramesetMode(_ token: HTMLToken) {
        switch token {
        case .comment(let data): insertComment(data, target: document)
        case .doctype: return
        case .text(let text) where Self.isASCIIWhitespaceOnly(text): inBodyMode(token)
        case .startTag(let name, _, _) where name == "html": inBodyMode(token)
        case .startTag(let name, _, _) where name == "noframes": inHeadMode(token)
        default: return
        }
    }

    // MARK: - Reset the insertion mode appropriately (§13.2.6.2)

    private func resetInsertionModeAppropriately() {
        var last = false
        var index = openElements.count - 1
        while index >= 0 {
            var node = openElements[index]
            if index == 0 {
                last = true
                if fragmentParsing, let ctx = contextElement { node = ctx }
            }
            if node.isHTMLNamespace, let tag = node.tagName {
                switch tag {
                case "select":
                    if !last {
                        var ancestorIndex = index
                        while ancestorIndex > 0 {
                            ancestorIndex -= 1
                            let ancestor = openElements[ancestorIndex]
                            if isHTMLElement(ancestor, "template") { break }
                            if isHTMLElement(ancestor, "table") {
                                mode = .inSelectInTable
                                return
                            }
                        }
                    }
                    mode = .inSelect
                    return
                case "td", "th":
                    if !last { mode = .inCell; return }
                case "tr":
                    mode = .inRow; return
                case "tbody", "thead", "tfoot":
                    mode = .inTableBody; return
                case "caption":
                    mode = .inCaption; return
                case "colgroup":
                    mode = .inColumnGroup; return
                case "table":
                    mode = .inTable; return
                case "template":
                    mode = templateModes.last ?? .inBody; return
                case "head":
                    if !last { mode = .inHead; return }
                case "body":
                    mode = .inBody; return
                case "frameset":
                    mode = .inFrameset; return
                case "html":
                    mode = headElement == nil ? .beforeHead : .afterHead
                    return
                default:
                    break
                }
            }
            if last { mode = .inBody; return }
            index -= 1
        }
        mode = .inBody
    }

    // MARK: - Adoption agency (§13.2.6.4.7)

    /// Repairs misnested formatting elements: `<b><i></b></i>` ends up as
    /// `<b><i></i></b><i></i>`, and the reopened `<i>` keeps the original's
    /// attributes.
    private func adoptionAgency(for subject: String) {
        if let current = currentNode, isHTMLElement(current, subject),
           !activeFormatting.contains(where: { $0.element === current }) {
            openElements.removeLast()
            return
        }

        var outer = 0
        while outer < 8 {
            outer += 1

            guard let formattingIndex = lastActiveFormattingIndex(of: subject),
                  let formattingElement = activeFormatting[formattingIndex].element else {
                anyOtherEndTag(subject)
                return
            }
            let formattingEntry = activeFormatting[formattingIndex]

            guard let stackIndex = openElements.lastIndex(where: { $0 === formattingElement }) else {
                activeFormatting.remove(at: formattingIndex)
                return
            }
            guard hasInScope({ $0 === formattingElement }, extra: []) else { return }

            var furthestBlockIndex: Int?
            var scan = stackIndex + 1
            while scan < openElements.count {
                let node = openElements[scan]
                if node.isHTMLNamespace, let tag = node.tagName, HTMLElements.special.contains(tag) {
                    furthestBlockIndex = scan
                    break
                }
                scan += 1
            }

            guard let blockIndex = furthestBlockIndex else {
                openElements.removeSubrange(stackIndex...)
                activeFormatting.remove(at: formattingIndex)
                return
            }

            let furthestBlock = openElements[blockIndex]
            let commonAncestor = openElements[stackIndex - 1]
            var bookmark = formattingIndex

            var lastNode = furthestBlock
            var nodeIndex = blockIndex
            var inner = 0

            while true {
                inner += 1
                nodeIndex -= 1
                guard nodeIndex >= 0 else { break }
                var node = openElements[nodeIndex]
                if node === formattingElement { break }

                let entryIndex = activeFormatting.firstIndex { $0.element === node }
                if inner > 3, let entryIndex {
                    activeFormatting.remove(at: entryIndex)
                    if entryIndex < bookmark { bookmark -= 1 }
                    openElements.remove(at: nodeIndex)
                    continue
                }
                guard let entryIndex else {
                    openElements.remove(at: nodeIndex)
                    continue
                }

                let entry = activeFormatting[entryIndex]
                let replacement = createElement(tag: entry.tag, attributes: entry.attributes)
                activeFormatting[entryIndex].element = replacement
                openElements[nodeIndex] = replacement
                node = replacement

                if lastNode === furthestBlock { bookmark = entryIndex + 1 }
                lastNode.parent?.removeChild(lastNode)
                node.appendChild(lastNode)
                lastNode = node
            }

            lastNode.parent?.removeChild(lastNode)
            let savedFoster = fosterParenting
            fosterParenting = true
            insert(lastNode, overrideTarget: commonAncestor)
            fosterParenting = savedFoster

            let newFormatting = createElement(tag: formattingEntry.tag, attributes: formattingEntry.attributes)
            for child in furthestBlock.children {
                furthestBlock.removeChild(child)
                newFormatting.appendChild(child)
            }
            furthestBlock.appendChild(newFormatting)

            if let index = activeFormatting.firstIndex(where: { $0.element === formattingElement }) {
                activeFormatting.remove(at: index)
                if index < bookmark { bookmark -= 1 }
            }
            bookmark = min(max(bookmark, 0), activeFormatting.count)
            activeFormatting.insert(
                FormattingEntry(element: newFormatting, tag: formattingEntry.tag, attributes: formattingEntry.attributes),
                at: bookmark
            )

            openElements.removeAll { $0 === formattingElement }
            if let index = openElements.lastIndex(where: { $0 === furthestBlock }) {
                openElements.insert(newFormatting, at: index + 1)
            } else {
                openElements.append(newFormatting)
            }
        }
    }

    // MARK: - Foreign content (§13.2.6.5)

    private static let foreignBreakout: Set<String> = [
        "b", "big", "blockquote", "body", "br", "center", "code", "dd", "div", "dl",
        "dt", "em", "embed", "h1", "h2", "h3", "h4", "h5", "h6", "head", "hr", "i",
        "img", "li", "listing", "menu", "meta", "nobr", "ol", "p", "pre", "ruby",
        "s", "small", "span", "strong", "strike", "sub", "sup", "table", "tt", "u",
        "ul", "var",
    ]

    private func insertForeignElement(
        tag: String,
        attributes: [HTMLAttribute],
        namespace: String,
        selfClosing: Bool
    ) {
        let adjustedTag = namespace == DOMNode.svgNamespace ? (Self.svgTagAdjustments[tag] ?? tag) : tag
        let adjusted = Self.adjustForeignAttributes(attributes, namespace: namespace)
        insertElement(tag: adjustedTag, attributes: adjusted, namespace: namespace, preserveCase: true)
        if selfClosing { openElements.removeLast() }
    }

    private func foreignContent(_ token: HTMLToken) {
        switch token {
        case .doctype:
            return

        case .comment(let data):
            insertComment(data)

        case .text(let raw):
            // NUL becomes U+FFFD here rather than being dropped.
            let text = raw.contains("\0") ? raw.replacingOccurrences(of: "\0", with: "\u{FFFD}") : raw
            guard !text.isEmpty else { return }
            insertCharacters(text)
            if !Self.isASCIIWhitespaceOnly(text) { framesetOK = false }

        case .startTag(let name, let attributes, let selfClosing):
            let isFontBreakout = name == "font" && attributes.contains {
                $0.name == "color" || $0.name == "face" || $0.name == "size"
            }
            if Self.foreignBreakout.contains(name) || isFontBreakout {
                while let node = currentNode, !node.isHTMLNamespace,
                      !isHTMLIntegrationPoint(node),
                      !(node.namespaceURI == DOMNode.mathmlNamespace
                        && HTMLElements.mathmlTextIntegration.contains(node.tagName ?? "")) {
                    openElements.removeLast()
                }
                dispatch(token)
                return
            }
            guard let namespace = adjustedCurrentNode?.namespaceURI else { return }
            insertForeignElement(tag: name, attributes: attributes, namespace: namespace, selfClosing: selfClosing)

        case .endTag(let name):
            if name == "script", let node = currentNode,
               node.namespaceURI == DOMNode.svgNamespace, node.tagName == "script" {
                openElements.removeLast()
                return
            }
            var index = openElements.count - 1
            guard index >= 0 else { return }
            while true {
                let node = openElements[index]
                if index == 0 { return }
                if (node.tagName ?? "").lowercased() == name {
                    while openElements.count > index { openElements.removeLast() }
                    return
                }
                index -= 1
                if openElements[index].isHTMLNamespace {
                    process(token, in: mode)
                    return
                }
            }
        }
    }

    /// SVG element names are case-sensitive; the tokenizer lowercased them.
    private static let svgTagAdjustments: [String: String] = [
        "altglyph": "altGlyph", "altglyphdef": "altGlyphDef", "altglyphitem": "altGlyphItem",
        "animatecolor": "animateColor", "animatemotion": "animateMotion",
        "animatetransform": "animateTransform", "clippath": "clipPath",
        "feblend": "feBlend", "fecolormatrix": "feColorMatrix",
        "fecomponenttransfer": "feComponentTransfer", "fecomposite": "feComposite",
        "feconvolvematrix": "feConvolveMatrix", "fediffuselighting": "feDiffuseLighting",
        "fedisplacementmap": "feDisplacementMap", "fedistantlight": "feDistantLight",
        "fedropshadow": "feDropShadow", "feflood": "feFlood", "fefunca": "feFuncA",
        "fefuncb": "feFuncB", "fefuncg": "feFuncG", "fefuncr": "feFuncR",
        "fegaussianblur": "feGaussianBlur", "feimage": "feImage", "femerge": "feMerge",
        "femergenode": "feMergeNode", "femorphology": "feMorphology", "feoffset": "feOffset",
        "fepointlight": "fePointLight", "fespecularlighting": "feSpecularLighting",
        "fespotlight": "feSpotLight", "fetile": "feTile", "feturbulence": "feTurbulence",
        "foreignobject": "foreignObject", "glyphref": "glyphRef",
        "lineargradient": "linearGradient", "radialgradient": "radialGradient",
        "textpath": "textPath",
    ]

    /// SVG attribute names that are case-sensitive — `viewBox` above all.
    private static let svgAttributeAdjustments: [String: String] = [
        "attributename": "attributeName", "attributetype": "attributeType",
        "basefrequency": "baseFrequency", "baseprofile": "baseProfile",
        "calcmode": "calcMode", "clippathunits": "clipPathUnits",
        "diffuseconstant": "diffuseConstant", "edgemode": "edgeMode",
        "filterunits": "filterUnits", "glyphref": "glyphRef",
        "gradienttransform": "gradientTransform", "gradientunits": "gradientUnits",
        "kernelmatrix": "kernelMatrix", "kernelunitlength": "kernelUnitLength",
        "keypoints": "keyPoints", "keysplines": "keySplines", "keytimes": "keyTimes",
        "lengthadjust": "lengthAdjust", "limitingconeangle": "limitingConeAngle",
        "markerheight": "markerHeight", "markerunits": "markerUnits",
        "markerwidth": "markerWidth", "maskcontentunits": "maskContentUnits",
        "maskunits": "maskUnits", "numoctaves": "numOctaves", "pathlength": "pathLength",
        "patterncontentunits": "patternContentUnits", "patterntransform": "patternTransform",
        "patternunits": "patternUnits", "pointsatx": "pointsAtX", "pointsaty": "pointsAtY",
        "pointsatz": "pointsAtZ", "preservealpha": "preserveAlpha",
        "preserveaspectratio": "preserveAspectRatio", "primitiveunits": "primitiveUnits",
        "refx": "refX", "refy": "refY", "repeatcount": "repeatCount", "repeatdur": "repeatDur",
        "requiredextensions": "requiredExtensions", "requiredfeatures": "requiredFeatures",
        "specularconstant": "specularConstant", "specularexponent": "specularExponent",
        "spreadmethod": "spreadMethod", "startoffset": "startOffset",
        "stddeviation": "stdDeviation", "stitchtiles": "stitchTiles",
        "surfacescale": "surfaceScale", "systemlanguage": "systemLanguage",
        "tablevalues": "tableValues", "targetx": "targetX", "targety": "targetY",
        "textlength": "textLength", "viewbox": "viewBox", "viewtarget": "viewTarget",
        "xchannelselector": "xChannelSelector", "ychannelselector": "yChannelSelector",
        "zoomandpan": "zoomAndPan",
    ]

    // The xlink:/xml:/xmlns: family needs no adjustment table here: those
    // names are already all-lowercase in the source, and this DOM keeps
    // attributes as flat `prefix:local` strings rather than namespaced pairs.

    private static func adjustForeignAttributes(
        _ attributes: [HTMLAttribute],
        namespace: String
    ) -> [HTMLAttribute] {
        attributes.map { attribute in
            if namespace == DOMNode.svgNamespace, let adjusted = svgAttributeAdjustments[attribute.name] {
                return HTMLAttribute(name: adjusted, value: attribute.value)
            }
            if namespace == DOMNode.mathmlNamespace, attribute.name == "definitionurl" {
                return HTMLAttribute(name: "definitionURL", value: attribute.value)
            }
            return attribute
        }
    }

    // MARK: - Quirks mode (§13.2.6.4.1)

    static func quirksMode(for doctype: HTMLDoctype) -> DOMNode.QuirksMode {
        if doctype.forceQuirks { return .quirks }
        if (doctype.name ?? "") != "html" { return .quirks }

        let publicId = (doctype.publicId ?? "").lowercased()
        let systemId = (doctype.systemId ?? "").lowercased()

        if publicId == "-//w3o//dtd w3 html strict 3.0//en//"
            || publicId == "-/w3c/dtd html 4.0 transitional/en"
            || publicId == "html" {
            return .quirks
        }
        if systemId == "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd" { return .quirks }
        if quirksPublicPrefixes.contains(where: { publicId.hasPrefix($0) }) { return .quirks }
        if doctype.systemId == nil,
           publicId.hasPrefix("-//w3c//dtd html 4.01 frameset//")
            || publicId.hasPrefix("-//w3c//dtd html 4.01 transitional//") {
            return .quirks
        }

        if publicId.hasPrefix("-//w3c//dtd xhtml 1.0 frameset//")
            || publicId.hasPrefix("-//w3c//dtd xhtml 1.0 transitional//") {
            return .limitedQuirks
        }
        if doctype.systemId != nil,
           publicId.hasPrefix("-//w3c//dtd html 4.01 frameset//")
            || publicId.hasPrefix("-//w3c//dtd html 4.01 transitional//") {
            return .limitedQuirks
        }
        return .noQuirks
    }

    private static let quirksPublicPrefixes: [String] = [
        "+//silmaril//dtd html pro v0r11 19970101//",
        "-//as//dtd html 3.0 aswedit + extensions//",
        "-//advasoft ltd//dtd html 3.0 aswedit + extensions//",
        "-//ietf//dtd html 2.0 level 1//",
        "-//ietf//dtd html 2.0 level 2//",
        "-//ietf//dtd html 2.0 strict level 1//",
        "-//ietf//dtd html 2.0 strict level 2//",
        "-//ietf//dtd html 2.0 strict//",
        "-//ietf//dtd html 2.0//",
        "-//ietf//dtd html 2.1e//",
        "-//ietf//dtd html 3.0//",
        "-//ietf//dtd html 3.2 final//",
        "-//ietf//dtd html 3.2//",
        "-//ietf//dtd html 3//",
        "-//ietf//dtd html level 0//",
        "-//ietf//dtd html level 1//",
        "-//ietf//dtd html level 2//",
        "-//ietf//dtd html level 3//",
        "-//ietf//dtd html strict level 0//",
        "-//ietf//dtd html strict level 1//",
        "-//ietf//dtd html strict level 2//",
        "-//ietf//dtd html strict level 3//",
        "-//ietf//dtd html strict//",
        "-//ietf//dtd html//",
        "-//metrius//dtd metrius presentational//",
        "-//microsoft//dtd internet explorer 2.0 html strict//",
        "-//microsoft//dtd internet explorer 2.0 html//",
        "-//microsoft//dtd internet explorer 2.0 tables//",
        "-//microsoft//dtd internet explorer 3.0 html strict//",
        "-//microsoft//dtd internet explorer 3.0 html//",
        "-//microsoft//dtd internet explorer 3.0 tables//",
        "-//netscape comm. corp.//dtd html//",
        "-//netscape comm. corp.//dtd strict html//",
        "-//o'reilly and associates//dtd html 2.0//",
        "-//o'reilly and associates//dtd html extended 1.0//",
        "-//o'reilly and associates//dtd html extended relaxed 1.0//",
        "-//sq//dtd html 2.0 hotmetal + extensions//",
        "-//softquad software//dtd hotmetal pro 6.0::19990601::extensions to html 4.0//",
        "-//softquad//dtd hotmetal pro 4.0::19971010::extensions to html 4.0//",
        "-//spyglass//dtd html 2.0 extended//",
        "-//sun microsystems corp.//dtd hotjava html//",
        "-//sun microsystems corp.//dtd hotjava strict html//",
        "-//w3c//dtd html 3 1995-03-24//",
        "-//w3c//dtd html 3.2 draft//",
        "-//w3c//dtd html 3.2 final//",
        "-//w3c//dtd html 3.2//",
        "-//w3c//dtd html 3.2s draft//",
        "-//w3c//dtd html 4.0 frameset//",
        "-//w3c//dtd html 4.0 transitional//",
        "-//w3c//dtd html experimental 19960712//",
        "-//w3c//dtd html experimental 970421//",
        "-//w3c//dtd w3 html//",
        "-//w3o//dtd w3 html 3.0//",
        "-//webtechs//dtd mozilla html 2.0//",
        "-//webtechs//dtd mozilla html//",
    ]
}
