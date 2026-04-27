import Foundation

/// Builds a DOM tree from HTML tokens.
public struct HTMLParser: Sendable {

    /// Parse an HTML string into a DOM tree.
    public static func parse(_ html: String) -> DOMNode {
        var tokenizer = HTMLTokenizer(html)
        let tokens = tokenizer.tokenize()
        return buildTree(from: tokens)
    }

    private static func buildTree(from tokens: [HTMLToken]) -> DOMNode {
        let document = DOMNode.document()
        var openElements: [DOMNode] = [document]

        for token in tokens {
            switch token {
            case .doctype:
                // Noted but no node created
                break

            case .startTag(let name, let attributes, let selfClosing):
                // Tag and attribute names are already lowercased by the tokenizer.
                let attrDict = Dictionary(
                    attributes.map { ($0.name, $0.value) },
                    uniquingKeysWith: { first, _ in first }
                )
                let element = DOMNode.element(tag: name, attributes: attrDict)

                // Auto-close certain elements per HTML5 rules
                autoCloseIfNeeded(tag: name, stack: &openElements)

                // Append to current parent
                openElements.last?.appendChild(element)

                // Push onto stack unless void or self-closing
                let isVoid = DOMNode.voidElements.contains(name)
                if !isVoid && !selfClosing {
                    openElements.append(element)
                }

            case .endTag(let name):
                // Tag names are already lowercased by the tokenizer.
                if let index = openElements.lastIndex(where: { $0.tagName == name }) {
                    openElements.removeSubrange(index...)
                }
                // If no match, silently ignore (lenient parsing)

            case .text(let content):
                let textNode = DOMNode.text(content)
                openElements.last?.appendChild(textNode)

            case .comment(let content):
                let commentNode = DOMNode.comment(content)
                openElements.last?.appendChild(commentNode)
            }
        }

        return document
    }

    /// Handle implicit closing rules for HTML elements.
    private static func autoCloseIfNeeded(tag: String, stack: inout [DOMNode]) {
        switch tag {
        case "p":
            if stack.last?.tagName == "p" { stack.removeLast() }
        case "li":
            if stack.last?.tagName == "li" { stack.removeLast() }
        case "td", "th":
            if let last = stack.last?.tagName, last == "td" || last == "th" {
                stack.removeLast()
            }
        case "tr":
            // Close open td/th first, then open tr
            if let last = stack.last?.tagName, last == "td" || last == "th" {
                stack.removeLast()
            }
            if stack.last?.tagName == "tr" { stack.removeLast() }
        case "dt", "dd":
            if let last = stack.last?.tagName, last == "dt" || last == "dd" {
                stack.removeLast()
            }
        case "thead", "tbody", "tfoot":
            if let last = stack.last?.tagName, last == "thead" || last == "tbody" || last == "tfoot" {
                stack.removeLast()
            }
        case "option":
            if stack.last?.tagName == "option" { stack.removeLast() }
        case "head":
            // Close head if another head or body opens
            break
        case "body":
            if stack.last?.tagName == "head" { stack.removeLast() }
        default:
            break
        }
    }
}
