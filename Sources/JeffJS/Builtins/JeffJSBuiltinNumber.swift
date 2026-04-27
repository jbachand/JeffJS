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

extension JeffJSContext {
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

    /// Wire constructor.prototype and prototype.constructor.
    /// Per ES spec, `constructor` on prototypes is writable+configurable but NOT enumerable.
    func setConstructorProto(ctor: JeffJSValue, proto: JeffJSValue) {
        _ = setPropertyStr(obj: ctor, name: "prototype", value: proto)
        let atom = rt.findAtom("constructor")
        _ = definePropertyValue(obj: proto, atom: atom, value: ctor,
                                flags: JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE)
        rt.freeAtom(atom)
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
        obj.shape = createShape(self, proto: protoObj, hashSize: 0, propSize: 0)
        obj.prop = []
        return JeffJSValue.makeObject(obj)
    }

    /// Create a new object from a new.target value.
    func newObjectFromNewTarget(newTarget: JeffJSValue, classID: Int) -> JeffJSValue {
        return newObjectClass(classID: classID)
    }

    /// Convert a value to an integer JeffJSValue (ToInteger semantics).
    func toInteger(_ val: JeffJSValue) -> JeffJSValue {
        if val.isInt { return val }
        if val.isFloat64 {
            let d = val.toFloat64()
            if d.isNaN { return .newInt32(0) }
            if d.isInfinite { return val }
            return .newFloat64(d >= 0 ? Foundation.floor(d) : Foundation.ceil(d))
        }
        return .newInt32(0)
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

    /// ToNumeric coercion. For now, delegates to toNumber-like behavior.
    func toNumeric(_ val: JeffJSValue) -> JeffJSValue {
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

    /// Convert BigInt to Float64 (approximate).
    func bigIntToFloat64(_ val: JeffJSValue) -> Double {
        if val.isInt { return Double(val.toInt32()) }
        if val.isFloat64 { return val.toFloat64() }
        return Double.nan
    }

}

// MARK: - JeffJSBuiltinNumber

struct JeffJSBuiltinNumber {

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
        ctx.classProto[JSClassID.JS_CLASS_NUMBER.rawValue] = proto

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
            return this
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
    /// For radix 10 this uses the standard double-to-string algorithm (DtoA).
    /// For other radices it uses the spec's algorithm.
    static func numberToStringRadix(_ d: Double, _ radix: Int) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        if d == 0 { return "0" }

        if radix == 10 {
            return numberToStringBase10(d)
        }

        // For non-base-10, handle the sign, then convert the magnitude
        let negative = d < 0
        var val = negative ? -d : d

        // Integer part
        var intPart = Foundation.floor(val)
        var fracPart = val - intPart

        let digits = "0123456789abcdefghijklmnopqrstuvwxyz"
        let digitsArray = Array(digits)

        // Build integer digits
        var intDigits = [Character]()
        if intPart == 0 {
            intDigits.append("0")
        } else {
            while intPart >= 1 {
                let digit = Int(intPart.truncatingRemainder(dividingBy: Double(radix)))
                intDigits.append(digitsArray[digit])
                intPart = Foundation.floor(intPart / Double(radix))
            }
            intDigits.reverse()
        }

        // Build fractional digits (up to ~52 / log2(radix) digits precision)
        var fracDigits = [Character]()
        if fracPart > 0 {
            let maxFracDigits = Int(ceil(52.0 / log2(Double(radix)))) + 1
            for _ in 0..<maxFracDigits {
                fracPart *= Double(radix)
                let digit = Int(fracPart)
                fracDigits.append(digitsArray[digit])
                fracPart -= Double(digit)
                if fracPart < 1e-15 { break }
            }
            // Remove trailing zeros
            while let last = fracDigits.last, last == "0" {
                fracDigits.removeLast()
            }
        }

        var result = ""
        if negative { result.append("-") }
        result.append(contentsOf: intDigits)
        if !fracDigits.isEmpty {
            result.append(".")
            result.append(contentsOf: fracDigits)
        }
        return result
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

        // Use Swift's default formatting which produces the shortest
        // round-trip-safe decimal representation.
        var s = "\(d)"
        // Ensure we don't produce trailing ".0" for exact integers
        // (already handled above, but just in case)
        if s.hasSuffix(".0") {
            s = String(s.dropLast(2))
        }
        return s
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
                return ctx.throwRangeError("toString() radix must be between 2 and 36")
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

    /// `Number.prototype.toFixed(fractionDigits)`
    static func toFixed(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let numVal = thisNumberValue(ctx: ctx, this: this)
        if numVal.isException {
            return ctx.throwTypeError("Number.prototype.toFixed requires that 'this' be a Number")
        }
        let f: Int
        if args.isEmpty {
            f = 0
        } else {
            let n = ctx.toInteger(args[0])
            if n.isException { return .exception }
            f = ctx.extractInt(n)
        }
        if f < 0 || f > 100 {
            return ctx.throwRangeError("toFixed() digits argument must be between 0 and 100")
        }
        let d = extractDouble(numVal)
        if d.isNaN { return ctx.newStringValue("NaN") }
        if d.isInfinite || Swift.abs(d) >= 1e21 {
            return ctx.newStringValue(numberToStringBase10(d))
        }

        // Use the spec-compliant fixed-point formatting
        let result = toFixedInternal(d, f)
        return ctx.newStringValue(result)
    }

    /// Internal toFixed implementation following the spec algorithm.
    private static func toFixedInternal(_ x: Double, _ f: Int) -> String {
        let negative = x < 0
        let val = negative ? -x : x

        var result: String
        if val >= 1e21 {
            result = numberToStringBase10(val)
        } else {
            // Use String(format:) for proper rounding
            result = String(format: "%.\(f)f", val)
        }
        if negative && result != "0" && !result.allSatisfy({ $0 == "0" || $0 == "." }) {
            result = "-" + result
        }
        return result
    }

    /// `Number.prototype.toExponential(fractionDigits)`
    static func toExponential(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let numVal = thisNumberValue(ctx: ctx, this: this)
        if numVal.isException {
            return ctx.throwTypeError("Number.prototype.toExponential requires that 'this' be a Number")
        }
        let d = extractDouble(numVal)
        if d.isNaN { return ctx.newStringValue("NaN") }
        if d.isInfinite {
            return ctx.newStringValue(d > 0 ? "Infinity" : "-Infinity")
        }

        let f: Int?
        if args.isEmpty || args[0].isUndefined {
            f = nil
        } else {
            let n = ctx.toInteger(args[0])
            if n.isException { return .exception }
            let fVal = ctx.extractInt(n)
            if fVal < 0 || fVal > 100 {
                return ctx.throwRangeError("toExponential() argument must be between 0 and 100")
            }
            f = fVal
        }

        let result = toExponentialInternal(d, f)
        return ctx.newStringValue(result)
    }

    private static func toExponentialInternal(_ x: Double, _ fractionDigits: Int?) -> String {
        let negative = x < 0
        let val = negative ? -x : x

        if val == 0 {
            var result = "0"
            if let f = fractionDigits, f > 0 {
                result.append(".")
                result.append(String(repeating: "0", count: f))
            }
            result.append("e+0")
            if negative { result = "-" + result }
            return result
        }

        var result: String
        if let f = fractionDigits {
            result = String(format: "%.\(f)e", val)
        } else {
            // Use the minimum number of digits needed
            result = String(format: "%e", val)
            // Remove trailing zeros in the mantissa
            if let dotIdx = result.firstIndex(of: "."),
               let eIdx = result.firstIndex(of: "e") {
                var mantissa = String(result[dotIdx..<eIdx])
                while mantissa.hasSuffix("0") {
                    mantissa = String(mantissa.dropLast())
                }
                if mantissa == "." {
                    mantissa = ""
                }
                let intPart = String(result[result.startIndex..<dotIdx])
                let expPart = String(result[eIdx...])
                result = intPart + mantissa + expPart
            }
        }

        // Normalize the exponent format: remove leading zeros, ensure +/- sign
        if let eIdx = result.firstIndex(of: "e") {
            let expStr = String(result[result.index(after: eIdx)...])
            let sign: String
            var magnitude: String
            if expStr.hasPrefix("-") {
                sign = "-"
                magnitude = String(expStr.dropFirst())
            } else if expStr.hasPrefix("+") {
                sign = "+"
                magnitude = String(expStr.dropFirst())
            } else {
                sign = "+"
                magnitude = expStr
            }
            // Remove leading zeros from magnitude
            while magnitude.count > 1 && magnitude.hasPrefix("0") {
                magnitude = String(magnitude.dropFirst())
            }
            let prefix = String(result[result.startIndex...eIdx])
            result = prefix + sign + magnitude
        }

        if negative { result = "-" + result }
        return result
    }

    /// `Number.prototype.toPrecision(precision)`
    static func toPrecision(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let numVal = thisNumberValue(ctx: ctx, this: this)
        if numVal.isException {
            return ctx.throwTypeError("Number.prototype.toPrecision requires that 'this' be a Number")
        }
        let d = extractDouble(numVal)

        if args.isEmpty || args[0].isUndefined {
            return ctx.newStringValue(numberToStringBase10(d))
        }

        if d.isNaN { return ctx.newStringValue("NaN") }
        if d.isInfinite {
            return ctx.newStringValue(d > 0 ? "Infinity" : "-Infinity")
        }

        let pVal = ctx.toInteger(args[0])
        if pVal.isException { return .exception }
        let p = ctx.extractInt(pVal)
        if p < 1 || p > 100 {
            return ctx.throwRangeError("toPrecision() argument must be between 1 and 100")
        }

        let result = toPrecisionInternal(d, p)
        return ctx.newStringValue(result)
    }

    private static func toPrecisionInternal(_ x: Double, _ precision: Int) -> String {
        let negative = x < 0
        let val = negative ? -x : x

        if val == 0 {
            var result = "0"
            if precision > 1 {
                result.append(".")
                result.append(String(repeating: "0", count: precision - 1))
            }
            if negative { result = "-" + result }
            return result
        }

        // Compute the exponent (number of digits before/after decimal point)
        let e = Int(Foundation.floor(Foundation.log10(val)))

        var result: String
        if e < -6 || e >= precision {
            // Use exponential notation
            result = String(format: "%.\(precision - 1)e", val)
            // Normalize exponent
            if let eIdx = result.firstIndex(of: "e") {
                let expStr = String(result[result.index(after: eIdx)...])
                let sign: String
                var magnitude: String
                if expStr.hasPrefix("-") {
                    sign = "-"
                    magnitude = String(expStr.dropFirst())
                } else if expStr.hasPrefix("+") {
                    sign = "+"
                    magnitude = String(expStr.dropFirst())
                } else {
                    sign = "+"
                    magnitude = expStr
                }
                while magnitude.count > 1 && magnitude.hasPrefix("0") {
                    magnitude = String(magnitude.dropFirst())
                }
                let prefix = String(result[result.startIndex...eIdx])
                result = prefix + sign + magnitude
            }
        } else {
            // Use fixed notation
            let fracDigits = precision - e - 1
            if fracDigits >= 0 {
                result = String(format: "%.\(fracDigits)f", val)
            } else {
                result = String(format: "%.0f", val)
            }
        }

        // Remove trailing zeros after the decimal point (but keep the point
        // if digits remain after it)
        if result.contains(".") {
            while result.hasSuffix("0") {
                result = String(result.dropLast())
            }
            if result.hasSuffix(".") {
                result = String(result.dropLast())
            }
        }

        if negative { result = "-" + result }
        return result
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

struct JeffJSBuiltinBoolean {

    // MARK: - Intrinsic Registration

    /// Install `Boolean`, `Boolean.prototype`, and all methods onto `ctx`.
    static func addIntrinsic(ctx: JeffJSContext) {
        // 1. Create Boolean.prototype (a Boolean wrapper with [[BooleanData]] = false)
        let proto = ctx.newObject(classID: JeffJSClassID.boolean.rawValue)
        ctx.setObjectData(proto, value: JeffJSValue.JS_FALSE)

        // Update classProto so auto-boxing (e.g., true.toString()) finds
        // Boolean.prototype methods when getPropertyInternal looks them up.
        ctx.classProto[JSClassID.JS_CLASS_BOOLEAN.rawValue] = proto

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
            return this
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

struct JeffJSBuiltinBigInt {

    // MARK: - Helpers

    /// Extract the BigInt value from `this`, handling both primitive BigInts
    /// and BigInt wrapper objects.
    private static func thisBigIntValue(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
        if this.isBigInt || this.isShortBigInt {
            return this
        }
        if this.isObject {
            if this.toObject() != nil {
                let data = ctx.getObjectData(this)
                if data.isBigInt || data.isShortBigInt {
                    return data
                }
            }
        }
        return .exception
    }

    /// Convert a BigInt value to a Swift Int64 (truncating for large values).
    private static func bigIntToInt64(_ val: JeffJSValue) -> Int64 {
        if val.isInt { return Int64(val.toInt32()) }
        if val.isBigInt, let bi = val.toBigInt() {
            let magnitude = bi.limbs.first ?? 0
            let result = Int64(bitPattern: magnitude)
            return bi.sign ? -result : result
        }
        return 0
    }

    /// Convert a BigInt value to a Swift UInt64 (truncating for large values).
    private static func bigIntToUInt64(_ val: JeffJSValue) -> UInt64 {
        if val.isInt { return UInt64(bitPattern: Int64(val.toInt32())) }
        if val.isBigInt, let bi = val.toBigInt() {
            let magnitude = bi.limbs.first ?? 0
            return bi.sign ? UInt64(bitPattern: -Int64(bitPattern: magnitude)) : magnitude
        }
        return 0
    }

    /// Convert an unsigned integer to a string in the given radix (2-36).
    private static func uint64ToString(_ value: UInt64, radix: Int) -> String {
        if value == 0 { return "0" }
        let digits = "0123456789abcdefghijklmnopqrstuvwxyz"
        let digitsArray = Array(digits)
        var result = [Character]()
        var v = value
        let r = UInt64(radix)
        while v > 0 {
            result.append(digitsArray[Int(v % r)])
            v /= r
        }
        result.reverse()
        return String(result)
    }

    // MARK: - BigInt.prototype.toString(radix?)

    /// `BigInt.prototype.toString([radix])`
    static func toString(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let bigVal = thisBigIntValue(ctx: ctx, this: this)
        if bigVal.isException {
            return ctx.throwTypeError("BigInt.prototype.toString requires that 'this' be a BigInt")
        }

        var radix = 10
        if !args.isEmpty && !args[0].isUndefined {
            let r = ctx.toInteger(args[0])
            if r.isException { return .exception }
            radix = ctx.extractInt(r)
            if radix < 2 || radix > 36 {
                return ctx.throwRangeError("toString() radix must be between 2 and 36")
            }
        }

        // Handle int values (shortBigInt promoted to int in NaN-boxed mode)
        if bigVal.isInt {
            let v = Int64(bigVal.toInt32())
            if radix == 10 { return ctx.newStringValue(String(v)) }
            let negative = v < 0
            let magnitude = negative ? UInt64(bitPattern: -v) : UInt64(bitPattern: v)
            var str = uint64ToString(magnitude, radix: radix)
            if negative { str = "-" + str }
            return ctx.newStringValue(str)
        }

        // Handle heap BigInt
        if let bi = bigVal.toBigInt() {
            if bi.limbs.isEmpty || (bi.limbs.count == 1 && bi.limbs[0] == 0) {
                return ctx.newStringValue("0")
            }
            let magnitude = bi.limbs.first ?? 0
            if radix == 10 {
                if bi.sign {
                    return ctx.newStringValue("-" + String(magnitude))
                }
                return ctx.newStringValue(String(magnitude))
            }
            var str = uint64ToString(magnitude, radix: radix)
            if bi.sign { str = "-" + str }
            return ctx.newStringValue(str)
        }

        return ctx.newStringValue("0")
    }

    // MARK: - BigInt.prototype.valueOf()

    /// `BigInt.prototype.valueOf()`
    static func valueOf(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let bigVal = thisBigIntValue(ctx: ctx, this: this)
        if bigVal.isException {
            return ctx.throwTypeError("BigInt.prototype.valueOf requires that 'this' be a BigInt")
        }
        return bigVal
    }

    // MARK: - BigInt.prototype.toLocaleString()

    /// `BigInt.prototype.toLocaleString()` — delegates to toString for now.
    static func toLocaleString(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        return toString(ctx: ctx, this: this, args: args)
    }

    // MARK: - BigInt.asIntN(bits, bigint)

    /// `BigInt.asIntN(bits, bigint)` — Truncate a BigInt to fit in a signed integer of the given bit width.
    static func asIntN(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 2 else {
            return ctx.throwTypeError("BigInt.asIntN requires 2 arguments")
        }

        let bitsVal = ctx.toInteger(args[0])
        if bitsVal.isException { return .exception }
        let bits = ctx.extractInt(bitsVal)
        if bits < 0 {
            return ctx.throwRangeError("Invalid bit width")
        }

        let bigVal = args[1]
        guard bigVal.isBigInt || bigVal.isShortBigInt else {
            return ctx.throwTypeError("Cannot convert non-BigInt to BigInt")
        }

        if bits == 0 {
            return JeffJSValue.mkShortBigInt(0)
        }

        let value = bigIntToInt64(bigVal)

        if bits >= 64 {
            // No truncation needed for values that fit in Int64
            return JeffJSValue.mkShortBigInt(value)
        }

        // Truncate to `bits` width and sign-extend
        let mask = bits == 64 ? UInt64.max : (UInt64(1) << bits) - 1
        let truncated = UInt64(bitPattern: value) & mask
        // Sign extend: check the sign bit
        let signBit = UInt64(1) << (bits - 1)
        let result: Int64
        if truncated & signBit != 0 {
            // Negative: extend sign bits
            result = Int64(bitPattern: truncated | ~mask)
        } else {
            result = Int64(bitPattern: truncated)
        }
        return JeffJSValue.mkShortBigInt(result)
    }

    // MARK: - BigInt.asUintN(bits, bigint)

    /// `BigInt.asUintN(bits, bigint)` — Truncate a BigInt to fit in an unsigned integer of the given bit width.
    static func asUintN(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 2 else {
            return ctx.throwTypeError("BigInt.asUintN requires 2 arguments")
        }

        let bitsVal = ctx.toInteger(args[0])
        if bitsVal.isException { return .exception }
        let bits = ctx.extractInt(bitsVal)
        if bits < 0 {
            return ctx.throwRangeError("Invalid bit width")
        }

        let bigVal = args[1]
        guard bigVal.isBigInt || bigVal.isShortBigInt else {
            return ctx.throwTypeError("Cannot convert non-BigInt to BigInt")
        }

        if bits == 0 {
            return JeffJSValue.mkShortBigInt(0)
        }

        let value = bigIntToUInt64(bigVal)

        if bits >= 64 {
            // No truncation needed for values that fit in UInt64
            return JeffJSValue.mkShortBigInt(Int64(bitPattern: value))
        }

        // Truncate to `bits` width (unsigned, no sign extension)
        let mask = (UInt64(1) << bits) - 1
        let result = value & mask
        return JeffJSValue.mkShortBigInt(Int64(bitPattern: result))
    }
}
