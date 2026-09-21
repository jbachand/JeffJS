import XCTest
@testable import JeffJS

/// Micro-benchmark: 1000 rules matched against 2000 elements.
/// Uses only API that exists both before and after the selector work so the
/// same file can be dropped into either worktree.
final class SelectorBenchTests: XCTestCase {

    private func buildTree(elementCount: Int) -> DOMNode {
        var html = ""
        var depth = 0
        for i in 0..<elementCount {
            let cls = "c\(i % 37) k\(i % 11)"
            let tag = ["div", "span", "p", "a", "li", "section"][i % 6]
            html += "<\(tag) id=\"n\(i)\" class=\"\(cls)\" data-role=\"r\(i % 13)\">"
            depth += 1
            if depth > 6 {
                // close a few levels so the tree is wide as well as deep
                for _ in 0..<6 {
                    html += "</div>"
                }
                depth = 0
            }
        }
        return HTMLParser.parse(html)
    }

    private func buildSelectors(count: Int) -> [String] {
        var selectors: [String] = []
        let tags = ["div", "span", "p", "a", "li", "section"]
        for i in 0..<count {
            switch i % 10 {
            case 0: selectors.append(".c\(i % 37)")
            case 1: selectors.append("\(tags[i % 6]).k\(i % 11)")
            case 2: selectors.append("#n\(i)")
            case 3: selectors.append("div .c\(i % 37)")
            case 4: selectors.append("div > span.k\(i % 11)")
            case 5: selectors.append("[data-role='r\(i % 13)']")
            case 6: selectors.append("li:nth-child(2n+1)")
            case 7: selectors.append("p:not(.c\(i % 37))")
            case 8: selectors.append("section a + span")
            default: selectors.append("\(tags[i % 6]) .k\(i % 11) .c\(i % 37)")
            }
        }
        return selectors
    }

    func testMatch1000RulesAgainst2000Elements() {
        let root = buildTree(elementCount: 2000)
        var elements: [DOMNode] = []
        func walk(_ n: DOMNode) {
            for c in n.children {
                if c.nodeType == .element { elements.append(c) }
                walk(c)
            }
        }
        walk(root)
        let rules = buildSelectors(count: 1000).map { CSSSelectorParser.parse($0) }
        XCTAssertGreaterThan(elements.count, 1500)

        // warm up
        var matches = 0
        for rule in rules.prefix(50) {
            for el in elements.prefix(100) {
                for sel in rule.selectors where CSSSelectorMatcher.matches(sel, node: el) { matches += 1 }
            }
        }

        var best = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            matches = 0
            let start = Date()
            for rule in rules {
                for el in elements {
                    for sel in rule.selectors where CSSSelectorMatcher.matches(sel, node: el) { matches += 1 }
                }
            }
            best = min(best, Date().timeIntervalSince(start))
        }
        print("[BENCH] elements=\(elements.count) rules=\(rules.count) matches=\(matches) best=\(String(format: "%.4f", best))s")
    }

    /// `:has()` should only cost anything when it is actually used.
    func testHasOnlyCostsWhenUsed() {
        let root = buildTree(elementCount: 2000)
        var elements: [DOMNode] = []
        func walk(_ n: DOMNode) {
            for c in n.children {
                if c.nodeType == .element { elements.append(c) }
                walk(c)
            }
        }
        walk(root)
        let plain = CSSSelectorParser.parse("div.k3")
        let withHas = CSSSelectorParser.parse("div.k3:has(> .c5)")

        func time(_ list: CSSSelectorList) -> Double {
            let start = Date()
            var n = 0
            for el in elements {
                for sel in list.selectors where CSSSelectorMatcher.matches(sel, node: el) { n += 1 }
            }
            return Date().timeIntervalSince(start)
        }
        _ = time(plain)
        let plainTime = time(plain)
        let hasTime = time(withHas)
        print("[BENCH-HAS] plain=\(String(format: "%.4f", plainTime))s has=\(String(format: "%.4f", hasTime))s")
    }
}
