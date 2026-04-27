// JeffJSBuiltinObject.swift
// JeffJS — 1:1 Swift port of QuickJS Object built-in
// Copyright 2026 Jeff Bachand. All rights reserved.
//
// Port of js_obj_funcs[], js_object_constructor, and all Object static methods
// plus Object.prototype methods from QuickJS quickjs.c.

import Foundation

// MARK: - JeffJSContext extensions for Object built-in

extension JeffJSContext {
    /// Object.prototype convenience accessor.
    var objectPrototype: JeffJSValue {
        if JSClassID.JS_CLASS_OBJECT.rawValue < classProto.count {
            return classProto[JSClassID.JS_CLASS_OBJECT.rawValue]
        }
        return .null
    }

    /// Set a function property by atom (resolves atom to name).
    func setPropertyFunc(obj: JeffJSValue, atom: JSAtom, fn: @escaping JeffJSNativeFunc, length: Int) {
        let name = rt.atomToString(atom) ?? "?"
        setPropertyFunc(obj: obj, name: name, fn: fn, length: length)
    }

    /// Set a getter/setter pair by atom.
    func setPropertyGetSet(obj: JeffJSValue, atom: JSAtom,
                           getter: @escaping JeffJSNativeFunc,
                           setter: @escaping JeffJSNativeFunc) {
        let getterVal = newCFunction(getter, name: "get", length: 0)
        let setterVal = newCFunction(setter, name: "set", length: 1)
        setPropertyGetSet(obj: obj, name: rt.atomToString(atom) ?? "?",
                          getter: getterVal, setter: setterVal)
    }

    /// Create/find an atom from a string.
    func newAtom(_ str: String) -> JSAtom {
        return rt.findAtom(str)
    }

    /// Create a new object with a given prototype.
    func newObjectWithProto(_ proto: JeffJSValue) -> JeffJSValue {
        let obj = JeffJSObject()
        obj.classID = JSClassID.JS_CLASS_OBJECT.rawValue
        obj.extensible = true
        let protoObj = proto.toObject()
        // Always create a shape so property operations work correctly.
        obj.shape = JeffJSShape()
        // obj.proto is the single source of truth; its setter auto-syncs shape.proto.
        obj.proto = protoObj
        return JeffJSValue.makeObject(obj)
    }

    /// JS_GetPrototypeOf equivalent.
    /// obj.proto is the single source of truth for the prototype.
    func getPrototypeOf(_ val: JeffJSValue) -> JeffJSValue {
        guard let obj = val.toObject() else { return .null }
        if let proto = obj.proto {
            return JeffJSValue.makeObject(proto)
        }
        return .null
    }

    /// JS_SetPrototypeOf equivalent.
    /// obj.proto is the single source of truth; its setter auto-syncs shape.proto.
    @discardableResult
    func setPrototypeOf(_ obj: JeffJSValue, proto: JeffJSValue) -> Bool {
        guard let jsObj = obj.toObject() else { return false }
        if jsObj.shape == nil { jsObj.shape = JeffJSShape() }
        jsObj.proto = proto.toObject()
        return true
    }

    /// JS_HasOwnProperty (key-based).
    func hasOwnProperty(_ obj: JeffJSValue, key: JeffJSValue) -> Int32 {
        guard let jsObj = obj.toObject() else { return 0 }
        if key.isString, let s = key.stringValue {
            let atom = rt.findAtom(s.toSwiftString())
            defer { rt.freeAtom(atom) }
            let val = jsObj.getOwnPropertyValue(atom: atom)
            return val.isUndefined ? 0 : 1
        }
        return 0
    }

    /// SameValue comparison (ES2023 7.2.11).
    ///
    /// Differs from strict equality (===) in two ways:
    ///   - NaN === NaN is true  (unlike ===)
    ///   - +0  === -0  is false (unlike ===)
    func sameValue(_ x: JeffJSValue, _ y: JeffJSValue) -> Bool {
        // Different tags -> not the same value (int vs float handled below).
        if !JeffJSValue.sameTag(x, y) {
            // Allow int/float cross-comparison (e.g. 0 vs 0.0).
            if x.isNumber && y.isNumber {
                let a = x.toNumber(), b = y.toNumber()
                if a.isNaN && b.isNaN { return true }
                if a == 0 && b == 0 { return a.sign == b.sign }
                return a == b
            }
            return false
        }

        // Same tag — dispatch by type.
        if x.isInt { return x.toInt32() == y.toInt32() }
        if x.isFloat64 {
            let a = x.toFloat64(), b = y.toFloat64()
            if a.isNaN && b.isNaN { return true }
            if a == 0 && b == 0 { return a.sign == b.sign }
            return a == b
        }
        if x.isBool { return x.toBool() == y.toBool() }
        if x.isNull || x.isUndefined { return true }
        if x.isString {
            if let sx = x.stringValue, let sy = y.stringValue {
                return jeffJS_stringEquals(s1: sx, s2: sy)
            }
            return false
        }
        if x.isObject { return x.toObject() === y.toObject() }
        if x.isSymbol { return x.heapRef === y.heapRef }
        if x.isBigInt {
            if let b1 = x.toBigInt(), let b2 = y.toBigInt() {
                return b1 === b2 || (b1.sign == b2.sign && b1.limbs == b2.limbs)
            }
            return false
        }
        return false
    }

    /// Returns a property descriptor object for an own property, or undefined if not found.
    func getOwnPropertyDescriptor(_ obj: JeffJSValue, key: JeffJSValue) -> JeffJSValue {
        guard let jsObj = obj.toObject() else { return .undefined }
        if key.isString, let s = key.stringValue {
            let atom = rt.findAtom(s.toSwiftString())
            defer { rt.freeAtom(atom) }
            let (shapeProp, prop) = jeffJS_findOwnProperty(obj: jsObj, atom: atom)
            guard let shapeProp = shapeProp, let prop = prop else { return .undefined }

            let desc = newPlainObject()
            switch prop {
            case .value(let val):
                _ = setPropertyStr(obj: desc, name: "value", value: val.dupValue())
                _ = setPropertyStr(obj: desc, name: "writable",
                                   value: JeffJSValue.newBool(shapeProp.flags.contains(.writable)))
            case .getset(let getter, let setter):
                if let getter = getter {
                    _ = setPropertyStr(obj: desc, name: "get", value: JeffJSValue.makeObject(getter))
                } else {
                    _ = setPropertyStr(obj: desc, name: "get", value: .undefined)
                }
                if let setter = setter {
                    _ = setPropertyStr(obj: desc, name: "set", value: JeffJSValue.makeObject(setter))
                } else {
                    _ = setPropertyStr(obj: desc, name: "set", value: .undefined)
                }
            default:
                break
            }
            _ = setPropertyStr(obj: desc, name: "enumerable",
                               value: JeffJSValue.newBool(shapeProp.flags.contains(.enumerable)))
            _ = setPropertyStr(obj: desc, name: "configurable",
                               value: JeffJSValue.newBool(shapeProp.flags.contains(.configurable)))
            return desc
        }
        return .undefined
    }

    /// Implements Object.defineProperty descriptor processing.
    /// Handles both data descriptors ({value, writable}) and accessor
    /// descriptors ({get, set}).
    func definePropertyFromDescriptor(_ obj: JeffJSValue, key: JeffJSValue, desc: JeffJSValue) -> JeffJSValue {
        guard let jsObj = obj.toObject() else {
            return throwTypeError(message: "not an object")
        }
        guard let descObj = desc.toObject() else {
            return throwTypeError(message: "property descriptor must be an object")
        }

        // Get the atom for the property name
        let atom: UInt32
        if key.isString, let s = key.stringValue {
            atom = rt.findAtom(s.toSwiftString())
        } else if let str = toSwiftString(key) {
            atom = rt.findAtom(str)
        } else {
            return throwTypeError(message: "invalid property key")
        }

        // Check if this is an accessor descriptor (has get or set)
        let getterVal = getPropertyStr(obj: desc, name: "get")
        let setterVal = getPropertyStr(obj: desc, name: "set")
        let hasGetter = !getterVal.isUndefined
        let hasSetter = !setterVal.isUndefined

        if hasGetter || hasSetter {
            // Accessor descriptor: { get, set, configurable, enumerable }
            let getter = hasGetter ? getterVal.toObject() : nil
            let setter = hasSetter ? setterVal.toObject() : nil

            // Build flags
            var flags: UInt32 = UInt32(JS_PROP_HAS_CONFIGURABLE | JS_PROP_HAS_ENUMERABLE)
            flags |= UInt32(JS_PROP_GETSET)
            if hasGetter { flags |= UInt32(JS_PROP_HAS_GET) }
            if hasSetter { flags |= UInt32(JS_PROP_HAS_SET) }

            // Check configurable/enumerable from descriptor
            let configVal = getPropertyStr(obj: desc, name: "configurable")
            if !configVal.isUndefined && JeffJSTypeConvert.toBool(configVal) {
                flags |= UInt32(JS_PROP_CONFIGURABLE)
            }
            let enumVal = getPropertyStr(obj: desc, name: "enumerable")
            if !enumVal.isUndefined && JeffJSTypeConvert.toBool(enumVal) {
                flags |= UInt32(JS_PROP_ENUMERABLE)
            }

            // Define the accessor property
            let getVal: JeffJSValue = getter != nil ? JeffJSValue.makeObject(getter!) : .undefined
            let setVal: JeffJSValue = setter != nil ? JeffJSValue.makeObject(setter!) : .undefined
            _ = defineProperty(obj: obj, atom: atom, value: .undefined,
                               getter: getVal, setter: setVal,
                               flags: Int(flags))
        } else {
            // Data descriptor: { value, writable, configurable, enumerable }
            let val = getPropertyStr(obj: desc, name: "value")

            var flags = JS_PROP_HAS_CONFIGURABLE | JS_PROP_HAS_ENUMERABLE | JS_PROP_HAS_WRITABLE | JS_PROP_HAS_VALUE

            let configVal = getPropertyStr(obj: desc, name: "configurable")
            if !configVal.isUndefined && JeffJSTypeConvert.toBool(configVal) {
                flags |= JS_PROP_CONFIGURABLE
            }
            let enumVal = getPropertyStr(obj: desc, name: "enumerable")
            if !enumVal.isUndefined && JeffJSTypeConvert.toBool(enumVal) {
                flags |= JS_PROP_ENUMERABLE
            }
            let writableVal = getPropertyStr(obj: desc, name: "writable")
            if !writableVal.isUndefined && JeffJSTypeConvert.toBool(writableVal) {
                flags |= JS_PROP_WRITABLE
            }

            _ = definePropertyValue(obj: obj, atom: atom, value: val, flags: flags)
        }
        return obj
    }

    /// Returns an array of own property names matching the given GPN flags.
    ///
    /// Flags:
    /// - `JS_GPN_STRING_MASK`  – include string-keyed properties
    /// - `JS_GPN_SYMBOL_MASK`  – include symbol-keyed properties
    /// - `JS_GPN_ENUM_ONLY`    – include only enumerable properties
    ///
    /// Integer-indexed array elements (stored in the fast-array payload) are
    /// included as string keys when `JS_GPN_STRING_MASK` is set.
    /// Deleted properties (atom == 0) are always skipped.
    func getOwnPropertyNames(_ obj: JeffJSValue, flags: Int) -> JeffJSValue {
        guard let jsObj = obj.toObject() else {
            return newArrayWithLength(0)
        }

        let wantStrings = (flags & JS_GPN_STRING_MASK) != 0
        let wantSymbols = (flags & JS_GPN_SYMBOL_MASK) != 0
        let enumOnly    = (flags & JS_GPN_ENUM_ONLY) != 0

        // Per ES spec §9.1.12, own property keys are returned in this order:
        // 1. Integer indices in ascending numeric order
        // 2. String keys in insertion order
        // 3. Symbol keys in insertion order
        var intKeys: [(UInt32, JeffJSValue)] = []  // (numeric index, string value)
        var stringKeys: [JeffJSValue] = []
        var symbolKeys: [JeffJSValue] = []

        // 1. Integer-indexed array elements (from fast-array payload).
        //    These are always enumerable and already in ascending order.
        if wantStrings {
            if case .array(_, let values, let count) = jsObj.payload {
                for i in 0..<Int(count) {
                    if i < values.count && !values[i].isUndefined {
                        intKeys.append((UInt32(i), newStringValue(String(i))))
                    }
                }
            }
        }

        // 2. Walk the shape's property table (insertion order).
        //    Separate integer-indexed keys from string/symbol keys.
        if let shape = jsObj.shape {
            for prop in shape.prop {
                let atom = prop.atom
                // Skip deleted slots.
                if atom == 0 { continue }

                // Skip non-enumerable when caller only wants enumerable.
                if enumOnly && !prop.flags.contains(.enumerable) { continue }

                // Determine whether this atom is a string or a symbol.
                let isIntAtom = rt.atomIsArrayIndex(atom)
                if isIntAtom {
                    // Integer atom — collect separately for numeric sorting.
                    if wantStrings {
                        if let idx = rt.atomToUInt32(atom) {
                            intKeys.append((idx, newStringValue(String(idx))))
                        }
                    }
                } else if let entry = rt.atomArray[Int(atom)] {
                    let isSymbol = entry.atomType == .JS_ATOM_TYPE_SYMBOL ||
                                   entry.atomType == .JS_ATOM_TYPE_GLOBAL_SYMBOL
                    if isSymbol {
                        if wantSymbols {
                            symbolKeys.append(newStringValue(entry.str))
                        }
                    } else {
                        if wantStrings {
                            stringKeys.append(newStringValue(entry.str))
                        }
                    }
                }
            }
        }

        // Sort integer keys in ascending numeric order.
        intKeys.sort { $0.0 < $1.0 }

        // Combine: integer keys (sorted) + string keys (insertion order) + symbol keys (insertion order)
        var names: [JeffJSValue] = []
        names.reserveCapacity(intKeys.count + stringKeys.count + symbolKeys.count)
        for (_, val) in intKeys { names.append(val) }
        names.append(contentsOf: stringKeys)
        names.append(contentsOf: symbolKeys)

        let arr = newArrayWithLength(names.count)
        if let arrObj = arr.toObject() {
            arrObj.payload = .array(size: UInt32(names.count), values: names, count: UInt32(names.count))
        }
        return arr
    }

    /// Get class ID from value.
    func getClassID(_ val: JeffJSValue) -> Int {
        guard let obj = val.toObject() else { return 0 }
        return obj.classID
    }

    /// JS_IsExtensible.
    func isExtensible(_ val: JeffJSValue) -> Bool {
        guard let obj = val.toObject() else { return false }
        return obj.extensible
    }

    /// JS_PreventExtensions.
    func preventExtensions(_ val: JeffJSValue) -> JeffJSValue {
        guard let obj = val.toObject() else {
            return throwTypeError(message: "not an object")
        }
        obj.extensible = false
        return .undefined
    }

    /// Call a function value (thisArg variant).
    func call(_ func_: JeffJSValue, thisArg: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        return call(func_, this: thisArg, args: args)
    }

    /// Get an iterator from an iterable.
    func getIterator(_ iterable: JeffJSValue, isAsync: Bool) -> JeffJSValue {
        guard let obj = iterable.toObject() else { return .exception }
        // Look for Symbol.iterator
        let iterFn = obj.getOwnPropertyValue(atom: JSAtomID.Symbol_iterator)
        if iterFn.isUndefined { return .exception }
        return call(iterFn, this: iterable, args: [])
    }

    /// Get the next value from an iterator.
    func iteratorNext(_ iter: JeffJSValue) -> JeffJSValue {
        guard let obj = iter.toObject() else { return .exception }
        let nextFn = obj.getOwnPropertyValue(atom: JSAtomID.next)
        if nextFn.isUndefined { return .exception }
        return call(nextFn, this: iter, args: [])
    }

    /// Freeze/seal integrity levels.
    func setIntegrityLevel(_ obj: JeffJSValue, level: JeffJSIntegrityLevel) -> JeffJSValue {
        guard let jsObj = obj.toObject() else {
            return throwTypeError(message: "not an object")
        }
        jsObj.extensible = false
        // For a full implementation, would also make properties non-configurable (seal)
        // and non-writable (freeze).
        return obj
    }

    func testIntegrityLevel(_ obj: JeffJSValue, level: JeffJSIntegrityLevel) -> Bool {
        guard let jsObj = obj.toObject() else { return true }
        return !jsObj.extensible
    }

}

// MARK: - Max array length constant (2^32 - 1)

private let JS_MAX_ARRAY_LENGTH: UInt32 = 0xFFFF_FFFE

// MARK: - JeffJSBuiltinObject

struct JeffJSBuiltinObject {

    // MARK: - Intrinsic registration

    /// Register Object constructor + Object.prototype + all static and prototype methods.
    /// Mirrors `js_init_function_class` + `JS_SetPropertyFunctionList` for Object in QuickJS.
    static func addIntrinsic(ctx: JeffJSContext) {
        // -- Object.prototype ---------------------------------------------------
        let objProto = ctx.objectPrototype

        // prototype methods
        ctx.setPropertyFunc(obj: objProto, atom: JSAtomID.toStringAtom, fn: toString, length: 0)
        ctx.setPropertyFunc(obj: objProto, atom: JSAtomID.toLocaleString, fn: toLocaleString, length: 0)
        ctx.setPropertyFunc(obj: objProto, atom: JSAtomID.valueOf, fn: valueOf, length: 0)
        ctx.setPropertyFunc(obj: objProto, atom: JSAtomID.hasOwnProperty, fn: hasOwnProperty, length: 1)
        ctx.setPropertyFunc(obj: objProto, atom: JSAtomID.isPrototypeOf, fn: isPrototypeOf_, length: 1)
        ctx.setPropertyFunc(obj: objProto, atom: JSAtomID.propertyIsEnumerable, fn: propertyIsEnumerable, length: 1)
        // __proto__ must be non-enumerable (ES spec). Use defineProperty directly
        // instead of setPropertyGetSet which always adds JS_PROP_ENUMERABLE.
        do {
            let getterVal = ctx.newCFunction(protoGetter, name: "get __proto__", length: 0)
            let setterVal = ctx.newCFunction(protoSetter, name: "set __proto__", length: 1)
            let atom = ctx.rt.findAtom("__proto__")
            _ = ctx.defineProperty(obj: objProto, atom: atom, value: .undefined,
                                   getter: getterVal, setter: setterVal,
                                   flags: JS_PROP_HAS_GET | JS_PROP_HAS_SET |
                                          JS_PROP_HAS_CONFIGURABLE | JS_PROP_CONFIGURABLE |
                                          JS_PROP_GETSET)
            ctx.rt.freeAtom(atom)
        }
        ctx.setPropertyFunc(obj: objProto, atom: JSAtomID.defineGetter, fn: defineGetter, length: 2)
        ctx.setPropertyFunc(obj: objProto, atom: JSAtomID.defineSetter, fn: defineSetter, length: 2)
        ctx.setPropertyFunc(obj: objProto, atom: JSAtomID.lookupGetter, fn: lookupGetter, length: 1)
        ctx.setPropertyFunc(obj: objProto, atom: JSAtomID.lookupSetter, fn: lookupSetter, length: 1)

        // -- Object constructor -------------------------------------------------
        let objCtor = ctx.newConstructorFunc(name: "Object", fn: { ctx, this, args in
            objectConstructor(ctx: ctx, newTarget: this, this: this, args: args)
        }, length: 1, proto: objProto)

        // Static methods on Object
        ctx.setPropertyFunc(obj: objCtor, atom: JSAtomID.create, fn: create, length: 2)
        ctx.setPropertyFunc(obj: objCtor, atom: JSAtomID.getPrototypeOf, fn: getPrototypeOf, length: 1)
        ctx.setPropertyFunc(obj: objCtor, atom: JSAtomID.setPrototypeOf, fn: setPrototypeOf, length: 2)
        ctx.setPropertyFunc(obj: objCtor, atom: JSAtomID.defineProperty, fn: defineProperty, length: 3)
        ctx.setPropertyFunc(obj: objCtor, atom: ctx.newAtom("defineProperties"), fn: defineProperties, length: 2)
        ctx.setPropertyFunc(obj: objCtor, atom: JSAtomID.getOwnPropertyNames, fn: getOwnPropertyNames, length: 1)
        ctx.setPropertyFunc(obj: objCtor, atom: JSAtomID.getOwnPropertySymbols, fn: getOwnPropertySymbols, length: 1)
        ctx.setPropertyFunc(obj: objCtor, atom: JSAtomID.getOwnPropertyDescriptor, fn: getOwnPropertyDescriptor, length: 2)
        ctx.setPropertyFunc(obj: objCtor, atom: JSAtomID.getOwnPropertyDescriptors, fn: getOwnPropertyDescriptors, length: 1)
        ctx.setPropertyFunc(obj: objCtor, atom: JSAtomID.keys, fn: keys, length: 1)
        ctx.setPropertyFunc(obj: objCtor, atom: JSAtomID.values, fn: values, length: 1)
        ctx.setPropertyFunc(obj: objCtor, atom: JSAtomID.entries, fn: entries, length: 1)
        ctx.setPropertyFunc(obj: objCtor, atom: JSAtomID.assign, fn: assign, length: 2)
        ctx.setPropertyFunc(obj: objCtor, atom: JSAtomID.is_, fn: is_, length: 2)
        ctx.setPropertyFunc(obj: objCtor, atom: JSAtomID.freeze, fn: freeze, length: 1)
        ctx.setPropertyFunc(obj: objCtor, atom: JSAtomID.seal, fn: seal, length: 1)
        ctx.setPropertyFunc(obj: objCtor, atom: JSAtomID.isFrozen, fn: isFrozen, length: 1)
        ctx.setPropertyFunc(obj: objCtor, atom: JSAtomID.isSealed, fn: isSealed, length: 1)
        ctx.setPropertyFunc(obj: objCtor, atom: JSAtomID.isExtensible, fn: isExtensible, length: 1)
        ctx.setPropertyFunc(obj: objCtor, atom: JSAtomID.preventExtensions, fn: preventExtensions, length: 1)
        ctx.setPropertyFunc(obj: objCtor, atom: JSAtomID.fromEntries, fn: fromEntries, length: 1)
        ctx.setPropertyFunc(obj: objCtor, atom: ctx.newAtom("hasOwn"), fn: hasOwn, length: 2)
        ctx.setPropertyFunc(obj: objCtor, atom: ctx.newAtom("groupBy"), fn: groupBy, length: 2)

        ctx.setGlobalConstructor(name: "Object", ctor: objCtor)
    }

    // MARK: - Object constructor

    /// `Object(value)` / `new Object(value)`
    /// When called as a function, converts the argument to an object.
    /// When called as a constructor, creates a new Object.
    /// Mirrors `js_object_constructor` in QuickJS.
    static func objectConstructor(ctx: JeffJSContext, newTarget: JeffJSValue,
                                   this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let value = args.count > 0 ? args[0] : .undefined

        // If new.target is undefined or Object, and value is supplied and not nullish
        if !newTarget.isUndefined && !newTarget.isObject {
            // new Object(value) with a subclass -- create a plain object
            return ctx.newPlainObject()
        }

        if value.isNullOrUndefined {
            return ctx.newPlainObject()
        }

        // ToObject coercion for primitive types
        return ctx.toObject(value)
    }

    // MARK: - Object static methods

    /// `Object.create(proto, propertiesObject)`
    /// Creates a new object with the specified prototype object and properties.
    static func create(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let proto = args.count > 0 ? args[0] : .undefined
        let propsArg = args.count > 1 ? args[1] : .undefined

        // proto must be an object or null
        if !proto.isObject && !proto.isNull {
            return ctx.throwTypeError("Object prototype may only be an Object or null")
        }

        let obj = ctx.newObjectWithProto(proto)
        if obj.isException { return obj }

        if !propsArg.isUndefined {
            let result = objectDefineProperties(ctx: ctx, obj: obj, props: propsArg)
            if result.isException { return result }
        }

        return obj
    }

    /// `Object.getPrototypeOf(obj)`
    /// Returns the prototype of the specified object.
    static func getPrototypeOf(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let arg = args.count > 0 ? args[0] : .undefined

        // ES2015: ToObject conversion for non-objects
        let obj = ctx.toObject(arg)
        if obj.isException { return obj }

        return ctx.getPrototypeOf(obj)
    }

    /// `Object.setPrototypeOf(obj, proto)`
    /// Sets the prototype of a specified object to another object or null.
    static func setPrototypeOf(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = args.count > 0 ? args[0] : .undefined
        let proto = args.count > 1 ? args[1] : .undefined

        // First argument must not be null or undefined
        if obj.isNullOrUndefined {
            return ctx.throwTypeError("Object.setPrototypeOf called on null or undefined")
        }

        // proto must be an object or null
        if !proto.isObject && !proto.isNull {
            return ctx.throwTypeError("Object prototype may only be an Object or null")
        }

        // If obj is not an object (it is a primitive), return it unchanged (no-op per spec)
        if !obj.isObject {
            return obj
        }

        let success = ctx.setPrototypeOf(obj, proto: proto)
        if !success {
            return ctx.throwTypeError("Cyclic __proto__ value")
        }

        return obj
    }

    /// `Object.defineProperty(obj, prop, descriptor)`
    /// Defines a new property directly on an object, or modifies an existing property.
    static func defineProperty(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = args.count > 0 ? args[0] : .undefined
        let prop = args.count > 1 ? args[1] : .undefined
        let desc = args.count > 2 ? args[2] : .undefined

        if !obj.isObject {
            return ctx.throwTypeError("Object.defineProperty called on non-object")
        }

        // Convert prop to property key
        let key = ctx.toPropertyKey(prop)
        if key.isException { return key }

        let result = ctx.definePropertyFromDescriptor(obj, key: key, desc: desc)
        if result.isException { return result }

        return obj
    }

    /// `Object.defineProperties(obj, props)`
    /// Defines new or modifies existing properties directly on an object.
    static func defineProperties(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = args.count > 0 ? args[0] : .undefined
        let props = args.count > 1 ? args[1] : .undefined

        if !obj.isObject {
            return ctx.throwTypeError("Object.defineProperties called on non-object")
        }

        let result = objectDefineProperties(ctx: ctx, obj: obj, props: props)
        if result.isException { return result }

        return obj
    }

    /// `Object.getOwnPropertyNames(obj)`
    /// Returns an array of all own string-keyed property names.
    static func getOwnPropertyNames(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let arg = args.count > 0 ? args[0] : .undefined
        let obj = ctx.toObject(arg)
        if obj.isException { return obj }

        return ctx.getOwnPropertyNames(obj, flags: JS_GPN_STRING_MASK)
    }

    /// `Object.getOwnPropertySymbols(obj)`
    /// Returns an array of all own symbol-keyed properties.
    static func getOwnPropertySymbols(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let arg = args.count > 0 ? args[0] : .undefined
        let obj = ctx.toObject(arg)
        if obj.isException { return obj }

        return ctx.getOwnPropertyNames(obj, flags: JS_GPN_SYMBOL_MASK)
    }

    /// `Object.getOwnPropertyDescriptor(obj, prop)`
    /// Returns a property descriptor for an own property.
    static func getOwnPropertyDescriptor(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let arg = args.count > 0 ? args[0] : .undefined
        let prop = args.count > 1 ? args[1] : .undefined

        let obj = ctx.toObject(arg)
        if obj.isException { return obj }

        let key = ctx.toPropertyKey(prop)
        if key.isException { return key }

        return ctx.getOwnPropertyDescriptor(obj, key: key)
    }

    /// `Object.getOwnPropertyDescriptors(obj)`
    /// Returns all own property descriptors.
    static func getOwnPropertyDescriptors(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let arg = args.count > 0 ? args[0] : .undefined
        let obj = ctx.toObject(arg)
        if obj.isException { return obj }

        // Get all own property names (strings + symbols)
        let names = ctx.getOwnPropertyNames(obj, flags: JS_GPN_STRING_MASK | JS_GPN_SYMBOL_MASK)
        if names.isException { return names }

        let result = ctx.newPlainObject()
        if result.isException { return result }

        let len = ctx.getArrayLength(names)
        for i in 0..<len {
            let key = ctx.getPropertyByIndex(obj:names, index: UInt32(i))
            if key.isException { return key }

            let desc = ctx.getOwnPropertyDescriptor(obj, key: key)
            if desc.isException { return desc }

            if !desc.isUndefined {
                let ret = ctx.setProperty(obj: result, key: key, value: desc)
                if ret < 0 { return .exception }
            }
        }

        return result
    }

    /// `Object.keys(obj)`
    /// Returns an array of an object's own enumerable string-keyed property names.
    static func keys(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let arg = args.count > 0 ? args[0] : .undefined
        let obj = ctx.toObject(arg)
        if obj.isException { return obj }

        return ctx.getOwnPropertyNames(obj, flags: JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY)
    }

    /// `Object.values(obj)`
    /// Returns an array of an object's own enumerable string-keyed property values.
    static func values(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let arg = args.count > 0 ? args[0] : .undefined
        let obj = ctx.toObject(arg)
        if obj.isException { return obj }

        let keysArr = ctx.getOwnPropertyNames(obj, flags: JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY)
        if keysArr.isException { return keysArr }

        let result = ctx.newArray()
        if result.isException { return result }

        let len = ctx.getArrayLength(keysArr)
        for i in 0..<len {
            let key = ctx.getPropertyByIndex(obj:keysArr, index: UInt32(i))
            if key.isException { return key }

            let val = ctx.getProperty(obj: obj, key: key)
            if val.isException { return val }

            ctx.setPropertyByIndex(obj:result, index: UInt32(i), value: val)
        }

        return result
    }

    /// `Object.entries(obj)`
    /// Returns an array of an object's own enumerable string-keyed property [key, value] pairs.
    static func entries(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let arg = args.count > 0 ? args[0] : .undefined
        let obj = ctx.toObject(arg)
        if obj.isException { return obj }

        let keysArr = ctx.getOwnPropertyNames(obj, flags: JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY)
        if keysArr.isException { return keysArr }

        let result = ctx.newArray()
        if result.isException { return result }

        let len = ctx.getArrayLength(keysArr)
        for i in 0..<len {
            let key = ctx.getPropertyByIndex(obj:keysArr, index: UInt32(i))
            if key.isException { return key }

            let val = ctx.getProperty(obj: obj, key: key)
            if val.isException { return val }

            let pair = ctx.newArray()
            if pair.isException { return pair }
            ctx.setPropertyByIndex(obj:pair, index: 0, value: key)
            ctx.setPropertyByIndex(obj:pair, index: 1, value: val)
            ctx.setPropertyByIndex(obj:result, index: UInt32(i), value: pair)
        }

        return result
    }

    /// `Object.assign(target, ...sources)`
    /// Copies all enumerable own properties from one or more source objects to a target object.
    static func assign(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let target = args.count > 0 ? args[0] : .undefined

        let to = ctx.toObject(target)
        if to.isException { return to }

        // Iterate over each source
        for i in 1..<args.count {
            let nextSource = args[i]
            if nextSource.isNullOrUndefined {
                continue
            }

            let source = ctx.toObject(nextSource)
            if source.isException { return source }

            let keysArr = ctx.getOwnPropertyNames(source, flags: JS_GPN_STRING_MASK | JS_GPN_SYMBOL_MASK | JS_GPN_ENUM_ONLY)
            if keysArr.isException { return keysArr }

            let len = ctx.getArrayLength(keysArr)
            for j in 0..<len {
                let key = ctx.getPropertyByIndex(obj:keysArr, index: UInt32(j))
                if key.isException { return key }

                let val = ctx.getProperty(obj: source, key: key)
                if val.isException { return val }

                let ret = ctx.setProperty(obj: to, key: key, value: val)
                if ret < 0 { return .exception }
            }
        }

        return to
    }

    /// `Object.is(value1, value2)`
    /// Determines whether two values are the same value (SameValue algorithm).
    static func is_(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let x = args.count > 0 ? args[0] : .undefined
        let y = args.count > 1 ? args[1] : .undefined

        return ctx.sameValue(x, y) ? .JS_TRUE : .JS_FALSE
    }

    /// `Object.freeze(obj)`
    /// Freezes an object: prevents new properties, and marks all existing properties
    /// as non-configurable and (for data properties) non-writable.
    static func freeze(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let arg = args.count > 0 ? args[0] : .undefined

        // Per ES2015, non-objects are returned as-is
        if !arg.isObject {
            return arg
        }

        let result = ctx.setIntegrityLevel(arg, level: .frozen)
        if result.isException { return result }

        return arg
    }

    /// `Object.seal(obj)`
    /// Seals an object: prevents new properties and marks all existing as non-configurable.
    static func seal(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let arg = args.count > 0 ? args[0] : .undefined

        if !arg.isObject {
            return arg
        }

        let result = ctx.setIntegrityLevel(arg, level: .sealed)
        if result.isException { return result }

        return arg
    }

    /// `Object.isFrozen(obj)`
    /// Determines if an object is frozen.
    static func isFrozen(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let arg = args.count > 0 ? args[0] : .undefined

        if !arg.isObject {
            return .JS_TRUE
        }

        return ctx.testIntegrityLevel(arg, level: .frozen) ? .JS_TRUE : .JS_FALSE
    }

    /// `Object.isSealed(obj)`
    /// Determines if an object is sealed.
    static func isSealed(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let arg = args.count > 0 ? args[0] : .undefined

        if !arg.isObject {
            return .JS_TRUE
        }

        return ctx.testIntegrityLevel(arg, level: .sealed) ? .JS_TRUE : .JS_FALSE
    }

    /// `Object.isExtensible(obj)`
    /// Determines if an object is extensible.
    static func isExtensible(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let arg = args.count > 0 ? args[0] : .undefined

        if !arg.isObject {
            return .JS_FALSE
        }

        return ctx.isExtensible(arg) ? .JS_TRUE : .JS_FALSE
    }

    /// `Object.preventExtensions(obj)`
    /// Prevents new properties from ever being added to an object.
    static func preventExtensions(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let arg = args.count > 0 ? args[0] : .undefined

        if !arg.isObject {
            return arg
        }

        let result = ctx.preventExtensions(arg)
        if result.isException { return result }

        return arg
    }

    /// `Object.fromEntries(iterable)`
    /// Transforms a list of key-value pairs into an object.
    static func fromEntries(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let iterable = args.count > 0 ? args[0] : .undefined

        if iterable.isNullOrUndefined {
            return ctx.throwTypeError("Cannot convert undefined or null to object")
        }

        let obj = ctx.newPlainObject()
        if obj.isException { return obj }

        // Get iterator
        let iter = ctx.getIterator(iterable, isAsync: false)
        if iter.isException { return iter }

        while true {
            let next = ctx.iteratorNext(iter: iter)
            if next.isException { return next }

            let done = ctx.getProperty(obj: next, atom: JSAtomID.done)
            if done.isException { return done }
            if ctx.toBoolFree(done) {
                break
            }

            let val = ctx.getProperty(obj: next, atom: JSAtomID.value)
            if val.isException {
                ctx.iteratorClose(iter: iter, isThrow: true)
                return val
            }

            // Each element must be an object (array-like [key, value])
            if !val.isObject {
                ctx.iteratorClose(iter: iter, isThrow: true)
                return ctx.throwTypeError("Iterator value is not an entry object")
            }

            let key = ctx.getPropertyByIndex(obj:val, index: 0)
            if key.isException {
                ctx.iteratorClose(iter: iter, isThrow: true)
                return key
            }

            let entryValue = ctx.getPropertyByIndex(obj:val, index: 1)
            if entryValue.isException {
                ctx.iteratorClose(iter: iter, isThrow: true)
                return entryValue
            }

            let propKey = ctx.toPropertyKey(key)
            if propKey.isException {
                ctx.iteratorClose(iter: iter, isThrow: true)
                return propKey
            }

            let ret = ctx.setProperty(obj: obj, key: propKey, value: entryValue)
            if ret < 0 {
                ctx.iteratorClose(iter: iter, isThrow: true)
                return .exception
            }
        }

        return obj
    }

    /// `Object.hasOwn(obj, prop)`
    /// ES2022: Returns true if the specified object has the indicated property as its own property.
    static func hasOwn(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = args.count > 0 ? args[0] : .undefined
        let prop = args.count > 1 ? args[1] : .undefined

        let o = ctx.toObject(obj)
        if o.isException { return o }

        let key = ctx.toPropertyKey(prop)
        if key.isException { return key }

        let has = ctx.hasOwnProperty(o, key: key)
        if has < 0 { return .exception }

        return has != 0 ? .JS_TRUE : .JS_FALSE
    }

    /// `Object.groupBy(items, callbackFn)`
    /// ES2024: Groups elements of an iterable according to a callback function.
    static func groupBy(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let items = args.count > 0 ? args[0] : .undefined
        let callbackFn = args.count > 1 ? args[1] : .undefined

        if items.isNullOrUndefined {
            return ctx.throwTypeError("Cannot convert undefined or null to object")
        }

        if !ctx.isCallable(callbackFn) {
            return ctx.throwTypeError("callback is not a function")
        }

        // Create a null-prototype object for the result
        let groups = ctx.newObjectWithProto(.null)
        if groups.isException { return groups }

        let iter = ctx.getIterator(items, isAsync: false)
        if iter.isException { return iter }

        var k: Int64 = 0
        while true {
            // Check index overflow
            if k >= Int64(JS_MAX_SAFE_INTEGER) {
                ctx.iteratorClose(iter: iter, isThrow: true)
                return ctx.throwTypeError("groupBy index overflow")
            }

            let next = ctx.iteratorNext(iter: iter)
            if next.isException { return next }

            let done = ctx.getProperty(obj: next, atom: JSAtomID.done)
            if done.isException { return done }
            if ctx.toBoolFree(done) {
                break
            }

            let val = ctx.getProperty(obj: next, atom: JSAtomID.value)
            if val.isException {
                ctx.iteratorClose(iter: iter, isThrow: true)
                return val
            }

            let kValue = ctx.newInt64(k)
            let key = ctx.call(callbackFn, thisArg: .undefined, args: [val, kValue])
            if key.isException {
                ctx.iteratorClose(iter: iter, isThrow: true)
                return key
            }

            // key must be coerced to a property key
            let propKey = ctx.toPropertyKey(key)
            if propKey.isException {
                ctx.iteratorClose(iter: iter, isThrow: true)
                return propKey
            }

            // Get or create the group array
            var group = ctx.getProperty(obj: groups, key: propKey)
            if group.isException {
                ctx.iteratorClose(iter: iter, isThrow: true)
                return group
            }

            if group.isUndefined {
                group = ctx.newArray()
                if group.isException {
                    ctx.iteratorClose(iter: iter, isThrow: true)
                    return group
                }
                let ret = ctx.setProperty(obj: groups, key: propKey, value: group)
                if ret < 0 {
                    ctx.iteratorClose(iter: iter, isThrow: true)
                    return .exception
                }
            }

            // Append val to the group array
            let groupLen = ctx.getArrayLength(group)
            ctx.setPropertyByIndex(obj:group, index: UInt32(groupLen), value: val)

            k += 1
        }

        return groups
    }

    // MARK: - Object.prototype methods

    /// `Object.prototype.toString()`
    /// Returns a string of the form "[object Type]".
    /// Mirrors `js_object_toString` in QuickJS with full @@toStringTag support.
    static func toString(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        // Spec: if this is undefined, return "[object Undefined]"
        if this.isUndefined {
            return ctx.newString("[object Undefined]")
        }
        // Spec: if this is null, return "[object Null]"
        if this.isNull {
            return ctx.newString("[object Null]")
        }

        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        // Check Symbol.toStringTag
        let tag = ctx.getProperty(obj: obj, atom: JSAtomID.Symbol_toStringTag)
        if tag.isException { return tag }

        if tag.isString {
            let tagStr = ctx.jsValueToString(tag)
            return ctx.newString("[object \(tagStr)]")
        }

        // Determine built-in tag
        let builtinTag: String
        if ctx.isArray(obj) {
            builtinTag = "Array"
        } else if ctx.isFunction(obj) {
            builtinTag = "Function"
        } else {
            let classID = ctx.getClassID(obj)
            switch classID {
            case JeffJSClassID.error.rawValue:
                builtinTag = "Error"
            case JeffJSClassID.boolean.rawValue:
                builtinTag = "Boolean"
            case JeffJSClassID.number.rawValue:
                builtinTag = "Number"
            case JeffJSClassID.string.rawValue:
                builtinTag = "String"
            case JeffJSClassID.date.rawValue:
                builtinTag = "Date"
            case JeffJSClassID.regexp.rawValue:
                builtinTag = "RegExp"
            case JeffJSClassID.arguments.rawValue, JeffJSClassID.mappedArguments.rawValue:
                builtinTag = "Arguments"
            default:
                builtinTag = "Object"
            }
        }

        return ctx.newString("[object \(builtinTag)]")
    }

    /// `Object.prototype.toLocaleString()`
    /// Calls this.toString().
    static func toLocaleString(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let toStr = ctx.getProperty(obj: this, atom: JSAtomID.toStringAtom)
        if toStr.isException { return toStr }

        if !ctx.isCallable(toStr) {
            return ctx.throwTypeError("toLocaleString: toString is not a function")
        }

        return ctx.call(toStr, thisArg: this, args: [])
    }

    /// `Object.prototype.valueOf()`
    /// Returns the primitive value of the specified object.
    static func valueOf(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        return ctx.toObject(this)
    }

    /// `Object.prototype.hasOwnProperty(prop)`
    /// Returns a boolean indicating whether the object has the specified property as its own property.
    static func hasOwnProperty(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let prop = args.count > 0 ? args[0] : .undefined

        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let key = ctx.toPropertyKey(prop)
        if key.isException { return key }

        let has = ctx.hasOwnProperty(obj, key: key)
        if has < 0 { return .exception }

        return has != 0 ? .JS_TRUE : .JS_FALSE
    }

    /// `Object.prototype.isPrototypeOf(v)`
    /// Checks if this object exists in another object's prototype chain.
    static func isPrototypeOf_(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let v = args.count > 0 ? args[0] : .undefined

        // If V is not an object, return false
        if !v.isObject {
            return .JS_FALSE
        }

        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        guard let thisObj = obj.toObject() else {
            return .JS_FALSE
        }

        // Walk V's prototype chain looking for O (using object identity)
        var current = v
        while true {
            guard let currentObj = current.toObject() else {
                return .JS_FALSE
            }
            guard let proto = currentObj.proto else {
                return .JS_FALSE
            }
            if proto === thisObj {
                return .JS_TRUE
            }
            current = JeffJSValue.makeObject(proto)
        }
    }

    /// `Object.prototype.propertyIsEnumerable(prop)`
    /// Returns a boolean indicating whether the specified property is enumerable and is the
    /// object's own property.
    static func propertyIsEnumerable(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let prop = args.count > 0 ? args[0] : .undefined

        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        let key = ctx.toPropertyKey(prop)
        if key.isException { return key }

        let desc = ctx.getOwnPropertyDescriptor(obj, key: key)
        if desc.isException { return desc }

        if desc.isUndefined {
            return .JS_FALSE
        }

        let enumerable = ctx.getProperty(obj: desc, atom: JSAtomID.enumerable)
        if enumerable.isException { return enumerable }

        return ctx.toBoolFree(enumerable) ? .JS_TRUE : .JS_FALSE
    }

    // MARK: - __proto__ getter/setter

    /// `get Object.prototype.__proto__`
    /// Returns the prototype of this object.
    static func protoGetter(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        return ctx.getPrototypeOf(obj)
    }

    /// `set Object.prototype.__proto__`
    /// Sets the prototype of this object.
    static func protoSetter(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let proto = args.count > 0 ? args[0] : .undefined

        // If this is not an object, silently return (per spec, non-object is no-op)
        if this.isNullOrUndefined {
            return ctx.throwTypeError("Cannot set __proto__ of null or undefined")
        }

        if !this.isObject {
            return .undefined
        }

        // proto must be an object or null
        if !proto.isObject && !proto.isNull {
            return .undefined
        }

        let success = ctx.setPrototypeOf(this, proto: proto)
        if !success {
            return ctx.throwTypeError("Cyclic __proto__ value")
        }

        return .undefined
    }

    // MARK: - __defineGetter__, __defineSetter__, __lookupGetter__, __lookupSetter__

    /// `Object.prototype.__defineGetter__(prop, func)`
    /// Binds an object's property to a function to be called when that property is looked up.
    static func defineGetter(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let prop = args.count > 0 ? args[0] : .undefined
        let getter = args.count > 1 ? args[1] : .undefined

        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        if !ctx.isCallable(getter) {
            return ctx.throwTypeError("__defineGetter__: getter is not a function")
        }

        let key = ctx.toPropertyKey(prop)
        if key.isException { return key }

        // Build a descriptor: { get: getter, enumerable: true, configurable: true }
        let desc = ctx.newPlainObject()
        if desc.isException { return desc }
        var ret = ctx.setProperty(obj: desc, atom: JSAtomID.get, value: getter)
        if ret < 0 { return .exception }
        ret = ctx.setProperty(obj: desc, atom: JSAtomID.enumerable, value: .JS_TRUE)
        if ret < 0 { return .exception }
        ret = ctx.setProperty(obj: desc, atom: JSAtomID.configurable, value: .JS_TRUE)
        if ret < 0 { return .exception }

        let result = ctx.definePropertyFromDescriptor(obj, key: key, desc: desc)
        if result.isException { return result }

        return .undefined
    }

    /// `Object.prototype.__defineSetter__(prop, func)`
    /// Binds an object's property to a function to be called when an attempt is made to set that property.
    static func defineSetter(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let prop = args.count > 0 ? args[0] : .undefined
        let setter = args.count > 1 ? args[1] : .undefined

        let obj = ctx.toObject(this)
        if obj.isException { return obj }

        if !ctx.isCallable(setter) {
            return ctx.throwTypeError("__defineSetter__: setter is not a function")
        }

        let key = ctx.toPropertyKey(prop)
        if key.isException { return key }

        // Build a descriptor: { set: setter, enumerable: true, configurable: true }
        let desc = ctx.newPlainObject()
        if desc.isException { return desc }
        var ret = ctx.setProperty(obj: desc, atom: JSAtomID.set, value: setter)
        if ret < 0 { return .exception }
        ret = ctx.setProperty(obj: desc, atom: JSAtomID.enumerable, value: .JS_TRUE)
        if ret < 0 { return .exception }
        ret = ctx.setProperty(obj: desc, atom: JSAtomID.configurable, value: .JS_TRUE)
        if ret < 0 { return .exception }

        let result = ctx.definePropertyFromDescriptor(obj, key: key, desc: desc)
        if result.isException { return result }

        return .undefined
    }

    /// `Object.prototype.__lookupGetter__(prop)`
    /// Returns the getter function bound to the specified property.
    static func lookupGetter(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let prop = args.count > 0 ? args[0] : .undefined

        var obj = ctx.toObject(this)
        if obj.isException { return obj }

        let key = ctx.toPropertyKey(prop)
        if key.isException { return key }

        // Walk the prototype chain
        while true {
            let desc = ctx.getOwnPropertyDescriptor(obj, key: key)
            if desc.isException { return desc }

            if !desc.isUndefined {
                let getter = ctx.getProperty(obj: desc, atom: JSAtomID.get)
                if getter.isException { return getter }
                if !getter.isUndefined {
                    return getter
                }
                // Data descriptor -- return undefined
                return .undefined
            }

            // Walk up prototype chain
            let proto = ctx.getPrototypeOf(obj)
            if proto.isException { return proto }
            if proto.isNull {
                return .undefined
            }
            obj = proto
        }
    }

    /// `Object.prototype.__lookupSetter__(prop)`
    /// Returns the setter function bound to the specified property.
    static func lookupSetter(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let prop = args.count > 0 ? args[0] : .undefined

        var obj = ctx.toObject(this)
        if obj.isException { return obj }

        let key = ctx.toPropertyKey(prop)
        if key.isException { return key }

        // Walk the prototype chain
        while true {
            let desc = ctx.getOwnPropertyDescriptor(obj, key: key)
            if desc.isException { return desc }

            if !desc.isUndefined {
                let setter = ctx.getProperty(obj: desc, atom: JSAtomID.set)
                if setter.isException { return setter }
                if !setter.isUndefined {
                    return setter
                }
                return .undefined
            }

            let proto = ctx.getPrototypeOf(obj)
            if proto.isException { return proto }
            if proto.isNull {
                return .undefined
            }
            obj = proto
        }
    }

    // MARK: - Internal helpers

    /// Internal implementation of Object.defineProperties.
    /// Mirrors `js_object_defineProperties` in QuickJS.
    private static func objectDefineProperties(ctx: JeffJSContext, obj: JeffJSValue, props: JeffJSValue) -> JeffJSValue {
        let propsObj = ctx.toObject(props)
        if propsObj.isException { return propsObj }

        let keysArr = ctx.getOwnPropertyNames(propsObj, flags: JS_GPN_STRING_MASK | JS_GPN_SYMBOL_MASK | JS_GPN_ENUM_ONLY)
        if keysArr.isException { return keysArr }

        // First pass: collect all descriptors (spec requires this before applying any)
        let len = ctx.getArrayLength(keysArr)
        var descriptors: [(key: JeffJSValue, desc: JeffJSValue)] = []
        descriptors.reserveCapacity(Int(len))

        for i in 0..<len {
            let key = ctx.getPropertyByIndex(obj:keysArr, index: UInt32(i))
            if key.isException { return key }

            let descValue = ctx.getProperty(obj: propsObj, key: key)
            if descValue.isException { return descValue }

            descriptors.append((key: key, desc: descValue))
        }

        // Second pass: apply all descriptors
        for (key, desc) in descriptors {
            let result = ctx.definePropertyFromDescriptor(obj, key: key, desc: desc)
            if result.isException { return result }
        }

        return obj
    }
}

// MARK: - Integrity level enum

/// Integrity levels for freeze/seal operations.
enum JeffJSIntegrityLevel {
    case sealed
    case frozen
}

// MARK: - Context protocol extensions for Object builtins

/// These are the context methods that the Object builtin relies on.
/// They mirror the internal helper functions in QuickJS that are called by the
/// Object methods. The actual JeffJSContext class will provide implementations;
/// these are declared as protocol extensions to define the interface.
protocol JeffJSContextObjectOps {
    // Object creation
    var objectPrototype: JeffJSValue { get }
    func newPlainObject() -> JeffJSValue
    func newObjectWithProto(_ proto: JeffJSValue) -> JeffJSValue
    func newArray() -> JeffJSValue
    func newConstructorFunc(name: String, fn: @escaping (JeffJSContext, JeffJSValue, JeffJSValue, [JeffJSValue]) -> JeffJSValue,
                            length: Int, proto: JeffJSValue) -> JeffJSValue

    // Property access
    func getProperty(_ obj: JeffJSValue, key: JeffJSValue) -> JeffJSValue
    func getProperty(_ obj: JeffJSValue, atom: JSAtom) -> JeffJSValue
    func getPropertyByIndex(_ obj: JeffJSValue, index: UInt32) -> JeffJSValue
    func setProperty(_ obj: JeffJSValue, key: JeffJSValue, value: JeffJSValue) -> Int32
    func setProperty(_ obj: JeffJSValue, atom: JSAtom, value: JeffJSValue) -> Int32
    func setPropertyByIndex(_ obj: JeffJSValue, index: UInt32, value: JeffJSValue) -> Int32
    func setPropertyFunc(obj: JeffJSValue, atom: JSAtom, fn: @escaping (JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue, length: Int)
    func setPropertyGetSet(obj: JeffJSValue, atom: JSAtom,
                           getter: @escaping (JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue,
                           setter: @escaping (JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue)
    func hasOwnProperty(_ obj: JeffJSValue, key: JeffJSValue) -> Int32

    // Prototype
    func getPrototypeOf(_ obj: JeffJSValue) -> JeffJSValue
    func setPrototypeOf(_ obj: JeffJSValue, proto: JeffJSValue) -> Bool

    // Property descriptors
    func getOwnPropertyDescriptor(_ obj: JeffJSValue, key: JeffJSValue) -> JeffJSValue
    func getOwnPropertyNames(_ obj: JeffJSValue, flags: Int) -> JeffJSValue
    func definePropertyFromDescriptor(_ obj: JeffJSValue, key: JeffJSValue, desc: JeffJSValue) -> JeffJSValue

    // Integrity
    func setIntegrityLevel(_ obj: JeffJSValue, level: JeffJSIntegrityLevel) -> JeffJSValue
    func testIntegrityLevel(_ obj: JeffJSValue, level: JeffJSIntegrityLevel) -> Bool
    func isExtensible(_ obj: JeffJSValue) -> Bool
    func preventExtensions(_ obj: JeffJSValue) -> JeffJSValue

    // Type checks
    func isCallable(_ val: JeffJSValue) -> Bool
    func isFunction(_ val: JeffJSValue) -> Bool
    func isArray(_ val: JeffJSValue) -> Bool
    func getClassID(_ val: JeffJSValue) -> UInt16
    func getArrayLength(_ val: JeffJSValue) -> Int64

    // Conversion
    func toObject(_ val: JeffJSValue) -> JeffJSValue
    func toPropertyKey(_ val: JeffJSValue) -> JeffJSValue
    func toBoolFree(_ val: JeffJSValue) -> Bool
    func jsValueToString(_ val: JeffJSValue) -> String
    func sameValue(_ x: JeffJSValue, _ y: JeffJSValue) -> Bool

    // Value creation
    func newString(_ str: String) -> JeffJSValue
    func newInt64(_ val: Int64) -> JeffJSValue
    func newAtom(_ str: String) -> JSAtom

    // Errors
    func throwTypeError(_ msg: String) -> JeffJSValue

    // Iterators
    func getIterator(_ obj: JeffJSValue, isAsync: Bool) -> JeffJSValue
    func iteratorNext(_ iter: JeffJSValue) -> JeffJSValue
    func iteratorClose(_ iter: JeffJSValue, isThrow: Bool)

    // Call
    func call(_ func_: JeffJSValue, thisArg: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue

    // Registration
    func setGlobalConstructor(name: String, ctor: JeffJSValue)
}
