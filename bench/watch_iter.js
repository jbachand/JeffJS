// Watch interpreter speed (2026-10-05): iterator protocol over arrays —
// for-of, array spread, call spread, array destructuring, Array.from — the
// shapes modern bundles (homedepot's ES2015+ module bundle) compile to.
var LOG = [];
function now() { return (typeof performance !== "undefined" && performance.now) ? performance.now() : Date.now(); }
function bench(name, fn) { fn(); var t = now(); var r = fn(); LOG.push(name + "\t" + (now() - t).toFixed(1) + "\t" + r); }
var A = []; for (var i = 0; i < 100; i++) A.push(i);
bench("for-of-array", function () { var s = 0; for (var k = 0; k < 4000; k++) for (var v of A) s += v; return s; });
bench("array-spread", function () { var s = 0, b = [1, 2, 3, 4]; for (var k = 0; k < 200000; k++) { var o = [...b, k]; s += o.length; } return s; });
bench("call-spread", function () { function f(a, b, c) { return a + b + c; } var s = 0, b = [1, 2, 3]; for (var k = 0; k < 200000; k++) s += f(...b); return s; });
bench("destructure", function () { var s = 0, b = [1, 2, 3]; for (var k = 0; k < 200000; k++) { var [x, y, ...z] = b; s += x + y + z.length; } return s; });
bench("Array.from-iter", function () { var s = 0; for (var k = 0; k < 50000; k++) s += Array.from(A.keys()).length; return s; });
var __report = LOG.join("\n");
if (typeof console !== "undefined" && console.log) console.log(__report); else print(__report);
