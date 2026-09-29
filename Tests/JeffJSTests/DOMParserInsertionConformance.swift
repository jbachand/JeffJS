// DOMParserInsertionConformance.swift
// JeffJS — conformance group "DOMParserInsertion" (DOM §4.2.3 "insert" queues a
// childList record per inserted node, HTML §13.2.6.1 the parser inserts nodes
// one by one).
//
// (1) The host parses the whole document before it runs the parser-inserted
// scripts; an observer an early script registers got no records for the nodes
// "parsed" after it (WebKit's streaming parser inserts them after the script
// ran). JeffJSDOMBridge.noteParserInsertions(upTo:) replays those insertions to
// the live observers, one record per node, delivered before the next script;
// hosts get it for free through setCurrentScriptNode / setReadyState.

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    mutating func testDOMParserInsertion() {
        var outcomes: [(Bool, String)] = []
        func onMain(_ body: @escaping @MainActor () -> Void) {
            if Thread.isMainThread { MainActor.assumeIsolated { body() } } else { DispatchQueue.main.sync { MainActor.assumeIsolated { body() } } }
        }
        @MainActor func check(_ e: JeffJSEnvironment, _ js: String, _ name: String) {
            switch e.eval(js, filename: "<parser-insertion>") {
            case .success(let v): outcomes.append((v == "true", "DOMParserInsertion: \(name) -> \(v ?? "undefined")"))
            case .exception(let m): outcomes.append((false, "DOMParserInsertion: \(name) threw \(m)"))
            }
        }
        onMain {
            // ---- parser insertions reach MutationObserver ----
            let e = JeffJSEnvironment()
            guard let dom = e.domBridge else { outcomes.append((false, "DOMParserInsertion: no DOM bridge")); return }
            let body = e.document.children.first { $0.tagName == "html" }?.children.first { $0.tagName == "body" }
            guard let body else { outcomes.append((false, "DOMParserInsertion: no body")); return }
            // "Parser output": <script id=s0>…</script><div id=a><span id=b></span><i id=g></i></div>
            //                  <script id=s1></script><p id=c></p>
            let s0 = DOMNode.element(tag: "script", attributes: ["id": "s0"]); s0.appendChild(DOMNode.text("0"))
            let a = DOMNode.element(tag: "div", attributes: ["id": "a"])
            a.appendChild(DOMNode.element(tag: "span", attributes: ["id": "b"]))
            a.appendChild(DOMNode.element(tag: "i", attributes: ["id": "g"]))
            let s1 = DOMNode.element(tag: "script", attributes: ["id": "s1"])
            let c = DOMNode.element(tag: "p", attributes: ["id": "c"])
            for n in [s0, a, s1, c] { body.appendChild(n) }

            dom.noteParserInsertions(upTo: s0)          // before s0 runs: no observer yet
            // s0: registers the observer; removes #g (never "inserted" any more).
            _ = e.eval("""
                var PI = [], PIobs = new MutationObserver(function (rs) {
                  rs.forEach(function (r) { r.addedNodes.forEach ? 0 : 0;
                    for (var i = 0; i < r.addedNodes.length; i++) { var n = r.addedNodes[i];
                      if (n.nodeType === 1) PI.push(n.id + '@' + (r.target.id || r.target.nodeName) + ':' + (r.previousSibling ? (r.previousSibling.id || r.previousSibling.nodeName) : '-') + ':' + (r.nextSibling ? 'n' : '-')); } }); });
                PIobs.observe(document.documentElement, { childList: true, subtree: true });
                document.getElementById('g').remove(); PI.length = 0;
                """, filename: "<s0>")
            dom.noteParserInsertions(upTo: s1)          // before s1 runs: div, span, s1 are inserted
            check(e, "PI.join() === 'a@BODY:s0:-,b@a:-:-,s1@BODY:a:-'", "records for the nodes after the running script, delivered before the next one")
            _ = e.eval("PI.length = 0; document.body.appendChild(document.createElement('em'));", filename: "<s1>")
            dom.noteParserInsertions(upTo: nil)         // end of parsing: <p id=c>
            check(e, "PI.join() === '@BODY:c:-,c@BODY:s1:-'", "the rest of the document at the end of parsing, after the page's own insertion")
            dom.noteParserInsertions(upTo: nil)
            check(e, "PI.length === 2", "idempotent after parsing finished")
            _ = e.eval("PIobs.disconnect();", filename: "<cleanup>")

            // ---- the host's hooks: currentScript and readyState drive it ----
            let e2 = JeffJSEnvironment()
            guard let dom2 = e2.domBridge,
                  let body2 = e2.document.children.first(where: { $0.tagName == "html" })?.children.first(where: { $0.tagName == "body" }) else {
                outcomes.append((false, "DOMParserInsertion: no second environment")); return
            }
            let t0 = DOMNode.element(tag: "script", attributes: ["id": "t0"])
            let x = DOMNode.element(tag: "div", attributes: ["id": "x"])
            let t1 = DOMNode.element(tag: "script", attributes: ["id": "t1"])
            let y = DOMNode.element(tag: "p", attributes: ["id": "y"])
            for n in [t0, x, t1, y] { body2.appendChild(n) }
            dom2.setCurrentScriptNode(t0)
            _ = e2.eval("var Q = []; new MutationObserver(function (rs) { rs.forEach(function (r) { for (var i = 0; i < r.addedNodes.length; i++) if (r.addedNodes[i].id) Q.push(r.addedNodes[i].id); }); }).observe(document.body, { childList: true });", filename: "<t0>")
            dom2.setCurrentScriptNode(nil)
            let unrelated = DOMNode.element(tag: "script", attributes: ["id": "dyn"])
            dom2.setCurrentScriptNode(unrelated)     // not a parser-inserted script: ignored
            dom2.setCurrentScriptNode(nil)
            check(e2, "Q.join() === ''", "a script the parser did not insert does not move the parser")
            dom2.setCurrentScriptNode(t1)
            check(e2, "Q.join() === 'x,t1'", "setCurrentScriptNode(parser script) replays the insertions before it")
            if let doc = dom2.documentJSValue { dom2.setReadyState("interactive", on: doc, ctx: e2.context) }
            _ = e2.eval("0", filename: "<drain>")
            check(e2, "Q.join() === 'x,t1,y'", "setReadyState('interactive') replays the rest")

        }
        for (ok, message) in outcomes { assert(ok, message) }
    }
}
