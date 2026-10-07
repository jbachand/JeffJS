// JeffJSDOMBridge+CharacterData.swift
// JeffJS — DOM §4.10 interface CharacterData and §4.11 interface Text.
//
// Text and Comment wrappers had no CharacterData members of their own: `data`
// was the shared element prototype's accessor, and `length`, `substringData`,
// `appendData`, `insertData`, `deleteData`, `replaceData`, `splitText` and
// `wholeText` did not exist in the engine at all. A host's platform-surface
// pass (React Natively's `elementIfaces`) makes `CharacterData.prototype` /
// `Text.prototype` objects for the wrappers (`__rnSetNodeInterfaces`), and the
// stubs it found there (`data: ''`, `length: 0`, no-op methods) shadowed the
// working accessor: every text node read `data === ""`, a write created an own
// property and queued no MutationObserver record (rung 15 js09 / m11).
//
// Now the members are native and installed on the interface prototypes: the
// host's when it hands them over, else the engine's own `Text` / `Comment`
// wrapper prototypes (chained to the shared element prototype through one
// CharacterData prototype). Every change goes through "replace data" (DOM
// §4.10): UTF-16 offsets and counts (WebIDL `unsigned long`), IndexSizeError
// past the end, a characterData record with the old value, then the host's
// mutation callback (the renderer / a <style>'s text). Live ranges are not
// updated (the engine has no live Range).
//
// Strings are stored as Swift Strings: a split inside a surrogate pair cannot
// keep the lone halves (each becomes U+FFFD).

import Foundation

extension JeffJSDOMBridge {

    // MARK: - Prototypes

    /// The wrapper prototype the engine uses for Text (`isText`) or Comment
    /// nodes while the host has handed over none: Text/Comment prototype ->
    /// CharacterData prototype -> the shared element prototype.
    func engineCharacterDataPrototype(text: Bool, shared: JeffJSValue, ctx: JeffJSContext) -> JeffJSValue? {
        if let p = text ? engineTextPrototype : engineCommentPrototype { return p }
        if engineCharacterDataBase == nil {
            let base = ctx.newObjectProto(proto: shared)
            installCharacterDataMembers(on: base, ctx: ctx)
            engineCharacterDataBase = base
        }
        guard let base = engineCharacterDataBase else { return nil }
        let p = ctx.newObjectProto(proto: base)
        if text {
            installTextMembers(on: p, ctx: ctx)
            engineTextPrototype = p
        } else {
            engineCommentPrototype = p
        }
        return p
    }

    /// The host's Text / Comment interface prototypes (`__rnSetNodeInterfaces`):
    /// the CharacterData members go on their common prototype when they share
    /// one below the element prototype (CharacterData.prototype), else on each;
    /// the Text members on the Text prototype. They replace whatever the host
    /// had there (stubs).
    func installCharacterDataMembers(text: JeffJSValue?, comment: JeffJSValue?, shared: JeffJSValue?, ctx: JeffJSContext) {
        let sharedObj = shared?.toObject()
        var common: JeffJSObject? = nil
        if let t = text?.toObject(), let c = comment?.toObject(), let tp = t.proto, tp === c.proto,
           tp !== sharedObj, tp !== t, tp !== c {
            common = tp
        }
        if let common {
            installCharacterDataMembers(on: JeffJSValue.borrowedObject(common), ctx: ctx)
        } else {
            if let text, text.isObject { installCharacterDataMembers(on: text, ctx: ctx) }
            if let comment, comment.isObject { installCharacterDataMembers(on: comment, ctx: ctx) }
        }
        if let text, text.isObject { installTextMembers(on: text, ctx: ctx) }
    }

    // MARK: - Members

    /// `data`, `length`, `substringData`, `appendData`, `insertData`,
    /// `deleteData`, `replaceData` (DOM §4.10).
    func installCharacterDataMembers(on proto: JeffJSValue, ctx: JeffJSContext) {
        let getData = ctx.newCFunction({ [weak self] ctx, thisVal, _ in
            guard let self else { return .undefined }
            guard let n = self.characterDataNode(thisVal) else {
                return ctx.throwTypeError(message: "The CharacterData.data getter can only be used on instances of CharacterData")
            }
            return ctx.newStringValue(n.textContent ?? "")
        }, name: "get data", length: 0)
        let setData = ctx.newCFunction({ [weak self] ctx, thisVal, args in
            guard let self else { return .undefined }
            guard let n = self.characterDataNode(thisVal) else {
                return ctx.throwTypeError(message: "The CharacterData.data setter can only be used on instances of CharacterData")
            }
            // [LegacyNullToEmptyString] attribute DOMString data: "replace data
            // with node this, offset 0, count this's length, and data the value".
            let v = args.first ?? .undefined
            let s: String
            if v.isNull { s = "" } else { guard let str = self.domString(ctx, v) else { return .exception }; s = str }
            self.replaceCharacterData(n, offset: 0, count: (n.textContent ?? "").utf16.count, data: s)
            return .undefined
        }, name: "set data", length: 1)
        dropOwn(ctx, proto, "data")
        ctx.setPropertyGetSet(obj: proto, name: "data", getter: getData, setter: setData)

        let getLength = ctx.newCFunction({ [weak self] ctx, thisVal, _ in
            guard let self else { return .undefined }
            guard let n = self.characterDataNode(thisVal) else {
                return ctx.throwTypeError(message: "The CharacterData.length getter can only be used on instances of CharacterData")
            }
            return .newInt32(Int32(truncatingIfNeeded: (n.textContent ?? "").utf16.count))
        }, name: "get length", length: 0)
        dropOwn(ctx, proto, "length")
        ctx.setPropertyGetSet(obj: proto, name: "length", getter: getLength, setter: nil)

        // substringData(offset, count)
        dropOwn(ctx, proto, "substringData")
        ctx.setPropertyFunc(obj: proto, name: "substringData", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return .undefined }
            guard let n = self.characterDataNode(thisVal) else { return self.illegalInvocation(ctx, "substringData") }
            guard args.count >= 2 else { return self.missingArguments(ctx, "substringData", "CharacterData", 2, args.count) }
            guard let offset = self.unsignedLong(ctx, args[0]), let count = self.unsignedLong(ctx, args[1]) else { return .exception }
            let units = Array((n.textContent ?? "").utf16)
            guard offset <= units.count else { return self.indexSizeError(ctx) }
            let end = min(units.count, offset + count)
            return ctx.newStringValue(String(decoding: units[offset ..< end], as: UTF16.self))
        }, length: 2)

        // appendData(data): replace data(length, 0, data)
        dropOwn(ctx, proto, "appendData")
        ctx.setPropertyFunc(obj: proto, name: "appendData", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return .undefined }
            guard let n = self.characterDataNode(thisVal) else { return self.illegalInvocation(ctx, "appendData") }
            guard args.count >= 1 else { return self.missingArguments(ctx, "appendData", "CharacterData", 1, 0) }
            guard let s = self.domString(ctx, args[0]) else { return .exception }
            self.replaceCharacterData(n, offset: (n.textContent ?? "").utf16.count, count: 0, data: s)
            return .undefined
        }, length: 1)

        // insertData(offset, data): replace data(offset, 0, data)
        dropOwn(ctx, proto, "insertData")
        ctx.setPropertyFunc(obj: proto, name: "insertData", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return .undefined }
            guard let n = self.characterDataNode(thisVal) else { return self.illegalInvocation(ctx, "insertData") }
            guard args.count >= 2 else { return self.missingArguments(ctx, "insertData", "CharacterData", 2, args.count) }
            guard let offset = self.unsignedLong(ctx, args[0]), let s = self.domString(ctx, args[1]) else { return .exception }
            guard offset <= (n.textContent ?? "").utf16.count else { return self.indexSizeError(ctx) }
            self.replaceCharacterData(n, offset: offset, count: 0, data: s)
            return .undefined
        }, length: 2)

        // deleteData(offset, count): replace data(offset, count, "")
        dropOwn(ctx, proto, "deleteData")
        ctx.setPropertyFunc(obj: proto, name: "deleteData", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return .undefined }
            guard let n = self.characterDataNode(thisVal) else { return self.illegalInvocation(ctx, "deleteData") }
            guard args.count >= 2 else { return self.missingArguments(ctx, "deleteData", "CharacterData", 2, args.count) }
            guard let offset = self.unsignedLong(ctx, args[0]), let count = self.unsignedLong(ctx, args[1]) else { return .exception }
            guard offset <= (n.textContent ?? "").utf16.count else { return self.indexSizeError(ctx) }
            self.replaceCharacterData(n, offset: offset, count: count, data: "")
            return .undefined
        }, length: 2)

        // replaceData(offset, count, data)
        dropOwn(ctx, proto, "replaceData")
        ctx.setPropertyFunc(obj: proto, name: "replaceData", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return .undefined }
            guard let n = self.characterDataNode(thisVal) else { return self.illegalInvocation(ctx, "replaceData") }
            guard args.count >= 3 else { return self.missingArguments(ctx, "replaceData", "CharacterData", 3, args.count) }
            guard let offset = self.unsignedLong(ctx, args[0]), let count = self.unsignedLong(ctx, args[1]),
                  let s = self.domString(ctx, args[2]) else { return .exception }
            guard offset <= (n.textContent ?? "").utf16.count else { return self.indexSizeError(ctx) }
            self.replaceCharacterData(n, offset: offset, count: count, data: s)
            return .undefined
        }, length: 3)
    }

    /// `splitText(offset)` and `wholeText` (DOM §4.11).
    func installTextMembers(on proto: JeffJSValue, ctx: JeffJSContext) {
        let getWhole = ctx.newCFunction({ [weak self] ctx, thisVal, _ in
            guard let self else { return .undefined }
            guard let n = self.characterDataNode(thisVal), n.nodeType == .text else {
                return ctx.throwTypeError(message: "The Text.wholeText getter can only be used on instances of Text")
            }
            // The data of the contiguous Text nodes of this node, in tree order.
            guard let parent = n.parent else { return ctx.newStringValue(n.textContent ?? "") }
            let kids = parent.children
            guard let i = kids.firstIndex(where: { $0 === n }) else { return ctx.newStringValue(n.textContent ?? "") }
            var lo = i, hi = i
            while lo > 0, kids[lo - 1].nodeType == .text { lo -= 1 }
            while hi + 1 < kids.count, kids[hi + 1].nodeType == .text { hi += 1 }
            var s = ""
            for k in lo ... hi { s += kids[k].textContent ?? "" }
            return ctx.newStringValue(s)
        }, name: "get wholeText", length: 0)
        dropOwn(ctx, proto, "wholeText")
        ctx.setPropertyGetSet(obj: proto, name: "wholeText", getter: getWhole, setter: nil)

        dropOwn(ctx, proto, "splitText")
        ctx.setPropertyFunc(obj: proto, name: "splitText", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return .undefined }
            guard let n = self.characterDataNode(thisVal), n.nodeType == .text else {
                return ctx.throwTypeError(message: "Can only call Text.splitText on instances of Text")
            }
            guard args.count >= 1 else { return self.missingArguments(ctx, "splitText", "Text", 1, 0) }
            guard let offset = self.unsignedLong(ctx, args[0]) else { return .exception }
            guard let newNode = self.splitTextNode(n, offset: offset) else { return self.indexSizeError(ctx) }
            return self.wrapElement(newNode, ctx: ctx)
        }, length: 1)
    }

    // MARK: - Algorithms

    /// DOM §4.10 "replace data": `offset` ≤ length (checked by the callers);
    /// `count` is clamped to the end. Queues the characterData record (old
    /// value) before the change, as the spec does.
    func replaceCharacterData(_ node: DOMNode, offset: Int, count: Int, data: String) {
        let old = node.textContent ?? ""
        var units = Array(old.utf16)
        let start = min(offset, units.count)
        let end = min(units.count, start + count)
        queueCharacterDataRecord(target: node, oldValue: old)
        units.replaceSubrange(start ..< end, with: data.utf16)
        node.textContent = String(decoding: units, as: UTF16.self)
        notifyMutation(for: node)
    }

    /// DOM §4.11 "split a Text node": nil when `offset` > length
    /// (IndexSizeError). The new node gets the data after `offset` and the
    /// node's document; the node's data is cut ("replace data", a
    /// characterData record), then, with a parent, the new node is inserted
    /// after it (a childList record). That is WebKit's (`Text::splitText`)
    /// and Blink's order, which rung 15 js16 checks; the spec's text inserts
    /// first (step 7) and replaces the data after (step 8). The resulting
    /// tree is the same; only the record order differs (as for normalize()).
    func splitTextNode(_ node: DOMNode, offset: Int) -> DOMNode? {
        let units = Array((node.textContent ?? "").utf16)
        guard offset <= units.count else { return nil }
        let count = units.count - offset
        let newNode = DOMNode.text(String(decoding: units[offset...], as: UTF16.self))
        let document = nodeDocument(of: node)
        newNode.nodeDocument = document === root ? nil : document
        let next = nextSibling(of: node)
        replaceCharacterData(node, offset: offset, count: count, data: "")
        if let parent = node.parent {
            insertNodes([newNode], into: parent, before: next)
        }
        return newNode
    }

    // MARK: - Helpers

    /// Deletes an own member a host put on the prototype (a stub value or
    /// accessor) before the engine's is defined: adding a shape property for a
    /// name the object already owns would leave the old one found first.
    func dropOwn(_ ctx: JeffJSContext, _ proto: JeffJSValue, _ name: String) {
        let atom = ctx.rt.findAtom(name)
        _ = ctx.deleteProperty(obj: proto, atom: atom)
        ctx.rt.freeAtom(atom)
    }

    /// The Text / Comment node behind `value` (not a doctype, which the
    /// engine stores as a comment).
    func characterDataNode(_ value: JeffJSValue) -> DOMNode? {
        guard let n = extractNode(from: value) else { return nil }
        switch n.nodeType {
        case .text: return n
        case .comment: return n.isDocumentType ? nil : n
        default: return nil
        }
    }

    /// WebIDL `unsigned long`: ToNumber, then modulo 2^32 (nil = exception).
    func unsignedLong(_ ctx: JeffJSContext, _ v: JeffJSValue) -> Int? {
        guard let d = ctx.toFloat64(v) else { return nil }
        guard d.isFinite else { return 0 }
        var m = fmod(d.rounded(.towardZero), 4_294_967_296)
        if m < 0 { m += 4_294_967_296 }
        return Int(m)
    }

    /// WebIDL `DOMString` (nil = exception).
    func domString(_ ctx: JeffJSContext, _ v: JeffJSValue) -> String? {
        if v.isNull { return "null" }
        if v.isUndefined { return "undefined" }
        return ctx.toSwiftString(v)
    }

    func indexSizeError(_ ctx: JeffJSContext) -> JeffJSValue {
        throwDOMException(ctx: ctx, name: "IndexSizeError", message: "The index is not in the allowed range.")
    }

    func illegalInvocation(_ ctx: JeffJSContext, _ method: String) -> JeffJSValue {
        ctx.throwTypeError(message: "Can only call CharacterData.\(method) on instances of CharacterData")
    }

    func missingArguments(_ ctx: JeffJSContext, _ method: String, _ iface: String, _ required: Int, _ present: Int) -> JeffJSValue {
        ctx.throwTypeError(message: "Failed to execute '\(method)' on '\(iface)': \(required) argument\(required == 1 ? "" : "s") required, but only \(present) present.")
    }
}
