// JeffJSBigIntCore.swift
// JeffJS — 1:1 Swift port of QuickJS
//
// Arbitrary-precision integer arithmetic for BigInt.
//
// quickjs-ng builds its BigInt on libbf; this is the same shape in Swift:
// a sign + little-endian magnitude of 32-bit limbs with schoolbook multiply
// and Knuth algorithm D division. 32-bit limbs keep every intermediate in a
// UInt64, which is what makes the division and the radix conversion simple.
//
// `JBigInt` is a pure value type — no refcount, no GC, no runtime. The JS
// value layer (JeffJSBigIntValue.swift) decides whether a result lives inline
// in the NaN-boxed payload or in a heap `JeffJSBigInt`.
//
// Copyright 2026 Jeff Bachand. All rights reserved.

import Foundation

/// Arbitrary-precision signed integer.
///
/// `mag` is little-endian (mag[0] is the least significant limb) and always
/// normalised: no trailing zero limbs, and zero is the empty array with
/// `negative == false` (there is no negative zero).
struct JBigInt: Hashable, CustomStringConvertible {

    var negative: Bool
    var mag: [UInt32]

    // MARK: - Construction

    init() {
        negative = false
        mag = []
    }

    /// Normalising designated initialiser.
    init(negative: Bool, mag: [UInt32]) {
        var m = mag
        while let last = m.last, last == 0 { m.removeLast() }
        self.mag = m
        self.negative = m.isEmpty ? false : negative
    }

    init(_ v: Int) { self.init(Int64(v)) }

    init(_ v: Int64) {
        let m = v.magnitude              // correct for Int64.min
        self.init(negative: v < 0, mag: JBigInt.limbs(ofUInt64: m))
    }

    init(_ v: UInt64) {
        self.init(negative: false, mag: JBigInt.limbs(ofUInt64: v))
    }

    @inline(__always)
    static func limbs(ofUInt64 m: UInt64) -> [UInt32] {
        if m == 0 { return [] }
        let lo = UInt32(truncatingIfNeeded: m)
        let hi = UInt32(truncatingIfNeeded: m >> 32)
        return hi == 0 ? [lo] : [lo, hi]
    }

    static let zero = JBigInt()
    static let one  = JBigInt(1)

    // MARK: - Queries

    @inline(__always) var isZero: Bool { mag.isEmpty }
    @inline(__always) var isOne: Bool { !negative && mag.count == 1 && mag[0] == 1 }

    /// Number of significant bits in the magnitude (0 for zero).
    var bitLength: Int {
        guard let top = mag.last else { return 0 }
        return (mag.count - 1) * 32 + (32 - Int(top.leadingZeroBitCount))
    }

    /// Bit `i` of the two's-complement representation (infinitely sign-extended).
    func twosComplementBit(_ i: Int) -> Bool {
        if !negative { return magBit(i) }
        // -x == ~(x - 1): the two's-complement bits are the bits of (|x| - 1)
        // inverted.
        let dec = JBigInt(negative: false, mag: JBigInt.magSubSmall(mag, 1))
        return !dec.magBit(i)
    }

    @inline(__always)
    private func magBit(_ i: Int) -> Bool {
        let w = i >> 5
        if w >= mag.count { return false }
        return (mag[w] >> UInt32(i & 31)) & 1 == 1
    }

    /// The value as an Int64 when it fits, nil otherwise.
    var asInt64: Int64? {
        if mag.isEmpty { return 0 }
        if mag.count > 2 { return nil }
        var u: UInt64 = UInt64(mag[0])
        if mag.count == 2 { u |= UInt64(mag[1]) << 32 }
        if negative {
            if u > UInt64(Int64.max) + 1 { return nil }
            if u == UInt64(Int64.max) + 1 { return Int64.min }
            return -Int64(u)
        }
        if u > UInt64(Int64.max) { return nil }
        return Int64(u)
    }

    /// Low 64 bits of the two's-complement representation.
    var lowUInt64: UInt64 {
        var u: UInt64 = 0
        if mag.count > 0 { u = UInt64(mag[0]) }
        if mag.count > 1 { u |= UInt64(mag[1]) << 32 }
        return negative ? (0 &- u) : u
    }

    /// Nearest double (round-to-nearest-even is not attempted; truncation of
    /// the low bits matches what QuickJS's bf_get_float64 produces for the
    /// magnitudes JS code actually converts).
    var asDouble: Double {
        if mag.isEmpty { return 0 }
        var d: Double = 0
        for limb in mag.reversed() {
            d = d * 4294967296.0 + Double(limb)
        }
        return negative ? -d : d
    }

    // MARK: - Comparison

    /// -1, 0 or +1.
    static func compare(_ a: JBigInt, _ b: JBigInt) -> Int {
        if a.negative != b.negative { return a.negative ? -1 : 1 }
        let c = magCompare(a.mag, b.mag)
        return a.negative ? -c : c
    }

    static func == (a: JBigInt, b: JBigInt) -> Bool {
        a.negative == b.negative && a.mag == b.mag
    }

    @inline(__always)
    static func magCompare(_ a: [UInt32], _ b: [UInt32]) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        var i = a.count - 1
        while i >= 0 {
            if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
            i -= 1
        }
        return 0
    }

    // MARK: - Magnitude helpers

    static func magAdd(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        let (x, y) = a.count >= b.count ? (a, b) : (b, a)
        var out = [UInt32]()
        out.reserveCapacity(x.count + 1)
        var carry: UInt64 = 0
        for i in 0..<x.count {
            let s = UInt64(x[i]) + (i < y.count ? UInt64(y[i]) : 0) + carry
            out.append(UInt32(truncatingIfNeeded: s))
            carry = s >> 32
        }
        if carry != 0 { out.append(UInt32(carry)) }
        return out
    }

    /// a - b, requires a >= b.
    static func magSub(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var out = [UInt32]()
        out.reserveCapacity(a.count)
        var borrow: Int64 = 0
        for i in 0..<a.count {
            var d = Int64(a[i]) - (i < b.count ? Int64(b[i]) : 0) - borrow
            if d < 0 { d += 0x1_0000_0000; borrow = 1 } else { borrow = 0 }
            out.append(UInt32(truncatingIfNeeded: d))
        }
        while let last = out.last, last == 0 { out.removeLast() }
        return out
    }

    static func magSubSmall(_ a: [UInt32], _ v: UInt32) -> [UInt32] {
        return magSub(a, [v])
    }

    static func magMul(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        if a.isEmpty || b.isEmpty { return [] }
        var out = [UInt32](repeating: 0, count: a.count + b.count)
        out.withUnsafeMutableBufferPointer { o in
            for i in 0..<a.count {
                let ai = UInt64(a[i])
                if ai == 0 { continue }
                var carry: UInt64 = 0
                for j in 0..<b.count {
                    let t = ai * UInt64(b[j]) + UInt64(o[i + j]) + carry
                    o[i + j] = UInt32(truncatingIfNeeded: t)
                    carry = t >> 32
                }
                var k = i + b.count
                while carry != 0 {
                    let t = UInt64(o[k]) + carry
                    o[k] = UInt32(truncatingIfNeeded: t)
                    carry = t >> 32
                    k += 1
                }
            }
        }
        while let last = out.last, last == 0 { out.removeLast() }
        return out
    }

    /// Multiply by a single limb.
    static func magMulSmall(_ a: [UInt32], _ m: UInt32) -> [UInt32] {
        if a.isEmpty || m == 0 { return [] }
        var out = [UInt32]()
        out.reserveCapacity(a.count + 1)
        var carry: UInt64 = 0
        let mm = UInt64(m)
        for limb in a {
            let t = UInt64(limb) * mm + carry
            out.append(UInt32(truncatingIfNeeded: t))
            carry = t >> 32
        }
        if carry != 0 { out.append(UInt32(truncatingIfNeeded: carry)) }
        return out
    }

    /// Divide by a single limb; returns (quotient, remainder).
    static func magDivSmall(_ a: [UInt32], _ d: UInt32) -> ([UInt32], UInt32) {
        var q = [UInt32](repeating: 0, count: a.count)
        var rem: UInt64 = 0
        let dd = UInt64(d)
        var i = a.count - 1
        while i >= 0 {
            let cur = (rem << 32) | UInt64(a[i])
            q[i] = UInt32(truncatingIfNeeded: cur / dd)
            rem = cur % dd
            i -= 1
        }
        while let last = q.last, last == 0 { q.removeLast() }
        return (q, UInt32(truncatingIfNeeded: rem))
    }

    /// Knuth algorithm D. Returns (quotient, remainder) magnitudes.
    static func magDivMod(_ a: [UInt32], _ b: [UInt32]) -> ([UInt32], [UInt32]) {
        if b.isEmpty { return ([], []) }               // caller rejects /0
        if magCompare(a, b) < 0 { return ([], a) }
        if b.count == 1 {
            let (q, r) = magDivSmall(a, b[0])
            return (q, r == 0 ? [] : [r])
        }

        // Normalise so the divisor's top limb has its high bit set.
        let shift = Int(b[b.count - 1].leadingZeroBitCount)
        let u = magShiftLeftBits(a, shift)
        let v = magShiftLeftBits(b, shift)
        let n = v.count
        let m = u.count - n

        var un = u
        un.append(0)                                   // u has m+n+1 limbs
        var q = [UInt32](repeating: 0, count: m + 1)

        let vHigh = UInt64(v[n - 1])
        let vNext = UInt64(v[n - 2])

        var j = m
        while j >= 0 {
            let num = (UInt64(un[j + n]) << 32) | UInt64(un[j + n - 1])
            var qhat = num / vHigh
            var rhat = num % vHigh
            if qhat > 0xFFFF_FFFF { qhat = 0xFFFF_FFFF; rhat = num - qhat * vHigh }
            while rhat <= 0xFFFF_FFFF && qhat * vNext > ((rhat << 32) | UInt64(un[j + n - 2])) {
                qhat -= 1
                rhat += vHigh
            }

            // Multiply and subtract.
            var borrow: Int64 = 0
            var carry: UInt64 = 0
            for i in 0..<n {
                let p = qhat * UInt64(v[i]) + carry
                carry = p >> 32
                var t = Int64(un[i + j]) - Int64(p & 0xFFFF_FFFF) - borrow
                if t < 0 { t += 0x1_0000_0000; borrow = 1 } else { borrow = 0 }
                un[i + j] = UInt32(truncatingIfNeeded: t)
            }
            var t = Int64(un[j + n]) - Int64(carry) - borrow
            if t < 0 { t += 0x1_0000_0000; borrow = 1 } else { borrow = 0 }
            un[j + n] = UInt32(truncatingIfNeeded: t)

            if borrow != 0 {
                // qhat was one too large — add the divisor back.
                qhat -= 1
                var c: UInt64 = 0
                for i in 0..<n {
                    let s = UInt64(un[i + j]) + UInt64(v[i]) + c
                    un[i + j] = UInt32(truncatingIfNeeded: s)
                    c = s >> 32
                }
                un[j + n] = UInt32(truncatingIfNeeded: UInt64(un[j + n]) &+ c)
            }
            q[j] = UInt32(truncatingIfNeeded: qhat)
            j -= 1
        }

        while let last = q.last, last == 0 { q.removeLast() }
        var r = Array(un[0..<n])
        while let last = r.last, last == 0 { r.removeLast() }
        r = magShiftRightBits(r, shift)
        return (q, r)
    }

    static func magShiftLeftBits(_ a: [UInt32], _ bits: Int) -> [UInt32] {
        if a.isEmpty { return [] }
        let words = bits >> 5
        let sh = UInt32(bits & 31)
        var out = [UInt32](repeating: 0, count: a.count + words + 1)
        if sh == 0 {
            for i in 0..<a.count { out[i + words] = a[i] }
        } else {
            var carry: UInt32 = 0
            for i in 0..<a.count {
                out[i + words] = (a[i] << sh) | carry
                carry = a[i] >> (32 - sh)
            }
            out[a.count + words] = carry
        }
        while let last = out.last, last == 0 { out.removeLast() }
        return out
    }

    /// Logical right shift of the magnitude; returns (shifted, anyBitsLost).
    static func magShiftRightBitsLossy(_ a: [UInt32], _ bits: Int) -> ([UInt32], Bool) {
        let words = bits >> 5
        if words >= a.count {
            return ([], !a.isEmpty)
        }
        let sh = UInt32(bits & 31)
        var lost = false
        for i in 0..<words where a[i] != 0 { lost = true; break }
        var out = [UInt32](repeating: 0, count: a.count - words)
        if sh == 0 {
            for i in 0..<out.count { out[i] = a[i + words] }
        } else {
            if (a[words] & ((1 << sh) - 1)) != 0 { lost = true }
            for i in 0..<out.count {
                var v = a[i + words] >> sh
                if i + words + 1 < a.count {
                    v |= a[i + words + 1] << (32 - sh)
                }
                out[i] = v
            }
        }
        while let last = out.last, last == 0 { out.removeLast() }
        return (out, lost)
    }

    static func magShiftRightBits(_ a: [UInt32], _ bits: Int) -> [UInt32] {
        return magShiftRightBitsLossy(a, bits).0
    }

    // MARK: - Arithmetic

    static func add(_ a: JBigInt, _ b: JBigInt) -> JBigInt {
        if a.negative == b.negative {
            return JBigInt(negative: a.negative, mag: magAdd(a.mag, b.mag))
        }
        let c = magCompare(a.mag, b.mag)
        if c == 0 { return JBigInt.zero }
        if c > 0 { return JBigInt(negative: a.negative, mag: magSub(a.mag, b.mag)) }
        return JBigInt(negative: b.negative, mag: magSub(b.mag, a.mag))
    }

    static func sub(_ a: JBigInt, _ b: JBigInt) -> JBigInt {
        return add(a, b.negated)
    }

    static func mul(_ a: JBigInt, _ b: JBigInt) -> JBigInt {
        if a.isZero || b.isZero { return .zero }
        return JBigInt(negative: a.negative != b.negative, mag: magMul(a.mag, b.mag))
    }

    /// Truncating division (toward zero) — the JS `/` on BigInts.
    /// The caller rejects a zero divisor (RangeError).
    static func divMod(_ a: JBigInt, _ b: JBigInt) -> (q: JBigInt, r: JBigInt) {
        let (qm, rm) = magDivMod(a.mag, b.mag)
        let q = JBigInt(negative: a.negative != b.negative, mag: qm)
        let r = JBigInt(negative: a.negative, mag: rm)   // remainder takes the dividend's sign
        return (q, r)
    }

    var negated: JBigInt {
        if isZero { return .zero }
        return JBigInt(negative: !negative, mag: mag)
    }

    var abs: JBigInt { JBigInt(negative: false, mag: mag) }

    /// `~x` == `-x - 1`.
    var bitwiseNot: JBigInt {
        return JBigInt.sub(negated, .one)
    }

    /// Exponentiation by squaring. `maxBits` guards against runaway
    /// allocations (QuickJS reports "out of memory" there).
    static func pow(_ base: JBigInt, _ exp: JBigInt, maxBits: Int = 1 << 24) -> JBigInt? {
        if exp.isZero { return .one }
        guard let e64 = exp.asInt64, e64 >= 0 else { return nil }
        if base.isZero { return .zero }
        if base.isOne { return .one }
        if base.mag == [1] {        // -1
            return (e64 & 1) == 0 ? .one : JBigInt(-1)
        }
        // Rough size check before doing the work.
        let bits = base.bitLength
        if bits > 1, e64 > Int64(maxBits) { return nil }
        if bits * Int(e64) > maxBits { return nil }

        var result = JBigInt.one
        var b = base
        var e = e64
        while e > 0 {
            if e & 1 == 1 { result = mul(result, b) }
            e >>= 1
            if e > 0 { b = mul(b, b) }
        }
        return result
    }

    /// `x << n` (n >= 0) / `x >> -n`.
    static func shiftLeft(_ a: JBigInt, _ n: Int) -> JBigInt {
        if a.isZero { return .zero }
        if n == 0 { return a }
        if n < 0 { return shiftRight(a, -n) }
        return JBigInt(negative: a.negative, mag: magShiftLeftBits(a.mag, n))
    }

    /// Arithmetic right shift — floor division by 2^n, so negatives round
    /// toward -Infinity (`-5n >> 1n === -3n`).
    static func shiftRight(_ a: JBigInt, _ n: Int) -> JBigInt {
        if a.isZero { return .zero }
        if n == 0 { return a }
        if n < 0 { return shiftLeft(a, -n) }
        let (m, lost) = magShiftRightBitsLossy(a.mag, n)
        if !a.negative { return JBigInt(negative: false, mag: m) }
        var r = JBigInt(negative: true, mag: m)
        if lost { r = sub(r, .one) }
        return r
    }

    // MARK: - Bitwise (two's complement semantics)

    private static func twosWords(_ x: JBigInt, _ n: Int) -> [UInt32] {
        var w = [UInt32](repeating: 0, count: n)
        for i in 0..<Swift.min(n, x.mag.count) { w[i] = x.mag[i] }
        if x.negative {
            // two's complement: invert and add one
            var carry: UInt64 = 1
            for i in 0..<n {
                let t = UInt64(~w[i]) + carry
                w[i] = UInt32(truncatingIfNeeded: t)
                carry = t >> 32
            }
        }
        return w
    }

    private static func fromTwos(_ w: [UInt32], negative: Bool) -> JBigInt {
        if !negative { return JBigInt(negative: false, mag: w) }
        var m = w
        var carry: UInt64 = 1
        for i in 0..<m.count {
            let t = UInt64(~m[i]) + carry
            m[i] = UInt32(truncatingIfNeeded: t)
            carry = t >> 32
        }
        return JBigInt(negative: true, mag: m)
    }

    private static func bitwise(_ a: JBigInt, _ b: JBigInt,
                                _ op: (UInt32, UInt32) -> UInt32,
                                _ signOp: (Bool, Bool) -> Bool) -> JBigInt {
        let n = Swift.max(a.mag.count, b.mag.count) + 1
        let wa = twosWords(a, n)
        let wb = twosWords(b, n)
        var out = [UInt32](repeating: 0, count: n)
        for i in 0..<n { out[i] = op(wa[i], wb[i]) }
        return fromTwos(out, negative: signOp(a.negative, b.negative))
    }

    static func and(_ a: JBigInt, _ b: JBigInt) -> JBigInt {
        bitwise(a, b, { $0 & $1 }, { $0 && $1 })
    }
    static func or(_ a: JBigInt, _ b: JBigInt) -> JBigInt {
        bitwise(a, b, { $0 | $1 }, { $0 || $1 })
    }
    static func xor(_ a: JBigInt, _ b: JBigInt) -> JBigInt {
        bitwise(a, b, { $0 ^ $1 }, { $0 != $1 })
    }

    // MARK: - asIntN / asUintN

    /// Low `bits` bits, interpreted as an unsigned value.
    static func asUintN(_ bits: Int, _ x: JBigInt) -> JBigInt {
        if bits == 0 { return .zero }
        let n = (bits + 31) / 32
        var w = twosWords(x, Swift.max(n, x.mag.count + 1))
        w = Array(w[0..<n])
        let topBits = bits & 31
        if topBits != 0 {
            w[n - 1] &= (UInt32(1) << UInt32(topBits)) &- 1
        }
        return JBigInt(negative: false, mag: w)
    }

    /// Low `bits` bits, interpreted as a signed two's-complement value.
    static func asIntN(_ bits: Int, _ x: JBigInt) -> JBigInt {
        if bits == 0 { return .zero }
        let u = asUintN(bits, x)
        // If the sign bit is set, subtract 2^bits.
        if u.twosComplementBit(bits - 1) {
            let two = JBigInt(negative: false, mag: magShiftLeftBits([1], bits))
            return sub(u, two)
        }
        return u
    }

    // MARK: - String conversion

    private static let digitChars = Array("0123456789abcdefghijklmnopqrstuvwxyz".utf8)

    func toString(radix: Int = 10) -> String {
        if mag.isEmpty { return "0" }
        var out = [UInt8]()
        if radix == 10 {
            // Peel off 9 decimal digits per division by 10^9.
            var cur = mag
            var chunks = [UInt32]()
            while !cur.isEmpty {
                let (q, r) = JBigInt.magDivSmall(cur, 1_000_000_000)
                chunks.append(r)
                cur = q
            }
            out.reserveCapacity(chunks.count * 9 + 1)
            if negative { out.append(0x2D) }
            var first = true
            for c in chunks.reversed() {
                if first {
                    out.append(contentsOf: Array(String(c).utf8))
                    first = false
                } else {
                    var s = Array(String(c).utf8)
                    while s.count < 9 { s.insert(0x30, at: 0) }
                    out.append(contentsOf: s)
                }
            }
            return String(decoding: out, as: UTF8.self)
        }

        if radix == 16 || radix == 8 || radix == 4 || radix == 32 || radix == 2 {
            // Power-of-two radices: pure bit slicing.
            let bitsPer = radix.trailingZeroBitCount
            var digits = [UInt8]()
            var i = 0
            let total = bitLength
            while i < total {
                var d: UInt32 = 0
                for k in 0..<bitsPer where magBit(i + k) {
                    d |= (1 << UInt32(k))
                }
                digits.append(JBigInt.digitChars[Int(d)])
                i += bitsPer
            }
            while digits.count > 1 && digits.last == 0x30 { digits.removeLast() }
            if negative { digits.append(0x2D) }
            return String(decoding: digits.reversed(), as: UTF8.self)
        }

        // Generic radix: repeated division by the largest power of `radix`
        // that fits in a limb.
        var chunkDigits = 1
        var chunkValue = UInt64(radix)
        while chunkValue * UInt64(radix) < 0x1_0000_0000 {
            chunkValue *= UInt64(radix)
            chunkDigits += 1
        }
        var cur = mag
        var parts = [UInt32]()
        while !cur.isEmpty {
            let (q, r) = JBigInt.magDivSmall(cur, UInt32(chunkValue))
            parts.append(r)
            cur = q
        }
        var digits = [UInt8]()
        var first = true
        for p in parts.reversed() {
            var v = p
            var buf = [UInt8]()
            if v == 0 { buf = [0x30] }
            while v > 0 {
                buf.append(JBigInt.digitChars[Int(v % UInt32(radix))])
                v /= UInt32(radix)
            }
            if !first {
                while buf.count < chunkDigits { buf.append(0x30) }
            }
            first = false
            digits.append(contentsOf: buf.reversed())
        }
        var s = String(decoding: digits, as: UTF8.self)
        if negative { s = "-" + s }
        return s
    }

    var description: String { toString() }

    /// Parse a run of digits in `radix`. Returns nil on an invalid digit.
    /// `text` must already be stripped of sign, prefix and separators.
    static func parse(digits: [UInt8], radix: Int) -> JBigInt? {
        if digits.isEmpty { return nil }
        var chunkDigits = 1
        var chunkValue = UInt64(radix)
        while chunkValue * UInt64(radix) < 0x1_0000_0000 {
            chunkValue *= UInt64(radix)
            chunkDigits += 1
        }
        var mag: [UInt32] = []
        var i = 0
        while i < digits.count {
            let take = Swift.min(chunkDigits, digits.count - i)
            var chunk: UInt32 = 0
            var scale: UInt64 = 1
            for k in 0..<take {
                guard let d = digitValue(digits[i + k]), d < radix else { return nil }
                chunk = chunk &* UInt32(radix) &+ UInt32(d)
                scale *= UInt64(radix)
            }
            mag = magMulSmall(mag, UInt32(scale))
            if chunk != 0 { mag = magAdd(mag, [chunk]) }
            i += take
        }
        return JBigInt(negative: false, mag: mag)
    }

    @inline(__always)
    static func digitValue(_ c: UInt8) -> Int? {
        switch c {
        case 0x30...0x39: return Int(c - 0x30)
        case 0x61...0x7A: return Int(c - 0x61) + 10
        case 0x41...0x5A: return Int(c - 0x41) + 10
        default: return nil
        }
    }

    /// Exact conversion from a double. nil when `d` is not an integer
    /// (NaN, Infinity and fractions all return nil — the caller raises
    /// RangeError).
    static func fromDouble(_ d: Double) -> JBigInt? {
        if !d.isFinite { return nil }
        if d != d.rounded(.towardZero) { return nil }
        if d == 0 { return .zero }
        let neg = d < 0
        let a = Swift.abs(d)
        if a < 9.007199254740992e15 {           // exact in Int64
            return JBigInt(Int64(a) * (neg ? -1 : 1))
        }
        // Decompose: significand * 2^exponent.
        let e = a.exponent                       // unbiased
        let sig = a.significandBitPattern | (1 << 52)
        var v = JBigInt(UInt64(sig))
        let shift = Int(e) - 52
        if shift >= 0 {
            v = shiftLeft(v, shift)
        } else {
            v = shiftRight(v, -shift)
        }
        return neg ? v.negated : v
    }
}
