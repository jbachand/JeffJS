// CSSScopingConformance.swift
// JeffJS — conformance group "CSSScoping" (CSS Scoping 1 §3.1-3.2: `:host`,
// `:host(<compound>)`, `:host-context(<compound>)`, `::slotted(<compound>)`,
// Shadow Parts `::part()`). Selectors of a shadow tree's style sheets are matched
// with `CSSMatchContext.shadowHost` = the tree's host: the host is featureless
// (only `:host`-family compounds match it), combinators leaving the tree's
// shadow root reach the host and stop there, and document-context matching never
// matches `:host`. `::slotted()` keeps its argument in the subject compound for
// the style resolver. These selectors used to parse as `.unsupported` (never
// matched), so every Lit component's `:host { display: block }` was lost.
// Swift-level: the matcher is exercised directly on DOM nodes.

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    mutating func testCSSScoping() {
        func sel(_ s: String) -> CSSComplexSelector? { CSSSelectorParser.parse(s).selectors.first }
        func check(_ name: String, _ ok: Bool) { assert(ok, "CSSScoping: \(name)") }

        // doc: <div class=outer><x-host class=h id=hh><span slot=a class=lit></span></x-host></div>
        let doc = DOMNode.document()
        let outer = DOMNode.element(tag: "div", attributes: ["class": "outer"])
        let host = DOMNode.element(tag: "x-host", attributes: ["class": "h", "id": "hh"])
        let light = DOMNode.element(tag: "span", attributes: ["slot": "a", "class": "lit"])
        doc.appendChild(outer); outer.appendChild(host); host.appendChild(light)
        guard let root = host.attachShadowRoot(mode: "open") else { check("attach", false); return }
        let wrap = DOMNode.element(tag: "div", attributes: ["class": "wrap"])
        let slot = DOMNode.element(tag: "slot", attributes: ["name": "a"])
        let inner = DOMNode.element(tag: "b", attributes: ["class": "in"])
        root.appendChild(wrap); wrap.appendChild(slot); wrap.appendChild(inner)
        let inTree = CSSMatchContext(scope: nil, shadowHost: host)

        check(":host matches the host in its tree's context", sel(":host").map { CSSSelectorMatcher.matches($0, node: host, context: inTree) } == true)
        check(":host never matches in document context", sel(":host").map { CSSSelectorMatcher.matches($0, node: host) } == false)
        check(":host does not match a shadow-tree element", sel(":host").map { CSSSelectorMatcher.matches($0, node: inner, context: inTree) } == false)
        check(":host(.h) / :host(#hh) match, :host(.nope) does not",
              sel(":host(.h)").map { CSSSelectorMatcher.matches($0, node: host, context: inTree) } == true
              && sel(":host(#hh)").map { CSSSelectorMatcher.matches($0, node: host, context: inTree) } == true
              && sel(":host(.nope)").map { CSSSelectorMatcher.matches($0, node: host, context: inTree) } == false)
        check("the host is featureless: x-host / .h do not match it in its tree's context",
              sel("x-host").map { CSSSelectorMatcher.matches($0, node: host, context: inTree) } == false
              && sel(".h").map { CSSSelectorMatcher.matches($0, node: host, context: inTree) } == false)
        check(":host-context(.outer) matches through the host's ancestors",
              sel(":host-context(.outer)").map { CSSSelectorMatcher.matches($0, node: host, context: inTree) } == true
              && sel(":host-context(.zzz)").map { CSSSelectorMatcher.matches($0, node: host, context: inTree) } == false)
        check(":host > .wrap and :host .in reach the host from inside",
              sel(":host > .wrap").map { CSSSelectorMatcher.matches($0, node: wrap, context: inTree) } == true
              && sel(":host .in").map { CSSSelectorMatcher.matches($0, node: inner, context: inTree) } == true
              && sel(":host(.nope) .in").map { CSSSelectorMatcher.matches($0, node: inner, context: inTree) } == false)
        check("combinators stop at the host: .outer .in does not match inside the tree",
              sel(".outer .in").map { CSSSelectorMatcher.matches($0, node: inner, context: inTree) } == false
              && sel(".outer .in").map { CSSSelectorMatcher.matches($0, node: inner) } == false
              && sel(".wrap .in").map { CSSSelectorMatcher.matches($0, node: inner, context: inTree) } == true)
        let slotted = sel("slot[name=a]::slotted(.lit)")
        check("::slotted() is a pseudo-element keeping its argument; element matching ignores it",
              slotted?.pseudoElement == .slotted
              && slotted.map { CSSSelectorMatcher.matches($0, node: slot, context: inTree) } == true
              && (slotted?.parts.last?.selector.components.contains { if case .slottedArgument = $0 { return true }; return false } ?? false))
        check("::part(label) parses as the part pseudo-element",
              sel("x-host::part(label)")?.pseudoElement == .part)
        check("specificity: :host(.h) = (0,2,0), ::slotted(.lit) = (0,1,1)",
              sel(":host(.h)").map { CSSSpecificity.calculate(for: $0) } == CSSSpecificity(inline: 0, ids: 0, classes: 2, elements: 0)
              && sel("::slotted(.lit)").map { CSSSpecificity.calculate(for: $0) } == CSSSpecificity(inline: 0, ids: 0, classes: 1, elements: 1))
        check("CSS.supports selector(): :host, ::slotted() supported",
              CSSSelector.isSupported(":host(.h)") && CSSSelector.isSupported("::slotted(span)") && CSSSelector.isSupported(":host-context(.a)"))
        check("closest() from inside a shadow tree stops at the shadow root",
              inner.closestMatching(".outer") == nil && inner.closestMatching(".wrap") === wrap)
    }
}
