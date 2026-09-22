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
}
