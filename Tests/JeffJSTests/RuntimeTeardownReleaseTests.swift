// RuntimeTeardownReleaseTests.swift
// JeffJS — freeing a context and its runtime must give the whole JS heap back:
// objects, strings and function bytecode still referenced from the global object
// (a page's heap when the host tears its engine down) are deallocated.
//
//   swift test -c release --filter RuntimeTeardownReleaseTests

import XCTest
@testable import JeffJS

final class RuntimeTeardownReleaseTests: XCTestCase {

    func testFreeReleasesLiveHeap() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["JEFFJS_ZOMBIES"] == "1", "zombie mode keeps every freed object allocated on purpose")
        weak var object: JeffJSObject?
        weak var function: JeffJSObject?
        weak var string: JeffJSStringBase?
        weak var body: JeffJSFunctionBytecode?
        do {
            let rt = JeffJSRuntime()
            let ctx = rt.newContext()
            let v = ctx.eval(input: """
                // `s` is assigned, not an object-literal property: a literal's property
                // value keeps one count too many (a refcount leak of its own, open), and
                // teardown frees by counts — such a string still outlives the runtime.
                var keep = { list: [] };
                keep.s = 'abc'.repeat(50);
                for (var i = 0; i < 1000; i++) keep.list.push({ i: i, t: 'v' + i });
                keep.f = function (x) { return x + keep.s.length };
                keep.self = keep;   // a cycle
                keep
                """, filename: "<teardown>", evalFlags: 0)
            XCTAssertFalse(v.isException)
            object = v.toObject()
            let f = ctx.getPropertyStr(obj: v, name: "f")
            function = f.toObject()
            if case .bytecodeFunc(let fb, _, _)? = function?.payload { body = fb }
            let s = ctx.getPropertyStr(obj: v, name: "s")
            string = s.stringBase
            s.freeValue(); f.freeValue(); v.freeValue()
            XCTAssertNotNil(object); XCTAssertNotNil(function); XCTAssertNotNil(string); XCTAssertNotNil(body)
            ctx.free()
            rt.free()
        }
        XCTAssertNil(object, "a live object outlived its runtime")
        XCTAssertNil(function, "a live function outlived its runtime")
        XCTAssertNil(string, "a live string outlived its runtime")
        XCTAssertNil(body, "a live function body outlived its runtime")
    }

    /// The intrinsics a context installs (prototypes, constructors, builtin
    /// functions, the global object) are kept off the GC list, so before
    /// JeffJSRuntime.initObjects nothing freed them: ~1 000 builtins per context
    /// outlived it, and through their runtime / realm back-pointers the runtime
    /// and the context too, with what those still held (a page per navigation).
    func testFreeReleasesIntrinsicsContextAndRuntime() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["JEFFJS_ZOMBIES"] == "1", "zombie mode keeps every freed object allocated on purpose")
        weak var builtin: JeffJSObject?
        weak var proto: JeffJSObject?
        weak var weakContext: JeffJSContext?
        weak var weakRuntime: JeffJSRuntime?
        do {
            let rt = JeffJSRuntime()
            let ctx = rt.newContext()
            let f = ctx.eval(input: "Array.prototype.push", filename: "<intrinsic>", evalFlags: 0)
            let p = ctx.eval(input: "Object.prototype", filename: "<intrinsic>", evalFlags: 0)
            XCTAssertFalse(f.isException); XCTAssertFalse(p.isException)
            builtin = f.toObject()
            proto = p.toObject()
            f.freeValue(); p.freeValue()
            weakContext = ctx
            weakRuntime = rt
            ctx.free()
            rt.free()
        }
        XCTAssertNil(builtin, "a builtin function outlived its runtime")
        XCTAssertNil(proto, "Object.prototype outlived its runtime")
        XCTAssertNil(weakContext, "the context outlived its free()")
        // The runtime object itself can still be pinned by a few objects whose
        // Swift retain leaked (their `ownerRuntime`; open) — but it holds nothing
        // any more: free() empties its string caches.
        if let rt = weakRuntime {
            XCTAssertTrue(rt.sharedStrings.isEmpty && rt.atomJSStrings.isEmpty && rt.initObjects.isEmpty,
                          "a freed runtime still holds its caches")
        }
    }

    /// Date's installer took four Swift retains on the constructor (`makeObject` — the
    /// object's free gives one back), and every getter / setter call took one more on the
    /// accessor function: Date, and each accessor that ever ran, outlived the runtime —
    /// and pinned it through `ownerRuntime` (the watch creates a runtime per page).
    func testFreeReleasesDateAndCalledAccessors() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["JEFFJS_ZOMBIES"] == "1", "zombie mode keeps every freed object allocated on purpose")
        weak var dateCtor: JeffJSObject?
        weak var dateProto: JeffJSObject?
        weak var getter: JeffJSObject?
        weak var setter: JeffJSObject?
        weak var weakRuntime: JeffJSRuntime?
        do {
            let rt = JeffJSRuntime()
            let ctx = rt.newContext()
            let v = ctx.eval(input: """
                var acc = { _v: 0, get v() { return this._v; }, set v(x) { this._v = x; } };
                acc.v = 2; var inherited = Object.create(acc); inherited.v = 3;
                var d = new Date(0); d.getTime() + acc.v + inherited.v + new Date(5).valueOf();
                [Date, Date.prototype, Object.getOwnPropertyDescriptor(acc, 'v').get, Object.getOwnPropertyDescriptor(acc, 'v').set]
                """, filename: "<teardown-date>", evalFlags: 0)
            XCTAssertFalse(v.isException)
            for (i, name) in ["0", "1", "2", "3"].enumerated() {
                let e = ctx.getPropertyStr(obj: v, name: name)
                switch i {
                case 0: dateCtor = e.toObject()
                case 1: dateProto = e.toObject()
                case 2: getter = e.toObject()
                default: setter = e.toObject()
                }
                e.freeValue()
            }
            v.freeValue()
            XCTAssertNotNil(dateCtor); XCTAssertNotNil(dateProto); XCTAssertNotNil(getter); XCTAssertNotNil(setter)
            weakRuntime = rt
            ctx.free()
            rt.free()
        }
        XCTAssertNil(dateCtor, "Date outlived its runtime")
        XCTAssertNil(dateProto, "Date.prototype outlived its runtime")
        XCTAssertNil(getter, "a getter that ran outlived its runtime")
        XCTAssertNil(setter, "a setter that ran outlived its runtime")
        XCTAssertNil(weakRuntime, "a fresh runtime outlived its free()")
    }

    /// A lazily compiled function's body is parsed and thrown away (only its free
    /// names are kept); the string literals the parser put in its constant pool —
    /// and in the pools of the definitions nested in it — own one reference each,
    /// which the drop must give back (JeffJSCompiler.releaseDroppedConstants). It
    /// used to empty the arrays only: every literal of every lazy function leaked
    /// at parse time, beyond the reach of the runtime's teardown (wikipedia: 36 k
    /// strings per page view).
    func testDroppedLazyDefinitionReleasesItsLiterals() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["JEFFJS_ZOMBIES"] == "1", "zombie mode keeps every freed object allocated on purpose")
        weak var outerLiteral: JeffJSStringBase?
        weak var innerLiteral: JeffJSStringBase?
        do {
            let outer = JeffJSFunctionDefCompiler()
            let inner = JeffJSFunctionDefCompiler()
            outer.childFunctions = [inner]
            let a = JeffJSValue.makeString(JeffJSString(swiftString: "outer literal " + String(repeating: "a", count: 40)))
            let b = JeffJSValue.makeString(JeffJSString(swiftString: "inner literal " + String(repeating: "b", count: 40)))
            outerLiteral = a.stringBase
            innerLiteral = b.stringBase
            outer.cpool = [.undefined, a, JeffJSValue.newFloat64(1.5)]
            inner.cpool = [b]
            XCTAssertNotNil(outerLiteral); XCTAssertNotNil(innerLiteral)
            JeffJSCompiler.releaseDroppedConstants(outer)
            XCTAssertTrue(outer.cpool.isEmpty); XCTAssertTrue(inner.cpool.isEmpty)
        }
        XCTAssertNil(outerLiteral, "a dropped lazy body's literal leaked")
        XCTAssertNil(innerLiteral, "a literal of a definition nested in a dropped lazy body leaked")
    }
}

// MARK: - Realms (iframe realms: JeffJSRuntime.newRealm) — teardown with a second realm

extension RuntimeTeardownReleaseTests {

    /// Script run in each realm: closures, classes, tagged templates (a template
    /// object in the constant pool), regexps, generators, a few thousand objects.
    static let realmHeapScript = """
        var realmKeep = { list: [], fns: [], tag: function (s) { return s; } };
        function mk(i) { var o = { i: i, s: 'v' + i, a: [i, i + 1], self: null }; o.self = o; return o; }
        for (var i = 0; i < 3000; i++) realmKeep.list.push(mk(i));
        class K { constructor(x) { this.x = x; } get y() { return this.x * 2; } static z() { return 1; } }
        for (var i = 0; i < 200; i++) realmKeep.list.push(new K(i));
        for (var i = 0; i < 50; i++) (function (j) { realmKeep.fns.push(function () { return j + realmKeep.list.length; }); })(i);
        realmKeep.tpl = realmKeep.tag`a${1}b${2}c`;
        realmKeep.tplFn = function () { return realmKeep.tag`x${3}y`; };
        realmKeep.tplFn();
        realmKeep.re = /ab+c/g;
        realmKeep.gen = (function* () { yield 1; yield 2; })();
        realmKeep.gen.next();
        realmKeep.map = new Map([[realmKeep, realmKeep.list[0]]]);
        realmKeep.p = Promise.resolve(realmKeep);
        realmKeep.p.then(function (v) { v.resolved = true; });
        Object.prototype.__realmMark = realmKeep;
        Array.prototype.__realmFn = realmKeep.fns[0];
        """

    /// The iframe-realm teardown (the app's JSScriptEngine.teardown): a page's main
    /// context and a frame realm of the same runtime, their objects referencing each
    /// other, freed realm first, then the main context, then the runtime. -O app
    /// builds crashed in freeRemainingHeap with this (2026-10-06).
    func testFreeWithRealmCrossReferences() throws {
        for round in 0..<3 {
            let rt = JeffJSRuntime()
            let ctx = rt.newContext()
            guard let realm = rt.newRealm() else { return XCTFail("no realm") }
            for c in [ctx, realm] {
                let r = c.eval(input: Self.realmHeapScript, filename: "<realm-heap>", evalFlags: 0)
                XCTAssertFalse(r.isException, "round \(round)")
                r.freeValue()
            }
            let wg = realm.getGlobalObject()
            let g = ctx.getGlobalObject()
            _ = ctx.setPropertyStr(obj: g, name: "w", value: wg.dupValue())
            _ = realm.setPropertyStr(obj: wg, name: "parentWin", value: g.dupValue())
            g.freeValue(); wg.freeValue()
            let r2 = ctx.eval(input: """
                var fromW = [];
                for (var i = 0; i < 1000; i++) fromW.push(w.eval('({ k: ' + i + ', arr: new Array(3), f: function () { return parentWin; } })'));
                w.mainRef = { fromMain: realmKeep, f: function () { return w; } };
                w.mainFns = realmKeep.fns;
                realmKeep.wList = w.realmKeep.list;
                realmKeep.wCtor = new w.Function('a', 'return a + 1');
                realmKeep.wArr = w.Array.from([1, 2, 3]);
                realmKeep.wTpl = w.eval('realmKeep.tplFn')();
                w.eval('(function (f) { return f(); })')(function () { return [] instanceof Array; });
                1
                """, filename: "<realm-cross>", evalFlags: 0)
            XCTAssertFalse(r2.isException, "round \(round)")
            r2.freeValue()
            _ = rt.executePendingJobs()
            // The app frees the frame realms first, then the page's context, then the runtime.
            realm.free()
            ctx.free()
            rt.free()
        }
    }
}

extension RuntimeTeardownReleaseTests {
    /// The same heap in a single context (no realm).
    func testFreeRealmHeapScriptSingleContext() throws {
        for round in 0..<3 {
            let rt = JeffJSRuntime()
            let ctx = rt.newContext()
            let r = ctx.eval(input: Self.realmHeapScript, filename: "<realm-heap>", evalFlags: 0)
            XCTAssertFalse(r.isException, "round \(round)")
            r.freeValue()
            _ = rt.executePendingJobs()
            ctx.free()
            rt.free()
        }
    }
}

extension RuntimeTeardownReleaseTests {
    /// A page with an iframe realm over a nested document (the app's
    /// JeffJSFrameRealms: DOM + event bridges per realm, one wrapper per node per
    /// realm, nodes moved between the documents, listeners, the polyfills run in
    /// both realms), torn down like a navigation: frame realm, page, runtime.
    @MainActor
    func testFreeWithDOMRealm() throws {
        for round in 0..<3 {
            let e = JeffJSEnvironment()
            let child = DOMNode.document()
            let html = DOMNode.element(tag: "html")
            html.appendChild(DOMNode.element(tag: "head"))
            html.appendChild(DOMNode.element(tag: "body"))
            child.appendChild(html)
            guard let wg = e.makeChildRealm(document: child) else { return XCTFail("no realm") }
            let ctx = e.context
            let g = ctx.getGlobalObject()
            _ = ctx.setPropertyStr(obj: g, name: "w", value: wg)
            g.freeValue()
            for js in [Self.realmHeapScript, "w.eval(\(Self.jsLiteral(Self.realmHeapScript)))", """
                var frameNodes = [];
                for (var i = 0; i < 300; i++) {
                    var d = w.document.createElement('div'); d.id = 'f' + i; d.textContent = 'x' + i;
                    d.addEventListener('click', function () { return realmKeep; });
                    w.document.body.appendChild(d); frameNodes.push(d);
                    var p = document.createElement('p'); p.className = 'c' + i;
                    p.addEventListener('click', w.eval('(function () { return realmKeep; })'));
                    if (i % 3 === 0) w.document.body.appendChild(p); else document.body.appendChild(p);
                    p.dataset.k = 'v' + i; p.classList.add('z');
                }
                w.eval('document.body.querySelectorAll("div").length') + document.querySelectorAll('p').length
                """] {
                switch e.eval(js, filename: "<dom-realm>") {
                case .success: break
                case .exception(let m): XCTFail("round \(round): \(m)")
                }
            }
            e.teardown()
        }
    }

    static func jsLiteral(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        let json = String(decoding: data, as: UTF8.self)
        return String(json.dropFirst().dropLast())
    }
}
