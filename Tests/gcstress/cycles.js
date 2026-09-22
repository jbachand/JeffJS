// GC stress: every heap shape whose collection must be identical on the CPU
// and the GPU collector. Output is compared byte for byte between the two, so
// nothing here may print a pointer, an address or a timing.
function report(tag, f) { var v; try { v = String(f()); } catch (e) { v = "THREW " + e.message; } console.log(tag + " = " + v); }

// 1. self-cycles
(function () { for (var i = 0; i < 40000; i++) { var o = {}; o.self = o; o.i = i; } })();
__gc();
report("selfcycles.live", function () { return JSON.parse(__gcStats()).liveObjects < 5000; });

// 2. React-style tree, dropped and rebuilt
function mkNode(d, parent) {
  var n = { tag: "div", d: d, kids: [], parent: parent || null };
  n.onClick = function () { return n.d; };
  if (d > 0) { n.kids.push(mkNode(d - 1, n), mkNode(d - 1, n)); }
  return n;
}
for (var pass = 0; pass < 6; pass++) { var t = mkNode(11, null); t = null; }
var liveTree = mkNode(11, null);
__gc();
report("tree.readback", function () { return liveTree.kids[0].parent === liveTree && liveTree.kids[1].kids[0].onClick(); });
report("tree.bounded", function () { return JSON.parse(__gcStats()).liveObjects < 40000; });

// 3. closures over one shared var-ref
function mkModule(tag) {
  var ns = { tag: tag, n: 0 };
  var fns = []; for (var i = 0; i < 30; i++) fns.push(function () { return ns.tag + ns.n; });
  return { fns: fns, rec: function walk(k) { return k ? walk(k - 1) : ns.tag; } };
}
var keptModules = [];
for (var m = 0; m < 4000; m++) { var mod = mkModule("M" + m); if (m % 1000 === 0) keptModules.push(mod); }
__gc();
report("varrefs.readback", function () { return keptModules.map(function (x) { return x.fns[29]() + "/" + x.rec(9); }).join(","); });

// 4. WeakRef / FinalizationRegistry observe the free
var reg = new FinalizationRegistry(function () {});
var kept = {}; kept.self = kept; reg.register(kept, "kept");
var keptRef = new WeakRef(kept);
var deadRef = (function () { var d = {}; d.self = d; reg.register(d, "dead"); return new WeakRef(d); })();
for (var i = 0; i < 20000; i++) { var junk = {}; junk.self = junk; }
__gc(); __gc();
report("weakref.kept", function () { return keptRef.deref() === kept; });
report("weakref.dead", function () { return deadRef.deref() === undefined; });

// 5. Map/Set with object keys, promise reaction cycles, class hierarchies
var liveMap = new Map(); var kk = { id: 0 }; liveMap.set(kk, { v: "zero", back: kk });
for (var i = 1; i < 20000; i++) { var k = { id: i }; var mp = new Map(); mp.set(k, { back: k }); var st = new Set(); st.add(k); }
__gc();
report("map.readback", function () { return liveMap.get(kk).back.id + "/" + liveMap.size; });

var liveP = new Promise(function () {}); liveP.self = liveP;
var liveChain = liveP.then(function () { return liveP; });
for (var i = 0; i < 20000; i++) { var p = new Promise(function () {}); p.self = p; p.then(function () { return p; }).catch(function () {}); }
__gc();
report("promise.readback", function () { return (liveP.self === liveP) + "/" + (typeof liveChain.then); });

var LiveBase = class { who() { return "base"; } };
var LiveMid = class extends LiveBase { who() { return "mid" + super.who(); } };
var inst = new LiveMid();
for (var i = 0; i < 6000; i++) { var A = class { m() { return 1; } }; var B = class extends A { m() { return super.m() + 1; } }; var b = new B(); b = null; }
__gc();
report("class.readback", function () { return inst.who() + "/" + (inst instanceof LiveBase); });

// 6. generators and suspended async frames
function* gen(tag) { var box = { tag: tag }; var i = 0; while (true) { yield box.tag + (i++); } }
var liveGen = gen("L"); liveGen.next();
var forever = new Promise(function () {});
async function waiter(tag) { var box = { tag: tag }; await forever; return box.tag; }
var liveAwait = waiter("A");
for (var i = 0; i < 8000; i++) { var g = gen("g"); g.next(); g = null; var w = waiter("w"); w = null; }
__gc();
report("gen.readback", function () { return liveGen.next().value + "/" + liveGen.next().value + "/" + (typeof liveAwait.then); });

// 7. mapped arguments, bound functions, proxies
function mkArgs(x, y) { var a = arguments; return { a: a, get: function () { return x + y; }, bump: function () { x++; return x; } }; }
var liveArgs = mkArgs(20, 22);
function bt(a, b) { return this.base + a + b; }
var liveBound = bt.bind({ base: 100 }, 1);
var pt = { v: 7 }; var liveProxy = new Proxy(pt, { get: function (t, k) { return k === "twice" ? t.v * 2 : t[k]; } }); pt.p = liveProxy;
for (var i = 0; i < 8000; i++) {
  var t2 = mkArgs(i, i); t2.a = null; t2 = null;
  var bb = bt.bind({ base: i }, i); bb = null;
  var tt = { v: i }; var pp = new Proxy(tt, {}); tt.p = pp; pp = null; tt = null;
}
__gc();
report("args.readback", function () { return liveArgs.get() + "/" + liveArgs.a[0] + "/" + liveArgs.bump(); });
report("bound.readback", function () { return liveBound(2); });
report("proxy.readback", function () { return liveProxy.twice + "/" + (pt.p === liveProxy); });

// 8. DOM wrappers
var root = document.createElement("div"); root.id = "root"; document.body.appendChild(root);
root.onclick = function () { return root.id; };
for (var i = 0; i < 8000; i++) { var d = document.createElement("span"); var c = document.createElement("b"); d.appendChild(c); c.owner = d; d.self = d; d = null; c = null; }
var liveEl = document.createElement("p"); liveEl.textContent = "kept"; root.appendChild(liveEl); liveEl.back = root;
__gc();
report("dom.readback", function () { return root.onclick() + "/" + document.getElementById("root").childNodes.length + "/" + (liveEl.back === root) + "/" + liveEl.textContent; });

__gc();
report("final.bounded", function () { return JSON.parse(__gcStats()).liveObjects < 200000; });
console.log("DONE");
