// JeffJSUnicode.swift
// JeffJS — 1:1 Swift port of QuickJS libunicode.c
// Copyright 2026 Jeff Bachand. All rights reserved.

import Foundation

// MARK: - JeffJS Unicode Utilities

struct JeffJSUnicode {

    // MARK: - Character Classification

    /// ECMAScript whitespace (includes all WhiteSpace + LineTerminator code points).
    static func isSpace(_ c: UInt32) -> Bool {
        switch c {
        case 0x0009, // TAB
             0x000A, // LF
             0x000B, // VT
             0x000C, // FF
             0x000D, // CR
             0x0020, // SPACE
             0x00A0, // NBSP
             0x1680, // OGHAM SPACE MARK
             0x2000...0x200A, // EN QUAD through HAIR SPACE
             0x2028, // LINE SEPARATOR
             0x2029, // PARAGRAPH SEPARATOR
             0x202F, // NARROW NO-BREAK SPACE
             0x205F, // MEDIUM MATHEMATICAL SPACE
             0x3000, // IDEOGRAPHIC SPACE
             0xFEFF: // ZERO WIDTH NO-BREAK SPACE (BOM)
            return true
        default:
            return false
        }
    }

    /// ECMAScript line terminator.
    static func isLineTerminator(_ c: UInt32) -> Bool {
        return c == 0x000A || c == 0x000D || c == 0x2028 || c == 0x2029
    }

    /// IdentifierStart per ECMAScript.
    static func isIDStart(_ c: UInt32) -> Bool {
        if c < 128 {
            return (c >= 0x41 && c <= 0x5A) || // A-Z
                   (c >= 0x61 && c <= 0x7A) || // a-z
                   c == 0x5F || c == 0x24       // _ $
        }
        return JeffJSUnicodeTable.idStartTable.contains(c)
    }

    /// IdentifierPart per ECMAScript.
    static func isIDContinue(_ c: UInt32) -> Bool {
        if c < 128 {
            return (c >= 0x41 && c <= 0x5A) || // A-Z
                   (c >= 0x61 && c <= 0x7A) || // a-z
                   (c >= 0x30 && c <= 0x39) || // 0-9
                   c == 0x5F || c == 0x24       // _ $
        }
        if c == 0x200C || c == 0x200D { return true } // ZWNJ ZWJ
        return JeffJSUnicodeTable.idContinueTable.contains(c)
    }

    /// ASCII decimal digit.
    static func isDigit(_ c: UInt32) -> Bool {
        return c >= 0x30 && c <= 0x39
    }

    /// ASCII hexadecimal digit.
    static func isHexDigit(_ c: UInt32) -> Bool {
        return (c >= 0x30 && c <= 0x39) ||
               (c >= 0x41 && c <= 0x46) ||
               (c >= 0x61 && c <= 0x66)
    }

    /// Value of a hex digit, or -1 on invalid input.
    static func hexDigitValue(_ c: UInt32) -> Int {
        if c >= 0x30 && c <= 0x39 { return Int(c - 0x30) }
        if c >= 0x41 && c <= 0x46 { return Int(c - 0x41 + 10) }
        if c >= 0x61 && c <= 0x66 { return Int(c - 0x61 + 10) }
        return -1
    }

    // MARK: - Case Conversion

    /// Simple lowercase conversion (1:1 mapping only).
    static func toLower(_ c: UInt32) -> UInt32 {
        if c >= 0x41 && c <= 0x5A { return c + 32 }
        if c < 128 { return c }
        return JeffJSUnicodeTable.simpleLowerCase(c)
    }

    /// Simple uppercase conversion (1:1 mapping only).
    static func toUpper(_ c: UInt32) -> UInt32 {
        if c >= 0x61 && c <= 0x7A { return c - 32 }
        if c < 128 { return c }
        return JeffJSUnicodeTable.simpleUpperCase(c)
    }

    /// Full lowercase conversion (may expand, e.g. capital I with dot -> i + combining dot).
    static func fullLowerCase(_ c: UInt32) -> [UInt32] {
        let result = JeffJSUnicodeTable.fullLowerCase(c)
        if result.isEmpty { return [toLower(c)] }
        return result
    }

    /// Full uppercase conversion (may expand, e.g. sharp-s -> SS).
    static func fullUpperCase(_ c: UInt32) -> [UInt32] {
        let result = JeffJSUnicodeTable.fullUpperCase(c)
        if result.isEmpty { return [toUpper(c)] }
        return result
    }

    /// Case fold for case-insensitive comparison (simple).
    static func caseFold(_ c: UInt32) -> UInt32 {
        return toLower(c)
    }

    // MARK: - Word character (for regex \w)

    /// Returns `true` for [0-9A-Za-z_].
    static func isWordChar(_ c: UInt32) -> Bool {
        return (c >= 0x30 && c <= 0x39) || // 0-9
               (c >= 0x41 && c <= 0x5A) || // A-Z
               (c >= 0x61 && c <= 0x7A) || // a-z
               c == 0x5F                    // _
    }

    // MARK: - Unicode general categories

    /// Look up the general category.
    static func getCategory(_ c: UInt32) -> UnicodeCategory {
        return JeffJSUnicodeTable.getCategory(c)
    }

    /// Any letter category (Lu, Ll, Lt, Lm, Lo).
    static func isLetter(_ c: UInt32) -> Bool {
        let cat = getCategory(c)
        return cat == .Lu || cat == .Ll || cat == .Lt || cat == .Lm || cat == .Lo
    }

    /// Cased letter (Lu, Ll, Lt).
    static func isCased(_ c: UInt32) -> Bool {
        let cat = getCategory(c)
        return cat == .Lu || cat == .Ll || cat == .Lt
    }

    /// Unicode alphabetic property.
    static func isAlpha(_ c: UInt32) -> Bool {
        return isLetter(c) || getCategory(c) == .Nl
    }

    // MARK: - UTF-8 / UTF-16 Conversion

    /// Decode a single UTF-8 character from a byte array.
    static func utf8Decode(_ bytes: [UInt8], at offset: Int) -> (codePoint: UInt32, length: Int) {
        guard offset < bytes.count else { return (0xFFFD, 1) }
        let b0 = bytes[offset]

        if b0 < 0x80 {
            return (UInt32(b0), 1)
        } else if b0 < 0xC0 {
            // Unexpected continuation byte
            return (0xFFFD, 1)
        } else if b0 < 0xE0 {
            guard offset + 1 < bytes.count else { return (0xFFFD, 1) }
            let b1 = bytes[offset + 1]
            if b1 & 0xC0 != 0x80 { return (0xFFFD, 1) }
            let cp = (UInt32(b0 & 0x1F) << 6) | UInt32(b1 & 0x3F)
            if cp < 0x80 { return (0xFFFD, 2) } // overlong
            return (cp, 2)
        } else if b0 < 0xF0 {
            guard offset + 2 < bytes.count else { return (0xFFFD, 1) }
            let b1 = bytes[offset + 1]
            let b2 = bytes[offset + 2]
            if b1 & 0xC0 != 0x80 || b2 & 0xC0 != 0x80 { return (0xFFFD, 1) }
            let cp = (UInt32(b0 & 0x0F) << 12) | (UInt32(b1 & 0x3F) << 6) | UInt32(b2 & 0x3F)
            if cp < 0x800 { return (0xFFFD, 3) } // overlong
            if cp >= 0xD800 && cp <= 0xDFFF { return (0xFFFD, 3) } // surrogate
            return (cp, 3)
        } else if b0 < 0xF8 {
            guard offset + 3 < bytes.count else { return (0xFFFD, 1) }
            let b1 = bytes[offset + 1]
            let b2 = bytes[offset + 2]
            let b3 = bytes[offset + 3]
            if b1 & 0xC0 != 0x80 || b2 & 0xC0 != 0x80 || b3 & 0xC0 != 0x80 {
                return (0xFFFD, 1)
            }
            let cp = (UInt32(b0 & 0x07) << 18) | (UInt32(b1 & 0x3F) << 12) |
                     (UInt32(b2 & 0x3F) << 6) | UInt32(b3 & 0x3F)
            if cp < 0x10000 || cp > 0x10FFFF { return (0xFFFD, 4) }
            return (cp, 4)
        }
        return (0xFFFD, 1)
    }

    /// Encode a code point to UTF-8 bytes.
    static func utf8Encode(_ cp: UInt32) -> [UInt8] {
        if cp < 0x80 {
            return [UInt8(cp)]
        } else if cp < 0x800 {
            return [
                UInt8(0xC0 | (cp >> 6)),
                UInt8(0x80 | (cp & 0x3F)),
            ]
        } else if cp < 0x10000 {
            return [
                UInt8(0xE0 | (cp >> 12)),
                UInt8(0x80 | ((cp >> 6) & 0x3F)),
                UInt8(0x80 | (cp & 0x3F)),
            ]
        } else {
            return [
                UInt8(0xF0 | (cp >> 18)),
                UInt8(0x80 | ((cp >> 12) & 0x3F)),
                UInt8(0x80 | ((cp >> 6) & 0x3F)),
                UInt8(0x80 | (cp & 0x3F)),
            ]
        }
    }

    /// Length in bytes of a UTF-8 encoding for `cp`.
    static func utf8EncodedLength(_ cp: UInt32) -> Int {
        if cp < 0x80 { return 1 }
        if cp < 0x800 { return 2 }
        if cp < 0x10000 { return 3 }
        return 4
    }

    /// Check if code unit is a high surrogate (U+D800..U+DBFF).
    static func isHiSurrogate(_ c: UInt32) -> Bool {
        return c >= 0xD800 && c <= 0xDBFF
    }

    /// Check if code unit is a low surrogate (U+DC00..U+DFFF).
    static func isLoSurrogate(_ c: UInt32) -> Bool {
        return c >= 0xDC00 && c <= 0xDFFF
    }

    /// Combine a surrogate pair into a code point.
    static func fromSurrogates(_ hi: UInt32, _ lo: UInt32) -> UInt32 {
        return ((hi - 0xD800) << 10) + (lo - 0xDC00) + 0x10000
    }

    /// Split a supplementary code point into a surrogate pair.
    static func toSurrogates(_ cp: UInt32) -> (hi: UInt16, lo: UInt16) {
        let c = cp - 0x10000
        return (UInt16(0xD800 + (c >> 10)), UInt16(0xDC00 + (c & 0x3FF)))
    }

    // MARK: - String helpers

    /// Convert a Swift String to an array of UTF-16 code units.
    static func stringToUTF16(_ s: String) -> [UInt16] {
        return Array(s.utf16)
    }

    /// Convert an array of UTF-16 code units to code points, decoding surrogate pairs.
    static func utf16ToCodePoints(_ units: [UInt16]) -> [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(units.count)
        var i = 0
        while i < units.count {
            let u = UInt32(units[i])
            if isHiSurrogate(u) && i + 1 < units.count {
                let lo = UInt32(units[i + 1])
                if isLoSurrogate(lo) {
                    result.append(fromSurrogates(u, lo))
                    i += 2
                    continue
                }
            }
            result.append(u)
            i += 1
        }
        return result
    }

    /// Convert an array of code points to UTF-16 code units.
    static func codePointsToUTF16(_ cps: [UInt32]) -> [UInt16] {
        var result: [UInt16] = []
        result.reserveCapacity(cps.count)
        for cp in cps {
            if cp >= 0x10000 {
                let pair = toSurrogates(cp)
                result.append(pair.hi)
                result.append(pair.lo)
            } else {
                result.append(UInt16(cp))
            }
        }
        return result
    }

    // MARK: - Normalization

    enum NormalizationForm {
        case NFC, NFD, NFKC, NFKD
    }

    /// Normalize an array of code points.
    static func normalize(_ input: [UInt32], form: NormalizationForm) -> [UInt32] {
        switch form {
        case .NFC:
            let decomposed = decomposeCanonical(input)
            return composeCanonical(decomposed)
        case .NFD:
            return decomposeCanonical(input)
        case .NFKC:
            let decomposed = decomposeCompatibility(input)
            return composeCanonical(decomposed)
        case .NFKD:
            return decomposeCompatibility(input)
        }
    }

    /// Quick check: is the string already in NFC?
    static func isNFC(_ input: [UInt32]) -> Bool {
        var lastCCC: Int = 0
        for cp in input {
            let ccc = JeffJSUnicodeTable.getCombiningClass(cp)
            if ccc != 0 && lastCCC > ccc { return false }
            let decomp = JeffJSUnicodeTable.decompose(cp) ?? []
            if !decomp.isEmpty { return false }
            lastCCC = Int(ccc)
        }
        return true
    }

    // -- Decomposition helpers ------------------------------------------------

    private static func decomposeCanonical(_ input: [UInt32]) -> [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(input.count)
        for cp in input {
            decomposeCanonicalOne(cp, into: &result)
        }
        sortByCCC(&result)
        return result
    }

    private static func decomposeCanonicalOne(_ cp: UInt32, into result: inout [UInt32]) {
        // Hangul decomposition (algorithmic)
        if cp >= 0xAC00 && cp <= 0xD7A3 {
            let sIndex = cp - 0xAC00
            let l = 0x1100 + sIndex / (21 * 28)
            let v = 0x1161 + (sIndex % (21 * 28)) / 28
            let t = 0x11A7 + sIndex % 28
            result.append(l)
            result.append(v)
            if t != 0x11A7 { result.append(t) }
            return
        }

        let decomp = JeffJSUnicodeTable.decompose(cp) ?? []
        if decomp.isEmpty {
            result.append(cp)
        } else {
            for d in decomp {
                decomposeCanonicalOne(d, into: &result)
            }
        }
    }

    private static func decomposeCompatibility(_ input: [UInt32]) -> [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(input.count)
        for cp in input {
            decomposeCompatibilityOne(cp, into: &result)
        }
        sortByCCC(&result)
        return result
    }

    private static func decomposeCompatibilityOne(_ cp: UInt32, into result: inout [UInt32]) {
        // Hangul decomposition
        if cp >= 0xAC00 && cp <= 0xD7A3 {
            let sIndex = cp - 0xAC00
            let l = 0x1100 + sIndex / (21 * 28)
            let v = 0x1161 + (sIndex % (21 * 28)) / 28
            let t = 0x11A7 + sIndex % 28
            result.append(l)
            result.append(v)
            if t != 0x11A7 { result.append(t) }
            return
        }

        let compat = JeffJSUnicodeTable.decompose(cp) ?? []
        if !compat.isEmpty {
            for d in compat {
                decomposeCompatibilityOne(d, into: &result)
            }
            return
        }
        let canonical = JeffJSUnicodeTable.decompose(cp) ?? []
        if !canonical.isEmpty {
            for d in canonical {
                decomposeCompatibilityOne(d, into: &result)
            }
            return
        }
        result.append(cp)
    }

    /// Stable sort by canonical combining class (bubble-sort on runs of non-starters).
    private static func sortByCCC(_ chars: inout [UInt32]) {
        guard chars.count > 1 else { return }
        var i = 1
        while i < chars.count {
            let ccc = JeffJSUnicodeTable.getCombiningClass(chars[i])
            if ccc != 0 {
                var j = i
                while j > 0 {
                    let prevCCC = JeffJSUnicodeTable.getCombiningClass(chars[j - 1])
                    if prevCCC <= ccc { break }
                    chars.swapAt(j, j - 1)
                    j -= 1
                }
            }
            i += 1
        }
    }

    /// Canonical composition (after canonical decomposition gives NFC).
    private static func composeCanonical(_ input: [UInt32]) -> [UInt32] {
        guard !input.isEmpty else { return [] }
        var result: [UInt32] = []
        result.reserveCapacity(input.count)
        result.append(input[0])
        var lastStarter = 0

        for i in 1..<input.count {
            let cp = input[i]
            let ccc = JeffJSUnicodeTable.getCombiningClass(cp)

            // Hangul composition (algorithmic)
            let starterCP = result[lastStarter]
            if let composed = hangulCompose(starterCP, cp) {
                let prevCCC = i > 1 ? JeffJSUnicodeTable.getCombiningClass(input[i - 1]) : 0
                if lastStarter == result.count - 1 || prevCCC < ccc {
                    result[lastStarter] = composed
                    continue
                }
            }

            if let composed = JeffJSUnicodeTable.compose(starterCP, cp) {
                let prevCCC = i > 1 ? JeffJSUnicodeTable.getCombiningClass(input[i - 1]) : 0
                if lastStarter == result.count - 1 || prevCCC < ccc {
                    result[lastStarter] = composed
                    continue
                }
            }

            result.append(cp)
            if ccc == 0 {
                lastStarter = result.count - 1
            }
        }
        return result
    }

    /// Hangul LV + T or L + V composition (algorithmic).
    private static func hangulCompose(_ a: UInt32, _ b: UInt32) -> UInt32? {
        // L + V -> LV
        if a >= 0x1100 && a <= 0x1112 && b >= 0x1161 && b <= 0x1175 {
            return 0xAC00 + (a - 0x1100) * 21 * 28 + (b - 0x1161) * 28
        }
        // LV + T -> LVT
        if a >= 0xAC00 && a <= 0xD7A3 && (a - 0xAC00) % 28 == 0 &&
           b >= 0x11A8 && b <= 0x11C2 {
            return a + (b - 0x11A7)
        }
        return nil
    }
}
