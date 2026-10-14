import XCTest
@testable import JeffJS

/// Prints per-call timings for the common DOM query shapes on a 12k-element
/// tree (no assertions; self-contained so it also runs on older checkouts).
final class DOMQueryBenchTests: XCTestCase {
    func time(_ label: String, _ reps: Int = 1, _ f: () -> Int) {
        _ = f()
        let t0 = DispatchTime.now().uptimeNanoseconds
        var n = 0
        for _ in 0..<reps { n = f() }
        let us = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e3 / Double(reps)
        print(String(format: "BENCH %-48@ %10.1f us/call  result=%d", label as NSString, us, n))
    }

    func testBench() {
        var html = "<html><head></head><body><div id=\"app\">"
        for s in 0..<100 {
            html += "<section class=\"s s\(s % 10)\" data-i=\"\(s)\"><div class=\"w\"><ul>"
            for i in 0..<30 { html += "<li class=\"it k\(i % 7)\"><a href=\"/x\(i)\"><span>t</span></a></li>" }
            html += "</ul></div></section>"
        }
        html += "<ul id=\"wide\">"
        for i in 0..<3000 { html += "<li class=\"wi\">\(i)</li>" }
        html += "</ul></div></body></html>"
        let root = HTMLParser.parse(html)
        time("qSA .k3") { root.querySelectorAll(".k3").count }
        time("qSA .nosuch") { root.querySelectorAll(".nosuch").count }
        time("qSA li") { root.querySelectorAll("li").count }
        time("qS body") { root.querySelector("body") == nil ? 0 : 1 }
        time("qS #wide") { root.querySelector("#wide") == nil ? 0 : 1 }
        time("qS .s9 .k3 a") { root.querySelector(".s9 .k3 a") == nil ? 0 : 1 }
        time("qSA section li a span") { root.querySelectorAll("section li a span").count }
        time("qSA [data-i='57']") { root.querySelectorAll("[data-i='57']").count }
        time("qSA #wide > li:nth-child(2n+1)") { root.querySelectorAll("#wide > li:nth-child(2n+1)").count }
        time("qSA #wide li:last-child") { root.querySelectorAll("#wide li:last-child").count }
        let list = (0..<100).map { "[data-x\($0)=\"v\"] li a, .nosuch\($0) span, #nid\($0)" }.joined(separator: ", ")
        time("qSA 300-selector list (no match)") { root.querySelectorAll(list).count }
        let last = root.querySelectorAll("#wide li").last!
        time("previousElementSibling walk, 3000 li") {
            var c = 0; var cur: DOMNode? = last
            while let x = cur { c += 1; cur = CSSSelectorMatcher.previousElementSibling(of: x) }; return c }
        let li = root.querySelectorAll("#wide li")[1500]
        time("matches #wide>li x1000", 1) { var c = 0; for _ in 0..<1000 { if li.matchesSelector("#wide > li") { c += 1 } }; return c }
        let sp = root.querySelectorAll("section span")[300]
        time("closest .s x1000", 1) { var c = 0; for _ in 0..<1000 { if sp.closestMatching(".s") != nil { c += 1 } }; return c }
    }
}
