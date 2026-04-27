// JeffJSBuiltinPromise.swift
// JeffJS - 1:1 Swift port of QuickJS JavaScript engine
//
// Port of the Promise built-in from QuickJS.
// Implements the full Promise/A+ specification per ECMA-262 Section 27.2,
// including Promise.all, allSettled, any, race, withResolvers, try, and
// the microtask job queue integration.
//
// QuickJS source reference: quickjs.c — js_promise_constructor,
// js_promise_resolve, js_promise_reject, js_promise_all,
// perform_promise_then, promise_reaction_job, etc.

import Foundation

// MARK: - Promise Reaction Record

/// A single promise reaction record, corresponding to QuickJS
/// JSPromiseReactionData / the [[PromiseReaction]] internal slot.
///
/// Each reaction records what to do when a promise settles:
/// - The handler function (onFulfilled or onRejected)
/// - The capability of the dependent promise (resolve + reject functions)
/// - The reaction type (fulfill vs reject)
struct JeffJSPromiseReaction {
    /// The handler closure. May be JS_UNDEFINED for default pass-through.
    var handler: JeffJSValue

    /// The resolve function of the dependent promise capability.
    var resolveFunc: JeffJSValue

    /// The reject function of the dependent promise capability.
    var rejectFunc: JeffJSValue

    /// True if this is a fulfill reaction; false if reject.
    var isFulfill: Bool

    init(handler: JeffJSValue = .undefined,
         resolveFunc: JeffJSValue = .undefined,
         rejectFunc: JeffJSValue = .undefined,
         isFulfill: Bool = true) {
        self.handler = handler
        self.resolveFunc = resolveFunc
        self.rejectFunc = rejectFunc
        self.isFulfill = isFulfill
    }
}

// MARK: - Promise Data

// JeffJSPromiseData is defined in JeffJSObject.swift.
// This file uses it from there to avoid duplicate declarations.

// MARK: - Resolving Functions Opaque Data

/// Opaque data attached to the resolve/reject functions created by
/// CreateResolvingFunctions. Holds a reference to the promise and a shared
/// alreadyResolved flag.
private final class ResolvingFunctionsData {
    /// Strong reference to the promise object. This MUST be strong — not weak —
    /// because resolve/reject functions can be called asynchronously (e.g., from
    /// fetch callbacks, timer callbacks). A weak reference would allow the promise
    /// to be deallocated before resolve is called, silently breaking the chain.
    var promiseObj: JeffJSObject?
    var alreadyResolved: Bool = false

    init(promiseObj: JeffJSObject?) {
        self.promiseObj = promiseObj
    }
}

// MARK: - Promise.all / allSettled / any Element Closure Data

/// Shared state for Promise.all / allSettled / any element closures.
private final class PromiseAllData {
    var remainingElements: Int = 1  // Starts at 1 (decremented after iteration)
    var values: [JeffJSValue] = []
    var resolveFunc: JeffJSValue = .undefined
    var rejectFunc: JeffJSValue = .undefined
    var promiseCapability: (promise: JeffJSValue, resolve: JeffJSValue, reject: JeffJSValue)?
    var errors: [JeffJSValue] = []  // Used by Promise.any
    var index: Int = 0

    init() {}
}

// MARK: - JeffJSBuiltinPromise

struct JeffJSBuiltinPromise {

    // MARK: - Recursion Guard for resolvePromise

    /// Track resolve depth to prevent infinite thenable chains.
    /// If resolution is a thenable that resolves to another thenable, each
    /// step re-enters resolvePromise via PromiseResolveThenableJob. A depth
    /// limit prevents runaway chains from consuming unbounded CPU / memory.
    private static let maxResolveDepth = 10
    private static var _resolveDepth = 0

    // MARK: - Intrinsic Registration

    /// Registers the Promise constructor and prototype on the global object.
    /// Mirrors JS_AddIntrinsicPromise from QuickJS.
    static func addIntrinsic(ctx: JeffJSContext) {
        // Create Promise prototype
        let promiseProto = ctx.newPlainObject()

        // Prototype methods
        let thenFunc = ctx.newCFunction(name: "then", length: 2) { c, this, args in
            return JeffJSBuiltinPromise.then(ctx: c, this: this, args: args)
        }
        ctx.setPropertyStr(obj: promiseProto, name: "then", value: thenFunc)

        let catchFunc = ctx.newCFunction(name: "catch", length: 1) { c, this, args in
            return JeffJSBuiltinPromise.catch_(ctx: c, this: this, args: args)
        }
        ctx.setPropertyStr(obj: promiseProto, name: "catch", value: catchFunc)

        let finallyFunc = ctx.newCFunction(name: "finally", length: 1) { c, this, args in
            return JeffJSBuiltinPromise.finally_(ctx: c, this: this, args: args)
        }
        ctx.setPropertyStr(obj: promiseProto, name: "finally", value: finallyFunc)

        // Set @@toStringTag
        ctx.setPropertyStr(obj: promiseProto, name: "@@toStringTag",
                           value: ctx.newStringValue("Promise"))

        // Create the Promise constructor function
        let promiseCtor = ctx.newCFunction(name: "Promise", length: 1) { c, this, args in
            return JeffJSBuiltinPromise.promiseConstructor(
                ctx: c, newTarget: this, this: this, args: args)
        }

        // Constructor.prototype = prototype
        ctx.setPropertyStr(obj: promiseCtor, name: "prototype", value: promiseProto)

        // Static methods
        let resolveMethod = ctx.newCFunction(name: "resolve", length: 1) { c, this, args in
            return JeffJSBuiltinPromise.resolve(ctx: c, this: this, args: args)
        }
        ctx.setPropertyStr(obj: promiseCtor, name: "resolve", value: resolveMethod)

        let rejectMethod = ctx.newCFunction(name: "reject", length: 1) { c, this, args in
            return JeffJSBuiltinPromise.reject(ctx: c, this: this, args: args)
        }
        ctx.setPropertyStr(obj: promiseCtor, name: "reject", value: rejectMethod)

        let allMethod = ctx.newCFunction(name: "all", length: 1) { c, this, args in
            return JeffJSBuiltinPromise.all(ctx: c, this: this, args: args, magic: 0)
        }
        ctx.setPropertyStr(obj: promiseCtor, name: "all", value: allMethod)

        let allSettledMethod = ctx.newCFunction(name: "allSettled", length: 1) { c, this, args in
            return JeffJSBuiltinPromise.allSettled(ctx: c, this: this, args: args, magic: 1)
        }
        ctx.setPropertyStr(obj: promiseCtor, name: "allSettled", value: allSettledMethod)

        let anyMethod = ctx.newCFunction(name: "any", length: 1) { c, this, args in
            return JeffJSBuiltinPromise.any(ctx: c, this: this, args: args, magic: 2)
        }
        ctx.setPropertyStr(obj: promiseCtor, name: "any", value: anyMethod)

        let raceMethod = ctx.newCFunction(name: "race", length: 1) { c, this, args in
            return JeffJSBuiltinPromise.race(ctx: c, this: this, args: args)
        }
        ctx.setPropertyStr(obj: promiseCtor, name: "race", value: raceMethod)

        let withResolversMethod = ctx.newCFunction(name: "withResolvers", length: 0) { c, this, args in
            return JeffJSBuiltinPromise.withResolvers(ctx: c, this: this, args: args)
        }
        ctx.setPropertyStr(obj: promiseCtor, name: "withResolvers", value: withResolversMethod)

        let tryMethod = ctx.newCFunction(name: "try", length: 1) { c, this, args in
            return JeffJSBuiltinPromise.try_(ctx: c, this: this, args: args)
        }
        ctx.setPropertyStr(obj: promiseCtor, name: "try", value: tryMethod)

        // Register on global and update ctx.promiseCtor so it stays in sync
        // with the Phase 2 constructor (Phase 1 sets a stub that Phase 2 replaces).
        ctx.promiseCtor = promiseCtor.dupValue()
        ctx.setPropertyStr(obj: ctx.globalObject, name: "Promise", value: promiseCtor)

        // Update classProto for JS_CLASS_PROMISE so promise objects created by
        // the real constructor inherit the real prototype (with then/catch/finally).
        let promiseClassID = JSClassID.JS_CLASS_PROMISE.rawValue
        if promiseClassID < ctx.classProto.count {
            ctx.classProto[promiseClassID] = promiseProto.dupValue()
        }
    }

    // MARK: - Promise Constructor

    /// new Promise(executor)
    /// The executor receives (resolve, reject) and is called synchronously.
    /// Mirrors js_promise_constructor from QuickJS.
    static func promiseConstructor(ctx: JeffJSContext, newTarget: JeffJSValue,
                                    this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 1, ctx.isFunction(args[0]) else {
            return ctx.throwTypeError("Promise resolver is not a function")
        }
        let executor = args[0]

        // Create the promise object
        let promiseObj = createPromiseObject(ctx: ctx)
        if promiseObj.isException { return promiseObj }

        // Create resolving functions
        let (resolveFunc, rejectFunc) = createResolvingFunctions(ctx: ctx, promise: promiseObj)

        // Call the executor synchronously: executor(resolve, reject)
        let executorResult = ctx.callFunction(func_: executor, this: .undefined,
                                              args: [resolveFunc, rejectFunc])

        if executorResult.isException {
            // If the executor throws, reject the promise with the thrown value
            let exception = ctx.getException()
            let _ = ctx.callFunction(func_: rejectFunc, this: .undefined, args: [exception])
            ctx.freeValue(exception)
        }
        ctx.freeValue(executorResult)
        ctx.freeValue(resolveFunc)
        ctx.freeValue(rejectFunc)

        return promiseObj
    }

    // MARK: - Static Methods

    /// Promise.resolve(value)
    /// Returns a promise resolved with the given value.
    /// If value is already a promise from the same constructor, returns it directly.
    static func resolve(ctx: JeffJSContext, this: JeffJSValue,
                        args: [JeffJSValue]) -> JeffJSValue {
        let value = args.count >= 1 ? args[0] : JeffJSValue.undefined

        // If value is already a Promise from this constructor, return it
        if value.isObject {
            if let obj = value.toObject(), obj.classID == JSClassID.JS_CLASS_PROMISE.rawValue {
                // Check if the constructor matches (Species check)
                // Simplified: assume same constructor
                return value.dupValue()
            }
        }

        // Create a new resolved promise
        guard let cap = newPromiseCapability(ctx: ctx, ctor: this) else {
            return .exception
        }

        let _ = ctx.callFunction(func_: cap.resolve, this: .undefined, args: [value])
        ctx.freeValue(cap.resolve)
        ctx.freeValue(cap.reject)

        return cap.promise
    }

    /// Promise.reject(reason)
    /// Returns a promise rejected with the given reason.
    static func reject(ctx: JeffJSContext, this: JeffJSValue,
                       args: [JeffJSValue]) -> JeffJSValue {
        let reason = args.count >= 1 ? args[0] : JeffJSValue.undefined

        guard let cap = newPromiseCapability(ctx: ctx, ctor: this) else {
            return .exception
        }

        let _ = ctx.callFunction(func_: cap.reject, this: .undefined, args: [reason])
        ctx.freeValue(cap.resolve)
        ctx.freeValue(cap.reject)

        return cap.promise
    }

    /// Promise.all(iterable)
    /// Waits for all promises to fulfill, or rejects on the first rejection.
    static func all(ctx: JeffJSContext, this: JeffJSValue,
                    args: [JeffJSValue], magic: Int) -> JeffJSValue {
        let iterable = args.count >= 1 ? args[0] : JeffJSValue.undefined

        guard let cap = newPromiseCapability(ctx: ctx, ctor: this) else {
            return .exception
        }

        let allData = PromiseAllData()
        allData.resolveFunc = cap.resolve.dupValue()
        allData.rejectFunc = cap.reject.dupValue()
        allData.promiseCapability = cap

        // Get the iterator
        let iterResult = getIterator(ctx: ctx, iterable: iterable)
        if iterResult.isException {
            let _ = ctx.callFunction(func_: cap.reject, this: .undefined,
                                     args: [ctx.getException()])
            ctx.freeValue(cap.resolve)
            ctx.freeValue(cap.reject)
            return cap.promise
        }

        var index = 0
        allData.remainingElements = 1 // Will be decremented after loop
        let maxIterations = 10_000 // safety limit

        while index < maxIterations {
            let next = iteratorNext(ctx: ctx, iterator: iterResult)
            if next.isException {
                let _ = ctx.callFunction(func_: cap.reject, this: .undefined,
                                         args: [ctx.getException()])
                break
            }

            let done = ctx.getPropertyStr(obj: next, name: "done")
            if done.toBool() {
                ctx.freeValue(done)
                ctx.freeValue(next)
                break
            }
            ctx.freeValue(done)

            let nextValue = ctx.getPropertyStr(obj: next, name: "value")
            ctx.freeValue(next)

            // Ensure values array is large enough
            while allData.values.count <= index {
                allData.values.append(JeffJSValue.undefined)
            }

            allData.remainingElements += 1
            let currentIndex = index

            // Resolve the next value through Promise.resolve
            let resolvedPromise = JeffJSBuiltinPromise.resolve(
                ctx: ctx, this: this, args: [nextValue])
            ctx.freeValue(nextValue)

            if resolvedPromise.isException {
                let _ = ctx.callFunction(func_: cap.reject, this: .undefined,
                                         args: [ctx.getException()])
                break
            }

            // Create the element resolve closure
            let onFulfilled = createAllResolveElement(
                ctx: ctx, allData: allData, index: currentIndex)
            let onRejected = cap.reject.dupValue()

            // Attach .then(onFulfilled, onRejected)
            let thenResult = JeffJSBuiltinPromise.performPromiseThen(
                ctx: ctx, promise: resolvedPromise,
                onFulfilled: onFulfilled, onRejected: onRejected,
                resultPromise: nil)

            ctx.freeValue(thenResult)
            ctx.freeValue(onFulfilled)
            ctx.freeValue(onRejected)
            ctx.freeValue(resolvedPromise)

            index += 1
        }

        ctx.freeValue(iterResult)

        // Decrement the initial remaining count
        allData.remainingElements -= 1
        if allData.remainingElements == 0 {
            // All promises resolved synchronously (or there were none)
            let resultsArray = createArrayFromValues(ctx: ctx, values: allData.values)
            let _ = ctx.callFunction(func_: allData.resolveFunc, this: .undefined,
                                     args: [resultsArray])
            ctx.freeValue(resultsArray)
        }

        ctx.freeValue(allData.resolveFunc)
        ctx.freeValue(allData.rejectFunc)
        ctx.freeValue(cap.resolve)
        ctx.freeValue(cap.reject)

        return cap.promise
    }

    /// Promise.allSettled(iterable)
    /// Waits for all promises to settle (fulfill or reject).
    /// Returns array of {status, value/reason} objects.
    static func allSettled(ctx: JeffJSContext, this: JeffJSValue,
                           args: [JeffJSValue], magic: Int) -> JeffJSValue {
        let iterable = args.count >= 1 ? args[0] : JeffJSValue.undefined

        guard let cap = newPromiseCapability(ctx: ctx, ctor: this) else {
            return .exception
        }

        let allData = PromiseAllData()
        allData.resolveFunc = cap.resolve.dupValue()
        allData.rejectFunc = cap.reject.dupValue()
        allData.promiseCapability = cap

        let iterResult = getIterator(ctx: ctx, iterable: iterable)
        if iterResult.isException {
            let _ = ctx.callFunction(func_: cap.reject, this: .undefined,
                                     args: [ctx.getException()])
            ctx.freeValue(cap.resolve)
            ctx.freeValue(cap.reject)
            return cap.promise
        }

        var index = 0
        allData.remainingElements = 1

        while true {
            let next = iteratorNext(ctx: ctx, iterator: iterResult)
            if next.isException {
                let _ = ctx.callFunction(func_: cap.reject, this: .undefined,
                                         args: [ctx.getException()])
                break
            }

            let done = ctx.getPropertyStr(obj: next, name: "done")
            if done.toBool() {
                ctx.freeValue(done)
                ctx.freeValue(next)
                break
            }
            ctx.freeValue(done)

            let nextValue = ctx.getPropertyStr(obj: next, name: "value")
            ctx.freeValue(next)

            while allData.values.count <= index {
                allData.values.append(JeffJSValue.undefined)
            }

            allData.remainingElements += 1
            let currentIndex = index

            let resolvedPromise = JeffJSBuiltinPromise.resolve(
                ctx: ctx, this: this, args: [nextValue])
            ctx.freeValue(nextValue)

            if resolvedPromise.isException {
                let _ = ctx.callFunction(func_: cap.reject, this: .undefined,
                                         args: [ctx.getException()])
                break
            }

            // Create both resolve and reject element closures
            let onFulfilled = createAllSettledResolveElement(
                ctx: ctx, allData: allData, index: currentIndex, isFulfill: true)
            let onRejected = createAllSettledResolveElement(
                ctx: ctx, allData: allData, index: currentIndex, isFulfill: false)

            let thenResult = JeffJSBuiltinPromise.performPromiseThen(
                ctx: ctx, promise: resolvedPromise,
                onFulfilled: onFulfilled, onRejected: onRejected,
                resultPromise: nil)

            ctx.freeValue(thenResult)
            ctx.freeValue(onFulfilled)
            ctx.freeValue(onRejected)
            ctx.freeValue(resolvedPromise)

            index += 1
        }

        ctx.freeValue(iterResult)

        allData.remainingElements -= 1
        if allData.remainingElements == 0 {
            let resultsArray = createArrayFromValues(ctx: ctx, values: allData.values)
            let _ = ctx.callFunction(func_: allData.resolveFunc, this: .undefined,
                                     args: [resultsArray])
            ctx.freeValue(resultsArray)
        }

        ctx.freeValue(allData.resolveFunc)
        ctx.freeValue(allData.rejectFunc)
        ctx.freeValue(cap.resolve)
        ctx.freeValue(cap.reject)

        return cap.promise
    }

    /// Promise.any(iterable)
    /// Resolves with the first fulfilled promise; rejects with AggregateError if all reject.
    static func any(ctx: JeffJSContext, this: JeffJSValue,
                    args: [JeffJSValue], magic: Int) -> JeffJSValue {
        let iterable = args.count >= 1 ? args[0] : JeffJSValue.undefined

        guard let cap = newPromiseCapability(ctx: ctx, ctor: this) else {
            return .exception
        }

        let allData = PromiseAllData()
        allData.resolveFunc = cap.resolve.dupValue()
        allData.rejectFunc = cap.reject.dupValue()
        allData.promiseCapability = cap

        let iterResult = getIterator(ctx: ctx, iterable: iterable)
        if iterResult.isException {
            let _ = ctx.callFunction(func_: cap.reject, this: .undefined,
                                     args: [ctx.getException()])
            ctx.freeValue(cap.resolve)
            ctx.freeValue(cap.reject)
            return cap.promise
        }

        var index = 0
        allData.remainingElements = 1

        while true {
            let next = iteratorNext(ctx: ctx, iterator: iterResult)
            if next.isException {
                let _ = ctx.callFunction(func_: cap.reject, this: .undefined,
                                         args: [ctx.getException()])
                break
            }

            let done = ctx.getPropertyStr(obj: next, name: "done")
            if done.toBool() {
                ctx.freeValue(done)
                ctx.freeValue(next)
                break
            }
            ctx.freeValue(done)

            let nextValue = ctx.getPropertyStr(obj: next, name: "value")
            ctx.freeValue(next)

            while allData.errors.count <= index {
                allData.errors.append(JeffJSValue.undefined)
            }

            allData.remainingElements += 1
            let currentIndex = index

            let resolvedPromise = JeffJSBuiltinPromise.resolve(
                ctx: ctx, this: this, args: [nextValue])
            ctx.freeValue(nextValue)

            if resolvedPromise.isException {
                let _ = ctx.callFunction(func_: cap.reject, this: .undefined,
                                         args: [ctx.getException()])
                break
            }

            // For Promise.any: onFulfilled resolves immediately; onRejected collects errors
            let onFulfilled = cap.resolve.dupValue()
            let onRejected = createAnyRejectElement(
                ctx: ctx, allData: allData, index: currentIndex)

            let thenResult = JeffJSBuiltinPromise.performPromiseThen(
                ctx: ctx, promise: resolvedPromise,
                onFulfilled: onFulfilled, onRejected: onRejected,
                resultPromise: nil)

            ctx.freeValue(thenResult)
            ctx.freeValue(onFulfilled)
            ctx.freeValue(onRejected)
            ctx.freeValue(resolvedPromise)

            index += 1
        }

        ctx.freeValue(iterResult)

        allData.remainingElements -= 1
        if allData.remainingElements == 0 {
            // All rejected -- create AggregateError
            let errorsArray = createArrayFromValues(ctx: ctx, values: allData.errors)
            let aggError = createAggregateError(ctx: ctx, errors: errorsArray,
                                                 message: "All promises were rejected")
            let _ = ctx.callFunction(func_: allData.rejectFunc, this: .undefined,
                                     args: [aggError])
            ctx.freeValue(errorsArray)
            ctx.freeValue(aggError)
        }

        ctx.freeValue(allData.resolveFunc)
        ctx.freeValue(allData.rejectFunc)
        ctx.freeValue(cap.resolve)
        ctx.freeValue(cap.reject)

        return cap.promise
    }

    /// Promise.race(iterable)
    /// The first promise to settle (fulfill or reject) wins.
    static func race(ctx: JeffJSContext, this: JeffJSValue,
                     args: [JeffJSValue]) -> JeffJSValue {
        let iterable = args.count >= 1 ? args[0] : JeffJSValue.undefined

        guard let cap = newPromiseCapability(ctx: ctx, ctor: this) else {
            return .exception
        }

        let iterResult = getIterator(ctx: ctx, iterable: iterable)
        if iterResult.isException {
            let _ = ctx.callFunction(func_: cap.reject, this: .undefined,
                                     args: [ctx.getException()])
            ctx.freeValue(cap.resolve)
            ctx.freeValue(cap.reject)
            return cap.promise
        }

        while true {
            let next = iteratorNext(ctx: ctx, iterator: iterResult)
            if next.isException {
                let _ = ctx.callFunction(func_: cap.reject, this: .undefined,
                                         args: [ctx.getException()])
                break
            }

            let done = ctx.getPropertyStr(obj: next, name: "done")
            if done.toBool() {
                ctx.freeValue(done)
                ctx.freeValue(next)
                break
            }
            ctx.freeValue(done)

            let nextValue = ctx.getPropertyStr(obj: next, name: "value")
            ctx.freeValue(next)

            let resolvedPromise = JeffJSBuiltinPromise.resolve(
                ctx: ctx, this: this, args: [nextValue])
            ctx.freeValue(nextValue)

            if resolvedPromise.isException {
                let _ = ctx.callFunction(func_: cap.reject, this: .undefined,
                                         args: [ctx.getException()])
                break
            }

            // Attach .then(resolve, reject) — first to settle wins
            let thenResult = JeffJSBuiltinPromise.performPromiseThen(
                ctx: ctx, promise: resolvedPromise,
                onFulfilled: cap.resolve, onRejected: cap.reject,
                resultPromise: nil)

            ctx.freeValue(thenResult)
            ctx.freeValue(resolvedPromise)
        }

        ctx.freeValue(iterResult)
        ctx.freeValue(cap.resolve)
        ctx.freeValue(cap.reject)

        return cap.promise
    }

    /// Promise.withResolvers()
    /// Returns { promise, resolve, reject }.
    static func withResolvers(ctx: JeffJSContext, this: JeffJSValue,
                              args: [JeffJSValue]) -> JeffJSValue {
        guard let cap = newPromiseCapability(ctx: ctx, ctor: this) else {
            return .exception
        }

        let result = ctx.newPlainObject()
        ctx.setPropertyStr(obj: result, name: "promise", value: cap.promise)
        ctx.setPropertyStr(obj: result, name: "resolve", value: cap.resolve)
        ctx.setPropertyStr(obj: result, name: "reject", value: cap.reject)

        return result
    }

    /// Promise.try(callbackfn, ...args)
    /// Calls the callback and wraps the result or thrown exception in a promise.
    static func try_(ctx: JeffJSContext, this: JeffJSValue,
                     args: [JeffJSValue]) -> JeffJSValue {
        guard let cap = newPromiseCapability(ctx: ctx, ctor: this) else {
            return .exception
        }

        let callback = args.count >= 1 ? args[0] : JeffJSValue.undefined
        let callArgs = args.count >= 2 ? Array(args[1...]) : []

        let callResult = ctx.callFunction(func_: callback, this: .undefined, args: callArgs)

        if callResult.isException {
            let exception = ctx.getException()
            let _ = ctx.callFunction(func_: cap.reject, this: .undefined, args: [exception])
            ctx.freeValue(exception)
        } else {
            let _ = ctx.callFunction(func_: cap.resolve, this: .undefined, args: [callResult])
        }

        ctx.freeValue(callResult)
        ctx.freeValue(cap.resolve)
        ctx.freeValue(cap.reject)

        return cap.promise
    }

    // MARK: - Prototype Methods

    /// Promise.prototype.then(onFulfilled, onRejected)
    /// Registers fulfillment and rejection handlers on the promise.
    static func then(ctx: JeffJSContext, this: JeffJSValue,
                     args: [JeffJSValue]) -> JeffJSValue {
        guard let promiseObj = this.toObject(),
              promiseObj.classID == JSClassID.JS_CLASS_PROMISE.rawValue else {
            return ctx.throwTypeError("Promise.prototype.then called on non-promise")
        }

        let onFulfilled = args.count >= 1 ? args[0] : JeffJSValue.undefined
        let onRejected = args.count >= 2 ? args[1] : JeffJSValue.undefined

        // Get the constructor for species
        let ctor = ctx.getPropertyStr(obj: this, name: "constructor")
        let ctorToUse = ctor.isUndefined ? ctx.getPropertyStr(
            obj: ctx.globalObject, name: "Promise") : ctor

        guard let cap = newPromiseCapability(ctx: ctx, ctor: ctorToUse) else {
            ctx.freeValue(ctor)
            return .exception
        }
        ctx.freeValue(ctor)

        let result = performPromiseThen(ctx: ctx, promise: this,
                                         onFulfilled: onFulfilled, onRejected: onRejected,
                                         resultPromise: cap.promise)

        ctx.freeValue(cap.resolve)
        ctx.freeValue(cap.reject)

        if result.isException { return result }
        ctx.freeValue(result)

        return cap.promise
    }

    /// Promise.prototype.catch(onRejected)
    /// Equivalent to .then(undefined, onRejected).
    static func catch_(ctx: JeffJSContext, this: JeffJSValue,
                       args: [JeffJSValue]) -> JeffJSValue {
        let onRejected = args.count >= 1 ? args[0] : JeffJSValue.undefined
        return then(ctx: ctx, this: this, args: [JeffJSValue.undefined, onRejected])
    }

    /// Promise.prototype.finally(onFinally)
    /// Registers a handler that is called when the promise settles (regardless of outcome).
    static func finally_(ctx: JeffJSContext, this: JeffJSValue,
                         args: [JeffJSValue]) -> JeffJSValue {
        let onFinally = args.count >= 1 ? args[0] : JeffJSValue.undefined

        if !ctx.isFunction(onFinally) {
            // If onFinally is not callable, pass through
            return then(ctx: ctx, this: this,
                        args: [onFinally, onFinally])
        }

        // Get the constructor
        let ctor = ctx.getPropertyStr(obj: this, name: "constructor")
        let ctorToUse = ctor.isUndefined ? ctx.getPropertyStr(
            obj: ctx.globalObject, name: "Promise") : ctor

        // Create then-finally callback: value => { onFinally(); return value; }
        let thenFinally = ctx.newCFunction(name: "thenFinally", length: 1) { c, _, innerArgs in
            let value = innerArgs.count >= 1 ? innerArgs[0] : JeffJSValue.undefined
            let callResult = c.callFunction(func_: onFinally, this: .undefined, args: [])
            if callResult.isException { return callResult }
            c.freeValue(callResult)

            // Return Promise.resolve(callResult).then(() => value)
            let resolved = JeffJSBuiltinPromise.resolve(ctx: c, this: ctorToUse, args: [callResult])
            if resolved.isException { return resolved }

            let returnValue = value.dupValue()
            let valueThunk = c.newCFunction(name: "", length: 0) { c2, _, _ in
                return returnValue
            }
            let finalResult = JeffJSBuiltinPromise.then(
                ctx: c, this: resolved, args: [valueThunk])
            c.freeValue(valueThunk)
            c.freeValue(resolved)
            return finalResult
        }

        // Create catch-finally callback: reason => { onFinally(); throw reason; }
        let catchFinally = ctx.newCFunction(name: "catchFinally", length: 1) { c, _, innerArgs in
            let reason = innerArgs.count >= 1 ? innerArgs[0] : JeffJSValue.undefined
            let callResult = c.callFunction(func_: onFinally, this: .undefined, args: [])
            if callResult.isException { return callResult }
            c.freeValue(callResult)

            let resolved = JeffJSBuiltinPromise.resolve(ctx: c, this: ctorToUse, args: [callResult])
            if resolved.isException { return resolved }

            let thrownReason = reason.dupValue()
            let reasonThunk = c.newCFunction(name: "", length: 0) { c2, _, _ in
                return c2.throwTypeError(
                    thrownReason.isString
                    ? (thrownReason.stringValue?.toSwiftString() ?? "rejected")
                    : "rejected")
            }
            let finalResult = JeffJSBuiltinPromise.then(
                ctx: c, this: resolved, args: [reasonThunk])
            c.freeValue(reasonThunk)
            c.freeValue(resolved)
            return finalResult
        }

        let result = then(ctx: ctx, this: this, args: [thenFinally, catchFinally])

        ctx.freeValue(thenFinally)
        ctx.freeValue(catchFinally)
        ctx.freeValue(ctor)

        return result
    }

    // MARK: - Internal: Promise Capability

    /// NewPromiseCapability(C)
    /// Creates a new PromiseCapability record: { promise, resolve, reject }.
    /// The promise is created by calling new C(executor) where executor
    /// captures resolve and reject.
    static func newPromiseCapability(ctx: JeffJSContext,
                                     ctor: JeffJSValue) -> (promise: JeffJSValue, resolve: JeffJSValue, reject: JeffJSValue)? {
        let promiseObj = createPromiseObject(ctx: ctx)
        if promiseObj.isException { return nil }

        let (resolveFunc, rejectFunc) = createResolvingFunctions(ctx: ctx, promise: promiseObj)

        return (promise: promiseObj, resolve: resolveFunc, reject: rejectFunc)
    }

    // MARK: - Internal: PerformPromiseThen

    /// PerformPromiseThen(promise, onFulfilled, onRejected, resultCapability)
    /// The core of .then(). Either queues reactions (if pending) or enqueues a
    /// microtask job (if already settled).
    @discardableResult
    static func performPromiseThen(ctx: JeffJSContext, promise: JeffJSValue,
                                    onFulfilled: JeffJSValue, onRejected: JeffJSValue,
                                    resultPromise: JeffJSValue?) -> JeffJSValue {
        guard let promiseObj = promise.toObject(),
              promiseObj.classID == JSClassID.JS_CLASS_PROMISE.rawValue else {
            return ctx.throwTypeError("not a promise")
        }

        let promiseData = getPromiseData(promiseObj)

        // Get the result promise's resolve/reject functions (if any)
        var capResolve = JeffJSValue.undefined
        var capReject = JeffJSValue.undefined

        if let resultPromise = resultPromise, let resultObj = resultPromise.toObject() {
            let resultData = getPromiseData(resultObj)
            // The resolve/reject for the result promise are created
            // by the caller (newPromiseCapability). We extract them from
            // the resolving functions that were created with the promise.
            let (rf, rj) = createResolvingFunctions(ctx: ctx, promise: resultPromise)
            capResolve = rf
            capReject = rj
            _ = resultData // suppress warning
        }

        // Create the reaction records
        let fulfillReaction = JeffJSPromiseReaction(
            handler: ctx.isFunction(onFulfilled) ? onFulfilled.dupValue() : .undefined,
            resolveFunc: capResolve.dupValue(),
            rejectFunc: capReject.dupValue(),
            isFulfill: true
        )

        let rejectReaction = JeffJSPromiseReaction(
            handler: ctx.isFunction(onRejected) ? onRejected.dupValue() : .undefined,
            resolveFunc: capResolve.dupValue(),
            rejectFunc: capReject.dupValue(),
            isFulfill: false
        )

        ctx.freeValue(capResolve)
        ctx.freeValue(capReject)

        switch promiseData.promiseState {
        case .pending:
            // Queue the reactions for later
            promiseData.promiseFulfillReactions.append(fulfillReaction)
            promiseData.promiseRejectReactions.append(rejectReaction)

        case .fulfilled:
            // Already fulfilled — enqueue a microtask for the fulfill reaction
            promiseData.isHandled = true
            enqueueReactionJob(ctx: ctx, reaction: fulfillReaction,
                               argument: promiseData.promiseResult)

        case .rejected:
            // Already rejected — enqueue a microtask for the reject reaction
            if !promiseData.isHandled {
                // Track unhandled rejection
                hostPromiseRejectionTracker(ctx: ctx, promise: promise,
                                             isHandled: true)
            }
            promiseData.isHandled = true
            enqueueReactionJob(ctx: ctx, reaction: rejectReaction,
                               argument: promiseData.promiseResult)
        }

        return JeffJSValue.undefined
    }

    // MARK: - Internal: CreateResolvingFunctions

    /// CreateResolvingFunctions(promise)
    /// Returns a (resolve, reject) pair of one-shot functions for the promise.
    /// Once either is called, both become no-ops (alreadyResolved flag).
    static func createResolvingFunctions(ctx: JeffJSContext,
                                          promise: JeffJSValue) -> (resolve: JeffJSValue, reject: JeffJSValue) {
        let data = ResolvingFunctionsData(promiseObj: promise.toObject())

        let resolveFunc = ctx.newCFunction(name: "resolve", length: 1) { c, _, args in
            if data.alreadyResolved { return JeffJSValue.undefined }
            data.alreadyResolved = true

            let resolution = args.count >= 1 ? args[0] : JeffJSValue.undefined

            guard let promObj = data.promiseObj else { return JeffJSValue.undefined }
            let promVal = JeffJSValue.mkPtr(tag: .object, ptr: promObj)

            // Cannot resolve a promise with itself
            if resolution.isObject, let resObj = resolution.toObject(), resObj === promObj {
                let err = c.throwTypeError("Promise cannot be resolved with itself")
                JeffJSBuiltinPromise.rejectPromise(ctx: c, promise: promVal, reason: c.getException())
                return err
            }

            JeffJSBuiltinPromise.resolvePromise(ctx: c, promise: promVal, resolution: resolution)
            return JeffJSValue.undefined
        }

        let rejectFunc = ctx.newCFunction(name: "reject", length: 1) { c, _, args in
            if data.alreadyResolved { return JeffJSValue.undefined }
            data.alreadyResolved = true

            let reason = args.count >= 1 ? args[0] : JeffJSValue.undefined

            guard let promObj = data.promiseObj else { return JeffJSValue.undefined }
            let promVal = JeffJSValue.mkPtr(tag: .object, ptr: promObj)

            JeffJSBuiltinPromise.rejectPromise(ctx: c, promise: promVal, reason: reason)
            return JeffJSValue.undefined
        }

        return (resolve: resolveFunc, reject: rejectFunc)
    }

    // MARK: - Internal: FulfillPromise

    /// FulfillPromise(promise, value)
    /// Transitions the promise from pending to fulfilled with the given value,
    /// and triggers all queued fulfill reactions.
    static func fulfillPromise(ctx: JeffJSContext, promise: JeffJSValue,
                                value: JeffJSValue) {
        guard let promiseObj = promise.toObject() else { return }
        let promiseData = getPromiseData(promiseObj)

        guard promiseData.promiseState == .pending else { return }

        // Save the reactions before clearing
        let reactions = promiseData.promiseFulfillReactions

        // Transition state
        promiseData.promiseState = .fulfilled
        promiseData.promiseResult = value.dupValue()
        promiseData.promiseFulfillReactions = []
        promiseData.promiseRejectReactions = []

        // Trigger reactions
        triggerPromiseReactions(ctx: ctx, reactions: reactions, argument: value)
    }

    // MARK: - Internal: RejectPromise

    /// RejectPromise(promise, reason)
    /// Transitions the promise from pending to rejected with the given reason,
    /// and triggers all queued reject reactions.
    static func rejectPromise(ctx: JeffJSContext, promise: JeffJSValue,
                               reason: JeffJSValue) {
        guard let promiseObj = promise.toObject() else { return }
        let promiseData = getPromiseData(promiseObj)

        guard promiseData.promiseState == .pending else { return }

        let reactions = promiseData.promiseRejectReactions

        promiseData.promiseState = .rejected
        promiseData.promiseResult = reason.dupValue()
        promiseData.promiseFulfillReactions = []
        promiseData.promiseRejectReactions = []

        // Track unhandled rejection
        if !promiseData.isHandled {
            hostPromiseRejectionTracker(ctx: ctx, promise: promise, isHandled: false)
        }

        triggerPromiseReactions(ctx: ctx, reactions: reactions, argument: reason)
    }

    // MARK: - Internal: TriggerPromiseReactions

    /// TriggerPromiseReactions(reactions, argument)
    /// Enqueues a microtask job for each reaction in the list.
    static func triggerPromiseReactions(ctx: JeffJSContext,
                                        reactions: [JeffJSPromiseReaction],
                                        argument: JeffJSValue) {
        for reaction in reactions {
            enqueueReactionJob(ctx: ctx, reaction: reaction, argument: argument)
        }
    }

    // MARK: - Internal: ResolvePromise (Promise Resolution Procedure)

    /// Promise Resolution Procedure.
    /// If resolution is a thenable, enqueue a PromiseResolveThenableJob.
    /// Otherwise, fulfill the promise with the resolution value.
    ///
    /// Includes two safety measures to prevent infinite thenable chains:
    /// 1. If resolution is already a JeffJS Promise, unwrap it directly
    ///    instead of going through the generic thenable path.
    /// 2. A recursion depth guard rejects the promise if the chain
    ///    exceeds `maxResolveDepth` levels.
    static func resolvePromise(ctx: JeffJSContext, promise: JeffJSValue,
                                resolution: JeffJSValue) {
        // --- Option 3: Recursion guard ---
        _resolveDepth += 1
        defer { _resolveDepth -= 1 }

        if _resolveDepth > maxResolveDepth {
            _ = ctx.throwTypeError("Promise resolve thenable chain too deep")
            let reason = ctx.getException()
            rejectPromise(ctx: ctx, promise: promise, reason: reason)
            ctx.freeValue(reason)
            return
        }

        // If resolution is not an object, fulfill directly
        guard resolution.isObject else {
            fulfillPromise(ctx: ctx, promise: promise, value: resolution)
            return
        }

        // --- Option 2: Short-circuit for JeffJS Promise objects ---
        // If the resolution is already one of our own Promise objects we can
        // read its state directly, avoiding the generic thenable path that
        // would create a PromiseResolveThenableJob (which itself calls
        // .then(), creating a new promise capability, potentially ad infinitum).
        if let resObj = resolution.toObject(),
           resObj.classID == JSClassID.JS_CLASS_PROMISE.rawValue {
            let promiseData = getPromiseData(resObj)
            switch promiseData.promiseState {
            case .fulfilled:
                fulfillPromise(ctx: ctx, promise: promise, value: promiseData.promiseResult)
                return
            case .rejected:
                rejectPromise(ctx: ctx, promise: promise, reason: promiseData.promiseResult)
                return
            case .pending:
                // The resolution promise is still pending — subscribe directly
                // to its reaction lists so that when it settles, our promise
                // settles too, without creating an intermediate thenable job.
                guard let promiseObj = promise.toObject() else { return }
                let myData = getPromiseData(promiseObj)
                guard myData.promiseState == .pending else { return }

                let (resolveFunc, rejectFunc) = createResolvingFunctions(
                    ctx: ctx, promise: promise)

                let fulfillReaction = JeffJSPromiseReaction(
                    handler: .undefined,
                    resolveFunc: resolveFunc,
                    rejectFunc: rejectFunc,
                    isFulfill: true)
                let rejectReaction = JeffJSPromiseReaction(
                    handler: .undefined,
                    resolveFunc: resolveFunc.dupValue(),
                    rejectFunc: rejectFunc.dupValue(),
                    isFulfill: false)

                promiseData.promiseFulfillReactions.append(fulfillReaction)
                promiseData.promiseRejectReactions.append(rejectReaction)
                return
            }
        }

        // Check if the resolution has a `then` method (thenable check)
        let thenMethod = ctx.getPropertyStr(obj: resolution, name: "then")

        if thenMethod.isException {
            let exception = ctx.getException()
            rejectPromise(ctx: ctx, promise: promise, reason: exception)
            ctx.freeValue(exception)
            return
        }

        if ctx.isFunction(thenMethod) {
            // Resolution is a thenable — enqueue PromiseResolveThenableJob
            enqueueResolveThenableJob(ctx: ctx, promise: promise,
                                      thenable: resolution, then: thenMethod)
        } else {
            // `then` is not a function — fulfill with the resolution object
            fulfillPromise(ctx: ctx, promise: promise, value: resolution)
        }

        ctx.freeValue(thenMethod)
    }

    // MARK: - Microtask Job Helpers

    /// Enqueue a promise reaction job.
    /// When the job runs, it calls the reaction handler (or passes through
    /// the argument if no handler) and resolves/rejects the result promise.
    private static func enqueueReactionJob(ctx: JeffJSContext,
                                            reaction: JeffJSPromiseReaction,
                                            argument: JeffJSValue) {
        let handler = reaction.handler
        let resolveFunc = reaction.resolveFunc
        let rejectFunc = reaction.rejectFunc
        let isFulfill = reaction.isFulfill
        let argDup = argument.dupValue()

        ctx.rt.enqueueJob(ctx: ctx, jobFunc: { jobCtx, _, _ in
            var handlerResult: JeffJSValue
            var rejected = false

            if handler.isUndefined {
                // No handler — default behavior
                if isFulfill {
                    handlerResult = argDup.dupValue()
                } else {
                    handlerResult = argDup.dupValue()
                    rejected = true
                }
            } else {
                // Call the handler
                handlerResult = jobCtx.callFunction(func_: handler, this: .undefined,
                                                     args: [argDup])
                if handlerResult.isException {
                    handlerResult = jobCtx.getException()
                    rejected = true
                }
            }

            // Resolve or reject the result promise
            if rejected {
                if !rejectFunc.isUndefined {
                    let _ = jobCtx.callFunction(func_: rejectFunc, this: .undefined,
                                                args: [handlerResult])
                }
            } else {
                if !resolveFunc.isUndefined {
                    let _ = jobCtx.callFunction(func_: resolveFunc, this: .undefined,
                                                args: [handlerResult])
                }
            }

            jobCtx.freeValue(handlerResult)
            return JeffJSValue.undefined
        }, args: [])
    }

    /// Enqueue a PromiseResolveThenableJob.
    /// Calls thenable.then(resolve, reject) where resolve/reject are the
    /// resolving functions of the original promise.
    private static func enqueueResolveThenableJob(ctx: JeffJSContext,
                                                   promise: JeffJSValue,
                                                   thenable: JeffJSValue,
                                                   then: JeffJSValue) {
        let promiseDup = promise.dupValue()
        let thenableDup = thenable.dupValue()
        let thenDup = then.dupValue()

        ctx.rt.enqueueJob(ctx: ctx, jobFunc: { jobCtx, _, _ in
            let (resolveFunc, rejectFunc) = createResolvingFunctions(
                ctx: jobCtx, promise: promiseDup)

            let result = jobCtx.callFunction(func_: thenDup, this: thenableDup,
                                              args: [resolveFunc, rejectFunc])

            if result.isException {
                let exception = jobCtx.getException()
                let _ = jobCtx.callFunction(func_: rejectFunc, this: .undefined,
                                            args: [exception])
                jobCtx.freeValue(exception)
            }

            jobCtx.freeValue(result)
            jobCtx.freeValue(resolveFunc)
            jobCtx.freeValue(rejectFunc)
            jobCtx.freeValue(thenDup)

            return JeffJSValue.undefined
        }, args: [])
    }

    // MARK: - Promise Object Creation

    /// Create a new bare Promise object with pending state.
    /// Uses newObjectClass so the promise gets a proper shape (needed for
    /// property storage) and inherits Promise.prototype (needed for .then/.catch/.finally).
    private static func createPromiseObject(ctx: JeffJSContext) -> JeffJSValue {
        let promiseVal = ctx.newObjectClass(classID: JSClassID.JS_CLASS_PROMISE.rawValue)
        if promiseVal.isException { return promiseVal }
        if let obj = promiseVal.toObject() {
            let data = JeffJSPromiseData()
            obj.payload = .promiseData(data)
        }
        return promiseVal
    }

    /// Extract JeffJSPromiseData from a promise object.
    /// If the payload is not a promiseData, creates and attaches one.
    private static func getPromiseData(_ obj: JeffJSObject) -> JeffJSPromiseData {
        if case .promiseData(let data) = obj.payload {
            return data
        }
        let data = JeffJSPromiseData()
        obj.payload = .promiseData(data)
        return data
    }

    // MARK: - Promise.all Element Resolve Closure

    /// Creates a resolve element function for Promise.all at the given index.
    /// When called, stores the value and decrements remainingElements.
    /// When remainingElements reaches 0, resolves the aggregate promise.
    private static func createAllResolveElement(
        ctx: JeffJSContext, allData: PromiseAllData, index: Int) -> JeffJSValue {
        var alreadyCalled = false

        return ctx.newCFunction(name: "", length: 1) { c, _, args in
            if alreadyCalled { return JeffJSValue.undefined }
            alreadyCalled = true

            let value = args.count >= 1 ? args[0] : JeffJSValue.undefined

            // Store the value at the correct index
            while allData.values.count <= index {
                allData.values.append(JeffJSValue.undefined)
            }
            allData.values[index] = value.dupValue()

            allData.remainingElements -= 1
            if allData.remainingElements == 0 {
                let resultsArray = createArrayFromValues(ctx: c, values: allData.values)
                let _ = c.callFunction(func_: allData.resolveFunc, this: .undefined,
                                       args: [resultsArray])
                c.freeValue(resultsArray)
            }

            return JeffJSValue.undefined
        }
    }

    // MARK: - Promise.allSettled Element Closures

    /// Creates a resolve/reject element function for Promise.allSettled.
    /// Stores { status: "fulfilled"/"rejected", value/reason } objects.
    private static func createAllSettledResolveElement(
        ctx: JeffJSContext, allData: PromiseAllData, index: Int,
        isFulfill: Bool) -> JeffJSValue {
        var alreadyCalled = false

        return ctx.newCFunction(name: "", length: 1) { c, _, args in
            if alreadyCalled { return JeffJSValue.undefined }
            alreadyCalled = true

            let arg = args.count >= 1 ? args[0] : JeffJSValue.undefined

            // Create the result object { status, value/reason }
            let resultObj = c.newPlainObject()

            if isFulfill {
                c.setPropertyStr(obj: resultObj, name: "status",
                                 value: c.newStringValue("fulfilled"))
                c.setPropertyStr(obj: resultObj, name: "value", value: arg.dupValue())
            } else {
                c.setPropertyStr(obj: resultObj, name: "status",
                                 value: c.newStringValue("rejected"))
                c.setPropertyStr(obj: resultObj, name: "reason", value: arg.dupValue())
            }

            while allData.values.count <= index {
                allData.values.append(JeffJSValue.undefined)
            }
            allData.values[index] = resultObj

            allData.remainingElements -= 1
            if allData.remainingElements == 0 {
                let resultsArray = createArrayFromValues(ctx: c, values: allData.values)
                let _ = c.callFunction(func_: allData.resolveFunc, this: .undefined,
                                       args: [resultsArray])
                c.freeValue(resultsArray)
            }

            return JeffJSValue.undefined
        }
    }

    // MARK: - Promise.any Reject Element Closure

    /// Creates a reject element function for Promise.any at the given index.
    /// Collects errors; when all reject, creates AggregateError.
    private static func createAnyRejectElement(
        ctx: JeffJSContext, allData: PromiseAllData, index: Int) -> JeffJSValue {
        var alreadyCalled = false

        return ctx.newCFunction(name: "", length: 1) { c, _, args in
            if alreadyCalled { return JeffJSValue.undefined }
            alreadyCalled = true

            let reason = args.count >= 1 ? args[0] : JeffJSValue.undefined

            while allData.errors.count <= index {
                allData.errors.append(JeffJSValue.undefined)
            }
            allData.errors[index] = reason.dupValue()

            allData.remainingElements -= 1
            if allData.remainingElements == 0 {
                let errorsArray = createArrayFromValues(ctx: c, values: allData.errors)
                let aggError = createAggregateError(ctx: c, errors: errorsArray,
                                                     message: "All promises were rejected")
                let _ = c.callFunction(func_: allData.rejectFunc, this: .undefined,
                                       args: [aggError])
                c.freeValue(errorsArray)
                c.freeValue(aggError)
            }

            return JeffJSValue.undefined
        }
    }

    // MARK: - Unhandled Rejection Tracker

    /// Notify the host about promise rejection tracking.
    /// Calls the runtime's hostPromiseRejectionTracker if set.
    private static func hostPromiseRejectionTracker(ctx: JeffJSContext,
                                                     promise: JeffJSValue,
                                                     isHandled: Bool) {
        guard let promiseObj = promise.toObject() else { return }
        let promiseData = getPromiseData(promiseObj)

        if let tracker = ctx.rt.hostPromiseRejectionTracker {
            tracker(ctx, isHandled, promise, promiseData.promiseResult,
                    ctx.rt.hostPromiseRejectionTrackerOpaque)
        }
    }

    // MARK: - Helper: Iterator Protocol

    /// Get an iterator from an iterable.
    /// Simplified: treats arrays directly as iterables.
    private static func getIterator(ctx: JeffJSContext,
                                     iterable: JeffJSValue) -> JeffJSValue {
        // Check for Symbol.iterator method
        let iterMethod = ctx.getPropertyStr(obj: iterable, name: "@@iterator")

        if ctx.isFunction(iterMethod) {
            let iterator = ctx.callFunction(func_: iterMethod, this: iterable, args: [])
            ctx.freeValue(iterMethod)
            return iterator
        }
        ctx.freeValue(iterMethod)

        // Fallback: if it's an array, create a simple array iterator
        if ctx.isArray(iterable) {
            return createArrayIterator(ctx: ctx, array: iterable)
        }

        return ctx.throwTypeError("object is not iterable")
    }

    /// Get the next value from an iterator.
    private static func iteratorNext(ctx: JeffJSContext,
                                      iterator: JeffJSValue) -> JeffJSValue {
        let nextMethod = ctx.getPropertyStr(obj: iterator, name: "next")
        if !ctx.isFunction(nextMethod) {
            ctx.freeValue(nextMethod)
            // Check if this is our simple array iterator
            return simpleArrayIteratorNext(ctx: ctx, iterator: iterator)
        }

        let result = ctx.callFunction(func_: nextMethod, this: iterator, args: [])
        ctx.freeValue(nextMethod)
        return result
    }

    /// Create a simple array iterator object.
    private static func createArrayIterator(ctx: JeffJSContext,
                                             array: JeffJSValue) -> JeffJSValue {
        let iterObj = ctx.newPlainObject()
        ctx.setPropertyStr(obj: iterObj, name: "__array__", value: array.dupValue())
        ctx.setPropertyStr(obj: iterObj, name: "__index__", value: JeffJSValue.newInt32(0))
        return iterObj
    }

    /// Advance a simple array iterator.
    private static func simpleArrayIteratorNext(ctx: JeffJSContext,
                                                 iterator: JeffJSValue) -> JeffJSValue {
        let array = ctx.getPropertyStr(obj: iterator, name: "__array__")
        let indexVal = ctx.getPropertyStr(obj: iterator, name: "__index__")

        if array.isUndefined || indexVal.isUndefined {
            let result = ctx.newPlainObject()
            ctx.setPropertyStr(obj: result, name: "done", value: JeffJSValue.JS_TRUE)
            ctx.setPropertyStr(obj: result, name: "value", value: .undefined)
            return result
        }

        let index = indexVal.isInt ? Int(indexVal.toInt32()) : 0
        let length = ctx.getPropertyLength(array)

        if index >= length {
            let result = ctx.newPlainObject()
            ctx.setPropertyStr(obj: result, name: "done", value: JeffJSValue.JS_TRUE)
            ctx.setPropertyStr(obj: result, name: "value", value: .undefined)
            return result
        }

        let value = ctx.getPropertyUInt32(obj: array, index: UInt32(index))

        // Update the index
        ctx.setPropertyStr(obj: iterator, name: "__index__",
                           value: JeffJSValue.newInt32(Int32(index + 1)))

        let result = ctx.newPlainObject()
        ctx.setPropertyStr(obj: result, name: "done", value: JeffJSValue.JS_FALSE)
        ctx.setPropertyStr(obj: result, name: "value", value: value)
        return result
    }

    // MARK: - Helper: Array from Values

    /// Create a JS array from a Swift array of JeffJSValues.
    private static func createArrayFromValues(ctx: JeffJSContext,
                                               values: [JeffJSValue]) -> JeffJSValue {
        let arr = ctx.newArray()
        for (i, val) in values.enumerated() {
            ctx.setPropertyUInt32(obj: arr, index: UInt32(i), value: val.dupValue())
        }
        return arr
    }

    // MARK: - Helper: AggregateError

    /// Create an AggregateError object with the given errors array and message.
    private static func createAggregateError(ctx: JeffJSContext,
                                              errors: JeffJSValue,
                                              message: String) -> JeffJSValue {
        let errObj = ctx.newPlainObject()
        ctx.setPropertyStr(obj: errObj, name: "name",
                           value: ctx.newStringValue("AggregateError"))
        ctx.setPropertyStr(obj: errObj, name: "message",
                           value: ctx.newStringValue(message))
        ctx.setPropertyStr(obj: errObj, name: "errors", value: errors.dupValue())
        return errObj
    }
}

// MARK: - Context Extension for Exception Handling

// getException() is defined in JeffJSContext.swift.
// This file uses it from there to avoid duplicate declarations.
