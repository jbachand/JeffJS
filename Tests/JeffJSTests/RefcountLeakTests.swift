// RefcountLeakTests.swift
// JeffJS — "does this shape come back to baseline?" regression tests.
//
// Every case below is a loop that allocates and drops the same thing 50 000
// times. After a forced collection the runtime's live-object count must be
// back where it started, within a small constant for the handful of objects
// the loop itself leaves behind (the function object, its prototype, a shape
// or two). A refcount that is taken and never given back shows up here as a
// per-iteration slope, which is exactly how each of the bugs these guard was
// found.
//
//   swift test -c release --filter RefcountLeakTests

import XCTest
@testable import JeffJS

final class RefcountLeakTests: XCTestCase {

    /// Objects still on the runtime's GC list after a forced collection.
    private func liveObjects(_ rt: JeffJSRuntime) -> Int {
        runGC(rt)
        return rt.gcObjects.count
    }

    /// Run `body` (a JS snippet with a `N` placeholder for the loop count)
    /// once to warm the pools up, then 50 000 times, and report the growth.
    private func growth(_ name: String, _ source: String,
                        warmup: Int = 200, iterations: Int = 50_000) -> Int {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        let warm = ctx.eval(input: source.replacingOccurrences(of: "$N", with: String(warmup)),
                            filename: "<leak-warmup>", evalFlags: 0)
        XCTAssertFalse(warm.isException, "\(name): warmup threw")
        warm.freeValue()
        let before = liveObjects(rt)
        let r = ctx.eval(input: source.replacingOccurrences(of: "$N", with: String(iterations)),
                         filename: "<leak-loop>", evalFlags: 0)
        XCTAssertFalse(r.isException, "\(name): loop threw")
        r.freeValue()
        let after = liveObjects(rt)
        print("[rc-leak] \(name): \(before) -> \(after) (+\(after - before))")
        return after - before
    }

    /// Each case must come back to within `slack` objects of its baseline —
    /// a constant, never a multiple of the iteration count.
    private func assertFlat(_ name: String, _ source: String,
                            slack: Int = 64, file: StaticString = #filePath, line: UInt = #line) {
        let grew = growth(name, source)
        XCTAssertLessThanOrEqual(grew, slack,
            "\(name): 50k iterations left \(grew) extra live objects (\(Double(grew) / 50_000.0) per iteration)",
            file: file, line: line)
    }

    // MARK: - The shapes a React render exercises

    func testObjectLiteralMembersDoNotLeak() {
        // define_method: the opcode popped the function and `defineProperty`
        // dup'd it, so nobody released the stack's reference.
        assertFlat("method shorthand", "for (var i=0;i<$N;i++){ var o={ f(){} }; o=null; }")
        assertFlat("computed method",  "var k='f'; for (var i=0;i<$N;i++){ var o={ [k](){} }; o=null; }")
        assertFlat("async method",     "for (var i=0;i<$N;i++){ var o={ async f(){} }; o=null; }")
        assertFlat("generator method", "for (var i=0;i<$N;i++){ var o={ *f(){} }; o=null; }")
        // freeObject released the accessor slot's ARC reference but not the
        // manual count defineProperty added.
        assertFlat("getter",           "for (var i=0;i<$N;i++){ var o={ get x(){ return 1 } }; o=null; }")
        assertFlat("setter",           "for (var i=0;i<$N;i++){ var o={ set x(v){} }; o=null; }")
        assertFlat("defineProperty accessor",
                   "for (var i=0;i<$N;i++){ var o={}; Object.defineProperty(o,'x',{get:function(){return 1},configurable:true}); o=null; }")
    }

    func testRedefiningAPropertyReleasesTheOldValue() {
        // defineProperty overwrote the slot in place and dropped whatever was
        // there. `class C {}` hit it through the lazy `prototype`.
        assertFlat("class declaration",  "for (var i=0;i<$N;i++){ class C {} }")
        assertFlat("class with members",
                   "for (var i=0;i<$N;i++){ class C { m(){} get g(){return 1} static s(){} } }")
        assertFlat("class extends",      "class B {} for (var i=0;i<$N;i++){ class C extends B {} }")
        assertFlat("redefine data prop",
                   "var o={}; for (var i=0;i<$N;i++){ Object.defineProperty(o,'x',{value:{v:i},configurable:true}); }")
        assertFlat("redefine accessor",
                   "var o={}; for (var i=0;i<$N;i++){ Object.defineProperty(o,'x',{get:function(){return i},configurable:true}); }")
    }

    func testArrayPushDoesNotRetainTheArray() {
        // The main loop's push fast path popped the receiver and the callee
        // without releasing either, so the array outlived everything in it.
        assertFlat("push temporary",  "function f(){ var a=[]; for (var i=0;i<$N;i++){ a.push({x:i}); } } f();")
        assertFlat("push with method","function f(){ var a=[]; for (var i=0;i<$N;i++){ a.push({ t:'d', on(){ return i } }); } } f();")
        assertFlat("push local",      "function f(){ var a=[]; for (var i=0;i<$N;i++){ var o={x:i}; a.push(o); } } f();")
        assertFlat("push then truncate",
                   "var a=[]; for (var i=0;i<$N;i++){ a.push({ cb:()=>1 }); a.length=0; }")
        assertFlat("indexed store",   "function f(){ var a=[]; for (var i=0;i<$N;i++){ a[i]={x:i}; } } f();")
        assertFlat("push.call",       "function f(){ var a=[]; for (var i=0;i<$N;i++){ Array.prototype.push.call(a,{x:i}); } } f();")
    }

    func testCollectionsReleaseTheirContents() {
        // freeObject let ARC reclaim the JeffJSMapState and left the records'
        // manual counts behind.
        assertFlat("Map",     "for (var i=0;i<$N;i++){ var m=new Map(); m.set('k',{v:i}); m.get('k'); m=null; }")
        assertFlat("Set",     "for (var i=0;i<$N;i++){ var s=new Set(); s.add({v:i}); s=null; }")
        assertFlat("WeakMap", "for (var i=0;i<$N;i++){ var k={}; var w=new WeakMap(); w.set(k,1); w=null; k=null; }")
        assertFlat("WeakSet", "for (var i=0;i<$N;i++){ var k={}; var w=new WeakSet(); w.add(k); w=null; k=null; }")
    }

    func testPromiseReactionsAreReleased() {
        // A .then() builds a fulfill and a reject reaction; one of the two can
        // never run, and the job that runs the other never released what it
        // captured. The eval drains the microtask queue before it returns.
        assertFlat("resolve/then", "for (var i=0;i<$N;i++){ Promise.resolve({v:i}).then(function(v){ return v }); }")
        assertFlat("reject/catch", "for (var i=0;i<$N;i++){ Promise.reject({v:i}).catch(function(v){ return v }); }")
        assertFlat("never settles", "for (var i=0;i<$N;i++){ new Promise(function(){}).then(function(v){ return v }); }")
    }

    func testBranchConditionsDoNotRetainTheirOperand() {
        // Neither trace interpreter released the condition `if_false`,
        // `if_true` and `lnot` pop. A bool condition costs nothing; an object
        // one is a reference, and `if (node)` / `if (!a || !b)` is what a
        // virtual-DOM diff is made of.
        assertFlat("if (obj)",   "function d(o){ if (o) return 1; return 0 } var s=0; for (var i=0;i<$N;i++) s+=d({x:i});")
        assertFlat("if (!obj)",  "function d(o){ if (!o) return 0; return 1 } var s=0; for (var i=0;i<$N;i++) s+=d({x:i});")
        assertFlat("!! in expr", "var s=0; for (var i=0;i<$N;i++){ var o={x:i}; s += !!o ? 1 : 0; o=null; }")
        assertFlat("|| chain",   "function d(a,b){ if (!a || !b) return 0; return 1 } var s=0; for (var i=0;i<$N;i++) s+=d({x:i},{y:i});")
        // The whole re-render shape: build a small tree, diff it against the
        // previous one, drop the previous one. Every pass used to leak a tree.
        assertFlat("build and diff a tree", """
            function ce(t,p,c){ return { type:t, props:p, children:c } }
            function build(seed){ var cells=[];
              for (var j=0;j<8;j++) (function(j){ cells.push(ce("td",{ c:"c"+j, onClick:function(){ return j+seed } },null)) })(j);
              return ce("tr",{ key:seed },cells) }
            function diff(a,b,out){ if (!a || !b) { out.push(1); return }
              if (a.type !== b.type) { out.push(2); return }
              var ca=a.children||[], cb=b.children||[];
              for (var i=0;i<ca.length;i++) diff(ca[i],cb[i],out) }
            var prev = build(0);
            for (var i=0;i<$N;i++){ var next=build(i); var out=[]; diff(prev,next,out); prev=next; }
            prev = null;
            """, slack: 512)
    }

    func testCommonRenderShapesStayFlat() {
        let rows = "var src=[{id:1,n:'a'},{id:2,n:'b'},{id:3,n:'c'}];"
        assertFlat("map spread",   rows + "for (var i=0;i<$N;i++){ var r=src.map(function(x){ return {...x} }); r=null; }")
        assertFlat("Object.assign",rows + "for (var i=0;i<$N;i++){ var r=Object.assign({},src[0]); r=null; }")
        assertFlat("array spread", rows + "for (var i=0;i<$N;i++){ var r=[...src]; r=null; }")
        assertFlat("concat/slice/filter",
                   rows + "for (var i=0;i<$N;i++){ var r=src.concat(src).slice(1).filter(function(x){return x.id>1}); r=null; }")
        assertFlat("for..of",      rows + "var t=0; for (var i=0;i<$N;i++){ for (var v of src) t+=v.id; }")
        assertFlat("closure in loop", "for (var i=0;i<$N;i++){ var x={v:i}; var f=function(){ return x.v }; f(); f=null; x=null; }")
        assertFlat("bind",         "function f(a){return a} for (var i=0;i<$N;i++){ var b=f.bind(null,1); b(); b=null; }")
        assertFlat("JSON round trip",
                   "var o={a:1,b:'x',c:[1,2]}; for (var i=0;i<$N;i++){ var r=JSON.parse(JSON.stringify(o)); r=null; }")
        assertFlat("template literal",
                   "var o={toString(){return 'x'}}; for (var i=0;i<$N;i++){ var s=`v=${o}`; s=null; }")
        assertFlat("rest parameters",
                   "function g(a,...r){ return r.length } var t=0; for (var i=0;i<$N;i++) t+=g(1,2,3);")
        assertFlat("arguments object",
                   "function g(){ return arguments.length } var t=0; for (var i=0;i<$N;i++) t+=g(1,2,3);")
        assertFlat("class instance with arrow field",
                   "class C { constructor(){ this.n=1 } m = () => this.n } for (var i=0;i<$N;i++){ var c=new C(); c.m(); c=null; }")
    }

    // MARK: - The prototype is owned by the shape, exactly once

    /// `newObjectProto` / `Object.create` / `setPrototypeOf` used to give the
    /// prototype a per-*object* reference that `freeObject` never gave back,
    /// so `Object.create(p)` added one permanent count to `p` per call and
    /// every instance pinned its class. The reference now belongs to the
    /// shape (one per shape, released by `freeShape`, marked by the
    /// collector), which is what quickjs does.
    func testPrototypesAreOwnedByTheirShape() {
        assertFlat("Object.create shared proto",
                   "var p={x:1}; for (var i=0;i<$N;i++){ var o=Object.create(p); o=null; }")
        assertFlat("Object.create then extend",
                   "var p={x:1}; for (var i=0;i<$N;i++){ var o=Object.create(p); o.y=i; o=null; }")
        assertFlat("Object.create(null)",
                   "for (var i=0;i<$N;i++){ var o=Object.create(null); o.k=i; o=null; }")
        // A fresh prototype per iteration: the object moves onto a private
        // shape, which is freed with it and releases the prototype.
        assertFlat("Object.setPrototypeOf fresh proto",
                   "for (var i=0;i<$N;i++){ var o={}; Object.setPrototypeOf(o,{a:i}); o=null; }")
        assertFlat("Reflect.setPrototypeOf fresh proto",
                   "for (var i=0;i<$N;i++){ var o={}; Reflect.setPrototypeOf(o,{a:i}); o=null; }")
        assertFlat("__proto__ assignment",
                   "var p={a:1}; for (var i=0;i<$N;i++){ var o={}; o.__proto__=p; o=null; }")
        assertFlat("__proto__ = null",
                   "for (var i=0;i<$N;i++){ var o={a:i}; o.__proto__=null; o=null; }")
        // `set_proto` popped the prototype and let the shape dup it, so the
        // stack's reference was dropped on the floor: `class B extends A`
        // pinned both `A` and `A.prototype`, four objects per evaluation.
        assertFlat("class hierarchy dropped",
                   "for (var i=0;i<$N;i++){ class A { m(){return 1} } class B extends A { n(){return 2} } }")
        assertFlat("instances of a shared class",
                   "class A { constructor(){ this.x=1 } } class B extends A { }" +
                   "for (var i=0;i<$N;i++){ var b=new B(); b=null; }")
        assertFlat("constructor with a prototype property",
                   "function F(){ this.a=1 } F.prototype.m=function(){ return 1 };" +
                   "for (var i=0;i<$N;i++){ var o=new F(); o.m(); o=null; }")
        assertFlat("subclassed builtin",
                   "class L extends Array { } for (var i=0;i<$N;i++){ var a=new L(); a.push(i); a=null; }")
    }

    /// The headline case, stated directly: a prototype that 100 000 objects
    /// were created from must die with them. Before, `p` reached the end of
    /// the run with a refcount of 100 001.
    /// The hashed shape table is swept by the collector. A loop that builds a
    /// fresh prototype parks one hashed root shape per prototype, and a shape
    /// owns one counted reference to its prototype (Round 12), so before the
    /// sweep those prototypes were immortal — ~0.72 objects per iteration,
    /// until `shapes.maxHashed` (16 384) was reached and every later object
    /// got a private shape and permanent IC misses instead.
    func testFreshPrototypeLoopsDoNotGrowTheShapeTable() {
        assertFlat("fresh prototype per iteration", """
            for (var i = 0; i < $N; i++) { var p = { k: i }; var o = Object.create(p); o.x = i; }
            """, slack: 512)
        assertFlat("fresh class per iteration", """
            for (var i = 0; i < $N; i++) {
                var A = class { constructor() { this.x = i; } m() { return this.x; } };
                var a = new A(); a.m();
            }
            """, slack: 512)
    }

    /// The sweep must not break the inline caches, which compare shapes by raw
    /// address: a hot polymorphic read over objects whose shapes are being
    /// evicted underneath it has to keep answering correctly.
    func testShapeEvictionKeepsInlineCachesHonest() {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        let src = """
            function read(o) { return o.a + o.b; }
            var bad = 0;
            for (var pass = 0; pass < 40; pass++) {
                var protos = [];
                for (var i = 0; i < 300; i++) protos.push({ tag: i });
                for (var i = 0; i < 300; i++) {
                    var o = Object.create(protos[i]);
                    o.a = i; o.b = i + 1;
                    if (read(o) !== 2 * i + 1) bad++;
                    if (o.tag !== i) bad++;
                }
                protos = null;
            }
            bad
            """
        let r = ctx.eval(input: src, filename: "<shape-evict>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        XCTAssertFalse(r.isException, "shape-eviction stress threw")
        XCTAssertEqual(ctx.toInt32(r), 0, "reads through evicted shapes gave wrong answers")
        r.freeValue()
        runGC(rt)
        XCTAssertLessThan(rt.shapeHashCount, 4000,
                          "the shape table kept \(rt.shapeHashCount) shapes after the sweep")
        print("[rc-leak] shape table after eviction stress: \(rt.shapeHashCount) "
              + "(\(rt.shapesEvicted) swept)")
    }

    func testAPrototypeDiesWithItsInstances() {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        let setup = ctx.eval(input: """
            var p = { x: 1 };
            var w = new WeakRef(p);
            for (var i = 0; i < 100000; i++) { Object.create(p); }
            p = null;
            """, filename: "<proto-weakref>", evalFlags: 0)
        XCTAssertFalse(setup.isException, "setup threw")
        setup.freeValue()
        runGC(rt)
        let alive = ctx.eval(input: "w.deref() !== undefined",
                             filename: "<proto-weakref-check>", evalFlags: 0)
        XCTAssertFalse(alive.isException, "check threw")
        XCTAssertFalse(alive.toBool(), "the prototype outlived its 100 000 instances")
        alive.freeValue()
    }

    // MARK: - Retained native -> JS calls (JeffJSContext.callRetained)

    func testRetainedCallbackSitesDoNotLeak() {
        // The call holds its own references to the function, receiver and
        // arguments and must give every one back.
        assertFlat("getter call",
                   "var o={ get x(){ return {} } }; for (var i=0;i<$N;i++){ var v=o.x; v=null; }")
        assertFlat("inherited setter call",
                   "var p={ set x(v){ this._x=v } }; var o=Object.create(p); for (var i=0;i<$N;i++){ o.x={}; }")
        assertFlat("getter that deletes itself",
                   "for (var i=0;i<$N;i++){ var o={ get x(){ delete this.x; return 1 } }; o.x; o=null; }")
        assertFlat("Map.forEach",
                   "var m=new Map([[{},{}],[{},{}]]); for (var i=0;i<$N/10;i++){ m.forEach(function(v,k){ return {} }); }")
        assertFlat("Map.forEach deleting its entry",
                   "for (var i=0;i<$N/10;i++){ var m=new Map([[{},{}]]); m.forEach(function(v,k){ m.delete(k) }); m=null; }")
        // Revocation keeps target and handler until the proxy dies.
        assertFlat("revoked proxies",
                   "for (var i=0;i<$N/10;i++){ var r=Proxy.revocable({}, {get:function(){ r.revoke(); return 1 }}); r.proxy.x; r=null; }")
        assertFlat("sort comparator that throws",
                   "var a=[{},{},{}]; for (var i=0;i<$N/10;i++){ try { a.sort(function(){ throw 0 }) } catch(e){} }")
    }

    // MARK: - Idle heap growth (timers / animation frames on a live page)

    func testBoundFunctionsReleaseTheirTarget() {
        // freeObject dropped the .boundFunction payload without releasing the
        // target, bound `this` and bound arguments that bind() dup'd, so every
        // `f.bind(...)` of a short-lived function leaked it and its closure.
        assertFlat("bind a fresh closure", "for (var i=0;i<$N;i++){ var f=function(){ return i }; var g=f.bind(null); g(); }")
        assertFlat("bound arguments",      "for (var i=0;i<$N;i++){ var f=function(a,b){ return a }; f.bind({}, {x:i}, [i])(); }")
        assertFlat("bound method cycle",   "for (var i=0;i<$N;i++){ var o={ f:function(){ return this } }; o.g=o.f.bind(o); o=null; }")
    }

    func testCyclesThroughCollectionsAreCollected() {
        // Map/Set entries, promise results/reactions and a resolver's promise
        // are counted edges the collector did not follow, so any cycle through
        // one of them was immortal.
        assertFlat("Map cycle",  "for (var i=0;i<$N;i++){ var o={ m:new Map() }; o.m.set('self', o); o=null; }")
        assertFlat("Map key cycle", "for (var i=0;i<$N;i++){ var o={ m:new Map() }; o.m.set(o, 1); o=null; }")
        assertFlat("Set cycle",  "for (var i=0;i<$N;i++){ var o={ s:new Set() }; o.s.add(o); o=null; }")
        assertFlat("pending promise cycle",
                   "for (var i=0;i<$N;i++){ var o={}; o.p=new Promise(function(r){ o.r=r }); o.p.then(function(){ return o }); o=null; }")
        assertFlat("settled promise cycle", "for (var i=0;i<$N;i++){ var o={}; o.p=Promise.resolve(o); o=null; }")
    }

    func testWeakCollectionsDoNotOwnTheirKeys() {
        // WeakMap/WeakSet dup'd their keys like a Map, so a long-lived weak
        // collection (a module cache, Babel's private-field WeakMap) kept
        // every key it ever saw.
        assertFlat("WeakMap cache",   "var wm=new WeakMap(); for (var i=0;i<$N;i++){ var k={}; wm.set(k, {v:i}); k=null; }")
        assertFlat("WeakSet cache",   "var ws=new WeakSet(); for (var i=0;i<$N;i++){ var k={}; ws.add(k); k=null; }")
        assertFlat("value refers to key (ephemeron)",
                   "var wm=new WeakMap(); for (var i=0;i<$N;i++){ var k={}; wm.set(k, { k:k }); k=null; }")
        assertFlat("private-field pattern",
                   "var _p=new WeakMap(); function C(){ _p.set(this, { self:this, f:function(){} }) } for (var i=0;i<$N;i++){ new C(); }")
        assertFlat("constructor entries", "for (var i=0;i<$N;i++){ var k={}; var w=new WeakMap([[k, {k:k}]]); w=null; k=null; }")
    }

    func testWeakCollectionSemantics() {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        let r = ctx.eval(input: """
            var wm = new WeakMap(), ws = new WeakSet(), out = [];
            var a = {}, b = {};
            wm.set(a, 1).set(b, 2); ws.add(a);
            out.push(wm.get(a), wm.get(b), wm.has(a), ws.has(a), ws.has(b));
            wm.set(a, 3); out.push(wm.get(a));
            out.push(wm.delete(a), wm.has(a), wm.delete(a), ws.delete(a), ws.has(a));
            wm.set(a, 4); out.push(wm.get(a));
            for (var i = 0; i < 1000; i++) wm.set({}, i);   // keys die at once
            out.push(wm.get(b));
            var threw = false; try { wm.set(1, 1) } catch (e) { threw = e instanceof TypeError }
            out.push(threw);
            out.join(',')
            """, filename: "<weak-semantics>", evalFlags: 0)
        XCTAssertEqual(ctx.toSwiftString(r), "1,2,true,true,false,3,true,false,false,true,false,4,2,true")
        r.freeValue()
        runGC(rt)
        // Only a and b are still keyed; the 1 000 temporaries left no records.
        XCTAssertEqual(rt.weakMapKeyRecords.count, 2)
    }

    func testMapChurnDoesNotGrowTheRecordTable() {
        // Deleted records stayed in the table forever: a Map used as a queue
        // grew by one record per insertion.
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        let m = ctx.eval(input: """
            var m = new Map(), seen = 0;
            for (var i = 0; i < 100000; i++) { m.set(i, {v:i}); if (i >= 3) m.delete(i - 3); }
            // Iteration that deletes as it goes still visits every entry once.
            var it = m.keys(); m.set('x', 1);
            for (var k of it) { seen++; m.delete(k); }
            m.set('y', 2); m.forEach(function(v, k){ seen += 10; m.delete(k) });
            m.set('z', 3);
            m
            """, filename: "<map-churn>", evalFlags: 0)
        guard let obj = m.toObject(), case .mapState(let s) = obj.payload else {
            XCTFail("not a Map"); m.freeValue(); return
        }
        XCTAssertLessThan(s.records.count, 64, "the record table kept \(s.records.count) records for \(s.count) entries")
        XCTAssertEqual(s.count, 1)
        m.freeValue()
        let seen = ctx.eval(input: "seen", filename: "<seen>", evalFlags: 0)
        XCTAssertEqual(seen.toInt32(), 4 + 10)
    }

    func testClosureVariableStoresReleaseTheOldValue() {
        // put_var_ref / set_var_ref overwrote the captured binding without
        // releasing what it held: every assignment to a closure variable
        // leaked the previous value (React's module-level
        // `workInProgressHook = hook` leaked every hook of every render).
        assertFlat("plain store",
                   "var f=(function(){ var v=null; return function(){ v={x:1}; } })(); for (var i=0;i<$N;i++) f();")
        assertFlat("store in expression",
                   "var f=(function(){ var v=null; return function(){ var y=(v={x:1}); } })(); for (var i=0;i<$N;i++) f();")
        assertFlat("chained through a property",
                   "var f=(function(){ var v={}; return function(){ v = v.next = {x:1}; } })(); for (var i=0;i<$N;i++) f();")
        assertFlat("let binding",
                   "var f=(function(){ let v=null; return function(){ v={x:1}; } })(); for (var i=0;i<$N;i++) f();")
        // `y = (v = x)` on a `let` is `dup; put_var_ref_check; put_loc`: the
        // trace's chained-store peek kept the dup'd reference too.
        assertFlat("let binding in expression",
                   "var f=(function(){ let v=null, w=null; return function(){ var y=(v={x:1}); w = v = {y:2}; } })(); for (var i=0;i<$N;i++) f();")
        assertFlat("live (not yet closed) binding",
                   "for (var i=0;i<$N;i++){ (function(){ var v={x:1}; var g=function(){ v={y:2}; v={z:3}; }; g(); })(); }")
        assertFlat("hook list",
                   "var r=(function(){ var wip=null, fiber=null; function mount(){ var h={memoizedState:null,next:null}; if (wip===null) fiber.memoizedState = wip = h; else wip = wip.next = h; return wip } return function(){ fiber={}; wip=null; mount(); mount(); mount(); wip=null } })(); for (var i=0;i<$N;i++) r();")
    }

    func testFindLastReleasesUnmatchedElements() {
        assertFlat("findLast no match",  "for (var i=0;i<$N;i++){ [{a:1},{a:2}].findLast(function(){ return false }); }")
        assertFlat("findLast match",     "for (var i=0;i<$N;i++){ [{a:1},{a:2}].findLast(function(x){ return x.a === 1 }); }")
        assertFlat("findLastIndex",      "for (var i=0;i<$N;i++){ [{a:1},{a:2}].findLastIndex(function(x){ return x.a === 1 }); }")
    }

    func testIdleCollectionRunsBetweenTasks() {
        // A page's timers leave cyclic garbage far below the allocation
        // watermark; the idle trigger collects it at the next task boundary.
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        let tick = ctx.eval(input: """
            (function () { for (var i = 0; i < 300; i++) { var o = {}; o.self = o; o.f = function () { return o }; } })
            """, filename: "<tick>", evalFlags: 0)
        runGC(rt)
        let before = rt.gcObjects.count
        for _ in 0..<40 {
            ctx.callFunction(tick, thisVal: .undefined, args: []).freeValue()
            rt.gcLastEnd = 0   // pretend the last collection was long ago
        }
        let idleRuns = rt.gcIdleRuns
        XCTAssertGreaterThan(idleRuns, 0, "no idle collection ran")
        // 40 ticks x 300 cycles would be 12 000+ objects without a collection.
        XCTAssertLessThan(rt.gcObjects.count - before, 2_000,
                          "idle ticks left \(rt.gcObjects.count - before) objects behind (\(idleRuns) idle runs)")
        tick.freeValue()
    }
}
