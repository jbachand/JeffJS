// DOMNodeInterfaceConformance.swift
// JeffJS — conformance group "DOMNodeInterface" (DOM §4.4 Interface Node:
// hasChildNodes(), isSameNode(), isEqualNode() with the "equals" algorithm,
// getRootNode(), normalize()). On every node wrapper they were the app
// polyfill's stubs (normalize() did nothing, isEqualNode missing / identity on
// the JSC bridge, getRootNode walked parentNode); the document object had only
// hasChildNodes / isSameNode. Now native in JeffJSDOMBridge
// (installNodeInterfaceMethods): normalize() merges adjacent Text nodes and
// removes empty ones, with a characterData record per merge and a childList
// record per removal, in tree order.

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let domNodeInterfaceCases: [(String, String)] = [
        ("hasChildNodes on elements, text, fragments and the document",
         #"(function(){ var d = document.createElement('div'), t = document.createTextNode('x'), f = document.createDocumentFragment(); var before = d.hasChildNodes(); d.appendChild(t); return !before && d.hasChildNodes() && !t.hasChildNodes() && !f.hasChildNodes() && document.hasChildNodes() && d.hasChildNodes.length === 0; })()"#),
        ("isSameNode is identity; null and non-nodes are false",
         #"(function(){ var d = document.createElement('div'); return d.isSameNode(d) && !d.isSameNode(d.cloneNode(true)) && !d.isSameNode(null) && !d.isSameNode({}) && document.isSameNode(document) && !document.isSameNode(document.body) && d.isSameNode.length === 1; })()"#),
        ("isEqualNode: attribute order does not matter, values and children do",
         #"(function(){ function el(attrs, text){ var e = document.createElement('p'); attrs.forEach(function(a){ e.setAttribute(a[0], a[1]); }); if (text !== undefined) e.appendChild(document.createTextNode(text)); return e; } var a = el([['x','1'],['y','2']], 't'), b = el([['y','2'],['x','1']], 't'); return a.isEqualNode(b) && b.isEqualNode(a) && !a.isEqualNode(el([['x','1'],['y','3']], 't')) && !a.isEqualNode(el([['x','1']], 't')) && !a.isEqualNode(el([['x','1'],['y','2']], 'u')) && !a.isEqualNode(el([['x','1'],['y','2']])) && a.isEqualNode(a.cloneNode(true)) && !a.isEqualNode(null) && a.isEqualNode.length === 1; })()"#),
        ("isEqualNode: node type, local name, namespace, text / comment data, deep structure",
         #"(function(){ var t = function(s){ return document.createTextNode(s); }; var svg = 'http://www.w3.org/2000/svg'; var x = document.createElement('div'); x.innerHTML = '<ul><li>a</li><li>b<i>c</i></li></ul>'; var y = document.createElement('div'); y.innerHTML = '<ul><li>a</li><li>b<i>c</i></li></ul>'; var z = document.createElement('div'); z.innerHTML = '<ul><li>a</li><li>b<i>C</i></li></ul>'; return t('q').isEqualNode(t('q')) && !t('q').isEqualNode(t('r')) && !document.createComment('q').isEqualNode(t('q')) && document.createComment('q').isEqualNode(document.createComment('q')) && !document.createElement('div').isEqualNode(document.createElement('span')) && !document.createElementNS(svg, 'g').isEqualNode(document.createElement('g')) && document.createElementNS(svg, 'g').isEqualNode(document.createElementNS(svg, 'g')) && x.isEqualNode(y) && !x.isEqualNode(z); })()"#),
        ("isEqualNode on fragments and the document",
         #"(function(){ var f = document.createDocumentFragment(), g = document.createDocumentFragment(); f.appendChild(document.createElement('b')); g.appendChild(document.createElement('b')); var h = document.createDocumentFragment(); return f.isEqualNode(g) && !f.isEqualNode(h) && document.isEqualNode(document) && !document.isEqualNode(document.body) && !f.isEqualNode(document.createElement('b')); })()"#),
        ("getRootNode: the topmost inclusive ancestor; the document for connected nodes",
         #"(function(){ var d = document.createElement('div'), s = document.createElement('span'), t = document.createTextNode('x'); d.appendChild(s); s.appendChild(t); var f = document.createDocumentFragment(); var c = document.createElement('i'); f.appendChild(c); return t.getRootNode() === d && d.getRootNode() === d && c.getRootNode() === f && document.body.getRootNode() === document && document.body.getRootNode({ composed: true }) === document && document.getRootNode() === document && d.getRootNode.length === 0; })()"#),
        ("normalize merges adjacent Text nodes and removes empty ones, in the whole subtree",
         #"(function(){ var n = document.createElement('div'); ['', 'a', '', 'b'].forEach(function(s){ n.appendChild(document.createTextNode(s)); }); var sp = document.createElement('span'); sp.appendChild(document.createTextNode('c')); sp.appendChild(document.createTextNode('d')); n.appendChild(sp); n.appendChild(document.createTextNode('e')); n.appendChild(document.createTextNode('')); var first = n.childNodes[1]; n.normalize(); return n.childNodes.length === 3 && n.firstChild === first && first.data === 'ab' && sp.childNodes.length === 1 && sp.firstChild.data === 'cd' && n.lastChild.data === 'e' && n.textContent === 'abcde' && n.normalize.length === 0; })()"#),
        ("normalize queues its records in WebKit's order: each following Text node is appended (characterData) then removed (childList); an empty one is only removed",
         #"(function(){ var n = document.createElement('div'); ['', 'a', '', 'b'].forEach(function(s){ n.appendChild(document.createTextNode(s)); }); var sp = document.createElement('span'); sp.appendChild(document.createTextNode('c')); sp.appendChild(document.createTextNode('d')); n.appendChild(sp); var mo = new MutationObserver(function(){}); mo.observe(n, { childList: true, characterData: true, characterDataOldValue: true, subtree: true }); n.normalize(); var r = mo.takeRecords(); mo.disconnect(); return r.map(function(x){ return x.type === 'characterData' ? 'cd:' + x.oldValue : 'cl:' + x.removedNodes.length + (x.target === n ? 'n' : 's'); }).join(' ') === 'cl:1n cl:1n cd:a cl:1n cd:c cl:1s'; })()"#),
        ("normalize with nothing to do queues nothing; document.normalize works",
         #"(function(){ var n = document.createElement('div'); n.appendChild(document.createTextNode('a')); n.appendChild(document.createElement('b')); n.appendChild(document.createTextNode('c')); var mo = new MutationObserver(function(){}); mo.observe(n, { childList: true, characterData: true, subtree: true }); n.normalize(); var r = mo.takeRecords(); mo.disconnect(); document.body.appendChild(document.createTextNode('')); document.normalize(); return r.length === 0 && n.childNodes.length === 3 && Array.prototype.every.call(document.body.childNodes, function(c){ return c.nodeType !== 3 || c.data !== ''; }); })()"#),
    ]

    mutating func testDOMNodeInterface() {
        var outcomes: [(Bool, String)] = []
        func onMain(_ body: @escaping @JeffJSHostActor () -> Void) {
            if Thread.isMainThread { JeffJSHostActor.assumeIsolated { body() } } else { DispatchQueue.main.sync { JeffJSHostActor.assumeIsolated { body() } } }
        }
        onMain {
            let e = JeffJSEnvironment()
            for (name, js) in JeffJSTestRunner.domNodeInterfaceCases {
                switch e.eval(js, filename: "<dom-node-interface>") {
                case .success(let v): outcomes.append((v == "true", "DOMNodeInterface: \(name) -> \(v ?? "undefined")"))
                case .exception(let m): outcomes.append((false, "DOMNodeInterface: \(name) threw \(m)"))
                }
            }
        }
        for (ok, message) in outcomes { assert(ok, message) }
    }
}
