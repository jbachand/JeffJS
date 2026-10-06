// Watch memory (perf/watch-object-size): a homedepot-shaped live heap built in
// a second, then bytes per live GC object / per string as jeffjs-cli sees them
// (__mallocInUse / __gcStats are jeffjs-cli natives). Shapes taken from the
// homedepot-plp census: THD prop-type descriptors {type,_isRequired,...},
// Apollo-style normalized records with __typename / id / url strings, React
// fiber-ish nodes with closures, small arrays, and a JSON payload.
//   .build/release/jeffjs-cli bench/watch_heap.js
// The real page: jeffjs-cli --page=~/rn_fixtures/homedepot-plp
//   --bundles=~/rn_fixtures/homedepot-plp/module-bundles --quiet --heap-report
function stats() { __gc(); __gc(); var g = JSON.parse(__gcStats()); g.malloc = +__mallocInUse(); return g; }
var before = stats();
var keep = [];
// prop-type descriptors
function PT(t, o) { this.type = t; this._isRequired = false; this._isPropType = t !== "Object"; this._isArray = !!(o && o.isArray); this._client = false; this._value = t + (o && o.req ? "!" : ""); }
for (var i = 0; i < 20000; i++) keep.push(new PT(i % 3 ? "String" : "Int", { req: i & 1 }));
// Apollo-normalized records from a JSON payload
var payload = [];
for (var i = 0; i < 4000; i++) payload.push({ __typename: i % 5 ? "Product" : "Image", id: "p" + i, url: "/p/" + i + "/x", title: "Item " + i, price: { value: i * 1.5, currency: "USD" }, tags: ["a", "b", "c" + (i % 7)] });
var parsed = JSON.parse(JSON.stringify(payload));
keep.push(parsed);
// fiber-ish nodes with handlers capturing their node
for (var i = 0; i < 15000; i++) {
  var node = { tag: i % 11, key: null, type: "div", props: { className: "c" + (i % 50), children: [] }, memoizedState: null, return: null, child: null, sibling: null, index: i };
  node.onClick = function () { return node.index; };
  keep.push(node);
}
// small arrays and strings
for (var i = 0; i < 20000; i++) keep.push([i, "s" + (i % 1000), i & 1 ? "" : "x"]);
var after = stats();
var objs = after.liveObjects - before.liveObjects, bytes = after.malloc - before.malloc;
console.log("objects\t" + objs + "\tbytes\t" + bytes + "\tbytes/object\t" + (bytes / objs).toFixed(0));
