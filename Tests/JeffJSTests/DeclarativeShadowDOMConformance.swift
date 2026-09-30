// DeclarativeShadowDOMConformance.swift
// JeffJS — conformance group "DeclarativeShadowDOM" (HTML §13.2.6.4.4 `<template
// shadowrootmode>`): the document parser attaches a declarative shadow root to the
// template's parent and puts the template's contents in it (the template is not
// inserted); an invalid host, a second root, fragment parsing (innerHTML) and
// DOMParser leave an ordinary template. Swift-level (HTMLParser directly).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    mutating func testDeclarativeShadowDOM() {
        func check(_ name: String, _ ok: Bool) { assert(ok, "DeclarativeShadowDOM: \(name)") }
        func find(_ n: DOMNode, _ id: String) -> DOMNode? {
            var stack = [n]
            while let x = stack.popLast() {
                if x.idAttribute == id { return x }
                stack.append(contentsOf: x.children)
                if let r = x.shadowRoot { stack.append(r) }
            }
            return nil
        }
        let doc = HTMLParser.parse("""
            <!doctype html><body>
            <div id=h1><template shadowrootmode=open shadowrootdelegatesfocus><b id=in1>x</b><slot></slot></template><i id=l1>light</i></div>
            <x-el id=h2><template shadowrootmode="closed" shadowrootclonable><p id=in2></p></template></x-el>
            <img id=h3><template shadowrootmode=open><u id=in3></u></template>
            <div id=h4><template shadowrootmode=bogus><s id=in4></s></template></div>
            <div id=h5><template shadowrootmode=open><em id=in5a></em></template><template shadowrootmode=open><em id=in5b></em></template></div>
            </body>
            """)
        let h1 = find(doc, "h1"), in1 = find(doc, "in1")
        check("open root on a div, contents moved in, template gone",
              h1?.shadowRoot?.shadowRootInfo?.mode == "open" && in1?.parent === h1?.shadowRoot
              && h1?.children.contains(where: { $0.tagName == "template" }) == false
              && h1?.shadowRoot?.shadowRootInfo?.delegatesFocus == true && h1?.shadowRoot?.shadowRootInfo?.declarative == true)
        check("the light child is slotted into the declarative root",
              find(doc, "l1")?.assignedSlotNode?.tagName == "slot")
        let h2 = find(doc, "h2")
        check("closed root on a custom element, clonable",
              h2?.shadowRoot?.shadowRootInfo?.mode == "closed" && h2?.shadowRoot?.shadowRootInfo?.clonable == true
              && find(doc, "in2")?.parent === h2?.shadowRoot)
        check("a void element never hosts: the template after <img> attaches to its parent (body), not the img",
              find(doc, "h3")?.shadowRoot == nil)
        check("an unknown mode keeps an ordinary template", find(doc, "h4")?.shadowRoot == nil
              && find(doc, "h4")?.children.contains(where: { $0.tagName == "template" }) == true)
        let h5 = find(doc, "h5")
        check("a second declarative template stays a template",
              h5?.shadowRoot != nil && find(doc, "in5a")?.parent === h5?.shadowRoot
              && h5?.children.contains(where: { $0.tagName == "template" }) == true)
        let frag = HTMLParser.parseFragment("<div id=f><template shadowrootmode=open><b></b></template></div>", context: "body")
        check("fragment parsing (innerHTML) never attaches one",
              frag.first?.shadowRoot == nil && frag.first?.children.first?.tagName == "template")
        let viaDOMParser = HTMLParser.parse("<div id=d><template shadowrootmode=open><b></b></template></div>",
                                            allowDeclarativeShadowRoots: false)
        check("DOMParser (allowDeclarativeShadowRoots: false) never attaches one",
              find(viaDOMParser, "d")?.shadowRoot == nil)
    }
}
