// DOMThreadSafetyTests.swift
// JeffJS — the DOM threading contract (header of `DOMNode.swift`): one
// mutating thread; any number of reader threads may call the matching /
// attribute / children getters concurrently and see a consistent snapshot per
// call. This is what lets the app's style pass read the DOM on its own thread
// while script mutates it.
//
// * `DOMThreadSafetyTests.testConcurrentMutationAndMatching` — one writer
//   mutates attributes / classes / ids / lang / children / text of a
//   5,000-node tree while two readers run `querySelectorAll` and full
//   per-element matching (plus every reader-facing getter) and a third thread
//   builds and drops detached subtrees (an image decode building SVG nodes:
//   it bumps the global selector epoch from another thread). Default 5 s,
//   `DOM_STRESS_SECONDS` overrides. Run it under Thread Sanitizer on an iOS
//   Simulator (on macOS 26 / Xcode 26.2 host-side TSan crashes at launch, even
//   for an empty C program, and `swift test --sanitize=thread` cannot inject
//   the runtime into the signed test helper):
//
//       xcodebuild test -scheme JeffJS-Package -enableThreadSanitizer YES \
//         -destination "platform=iOS Simulator,id=<udid>" \
//         -only-testing:JeffJSTests/DOMThreadSafetyTests
//
// * `testDOMConformanceGroups` runs the DOM / selector conformance groups on
//   their own (so they can be run under TSan without the whole suite).
// * The "DOMThreadSafety" conformance group (`EngineTests/testConformance`)
//   is a short (0.3 s) version of the stress run with the same invariants.

import Foundation
import XCTest
@testable import JeffJS

/// The stress run shared by the XCTest and the conformance group.
enum DOMThreadStress {

    struct Report {
        var writerOps = 0
        var readerPasses = 0
        var queryPasses = 0
        var builderTrees = 0
        var failures: [String] = []
    }

    /// Deterministic xorshift, one per thread.
    struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    }

    static let classPool = ["a", "b", "c", "d", "nav", "item", "active", "hidden", "x-y", "big"]
    static let langPool = ["en", "en-US", "fr", "de-CH", "ja", ""]
    static let tagPool = ["div", "p", "span", "section", "ul", "li", "a", "em", "b", "article"]

    static let selectorTexts = [
        "div", ".a", "#n17", ".a .b", "div > p", "section .item.active", "ul > li:first-child",
        "li:nth-child(2n+1)", ".nav a[href]", ":lang(en) .c", ":lang(fr) span", "p ~ span", "em + b",
        ":is(.a, .b) > .c", "div:not(.hidden) .big", ":has(> .active)", "article :has(.x-y)",
        "[data-k=\"1\"]", "[lang|=de] p", ":empty", "p:only-child", ".d .c .b .a",
        "section > :is(div, p) ~ .item", "*:where(.nav) *", "[class~=big]", "li:last-of-type",
    ]

    /// Builds a tree of about `count` nodes (elements plus a text child for
    /// every third element).
    static func buildTree(count: Int, rng: inout RNG) -> (root: DOMNode, elements: [DOMNode]) {
        let root = DOMNode.element(tag: "html", attributes: ["lang": "en"])
        var elements: [DOMNode] = [root]
        var total = 1
        var frontier = [root]
        var index = 0
        while total < count {
            let parent = frontier[index % frontier.count]
            index += 1
            let node = makeElement(serial: total, rng: &rng)
            parent.appendChild(node)
            elements.append(node)
            frontier.append(node)
            total += 1
            if total % 3 == 0 && total < count {
                node.appendChild(.text("t\(total)"))
                total += 1
            }
            if frontier.count > 64 { frontier.removeFirst(16) }
        }
        return (root, elements)
    }

    static func makeElement(serial: Int, rng: inout RNG) -> DOMNode {
        var attributes: [String: String] = [:]
        if rng.below(2) == 0 {
            attributes["class"] = "\(classPool[rng.below(classPool.count)]) \(classPool[rng.below(classPool.count)])"
        }
        if rng.below(5) == 0 { attributes["id"] = "n\(serial)" }
        if rng.below(20) == 0 { attributes["lang"] = langPool[rng.below(langPool.count)] }
        if rng.below(8) == 0 { attributes["href"] = "#" }
        return DOMNode.element(tag: tagPool[rng.below(tagPool.count)], attributes: attributes)
    }

    /// Runs the stress for `seconds` and checks the end state.
    static func run(seconds: Double, nodes: Int = 5_000) -> Report {
        var rng = RNG(state: 0x9E37_79B9_7F4A_7C15)
        let (root, initial) = buildTree(count: nodes, rng: &rng)
        let selectors = selectorTexts.map { CSSSelectorParser.parse($0).selectors[0] }
        let stop = StopFlag()
        let group = DispatchGroup()
        let lock = NSLock()
        let shared = UncheckedBox(Report())

        func spawn(_ name: String, _ body: @escaping @Sendable () -> Void) {
            group.enter()
            let thread = Thread {
                body()
                group.leave()
            }
            thread.name = name
            thread.stackSize = 8 << 20
            thread.start()
        }

        // ---- the one mutating thread ----
        let writerElements = UncheckedBox(initial)
        spawn("dom-writer") {
            var rng = RNG(state: 0xD1B5_4A32_D192_ED03)
            var elements = writerElements.value
            var ops = 0
            var serial = 100_000
            while !stop.isSet {
                let node = elements[rng.below(elements.count)]
                switch rng.below(14) {
                case 0, 1:
                    node.setAttribute(name: "class", value: "\(classPool[rng.below(classPool.count)]) \(classPool[rng.below(classPool.count)])")
                case 2:
                    node.removeAttribute(name: "class")
                case 3:
                    node.setAttribute(name: "id", value: "n\(rng.below(6_000))")
                case 4:
                    if rng.below(2) == 0 {
                        node.setAttribute(name: "lang", value: langPool[rng.below(langPool.count)])
                    } else {
                        node.removeAttribute(name: "lang")
                    }
                case 5:
                    node.setAttribute(name: "data-k", value: "\(rng.below(3))")
                case 6:
                    node.attributes["title"] = "t\(ops)"          // host-style direct edit
                case 7:
                    node.setAttributePreservingCase(name: "viewBox", value: "0 0 \(rng.below(9)) 1")
                case 8:
                    // Move a leaf-ish element somewhere else (never under itself).
                    let moving = elements[1 + rng.below(elements.count - 1)]
                    let target = elements[rng.below(elements.count)]
                    var cursor: DOMNode? = target
                    var inside = false
                    while let c = cursor { if c === moving { inside = true; break }; cursor = c.parent }
                    if !inside, let old = moving.parent {
                        old.removeChild(moving)
                        if let first = target.firstChildNode, rng.below(2) == 0 {
                            target.insertChild(moving, before: first)
                        } else {
                            target.appendChild(moving)
                        }
                    }
                case 9:
                    // Add a new element, or drop one that has no children.
                    if rng.below(2) == 0 || elements.count < nodes / 2 {
                        let fresh = makeElement(serial: serial, rng: &rng)
                        serial += 1
                        node.appendChild(fresh)
                        elements.append(fresh)
                    } else {
                        let victimIndex = 1 + rng.below(elements.count - 1)
                        let victim = elements[victimIndex]
                        if victim.children.allSatisfy({ $0.nodeType == .text }), let old = victim.parent {
                            old.removeChild(victim)
                            elements.swapAt(victimIndex, elements.count - 1)
                            elements.removeLast()
                        }
                    }
                case 10:
                    // Text data: replace, append, or set an element's text.
                    if let text = node.children.first(where: { $0.nodeType == .text }) {
                        if rng.below(2) == 0 { text.textContent = "v\(ops)" } else { text.appendTextData("+") }
                    } else if node.children.isEmpty {
                        node.setTextContent(rng.below(2) == 0 ? "" : "w\(ops)")
                    }
                case 11:
                    // Replace a child with two fresh ones.
                    if let child = node.firstChildNode, child.nodeType == .text {
                        node.replaceChild(child, with: [.text("r"), .comment("c")])
                    }
                case 12:
                    // A whole-dictionary replace, keeping class and id.
                    var attrs = node.attributes
                    attrs["data-z"] = "\(ops & 7)"
                    node.attributes = attrs
                default:
                    node.removeAttribute(name: "data-k")
                }
                ops += 1
                // Script mutates in bursts, not flat out: leave the readers
                // room to finish passes (every write bumps the global epoch).
                if ops % 4 == 0 { usleep(50) }
            }
            writerElements.value = elements
            lock.lock(); shared.value.writerOps = ops; lock.unlock()
        }

        // ---- reader 1: full per-element matching, as the style pass does ----
        spawn("dom-reader-match") {
            var passes = 0
            var failures: [String] = []
            while !stop.isSet {
                CSSSelectorMatcher.beginMatchPass()
                var stack: [DOMNode] = [root]
                var visited = 0
                while let node = stack.popLast() {
                    visited += 1
                    let kids = node.children
                    for child in kids.reversed() { stack.append(child) }
                    guard node.nodeType == .element else {
                        _ = node.textContent
                        continue
                    }
                    for selector in selectors { _ = CSSSelectorMatcher.matches(selector, node: node) }
                    // Every reader-facing getter (each one is its own snapshot;
                    // the end state is checked once the writer has stopped).
                    let classes = node.classList
                    _ = node.classNames
                    for cls in classes where !node.hasClass(cls) && node.classList.contains(cls) {
                        failures.append("hasClass disagrees with classList on a stable class")
                    }
                    let attrs = node.attributes
                    if let id = attrs["id"], id.isEmpty { failures.append("empty id was never written") }
                    _ = node.orderedAttributes
                    _ = node.enumerableAttributes
                    _ = node.language
                    _ = node.inlineStyle
                    _ = node.parent?.lowercasedTagName
                    _ = node.textDescendants
                }
                CSSSelectorMatcher.endMatchPass()
                if visited == 0 { failures.append("empty traversal") }
                passes += 1
            }
            lock.lock(); shared.value.readerPasses = passes; shared.value.failures += failures; lock.unlock()
        }

        // ---- reader 2: querySelectorAll / closest / matches, as script-side reads do ----
        spawn("dom-reader-query") {
            var passes = 0
            var failures: [String] = []
            while !stop.isSet {
                for text in selectorTexts {
                    let found = root.querySelectorAll(text)
                    for node in found.prefix(8) {
                        _ = node.closestMatching("section, ul")
                        if node.nodeType != .element { failures.append("querySelectorAll returned a non-element") }
                    }
                }
                passes += 1
            }
            lock.lock(); shared.value.queryPasses = passes; shared.value.failures += failures; lock.unlock()
        }

        // ---- a builder: detached subtrees made and dropped on another thread ----
        spawn("dom-builder") {
            var rng = RNG(state: 0x2545_F491_4F6C_DD1D)
            var trees = 0
            while !stop.isSet {
                let svg = DOMNode.element(tag: "svg", preserveCase: true, namespace: DOMNode.svgNamespace)
                for i in 0..<8 {
                    let g = DOMNode.element(tag: "linearGradient", attributes: ["id": "g\(i)"], preserveCase: true)
                    g.setAttributePreservingCase(name: "gradientUnits", value: "userSpaceOnUse")
                    svg.appendChild(g)
                    if rng.below(2) == 0 { _ = CSSSelectorMatcher.matches(selectors[1], node: g) }
                }
                trees += 1
            }
            lock.lock(); shared.value.builderTrees = trees; lock.unlock()
        }

        Thread.sleep(forTimeInterval: seconds)
        stop.set()
        group.wait()
        var report = shared.value

        // ---- quiescent checks: the caches must agree with a cold recompute ----
        var elements: [DOMNode] = []
        var stack: [DOMNode] = [root]
        while let node = stack.popLast() {
            if node.nodeType == .element { elements.append(node) }
            stack.append(contentsOf: node.children.reversed())
            for child in node.children where child.parent !== node {
                report.failures.append("child's parent pointer does not point back")
            }
        }
        let warm = elements.map { node in selectors.map { CSSSelectorMatcher.matches($0, node: node) } }
        let warmLanguages = elements.map(\.language)
        DOMNode.bumpSelectorEpoch()
        let cold = elements.map { node in selectors.map { CSSSelectorMatcher.matches($0, node: node) } }
        if warm != cold { report.failures.append("cached matching differs from a cold recompute") }
        if warmLanguages != elements.map(\.language) { report.failures.append("cached language differs from a cold recompute") }
        for node in elements {
            let fromAttribute = node.attributes["class"].map { Set(DOMNode.splitASCIIWhitespace($0)) } ?? []
            if node.classList != fromAttribute { report.failures.append("classList stale after quiescence"); break }
            if node.idAttribute != node.attributes["id"] { report.failures.append("id cache stale after quiescence"); break }
        }
        // `querySelectorAll` agrees with per-element matching.
        for (i, text) in selectorTexts.enumerated() {
            let viaQuery = root.querySelectorAll(text).map(ObjectIdentifier.init)
            let viaMatch = elements.dropFirst().enumerated().filter { cold[$0.offset + 1][i] }.map { ObjectIdentifier($0.element) }
            if viaQuery != viaMatch { report.failures.append("querySelectorAll(\(text)) differs from matching") }
        }
        return report
    }

    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    final class UncheckedBox<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }
}

extension JeffJSTestRunner {
    /// Conformance group "DOMThreadSafety": a short concurrent run with the
    /// same end-state invariants as the stress test.
    mutating func testDOMThreadSafety() {
        let report = DOMThreadStress.run(seconds: 0.3, nodes: 2_000)
        assert(report.writerOps > 0 && report.readerPasses > 0 && report.queryPasses > 0,
               "DOMThreadSafety: every thread made progress (writer \(report.writerOps), match \(report.readerPasses), query \(report.queryPasses))")
        assert(report.failures.isEmpty, "DOMThreadSafety: \(report.failures.prefix(3).joined(separator: "; "))")

        // Single-threaded contract details.
        let div = DOMNode.element(tag: "DIV", attributes: ["id": "a", "class": "x y"], preserveCase: true)
        assert(div.lowercasedTagName == "div" && div.tagName == "DIV", "DOMThreadSafety: lowercased tag name is fixed at creation")
        assert(div.idAttribute == "a" && div.hasClass("y") && !div.hasClass("z"), "DOMThreadSafety: id / class caches from the factory")
        div.setAttribute(name: "ID", value: "b")
        div.attributes["class"] = "z"
        assert(div.idAttribute == "b" && div.hasClass("z") && !div.hasClass("x") && div.classNames == ["z"],
               "DOMThreadSafety: id / class caches follow setAttribute and direct edits")
        div.removeAttribute(name: "id")
        assert(div.idAttribute == nil, "DOMThreadSafety: removing id clears the id cache")
        let before = DOMNode.selectorEpoch
        div.setAttribute(name: "data-q", value: "1")
        assert(DOMNode.selectorEpoch != before, "DOMThreadSafety: attribute writes bump the selector epoch")
        let text = DOMNode.text("ab")
        text.appendTextData("cd")
        assert(text.textContent == "abcd", "DOMThreadSafety: appendTextData appends in place")
        let parent = DOMNode.element(tag: "p")
        let t1 = DOMNode.text("1"), t2 = DOMNode.text("2"), t3 = DOMNode.text("3")
        parent.appendChild(t1)
        parent.appendChild(t2)
        let replaced = parent.replaceChild(t1, with: [t3, .text("4")])
        assert(replaced === t1 && t1.parent == nil && t3.parent === parent
               && parent.children.compactMap(\.textContent) == ["3", "4", "2"],
               "DOMThreadSafety: replaceChild keeps order and parents")
        assert(parent.replaceChild(t1, with: [t2]) == nil && parent.children.count == 3,
               "DOMThreadSafety: replaceChild of a non-child is a no-op")
    }
}

final class DOMThreadSafetyTests: XCTestCase {

    func testConcurrentMutationAndMatching() {
        let seconds = ProcessInfo.processInfo.environment["DOM_STRESS_SECONDS"].flatMap(Double.init) ?? 5
        let report = DOMThreadStress.run(seconds: seconds)
        print(String(format: "[DOMSTRESS] %.1fs: writer ops=%d, match passes=%d, query passes=%d, detached trees=%d, failures=%d",
                     seconds, report.writerOps, report.readerPasses, report.queryPasses, report.builderTrees,
                     report.failures.count))
        XCTAssertGreaterThan(report.writerOps, 0)
        XCTAssertGreaterThan(report.readerPasses, 0)
        XCTAssertGreaterThan(report.queryPasses, 0)
        XCTAssertEqual(report.failures, [])
    }

    /// The DOM / selector conformance groups on their own (for TSan runs).
    func testDOMConformanceGroups() {
        let names: Set<String> = [
            "SelectorMatchingCache", "HTMLParsing", "DOMBridgeRung15", "DOMEvents", "ElementLangDir",
            "DOMScriptPrepare", "HyperlinkReflection", "DOMThreadSafety",
        ]
        var pass = 0
        var failures: [String] = []
        let done = expectation(description: "groups")
        let thread = Thread {
            for (name, fn) in JeffJSTestRunner.allTests where names.contains(name) {
                var runner = JeffJSTestRunner()
                fn(&runner)
                JeffJSTestRunner.detachSharedContext()
                pass += runner.passCount
                failures += runner.errors
                print("[group] \(name) pass=\(runner.passCount) fail=\(runner.failCount)")
            }
            done.fulfill()
        }
        thread.stackSize = 64 << 20
        thread.start()
        wait(for: [done], timeout: 1_800)
        print("[DOMGROUPS] pass=\(pass) fail=\(failures.count)")
        XCTAssertGreaterThan(pass, 0)
        XCTAssertEqual(failures, [])
    }
}
