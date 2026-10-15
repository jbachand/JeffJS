import Foundation
import Synchronization

// MARK: - Shadow DOM (DOM §4.2.2 shadow trees, §4.2.2.3–4 slots, CSS Scoping 1 §2 flat tree)
//
// A shadow root is a DocumentFragment node (`nodeType == .documentFragment`)
// carrying a `DOMShadowRootInfo`. Its host keeps it in `State.shadowRoot`; it is
// never one of the host's `children`, so every DOM-tree walk (querySelector,
// serialisation, cloning, textContent, the element diff's walker) stays out of
// it, as in a browser.
//
// **Parent pointer.** The shadow root's `parent` is its **host** (the
// "shadow-including" parent). Everything that climbs to the document — node
// documents, `isConnected`, the event path (DOM §4.2.2: a shadow root's "get the
// parent" is its host), the renderer's "is this node in the page" checks, style
// depth — then works across the boundary unchanged. The DOM-tree answers that
// must stop at the root do so explicitly: `parentNode`/`parentElement` of a shadow
// root are null, `getRootNode()` returns the shadow root, `closest()` and the
// selector matcher's ancestor walks stop there, subtree MutationObservers do not
// cross it, and `contains()` walks children (never into a shadow root).
//
// **Flat tree.** Rendering walks `flatTreeChildren` / `flatTreeParent` (CSS
// Scoping 1 §2.1): a host's flat children are its shadow root's children (the
// light children are only rendered through slots), a `<slot>` in a shadow tree
// has its assigned nodes (or, when none, its own children as fallback), every
// other node its children. The shadow root node itself is not in the flat tree.
// With no shadow root anywhere (`DOMNode.anyShadowRoots` false) both are the
// plain `children` / `parent` — the common case costs one atomic load.
//
// **Slot assignment** (DOM §4.2.2.4 "assign slottables for a tree") is computed
// per shadow root on demand and cached against the global selector epoch (bumped
// by every parent / attribute change), so it is recomputed after a mutation and
// read for free during a style or layout pass. Threading: readers may call these
// from the background style/layout pass; the cache is behind its own lock and the
// DOM reads are the node's per-call-safe getters.

/// The record of a shadow root (on the root node's state).
nonisolated public final class DOMShadowRootInfo: @unchecked Sendable {
    public weak var host: DOMNode?
    /// "open" or "closed".
    public let mode: String
    public let delegatesFocus: Bool
    /// "named" or "manual".
    public let slotAssignment: String
    public let clonable: Bool
    public let serializable: Bool
    /// Created by the HTML parser from `<template shadowrootmode>` (HTML §13.2.6.4.1).
    public var declarative: Bool

    /// Manual slot assignment (`slot.assign(...)`): slot identity -> nodes, in call order.
    let manual = Mutex<[ObjectIdentifier: [DOMNode]]>([:])
    /// The last computed assignment and the selector epoch it was computed at.
    let cache = Mutex<DOMSlotAssignment?>(nil)
    /// The assignment last reported through `slotchange` (the bridge's diff).
    var signaled: [ObjectIdentifier: [ObjectIdentifier]] = [:]

    init(host: DOMNode, mode: String, delegatesFocus: Bool, slotAssignment: String,
         clonable: Bool, serializable: Bool, declarative: Bool) {
        self.host = host
        self.mode = mode
        self.delegatesFocus = delegatesFocus
        self.slotAssignment = slotAssignment
        self.clonable = clonable
        self.serializable = serializable
        self.declarative = declarative
    }
}

/// One shadow tree's slot assignment.
nonisolated struct DOMSlotAssignment {
    let epoch: UInt64
    /// The tree's slots in tree order.
    let slots: [DOMNode]
    /// slot -> its assigned nodes (slottables), in the host's child order.
    let assigned: [ObjectIdentifier: [DOMNode]]
    /// slottable -> the slot it is assigned to.
    let slotOf: [ObjectIdentifier: DOMNode]
}

/// Set once any shadow root has been attached in this process: until then the
/// flat-tree accessors are the plain tree ones.
nonisolated(unsafe) private let domShadowRootsAttached = Atomic<Bool>(false)

extension DOMNode {

    /// True once a shadow root exists anywhere (the flat tree differs from the DOM tree).
    @inline(__always)
    public static var anyShadowRoots: Bool { domShadowRootsAttached.load(ordering: .acquiring) }

    // MARK: Shadow root / host

    /// The shadow root this host has attached (open or closed); nil otherwise.
    public var shadowRoot: DOMNode? { state.withLock { $0.shadowRoot } }

    /// The record of this node when it is a shadow root.
    public var shadowRootInfo: DOMShadowRootInfo? { state.withLock { $0.shadowInfo } }

    /// True when this node is a shadow root.
    public var isShadowRoot: Bool { state.withLock { $0.shadowInfo != nil } }

    /// The host of this shadow root (nil for any other node).
    public var shadowHost: DOMNode? { state.withLock { $0.shadowInfo?.host } }

    /// DOM §4.2.2 "valid shadow host names" (plus any valid custom element name).
    public static let shadowHostTags: Set<String> = [
        "article", "aside", "blockquote", "body", "div", "footer", "h1", "h2", "h3", "h4", "h5", "h6",
        "header", "main", "nav", "p", "section", "span",
    ]

    /// HTML §4.13.2 "valid custom element name" (the ASCII approximation WebKit
    /// uses for the PCENChar ranges: a lowercase ASCII letter first, a hyphen,
    /// no ASCII uppercase, not one of the reserved names).
    public static func isValidCustomElementName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first >= "a", first <= "z", name.contains("-") else { return false }
        for u in name.unicodeScalars where u >= "A" && u <= "Z" { return false }
        switch name {
        case "annotation-xml", "color-profile", "font-face", "font-face-src", "font-face-uri",
             "font-face-format", "font-face-name", "missing-glyph":
            return false
        default:
            return true
        }
    }

    /// DOM §4.2.2 "attach a shadow root". Returns nil for a host this cannot
    /// attach to (the caller throws `NotSupportedError`). A declarative root of
    /// the same mode is reused (its children removed), as the spec says.
    @discardableResult
    public func attachShadowRoot(mode: String, delegatesFocus: Bool = false, slotAssignment: String = "named",
                                 clonable: Bool = false, serializable: Bool = false,
                                 declarative: Bool = false) -> DOMNode? {
        guard nodeType == .element, isHTMLNamespace, let tag = tagName else { return nil }
        guard Self.shadowHostTags.contains(tag) || Self.isValidCustomElementName(tag) else { return nil }
        if let existing = shadowRoot {
            guard let info = existing.shadowRootInfo, info.declarative, info.mode == mode, !declarative else { return nil }
            for child in existing.detachChildrenArray() { child.parent = nil }
            info.declarative = false
            return existing
        }
        let root = DOMNode.documentFragment()
        let info = DOMShadowRootInfo(host: self, mode: mode, delegatesFocus: delegatesFocus,
                                     slotAssignment: slotAssignment == "manual" ? "manual" : "named",
                                     clonable: clonable, serializable: serializable, declarative: declarative)
        root.state.withLock { $0.shadowInfo = info }
        domShadowRootsAttached.store(true, ordering: .releasing)
        state.withLock { $0.shadowRoot = root }
        // The shadow-including parent (see the header): published last, with the epoch bump.
        root.parent = self
        return root
    }

    /// The shadow root this node's tree belongs to (nil in a document tree or a
    /// detached tree). Walks parents up to the first shadow root.
    public var containingShadowRoot: DOMNode? {
        guard DOMNode.anyShadowRoots else { return nil }
        var cur = parent
        while let c = cur {
            if c.isShadowRoot { return c }
            cur = c.parent
        }
        return nil
    }

    /// DOM §4.4 "get the root": the topmost node of this node's tree — a shadow
    /// root stops the walk unless `composed` (then the host's root, recursively).
    public func rootNode(composed: Bool) -> DOMNode {
        var top = self
        while true {
            if !composed, top.isShadowRoot { return top }
            guard let p = top.parent else { return top }
            top = p
        }
    }

    /// The DOM-tree parent: the shadow-including parent except that a shadow
    /// root has none (`parentNode` of a ShadowRoot is null).
    public var domParent: DOMNode? {
        if DOMNode.anyShadowRoots, isShadowRoot { return nil }
        return parent
    }

    // MARK: Slots

    /// True for an HTML `<slot>` element.
    @inline(__always)
    public var isSlotElement: Bool { nodeType == .element && tagName == "slot" && isHTMLNamespace }

    /// A slot's name (DOM: the `name` attribute, "" when absent).
    public var slotName: String { attributeValue("name") ?? "" }

    /// A slottable's name: an element's `slot` attribute, "" for text / no attribute.
    public var slottableName: String { nodeType == .element ? (attributeValue("slot") ?? "") : "" }

    /// Whether this node can be assigned to a slot (DOM: Element and Text).
    @inline(__always)
    public var isSlottable: Bool { nodeType == .element || nodeType == .text }

    /// The shadow tree's slot assignment, recomputed when the tree changed.
    func slotAssignment() -> DOMSlotAssignment? {
        guard let info = shadowRootInfo else { return nil }
        let epoch = DOMNode.selectorEpoch
        if let cached = info.cache.withLock({ $0 }), cached.epoch == epoch { return cached }
        let computed = computeSlotAssignment(info: info, epoch: epoch)
        info.cache.withLock { $0 = computed }
        return computed
    }

    /// DOM §4.2.2.4 "assign slottables for a tree" (and "find a slot" for each
    /// slottable): the first slot in tree order with the slottable's name wins
    /// (named), or the slot whose manually assigned nodes list it (manual).
    private func computeSlotAssignment(info: DOMShadowRootInfo, epoch: UInt64) -> DOMSlotAssignment {
        // The tree's slots in tree order (iterative: no stack per level).
        var slots: [DOMNode] = []
        var stack: [DOMNode] = children.reversed()
        while let n = stack.popLast() {
            if n.isSlotElement { slots.append(n) }
            let kids = n.children
            if !kids.isEmpty { stack.append(contentsOf: kids.reversed()) }
        }
        var assigned: [ObjectIdentifier: [DOMNode]] = [:]
        var slotOf: [ObjectIdentifier: DOMNode] = [:]
        guard let host = info.host, !slots.isEmpty else {
            return DOMSlotAssignment(epoch: epoch, slots: slots, assigned: [:], slotOf: [:])
        }
        let lightChildren = host.children
        if info.slotAssignment == "manual" {
            let manual = info.manual.withLock { $0 }
            let isChild = Set(lightChildren.map { ObjectIdentifier($0) })
            for slot in slots {
                guard let nodes = manual[ObjectIdentifier(slot)] else { continue }
                var list: [DOMNode] = []
                for n in nodes where isChild.contains(ObjectIdentifier(n)) && n.isSlottable
                    && slotOf[ObjectIdentifier(n)] == nil {
                    list.append(n)
                    slotOf[ObjectIdentifier(n)] = slot
                }
                if !list.isEmpty { assigned[ObjectIdentifier(slot)] = list }
            }
        } else {
            var firstByName: [String: DOMNode] = [:]
            for slot in slots where firstByName[slot.slotName] == nil { firstByName[slot.slotName] = slot }
            for child in lightChildren where child.isSlottable {
                guard let slot = firstByName[child.slottableName] else { continue }
                assigned[ObjectIdentifier(slot), default: []].append(child)
                slotOf[ObjectIdentifier(child)] = slot
            }
        }
        return DOMSlotAssignment(epoch: epoch, slots: slots, assigned: assigned, slotOf: slotOf)
    }

    /// A slot's assigned nodes (DOM "find slottables"); empty for a slot that
    /// is not in a shadow tree.
    public var assignedNodes: [DOMNode] {
        guard DOMNode.anyShadowRoots, isSlotElement, let root = containingShadowRoot,
              let a = root.slotAssignment() else { return [] }
        return a.assigned[ObjectIdentifier(self)] ?? []
    }

    /// DOM "find flattened slottables": the assigned nodes (the slot's own
    /// slottable children when none), each nested slot replaced by its own
    /// flattened slottables.
    public var flattenedAssignedNodes: [DOMNode] { flattenedAssignedNodesShallow(depth: 0) }

    private func flattenedAssignedNodesShallow(depth: Int) -> [DOMNode] {
        guard depth < 32 else { return [] }
        var list = assignedNodes
        if list.isEmpty { list = children.filter { $0.isSlottable } }
        var out: [DOMNode] = []
        for n in list {
            if n.isSlotElement, n.containingShadowRoot != nil {
                out.append(contentsOf: n.flattenedAssignedNodesShallow(depth: depth + 1))
            } else {
                out.append(n)
            }
        }
        return out
    }

    /// The slot this node is assigned to (DOM "find a slot"), any mode.
    public var assignedSlotNode: DOMNode? {
        guard DOMNode.anyShadowRoots, isSlottable, let p = parent, let root = p.shadowRoot,
              let a = root.slotAssignment() else { return nil }
        return a.slotOf[ObjectIdentifier(self)]
    }

    /// `slot.assign(...nodes)` (manual slot assignment).
    public func assignSlottables(_ nodes: [DOMNode]) {
        guard isSlotElement else { return }
        var seen = Set<ObjectIdentifier>()
        let unique = nodes.filter { seen.insert(ObjectIdentifier($0)).inserted }
        // A node is manually assigned to at most one slot: take it out of the others.
        if let root = containingShadowRoot, let info = root.shadowRootInfo {
            info.manual.withLock { m in
                for key in m.keys { m[key]?.removeAll { seen.contains(ObjectIdentifier($0)) } }
                m[ObjectIdentifier(self)] = unique
            }
        }
        DOMNode.bumpSelectorEpoch()
    }

    // MARK: Flat tree (CSS Scoping 1 §2.1)

    /// This node's children in the flat tree (see the header).
    public var flatTreeChildren: [DOMNode] {
        guard DOMNode.anyShadowRoots else { return children }
        if let root = shadowRoot { return root.children }
        if isSlotElement, let root = containingShadowRoot {
            if let a = root.slotAssignment(), let list = a.assigned[ObjectIdentifier(self)], !list.isEmpty {
                return list
            }
        }
        return children
    }

    /// This node's parent in the flat tree: the host for the top of a shadow
    /// tree, the slot for an assigned light child, nil for an unassigned light
    /// child of a host (it is not rendered).
    public var flatTreeParent: DOMNode? {
        guard DOMNode.anyShadowRoots else { return parent }
        guard let p = parent else { return nil }
        if let host = p.shadowHost { return host }
        if p.shadowRoot != nil { return assignedSlotNode }
        return p
    }

    /// True when this node is a light child of a shadow host that no slot takes:
    /// it has no box (CSS Scoping 1 §2.1).
    public var isUnslottedLightChild: Bool {
        guard DOMNode.anyShadowRoots, let p = parent, p.shadowRoot != nil else { return false }
        return assignedSlotNode == nil
    }
}
