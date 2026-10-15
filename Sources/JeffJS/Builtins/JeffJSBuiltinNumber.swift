// JeffJSBuiltinNumber.swift
// JeffJS - 1:1 Swift port of QuickJS JavaScript engine
//
// Complete port of the Number and Boolean built-ins: constructors,
// static properties/methods, prototype methods, and the global
// parseInt/parseFloat/isNaN/isFinite functions.
//
// All IEEE 754 constants use their exact double-precision values.

import Foundation

// MARK: - JeffJSContext helpers for Number/Boolean builtins

nonisolated extension JeffJSContext {
    /// Create an object with a given class ID (delegates to newObjectClass).
    func newObject(classID: Int) -> JeffJSValue {
        return newObjectClass(classID: classID)
    }

    /// Set the [[ObjectData]] internal slot.
    func setObjectData(_ obj: JeffJSValue, value: JeffJSValue) {
        if let jsObj = obj.toObject() {
            jsObj.payload = JeffJSObjectPayload.objectData(value)
        }
    }

    /// Wire constructor.prototype and prototype.constructor with the spec's
    /// attributes (defineIntrinsicPrototypeLink). Consumes `proto`, like the
    /// setPropertyStr it replaced; `proto.constructor` takes a new count.
    func setConstructorProto(ctor: JeffJSValue, proto: JeffJSValue) {
        defineIntrinsicPrototypeLink(ctor: ctor, proto: proto)
        proto.freeValue()
    }

    /// Define a property by name (convenience wrapper around atom-based definePropertyValue).
    func definePropertyValue(_ obj: JeffJSValue, name: String, value: JeffJSValue, flags: Int) -> Int {
        let atom = rt.findAtom(name)
        defer { rt.freeAtom(atom) }
        return definePropertyValue(obj: obj, atom: atom, value: value, flags: flags)
    }

    /// Install a global function.
    func setGlobalFunc(name: String, fn: @escaping JeffJSNativeFunc, length: Int) {
        setPropertyFunc(obj: globalObj, name: name, fn: fn, length: length)
    }

    /// Install a global value.
    func setGlobalValue(name: String, value: JeffJSValue) {
        _ = setPropertyStr(obj: globalObj, name: name, value: value)
    }

    /// setGlobalConstructor with proto parameter (installs proto on ctor too).
    func setGlobalConstructor(name: String, ctor: JeffJSValue, proto: JeffJSValue) {
        setConstructorProto(ctor: ctor, proto: proto)
        setGlobalConstructor(name: name, ctor: ctor)
    }

    /// Create a constructor/function CFunction by wrapping a closure.
    func newCFunction(
        name: String,
        length: Int,
        cproto: JSCFunctionType
    ) -> JeffJSValue {
        let obj = JeffJSObject()
        obj.classID = JSClassID.JS_CLASS_C_FUNCTION.rawValue
        obj.extensible = true
        obj.isConstructor = true
        obj.payload = .cFunc(
            realm: self,
            cFunction: cproto,
            length: UInt8(min(length, Int(UInt8.max))),
            cproto: UInt8(JS_CFUNC_CONSTRUCTOR_OR_FUNC),
            magic: 0
        )
        // Create a shape so properties (like static methods) can be added.
        let protoObj = functionProto.isObject ? functionProto.toObject() : nil
        obj.shape = jeffJS_rootShape(self, proto: protoObj)
        obj.clearProps()
        // [[Prototype]] is Function.prototype (ES §10.3): lookups read obj.proto,
        // not the shape's — String/Number/Boolean had none, so `String + ""`
        // threw "Cannot convert object to primitive value" (core-js's
        // inspectSource does `String(String)`: Adobe's sync.js, lowes' vendors),
        // and `String.name` / `.length` (ES §10.2.9, §10.2.10) were missing.
        // akamai navigation fix, 2026-09-29.
        obj.proto = protoObj
        let funcVal = JeffJSValue.makeObject(obj)
        definePropertyValue(obj: funcVal, atom: JeffJSAtomID.JS_ATOM_length.rawValue,
                            value: JeffJSValue.newInt32(Int32(length)), flags: JS_PROP_CONFIGURABLE)
        let nameVal = newStringValue(name)
        definePropertyValue(obj: funcVal, atom: JeffJSAtomID.JS_ATOM_name.rawValue, value: nameVal, flags: JS_PROP_CONFIGURABLE)
        nameVal.freeValue()   // definePropertyValue dups
        return funcVal
    }

    /// Create a new object from a new.target value.
    func newObjectFromNewTarget(newTarget: JeffJSValue, classID: Int) -> JeffJSValue {
        return newObjectClass(classID: classID)
    }

    /// Convert a value to an integer JeffJSValue (ToInteger semantics).
    /// ToIntegerOrInfinity: strings, booleans, null, undefined and objects go
    /// through ToNumber (objects via valueOf/toString, which may throw), NaN is 0,
    /// ±Infinity is kept. Returns an int or float64 value, or `.exception`.
    func toInteger(_ val: JeffJSValue) -> JeffJSValue {
        if val.isInt { return val }
        let d: Double
        if val.isFloat64 {
            d = val.toFloat64()
        } else {
            if val.isBigInt { return throwTypeError(message: "Cannot convert a BigInt value to a number") }
            if val.isSymbol { return throwTypeError(message: "Cannot convert a symbol to a number") }
            let (n, ok) = JeffJSTypeConvert.toNumber(ctx: self, val: val)
            if !ok { return .exception }
            d = n
        }
        if d.isNaN { return .newInt32(0) }
        if d.isInfinite { return .newFloat64(d) }
        let t = d >= 0 ? Foundation.floor(d) : Foundation.ceil(d)
        if t >= -2147483648.0 && t <= 2147483647.0 { return .newInt32(Int32(t)) }
        return .newFloat64(t)
    }

    /// Extract an Int from a JeffJSValue that is known to be a number.
    func extractInt(_ val: JeffJSValue) -> Int {
        if val.isInt { return Int(val.toInt32()) }
        if val.isFloat64 {
            let d = val.toFloat64()
            if d.isNaN || d.isInfinite { return d > 0 ? Int.max / 2 : (d < 0 ? Int.min / 2 : 0) }
            if d > Double(Int.max / 2) { return Int.max / 2 }
            if d < Double(Int.min / 2) { return Int.min / 2 }
            return Int(d)
        }
        return 0
    }

    /// Extract a Double from a JeffJSValue that is known to be a number.
    func extractDouble(_ val: JeffJSValue) -> Double {
        if val.isInt { return Double(val.toInt32()) }
        if val.isFloat64 { return val.toFloat64() }
        return Double.nan
    }

    /// ToNumeric coercion — BigInts survive, everything else becomes a Number.
    func toNumeric(_ val: JeffJSValue) -> JeffJSValue {
        if val.isBigInt { return val }
        // Only an object can turn into a BigInt through ToPrimitive; keep the
        // string/number path on the original (faster) conversion.
        if val.isObject { return toNumericValue(val) }
        return toNumber(val)
    }

    /// ToBooleanFree: convert to Bool and free the value.
    func toBooleanFree(_ val: JeffJSValue) -> Bool {
        if val.isBool { return val.toBool() }
        if val.isInt { return val.toInt32() != 0 }
        if val.isFloat64 { let d = val.toFloat64(); return !d.isNaN && d != 0 }
        if val.isNull || val.isUndefined { return false }
        if val.isString, let s = val.stringValue { return !s.toSwiftString().isEmpty }
        if val.isObject { return true }
        return false
    }

    /// Convert BigInt to Float64 (`Number(1n)`); rounds like ToNumber would.
    func bigIntToFloat64(_ val: JeffJSValue) -> Double {
        if val.isInt { return Double(val.toInt32()) }
        if val.isFloat64 { return val.toFloat64() }
        if val.isBigInt { return JeffJSBigIntOps.toDouble(val) }
        return Double.nan
    }

}

// MARK: - JeffJSBuiltinNumber

nonisolated struct JeffJSBuiltinNumber {

    // MARK: - IEEE 754 Constants

    /// Number.MAX_VALUE = largest positive finite IEEE 754 double
    static let MAX_VALUE: Double = 1.7976931348623157e+308

    /// Number.MIN_VALUE = smallest positive subnormal IEEE 754 double
    static let MIN_VALUE: Double = 5e-324

    /// Number.EPSILON = 2^-52 (difference between 1 and smallest float > 1)
    static let EPSILON: Double = 2.220446049250313e-16

    /// Number.MAX_SAFE_INTEGER = 2^53 - 1
    static let MAX_SAFE_INTEGER: Double = 9007199254740991.0

    /// Number.MIN_SAFE_INTEGER = -(2^53 - 1)
    static let MIN_SAFE_INTEGER: Double = -9007199254740991.0

    // MARK: - Intrinsic Registration

    /// Install `Number`, `Number.prototype`, and all methods onto `ctx`.
    static func addIntrinsic(ctx: JeffJSContext) {
        // 1. Create Number.prototype (a Number wrapper with [[NumberData]] = +0)
        let proto = ctx.newObject(classID: JeffJSClassID.number.rawValue)
        ctx.setObjectData(proto, value: JeffJSValue.newInt32(0))

        // Update classProto so auto-boxing (e.g., (42).toString()) finds
        // Number.prototype methods when getPropertyInternal looks them up.
        ctx.classProto[JSClassID.JS_CLASS_NUMBER.rawValue] = proto.dupValue()

        // 2. Create the Number constructor
        let ctor = ctx.newCFunction(
            name: "Number",
            length: 1,
            cproto: .constructorOrFunc({ c, this, args, isNew in
                numberConstructor(ctx: c, newTarget: isNew ? this : .undefined,
                                  this: this, args: args)
            })
        )

        // 3. Wire constructor.prototype = proto, proto.constructor = ctor
        ctx.setConstructorProto(ctor: ctor, proto: proto)

        // 4. Static properties
        ctx.definePropertyValue(ctor, name: "MAX_VALUE",
                                value: JeffJSValue.newFloat64(MAX_VALUE), flags: 0)
        ctx.definePropertyValue(ctor, name: "MIN_VALUE",
                                value: JeffJSValue.newFloat64(MIN_VALUE), flags: 0)
        ctx.definePropertyValue(ctor, name: "NaN",
                                value: JeffJSValue.JS_NAN, flags: 0)
        ctx.definePropertyValue(ctor, name: "NEGATIVE_INFINITY",
                                value: JeffJSValue.JS_NEGATIVE_INFINITY, flags: 0)
        ctx.definePropertyValue(ctor, name: "POSITIVE_INFINITY",
                                value: JeffJSValue.JS_POSITIVE_INFINITY, flags: 0)
        ctx.definePropertyValue(ctor, name: "EPSILON",
                                value: JeffJSValue.newFloat64(EPSILON), flags: 0)
        ctx.definePropertyValue(ctor, name: "MAX_SAFE_INTEGER",
                                value: JeffJSValue.newFloat64(MAX_SAFE_INTEGER), flags: 0)
        ctx.definePropertyValue(ctor, name: "MIN_SAFE_INTEGER",
                                value: JeffJSValue.newFloat64(MIN_SAFE_INTEGER), flags: 0)

        // 5. Static methods
        ctx.setPropertyFunc(obj: ctor, name: "isNaN",        fn: isNaN,        length: 1)
        ctx.setPropertyFunc(obj: ctor, name: "isFinite",     fn: isFinite,     length: 1)
        ctx.setPropertyFunc(obj: ctor, name: "isInteger",    fn: isInteger,    length: 1)
        ctx.setPropertyFunc(obj: ctor, name: "isSafeInteger", fn: isSafeInteger, length: 1)
        ctx.setPropertyFunc(obj: ctor, name: "parseInt",     fn: parseInt,     length: 2)
        ctx.setPropertyFunc(obj: ctor, name: "parseFloat",   fn: parseFloat,   length: 1)

        // 6. Prototype methods
        ctx.setPropertyFunc(obj: proto, name: "toString",       fn: toString,       length: 1)
        ctx.setPropertyFunc(obj: proto, name: "toLocaleString", fn: toLocaleString, length: 0)
        ctx.setPropertyFunc(obj: proto, name: "valueOf",        fn: valueOf,        length: 0)
        ctx.setPropertyFunc(obj: proto, name: "toFixed",        fn: toFixed,        length: 1)
        ctx.setPropertyFunc(obj: proto, name: "toExponential",  fn: toExponential,  length: 1)
        ctx.setPropertyFunc(obj: proto, name: "toPrecision",    fn: toPrecision,    length: 1)

        // 7. Register Number and Number.prototype on the global object
        ctx.setGlobalConstructor(name: "Number", ctor: ctor, proto: proto)

        // 8. Global functions: parseInt, parseFloat, isNaN, isFinite
        ctx.setGlobalFunc(name: "parseInt",    fn: globalParseInt,    length: 2)
        ctx.setGlobalFunc(name: "parseFloat",  fn: globalParseFloat,  length: 1)
        ctx.setGlobalFunc(name: "isNaN",       fn: globalIsNaN,       length: 1)
        ctx.setGlobalFunc(name: "isFinite",    fn: globalIsFinite,    length: 1)

        // 9. Global NaN and Infinity
        ctx.setGlobalValue(name: "NaN",      value: JeffJSValue.JS_NAN)
        ctx.setGlobalValue(name: "Infinity", value: JeffJSValue.JS_POSITIVE_INFINITY)
    }

    // MARK: - Internal Helpers

    /// Unwrap the numeric value from `this`, handling both primitive numbers
    /// and Number wrapper objects.  Mirrors QuickJS `thisNumberValue`.
    static func thisNumberValue(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
        if this.isInt || this.isFloat64 {
            return this.dupValue()   // the caller releases this argument; the result is a new reference
        }
        if this.isObject {
            if let obj = this.toObject(), obj.classID == JeffJSClassID.number.rawValue {
                let data = ctx.getObjectData(this)
                if data.isInt || data.isFloat64 {
                    return data
                }
            }
        }
        return .exception
    }

    /// Extract the double value from a JeffJSValue that is known to be a number.
    @inline(__always)
    static func extractDouble(_ val: JeffJSValue) -> Double {
        if val.isInt { return Double(val.toInt32()) }
        if val.isFloat64 { return val.toFloat64() }
        return Double.nan
    }

    /// Parse a radix argument, defaulting to 10.
    static func getRadix(ctx: JeffJSContext, val: JeffJSValue) -> Int? {
        if val.isUndefined || val.isNull {
            return 10
        }
        guard let n = ctx.toInt32(val) else { return nil }
        let radix = Int(n)
        if radix < 2 || radix > 36 {
            return nil
        }
        return radix
    }

    /// Convert a double to a string in a given radix (2-36).
    /// Radix 10 is ES Number::toString. Other radices print what
    /// JavaScriptCore prints (`toStringWithRadixInternal`, NumberPrototype.cpp):
    /// the integer part exactly (every digit of a double above 2^53, not a
    /// float division's rounding), and the shortest fraction that still
    /// identifies the double — digits are written while the remainder is at
    /// least half the gap to the neighbouring doubles, rounding half to even —
    /// computed in exact binary arithmetic. `(123.456).toString(36)` is
    /// "3f.gez4w97ry" (it was "3f.gez4w97ry0a1": a fixed 52-bit digit budget),
    /// `(2**60).toString(36)` "8rc4kbdvss1s" (was "…ss0s"). Bot-defence
    /// scripts print Math.random() in base 36.
    static func numberToStringRadix(_ d: Double, _ radix: Int) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        if d == 0 { return "0" }

        if radix == 10 {
            return numberToStringBase10(d)
        }

        let digitChars: [UInt8] = Array("0123456789abcdefghijklmnopqrstuvwxyz".utf8)
        let negative = d < 0
        let number = negative ? -d : d
        var integerPart = Foundation.floor(number)
        let fractionPart = number - integerPart
        var fracDigits: [UInt8] = []

        if fractionPart != 0 {
            // integerPart < 2^53 here (a double with a fraction is below 2^52).
            let integerPartIsOdd = (UInt64(integerPart) & 1) == 1
            var isOddInOddRadix = integerPartIsOdd
            var digit = integerPartIsOdd ? 1 : 0
            let r = UInt32(radix)
            var fraction = RadixFixedPoint(fractionPart, halve: false)
            let deltaNext = number.nextUp - number
            let deltaLast = number - number.nextDown
            var halfNext = RadixFixedPoint(deltaNext, halve: true)
            var halfLast = RadixFixedPoint(deltaLast, halve: true)
            var roundUp = false
            while true {
                let c = fraction.compareHalf()
                if c > 0 || (c == 0 && ((radix & 1) == 1 ? isOddInOddRadix : (digit & 1) == 1)) {
                    if fraction.sumGreaterThanOne(halfNext) { roundUp = true; break }
                } else if fraction.isLess(than: halfLast) {
                    break
                }
                fraction.multiply(by: r)
                digit = fraction.floorAndSubtract()
                if (digit & 1) == 1 { isOddInOddRadix.toggle() }
                fracDigits.append(digitChars[digit])
                halfNext.multiply(by: r)
                halfLast.multiply(by: r)
                if fracDigits.count > 1100 { break }   // cannot happen; bounds the loop
            }
            if roundUp {
                while let last = fracDigits.last, last == digitChars[radix - 1] { fracDigits.removeLast() }
                if let last = fracDigits.last {
                    fracDigits[fracDigits.count - 1] = (last == UInt8(ascii: "9")) ? UInt8(ascii: "a") : last + 1
                } else {
                    integerPart += 1
                }
            } else {
                while let last = fracDigits.last, last == UInt8(ascii: "0") { fracDigits.removeLast() }
            }
        }

        // Integer digits, exact (a double integer up to 2^1024 as a big integer).
        var limbs = RadixFixedPoint.integerLimbs(integerPart)
        var intDigits: [UInt8] = []
        repeat {
            var rem: UInt64 = 0
            var i = limbs.count - 1
            while i >= 0 {
                let cur = (rem << 32) | UInt64(limbs[i])
                limbs[i] = UInt32(cur / UInt64(radix))
                rem = cur % UInt64(radix)
                i -= 1
            }
            intDigits.append(digitChars[Int(rem)])
            while let top = limbs.last, top == 0 { limbs.removeLast() }
        } while !limbs.isEmpty

        var out: [UInt8] = []
        out.reserveCapacity(intDigits.count + fracDigits.count + 2)
        if negative { out.append(UInt8(ascii: "-")) }
        out.append(contentsOf: intDigits.reversed())
        if !fracDigits.isEmpty {
            out.append(UInt8(ascii: "."))
            out.append(contentsOf: fracDigits)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Standard Number-to-String for base 10, matching the ECMAScript spec
    /// (ToString applied to a Number value). Uses Swift's built-in formatting
    /// which conforms to the IEEE 754 round-trip requirements.
    static func numberToStringBase10(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d == 0 { return "0" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }

        // Check if it is an integer value in the safe range
        if d == Foundation.floor(d) && Swift.abs(d) <= MAX_SAFE_INTEGER {
            let i = Int64(d)
            return String(i)
        }

        return jeffJS_formatDoubleJS(d)
    }

    // MARK: - Constructor

    /// `Number(value)` / `new Number(value)`
    static func numberConstructor(ctx: JeffJSContext, newTarget: JeffJSValue,
                                   this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let n: JeffJSValue
        if args.isEmpty {
            n = JeffJSValue.newInt32(0)
        } else {
            let prim = ctx.toNumeric(args[0])
            if prim.isException { return .exception }
            if prim.isBigInt {
                // BigInt -> Number conversion is not allowed as constructor, but
                // Number(bigint) should return a number
                let d = ctx.bigIntToFloat64(prim)
                n = JeffJSValue.newFloat64(d)
            } else {
                n = prim
            }
        }

        // Called as function: return the primitive number
        if newTarget.isUndefined {
            return n
        }

        // Called as constructor: return a Number wrapper object
        let obj = ctx.newObjectFromNewTarget(newTarget: newTarget, classID: JeffJSClassID.number.rawValue)
        if obj.isException { return .exception }
        ctx.setObjectData(obj, value: n)
        return obj
    }

    // MARK: - Static Methods

    /// `Number.isNaN(value)` - strict isNaN (no type coercion)
    static func isNaN(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let val = args.isEmpty ? JeffJSValue.undefined : args[0]
        if !val.isNumber { return .JS_FALSE }
        let d = extractDouble(val)
        return JeffJSValue.newBool(d.isNaN)
    }

    /// `Number.isFinite(value)` - strict isFinite (no type coercion)
    static func isFinite(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let val = args.isEmpty ? JeffJSValue.undefined : args[0]
        if !val.isNumber { return .JS_FALSE }
        let d = extractDouble(val)
        return JeffJSValue.newBool(d.isFinite)
    }

    /// `Number.isInteger(value)`
    static func isInteger(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let val = args.isEmpty ? JeffJSValue.undefined : args[0]
        if !val.isNumber { return .JS_FALSE }
        let d = extractDouble(val)
        if d.isNaN || d.isInfinite { return .JS_FALSE }
        return JeffJSValue.newBool(d == Foundation.floor(d))
    }

    /// `Number.isSafeInteger(value)`
    static func isSafeInteger(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let val = args.isEmpty ? JeffJSValue.undefined : args[0]
        if !val.isNumber { return .JS_FALSE }
        let d = extractDouble(val)
        if d.isNaN || d.isInfinite { return .JS_FALSE }
        if d != Foundation.floor(d) { return .JS_FALSE }
        return JeffJSValue.newBool(Swift.abs(d) <= MAX_SAFE_INTEGER)
    }

    /// `Number.parseInt(string, radix)` - same as global parseInt
    static func parseInt(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        return globalParseInt(ctx: ctx, this: this, args: args)
    }

    /// `Number.parseFloat(string)` - same as global parseFloat
    static func parseFloat(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        return globalParseFloat(ctx: ctx, this: this, args: args)
    }

    // MARK: - Prototype Methods

    /// `Number.prototype.toString([radix])`
    static func toString(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let numVal = thisNumberValue(ctx: ctx, this: this)
        if numVal.isException {
            return ctx.throwTypeError("Number.prototype.toString requires that 'this' be a Number")
        }
        let radix: Int
        if args.isEmpty || args[0].isUndefined {
            radix = 10
        } else {
            let r = ctx.toInteger(args[0])
            if r.isException { return .exception }
            radix = ctx.extractInt(r)
            if radix < 2 || radix > 36 {
                return ctx.throwRangeError("toString() radix argument must be between 2 and 36")
            }
        }
        let d = extractDouble(numVal)
        return ctx.newStringValue(numberToStringRadix(d, radix))
    }

    /// `Number.prototype.toLocaleString([locales [, options]])`
    static func toLocaleString(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let numVal = thisNumberValue(ctx: ctx, this: this)
        if numVal.isException {
            return ctx.throwTypeError("Number.prototype.toLocaleString requires that 'this' be a Number")
        }
        let d = extractDouble(numVal)
        if d.isNaN { return ctx.newStringValue("NaN") }
        if d.isInfinite {
            return ctx.newStringValue(d > 0 ? "Infinity" : "-Infinity")
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal

        if !args.isEmpty && !args[0].isUndefined {
            let locStr = ctx.toString(args[0])
            if locStr.isException { return .exception }
            formatter.locale = Locale(identifier: ctx.toSwiftString(locStr) ?? "")
        } else {
            formatter.locale = Locale.current
        }

        let result = formatter.string(from: NSNumber(value: d)) ?? numberToStringBase10(d)
        return ctx.newStringValue(result)
    }

    /// `Number.prototype.valueOf()`
    static func valueOf(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let numVal = thisNumberValue(ctx: ctx, this: this)
        if numVal.isException {
            return ctx.throwTypeError("Number.prototype.valueOf requires that 'this' be a Number")
        }
        return numVal
    }

    /// ToIntegerOrInfinity on a builtin's argument, as a Double (±Infinity kept).
    /// `nil` when the conversion threw.
    private static func integerOrInfinityArg(ctx: JeffJSContext, _ args: [JeffJSValue], _ i: Int) -> Double? {
        let v = ctx.toInteger(i < args.count ? args[i] : .undefined)
        if v.isException { return nil }
        return ctx.extractDouble(v)
    }

    /// `Number.prototype.toFixed(fractionDigits)` — ES2025 §21.1.3.3.
    static func toFixed(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let numVal = thisNumberValue(ctx: ctx, this: this)
        if numVal.isException {
            return ctx.throwTypeError("Number.prototype.toFixed requires that 'this' be a Number")
        }
        let d = extractDouble(numVal)
        // 2-4: f = ToIntegerOrInfinity(fractionDigits); RangeError before the finiteness check.
        guard let f = integerOrInfinityArg(ctx: ctx, args, 0) else { return .exception }
        if !f.isFinite || f < 0 || f > 100 {
            return ctx.throwRangeError("toFixed() argument must be between 0 and 100")
        }
        // 5, 8: non-finite and |x| >= 1e21 use Number::toString.
        if !d.isFinite || Swift.abs(d) >= 1e21 {
            return ctx.newStringValue(numberToStringBase10(d))
        }
        return ctx.newStringValue(jsNumberToFixed(d, fractionDigits: Int(f)))
    }

    /// `Number.prototype.toExponential(fractionDigits)` — ES2025 §21.1.3.2.
    static func toExponential(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let numVal = thisNumberValue(ctx: ctx, this: this)
        if numVal.isException {
            return ctx.throwTypeError("Number.prototype.toExponential requires that 'this' be a Number")
        }
        let d = extractDouble(numVal)
        // 2: f = ToIntegerOrInfinity(fractionDigits), before the finiteness check.
        let undefinedDigits = args.isEmpty || args[0].isUndefined
        guard let f = integerOrInfinityArg(ctx: ctx, args, 0) else { return .exception }
        // 4: non-finite values stringify; 5: then the range check.
        if !d.isFinite { return ctx.newStringValue(numberToStringBase10(d)) }
        if !f.isFinite || f < 0 || f > 100 {
            return ctx.throwRangeError("toExponential() argument must be between 0 and 100")
        }
        return ctx.newStringValue(jsNumberToExponential(d, fractionDigits: undefinedDigits ? nil : Int(f)))
    }

    /// `Number.prototype.toPrecision(precision)` — ES2025 §21.1.3.5.
    static func toPrecision(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let numVal = thisNumberValue(ctx: ctx, this: this)
        if numVal.isException {
            return ctx.throwTypeError("Number.prototype.toPrecision requires that 'this' be a Number")
        }
        let d = extractDouble(numVal)
        // 2: undefined precision is ToString(x).
        if args.isEmpty || args[0].isUndefined {
            return ctx.newStringValue(numberToStringBase10(d))
        }
        // 3: p = ToIntegerOrInfinity(precision), before the finiteness check.
        guard let p = integerOrInfinityArg(ctx: ctx, args, 0) else { return .exception }
        // 4: non-finite values stringify; 5: then the range check.
        if !d.isFinite { return ctx.newStringValue(numberToStringBase10(d)) }
        if !p.isFinite || p < 1 || p > 100 {
            return ctx.throwRangeError("toPrecision() argument must be between 1 and 100")
        }
        return ctx.newStringValue(jsNumberToPrecision(d, precision: Int(p)))
    }

    // MARK: - Global Number Functions

    /// `parseInt(string, radix)` - the global parseInt function.
    /// Full implementation with all radix handling (2-36), legacy octal,
    /// hex prefix, whitespace skipping.
    static func globalParseInt(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let inputVal = args.isEmpty ? JeffJSValue.undefined : args[0]
        let inputStr = ctx.toString(inputVal)
        if inputStr.isException { return .exception }
        let str = ctx.toSwiftString(inputStr) ?? ""

        // Step 1: skip leading whitespace
        var chars = Array(str.unicodeScalars)
        var pos = 0
        while pos < chars.count && isParseIntWhitespace(chars[pos]) {
            pos += 1
        }

        if pos >= chars.count {
            return JeffJSValue.JS_NAN
        }

        // Step 2: determine sign
        var sign: Double = 1.0
        if chars[pos].value == 0x2B { // '+'
            pos += 1
        } else if chars[pos].value == 0x2D { // '-'
            sign = -1.0
            pos += 1
        }

        // Step 3: determine radix
        var radix: Int
        if args.count >= 2 && !args[1].isUndefined {
            guard let r = ctx.toInt32(args[1]) else { return .exception }
            radix = Int(r)
            if radix == 0 {
                radix = 10
            } else if radix < 2 || radix > 36 {
                return JeffJSValue.JS_NAN
            }
        } else {
            radix = 10
        }

        // Step 4: check for 0x/0X prefix (hex)
        if pos < chars.count && chars[pos].value == 0x30 { // '0'
            if pos + 1 < chars.count {
                let next = chars[pos + 1].value
                if next == 0x78 || next == 0x58 { // 'x' or 'X'
                    if radix == 10 || radix == 16 {
                        radix = 16
                        pos += 2
                    }
                } else if radix == 10 {
                    // Legacy octal: only when radix argument was not provided
                    if args.count < 2 || args[1].isUndefined {
                        // ECMAScript 5+: do NOT interpret as octal
                        // (parseInt("010") should return 10, not 8)
                        radix = 10
                    }
                }
            }
        }

        // Step 5: parse digits
        var result: Double = 0.0
        var hasDigit = false
        let radixDouble = Double(radix)

        while pos < chars.count {
            let c = chars[pos].value
            let digit = parseIntDigitValue(UInt32(c))
            if digit < 0 || digit >= radix {
                break
            }
            hasDigit = true
            result = result * radixDouble + Double(digit)
            pos += 1
        }

        if !hasDigit {
            return JeffJSValue.JS_NAN
        }

        result *= sign
        return JeffJSValue.newFloat64(result)
    }

    /// Helper: determine the digit value of a character for parseInt.
    private static func parseIntDigitValue(_ c: UInt32) -> Int {
        if c >= 0x30 && c <= 0x39 { return Int(c - 0x30) }       // '0'-'9'
        if c >= 0x41 && c <= 0x5A { return Int(c - 0x41) + 10 }  // 'A'-'Z'
        if c >= 0x61 && c <= 0x7A { return Int(c - 0x61) + 10 }  // 'a'-'z'
        return -1
    }

    /// Helper: check if a unicode scalar is whitespace for parseInt purposes.
    private static func isParseIntWhitespace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020,
             0x00A0, 0x1680,
             0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005,
             0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// `parseFloat(string)` - the global parseFloat function.
    static func globalParseFloat(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let inputVal = args.isEmpty ? JeffJSValue.undefined : args[0]
        let inputStr = ctx.toString(inputVal)
        if inputStr.isException { return .exception }
        let str = ctx.toSwiftString(inputStr) ?? ""

        // Skip leading whitespace
        var trimmed = str.drop { c in
            guard let s = c.unicodeScalars.first else { return false }
            return isParseIntWhitespace(s)
        }

        if trimmed.isEmpty {
            return JeffJSValue.JS_NAN
        }

        // Check for Infinity
        if trimmed.hasPrefix("Infinity") || trimmed.hasPrefix("+Infinity") {
            return JeffJSValue.JS_POSITIVE_INFINITY
        }
        if trimmed.hasPrefix("-Infinity") {
            return JeffJSValue.JS_NEGATIVE_INFINITY
        }

        // Determine sign
        var sign: Double = 1.0
        if trimmed.hasPrefix("-") {
            sign = -1.0
            trimmed = trimmed.dropFirst()
        } else if trimmed.hasPrefix("+") {
            trimmed = trimmed.dropFirst()
        }

        // Parse the number: digits, optional decimal point, optional exponent
        var result: Double = 0.0
        var hasDigit = false
        var hasDot = false
        var fracDiv: Double = 1.0
        var chars = Array(trimmed)
        var pos = 0

        // Integer + fractional part
        while pos < chars.count {
            let c = chars[pos]
            if c >= "0" && c <= "9" {
                hasDigit = true
                let digit = Double(c.asciiValue! - 48)
                if hasDot {
                    fracDiv *= 10.0
                    result += digit / fracDiv
                } else {
                    result = result * 10.0 + digit
                }
                pos += 1
            } else if c == "." && !hasDot {
                hasDot = true
                pos += 1
            } else {
                break
            }
        }

        if !hasDigit {
            return JeffJSValue.JS_NAN
        }

        // Exponent part
        if pos < chars.count && (chars[pos] == "e" || chars[pos] == "E") {
            pos += 1
            var expSign: Double = 1.0
            if pos < chars.count && chars[pos] == "+" {
                pos += 1
            } else if pos < chars.count && chars[pos] == "-" {
                expSign = -1.0
                pos += 1
            }
            var exp: Double = 0.0
            var hasExpDigit = false
            while pos < chars.count && chars[pos] >= "0" && chars[pos] <= "9" {
                hasExpDigit = true
                exp = exp * 10.0 + Double(chars[pos].asciiValue! - 48)
                pos += 1
            }
            if hasExpDigit {
                result *= Foundation.pow(10.0, exp * expSign)
            }
        }

        result *= sign
        return JeffJSValue.newFloat64(result)
    }

    /// `isNaN(value)` - global isNaN with type coercion
    static func globalIsNaN(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let val = args.isEmpty ? JeffJSValue.undefined : args[0]
        let numVal = ctx.toNumber(val)
        if numVal.isException { return .exception }
        let d = ctx.extractDouble(numVal)
        return JeffJSValue.newBool(d.isNaN)
    }

    /// `isFinite(value)` - global isFinite with type coercion
    static func globalIsFinite(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let val = args.isEmpty ? JeffJSValue.undefined : args[0]
        let numVal = ctx.toNumber(val)
        if numVal.isException { return .exception }
        let d = ctx.extractDouble(numVal)
        return JeffJSValue.newBool(d.isFinite)
    }
}

// MARK: - JeffJSBuiltinBoolean

nonisolated struct JeffJSBuiltinBoolean {

    // MARK: - Intrinsic Registration

    /// Install `Boolean`, `Boolean.prototype`, and all methods onto `ctx`.
    static func addIntrinsic(ctx: JeffJSContext) {
        // 1. Create Boolean.prototype (a Boolean wrapper with [[BooleanData]] = false)
        let proto = ctx.newObject(classID: JeffJSClassID.boolean.rawValue)
        ctx.setObjectData(proto, value: JeffJSValue.JS_FALSE)

        // Update classProto so auto-boxing (e.g., true.toString()) finds
        // Boolean.prototype methods when getPropertyInternal looks them up.
        ctx.classProto[JSClassID.JS_CLASS_BOOLEAN.rawValue] = proto.dupValue()

        // 2. Create the Boolean constructor
        let ctor = ctx.newCFunction(
            name: "Boolean",
            length: 1,
            cproto: .constructorOrFunc({ c, this, args, isNew in
                booleanConstructor(ctx: c, newTarget: isNew ? this : .undefined,
                                   this: this, args: args)
            })
        )

        // 3. Wire constructor.prototype = proto, proto.constructor = ctor
        ctx.setConstructorProto(ctor: ctor, proto: proto)

        // 4. Prototype methods
        ctx.setPropertyFunc(obj: proto, name: "toString", fn: toString, length: 0)
        ctx.setPropertyFunc(obj: proto, name: "valueOf",  fn: valueOf,  length: 0)

        // 5. Register Boolean on the global object
        ctx.setGlobalConstructor(name: "Boolean", ctor: ctor, proto: proto)
    }

    // MARK: - Internal Helpers

    /// Unwrap the boolean value from `this`, handling both primitive booleans
    /// and Boolean wrapper objects.
    static func thisBooleanValue(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
        if this.isBool {
            return this.dupValue()   // the caller releases this argument; the result is a new reference
        }
        if this.isObject {
            if let obj = this.toObject(), obj.classID == JeffJSClassID.boolean.rawValue {
                let data = ctx.getObjectData(this)
                if data.isBool {
                    return data
                }
            }
        }
        return .exception
    }

    // MARK: - Constructor

    /// `Boolean(value)` / `new Boolean(value)`
    static func booleanConstructor(ctx: JeffJSContext, newTarget: JeffJSValue,
                                    this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let b: Bool
        if args.isEmpty {
            b = false
        } else {
            b = ctx.toBooleanFree(args[0])
        }

        let boolVal = JeffJSValue.newBool(b)

        // Called as function: return the primitive boolean
        if newTarget.isUndefined {
            return boolVal
        }

        // Called as constructor: return a Boolean wrapper object
        let obj = ctx.newObjectFromNewTarget(newTarget: newTarget, classID: JeffJSClassID.boolean.rawValue)
        if obj.isException { return .exception }
        ctx.setObjectData(obj, value: boolVal)
        return obj
    }

    // MARK: - Prototype Methods

    /// `Boolean.prototype.toString()`
    static func toString(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let boolVal = thisBooleanValue(ctx: ctx, this: this)
        if boolVal.isException {
            return ctx.throwTypeError("Boolean.prototype.toString requires that 'this' be a Boolean")
        }
        let b = boolVal.toBool()
        return ctx.newStringValue(b ? "true" : "false")
    }

    /// `Boolean.prototype.valueOf()`
    static func valueOf(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let boolVal = thisBooleanValue(ctx: ctx, this: this)
        if boolVal.isException {
            return ctx.throwTypeError("Boolean.prototype.valueOf requires that 'this' be a Boolean")
        }
        return boolVal
    }
}

// MARK: - JeffJSBuiltinBigInt

nonisolated struct JeffJSBuiltinBigInt {

    /// `this` as a BigInt primitive, unwrapping a `BigInt` wrapper object.
    /// Returns `.exception` (without throwing) when `this` is neither.
    private static func thisBigIntValue(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
        if this.isBigInt { return this }
        if this.isObject, let obj = this.toObject() {
            // Wrappers built by `Object(1n)` store the primitive in
            // `primitiveValue`; `new Number()`-style builtins use the
            // `.objectData` payload. Accept both.
            let pv = obj.primitiveValue
            if pv.isBigInt { return pv }
            let data = ctx.getObjectData(this)
            if data.isBigInt { return data }
        }
        return .exception
    }

    // MARK: - BigInt.prototype.toString(radix?)

    static func toString(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let bigVal = thisBigIntValue(ctx: ctx, this: this)
        if bigVal.isException {
            return ctx.throwTypeError(message: "BigInt.prototype.toString requires that 'this' be a BigInt")
        }
        var radix = 10
        if !args.isEmpty && !args[0].isUndefined {
            let r = ctx.toInteger(args[0])
            if r.isException { return .exception }
            radix = ctx.extractInt(r)
            if radix < 2 || radix > 36 {
                return ctx.throwRangeError(message: "toString() radix argument must be between 2 and 36")
            }
        }
        return JeffJSBigIntOps.toStringValue(ctx: ctx, bigVal, radix: radix)
    }

    // MARK: - BigInt.prototype.valueOf()

    static func valueOf(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let bigVal = thisBigIntValue(ctx: ctx, this: this)
        if bigVal.isException {
            return ctx.throwTypeError(message: "BigInt.prototype.valueOf requires that 'this' be a BigInt")
        }
        return bigVal.dupValue()
    }

    // MARK: - BigInt.prototype.toLocaleString()

    static func toLocaleString(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let bigVal = thisBigIntValue(ctx: ctx, this: this)
        if bigVal.isException {
            return ctx.throwTypeError(message: "BigInt.prototype.toLocaleString requires that 'this' be a BigInt")
        }
        // Group the digits like Number.prototype.toLocaleString does.
        let digits = JeffJSBigIntOps.toSwiftString(bigVal)
        var body = Substring(digits)
        var sign = ""
        if body.hasPrefix("-") { sign = "-"; body = body.dropFirst() }
        var grouped = ""
        for (i, c) in body.enumerated() {
            if i > 0 && (body.count - i) % 3 == 0 { grouped.append(",") }
            grouped.append(c)
        }
        return ctx.newStringValue(sign + grouped)
    }

    // MARK: - BigInt.asIntN / asUintN

    private static func bitsArg(ctx: JeffJSContext, _ args: [JeffJSValue]) -> Int? {
        let bitsVal = ctx.toInteger(args.isEmpty ? .undefined : args[0])
        if bitsVal.isException { return nil }
        let bits = ctx.extractInt(bitsVal)
        if bits < 0 || bits > (1 << 24) {
            _ = ctx.throwRangeError(message: "Invalid bit width")
            return nil
        }
        return bits
    }

    /// `BigInt.asIntN(bits, bigint)`
    static func asIntN(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let bits = bitsArg(ctx: ctx, args) else { return .exception }
        let v = ctx.toBigIntValue(args.count > 1 ? args[1] : .undefined)
        if v.isException { return .exception }
        defer { v.freeValue() }
        if bits == 0 { return JeffJSValue.newBigInt(0) }
        return JeffJSValue.newBigInt(JBigInt.asIntN(bits, v.bigIntValue))
    }

    /// `BigInt.asUintN(bits, bigint)`
    static func asUintN(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let bits = bitsArg(ctx: ctx, args) else { return .exception }
        let v = ctx.toBigIntValue(args.count > 1 ? args[1] : .undefined)
        if v.isException { return .exception }
        defer { v.freeValue() }
        if bits == 0 { return JeffJSValue.newBigInt(0) }
        return JeffJSValue.newBigInt(JBigInt.asUintN(bits, v.bigIntValue))
    }
}


/// ES Number::toString(10): Swift's description supplies the shortest
/// round-trip digits; this lays them out with the spec's rules (plain digits
/// when the decimal exponent n is in (-6, 21], exponent form otherwise, and
/// the exponent written without zero padding). Swift's own layout differs:
/// "1e-07" for 1e-7, "1e+20" for 1e20 (JS: "100000000000000000000").
nonisolated func jeffJS_formatDoubleJS(_ d: Double) -> String {
    let negative = d < 0
    let s = "\(Swift.abs(d))"
    var mant = Substring(s)
    var exp10 = 0
    if let ei = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        mant = s[s.startIndex..<ei]
        exp10 = Int(s[s.index(after: ei)...]) ?? 0
    }
    var digits: [Character]
    var pointPos: Int
    if let dot = mant.firstIndex(of: ".") {
        let intPart = mant[mant.startIndex..<dot]
        let frac = mant[mant.index(after: dot)...]
        digits = Array(intPart) + Array(frac)
        pointPos = intPart.count
    } else {
        digits = Array(mant)
        pointPos = digits.count
    }
    while digits.count > 1 && digits.first == "0" { digits.removeFirst(); pointPos -= 1 }
    while digits.count > 1 && digits.last == "0" { digits.removeLast() }
    let n = pointPos + exp10
    let k = digits.count
    var out = ""
    if k <= n && n <= 21 {
        out = String(digits) + String(repeating: "0", count: n - k)
    } else if 0 < n && n <= 21 {
        out = String(digits[0..<n]) + "." + String(digits[n...])
    } else if -6 < n && n <= 0 {
        out = "0." + String(repeating: "0", count: -n) + String(digits)
    } else {
        let e = n - 1
        let expStr = (e >= 0 ? "+" : "-") + String(Swift.abs(e))
        out = k == 1 ? String(digits) + "e" + expStr
                     : String(digits[0]) + "." + String(digits[1...]) + "e" + expStr
    }
    return negative ? "-" + out : out
}


/// Exact non-negative binary fixed point for `numberToStringRadix`: value =
/// N / 2^scaleBits, N in little-endian 32-bit limbs. Every double below 2 is
/// exact here (the smallest half-gap is 2^-1075), and multiplying by a radix
/// (≤ 36) only grows the integer bits the loop floors away.
nonisolated struct RadixFixedPoint {
    static let scaleBits = 1088          // 34 limbs of fraction
    static let limbCount = 36            // + 2 limbs of integer headroom
    var limbs: [UInt32]

    /// `value` (or value / 2 when `halve`) for a finite 0 ≤ value < 2.
    init(_ value: Double, halve: Bool) {
        limbs = [UInt32](repeating: 0, count: RadixFixedPoint.limbCount)
        if value == 0 { return }
        let bits = value.bitPattern
        let expField = Int((bits >> 52) & 0x7FF)
        var mantissa = bits & 0xF_FFFF_FFFF_FFFF
        var exp: Int
        if expField == 0 { exp = -1074 } else { mantissa |= 1 << 52; exp = expField - 1075 }
        if halve { exp -= 1 }
        let shift = RadixFixedPoint.scaleBits + exp     // ≥ 1088 - 1075 > 0
        var m = mantissa
        var bit = shift
        while m != 0 {
            let limb = bit / 32, off = bit % 32
            let chunk = m & 0xFFFF_FFFF
            let wide = chunk << UInt64(off)
            if limb < limbs.count { limbs[limb] |= UInt32(truncatingIfNeeded: wide) }
            if limb + 1 < limbs.count { limbs[limb + 1] |= UInt32(truncatingIfNeeded: wide >> 32) }
            m >>= 32
            bit += 32
        }
    }

    /// Limbs of a non-negative double integer (exact).
    static func integerLimbs(_ value: Double) -> [UInt32] {
        if value < 1 { return [0] }
        let bits = value.bitPattern
        let expField = Int((bits >> 52) & 0x7FF)
        let mantissa = (bits & 0xF_FFFF_FFFF_FFFF) | (1 << 52)
        let exp = expField - 1075
        if exp <= 0 { let v = mantissa >> UInt64(-exp); return [UInt32(v & 0xFFFF_FFFF), UInt32(v >> 32)] }
        var out = [UInt32](repeating: 0, count: (exp + 53) / 32 + 2)
        let limb = exp / 32, off = UInt64(exp % 32)
        let lo = (mantissa & 0xFFFF_FFFF) << off, hi = (mantissa >> 32) << off
        out[limb] |= UInt32(truncatingIfNeeded: lo)
        out[limb + 1] |= UInt32(truncatingIfNeeded: lo >> 32) | UInt32(truncatingIfNeeded: hi)
        out[limb + 2] |= UInt32(truncatingIfNeeded: hi >> 32)
        while let top = out.last, top == 0, out.count > 1 { out.removeLast() }
        return out
    }

    mutating func multiply(by r: UInt32) {
        var carry: UInt64 = 0
        for i in 0..<limbs.count {
            let v = UInt64(limbs[i]) * UInt64(r) + carry
            limbs[i] = UInt32(v & 0xFFFF_FFFF)
            carry = v >> 32
        }
    }

    /// The integer part (a digit < radix); leaves the fraction.
    mutating func floorAndSubtract() -> Int {
        let base = RadixFixedPoint.scaleBits / 32
        var v = 0
        for i in stride(from: limbs.count - 1, through: base, by: -1) { v = v << 32 | Int(limbs[i]); limbs[i] = 0 }
        return v
    }

    /// -1 / 0 / 1 as the value is below / equal to / above 1/2.
    func compareHalf() -> Int {
        let base = RadixFixedPoint.scaleBits / 32
        for i in base..<limbs.count where limbs[i] != 0 { return 1 }
        let top = limbs[base - 1]
        if top > 0x8000_0000 { return 1 }
        if top < 0x8000_0000 { return -1 }
        for i in 0..<(base - 1) where limbs[i] != 0 { return 1 }
        return 0
    }

    func isLess(than o: RadixFixedPoint) -> Bool {
        for i in stride(from: limbs.count - 1, through: 0, by: -1) where limbs[i] != o.limbs[i] { return limbs[i] < o.limbs[i] }
        return false
    }

    /// self + o > 1
    func sumGreaterThanOne(_ o: RadixFixedPoint) -> Bool {
        var sum = [UInt32](repeating: 0, count: limbs.count)
        var carry: UInt64 = 0
        for i in 0..<limbs.count {
            let v = UInt64(limbs[i]) + UInt64(o.limbs[i]) + carry
            sum[i] = UInt32(v & 0xFFFF_FFFF); carry = v >> 32
        }
        let base = RadixFixedPoint.scaleBits / 32
        var intPart: UInt64 = carry
        for i in stride(from: limbs.count - 1, through: base, by: -1) { intPart = intPart << 32 | UInt64(sum[i]) }
        if intPart > 1 { return true }
        if intPart < 1 { return false }
        for i in 0..<base where sum[i] != 0 { return true }
        return false
    }
}
