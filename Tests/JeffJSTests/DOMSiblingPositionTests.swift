import XCTest
@testable import JeffJS

/// Cached sibling positions (`DOMNode+Siblings.swift`) under random tree
/// surgery: after every batch of mutations -- appends, inserts, removals,
/// moves between parents and between two documents, replaces, clears,
/// re-adding a detached children array -- every node's sibling queries and
/// structural pseudo-classes must equal a plain scan of its parent's children.
final class DOMSiblingPositionTests: XCTestCase {
    typealias RNG = SelectorMatcherDifferentialTests.RNG

    private func scanIndex(_ n: DOMNode) -> (Int, Int, Int, Int)? {   // index, elementIndex, elementCount, parentChildCount
        guard let p = n.parent, let i = p.children.firstIndex(where: { $0 === n }) else { return nil }
        var ei = 0, total = 0
        for (j, c) in p.children.enumerated() where c.nodeType == .element { if j < i { ei += 1 }; total += 1 }
        return (i, ei, total, p.children.count)
    }

    private func verify(_ nodes: [DOMNode], _ label: String) {
        for n in nodes {
            guard let (i, ei, total, count) = scanIndex(n), let p = n.parent else {
                XCTAssertNil(n.siblingPosition(), "\(label): detached node has a position")
                continue
            }
            let pos = n.siblingPosition()
            XCTAssertEqual(pos?.index, i, label)
            XCTAssertEqual(pos?.elementIndex, ei, label)
            XCTAssertEqual(pos?.elementCount, total, label)
            XCTAssertTrue(n.sibling(offset: 1) === (i + 1 < count ? p.children[i + 1] : nil), label)
            XCTAssertTrue(n.sibling(offset: -1) === (i > 0 ? p.children[i - 1] : nil), label)
            let next = p.children[(i + 1)...].first { $0.nodeType == .element }
            let prev = p.children[..<i].last { $0.nodeType == .element }
            XCTAssertTrue(CSSSelectorMatcher.nextElementSibling(of: n) === next, label)
            XCTAssertTrue(CSSSelectorMatcher.previousElementSibling(of: n) === prev, label)
            if n.nodeType == .element {
                XCTAssertEqual(n.matchesSelector(":first-child"), ei == 0, label)
                XCTAssertEqual(n.matchesSelector(":last-child"), ei == total - 1, label)
                XCTAssertEqual(n.matchesSelector(":nth-child(2n+1)"), ei % 2 == 0, label)
                XCTAssertEqual(n.matchesSelector(":nth-last-child(3)"), total - 1 - ei == 2, label)
            }
        }
    }

    func testPositionsSurviveRandomTreeSurgery() {
        var r = RNG(s: 0x51B1)
        for round in 0..<60 {
            let docs = [DOMNode.document(), DOMNode.document()]
            var pool: [DOMNode] = []
            var containers: [DOMNode] = []
            for d in docs {
                let root = DOMNode.element(tag: "div")
                d.appendChild(root); containers.append(root); pool.append(root)
            }
            func fresh() -> DOMNode {
                let n = r.chance(25) ? DOMNode.text("t") : DOMNode.element(tag: r.pick(["li", "p", "b"]))
                pool.append(n)
                if n.nodeType == .element, r.chance(30) { containers.append(n) }
                return n
            }
            for step in 0..<120 {
                let parent = r.pick(containers)
                switch r.int(8) {
                case 0, 1: parent.appendChild(fresh())
                case 2:
                    if let ref = parent.children.randomElement() { parent.insertChild(fresh(), before: ref) }
                case 3:
                    if let c = parent.children.randomElement() { parent.removeChild(c) }
                case 4:   // move a node to another parent (possibly in the other document)
                    let n = r.pick(pool)
                    let target = r.pick(containers)
                    // never make a cycle
                    var cursor: DOMNode? = target; var cyc = false
                    while let c = cursor { if c === n { cyc = true; break }; cursor = c.parent }
                    if !cyc, n.nodeType != .document {
                        if let old = n.parent { old.removeChild(n) }
                        if let ref = target.children.randomElement(), r.chance(50) { target.insertChild(n, before: ref) }
                        else { target.appendChild(n) }
                    }
                case 5:
                    if let old = parent.children.randomElement() {
                        parent.replaceChild(old, with: [fresh(), fresh()])
                    }
                case 6:
                    if r.chance(25) {
                        let kids = parent.detachChildrenArray()
                        for k in kids { k.parent = nil }
                        for k in kids.reversed() { parent.appendChild(k) }
                    }
                default:
                    if r.chance(10) { parent.clearChildren() }
                }
                if step % 7 == 0 { verify(pool, "round \(round) step \(step)") }
            }
            verify(pool, "round \(round) end")
        }
    }

    func testSiblingWalkIsLinear() {
        let list = DOMNode.element(tag: "ul")
        for _ in 0..<20000 { list.appendChild(DOMNode.element(tag: "li")) }
        let t0 = DispatchTime.now().uptimeNanoseconds
        var cur = list.firstChildNode
        var n = 0
        while let c = cur { n += 1; cur = c.sibling(offset: 1) }
        var back = list.lastChildNode
        while let c = back { n += 1; back = CSSSelectorMatcher.previousElementSibling(of: c) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        XCTAssertEqual(n, 40000)
        XCTAssertLessThan(ms, 300, "sibling walk over 20000 children took \(ms) ms")
        let m0 = DispatchTime.now().uptimeNanoseconds
        XCTAssertEqual(list.querySelectorAll("li:nth-child(2n+1)").count, 10000)
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - m0) / 1e6, 300)
    }
}
