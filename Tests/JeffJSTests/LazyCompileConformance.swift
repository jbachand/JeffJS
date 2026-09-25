// LazyCompileConformance.swift
// JeffJS — "LazyCompile": function bodies compiled on their first call.
//
// With `compile.lazyFunctions` (JeffJSCompiler.lazyStubOrEager /
// compileLazy) a function body is parsed at load (early errors) but only
// compiled when first called: until then it is a stub holding its closure
// variables, flags and source span. These cases cover what the stub has to
// get right without the body: early errors from bodies that never run,
// closures over enclosing bindings (several levels, loop `let`s, TDZ,
// const), `arguments` / `this` / `new.target` / `super` seen from lazy
// arrows, private names, direct eval and `with` (which force eager
// compilation), toString / length / name of functions never called,
// generators, async functions, default parameters and tail calls.
//
// Every case (a JS expression that must evaluate to `true`) runs twice: lazy
// (the default) and with lazy compilation off. The filename keeps them out
// of the bytecode cache (`<eval>` prefix), so the eager runs compile.
// The group also checks that the lazy runs made stubs and compiled them.
// Cache round trips of stubs and of lazily compiled bodies are in
// BytecodeCacheLazyTests.swift.

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    /// `src` must throw a SyntaxError when evaluated (indirectly) — even
    /// though the function holding the error is never called.
    private static func earlyError(_ src: String) -> String {
        let quoted = src.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "(function(){ try { (0, eval)(\"\(quoted)\"); return false; } catch (e) { return e instanceof SyntaxError; } })()"
    }

    static let lazyCompileCases: [(String, String)] = [
        // ---- Early errors from bodies that never run ----
        ("syntax error in a never-called function", earlyError("function f(){ var x = ; }")),
        ("const without an initializer in a never-called function", earlyError("function f(){ const x; }")),
        ("syntax error nested two functions deep", earlyError("function f(){ function g(){ return function(){ return 1 +; }; } }")),
        ("syntax error in a never-called arrow", earlyError("var f = (a) => { if (a) { return } } }")),
        ("syntax error in a never-called method", earlyError("var o = { m(){ return new; } }")),
        ("undeclared private name in a never-called method", earlyError("class A { m(){ return this.#nope; } }")),
        ("undeclared private name in an arrow inside a method", earlyError("class A { #p = 1; m(){ return () => this.#q; } }")),
        ("strict-mode early error in a never-called function", earlyError("function f(){ 'use strict'; with ({}) {} }")),
        ("break outside a loop in a never-called function", earlyError("function f(){ break; }")),
        ("the script with an early error runs nothing",
         "(function(){ globalThis.__lcRan = 0; try { (0, eval)('__lcRan = 1; function f(){ return 1 +; }'); } catch (e) {} return globalThis.__lcRan === 0; })()"),

        // ---- Closures over enclosing bindings ----
        ("three levels of closures, only the innermost called",
         "(function(){ var a = 1; let b = 2; const c = 3; function f(){ return function(){ return () => a + b + c; }; } a = 10; return f()()() === 15; })()"),
        ("parameter of an outer lazy function read two levels down",
         "(function(){ function a(x){ return function b(){ return function c(){ return x; }; }; } return a(7)()() === 7; })()"),
        ("lazy closures over per-iteration let",
         "(function(){ var fs = []; for (let i = 0; i < 3; i++) fs.push(function(){ return i; }); return fs.map(function(f){ return f(); }).join() === '0,1,2'; })()"),
        ("writes through a closure variable",
         "(function(){ var n = 0; function inc(){ n++; } inc(); inc(); var g = function(){ n += 10; }; g(); return n === 12; })()"),
        ("closure reads let in TDZ, then after init",
         "(function(){ function f(){ return x; } try { f(); return false; } catch (e) { if (!(e instanceof ReferenceError)) return false; } let x = 5; return f() === 5; })()"),
        ("assignment to an enclosing const throws TypeError",
         "(function(){ const k = 1; function f(){ k = 2; } try { f(); return false; } catch (e) { return e instanceof TypeError && k === 1; } })()"),
        ("free name shadowed inside a block but free outside it",
         "(function(){ var x = 'outer'; function f(){ { let x = 'block'; } return x; } return f() === 'outer'; })()"),
        ("name free in a parameter default, var of the same name in the body",
         "(function(){ var x = 'outer'; function f(a = () => x, y = a()){ var x = 'inner'; return a() + y + x; } return f() === 'outerouterinner'; })()"),
        ("many closure objects made before the first call share one body",
         "(function(){ var fs = []; for (var i = 0; i < 5; i++) fs.push(function(x){ return x + i; }); var s = 0; fs.forEach(function(f){ s += f(1); }); return s === 30; })()"),
        ("recursive call during the first call",
         "(function(){ function r(n){ return n ? r(n - 1) + 1 : 0; } return r(50) === 50; })()"),
        ("a function declared later in the parent (hoisting)",
         "(function(){ function f(){ return g() + y; } var y = 2; function g(){ return 1; } return f() === 3; })()"),
        ("hoisted function declarations inside a lazy body",
         "(function(){ function f(){ return g(); function g(){ return 5; } } return f() === 5; })()"),
        ("sloppy block function inside a lazy body",
         "(function(){ function f(){ { function h(){ return 1; } } return typeof h; } return f() === 'function'; })()"),
        ("global reads and writes from lazy code",
         "(function(){ globalThis.__lcG = 1; var f = function(){ __lcG = __lcG + 1; return __lcG; }; return f() === 2 && __lcG === 2; })()"),
        ("parameter captured and reassigned by an inner closure",
         "(function(){ function f(a){ var set = function(v){ a = v; }; set({ v: 2 }); return a.v; } var s = 0; for (var i = 0; i < 50; i++) s += f({ v: 1 }); return s === 100; })()"),
        ("a function that throws on its first call works afterwards",
         "(function(){ var n = 0; function f(){ if (n++ === 0) throw new Error('first'); return n; } try { f(); } catch (e) {} return f() === 2; })()"),

        // ---- arguments, this, new.target, super ----
        ("arguments of the enclosing function from a lazy arrow",
         "(function(){ function f(){ var g = () => arguments.length; return g(); } return f(1, 2, 3) === 3; })()"),
        ("mapped arguments in a lazy sloppy function",
         "(function(){ function f(a){ arguments[0] = 9; return a; } return f(1) === 9; })()"),
        ("this seen from a lazy arrow in a method",
         "(function(){ var o = { v: 4, m(){ return [1].map(() => this.v)[0]; } }; return o.m() === 4; })()"),
        ("new.target in a lazy function",
         "(function(){ function F(){ this.ok = new.target === F; } return new F().ok && (function(){ return new.target === undefined; })(); })()"),
        ("super property from lazy methods, instance and static",
         "(function(){ class A { m(){ return 1; } static s(){ return 10; } } class B extends A { m(){ var k = () => 1; return super.m() + k(); } static s(){ return super.s() + 1; } } return new B().m() === 2 && B.s() === 11; })()"),
        ("super in an object-literal method",
         "(function(){ var p = { m(){ return 'p'; } }; var o = { __proto__: p, m(){ return super.m() + 'o'; } }; return o.m() === 'po'; })()"),
        ("derived constructor, fields and lazy methods",
         "(function(){ class A { constructor(x){ this.x = x; } get dbl(){ return this.x * 2; } } class B extends A { y = 3; constructor(){ super(4); } sum(){ return this.x + this.y + this.dbl; } static make(){ return new B(); } } return B.make().sum() === 15; })()"),

        // ---- Private names ----
        ("private field, method and accessor used from lazy methods",
         "(function(){ class A { #f = 1; #m(){ return 2; } get #g(){ return 3; } static #s = 4; sum(){ return this.#f + this.#m() + this.#g + A.#s; } has(o){ return #f in o; } } var a = new A(); return a.sum() === 10 && a.has(a) && !a.has({}); })()"),
        ("private name read from an arrow inside a lazy method",
         "(function(){ class A { #p = 7; m(){ return () => this.#p; } } return new A().m()() === 7; })()"),
        ("private setter used from a lazy method",
         "(function(){ class A { #v = 0; set #s(x){ this.#v = x * 2; } put(x){ this.#s = x; return this.#v; } } return new A().put(5) === 10; })()"),
        ("field initializer arrow and static block",
         "(function(){ class A { x = 1; f = () => this.x; static s; static { A.s = (() => 5)(); } } return new A().f() === 1 && A.s === 5; })()"),

        // ---- Direct eval and with (compiled eagerly) ----
        ("direct eval inside a function reads enclosing bindings",
         "(function(){ var a = 1; function f(){ return eval('a + 1'); } return f() === 2; })()"),
        ("direct eval in the parent declares a var a child reads",
         "(function(){ function outer(){ eval('var z = 7'); return function(){ return z; }; } return outer()() === 7; })()"),
        ("direct eval nested two levels below the binding",
         "(function(){ var q = 3; function a(){ return function b(){ return eval('q * 2'); }; } return a()() === 6; })()"),
        ("function defined in a with body",
         "(function(){ var o = { q: 3 }; var f; with (o) { f = function(){ return q; }; } return f() === 3; })()"),
        ("with inside a lazy function",
         "(function(){ function f(o){ with (o) { return q; } } return f({ q: 9 }) === 9; })()"),
        ("functions made by direct-eval code",
         "(function(){ var base = 10; var g = eval('(function(x){ return function(){ return x + base; }; })'); return g(1)() === 11; })()"),
        ("indirect eval code defines lazy functions",
         "(function(){ var g = (0, eval)('(function(){ function h(n){ return n + 1; } return h; })()'); return g(1) === 2; })()"),

        // ---- Function object properties before the first call ----
        ("toString of never-called functions",
         "(function(){ function f(a, b) { return a + b; } var ar = (x) => x * 2; var o = { m(p) { return p; }, get g() { return 1; } }; class C { static s(z) { return z; } } return f.toString() === 'function f(a, b) { return a + b; }' && ar.toString() === '(x) => x * 2' && o.m.toString() === 'm(p) { return p; }' && Object.getOwnPropertyDescriptor(o, 'g').get.toString() === 'get g() { return 1; }' && C.s.toString() === 's(z) { return z; }'; })()"),
        ("toString unchanged by the first call",
         "(function(){ var f = async function*  named ( a ) { yield a; }; var before = f.toString(); f(1).next(); return before === f.toString() && before === 'async function*  named ( a ) { yield a; }'; })()"),
        ("length and name before the first call",
         "(function(){ function foo(a, b = 1, c){} var ar = (x, y) => 0; function g(a, b, c){} return foo.length === 1 && foo.name === 'foo' && ar.length === 2 && ar.name === 'ar' && g.bind(null, 1).length === 2 && g.bind(null).name === 'bound g'; })()"),
        ("named function expression: self binding and a shadowing parameter",
         "(function(){ var f = function fact(n){ return n <= 1 ? 1 : n * fact(n - 1); }; return f(5) === 120 && (function g(g){ return typeof g; })(1) === 'number'; })()"),
        ("prototype of a never-called constructor",
         "(function(){ function K(){ this.a = 1; } K.prototype.m = function(){ return this.a + 1; }; return new K().m() === 2 && K.prototype.constructor === K; })()"),

        // ---- Generators, async, parameters, tail calls ----
        ("lazy generator and generator method",
         "(function(){ function* g(n){ for (let i = 0; i < n; i++) yield i; } var o = { *m(){ yield* g(2); yield 9; } }; return [...g(3)].join() === '0,1,2' && [...o.m()].join() === '0,1,9'; })()"),
        ("generator whose default parameter throws at call time",
         "(function(){ function* g(a = (() => { throw 1; })()){ yield a; } try { g(); return false; } catch (e) { return e === 1; } })()"),
        ("async function and async arrow return promises",
         "(function(){ async function f(){ return 1; } var g = async (x) => x + 1; var o = { async m(){ return 2; } }; return f() instanceof Promise && g(1) instanceof Promise && o.m() instanceof Promise; })()"),
        ("async function awaiting inside a lazily compiled body",
         "(function(){ var out = 0; async function f(a){ var b = await a; out = b + 1; } f(1); return out === 2 || out === 0; })()"),
        ("destructuring and rest parameters",
         "(function(){ function f({ a, b: [c] }, ...r){ return a + c + r.length; } var g = ([x, y] = [1, 2]) => x + y; return f({ a: 1, b: [2] }, 3, 4) === 5 && g() === 3; })()"),
        ("tail calls in lazy strict functions",
         "(function(){ 'use strict'; function a(n){ return n === 0 ? 'done' : a(n - 1); } return a(1000) === 'done'; })()"),
        ("strict mode inherited by a lazy function",
         "(function(){ 'use strict'; function f(){ return this; } return f() === undefined; })()"),
        ("use strict directive inside a lazy body",
         "(function(){ function f(){ 'use strict'; return this; } function g(){ return this; } return f() === undefined && g() === globalThis; })()"),
        ("concise arrow bodies with in, comma and conditional",
         "(function(){ var o = { a: 1 }; var f = k => k in o; var g = (a, b) => (a, b); var h = x => x ? 'y' : 'n'; return f('a') && !f('b') && g(1, 2) === 2 && h(0) === 'n'; })()"),
        ("arrow parameters on their own line",
         "(function(){ var fs = [1, 2].map(\n  v => v * 2\n); return fs.join() === '2,4'; })()"),
        ("immediately invoked functions and arrows",
         "(function(){ var a = (function(){ return 1; })(); var b = !function(){ return 2; }(); var c = (() => 3)(); return a === 1 && b === false && c === 3; })()"),
        ("stack trace of a lazily compiled function names its line",
         "(function(){ function f(){\n return new Error('x').stack;\n} var s = f(); return /:2:\\d+/.test(s); })()"),
        ("labels, switch and try/finally in a lazy body",
         "(function(){ function f(n){ var s = 0; outer: for (var i = 0; i < n; i++) { switch (i % 3) { case 0: continue outer; case 1: s += 1; break; default: try { if (i > 5) break outer; } finally { s += 10; } } } return s; } return f(10) === 33; })()"),
    ]

    /// Idle reclaim (compile.lazyDropAfterMs): a lazily compiled body that
    /// did not run between two passes is dropped and compiles again on its
    /// next call; one that ran is kept.
    mutating func testLazyReclaim() {
        let group = "LazyCompile"
        JeffJSStackDiag.currentLabel = "\(group): reclaim"
        let (rt, ctx) = makeCtx()
        func run(_ js: String) -> String {
            let r = ctx.eval(input: js, filename: "<eval><\(group)-reclaim>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            if r.isException {
                let e = ctx.getException()
                defer { e.freeValue() }
                return "!" + (ctx.toSwiftString(e) ?? "?")
            }
            defer { r.freeValue() }
            return ctx.toSwiftString(r) ?? "?"
        }
        let first = run("""
            var __lcR = { f: function(a){ return a * 2 + 1; },
                          g: function(s){ var t = 0; for (var i = 0; i < s; i++) t += i; return t; },
                          h: (x) => x + 'h' };
            __lcR.f(1) + __lcR.g(4) + __lcR.h(1)
            """)
        assert(first == "91h", "\(group): reclaim setup -> \(first)")
        rt.reclaimIdleLazyBodies()                       // marks f, g, h
        let d0 = rt.lazyStats.dropped
        rt.reclaimIdleLazyBodies()                       // none ran: dropped
        assert(rt.lazyStats.dropped - d0 >= 3, "\(group): reclaim dropped \(rt.lazyStats.dropped - d0)")
        let c0 = rt.lazyStats.compiled
        let second = run("__lcR.f(2) + __lcR.g(5) + __lcR.h(2) + (__lcR.f.toString() === 'function(a){ return a * 2 + 1; }')")
        assert(second == "152htrue", "\(group): after reclaim -> \(second)")
        assert(rt.lazyStats.compiled - c0 == 3, "\(group): recompiled \(rt.lazyStats.compiled - c0)")
        rt.reclaimIdleLazyBodies()                       // marks again
        let kept = run("__lcR.f(3)")                     // f runs between the passes
        let d1 = rt.lazyStats.dropped
        rt.reclaimIdleLazyBodies()
        assert(kept == "7" && rt.lazyStats.dropped - d1 == 2,
               "\(group): the function that ran is kept (\(kept), dropped \(rt.lazyStats.dropped - d1))")
        let c1 = rt.lazyStats.compiled
        let third = run("__lcR.f(4) + __lcR.g(3)")
        assert(third == "12" && rt.lazyStats.compiled - c1 == 1, "\(group): f kept, g recompiled -> \(third)")
    }

    mutating func testLazyCompile() {
        let group = "LazyCompile"
        var lazyStubs = 0
        var lazyCompiled = 0
        for lazy in [true, false] {
            for (name, js) in JeffJSTestRunner.lazyCompileCases {
                let label = "\(name) [\(lazy ? "lazy" : "eager")]"
                JeffJSStackDiag.currentLabel = "\(group): \(label)"
                let (_, ctx) = makeCtx()
                ctx.rt.lazyFunctions = lazy
                let before = ctx.rt.lazyStats
                let result = ctx.eval(input: js, filename: "<eval><\(group)>", evalFlags: JS_EVAL_TYPE_GLOBAL)
                if result.isException {
                    let exc = ctx.getException()
                    assert(false, "\(group): \(label) threw \(ctx.toSwiftString(exc) ?? "?")")
                    exc.freeValue()
                } else {
                    let ok = result.isBool && result.toBool()
                    assert(ok, "\(group): \(label) -> \(ctx.toSwiftString(result) ?? "?")")
                }
                result.freeValue()
                if lazy {
                    lazyStubs += ctx.rt.lazyStats.stubs - before.stubs
                    lazyCompiled += ctx.rt.lazyStats.compiled - before.compiled
                } else {
                    assert(ctx.rt.lazyStats.stubs == before.stubs,
                           "\(group): \(label) made stubs with lazy compilation off")
                }
            }
        }
        makeCtx().0.lazyFunctions = JeffJSConfig.lazyFunctions
        testLazyReclaim()
        // The cases exercise laziness only if the lazy runs made stubs and
        // compiled them on a call.
        assert(lazyStubs >= 40 && lazyCompiled >= 40, "\(group): only \(lazyCompiled) lazy compiles (stubs \(lazyStubs))")
    }
}
