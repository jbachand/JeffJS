import Foundation

// MARK: - One DOM bridge per realm (HTML §7.1: a nested browsing context's
// Window has its own document and wrappers) — iframe realms, 2026-09-30.
//
// A host that gives an `<iframe>` its own realm (JeffJSRuntime.newRealm) registers
// a second JeffJSDOMBridge on that realm with the nested document as its root.
// A node then has one wrapper, made by the bridge of the realm its node document
// belongs to (WebIDL §3.1 / HTML: platform objects live in their relevant realm):
// `iframe.contentDocument.body` read from the embedder is the nested realm's
// wrapper with the nested realm's prototypes, and the nested realm's
// `frameElement` is the embedder's wrapper of the `<iframe>`. Bridges join the
// routing table with `joinRealmRegistry()`; with fewer than two members nothing
// is routed (one realm per page costs nothing).

extension JeffJSDOMBridge {

    final class WeakBridge {
        weak var value: JeffJSDOMBridge?
        init(_ value: JeffJSDOMBridge) { self.value = value }
    }

    /// Bridges taking part in realm routing (main thread, like every DOM call).
    nonisolated(unsafe) static var realmBridges: [WeakBridge] = []

    /// Adds this bridge to the routing table (the host calls it for its main
    /// bridge before the first nested realm's bridge, then for each nested one).
    func joinRealmRegistry() {
        Self.realmBridges.removeAll { $0.value == nil || $0.value === self }
        Self.realmBridges.append(WeakBridge(self))
    }

    /// Leaves the routing table (teardown / navigation).
    func leaveRealmRegistry() {
        Self.realmBridges.removeAll { $0.value == nil || $0.value === self }
    }

    /// The JS value of this bridge's document object (the realm's `document`).
    var documentValue: JeffJSValue? { documentJSValue }

    /// The bridge of another realm that owns `node`: one that already wrapped it,
    /// else the one whose document the node's tree (or node document) is. Nil when
    /// the node is this bridge's (or no realm claims it).
    func realmOwner(of node: DOMNode) -> JeffJSDOMBridge? {
        let bridges = Self.realmBridges
        guard bridges.count > 1 else { return nil }
        for wb in bridges {
            guard let b = wb.value, b !== self else { continue }
            if b.elementCache[node.id] != nil { return b }
        }
        var top = node
        var steps = 0
        while let p = top.parent, steps < 100_000 { top = p; steps += 1 }
        let document: DOMNode? = top.nodeType == .document ? top : top.nodeDocument
        guard let document, document !== root else { return nil }
        for wb in bridges {
            guard let b = wb.value, b !== self else { continue }
            if b.root === document { return b }
        }
        return nil
    }
}

extension JeffJSDOMBridge {

    /// A navigation of a nested browsing context that keeps its Window (HTML
    /// §7.4.2.3.3 / §7.1.3: the initial `about:blank` document replaced by the
    /// first same-origin document reuses the Window): the realm's bridge now
    /// serves `newRoot`. The `document` object, the shared prototypes and every
    /// host patch on them stay; the wrappers and per-node caches of the old
    /// document are dropped (its nodes are no longer this realm's document's).
    func replaceRoot(_ newRoot: DOMNode) {
        guard newRoot !== root else { return }
        for (_, v) in elementCache { v.freeValue() }
        elementCache.removeAll()
        for (_, v) in classListCache { v.freeValue() }
        classListCache.removeAll()
        for (_, v) in relListCache { v.freeValue() }
        relListCache.removeAll()
        for (_, v) in datasetCache { v.freeValue() }
        datasetCache.removeAll()
        inlineStyleEntries.removeAll()
        nodeRegistry.removeAll()
        moRegistrations.removeAll()
        templateContent.removeAll()
        inertDocuments.removeAll()
        detachedCandidates.removeAll()
        detachedCandidateIDs.removeAll()
        dirtyTextareas.removeAll()
        currentScriptNode = nil
        focusedElement = nil
        parserOrder = []
        parserInsertedThrough = -1
        parserInsertionsStarted = false
        parserInsertionsDone = false
        root = newRoot
        Self.markScriptsAlreadyStarted(in: [newRoot], onlyIfWouldStart: true)
    }
}
