// Real-world style workloads (browser/app code patterns), one timed run each
// after a warm-up. Output: name <TAB> ms <TAB> result (results must agree
// between engines). Works under JeffJS, QuickJS and jsc.
var LOG = [];
function out(s) { LOG.push(s); if (typeof console !== "undefined" && console.log) console.log(s); else if (typeof print === "function") print(s); }
function now() { return (typeof performance !== "undefined" && performance.now) ? performance.now() : Date.now(); }
function bench(name, fn) {
  var r;
  try { fn(); var t = now(); r = fn(); var dt = now() - t; out(name + "\t" + dt.toFixed(2) + "\t" + String(r).slice(0, 40)); }
  catch (e) { out(name + "\tERR\t" + String(e).slice(0, 70)); }
}

// ---- shared data ---------------------------------------------------------
var payloadObj = [];
for (var i = 0; i < 2000; i++) payloadObj.push({ id: i, name: "user" + i, email: "user" + i + "@example.com", active: i % 2 == 0, score: i * 1.5, tags: ["a", "b", "c"], address: { city: "City" + (i % 50), zip: 10000 + i, geo: { lat: i * 0.01, lng: -i * 0.02 } } });
var payload = JSON.stringify(payloadObj);
var people = [];
for (var i = 0; i < 20000; i++) people.push({ id: i, age: i % 80, name: "n" + i, dept: i % 10 });
var csv = [];
for (var i = 0; i < 2000; i++) csv.push("  Name" + i + ", " + (i % 90) + " , city" + (i % 30) + " ,tag" + i + " ");
var csvText = csv.join("\n");
var wsrc = "the quick brown fox jumps over the lazy dog and runs away from the big bad wolf while the cat sleeps".split(" ");
var words = [];
for (var i = 0; i < 50000; i++) words.push(wsrc[i % wsrc.length] + (i % 500));
function h(tag, props, children) { return { tag: tag, props: props, children: children || [] }; }
function buildTree(depth, breadth, seed) {
  if (depth == 0) return h("span", { text: "t" + seed }, []);
  var kids = [];
  for (var i = 0; i < breadth; i++) kids.push(buildTree(depth - 1, breadth, seed * breadth + i));
  return h("div", { cls: "c" + (seed % 7), id: seed }, kids);
}
function diff(a, b, patches) {
  if (a.tag !== b.tag) { patches.push({ type: "replace", node: b }); return; }
  for (var k in b.props) { if (a.props[k] !== b.props[k]) patches.push({ type: "prop", key: k, value: b.props[k] }); }
  var n = Math.max(a.children.length, b.children.length);
  for (var i = 0; i < n; i++) {
    var ca = a.children[i], cb = b.children[i];
    if (!ca) patches.push({ type: "add", node: cb });
    else if (!cb) patches.push({ type: "remove" });
    else diff(ca, cb, patches);
  }
}

// ---- JSON ----------------------------------------------------------------
bench("json-parse", function () { var n = 0; for (var k = 0; k < 20; k++) { var o = JSON.parse(payload); n += o.length + o[1999].address.geo.lat; } return n; });
bench("json-stringify", function () { var n = 0; for (var k = 0; k < 20; k++) { n += JSON.stringify(payloadObj).length; } return n; });

// ---- virtual DOM ---------------------------------------------------------
bench("vdom-build-diff", function () { var s = 0; for (var k = 0; k < 3; k++) { var a = buildTree(6, 4, 1), b = buildTree(6, 4, 2); var p = []; diff(a, b, p); s += p.length; } return s; });
bench("tree-walk", function () { var root = buildTree(7, 4, 1); var s = 0; function walk(n, depth) { s += depth + n.children.length; for (var i = 0; i < n.children.length; i++) walk(n.children[i], depth + 1); } for (var k = 0; k < 5; k++) walk(root, 0); return s; });

// ---- arrays with callbacks -----------------------------------------------
bench("array-map-filter-reduce", function () { var s = 0; for (var k = 0; k < 20; k++) { var adults = people.filter(function (p) { return p.age >= 18; }); var ages = adults.map(function (p) { return p.age; }); s += ages.reduce(function (a, b) { return a + b; }, 0); var names = adults.map(function (p) { return p.name.toUpperCase(); }); s += names.length; people.forEach(function (p) { if (p.dept === 3) s++; }); } return s; });
bench("array-sort-comparator", function () { var s = 0; for (var k = 0; k < 5; k++) { var arr = people.slice(); arr.sort(function (a, b) { return a.age - b.age || a.id - b.id; }); s += arr[0].id + arr[19999].id; } return s; });
bench("array-find-indexof", function () { var s = 0; var nums = []; for (var i = 0; i < 5000; i++) nums.push(i * 7 % 5003); for (var k = 0; k < 200; k++) { s += nums.indexOf(k * 13 % 5003); s += nums.includes(k) ? 1 : 0; var f = people.find(function (p) { return p.id === k * 50; }); s += f ? f.age : 0; } return s; });
bench("array-splice-concat", function () { var s = 0; for (var k = 0; k < 200; k++) { var a = []; for (var i = 0; i < 500; i++) a.push(i); a.splice(100, 50); a.unshift(1, 2, 3); var b = a.slice(10, 300).concat([1, 2, 3]); a.reverse(); s += a.length + b.length + b.indexOf(150) + a.pop() + a.shift(); } return s; });
bench("array-from-fill", function () { var s = 0; for (var k = 0; k < 200; k++) { var a = Array.from({ length: 1000 }, function (_, i) { return i * 2; }); var b = new Array(1000).fill(0).map(function (_, i) { return i; }); s += a[999] + b[999] + a.length; } return s; });

// ---- strings and regex ---------------------------------------------------
bench("string-split-trim", function () { var s = 0; for (var k = 0; k < 20; k++) { var lines = csvText.split("\n"); for (var i = 0; i < lines.length; i++) { var f = lines[i].split(","); var name = f[0].trim(); var age = parseInt(f[1].trim(), 10); var city = f[2].trim().toLowerCase(); if (name.startsWith("Name") && city.indexOf("city") === 0) s += age; s += name.length + f[3].slice(0, 3).length; } } return s; });
bench("string-replace-regex", function () { var s = 0; var text = csvText; for (var k = 0; k < 10; k++) { var r = text.replace(/Name(\d+)/g, "User$1"); s += r.length; var m = text.match(/city(\d+)/g); s += m.length; var parts = text.split(/\s*,\s*/); s += parts.length; } return s; });
bench("regex-tokenize", function () { var src = ""; for (var i = 0; i < 200; i++) src += "let x = foo(1, 2.5) + bar['key'] * 3; if (x >= 10) { return x - 1; } // comment\n"; var re = /\s+|\/\/[^\n]*|\d+(?:\.\d+)?|[A-Za-z_]\w*|'[^']*'|[-+*\/=<>!&|]+|[(){}\[\];,.]/g; var n = 0; for (var k = 0; k < 5; k++) { re.lastIndex = 0; var m; while ((m = re.exec(src)) !== null) { n += m[0].length; } } return n; });
bench("template-html", function () { var s = 0; for (var k = 0; k < 20; k++) { var html = ""; for (var i = 0; i < 5000; i++) { var p = people[i]; html += "<tr class=\"row " + (i % 2 ? "odd" : "even") + "\"><td>" + p.id + "</td><td>" + p.name + "</td><td>" + p.age + "</td></tr>"; } s += html.length; var parts = []; for (var i = 0; i < 5000; i++) { parts.push("<li>" + people[i].name + "</li>"); } s += parts.join("").length; } return s; });
bench("template-literals", function () { var s = 0; for (var k = 0; k < 20; k++) { var html = ""; for (var i = 0; i < 5000; i++) { var p = people[i]; html += `<tr class="row ${i % 2 ? "odd" : "even"}"><td>${p.id}</td><td>${p.name}</td><td>${p.age}</td></tr>`; } s += html.length; } return s; });
bench("charcode-encode", function () { var s = 0; var str = "Hello, World! Unicode "; for (var i = 0; i < 200; i++) str += "x"; for (var k = 0; k < 300; k++) { var o = ""; for (var i = 0; i < str.length; i++) { var c = str.charCodeAt(i); o += String.fromCharCode(c < 128 ? c ^ 1 : c); } s += o.length; var arr = []; for (var i = 0; i < str.length; i++) arr.push(str[i]); s += arr.join("").length; s += encodeURIComponent(str).length + decodeURIComponent(encodeURIComponent(str)).length; } return s; });
bench("string-sort-compare", function () { var s = 0; var names = []; for (var i = 0; i < 5000; i++) names.push("name" + ((i * 7919) % 5000)); for (var k = 0; k < 10; k++) { var arr = names.slice(); arr.sort(); s += arr[0].length; arr.sort(function (a, b) { return a < b ? -1 : a > b ? 1 : 0; }); s += arr[4999].length; var joined = arr.join(","); s += joined.split(",").length; } return s; });

// ---- dictionaries --------------------------------------------------------
bench("object-dictionary", function () { var s = 0; for (var k = 0; k < 5; k++) { var counts = {}; for (var i = 0; i < words.length; i++) { var w = words[i]; counts[w] = (counts[w] || 0) + 1; } var keys = Object.keys(counts); s += keys.length; for (var i = 0; i < keys.length; i++) { if (counts.hasOwnProperty(keys[i])) s += counts[keys[i]]; } for (var i = 0; i < keys.length; i += 2) delete counts[keys[i]]; s += Object.keys(counts).length; if ("the0" in counts) s++; } return s; });
bench("map-set", function () { var s = 0; for (var k = 0; k < 5; k++) { var m = new Map(); var set = new Set(); for (var i = 0; i < words.length; i++) { var w = words[i]; m.set(w, (m.get(w) || 0) + 1); set.add(w); } s += m.size + set.size; for (var i = 0; i < words.length; i += 3) { if (m.has(words[i])) s++; } m.forEach(function (v, key) { s += v; }); for (const e of m) { s += e[0].length; } } return s; });
bench("large-object-keys", function () { var big = {}; for (var i = 0; i < 5000; i++) big["key" + i] = i; var s = 0; for (var i = 0; i < 500000; i++) { s += big["key" + (i % 5000)]; } return s; });
bench("polymorphic-access", function () { var objs = [{ x: 1, y: 2 }, { y: 2, x: 1 }, { x: 1, z: 3, y: 2 }, { a: 0, x: 1, y: 2 }, { x: 1, y: 2, b: 1 }]; var s = 0; for (var i = 0; i < 1000000; i++) { var o = objs[i % 5]; s += o.x + o.y; } return s; });
bench("for-in-entries", function () { var s = 0; var objs = []; for (var i = 0; i < 2000; i++) { objs.push({ a: i, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8 }); } for (var k = 0; k < 20; k++) { for (var i = 0; i < objs.length; i++) { var o = objs[i]; for (var key in o) { s += o[key]; } var ents = Object.entries(o); for (var j = 0; j < ents.length; j++) s += ents[j][1]; var vals = Object.values(o); for (var j = 0; j < vals.length; j++) s += vals[j]; } } return s; });
bench("object-assign-create", function () { var s = 0; var defaults = { a: 1, b: 2, c: 3, d: 4 }; var proto = { greet: function () { return this.a + this.b; } }; for (var i = 0; i < 100000; i++) { var cfg = Object.assign({}, defaults, { b: i, e: 5 }); var o = Object.create(proto); o.a = i; o.b = 1; s += cfg.b + cfg.e + o.greet() + Object.keys(cfg).length; } return s; });

// ---- classes, closures, calls -------------------------------------------
class Shape { constructor(x, y) { this.x = x; this.y = y; } get pos() { return this.x + this.y; } move(dx, dy) { this.x += dx; this.y += dy; return this; } area() { return 0; } }
class Rect extends Shape { constructor(x, y, w, h) { super(x, y); this.w = w; this.h = h; } area() { return this.w * this.h; } }
class Square extends Rect { constructor(x, y, s) { super(x, y, s, s); } area() { return super.area(); } describe() { return "sq" + this.area(); } }
bench("class-hierarchy", function () { var s = 0; var shapes = []; for (var i = 0; i < 3000; i++) { shapes.push(i % 3 == 0 ? new Shape(i, i) : i % 3 == 1 ? new Rect(i, i, 2, 3) : new Square(i, i, 4)); } for (var k = 0; k < 100; k++) { for (var i = 0; i < shapes.length; i++) { var sh = shapes[i]; s += sh.area() + sh.pos; sh.move(1, 1); if (sh instanceof Square) s += sh.describe().length; } } return s; });
bench("getter-setter", function () { var o = { _v: 0, get v() { return this._v; }, set v(n) { this._v = n; } }; var s = 0; for (var i = 0; i < 300000; i++) { o.v = i; s += o.v; } return s; });
function Emitter() { this.listeners = {}; }
Emitter.prototype.on = function (ev, fn) { (this.listeners[ev] || (this.listeners[ev] = [])).push(fn); };
Emitter.prototype.emit = function (ev) { var l = this.listeners[ev]; if (!l) return; var args = Array.prototype.slice.call(arguments, 1); for (var i = 0; i < l.length; i++) l[i].apply(this, args); };
bench("event-emitter", function () { var s = 0; var em = new Emitter(); for (var i = 0; i < 50; i++) { (function (i) { em.on("data", function (a, b) { s += a + b + i; }); })(i); } for (var k = 0; k < 4000; k++) { em.emit("data", k, 1); } return s; });
bench("closure-creation", function () { var s = 0; var handlers = []; for (var i = 0; i < 100000; i++) { var el = { id: i }; handlers.push(function () { return el.id; }); } for (var i = 0; i < handlers.length; i++) s += handlers[i](); return s; });
bench("bind-call-apply", function () { var s = 0; var o = { v: 2 }; function f(a, b) { return this.v + a + b; } var g = f.bind(o, 1); for (var i = 0; i < 200000; i++) { s += f.call(o, i, 1) + f.apply(o, [i, 2]) + g(i); } return s; });
bench("arguments-object", function () { function sum() { var t = 0; for (var i = 0; i < arguments.length; i++) t += arguments[i]; return t; } var s = 0; for (var i = 0; i < 200000; i++) s += sum(i, 1, 2, 3); return s; });
bench("rest-spread-destructure", function () { var s = 0; function f(a, ...rest) { return a + rest.length; } for (var i = 0; i < 100000; i++) { var o = { x: i, y: 1, z: 2 }; var { x, y } = o; var arr = [x, y, ...[1, 2, 3]]; var o2 = { ...o, w: 3 }; s += f(...arr) + o2.w + Math.max(...arr); } return s; });
bench("native-calls", function () { var s = 0; for (var i = 0; i < 1000000; i++) { s += Math.max(i, 1) + Math.abs(-i) + (Array.isArray(s) ? 1 : 0) + Math.floor(i / 3); } return s; });
bench("promise-chain-setup", function () { var s = 0; var p = Promise.resolve(0); for (var i = 0; i < 20000; i++) { p = p.then(function (v) { return v + 1; }); } p.then(function (v) { s = v; }); return "queued"; });
bench("try-catch-throw", function () { var s = 0; for (var i = 0; i < 50000; i++) { try { if (i % 2) throw new Error("e" + i); s++; } catch (e) { s += e.message.length; } finally { s++; } } return s; });
bench("proxy-reactive", function () { var s = 0; var target = { a: 1, b: 2 }; var p = new Proxy(target, { get: function (t, k) { return t[k]; }, set: function (t, k, v) { t[k] = v; return true; } }); for (var i = 0; i < 200000; i++) { p.a = i; s += p.a + p.b; } return s; });
bench("generators-iterators", function () { var s = 0; function* range(n) { for (var i = 0; i < n; i++) yield i; } for (var k = 0; k < 50; k++) { for (const x of range(5000)) s += x; var it = { [Symbol.iterator]: function () { var i = 0; return { next: function () { return i < 2000 ? { value: i++, done: false } : { value: undefined, done: true }; } }; } }; for (const x of it) s += x; } return s; });
bench("switch-interpreter", function () { var code = []; for (var i = 0; i < 1000; i++) code.push(i % 8); var acc = 0; for (var k = 0; k < 2000; k++) { for (var pc = 0; pc < code.length; pc++) { switch (code[pc]) { case 0: acc += 1; break; case 1: acc -= 1; break; case 2: acc *= 2; break; case 3: acc = acc >> 1; break; case 4: acc ^= pc; break; case 5: acc |= 1; break; case 6: acc &= 0xffff; break; default: acc += pc; } } } return acc; });

// ---- numbers, dates, typed arrays ---------------------------------------
bench("date-number-format", function () { var s = 0; for (var i = 0; i < 100000; i++) { var d = new Date(1600000000000 + i * 1000); s += d.getHours() + d.getMonth(); s += (i / 3).toFixed(2).length; s += parseFloat("3.14" + i) | 0; s += String(i * 1.5).length; s += Number("42") + parseInt("ff", 16); } s += new Date(1600000000000).toISOString().length; return s; });
bench("physics-vectors", function () { var s = 0; var ps = []; for (var i = 0; i < 2000; i++) ps.push({ x: i, y: i * 0.5, vx: 1, vy: -1 }); for (var k = 0; k < 100; k++) { for (var i = 0; i < ps.length; i++) { var p = ps[i]; p.vy += 0.1; p.x += p.vx * 0.016; p.y += p.vy * 0.016; if (p.y > 100) { p.y = 100; p.vy = -p.vy * 0.9; } s += Math.sqrt(p.x * p.x + p.y * p.y); } } return Math.round(s); });
bench("typed-array-image", function () { var w = 512, hh = 512; var img = new Uint8ClampedArray(w * hh * 4); for (var i = 0; i < img.length; i++) img[i] = i & 255; var s = 0; for (var k = 0; k < 3; k++) { for (var i = 0; i < img.length; i += 4) { var r = img[i], g = img[i + 1], b = img[i + 2]; var y = (r * 77 + g * 151 + b * 28) >> 8; img[i] = img[i + 1] = img[i + 2] = y; s += y; } } var f = new Float32Array(100000); for (var i = 0; i < f.length; i++) f[i] = Math.sin(i * 0.001); var acc = 0; for (var i = 0; i < f.length; i++) acc += f[i] * f[i]; return s + Math.round(acc); });

var __report = LOG.join("\n");
out("done " + LOG.length + " kernels");
