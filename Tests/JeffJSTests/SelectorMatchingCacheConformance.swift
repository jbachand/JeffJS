// SelectorMatchingCacheConformance.swift
// JeffJS — "SelectorMatchingCache": the per-element selector-matching caches
// (`DOMNode+SelectorCache.swift`) must never change a match result.
//
// * `:lang()` reads the element's language resolved once per selector epoch
//   (HTML §3.2.6.2 inheritance, `lang=""` = unknown, RFC 4647 extended
//   filtering): it has to follow attribute changes on the element and its
//   ancestors, re-parenting, and ancestors being freed.
// * Descendant / child chains are pre-filtered by a Bloom filter of the
//   ancestors' tag names, ids, classes and languages: every tree or attribute
//   mutation has to be seen by the next match, including through `:is()`,
//   `:where()`, `:not()`, `:has()` and sibling combinators.
//
// JS cases run through the DOM bridge (what pages do: setAttribute,
// appendChild, insertBefore, replaceWith, matches, querySelectorAll); Swift
// cases drive `DOMNode` / `CSSSelectorMatcher` directly (what the app's style
// resolver does).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let selectorMatchingCacheCases: [(String, String)] = [
        // ---- :lang() ----
        ("lang is inherited and matched by subtag prefix, case-insensitively",
         #"(function(){ document.body.innerHTML = '<div id=l1 lang=en-US><p><span id=l2>x</span></p></div>'; var s = document.getElementById('l2'); return s.matches(':lang(en)') && s.matches(':lang(en-US)') && s.matches(':lang(EN-us)') && !s.matches(':lang(e)') && !s.matches(':lang(fr)') && !s.matches(':lang(en-GB)'); })()"#),
        ("extended filtering: wildcards, skipped subtags, comma lists",
         #"(function(){ document.body.innerHTML = '<p id=l3 lang=de-Latn-CH>x</p>'; var p = document.getElementById('l3'); return p.matches(':lang(de-CH)') && p.matches(':lang("*-CH")') && p.matches(':lang("*-Latn")') && p.matches(':lang(*)') && p.matches(':lang(fr, de)') && !p.matches(':lang(de-DE)') && !p.matches(':lang(fr, it)') && !p.matches(':lang(de-CH-1996)'); })()"#),
        ("a singleton subtag ends extended filtering",
         #"(function(){ document.body.innerHTML = '<p id=l4 lang=de-x-ch>x</p>'; var p = document.getElementById('l4'); return p.matches(':lang(de)') && !p.matches(':lang(de-CH)'); })()"#),
        ("lang=\"\" is an unknown language and stops inheritance",
         #"(function(){ document.body.innerHTML = '<div lang=en><p id=l5 lang=""><span id=l6>x</span></p></div>'; var p = document.getElementById('l5'), s = document.getElementById('l6'); return !p.matches(':lang(en)') && !s.matches(':lang(en)') && !s.matches(':lang(*)') && s.parentNode.parentNode.matches(':lang(en)'); })()"#),
        ("changing lang on an ancestor is seen by descendants",
         #"(function(){ document.body.innerHTML = '<div id=l7 lang=en><p><span id=l8>x</span></p></div>'; var d = document.getElementById('l7'), s = document.getElementById('l8'); var r = s.matches(':lang(en)'); d.setAttribute('lang', 'fr'); r = r && s.matches(':lang(fr)') && !s.matches(':lang(en)'); d.removeAttribute('lang'); r = r && !s.matches(':lang(fr)'); d.setAttribute('lang', ''); r = r && !s.matches(':lang(*)'); d.setAttribute('lang', 'ja'); return r && s.matches(':lang(ja)') && document.querySelectorAll(':lang(ja) span').length === 1; })()"#),
        ("lang on the element itself overrides and follows its own changes",
         #"(function(){ document.body.innerHTML = '<div lang=en><span id=l9 lang=ko>x</span></div>'; var s = document.getElementById('l9'); var r = s.matches(':lang(ko)') && !s.matches(':lang(en)'); s.removeAttribute('lang'); r = r && s.matches(':lang(en)'); s.lang = 'zh-TW'; return r && s.matches(':lang(zh)') && s.matches(':lang(zh-TW)') && !s.matches(':lang(zh-CN)'); })()"#),
        ("re-parenting moves an element into its new ancestor's language",
         #"(function(){ document.body.innerHTML = '<div id=la lang=en><span id=lm>x</span></div><div id=lb lang=ar><i id=ln></i></div>'; var s = document.getElementById('lm'); var r = s.matches(':lang(en)'); document.getElementById('lb').appendChild(s); r = r && s.matches(':lang(ar)') && !s.matches(':lang(en)'); var frag = document.createElement('div'); frag.appendChild(s); r = r && !s.matches(':lang(ar)') && !s.matches(':lang(*)'); document.getElementById('la').insertBefore(s, null); return r && s.matches(':lang(en)'); })()"#),
        ("xml:lang applies when there is no lang attribute",
         #"(function(){ document.body.innerHTML = '<div><p id=lx>x</p></div>'; var p = document.getElementById('lx'); p.parentNode.setAttribute('xml:lang', 'it'); return p.matches(':lang(it)'); })()"#),
        (":lang() in an ancestor compound, including multi-language lists",
         #"(function(){ document.body.innerHTML = '<section id=ly lang=en><b class=t id=lz>x</b></section>'; var b = document.getElementById('lz'); var r = !b.matches(':lang(ja) .t') && b.matches(':lang(ja, en) .t') && b.matches(':lang(en-US, en) .t') && b.matches('section:lang(en) > .t') && !b.matches(':lang("*-CH") .t'); document.getElementById('ly').lang = 'ja-JP'; return r && b.matches(':lang(ja) .t') && !b.matches(':lang(en) .t') && b.matches(':lang("*-JP") .t'); })()"#),

        // ---- ancestor filter under mutation ----
        ("descendant chains follow class changes on ancestors",
         #"(function(){ document.body.innerHTML = '<div id=a1 class=a><div id=b1 class=b><span id=c1 class=c>x</span></div></div>'; var c = document.getElementById('c1'), a = document.getElementById('a1'); var r = c.matches('.a .b .c'); a.className = 'z'; r = r && !c.matches('.a .b .c') && c.matches('.z .c'); a.classList.add('a'); r = r && c.matches('.a .b .c'); a.removeAttribute('class'); return r && !c.matches('.a .c') && document.querySelectorAll('.a .c').length === 0; })()"#),
        ("descendant chains follow id changes on ancestors",
         #"(function(){ document.body.innerHTML = '<div id=i1><p><em id=i2>x</em></p></div>'; var e = document.getElementById('i2'), d = document.getElementById('i1'); var r = e.matches('#i1 em'); d.id = 'i9'; r = r && !e.matches('#i1 em') && e.matches('#i9 em') && e.matches('div#i9 > p > em'); return r; })()"#),
        ("inserting and removing an ancestor",
         #"(function(){ document.body.innerHTML = '<div id=w0><span id=w1 class=c>x</span></div>'; var s = document.getElementById('w1'), top = document.getElementById('w0'); var r = !s.matches('.wrap .c') && s.matches('#w0 > .c'); var wrap = document.createElement('section'); wrap.className = 'wrap'; top.insertBefore(wrap, s); wrap.appendChild(s); r = r && s.matches('.wrap .c') && s.matches('#w0 > section.wrap > .c') && !s.matches('#w0 > .c') && s.matches('#w0 .c'); wrap.replaceWith(s); return r && !s.matches('.wrap .c') && s.matches('#w0 > .c') && document.querySelectorAll('section .c').length === 0; })()"#),
        ("moving a subtree between ancestors",
         #"(function(){ document.body.innerHTML = '<ul id=m1 class=one><li><b id=m3 class=k>x</b></li></ul><ol id=m2 class=two></ol>'; var li = document.querySelector('#m1 > li'), b = document.getElementById('m3'); var r = b.matches('.one .k') && !b.matches('.two .k') && b.matches('ul li .k'); document.getElementById('m2').appendChild(li); r = r && !b.matches('.one .k') && b.matches('.two .k') && b.matches('ol > li > .k') && !b.matches('ul .k'); li.remove(); return r && !b.matches('.two .k') && b.matches('li .k') && b.matches('li > .k') && !b.matches('ol .k'); })()"#),
        ("a detached subtree only sees its own ancestors",
         #"(function(){ var d = document.createElement('div'); d.className = 'q'; d.innerHTML = '<p><a id=dt class=r>x</a></p>'; var a = d.querySelector('#dt'); var r = a.matches('.q .r') && a.matches('div p .r') && !a.matches('body .r'); document.body.appendChild(d); return r && a.matches('body .r') && a.matches('body > .q > p > .r'); })()"#),
        ("child combinator only looks at the parent",
         #"(function(){ document.body.innerHTML = '<div class=x><div class=y><i id=cz class=z></i></div></div>'; var i = document.getElementById('cz'); return i.matches('.y > .z') && !i.matches('.x > .z') && i.matches('.x > .y > .z') && i.matches('.x .z') && !i.matches('.x > .x .z'); })()"#),

        // ---- sibling combinators mixed with ancestor ones ----
        ("a compound before + or ~ is a sibling, not an ancestor",
         #"(function(){ document.body.innerHTML = '<div class=p><h2 class=s></h2><div class=b><span id=sc class=c>x</span></div></div>'; var s = document.getElementById('sc'); var r = s.matches('.s + .b .c') && s.matches('.s ~ .b > .c') && s.matches('.p > .s + .b .c') && s.matches('.p .s ~ .b .c') && !s.matches('.b + .s .c') && !s.matches('.q .s + .b .c'); var h = document.querySelector('.s'); h.className = 't'; r = r && !s.matches('.s + .b .c') && s.matches('.t + .b .c'); h.remove(); return r && !s.matches('.t + .b .c') && s.matches('.p > .b .c'); })()"#),
        ("sibling chains follow sibling insertion",
         #"(function(){ document.body.innerHTML = '<p id=g1 class=g></p><p id=g2 class=h></p>'; var h = document.getElementById('g2'); var r = h.matches('.g + .h') && h.matches('.g ~ .h'); var n = document.createElement('em'); h.before(n); r = r && !h.matches('.g + .h') && h.matches('.g ~ .h') && h.matches('em + .h'); n.remove(); return r && h.matches('.g + .h'); })()"#),

        // ---- :is / :where / :not / :has reuse the filter ----
        (":is() and :where() in ancestor position",
         #"(function(){ document.body.innerHTML = '<div id=is1 class="b k"><div><i id=is2 class=c></i></div></div>'; var i = document.getElementById('is2'), d = document.getElementById('is1'); var r = i.matches(':is(.a.k, .b.k) .c') && i.matches(':where(.a, .b) .c') && !i.matches(':is(.a.k, .b.z) .c') && i.matches(':is(.x .y, div) > div > .c'); d.className = 'a'; r = r && !i.matches(':is(.a.k, .b.k) .c') && i.matches(':where(.a, .b) .c'); d.className = 'a k'; return r && i.matches(':is(.a.k, .b.k) .c') && i.matches('.k :is(.c)'); })()"#),
        (":not() with a complex argument follows mutations",
         #"(function(){ document.body.innerHTML = '<div id=n1 class=off><i id=n2 class=c></i></div>'; var i = document.getElementById('n2'), d = document.getElementById('n1'); var r = i.matches('.c:not(.on .c)') && !i.matches('.c:not(.off .c)'); d.className = 'on'; r = r && !i.matches('.c:not(.on .c)') && i.matches('.c:not(.off .c)'); return r && document.querySelectorAll('i:not(.on *)').length === 0; })()"#),
        (":has() with a complex argument follows mutations",
         #"(function(){ document.body.innerHTML = '<section id=h1><div id=h2><b id=h3 class=t></b></div></section>'; var sec = document.getElementById('h1'), div = document.getElementById('h2'); var r = sec.matches(':has(div .t)') && !sec.matches(':has(.m .t)'); div.className = 'm'; r = r && sec.matches(':has(.m .t)') && sec.matches(':has(> .m > .t)'); document.getElementById('h3').remove(); return r && !sec.matches(':has(.m .t)') && !sec.matches(':has(.t)'); })()"#),
        ("querySelectorAll after a batch of mutations",
         #"(function(){ document.body.innerHTML = '<div class=root><ul class=list></ul></div>'; var ul = document.querySelector('.list'); for (var i = 0; i < 20; i++) { var li = document.createElement('li'); li.className = i % 2 ? 'odd' : 'even'; li.innerHTML = '<span class=v>' + i + '</span>'; ul.appendChild(li); } var r = document.querySelectorAll('.root .list .odd .v').length === 10; ul.className = 'other'; r = r && document.querySelectorAll('.root .list .odd .v').length === 0 && document.querySelectorAll('.root .other > .even > .v').length === 10; document.querySelector('.root').classList.remove('root'); return r && document.querySelectorAll('.root .v').length === 0 && document.querySelectorAll('div .v').length === 20; })()"#),
    ]

    mutating func testSelectorMatchingCache() {
        // JS through the DOM bridge.
        var outcomes: [(Bool, String)] = []
        let run = {
            MainActor.assumeIsolated {
                let env = JeffJSEnvironment(configuration: .init(baseURL: URL(string: "https://www.example.com/")!))
                for (name, js) in JeffJSTestRunner.selectorMatchingCacheCases {
                    switch env.eval(js, filename: "<selector-matching-cache>") {
                    case .success(let value):
                        outcomes.append((value == "true", "SelectorMatchingCache: \(name) -> \(value ?? "undefined")"))
                    case .exception(let message):
                        outcomes.append((false, "SelectorMatchingCache: \(name) threw \(message)"))
                    }
                }
            }
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.sync(execute: run) }
        for (ok, message) in outcomes { assert(ok, message) }

        // Swift-side DOM, as the app's style resolver drives it.
        func sel(_ text: String) -> CSSComplexSelector { CSSSelectorParser.parse(text).selectors[0] }
        func m(_ text: String, _ node: DOMNode) -> Bool { CSSSelectorMatcher.matches(sel(text), node: node) }

        // Language resolution and its cache.
        let html = DOMNode.element(tag: "html", attributes: ["lang": "EN-us"])
        let body = DOMNode.element(tag: "body")
        let p = DOMNode.element(tag: "p", attributes: ["class": "t"])
        html.appendChild(body)
        body.appendChild(p)
        assert(p.language == "en-us" && body.language == "en-us", "SelectorMatchingCache: language is inherited and lowercased")
        assert(m(":lang(en)", p) && m(":lang(en) .t", p) && !m(":lang(ja) .t", p), "SelectorMatchingCache: Swift :lang matches")
        body.setAttribute(name: "lang", value: "")
        // (`:lang(en) .t` still matches: `html` is an `en` ancestor.)
        assert(p.language == "" && !m(":lang(en)", p) && !m("body:lang(en) .t", p) && m(":lang(en) .t", p)
               && !m(":lang(*)", p), "SelectorMatchingCache: lang=\"\" on an ancestor")
        body.removeAttribute(name: "lang")
        assert(p.language == "en-us" && m(":lang(en) .t", p), "SelectorMatchingCache: removing lang restores inheritance")
        html.attributes["lang"] = "ja"   // direct dictionary edit (hosts do this)
        assert(p.language == "ja" && m(":lang(ja) .t", p) && !m(":lang(en)", p), "SelectorMatchingCache: direct attributes edit is seen")

        // An ancestor freed while its child still points at it (weak parent
        // zeroed without an observer): the child must forget it.
        var owner: DOMNode? = DOMNode.element(tag: "div", attributes: ["lang": "fr", "class": "own"])
        let orphan = DOMNode.element(tag: "span", attributes: ["class": "o"])
        owner!.appendChild(orphan)
        assert(orphan.language == "fr" && m(".own .o", orphan), "SelectorMatchingCache: before the ancestor is freed")
        owner!.detachChildrenArray()
        owner = nil
        assert(orphan.parent == nil && orphan.language == nil && !m(".own .o", orphan) && !m(":lang(fr)", orphan),
               "SelectorMatchingCache: a freed ancestor no longer contributes")

        // Ancestor filter across insert / remove / move / attribute edits.
        let root = HTMLParser.parse("<div id=r class='x'><div class='y'><em class='z'></em></div></div><aside class='w'></aside>")
        guard let em = root.querySelector("em"), let y = root.querySelector(".y"),
              let r = root.querySelector("#r"), let aside = root.querySelector("aside") else {
            assert(false, "SelectorMatchingCache: fixture tree")
            return
        }
        assert(m(".x .y .z", em) && m("#r > .y > em", em) && !m(".w .z", em), "SelectorMatchingCache: initial chain")
        r.removeChild(y)
        assert(!m(".x .z", em) && m(".y > .z", em), "SelectorMatchingCache: removed ancestor")
        aside.appendChild(y)
        assert(m(".w .y .z", em) && !m(".x .z", em) && m("body > aside.w > div > em", em), "SelectorMatchingCache: moved under a new ancestor")
        let wrapper = DOMNode.element(tag: "nav", attributes: ["id": "wr", "class": "k"])
        aside.replaceChild(y, with: [wrapper])
        wrapper.appendChild(y)
        assert(m("#wr .z", em) && m(".w > nav.k > .y > .z", em) && m("aside .k em", em), "SelectorMatchingCache: inserted ancestor")
        wrapper.setAttribute(name: "class", value: "k2")
        assert(!m(".k .z", em) && m(".k2 .z", em), "SelectorMatchingCache: class edit on an inserted ancestor")
        wrapper.setAttributePreservingCase(name: "id", value: "wr2")
        assert(!m("#wr .z", em) && m("#wr2 .z", em), "SelectorMatchingCache: id edit")

        // Language primary subtags: the filter must not reject a range list
        // with several primaries, or a wildcard.
        let langRoot = HTMLParser.parse("<div lang='zh-Hant-TW'><p><b class='g'>x</b></p></div>")
        if let b = langRoot.querySelector(".g") {
            assert(m(":lang(zh-TW) .g", b) && m(":lang(ja, zh) .g", b) && m(":lang(\"*-TW\") .g", b)
                   && !m(":lang(zh-CN) .g", b) && !m(":lang(ja, ko) .g", b),
                   "SelectorMatchingCache: :lang ranges in ancestor compounds")
        } else {
            assert(false, "SelectorMatchingCache: lang fixture tree")
        }

        // The matcher's answer equals a plain walk for a batch of selectors on
        // a mutated tree (catches any over-eager rejection).
        let big = HTMLParser.parse(String(repeating: "<div class='a b'><section id=s><p class='c'><span class='d'>t</span></p></section></div>", count: 5))
        let spans = big.querySelectorAll("span")
        if let firstDiv = big.querySelector("div") { firstDiv.setAttribute(name: "class", value: "a") }
        let probes = [".a .d", ".b .d", ".a.b .c > .d", "#s .d", "section > p .d", "div:not(.b) .d", ":is(.b, #s) .d",
                      ".c + .d", "p ~ .d", ".zz .d", "div > .d", "div > section > p > span.d", "body .d"]
        for text in probes {
            let selector = sel(text)
            for span in spans {
                let fast = CSSSelectorMatcher.matches(selector, node: span)
                let slow = naiveMatches(selector.parts, selector.parts.count - 1, span)
                assert(fast == slow, "SelectorMatchingCache: '\(text)' agrees with a plain walk")
            }
        }
    }

    /// Reference matcher: the right-to-left walk with no filters.
    private func naiveMatches(_ parts: [CSSComplexSelector.Part], _ index: Int, _ node: DOMNode) -> Bool {
        guard CSSSelectorMatcher.matchesCompound(parts[index].selector, node: node) else { return false }
        if index == 0 { return true }
        switch parts[index].combinator ?? .descendant {
        case .child:
            guard let parent = node.parent else { return false }
            return naiveMatches(parts, index - 1, parent)
        case .descendant:
            var cursor = node.parent
            while let ancestor = cursor {
                if naiveMatches(parts, index - 1, ancestor) { return true }
                cursor = ancestor.parent
            }
            return false
        case .adjacentSibling:
            guard let sibling = CSSSelectorMatcher.previousElementSibling(of: node) else { return false }
            return naiveMatches(parts, index - 1, sibling)
        case .generalSibling:
            var cursor = CSSSelectorMatcher.previousElementSibling(of: node)
            while let sibling = cursor {
                if naiveMatches(parts, index - 1, sibling) { return true }
                cursor = CSSSelectorMatcher.previousElementSibling(of: sibling)
            }
            return false
        }
    }
}
