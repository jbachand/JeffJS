// JeffJSTokenizer.swift
// JeffJS — 1:1 Swift port of QuickJS JavaScript engine
//
// Complete JavaScript tokenizer / lexer.
// Port of next_token() and all supporting tokenizer code from quickjs.c.
// This is a single-pass lexer that produces tokens for the recursive-descent parser.
//
// Copyright 2026 Jeff Bachand. All rights reserved.

import Foundation

// MARK: - Token Data

/// Holds all data associated with a single token produced by the lexer.
/// Mirrors the C union `JSToken` in quickjs.c.
struct JeffJSToken {
    /// Token type — either a JSTokenType raw value (>= 128) or an ASCII char code (< 128).
    var type: Int = 0

    /// Byte offset in the source buffer where this token starts.
    var ptr: Int = 0

    /// Line number (1-based) where this token starts.
    var line: Int = 1

    // -- Numeric literal data --
    var numValue: Double = 0

    // -- String / template literal data --
    var strValue: String = ""
    var strSeparator: Character = "\0"

    // -- Identifier data --
    var identAtom: UInt32 = 0       // JSAtom index
    var identHasEscape: Bool = false
    var identIsReserved: Bool = false

    // -- Regular expression data --
    var regexpBody: String = ""
    var regexpFlags: String = ""

    mutating func reset() {
        type = 0
        ptr = 0
        numValue = 0
        strValue = ""
        strSeparator = "\0"
        identAtom = 0
        identHasEscape = false
        identIsReserved = false
        regexpBody = ""
        regexpFlags = ""
    }
}

// MARK: - Parse State

/// Mutable state for the tokenizer and parser.
/// Mirrors `JSParseState` in quickjs.c.
class JeffJSParseState {

    // -- Context --
    weak var ctx: JeffJSTokenizerContext?
    /// Strong reference used when the parse state owns its context (convenience init).
    private var ownedCtx: JeffJSTokenizerContext?
    var filename: String

    // -- Current and previous tokens --
    var token: JeffJSToken = JeffJSToken()
    var gotLF: Bool = false          // line feed seen before current token (for ASI)
    var lastLineNum: Int = 1         // line number at end of previous token
    var lastPtr: Int = 0             // byte offset at end of previous token

    // -- Source buffer (UTF-8 encoded) --
    var buf: [UInt8]
    var bufLen: Int
    var bufPtr: Int = 0              // current read position

    // -- Line tracking --
    var lineNum: Int = 1             // current line number (1-based)

    // -- Parser flags --
    var curFunc: JeffJSFunctionDef?
    var isModule: Bool = false
    var allowHTMLComments: Bool = true
    var extJSON: Bool = false

    // -- Template literal nesting --
    var templateNestLevel: Int = 0

    // -- Previous token type (for regex/division disambiguation) --
    var lastTokenType: Int = 0

    // -- Error state --
    /// The first syntax error message captured during parsing (nil if no error).
    var lastErrorMessage: String?

    init(source: String, filename: String = "<input>", ctx: JeffJSTokenizerContext? = nil) {
        self.filename = filename
        self.ctx = ctx
        let data = Array(source.utf8)
        self.buf = data
        self.bufLen = data.count
    }

    init(buf: [UInt8], filename: String = "<input>", ctx: JeffJSTokenizerContext? = nil) {
        self.filename = filename
        self.ctx = ctx
        self.buf = buf
        self.bufLen = buf.count
    }
}

// MARK: - Tokenizer Context (minimal interface)

/// Minimal context protocol that the tokenizer needs.
/// The real JeffJSContext will conform to this.
protocol JeffJSTokenizerContext: AnyObject {
    /// Find or create an atom for the given string. Returns 0 on failure.
    func findAtom(_ name: String) -> UInt32
}

// MARK: - Placeholder for JeffJSFunctionDef

/// Forward declaration placeholder — the real type lives in the parser/compiler.
class JeffJSFunctionDef {
    var jsMode: Int = 0   // JS_MODE_STRICT etc.
    var isStrict: Bool { return jsMode & JS_MODE_STRICT != 0 }
}

// MARK: - Keyword Table

/// Maps keyword strings to their JSTokenType raw values.
/// Order must match the QuickJS keyword atom table.
private let keywordTable: [(String, Int)] = [
    ("null",        JSTokenType.TOK_NULL.rawValue),
    ("false",       JSTokenType.TOK_FALSE.rawValue),
    ("true",        JSTokenType.TOK_TRUE.rawValue),
    ("if",          JSTokenType.TOK_IF.rawValue),
    ("else",        JSTokenType.TOK_ELSE.rawValue),
    ("return",      JSTokenType.TOK_RETURN.rawValue),
    ("var",         JSTokenType.TOK_VAR.rawValue),
    ("this",        JSTokenType.TOK_THIS.rawValue),
    ("delete",      JSTokenType.TOK_DELETE.rawValue),
    ("void",        JSTokenType.TOK_VOID.rawValue),
    ("typeof",      JSTokenType.TOK_TYPEOF.rawValue),
    ("new",         JSTokenType.TOK_NEW.rawValue),
    ("in",          JSTokenType.TOK_IN.rawValue),
    ("instanceof",  JSTokenType.TOK_INSTANCEOF.rawValue),
    ("do",          JSTokenType.TOK_DO.rawValue),
    ("while",       JSTokenType.TOK_WHILE.rawValue),
    ("for",         JSTokenType.TOK_FOR.rawValue),
    ("break",       JSTokenType.TOK_BREAK.rawValue),
    ("continue",    JSTokenType.TOK_CONTINUE.rawValue),
    ("switch",      JSTokenType.TOK_SWITCH.rawValue),
    ("case",        JSTokenType.TOK_CASE.rawValue),
    ("default",     JSTokenType.TOK_DEFAULT.rawValue),
    ("throw",       JSTokenType.TOK_THROW.rawValue),
    ("try",         JSTokenType.TOK_TRY.rawValue),
    ("catch",       JSTokenType.TOK_CATCH.rawValue),
    ("finally",     JSTokenType.TOK_FINALLY.rawValue),
    ("function",    JSTokenType.TOK_FUNCTION.rawValue),
    ("debugger",    JSTokenType.TOK_DEBUGGER.rawValue),
    ("with",        JSTokenType.TOK_WITH.rawValue),
    ("class",       JSTokenType.TOK_CLASS.rawValue),
    ("const",       JSTokenType.TOK_CONST.rawValue),
    ("enum",        JSTokenType.TOK_ENUM.rawValue),
    ("export",      JSTokenType.TOK_EXPORT.rawValue),
    ("extends",     JSTokenType.TOK_EXTENDS.rawValue),
    ("import",      JSTokenType.TOK_IMPORT.rawValue),
    ("super",       JSTokenType.TOK_SUPER.rawValue),
    ("implements",  JSTokenType.TOK_IMPLEMENTS.rawValue),
    ("interface",   JSTokenType.TOK_INTERFACE.rawValue),
    ("let",         JSTokenType.TOK_LET.rawValue),
    ("package",     JSTokenType.TOK_PACKAGE.rawValue),
    ("private",     JSTokenType.TOK_PRIVATE.rawValue),
    ("protected",   JSTokenType.TOK_PROTECTED.rawValue),
    ("public",      JSTokenType.TOK_PUBLIC.rawValue),
    ("static",      JSTokenType.TOK_STATIC.rawValue),
    ("yield",       JSTokenType.TOK_YIELD.rawValue),
    ("await",       JSTokenType.TOK_AWAIT.rawValue),
    ("of",          JSTokenType.TOK_OF.rawValue),
    ("accessor",    JSTokenType.TOK_ACCESSOR.rawValue),
]

/// Pre-built dictionary for fast keyword lookup.
private let keywordDict: [String: Int] = {
    var d = [String: Int](minimumCapacity: keywordTable.count)
    for (kw, tok) in keywordTable {
        d[kw] = tok
    }
    return d
}()

/// Set of strict-mode-only reserved words.
/// These are keywords only in strict mode; in sloppy mode they are valid identifiers.
private let strictModeReservedWords: Set<String> = [
    "implements", "interface", "let", "package", "private",
    "protected", "public", "static", "yield",
]

/// Set of future reserved words (always reserved).
private let futureReservedWords: Set<String> = [
    "enum",
]

// MARK: - Unicode Character Classification

/// Returns true if `c` can be the first character of a JavaScript identifier.
/// Matches QuickJS `lre_js_is_ident_first`.
func jeffJS_isIdentFirst(_ c: UInt32) -> Bool {
    if c == 0x24 { return true }  // $
    if c == 0x5F { return true }  // _
    // A-Z
    if c >= 0x41 && c <= 0x5A { return true }
    // a-z
    if c >= 0x61 && c <= 0x7A { return true }
    // Unicode letters (simplified — covers BMP Letter categories)
    if c >= 0x80 {
        return jeffJS_isUnicodeLetter(c)
    }
    return false
}

/// Returns true if `c` can appear after the first character in an identifier.
/// Matches QuickJS `lre_js_is_ident_next`.
func jeffJS_isIdentNext(_ c: UInt32) -> Bool {
    if jeffJS_isIdentFirst(c) { return true }
    // 0-9
    if c >= 0x30 && c <= 0x39 { return true }
    // Zero-width non-joiner / zero-width joiner
    if c == 0x200C || c == 0x200D { return true }
    // Unicode combining marks, connector punctuation, digits
    if c >= 0x80 {
        return jeffJS_isUnicodeIdentPart(c)
    }
    return false
}

/// Simplified Unicode letter check using Character properties.
/// A full implementation would use the Unicode ID_Start / ID_Continue tables.
private func jeffJS_isUnicodeLetter(_ c: UInt32) -> Bool {
    guard let scalar = Unicode.Scalar(c) else { return false }
    let ch = Character(scalar)
    return ch.isLetter
}

/// Simplified Unicode identifier-continuation check.
private func jeffJS_isUnicodeIdentPart(_ c: UInt32) -> Bool {
    guard let scalar = Unicode.Scalar(c) else { return false }
    let ch = Character(scalar)
    return ch.isLetter || ch.isNumber ||
           c == 0x200C || c == 0x200D  // ZWNJ, ZWJ
}

// MARK: - Low-level Buffer Helpers

extension JeffJSParseState {

    /// Peek at the current byte without advancing.
    @inline(__always)
    func peekByte() -> UInt8 {
        guard bufPtr < bufLen else { return 0 }
        return buf[bufPtr]
    }

    /// Peek at byte at offset `n` from current position.
    @inline(__always)
    func peekByteAt(_ n: Int) -> UInt8 {
        let pos = bufPtr + n
        guard pos < bufLen else { return 0 }
        return buf[pos]
    }

    /// Read current byte and advance.
    @inline(__always)
    @discardableResult
    func readByte() -> UInt8 {
        guard bufPtr < bufLen else { return 0 }
        let b = buf[bufPtr]
        bufPtr += 1
        return b
    }

    /// True if we've reached end of source.
    @inline(__always)
    var atEnd: Bool { bufPtr >= bufLen }

    /// Decode a full Unicode code point from the UTF-8 stream at current position.
    /// Returns (codePoint, byteLength). Does NOT advance bufPtr.
    func decodeUTF8() -> (UInt32, Int) {
        guard bufPtr < bufLen else { return (0, 0) }
        let b0 = buf[bufPtr]
        if b0 < 0x80 {
            return (UInt32(b0), 1)
        }
        if b0 < 0xC0 {
            // Invalid continuation byte — treat as Latin-1.
            return (UInt32(b0), 1)
        }
        if b0 < 0xE0 {
            guard bufPtr + 1 < bufLen else { return (UInt32(b0), 1) }
            let b1 = buf[bufPtr + 1]
            let cp = (UInt32(b0 & 0x1F) << 6) | UInt32(b1 & 0x3F)
            return (cp, 2)
        }
        if b0 < 0xF0 {
            guard bufPtr + 2 < bufLen else { return (UInt32(b0), 1) }
            let b1 = buf[bufPtr + 1]
            let b2 = buf[bufPtr + 2]
            let cp = (UInt32(b0 & 0x0F) << 12) |
                     (UInt32(b1 & 0x3F) << 6) |
                      UInt32(b2 & 0x3F)
            return (cp, 3)
        }
        guard bufPtr + 3 < bufLen else { return (UInt32(b0), 1) }
        let b1 = buf[bufPtr + 1]
        let b2 = buf[bufPtr + 2]
        let b3 = buf[bufPtr + 3]
        let cp = (UInt32(b0 & 0x07) << 18) |
                 (UInt32(b1 & 0x3F) << 12) |
                 (UInt32(b2 & 0x3F) << 6) |
                  UInt32(b3 & 0x3F)
        return (cp, 4)
    }

    /// Decode a UTF-8 code point at an arbitrary offset.
    func decodeUTF8At(_ pos: Int) -> (UInt32, Int) {
        guard pos < bufLen else { return (0, 0) }
        let b0 = buf[pos]
        if b0 < 0x80 {
            return (UInt32(b0), 1)
        }
        if b0 < 0xC0 {
            return (UInt32(b0), 1)
        }
        if b0 < 0xE0 {
            guard pos + 1 < bufLen else { return (UInt32(b0), 1) }
            let b1 = buf[pos + 1]
            let cp = (UInt32(b0 & 0x1F) << 6) | UInt32(b1 & 0x3F)
            return (cp, 2)
        }
        if b0 < 0xF0 {
            guard pos + 2 < bufLen else { return (UInt32(b0), 1) }
            let b1 = buf[pos + 1]
            let b2 = buf[pos + 2]
            let cp = (UInt32(b0 & 0x0F) << 12) |
                     (UInt32(b1 & 0x3F) << 6) |
                      UInt32(b2 & 0x3F)
            return (cp, 3)
        }
        guard pos + 3 < bufLen else { return (UInt32(b0), 1) }
        let b1 = buf[pos + 1]
        let b2 = buf[pos + 2]
        let b3 = buf[pos + 3]
        let cp = (UInt32(b0 & 0x07) << 18) |
                 (UInt32(b1 & 0x3F) << 12) |
                 (UInt32(b2 & 0x3F) << 6) |
                  UInt32(b3 & 0x3F)
        return (cp, 4)
    }

    // MARK: - Encoding helpers

    /// Encode a Unicode code point to UTF-8 and append to a byte array.
    static func appendUTF8(_ cp: UInt32, to buf: inout [UInt8]) {
        if cp < 0x80 {
            buf.append(UInt8(cp))
        } else if cp < 0x800 {
            buf.append(UInt8(0xC0 | (cp >> 6)))
            buf.append(UInt8(0x80 | (cp & 0x3F)))
        } else if cp < 0x10000 {
            buf.append(UInt8(0xE0 | (cp >> 12)))
            buf.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
            buf.append(UInt8(0x80 | (cp & 0x3F)))
        } else {
            buf.append(UInt8(0xF0 | (cp >> 18)))
            buf.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
            buf.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
            buf.append(UInt8(0x80 | (cp & 0x3F)))
        }
    }
}

// MARK: - Error Reporting

extension JeffJSParseState {

    /// Extract the source line containing the given byte offset.
    /// Returns a source snippet around the error position and the adjusted caret column.
    /// For short lines, returns the full line. For long lines (e.g. minified JS),
    /// shows ~50 chars before and after the error position.
    private func getSourceSnippet(at offset: Int) -> (snippet: String, caretCol: Int)? {
        guard let line = getSourceLine(at: offset) else { return nil }
        let (_, col) = getLineCol(offset)

        // Short line — return as-is
        if line.count <= 120 {
            return (line, col)
        }

        // Long line — truncate around the error column
        let maxContext = 50
        let startIdx = max(0, col - 1 - maxContext)
        let endIdx = min(line.count, col - 1 + maxContext)

        let sIdx = line.index(line.startIndex, offsetBy: startIdx)
        let eIdx = line.index(line.startIndex, offsetBy: endIdx)
        let prefix = startIdx > 0 ? "..." : ""
        let suffix = endIdx < line.count ? "..." : ""
        let snippet = prefix + String(line[sIdx..<eIdx]) + suffix
        let caretCol = (col - 1 - startIdx) + prefix.count + 1
        return (snippet, caretCol)
    }

    private func getSourceLine(at offset: Int) -> String? {
        let clampedOffset = min(offset, bufLen)
        // Find start of line
        var start = clampedOffset
        while start > 0 && buf[start - 1] != 0x0A && buf[start - 1] != 0x0D {
            start -= 1
        }
        // Find end of line
        var end = clampedOffset
        while end < bufLen && buf[end] != 0x0A && buf[end] != 0x0D {
            end += 1
        }
        guard end > start else { return nil }
        return String(bytes: buf[start..<end], encoding: .utf8)
    }

    /// Global flag to suppress syntax error console output (e.g., during test262 runs).
    static var suppressErrorPrinting = JeffJSConfig.suppressErrorPrinting

    /// Report a syntax error at the current position.
    func syntaxError(_ msg: String) {
        let (line, col) = getLineCol(bufPtr)
        var full = "\(filename):\(line):\(col): \(msg)"
        if let (srcSnippet, caretCol) = getSourceSnippet(at: bufPtr) {
            full += "\n  \(srcSnippet)\n  \(String(repeating: " ", count: max(0, caretCol - 1)))^"
        }
        if lastErrorMessage == nil { lastErrorMessage = full }
        if !JeffJSParseState.suppressErrorPrinting { print("SyntaxError: \(full)") }
    }

    /// Report a syntax error at a specific offset.
    func syntaxErrorAt(_ offset: Int, _ msg: String) {
        let (line, col) = getLineCol(offset)
        var full = "\(filename):\(line):\(col): \(msg)"
        if let (srcSnippet, caretCol) = getSourceSnippet(at: offset) {
            full += "\n  \(srcSnippet)\n  \(String(repeating: " ", count: max(0, caretCol - 1)))^"
        }
        if lastErrorMessage == nil { lastErrorMessage = full }
        if !JeffJSParseState.suppressErrorPrinting { print("SyntaxError: \(full)") }
    }
}

// MARK: - Line / Column Tracking

extension JeffJSParseState {

    /// Compute 1-based line and column numbers for a byte offset.
    /// Scans from the beginning of the buffer each time.
    /// QuickJS uses a similar approach with `find_line_num`.
    func getLineCol(_ offset: Int) -> (line: Int, col: Int) {
        var line = 1
        var lineStart = 0
        let end = min(offset, bufLen)
        var i = 0
        while i < end {
            if buf[i] == 0x0A { // '\n'
                line += 1
                lineStart = i + 1
            } else if buf[i] == 0x0D { // '\r'
                line += 1
                if i + 1 < end && buf[i + 1] == 0x0A {
                    i += 1
                }
                lineStart = i + 1
            }
            i += 1
        }
        let col = offset - lineStart + 1
        return (line, col)
    }
}

// MARK: - Skip Whitespace and Comments

extension JeffJSParseState {

    /// Skip all whitespace and comments. Sets `gotLF` if a line terminator
    /// was encountered (needed for ASI). Returns false on unterminated block comment.
    @discardableResult
    func skipWhitespaceAndComments() -> Bool {
        gotLF = false

        while bufPtr < bufLen {
            let c = buf[bufPtr]

            switch c {
            case 0x20, 0x09, 0x0B, 0x0C: // space, tab, vertical tab, form feed
                bufPtr += 1

            case 0x0A: // \n
                bufPtr += 1
                lineNum += 1
                gotLF = true

            case 0x0D: // \r
                bufPtr += 1
                if bufPtr < bufLen && buf[bufPtr] == 0x0A {
                    bufPtr += 1
                }
                lineNum += 1
                gotLF = true

            case 0x2F: // '/'
                if bufPtr + 1 < bufLen {
                    let c2 = buf[bufPtr + 1]
                    if c2 == 0x2F { // '//' line comment
                        skipLineComment()
                        continue
                    }
                    if c2 == 0x2A { // '/*' block comment
                        if !skipBlockComment() {
                            return false
                        }
                        continue
                    }
                }
                return true

            case 0x3C: // '<' — check for HTML comment <!--
                if allowHTMLComments && !isModule &&
                   bufPtr + 3 < bufLen &&
                   buf[bufPtr + 1] == 0x21 && // !
                   buf[bufPtr + 2] == 0x2D && // -
                   buf[bufPtr + 3] == 0x2D    // -
                {
                    bufPtr += 4
                    skipLineComment()
                    continue
                }
                return true

            case 0x2D: // '-' — check for HTML comment -->
                // --> is only a comment start at the beginning of a line (after optional whitespace)
                if allowHTMLComments && !isModule && gotLF &&
                   bufPtr + 2 < bufLen &&
                   buf[bufPtr + 1] == 0x2D && // -
                   buf[bufPtr + 2] == 0x3E    // >
                {
                    bufPtr += 3
                    skipLineComment()
                    continue
                }
                return true

            case 0x23: // '#' — hashbang line at start of file
                if bufPtr == 0 && bufPtr + 1 < bufLen && buf[bufPtr + 1] == 0x21 {
                    bufPtr += 2
                    skipLineComment()
                    continue
                }
                return true

            default:
                // Check for Unicode whitespace (BOM, NBSP, etc.)
                if c >= 0x80 {
                    let (cp, len) = decodeUTF8()
                    if isUnicodeWhitespace(cp) {
                        bufPtr += len
                        continue
                    }
                    // Unicode line terminators: LS (0x2028), PS (0x2029)
                    if cp == 0x2028 || cp == 0x2029 {
                        bufPtr += len
                        lineNum += 1
                        gotLF = true
                        continue
                    }
                }
                return true
            }
        }
        return true
    }

    /// Skip to end of line (single-line comment). Does NOT consume the line terminator.
    func skipLineComment() {
        while bufPtr < bufLen {
            let c = buf[bufPtr]
            if c == 0x0A || c == 0x0D {
                return
            }
            if c >= 0x80 {
                let (cp, len) = decodeUTF8()
                if cp == 0x2028 || cp == 0x2029 {
                    return
                }
                bufPtr += len
            } else {
                bufPtr += 1
            }
        }
    }

    /// Skip a block comment (/* ... */). Returns false if unterminated.
    func skipBlockComment() -> Bool {
        bufPtr += 2  // skip '/*'
        while bufPtr < bufLen {
            let c = buf[bufPtr]
            if c == 0x2A { // '*'
                if bufPtr + 1 < bufLen && buf[bufPtr + 1] == 0x2F { // '/'
                    bufPtr += 2
                    return true
                }
                bufPtr += 1
            } else if c == 0x0A { // '\n'
                bufPtr += 1
                lineNum += 1
                gotLF = true
            } else if c == 0x0D { // '\r'
                bufPtr += 1
                if bufPtr < bufLen && buf[bufPtr] == 0x0A {
                    bufPtr += 1
                }
                lineNum += 1
                gotLF = true
            } else if c >= 0x80 {
                let (cp, len) = decodeUTF8()
                if cp == 0x2028 || cp == 0x2029 {
                    lineNum += 1
                    gotLF = true
                }
                bufPtr += len
            } else {
                bufPtr += 1
            }
        }
        syntaxError("unterminated block comment")
        return false
    }

    /// Check if a code point is Unicode whitespace (non-line-terminator).
    private func isUnicodeWhitespace(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x00A0, // NBSP
             0x1680, // Ogham Space Mark
             0x2000...0x200A, // En Quad through Hair Space
             0x202F, // Narrow No-Break Space
             0x205F, // Medium Mathematical Space
             0x3000, // Ideographic Space
             0xFEFF: // BOM / ZWNBSP
            return true
        default:
            return false
        }
    }
}

// MARK: - Parse Identifier

extension JeffJSParseState {

    /// Parse an identifier or keyword starting at `bufPtr`.
    /// The first character has already been validated as an identifier start.
    /// Returns the identifier string and whether it contained escape sequences.
    func parseIdent() -> (ident: String, hasEscape: Bool) {
        var identBuf = [UInt8]()
        var hasEscape = false

        while bufPtr < bufLen {
            let c = buf[bufPtr]

            if c == 0x5C { // backslash — unicode escape
                bufPtr += 1
                guard bufPtr < bufLen && buf[bufPtr] == 0x75 else { // 'u'
                    syntaxError("invalid escape in identifier")
                    return (String(bytes: identBuf, encoding: .utf8) ?? "", hasEscape)
                }
                bufPtr += 1
                hasEscape = true

                let cp = parseUnicodeEscape()
                guard cp != UInt32.max else {
                    syntaxError("invalid unicode escape in identifier")
                    return (String(bytes: identBuf, encoding: .utf8) ?? "", hasEscape)
                }
                // Validate that the code point is valid at this position
                if identBuf.isEmpty {
                    guard jeffJS_isIdentFirst(cp) else {
                        syntaxError("invalid identifier start character")
                        return ("", hasEscape)
                    }
                } else {
                    guard jeffJS_isIdentNext(cp) else {
                        syntaxError("invalid identifier character")
                        return (String(bytes: identBuf, encoding: .utf8) ?? "", hasEscape)
                    }
                }
                JeffJSParseState.appendUTF8(cp, to: &identBuf)

            } else if c < 0x80 {
                // ASCII fast path
                let cp = UInt32(c)
                if identBuf.isEmpty {
                    guard jeffJS_isIdentFirst(cp) else { break }
                } else {
                    guard jeffJS_isIdentNext(cp) else { break }
                }
                identBuf.append(c)
                bufPtr += 1

            } else {
                // Multi-byte UTF-8
                let (cp, len) = decodeUTF8()
                if identBuf.isEmpty {
                    guard jeffJS_isIdentFirst(cp) else { break }
                } else {
                    guard jeffJS_isIdentNext(cp) else { break }
                }
                for i in 0..<len {
                    identBuf.append(buf[bufPtr + i])
                }
                bufPtr += len
            }
        }

        let ident = String(bytes: identBuf, encoding: .utf8) ?? ""
        return (ident, hasEscape)
    }

    /// Parse a \uXXXX or \u{XXXXX} escape sequence. bufPtr should be positioned
    /// right after the 'u'. Returns the code point or UInt32.max on error.
    func parseUnicodeEscape() -> UInt32 {
        if bufPtr < bufLen && buf[bufPtr] == 0x7B { // '{'
            bufPtr += 1
            var val: UInt32 = 0
            var count = 0
            while bufPtr < bufLen && buf[bufPtr] != 0x7D { // '}'
                let digit = hexDigitValue(buf[bufPtr])
                guard digit != UInt32.max else { return UInt32.max }
                val = (val << 4) | digit
                if val > 0x10FFFF { return UInt32.max }
                bufPtr += 1
                count += 1
            }
            guard count > 0 && bufPtr < bufLen else { return UInt32.max }
            bufPtr += 1 // skip '}'
            return val
        } else {
            // Exactly 4 hex digits
            var val: UInt32 = 0
            for _ in 0..<4 {
                guard bufPtr < bufLen else { return UInt32.max }
                let digit = hexDigitValue(buf[bufPtr])
                guard digit != UInt32.max else { return UInt32.max }
                val = (val << 4) | digit
                bufPtr += 1
            }
            return val
        }
    }

    /// Return hex digit value (0-15) or UInt32.max for non-hex.
    @inline(__always)
    func hexDigitValue(_ c: UInt8) -> UInt32 {
        if c >= 0x30 && c <= 0x39 { return UInt32(c - 0x30) }      // 0-9
        if c >= 0x41 && c <= 0x46 { return UInt32(c - 0x41 + 10) }  // A-F
        if c >= 0x61 && c <= 0x66 { return UInt32(c - 0x61 + 10) }  // a-f
        return UInt32.max
    }

    /// Check if identifier is a keyword and update the token accordingly.
    /// Mirrors `update_token` / keyword detection in quickjs.c.
    func updateTokenIdent(_ ident: String, hasEscape: Bool) {
        // Look up in keyword table
        if let tokType = keywordDict[ident] {
            // If the keyword was written with unicode escapes, it is NOT a keyword —
            // it's an identifier that happens to spell a keyword.
            // Exception: in QuickJS, escaped keywords are syntax errors in strict mode.
            if hasEscape {
                token.type = JSTokenType.TOK_IDENT.rawValue
                token.identAtom = ctx?.findAtom(ident) ?? 0
                token.identHasEscape = true
                // Escaped keywords are reserved identifiers — parser may reject them.
                token.identIsReserved = true
                return
            }

            token.type = tokType
            return
        }

        // Not a keyword — it's a plain identifier
        token.type = JSTokenType.TOK_IDENT.rawValue
        token.identAtom = ctx?.findAtom(ident) ?? 0
        token.identHasEscape = hasEscape

        // Check strict-mode reserved words
        if isStrict && strictModeReservedWords.contains(ident) {
            token.identIsReserved = true
        } else {
            token.identIsReserved = false
        }
    }

    /// Whether the current parsing context is strict mode.
    var isStrict: Bool {
        if let f = curFunc { return f.isStrict }
        return isModule  // modules are implicitly strict
    }
}

// MARK: - Parse String

extension JeffJSParseState {

    /// Parse a string literal (single-quoted or double-quoted).
    /// `sep` is the opening quote character (0x22 for ", 0x27 for ').
    /// bufPtr should be positioned right after the opening quote.
    func parseString(_ sep: UInt8) -> Bool {
        var result = [UInt8]()
        token.strSeparator = Character(Unicode.Scalar(sep))

        while bufPtr < bufLen {
            let c = buf[bufPtr]

            if c == sep {
                bufPtr += 1 // consume closing quote
                token.strValue = String(bytes: result, encoding: .utf8) ?? ""
                token.type = JSTokenType.TOK_STRING.rawValue
                return true
            }

            if c == 0x5C { // backslash
                bufPtr += 1
                guard bufPtr < bufLen else {
                    syntaxError("unexpected end of string")
                    return false
                }
                let esc = buf[bufPtr]
                bufPtr += 1

                switch esc {
                case 0x6E: // 'n'
                    result.append(0x0A)
                case 0x72: // 'r'
                    result.append(0x0D)
                case 0x74: // 't'
                    result.append(0x09)
                case 0x62: // 'b'
                    result.append(0x08)
                case 0x66: // 'f'
                    result.append(0x0C)
                case 0x76: // 'v'
                    result.append(0x0B)
                case 0x30: // '0' — null or legacy octal
                    if bufPtr < bufLen && buf[bufPtr] >= 0x30 && buf[bufPtr] <= 0x39 {
                        // Legacy octal escape \0nn
                        if isStrict {
                            syntaxError("octal escape sequences are not allowed in strict mode")
                            return false
                        }
                        let val = parseLegacyOctalEscape(firstDigit: 0)
                        JeffJSParseState.appendUTF8(val, to: &result)
                    } else {
                        result.append(0x00) // \0 = NUL
                    }
                case 0x31...0x37: // '1'-'7' legacy octal
                    if isStrict {
                        syntaxError("octal escape sequences are not allowed in strict mode")
                        return false
                    }
                    let val = parseLegacyOctalEscape(firstDigit: UInt32(esc - 0x30))
                    JeffJSParseState.appendUTF8(val, to: &result)
                case 0x38, 0x39: // '8', '9' — invalid octal, but \8 and \9 are identity escapes
                    if isStrict {
                        syntaxError("\\8 and \\9 are not allowed in strict mode")
                        return false
                    }
                    result.append(esc)
                case 0x78: // 'x' — hex escape \xNN
                    guard bufPtr + 1 < bufLen else {
                        syntaxError("invalid hex escape")
                        return false
                    }
                    let d1 = hexDigitValue(buf[bufPtr])
                    let d2 = hexDigitValue(buf[bufPtr + 1])
                    guard d1 != UInt32.max && d2 != UInt32.max else {
                        syntaxError("invalid hex escape")
                        return false
                    }
                    bufPtr += 2
                    result.append(UInt8((d1 << 4) | d2))
                case 0x75: // 'u' — unicode escape
                    let cp = parseUnicodeEscape()
                    guard cp != UInt32.max && cp <= 0x10FFFF else {
                        syntaxError("invalid unicode escape in string")
                        return false
                    }
                    JeffJSParseState.appendUTF8(cp, to: &result)
                case 0x0A: // '\n' — line continuation
                    lineNum += 1
                case 0x0D: // '\r' — line continuation
                    if bufPtr < bufLen && buf[bufPtr] == 0x0A {
                        bufPtr += 1
                    }
                    lineNum += 1
                default:
                    // For line separators and paragraph separators
                    if esc >= 0x80 {
                        let savedPtr = bufPtr - 1
                        let (cp, len) = decodeUTF8At(savedPtr)
                        if cp == 0x2028 || cp == 0x2029 {
                            // Line continuation with Unicode line terminator
                            bufPtr = savedPtr + len
                            lineNum += 1
                        } else {
                            // Identity escape for other characters
                            bufPtr = savedPtr
                            let (cp2, len2) = decodeUTF8()
                            bufPtr += len2
                            JeffJSParseState.appendUTF8(cp2, to: &result)
                        }
                    } else {
                        // Identity escape: \c -> c for all other ASCII chars
                        result.append(esc)
                    }
                }

            } else if c == 0x0A || c == 0x0D {
                syntaxError("unterminated string literal")
                return false
            } else if c >= 0x80 {
                let (cp, len) = decodeUTF8()
                if cp == 0x2028 || cp == 0x2029 {
                    // ES2019: LS and PS are allowed in string literals
                    JeffJSParseState.appendUTF8(cp, to: &result)
                    bufPtr += len
                } else {
                    for i in 0..<len {
                        result.append(buf[bufPtr + i])
                    }
                    bufPtr += len
                }
            } else {
                result.append(c)
                bufPtr += 1
            }
        }

        syntaxError("unterminated string literal")
        return false
    }

    /// Parse a legacy octal escape sequence (\0nn, \1nn, etc.).
    /// `firstDigit` is the value of the first octal digit already consumed.
    func parseLegacyOctalEscape(firstDigit: UInt32) -> UInt32 {
        var val = firstDigit
        // Up to 2 more octal digits
        var maxDigits = firstDigit <= 3 ? 2 : 1
        while maxDigits > 0 && bufPtr < bufLen {
            let c = buf[bufPtr]
            guard c >= 0x30 && c <= 0x37 else { break } // '0'-'7'
            val = (val << 3) | UInt32(c - 0x30)
            bufPtr += 1
            maxDigits -= 1
        }
        return val
    }
}

// MARK: - Parse Template Literal

extension JeffJSParseState {

    /// Parse a template literal part. Called when bufPtr is positioned right after
    /// the opening backtick (`) or the closing `}` of an interpolation.
    /// Sets token to TOK_TEMPLATE.
    func parseTemplatePart(isTagged: Bool = false) -> Bool {
        var result = [UInt8]()
        token.type = JSTokenType.TOK_TEMPLATE.rawValue

        while bufPtr < bufLen {
            let c = buf[bufPtr]

            if c == 0x60 { // backtick — end of template
                bufPtr += 1
                token.strValue = String(bytes: result, encoding: .utf8) ?? ""
                return true
            }

            if c == 0x24 && bufPtr + 1 < bufLen && buf[bufPtr + 1] == 0x7B { // ${
                bufPtr += 2
                templateNestLevel += 1
                token.strValue = String(bytes: result, encoding: .utf8) ?? ""
                return true
            }

            if c == 0x5C { // backslash escape
                bufPtr += 1
                guard bufPtr < bufLen else {
                    syntaxError("unexpected end of template literal")
                    return false
                }

                if isTagged {
                    // In tagged templates, invalid escapes produce undefined cooked value.
                    // We still need to skip past them correctly.
                    let esc = buf[bufPtr]
                    bufPtr += 1
                    switch esc {
                    case 0x6E: result.append(0x0A)
                    case 0x72: result.append(0x0D)
                    case 0x74: result.append(0x09)
                    case 0x62: result.append(0x08)
                    case 0x66: result.append(0x0C)
                    case 0x76: result.append(0x0B)
                    case 0x30:
                        if bufPtr < bufLen && buf[bufPtr] >= 0x30 && buf[bufPtr] <= 0x39 {
                            // Skip octal — tagged template will get undefined cooked value
                            while bufPtr < bufLen && buf[bufPtr] >= 0x30 && buf[bufPtr] <= 0x37 {
                                bufPtr += 1
                            }
                        } else {
                            result.append(0x00)
                        }
                    case 0x78:
                        if bufPtr + 1 < bufLen {
                            let d1 = hexDigitValue(buf[bufPtr])
                            let d2 = hexDigitValue(buf[bufPtr + 1])
                            if d1 != UInt32.max && d2 != UInt32.max {
                                bufPtr += 2
                                result.append(UInt8((d1 << 4) | d2))
                            }
                        }
                    case 0x75:
                        let cp = parseUnicodeEscape()
                        if cp != UInt32.max && cp <= 0x10FFFF {
                            JeffJSParseState.appendUTF8(cp, to: &result)
                        }
                    case 0x0A:
                        lineNum += 1
                    case 0x0D:
                        if bufPtr < bufLen && buf[bufPtr] == 0x0A { bufPtr += 1 }
                        lineNum += 1
                    default:
                        result.append(esc)
                    }
                } else {
                    // Normal template — escapes must be valid
                    let esc = buf[bufPtr]
                    bufPtr += 1
                    switch esc {
                    case 0x6E: result.append(0x0A)
                    case 0x72: result.append(0x0D)
                    case 0x74: result.append(0x09)
                    case 0x62: result.append(0x08)
                    case 0x66: result.append(0x0C)
                    case 0x76: result.append(0x0B)
                    case 0x30:
                        if bufPtr < bufLen && buf[bufPtr] >= 0x30 && buf[bufPtr] <= 0x39 {
                            syntaxError("octal escape sequences are not allowed in template literals")
                            return false
                        }
                        result.append(0x00)
                    case 0x31...0x39:
                        syntaxError("octal escape sequences are not allowed in template literals")
                        return false
                    case 0x78: // \xNN
                        guard bufPtr + 1 < bufLen else {
                            syntaxError("invalid hex escape in template literal")
                            return false
                        }
                        let d1 = hexDigitValue(buf[bufPtr])
                        let d2 = hexDigitValue(buf[bufPtr + 1])
                        guard d1 != UInt32.max && d2 != UInt32.max else {
                            syntaxError("invalid hex escape in template literal")
                            return false
                        }
                        bufPtr += 2
                        result.append(UInt8((d1 << 4) | d2))
                    case 0x75: // \uNNNN or \u{N...}
                        let cp = parseUnicodeEscape()
                        guard cp != UInt32.max && cp <= 0x10FFFF else {
                            syntaxError("invalid unicode escape in template literal")
                            return false
                        }
                        JeffJSParseState.appendUTF8(cp, to: &result)
                    case 0x0A:
                        lineNum += 1
                    case 0x0D:
                        if bufPtr < bufLen && buf[bufPtr] == 0x0A { bufPtr += 1 }
                        lineNum += 1
                    case 0x60, 0x5C, 0x24: // ` \ $
                        result.append(esc)
                    default:
                        if esc >= 0x80 {
                            let savedPtr = bufPtr - 1
                            let (cp, len) = decodeUTF8At(savedPtr)
                            if cp == 0x2028 || cp == 0x2029 {
                                bufPtr = savedPtr + len
                                lineNum += 1
                            } else {
                                bufPtr = savedPtr
                                let (cp2, len2) = decodeUTF8()
                                bufPtr += len2
                                JeffJSParseState.appendUTF8(cp2, to: &result)
                            }
                        } else {
                            result.append(esc)
                        }
                    }
                }
            } else if c == 0x0A {
                result.append(0x0A)
                bufPtr += 1
                lineNum += 1
            } else if c == 0x0D {
                // Normalize \r\n to \n
                result.append(0x0A)
                bufPtr += 1
                if bufPtr < bufLen && buf[bufPtr] == 0x0A {
                    bufPtr += 1
                }
                lineNum += 1
            } else if c >= 0x80 {
                let (cp, len) = decodeUTF8()
                if cp == 0x2028 || cp == 0x2029 {
                    // These are line terminators — normalize to \n
                    result.append(0x0A)
                    lineNum += 1
                } else {
                    for i in 0..<len {
                        result.append(buf[bufPtr + i])
                    }
                }
                bufPtr += len
            } else {
                result.append(c)
                bufPtr += 1
            }
        }

        syntaxError("unterminated template literal")
        return false
    }
}

// MARK: - Parse Regular Expression

extension JeffJSParseState {

    /// Parse a regular expression literal. bufPtr is positioned right after
    /// the opening '/'. The token type is set to TOK_REGEXP.
    func parseRegexp() -> Bool {
        var body = [UInt8]()
        var inClass = false

        while bufPtr < bufLen {
            let c = buf[bufPtr]

            if c == 0x0A || c == 0x0D {
                syntaxError("unterminated regular expression")
                return false
            }

            if c >= 0x80 {
                let (cp, len) = decodeUTF8()
                if cp == 0x2028 || cp == 0x2029 {
                    syntaxError("unterminated regular expression")
                    return false
                }
                for i in 0..<len {
                    body.append(buf[bufPtr + i])
                }
                bufPtr += len
                continue
            }

            if c == 0x5C { // backslash
                body.append(c)
                bufPtr += 1
                guard bufPtr < bufLen else {
                    syntaxError("unterminated regular expression")
                    return false
                }
                let escaped = buf[bufPtr]
                if escaped == 0x0A || escaped == 0x0D {
                    syntaxError("unterminated regular expression")
                    return false
                }
                if escaped >= 0x80 {
                    let (_, len) = decodeUTF8()
                    for i in 0..<len {
                        body.append(buf[bufPtr + i])
                    }
                    bufPtr += len
                } else {
                    body.append(escaped)
                    bufPtr += 1
                }
                continue
            }

            if c == 0x2F && !inClass { // '/' ends the regex (unless in char class)
                bufPtr += 1
                break
            }

            if c == 0x5B { // '[' starts character class
                inClass = true
            } else if c == 0x5D && inClass { // ']' ends character class
                inClass = false
            }

            body.append(c)
            bufPtr += 1
        }

        // Parse flags
        var flags = [UInt8]()
        while bufPtr < bufLen {
            let c = buf[bufPtr]
            // Valid regexp flags: d, g, i, m, s, u, v, y
            if (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) {
                // Accept any letter as a flag — validation happens later
                if jeffJS_isIdentNext(UInt32(c)) {
                    flags.append(c)
                    bufPtr += 1
                } else {
                    break
                }
            } else if c == 0x5C { // unicode escape in flags
                break
            } else {
                break
            }
        }

        token.type = JSTokenType.TOK_REGEXP.rawValue
        token.regexpBody = String(bytes: body, encoding: .utf8) ?? ""
        token.regexpFlags = String(bytes: flags, encoding: .utf8) ?? ""
        return true
    }
}

// MARK: - Parse Number

extension JeffJSParseState {

    /// Parse a numeric literal. bufPtr is positioned at the first digit (or '.').
    /// Sets token to TOK_NUMBER.
    func parseNumber() -> Bool {
        let startPtr = bufPtr

        // Check for 0x, 0o, 0b, 0X, 0O, 0B prefixes
        if bufPtr < bufLen && buf[bufPtr] == 0x30 { // '0'
            if bufPtr + 1 < bufLen {
                let next = buf[bufPtr + 1]

                if next == 0x78 || next == 0x58 { // 'x' or 'X' — hex
                    bufPtr += 2
                    return parseHexNumber()
                }
                if next == 0x6F || next == 0x4F { // 'o' or 'O' — octal
                    bufPtr += 2
                    return parseOctalNumber()
                }
                if next == 0x62 || next == 0x42 { // 'b' or 'B' — binary
                    bufPtr += 2
                    return parseBinaryNumber()
                }

                // Legacy octal: 0[0-7]+
                if next >= 0x30 && next <= 0x37 { // '0'-'7'
                    if isStrict {
                        // In strict mode, legacy octals are not allowed, but
                        // 0-prefixed decimals like 09 are also not allowed.
                        // However, if we see 8 or 9, it's a decimal.
                        return parseLegacyOctalNumber()
                    }
                    return parseLegacyOctalNumber()
                }
            }
        }

        // Decimal number
        return parseDecimalNumber(startPtr: startPtr)
    }

    /// Parse a decimal number (integer or floating-point).
    private func parseDecimalNumber(startPtr: Int) -> Bool {
        // Integer part
        skipDecimalDigits()

        var isFloat = false

        // Fractional part
        if bufPtr < bufLen && buf[bufPtr] == 0x2E { // '.'
            // Check that the next char is not an identifier start (for 1.toString())
            if bufPtr + 1 < bufLen {
                let afterDot = buf[bufPtr + 1]
                if afterDot >= 0x30 && afterDot <= 0x39 {
                    // Definitely a decimal point
                    isFloat = true
                    bufPtr += 1
                    skipDecimalDigits()
                } else if afterDot == 0x2E { // '..' — e.g. 1..toString = (1.0).toString
                    // Consume the dot as part of the number (1. = 1.0),
                    // leaving the second dot for member access
                    isFloat = true
                    bufPtr += 1
                } else if jeffJS_isIdentFirst(UInt32(afterDot)) {
                    // member access like 1.toString — don't consume dot
                } else {
                    // e.g. 1. at end of input
                    isFloat = true
                    bufPtr += 1
                }
            } else {
                isFloat = true
                bufPtr += 1
            }
        }

        // Exponent part
        if bufPtr < bufLen && (buf[bufPtr] == 0x65 || buf[bufPtr] == 0x45) { // 'e' or 'E'
            isFloat = true
            bufPtr += 1
            if bufPtr < bufLen && (buf[bufPtr] == 0x2B || buf[bufPtr] == 0x2D) { // '+' or '-'
                bufPtr += 1
            }
            if bufPtr >= bufLen || !(buf[bufPtr] >= 0x30 && buf[bufPtr] <= 0x39) {
                syntaxError("missing exponent")
                return false
            }
            skipDecimalDigits()
        }

        // BigInt suffix 'n'
        if bufPtr < bufLen && buf[bufPtr] == 0x6E { // 'n'
            if isFloat {
                syntaxError("BigInt literal cannot have a decimal point or exponent")
                return false
            }
            bufPtr += 1
            // For now, parse BigInt as a regular number (full BigInt support comes later)
            let numStr = extractNumberString(startPtr, bufPtr - 1)
            token.numValue = Double(numStr) ?? 0
            token.type = JSTokenType.TOK_NUMBER.rawValue
            return true
        }

        // Check that the number is not immediately followed by an identifier char
        if bufPtr < bufLen {
            let (nextCP, _) = decodeUTF8()
            if jeffJS_isIdentFirst(nextCP) {
                syntaxError("identifier starts immediately after numeric literal")
                return false
            }
        }

        let numStr = extractNumberString(startPtr, bufPtr)
        token.numValue = Double(numStr) ?? 0
        token.type = JSTokenType.TOK_NUMBER.rawValue
        return true
    }

    /// Parse a hexadecimal number (after 0x prefix).
    private func parseHexNumber() -> Bool {
        let digitStart = bufPtr
        skipHexDigits()

        if bufPtr == digitStart {
            syntaxError("expected hex digit after 0x")
            return false
        }

        // BigInt suffix
        if bufPtr < bufLen && buf[bufPtr] == 0x6E { // 'n'
            bufPtr += 1
        }

        // Check no identifier follows
        if bufPtr < bufLen {
            let (nextCP, _) = decodeUTF8()
            if jeffJS_isIdentFirst(nextCP) {
                syntaxError("identifier starts immediately after numeric literal")
                return false
            }
        }

        let hexStr = extractNumberString(digitStart, bufPtr)
        let cleaned = hexStr.replacingOccurrences(of: "_", with: "")
        if let val = UInt64(cleaned, radix: 16) {
            token.numValue = Double(val)
        } else {
            // Very large hex — parse as Double via string
            token.numValue = Double("0x" + cleaned) ?? 0
        }
        token.type = JSTokenType.TOK_NUMBER.rawValue
        return true
    }

    /// Parse an octal number (after 0o prefix).
    private func parseOctalNumber() -> Bool {
        let digitStart = bufPtr
        while bufPtr < bufLen {
            let c = buf[bufPtr]
            if c >= 0x30 && c <= 0x37 { // '0'-'7'
                bufPtr += 1
            } else if c == 0x5F { // '_' numeric separator
                bufPtr += 1
            } else {
                break
            }
        }

        if bufPtr == digitStart {
            syntaxError("expected octal digit after 0o")
            return false
        }

        // BigInt suffix
        if bufPtr < bufLen && buf[bufPtr] == 0x6E { bufPtr += 1 }

        if bufPtr < bufLen {
            let (nextCP, _) = decodeUTF8()
            if jeffJS_isIdentFirst(nextCP) {
                syntaxError("identifier starts immediately after numeric literal")
                return false
            }
        }

        let octStr = extractNumberString(digitStart, bufPtr)
        let cleaned = octStr.replacingOccurrences(of: "_", with: "")
        if let val = UInt64(cleaned, radix: 8) {
            token.numValue = Double(val)
        } else {
            token.numValue = 0
        }
        token.type = JSTokenType.TOK_NUMBER.rawValue
        return true
    }

    /// Parse a binary number (after 0b prefix).
    private func parseBinaryNumber() -> Bool {
        let digitStart = bufPtr
        while bufPtr < bufLen {
            let c = buf[bufPtr]
            if c == 0x30 || c == 0x31 { // '0' or '1'
                bufPtr += 1
            } else if c == 0x5F { // '_' numeric separator
                bufPtr += 1
            } else {
                break
            }
        }

        if bufPtr == digitStart {
            syntaxError("expected binary digit after 0b")
            return false
        }

        // BigInt suffix
        if bufPtr < bufLen && buf[bufPtr] == 0x6E { bufPtr += 1 }

        if bufPtr < bufLen {
            let (nextCP, _) = decodeUTF8()
            if jeffJS_isIdentFirst(nextCP) {
                syntaxError("identifier starts immediately after numeric literal")
                return false
            }
        }

        let binStr = extractNumberString(digitStart, bufPtr)
        let cleaned = binStr.replacingOccurrences(of: "_", with: "")
        if let val = UInt64(cleaned, radix: 2) {
            token.numValue = Double(val)
        } else {
            token.numValue = 0
        }
        token.type = JSTokenType.TOK_NUMBER.rawValue
        return true
    }

    /// Parse a legacy octal number (0-prefixed, e.g. 0777).
    private func parseLegacyOctalNumber() -> Bool {
        let startPtr = bufPtr
        bufPtr += 1 // skip the leading '0'
        var isDecimal = false

        while bufPtr < bufLen {
            let c = buf[bufPtr]
            if c >= 0x30 && c <= 0x37 { // '0'-'7'
                bufPtr += 1
            } else if c == 0x38 || c == 0x39 { // '8' or '9' — not valid octal, switch to decimal
                isDecimal = true
                bufPtr += 1
            } else if c == 0x2E || c == 0x65 || c == 0x45 { // '.', 'e', 'E'
                isDecimal = true
                break
            } else {
                break
            }
        }

        if isDecimal {
            // Re-parse as decimal from the beginning
            bufPtr = startPtr
            return parseDecimalNumber(startPtr: startPtr)
        }

        // Check strict mode
        if isStrict {
            syntaxError("legacy octal literals are not allowed in strict mode")
            return false
        }

        let octStr = extractNumberString(startPtr + 1, bufPtr) // skip leading 0
        let cleaned = octStr.replacingOccurrences(of: "_", with: "")
        if let val = UInt64(cleaned, radix: 8) {
            token.numValue = Double(val)
        } else {
            token.numValue = 0
        }
        token.type = JSTokenType.TOK_NUMBER.rawValue
        return true
    }

    /// Skip decimal digits (0-9) and numeric separators (_).
    private func skipDecimalDigits() {
        var lastWasSep = true // prevent leading separator
        while bufPtr < bufLen {
            let c = buf[bufPtr]
            if c >= 0x30 && c <= 0x39 {
                bufPtr += 1
                lastWasSep = false
            } else if c == 0x5F { // '_'
                if lastWasSep {
                    syntaxError("numeric separator cannot be adjacent to another separator or at start")
                    return
                }
                bufPtr += 1
                lastWasSep = true
            } else {
                break
            }
        }
    }

    /// Skip hex digits (0-9, a-f, A-F) and numeric separators (_).
    private func skipHexDigits() {
        while bufPtr < bufLen {
            let c = buf[bufPtr]
            if (c >= 0x30 && c <= 0x39) ||
               (c >= 0x41 && c <= 0x46) ||
               (c >= 0x61 && c <= 0x66) ||
               c == 0x5F {
                bufPtr += 1
            } else {
                break
            }
        }
    }

    /// Extract a substring from the source buffer as a String.
    private func extractNumberString(_ start: Int, _ end: Int) -> String {
        guard start < end && end <= bufLen else { return "0" }
        return String(bytes: buf[start..<end], encoding: .utf8) ?? "0"
    }
}

// MARK: - Main Tokenizer: nextToken()

extension JeffJSParseState {

    /// The main tokenizer entry point.
    /// Reads the next token from the source buffer, updates `self.token`.
    /// Returns `true` on success, `false` on error.
    ///
    /// This corresponds to `next_token()` in quickjs.c — a big switch on the
    /// first character after whitespace.
    @discardableResult
    func nextToken() -> Bool {
        lastTokenType = token.type
        lastPtr = bufPtr
        lastLineNum = lineNum
        token.reset()

        // Skip whitespace and comments
        if !skipWhitespaceAndComments() {
            return false
        }

        token.ptr = bufPtr
        token.line = lineNum

        // Check for EOF
        guard bufPtr < bufLen else {
            token.type = JSTokenType.TOK_EOF.rawValue
            return true
        }

        let c = buf[bufPtr]

        // Big switch on first character — mirrors the QuickJS next_token() structure
        switch c {

        // MARK: Digits
        case 0x30...0x39: // '0'-'9'
            return parseNumber()

        // MARK: String literals
        case 0x22, 0x27: // '"' or '\''
            bufPtr += 1
            return parseString(c)

        // MARK: Template literal
        case 0x60: // '`'
            bufPtr += 1
            return parseTemplatePart()

        // MARK: Identifiers and keywords
        case 0x41...0x5A, 0x61...0x7A, 0x24, 0x5F: // A-Z, a-z, $, _
            let (ident, hasEscape) = parseIdent()
            updateTokenIdent(ident, hasEscape: hasEscape)
            return true

        case 0x5C: // backslash — could be unicode-escaped identifier
            if bufPtr + 1 < bufLen && buf[bufPtr + 1] == 0x75 { // \u
                let (ident, hasEscape) = parseIdent()
                if ident.isEmpty {
                    syntaxError("invalid identifier")
                    return false
                }
                updateTokenIdent(ident, hasEscape: hasEscape)
                return true
            }
            syntaxError("unexpected character '\\'")
            return false

        // MARK: Dot or number starting with dot
        case 0x2E: // '.'
            if bufPtr + 1 < bufLen && buf[bufPtr + 1] >= 0x30 && buf[bufPtr + 1] <= 0x39 {
                // Number starting with '.'
                return parseNumber()
            }
            if bufPtr + 2 < bufLen && buf[bufPtr + 1] == 0x2E && buf[bufPtr + 2] == 0x2E { // ...
                bufPtr += 3
                token.type = JSTokenType.TOK_ELLIPSIS.rawValue
                return true
            }
            bufPtr += 1
            token.type = Int(c)  // single '.'
            return true

        // MARK: Semicolon, comma, colon, parentheses, brackets, braces, tilde, at
        case 0x3B, 0x2C, 0x40: // ';' ',' '@'
            bufPtr += 1
            token.type = Int(c)
            return true

        case 0x3A: // ':'
            bufPtr += 1
            token.type = Int(c)
            return true

        case 0x28: // '('
            bufPtr += 1
            token.type = Int(c)
            return true

        case 0x29: // ')'
            bufPtr += 1
            token.type = Int(c)
            return true

        case 0x5B: // '['
            bufPtr += 1
            token.type = Int(c)
            return true

        case 0x5D: // ']'
            bufPtr += 1
            token.type = Int(c)
            return true

        case 0x7B: // '{'
            bufPtr += 1
            token.type = Int(c)
            return true

        case 0x7D: // '}'
            // Check if this closes a template expression
            if templateNestLevel > 0 {
                bufPtr += 1 // skip the '}'
                templateNestLevel -= 1
                return parseTemplatePart()
            }
            bufPtr += 1
            token.type = Int(c)
            return true

        case 0x7E: // '~'
            bufPtr += 1
            token.type = Int(c)
            return true

        // MARK: Plus
        case 0x2B: // '+'
            bufPtr += 1
            if bufPtr < bufLen {
                if buf[bufPtr] == 0x2B { // '++'
                    bufPtr += 1
                    token.type = JSTokenType.TOK_INC.rawValue
                    return true
                }
                if buf[bufPtr] == 0x3D { // '+='
                    bufPtr += 1
                    token.type = JSTokenType.TOK_ADD_ASSIGN.rawValue
                    return true
                }
            }
            token.type = Int(c) // '+'
            return true

        // MARK: Minus
        case 0x2D: // '-'
            bufPtr += 1
            if bufPtr < bufLen {
                if buf[bufPtr] == 0x2D { // '--'
                    bufPtr += 1
                    token.type = JSTokenType.TOK_DEC.rawValue
                    return true
                }
                if buf[bufPtr] == 0x3D { // '-='
                    bufPtr += 1
                    token.type = JSTokenType.TOK_SUB_ASSIGN.rawValue
                    return true
                }
            }
            token.type = Int(c) // '-'
            return true

        // MARK: Star
        case 0x2A: // '*'
            bufPtr += 1
            if bufPtr < bufLen {
                if buf[bufPtr] == 0x2A { // '**'
                    bufPtr += 1
                    if bufPtr < bufLen && buf[bufPtr] == 0x3D { // '**='
                        bufPtr += 1
                        token.type = JSTokenType.TOK_POW_ASSIGN.rawValue
                        return true
                    }
                    token.type = JSTokenType.TOK_POW.rawValue
                    return true
                }
                if buf[bufPtr] == 0x3D { // '*='
                    bufPtr += 1
                    token.type = JSTokenType.TOK_MUL_ASSIGN.rawValue
                    return true
                }
            }
            token.type = Int(c) // '*'
            return true

        // MARK: Slash (division, regex, or comment — comments already handled)
        case 0x2F: // '/'
            // Regex vs division disambiguation based on previous token.
            // After tokens that end an expression, '/' is division.
            // After anything else (operators, keywords, punctuation), '/' starts a regex.
            if slashIsDivision() {
                bufPtr += 1
                if bufPtr < bufLen {
                    if buf[bufPtr] == 0x3D { // '/='
                        bufPtr += 1
                        token.type = JSTokenType.TOK_DIV_ASSIGN.rawValue
                        return true
                    }
                }
                token.type = Int(c) // '/' as division
                return true
            } else {
                // '/' starts a regex literal — parse it directly
                bufPtr += 1
                return parseRegexp()
            }

        // MARK: Percent
        case 0x25: // '%'
            bufPtr += 1
            if bufPtr < bufLen && buf[bufPtr] == 0x3D { // '%='
                bufPtr += 1
                token.type = JSTokenType.TOK_MOD_ASSIGN.rawValue
                return true
            }
            token.type = Int(c)
            return true

        // MARK: Less-than
        case 0x3C: // '<'
            bufPtr += 1
            if bufPtr < bufLen {
                if buf[bufPtr] == 0x3C { // '<<'
                    bufPtr += 1
                    if bufPtr < bufLen && buf[bufPtr] == 0x3D { // '<<='
                        bufPtr += 1
                        token.type = JSTokenType.TOK_SHL_ASSIGN.rawValue
                        return true
                    }
                    token.type = JSTokenType.TOK_SHL.rawValue
                    return true
                }
                if buf[bufPtr] == 0x3D { // '<='
                    bufPtr += 1
                    token.type = JSTokenType.TOK_LE.rawValue
                    return true
                }
            }
            token.type = Int(c) // '<'
            return true

        // MARK: Greater-than
        case 0x3E: // '>'
            bufPtr += 1
            if bufPtr < bufLen {
                if buf[bufPtr] == 0x3E { // '>>'
                    bufPtr += 1
                    if bufPtr < bufLen {
                        if buf[bufPtr] == 0x3E { // '>>>'
                            bufPtr += 1
                            if bufPtr < bufLen && buf[bufPtr] == 0x3D { // '>>>='
                                bufPtr += 1
                                token.type = JSTokenType.TOK_SHR_ASSIGN.rawValue
                                return true
                            }
                            token.type = JSTokenType.TOK_SHR.rawValue
                            return true
                        }
                        if buf[bufPtr] == 0x3D { // '>>='
                            bufPtr += 1
                            token.type = JSTokenType.TOK_SAR_ASSIGN.rawValue
                            return true
                        }
                    }
                    token.type = JSTokenType.TOK_SAR.rawValue
                    return true
                }
                if buf[bufPtr] == 0x3D { // '>='
                    bufPtr += 1
                    token.type = JSTokenType.TOK_GE.rawValue
                    return true
                }
            }
            token.type = Int(c) // '>'
            return true

        // MARK: Equals
        case 0x3D: // '='
            bufPtr += 1
            if bufPtr < bufLen {
                if buf[bufPtr] == 0x3D { // '=='
                    bufPtr += 1
                    if bufPtr < bufLen && buf[bufPtr] == 0x3D { // '==='
                        bufPtr += 1
                        token.type = JSTokenType.TOK_STRICT_EQ.rawValue
                        return true
                    }
                    token.type = JSTokenType.TOK_EQ.rawValue
                    return true
                }
                if buf[bufPtr] == 0x3E { // '=>'
                    bufPtr += 1
                    token.type = JSTokenType.TOK_ARROW.rawValue
                    return true
                }
            }
            token.type = Int(c) // '='
            return true

        // MARK: Exclamation mark (not, !=, !==)
        case 0x21: // '!'
            bufPtr += 1
            if bufPtr < bufLen && buf[bufPtr] == 0x3D { // '!='
                bufPtr += 1
                if bufPtr < bufLen && buf[bufPtr] == 0x3D { // '!=='
                    bufPtr += 1
                    token.type = JSTokenType.TOK_STRICT_NEQ.rawValue
                    return true
                }
                token.type = JSTokenType.TOK_NEQ.rawValue
                return true
            }
            token.type = Int(c) // '!'
            return true

        // MARK: Ampersand
        case 0x26: // '&'
            bufPtr += 1
            if bufPtr < bufLen {
                if buf[bufPtr] == 0x26 { // '&&'
                    bufPtr += 1
                    if bufPtr < bufLen && buf[bufPtr] == 0x3D { // '&&='
                        bufPtr += 1
                        token.type = JSTokenType.TOK_LAND_ASSIGN.rawValue
                        return true
                    }
                    token.type = JSTokenType.TOK_LAND.rawValue
                    return true
                }
                if buf[bufPtr] == 0x3D { // '&='
                    bufPtr += 1
                    token.type = JSTokenType.TOK_AND_ASSIGN.rawValue
                    return true
                }
            }
            token.type = Int(c) // '&'
            return true

        // MARK: Pipe
        case 0x7C: // '|'
            bufPtr += 1
            if bufPtr < bufLen {
                if buf[bufPtr] == 0x7C { // '||'
                    bufPtr += 1
                    if bufPtr < bufLen && buf[bufPtr] == 0x3D { // '||='
                        bufPtr += 1
                        token.type = JSTokenType.TOK_LOR_ASSIGN.rawValue
                        return true
                    }
                    token.type = JSTokenType.TOK_LOR.rawValue
                    return true
                }
                if buf[bufPtr] == 0x3D { // '|='
                    bufPtr += 1
                    token.type = JSTokenType.TOK_OR_ASSIGN.rawValue
                    return true
                }
            }
            token.type = Int(c) // '|'
            return true

        // MARK: Caret
        case 0x5E: // '^'
            bufPtr += 1
            if bufPtr < bufLen && buf[bufPtr] == 0x3D { // '^='
                bufPtr += 1
                token.type = JSTokenType.TOK_XOR_ASSIGN.rawValue
                return true
            }
            token.type = Int(c) // '^'
            return true

        // MARK: Question mark
        case 0x3F: // '?'
            bufPtr += 1
            if bufPtr < bufLen {
                if buf[bufPtr] == 0x3F { // '??'
                    bufPtr += 1
                    if bufPtr < bufLen && buf[bufPtr] == 0x3D { // '??='
                        bufPtr += 1
                        token.type = JSTokenType.TOK_DOUBLE_QUESTION_MARK_ASSIGN.rawValue
                        return true
                    }
                    token.type = JSTokenType.TOK_DOUBLE_QUESTION_MARK.rawValue
                    return true
                }
                if buf[bufPtr] == 0x2E { // '?.'
                    // Only if the char after '.' is NOT a digit (to distinguish from ?. and ?.5)
                    if bufPtr + 1 >= bufLen || !(buf[bufPtr + 1] >= 0x30 && buf[bufPtr + 1] <= 0x39) {
                        bufPtr += 1
                        token.type = JSTokenType.TOK_OPTIONAL_CHAIN.rawValue
                        return true
                    }
                }
            }
            token.type = Int(c) // '?'
            return true

        // MARK: Hash (private name)
        case 0x23: // '#'
            bufPtr += 1
            if bufPtr < bufLen {
                let (cp, _) = decodeUTF8()
                if jeffJS_isIdentFirst(cp) {
                    let (ident, hasEscape) = parseIdent()
                    token.type = JSTokenType.TOK_PRIVATE_NAME.rawValue
                    token.strValue = ident
                    token.identHasEscape = hasEscape
                    token.identAtom = ctx?.findAtom(ident) ?? 0
                    return true
                }
            }
            // Standalone '#' — error in most contexts but the parser handles it
            token.type = Int(c)
            return true

        default:
            // Check for Unicode identifier starts
            if c >= 0x80 {
                let (cp, _) = decodeUTF8()
                if jeffJS_isIdentFirst(cp) {
                    let (ident, hasEscape) = parseIdent()
                    updateTokenIdent(ident, hasEscape: hasEscape)
                    return true
                }
                // Unicode whitespace was already handled — this is an error
                syntaxError("unexpected character U+\(String(format: "%04X", cp))")
                return false
            }

            syntaxError("unexpected character '\(Character(Unicode.Scalar(c)))'")
            return false
        }
    }
}

// MARK: - Regex / Division Disambiguation

extension JeffJSParseState {

    /// Returns true if '/' should be treated as division (not regex).
    /// Division follows tokens that can end an expression:
    ///   ), ], identifier, number, string, template, ++, --, this, true, false, null, }
    /// Everything else (operators, keywords, punctuation, SOF) means '/' starts a regex.
    func slashIsDivision() -> Bool {
        switch lastTokenType {
        // Closing brackets/parens — expression just ended
        case 0x29, // ')'
             0x5D: // ']'
            return true
        // '}' is ambiguous (could end a block statement or an object literal).
        // Treat as division (end of expression) — matches V8/SpiderMonkey behavior.
        case 0x7D: // '}'
            return true
        // Literals and identifiers — expression just ended
        case JSTokenType.TOK_NUMBER.rawValue,
             JSTokenType.TOK_STRING.rawValue,
             JSTokenType.TOK_IDENT.rawValue,
             JSTokenType.TOK_REGEXP.rawValue,
             JSTokenType.TOK_TEMPLATE.rawValue:
            return true
        // Keywords that are expression values
        case JSTokenType.TOK_THIS.rawValue,
             JSTokenType.TOK_TRUE.rawValue,
             JSTokenType.TOK_FALSE.rawValue,
             JSTokenType.TOK_NULL.rawValue:
            return true
        // Postfix operators — expression just ended
        case JSTokenType.TOK_INC.rawValue,
             JSTokenType.TOK_DEC.rawValue:
            return true
        // Everything else: operators, assignment, keywords (return, case, typeof, etc.),
        // open brackets, comma, semicolon, colon, SOF (0) → '/' is regex
        default:
            return false
        }
    }
}

// MARK: - Regex Re-tokenization

extension JeffJSParseState {

    /// Re-lex the current '/' token as the start of a regular expression.
    /// This is called by the parser when it determines that '/' is a regex,
    /// not division. The token must currently be '/' (0x2F) or '/=' (TOK_DIV_ASSIGN).
    ///
    /// Mirrors `js_parse_regexp` in quickjs.c.
    @discardableResult
    func reParseAsRegexp() -> Bool {
        // Back up to the '/' character
        if token.type == JSTokenType.TOK_DIV_ASSIGN.rawValue {
            // '/=' was two characters; back up to after the '/'
            bufPtr = token.ptr + 1
        } else {
            // '/' was one character
            bufPtr = token.ptr + 1
        }
        return parseRegexp()
    }
}

// MARK: - Simple / Lightweight Lookahead

extension JeffJSParseState {

    /// Lightweight lookahead that tokenizes the next token without updating the
    /// parse state. Returns the token type.
    /// Mirrors `simple_next_token` in quickjs.c.
    func simpleNextToken() -> Int {
        let savedBufPtr = bufPtr
        let savedLineNum = lineNum
        let savedToken = token
        let savedGotLF = gotLF
        let savedLastPtr = lastPtr
        let savedLastLineNum = lastLineNum
        let savedTemplateNestLevel = templateNestLevel
        let savedLastTokenType = lastTokenType

        let ok = nextToken()

        let resultType = ok ? token.type : JSTokenType.TOK_EOF.rawValue

        // Restore state
        bufPtr = savedBufPtr
        lineNum = savedLineNum
        token = savedToken
        gotLF = savedGotLF
        lastPtr = savedLastPtr
        lastLineNum = savedLastLineNum
        templateNestLevel = savedTemplateNestLevel
        lastTokenType = savedLastTokenType

        return resultType
    }

    /// Peek at the next token without consuming. Returns the token struct.
    /// Saves and restores all tokenizer state.
    func peekToken() -> JeffJSToken {
        let savedBufPtr = bufPtr
        let savedLineNum = lineNum
        let savedToken = token
        let savedGotLF = gotLF
        let savedLastPtr = lastPtr
        let savedLastLineNum = lastLineNum
        let savedTemplateNestLevel = templateNestLevel
        let savedLastTokenType = lastTokenType

        _ = nextToken()
        let result = token

        // Restore state
        bufPtr = savedBufPtr
        lineNum = savedLineNum
        token = savedToken
        gotLF = savedGotLF
        lastPtr = savedLastPtr
        lastLineNum = savedLastLineNum
        templateNestLevel = savedTemplateNestLevel
        lastTokenType = savedLastTokenType

        return result
    }
}

// MARK: - Token Expectations

extension JeffJSParseState {

    /// Expect the current token to have the given type. If it does not, report
    /// an error and return false. On success, advance to the next token.
    @discardableResult
    func expectToken(_ type: Int) -> Bool {
        if token.type != type {
            let expected = tokenTypeName(type)
            let got = tokenTypeName(token.type)
            syntaxError("expected \(expected), got \(got)")
            return false
        }
        return nextToken()
    }

    /// Expect a semicolon, applying automatic semicolon insertion (ASI) rules.
    /// Returns true if a semicolon was found or inserted.
    ///
    /// ASI rules (ECMA-262 11.9):
    /// 1. When the parser encounters a token that is not allowed by the grammar,
    ///    and there is a line terminator before it, a semicolon is automatically inserted.
    /// 2. When a '}' token is encountered.
    /// 3. At the end of the source text.
    @discardableResult
    func expectSemicolon() -> Bool {
        if token.type == Int(UInt8(ascii: ";")) {
            return nextToken()
        }

        // ASI: insert semicolon if:
        // - there was a line feed before the current token
        // - current token is '}'
        // - we're at EOF
        if gotLF || token.type == Int(UInt8(ascii: "}")) ||
           token.type == JSTokenType.TOK_EOF.rawValue {
            return true // semicolon inserted
        }

        syntaxError("expected ';'")
        return false
    }

    /// Return a human-readable name for a token type.
    func tokenTypeName(_ type: Int) -> String {
        // Single-character tokens
        if type > 0 && type < 128 {
            return "'\(Character(Unicode.Scalar(UInt8(type))))'"
        }

        // Multi-char tokens and keywords
        if let tokType = JSTokenType(rawValue: type) {
            switch tokType {
            case .TOK_NUMBER: return "number"
            case .TOK_STRING: return "string"
            case .TOK_TEMPLATE: return "template"
            case .TOK_IDENT: return "identifier"
            case .TOK_REGEXP: return "regexp"
            case .TOK_EOF: return "end of input"
            case .TOK_PRIVATE_NAME: return "private name"
            case .TOK_DIV_ASSIGN: return "'/='"
            case .TOK_LINE_NUM: return "line number"
            case .TOK_SHL_ASSIGN: return "'<<='"
            case .TOK_SAR_ASSIGN: return "'>>='"
            case .TOK_SHR_ASSIGN: return "'>>>='"
            case .TOK_MUL_ASSIGN: return "'*='"
            case .TOK_MOD_ASSIGN: return "'%='"
            case .TOK_POW_ASSIGN: return "'**='"
            case .TOK_ADD_ASSIGN: return "'+='"
            case .TOK_SUB_ASSIGN: return "'-='"
            case .TOK_AND_ASSIGN: return "'&='"
            case .TOK_OR_ASSIGN: return "'|='"
            case .TOK_XOR_ASSIGN: return "'^='"
            case .TOK_LAND_ASSIGN: return "'&&='"
            case .TOK_LOR_ASSIGN: return "'||='"
            case .TOK_DOUBLE_QUESTION_MARK_ASSIGN: return "'??='"
            case .TOK_SHL: return "'<<'"
            case .TOK_SAR: return "'>>'"
            case .TOK_SHR: return "'>>>'"
            case .TOK_POW: return "'**'"
            case .TOK_LAND: return "'&&'"
            case .TOK_LOR: return "'||'"
            case .TOK_INC: return "'++'"
            case .TOK_DEC: return "'--'"
            case .TOK_EQ: return "'=='"
            case .TOK_NEQ: return "'!='"
            case .TOK_STRICT_EQ: return "'==='"
            case .TOK_STRICT_NEQ: return "'!=='"
            case .TOK_LE: return "'<='"
            case .TOK_GE: return "'>='"
            case .TOK_ARROW: return "'=>'"
            case .TOK_ELLIPSIS: return "'...'"
            case .TOK_DOUBLE_QUESTION_MARK: return "'??'"
            case .TOK_OPTIONAL_CHAIN: return "'?.'"
            case .TOK_NULL: return "'null'"
            case .TOK_FALSE: return "'false'"
            case .TOK_TRUE: return "'true'"
            case .TOK_IF: return "'if'"
            case .TOK_ELSE: return "'else'"
            case .TOK_RETURN: return "'return'"
            case .TOK_VAR: return "'var'"
            case .TOK_THIS: return "'this'"
            case .TOK_DELETE: return "'delete'"
            case .TOK_VOID: return "'void'"
            case .TOK_TYPEOF: return "'typeof'"
            case .TOK_NEW: return "'new'"
            case .TOK_IN: return "'in'"
            case .TOK_INSTANCEOF: return "'instanceof'"
            case .TOK_DO: return "'do'"
            case .TOK_WHILE: return "'while'"
            case .TOK_FOR: return "'for'"
            case .TOK_BREAK: return "'break'"
            case .TOK_CONTINUE: return "'continue'"
            case .TOK_SWITCH: return "'switch'"
            case .TOK_CASE: return "'case'"
            case .TOK_DEFAULT: return "'default'"
            case .TOK_THROW: return "'throw'"
            case .TOK_TRY: return "'try'"
            case .TOK_CATCH: return "'catch'"
            case .TOK_FINALLY: return "'finally'"
            case .TOK_FUNCTION: return "'function'"
            case .TOK_DEBUGGER: return "'debugger'"
            case .TOK_WITH: return "'with'"
            case .TOK_CLASS: return "'class'"
            case .TOK_CONST: return "'const'"
            case .TOK_ENUM: return "'enum'"
            case .TOK_EXPORT: return "'export'"
            case .TOK_EXTENDS: return "'extends'"
            case .TOK_IMPORT: return "'import'"
            case .TOK_SUPER: return "'super'"
            case .TOK_IMPLEMENTS: return "'implements'"
            case .TOK_INTERFACE: return "'interface'"
            case .TOK_LET: return "'let'"
            case .TOK_PACKAGE: return "'package'"
            case .TOK_PRIVATE: return "'private'"
            case .TOK_PROTECTED: return "'protected'"
            case .TOK_PUBLIC: return "'public'"
            case .TOK_STATIC: return "'static'"
            case .TOK_YIELD: return "'yield'"
            case .TOK_AWAIT: return "'await'"
            case .TOK_OF: return "'of'"
            case .TOK_ACCESSOR: return "'accessor'"
            }
        }

        return "token(\(type))"
    }
}

// MARK: - JSON Tokenizer

extension JeffJSParseState {

    /// Separate JSON tokenizer with ext_json support.
    /// Mirrors `json_next_token` in quickjs.c.
    ///
    /// Extended JSON supports:
    /// - Single-line (//) and block (/* */) comments
    /// - Single-quoted strings
    /// - Unquoted property names (identifiers)
    /// - Trailing commas
    /// - +Infinity, -Infinity, NaN
    @discardableResult
    func jsonNextToken() -> Bool {
        lastPtr = bufPtr
        lastLineNum = lineNum
        token.reset()

        // Skip whitespace (and comments in ext_json mode)
        if extJSON {
            if !skipWhitespaceAndComments() {
                return false
            }
        } else {
            // Standard JSON: only skip basic whitespace
            jsonSkipWhitespace()
        }

        token.ptr = bufPtr
        token.line = lineNum

        guard bufPtr < bufLen else {
            token.type = JSTokenType.TOK_EOF.rawValue
            return true
        }

        let c = buf[bufPtr]

        switch c {
        case 0x22: // '"' — JSON string
            bufPtr += 1
            return jsonParseString(0x22)

        case 0x27: // '\'' — single-quoted string (ext_json only)
            if extJSON {
                bufPtr += 1
                return jsonParseString(0x27)
            }
            syntaxError("unexpected character in JSON")
            return false

        case 0x30...0x39: // '0'-'9'
            return jsonParseNumber()

        case 0x2D: // '-'
            return jsonParseNumber()

        case 0x7B, 0x7D, 0x5B, 0x5D, 0x2C, 0x3A: // { } [ ] , :
            bufPtr += 1
            token.type = Int(c)
            return true

        case 0x74: // 't' — true
            if matchLiteral("true") {
                token.type = JSTokenType.TOK_TRUE.rawValue
                return true
            }
            if extJSON { return jsonParseIdentifier() }
            syntaxError("unexpected token in JSON")
            return false

        case 0x66: // 'f' — false
            if matchLiteral("false") {
                token.type = JSTokenType.TOK_FALSE.rawValue
                return true
            }
            if extJSON { return jsonParseIdentifier() }
            syntaxError("unexpected token in JSON")
            return false

        case 0x6E: // 'n' — null
            if matchLiteral("null") {
                token.type = JSTokenType.TOK_NULL.rawValue
                return true
            }
            if extJSON { return jsonParseIdentifier() }
            syntaxError("unexpected token in JSON")
            return false

        case 0x2B: // '+' — +Infinity (ext_json only)
            if extJSON {
                if matchLiteral("+Infinity") {
                    token.type = JSTokenType.TOK_NUMBER.rawValue
                    token.numValue = Double.infinity
                    return true
                }
            }
            syntaxError("unexpected character in JSON")
            return false

        case 0x4E: // 'N' — NaN (ext_json only)
            if extJSON && matchLiteral("NaN") {
                token.type = JSTokenType.TOK_NUMBER.rawValue
                token.numValue = Double.nan
                return true
            }
            if extJSON { return jsonParseIdentifier() }
            syntaxError("unexpected token in JSON")
            return false

        case 0x49: // 'I' — Infinity (ext_json only)
            if extJSON && matchLiteral("Infinity") {
                token.type = JSTokenType.TOK_NUMBER.rawValue
                token.numValue = Double.infinity
                return true
            }
            if extJSON { return jsonParseIdentifier() }
            syntaxError("unexpected token in JSON")
            return false

        default:
            // ext_json: unquoted identifier for property names
            if extJSON {
                if c >= 0x80 {
                    let (cp, _) = decodeUTF8()
                    if jeffJS_isIdentFirst(cp) {
                        return jsonParseIdentifier()
                    }
                } else if jeffJS_isIdentFirst(UInt32(c)) {
                    return jsonParseIdentifier()
                }
            }
            syntaxError("unexpected character in JSON")
            return false
        }
    }

    /// Skip basic JSON whitespace (space, tab, CR, LF).
    private func jsonSkipWhitespace() {
        while bufPtr < bufLen {
            let c = buf[bufPtr]
            if c == 0x20 || c == 0x09 { // space, tab
                bufPtr += 1
            } else if c == 0x0A { // \n
                bufPtr += 1
                lineNum += 1
            } else if c == 0x0D { // \r
                bufPtr += 1
                if bufPtr < bufLen && buf[bufPtr] == 0x0A { bufPtr += 1 }
                lineNum += 1
            } else {
                break
            }
        }
    }

    /// Parse a JSON string literal (double-quoted or single-quoted for ext_json).
    private func jsonParseString(_ sep: UInt8) -> Bool {
        var result = [UInt8]()

        while bufPtr < bufLen {
            let c = buf[bufPtr]

            if c == sep {
                bufPtr += 1
                token.type = JSTokenType.TOK_STRING.rawValue
                token.strValue = String(bytes: result, encoding: .utf8) ?? ""
                return true
            }

            if c == 0x5C { // backslash
                bufPtr += 1
                guard bufPtr < bufLen else {
                    syntaxError("unexpected end of JSON string")
                    return false
                }
                let esc = buf[bufPtr]
                bufPtr += 1

                switch esc {
                case 0x22: result.append(0x22) // \"
                case 0x5C: result.append(0x5C) // \\
                case 0x2F: result.append(0x2F) // \/
                case 0x62: result.append(0x08) // \b
                case 0x66: result.append(0x0C) // \f
                case 0x6E: result.append(0x0A) // \n
                case 0x72: result.append(0x0D) // \r
                case 0x74: result.append(0x09) // \t
                case 0x27: // \' (ext_json only)
                    if extJSON {
                        result.append(0x27)
                    } else {
                        syntaxError("invalid escape in JSON string")
                        return false
                    }
                case 0x75: // \uXXXX
                    var val: UInt32 = 0
                    for _ in 0..<4 {
                        guard bufPtr < bufLen else {
                            syntaxError("invalid unicode escape in JSON string")
                            return false
                        }
                        let d = hexDigitValue(buf[bufPtr])
                        guard d != UInt32.max else {
                            syntaxError("invalid unicode escape in JSON string")
                            return false
                        }
                        val = (val << 4) | d
                        bufPtr += 1
                    }
                    // Handle surrogate pairs
                    if val >= 0xD800 && val <= 0xDBFF {
                        // High surrogate — expect \uDCxx low surrogate
                        if bufPtr + 5 < bufLen &&
                           buf[bufPtr] == 0x5C && buf[bufPtr + 1] == 0x75 {
                            bufPtr += 2
                            var low: UInt32 = 0
                            for _ in 0..<4 {
                                let d = hexDigitValue(buf[bufPtr])
                                guard d != UInt32.max else {
                                    syntaxError("invalid unicode escape in JSON string")
                                    return false
                                }
                                low = (low << 4) | d
                                bufPtr += 1
                            }
                            if low >= 0xDC00 && low <= 0xDFFF {
                                let cp = 0x10000 + ((val - 0xD800) << 10) + (low - 0xDC00)
                                JeffJSParseState.appendUTF8(cp, to: &result)
                            } else {
                                // Invalid surrogate pair — emit replacement character
                                JeffJSParseState.appendUTF8(0xFFFD, to: &result)
                                JeffJSParseState.appendUTF8(low, to: &result)
                            }
                        } else {
                            JeffJSParseState.appendUTF8(0xFFFD, to: &result)
                        }
                    } else {
                        JeffJSParseState.appendUTF8(val, to: &result)
                    }
                case 0x0A: // line continuation (ext_json)
                    if extJSON { lineNum += 1 }
                    else {
                        syntaxError("invalid escape in JSON string")
                        return false
                    }
                case 0x0D: // line continuation (ext_json)
                    if extJSON {
                        if bufPtr < bufLen && buf[bufPtr] == 0x0A { bufPtr += 1 }
                        lineNum += 1
                    } else {
                        syntaxError("invalid escape in JSON string")
                        return false
                    }
                default:
                    if extJSON {
                        // ext_json allows identity escapes
                        result.append(esc)
                    } else {
                        syntaxError("invalid escape in JSON string")
                        return false
                    }
                }
            } else if c < 0x20 {
                // Control characters are not allowed in JSON strings
                syntaxError("invalid character in JSON string")
                return false
            } else if c >= 0x80 {
                let (_, len) = decodeUTF8()
                for i in 0..<len {
                    result.append(buf[bufPtr + i])
                }
                bufPtr += len
            } else {
                result.append(c)
                bufPtr += 1
            }
        }

        syntaxError("unterminated JSON string")
        return false
    }

    /// Parse a JSON number.
    private func jsonParseNumber() -> Bool {
        let startPtr = bufPtr

        // Optional minus
        if bufPtr < bufLen && buf[bufPtr] == 0x2D {
            bufPtr += 1
        }

        guard bufPtr < bufLen else {
            syntaxError("unexpected end of JSON number")
            return false
        }

        // Check for -Infinity (ext_json)
        if extJSON && bufPtr < bufLen && buf[bufPtr] == 0x49 { // 'I'
            if matchLiteral("Infinity") {
                token.type = JSTokenType.TOK_NUMBER.rawValue
                token.numValue = buf[startPtr] == 0x2D ? -Double.infinity : Double.infinity
                return true
            }
        }

        // Integer part
        let c = buf[bufPtr]
        if c == 0x30 { // '0'
            bufPtr += 1
            // In ext_json, allow 0x hex prefix
            if extJSON && bufPtr < bufLen && (buf[bufPtr] == 0x78 || buf[bufPtr] == 0x58) {
                bufPtr += 1
                let hexStart = bufPtr
                skipHexDigits()
                if bufPtr == hexStart {
                    syntaxError("expected hex digit")
                    return false
                }
                let hexStr = extractNumberString(hexStart, bufPtr)
                    .replacingOccurrences(of: "_", with: "")
                if let val = UInt64(hexStr, radix: 16) {
                    token.numValue = buf[startPtr] == 0x2D ? -Double(val) : Double(val)
                } else {
                    token.numValue = 0
                }
                token.type = JSTokenType.TOK_NUMBER.rawValue
                return true
            }
        } else if c >= 0x31 && c <= 0x39 { // '1'-'9'
            bufPtr += 1
            while bufPtr < bufLen && buf[bufPtr] >= 0x30 && buf[bufPtr] <= 0x39 {
                bufPtr += 1
            }
        } else {
            syntaxError("unexpected character in JSON number")
            return false
        }

        // Fractional part
        if bufPtr < bufLen && buf[bufPtr] == 0x2E {
            bufPtr += 1
            if bufPtr >= bufLen || !(buf[bufPtr] >= 0x30 && buf[bufPtr] <= 0x39) {
                syntaxError("expected digit after decimal point in JSON number")
                return false
            }
            while bufPtr < bufLen && buf[bufPtr] >= 0x30 && buf[bufPtr] <= 0x39 {
                bufPtr += 1
            }
        }

        // Exponent
        if bufPtr < bufLen && (buf[bufPtr] == 0x65 || buf[bufPtr] == 0x45) {
            bufPtr += 1
            if bufPtr < bufLen && (buf[bufPtr] == 0x2B || buf[bufPtr] == 0x2D) {
                bufPtr += 1
            }
            if bufPtr >= bufLen || !(buf[bufPtr] >= 0x30 && buf[bufPtr] <= 0x39) {
                syntaxError("expected digit in JSON number exponent")
                return false
            }
            while bufPtr < bufLen && buf[bufPtr] >= 0x30 && buf[bufPtr] <= 0x39 {
                bufPtr += 1
            }
        }

        let numStr = extractNumberString(startPtr, bufPtr)
        token.numValue = Double(numStr) ?? 0
        token.type = JSTokenType.TOK_NUMBER.rawValue
        return true
    }

    /// Parse an unquoted identifier for ext_json property names.
    private func jsonParseIdentifier() -> Bool {
        let (ident, hasEscape) = parseIdent()
        if ident.isEmpty {
            syntaxError("expected identifier in JSON")
            return false
        }
        token.type = JSTokenType.TOK_IDENT.rawValue
        token.strValue = ident
        token.identHasEscape = hasEscape
        token.identAtom = ctx?.findAtom(ident) ?? 0
        return true
    }

    /// Try to match a literal string at the current position.
    /// On success, advance bufPtr past the literal and return true.
    /// The literal must not be followed by an identifier character.
    private func matchLiteral(_ literal: String) -> Bool {
        let bytes = Array(literal.utf8)
        guard bufPtr + bytes.count <= bufLen else { return false }
        for i in 0..<bytes.count {
            if buf[bufPtr + i] != bytes[i] { return false }
        }
        // Check that the literal is not followed by an identifier character
        let endPos = bufPtr + bytes.count
        if endPos < bufLen {
            let (nextCP, _) = decodeUTF8At(endPos)
            if jeffJS_isIdentNext(nextCP) { return false }
        }
        bufPtr += bytes.count
        return true
    }
}

// MARK: - Module Detection

extension JeffJSParseState {

    /// Heuristic to detect whether source code is an ES module.
    /// Scans for top-level `import` or `export` statements.
    /// Mirrors `JS_DetectModule` in quickjs.c.
    static func detectModule(source: String) -> Bool {
        let state = JeffJSParseState(source: source, filename: "<detect>", isModule: false)
        while state.nextToken() {
            let t = state.token.type
            if t == JSTokenType.TOK_EOF.rawValue { break }

            // import declaration (not import())
            if t == JSTokenType.TOK_IMPORT.rawValue {
                let next = state.simpleNextToken()
                // import.meta, import() are not module-only
                if next == Int(UInt8(ascii: ".")) || next == Int(UInt8(ascii: "(")) {
                    continue
                }
                return true
            }

            // export declaration
            if t == JSTokenType.TOK_EXPORT.rawValue {
                return true
            }
        }
        return false
    }
}

// MARK: - Token Type Helpers

/// Returns true if the token type is an assignment operator.
/// Mirrors the QuickJS check: tok >= TOK_MUL_ASSIGN && tok <= TOK_DOUBLE_QUESTION_MARK_ASSIGN
func jeffJS_isAssignmentOp(_ tokType: Int) -> Bool {
    return tokType >= JSTokenType.TOK_SHL_ASSIGN.rawValue &&
           tokType <= JSTokenType.TOK_DOUBLE_QUESTION_MARK_ASSIGN.rawValue
}

/// Returns true if the token is a keyword.
func jeffJS_isKeyword(_ tokType: Int) -> Bool {
    return tokType >= JSTokenType.TOK_NULL.rawValue &&
           tokType <= JSTokenType.TOK_ACCESSOR.rawValue
}

/// Returns true if the token could start an expression.
/// Used by the parser for ASI and other decisions.
func jeffJS_canStartExpr(_ tokType: Int) -> Bool {
    // Identifiers, literals, keywords that start expressions, unary operators
    if tokType == JSTokenType.TOK_IDENT.rawValue ||
       tokType == JSTokenType.TOK_NUMBER.rawValue ||
       tokType == JSTokenType.TOK_STRING.rawValue ||
       tokType == JSTokenType.TOK_TEMPLATE.rawValue ||
       tokType == JSTokenType.TOK_REGEXP.rawValue ||
       tokType == JSTokenType.TOK_PRIVATE_NAME.rawValue {
        return true
    }

    // Keywords that can start expressions
    if tokType == JSTokenType.TOK_THIS.rawValue ||
       tokType == JSTokenType.TOK_NULL.rawValue ||
       tokType == JSTokenType.TOK_TRUE.rawValue ||
       tokType == JSTokenType.TOK_FALSE.rawValue ||
       tokType == JSTokenType.TOK_FUNCTION.rawValue ||
       tokType == JSTokenType.TOK_CLASS.rawValue ||
       tokType == JSTokenType.TOK_NEW.rawValue ||
       tokType == JSTokenType.TOK_DELETE.rawValue ||
       tokType == JSTokenType.TOK_VOID.rawValue ||
       tokType == JSTokenType.TOK_TYPEOF.rawValue ||
       tokType == JSTokenType.TOK_YIELD.rawValue ||
       tokType == JSTokenType.TOK_AWAIT.rawValue ||
       tokType == JSTokenType.TOK_SUPER.rawValue ||
       tokType == JSTokenType.TOK_IMPORT.rawValue {
        return true
    }

    // Unary / prefix operators
    let asciiUnary: [UInt8] = [
        0x28, // (
        0x5B, // [
        0x7B, // {
        0x21, // !
        0x7E, // ~
        0x2B, // +
        0x2D, // -
        0x2F, // / (could be regex)
    ]
    for ch in asciiUnary {
        if tokType == Int(ch) { return true }
    }

    if tokType == JSTokenType.TOK_INC.rawValue ||
       tokType == JSTokenType.TOK_DEC.rawValue {
        return true
    }

    return false
}

// MARK: - Default Context Implementation

/// A minimal tokenizer context that uses a simple dictionary for atoms.
/// Used for standalone tokenization without a full JeffJSContext.
final class JeffJSSimpleTokenizerContext: JeffJSTokenizerContext {
    private var atoms: [String: UInt32] = [:]
    private var nextAtomID: UInt32 = 1

    func findAtom(_ name: String) -> UInt32 {
        if let existing = atoms[name] {
            return existing
        }
        let id = nextAtomID
        nextAtomID += 1
        atoms[name] = id
        return id
    }
}

// MARK: - Convenience Initializer

extension JeffJSParseState {

    /// Create a parse state for standalone tokenization.
    /// The context is owned by the parse state (strong reference via `ownedCtx`).
    convenience init(source: String, filename: String = "<input>", isModule: Bool = false) {
        let ctx = JeffJSSimpleTokenizerContext()
        self.init(source: source, filename: filename, ctx: ctx)
        self.ownedCtx = ctx  // keep the context alive
        self.isModule = isModule
        self.allowHTMLComments = !isModule
    }
}
