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
final class JeffJSAsyncGeneratorRequest {
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

/// Internal data stored on iterator helper wrapper objects.
/// Used by map, filter, take, drop, flatMap to track state.
///
/// Mirrors QuickJS `JSIteratorHelperData`.
private final class JeffJSIteratorHelperData {
    /// The underlying iterator being wrapped
    var underlying: JeffJSValue = .undefined
    /// The callback function (mapper, predicate, etc.)
    var callback: JeffJSValue = .undefined
    /// Counter for take/drop
    var remaining: Int64 = 0
    /// Is the helper exhausted?
    var done: Bool = false
    /// For flatMap: the inner iterator currently being consumed
    var innerIterator: JeffJSValue = .undefined
    /// For flatMap: is the inner iterator active?
    var innerActive: Bool = false

    init() {}
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
        let rt = ctx.rt

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

        // Iterator.prototype[Symbol.toStringTag] = "Iterator"
        ctx.setPropertyStr(obj: iterProto, name: "toStringTag",
                           value: ctx.newStringValue("Iterator"))

        // Iterator.prototype helper methods (ES2025)
        addProtoFunc(ctx, iterProto, "map",     iteratorMap,     1)
        addProtoFunc(ctx, iterProto, "filter",  iteratorFilter,  1)
        addProtoFunc(ctx, iterProto, "take",    iteratorTake,    1)
        addProtoFunc(ctx, iterProto, "drop",    iteratorDrop,    1)
        addProtoFunc(ctx, iterProto, "flatMap", iteratorFlatMap, 1)
        addProtoFunc(ctx, iterProto, "reduce",  iteratorReduce,  1)
        addProtoFunc(ctx, iterProto, "toArray", iteratorToArray, 0)
        addProtoFunc(ctx, iterProto, "forEach", iteratorForEach, 1)
        addProtoFunc(ctx, iterProto, "some",    iteratorSome,    1)
        addProtoFunc(ctx, iterProto, "every",   iteratorEvery,   1)
        addProtoFunc(ctx, iterProto, "find",    iteratorFind,    1)

        // ---------------------------------------------------------------
        // 2. Iterator constructor
        // ---------------------------------------------------------------
        let iterCtor = ctx.newCFunction({ ctx, this, args in
            return iteratorConstructor(ctx: ctx, newTarget: this, this: this, args: args)
        }, name: "Iterator", length: 0)

        // Iterator.from()
        let iterFromFunc = ctx.newCFunction(iteratorFrom, name: "from", length: 1)
        ctx.setPropertyStr(obj: iterCtor, name: "from", value: iterFromFunc)

        // Iterator.concat() -- ES2025
        let iterConcatFunc = ctx.newCFunction(iteratorConcat, name: "concat", length: 0)
        ctx.setPropertyStr(obj: iterCtor, name: "concat", value: iterConcatFunc)

        // Link Iterator.prototype to Iterator constructor
        ctx.setPropertyStr(obj: iterCtor, name: "prototype", value: iterProto.dupValue())
        ctx.setPropertyStr(obj: iterProto, name: "constructor", value: iterCtor.dupValue())

        // Store Iterator constructor on ctx
        ctx.iteratorCtor = iterCtor.dupValue()

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
        let obj = ctx.newObject()
        if obj.isException { return .exception }

        ctx.setPropertyStr(obj: obj, name: "value", value: val.dupValue())
        ctx.setPropertyStr(obj: obj, name: "done", value: .newBool(done))

        return obj
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

    // MARK: - Call Iterator .next()

    /// Calls iterator.next(value) and returns the result object.
    ///
    /// Mirrors `JS_IteratorNext` in QuickJS.
    private static func iteratorNext(ctx: JeffJSContext, iterator: JeffJSValue,
                                      value: JeffJSValue = .undefined) -> JeffJSValue? {
        let nextMethod = ctx.getPropertyStr(obj: iterator, name: "next")
        if nextMethod.isException { return nil }
        if nextMethod.isUndefined || nextMethod.isNull {
            _ = ctx.throwTypeError(message: "iterator.next is not a function")
            return nil
        }

        guard let nextObj = nextMethod.toObject(), let cFunc = nextObj.cFunction else {
            _ = ctx.throwTypeError(message: "iterator.next is not callable")
            return nil
        }

        let args = value.isUndefined ? [JeffJSValue]() : [value]
        let result = cFunc(ctx, iterator, args)
        if result.isException { return nil }
        if !result.isObject {
            _ = ctx.throwTypeError(message: "iterator.next() must return an object")
            return nil
        }
        return result
    }

    /// Check if an iterator result is done.
    private static func iterResultDone(ctx: JeffJSContext,
                                        iterResult: JeffJSValue) -> Bool {
        let doneVal = ctx.getPropertyStr(obj: iterResult, name: "done")
        return ctx.toBool(doneVal)
    }

    /// Get the value from an iterator result.
    private static func iterResultValue(ctx: JeffJSContext,
                                         iterResult: JeffJSValue) -> JeffJSValue {
        return ctx.getPropertyStr(obj: iterResult, name: "value")
    }

    /// Close an iterator by calling iterator.return() if it exists.
    ///
    /// Mirrors `JS_IteratorClose` in QuickJS.
    private static func iteratorClose(ctx: JeffJSContext,
                                       iterator: JeffJSValue,
                                       completion: JeffJSValue = .undefined) {
        let returnMethod = ctx.getPropertyStr(obj: iterator, name: "return")
        if returnMethod.isException || returnMethod.isUndefined || returnMethod.isNull {
            return
        }
        guard let retObj = returnMethod.toObject(), let cFunc = retObj.cFunction else {
            return
        }
        let args = completion.isUndefined ? [JeffJSValue]() : [completion]
        _ = cFunc(ctx, iterator, args)
    }

    // MARK: - Iterator Constructor

    /// `new Iterator()` -- abstract constructor.
    ///
    /// The Iterator constructor is not meant to be called directly. It serves
    /// as the base class for iterator helpers.
    ///
    /// Mirrors `js_iterator_constructor` in QuickJS.
    static func iteratorConstructor(ctx: JeffJSContext, newTarget: JeffJSValue,
                                     this: JeffJSValue,
                                     args: [JeffJSValue]) -> JeffJSValue {
        // Per spec, Iterator is an abstract class
        if newTarget.isUndefined {
            return ctx.throwTypeError(message: "Iterator is not a constructor")
        }
        // If called with new via a subclass, return a plain object
        return ctx.newObject()
    }

    // MARK: - Iterator.from(value)

    /// `Iterator.from(value)` -- wraps any iterable or iterator-like into an Iterator.
    ///
    /// If value has a [Symbol.iterator] method, calls it and wraps the result.
    /// If value already has a `.next()` method, wraps it directly.
    ///
    /// Mirrors `js_iterator_from` in QuickJS.
    static func iteratorFrom(ctx: JeffJSContext, this: JeffJSValue,
                              args: [JeffJSValue]) -> JeffJSValue {
        let value = args.isEmpty ? JeffJSValue.undefined : args[0]

        // Step 1: Try to get [Symbol.iterator]
        let symIterAtom = JeffJSAtomID.JS_ATOM_Symbol_iterator.rawValue
        let iterMethod = ctx.getProperty(obj: value, atom: symIterAtom)

        if !iterMethod.isUndefined && !iterMethod.isNull && !iterMethod.isException {
            // Call the iterator method
            guard let iter = callIteratorMethod(ctx: ctx, method: iterMethod, obj: value) else {
                return .exception
            }
            // If iter already has Iterator.prototype in its chain, return as-is
            // Otherwise wrap it in a WrapForValidIteratorPrototype
            return wrapIterator(ctx: ctx, iterator: iter)
        }

        // Step 2: Check if value itself has a .next() method (iterator protocol)
        let nextMethod = ctx.getPropertyStr(obj: value, name: "next")
        if !nextMethod.isUndefined && !nextMethod.isNull && !nextMethod.isException {
            return wrapIterator(ctx: ctx, iterator: value)
        }

        return ctx.throwTypeError(message: "Iterator.from: argument is not iterable")
    }

    /// Wrap an iterator object so it has Iterator.prototype helper methods.
    private static func wrapIterator(ctx: JeffJSContext,
                                      iterator: JeffJSValue) -> JeffJSValue {
        // Create a wrapper object that delegates .next/.return/.throw to the
        // underlying iterator but inherits from Iterator.prototype.
        let wrapper = ctx.newObject()
        if wrapper.isException { return .exception }

        // Store the underlying iterator
        ctx.setPropertyStr(obj: wrapper, name: "__underlying", value: iterator.dupValue())

        // Install a .next() that delegates
        let nextFn = ctx.newCFunction({ ctx, this, args in
            let underlying = ctx.getPropertyStr(obj: this, name: "__underlying")
            if underlying.isUndefined {
                return createIterResult(ctx: ctx, val: .undefined, done: true)
            }
            guard let result = iteratorNext(ctx: ctx, iterator: underlying,
                                             value: args.isEmpty ? .undefined : args[0]) else {
                return .exception
            }
            return result
        }, name: "next", length: 1)
        ctx.setPropertyStr(obj: wrapper, name: "next", value: nextFn)

        // Install a .return() that delegates
        let returnFn = ctx.newCFunction({ ctx, this, args in
            let underlying = ctx.getPropertyStr(obj: this, name: "__underlying")
            if underlying.isUndefined || underlying.isNull {
                let val = args.isEmpty ? JeffJSValue.undefined : args[0]
                return createIterResult(ctx: ctx, val: val, done: true)
            }
            let returnMethod = ctx.getPropertyStr(obj: underlying, name: "return")
            if returnMethod.isUndefined || returnMethod.isNull {
                let val = args.isEmpty ? JeffJSValue.undefined : args[0]
                return createIterResult(ctx: ctx, val: val, done: true)
            }
            guard let retObj = returnMethod.toObject(), let cFunc = retObj.cFunction else {
                return ctx.throwTypeError(message: "iterator.return is not callable")
            }
            return cFunc(ctx, underlying, args)
        }, name: "return", length: 1)
        ctx.setPropertyStr(obj: wrapper, name: "return", value: returnFn)

        // Install [Symbol.iterator] returning this
        let selfIterFn = ctx.newCFunction({ ctx, this, args in
            return this.dupValue()
        }, name: "[Symbol.iterator]", length: 0)
        let symAtom = JeffJSAtomID.JS_ATOM_Symbol_iterator.rawValue
        ctx.setProperty(obj: wrapper, atom: symAtom, value: selfIterFn)

        return wrapper
    }

    // MARK: - Iterator.prototype.map(mapperFn)

    /// `Iterator.prototype.map(mapperFn)` -- lazy map.
    ///
    /// Returns a new iterator that yields mapperFn(value, counter) for each
    /// value from the underlying iterator.
    ///
    /// Mirrors `js_iterator_proto_map` in QuickJS.
    static func iteratorMap(ctx: JeffJSContext, this: JeffJSValue,
                             args: [JeffJSValue]) -> JeffJSValue {
        let mapper = args.isEmpty ? JeffJSValue.undefined : args[0]
        if !mapper.isObject {
            return ctx.throwTypeError(message: "Iterator.prototype.map: callback is not a function")
        }

        var counter: Int64 = 0
        let underlying = this

        let wrapper = ctx.newObject()
        if wrapper.isException { return .exception }

        // Store state on the wrapper via closures
        ctx.setPropertyStr(obj: wrapper, name: "__underlying", value: underlying.dupValue())
        ctx.setPropertyStr(obj: wrapper, name: "__mapper", value: mapper.dupValue())
        ctx.setPropertyStr(obj: wrapper, name: "__counter", value: .newInt32(0))
        ctx.setPropertyStr(obj: wrapper, name: "__done", value: .JS_FALSE)

        let nextFn = ctx.newCFunction({ ctx, this, args in
            let doneVal = ctx.getPropertyStr(obj: this, name: "__done")
            if ctx.toBool(doneVal) {
                return createIterResult(ctx: ctx, val: .undefined, done: true)
            }

            let underlying = ctx.getPropertyStr(obj: this, name: "__underlying")
            let mapper = ctx.getPropertyStr(obj: this, name: "__mapper")
            let counterVal = ctx.getPropertyStr(obj: this, name: "__counter")
            let currentCounter = counterVal.isInt ? Int64(counterVal.toInt32()) : 0

            guard let iterResult = iteratorNext(ctx: ctx, iterator: underlying) else {
                ctx.setPropertyStr(obj: this, name: "__done", value: .JS_TRUE)
                return .exception
            }

            if iterResultDone(ctx: ctx, iterResult: iterResult) {
                ctx.setPropertyStr(obj: this, name: "__done", value: .JS_TRUE)
                return createIterResult(ctx: ctx, val: .undefined, done: true)
            }

            let value = iterResultValue(ctx: ctx, iterResult: iterResult)

            // Call mapper(value, counter)
            guard let mapperObj = mapper.toObject(), let cFunc = mapperObj.cFunction else {
                iteratorClose(ctx: ctx, iterator: underlying)
                ctx.setPropertyStr(obj: this, name: "__done", value: .JS_TRUE)
                return ctx.throwTypeError(message: "Iterator.prototype.map: mapper is not callable")
            }

            let mapped = cFunc(ctx, .undefined, [value, .newInt64(currentCounter)])
            if mapped.isException {
                iteratorClose(ctx: ctx, iterator: underlying)
                ctx.setPropertyStr(obj: this, name: "__done", value: .JS_TRUE)
                return .exception
            }

            ctx.setPropertyStr(obj: this, name: "__counter",
                               value: .newInt64(currentCounter + 1))

            return createIterResult(ctx: ctx, val: mapped, done: false)
        }, name: "next", length: 0)
        ctx.setPropertyStr(obj: wrapper, name: "next", value: nextFn)

        installIteratorReturn(ctx: ctx, wrapper: wrapper)
        installSymbolIterator(ctx: ctx, wrapper: wrapper)

        return wrapper
    }

    // MARK: - Iterator.prototype.filter(predicate)

    /// `Iterator.prototype.filter(predicate)` -- lazy filter.
    ///
    /// Returns a new iterator that yields only values where predicate(value, counter)
    /// is truthy.
    ///
    /// Mirrors `js_iterator_proto_filter` in QuickJS.
    static func iteratorFilter(ctx: JeffJSContext, this: JeffJSValue,
                                args: [JeffJSValue]) -> JeffJSValue {
        let predicate = args.isEmpty ? JeffJSValue.undefined : args[0]
        if !predicate.isObject {
            return ctx.throwTypeError(message: "Iterator.prototype.filter: callback is not a function")
        }

        let wrapper = ctx.newObject()
        if wrapper.isException { return .exception }

        ctx.setPropertyStr(obj: wrapper, name: "__underlying", value: this.dupValue())
        ctx.setPropertyStr(obj: wrapper, name: "__predicate", value: predicate.dupValue())
        ctx.setPropertyStr(obj: wrapper, name: "__counter", value: .newInt32(0))
        ctx.setPropertyStr(obj: wrapper, name: "__done", value: .JS_FALSE)

        let nextFn = ctx.newCFunction({ ctx, this, args in
            let doneVal = ctx.getPropertyStr(obj: this, name: "__done")
            if ctx.toBool(doneVal) {
                return createIterResult(ctx: ctx, val: .undefined, done: true)
            }

            let underlying = ctx.getPropertyStr(obj: this, name: "__underlying")
            let predicate = ctx.getPropertyStr(obj: this, name: "__predicate")
            var counterVal = ctx.getPropertyStr(obj: this, name: "__counter")
            var currentCounter = counterVal.isInt ? Int64(counterVal.toInt32()) : 0

            guard let predObj = predicate.toObject(), let cFunc = predObj.cFunction else {
                ctx.setPropertyStr(obj: this, name: "__done", value: .JS_TRUE)
                return ctx.throwTypeError(message: "filter predicate is not callable")
            }

            // Keep calling next until we find a matching element or exhaust the iterator
            while true {
                guard let iterResult = iteratorNext(ctx: ctx, iterator: underlying) else {
                    ctx.setPropertyStr(obj: this, name: "__done", value: .JS_TRUE)
                    return .exception
                }

                if iterResultDone(ctx: ctx, iterResult: iterResult) {
                    ctx.setPropertyStr(obj: this, name: "__done", value: .JS_TRUE)
                    return createIterResult(ctx: ctx, val: .undefined, done: true)
                }

                let value = iterResultValue(ctx: ctx, iterResult: iterResult)
                let selected = cFunc(ctx, .undefined, [value, .newInt64(currentCounter)])
                currentCounter += 1

                if selected.isException {
                    iteratorClose(ctx: ctx, iterator: underlying)
                    ctx.setPropertyStr(obj: this, name: "__done", value: .JS_TRUE)
                    return .exception
                }

                if ctx.toBool(selected) {
                    ctx.setPropertyStr(obj: this, name: "__counter",
                                       value: .newInt64(currentCounter))
                    return createIterResult(ctx: ctx, val: value, done: false)
                }
            }
        }, name: "next", length: 0)
        ctx.setPropertyStr(obj: wrapper, name: "next", value: nextFn)

        installIteratorReturn(ctx: ctx, wrapper: wrapper)
        installSymbolIterator(ctx: ctx, wrapper: wrapper)

        return wrapper
    }

    // MARK: - Iterator.prototype.take(limit)

    /// `Iterator.prototype.take(limit)` -- lazy take.
    ///
    /// Returns a new iterator that yields at most `limit` values.
    ///
    /// Mirrors `js_iterator_proto_take` in QuickJS.
    static func iteratorTake(ctx: JeffJSContext, this: JeffJSValue,
                              args: [JeffJSValue]) -> JeffJSValue {
        let limitVal = args.isEmpty ? JeffJSValue.undefined : args[0]
        guard let limitNum = ctx.toFloat64(limitVal) else {
            return .exception
        }

        if limitNum.isNaN || limitNum < 0 {
            return ctx.throwRangeError(message: "Iterator.prototype.take: limit must be a non-negative number")
        }

        let limit = limitNum.isInfinite ? Int64.max : Int64(limitNum)

        let wrapper = ctx.newObject()
        if wrapper.isException { return .exception }

        ctx.setPropertyStr(obj: wrapper, name: "__underlying", value: this.dupValue())
        ctx.setPropertyStr(obj: wrapper, name: "__remaining", value: .newInt64(limit))
        ctx.setPropertyStr(obj: wrapper, name: "__done", value: .JS_FALSE)

        let nextFn = ctx.newCFunction({ ctx, this, args in
            let doneVal = ctx.getPropertyStr(obj: this, name: "__done")
            if ctx.toBool(doneVal) {
                return createIterResult(ctx: ctx, val: .undefined, done: true)
            }

            let remainingVal = ctx.getPropertyStr(obj: this, name: "__remaining")
            var remaining: Int64 = 0
            if remainingVal.isInt {
                remaining = Int64(remainingVal.toInt32())
            } else if remainingVal.isFloat64 {
                let d = remainingVal.toFloat64()
                remaining = d.isNaN ? 0 : (d.isInfinite || abs(d) > Double(Int64.max) ? (d > 0 ? Int64.max : 0) : Int64(d))
            }

            if remaining <= 0 {
                let underlying = ctx.getPropertyStr(obj: this, name: "__underlying")
                iteratorClose(ctx: ctx, iterator: underlying)
                ctx.setPropertyStr(obj: this, name: "__done", value: .JS_TRUE)
                return createIterResult(ctx: ctx, val: .undefined, done: true)
            }

            let underlying = ctx.getPropertyStr(obj: this, name: "__underlying")
            guard let iterResult = iteratorNext(ctx: ctx, iterator: underlying) else {
                ctx.setPropertyStr(obj: this, name: "__done", value: .JS_TRUE)
                return .exception
            }

            if iterResultDone(ctx: ctx, iterResult: iterResult) {
                ctx.setPropertyStr(obj: this, name: "__done", value: .JS_TRUE)
                return createIterResult(ctx: ctx, val: .undefined, done: true)
            }

            ctx.setPropertyStr(obj: this, name: "__remaining",
                               value: .newInt64(remaining - 1))

            return iterResult
        }, name: "next", length: 0)
        ctx.setPropertyStr(obj: wrapper, name: "next", value: nextFn)

        installIteratorReturn(ctx: ctx, wrapper: wrapper)
        installSymbolIterator(ctx: ctx, wrapper: wrapper)

        return wrapper
    }

    // MARK: - Iterator.prototype.drop(limit)

    /// `Iterator.prototype.drop(limit)` -- lazy drop.
    ///
    /// Returns a new iterator that skips the first `limit` values, then yields
    /// the rest.
    ///
    /// Mirrors `js_iterator_proto_drop` in QuickJS.
    static func iteratorDrop(ctx: JeffJSContext, this: JeffJSValue,
                              args: [JeffJSValue]) -> JeffJSValue {
        let limitVal = args.isEmpty ? JeffJSValue.undefined : args[0]
        guard let limitNum = ctx.toFloat64(limitVal) else {
            return .exception
        }

        if limitNum.isNaN || limitNum < 0 {
            return ctx.throwRangeError(message: "Iterator.prototype.drop: limit must be a non-negative number")
        }

        let limit = limitNum.isInfinite ? Int64.max : Int64(limitNum)

        let wrapper = ctx.newObject()
        if wrapper.isException { return .exception }

        ctx.setPropertyStr(obj: wrapper, name: "__underlying", value: this.dupValue())
        ctx.setPropertyStr(obj: wrapper, name: "__toDrop", value: .newInt64(limit))
        ctx.setPropertyStr(obj: wrapper, name: "__done", value: .JS_FALSE)

        let nextFn = ctx.newCFunction({ ctx, this, args in
            let doneVal = ctx.getPropertyStr(obj: this, name: "__done")
            if ctx.toBool(doneVal) {
                return createIterResult(ctx: ctx, val: .undefined, done: true)
            }

            let underlying = ctx.getPropertyStr(obj: this, name: "__underlying")
            let toDropVal = ctx.getPropertyStr(obj: this, name: "__toDrop")
            var toDrop: Int64 = 0
            if toDropVal.isInt {
                toDrop = Int64(toDropVal.toInt32())
            } else if toDropVal.isFloat64 {
                let d = toDropVal.toFloat64()
                toDrop = d.isNaN ? 0 : (d.isInfinite || abs(d) > Double(Int64.max) ? (d > 0 ? Int64.max : 0) : Int64(d))
            }

            // Skip elements
            while toDrop > 0 {
                guard let iterResult = iteratorNext(ctx: ctx, iterator: underlying) else {
                    ctx.setPropertyStr(obj: this, name: "__done", value: .JS_TRUE)
                    return .exception
                }
                if iterResultDone(ctx: ctx, iterResult: iterResult) {
                    ctx.setPropertyStr(obj: this, name: "__done", value: .JS_TRUE)
                    return createIterResult(ctx: ctx, val: .undefined, done: true)
                }
                toDrop -= 1
            }
            ctx.setPropertyStr(obj: this, name: "__toDrop", value: .newInt32(0))

            // Now yield the next element
            guard let iterResult = iteratorNext(ctx: ctx, iterator: underlying) else {
                ctx.setPropertyStr(obj: this, name: "__done", value: .JS_TRUE)
                return .exception
            }

            if iterResultDone(ctx: ctx, iterResult: iterResult) {
                ctx.setPropertyStr(obj: this, name: "__done", value: .JS_TRUE)
                return createIterResult(ctx: ctx, val: .undefined, done: true)
            }

            return iterResult
        }, name: "next", length: 0)
        ctx.setPropertyStr(obj: wrapper, name: "next", value: nextFn)

        installIteratorReturn(ctx: ctx, wrapper: wrapper)
        installSymbolIterator(ctx: ctx, wrapper: wrapper)

        return wrapper
    }

    // MARK: - Iterator.prototype.flatMap(mapperFn)

    /// `Iterator.prototype.flatMap(mapperFn)` -- lazy flatMap.
    ///
    /// For each value, calls mapperFn(value, counter) which must return an iterable.
    /// Yields all values from each returned iterable in sequence.
    ///
    /// Mirrors `js_iterator_proto_flatMap` in QuickJS.
    static func iteratorFlatMap(ctx: JeffJSContext, this: JeffJSValue,
                                 args: [JeffJSValue]) -> JeffJSValue {
        let mapper = args.isEmpty ? JeffJSValue.undefined : args[0]
        if !mapper.isObject {
            return ctx.throwTypeError(message: "Iterator.prototype.flatMap: callback is not a function")
        }

        let wrapper = ctx.newObject()
        if wrapper.isException { return .exception }

        ctx.setPropertyStr(obj: wrapper, name: "__underlying", value: this.dupValue())
        ctx.setPropertyStr(obj: wrapper, name: "__mapper", value: mapper.dupValue())
        ctx.setPropertyStr(obj: wrapper, name: "__counter", value: .newInt32(0))
        ctx.setPropertyStr(obj: wrapper, name: "__done", value: .JS_FALSE)
        ctx.setPropertyStr(obj: wrapper, name: "__innerIter", value: .undefined)
        ctx.setPropertyStr(obj: wrapper, name: "__innerActive", value: .JS_FALSE)

        let nextFn = ctx.newCFunction({ ctx, this, args in
            let doneVal = ctx.getPropertyStr(obj: this, name: "__done")
            if ctx.toBool(doneVal) {
                return createIterResult(ctx: ctx, val: .undefined, done: true)
            }

            let underlying = ctx.getPropertyStr(obj: this, name: "__underlying")
            let mapper = ctx.getPropertyStr(obj: this, name: "__mapper")
            var counterVal = ctx.getPropertyStr(obj: this, name: "__counter")
            var currentCounter = counterVal.isInt ? Int64(counterVal.toInt32()) : 0

            guard let mapperObj = mapper.toObject(), let mapFn = mapperObj.cFunction else {
                ctx.setPropertyStr(obj: this, name: "__done", value: .JS_TRUE)
                return ctx.throwTypeError(message: "flatMap mapper is not callable")
            }

            while true {
                // If we have an active inner iterator, try to get next from it
                let innerActive = ctx.toBool(ctx.getPropertyStr(obj: this, name: "__innerActive"))
                if innerActive {
                    let innerIter = ctx.getPropertyStr(obj: this, name: "__innerIter")
                    if let innerResult = iteratorNext(ctx: ctx, iterator: innerIter) {
                        if !iterResultDone(ctx: ctx, iterResult: innerResult) {
                            return innerResult
                        }
                    }
                    // Inner iterator exhausted
                    ctx.setPropertyStr(obj: this, name: "__innerActive", value: .JS_FALSE)
                    ctx.setPropertyStr(obj: this, name: "__innerIter", value: .undefined)
                }

                // Get next from outer iterator
                guard let outerResult = iteratorNext(ctx: ctx, iterator: underlying) else {
                    ctx.setPropertyStr(obj: this, name: "__done", value: .JS_TRUE)
                    return .exception
                }

                if iterResultDone(ctx: ctx, iterResult: outerResult) {
                    ctx.setPropertyStr(obj: this, name: "__done", value: .JS_TRUE)
                    return createIterResult(ctx: ctx, val: .undefined, done: true)
                }

                let value = iterResultValue(ctx: ctx, iterResult: outerResult)

                // Call mapper(value, counter)
                let mapped = mapFn(ctx, .undefined, [value, .newInt64(currentCounter)])
                currentCounter += 1
                ctx.setPropertyStr(obj: this, name: "__counter",
                                   value: .newInt64(currentCounter))

                if mapped.isException {
                    iteratorClose(ctx: ctx, iterator: underlying)
                    ctx.setPropertyStr(obj: this, name: "__done", value: .JS_TRUE)
                    return .exception
                }

                // Get an iterator from the mapped value
                guard let innerIter = getIterator(ctx: ctx, obj: mapped) else {
                    iteratorClose(ctx: ctx, iterator: underlying)
                    ctx.setPropertyStr(obj: this, name: "__done", value: .JS_TRUE)
                    return .exception
                }

                ctx.setPropertyStr(obj: this, name: "__innerIter", value: innerIter.dupValue())
                ctx.setPropertyStr(obj: this, name: "__innerActive", value: .JS_TRUE)
                // Loop back to try getting from inner iterator
            }
        }, name: "next", length: 0)
        ctx.setPropertyStr(obj: wrapper, name: "next", value: nextFn)

        installIteratorReturn(ctx: ctx, wrapper: wrapper)
        installSymbolIterator(ctx: ctx, wrapper: wrapper)

        return wrapper
    }

    // MARK: - Iterator.prototype.reduce(reducer [, initialValue])

    /// `Iterator.prototype.reduce(reducer [, initialValue])` -- eager reduce.
    ///
    /// Consumes the entire iterator, reducing to a single value.
    /// If no initialValue is provided, uses the first yielded value.
    ///
    /// Mirrors `js_iterator_proto_reduce` in QuickJS.
    static func iteratorReduce(ctx: JeffJSContext, this: JeffJSValue,
                                args: [JeffJSValue]) -> JeffJSValue {
        let reducer = args.isEmpty ? JeffJSValue.undefined : args[0]
        if !reducer.isObject {
            return ctx.throwTypeError(message: "Iterator.prototype.reduce: callback is not a function")
        }

        guard let reducerObj = reducer.toObject(), let reduceFn = reducerObj.cFunction else {
            return ctx.throwTypeError(message: "Iterator.prototype.reduce: callback is not callable")
        }

        var accumulator: JeffJSValue
        var counter: Int64 = 0
        let hasInitialValue = args.count >= 2

        if hasInitialValue {
            accumulator = args[1]
        } else {
            // Use first element as initial value
            guard let first = iteratorNext(ctx: ctx, iterator: this) else {
                return .exception
            }
            if iterResultDone(ctx: ctx, iterResult: first) {
                return ctx.throwTypeError(message: "Iterator.prototype.reduce: reduce of empty iterator with no initial value")
            }
            accumulator = iterResultValue(ctx: ctx, iterResult: first)
            counter = 1
        }

        // Consume the rest
        while true {
            guard let iterResult = iteratorNext(ctx: ctx, iterator: this) else {
                return .exception
            }
            if iterResultDone(ctx: ctx, iterResult: iterResult) {
                break
            }

            let value = iterResultValue(ctx: ctx, iterResult: iterResult)
            let result = reduceFn(ctx, .undefined, [accumulator, value, .newInt64(counter)])
            if result.isException {
                iteratorClose(ctx: ctx, iterator: this)
                return .exception
            }
            accumulator = result
            counter += 1
        }

        return accumulator
    }

    // MARK: - Iterator.prototype.toArray()

    /// `Iterator.prototype.toArray()` -- eagerly collects all values into an array.
    ///
    /// Mirrors `js_iterator_proto_toArray` in QuickJS.
    static func iteratorToArray(ctx: JeffJSContext, this: JeffJSValue,
                                 args: [JeffJSValue]) -> JeffJSValue {
        return iteratorToArrayInternal(ctx: ctx, iterator: this)
    }

    /// Internal helper: consume an iterator and collect results into a JS array.
    ///
    /// Mirrors `js_iterator_to_array` in QuickJS.
    static func iteratorToArrayInternal(ctx: JeffJSContext,
                                         iterator: JeffJSValue) -> JeffJSValue {
        let arr = ctx.newArray()
        if arr.isException { return .exception }

        var index: UInt32 = 0

        while true {
            guard let iterResult = iteratorNext(ctx: ctx, iterator: iterator) else {
                return .exception
            }
            if iterResultDone(ctx: ctx, iterResult: iterResult) {
                break
            }

            let value = iterResultValue(ctx: ctx, iterResult: iterResult)
            ctx.setPropertyUint32(obj: arr, index: index, value: value.dupValue())
            index += 1
        }

        // Set array length
        ctx.setPropertyStr(obj: arr, name: "length", value: .newUInt32(index))

        return arr
    }

    // MARK: - Iterator.prototype.forEach(fn)

    /// `Iterator.prototype.forEach(fn)` -- eagerly calls fn(value, counter) for each value.
    ///
    /// Returns undefined. Consumes the entire iterator.
    ///
    /// Mirrors `js_iterator_proto_forEach` in QuickJS.
    static func iteratorForEach(ctx: JeffJSContext, this: JeffJSValue,
                                 args: [JeffJSValue]) -> JeffJSValue {
        let fn = args.isEmpty ? JeffJSValue.undefined : args[0]
        if !fn.isObject {
            return ctx.throwTypeError(message: "Iterator.prototype.forEach: callback is not a function")
        }

        guard let fnObj = fn.toObject(), let cFunc = fnObj.cFunction else {
            return ctx.throwTypeError(message: "Iterator.prototype.forEach: callback is not callable")
        }

        var counter: Int64 = 0
        while true {
            guard let iterResult = iteratorNext(ctx: ctx, iterator: this) else {
                return .exception
            }
            if iterResultDone(ctx: ctx, iterResult: iterResult) {
                break
            }

            let value = iterResultValue(ctx: ctx, iterResult: iterResult)
            let result = cFunc(ctx, .undefined, [value, .newInt64(counter)])
            if result.isException {
                iteratorClose(ctx: ctx, iterator: this)
                return .exception
            }
            counter += 1
        }

        return .undefined
    }

    // MARK: - Iterator.prototype.some(predicate)

    /// `Iterator.prototype.some(predicate)` -- eagerly tests if any value matches.
    ///
    /// Returns true if predicate(value, counter) is truthy for at least one value.
    /// Short-circuits on the first truthy result. Consumes the iterator.
    ///
    /// Mirrors `js_iterator_proto_some` in QuickJS.
    static func iteratorSome(ctx: JeffJSContext, this: JeffJSValue,
                              args: [JeffJSValue]) -> JeffJSValue {
        let predicate = args.isEmpty ? JeffJSValue.undefined : args[0]
        if !predicate.isObject {
            return ctx.throwTypeError(message: "Iterator.prototype.some: callback is not a function")
        }

        guard let predObj = predicate.toObject(), let cFunc = predObj.cFunction else {
            return ctx.throwTypeError(message: "Iterator.prototype.some: callback is not callable")
        }

        var counter: Int64 = 0
        while true {
            guard let iterResult = iteratorNext(ctx: ctx, iterator: this) else {
                return .exception
            }
            if iterResultDone(ctx: ctx, iterResult: iterResult) {
                return .JS_FALSE
            }

            let value = iterResultValue(ctx: ctx, iterResult: iterResult)
            let result = cFunc(ctx, .undefined, [value, .newInt64(counter)])
            if result.isException {
                iteratorClose(ctx: ctx, iterator: this)
                return .exception
            }

            if ctx.toBool(result) {
                iteratorClose(ctx: ctx, iterator: this)
                return .JS_TRUE
            }
            counter += 1
        }
    }

    // MARK: - Iterator.prototype.every(predicate)

    /// `Iterator.prototype.every(predicate)` -- eagerly tests if all values match.
    ///
    /// Returns true if predicate(value, counter) is truthy for every value.
    /// Short-circuits on the first falsy result. Consumes the iterator.
    ///
    /// Mirrors `js_iterator_proto_every` in QuickJS.
    static func iteratorEvery(ctx: JeffJSContext, this: JeffJSValue,
                               args: [JeffJSValue]) -> JeffJSValue {
        let predicate = args.isEmpty ? JeffJSValue.undefined : args[0]
        if !predicate.isObject {
            return ctx.throwTypeError(message: "Iterator.prototype.every: callback is not a function")
        }

        guard let predObj = predicate.toObject(), let cFunc = predObj.cFunction else {
            return ctx.throwTypeError(message: "Iterator.prototype.every: callback is not callable")
        }

        var counter: Int64 = 0
        while true {
            guard let iterResult = iteratorNext(ctx: ctx, iterator: this) else {
                return .exception
            }
            if iterResultDone(ctx: ctx, iterResult: iterResult) {
                return .JS_TRUE
            }

            let value = iterResultValue(ctx: ctx, iterResult: iterResult)
            let result = cFunc(ctx, .undefined, [value, .newInt64(counter)])
            if result.isException {
                iteratorClose(ctx: ctx, iterator: this)
                return .exception
            }

            if !ctx.toBool(result) {
                iteratorClose(ctx: ctx, iterator: this)
                return .JS_FALSE
            }
            counter += 1
        }
    }

    // MARK: - Iterator.prototype.find(predicate)

    /// `Iterator.prototype.find(predicate)` -- eagerly finds the first matching value.
    ///
    /// Returns the first value for which predicate(value, counter) is truthy,
    /// or undefined if none match. Consumes the iterator.
    ///
    /// Mirrors `js_iterator_proto_find` in QuickJS.
    static func iteratorFind(ctx: JeffJSContext, this: JeffJSValue,
                              args: [JeffJSValue]) -> JeffJSValue {
        let predicate = args.isEmpty ? JeffJSValue.undefined : args[0]
        if !predicate.isObject {
            return ctx.throwTypeError(message: "Iterator.prototype.find: callback is not a function")
        }

        guard let predObj = predicate.toObject(), let cFunc = predObj.cFunction else {
            return ctx.throwTypeError(message: "Iterator.prototype.find: callback is not callable")
        }

        var counter: Int64 = 0
        while true {
            guard let iterResult = iteratorNext(ctx: ctx, iterator: this) else {
                return .exception
            }
            if iterResultDone(ctx: ctx, iterResult: iterResult) {
                return .undefined
            }

            let value = iterResultValue(ctx: ctx, iterResult: iterResult)
            let result = cFunc(ctx, .undefined, [value, .newInt64(counter)])
            if result.isException {
                iteratorClose(ctx: ctx, iterator: this)
                return .exception
            }

            if ctx.toBool(result) {
                iteratorClose(ctx: ctx, iterator: this)
                return value
            }
            counter += 1
        }
    }

    // MARK: - Iterator.concat(...iterables)

    /// `Iterator.concat(...iterables)` -- concatenates multiple iterables.
    ///
    /// Returns a new iterator that yields all values from each iterable in sequence.
    /// Each argument must be iterable; a TypeError is thrown otherwise.
    ///
    /// This is a static method on Iterator, not a prototype method (ES2025).
    ///
    /// Mirrors the Iterator.concat proposal.
    static func iteratorConcat(ctx: JeffJSContext, this: JeffJSValue,
                                args: [JeffJSValue]) -> JeffJSValue {
        // Validate all arguments are iterable before creating the iterator
        let symIterAtom = JeffJSAtomID.JS_ATOM_Symbol_iterator.rawValue
        for (i, arg) in args.enumerated() {
            let method = ctx.getProperty(obj: arg, atom: symIterAtom)
            if method.isUndefined || method.isNull {
                return ctx.throwTypeError(message: "Iterator.concat: argument \(i) is not iterable")
            }
        }

        let wrapper = ctx.newObject()
        if wrapper.isException { return .exception }

        // Store the iterables as an array
        let iterablesArr = ctx.newArray()
        for (i, arg) in args.enumerated() {
            ctx.setPropertyUint32(obj: iterablesArr, index: UInt32(i), value: arg.dupValue())
        }
        ctx.setPropertyStr(obj: iterablesArr, name: "length",
                           value: .newInt32(Int32(args.count)))

        ctx.setPropertyStr(obj: wrapper, name: "__iterables", value: iterablesArr)
        ctx.setPropertyStr(obj: wrapper, name: "__outerIndex", value: .newInt32(0))
        ctx.setPropertyStr(obj: wrapper, name: "__innerIter", value: .undefined)
        ctx.setPropertyStr(obj: wrapper, name: "__done", value: .JS_FALSE)
        ctx.setPropertyStr(obj: wrapper, name: "__count", value: .newInt32(Int32(args.count)))

        let nextFn = ctx.newCFunction({ ctx, this, args in
            let doneVal = ctx.getPropertyStr(obj: this, name: "__done")
            if ctx.toBool(doneVal) {
                return createIterResult(ctx: ctx, val: .undefined, done: true)
            }

            let iterables = ctx.getPropertyStr(obj: this, name: "__iterables")
            let countVal = ctx.getPropertyStr(obj: this, name: "__count")
            let count = countVal.isInt ? Int(countVal.toInt32()) : 0

            while true {
                // Try to get from current inner iterator
                let innerIter = ctx.getPropertyStr(obj: this, name: "__innerIter")
                if !innerIter.isUndefined && !innerIter.isNull {
                    if let iterResult = iteratorNext(ctx: ctx, iterator: innerIter) {
                        if !iterResultDone(ctx: ctx, iterResult: iterResult) {
                            return iterResult
                        }
                    }
                    // Inner exhausted, move to next
                    ctx.setPropertyStr(obj: this, name: "__innerIter", value: .undefined)
                }

                // Get next iterable
                let outerIndexVal = ctx.getPropertyStr(obj: this, name: "__outerIndex")
                let outerIndex = outerIndexVal.isInt ? Int(outerIndexVal.toInt32()) : 0

                if outerIndex >= count {
                    ctx.setPropertyStr(obj: this, name: "__done", value: .JS_TRUE)
                    return createIterResult(ctx: ctx, val: .undefined, done: true)
                }

                let nextIterable = ctx.getPropertyUint32(obj: iterables, index: UInt32(outerIndex))
                ctx.setPropertyStr(obj: this, name: "__outerIndex",
                                   value: .newInt32(Int32(outerIndex + 1)))

                // Get iterator from the iterable
                guard let newInner = getIterator(ctx: ctx, obj: nextIterable) else {
                    ctx.setPropertyStr(obj: this, name: "__done", value: .JS_TRUE)
                    return .exception
                }

                ctx.setPropertyStr(obj: this, name: "__innerIter", value: newInner.dupValue())
                // Loop back to try getting from the new inner iterator
            }
        }, name: "next", length: 0)
        ctx.setPropertyStr(obj: wrapper, name: "next", value: nextFn)

        installIteratorReturn(ctx: ctx, wrapper: wrapper)
        installSymbolIterator(ctx: ctx, wrapper: wrapper)

        return wrapper
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
    private static func asyncGeneratorEnqueue(ctx: JeffJSContext, this: JeffJSValue,
                                               args: [JeffJSValue],
                                               completionType: Int) -> JeffJSValue {
        guard let obj = this.toObject() else {
            return ctx.throwTypeError(message: "async generator method called on non-object")
        }

        guard case .generatorData(let genData) = obj.payload else {
            return ctx.throwTypeError(message: "not an async generator object")
        }

        let value = args.isEmpty ? JeffJSValue.undefined : args[0]

        // Create the promise that will be returned to the caller
        let promise = ctx.newObjectClass(classID: JSClassID.JS_CLASS_PROMISE.rawValue)
        if promise.isException { return .exception }

        // Create resolve and reject functions for the promise
        let resolveFunc = ctx.newCFunction({ ctx, this, args in
            return .undefined
        }, name: "resolve", length: 1)

        let rejectFunc = ctx.newCFunction({ ctx, this, args in
            return .undefined
        }, name: "reject", length: 1)

        // Process the request based on the generator's current state
        switch genData.state {
        case .completed:
            // Generator is done
            if completionType == 2 {
                // throw: reject the promise
                // In a full engine, we'd call reject(value)
                return promise
            }
            // next or return: resolve with { value, done: true }
            // In a full engine, we'd call resolve({value: (type==1 ? value : undefined), done: true})
            return promise

        case .executing:
            // Queue the request for later processing.
            // In a full engine, this would be added to the async generator's
            // request queue and processed when the current execution completes.
            return promise

        case .suspended_start:
            if completionType == 1 {
                // return: complete the generator
                genData.state = .completed
                return promise
            }
            if completionType == 2 {
                // throw: complete the generator and reject
                genData.state = .completed
                return promise
            }
            // next: start execution
            genData.state = .executing

            // In a full engine, this would begin executing the generator's
            // bytecode body. When it hits a yield or return, the generator
            // would resolve the promise and transition to the appropriate state.
            genData.state = .completed
            return promise

        case .suspended_yield, .suspended_yield_star:
            genData.state = .executing

            // In a full engine, this would resume the generator at the yield
            // point with the appropriate completion type (normal, return, or
            // throw). The async state machine handles the promise resolution.
            //
            // The bytecode interpreter would:
            // 1. Resume execution at the saved PC
            // 2. Pass `value` as the result of the await/yield expression
            // 3. On the next yield/return/throw, resolve/reject the promise
            // 4. Transition the state accordingly

            genData.state = .completed
            return promise
        }
    }

    // MARK: - Private Helpers

    /// Install a .return() method that delegates to the underlying iterator's .return().
    private static func installIteratorReturn(ctx: JeffJSContext, wrapper: JeffJSValue) {
        let returnFn = ctx.newCFunction({ ctx, this, args in
            let underlying = ctx.getPropertyStr(obj: this, name: "__underlying")
            ctx.setPropertyStr(obj: this, name: "__done", value: .JS_TRUE)

            if underlying.isUndefined || underlying.isNull {
                let val = args.isEmpty ? JeffJSValue.undefined : args[0]
                return createIterResult(ctx: ctx, val: val, done: true)
            }

            // Try to call underlying.return()
            let returnMethod = ctx.getPropertyStr(obj: underlying, name: "return")
            if returnMethod.isUndefined || returnMethod.isNull {
                let val = args.isEmpty ? JeffJSValue.undefined : args[0]
                return createIterResult(ctx: ctx, val: val, done: true)
            }

            if let retObj = returnMethod.toObject(), let cFunc = retObj.cFunction {
                return cFunc(ctx, underlying, args)
            }

            let val = args.isEmpty ? JeffJSValue.undefined : args[0]
            return createIterResult(ctx: ctx, val: val, done: true)
        }, name: "return", length: 1)
        ctx.setPropertyStr(obj: wrapper, name: "return", value: returnFn)
    }

    /// Install [Symbol.iterator] that returns `this` on a wrapper object.
    private static func installSymbolIterator(ctx: JeffJSContext, wrapper: JeffJSValue) {
        let selfIterFn = ctx.newCFunction({ ctx, this, args in
            return this.dupValue()
        }, name: "[Symbol.iterator]", length: 0)
        let symAtom = JeffJSAtomID.JS_ATOM_Symbol_iterator.rawValue
        ctx.setProperty(obj: wrapper, atom: symAtom, value: selfIterFn)
    }
}
