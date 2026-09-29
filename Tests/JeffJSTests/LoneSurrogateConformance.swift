// LoneSurrogateConformance.swift
// JeffJS — conformance group "LoneSurrogate" (ES §12.9.4.1 string literal SV,
// §12.9.6 template CV, §6.1.4: a String value is a sequence of UTF-16 code units,
// so `"\uD800"` is the one code unit 0xD800). The tokenizer built its literal
// values as Swift Strings from WTF-8 bytes; a lone surrogate made the decode fail
// and the *whole* literal became "" (`"a\ud800b".length === 0`). Also
// encodeURI/encodeURIComponent (§19.2.6.5 Encode: URIError on a lone surrogate,
// JSC's "String contained an illegal UTF-16 sequence.") and decodeURI(Component)
// (§19.2.6.6: code units copied unchanged, JSC's "URI error"), which read their
// argument through a lossy Swift String.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let loneSurrogateCases: [(String, String)] = [
        ("a string literal keeps a lone high surrogate",
         #"(function(){ var s = "a\ud800b"; return s.length === 3 && s.charCodeAt(0) === 0x61 && s.charCodeAt(1) === 0xD800 && s.charCodeAt(2) === 0x62; })()"#),
        ("a lone low surrogate, \\u{…} form, single quotes",
         #"(function(){ var s = 'x\u{DC00}'; var t = "\udfff"; return s.length === 2 && s.charCodeAt(1) === 0xDC00 && t.length === 1 && t.charCodeAt(0) === 0xDFFF; })()"#),
        ("an escaped surrogate pair is still one code point",
         #"(function(){ var s = "😀"; return s.length === 2 && s.codePointAt(0) === 0x1F600 && s === String.fromCodePoint(0x1F600); })()"#),
        ("reversed pair and two highs stay separate code units",
         #"(function(){ var s = "\ude00\ud83d", t = "\ud800\ud800"; return s.length === 2 && s.charCodeAt(0) === 0xDE00 && s.charCodeAt(1) === 0xD83D && t.length === 2 && [...t].length === 2; })()"#),
        ("a literal equals String.fromCharCode of the same unit",
         #""\ud800" === String.fromCharCode(0xD800) && "a\ud800" === "a" + String.fromCharCode(0xD800)"#),
        ("non-ASCII text next to the lone surrogate survives",
         #"(function(){ var s = "é\ud800€"; return s.length === 3 && s.charCodeAt(0) === 0xE9 && s.charCodeAt(1) === 0xD800 && s.charCodeAt(2) === 0x20AC; })()"#),
        ("template literals (untagged) keep the code unit",
         #"(function(){ var a = `x\ud800y`, b = `${1}\udc00${2}`; return a.length === 3 && a.charCodeAt(1) === 0xD800 && b === '1' + String.fromCharCode(0xDC00) + '2'; })()"#),
        ("tagged templates: cooked keeps the unit, raw keeps the escape",
         #"(function(){ function t(s) { return s; } var s = t`q\ud800`; return s[0].length === 2 && s[0].charCodeAt(1) === 0xD800 && s.raw[0] === 'q\\ud800'; })()"#),
        ("direct and indirect eval of a lone-surrogate literal",
         #"eval('"\\ud800"').charCodeAt(0) === 0xD800 && (0, eval)('"\\udc01x"').length === 2"#),
        ("new Function body with a lone surrogate",
         #"new Function('return "a\\ud800"')().charCodeAt(1) === 0xD800"#),
        ("JSON.parse keeps it and JSON.stringify escapes it",
         #"JSON.parse('"\\ud800"').charCodeAt(0) === 0xD800 && JSON.stringify("\ud800") === '"\\ud800"' && JSON.stringify("😀").length === 4"#),
        ("isWellFormed / toWellFormed see the lone surrogate",
         #""a\ud800".isWellFormed() === false && "😀".isWellFormed() && "a\ud800b\udc00".toWellFormed() === 'a�b�'"#),
        ("iteration and codePointAt",
         #""\ud800".codePointAt(0) === 0xD800 && [..."\ud800x"].length === 2"#),
        ("a regexp matches the literal's code unit",
         #"/\ud800/.test("\ud800") && "x\ud800y".replace("\ud800", "-") === 'x-y'"#),
        ("encodeURIComponent throws URIError on a lone high surrogate (JSC text)",
         #"(function(){ try { encodeURIComponent("\ud800"); return false; } catch (e) { return e instanceof URIError && e.message === 'String contained an illegal UTF-16 sequence.'; } })()"#),
        ("encodeURI throws URIError on a lone low surrogate and on high-high",
         #"(function(){ var n = 0; try { encodeURI("a\udc00"); } catch (e) { if (e instanceof URIError) n++; } try { encodeURI("\ud800\ud800"); } catch (e) { if (e instanceof URIError) n++; } try { encodeURI(String.fromCharCode(0xD800)); } catch (e) { if (e instanceof URIError) n++; } return n === 3; })()"#),
        ("encode: pairs and non-ASCII are UTF-8 escaped, not letter-allowed",
         #"encodeURIComponent("😀é") === '%F0%9F%98%80%C3%A9' && encodeURI('http://x/a b?q=é#f[1]') === 'http://x/a%20b?q=%C3%A9#f%5B1%5D'"#),
        ("decodeURIComponent copies a lone surrogate unchanged",
         #"decodeURIComponent("\ud800%41") === "\ud800A" && decodeURI("%F0%9F%98%80") === "😀""#),
        ("decodeURI keeps reserved escapes, rejects encoded surrogates / overlongs (JSC text)",
         #"(function(){ if (decodeURI('%23%2F%3f%41') !== '%23%2F%3fA') return false; var bad = ['%ED%A0%80', '%C0%80', '%E2%82', 'a%', '%zz']; for (var i = 0; i < bad.length; i++) { try { decodeURIComponent(bad[i]); return false; } catch (e) { if (!(e instanceof URIError) || e.message !== 'URI error') return false; } } return true; })()"#),
    ]

    mutating func testLoneSurrogate() {
        runTrueCases("LoneSurrogate", JeffJSTestRunner.loneSurrogateCases)
    }
}
