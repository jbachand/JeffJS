import XCTest
@testable import JeffJS

/// Real-world selector-matching benchmark: the stylesheets and DOM of the
/// React Natively offline fixtures (`/tmp/fixtures/apple`, `/tmp/fixtures/wiki`,
/// written by the app's `Scripts/fixture_server.py` snapshots). Skipped when the
/// fixtures are not on disk.
///
/// The selectors are pulled out of the sheets with a small block scanner (the
/// real CSS parser lives in the app), candidate rules come from an index like
/// the app's `StyleResolver` (tag > class > id > universal on the rightmost
/// compound), and every element of the document is matched the way the
/// resolver does it (a pseudo-element selector is tested without its
/// pseudo-element). Only API that existed before the selector-cache work is
/// used, so the same file measures both sides.
///
///     swift test -c release --filter SelectorFixtureBenchTests
final class SelectorFixtureBenchTests: XCTestCase {

    private static let fixtureRoot = "/tmp/fixtures"

    /// Selector preludes of every style rule, including those nested in
    /// `@media` / `@supports` / `@layer` / `@container` / `@document` blocks.
    static func selectorPreludes(in css: String) -> [String] {
        var out: [String] = []
        let chars = Array(css.unicodeScalars)
        var i = 0
        var prelude = String.UnicodeScalarView()
        var skipDepth = 0          // > 0 while inside a block we do not descend into
        var ruleDepth = 0          // > 0 while inside a style rule's declarations
        while i < chars.count {
            let c = chars[i]
            // comments
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            // strings
            if c == "\"" || c == "'" {
                let quote = c
                if skipDepth == 0 && ruleDepth == 0 { prelude.append(c) }
                i += 1
                while i < chars.count, chars[i] != quote {
                    if chars[i] == "\\", i + 1 < chars.count {
                        if skipDepth == 0 && ruleDepth == 0 { prelude.append(chars[i]); prelude.append(chars[i + 1]) }
                        i += 2
                        continue
                    }
                    if skipDepth == 0 && ruleDepth == 0 { prelude.append(chars[i]) }
                    i += 1
                }
                if skipDepth == 0 && ruleDepth == 0, i < chars.count { prelude.append(chars[i]) }
                i += 1
                continue
            }
            if skipDepth > 0 || ruleDepth > 0 {
                if c == "{" { if skipDepth > 0 { skipDepth += 1 } else { ruleDepth += 1 } }
                if c == "}" { if skipDepth > 0 { skipDepth -= 1 } else { ruleDepth -= 1 } }
                i += 1
                continue
            }
            switch c {
            case "{":
                let text = String(prelude).trimmingCharacters(in: .whitespacesAndNewlines)
                prelude = String.UnicodeScalarView()
                if text.hasPrefix("@") {
                    let lower = text.lowercased()
                    if lower.hasPrefix("@media") || lower.hasPrefix("@supports") || lower.hasPrefix("@layer")
                        || lower.hasPrefix("@container") || lower.hasPrefix("@document") || lower.hasPrefix("@scope") {
                        // descend: the block's contents are rules
                    } else {
                        skipDepth = 1
                    }
                } else {
                    if !text.isEmpty { out.append(text) }
                    ruleDepth = 1
                }
            case "}":
                prelude = String.UnicodeScalarView()
            case ";":
                prelude = String.UnicodeScalarView()   // @import / @charset / stray
            default:
                prelude.append(c)
            }
            i += 1
        }
        return out
    }

    struct Rule {
        let selectors: [CSSComplexSelector]
    }

    /// The app's `StyleResolver.subjectIndexKeys`, reduced to what matters here.
    enum Key { case tags(Set<String>), classes(Set<String>), ids(Set<String>), universal }
    static func indexKey(_ list: CSSSelectorList) -> Key {
        var tags = Set<String>(), classes = Set<String>(), ids = Set<String>()
        var unindexable = false
        for complex in list.selectors {
            guard let subject = complex.parts.last else { continue }
            var tag: String?, cls: [String] = [], id: String?
            for component in subject.selector.components {
                switch component {
                case .element(let t): tag = t.lowercased()
                case .className(let c): cls.append(c)
                case .id(let i): id = i
                default: break
                }
            }
            if let tag { tags.insert(tag) } else if let c = cls.first { classes.insert(c) }
            else if let id { ids.insert(id) } else { unindexable = true }
        }
        if unindexable { return .universal }
        if !tags.isEmpty { return classes.isEmpty && ids.isEmpty ? .tags(tags) : .universal }
        if !classes.isEmpty { return ids.isEmpty ? .classes(classes) : .universal }
        if !ids.isEmpty { return .ids(ids) }
        return .universal
    }

    struct Index {
        var byTag: [String: [Rule]] = [:]
        var byClass: [String: [Rule]] = [:]
        var byID: [String: [Rule]] = [:]
        var universal: [Rule] = []

        init(_ lists: [CSSSelectorList]) {
            for list in lists {
                let rule = Rule(selectors: list.selectors)
                switch SelectorFixtureBenchTests.indexKey(list) {
                case .tags(let t): for x in t { byTag[x, default: []].append(rule) }
                case .classes(let c): for x in c { byClass[x, default: []].append(rule) }
                case .ids(let i): for x in i { byID[x, default: []].append(rule) }
                case .universal: universal.append(rule)
                }
            }
        }

        func candidates(for node: DOMNode, into out: inout [Rule]) {
            out.removeAll(keepingCapacity: true)
            if let r = byTag[node.tagName ?? ""] { out.append(contentsOf: r) }
            for cls in node.classList { if let r = byClass[cls] { out.append(contentsOf: r) } }
            if let id = node.idAttribute, let r = byID[id] { out.append(contentsOf: r) }
            out.append(contentsOf: universal)
        }
    }

    static func loadSheets(_ fixture: String) -> [CSSSelectorList] {
        let dir = "\(fixtureRoot)/\(fixture)/r"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var lists: [CSSSelectorList] = []
        for file in files.sorted() where file.hasSuffix(".css") {
            guard let data = FileManager.default.contents(atPath: "\(dir)/\(file)"),
                  let css = String(data: data, encoding: .utf8) else { continue }
            for prelude in selectorPreludes(in: css) {
                let list = CSSSelectorParser.parse(prelude)
                if !list.selectors.isEmpty { lists.append(list) }
            }
        }
        return lists
    }

    static func loadDocument(_ fixture: String) -> DOMNode? {
        guard let data = FileManager.default.contents(atPath: "\(fixtureRoot)/\(fixture)/index.html"),
              let html = String(data: data, encoding: .utf8) else { return nil }
        return HTMLParser.parse(html)
    }

    static func elements(of root: DOMNode) -> [DOMNode] {
        var out: [DOMNode] = []
        func walk(_ n: DOMNode) {
            for c in n.children {
                if c.nodeType == .element { out.append(c) }
                walk(c)
            }
        }
        walk(root)
        return out
    }

    /// One full match of every element against its candidate rules; returns
    /// (matched selectors, selector tests).
    static func fullMatch(_ elements: [DOMNode], _ index: Index) -> (Int, Int) {
        var matched = 0, tests = 0
        var candidates: [Rule] = []
        candidates.reserveCapacity(1024)
        CSSSelectorMatcher.beginMatchPass()
        defer { CSSSelectorMatcher.endMatchPass() }
        for el in elements {
            index.candidates(for: el, into: &candidates)
            for rule in candidates {
                for sel in rule.selectors {
                    tests += 1
                    let ok: Bool
                    if sel.pseudoElement != nil {
                        ok = CSSSelectorMatcher.matches(CSSComplexSelector(parts: sel.parts, pseudoElement: nil), node: el)
                    } else {
                        ok = CSSSelectorMatcher.matches(sel, node: el)
                    }
                    if ok { matched += 1 }
                }
            }
        }
        return (matched, tests)
    }

    private func run(css: String, dom: String, label: String) {
        let lists = Self.loadSheets(css)
        guard !lists.isEmpty, let root = Self.loadDocument(dom) else {
            print("[FXBENCH] \(label): fixtures missing, skipped")
            return
        }
        let elements = Self.elements(of: root)
        let index = Index(lists)
        let selectorCount = lists.reduce(0) { $0 + $1.selectors.count }
        // First pass: cold (per-element caches empty), then best of 5 warm passes.
        var t0 = Date()
        let (matched, tests) = Self.fullMatch(elements, index)
        let cold = Date().timeIntervalSince(t0)
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<5 {
            t0 = Date()
            let (m, _) = Self.fullMatch(elements, index)
            best = min(best, Date().timeIntervalSince(t0))
            XCTAssertEqual(m, matched)
        }
        // A pass after a DOM mutation (one attribute change invalidates the
        // per-element caches, whatever their scheme).
        elements.first?.setAttribute(name: "data-bench", value: "1")
        t0 = Date()
        let (m2, _) = Self.fullMatch(elements, index)
        let afterMutation = Date().timeIntervalSince(t0)
        XCTAssertEqual(m2, matched)
        print(String(format: "[FXBENCH] %@: elements=%d rules=%d selectors=%d tests=%d matched=%d cold=%.1fms warm=%.1fms afterMutation=%.1fms",
                     label, elements.count, lists.count, selectorCount, tests, matched,
                     cold * 1000, best * 1000, afterMutation * 1000))

        // The `:lang()` rules alone, through the same index (what the cascade
        // pays for them), and the bare pseudo-class: every element against
        // every distinct `:lang(...)` argument list of the sheets.
        let langLists = lists.filter { list in list.selectors.contains { "\($0)".contains("pseudoLang") } }
        if !langLists.isEmpty {
            let langIndex = Index(langLists)
            var bestIndexed = Double.greatestFiniteMagnitude
            var langMatched = 0
            for _ in 0..<5 {
                t0 = Date()
                langMatched = Self.fullMatch(elements, langIndex).0
                bestIndexed = min(bestIndexed, Date().timeIntervalSince(t0))
            }
            var arguments = Set<String>()
            for list in langLists {
                let text = "\(list)"
                var rest = text[...]
                while let r = rest.range(of: "pseudoLang([") {
                    let tail = rest[r.upperBound...]
                    guard let close = tail.range(of: "])") else { break }
                    arguments.insert(tail[..<close.lowerBound].replacingOccurrences(of: "\"", with: ""))
                    rest = tail[close.upperBound...]
                }
            }
            let bare = arguments.sorted().map { CSSSelectorParser.parse(":lang(\($0))").selectors[0] }
            var bestBare = Double.greatestFiniteMagnitude
            var bareMatched = 0
            for _ in 0..<5 {
                bareMatched = 0
                t0 = Date()
                for el in elements { for sel in bare where CSSSelectorMatcher.matches(sel, node: el) { bareMatched += 1 } }
                bestBare = min(bestBare, Date().timeIntervalSince(t0))
            }
            let calls = elements.count * bare.count
            print(String(format: "[FXBENCH] %@: :lang rules=%d indexed matched=%d best=%.2fms | bare :lang args=%d calls=%d matched=%d best=%.2fms (%.0f ns/call)",
                         label, langLists.count, langMatched, bestIndexed * 1000, bare.count, calls, bareMatched,
                         bestBare * 1000, bestBare * 1e9 / Double(max(calls, 1))))
        }
    }

    func testAppleSheetsOnAppleDOM() { run(css: "apple", dom: "apple", label: "apple css x apple dom") }
    func testWikiSheetsOnWikiDOM() { run(css: "wiki", dom: "wiki", label: "wiki css x wiki dom") }
    func testAppleSheetsOnWikiDOM() { run(css: "apple", dom: "wiki", label: "apple css x wiki dom") }
}
