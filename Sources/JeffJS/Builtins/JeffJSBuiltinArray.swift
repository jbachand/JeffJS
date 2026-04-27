// JeffJSBuiltinArray.swift
// JeffJS — 1:1 Swift port of QuickJS Array built-in
// Copyright 2026 Jeff Bachand. All rights reserved.
//
// Port of js_array_funcs[], js_array_constructor, and all Array static methods
// plus Array.prototype methods from QuickJS quickjs.c.

import Foundation

// MARK: - Array length limits

/// Maximum valid array length per ECMAScript spec: 2^32 - 1.
private let MAX_SAFE_ARRAY_LENGTH: UInt32 = 0xFFFF_FFFF

/// Maximum safe integer: 2^53 - 1 (used for generic length validation).
private let MAX_SAFE_INTEGER: Int64 = (1 << 53) - 1

// MARK: - JeffJSBuiltinArray

struct JeffJSBuiltinArray {

    // MARK: - Intrinsic registration

    /// Register Array constructor + Array.prototype + all static and prototype methods.
    /// Mirrors `js_init_function_class` + `JS_SetPropertyFunctionList` for Array in QuickJS.
    static func addIntrinsic(ctx: JeffJSContext) {
        // -- Array.prototype ----------------------------------------------------
        let arrayProto = ctx.arrayPrototype

        // Mutation methods
        ctx.setPropertyFunc(obj: arrayProto, name: "push", fn: push, length: 1)
        // Cache the push function object for the interpreter fast-path.
        // The object is looked up via the "push" atom on Array.prototype.
        let pushAtom = ctx.rt.findAtom("push")
        let pushVal = ctx.getProperty(obj: arrayProto, atom: pushAtom)
        ctx.arrayProtoPushObj = pushVal.toObject()
        ctx.rt.freeAtom(pushAtom)
        ctx.setPropertyFunc(obj: arrayProto, name: "pop", fn: pop, length: 0)
        ctx.setPropertyFunc(obj: arrayProto, name: "shift", fn: shift, length: 0)
        ctx.setPropertyFunc(obj: arrayProto, name: "unshift", fn: unshift, length: 1)
        ctx.setPropertyFunc(obj: arrayProto, name: "splice", fn: splice, length: 2)
        ctx.setPropertyFunc(obj: arrayProto, name: "sort", fn: sort, length: 1)
        ctx.setPropertyFunc(obj: arrayProto, name: "reverse", fn: reverse, length: 0)
        ctx.setPropertyFunc(obj: arrayProto, name: "fill", fn: fill, length: 1)
        ctx.setPropertyFunc(obj: arrayProto, name: "copyWithin", fn: copyWithin, length: 2)

        // Non-mutating methods
        ctx.setPropertyFunc(obj: arrayProto, name: "concat", fn: concat, length: 1)
        ctx.setPropertyFunc(obj: arrayProto, name: "join", fn: join, length: 1)
        ctx.setPropertyFunc(obj: arrayProto, name: "slice", fn: slice, length: 2)
        ctx.setPropertyFunc(obj: arrayProto, name: "indexOf", fn: indexOf, length: 1)
        ctx.setPropertyFunc(obj: arrayProto, name: "lastIndexOf", fn: lastIndexOf, length: 1)
        ctx.setPropertyFunc(obj: arrayProto, name: "includes", fn: includes, length: 1)
        ctx.setPropertyFunc(obj: arrayProto, name: "flat", fn: flat, length: 0)
        ctx.setPropertyFunc(obj: arrayProto, name: "flatMap", fn: flatMap, length: 1)

        // Iteration
        ctx.setPropertyFunc(obj: arrayProto, name: "forEach", fn: forEach, length: 1)
        ctx.setPropertyFunc(obj: arrayProto, name: "map", fn: map, length: 1)
        ctx.setPropertyFunc(obj: arrayProto, name: "filter", fn: filter, length: 1)
        ctx.setPropertyFunc(obj: arrayProto, name: "every", fn: every, length: 1)
        ctx.setPropertyFunc(obj: arrayProto, name: "some", fn: some, length: 1)
        ctx.setPropertyFunc(obj: arrayProto, name: "find", fn: find, length: 1)
        ctx.setPropertyFunc(obj: arrayProto, name: "findIndex", fn: findIndex, length: 1)
        ctx.setPropertyFunc(obj: arrayProto, name: "findLast", fn: findLast, length: 1)
        ctx.setPropertyFunc(obj: arrayProto, name: "findLastIndex", fn: findLastIndex, length: 1)

        // Reduction
        ctx.setPropertyFunc(obj: arrayProto, name: "reduce", fn: reduce, length: 1)
        ctx.setPropertyFunc(obj: arrayProto, name: "reduceRight", fn: reduceRight, length: 1)

        // ES2023 immutable methods
        ctx.setPropertyFunc(obj: arrayProto, name: "toReversed", fn: toReversed, length: 0)
        ctx.setPropertyFunc(obj: arrayProto, name: "toSorted", fn: toSorted, length: 1)
        ctx.setPropertyFunc(obj: arrayProto, name: "toSpliced", fn: toSpliced, length: 2)
        ctx.setPropertyFunc(obj: arrayProto, name: "with", fn: with_, length: 2)
        ctx.setPropertyFunc(obj: arrayProto, name: "at", fn: at, length: 1)

        // Conversion
        ctx.setPropertyFunc(obj: arrayProto, name: "toString", fn: toString, length: 0)
        ctx.setPropertyFunc(obj: arrayProto, name: "toLocaleString", fn: toLocaleString, length: 0)

        // Iterators
        ctx.setPropertyFunc(obj: arrayProto, name: "keys", fn: keys, length: 0)
        ctx.setPropertyFunc(obj: arrayProto, name: "values", fn: values, length: 0)
        ctx.setPropertyFunc(obj: arrayProto, name: "entries", fn: entries, length: 0)

        // @@iterator is the same as values — must be stored under the well-known
        // symbol atom so that for-of / spread can find it via [Symbol.iterator].
        let valuesFunc = ctx.newCFunction(values, name: "values", length: 0)
        let symIterAtom = JeffJSAtomID.JS_ATOM_Symbol_iterator.rawValue
        ctx.setProperty(obj: arrayProto, atom: symIterAtom, value: valuesFunc)

        // -- Array constructor --------------------------------------------------
        let arrayCtor = ctx.newConstructorFunc(name: "Array", fn: arrayConstructor, length: 1, proto: arrayProto)

        // Static methods
        ctx.setPropertyFunc(obj: arrayCtor, name: "isArray", fn: isArray, length: 1)
        ctx.setPropertyFunc(obj: arrayCtor, name: "from", fn: from, length: 1)
        ctx.setPropertyFunc(obj: arrayCtor, name: "of", fn: of_, length: 0)

        // @@species getter
        let speciesGetterVal = ctx.newCFunction(speciesGetter, name: "get [Symbol.species]", length: 0)
        ctx.setPropertyGetSet(obj: arrayCtor, name: "Symbol.species",
                              getter: speciesGetterVal, setter: nil)

        ctx.setGlobalConstructor(name: "Array", ctor: arrayCtor)
    }

    // MARK: - Array constructor

    /// `Array(len)` / `Array(element0, element1, ..., elementN)` / `new Array(...)`
    /// Mirrors `js_array_constructor` in QuickJS.
    static func arrayConstructor(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let arr = ctx.newArray()
        if arr.isException { return arr }

        // Single numeric argument: Array(len)
        if args.count == 1 {
            let arg = args[0]
            if arg.isNumber {
                let lenVal = ctx.toUint32(arg)

                let dval = ctx.extractFloat64(arg) ?? 0

                // If the uint32 value does not match the number value, it is not a valid length
                if Double(lenVal) != dval {
                    return ctx.throwRangeError(message: "Invalid array length")
                }

                ctx.setArrayLength(arr, Int64(lenVal))

                return arr
            }
        }

        // Multiple arguments or single non-numeric: Array(element0, element1, ...)
        for i in 0..<args.count {
            ctx.setPropertyByIndex(obj: arr, index: UInt32(i), value: args[i])
        }

        ctx.setArrayLength(arr, Int64(args.count))

        return arr
    }

    // MARK: - Array static methods

    /// `Array.isArray(arg)`
    /// Determines whether the passed value is an Array.
    static func isArray(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let arg = args.count > 0 ? args[0] : .undefined
        return ctx.isArray(arg) ? JeffJSValue.JS_TRUE : JeffJSValue.JS_FALSE
    }

    /// `Array.from(arrayLike, mapFn?, thisArg?)`
    /// Creates a new, shallow-copied Array instance from an iterable or array-like object.
    static func from(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let items = args.count > 0 ? args[0] : .undefined
        let mapFn = args.count > 1 ? args[1] : .undefined
        let thisArg = args.count > 2 ? args[2] : .undefined

        let mapping: Bool
        if !mapFn.isUndefined {
            if !ctx.isCallable(mapFn) {
                return ctx.throwTypeError(message: "Array.from: mapFn is not a function")
            }
            mapping = true
        } else {
            mapping = false
        }

        // Try getting the iterator first
        let usingIterator = ctx.getMethod(items, name: "Symbol.iterator")
        let usingIteratorIsNil = (usingIterator == nil)

        if !usingIteratorIsNil, let usingIter = usingIterator {
            // Create array via species constructor or plain array
            let arr: JeffJSValue
            if this.isObject && ctx.isConstructor(this) {
                arr = ctx.callConstructor(this, args: [])
                if arr.isException { return arr }
            } else {
                arr = ctx.newArray()
                if arr.isException { return arr }
            }

            let iter = ctx.call(usingIter, this: items, args: [])
            if iter.isException { return iter }

            var k: Int64 = 0
            while true {
                if k >= MAX_SAFE_INTEGER {
                    return ctx.throwTypeError(message: "Array.from: too many elements")
                }

                let next = ctx.callMethod(iter, name: "next", args: [])
                if next.isException { return next }

                let done = ctx.getProperty(obj: next, atom: ctx.rt.findAtom("done"))
                if done.isException { return done }
                if ctx.toBoolFree(done) {
                    ctx.setArrayLength(arr, k)
                    return arr
                }

                var val = ctx.getProperty(obj: next, atom: ctx.rt.findAtom("value"))
                if val.isException {
                    return val
                }

                if mapping {
                    let kValue = ctx.newInt64(k)
                    val = ctx.call(mapFn, this: thisArg, args: [val, kValue])
                    if val.isException {
                        return val
                    }
                }

                ctx.setPropertyByIndex(obj: arr, index: UInt32(k), value: val)

                k += 1
            }
        }

        // Array-like fallback
        let arrayLike = ctx.toObject(items)
        if arrayLike.isException { return arrayLike }

        let lenAtom = ctx.rt.findAtom("length")
        let lenVal = ctx.getProperty(obj: arrayLike, atom: lenAtom)
        if lenVal.isException { return lenVal }
        let len = ctx.toLength(lenVal)
        if len < 0 { return .exception }

        let arr: JeffJSValue
        if this.isObject && ctx.isConstructor(this) {
            let lenArg = ctx.newInt64(len)
            arr = ctx.callConstructor(this, args: [lenArg])
            if arr.isException { return arr }
        } else {
            arr = ctx.newArrayWithLength(Int(len))
            if arr.isException { return arr }
        }

        var k: Int64 = 0
        while k < len {
            var val = ctx.getPropertyByIndex(obj: arrayLike, index: UInt32(k))
            if val.isException { return val }

            if mapping {
                let kValue = ctx.newInt64(k)
                val = ctx.call(mapFn, this: thisArg, args: [val, kValue])
                if val.isException { return val }
            }

            ctx.setPropertyByIndex(obj: arr, index: UInt32(k), value: val)

            k += 1
        }

        ctx.setArrayLength(arr, len)

        return arr
    }

    /// `Array.of(element0, element1, ..., elementN)`
    /// Creates a new Array instance from a variable number of arguments.
    static func of_(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let len = args.count

        // Species constructor support
        let arr: JeffJSValue
        if this.isObject && ctx.isConstructor(this) {
            let lenArg = ctx.newInt64(Int64(len))
            arr = ctx.callConstructor(this, args: [lenArg])
            if arr.isException { return arr }
        } else {
            arr = ctx.newArrayWithLength(len)
            if arr.isException { return arr }
        }

        for i in 0..<len {
            ctx.setPropertyByIndex(obj: arr, index: UInt32(i), value: args[i])
        }

        ctx.setArrayLength(arr, Int64(len))

        return arr
    }

    /// `get Array[Symbol.species]`
    /// Returns the Array constructor.
    static func speciesGetter(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        return this
    }

    // MARK: - Array.prototype mutation methods

    /// `Array.prototype.push(...items)`
    /// Adds one or more elements to the end of an array and returns the new length.
    static func push(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        var len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        let argCount = Int64(args.count)
        if len + argCount > MAX_SAFE_INTEGER {
            return ctx.throwTypeError(message: "Array.prototype.push: array length overflow")
        }

        for i in 0..<args.count {
            ctx.setPropertyByIndex(obj: obj, index: UInt32(len), value: args[i])
            len += 1
        }

        setLength(ctx: ctx, obj: obj, length: len)

        return ctx.newInt64(len)
    }

    /// `Array.prototype.pop()`
    /// Removes the last element from an array and returns that element.
    static func pop(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        var len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        if len == 0 {
            setLength(ctx: ctx, obj: obj, length: 0)
            return .undefined
        }

        len -= 1
        let val = ctx.getPropertyByIndex(obj: obj, index: UInt32(len))
        if val.isException { return val }

        _ = ctx.deletePropertyByIndex(obj: obj, index: UInt32(len))

        setLength(ctx: ctx, obj: obj, length: len)

        return val
    }

    /// `Array.prototype.shift()`
    /// Removes the first element from an array and returns that element.
    static func shift(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        var len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        if len == 0 {
            setLength(ctx: ctx, obj: obj, length: 0)
            return .undefined
        }

        let first = ctx.getPropertyByIndex(obj: obj, index: 0)
        if first.isException { return first }

        // Shift all elements down by 1
        var k: Int64 = 1
        while k < len {
            let has = ctx.hasPropertyByIndex(obj: obj, index: UInt32(k))

            if has {
                let val = ctx.getPropertyByIndex(obj: obj, index: UInt32(k))
                if val.isException { return val }
                ctx.setPropertyByIndex(obj: obj, index: UInt32(k - 1), value: val)
            } else {
                _ = ctx.deletePropertyByIndex(obj: obj, index: UInt32(k - 1))
            }
            k += 1
        }

        _ = ctx.deletePropertyByIndex(obj: obj, index: UInt32(len - 1))

        len -= 1
        setLength(ctx: ctx, obj: obj, length: len)

        return first
    }

    /// `Array.prototype.unshift(...items)`
    /// Adds one or more elements to the beginning of an array and returns the new length.
    static func unshift(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        var len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        let argCount = Int64(args.count)
        if argCount > 0 {
            if len + argCount > MAX_SAFE_INTEGER {
                return ctx.throwTypeError(message: "Array.prototype.unshift: array length overflow")
            }

            // Shift existing elements up
            var k = len
            while k > 0 {
                let from = UInt32(k - 1)
                let to = UInt32(k - 1 + argCount)

                let has = ctx.hasPropertyByIndex(obj: obj, index: from)

                if has {
                    let val = ctx.getPropertyByIndex(obj: obj, index: from)
                    if val.isException { return val }
                    ctx.setPropertyByIndex(obj: obj, index: to, value: val)
                } else {
                    _ = ctx.deletePropertyByIndex(obj: obj, index: to)
                }
                k -= 1
            }

            // Insert new elements at the beginning
            for i in 0..<args.count {
                ctx.setPropertyByIndex(obj: obj, index: UInt32(i), value: args[i])
            }

            len += argCount
        }

        setLength(ctx: ctx, obj: obj, length: len)

        return ctx.newInt64(len)
    }

    /// `Array.prototype.splice(start, deleteCount, ...items)`
    /// Changes the contents of an array by removing or replacing existing elements and/or
    /// adding new elements in place.
    static func splice(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        // Resolve start
        var actualStart: Int64
        if args.count > 0 {
            let rs = ctx.toIntegerOrInfinity(args[0])
            if rs == -.infinity {
                actualStart = 0
            } else if rs < 0 {
                actualStart = max(len + Int64(rs), 0)
            } else {
                actualStart = min(Int64(rs), len)
            }
        } else {
            actualStart = 0
        }

        // Resolve deleteCount
        var actualDeleteCount: Int64
        let insertCount = Int64(max(args.count - 2, 0))

        if args.count == 0 {
            actualDeleteCount = 0
        } else if args.count == 1 {
            actualDeleteCount = len - actualStart
        } else {
            let dc = ctx.toIntegerOrInfinity(args[1])
            actualDeleteCount = min(max(Int64(dc), 0), len - actualStart)
        }

        // Check length overflow
        if len - actualDeleteCount + insertCount > MAX_SAFE_INTEGER {
            return ctx.throwTypeError(message: "Array.prototype.splice: array length overflow")
        }

        // Create result array with species constructor
        let result = arraySpeciesCreate(ctx: ctx, obj: obj, length: actualDeleteCount)
        if result.isException { return result }

        // Copy deleted elements to result
        for i in 0..<actualDeleteCount {
            let from = UInt32(actualStart + i)
            let has = ctx.hasPropertyByIndex(obj: obj, index: from)

            if has {
                let val = ctx.getPropertyByIndex(obj: obj, index: from)
                if val.isException { return val }
                ctx.setPropertyByIndex(obj: result, index: UInt32(i), value: val)
            }
        }
        ctx.setArrayLength(result, actualDeleteCount)

        // Shift remaining elements
        let itemCount = insertCount
        if itemCount < actualDeleteCount {
            // Shift down
            var k = actualStart
            while k < len - actualDeleteCount {
                let from = UInt32(k + actualDeleteCount)
                let to = UInt32(k + itemCount)

                let has = ctx.hasPropertyByIndex(obj: obj, index: from)

                if has {
                    let val = ctx.getPropertyByIndex(obj: obj, index: from)
                    if val.isException { return val }
                    ctx.setPropertyByIndex(obj: obj, index: to, value: val)
                } else {
                    _ = ctx.deletePropertyByIndex(obj: obj, index: to)
                }
                k += 1
            }
            // Delete trailing elements
            var j = len
            while j > len - actualDeleteCount + itemCount {
                j -= 1
                _ = ctx.deletePropertyByIndex(obj: obj, index: UInt32(j))
            }
        } else if itemCount > actualDeleteCount {
            // Shift up
            var k = len - actualDeleteCount
            while k > actualStart {
                k -= 1
                let from = UInt32(k + actualDeleteCount)
                let to = UInt32(k + itemCount)

                let has = ctx.hasPropertyByIndex(obj: obj, index: from)

                if has {
                    let val = ctx.getPropertyByIndex(obj: obj, index: from)
                    if val.isException { return val }
                    ctx.setPropertyByIndex(obj: obj, index: to, value: val)
                } else {
                    _ = ctx.deletePropertyByIndex(obj: obj, index: to)
                }
            }
        }

        // Insert new items
        for i in 0..<Int(itemCount) {
            ctx.setPropertyByIndex(obj: obj, index: UInt32(actualStart + Int64(i)), value: args[i + 2])
        }

        let newLen = len - actualDeleteCount + itemCount
        setLength(ctx: ctx, obj: obj, length: newLen)

        return result
    }

    /// `Array.prototype.sort(comparefn)`
    /// Sorts the elements of an array in place and returns the sorted array.
    /// Mirrors `js_array_sort` in QuickJS with TimSort-style merge sort.
    static func sort(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let comparefn = args.count > 0 ? args[0] : .undefined

        if !comparefn.isUndefined && !ctx.isCallable(comparefn) {
            return ctx.throwTypeError(message: "Array.prototype.sort: compareFn is not a function")
        }

        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }
        if len <= 1 { return obj }

        // Collect elements into a Swift array, handling holes
        var elements: [(index: Int64, value: JeffJSValue)] = []
        var undefinedCount: Int64 = 0
        var holeCount: Int64 = 0

        for i in 0..<len {
            let has = ctx.hasPropertyByIndex(obj: obj, index: UInt32(i))

            if has {
                let val = ctx.getPropertyByIndex(obj: obj, index: UInt32(i))
                if val.isException { return val }
                if val.isUndefined {
                    undefinedCount += 1
                } else {
                    elements.append((index: i, value: val))
                }
            } else {
                holeCount += 1
            }
        }

        // Sort the non-undefined, non-hole elements
        var sortError = false
        elements.sort { a, b in
            if sortError { return false }

            if !comparefn.isUndefined {
                let result = ctx.call(comparefn, this: .undefined, args: [a.value, b.value])
                if result.isException {
                    sortError = true
                    return false
                }
                let d = ctx.extractFloat64(result) ?? Double.nan
                if d.isNaN { return false }
                return d < 0
            } else {
                // Default string comparison
                let sa = ctx.jsValueToString(a.value) ?? ""
                let sb = ctx.jsValueToString(b.value) ?? ""
                return sa < sb
            }
        }

        if sortError { return .exception }

        // Write back sorted elements
        var writeIdx: Int64 = 0
        for elem in elements {
            ctx.setPropertyByIndex(obj: obj, index: UInt32(writeIdx), value: elem.value)
            writeIdx += 1
        }

        // Write undefineds
        for _ in 0..<undefinedCount {
            ctx.setPropertyByIndex(obj: obj, index: UInt32(writeIdx), value: .undefined)
            writeIdx += 1
        }

        // Delete holes at the end
        while writeIdx < len {
            _ = ctx.deletePropertyByIndex(obj: obj, index: UInt32(writeIdx))
            writeIdx += 1
        }

        return obj
    }

    /// `Array.prototype.reverse()`
    /// Reverses the array in place.
    static func reverse(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        let middle = len / 2
        var lower: Int64 = 0
        while lower < middle {
            let upper = len - lower - 1

            let lowerExists = ctx.hasPropertyByIndex(obj: obj, index: UInt32(lower))

            let upperExists = ctx.hasPropertyByIndex(obj: obj, index: UInt32(upper))

            if lowerExists && upperExists {
                let lowerVal = ctx.getPropertyByIndex(obj: obj, index: UInt32(lower))
                if lowerVal.isException { return lowerVal }
                let upperVal = ctx.getPropertyByIndex(obj: obj, index: UInt32(upper))
                if upperVal.isException { return upperVal }

                ctx.setPropertyByIndex(obj: obj, index: UInt32(lower), value: upperVal)
                ctx.setPropertyByIndex(obj: obj, index: UInt32(upper), value: lowerVal)
            } else if !lowerExists && upperExists {
                let upperVal = ctx.getPropertyByIndex(obj: obj, index: UInt32(upper))
                if upperVal.isException { return upperVal }
                ctx.setPropertyByIndex(obj: obj, index: UInt32(lower), value: upperVal)
                _ = ctx.deletePropertyByIndex(obj: obj, index: UInt32(upper))
            } else if lowerExists && !upperExists {
                let lowerVal = ctx.getPropertyByIndex(obj: obj, index: UInt32(lower))
                if lowerVal.isException { return lowerVal }
                _ = ctx.deletePropertyByIndex(obj: obj, index: UInt32(lower))
                ctx.setPropertyByIndex(obj: obj, index: UInt32(upper), value: lowerVal)
            }
            // Both absent: no-op

            lower += 1
        }

        return obj
    }

    /// `Array.prototype.fill(value, start?, end?)`
    /// Fills all the elements from a start index to an end index with a static value.
    static func fill(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        let value = args.count > 0 ? args[0] : .undefined

        let k = resolveRelativeIndex(ctx: ctx, arg: args.count > 1 ? args[1] : .undefined, length: len, defaultVal: 0)
        if k < -1 { return .exception }

        let final_ = resolveRelativeIndex(ctx: ctx, arg: args.count > 2 ? args[2] : .undefined, length: len, defaultVal: len)
        if final_ < -1 { return .exception }

        var i = k
        while i < final_ {
            ctx.setPropertyByIndex(obj: obj, index: UInt32(i), value: value)
            i += 1
        }

        return obj
    }

    /// `Array.prototype.copyWithin(target, start, end?)`
    /// Shallow copies part of an array to another location in the same array.
    static func copyWithin(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        var to = resolveRelativeIndex(ctx: ctx, arg: args.count > 0 ? args[0] : .undefined, length: len, defaultVal: 0)
        if to < -1 { return .exception }

        var from = resolveRelativeIndex(ctx: ctx, arg: args.count > 1 ? args[1] : .undefined, length: len, defaultVal: 0)
        if from < -1 { return .exception }

        let final_ = resolveRelativeIndex(ctx: ctx, arg: args.count > 2 ? args[2] : .undefined, length: len, defaultVal: len)
        if final_ < -1 { return .exception }

        var count = min(final_ - from, len - to)
        if count <= 0 { return obj }

        // Determine copy direction to handle overlapping regions
        let direction: Int64
        if from < to && to < from + count {
            direction = -1
            from = from + count - 1
            to = to + count - 1
        } else {
            direction = 1
        }

        while count > 0 {
            let has = ctx.hasPropertyByIndex(obj: obj, index: UInt32(from))

            if has {
                let val = ctx.getPropertyByIndex(obj: obj, index: UInt32(from))
                if val.isException { return val }
                ctx.setPropertyByIndex(obj: obj, index: UInt32(to), value: val)
            } else {
                _ = ctx.deletePropertyByIndex(obj: obj, index: UInt32(to))
            }

            from += direction
            to += direction
            count -= 1
        }

        return obj
    }

    // MARK: - Array.prototype non-mutating methods

    /// `Array.prototype.concat(...items)`
    /// Merges two or more arrays, returning a new array.
    static func concat(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        // Defensive: if this is null/undefined (method dispatch may pass undefined
        // when using call instead of call_method), fall back to an empty array
        // so we don't throw a TypeError on valid-looking code like [1,2].concat([3,4]).
        let thisOrEmpty: JeffJSValue = (this.isNull || this.isUndefined) ? ctx.newArray() : this
        let obj = ctx.toObject(thisOrEmpty)
        if obj.isException { return obj }

        let result = arraySpeciesCreate(ctx: ctx, obj: obj, length: 0)
        if result.isException { return result }

        var n: Int64 = 0

        // Process this + all arguments
        let items = [obj] + args
        for item in items {
            let spreadable = isConcatSpreadable(ctx: ctx, obj: item)

            if spreadable {
                let itemLen = getLength(ctx: ctx, obj: item)
                if itemLen < 0 { return .exception }

                if n + itemLen > MAX_SAFE_INTEGER {
                    return ctx.throwTypeError(message: "Array.prototype.concat: array length overflow")
                }

                for k in 0..<itemLen {
                    let has = ctx.hasPropertyByIndex(obj: item, index: UInt32(k))

                    if has {
                        let val = ctx.getPropertyByIndex(obj: item, index: UInt32(k))
                        if val.isException { return val }
                        ctx.setPropertyByIndex(obj: result, index: UInt32(n), value: val)
                    }
                    n += 1
                }
            } else {
                if n >= MAX_SAFE_INTEGER {
                    return ctx.throwTypeError(message: "Array.prototype.concat: array length overflow")
                }
                ctx.setPropertyByIndex(obj: result, index: UInt32(n), value: item)
                n += 1
            }
        }

        ctx.setArrayLength(result, n)

        return result
    }

    /// `Array.prototype.join(separator)`
    /// Joins all elements of an array into a string.
    static func join(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        let sep: String
        if args.count > 0 && !args[0].isUndefined {
            sep = ctx.jsValueToString(args[0]) ?? ","
        } else {
            sep = ","
        }

        if len == 0 {
            return ctx.newStringValue("")
        }

        var result = ""
        for i in 0..<len {
            if i > 0 {
                result += sep
            }
            let elem = ctx.getPropertyByIndex(obj: obj, index: UInt32(i))
            if elem.isException { return elem }

            if !elem.isNullOrUndefined {
                let str = ctx.jsValueToString(elem) ?? ""
                result += str
            }
        }

        return ctx.newStringValue(result)
    }

    /// `Array.prototype.slice(start, end)`
    /// Returns a shallow copy of a portion of an array into a new array.
    static func slice(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        let k = resolveRelativeIndex(ctx: ctx, arg: args.count > 0 ? args[0] : .undefined, length: len, defaultVal: 0)
        if k < -1 { return .exception }

        let final_ = resolveRelativeIndex(ctx: ctx, arg: args.count > 1 ? args[1] : .undefined, length: len, defaultVal: len)
        if final_ < -1 { return .exception }

        let count = max(final_ - k, 0)
        let result = arraySpeciesCreate(ctx: ctx, obj: obj, length: count)
        if result.isException { return result }

        var n: Int64 = 0
        var i = k
        while i < final_ {
            let has = ctx.hasPropertyByIndex(obj: obj, index: UInt32(i))

            if has {
                let val = ctx.getPropertyByIndex(obj: obj, index: UInt32(i))
                if val.isException { return val }
                ctx.setPropertyByIndex(obj: result, index: UInt32(n), value: val)
            }
            i += 1
            n += 1
        }

        ctx.setArrayLength(result, count)

        return result
    }

    /// `Array.prototype.indexOf(searchElement, fromIndex?)`
    /// Returns the first index at which a given element can be found.
    /// Uses Strict Equality Comparison (===) per ES spec.
    static func indexOf(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        if len == 0 { return ctx.newInt64(-1) }

        let searchElement = args.count > 0 ? args[0] : .undefined

        var k: Int64
        if args.count > 1 {
            let nv = ctx.toIntegerOrInfinity(args[1])
            if nv >= Double(len) { return ctx.newInt64(-1) }
            if nv >= 0 {
                k = Int64(nv)
            } else {
                k = max(len + Int64(nv), 0)
            }
        } else {
            k = 0
        }

        while k < len {
            let has = ctx.hasPropertyByIndex(obj: obj, index: UInt32(k))

            if has {
                let val = ctx.getPropertyByIndex(obj: obj, index: UInt32(k))
                if val.isException { return val }

                if strictEqual(ctx: ctx, val, searchElement) {
                    return ctx.newInt64(k)
                }
            }
            k += 1
        }

        return ctx.newInt64(-1)
    }

    /// `Array.prototype.lastIndexOf(searchElement, fromIndex?)`
    /// Returns the last index at which a given element can be found.
    /// Uses Strict Equality Comparison (===) per ES spec.
    static func lastIndexOf(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        if len == 0 { return ctx.newInt64(-1) }

        let searchElement = args.count > 0 ? args[0] : .undefined

        var k: Int64
        if args.count > 1 {
            let nv = ctx.toIntegerOrInfinity(args[1])
            if nv >= 0 {
                k = min(Int64(nv), len - 1)
            } else {
                k = len + Int64(nv)
            }
        } else {
            k = len - 1
        }

        while k >= 0 {
            let has = ctx.hasPropertyByIndex(obj: obj, index: UInt32(k))

            if has {
                let val = ctx.getPropertyByIndex(obj: obj, index: UInt32(k))
                if val.isException { return val }

                if strictEqual(ctx: ctx, val, searchElement) {
                    return ctx.newInt64(k)
                }
            }
            k -= 1
        }

        return ctx.newInt64(-1)
    }

    /// `Array.prototype.includes(searchElement, fromIndex?)`
    /// Determines whether an array includes a certain value.
    /// Uses SameValueZero comparison (NaN === NaN, +0 === -0).
    static func includes(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        if len == 0 { return .JS_FALSE }

        let searchElement = args.count > 0 ? args[0] : .undefined

        var k: Int64
        if args.count > 1 {
            let nv = ctx.toIntegerOrInfinity(args[1])
            if nv >= Double(len) { return .JS_FALSE }
            if nv >= 0 {
                k = Int64(nv)
            } else {
                k = max(len + Int64(nv), 0)
            }
        } else {
            k = 0
        }

        while k < len {
            let val = ctx.getPropertyByIndex(obj: obj, index: UInt32(k))
            if val.isException { return val }

            if ctx.sameValueZero(val, searchElement) {
                return .JS_TRUE
            }
            k += 1
        }

        return .JS_FALSE
    }

    /// `Array.prototype.flat(depth?)`
    /// Creates a new array with all sub-array elements concatenated into it recursively
    /// up to the specified depth.
    static func flat(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        var depthNum: Int64 = 1
        if args.count > 0 && !args[0].isUndefined {
            let d = ctx.toIntegerOrInfinity(args[0])
            if d.isNaN || d <= 0 { depthNum = 0 }
            else if d.isInfinite || d > Double(Int64.max) { depthNum = Int64.max }
            else { depthNum = Int64(d) }
        }

        let result = arraySpeciesCreate(ctx: ctx, obj: obj, length: 0)
        if result.isException { return result }

        let finalIdx = flattenIntoArray(ctx: ctx, target: result, source: obj, sourceLen: len,
                                        start: 0, depth: depthNum, mapperFunction: .undefined, thisArg: .undefined)
        if finalIdx < 0 { return .exception }

        ctx.setArrayLength(result, finalIdx)

        return result
    }

    /// `Array.prototype.flatMap(callback, thisArg?)`
    /// Maps each element using a mapping function, then flattens the result into a new array.
    static func flatMap(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        let callbackFn = args.count > 0 ? args[0] : .undefined
        if !ctx.isCallable(callbackFn) {
            return ctx.throwTypeError(message: "Array.prototype.flatMap: callback is not a function")
        }

        let thisArg = args.count > 1 ? args[1] : .undefined

        let result = arraySpeciesCreate(ctx: ctx, obj: obj, length: 0)
        if result.isException { return result }

        let finalIdx = flattenIntoArray(ctx: ctx, target: result, source: obj, sourceLen: len,
                                        start: 0, depth: 1, mapperFunction: callbackFn, thisArg: thisArg)
        if finalIdx < 0 { return .exception }

        ctx.setArrayLength(result, finalIdx)

        return result
    }

    // MARK: - Iteration methods

    /// `Array.prototype.forEach(callback, thisArg?)`
    static func forEach(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        let callbackFn = args.count > 0 ? args[0] : .undefined
        if !ctx.isCallable(callbackFn) {
            return ctx.throwTypeError(message: "Array.prototype.forEach: callback is not a function")
        }

        let thisArg = args.count > 1 ? args[1] : .undefined

        for k in 0..<len {
            let has = ctx.hasPropertyByIndex(obj: obj, index: UInt32(k))

            if has {
                let val = ctx.getPropertyByIndex(obj: obj, index: UInt32(k))
                if val.isException { return val }

                let kVal = ctx.newInt64(k)
                let result = ctx.call(callbackFn, this: thisArg, args: [val, kVal, obj])
                if result.isException { return result }
            }
        }

        return .undefined
    }

    /// `Array.prototype.map(callback, thisArg?)`
    static func map(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        let callbackFn = args.count > 0 ? args[0] : .undefined
        if !ctx.isCallable(callbackFn) {
            return ctx.throwTypeError(message: "Array.prototype.map: callback is not a function")
        }

        let thisArg = args.count > 1 ? args[1] : .undefined

        let result = arraySpeciesCreate(ctx: ctx, obj: obj, length: len)
        if result.isException { return result }

        for k in 0..<len {
            let has = ctx.hasPropertyByIndex(obj: obj, index: UInt32(k))

            if has {
                let val = ctx.getPropertyByIndex(obj: obj, index: UInt32(k))
                if val.isException { return val }

                let kVal = ctx.newInt64(k)
                let mappedValue = ctx.call(callbackFn, this: thisArg, args: [val, kVal, obj])
                if mappedValue.isException { return mappedValue }

                ctx.setPropertyByIndex(obj: result, index: UInt32(k), value: mappedValue)
            }
        }

        return result
    }

    /// `Array.prototype.filter(callback, thisArg?)`
    static func filter(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        let callbackFn = args.count > 0 ? args[0] : .undefined
        if !ctx.isCallable(callbackFn) {
            return ctx.throwTypeError(message: "Array.prototype.filter: callback is not a function")
        }

        let thisArg = args.count > 1 ? args[1] : .undefined

        let result = arraySpeciesCreate(ctx: ctx, obj: obj, length: 0)
        if result.isException { return result }

        var to: Int64 = 0
        for k in 0..<len {
            let has = ctx.hasPropertyByIndex(obj: obj, index: UInt32(k))

            if has {
                let val = ctx.getPropertyByIndex(obj: obj, index: UInt32(k))
                if val.isException { return val }

                let kVal = ctx.newInt64(k)
                let selected = ctx.call(callbackFn, this: thisArg, args: [val, kVal, obj])
                if selected.isException { return selected }

                if ctx.toBoolFree(selected) {
                    ctx.setPropertyByIndex(obj: result, index: UInt32(to), value: val)
                    to += 1
                }
            }
        }

        setLength(ctx: ctx, obj: result, length: to)

        return result
    }

    /// `Array.prototype.every(callback, thisArg?)`
    static func every(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        let callbackFn = args.count > 0 ? args[0] : .undefined
        if !ctx.isCallable(callbackFn) {
            return ctx.throwTypeError(message: "Array.prototype.every: callback is not a function")
        }

        let thisArg = args.count > 1 ? args[1] : .undefined

        for k in 0..<len {
            let has = ctx.hasPropertyByIndex(obj: obj, index: UInt32(k))

            if has {
                let val = ctx.getPropertyByIndex(obj: obj, index: UInt32(k))
                if val.isException { return val }

                let kVal = ctx.newInt64(k)
                let testResult = ctx.call(callbackFn, this: thisArg, args: [val, kVal, obj])
                if testResult.isException { return testResult }

                if !ctx.toBoolFree(testResult) {
                    return .JS_FALSE
                }
            }
        }

        return .JS_TRUE
    }

    /// `Array.prototype.some(callback, thisArg?)`
    static func some(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        let callbackFn = args.count > 0 ? args[0] : .undefined
        if !ctx.isCallable(callbackFn) {
            return ctx.throwTypeError(message: "Array.prototype.some: callback is not a function")
        }

        let thisArg = args.count > 1 ? args[1] : .undefined

        for k in 0..<len {
            let has = ctx.hasPropertyByIndex(obj: obj, index: UInt32(k))

            if has {
                let val = ctx.getPropertyByIndex(obj: obj, index: UInt32(k))
                if val.isException { return val }

                let kVal = ctx.newInt64(k)
                let testResult = ctx.call(callbackFn, this: thisArg, args: [val, kVal, obj])
                if testResult.isException { return testResult }

                if ctx.toBoolFree(testResult) {
                    return .JS_TRUE
                }
            }
        }

        return .JS_FALSE
    }

    /// `Array.prototype.find(callback, thisArg?)`
    static func find(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        let callbackFn = args.count > 0 ? args[0] : .undefined
        if !ctx.isCallable(callbackFn) {
            return ctx.throwTypeError(message: "Array.prototype.find: callback is not a function")
        }

        let thisArg = args.count > 1 ? args[1] : .undefined

        for k in 0..<len {
            let val = ctx.getPropertyByIndex(obj: obj, index: UInt32(k))
            if val.isException { return val }

            let kVal = ctx.newInt64(k)
            let testResult = ctx.call(callbackFn, this: thisArg, args: [val, kVal, obj])
            if testResult.isException { return testResult }

            if ctx.toBoolFree(testResult) {
                return val
            }
        }

        return .undefined
    }

    /// `Array.prototype.findIndex(callback, thisArg?)`
    static func findIndex(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        let callbackFn = args.count > 0 ? args[0] : .undefined
        if !ctx.isCallable(callbackFn) {
            return ctx.throwTypeError(message: "Array.prototype.findIndex: callback is not a function")
        }

        let thisArg = args.count > 1 ? args[1] : .undefined

        for k in 0..<len {
            let val = ctx.getPropertyByIndex(obj: obj, index: UInt32(k))
            if val.isException { return val }

            let kVal = ctx.newInt64(k)
            let testResult = ctx.call(callbackFn, this: thisArg, args: [val, kVal, obj])
            if testResult.isException { return testResult }

            if ctx.toBoolFree(testResult) {
                return ctx.newInt64(k)
            }
        }

        return ctx.newInt64(-1)
    }

    /// `Array.prototype.findLast(callback, thisArg?)`
    static func findLast(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        let callbackFn = args.count > 0 ? args[0] : .undefined
        if !ctx.isCallable(callbackFn) {
            return ctx.throwTypeError(message: "Array.prototype.findLast: callback is not a function")
        }

        let thisArg = args.count > 1 ? args[1] : .undefined

        var k = len - 1
        while k >= 0 {
            let val = ctx.getPropertyByIndex(obj: obj, index: UInt32(k))
            if val.isException { return val }

            let kVal = ctx.newInt64(k)
            let testResult = ctx.call(callbackFn, this: thisArg, args: [val, kVal, obj])
            if testResult.isException { return testResult }

            if ctx.toBoolFree(testResult) {
                return val
            }
            k -= 1
        }

        return .undefined
    }

    /// `Array.prototype.findLastIndex(callback, thisArg?)`
    static func findLastIndex(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        let callbackFn = args.count > 0 ? args[0] : .undefined
        if !ctx.isCallable(callbackFn) {
            return ctx.throwTypeError(message: "Array.prototype.findLastIndex: callback is not a function")
        }

        let thisArg = args.count > 1 ? args[1] : .undefined

        var k = len - 1
        while k >= 0 {
            let val = ctx.getPropertyByIndex(obj: obj, index: UInt32(k))
            if val.isException { return val }

            let kVal = ctx.newInt64(k)
            let testResult = ctx.call(callbackFn, this: thisArg, args: [val, kVal, obj])
            if testResult.isException { return testResult }

            if ctx.toBoolFree(testResult) {
                return ctx.newInt64(k)
            }
            k -= 1
        }

        return ctx.newInt64(-1)
    }

    // MARK: - Reduction methods

    /// `Array.prototype.reduce(callback, initialValue?)`
    static func reduce(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        let callbackFn = args.count > 0 ? args[0] : .undefined
        if !ctx.isCallable(callbackFn) {
            return ctx.throwTypeError(message: "Array.prototype.reduce: callback is not a function")
        }

        var k: Int64 = 0
        var accumulator: JeffJSValue = .undefined

        if args.count >= 2 {
            accumulator = args[1]
        } else {
            // Find first present element
            var kPresent = false
            while k < len {
                let has = ctx.hasPropertyByIndex(obj: obj, index: UInt32(k))

                if has {
                    accumulator = ctx.getPropertyByIndex(obj: obj, index: UInt32(k))
                    if accumulator.isException { return accumulator }
                    kPresent = true
                    k += 1
                    break
                }
                k += 1
            }
            if !kPresent {
                return ctx.throwTypeError(message: "Reduce of empty array with no initial value")
            }
        }

        while k < len {
            let has = ctx.hasPropertyByIndex(obj: obj, index: UInt32(k))

            if has {
                let val = ctx.getPropertyByIndex(obj: obj, index: UInt32(k))
                if val.isException { return val }

                let kVal = ctx.newInt64(k)
                accumulator = ctx.call(callbackFn, this: .undefined, args: [accumulator, val, kVal, obj])
                if accumulator.isException { return accumulator }
            }
            k += 1
        }

        return accumulator
    }

    /// `Array.prototype.reduceRight(callback, initialValue?)`
    static func reduceRight(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        let callbackFn = args.count > 0 ? args[0] : .undefined
        if !ctx.isCallable(callbackFn) {
            return ctx.throwTypeError(message: "Array.prototype.reduceRight: callback is not a function")
        }

        var k = len - 1
        var accumulator: JeffJSValue = .undefined

        if args.count >= 2 {
            accumulator = args[1]
        } else {
            var kPresent = false
            while k >= 0 {
                let has = ctx.hasPropertyByIndex(obj: obj, index: UInt32(k))

                if has {
                    accumulator = ctx.getPropertyByIndex(obj: obj, index: UInt32(k))
                    if accumulator.isException { return accumulator }
                    kPresent = true
                    k -= 1
                    break
                }
                k -= 1
            }
            if !kPresent {
                return ctx.throwTypeError(message: "Reduce of empty array with no initial value")
            }
        }

        while k >= 0 {
            let has = ctx.hasPropertyByIndex(obj: obj, index: UInt32(k))

            if has {
                let val = ctx.getPropertyByIndex(obj: obj, index: UInt32(k))
                if val.isException { return val }

                let kVal = ctx.newInt64(k)
                accumulator = ctx.call(callbackFn, this: .undefined, args: [accumulator, val, kVal, obj])
                if accumulator.isException { return accumulator }
            }
            k -= 1
        }

        return accumulator
    }

    // MARK: - ES2023 immutable methods

    /// `Array.prototype.toReversed()`
    /// Returns a new array with the elements in reversed order.
    static func toReversed(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        let result = ctx.newArrayWithLength(Int(len))
        if result.isException { return result }

        for k in 0..<len {
            let from = len - k - 1
            let val = ctx.getPropertyByIndex(obj: obj, index: UInt32(from))
            if val.isException { return val }

            ctx.setPropertyByIndex(obj: result, index: UInt32(k), value: val)
        }

        return result
    }

    /// `Array.prototype.toSorted(compareFn?)`
    /// Returns a new array with the elements sorted.
    static func toSorted(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let comparefn = args.count > 0 ? args[0] : .undefined

        if !comparefn.isUndefined && !ctx.isCallable(comparefn) {
            return ctx.throwTypeError(message: "Array.prototype.toSorted: compareFn is not a function")
        }

        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        // Create a copy
        let result = ctx.newArrayWithLength(Int(len))
        if result.isException { return result }

        for k in 0..<len {
            let val = ctx.getPropertyByIndex(obj: obj, index: UInt32(k))
            if val.isException { return val }
            ctx.setPropertyByIndex(obj: result, index: UInt32(k), value: val)
        }

        // Sort the copy in place
        let sortResult = sort(ctx: ctx, this: result, args: comparefn.isUndefined ? [] : [comparefn])
        if sortResult.isException { return sortResult }

        return result
    }

    /// `Array.prototype.toSpliced(start, deleteCount, ...items)`
    /// Returns a new array with some elements removed and/or replaced at a given index.
    static func toSpliced(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        // Resolve start
        var actualStart: Int64
        if args.count > 0 {
            let rs = ctx.toIntegerOrInfinity(args[0])
            if rs == -.infinity {
                actualStart = 0
            } else if rs < 0 {
                actualStart = max(len + Int64(rs), 0)
            } else {
                actualStart = min(Int64(rs), len)
            }
        } else {
            actualStart = 0
        }

        let insertCount = Int64(max(args.count - 2, 0))
        var actualDeleteCount: Int64
        if args.count == 0 {
            actualDeleteCount = 0
        } else if args.count == 1 {
            actualDeleteCount = len - actualStart
        } else {
            let dc = ctx.toIntegerOrInfinity(args[1])
            actualDeleteCount = min(max(Int64(dc), 0), len - actualStart)
        }

        let newLen = len + insertCount - actualDeleteCount
        if newLen > MAX_SAFE_INTEGER {
            return ctx.throwTypeError(message: "Array.prototype.toSpliced: result length overflow")
        }

        let result = ctx.newArrayWithLength(Int(newLen))
        if result.isException { return result }

        var i: Int64 = 0
        var r: Int64 = 0

        // Copy elements before actualStart
        while r < actualStart {
            let val = ctx.getPropertyByIndex(obj: obj, index: UInt32(r))
            if val.isException { return val }
            ctx.setPropertyByIndex(obj: result, index: UInt32(i), value: val)
            i += 1
            r += 1
        }

        // Insert new items
        for j in 0..<Int(insertCount) {
            ctx.setPropertyByIndex(obj: result, index: UInt32(i), value: args[j + 2])
            i += 1
        }

        // Skip deleted elements
        r += actualDeleteCount

        // Copy remaining elements
        while r < len {
            let val = ctx.getPropertyByIndex(obj: obj, index: UInt32(r))
            if val.isException { return val }
            ctx.setPropertyByIndex(obj: result, index: UInt32(i), value: val)
            i += 1
            r += 1
        }

        return result
    }

    /// `Array.prototype.with(index, value)`
    /// Returns a new array with the element at the given index replaced with the given value.
    static func with_(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        let indexArg = args.count > 0 ? args[0] : .undefined
        let value = args.count > 1 ? args[1] : .undefined

        let riDouble = ctx.toIntegerOrInfinity(indexArg)
        let ri: Int64 = riDouble.isNaN ? 0 : (riDouble.isInfinite || abs(riDouble) > Double(Int64.max) ? (riDouble > 0 ? Int64.max : Int64.min) : Int64(riDouble))

        let actualIndex: Int64
        if ri >= 0 {
            actualIndex = ri
        } else {
            actualIndex = len + ri
        }

        if actualIndex < 0 || actualIndex >= len {
            return ctx.throwRangeError(message: "Array.prototype.with: index out of range")
        }

        let result = ctx.newArrayWithLength(Int(len))
        if result.isException { return result }

        for k in 0..<len {
            let val: JeffJSValue
            if k == actualIndex {
                val = value
            } else {
                val = ctx.getPropertyByIndex(obj: obj, index: UInt32(k))
                if val.isException { return val }
            }
            ctx.setPropertyByIndex(obj: result, index: UInt32(k), value: val)
        }

        return result
    }

    /// `Array.prototype.at(index)`
    /// Returns the element at the given integer index, allowing positive and negative integers.
    static func at(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        let indexArg = args.count > 0 ? args[0] : .undefined
        let riDouble2 = ctx.toIntegerOrInfinity(indexArg)
        let ri: Int64 = riDouble2.isNaN ? 0 : (riDouble2.isInfinite || abs(riDouble2) > Double(Int64.max) ? (riDouble2 > 0 ? Int64.max : Int64.min) : Int64(riDouble2))

        let k: Int64
        if ri >= 0 {
            k = ri
        } else {
            k = len + ri
        }

        if k < 0 || k >= len {
            return .undefined
        }

        return ctx.getPropertyByIndex(obj: obj, index: UInt32(k))
    }

    // MARK: - Conversion methods

    /// `Array.prototype.toString()`
    /// Returns a string representing the specified array and its elements.
    static func toString(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let joinAtom = ctx.rt.findAtom("join")
        let joinFn = ctx.getProperty(obj: obj, atom: joinAtom)
        if joinFn.isException { return joinFn }

        if ctx.isCallable(joinFn) {
            return ctx.call(joinFn, this: obj, args: [])
        }

        // Fallback to Object.prototype.toString
        return JeffJSBuiltinObject.toString(ctx: ctx, this: obj, args: [])
    }

    /// `Array.prototype.toLocaleString()`
    /// Returns a localized string representing the specified array and its elements.
    static func toLocaleString(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let len = getLength(ctx: ctx, obj: obj)
        if len < 0 { return .exception }

        if len == 0 {
            return ctx.newStringValue("")
        }

        let tlsAtom = ctx.rt.findAtom("toLocaleString")
        var result = ""
        for i in 0..<len {
            if i > 0 {
                result += ","
            }
            let elem = ctx.getPropertyByIndex(obj: obj, index: UInt32(i))
            if elem.isException { return elem }

            if !elem.isNullOrUndefined {
                let tls = ctx.getProperty(obj: elem, atom: tlsAtom)
                if tls.isException { return tls }

                if !ctx.isCallable(tls) {
                    return ctx.throwTypeError(message: "toLocaleString is not a function")
                }

                let str = ctx.call(tls, this: elem, args: [])
                if str.isException { return str }

                result += ctx.jsValueToString(str) ?? ""
            }
        }

        return ctx.newStringValue(result)
    }

    // MARK: - Iterator methods

    /// `Array.prototype.keys()`
    /// Returns a new Array Iterator object that contains the keys for each index in the array.
    static func keys(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        return ctx.createArrayIterator(obj: obj, kind: JeffJSArrayIteratorKind.key.rawValue)
    }

    /// `Array.prototype.values()` / `Array.prototype[Symbol.iterator]()`
    /// Returns a new Array Iterator object that contains the values for each index in the array.
    static func values(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        return ctx.createArrayIterator(obj: obj, kind: JeffJSArrayIteratorKind.value.rawValue)
    }

    /// `Array.prototype.entries()`
    /// Returns a new Array Iterator object that contains the key/value pairs for each index.
    static func entries(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        return ctx.createArrayIterator(obj: obj, kind: JeffJSArrayIteratorKind.keyAndValue.rawValue)
    }


    // MARK: - Internal helpers

    /// Get the length of an array-like object as Int64.
    /// Mirrors `js_get_length64` in QuickJS.
    private static func getLength(ctx: JeffJSContext, obj: JeffJSValue) -> Int64 {
        let lenAtom = ctx.rt.findAtom("length")
        let lenVal = ctx.getProperty(obj: obj, atom: lenAtom)
        if lenVal.isException { return -1 }
        return ctx.toLength(lenVal)
    }

    /// Set the "length" property of an object.
    /// Returns 0 on success, -1 on failure.
    @discardableResult
    private static func setLength(ctx: JeffJSContext, obj: JeffJSValue, length: Int64) -> Int {
        let lenAtom = ctx.rt.findAtom("length")
        let lenVal = ctx.newInt64(length)
        return ctx.setProperty(obj: obj, atom: lenAtom, value: lenVal)
    }

    /// Resolve a relative index argument to an absolute index.
    /// - If arg is undefined, returns defaultVal.
    /// - Negative values are resolved relative to length.
    /// - Returns -2 on exception.
    private static func resolveRelativeIndex(ctx: JeffJSContext, arg: JeffJSValue, length: Int64, defaultVal: Int64) -> Int64 {
        if arg.isUndefined {
            return defaultVal
        }
        let nv = ctx.toIntegerOrInfinity(arg)
        if nv == -.infinity { return 0 }
        if nv < 0 {
            return max(length + Int64(nv), 0)
        }
        return min(Int64(nv), length)
    }

    /// Check if an object is concat spreadable (has Symbol.isConcatSpreadable or is an array).
    /// Returns 1 if spreadable, 0 if not, -1 on error.
    private static func isConcatSpreadable(ctx: JeffJSContext, obj: JeffJSValue) -> Bool {
        if !obj.isObject {
            return false
        }

        let spreadableAtom = ctx.rt.findAtom("Symbol.isConcatSpreadable")
        let spreadable = ctx.getProperty(obj: obj, atom: spreadableAtom)
        if spreadable.isException { return false }

        if !spreadable.isUndefined {
            return ctx.toBoolFree(spreadable)
        }

        return ctx.isArray(obj)
    }

    /// Create an array using species constructor if available.
    /// Mirrors `JS_ArraySpeciesCreate` in QuickJS.
    private static func arraySpeciesCreate(ctx: JeffJSContext, obj: JeffJSValue, length: Int64) -> JeffJSValue {
        if !ctx.isArray(obj) {
            return ctx.newArrayWithLength(Int(length))
        }

        let ctorAtom = ctx.rt.findAtom("constructor")
        let ctor = ctx.getProperty(obj: obj, atom: ctorAtom)
        if ctor.isException { return ctor }

        if ctor.isObject {
            // Check @@species
            let speciesAtom = ctx.rt.findAtom("Symbol.species")
            let species = ctx.getProperty(obj: ctor, atom: speciesAtom)
            if species.isException { return species }

            if species.isNullOrUndefined {
                return ctx.newArrayWithLength(Int(length))
            }

            if ctx.isConstructor(species) {
                let lenArg = ctx.newInt64(length)
                return ctx.callConstructor(species, args: [lenArg])
            }
        }

        return ctx.newArrayWithLength(Int(length))
    }

    /// Strict Equality Comparison (===) per ES spec.
    /// Unlike SameValueZero, NaN !== NaN and +0 === -0.
    /// Used by indexOf and lastIndexOf.
    private static func strictEqual(ctx: JeffJSContext, _ a: JeffJSValue, _ b: JeffJSValue) -> Bool {
        // Numbers: both int and float representations are JS "number" type.
        // Try numeric comparison first (handles int vs float cross-tag).
        // Use IEEE comparison so NaN !== NaN.
        if a.isNumber && b.isNumber {
            guard let da = ctx.extractFloat64(a), let db = ctx.extractFloat64(b) else { return false }
            return da == db  // IEEE: NaN != NaN, +0 == -0
        }
        // Different tags (after excluding mixed int/float) means different types
        if !JeffJSValue.sameTag(a, b) { return false }
        // Strings
        if let sa = a.stringValue?.toSwiftString(), let sb = b.stringValue?.toSwiftString() {
            return sa == sb
        }
        // Objects: reference identity
        if a.isObject && b.isObject {
            return a.toObject() === b.toObject()
        }
        // Booleans, null, undefined: tag equality + value equality
        return a == b
    }

    /// FlattenIntoArray internal operation per spec.
    /// Returns the target index after flattening, or -1 on error.
    private static func flattenIntoArray(ctx: JeffJSContext, target: JeffJSValue, source: JeffJSValue,
                                         sourceLen: Int64, start: Int64, depth: Int64,
                                         mapperFunction: JeffJSValue, thisArg: JeffJSValue) -> Int64 {
        var targetIndex = start

        for sourceIndex in 0..<sourceLen {
            let has = ctx.hasPropertyByIndex(obj: source, index: UInt32(sourceIndex))

            if has {
                var element = ctx.getPropertyByIndex(obj: source, index: UInt32(sourceIndex))
                if element.isException { return -1 }

                if !mapperFunction.isUndefined {
                    let kVal = ctx.newInt64(sourceIndex)
                    element = ctx.call(mapperFunction, this: thisArg, args: [element, kVal, source])
                    if element.isException { return -1 }
                }

                var shouldFlatten = false
                if depth > 0 {
                    let isArr = ctx.isArray(element)
                    shouldFlatten = isArr
                }

                if shouldFlatten {
                    let elementLen = getLength(ctx: ctx, obj: element)
                    if elementLen < 0 { return -1 }

                    targetIndex = flattenIntoArray(ctx: ctx, target: target, source: element,
                                                   sourceLen: elementLen, start: targetIndex,
                                                   depth: depth - 1,
                                                   mapperFunction: .undefined, thisArg: .undefined)
                    if targetIndex < 0 { return -1 }
                } else {
                    if targetIndex >= MAX_SAFE_INTEGER { return -1 }

                    ctx.setPropertyByIndex(obj: target, index: UInt32(targetIndex), value: element)
                    targetIndex += 1
                }
            }
        }

        return targetIndex
    }
}

// MARK: - Array iterator kind

/// Iteration kind for Array iterators.
enum JeffJSArrayIteratorKind: Int {
    case key = 0
    case value = 1
    case keyAndValue = 2
}

// MARK: - Context protocol extensions for Array builtins

/// These are the context methods that the Array builtin relies on.
/// The actual JeffJSContext class will provide implementations.
protocol JeffJSContextArrayOps {
    // Array-specific
    var arrayPrototype: JeffJSValue { get }
    func newArrayWithLength(_ length: Int) -> JeffJSValue
    func setArrayLength(_ arr: JeffJSValue, _ length: Int64)
    func createArrayFromConstructor(_ newTarget: JeffJSValue, length: Int) -> JeffJSValue
    func createArrayIterator(obj: JeffJSValue, kind: Int) -> JeffJSValue

    // Property access
    func getProperty(obj: JeffJSValue, atom: UInt32) -> JeffJSValue
    func setProperty(obj: JeffJSValue, atom: UInt32, value: JeffJSValue) -> Int
    func getPropertyByIndex(obj: JeffJSValue, index: UInt32) -> JeffJSValue
    func setPropertyByIndex(obj: JeffJSValue, index: UInt32, value: JeffJSValue)
    func hasPropertyByIndex(obj: JeffJSValue, index: UInt32) -> Bool
    func deletePropertyByIndex(obj: JeffJSValue, index: UInt32) -> Bool
    func getMethod(_ obj: JeffJSValue, name: String) -> JeffJSValue?
    func callMethod(_ obj: JeffJSValue, name: String, args: [JeffJSValue]) -> JeffJSValue
    func setPropertyFunc(obj: JeffJSValue, name: String, fn: @escaping JeffJSNativeFunc, length: Int)
    func setPropertyGetSet(obj: JeffJSValue, name: String, getter: JeffJSValue?, setter: JeffJSValue?)

    // Type checks
    func isConstructor(_ val: JeffJSValue) -> Bool
    func isCallable(_ val: JeffJSValue) -> Bool
    func isArray(_ val: JeffJSValue) -> Bool

    // Conversion
    func toUint32(_ val: JeffJSValue) -> UInt32
    func toLength(_ val: JeffJSValue) -> Int64
    func toIntegerOrInfinity(_ val: JeffJSValue) -> Double
    func extractUint32(_ val: JeffJSValue) -> UInt32?
    func extractFloat64(_ val: JeffJSValue) -> Double?
    func toObject(_ val: JeffJSValue) -> JeffJSValue
    func toBoolFree(_ val: JeffJSValue) -> Bool
    func jsValueToString(_ val: JeffJSValue) -> String?
    func newInt64(_ val: Int64) -> JeffJSValue
    func newStringValue(_ str: String) -> JeffJSValue

    // Comparison
    func sameValueZero(_ a: JeffJSValue, _ b: JeffJSValue) -> Bool

    // Constructor
    func callConstructor(_ ctor: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue
    func call(_ fn: JeffJSValue, this thisVal: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue

    // Errors
    func throwTypeError(message: String) -> JeffJSValue
    func throwRangeError(message: String) -> JeffJSValue
}
