import XCTest
@testable import JeffJS

/// querySelector / querySelectorAll fast paths: early exit, selector-list
/// bucketing and plan cache, each checked against a plain
/// "walk everything, test every selector" oracle.
final class DOMQueryFastPathTests: XCTestCase {
    typealias Gen = SelectorMatcherDifferentialTests

    /// Document-order oracle: every descendant element, any selector of the list.
    static func oracleAll(_ root: DOMNode, _ selector: String) -> [DOMNode] {
        let list = CSSSelectorParser.parse(selector).selectors.filter { $0.pseudoElement == nil }
        guard !list.isEmpty else { return [] }
        let ctx = CSSMatchContext(scope: root)
        var out: [DOMNode] = []
        func walk(_ n: DOMNode) {
            for c in n.children {
                if c.nodeType == .element, list.contains(where: { Gen.oracle($0, c, ctx) }) { out.append(c) }
                walk(c)
            }
        }
        walk(root)
        return out
    }

    func testQuerySelectorIsFirstOfQuerySelectorAll() {
        var r = Gen.RNG(s: 0xBEEF)
        for _ in 0..<120 {
            let (doc, nodes, _) = Gen.buildTree(&r)
            for _ in 0..<30 {
                // Lists of 1..8 selectors so both the plain and the bucketed path run.
                let sel = (0..<(1 + r.int(8))).map { _ in Gen.selector(&r) }.joined(separator: ", ")
                for root in [doc, nodes[r.int(nodes.count)]] {
                    let all = root.querySelectorAll(sel)
                    let expect = Self.oracleAll(root, sel)
                    XCTAssertTrue(all.elementsEqual(expect, by: ===), "qSA differs from oracle for \(sel)")
                    XCTAssertTrue(root.querySelector(sel) === expect.first, "qS differs for \(sel)")
                }
            }
        }
    }

    func testQuerySelectorStopsAtFirstMatch() {
        // 5000 siblings; the first one matches. The walk must not visit the rest:
        // count visits through a selector that records them is impossible, so
        // compare timing against the full scan.
        var html = "<div id=\"r\">"
        for i in 0..<20000 { html += "<span class=\"s\(i == 0 ? "first" : "x")\">\(i)</span>" }
        html += "</div>"
        let root = HTMLParser.parse(html)
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<200 { XCTAssertNotNil(root.querySelector(".sfirst")) }
        let early = DispatchTime.now().uptimeNanoseconds - t0
        let t1 = DispatchTime.now().uptimeNanoseconds
        XCTAssertEqual(root.querySelectorAll(".sfirst").count, 1)
        let full = DispatchTime.now().uptimeNanoseconds - t1
        XCTAssertLessThan(early, full * 20, "200 early-exit queries cost more than 20 full scans")
    }

    func testPlanCacheStaysBounded() {
        let root = HTMLParser.parse("<div class=a><p class=b></p></div>")
        for i in 0..<1000 { _ = root.querySelectorAll(".c\(i), .b, .a, p, #x\(i)") }
        XCTAssertEqual(root.querySelectorAll(".c1, .b, .a, p, #x1").count, 2)
    }
}
