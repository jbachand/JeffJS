// JeffJSDOMBridge+InlineStyle.swift
// JeffJS DOM bridge — `element.style` (CSSOM §6.7 CSSStyleDeclaration) over a
// parsed declaration block kept per element, with the CSS semantics supplied
// by the host.
//
// The engine does not parse CSS values (it has no property grammars), so a
// host that wants CSSOM semantics — invalid values ignored, WebKit's `cssText`
// serialisation, shorthands replacing their longhands — used to redefine
// `setProperty` & co. in JS over three natives: read the `style` attribute,
// parse + edit + serialise it in the host, write the attribute back. Every
// property write re-parsed the whole inline style (React Natively measured
// 15–70 µs per `el.style.x = v` on Facebook / Instagram).
//
// With `inlineStyleHost` set before the style prototype is built, the
// prototype's `setProperty`, `removeProperty`, `getPropertyValue`,
// `getPropertyPriority` and `cssText` are natives over a host block
// (`JeffJSInlineStyleBlock`) cached per element: a write edits the block and
// stores its serialisation as the `style` attribute through the attribute
// mutation primitive (`setAttributeValue`: the MutationObserver record with
// the old value, attribute reactions, then the host's mutation callback), so
// one property write is one native call and one parse of the new value. The
// cached block is valid while the attribute is the text it produced or was
// parsed from; any other change of `style` (setAttribute, removeAttribute,
// innerHTML of a parent, the parser) makes the next access parse it again.
//
// Without a host nothing changes: the engine's own key/value natives stay.

import Foundation

/// A parsed inline declaration block (one element's `style` attribute). The
/// host owns the CSS semantics; the engine only calls these and stores
/// `cssText` as the attribute after a change.
nonisolated public protocol JeffJSInlineStyleBlock: AnyObject {
    /// CSSOM `setProperty(name, value, priority)` (an empty `value` removes).
    /// Edits the block and returns true when the attribute must be written;
    /// false when the call changes nothing (an invalid value, a bad priority,
    /// removing an absent property).
    func setProperty(_ name: String, value: String, priority: String) -> Bool
    /// CSSOM `getPropertyValue(name)` ("" when absent).
    func propertyValue(_ name: String) -> String
    /// CSSOM `getPropertyPriority(name)` ("important" or "").
    func propertyPriority(_ name: String) -> String
    /// The serialised block (`cssText`, and the attribute value after a change).
    var cssText: String { get }
}

/// Makes a host block from a `style` attribute value (or a `cssText` write).
nonisolated public protocol JeffJSInlineStyleHost: AnyObject {
    func parseInlineStyle(_ text: String) -> JeffJSInlineStyleBlock
}

/// One element's cached block and the attribute text it stands for.
nonisolated final class JeffJSInlineStyleEntry {
    var text: String
    let block: JeffJSInlineStyleBlock
    init(text: String, block: JeffJSInlineStyleBlock) {
        self.text = text
        self.block = block
    }
}

extension JeffJSDOMBridge {

    /// The cached block for `node`, parsed again when its `style` attribute is
    /// no longer the text the cache stands for.
    func inlineStyleBlock(for node: DOMNode, host: JeffJSInlineStyleHost) -> JeffJSInlineStyleBlock {
        let text = node.attributeValue("style") ?? ""
        if let entry = inlineStyleEntries[node.id], entry.text == text { return entry.block }
        let block = host.parseInlineStyle(text)
        inlineStyleEntries[node.id] = JeffJSInlineStyleEntry(text: text, block: block)
        return block
    }

    /// Stores a changed block as `node`'s `style` attribute (the attribute
    /// mutation primitive: record, reactions) and tells the host.
    func commitInlineStyle(_ block: JeffJSInlineStyleBlock, for node: DOMNode) {
        let text = block.cssText
        setAttributeValue(node, name: "style", value: text)
        if let entry = inlineStyleEntries[node.id], entry.block === block {
            entry.text = text
        } else {
            inlineStyleEntries[node.id] = JeffJSInlineStyleEntry(text: text, block: block)
        }
        notifyMutation(for: node)
    }

    /// JS `String(v)` for the CSSOM glue's arguments (a Symbol reads as its
    /// descriptive string, as `String(sym)` does). nil = exception pending.
    private func cssomString(_ ctx: JeffJSContext, _ v: JeffJSValue) -> String? {
        if v.isSymbol {
            let global = ctx.getGlobalObject()
            let stringFn = ctx.getPropertyStr(obj: global, name: "String")
            global.freeValue()
            let r = ctx.call(stringFn, this: .undefined, args: [v])
            stringFn.freeValue()
            defer { r.freeValue() }
            if r.isException { return nil }
            return ctx.toSwiftString(r)
        }
        return ctx.toSwiftString(v)
    }

    /// Replaces the style prototype's CSSOM members with natives over the
    /// host's blocks (see the file header). WebIDL operations and attributes:
    /// enumerable, configurable, writable methods.
    func installHostInlineStyleMembers(on proto: JeffJSValue, ctx: JeffJSContext) {
        func method(_ name: String, length: Int, _ fn: @escaping JeffJSNativeFunc) {
            let f = ctx.newCFunction(fn, name: name, length: length)
            let atom = ctx.rt.findAtom(name)
            ctx.defineOrReplaceOwnProperty(proto, atom: atom, value: f,
                                           flags: JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE)
            ctx.rt.freeAtom(atom)
            f.freeValue()
        }
        func illegal(_ ctx: JeffJSContext, _ name: String) -> JeffJSValue {
            ctx.throwTypeError(message: "Can only call CSSStyleDeclaration.\(name) on instances of CSSStyleDeclaration")
        }
        let exception = JeffJSValue.exception

        // setProperty(name, value, priority): String(name), null value = "",
        // null / undefined priority = "".
        method("setProperty", length: 3) { [weak self] ctx, thisVal, args in
            guard let self, let host = self.inlineStyleHost else { return .undefined }
            guard let node = self.extractNode(from: thisVal) else { return illegal(ctx, "setProperty") }
            guard let name = self.cssomString(ctx, args.first ?? .undefined) else { return exception }
            let v = args.count > 1 ? args[1] : .undefined
            let value: String
            if v.isNull { value = "" } else { guard let s = self.cssomString(ctx, v) else { return exception }; value = s }
            let p = args.count > 2 ? args[2] : .undefined
            let priority: String
            if p.isNull || p.isUndefined { priority = "" } else { guard let s = self.cssomString(ctx, p) else { return exception }; priority = s }
            let block = self.inlineStyleBlock(for: node, host: host)
            if block.setProperty(name, value: value, priority: priority) { self.commitInlineStyle(block, for: node) }
            return .undefined
        }

        // removeProperty(name) -> the old value.
        method("removeProperty", length: 1) { [weak self] ctx, thisVal, args in
            guard let self, let host = self.inlineStyleHost else { return .undefined }
            guard let node = self.extractNode(from: thisVal) else { return illegal(ctx, "removeProperty") }
            guard let name = self.cssomString(ctx, args.first ?? .undefined) else { return exception }
            let block = self.inlineStyleBlock(for: node, host: host)
            let old = block.propertyValue(name)
            if block.setProperty(name, value: "", priority: "") { self.commitInlineStyle(block, for: node) }
            return ctx.newStringValue(old)
        }

        method("getPropertyValue", length: 1) { [weak self] ctx, thisVal, args in
            guard let self, let host = self.inlineStyleHost else { return .undefined }
            guard let node = self.extractNode(from: thisVal) else { return illegal(ctx, "getPropertyValue") }
            guard let name = self.cssomString(ctx, args.first ?? .undefined) else { return exception }
            return ctx.newStringValue(self.inlineStyleBlock(for: node, host: host).propertyValue(name))
        }

        method("getPropertyPriority", length: 1) { [weak self] ctx, thisVal, args in
            guard let self, let host = self.inlineStyleHost else { return .undefined }
            guard let node = self.extractNode(from: thisVal) else { return illegal(ctx, "getPropertyPriority") }
            guard let name = self.cssomString(ctx, args.first ?? .undefined) else { return exception }
            return ctx.newStringValue(self.inlineStyleBlock(for: node, host: host).propertyPriority(name))
        }

        // cssText: the serialised block; a write parses the new text and
        // stores its serialisation (invalid declarations dropped by the host).
        let getter = ctx.newCFunction({ [weak self] ctx, thisVal, _ in
            guard let self, let host = self.inlineStyleHost else { return ctx.newStringValue("") }
            guard let node = self.extractNode(from: thisVal) else { return illegal(ctx, "cssText") }
            return ctx.newStringValue(self.inlineStyleBlock(for: node, host: host).cssText)
        }, name: "get cssText", length: 0)
        let setter = ctx.newCFunction({ [weak self] ctx, thisVal, args in
            guard let self, let host = self.inlineStyleHost else { return .undefined }
            guard let node = self.extractNode(from: thisVal) else { return illegal(ctx, "cssText") }
            let v = args.first ?? .undefined
            let text: String
            if v.isNull || v.isUndefined { text = "" } else { guard let s = self.cssomString(ctx, v) else { return exception }; text = s }
            self.commitInlineStyle(host.parseInlineStyle(text), for: node)
            return .undefined
        }, name: "set cssText", length: 1)
        ctx.setPropertyGetSet(obj: proto, name: "cssText", getter: getter, setter: setter)
    }
}
