// ParamPatternTypedArrayConformance.swift
// JeffJS — conformance groups for three defects found on apple.com:
//
//   "ParameterPatterns"   a destructuring parameter's `= default` was never
//                          applied (`function f({silent: t = !1} = {}) {}; f()`
//                          threw "Cannot read properties of undefined"), and
//                          parameter initializers ran defaults-first instead
//                          of left to right.
//   "TypedArrayIteration" %TypedArray%.prototype had no [Symbol.iterator] /
//                          values / keys / entries, so destructuring, spread,
//                          for-of, Array.from and `new Set(u8)` all failed.
//   "HyperlinkReflection" <a>/<area>/<link> reflected attributes (hreflang,
//                          target, download, ping, referrerPolicy) and the
//                          HTMLHyperlinkElementUtils URL decomposition.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let parameterPatternCases: [(String, String)] = [
        // The apple.com AnimSystem shape.
        ("object pattern default applies when the argument is missing",
         "(function(){ function f({silent: t = !1} = {}){ return t; } return f() === false; })()"),
        ("class method with a defaulted object pattern",
         "(function(){ class A { onKeyframesDirty({silent: t = !1} = {}){ return t; } } return new A().onKeyframesDirty() === false && new A().onKeyframesDirty({silent: 1}) === 1; })()"),
        ("explicit undefined takes the default, null does not",
         "(function(){ function f({a} = {a: 2}){ return a; } var threw = false; try { f(null); } catch (e) { threw = e instanceof TypeError; } return f(undefined) === 2 && threw; })()"),
        ("array pattern default",
         "(function(){ function f([a, b = 2] = [5]){ return a + b; } return f() === 7 && f([1, 1]) === 2; })()"),
        ("pattern default in a later parameter",
         "(function(){ function f(x, {a} = {a: 2}){ return x + a; } return f(1) === 3; })()"),
        ("nested defaults inside a defaulted pattern",
         "(function(){ function f({a: {b = 3} = {}, c: [d = 4] = []} = {}){ return b * 10 + d; } return f() === 34 && f({a: {b: 1}}) === 14; })()"),
        ("initializers run left to right and see earlier parameters",
         "(function(){ var log = []; function f(a, b = a * 2, {c = b + 1} = (log.push('p'), {}), d = c + 1){ return [a, b, c, d, log.join()].join(); } return f(1) === '1,2,3,4,p'; })()"),
        ("a plain default sees an earlier destructured name",
         "(function(){ function f({a}, b = a + 1){ return b; } return f({a: 1}) === 2; })()"),
        ("evaluation order: pattern default, then its inner defaults, then later params",
         "(function(){ var log = []; function f({a = (log.push('a'), 1)} = (log.push('d'), {}), b = (log.push('b'), 2)){ return log.join(); } return f() === 'd,a,b'; })()"),
        ("arguments is visible to initializers and reflects the call",
         "(function(){ function f(a, b = arguments.length){ return b; } function g(a = 5){ return arguments.length + ':' + arguments[0] + ':' + a; } return f(1) === 1 && g() === '0:undefined:5'; })()"),
        ("non-simple parameters give an unmapped arguments object",
         "(function(){ function f(a, {b} = {b: 2}){ a = 9; return arguments[0]; } return f(1) === 1; })()"),
        ("function length stops at the first initializer",
         "(function(){ return function(a, {b} = {}, c){}.length === 1 && function({a}, b){}.length === 2 && ((a, [b] = []) => 0).length === 1; })()"),
        ("arrow with a defaulted object pattern",
         "(function(){ var f = ({a = 1} = {}) => a; var g = ([a, b = 2] = [1]) => a + b; return f() === 1 && g() === 3; })()"),
        ("async arrow with a pattern parameter",
         "(function(){ var f = async ({a = 1} = {}) => a; var g = async ([x], {y}) => x + y; return typeof f().then === 'function' && typeof g([1], {y: 2}).then === 'function'; })()"),
        ("arrow pattern parameter captures an enclosing block binding",
         "(function(){ var r; { let x = 5; var f = ({a} = {a: 1}) => a + x; r = f(); } return r === 6; })()"),
        ("generator, async function, object method, setter, static method, constructor",
         "(function(){ function* g({a = 1} = {}){ yield a; } async function af({a = 1} = {}){ return a; } var o = { m({a = 1} = {}){ return a; }, set s({a = 2}){ this.v = a; } }; o.s = {}; class C { constructor({a = 3} = {}){ this.a = a; } static m([a] = [4]){ return a; } } return g().next().value === 1 && typeof af().then === 'function' && o.m() === 1 && o.v === 2 && new C().a === 3 && C.m() === 4; })()"),
        ("initializer sees this and new.target",
         "(function(){ var o = { v: 4, m({a = this.v} = {}){ return a; } }; function F({a = new.target === F} = {}){ this.a = a; } return o.m() === 4 && new F().a === true; })()"),
        ("computed key with a default inside a defaulted pattern",
         "(function(){ var k = 'x'; function f({[k]: v = 3} = {}){ return v; } return f() === 3 && f({x: 1}) === 1; })()"),
        ("rest parameter patterns",
         "(function(){ function f(a, ...[b, c]){ return a + b + c; } function g(...{length}){ return length; } var h = (a, ...[b]) => a + b; return f(1, 2, 3) === 6 && g(1, 2, 3) === 3 && h(1, 2) === 3; })()"),
        ("a closure in an initializer shares the parameter binding",
         "(function(){ function f(a, g = () => a){ a = 7; return g(); } return f(1) === 7; })()"),
        ("a missing required pattern argument still throws",
         "(function(){ function f({a}){ return a; } try { f(); return false; } catch (e) { return e instanceof TypeError; } })()"),
        ("catch pattern with nested defaults is block scoped",
         "(function(){ var r; try { throw {p: {}}; } catch ({p: {q = 7} = {}, cq}) { r = q; } return r === 7 && typeof cq === 'undefined'; })()"),
        ("catch pattern with an initializer (QuickJS extension)",
         "(function(){ try { throw undefined; } catch ({a = 1} = {}) { return a === 1; } })()"),
        ("catch pattern bindings are per catch",
         "(function(){ var fs = []; for (var i = 0; i < 2; i++) { try { throw {v: i}; } catch ({v}) { fs.push(function(){ return v; }); } } return fs[0]() === 0 && fs[1]() === 1; })()"),
    ]

    static let typedArrayIterationCases: [(String, String)] = [
        ("[Symbol.iterator] is values, shared by every view type",
         "(function(){ var P = Object.getPrototypeOf(Int8Array.prototype); return typeof new Float32Array(1)[Symbol.iterator] === 'function' && Float32Array.prototype[Symbol.iterator] === Float32Array.prototype.values && Uint8Array.prototype.values === Float64Array.prototype.values && P.hasOwnProperty(Symbol.iterator) && !Float32Array.prototype.hasOwnProperty('values'); })()"),
        ("array destructuring of a Float32Array (apple.com quaternion)",
         "(function(){ var q = new Float32Array(4); q[3] = 1; const [i, r, n, a] = q; return i === 0 && r === 0 && n === 0 && a === 1; })()"),
        ("spread, for-of, Array.from",
         "(function(){ var n = 0; for (var x of new Uint8Array([1, 2, 3])) n += x; return n === 6 && [...new Int16Array([4, 5])].join() === '4,5' && Array.from(new Uint8Array([7, 8])).join() === '7,8'; })()"),
        ("Set, Map and WeakSet consume iterables through the protocol",
         "(function(){ return new Set(new Uint8Array([1, 1, 2])).size === 2 && new Set('abca').size === 3 && new Set(new Set([1, 2])).size === 2 && new Map(new Map([[1, 2]])).get(1) === 2 && new Set((function*(){ yield 1; yield 2; })()).size === 2 && new Set(new Map([[1, 2]]).keys()).has(1); })()"),
        ("Map constructor rejects a non-object entry",
         "(function(){ try { new Map([1].values()); return false; } catch (e) { return e instanceof TypeError; } })()"),
        ("keys and entries",
         "(function(){ return [...new Uint8Array(3).keys()].join() === '0,1,2' && JSON.stringify([...new Uint8Array([9, 8]).entries()]) === '[[0,9],[1,8]]'; })()"),
        ("the iterator is an Array Iterator",
         "(function(){ var it = new Uint8Array(1).values(); return Object.prototype.toString.call(it) === '[object Array Iterator]' && Object.getPrototypeOf(it) === Object.getPrototypeOf([].values()); })()"),
        ("values on a non-typed-array throws",
         "(function(){ try { Uint8Array.prototype.values.call([1]); return false; } catch (e) { return e instanceof TypeError; } })()"),
        ("%TypedArray% intrinsic and prototype chain",
         "(function(){ var TA = Object.getPrototypeOf(Int8Array); return TA !== Function.prototype && TA.name === 'TypedArray' && TA.prototype === Object.getPrototypeOf(Int8Array.prototype) && Object.getPrototypeOf(TA.prototype) === Object.prototype && Object.getPrototypeOf(Float32Array) === TA && new Uint8Array(1) instanceof TA && !Int8Array.hasOwnProperty('from') && typeof TA.from === 'function'; })()"),
        ("%TypedArray% cannot be called or constructed",
         "(function(){ var TA = Object.getPrototypeOf(Int8Array), n = 0; try { TA(); } catch (e) { n += e instanceof TypeError; } try { new TA(); } catch (e) { n += e instanceof TypeError; } return n === 2; })()"),
        ("from and of dispatch on the receiver",
         "(function(){ var f = Float32Array.from([1.5, 2]), u = Uint8Array.of(1, 300); class V extends Float32Array {} return f instanceof Float32Array && f.join() === '1.5,2' && u.join() === '1,44' && V.from([1, 2]).length === 2; })()"),
        ("@@toStringTag is a getter on %TypedArray%.prototype",
         "(function(){ var P = Object.getPrototypeOf(Int8Array.prototype); var d = Object.getOwnPropertyDescriptor(P, Symbol.toStringTag); return typeof d.get === 'function' && d.set === undefined && !d.enumerable && d.configurable && d.get.call({}) === undefined && P[Symbol.toStringTag] === undefined && new BigInt64Array(1)[Symbol.toStringTag] === 'BigInt64Array' && Object.prototype.toString.call(new Float64Array(1)) === '[object Float64Array]' && !Float32Array.prototype.hasOwnProperty(Symbol.toStringTag); })()"),
        ("accessors live on %TypedArray%.prototype and are callable",
         "(function(){ var d = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Int8Array.prototype), 'length'); return typeof d.get === 'function' && d.get.call(new Int8Array(3)) === 3 && !Int8Array.prototype.hasOwnProperty('length'); })()"),
        ("map and filter keep the element type",
         "(function(){ var m = new Uint8Array([1, 2, 3]).map(function(x){ return x * 100; }); var f = new Int32Array([1, -2, 3]).filter(function(x){ return x > 0; }); return m instanceof Uint8Array && m.join() === '100,200,44' && f instanceof Int32Array && f.join() === '1,3'; })()"),
        ("forEach, every, some, find*, reduce*",
         "(function(){ var s = []; var a = new Uint8Array([5, 6, 7]); a.forEach(function(v, i, t){ s.push(v + i, t === a); }); return s.join() === '5,true,7,true,9,true' && a.every(function(x){ return x > 4; }) && a.some(function(x){ return x > 6; }) && a.find(function(x){ return x > 5; }) === 6 && a.findIndex(function(x){ return x > 5; }) === 1 && a.findLast(function(x){ return x > 5; }) === 7 && a.findLastIndex(function(x){ return x > 9; }) === -1 && a.reduce(function(x, y){ return x + y; }) === 18 && a.reduceRight(function(x, y){ return x + '' + y; }, '') === '765'; })()"),
        ("callback methods reject a non-typed-array receiver",
         "(function(){ try { Uint8Array.prototype.forEach.call([1], function(){}); return false; } catch (e) { return e instanceof TypeError; } })()"),
        ("default sort is numeric: NaN last, -0 before +0, exact BigInt",
         "(function(){ var s = Array.from(new Float64Array([3, NaN, 0, -0, -1, 10]).sort()); return Object.is(s[1], -0) && Object.is(s[2], 0) && s[0] === -1 && s[3] === 3 && s[4] === 10 && s[5] !== s[5] && new BigInt64Array([3n, -5n, 1n]).sort().join() === '-5,1,3' && new BigUint64Array([18446744073709551615n, 1n]).sort().join() === '1,18446744073709551615'; })()"),
        ("sort with a comparator, toSorted, toReversed, with",
         "(function(){ var a = new Uint8Array([3, 1, 2]); var b = a.toSorted(); var threw = false; try { a.with(5, 0); } catch (e) { threw = e instanceof RangeError; } return new Int8Array([1, 3, 2]).sort(function(x, y){ return y - x; }).join() === '3,2,1' && a.join() === '3,1,2' && b.join() === '1,2,3' && b instanceof Uint8Array && a.toReversed().join() === '2,1,3' && a.with(-1, 9).join() === '3,1,9' && threw; })()"),
        ("a throwing comparator propagates",
         "(function(){ try { new Uint8Array([1, 2, 3]).sort(function(){ throw new Error('cmp'); }); return false; } catch (e) { return e.message === 'cmp'; } })()"),
        ("join formats numbers and BigInts like Number/BigInt toString",
         "(function(){ return new Float64Array([3, 2.5, NaN, -Infinity]).join() === '3,2.5,NaN,-Infinity' && String(new Float32Array([1])) === '1' && new BigInt64Array([3n, -5n]).join() === '3,-5' && new Uint8Array([1, 2]).join(0) === '102'; })()"),
        ("subclass instances iterate",
         "(function(){ class V extends Float32Array {} var v = new V(2); return v instanceof V && [...v].length === 2 && Object.prototype.toString.call(v) === '[object Float32Array]'; })()"),
    ]

    /// Run `(name, expr)` cases on a plain engine context (no DOM, no
    /// polyfills), asserting each evaluates to `true`.
    mutating func runTrueCases(_ group: String, _ cases: [(String, String)]) {
        let (_, ctx) = makeCtx()
        for (name, js) in cases {
            JeffJSStackDiag.currentLabel = "\(group): \(name)"
            let result = ctx.eval(input: js, filename: "<\(group)>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            if result.isException {
                let exc = ctx.getException()
                assert(false, "\(group): \(name) threw \(ctx.toSwiftString(exc) ?? "?")")
                exc.freeValue()
            } else {
                let ok = result.isBool && result.toBool()
                assert(ok, "\(group): \(name) -> \(ctx.toSwiftString(result) ?? "?")")
            }
            result.freeValue()
        }
    }

    mutating func testParameterPatterns() {
        runTrueCases("ParameterPatterns", JeffJSTestRunner.parameterPatternCases)
    }

    mutating func testTypedArrayIteration() {
        runTrueCases("TypedArrayIteration", JeffJSTestRunner.typedArrayIterationCases)
    }

    // MARK: - HyperlinkReflection (DOM bridge)

    static let hyperlinkReflectionCases: [(String, String)] = [
        // apple.com localeswitcher reads link.hreflang.
        ("link.hreflang and a.hreflang reflect",
         "(function(){ var l = document.createElement('link'); l.setAttribute('hreflang', 'en-US'); var a = document.createElement('a'); var before = a.hreflang; a.hreflang = 'fr'; return l.hreflang === 'en-US' && before === '' && a.getAttribute('hreflang') === 'fr' && a.hreflang === 'fr'; })()"),
        ("target, download, ping reflect as strings",
         "(function(){ var a = document.createElement('a'); a.target = '_blank'; a.download = 'f.txt'; a.ping = 'https://p.example/'; var f = document.createElement('form'); f.setAttribute('target', 'fr'); return a.getAttribute('target') === '_blank' && a.target === '_blank' && a.getAttribute('download') === 'f.txt' && a.download === 'f.txt' && a.ping === 'https://p.example/' && f.target === 'fr' && document.createElement('area').download === ''; })()"),
        ("setting null stringifies (DOMString)",
         "(function(){ var a = document.createElement('a'); a.target = null; return a.getAttribute('target') === 'null'; })()"),
        ("referrerPolicy is limited to known values",
         "(function(){ var a = document.createElement('a'); var r0 = a.referrerPolicy; a.setAttribute('referrerpolicy', 'No-Referrer'); var r1 = a.referrerPolicy; a.referrerPolicy = 'bogus'; var r2 = a.referrerPolicy; var img = document.createElement('img'); img.referrerPolicy = 'origin'; return r0 === '' && r1 === 'no-referrer' && r2 === '' && a.getAttribute('referrerpolicy') === 'bogus' && img.referrerPolicy === 'origin'; })()"),
        ("rel and relList on a and link",
         "(function(){ var a = document.createElement('a'); a.rel = 'noopener external'; var l = document.createElement('link'); l.setAttribute('rel', 'stylesheet'); return a.relList.contains('noopener') && a.relList.length === 2 && l.rel === 'stylesheet' && l.relList.contains('stylesheet'); })()"),
        ("URL decomposition of an absolute href",
         "(function(){ var a = document.createElement('a'); a.href = 'HTTPS://Example.COM:8443/p/q.html?x=1&y=2#frag'; return a.href === 'https://example.com:8443/p/q.html?x=1&y=2#frag' && a.protocol === 'https:' && a.host === 'example.com:8443' && a.hostname === 'example.com' && a.port === '8443' && a.pathname === '/p/q.html' && a.search === '?x=1&y=2' && a.hash === '#frag' && a.origin === 'https://example.com:8443'; })()"),
        ("default port dropped, empty path becomes /",
         "(function(){ var a = document.createElement('a'); a.href = 'http://example.com:80'; return a.href === 'http://example.com/' && a.port === '' && a.host === 'example.com' && a.pathname === '/' && a.search === '' && a.hash === ''; })()"),
        ("relative href resolves against the document URL",
         "(function(){ var a = document.createElement('a'); a.setAttribute('href', 'x/y?z#w'); return a.href === 'https://www.example.com/shop/buy/x/y?z#w' && a.getAttribute('href') === 'x/y?z#w' && a.hash === '#w' && a.search === '?z'; })()"),
        ("component setters rewrite href",
         "(function(){ var a = document.createElement('a'); a.href = 'https://example.com/a?b#c'; a.hash = 'top'; a.search = '?q=1'; a.pathname = 'dir/file'; a.hostname = 'Other.Example'; a.port = '8080'; a.protocol = 'http:'; var ok1 = a.href === 'http://other.example:8080/dir/file?q=1#top'; a.host = 'h.example:9000'; a.search = ''; a.hash = ''; return ok1 && a.href === 'http://h.example:9000/dir/file' && a.getAttribute('href') === a.href; })()"),
        ("special and non-special schemes do not convert",
         "(function(){ var a = document.createElement('a'); a.href = 'https://example.com/'; a.protocol = 'mailto'; return a.protocol === 'https:'; })()"),
        ("no href: decomposition reads empty, setters do nothing",
         "(function(){ var a = document.createElement('a'); var ok = a.href === '' && a.protocol === ':' && a.host === '' && a.pathname === '' && a.origin === ''; a.hash = 'x'; return ok && a.getAttribute('href') === null; })()"),
        ("mailto and javascript hrefs",
         "(function(){ var a = document.createElement('a'); a.href = 'mailto:someone@example.com'; var m = a.protocol === 'mailto:' && a.pathname === 'someone@example.com' && a.host === '' && a.origin === 'null'; a.href = 'javascript:void(0)'; return m && a.protocol === 'javascript:'; })()"),
        ("area decomposes, link resolves href only",
         "(function(){ var ar = document.createElement('area'); ar.href = 'https://example.com/m?k#h'; var l = document.createElement('link'); l.setAttribute('href', '/s.css'); return ar.pathname === '/m' && ar.hash === '#h' && l.href === 'https://www.example.com/s.css' && l.hash === undefined; })()"),
        ("other elements keep attribute passthrough",
         "(function(){ var d = document.createElement('div'); var u = d.hash === undefined && d.hreflang === undefined && d.download === undefined; d.target = 't'; return u && d.getAttribute('target') === 't' && d.target === 't' && document.createElement('div').href !== undefined; })()"),
        ("base element changes the document base URL",
         "(function(){ var head = document.head; var b = document.createElement('base'); b.setAttribute('href', 'https://base.example/dir/'); head.insertBefore(b, head.firstChild); var a = document.createElement('a'); a.setAttribute('href', 'page.html'); var r = a.href; head.removeChild(b); return r === 'https://base.example/dir/page.html' && a.href !== r; })()"),
    ]

    mutating func testHyperlinkReflection() {
        var outcomes: [(Bool, String)] = []
        let run = {
            MainActor.assumeIsolated {
                let env = JeffJSEnvironment(configuration: .init(
                    baseURL: URL(string: "https://www.example.com/shop/buy/index.html")!))
                for (name, js) in JeffJSTestRunner.hyperlinkReflectionCases {
                    switch env.eval(js, filename: "<hyperlink-reflection>") {
                    case .success(let value):
                        outcomes.append((value == "true", "HyperlinkReflection: \(name) -> \(value ?? "undefined")"))
                    case .exception(let message):
                        outcomes.append((false, "HyperlinkReflection: \(name) threw \(message)"))
                    }
                }
            }
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.sync(execute: run) }
        for (ok, message) in outcomes { assert(ok, message) }
    }
}
