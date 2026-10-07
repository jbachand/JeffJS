// DOMCharacterDataConformance.swift
// JeffJS — conformance group "DOMCharacterData" (DOM §4.10 interface
// CharacterData, §4.11 interface Text, §4.3.3 queue a mutation record): `data`
// / `length` / `substringData` / `appendData` / `insertData` / `deleteData` /
// `replaceData` on Text and Comment nodes, `splitText` / `wholeText`, UTF-16
// offsets, IndexSizeError, and the characterData records (old value, order,
// subtree) every change queues. The engine had only a `data` accessor on the
// shared element prototype (no length, no methods), and the host's interface
// prototypes shadowed even that (rung 15 js09 / m11).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let domCharacterDataCases: [(String, String)] = [
        ("data and length on Text and Comment; length counts UTF-16 code units",
         #"(function(){ var t = document.createTextNode('ab\u{1F600}'), c = document.createComment('xyz'); return t.data === 'ab\u{1F600}' && t.length === 4 && c.data === 'xyz' && c.length === 3 && document.createElement('div').length === undefined && !('length' in document.createElement('div')); })()"#),
        ("data setter: null is the empty string, other values are stringified",
         #"(function(){ var t = document.createTextNode('a'); t.data = null; var a = t.data; t.data = 12; var b = t.data; t.data = undefined; return a === '' && b === '12' && t.data === 'undefined' && t.nodeValue === 'undefined' && t.textContent === 'undefined'; })()"#),
        ("substringData clamps the count and throws IndexSizeError past the end",
         #"(function(){ var t = document.createTextNode('hello'); var e = ''; try { t.substringData(6, 1); } catch (x) { e = x.name; } return t.substringData(1, 3) === 'ell' && t.substringData(2, 100) === 'llo' && t.substringData(5, 1) === '' && t.substringData(0, 4294967296) === '' && e === 'IndexSizeError'; })()"#),
        ("appendData / insertData / deleteData / replaceData",
         #"(function(){ var t = document.createTextNode('abc'); t.appendData('de'); var a = t.data; t.insertData(1, 'X'); var b = t.data; t.deleteData(2, 2); var c = t.data; t.replaceData(0, 2, 'QQQ'); var d = t.data; t.replaceData(1, 99, ''); return a === 'abcde' && b === 'aXbcde' && c === 'aXde' && d === 'QQQde' && t.data === 'Q'; })()"#),
        ("offsets are unsigned long: -1 wraps and throws IndexSizeError; missing arguments are a TypeError",
         #"(function(){ var t = document.createTextNode('abc'), n = []; try { t.insertData(-1, 'x'); } catch (x) { n.push(x.name); } try { t.deleteData(4, 1); } catch (x) { n.push(x.name); } try { t.appendData(); } catch (x) { n.push(x.name); } try { t.replaceData(0, 1); } catch (x) { n.push(x.name); } t.deleteData(1, -1); return n.join() === 'IndexSizeError,IndexSizeError,TypeError,TypeError' && t.data === 'a'; })()"#),
        ("every change queues one characterData record with the old value, in order",
         #"(function(){ var d = document.createElement('div'), t = document.createTextNode('a'); d.appendChild(t); var mo = new MutationObserver(function(){}); mo.observe(d, { characterData: true, characterDataOldValue: true, subtree: true }); t.data = 'b'; t.nodeValue = 'c'; t.textContent = 'd'; t.appendData('e'); t.insertData(0, 'f'); t.deleteData(0, 1); t.replaceData(0, 1, 'g'); var r = mo.takeRecords(); mo.disconnect(); return r.map(function(x){ return x.type.charAt(0) + x.oldValue + (x.target === t ? '' : '!'); }).join(' ') === 'ca cb cc cd cde cfde cde' && t.data === 'ge'; })()"#),
        ("characterData records: no oldValue unless asked; not without subtree for a child; comments too",
         #"(function(){ var d = document.createElement('div'), t = document.createTextNode('a'), c = document.createComment('x'); d.appendChild(t); d.appendChild(c); var m1 = new MutationObserver(function(){}), m2 = new MutationObserver(function(){}), m3 = new MutationObserver(function(){}); m1.observe(d, { characterData: true, subtree: true }); m2.observe(d, { characterData: true }); m3.observe(t, { characterData: true }); t.data = 'b'; c.appendData('y'); var r1 = m1.takeRecords(), r2 = m2.takeRecords(), r3 = m3.takeRecords(); return r1.length === 2 && r1[0].oldValue === null && r1[1].target === c && r2.length === 0 && r3.length === 1 && r3[0].target === t; })()"#),
        ("a characterData record is delivered in a microtask with the attribute records in order",
         #"(function(){ var b = document.createElement('div'); b.appendChild(document.createTextNode('a')); var o = []; var mo = new MutationObserver(function(r){ for (var k = 0; k < r.length; k++) o.push(r[k].type.charAt(0) + (r[k].oldValue === null ? 'N' : r[k].oldValue)); }); mo.observe(b, { attributes: true, attributeOldValue: true, characterData: true, characterDataOldValue: true, subtree: true }); b.setAttribute('data-a', '1'); b.setAttribute('data-a', '2'); b.removeAttribute('data-a'); b.firstChild.data = 'b'; b.firstChild.data = 'c'; var r = mo.takeRecords(); mo.disconnect(); return r.length === 5 && r.map(function(x){ return x.type.charAt(0) + (x.oldValue === null ? 'N' : x.oldValue); }).join('_') === 'aN_a1_a2_ca_cb'; })()"#),
        ("splitText: the new node gets the tail and is inserted after; detached nodes split too",
         #"(function(){ var d = document.createElement('div'), t = document.createTextNode('hello'); d.appendChild(t); d.appendChild(document.createElement('b')); var n = t.splitText(2); var lone = document.createTextNode('xyz'), m = lone.splitText(3); var e = ''; try { t.splitText(9); } catch (x) { e = x.name; } return t.data === 'he' && n.data === 'llo' && t.nextSibling === n && n.nextSibling.nodeName === 'B' && d.childNodes.length === 3 && lone.data === 'xyz' && m.data === '' && m.parentNode === null && e === 'IndexSizeError' && n.nodeType === 3 && n.ownerDocument === document; })()"#),
        ("splitText records in WebKit's / Blink's order: characterData (replace data) then childList (insert)",
         #"(function(){ var d = document.createElement('div'), t = document.createTextNode('hello'); d.appendChild(t); var mo = new MutationObserver(function(){}); mo.observe(d, { childList: true, characterData: true, characterDataOldValue: true, subtree: true }); var n = t.splitText(3); var r = mo.takeRecords(); mo.disconnect(); return r.map(function(x){ return x.type === 'childList' ? 'cl' + x.addedNodes.length + (x.previousSibling === t ? 'p' : '') : 'cd' + x.oldValue; }).join(' ') === 'cdhello cl1p'; })()"#),
        ("wholeText concatenates the contiguous Text nodes",
         #"(function(){ var d = document.createElement('div'); d.appendChild(document.createTextNode('a')); var m = document.createTextNode('b'); d.appendChild(m); d.appendChild(document.createTextNode('c')); d.appendChild(document.createElement('i')); d.appendChild(document.createTextNode('z')); return m.wholeText === 'abc' && d.lastChild.wholeText === 'z' && document.createTextNode('q').wholeText === 'q'; })()"#),
        ("members are on the prototype chain, not own; methods have WebIDL lengths",
         #"(function(){ var t = document.createTextNode('a'), c = document.createComment('b'); return !Object.prototype.hasOwnProperty.call(t, 'data') && typeof t.appendData === 'function' && t.appendData === c.appendData && t.appendData.length === 1 && t.replaceData.length === 3 && t.substringData.length === 2 && typeof t.splitText === 'function' && c.splitText === undefined && typeof document.createElement('div').appendData === 'undefined'; })()"#),
        ("a host's interface prototypes (__rnSetNodeInterfaces) get the members over their stubs; existing wrappers move",
         #"(function(){ var early = document.createTextNode('early'); var EP = Object.getPrototypeOf(document.createElement('div')); var cd = Object.create(EP); ['data', 'length'].forEach(function(k){ Object.defineProperty(cd, k, { value: k === 'data' ? '' : 0, writable: true, configurable: true, enumerable: true }); }); Object.defineProperty(cd, 'appendData', { value: function(){}, writable: true, configurable: true }); var tp = Object.create(cd), cp = Object.create(cd); Object.defineProperty(tp, 'wholeText', { value: '', writable: true, configurable: true }); if (typeof __rnSetNodeInterfaces !== 'function') return 'no hook'; __rnSetNodeInterfaces({}, null, tp, cp); var t = document.createTextNode('ab'), c = document.createComment('x'); var mo = new MutationObserver(function(){}); mo.observe(t, { characterData: true, characterDataOldValue: true }); t.appendData('c'); t.data = 'z'; var r = mo.takeRecords(); mo.disconnect(); return Object.getPrototypeOf(t) === tp && Object.getPrototypeOf(c) === cp && Object.getPrototypeOf(early) === tp && early.data === 'early' && early.length === 5 && t.data === 'z' && t.length === 1 && t.wholeText === 'z' && c.length === 1 && r.length === 2 && r[0].oldValue === 'ab' && r[1].oldValue === 'abc' && Object.getOwnPropertyDescriptor(cd, 'data').get !== undefined; })()"#),
    ]

    mutating func testDOMCharacterData() {
        var outcomes: [(Bool, String)] = []
        func onMain(_ body: @escaping @MainActor () -> Void) {
            if Thread.isMainThread { MainActor.assumeIsolated { body() } } else { DispatchQueue.main.sync { MainActor.assumeIsolated { body() } } }
        }
        onMain {
            let e = JeffJSEnvironment()
            for (name, js) in JeffJSTestRunner.domCharacterDataCases {
                switch e.eval(js, filename: "<dom-character-data>") {
                case .success(let v): outcomes.append((v == "true", "DOMCharacterData: \(name) -> \(v ?? "undefined")"))
                case .exception(let m): outcomes.append((false, "DOMCharacterData: \(name) threw \(m)"))
                }
            }
        }
        for (ok, message) in outcomes { assert(ok, message) }
    }
}
