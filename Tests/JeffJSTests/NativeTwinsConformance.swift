// NativeTwinsConformance.swift
// JeffJS — "NativeTwins": native twins of known library functions
// (Builtins/Twins/JeffJSNativeTwins.swift, jbachand/JeffJS issue #3).
//
// Differential: every case runs on Home Depot's own copies of deepmerge
// (vendor-data-sources, minified inside a function, and vendor-sui-atomic,
// strict, other names) with the twins on and off; the printed results
// (keys, order, attributes, prototypes, identities, getter/proxy/setter
// side effects, exceptions) must be equal, and the twin must have served
// calls. Patched builtins and page-reassigned members must run the bytecode.
// The 300-level case is the one difference: the bytecode can run out of
// stack where the twin (and Safari) does not; it only has to succeed.

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let nativeTwinsVariants = #"""
var Rr,Pi;function nl(){if(Pi)return Rr;Pi=1;var t=function(P){return e(P)&&!r(P)};function e(w){return!!w&&typeof w=="object"}function r(w){var P=Object.prototype.toString.call(w);return P==="[object RegExp]"||P==="[object Date]"||o(w)}var n=typeof Symbol=="function"&&Symbol.for,i=n?Symbol.for("react.element"):60103;function o(w){return w.$$typeof===i}function s(w){return Array.isArray(w)?[]:{}}function u(w,P){return P.clone!==!1&&P.isMergeableObject(w)?E(s(w),w,P):w}function f(w,P,A){return w.concat(P).map(function(k){return u(k,A)})}function h(w,P){if(!P.customMerge)return E;var A=P.customMerge(w);return typeof A=="function"?A:E}function l(w){return Object.getOwnPropertySymbols?Object.getOwnPropertySymbols(w).filter(function(P){return Object.propertyIsEnumerable.call(w,P)}):[]}function y(w){return Object.keys(w).concat(l(w))}function v(w,P){try{return P in w}catch{return!1}}function g(w,P){return v(w,P)&&!(Object.hasOwnProperty.call(w,P)&&Object.propertyIsEnumerable.call(w,P))}function b(w,P,A){var k={};return A.isMergeableObject(w)&&y(w).forEach(function(N){k[N]=u(w[N],A)}),y(P).forEach(function(N){g(w,N)||(v(w,N)&&A.isMergeableObject(P[N])?k[N]=h(N,A)(w[N],P[N],A):k[N]=u(P[N],A))}),k}function E(w,P,A){A=A||{},A.arrayMerge=A.arrayMerge||f,A.isMergeableObject=A.isMergeableObject||t,A.cloneUnlessOtherwiseSpecified=u;var k=Array.isArray(P),N=Array.isArray(w),S=k===N;return S?k?A.arrayMerge(w,P,A):b(w,P,A):u(P,A)}E.all=function(P,A){if(!Array.isArray(P))throw new Error("first argument should be an array");return P.reduce(function(k,N){return E(k,N,A)},{})};var D=E;return Rr=D,Rr}
var DM_NL=nl();
var DM_SUI=(function(){'use strict';var Fa=function(t){return Da(t)&&!$a(t)};function Da(e){return!!e&&typeof e=="object"}function $a(e){var t=Object.prototype.toString.call(e);return t==="[object RegExp]"||t==="[object Date]"||Ha(e)}var za=typeof Symbol=="function"&&Symbol.for,Ba=za?Symbol.for("react.element"):60103;function Ha(e){return e.$$typeof===Ba}function Va(e){return Array.isArray(e)?[]:{}}function qe(e,t){return t.clone!==!1&&t.isMergeableObject(e)?Ae(Va(e),e,t):e}function Wa(e,t,n){return e.concat(t).map(function(s){return qe(s,n)})}function Ua(e,t){if(!t.customMerge)return Ae;var n=t.customMerge(e);return typeof n=="function"?n:Ae}function qa(e){return Object.getOwnPropertySymbols?Object.getOwnPropertySymbols(e).filter(function(t){return Object.propertyIsEnumerable.call(e,t)}):[]}function Ks(e){return Object.keys(e).concat(qa(e))}function Xr(e,t){try{return t in e}catch{return!1}}function Ka(e,t){return Xr(e,t)&&!(Object.hasOwnProperty.call(e,t)&&Object.propertyIsEnumerable.call(e,t))}function Ga(e,t,n){var s={};return n.isMergeableObject(e)&&Ks(e).forEach(function(i){s[i]=qe(e[i],n)}),Ks(t).forEach(function(i){Ka(e,i)||(Xr(e,i)&&n.isMergeableObject(t[i])?s[i]=Ua(i,n)(e[i],t[i],n):s[i]=qe(t[i],n))}),s}function Ae(e,t,n){n=n||{},n.arrayMerge=n.arrayMerge||Wa,n.isMergeableObject=n.isMergeableObject||Fa,n.cloneUnlessOtherwiseSpecified=qe;var s=Array.isArray(t),i=Array.isArray(e),o=s===i;return o?s?n.arrayMerge(e,t,n):Ga(e,t,n):qe(t,n)}Ae.all=function(t,n){if(!Array.isArray(t))throw new Error("first argument should be an array");return t.reduce(function(s,i){return Ae(s,i,n)},{})};return Ae;})();

"""#

    static let nativeTwinsCases = #"""
// Differential cases: run with twins on and off; outputs must be equal.
function show(v, seen) {
  seen = seen || [];
  if (v === null || typeof v !== "object") {
    if (typeof v === "symbol") return "sym(" + String(v.description) + ")";
    if (typeof v === "function") return "fn";
    if (typeof v === "number" && Object.is(v, -0)) return "-0";
    return typeof v + ":" + String(v);
  }
  var idx = seen.indexOf(v); if (idx >= 0) return "#" + idx;
  seen.push(v);
  var proto = Object.getPrototypeOf(v);
  var p = proto === Object.prototype ? "O" : proto === Array.prototype ? "A" : proto === null ? "N" : "P(" + Object.prototype.toString.call(v) + ")";
  var keys = Reflect.ownKeys(v);
  var parts = keys.map(function (k) {
    var d = Object.getOwnPropertyDescriptor(v, k);
    var flags = (d.enumerable ? "e" : "") + (d.writable ? "w" : "") + (d.configurable ? "c" : "") + ("get" in d ? "G" : "");
    return (typeof k === "symbol" ? "@" + String(k.description) : k) + "/" + flags + "=" + ("value" in d ? show(d.value, seen) : "acc");
  });
  return p + "{" + parts.join(",") + "}";
}
var OUT = [];
function rec(name, fn) {
  var r;
  try { r = show(fn()); } catch (e) { r = "THROW " + (e && e.name) + ": " + (e && e.message); }
  OUT.push(name + " => " + r);
}
var REACT = { $$typeof: Symbol.for("react.element"), type: "div", props: {} };
var D = new Date(5), RE = /x/g, SYM = Symbol("s");
var shared = { s: 1 };
var cases = [
  ["plain", function (m) { return m({ a: 1, b: { c: 2 } }, { b: { d: 3 }, e: [1, 2] }); }],
  ["arrays concat", function (m) { return m([1, { x: 1 }], [2, { y: 2 }]); }],
  ["array vs object", function (m) { return m([1], { a: 1 }); }],
  ["object vs array", function (m) { return m({ a: 1 }, [1, 2]); }],
  ["undefined target", function (m) { return m(undefined, { a: { b: 1 } }); }],
  ["null target", function (m) { return m(null, { a: 1 }); }],
  ["string target", function (m) { return m("ab", { 0: "x", a: 1 }); }],
  ["number target", function (m) { return m(5, { a: 1 }); }],
  ["integer keys order", function (m) { return m({ b: 1, 2: 2, a: 3, 1: 4 }, { 0: 0, c: 5, 1: 9 }); }],
  ["proto keys skipped", function (m) { return m({}, { constructor: 1, toString: 2, hasOwnProperty: 3, valueOf: { x: 1 }, ok: 4 }); }],
  ["clone proto keys", function (m) { return m({ a: 1 }, { a: { constructor: 5, z: 1 } }); }],
  ["__proto__ own key", function (m) { return m({}, JSON.parse('{"__proto__":{"polluted":1},"x":1}')); }],
  ["__proto__ primitive", function (m) { return m({}, JSON.parse('{"__proto__":5,"x":1}')); }],
  ["dates and regexps kept", function (m) { var r = m({ d: { a: 1 } }, { d: D, r: RE }); return [r.d === D, r.r === RE, show(r)]; }],
  ["react element kept", function (m) { var r = m({}, { el: REACT, nested: { el: REACT } }); return [r.el === REACT, r.nested.el === REACT]; }],
  ["symbols", function (m) { var s = {}; s[SYM] = { q: 1 }; s.k = 1; var e = {}; e[SYM] = { p: 2 }; return m(e, s); }],
  ["non-enumerable source", function (m) { var s = { a: 1 }; Object.defineProperty(s, "h", { value: 2, enumerable: false }); return m({}, s); }],
  ["non-enumerable target key", function (m) { var e = { a: 1 }; Object.defineProperty(e, "h", { value: { x: 1 }, enumerable: false }); return m(e, { h: { y: 1 }, a: 2 }); }],
  ["getter in source", function (m) { var n = 0; var s = { get g() { n++; return { v: n }; } }; var r = m({}, s); return [n, show(r)]; }],
  ["getter in target", function (m) { var n = 0; var e = { get g() { n++; return { v: 1 }; } }; var r = m(e, { g: { w: 1 } }); return [n, show(r)]; }],
  ["proxy source", function (m) { var log = []; var p = new Proxy({ a: 1 }, { ownKeys: function (t) { log.push("ownKeys"); return Reflect.ownKeys(t); } }); var r = m({}, p); return [log.join(), show(r)]; }],
  ["proxy target", function (m) { var log = []; var p = new Proxy({ a: { x: 1 } }, { has: function (t, k) { log.push("has " + String(k)); return k in t; } }); var r = m(p, { a: { y: 1 } }); return [log.join(), show(r)]; }],
  ["class instance source", function (m) { function C() { this.a = 1; } C.prototype.b = 2; return m({}, new C()); }],
  ["class instance target", function (m) { function C() { this.a = { x: 1 }; } C.prototype.b = { y: 1 }; return m(new C(), { a: { z: 1 }, b: { w: 1 } }); }],
  ["null-proto source", function (m) { var s = Object.create(null); s.a = { b: 1 }; return m({}, s); }],
  ["map leaf", function (m) { var mp = new Map([[1, 2]]); var r = m({}, { m: mp }); return [r.m === mp, show(r)]; }],
  ["error leaf", function (m) { var er = new Error("x"); var r = m({}, { e: er }); return [r.e === er, show(r)]; }],
  ["function leaf", function (m) { var f = function () {}; var r = m({}, { f: f }); return r.f === f; }],
  ["holes", function (m) { return m([1, , 3], [, 5]); }],
  ["array own prop", function (m) { var a = [1, 2]; a.extra = 1; return m([], a); }],
  ["nested arrays", function (m) { return m({ a: [[1], { b: [2] }] }, { a: [[3]] }); }],
  ["shared subobject", function (m) { var r = m({}, { a: shared, b: shared }); return [r.a === shared, r.a === r.b, show(r)]; }],
  ["same in both", function (m) { var o = { x: { y: 1 } }; return m(o, o); }],
  ["options clone false", function (m) { var o = { x: 1 }; var r = m({}, { o: o }, { clone: false }); return r.o === o; }],
  ["options arrayMerge", function (m) { return m({ a: [1] }, { a: [2] }, { arrayMerge: function (d, s) { return s; } }); }],
  ["primitive source", function (m) { return m({ a: 1 }, 5); }],
  ["string source", function (m) { return m({ a: 1 }, "xy"); }],
  ["undefined source", function (m) { return m({ a: 1 }, undefined); }],
  ["frozen source", function (m) { return m({}, Object.freeze({ a: Object.freeze({ b: 1 }) })); }],
  ["toStringTag Date", function (m) { var o = { a: 1 }; o[Symbol.toStringTag] = "Date"; var r = m({}, { o: o }); return r.o === o; }],
  ["toStringTag other", function (m) { var o = { a: 1 }; o[Symbol.toStringTag] = "Foo"; var r = m({}, { o: o }); return [r.o === o, show(r)]; }],
  ["toStringTag getter", function (m) { var n = 0; var o = { a: 1 }; Object.defineProperty(o, Symbol.toStringTag, { get: function () { n++; return "X"; } }); var r = m({}, { o: o }); return [n, show(r)]; }],
  ["$$typeof getter", function (m) { var n = 0; var o = { a: 1 }; Object.defineProperty(o, "$$typeof", { get: function () { n++; return 1; }, enumerable: false }); var r = m({}, { o: o }); return [n, show(r)]; }],
  ["deep", function (m) { var s = {}, c = s; for (var i = 0; i < 300; i++) { c.n = {}; c = c.n; } c.end = 1; var r = m({}, s); var d = 0; while (r.n) { r = r.n; d++; } return d + ":" + r.end; }],
  ["very deep", function (m) { var s = {}, c = s; for (var i = 0; i < 2000; i++) { c.n = {}; c = c.n; } var r = m({}, s); var d = 0; while (r.n) { r = r.n; d++; } return d; }],
  ["cyclic", function (m) { var s = { a: 1 }; s.self = s; return m({}, s); }],
  ["big", function (m) { var a = {}, b = {}; for (var i = 0; i < 200; i++) { a["k" + i] = { v: i, l: [i] }; b["k" + (i * 2)] = { w: i }; } return m(a, b); }],
  ["frozen target merge", function (m) { var e = Object.freeze({ a: { x: 1 } }); return m(e, { a: { y: 2 } }); }],
  ["target array nested object", function (m) { return m({ a: [1] }, { a: { b: 1 } }); }],
  ["numbers/negzero", function (m) { return m({ a: -0 }, { b: NaN, c: -0 }); }],
];
function runAll(label, m) {
  for (var i = 0; i < cases.length; i++) rec(label + " " + cases[i][0], function () { return cases[i][1](m); });
}
function patched(label, m) {
  // Patching a builtin the library calls must give the patched behaviour.
  var orig = Array.prototype.concat;
  Array.prototype.concat = function () { var r = orig.apply(this, arguments); r.push("patched"); return r; };
  rec(label + " patched concat", function () { return m([1], [2]); });
  Array.prototype.concat = orig;
  var ok = Object.keys;
  Object.keys = function (o) { return ok(o).reverse(); };
  rec(label + " patched keys", function () { return m({}, { a: 1, b: 2, c: { d: 1, e: 2 } }); });
  Object.keys = ok;
  Object.defineProperty(Object.prototype, "zz", { set: function (v) { OUT.push("setter ran"); }, configurable: true });
  rec(label + " Object.prototype setter", function () { return m({}, { zz: 1, a: 2 }); });
  delete Object.prototype.zz;
}

"""#

    mutating func testNativeTwins() {
        let group = "NativeTwins"
        JeffJSStackDiag.currentLabel = group
        let (rt, ctx) = makeCtx()
        let saved = rt.nativeTwins
        defer { rt.nativeTwins = saved }
        func run(_ js: String, _ tag: String) -> String {
            let r = ctx.eval(input: js, filename: "<eval><\(group)-\(tag)>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            if r.isException {
                let e = ctx.getException()
                defer { e.freeValue() }
                return "!" + (ctx.toSwiftString(e) ?? "?")
            }
            defer { r.freeValue() }
            return ctx.toSwiftString(r) ?? "?"
        }
        // The shipped table is what this compiler makes of the references.
        let built = JeffJSNativeTwins.buildTable(ctx)
        var builtSet = Set<String>(), shipped = Set<String>()
        for (i, m) in built.table.members.enumerated() {
            guard let h = built.hashes[i], let k = built.keys[i] else { continue }
            builtSet.insert("\(h) \(k) \(JeffJSNativeTwins.families[m.family].name) \(m.role)")
        }
        for e in JeffJSTwinTableData.entries { shipped.insert("\(e.hash) \(e.prefilter) \(e.family) \(e.role)") }
        assert(!builtSet.isEmpty && builtSet == shipped,
               "\(group): JeffJSTwinTableData.swift is stale: swift run -c release jeffjs-cli --twin-table > Sources/JeffJS/Builtins/Twins/JeffJSTwinTableData.swift")
        let setup = run(Self.nativeTwinsVariants + Self.nativeTwinsCases + "'ok'", "setup")
        assert(setup == "ok", "\(group): setup -> \(setup)")
        let body = """
            OUT = []; runAll("nl", DM_NL); runAll("sui", DM_SUI); patched("nl", DM_NL);
            OUT.filter(function (l) { return !/ deep => /.test(l); }).join("\\n")
            """
        rt.nativeTwins = true
        let h0 = rt.twinStats.hits
        let on = run(body, "on")
        let served = rt.twinStats.hits - h0
        rt.nativeTwins = false
        let off = run(body, "off")
        assert(served > 50, "\(group): twin served \(served) calls")
        assert(on == off, "\(group): twin and bytecode differ")
        if on != off {
            let a = on.split(separator: "\n"), b = off.split(separator: "\n")
            for (x, y) in zip(a, b) where x != y { print("[\(group)] twin: \(x)\n[\(group)] code: \(y)") }
        }
        rt.nativeTwins = true
        let deep = run("OUT = []; rec('d', function(){ return cases.filter(function(c){ return c[0] === 'deep'; })[0][1](DM_NL); }); OUT[0]", "deep")
        assert(deep == "d => string:300:1", "\(group): 300 levels -> \(deep)")
        // A member the page replaced: its code runs instead of the twin.
        let famSrc = "var __twinFam = (function(){" + JeffJSTwinDeepmerge.reference
            + "return { dm: yC, swap: function(){ var old = $7; $7 = function(e,t){ globalThis.__twinU = (globalThis.__twinU||0) + 1; return old(e,t); }; } }; })(); 'ok'"
        assert(run(famSrc, "fam") == "ok", "\(group): reference family")
        let h1 = rt.twinStats.hits
        let before = run("JSON.stringify(__twinFam.dm({ a: 1 }, { b: { c: 2 } }))", "fam1")
        assert(before == "{\"a\":1,\"b\":{\"c\":2}}" && rt.twinStats.hits == h1 + 1,
               "\(group): reference copy served -> \(before)")
        let after = run("__twinFam.swap(); JSON.stringify(__twinFam.dm({ a: 1 }, { b: { c: 2 } })) + ':' + globalThis.__twinU", "fam2")
        assert(after == "{\"a\":1,\"b\":{\"c\":2}}:3" && rt.twinStats.hits == h1 + 1,
               "\(group): replaced member -> \(after)")
    }
}
