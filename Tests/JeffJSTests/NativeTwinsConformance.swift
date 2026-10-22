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

    /// Home Depot's own copies of Babel's objectSpread2 (Page build), Apollo's
    /// cloneDeep and @wry/equality (vendor-apollo build).
    static let nativeTwinsVariants2 = #"""
var SPREAD_X=(function(){'use strict';function moe(e,t){var r=Object.keys(e);if(Object.getOwnPropertySymbols){var n=Object.getOwnPropertySymbols(e);t&&(n=n.filter(function(a){return Object.getOwnPropertyDescriptor(e,a).enumerable})),r.push.apply(r,n)}return r}function ul(e){for(var t=1;t<arguments.length;t++){var r=arguments[t]!=null?arguments[t]:{};t%2?moe(Object(r),!0).forEach(function(n){_5e(e,n,r[n])}):Object.getOwnPropertyDescriptors?Object.defineProperties(e,Object.getOwnPropertyDescriptors(r)):moe(Object(r)).forEach(function(n){Object.defineProperty(e,n,Object.getOwnPropertyDescriptor(r,n))})}return e}function _5e(e,t,r){return(t=A5e(t))in e?Object.defineProperty(e,t,{value:r,enumerable:!0,configurable:!0,writable:!0}):e[t]=r,e}function A5e(e){var t=P5e(e,"string");return typeof t=="symbol"?t:t+""}function P5e(e,t){if(typeof e!="object"||!e)return e;var r=e[Symbol.toPrimitive];if(r!==void 0){var n=r.call(e,t||"default");if(typeof n!="object")return n;throw new TypeError("@@toPrimitive must return a primitive value.")}return(t==="string"?String:Number)(e)}return ul;})();
var CLONE_X=(function(){'use strict';var fs=Object.prototype.toString;function hs(r){return xt(r)}function xt(r,e){switch(fs.call(r)){case"[object Array]":{if(e=e||new Map,e.has(r))return e.get(r);var t=r.slice(0);return e.set(r,t),t.forEach(function(i,s){t[s]=xt(i,e)}),t}case"[object Object]":{if(e=e||new Map,e.has(r))return e.get(r);var n=Object.create(Object.getPrototypeOf(r));return e.set(r,n),Object.keys(r).forEach(function(i){n[i]=xt(r[i],e)}),n}default:return r}}return hs;})();
var EQ_X=(function(){'use strict';var yn=Object.prototype,wr=yn.toString,Ns=yn.hasOwnProperty,xr=Function.prototype.toString,Nt=new Map;function F(r,e){try{return Ct(r,e)}finally{Nt.clear()}}function Ct(r,e){if(r===e)return!0;var t=wr.call(r),n=wr.call(e);if(t!==n)return!1;switch(t){case"[object Array]":if(r.length!==e.length)return!1;case"[object Object]":{if(Ir(r,e))return!0;var i=Dr(r),s=Dr(e),a=i.length;if(a!==s.length)return!1;for(var o=0;o<a;++o)if(!Ns.call(e,i[o]))return!1;for(var o=0;o<a;++o){var u=i[o];if(!Ct(r[u],e[u]))return!1}return!0}case"[object Error]":return r.name===e.name&&r.message===e.message;case"[object Number]":if(r!==r)return e!==e;case"[object Boolean]":case"[object Date]":return+r==+e;case"[object RegExp]":case"[object String]":return r==""+e;case"[object Map]":case"[object Set]":{if(r.size!==e.size)return!1;if(Ir(r,e))return!0;for(var c=r.entries(),l=t==="[object Map]";;){var f=c.next();if(f.done)break;var h=f.value,v=h[0],m=h[1];if(!e.has(v)||l&&!Ct(m,e.get(v)))return!1}return!0}case"[object AsyncFunction]":case"[object GeneratorFunction]":case"[object AsyncGeneratorFunction]":case"[object Function]":{var y=xr.call(r);return y!==xr.call(e)?!1:!As(y,Rs)}}return!1}function Dr(r){return Object.keys(r).filter(Cs,r)}function Cs(r){return this[r]!==void 0}var Rs="{ [native code] }";function As(r,e){var t=r.length-e.length;return t>=0&&r.indexOf(e,t)===t}function Ir(r,e){var t=Nt.get(r);if(t){if(t.has(e))return!0}else Nt.set(r,t=new Set);return t.add(e),!1}return F;})();

"""#

    static let nativeTwinsCases2 = #"""
// Differential cases for objectSpread2 / cloneDeep / @wry/equality.
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
  return p + (Object.isExtensible(v) ? "" : "!x") + "{" + parts.join(",") + "}";
}
var OUT = [];
function rec(name, fn) { var r; try { r = show(fn()); } catch (e) { r = "THROW " + (e && e.name) + ": " + (e && e.message); } OUT.push(name + " => " + r); }
var SYM = Symbol("s"), D = new Date(5);
var spreadCases = [
  ["basic", function (s) { return s(s({}, { a: 1, b: 2 }), {}, { c: 3 }); }],
  ["overwrite", function (s) { return s({ a: 1, b: 2 }, { b: 3, c: 4 }); }],
  ["int keys", function (s) { return s({ z: 1 }, { 2: "b", 1: "a", x: 0 }); }],
  ["symbols", function (s) { var o = { a: 1 }; o[SYM] = 2; Object.defineProperty(o, Symbol("hidden"), { value: 3, enumerable: false }); return s({}, o); }],
  ["non-enumerable odd", function (s) { var o = { a: 1 }; Object.defineProperty(o, "h", { value: 2, enumerable: false }); return s({}, o); }],
  ["non-enumerable even", function (s) { var o = { a: 1 }; Object.defineProperty(o, "h", { value: 2, enumerable: false, writable: true }); return s({}, {}, o); }],
  ["even then odd", function (s) { var o = {}; Object.defineProperty(o, "h", { value: 2, enumerable: false, configurable: true }); return s({}, {}, o, { h: 5 }); }],
  ["nullish", function (s) { return s({ a: 1 }, null, undefined, 5, true); }],
  ["string source", function (s) { return s({}, "ab"); }],
  ["array source", function (s) { return s({}, [1, 2]); }],
  ["proto key", function (s) { return s({}, { toString: 1, constructor: 2 }); }],
  ["__proto__ key", function (s) { return s({}, JSON.parse('{"__proto__":{"x":1},"y":2}')); }],
  ["frozen target prop", function (s) { var t = {}; Object.defineProperty(t, "a", { value: 1, configurable: false, writable: true, enumerable: true }); return s(t, { a: 2 }); }],
  ["non-writable configurable", function (s) { var t = {}; Object.defineProperty(t, "a", { value: 1, configurable: true, writable: false }); return s(t, { a: 2 }); }],
  ["sealed target", function (s) { return s(Object.preventExtensions({ a: 1 }), { b: 2 }); }],
  ["getter source", function (s) { var n = 0; var o = { get g() { n++; return 7; } }; var r = s({}, o); return [n, show(r)]; }],
  ["setter target", function (s) { var log = []; var t = { set q(v) { log.push(v); } }; var r = s(t, { q: 1 }); return [log.join(), show(r)]; }],
  ["proto setter target", function (s) { var log = []; var p = { set q(v) { log.push(v); } }; var t = Object.create(p); var r = s(t, { q: 1, w: 2 }); return [log.join(), show(r)]; }],
  ["proxy source", function (s) { return s({}, new Proxy({ a: 1 }, {})); }],
  ["same object", function (s) { var o = { a: 1 }; return s(o, o); }],
  ["class instance source", function (s) { function C() { this.a = 1; } C.prototype.b = 2; return s({}, new C()); }],
  ["many keys", function (s) { var o = {}; for (var i = 0; i < 100; i++) o["k" + i] = i; return s(s({}, o), { k5: "x" }); }],
  ["target array", function (s) { return s([], { a: 1 }); }],
  ["no args", function (s) { return s({ a: 1 }); }],
];
var Q = { x: 1 };
var cloneCases = [
  ["primitive", function (c) { return [c(1), c("s"), c(null), c(undefined)]; }],
  ["nested", function (c) { return c({ a: [1, { b: 2 }], c: { d: [3] } }); }],
  ["shared", function (c) { var s = { v: 1 }; var r = c({ a: s, b: s }); return [r.a === r.b, r.a !== s, show(r)]; }],
  ["cycle", function (c) { var o = { a: 1 }; o.self = o; var r = c(o); return [r.self === r, r !== o]; }],
  ["array cycle", function (c) { var a = [1]; a.push(a); var r = c(a); return [r[1] === r, r !== a]; }],
  ["class instance", function (c) { function K() { this.a = 1; } K.prototype.m = function () {}; var r = c(new K()); return [Object.getPrototypeOf(r) === K.prototype, show(r)]; }],
  ["null proto", function (c) { var o = Object.create(null); o.a = { b: 1 }; return c(o); }],
  ["date leaf", function (c) { var r = c({ d: D }); return r.d === D; }],
  ["map leaf", function (c) { var m = new Map(); return c({ m: m }).m === m; }],
  ["holes", function (c) { return c([1, , 3]); }],
  ["symbol key skipped", function (c) { var o = { a: 1 }; o[SYM] = 2; return c(o); }],
  ["non-enumerable skipped", function (c) { var o = { a: 1 }; Object.defineProperty(o, "h", { value: 2 }); return c(o); }],
  ["getter", function (c) { var n = 0; var r = c({ get g() { n++; return 1; } }); return [n, show(r)]; }],
  ["proto setter", function (c) { var log = []; function K() { this.q = 1; } Object.defineProperty(K.prototype, "q", { set: function (v) { log.push(v); }, get: function () { return 9; }, configurable: true }); var k = Object.create(K.prototype); Object.defineProperty(k, "q", { value: 1, enumerable: true }); var r = c(k); return [log.join(), show(r)]; }],
  ["proto readonly", function (c) { var p = {}; Object.defineProperty(p, "a", { value: 0, writable: false }); var o = Object.create(p); Object.defineProperty(o, "a", { value: 1, enumerable: true }); try { return c(o); } catch (e) { return "throw " + e.name; } }],
  ["frozen source", function (c) { return c(Object.freeze({ a: Object.freeze([1]) })); }],
  ["toStringTag", function (c) { var o = { a: 1 }; o[Symbol.toStringTag] = "Foo"; return c(o) === o; }],
  ["array with prop", function (c) { var a = [1]; a.x = 2; return c(a); }],
  ["big", function (c) { var o = { items: [] }; for (var i = 0; i < 200; i++) o.items.push({ id: i, tags: ["a", "b"], meta: { n: i } }); return c(o); }],
  ["deep", function (c) { var o = {}, x = o; for (var i = 0; i < 300; i++) { x.n = {}; x = x.n; } var r = c(o); var d = 0; while (r.n) { r = r.n; d++; } return d; }],
];
var eqCases = [
  ["prims", function (e) { return [e(1, 1), e(1, 2), e(NaN, NaN), e(0, -0), e("a", "a"), e("a", "b"), e(true, false), e(null, undefined), e(undefined, undefined), e(1, "1")]; }],
  ["objects", function (e) { return [e({ a: 1 }, { a: 1 }), e({ a: 1 }, { a: 2 }), e({ a: 1 }, { b: 1 }), e({ a: 1, b: undefined }, { a: 1 }), e({ a: 1 }, { a: 1, b: undefined })]; }],
  ["nested", function (e) { return [e({ a: [1, { b: 2 }] }, { a: [1, { b: 2 }] }), e({ a: [1, { b: 2 }] }, { a: [1, { b: 3 }] })]; }],
  ["arrays", function (e) { return [e([1, 2], [1, 2]), e([1, 2], [1, 2, 3]), e([undefined, 1], [undefined, 1]), e([undefined], [null]), e([], {})]; }],
  ["cycles", function (e) { var a = { x: 1 }; a.self = a; var b = { x: 1 }; b.self = b; var c = { x: 2 }; c.self = c; return [e(a, b), e(a, c)]; }],
  ["key order", function (e) { return e({ a: 1, b: 2 }, { b: 2, a: 1 }); }],
  ["proto differs", function (e) { function K() { this.a = 1; } return e(new K(), { a: 1 }); }],
  ["null proto", function (e) { var o = Object.create(null); o.a = 1; return e(o, { a: 1 }); }],
  ["dates", function (e) { return [e(new Date(1), new Date(1)), e(new Date(1), new Date(2))]; }],
  ["maps", function (e) { return [e(new Map([[1, 2]]), new Map([[1, 2]])), e(new Set([1]), new Set([2]))]; }],
  ["funcs", function (e) { var f = function () { return 1; }; return [e(f, function () { return 1; }), e(Math.max, Math.min)]; }],
  ["errors", function (e) { return e(new Error("x"), new Error("x")); }],
  ["wrappers", function (e) { return [e(new Number(1), new Number(1)), e(new String("a"), "a")]; }],
  ["symbols", function (e) { return [e(SYM, SYM), e(Symbol("a"), Symbol("a")), e({ s: SYM }, { s: SYM })]; }],
  ["getter", function (e) { var n = 0; var a = { get g() { n++; return 1; } }; var r = e(a, { g: 1 }); return [n, r]; }],
  ["non-enumerable in b", function (e) { var b = {}; Object.defineProperty(b, "a", { value: 1 }); return e({ a: 1, c: 2 }, Object.assign(b, { c: 2, d: undefined })); }],
  ["arguments", function (e) { return e((function () { return arguments; })(1), (function () { return arguments; })(1)); }],
  ["toStringTag", function (e) { var a = { x: 1 }, b = { x: 1 }; a[Symbol.toStringTag] = "Foo"; b[Symbol.toStringTag] = "Foo"; return e(a, b); }],
  ["big", function (e) { function mk() { var o = { items: [] }; for (var i = 0; i < 200; i++) o.items.push({ id: i, tags: ["a", "b"], meta: { n: i } }); return o; } var a = mk(), b = mk(); var r1 = e(a, b); b.items[199].meta.n = -1; return [r1, e(a, b)]; }],
];
function runAll2(label, s, c, e) {
  spreadCases.forEach(function (x) { rec(label + " spread " + x[0], function () { return x[1](s); }); });
  cloneCases.forEach(function (x) { rec(label + " clone " + x[0], function () { return x[1](c); }); });
  eqCases.forEach(function (x) { rec(label + " equal " + x[0], function () { return x[1](e); }); });
}
function patched2(label, s, c, e) {
  var ok = Object.keys; Object.keys = function (o) { return ok(o).reverse(); };
  rec(label + " patched keys spread", function () { return s({}, { a: 1, b: 2 }); });
  rec(label + " patched keys clone", function () { return c({ a: 1, b: 2 }); });
  rec(label + " patched keys equal", function () { return e({ a: 1, b: 2 }, { a: 1, b: 2 }); });
  Object.keys = ok;
  var OM = Map; Map = function () { OUT.push("Map ctor ran"); return new OM(); };
  rec(label + " patched Map clone", function () { return c({ a: [1] }); });
  Map = OM;
  var OS = Set; Set = function () { OUT.push("Set ctor ran"); return new OS(); };
  rec(label + " patched Set equal", function () { return e({ a: 1 }, { a: 1 }); });
  Set = OS;
  var dp = Object.defineProperty; Object.defineProperty = function (o, k, d) { OUT.push("defineProperty " + String(k)); return dp(o, k, d); };
  rec(label + " patched defineProperty spread", function () { return s({ toString: 0 }, { toString: 1 }); });
  Object.defineProperty = dp;
}

"""#

    /// objectSpread2, cloneDeep, @wry/equality: twin on vs off, as above.
    mutating func testNativeTwinsRound2() {
        let group = "NativeTwins2"
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
        let setup = run(Self.nativeTwinsVariants2 + Self.nativeTwinsCases2 + "'ok'", "setup")
        assert(setup == "ok", "\(group): setup -> \(setup)")
        let body = """
            OUT = []; runAll2("x", SPREAD_X, CLONE_X, EQ_X); patched2("x", SPREAD_X, CLONE_X, EQ_X);
            OUT.filter(function (l) { return !/ deep => /.test(l); }).join("\\n")
            """
        rt.nativeTwins = true
        let h0 = rt.twinStats.hits
        let on = run(body, "on")
        let served = rt.twinStats.hits - h0
        rt.nativeTwins = false
        let off = run(body, "off")
        assert(served > 30, "\(group): twins served \(served) calls")
        assert(on == off, "\(group): twins and bytecode differ")
        if on != off {
            for (x, y) in zip(on.split(separator: "\n"), off.split(separator: "\n")) where x != y {
                print("[\(group)] twin: \(x)\n[\(group)] code: \(y)")
            }
        }
        rt.nativeTwins = true
        let deep = run("OUT = []; rec('d', function(){ return cloneCases.filter(function(c){ return c[0] === 'deep'; })[0][1](CLONE_X); }); OUT[0]", "deep")
        assert(deep == "d => number:300", "\(group): 300 levels -> \(deep)")
    }
}
