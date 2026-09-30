import Foundation

// MARK: - Shadow DOM and custom element reactions (JS side)
//
// DOM §4.2.2 (Element.attachShadow / shadowRoot, ShadowRoot), §4.2.2.3-4 (slots:
// HTMLSlotElement.assignedNodes / assignedElements / assign, Element.assignedSlot,
// `slotchange`), HTML §4.13.6 (custom element reactions: the page's customElements
// implementation registers one hook, called at the end of every DOM mutation that
// connects, disconnects or re-attributes a custom element candidate).
//
// The tree model lives in `DOMNode+Shadow.swift`. Shadow roots are wrapped like any
// node (`wrapElement`) and get `ShadowRoot.prototype`, which chains to the element
// prototype (innerHTML, querySelector, append, … all work on the fragment).

extension JeffJSDOMBridge {

    // MARK: Registration

    func registerShadowDOMAPI(on proto: JeffJSValue, ctx: JeffJSContext) {
        // attachShadow(init) — DOM §4.2.2 "attach a shadow root".
        ctx.setPropertyFunc(obj: proto, name: "attachShadow", fn: { [weak self] ctx, thisVal, args in
            guard let self, let host = self.extractNode(from: thisVal), host.nodeType == .element else {
                return ctx.throwTypeError(message: "Can only call Element.attachShadow on instances of Element")
            }
            guard let initObj = args.first, initObj.isObject else {
                return ctx.throwTypeError(message: "Type error")
            }
            let mode = Self.stringMember(ctx, initObj, "mode")
            guard mode == "open" || mode == "closed" else {
                return ctx.throwTypeError(message: "Type error")
            }
            let delegatesFocus = Self.boolMember(ctx, initObj, "delegatesFocus")
            let clonable = Self.boolMember(ctx, initObj, "clonable")
            let serializable = Self.boolMember(ctx, initObj, "serializable")
            let slotAssignment = Self.stringMember(ctx, initObj, "slotAssignment") ?? "named"
            guard let root = host.attachShadowRoot(mode: mode!, delegatesFocus: delegatesFocus,
                                                   slotAssignment: slotAssignment, clonable: clonable,
                                                   serializable: serializable) else {
                return self.throwDOMException(ctx: ctx, name: "NotSupportedError",
                                              message: "Operation is not supported")
            }
            // The host's box now shows the shadow tree instead of its light children.
            self.notifyMutation(for: host)
            return self.wrapElement(root, ctx: ctx)
        }, length: 1)

        // shadowRoot — the attached root when its mode is open, else null.
        accessor(on: proto, ctx: ctx, name: "shadowRoot") { bridge, ctx, node in
            guard let root = node.shadowRoot, root.shadowRootInfo?.mode == "open" else { return .null }
            return bridge.wrapElement(root, ctx: ctx)
        }

        // assignedSlot — the slot this node is assigned to, if its tree is open.
        accessor(on: proto, ctx: ctx, name: "assignedSlot") { bridge, ctx, node in
            guard let slot = node.assignedSlotNode,
                  slot.containingShadowRoot?.shadowRootInfo?.mode == "open" else { return .null }
            return bridge.wrapElement(slot, ctx: ctx)
        }

        // HTMLSlotElement.assignedNodes({flatten}) / assignedElements({flatten}).
        for (name, elementsOnly) in [("assignedNodes", false), ("assignedElements", true)] {
            ctx.setPropertyFunc(obj: proto, name: name, fn: { [weak self] ctx, thisVal, args in
                guard let self, let slot = self.extractNode(from: thisVal), slot.isSlotElement else {
                    return ctx.newArray()
                }
                let flatten = args.first.map { $0.isObject && Self.boolMember(ctx, $0, "flatten") } ?? false
                var nodes = flatten ? slot.flattenedAssignedNodes : slot.assignedNodes
                if elementsOnly { nodes = nodes.filter { $0.nodeType == .element } }
                return self.wrapElementArray(nodes, ctx: ctx)
            }, length: 0)
        }

        // HTMLSlotElement.assign(...nodes) — manual slot assignment.
        ctx.setPropertyFunc(obj: proto, name: "assign", fn: { [weak self] ctx, thisVal, args in
            guard let self, let slot = self.extractNode(from: thisVal), slot.isSlotElement else { return .undefined }
            let nodes = args.compactMap { self.extractNode(from: $0) }.filter { $0.isSlottable }
            slot.assignSlottables(nodes)
            if let host = slot.containingShadowRoot?.shadowHost { self.notifyMutation(for: host) }
            self.signalSlotChanges(in: slot.containingShadowRoot)
            return .undefined
        }, length: 0)

        buildShadowRootPrototype(elementPrototype: proto, ctx: ctx)
    }

    /// `ShadowRoot.prototype` (→ the element prototype) and the global
    /// `ShadowRoot` interface object (not constructible).
    private func buildShadowRootPrototype(elementPrototype: JeffJSValue, ctx: JeffJSContext) {
        let srProto = ctx.newObjectProto(proto: elementPrototype)
        func info(_ node: DOMNode) -> DOMShadowRootInfo? { node.shadowRootInfo }
        accessor(on: srProto, ctx: ctx, name: "host") { bridge, ctx, node in
            guard let host = node.shadowHost else { return .null }
            return bridge.wrapElement(host, ctx: ctx)
        }
        accessor(on: srProto, ctx: ctx, name: "mode") { _, ctx, node in
            ctx.newStringValue(node.shadowRootInfo?.mode ?? "open")
        }
        accessor(on: srProto, ctx: ctx, name: "slotAssignment") { _, ctx, node in
            ctx.newStringValue(node.shadowRootInfo?.slotAssignment ?? "named")
        }
        accessor(on: srProto, ctx: ctx, name: "delegatesFocus") { _, _, node in
            .newBool(node.shadowRootInfo?.delegatesFocus ?? false)
        }
        accessor(on: srProto, ctx: ctx, name: "clonable") { _, _, node in
            .newBool(node.shadowRootInfo?.clonable ?? false)
        }
        accessor(on: srProto, ctx: ctx, name: "serializable") { _, _, node in
            .newBool(node.shadowRootInfo?.serializable ?? false)
        }
        // DocumentOrShadowRoot.activeElement: the focused element when it is in
        // this tree (retargeted to the root's tree otherwise: null here).
        accessor(on: srProto, ctx: ctx, name: "activeElement") { bridge, ctx, node in
            guard let focused = bridge.activeElement() else { return .null }
            var cur: DOMNode? = focused
            while let c = cur {
                if c.parent === node { return bridge.wrapElement(focused, ctx: ctx) }
                if c.isShadowRoot { break }
                cur = c.parent
            }
            return .null
        }
        // DocumentFragment.getElementById (NonElementParentNode).
        ctx.setPropertyFunc(obj: srProto, name: "getElementById", fn: { [weak self] ctx, thisVal, args in
            guard let self, let root = self.extractNode(from: thisVal),
                  let id = self.extractString(ctx: ctx, args: args, index: 0), !id.isEmpty else { return .null }
            var stack: [DOMNode] = root.children.reversed()
            while let n = stack.popLast() {
                if n.nodeType == .element, n.idAttribute == id { return self.wrapElement(n, ctx: ctx) }
                let kids = n.children
                if !kids.isEmpty { stack.append(contentsOf: kids.reversed()) }
            }
            return .null
        }, length: 1)
        ctx.setPropertyStr(obj: srProto, name: "nodeName", value: ctx.newStringValue("#document-fragment"))
        shadowRootPrototype = srProto

        // window.ShadowRoot: an interface object whose prototype is srProto.
        let ctor = ctx.newCFunction({ ctx, _, _ in ctx.throwTypeError(message: "Illegal constructor") },
                                    name: "ShadowRoot", length: 0)
        ctx.setPropertyStr(obj: ctor, name: "prototype", value: srProto.dupValue())
        ctx.setPropertyStr(obj: srProto, name: "constructor", value: ctor.dupValue())
        let global = ctx.getGlobalObject()
        ctx.setPropertyStr(obj: global, name: "ShadowRoot", value: ctor)
        global.freeValue()
    }

    /// A read-only accessor on `obj` whose getter reads `this`'s node.
    private func accessor(on obj: JeffJSValue, ctx: JeffJSContext, name: String,
                          _ body: @escaping (JeffJSDOMBridge, JeffJSContext, DOMNode) -> JeffJSValue) {
        let getter = ctx.newCFunction({ [weak self] ctx, thisVal, _ in
            guard let self, let node = self.extractNode(from: thisVal) else { return .null }
            return body(self, ctx, node)
        }, name: "get " + name, length: 0)
        ctx.setPropertyGetSet(obj: obj, name: name, getter: getter, setter: nil)
    }

    static func stringMember(_ ctx: JeffJSContext, _ obj: JeffJSValue, _ name: String) -> String? {
        let v = ctx.getPropertyStr(obj: obj, name: name)
        defer { v.freeValue() }
        if v.isUndefined || v.isNull { return nil }
        return ctx.toSwiftString(v)
    }

    static func boolMember(_ ctx: JeffJSContext, _ obj: JeffJSValue, _ name: String) -> Bool {
        let v = ctx.getPropertyStr(obj: obj, name: name)
        defer { v.freeValue() }
        return ctx.toBool(v)
    }

    // MARK: slotchange (DOM §4.2.2.5 "signal a slot change")

    /// Recomputes `root`'s slot assignment and fires `slotchange` (bubbles, not
    /// composed) at every slot whose assigned nodes changed since the last
    /// signal, in a microtask like the spec's signal slots (mutation observer
    /// microtask). No-op without shadow roots.
    func signalSlotChanges(in root: DOMNode?) {
        guard DOMNode.anyShadowRoots, let root, let info = root.shadowRootInfo,
              let assignment = root.slotAssignment() else { return }
        var now: [ObjectIdentifier: [ObjectIdentifier]] = [:]
        for slot in assignment.slots {
            let ids = (assignment.assigned[ObjectIdentifier(slot)] ?? []).map { ObjectIdentifier($0) }
            now[ObjectIdentifier(slot)] = ids
        }
        var changed: [DOMNode] = []
        for slot in assignment.slots {
            let key = ObjectIdentifier(slot)
            if (info.signaled[key] ?? []) != (now[key] ?? []) { changed.append(slot) }
        }
        info.signaled = now
        guard !changed.isEmpty, let ctx = jsContext else { return }
        for slot in changed { pendingSlotChanges.append(slot) }
        if pendingSlotChanges.count == changed.count {
            // First signal since the last delivery: one microtask fires them all.
            ctx.rt.enqueueJob(ctx: ctx, jobFunc: { [weak self] ctx, _, _ in
                self?.fireSlotChanges(ctx: ctx)
                return .undefined
            }, args: [])
        }
    }

    private func fireSlotChanges(ctx: JeffJSContext) {
        let slots = pendingSlotChanges
        pendingSlotChanges = []
        for slot in slots {
            guard let event = makeEvent(ctx: ctx, constructors: ["Event"], type: "slotchange",
                                        init: [("bubbles", .newBool(true))]) else { continue }
            let target = wrapElement(slot, ctx: ctx)
            let dispatch = ctx.getPropertyStr(obj: target, name: "dispatchEvent")
            if dispatch.isFunction {
                let r = ctx.call(dispatch, this: target, args: [event])
                reportIfException(r, ctx: ctx, label: "slotchange")
                r.freeValue()
            }
            dispatch.freeValue()
            target.freeValue()
            event.freeValue()
        }
    }

    /// The shadow roots whose assignment a mutation of `parent`'s children or
    /// of `node`'s `slot`/`name` attribute can change: `parent`'s own shadow root
    /// (a host's light children) and the tree `parent` is in (slots moved).
    func slotChangeRoots(forChildrenOf parent: DOMNode) -> [DOMNode] {
        guard DOMNode.anyShadowRoots else { return [] }
        var roots: [DOMNode] = []
        if let r = parent.shadowRoot { roots.append(r) }
        if let r = parent.isShadowRoot ? parent : parent.containingShadowRoot { roots.append(r) }
        return roots
    }

    // MARK: Custom element reactions (HTML §4.13.6)

    /// True for an element the page's customElements implementation may care
    /// about: a hyphenated local name (autonomous) or an `is` attribute.
    @inline(__always)
    static func isCustomElementCandidate(_ node: DOMNode) -> Bool {
        guard node.nodeType == .element, let tag = node.tagName else { return false }
        return tag.contains("-") || node.attributeValue("is") != nil
    }

    /// The candidates in `nodes`' subtrees, shadow-including, in shadow-including
    /// tree order (iterative).
    func customElementCandidates(in nodes: [DOMNode]) -> [DOMNode] {
        var out: [DOMNode] = []
        var stack: [DOMNode] = nodes.reversed()
        while let n = stack.popLast() {
            if Self.isCustomElementCandidate(n) { out.append(n) }
            let kids = n.children
            if !kids.isEmpty { stack.append(contentsOf: kids.reversed()) }
            if let root = n.shadowRoot { stack.append(root) }
        }
        return out
    }

    /// Calls the page hook: `hook(kind, list)` with kind "connected" /
    /// "disconnected" and a node list, or `hook("attribute", el, name, old, new)`.
    func runCustomElementReactions(_ kind: String, nodes: [DOMNode]) {
        guard let hook = customElementHook, let ctx = jsContext else { return }
        let list = customElementCandidates(in: nodes)
        guard !list.isEmpty else { return }
        let arr = wrapElementArray(list, ctx: ctx)
        let k = ctx.newStringValue(kind)
        let r = ctx.call(hook, this: .undefined, args: [k, arr])
        reportIfException(r, ctx: ctx, label: "custom element reactions")
        r.freeValue(); k.freeValue(); arr.freeValue()
    }

    func runCustomElementAttributeReaction(_ node: DOMNode, name: String, oldValue: String?, newValue: String?) {
        guard let hook = customElementHook, let ctx = jsContext, Self.isCustomElementCandidate(node) else { return }
        let el = wrapElement(node, ctx: ctx)
        let k = ctx.newStringValue("attribute")
        let n = ctx.newStringValue(name)
        let o = oldValue.map { ctx.newStringValue($0) } ?? .null
        let v = newValue.map { ctx.newStringValue($0) } ?? .null
        let r = ctx.call(hook, this: .undefined, args: [k, el, n, o, v])
        reportIfException(r, ctx: ctx, label: "custom element reactions")
        r.freeValue(); k.freeValue(); n.freeValue(); o.freeValue(); v.freeValue(); el.freeValue()
    }

    /// After a tree mutation: custom element reactions for the nodes that
    /// became connected / disconnected, and slot change signals.
    func afterTreeMutation(parent: DOMNode, inserted: [DOMNode], removed: [DOMNode]) {
        if customElementHook != nil, isConnected(parent) {
            if !removed.isEmpty { runCustomElementReactions("disconnected", nodes: removed) }
            if !inserted.isEmpty { runCustomElementReactions("connected", nodes: inserted) }
        }
        if DOMNode.anyShadowRoots {
            for root in slotChangeRoots(forChildrenOf: parent) { signalSlotChanges(in: root) }
            // A slot inserted into / removed from a shadow tree changes that tree's assignment.
            if !inserted.isEmpty || !removed.isEmpty, let root = parent.isShadowRoot ? parent : parent.containingShadowRoot,
               !slotChangeRoots(forChildrenOf: parent).contains(where: { $0 === root }) {
                signalSlotChanges(in: root)
            }
        }
    }

    /// Elements at or below `start` (optionally with `localName`), in
    /// shadow-including preorder: an element, then its shadow tree, then its
    /// children (DOM §4.2.2 "shadow-including tree order"). Iterative.
    func shadowIncludingElements(from start: DOMNode, localName: String?) -> [DOMNode] {
        var out: [DOMNode] = []
        var stack: [DOMNode] = [start]
        while let n = stack.popLast() {
            if n.nodeType == .element, localName == nil || n.tagName == localName { out.append(n) }
            let kids = n.children
            if !kids.isEmpty { stack.append(contentsOf: kids.reversed()) }
            if let r = n.shadowRoot { stack.append(r) }
        }
        return out
    }

    /// Installs `document.__rnSetCEHook(fn)` (the app's customElements
    /// implementation registers its reaction runner; null removes it) and
    /// `document.__rnCEDefined(name)`: `name` is now defined, so `:defined`
    /// (Selectors 4 §13.5, HTML §4.13: the element's custom element state is
    /// "custom") matches its elements — they are reported as mutated so the
    /// host restyles them.
    func installCustomElementHookSetter(on doc: JeffJSValue, ctx: JeffJSContext) {
        ctx.setPropertyFunc(obj: doc, name: "__rnCEDefined", fn: { [weak self] ctx, _, args in
            guard let self, let name = self.extractString(ctx: ctx, args: args, index: 0)?.lowercased(),
                  !name.isEmpty else { return ctx.newArray() }
            var names = DOMNode.definedCustomElements
            if names.insert(name).inserted {
                DOMNode.definedCustomElements = names
                DOMNode.bumpSelectorEpoch()
            }
            // The document's elements with that local name, shadow-including
            // tree order (HTML §4.13.4 define step 18: the upgrade candidates).
            let found = self.shadowIncludingElements(from: self.root, localName: name)
            self.notifyMutations(found.map { $0.id })
            return self.wrapElementArray(found, ctx: ctx)
        }, length: 1)
        // `document.__rnShadowIncludingElements(root, localName?)`: the element
        // descendants of `root` (inclusive), shadow-including tree order — for
        // `customElements.upgrade(root)` (closed roots included).
        ctx.setPropertyFunc(obj: doc, name: "__rnShadowIncludingElements", fn: { [weak self] ctx, _, args in
            guard let self, let first = args.first, let start = self.nodeArgument(first) else { return ctx.newArray() }
            let name = args.count > 1 ? self.extractString(ctx: ctx, args: args, index: 1)?.lowercased() : nil
            return self.wrapElementArray(self.shadowIncludingElements(from: start, localName: name), ctx: ctx)
        }, length: 2)
        ctx.setPropertyFunc(obj: doc, name: "__rnSetCEHook", fn: { [weak self] ctx, _, args in
            guard let self else { return .undefined }
            self.customElementHook?.freeValue()
            if let fn = args.first, fn.isFunction { self.customElementHook = fn.dupValue() } else { self.customElementHook = nil }
            return .undefined
        }, length: 1)
    }
}
