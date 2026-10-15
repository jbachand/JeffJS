import Foundation
import Synchronization

// MARK: - Selector Components

/// A single component of a CSS selector.
nonisolated public enum CSSSelectorComponent: Sendable {
    case element(String)    // div, p, h1
    case className(String)  // .header
    case id(String)         // #main
    case attribute(name: String, op: CSSAttributeOperator?, value: String?, caseSensitivity: CSSAttributeCaseSensitivity)
    case pseudoMatchesAny([CSSComplexSelector]) // :is(...), :matches(...)
    case pseudoWhere([CSSComplexSelector])      // :where(...) — zero specificity
    case pseudoNot([CSSComplexSelector])        // :not(a, b)
    case pseudoHas(CSSHasSelector)              // :has(> .x, + .y)
    case universal          // *
    case pseudoRoot         // :root
    case pseudoScope        // :scope
    // Structural pseudo-classes
    case pseudoFirstChild
    case pseudoLastChild
    case pseudoOnlyChild
    case pseudoNthChild(Int, Int, [CSSComplexSelector]?)      // :nth-child(an+b [of S])
    case pseudoNthLastChild(Int, Int, [CSSComplexSelector]?)  // :nth-last-child(an+b [of S])
    case pseudoFirstOfType
    case pseudoLastOfType
    case pseudoOnlyOfType
    case pseudoNthOfType(Int, Int)
    case pseudoNthLastOfType(Int, Int)
    case pseudoEmpty
    // Link pseudo-classes
    case pseudoLink         // :link — an unvisited link; we never track visits, so every link
    case pseudoAnyLink      // :any-link
    // User-interaction pseudo-classes (host-settable state on DOMNode)
    case pseudoHover
    case pseudoActive
    case pseudoFocus
    case pseudoFocusVisible
    case pseudoFocusWithin
    case pseudoTarget
    case pseudoTargetWithin
    // State pseudo-classes (form elements)
    case pseudoChecked
    case pseudoDisabled
    case pseudoEnabled
    case pseudoRequired
    case pseudoOptional
    case pseudoPlaceholderShown
    case pseudoReadOnly
    case pseudoReadWrite
    case pseudoIndeterminate
    case pseudoDefault
    case pseudoDefined
    // Linguistic pseudo-classes
    case pseudoLang([String])
    case pseudoDir(String)
    // Pseudo-element marker (::before, ::after, ::marker, ...) — extracted during selector construction
    case pseudoElementMarker(CSSPseudoElement)
    /// A pseudo-class we understand but that can never match here (`:visited`).
    case neverMatches
    /// CSS Scoping 1 §3.2.1 `:host` / `:host(<compound>)`: matches only the
    /// shadow host of the tree whose rule is being matched
    /// (`CSSMatchContext.shadowHost`), featureless otherwise.
    case pseudoHost([CSSComplexSelector]?)
    /// CSS Scoping 1 §3.2.1 `:host-context(<compound>)`: the host, when it or a
    /// shadow-including ancestor matches the argument.
    case pseudoHostContext([CSSComplexSelector])
    /// The argument of `::slotted(<compound>)` (CSS Scoping 1 §3.2.2), kept in
    /// the subject compound of a selector whose `pseudoElement` is `.slotted`;
    /// ignored by element matching (the style resolver matches the compound
    /// against the slot and the argument against each slotted element).
    case slottedArgument([CSSComplexSelector])
    /// The part names of `::part(<ident>+)` (CSS Shadow Parts 1 §4.1).
    case partArgument([String])
    /// A pseudo-class/element we do not implement. Never matches, and makes
    /// `CSSSelector.isSupported` report false.
    case unsupported(String)
}

/// CSS pseudo-elements supported for content generation and styling.
nonisolated public enum CSSPseudoElement: String, Sendable {
    case before = "before"
    case after = "after"
    case placeholder = "placeholder"
    case marker = "marker"
    case selection = "selection"
    case firstLine = "first-line"
    case firstLetter = "first-letter"
    case backdrop = "backdrop"
    case fileSelectorButton = "file-selector-button"
    /// `::slotted()` (CSS Scoping 1 §3.2.2) — see `CSSSelectorComponent.slottedArgument`.
    case slotted = "slotted"
    /// `::part()` (CSS Shadow Parts 1) — see `CSSSelectorComponent.partArgument`.
    case part = "part"
}

nonisolated public enum CSSAttributeOperator: Sendable {
    case equals
    case containsWord      // ~=
    case startsWithOrDash  // |=
    case prefixMatch       // ^=
    case suffixMatch       // $=
    case substringMatch    // *=
}

/// `[attr=value i]` / `[attr=value s]`. `.auto` means "whatever HTML says for
/// this attribute" — case-insensitive for the legacy HTML attribute list,
/// case-sensitive otherwise.
nonisolated public enum CSSAttributeCaseSensitivity: Sendable {
    case auto
    case insensitive
    case sensitive
}

/// The argument of `:has()`: a list of *relative* selectors, each of which may
/// start with a combinator (`:has(> .x)`).
///
/// `anchored` holds the same selectors rewritten with an explicit leading
/// `:scope` compound so the ordinary right-to-left matcher can evaluate them.
nonisolated public struct CSSHasSelector: Sendable {
    /// Identity for the per-pass match cache (structs have no identity of their own).
    public let id: Int
    public let selectors: [CSSComplexSelector]
    public let anchored: [CSSComplexSelector]

    nonisolated(unsafe) private static var nextID: Int = 0
    private static let idLock = NSLock()

    public init(selectors: [CSSComplexSelector]) {
        Self.idLock.lock()
        Self.nextID += 1
        self.id = Self.nextID
        Self.idLock.unlock()
        self.selectors = selectors
        self.anchored = selectors.map { relative in
            let scopePart = CSSComplexSelector.Part(
                combinator: nil,
                selector: CSSCompoundSelector(components: [.pseudoScope])
            )
            var parts: [CSSComplexSelector.Part] = [scopePart]
            for (offset, part) in relative.parts.enumerated() {
                if offset == 0 {
                    parts.append(CSSComplexSelector.Part(
                        combinator: part.combinator ?? .descendant,
                        selector: part.selector
                    ))
                } else {
                    parts.append(part)
                }
            }
            return CSSComplexSelector(parts: parts)
        }
    }
}

/// A compound selector — all components must match the same element.
nonisolated public struct CSSCompoundSelector: Sendable {
    public let components: [CSSSelectorComponent]
    /// Hashes of the identifiers an element must carry to match this compound
    /// (tag name, id, classes, the primary subtag of a `:lang()` range, and
    /// what every alternative of an `:is()` / `:where()` requires). When the
    /// compound sits left of a descendant or child combinator they are looked
    /// up in the subject's ancestor filter (`DOMAncestorFilter`) before any
    /// ancestor is walked.
    public let ancestorKeyHashes: [UInt32]

    public init(components: [CSSSelectorComponent]) {
        self.components = components
        self.ancestorKeyHashes = Self.requiredKeyHashes(components)
    }

    private static func requiredKeyHashes(_ components: [CSSSelectorComponent]) -> [UInt32] {
        var keys: [UInt32] = []
        for component in components {
            switch component {
            case .element(let tag):
                keys.append(DOMSelectorKeyHash.hash(DOMSelectorKeyHash.tagKind, tag))
            case .id(let id):
                keys.append(DOMSelectorKeyHash.hash(DOMSelectorKeyHash.idKind, id))
            case .className(let cls):
                keys.append(DOMSelectorKeyHash.hash(DOMSelectorKeyHash.classKind, cls))
            case .pseudoLang(let ranges):
                // Extended filtering compares the primary subtag exactly unless
                // it is `*`; a single primary subtag shared by every range is a
                // key the matching element's language must have.
                guard let first = ranges.first else { break }
                let primary = DOMSelectorKeyHash.primarySubtag(first)
                if primary != "*", ranges.allSatisfy({ DOMSelectorKeyHash.primarySubtag($0) == primary }) {
                    keys.append(DOMSelectorKeyHash.hash(DOMSelectorKeyHash.langKind, primary))
                }
            case .pseudoMatchesAny(let alternatives), .pseudoWhere(let alternatives):
                // Keys every alternative's subject compound requires.
                var common: Set<UInt32>?
                for alternative in alternatives {
                    let subjectKeys = Set(alternative.parts.last?.selector.ancestorKeyHashes ?? [])
                    common = common.map { $0.intersection(subjectKeys) } ?? subjectKeys
                    if common?.isEmpty == true { break }
                }
                if let common { keys.append(contentsOf: common.sorted()) }
            default:
                break
            }
        }
        return keys
    }
}

/// Combinator between compound selectors.
nonisolated public enum CSSCombinator: Sendable {
    case descendant       // whitespace
    case child            // >
    case adjacentSibling  // +
    case generalSibling   // ~
}

/// A complex selector is a chain of compound selectors with combinators.
nonisolated public struct CSSComplexSelector: Sendable {
    public struct Part: Sendable {
        /// The combinator *preceding* this compound (nil on the first part of
        /// an absolute selector; set on the first part of a relative one).
        public let combinator: CSSCombinator?
        public let selector: CSSCompoundSelector
        public init(combinator: CSSCombinator?, selector: CSSCompoundSelector) {
            self.combinator = combinator
            self.selector = selector
        }
    }
    public let parts: [Part]
    /// If non-nil, this selector targets a pseudo-element (::before / ::after / ...).
    public let pseudoElement: CSSPseudoElement?

    /// `pureDescendantPrefix[i]` is true when every combinator left of
    /// `parts[i - 1]` (those preceding `parts[1..<i]`) is a descendant
    /// combinator. A descendant combinator before `parts[i]` then needs only
    /// the *nearest* ancestor matching `parts[i - 1]`: a farther one has a
    /// subset of its ancestors, and nothing left of it constrains the
    /// ancestor's position, so if the nearest fails every farther one fails.
    /// Otherwise the matcher backtracks with a failure memo
    /// (`CSSSelectorMatcher.ChainMemo`) so the work stays polynomial.
    let pureDescendantPrefix: [Bool]

    public init(parts: [Part], pseudoElement: CSSPseudoElement? = nil) {
        self.parts = parts
        self.pseudoElement = pseudoElement
        var pure = [Bool](repeating: true, count: parts.count + 1)
        var allDescendant = true
        for i in 0..<parts.count {
            pure[i] = allDescendant
            if i >= 1, (parts[i].combinator ?? .descendant) != .descendant { allDescendant = false }
        }
        pure[parts.count] = allDescendant
        self.pureDescendantPrefix = pure
    }
}

/// A selector list: "h1, h2, h3" — any selector matching means the rule applies.
nonisolated public struct CSSSelectorList: Sendable {
    public let selectors: [CSSComplexSelector]
    /// False when some group in the list failed to parse (an invalid selector).
    public let isValid: Bool

    public init(selectors: [CSSComplexSelector], isValid: Bool = true) {
        self.selectors = selectors
        self.isValid = isValid
    }
}

// MARK: - Specificity

nonisolated public struct CSSSpecificity: Comparable, Sendable {
    public let inline: Int
    public let ids: Int
    public let classes: Int
    public let elements: Int

    public init(inline: Int, ids: Int, classes: Int, elements: Int) {
        self.inline = inline
        self.ids = ids
        self.classes = classes
        self.elements = elements
    }

    public static let zero = CSSSpecificity(inline: 0, ids: 0, classes: 0, elements: 0)

    public static func < (lhs: CSSSpecificity, rhs: CSSSpecificity) -> Bool {
        if lhs.inline != rhs.inline { return lhs.inline < rhs.inline }
        if lhs.ids != rhs.ids { return lhs.ids < rhs.ids }
        if lhs.classes != rhs.classes { return lhs.classes < rhs.classes }
        return lhs.elements < rhs.elements
    }

    public static func calculate(for selector: CSSComplexSelector) -> CSSSpecificity {
        var ids = 0, classes = 0, elements = 0
        for part in selector.parts {
            for component in part.selector.components {
                add(component, &ids, &classes, &elements)
            }
        }
        // The pseudo-element is lifted out of the components during parsing, but
        // it still contributes (0, 0, 1) to specificity.
        if selector.pseudoElement != nil { elements += 1 }
        return CSSSpecificity(inline: 0, ids: ids, classes: classes, elements: elements)
    }

    /// Specificity of the most specific selector in a list — what `:is()`,
    /// `:not()`, `:has()` and `:nth-child(... of S)` contribute.
    public static func mostSpecific(_ selectors: [CSSComplexSelector]) -> CSSSpecificity {
        selectors.map { calculate(for: $0) }.max() ?? .zero
    }

    private static func add(_ component: CSSSelectorComponent, _ ids: inout Int, _ classes: inout Int, _ elements: inout Int) {
        switch component {
        case .id:
            ids += 1
        case .className, .attribute,
             .pseudoRoot, .pseudoScope,
             .pseudoFirstChild, .pseudoLastChild, .pseudoOnlyChild,
             .pseudoFirstOfType, .pseudoLastOfType, .pseudoOnlyOfType,
             .pseudoNthOfType, .pseudoNthLastOfType,
             .pseudoEmpty,
             .pseudoLink, .pseudoAnyLink,
             .pseudoHover, .pseudoActive, .pseudoFocus, .pseudoFocusVisible,
             .pseudoFocusWithin, .pseudoTarget, .pseudoTargetWithin,
             .pseudoChecked, .pseudoDisabled, .pseudoEnabled,
             .pseudoRequired, .pseudoOptional, .pseudoPlaceholderShown,
             .pseudoReadOnly, .pseudoReadWrite,
             .pseudoIndeterminate, .pseudoDefault, .pseudoDefined,
             .pseudoLang, .pseudoDir:
            classes += 1
        case .pseudoNot(let selectors), .pseudoMatchesAny(let selectors):
            // :is()/:not() take the specificity of their most specific argument.
            let spec = mostSpecific(selectors)
            ids += spec.ids
            classes += spec.classes
            elements += spec.elements
        case .pseudoHas(let has):
            let spec = mostSpecific(has.selectors)
            ids += spec.ids
            classes += spec.classes
            elements += spec.elements
        case .pseudoNthChild(_, _, let of), .pseudoNthLastChild(_, _, let of):
            // (0,1,0) for the pseudo-class itself, plus the `of S` argument.
            classes += 1
            if let of {
                let spec = mostSpecific(of)
                ids += spec.ids
                classes += spec.classes
                elements += spec.elements
            }
        case .pseudoWhere:
            // :where() always contributes zero specificity.
            break
        case .pseudoHost(let arg):
            // CSS Scoping 1 §3.2.1: a pseudo-class, plus its argument.
            classes += 1
            if let arg {
                let spec = mostSpecific(arg)
                ids += spec.ids; classes += spec.classes; elements += spec.elements
            }
        case .pseudoHostContext(let arg):
            classes += 1
            let spec = mostSpecific(arg)
            ids += spec.ids; classes += spec.classes; elements += spec.elements
        case .slottedArgument(let arg):
            // CSS Scoping 1 §3.2.2: a pseudo-element (the (0,0,1) is added by
            // `calculate` for `pseudoElement`), plus its argument.
            let spec = mostSpecific(arg)
            ids += spec.ids; classes += spec.classes; elements += spec.elements
        case .partArgument:
            break   // the pseudo-element's (0,0,1) comes from `calculate`
        case .element, .pseudoElementMarker:
            elements += 1
        case .universal:
            break
        case .neverMatches, .unsupported:
            // Unknown pseudo-classes still count as (0,0,1,0).
            classes += 1
        }
    }
}

// MARK: - Match Context

/// Per-query state the matcher needs beyond the node itself.
///
/// Interaction state (`:hover`, `:focus`, `:target`, ...) is read from
/// `DOMInteractionState.shared` / the `DOMNode` static accessors, so the common
/// matching path costs nothing extra.
nonisolated public struct CSSMatchContext: Sendable {
    /// The `:scope` element. `querySelectorAll` sets it to the node it was
    /// called on; `:has()` re-points it at the anchor element.
    public var scope: DOMNode?
    /// The shadow host of the tree whose rules are being matched (CSS Scoping
    /// 1 §3): `:host` matches only it, and a combinator stepping out of that
    /// tree's shadow root reaches it (featureless: only `:host`-family
    /// compounds match it). nil = a document-tree rule.
    public var shadowHost: DOMNode?
    /// The ancestors of the node a query is currently testing, when a
    /// subtree scan carries them (`DOMAncestorChain`); nil everywhere else.
    /// Honoured only for `ancestorChain.subject` itself.
    var ancestorChain: DOMAncestorChain?

    public init(scope: DOMNode? = nil, shadowHost: DOMNode? = nil) {
        self.scope = scope
        self.shadowHost = shadowHost
    }

    /// No scoping element — `:scope` then behaves like `:root`.
    public static let none = CSSMatchContext(scope: nil)
}

/// The ancestors of the element a subtree scan (`querySelectorAll`) is
/// testing, root-most first, kept as strong references on the scan's own
/// stack: combinators step to the parent by index, with no `parent` getter
/// (a lock and a weak load per step). Optionally also a counting Bloom filter
/// of the ancestors' tag, id, class and attribute-name hashes, maintained on
/// push / pop, which long selector lists use to reject entries cheaply.
/// One scan's private state: never shared between threads.
nonisolated final class DOMAncestorChain: @unchecked Sendable {
    var nodes: [DOMNode] = []
    /// The element being tested; the chain describes its ancestors.
    var subject: DOMNode?
    let tracksFilter: Bool
    private var counters: [UInt16]
    private var hashes: [UInt32] = []
    private var levelStart: [Int] = []

    init(tracksFilter: Bool) {
        self.tracksFilter = tracksFilter
        counters = tracksFilter ? [UInt16](repeating: 0, count: 512) : []
    }

    func push(_ node: DOMNode) {
        nodes.append(node)
        guard tracksFilter else { return }
        levelStart.append(hashes.count)
        if node.nodeType == .element {
            if let tag = node.lowercasedTagName { hashes.append(DOMSelectorKeyHash.hash(DOMSelectorKeyHash.tagKind, tag)) }
            if let id = node.idAttribute { hashes.append(DOMSelectorKeyHash.hash(DOMSelectorKeyHash.idKind, id)) }
            for cls in node.classNames { hashes.append(DOMSelectorKeyHash.hash(DOMSelectorKeyHash.classKind, cls)) }
            for key in node.attributes.keys { hashes.append(DOMSelectorKeyHash.attributeNameHash(key)) }
        }
        for h in hashes[levelStart[levelStart.count - 1]...] {
            counters[Int(h & 511)] &+= 1
            counters[Int((h >> 9) & 511)] &+= 1
        }
    }

    func pop() {
        nodes.removeLast()
        guard tracksFilter else { return }
        let start = levelStart.removeLast()
        for h in hashes[start...] {
            counters[Int(h & 511)] &-= 1
            counters[Int((h >> 9) & 511)] &-= 1
        }
        hashes.removeSubrange(start...)
    }

    @inline(__always)
    func mayContain(_ hash: UInt32) -> Bool {
        counters[Int(hash & 511)] > 0 && counters[Int((hash >> 9) & 511)] > 0
    }
}

// MARK: - Selector Matching

nonisolated public struct CSSSelectorMatcher: Sendable {

    /// Test whether a complex selector matches a DOM node.
    public static func matches(_ selector: CSSComplexSelector, node: DOMNode) -> Bool {
        matches(selector, node: node, context: .none)
    }

    /// Test whether a complex selector matches a DOM node within a scope.
    public static func matches(_ selector: CSSComplexSelector, node: DOMNode, context: CSSMatchContext) -> Bool {
        let chain = context.ancestorChain.flatMap { $0.subject === node ? $0 : nil }
        return matches(selector, node: node, context: context, chain: chain)
    }

    static func matches(_ selector: CSSComplexSelector, node: DOMNode, context: CSSMatchContext,
                        chain: DOMAncestorChain?) -> Bool {
        let parts = selector.parts
        let last = parts.count - 1
        guard last >= 0 else { return false }
        guard matchesCompound(parts[last].selector, node: node, context: context) else { return false }
        if last == 0 { return true }
        // Fast reject: a compound left of a descendant / child combinator must
        // match an ancestor, so its identifiers must be in the ancestor filter.
        if chain == nil, ancestorFilterRejects(parts, node: node) { return false }
        var memo: ChainMemo?
        return matchesCombinator(selector, last, node: node, context: context, chain: chain,
                                 upTo: chain?.nodes.count ?? 0, memo: &memo)
    }

    /// True when some compound that has to match an ancestor of `node` needs
    /// an identifier no ancestor carries. A compound left of a sibling
    /// combinator matches a sibling, not an ancestor, and is skipped; the
    /// compounds further left of it are ancestors again.
    @inline(__always)
    private static func ancestorFilterRejects(_ parts: [CSSComplexSelector.Part], node: DOMNode) -> Bool {
        var filter: DOMAncestorFilter?
        var index = parts.count - 1
        while index > 0 {
            let combinator = parts[index].combinator ?? .descendant
            index -= 1
            guard combinator == .descendant || combinator == .child else { continue }
            let keys = parts[index].selector.ancestorKeyHashes
            if keys.isEmpty { continue }
            if filter == nil { filter = node.ancestorFilterForMatching() }
            for key in keys where !filter.unsafelyUnwrapped.mayContain(key) { return true }
        }
        return false
    }

    /// Failure memo for one `matches` call: (part index, node) pairs for which
    /// "`parts[index]` matches the node and the rest of the chain holds" was
    /// found false. Keeps backtracking over descendant / general-sibling
    /// combinators O(parts x nodes) instead of exponential in the depth. The
    /// same idea as WebKit's SelectorChecker descendant backtracking (and
    /// SelectorCompiler, which only backtracks while an earlier combinator can
    /// still pick a different ancestor).
    final class ChainMemo {
        struct Key: Hashable { let index: Int; let node: ObjectIdentifier }
        var failed = Set<Key>()
    }

    /// `parts[index]` against `node`, then the rest of the chain.
    private static func matchesChain(
        _ selector: CSSComplexSelector, _ index: Int, node: DOMNode,
        context: CSSMatchContext, chain: DOMAncestorChain?, upTo: Int, memo: inout ChainMemo?
    ) -> Bool {
        guard matchesCompound(selector.parts[index].selector, node: node, context: context) else { return false }
        if index == 0 { return true }
        return matchesCombinator(selector, index, node: node, context: context, chain: chain, upTo: upTo, memo: &memo)
    }

    /// The element a combinator steps to from `node` and how many chain
    /// entries lie above it. With a chain (`upTo` ancestors known above
    /// `node`) the parent is `chain.nodes[upTo - 1]`.
    @inline(__always)
    private static func parentStep(_ node: DOMNode, _ context: CSSMatchContext,
                                   _ chain: DOMAncestorChain?, _ upTo: Int) -> (DOMNode?, Int) {
        if let chain { return upTo > 0 ? (chain.nodes[upTo - 1], upTo - 1) : (nil, 0) }
        return (selectorParent(of: node, context: context), 0)
    }

    /// Memoised `matchesChain`, for the backtracking loops.
    private static func matchesChainMemoised(
        _ selector: CSSComplexSelector, _ index: Int, node: DOMNode,
        context: CSSMatchContext, chain: DOMAncestorChain?, upTo: Int, memo: inout ChainMemo?
    ) -> Bool {
        if memo == nil { memo = ChainMemo() }
        let key = ChainMemo.Key(index: index, node: ObjectIdentifier(node))
        if memo.unsafelyUnwrapped.failed.contains(key) { return false }
        if matchesChain(selector, index, node: node, context: context, chain: chain, upTo: upTo, memo: &memo) { return true }
        memo.unsafelyUnwrapped.failed.insert(key)
        return false
    }

    /// The rest of `matchesChain` once `parts[index]` matched `node`: find the
    /// element the combinator before it points at.
    private static func matchesCombinator(
        _ selector: CSSComplexSelector, _ index: Int, node: DOMNode,
        context: CSSMatchContext, chain: DOMAncestorChain?, upTo: Int, memo: inout ChainMemo?
    ) -> Bool {
        let parts = selector.parts
        switch parts[index].combinator ?? .descendant {
        case .child:
            let (parent, parentUp) = parentStep(node, context, chain, upTo)
            guard let parent else { return false }
            return matchesChain(selector, index - 1, node: parent, context: context, chain: chain, upTo: parentUp, memo: &memo)
        case .descendant:
            var (cursor, cursorUp) = parentStep(node, context, chain, upTo)
            if selector.pureDescendantPrefix[index] {
                // Greedy: the nearest ancestor matching the compound decides.
                let target = parts[index - 1].selector
                while let ancestor = cursor {
                    if matchesCompound(target, node: ancestor, context: context) {
                        if index - 1 == 0 { return true }
                        return matchesCombinator(selector, index - 1, node: ancestor, context: context,
                                                 chain: chain, upTo: cursorUp, memo: &memo)
                    }
                    (cursor, cursorUp) = parentStep(ancestor, context, chain, cursorUp)
                }
                return false
            }
            while let ancestor = cursor {
                if matchesChainMemoised(selector, index - 1, node: ancestor, context: context,
                                        chain: chain, upTo: cursorUp, memo: &memo) { return true }
                (cursor, cursorUp) = parentStep(ancestor, context, chain, cursorUp)
            }
            return false
        case .adjacentSibling:
            guard let sibling = previousElementSibling(of: node) else { return false }
            return matchesChain(selector, index - 1, node: sibling, context: context, chain: chain, upTo: upTo, memo: &memo)
        case .generalSibling:
            var cursor = previousElementSibling(of: node)
            while let sibling = cursor {
                if matchesChainMemoised(selector, index - 1, node: sibling, context: context,
                                        chain: chain, upTo: upTo, memo: &memo) { return true }
                cursor = previousElementSibling(of: sibling)
            }
            return false
        }
    }

    /// The parent a combinator steps to: the DOM-tree parent, which ends at a
    /// shadow root (whose stored parent is its host — `DOMNode+Shadow.swift`).
    /// Selectors never match across a shadow boundary (CSS Scoping 1 §3.1).
    @inline(__always)
    static func selectorParent(of node: DOMNode) -> DOMNode? {
        guard let p = node.parent else { return nil }
        if DOMNode.anyShadowRoots, p.isShadowRoot { return nil }
        return p
    }

    /// `selectorParent(of:)` for a rule of a shadow tree: stepping out of the
    /// rule's own shadow root reaches its host (CSS Scoping 1 §3.2.1: "the
    /// host … is treated as the parent of the shadow root's top-level
    /// elements" for `:host > x` / `:host x`); the host's own parent is never
    /// reached (the host is featureless and ends the chain).
    @inline(__always)
    static func selectorParent(of node: DOMNode, context: CSSMatchContext) -> DOMNode? {
        guard let host = context.shadowHost else { return selectorParent(of: node) }
        if node === host { return nil }
        guard let p = node.parent else { return nil }
        if DOMNode.anyShadowRoots, p.isShadowRoot { return p.shadowHost === host ? host : nil }
        return p
    }

    /// CSS Scoping 1 §3.1: in the context of its own shadow tree's rules the
    /// host is featureless — only `:host`, `:host()`, `:host-context()` (alone
    /// or with `*`) can match it.
    private static func matchesFeaturelessHost(_ selector: CSSCompoundSelector, host: DOMNode,
                                               context: CSSMatchContext) -> Bool {
        var sawHost = false
        for component in selector.components {
            switch component {
            case .universal:
                continue
            case .pseudoHost(let arg):
                sawHost = true
                if let arg {
                    // The argument matches the host as an element of *its* tree.
                    let outer = CSSMatchContext(scope: nil, shadowHost: nil)
                    guard arg.contains(where: { matches($0, node: host, context: outer) }) else { return false }
                }
            case .pseudoHostContext(let arg):
                sawHost = true
                var cur: DOMNode? = host
                var found = false
                let outer = CSSMatchContext(scope: nil, shadowHost: nil)
                while let c = cur, !found {
                    if c.nodeType == .element, arg.contains(where: { matches($0, node: c, context: outer) }) { found = true }
                    cur = c.parent   // shadow-including ancestors
                }
                guard found else { return false }
            case .pseudoMatchesAny(let list), .pseudoWhere(let list):
                guard list.contains(where: { matches($0, node: host, context: context) }) else { return false }
                sawHost = true
            case .pseudoNot(let list):
                if list.contains(where: { matches($0, node: host, context: context) }) { return false }
            default:
                return false
            }
        }
        return sawHost
    }

    /// Test whether a compound selector matches a single node.
    public static func matchesCompound(_ selector: CSSCompoundSelector, node: DOMNode) -> Bool {
        matchesCompound(selector, node: node, context: .none)
    }

    public static func matchesCompound(_ selector: CSSCompoundSelector, node: DOMNode, context: CSSMatchContext) -> Bool {
        // Only elements match — except the scoping root, which may be a
        // document or fragment when `:scope > x` is evaluated.
        guard node.nodeType == .element || node === context.scope else { return false }
        if let host = context.shadowHost, node === host {
            return matchesFeaturelessHost(selector, host: host, context: context)
        }

        for component in selector.components {
            switch component {
            case .element(let tag):
                guard node.lowercasedTagName == tag else { return false }
            case .className(let cls):
                guard node.hasClass(cls) else { return false }
            case .id(let id):
                guard node.idAttribute == id else { return false }
            case .attribute(let name, let op, let value, let caseSensitivity):
                guard matchesAttribute(node: node, name: name, op: op, value: value, caseSensitivity: caseSensitivity) else { return false }
            case .pseudoMatchesAny(let selectors), .pseudoWhere(let selectors):
                guard selectors.contains(where: { matches($0, node: node, context: context) }) else { return false }
            case .pseudoNot(let selectors):
                if selectors.contains(where: { matches($0, node: node, context: context) }) { return false }
            case .pseudoHas(let has):
                guard matchesHas(has, anchor: node, context: context) else { return false }
            case .universal:
                continue
            case .pseudoRoot:
                guard isRoot(node) else { return false }
            case .pseudoScope:
                if let scope = context.scope {
                    guard node === scope else { return false }
                } else {
                    guard isRoot(node) else { return false }
                }
            case .pseudoFirstChild:
                guard elementIndex(of: node) == 0 else { return false }
            case .pseudoLastChild:
                guard isLastElement(node) else { return false }
            case .pseudoOnlyChild:
                guard elementIndex(of: node) == 0 && isLastElement(node) else { return false }
            case .pseudoNthChild(let a, let b, let of):
                guard matchesNthChild(a: a, b: b, of: of, node: node, fromEnd: false, context: context) else { return false }
            case .pseudoNthLastChild(let a, let b, let of):
                guard matchesNthChild(a: a, b: b, of: of, node: node, fromEnd: true, context: context) else { return false }
            case .pseudoFirstOfType:
                guard elementOfTypeIndex(of: node) == 0 else { return false }
            case .pseudoLastOfType:
                guard isLastElementOfType(node) else { return false }
            case .pseudoOnlyOfType:
                guard elementOfTypeIndex(of: node) == 0 && isLastElementOfType(node) else { return false }
            case .pseudoNthOfType(let a, let b):
                guard matchesNth(a: a, b: b, index: elementOfTypeIndex(of: node)) else { return false }
            case .pseudoNthLastOfType(let a, let b):
                guard matchesNth(a: a, b: b, index: elementOfTypeIndexFromEnd(of: node)) else { return false }
            case .pseudoEmpty:
                guard isEmpty(node) else { return false }
            case .pseudoLink, .pseudoAnyLink:
                // We never record visited state, so every link is an unvisited
                // link — and `:visited` (below) never matches.
                guard isLink(node) else { return false }
            case .pseudoHover:
                guard isSelfOrAncestor(node, of: DOMInteractionState.shared.hovered) else { return false }
            case .pseudoActive:
                guard isSelfOrAncestor(node, of: DOMInteractionState.shared.active) else { return false }
            case .pseudoFocus:
                guard let focused = DOMInteractionState.shared.focused, focused === node else { return false }
            case .pseudoFocusVisible:
                guard DOMInteractionState.shared.focusVisible,
                      let focused = DOMInteractionState.shared.focused, focused === node else { return false }
            case .pseudoFocusWithin:
                guard isSelfOrAncestor(node, of: DOMInteractionState.shared.focused) else { return false }
            case .pseudoTarget:
                guard isTarget(node) else { return false }
            case .pseudoTargetWithin:
                guard isSelfOrAncestorOfTarget(node) else { return false }
            case .pseudoChecked:
                guard matchesChecked(node) else { return false }
            case .pseudoDisabled:
                guard matchesDisabled(node) else { return false }
            case .pseudoEnabled:
                guard matchesEnabled(node) else { return false }
            case .pseudoRequired:
                guard isRequirable(node), node.attributeValue("required") != nil else { return false }
            case .pseudoOptional:
                guard isRequirable(node), node.attributeValue("required") == nil else { return false }
            case .pseudoPlaceholderShown:
                guard matchesPlaceholderShown(node) else { return false }
            case .pseudoReadOnly:
                guard !matchesReadWrite(node) else { return false }
            case .pseudoReadWrite:
                guard matchesReadWrite(node) else { return false }
            case .pseudoIndeterminate:
                guard matchesIndeterminate(node) else { return false }
            case .pseudoDefault:
                guard matchesDefault(node) else { return false }
            case .pseudoDefined:
                guard matchesDefined(node) else { return false }
            case .pseudoLang(let ranges):
                guard matchesLang(node, ranges: ranges) else { return false }
            case .pseudoDir(let direction):
                guard resolvedDirection(node) == direction else { return false }
            case .pseudoElementMarker, .slottedArgument, .partArgument:
                // Pseudo-element markers are extracted during parsing; if one
                // remains in components it should not affect element matching.
                break
            case .pseudoHost, .pseudoHostContext:
                // Only the context's host (handled above) matches `:host`.
                return false
            case .neverMatches, .unsupported:
                return false
            }
        }
        return true
    }

    // MARK: - :has()

    /// Per-style-pass cache for `:has()`. Off by default: turn it on around a
    /// style pass with `beginMatchPass()` / `endMatchPass()` when the tree is
    /// known not to change in between. The memo belongs to the thread that
    /// began the pass: matching on any other thread (script's
    /// `querySelectorAll` while a style pass runs elsewhere) neither reads nor
    /// fills it, since it may see a newer tree than the pass.
    private struct HasCacheKey: Hashable {
        let node: ObjectIdentifier
        let selector: Int
    }
    nonisolated(unsafe) private static var hasCache: [HasCacheKey: Bool] = [:]
    /// The selector epoch the memo's entries were computed at: a DOM mutation
    /// during the pass (script running while the pass reads) empties it.
    nonisolated(unsafe) private static var hasCacheEpoch: UInt64 = 0
    /// The pass thread (`currentThreadToken`), 0 when no pass is running.
    private static let hasCacheOwner = Atomic<UInt>(0)
    private static let hasCacheLock = NSLock()

    @inline(__always)
    private static var currentThreadToken: UInt { UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(pthread_self()))) }

    /// Start a style pass on the calling thread: `:has()` results are memoised
    /// per element until `endMatchPass()`. The DOM must not mutate in between.
    public static func beginMatchPass() {
        hasCacheLock.lock()
        hasCache.removeAll(keepingCapacity: true)
        hasCacheLock.unlock()
        hasCacheOwner.store(currentThreadToken, ordering: .releasing)
    }

    /// End a style pass and drop the `:has()` cache.
    public static func endMatchPass() {
        hasCacheOwner.store(0, ordering: .releasing)
        hasCacheLock.lock()
        hasCache.removeAll()
        hasCacheLock.unlock()
    }

    private static func matchesHas(_ has: CSSHasSelector, anchor: DOMNode, context: CSSMatchContext) -> Bool {
        let key = HasCacheKey(node: ObjectIdentifier(anchor), selector: has.id)
        let useCache = hasCacheOwner.load(ordering: .acquiring) == currentThreadToken
        let epoch = DOMNode.selectorEpoch
        if useCache {
            hasCacheLock.lock()
            if hasCacheEpoch != epoch {
                hasCache.removeAll(keepingCapacity: true)
                hasCacheEpoch = epoch
            }
            let cached = hasCache[key]
            hasCacheLock.unlock()
            if let cached { return cached }
        }

        var innerContext = context
        innerContext.scope = anchor
        innerContext.ancestorChain = nil
        var result = false

        for anchored in has.anchored {
            // parts[0] is the synthesised `:scope`; parts[1] carries the leading
            // combinator, which decides where candidates can live.
            guard anchored.parts.count >= 2 else { continue }
            let lead = anchored.parts[1].combinator ?? .descendant
            switch lead {
            case .descendant, .child:
                if anySubtreeElement(of: anchor, includeSelf: false, where: {
                    matches(anchored, node: $0, context: innerContext)
                }) { result = true }
            case .adjacentSibling, .generalSibling:
                var sibling = nextElementSibling(of: anchor)
                while let candidate = sibling, !result {
                    if anySubtreeElement(of: candidate, includeSelf: true, where: {
                        matches(anchored, node: $0, context: innerContext)
                    }) { result = true }
                    sibling = nextElementSibling(of: candidate)
                }
            }
            if result { break }
        }

        if useCache {
            hasCacheLock.lock()
            if hasCacheEpoch == epoch { hasCache[key] = result }
            hasCacheLock.unlock()
        }
        return result
    }

    /// Depth-first scan with early exit — no intermediate arrays.
    private static func anySubtreeElement(of node: DOMNode, includeSelf: Bool, where predicate: (DOMNode) -> Bool) -> Bool {
        if includeSelf, node.nodeType == .element, predicate(node) { return true }
        for child in node.children {
            if child.nodeType == .element {
                if predicate(child) { return true }
                if anySubtreeElement(of: child, includeSelf: false, where: predicate) { return true }
            } else if anySubtreeElement(of: child, includeSelf: false, where: predicate) {
                return true
            }
        }
        return false
    }

    // MARK: - Structural Pseudo-class Helpers

    /// `:root` — the document element, i.e. the document's first element child.
    /// A detached element is not a `:root`, matching WebKit.
    private static func isRoot(_ node: DOMNode) -> Bool {
        guard node.nodeType == .element,
              let parent = node.parent,
              parent.nodeType == .document else { return false }
        return parent.children.first(where: { $0.nodeType == .element }) === node
    }

    private static func isEmpty(_ node: DOMNode) -> Bool {
        node.children.allSatisfy {
            $0.nodeType == .comment || ($0.nodeType == .text && ($0.textContent ?? "").isEmpty)
        }
    }

    /// Returns the 0-based index of this element among its element siblings.
    private static func elementIndex(of node: DOMNode) -> Int {
        node.siblingPosition()?.elementIndex ?? 0
    }

    /// Returns the 0-based index of this element counting from the end among element siblings.
    private static func elementIndexFromEnd(of node: DOMNode) -> Int {
        guard let position = node.siblingPosition() else { return 0 }
        return position.elementCount - 1 - position.elementIndex
    }

    /// Returns the 0-based index of this element among siblings of the same tag name.
    private static func elementOfTypeIndex(of node: DOMNode) -> Int {
        guard let parent = node.parent, let tag = node.tagName else { return 0 }
        var index = 0
        for child in parent.children {
            if child === node { return index }
            if child.nodeType == .element && child.tagName == tag { index += 1 }
        }
        return 0
    }

    /// Returns the 0-based index from end of this element among siblings of the same tag name.
    private static func elementOfTypeIndexFromEnd(of node: DOMNode) -> Int {
        guard let parent = node.parent, let tag = node.tagName else { return 0 }
        var index = 0
        for child in parent.children.reversed() {
            if child === node { return index }
            if child.nodeType == .element && child.tagName == tag { index += 1 }
        }
        return 0
    }

    /// Whether the node is the last element child of its parent.
    private static func isLastElement(_ node: DOMNode) -> Bool {
        guard let position = node.siblingPosition() else { return true }
        return position.elementIndex == position.elementCount - 1
    }

    /// Whether the node is the last element child of its type in its parent.
    private static func isLastElementOfType(_ node: DOMNode) -> Bool {
        guard let parent = node.parent, let tag = node.tagName else { return true }
        for child in parent.children.reversed() {
            if child.nodeType == .element && child.tagName == tag { return child === node }
        }
        return false
    }

    /// `:nth-child(An+B [of S])` / `:nth-last-child(An+B [of S])`.
    private static func matchesNthChild(
        a: Int,
        b: Int,
        of: [CSSComplexSelector]?,
        node: DOMNode,
        fromEnd: Bool,
        context: CSSMatchContext
    ) -> Bool {
        guard let of else {
            let index = fromEnd ? elementIndexFromEnd(of: node) : elementIndex(of: node)
            return matchesNth(a: a, b: b, index: index)
        }
        // The element itself has to match the `of S` list first.
        guard of.contains(where: { matches($0, node: node, context: context) }) else { return false }
        guard let parent = node.parent else {
            return matchesNth(a: a, b: b, index: 0)
        }
        let siblings = fromEnd ? parent.children.reversed().map { $0 } : parent.children
        var index = 0
        for child in siblings {
            if child === node { return matchesNth(a: a, b: b, index: index) }
            if child.nodeType == .element,
               of.contains(where: { matches($0, node: child, context: context) }) {
                index += 1
            }
        }
        return false
    }

    /// Check if the 0-based `index` matches the `an+b` formula.
    /// CSS uses 1-based counting so we convert: position = index + 1.
    private static func matchesNth(a: Int, b: Int, index: Int) -> Bool {
        let position = index + 1 // CSS :nth-child is 1-based
        if a == 0 {
            return position == b
        }
        let diff = position - b
        // diff must be a non-negative multiple of a
        if a > 0 {
            return diff >= 0 && diff % a == 0
        } else {
            return diff <= 0 && diff % a == 0
        }
    }

    // MARK: - Link / Interaction Helpers

    private static let linkTags: Set<String> = ["a", "area", "link"]

    private static func isLink(_ node: DOMNode) -> Bool {
        guard let tag = node.lowercasedTagName, linkTags.contains(tag) else { return false }
        return node.attributeValue("href") != nil
    }

    /// `:hover`, `:active` and `:focus-within` match the state-holding element
    /// *and every ancestor of it*.
    private static func isSelfOrAncestor(_ node: DOMNode, of stateNode: DOMNode?) -> Bool {
        var cursor = stateNode
        while let current = cursor {
            if current === node { return true }
            cursor = current.parent
        }
        return false
    }

    private static func isTarget(_ node: DOMNode) -> Bool {
        guard let fragment = DOMInteractionState.shared.targetFragment, !fragment.isEmpty else { return false }
        if node.idAttribute == fragment { return true }
        // Legacy: <a name="..."> is also a fragment target.
        if node.lowercasedTagName == "a", node.attributeValue("name") == fragment { return true }
        return false
    }

    /// `:target-within` — the element is, or contains, the fragment target.
    private static func isSelfOrAncestorOfTarget(_ node: DOMNode) -> Bool {
        guard DOMInteractionState.shared.targetFragment != nil else { return false }
        if isTarget(node) { return true }
        return anySubtreeElement(of: node, includeSelf: false) { isTarget($0) }
    }

    // MARK: - Form State Pseudo-class Helpers

    private static let formDisableableTags: Set<String> = [
        "input", "button", "select", "textarea", "fieldset", "optgroup", "option"
    ]
    private static let requirableTags: Set<String> = ["input", "select", "textarea"]
    /// Input types that hold user-editable text.
    private static let textualInputTypes: Set<String> = [
        "text", "search", "url", "tel", "email", "password", "number",
        "date", "month", "week", "time", "datetime-local"
    ]

    private static func inputType(_ node: DOMNode) -> String {
        (node.attributeValue("type") ?? "text").lowercased()
    }

    private static func matchesChecked(_ node: DOMNode) -> Bool {
        guard let tag = node.lowercasedTagName else { return false }
        if tag == "input" {
            let type = inputType(node)
            guard type == "checkbox" || type == "radio" else { return false }
            return node.attributeValue("checked") != nil
        }
        if tag == "option" {
            return node.attributeValue("selected") != nil
        }
        return false
    }

    /// Disabled-ness is inherited from an ancestor `<fieldset disabled>`
    /// (except through its first `<legend>`), which is what WebKit does.
    private static func matchesDisabled(_ node: DOMNode) -> Bool {
        guard let tag = node.lowercasedTagName, formDisableableTags.contains(tag) else { return false }
        if node.attributeValue("disabled") != nil { return true }
        if tag == "fieldset" { return false }
        var child = node
        var cursor = node.parent
        while let ancestor = cursor {
            if ancestor.lowercasedTagName == "fieldset", ancestor.attributeValue("disabled") != nil {
                // Controls inside the fieldset's first <legend> stay enabled.
                if let legend = ancestor.children.first(where: { $0.lowercasedTagName == "legend" }),
                   isSelfOrAncestor(legend, of: child) {
                    return false
                }
                return true
            }
            child = ancestor
            cursor = ancestor.parent
        }
        return false
    }

    private static func matchesEnabled(_ node: DOMNode) -> Bool {
        guard let tag = node.lowercasedTagName, formDisableableTags.contains(tag) else { return false }
        return !matchesDisabled(node)
    }

    private static func isRequirable(_ node: DOMNode) -> Bool {
        guard let tag = node.lowercasedTagName, requirableTags.contains(tag) else { return false }
        if tag == "input" {
            let type = inputType(node)
            return type != "hidden" && type != "range" && type != "color" &&
                   type != "submit" && type != "reset" && type != "button" && type != "image"
        }
        return true
    }

    private static func matchesPlaceholderShown(_ node: DOMNode) -> Bool {
        guard let tag = node.lowercasedTagName else { return false }
        guard node.attributeValue("placeholder") != nil else { return false }
        if tag == "textarea" {
            return node.textDescendants.isEmpty && (node.attributeValue("value") ?? "").isEmpty
        }
        guard tag == "input" else { return false }
        guard textualInputTypes.contains(inputType(node)) else { return false }
        return (node.attributeValue("value") ?? "").isEmpty
    }

    /// `:read-write` — the element is user-editable. Everything else (including
    /// ordinary `<p>`s and disabled inputs) is `:read-only`.
    private static func matchesReadWrite(_ node: DOMNode) -> Bool {
        guard let tag = node.lowercasedTagName else { return false }
        if tag == "input" || tag == "textarea" {
            if tag == "input", !textualInputTypes.contains(inputType(node)) { return false }
            return node.attributeValue("readonly") == nil && !matchesDisabled(node)
        }
        // contenteditable (inherited)
        var cursor: DOMNode? = node
        while let current = cursor {
            if let value = current.attributeValue("contenteditable")?.lowercased() {
                if value == "false" { return false }
                if value == "" || value == "true" || value == "plaintext-only" { return true }
            }
            cursor = current.parent
        }
        return false
    }

    private static func matchesIndeterminate(_ node: DOMNode) -> Bool {
        guard let tag = node.lowercasedTagName else { return false }
        if tag == "progress" { return node.attributeValue("value") == nil }
        guard tag == "input" else { return false }
        let type = inputType(node)
        if type == "checkbox" {
            return node.attributeValue("indeterminate") != nil
        }
        if type == "radio" {
            // A radio group with nothing checked is indeterminate.
            guard node.attributeValue("checked") == nil else { return false }
            let name = node.attributeValue("name") ?? ""
            guard !name.isEmpty else { return true }
            var root: DOMNode = node
            while let parent = root.parent { root = parent }
            var anyChecked = false
            _ = anySubtreeElement(of: root, includeSelf: true) { candidate in
                if candidate.lowercasedTagName == "input",
                   inputType(candidate) == "radio",
                   candidate.attributeValue("name") == name,
                   candidate.attributeValue("checked") != nil {
                    anyChecked = true
                    return true
                }
                return false
            }
            return !anyChecked
        }
        return false
    }

    /// `:default` — a checked checkbox/radio, a selected option, or the form's
    /// default (first submit) button.
    private static func matchesDefault(_ node: DOMNode) -> Bool {
        guard let tag = node.lowercasedTagName else { return false }
        if tag == "option" { return node.attributeValue("selected") != nil }
        if tag == "input" {
            let type = inputType(node)
            if type == "checkbox" || type == "radio" { return node.attributeValue("checked") != nil }
            if type == "submit" || type == "image" { return isDefaultSubmitButton(node) }
            return false
        }
        if tag == "button" {
            let type = (node.attributeValue("type") ?? "submit").lowercased()
            guard type == "submit" else { return false }
            return isDefaultSubmitButton(node)
        }
        return false
    }

    private static func isDefaultSubmitButton(_ node: DOMNode) -> Bool {
        var cursor = node.parent
        var form: DOMNode?
        while let current = cursor {
            if current.lowercasedTagName == "form" { form = current; break }
            cursor = current.parent
        }
        guard let form else { return false }
        var first: DOMNode?
        _ = anySubtreeElement(of: form, includeSelf: false) { candidate in
            guard let tag = candidate.lowercasedTagName else { return false }
            if tag == "button" {
                let type = (candidate.attributeValue("type") ?? "submit").lowercased()
                if type == "submit" { first = candidate; return true }
            } else if tag == "input" {
                let type = inputType(candidate)
                if type == "submit" || type == "image" { first = candidate; return true }
            }
            return false
        }
        return first === node
    }

    /// `:defined` — everything but an un-upgraded custom element.
    private static func matchesDefined(_ node: DOMNode) -> Bool {
        guard let tag = node.lowercasedTagName else { return false }
        guard tag.contains("-") else { return true }
        return DOMInteractionState.shared.definedCustomElements.contains(tag)
    }

    // MARK: - Linguistic Pseudo-class Helpers

    /// `:lang()` against the element's cached language (`DOMNode.language`,
    /// resolved once per selector epoch). Ranges are lowercased by the parser.
    /// An element without a language, or with an explicitly unknown one
    /// (`lang=""`), matches no range.
    private static func matchesLang(_ node: DOMNode, ranges: [String]) -> Bool {
        let id = node.selectorLanguageID(DOMNode.selectorEpoch)
        let language: String
        switch id {
        case DOMLanguageTable.none, DOMLanguageTable.unknown:
            return false
        case DOMLanguageTable.uncached:
            guard let resolved = node.uncachedLanguage(), !resolved.isEmpty else { return false }
            language = resolved
        default:
            language = DOMLanguageTable.shared.tag(id)
        }
        for range in ranges where languageRange(range, matches: language) { return true }
        return false
    }

    /// RFC 4647 §3.3.2 extended filtering (Selectors 4 §7.2), both sides
    /// lowercased: `en` matches `en` and `en-US`, `de-DE` matches `de-Latn-DE`,
    /// `*-CH` matches `de-CH` and `fr-CH`, `*` matches any language.
    static func languageRange(_ range: String, matches language: String) -> Bool {
        if range == "*" { return true }
        var range = range, language = language
        return range.withUTF8 { r in language.withUTF8 { l in extendedFilter(r, l) } }
    }

    /// Extended filtering over UTF-8 bytes, without allocating: subtags are
    /// `-`-separated runs, compared bytewise (both sides are lowercased).
    private static func extendedFilter(_ r: UnsafeBufferPointer<UInt8>, _ l: UnsafeBufferPointer<UInt8>) -> Bool {
        let dash = UInt8(ascii: "-"), star = UInt8(ascii: "*")
        @inline(__always) func end(_ b: UnsafeBufferPointer<UInt8>, _ start: Int) -> Int {
            var i = start
            while i < b.count && b[i] != dash { i += 1 }
            return i
        }
        @inline(__always) func same(_ rs: Int, _ re: Int, _ ls: Int, _ le: Int) -> Bool {
            guard re - rs == le - ls else { return false }
            var i = 0
            while i < re - rs { if r[rs + i] != l[ls + i] { return false }; i += 1 }
            return true
        }
        // First subtags: equal, or the range's is `*`.
        let rEnd0 = end(r, 0), lEnd0 = end(l, 0)
        let rangeStar0 = rEnd0 == 1 && r[0] == star
        if !rangeStar0 && !same(0, rEnd0, 0, lEnd0) { return false }
        var rs = rEnd0 + 1, ls = lEnd0 + 1     // start of the next subtag (> count: none)
        while rs <= r.count {
            let re = end(r, rs)
            if re - rs == 1 && r[rs] == star { rs = re + 1; continue }
            // The range subtag must occur later in the tag, stopping at a singleton.
            while true {
                guard ls <= l.count else { return false }
                let le = end(l, ls)
                if same(rs, re, ls, le) { ls = le + 1; break }
                if le - ls == 1 { return false }
                ls = le + 1
            }
            rs = re + 1
        }
        return true
    }

    /// `:dir()` — nearest `dir` attribute, defaulting to ltr. `dir=auto` is
    /// resolved as ltr (we have no bidi text analysis).
    private static func resolvedDirection(_ node: DOMNode) -> String {
        var cursor: DOMNode? = node
        while let current = cursor {
            if let value = current.attributeValue("dir")?.lowercased() {
                if value == "ltr" || value == "rtl" { return value }
                if value == "auto" { return "ltr" }
            }
            cursor = current.parent
        }
        return "ltr"
    }

    // MARK: - Sibling Helpers

    static func previousElementSibling(of node: DOMNode) -> DOMNode? {
        node.elementSibling(forward: false)
    }

    static func nextElementSibling(of node: DOMNode) -> DOMNode? {
        node.elementSibling(forward: true)
    }

    // MARK: - Attribute Matching

    /// Attributes HTML matches case-insensitively in HTML documents
    /// (the "case-insensitive attribute" list from the HTML spec).
    private static let caseInsensitiveAttributes: Set<String> = [
        "accept", "accept-charset", "align", "alink", "axis", "bgcolor", "charset",
        "checked", "clear", "codetype", "color", "compact", "declare", "defer",
        "dir", "direction", "disabled", "enctype", "face", "frame", "hreflang",
        "http-equiv", "lang", "language", "link", "media", "method", "multiple",
        "nohref", "noresize", "noshade", "nowrap", "readonly", "rel", "rev",
        "rules", "scope", "scrolling", "selected", "shape", "target", "text",
        "type", "valign", "valuetype", "vlink"
    ]

    private static func matchesAttribute(
        node: DOMNode,
        name: String,
        op: CSSAttributeOperator?,
        value: String?,
        caseSensitivity: CSSAttributeCaseSensitivity
    ) -> Bool {
        let attrName = name.lowercased()
        guard let rawAttrValue = node.attributeValue(attrName) else {
            return false
        }
        guard let op else { return true }

        let insensitive: Bool
        switch caseSensitivity {
        case .insensitive: insensitive = true
        case .sensitive: insensitive = false
        case .auto: insensitive = caseInsensitiveAttributes.contains(attrName)
        }

        let attrValue = insensitive ? rawAttrValue.lowercased() : rawAttrValue
        let value = insensitive ? (value ?? "").lowercased() : (value ?? "")

        // `[attr^=""]`, `[attr$=""]`, `[attr*=""]` and `[attr~=""]` never match.
        if value.isEmpty {
            switch op {
            case .equals: return attrValue.isEmpty
            case .startsWithOrDash: return attrValue.isEmpty
            case .containsWord, .prefixMatch, .suffixMatch, .substringMatch: return false
            }
        }

        switch op {
        case .equals:
            return attrValue == value
        case .containsWord:
            // Token lists split on ASCII whitespace, per HTML.
            return DOMNode.splitASCIIWhitespace(attrValue).contains(value)
        case .startsWithOrDash:
            return attrValue == value || attrValue.hasPrefix(value + "-")
        case .prefixMatch:
            return attrValue.hasPrefix(value)
        case .suffixMatch:
            return attrValue.hasSuffix(value)
        case .substringMatch:
            return attrValue.contains(value)
        }
    }
}

// MARK: - Selector Parsing

nonisolated public struct CSSSelectorParser: Sendable {

    /// Cache of parsed selector lists keyed by their source strings.
    /// Avoids re-parsing the same selector strings that appear across stylesheets
    /// or are used by querySelector/querySelectorAll calls.
    nonisolated(unsafe) private static var selectorCache: [String: CSSSelectorList] = [:]
    private static let cacheLock = NSLock()

    /// Clear the selector cache. Call on page teardown to free memory.
    public static func clearCache() {
        CSSQueryPlan.clearCache()
        cacheLock.lock()
        selectorCache.removeAll()
        cacheLock.unlock()
    }

    /// Parse a selector string like "div.container > p, h1" into a CSSSelectorList.
    public static func parse(_ selectorString: String) -> CSSSelectorList {
        cacheLock.lock()
        let cached = selectorCache[selectorString]
        cacheLock.unlock()
        if let cached { return cached }

        let groups = splitTopLevel(selectorString, separator: ",")
        var selectors: [CSSComplexSelector] = []
        var isValid = !groups.isEmpty
        for group in groups {
            var valid = true
            let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = parseComplexSelector(trimmed, &valid), valid {
                selectors.append(parsed)
            } else {
                isValid = false
            }
        }
        if selectors.isEmpty { isValid = false }
        let result = CSSSelectorList(selectors: selectors, isValid: isValid)
        cacheLock.lock()
        selectorCache[selectorString] = result
        cacheLock.unlock()
        return result
    }

    /// Parse a *relative* selector list (the argument of `:has()`), where each
    /// selector may begin with a combinator.
    public static func parseRelative(_ selectorString: String) -> CSSSelectorList {
        parse(selectorString)
    }

    private static func parseComplexSelector(_ input: String, _ valid: inout Bool) -> CSSComplexSelector? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            valid = false
            return nil
        }

        var parts: [CSSComplexSelector.Part] = []
        let chars = Array(trimmed)
        var currentCombinator: CSSCombinator? = nil
        var index = 0
        var hasPreviousPart = false

        while index < chars.count {
            let hadWhitespace = skipWhitespace(chars, &index)
            if hadWhitespace && hasPreviousPart && currentCombinator == nil {
                currentCombinator = .descendant
            }
            guard index < chars.count else { break }

            if let comb = parseCombinator(chars, &index) {
                // Two combinators in a row ("div > > p") is a syntax error;
                // a leading combinator is legal in a relative selector.
                if currentCombinator != nil && currentCombinator != .descendant && hasPreviousPart {
                    valid = false
                }
                currentCombinator = comb
                _ = skipWhitespace(chars, &index)
                continue
            }

            guard let compound = parseCompoundSelector(chars, &index, &valid) else {
                valid = false
                break
            }

            parts.append(CSSComplexSelector.Part(
                combinator: currentCombinator,
                selector: compound
            ))
            currentCombinator = nil
            hasPreviousPart = true
        }

        // A dangling combinator ("div >") is invalid.
        if currentCombinator != nil, currentCombinator != .descendant { valid = false }
        guard !parts.isEmpty else {
            valid = false
            return nil
        }

        // Extract pseudo-element marker from the last compound selector's components.
        var pseudoElement: CSSPseudoElement? = nil
        if let lastPart = parts.last {
            let filtered = lastPart.selector.components.compactMap { component -> CSSSelectorComponent? in
                if case .pseudoElementMarker(let pseudo) = component {
                    pseudoElement = pseudo
                    return nil
                }
                // `::slotted()` / `::part()` keep their argument in the compound.
                if case .slottedArgument = component { pseudoElement = .slotted }
                if case .partArgument = component { pseudoElement = .part }
                return component
            }
            if pseudoElement != nil {
                parts[parts.count - 1] = CSSComplexSelector.Part(
                    combinator: lastPart.combinator,
                    selector: CSSCompoundSelector(components: filtered)
                )
            }
        }

        return CSSComplexSelector(parts: parts, pseudoElement: pseudoElement)
    }

    private static func parseCombinator(_ chars: [Character], _ index: inout Int) -> CSSCombinator? {
        guard index < chars.count else { return nil }
        switch chars[index] {
        case ">":
            index += 1
            return .child
        case "+":
            index += 1
            return .adjacentSibling
        case "~":
            index += 1
            return .generalSibling
        default:
            return nil
        }
    }

    private static func parseCompoundSelector(_ chars: [Character], _ index: inout Int, _ valid: inout Bool) -> CSSCompoundSelector? {
        var components: [CSSSelectorComponent] = []
        let start = index

        // Type selector, with optional namespace prefix (`*|div`, `|div`, `ns|div`).
        if index < chars.count {
            if let typeComponent = parseTypeSelector(chars, &index) {
                components.append(typeComponent)
            }
        }

        while index < chars.count {
            let ch = chars[index]
            if ch == " " || ch == "\t" || ch == "\n" || ch == "\u{0C}" || ch == "\r" ||
               ch == ">" || ch == "+" || ch == "~" || ch == "," || ch == ")" {
                break
            }

            if ch == "." {
                index += 1
                if let cls = consumeIdentifier(chars, &index) {
                    components.append(.className(cls))
                } else {
                    valid = false
                    break
                }
                continue
            }

            if ch == "#" {
                index += 1
                if let id = consumeIdentifier(chars, &index) {
                    components.append(.id(id))
                } else {
                    valid = false
                    break
                }
                continue
            }

            if ch == "[" {
                if let attr = parseAttributeSelector(chars, &index, &valid) {
                    components.append(attr)
                } else {
                    valid = false
                    break
                }
                continue
            }

            if ch == ":" {
                if let pseudo = parsePseudoSelector(chars, &index, &valid) {
                    components.append(pseudo)
                } else {
                    valid = false
                    break
                }
                continue
            }

            // Unknown token in this position: a syntax error. Consume one char
            // so the caller cannot loop forever.
            valid = false
            index += 1
            break
        }

        if components.isEmpty && index == start {
            return nil
        }
        return CSSCompoundSelector(components: components)
    }

    /// `div`, `*`, `*|div`, `|div`, `svg|rect` (namespaced names we cannot
    /// resolve become `.unsupported`).
    private static func parseTypeSelector(_ chars: [Character], _ index: inout Int) -> CSSSelectorComponent? {
        func isNamespaceBar(_ at: Int) -> Bool {
            guard at < chars.count, chars[at] == "|" else { return false }
            // `|=` inside an attribute selector never reaches here, but a bare
            // `|` followed by `=` is not a namespace separator.
            return !(at + 1 < chars.count && chars[at + 1] == "=")
        }

        guard index < chars.count else { return nil }

        // `|div` — explicitly no namespace.
        if isNamespaceBar(index) {
            index += 1
            if index < chars.count, chars[index] == "*" {
                index += 1
                return .universal
            }
            if let name = consumeIdentifier(chars, &index) {
                return .element(name.lowercased())
            }
            return .universal
        }

        if chars[index] == "*" {
            index += 1
            if isNamespaceBar(index) {
                index += 1
                if index < chars.count, chars[index] == "*" {
                    index += 1
                    return .universal
                }
                if let name = consumeIdentifier(chars, &index) {
                    return .element(name.lowercased())
                }
                return .universal
            }
            return .universal
        }

        let save = index
        guard let name = consumeIdentifier(chars, &index) else {
            index = save
            return nil
        }
        if isNamespaceBar(index) {
            index += 1
            if index < chars.count, chars[index] == "*" {
                index += 1
                return .unsupported("namespace|*")
            }
            guard let local = consumeIdentifier(chars, &index) else {
                return .unsupported("namespace")
            }
            // We have no namespace declarations, so a real prefix can never match.
            return .unsupported("\(name)|\(local)")
        }
        return .element(name.lowercased())
    }

    private static func parseAttributeSelector(_ chars: [Character], _ index: inout Int, _ valid: inout Bool) -> CSSSelectorComponent? {
        guard index < chars.count, chars[index] == "[" else { return nil }
        index += 1
        _ = skipWhitespace(chars, &index)

        // Optional namespace prefix on the attribute name.
        if index < chars.count, chars[index] == "|",
           !(index + 1 < chars.count && chars[index + 1] == "=") {
            index += 1
        } else if index < chars.count, chars[index] == "*",
                  index + 1 < chars.count, chars[index + 1] == "|" {
            index += 2
        }

        guard let name = consumeIdentifier(chars, &index)?.lowercased() else {
            consumeUntil(chars, &index, stopAt: "]")
            if index < chars.count, chars[index] == "]" { index += 1 }
            valid = false
            return nil
        }

        _ = skipWhitespace(chars, &index)
        var op: CSSAttributeOperator?
        var value: String?
        var caseSensitivity: CSSAttributeCaseSensitivity = .auto

        if index < chars.count, chars[index] != "]" {
            guard let parsedOp = parseAttributeOperator(chars, &index) else {
                consumeUntil(chars, &index, stopAt: "]")
                if index < chars.count, chars[index] == "]" { index += 1 }
                valid = false
                return nil
            }
            op = parsedOp
            _ = skipWhitespace(chars, &index)
            value = parseAttributeValue(chars, &index)
            if value == nil { valid = false }
            _ = skipWhitespace(chars, &index)

            // Case-sensitivity flag: [attr="x" i] / [attr="x" s]
            if let flag = consumeIdentifier(chars, &index)?.lowercased() {
                switch flag {
                case "i": caseSensitivity = .insensitive
                case "s": caseSensitivity = .sensitive
                default: valid = false
                }
            }
            _ = skipWhitespace(chars, &index)
        }

        if index < chars.count, chars[index] == "]" {
            index += 1
        } else {
            consumeUntil(chars, &index, stopAt: "]")
            if index < chars.count, chars[index] == "]" { index += 1 }
            valid = false
        }

        return .attribute(name: name, op: op, value: value, caseSensitivity: caseSensitivity)
    }

    /// Pseudo-elements that may also be written with the legacy single colon.
    private static let legacyPseudoElements: [String: CSSPseudoElement] = [
        "before": .before,
        "after": .after,
        "first-line": .firstLine,
        "first-letter": .firstLetter
    ]

    private static func parsePseudoSelector(_ chars: [Character], _ index: inout Int, _ valid: inout Bool) -> CSSSelectorComponent? {
        guard index < chars.count, chars[index] == ":" else { return nil }
        index += 1

        // Pseudo-elements (::before / ::after / ::marker / ...)
        if index < chars.count, chars[index] == ":" {
            index += 1
            let pseudoName = consumeIdentifier(chars, &index)?.lowercased()
            // Consume optional arguments like ::slotted(...) / ::part(...)
            var pseudoArgument: String?
            if index < chars.count, chars[index] == "(" {
                pseudoArgument = consumeParenthesizedContent(chars, &index)
            }
            guard let pseudoName else {
                valid = false
                return nil
            }
            // CSS Scoping 1 §3.2.2 / Shadow Parts 1 §4.1.
            if pseudoName == "slotted", let arg = pseudoArgument {
                let list = parse(arg.trimmingCharacters(in: .whitespaces))
                guard list.isValid, !list.selectors.isEmpty,
                      list.selectors.allSatisfy({ $0.parts.count == 1 && $0.pseudoElement == nil }) else {
                    valid = false
                    return .unsupported("::slotted()")
                }
                return .slottedArgument(list.selectors)
            }
            if pseudoName == "part", let arg = pseudoArgument {
                let names = splitTopLevel(arg, separator: " ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard !names.isEmpty else { valid = false; return .unsupported("::part()") }
                return .partArgument(names)
            }
            if let pseudo = CSSPseudoElement(rawValue: pseudoName) {
                return .pseudoElementMarker(pseudo)
            }
            return .unsupported("::\(pseudoName)")
        }

        guard let pseudoName = consumeIdentifier(chars, &index)?.lowercased() else {
            valid = false
            return nil
        }

        // Legacy single-colon pseudo-elements.
        if index >= chars.count || chars[index] != "(", let legacy = legacyPseudoElements[pseudoName] {
            return .pseudoElementMarker(legacy)
        }

        // Simple pseudo-classes without arguments
        switch pseudoName {
        case "root":
            return .pseudoRoot
        case "scope":
            return .pseudoScope
        case "first-child":
            return .pseudoFirstChild
        case "last-child":
            return .pseudoLastChild
        case "only-child":
            return .pseudoOnlyChild
        case "first-of-type":
            return .pseudoFirstOfType
        case "last-of-type":
            return .pseudoLastOfType
        case "only-of-type":
            return .pseudoOnlyOfType
        case "empty":
            return .pseudoEmpty
        // Links
        case "link":
            return .pseudoLink
        case "any-link":
            return .pseudoAnyLink
        case "visited", "local-link":
            // Privacy: :visited must never match. Supported, never true.
            return .neverMatches
        // User interaction — driven by host-settable state on DOMNode.
        case "hover":
            return .pseudoHover
        case "active":
            return .pseudoActive
        case "focus":
            return .pseudoFocus
        case "focus-visible":
            return .pseudoFocusVisible
        case "focus-within":
            return .pseudoFocusWithin
        case "target":
            return .pseudoTarget
        case "target-within":
            return .pseudoTargetWithin
        // Form state
        case "checked":
            return .pseudoChecked
        case "disabled":
            return .pseudoDisabled
        case "enabled":
            return .pseudoEnabled
        case "required":
            return .pseudoRequired
        case "optional":
            return .pseudoOptional
        case "placeholder-shown":
            return .pseudoPlaceholderShown
        case "read-only":
            return .pseudoReadOnly
        case "read-write":
            return .pseudoReadWrite
        case "indeterminate":
            return .pseudoIndeterminate
        case "default":
            return .pseudoDefault
        case "defined":
            return .pseudoDefined
        case "host" where index >= chars.count || chars[index] != "(":
            return .pseudoHost(nil)
        default:
            break
        }

        // Pseudo-classes that require arguments
        guard index < chars.count, chars[index] == "(" else {
            // Unknown pseudo-class without args — must not silently drop.
            return .unsupported(":\(pseudoName)")
        }

        guard let argument = consumeParenthesizedContent(chars, &index) else {
            valid = false
            return .unsupported(":\(pseudoName)()")
        }
        let trimmedArg = argument.trimmingCharacters(in: .whitespaces)

        switch pseudoName {
        case "not":
            let list = parse(trimmedArg)
            guard !list.selectors.isEmpty else {
                valid = false
                return .unsupported(":not()")
            }
            if !list.isValid { valid = false }
            return .pseudoNot(list.selectors)
        case "is", "matches", "-webkit-any", "-moz-any":
            let list = parse(trimmedArg)
            guard !list.selectors.isEmpty else {
                // :is() is forgiving — an unparseable argument list just never matches.
                return .neverMatches
            }
            return .pseudoMatchesAny(list.selectors)
        case "where":
            let list = parse(trimmedArg)
            guard !list.selectors.isEmpty else { return .neverMatches }
            return .pseudoWhere(list.selectors)
        case "has":
            let list = parse(trimmedArg)
            guard !list.selectors.isEmpty else {
                valid = false
                return .unsupported(":has()")
            }
            if !list.isValid { valid = false }
            return .pseudoHas(CSSHasSelector(selectors: list.selectors))
        case "nth-child", "nth-last-child":
            let (nth, ofList) = parseNthWithOf(trimmedArg, &valid)
            if pseudoName == "nth-child" {
                return .pseudoNthChild(nth.0, nth.1, ofList)
            }
            return .pseudoNthLastChild(nth.0, nth.1, ofList)
        case "nth-of-type":
            let (a, b) = parseNthExpression(trimmedArg)
            return .pseudoNthOfType(a, b)
        case "nth-last-of-type":
            let (a, b) = parseNthExpression(trimmedArg)
            return .pseudoNthLastOfType(a, b)
        case "lang":
            // Language ranges compare case-insensitively: stored lowercased.
            let ranges = splitTopLevel(trimmedArg, separator: ",")
                .map { unquote($0.trimmingCharacters(in: .whitespaces)).lowercased() }
                .filter { !$0.isEmpty }
            guard !ranges.isEmpty else {
                valid = false
                return .unsupported(":lang()")
            }
            return .pseudoLang(ranges)
        case "host", "host-context":
            // CSS Scoping 1 §3.2.1: `<compound-selector>` arguments.
            let list = parse(trimmedArg)
            guard list.isValid, !list.selectors.isEmpty,
                  list.selectors.allSatisfy({ $0.parts.count == 1 && $0.pseudoElement == nil }) else {
                valid = false
                return .unsupported(":\(pseudoName)()")
            }
            return pseudoName == "host" ? .pseudoHost(list.selectors) : .pseudoHostContext(list.selectors)
        case "dir":
            let direction = unquote(trimmedArg).lowercased()
            guard direction == "ltr" || direction == "rtl" else {
                // Unknown directions are valid syntax but never match.
                return .neverMatches
            }
            return .pseudoDir(direction)
        default:
            return .unsupported(":\(pseudoName)()")
        }
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
              (first == "\"" || first == "'"), first == last else { return value }
        return String(value.dropFirst().dropLast())
    }

    /// Splits `2n+1 of .highlight` into the An+B part and the optional `of S`
    /// selector list.
    private static func parseNthWithOf(_ argument: String, _ valid: inout Bool) -> ((Int, Int), [CSSComplexSelector]?) {
        let chars = Array(argument)
        var depth = 0
        var index = 0
        var splitAt: Int? = nil
        while index < chars.count {
            let ch = chars[index]
            if ch == "(" || ch == "[" { depth += 1 }
            if ch == ")" || ch == "]" { depth = max(0, depth - 1) }
            if depth == 0, index + 2 < chars.count,
               (chars[index] == "o" || chars[index] == "O"),
               (chars[index + 1] == "f" || chars[index + 1] == "F"),
               DOMNode.isASCIIWhitespace(chars[index + 2]),
               index > 0, DOMNode.isASCIIWhitespace(chars[index - 1]) {
                splitAt = index
                break
            }
            index += 1
        }

        guard let splitAt else {
            return (parseNthExpression(argument), nil)
        }
        let nthPart = String(chars[0..<splitAt])
        let selectorPart = String(chars[(splitAt + 2)...]).trimmingCharacters(in: .whitespaces)
        let list = parse(selectorPart)
        if !list.isValid || list.selectors.isEmpty { valid = false }
        return (parseNthExpression(nthPart), list.selectors.isEmpty ? nil : list.selectors)
    }

    /// Parse an `an+b` expression like "2n+1", "odd", "even", "3", "-n+2".
    private static func parseNthExpression(_ expr: String) -> (Int, Int) {
        let s = expr.trimmingCharacters(in: .whitespaces).lowercased()

        if s == "odd" { return (2, 1) }
        if s == "even" { return (2, 0) }

        // Try to parse "an+b" or "an-b" or "an" or "n+b" or "b" or "-n+b"
        let nIdx = s.firstIndex(of: "n")

        if let nIdx = nIdx {
            let aPart = String(s[s.startIndex..<nIdx]).trimmingCharacters(in: .whitespaces)
            let a: Int
            if aPart.isEmpty || aPart == "+" {
                a = 1
            } else if aPart == "-" {
                a = -1
            } else {
                a = Int(aPart) ?? 1
            }

            let afterN = s[s.index(after: nIdx)...].trimmingCharacters(in: .whitespaces)
            if afterN.isEmpty {
                return (a, 0)
            }
            // afterN should be like "+3" or "- 2"
            let b = Int(afterN.replacingOccurrences(of: " ", with: "")) ?? 0
            return (a, b)
        }

        // No "n" — it's just a number b
        if let b = Int(s) {
            return (0, b)
        }

        return (0, 0)
    }

    private static func parseAttributeOperator(_ chars: [Character], _ index: inout Int) -> CSSAttributeOperator? {
        guard index < chars.count else { return nil }
        if chars[index] == "=" {
            index += 1
            return .equals
        }
        guard index + 1 < chars.count else { return nil }
        let a = chars[index]
        let b = chars[index + 1]
        switch (a, b) {
        case ("~", "="):
            index += 2
            return .containsWord
        case ("|", "="):
            index += 2
            return .startsWithOrDash
        case ("^", "="):
            index += 2
            return .prefixMatch
        case ("$", "="):
            index += 2
            return .suffixMatch
        case ("*", "="):
            index += 2
            return .substringMatch
        default:
            return nil
        }
    }

    private static func parseAttributeValue(_ chars: [Character], _ index: inout Int) -> String? {
        guard index < chars.count else { return nil }
        if chars[index] == "\"" || chars[index] == "'" {
            let quote = chars[index]
            index += 1
            var value = ""
            while index < chars.count, chars[index] != quote {
                if chars[index] == "\\", index + 1 < chars.count {
                    index += 1
                    value.append(consumeEscape(chars, &index))
                    continue
                }
                value.append(chars[index])
                index += 1
            }
            if index < chars.count, chars[index] == quote { index += 1 }
            return value
        }

        // Unquoted values are identifiers, so they can carry escapes too.
        return consumeIdentifier(chars, &index)
    }

    private static func consumeParenthesizedContent(_ chars: [Character], _ index: inout Int) -> String? {
        guard index < chars.count, chars[index] == "(" else { return nil }
        index += 1
        var depth = 1
        var result = ""
        var quote: Character?

        while index < chars.count {
            let ch = chars[index]

            if let q = quote {
                if ch == q { quote = nil }
                result.append(ch)
                index += 1
                continue
            }

            if ch == "\"" || ch == "'" {
                quote = ch
                result.append(ch)
                index += 1
                continue
            }

            if ch == "\\", index + 1 < chars.count {
                // Keep escapes intact for the nested parse.
                result.append(ch)
                result.append(chars[index + 1])
                index += 2
                continue
            }

            if ch == "(" {
                depth += 1
                result.append(ch)
                index += 1
                continue
            }

            if ch == ")" {
                depth -= 1
                if depth == 0 {
                    index += 1
                    return result
                }
                result.append(ch)
                index += 1
                continue
            }

            result.append(ch)
            index += 1
        }

        return result.isEmpty ? nil : result
    }

    private static func splitTopLevel(_ input: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var parenDepth = 0
        var bracketDepth = 0
        var quote: Character?
        var escaped = false

        for ch in input {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" {
                current.append(ch)
                escaped = true
                continue
            }
            if let q = quote {
                current.append(ch)
                if ch == q {
                    quote = nil
                }
                continue
            }

            if ch == "\"" || ch == "'" {
                quote = ch
                current.append(ch)
                continue
            }

            if ch == "(" { parenDepth += 1 }
            if ch == ")" { parenDepth = max(0, parenDepth - 1) }
            if ch == "[" { bracketDepth += 1 }
            if ch == "]" { bracketDepth = max(0, bracketDepth - 1) }

            if ch == separator, parenDepth == 0, bracketDepth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }

        if !current.isEmpty {
            parts.append(current)
        }
        return parts
    }

    private static func skipWhitespace(_ chars: [Character], _ index: inout Int) -> Bool {
        let start = index
        while index < chars.count, DOMNode.isASCIIWhitespace(chars[index]) {
            index += 1
        }
        return index > start
    }

    @inline(__always)
    private static func isIdentifierCharacter(_ ch: Character) -> Bool {
        if ch.isLetter || ch.isNumber { return true }
        if ch == "_" || ch == "-" { return true }
        // Anything non-ASCII is a valid identifier character in CSS.
        if let scalar = ch.unicodeScalars.first, scalar.value >= 0x80 { return true }
        return false
    }

    /// Consumes one CSS escape sequence, with `index` pointing at the character
    /// *after* the backslash. `\3130 ` -> U+3130, `\:` -> ":".
    private static func consumeEscape(_ chars: [Character], _ index: inout Int) -> String {
        guard index < chars.count else { return "" }
        let ch = chars[index]
        if ch.isHexDigit, ch.isASCII {
            var hex = ""
            while index < chars.count, hex.count < 6, chars[index].isHexDigit, chars[index].isASCII {
                hex.append(chars[index])
                index += 1
            }
            // A single trailing whitespace terminates the escape: `\31 0` is "10".
            if index < chars.count, DOMNode.isASCIIWhitespace(chars[index]) {
                index += 1
            }
            if let code = UInt32(hex, radix: 16), code != 0, let scalar = Unicode.Scalar(code) {
                return String(Character(scalar))
            }
            return "\u{FFFD}"
        }
        index += 1
        return String(ch)
    }

    /// Consumes a CSS identifier, resolving escapes (`.\:hover`, `#\31 0`).
    private static func consumeIdentifier(_ chars: [Character], _ index: inout Int) -> String? {
        guard index < chars.count else { return nil }
        var result = ""

        while index < chars.count {
            let ch = chars[index]
            if ch == "\\" {
                index += 1
                result += consumeEscape(chars, &index)
                continue
            }
            if isIdentifierCharacter(ch) {
                result.append(ch)
                index += 1
                continue
            }
            break
        }

        return result.isEmpty ? nil : result
    }

    private static func consumeUntil(_ chars: [Character], _ index: inout Int, stopAt: Character) {
        while index < chars.count, chars[index] != stopAt {
            index += 1
        }
    }
}

// MARK: - Public Façade

/// Entry point for selector support queries — backs `@supports selector(...)`
/// and lets the host check a selector before relying on it.
nonisolated public enum CSSSelector {

    /// Parse a selector list (cached).
    public static func parse(_ selector: String) -> CSSSelectorList {
        CSSSelectorParser.parse(selector)
    }

    /// `@supports selector(<selector>)` — true when the selector parses *and*
    /// every component in it is implemented. `:visited` counts as supported
    /// (it simply never matches); `:nth-child(2n of .x)` counts as supported;
    /// `::slotted(x)` or `:blink` do not.
    public static func isSupported(_ selector: String) -> Bool {
        let list = parse(selector)
        guard list.isValid, !list.selectors.isEmpty else { return false }
        return list.selectors.allSatisfy { isSupported(complex: $0) }
    }

    /// Specificity of a selector string. Returns the highest specificity in the
    /// list, or nil when the selector does not parse.
    public static func specificity(of selector: String) -> CSSSpecificity? {
        let list = parse(selector)
        guard !list.selectors.isEmpty else { return nil }
        return list.selectors.map { CSSSpecificity.calculate(for: $0) }.max()
    }

    /// Does `node` match the selector string? `scope` supplies `:scope`.
    public static func matches(_ selector: String, node: DOMNode, scope: DOMNode? = nil) -> Bool {
        let list = parse(selector)
        let context = CSSMatchContext(scope: scope)
        return list.selectors.contains { CSSSelectorMatcher.matches($0, node: node, context: context) }
    }

    private static func isSupported(complex: CSSComplexSelector) -> Bool {
        for part in complex.parts {
            for component in part.selector.components {
                if !isSupported(component: component) { return false }
            }
        }
        return true
    }

    private static func isSupported(component: CSSSelectorComponent) -> Bool {
        switch component {
        case .unsupported:
            return false
        case .pseudoNot(let selectors), .pseudoMatchesAny(let selectors), .pseudoWhere(let selectors):
            return selectors.allSatisfy { isSupported(complex: $0) }
        case .pseudoHas(let has):
            return has.selectors.allSatisfy { isSupported(complex: $0) }
        case .pseudoNthChild(_, _, let of), .pseudoNthLastChild(_, _, let of):
            guard let of else { return true }
            return of.allSatisfy { isSupported(complex: $0) }
        default:
            return true
        }
    }
}

// MARK: - Query plans (querySelector / querySelectorAll)

/// A parsed selector list prepared for scanning a subtree: pseudo-element
/// selectors dropped, and for lists of `bucketThreshold` or more selectors an
/// index of the selectors by the identifier their *rightmost compound*
/// requires (id, class, attribute name or tag; WebKit's RuleSet buckets).
/// An element then tests only the selectors whose bucket key it carries, plus
/// the selectors with no usable key, instead of every selector in the list.
///
/// Keyed by the selector string (like the parse cache), never by DOM state,
/// so a plan stays valid across mutations; the plan cache is bounded.
nonisolated final class CSSQueryPlan: @unchecked Sendable {
    static let bucketThreshold = 4

    let selectors: [CSSComplexSelector]
    private let byID: [String: [Int]]
    private let byClass: [String: [Int]]
    private let byTag: [String: [Int]]
    private let byAttribute: [String: [Int]]
    private let unkeyed: [Int]
    private let bucketed: Bool
    /// Per selector: identifier hashes (tag, id, class, attribute name) that
    /// must occur on an ancestor of any element it matches. A bare-tag subject
    /// such as `[data-x] ... a` lands in a big tag bucket; these let a bucket
    /// entry be rejected with a few counter reads on the scan's ancestor
    /// chain (`DOMAncestorChain`) before the matcher is called.
    /// Whether a plan wants the chain's filter maintained.
    var wantsAncestorFilter: Bool { bucketed }
    private let ancestorKeys: [[UInt32]]

    private init?(list: CSSSelectorList) {
        let candidates = list.selectors.filter { $0.pseudoElement == nil }
        guard !candidates.isEmpty else { return nil }
        selectors = candidates
        ancestorKeys = candidates.map { sel in
            var keys: [UInt32] = []
            var index = sel.parts.count - 1
            while index > 0 {
                let combinator = sel.parts[index].combinator ?? .descendant
                index -= 1
                guard combinator == .descendant || combinator == .child else { continue }
                let compound = sel.parts[index].selector
                keys.append(contentsOf: compound.ancestorKeyHashes)
                for component in compound.components {
                    if case .attribute(let name, _, _, _) = component {
                        keys.append(DOMSelectorKeyHash.attributeNameHash(name))
                    }
                }
            }
            return keys
        }
        guard candidates.count >= Self.bucketThreshold else {
            bucketed = false
            byID = [:]; byClass = [:]; byTag = [:]; byAttribute = [:]; unkeyed = []
            return
        }
        bucketed = true
        var ids: [String: [Int]] = [:], classes: [String: [Int]] = [:]
        var tags: [String: [Int]] = [:], attrs: [String: [Int]] = [:], loose: [Int] = []
        for (i, sel) in candidates.enumerated() {
            guard let subject = sel.parts.last?.selector else { loose.append(i); continue }
            var id: String?, cls: String?, tag: String?, attr: String?
            for component in subject.components {
                switch component {
                case .id(let v): if id == nil { id = v }
                case .className(let v): if cls == nil { cls = v }
                case .element(let v): if tag == nil { tag = v }
                case .attribute(let name, _, _, _): if attr == nil { attr = name.lowercased() }
                default: break
                }
            }
            if let id { ids[id, default: []].append(i) }
            else if let cls { classes[cls, default: []].append(i) }
            else if let attr { attrs[attr, default: []].append(i) }
            else if let tag { tags[tag, default: []].append(i) }
            else { loose.append(i) }
        }
        byID = ids; byClass = classes; byTag = tags; byAttribute = attrs; unkeyed = loose
    }

    /// True when any selector of the list matches `node`.
    func matches(_ node: DOMNode, context: CSSMatchContext) -> Bool {
        guard bucketed else {
            for sel in selectors where CSSSelectorMatcher.matches(sel, node: node, context: context) { return true }
            return false
        }
        let chain = context.ancestorChain.flatMap { $0.subject === node && $0.tracksFilter ? $0 : nil }
        func test(_ indices: [Int]) -> Bool {
            for i in indices {
                if let chain {
                    var rejected = false
                    for key in ancestorKeys[i] where !chain.mayContain(key) { rejected = true; break }
                    if rejected { continue }
                }
                if CSSSelectorMatcher.matches(selectors[i], node: node, context: context) { return true }
            }
            return false
        }
        if !unkeyed.isEmpty, test(unkeyed) { return true }
        if let tag = node.lowercasedTagName, let hit = byTag[tag], test(hit) { return true }
        if !byID.isEmpty, let id = node.idAttribute, let hit = byID[id], test(hit) { return true }
        if !byClass.isEmpty {
            for cls in node.classNames { if let hit = byClass[cls], test(hit) { return true } }
        }
        if !byAttribute.isEmpty {
            for key in node.attributes.keys { if let hit = byAttribute[key], test(hit) { return true } }
        }
        return false
    }

    // MARK: Cache (bounded, approximate LRU)

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (plan: CSSQueryPlan?, used: UInt64)] = [:]
    nonisolated(unsafe) private static var clock: UInt64 = 0
    private static let capacity = 128

    /// The plan for `selector` (nil when it parses to nothing usable).
    static func plan(for selector: String) -> CSSQueryPlan? {
        cacheLock.lock()
        clock += 1
        if var hit = cache[selector] {
            hit.used = clock
            cache[selector] = hit
            cacheLock.unlock()
            return hit.plan
        }
        cacheLock.unlock()
        let built = CSSQueryPlan(list: CSSSelectorParser.parse(selector))
        cacheLock.lock()
        if cache.count >= capacity {
            // Drop the least recently used quarter.
            let victims = cache.sorted { $0.value.used < $1.value.used }.prefix(capacity / 4).map(\.key)
            for key in victims { cache.removeValue(forKey: key) }
        }
        clock += 1
        cache[selector] = (built, clock)
        cacheLock.unlock()
        return built
    }

    static func clearCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }
}
