// JeffJSUnminifier.swift
// JeffJS — a JavaScript pretty-printer ("unminifier") on the engine's own tokenizer.
//
// The parser compiles straight to bytecode (no AST), so the formatter is a
// token-stream printer: the engine tokenizer (`JeffJSParseState.nextToken`)
// lexes every token — strings, numbers with separators, regex literals,
// template literals, private names, Unicode escapes — and two passes lay
// them out:
//
//   1. lex + structure: a bracket stack decides regex-vs-division and where a
//      template substitution ends (the formatter, not the tokenizer, owns
//      that state), and gives every token a role: block / object literal /
//      class body / switch body brace, call / control / for-header / parameter
//      paren, index / array bracket, ternary / property / case / label colon,
//      unary / binary / postfix operator, generator star, property-key position.
//   2. emit: every token's source bytes are copied verbatim (so literals never
//      change), only the whitespace between tokens is rewritten: blocks and
//      long object / array / argument lists break onto indented lines, long
//      `.then().catch()` chains break before the `.`, long expressions break
//      after `&&` / `||` / `,` and around `?` / `:`.
//
// Semantics are preserved by construction: only inter-token whitespace
// changes, and a newline is never inserted where it changes meaning (after
// `return` / `throw` / `break` / `continue` / `yield` / `async`, before a
// postfix `++` / `--` or `=>`, before a call / index / tagged-template
// continuation, inside a `for (;;)` header), and a newline of the original
// that automatic semicolon insertion may depend on is always kept. The test
// suite checks that the output tokenizes to the same token sequence.
//
// The result carries a position map both ways (original byte offset <->
// formatted byte offset; line:column helpers in the engine's convention:
// 1-based lines split at \n, \r, \r\n, 1-based UTF-8 byte columns — what
// `Error.stack` frames report), and the formatted extent of every braced
// function body (for "copy the enclosing function").
//
// Copyright 2026 Jeff Bachand. All rights reserved.

import Foundation

// MARK: - Public API

/// Formatting options.
nonisolated public struct JeffJSUnminifyOptions: Sendable {
    /// Spaces per indentation level.
    public var indentWidth: Int
    /// Soft line length: object / array / argument lists longer than this
    /// break one element per line, call chains break before `.`, long
    /// expressions break after `&&` / `||` / `,` and around `? :`.
    public var maxLineLength: Int
    /// Every N formatted lines, end the line with `// <orig line:col>` (the
    /// original position of the line's first token). 0 = off (default).
    public var positionCommentEvery: Int
    /// Keep the source's comments (license headers, `/*#__PURE__*/`, ...).
    public var keepComments: Bool

    public init(indentWidth: Int = 2, maxLineLength: Int = 100,
                positionCommentEvery: Int = 0, keepComments: Bool = true) {
        self.indentWidth = max(0, min(indentWidth, 16))
        self.maxLineLength = max(20, maxLineLength)
        self.positionCommentEvery = max(0, positionCommentEvery)
        self.keepComments = keepComments
    }
}

/// A formatted excerpt around one position.
nonisolated public struct JeffJSUnminifiedExcerpt: Sendable {
    /// Formatted line number (1-based) of `lines[0]`.
    public let firstLine: Int
    public let lines: [String]
    /// Formatted line (1-based) and UTF-8 column (1-based) of the position.
    public let targetLine: Int
    public let targetColumn: Int
    /// The original position asked for.
    public let originalLine: Int
    public let originalColumn: Int
}

/// Output of `JeffJSUnminifier.format`.
nonisolated public struct JeffJSUnminified: Sendable {
    /// The formatted source.
    public let text: String
    /// False when the source did not tokenize: `text` is then the source
    /// unchanged and the map is the identity.
    public let ok: Bool
    public let error: String?
    /// Significant (non-comment) tokens.
    public let tokenCount: Int
    public let originalByteCount: Int

    // Position map: runs of tokens whose (formatted - original) offset delta
    // is constant. `runOrig` / `runOut` are both increasing.
    let runOrig: [UInt32]
    let runOut: [UInt32]
    let origLineStarts: [UInt32]
    let outLineStarts: [UInt32]
    // Braced function bodies: formatted [start, end) byte ranges (start = the
    // function's head: `function` / `async` / the arrow's parameters / the
    // method key), parent index (-1 = top level), sorted by start.
    let fnStart: [UInt32]
    let fnEnd: [UInt32]
    let fnParent: [Int32]

    /// Bytes held by the result (text + map + line tables + function table).
    public var memoryFootprint: Int {
        text.utf8.count + 4 * (runOrig.count + runOut.count + origLineStarts.count
                               + outLineStarts.count + fnStart.count + fnEnd.count + fnParent.count)
    }

    public var formattedLineCount: Int { outLineStarts.count }
    public var originalLineCount: Int { origLineStarts.count }
    public var functionCount: Int { fnStart.count }

    // MARK: offsets

    /// Formatted byte offset of an original byte offset. A position inside a
    /// token maps to the same byte of that token; one in whitespace the
    /// formatter rewrote maps to the next token.
    public func formattedOffset(originalOffset o: Int) -> Int {
        guard !runOrig.isEmpty else { return o }
        let k = Self.lastIndex(runOrig, notAbove: o)
        if k < 0 { return Int(runOut[0]) }
        return max(0, Int(runOut[k]) + (o - Int(runOrig[k])))
    }

    /// Original byte offset of a formatted byte offset (inverse of
    /// `formattedOffset` on token bytes; inserted whitespace maps forward).
    public func originalOffset(formattedOffset f: Int) -> Int {
        guard !runOut.isEmpty else { return f }
        let k = Self.lastIndex(runOut, notAbove: f)
        if k < 0 { return Int(runOrig[0]) }
        var o = Int(runOrig[k]) + (f - Int(runOut[k]))
        if k + 1 < runOrig.count { o = min(o, Int(runOrig[k + 1])) }
        return max(0, min(o, originalByteCount))
    }

    // MARK: line:column (1-based lines, 1-based UTF-8 byte columns)

    /// Formatted line:column of an original line:column.
    public func formattedPosition(line: Int, column: Int) -> (line: Int, column: Int)? {
        guard let o = Self.offset(line: line, column: column, starts: origLineStarts, limit: originalByteCount) else { return nil }
        return Self.lineColumn(formattedOffset(originalOffset: o), starts: outLineStarts)
    }

    /// Original line:column of a formatted line:column.
    public func originalPosition(line: Int, column: Int) -> (line: Int, column: Int)? {
        guard let f = Self.offset(line: line, column: column, starts: outLineStarts, limit: text.utf8.count) else { return nil }
        return Self.lineColumn(originalOffset(formattedOffset: f), starts: origLineStarts)
    }

    /// One formatted line (1-based), without its terminator.
    public func formattedLine(_ n: Int) -> String? {
        guard n >= 1, n <= outLineStarts.count else { return nil }
        let a = Int(outLineStarts[n - 1])
        var b = n < outLineStarts.count ? Int(outLineStarts[n]) : text.utf8.count
        return text.utf8.withContiguousStorageIfAvailable { u -> String in
            while b > a, u[b - 1] == 0x0A || u[b - 1] == 0x0D { b -= 1 }
            return String(decoding: UnsafeBufferPointer(rebasing: u[a ..< b]), as: UTF8.self)
        } ?? ""
    }

    /// The formatted lines around an original position: `context` lines
    /// before and after the line the position lands on.
    public func excerpt(originalLine: Int, column: Int, context: Int = 6) -> JeffJSUnminifiedExcerpt? {
        guard let (l, c) = formattedPosition(line: originalLine, column: column) else { return nil }
        let first = max(1, l - max(0, context))
        let last = min(outLineStarts.count, l + max(0, context))
        var lines: [String] = []
        lines.reserveCapacity(last - first + 1)
        for n in first ... last { lines.append(formattedLine(n) ?? "") }
        return JeffJSUnminifiedExcerpt(firstLine: first, lines: lines, targetLine: l, targetColumn: c,
                                       originalLine: originalLine, originalColumn: column)
    }

    /// The formatted text of the innermost braced function (declaration,
    /// expression, method, or arrow with a block body) enclosing an original
    /// position, dedented, with its first formatted line. nil at top level.
    /// (An arrow with an expression body has no braces: its enclosing braced
    /// function is returned.)
    public func enclosingFunction(originalLine: Int, column: Int) -> (text: String, firstLine: Int)? {
        guard let o = Self.offset(line: originalLine, column: column, starts: origLineStarts, limit: originalByteCount) else { return nil }
        let f = formattedOffset(originalOffset: o)
        var k = Self.lastIndex(fnStart, notAbove: f)
        while k >= 0, Int(fnEnd[k]) <= f { k = Int(fnParent[k]) }
        guard k >= 0 else { return nil }
        let a = Int(fnStart[k]), b = Int(fnEnd[k])
        guard let (line, _) = Self.lineColumn(a, starts: outLineStarts) else { return nil }
        let lineStart = Int(outLineStarts[line - 1])
        let raw: String = text.utf8.withContiguousStorageIfAvailable { u in
            String(decoding: UnsafeBufferPointer(rebasing: u[lineStart ..< b]), as: UTF8.self)
        } ?? ""
        // Dedent by the head line's indentation (continuation lines of the
        // function share it; template literal lines may not, and are kept).
        let indent = raw.utf8.prefix(while: { $0 == 0x20 }).count
        let head = String(raw.dropFirst(indent).prefix(while: { _ in true }))
        guard indent > 0 else { return (head, line) }
        let pad = String(repeating: " ", count: indent)
        var lines = head.components(separatedBy: "\n")
        for i in 1 ..< lines.count where lines[i].hasPrefix(pad) { lines[i].removeFirst(indent) }
        return (lines.joined(separator: "\n"), line)
    }

    /// `Error.stack` text with every `url:line:col` whose URL `isThisScript`
    /// accepts rewritten to the formatted position (`url:line:col` stays the
    /// frame's text, ` -> formatted line:col` is appended, and with
    /// `showLine` the formatted line follows, indented).
    public func rewriteStack(_ stack: String, showLine: Bool = true, isThisScript: (String) -> Bool) -> String {
        var out: [String] = []
        for frameLine in stack.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(frameLine)
            guard let loc = JeffJSStackLocation.parse(s), isThisScript(loc.url),
                  let (l, c) = formattedPosition(line: loc.line, column: loc.column) else {
                out.append(s); continue
            }
            out.append(s + "  -> unminified \(l):\(c)")
            if showLine, let text = formattedLine(l) {
                out.append("      " + text.trimmingCharacters(in: .whitespaces))
            }
        }
        return out.joined(separator: "\n")
    }

    /// The map's runs as (original offset, formatted offset) pairs: from
    /// each pair on, bytes map with a constant delta up to the next pair.
    public func mapRuns() -> [(original: Int, formatted: Int)] {
        (0 ..< runOrig.count).map { (Int(runOrig[$0]), Int(runOut[$0])) }
    }

    /// Line:column of a byte offset in the original / formatted text.
    public func originalLineColumn(offset: Int) -> (line: Int, column: Int)? {
        Self.lineColumn(offset, starts: origLineStarts)
    }
    public func formattedLineColumn(offset: Int) -> (line: Int, column: Int)? {
        Self.lineColumn(offset, starts: outLineStarts)
    }

    // MARK: helpers

    /// Index of the last element <= v (-1 if none). `a` is increasing.
    static func lastIndex(_ a: [UInt32], notAbove v: Int) -> Int {
        var lo = 0, hi = a.count - 1, best = -1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            if Int(a[mid]) <= v { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best
    }

    static func offset(line: Int, column: Int, starts: [UInt32], limit: Int) -> Int? {
        guard line >= 1, line <= starts.count else { return nil }
        let o = Int(starts[line - 1]) + max(0, column - 1)
        return min(o, limit)
    }

    static func lineColumn(_ offset: Int, starts: [UInt32]) -> (line: Int, column: Int)? {
        let k = lastIndex(starts, notAbove: offset)
        guard k >= 0 else { return nil }
        return (k + 1, offset - Int(starts[k]) + 1)
    }
}

/// A `url:line:col` location as `Error.stack` frames (`fn@url:line:col`),
/// JSC's console prefix (`[url:line:col]`) and V8 frames (`at f (url:l:c)`)
/// print it.
nonisolated public struct JeffJSStackLocation: Sendable, Equatable {
    public let url: String
    public let line: Int
    public let column: Int

    public init(url: String, line: Int, column: Int) {
        self.url = url; self.line = line; self.column = column
    }

    /// The first `url:line:col` in `text` (URL = a scheme://… or an absolute
    /// path), or nil.
    public static func parse(_ text: String) -> JeffJSStackLocation? {
        return all(in: text, limit: 1).first
    }

    /// Every `url:line:col` in `text`, in order (at most `limit`).
    public static func all(in text: String, limit: Int = .max) -> [JeffJSStackLocation] {
        var found: [JeffJSStackLocation] = []
        let u = Array(text.utf8)
        let n = u.count
        var i = 0
        @inline(__always) func isStop(_ c: UInt8) -> Bool {
            c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x5B || c == 0x5D
                || c == 0x28 || c == 0x29 || c == 0x22 || c == 0x27 || c == 0x40 || c == 0x3C || c == 0x3E
        }
        while i < n, found.count < limit {
            // A URL start: "xyz://" or "/" at a token start.
            var start = -1
            if u[i] == 0x3A, i + 2 < n, u[i + 1] == 0x2F, u[i + 2] == 0x2F {
                var s = i
                while s > 0, (u[s - 1] >= 0x61 && u[s - 1] <= 0x7A) || (u[s - 1] >= 0x41 && u[s - 1] <= 0x5A)
                        || (u[s - 1] >= 0x30 && u[s - 1] <= 0x39) || u[s - 1] == 0x2B || u[s - 1] == 0x2D || u[s - 1] == 0x2E { s -= 1 }
                if s < i { start = s }
            } else if u[i] == 0x2F, i == 0 || isStop(u[i - 1]), i + 1 < n, u[i + 1] != 0x2F {
                start = i
            }
            if start < 0 { i += 1; continue }
            var e = i
            while e < n, !isStop(u[e]) { e += 1 }
            // Trailing ":line:col" (allow a trailing ':' / ',' / '.' after it).
            var end = e
            while end > start, u[end - 1] == 0x3A || u[end - 1] == 0x2C || u[end - 1] == 0x2E { end -= 1 }
            func trailingNumber(_ to: Int) -> (value: Int, from: Int)? {
                var k = to, v = 0, mul = 1
                while k > start, u[k - 1] >= 0x30, u[k - 1] <= 0x39, mul <= 1_000_000_000 {
                    v += Int(u[k - 1] - 0x30) * mul; mul *= 10; k -= 1
                }
                guard k < to, k > start, u[k - 1] == 0x3A else { return nil }
                return (v, k - 1)
            }
            if let col = trailingNumber(end), let line = trailingNumber(col.from), line.from > start {
                let url = String(decoding: u[start ..< line.from], as: UTF8.self)
                found.append(JeffJSStackLocation(url: url, line: line.value, column: col.value))
            }
            i = max(e, i + 1)
        }
        return found
    }
}

nonisolated public enum JeffJSUnminifier {

    /// Format `source`. Never fails: a source that does not tokenize comes
    /// back unchanged (`ok == false`, identity map).
    public static func format(_ source: String, options: JeffJSUnminifyOptions = JeffJSUnminifyOptions()) -> JeffJSUnminified {
        return format(span: JeffJSBytesSpan(utf8: source), options: options)
    }

    /// Format UTF-8 bytes (a mapped script text, a cache file).
    public static func format(span: JeffJSBytesSpan, options: JeffJSUnminifyOptions = JeffJSUnminifyOptions()) -> JeffJSUnminified {
        let lexed = lex(span)
        return span.withUnsafeBufferPointer { src -> JeffJSUnminified in
            let origStarts = lineStarts(src)
            guard lexed.error == nil else {
                let text = String(decoding: src, as: UTF8.self)
                return JeffJSUnminified(text: text, ok: false, error: lexed.error, tokenCount: 0,
                                        originalByteCount: src.count, runOrig: [0], runOut: [0],
                                        origLineStarts: origStarts, outLineStarts: origStarts,
                                        fnStart: [], fnEnd: [], fnParent: [])
            }
            var printer = Printer(src: src, lexed: lexed, options: options, origLineStarts: origStarts)
            printer.run()
            let outBytes = printer.out
            let text = String(decoding: outBytes, as: UTF8.self)
            let outStarts = outBytes.withUnsafeBufferPointer { lineStarts($0) }
            return JeffJSUnminified(text: text, ok: true, error: nil, tokenCount: lexed.significantCount,
                                    originalByteCount: src.count,
                                    runOrig: printer.runOrig, runOut: printer.runOut,
                                    origLineStarts: origStarts, outLineStarts: outStarts,
                                    fnStart: printer.fnStart, fnEnd: printer.fnEnd, fnParent: printer.fnParent)
        }
    }

    /// The significant tokens of `source` as (type, text) pairs, lexed with
    /// the formatter's own regex / template rules — the round-trip check:
    /// `tokens(format(s).text) == tokens(s)`. Comments are not tokens.
    public static func tokenSignature(_ source: String) -> (types: [Int], texts: [Substring], error: String?) {
        let span = JeffJSBytesSpan(utf8: source)
        let lexed = lex(span)
        var types: [Int] = [], texts: [Substring] = []
        types.reserveCapacity(lexed.significantCount)
        texts.reserveCapacity(lexed.significantCount)
        let utf8 = Array(source.utf8)
        for t in lexed.toks where t.type != T.commentLine && t.type != T.commentBlock {
            types.append(Int(t.type))
            texts.append(Substring(String(decoding: utf8[Int(t.start) ..< Int(t.start + t.len)], as: UTF8.self)))
        }
        return (types, texts, lexed.error)
    }

    /// Line starts by the engine's rule (`JeffJSParseState.getLineCol`): \n, \r, \r\n.
    static func lineStarts(_ b: UnsafeBufferPointer<UInt8>) -> [UInt32] {
        var starts: [UInt32] = [0]
        let n = b.count
        var i = 0
        while i < n {
            let c = b[i]
            if c == 0x0A { starts.append(UInt32(i + 1)) }
            else if c == 0x0D {
                if i + 1 < n, b[i + 1] == 0x0A { i += 1 }
                starts.append(UInt32(i + 1))
            }
            i += 1
        }
        return starts
    }
}

// MARK: - Token model

/// Token type codes: the tokenizer's (`JSTokenType` raw values, ASCII for
/// one-character punctuators) plus two comment codes.
nonisolated enum T {
    static let number: UInt8 = 128, string: UInt8 = 129, template: UInt8 = 130, ident: UInt8 = 131
    static let regexp: UInt8 = 132, divAssign: UInt8 = 133, privateName: UInt8 = 135, eof: UInt8 = 136
    static let shlAssign: UInt8 = 137, dqmAssign: UInt8 = 150
    static let shl: UInt8 = 151, sar: UInt8 = 152, shr: UInt8 = 153, pow: UInt8 = 154
    static let land: UInt8 = 155, lor: UInt8 = 156, inc: UInt8 = 157, dec: UInt8 = 158
    static let eq: UInt8 = 159, neq: UInt8 = 160, strictEq: UInt8 = 161, strictNeq: UInt8 = 162
    static let le: UInt8 = 163, ge: UInt8 = 164, arrow: UInt8 = 165, ellipsis: UInt8 = 166
    static let dqm: UInt8 = 167, optChain: UInt8 = 168
    static let null: UInt8 = 169, false_: UInt8 = 170, true_: UInt8 = 171, if_: UInt8 = 172, else_: UInt8 = 173
    static let return_: UInt8 = 174, var_: UInt8 = 175, this_: UInt8 = 176, delete_: UInt8 = 177, void_: UInt8 = 178
    static let typeof_: UInt8 = 179, new_: UInt8 = 180, in_: UInt8 = 181, instanceof_: UInt8 = 182, do_: UInt8 = 183
    static let while_: UInt8 = 184, for_: UInt8 = 185, break_: UInt8 = 186, continue_: UInt8 = 187, switch_: UInt8 = 188
    static let case_: UInt8 = 189, default_: UInt8 = 190, throw_: UInt8 = 191, try_: UInt8 = 192, catch_: UInt8 = 193
    static let finally_: UInt8 = 194, function_: UInt8 = 195, debugger_: UInt8 = 196, with_: UInt8 = 197
    static let class_: UInt8 = 198, const_: UInt8 = 199, enum_: UInt8 = 200, export_: UInt8 = 201
    static let extends_: UInt8 = 202, import_: UInt8 = 203, super_: UInt8 = 204, let_: UInt8 = 207
    static let static_: UInt8 = 212, yield_: UInt8 = 213, await_: UInt8 = 214
    static let firstKeyword: UInt8 = 169, lastKeyword: UInt8 = 216
    static let commentLine: UInt8 = 250, commentBlock: UInt8 = 251

    static let lparen: UInt8 = 0x28, rparen: UInt8 = 0x29, lbrack: UInt8 = 0x5B, rbrack: UInt8 = 0x5D
    static let lbrace: UInt8 = 0x7B, rbrace: UInt8 = 0x7D, semi: UInt8 = 0x3B, comma: UInt8 = 0x2C
    static let colon: UInt8 = 0x3A, question: UInt8 = 0x3F, dot: UInt8 = 0x2E, star: UInt8 = 0x2A
    static let plus: UInt8 = 0x2B, minus: UInt8 = 0x2D, bang: UInt8 = 0x21, tilde: UInt8 = 0x7E
    static let assign: UInt8 = 0x3D, slash: UInt8 = 0x2F, at: UInt8 = 0x40

    @inline(__always) static func isKeyword(_ t: UInt8) -> Bool { t >= firstKeyword && t <= lastKeyword }
    /// Keywords that are values (end an expression).
    @inline(__always) static func isValueKeyword(_ t: UInt8) -> Bool {
        t == null || t == false_ || t == true_ || t == this_ || t == super_
    }
    @inline(__always) static func isAssignOp(_ t: UInt8) -> Bool {
        t == assign || t == divAssign || (t >= shlAssign && t <= dqmAssign)
    }
}

/// Token roles (pass 1).
nonisolated enum R {
    static let none: UInt8 = 0
    // braces
    static let block: UInt8 = 1, object: UInt8 = 2, classBody: UInt8 = 3, switchBody: UInt8 = 4
    static let funcBody: UInt8 = 5, arrowBody: UInt8 = 6
    // parens
    static let call: UInt8 = 10, control: UInt8 = 11, forHeader: UInt8 = 12, params: UInt8 = 13, switchParen: UInt8 = 14
    // brackets
    static let index: UInt8 = 15, array: UInt8 = 16
    // template substitution (frames only)
    static let tmpl: UInt8 = 17
    // colons / question
    static let ternaryColon: UInt8 = 20, propColon: UInt8 = 21, caseColon: UInt8 = 22, labelColon: UInt8 = 23
    static let ternaryQ: UInt8 = 24
    // operators
    static let unary: UInt8 = 25, binary: UInt8 = 26, postfix: UInt8 = 27, genStar: UInt8 = 28
    static let caseKeyword: UInt8 = 29

    @inline(__always) static func isBlockish(_ r: UInt8) -> Bool {
        r == block || r == funcBody || r == arrowBody || r == switchBody || r == classBody
    }
}

/// Token flags.
nonisolated enum F {
    static let nl: UInt16 = 1            // a line terminator in the gap before the token (ASI)
    static let nlDirect: UInt16 = 2      // a line terminator right before the token (after any comment)
    static let containsBlock: UInt16 = 4 // opener: a block brace somewhere inside
    static let exprEnd: UInt16 = 8       // the token ends an expression
    static let key: UInt16 = 16          // at a property-key position (object / class member)
    static let tmplStart: UInt16 = 32    // template token starts with a backtick
    static let tmplOpen: UInt16 = 64     // template token ends with `${`
    static let aux: UInt16 = 128         // params / func body / class: expression; block: `do` body
    static let head: UInt16 = 256        // head token of a braced function
}

nonisolated struct UTok {
    var start: UInt32
    var len: UInt32
    var match: Int32 = -1
    var type: UInt8
    var role: UInt8 = 0
    var flags: UInt16 = 0
}

nonisolated struct Lexed {
    var toks: ContiguousArray<UTok> = []
    /// widthPrefix[i] = sum over tokens < i of (len + 1): a token span's
    /// one-line width estimate in O(1).
    var widthPrefix: ContiguousArray<UInt32> = [0]
    var significantCount = 0
    var error: String? = nil
}

// MARK: - Pass 1: lex + structure

nonisolated private struct P1Frame {
    var role: UInt8
    var open: Int32
    var ternary: Int32 = 0
    var casePending = false
    var aux = false
    var head: Int32 = -1
    var isKey = false
}

extension JeffJSUnminifier {

    static func lex(_ span: JeffJSBytesSpan) -> Lexed {
        var L = Lexed()
        let ps = JeffJSParseState(span: span, filename: "<unminify>")
        ps.speculationDepth = 1       // lexing errors are reported here, not printed
        ps.allowHTMLComments = true
        let n = span.count
        L.toks.reserveCapacity(n / 3 + 16)
        L.widthPrefix.reserveCapacity(n / 3 + 17)

        span.withUnsafeBufferPointer { b in
            var stack: [P1Frame] = [P1Frame(role: R.block, open: -1)]
            stack.reserveCapacity(64)
            var prevSig = -1, prevSig2 = -1
            var keyPosNext = false
            var memberStart: Int32 = -1
            var pendingClass: [(depth: Int, expr: Bool)] = []
            var funcKw: (index: Int32, head: Int32, expr: Bool, depth: Int)? = nil
            var arrowHead: Int32 = -1
            var lastParamsHead: Int32 = -1
            var lastParamsExpr = false
            var lastEnd = 0

            @inline(__always) func tokIs(_ i: Int, _ word: StaticString) -> Bool {
                guard i >= 0 else { return false }
                let t = L.toks[i]
                guard t.type == T.ident, Int(t.len) == word.utf8CodeUnitCount else { return false }
                let w = word.utf8Start
                for k in 0 ..< Int(t.len) where b[Int(t.start) + k] != w[k] { return false }
                return true
            }
            @inline(__always) func exprEnd(_ i: Int) -> Bool {
                i >= 0 && L.toks[i].flags & F.exprEnd != 0
            }
            /// Whether a token after `prevSig` (with a newline before it or
            /// not) starts a statement — `function` / `class` there is a
            /// declaration.
            func statementStart(_ p: Int, _ p2: Int, nl: Bool) -> Bool {
                var p = p, p2 = p2
                if p >= 0, tokIs(p, "async") { p = p2; p2 = -1 }   // `async function`
                guard p >= 0 else { return true }
                let t = L.toks[p]
                switch t.type {
                case T.semi: return true
                case T.lbrace: return t.role != R.object
                case T.rbrace: return t.flags & F.exprEnd == 0 || nl
                case T.rparen: return t.role == R.control || t.role == R.forHeader
                case T.else_, T.do_, T.export_: return true
                case T.colon: return t.role == R.caseColon || t.role == R.labelColon
                case T.default_: return p2 >= 0 && L.toks[p2].type == T.export_
                default: return nl && t.flags & F.exprEnd != 0
                }
            }
            func addComment(_ s: Int, _ e: Int, line: Bool, nlBefore: Bool) {
                var c = UTok(start: UInt32(s), len: UInt32(e - s), type: line ? T.commentLine : T.commentBlock)
                if nlBefore { c.flags |= F.nlDirect | F.nl }
                L.toks.append(c)
                L.widthPrefix.append(L.widthPrefix[L.widthPrefix.count - 1] &+ UInt32(e - s + 1))
            }
            /// Comments in the whitespace gap [s, e); returns whether a line
            /// terminator follows the last comment (or the gap has one and no comment).
            func scanGap(_ s: Int, _ e: Int) -> Bool {
                var p = s
                var sawNL = false
                while p < e {
                    let c = b[p]
                    if c == 0x0A || c == 0x0D { sawNL = true; p += 1; continue }
                    if c >= 0x80 {
                        // U+2028 / U+2029 (E2 80 A8 / A9) are line terminators.
                        if c == 0xE2, p + 2 < e, b[p + 1] == 0x80, b[p + 2] == 0xA8 || b[p + 2] == 0xA9 { sawNL = true; p += 3; continue }
                        p += 1; continue
                    }
                    if c == 0x2F, p + 1 < e, b[p + 1] == 0x2F {
                        var q = p + 2
                        while q < e, b[q] != 0x0A, b[q] != 0x0D, !(b[q] == 0xE2 && q + 2 < e && b[q + 1] == 0x80 && (b[q + 2] == 0xA8 || b[q + 2] == 0xA9)) { q += 1 }
                        addComment(p, q, line: true, nlBefore: sawNL); sawNL = false; p = q; continue
                    }
                    if c == 0x2F, p + 1 < e, b[p + 1] == 0x2A {
                        var q = p + 2
                        while q + 1 < e, !(b[q] == 0x2A && b[q + 1] == 0x2F) { q += 1 }
                        q = min(e, q + 2)
                        addComment(p, q, line: false, nlBefore: sawNL); sawNL = false; p = q; continue
                    }
                    if (c == 0x3C && p + 3 < e && b[p + 1] == 0x21 && b[p + 2] == 0x2D && b[p + 3] == 0x2D)
                        || (c == 0x2D && p + 2 < e && b[p + 1] == 0x2D && b[p + 2] == 0x3E)
                        || (c == 0x23 && p == 0 && p + 1 < e && b[p + 1] == 0x21) {
                        var q = p
                        while q < e, b[q] != 0x0A, b[q] != 0x0D { q += 1 }
                        addComment(p, q, line: true, nlBefore: sawNL || c == 0x2D); sawNL = false; p = q; continue
                    }
                    p += 1
                }
                return sawNL
            }

            while true {
                let topRole = stack[stack.count - 1].role
                ps.templateNestLevel = topRole == R.tmpl ? 1 : 0
                // Regex vs division is decided here: the tokenizer reads
                // `lastTokenType` (an expression end means division).
                ps.token.type = exprEnd(prevSig) ? 0x29 : 0x28
                if !ps.nextToken() {
                    let (l, c) = ps.getLineCol(ps.token.ptr)
                    L.error = (ps.lastError?.text ?? "tokenize error") + " at \(l):\(c)"
                    return
                }
                let rawType = ps.token.type
                let start = ps.token.ptr
                let end = ps.bufPtr
                var nlDirect = ps.gotLF
                if start > lastEnd {
                    let before = L.toks.count
                    let nlAfterLastComment = scanGap(lastEnd, start)
                    if L.toks.count != before { nlDirect = nlAfterLastComment }
                }
                if rawType == Int(T.eof) || start >= n { break }
                lastEnd = end
                let i = L.toks.count
                var tok = UTok(start: UInt32(start), len: UInt32(end - start), type: UInt8(truncatingIfNeeded: rawType))
                if ps.gotLF { tok.flags |= F.nl }
                if nlDirect { tok.flags |= F.nlDirect }
                let pType: UInt8 = prevSig >= 0 ? L.toks[prevSig].type : 0
                let pRole: UInt8 = prevSig >= 0 ? L.toks[prevSig].role : 0
                let top = stack.count - 1

                // Property-key position (object literal / class member).
                var atKey = false
                if topRole == R.object {
                    atKey = keyPosNext || prevSig == Int(stack[top].open) || (pType == T.comma && prevSig > Int(stack[top].open))
                } else if topRole == R.classBody {
                    atKey = keyPosNext || prevSig == Int(stack[top].open) || pType == T.semi
                        || (pType == T.rbrace && prevSig > Int(stack[top].open))
                        || (ps.gotLF && exprEnd(prevSig))
                }
                // Keywords used as names: after `.` / `?.`, and as keys.
                if T.isKeyword(tok.type) {
                    if pType == T.dot || pType == T.optChain {
                        tok.type = T.ident
                    } else if atKey && tok.type != T.static_ {
                        tok.type = T.ident
                    }
                }
                if atKey {
                    tok.flags |= F.key
                    if !keyPosNext { memberStart = Int32(i) }
                }
                keyPosNext = atKey && (tok.type == T.static_ || tok.type == T.star
                                       || (tok.type == T.ident && (Self.textIs(b, tok, "get") || Self.textIs(b, tok, "set")
                                                                   || Self.textIs(b, tok, "async") || Self.textIs(b, tok, "accessor"))))

                switch tok.type {
                case T.lparen:
                    var f = P1Frame(role: R.call, open: Int32(i))
                    if pType == T.if_ || pType == T.while_ || pType == T.with_ || pType == T.catch_ {
                        f.role = R.control
                    } else if pType == T.switch_ {
                        f.role = R.switchParen
                    } else if pType == T.for_ || (pType == T.await_ && prevSig2 >= 0 && L.toks[prevSig2].type == T.for_) {
                        f.role = R.forHeader
                    } else if let fk = funcKw, fk.depth == stack.count {
                        f.role = R.params; f.aux = fk.expr; f.head = fk.head
                        funcKw = nil
                    } else if prevSig >= 0, L.toks[prevSig].flags & F.key != 0 {
                        f.role = R.params; f.aux = false; f.head = memberStart
                    }
                    tok.role = f.role
                    stack.append(f)
                case T.rparen, T.rbrack:
                    if stack.count > 1, stack[top].open >= 0,
                       L.toks[Int(stack[top].open)].type == (tok.type == T.rparen ? T.lparen : T.lbrack) {
                        let f = stack.removeLast()
                        tok.role = f.role
                        tok.match = f.open
                        L.toks[Int(f.open)].match = Int32(i)
                        if f.role == R.params {
                            lastParamsHead = f.head; lastParamsExpr = f.aux
                            if f.aux { tok.flags |= F.aux }
                        }
                        if f.isKey { tok.flags |= F.key }
                        propagateContainsBlock(&L, closed: Int(f.open), parent: stack[stack.count - 1])
                    }
                case T.lbrack:
                    var f = P1Frame(role: exprEnd(prevSig) ? R.index : R.array, open: Int32(i))
                    f.isKey = atKey
                    tok.role = f.role
                    stack.append(f)
                case T.lbrace:
                    var role = R.object
                    var aux = false
                    var head: Int32 = -1
                    if let pc = pendingClass.last, pc.depth == stack.count {
                        role = R.classBody; aux = pc.expr
                        pendingClass.removeLast()
                    } else if pType == T.arrow {
                        role = R.arrowBody; aux = true; head = arrowHead
                    } else if pType == T.rparen {
                        if pRole == R.params { role = R.funcBody; aux = lastParamsExpr; head = lastParamsHead }
                        else if pRole == R.switchParen { role = R.switchBody }
                        else { role = R.block }
                    } else if prevSig < 0 || pType == T.semi || pType == T.rbrace || pType == T.else_
                                || pType == T.try_ || pType == T.finally_ || pType == T.catch_ {
                        role = R.block
                    } else if pType == T.lbrace {
                        role = pRole == R.object ? R.object : R.block
                    } else if pType == T.do_ {
                        role = R.block; aux = true
                    } else if pType == T.colon {
                        role = (pRole == R.caseColon || pRole == R.labelColon) ? R.block : R.object
                    } else if pType == T.static_ && topRole == R.classBody {
                        role = R.block
                    } else if exprEnd(prevSig) {
                        role = R.block      // only valid after ASI
                    }
                    tok.role = role
                    if aux { tok.flags |= F.aux }
                    if role == R.funcBody || role == R.arrowBody {
                        let h = head >= 0 ? Int(head) : i
                        if h < i { L.toks[h].flags |= F.head } else { tok.flags |= F.head }
                    }
                    if R.isBlockish(role) && role != R.classBody {
                        // The enclosing expression frame holds a block.
                        if !R.isBlockish(stack[top].role), stack[top].open >= 0 {
                            L.toks[Int(stack[top].open)].flags |= F.containsBlock
                        }
                    }
                    var f = P1Frame(role: role, open: Int32(i))
                    f.aux = aux
                    stack.append(f)
                case T.rbrace:
                    if stack.count > 1, stack[top].open >= 0, L.toks[Int(stack[top].open)].type == T.lbrace {
                        let f = stack.removeLast()
                        tok.role = f.role
                        tok.match = f.open
                        if f.aux { tok.flags |= F.aux }
                        L.toks[Int(f.open)].match = Int32(i)
                        propagateContainsBlock(&L, closed: Int(f.open), parent: stack[stack.count - 1])
                    }
                case T.template:
                    if start < n, b[start] == 0x60 { tok.flags |= F.tmplStart }
                    if end >= 2, b[end - 1] == 0x7B, b[end - 2] == 0x24, end - 2 >= start + 1 { tok.flags |= F.tmplOpen }
                    if tok.flags & F.tmplStart == 0, stack.count > 1, stack[top].role == R.tmpl {
                        let f = stack.removeLast()
                        tok.match = f.open
                        if !R.isBlockish(stack[stack.count - 1].role), stack[stack.count - 1].open >= 0,
                           L.toks[Int(f.open)].flags & F.containsBlock != 0 {
                            L.toks[Int(stack[stack.count - 1].open)].flags |= F.containsBlock
                        }
                    }
                    if tok.flags & F.tmplOpen != 0 {
                        stack.append(P1Frame(role: R.tmpl, open: Int32(i)))
                    }
                case T.question:
                    stack[top].ternary += 1
                    tok.role = R.ternaryQ
                case T.colon:
                    if stack[top].ternary > 0 {
                        stack[top].ternary -= 1; tok.role = R.ternaryColon
                    } else if topRole == R.object {
                        tok.role = R.propColon
                    } else if stack[top].casePending {
                        stack[top].casePending = false; tok.role = R.caseColon
                    } else if R.isBlockish(topRole) && pType == T.ident {
                        tok.role = R.labelColon
                    } else {
                        tok.role = R.propColon
                    }
                case T.semi:
                    if R.isBlockish(topRole) { stack[top].ternary = 0 }
                case T.case_:
                    if topRole == R.switchBody { stack[top].casePending = true; tok.role = R.caseKeyword }
                case T.default_:
                    if topRole == R.switchBody && pType != T.export_ { stack[top].casePending = true; tok.role = R.caseKeyword }
                case T.function_:
                    let expr = !statementStart(prevSig, prevSig2, nl: ps.gotLF)
                    var head = Int32(i)
                    if prevSig >= 0, tokIs(prevSig, "async"), !ps.gotLF { head = Int32(prevSig) }
                    funcKw = (Int32(i), head, expr, stack.count)
                case T.class_:
                    pendingClass.append((stack.count, !statementStart(prevSig, prevSig2, nl: ps.gotLF)))
                case T.arrow:
                    var h = prevSig
                    if pType == T.rparen, prevSig >= 0, L.toks[prevSig].match >= 0 { h = Int(L.toks[prevSig].match) }
                    // `async (x) =>` / `async x =>`
                    var k = h - 1
                    while k >= 0, L.toks[k].type >= T.commentLine { k -= 1 }
                    if k >= 0, tokIs(k, "async") { h = k }
                    arrowHead = Int32(max(0, h))
                case T.plus, T.minus:
                    tok.role = exprEnd(prevSig) ? R.binary : R.unary
                case T.inc, T.dec:
                    tok.role = (exprEnd(prevSig) && !ps.gotLF) ? R.postfix : R.unary
                case T.star:
                    tok.role = (pType == T.function_ || pType == T.yield_ || atKey) ? R.genStar : R.binary
                default:
                    break
                }

                // Expression end?
                var ee = false
                switch tok.type {
                case T.ident, T.number, T.string, T.regexp, T.privateName,
                     T.this_, T.super_, T.true_, T.false_, T.null:
                    ee = true
                case T.template: ee = tok.flags & F.tmplOpen == 0
                case T.rparen: ee = tok.role == R.call
                case T.rbrack: ee = true
                case T.rbrace:
                    ee = tok.role == R.object || tok.role == R.arrowBody
                        || ((tok.role == R.funcBody || tok.role == R.classBody) && tok.flags & F.aux != 0)
                case T.inc, T.dec: ee = tok.role == R.postfix
                default: ee = false
                }
                if ee { tok.flags |= F.exprEnd }

                L.toks.append(tok)
                L.widthPrefix.append(L.widthPrefix[L.widthPrefix.count - 1] &+ UInt32(end - start + 1))
                L.significantCount += 1
                prevSig2 = prevSig
                prevSig = i
            }
            // Trailing comments.
            if lastEnd < n { _ = scanGap(lastEnd, n) }
        }
        return L
    }

    /// A closed frame that held a block makes its expression parent hold one.
    @inline(__always)
    private static func propagateContainsBlock(_ L: inout Lexed, closed: Int, parent: P1Frame) {
        guard L.toks[closed].flags & F.containsBlock != 0 || R.isBlockish(L.toks[closed].role) && L.toks[closed].role != R.classBody else { return }
        if !R.isBlockish(parent.role), parent.open >= 0 {
            L.toks[Int(parent.open)].flags |= F.containsBlock
        }
    }

    @inline(__always)
    static func textIs(_ b: UnsafeBufferPointer<UInt8>, _ t: UTok, _ word: StaticString) -> Bool {
        guard Int(t.len) == word.utf8CodeUnitCount else { return false }
        let w = word.utf8Start
        for k in 0 ..< Int(t.len) where b[Int(t.start) + k] != w[k] { return false }
        return true
    }
}

// MARK: - Pass 2: layout + emit

nonisolated private struct LFrame {
    var role: UInt8
    var open: Int32
    var multiline = false
    var fill = false
    var inlineObj = false
    var empty = false
    var inner: Int = 0
    var close: Int = 0
    var stmt: Int = 0
    var cont = false
    var chain = false
    var fnIndex: Int32 = -1
}

nonisolated private enum Sep { case none, space, newline(Int) }

nonisolated private struct Printer {
    let src: UnsafeBufferPointer<UInt8>
    let toks: ContiguousArray<UTok>
    let widthPrefix: ContiguousArray<UInt32>
    let w: Int
    let maxLen: Int
    let posEvery: Int
    let keepComments: Bool
    let origLineStarts: [UInt32]

    var out: [UInt8] = []
    var col = 0
    var lineIndent = 0
    var atLineStart = true
    var lineBegin = 0          // out offset where the current line starts
    var outLine = 1
    var lineFirstOrig = -1     // original offset of the current line's first token
    var nlSinceSig = true
    var mustNL = false
    var lastWasComment = false
    var frames: [LFrame] = []
    var runOrig: [UInt32] = []
    var runOut: [UInt32] = []
    var lastDelta = Int.min
    var fnStart: [UInt32] = []
    var fnEnd: [UInt32] = []
    var fnParent: [Int32] = []
    var openFns: [Int32] = []
    var heads: [UInt32] = []   // formatted offsets of pending function heads

    init(src: UnsafeBufferPointer<UInt8>, lexed: Lexed, options: JeffJSUnminifyOptions, origLineStarts: [UInt32]) {
        self.src = src
        self.toks = lexed.toks
        self.widthPrefix = lexed.widthPrefix
        self.w = options.indentWidth
        self.maxLen = options.maxLineLength
        self.posEvery = options.positionCommentEvery
        self.keepComments = options.keepComments
        self.origLineStarts = origLineStarts
        out.reserveCapacity(src.count + src.count / 2 + 64)
        runOrig.reserveCapacity(lexed.significantCount / 2 + 4)
        runOut.reserveCapacity(lexed.significantCount / 2 + 4)
        var root = LFrame(role: R.block, open: -1)
        root.multiline = true
        frames.append(root)
    }

    @inline(__always) func width(_ a: Int, _ b: Int) -> Int {
        Int(widthPrefix[b + 1] &- widthPrefix[a])
    }

    @inline(__always) func isText(_ t: UTok, _ word: StaticString) -> Bool {
        JeffJSUnminifier.textIs(src, t, word)
    }

    // MARK: output primitives

    mutating func newline(_ indent: Int) {
        if atLineStart {
            out.removeSubrange(lineBegin ..< out.count)
        } else {
            while let l = out.last, l == 0x20 { out.removeLast() }
            if posEvery > 0, outLine % posEvery == 0, lineFirstOrig >= 0 {
                let k = JeffJSUnminified.lastIndex(origLineStarts, notAbove: lineFirstOrig)
                let tag = " // <\(k + 1):\(lineFirstOrig - Int(origLineStarts[max(0, k)]) + 1)>"
                out.append(contentsOf: tag.utf8)
            }
            out.append(0x0A)
            outLine += 1
            lineBegin = out.count
        }
        let ind = max(0, indent)
        if ind > 0 { out.append(contentsOf: repeatElement(0x20, count: ind)) }
        col = ind
        lineIndent = ind
        atLineStart = true
        lineFirstOrig = -1
        nlSinceSig = true
    }

    mutating func space() {
        if atLineStart { return }
        if let l = out.last, l == 0x20 { return }
        out.append(0x20); col += 1
    }

    mutating func emit(_ t: UTok) {
        let s = Int(t.start), n = Int(t.len)
        let delta = out.count - s
        if delta != lastDelta {
            runOrig.append(UInt32(s)); runOut.append(UInt32(out.count)); lastDelta = delta
        }
        if atLineStart { lineFirstOrig = s }
        out.append(contentsOf: UnsafeBufferPointer(rebasing: src[s ..< s + n]))
        atLineStart = false
        if t.type == T.template || t.type == T.string || t.type == T.commentBlock {
            var k = n - 1
            var lines = 0
            var lastNL = -1
            while k >= 0 {
                let c = src[s + k]
                if c == 0x0A || c == 0x0D {
                    if lastNL < 0 { lastNL = k }
                    if !(c == 0x0A && k > 0 && src[s + k - 1] == 0x0D) { lines += 1 }
                }
                k -= 1
            }
            if lastNL >= 0 {
                col = n - lastNL - 1
                outLine += lines
                lineBegin = out.count - col
                return
            }
        }
        col += n
    }

    // MARK: frame helpers

    func defaultIndent() -> Int {
        let f = frames[frames.count - 1]
        if R.isBlockish(f.role) { return f.stmt + (f.cont ? w : 0) }
        return f.inner
    }

    mutating func softIndent() -> Int {
        let k = frames.count - 1
        if R.isBlockish(frames[k].role) {
            frames[k].cont = true
            return frames[k].stmt + w
        }
        return frames[k].multiline ? frames[k].inner + w : frames[k].inner
    }

    func tokIsExprEnd(_ i: Int) -> Bool { i >= 0 && toks[i].flags & F.exprEnd != 0 }

    // MARK: spacing

    func isSpacedOperator(_ t: UTok) -> Bool {
        switch t.type {
        case T.star: return t.role != R.genStar
        case T.plus, T.minus: return t.role == R.binary
        case 0x3C, 0x3E, 0x25, 0x26, 0x7C, 0x5E, T.slash: return true   // < > % & | ^ /
        case T.le, T.ge, T.eq, T.neq, T.strictEq, T.strictNeq, T.land, T.lor, T.dqm,
             T.shl, T.sar, T.shr, T.pow, T.arrow:
            return true
        default: return T.isAssignOp(t.type)
        }
    }

    func wantSpace(_ pi: Int, _ i: Int) -> Bool {
        let p = toks[pi], t = toks[i]
        let P = p.type, TT = t.type
        if TT == T.comma || TT == T.semi || TT == T.rparen || TT == T.rbrack { return false }
        if TT == T.dot || TT == T.optChain { return false }
        if P == T.dot || P == T.optChain || P == T.lparen || P == T.lbrack || P == T.ellipsis
            || P == T.bang || P == T.tilde || P == T.at || P == T.privateName && TT == T.lparen { return false }
        if (P == T.plus || P == T.minus || P == T.inc || P == T.dec) && p.role == R.unary { return false }
        if (TT == T.inc || TT == T.dec) && t.role == R.postfix { return false }
        if TT == T.template && t.flags & F.tmplStart == 0 { return false }   // `}` of `${…}`
        if P == T.template && p.flags & F.tmplOpen != 0 { return false }      // after `${`
        if TT == T.colon { return t.role == R.ternaryColon }
        if P == T.colon { return true }
        if isSpacedOperator(t) || isSpacedOperator(p) { return true }
        if TT == T.question || P == T.question { return true }
        if P == T.comma { return true }
        if P == T.star && p.role == R.genStar {
            var k = pi - 1
            while k >= 0, toks[k].type >= T.commentLine { k -= 1 }
            return k >= 0 && (toks[k].type == T.function_ || toks[k].type == T.yield_)
        }
        if TT == T.star && t.role == R.genStar { return !(P == T.function_ || P == T.yield_) }
        if TT == T.lparen {
            if T.isKeyword(P) && !T.isValueKeyword(P) && P != T.import_ { return true }
            if P == T.ident && isText(p, "async"), t.match >= 0, Int(t.match) + 1 < toks.count {
                var k = Int(t.match) + 1
                while k < toks.count, toks[k].type >= T.commentLine { k += 1 }
                return k < toks.count && toks[k].type == T.arrow
            }
            return false
        }
        if TT == T.lbrack {
            if tokIsExprEnd(pi) { return false }
            return T.isKeyword(P) && !T.isValueKeyword(P) || (P == T.ident && p.flags & F.key != 0)
        }
        if TT == T.template {   // a template head
            if tokIsExprEnd(pi) { return false }
            return T.isKeyword(P) && !T.isValueKeyword(P)
        }
        if TT == T.lbrace { return true }
        if T.isKeyword(P) && !T.isValueKeyword(P) { return true }
        if P == T.rparen || P == T.rbrace || P == T.rbrack || tokIsExprEnd(pi) {
            switch TT {
            case T.ident, T.number, T.string, T.regexp, T.privateName, T.bang, T.tilde, T.ellipsis,
                 T.plus, T.minus, T.inc, T.dec, T.at:
                return true
            default:
                return T.isKeyword(TT)
            }
        }
        return false
    }

    /// Bytes that would fuse with the next token without a separator.
    func needsGlueSpace(_ t: UTok) -> Bool {
        guard let last = out.last, last != 0x20, last != 0x0A else { return false }
        let first = src[Int(t.start)]
        @inline(__always) func identish(_ c: UInt8) -> Bool {
            (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39)
                || c == 0x24 || c == 0x5F || c == 0x5C || c >= 0x80
        }
        if identish(last) && (identish(first) || first == 0x23) { return true }
        if (last == 0x2B && first == 0x2B) || (last == 0x2D && first == 0x2D) { return true }
        if last == 0x2F && (first == 0x2F || first == 0x2A) { return true }
        if last == 0x3C && first == 0x21 { return true }                      // <!--
        if first == 0x3E && out.count >= 2 && last == 0x2D && out[out.count - 2] == 0x2D { return true }  // -->
        if last == 0x3F && first == 0x2E && t.len > 1 && src[Int(t.start) + 1] >= 0x30 && src[Int(t.start) + 1] <= 0x39 { return true }
        if first == 0x2E && t.type != T.number {
            // `1 .toString()`: a digits-only number followed by `.`
            var k = out.count - 1, digitsOnly = true, sawDigit = false
            while k >= 0 {
                let c = out[k]
                if c >= 0x30 && c <= 0x39 { sawDigit = true; k -= 1; continue }
                if c == 0x5F { k -= 1; continue }
                if identish(c) || c == 0x2E { digitsOnly = false }
                break
            }
            if sawDigit && digitsOnly { return true }
        }
        if t.type == T.number && first == 0x2E && last == 0x2E { return true }
        return false
    }

    // MARK: ASI

    func canEndStatement(_ pi: Int) -> Bool {
        if tokIsExprEnd(pi) { return true }
        let P = toks[pi].type
        return P == T.return_ || P == T.break_ || P == T.continue_ || P == T.yield_
            || P == T.debugger_ || P == T.throw_ || P == T.let_
    }

    func startsStatement(_ pi: Int, _ i: Int) -> Bool {
        let t = toks[i]
        switch t.type {
        case T.ident, T.number, T.string, T.regexp, T.privateName, T.lbrace, T.bang, T.tilde, T.at:
            return true
        case T.lparen, T.lbrack: return !tokIsExprEnd(pi)
        case T.template: return t.flags & F.tmplStart != 0 && !tokIsExprEnd(pi)
        case T.plus, T.minus, T.inc, T.dec: return t.role == R.unary
        default:
            return T.isKeyword(t.type) && t.type != T.in_ && t.type != T.instanceof_
        }
    }

    /// A newline the original did not have may not go between these tokens.
    func newlineForbidden(_ pi: Int, _ i: Int) -> Bool {
        let p = toks[pi], t = toks[i]
        if t.flags & F.nl != 0 { return false }
        if frames[frames.count - 1].role == R.forHeader { return true }
        switch p.type {
        case T.return_, T.throw_, T.break_, T.continue_, T.yield_:
            return !(t.type == T.semi || t.type == T.rbrace)
        case T.ident:
            if isText(p, "async") && (t.type == T.function_ || t.type == T.ident || t.type == T.lparen) { return true }
            if p.flags & F.key != 0 && t.flags & F.key != 0 { return true }   // `get x`, `static async *x`
        case T.static_:
            if t.flags & F.key != 0 { return true }
        default: break
        }
        if t.type == T.arrow { return true }
        if (t.type == T.inc || t.type == T.dec) && t.role == R.postfix { return true }
        if (t.type == T.lparen || t.type == T.lbrack || (t.type == T.template && t.flags & F.tmplStart != 0)) && tokIsExprEnd(pi) { return true }
        return false
    }

    // MARK: layout

    mutating func layout(_ pi: Int, _ i: Int) -> Sep {
        let t = toks[i]
        let TT = t.type
        let k = frames.count - 1
        let f = frames[k]
        let isCloser = TT == T.rbrace || TT == T.rparen || TT == T.rbrack
        if isCloser && Int(t.match) == Int(f.open) && f.open >= 0 {
            if f.empty { return .none }
            if f.multiline { return .newline(f.close) }
            if f.inlineObj { return .space }
            return .none
        }
        guard pi >= 0 else { return .none }
        let p = toks[pi]
        let P = p.type
        if pi == Int(f.open) && (P == T.lbrace || P == T.lparen || P == T.lbrack) {
            if f.multiline { return .newline(R.isBlockish(f.role) ? f.stmt : f.inner) }
            if f.inlineObj { return .space }
            return .none
        }
        if t.role == R.caseKeyword && f.role == R.switchBody {
            frames[k].stmt = f.inner; frames[k].cont = false
            return .newline(f.inner)
        }
        if P == T.colon && p.role == R.caseColon {
            frames[k].stmt = f.inner + w; frames[k].cont = false
            return .newline(f.inner + w)
        }
        if P == T.semi {
            if f.role == R.forHeader { return (TT == T.semi || TT == T.rparen) ? .none : .space }
            if R.isBlockish(f.role) {
                frames[k].cont = false; frames[k].chain = false
                return .newline(f.stmt)
            }
            return .space
        }
        if P == T.rbrace && p.flags & F.exprEnd == 0 && R.isBlockish(p.role) {
            if TT == T.else_ || TT == T.catch_ || TT == T.finally_ { return .space }
            if TT == T.while_ && p.role == R.block && p.flags & F.aux != 0 { return .space }
            if !(TT == T.semi || TT == T.comma || TT == T.rparen || TT == T.rbrack || TT == T.dot || TT == T.optChain) {
                if R.isBlockish(f.role) {
                    frames[k].cont = false; frames[k].chain = false
                    return .newline(f.stmt)
                }
                return .newline(defaultIndent())
            }
        }
        if P == T.comma {
            frames[k].chain = false
            if f.multiline && !f.fill && !R.isBlockish(f.role) { return .newline(f.inner) }
            if R.isBlockish(f.role) {
                frames[k].cont = true
                return .newline(f.stmt + w)
            }
            if f.fill { return col > maxLen ? .newline(f.inner) : .space }
            if col > maxLen && f.role != R.forHeader && f.role != R.tmpl { return .newline(softIndent()) }
            return .space
        }
        if (TT == T.dot || TT == T.optChain) && P == T.rparen && f.role != R.forHeader && f.role != R.tmpl {
            var seg = 1
            if i + 1 < toks.count {
                var e = i + 1
                if e + 1 < toks.count, toks[e + 1].type == T.lparen, toks[e + 1].match > 0 { e = Int(toks[e + 1].match) }
                seg = width(i, e)
            }
            if f.chain || col + seg > maxLen {
                frames[k].chain = true
                if R.isBlockish(f.role) { frames[k].cont = true; return .newline(f.stmt + w) }
                return .newline(f.multiline ? f.inner + w : f.inner)
            }
        }
        if col > maxLen && f.role != R.forHeader && f.role != R.tmpl {
            if (p.role == R.binary || P == T.land || P == T.lor || P == T.dqm) && !(TT == T.lparen) {
                return .newline(softIndent())
            }
            if (TT == T.question && t.role == R.ternaryQ) || (TT == T.colon && t.role == R.ternaryColon) {
                return .newline(softIndent())
            }
        }
        if P == T.colon && p.role == R.labelColon { return .space }
        return wantSpace(pi, i) ? .space : .none
    }

    // MARK: frames on emit

    mutating func pushFrame(_ i: Int) {
        let t = toks[i]
        var f = LFrame(role: t.role, open: Int32(i))
        let base = lineIndent
        f.inner = base + w
        f.close = base
        f.stmt = f.inner
        let m = Int(t.match)
        f.empty = m == i + 1
        switch t.role {
        case R.block, R.funcBody, R.arrowBody, R.classBody, R.switchBody:
            f.multiline = !f.empty && m > i
        case R.object:
            if !f.empty && m > i {
                let wd = width(i, m)
                f.multiline = t.flags & F.containsBlock != 0 || col + wd > maxLen
                f.inlineObj = !f.multiline
            }
        case R.array:
            if !f.empty && m > i {
                let wd = width(i, m)
                if t.flags & F.containsBlock != 0 { f.multiline = true }
                else if col + wd > maxLen { f.multiline = true; f.fill = true }
            }
        case R.call, R.params:
            if !f.empty && m > i && t.flags & F.containsBlock == 0 {
                f.multiline = col + width(i, m) > maxLen
            }
        default:
            break
        }
        if t.type == T.template { f.role = R.tmpl; f.empty = false; f.multiline = false }
        if (t.role == R.funcBody || t.role == R.arrowBody) && t.type == T.lbrace {
            let start: UInt32 = t.flags & F.head != 0 ? UInt32(out.count - Int(t.len)) : (heads.popLast() ?? UInt32(out.count - Int(t.len)))
            f.fnIndex = Int32(fnStart.count)
            fnStart.append(start)
            fnEnd.append(UInt32(out.count))
            fnParent.append(openFns.last ?? -1)
            openFns.append(f.fnIndex)
        }
        frames.append(f)
    }

    mutating func run() {
        var prevSig = -1
        let count = toks.count
        var i = 0
        while i < count {
            let t = toks[i]
            if t.type >= T.commentLine {
                if keepComments { emitComment(t) }
                i += 1
                continue
            }
            var sep = layout(prevSig, i)
            let forcedNL = mustNL      // a line comment ends the line: always honoured
            if forcedNL {
                if case .newline = sep {} else { sep = .newline(defaultIndent()) }
                mustNL = false
            } else if prevSig >= 0, case .newline = sep, newlineForbidden(prevSig, i), !nlSinceSig {
                sep = .space
            }
            if prevSig >= 0, !nlSinceSig, t.flags & F.nl != 0, canEndStatement(prevSig), startsStatement(prevSig, i) {
                if case .newline = sep {} else {
                    let k = frames.count - 1
                    if R.isBlockish(frames[k].role) {
                        frames[k].cont = false
                        sep = .newline(frames[k].stmt)
                    } else {
                        sep = .newline(defaultIndent())
                    }
                }
            }
            switch sep {
            case .newline(let ind): newline(ind)
            case .space: space()
            case .none:
                if lastWasComment || needsGlueSpace(t) { space() }
            }

            // Closers pop before emitting (indent was decided above).
            let isCloser = (t.type == T.rbrace || t.type == T.rparen || t.type == T.rbrack) && t.match >= 0
            if t.flags & F.head != 0 && !(t.type == T.lbrace) {
                heads.append(UInt32(out.count))
            }
            emit(t)
            lastWasComment = false
            if isCloser, frames.count > 1, Int(frames[frames.count - 1].open) == Int(t.match) {
                let f = frames.removeLast()
                if f.fnIndex >= 0 {
                    fnEnd[Int(f.fnIndex)] = UInt32(out.count)
                    openFns.removeLast()
                }
            } else if t.type == T.template {
                if t.flags & F.tmplStart == 0, frames.count > 1, frames[frames.count - 1].role == R.tmpl {
                    frames.removeLast()
                }
                if t.flags & F.tmplOpen != 0 { pushFrame(i) }
            } else if (t.type == T.lbrace || t.type == T.lparen || t.type == T.lbrack) && t.match > Int32(i) {
                pushFrame(i)
            }
            nlSinceSig = false
            prevSig = i
            i += 1
        }
        if !atLineStart { out.append(0x0A) } else { out.removeSubrange(lineBegin ..< out.count) }
    }

    mutating func emitComment(_ c: UTok) {
        let isHTMLClose = c.type == T.commentLine && src[Int(c.start)] == 0x2D
        if c.flags & F.nlDirect != 0 || mustNL || isHTMLClose {
            if !atLineStart { newline(defaultIndent()) }
        } else if !atLineStart {
            space()
        }
        mustNL = false
        emit(c)
        lastWasComment = true
        if c.type == T.commentLine { mustNL = true }
    }
}
