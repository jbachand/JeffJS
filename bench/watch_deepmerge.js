// homedepot.com hot spot (watch interpreter speed, 2026-10-05): the THD
// "data model" merge — deepmerge + Babel's _objectSpread2 helpers, verbatim
// from the GuestHomepageContainer bundle (minified names kept) — ~60% of the
// page's JS samples on JeffJS. Synthetic data models of the same shape:
// nested GraphQL field trees ({ field: { _client: true }, nested: {...} }).
var LOG = [];
function now() { return (typeof performance !== "undefined" && performance.now) ? performance.now() : Date.now(); }
var Sze=function(t){return Oze(t)&&!Cze(t)};function Oze(e){return!!e&&typeof e=="object"}function Cze(e){var t=Object.prototype.toString.call(e);return t==="[object RegExp]"||t==="[object Date]"||_ze(e)}var Pze=typeof Symbol=="function"&&Symbol.for,Tze=Pze?Symbol.for("react.element"):60103;function _ze(e){return e.$$typeof===Tze}function Aze(e){return Array.isArray(e)?[]:{}}function $7(e,t){return t.clone!==!1&&t.isMergeableObject(e)?yC(Aze(e),e,t):e}function Ize(e,t,r){return e.concat(t).map(function(n){return $7(n,r)})}function Nze(e,t){if(!t.customMerge)return yC;var r=t.customMerge(e);return typeof r=="function"?r:yC}function Dze(e){return Object.getOwnPropertySymbols?Object.getOwnPropertySymbols(e).filter(function(t){return Object.propertyIsEnumerable.call(e,t)}):[]}function Qme(e){return Object.keys(e).concat(Dze(e))}function tNe(e,t){try{return t in e}catch{return!1}}function Rze(e,t){return tNe(e,t)&&!(Object.hasOwnProperty.call(e,t)&&Object.propertyIsEnumerable.call(e,t))}function kze(e,t,r){var n={};return r.isMergeableObject(e)&&Qme(e).forEach(function(a){n[a]=$7(e[a],r)}),Qme(t).forEach(function(a){Rze(e,a)||(tNe(e,a)&&r.isMergeableObject(t[a])?n[a]=Nze(a,r)(e[a],t[a],r):n[a]=$7(t[a],r))}),n}function yC(e,t,r){r=r||{},r.arrayMerge=r.arrayMerge||Ize,r.isMergeableObject=r.isMergeableObject||Sze,r.cloneUnlessOtherwiseSpecified=$7;var n=Array.isArray(t),a=Array.isArray(e),i=n===a;return i?n?r.arrayMerge(e,t,r):kze(e,t,r):$7(t,r)}
var oQ=yC;
function Zme(e,t){var r=Object.keys(e);if(Object.getOwnPropertySymbols){var n=Object.getOwnPropertySymbols(e);t&&(n=n.filter(function(a){return Object.getOwnPropertyDescriptor(e,a).enumerable})),r.push.apply(r,n)}return r}function Xme(e){for(var t=1;t<arguments.length;t++){var r=arguments[t]!=null?arguments[t]:{};t%2?Zme(Object(r),!0).forEach(function(n){$ze(e,n,r[n])}):Object.getOwnPropertyDescriptors?Object.defineProperties(e,Object.getOwnPropertyDescriptors(r)):Zme(Object(r)).forEach(function(n){Object.defineProperty(e,n,Object.getOwnPropertyDescriptor(r,n))})}return e}function $ze(e,t,r){return(t=Fze(t))in e?Object.defineProperty(e,t,{value:r,enumerable:!0,configurable:!0,writable:!0}):e[t]=r,e}function Fze(e){var t=Lze(e,"string");return typeof t=="symbol"?t:t+""}function Lze(e,t){if(typeof e!="object"||!e)return e;var r=e[Symbol.toPrimitive];if(r!==void 0){var n=r.call(e,t||"default");if(typeof n!="object")return n;throw new TypeError("@@toPrimitive must return a primitive value.")}return(t==="string"?String:Number)(e)}
const rNe=(e,t)=>Object.keys(e).map(r=>typeof e[r]=="object"?t(e[r])?{}:{[r]:rNe(e[r],t)}:{[r]:e[r]}).reduce((r,n)=>Xme(Xme({},r),n),{}),Bze=e=>rNe(e,r=>!!r._client);
// Synthetic data models: a field tree per component, overlapping keys.
var seed = 7; function rnd(n) { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; }
var FIELDS = []; for (var i = 0; i < 60; i++) FIELDS.push("field" + i);
function model(depth) {
  var o = {}; var n = 3 + rnd(6);
  for (var i = 0; i < n; i++) {
    var k = FIELDS[rnd(FIELDS.length)];
    if (depth > 0 && rnd(3) === 0) o[k] = model(depth - 1);
    else o[k] = rnd(4) === 0 ? { _client: true } : { type: "String" };
  }
  return o;
}
var MODELS = []; for (var i = 0; i < 40; i++) MODELS.push({ product: model(3), searchModel: model(2) });
function iNeLike() {
  // the shape of iNe: merge every component's dataModel (client) and its
  // server-only projection (server)
  var client = MODELS.reduce(function (o, s) { return oQ(o, s); }, {});
  var server = MODELS.reduce(function (o, s) { return oQ(o, Bze(s)); }, {});
  return Object.keys(client).length + Object.keys(server).length;
}
function bench(name, n, fn) { fn(); var t = now(); var r; for (var i = 0; i < n; i++) r = fn(); LOG.push(name + "\t" + (now() - t).toFixed(1) + "\t" + r); }
bench("deepmerge-datamodels", 2, iNeLike);
bench("objectSpread2", 20000, function () { return Object.keys(Xme(Xme({}, { a: 1, b: 2, c: 3 }), { d: 4 })).length; });
bench("rNe-server-projection", 40, function () { var s = 0; for (var i = 0; i < MODELS.length; i++) s += Object.keys(Bze(MODELS[i])).length; return s; });
var __report = LOG.join("\n");
if (typeof console !== "undefined" && console.log) console.log(__report); else print(__report);
