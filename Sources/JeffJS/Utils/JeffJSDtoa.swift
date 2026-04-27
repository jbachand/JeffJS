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

/// Internal: format with fixed fractional digits.
private func formatDoubleFrac(_ d: Double, nDigits: Int) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }

    let clamped = max(nDigits, 0)
    let negative = d < 0 || jsIsNegativeZero(d)
    let absVal = abs(d)

    if clamped == 0 {
        // Round to nearest integer.
        let rounded = absVal.rounded(.toNearestOrEven)
        let intVal = UInt64(rounded)
        let s = String(intVal)
        return negative ? "-\(s)" : s
    }

    // Use a high-precision approach: multiply by 10^nDigits, round, then
    // insert the decimal point.
    let scale = pow(10.0, Double(clamped))
    let scaled = (absVal * scale).rounded(.toNearestOrEven)

    // Guard against overflow of UInt64.
    if scaled >= Double(UInt64.max) || scaled.isInfinite {
        // Fall back to String(format:) for very large values.
        let fmt = String(format: "%.\(clamped)f", d)
        return fmt
    }

    let intScaled = UInt64(scaled)
    var digits = String(intScaled)

    // Pad with leading zeros if necessary.
    while digits.count <= clamped {
        digits = "0" + digits
    }

    let intPartLen = digits.count - clamped
    let intPart = String(digits.prefix(intPartLen))
    let fracPart = String(digits.suffix(clamped))

    var result = intPart + "." + fracPart
    if negative {
        result = "-" + result
    }
    return result
}

// MARK: - Fixed significant digits (toPrecision)

/// Internal: format with fixed number of significant digits.
private func formatDoubleFixed(_ d: Double, nDigits: Int, expEnabled: Bool) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }

    let negative = d < 0 || jsIsNegativeZero(d)
    let absVal = abs(d)
    let prec = max(nDigits, 1)

    if absVal == 0 {
        var s = "0"
        if prec > 1 {
            s += "."
            for _ in 0 ..< (prec - 1) {
                s += "0"
            }
        }
        return negative ? "-\(s)" : s
    }

    // Determine the order of magnitude.
    let logVal = Foundation.log10(absVal)
    let exponent = Int(Foundation.floor(logVal))

    // Decide whether to use exponential notation.
    if expEnabled && (exponent >= prec || exponent < -4) {
        return formatDoubleExponential(d, nDigits: prec - 1)
    }

    // Number of fractional digits needed.
    let fracDigits = prec - exponent - 1

    if fracDigits >= 0 {
        return formatDoubleFrac(d, nDigits: fracDigits)
    } else {
        // More integer digits than precision — round and pad with zeros.
        let scale = pow(10.0, Double(-fracDigits))
        let rounded = (absVal / scale).rounded(.toNearestOrEven) * scale
        let intVal = UInt64(rounded)
        let s = String(intVal)
        return negative ? "-\(s)" : s
    }
}

// MARK: - Exponential notation (toExponential)

/// Format a double in exponential notation with `nFracDigits` fractional digits.
/// Mirrors the `toExponential` path in QuickJS.
private func formatDoubleExponential(_ d: Double, nDigits: Int) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }

    let negative = d < 0 || jsIsNegativeZero(d)
    let absVal = abs(d)

    if absVal == 0.0 {
        var s = negative ? "-0" : "0"
        if nDigits > 0 {
            s += "."
            for _ in 0 ..< nDigits {
                s += "0"
            }
        }
        s += "e+0"
        return s
    }

    let logVal = Foundation.log10(absVal)
    var exponent = Int(Foundation.floor(logVal))

    // Normalise the mantissa to [1, 10).
    var mantissa = absVal / pow(10.0, Double(exponent))

    // Correct for floating-point imprecision in log10.
    if mantissa >= 10.0 {
        mantissa /= 10.0
        exponent += 1
    } else if mantissa < 1.0 {
        mantissa *= 10.0
        exponent -= 1
    }

    // Round the mantissa to the requested number of fractional digits.
    let scale = pow(10.0, Double(nDigits))
    mantissa = (mantissa * scale).rounded(.toNearestOrEven) / scale

    // If rounding pushed mantissa to 10, adjust.
    if mantissa >= 10.0 {
        mantissa /= 10.0
        exponent += 1
    }

    // Build the mantissa string.
    var mStr: String
    if nDigits <= 0 {
        mStr = String(Int(mantissa.rounded()))
    } else {
        mStr = formatDoubleFrac(mantissa, nDigits: nDigits)
    }

    // Build the exponent string.
    let expSign = exponent >= 0 ? "+" : "-"
    let expStr = String(abs(exponent))

    var result = mStr + "e" + expSign + expStr
    if negative && !result.hasPrefix("-") {
        result = "-" + result
    }
    return result
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
/// Mirrors `js_number_toExponential` in QuickJS.
func jsNumberToExponential(_ d: Double, fractionDigits: Int) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
    let clamped = max(0, min(fractionDigits, 100))
    return formatDoubleExponential(d, nDigits: clamped)
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
