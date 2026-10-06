// Watch interpreter speed (2026-10-05): native builtins calling small JS
// callbacks (reduce/map/forEach/filter ~ 50% inclusive of homedepot's JS),
// native method calls from bytecode, Object.prototype.toString.call.
var LOG = [];
function now() { return (typeof performance !== "undefined" && performance.now) ? performance.now() : Date.now(); }
function bench(name, fn) { fn(); var t = now(); var r = fn(); LOG.push(name + "\t" + (now() - t).toFixed(1) + "\t" + r); }
var A = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
bench("forEach", function () { var s = 0; for (var k = 0; k < 200000; k++) A.forEach(function (v) { s += v; }); return s; });
bench("map", function () { var s = 0; for (var k = 0; k < 200000; k++) s += A.map(function (v) { return v + 1; }).length; return s; });
bench("reduce", function () { var s = 0; for (var k = 0; k < 200000; k++) s += A.reduce(function (r, v) { return r + v; }, 0); return s; });
bench("filter", function () { var s = 0; for (var k = 0; k < 200000; k++) s += A.filter(function (v) { return v & 1; }).length; return s; });
bench("toString.call", function () { var s = 0, o = {}; for (var k = 0; k < 500000; k++) if (Object.prototype.toString.call(o) === "[object Object]") s++; return s; });
bench("hasOwn.call", function () { var s = 0, o = { a: 1 }; for (var k = 0; k < 500000; k++) if (Object.prototype.hasOwnProperty.call(o, "a")) s++; return s; });
bench("keys-concat-symbols", function () { var s = 0, o = { a: 1, b: 2, c: 3 }; for (var k = 0; k < 200000; k++) s += Object.keys(o).concat(Object.getOwnPropertySymbols(o)).length; return s; });
var __report = LOG.join("\n");
if (typeof console !== "undefined" && console.log) console.log(__report); else print(__report);
