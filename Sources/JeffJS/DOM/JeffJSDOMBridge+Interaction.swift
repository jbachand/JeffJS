// JeffJSDOMBridge+Interaction.swift
// JeffJS DOM bridge — the interaction half of the DOM (the app's spec-ladder
// rung 15):
//
//   - DOM mutation algorithms (DOM §4.2.3): insert / remove / replace /
//     replace-all, DocumentFragment insertion, node documents and adoption.
//     Every script-initiated tree, attribute and character-data change goes
//     through them, so MutationObserver sees each one.
//   - MutationObserver (DOM §4.3), native.
//   - Node lifetimes: wrappers and event listeners belong to the node and
//     survive removal; a detached subtree is released only when script can no
//     longer reach it (`collectDetachedNodes`).
//   - Focus (HTML §6.6): focusability, focus()/blur(), activeElement,
//     focus/blur/focusin/focusout, autofocus.
//   - HTMLElement.click() and activation behaviour (HTML §6.2, DOM §2.9).
//   - innerText (HTML §3.2.7), dataset (HTML §3.2.6.6), <details> toggle
//     (HTML §4.11.1), label.control / labels.
//
// Host contract (all optional; the engine works without them):
//   - `computedStyleProvider(node, property) -> String?` — resolved CSS values
//     for innerText and focusability. Without it the bridge calls the host's
//     global `__nativeGetComputedStyleValue(nodeID, property)`, then falls back
//     to the inline style and UA defaults.
//   - `onFocusChange(new, old)` — script moved focus; move first responder.
//   - `hostFocusChanged(to:ctx:)` / `hostBlurred(_:ctx:)` (JS:
//     `__nativeEventBridge.focus(el)` / `.blur(el)`) — the host moved focus.
//   - `onActivationBehavior(element, kind) -> Bool` — "hyperlink", "submit",
//     "reset" after an uncanceled click(); JS fallback
//     `window.__nativeActivationBehavior(element, kind)`.
//   - `collectDetachedNodes()` — optional idle-time sweep (it also runs by
//     itself as detached nodes accumulate).
//
// Ownership: record/proxy/observer values stored here are owned (dup'd) and
// freed exactly once (resetBridge, disconnect, delivery, or the sweep).

import Foundation

// MARK: - MutationObserver state

/// One MutationObserver known to the bridge (created by `observe`, dropped
/// by `disconnect` or when it has neither registrations nor records).
final class JeffJSMutationObserverEntry {
    let id: Int
    /// The observer JS object (owned). Its `__moCallback` is the callback.
    let object: JeffJSValue
    /// Queued MutationRecord objects (owned).
    var records: [JeffJSValue] = []

    init(id: Int, object: JeffJSValue) {
        self.id = id
        self.object = object
    }

    func release() {
        object.freeValue()
        for r in records { r.freeValue() }
        records.removeAll()
    }
}

struct JeffJSMutationObserverOptions {
    var childList = false
    var attributes = false
    var characterData = false
    var subtree = false
    var attributeOldValue = false
    var characterDataOldValue = false
    var attributeFilter: Set<String>?
}

/// A "registered observer" on a node. Transient registrations (added to a
/// node removed from under a `subtree` registration) carry their source node.
struct JeffJSMutationRegistration {
    let observerID: Int
    var options: JeffJSMutationObserverOptions
    let transientSource: UUID?
}

extension JeffJSDOMBridge {

    // MARK: - Node documents

    /// DOM "node document": a document for itself; the document whose tree
    /// the node is in; else its detached subtree's recorded document (the
    /// page when none was recorded).
    func nodeDocument(of node: DOMNode) -> DOMNode {
        if node.nodeType == .document { return node }
        var top = node
        while let p = top.parent { top = p }
        if top.nodeType == .document { return top }
        return top.nodeDocument ?? root
    }

    /// DOM "adopt": removes `node` from its parent and makes `document` its
    /// node document (`root` = the page document).
    func adopt(_ node: DOMNode, into document: DOMNode) {
        if node.parent != nil { removeNodeFromParent(node) }
        node.nodeDocument = document === root ? nil : document
    }

    /// The inert document holding `<template>` contents for `document`.
    func inertDocument(for document: DOMNode) -> DOMNode {
        if let existing = inertDocuments[document.id] { return existing }
        let inert = DOMNode.document()
        inertDocuments[document.id] = inert
        return inert
    }

    /// The JS value for a node: the page root is `document`.
    func jsValue(for node: DOMNode, ctx: JeffJSContext) -> JeffJSValue {
        if node === root, let doc = documentJSValue { return doc.dupValue() }
        return wrapElement(node, ctx: ctx)
    }

    /// A DOM node from a JS value: element wrappers by payload, `document`
    /// (which has no payload) as the page root.
    func nodeFromValue(_ value: JeffJSValue) -> DOMNode? {
        if let node = extractNode(from: value) { return node }
        if value.isObject, let doc = documentJSValue, value == doc { return root }
        return nil
    }

    // MARK: - Tree mutations (DOM §4.2.3)

    /// "Pre-insert": inserts `node` into `parent` before `child` (nil =
    /// append). A DocumentFragment inserts its children and is left empty; a
    /// node with a parent is removed from it first. Queues the childList
    /// records. False (tree unchanged) when the insertion would make a node
    /// its own ancestor (HierarchyRequestError).
    @discardableResult
    func insertNode(_ node: DOMNode, into parent: DOMNode, before child: DOMNode?) -> Bool {
        if node === parent || nodeContains(node, child: parent) { return false }
        if node.nodeType == .document { return false }
        var reference = child
        if let r = reference, r.parent !== parent { reference = nil }
        if reference === node { reference = nextSibling(of: node) }
        let nodes: [DOMNode]
        if node.nodeType == .documentFragment {
            nodes = takeFragmentChildren(node)
            guard !nodes.isEmpty else { return true }
        } else {
            if node.parent != nil { removeNodeFromParent(node) }
            nodes = [node]
        }
        insertNodes(nodes, into: parent, before: reference)
        return true
    }

    /// Inserts already-parentless `nodes` (in order) before `reference`, with
    /// one childList record.
    func insertNodes(_ nodes: [DOMNode], into parent: DOMNode, before reference: DOMNode?) {
        guard !nodes.isEmpty else { return }
        let ref = (reference?.parent === parent) ? reference : nil
        let previous = ref.map { previousSibling(of: $0) } ?? parent.lastChildNode
        for n in nodes {
            if let ref { parent.insertChild(n, before: ref) } else { parent.appendChild(n) }
            n.nodeDocument = nil
        }
        queueChildListRecord(target: parent, added: nodes, removed: [], previous: previous, next: ref)
        runScriptInsertionSteps(inserted: nodes, parent: parent)
    }

    /// Empties a DocumentFragment (one record on the fragment) and returns
    /// its former children, now parentless.
    func takeFragmentChildren(_ fragment: DOMNode) -> [DOMNode] {
        let kids = fragment.detachChildrenArray()
        for k in kids { k.parent = nil }
        if !kids.isEmpty {
            queueChildListRecord(target: fragment, added: [], removed: kids, previous: nil, next: nil)
        }
        return kids
    }

    /// "Remove": takes `node` out of its parent. Its wrapper, listeners and
    /// caches stay (they belong to the node); it becomes a collection
    /// candidate and keeps the old tree's document as its node document.
    func removeNodeFromParent(_ node: DOMNode, suppressObservers: Bool = false) {
        guard let parent = node.parent else { return }
        let previous = previousSibling(of: node)
        let next = nextSibling(of: node)
        if !suppressObservers { addTransientRegistrations(for: node, removedFrom: parent) }
        let document = nodeDocument(of: parent)
        parent.removeChild(node)
        node.nodeDocument = document === root ? nil : document
        if !suppressObservers {
            queueChildListRecord(target: parent, added: [], removed: [node], previous: previous, next: next)
        }
        nodeLeftTree(node)
    }

    /// "Replace all" (innerHTML, textContent, replaceChildren, innerText):
    /// one record with every removed and added node.
    func replaceAllChildren(of parent: DOMNode, with newNodes: [DOMNode]) {
        var added: [DOMNode] = []
        for n in newNodes {
            if n.nodeType == .documentFragment {
                added += takeFragmentChildren(n)
            } else {
                if n.parent != nil { removeNodeFromParent(n) }
                added.append(n)
            }
        }
        let removed = parent.children
        let document = nodeDocument(of: parent)
        for r in removed { addTransientRegistrations(for: r, removedFrom: parent) }
        parent.clearChildren()
        for r in removed {
            r.nodeDocument = document === root ? nil : document
            nodeLeftTree(r)
        }
        for a in added {
            parent.appendChild(a)
            a.nodeDocument = nil
        }
        if !added.isEmpty || !removed.isEmpty {
            queueChildListRecord(target: parent, added: added, removed: removed, previous: nil, next: nil)
            runScriptInsertionSteps(inserted: added, parent: parent)
        }
    }

    /// `replaceChild(node, old)`: false on a hierarchy error.
    @discardableResult
    func replaceChildNode(_ old: DOMNode, with node: DOMNode, in parent: DOMNode) -> Bool {
        guard old.parent === parent else { return false }
        if node === parent || nodeContains(node, child: parent) || node.nodeType == .document { return false }
        if node === old { return true }
        let nodes: [DOMNode]
        if node.nodeType == .documentFragment {
            nodes = takeFragmentChildren(node)
        } else {
            if node.parent != nil { removeNodeFromParent(node) }
            nodes = [node]
        }
        replaceChildNode(old, withNodes: nodes, in: parent)
        return true
    }

    /// Replaces `old` with already-parentless `nodes`, one record.
    func replaceChildNode(_ old: DOMNode, withNodes nodes: [DOMNode], in parent: DOMNode) {
        guard old.parent === parent else { return }
        var flat: [DOMNode] = []
        for n in nodes {
            if n.nodeType == .documentFragment { flat += takeFragmentChildren(n) } else { flat.append(n) }
        }
        let previous = previousSibling(of: old)
        let reference = nextSibling(of: old)
        addTransientRegistrations(for: old, removedFrom: parent)
        let document = nodeDocument(of: parent)
        parent.removeChild(old)
        old.nodeDocument = document === root ? nil : document
        for n in flat {
            if n.parent != nil { removeNodeFromParent(n) }
            if let reference, reference.parent === parent { parent.insertChild(n, before: reference) } else { parent.appendChild(n) }
            n.nodeDocument = nil
        }
        queueChildListRecord(target: parent, added: flat, removed: [old], previous: previous,
                             next: (reference?.parent === parent) ? reference : nil)
        nodeLeftTree(old)
        runScriptInsertionSteps(inserted: flat, parent: parent)
    }

    /// DOM "convert nodes into a node" for append/prepend/before/after/
    /// replaceWith/replaceChildren, flattened: strings become Text nodes,
    /// fragments contribute their children, and every node leaves its old
    /// parent (records there). `parent` is only the eventual destination.
    func convertNodesForInsertion(_ args: [JeffJSValue], into parent: DOMNode, ctx: JeffJSContext) -> [DOMNode] {
        var out: [DOMNode] = []
        for arg in args {
            if let n = extractNode(from: arg, ctx: ctx) {
                if n.nodeType == .documentFragment {
                    out += takeFragmentChildren(n)
                } else if n === parent || nodeContains(n, child: parent) || n.nodeType == .document {
                    continue   // HierarchyRequestError: skip rather than corrupt the tree
                } else {
                    if n.parent != nil { removeNodeFromParent(n) }
                    out.append(n)
                }
            } else if let text = ctx.toSwiftString(arg) {
                out.append(DOMNode.text(text))
            }
        }
        return out
    }

    /// Identities of the node arguments (viable sibling computation).
    func argumentNodeSet(_ args: [JeffJSValue], ctx: JeffJSContext) -> Set<ObjectIdentifier> {
        var set = Set<ObjectIdentifier>()
        for arg in args { if let n = extractNode(from: arg) { set.insert(ObjectIdentifier(n)) } }
        return set
    }

    /// Bookkeeping when a subtree leaves a tree: collection candidacy and the
    /// focus fixup rule (a removed focused element stops being focused,
    /// without events).
    func nodeLeftTree(_ node: DOMNode) {
        noteDetached(node)
        if let focused = focusedElement, focused === node || nodeContains(node, child: focused) {
            focusedElement = nil
            if DOMNode.focusedNode === focused { DOMNode.focusedNode = nil }
        }
    }

    // MARK: - Attribute / character data changes

    /// Script-initiated "set an attribute value": HTML elements lower-case
    /// the name, foreign elements keep its case. Queues the attribute record
    /// and runs the attribute change steps (details `open`).
    func setAttributeValue(_ node: DOMNode, name: String, value: String) {
        let foreign = node.nodeType == .element && !node.isHTMLNamespace
        let key = foreign ? name : name.lowercased()
        let old = node.attributes[key]
        if foreign {
            node.setAttributePreservingCase(name: name, value: value)
        } else {
            node.setAttribute(name: name, value: value)
        }
        attributeChanged(node, name: key, oldValue: old, newValue: value)
    }

    /// Script-initiated "remove an attribute by name" (no-op when absent).
    func removeAttributeValue(_ node: DOMNode, name: String) {
        let foreign = node.nodeType == .element && !node.isHTMLNamespace
        var key = foreign ? name : name.lowercased()
        if foreign, node.attributes[key] == nil, node.attributes[name.lowercased()] != nil { key = name.lowercased() }
        guard let old = node.attributes[key] else { return }
        if foreign {
            node.removeAttributePreservingCase(name: key)
        } else {
            node.removeAttribute(name: key)
        }
        attributeChanged(node, name: key, oldValue: old, newValue: nil)
    }

    private func attributeChanged(_ node: DOMNode, name: String, oldValue: String?, newValue: String?) {
        queueAttributeRecord(target: node, name: name, oldValue: oldValue)
        if Self.isHTMLScript(node) {
            // HTML §4.12.1: an `async` attribute change clears "non-blocking";
            // a `src` set where there was none prepares a connected script.
            if name == "async" { node.scriptNonBlocking = false }
            if name == "src", oldValue == nil, newValue != nil { scriptSrcAttributeAdded(node) }
        }
        // HTML §4.11.1: a details element's open attribute added or removed
        // queues a `toggle` event.
        if name == "open", (oldValue != nil) != (newValue != nil),
           node.nodeType == .element, node.isHTMLNamespace, node.tagName == "details" {
            queueDetailsToggle(node, wasOpen: oldValue != nil)
        }
    }

    /// "Replace data" on a Text/Comment node (characterData record).
    func setCharacterData(_ node: DOMNode, _ value: String) {
        let old = node.textContent
        node.textContent = value
        queueCharacterDataRecord(target: node, oldValue: old ?? "")
    }

    // MARK: - MutationObserver (DOM §4.3)

    private static let mutationObserverShim = #"""
    (function (g, N) {
      'use strict';
      function MutationObserver(callback) {
        if (!(this instanceof MutationObserver)) throw new TypeError("Failed to construct 'MutationObserver': Please use the 'new' operator, this DOM object constructor cannot be called as a function.");
        if (typeof callback !== 'function') throw new TypeError("Failed to construct 'MutationObserver': parameter 1 is not of type 'MutationCallback'.");
        Object.defineProperty(this, '__moID', { value: N.nextID() });
        Object.defineProperty(this, '__moCallback', { value: callback });
      }
      Object.defineProperty(MutationObserver.prototype, 'observe', { writable: true, configurable: true, value: function observe(target, options) {
        N.observe(this, target, options === undefined ? {} : options);
      } });
      Object.defineProperty(MutationObserver.prototype, 'disconnect', { writable: true, configurable: true, value: function disconnect() { N.disconnect(this); } });
      Object.defineProperty(MutationObserver.prototype, 'takeRecords', { writable: true, configurable: true, value: function takeRecords() { return N.take(this); } });
      Object.defineProperty(MutationObserver, '__jeffjsReal', { value: true });
      g.MutationObserver = MutationObserver;
      g.WebKitMutationObserver = MutationObserver;
      if (typeof g.MutationRecord !== 'function') g.MutationRecord = function MutationRecord() { throw new TypeError('Illegal constructor'); };
    })
    """#

    func installMutationObserver(on global: JeffJSValue, ctx: JeffJSContext) {
        let natives = ctx.newObject()
        var nextID = 0
        ctx.setPropertyFunc(obj: natives, name: "nextID", fn: { _, _, _ in
            nextID += 1
            return .newInt32(Int32(nextID))
        }, length: 0)
        ctx.setPropertyFunc(obj: natives, name: "observe", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 3 else { return .undefined }
            return self.mutationObserverObserve(ctx: ctx, observer: args[0], target: args[1], options: args[2])
        }, length: 3)
        ctx.setPropertyFunc(obj: natives, name: "disconnect", fn: { [weak self] ctx, _, args in
            guard let self, let obs = args.first, let id = self.mutationObserverID(obs, ctx: ctx) else { return .undefined }
            self.disconnectMutationObserver(id)
            return .undefined
        }, length: 1)
        ctx.setPropertyFunc(obj: natives, name: "take", fn: { [weak self] ctx, _, args in
            let arr = ctx.newArray()
            guard let self, let obs = args.first, let id = self.mutationObserverID(obs, ctx: ctx),
                  let entry = self.moObservers[id] else { return arr }
            let records = entry.records
            entry.records.removeAll()
            for (i, r) in records.enumerated() {
                ctx.setPropertyUint32(obj: arr, index: UInt32(i), value: r)   // transfers ownership
            }
            self.pruneIdleMutationObservers()
            return arr
        }, length: 1)

        let shim = ctx.eval(input: Self.mutationObserverShim, filename: "<mutation-observer>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        if shim.isFunction {
            let r = ctx.call(shim, this: .undefined, args: [global, natives])
            reportIfException(r, ctx: ctx, label: "MutationObserver install")
            r.freeValue()
        } else {
            reportIfException(shim, ctx: ctx, label: "MutationObserver install")
        }
        shim.freeValue()
        natives.freeValue()
    }

    func mutationObserverID(_ observer: JeffJSValue, ctx: JeffJSContext) -> Int? {
        guard observer.isObject else { return nil }
        let v = ctx.getPropertyStr(obj: observer, name: "__moID")
        defer { v.freeValue() }
        guard let id = ctx.toInt32(v), id > 0 else { return nil }
        return Int(id)
    }

    private func readOptionalBool(_ ctx: JeffJSContext, _ obj: JeffJSValue, _ name: String) -> Bool? {
        let v = ctx.getPropertyStr(obj: obj, name: name)
        defer { v.freeValue() }
        if v.isException { ctx.getException().freeValue(); return nil }
        return v.isUndefined ? nil : ctx.toBool(v)
    }

    /// `observe(target, options)` (DOM §4.3.1).
    func mutationObserverObserve(ctx: JeffJSContext, observer: JeffJSValue, target: JeffJSValue, options: JeffJSValue) -> JeffJSValue {
        guard let id = mutationObserverID(observer, ctx: ctx) else {
            return ctx.throwTypeError(message: "Illegal invocation")
        }
        guard let node = nodeFromValue(target) else {
            return ctx.throwTypeError(message: "Failed to execute 'observe' on 'MutationObserver': parameter 1 is not of type 'Node'.")
        }
        var o = JeffJSMutationObserverOptions()
        var attributes: Bool? = nil, characterData: Bool? = nil
        var attributeOldValue: Bool? = nil, characterDataOldValue: Bool? = nil
        if options.isObject {
            o.childList = readOptionalBool(ctx, options, "childList") ?? false
            o.subtree = readOptionalBool(ctx, options, "subtree") ?? false
            attributes = readOptionalBool(ctx, options, "attributes")
            characterData = readOptionalBool(ctx, options, "characterData")
            attributeOldValue = readOptionalBool(ctx, options, "attributeOldValue")
            characterDataOldValue = readOptionalBool(ctx, options, "characterDataOldValue")
            let filter = ctx.getPropertyStr(obj: options, name: "attributeFilter")
            if filter.isObject {
                var names = Set<String>()
                let lenVal = ctx.getPropertyStr(obj: filter, name: "length")
                let len = ctx.toInt32(lenVal) ?? 0
                lenVal.freeValue()
                for i in 0..<max(0, len) {
                    let item = ctx.getPropertyUint32(obj: filter, index: UInt32(i))
                    if let str = ctx.toSwiftString(item) { names.insert(str) }
                    item.freeValue()
                }
                o.attributeFilter = names
            } else if filter.isException {
                ctx.getException().freeValue()
            }
            filter.freeValue()
        }
        if (attributeOldValue != nil || o.attributeFilter != nil) && attributes == nil { attributes = true }
        if characterDataOldValue != nil && characterData == nil { characterData = true }
        o.attributes = attributes ?? false
        o.characterData = characterData ?? false
        o.attributeOldValue = attributeOldValue ?? false
        o.characterDataOldValue = characterDataOldValue ?? false
        let prefix = "Failed to execute 'observe' on 'MutationObserver': "
        if !o.childList && !o.attributes && !o.characterData {
            return ctx.throwTypeError(message: prefix + "The options object must set at least one of 'attributes', 'characterData', or 'childList' to true.")
        }
        if o.attributeOldValue && !o.attributes {
            return ctx.throwTypeError(message: prefix + "The options object may only set 'attributeOldValue' to true when 'attributes' is true or not present.")
        }
        if o.attributeFilter != nil && !o.attributes {
            return ctx.throwTypeError(message: prefix + "The options object may only set 'attributeFilter' when 'attributes' is true or not present.")
        }
        if o.characterDataOldValue && !o.characterData {
            return ctx.throwTypeError(message: prefix + "The options object may only set 'characterDataOldValue' to true when 'characterData' is true or not present.")
        }

        if moObservers[id] == nil {
            moObservers[id] = JeffJSMutationObserverEntry(id: id, object: observer.dupValue())
        }
        var regs = moRegistrations[node.id] ?? []
        if let index = regs.firstIndex(where: { $0.observerID == id && $0.transientSource == nil }) {
            removeTransientRegistrations(observerID: id, source: node.id)
            regs = moRegistrations[node.id] ?? []
            if let again = regs.firstIndex(where: { $0.observerID == id && $0.transientSource == nil }) {
                regs[again].options = o
            } else {
                regs.insert(JeffJSMutationRegistration(observerID: id, options: o, transientSource: nil), at: min(index, regs.count))
            }
        } else {
            regs.append(JeffJSMutationRegistration(observerID: id, options: o, transientSource: nil))
        }
        moRegistrations[node.id] = regs
        return .undefined
    }

    func disconnectMutationObserver(_ id: Int) {
        for key in Array(moRegistrations.keys) {
            guard var regs = moRegistrations[key] else { continue }
            regs.removeAll { $0.observerID == id }
            moRegistrations[key] = regs.isEmpty ? nil : regs
        }
        if let entry = moObservers.removeValue(forKey: id) { entry.release() }
    }

    /// Drops observers with nothing registered and nothing queued (script can
    /// `observe` again: the entry is recreated from the JS object).
    func pruneIdleMutationObservers() {
        guard !moObservers.isEmpty else { return }
        var active = Set<Int>()
        for (_, regs) in moRegistrations { for r in regs { active.insert(r.observerID) } }
        for (id, entry) in moObservers where !active.contains(id) && entry.records.isEmpty {
            moObservers.removeValue(forKey: id)
            entry.release()
        }
    }

    private func removeTransientRegistrations(observerID: Int, source: UUID? = nil) {
        for key in Array(moRegistrations.keys) {
            guard var regs = moRegistrations[key] else { continue }
            let before = regs.count
            regs.removeAll { $0.observerID == observerID && $0.transientSource != nil
                && (source == nil || $0.transientSource == source) }
            if regs.count != before { moRegistrations[key] = regs.isEmpty ? nil : regs }
        }
    }

    /// DOM "remove" step 13: observers with `subtree` on an inclusive
    /// ancestor of the old parent keep seeing the removed subtree until
    /// their next delivery.
    func addTransientRegistrations(for node: DOMNode, removedFrom parent: DOMNode) {
        guard !moRegistrations.isEmpty else { return }
        var cursor: DOMNode? = parent
        var added: [JeffJSMutationRegistration] = []
        while let ancestor = cursor {
            if let regs = moRegistrations[ancestor.id] {
                for reg in regs where reg.options.subtree {
                    added.append(JeffJSMutationRegistration(observerID: reg.observerID, options: reg.options,
                                                            transientSource: ancestor.id))
                }
            }
            cursor = ancestor.parent
        }
        if !added.isEmpty { moRegistrations[node.id, default: []].append(contentsOf: added) }
    }

    private enum MutationKind { case childList, attributes, characterData }

    /// DOM "queue a mutation record" step 1-4: observer id -> whether it wants
    /// the old value.
    private func interestedObservers(target: DOMNode, kind: MutationKind, attributeName: String?) -> [Int: Bool] {
        var result: [Int: Bool] = [:]
        var cursor: DOMNode? = target
        while let node = cursor {
            if let regs = moRegistrations[node.id] {
                for reg in regs {
                    let o = reg.options
                    if node !== target && !o.subtree { continue }
                    var wantsOld = false
                    switch kind {
                    case .attributes:
                        if !o.attributes { continue }
                        if let filter = o.attributeFilter, let name = attributeName, !filter.contains(name) { continue }
                        wantsOld = o.attributeOldValue
                    case .characterData:
                        if !o.characterData { continue }
                        wantsOld = o.characterDataOldValue
                    case .childList:
                        if !o.childList { continue }
                    }
                    result[reg.observerID] = (result[reg.observerID] ?? false) || wantsOld
                }
            }
            cursor = node.parent
        }
        return result
    }

    func queueChildListRecord(target: DOMNode, added: [DOMNode], removed: [DOMNode], previous: DOMNode?, next: DOMNode?) {
        guard !moRegistrations.isEmpty, let ctx = jsContext else { return }
        let interested = interestedObservers(target: target, kind: .childList, attributeName: nil)
        for id in interested.keys.sorted() {
            let record = makeMutationRecord(ctx: ctx, type: "childList", target: target, added: added, removed: removed,
                                            previous: previous, next: next, attributeName: nil, oldValue: nil)
            enqueueMutationRecord(record, observerID: id, ctx: ctx)
        }
    }

    func queueAttributeRecord(target: DOMNode, name: String, oldValue: String?) {
        guard !moRegistrations.isEmpty, let ctx = jsContext else { return }
        let interested = interestedObservers(target: target, kind: .attributes, attributeName: name)
        for id in interested.keys.sorted() {
            let record = makeMutationRecord(ctx: ctx, type: "attributes", target: target, added: [], removed: [],
                                            previous: nil, next: nil, attributeName: name,
                                            oldValue: interested[id] == true ? .some(oldValue) : .none)
            enqueueMutationRecord(record, observerID: id, ctx: ctx)
        }
    }

    func queueCharacterDataRecord(target: DOMNode, oldValue: String) {
        guard !moRegistrations.isEmpty, let ctx = jsContext else { return }
        let interested = interestedObservers(target: target, kind: .characterData, attributeName: nil)
        for id in interested.keys.sorted() {
            let record = makeMutationRecord(ctx: ctx, type: "characterData", target: target, added: [], removed: [],
                                            previous: nil, next: nil, attributeName: nil,
                                            oldValue: interested[id] == true ? .some(oldValue) : .none)
            enqueueMutationRecord(record, observerID: id, ctx: ctx)
        }
    }

    /// A MutationRecord object (owned). `oldValue` is nil when the observer
    /// did not ask for it (reads null), `.some(nil)` for an absent old value.
    private func makeMutationRecord(ctx: JeffJSContext, type: String, target: DOMNode, added: [DOMNode], removed: [DOMNode],
                                    previous: DOMNode?, next: DOMNode?, attributeName: String?,
                                    oldValue: String??) -> JeffJSValue {
        let rec = ctx.newObject()
        ctx.setPropertyStr(obj: rec, name: "type", value: ctx.newStringValue(type))
        ctx.setPropertyStr(obj: rec, name: "target", value: jsValue(for: target, ctx: ctx))
        ctx.setPropertyStr(obj: rec, name: "addedNodes", value: wrapElementArray(added, ctx: ctx))
        ctx.setPropertyStr(obj: rec, name: "removedNodes", value: wrapElementArray(removed, ctx: ctx))
        ctx.setPropertyStr(obj: rec, name: "previousSibling", value: previous.map { jsValue(for: $0, ctx: ctx) } ?? .null)
        ctx.setPropertyStr(obj: rec, name: "nextSibling", value: next.map { jsValue(for: $0, ctx: ctx) } ?? .null)
        ctx.setPropertyStr(obj: rec, name: "attributeName", value: attributeName.map { ctx.newStringValue($0) } ?? .null)
        ctx.setPropertyStr(obj: rec, name: "attributeNamespace", value: .null)
        let old: JeffJSValue
        if case .some(.some(let s)) = oldValue { old = ctx.newStringValue(s) } else { old = .null }
        ctx.setPropertyStr(obj: rec, name: "oldValue", value: old)
        return rec
    }

    private func enqueueMutationRecord(_ record: JeffJSValue, observerID: Int, ctx: JeffJSContext) {
        guard let entry = moObservers[observerID] else { record.freeValue(); return }
        entry.records.append(record)
        guard !moDeliveryScheduled else { return }
        moDeliveryScheduled = true
        // "Queue a mutation observer microtask".
        ctx.rt.enqueueJob(ctx: ctx, jobFunc: { [weak self] ctx, _, _ in
            self?.deliverMutationRecords(ctx: ctx)
            return .undefined
        }, args: [])
    }

    /// DOM "notify mutation observers": every observer in creation order,
    /// transient registrations dropped, callback(records, observer).
    func deliverMutationRecords(ctx: JeffJSContext) {
        moDeliveryScheduled = false
        for id in moObservers.keys.sorted() {
            guard let entry = moObservers[id] else { continue }
            let records = entry.records
            entry.records.removeAll()
            removeTransientRegistrations(observerID: id)
            guard !records.isEmpty else { continue }
            let arr = ctx.newArray()
            for (i, r) in records.enumerated() {
                ctx.setPropertyUint32(obj: arr, index: UInt32(i), value: r)
            }
            let observer = entry.object.dupValue()
            let callback = ctx.getPropertyStr(obj: observer, name: "__moCallback")
            if callback.isFunction {
                let r = ctx.call(callback, this: observer, args: [arr, observer])
                reportIfException(r, ctx: ctx, label: "MutationObserver callback")
                r.freeValue()
            }
            callback.freeValue()
            observer.freeValue()
            arr.freeValue()
        }
        pruneIdleMutationObservers()
    }

    // MARK: - Node lifetimes

    /// Cached wrappers / pending collection candidates (diagnostics / tests).
    var wrapperCount: Int { elementCache.count }
    var detachedCandidateCount: Int { detachedCandidates.count }

    func noteDetached(_ node: DOMNode) {
        if detachedCandidateIDs.insert(node.id).inserted { detachedCandidates.append(node) }
    }

    /// Sweeps once enough detached candidates have accumulated. Called at the
    /// start of the natives that create or remove nodes, where the only live
    /// wrappers are the ones on the JS stack (counted in their refcounts).
    func maybeCollectDetachedNodes() {
        if detachedCandidates.count >= detachedSweepThreshold { collectDetachedNodes() }
    }

    /// Releases the wrapper, event listeners and caches of every detached
    /// subtree script can no longer reach: none of its wrappers (or classList
    /// / relList / dataset objects) is referenced by anything but this
    /// bridge's caches. A subtree that is still held — directly, through a
    /// listener closure, a pending mutation record, an event path — is kept
    /// whole, so a removed node re-inserted later still has its listeners.
    /// Safe to call from the host at idle time.
    func collectDetachedNodes() {
        let candidates = detachedCandidates
        detachedCandidates.removeAll()
        detachedCandidateIDs.removeAll()
        var decided = Set<ObjectIdentifier>()
        var survivors: [DOMNode] = []
        let templateFragments = Set(templateContent.values.map { ObjectIdentifier($0) })
        for node in candidates {
            var top = node
            while let p = top.parent { top = p }
            if top === root || top.nodeType == .document { continue }
            if templateFragments.contains(ObjectIdentifier(top)) { continue }
            guard decided.insert(ObjectIdentifier(top)).inserted else { continue }
            if isSubtreeHeld(top) { survivors.append(top) } else { releaseSubtree(top) }
        }
        for s in survivors { noteDetached(s) }
        detachedSweepThreshold = max(64, survivors.count * 2)
    }

    private func isHeldElsewhere(_ value: JeffJSValue?) -> Bool {
        guard let value, let obj = value.obj else { return false }
        return obj.refCount > 1
    }

    private func isSubtreeHeld(_ top: DOMNode) -> Bool {
        var stack = [top]
        while let n = stack.popLast() {
            if isHeldElsewhere(elementCache[n.id]) || isHeldElsewhere(classListCache[n.id])
                || isHeldElsewhere(relListCache[n.id]) || isHeldElsewhere(datasetCache[n.id]) {
                return true
            }
            if clickInProgress.contains(n.id) || pendingDetailsToggles[n.id] != nil { return true }
            stack.append(contentsOf: n.children)
            if let fragment = templateContent[n.id] { stack.append(fragment) }
        }
        return false
    }

    private func releaseSubtree(_ top: DOMNode) {
        var stack = [top]
        while let n = stack.popLast() {
            stack.append(contentsOf: n.children)
            if let fragment = templateContent[n.id] { stack.append(fragment) }
            clearEventListeners(for: n.id)
        }
    }

    // MARK: - Queued tasks

    /// HTML "queue a task": runs `body` from a `setTimeout(…, 0)` (the host's
    /// event loop), or as a microtask when no timer is installed.
    func queueTask(_ body: @escaping () -> Void) {
        pendingTasks.append(body)
        guard !taskScheduled, let ctx = jsContext else { return }
        taskScheduled = true
        if taskRunnerFn == nil {
            taskRunnerFn = ctx.newCFunction({ [weak self] _, _, _ in
                self?.runQueuedTasks()
                return .undefined
            }, name: "domTask", length: 0)
        }
        let global = ctx.getGlobalObject()
        let setTimeoutFn = ctx.getPropertyStr(obj: global, name: "setTimeout")
        global.freeValue()
        defer { setTimeoutFn.freeValue() }
        if setTimeoutFn.isFunction, let runner = taskRunnerFn {
            let r = ctx.call(setTimeoutFn, this: .undefined, args: [runner, .newInt32(0)])
            if !r.isException { r.freeValue(); return }
            reportIfException(r, ctx: ctx, label: "queue a task")
        }
        ctx.rt.enqueueJob(ctx: ctx, jobFunc: { [weak self] _, _, _ in
            self?.runQueuedTasks()
            return .undefined
        }, args: [])
    }

    func runQueuedTasks() {
        taskScheduled = false
        let tasks = pendingTasks
        pendingTasks.removeAll()
        for task in tasks { task() }
    }

    // MARK: - <details> toggle (HTML §4.11.1)

    /// "Queue a details toggle event task", coalesced: a pending task keeps
    /// its original old state and fires with the state at run time.
    func queueDetailsToggle(_ node: DOMNode, wasOpen: Bool) {
        guard pendingDetailsToggles[node.id] == nil else { return }
        pendingDetailsToggles[node.id] = wasOpen
        queueTask { [weak self, node] in
            guard let self, let ctx = self.jsContext,
                  let old = self.pendingDetailsToggles.removeValue(forKey: node.id) else { return }
            let isOpen = node.attributes["open"] != nil
            let target = self.wrapElement(node, ctx: ctx)
            defer { target.freeValue() }
            let oldState = ctx.newStringValue(old ? "open" : "closed")
            let newState = ctx.newStringValue(isOpen ? "open" : "closed")
            defer { oldState.freeValue(); newState.freeValue() }
            guard let event = self.makeEvent(ctx: ctx, constructors: ["ToggleEvent", "Event"], type: "toggle",
                                             init: [("bubbles", .newBool(false)), ("cancelable", .newBool(false)),
                                                    ("oldState", oldState), ("newState", newState)]) else { return }
            ctx.setPropertyStr(obj: event, name: "isTrusted", value: .newBool(true))
            self.eventBridge?.dispatchFromTarget(ctx: ctx, target: target, type: "toggle", event: event)
            event.freeValue()
        }
    }

    // MARK: - Events

    /// `new C(type, init)` for the first constructor in `constructors` that
    /// exists and succeeds. `init` values are borrowed. Owned result.
    func makeEvent(ctx: JeffJSContext, constructors: [String], type: String, init entries: [(String, JeffJSValue)]) -> JeffJSValue? {
        let global = ctx.getGlobalObject()
        defer { global.freeValue() }
        for name in constructors {
            let ctor = ctx.getPropertyStr(obj: global, name: name)
            defer { ctor.freeValue() }
            guard ctor.isFunction else { continue }
            let initObj = ctx.newObject()
            for (k, v) in entries { ctx.setPropertyStr(obj: initObj, name: k, value: v.dupValue()) }
            let typeVal = ctx.newStringValue(type)
            let event = ctx.callConstructor(ctor, args: [typeVal, initObj])
            typeVal.freeValue()
            initObj.freeValue()
            if event.isException {
                ctx.getException().freeValue()
                continue
            }
            return event
        }
        return nil
    }

    func reportIfException(_ result: JeffJSValue, ctx: JeffJSContext, label: String) {
        guard result.isException else { return }
        let exc = ctx.getException()
        var message = ctx.toSwiftString(exc) ?? "unknown error"
        if exc.isObject {
            let stack = ctx.getPropertyStr(obj: exc, name: "stack")
            if let s = ctx.toSwiftString(stack), !s.isEmpty { message += "\n" + s }
            stack.freeValue()
        }
        exc.freeValue()
        onError?("[JeffJS] \(label): \(message)")
    }

    func throwDOMException(ctx: JeffJSContext, name: String, message: String) -> JeffJSValue {
        let global = ctx.getGlobalObject()
        let ctor = ctx.getPropertyStr(obj: global, name: "DOMException")
        global.freeValue()
        defer { ctor.freeValue() }
        if ctor.isFunction {
            let msg = ctx.newStringValue(message)
            let nm = ctx.newStringValue(name)
            let err = ctx.callConstructor(ctor, args: [msg, nm])
            msg.freeValue()
            nm.freeValue()
            if err.isException { return err }
            return ctx.throwValue(err)
        }
        return ctx.throwTypeError(message: message)
    }

    func throwHierarchyRequestError(ctx: JeffJSContext, method: String) -> JeffJSValue {
        throwDOMException(ctx: ctx, name: "HierarchyRequestError",
                          message: "Failed to execute '\(method)' on 'Node': The new child element contains the parent.")
    }

    // MARK: - Computed style (host hook, then inline, then UA defaults)

    /// Reads computed values for one operation. Holds the host's
    /// `__nativeGetComputedStyleValue` for its lifetime.
    @MainActor final class StyleReader {
        private let provider: ((DOMNode, String) -> String?)?
        private let ctx: JeffJSContext
        private let hostFn: JeffJSValue

        init(bridge: JeffJSDOMBridge, ctx: JeffJSContext) {
            self.ctx = ctx
            self.provider = bridge.computedStyleProvider
            if bridge.computedStyleProvider == nil {
                let global = ctx.getGlobalObject()
                hostFn = ctx.getPropertyStr(obj: global, name: "__nativeGetComputedStyleValue")
                global.freeValue()
            } else {
                hostFn = .undefined
            }
        }

        deinit { hostFn.freeValue() }

        /// The host's value, or nil when it has none.
        func hostValue(_ node: DOMNode, _ property: String) -> String? {
            if let provider {
                if let v = provider(node, property), !v.isEmpty { return v.lowercased() }
                return nil
            }
            guard hostFn.isFunction else { return nil }
            let id = ctx.newStringValue(node.id.uuidString)
            let prop = ctx.newStringValue(property)
            let r = ctx.call(hostFn, this: .undefined, args: [id, prop])
            id.freeValue()
            prop.freeValue()
            defer { r.freeValue() }
            if r.isException { ctx.getException().freeValue(); return nil }
            guard let s = ctx.toSwiftString(r), !s.isEmpty, !r.isUndefined, !r.isNull else { return nil }
            return s.trimmingCharacters(in: .whitespaces).lowercased()
        }

        /// Host value, else the inline declaration, else the UA stylesheet's.
        func value(_ node: DOMNode, _ property: String) -> String? {
            if let v = hostValue(node, property) { return v }
            if let v = JeffJSDOMBridge.inlineStyleValue(node, property) { return v }
            return JeffJSDOMBridge.uaDefault(node, property)
        }

        /// `display`, with the UA stylesheet's defaults when nobody says.
        func display(_ node: DOMNode) -> String {
            if let v = value(node, "display") { return v }
            return JeffJSDOMBridge.defaultDisplay(node)
        }
    }

    static func inlineStyleValue(_ node: DOMNode, _ property: String) -> String? {
        guard let style = node.attributes["style"], !style.isEmpty else { return nil }
        guard var v = parseInlineStyles(style)[property] else { return nil }
        if let bang = v.range(of: "!important") { v = String(v[..<bang.lowerBound]) }
        v = v.trimmingCharacters(in: .whitespaces).lowercased()
        return v.isEmpty ? nil : v
    }

    /// UA stylesheet values the rendered-text algorithms depend on (other
    /// than `display`): `white-space` of the preformatted elements.
    static func uaDefault(_ node: DOMNode, _ property: String) -> String? {
        guard node.nodeType == .element, node.isHTMLNamespace, let tag = node.tagName?.lowercased() else { return nil }
        switch property {
        case "white-space":
            switch tag {
            case "pre", "listing", "xmp", "plaintext": return "pre"
            case "textarea": return "pre-wrap"
            case "nobr": return "nowrap"
            case "td", "th": return node.attributes["nowrap"] != nil ? "nowrap" : nil
            default: return nil
            }
        default:
            return nil
        }
    }

    /// The HTML UA stylesheet's `display` for an element nobody styled.
    static func defaultDisplay(_ node: DOMNode) -> String {
        guard node.nodeType == .element, node.isHTMLNamespace, let tag = node.tagName?.lowercased() else { return "inline" }
        if node.attributes["hidden"] != nil { return "none" }
        switch tag {
        case "head", "script", "style", "template", "title", "meta", "link", "base", "noscript", "datalist",
             "param", "source", "track", "area", "noembed", "noframes", "rp", "dialog":
            return tag == "dialog" && node.attributes["open"] != nil ? "block" : "none"
        case "input":
            return (node.attributes["type"]?.lowercased() == "hidden") ? "none" : "inline-block"
        case "li": return "list-item"
        case "table": return "table"
        case "tr": return "table-row"
        case "td", "th": return "table-cell"
        case "thead": return "table-header-group"
        case "tbody": return "table-row-group"
        case "tfoot": return "table-footer-group"
        case "caption": return "table-caption"
        case "col": return "table-column"
        case "colgroup": return "table-column-group"
        case "button", "select", "textarea", "meter", "progress": return "inline-block"
        case "html", "body", "summary", "legend", "center", "menu", "dir", "listing", "plaintext", "xmp",
             "search", "optgroup", "option", "frameset", "frame":
            return "block"
        default:
            return DOMNode.blockElements.contains(tag) ? "block" : "inline"
        }
    }

    /// Children of a closed `<details>` other than its summary are not rendered.
    static func isHiddenByClosedDetails(_ node: DOMNode) -> Bool {
        guard let parent = node.parent, parent.nodeType == .element, parent.isHTMLNamespace,
              parent.tagName == "details", parent.attributes["open"] == nil else { return false }
        let summary = parent.children.first { $0.nodeType == .element && $0.tagName == "summary" }
        return summary !== node
    }

    /// "Being rendered": connected, and neither it nor an ancestor has
    /// `display: none` (or sits in a closed details element).
    func isBeingRendered(_ node: DOMNode, style: StyleReader) -> Bool {
        guard isConnected(node) else { return false }
        var cursor: DOMNode? = node.nodeType == .element ? node : node.parent
        while let n = cursor, n !== root {
            if n.nodeType == .element {
                if style.display(n) == "none" { return false }
                if Self.isHiddenByClosedDetails(n) { return false }
            }
            cursor = n.parent
        }
        return true
    }

    // MARK: - innerText (HTML §3.2.7)

    private enum InnerTextItem {
        case text(String, collapsible: Bool)
        case lineBreak       // <br>, a table row's "\n"
        case tab             // a table cell's "\t"
        case required(Int)   // required line break count
    }

    private struct InheritedText {
        var visible = true
        var whiteSpace = "normal"
        var textTransform = "none"
    }

    /// The `innerText` getter: the rendered text, or the text content when
    /// the element is not being rendered.
    func innerText(of node: DOMNode, ctx: JeffJSContext) -> String {
        guard node.nodeType == .element else { return node.rawTextDescendants }
        let style = StyleReader(bridge: self, ctx: ctx)
        guard isBeingRendered(node, style: style) else { return node.rawTextDescendants }
        var inherited = InheritedText()
        // The element's inherited context comes from its own computed values.
        inherited.visible = !(["hidden", "collapse"].contains(inheritedValue(node, "visibility", style: style) ?? "visible"))
        inherited.whiteSpace = inheritedValue(node, "white-space", style: style) ?? "normal"
        inherited.textTransform = inheritedValue(node, "text-transform", style: style) ?? "none"
        var items: [InnerTextItem] = []
        for child in node.children { collectInnerText(child, inherited: inherited, style: style, into: &items) }
        return joinInnerText(items)
    }

    /// An inherited property: the host's computed value, else the nearest
    /// inline declaration on the node or an ancestor.
    private func inheritedValue(_ node: DOMNode, _ property: String, style: StyleReader) -> String? {
        if let v = style.hostValue(node, property) { return v }
        var cursor: DOMNode? = node
        while let n = cursor, n !== root {
            if let v = Self.inlineStyleValue(n, property) ?? Self.uaDefault(n, property), v != "inherit" { return v }
            cursor = n.parent
        }
        return nil
    }

    private static let blockLevelDisplays: Set<String> = [
        "block", "flow-root", "list-item", "table", "flex", "grid", "table-caption", "-webkit-box",
        "block flow", "block flow-root", "block flex", "block grid", "block table",
    ]

    private func collectInnerText(_ node: DOMNode, inherited: InheritedText, style: StyleReader, into items: inout [InnerTextItem]) {
        switch node.nodeType {
        case .text:
            guard inherited.visible else { return }
            let raw = node.textContent ?? ""
            guard !raw.isEmpty else { return }
            let (text, collapsible) = Self.processWhiteSpace(raw, whiteSpace: inherited.whiteSpace)
            items.append(.text(Self.applyTextTransform(text, inherited.textTransform), collapsible: collapsible))
        case .element:
            let display = style.display(node)
            if display == "none" || Self.isHiddenByClosedDetails(node) { return }
            let tag = node.isHTMLNamespace ? (node.tagName?.lowercased() ?? "") : ""
            var mine = inherited
            if let v = style.value(node, "visibility"), v != "inherit" { mine.visible = !(v == "hidden" || v == "collapse") }
            if let v = style.value(node, "white-space"), v != "inherit" { mine.whiteSpace = v }
            if let v = style.value(node, "text-transform"), v != "inherit" { mine.textTransform = v }
            var inner: [InnerTextItem] = []
            // Replaced/form elements contribute no text of their own.
            if !["textarea", "select", "img", "video", "audio", "canvas", "iframe", "object", "embed", "input", "svg", "math"].contains(tag) {
                for child in node.children { collectInnerText(child, inherited: mine, style: style, into: &inner) }
            }
            guard mine.visible else { items.append(contentsOf: inner); return }
            if tag == "br" { inner.append(.lineBreak) }
            if display == "table-cell", hasFollowingSibling(node, display: "table-cell", style: style) { inner.append(.tab) }
            if display == "table-row", hasFollowingSibling(node, display: "table-row", style: style) { inner.append(.lineBreak) }
            if tag == "p" {
                items.append(.required(2)); items.append(contentsOf: inner); items.append(.required(2))
            } else if Self.blockLevelDisplays.contains(display) {
                items.append(.required(1)); items.append(contentsOf: inner); items.append(.required(1))
            } else {
                items.append(contentsOf: inner)
            }
        default:
            return
        }
    }

    /// Whether a later sibling (a cell in the same row, a later row) exists.
    private func hasFollowingSibling(_ node: DOMNode, display: String, style: StyleReader) -> Bool {
        var cursor = nextSibling(of: node)
        while let n = cursor {
            if n.nodeType == .element, style.display(n) == display { return true }
            cursor = nextSibling(of: n)
        }
        return false
    }

    /// CSS Text §4.1 white-space processing for one text node. Returns the
    /// text and whether its spaces are collapsible across node boundaries.
    private static func processWhiteSpace(_ raw: String, whiteSpace: String) -> (String, Bool) {
        switch whiteSpace {
        case "pre", "pre-wrap", "break-spaces", "preserve", "preserve breaks":
            return (raw.replacingOccurrences(of: "\r\n", with: "\n"), false)
        case "pre-line", "preserve-breaks":
            var out = ""
            var pendingSpace = false
            for scalar in raw.unicodeScalars {
                if scalar == "\n" || scalar == "\r" {
                    pendingSpace = false
                    if scalar == "\r" { continue }
                    while out.hasSuffix(" ") { out.removeLast() }
                    out.append("\n")
                } else if scalar == " " || scalar == "\t" || scalar == "\u{0C}" {
                    pendingSpace = true
                } else {
                    if pendingSpace, !out.hasSuffix("\n") { out.append(" ") }
                    pendingSpace = false
                    out.unicodeScalars.append(scalar)
                }
            }
            if pendingSpace { out.append(" ") }
            return (out, true)
        default:
            var out = ""
            var inSpace = false
            for scalar in raw.unicodeScalars {
                if DOMNode.isASCIIWhitespace(scalar) {
                    if !inSpace { out.append(" "); inSpace = true }
                } else {
                    out.unicodeScalars.append(scalar)
                    inSpace = false
                }
            }
            return (out, true)
        }
    }

    private static func applyTextTransform(_ text: String, _ transform: String) -> String {
        switch transform {
        case "uppercase": return text.uppercased()
        case "lowercase": return text.lowercased()
        case "capitalize":
            var out = ""
            var atWordStart = true
            for ch in text {
                if ch.isLetter || ch.isNumber {
                    out += atWordStart ? String(ch).uppercased() : String(ch)
                    atWordStart = false
                } else {
                    out.append(ch)
                    atWordStart = ch.isWhitespace || ch.isPunctuation && ch != "'"
                }
            }
            return out
        default:
            return text
        }
    }

    /// Joins the items: collapsible spaces collapse across nodes and vanish
    /// at line starts/ends; runs of required line breaks become the maximum
    /// count of "\n"; leading ones are dropped. Trailing ones are kept, as
    /// WebKit does when the element is followed by rendered content (the
    /// spec drops them; the reference engine wins).
    private func joinInnerText(_ items: [InnerTextItem]) -> String {
        var out = ""
        var pending = 0
        var started = false
        var trailingSpace = false
        func dropTrailingSpace() {
            if trailingSpace { out.removeLast(); trailingSpace = false }
        }
        func flushPending() {
            guard pending > 0 else { return }
            dropTrailingSpace()
            out += String(repeating: "\n", count: pending)
            pending = 0
        }
        for item in items {
            switch item {
            case .required(let k):
                if started { pending = max(pending, k) }
            case .text(var s, let collapsible):
                guard !s.isEmpty else { continue }
                flushPending()
                if collapsible {
                    if s.hasPrefix(" "), out.isEmpty || out.hasSuffix("\n") || out.hasSuffix("\t") || trailingSpace {
                        s.removeFirst()
                    }
                    guard !s.isEmpty else { continue }
                    out += s
                    trailingSpace = s.hasSuffix(" ")
                } else {
                    out += s
                    trailingSpace = false
                }
                started = true
            case .lineBreak:
                flushPending()
                dropTrailingSpace()
                out += "\n"
                started = true
            case .tab:
                flushPending()
                dropTrailingSpace()
                out += "\t"
                started = true
            }
        }
        dropTrailingSpace()
        if pending > 0 { out += String(repeating: "\n", count: pending) }
        return out
    }

    /// The `innerText` setter (HTML §3.2.7 "rendered text fragment"): Text
    /// nodes with a `<br>` for every line break.
    func setInnerText(_ node: DOMNode, _ value: String) {
        var nodes: [DOMNode] = []
        let normalized = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if !line.isEmpty { nodes.append(DOMNode.text(line)) }
            if i < lines.count - 1 { nodes.append(DOMNode.element(tag: "br")) }
        }
        replaceAllChildren(of: node, with: nodes)
    }

    // MARK: - Focus (HTML §6.6)

    /// The currently focused element, if it is still in the document.
    var currentFocus: DOMNode? {
        guard let f = focusedElement, isConnected(f) else { return nil }
        return f
    }

    /// `document.activeElement`: the focused element, else body, else html.
    func activeElement() -> DOMNode? {
        if let f = currentFocus { return f }
        let html = root.children.first { $0.nodeType == .element && $0.tagName == "html" }
        if let body = html?.children.first(where: { $0.nodeType == .element && ($0.tagName == "body" || $0.tagName == "frameset") }) {
            return body
        }
        return html
    }

    private static let disableableControls: Set<String> = ["button", "input", "select", "textarea", "optgroup", "option", "fieldset"]

    /// "Actually disabled" (HTML §4.10.18.5), incl. a disabled fieldset
    /// ancestor (outside its first legend).
    func isDisabledFormControl(_ node: DOMNode) -> Bool {
        guard node.nodeType == .element, node.isHTMLNamespace, let tag = node.tagName?.lowercased(),
              Self.disableableControls.contains(tag) else { return false }
        if node.attributes["disabled"] != nil { return true }
        if tag == "option" || tag == "optgroup" {
            if let p = node.parent, p.tagName == "optgroup", p.attributes["disabled"] != nil { return true }
            return false
        }
        var child = node
        var cursor = node.parent
        while let ancestor = cursor {
            if ancestor.nodeType == .element, ancestor.tagName == "fieldset", ancestor.attributes["disabled"] != nil {
                let firstLegend = ancestor.children.first { $0.nodeType == .element && $0.tagName == "legend" }
                if firstLegend !== child { return true }
            }
            child = ancestor
            cursor = ancestor.parent
        }
        return false
    }

    /// A focusable area (HTML §6.6.2): an element that is focusable by
    /// default or has a valid tabindex, not disabled, being rendered and
    /// visible.
    func isFocusable(_ node: DOMNode, style: StyleReader) -> Bool {
        guard node.nodeType == .element, isConnected(node) else { return false }
        let tag = node.tagName?.lowercased() ?? ""
        var focusable = false
        if let tabindex = node.attributes["tabindex"], Int(tabindex.trimmingCharacters(in: .whitespaces)) != nil {
            focusable = true
        } else if node.isHTMLNamespace {
            switch tag {
            case "a", "area": focusable = node.attributes["href"] != nil
            case "button", "select", "textarea", "iframe": focusable = true
            case "input": focusable = node.attributes["type"]?.lowercased() != "hidden"
            case "summary":
                if let details = node.parent, details.tagName == "details" {
                    focusable = details.children.first { $0.nodeType == .element && $0.tagName == "summary" } === node
                }
            case "audio", "video": focusable = node.attributes["controls"] != nil
            default: break
            }
            if !focusable, let editable = node.attributes["contenteditable"]?.lowercased(),
               editable != "false" { focusable = true }
        } else if node.namespaceURI == DOMNode.svgNamespace, tag == "a" {
            focusable = node.attributes["href"] != nil || node.attributes["xlink:href"] != nil
        }
        guard focusable, !isDisabledFormControl(node) else { return false }
        guard isBeingRendered(node, style: style) else { return false }
        let visibility = inheritedValue(node, "visibility", style: style) ?? "visible"
        return visibility != "hidden" && visibility != "collapse"
    }

    /// `el.focus()`: the focusing steps when `node` is focusable.
    func focusElement(_ node: DOMNode, ctx: JeffJSContext) {
        let style = StyleReader(bridge: self, ctx: ctx)
        guard isFocusable(node, style: style) else { return }
        runFocusUpdate(to: node, ctx: ctx, notifyHost: true)
    }

    /// `el.blur()`: the unfocusing steps when `node` is focused.
    func blurElement(_ node: DOMNode, ctx: JeffJSContext) {
        guard currentFocus === node else { return }
        runFocusUpdate(to: nil, ctx: ctx, notifyHost: true)
    }

    /// The host focused `node` (a native control became first responder).
    func hostFocusChanged(to node: DOMNode?, ctx: JeffJSContext) {
        runFocusUpdate(to: node, ctx: ctx, notifyHost: false)
    }

    /// The host's control for `node` resigned first responder.
    func hostBlurred(_ node: DOMNode, ctx: JeffJSContext) {
        guard currentFocus === node else { return }
        runFocusUpdate(to: nil, ctx: ctx, notifyHost: false)
    }

    /// HTML "focus update steps": blur + focusout at the old element (with
    /// activeElement already the body), then focus + focusin at the new one.
    /// blur/focus do not bubble; focusout/focusin do. relatedTarget is the
    /// other element.
    func runFocusUpdate(to newFocus: DOMNode?, ctx: JeffJSContext, notifyHost: Bool) {
        let old = currentFocus
        if old === newFocus { return }
        focusedElement = nil
        if let old {
            if DOMNode.focusedNode === old { DOMNode.focusedNode = nil }
            fireFocusEvent("blur", at: old, related: newFocus, bubbles: false, ctx: ctx)
            fireFocusEvent("focusout", at: old, related: newFocus, bubbles: true, ctx: ctx)
            notifyMutation(for: old)
            // A blur/focusout listener moved focus itself: that wins.
            if focusedElement != nil { return }
        }
        if let newFocus {
            focusedElement = newFocus
            DOMNode.focusedNode = newFocus
            notifyMutation(for: newFocus)
            fireFocusEvent("focus", at: newFocus, related: old, bubbles: false, ctx: ctx)
            fireFocusEvent("focusin", at: newFocus, related: old, bubbles: true, ctx: ctx)
        }
        if notifyHost { onFocusChange?(currentFocus, old) }
    }

    private func fireFocusEvent(_ type: String, at node: DOMNode, related: DOMNode?, bubbles: Bool, ctx: JeffJSContext) {
        let target = jsValue(for: node, ctx: ctx)
        defer { target.freeValue() }
        let relatedValue = related.map { jsValue(for: $0, ctx: ctx) } ?? .null
        defer { relatedValue.freeValue() }
        let global = ctx.getGlobalObject()
        defer { global.freeValue() }
        guard let event = makeEvent(ctx: ctx, constructors: ["FocusEvent", "Event"], type: type,
                                    init: [("bubbles", .newBool(bubbles)), ("cancelable", .newBool(false)),
                                           ("composed", .newBool(true)), ("view", global),
                                           ("relatedTarget", relatedValue)]) else { return }
        // UA-fired, like a browser's.
        ctx.setPropertyStr(obj: event, name: "isTrusted", value: .newBool(true))
        eventBridge?.dispatchFromTarget(ctx: ctx, target: target, type: type, event: event)
        event.freeValue()
    }

    /// HTML §6.6.5 autofocus: the first connected, focusable `[autofocus]`
    /// element, unless something already has focus.
    func runAutofocus() {
        guard let ctx = jsContext, currentFocus == nil else { return }
        let style = StyleReader(bridge: self, ctx: ctx)
        var found: DOMNode?
        root.forEachDescendantElement { n in
            if found == nil, n.attributes["autofocus"] != nil, isFocusable(n, style: style) { found = n }
        }
        if let found { runFocusUpdate(to: found, ctx: ctx, notifyHost: true) }
    }

    // MARK: - click() and activation behaviour (HTML §6.2, DOM §2.9)

    private struct CheckablePreActivation {
        let input: DOMNode
        let wasChecked: Bool
        let isRadio: Bool
        let previousRadio: DOMNode?
    }

    /// `HTMLElement.click()`. Returns false when a listener canceled the click.
    @discardableResult
    func click(_ node: DOMNode, ctx: JeffJSContext) -> Bool {
        guard node.nodeType == .element, !isDisabledFormControl(node) else { return true }
        guard clickInProgress.insert(node.id).inserted else { return true }
        defer { clickInProgress.remove(node.id) }
        guard let eventBridge else { return true }

        let activation = activationTarget(for: node)
        let pre = activation.flatMap { legacyPreActivation($0, ctx: ctx) }

        let target = jsValue(for: node, ctx: ctx)
        defer { target.freeValue() }
        let global = ctx.getGlobalObject()
        defer { global.freeValue() }
        guard let event = makeEvent(ctx: ctx, constructors: ["PointerEvent", "MouseEvent", "Event"], type: "click",
                                    init: [("bubbles", .newBool(true)), ("cancelable", .newBool(true)),
                                           ("composed", .newBool(true)), ("view", global),
                                           ("pointerId", .newInt32(-1)), ("detail", .newInt32(1))]) else { return true }
        let notCanceled = eventBridge.dispatchFromTarget(ctx: ctx, target: target, type: "click", event: event)
        event.freeValue()

        if let activation {
            if notCanceled {
                runActivationBehavior(activation, clickTarget: node, pre: pre, ctx: ctx)
            } else if let pre {
                legacyCanceledActivation(pre, ctx: ctx)
            }
        }
        return notCanceled
    }

    /// DOM dispatch "activation target": the target if it has activation
    /// behaviour, else the nearest ancestor that does (click bubbles).
    private func activationTarget(for node: DOMNode) -> DOMNode? {
        var cursor: DOMNode? = node
        while let n = cursor, n !== root {
            if hasActivationBehavior(n) { return n }
            cursor = n.parent
        }
        return nil
    }

    private func hasActivationBehavior(_ node: DOMNode) -> Bool {
        guard node.nodeType == .element, let tag = node.tagName?.lowercased() else { return false }
        if !node.isHTMLNamespace { return false }
        switch tag {
        case "a", "area": return node.attributes["href"] != nil
        case "button", "label": return true
        case "input":
            let type = node.attributes["type"]?.lowercased() ?? "text"
            return ["checkbox", "radio", "submit", "image", "reset", "button"].contains(type)
        case "summary":
            guard let details = node.parent, details.tagName == "details" else { return false }
            return details.children.first { $0.nodeType == .element && $0.tagName == "summary" } === node
        default: return false
        }
    }

    private func inputType(_ node: DOMNode) -> String {
        node.attributes["type"]?.lowercased() ?? "text"
    }

    private func readChecked(_ node: DOMNode, ctx: JeffJSContext) -> Bool {
        let wrapper = wrapElement(node, ctx: ctx)
        defer { wrapper.freeValue() }
        let v = ctx.getPropertyStr(obj: wrapper, name: "checked")
        defer { v.freeValue() }
        if v.isException { ctx.getException().freeValue(); return node.attributes["checked"] != nil }
        return ctx.toBool(v)
    }

    /// Writes `checked` through the JS property, so a host form-control
    /// implementation (checkedness, radio groups) sees it.
    private func writeChecked(_ node: DOMNode, _ value: Bool, ctx: JeffJSContext) {
        let wrapper = wrapElement(node, ctx: ctx)
        defer { wrapper.freeValue() }
        if !ctx.setPropertyStr(obj: wrapper, name: "checked", value: .newBool(value)) {
            ctx.getException().freeValue()
        }
    }

    /// The form owner: the `form` attribute's element, else the nearest form.
    func formOwner(of node: DOMNode) -> DOMNode? {
        if let formID = node.attributes["form"] {
            var top = node
            while let p = top.parent { top = p }
            return findElement(in: top, where: { $0.tagName == "form" && $0.attributes["id"] == formID })
        }
        var cursor = node.parent
        while let n = cursor {
            if n.nodeType == .element, n.isHTMLNamespace, n.tagName == "form" { return n }
            cursor = n.parent
        }
        return nil
    }

    /// The other radio buttons in `input`'s group (same name, same form owner, same tree).
    private func radioGroup(of input: DOMNode) -> [DOMNode] {
        guard let name = input.attributes["name"], !name.isEmpty else { return [] }
        var top = input
        while let p = top.parent { top = p }
        let owner = formOwner(of: input)
        var group: [DOMNode] = []
        top.forEachDescendantElement { n in
            if n !== input, n.tagName == "input", self.inputType(n) == "radio",
               n.attributes["name"] == name, self.formOwner(of: n) === owner {
                group.append(n)
            }
        }
        return group
    }

    private func legacyPreActivation(_ node: DOMNode, ctx: JeffJSContext) -> CheckablePreActivation? {
        guard node.tagName == "input" else { return nil }
        let type = inputType(node)
        guard type == "checkbox" || type == "radio" else { return nil }
        let was = readChecked(node, ctx: ctx)
        if type == "checkbox" {
            writeChecked(node, !was, ctx: ctx)
            return CheckablePreActivation(input: node, wasChecked: was, isRadio: false, previousRadio: nil)
        }
        let previous = radioGroup(of: node).first { readChecked($0, ctx: ctx) }
        writeChecked(node, true, ctx: ctx)
        if let previous, readChecked(previous, ctx: ctx) { writeChecked(previous, false, ctx: ctx) }
        return CheckablePreActivation(input: node, wasChecked: was, isRadio: true, previousRadio: previous)
    }

    private func legacyCanceledActivation(_ pre: CheckablePreActivation, ctx: JeffJSContext) {
        writeChecked(pre.input, pre.wasChecked, ctx: ctx)
        if pre.isRadio, let previous = pre.previousRadio, !pre.wasChecked {
            writeChecked(previous, true, ctx: ctx)
        }
    }

    private func fireSimpleEvent(_ type: String, at node: DOMNode, bubbles: Bool, cancelable: Bool = false, ctx: JeffJSContext) {
        let target = jsValue(for: node, ctx: ctx)
        defer { target.freeValue() }
        guard let event = makeEvent(ctx: ctx, constructors: ["Event"], type: type,
                                    init: [("bubbles", .newBool(bubbles)), ("cancelable", .newBool(cancelable)),
                                           ("composed", .newBool(type == "input"))]) else { return }
        ctx.setPropertyStr(obj: event, name: "isTrusted", value: .newBool(true))
        eventBridge?.dispatchFromTarget(ctx: ctx, target: target, type: type, event: event)
        event.freeValue()
    }

    private func runActivationBehavior(_ node: DOMNode, clickTarget: DOMNode, pre: CheckablePreActivation?, ctx: JeffJSContext) {
        let tag = node.tagName?.lowercased() ?? ""
        switch tag {
        case "input":
            let type = inputType(node)
            if let pre {
                // HTML §4.10.5.1.15/16: input then change, when the state changed.
                guard isConnected(node) else { return }
                if pre.isRadio && pre.wasChecked { return }
                fireSimpleEvent("input", at: node, bubbles: true, ctx: ctx)
                fireSimpleEvent("change", at: node, bubbles: true, ctx: ctx)
            } else if type == "submit" || type == "image" {
                submitForm(of: node, ctx: ctx)
            } else if type == "reset" {
                resetForm(of: node, ctx: ctx)
            }
        case "button":
            let type = node.attributes["type"]?.lowercased() ?? "submit"
            if type == "reset" { resetForm(of: node, ctx: ctx) }
            else if type != "button" { submitForm(of: node, ctx: ctx) }
        case "label":
            // Clicking a label clicks its control (unless the click came from
            // the control or something inside it).
            guard let control = labeledControl(of: node),
                  control !== clickTarget, !nodeContains(control, child: clickTarget) else { return }
            click(control, ctx: ctx)
        case "summary":
            guard let details = node.parent else { return }
            if details.attributes["open"] != nil {
                removeAttributeValue(details, name: "open")
            } else {
                setAttributeValue(details, name: "open", value: "")
            }
            notifyMutation(for: details)
        case "a", "area":
            _ = hostActivation(node, kind: "hyperlink", ctx: ctx)
        default:
            break
        }
    }

    private func submitForm(of node: DOMNode, ctx: JeffJSContext) {
        guard let form = formOwner(of: node) else { return }
        if callFormMethod(form, "requestSubmit", submitter: node, ctx: ctx) { return }
        _ = hostActivation(node, kind: "submit", ctx: ctx)
    }

    private func resetForm(of node: DOMNode, ctx: JeffJSContext) {
        guard let form = formOwner(of: node) else { return }
        if callFormMethod(form, "reset", submitter: nil, ctx: ctx) { return }
        _ = hostActivation(node, kind: "reset", ctx: ctx)
    }

    /// Calls `form.<method>(submitter?)` when the form has it (a host form
    /// implementation). True when it existed.
    private func callFormMethod(_ form: DOMNode, _ method: String, submitter: DOMNode?, ctx: JeffJSContext) -> Bool {
        let formValue = wrapElement(form, ctx: ctx)
        defer { formValue.freeValue() }
        let fn = ctx.getPropertyStr(obj: formValue, name: method)
        defer { fn.freeValue() }
        guard fn.isFunction else {
            if fn.isException { ctx.getException().freeValue() }
            return false
        }
        var args: [JeffJSValue] = []
        if let submitter { args.append(wrapElement(submitter, ctx: ctx)) }
        let r = ctx.call(fn, this: formValue, args: args)
        for a in args { a.freeValue() }
        reportIfException(r, ctx: ctx, label: "form.\(method)")
        r.freeValue()
        return true
    }

    /// `onActivationBehavior`, else `window.__nativeActivationBehavior(el, kind)`.
    private func hostActivation(_ node: DOMNode, kind: String, ctx: JeffJSContext) -> Bool {
        if let hook = onActivationBehavior { return hook(node, kind) }
        let global = ctx.getGlobalObject()
        defer { global.freeValue() }
        let fn = ctx.getPropertyStr(obj: global, name: "__nativeActivationBehavior")
        defer { fn.freeValue() }
        guard fn.isFunction else { return false }
        let el = wrapElement(node, ctx: ctx)
        let k = ctx.newStringValue(kind)
        let r = ctx.call(fn, this: .undefined, args: [el, k])
        el.freeValue()
        k.freeValue()
        reportIfException(r, ctx: ctx, label: "__nativeActivationBehavior")
        let handled = !r.isException && ctx.toBool(r)
        r.freeValue()
        return handled
    }

    // MARK: - label.control / labels (HTML §4.10.4)

    private static let labelableTags: Set<String> = ["button", "input", "meter", "output", "progress", "select", "textarea"]

    func isLabelable(_ node: DOMNode) -> Bool {
        guard node.nodeType == .element, node.isHTMLNamespace, let tag = node.tagName?.lowercased(),
              Self.labelableTags.contains(tag) else { return false }
        return !(tag == "input" && inputType(node) == "hidden")
    }

    /// A label's labeled control: its `for` target (when labelable), else
    /// its first labelable descendant.
    func labeledControl(of label: DOMNode) -> DOMNode? {
        if let forID = label.attributes["for"] {
            var top = label
            while let p = top.parent { top = p }
            guard let target = findElement(in: top, where: { $0.attributes["id"] == forID }) else { return nil }
            return isLabelable(target) ? target : nil
        }
        var found: DOMNode?
        label.forEachDescendantElement { n in
            if found == nil, isLabelable(n) { found = n }
        }
        return found
    }

    /// A labelable element's labels, in tree order.
    func labels(of node: DOMNode) -> [DOMNode] {
        var top = node
        while let p = top.parent { top = p }
        var result: [DOMNode] = []
        top.forEachDescendantElement { n in
            if n.tagName == "label", n.isHTMLNamespace, labeledControl(of: n) === node { result.append(n) }
        }
        return result
    }

    // MARK: - dataset (HTML §3.2.6.6)

    private static let datasetShim = #"""
    (function (N) {
      'use strict';
      var H = {
        get: function (t, p, r) {
          if (typeof p === 'string') { var v = N.get(t, p); if (v !== undefined) return v; }
          return Reflect.get(t, p, r);
        },
        set: function (t, p, v, r) {
          if (typeof p !== 'string') return Reflect.set(t, p, v, r);
          if (!N.set(t, p, String(v))) {
            var msg = "Failed to set the '" + p + "' property on 'DOMStringMap': '" + p + "' is not a valid property name.";
            throw (typeof DOMException === 'function') ? new DOMException(msg, 'SyntaxError') : new SyntaxError(msg);
          }
          return true;
        },
        has: function (t, p) { return (typeof p === 'string' && N.has(t, p)) || Reflect.has(t, p); },
        deleteProperty: function (t, p) { if (typeof p === 'string') N.del(t, p); return true; },
        ownKeys: function (t) { return N.keys(t); },
        getOwnPropertyDescriptor: function (t, p) {
          if (typeof p !== 'string' || !N.has(t, p)) return undefined;
          return { value: N.get(t, p), writable: true, enumerable: true, configurable: true };
        },
        defineProperty: function (t, p, d) {
          if (typeof p !== 'string' || !d || !('value' in d)) return false;
          return N.set(t, p, String(d.value));
        }
      };
      return function (target) { return new Proxy(target, H); };
    })
    """#

    /// camelCase property -> `data-` attribute name; nil when invalid for
    /// setting (a "-" followed by an ASCII lowercase letter).
    static func datasetAttributeName(_ property: String, forSetting: Bool) -> String? {
        var out = "data-"
        let scalars = Array(property.unicodeScalars)
        for (i, u) in scalars.enumerated() {
            if forSetting, u == "-", i + 1 < scalars.count, scalars[i + 1].value >= 0x61, scalars[i + 1].value <= 0x7A {
                return nil
            }
            if u.value >= 0x41 && u.value <= 0x5A {
                out += "-"
                out.unicodeScalars.append(Unicode.Scalar(u.value + 0x20)!)
            } else {
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// `data-` attribute name -> camelCase property (nil if not a dataset name).
    static func datasetPropertyName(_ attribute: String) -> String? {
        guard attribute.hasPrefix("data-") else { return nil }
        let rest = Array(attribute.unicodeScalars.dropFirst(5))
        if rest.contains(where: { $0.value >= 0x41 && $0.value <= 0x5A }) { return nil }
        var out = ""
        var i = 0
        while i < rest.count {
            let u = rest[i]
            if u == "-", i + 1 < rest.count, rest[i + 1].value >= 0x61, rest[i + 1].value <= 0x7A {
                out.unicodeScalars.append(Unicode.Scalar(rest[i + 1].value - 0x20)!)
                i += 2
                continue
            }
            out.unicodeScalars.append(u)
            i += 1
        }
        return out
    }

    private func datasetNode(_ target: JeffJSValue) -> DOMNode? { extractNode(from: target) }

    /// Existing attribute for a supported property name.
    private func datasetAttribute(_ node: DOMNode, _ property: String) -> String? {
        guard let attr = Self.datasetAttributeName(property, forSetting: false),
              node.attributes[attr] != nil, Self.datasetPropertyName(attr) == property else { return nil }
        return attr
    }

    func installDatasetFactory(ctx: JeffJSContext) {
        guard datasetFactory == nil else { return }
        let natives = ctx.newObject()
        defer { natives.freeValue() }
        ctx.setPropertyFunc(obj: natives, name: "get", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 2, let node = self.datasetNode(args[0]),
                  let prop = ctx.toSwiftString(args[1]),
                  let attr = self.datasetAttribute(node, prop), let value = node.attributes[attr] else { return .undefined }
            return ctx.newStringValue(value)
        }, length: 2)
        ctx.setPropertyFunc(obj: natives, name: "has", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 2, let node = self.datasetNode(args[0]),
                  let prop = ctx.toSwiftString(args[1]) else { return .newBool(false) }
            return .newBool(self.datasetAttribute(node, prop) != nil)
        }, length: 2)
        ctx.setPropertyFunc(obj: natives, name: "set", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 3, let node = self.datasetNode(args[0]),
                  let prop = ctx.toSwiftString(args[1]) else { return .newBool(false) }
            guard let attr = Self.datasetAttributeName(prop, forSetting: true) else { return .newBool(false) }
            self.setAttributeValue(node, name: attr, value: ctx.toSwiftString(args[2]) ?? "")
            self.notifyMutation(for: node)
            return .newBool(true)
        }, length: 3)
        ctx.setPropertyFunc(obj: natives, name: "del", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 2, let node = self.datasetNode(args[0]),
                  let prop = ctx.toSwiftString(args[1]),
                  let attr = self.datasetAttribute(node, prop) else { return .undefined }
            self.removeAttributeValue(node, name: attr)
            self.notifyMutation(for: node)
            return .undefined
        }, length: 2)
        ctx.setPropertyFunc(obj: natives, name: "keys", fn: { [weak self] ctx, _, args in
            let arr = ctx.newArray()
            guard let self, let target = args.first, let node = self.datasetNode(target) else { return arr }
            var i: UInt32 = 0
            for name in node.orderedAttributeNames {
                guard let prop = Self.datasetPropertyName(name) else { continue }
                ctx.setPropertyUint32(obj: arr, index: i, value: ctx.newStringValue(prop))
                i += 1
            }
            return arr
        }, length: 1)
        let shim = ctx.eval(input: Self.datasetShim, filename: "<dataset>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        defer { shim.freeValue() }
        guard shim.isFunction else { reportIfException(shim, ctx: ctx, label: "dataset install"); return }
        let factory = ctx.call(shim, this: .undefined, args: [natives])
        if factory.isFunction {
            datasetFactory = factory
        } else {
            reportIfException(factory, ctx: ctx, label: "dataset install")
            factory.freeValue()
        }
    }

    /// The element's DOMStringMap (one per element, cached).
    func dataset(for node: DOMNode, ctx: JeffJSContext) -> JeffJSValue {
        if let cached = datasetCache[node.id] { return cached.dupValue() }
        installDatasetFactory(ctx: ctx)
        guard let factory = datasetFactory else { return .undefined }
        // The proxy's target carries the node (not the wrapper), so a cached
        // dataset never keeps the element's wrapper alive.
        let target = ctx.newObject()
        if let obj = target.toObject() { obj.payload = .opaque(node) }
        let proxy = ctx.call(factory, this: .undefined, args: [target])
        target.freeValue()
        guard proxy.isObject else {
            reportIfException(proxy, ctx: ctx, label: "dataset")
            proxy.freeValue()
            return .undefined
        }
        datasetCache[node.id] = proxy.dupValue()
        return proxy
    }

    // MARK: - Accessors installed on the element prototype

    /// `__get_*`/`__set_*` natives for ownerDocument, dataset, open, control
    /// and labels (wired to accessors by `installElementPropertyShim`).
    func registerInteractionAccessors(on el: JeffJSValue, ctx: JeffJSContext) {
        // ownerDocument — the node document (null for a document).
        ctx.setPropertyFunc(obj: el, name: "__get_ownerDocument", fn: { [weak self] ctx, thisVal, _ in
            guard let self, let node = self.extractNode(from: thisVal), node.nodeType != .document else { return .null }
            let document = self.nodeDocument(of: node)
            if document === self.root { return self.documentJSValue?.dupValue() ?? .null }
            return self.wrapDetachedDocument(document, ctx: ctx)
        }, length: 0)

        // dataset — HTMLElement / SVGElement only.
        ctx.setPropertyFunc(obj: el, name: "__get_dataset", fn: { [weak self] ctx, thisVal, _ in
            guard let self, let node = self.extractNode(from: thisVal), node.nodeType == .element else { return .undefined }
            return self.dataset(for: node, ctx: ctx)
        }, length: 0)

        // open — details / dialog reflect the boolean attribute; elsewhere it
        // is an ordinary expando (the setter defines an own property).
        func shadow(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ name: String, _ value: JeffJSValue) {
            let atom = ctx.rt.findAtom(name)
            _ = ctx.definePropertyValue(obj: thisVal, atom: atom, value: value,
                                        flags: JS_PROP_WRITABLE | JS_PROP_ENUMERABLE | JS_PROP_CONFIGURABLE)
            ctx.rt.freeAtom(atom)
        }
        ctx.setPropertyFunc(obj: el, name: "__get_open", fn: { [weak self] _, thisVal, _ in
            guard let self, let node = self.extractNode(from: thisVal), node.nodeType == .element,
                  node.isHTMLNamespace, node.tagName == "details" || node.tagName == "dialog" else { return .undefined }
            return .newBool(node.attributes["open"] != nil)
        }, length: 0)
        ctx.setPropertyFunc(obj: el, name: "__set_open", fn: { [weak self] ctx, thisVal, args in
            guard let self, let node = self.extractNode(from: thisVal) else { return .undefined }
            let value = args.first ?? .undefined
            guard node.nodeType == .element, node.isHTMLNamespace,
                  node.tagName == "details" || node.tagName == "dialog" else {
                shadow(ctx, thisVal, "open", value)
                return .undefined
            }
            let open = ctx.toBool(value)
            if open, node.attributes["open"] == nil {
                self.setAttributeValue(node, name: "open", value: "")
                self.notifyMutation(for: node)
            } else if !open, node.attributes["open"] != nil {
                self.removeAttributeValue(node, name: "open")
                self.notifyMutation(for: node)
            }
            return .undefined
        }, length: 1)

        // label.control / <labelable>.labels
        ctx.setPropertyFunc(obj: el, name: "__get_control", fn: { [weak self] ctx, thisVal, _ in
            guard let self, let node = self.extractNode(from: thisVal) else { return .undefined }
            guard node.nodeType == .element, node.isHTMLNamespace, node.tagName == "label" else { return .undefined }
            guard let control = self.labeledControl(of: node) else { return .null }
            return self.wrapElement(control, ctx: ctx)
        }, length: 0)
        ctx.setPropertyFunc(obj: el, name: "__set_control", fn: { ctx, thisVal, args in
            shadow(ctx, thisVal, "control", args.first ?? .undefined)
            return .undefined
        }, length: 1)
        ctx.setPropertyFunc(obj: el, name: "__get_labels", fn: { [weak self] ctx, thisVal, _ in
            guard let self, let node = self.extractNode(from: thisVal) else { return .undefined }
            guard self.isLabelable(node) else { return node.nodeType == .element ? .null : .undefined }
            return self.wrapElementArray(self.labels(of: node), ctx: ctx)
        }, length: 0)
        ctx.setPropertyFunc(obj: el, name: "__set_labels", fn: { ctx, thisVal, args in
            shadow(ctx, thisVal, "labels", args.first ?? .undefined)
            return .undefined
        }, length: 1)
    }
}
