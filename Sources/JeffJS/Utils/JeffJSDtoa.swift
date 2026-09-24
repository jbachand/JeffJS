// JeffJSDtoa.swift
// JeffJS - 1:1 Swift port of QuickJS JavaScript engine
//
// Port of QuickJS dtoa.c — double-to-ASCII and ASCII-to-double conversion,
// number formatting for toString/toFixed/toExponential/toPrecision.

import Foundation

// MARK: - DtoaFormat

/// Output format for `jsDtoa` / `jsDtoa2`, matching QuickJS JS_DTOA_* modes.
enum DtoaFormat: Int {
    /// Shortest representation that round-trips (Grisu/Dragon4 equivalent).
    /// Corresponds to `JS_DTOA_FORMAT_FREE` in QuickJS.
    case free = 0

    /// Fixed number of fractional digits (used by `toFixed`).
    /// Corresponds to `JS_DTOA_FORMAT_FRAC` in QuickJS.
    case frac = 1

    /// Fixed number of significant digits (used by `toPrecision`).
    /// Corresponds to `JS_DTOA_FORMAT_FIXED` in QuickJS.
    case fixed = 2
}

// MARK: - ATOD Flags (ASCII-to-double parsing flags)

/// Mirrors `ATOD_*` flags from QuickJS quickjs.c / dtoa.c.
struct ATODFlags: OptionSet {
    let rawValue: UInt32

    /// Only parse integer strings (no decimal point or exponent).
    static let intOnly              = ATODFlags(rawValue: 1 << 0)

    /// Accept `0b` (binary) and `0o` (octal) prefixes.
    static let acceptBinOct         = ATODFlags(rawValue: 1 << 1)

    /// Accept legacy octal `0nnn` (non-strict mode).
    static let acceptLegacyOctal    = ATODFlags(rawValue: 1 << 2)

    /// Accept numeric separator underscores `1_000_000`.
    static let acceptUnderscores    = ATODFlags(rawValue: 1 << 3)

    /// Accept BigInt `n` suffix (`123n`).
    static let acceptSuffix         = ATODFlags(rawValue: 1 << 4)

    /// Accept `0x`/`0b`/`0o` prefix after a leading sign.
    static let acceptPrefixAfterSign = ATODFlags(rawValue: 1 << 5)

    /// Return a BigInt value when the `n` suffix is present.
    static let wantBigInt           = ATODFlags(rawValue: 1 << 6)

    /// Accept `Infinity` as a valid token.
    static let acceptInfinity       = ATODFlags(rawValue: 1 << 7)

    /// Accept trailing content (don't require full-string match).
    static let acceptTrailing       = ATODFlags(rawValue: 1 << 8)
}

// MARK: - JS_DTOA Flags (double-to-ASCII formatting flags)

/// Mirrors `JS_DTOA_*` flags from QuickJS.
struct JSDtoaFlags: OptionSet {
    let rawValue: UInt32

    /// Use shortest (free-form) format.
    static let formatFree   = JSDtoaFlags(rawValue: 0 << 0)

    /// Use fixed fractional-digit format (toFixed).
    static let formatFrac   = JSDtoaFlags(rawValue: 1 << 0)

    /// Use fixed significant-digit format (toPrecision).
    static let formatFixed  = JSDtoaFlags(rawValue: 2 << 0)

    /// Enable exponential notation when appropriate.
    static let expEnabled   = JSDtoaFlags(rawValue: 1 << 4)

    /// Prefix output with radix indicator (0x, 0b, 0o) for non-decimal.
    static let radixPrefix  = JSDtoaFlags(rawValue: 1 << 5)
}

// MARK: - Float Classification Helpers

/// Returns `true` if `d` is NaN.  Mirrors QuickJS `isnan()`.
@inline(__always)
func jsIsNaN(_ d: Double) -> Bool {
    return d.isNaN
}

/// Returns `true` if `d` is +Infinity or -Infinity.  Mirrors QuickJS `isinf()`.
@inline(__always)
func jsIsInfinity(_ d: Double) -> Bool {
    return d.isInfinite
}

/// Returns `true` if `d` is neither NaN nor Infinity.  Mirrors QuickJS `isfinite()`.
@inline(__always)
func jsIsFinite(_ d: Double) -> Bool {
    return d.isFinite
}

/// Returns `true` if `d` is negative zero.
@inline(__always)
func jsIsNegativeZero(_ d: Double) -> Bool {
    return d == 0.0 && d.bitPattern == (-0.0 as Double).bitPattern
}

/// Returns the sign bit of a double (1 for negative, 0 for positive/+0).
@inline(__always)
func jsSignBit(_ d: Double) -> Int {
    return d.bitPattern >> 63 == 1 ? 1 : 0
}

// MARK: - Core Double-to-ASCII

/// Format a double value as a string in the given radix.
///
/// This is the main number-to-string conversion used throughout QuickJS.
/// Mirrors `js_dtoa` in QuickJS quickjs.c.
///
/// - Parameters:
///   - buf: A DynBuf to write the result into.
///   - d: The double value to format.
///   - radix: Numeric base (2-36). Pass 10 for decimal.
///   - nDigits: Number of digits (interpretation depends on `format`).
///   - format: Output format mode (free, frac, or fixed).
/// - Returns: The formatted string.
func jsDtoa(_ buf: inout DynBuf, _ d: Double, radix: Int, nDigits: Int, format: DtoaFormat) -> String {
    return jsDtoa2(&buf, d, radix: radix, nDigits: nDigits, format: format, expEnabled: false)
}

/// Extended version of `jsDtoa` with explicit exponential-notation control.
/// Mirrors `js_dtoa2` / the internal dtoa logic in QuickJS.
func jsDtoa2(_ buf: inout DynBuf, _ d: Double, radix: Int, nDigits: Int, format: DtoaFormat, expEnabled: Bool) -> String {
    // Handle special values first.
    if d.isNaN {
        return "NaN"
    }
    if d.isInfinite {
        return d < 0 ? "-Infinity" : "Infinity"
    }

    let negative = jsSignBit(d) != 0
    let absVal = negative ? -d : d

    // Negative zero.
    if d == 0.0 {
        if negative && format == .free {
            // In JS, Number(-0).toString() returns "0", not "-0".
            // But certain paths (e.g. JSON) distinguish them.
        }
        switch format {
        case .free:
            return "0"
        case .frac:
            if nDigits <= 0 {
                return negative ? "-0" : "0"
            }
            var s = negative ? "-0." : "0."
            for _ in 0 ..< nDigits {
                s.append("0")
            }
            return s
        case .fixed:
            if nDigits <= 1 {
                return negative ? "-0" : "0"
            }
            var s = negative ? "-0." : "0."
            for _ in 0 ..< (nDigits - 1) {
                s.append("0")
            }
            return s
        }
    }

    // Non-decimal radix.
    if radix != 10 {
        return formatDoubleRadix(absVal, negative: negative, radix: radix)
    }

    // Decimal formatting.
    switch format {
    case .free:
        return formatDoubleFree(d)

    case .frac:
        return formatDoubleFrac(d, nDigits: nDigits)

    case .fixed:
        return formatDoubleFixed(d, nDigits: nDigits, expEnabled: expEnabled)
    }
}

// MARK: - Free-form (shortest representation)

/// Format a double using the shortest decimal representation that round-trips.
/// This mirrors the Grisu2/Dragon4 algorithm used by QuickJS for free-form
/// output (i.e. `Number.prototype.toString()` with no arguments).
private func formatDoubleFree(_ d: Double) -> String {
    if d == 0.0 {
        return jsSignBit(d) != 0 ? "0" : "0"
    }

    // Use Swift's built-in shortest representation, which already follows
    // the ECMAScript spec for Number-to-String (IEEE 754 shortest).
    // Swift's Double description matches the JS spec:
    //  - No trailing zeros.
    //  - Exponential form for very large/small numbers.
    var s = "\(d)"

    // Swift formats 1e20 as "1e+20" — JS uses "100000000000000000000".
    // Swift formats 0.1 as "0.1" — matches JS.
    // Swift formats 1e-7 as "1e-07" — JS uses "1e-7".
    // Normalise Swift's exponent formatting to match JS.
    if let eIdx = s.firstIndex(of: "e") {
        let mantissa = String(s[s.startIndex ..< eIdx])
        let expPart = String(s[s.index(after: eIdx)...])
        let expSign: String
        var expStr: String
        if expPart.hasPrefix("+") {
            expSign = "+"
            expStr = String(expPart.dropFirst())
        } else if expPart.hasPrefix("-") {
            expSign = "-"
            expStr = String(expPart.dropFirst())
        } else {
            expSign = "+"
            expStr = expPart
        }
        // Remove leading zeros from exponent.
        while expStr.count > 1 && expStr.hasPrefix("0") {
            expStr = String(expStr.dropFirst())
        }
        s = "\(mantissa)e\(expSign)\(expStr)"
    }

    return s
}

// MARK: - Exact decimal expansion

/// The exact decimal expansion of a finite, non-zero double's magnitude:
/// `|d| = 0.D1 D2 D3 … × 10^exponent`, with `D1 != 0` and no trailing zero digits.
///
/// Every binary double has a finite decimal expansion (at most 767 significant
/// digits), so rounding decisions made on these digits are exact. That is what
/// ECMA-262 asks of toFixed / toExponential / toPrecision ("let n be an integer
/// for which n / 10^f - x is as close to zero as possible; if there are two such
/// n, pick the larger n"): round half up on the exact value. Scaling by powers of
/// ten in floating point, `log10`, or printf's round-half-even cannot give that.
private func exactDecimalDigits(_ d: Double) -> (digits: [UInt8], exponent: Int) {
    let a = Swift.abs(d)
    var mant = a.significandBitPattern
    var e2: Int
    if a.exponentBitPattern == 0 {
        e2 = -1074
    } else {
        mant |= (UInt64(1) << 52)
        e2 = Int(a.exponentBitPattern) - 1075
    }
    let tz = mant.trailingZeroBitCount
    mant >>= UInt64(tz)
    e2 += tz

    // Little-endian base-1e9 bignum holding N, with |d| = N × 10^(-scale).
    let base: UInt64 = 1_000_000_000
    var limbs: [UInt32] = []
    var m = mant
    while m > 0 { limbs.append(UInt32(m % base)); m /= base }
    func mul(_ f: UInt64) {
        var carry: UInt64 = 0
        for i in 0 ..< limbs.count {
            let p = UInt64(limbs[i]) * f + carry
            limbs[i] = UInt32(p % base)
            carry = p / base
        }
        while carry > 0 { limbs.append(UInt32(carry % base)); carry /= base }
    }
    var scale = 0
    if e2 > 0 {
        var k = e2
        while k >= 28 { mul(UInt64(1) << 28); k -= 28 }
        if k > 0 { mul(UInt64(1) << UInt64(k)) }
    } else if e2 < 0 {
        // m × 2^-k = m × 5^k × 10^-k
        var k = -e2
        scale = k
        while k >= 13 { mul(1_220_703_125); k -= 13 }  // 5^13
        if k > 0 {
            var p: UInt64 = 1
            for _ in 0 ..< k { p *= 5 }
            mul(p)
        }
    }

    var digits: [UInt8] = []
    digits.reserveCapacity(limbs.count * 9)
    for ch in String(limbs[limbs.count - 1]).utf8 { digits.append(ch &- 48) }
    if limbs.count >= 2 {
        for i in stride(from: limbs.count - 2, through: 0, by: -1) {
            var v = limbs[i]
            var chunk = [UInt8](repeating: 0, count: 9)
            for j in stride(from: 8, through: 0, by: -1) {
                chunk[j] = UInt8(v % 10)
                v /= 10
            }
            digits.append(contentsOf: chunk)
        }
    }
    let exponent = digits.count - scale
    while let last = digits.last, last == 0 { digits.removeLast() }
    return (digits, exponent)
}

/// The shortest digits that round-trip to `|d|` (Number::toString's digits):
/// `|d| = 0.D1 D2 … × 10^exponent`, `D1 != 0`, no trailing zeros. `d` finite, non-zero.
private func shortestDecimalDigits(_ d: Double) -> (digits: [UInt8], exponent: Int) {
    // Swift's description is the shortest round-trip, closest representation.
    let s = "\(Swift.abs(d))"
    var mantissa = Substring(s)
    var exp10 = 0
    if let eIdx = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        mantissa = s[s.startIndex ..< eIdx]
        exp10 = Int(s[s.index(after: eIdx)...]) ?? 0
    }
    var digits: [UInt8] = []
    var pointPos: Int? = nil
    for ch in mantissa.utf8 {
        if ch == 46 { pointPos = digits.count } else if ch >= 48 && ch <= 57 { digits.append(ch - 48) }
    }
    var exponent = (pointPos ?? digits.count) + exp10
    while let first = digits.first, first == 0 { digits.removeFirst(); exponent -= 1 }
    while let last = digits.last, last == 0 { digits.removeLast() }
    return (digits, exponent)
}

/// Keeps the first `count` digits of `0.D` (zero-padded), rounding half up on the
/// rest. When the rounding carries out of the leading digit the result is `1`
/// followed by `count` zeros (`count + 1` digits) and `carried` is true.
/// `count <= 0` rounds to nothing, or to a lone carried `1` when `count == 0` and
/// the leading digit is >= 5.
private func roundDigitsHalfUp(_ digits: [UInt8], count: Int) -> (digits: [UInt8], carried: Bool) {
    if count < 0 { return ([], false) }
    if count == 0 {
        if let first = digits.first, first >= 5 { return ([1], true) }
        return ([], false)
    }
    var r = Array(digits.prefix(count))
    while r.count < count { r.append(0) }
    if digits.count > count && digits[count] >= 5 {
        var i = count - 1
        while i >= 0 {
            if r[i] == 9 { r[i] = 0; i -= 1 } else { r[i] += 1; break }
        }
        if i < 0 {
            r.insert(1, at: 0)
            return (r, true)
        }
    }
    return (r, false)
}

@inline(__always)
private func digitString<S: Sequence>(_ digits: S) -> String where S.Element == UInt8 {
    var s = ""
    for d in digits { s.unicodeScalars.append(Unicode.Scalar(d + 48)) }
    return s
}

@inline(__always)
private func exponentSuffix(_ e: Int) -> String {
    return (e < 0 ? "e-" : "e+") + String(Swift.abs(e))
}

// MARK: - Fixed fractional digits (toFixed)

/// Format a double with exactly `nDigits` fractional digits.
/// Mirrors `js_fcvt` in QuickJS dtoa.c.
func jsFcvt(_ d: Double, nDigits: Int) -> String {
    return formatDoubleFrac(d, nDigits: nDigits)
}

/// Extended variant with format control.
func jsFcvt1(_ d: Double, nDigits: Int, format: DtoaFormat) -> String {
    switch format {
    case .frac:
        return formatDoubleFrac(d, nDigits: nDigits)
    case .fixed:
        return formatDoubleFixed(d, nDigits: nDigits, expEnabled: false)
    case .free:
        return formatDoubleFree(d)
    }
}

/// ES2025 §21.1.3.3 Number.prototype.toFixed steps 5–12 for a finite `d` with
/// `|d| < 1e21` (callers handle the rest): exactly `nDigits` fractional digits,
/// ties rounded up (away from zero), "-" only for `d < 0` (so `-0` gives "0.00"
/// while `-0.0001` gives "-0.00").
private func formatDoubleFrac(_ d: Double, nDigits: Int) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
    let f = max(nDigits, 0)
    if Swift.abs(d) >= 1e21 { return formatDoubleFree(d) }

    var m: String
    if d == 0 {
        m = "0"
    } else {
        let (digits, exponent) = exactDecimalDigits(d)
        let (n, _) = roundDigitsHalfUp(digits, count: exponent + f)
        m = n.isEmpty ? "0" : digitString(n)
    }
    if f != 0 {
        var k = m.count
        if k <= f {
            m = String(repeating: "0", count: f + 1 - k) + m
            k = f + 1
        }
        let a = m.prefix(k - f)
        let b = m.suffix(f)
        m = a + "." + b
    }
    return d < 0 ? "-" + m : m
}

// MARK: - Fixed significant digits (toPrecision)

/// ES2025 §21.1.3.5 Number.prototype.toPrecision steps 8–13 for a finite `d`:
/// exactly `nDigits` significant digits (trailing zeros kept), ties rounded up,
/// exponential notation when the exponent is < -6 or >= the precision (only if
/// `expEnabled`; otherwise always positional). `-0` formats like `0`.
private func formatDoubleFixed(_ d: Double, nDigits: Int, expEnabled: Bool) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
    let p = max(nDigits, 1)

    var m: [UInt8]
    var e: Int
    if d == 0 {
        m = [UInt8](repeating: 0, count: p)
        e = 0
    } else {
        let (digits, exponent) = exactDecimalDigits(d)
        let (r, carried) = roundDigitsHalfUp(digits, count: p)
        m = r
        e = exponent - 1
        if carried {
            m.removeLast()
            e += 1
        }
    }
    let s = d < 0 ? "-" : ""

    if expEnabled && (e < -6 || e >= p) {
        var out = s + digitString(m[0 ..< 1])
        if p != 1 { out += "." + digitString(m[1...]) }
        return out + exponentSuffix(e)
    }
    if e >= p - 1 {
        return s + digitString(m) + String(repeating: "0", count: e - (p - 1))
    }
    if e >= 0 {
        return s + digitString(m[0 ... e]) + "." + digitString(m[(e + 1)...])
    }
    return s + "0." + String(repeating: "0", count: -(e + 1)) + digitString(m)
}

// MARK: - Exponential notation (toExponential)

/// ES2025 §21.1.3.2 Number.prototype.toExponential steps 7–15 for a finite `d`:
/// `nDigits` fractional digits, ties rounded up; `nDigits < 0` means
/// "fractionDigits undefined": as many digits as needed to identify the value
/// (the shortest round-trip digits). `-0` formats like `0`.
private func formatDoubleExponential(_ d: Double, nDigits: Int) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }

    var m: [UInt8]
    var e: Int
    if d == 0 {
        m = [UInt8](repeating: 0, count: max(nDigits, 0) + 1)
        e = 0
    } else if nDigits < 0 {
        let (digits, exponent) = shortestDecimalDigits(d)
        m = digits
        e = exponent - 1
    } else {
        let (digits, exponent) = exactDecimalDigits(d)
        let (r, carried) = roundDigitsHalfUp(digits, count: nDigits + 1)
        m = r
        e = exponent - 1
        if carried {
            m.removeLast()
            e += 1
        }
    }
    var out = d < 0 ? "-" : ""
    out += digitString(m[0 ..< 1])
    if m.count > 1 { out += "." + digitString(m[1...]) }
    return out + exponentSuffix(e)
}

// MARK: - Non-decimal Radix Formatting

/// Format a double in a non-decimal radix (2-36).
/// Used by `Number.prototype.toString(radix)`.
/// Mirrors the non-decimal path in QuickJS `js_dtoa`.
private func formatDoubleRadix(_ absVal: Double, negative: Bool, radix: Int) -> String {
    let digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    let digitsArr = Array(digits)
    let r = Double(radix)

    // Split into integer and fractional parts.
    var intPart = Foundation.floor(absVal)
    var fracPart = absVal - intPart

    // Format integer part.
    var intChars = [Character]()
    if intPart == 0 {
        intChars.append("0")
    } else {
        while intPart >= 1.0 {
            let digit = Int(intPart.truncatingRemainder(dividingBy: r))
            let clampedDigit = min(max(digit, 0), radix - 1)
            intChars.append(digitsArr[clampedDigit])
            intPart = Foundation.floor(intPart / r)
        }
        intChars.reverse()
    }

    var result = String(intChars)

    // Format fractional part (up to ~52 digits of precision for the radix).
    if fracPart > 0 {
        result.append(".")
        // Maximum number of fractional digits: enough to represent 53 bits
        // of mantissa in the given radix.
        let maxFracDigits = Int(ceil(53.0 / Foundation.log2(r))) + 1
        var count = 0
        while fracPart > 0 && count < maxFracDigits {
            fracPart *= r
            let digit = Int(fracPart)
            let clampedDigit = min(max(digit, 0), radix - 1)
            result.append(digitsArr[clampedDigit])
            fracPart -= Double(digit)
            count += 1
        }
        // Remove trailing zeros from fractional part.
        while result.hasSuffix("0") {
            result.removeLast()
        }
        if result.hasSuffix(".") {
            result.removeLast()
        }
    }

    if negative {
        result = "-" + result
    }
    return result
}

// MARK: - String-to-Number Parsing (jsAtof)

/// Result of parsing a numeric string.
enum JsAtofResult {
    case double(Double)
    case integer(Int64)
    case bigInt(String)   // raw digit string for BigInt creation
    case error
}

/// Parse a numeric value from a string with the given flags and radix.
///
/// This is the main string-to-number conversion used by QuickJS for
/// `Number()`, `parseInt()`, `parseFloat()`, and numeric literals.
/// Mirrors `js_atof` / `js_atof2` in QuickJS quickjs.c / dtoa.c.
///
/// - Parameters:
///   - str: The input string to parse.
///   - flags: Parsing behaviour flags.
///   - radix: Default radix (0 = auto-detect, 10 = decimal, etc.).
/// - Returns: The parsed result.
func jsAtof(_ str: String, flags: ATODFlags, radix: Int) -> JsAtofResult {
    let chars = Array(str.utf8)
    var pos = 0
    let len = chars.count

    // Skip leading whitespace.
    while pos < len && isWhitespace(chars[pos]) {
        pos += 1
    }

    if pos >= len {
        return flags.contains(.intOnly) ? .integer(0) : .double(Double.nan)
    }

    // Parse sign.
    var negative = false
    if chars[pos] == 0x2B /* '+' */ {
        pos += 1
    } else if chars[pos] == 0x2D /* '-' */ {
        negative = true
        pos += 1
    }

    if pos >= len {
        return flags.contains(.intOnly) ? .integer(0) : .double(Double.nan)
    }

    // Check for Infinity.
    if flags.contains(.acceptInfinity) || !flags.contains(.intOnly) {
        if matchesLiteral(chars, pos, "Infinity") {
            pos += 8
            // Check for trailing content.
            if !flags.contains(.acceptTrailing) {
                while pos < len && isWhitespace(chars[pos]) { pos += 1 }
                if pos < len { return .double(Double.nan) }
            }
            return .double(negative ? -Double.infinity : Double.infinity)
        }
    }

    // Determine radix from prefix.
    var currentRadix = radix == 0 ? 10 : radix
    var hasPrefix = false

    if (chars[pos] == 0x30 /* '0' */) && pos + 1 < len {
        let next = chars[pos + 1]

        if flags.contains(.acceptBinOct) || flags.contains(.acceptPrefixAfterSign) {
            if next == 0x78 || next == 0x58 /* 'x' or 'X' */ {
                currentRadix = 16
                pos += 2
                hasPrefix = true
            } else if next == 0x6F || next == 0x4F /* 'o' or 'O' */ {
                currentRadix = 8
                pos += 2
                hasPrefix = true
            } else if next == 0x62 || next == 0x42 /* 'b' or 'B' */ {
                currentRadix = 2
                pos += 2
                hasPrefix = true
            }
        }

        if !hasPrefix && flags.contains(.acceptLegacyOctal) && radix == 0 {
            // Check if all following digits are octal.
            var allOctal = true
            var j = pos + 1
            while j < len {
                let c = chars[j]
                if c == 0x5F /* '_' */ && flags.contains(.acceptUnderscores) {
                    j += 1
                    continue
                }
                if c < 0x30 || c > 0x37 /* not '0'-'7' */ {
                    if c >= 0x38 && c <= 0x39 /* '8' or '9' */ {
                        allOctal = false
                    }
                    break
                }
                j += 1
            }
            if allOctal && j > pos + 1 {
                currentRadix = 8
                pos += 1  // Skip leading '0', digits follow.
            }
        }
    }

    // Parse digits.
    if currentRadix == 10 && !flags.contains(.intOnly) {
        return parseDecimalFloat(chars, &pos, len, negative: negative, flags: flags)
    } else {
        return parseRadixInteger(chars, &pos, len, negative: negative,
                                 radix: currentRadix, flags: flags,
                                 hasRadixPrefix: hasPrefix)
    }
}

// MARK: - Internal Parsing Helpers

/// Parse a decimal floating-point number from UTF-8 bytes.
private func parseDecimalFloat(_ chars: [UInt8], _ pos: inout Int, _ len: Int,
                                negative: Bool, flags: ATODFlags) -> JsAtofResult {
    var intStr = ""
    var fracStr = ""
    var expStr = ""
    var hasDigits = false
    var hasDot = false
    var hasExp = false
    var prevUnderscore = false

    // Integer part.
    while pos < len {
        let c = chars[pos]
        if c == 0x5F /* '_' */ && flags.contains(.acceptUnderscores) {
            if !hasDigits || prevUnderscore { break }
            prevUnderscore = true
            pos += 1
            continue
        }
        prevUnderscore = false
        if c >= 0x30 && c <= 0x39 /* '0'-'9' */ {
            intStr.append(Character(Unicode.Scalar(c)))
            hasDigits = true
            pos += 1
        } else {
            break
        }
    }

    // Fractional part.
    if pos < len && chars[pos] == 0x2E /* '.' */ {
        hasDot = true
        pos += 1
        prevUnderscore = false
        while pos < len {
            let c = chars[pos]
            if c == 0x5F /* '_' */ && flags.contains(.acceptUnderscores) {
                if fracStr.isEmpty || prevUnderscore { break }
                prevUnderscore = true
                pos += 1
                continue
            }
            prevUnderscore = false
            if c >= 0x30 && c <= 0x39 {
                fracStr.append(Character(Unicode.Scalar(c)))
                hasDigits = true
                pos += 1
            } else {
                break
            }
        }
    }

    if !hasDigits {
        return .double(Double.nan)
    }

    // Exponent.
    if pos < len && (chars[pos] == 0x65 || chars[pos] == 0x45) /* 'e' or 'E' */ {
        hasExp = true
        pos += 1
        if pos < len && (chars[pos] == 0x2B || chars[pos] == 0x2D) /* '+' or '-' */ {
            expStr.append(Character(Unicode.Scalar(chars[pos])))
            pos += 1
        }
        var expHasDigits = false
        prevUnderscore = false
        while pos < len {
            let c = chars[pos]
            if c == 0x5F && flags.contains(.acceptUnderscores) {
                if !expHasDigits || prevUnderscore { break }
                prevUnderscore = true
                pos += 1
                continue
            }
            prevUnderscore = false
            if c >= 0x30 && c <= 0x39 {
                expStr.append(Character(Unicode.Scalar(c)))
                expHasDigits = true
                pos += 1
            } else {
                break
            }
        }
        if !expHasDigits {
            return .double(Double.nan)
        }
    }

    // Check for BigInt suffix.
    if pos < len && chars[pos] == 0x6E /* 'n' */ && flags.contains(.acceptSuffix) {
        pos += 1
        if !flags.contains(.acceptTrailing) {
            while pos < len && isWhitespace(chars[pos]) { pos += 1 }
            if pos < len { return .error }
        }
        if flags.contains(.wantBigInt) {
            let numStr = (negative ? "-" : "") + intStr
            return .bigInt(numStr)
        }
    }

    // Check for trailing content.
    if !flags.contains(.acceptTrailing) {
        while pos < len && isWhitespace(chars[pos]) { pos += 1 }
        if pos < len { return .double(Double.nan) }
    }

    // Build the full numeric string and parse with Double.
    var numStr = negative ? "-" : ""
    numStr += intStr.isEmpty ? "0" : intStr
    if hasDot {
        numStr += "."
        numStr += fracStr.isEmpty ? "0" : fracStr
    }
    if hasExp {
        numStr += "e"
        numStr += expStr
    }

    if let val = Double(numStr) {
        return .double(val)
    }
    return .double(Double.nan)
}

/// Parse an integer in an arbitrary radix from UTF-8 bytes.
private func parseRadixInteger(_ chars: [UInt8], _ pos: inout Int, _ len: Int,
                                negative: Bool, radix: Int,
                                flags: ATODFlags,
                                hasRadixPrefix: Bool) -> JsAtofResult {
    var result: UInt64 = 0
    var hasDigits = false
    var overflow = false
    var digitStr = ""
    var prevUnderscore = false

    while pos < len {
        let c = chars[pos]

        if c == 0x5F /* '_' */ && flags.contains(.acceptUnderscores) {
            if !hasDigits || prevUnderscore { break }
            prevUnderscore = true
            pos += 1
            continue
        }
        prevUnderscore = false

        let digit = digitValue(c, radix: radix)
        if digit < 0 {
            break
        }

        hasDigits = true
        digitStr.append(Character(Unicode.Scalar(c)))

        if !overflow {
            let (newVal, mulOvf) = result.multipliedReportingOverflow(by: UInt64(radix))
            if mulOvf {
                overflow = true
            } else {
                let (addVal, addOvf) = newVal.addingReportingOverflow(UInt64(digit))
                if addOvf {
                    overflow = true
                } else {
                    result = addVal
                }
            }
        }
        pos += 1
    }

    if !hasDigits {
        if flags.contains(.intOnly) {
            return .integer(0)
        }
        return .double(Double.nan)
    }

    // Check for BigInt suffix.
    if pos < len && chars[pos] == 0x6E /* 'n' */ && flags.contains(.acceptSuffix) {
        pos += 1
        if !flags.contains(.acceptTrailing) {
            while pos < len && isWhitespace(chars[pos]) { pos += 1 }
            if pos < len { return .error }
        }
        if flags.contains(.wantBigInt) {
            return .bigInt((negative ? "-" : "") + digitStr)
        }
    }

    // Check for trailing content.
    if !flags.contains(.acceptTrailing) {
        while pos < len && isWhitespace(chars[pos]) { pos += 1 }
        if pos < len && !flags.contains(.intOnly) {
            return .double(Double.nan)
        }
    }

    if overflow {
        // Value too large for UInt64 — parse as Double.
        let d = parseRadixString(digitStr, radix: radix)
        return .double(negative ? -d : d)
    }

    // Check if the value fits in Int64.
    if negative {
        if result <= UInt64(Int64.max) + 1 {
            if result == UInt64(Int64.max) + 1 {
                return .integer(Int64.min)
            }
            return .integer(-Int64(result))
        }
        return .double(-Double(result))
    } else {
        if result <= UInt64(Int64.max) {
            return .integer(Int64(result))
        }
        return .double(Double(result))
    }
}

/// Parse a string of digits in the given radix as a Double.
/// Used when the integer overflows UInt64.
/// Mirrors `js_atod` / radix parsing fallback in QuickJS.
func parseRadixString(_ str: String, radix: Int) -> Double {
    var result: Double = 0.0
    let r = Double(radix)
    for ch in str {
        let d = digitValueChar(ch, radix: radix)
        if d < 0 { break }
        result = result * r + Double(d)
    }
    return result
}

/// Return the numeric value of a digit character in the given radix, or -1.
private func digitValue(_ c: UInt8, radix: Int) -> Int {
    var val: Int
    if c >= 0x30 && c <= 0x39 /* '0'-'9' */ {
        val = Int(c - 0x30)
    } else if c >= 0x41 && c <= 0x5A /* 'A'-'Z' */ {
        val = Int(c - 0x41) + 10
    } else if c >= 0x61 && c <= 0x7A /* 'a'-'z' */ {
        val = Int(c - 0x61) + 10
    } else {
        return -1
    }
    if val >= radix { return -1 }
    return val
}

/// Character variant of `digitValue`.
private func digitValueChar(_ ch: Character, radix: Int) -> Int {
    guard let ascii = ch.asciiValue else { return -1 }
    return digitValue(ascii, radix: radix)
}

/// Check if the byte sequence at `pos` matches the given ASCII literal.
private func matchesLiteral(_ chars: [UInt8], _ pos: Int, _ literal: String) -> Bool {
    let literalBytes = Array(literal.utf8)
    guard pos + literalBytes.count <= chars.count else { return false }
    for i in 0 ..< literalBytes.count {
        if chars[pos + i] != literalBytes[i] {
            return false
        }
    }
    return true
}

/// Returns `true` if the byte is an ASCII whitespace character matching the
/// ES2024 `WhiteSpace` or `LineTerminator` productions.
private func isWhitespace(_ c: UInt8) -> Bool {
    switch c {
    case 0x09, // TAB
         0x0A, // LF
         0x0B, // VT
         0x0C, // FF
         0x0D, // CR
         0x20: // SPACE
        return true
    default:
        return false
    }
}

// MARK: - parseInt / parseFloat Convenience

/// Parse an integer from a string with an optional radix.
/// Mirrors the `parseInt()` global function behaviour.
func jsParseInt(_ str: String, radix: Int = 0) -> JsAtofResult {
    var flags: ATODFlags = [.intOnly, .acceptTrailing]
    if radix == 0 || radix == 16 {
        flags.insert(.acceptPrefixAfterSign)
    }
    if radix == 0 {
        flags.insert(.acceptBinOct)
    }
    return jsAtof(str, flags: flags, radix: radix)
}

/// Parse a float from a string.
/// Mirrors the `parseFloat()` global function behaviour.
func jsParseFloat(_ str: String) -> JsAtofResult {
    let flags: ATODFlags = [.acceptTrailing, .acceptInfinity]
    return jsAtof(str, flags: flags, radix: 10)
}

// MARK: - Number.prototype helpers

/// Implementation of `Number.prototype.toFixed(fractionDigits)`.
/// Mirrors `js_number_toFixed` in QuickJS.
func jsNumberToFixed(_ d: Double, fractionDigits: Int) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
    let clamped = max(0, min(fractionDigits, 100))
    return formatDoubleFrac(d, nDigits: clamped)
}

/// Implementation of `Number.prototype.toExponential(fractionDigits)`.
/// `nil` = fractionDigits undefined (shortest round-trip digits).
/// Mirrors `js_number_toExponential` in QuickJS.
func jsNumberToExponential(_ d: Double, fractionDigits: Int?) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
    guard let f = fractionDigits else { return formatDoubleExponential(d, nDigits: -1) }
    return formatDoubleExponential(d, nDigits: max(0, min(f, 100)))
}

/// Implementation of `Number.prototype.toPrecision(precision)`.
/// Mirrors `js_number_toPrecision` in QuickJS.
func jsNumberToPrecision(_ d: Double, precision: Int) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
    let clamped = max(1, min(precision, 100))
    return formatDoubleFixed(d, nDigits: clamped, expEnabled: true)
}

/// Implementation of `Number.prototype.toString(radix)`.
/// Mirrors `js_number_toString` in QuickJS.
func jsNumberToString(_ d: Double, radix: Int = 10) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }

    if radix == 10 {
        return formatDoubleFree(d)
    }

    let negative = d < 0 || jsIsNegativeZero(d)
    let absVal = abs(d)

    if absVal == 0.0 {
        return "0"
    }

    return formatDoubleRadix(absVal, negative: negative, radix: radix)
}
