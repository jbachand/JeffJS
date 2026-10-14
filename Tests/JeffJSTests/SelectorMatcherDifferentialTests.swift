import XCTest
@testable import JeffJS

/// Differential test for the selector chain matcher: the greedy / memoised
/// right-to-left matcher against the plain exhaustive backtracking one it
/// replaced (kept here as the oracle), over random trees (with shadow roots)
/// and random selectors covering every combinator, `:is`, `:not`, `:has`,
/// `:scope`, `:host`, `:host()`, `:host-context()` and the structural
/// pseudo-classes, in document and shadow-tree match contexts.
final class SelectorMatcherDifferentialTests: XCTestCase {

    struct RNG {
        var s: UInt64
        mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
        mutating func chance(_ pct: Int) -> Bool { int(100) < pct }
    }

    // MARK: Oracle (the pre-memo algorithm)

    static func oracle(_ sel: CSSComplexSelector, _ node: DOMNode, _ ctx: CSSMatchContext) -> Bool {
        let parts = sel.parts
        let last = parts.count - 1
        guard CSSSelectorMatcher.matchesCompound(parts[last].selector, node: node, context: ctx) else { return false }
        if last == 0 { return true }
        return combinator(parts, last, node, ctx)
    }
    static func chain(_ parts: [CSSComplexSelector.Part], _ i: Int, _ node: DOMNode, _ ctx: CSSMatchContext) -> Bool {
        guard CSSSelectorMatcher.matchesCompound(parts[i].selector, node: node, context: ctx) else { return false }
        return i == 0 ? true : combinator(parts, i, node, ctx)
    }
    static func combinator(_ parts: [CSSComplexSelector.Part], _ i: Int, _ node: DOMNode, _ ctx: CSSMatchContext) -> Bool {
        switch parts[i].combinator ?? .descendant {
        case .child:
            guard let p = CSSSelectorMatcher.selectorParent(of: node, context: ctx) else { return false }
            return chain(parts, i - 1, p, ctx)
        case .descendant:
            var c = CSSSelectorMatcher.selectorParent(of: node, context: ctx)
            while let a = c {
                if chain(parts, i - 1, a, ctx) { return true }
                c = CSSSelectorMatcher.selectorParent(of: a, context: ctx)
            }
            return false
        case .adjacentSibling:
            guard let s = CSSSelectorMatcher.previousElementSibling(of: node) else { return false }
            return chain(parts, i - 1, s, ctx)
        case .generalSibling:
            var c = CSSSelectorMatcher.previousElementSibling(of: node)
            while let s = c {
                if chain(parts, i - 1, s, ctx) { return true }
                c = CSSSelectorMatcher.previousElementSibling(of: s)
            }
            return false
        }
    }

    // MARK: Generators

    static let tags = ["div", "span", "p", "a"]
    static let classes = ["a", "b", "c", "d"]

    static func buildTree(_ r: inout RNG) -> (doc: DOMNode, nodes: [DOMNode], hosts: [DOMNode]) {
        let doc = DOMNode.document()
        let root = DOMNode.element(tag: "div", attributes: ["class": "o"])
        doc.appendChild(root)
        var all = [root]
        var hosts: [DOMNode] = []
        func attrs(_ r: inout RNG) -> [String: String] {
            var at: [String: String] = [:]
            let k = r.int(3)
            if k > 0 { at["class"] = (0..<k).map { _ in r.pick(classes) }.joined(separator: " ") }
            if r.chance(25) { at["id"] = "i\(r.int(3))" }
            if r.chance(30) { at["data-x"] = r.pick(["u", "v"]) }
            return at
        }
        func grow(_ parent: DOMNode, depth: Int, _ r: inout RNG, into list: inout [DOMNode]) {
            guard depth < 7 else { return }
            for _ in 0..<(1 + r.int(3)) {
                if r.chance(15) { parent.appendChild(.text("t")) }
                let e = DOMNode.element(tag: r.pick(tags), attributes: attrs(&r))
                parent.appendChild(e); list.append(e)
                if r.chance(70) { grow(e, depth: depth + 1, &r, into: &list) }
            }
        }
        grow(root, depth: 0, &r, into: &all)
        for e in all where r.chance(8) && e !== root {
            let h = DOMNode.element(tag: "x-h", attributes: ["class": r.pick(["h", "a"])])
            e.appendChild(h)
            if let sr = h.attachShadowRoot(mode: "open") {
                var inner: [DOMNode] = []
                grow(sr, depth: 3, &r, into: &inner)
                all.append(h); all.append(contentsOf: inner); hosts.append(h)
            }
        }
        return (doc, all, hosts)
    }

    static func compound(_ r: inout RNG, allowDeep: Bool) -> String {
        var s = ""
        if r.chance(45) { s += r.pick(tags) }
        for _ in 0..<r.int(3) {
            switch r.int(allowDeep ? 14 : 8) {
            case 0, 1, 2: s += "." + r.pick(classes)
            case 3: s += "#i\(r.int(3))"
            case 4: s += "[data-x]"
            case 5: s += "[data-x=\(r.pick(["u", "v"]))]"
            case 6: s += r.pick([":first-child", ":last-child", ":nth-child(2n+1)", ":only-child", ":empty"])
            case 7: s += ":scope"
            case 8: s += ":not(.\(r.pick(classes)))"
            case 9: s += ":is(.\(r.pick(classes)), \(r.pick(tags)))"
            case 10: s += ":has(> .\(r.pick(classes)))"
            case 11: s += ":has(.\(r.pick(classes)) + \(r.pick(tags)))"
            case 12: s += r.pick([":host", ":host(.h)", ":host-context(.o)", ":host-context(.a)"])
            default: s += ":not(\(r.pick(tags)) .\(r.pick(classes)))"
            }
        }
        return s.isEmpty ? "*" : s
    }

    static func selector(_ r: inout RNG) -> String {
        let n = 1 + r.int(5)
        var s = compound(&r, allowDeep: true)
        for _ in 1..<n {
            s += " " + r.pick([" ", " ", ">", "+", "~"]) + " " + compound(&r, allowDeep: false)
        }
        return s.replacingOccurrences(of: "   ", with: " ").replacingOccurrences(of: "  ", with: " ")
    }

    func testMatcherAgreesWithExhaustiveOracle() {
        var r = RNG(s: 0xC0FFEE)
        var checked = 0, matched = 0
        for _ in 0..<150 {
            let (doc, nodes, hosts) = Self.buildTree(&r)
            let sels: [CSSComplexSelector] = (0..<40).compactMap { _ in
                CSSSelectorParser.parse(Self.selector(&r)).selectors.first
            }
            var contexts: [CSSMatchContext] = [.none, CSSMatchContext(scope: doc), CSSMatchContext(scope: nodes[r.int(nodes.count)])]
            for h in hosts { contexts.append(CSSMatchContext(scope: nil, shadowHost: h)) }
            for sel in sels where sel.pseudoElement == nil {
                for ctx in contexts {
                    for n in nodes {
                        let a = CSSSelectorMatcher.matches(sel, node: n, context: ctx)
                        let b = Self.oracle(sel, n, ctx)
                        XCTAssertEqual(a, b, "matcher disagrees with oracle")
                        checked += 1; if a { matched += 1 }
                    }
                }
            }
        }
        XCTAssertGreaterThan(matched, 1000, "fuzz must produce matches (\(matched)/\(checked))")
    }

    // MARK: Pathological depth

    func testDeepDescendantChainsAreNotExponential() {
        var html = "<div data-module-type=\"Y\">"
        for _ in 0..<60 { html += "<div>" }
        html += "<span>x</span>"
        for _ in 0..<60 { html += "</div>" }
        html += "</div>"
        let root = HTMLParser.parse(html)
        let t0 = DispatchTime.now().uptimeNanoseconds
        XCTAssertEqual(root.querySelectorAll("[data-module-type=\"X\"] div div div div div div div div").count, 0)
        XCTAssertEqual(root.querySelectorAll("body div div div div div div div div div div span.none").count, 0)
        // Child combinators mixed in force the memoised path.
        XCTAssertEqual(root.querySelectorAll("div > div div > div div > div div > div div > div span.none").count, 0)
        XCTAssertEqual(root.querySelectorAll("div > div div > div div > div div > div div > div span").count, 1)
        XCTAssertEqual(root.querySelectorAll("div ~ div div ~ div div ~ div div ~ div span.none").count, 0)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        XCTAssertLessThan(ms, 500, "deep chains took \(ms) ms")
    }
}
