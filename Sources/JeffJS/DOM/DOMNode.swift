import Foundation

// MARK: - DOM Node

/// A node in the parsed HTML document tree.
public final class DOMNode: @unchecked Sendable, Identifiable {
    public let id = UUID()
    public let nodeType: NodeType
    public internal(set) weak var parent: DOMNode?

    /// Lock protecting `_children` from concurrent read/write races.
    private let childrenLock = NSLock()
    private var _children: [DOMNode] = []

    /// Thread-safe accessor for the children array.
    /// Reading returns a snapshot; mutations must go through
    /// `appendChild`, `removeChild`, or `clearChildren`.
    public internal(set) var children: [DOMNode] {
        get {
            childrenLock.lock()
            let snapshot = _children
            childrenLock.unlock()
            return snapshot
        }
        set {
            childrenLock.lock()
            _children = newValue
            childrenLock.unlock()
        }
    }

    // Element-specific
    public let tagName: String?
    public internal(set) var attributes: [String: String]

    // Text/comment content
    public internal(set) var textContent: String?

    public enum NodeType: Sendable, Hashable {
        case document
        case documentFragment
        case element
        case text
        case comment
    }

    // MARK: - Factories

    public static func document() -> DOMNode {
        DOMNode(nodeType: .document, tagName: nil, attributes: [:], textContent: nil)
    }

    public static func documentFragment() -> DOMNode {
        DOMNode(nodeType: .documentFragment, tagName: nil, attributes: [:], textContent: nil)
    }

    public static func element(tag: String, attributes: [String: String] = [:], preserveCase: Bool = false) -> DOMNode {
        let resolvedTag = preserveCase ? tag : tag.lowercased()
        return DOMNode(nodeType: .element, tagName: resolvedTag, attributes: attributes, textContent: nil)
    }

    public static func text(_ content: String) -> DOMNode {
        DOMNode(nodeType: .text, tagName: nil, attributes: [:], textContent: content)
    }

    public static func comment(_ content: String) -> DOMNode {
        DOMNode(nodeType: .comment, tagName: nil, attributes: [:], textContent: content)
    }

    /// Cached class list, invalidated when the `class` attribute changes.
    private var _cachedClassList: Set<String>?

    private init(nodeType: NodeType, tagName: String?, attributes: [String: String], textContent: String?) {
        self.nodeType = nodeType
        self.tagName = tagName
        self.attributes = attributes
        self.textContent = textContent
    }

    /// Invalidate cached classList when class attribute may have changed.
    private func invalidateClassListIfNeeded(_ name: String) {
        if name == "class" { _cachedClassList = nil }
    }

    // MARK: - Computed Properties

    public var classList: Set<String> {
        if let cached = _cachedClassList { return cached }
        guard let cls = attributes["class"] else { return [] }
        let result = Set(cls.split(separator: " ").map(String.init))
        _cachedClassList = result
        return result
    }

    public var idAttribute: String? {
        attributes["id"]
    }

    public var inlineStyle: String? {
        attributes["style"]
    }

    public var childElements: [DOMNode] {
        children.filter { $0.nodeType == .element }
    }

    /// Tags whose text content is not part of the visible page output.
    private static let nonVisibleTextTags: Set<String> = [
        "style", "script", "noscript", "template", "datalist"
    ]

    /// Recursively collects all visible descendant text content, skipping
    /// elements like `<style>` and `<script>` whose raw text should never
    /// appear as rendered output.
    public var textDescendants: String {
        switch nodeType {
        case .text:
            return textContent ?? ""
        case .element, .document, .documentFragment:
            return children.compactMap { child -> String? in
                if let tag = child.tagName, Self.nonVisibleTextTags.contains(tag) {
                    return nil
                }
                return child.textDescendants
            }.joined()
        case .comment:
            return ""
        }
    }

    /// Recursively collects ALL descendant text content including non-visible
    /// elements. Used by CSS/JS extraction where the raw text of `<style>` and
    /// `<script>` elements is needed.
    public var rawTextDescendants: String {
        switch nodeType {
        case .text:
            return textContent ?? ""
        case .element, .document, .documentFragment:
            return children.map(\.rawTextDescendants).joined()
        case .comment:
            return ""
        }
    }

    // MARK: - Tree Mutation (used during parsing)

    func appendChild(_ child: DOMNode) {
        child.parent = self
        childrenLock.lock()
        _children.append(child)
        childrenLock.unlock()
    }

    func removeChild(_ child: DOMNode) {
        childrenLock.lock()
        _children.removeAll { $0 === child }
        childrenLock.unlock()
        child.parent = nil
    }

    /// Inserts `child` before `before` in the children array atomically.
    /// Falls back to appending if `before` is not found.
    func insertChild(_ child: DOMNode, before: DOMNode) {
        child.parent = self
        childrenLock.lock()
        if let index = _children.firstIndex(where: { $0 === before }) {
            _children.insert(child, at: index)
        } else {
            _children.append(child)
        }
        childrenLock.unlock()
    }

    /// Inserts `child` after `after` in the children array atomically.
    /// Falls back to appending if `after` is not found.
    func insertChild(_ child: DOMNode, after: DOMNode) {
        child.parent = self
        childrenLock.lock()
        if let index = _children.firstIndex(where: { $0 === after }) {
            _children.insert(child, at: index + 1)
        } else {
            _children.append(child)
        }
        childrenLock.unlock()
    }

    /// Inserts `child` at a specific index atomically.
    func insertChild(_ child: DOMNode, at index: Int) {
        child.parent = self
        childrenLock.lock()
        let clamped = min(index, _children.count)
        _children.insert(child, at: clamped)
        childrenLock.unlock()
    }

    /// Atomically removes `old` and inserts `replacements` at its position.
    /// Returns the removed node, or nil if not found.
    @discardableResult
    func replaceChild(_ old: DOMNode, with replacements: [DOMNode]) -> DOMNode? {
        childrenLock.lock()
        guard let index = _children.firstIndex(where: { $0 === old }) else {
            childrenLock.unlock()
            return nil
        }
        _children.remove(at: index)
        for (offset, replacement) in replacements.enumerated() {
            replacement.parent = self
            _children.insert(replacement, at: index + offset)
        }
        childrenLock.unlock()
        old.parent = nil
        return old
    }

    public func clearChildren() {
        childrenLock.lock()
        let old = _children
        _children.removeAll()
        childrenLock.unlock()
        for child in old {
            child.parent = nil
        }
    }

    public func setAttribute(name: String, value: String) {
        let lower = name.lowercased()
        attributes[lower] = value
        invalidateClassListIfNeeded(lower)
    }

    public func removeAttribute(name: String) {
        let lower = name.lowercased()
        attributes.removeValue(forKey: lower)
        invalidateClassListIfNeeded(lower)
    }

    public func setAttributePreservingCase(name: String, value: String) {
        attributes[name] = value
        invalidateClassListIfNeeded(name.lowercased())
    }

    public func removeAttributePreservingCase(name: String) {
        attributes.removeValue(forKey: name)
        attributes.removeValue(forKey: name.lowercased())
        invalidateClassListIfNeeded("class")
    }

    public func setTextContent(_ text: String?) {
        switch nodeType {
        case .text, .comment:
            textContent = text
        case .element, .document, .documentFragment:
            clearChildren()
            guard let text, !text.isEmpty else { return }
            appendChild(.text(text))
        }
    }

    public func querySelector(_ selector: String) -> DOMNode? {
        querySelectorAll(selector).first
    }

    public func querySelectorAll(_ selector: String) -> [DOMNode] {
        let selectorList = CSSSelectorParser.parse(selector)
        guard !selectorList.selectors.isEmpty else { return [] }

        var results: [DOMNode] = []
        for node in allDescendantElements() {
            if selectorList.selectors.contains(where: { CSSSelectorMatcher.matches($0, node: node) }) {
                results.append(node)
            }
        }
        return results
    }

    private func allDescendantElements() -> [DOMNode] {
        var result: [DOMNode] = []

        func traverse(_ node: DOMNode) {
            for child in node.children {
                if child.nodeType == .element {
                    result.append(child)
                }
                traverse(child)
            }
        }

        if nodeType == .element {
            result.append(self)
        }
        traverse(self)
        return result
    }

    // MARK: - Element Classification

    public static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"
    ]

    public static let inlineElements: Set<String> = [
        "a", "abbr", "b", "bdi", "bdo", "br", "cite", "code", "data",
        "em", "i", "kbd", "mark", "q", "s", "samp", "small", "span",
        "strong", "sub", "sup", "time", "u", "var"
    ]

    public static let blockElements: Set<String> = [
        "address", "article", "aside", "blockquote", "canvas", "details", "dialog",
        "dd", "div", "dl", "dt", "fieldset", "figcaption", "figure",
        "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header",
        "hgroup", "hr", "li", "main", "nav", "noscript", "ol", "p", "pre",
        "section", "table", "tfoot", "ul", "video"
    ]

    public var isVoid: Bool {
        guard let tag = tagName else { return false }
        return Self.voidElements.contains(tag)
    }

    public var isInlineElement: Bool {
        guard let tag = tagName else { return false }
        return Self.inlineElements.contains(tag)
    }

    public var isBlockElement: Bool {
        guard let tag = tagName else { return false }
        return Self.blockElements.contains(tag)
    }
}
