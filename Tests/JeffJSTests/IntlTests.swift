// IntlTests.swift
// JeffJS — the native (Foundation-backed) ECMA-402 surface installed by
// JeffJSIntlBridge, plus crypto.subtle.digest from JeffJSWebAPIsBridge.
//
// Expected values are JavaScriptCore's (`jsc`) output on the same machine;
// qjs has no Intl at all. Two documented divergences from this machine's jsc:
// its ICU is older, so it prints a plain space before AM/PM where JeffJS (and
// current Chrome/Node ICU) print U+202F, and formatRange is the basic
// "<start> – <end>" form rather than ICU's field-collapsing one.
//
// Usage:
//   swift test --filter IntlTests
//   JEFFJS_ZOMBIES=1 JEFFJS_TRACK_RC=1 swift test --filter IntlTests

import XCTest
@testable import JeffJS

final class IntlTests: XCTestCase {

    // MARK: - Helpers

    @MainActor
    private func makeEnvironment() -> JeffJSEnvironment {
        return JeffJSEnvironment(configuration: .init(storageScope: "jeffjs.test.intl"))
    }

    @MainActor
    @discardableResult
    private func evalString(_ env: JeffJSEnvironment, _ js: String,
                            file: StaticString = #filePath, line: UInt = #line) -> String {
        switch env.eval(js) {
        case .success(let s): return s ?? "undefined"
        case .exception(let msg):
            XCTFail("JS threw: \(msg) — while evaluating: \(js)", file: file, line: line)
            return "<exception>"
        }
    }

    @MainActor
    private func expect(_ env: JeffJSEnvironment, _ js: String, _ expected: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(evalString(env, js, file: file, line: line), expected,
                       js, file: file, line: line)
    }

    // MARK: - Presence

    @MainActor
    func testIntlIsNativeAndNotAStub() {
        let env = makeEnvironment()
        defer { env.teardown() }
        expect(env, "typeof Intl", "object")
        expect(env, "typeof Intl.NumberFormat", "function")
        // The host stubs guard on a callable NumberFormat.prototype.format.
        expect(env, "typeof Intl.NumberFormat.prototype.format", "function")
        expect(env, "typeof Intl.DateTimeFormat.prototype.format", "function")
        expect(env, """
        ['NumberFormat','DateTimeFormat','Collator','PluralRules','RelativeTimeFormat',
         'ListFormat','DisplayNames','Locale','Segmenter']
          .every(function(k){ return typeof Intl[k] === 'function'; }) + ''
        """, "true")
        expect(env, "typeof Intl.getCanonicalLocales + ',' + typeof Intl.supportedValuesOf",
               "function,function")
    }

    // MARK: - NumberFormat

    @MainActor
    func testNumberFormatBasics() {
        let env = makeEnvironment()
        defer { env.teardown() }
        expect(env, "new Intl.NumberFormat('en-US').format(1234.5)", "1,234.5")
        expect(env, "new Intl.NumberFormat('en-US').format(1234567.891)", "1,234,567.891")
        expect(env, "new Intl.NumberFormat('de-DE').format(1234567.891)", "1.234.567,891")
        expect(env, "new Intl.NumberFormat('en-US',{useGrouping:false}).format(1234567.5)", "1234567.5")
        expect(env, "new Intl.NumberFormat('en-US',{minimumFractionDigits:2}).format(5)", "5.00")
        expect(env, "new Intl.NumberFormat('en-US',{maximumFractionDigits:0}).format(2.5)", "3")
        expect(env, "new Intl.NumberFormat('en-US',{style:'percent'}).format(0.256)", "26%")
        expect(env, """
        new Intl.NumberFormat('en-US',{minimumSignificantDigits:3,maximumSignificantDigits:5})
          .format(1.23456)
        """, "1.2346")
        expect(env, "new Intl.NumberFormat('en').format(NaN)", "NaN")
        expect(env, "new Intl.NumberFormat('en',{signDisplay:'always'}).format(5)", "+5")
    }

    @MainActor
    func testNumberFormatCurrency() {
        let env = makeEnvironment()
        defer { env.teardown() }
        expect(env, "new Intl.NumberFormat('en-US',{style:'currency',currency:'USD'}).format(9.99)", "$9.99")
        // Lower-case currency codes are canonicalised.
        expect(env, "new Intl.NumberFormat('en-US',{style:'currency',currency:'usd'}).format(1)", "$1.00")
        // JPY has zero minor units.
        expect(env, "new Intl.NumberFormat('en-US',{style:'currency',currency:'JPY'}).format(1234.5)", "¥1,235")
        expect(env, """
        (function(){
          try { new Intl.NumberFormat('en',{style:'currency',currency:'US'}).format(1); return 'no throw'; }
          catch (e) { return e.name; }
        })()
        """, "RangeError")
        expect(env, """
        (function(){
          try { new Intl.NumberFormat('en',{style:'currency'}).format(1); return 'no throw'; }
          catch (e) { return e.name; }
        })()
        """, "TypeError")
    }

    @MainActor
    func testNumberFormatCompactNotation() {
        let env = makeEnvironment()
        defer { env.teardown() }
        expect(env, "new Intl.NumberFormat('en',{notation:'compact'}).format(12345)", "12K")
        expect(env, """
        [999,1000,1234,123456,999999,1500000,1234567,1e9,1.5e12,-12345,0]
          .map(function(v){ return new Intl.NumberFormat('en',{notation:'compact'}).format(v); })
          .join(',')
        """, "999,1K,1.2K,123K,1M,1.5M,1.2M,1B,1.5T,-12K,0")
    }

    @MainActor
    func testNumberFormatPartsAndResolvedOptions() {
        let env = makeEnvironment()
        defer { env.teardown() }
        expect(env, """
        JSON.stringify(new Intl.NumberFormat('en-US',{style:'currency',currency:'USD'})
          .formatToParts(1234.5))
        """, """
        [{"type":"currency","value":"$"},{"type":"integer","value":"1"},\
        {"type":"group","value":","},{"type":"integer","value":"234"},\
        {"type":"decimal","value":"."},{"type":"fraction","value":"50"}]
        """)
        expect(env, """
        (function(){
          var o = new Intl.NumberFormat('en-US').resolvedOptions();
          return [o.locale,o.style,o.numberingSystem,o.minimumFractionDigits,
                  o.maximumFractionDigits,o.notation].join(',');
        })()
        """, "en-US,decimal,latn,0,3,standard")
        // Internal bookkeeping must not leak into resolvedOptions().
        expect(env, """
        Object.keys(new Intl.NumberFormat('en-US').resolvedOptions())
          .filter(function(k){ return k.charAt(0) === '_'; }).length + ''
        """, "0")
    }

    // MARK: - DateTimeFormat

    @MainActor
    func testDateTimeFormatComponents() {
        let env = makeEnvironment()
        defer { env.teardown() }
        expect(env, "new Intl.DateTimeFormat('en-US',{month:'short',day:'numeric'}).format(new Date(2026,8,20))",
               "Sep 20")
        expect(env, "new Intl.DateTimeFormat('en-US').format(new Date(2026,8,20))", "9/20/2026")
        expect(env, """
        new Intl.DateTimeFormat('en-US',{weekday:'long',year:'numeric',month:'long',day:'numeric'})
          .format(new Date(2026,8,20))
        """, "Sunday, September 20, 2026")
        expect(env, """
        new Intl.DateTimeFormat('en-US',{hour:'2-digit',minute:'2-digit',hour12:false,timeZone:'UTC'})
          .format(new Date(Date.UTC(2026,8,20,18,5)))
        """, "18:05")
        expect(env, """
        new Intl.DateTimeFormat('en-GB',{dateStyle:'short',timeZone:'UTC'})
          .format(new Date(Date.UTC(2026,8,20,18,5)))
        """, "20/09/2026")
    }

    @MainActor
    func testDateTimeFormatResolvedOptionsHasRealTimeZone() {
        let env = makeEnvironment()
        defer { env.teardown() }
        expect(env, "typeof new Intl.DateTimeFormat().resolvedOptions().timeZone", "string")
        expect(env, "new Intl.DateTimeFormat().resolvedOptions().timeZone.length > 0 ? 'ok' : 'empty'", "ok")
        expect(env, "new Intl.DateTimeFormat('en',{timeZone:'UTC'}).resolvedOptions().timeZone", "UTC")
        expect(env, """
        (function(){
          var o = new Intl.DateTimeFormat('en-US',{timeZone:'UTC',month:'short'}).resolvedOptions();
          return [o.locale,o.calendar,o.numberingSystem,o.timeZone,o.month].join(',');
        })()
        """, "en-US,gregory,latn,UTC,short")
        expect(env, """
        (function(){
          try { new Intl.DateTimeFormat('en',{timeZone:'Not/AZone'}); return 'no throw'; }
          catch (e) { return e.name; }
        })()
        """, "RangeError")
    }

    @MainActor
    func testDateTimeFormatPartsAndRange() {
        let env = makeEnvironment()
        defer { env.teardown() }
        expect(env, """
        JSON.stringify(new Intl.DateTimeFormat('en-US',{month:'short',day:'numeric'})
          .formatToParts(new Date(2026,8,20)))
        """, """
        [{"type":"month","value":"Sep"},{"type":"literal","value":" "},{"type":"day","value":"20"}]
        """)
        expect(env, """
        new Intl.DateTimeFormat('en-US',{month:'short',day:'numeric'})
          .formatRange(new Date(2026,8,20), new Date(2026,8,20))
        """, "Sep 20")
        expect(env, """
        new Intl.DateTimeFormat('en-US',{month:'short',day:'numeric'})
          .formatRange(new Date(2026,8,20), new Date(2026,8,21)).indexOf('Sep 20') === 0 ? 'ok' : 'bad'
        """, "ok")
    }

    // MARK: - Collator

    @MainActor
    func testCollatorSortsAndIsBound() {
        let env = makeEnvironment()
        defer { env.teardown() }
        expect(env, "['b','a','B'].sort(new Intl.Collator('en').compare).join()", "a,b,B")
        // `.compare` detached from its receiver still works (bound function).
        expect(env, """
        (function(){ var c = new Intl.Collator('en').compare; return c('a','b') + ',' + c('b','a') + ',' + c('a','a'); })()
        """, "-1,1,0")
        expect(env, "new Intl.Collator('en',{sensitivity:'base'}).compare('a','A')", "0")
        expect(env, "['10','9','1'].sort(new Intl.Collator('en',{numeric:true}).compare).join()", "1,9,10")
        expect(env, "new Intl.Collator('en',{ignorePunctuation:true}).compare('a-b','ab')", "0")
        expect(env, "new Intl.Collator('en').resolvedOptions().sensitivity", "variant")
    }

    // MARK: - PluralRules / RelativeTimeFormat / ListFormat / DisplayNames

    @MainActor
    func testPluralRules() {
        let env = makeEnvironment()
        defer { env.teardown() }
        expect(env, "new Intl.PluralRules('en').select(1)", "one")
        expect(env, "[0,1,2,1.5].map(function(v){return new Intl.PluralRules('en').select(v);}).join()",
               "other,one,other,other")
        expect(env, """
        [1,2,3,4,11,21].map(function(v){
          return new Intl.PluralRules('en',{type:'ordinal'}).select(v); }).join()
        """, "one,two,few,other,other,one")
        expect(env, "[0,1,2,5,21,22].map(function(v){return new Intl.PluralRules('ru').select(v);}).join()",
               "many,one,few,many,one,few")
        expect(env, "[0,1,2].map(function(v){return new Intl.PluralRules('fr').select(v);}).join()",
               "one,one,other")
        expect(env, "[0,1,2,3,11].map(function(v){return new Intl.PluralRules('ar').select(v);}).join()",
               "zero,one,two,few,many")
        expect(env, "new Intl.PluralRules('ja').select(1)", "other")
    }

    @MainActor
    func testRelativeTimeFormat() {
        let env = makeEnvironment()
        defer { env.teardown() }
        expect(env, "new Intl.RelativeTimeFormat('en',{numeric:'auto'}).format(-1,'day')", "yesterday")
        expect(env, """
        [-2,-1,0,1,2].map(function(v){
          return new Intl.RelativeTimeFormat('en',{numeric:'auto'}).format(v,'day'); }).join('|')
        """, "2 days ago|yesterday|today|tomorrow|in 2 days")
        expect(env, """
        [-2,-1,0,1,2].map(function(v){
          return new Intl.RelativeTimeFormat('en').format(v,'day'); }).join('|')
        """, "2 days ago|1 day ago|in 0 days|in 1 day|in 2 days")
        expect(env, """
        ['second','minute','hour','week','month','quarter','year'].map(function(u){
          return new Intl.RelativeTimeFormat('en',{numeric:'auto'}).format(-1,u); }).join('|')
        """, "1 second ago|1 minute ago|1 hour ago|last week|last month|last quarter|last year")
        // Plural unit names are accepted.
        expect(env, "new Intl.RelativeTimeFormat('en').format(-3,'hours')", "3 hours ago")
        expect(env, """
        (function(){
          try { new Intl.RelativeTimeFormat('en').format(1,'fortnight'); return 'no throw'; }
          catch (e) { return e.name; }
        })()
        """, "RangeError")
    }

    @MainActor
    func testListFormatAndDisplayNames() {
        let env = makeEnvironment()
        defer { env.teardown() }
        expect(env, """
        [[],['a'],['a','b'],['a','b','c']].map(function(x){
          return new Intl.ListFormat('en').format(x); }).join('|')
        """, "|a|a and b|a, b, and c")
        expect(env, "new Intl.ListFormat('en',{type:'disjunction'}).format(['a','b','c'])", "a, b, or c")
        expect(env, "new Intl.ListFormat('en',{type:'unit'}).format(['a','b','c'])", "a, b, c")
        expect(env, "new Intl.DisplayNames(['en'],{type:'region'}).of('US')", "United States")
        expect(env, "new Intl.DisplayNames(['en'],{type:'currency'}).of('EUR')", "Euro")
        expect(env, "new Intl.DisplayNames(['en'],{type:'language'}).of('fr')", "French")
    }

    // MARK: - Locale / canonicalisation / Segmenter

    @MainActor
    func testLocaleCanonicalisationAndSegmenter() {
        let env = makeEnvironment()
        defer { env.teardown() }
        expect(env, """
        (function(){ var l = new Intl.Locale('en-US');
          return [l.language,l.region,l.baseName,String(l)].join(','); })()
        """, "en,US,en-US,en-US")
        expect(env, """
        (function(){ var l = new Intl.Locale('zh-Hant-TW');
          return [l.language,l.script,l.region,l.baseName].join(','); })()
        """, "zh,Hant,TW,zh-Hant-TW")
        expect(env, "JSON.stringify(Intl.getCanonicalLocales(['EN-us','fr']))", #"["en-US","fr"]"#)
        expect(env, """
        (function(){ try { Intl.getCanonicalLocales('en_US'); return 'no throw'; }
                     catch (e) { return e.name; } })()
        """, "RangeError")
        expect(env, "JSON.stringify(Intl.NumberFormat.supportedLocalesOf(['en-US','xx']))", #"["en-US"]"#)
        expect(env, "Intl.supportedValuesOf('timeZone').length > 10 ? 'ok' : 'short'", "ok")
        expect(env, """
        Array.from(new Intl.Segmenter('en').segment('ab\u{00e9}'))
          .map(function(s){ return s.segment + ':' + s.index; }).join(',')
        """, "a:0,b:1,é:2")
        expect(env, "new Intl.Segmenter('en').segment('abc').containing(1).segment", "b")
    }

    // MARK: - Rewired builtins

    @MainActor
    func testLocaleAwareBuiltinsHonourLocalesAndOptions() {
        let env = makeEnvironment()
        defer { env.teardown() }
        expect(env, "(1234.5).toLocaleString('en-US')", "1,234.5")
        expect(env, "(1234.5).toLocaleString('de-DE')", "1.234,5")
        expect(env, "(0.256).toLocaleString('en-US',{style:'percent'})", "26%")
        expect(env, "(9.99).toLocaleString('en-US',{style:'currency',currency:'USD'})", "$9.99")
        expect(env, "new Date(2026,8,20).toLocaleDateString('en-US')", "9/20/2026")
        expect(env, "new Date(2026,8,20).toLocaleDateString('en-GB')", "20/09/2026")
        expect(env, """
        new Date(2026,8,20).toLocaleDateString('en-US',{month:'long',day:'numeric',year:'numeric'})
        """, "September 20, 2026")
        expect(env, """
        new Date(Date.UTC(2026,8,20,18,5,9)).toLocaleTimeString('en-US',{timeZone:'UTC',hour12:false})
        """, "18:05:09")
        expect(env, "new Date(NaN).toLocaleDateString('en-US')", "Invalid Date")
        expect(env, "'a'.localeCompare('b') + ',' + 'b'.localeCompare('a') + ',' + 'a'.localeCompare('a')",
               "-1,1,0")
        expect(env, "'résumé'.localeCompare('resume','en',{sensitivity:'base'})", "0")
        expect(env, "[1234.5, 9.99].toLocaleString('en-US')", "1,234.5,9.99")
    }

    // MARK: - crypto.subtle

    @MainActor
    func testSubtleDigestResolvesToArrayBuffer() {
        let env = makeEnvironment()
        defer { env.teardown() }
        expect(env, "typeof crypto.subtle + ',' + typeof crypto.subtle.digest", "object,function")
        evalString(env, """
        var HEX = null, LEN = null, IS_AB = null;
        function hex(buf){
          var u = new Uint8Array(buf), s = '';
          for (var i = 0; i < u.length; i++) { s += (u[i] < 16 ? '0' : '') + u[i].toString(16); }
          return s;
        }
        crypto.subtle.digest('SHA-256', new TextEncoder().encode('abc')).then(function(d){
          HEX = hex(d); LEN = d.byteLength; IS_AB = (d instanceof ArrayBuffer);
        });
        """)
        expect(env, "HEX.slice(0,8)", "ba7816bf")
        expect(env, """
        HEX === 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' ? 'ok' : HEX
        """, "ok")
        expect(env, "LEN + ',' + IS_AB", "32,true")
    }

    @MainActor
    func testSubtleDigestAlgorithmsAndInputTypes() {
        let env = makeEnvironment()
        defer { env.teardown() }
        evalString(env, """
        var OUT = {};
        function hex(buf){
          var u = new Uint8Array(buf), s = '';
          for (var i = 0; i < u.length; i++) { s += (u[i] < 16 ? '0' : '') + u[i].toString(16); }
          return s;
        }
        var abc = new TextEncoder().encode('abc');
        crypto.subtle.digest('SHA-1', abc).then(function(d){ OUT.sha1 = hex(d); });
        crypto.subtle.digest({name:'SHA-384'}, abc).then(function(d){ OUT.sha384 = d.byteLength; });
        crypto.subtle.digest('sha-512', abc).then(function(d){ OUT.sha512 = d.byteLength; });
        var ab = new ArrayBuffer(3), dv = new DataView(ab);
        dv.setUint8(0,97); dv.setUint8(1,98); dv.setUint8(2,99);
        crypto.subtle.digest('SHA-256', ab).then(function(d){ OUT.fromBuffer = hex(d).slice(0,8); });
        crypto.subtle.digest('SHA-256', dv).then(function(d){ OUT.fromView = hex(d).slice(0,8); });
        """)
        expect(env, "OUT.sha1", "a9993e364706816aba3e25717850c26c9cd0d89d")
        expect(env, "OUT.sha384 + ',' + OUT.sha512", "48,64")
        expect(env, "OUT.fromBuffer + ',' + OUT.fromView", "ba7816bf,ba7816bf")
    }

    @MainActor
    func testSubtleRejectsUnsupportedAndKeepsRandom() {
        let env = makeEnvironment()
        defer { env.teardown() }
        evalString(env, """
        var ERR = {};
        crypto.subtle.digest('MD5', new Uint8Array([1]))
          .then(function(){ ERR.md5 = 'resolved'; }, function(e){ ERR.md5 = e.name; });
        crypto.subtle.encrypt().then(null, function(e){ ERR.encrypt = e.name; });
        crypto.subtle.importKey().then(null, function(e){ ERR.importKey = e.name; });
        crypto.subtle.digest('SHA-256', 'not a buffer')
          .then(function(){ ERR.bad = 'resolved'; }, function(e){ ERR.bad = e.name; });
        """)
        expect(env, "ERR.md5 + ',' + ERR.encrypt + ',' + ERR.importKey", "NotSupportedError,NotSupportedError,NotSupportedError")
        expect(env, "ERR.bad", "TypeError")
        expect(env, "crypto.randomUUID().length + ',' + crypto.getRandomValues(new Uint8Array(4)).length",
               "36,4")
    }
}
