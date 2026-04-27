import Foundation

/// A state-machine tokenizer that converts an HTML string into tokens.
/// Uses UTF-8 byte array for fast O(1) access and minimal allocations.
public struct HTMLTokenizer: Sendable {

    private let input: [UInt8]
    private var pos: Int = 0
    private var tokens: [HTMLToken] = []

    // Byte buffers — avoid String allocations during hot loops
    private var textBytes: [UInt8] = []
    private var tagNameBytes: [UInt8] = []
    private var attrNameBytes: [UInt8] = []
    private var attrValueBytes: [UInt8] = []
    private var currentAttributes: [HTMLAttribute] = []
    private var isEndTag: Bool = false
    private var isSelfClosing: Bool = false
    private var commentBytes: [UInt8] = []

    // ASCII constants
    private static let lt: UInt8 = 0x3C       // <
    private static let gt: UInt8 = 0x3E       // >
    private static let amp: UInt8 = 0x26      // &
    private static let bang: UInt8 = 0x21     // !
    private static let slash: UInt8 = 0x2F    // /
    private static let eq: UInt8 = 0x3D       // =
    private static let dquote: UInt8 = 0x22   // "
    private static let squote: UInt8 = 0x27   // '
    private static let dash: UInt8 = 0x2D     // -
    private static let semi: UInt8 = 0x3B     // ;
    private static let hash: UInt8 = 0x23     // #
    private static let space: UInt8 = 0x20
    private static let tab: UInt8 = 0x09
    private static let nl: UInt8 = 0x0A
    private static let cr: UInt8 = 0x0D

    public init(_ html: String) {
        self.input = Array(html.utf8)
        textBytes.reserveCapacity(256)
        tagNameBytes.reserveCapacity(32)
        attrNameBytes.reserveCapacity(32)
        attrValueBytes.reserveCapacity(128)
        commentBytes.reserveCapacity(64)
    }

    // MARK: - Public API

    public mutating func tokenize() -> [HTMLToken] {
        tokens.reserveCapacity(input.count / 20) // rough estimate: 1 token per 20 bytes
        while pos < input.count {
            let b = input[pos]
            if b == Self.lt {
                flushText()
                pos += 1
                parseTag()
            } else {
                textBytes.append(b)
                pos += 1
            }
        }
        flushText()
        return tokens
    }

    // MARK: - Tag Parsing

    private mutating func parseTag() {
        guard pos < input.count else { return }
        let b = input[pos]

        // Comment: <!--
        if b == Self.bang {
            if matchAhead("!--") {
                pos += 3
                parseComment()
                return
            }
            if matchAheadCaseInsensitive("!doctype") {
                pos += 8
                parseDoctype()
                return
            }
            skipToClosingAngle()
            return
        }

        // End tag: </
        if b == Self.slash {
            pos += 1
            isEndTag = true
            parseTagName()
            return
        }

        // Start tag
        isEndTag = false
        parseTagName()
    }

    private mutating func parseComment() {
        commentBytes.removeAll(keepingCapacity: true)
        while pos < input.count {
            if input[pos] == Self.dash && matchAhead("-->") {
                pos += 3
                tokens.append(.comment(stringFromBytes(commentBytes)))
                return
            }
            commentBytes.append(input[pos])
            pos += 1
        }
        tokens.append(.comment(stringFromBytes(commentBytes)))
    }

    private mutating func parseDoctype() {
        skipWhitespace()
        var nameBytes: [UInt8] = []
        while pos < input.count && input[pos] != Self.gt {
            nameBytes.append(input[pos])
            pos += 1
        }
        if pos < input.count { pos += 1 }
        tokens.append(.doctype(name: stringFromBytes(nameBytes).trimmingCharacters(in: .whitespaces)))
    }

    private mutating func parseTagName() {
        skipWhitespace()
        tagNameBytes.removeAll(keepingCapacity: true)
        currentAttributes = []
        isSelfClosing = false

        while pos < input.count {
            let b = input[pos]
            if isWhitespace(b) || b == Self.slash || b == Self.gt {
                break
            }
            // Inline ASCII lowercase
            tagNameBytes.append(asciiLower(b))
            pos += 1
        }

        let tagName = stringFromBytes(tagNameBytes)

        parseAttributes()

        // Check for raw text elements (script, style)
        if !isEndTag && (tagName == "script" || tagName == "style") {
            emitTag(name: tagName)
            parseRawText(endTag: tagName)
            return
        }

        emitTag(name: tagName)
    }

    private mutating func parseAttributes() {
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
                isSelfClosing = true
                skipWhitespace()
                if pos < input.count && input[pos] == Self.gt {
                    pos += 1
                }
                return
            }

            // Parse attribute name
            attrNameBytes.removeAll(keepingCapacity: true)
            while pos < input.count {
                let c = input[pos]
                if c == Self.eq || isWhitespace(c) || c == Self.gt || c == Self.slash {
                    break
                }
                attrNameBytes.append(asciiLower(c))
                pos += 1
            }

            guard !attrNameBytes.isEmpty else {
                pos += 1
                continue
            }

            skipWhitespace()

            // Check for = sign
            if pos < input.count && input[pos] == Self.eq {
                pos += 1
                skipWhitespace()
                attrValueBytes.removeAll(keepingCapacity: true)
                parseAttributeValue()
            } else {
                attrValueBytes.removeAll(keepingCapacity: true)
            }

            let name = stringFromBytes(attrNameBytes)
            let value = decodeEntities(attrValueBytes)
            currentAttributes.append(HTMLAttribute(name: name, value: value))
        }
    }

    private mutating func parseAttributeValue() {
        guard pos < input.count else { return }
        let b = input[pos]

        if b == Self.dquote || b == Self.squote {
            let quote = b
            pos += 1
            while pos < input.count && input[pos] != quote {
                attrValueBytes.append(input[pos])
                pos += 1
            }
            if pos < input.count { pos += 1 }
            return
        }

        // Unquoted value
        while pos < input.count {
            let c = input[pos]
            if isWhitespace(c) || c == Self.gt || c == Self.slash {
                break
            }
            attrValueBytes.append(c)
            pos += 1
        }
    }

    private mutating func parseRawText(endTag: String) {
        var rawBytes: [UInt8] = []
        rawBytes.reserveCapacity(1024)
        let endPattern = "</\(endTag)"

        while pos < input.count {
            if input[pos] == Self.lt && matchAheadCaseInsensitive(endPattern) {
                pos += endPattern.count
                while pos < input.count && input[pos] != Self.gt {
                    pos += 1
                }
                if pos < input.count { pos += 1 }

                tokens.append(.text(stringFromBytes(rawBytes)))
                tokens.append(.endTag(name: endTag))
                return
            }
            rawBytes.append(input[pos])
            pos += 1
        }
        if !rawBytes.isEmpty {
            tokens.append(.text(stringFromBytes(rawBytes)))
        }
    }

    // MARK: - Helpers

    private mutating func emitTag(name: String) {
        guard !name.isEmpty else { return }
        if isEndTag {
            tokens.append(.endTag(name: name))
        } else {
            tokens.append(.startTag(
                name: name,
                attributes: currentAttributes,
                selfClosing: isSelfClosing
            ))
        }
    }

    private mutating func flushText() {
        if !textBytes.isEmpty {
            let decoded = decodeEntities(textBytes)
            tokens.append(.text(decoded))
            textBytes.removeAll(keepingCapacity: true)
        }
    }

    private func matchAhead(_ suffix: String) -> Bool {
        let suffixBytes = Array(suffix.utf8)
        guard pos + suffixBytes.count <= input.count else { return false }
        for (i, b) in suffixBytes.enumerated() {
            if input[pos + i] != b { return false }
        }
        return true
    }

    private func matchAheadCaseInsensitive<S: StringProtocol>(_ suffix: S) -> Bool {
        let suffixBytes = Array(suffix.utf8)
        guard pos + suffixBytes.count <= input.count else { return false }
        for (i, b) in suffixBytes.enumerated() {
            if asciiLower(input[pos + i]) != asciiLower(b) { return false }
        }
        return true
    }

    @inline(__always)
    private func isWhitespace(_ b: UInt8) -> Bool {
        b == Self.space || b == Self.tab || b == Self.nl || b == Self.cr
    }

    @inline(__always)
    private func asciiLower(_ b: UInt8) -> UInt8 {
        (b >= 0x41 && b <= 0x5A) ? b | 0x20 : b
    }

    private mutating func skipWhitespace() {
        while pos < input.count && isWhitespace(input[pos]) {
            pos += 1
        }
    }

    private mutating func skipToClosingAngle() {
        while pos < input.count && input[pos] != Self.gt {
            pos += 1
        }
        if pos < input.count { pos += 1 }
    }

    private func stringFromBytes(_ bytes: [UInt8]) -> String {
        String(unsafeUninitializedCapacity: bytes.count) { buffer in
            _ = buffer.initialize(from: bytes)
            return bytes.count
        }
    }

    // MARK: - Entity Decoding (operates on byte buffers)

    private func decodeEntities(_ bytes: [UInt8]) -> String {
        // Fast path: no ampersand in the buffer
        guard bytes.contains(Self.amp) else {
            return stringFromBytes(bytes)
        }

        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var i = 0

        while i < bytes.count {
            if bytes[i] == Self.amp {
                i += 1
                var entityBytes: [UInt8] = []
                while i < bytes.count {
                    let b = bytes[i]
                    if b == Self.semi {
                        i += 1
                        break
                    }
                    entityBytes.append(b)
                    if entityBytes.count > 10 { break }
                    i += 1
                }
                let entity = stringFromBytes(entityBytes)
                if let decoded = Self.resolveEntity(entity) {
                    var utf8 = [UInt8]()
                    for byte in String(decoded).utf8 { utf8.append(byte) }
                    result.append(contentsOf: utf8)
                } else {
                    result.append(Self.amp)
                    result.append(contentsOf: entityBytes)
                    result.append(Self.semi)
                }
            } else {
                result.append(bytes[i])
                i += 1
            }
        }
        return stringFromBytes(result)
    }

    private static func resolveEntity(_ entity: String) -> Character? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        case "copy": return "\u{00A9}"
        case "reg": return "\u{00AE}"
        case "mdash": return "\u{2014}"
        case "ndash": return "\u{2013}"
        case "laquo": return "\u{00AB}"
        case "raquo": return "\u{00BB}"
        case "bull": return "\u{2022}"
        case "hellip": return "\u{2026}"
        case "trade": return "\u{2122}"
        default:
            break
        }

        // Numeric entities: &#123; or &#x7B;
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            let hex = String(entity.dropFirst(2))
            if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                return Character(scalar)
            }
        } else if entity.hasPrefix("#") {
            let dec = String(entity.dropFirst())
            if let code = UInt32(dec), let scalar = Unicode.Scalar(code) {
                return Character(scalar)
            }
        }

        return nil
    }
}
