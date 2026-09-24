import Foundation
import Synchronization

// MARK: - DOM Node
//
// Threading contract
// ------------------
// One mutating thread; any number of reader threads may call the matching,
// attribute, children, parent and text getters concurrently and observe a
// consistent snapshot per call.
//
// * Everything a reader can observe that changes after a node is created lives
//   in `state`, a `Mutex` (os_unfair_lock) per node: parent, children,
//   attributes (with their order and aliases), text data, quirks mode, the
//   cached `id`, the lazily built class tokens and the selector-matching cache
//   entry (`DOMNode+SelectorCache.swift`). A getter takes the lock once, reads
//   (or copies out a copy-on-write value: an array or dictionary snapshot the
//   writer can no longer change) and releases it. Hot matching reads (`hasClass`,
//   `idAttribute`, `attributeValue(_:)`) look up in place under the lock, so they
//   neither allocate nor retain the collection. No getter holds two nodes' locks
//   at once; the writer never does either, so there is no lock order to break.
// * Lazily built caches (class tokens, selector-cache entries) are built into
//   a local outside the lock and published under it only if their input has
//   not changed since (class tokens: `classGeneration`; selector entries: the
//   global selector epoch, an `Atomic` bumped with release ordering *after* the
//   mutation it announces and loaded with acquire ordering by readers). A read
//   racing a write therefore sees the state before or after it, never a mix
//   within one call, and a stale cache entry is never trusted under a newer epoch.
// * `nodeType`, `tagName`, `lowercasedTagName` and `id` are immutable;
//   `namespaceURI` and `isDocumentType` are set by the factories before a node
//   is inserted anywhere (insertion publishes them through the parent's lock).
// * Script-only bookkeeping (`nodeDocument`, `scriptAlreadyStarted`,
//   `scriptNonBlocking`) is touched by the mutating thread only.

/// A node in the parsed HTML document tree.
public final class DOMNode: @unchecked Sendable, Identifiable {
    public let id = UUID()
    public let nodeType: NodeType

    /// The reader-visible mutable state, guarded by one lock per node (see the
    /// threading contract above).
    struct State {
        /// Any change invalidates every node's selector-matching cache (the
        /// language and ancestor filter are functions of the parent chain).
        weak var parent: DOMNode?
        var children: [DOMNode] = []
        var attributes: [String: String]
        /// Attribute names in the order they were added (see `orderedAttributeNames`).
        var attributeOrder: [String] = []
        var aliasAttributeKeys: Set<String> = []
        var textContent: String?
        var quirksMode: QuirksMode = .noQuirks
        /// `attributes["id"]`, kept in step with every attribute write so the
        /// hot `#id` test does not hash a key.
        var idValue: String?
        /// Lazily built class tokens; nil until built after the last `class` change.
        var classSet: Set<String>?
        var classNames: [String]?
        /// Bumped on every possible `class` change: a lazy token build publishes
        /// its result only if this has not moved since it read the attribute.
        var classGeneration: UInt64 = 0
        /// Selector-matching cache (`DOMNode+SelectorCache.swift`).
        var selectorCache = DOMSelectorCacheEntry()

        init(attributes: [String: String], textContent: String?) {
            self.attributes = attributes
            self.textContent = textContent
            self.idValue = attributes["id"]
        }

        @inline(__always)
        mutating func invalidateClasses() {
            classSet = nil
            classNames = nil
            classGeneration &+= 1
        }

        /// Keep the derived caches in step after `key` (lowercased) changed.
        @inline(__always)
        mutating func attributeDidChange(_ key: String) {
            if key == "id" {
                idValue = attributes["id"]
            } else if key == "class" {
                invalidateClasses()
            }
        }

        /// After the whole dictionary was replaced or several keys changed.
        mutating func attributesReplaced() {
            idValue = attributes["id"]
            invalidateClasses()
        }
    }

    let state: Mutex<State>

    /// The selector-cache entry's epoch and language in one word, written
    /// with the entry (under `state`'s lock) and read lock-free by `:lang()`
    /// (`DOMNode+SelectorCache.swift`). 0 = no entry.
    let selectorLanguageStamp = Atomic<UInt64>(0)

    /// The parent node (weak). Any change bumps the selector epoch.
    public internal(set) var parent: DOMNode? {
        get { state.withLock { $0.parent } }
        set {
            state.withLock { $0.parent = newValue }
            DOMNode.bumpSelectorEpoch()
        }
    }

    /// A snapshot of the children. Mutations go through `appendChild`,
    /// `removeChild`, `insertChild`, `replaceChild` or `clearChildren`.
    public internal(set) var children: [DOMNode] {
        get { state.withLock { $0.children } }
        set { state.withLock { $0.children = newValue } }
    }

    // Element-specific
    public let tagName: String?
    /// ASCII-lowercased tag name, for case-insensitive HTML type selectors.
    /// Elements created with `preserveCase` (SVG's `linearGradient`,
    /// `clipPath`, ...) keep their authored spelling in `tagName`.
    public let lowercasedTagName: String?

    /// A snapshot of the attributes. Every mutation invalidates the
    /// selector-matching caches (`id`, `class`, `lang` / `xml:lang` feed them).
    /// Prefer `attributeValue(_:)` for a single lookup (no dictionary retain).
    public internal(set) var attributes: [String: String] {
        get { state.withLock { $0.attributes } }
        set {
            state.withLock {
                $0.attributes = newValue
                $0.attributesReplaced()
            }
            DOMNode.bumpSelectorEpoch()
        }
    }

    /// One attribute's value, looked up under the node's lock.
    @inline(__always)
    public func attributeValue(_ name: String) -> String? {
        state.withLock { $0.attributes[name] }
    }

    /// True when the element has the attribute `name`.
    @inline(__always)
    public func hasAttributeValue(_ name: String) -> Bool {
        state.withLock { $0.attributes[name] != nil }
    }

    /// The element's namespace. `nil` means the HTML namespace — the common
    /// case, kept nil so nothing pays for a string it never reads.
    public internal(set) var namespaceURI: String?

    /// ASCII-lowercased aliases of case-sensitive foreign-content attribute
    /// names (`viewbox` -> the `viewBox` entry). They live in `attributes` so
    /// every existing `attributes["viewbox"]` lookup keeps working, and are
    /// listed here so enumeration (`element.attributes`, `outerHTML`) can skip
    /// them.
    public internal(set) var aliasAttributeKeys: Set<String> {
        get { state.withLock { $0.aliasAttributeKeys } }
        set { state.withLock { $0.aliasAttributeKeys = newValue } }
    }

    /// `attributes` without the lowercase aliases — what the DOM exposes.
    public var enumerableAttributes: [String: String] {
        let (attributes, aliases) = state.withLock { ($0.attributes, $0.aliasAttributeKeys) }
        guard !aliases.isEmpty else { return attributes }
        return attributes.filter { !aliases.contains($0.key) }
    }

    /// Attribute names in the order they were added (DOM §4.9: an element's
    /// attribute list is ordered — source order for parsed elements, append
    /// order for `setAttribute`). `attributes` is a dictionary, so the order
    /// lives in `State.attributeOrder`; it may hold stale names (a host that
    /// replaces `attributes` directly) and never lists aliases.
    ///
    /// The exposed attribute names in attribute-list order: the recorded
    /// order first, then any name the dictionary gained without going through
    /// the setters (sorted, so the result stays deterministic).
    public var orderedAttributeNames: [String] {
        let (attributes, order, aliases) = state.withLock { ($0.attributes, $0.attributeOrder, $0.aliasAttributeKeys) }
        return Self.orderedNames(attributes, order, aliases)
    }

    private static func orderedNames(_ attributes: [String: String], _ order: [String], _ aliases: Set<String>) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        names.reserveCapacity(attributes.count)
        for name in order where attributes[name] != nil && !aliases.contains(name) {
            if seen.insert(name).inserted { names.append(name) }
        }
        if names.count < attributes.count - aliases.count {
            for name in attributes.keys.sorted() where !seen.contains(name) && !aliases.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    /// `(name, value)` pairs in attribute-list order (serialisation, cloning).
    public var orderedAttributes: [(name: String, value: String)] {
        let (attributes, order, aliases) = state.withLock { ($0.attributes, $0.attributeOrder, $0.aliasAttributeKeys) }
        return Self.orderedNames(attributes, order, aliases).compactMap { name in attributes[name].map { (name, $0) } }
    }

    /// Appends an attribute the parser tokenised, keeping source order. The
    /// first occurrence of a duplicate name wins (HTML §13.2.5.33).
    func appendParsedAttribute(name: String, value: String) {
        let added: Bool = state.withLock {
            guard $0.attributes[name] == nil else { return false }
            $0.attributes[name] = value
            $0.attributeOrder.append(name)
            $0.attributeDidChange(name)
            return true
        }
        if added { DOMNode.bumpSelectorEpoch() }
    }

    /// Copies `other`'s attribute list (values and order) — the cloning steps.
    func copyAttributes(from other: DOMNode) {
        let (attributes, order, aliases) = other.state.withLock { ($0.attributes, $0.attributeOrder, $0.aliasAttributeKeys) }
        let names = Self.orderedNames(attributes, order, aliases)
        state.withLock {
            $0.attributes = attributes
            $0.aliasAttributeKeys = aliases
            $0.attributeOrder = names
            $0.attributesReplaced()
        }
        DOMNode.bumpSelectorEpoch()
    }

    /// The document this node belongs to while it is not in a document's tree
    /// (DOM "node document"). Nil means the page document. Only a subtree's
    /// top node carries it: every node of a detached subtree shares its top's
    /// node document, and a node in a document's tree belongs to that
    /// document. Set by the DOM bridge when a node is created for, adopted
    /// into or removed from another document's tree.
    weak var nodeDocument: DOMNode?

    /// HTML §4.12.1.1 "already started" for a `<script>` element. Once true the
    /// element is never prepared (run) again: set by the DOM bridge when it
    /// hands a script to the host (`onScriptExecution`), by the bridge for the
    /// scripts already in the document when it registers, and for every script
    /// the fragment parser creates (innerHTML / outerHTML / insertAdjacentHTML /
    /// DOMParser). Hosts that prepare parser-inserted scripts themselves should
    /// set it too. Copied by `cloneNode` (the script cloning steps).
    public var scriptAlreadyStarted = false

    /// HTML §4.12.1 "non-blocking" (surfaced as `script.async` without an
    /// `async` attribute): initially set; the HTML parser unsets it on the
    /// scripts it creates, and the `async` IDL setter / an `async` attribute
    /// change clear it. Only meaningful on `<script>`.
    public var scriptNonBlocking = true

    /// Document-level quirks mode, decided by the parser from the DOCTYPE.
    /// Only meaningful on a `.document` node.
    public enum QuirksMode: String, Sendable {
        case noQuirks
        case quirks
        case limitedQuirks
    }

    public internal(set) var quirksMode: QuirksMode {
        get { state.withLock { $0.quirksMode } }
        set { state.withLock { $0.quirksMode = newValue } }
    }

    /// `document.compatMode`: "BackCompat" in quirks mode, "CSS1Compat"
    /// otherwise (limited-quirks is a standards mode as far as this reports).
    public var compatMode: String {
        quirksMode == .quirks ? "BackCompat" : "CSS1Compat"
    }

    public static let htmlNamespace = "http://www.w3.org/1999/xhtml"
    public static let svgNamespace = "http://www.w3.org/2000/svg"
    public static let mathmlNamespace = "http://www.w3.org/1998/Math/MathML"

    /// True for HTML-namespace elements (and for anything the parser did not
    /// tag, which is the same thing).
    public var isHTMLNamespace: Bool {
        namespaceURI == nil || namespaceURI == Self.htmlNamespace
    }

    // Text/comment content
    public internal(set) var textContent: String? {
        get { state.withLock { $0.textContent } }
        set { state.withLock { $0.textContent = newValue } }
    }

    /// Appends to a text node's data in place (the parser's character runs).
    func appendTextData(_ text: String) {
        state.withLock {
            if $0.textContent == nil { $0.textContent = text } else { $0.textContent!.append(text) }
        }
    }

    /// True for a `DocumentType` node (`<!DOCTYPE …>`, DOM §4.6).
    ///
    /// A doctype is carried as a `.comment`-typed node with this flag rather
    /// than as its own `NodeType` case: every consumer that walks the tree
    /// (style, layout, rendering, the host's own bridges) already skips
    /// comments, and hosts switch exhaustively over `NodeType`. The JS bridge
    /// reports it as nodeType 10. Name and identifiers live in
    /// `doctypeName` / `doctypePublicId` / `doctypeSystemId`.
    public private(set) var isDocumentType = false
    public var doctypeName: String { isDocumentType ? (attributes["name"] ?? "") : "" }
    public var doctypePublicId: String { isDocumentType ? (attributes["publicId"] ?? "") : "" }
    public var doctypeSystemId: String { isDocumentType ? (attributes["systemId"] ?? "") : "" }

    /// The document's `DocumentType` child, if any (`document.doctype`).
    public var doctype: DOMNode? {
        guard nodeType == .document else { return nil }
        return children.first { $0.isDocumentType }
    }

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

    public static func element(
        tag: String,
        attributes: [String: String] = [:],
        preserveCase: Bool = false,
        namespace: String? = nil
    ) -> DOMNode {
        let resolvedTag = preserveCase ? tag : tag.lowercased()
        let node = DOMNode(nodeType: .element, tagName: resolvedTag, attributes: attributes, textContent: nil)
        node.namespaceURI = namespace
        return node
    }

    public static func text(_ content: String) -> DOMNode {
        DOMNode(nodeType: .text, tagName: nil, attributes: [:], textContent: content)
    }

    public static func comment(_ content: String) -> DOMNode {
        DOMNode(nodeType: .comment, tagName: nil, attributes: [:], textContent: content)
    }

    /// A `DocumentType` node (see `isDocumentType`).
    public static func documentType(name: String, publicId: String = "", systemId: String = "") -> DOMNode {
        let node = DOMNode(nodeType: .comment, tagName: nil,
                           attributes: ["name": name, "publicId": publicId, "systemId": systemId],
                           textContent: nil)
        node.isDocumentType = true
        return node
    }

    deinit {
        // A node's death zeroes its children's weak `parent` without running
        // their observers, so it invalidates the caches too.
        DOMNode.bumpSelectorEpoch()
    }

    private init(nodeType: NodeType, tagName: String?, attributes: [String: String], textContent: String?) {
        self.nodeType = nodeType
        self.tagName = tagName
        self.lowercasedTagName = tagName.map(Self.asciiLowercased)
        var initial = State(attributes: attributes, textContent: textContent)
        // A dictionary has no order; sort so a factory-built element at least
        // serialises deterministically.
        if !attributes.isEmpty { initial.attributeOrder = attributes.keys.sorted() }
        self.state = Mutex(initial)
    }

    /// `lowercased()` that hands back the same string (no copy) when there is
    /// nothing to lower — the common case, as the parser lowercases HTML tags.
    private static func asciiLowercased(_ string: String) -> String {
        for byte in string.utf8 where byte >= 0x41 && byte <= 0x5A { return string.lowercased() }
        for byte in string.utf8 where byte >= 0x80 { return string.lowercased() }
        return string
    }

    // MARK: - ASCII Whitespace Token Splitting (HTML "space characters")

    /// The HTML spec's ASCII whitespace set: space, tab, LF, FF, CR.
    /// Deliberately *not* `Character.isWhitespace`, which also treats NBSP and
    /// other Unicode spaces as separators — those are ordinary class-name
    /// characters as far as HTML is concerned.
    @inline(__always)
    public static func isASCIIWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\u{0C}" || scalar == "\r"
    }

    /// Whitespace test for a `Character`. Note that "\r\n" is a *single*
    /// Swift Character (a CRLF grapheme cluster), so comparing against "\r" or
    /// "\n" alone silently fails — hence the scalar-level check.
    @inline(__always)
    public static func isASCIIWhitespace(_ ch: Character) -> Bool {
        guard let first = ch.unicodeScalars.first else { return false }
        return isASCIIWhitespace(first)
    }

    /// Splits a token-list attribute value on ASCII whitespace, dropping empty
    /// tokens. `"\n\tfoo\n\tbar"` -> `["foo", "bar"]`.
    /// Works on Unicode scalars so CRLF splits as two separators rather than
    /// surviving as part of a token.
    public static func splitASCIIWhitespace(_ value: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if isASCIIWhitespace(scalar) {
                if !current.isEmpty {
                    result.append(String(current))
                    current = String.UnicodeScalarView()
                }
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { result.append(String(current)) }
        return result
    }

    /// Ordered set of tokens (duplicates removed, first occurrence wins) — the
    /// DOM's `DOMTokenList` semantics.
    public static func orderedTokenSet(_ value: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for token in splitASCIIWhitespace(value) where seen.insert(token).inserted {
            result.append(token)
        }
        return result
    }

    /// The parsed token list of any token-list attribute (`class`, `rel`,
    /// `headers`, `sandbox`, `itemprop`, ...).
    public func tokenList(for attribute: String) -> [String] {
        if attribute == "class" { return classNames }
        return Self.orderedTokenSet(attributes[attribute.lowercased()] ?? "")
    }

    /// `rel` as a token list (`relList`).
    public var relList: [String] { tokenList(for: "rel") }

    /// `headers` as a token list.
    public var headersList: [String] { tokenList(for: "headers") }

    /// Attributes the DOM exposes as a `DOMTokenList`.
    public static let tokenListAttributes: Set<String> = [
        "class", "rel", "headers", "sandbox", "itemprop", "ping", "for"
    ]

    // MARK: - Computed Properties

    public var classList: Set<String> {
        let (cached, source, generation) = state.withLock { s -> (Set<String>?, String?, UInt64) in
            if let set = s.classSet { return (set, nil, 0) }
            return (nil, s.attributes["class"], s.classGeneration)
        }
        if let cached { return cached }
        let built: Set<String> = source.map { Set(Self.splitASCIIWhitespace($0)) } ?? []
        state.withLock { if $0.classGeneration == generation { $0.classSet = built } }
        return built
    }

    /// Ordered, de-duplicated class tokens — the order `classList.item(i)` and
    /// `classList[i]` must report.
    public var classNames: [String] {
        let (cached, source, generation) = state.withLock { s -> ([String]?, String?, UInt64) in
            if let names = s.classNames { return (names, nil, 0) }
            return (nil, s.attributes["class"], s.classGeneration)
        }
        if let cached { return cached }
        let built: [String] = source.map { Self.orderedTokenSet($0) } ?? []
        state.withLock { if $0.classGeneration == generation { $0.classNames = built } }
        return built
    }

    /// `classList.contains(name)` without copying the set out (the `.class`
    /// selector test).
    @inline(__always)
    public func hasClass(_ name: String) -> Bool {
        let cached = state.withLock { $0.classSet?.contains(name) }
        if let cached { return cached }
        return classList.contains(name)
    }

    public var idAttribute: String? {
        state.withLock { $0.idValue }
    }

    public var inlineStyle: String? {
        attributeValue("style")
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

    /// The last child without copying the whole children array — `children`
    /// hands back a snapshot, which turns "append this character to the
    /// trailing text node" into an O(n) copy per text token.
    var lastChildNode: DOMNode? {
        state.withLock { $0.children.last }
    }

    /// The first child, again without a snapshot.
    var firstChildNode: DOMNode? {
        state.withLock { $0.children.first }
    }

    /// The child immediately before `node`, again without a snapshot.
    func childBefore(_ node: DOMNode) -> DOMNode? {
        state.withLock {
            guard let index = $0.children.firstIndex(where: { $0 === node }), index > 0 else { return nil }
            return $0.children[index - 1]
        }
    }

    func appendChild(_ child: DOMNode) {
        child.parent = self
        state.withLock { $0.children.append(child) }
    }

    func removeChild(_ child: DOMNode) {
        state.withLock { $0.children.removeAll { $0 === child } }
        child.parent = nil
    }

    /// Inserts `child` before `before` in the children array atomically.
    /// Falls back to appending if `before` is not found.
    func insertChild(_ child: DOMNode, before: DOMNode) {
        child.parent = self
        state.withLock {
            if let index = $0.children.firstIndex(where: { $0 === before }) {
                $0.children.insert(child, at: index)
            } else {
                $0.children.append(child)
            }
        }
    }

    /// Inserts `child` after `after` in the children array atomically.
    /// Falls back to appending if `after` is not found.
    func insertChild(_ child: DOMNode, after: DOMNode) {
        child.parent = self
        state.withLock {
            if let index = $0.children.firstIndex(where: { $0 === after }) {
                $0.children.insert(child, at: index + 1)
            } else {
                $0.children.append(child)
            }
        }
    }

    /// Inserts `child` at a specific index atomically.
    func insertChild(_ child: DOMNode, at index: Int) {
        child.parent = self
        state.withLock {
            let clamped = min(index, $0.children.count)
            $0.children.insert(child, at: clamped)
        }
    }

    /// Atomically removes `old` and inserts `replacements` at its position.
    /// Returns the removed node, or nil if not found.
    @discardableResult
    func replaceChild(_ old: DOMNode, with replacements: [DOMNode]) -> DOMNode? {
        let found = state.withLock { $0.children.contains { $0 === old } }
        guard found else { return nil }
        // Parents first (never under this node's lock: no two node locks are
        // ever held at once), then one swap of the children array.
        for replacement in replacements { replacement.parent = self }
        let replaced: Bool = state.withLock {
            guard let index = $0.children.firstIndex(where: { $0 === old }) else { return false }
            $0.children.replaceSubrange(index...index, with: replacements)
            return true
        }
        guard replaced else { return nil }
        old.parent = nil
        return old
    }

    /// Empties the children array and returns what was there WITHOUT touching
    /// the nodes' parent pointers — for callers that have already re-parented
    /// them (`appendChild` elsewhere) and only need the old array gone.
    /// `clearChildren()` would nil the new parents out from under them.
    @discardableResult
    func detachChildrenArray() -> [DOMNode] {
        state.withLock {
            let old = $0.children
            $0.children = []
            return old
        }
    }

    public func clearChildren() {
        let old = detachChildrenArray()
        for child in old {
            child.parent = nil
        }
    }

    public func setAttribute(name: String, value: String) {
        let lower = name.lowercased()
        state.withLock {
            if $0.attributes.updateValue(value, forKey: lower) == nil { $0.attributeOrder.append(lower) }
            $0.attributeDidChange(lower)
        }
        DOMNode.bumpSelectorEpoch()
    }

    public func removeAttribute(name: String) {
        let lower = name.lowercased()
        state.withLock {
            $0.attributes.removeValue(forKey: lower)
            if let index = $0.attributeOrder.firstIndex(of: lower) { $0.attributeOrder.remove(at: index) }
            $0.attributeDidChange(lower)
        }
        DOMNode.bumpSelectorEpoch()
    }

    public func setAttributePreservingCase(name: String, value: String) {
        let lower = name.lowercased()
        state.withLock {
            if $0.attributes.updateValue(value, forKey: name) == nil { $0.attributeOrder.append(name) }
            if lower != name {
                $0.attributes[lower] = value
                $0.aliasAttributeKeys.insert(lower)
            }
            $0.attributeDidChange(lower)
        }
        DOMNode.bumpSelectorEpoch()
    }

    public func removeAttributePreservingCase(name: String) {
        let lower = name.lowercased()
        state.withLock {
            $0.attributes.removeValue(forKey: name)
            if let index = $0.attributeOrder.firstIndex(of: name) { $0.attributeOrder.remove(at: index) }
            if lower != name || $0.aliasAttributeKeys.contains(lower) {
                $0.attributes.removeValue(forKey: lower)
                $0.aliasAttributeKeys.remove(lower)
            }
            $0.attributesReplaced()
        }
        DOMNode.bumpSelectorEpoch()
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

    /// `Element.matches(selector)` — true when this element itself matches any
    /// selector in the list. Unlike the old parent-scoped implementation this
    /// works on detached nodes (jQuery's `parseHTML`/`filter` rely on it).
    ///
    /// `:scope` inside the selector refers to `scope` when given, otherwise to
    /// the element itself (what `Element.matches` does per Selectors 4).
    public func matchesSelector(_ selector: String, scope: DOMNode? = nil) -> Bool {
        guard nodeType == .element else { return false }
        let list = CSSSelectorParser.parse(selector)
        guard !list.selectors.isEmpty else { return false }
        let context = CSSMatchContext(scope: scope ?? self)
        return list.selectors.contains {
            // Pseudo-element selectors never match an element via the DOM
            // querying APIs (`p::before` matches nothing), though the style
            // resolver still uses them to find originating elements.
            $0.pseudoElement == nil && CSSSelectorMatcher.matches($0, node: self, context: context)
        }
    }

    /// `Element.closest(selector)` — nearest self-or-ancestor element matching.
    /// `:scope` refers to the element `closest` was called on.
    public func closestMatching(_ selector: String) -> DOMNode? {
        let list = CSSSelectorParser.parse(selector)
        guard !list.selectors.isEmpty else { return nil }
        let context = CSSMatchContext(scope: self)
        var cursor: DOMNode? = nodeType == .element ? self : parent
        while let node = cursor {
            if node.nodeType == .element,
               list.selectors.contains(where: {
                   $0.pseudoElement == nil && CSSSelectorMatcher.matches($0, node: node, context: context)
               }) {
                return node
            }
            cursor = node.parent
        }
        return nil
    }

    /// `querySelectorAll` — descendants of this node, in document order.
    /// The node itself is never part of the result (matching WebKit), but it is
    /// the `:scope` for relative selectors such as `:scope > a`.
    public func querySelectorAll(_ selector: String) -> [DOMNode] {
        let selectorList = CSSSelectorParser.parse(selector)
        guard !selectorList.selectors.isEmpty else { return [] }
        let candidates = selectorList.selectors.filter { $0.pseudoElement == nil }
        guard !candidates.isEmpty else { return [] }
        let context = CSSMatchContext(scope: self)

        var results: [DOMNode] = []
        forEachDescendantElement { node in
            if candidates.contains(where: { CSSSelectorMatcher.matches($0, node: node, context: context) }) {
                results.append(node)
            }
        }
        return results
    }

    /// Pre-order (document order) walk over descendant elements.
    func forEachDescendantElement(_ body: (DOMNode) -> Void) {
        for child in children {
            if child.nodeType == .element { body(child) }
            child.forEachDescendantElement(body)
        }
    }

    func allDescendantElements() -> [DOMNode] {
        var result: [DOMNode] = []
        forEachDescendantElement { result.append($0) }
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

// MARK: - Host-Settable Interaction State

/// The document-level state the host (the app / renderer) owns and the selector
/// engine only reads: which element the pointer is over, which has focus, which
/// is being activated, the URL fragment `:target` resolves against, and which
/// custom elements have been defined.
///
/// The app sets these as the user interacts, then re-runs its style pass:
///
///     DOMNode.hoveredNode = elementUnderFinger
///     DOMNode.focusedNode = textField
///     DOMNode.targetFragment = url.fragment
///
/// Everything is nil/empty by default, so `:hover`/`:focus`/`:target` simply
/// never match until the host opts in.
public final class DOMInteractionState: @unchecked Sendable {
    public static let shared = DOMInteractionState()

    private let lock = NSLock()
    private weak var _hovered: DOMNode?
    private weak var _focused: DOMNode?
    private weak var _active: DOMNode?
    private var _focusVisible: Bool = true
    private var _targetFragment: String?
    private var _definedCustomElements: Set<String> = []

    public var hovered: DOMNode? {
        get { lock.lock(); defer { lock.unlock() }; return _hovered }
        set { lock.lock(); _hovered = newValue; lock.unlock() }
    }
    public var focused: DOMNode? {
        get { lock.lock(); defer { lock.unlock() }; return _focused }
        set { lock.lock(); _focused = newValue; lock.unlock() }
    }
    public var active: DOMNode? {
        get { lock.lock(); defer { lock.unlock() }; return _active }
        set { lock.lock(); _active = newValue; lock.unlock() }
    }
    /// Whether the current focus should also match `:focus-visible`
    /// (keyboard-style focus). Defaults to true.
    public var focusVisible: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _focusVisible }
        set { lock.lock(); _focusVisible = newValue; lock.unlock() }
    }
    /// The URL fragment (without `#`) that `:target` matches.
    public var targetFragment: String? {
        get { lock.lock(); defer { lock.unlock() }; return _targetFragment }
        set { lock.lock(); _targetFragment = newValue; lock.unlock() }
    }
    /// Custom element names registered with `customElements.define` — they are
    /// the only hyphenated tag names that match `:defined`.
    public var definedCustomElements: Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return _definedCustomElements }
        set { lock.lock(); _definedCustomElements = newValue; lock.unlock() }
    }

    public func reset() {
        lock.lock()
        _hovered = nil
        _focused = nil
        _active = nil
        _focusVisible = true
        _targetFragment = nil
        _definedCustomElements = []
        lock.unlock()
    }
}

extension DOMNode {
    /// Element the pointer is over. `:hover` matches it and its ancestors.
    public static var hoveredNode: DOMNode? {
        get { DOMInteractionState.shared.hovered }
        set { DOMInteractionState.shared.hovered = newValue }
    }
    /// Focused element. `:focus` matches it; `:focus-within` matches it and its ancestors.
    public static var focusedNode: DOMNode? {
        get { DOMInteractionState.shared.focused }
        set { DOMInteractionState.shared.focused = newValue }
    }
    /// Element being activated (finger/mouse down). `:active` matches it and its ancestors.
    public static var activeNode: DOMNode? {
        get { DOMInteractionState.shared.active }
        set { DOMInteractionState.shared.active = newValue }
    }
    /// Whether the focused element also matches `:focus-visible`.
    public static var focusVisible: Bool {
        get { DOMInteractionState.shared.focusVisible }
        set { DOMInteractionState.shared.focusVisible = newValue }
    }
    /// URL fragment (without `#`) used by `:target`.
    public static var targetFragment: String? {
        get { DOMInteractionState.shared.targetFragment }
        set { DOMInteractionState.shared.targetFragment = newValue }
    }
    /// Names registered via `customElements.define`, used by `:defined`.
    public static var definedCustomElements: Set<String> {
        get { DOMInteractionState.shared.definedCustomElements }
        set { DOMInteractionState.shared.definedCustomElements = newValue }
    }
    /// Clears all host-settable selector state (hover/focus/active/target/defined).
    public static func resetInteractionState() { DOMInteractionState.shared.reset() }
}
