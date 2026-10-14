import XCTest
import Synchronization
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
            let (doc, nodes, hosts) = Gen.buildTree(&r)
            for _ in 0..<30 {
                // Lists of 1..8 selectors so both the plain and the bucketed path run.
                let sel = (0..<(1 + r.int(8))).map { _ in Gen.selector(&r) }.joined(separator: ", ")
                for root in [doc, nodes[r.int(nodes.count)]] + hosts.compactMap(\.shadowRoot) {
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

    func testLongSelectorListIsBucketed() {
        var html = "<div id=\"app\">"
        for i in 0..<4000 { html += "<section class=\"s k\(i % 7)\" data-i=\"\(i)\"><a href=\"/x\"><span>t</span></a></section>" }
        html += "</div>"
        let root = HTMLParser.parse(html)
        let list = (0..<300).map { "[data-x\($0)=\"v\"].c\($0), .nosuch\($0) span, #nid\($0), p.q\($0)" }.joined(separator: ", ")
            + ", [data-i=\"57\"], .k3.s section, section > a"
        let t0 = DispatchTime.now().uptimeNanoseconds
        let got = root.querySelectorAll(list)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        XCTAssertTrue(got.elementsEqual(Self.oracleAll(root, list), by: ===))
        XCTAssertEqual(got.count, 4001)   // every <a> plus section 57
        XCTAssertLessThan(ms, 150, "1200-selector list took \(ms) ms")
    }

    /// Selectors whose subject is a bare tag but whose ancestors need an
    /// attribute: only the scan's ancestor filter can reject them cheaply.
    func testAttributeAnchoredAncestorsAreRejectedByTheChainFilter() {
        var html = "<div id=\"app\">"
        for i in 0..<4000 { html += "<section class=\"s\" data-i=\"\(i)\"><a href=\"/x\"><span>t</span></a></section>" }
        html += "</div>"
        let root = HTMLParser.parse(html)
        let list = (0..<300).map { "[data-x\($0)=\"v\"] section a, [data-y\($0)] span" }.joined(separator: ", ") + ", [data-i=\"57\"] a"
        let t0 = DispatchTime.now().uptimeNanoseconds
        let got = root.querySelectorAll(list)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        XCTAssertTrue(got.elementsEqual(Self.oracleAll(root, list), by: ===))
        XCTAssertEqual(got.count, 1)
        XCTAssertLessThan(ms, 150, "attribute-anchored list took \(ms) ms")
    }
}

/// Readers scanning (querySelectorAll, sibling queries) while the single
/// writer mutates; run under `swift test --sanitize=thread` too.
final class DOMQueryConcurrencyTests: XCTestCase {
    func testConcurrentReadersDuringMutation() {
        let root = HTMLParser.parse("<div id=\"r\"></div>")
        let host = root.querySelector("#r")!
        for i in 0..<200 { let e = DOMNode.element(tag: "li", attributes: ["class": "k\(i % 5)"]); host.appendChild(e) }
        let stop = Atomic<Bool>(false)
        let group = DispatchGroup()
        for t in 0..<3 {
            group.enter()
            Thread.detachNewThread {
                var n = 0
                while !stop.load(ordering: .acquiring) {
                    n += root.querySelectorAll("#r > li.k\(t), li:nth-child(2n+1), li + li ~ li.k1").count
                    if let first = host.firstChildNode { n += first.sibling(offset: 1) == nil ? 0 : 1 }
                    _ = root.querySelector(".k3")
                }
                group.leave()
            }
        }
        for step in 0..<3000 {
            let kids = host.children
            switch step % 4 {
            case 0: host.appendChild(DOMNode.element(tag: "li", attributes: ["class": "k\(step % 5)"]))
            case 1: if let k = kids.randomElement() { host.removeChild(k) }
            case 2: if let a = kids.randomElement(), let b = kids.randomElement(), a !== b, a.parent === host {
                host.removeChild(a); host.insertChild(a, before: b) }
            default: kids.randomElement()?.setAttribute(name: "class", value: "k\(step % 5)")
            }
        }
        stop.store(true, ordering: .releasing)
        group.wait()
    }
}
