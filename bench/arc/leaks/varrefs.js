// Var-ref lifetime cases (Tests/JeffJSTests/ArclessVarRefTests.swift), repeated: closures that
// die before/after their frame, shared and mapped bindings, generators, async, eval, cycles.
var ok = 0, n = 0, bad = [];
var cases = [
  ['loop closures keep their own binding after the callbacks die', function(){ return (function(){ var keep = [];
  for (var r = 0; r < 50; r++) {
    [1,2,3].forEach(function(v){ var t = v * r; return function(){ return t; }; });
    let rr = r; for (let i = 0; i < 4; i++) { if (rr % 7 === 0) keep.push(function(){ return i + rr * 10; }); }
  }
  var s = 0; for (var k = 0; k < keep.length; k++) s += keep[k]();
  return keep.length === 32 && s === 7888; })(); }],
  ['two closures share one detached binding', function(){ return (function(){ function mk(){ var n = 0; return [function(){ return ++n; }, function(){ return n; }]; }
  var a = mk(), b = mk(); a[0](); a[0](); b[0]();
  for (var j = 0; j < 100; j++) mk()[0]();   // dying var-refs, parked and reused
  return a[1]() === 2 && b[1]() === 1 && a[0]() === 3 && a[1]() === 3; })(); }],
  ['binding outlives one of its two closures', function(){ return (function(){ function mk(){ var o = {v: 1}; var g = function(){ return o; };
    return [g, function(x){ o = {v: x}; }]; }
  var p = mk(); var set = p[1]; p = p[0];   // the setter survives, then dies
  set(5); set = null;
  for (var j = 0; j < 200; j++) mk();
  return p().v === 5; })(); }],
  ['closure over a parameter with a mapped arguments object', function(){ return (function(){ function f(x){ var a = arguments; var g = function(){ return x; }; a[0] = 9; return [g, a]; }
  var r = f(1); var g = r[0]; r = null;
  for (var j = 0; j < 100; j++) f(j);
  function h(x){ var a = arguments; return function(){ return a[0] + x; }; }
  var k = h(4);
  for (var j = 0; j < 100; j++) h(j)();
  return g() === 9 && k() === 8; })(); }],
  ['arguments object outlives the frame and the closures', function(){ return (function(){ function f(x){ var c = function(){ x++; }; c(); return arguments; }
  var a = f(10); for (var j = 0; j < 100; j++) f(j);
  return a[0] === 11 && a.length === 1; })(); }],
  ['generator: closures over its locals across yields', function(){ return (function(){ function* g(){ var n = 1; var get = function(){ return n; };
    yield get; n = 2; yield get; var inc = function(){ n += 10; }; inc(); yield get; }
  var it = g(); var f = it.next().value; var a = f();
  for (var j = 0; j < 50; j++) { var t = g(); t.next(); t.next(); }
  it.next(); var b = f(); it.next(); var c = f(); it.next();
  return a === 1 && b === 2 && c === 12; })(); }],
  ['async function: closure over a local across await', function(){ return (function(){ var out = [];
  async function f(){ var n = 1; var get = function(){ return n; }; out.push(get);
    await null; n = 2; await null; n = 3; }
  f(); for (var j = 0; j < 20; j++) f();
  return out.length === 21 && out[0]() === 1; })(); }],
  ["eval code captures the caller's locals", function(){ return (function(){ function f(){ var a = 3; var g = eval("(function(){ return a * 2; })"); a = 4; return g; }
  var g = f(); for (var j = 0; j < 50; j++) f()();
  return g() === 8; })(); }],
  ['close_loc: per-iteration bindings, parked when unread', function(){ return (function(){ var fs = [];
  for (let i = 0; i < 20; i++) { let k = i * 2; (function(){ return k; })(); if (i & 1) fs.push(function(){ return k; }); }
  var s = 0; for (var j = 0; j < fs.length; j++) s += fs[j]();
  return fs.length === 10 && s === 2*(1+3+5+7+9+11+13+15+17+19); })(); }],
  ['cycles through captured bindings are collected and the rest survive', function(){ return (function(){ var live = null;
  for (var j = 0; j < 300; j++) { (function(){ var node = {}; node.cb = function(){ return node; }; })();
    if (j === 150) live = (function(){ var node = {t: 7}; node.cb = function(){ return node; }; return node; })(); }
  if (typeof std !== 'undefined' && std.gc) std.gc();
  return live.cb() === live && live.cb().t === 7; })(); }],
];
for (var rep = 0; rep < 20; rep++) for (var c = 0; c < cases.length; c++) { n++; var r = false; try { r = cases[c][1](); } catch (e) { r = false; } if (r === true) ok++; else if (bad.indexOf(cases[c][0]) < 0) bad.push(cases[c][0]); }
console.log(ok + '/' + n + (bad.length ? ' FAIL ' + bad.join('; ') : ''));
