// JeffJSRegExp.swift
// JeffJS — 1:1 Swift port of QuickJS libregexp.c
// Copyright 2026 Jeff Bachand. All rights reserved.
//
// ECMAScript-compliant regex compiler (pattern -> bytecode) and
// backtracking VM (bytecode + input -> match result + captures).
//
// This is a faithful port of libregexp.c.  Naming intentionally mirrors the
// C original (lre_*) so the two can be compared side-by-side.

import Foundation

// ============================================================================
// MARK: - Flags
// ============================================================================

struct JeffJSRegExpFlags: OptionSet, Sendable {
    let rawValue: Int

    // ECMAScript-visible flags
    static let global       = JeffJSRegExpFlags(rawValue: 1 << 0)   // g
    static let ignoreCase   = JeffJSRegExpFlags(rawValue: 1 << 1)   // i
    static let multiline    = JeffJSRegExpFlags(rawValue: 1 << 2)   // m
    static let dotAll       = JeffJSRegExpFlags(rawValue: 1 << 3)   // s
    static let unicode      = JeffJSRegExpFlags(rawValue: 1 << 4)   // u
    static let sticky       = JeffJSRegExpFlags(rawValue: 1 << 5)   // y
    static let hasIndices   = JeffJSRegExpFlags(rawValue: 1 << 6)   // d
    static let unicodeSets  = JeffJSRegExpFlags(rawValue: 1 << 7)   // v

    // Internal flags (not in the source pattern)
    static let named        = JeffJSRegExpFlags(rawValue: 1 << 8)
    static let utf16        = JeffJSRegExpFlags(rawValue: 1 << 9)

    /// Whether the pattern is in full-unicode mode (u or v flag).
    var isUnicode: Bool { contains(.unicode) || contains(.unicodeSets) }
}

// ============================================================================
// MARK: - CharRange
// ============================================================================

/// An inclusive range of Unicode code points [lo, hi].
struct CharRange: Equatable {
    var lo: UInt32
    var hi: UInt32

    init(_ lo: UInt32, _ hi: UInt32) {
        self.lo = lo
        self.hi = hi
    }

    init(_ single: UInt32) {
        self.lo = single
        self.hi = single
    }
}

// ============================================================================
// MARK: - CharRange set operations
// ============================================================================

/// Normalise a range list: sort by lo then hi, merge overlapping/adjacent.
private func crNormalize(_ ranges: [CharRange]) -> [CharRange] {
    guard ranges.count > 1 else { return ranges }
    var sorted = ranges.sorted { $0.lo < $1.lo || ($0.lo == $1.lo && $0.hi < $1.hi) }
    var out = [CharRange]()
    out.reserveCapacity(sorted.count)
    out.append(sorted[0])
    for i in 1 ..< sorted.count {
        let cur = sorted[i]
        if cur.lo <= out[out.count - 1].hi &+ 1 {
            out[out.count - 1].hi = max(out[out.count - 1].hi, cur.hi)
        } else {
            out.append(cur)
        }
    }
    return out
}

/// Add a single code point to a range list.
func crAddChar(_ ranges: inout [CharRange], _ c: UInt32) {
    ranges.append(CharRange(c))
}

/// Add an inclusive range [lo, hi] to a range list.
func crAddRange(_ ranges: inout [CharRange], _ lo: UInt32, _ hi: UInt32) {
    if lo <= hi {
        ranges.append(CharRange(lo, hi))
    }
}

/// Complement the character class over [0, 0x10FFFF].
func crComplement(_ ranges: [CharRange]) -> [CharRange] {
    let norm = crNormalize(ranges)
    var out = [CharRange]()
    var prev: UInt32 = 0
    for r in norm {
        if r.lo > prev {
            out.append(CharRange(prev, r.lo - 1))
        }
        prev = r.hi &+ 1
        if prev == 0 { return out } // wrapped past 0x10FFFF
    }
    if prev <= 0x10FFFF {
        out.append(CharRange(prev, 0x10FFFF))
    }
    return out
}

/// Union of two sorted, normalised range lists.
func crUnion(_ a: [CharRange], _ b: [CharRange]) -> [CharRange] {
    var combined = a
    combined.append(contentsOf: b)
    return crNormalize(combined)
}

/// Intersection of two sorted, normalised range lists.
func crIntersection(_ a: [CharRange], _ b: [CharRange]) -> [CharRange] {
    let na = crNormalize(a)
    let nb = crNormalize(b)
    var out = [CharRange]()
    var i = 0, j = 0
    while i < na.count && j < nb.count {
        let lo = max(na[i].lo, nb[j].lo)
        let hi = min(na[i].hi, nb[j].hi)
        if lo <= hi {
            out.append(CharRange(lo, hi))
        }
        if na[i].hi < nb[j].hi {
            i += 1
        } else {
            j += 1
        }
    }
    return out
}

/// Subtraction:  a \ b.
func crSubtraction(_ a: [CharRange], _ b: [CharRange]) -> [CharRange] {
    return crIntersection(a, crComplement(b))
}

/// Test membership.
func crContains(_ ranges: [CharRange], _ c: UInt32) -> Bool {
    // Binary search on a normalised list.
    let norm = ranges // Caller should pass normalised, but tolerate unsorted.
    var lo = 0, hi = norm.count - 1
    while lo <= hi {
        let mid = (lo + hi) / 2
        if c < norm[mid].lo {
            hi = mid - 1
        } else if c > norm[mid].hi {
            lo = mid + 1
        } else {
            return true
        }
    }
    return false
}

// ============================================================================
// MARK: - Character classification helpers
// ============================================================================

/// ECMAScript WhiteSpace + LineTerminator (\s).
func lreIsSpace(_ c: UInt32) -> Bool {
    switch c {
    case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680,
         0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
        return true
    default:
        return false
    }
}

/// ECMAScript \w character (word character).
func lreIsWordChar(_ c: UInt32) -> Bool {
    if c >= UInt32(Character("a").asciiValue!) && c <= UInt32(Character("z").asciiValue!) { return true }
    if c >= UInt32(Character("A").asciiValue!) && c <= UInt32(Character("Z").asciiValue!) { return true }
    if c >= UInt32(Character("0").asciiValue!) && c <= UInt32(Character("9").asciiValue!) { return true }
    if c == UInt32(Character("_").asciiValue!) { return true }
    return false
}

/// ECMAScript \d character.
private func lreIsDigit(_ c: UInt32) -> Bool {
    return c >= 0x30 && c <= 0x39
}

/// ECMAScript LineTerminator.
private func lreIsLineTerminator(_ c: UInt32) -> Bool {
    return c == 0x0A || c == 0x0D || c == 0x2028 || c == 0x2029
}

// ============================================================================
// MARK: - Case folding helpers
// ============================================================================

/// Simple case fold for Canonicalize (non-unicode mode):
/// Only folds ASCII letters. This mirrors QuickJS's behaviour for the 'i'
/// flag without 'u'/'v'.
func lreCanonicalizeChar(_ c: UInt32, _ flags: JeffJSRegExpFlags) -> UInt32 {
    if flags.isUnicode {
        return lreCanonicalizeUnicode(c)
    }
    // Non-unicode: only fold ASCII A-Z <-> a-z.
    if c >= 0x41 && c <= 0x5A { return c + 0x20 }
    if c >= 0x61 && c <= 0x7A { return c - 0x20 }
    return c
}

/// Unicode-mode case fold (simple case folding from CaseFolding.txt, status C+S).
/// For a full engine this table would be thousands of entries; we implement the
/// most important folds here and fall back to Foundation for the rest.
private func lreCanonicalizeUnicode(_ c: UInt32) -> UInt32 {
    guard let scalar = Unicode.Scalar(c) else { return c }
    let str = String(scalar).lowercased()
    if let first = str.unicodeScalars.first {
        return first.value
    }
    return c
}

/// Case conversion that may expand (e.g. German sharp-s -> "SS").
/// Returns an array of code points.
func lreCaseConv(_ c: UInt32, isUpper: Bool) -> [UInt32] {
    guard let scalar = Unicode.Scalar(c) else { return [c] }
    let str = String(scalar)
    let converted = isUpper ? str.uppercased() : str.lowercased()
    return Array(converted.unicodeScalars.map { $0.value })
}

// ============================================================================
// MARK: - Unicode property support (for \p{...} / \P{...})
// ============================================================================

/// Returns the set of CharRanges for a Unicode property name or value.
/// Supports General_Category values, Script values, and binary properties.
private func lreGetUnicodePropertyRanges(_ name: String, negate: Bool) -> [CharRange]? {
    // Canonical name comparison: strip underscores/hyphens/spaces, lowercase.
    let key = name.lowercased().replacingOccurrences(of: "_", with: "")
                  .replacingOccurrences(of: "-", with: "")
                  .replacingOccurrences(of: " ", with: "")

    var ranges: [CharRange]? = nil

    // --- General Category shortcuts ---
    switch key {
    case "l", "letter":
        ranges = lreUnicodeCategoryRanges { $0.isLetter }
    case "lu", "uppercaseletter":
        ranges = lreUnicodeCategoryRanges { $0.properties.isUppercase }
    case "ll", "lowercaseletter":
        ranges = lreUnicodeCategoryRanges { $0.properties.isLowercase }
    case "lt", "titlecaseletter":
        // Title-case letters are rare; approximate via checking both cases.
        ranges = lreUnicodeCategoryRanges {
            $0.properties.isUppercase && $0.properties.isLowercase
        }
    case "lm", "modifierletter":
        ranges = lreUnicodeCategoryRanges { $0.isLetter && !$0.properties.isUppercase && !$0.properties.isLowercase }
    case "lo", "otherletter":
        ranges = lreUnicodeCategoryRanges { $0.isLetter && !$0.properties.isUppercase && !$0.properties.isLowercase }
    case "n", "number":
        ranges = lreUnicodeCategoryRanges { $0.properties.numericType != nil }
    case "nd", "decimalnumber", "decimaldigit":
        ranges = lreUnicodeCategoryRanges {
            if let nt = $0.properties.numericType { return nt == .decimal }
            return false
        }
    case "nl", "letternumber":
        ranges = lreUnicodeCategoryRanges {
            if let nt = $0.properties.numericType { return nt == .digit }
            return false
        }
    case "no", "othernumber":
        ranges = lreUnicodeCategoryRanges {
            if let nt = $0.properties.numericType { return nt == .numeric }
            return false
        }
    case "p", "punctuation":
        ranges = lreUnicodeCategoryRanges { $0.properties.generalCategory._isPunctuation }
    case "s", "symbol":
        ranges = lreUnicodeCategoryRanges { $0.properties.generalCategory._isSymbol }
    case "z", "separator":
        ranges = lreUnicodeCategoryRanges { $0.properties.generalCategory._isSeparator }
    case "zs", "spaceseparator":
        ranges = lreUnicodeCategoryRanges { $0.properties.generalCategory == .spaceSeparator }
    case "zl", "lineseparator":
        ranges = lreUnicodeCategoryRanges { $0.properties.generalCategory == .lineSeparator }
    case "zp", "paragraphseparator":
        ranges = lreUnicodeCategoryRanges { $0.properties.generalCategory == .paragraphSeparator }
    case "c", "other":
        ranges = lreUnicodeCategoryRanges { $0.properties.generalCategory._isOther }
    case "cc", "control":
        ranges = lreUnicodeCategoryRanges { $0.properties.generalCategory == .control }
    case "cf", "format":
        ranges = lreUnicodeCategoryRanges { $0.properties.generalCategory == .format }
    case "cn", "unassigned":
        // Unassigned: everything not assigned a valid scalar.
        // Approximate with the complement of all assigned.
        ranges = lreUnicodeCategoryRanges { _ in false }
        if ranges != nil { ranges = crComplement(ranges!) }
    case "m", "mark":
        ranges = lreUnicodeCategoryRanges { $0.properties.generalCategory._isMark }
    case "mn", "nonspacingmark":
        ranges = lreUnicodeCategoryRanges { $0.properties.generalCategory == .nonspacingMark }
    case "mc", "spacingmark":
        ranges = lreUnicodeCategoryRanges { $0.properties.generalCategory == .spacingMark }
    case "me", "enclosingmark":
        ranges = lreUnicodeCategoryRanges { $0.properties.generalCategory == .enclosingMark }

    // --- Binary properties ---
    case "ascii":
        ranges = [CharRange(0, 0x7F)]
    case "alphabetic":
        ranges = lreUnicodeCategoryRanges { $0.properties.isAlphabetic }
    case "any":
        ranges = [CharRange(0, 0x10FFFF)]
    case "assigned":
        ranges = lreUnicodeCategoryRanges { _ in true }
    case "asciihexdigit":
        ranges = [CharRange(0x30, 0x39), CharRange(0x41, 0x46), CharRange(0x61, 0x66)]
    case "uppercase":
        ranges = lreUnicodeCategoryRanges { $0.properties.isUppercase }
    case "lowercase":
        ranges = lreUnicodeCategoryRanges { $0.properties.isLowercase }
    case "whitespace":
        ranges = lreUnicodeCategoryRanges { $0.properties.isWhitespace }
    case "emoji":
        ranges = lreUnicodeCategoryRanges { $0.properties.isEmoji }
    case "emojipresentation":
        ranges = lreUnicodeCategoryRanges { $0.properties.isEmojiPresentation }
    case "emojimodifier":
        ranges = lreUnicodeCategoryRanges { $0.properties.isEmojiModifier }
    case "emojimodifierbase":
        ranges = lreUnicodeCategoryRanges { $0.properties.isEmojiModifierBase }
    case "emojicomponent":
        // Emoji_Component (Unicode 15.1): keycap bases, VS16, ZWJ, skin tone modifiers, tag chars
        ranges = [
            CharRange(0x0023, 0x0023), CharRange(0x002A, 0x002A), CharRange(0x0030, 0x0039),
            CharRange(0x200D, 0x200D), CharRange(0xFE0F, 0xFE0F), CharRange(0x20E3, 0x20E3),
            CharRange(0x1F1E6, 0x1F1FF), CharRange(0x1F3FB, 0x1F3FF),
            CharRange(0xE0020, 0xE007F),
        ]
    case "regionalindicator":
        ranges = [CharRange(0x1F1E6, 0x1F1FF)]
    case "extendedpictographic":
        // Extended_Pictographic (Unicode 15.1) — full range table
        ranges = [
            // BMP
            CharRange(0x0023, 0x0023), CharRange(0x002A, 0x002A), CharRange(0x0030, 0x0039),
            CharRange(0x00A9, 0x00A9), CharRange(0x00AE, 0x00AE),
            CharRange(0x203C, 0x203C), CharRange(0x2049, 0x2049),
            CharRange(0x2122, 0x2122), CharRange(0x2139, 0x2139),
            CharRange(0x2194, 0x2199), CharRange(0x21A9, 0x21AA),
            CharRange(0x231A, 0x231B), CharRange(0x2328, 0x2328),
            CharRange(0x23CF, 0x23CF), CharRange(0x23E9, 0x23F3), CharRange(0x23F8, 0x23FA),
            CharRange(0x24C2, 0x24C2),
            CharRange(0x25AA, 0x25AB), CharRange(0x25B6, 0x25B6),
            CharRange(0x25C0, 0x25C0), CharRange(0x25FB, 0x25FE),
            CharRange(0x2600, 0x2605), CharRange(0x2607, 0x2612),
            CharRange(0x2614, 0x2685), CharRange(0x2690, 0x2705),
            CharRange(0x2708, 0x2767), CharRange(0x2795, 0x27BF),
            CharRange(0x2934, 0x2935),
            CharRange(0x2B05, 0x2B07), CharRange(0x2B1B, 0x2B1C),
            CharRange(0x2B50, 0x2B50), CharRange(0x2B55, 0x2B55),
            CharRange(0x3030, 0x3030), CharRange(0x303D, 0x303D),
            CharRange(0x3297, 0x3297), CharRange(0x3299, 0x3299),
            // SMP: Mahjong, Playing Cards
            CharRange(0x1F004, 0x1F004), CharRange(0x1F0CF, 0x1F0CF),
            // SMP: Enclosed Alphanumeric Supplement
            CharRange(0x1F170, 0x1F171), CharRange(0x1F17E, 0x1F17F),
            CharRange(0x1F18E, 0x1F18E), CharRange(0x1F191, 0x1F19A),
            // SMP: Regional Indicators
            CharRange(0x1F1E0, 0x1F1FF),
            // SMP: Enclosed Ideographic Supplement
            CharRange(0x1F201, 0x1F202), CharRange(0x1F21A, 0x1F21A),
            CharRange(0x1F22F, 0x1F22F), CharRange(0x1F232, 0x1F23A),
            CharRange(0x1F250, 0x1F251),
            // SMP: Misc Symbols and Pictographs, Emoticons, Transport
            CharRange(0x1F300, 0x1F321), CharRange(0x1F324, 0x1F393),
            CharRange(0x1F396, 0x1F397), CharRange(0x1F399, 0x1F39B),
            CharRange(0x1F39E, 0x1F3F0), CharRange(0x1F3F3, 0x1F3F5),
            CharRange(0x1F3F7, 0x1F4FD), CharRange(0x1F4FF, 0x1F53D),
            CharRange(0x1F549, 0x1F54E), CharRange(0x1F550, 0x1F567),
            CharRange(0x1F56F, 0x1F570), CharRange(0x1F573, 0x1F57A),
            CharRange(0x1F587, 0x1F587), CharRange(0x1F58A, 0x1F58D),
            CharRange(0x1F590, 0x1F590), CharRange(0x1F595, 0x1F596),
            CharRange(0x1F5A4, 0x1F5A5), CharRange(0x1F5A8, 0x1F5A8),
            CharRange(0x1F5B1, 0x1F5B2), CharRange(0x1F5BC, 0x1F5BC),
            CharRange(0x1F5C2, 0x1F5C4), CharRange(0x1F5D1, 0x1F5D3),
            CharRange(0x1F5DC, 0x1F5DE), CharRange(0x1F5E1, 0x1F5E1),
            CharRange(0x1F5E3, 0x1F5E3), CharRange(0x1F5E8, 0x1F5E8),
            CharRange(0x1F5EF, 0x1F5EF), CharRange(0x1F5F3, 0x1F5F3),
            CharRange(0x1F5FA, 0x1F64F),
            CharRange(0x1F680, 0x1F6C5), CharRange(0x1F6CB, 0x1F6D2),
            CharRange(0x1F6D5, 0x1F6D7), CharRange(0x1F6DC, 0x1F6E5),
            CharRange(0x1F6E9, 0x1F6E9), CharRange(0x1F6EB, 0x1F6EC),
            CharRange(0x1F6F0, 0x1F6F0), CharRange(0x1F6F3, 0x1F6FC),
            // SMP: Geometric Shapes Extended, Supplemental Symbols
            CharRange(0x1F7E0, 0x1F7EB), CharRange(0x1F7F0, 0x1F7F0),
            CharRange(0x1F90C, 0x1F93A), CharRange(0x1F93C, 0x1F945),
            CharRange(0x1F947, 0x1F9FF),
            // SMP: Chess, Symbols Extended-A, reserved
            CharRange(0x1FA00, 0x1FA53), CharRange(0x1FA60, 0x1FA6D),
            CharRange(0x1FA70, 0x1FA7C), CharRange(0x1FA80, 0x1FA89),
            CharRange(0x1FA8F, 0x1FAC6), CharRange(0x1FACE, 0x1FADC),
            CharRange(0x1FAE0, 0x1FAE9), CharRange(0x1FAF0, 0x1FAF8),
            CharRange(0x1FC00, 0x1FFFD),
        ]

    // --- Script / Script_Extensions (common ones) ---
    default:
        ranges = lreGetScriptRanges(key)
    }

    guard var result = ranges else { return nil }
    result = crNormalize(result)
    if negate {
        result = crComplement(result)
    }
    return result
}

/// Build character ranges by scanning Unicode scalars that match a predicate.
/// We scan BMP + a small portion of supplementary planes.
private func lreUnicodeCategoryRanges(_ predicate: (Unicode.Scalar) -> Bool) -> [CharRange] {
    var ranges = [CharRange]()
    var runStart: UInt32? = nil

    func scan(_ lo: UInt32, _ hi: UInt32) {
        var i = lo
        while i <= hi {
            if let scalar = Unicode.Scalar(i), predicate(scalar) {
                if runStart == nil { runStart = i }
            } else {
                if let rs = runStart {
                    ranges.append(CharRange(rs, i - 1))
                    runStart = nil
                }
            }
            if i == hi { break }
            i += 1
        }
        if let rs = runStart {
            ranges.append(CharRange(rs, hi))
            runStart = nil
        }
    }

    // BMP (skip surrogates)
    scan(0, 0xD7FF)
    scan(0xE000, 0xFFFF)
    // Supplementary (common blocks)
    scan(0x10000, 0x1FFFF)
    scan(0x20000, 0x2FA1F)
    // Emoji block
    scan(0x1F000, 0x1FAFF)

    return ranges
}

/// Get character ranges for a script name (very common ones only).
/// For a production engine this would use ICU or a generated table.
private func lreGetScriptRanges(_ name: String) -> [CharRange]? {
    switch name {
    case "latin":
        return [CharRange(0x41, 0x5A), CharRange(0x61, 0x7A),
                CharRange(0xC0, 0xD6), CharRange(0xD8, 0xF6),
                CharRange(0xF8, 0x02AF),
                CharRange(0x1E00, 0x1EFF),
                CharRange(0x2C60, 0x2C7F),
                CharRange(0xA720, 0xA7FF)]
    case "greek":
        return [CharRange(0x0370, 0x03FF), CharRange(0x1F00, 0x1FFF)]
    case "cyrillic":
        return [CharRange(0x0400, 0x04FF), CharRange(0x0500, 0x052F)]
    case "armenian":
        return [CharRange(0x0530, 0x058F)]
    case "hebrew":
        return [CharRange(0x0590, 0x05FF)]
    case "arabic":
        return [CharRange(0x0600, 0x06FF), CharRange(0x0750, 0x077F),
                CharRange(0x08A0, 0x08FF)]
    case "devanagari":
        return [CharRange(0x0900, 0x097F), CharRange(0xA8E0, 0xA8FF)]
    case "bengali":
        return [CharRange(0x0980, 0x09FF)]
    case "thai":
        return [CharRange(0x0E00, 0x0E7F)]
    case "hangul":
        return [CharRange(0xAC00, 0xD7AF), CharRange(0x1100, 0x11FF),
                CharRange(0x3130, 0x318F)]
    case "han":
        return [CharRange(0x4E00, 0x9FFF), CharRange(0x3400, 0x4DBF),
                CharRange(0x20000, 0x2A6DF), CharRange(0x2A700, 0x2B73F),
                CharRange(0xF900, 0xFAFF)]
    case "hiragana":
        return [CharRange(0x3040, 0x309F)]
    case "katakana":
        return [CharRange(0x30A0, 0x30FF), CharRange(0x31F0, 0x31FF)]
    case "common":
        // Very approximate
        return [CharRange(0x00, 0x40), CharRange(0x5B, 0x60),
                CharRange(0x7B, 0xBF)]
    default:
        // Unknown property -- return nil so the compiler can report an error.
        return nil
    }
}

// ============================================================================
// MARK: - Unicode.Scalar.Properties helpers
// ============================================================================

private extension Unicode.GeneralCategory {
    var _isPunctuation: Bool {
        switch self {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation,
             .closePunctuation, .initialPunctuation, .finalPunctuation,
             .otherPunctuation:
            return true
        default:
            return false
        }
    }
    var _isSymbol: Bool {
        switch self {
        case .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }
    var _isSeparator: Bool {
        switch self {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }
    var _isOther: Bool {
        switch self {
        case .control, .format, .surrogate, .privateUse, .unassigned:
            return true
        default:
            return false
        }
    }
    var _isMark: Bool {
        switch self {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }
    var _isLetter: Bool {
        switch self {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter:
            return true
        default:
            return false
        }
    }
}

private extension Unicode.Scalar {
    var isLetter: Bool {
        properties.generalCategory._isLetter
    }
}

// ============================================================================
// MARK: - Bytecode builder
// ============================================================================

/// Accumulates regex bytecode during compilation.
private final class REBytecodeBuilder {
    var code: [UInt8] = []

    var count: Int { code.count }

    func emit(_ byte: UInt8) {
        code.append(byte)
    }

    func emitOp(_ op: JeffJSRegExpOpcode) {
        code.append(op.rawValue)
    }

    func emitU16(_ v: UInt16) {
        code.append(UInt8(v & 0xFF))
        code.append(UInt8((v >> 8) & 0xFF))
    }

    func emitU32(_ v: UInt32) {
        code.append(UInt8(v & 0xFF))
        code.append(UInt8((v >> 8) & 0xFF))
        code.append(UInt8((v >> 16) & 0xFF))
        code.append(UInt8((v >> 24) & 0xFF))
    }

    func emitI32(_ v: Int32) {
        emitU32(UInt32(bitPattern: v))
    }

    /// Patch a 32-bit value at a given offset.
    func patchU32(_ offset: Int, _ v: UInt32) {
        code[offset]     = UInt8(v & 0xFF)
        code[offset + 1] = UInt8((v >> 8) & 0xFF)
        code[offset + 2] = UInt8((v >> 16) & 0xFF)
        code[offset + 3] = UInt8((v >> 24) & 0xFF)
    }

    func patchI32(_ offset: Int, _ v: Int32) {
        patchU32(offset, UInt32(bitPattern: v))
    }

    /// Emit a char opcode (char or char32 depending on value).
    func emitChar(_ c: UInt32) {
        if c <= 0xFFFF {
            emitOp(.char_)
            emitU16(UInt16(c))
        } else {
            emitOp(.char32)
            emitU32(c)
        }
    }

    /// Emit a goto with a placeholder offset, return the position of the offset field.
    func emitGoto() -> Int {
        emitOp(.goto_)
        let pos = count
        emitI32(0)
        return pos
    }

    /// Emit a split (try-first variant) with placeholder, return offset position.
    func emitSplitGotoFirst() -> Int {
        emitOp(.splitGotoFirst)
        let pos = count
        emitI32(0)
        return pos
    }

    func emitSplitNextFirst() -> Int {
        emitOp(.splitNextFirst)
        let pos = count
        emitI32(0)
        return pos
    }

    /// Set the jump target for a split/goto at patchPos to the current end.
    func patchJump(_ patchPos: Int) {
        let target = Int32(count) - Int32(patchPos) - 4
        patchI32(patchPos, target)
    }

    /// Read a u16 at an offset.
    func readU16(_ offset: Int) -> UInt16 {
        return UInt16(code[offset]) | (UInt16(code[offset + 1]) << 8)
    }

    /// Read a u32 at an offset.
    func readU32(_ offset: Int) -> UInt32 {
        return UInt32(code[offset])
            | (UInt32(code[offset + 1]) << 8)
            | (UInt32(code[offset + 2]) << 16)
            | (UInt32(code[offset + 3]) << 24)
    }

    func readI32(_ offset: Int) -> Int32 {
        return Int32(bitPattern: readU32(offset))
    }
}

// ============================================================================
// MARK: - Bytecode header layout
// ============================================================================

/// The compiled bytecode starts with a small header:
///   [0..1] flags (UInt16, little-endian)  — includes .named flag at bit 8
///   [2]    capture count (UInt8)  — number of groups including group 0
///   [3..4] bytecode length (UInt16, little-endian)
/// Then `bytecodeLength` bytes of opcodes follow.
/// After that, NUL-terminated group name strings (if .named flag set).
private let kHeaderSize = 5

// ============================================================================
// MARK: - Compiler
// ============================================================================

/// Result of compilation.
struct JeffJSRegExpCompileResult {
    var bytecode: [UInt8]
    var error: String?
}

/// Compile a regex pattern string into bytecode.
func lreCompile(pattern: String, flags: JeffJSRegExpFlags) -> JeffJSRegExpCompileResult {
    let compiler = RECompiler(pattern: pattern, flags: flags)
    return compiler.compile()
}

/// The compiler object.  Lives only for the duration of one compile call.
private final class RECompiler {
    let pattern: [UInt32]          // code points of the pattern
    var pos: Int = 0               // current position in `pattern`
    let flags: JeffJSRegExpFlags
    let bc = REBytecodeBuilder()
    var captureCount: Int = 1      // group 0 always exists
    var groupNames: [String?] = [nil]  // group 0 has no name
    var error: String? = nil
    var hasNamedGroups = false

    init(pattern: String, flags: JeffJSRegExpFlags) {
        // Convert to code points.
        self.pattern = Array(pattern.unicodeScalars.map { $0.value })
        self.flags = flags
    }

    // MARK: Compile entry point

    func compile() -> JeffJSRegExpCompileResult {
        // Reserve header space.
        for _ in 0 ..< kHeaderSize {
            bc.emit(0)
        }

        // Emit save_start 0, <disjunction>, save_end 0, match.
        bc.emitOp(.saveStart)
        bc.emit(0)

        parseDisjunction()

        if error == nil && pos < pattern.count {
            setError("unexpected character in pattern")
        }

        bc.emitOp(.saveEnd)
        bc.emit(0)
        bc.emitOp(.match)

        if let err = error {
            return JeffJSRegExpCompileResult(bytecode: [], error: err)
        }

        // Write header (5 bytes: 2-byte flags, 1-byte capture count, 2-byte bc length).
        var headerFlags = flags
        if hasNamedGroups { headerFlags.insert(.named) }
        let flagsRaw = UInt16(headerFlags.rawValue & 0xFFFF)
        bc.code[0] = UInt8(flagsRaw & 0xFF)
        bc.code[1] = UInt8((flagsRaw >> 8) & 0xFF)
        bc.code[2] = UInt8(captureCount & 0xFF)
        let bcLen = bc.count - kHeaderSize
        bc.code[3] = UInt8(bcLen & 0xFF)
        bc.code[4] = UInt8((bcLen >> 8) & 0xFF)

        // Append group names if named groups exist.
        if hasNamedGroups {
            for i in 0 ..< groupNames.count {
                if let name = groupNames[i] {
                    for ch in name.utf8 {
                        bc.emit(ch)
                    }
                }
                bc.emit(0) // NUL terminator
            }
        }

        return JeffJSRegExpCompileResult(bytecode: bc.code, error: nil)
    }

    // MARK: Error

    func setError(_ msg: String) {
        if error == nil {
            error = msg
        }
    }

    // MARK: Pattern access

    func peek() -> UInt32? {
        guard pos < pattern.count else { return nil }
        return pattern[pos]
    }

    func peekIs(_ c: UInt32) -> Bool {
        return peek() == c
    }

    func advance() -> UInt32? {
        guard pos < pattern.count else { return nil }
        let c = pattern[pos]
        pos += 1
        return c
    }

    func expect(_ c: UInt32) -> Bool {
        if peek() == c {
            pos += 1
            return true
        }
        return false
    }

    // MARK: Disjunction  (alternative | alternative | ...)

    func parseDisjunction() {
        // Standard approach: compile the first alternative, then for each '|'
        // wrap the preceding code with a split and add a goto at the end.
        //
        //   split_next_first L1    (try this alt first, on fail go to L1)
        //   <alt body>
        //   goto L_end
        // L1:
        //   split_next_first L2    (if another alt follows)
        //   <alt body>
        //   goto L_end
        // L2:
        //   <last alt body>
        // L_end:

        let start = bc.count
        parseAlternative()
        guard error == nil else { return }

        if !peekIs(0x7C) { return }  // no alternatives, we're done

        // We have at least one '|'.
        // Step 1: save the first alternative's code and remove it.
        let firstAltCode = Array(bc.code[start...])
        bc.code.removeSubrange(start...)

        // Collect all alternatives (the first is already parsed).
        var altCodes: [[UInt8]] = [firstAltCode]

        while expect(0x7C) {
            let altStart = bc.count
            parseAlternative()
            guard error == nil else { return }
            let altCode = Array(bc.code[altStart...])
            bc.code.removeSubrange(altStart...)
            altCodes.append(altCode)
        }

        // Emit: for N alternatives we need (N-1) split instructions.
        var gotoPatches = [Int]()

        for i in 0 ..< altCodes.count {
            if i < altCodes.count - 1 {
                // Not the last alternative: emit a split.
                let splitPos = bc.emitSplitNextFirst()
                bc.code.append(contentsOf: altCodes[i])
                let gotoPos = bc.emitGoto()
                gotoPatches.append(gotoPos)
                bc.patchJump(splitPos)
            } else {
                // Last alternative: no split needed.
                bc.code.append(contentsOf: altCodes[i])
            }
        }

        // Patch all goto offsets to point here (after the last alternative).
        for g in gotoPatches {
            bc.patchJump(g)
        }
    }

    // MARK: Alternative (term term term ...)

    func parseAlternative() {
        while let c = peek(), c != 0x7C /* | */, c != 0x29 /* ) */ {
            parseTerm()
            if error != nil { return }
        }
    }

    // MARK: Term (atom quantifier?)

    func parseTerm() {
        let atomStart = bc.count
        let atomCaptureCount = captureCount

        guard parseAtom() else { return }
        if error != nil { return }

        // Quantifier?
        if let c = peek() {
            switch c {
            case 0x2A: // *
                pos += 1
                let lazy = expect(0x3F)
                emitQuantifier(atomStart: atomStart, atomCaptures: atomCaptureCount,
                               min: 0, max: Int32.max, lazy: lazy)
            case 0x2B: // +
                pos += 1
                let lazy = expect(0x3F)
                emitQuantifier(atomStart: atomStart, atomCaptures: atomCaptureCount,
                               min: 1, max: Int32.max, lazy: lazy)
            case 0x3F: // ?
                pos += 1
                let lazy = expect(0x3F)
                emitQuantifier(atomStart: atomStart, atomCaptures: atomCaptureCount,
                               min: 0, max: 1, lazy: lazy)
            case 0x7B: // {
                if let (min, max, consumed) = tryParseQuantifierBraces() {
                    pos += consumed
                    let lazy = expect(0x3F)
                    if min > max {
                        setError("numbers out of order in quantifier")
                        return
                    }
                    emitQuantifier(atomStart: atomStart, atomCaptures: atomCaptureCount,
                                   min: min, max: max, lazy: lazy)
                }
                // If tryParseQuantifierBraces returns nil, '{' is treated as literal
                // (non-unicode mode).
            default:
                break
            }
        }
    }

    /// Try to parse {n}, {n,}, {n,m}. Returns (min, max, charsConsumed) or nil.
    func tryParseQuantifierBraces() -> (Int32, Int32, Int)? {
        guard peekIs(0x7B) else { return nil }
        var i = pos + 1

        // Parse min
        guard i < pattern.count, isDigit(pattern[i]) else {
            if flags.isUnicode { setError("incomplete quantifier") }
            return nil
        }
        var min: Int64 = 0
        while i < pattern.count && isDigit(pattern[i]) {
            min = min * 10 + Int64(pattern[i] - 0x30)
            if min > Int64(Int32.max) { setError("quantifier too large"); return nil }
            i += 1
        }

        var max: Int64 = min

        if i < pattern.count && pattern[i] == 0x2C /* , */ {
            i += 1
            if i < pattern.count && isDigit(pattern[i]) {
                max = 0
                while i < pattern.count && isDigit(pattern[i]) {
                    max = max * 10 + Int64(pattern[i] - 0x30)
                    if max > Int64(Int32.max) { setError("quantifier too large"); return nil }
                    i += 1
                }
            } else {
                max = Int64(Int32.max) // unbounded
            }
        }

        guard i < pattern.count && pattern[i] == 0x7D /* } */ else {
            if flags.isUnicode { setError("incomplete quantifier") }
            return nil
        }

        let consumed = i - pos + 1
        return (Int32(min), Int32(max), consumed)
    }

    private func isDigit(_ c: UInt32) -> Bool {
        return c >= 0x30 && c <= 0x39
    }

    // MARK: Quantifier emission

    /// Check if an atom body is a single character-matching opcode suitable for
    /// simpleGreedyQuant. Returns true for: char_, char32, range, range32, dot, any.
    private func isSimpleGreedyBody(_ body: [UInt8]) -> Bool {
        guard !body.isEmpty else { return false }
        guard let op = JeffJSRegExpOpcode(rawValue: body[0]) else { return false }
        switch op {
        case .char_:   return body.count == 3   // 1 opcode + 2 char
        case .char32:  return body.count == 5   // 1 opcode + 4 char
        case .dot:     return body.count == 1
        case .any:     return body.count == 1
        case .range:
            // 1 opcode + 2 pair count + pairCount*4 bytes
            guard body.count >= 3 else { return false }
            let pairCount = Int(UInt16(body[1]) | (UInt16(body[2]) << 8))
            return body.count == 3 + pairCount * 4
        case .range32:
            guard body.count >= 3 else { return false }
            let pairCount = Int(UInt16(body[1]) | (UInt16(body[2]) << 8))
            return body.count == 3 + pairCount * 8
        default:
            return false
        }
    }

    func emitQuantifier(atomStart: Int, atomCaptures: Int, min: Int32, max: Int32, lazy: Bool) {
        if min == 1 && max == 1 { return } // {1} is a no-op

        // Extract the atom body.
        let atomBody = Array(bc.code[atomStart...])
        bc.code.removeSubrange(atomStart...)

        let hasCaptures = captureCount > atomCaptures

        // Phase 2: Emit simpleGreedyQuant for simple single-opcode greedy quantifiers
        // with no captures. This avoids the generic pushCharPos/split/checkAdvance loop
        // and lets the VM handle it with a tight inline loop.
        if !lazy && !hasCaptures && isSimpleGreedyBody(atomBody) {
            // Emit min required copies first (unrolled).
            for _ in 0 ..< min {
                bc.code.append(contentsOf: atomBody)
            }
            // Emit simpleGreedyQuant for the remaining (min..max) range.
            let remainMin: Int32 = 0
            let remainMax: Int32 = (max == Int32.max) ? Int32.max : max - min
            if remainMax > 0 || max == Int32.max {
                // Layout: opcode(1) + offset(4) + min(4) + max(4) + body_len(4) + body
                bc.emitOp(.simpleGreedyQuant)
                let offsetPos = bc.count
                bc.emitI32(0)  // offset placeholder (points past the whole instruction)
                bc.emitU32(UInt32(bitPattern: remainMin))
                bc.emitU32(UInt32(bitPattern: remainMax))
                bc.emitU32(UInt32(atomBody.count))
                bc.code.append(contentsOf: atomBody)
                // Patch offset to point past the instruction (from offset field to end)
                let afterPC = bc.count
                bc.patchI32(offsetPos, Int32(afterPC - offsetPos - 4))
            }
            return
        }

        if min == 0 && max == Int32.max {
            // * (or *?)
            let splitPos: Int
            if lazy {
                splitPos = bc.emitSplitGotoFirst()
            } else {
                splitPos = bc.emitSplitNextFirst()
            }

            // Push char pos for empty-check.
            bc.emitOp(.pushCharPos)
            bc.code.append(contentsOf: atomBody)
            bc.emitOp(.checkAdvance)

            // Loop back.
            let loopPos = bc.emitGoto()
            bc.patchI32(loopPos, Int32(splitPos - loopPos - 4 - 1))

            bc.patchJump(splitPos)
        } else if min == 1 && max == Int32.max {
            // + (or +?)
            let loopTop = bc.count
            bc.emitOp(.pushCharPos)
            bc.code.append(contentsOf: atomBody)
            bc.emitOp(.checkAdvance)

            let splitPos: Int
            if lazy {
                splitPos = bc.emitSplitGotoFirst()
            } else {
                splitPos = bc.emitSplitNextFirst()
            }
            bc.patchI32(splitPos, Int32(loopTop - splitPos - 4 - 1))
        } else if min == 0 && max == 1 {
            // ? (or ??)
            let splitPos: Int
            if lazy {
                splitPos = bc.emitSplitGotoFirst()
            } else {
                splitPos = bc.emitSplitNextFirst()
            }
            bc.code.append(contentsOf: atomBody)
            bc.patchJump(splitPos)
        } else {
            // General {n,m}
            // Emit min required copies.
            for _ in 0 ..< min {
                if hasCaptures {
                    bc.emitOp(.saveReset)
                    bc.emit(UInt8(atomCaptures & 0xFF))
                    bc.emit(UInt8((captureCount - atomCaptures) & 0xFF))
                }
                bc.code.append(contentsOf: atomBody)
            }

            if max == Int32.max {
                // {n,} — emit a * loop for the remaining
                let splitPos: Int
                if lazy {
                    splitPos = bc.emitSplitGotoFirst()
                } else {
                    splitPos = bc.emitSplitNextFirst()
                }
                bc.emitOp(.pushCharPos)
                if hasCaptures {
                    bc.emitOp(.saveReset)
                    bc.emit(UInt8(atomCaptures & 0xFF))
                    bc.emit(UInt8((captureCount - atomCaptures) & 0xFF))
                }
                bc.code.append(contentsOf: atomBody)
                bc.emitOp(.checkAdvance)
                let loopPos = bc.emitGoto()
                bc.patchI32(loopPos, Int32(splitPos - loopPos - 4 - 1))
                bc.patchJump(splitPos)
            } else {
                // {n,m} where m is finite — emit (m-n) optional copies
                let extra = max - min
                for _ in 0 ..< extra {
                    let splitPos: Int
                    if lazy {
                        splitPos = bc.emitSplitGotoFirst()
                    } else {
                        splitPos = bc.emitSplitNextFirst()
                    }
                    if hasCaptures {
                        bc.emitOp(.saveReset)
                        bc.emit(UInt8(atomCaptures & 0xFF))
                        bc.emit(UInt8((captureCount - atomCaptures) & 0xFF))
                    }
                    bc.code.append(contentsOf: atomBody)
                    bc.patchJump(splitPos)
                }
            }
        }
    }

    // MARK: Atom

    /// Parse an atom.  Returns true if something was emitted (or an error set).
    func parseAtom() -> Bool {
        guard let c = advance() else { return false }

        switch c {
        case 0x5C: // backslash
            return parseEscapedAtom()

        case 0x2E: // .
            if flags.contains(.dotAll) {
                bc.emitOp(.any)
            } else {
                bc.emitOp(.dot)
            }
            return true

        case 0x5E: // ^
            bc.emitOp(.lineStart)
            return true

        case 0x24: // $
            bc.emitOp(.lineEnd)
            return true

        case 0x28: // (
            return parseGroup()

        case 0x29: // )
            pos -= 1
            return false

        case 0x5B: // [
            return parseCharClass()

        case 0x5D: // ]
            if flags.isUnicode {
                setError("unmatched ']'")
                return false
            }
            bc.emitChar(c)
            return true

        case 0x7B: // {
            if flags.isUnicode {
                setError("nothing to repeat")
                return false
            }
            bc.emitChar(c)
            return true

        case 0x7D: // }
            if flags.isUnicode {
                setError("unmatched '}'")
                return false
            }
            bc.emitChar(c)
            return true

        case 0x2A, 0x2B, 0x3F: // *, +, ?
            setError("nothing to repeat")
            return false

        case 0x7C: // |  — should not reach here
            pos -= 1
            return false

        default:
            emitCharWithCase(c)
            return true
        }
    }

    /// Emit a character match, respecting case-insensitive flag.
    func emitCharWithCase(_ c: UInt32) {
        if flags.contains(.ignoreCase) {
            let folded = flags.isUnicode ? lreCanonicalizeUnicode(c) : c
            // Build a small char class for all case variants.
            var variants = Set<UInt32>()
            variants.insert(c)
            if let s = Unicode.Scalar(c) {
                for ch in String(s).lowercased().unicodeScalars { variants.insert(ch.value) }
                for ch in String(s).uppercased().unicodeScalars { variants.insert(ch.value) }
            }
            if !flags.isUnicode {
                variants.insert(folded)
            }

            if variants.count == 1 {
                bc.emitChar(c)
            } else {
                // Emit a range opcode with all variants.
                var ranges = [CharRange]()
                for v in variants {
                    crAddChar(&ranges, v)
                }
                emitCharClassRanges(crNormalize(ranges))
            }
        } else {
            bc.emitChar(c)
        }
    }

    // MARK: Escaped atom (\...)

    func parseEscapedAtom() -> Bool {
        guard let c = advance() else {
            setError("pattern ends with backslash")
            return false
        }

        switch c {
        case 0x64: // d
            emitCharClassRanges([CharRange(0x30, 0x39)])
            return true
        case 0x44: // D
            emitCharClassRanges(crComplement([CharRange(0x30, 0x39)]))
            return true
        case 0x77: // w
            emitCharClassRanges(lreWordCharRanges())
            return true
        case 0x57: // W
            emitCharClassRanges(crComplement(lreWordCharRanges()))
            return true
        case 0x73: // s
            emitCharClassRanges(lreSpaceCharRanges())
            return true
        case 0x53: // S
            emitCharClassRanges(crComplement(lreSpaceCharRanges()))
            return true
        case 0x62: // b
            bc.emitOp(.wordBoundary)
            return true
        case 0x42: // B
            bc.emitOp(.notWordBoundary)
            return true
        case 0x70, 0x50: // p, P  — Unicode property escape
            let negate = (c == 0x50)
            guard expect(0x7B) else {
                setError("invalid Unicode property escape")
                return false
            }
            var propName = ""
            while let ch = peek(), ch != 0x7D {
                propName.append(Character(Unicode.Scalar(ch)!))
                pos += 1
            }
            guard expect(0x7D) else {
                setError("unterminated Unicode property escape")
                return false
            }
            // Check for property=value form.
            let parts = propName.split(separator: "=", maxSplits: 1)
            let lookupName: String
            if parts.count == 2 {
                lookupName = String(parts[1])
            } else {
                lookupName = propName
            }
            guard let ranges = lreGetUnicodePropertyRanges(lookupName, negate: negate) else {
                setError("invalid Unicode property name: \(propName)")
                return false
            }
            emitCharClassRanges(ranges)
            return true

        case 0x30: // \0  — NUL
            if pos < pattern.count && isDigit(pattern[pos]) && !flags.isUnicode {
                // Octal escape (legacy).
                return parseOctalEscape(firstDigit: 0)
            }
            emitCharWithCase(0)
            return true

        case 0x31...0x39: // 1-9 — backreference
            var num = Int(c - 0x30)
            while let nc = peek(), nc >= 0x30 && nc <= 0x39 {
                let newNum = num * 10 + Int(nc - 0x30)
                if newNum >= captureCount && newNum > 9 { break }
                num = newNum
                pos += 1
            }
            if num >= captureCount {
                if flags.isUnicode {
                    setError("invalid backreference \\\(num)")
                    return false
                }
                // In non-unicode mode, treat as octal if possible.
                pos -= 1
                // But if it's just a single digit > captureCount, emit as backreference
                // (it will always fail to match, which is spec-correct).
            }
            bc.emitOp(.backReference)
            bc.emit(UInt8(num & 0xFF))
            return true

        case 0x6B: // k — named backreference
            guard expect(0x3C) else {
                if flags.isUnicode {
                    setError("expected '<' after \\k")
                    return false
                }
                bc.emitChar(c)
                return true
            }
            var name = ""
            while let ch = peek(), ch != 0x3E {
                name.append(Character(Unicode.Scalar(ch)!))
                pos += 1
            }
            guard expect(0x3E) else {
                setError("unterminated named backreference")
                return false
            }
            // Find group index.
            if let idx = groupNames.firstIndex(where: { $0 == name }) {
                bc.emitOp(.backReference)
                bc.emit(UInt8(idx & 0xFF))
            } else {
                setError("undefined named backreference: \(name)")
                return false
            }
            return true

        case 0x74: emitCharWithCase(0x09); return true // \t
        case 0x6E: emitCharWithCase(0x0A); return true // \n
        case 0x76: emitCharWithCase(0x0B); return true // \v
        case 0x66: emitCharWithCase(0x0C); return true // \f
        case 0x72: emitCharWithCase(0x0D); return true // \r

        case 0x63: // \cX
            guard let ctrl = advance() else {
                setError("pattern ends after \\c")
                return false
            }
            let val = ctrl % 32
            emitCharWithCase(val)
            return true

        case 0x78: // \xHH
            guard let h1 = parseHexDigit(), let h2 = parseHexDigit() else {
                if flags.isUnicode {
                    setError("invalid hex escape")
                    return false
                }
                emitCharWithCase(0x78) // literal 'x'
                return true
            }
            emitCharWithCase((h1 << 4) | h2)
            return true

        case 0x75: // \uHHHH or \u{HHHH}
            if expect(0x7B) {
                // \u{HHHH+}
                var val: UInt32 = 0
                var count = 0
                while let d = parseHexDigit() {
                    val = (val << 4) | d
                    count += 1
                    if val > 0x10FFFF { setError("Unicode escape out of range"); return false }
                }
                guard count > 0, expect(0x7D) else {
                    setError("invalid Unicode escape")
                    return false
                }
                emitCharWithCase(val)
            } else {
                guard let h1 = parseHexDigit(), let h2 = parseHexDigit(),
                      let h3 = parseHexDigit(), let h4 = parseHexDigit() else {
                    if flags.isUnicode {
                        setError("invalid Unicode escape")
                        return false
                    }
                    emitCharWithCase(0x75) // literal 'u'
                    return true
                }
                var val = (h1 << 12) | (h2 << 8) | (h3 << 4) | h4
                // Check for surrogate pair \uD800\uDC00.
                if val >= 0xD800 && val <= 0xDBFF && flags.isUnicode {
                    let saved = pos
                    if expect(0x5C) && expect(0x75) {
                        if let l1 = parseHexDigit(), let l2 = parseHexDigit(),
                           let l3 = parseHexDigit(), let l4 = parseHexDigit() {
                            let lo = (l1 << 12) | (l2 << 8) | (l3 << 4) | l4
                            if lo >= 0xDC00 && lo <= 0xDFFF {
                                val = 0x10000 + ((val - 0xD800) << 10) + (lo - 0xDC00)
                            } else {
                                pos = saved
                            }
                        } else {
                            pos = saved
                        }
                    } else {
                        pos = saved
                    }
                }
                emitCharWithCase(val)
            }
            return true

        default:
            // Identity escape (in unicode mode, only syntax characters are allowed).
            if flags.isUnicode {
                if isSyntaxChar(c) {
                    emitCharWithCase(c)
                    return true
                }
                setError("invalid escape sequence")
                return false
            }
            emitCharWithCase(c)
            return true
        }
    }

    func parseOctalEscape(firstDigit: UInt32) -> Bool {
        var val = firstDigit
        for _ in 0 ..< 2 {
            guard let c = peek(), c >= 0x30 && c <= 0x37 else { break }
            let newVal = val * 8 + (c - 0x30)
            if newVal > 0xFF { break }
            val = newVal
            pos += 1
        }
        emitCharWithCase(val)
        return true
    }

    func parseHexDigit() -> UInt32? {
        guard let c = peek() else { return nil }
        var val: UInt32
        if c >= 0x30 && c <= 0x39 {
            val = c - 0x30
        } else if c >= 0x41 && c <= 0x46 {
            val = c - 0x41 + 10
        } else if c >= 0x61 && c <= 0x66 {
            val = c - 0x61 + 10
        } else {
            return nil
        }
        pos += 1
        return val
    }

    func isSyntaxChar(_ c: UInt32) -> Bool {
        switch c {
        case 0x24, 0x28, 0x29, 0x2A, 0x2B, 0x2E, 0x2F, 0x3F,
             0x5B, 0x5C, 0x5D, 0x5E, 0x7B, 0x7C, 0x7D:
            return true
        default:
            return false
        }
    }

    // MARK: Groups

    func parseGroup() -> Bool {
        // We consumed '(' already.
        if expect(0x3F) {
            // Non-capturing or special group.
            if expect(0x3A) {
                // (?:...)
                parseDisjunction()
                guard expect(0x29) else {
                    setError("unterminated group")
                    return false
                }
                return true
            } else if expect(0x3D) {
                // (?=...)  lookahead
                return parseLookahead(negative: false)
            } else if expect(0x21) {
                // (?!...)  negative lookahead
                return parseLookahead(negative: true)
            } else if expect(0x3C) {
                // (?<  — could be named group, lookbehind (?<=...) or (?<!...)
                if expect(0x3D) {
                    return parseLookbehind(negative: false)
                } else if expect(0x21) {
                    return parseLookbehind(negative: true)
                } else {
                    // Named group (?<name>...)
                    return parseNamedGroup()
                }
            } else {
                setError("invalid group specifier")
                return false
            }
        } else {
            // Capturing group.
            let groupId = captureCount
            captureCount += 1
            groupNames.append(nil)

            bc.emitOp(.saveStart)
            bc.emit(UInt8(groupId & 0xFF))

            parseDisjunction()

            bc.emitOp(.saveEnd)
            bc.emit(UInt8(groupId & 0xFF))

            guard expect(0x29) else {
                setError("unterminated group")
                return false
            }
            return true
        }
    }

    func parseNamedGroup() -> Bool {
        var name = ""
        while let ch = peek(), ch != 0x3E /* > */ {
            name.append(Character(Unicode.Scalar(ch)!))
            pos += 1
        }
        guard expect(0x3E) else {
            setError("unterminated group name")
            return false
        }
        if name.isEmpty {
            setError("empty group name")
            return false
        }
        // Check for duplicate names.
        if groupNames.contains(name) {
            setError("duplicate group name: \(name)")
            return false
        }

        let groupId = captureCount
        captureCount += 1
        groupNames.append(name)
        hasNamedGroups = true

        bc.emitOp(.saveStart)
        bc.emit(UInt8(groupId & 0xFF))

        parseDisjunction()

        bc.emitOp(.saveEnd)
        bc.emit(UInt8(groupId & 0xFF))

        guard expect(0x29) else {
            setError("unterminated group")
            return false
        }
        return true
    }

    func parseLookahead(negative: Bool) -> Bool {
        let op: JeffJSRegExpOpcode = negative ? .negativeLookahead : .lookahead
        bc.emitOp(op)
        let patchPos = bc.count
        bc.emitI32(0)  // offset placeholder
        let captureStart = captureCount
        bc.emit(UInt8(captureStart & 0xFF))

        parseDisjunction()

        bc.emitOp(.match)
        bc.patchJump(patchPos)
        // Patch the capture count.
        bc.code[patchPos + 4] = UInt8(captureCount & 0xFF)

        guard expect(0x29) else {
            setError("unterminated lookahead")
            return false
        }
        return true
    }

    func parseLookbehind(negative: Bool) -> Bool {
        // Lookbehind is compiled similarly to lookahead but with
        // prev instructions to scan backward.
        let op: JeffJSRegExpOpcode = negative ? .negativeLookahead : .lookahead
        bc.emitOp(op)
        let patchPos = bc.count
        bc.emitI32(0)
        let captureStart = captureCount
        bc.emit(UInt8(captureStart & 0xFF))

        // Mark this as a lookbehind by emitting prev before each atom.
        // For simplicity we compile the body normally then the VM will
        // handle backward scanning via the prev opcode when we wrap it.
        // QuickJS actually reverses the body. We take a simpler approach:
        // just compile normally, and handle lookbehind in the VM by
        // scanning backward from the current position.
        // Emit prev at start to back up.
        bc.emitOp(.prev)
        parseDisjunction()

        bc.emitOp(.match)
        bc.patchJump(patchPos)
        bc.code[patchPos + 4] = UInt8(captureCount & 0xFF)

        guard expect(0x29) else {
            setError("unterminated lookbehind")
            return false
        }
        return true
    }

    // MARK: Character class [...]

    func parseCharClass() -> Bool {
        var negate = false
        if expect(0x5E) { // ^
            negate = true
        }

        var ranges = [CharRange]()

        while let c = peek(), c != 0x5D /* ] */ {
            _classPropertyStash = nil
            let (lo, ok) = parseClassAtom()
            if !ok { return false }

            // Check if this was a shorthand class or property escape.
            if let propRanges = _classPropertyStash {
                // \p{}, \P{} inside class — add the ranges directly.
                ranges.append(contentsOf: propRanges)
                _classPropertyStash = nil
                continue
            }
            if let shorthand = expandClassAtomSentinel(lo) {
                ranges.append(contentsOf: shorthand)
                continue
            }

            if expect(0x2D) { // -
                if peekIs(0x5D) {
                    // trailing '-' — treat both lo and '-' as literals.
                    crAddChar(&ranges, lo)
                    crAddChar(&ranges, 0x2D)
                    continue
                }
                _classPropertyStash = nil
                let (hi, ok2) = parseClassAtom()
                if !ok2 { return false }
                // If either side was a shorthand, ranges are not valid.
                if _classPropertyStash != nil || expandClassAtomSentinel(hi) != nil {
                    if flags.isUnicode {
                        setError("character class range with shorthand class")
                        return false
                    }
                    crAddChar(&ranges, lo)
                    crAddChar(&ranges, 0x2D)
                    if let propR = _classPropertyStash {
                        ranges.append(contentsOf: propR)
                    } else if let sh = expandClassAtomSentinel(hi) {
                        ranges.append(contentsOf: sh)
                    } else {
                        crAddChar(&ranges, hi)
                    }
                    continue
                }
                if lo > hi {
                    if flags.isUnicode {
                        setError("range out of order in character class")
                        return false
                    }
                    crAddChar(&ranges, lo)
                    crAddChar(&ranges, hi)
                } else {
                    crAddRange(&ranges, lo, hi)
                }
            } else {
                crAddChar(&ranges, lo)
            }
        }

        guard expect(0x5D) else {
            setError("unterminated character class")
            return false
        }

        var normalized = crNormalize(ranges)
        if negate {
            normalized = crComplement(normalized)
            // In non-unicode mode, cap at 0xFFFF.
            if !flags.isUnicode {
                normalized = crIntersection(normalized, [CharRange(0, 0xFFFF)])
            }
        }

        if flags.contains(.ignoreCase) {
            normalized = expandCaseVariants(normalized)
        }

        emitCharClassRanges(normalized)
        return true
    }

    /// Expand sentinel values returned by parseClassAtom for shorthand classes.
    /// Returns nil if the value is not a sentinel.
    private func expandClassAtomSentinel(_ val: UInt32) -> [CharRange]? {
        switch val {
        case 0xFFFF_FFFF: return [CharRange(0x30, 0x39)]                              // \d
        case 0xFFFF_FFFE: return crComplement([CharRange(0x30, 0x39)])                 // \D
        case 0xFFFF_FFFD: return lreWordCharRanges()                                    // \w
        case 0xFFFF_FFFC: return crComplement(lreWordCharRanges())                      // \W
        case 0xFFFF_FFFB: return lreSpaceCharRanges()                                   // \s
        case 0xFFFF_FFFA: return crComplement(lreSpaceCharRanges())                     // \S
        case 0xFFFF_FFF0: return _classPropertyStash                                    // \p{}/\P{}
        default:          return nil
        }
    }

    /// Parse one atom inside a character class. Returns (codePoint, success).
    func parseClassAtom() -> (UInt32, Bool) {
        guard let c = advance() else {
            setError("unterminated character class")
            return (0, false)
        }

        if c == 0x5C { // backslash
            guard let esc = advance() else {
                setError("pattern ends with backslash in class")
                return (0, false)
            }
            switch esc {
            case 0x64: // \d
                return (0xFFFF_FFFF, true) // sentinel; handled below
            case 0x44:
                return (0xFFFF_FFFE, true)
            case 0x77:
                return (0xFFFF_FFFD, true)
            case 0x57:
                return (0xFFFF_FFFC, true)
            case 0x73:
                return (0xFFFF_FFFB, true)
            case 0x53:
                return (0xFFFF_FFFA, true)
            case 0x74: return (0x09, true)
            case 0x6E: return (0x0A, true)
            case 0x76: return (0x0B, true)
            case 0x66: return (0x0C, true)
            case 0x72: return (0x0D, true)
            case 0x62: return (0x08, true) // \b in char class = backspace
            case 0x30:
                if pos < pattern.count && isDigit(pattern[pos]) && !flags.isUnicode {
                    var val: UInt32 = 0
                    for _ in 0 ..< 3 {
                        guard let d = peek(), d >= 0x30 && d <= 0x37 else { break }
                        val = val * 8 + (d - 0x30)
                        pos += 1
                    }
                    return (val, true)
                }
                return (0, true) // NUL
            case 0x63: // \cX
                guard let ctrl = advance() else { setError("bad \\c"); return (0, false) }
                return (ctrl % 32, true)
            case 0x78: // \xHH
                guard let h1 = parseHexDigit(), let h2 = parseHexDigit() else {
                    if flags.isUnicode { setError("invalid hex escape in class"); return (0, false) }
                    return (0x78, true)
                }
                return ((h1 << 4) | h2, true)
            case 0x75: // \uHHHH or \u{HHHH}
                if expect(0x7B) {
                    var val: UInt32 = 0; var cnt = 0
                    while let d = parseHexDigit() {
                        val = (val << 4) | d; cnt += 1
                        if val > 0x10FFFF { setError("Unicode escape out of range"); return (0, false) }
                    }
                    guard cnt > 0, expect(0x7D) else { setError("invalid \\u{} escape"); return (0, false) }
                    return (val, true)
                }
                guard let h1 = parseHexDigit(), let h2 = parseHexDigit(),
                      let h3 = parseHexDigit(), let h4 = parseHexDigit() else {
                    if flags.isUnicode { setError("invalid \\u in class"); return (0, false) }
                    return (0x75, true)
                }
                return ((h1 << 12) | (h2 << 8) | (h3 << 4) | h4, true)
            case 0x70, 0x50: // \p{} / \P{} inside class
                let neg = (esc == 0x50)
                guard expect(0x7B) else { setError("expected '{' after \\p/\\P"); return (0, false) }
                var propName = ""
                while let ch = peek(), ch != 0x7D { propName.append(Character(Unicode.Scalar(ch)!)); pos += 1 }
                guard expect(0x7D) else { setError("unterminated \\p{}"); return (0, false) }
                let parts = propName.split(separator: "=", maxSplits: 1)
                let lookup = parts.count == 2 ? String(parts[1]) : propName
                guard let pr = lreGetUnicodePropertyRanges(lookup, negate: neg) else {
                    setError("invalid Unicode property: \(propName)"); return (0, false)
                }
                // Sentinel that tells the caller to add these ranges directly.
                // We encode the index into a global stash.
                _classPropertyStash = pr
                return (0xFFFF_FFF0, true) // property sentinel

            default:
                if flags.isUnicode && !isSyntaxChar(esc) && esc != 0x2D {
                    setError("invalid escape in character class")
                    return (0, false)
                }
                return (esc, true)
            }
        }

        return (c, true)
    }

    // Stash for property ranges parsed inside a class atom.
    var _classPropertyStash: [CharRange]? = nil

    /// Emit a character class (range/range32 opcode) from normalised ranges.
    func emitCharClassRanges(_ ranges: [CharRange]) {
        // Decide 16-bit vs 32-bit.
        let need32 = ranges.contains { $0.hi > 0xFFFF }

        if need32 {
            bc.emitOp(.range32)
            let pairCount = ranges.count
            bc.emitU16(UInt16(pairCount > 0xFFFF ? 0xFFFF : pairCount))
            for r in ranges {
                bc.emitU32(r.lo)
                bc.emitU32(r.hi)
            }
        } else {
            bc.emitOp(.range)
            let pairCount = ranges.count
            bc.emitU16(UInt16(pairCount > 0xFFFF ? 0xFFFF : pairCount))
            for r in ranges {
                bc.emitU16(UInt16(r.lo))
                bc.emitU16(UInt16(r.hi))
            }
        }
    }

    /// Expand character ranges to include all case variants (for 'i' flag).
    func expandCaseVariants(_ ranges: [CharRange]) -> [CharRange] {
        var expanded = ranges
        for r in ranges {
            // For small ranges, enumerate.  For large ranges, keep as-is
            // (runtime will fold per-character).
            let size = UInt64(r.hi) - UInt64(r.lo) + 1
            if size <= 256 {
                var c = r.lo
                while c <= r.hi {
                    if let scalar = Unicode.Scalar(c) {
                        for ch in String(scalar).lowercased().unicodeScalars {
                            crAddChar(&expanded, ch.value)
                        }
                        for ch in String(scalar).uppercased().unicodeScalars {
                            crAddChar(&expanded, ch.value)
                        }
                    }
                    c += 1
                }
            }
        }
        return crNormalize(expanded)
    }
}

// ============================================================================
// MARK: - Predefined character class ranges
// ============================================================================

/// \w character ranges.
func lreWordCharRanges() -> [CharRange] {
    return [
        CharRange(0x30, 0x39),    // 0-9
        CharRange(0x41, 0x5A),    // A-Z
        CharRange(0x5F, 0x5F),    // _
        CharRange(0x61, 0x7A),    // a-z
    ]
}

/// \s character ranges (ECMAScript WhiteSpace + LineTerminator).
func lreSpaceCharRanges() -> [CharRange] {
    return [
        CharRange(0x09, 0x0D),    // TAB, LF, VT, FF, CR
        CharRange(0x20, 0x20),    // SPACE
        CharRange(0xA0, 0xA0),    // NBSP
        CharRange(0x1680, 0x1680),
        CharRange(0x2000, 0x200A),
        CharRange(0x2028, 0x2029),
        CharRange(0x202F, 0x202F),
        CharRange(0x205F, 0x205F),
        CharRange(0x3000, 0x3000),
        CharRange(0xFEFF, 0xFEFF),
    ]
}

/// Line terminator ranges (for . without s flag).
private func lreLineTerminatorRanges() -> [CharRange] {
    return [
        CharRange(0x0A, 0x0A),
        CharRange(0x0D, 0x0D),
        CharRange(0x2028, 0x2029),
    ]
}

// ============================================================================
// MARK: - VM execution
// ============================================================================

/// Match result codes.
enum LREExecResult: Int {
    case noMatch = 0
    case match = 1
    case error = -1
}

/// Result returned from lreExec.
struct JeffJSRegExpExecResult {
    var result: LREExecResult
    var captures: [(start: Int, end: Int)?]
}

/// Execute compiled regex bytecode against an input string.
///
/// - Parameters:
///   - bytecode: The compiled bytecode (including header).
///   - input: The input as an array of code points (or UTF-16 code units).
///   - startPos: The position to start matching from.
///   - flags: Additional execution flags (usually the same as compile flags).
/// - Returns: Match result and capture groups.
func lreExec(bytecode: [UInt8], input: [UInt32], startPos: Int,
             flags: JeffJSRegExpFlags) -> JeffJSRegExpExecResult {
    let vm = REVirtualMachine(bytecode: bytecode, input: input,
                              startPos: startPos, flags: flags)
    return vm.exec()
}

/// Overload for String input.
func lreExec(bytecode: [UInt8], input: String, startPos: Int,
             flags: JeffJSRegExpFlags) -> JeffJSRegExpExecResult {
    let codePoints: [UInt32]
    if flags.isUnicode {
        codePoints = Array(input.unicodeScalars.map { $0.value })
    } else {
        // Use UTF-16 code units for non-unicode mode (to match JS semantics).
        codePoints = Array(input.utf16.map { UInt32($0) })
    }
    return lreExec(bytecode: bytecode, input: codePoints, startPos: startPos, flags: flags)
}

/// Fast global match: creates ONE REVirtualMachine and reuses it across all
/// match attempts, returning (start, end) tuples for every match.
///
/// This avoids the per-match overhead of:
/// 1. Re-allocating the bytecode [UInt8] array
/// 2. Re-converting the input string to [UInt32]
/// 3. Creating a new REVirtualMachine instance
/// 4. Building full JS result objects that are immediately discarded
///
/// For `/\d+/g` on 10KB input, this reduces from O(N * matchCount) allocations
/// to O(1) allocations.
///
/// - Parameters:
///   - bytecode: The compiled regex bytecode (including header).
///   - input: The input as an array of code points (or UTF-16 code units).
///   - flags: Execution flags.
///   - isUnicode: Whether to advance by surrogate pairs on zero-length matches.
/// - Returns: Array of (start, end) tuples for each full match, or nil on error.
func lreExecGlobalMatch(bytecode: [UInt8], input: [UInt32],
                        flags: JeffJSRegExpFlags,
                        isUnicode: Bool) -> [(start: Int, end: Int)]? {
    let vm = REVirtualMachine(bytecode: bytecode, input: input,
                              startPos: 0, flags: flags)

    guard vm.bcEnd > vm.bcStart else { return nil }

    let inputLen = input.count
    var results = [(start: Int, end: Int)]()
    results.reserveCapacity(64)  // pre-allocate for typical match counts
    var pos = 0
    var safetyLimit = 1_000_000

    // Phase 3: Fast start-position pre-filter.
    // Analyze the first bytecode opcode to build a pre-filter that can
    // skip positions where the first character can't possibly match,
    // avoiding a full VM invocation at each non-matching position.
    let firstOp = bytecode.count > vm.bcStart ? bytecode[vm.bcStart] : 0
    let preFilter = GlobalMatchPreFilter(bytecode: bytecode, bcStart: vm.bcStart, firstOp: firstOp, flags: flags)
    var hadError = false

    input.withUnsafeBufferPointer { inputBuf in
        while pos <= inputLen && safetyLimit > 0 {
            safetyLimit -= 1

            // Apply pre-filter: skip positions that can't match.
            pos = preFilter.nextCandidate(inputBuf: inputBuf, from: pos, inputLen: inputLen)
            if pos > inputLen { break }

            vm.reset(startPos: pos)
            let execResult = vm.exec()

            if execResult.result == .error {
                hadError = true
                return
            }
            if execResult.result == .noMatch {
                // Pre-filter found a candidate but VM couldn't match.
                // Move past this position and try the next candidate.
                pos += 1
                continue
            }

            // Extract the full match (capture group 0).
            guard let fullMatch = execResult.captures.first,
                  let match = fullMatch else {
                break
            }

            results.append((start: match.start, end: match.end))

            // Advance past the match. Handle zero-length matches to avoid infinite loop.
            if match.end == match.start {
                // Zero-length match: advance by 1 (or 2 for surrogate pairs in unicode mode).
                if isUnicode && pos < inputLen {
                    let c = inputBuf[pos]
                    if c >= 0xD800 && c <= 0xDBFF && pos + 1 < inputLen {
                        let lo = inputBuf[pos + 1]
                        if lo >= 0xDC00 && lo <= 0xDFFF {
                            pos += 2
                            continue
                        }
                    }
                }
                pos += 1
            } else {
                pos = match.end
            }
        }
    }

    if hadError { return nil }
    return results
}

/// Pre-filter for global match: quickly skip positions where the first opcode can't match.
private struct GlobalMatchPreFilter {
    enum FilterKind {
        case none                       // No pre-filter, try every position
        case singleChar(UInt32)         // First opcode is char_ matching this value
        case singleChar32(UInt32)       // First opcode is char32 matching this value
        case singleRange(UInt32, UInt32) // First opcode is range with 1 pair [lo, hi]
        case multiRange([(UInt32, UInt32)]) // First opcode is range with multiple pairs
    }

    let kind: FilterKind

    init(bytecode: [UInt8], bcStart: Int, firstOp: UInt8, flags: JeffJSRegExpFlags) {
        // Don't apply pre-filter if case-insensitive (ranges are pre-folded but
        // we'd need to fold input chars too, complicating the fast path).
        guard !flags.contains(.ignoreCase) else {
            self.kind = .none
            return
        }

        switch firstOp {
        case JeffJSRegExpOpcode.char_.rawValue:
            guard bcStart + 3 <= bytecode.count else { self.kind = .none; return }
            let ch = UInt32(bytecode[bcStart + 1]) | (UInt32(bytecode[bcStart + 2]) << 8)
            self.kind = .singleChar(ch)

        case JeffJSRegExpOpcode.char32.rawValue:
            guard bcStart + 5 <= bytecode.count else { self.kind = .none; return }
            let ch = UInt32(bytecode[bcStart + 1])
                | (UInt32(bytecode[bcStart + 2]) << 8)
                | (UInt32(bytecode[bcStart + 3]) << 16)
                | (UInt32(bytecode[bcStart + 4]) << 24)
            self.kind = .singleChar32(ch)

        case JeffJSRegExpOpcode.range.rawValue:
            guard bcStart + 3 <= bytecode.count else { self.kind = .none; return }
            let pairCount = Int(UInt16(bytecode[bcStart + 1]) | (UInt16(bytecode[bcStart + 2]) << 8))
            guard pairCount > 0, bcStart + 3 + pairCount * 4 <= bytecode.count else {
                self.kind = .none; return
            }
            if pairCount == 1 {
                let lo = UInt32(bytecode[bcStart + 3]) | (UInt32(bytecode[bcStart + 4]) << 8)
                let hi = UInt32(bytecode[bcStart + 5]) | (UInt32(bytecode[bcStart + 6]) << 8)
                self.kind = .singleRange(lo, hi)
            } else {
                var pairs = [(UInt32, UInt32)]()
                pairs.reserveCapacity(pairCount)
                for i in 0 ..< pairCount {
                    let off = bcStart + 3 + i * 4
                    let lo = UInt32(bytecode[off]) | (UInt32(bytecode[off + 1]) << 8)
                    let hi = UInt32(bytecode[off + 2]) | (UInt32(bytecode[off + 3]) << 8)
                    pairs.append((lo, hi))
                }
                self.kind = .multiRange(pairs)
            }

        case JeffJSRegExpOpcode.saveStart.rawValue:
            // Pattern starts with saveStart (capture group 0) — look at the NEXT opcode.
            let nextPC = bcStart + 2  // saveStart is 2 bytes
            guard nextPC < bytecode.count else { self.kind = .none; return }
            // Recurse with the next opcode position.
            let inner = GlobalMatchPreFilter(bytecode: bytecode, bcStart: nextPC, firstOp: bytecode[nextPC], flags: flags)
            self.kind = inner.kind

        default:
            self.kind = .none
        }
    }

    /// Find the next position >= `from` where the first opcode could match.
    @inline(__always)
    func nextCandidate(inputBuf: UnsafeBufferPointer<UInt32>, from: Int, inputLen: Int) -> Int {
        var pos = from
        switch kind {
        case .none:
            return pos

        case .singleChar(let ch):
            while pos < inputLen {
                if inputBuf[pos] == ch { return pos }
                pos += 1
            }
            return pos

        case .singleChar32(let ch):
            while pos < inputLen {
                if inputBuf[pos] == ch { return pos }
                pos += 1
            }
            return pos

        case .singleRange(let lo, let hi):
            while pos < inputLen {
                let c = inputBuf[pos]
                if c >= lo && c <= hi { return pos }
                pos += 1
            }
            return pos

        case .multiRange(let pairs):
            while pos < inputLen {
                let c = inputBuf[pos]
                for (lo, hi) in pairs {
                    if c >= lo && c <= hi { return pos }
                }
                pos += 1
            }
            return pos
        }
    }
}

// ============================================================================
// MARK: - Bytecode query helpers
// ============================================================================

/// Extract the flags from compiled bytecode.
func lreGetFlags(_ bytecode: [UInt8]) -> JeffJSRegExpFlags {
    guard bytecode.count >= kHeaderSize else { return [] }
    let raw = Int(bytecode[0]) | (Int(bytecode[1]) << 8)
    return JeffJSRegExpFlags(rawValue: raw)
}

/// Extract the capture count from compiled bytecode.
func lreGetCaptureCount(_ bytecode: [UInt8]) -> Int {
    guard bytecode.count >= kHeaderSize else { return 0 }
    return Int(bytecode[2])
}

/// Extract group names from compiled bytecode.  Returns an array of length
/// `captureCount` where unnamed groups have `nil`.
func lreGetGroupNames(_ bytecode: [UInt8]) -> [String?] {
    let flags = lreGetFlags(bytecode)
    let captureCount = lreGetCaptureCount(bytecode)
    guard flags.contains(.named), bytecode.count > kHeaderSize else {
        return [String?](repeating: nil, count: captureCount)
    }

    let bcLen = Int(bytecode[3]) | (Int(bytecode[4]) << 8)
    var offset = kHeaderSize + bcLen
    var names = [String?]()

    for _ in 0 ..< captureCount {
        var name = ""
        while offset < bytecode.count && bytecode[offset] != 0 {
            name.append(Character(Unicode.Scalar(bytecode[offset])))
            offset += 1
        }
        offset += 1 // skip NUL
        if name.isEmpty {
            names.append(nil)
        } else {
            names.append(name)
        }
    }

    while names.count < captureCount {
        names.append(nil)
    }
    return names
}

// ============================================================================
// MARK: - REVirtualMachine
// ============================================================================

/// Backtracking regex VM.  Executes compiled bytecode against an input.
///
/// Performance-critical design choices:
/// - Backtrack entries store only the *index and old value* of the single
///   capture slot that changed, NOT a full snapshot of the captures array.
///   This avoids O(captureCount) copies on every saveStart/saveEnd.
/// - Stack and captures use ContiguousArray with pre-allocated capacity.
/// - Input and bytecode are accessed through UnsafeBufferPointer in the
///   hot loop to eliminate bounds checking.
private final class REVirtualMachine {
    let bc: [UInt8]         // full bytecode including header
    let bcStart: Int        // offset of first opcode (after header)
    let bcEnd: Int          // offset past last opcode
    let input: [UInt32]     // input code points (or UTF-16 code units)
    let inputLen: Int
    var startPos: Int       // starting position in input (var for reuse in global match)
    let flags: JeffJSRegExpFlags
    let captureCount: Int

    // Execution state
    var captures: ContiguousArray<Int>   // flat: [start0, end0, start1, end1, ...]
    var stack: ContiguousArray<BacktrackEntry>   // backtracking stack
    var stepCount: Int = 0
    let stepLimit: Int = 10_000_000  // safety limit

    struct BacktrackEntry {
        var pc: Int
        var pos: Int
        var captureIdx: Int32     // index into captures to restore (-1 = none)
        var captureVal: Int       // old value to restore
        var extra: Int32          // extra data (for pushI32, char pos)

        // Backtrack with capture restore
        @inline(__always)
        init(pc: Int, pos: Int, captureIdx: Int32, captureVal: Int) {
            self.pc = pc
            self.pos = pos
            self.captureIdx = captureIdx
            self.captureVal = captureVal
            self.extra = 0
        }

        // Split/goto backtrack (no capture restore)
        @inline(__always)
        init(pc: Int, pos: Int) {
            self.pc = pc
            self.pos = pos
            self.captureIdx = -1
            self.captureVal = 0
            self.extra = 0
        }

        // Value entry (pushI32 / pushCharPos)
        @inline(__always)
        init(value: Int32) {
            self.pc = -2
            self.pos = 0
            self.captureIdx = -1
            self.captureVal = 0
            self.extra = value
        }
    }

    init(bytecode: [UInt8], input: [UInt32], startPos: Int,
         flags: JeffJSRegExpFlags) {
        self.bc = bytecode
        self.input = input
        self.inputLen = input.count
        self.startPos = startPos
        self.flags = flags

        // Parse header.
        if bytecode.count >= kHeaderSize {
            let bcLen = Int(bytecode[3]) | (Int(bytecode[4]) << 8)
            self.bcStart = kHeaderSize
            self.bcEnd = kHeaderSize + bcLen
            self.captureCount = Int(bytecode[2])
        } else {
            self.bcStart = 0
            self.bcEnd = 0
            self.captureCount = 1
        }

        // Initialise captures to -1 (unmatched).
        self.captures = ContiguousArray<Int>(repeating: -1, count: captureCount * 2)
        self.stack = ContiguousArray<BacktrackEntry>()
        self.stack.reserveCapacity(1024)
    }

    /// Reset the VM for another match attempt at a new starting position.
    /// Reuses the same bytecode, input, and flags — only resets mutable state.
    func reset(startPos newPos: Int) {
        self.startPos = newPos
        self.stepCount = 0
        // Reset all captures to -1 (unmatched).
        for i in 0 ..< captures.count {
            captures[i] = -1
        }
        stack.removeAll(keepingCapacity: true)
    }

    // MARK: Top-level exec

    func exec() -> JeffJSRegExpExecResult {
        guard bcEnd > bcStart else {
            return JeffJSRegExpExecResult(result: .error, captures: [])
        }

        let result = run(pc: bcStart, pos: startPos)

        if result {
            // Build capture pairs.
            var pairs = [(start: Int, end: Int)?]()
            for i in 0 ..< captureCount {
                let s = captures[i * 2]
                let e = captures[i * 2 + 1]
                if s >= 0 && e >= 0 {
                    pairs.append((start: s, end: e))
                } else {
                    pairs.append(nil)
                }
            }
            return JeffJSRegExpExecResult(result: .match, captures: pairs)
        }
        return JeffJSRegExpExecResult(result: .noMatch, captures: [])
    }

    // MARK: Read helpers

    func readU8(_ pc: Int) -> UInt8 {
        return bc[pc]
    }

    func readU16(_ pc: Int) -> UInt16 {
        return UInt16(bc[pc]) | (UInt16(bc[pc + 1]) << 8)
    }

    func readU32(_ pc: Int) -> UInt32 {
        return UInt32(bc[pc])
            | (UInt32(bc[pc + 1]) << 8)
            | (UInt32(bc[pc + 2]) << 16)
            | (UInt32(bc[pc + 3]) << 24)
    }

    func readI32(_ pc: Int) -> Int32 {
        return Int32(bitPattern: readU32(pc))
    }

    // MARK: Input access

    func getChar(_ pos: Int) -> UInt32 {
        guard pos >= 0, pos < inputLen else { return 0xFFFF_FFFF }
        return input[pos]
    }

    /// Get char and decode surrogate pairs if in unicode mode.
    func getCharUnicode(_ pos: Int) -> (codePoint: UInt32, width: Int) {
        guard pos >= 0, pos < inputLen else { return (0xFFFF_FFFF, 0) }
        let c = input[pos]
        if flags.isUnicode && c >= 0xD800 && c <= 0xDBFF && pos + 1 < inputLen {
            let lo = input[pos + 1]
            if lo >= 0xDC00 && lo <= 0xDFFF {
                let cp = 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00)
                return (cp, 2)
            }
        }
        return (c, 1)
    }

    /// Get the code point just before pos (for lookbehind / word boundary).
    func getCharBefore(_ pos: Int) -> (codePoint: UInt32, width: Int) {
        guard pos > 0 else { return (0xFFFF_FFFF, 0) }
        let c = input[pos - 1]
        if flags.isUnicode && c >= 0xDC00 && c <= 0xDFFF && pos - 2 >= 0 {
            let hi = input[pos - 2]
            if hi >= 0xD800 && hi <= 0xDBFF {
                let cp = 0x10000 + ((hi - 0xD800) << 10) + (c - 0xDC00)
                return (cp, 2)
            }
        }
        return (c, 1)
    }

    // MARK: Main VM loop

    func run(pc initialPC: Int, pos initialPos: Int) -> Bool {
        var pc = initialPC
        var pos = initialPos
        stack.removeAll(keepingCapacity: true)

        // Use unsafe buffer pointers for the hot loop to avoid bounds checking.
        return bc.withUnsafeBufferPointer { bcBuf in
            input.withUnsafeBufferPointer { inputBuf in
                runInner(pc: &pc, pos: &pos, bcBuf: bcBuf, inputBuf: inputBuf)
            }
        }
    }

    /// Read a signed 32-bit value from bytecode using unsafe pointer.
    @inline(__always)
    private static func readI32Fast(_ buf: UnsafeBufferPointer<UInt8>, _ pc: Int) -> Int32 {
        return Int32(bitPattern:
            UInt32(buf[pc])
            | (UInt32(buf[pc + 1]) << 8)
            | (UInt32(buf[pc + 2]) << 16)
            | (UInt32(buf[pc + 3]) << 24)
        )
    }

    /// Read an unsigned 32-bit value from bytecode using unsafe pointer.
    @inline(__always)
    private static func readU32Fast(_ buf: UnsafeBufferPointer<UInt8>, _ pc: Int) -> UInt32 {
        return UInt32(buf[pc])
            | (UInt32(buf[pc + 1]) << 8)
            | (UInt32(buf[pc + 2]) << 16)
            | (UInt32(buf[pc + 3]) << 24)
    }

    /// Inner VM loop using unsafe buffer pointers for zero-cost array access.
    private func runInner(
        pc pcRef: inout Int,
        pos posRef: inout Int,
        bcBuf: UnsafeBufferPointer<UInt8>,
        inputBuf: UnsafeBufferPointer<UInt32>
    ) -> Bool {
        var pc = pcRef
        var pos = posRef

        // Phase 5: Raw opcode constants for direct UInt8 switch (no enum init overhead).
        let OP_MATCH: UInt8 = 10
        let OP_CHAR: UInt8 = 1
        let OP_CHAR32: UInt8 = 2
        let OP_DOT: UInt8 = 3
        let OP_ANY: UInt8 = 4
        let OP_LINE_START: UInt8 = 5
        let OP_LINE_END: UInt8 = 6
        let OP_GOTO: UInt8 = 7
        let OP_SPLIT_GOTO_FIRST: UInt8 = 8
        let OP_SPLIT_NEXT_FIRST: UInt8 = 9
        let OP_SAVE_START: UInt8 = 11
        let OP_SAVE_END: UInt8 = 12
        let OP_SAVE_RESET: UInt8 = 13
        let OP_LOOP: UInt8 = 14
        let OP_PUSH_I32: UInt8 = 15
        let OP_DROP: UInt8 = 16
        let OP_WORD_BOUNDARY: UInt8 = 17
        let OP_NOT_WORD_BOUNDARY: UInt8 = 18
        let OP_BACK_REFERENCE: UInt8 = 19
        let OP_BACKWARD_BACK_REFERENCE: UInt8 = 20
        let OP_RANGE: UInt8 = 21
        let OP_RANGE32: UInt8 = 22
        let OP_LOOKAHEAD: UInt8 = 23
        let OP_NEGATIVE_LOOKAHEAD: UInt8 = 24
        let OP_PUSH_CHAR_POS: UInt8 = 25
        let OP_CHECK_ADVANCE: UInt8 = 26
        let OP_PREV: UInt8 = 27
        let OP_SIMPLE_GREEDY_QUANT: UInt8 = 28

        while true {
            // Phase 5: Check step count every 1024 steps instead of every step.
            stepCount += 1
            if stepCount & 0x3FF == 0 && stepCount > stepLimit { return false }

            let opByte = bcBuf[pc]

            // Phase 5: Switch directly on UInt8 opByte, avoiding enum init.
            switch opByte {
            case OP_MATCH:
                pcRef = pc
                posRef = pos
                return true

            case OP_CHAR:
                let expected = UInt32(bcBuf[pc + 1]) | (UInt32(bcBuf[pc + 2]) << 8)
                let (ch, w) = getCharUnicodeFast(pos, inputBuf)
                if matchCharCaseInsensitive(ch, expected) {
                    pos += w
                    pc += 3
                } else {
                    if !backtrack(&pc, &pos) { return false }
                }

            case OP_CHAR32:
                let expected = UInt32(bcBuf[pc + 1])
                    | (UInt32(bcBuf[pc + 2]) << 8)
                    | (UInt32(bcBuf[pc + 3]) << 16)
                    | (UInt32(bcBuf[pc + 4]) << 24)
                let (ch, w) = getCharUnicodeFast(pos, inputBuf)
                if matchCharCaseInsensitive(ch, expected) {
                    pos += w
                    pc += 5
                } else {
                    if !backtrack(&pc, &pos) { return false }
                }

            case OP_DOT:
                let (ch, w) = getCharUnicodeFast(pos, inputBuf)
                if ch != 0xFFFF_FFFF && !lreIsLineTerminator(ch) {
                    pos += w
                    pc += 1
                } else {
                    if !backtrack(&pc, &pos) { return false }
                }

            case OP_ANY:
                if pos < inputLen {
                    let (_, w) = getCharUnicodeFast(pos, inputBuf)
                    pos += w
                    pc += 1
                } else {
                    if !backtrack(&pc, &pos) { return false }
                }

            case OP_LINE_START:
                if pos == 0 || (flags.contains(.multiline) && pos > 0 && lreIsLineTerminator(inputBuf[pos - 1])) {
                    pc += 1
                } else {
                    if !backtrack(&pc, &pos) { return false }
                }

            case OP_LINE_END:
                if pos == inputLen || (flags.contains(.multiline) && pos < inputLen && lreIsLineTerminator(inputBuf[pos])) {
                    pc += 1
                } else {
                    if !backtrack(&pc, &pos) { return false }
                }

            case OP_GOTO:
                let offset = REVirtualMachine.readI32Fast(bcBuf, pc + 1)
                pc = pc + 5 + Int(offset)

            case OP_SPLIT_GOTO_FIRST:
                let offset = REVirtualMachine.readI32Fast(bcBuf, pc + 1)
                // Push alternative: "next instruction" on the backtrack stack.
                pushState(pc: pc + 5, pos: pos)
                // Take the goto branch first.
                pc = pc + 5 + Int(offset)

            case OP_SPLIT_NEXT_FIRST:
                let offset = REVirtualMachine.readI32Fast(bcBuf, pc + 1)
                // Push alternative: "goto branch" on the backtrack stack.
                pushState(pc: pc + 5 + Int(offset), pos: pos)
                // Take the next instruction first.
                pc += 5

            case OP_SAVE_START:
                let groupId = Int(bcBuf[pc + 1])
                let idx = groupId * 2
                if idx < captures.count {
                    // Save old value for backtracking — only this one slot.
                    let old = captures[idx]
                    captures[idx] = pos
                    stack.append(BacktrackEntry(pc: -1, pos: pos, captureIdx: Int32(idx), captureVal: old))
                }
                pc += 2

            case OP_SAVE_END:
                let groupId = Int(bcBuf[pc + 1])
                let idx = groupId * 2 + 1
                if idx < captures.count {
                    let old = captures[idx]
                    captures[idx] = pos
                    stack.append(BacktrackEntry(pc: -1, pos: pos, captureIdx: Int32(idx), captureVal: old))
                }
                pc += 2

            case OP_SAVE_RESET:
                let start = Int(bcBuf[pc + 1])
                let count = Int(bcBuf[pc + 2])
                // Reset captures in range [start, start+count) to -1.
                for g in start ..< start + count {
                    let si = g * 2
                    let ei = g * 2 + 1
                    if si < captures.count { captures[si] = -1 }
                    if ei < captures.count { captures[ei] = -1 }
                }
                pc += 3

            case OP_LOOP:
                // The loop opcode manages a counter on the backtrack stack.
                pc += 5

            case OP_PUSH_I32:
                let val = REVirtualMachine.readI32Fast(bcBuf, pc + 1)
                pushValue(val)
                pc += 5

            case OP_DROP:
                popValue()
                pc += 1

            case OP_WORD_BOUNDARY:
                if isWordBoundary(pos) {
                    pc += 1
                } else {
                    if !backtrack(&pc, &pos) { return false }
                }

            case OP_NOT_WORD_BOUNDARY:
                if !isWordBoundary(pos) {
                    pc += 1
                } else {
                    if !backtrack(&pc, &pos) { return false }
                }

            case OP_BACK_REFERENCE:
                let groupId = Int(bcBuf[pc + 1])
                if matchBackReference(groupId, pos: &pos) {
                    pc += 2
                } else {
                    if !backtrack(&pc, &pos) { return false }
                }

            case OP_BACKWARD_BACK_REFERENCE:
                let groupId = Int(bcBuf[pc + 1])
                if matchBackReference(groupId, pos: &pos) {
                    pc += 2
                } else {
                    if !backtrack(&pc, &pos) { return false }
                }

            case OP_RANGE:
                let pairCount = Int(UInt16(bcBuf[pc + 1]) | (UInt16(bcBuf[pc + 2]) << 8))
                let (ch, w) = getCharUnicodeFast(pos, inputBuf)
                if ch != 0xFFFF_FFFF && matchRange16Fast(bcBuf, pc + 3, pairCount: pairCount, ch: ch) {
                    pos += w
                    pc += 3 + pairCount * 4  // 2 bytes per endpoint * 2
                } else {
                    if !backtrack(&pc, &pos) { return false }
                }

            case OP_RANGE32:
                let pairCount = Int(UInt16(bcBuf[pc + 1]) | (UInt16(bcBuf[pc + 2]) << 8))
                let (ch, w) = getCharUnicodeFast(pos, inputBuf)
                if ch != 0xFFFF_FFFF && matchRange32Fast(bcBuf, pc + 3, pairCount: pairCount, ch: ch) {
                    pos += w
                    pc += 3 + pairCount * 8  // 4 bytes per endpoint * 2
                } else {
                    if !backtrack(&pc, &pos) { return false }
                }

            case OP_LOOKAHEAD:
                let offset = REVirtualMachine.readI32Fast(bcBuf, pc + 1)
                let savedCaptures = captures
                let savedPos = pos
                let bodyPC = pc + 6
                let matched = runSub(pc: bodyPC, pos: pos)
                if matched {
                    // Lookahead succeeded, continue after it.
                    pos = savedPos
                    pc = pc + 6 + Int(offset) - 1
                    // Restore captures? No -- lookahead can set captures per spec.
                } else {
                    captures = savedCaptures
                    if !backtrack(&pc, &pos) { return false }
                }

            case OP_NEGATIVE_LOOKAHEAD:
                let offset = REVirtualMachine.readI32Fast(bcBuf, pc + 1)
                let savedCaptures = captures
                let savedPos = pos
                let bodyPC = pc + 6
                let matched = runSub(pc: bodyPC, pos: pos)
                if !matched {
                    // Negative lookahead succeeded (body did NOT match).
                    captures = savedCaptures
                    pos = savedPos
                    pc = pc + 6 + Int(offset) - 1
                } else {
                    captures = savedCaptures
                    if !backtrack(&pc, &pos) { return false }
                }

            case OP_PUSH_CHAR_POS:
                pushValue(Int32(pos))
                pc += 1

            case OP_CHECK_ADVANCE:
                if let savedPos = popValue() {
                    if pos == Int(savedPos) {
                        // No progress — fail this branch to prevent infinite loop.
                        if !backtrack(&pc, &pos) { return false }
                    } else {
                        pc += 1
                    }
                } else {
                    pc += 1
                }

            case OP_PREV:
                if pos > 0 {
                    let (_, w) = getCharBefore(pos)
                    pos -= max(w, 1)
                    pc += 1
                } else {
                    if !backtrack(&pc, &pos) { return false }
                }

            case OP_SIMPLE_GREEDY_QUANT:
                // Header: 1 opcode + 4 offset + 4 min + 4 max + 4 body_len
                let qmin = REVirtualMachine.readU32Fast(bcBuf, pc + 5)
                let qmax = REVirtualMachine.readU32Fast(bcBuf, pc + 9)
                let bodyLen = REVirtualMachine.readU32Fast(bcBuf, pc + 13)
                let bodyPC = pc + 17
                let afterPC = pc + 17 + Int(bodyLen)

                // Read the single body opcode for inline evaluation.
                let bodyOp = bcBuf[bodyPC]
                var count: UInt32 = 0

                // Tight inline loop: evaluate the single body opcode directly
                // without creating a sub-VM or backtrack context.
                switch bodyOp {
                case JeffJSRegExpOpcode.char_.rawValue:
                    // char_: match one 16-bit char
                    let expected = UInt32(bcBuf[bodyPC + 1]) | (UInt32(bcBuf[bodyPC + 2]) << 8)
                    while count < qmax && pos < inputLen {
                        let (ch, w) = getCharUnicodeFast(pos, inputBuf)
                        if matchCharCaseInsensitive(ch, expected) {
                            pos += w
                            count += 1
                        } else {
                            break
                        }
                    }

                case JeffJSRegExpOpcode.char32.rawValue:
                    // char32: match one 32-bit char
                    let expected = UInt32(bcBuf[bodyPC + 1])
                        | (UInt32(bcBuf[bodyPC + 2]) << 8)
                        | (UInt32(bcBuf[bodyPC + 3]) << 16)
                        | (UInt32(bcBuf[bodyPC + 4]) << 24)
                    while count < qmax && pos < inputLen {
                        let (ch, w) = getCharUnicodeFast(pos, inputBuf)
                        if matchCharCaseInsensitive(ch, expected) {
                            pos += w
                            count += 1
                        } else {
                            break
                        }
                    }

                case JeffJSRegExpOpcode.dot.rawValue:
                    // dot: match any except line terminators
                    while count < qmax && pos < inputLen {
                        let (ch, w) = getCharUnicodeFast(pos, inputBuf)
                        if ch != 0xFFFF_FFFF && !lreIsLineTerminator(ch) {
                            pos += w
                            count += 1
                        } else {
                            break
                        }
                    }

                case JeffJSRegExpOpcode.any.rawValue:
                    // any: match any char (s flag)
                    while count < qmax && pos < inputLen {
                        let (_, w) = getCharUnicodeFast(pos, inputBuf)
                        pos += w
                        count += 1
                    }

                case JeffJSRegExpOpcode.range.rawValue:
                    // range: character class [...] with 16-bit pairs
                    let pairCount = Int(UInt16(bcBuf[bodyPC + 1]) | (UInt16(bcBuf[bodyPC + 2]) << 8))
                    let rangeDataPC = bodyPC + 3
                    if pairCount == 1 && !flags.contains(.ignoreCase) {
                        // Fast path: single range pair (e.g., \d = [0x30, 0x39])
                        let lo = UInt32(bcBuf[rangeDataPC]) | (UInt32(bcBuf[rangeDataPC + 1]) << 8)
                        let hi = UInt32(bcBuf[rangeDataPC + 2]) | (UInt32(bcBuf[rangeDataPC + 3]) << 8)
                        while count < qmax && pos < inputLen {
                            let ch = inputBuf[pos]
                            if ch >= lo && ch <= hi {
                                pos += 1
                                count += 1
                            } else {
                                break
                            }
                        }
                    } else {
                        while count < qmax && pos < inputLen {
                            let (ch, w) = getCharUnicodeFast(pos, inputBuf)
                            if ch != 0xFFFF_FFFF && matchRange16Fast(bcBuf, rangeDataPC, pairCount: pairCount, ch: ch) {
                                pos += w
                                count += 1
                            } else {
                                break
                            }
                        }
                    }

                case JeffJSRegExpOpcode.range32.rawValue:
                    // range32: character class [...] with 32-bit pairs
                    let pairCount = Int(UInt16(bcBuf[bodyPC + 1]) | (UInt16(bcBuf[bodyPC + 2]) << 8))
                    let rangeDataPC = bodyPC + 3
                    while count < qmax && pos < inputLen {
                        let (ch, w) = getCharUnicodeFast(pos, inputBuf)
                        if ch != 0xFFFF_FFFF && matchRange32Fast(bcBuf, rangeDataPC, pairCount: pairCount, ch: ch) {
                            pos += w
                            count += 1
                        } else {
                            break
                        }
                    }

                default:
                    // Fallback: run full sub-VM for unknown opcodes
                    while count < qmax {
                        let savedPos = pos
                        if runSub(pc: bodyPC, pos: pos) && pos > savedPos {
                            count += 1
                        } else {
                            pos = savedPos
                            break
                        }
                    }
                }

                if count < qmin {
                    if !backtrack(&pc, &pos) { return false }
                } else {
                    pc = afterPC
                }

            default:
                // Invalid or unknown opcode.
                return false
            }
        }
    }

    // MARK: Fast input access (unsafe)

    /// Get char and decode surrogate pairs -- unsafe buffer pointer version.
    @inline(__always)
    private func getCharUnicodeFast(_ pos: Int, _ buf: UnsafeBufferPointer<UInt32>) -> (codePoint: UInt32, width: Int) {
        guard pos >= 0, pos < inputLen else { return (0xFFFF_FFFF, 0) }
        let c = buf[pos]
        if flags.isUnicode && c >= 0xD800 && c <= 0xDBFF && pos + 1 < inputLen {
            let lo = buf[pos + 1]
            if lo >= 0xDC00 && lo <= 0xDFFF {
                let cp = 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00)
                return (cp, 2)
            }
        }
        return (c, 1)
    }

    // MARK: Sub-execution (for lookahead, simpleGreedyQuant)

    func runSub(pc startPC: Int, pos startPos: Int) -> Bool {
        // Save the parent's stack portion and clear it -- the sub-execution
        // gets a clean stack so backtrack() cannot pop parent entries.
        let savedStack = stack
        let savedCaptures = captures
        stack.removeAll(keepingCapacity: true)

        var pc = startPC
        var pos = startPos
        let result = bc.withUnsafeBufferPointer { bcBuf in
            input.withUnsafeBufferPointer { inputBuf in
                runInner(pc: &pc, pos: &pos, bcBuf: bcBuf, inputBuf: inputBuf)
            }
        }

        // Restore parent stack.
        stack = savedStack
        if !result {
            captures = savedCaptures
        }
        // Don't restore stepCount — let the limit accumulate.

        return result
    }

    // MARK: Backtracking

    @inline(__always)
    func pushState(pc: Int, pos: Int) {
        stack.append(BacktrackEntry(pc: pc, pos: pos))
    }

    @inline(__always)
    func pushValue(_ val: Int32) {
        stack.append(BacktrackEntry(value: val))
    }

    @discardableResult
    @inline(__always)
    func popValue() -> Int32? {
        if let last = stack.last, last.pc == -2 {
            stack.removeLast()
            return last.extra
        }
        return nil
    }

    func backtrack(_ pc: inout Int, _ pos: inout Int) -> Bool {
        while let entry = stack.popLast() {
            if entry.pc == -2 {
                // Value entry, skip.
                continue
            }
            if entry.pc == -1 {
                // Capture restore entry — restore the single slot and keep searching.
                let idx = Int(entry.captureIdx)
                if idx >= 0 && idx < captures.count {
                    captures[idx] = entry.captureVal
                }
                continue
            }
            // Real backtrack entry — restore position and resume.
            pc = entry.pc
            pos = entry.pos
            return true
        }
        return false
    }

    // MARK: Character matching helpers

    func matchCharCaseInsensitive(_ actual: UInt32, _ expected: UInt32) -> Bool {
        if actual == expected { return true }
        if !flags.contains(.ignoreCase) { return false }

        // Fold both sides and compare.
        if flags.isUnicode {
            return lreCanonicalizeUnicode(actual) == lreCanonicalizeUnicode(expected)
        }
        // Non-unicode: only ASCII fold.
        func asciiLower(_ c: UInt32) -> UInt32 {
            if c >= 0x41 && c <= 0x5A { return c + 0x20 }
            return c
        }
        return asciiLower(actual) == asciiLower(expected)
    }

    func matchRange16(_ offset: Int, pairCount: Int, ch: UInt32) -> Bool {
        let isIC = flags.contains(.ignoreCase)
        let c: UInt32 = isIC ? (flags.isUnicode ? lreCanonicalizeUnicode(ch) : ch) : ch

        var off = offset
        if isIC {
            let isUni = flags.isUnicode
            for _ in 0 ..< pairCount {
                let lo = UInt32(readU16(off))
                let hi = UInt32(readU16(off + 2))
                off += 4
                if c >= lo && c <= hi { return true }
                if !isUni {
                    // ASCII case variants
                    let lower: UInt32 = (ch >= 0x41 && ch <= 0x5A) ? ch + 0x20 : ch
                    let upper: UInt32 = (ch >= 0x61 && ch <= 0x7A) ? ch - 0x20 : ch
                    if lower >= lo && lower <= hi { return true }
                    if upper >= lo && upper <= hi { return true }
                }
            }
        } else {
            // Fast non-ignoreCase path
            if pairCount == 1 {
                // Single pair fast path (common: \d, \w ranges)
                let lo = UInt32(readU16(off))
                let hi = UInt32(readU16(off + 2))
                return c >= lo && c <= hi
            }
            for _ in 0 ..< pairCount {
                let lo = UInt32(readU16(off))
                let hi = UInt32(readU16(off + 2))
                off += 4
                if c >= lo && c <= hi { return true }
            }
        }
        return false
    }

    func matchRange32(_ offset: Int, pairCount: Int, ch: UInt32) -> Bool {
        let isIC = flags.contains(.ignoreCase)
        let c: UInt32 = isIC ? (flags.isUnicode ? lreCanonicalizeUnicode(ch) : ch) : ch

        var off = offset
        if isIC {
            for _ in 0 ..< pairCount {
                let lo = readU32(off)
                let hi = readU32(off + 4)
                off += 8
                if c >= lo && c <= hi { return true }
            }
        } else {
            if pairCount == 1 {
                let lo = readU32(off)
                let hi = readU32(off + 4)
                return c >= lo && c <= hi
            }
            for _ in 0 ..< pairCount {
                let lo = readU32(off)
                let hi = readU32(off + 4)
                off += 8
                if c >= lo && c <= hi { return true }
            }
        }
        return false
    }

    // MARK: Fast range matching with UnsafeBufferPointer (Phase 4)

    /// Match a 16-bit character class using unsafe buffer pointer for bytecode access.
    @inline(__always)
    func matchRange16Fast(_ bcBuf: UnsafeBufferPointer<UInt8>, _ offset: Int, pairCount: Int, ch: UInt32) -> Bool {
        let isIC = flags.contains(.ignoreCase)
        let c: UInt32 = isIC ? (flags.isUnicode ? lreCanonicalizeUnicode(ch) : ch) : ch

        var off = offset
        if isIC {
            let isUni = flags.isUnicode
            for _ in 0 ..< pairCount {
                let lo = UInt32(bcBuf[off]) | (UInt32(bcBuf[off + 1]) << 8)
                let hi = UInt32(bcBuf[off + 2]) | (UInt32(bcBuf[off + 3]) << 8)
                off += 4
                if c >= lo && c <= hi { return true }
                if !isUni {
                    let lower: UInt32 = (ch >= 0x41 && ch <= 0x5A) ? ch + 0x20 : ch
                    let upper: UInt32 = (ch >= 0x61 && ch <= 0x7A) ? ch - 0x20 : ch
                    if lower >= lo && lower <= hi { return true }
                    if upper >= lo && upper <= hi { return true }
                }
            }
        } else {
            if pairCount == 1 {
                let lo = UInt32(bcBuf[off]) | (UInt32(bcBuf[off + 1]) << 8)
                let hi = UInt32(bcBuf[off + 2]) | (UInt32(bcBuf[off + 3]) << 8)
                return c >= lo && c <= hi
            }
            for _ in 0 ..< pairCount {
                let lo = UInt32(bcBuf[off]) | (UInt32(bcBuf[off + 1]) << 8)
                let hi = UInt32(bcBuf[off + 2]) | (UInt32(bcBuf[off + 3]) << 8)
                off += 4
                if c >= lo && c <= hi { return true }
            }
        }
        return false
    }

    /// Match a 32-bit character class using unsafe buffer pointer for bytecode access.
    @inline(__always)
    func matchRange32Fast(_ bcBuf: UnsafeBufferPointer<UInt8>, _ offset: Int, pairCount: Int, ch: UInt32) -> Bool {
        let isIC = flags.contains(.ignoreCase)
        let c: UInt32 = isIC ? (flags.isUnicode ? lreCanonicalizeUnicode(ch) : ch) : ch

        var off = offset
        if isIC {
            for _ in 0 ..< pairCount {
                let lo = UInt32(bcBuf[off]) | (UInt32(bcBuf[off + 1]) << 8) | (UInt32(bcBuf[off + 2]) << 16) | (UInt32(bcBuf[off + 3]) << 24)
                let hi = UInt32(bcBuf[off + 4]) | (UInt32(bcBuf[off + 5]) << 8) | (UInt32(bcBuf[off + 6]) << 16) | (UInt32(bcBuf[off + 7]) << 24)
                off += 8
                if c >= lo && c <= hi { return true }
            }
        } else {
            if pairCount == 1 {
                let lo = UInt32(bcBuf[off]) | (UInt32(bcBuf[off + 1]) << 8) | (UInt32(bcBuf[off + 2]) << 16) | (UInt32(bcBuf[off + 3]) << 24)
                let hi = UInt32(bcBuf[off + 4]) | (UInt32(bcBuf[off + 5]) << 8) | (UInt32(bcBuf[off + 6]) << 16) | (UInt32(bcBuf[off + 7]) << 24)
                return c >= lo && c <= hi
            }
            for _ in 0 ..< pairCount {
                let lo = UInt32(bcBuf[off]) | (UInt32(bcBuf[off + 1]) << 8) | (UInt32(bcBuf[off + 2]) << 16) | (UInt32(bcBuf[off + 3]) << 24)
                let hi = UInt32(bcBuf[off + 4]) | (UInt32(bcBuf[off + 5]) << 8) | (UInt32(bcBuf[off + 6]) << 16) | (UInt32(bcBuf[off + 7]) << 24)
                off += 8
                if c >= lo && c <= hi { return true }
            }
        }
        return false
    }

    func isWordBoundary(_ pos: Int) -> Bool {
        let left: Bool
        if pos == 0 {
            left = false
        } else {
            let (ch, _) = getCharBefore(pos)
            left = lreIsWordChar(ch)
        }
        let right: Bool
        if pos >= inputLen {
            right = false
        } else {
            let (ch, _) = getCharUnicode(pos)
            right = lreIsWordChar(ch)
        }
        return left != right
    }

    func matchBackReference(_ groupId: Int, pos: inout Int) -> Bool {
        guard groupId < captureCount else { return true }
        let si = groupId * 2
        let ei = groupId * 2 + 1
        guard si < captures.count, ei < captures.count else { return true }
        let start = captures[si]
        let end = captures[ei]
        if start < 0 || end < 0 {
            // Unmatched group — always succeeds (matches empty).
            return true
        }
        let len = end - start
        if pos + len > inputLen { return false }

        for i in 0 ..< len {
            let expected = input[start + i]
            let actual = input[pos + i]
            if !matchCharCaseInsensitive(actual, expected) {
                return false
            }
        }
        pos += len
        return true
    }
}

// ============================================================================
// MARK: - High-level convenience API
// ============================================================================

/// Compile and execute a regex in one call. Convenience wrapper.
func lreCompileAndExec(pattern: String, input: String, flags: JeffJSRegExpFlags,
                       startPos: Int = 0) -> JeffJSRegExpExecResult {
    let compiled = lreCompile(pattern: pattern, flags: flags)
    if compiled.error != nil {
        return JeffJSRegExpExecResult(result: .error, captures: [])
    }
    return lreExec(bytecode: compiled.bytecode, input: input,
                   startPos: startPos, flags: flags)
}

/// Parse regex flags from a flag string ("gimsuyvd").
func lreParseFlags(_ flagStr: String) -> JeffJSRegExpFlags? {
    var flags = JeffJSRegExpFlags()
    var seen = Set<Character>()
    for ch in flagStr {
        if seen.contains(ch) { return nil } // duplicate flag
        seen.insert(ch)
        switch ch {
        case "g": flags.insert(.global)
        case "i": flags.insert(.ignoreCase)
        case "m": flags.insert(.multiline)
        case "s": flags.insert(.dotAll)
        case "u": flags.insert(.unicode)
        case "y": flags.insert(.sticky)
        case "d": flags.insert(.hasIndices)
        case "v": flags.insert(.unicodeSets)
        default: return nil  // invalid flag
        }
    }
    // u and v are mutually exclusive.
    if flags.contains(.unicode) && flags.contains(.unicodeSets) {
        return nil
    }
    return flags
}

// ============================================================================
// MARK: - Bytecode disassembler (debug)
// ============================================================================

/// Disassemble compiled regex bytecode into a human-readable string.
func lreDisassemble(_ bytecode: [UInt8]) -> String {
    guard bytecode.count >= kHeaderSize else { return "<invalid bytecode>" }

    let flags = lreGetFlags(bytecode)
    let captureCount = lreGetCaptureCount(bytecode)
    let bcLen = Int(bytecode[3]) | (Int(bytecode[4]) << 8)

    var out = "Flags: \(flags.rawValue), Captures: \(captureCount), BytecodeLen: \(bcLen)\n"

    var pc = kHeaderSize
    let end = kHeaderSize + bcLen

    while pc < end {
        let opByte = bytecode[pc]
        guard let op = JeffJSRegExpOpcode(rawValue: opByte) else {
            out += "\(pc - kHeaderSize): <unknown opcode \(opByte)>\n"
            pc += 1
            continue
        }

        let offset = pc - kHeaderSize
        switch op {
        case .char_:
            let ch = UInt16(bytecode[pc + 1]) | (UInt16(bytecode[pc + 2]) << 8)
            if ch >= 0x20 && ch < 0x7F {
                out += "\(offset): char '\(Character(Unicode.Scalar(ch)!))'\n"
            } else {
                out += "\(offset): char U+\(String(format: "%04X", ch))\n"
            }
            pc += 3

        case .char32:
            let ch = UInt32(bytecode[pc + 1])
                   | (UInt32(bytecode[pc + 2]) << 8)
                   | (UInt32(bytecode[pc + 3]) << 16)
                   | (UInt32(bytecode[pc + 4]) << 24)
            out += "\(offset): char32 U+\(String(format: "%06X", ch))\n"
            pc += 5

        case .dot:
            out += "\(offset): dot\n"
            pc += 1

        case .any:
            out += "\(offset): any\n"
            pc += 1

        case .lineStart:
            out += "\(offset): line_start\n"
            pc += 1

        case .lineEnd:
            out += "\(offset): line_end\n"
            pc += 1

        case .goto_:
            let off = Int32(bitPattern: UInt32(bytecode[pc + 1])
                          | (UInt32(bytecode[pc + 2]) << 8)
                          | (UInt32(bytecode[pc + 3]) << 16)
                          | (UInt32(bytecode[pc + 4]) << 24))
            out += "\(offset): goto \(Int(off) + offset + 5)\n"
            pc += 5

        case .splitGotoFirst:
            let off = Int32(bitPattern: UInt32(bytecode[pc + 1])
                          | (UInt32(bytecode[pc + 2]) << 8)
                          | (UInt32(bytecode[pc + 3]) << 16)
                          | (UInt32(bytecode[pc + 4]) << 24))
            out += "\(offset): split_goto_first \(Int(off) + offset + 5)\n"
            pc += 5

        case .splitNextFirst:
            let off = Int32(bitPattern: UInt32(bytecode[pc + 1])
                          | (UInt32(bytecode[pc + 2]) << 8)
                          | (UInt32(bytecode[pc + 3]) << 16)
                          | (UInt32(bytecode[pc + 4]) << 24))
            out += "\(offset): split_next_first \(Int(off) + offset + 5)\n"
            pc += 5

        case .match:
            out += "\(offset): match\n"
            pc += 1

        case .saveStart:
            out += "\(offset): save_start \(bytecode[pc + 1])\n"
            pc += 2

        case .saveEnd:
            out += "\(offset): save_end \(bytecode[pc + 1])\n"
            pc += 2

        case .saveReset:
            out += "\(offset): save_reset \(bytecode[pc + 1]) \(bytecode[pc + 2])\n"
            pc += 3

        case .loop:
            out += "\(offset): loop\n"
            pc += 5

        case .pushI32:
            let val = Int32(bitPattern: UInt32(bytecode[pc + 1])
                          | (UInt32(bytecode[pc + 2]) << 8)
                          | (UInt32(bytecode[pc + 3]) << 16)
                          | (UInt32(bytecode[pc + 4]) << 24))
            out += "\(offset): push_i32 \(val)\n"
            pc += 5

        case .drop:
            out += "\(offset): drop\n"
            pc += 1

        case .wordBoundary:
            out += "\(offset): word_boundary\n"
            pc += 1

        case .notWordBoundary:
            out += "\(offset): not_word_boundary\n"
            pc += 1

        case .backReference:
            out += "\(offset): back_reference \(bytecode[pc + 1])\n"
            pc += 2

        case .backwardBackReference:
            out += "\(offset): backward_back_reference \(bytecode[pc + 1])\n"
            pc += 2

        case .range:
            let pairCount = Int(UInt16(bytecode[pc + 1]) | (UInt16(bytecode[pc + 2]) << 8))
            out += "\(offset): range (\(pairCount) pairs)\n"
            pc += 3 + pairCount * 4

        case .range32:
            let pairCount = Int(UInt16(bytecode[pc + 1]) | (UInt16(bytecode[pc + 2]) << 8))
            out += "\(offset): range32 (\(pairCount) pairs)\n"
            pc += 3 + pairCount * 8

        case .lookahead:
            let off = Int32(bitPattern: UInt32(bytecode[pc + 1])
                          | (UInt32(bytecode[pc + 2]) << 8)
                          | (UInt32(bytecode[pc + 3]) << 16)
                          | (UInt32(bytecode[pc + 4]) << 24))
            out += "\(offset): lookahead \(off) groups=\(bytecode[pc + 5])\n"
            pc += 6

        case .negativeLookahead:
            let off = Int32(bitPattern: UInt32(bytecode[pc + 1])
                          | (UInt32(bytecode[pc + 2]) << 8)
                          | (UInt32(bytecode[pc + 3]) << 16)
                          | (UInt32(bytecode[pc + 4]) << 24))
            out += "\(offset): negative_lookahead \(off) groups=\(bytecode[pc + 5])\n"
            pc += 6

        case .pushCharPos:
            out += "\(offset): push_char_pos\n"
            pc += 1

        case .checkAdvance:
            out += "\(offset): check_advance\n"
            pc += 1

        case .prev:
            out += "\(offset): prev\n"
            pc += 1

        case .simpleGreedyQuant:
            let sqMin = UInt32(bytecode[pc + 5]) | (UInt32(bytecode[pc + 6]) << 8)
                | (UInt32(bytecode[pc + 7]) << 16) | (UInt32(bytecode[pc + 8]) << 24)
            let sqMax = UInt32(bytecode[pc + 9]) | (UInt32(bytecode[pc + 10]) << 8)
                | (UInt32(bytecode[pc + 11]) << 16) | (UInt32(bytecode[pc + 12]) << 24)
            let bodyLen = UInt32(bytecode[pc + 13]) | (UInt32(bytecode[pc + 14]) << 8)
                | (UInt32(bytecode[pc + 15]) << 16) | (UInt32(bytecode[pc + 16]) << 24)
            out += "\(offset): simple_greedy_quant min=\(sqMin) max=\(sqMax == UInt32.max ? "inf" : "\(sqMax)") body_len=\(bodyLen)\n"
            pc += 17 + Int(bodyLen)

        case .invalid, .opcodeCount:
            out += "\(offset): <invalid>\n"
            pc += 1
        }
    }

    return out
}
