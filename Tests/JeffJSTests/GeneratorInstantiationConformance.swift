// GeneratorInstantiationConformance.swift
// JeffJS — "GeneratorInstantiation": a generator call runs
// FunctionDeclarationInstantiation before the generator object is returned
// (ES §27.5.3.1 EvaluateGeneratorBody, §27.6.3.2 EvaluateAsyncGeneratorBody).
//
// JeffJS had no `initial_yield`: calling a generator only built the object,
// and the parameter prologue ran on the first `next()`. So `let n = 0;
// function* g(a = ++n) {} g(); n` was 0, a throwing default threw from
// `next()` instead of the call, and `function* g({a}) {} g()` did not throw
// at all. The parser now emits `initial_yield` after the prologue (parameter
// defaults and patterns, `arguments`, the step-28 var copies and hoisted
// function declarations) and the call runs up to it, as QuickJS does.
//
// Every case is (name, JS expression that must evaluate to `true`). Async
// cases store their verdict in `globalThis.__gi` after the job queue drains.

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let generatorInstantiationCases: [(String, String)] = [
        ("defaults run at the call",
         "(function(){ var n = 0; function* g(a = ++n){ yield a; } var it = g(); var atCall = n; return atCall === 1 && it.next().value === 1 && n === 1; })()"),
        ("defaults of generator methods run at the call",
         "(function(){ var n = 0; var o = { *m(a = ++n){} }; class C { *m(a = ++n){} static *s(a = ++n){} } o.m(); new C().m(); C.s(); return n === 3; })()"),
        ("a throwing default throws from the call",
         "(function(){ function* g(a = (function(){ throw new RangeError('d'); })()){ yield 1; } try { g(); return false; } catch (e) { return e instanceof RangeError; } })()"),
        ("a destructuring parameter throws TypeError at the call",
         "(function(){ function* g({a}){} function* h([b]){} var n = 0; try { g(); } catch (e) { n += e instanceof TypeError; } try { h(null); } catch (e) { n += e instanceof TypeError; } return n === 2; })()"),
        ("the body starts at the first next",
         "(function(){ var log = []; function* g(a = log.push('p')){ log.push('b'); yield 1; } var it = g(); log.push('c'); it.next(); return log.join() === 'p,c,b'; })()"),
        ("the value passed to the first next is ignored",
         "(function(){ function* g(){ var x = yield 1; yield x; } var it = g(); it.next('lost'); return it.next(5).value === 5; })()"),
        ("arguments binds at the call",
         "(function(){ function* g(a){ yield arguments.length; yield arguments[2]; } function* m(a){ a = 5; yield arguments[0]; } function* u(a, b, c){ yield arguments.length; } return [...g(1, 2, 3)].join() === '3,3' && m(1).next().value === 5 && u(1).next().value === 1; })()"),
        ("rest parameters and unpassed parameters",
         "(function(){ function* h(a, ...r){ yield r.join(); } function* k(a, b){ b = 7; yield 0; yield b; } return h(1, 2, 3).next().value === '2,3' && [...k()].join() === '0,7'; })()"),
        ("this binds at the call",
         "(function(){ var o = { *m(){ yield this; } }; function* s(){ 'use strict'; yield this; } function* l(){ yield this; } return o.m().next().value === o && s().next().value === undefined && l().next().value === globalThis; })()"),
        ("hoisted function declarations and parameter closures",
         "(function(){ function* g(){ yield f(); function f(){ return 3; } } function* c(a, b = () => a){ var a = 9; yield b(); yield a; } var fe = function* named(){ yield typeof named; }; return g().next().value === 3 && [...c(3)].join() === '3,9' && fe().next().value === 'function'; })()"),
        ("return before start completes without running the body",
         "(function(){ var log = []; function* g(a = log.push('p')){ log.push('b'); try { yield 1; } finally { log.push('f'); } } var it = g(); var r = it.return(9); var after = it.next(); return r.value === 9 && r.done === true && after.done === true && after.value === undefined && log.join() === 'p'; })()"),
        ("throw before start throws without running the body",
         "(function(){ var log = []; function* g(){ log.push('b'); try { yield 1; } catch (e) { return 'caught'; } } var it = g(); try { it.throw(new Error('E')); return false; } catch (e) { return e.message === 'E' && it.next().done === true && log.length === 0; } })()"),
        ("yield in formal parameters is a SyntaxError",
         "(function(){ var srcs = ['function* g(a = yield){}', 'function* g(a = yield 1){}', 'function* g({a = yield}){}', '({ *m(a = yield){} })', '(class { *m(a = yield){} })']; return srcs.every(function(s){ try { (0, eval)(s); return false; } catch (e) { return e instanceof SyntaxError; } }); })()"),
        ("await in async formal parameters is a SyntaxError",
         "(function(){ var srcs = ['async function* g(a = await 1){}', 'async function f(a = await 1){}']; return srcs.every(function(s){ try { (0, eval)(s); return false; } catch (e) { return e instanceof SyntaxError; } }); })()"),
        ("async generator parameters run at the call",
         "(function(){ var n = 0; async function* ag(a = ++n){ yield a; } ag(); var r = n === 1; async function* bad(a = (function(){ throw new TypeError('x'); })()){} try { bad(); r = false; } catch (e) { r = r && e instanceof TypeError; } async function* d({x}){} try { d(); r = false; } catch (e) { r = r && e instanceof TypeError; } return r; })()"),
    ]

    /// Cases whose verdict is only known after the job queue drains: the
    /// expression sets `globalThis.__gi` to true or to a diagnostic.
    static let generatorInstantiationAsyncCases: [(String, String)] = [
        ("async generator body starts at the first next",
         "globalThis.__gi = 'pending'; (async function(){ var log = []; async function* ag(a = log.push('p')){ log.push('b'); yield a; } var it = ag(); log.push('c'); var v = await it.next(); globalThis.__gi = v.value === 1 && v.done === false && log.join() === 'p,c,b' || log.join(); })();"),
        ("async generator return/throw before start",
         "globalThis.__gi = 'pending'; (async function(){ var log = []; async function* ag(){ log.push('b'); yield 1; } var r = await ag().return(7); var t; try { await ag().throw(new Error('E')); t = 'resolved'; } catch (e) { t = e.message; } globalThis.__gi = r.value === 7 && r.done === true && t === 'E' && log.length === 0 || [JSON.stringify(r), t, log.join()].join('|'); })();"),
        ("async generator arguments bind at the call",
         "globalThis.__gi = 'pending'; (async function(){ async function* ar(a){ yield arguments.length; yield a; } var out = []; for await (var v of ar(4, 5)) out.push(v); globalThis.__gi = out.join() === '2,4' || out.join(); })();"),
        ("async functions still run their parameters at the call",
         "globalThis.__gi = 'pending'; (async function(){ var m = 0; async function af(a = ++m){ await null; return a; } var p = af(); var at = m; async function bad(a = (function(){ throw new TypeError('q'); })()){} var rej; try { await bad(); rej = 'resolved'; } catch (e) { rej = e instanceof TypeError; } var v = await p; globalThis.__gi = at === 1 && rej === true && v === 1 || [at, rej, v].join('|'); })();"),
    ]

    mutating func testGeneratorInstantiation() {
        runTrueCases("GeneratorInstantiation", JeffJSTestRunner.generatorInstantiationCases)
        let (_, ctx) = makeCtx()
        for (name, js) in JeffJSTestRunner.generatorInstantiationAsyncCases {
            JeffJSStackDiag.currentLabel = "GeneratorInstantiation: \(name)"
            let started = ctx.eval(input: js, filename: "<GeneratorInstantiation>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            if started.isException {
                let exc = ctx.getException()
                assert(false, "GeneratorInstantiation: \(name) threw \(ctx.toSwiftString(exc) ?? "?")")
                exc.freeValue()
                continue
            }
            started.freeValue()
            _ = ctx.rt.executePendingJobs()
            let verdict = ctx.eval(input: "globalThis.__gi", filename: "<GeneratorInstantiation>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            let ok = verdict.isBool && verdict.toBool()
            assert(ok, "GeneratorInstantiation: \(name) -> \(ctx.toSwiftString(verdict) ?? "?")")
            verdict.freeValue()
        }
    }
}
