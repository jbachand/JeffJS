// FreedValueConformance.swift
// JeffJS — conformance group "FreedValueTouches": ownership paths that used to
// free a value something still referenced. Each case runs with zombie mode on
// (JEFFJS_ZOMBIES semantics: freed objects/strings stay allocated and flagged)
// and the object pool off, so an over-release is counted deterministically as
// a touch instead of silently reusing the memory; a case passes when its
// result is right AND it caused no touch on a freed value.

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    /// Evaluate `code` (expected true) with zombie mode forced on, and require
    /// zero touches on freed values while it ran.
    private mutating func evalNoFreedTouches(_ ctx: JeffJSContext, _ label: String, _ code: String) {
        let savedZombies = jeffJSZombiesEnabled
        let savedDebug = jeffJS_refDebugMode
        let savedNoPool = jeffJSObjectPoolDisabled
        jeffJSZombiesEnabled = true
        jeffJS_refDebugMode = true
        jeffJSObjectPoolDisabled = true
        let before = JeffJSZombieDebug.touches
        evalCheckBool(ctx, code, expect: true)
        let touched = JeffJSZombieDebug.touches - before
        jeffJSZombiesEnabled = savedZombies
        jeffJS_refDebugMode = savedDebug
        jeffJSObjectPoolDisabled = savedNoPool
        assert(touched == 0, "\(label): \(touched) touch(es) on freed values")
    }

    mutating func testFreedValueTouches() {
        // Own runtime: the zombie window keeps what it frees allocated, and
        // this group's leftovers should not sit in the shared context. Not
        // freed, like the suite's per-group contexts (runtime teardown is not
        // what is under test here).
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()

        // RegExp pattern ownership: the payload held its pattern string
        // without a count, so once the value that supplied it died, `source`
        // handed a freed string back to JS (apple.com, marked.js `edit()`).
        evalNoFreedTouches(ctx, "RegExp source after the pattern value died", """
            var s = "ab" + "cd".repeat(3);
            var re = new RegExp(s, "g");
            s = null;
            var a = re.source; a = null;
            var b = re.source;
            b === "abcdcdcd" && re.source === "abcdcdcd" && String(re) === "/abcdcdcd/g"
            """)
        evalNoFreedTouches(ctx, "marked edit(re).replace(...).getRegex()", """
            function edit(e, t) { return e = e.source, t = t || "", {
                replace: function (t, n) { return n = (n = n.source || n).replace(/(^|[^\\[])\\^/g, "$1"), e = e.replace(t, n), this },
                getRegex: function () { return new RegExp(e, t) } } }
            var r = { hr: /^ {0,3}((?:- *){3,})(?:\\n+|$)/, heading: /^ *(#{1,6}) *([^\\n]+?) *#* *(?:\\n+|$)/,
                      paragraph: /^([^\\n]+(?:\\n?(?!hr|heading| {0,3}>)[^\\n]+)+)/, blockquote: /^( {0,3}> ?(paragraph|[^\\n]*)(?:\\n|$))+/ };
            r.paragraph = edit(r.paragraph).replace("hr", r.hr).replace("heading", r.heading).getRegex();
            r.blockquote = edit(r.blockquote).replace("paragraph", r.paragraph).getRegex();
            var gfm = edit(r.paragraph).replace("(?!", "(?!" + r.hr.source + "|").getRegex();
            var ok = true;
            for (var i = 0; i < 20; i++) ok = ok && edit(r.blockquote).getRegex().source === r.blockquote.source;
            ok && r.paragraph.source.indexOf("#{1,6}") > 0 && gfm.source.length > r.paragraph.source.length
            """)
        evalNoFreedTouches(ctx, "RegExp from RegExp, compile(), matchAll, literals", """
            var p = "x" + "y".repeat(2);
            var r1 = new RegExp(p); p = null;
            var r2 = new RegExp(r1, "i"); r1 = null;
            var c = /q/; c.compile("m" + "n".repeat(2), "g"); var cs = c.source; c.compile(r2);
            var m = [..."ab1ab2".matchAll(new RegExp("ab" + "\\\\d", "g"))];
            var lit; for (var i = 0; i < 5; i++) lit = /z+/g.source;
            r2.source === "xyy" && cs === "mnn" && c.source === "xyy" && m.length === 2 && lit === "z+" &&
            new RegExp(123).source === "123" && new RegExp().source === "(?:)"
            """)

        // Argument ownership: generator and async callees reached through a
        // native caller (Function.prototype.call/apply, array callbacks,
        // proxies) released the caller's argument references a second time
        // (apple.com globalnav: `q.apply(this, [ev])` into an async-to-
        // generator helper freed the event wrapper mid-dispatch -> SIGSEGV).
        evalNoFreedTouches(ctx, "generator via call/apply", """
            function* g(a) { return a.x; }
            var o = { x: 5 }, arr = [o], got = [];
            for (var i = 0; i < 4; i++) {
                got.push(g.call(null, o).next().value, g.apply(null, [o]).next().value,
                         g.apply(null, arr).next().value, Reflect.apply(g, null, [o]).next().value,
                         new Proxy(g, {}).call(null, o).next().value);
            }
            got.every(function (v) { return v === 5 }) && o.x === 5 && arr[0] === o
            """)
        evalNoFreedTouches(ctx, "async function via call/apply and array callbacks", """
            async function af(a) { return a.x; }
            async function* ag(a) { return a.x; }
            var o = { x: 7 };
            for (var i = 0; i < 4; i++) {
                af.call(null, o); af.apply(null, [o]); ag.call(null, o).next();
                [o].forEach(af); [o].map(af); [o].filter(af); [o].some(af); [o].reduce(af, o);
                af.bind(null, o)();
            }
            o.x === 7
            """)
        evalNoFreedTouches(ctx, "async-to-generator helper (esbuild __async)", """
            var I = (S, w, L) => new Promise((W, U) => {
                var Y = te => { try { P(L.next(te)) } catch (G) { U(G) } },
                    H = te => { try { P(L.throw(te)) } catch (G) { U(G) } },
                    P = te => te.done ? W(te.value) : Promise.resolve(te.value).then(Y, H);
                P((L = L.apply(S, w)).next()) });
            var seen = 0;
            var q = j => I(this, [j], function* ({ event: e, callback: cb }) {
                const { detail: { target: t } } = e; if (t && cb) { seen += yield cb(); } });
            var listener = ev => { q({ event: ev, callback: function () { return 1 } }) };
            var ev = { detail: { target: { id: 1 } } };
            for (var i = 0; i < 10; i++) listener(ev);
            ev.detail.target.id === 1
            """)

        _ = rt
        testDeadPrototypeShapes()
    }

    /// Run `steps` in order (each must evaluate to true) with a full collection
    /// after every one, zombie mode on and the pool off throughout: a value the
    /// collector frees in one run and something releases in a later run is only
    /// visible if the freed object stays allocated and flagged across both.
    private mutating func evalStepsNoFreedTouches(_ rt: JeffJSRuntime, _ ctx: JeffJSContext,
                                                  _ label: String, _ steps: [String]) {
        let savedZombies = jeffJSZombiesEnabled
        let savedDebug = jeffJS_refDebugMode
        let savedNoPool = jeffJSObjectPoolDisabled
        jeffJSZombiesEnabled = true
        jeffJS_refDebugMode = true
        jeffJSObjectPoolDisabled = true
        let before = JeffJSZombieDebug.touches
        for code in steps {
            evalCheckBool(ctx, code, expect: true)
            rt.runGC()
        }
        let touched = JeffJSZombieDebug.touches - before
        jeffJSZombiesEnabled = savedZombies
        jeffJS_refDebugMode = savedDebug
        jeffJSObjectPoolDisabled = savedNoPool
        assert(touched == 0, "\(label): \(touched) touch(es) on freed values")
    }

    /// A shape owns one counted reference to its prototype. When the collector
    /// frees a prototype, every shape that names it is unreachable too — but a
    /// hashed shape is kept cached at zero owners, so it outlived the group and
    /// the shape sweep of a *later* collection released the freed prototype
    /// again (`gcFreeCycles -> freeShape -> jeffJS_shapeSetProto`; Google's tag
    /// script, 13 touches on /tmp/fixtures/threes). Each case gets a fresh
    /// runtime so the hashed-shape count, which gates the sweep, is known.
    private mutating func testDeadPrototypeShapes() {
        // 600 distinct live transition shapes: past `shapes.evictThreshold`
        // (512), so the collection that follows sweeps zero-owner shapes.
        let fillTable = """
            var keep = [];
            for (var i = 0; i < 600; i++) { var q = {}; q["k" + i] = i; keep.push(q); }
            keep.length === 600
            """

        // The prototype and an instance in one cycle: the instance's shape
        // still had an owner when the dead set was chosen, so it was not
        // sweepable; freeing the instance left it cached on a freed prototype.
        do {
            let rt = JeffJSRuntime()
            let ctx = rt.newContext()
            evalStepsNoFreedTouches(rt, ctx, "prototype and instance in one cycle", [
                fillTable,
                """
                function mk(i) { var P = { m: i }; var o = Object.create(P); o.p = P; P.o = o; return o.m; }
                var s = 0; for (var i = 0; i < 20; i++) s += mk(i);
                s === 190
                """,
                "keep.length === 600",
                "var o2 = Object.create({ m: 3 }); o2.p = 1; o2.m + o2.p === 4",
            ])
        }

        // No owners left, but the first collection runs below the sweep
        // threshold, so the shape stays cached; the table then grows past it
        // and the next collection sweeps the shape and its freed prototype.
        do {
            let rt = JeffJSRuntime()
            let ctx = rt.newContext()
            // Installing the intrinsics leaves hundreds of zero-owner
            // intermediate transition shapes; one collection sweeps them.
            rt.runGC()
            assert(rt.shapeHashCount + 100 < JeffJSConfig.shapesEvictThreshold,
                   "dead prototype, sweep later: \(rt.shapeHashCount) hashed shapes after a collection")
            evalStepsNoFreedTouches(rt, ctx, "dead prototype, shape swept by a later collection", [
                """
                function mk(i) { var P = { m: i }; P.self = P; var o = Object.create(P); return o.m; }
                var s = 0; for (var i = 0; i < 20; i++) s += mk(i);
                s === 190
                """,
                fillTable,
                "keep[599].k599 === 599",
            ])
        }

        // What the tag script does: Closure-style classes built inside a
        // function that returns. B.prototype sits on a shape whose prototype
        // is A.prototype, and both constructor <-> prototype pairs are cycles.
        do {
            let rt = JeffJSRuntime()
            let ctx = rt.newContext()
            evalStepsNoFreedTouches(rt, ctx, "Closure-style class hierarchy dropped", [
                """
                function build(n) {
                    function A() { this.a = n; }
                    A.prototype.f = function () { return this.a; };
                    function B() { A.call(this); this.b = 2; }
                    B.prototype = Object.create(A.prototype);
                    B.prototype.constructor = B;
                    B.prototype.isSupported = function () { return true; };
                    var x = new B();
                    return x.f() + x.b + (x.isSupported() ? 1 : 0);
                }
                var t = 0; for (var i = 0; i < 20; i++) t += build(i);
                t === 250
                """,
                fillTable,
                "var t2 = 0; for (var i = 0; i < 20; i++) t2 += build(i); t2 === 250",
                "keep.length === 600 && build(7) === 10",
            ])
        }
    }
}
