import Foundation

// MARK: - Selector Components

/// A single component of a CSS selector.
public enum CSSSelectorComponent: Sendable {
    case element(String)    // div, p, h1
    case className(String)  // .header
    case id(String)         // #main
    case attribute(name: String, op: CSSAttributeOperator?, value: String?)
    case pseudoMatchesAny([CSSComplexSelector]) // :is(...), :matches(...)
    case pseudoWhere([CSSComplexSelector])      // :where(...) — zero specificity
    case pseudoNot([CSSComplexSelector])        // :not(...)
    case universal          // *
    case pseudoRoot         // :root
    // Structural pseudo-classes
    case pseudoFirstChild
    case pseudoLastChild
    case pseudoOnlyChild
    case pseudoNthChild(Int, Int)      // :nth-child(an+b) → (a, b)
    case pseudoNthLastChild(Int, Int)  // :nth-last-child(an+b)
    case pseudoFirstOfType
    case pseudoLastOfType
    case pseudoOnlyOfType
    case pseudoNthOfType(Int, Int)
    case pseudoNthLastOfType(Int, Int)
    case pseudoEmpty
    // State pseudo-classes (form elements)
    case pseudoChecked
    case pseudoDisabled
    case pseudoEnabled
    case pseudoReadOnly
    case pseudoReadWrite
    // Pseudo-element marker (::before, ::after, ::marker, ::placeholder) — extracted during selector construction
    case pseudoElementMarker(CSSPseudoElement)
    // Catch-all for unsupported pseudo-classes — never matches
    case neverMatches
}

/// CSS pseudo-elements supported for content generation and styling.
public enum CSSPseudoElement: String, Sendable {
    case before
    case after
    case placeholder
    case marker
}

public enum CSSAttributeOperator: Sendable {
    case equals
    case containsWord      // ~=
    case startsWithOrDash  // |=
    case prefixMatch       // ^=
    case suffixMatch       // $=
    case substringMatch    // *=
}

/// A compound selector — all components must match the same element.
/// e.g., "div.header" = [.element("div"), .className("header")]
public struct CSSCompoundSelector: Sendable {
    public let components: [CSSSelectorComponent]
}

/// Combinator between compound selectors.
public enum CSSCombinator: Sendable {
    case descendant       // whitespace
    case child            // >
    case adjacentSibling  // +
    case generalSibling   // ~
}

/// A complex selector is a chain of compound selectors with combinators.
public struct CSSComplexSelector: Sendable {
    public struct Part: Sendable {
        public let combinator: CSSCombinator?
        public let selector: CSSCompoundSelector
    }
    public let parts: [Part]
    /// If non-nil, this selector targets a pseudo-element (::before / ::after).
    public let pseudoElement: CSSPseudoElement?

    public init(parts: [Part], pseudoElement: CSSPseudoElement? = nil) {
        self.parts = parts
        self.pseudoElement = pseudoElement
    }
}

/// A selector list: "h1, h2, h3" — any selector matching means the rule applies.
public struct CSSSelectorList: Sendable {
    public let selectors: [CSSComplexSelector]
}

// MARK: - Specificity

public struct CSSSpecificity: Comparable, Sendable {
    public let inline: Int
    public let ids: Int
    public let classes: Int
    public let elements: Int

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
                switch component {
                case .id: ids += 1
                case .className, .attribute, .pseudoRoot,
                     .pseudoFirstChild, .pseudoLastChild, .pseudoOnlyChild,
                     .pseudoNthChild, .pseudoNthLastChild,
                     .pseudoFirstOfType, .pseudoLastOfType, .pseudoOnlyOfType,
                     .pseudoNthOfType, .pseudoNthLastOfType,
                     .pseudoEmpty,
                     .pseudoChecked, .pseudoDisabled, .pseudoEnabled,
                     .pseudoReadOnly, .pseudoReadWrite:
                    classes += 1
                case .pseudoNot(let selectors), .pseudoMatchesAny(let selectors):
                    // Specificity of :not() and :is() = highest specificity among arguments
                    let maxSpec = selectors.map { calculate(for: $0) }.max() ?? CSSSpecificity(inline: 0, ids: 0, classes: 0, elements: 0)
                    ids += maxSpec.ids
                    classes += maxSpec.classes
                    elements += maxSpec.elements
                case .pseudoWhere:
                    // :where() always contributes zero specificity
                    break
                case .element, .pseudoElementMarker: elements += 1
                case .universal: break
                case .neverMatches: classes += 1 // Unsupported pseudo-classes still contribute specificity (0,0,1,0)
                }
            }
        }
        return CSSSpecificity(inline: 0, ids: ids, classes: classes, elements: elements)
    }
}

// MARK: - Selector Matching

public struct CSSSelectorMatcher: Sendable {

    /// Test whether a complex selector matches a DOM node.
    public static func matches(_ selector: CSSComplexSelector, node: DOMNode) -> Bool {
        guard !selector.parts.isEmpty else { return false }

        // The rightmost part is the subject — it must match the node
        let parts = selector.parts
        var currentNode: DOMNode? = node

        // Walk parts from right to left
        var partIndex = parts.count - 1

        // First, the subject must match
        guard matchesCompound(parts[partIndex].selector, node: node) else {
            return false
        }
        partIndex -= 1

        // Then walk up/across the tree for each combinator
        while partIndex >= 0 {
            let part = parts[partIndex]
            let combinator = parts[partIndex + 1].combinator ?? .descendant

            switch combinator {
            case .descendant:
                // Walk ancestors until one matches
                currentNode = currentNode?.parent
                var found = false
                while let ancestor = currentNode {
                    if matchesCompound(part.selector, node: ancestor) {
                        found = true
                        break
                    }
                    currentNode = ancestor.parent
                }
                if !found { return false }

            case .child:
                // Direct parent must match
                currentNode = currentNode?.parent
                guard let parent = currentNode,
                      matchesCompound(part.selector, node: parent) else {
                    return false
                }
            case .adjacentSibling:
                guard let node = currentNode,
                      let sibling = previousElementSibling(of: node),
                      matchesCompound(part.selector, node: sibling) else {
                    return false
                }
                currentNode = sibling
            case .generalSibling:
                guard let node = currentNode else { return false }
                var sibling = previousElementSibling(of: node)
                var found = false
                while let candidate = sibling {
                    if matchesCompound(part.selector, node: candidate) {
                        currentNode = candidate
                        found = true
                        break
                    }
                    sibling = previousElementSibling(of: candidate)
                }
                if !found { return false }
            }

            partIndex -= 1
        }

        return true
    }

    /// Test whether a compound selector matches a single node.
    public static func matchesCompound(_ selector: CSSCompoundSelector, node: DOMNode) -> Bool {
        guard node.nodeType == .element else { return false }
        for component in selector.components {
            switch component {
            case .element(let tag):
                guard node.tagName == tag else { return false }
            case .className(let cls):
                guard node.classList.contains(cls) else { return false }
            case .id(let id):
                guard node.idAttribute == id else { return false }
            case .attribute(let name, let op, let value):
                guard matchesAttribute(node: node, name: name, op: op, value: value) else { return false }
            case .pseudoMatchesAny(let selectors), .pseudoWhere(let selectors):
                guard selectors.contains(where: { matches($0, node: node) }) else { return false }
            case .pseudoNot(let selectors):
                if selectors.contains(where: { matches($0, node: node) }) { return false }
            case .universal:
                continue
            case .pseudoRoot:
                guard node.parent?.nodeType == .document else { return false }
            case .pseudoFirstChild:
                guard elementIndex(of: node) == 0 else { return false }
            case .pseudoLastChild:
                guard isLastElement(node) else { return false }
            case .pseudoOnlyChild:
                guard elementIndex(of: node) == 0 && isLastElement(node) else { return false }
            case .pseudoNthChild(let a, let b):
                guard matchesNth(a: a, b: b, index: elementIndex(of: node)) else { return false }
            case .pseudoNthLastChild(let a, let b):
                guard matchesNth(a: a, b: b, index: elementIndexFromEnd(of: node)) else { return false }
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
                guard node.children.allSatisfy({ $0.nodeType == .comment || ($0.nodeType == .text && ($0.textContent ?? "").isEmpty) }) else { return false }
            case .pseudoChecked:
                guard matchesChecked(node) else { return false }
            case .pseudoDisabled:
                guard matchesDisabled(node) else { return false }
            case .pseudoEnabled:
                guard matchesEnabled(node) else { return false }
            case .pseudoReadOnly:
                guard matchesReadOnly(node) else { return false }
            case .pseudoReadWrite:
                guard matchesReadWrite(node) else { return false }
            case .pseudoElementMarker:
                // Pseudo-element markers are extracted during parsing; if one
                // remains in components it should not affect element matching.
                break
            case .neverMatches:
                return false
            }
        }
        return true
    }

    // MARK: - Structural Pseudo-class Helpers

    /// Returns the 0-based index of this element among its element siblings.
    private static func elementIndex(of node: DOMNode) -> Int {
        guard let parent = node.parent else { return 0 }
        var index = 0
        for child in parent.children {
            if child === node { return index }
            if child.nodeType == .element { index += 1 }
        }
        return 0
    }

    /// Returns the 0-based index of this element counting from the end among element siblings.
    private static func elementIndexFromEnd(of node: DOMNode) -> Int {
        guard let parent = node.parent else { return 0 }
        var index = 0
        for child in parent.children.reversed() {
            if child === node { return index }
            if child.nodeType == .element { index += 1 }
        }
        return 0
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
        guard let parent = node.parent else { return true }
        for child in parent.children.reversed() {
            if child.nodeType == .element { return child === node }
        }
        return false
    }

    /// Whether the node is the last element child of its type in its parent.
    private static func isLastElementOfType(_ node: DOMNode) -> Bool {
        guard let parent = node.parent, let tag = node.tagName else { return true }
        for child in parent.children.reversed() {
            if child.nodeType == .element && child.tagName == tag { return child === node }
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

    // MARK: - State Pseudo-class Helpers

    private static let formDisableableTags: Set<String> = ["input", "button", "select", "textarea", "fieldset"]

    private static func matchesChecked(_ node: DOMNode) -> Bool {
        guard let tag = node.tagName else { return false }
        if tag == "input" {
            let inputType = (node.attributes["type"] ?? "text").lowercased()
            guard inputType == "checkbox" || inputType == "radio" else { return false }
            return node.attributes["checked"] != nil
        }
        if tag == "option" {
            return node.attributes["selected"] != nil
        }
        return false
    }

    private static func matchesDisabled(_ node: DOMNode) -> Bool {
        guard let tag = node.tagName, formDisableableTags.contains(tag) else { return false }
        return node.attributes["disabled"] != nil
    }

    private static func matchesEnabled(_ node: DOMNode) -> Bool {
        guard let tag = node.tagName, formDisableableTags.contains(tag) else { return false }
        return node.attributes["disabled"] == nil
    }

    private static func matchesReadOnly(_ node: DOMNode) -> Bool {
        guard let tag = node.tagName else { return false }
        guard tag == "input" || tag == "textarea" else { return false }
        return node.attributes["readonly"] != nil || node.attributes["disabled"] != nil
    }

    private static func matchesReadWrite(_ node: DOMNode) -> Bool {
        guard let tag = node.tagName else { return false }
        guard tag == "input" || tag == "textarea" else { return false }
        return node.attributes["readonly"] == nil && node.attributes["disabled"] == nil
    }

    private static func previousElementSibling(of node: DOMNode) -> DOMNode? {
        guard let parent = node.parent else { return nil }
        let siblings = parent.children
        guard let idx = siblings.firstIndex(where: { $0 === node }), idx > 0 else { return nil }
        var scan = idx - 1
        while scan >= 0 {
            let candidate = siblings[scan]
            if candidate.nodeType == .element {
                return candidate
            }
            if scan == 0 { break }
            scan -= 1
        }
        return nil
    }

    private static func matchesAttribute(
        node: DOMNode,
        name: String,
        op: CSSAttributeOperator?,
        value: String?
    ) -> Bool {
        let attrName = name.lowercased()
        guard let attrValue = node.attributes[attrName] else {
            return false
        }
        guard let op else { return true }
        let value = value ?? ""

        switch op {
        case .equals:
            return attrValue == value
        case .containsWord:
            return attrValue
                .split(whereSeparator: \.isWhitespace)
                .contains { $0 == Substring(value) }
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

public struct CSSSelectorParser: Sendable {

    /// Cache of parsed selector lists keyed by their source strings.
    /// Avoids re-parsing the same selector strings that appear across stylesheets
    /// or are used by querySelector/querySelectorAll calls.
    nonisolated(unsafe) private static var selectorCache: [String: CSSSelectorList] = [:]

    /// Clear the selector cache. Call on page teardown to free memory.
    public static func clearCache() {
        selectorCache.removeAll()
    }

    /// Parse a selector string like "div.container > p, h1" into a CSSSelectorList.
    public static func parse(_ selectorString: String) -> CSSSelectorList {
        if let cached = selectorCache[selectorString] {
            return cached
        }
        let groups = splitTopLevel(selectorString, separator: ",")
        let selectors = groups.compactMap { parseComplexSelector($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let result = CSSSelectorList(selectors: selectors)
        selectorCache[selectorString] = result
        return result
    }

    private static func parseComplexSelector(_ input: String) -> CSSComplexSelector? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

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
                currentCombinator = comb
                _ = skipWhitespace(chars, &index)
                continue
            }

            guard let compound = parseCompoundSelector(chars, &index) else {
                break
            }

            parts.append(CSSComplexSelector.Part(
                combinator: currentCombinator,
                selector: compound
            ))
            currentCombinator = nil
            hasPreviousPart = true
        }

        guard !parts.isEmpty else { return nil }

        // Extract pseudo-element marker from the last compound selector's components.
        var pseudoElement: CSSPseudoElement? = nil
        if var lastPart = parts.last {
            let filtered = lastPart.selector.components.compactMap { component -> CSSSelectorComponent? in
                if case .pseudoElementMarker(let pseudo) = component {
                    pseudoElement = pseudo
                    return nil
                }
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

    private static func parseCompoundSelector(_ chars: [Character], _ index: inout Int) -> CSSCompoundSelector? {
        var components: [CSSSelectorComponent] = []
        let start = index

        if index < chars.count {
            if chars[index] == "*" {
                components.append(.universal)
                index += 1
            } else if let element = consumeIdentifier(chars, &index) {
                components.append(.element(element.lowercased()))
            }
        }

        while index < chars.count {
            let ch = chars[index]
            if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" || ch == ">" || ch == "+" || ch == "~" || ch == "," || ch == ")" {
                break
            }

            if ch == "." {
                index += 1
                if let cls = consumeIdentifier(chars, &index) {
                    components.append(.className(cls))
                }
                continue
            }

            if ch == "#" {
                index += 1
                if let id = consumeIdentifier(chars, &index) {
                    components.append(.id(id))
                }
                continue
            }

            if ch == "[" {
                if let attr = parseAttributeSelector(chars, &index) {
                    components.append(attr)
                }
                continue
            }

            if ch == ":" {
                if let pseudo = parsePseudoSelector(chars, &index) {
                    components.append(pseudo)
                }
                continue
            }

            // Unknown token in this position; consume one char to avoid infinite loop.
            index += 1
        }

        if components.isEmpty && index == start {
            return nil
        }
        return CSSCompoundSelector(components: components)
    }

    private static func parseAttributeSelector(_ chars: [Character], _ index: inout Int) -> CSSSelectorComponent? {
        guard index < chars.count, chars[index] == "[" else { return nil }
        index += 1
        _ = skipWhitespace(chars, &index)

        guard let name = consumeIdentifier(chars, &index)?.lowercased() else {
            consumeUntil(chars, &index, stopAt: "]")
            if index < chars.count, chars[index] == "]" { index += 1 }
            return nil
        }

        _ = skipWhitespace(chars, &index)
        var op: CSSAttributeOperator?
        var value: String?

        if let parsedOp = parseAttributeOperator(chars, &index) {
            op = parsedOp
            _ = skipWhitespace(chars, &index)
            value = parseAttributeValue(chars, &index)
            _ = skipWhitespace(chars, &index)

            // Optional flags like [attr="x" i] are ignored.
            _ = consumeIdentifier(chars, &index)
        }

        consumeUntil(chars, &index, stopAt: "]")
        if index < chars.count, chars[index] == "]" { index += 1 }

        return .attribute(name: name, op: op, value: value)
    }

    private static func parsePseudoSelector(_ chars: [Character], _ index: inout Int) -> CSSSelectorComponent? {
        guard index < chars.count, chars[index] == ":" else { return nil }
        index += 1

        // Pseudo-elements (::before / ::after)
        if index < chars.count, chars[index] == ":" {
            index += 1
            let pseudoName = consumeIdentifier(chars, &index)?.lowercased()
            // Consume optional arguments like ::slotted(...)
            if index < chars.count, chars[index] == "(" {
                _ = consumeParenthesizedContent(chars, &index)
            }
            if let pseudoName, let pseudo = CSSPseudoElement(rawValue: pseudoName) {
                return .pseudoElementMarker(pseudo)
            }
            return .neverMatches
        }

        guard let pseudoName = consumeIdentifier(chars, &index)?.lowercased() else { return nil }

        // Simple pseudo-classes without arguments
        switch pseudoName {
        case "root":
            return .pseudoRoot
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
        // State pseudo-classes (form elements)
        case "checked":
            return .pseudoChecked
        case "disabled":
            return .pseudoDisabled
        case "enabled":
            return .pseudoEnabled
        case "read-only":
            return .pseudoReadOnly
        case "read-write":
            return .pseudoReadWrite
        // User-interaction pseudo-classes — ignore in static rendering (never match)
        case "hover", "focus", "active", "visited", "focus-within", "focus-visible",
             "target",
             "placeholder-shown", "default", "indeterminate", "valid", "invalid",
             "required", "optional", "in-range", "out-of-range",
             "link", "any-link", "local-link":
            return .neverMatches
        default:
            break
        }

        // Pseudo-classes that require arguments
        guard index < chars.count, chars[index] == "(" else {
            // Unknown pseudo-class without args — must not silently drop.
            return .neverMatches
        }

        guard let argument = consumeParenthesizedContent(chars, &index) else { return .neverMatches }
        let trimmedArg = argument.trimmingCharacters(in: .whitespaces)

        switch pseudoName {
        case "not":
            let list = parse(trimmedArg).selectors
            guard !list.isEmpty else { return .neverMatches }
            return .pseudoNot(list)
        case "is", "matches", "-webkit-any", "-moz-any":
            let list = parse(trimmedArg).selectors
            guard !list.isEmpty else { return .neverMatches }
            return .pseudoMatchesAny(list)
        case "where":
            let list = parse(trimmedArg).selectors
            guard !list.isEmpty else { return .neverMatches }
            return .pseudoWhere(list)
        case "nth-child":
            let (a, b) = parseNthExpression(trimmedArg)
            return .pseudoNthChild(a, b)
        case "nth-last-child":
            let (a, b) = parseNthExpression(trimmedArg)
            return .pseudoNthLastChild(a, b)
        case "nth-of-type":
            let (a, b) = parseNthExpression(trimmedArg)
            return .pseudoNthOfType(a, b)
        case "nth-last-of-type":
            let (a, b) = parseNthExpression(trimmedArg)
            return .pseudoNthLastOfType(a, b)
        case "has":
            // :has() is complex; treat as never matching for now
            return .neverMatches
        default:
            return .neverMatches
        }
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
            // afterN should be like "+3" or "-2"
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
                value.append(chars[index])
                index += 1
            }
            if index < chars.count, chars[index] == quote { index += 1 }
            return value
        }

        let valueStart = index
        while index < chars.count {
            let ch = chars[index]
            if ch == "]" || ch.isWhitespace {
                break
            }
            index += 1
        }
        guard index > valueStart else { return nil }
        return String(chars[valueStart..<index])
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

        for ch in input {
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
        while index < chars.count, chars[index].isWhitespace {
            index += 1
        }
        return index > start
    }

    private static func consumeIdentifier(_ chars: [Character], _ index: inout Int) -> String? {
        guard index < chars.count else { return nil }
        let start = index

        func isIdentChar(_ ch: Character) -> Bool {
            ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == "\\"
        }

        while index < chars.count, isIdentChar(chars[index]) {
            index += 1
        }

        guard index > start else { return nil }
        return String(chars[start..<index])
    }

    private static func consumeUntil(_ chars: [Character], _ index: inout Int, stopAt: Character) {
        while index < chars.count, chars[index] != stopAt {
            index += 1
        }
    }
}
