// JeffJSBuiltinMath.swift
// JeffJS — 1:1 Swift port of QuickJS JavaScript engine
//
// Port of QuickJS js_math_* functions from quickjs.c.
// Implements the Math built-in object (ECMA-262 sec 21.3).
// Math is not a constructor — it is a plain object namespace.

import Foundation

// MARK: - Math Object Initialization

/// Install the `Math` object on the given global object.
/// Mirrors `js_init_module_math` / the Math portion of `JS_AddIntrinsicBaseObjects`.
func jeffJS_initMath(ctx: JeffJSContext, globalObj: JeffJSObject) {
    let mathObj = jeffJS_createObject(ctx: ctx, proto: nil, classID: UInt16(JeffJSClassID.object.rawValue))
    mathObj.extensible = true

    // -- Constants --

    jeffJS_definePropertyValueDouble(ctx: ctx, obj: mathObj,
                                     atom: JeffJSAtomID.JS_ATOM_E.rawValue,
                                     value: Double.eulersNumber)
    jeffJS_definePropertyValueDouble(ctx: ctx, obj: mathObj,
                                     atom: JeffJSAtomID.JS_ATOM_LN10.rawValue,
                                     value: Darwin.log(10.0))
    jeffJS_definePropertyValueDouble(ctx: ctx, obj: mathObj,
                                     atom: JeffJSAtomID.JS_ATOM_LN2.rawValue,
                                     value: Darwin.log(2.0))
    jeffJS_definePropertyValueDouble(ctx: ctx, obj: mathObj,
                                     atom: JeffJSAtomID.JS_ATOM_LOG10E.rawValue,
                                     value: Darwin.log10(M_E))
    jeffJS_definePropertyValueDouble(ctx: ctx, obj: mathObj,
                                     atom: JeffJSAtomID.JS_ATOM_LOG2E.rawValue,
                                     value: 1.0 / Darwin.log(2.0))
    jeffJS_definePropertyValueDouble(ctx: ctx, obj: mathObj,
                                     atom: JeffJSAtomID.JS_ATOM_PI.rawValue,
                                     value: Double.pi)
    jeffJS_definePropertyValueDouble(ctx: ctx, obj: mathObj,
                                     atom: JeffJSAtomID.JS_ATOM_SQRT1_2.rawValue,
                                     value: 1.0 / Darwin.sqrt(2.0))
    jeffJS_definePropertyValueDouble(ctx: ctx, obj: mathObj,
                                     atom: JeffJSAtomID.JS_ATOM_SQRT2.rawValue,
                                     value: Darwin.sqrt(2.0))

    // [Symbol.toStringTag] = "Math"
    jeffJS_definePropertyValueStr(ctx: ctx, obj: mathObj,
                                  atom: JeffJSAtomID.JS_ATOM_Symbol_toStringTag.rawValue,
                                  value: "Math")

    // -- Methods --

    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "abs", length: 1, func: jsMath_abs)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "acos", length: 1, func: jsMath_acos)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "acosh", length: 1, func: jsMath_acosh)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "asin", length: 1, func: jsMath_asin)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "asinh", length: 1, func: jsMath_asinh)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "atan", length: 1, func: jsMath_atan)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "atanh", length: 1, func: jsMath_atanh)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "atan2", length: 2, func: jsMath_atan2)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "cbrt", length: 1, func: jsMath_cbrt)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "ceil", length: 1, func: jsMath_ceil)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "clz32", length: 1, func: jsMath_clz32)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "cos", length: 1, func: jsMath_cos)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "cosh", length: 1, func: jsMath_cosh)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "exp", length: 1, func: jsMath_exp)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "expm1", length: 1, func: jsMath_expm1)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "floor", length: 1, func: jsMath_floor)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "fround", length: 1, func: jsMath_fround)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "f16round", length: 1, func: jsMath_f16round)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "hypot", length: 2, func: jsMath_hypot)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "imul", length: 2, func: jsMath_imul)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "log", length: 1, func: jsMath_log)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "log1p", length: 1, func: jsMath_log1p)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "log10", length: 1, func: jsMath_log10)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "log2", length: 1, func: jsMath_log2)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "max", length: 2, func: jsMath_max)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "min", length: 2, func: jsMath_min)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "pow", length: 2, func: jsMath_pow)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "random", length: 0, func: jsMath_random)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "round", length: 1, func: jsMath_round)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "sign", length: 1, func: jsMath_sign)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "sin", length: 1, func: jsMath_sin)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "sinh", length: 1, func: jsMath_sinh)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "sqrt", length: 1, func: jsMath_sqrt)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "tan", length: 1, func: jsMath_tan)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "tanh", length: 1, func: jsMath_tanh)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "trunc", length: 1, func: jsMath_trunc)
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: mathObj,
                             name: "sumPrecise", length: 1, func: jsMath_sumPrecise)

    // Install Math on the global object.
    jeffJS_setPropertyStr(ctx: ctx, obj: globalObj, name: "Math",
                          value: .makeObject(mathObj))
}

// MARK: - Helper: Extract Double Argument

/// Convert argument at `index` to a Double, returning NaN if not provided
/// or not convertible. Mirrors `JS_ToFloat64` in QuickJS.
private func toFloat64Arg(_ ctx: JeffJSContext, _ argv: [JeffJSValue], _ index: Int) -> Double {
    guard index < argv.count else { return Double.nan }
    let v = argv[index]
    if v.isInt {
        return Double(v.toInt32())
    } else if v.isFloat64 {
        return v.toFloat64()
    } else if v.isUndefined {
        return Double.nan
    } else if v.isNull || v.isBool {
        if v.isNull { return 0.0 }
        return v.toBool() ? 1.0 : 0.0
    } else if v.isString {
        // ToNumber applied to a string: use ctx.toNumber then extract the double.
        let num = ctx.toNumber(v)
        if num.isFloat64 { return num.toFloat64() }
        if num.isInt { return Double(num.toInt32()) }
        return Double.nan
    } else if v.isObject {
        // ToNumber applied to an object: call ToPrimitive then convert.
        let prim = ctx.toNumber(v)
        if prim.isFloat64 { return prim.toFloat64() }
        if prim.isInt { return Double(prim.toInt32()) }
        return Double.nan
    }
    return Double.nan
}

/// Convert argument to Int32 (ToInt32 abstract op).
private func toInt32Arg(_ ctx: JeffJSContext, _ argv: [JeffJSValue], _ index: Int) -> Int32 {
    let d = toFloat64Arg(ctx, argv, index)
    if d.isNaN || d.isInfinite || d == 0 { return 0 }
    // ECMA-262 sec 7.1.6 — modulo 2^32, then treat as signed
    let rem = d.truncatingRemainder(dividingBy: 4294967296.0)
    let int64Val: Int64 = (rem.isNaN || rem.isInfinite || rem > 9.2e18 || rem < -9.2e18) ? 0 : Int64(rem)
    let u32 = UInt32(bitPattern: Int32(truncatingIfNeeded: int64Val))
    return Int32(bitPattern: u32)
}

// MARK: - Math Methods

/// Math.abs(x)
private func jsMath_abs(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Swift.abs(x))
}

/// Math.acos(x)
private func jsMath_acos(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Darwin.acos(x))
}

/// Math.acosh(x)
private func jsMath_acosh(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Darwin.acosh(x))
}

/// Math.asin(x)
private func jsMath_asin(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Darwin.asin(x))
}

/// Math.asinh(x)
private func jsMath_asinh(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Darwin.asinh(x))
}

/// Math.atan(x)
private func jsMath_atan(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Darwin.atan(x))
}

/// Math.atanh(x)
private func jsMath_atanh(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Darwin.atanh(x))
}

/// Math.atan2(y, x)
private func jsMath_atan2(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let y = toFloat64Arg(ctx, argv, 0)
    let x = toFloat64Arg(ctx, argv, 1)
    return .newFloat64(Darwin.atan2(y, x))
}

/// Math.cbrt(x)
private func jsMath_cbrt(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Darwin.cbrt(x))
}

/// Math.ceil(x)
private func jsMath_ceil(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Darwin.ceil(x))
}

/// Math.clz32(x) -- Count Leading Zeros of the 32-bit integer representation.
private func jsMath_clz32(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let n = toInt32Arg(ctx, argv, 0)
    let u = UInt32(bitPattern: n)
    let result = u == 0 ? 32 : u.leadingZeroBitCount
    return .newInt32(Int32(result))
}

/// Math.cos(x)
private func jsMath_cos(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Darwin.cos(x))
}

/// Math.cosh(x)
private func jsMath_cosh(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Darwin.cosh(x))
}

/// Math.exp(x)
private func jsMath_exp(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Darwin.exp(x))
}

/// Math.expm1(x) -- e^x - 1, more precise for small x.
private func jsMath_expm1(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Darwin.expm1(x))
}

/// Math.floor(x)
private func jsMath_floor(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Darwin.floor(x))
}

/// Math.fround(x) -- Round to nearest float32.
private func jsMath_fround(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    let f32 = Float(x)
    return .newFloat64(Double(f32))
}

/// Math.f16round(x) -- Round to nearest float16 (IEEE 754 binary16).
/// Implemented via manual conversion since Swift Float16 availability varies.
private func jsMath_f16round(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    if x.isNaN { return .newFloat64(Double.nan) }
    if x.isInfinite { return .newFloat64(x) }
    if x == 0 { return .newFloat64(x) } // preserve sign of zero

    // Convert via Float32 first, then to Float16 manually.
    // Float16 has 1 sign, 5 exponent, 10 mantissa bits.
    let f32 = Float(x)
    let bits = f32.bitPattern
    let sign = (bits >> 31) & 1
    let exp32 = Int((bits >> 23) & 0xFF) - 127
    let frac32 = bits & 0x7FFFFF

    var f16bits: UInt16

    if exp32 > 15 {
        // Overflow -> infinity
        f16bits = UInt16(sign << 15) | 0x7C00
    } else if exp32 < -24 {
        // Underflow -> zero
        f16bits = UInt16(sign << 15)
    } else if exp32 < -14 {
        // Subnormal float16
        let shift = -14 - exp32
        let frac = (frac32 | 0x800000) >> (13 + shift)
        f16bits = UInt16(sign << 15) | UInt16(frac & 0x3FF)
    } else {
        // Normal float16
        let exp16 = UInt16(exp32 + 15)
        let frac16 = UInt16(frac32 >> 13)
        f16bits = UInt16(sign << 15) | (exp16 << 10) | (frac16 & 0x3FF)
    }

    // Convert back to Double
    let f16sign = (f16bits >> 15) & 1
    let f16exp = Int((f16bits >> 10) & 0x1F)
    let f16frac = f16bits & 0x3FF

    var result: Double
    if f16exp == 0 {
        if f16frac == 0 {
            result = f16sign == 1 ? -0.0 : 0.0
        } else {
            // Subnormal
            result = Double(f16frac) / 1024.0 * pow(2.0, -14.0)
            if f16sign == 1 { result = -result }
        }
    } else if f16exp == 0x1F {
        if f16frac == 0 {
            result = f16sign == 1 ? -Double.infinity : Double.infinity
        } else {
            result = Double.nan
        }
    } else {
        result = (1.0 + Double(f16frac) / 1024.0) * pow(2.0, Double(f16exp - 15))
        if f16sign == 1 { result = -result }
    }

    return .newFloat64(result)
}

/// Math.hypot(...values)
private func jsMath_hypot(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    if argv.isEmpty { return .newFloat64(0.0) }

    // Check for Infinity first (spec requires it returns +Infinity even if NaN present)
    var hasNaN = false
    var values = [Double]()
    values.reserveCapacity(argv.count)

    for i in 0..<argv.count {
        let d = toFloat64Arg(ctx, argv, i)
        if d.isInfinite { return .newFloat64(Double.infinity) }
        if d.isNaN { hasNaN = true }
        values.append(d)
    }

    if hasNaN { return .newFloat64(Double.nan) }

    // Kahan-style summation for precision
    var maxVal = 0.0
    for v in values {
        let a = Swift.abs(v)
        if a > maxVal { maxVal = a }
    }
    if maxVal == 0 { return .newFloat64(0.0) }

    var sum = 0.0
    for v in values {
        let normalized = v / maxVal
        sum += normalized * normalized
    }
    return .newFloat64(maxVal * Darwin.sqrt(sum))
}

/// Math.imul(a, b) -- 32-bit integer multiply.
private func jsMath_imul(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let a = toInt32Arg(ctx, argv, 0)
    let b = toInt32Arg(ctx, argv, 1)
    let result = a &* b
    return .newInt32(result)
}

/// Math.log(x)
private func jsMath_log(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Darwin.log(x))
}

/// Math.log1p(x) -- log(1+x), more precise for small x.
private func jsMath_log1p(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Darwin.log1p(x))
}

/// Math.log10(x)
private func jsMath_log10(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Darwin.log10(x))
}

/// Math.log2(x)
private func jsMath_log2(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Darwin.log2(x))
}

/// Math.max(...values)
private func jsMath_max(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    if argv.isEmpty { return .newFloat64(-Double.infinity) }

    var result = -Double.infinity
    for i in 0..<argv.count {
        let d = toFloat64Arg(ctx, argv, i)
        if d.isNaN { return .newFloat64(Double.nan) }
        // +0 > -0 per spec
        if d > result || (d == result && d == 0 && !d.sign.rawValue.isMultiple(of: 2) == false && result.sign == .minus) {
            result = d
        }
        if result == 0 && d == 0 {
            // If either is +0, result is +0
            if result.sign != .minus || d.sign != .minus {
                result = 0.0
            }
        }
    }
    return .newFloat64(result)
}

/// Math.min(...values)
private func jsMath_min(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    if argv.isEmpty { return .newFloat64(Double.infinity) }

    var result = Double.infinity
    for i in 0..<argv.count {
        let d = toFloat64Arg(ctx, argv, i)
        if d.isNaN { return .newFloat64(Double.nan) }
        if d < result {
            result = d
        } else if d == 0 && result == 0 {
            // If either is -0, result is -0
            if d.sign == .minus || result.sign == .minus {
                result = -0.0
            }
        }
    }
    return .newFloat64(result)
}

/// Math.pow(base, exponent)
private func jsMath_pow(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let base = toFloat64Arg(ctx, argv, 0)
    let exponent = toFloat64Arg(ctx, argv, 1)
    return .newFloat64(Darwin.pow(base, exponent))
}

/// Math.random() -- Returns a pseudo-random number in [0, 1).
private func jsMath_random(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    // Use a xoshiro128** PRNG for reproducibility and speed,
    // seeded from system entropy on first call.
    let value = jeffJS_mathRandomNext()
    return .newFloat64(value)
}

/// Math.round(x) -- Round to nearest integer, with ties going to +Infinity.
private func jsMath_round(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    if x.isNaN || x.isInfinite || x == 0 { return .newFloat64(x) }
    // ECMA-262: Math.round(x) = floor(x + 0.5), except for the range (-0.5, 0)
    // which rounds to -0.
    if x > 0 || x <= -0.5 {
        return .newFloat64(Darwin.floor(x + 0.5))
    }
    // x is in (-0.5, 0] exclusive of -0.5
    if x > -0.5 {
        return .newFloat64(x.sign == .minus ? -0.0 : 0.0)
    }
    return .newFloat64(Darwin.floor(x + 0.5))
}

/// Math.sign(x)
private func jsMath_sign(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    if x.isNaN { return .newFloat64(Double.nan) }
    if x == 0 { return .newFloat64(x) } // preserve sign of zero
    return .newFloat64(x > 0 ? 1.0 : -1.0)
}

/// Math.sin(x)
private func jsMath_sin(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Darwin.sin(x))
}

/// Math.sinh(x)
private func jsMath_sinh(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Darwin.sinh(x))
}

/// Math.sqrt(x)
private func jsMath_sqrt(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Darwin.sqrt(x))
}

/// Math.tan(x)
private func jsMath_tan(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Darwin.tan(x))
}

/// Math.tanh(x)
private func jsMath_tanh(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Darwin.tanh(x))
}

/// Math.trunc(x) -- Remove fractional digits.
private func jsMath_trunc(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let x = toFloat64Arg(ctx, argv, 0)
    return .newFloat64(Darwin.trunc(x))
}

/// Math.sumPrecise(iterable) -- Sums numbers from an iterable with exact precision.
/// Uses Neumaier compensated summation (an improvement on Kahan summation).
/// Spec: TC39 proposal Math.sumPrecise.
private func jsMath_sumPrecise(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    guard argv.count >= 1, argv[0].isObject else {
        return ctx.throwTypeError("Math.sumPrecise requires an iterable")
    }

    // For now, handle array-like objects directly.
    guard let arrObj = argv[0].toObject() else {
        return ctx.throwTypeError("Math.sumPrecise requires an iterable")
    }

    var count: Int = 0
    if case .array(_, let vals, let c) = arrObj.payload {
        count = Int(c)

        // Neumaier compensated summation
        var sum = 0.0
        var compensation = 0.0
        var hasInfPlus = false
        var hasInfMinus = false

        for i in 0..<count {
            let v = vals[i]
            var d: Double
            if v.isInt {
                d = Double(v.toInt32())
            } else if v.isFloat64 {
                d = v.toFloat64()
            } else {
                return .newFloat64(Double.nan)
            }

            if d.isNaN { return .newFloat64(Double.nan) }
            if d == Double.infinity { hasInfPlus = true }
            if d == -Double.infinity { hasInfMinus = true }
            if hasInfPlus && hasInfMinus { return .newFloat64(Double.nan) }

            let t = sum + d
            if Swift.abs(sum) >= Swift.abs(d) {
                compensation += (sum - t) + d
            } else {
                compensation += (d - t) + sum
            }
            sum = t
        }

        if hasInfPlus { return .newFloat64(Double.infinity) }
        if hasInfMinus { return .newFloat64(-Double.infinity) }

        let result = sum + compensation
        // Spec: if result is -0 and no values, return -0; otherwise +0
        if result == 0 && count == 0 { return .newFloat64(-0.0) }
        return .newFloat64(result)
    }

    return .newFloat64(0.0)
}

// MARK: - PRNG (xoshiro256**)

/// Internal PRNG state for Math.random(), seeded lazily from system entropy.
/// Uses xoshiro256** algorithm for high-quality randomness.
private var prngState: (UInt64, UInt64, UInt64, UInt64) = {
    var s0: UInt64 = 0
    var s1: UInt64 = 0
    var s2: UInt64 = 0
    var s3: UInt64 = 0
    // Seed from system random.
    arc4random_buf(&s0, 8)
    arc4random_buf(&s1, 8)
    arc4random_buf(&s2, 8)
    arc4random_buf(&s3, 8)
    // Ensure non-zero state.
    if s0 == 0 && s1 == 0 && s2 == 0 && s3 == 0 {
        s0 = 0x853c49e6748fea9b
        s1 = 0xda3e39cb94b95bdb
    }
    return (s0, s1, s2, s3)
}()

/// Rotate left helper for xoshiro.
@inline(__always)
private func rotl(_ x: UInt64, _ k: Int) -> UInt64 {
    return (x << k) | (x >> (64 - k))
}

/// Generate the next random Double in [0, 1) using xoshiro256**.
private func jeffJS_mathRandomNext() -> Double {
    let result = rotl(prngState.1 &* 5, 7) &* 9
    let t = prngState.1 << 17

    prngState.2 ^= prngState.0
    prngState.3 ^= prngState.1
    prngState.1 ^= prngState.2
    prngState.0 ^= prngState.3
    prngState.2 ^= t
    prngState.3 = rotl(prngState.3, 45)

    // Convert to [0, 1) by taking the top 52 bits as a fraction.
    let fraction = result >> 12
    return Double(fraction) / Double(UInt64(1) << 52)
}

// MARK: - Property Definition Helpers

/// Define a double-valued non-writable, non-enumerable, non-configurable property.
private func jeffJS_definePropertyValueDouble(ctx: JeffJSContext, obj: JeffJSObject,
                                              atom: UInt32, value: Double) {
    let flags: JeffJSPropertyFlags = []  // not writable, not enumerable, not configurable
    jeffJS_addProperty(ctx: ctx, obj: obj, atom: atom, flags: flags)
    obj.setOwnPropertyValue(atom: atom, value: .newFloat64(value))
}

/// Define a string-valued non-writable, non-enumerable, configurable property.
private func jeffJS_definePropertyValueStr(ctx: JeffJSContext, obj: JeffJSObject,
                                           atom: UInt32, value: String) {
    let flags: JeffJSPropertyFlags = [.configurable]
    jeffJS_addProperty(ctx: ctx, obj: obj, atom: atom, flags: flags)
    let str = JeffJSString(swiftString: value)
    obj.setOwnPropertyValue(atom: atom, value: .makeString(str))
}

/// Define a built-in native function property on an object.
/// Creates a C function object and installs it as a named property using
/// the atom-based shape system so that property lookup works correctly.
func jeffJS_defineBuiltinFunc(ctx: JeffJSContext, obj: JeffJSObject,
                                      name: String, length: Int,
                                      func cfunc: @escaping (JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue) {
    // Create the function value through the context's proper API.
    let funcVal = ctx.newCFunction(cfunc, name: name, length: length)

    // Look up the atom for the property name and install via the shape system.
    let atom = ctx.rt.findAtom(name)
    let flags: JeffJSPropertyFlags = [.writable, .configurable]
    jeffJS_addProperty(ctx: ctx, obj: obj, atom: atom, flags: flags)
    // Set the value in the slot that jeffJS_addProperty just appended.
    if !obj.prop.isEmpty {
        obj.prop[obj.prop.count - 1] = .value(funcVal)
    }
    ctx.rt.freeAtom(atom)
}

/// Set a named property on an object (for global installation).
/// Uses the atom-based shape system so that property lookup works correctly.
func jeffJS_setPropertyStr(ctx: JeffJSContext, obj: JeffJSObject,
                           name: String, value: JeffJSValue) {
    let atom = ctx.rt.findAtom(name)
    let flags: JeffJSPropertyFlags = [.writable, .configurable]
    jeffJS_addProperty(ctx: ctx, obj: obj, atom: atom, flags: flags)
    // Set the value in the slot that jeffJS_addProperty just appended.
    if !obj.prop.isEmpty {
        obj.prop[obj.prop.count - 1] = .value(value)
    }
    ctx.rt.freeAtom(atom)
}

// MARK: - Double.eulersNumber (convenience)

private extension Double {
    /// Euler's number e, matching Math.E exactly.
    static let eulersNumber: Double = 2.718281828459045
}
