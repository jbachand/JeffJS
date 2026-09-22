import Foundation

/// A single attribute on an HTML tag. Names are ASCII-lowercased by the
/// tokenizer; foreign-content adjustment (`viewBox`, `xlink:href`) happens in
/// the tree builder, which is the only place that knows the namespace.
public struct HTMLAttribute: Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// A `<!DOCTYPE …>` token. Everything the quirks-mode determination in
/// HTML Standard §13.2.6.4.1 needs is preserved, including whether the
/// tokenizer bailed out mid-token (`forceQuirks`).
public struct HTMLDoctype: Sendable {
    public var name: String?
    public var publicId: String?
    public var systemId: String?
    public var forceQuirks: Bool

    public init(name: String? = nil, publicId: String? = nil, systemId: String? = nil, forceQuirks: Bool = false) {
        self.name = name
        self.publicId = publicId
        self.systemId = systemId
        self.forceQuirks = forceQuirks
    }
}

/// A token produced by the HTML tokenizer.
public enum HTMLToken: Sendable {
    case doctype(HTMLDoctype)
    case startTag(name: String, attributes: [HTMLAttribute], selfClosing: Bool)
    case endTag(name: String)
    case text(String)
    case comment(String)
}
