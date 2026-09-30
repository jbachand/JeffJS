// JeffJSBuiltinIterator.swift
// JeffJS - 1:1 Swift port of QuickJS JavaScript engine
//
// Port of the Iterator, Generator, AsyncFunction, and AsyncGenerator built-ins
// from QuickJS. Implements:
// - Iterator constructor and Iterator.from()
// - Iterator.prototype helper methods (ES2025 Iterator Helpers)
// - Iterator.prototype.map/filter/take/drop/flatMap/reduce/toArray/forEach/some/every/find
// - Iterator.concat (ES2025)
// - Generator.prototype.next/return/throw
// - AsyncGenerator.prototype.next/return/throw
//
// QuickJS source reference: quickjs.c -- js_iterator_proto,
// js_generator_proto, js_async_generator_proto, js_iterator_helper_*,
// js_create_iterator_result, etc.
// Copyright 2026 Jeff Bachand. All rights reserved.

import Foundation

// MARK: - Async Generator Request

/// Represents a pending request in an async generator's queue.
/// Each call to .next()/.return()/.throw() creates one of these.
///
/// Mirrors QuickJS `JSAsyncGeneratorRequest`.
nonisolated final class JeffJSAsyncGeneratorRequest {
    /// Completion type: 0 = next, 1 = return, 2 = throw
    var completionType: Int
    /// The value passed to next(value), return(value), or throw(value)
    var result: JeffJSValue
    /// The promise returned to the caller
    var promise: JeffJSValue
    /// The (resolve, reject) pair for the promise
    var resolvingFuncs: (resolve: JeffJSValue, reject: JeffJSValue)

    init(completionType: Int,
         result: JeffJSValue,
         promise: JeffJSValue,
         resolvingFuncs: (JeffJSValue, JeffJSValue)) {
        self.completionType = completionType
        self.result = result
        self.promise = promise
        self.resolvingFuncs = resolvingFuncs
    }
}

// MARK: - Iterator Helper Data

/// The state of an Iterator Helper object (ES2025 §27.1.2.1: what the
/// helper's abstract closure captures, plus the generator state
/// CreateIteratorFromClosure gives it) or of a %WrapForValidIteratorPrototype%
/// object (`kind == .wrap`: just [[Iterated]]). Lives in the object's payload;
/// the object has no own properties. Every JeffJSValue here is owned.
nonisolated final class JeffJSIteratorHelperData {
    enum Kind { case map, filter, take, drop, flatMap, concat, wrap }
    enum State { case suspendedStart, suspendedYield, executing, completed }

    let kind: Kind
    var state: State = .suspendedStart
    /// [[UnderlyingIterator]] (map … flatMap) / [[Iterated]] (wrap).
    var iterator: JeffJSValue = .undefined
    var nextMethod: JeffJSValue = .undefined
    /// mapper / predicate.
    var fn: JeffJSValue = .undefined
    var counter: Double = 0
    /// take / drop: the remaining limit (+∞ allowed).
    var remaining: Double = 0
    /// flatMap / concat: the inner iterator being drained.
    var inner: JeffJSValue = .undefined
    var innerNext: JeffJSValue = .undefined
    var innerAlive = false
    /// concat: [openMethod₀, iterable₀, openMethod₁, iterable₁, …].
    var items: [JeffJSValue] = []
    var itemIndex = 0

    init(kind: Kind) { self.kind = kind }

    func clearInner() {
        inner.freeValue(); inner = .undefined
        innerNext.freeValue(); innerNext = .undefined
        innerAlive = false
    }

    /// Drops every reference (a completed helper keeps nothing alive).
    func release() {
        clearInner()
        iterator.freeValue(); iterator = .undefined
        nextMethod.freeValue(); nextMethod = .undefined
        fn.freeValue(); fn = .undefined
        for v in items { v.freeValue() }
        items = []
    }

    deinit {
        if JeffJSGCObjectHeader.activeRuntime != nil { release() }
    }
}

// MARK: - JeffJSBuiltinIterator

/// Implements the Iterator, Generator, AsyncFunction, and AsyncGenerator
/// built-ins for JeffJS.
///
/// Mirrors QuickJS js_iterator_proto, js_generator_proto,
/// js_async_generator_proto, and the ES2025 Iterator Helpers proposal.
struct JeffJSBuiltinIterator {

    // MARK: - Intrinsic Registration

    /// Registers Iterator, Generator, and Async Generator prototypes and methods.
    ///
    /// Sets up:
    /// - Iterator constructor (abstract, not directly constructible)
    /// - Iterator.from()
    /// - Iterator.prototype: map, filter, take, drop, flatMap, reduce, toArray,
    ///   forEach, some, every, find, [Symbol.iterator], [Symbol.toStringTag]
    /// - Iterator.concat (static)
    /// - Generator.prototype: next, return, throw
    /// - AsyncGenerator.prototype: next, return, throw
    static func addIntrinsic(ctx: JeffJSContext) {

        // ---------------------------------------------------------------
        // 1. Iterator.prototype (%IteratorPrototype%)
        // ---------------------------------------------------------------
        let iterProto = ctx.newObject()

        // Iterator.prototype[Symbol.iterator]() -- returns `this`
        let iterSymbolIter = ctx.newCFunction({ ctx, this, args in
            return this.dupValue()
        }, name: "[Symbol.iterator]", length: 0)
        let symIterAtom = JeffJSAtomID.JS_ATOM_Symbol_iterator.rawValue
        ctx.setProperty(obj: iterProto, atom: symIterAtom, value: iterSymbolIter)
        ctx.iteratorProto = iterProto.dupValue()
        // The builtin iterator prototypes were created as plain objects: give
        // them %IteratorPrototype% as [[Prototype]] so `[...arr.values()]`,
        // `Array.from(map.keys())` and `for...of` over an iterator work.
        for cid in [JSClassID.JS_CLASS_ARRAY_ITERATOR.rawValue,
                    JSClassID.JS_CLASS_STRING_ITERATOR.rawValue,
                    JSClassID.JS_CLASS_MAP_ITERATOR.rawValue,
                    JSClassID.JS_CLASS_SET_ITERATOR.rawValue] where cid < ctx.classProto.count {
            let p = ctx.classProto[cid]
            if let po = p.toObject(), po.proto == nil || po.proto === ctx.objectPrototype.toObject() {
                _ = ctx.setPrototypeOf(obj: p, proto: iterProto)
            }
        }

        // Iterator.prototype helper methods (ES2025 §27.1.4), non-enumerable.
        ctx.setPropertyFunc(obj: iterProto, name: "map",     fn: iteratorMap,     length: 1)
        ctx.setPropertyFunc(obj: iterProto, name: "filter",  fn: iteratorFilter,  length: 1)
        ctx.setPropertyFunc(obj: iterProto, name: "take",    fn: iteratorTake,    length: 1)
        ctx.setPropertyFunc(obj: iterProto, name: "drop",    fn: iteratorDrop,    length: 1)
        ctx.setPropertyFunc(obj: iterProto, name: "flatMap", fn: iteratorFlatMap, length: 1)
        ctx.setPropertyFunc(obj: iterProto, name: "reduce",  fn: iteratorReduce,  length: 1)
        ctx.setPropertyFunc(obj: iterProto, name: "toArray", fn: iteratorToArray, length: 0)
        ctx.setPropertyFunc(obj: iterProto, name: "forEach", fn: iteratorForEach, length: 1)
        ctx.setPropertyFunc(obj: iterProto, name: "some",    fn: iteratorSome,    length: 1)
        ctx.setPropertyFunc(obj: iterProto, name: "every",   fn: iteratorEvery,   length: 1)
        ctx.setPropertyFunc(obj: iterProto, name: "find",    fn: iteratorFind,    length: 1)

        // ---------------------------------------------------------------
        // 2. Iterator constructor (§27.1.3.1): abstract; `super()` from a
        //    subclass creates the instance.
        // ---------------------------------------------------------------
        let iterCtor = ctx.newCFunction({ ctx, this, args in .undefined }, name: "Iterator", length: 0)
        if let o = iterCtor.toObject() {
            o.payload = .cFunc(
                realm: ctx,
                cFunction: .constructorOrFunc({ ctx, newTarget, args, isNew in
                    iteratorConstructor(ctx: ctx, newTarget: newTarget, isNew: isNew)
                }),
                length: 0,
                cproto: UInt8(JS_CFUNC_CONSTRUCTOR_OR_FUNC),
                magic: 0)
            o.isConstructor = true
        }
        ctx.setPropertyFunc(obj: iterCtor, name: "from", fn: iteratorFrom, length: 1)
        ctx.setPropertyFunc(obj: iterCtor, name: "concat", fn: iteratorConcat, length: 0)
        // Iterator.prototype: { [[Writable]]: false, [[Enumerable]]: false, [[Configurable]]: false }
        _ = ctx.definePropertyValue(obj: iterCtor, atom: JeffJSAtomID.JS_ATOM_prototype.rawValue,
                                    value: iterProto, flags: 0)
        ctx.iteratorCtor = iterCtor.dupValue()

        // Iterator.prototype[@@toStringTag] and .constructor are accessors
        // (§27.1.4.1, §27.1.4.14): the getter answers "Iterator" / %Iterator%,
        // the setter is SetterThatIgnoresPrototypeProperties — assigning on
        // an iterator creates an own property instead of failing on the
        // inherited accessor.
        func defineIgnoringAccessor(_ atom: UInt32, _ label: String, value: @escaping (JeffJSContext) -> JeffJSValue) {
            let getter = ctx.newCFunction({ ctx, this, args in value(ctx) }, name: "get \(label)", length: 0)
            let setter = ctx.newCFunction({ ctx, this, args in
                setterThatIgnoresPrototypeProperties(ctx: ctx, this: this, atom: atom,
                                                     value: args.isEmpty ? .undefined : args[0])
            }, name: "set \(label)", length: 1)
            _ = ctx.defineProperty(obj: iterProto, atom: atom, value: .undefined,
                                   getter: getter, setter: setter,
                                   flags: JS_PROP_HAS_GET | JS_PROP_HAS_SET | JS_PROP_HAS_CONFIGURABLE |
                                          JS_PROP_CONFIGURABLE | JS_PROP_HAS_ENUMERABLE | JS_PROP_GETSET)
            getter.freeValue()
            setter.freeValue()
        }
        defineIgnoringAccessor(JeffJSAtomID.JS_ATOM_Symbol_toStringTag.rawValue, "[Symbol.toStringTag]") { ctx in
            ctx.newStringValue("Iterator")
        }
        defineIgnoringAccessor(JeffJSAtomID.JS_ATOM_constructor.rawValue, "constructor") { ctx in
            ctx.iteratorCtor.dupValue()
        }

        // %IteratorHelperPrototype% (§27.1.2.1) and %WrapForValidIteratorPrototype%
        // (§27.1.3.2.1.1), both inheriting %Iterator.prototype%.
        let helperClass = JSClassID.JS_CLASS_ITERATOR_HELPER.rawValue
        let wrapClass = JSClassID.JS_CLASS_ITERATOR_WRAP.rawValue
        while ctx.classProto.count <= max(helperClass, wrapClass) { ctx.classProto.append(.undefined) }
        let helperProto = ctx.newObjectProto(proto: iterProto)
        ctx.setPropertyFunc(obj: helperProto, name: "next", fn: helperNext, length: 0)
        ctx.setPropertyFunc(obj: helperProto, name: "return", fn: helperReturn, length: 0)
        _ = ctx.definePropertyValue(obj: helperProto,
                                    atom: JeffJSAtomID.JS_ATOM_Symbol_toStringTag.rawValue,
                                    value: ctx.newStringValue("Iterator Helper"),
                                    flags: JS_PROP_CONFIGURABLE)
        ctx.classProto[helperClass] = helperProto
        let wrapProto = ctx.newObjectProto(proto: iterProto)
        ctx.setPropertyFunc(obj: wrapProto, name: "next", fn: wrapNext, length: 0)
        ctx.setPropertyFunc(obj: wrapProto, name: "return", fn: wrapReturn, length: 0)
        ctx.classProto[wrapClass] = wrapProto

        // Register Iterator on the global object
        ctx.setPropertyStr(obj: ctx.globalObj, name: "Iterator", value: iterCtor)

        // ---------------------------------------------------------------
        // 3. Generator.prototype (%GeneratorPrototype%)
        // ---------------------------------------------------------------
        let genProto = ctx.newObjectProto(proto: iterProto)

        addProtoFunc(ctx, genProto, "next",   generatorNext,   1)
        addProtoFunc(ctx, genProto, "return", generatorReturn, 1)
        addProtoFunc(ctx, genProto, "throw",  generatorThrow,  1)

        // Generator.prototype[Symbol.toStringTag] = "Generator"
        ctx.setPropertyStr(obj: genProto, name: "toStringTag",
                           value: ctx.newStringValue("Generator"))

        // Set Generator prototype on the class proto table
        let genClassID = JSClassID.JS_CLASS_GENERATOR.rawValue
        if genClassID < ctx.classProto.count {
            ctx.classProto[genClassID] = genProto.dupValue()
        }

        // ---------------------------------------------------------------
        // 4. GeneratorFunction.prototype
        // ---------------------------------------------------------------
        let genFuncProto = ctx.newObjectProto(proto: ctx.functionProto)

        ctx.setPropertyStr(obj: genFuncProto, name: "prototype", value: genProto.dupValue())
        ctx.setPropertyStr(obj: genFuncProto, name: "toStringTag",
                           value: ctx.newStringValue("GeneratorFunction"))

        let genFuncClassID = JSClassID.JS_CLASS_GENERATOR_FUNCTION.rawValue
        if genFuncClassID < ctx.classProto.count {
            ctx.classProto[genFuncClassID] = genFuncProto.dupValue()
        }

        // ---------------------------------------------------------------
        // 5. AsyncIterator.prototype (%AsyncIteratorPrototype%)
        // ---------------------------------------------------------------
        let asyncIterProto = ctx.newObject()

        // AsyncIterator.prototype[Symbol.asyncIterator]() -- returns `this`
        let asyncIterSymbol = ctx.newCFunction({ ctx, this, args in
            return this.dupValue()
        }, name: "[Symbol.asyncIterator]", length: 0)
        let symAsyncIterAtom = JeffJSAtomID.JS_ATOM_Symbol_asyncIterator.rawValue
        ctx.setProperty(obj: asyncIterProto, atom: symAsyncIterAtom, value: asyncIterSymbol)

        ctx.asyncIteratorProto = asyncIterProto.dupValue()

        // ---------------------------------------------------------------
        // 6. AsyncGenerator.prototype
        // ---------------------------------------------------------------
        let asyncGenProto = ctx.newObjectProto(proto: asyncIterProto)

        addProtoFunc(ctx, asyncGenProto, "next",   asyncGeneratorNext,   1)
        addProtoFunc(ctx, asyncGenProto, "return", asyncGeneratorReturn, 1)
        addProtoFunc(ctx, asyncGenProto, "throw",  asyncGeneratorThrow,  1)

        ctx.setPropertyStr(obj: asyncGenProto, name: "toStringTag",
                           value: ctx.newStringValue("AsyncGenerator"))

        let asyncGenClassID = JSClassID.JS_CLASS_ASYNC_GENERATOR.rawValue
        if asyncGenClassID < ctx.classProto.count {
            ctx.classProto[asyncGenClassID] = asyncGenProto.dupValue()
        }

        // ---------------------------------------------------------------
        // 7. AsyncGeneratorFunction.prototype
        // ---------------------------------------------------------------
        let asyncGenFuncProto = ctx.newObjectProto(proto: ctx.functionProto)

        ctx.setPropertyStr(obj: asyncGenFuncProto, name: "prototype",
                           value: asyncGenProto.dupValue())
        ctx.setPropertyStr(obj: asyncGenFuncProto, name: "toStringTag",
                           value: ctx.newStringValue("AsyncGeneratorFunction"))

        let asyncGenFuncClassID = JSClassID.JS_CLASS_ASYNC_GENERATOR_FUNCTION.rawValue
        if asyncGenFuncClassID < ctx.classProto.count {
            ctx.classProto[asyncGenFuncClassID] = asyncGenFuncProto.dupValue()
        }

        // ---------------------------------------------------------------
        // 8. AsyncFunction.prototype
        // ---------------------------------------------------------------
        let asyncFuncProto = ctx.newObjectProto(proto: ctx.functionProto)

        ctx.setPropertyStr(obj: asyncFuncProto, name: "toStringTag",
                           value: ctx.newStringValue("AsyncFunction"))

        let asyncFuncClassID = JSClassID.JS_CLASS_ASYNC_FUNCTION.rawValue
        if asyncFuncClassID < ctx.classProto.count {
            ctx.classProto[asyncFuncClassID] = asyncFuncProto.dupValue()
        }
    }

    // MARK: - Helper: add a method to a prototype object

    private static func addProtoFunc(
        _ ctx: JeffJSContext,
        _ proto: JeffJSValue,
        _ name: String,
        _ fn: @escaping (JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue,
        _ length: Int
    ) {
        let f = ctx.newCFunction(fn, name: name, length: length)
        ctx.setPropertyStr(obj: proto, name: name, value: f)
    }

    // MARK: - Iterator Result Helper

    /// Creates an iterator result object `{ value: val, done: done }`.
    ///
    /// Mirrors `js_create_iterator_result` in QuickJS.
    ///
    /// - Parameters:
    ///   - ctx: The JS context.
    ///   - val: The `value` property.
    ///   - done: The `done` property.
    /// - Returns: A new JS object `{ value, done }`.
    static func createIterResult(ctx: JeffJSContext, val: JeffJSValue,
                                  done: Bool) -> JeffJSValue {
        // Shared `{ value, done }` shape: one object and two slot appends,
        // instead of two string-interned property adds per step.
        return ctx.makeIterResult(value: val.dupValue(), done: done)
    }

    // MARK: - Get Iterator Helper

    /// Gets the iterator from an object by calling obj[Symbol.iterator]() or
    /// obj[Symbol.asyncIterator]().
    ///
    /// Mirrors `JS_GetIterator` in QuickJS.
    ///
    /// - Parameters:
    ///   - ctx: The JS context.
    ///   - obj: The object to get an iterator from.
    ///   - isAsync: If true, look for Symbol.asyncIterator first.
    /// - Returns: The iterator object, or nil on failure (exception set on ctx).
    static func getIterator(ctx: JeffJSContext, obj: JeffJSValue,
                             isAsync: Bool = false) -> JeffJSValue? {
        let methodAtom: UInt32
        if isAsync {
            // Try Symbol.asyncIterator first
            methodAtom = JeffJSAtomID.JS_ATOM_Symbol_asyncIterator.rawValue
        } else {
            methodAtom = JeffJSAtomID.JS_ATOM_Symbol_iterator.rawValue
        }

        let method = ctx.getProperty(obj: obj, atom: methodAtom)
        if method.isException { return nil }

        if method.isUndefined || method.isNull {
            if isAsync {
                // Fallback to sync iterator for async iteration
                let syncMethod = ctx.getProperty(obj: obj,
                    atom: JeffJSAtomID.JS_ATOM_Symbol_iterator.rawValue)
                if syncMethod.isException { return nil }
                if syncMethod.isUndefined || syncMethod.isNull {
                    _ = ctx.throwTypeError(message: "object is not iterable")
                    return nil
                }
                // Call the sync iterator method
                return callIteratorMethod(ctx: ctx, method: syncMethod, obj: obj)
            }
            _ = ctx.throwTypeError(message: "object is not iterable")
            return nil
        }

        return callIteratorMethod(ctx: ctx, method: method, obj: obj)
    }

    /// Call an iterator method on an object and validate the result is an object.
    private static func callIteratorMethod(ctx: JeffJSContext, method: JeffJSValue,
                                            obj: JeffJSValue) -> JeffJSValue? {
        // Call method with obj as `this`
        guard let methodObj = method.toObject() else {
            _ = ctx.throwTypeError(message: "iterator method is not a function")
            return nil
        }

        let result: JeffJSValue
        if let cFunc = methodObj.cFunction {
            result = cFunc(ctx, obj, [])
        } else {
            // For bytecode functions, the engine would use its call mechanism.
            // Placeholder: try the cFunction path; for a full engine this
            // would go through JS_Call.
            _ = ctx.throwTypeError(message: "iterator method is not callable")
            return nil
        }

        if result.isException { return nil }
        if !result.isObject {
            _ = ctx.throwTypeError(message: "iterator must return an object")
            return nil
        }
        return result
    }

    // MARK: - Iterator records (ES2025 §7.4)

    /// One IteratorStep / IteratorStepValue outcome. `.value` is owned.
    enum StepOutcome { case value(JeffJSValue), done, error }

    /// IteratorStepValue (ES2025 §7.4.8), or IteratorStep when `readValue` is
    /// false (`.value(.undefined)` then). `iterator` / `next` are borrowed.
    static func stepIterator(_ ctx: JeffJSContext, _ iterator: JeffJSValue, _ next: JeffJSValue,
                             readValue: Bool = true) -> StepOutcome {
        guard ctx.isCallable(next) else {
            _ = ctx.throwTypeError(message: "\(ctx.jscValueDescription(next)) is not a function")
            return .error
        }
        let r = ctx.callFunction(next, thisVal: iterator, args: [])
        if r.isException { return .error }
        guard r.isObject else {
            r.freeValue()
            _ = ctx.throwTypeError(message: "Iterator result interface is not an object.")
            return .error
        }
        let d = ctx.getProperty(obj: r, atom: JeffJSAtomID.JS_ATOM_done.rawValue)
        if d.isException { r.freeValue(); return .error }
        if ctx.toBoolFree(d) { r.freeValue(); return .done }
        if !readValue { r.freeValue(); return .value(.undefined) }
        let v = ctx.getProperty(obj: r, atom: JeffJSAtomID.JS_ATOM_value.rawValue)
        r.freeValue()
        if v.isException { return .error }
        return .value(v)
    }

    /// IteratorClose(iterator, NormalCompletion / ReturnCompletion) (§7.4.11):
    /// calls `return` if there is one; its errors and a non-object result
    /// throw. Returns false with the exception pending.
    static func closeIterator(_ ctx: JeffJSContext, _ iterator: JeffJSValue) -> Bool {
        let ret = ctx.getProperty(obj: iterator, atom: ctx.iterReturnAtom)
        if ret.isException { return false }
        if ret.isUndefined || ret.isNull { return true }
        guard ctx.isCallable(ret) else {
            _ = ctx.throwTypeError(message: "\(ctx.jscValueDescription(ret)) is not a function")
            ret.freeValue()
            return false
        }
        let r = ctx.callFunction(ret, thisVal: iterator, args: [])
        ret.freeValue()
        if r.isException { return false }
        let isObj = r.isObject
        r.freeValue()
        if !isObj {
            _ = ctx.throwTypeError(message: "Iterator result interface is not an object.")
            return false
        }
        return true
    }

    /// IteratorClose(iterator, ThrowCompletion) with the exception pending on
    /// `ctx`: `return` is called, whatever it does is ignored, and the
    /// original exception stays the pending one.
    static func closeIteratorOnThrow(_ ctx: JeffJSContext, _ iterator: JeffJSValue) {
        if ctx.rt.currentExceptionIsUncatchable || !iterator.isObject { return }
        let exc = ctx.getException()
        let ret = ctx.getProperty(obj: iterator, atom: ctx.iterReturnAtom)
        if ret.isException {
            ctx.getException().freeValue()
        } else if ctx.isCallable(ret) {
            let r = ctx.callFunction(ret, thisVal: iterator, args: [])
            if r.isException { ctx.getException().freeValue() } else { r.freeValue() }
        }
        ret.freeValue()
        _ = ctx.throwValue(exc)
    }

    /// GetIteratorFlattenable(obj, primitiveHandling) (§7.4.13): the iterator
    /// and its `next` (both owned), or nil with the exception pending.
    static func getIteratorFlattenable(_ ctx: JeffJSContext, _ obj: JeffJSValue,
                                       allowStrings: Bool) -> (JeffJSValue, JeffJSValue)? {
        if !obj.isObject && !(allowStrings && obj.isString) {
            _ = ctx.throwTypeError(message: allowStrings
                ? "GetIteratorFlattenable expects its first argument to be an object or a string"
                : "GetIteratorFlattenable expects its first argument to be an object")
            return nil
        }
        let method = ctx.getProperty(obj: obj, atom: JeffJSAtomID.JS_ATOM_Symbol_iterator.rawValue)
        if method.isException { return nil }
        let iterator: JeffJSValue
        if method.isUndefined || method.isNull {
            iterator = obj.dupValue()
        } else {
            guard ctx.isCallable(method) else {
                _ = ctx.throwTypeError(message: "\(ctx.jscValueDescription(method)) is not a function")
                method.freeValue()
                return nil
            }
            iterator = ctx.callFunction(method, thisVal: obj, args: [])
            method.freeValue()
            if iterator.isException { return nil }
        }
        guard iterator.isObject else {
            iterator.freeValue()
            _ = ctx.throwTypeError(message: "Iterator result interface is not an object.")
            return nil
        }
        let next = ctx.getProperty(obj: iterator, atom: ctx.iterNextAtom)
        if next.isException { iterator.freeValue(); return nil }
        return (iterator, next)
    }

    /// A counter / index as a JS number.
    @inline(__always)
    static func numberValue(_ d: Double) -> JeffJSValue {
        if d <= Double(Int32.max) { return .newInt32(Int32(d)) }
        return .newFloat64(d)
    }

    // MARK: - Iterator constructor (ES2025 §27.1.3.1)

    /// `Iterator()`: abstract — `new Iterator()` and a plain call throw; a
    /// subclass's `super()` gets OrdinaryCreateFromConstructor(NewTarget,
    /// %Iterator.prototype%).
    static func iteratorConstructor(ctx: JeffJSContext, newTarget: JeffJSValue,
                                    isNew: Bool) -> JeffJSValue {
        if !isNew || newTarget.isUndefined {
            return ctx.throwTypeError(message: "calling Iterator constructor without new is invalid")
        }
        if newTarget.bits == ctx.iteratorCtor.bits {
            return ctx.throwTypeError(message: "Iterator cannot be constructed directly")
        }
        let protoVal = ctx.getProperty(obj: newTarget, atom: JeffJSAtomID.JS_ATOM_prototype.rawValue)
        if protoVal.isException { return .exception }
        let result = ctx.newObjectProto(proto: protoVal.isObject ? protoVal : ctx.iteratorProto)
        protoVal.freeValue()
        return result
    }

    /// SetterThatIgnoresPrototypeProperties(this, %Iterator.prototype%, p, v)
    /// (ES2025 §27.1.4.14.1 / §10.4.? ): a TypeError on a primitive receiver
    /// or on the prototype itself; otherwise define an own data property if
    /// there is none, else Set.
    static func setterThatIgnoresPrototypeProperties(ctx: JeffJSContext, this: JeffJSValue,
                                                     atom: UInt32, value: JeffJSValue) -> JeffJSValue {
        guard let o = this.toObject() else {
            return ctx.throwTypeError(message: "SetterThatIgnoresPrototypeProperties expected |this| to be an object.")
        }
        if let home = ctx.iteratorProto.toObject(), o === home {
            return ctx.throwTypeError(message: "SetterThatIgnoresPrototypeProperties was called on a home object.")
        }
        let desc = ctx.getOwnProperty(obj: this, atom: atom)
        if desc == nil {
            if ctx.defineProperty(obj: this, atom: atom, value: value,
                                  flags: JS_PROP_HAS_VALUE | JS_PROP_HAS_WRITABLE | JS_PROP_WRITABLE |
                                         JS_PROP_HAS_ENUMERABLE | JS_PROP_ENUMERABLE |
                                         JS_PROP_HAS_CONFIGURABLE | JS_PROP_CONFIGURABLE | JS_PROP_THROW) < 0 {
                return .exception
            }
        } else if ctx.setProperty(obj: this, atom: atom, value: value.dupValue()) < 0 {
            return .exception
        }
        return .undefined
    }

    // MARK: - Iterator.from (ES2025 §27.1.3.2.1) and %WrapForValidIteratorPrototype%

    static func iteratorFrom(ctx: JeffJSContext, this: JeffJSValue,
                             args: [JeffJSValue]) -> JeffJSValue {
        let value = args.isEmpty ? JeffJSValue.undefined : args[0]
        guard let (iterator, next) = getIteratorFlattenable(ctx, value, allowStrings: true) else {
            return .exception
        }
        if JeffJSBuiltinFunction.ordinaryIsInstanceOf(ctx: ctx, val: iterator, obj: ctx.iteratorCtor) {
            next.freeValue()
            return iterator
        }
        let data = JeffJSIteratorHelperData(kind: .wrap)
        data.iterator = iterator
        data.nextMethod = next
        return makeHelperObject(ctx, data, classID: JSClassID.JS_CLASS_ITERATOR_WRAP.rawValue)
    }

    private static func wrapData(_ this: JeffJSValue) -> JeffJSIteratorHelperData? {
        guard let obj = this.toObject(), obj.classID == JSClassID.JS_CLASS_ITERATOR_WRAP.rawValue,
              case .opaque(let o) = obj.payload, let d = o as? JeffJSIteratorHelperData else { return nil }
        return d
    }

    /// %WrapForValidIteratorPrototype%.next() (§27.1.3.2.1.1.1).
    static func wrapNext(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let d = wrapData(this) else {
            return ctx.throwTypeError(message: "%WrapForValidIteratorPrototype%.next requires that |this| be a WrapForValidIteratorPrototype object")
        }
        guard ctx.isCallable(d.nextMethod) else {
            return ctx.throwTypeError(message: "\(ctx.jscValueDescription(d.nextMethod)) is not a function")
        }
        return ctx.callRetained(d.nextMethod, this: d.iterator, args: [])
    }

    /// %WrapForValidIteratorPrototype%.return() (§27.1.3.2.1.1.2).
    static func wrapReturn(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let d = wrapData(this) else {
            return ctx.throwTypeError(message: "%WrapForValidIteratorPrototype%.return requires that |this| be a WrapForValidIteratorPrototype object")
        }
        let iterator = d.iterator.dupValue()
        defer { iterator.freeValue() }
        let ret = ctx.getProperty(obj: iterator, atom: ctx.iterReturnAtom)
        if ret.isException { return .exception }
        if ret.isUndefined || ret.isNull {
            return ctx.makeIterResult(value: .undefined, done: true)
        }
        guard ctx.isCallable(ret) else {
            _ = ctx.throwTypeError(message: "\(ctx.jscValueDescription(ret)) is not a function")
            ret.freeValue()
            return .exception
        }
        let r = ctx.callFunction(ret, thisVal: iterator, args: [])
        ret.freeValue()
        return r
    }

    // MARK: - %IteratorHelperPrototype% (ES2025 §27.1.2.1)

    static func makeHelperObject(_ ctx: JeffJSContext, _ data: JeffJSIteratorHelperData,
                                 classID: Int) -> JeffJSValue {
        let proto = classID < ctx.classProto.count ? ctx.classProto[classID].toObject() : nil
        let obj = jeffJS_createObject(ctx: ctx, proto: proto, classID: UInt16(classID))
        obj.payload = .opaque(data)
        return JeffJSValue.makeObject(obj)
    }

    private static func helperData(_ this: JeffJSValue) -> JeffJSIteratorHelperData? {
        guard let obj = this.toObject(), obj.classID == JSClassID.JS_CLASS_ITERATOR_HELPER.rawValue,
              case .opaque(let o) = obj.payload, let d = o as? JeffJSIteratorHelperData else { return nil }
        return d
    }

    /// %IteratorHelperPrototype%.next() (§27.1.2.1.1): GeneratorResume of the
    /// helper's closure.
    static func helperNext(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let data = helperData(this) else {
            return ctx.throwTypeError(message: "|this| should be an iterator helper")
        }
        switch data.state {
        case .executing: return ctx.throwTypeError(message: "Generator is executing")
        case .completed: return ctx.makeIterResult(value: .undefined, done: true)
        case .suspendedStart, .suspendedYield: break
        }
        let atStart = data.state == .suspendedStart
        data.state = .executing
        switch helperStep(ctx, data, atStart: atStart) {
        case .value(let v):
            data.state = .suspendedYield
            return ctx.makeIterResult(value: v, done: false)
        case .done:
            data.state = .completed
            data.release()
            return ctx.makeIterResult(value: .undefined, done: true)
        case .error:
            data.state = .completed
            data.release()
            return .exception
        }
    }

    /// %IteratorHelperPrototype%.return() (§27.1.2.1.2): closes the underlying
    /// iterator(s) — GeneratorResumeAbrupt with a return completion.
    static func helperReturn(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let data = helperData(this) else {
            return ctx.throwTypeError(message: "|this| should be an iterator helper")
        }
        var ok = true
        switch data.state {
        case .executing:
            return ctx.throwTypeError(message: "Generator is executing")
        case .completed:
            return ctx.makeIterResult(value: .undefined, done: true)
        case .suspendedStart:
            data.state = .completed
            if data.kind != .concat { ok = closeIterator(ctx, data.iterator) }
        case .suspendedYield:
            data.state = .executing
            switch data.kind {
            case .flatMap where data.innerAlive:
                // Yield's abrupt completion: close the inner iterator, then
                // the outer one (with the inner's error if it threw).
                if closeIterator(ctx, data.inner) {
                    ok = closeIterator(ctx, data.iterator)
                } else {
                    closeIteratorOnThrow(ctx, data.iterator)
                    ok = false
                }
            case .concat:
                if data.innerAlive { ok = closeIterator(ctx, data.inner) }
            default:
                ok = closeIterator(ctx, data.iterator)
            }
            data.state = .completed
        }
        data.release()
        return ok ? ctx.makeIterResult(value: .undefined, done: true) : .exception
    }

    /// Runs the helper's closure from where it is suspended to its next
    /// Yield (`.value`, owned), its return (`.done`) or a throw (`.error`).
    private static func helperStep(_ ctx: JeffJSContext, _ data: JeffJSIteratorHelperData,
                                   atStart: Bool) -> StepOutcome {
        switch data.kind {
        case .map:
            switch stepIterator(ctx, data.iterator, data.nextMethod) {
            case .error: return .error
            case .done: return .done
            case .value(let v):
                let mapped = ctx.callFunction(data.fn, thisVal: .undefined, args: [v, numberValue(data.counter)])
                v.freeValue()
                if mapped.isException { closeIteratorOnThrow(ctx, data.iterator); return .error }
                data.counter += 1
                return .value(mapped)
            }

        case .filter:
            while true {
                switch stepIterator(ctx, data.iterator, data.nextMethod) {
                case .error: return .error
                case .done: return .done
                case .value(let v):
                    let sel = ctx.callFunction(data.fn, thisVal: .undefined, args: [v, numberValue(data.counter)])
                    if sel.isException { v.freeValue(); closeIteratorOnThrow(ctx, data.iterator); return .error }
                    data.counter += 1
                    if ctx.toBoolFree(sel) { return .value(v) }
                    v.freeValue()
                }
            }

        case .take:
            if data.remaining == 0 {
                return closeIterator(ctx, data.iterator) ? .done : .error
            }
            if data.remaining != .infinity { data.remaining -= 1 }
            return stepIterator(ctx, data.iterator, data.nextMethod)

        case .drop:
            if atStart {
                while data.remaining > 0 {
                    if data.remaining != .infinity { data.remaining -= 1 }
                    switch stepIterator(ctx, data.iterator, data.nextMethod, readValue: false) {
                    case .error: return .error
                    case .done: return .done
                    case .value: break
                    }
                }
            }
            return stepIterator(ctx, data.iterator, data.nextMethod)

        case .flatMap:
            while true {
                if data.innerAlive {
                    switch stepIterator(ctx, data.inner, data.innerNext) {
                    case .error: closeIteratorOnThrow(ctx, data.iterator); return .error
                    case .done: data.clearInner(); data.counter += 1; continue
                    case .value(let v): return .value(v)
                    }
                }
                switch stepIterator(ctx, data.iterator, data.nextMethod) {
                case .error: return .error
                case .done: return .done
                case .value(let v):
                    let mapped = ctx.callFunction(data.fn, thisVal: .undefined, args: [v, numberValue(data.counter)])
                    v.freeValue()
                    if mapped.isException { closeIteratorOnThrow(ctx, data.iterator); return .error }
                    let inner = getIteratorFlattenable(ctx, mapped, allowStrings: false)
                    mapped.freeValue()
                    guard let (it, next) = inner else { closeIteratorOnThrow(ctx, data.iterator); return .error }
                    data.inner = it
                    data.innerNext = next
                    data.innerAlive = true
                }
            }

        case .concat:
            while true {
                if data.innerAlive {
                    switch stepIterator(ctx, data.inner, data.innerNext) {
                    case .error: return .error
                    case .done: data.clearInner(); continue
                    case .value(let v): return .value(v)
                    }
                }
                if data.itemIndex * 2 >= data.items.count { return .done }
                let method = data.items[data.itemIndex * 2], iterable = data.items[data.itemIndex * 2 + 1]
                data.itemIndex += 1
                let it = ctx.callFunction(method, thisVal: iterable, args: [])
                if it.isException { return .error }
                guard it.isObject else {
                    it.freeValue()
                    _ = ctx.throwTypeError(message: "Iterator result interface is not an object.")
                    return .error
                }
                let next = ctx.getProperty(obj: it, atom: ctx.iterNextAtom)
                if next.isException { it.freeValue(); return .error }
                data.inner = it
                data.innerNext = next
                data.innerAlive = true
            }

        case .wrap:
            return .done
        }
    }

    // MARK: - Iterator.prototype methods (ES2025 §27.1.4)

    /// Steps 1-2 of every Iterator.prototype method: `this` must be an Object.
    @inline(__always)
    private static func requireObjectThis(_ ctx: JeffJSContext, _ this: JeffJSValue, _ method: String) -> Bool {
        if this.isObject { return true }
        _ = ctx.throwTypeError(message: "Iterator.prototype.\(method) requires that |this| be an Object.")
        return false
    }

    /// An argument check that fails after `this` is known to be an iterator:
    /// the error closes it (IteratorClose(iterated, error)).
    private static func throwAndClose(_ ctx: JeffJSContext, _ this: JeffJSValue,
                                      range: Bool = false, _ message: String) -> JeffJSValue {
        if range { _ = ctx.throwRangeError(message: message) } else { _ = ctx.throwTypeError(message: message) }
        closeIteratorOnThrow(ctx, this)
        return .exception
    }

    /// map / filter / flatMap: validate the callback, GetIteratorDirect, and
    /// build the helper.
    private static func makeCallbackHelper(_ ctx: JeffJSContext, _ this: JeffJSValue, _ args: [JeffJSValue],
                                           kind: JeffJSIteratorHelperData.Kind, method: String) -> JeffJSValue {
        guard requireObjectThis(ctx, this, method) else { return .exception }
        let fn = args.isEmpty ? JeffJSValue.undefined : args[0]
        guard ctx.isCallable(fn) else {
            return throwAndClose(ctx, this, "Iterator.prototype.\(method) callback must be a function.")
        }
        let next = ctx.getProperty(obj: this, atom: ctx.iterNextAtom)
        if next.isException { return .exception }
        let data = JeffJSIteratorHelperData(kind: kind)
        data.iterator = this.dupValue()
        data.nextMethod = next
        data.fn = fn.dupValue()
        return makeHelperObject(ctx, data, classID: JSClassID.JS_CLASS_ITERATOR_HELPER.rawValue)
    }

    static func iteratorMap(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        makeCallbackHelper(ctx, this, args, kind: .map, method: "map")
    }

    static func iteratorFilter(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        makeCallbackHelper(ctx, this, args, kind: .filter, method: "filter")
    }

    static func iteratorFlatMap(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        makeCallbackHelper(ctx, this, args, kind: .flatMap, method: "flatMap")
    }

    /// take / drop (§27.1.4.12, §27.1.4.3): ToNumber(limit), NaN and negative
    /// limits are RangeErrors (each closing the iterator), then the helper.
    private static func makeLimitHelper(_ ctx: JeffJSContext, _ this: JeffJSValue, _ args: [JeffJSValue],
                                        kind: JeffJSIteratorHelperData.Kind, method: String) -> JeffJSValue {
        guard requireObjectThis(ctx, this, method) else { return .exception }
        let (num, ok) = JeffJSTypeConvert.toNumber(ctx: ctx, val: args.isEmpty ? .undefined : args[0])
        if !ok { closeIteratorOnThrow(ctx, this); return .exception }
        if num.isNaN {
            return throwAndClose(ctx, this, range: true, "Iterator.prototype.\(method) argument must not be NaN.")
        }
        let limit = num.isInfinite ? num : num.rounded(.towardZero)
        if limit < 0 {
            return throwAndClose(ctx, this, range: true, "Iterator.prototype.\(method) argument must be non-negative.")
        }
        let next = ctx.getProperty(obj: this, atom: ctx.iterNextAtom)
        if next.isException { return .exception }
        let data = JeffJSIteratorHelperData(kind: kind)
        data.iterator = this.dupValue()
        data.nextMethod = next
        data.remaining = limit
        return makeHelperObject(ctx, data, classID: JSClassID.JS_CLASS_ITERATOR_HELPER.rawValue)
    }

    static func iteratorTake(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        makeLimitHelper(ctx, this, args, kind: .take, method: "take")
    }

    static func iteratorDrop(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        makeLimitHelper(ctx, this, args, kind: .drop, method: "drop")
    }

    /// The eager methods: `this` checked, `fn` validated (closing on failure),
    /// then the iterator record (owned `next`).
    private static func eagerRecord(_ ctx: JeffJSContext, _ this: JeffJSValue, _ args: [JeffJSValue],
                                    method: String, notCallable: String?) -> JeffJSValue? {
        guard requireObjectThis(ctx, this, method) else { return nil }
        if let message = notCallable, !ctx.isCallable(args.isEmpty ? .undefined : args[0]) {
            _ = throwAndClose(ctx, this, message)
            return nil
        }
        let next = ctx.getProperty(obj: this, atom: ctx.iterNextAtom)
        if next.isException { return nil }
        return next
    }

    /// Iterator.prototype.reduce(reducer [, initialValue]) (§27.1.4.9).
    static func iteratorReduce(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let next = eagerRecord(ctx, this, args, method: "reduce",
                                     notCallable: "Iterator.prototype.reduce reducer argument must be a function.") else {
            return .exception
        }
        defer { next.freeValue() }
        let reducer = args[0]
        var acc: JeffJSValue
        var counter: Double
        if args.count < 2 {
            switch stepIterator(ctx, this, next) {
            case .error: return .exception
            case .done:
                return ctx.throwTypeError(message: "Iterator.prototype.reduce requires an initial value or an iterator that is not done.")
            case .value(let v): acc = v
            }
            counter = 1
        } else {
            acc = args[1].dupValue()
            counter = 0
        }
        while true {
            switch stepIterator(ctx, this, next) {
            case .error: acc.freeValue(); return .exception
            case .done: return acc
            case .value(let v):
                let r = ctx.callFunction(reducer, thisVal: .undefined, args: [acc, v, numberValue(counter)])
                v.freeValue()
                acc.freeValue()
                if r.isException { closeIteratorOnThrow(ctx, this); return .exception }
                acc = r
                counter += 1
            }
        }
    }

    /// Iterator.prototype.toArray() (§27.1.4.13).
    static func iteratorToArray(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let next = eagerRecord(ctx, this, args, method: "toArray", notCallable: nil) else {
            return .exception
        }
        defer { next.freeValue() }
        var items: [JeffJSValue] = []
        while true {
            switch stepIterator(ctx, this, next) {
            case .error: for v in items { v.freeValue() }; return .exception
            case .done: return ctx.newArrayFrom(items)
            case .value(let v): items.append(v)
            }
        }
    }

    /// Iterator.prototype.forEach(fn) (§27.1.4.5).
    static func iteratorForEach(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let next = eagerRecord(ctx, this, args, method: "forEach",
                                     notCallable: "Iterator.prototype.forEach requires the callback argument to be callable.") else {
            return .exception
        }
        defer { next.freeValue() }
        let fn = args[0]
        var counter: Double = 0
        while true {
            switch stepIterator(ctx, this, next) {
            case .error: return .exception
            case .done: return .undefined
            case .value(let v):
                let r = ctx.callFunction(fn, thisVal: .undefined, args: [v, numberValue(counter)])
                v.freeValue()
                if r.isException { closeIteratorOnThrow(ctx, this); return .exception }
                r.freeValue()
                counter += 1
            }
        }
    }

    /// some / every / find (§27.1.4.11, §27.1.4.4, §27.1.4.6): the first
    /// deciding result closes the iterator (IteratorClose with a normal
    /// completion) and is returned.
    private enum ShortCircuit { case some, every, find }

    private static func shortCircuit(_ ctx: JeffJSContext, _ this: JeffJSValue, _ args: [JeffJSValue],
                                     _ mode: ShortCircuit, method: String) -> JeffJSValue {
        guard let next = eagerRecord(ctx, this, args, method: method,
                                     notCallable: "Iterator.prototype.\(method) callback must be a function.") else {
            return .exception
        }
        defer { next.freeValue() }
        let predicate = args[0]
        var counter: Double = 0
        while true {
            switch stepIterator(ctx, this, next) {
            case .error: return .exception
            case .done:
                switch mode {
                case .some: return .JS_FALSE
                case .every: return .JS_TRUE
                case .find: return .undefined
                }
            case .value(let v):
                let r = ctx.callFunction(predicate, thisVal: .undefined, args: [v, numberValue(counter)])
                if r.isException { v.freeValue(); closeIteratorOnThrow(ctx, this); return .exception }
                let truthy = ctx.toBoolFree(r)
                let decided = mode == .every ? !truthy : truthy
                if decided {
                    guard closeIterator(ctx, this) else { v.freeValue(); return .exception }
                    switch mode {
                    case .some: v.freeValue(); return .JS_TRUE
                    case .every: v.freeValue(); return .JS_FALSE
                    case .find: return v
                    }
                }
                v.freeValue()
                counter += 1
            }
        }
    }

    static func iteratorSome(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        shortCircuit(ctx, this, args, .some, method: "some")
    }

    static func iteratorEvery(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        shortCircuit(ctx, this, args, .every, method: "every")
    }

    static func iteratorFind(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        shortCircuit(ctx, this, args, .find, method: "find")
    }

    // MARK: - Iterator.concat(...items) (ES2026 §27.1.3.2.2)

    static func iteratorConcat(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        var items: [JeffJSValue] = []
        func fail(_ message: String?) -> JeffJSValue {
            for v in items { v.freeValue() }
            if let m = message { _ = ctx.throwTypeError(message: m) }
            return .exception
        }
        for item in args {
            guard item.isObject else { return fail("Iterator.concat expects all arguments to be objects") }
            let method = ctx.getProperty(obj: item, atom: JeffJSAtomID.JS_ATOM_Symbol_iterator.rawValue)
            if method.isException { return fail(nil) }
            if method.isUndefined || method.isNull { return fail("Iterator.concat expects all arguments to be iterable") }
            guard ctx.isCallable(method) else {
                let m = "\(ctx.jscValueDescription(method)) is not a function"
                method.freeValue()
                return fail(m)
            }
            items.append(method)
            items.append(item.dupValue())
        }
        let data = JeffJSIteratorHelperData(kind: .concat)
        data.items = items
        return makeHelperObject(ctx, data, classID: JSClassID.JS_CLASS_ITERATOR_HELPER.rawValue)
    }

    // MARK: - Generator.prototype.next(value)

    /// `Generator.prototype.next(value)` -- resumes the generator.
    ///
    /// Returns `{ value, done }`. If the generator is completed, returns
    /// `{ value: undefined, done: true }`.
    ///
    /// Mirrors `js_generator_next` in QuickJS.
    static func generatorNext(ctx: JeffJSContext, this: JeffJSValue,
                               args: [JeffJSValue]) -> JeffJSValue {
        guard let obj = this.toObject() else {
            return ctx.throwTypeError(message: "Generator.prototype.next called on non-object")
        }

        guard case .generatorData(let genData) = obj.payload else {
            return ctx.throwTypeError(message: "not a generator object")
        }

        switch genData.state {
        case .completed:
            return createIterResult(ctx: ctx, val: .undefined, done: true)

        case .executing:
            return ctx.throwTypeError(message: "generator is already executing")

        case .suspended_start, .suspended_yield, .suspended_yield_star:
            let value = args.isEmpty ? JeffJSValue.undefined : args[0]

            // Resume the generator's bytecode execution at the last yield point,
            // passing `value` as the result of the yield expression.
            // completionType 0 = next: push value onto the stack and continue.
            return ctx.generatorResume(genObj: this, sendValue: value, completionType: 0)
        }
    }

    // MARK: - Generator.prototype.return(value)

    /// `Generator.prototype.return(value)` -- forces the generator to return.
    ///
    /// If the generator is suspended, it transitions to the completed state
    /// and returns `{ value: value, done: true }`.
    ///
    /// Mirrors `js_generator_return` in QuickJS.
    static func generatorReturn(ctx: JeffJSContext, this: JeffJSValue,
                                 args: [JeffJSValue]) -> JeffJSValue {
        guard let obj = this.toObject() else {
            return ctx.throwTypeError(message: "Generator.prototype.return called on non-object")
        }

        guard case .generatorData(let genData) = obj.payload else {
            return ctx.throwTypeError(message: "not a generator object")
        }

        let value = args.isEmpty ? JeffJSValue.undefined : args[0]

        switch genData.state {
        case .completed:
            return createIterResult(ctx: ctx, val: value, done: true)

        case .executing:
            return ctx.throwTypeError(message: "generator is already executing")

        case .suspended_start:
            // Generator hasn't executed any code yet; just complete it.
            genData.state = .completed
            if let saved = genData.savedState { JeffJSGeneratorData.releaseSuspendedState(saved) }
            genData.savedState = nil
            return createIterResult(ctx: ctx, val: value, done: true)

        case .suspended_yield, .suspended_yield_star:
            // Resume the generator with a "return" completion (type 1).
            // This will force the generator to return the given value.
            // If the generator body has try/finally blocks, the finally
            // blocks would run first (handled by the interpreter's
            // exception propagation in a full implementation).
            return ctx.generatorResume(genObj: this, sendValue: value, completionType: 1)
        }
    }

    // MARK: - Generator.prototype.throw(exception)

    /// `Generator.prototype.throw(exception)` -- throws into the generator.
    ///
    /// If the generator is suspended at a yield, the exception is thrown at
    /// the yield point. If the generator hasn't started or is completed,
    /// the exception is re-thrown.
    ///
    /// Mirrors `js_generator_throw` in QuickJS.
    static func generatorThrow(ctx: JeffJSContext, this: JeffJSValue,
                                args: [JeffJSValue]) -> JeffJSValue {
        guard let obj = this.toObject() else {
            return ctx.throwTypeError(message: "Generator.prototype.throw called on non-object")
        }

        guard case .generatorData(let genData) = obj.payload else {
            return ctx.throwTypeError(message: "not a generator object")
        }

        let exception = args.isEmpty ? JeffJSValue.undefined : args[0]

        switch genData.state {
        case .completed:
            // Re-throw the exception
            return ctx.throwValue(exception.dupValue())

        case .executing:
            return ctx.throwTypeError(message: "generator is already executing")

        case .suspended_start:
            // Generator hasn't executed any code; complete it and throw
            genData.state = .completed
            if let saved = genData.savedState { JeffJSGeneratorData.releaseSuspendedState(saved) }
            genData.savedState = nil
            return ctx.throwValue(exception.dupValue())

        case .suspended_yield, .suspended_yield_star:
            // Resume the generator with a "throw" completion (type 2).
            // The exception will be thrown at the yield point. If there
            // is a try/catch around it, the catch block handles it and
            // execution continues. Otherwise the generator completes
            // abruptly with the exception.
            return ctx.generatorResume(genObj: this, sendValue: exception, completionType: 2)
        }
    }

    // MARK: - AsyncGenerator.prototype.next(value)

    /// `AsyncGenerator.prototype.next(value)` -- enqueues a next request.
    ///
    /// Returns a Promise that resolves to `{ value, done }`.
    /// Async generators maintain a request queue; if the generator is idle,
    /// the request is processed immediately.
    ///
    /// Mirrors `js_async_generator_next` in QuickJS.
    static func asyncGeneratorNext(ctx: JeffJSContext, this: JeffJSValue,
                                    args: [JeffJSValue]) -> JeffJSValue {
        return asyncGeneratorEnqueue(ctx: ctx, this: this, args: args, completionType: 0)
    }

    // MARK: - AsyncGenerator.prototype.return(value)

    /// `AsyncGenerator.prototype.return(value)` -- enqueues a return request.
    ///
    /// Returns a Promise that resolves to `{ value: value, done: true }`.
    ///
    /// Mirrors `js_async_generator_return` in QuickJS.
    static func asyncGeneratorReturn(ctx: JeffJSContext, this: JeffJSValue,
                                      args: [JeffJSValue]) -> JeffJSValue {
        return asyncGeneratorEnqueue(ctx: ctx, this: this, args: args, completionType: 1)
    }

    // MARK: - AsyncGenerator.prototype.throw(exception)

    /// `AsyncGenerator.prototype.throw(exception)` -- enqueues a throw request.
    ///
    /// Returns a Promise. If the generator is suspended at a yield, the exception
    /// is thrown at the yield point.
    ///
    /// Mirrors `js_async_generator_throw` in QuickJS.
    static func asyncGeneratorThrow(ctx: JeffJSContext, this: JeffJSValue,
                                     args: [JeffJSValue]) -> JeffJSValue {
        return asyncGeneratorEnqueue(ctx: ctx, this: this, args: args, completionType: 2)
    }

    /// Shared implementation for async generator next/return/throw.
    ///
    /// Creates a promise, enqueues the request, and if the generator is idle,
    /// processes the request immediately.
    ///
    /// Mirrors `js_async_generator_resolve_function` and
    /// `js_async_generator_resume_next` in QuickJS.
    ///
    /// - Parameters:
    ///   - completionType: 0 = next, 1 = return, 2 = throw
    /// `next` / `return` / `throw` on an async generator (ES §27.6.3.x
    /// AsyncGeneratorEnqueue + AsyncGeneratorResumeNext).
    ///
    /// Every call answers with a promise and joins a FIFO queue, because the
    /// body can only be in one place at a time. The drain below resumes the
    /// body; if the body parks on an `await`, the head request stays queued
    /// and the promise reaction restarts the drain with the settled value.
    ///
    /// This used to build a promise nobody ever settled and a resolve/reject
    /// pair that returned `undefined`, with "in a full engine ..." at every
    /// branch — async generator objects escaped it only because they were
    /// handed the *synchronous* generator prototype, whose `next` runs the
    /// body to the next yield and returns a plain `{value, done}`.
    private static func asyncGeneratorEnqueue(ctx: JeffJSContext, this: JeffJSValue,
                                               args: [JeffJSValue],
                                               completionType: Int) -> JeffJSValue {
        guard let obj = this.toObject(),
              case .generatorData(let genData) = obj.payload else {
            // A rejected promise, not a throw: these methods never throw
            // synchronously (ES §27.6.3.2 step 8).
            return rejectedPromise(ctx,
                ctx.throwTypeError(message: "not an async generator object"))
        }

        guard let cap = JeffJSBuiltinPromise.newPromiseCapability(ctx: ctx, ctor: .undefined) else {
            return .exception
        }
        let req = JeffJSAsyncGenRequest(
            completionType: completionType,
            value: (args.first ?? .undefined).dupValue(),
            resolve: cap.resolve,
            reject: cap.reject)
        genData.asyncQueue.append(req)
        asyncGeneratorDrain(ctx: ctx, genObj: this, genData: genData)
        return cap.promise
    }

    /// A promise already rejected with the pending exception.
    private static func rejectedPromise(_ ctx: JeffJSContext, _ marker: JeffJSValue) -> JeffJSValue {
        _ = marker
        let exc = ctx.getException()
        guard let cap = JeffJSBuiltinPromise.newPromiseCapability(ctx: ctx, ctor: .undefined) else {
            exc.freeValue()
            return .exception
        }
        _ = ctx.callFunction(cap.reject, thisVal: .undefined, args: [exc])
        exc.freeValue()
        cap.resolve.freeValue(); cap.reject.freeValue()
        return cap.promise
    }

    /// Run queued requests until the queue empties or the body parks on an
    /// `await`. Re-entrant calls (a resolve handler that calls `next` again)
    /// return immediately; the running loop picks the new request up.
    private static func asyncGeneratorDrain(ctx: JeffJSContext, genObj: JeffJSValue,
                                            genData: JeffJSGeneratorData) {
        if genData.asyncDraining { return }
        // Parked on an await: the continuation restarts the drain.
        if !genData.awaitedPromise.isUndefined { return }
        genData.asyncDraining = true
        defer { genData.asyncDraining = false }

        while !genData.asyncQueue.isEmpty {
            let req = genData.asyncQueue[0]

            if genData.state == .completed && !genData.awaitResumePending {
                genData.asyncQueue.removeFirst()
                settleCompleted(ctx, req)
                req.release()
                continue
            }

            // A `return(v)` on a generator that has not started yet finishes it
            // without running a line of the body (ES §27.6.3.8).
            if genData.state == .suspended_start && req.completionType != 0 {
                genData.state = .completed
                genData.savedState = nil
                genData.asyncQueue.removeFirst()
                settleCompleted(ctx, req)
                req.release()
                continue
            }

            let sendValue: JeffJSValue
            let sendType: Int
            var owned = false
            if genData.awaitResumePending {
                sendValue = genData.awaitResumeValue
                sendType = genData.awaitResumeIsThrow ? 2 : 0
                genData.awaitResumePending = false
                genData.awaitResumeValue = .undefined
                owned = true
            } else {
                sendValue = req.value
                sendType = req.completionType
            }

            let result = ctx.generatorResume(genObj: genObj, sendValue: sendValue,
                                             completionType: sendType)
            if owned { sendValue.freeValue() }

            // Parked on an await? The request stays at the head.
            if !genData.awaitedPromise.isUndefined {
                result.freeValue()
                attachAwaitContinuation(ctx: ctx, genObj: genObj, genData: genData)
                return
            }

            genData.asyncQueue.removeFirst()
            if result.isException {
                let exc = ctx.getException()
                _ = ctx.callFunction(req.reject, thisVal: .undefined, args: [exc])
                exc.freeValue()
            } else {
                _ = ctx.callFunction(req.resolve, thisVal: .undefined, args: [result])
            }
            result.freeValue()
            req.release()
        }
    }

    /// Settle a request against a generator that has already finished:
    /// `next()` and `return(v)` resolve, `throw(e)` rejects.
    private static func settleCompleted(_ ctx: JeffJSContext, _ req: JeffJSAsyncGenRequest) {
        if req.completionType == 2 {
            _ = ctx.callFunction(req.reject, thisVal: .undefined, args: [req.value])
            return
        }
        let value: JeffJSValue = req.completionType == 1 ? req.value : .undefined
        let iterResult = createIterResult(ctx: ctx, val: value, done: true)
        _ = ctx.callFunction(req.resolve, thisVal: .undefined, args: [iterResult])
        iterResult.freeValue()
    }

    /// Resume the parked body when its awaited promise settles, then keep
    /// draining. The generator object is retained across the microtask: the
    /// only other reference may be a `for await` temporary that is already
    /// gone by the time the reaction runs.
    private static func attachAwaitContinuation(ctx: JeffJSContext, genObj: JeffJSValue,
                                                genData: JeffJSGeneratorData) {
        let awaited = genData.awaitedPromise
        let held = genObj.dupValue()
        _ = JeffJSBuiltinPromise.performPromiseThen(
            ctx: ctx, promise: awaited,
            onFulfilled: .undefined, onRejected: .undefined,
            resultPromise: nil,
            nativeContinuation: { ctx, value, isRejection in
                genData.awaitedPromise.freeValue()
                genData.awaitedPromise = .undefined
                genData.awaitResumeValue = value.dupValue()
                genData.awaitResumeIsThrow = isRejection
                genData.awaitResumePending = true
                asyncGeneratorDrain(ctx: ctx, genObj: held, genData: genData)
                held.freeValue()
            })
    }
}
