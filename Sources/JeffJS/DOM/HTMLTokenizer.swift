import Foundation

/// The HTML Standard §13.2.5 tokenizer, over a UTF-8 byte array.
///
/// The tokenizer is *pull*-driven: the tree builder asks for one token at a
/// time and is allowed to change `contentState` (RAWTEXT / RCDATA / script
/// data / PLAINTEXT) and `allowCDATA` in between, which is exactly how the
/// spec's "switch the tokenizer to the … state" steps work. A single `step()`
/// never emits a token *after* a start tag, so the tree builder's state change
/// always lands before the next byte is read.
public struct HTMLTokenizer: Sendable {

    /// The subset of tokenizer states the tree builder may switch into.
    public enum ContentState: Sendable {
        case data
        case rcdata          // <title>, <textarea>: entities decoded, tags not
        case rawtext         // <style>, <xmp>, <iframe>, <noembed>, <noframes>, <noscript>
        case scriptData      // <script>: the <!-- … --> escape ladder
        case plaintext       // <plaintext>: everything to EOF is text
    }

    private let input: [UInt8]
    private var pos: Int = 0

    /// Tokens produced by the current `step()`, drained before stepping again.
    private var queue: [HTMLToken] = []
    private var queueIndex: Int = 0

    /// Settable by the tree builder between tokens.
    public var contentState: ContentState = .data
    /// True while the adjusted current node is a foreign (SVG/MathML) element,
    /// which is the only context where `<![CDATA[` is a CDATA section.
    public var allowCDATA: Bool = false

    /// The last start tag *emitted* — the "appropriate end tag" for RAWTEXT,
    /// RCDATA and script data.
    private var lastStartTagName: [UInt8] = []

    // Scratch buffers; reused so the hot loops do not allocate.
    private var textBytes: [UInt8] = []
    private var tagNameBytes: [UInt8] = []
    private var attrNameBytes: [UInt8] = []
    private var attrValueBytes: [UInt8] = []
    private var commentBytes: [UInt8] = []
    private var tempBytes: [UInt8] = []
    private var currentAttributes: [HTMLAttribute] = []

    // ASCII constants
    private static let lt: UInt8 = 0x3C
    private static let gt: UInt8 = 0x3E
    private static let amp: UInt8 = 0x26
    private static let bang: UInt8 = 0x21
    private static let slash: UInt8 = 0x2F
    private static let eq: UInt8 = 0x3D
    private static let dquote: UInt8 = 0x22
    private static let squote: UInt8 = 0x27
    private static let dash: UInt8 = 0x2D
    private static let semi: UInt8 = 0x3B
    private static let hash: UInt8 = 0x23
    private static let question: UInt8 = 0x3F
    private static let lbracket: UInt8 = 0x5B
    private static let rbracket: UInt8 = 0x5D
    private static let backtick: UInt8 = 0x60
    private static let space: UInt8 = 0x20
    private static let tab: UInt8 = 0x09
    private static let nl: UInt8 = 0x0A
    private static let ff: UInt8 = 0x0C
    private static let cr: UInt8 = 0x0D
    private static let nul: UInt8 = 0x00

    /// U+FFFD REPLACEMENT CHARACTER, in UTF-8.
    private static let replacementBytes: [UInt8] = [0xEF, 0xBF, 0xBD]

    // Literals matched inside the hot loops, pre-encoded: building these from
    // a String on every `<` inside a 150 KB inline script is not free.
    private static let scriptOpenBytes: [UInt8] = Array("<script".utf8)
    private static let scriptCloseBytes: [UInt8] = Array("</script".utf8)
    private static let commentOpenBytes: [UInt8] = Array("--".utf8)
    private static let doctypeBytes: [UInt8] = Array("doctype".utf8)
    private static let cdataOpenBytes: [UInt8] = Array("[CDATA[".utf8)
    private static let publicBytes: [UInt8] = Array("public".utf8)
    private static let systemBytes: [UInt8] = Array("system".utf8)
    private static let escapeOpenBytes: [UInt8] = [Self.lt, Self.bang, Self.dash, Self.dash]

    public init(_ html: String) {
        var bytes = Array(html.utf8)
        // §13.2.3.5: a leading BOM is dropped.
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            bytes.removeFirst(3)
        }
        self.input = bytes
        textBytes.reserveCapacity(256)
        tagNameBytes.reserveCapacity(32)
        attrNameBytes.reserveCapacity(32)
        attrValueBytes.reserveCapacity(128)
        commentBytes.reserveCapacity(64)
        queue.reserveCapacity(4)
    }

    // MARK: - Public API

    /// One token, or nil at end of input.
    public mutating func nextToken() -> HTMLToken? {
        while true {
            if queueIndex < queue.count {
                let token = queue[queueIndex]
                queueIndex += 1
                return token
            }
            if pos >= input.count { return nil }
            queue.removeAll(keepingCapacity: true)
            queueIndex = 0
            step()
        }
    }

    /// Convenience for callers that want the whole stream in the data state
    /// (tests, and anything that does not do tree construction).
    public mutating func tokenize() -> [HTMLToken] {
        var result: [HTMLToken] = []
        result.reserveCapacity(input.count / 20)
        while let token = nextToken() {
            if case .startTag(let name, _, _) = token {
                // Mirror the tree builder's tokenizer switches so a bare
                // `tokenize()` still treats <script>/<style>/<title> as text.
                switch name {
                case "script": contentState = .scriptData
                case "style", "xmp", "iframe", "noembed", "noframes", "noscript": contentState = .rawtext
                case "title", "textarea": contentState = .rcdata
                case "plaintext": contentState = .plaintext
                default: break
                }
            }
            result.append(token)
        }
        return result
    }

    // MARK: - Driver

    private mutating func step() {
        switch contentState {
        case .data: dataState()
        case .rcdata: rcdataState()
        case .rawtext: rawtextState()
        case .scriptData: scriptDataState()
        case .plaintext: plaintextState()
        }
    }

    @inline(__always)
    private mutating func emit(_ token: HTMLToken) { queue.append(token) }

    @inline(__always)
    private mutating func flushText() {
        if !textBytes.isEmpty {
            emit(.text(string(textBytes)))
            textBytes.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - Data state

    private mutating func dataState() {
        textBytes.removeAll(keepingCapacity: true)
        while pos < input.count {
            let b = input[pos]
            if b == Self.lt { break }
            if b == Self.amp {
                let (replacement, end) = scanCharacterReferenceAt(pos, inAttribute: false)
                if let replacement { textBytes.append(contentsOf: Array(replacement.utf8)) } else { textBytes.append(Self.amp) }
                pos = end
                continue
            }
            textBytes.append(b)
            pos += 1
        }
        flushText()
        guard pos < input.count else { return }
        pos += 1 // consume '<'
        tagOpenState()
    }

    /// PLAINTEXT: everything to EOF, NUL replaced.
    private mutating func plaintextState() {
        textBytes.removeAll(keepingCapacity: true)
        while pos < input.count {
            let b = input[pos]
            if b == Self.nul {
                textBytes.append(contentsOf: Self.replacementBytes)
            } else {
                textBytes.append(b)
            }
            pos += 1
        }
        flushText()
    }

    // MARK: - RCDATA / RAWTEXT

    private mutating func rcdataState() { rawLikeState(decodeEntities: true) }
    private mutating func rawtextState() { rawLikeState(decodeEntities: false) }

    private mutating func rawLikeState(decodeEntities: Bool) {
        textBytes.removeAll(keepingCapacity: true)
        while pos < input.count {
            let b = input[pos]
            if b == Self.lt {
                if let consumed = matchAppropriateEndTag() {
                    flushText()
                    pos = consumed
                    contentState = .data
                    endTagFromRawText()
                    return
                }
                textBytes.append(b)
                pos += 1
                continue
            }
            if b == Self.amp, decodeEntities {
                let (replacement, end) = scanCharacterReferenceAt(pos, inAttribute: false)
                if let replacement { textBytes.append(contentsOf: Array(replacement.utf8)) } else { textBytes.append(Self.amp) }
                pos = end
                continue
            }
            if b == Self.nul {
                textBytes.append(contentsOf: Self.replacementBytes)
                pos += 1
                continue
            }
            textBytes.append(b)
            pos += 1
        }
        flushText()
    }

    /// If `pos` is at `</name` where `name` is the appropriate end tag and the
    /// character after it terminates a tag name, returns the index just past
    /// the `</name`. Otherwise nil (the `<` is ordinary text).
    private func matchAppropriateEndTag() -> Int? {
        guard !lastStartTagName.isEmpty else { return nil }
        let start = pos
        guard start + 2 + lastStartTagName.count <= input.count else { return nil }
        guard input[start + 1] == Self.slash else { return nil }
        for (i, b) in lastStartTagName.enumerated() {
            if asciiLower(input[start + 2 + i]) != b { return nil }
        }
        let after = start + 2 + lastStartTagName.count
        guard after < input.count else { return nil }
        let c = input[after]
        guard isWhitespace(c) || c == Self.slash || c == Self.gt else { return nil }
        return after
    }

    /// `pos` sits just after `</name`; finish the tag (attributes on an end tag
    /// are parsed and discarded, per spec) and emit it.
    private mutating func endTagFromRawText() {
        let name = string(lastStartTagName)
        currentAttributes = []
        var selfClosing = false
        parseAttributes(selfClosing: &selfClosing)
        emit(.endTag(name: name))
    }

    // MARK: - Script data

    /// The whole §13.2.5.4–13.2.5.21 escape ladder, written as one loop over
    /// a small mode variable. `<!--` opens an escape in which `<script` opens a
    /// *double* escape where `</script>` no longer closes the element — but a
    /// plain `</script>` in a string literal does close it, which is why
    /// `var s = "</script>"` breaks a real page.
    private enum ScriptMode { case normal, escaped, escapedDash, escapedDashDash, doubleEscaped, doubleEscapedDash, doubleEscapedDashDash }

    private mutating func scriptDataState() {
        textBytes.removeAll(keepingCapacity: true)
        var mode: ScriptMode = .normal

        while pos < input.count {
            let b = input[pos]

            if b == Self.nul {
                textBytes.append(contentsOf: Self.replacementBytes)
                pos += 1
                if mode == .escapedDash || mode == .escapedDashDash { mode = .escaped }
                if mode == .doubleEscapedDash || mode == .doubleEscapedDashDash { mode = .doubleEscaped }
                continue
            }

            if b == Self.lt {
                switch mode {
                case .normal, .escaped, .escapedDash, .escapedDashDash:
                    // `</script` closes the element in every single-escaped mode.
                    if let consumed = matchAppropriateEndTag() {
                        flushText()
                        pos = consumed
                        contentState = .data
                        endTagFromRawText()
                        return
                    }
                    if mode == .normal, pos + 3 < input.count,
                       input[pos + 1] == Self.bang, input[pos + 2] == Self.dash, input[pos + 3] == Self.dash {
                        textBytes.append(contentsOf: Self.escapeOpenBytes)
                        pos += 4
                        mode = .escapedDashDash
                        continue
                    }
                    if mode != .normal, matchesScriptTagAhead() {
                        textBytes.append(contentsOf: Self.scriptOpenBytes)
                        pos += 7
                        mode = .doubleEscaped
                        continue
                    }
                    textBytes.append(b)
                    pos += 1
                    if mode == .escapedDash || mode == .escapedDashDash { mode = .escaped }
                    continue
                case .doubleEscaped, .doubleEscapedDash, .doubleEscapedDashDash:
                    // `</script` only *leaves* the double escape here.
                    if matchesClosingScriptAhead() {
                        textBytes.append(contentsOf: Self.scriptCloseBytes)
                        pos += 8
                        mode = .escaped
                        continue
                    }
                    textBytes.append(b)
                    pos += 1
                    mode = .doubleEscaped
                    continue
                }
            }

            if b == Self.dash {
                textBytes.append(b)
                pos += 1
                switch mode {
                case .normal: break
                case .escaped: mode = .escapedDash
                case .escapedDash, .escapedDashDash: mode = .escapedDashDash
                case .doubleEscaped: mode = .doubleEscapedDash
                case .doubleEscapedDash, .doubleEscapedDashDash: mode = .doubleEscapedDashDash
                }
                continue
            }

            if b == Self.gt {
                textBytes.append(b)
                pos += 1
                // `-->` leaves *both* escape levels: §13.2.5.26 and §13.2.5.28
                // both switch back to the plain script data state.
                if mode == .escapedDashDash || mode == .doubleEscapedDashDash { mode = .normal }
                continue
            }

            textBytes.append(b)
            pos += 1
            switch mode {
            case .escapedDash, .escapedDashDash: mode = .escaped
            case .doubleEscapedDash, .doubleEscapedDashDash: mode = .doubleEscaped
            default: break
            }
        }
        flushText()
    }

    /// `<script` followed by a tag-name terminator, at `pos`.
    private func matchesScriptTagAhead() -> Bool { matchesTagWord(Self.scriptOpenBytes) }

    private func matchesClosingScriptAhead() -> Bool { matchesTagWord(Self.scriptCloseBytes) }

    private func matchesTagWord(_ word: [UInt8]) -> Bool {
        guard pos + word.count <= input.count else { return false }
        var i = 0
        while i < word.count {
            if asciiLower(input[pos + i]) != word[i] { return false }
            i += 1
        }
        guard pos + word.count < input.count else { return true }
        let c = input[pos + word.count]
        return isWhitespace(c) || c == Self.slash || c == Self.gt
    }

    // MARK: - Tag open

    private mutating func tagOpenState() {
        guard pos < input.count else {
            emit(.text("<"))
            return
        }
        let b = input[pos]

        if b == Self.bang {
            markupDeclarationOpen()
            return
        }
        if b == Self.slash {
            pos += 1
            guard pos < input.count else {
                emit(.text("</"))
                return
            }
            let c = input[pos]
            if isASCIIAlpha(c) {
                parseTag(isEnd: true)
                return
            }
            if c == Self.gt {
                // missing-end-tag-name: `</>` is dropped entirely.
                pos += 1
                return
            }
            bogusComment()
            return
        }
        if isASCIIAlpha(b) {
            parseTag(isEnd: false)
            return
        }
        if b == Self.question {
            // unexpected-question-mark-instead-of-tag-name: bogus comment that
            // *includes* the `?`.
            bogusComment()
            return
        }
        // invalid-first-character-of-tag-name: the `<` is literal text.
        emit(.text("<"))
    }

    private mutating func markupDeclarationOpen() {
        // `pos` is at '!'
        if matchAhead(at: pos + 1, Self.commentOpenBytes) {
            pos += 3
            commentState()
            return
        }
        if matchAheadCaseInsensitive(at: pos + 1, Self.doctypeBytes) {
            pos += 8
            doctypeState()
            return
        }
        if matchAhead(at: pos + 1, Self.cdataOpenBytes) {
            if allowCDATA {
                pos += 8
                cdataSection()
            } else {
                // cdata-in-html-content: a comment whose data is "[CDATA[…".
                pos += 1
                bogusComment()
            }
            return
        }
        pos += 1
        bogusComment()
    }

    /// Everything up to the next `>` (or EOF) becomes comment data.
    private mutating func bogusComment() {
        commentBytes.removeAll(keepingCapacity: true)
        while pos < input.count, input[pos] != Self.gt {
            if input[pos] == Self.nul {
                commentBytes.append(contentsOf: Self.replacementBytes)
            } else {
                commentBytes.append(input[pos])
            }
            pos += 1
        }
        if pos < input.count { pos += 1 }
        emit(.comment(string(commentBytes)))
    }

    /// §13.2.5.43–13.2.5.51. `<!-->` and `<!--->` are empty comments; `--!>`
    /// closes one.
    private mutating func commentState() {
        commentBytes.removeAll(keepingCapacity: true)

        // Comment start / comment start dash: an immediate `>` (after zero or
        // one dash) is an abrupt-closing-of-empty-comment.
        if pos < input.count, input[pos] == Self.gt {
            pos += 1
            emit(.comment(""))
            return
        }
        if pos + 1 < input.count, input[pos] == Self.dash, input[pos + 1] == Self.gt {
            pos += 2
            emit(.comment(""))
            return
        }

        while pos < input.count {
            let b = input[pos]
            if b == Self.dash {
                // Count the dash run, then look at what follows.
                var dashes = 0
                var scan = pos
                while scan < input.count, input[scan] == Self.dash {
                    dashes += 1
                    scan += 1
                }
                if scan < input.count, input[scan] == Self.gt, dashes >= 2 {
                    // "--" immediately before ">" closes; extra dashes are data.
                    for _ in 0..<(dashes - 2) { commentBytes.append(Self.dash) }
                    pos = scan + 1
                    emit(.comment(string(commentBytes)))
                    return
                }
                if scan + 1 < input.count, input[scan] == Self.bang, input[scan + 1] == Self.gt, dashes >= 2 {
                    // incorrectly-closed-comment: `--!>` closes too.
                    for _ in 0..<(dashes - 2) { commentBytes.append(Self.dash) }
                    pos = scan + 2
                    emit(.comment(string(commentBytes)))
                    return
                }
                for _ in 0..<dashes { commentBytes.append(Self.dash) }
                pos = scan
                continue
            }
            if b == Self.nul {
                commentBytes.append(contentsOf: Self.replacementBytes)
            } else {
                commentBytes.append(b)
            }
            pos += 1
        }
        // eof-in-comment: emit what we have.
        emit(.comment(string(commentBytes)))
    }

    /// `<![CDATA[ … ]]>` in foreign content: the contents are character tokens.
    private mutating func cdataSection() {
        textBytes.removeAll(keepingCapacity: true)
        while pos < input.count {
            if input[pos] == Self.rbracket, pos + 2 < input.count,
               input[pos + 1] == Self.rbracket, input[pos + 2] == Self.gt {
                pos += 3
                flushText()
                return
            }
            textBytes.append(input[pos])
            pos += 1
        }
        flushText()
    }

    // MARK: - DOCTYPE

    private mutating func doctypeState() {
        var doctype = HTMLDoctype()
        skipWhitespace()
        guard pos < input.count else {
            doctype.forceQuirks = true
            emit(.doctype(doctype))
            return
        }
        if input[pos] == Self.gt {
            pos += 1
            doctype.forceQuirks = true
            emit(.doctype(doctype))
            return
        }

        var nameBytes: [UInt8] = []
        while pos < input.count {
            let b = input[pos]
            if isWhitespace(b) || b == Self.gt { break }
            if b == Self.nul { nameBytes.append(contentsOf: Self.replacementBytes) } else { nameBytes.append(asciiLower(b)) }
            pos += 1
        }
        doctype.name = string(nameBytes)

        skipWhitespace()
        if pos < input.count, input[pos] == Self.gt {
            pos += 1
            emit(.doctype(doctype))
            return
        }
        guard pos < input.count else {
            doctype.forceQuirks = true
            emit(.doctype(doctype))
            return
        }

        if matchAheadCaseInsensitive(at: pos, Self.publicBytes) {
            pos += 6
            skipWhitespace()
            if let id = doctypeIdentifier() {
                doctype.publicId = id
            } else {
                doctype.forceQuirks = true
                skipToGT()
                emit(.doctype(doctype))
                return
            }
            skipWhitespace()
            if pos < input.count, input[pos] == Self.gt {
                pos += 1
                emit(.doctype(doctype))
                return
            }
            if let id = doctypeIdentifier() {
                doctype.systemId = id
            } else {
                doctype.forceQuirks = true
                skipToGT()
                emit(.doctype(doctype))
                return
            }
        } else if matchAheadCaseInsensitive(at: pos, Self.systemBytes) {
            pos += 6
            skipWhitespace()
            if let id = doctypeIdentifier() {
                doctype.systemId = id
            } else {
                doctype.forceQuirks = true
                skipToGT()
                emit(.doctype(doctype))
                return
            }
        } else {
            // invalid-character-sequence-after-doctype-name
            doctype.forceQuirks = true
            skipToGT()
            emit(.doctype(doctype))
            return
        }

        // After the identifiers: anything but `>` is a bogus DOCTYPE, which
        // notably does *not* force quirks.
        skipWhitespace()
        skipToGT()
        emit(.doctype(doctype))
    }

    /// A quoted public/system identifier, or nil when the quote is missing.
    private mutating func doctypeIdentifier() -> String? {
        guard pos < input.count else { return nil }
        let quote = input[pos]
        guard quote == Self.dquote || quote == Self.squote else { return nil }
        pos += 1
        var bytes: [UInt8] = []
        while pos < input.count, input[pos] != quote {
            if input[pos] == Self.gt { break } // abrupt-doctype-…-identifier
            if input[pos] == Self.nul {
                bytes.append(contentsOf: Self.replacementBytes)
            } else {
                bytes.append(input[pos])
            }
            pos += 1
        }
        if pos < input.count, input[pos] == quote { pos += 1 }
        return string(bytes)
    }

    private mutating func skipToGT() {
        while pos < input.count, input[pos] != Self.gt { pos += 1 }
        if pos < input.count { pos += 1 }
    }

    // MARK: - Tags

    private mutating func parseTag(isEnd: Bool) {
        tagNameBytes.removeAll(keepingCapacity: true)
        currentAttributes = []
        var selfClosing = false

        while pos < input.count {
            let b = input[pos]
            if isWhitespace(b) || b == Self.slash || b == Self.gt { break }
            if b == Self.nul { tagNameBytes.append(contentsOf: Self.replacementBytes) } else { tagNameBytes.append(asciiLower(b)) }
            pos += 1
        }
        let name = string(tagNameBytes)

        parseAttributes(selfClosing: &selfClosing)

        if isEnd {
            emit(.endTag(name: name))
        } else {
            lastStartTagName = tagNameBytes
            emit(.startTag(name: name, attributes: currentAttributes, selfClosing: selfClosing))
        }
    }

    private mutating func parseAttributes(selfClosing: inout Bool) {
        while pos < input.count {
            skipWhitespace()
            guard pos < input.count else { return }
            let b = input[pos]

            if b == Self.gt {
                pos += 1
                return
            }
            if b == Self.slash {
                pos += 1
                skipWhitespace()
                if pos < input.count, input[pos] == Self.gt {
                    selfClosing = true
                    pos += 1
                    return
                }
                continue
            }

            attrNameBytes.removeAll(keepingCapacity: true)
            if b == Self.eq {
                // unexpected-equals-sign-before-attribute-name: `=` starts the name.
                attrNameBytes.append(Self.eq)
                pos += 1
            }
            while pos < input.count {
                let c = input[pos]
                if isWhitespace(c) || c == Self.eq || c == Self.gt || c == Self.slash { break }
                if c == Self.nul { attrNameBytes.append(contentsOf: Self.replacementBytes) } else { attrNameBytes.append(asciiLower(c)) }
                pos += 1
            }
            guard !attrNameBytes.isEmpty else {
                pos += 1
                continue
            }

            skipWhitespace()
            attrValueBytes.removeAll(keepingCapacity: true)
            var value = ""
            if pos < input.count, input[pos] == Self.eq {
                pos += 1
                skipWhitespace()
                value = parseAttributeValue()
            }

            let name = string(attrNameBytes)
            // duplicate-attribute: the first one wins. A linear scan beats a
            // Set here — tags carry a handful of attributes, not hundreds.
            if !currentAttributes.contains(where: { $0.name == name }) {
                currentAttributes.append(HTMLAttribute(name: name, value: value))
            }
        }
    }

    private mutating func parseAttributeValue() -> String {
        attrValueBytes.removeAll(keepingCapacity: true)
        guard pos < input.count else { return "" }
        let b = input[pos]

        if b == Self.dquote || b == Self.squote {
            let quote = b
            pos += 1
            while pos < input.count, input[pos] != quote {
                if input[pos] == Self.amp {
                    let (replacement, end) = scanCharacterReferenceAt(pos, inAttribute: true)
                    if let replacement { attrValueBytes.append(contentsOf: Array(replacement.utf8)) } else { attrValueBytes.append(Self.amp) }
                    pos = end
                    continue
                }
                if input[pos] == Self.nul {
                    attrValueBytes.append(contentsOf: Self.replacementBytes)
                } else {
                    attrValueBytes.append(input[pos])
                }
                pos += 1
            }
            if pos < input.count { pos += 1 }
            return string(attrValueBytes)
        }

        // Unquoted: only whitespace and `>` end it. `/` is an ordinary
        // character here, so `<a href=/foo/>` has href="/foo/".
        while pos < input.count {
            let c = input[pos]
            if isWhitespace(c) || c == Self.gt { break }
            if c == Self.amp {
                let (replacement, end) = scanCharacterReferenceAt(pos, inAttribute: true)
                if let replacement { attrValueBytes.append(contentsOf: Array(replacement.utf8)) } else { attrValueBytes.append(Self.amp) }
                pos = end
                continue
            }
            if c == Self.nul {
                attrValueBytes.append(contentsOf: Self.replacementBytes)
            } else {
                attrValueBytes.append(c)
            }
            pos += 1
        }
        return string(attrValueBytes)
    }

    // MARK: - Character references (§13.2.5.72–13.2.5.80)

    /// Scans the reference starting at `start` (which is the `&`). Returns the
    /// replacement text, or nil when the source text should be kept literally,
    /// together with the index just past what was consumed. Non-mutating so
    /// callers can append straight into their own scratch buffer.
    private func scanCharacterReferenceAt(_ start: Int, inAttribute: Bool) -> (replacement: String?, end: Int) {
        var index = start + 1
        guard index < input.count else { return (nil, start + 1) }

        if input[index] == Self.hash {
            return scanNumericCharacterReferenceAt(start)
        }
        guard isASCIIAlphanumeric(input[index]) else { return (nil, start + 1) }

        // Longest match, `;` included when present.
        let nameStart = index
        let limit = min(input.count, index + HTMLEntities.maxNameLength)
        while index < limit, isASCIIAlphanumeric(input[index]) { index += 1 }
        let scan = index
        let hasSemi = scan < input.count && input[scan] == Self.semi

        if hasSemi {
            let name = string(Array(input[nameStart..<scan])) + ";"
            if let replacement = HTMLEntities.lookup(name) {
                return (replacement, scan + 1)
            }
        }
        // Legacy, semicolon-less names: `&amp` is `&`, but `&ampx` stays literal
        // inside an attribute (ambiguous ampersand) and is `&x` elsewhere.
        var length = min(scan - nameStart, HTMLEntities.maxLegacyNameLength)
        while length > 0 {
            let name = string(Array(input[nameStart..<(nameStart + length)]))
            if let replacement = HTMLEntities.lookup(name) {
                let next = nameStart + length
                if inAttribute, next < input.count,
                   input[next] == Self.eq || isASCIIAlphanumeric(input[next]) {
                    break
                }
                return (replacement, next)
            }
            length -= 1
        }
        return (nil, start + 1)
    }

    /// `start` is the `&`; `start + 1` is `#`.
    private func scanNumericCharacterReferenceAt(_ start: Int) -> (replacement: String?, end: Int) {
        var scan = start + 2
        var value: UInt32 = 0
        var digits = 0
        var overflow = false

        if scan < input.count, input[scan] == 0x78 || input[scan] == 0x58 { // x X
            scan += 1
            while scan < input.count, let d = hexDigit(input[scan]) {
                if value <= 0x10FFFF { value = value &* 16 &+ UInt32(d) } else { overflow = true }
                digits += 1
                scan += 1
            }
        } else {
            while scan < input.count, input[scan] >= 0x30, input[scan] <= 0x39 {
                if value <= 0x10FFFF { value = value &* 10 &+ UInt32(input[scan] - 0x30) } else { overflow = true }
                digits += 1
                scan += 1
            }
        }
        guard digits > 0 else { return (nil, start + 1) }
        if scan < input.count, input[scan] == Self.semi { scan += 1 }
        return (Self.scalarText(for: overflow ? 0xFFFFFFFF : value), scan)
    }

    /// §13.2.5.80's fixups: NUL, out-of-range and surrogates become U+FFFD, and
    /// the C1 range is remapped through Windows-1252 — which is why `&#153;` is
    /// a trademark sign and not an unprintable control.
    static func scalarText(for code: UInt32) -> String {
        if code == 0 || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF) {
            return "\u{FFFD}"
        }
        if code >= 0x80, code <= 0x9F, let mapped = windows1252[Int(code - 0x80)] {
            return String(Unicode.Scalar(mapped)!)
        }
        guard let scalar = Unicode.Scalar(code) else { return "\u{FFFD}" }
        return String(scalar)
    }

    /// Windows-1252 replacements for C1 controls (§13.2.5.80's table). `nil`
    /// entries are the eight unassigned slots, which stay as the control.
    static let windows1252: [UInt32?] = [
        0x20AC, nil, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, nil, 0x017D, nil,
        nil, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, nil, 0x017E, 0x0178,
    ]

    // MARK: - Byte helpers

    @inline(__always)
    private func isWhitespace(_ b: UInt8) -> Bool {
        b == Self.space || b == Self.tab || b == Self.nl || b == Self.cr || b == Self.ff
    }

    @inline(__always)
    private func asciiLower(_ b: UInt8) -> UInt8 { (b >= 0x41 && b <= 0x5A) ? b | 0x20 : b }

    @inline(__always)
    private func isASCIIAlpha(_ b: UInt8) -> Bool {
        (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A)
    }

    @inline(__always)
    private func isASCIIAlphanumeric(_ b: UInt8) -> Bool {
        isASCIIAlpha(b) || (b >= 0x30 && b <= 0x39)
    }

    @inline(__always)
    private func hexDigit(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x61...0x66: return b - 0x61 + 10
        case 0x41...0x46: return b - 0x41 + 10
        default: return nil
        }
    }

    private mutating func skipWhitespace() {
        while pos < input.count, isWhitespace(input[pos]) { pos += 1 }
    }

    private func matchAhead(at index: Int, _ bytes: [UInt8]) -> Bool {
        guard index + bytes.count <= input.count else { return false }
        var i = 0
        while i < bytes.count {
            if input[index + i] != bytes[i] { return false }
            i += 1
        }
        return true
    }

    /// `bytes` must already be lowercase.
    private func matchAheadCaseInsensitive(at index: Int, _ bytes: [UInt8]) -> Bool {
        guard index + bytes.count <= input.count else { return false }
        var i = 0
        while i < bytes.count {
            if asciiLower(input[index + i]) != bytes[i] { return false }
            i += 1
        }
        return true
    }

    private func string(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}
