// PromiseIterableConformance.swift
// JeffJS — conformance group "PromiseIterables" (ES §27.2.4.1-5
// Promise.all / allSettled / race / any take any iterable: GetIterator(iterable,
// sync) looks up @@iterator). The helper read the *string* key "@@iterator",
// which never exists, and only real Arrays got through an array-only fallback:
// `Promise.all(new Set(...))` rejected with "object is not iterable". google.com's
// module loader awaits `Promise.all(new Set([...]))` between the script chunks of
// one module request; the chain stopped after the first chunk.
//
// Every case is (name, setup JS that settles into globalThis.__pi, expected string).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let promiseIterableCases: [(String, String, String)] = [
        ("Promise.all(Set)",
         "Promise.all(new Set([Promise.resolve(1), 2])).then(function(v){ globalThis.__pi = v.join(); }, function(e){ globalThis.__pi = 'REJ ' + e; });",
         "1,2"),
        ("Promise.all(empty Set) resolves []",
         "Promise.all(new Set()).then(function(v){ globalThis.__pi = 'ok' + v.length; }, function(e){ globalThis.__pi = 'REJ ' + e; });",
         "ok0"),
        ("Promise.all(Map) yields entries",
         "Promise.all(new Map([['k', 2]])).then(function(v){ globalThis.__pi = JSON.stringify(v); }, function(e){ globalThis.__pi = 'REJ ' + e; });",
         "[[\"k\",2]]"),
        ("Promise.all(generator)",
         "Promise.all((function*(){ yield 1; yield Promise.resolve(2); })()).then(function(v){ globalThis.__pi = v.join(); }, function(e){ globalThis.__pi = 'REJ ' + e; });",
         "1,2"),
        ("Promise.all(array iterator)",
         "Promise.all([3, 4].values()).then(function(v){ globalThis.__pi = v.join(); }, function(e){ globalThis.__pi = 'REJ ' + e; });",
         "3,4"),
        ("Promise.all(user iterable)",
         "Promise.all({ [Symbol.iterator](){ var i = 0; return { next(){ return i < 2 ? { value: i++, done: false } : { value: undefined, done: true }; } }; } }).then(function(v){ globalThis.__pi = v.join(); }, function(e){ globalThis.__pi = 'REJ ' + e; });",
         "0,1"),
        ("an Array still uses its (patchable) @@iterator",
         "var a = [1, 2]; a[Symbol.iterator] = function*(){ yield 'patched'; }; Promise.all(a).then(function(v){ globalThis.__pi = v.join(); }, function(e){ globalThis.__pi = 'REJ ' + e; });",
         "patched"),
        ("Promise.allSettled(Set)",
         "Promise.allSettled(new Set([Promise.reject('r'), 1])).then(function(v){ globalThis.__pi = v.map(function(x){ return x.status; }).join(); }, function(e){ globalThis.__pi = 'REJ ' + e; });",
         "rejected,fulfilled"),
        ("Promise.race(Set)",
         "Promise.race(new Set([Promise.resolve('first')])).then(function(v){ globalThis.__pi = v; }, function(e){ globalThis.__pi = 'REJ ' + e; });",
         "first"),
        ("Promise.any(Set)",
         "Promise.any(new Set([Promise.reject(1), Promise.resolve('any')])).then(function(v){ globalThis.__pi = v; }, function(e){ globalThis.__pi = 'REJ ' + e; });",
         "any"),
        ("a non-iterable rejects with a TypeError",
         "Promise.all({}).then(function(){ globalThis.__pi = 'resolved'; }, function(e){ globalThis.__pi = e instanceof TypeError ? 'TypeError' : 'other ' + e; });",
         "TypeError"),
        ("a throwing iterator rejects with its error",
         "Promise.all((function*(){ yield 1; throw new Error('boom'); })()).then(function(){ globalThis.__pi = 'resolved'; }, function(e){ globalThis.__pi = e.message; });",
         "boom"),
        ("a throwing @@iterator getter rejects with its error",
         "Promise.all({ get [Symbol.iterator](){ throw new Error('getter'); } }).then(function(){ globalThis.__pi = 'resolved'; }, function(e){ globalThis.__pi = e.message; });",
         "getter"),
        ("the google.com loader shape: await Promise.all(new Set([...])) in an async executor",
         "var p1 = Promise.resolve(1); var h = new Set(); h.add(p1); h.add(Promise.resolve(2)); new Promise(async function(res){ try { await Promise.all(h); res('chunk2'); } catch (e) { res('REJ ' + e); } }).then(function(v){ globalThis.__pi = v; });",
         "chunk2"),
        // Promise.prototype.constructor === Promise (ES §27.2.5.1); it was
        // missing, so PromiseResolve's `x.constructor === C` failed.
        ("Promise.prototype.constructor and Promise.resolve(p) === p",
         "var pp = Promise.resolve(5); var d = Object.getOwnPropertyDescriptor(Promise.prototype, 'constructor'); globalThis.__pi = String(Promise.prototype.constructor === Promise && pp.constructor === Promise && Promise.resolve(pp) === pp && d.writable && d.configurable && !d.enumerable);",
         "true"),
        // WeakMap / WeakSet constructors take an iterable (ES §24.3.1.1,
        // §24.4.1.1); the placeholder constructors ignored it.
        ("new WeakMap(iterable) / new WeakSet(iterable)",
         "var k = {}, j = {}, it = false, n = {}; n[Symbol.iterator] = function () { return { next: function () { return { done: it = true }; } }; }; new WeakMap(n); var e1 = 'none', e2 = 'none'; try { new WeakMap([[1, 2]]); } catch (e) { e1 = e.constructor.name; } try { new WeakSet([1]); } catch (e) { e2 = e.constructor.name; } globalThis.__pi = [new WeakMap([[k, 7], [j, 8]]).get(j), new WeakSet([k]).has(k), it, e1, e2, WeakMap.prototype.constructor === WeakMap].join();",
         "8,true,true,TypeError,TypeError,true"),
    ]

    mutating func testPromiseIterables() {
        let (_, ctx) = makeCtx()
        for (name, setup, expect) in JeffJSTestRunner.promiseIterableCases {
            JeffJSStackDiag.currentLabel = "PromiseIterables: \(name)"
            let global = ctx.getGlobalObject()
            ctx.setPropertyStr(obj: global, name: "__pi", value: .undefined)
            let r = ctx.eval(input: setup, filename: "<PromiseIterables>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            if r.isException {
                let exc = ctx.getException()
                assert(false, "PromiseIterables: \(name) threw \(ctx.toSwiftString(exc) ?? "?")")
                exc.freeValue()
                global.freeValue()
                continue
            }
            r.freeValue()
            _ = ctx.rt.executePendingJobs()
            let v = ctx.getPropertyStr(obj: global, name: "__pi")
            let got = ctx.toSwiftString(v) ?? "undefined"
            assert(got == expect, "PromiseIterables: \(name) -> \(got), expected \(expect)")
            v.freeValue()
            global.freeValue()
        }
    }
}
