// ArrayReduceRightConformance.swift
// JeffJS — conformance group "ArrayReduceRight" (2026-10-18). `Array.prototype.reduceRight`
// (QuickJS `js_array_reduce`, special_reduceRight) returned the caller's initial value without a
// reference of its own when no callback ran (`[].reduceRight(f, [])`, or only holes): the caller
// then released it twice and the array was freed while still in use — instagram.com's
// CometAppViewStack (`children: stack.reduceRight(…, [])` on an empty push-view stack) crashed
// the app. It also leaked every element it read and every accumulator a callback replaced.
// Expected values are JavaScriptCore's (`jsc`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    mutating func testArrayReduceRight() {
        let (_, ctx) = makeCtx()
        func ev(_ js: String) -> JeffJSValue { ctx.eval(input: js, filename: "<ArrayReduceRight>", evalFlags: JS_EVAL_TYPE_GLOBAL) }
        func str(_ js: String) -> String {
            let v = ev(js); defer { v.freeValue() }
            return ctx.toSwiftString(v) ?? "?"
        }

        // The initial value comes back with its own reference (no callback ran).
        let initial = ev("var __rrInit = []; __rrInit")
        let rc0 = initial.toObject()?.refCount ?? 0
        let r = ev("[].reduceRight(function (t) { return t; }, __rrInit)")
        assert((initial.toObject()?.refCount ?? 0) == rc0 + 1,
               "ArrayReduceRight: an empty array returns the initial value with a new reference (\(rc0) -> \(initial.toObject()?.refCount ?? 0))")
        r.freeValue()
        assert((initial.toObject()?.refCount ?? 0) == rc0, "ArrayReduceRight: releasing the result leaves the initial value alive")
        let holes = ev("[, , ].reduceRight(function (t) { return t; }, __rrInit)")
        assert((initial.toObject()?.refCount ?? 0) == rc0 + 1, "ArrayReduceRight: only holes: the initial value with a new reference")
        holes.freeValue()
        initial.freeValue()

        // The same accumulator returned through every call: no count gained or lost.
        let acc = ev("var __rrAcc = []; __rrAcc")
        let accRc = acc.toObject()?.refCount ?? 0
        ev("var __rrOut = [1, 2, 3].reduceRight(function (t, v) { t.unshift(v); return t; }, __rrAcc); 0").freeValue()
        assert((acc.toObject()?.refCount ?? 0) == accRc + 1,
               "ArrayReduceRight: an accumulator returned by every callback is held once more, by __rrOut (\(accRc) -> \(acc.toObject()?.refCount ?? 0))")
        acc.freeValue()

        // Elements read are released (an element object keeps only the array's reference).
        let el = ev("var __rrEl = {}; var __rrArr = [__rrEl, __rrEl]; __rrEl")
        let elRc = el.toObject()?.refCount ?? 0
        ev("__rrArr.reduceRight(function (t, v) { return 0; }, 0)").freeValue()
        ev("__rrArr.reduceRight(function (t, v) { return t; })").freeValue()
        assert((el.toObject()?.refCount ?? 0) == elRc, "ArrayReduceRight: element reads are released (\(elRc) -> \(el.toObject()?.refCount ?? 0))")
        el.freeValue()

        // Behaviour (JSC).
        assert(str("[1, 2, 3].reduceRight(function (a, b) { return a + '' + b; })") == "321", "ArrayReduceRight: no initial value starts at the last element")
        assert(str("JSON.stringify([1, 2].reduceRight(function (a, v, i) { a.push(i); return a; }, []))") == "[1,0]", "ArrayReduceRight: indices run backwards")
        assert(str("try { [].reduceRight(function () {}); 'no' } catch (e) { e.constructor.name }") == "TypeError", "ArrayReduceRight: empty without initial value throws")
        assert(str("var __rrCyc = [], __rrS = { children: [].reduceRight(function (t) { return t; }, __rrCyc) }; __rrS.children === __rrCyc") == "true",
               "ArrayReduceRight: the result is the initial value itself")
    }
}
