// AggregateErrorConformance.swift
// JeffJS — conformance group "AggregateError" (ES §20.5.7 AggregateError,
// §20.5.8.1 InstallErrorCause, §27.2.4.1-5 Promise combinators).
//
// `Promise.any` rejected with a plain object shaped like an error (not an
// AggregateError, `instanceof Error` false); `new AggregateError(errors, msg,
// opts)` took `errors` as the message (the live constructors were the phase-1
// placeholders: one `message` argument, no `cause`, enumerable `message`,
// [[Prototype]] Function.prototype instead of %Error%); `Promise.all` stopped
// silently after 10 000 elements and never settled. Engine-thrown errors had
// enumerable own `name`/`message` (JSON.stringify(e) was not `{}` as in JSC).
//
// Every case is (name, JS that sets globalThis.__ae — possibly from a
// reaction job — to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let aggregateErrorCases: [(String, String)] = [
        ("Promise.any rejects with an AggregateError holding the reasons in order",
         #"Promise.any([Promise.reject(1), Promise.reject(2)]).catch(function(e){ globalThis.__ae = e instanceof AggregateError && e instanceof Error && e.constructor === AggregateError && e.errors.join() === '1,2' && Object.prototype.hasOwnProperty.call(e, 'errors') && !Object.getOwnPropertyDescriptor(e, 'errors').enumerable && e.name === 'AggregateError'; });"#),
        ("Promise.any([]) rejects with an empty AggregateError, no own message (JSC)",
         #"Promise.any([]).catch(function(e){ globalThis.__ae = e instanceof AggregateError && e.errors.length === 0 && e.message === '' && !Object.prototype.hasOwnProperty.call(e, 'message') && String(e) === 'AggregateError'; });"#),
        ("Promise.any resolves with the first fulfilment",
         #"Promise.any([Promise.reject(1), Promise.resolve('ok')]).then(function(v){ globalThis.__ae = v === 'ok'; });"#),
        ("new AggregateError(errors, message, { cause })",
         #"var e = new AggregateError(new Set([1, 2]), 'm', { cause: 3 }); globalThis.__ae = e.message === 'm' && e.errors.join() === '1,2' && Array.isArray(e.errors) && e.cause === 3 && String(e) === 'AggregateError: m' && Object.keys(e).length === 0;"#),
        ("AggregateError: length 2, [[Prototype]] %Error%, prototype chain",
         #"globalThis.__ae = AggregateError.length === 2 && AggregateError.name === 'AggregateError' && Object.getPrototypeOf(AggregateError) === Error && Object.getPrototypeOf(TypeError) === Error && Object.getPrototypeOf(AggregateError.prototype) === Error.prototype && AggregateError.prototype.name === 'AggregateError' && AggregateError.prototype.message === '' && !('errors' in AggregateError.prototype);"#),
        ("AggregateError: errors is IterableToList (a non-iterable throws a TypeError)",
         #"var ok = false; try { new AggregateError(5); } catch (x) { ok = x instanceof TypeError; } globalThis.__ae = ok && new AggregateError((function*(){ yield 'a'; yield 'b'; })()).errors.join() === 'a,b' && AggregateError([1]) instanceof AggregateError;"#),
        ("a subclass of AggregateError",
         #"class A2 extends AggregateError {} var a = new A2([1], 'q'); globalThis.__ae = a instanceof A2 && a instanceof AggregateError && a.message === 'q' && a.errors[0] === 1;"#),
        ("Error / NativeError: options.cause (own or inherited, even undefined); message non-enumerable",
         #"var a = new Error('x', { cause: 0 }), b = new TypeError('t', Object.create({ cause: 'inh' })), c = new Error('u', { cause: undefined }), d = new RangeError('r', {}); globalThis.__ae = a.cause === 0 && b.cause === 'inh' && Object.prototype.hasOwnProperty.call(c, 'cause') && !('cause' in d) && Object.keys(a).length === 0 && !Object.getOwnPropertyDescriptor(a, 'message').enumerable && Object.getOwnPropertyDescriptor(a, 'cause').enumerable === false;"#),
        ("a message whose ToString throws propagates",
         #"var ok = false; try { new Error({ toString: function(){ throw new SyntaxError('ts'); } }); } catch (x) { ok = x instanceof SyntaxError; } globalThis.__ae = ok;"#),
        ("super(message, { cause }) from a class extending Error",
         #"class M extends Error { constructor(m){ super(m, { cause: 'c' }); } } var m = new M('hi'); globalThis.__ae = m instanceof M && m.message === 'hi' && m.cause === 'c';"#),
        ("an engine-thrown error: inherited name, non-enumerable message, intrinsic prototype",
         #"var T = TypeError, e; globalThis.TypeError = function(){}; try { null.x; } catch (x) { e = x; } globalThis.TypeError = T; globalThis.__ae = e instanceof T && Object.getPrototypeOf(e) === T.prototype && !Object.prototype.hasOwnProperty.call(e, 'name') && e.name === 'TypeError' && JSON.stringify(e) === '{}' && Object.keys(e).length === 0;"#),
        ("Promise.all of 20 000 elements settles (no element cap)",
         #"var a = []; for (var i = 0; i < 20000; i++) a.push(i); Promise.all(a).then(function(v){ globalThis.__ae = v.length === 20000 && v[19999] === 19999; });"#),
        ("Promise.allSettled / race / any past 10 000 elements",
         #"var a = []; for (var i = 0; i < 12000; i++) a.push(Promise.reject(i)); var n = 0; Promise.allSettled(a).then(function(v){ if (v.length === 12000) n++; }); Promise.any(a).catch(function(e){ if (e.errors.length === 12000 && e.errors[11999] === 11999) n++; }); var b = []; for (var j = 0; j < 12000; j++) b.push(new Promise(function(){})); b.push(Promise.resolve('last')); Promise.race(b).then(function(v){ if (v === 'last') n++; }); Promise.resolve().then(function(){}).then(function(){}).then(function(){}).then(function(){ globalThis.__ae = n === 3; });"#),
    ]

    mutating func testAggregateError() {
        let (_, ctx) = makeCtx()
        for (name, setup) in JeffJSTestRunner.aggregateErrorCases {
            JeffJSStackDiag.currentLabel = "AggregateError: \(name)"
            let global = ctx.getGlobalObject()
            ctx.setPropertyStr(obj: global, name: "__ae", value: .undefined)
            let r = ctx.eval(input: setup, filename: "<AggregateError>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            if r.isException {
                let exc = ctx.getException()
                assert(false, "AggregateError: \(name) threw \(ctx.toSwiftString(exc) ?? "?")")
                exc.freeValue()
                global.freeValue()
                continue
            }
            r.freeValue()
            _ = ctx.rt.executePendingJobs()
            let v = ctx.getPropertyStr(obj: global, name: "__ae")
            assert(v.isBool && v.toBool(), "AggregateError: \(name) -> \(ctx.toSwiftString(v) ?? "undefined")")
            v.freeValue()
            global.freeValue()
        }
    }
}
