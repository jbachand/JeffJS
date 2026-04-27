import Foundation

/// A single attribute on an HTML tag.
public struct HTMLAttribute: Sendable {
    public let name: String
    public let value: String
}

/// A token produced by the HTML tokenizer.
public enum HTMLToken: Sendable {
    case doctype(name: String)
    case startTag(name: String, attributes: [HTMLAttribute], selfClosing: Bool)
    case endTag(name: String)
    case text(String)
    case comment(String)
}
