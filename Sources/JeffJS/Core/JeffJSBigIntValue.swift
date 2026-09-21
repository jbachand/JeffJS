// JeffJSBigIntValue.swift
// JeffJS — 1:1 Swift port of QuickJS
//
// The JS value layer over JBigInt: NaN-boxed construction, the abstract
// operations (ToBigInt / ToNumeric / StringToBigInt) and the operator
// implementations the interpreter calls once it knows a BigInt is involved.
//
// Representation: |v| < 2^47 lives inline in the NaN-boxed payload
// (`shortBigInt`, no allocation and no refcount — this is what keeps `n++`
// loops cheap); anything wider allocates a refcounted `JeffJSBigInt`.
//
// Copyright 2026 Jeff Bachand. All rights reserved.

import Foundation

// MARK: - Allocation

/// Allocate a heap BigInt and register it with the runtime's GC list, the
/// way objects are registered — BigInts are leaves, but the collector walks
/// values generically and expects every `toGCObjectHeader()` result to be
/// tracked.
@inline(never)
func jeffJS_newHeapBigInt(_ v: JBigInt) -> JeffJSValue {
    let bi = JeffJSBigInt(v)
    if let rt = bi.ownerRuntime {
        addGCObject(rt, bi)
    }
    return JeffJSValue.makeBigInt(bi)
}

extension JeffJSValue {

    /// BigInt from an Int64 — inline when it fits, heap otherwise.
    @inline(__always)
    static func newBigInt(_ v: Int64) -> JeffJSValue {
        if v >= shortBigIntMin && v <= shortBigIntMax { return mkShortBigInt(v) }
        return jeffJS_newHeapBigInt(JBigInt(v))
    }

    /// BigInt from an arbitrary-precision value — normalises back to the
    /// inline form whenever the result got small again.
    @inline(__always)
    static func newBigInt(_ b: JBigInt) -> JeffJSValue {
        if b.mag.count <= 2, let i = b.asInt64,
           i >= shortBigIntMin, i <= shortBigIntMax {
            return mkShortBigInt(i)
        }
        return jeffJS_newHeapBigInt(b)
    }

    /// The arbitrary-precision value. Only valid when `isBigInt`.
    @inline(__always)
    var bigIntValue: JBigInt {
        if isShortBigInt { return JBigInt(shortBigIntValue) }
        if let bi = toBigInt() { return bi.value }
        return .zero
    }

    /// `0n` test without materialising a JBigInt (BigInt truthiness).
    @inline(__always)
    var bigIntIsZero: Bool {
        if isShortBigInt { return shortBigIntValue == 0 }
        if let bi = toBigInt() { return bi.value.isZero }
        return true
    }
}

// MARK: - String -> BigInt

/// StringToBigInt (ES 7.1.14). Returns nil when the string is not a valid
/// BigInt literal (the caller turns that into SyntaxError or `false`).
func jeffJS_stringToBigInt(_ raw: String) -> JBigInt? {
    var bytes = Array(raw.utf8)
    // Trim JS whitespace / line terminators.
    func isWS(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C
    }
    var lo = 0, hi = bytes.count
    while lo < hi && isWS(bytes[lo]) { lo += 1 }
    while hi > lo && isWS(bytes[hi - 1]) { hi -= 1 }
    // Non-ASCII whitespace (U+00A0, U+FEFF, …) survives the byte trim; fall
    // back to the Unicode trim when anything non-ASCII is present.
    if bytes.contains(where: { $0 >= 0x80 }) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        bytes = Array(t.utf8)
        lo = 0; hi = bytes.count
        if bytes.contains(where: { $0 >= 0x80 }) { return nil }
    }
    if lo == hi { return .zero }             // empty / all-whitespace == 0n

    var i = lo
    var negative = false
    var radix = 10
    if bytes[i] == 0x2B || bytes[i] == 0x2D {          // '+' / '-'
        negative = bytes[i] == 0x2D
        i += 1
        if i == hi { return nil }
    } else if bytes[i] == 0x30 && i + 1 < hi {         // '0'
        switch bytes[i + 1] {
        case 0x78, 0x58: radix = 16; i += 2
        case 0x6F, 0x4F: radix = 8;  i += 2
        case 0x62, 0x42: radix = 2;  i += 2
        default: break
        }
        if radix != 10 && i == hi { return nil }
    }
    let digits = Array(bytes[i..<hi])
    if digits.isEmpty { return nil }
    guard let mag = JBigInt.parse(digits: digits, radix: radix) else { return nil }
    return negative ? mag.negated : mag
}

// MARK: - Operators

enum JeffJSBigIntBinOp {
    case add, sub, mul, div, mod, pow, and, or, xor, shl, sar
}

struct JeffJSBigIntOps {

    /// BigInt ⊗ BigInt. Both operands must already be BigInts.
    static func binary(ctx: JeffJSContext, op: JeffJSBigIntBinOp,
                       _ a: JeffJSValue, _ b: JeffJSValue) -> JeffJSValue {
        // Inline fast path: two short BigInts through Int64. Every result of
        // +/-/& /|/^ on 48-bit inputs fits an Int64, and the multiply is
        // checked.
        if a.isShortBigInt && b.isShortBigInt {
            let x = a.shortBigIntValue, y = b.shortBigIntValue
            switch op {
            case .add: return .newBigInt(x &+ y)
            case .sub: return .newBigInt(x &- y)
            case .and: return .newBigInt(x & y)
            case .or:  return .newBigInt(x | y)
            case .xor: return .newBigInt(x ^ y)
            case .mul:
                let (r, ovf) = x.multipliedReportingOverflow(by: y)
                if !ovf { return .newBigInt(r) }
            case .div:
                if y == 0 { return ctx.throwRangeError(message: "BigInt division by zero") }
                return .newBigInt(x / y)          // truncating, and no overflow in 48 bits
            case .mod:
                if y == 0 { return ctx.throwRangeError(message: "BigInt division by zero") }
                return .newBigInt(x % y)
            default: break
            }
        }

        let x = a.bigIntValue
        let y = b.bigIntValue
        switch op {
        case .add: return .newBigInt(JBigInt.add(x, y))
        case .sub: return .newBigInt(JBigInt.sub(x, y))
        case .mul: return .newBigInt(JBigInt.mul(x, y))
        case .div:
            if y.isZero { return ctx.throwRangeError(message: "BigInt division by zero") }
            return .newBigInt(JBigInt.divMod(x, y).q)
        case .mod:
            if y.isZero { return ctx.throwRangeError(message: "BigInt division by zero") }
            return .newBigInt(JBigInt.divMod(x, y).r)
        case .pow:
            if y.negative {
                return ctx.throwRangeError(message: "BigInt negative exponent")
            }
            guard let r = JBigInt.pow(x, y) else {
                return ctx.throwRangeError(message: "BigInt is too large")
            }
            return .newBigInt(r)
        case .and: return .newBigInt(JBigInt.and(x, y))
        case .or:  return .newBigInt(JBigInt.or(x, y))
        case .xor: return .newBigInt(JBigInt.xor(x, y))
        case .shl, .sar:
            guard let n = y.asInt64, n > Int64(Int32.min), n < (1 << 31) else {
                // A shift count that large either overflows memory or
                // collapses to 0n / -1n.
                if y.negative == (op == .shl) {
                    return .newBigInt(x.negative ? JBigInt(-1) : .zero)
                }
                return ctx.throwRangeError(message: "BigInt is too large")
            }
            let amount = Int(n)
            if op == .shl { return .newBigInt(JBigInt.shiftLeft(x, amount)) }
            return .newBigInt(JBigInt.shiftRight(x, amount))
        }
    }

    /// Unary `-`.
    static func negate(_ a: JeffJSValue) -> JeffJSValue {
        if a.isShortBigInt { return .newBigInt(0 &- a.shortBigIntValue) }
        return .newBigInt(a.bigIntValue.negated)
    }

    /// Unary `~`.
    static func bitwiseNot(_ a: JeffJSValue) -> JeffJSValue {
        if a.isShortBigInt { return .newBigInt(~a.shortBigIntValue) }
        return .newBigInt(a.bigIntValue.bitwiseNot)
    }

    /// `++` / `--`.
    static func addInt(_ a: JeffJSValue, _ d: Int64) -> JeffJSValue {
        if a.isShortBigInt { return .newBigInt(a.shortBigIntValue &+ d) }
        return .newBigInt(JBigInt.add(a.bigIntValue, JBigInt(d)))
    }

    /// BigInt vs BigInt: -1 / 0 / 1.
    @inline(__always)
    static func compare(_ a: JeffJSValue, _ b: JeffJSValue) -> Int {
        if a.isShortBigInt && b.isShortBigInt {
            let x = a.shortBigIntValue, y = b.shortBigIntValue
            return x < y ? -1 : (x == y ? 0 : 1)
        }
        return JBigInt.compare(a.bigIntValue, b.bigIntValue)
    }

    @inline(__always)
    static func equal(_ a: JeffJSValue, _ b: JeffJSValue) -> Bool {
        if a.bits == b.bits { return true }
        if a.isShortBigInt != b.isShortBigInt { return false }   // canonical form
        return compare(a, b) == 0
    }

    /// BigInt vs Number (abstract relational / loose equality).
    /// Returns nil when the number is NaN (unordered).
    static func compareWithDouble(_ a: JeffJSValue, _ d: Double) -> Int? {
        if d.isNaN { return nil }
        if d.isInfinite { return d > 0 ? -1 : 1 }
        let x = a.bigIntValue
        // Compare against the integer part, then break ties on the fraction.
        guard let t = JBigInt.fromDouble(d.rounded(.towardZero)) else { return nil }
        let c = JBigInt.compare(x, t)
        if c != 0 { return c }
        let frac = d - d.rounded(.towardZero)
        if frac > 0 { return -1 }
        if frac < 0 { return 1 }
        return 0
    }

    /// The digits, without the `n` suffix (`String(1n) === "1"`).
    static func toStringValue(ctx: JeffJSContext, _ a: JeffJSValue, radix: Int = 10) -> JeffJSValue {
        if a.isShortBigInt && radix == 10 {
            return ctx.newStringValue(String(a.shortBigIntValue))
        }
        return ctx.newStringValue(a.bigIntValue.toString(radix: radix))
    }

    static func toSwiftString(_ a: JeffJSValue, radix: Int = 10) -> String {
        if a.isShortBigInt && radix == 10 { return String(a.shortBigIntValue) }
        return a.bigIntValue.toString(radix: radix)
    }

    /// ToNumber on a BigInt is a TypeError in JS, but `Number(1n)` and the
    /// relational operators need the double value.
    static func toDouble(_ a: JeffJSValue) -> Double {
        if a.isShortBigInt { return Double(a.shortBigIntValue) }
        return a.bigIntValue.asDouble
    }
}

// MARK: - Abstract operations on the context

extension JeffJSContext {

    /// ToBigInt (ES 7.1.13) — used by `BigInt64Array` stores, `DataView`
    /// setters and `Atomics`. Numbers are a TypeError here (unlike the
    /// `BigInt()` constructor, which accepts integral Numbers).
    func toBigIntValue(_ v: JeffJSValue) -> JeffJSValue {
        var prim = v
        var owned = false
        if v.isObject {
            prim = toPrimitive(v, preferredType: "number")
            if prim.isException { return .exception }
            owned = true
        }
        defer { if owned { prim.freeValue() } }
        if prim.isBigInt { return prim.dupValue() }
        if prim.isBool { return JeffJSValue.newBigInt(prim.toBool() ? 1 : 0) }
        if prim.isString {
            let s = toSwiftString(prim) ?? ""
            guard let b = jeffJS_stringToBigInt(s) else {
                return throwSyntaxError(message: "Cannot convert \(s) to a BigInt")
            }
            return JeffJSValue.newBigInt(b)
        }
        if prim.isNumber {
            return throwTypeError(message: "Cannot convert a Number to a BigInt")
        }
        return throwTypeError(message: "Cannot convert to a BigInt")
    }

    /// ToNumeric (ES 7.1.4): ToPrimitive(number) and then either the BigInt
    /// itself or ToNumber. Returns a BigInt or a Number (or an exception).
    func toNumericValue(_ v: JeffJSValue) -> JeffJSValue {
        if v.isInt || v.isFloat64 { return v }
        if v.isBigInt { return v.dupValue() }
        if v.isObject {
            let prim = toPrimitive(v, preferredType: "number")
            if prim.isException { return .exception }
            if prim.isBigInt { return prim }
            defer { prim.freeValue() }
            let (d, ok) = JeffJSTypeConvert.toNumber(ctx: self, val: prim)
            if !ok { return .exception }
            return JeffJSValue.newFloat64(d)
        }
        if v.isSymbol {
            return throwTypeError(message: "Cannot convert a Symbol value to a number")
        }
        let (d, ok) = JeffJSTypeConvert.toNumber(ctx: self, val: v)
        if !ok { return .exception }
        return JeffJSValue.newFloat64(d)
    }

    /// The `BigInt(value)` constructor's conversion (ES 21.2.1.1).
    func bigIntConstructorValue(_ v: JeffJSValue) -> JeffJSValue {
        var prim = v
        var owned = false
        if v.isObject {
            prim = toPrimitive(v, preferredType: "number")
            if prim.isException { return .exception }
            owned = true
        }
        defer { if owned { prim.freeValue() } }
        if prim.isBigInt { return prim.dupValue() }
        if prim.isBool { return JeffJSValue.newBigInt(prim.toBool() ? 1 : 0) }
        if prim.isInt { return JeffJSValue.newBigInt(Int64(prim.toInt32())) }
        if prim.isFloat64 {
            let d = prim.toFloat64()
            guard let b = JBigInt.fromDouble(d) else {
                return throwRangeError(message: "The number \(JeffJSTypeConvert.formatNumber(d)) cannot be converted to a BigInt because it is not an integer")
            }
            return JeffJSValue.newBigInt(b)
        }
        if prim.isString {
            let s = toSwiftString(prim) ?? ""
            guard let b = jeffJS_stringToBigInt(s) else {
                return throwSyntaxError(message: "Cannot convert \(s) to a BigInt")
            }
            return JeffJSValue.newBigInt(b)
        }
        if prim.isSymbol {
            return throwTypeError(message: "Cannot convert a Symbol value to a BigInt")
        }
        return throwTypeError(message: "Cannot convert \(prim.isNull ? "null" : "undefined") to a BigInt")
    }
}
