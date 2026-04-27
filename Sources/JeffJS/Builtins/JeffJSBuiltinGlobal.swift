// JeffJSBuiltinGlobal.swift
// JeffJS - 1:1 Swift port of QuickJS JavaScript engine
//
// Port of the global object functions from QuickJS (js_global_*).
// Implements: parseInt, parseFloat, isNaN, isFinite, encodeURI,
// encodeURIComponent, decodeURI, decodeURIComponent, escape, unescape,
// and global property bindings (undefined, NaN, Infinity, globalThis).
//
// QuickJS source reference: quickjs.c -- js_global_parseInt,
// js_global_parseFloat, js_global_isNaN, js_global_isFinite,
// js_global_encodeURI, js_global_decodeURI, js_global_escape,
// js_global_unescape, etc.
// Copyright 2026 Jeff Bachand. All rights reserved.

import Foundation

// MARK: - JeffJSBuiltinGlobal

/// Implements the global object built-in functions for JeffJS.
/// Mirrors QuickJS js_global_* functions and global property setup.
struct JeffJSBuiltinGlobal {

    // MARK: - Intrinsic Registration

    /// Registers global properties and functions on the context's global object.
    /// Mirrors the global-init portion of `JS_AddIntrinsicBaseObjects` in QuickJS.
    ///
    /// Sets up:
    /// - undefined, NaN, Infinity (non-writable, non-enumerable, non-configurable)
    /// - globalThis
    /// - parseInt, parseFloat, isNaN, isFinite
    /// - encodeURI, encodeURIComponent, decodeURI, decodeURIComponent
    /// - escape, unescape
    static func addIntrinsic(ctx: JeffJSContext) {
        let global = ctx.globalObj

        // Global properties
        let atom_undefined = ctx.rt.findAtom("undefined")
        ctx.definePropertyValue(obj: global, atom: atom_undefined,
                                value: .undefined, flags: 0)
        ctx.rt.freeAtom(atom_undefined)

        let atom_NaN = ctx.rt.findAtom("NaN")
        ctx.definePropertyValue(obj: global, atom: atom_NaN,
                                value: .newFloat64(Double.nan), flags: 0)
        ctx.rt.freeAtom(atom_NaN)

        let atom_Infinity = ctx.rt.findAtom("Infinity")
        ctx.definePropertyValue(obj: global, atom: atom_Infinity,
                                value: .newFloat64(Double.infinity), flags: 0)
        ctx.rt.freeAtom(atom_Infinity)

        // Global functions
        addFunc(ctx, global, "parseInt", globalParseInt, 2)
        addFunc(ctx, global, "parseFloat", globalParseFloat, 1)
        addFunc(ctx, global, "isNaN", globalIsNaN, 1)
        addFunc(ctx, global, "isFinite", globalIsFinite, 1)
        addFunc(ctx, global, "decodeURI", decodeURI, 1)
        addFunc(ctx, global, "decodeURIComponent", decodeURIComponent, 1)
        addFunc(ctx, global, "encodeURI", encodeURI, 1)
        addFunc(ctx, global, "encodeURIComponent", encodeURIComponent, 1)
        addFunc(ctx, global, "escape", jsEscape, 1)
        addFunc(ctx, global, "unescape", jsUnescape, 1)

        // globalThis
        ctx.setPropertyStr(obj: global, name: "globalThis", value: global.dupValue())
    }

    // MARK: - Helper: Add a C function to an object

    private static func addFunc(
        _ ctx: JeffJSContext,
        _ obj: JeffJSValue,
        _ name: String,
        _ fn: @escaping (JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue,
        _ length: Int
    ) {
        let f = ctx.newCFunction(fn, name: name, length: length)
        ctx.setPropertyStr(obj: obj, name: name, value: f)
    }

    // MARK: - Whitespace Detection

    /// Checks if a unicode scalar is whitespace per ECMAScript StrWhiteSpaceChar.
    /// Includes all Unicode Space_Separator (Zs) chars, BOM, and line terminators.
    @inline(__always)
    private static func isWhitespace(_ c: UInt32) -> Bool {
        switch c {
        // ASCII whitespace
        case 0x0009, // TAB
             0x000A, // LF
             0x000B, // VT
             0x000C, // FF
             0x000D, // CR
             0x0020, // SPACE
             // Non-ASCII whitespace
             0x00A0, // NBSP
             0x1680, // OGHAM SPACE MARK
             0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005,
             0x2006, 0x2007, 0x2008, 0x2009, 0x200A, // EN QUAD..HAIR SPACE
             0x2028, // LINE SEPARATOR
             0x2029, // PARAGRAPH SEPARATOR
             0x202F, // NARROW NO-BREAK SPACE
             0x205F, // MEDIUM MATHEMATICAL SPACE
             0x3000, // IDEOGRAPHIC SPACE
             0xFEFF: // BOM / ZWNBSP
            return true
        default:
            return false
        }
    }

    // MARK: - parseInt(string, radix)

    /// `parseInt(string, radix)` -- the global parseInt function.
    ///
    /// Full implementation with all radix handling (2-36), hex prefix (0x/0X),
    /// octal prefix (0o/0O), binary prefix (0b/0B), whitespace skipping, and
    /// sign detection. Matches ECMAScript 2025 specification Section 19.2.5.
    ///
    /// Mirrors `js_parseInt` in QuickJS.
    static func globalParseInt(ctx: JeffJSContext, this: JeffJSValue,
                                args: [JeffJSValue]) -> JeffJSValue {
        let inputVal = args.isEmpty ? JeffJSValue.undefined : args[0]

        // Step 1: ToString
        let inputStr = ctx.toString(inputVal)
        if inputStr.isException { return .exception }
        guard let str = ctx.toSwiftString(inputStr) else {
            return .JS_NAN
        }

        let scalars = Array(str.unicodeScalars)
        var pos = 0

        // Step 2: skip leading whitespace
        while pos < scalars.count && isWhitespace(scalars[pos].value) {
            pos += 1
        }

        if pos >= scalars.count {
            return .JS_NAN
        }

        // Step 3: determine sign
        var sign: Double = 1.0
        if scalars[pos].value == 0x2B { // '+'
            pos += 1
        } else if scalars[pos].value == 0x2D { // '-'
            sign = -1.0
            pos += 1
        }

        // Step 4: determine radix
        var radix: Int
        let hasExplicitRadix: Bool
        if args.count >= 2 && !args[1].isUndefined {
            guard let r = ctx.toInt32(args[1]) else {
                return .JS_NAN
            }
            let rInt = Int(r)
            if rInt == 0 {
                radix = 10
                hasExplicitRadix = false
            } else if rInt < 2 || rInt > 36 {
                return .JS_NAN
            } else {
                radix = rInt
                hasExplicitRadix = true
            }
        } else {
            radix = 10
            hasExplicitRadix = false
        }

        // Step 5: check for 0x/0X prefix (hex), 0o/0O (octal), 0b/0B (binary)
        if pos < scalars.count && scalars[pos].value == 0x30 { // '0'
            if pos + 1 < scalars.count {
                let next = scalars[pos + 1].value
                if (next == 0x78 || next == 0x58) { // 'x' or 'X'
                    if !hasExplicitRadix || radix == 16 {
                        radix = 16
                        pos += 2
                    }
                } else if (next == 0x6F || next == 0x4F) { // 'o' or 'O'
                    if !hasExplicitRadix {
                        radix = 8
                        pos += 2
                    }
                } else if (next == 0x62 || next == 0x42) { // 'b' or 'B'
                    if !hasExplicitRadix {
                        radix = 2
                        pos += 2
                    }
                }
            }
        }

        // Step 6: parse digits
        var result: Double = 0.0
        var hasDigit = false
        let radixDouble = Double(radix)

        while pos < scalars.count {
            let digit = digitValue(scalars[pos].value)
            if digit < 0 || digit >= radix {
                break
            }
            hasDigit = true
            result = result * radixDouble + Double(digit)
            pos += 1
        }

        if !hasDigit {
            return .JS_NAN
        }

        result *= sign

        // Optimize: return Int32 if it fits
        if result >= Double(Int32.min) && result <= Double(Int32.max) && result == Foundation.floor(result) {
            return .newInt32(Int32(result))
        }

        return .newFloat64(result)
    }

    /// Helper: get the digit value of a character (0-9, A-Z, a-z).
    /// Returns -1 for non-digit characters.
    @inline(__always)
    private static func digitValue(_ c: UInt32) -> Int {
        if c >= 0x30 && c <= 0x39 { return Int(c - 0x30) }       // '0'-'9'
        if c >= 0x41 && c <= 0x5A { return Int(c - 0x41) + 10 }  // 'A'-'Z'
        if c >= 0x61 && c <= 0x7A { return Int(c - 0x61) + 10 }  // 'a'-'z'
        return -1
    }

    // MARK: - parseFloat(string)

    /// `parseFloat(string)` -- the global parseFloat function.
    ///
    /// Parses a floating-point literal from the beginning of a string.
    /// Handles: sign, integer part, fractional part, exponent, Infinity.
    /// Matches ECMAScript 2025 specification Section 19.2.4.
    ///
    /// Mirrors `js_parseFloat` in QuickJS.
    static func globalParseFloat(ctx: JeffJSContext, this: JeffJSValue,
                                  args: [JeffJSValue]) -> JeffJSValue {
        let inputVal = args.isEmpty ? JeffJSValue.undefined : args[0]
        let inputStr = ctx.toString(inputVal)
        if inputStr.isException { return .exception }
        guard let str = ctx.toSwiftString(inputStr) else {
            return .JS_NAN
        }

        let chars = Array(str)
        var pos = 0

        // Skip leading whitespace
        while pos < chars.count,
              let scalar = chars[pos].unicodeScalars.first,
              isWhitespace(scalar.value) {
            pos += 1
        }

        if pos >= chars.count {
            return .JS_NAN
        }

        // Check for Infinity
        let remaining = String(chars[pos...])
        if remaining.hasPrefix("Infinity") {
            return .JS_POSITIVE_INFINITY
        }
        if remaining.hasPrefix("+Infinity") {
            return .JS_POSITIVE_INFINITY
        }
        if remaining.hasPrefix("-Infinity") {
            return .JS_NEGATIVE_INFINITY
        }

        // Determine sign
        var sign: Double = 1.0
        if pos < chars.count && chars[pos] == "-" {
            sign = -1.0
            pos += 1
        } else if pos < chars.count && chars[pos] == "+" {
            pos += 1
        }

        // Check for Infinity after sign
        if pos + 8 <= chars.count && String(chars[pos..<pos+8]) == "Infinity" {
            return .newFloat64(sign * Double.infinity)
        }

        // Parse digits
        var result: Double = 0.0
        var hasDigit = false
        var hasDot = false
        var fracDiv: Double = 1.0

        // Integer + fractional part
        while pos < chars.count {
            let c = chars[pos]
            if c >= "0" && c <= "9" {
                hasDigit = true
                let d = Double(c.asciiValue! - 48)
                if hasDot {
                    fracDiv *= 10.0
                    result += d / fracDiv
                } else {
                    result = result * 10.0 + d
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
            return .JS_NAN
        }

        // Exponent part
        if pos < chars.count && (chars[pos] == "e" || chars[pos] == "E") {
            let savedPos = pos
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
                result *= Foundation.pow(10.0, expSign * exp)
            } else {
                // No valid exponent digits; revert the 'e' consumption
                pos = savedPos
            }
        }

        result *= sign
        return .newFloat64(result)
    }

    // MARK: - isNaN(number)

    /// `isNaN(number)` -- the global isNaN function.
    ///
    /// Performs ToNumber conversion then checks for NaN.
    /// This is the legacy global isNaN (not Number.isNaN which has no coercion).
    ///
    /// Mirrors `js_global_isNaN` in QuickJS.
    static func globalIsNaN(ctx: JeffJSContext, this: JeffJSValue,
                             args: [JeffJSValue]) -> JeffJSValue {
        let val = args.isEmpty ? JeffJSValue.undefined : args[0]
        guard let d = ctx.toFloat64(val) else {
            // ToNumber threw an exception
            return .exception
        }
        return .newBool(d.isNaN)
    }

    // MARK: - isFinite(number)

    /// `isFinite(number)` -- the global isFinite function.
    ///
    /// Performs ToNumber conversion then checks for finiteness.
    /// This is the legacy global isFinite (not Number.isFinite).
    ///
    /// Mirrors `js_global_isFinite` in QuickJS.
    static func globalIsFinite(ctx: JeffJSContext, this: JeffJSValue,
                                args: [JeffJSValue]) -> JeffJSValue {
        let val = args.isEmpty ? JeffJSValue.undefined : args[0]
        guard let d = ctx.toFloat64(val) else {
            return .exception
        }
        return .newBool(d.isFinite)
    }

    // MARK: - URI Encoding Character Sets

    /// Characters that encodeURI does NOT encode (RFC 3986 unreserved + reserved subset).
    /// A-Z a-z 0-9 ; , / ? : @ & = + $ - _ . ! ~ * ' ( ) #
    private static let encodeURIUnescaped: Set<UInt8> = {
        var s = Set<UInt8>()
        // A-Z
        for c: UInt8 in 0x41...0x5A { s.insert(c) }
        // a-z
        for c: UInt8 in 0x61...0x7A { s.insert(c) }
        // 0-9
        for c: UInt8 in 0x30...0x39 { s.insert(c) }
        // ;,/?:@&=+$-_.!~*'()#
        for c in Array(";,/?:@&=+$-_.!~*'()#".utf8) { s.insert(c) }
        return s
    }()

    /// Characters that encodeURIComponent does NOT encode.
    /// A-Z a-z 0-9 - _ . ! ~ * ' ( )
    private static let encodeURIComponentUnescaped: Set<UInt8> = {
        var s = Set<UInt8>()
        for c: UInt8 in 0x41...0x5A { s.insert(c) }
        for c: UInt8 in 0x61...0x7A { s.insert(c) }
        for c: UInt8 in 0x30...0x39 { s.insert(c) }
        for c in Array("-_.!~*'()".utf8) { s.insert(c) }
        return s
    }()

    /// Characters that escape() does NOT encode.
    /// A-Z a-z 0-9 @ * _ + - . /
    private static let escapeUnescaped: Set<UInt8> = {
        var s = Set<UInt8>()
        for c: UInt8 in 0x41...0x5A { s.insert(c) }
        for c: UInt8 in 0x61...0x7A { s.insert(c) }
        for c: UInt8 in 0x30...0x39 { s.insert(c) }
        for c in Array("@*_+-./".utf8) { s.insert(c) }
        return s
    }()

    // MARK: - Hex Encoding Helpers

    private static let hexDigitsUpper: [Character] = Array("0123456789ABCDEF")

    /// Encode a byte as %XX (uppercase hex).
    @inline(__always)
    private static func percentEncode(_ byte: UInt8) -> String {
        let hi = hexDigitsUpper[Int(byte >> 4)]
        let lo = hexDigitsUpper[Int(byte & 0x0F)]
        return "%\(hi)\(lo)"
    }

    /// Decode a hex character to its numeric value (0-15), or -1 if invalid.
    @inline(__always)
    private static func hexValue(_ c: UInt32) -> Int {
        if c >= 0x30 && c <= 0x39 { return Int(c - 0x30) }       // '0'-'9'
        if c >= 0x41 && c <= 0x46 { return Int(c - 0x41) + 10 }  // 'A'-'F'
        if c >= 0x61 && c <= 0x66 { return Int(c - 0x61) + 10 }  // 'a'-'f'
        return -1
    }

    // MARK: - encodeURI(uriString)

    /// `encodeURI(uriString)` -- encodes a complete URI.
    ///
    /// Encodes all characters except: A-Z a-z 0-9 ; , / ? : @ & = + $ - _ . ! ~ * ' ( ) #
    /// Handles surrogate pairs for characters outside the BMP (U+10000..U+10FFFF).
    /// Throws URIError on lone surrogates.
    ///
    /// Mirrors `js_global_encodeURI` in QuickJS.
    static func encodeURI(ctx: JeffJSContext, this: JeffJSValue,
                           args: [JeffJSValue]) -> JeffJSValue {
        return encodeURIInternal(ctx: ctx, args: args, unescaped: encodeURIUnescaped,
                                 funcName: "encodeURI")
    }

    // MARK: - encodeURIComponent(uriComponent)

    /// `encodeURIComponent(uriComponent)` -- encodes a URI component.
    ///
    /// Encodes all characters except: A-Z a-z 0-9 - _ . ! ~ * ' ( )
    /// Handles surrogate pairs for characters outside the BMP.
    /// Throws URIError on lone surrogates.
    ///
    /// Mirrors `js_global_encodeURIComponent` in QuickJS.
    static func encodeURIComponent(ctx: JeffJSContext, this: JeffJSValue,
                                    args: [JeffJSValue]) -> JeffJSValue {
        return encodeURIInternal(ctx: ctx, args: args, unescaped: encodeURIComponentUnescaped,
                                 funcName: "encodeURIComponent")
    }

    /// Shared implementation for encodeURI and encodeURIComponent.
    private static func encodeURIInternal(ctx: JeffJSContext, args: [JeffJSValue],
                                           unescaped: Set<UInt8>,
                                           funcName: String) -> JeffJSValue {
        let inputVal = args.isEmpty ? JeffJSValue.undefined : args[0]
        let inputStr = ctx.toString(inputVal)
        if inputStr.isException { return .exception }
        guard let str = ctx.toSwiftString(inputStr) else {
            return .exception
        }

        var result = ""
        result.reserveCapacity(str.count)

        let utf16 = Array(str.utf16)
        var i = 0

        while i < utf16.count {
            let c = utf16[i]

            // ASCII fast path: check if the character should be left unescaped
            if c < 0x80 {
                if unescaped.contains(UInt8(c)) {
                    result.append(Character(Unicode.Scalar(c)!))
                    i += 1
                    continue
                }
                // Encode the single ASCII byte
                result += percentEncode(UInt8(c))
                i += 1
                continue
            }

            // Non-ASCII: need to determine the Unicode code point
            var codePoint: UInt32

            if c >= 0xD800 && c <= 0xDBFF {
                // High surrogate -- must be followed by a low surrogate
                if i + 1 >= utf16.count {
                    return ctx.throwURIError(message: "\(funcName): lone high surrogate")
                }
                let low = utf16[i + 1]
                if low < 0xDC00 || low > 0xDFFF {
                    return ctx.throwURIError(message: "\(funcName): lone high surrogate")
                }
                codePoint = 0x10000 + (UInt32(c - 0xD800) << 10) + UInt32(low - 0xDC00)
                i += 2
            } else if c >= 0xDC00 && c <= 0xDFFF {
                // Lone low surrogate
                return ctx.throwURIError(message: "\(funcName): lone low surrogate")
            } else {
                codePoint = UInt32(c)
                i += 1
            }

            // Encode the code point as UTF-8, then percent-encode each byte
            let utf8Bytes = encodeCodePointToUTF8(codePoint)
            for byte in utf8Bytes {
                result += percentEncode(byte)
            }
        }

        return ctx.newStringValue(result)
    }

    /// Encode a Unicode code point as UTF-8 bytes.
    private static func encodeCodePointToUTF8(_ cp: UInt32) -> [UInt8] {
        if cp < 0x80 {
            return [UInt8(cp)]
        } else if cp < 0x800 {
            return [
                UInt8(0xC0 | (cp >> 6)),
                UInt8(0x80 | (cp & 0x3F))
            ]
        } else if cp < 0x10000 {
            return [
                UInt8(0xE0 | (cp >> 12)),
                UInt8(0x80 | ((cp >> 6) & 0x3F)),
                UInt8(0x80 | (cp & 0x3F))
            ]
        } else {
            return [
                UInt8(0xF0 | (cp >> 18)),
                UInt8(0x80 | ((cp >> 12) & 0x3F)),
                UInt8(0x80 | ((cp >> 6) & 0x3F)),
                UInt8(0x80 | (cp & 0x3F))
            ]
        }
    }

    // MARK: - decodeURI(encodedURI)

    /// `decodeURI(encodedURI)` -- decodes a complete URI.
    ///
    /// Decodes %XX sequences except those that would produce URI-reserved characters:
    /// ; / ? : @ & = + $ , #
    /// Validates UTF-8 sequences. Throws URIError on malformed percent-encoding.
    ///
    /// Mirrors `js_global_decodeURI` in QuickJS.
    static func decodeURI(ctx: JeffJSContext, this: JeffJSValue,
                           args: [JeffJSValue]) -> JeffJSValue {
        // Characters that decodeURI should NOT decode even if encoded.
        // These are the URI reserved chars plus '#'.
        let reservedSet: Set<UInt8> = {
            var s = Set<UInt8>()
            for c in Array(";/?:@&=+$,#".utf8) { s.insert(c) }
            return s
        }()
        return decodeURIInternal(ctx: ctx, args: args, reservedSet: reservedSet,
                                 funcName: "decodeURI")
    }

    // MARK: - decodeURIComponent(encodedURIComponent)

    /// `decodeURIComponent(encodedURIComponent)` -- decodes a URI component.
    ///
    /// Decodes all %XX sequences (no reserved set).
    /// Validates UTF-8. Throws URIError on malformed percent-encoding.
    ///
    /// Mirrors `js_global_decodeURIComponent` in QuickJS.
    static func decodeURIComponent(ctx: JeffJSContext, this: JeffJSValue,
                                    args: [JeffJSValue]) -> JeffJSValue {
        return decodeURIInternal(ctx: ctx, args: args, reservedSet: Set<UInt8>(),
                                 funcName: "decodeURIComponent")
    }

    /// Shared implementation for decodeURI and decodeURIComponent.
    ///
    /// - Parameters:
    ///   - reservedSet: ASCII byte values that should NOT be decoded (left as %XX).
    ///   - funcName: Function name for error messages.
    private static func decodeURIInternal(ctx: JeffJSContext, args: [JeffJSValue],
                                           reservedSet: Set<UInt8>,
                                           funcName: String) -> JeffJSValue {
        let inputVal = args.isEmpty ? JeffJSValue.undefined : args[0]
        let inputStr = ctx.toString(inputVal)
        if inputStr.isException { return .exception }
        guard let str = ctx.toSwiftString(inputStr) else {
            return .exception
        }

        var result = ""
        result.reserveCapacity(str.count)

        let chars = Array(str)
        var pos = 0

        while pos < chars.count {
            let c = chars[pos]

            if c != "%" {
                result.append(c)
                pos += 1
                continue
            }

            // We have a '%' -- need at least 2 hex digits after it
            if pos + 2 >= chars.count {
                return ctx.throwURIError(message: "\(funcName): incomplete percent-encoding")
            }

            guard let h1 = hexCharValue(chars[pos + 1]),
                  let h2 = hexCharValue(chars[pos + 2]) else {
                return ctx.throwURIError(message: "\(funcName): invalid hex digits in percent-encoding")
            }

            let byte = UInt8(h1 << 4 | h2)

            // If the byte is ASCII (<0x80), check if it's in the reserved set
            if byte < 0x80 {
                if reservedSet.contains(byte) {
                    // Leave it encoded
                    result.append(contentsOf: chars[pos...pos+2])
                    pos += 3
                } else {
                    result.append(Character(Unicode.Scalar(byte)))
                    pos += 3
                }
                continue
            }

            // Multi-byte UTF-8 sequence
            let expectedLen = utf8SequenceLength(byte)
            if expectedLen < 2 || expectedLen > 4 {
                return ctx.throwURIError(message: "\(funcName): invalid UTF-8 start byte")
            }

            var utf8Bytes = [byte]
            pos += 3

            for _ in 1..<expectedLen {
                if pos >= chars.count || chars[pos] != "%" {
                    return ctx.throwURIError(message: "\(funcName): incomplete UTF-8 sequence")
                }
                if pos + 2 >= chars.count {
                    return ctx.throwURIError(message: "\(funcName): incomplete percent-encoding in UTF-8 sequence")
                }
                guard let ch1 = hexCharValue(chars[pos + 1]),
                      let ch2 = hexCharValue(chars[pos + 2]) else {
                    return ctx.throwURIError(message: "\(funcName): invalid hex digits in UTF-8 continuation")
                }
                let contByte = UInt8(ch1 << 4 | ch2)
                // Validate continuation byte: must be 10xxxxxx
                if contByte & 0xC0 != 0x80 {
                    return ctx.throwURIError(message: "\(funcName): invalid UTF-8 continuation byte")
                }
                utf8Bytes.append(contByte)
                pos += 3
            }

            // Decode the UTF-8 sequence to a Unicode code point
            guard let codePoint = decodeUTF8Sequence(utf8Bytes) else {
                return ctx.throwURIError(message: "\(funcName): invalid UTF-8 sequence")
            }

            // Validate: no surrogates (U+D800..U+DFFF) or overlong encodings
            if codePoint >= 0xD800 && codePoint <= 0xDFFF {
                return ctx.throwURIError(message: "\(funcName): UTF-8 encodes surrogate")
            }
            if codePoint > 0x10FFFF {
                return ctx.throwURIError(message: "\(funcName): UTF-8 code point out of range")
            }

            // Validate no overlong encoding
            let minCodePoint: UInt32
            switch expectedLen {
            case 2: minCodePoint = 0x80
            case 3: minCodePoint = 0x800
            case 4: minCodePoint = 0x10000
            default: minCodePoint = 0
            }
            if codePoint < minCodePoint {
                return ctx.throwURIError(message: "\(funcName): overlong UTF-8 encoding")
            }

            // Append the decoded character
            if let scalar = Unicode.Scalar(codePoint) {
                result.append(Character(scalar))
            } else {
                return ctx.throwURIError(message: "\(funcName): invalid Unicode scalar")
            }
        }

        return ctx.newStringValue(result)
    }

    /// Get the hex value of a Character, or nil if not a valid hex digit.
    @inline(__always)
    private static func hexCharValue(_ c: Character) -> Int? {
        guard let ascii = c.asciiValue else { return nil }
        if ascii >= 0x30 && ascii <= 0x39 { return Int(ascii - 0x30) }
        if ascii >= 0x41 && ascii <= 0x46 { return Int(ascii - 0x41) + 10 }
        if ascii >= 0x61 && ascii <= 0x66 { return Int(ascii - 0x61) + 10 }
        return nil
    }

    /// Determine the expected length of a UTF-8 sequence from its first byte.
    @inline(__always)
    private static func utf8SequenceLength(_ firstByte: UInt8) -> Int {
        if firstByte & 0x80 == 0 { return 1 }        // 0xxxxxxx
        if firstByte & 0xE0 == 0xC0 { return 2 }     // 110xxxxx
        if firstByte & 0xF0 == 0xE0 { return 3 }     // 1110xxxx
        if firstByte & 0xF8 == 0xF0 { return 4 }     // 11110xxx
        return 0 // invalid
    }

    /// Decode a UTF-8 byte sequence into a Unicode code point.
    private static func decodeUTF8Sequence(_ bytes: [UInt8]) -> UInt32? {
        guard !bytes.isEmpty else { return nil }
        let count = bytes.count

        switch count {
        case 1:
            return UInt32(bytes[0])
        case 2:
            let cp = (UInt32(bytes[0] & 0x1F) << 6) |
                     UInt32(bytes[1] & 0x3F)
            return cp
        case 3:
            let cp = (UInt32(bytes[0] & 0x0F) << 12) |
                     (UInt32(bytes[1] & 0x3F) << 6) |
                     UInt32(bytes[2] & 0x3F)
            return cp
        case 4:
            let cp = (UInt32(bytes[0] & 0x07) << 18) |
                     (UInt32(bytes[1] & 0x3F) << 12) |
                     (UInt32(bytes[2] & 0x3F) << 6) |
                     UInt32(bytes[3] & 0x3F)
            return cp
        default:
            return nil
        }
    }

    // MARK: - escape(string)

    /// `escape(string)` -- legacy URI encoding function.
    ///
    /// Encodes all characters except: A-Z a-z 0-9 @ * _ + - . /
    /// Characters with code < 256 are encoded as %XX.
    /// Characters with code >= 256 are encoded as %uXXXX.
    ///
    /// Mirrors `js_global_escape` in QuickJS.
    static func jsEscape(ctx: JeffJSContext, this: JeffJSValue,
                          args: [JeffJSValue]) -> JeffJSValue {
        let inputVal = args.isEmpty ? JeffJSValue.undefined : args[0]
        let inputStr = ctx.toString(inputVal)
        if inputStr.isException { return .exception }
        guard let str = ctx.toSwiftString(inputStr) else {
            return .exception
        }

        var result = ""
        result.reserveCapacity(str.count * 2)

        for scalar in str.unicodeScalars {
            let v = scalar.value

            // ASCII unescaped characters
            if v < 0x80 && escapeUnescaped.contains(UInt8(v)) {
                result.append(Character(scalar))
                continue
            }

            if v < 0x100 {
                // %XX format
                result += percentEncode(UInt8(v))
            } else {
                // %uXXXX format
                let h3 = hexDigitsUpper[Int((v >> 12) & 0xF)]
                let h2 = hexDigitsUpper[Int((v >> 8) & 0xF)]
                let h1 = hexDigitsUpper[Int((v >> 4) & 0xF)]
                let h0 = hexDigitsUpper[Int(v & 0xF)]
                result += "%u\(h3)\(h2)\(h1)\(h0)"
            }
        }

        return ctx.newStringValue(result)
    }

    // MARK: - unescape(string)

    /// `unescape(string)` -- legacy URI decoding function.
    ///
    /// Decodes %XX and %uXXXX sequences. All other characters pass through unchanged.
    ///
    /// Mirrors `js_global_unescape` in QuickJS.
    static func jsUnescape(ctx: JeffJSContext, this: JeffJSValue,
                            args: [JeffJSValue]) -> JeffJSValue {
        let inputVal = args.isEmpty ? JeffJSValue.undefined : args[0]
        let inputStr = ctx.toString(inputVal)
        if inputStr.isException { return .exception }
        guard let str = ctx.toSwiftString(inputStr) else {
            return .exception
        }

        var result = ""
        result.reserveCapacity(str.count)

        let chars = Array(str)
        var pos = 0

        while pos < chars.count {
            let c = chars[pos]

            if c == "%" {
                // Check for %uXXXX
                if pos + 5 < chars.count && chars[pos + 1] == "u" {
                    if let h3 = hexCharValue(chars[pos + 2]),
                       let h2 = hexCharValue(chars[pos + 3]),
                       let h1 = hexCharValue(chars[pos + 4]),
                       let h0 = hexCharValue(chars[pos + 5]) {
                        let code = UInt32(h3 << 12 | h2 << 8 | h1 << 4 | h0)
                        if let scalar = Unicode.Scalar(code) {
                            result.append(Character(scalar))
                        } else {
                            // Invalid scalar, leave as-is
                            result.append(c)
                            pos += 1
                            continue
                        }
                        pos += 6
                        continue
                    }
                }

                // Check for %XX
                if pos + 2 < chars.count {
                    if let h1 = hexCharValue(chars[pos + 1]),
                       let h0 = hexCharValue(chars[pos + 2]) {
                        let code = UInt8(h1 << 4 | h0)
                        result.append(Character(Unicode.Scalar(code)))
                        pos += 3
                        continue
                    }
                }
            }

            // No valid escape sequence -- pass through
            result.append(c)
            pos += 1
        }

        return ctx.newStringValue(result)
    }
}
