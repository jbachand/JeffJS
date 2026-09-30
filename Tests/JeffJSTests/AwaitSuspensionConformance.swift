// AwaitSuspensionConformance.swift
// JeffJS — conformance group "AwaitSuspension" (ES §27.7.5.3 Await: the value goes
// through PromiseResolve and the async activation *always* suspends; it resumes from
// a promise reaction job). JeffJS resumed at once when the awaited value was not a
// promise or was already settled, and drained the whole job queue synchronously on a
// pending one, so `p.then(f); await 0; g()` ran g before f — Lit's update cycle and
// reddit's `await scheduler?.yield?.()` saw the wrong order. Orders below are node's
// and JSC's.
//
// Every case is (name, JS expression) evaluated after the job queue drains:
// cases record into globalThis and the check expression reads it.

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let awaitSuspensionCases: [(String, String, String)] = [
        ("await of a non-promise yields to jobs queued before it",
         #"globalThis.__a1 = []; Promise.resolve().then(function(){ __a1.push('p1'); }); (async function(){ __a1.push('a0'); await 0; __a1.push('a1'); await 0; __a1.push('a2'); })(); Promise.resolve().then(function(){ __a1.push('p2'); });"#,
         #"__a1.join() === 'a0,p1,a1,p2,a2'"#),
        ("await of a settled promise, of null, of a thenable",
         #"globalThis.__a2 = []; Promise.resolve().then(function(){ __a2.push('p1'); }); (async function(){ __a2.push('a0'); await Promise.resolve(); __a2.push('a1'); await { then: function(r){ r(1); } }; __a2.push('a2'); await null; __a2.push('a3'); })(); Promise.resolve().then(function(){ __a2.push('p2'); });"#,
         #"__a2.join() === 'a0,p1,a1,p2,a2,a3'"#),
        ("an async function's code before its first await runs synchronously; its result settles later",
         #"globalThis.__a3 = []; var pr = (async function(){ __a3.push('in'); await 1; return 7; })(); __a3.push('after'); pr.then(function(v){ __a3.push('v' + v); });"#,
         #"__a3.join() === 'in,after,v7'"#),
        ("rejections and throwing thenables resume into catch in job order",
         #"globalThis.__a4 = []; (async function(){ try { await Promise.reject(1); } catch (e) { __a4.push('c' + e); } try { await { then: function(a, b){ b(2); } }; } catch (e) { __a4.push('t' + e); } })(); Promise.resolve().then(function(){ __a4.push('p1'); }).then(function(){ __a4.push('p2'); }).then(function(){ __a4.push('p3'); });"#,
         #"__a4.join() === 'c1,p1,p2,t2,p3'"#),
        ("async generators and for await interleave with promise jobs like node",
         #"globalThis.__a5 = []; async function* g(){ __a5.push('g0'); await 0; __a5.push('g1'); yield 1; await null; __a5.push('g2'); yield await Promise.resolve(2); } (async function(){ for await (var x of g()) __a5.push('x' + x); __a5.push('done'); })(); Promise.resolve().then(function(){ __a5.push('p1'); }).then(function(){ __a5.push('p2'); }).then(function(){ __a5.push('p3'); });"#,
         #"__a5.join() === 'g0,g1,p1,p2,x1,p3,g2,x2,done'"#),
        ("nested async calls: the inner await suspends the inner activation only",
         #"globalThis.__a6 = []; (async function(){ var r = await (async function(){ await 0; __a6.push('inner'); return 5; })(); __a6.push('outer' + r); })(); __a6.push('sync');"#,
         #"__a6.join() === 'sync,inner,outer5'"#),
    ]

    mutating func testAwaitSuspension() {
        let (rt, ctx) = makeCtx()
        for (name, setup, check) in JeffJSTestRunner.awaitSuspensionCases {
            JeffJSStackDiag.currentLabel = "AwaitSuspension: \(name)"
            let r0 = ctx.eval(input: setup, filename: "<AwaitSuspension>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            if r0.isException { let e = ctx.getException(); assert(false, "AwaitSuspension: \(name) setup threw \(ctx.toSwiftString(e) ?? "?")"); e.freeValue() }
            r0.freeValue()
            _ = rt.executePendingJobs()
            let r = ctx.eval(input: check, filename: "<AwaitSuspension>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            if r.isException {
                let e = ctx.getException(); assert(false, "AwaitSuspension: \(name) threw \(ctx.toSwiftString(e) ?? "?")"); e.freeValue()
            } else {
                assert(r.isBool && r.toBool(), "AwaitSuspension: \(name) -> false")
            }
            r.freeValue()
        }
    }
}
