// JeffJSDOMBridge.swift
// JeffJS DOM Bridge — Registers browser-like DOM APIs on a JeffJS context.
//
// This bridges the DOMNode tree to JavaScript running in JeffJS, providing:
//   document.getElementById, createElement, querySelector, querySelectorAll,
//   createTextNode, element.getAttribute/setAttribute, appendChild, removeChild,
//   insertBefore, addEventListener, textContent, innerHTML, classList, style, etc.
//
// Follows the same DOMNode interaction patterns as JSScriptEngine.swift's
// JSDocumentBridge / JSElementBridge, but uses JeffJS's native function API
// instead of JavaScriptCore.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics  // CGRect/CGPoint/CGSize geometry helpers for the layout-rect store
#endif

// MARK: - Mutation Observer Typealias

/// Callback invoked when JS mutates the DOM tree. The set contains UUIDs of
/// every DOMNode that was changed, matching the JSC path's mutation observer.
typealias JeffJSDOMMutationObserver = @MainActor @Sendable (Set<UUID>) -> Void

// MARK: - JeffJSDOMBridge

/// Registers DOM APIs (document, element methods) on a JeffJS context so that
/// JavaScript can interact with the native DOMNode tree.
///
/// Usage:
/// ```swift
/// let bridge = JeffJSDOMBridge(root: document, baseURL: url, onMutated: { ids in ... })
/// bridge.register(on: ctx)
/// ```
@MainActor
final class JeffJSDOMBridge {

    // MARK: - State

    private(set) var root: DOMNode
    private let baseURL: URL
    private let onMutated: JeffJSDOMMutationObserver?
    private let onScriptExecution: ((DOMNode) -> Void)?

    /// Called when a JS event listener throws an exception.
    var onError: ((String) -> Void)?

    /// Cache of wrapped JS element objects keyed by DOMNode UUID.
    /// Ensures identity: the same DOMNode always maps to the same JS object.
    private var elementCache: [UUID: JeffJSValue] = [:]

    /// Registry of all DOMNodes that have been wrapped, keyed by UUID.
    /// Used by extractNode fallback when opaque payload is unavailable.
    private var nodeRegistry: [UUID: DOMNode] = [:]

    /// The JS `document` object, stored so wrapped elements can reference it
    /// as `ownerDocument` (required by React DOM's event delegation).
    private(set) var documentJSValue: JeffJSValue?

    /// Shared prototype for all CSSStyleDeclaration objects.
    /// Created lazily on first use; all per-element style objects inherit from this.
    /// Getter/setter definitions live here and use `this` to find the DOMNode.
    private var stylePrototype: JeffJSValue?

    /// Shared prototype for all DOM element objects. Methods and accessor properties
    /// live here so they're non-enumerable and shared across all elements — matching
    /// browser behavior where methods are on HTMLElement.prototype, not per-element.
    private var elementPrototype: JeffJSValue?

    /// Reference to the centralized event bridge. All addEventListener/removeEventListener/
    /// dispatchEvent calls on elements and document are routed through this bridge,
    /// which provides proper capture/at-target/bubble phase dispatch.
    weak var eventBridge: JeffJSEventBridge?

    // MARK: - Layout Geometry State

    /// Layout rects in **document** coordinates keyed by `DOMNode.id`, pushed by the
    /// host after every layout pass (same shape as the JSC path's `layoutRects`).
    public private(set) var layoutRects: [UUID: CGRect] = [:]

    /// Viewport size reported with the last layout pass. `.zero` until the host
    /// pushes one; used for `documentElement.clientWidth/clientHeight`.
    public private(set) var viewportSize: CGSize = .zero

    /// Root scroll position in document px. `getBoundingClientRect()` subtracts it
    /// to produce viewport coordinates; `window.scrollX/scrollY` and
    /// `documentElement.scrollTop/scrollLeft` read and write it.
    public var scrollOffset: CGPoint = .zero

    /// Per-element `scrollTop`/`scrollLeft` values assigned from JS.
    private var elementScrollPositions: [UUID: CGPoint] = [:]

    /// Cache of `scrollWidth`/`scrollHeight` per node (descendant union is O(n));
    /// cleared whenever any rect changes.
    private var scrollSizeCache: [UUID: CGSize] = [:]

    /// Node IDs for which JS called `scrollIntoView()` since the host last drained.
    public private(set) var scrollIntoViewRequests: [UUID] = []

    /// Optional hook fired when JS scrolls an element (`scrollTop`/`scrollLeft`
    /// setters, `scrollTo`/`scrollBy`) or the window. `nil` node means the root.
    /// The regular mutation callback (`onMutated`) is also fired for element scrolls.
    public var onScrollChange: ((DOMNode?, CGPoint) -> Void)?

    /// Shared prototype for DOMRect objects returned by getBoundingClientRect().
    private var domRectPrototype: JeffJSValue?

    /// Per-node `classList` wrappers, keyed by `DOMNode.id`. Built lazily by the
    /// prototype's `classList` accessor so every element gets its *own* list
    /// (the previous eager materialisation bound a single empty object to the
    /// shared prototype, leaving `el.classList.add` undefined).
    private var classListCache: [UUID: JeffJSValue] = [:]

    /// Per-node `relList` wrappers, keyed by `DOMNode.id`. Same lifetime rules
    /// as `classListCache`.
    private var relListCache: [UUID: JeffJSValue] = [:]

    /// Detached documents handed out by `document.implementation.createHTMLDocument`
    /// and `DOMParser.parseFromString`, keyed by their root `DOMNode.id`.
    /// Non-empty only on pages that ask for one, so the `ownerDocument` walk in
    /// `wrapElement` stays free for everything else.
    private var detachedDocuments: [UUID: JeffJSValue] = [:]
    private var detachedDocumentRoots: [DOMNode] = []

    /// `<template>` content fragments, keyed by the template element's id.
    private var templateContent: [UUID: DOMNode] = [:]

    /// The `<script>` element currently being evaluated (`document.currentScript`).
    private var currentScriptNode: DOMNode?

    /// Shared `item`/`namedItem` implementations spliced onto every array
    /// returned by `wrapElementArray` (HTMLCollection/NodeList shape).
    private var nodeListItemFn: JeffJSValue?
    private var nodeListNamedItemFn: JeffJSValue?

    // MARK: - Init

    init(
        root: DOMNode,
        baseURL: URL,
        onMutated: JeffJSDOMMutationObserver?,
        onScriptExecution: ((DOMNode) -> Void)? = nil
    ) {
        self.root = root
        self.baseURL = baseURL
        self.onMutated = onMutated
        self.onScriptExecution = onScriptExecution
    }

    // MARK: - Lifecycle

    /// Clears all caches, freeing all duped JeffJSValues.
    /// Call on page navigation or teardown to prevent unbounded memory growth.
    /// Event listener cleanup is handled by JeffJSEventBridge.teardown().
    func resetBridge() {
        // Free all duped element wrapper values in the cache
        for (_, cachedVal) in elementCache {
            cachedVal.freeValue()
        }
        elementCache.removeAll()

        // Free shared style prototype
        stylePrototype?.freeValue()
        stylePrototype = nil

        elementPrototype?.freeValue()
        elementPrototype = nil

        domRectPrototype?.freeValue()
        domRectPrototype = nil

        for (_, v) in classListCache { v.freeValue() }
        classListCache.removeAll()
        for (_, v) in relListCache { v.freeValue() }
        relListCache.removeAll()
        for (_, v) in detachedDocuments { v.freeValue() }
        detachedDocuments.removeAll()
        detachedDocumentRoots.removeAll()
        templateContent.removeAll()
        currentScriptNode = nil
        nodeListItemFn?.freeValue(); nodeListItemFn = nil
        nodeListNamedItemFn?.freeValue(); nodeListNamedItemFn = nil

        nodeRegistry.removeAll()
        layoutRects.removeAll()
        elementScrollPositions.removeAll()
        scrollSizeCache.removeAll()
        scrollIntoViewRequests.removeAll()
        scrollOffset = .zero
    }

    // MARK: - Layout Geometry (host -> bridge)

    /// Replaces the layout-rect store with the result of a full layout pass.
    /// Rects are in document coordinates, keyed by `DOMNode.id`.
    public func updateLayoutRects(_ rects: [UUID: CGRect], viewport: CGSize) {
        layoutRects = rects
        viewportSize = viewport
        scrollSizeCache.removeAll()
    }

    /// Updates a single node's rect (incremental layout) without touching the others.
    public func setLayoutRect(_ rect: CGRect, for nodeID: UUID) {
        layoutRects[nodeID] = rect
        scrollSizeCache.removeAll()
    }

    /// The document-coordinate rect for a node, if the host has laid it out.
    public func layoutRect(for nodeID: UUID) -> CGRect? {
        layoutRects[nodeID]
    }

    /// Returns and clears the `scrollIntoView()` requests recorded since the last call.
    @discardableResult
    public func drainScrollIntoViewRequests() -> [UUID] {
        let pending = scrollIntoViewRequests
        scrollIntoViewRequests.removeAll()
        return pending
    }

    /// Clears event listeners, element cache, and node registry for a node
    /// and all its descendants when it is removed from the DOM.
    func clearNodeAndDescendants(_ node: DOMNode) {
        clearEventListeners(for: node.id)
        for child in node.children {
            clearNodeAndDescendants(child)
        }
    }

    /// Clears event listeners and cache for a specific node when it is removed from the DOM.
    func clearEventListeners(for nodeID: UUID) {
        // Tell centralized event bridge to free listeners for this node
        eventBridge?.removeAllListeners(forNodeID: nodeID)

        // Free cached wrapper
        if let cachedVal = elementCache[nodeID] {
            cachedVal.freeValue()
        }
        elementCache.removeValue(forKey: nodeID)
        nodeRegistry.removeValue(forKey: nodeID)
        elementScrollPositions.removeValue(forKey: nodeID)
        if let cachedList = classListCache.removeValue(forKey: nodeID) {
            cachedList.freeValue()
        }
        if let cachedList = relListCache.removeValue(forKey: nodeID) {
            cachedList.freeValue()
        }
        templateContent.removeValue(forKey: nodeID)
    }

    // MARK: - document.currentScript

    /// Records the `<script>` element being evaluated so `document.currentScript`
    /// reports it (AdSense and most tag loaders read it to find their own tag).
    /// Pass `nil` when evaluation finishes.
    func setCurrentScriptNode(_ node: DOMNode?) {
        currentScriptNode = node
    }

    // MARK: - Registration Entry Point

    /// Registers `document` and `window` objects on the JeffJS context's global scope.
    func register(on ctx: JeffJSContext) {
        let global = ctx.getGlobalObject()

        // -- window alias --
        ctx.setPropertyStr(obj: global, name: "window", value: global.dupValue())

        // -- window.scrollX/scrollY/pageXOffset/pageYOffset --
        // Accessors over `scrollOffset`, installed before any polyfill runs so a
        // host polyfill's `if (typeof window.scrollY === 'undefined') window.scrollY = 0`
        // guard skips them and its scrollTo/scrollBy assignments land in the setter.
        registerWindowScrollAccessors(on: global, ctx: ctx)

        // -- document object --
        let docObj = buildDocumentObject(ctx: ctx)
        self.documentJSValue = docObj.dupValue()
        ctx.setPropertyStr(obj: global, name: "document", value: docObj)

        // -- Constructor stubs (Window, Document, HTMLDocument, Node, Element, etc.) --
        // Browsers expose these as global constructor functions. Frameworks like React
        // check `typeof Document !== 'undefined'` to detect a DOM environment.
        let constructorResult = ctx.eval(input: """
        (function() {
          function S(name, proto) {
            if (typeof window[name] !== 'undefined') return;
            var F = function() {};
            Object.defineProperty(F, 'name', { value: name, configurable: true });
            if (proto) { for (var k in proto) { if (proto.hasOwnProperty(k)) F.prototype[k] = proto[k]; } }
            window[name] = F;
          }
          S('Window');
          S('Document');
          S('HTMLDocument');
          S('Node', { ELEMENT_NODE: 1, TEXT_NODE: 3, COMMENT_NODE: 8, DOCUMENT_NODE: 9, DOCUMENT_FRAGMENT_NODE: 11 });
          S('Element');
          S('HTMLElement');
          S('Text');
          S('Comment');
          S('DocumentFragment');
          S('Event');
          S('CustomEvent');
          S('EventTarget', { addEventListener: function(){}, removeEventListener: function(){}, dispatchEvent: function(){ return true; } });
          S('NodeList', { length: 0, item: function() { return null; } });
          S('HTMLCollection', { length: 0, item: function() { return null; }, namedItem: function() { return null; } });
        })()
        """, filename: "<dom-constructors>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        constructorResult.freeValue()

        // Native HTML -> detached Document, consumed by the host's DOMParser
        // polyfill (`DOMParser.parseFromString(str, "text/html")`).
        ctx.setPropertyFunc(obj: global, name: "__nativeParseHTMLDocument", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.null }
            let html = ctx.toSwiftString(args.first ?? .undefined) ?? ""
            return self.parseDetachedDocument(html: html, ctx: ctx)
        }, length: 1)

        global.freeValue()
    }

    // MARK: - Document Object

    private func buildDocumentObject(ctx: JeffJSContext) -> JeffJSValue {
        let doc = ctx.newObject()

        // -- nodeType = 9 (DOCUMENT_NODE) --
        ctx.setPropertyStr(obj: doc, name: "nodeType", value: .newInt32(9))
        ctx.setPropertyStr(obj: doc, name: "nodeName", value: ctx.newStringValue("#document"))

        // -- URL properties --
        let urlString = baseURL.absoluteString
        ctx.setPropertyStr(obj: doc, name: "URL", value: ctx.newStringValue(urlString))
        ctx.setPropertyStr(obj: doc, name: "documentURI", value: ctx.newStringValue(urlString))
        ctx.setPropertyStr(obj: doc, name: "baseURI", value: ctx.newStringValue(urlString))
        ctx.setPropertyStr(obj: doc, name: "domain", value: ctx.newStringValue(baseURL.host ?? ""))
        ctx.setPropertyStr(obj: doc, name: "referrer", value: ctx.newStringValue(""))
        ctx.setPropertyStr(obj: doc, name: "characterSet", value: ctx.newStringValue("UTF-8"))
        ctx.setPropertyStr(obj: doc, name: "charset", value: ctx.newStringValue("UTF-8"))
        ctx.setPropertyStr(obj: doc, name: "contentType", value: ctx.newStringValue("text/html"))
        ctx.setPropertyStr(obj: doc, name: "visibilityState", value: ctx.newStringValue("visible"))
        ctx.setPropertyStr(obj: doc, name: "hidden", value: .newBool(false))
        ctx.setPropertyStr(obj: doc, name: "readyState", value: ctx.newStringValue("loading"))
        ctx.setPropertyStr(obj: doc, name: "title", value: ctx.newStringValue(extractTitle()))

        // documentMode — React-DOM checks `document.documentMode` to detect IE.
        // Setting to undefined (rather than leaving absent) ensures
        // `'documentMode' in document` returns true, matching browser behavior.
        ctx.setPropertyStr(obj: doc, name: "documentMode", value: .undefined)

        // -- Methods --
        registerDocumentMethods(on: doc, ctx: ctx)

        // -- Element-returning property getters via methods --
        // Since JeffJS doesn't support Object.defineProperty with native
        // getter closures easily, we use __get_* methods and a small JS shim.
        registerDocumentPropertyGetters(on: doc, ctx: ctx)

        return doc
    }

    // MARK: - Document Methods

    private func registerDocumentMethods(on doc: JeffJSValue, ctx: JeffJSContext) {
        // getElementById
        ctx.setPropertyFunc(obj: doc, name: "getElementById", fn: { [weak self] ctx, thisVal, args in
            guard let self, let idStr = self.extractString(ctx: ctx, args: args, index: 0) else {
                return JeffJSValue.null
            }
            guard let node = self.findElement(in: self.root, where: { $0.idAttribute == idStr }) else {
                return JeffJSValue.null
            }
            return self.wrapElement(node, ctx: ctx)
        }, length: 1)

        // querySelector
        ctx.setPropertyFunc(obj: doc, name: "querySelector", fn: { [weak self] ctx, thisVal, args in
            guard let self, let selector = self.extractString(ctx: ctx, args: args, index: 0) else {
                return JeffJSValue.null
            }
            guard let node = self.root.querySelector(selector) else {
                return JeffJSValue.null
            }
            return self.wrapElement(node, ctx: ctx)
        }, length: 1)

        // querySelectorAll
        ctx.setPropertyFunc(obj: doc, name: "querySelectorAll", fn: { [weak self] ctx, thisVal, args in
            guard let self, let selector = self.extractString(ctx: ctx, args: args, index: 0) else {
                return self?.wrapElementArray([], ctx: ctx) ?? JeffJSValue.null
            }
            let nodes = self.root.querySelectorAll(selector)
            return self.wrapElementArray(nodes, ctx: ctx)
        }, length: 1)

        // getElementsByClassName
        ctx.setPropertyFunc(obj: doc, name: "getElementsByClassName", fn: { [weak self] ctx, thisVal, args in
            guard let self, let className = self.extractString(ctx: ctx, args: args, index: 0) else {
                return self?.wrapElementArray([], ctx: ctx) ?? JeffJSValue.null
            }
            let classes = DOMNode.splitASCIIWhitespace(className)
            guard !classes.isEmpty else { return self.wrapElementArray([], ctx: ctx) }
            let nodes = self.allElementDescendants(of: self.root).filter { node in
                let nodeClasses = node.classList
                return classes.allSatisfy { nodeClasses.contains($0) }
            }
            return self.wrapElementArray(nodes, ctx: ctx)
        }, length: 1)

        // getElementsByTagName
        ctx.setPropertyFunc(obj: doc, name: "getElementsByTagName", fn: { [weak self] ctx, thisVal, args in
            guard let self, let tagName = self.extractString(ctx: ctx, args: args, index: 0) else {
                return self?.wrapElementArray([], ctx: ctx) ?? JeffJSValue.null
            }
            let normalized = tagName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { return self.wrapElementArray([], ctx: ctx) }
            let nodes = self.allElementDescendants(of: self.root).filter {
                normalized == "*" || $0.tagName == normalized
            }
            return self.wrapElementArray(nodes, ctx: ctx)
        }, length: 1)

        // createElement
        ctx.setPropertyFunc(obj: doc, name: "createElement", fn: { [weak self] ctx, thisVal, args in
            guard let self, let tag = self.extractString(ctx: ctx, args: args, index: 0) else {
                return JeffJSValue.null
            }
            let node = DOMNode.element(tag: tag)
            return self.wrapElement(node, ctx: ctx)
        }, length: 1)

        // createElementNS(namespace, tag, options?) — used by Preact and modern frameworks.
        // Namespace is accepted but ignored (all elements treated as HTML).
        ctx.setPropertyFunc(obj: doc, name: "createElementNS", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.null }
            // args[0] = namespace URI (ignored), args[1] = tag name
            let tag = self.extractString(ctx: ctx, args: args, index: 1)
                ?? self.extractString(ctx: ctx, args: args, index: 0)
            guard let tag else { return JeffJSValue.null }
            let node = DOMNode.element(tag: tag)
            return self.wrapElement(node, ctx: ctx)
        }, length: 2)

        // createTextNode
        ctx.setPropertyFunc(obj: doc, name: "createTextNode", fn: { [weak self] ctx, thisVal, args in
            guard let self, let text = self.extractString(ctx: ctx, args: args, index: 0) else {
                return JeffJSValue.null
            }
            let node = DOMNode.text(text)
            return self.wrapElement(node, ctx: ctx)
        }, length: 1)

        // createDocumentFragment
        ctx.setPropertyFunc(obj: doc, name: "createDocumentFragment", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.null }
            let node = DOMNode.documentFragment()
            return self.wrapElement(node, ctx: ctx)
        }, length: 0)

        // createComment
        ctx.setPropertyFunc(obj: doc, name: "createComment", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.null }
            let text = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            let node = DOMNode.comment(text)
            return self.wrapElement(node, ctx: ctx)
        }, length: 1)

        // addEventListener(type, handler, options?) on document — routes through centralized event bridge
        ctx.setPropertyFunc(obj: doc, name: "addEventListener", fn: { [weak self] ctx, thisVal, args in
            guard let self, args.count >= 2 else { return JeffJSValue.undefined }
            let options = args.count >= 3 ? args[2] : JeffJSValue.undefined
            self.eventBridge?.addEventListener(ctx: ctx, target: thisVal, type: args[0], listener: args[1], options: options)
            return JeffJSValue.undefined
        }, length: 2)

        // removeEventListener(type, handler) on document — routes through centralized event bridge
        ctx.setPropertyFunc(obj: doc, name: "removeEventListener", fn: { [weak self] ctx, thisVal, args in
            guard let self, args.count >= 2 else { return JeffJSValue.undefined }
            let options = args.count >= 3 ? args[2] : JeffJSValue.undefined
            self.eventBridge?.removeEventListener(ctx: ctx, target: thisVal, type: args[0], listener: args[1], options: options)
            return JeffJSValue.undefined
        }, length: 2)

        // contains(node) -> bool (jQuery.contains and focus-trap libraries call it)
        ctx.setPropertyFunc(obj: doc, name: "contains", fn: { [weak self] ctx, _, args in
            guard let self, !args.isEmpty, let other = self.extractNode(from: args[0]) else {
                return .newBool(false)
            }
            return .newBool(self.nodeContains(self.root, child: other) || other === self.root)
        }, length: 1)

        // importNode(node, deep) / adoptNode(node)
        ctx.setPropertyFunc(obj: doc, name: "importNode", fn: { [weak self] ctx, _, args in
            guard let self, !args.isEmpty, let node = self.extractNode(from: args[0]) else {
                return JeffJSValue.null
            }
            let deep = args.count > 1 && args[1].toBool()
            return self.wrapElement(self.cloneDOMNode(node, deep: deep), ctx: ctx)
        }, length: 2)

        ctx.setPropertyFunc(obj: doc, name: "adoptNode", fn: { [weak self] ctx, _, args in
            guard let self, !args.isEmpty, let node = self.extractNode(from: args[0]) else {
                return JeffJSValue.null
            }
            node.parent?.removeChild(node)
            return self.wrapElement(node, ctx: ctx)
        }, length: 1)

        // document.implementation — createHTMLDocument backs jQuery.parseHTML.
        ctx.setPropertyStr(obj: doc, name: "implementation", value: buildDOMImplementation(ctx: ctx))

        // Live-ish collections: document.scripts / forms / images / links / embeds
        let collections: [(String, (DOMNode) -> Bool)] = [
            ("scripts", { $0.tagName == "script" }),
            ("forms", { $0.tagName == "form" }),
            ("images", { $0.tagName == "img" }),
            ("embeds", { $0.tagName == "embed" }),
            ("links", { ($0.tagName == "a" || $0.tagName == "area") && $0.attributes["href"] != nil }),
        ]
        for (name, predicate) in collections {
            let getter = ctx.newCFunction({ [weak self] ctx, _, _ in
                guard let self else { return ctx.newArray() }
                return self.wrapElementArray(self.allElementDescendants(of: self.root).filter(predicate), ctx: ctx)
            }, name: "get \(name)", length: 0)
            ctx.setPropertyGetSet(obj: doc, name: name, getter: getter, setter: nil)
        }

        // document.currentScript — the <script> the host is evaluating right now.
        let currentScriptGetter = ctx.newCFunction({ [weak self] ctx, _, _ in
            guard let self, let node = self.currentScriptNode else { return JeffJSValue.null }
            return self.wrapElement(node, ctx: ctx)
        }, name: "get currentScript", length: 0)
        ctx.setPropertyGetSet(obj: doc, name: "currentScript", getter: currentScriptGetter, setter: nil)

        // The host pushes the executing <script> by node id. Going through JS
        // (rather than a Swift entry point) keeps the host compiling against any
        // engine revision: it feature-tests the function before calling it.
        ctx.setPropertyFunc(obj: doc, name: "__setCurrentScriptByID", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            let raw = args.first.flatMap { ctx.toSwiftString($0) } ?? ""
            guard let uuid = UUID(uuidString: raw) else {
                self.currentScriptNode = nil
                return JeffJSValue.undefined
            }
            self.currentScriptNode = self.nodeRegistry[uuid]
                ?? self.findElement(in: self.root, where: { $0.id == uuid })
            return JeffJSValue.undefined
        }, length: 1)
    }

    // MARK: - document.implementation / detached documents

    /// Builds the `document.implementation` object. `createHTMLDocument` returns a
    /// real detached `Document` (jQuery 3's `parseHTML` needs `.body`, `.head`
    /// and `createElement` on it, and sets `base.href` on the created document).
    private func buildDOMImplementation(ctx: JeffJSContext) -> JeffJSValue {
        let impl = ctx.newObject()

        ctx.setPropertyFunc(obj: impl, name: "hasFeature", fn: { _, _, _ in .newBool(true) }, length: 2)

        ctx.setPropertyFunc(obj: impl, name: "createHTMLDocument", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.null }
            let title = args.isEmpty ? "" : (ctx.toSwiftString(args[0]) ?? "")
            return self.wrapDetachedDocument(self.makeDetachedDocument(title: title), ctx: ctx)
        }, length: 1)

        // createDocument(namespace, qualifiedName, doctype) — XML flavour; the
        // qualified name becomes the document element when supplied.
        ctx.setPropertyFunc(obj: impl, name: "createDocument", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.null }
            let docNode = DOMNode.document()
            let rootName = args.count > 1 ? (ctx.toSwiftString(args[1]) ?? "") : ""
            if !rootName.isEmpty {
                docNode.appendChild(DOMNode.element(tag: rootName))
            }
            return self.wrapDetachedDocument(docNode, ctx: ctx)
        }, length: 3)

        ctx.setPropertyFunc(obj: impl, name: "createDocumentType", fn: { ctx, _, args in
            let obj = ctx.newObject()
            ctx.setPropertyStr(obj: obj, name: "name", value: ctx.newStringValue(args.count > 0 ? (ctx.toSwiftString(args[0]) ?? "") : ""))
            ctx.setPropertyStr(obj: obj, name: "publicId", value: ctx.newStringValue(args.count > 1 ? (ctx.toSwiftString(args[1]) ?? "") : ""))
            ctx.setPropertyStr(obj: obj, name: "systemId", value: ctx.newStringValue(args.count > 2 ? (ctx.toSwiftString(args[2]) ?? "") : ""))
            ctx.setPropertyStr(obj: obj, name: "nodeType", value: .newInt32(10))
            return obj
        }, length: 3)

        return impl
    }

    /// `html > head > title + body` skeleton for a detached document.
    private func makeDetachedDocument(title: String) -> DOMNode {
        let docNode = DOMNode.document()
        let html = DOMNode.element(tag: "html")
        let head = DOMNode.element(tag: "head")
        let titleNode = DOMNode.element(tag: "title")
        titleNode.appendChild(DOMNode.text(title))
        head.appendChild(titleNode)
        html.appendChild(head)
        html.appendChild(DOMNode.element(tag: "body"))
        docNode.appendChild(html)
        return docNode
    }

    /// Parses `html` into a detached `Document`, for `DOMParser.parseFromString`.
    func parseDetachedDocument(html: String, ctx: JeffJSContext) -> JeffJSValue {
        let parsed = HTMLParser.parse(html)
        // Guarantee html/head/body exist so `.body` is never null.
        let docNode: DOMNode
        if parsed.querySelector("body") != nil, parsed.querySelector("html") != nil {
            docNode = parsed
        } else {
            docNode = makeDetachedDocument(title: "")
            if let body = docNode.querySelector("body") {
                for child in parsed.children { body.appendChild(child) }
            }
        }
        return wrapDetachedDocument(docNode, ctx: ctx)
    }

    /// Wraps a detached document root as a Document-shaped JS object: the element
    /// wrapper already supplies querySelector/getElementsByTagName/appendChild
    /// scoped to this subtree, so only the Document-only surface is added here.
    private func wrapDetachedDocument(_ docNode: DOMNode, ctx: JeffJSContext) -> JeffJSValue {
        if let cached = detachedDocuments[docNode.id] { return cached.dupValue() }

        detachedDocumentRoots.append(docNode)
        let wrapper = wrapElement(docNode, ctx: ctx)
        detachedDocuments[docNode.id] = wrapper.dupValue()

        // Document.ownerDocument is null; defaultView is null for a document that
        // has no browsing context.
        ctx.setPropertyStr(obj: wrapper, name: "ownerDocument", value: .null)
        ctx.setPropertyStr(obj: wrapper, name: "defaultView", value: .null)
        ctx.setPropertyStr(obj: wrapper, name: "compatMode", value: ctx.newStringValue("CSS1Compat"))
        ctx.setPropertyStr(obj: wrapper, name: "characterSet", value: ctx.newStringValue("UTF-8"))
        ctx.setPropertyStr(obj: wrapper, name: "contentType", value: ctx.newStringValue("text/html"))
        ctx.setPropertyStr(obj: wrapper, name: "readyState", value: ctx.newStringValue("complete"))
        ctx.setPropertyStr(obj: wrapper, name: "URL", value: ctx.newStringValue(baseURL.absoluteString))
        ctx.setPropertyStr(obj: wrapper, name: "baseURI", value: ctx.newStringValue(baseURL.absoluteString))
        ctx.setPropertyStr(obj: wrapper, name: "implementation", value: buildDOMImplementation(ctx: ctx))

        func tag(_ name: String) -> DOMNode? { docNode.querySelector(name) }

        let accessors: [(String, () -> DOMNode?)] = [
            ("documentElement", { tag("html") ?? docNode.children.first(where: { $0.nodeType == .element }) }),
            ("head", { tag("head") }),
            ("body", { tag("body") }),
            ("scrollingElement", { tag("html") }),
            ("activeElement", { tag("body") }),
        ]
        for (name, resolve) in accessors {
            let getter = ctx.newCFunction({ [weak self] ctx, _, _ in
                guard let self, let node = resolve() else { return JeffJSValue.null }
                return self.wrapElement(node, ctx: ctx)
            }, name: "get \(name)", length: 0)
            ctx.setPropertyGetSet(obj: wrapper, name: name, getter: getter, setter: nil)
        }

        let titleGetter = ctx.newCFunction({ ctx, _, _ in
            ctx.newStringValue(tag("title")?.rawTextDescendants ?? "")
        }, name: "get title", length: 0)
        let titleSetter = ctx.newCFunction({ ctx, _, args in
            let value = ctx.toSwiftString(args.first ?? .undefined) ?? ""
            if let existing = tag("title") {
                existing.setTextContent(value)
            } else if let head = tag("head") {
                let node = DOMNode.element(tag: "title")
                node.appendChild(DOMNode.text(value))
                head.appendChild(node)
            }
            return .undefined
        }, name: "set title", length: 1)
        ctx.setPropertyGetSet(obj: wrapper, name: "title", getter: titleGetter, setter: titleSetter)

        // Factory methods create nodes owned by *this* document. `adopt` captures
        // self weakly so the closures parked on the wrapper never retain the bridge.
        let docID = docNode.id
        let adopt: (DOMNode, JeffJSContext) -> JeffJSValue = { [weak self] node, ctx in
            guard let self else { return JeffJSValue.null }
            let value = self.wrapElement(node, ctx: ctx)
            if let owner = self.detachedDocuments[docID] {
                ctx.setPropertyStr(obj: value, name: "ownerDocument", value: owner.dupValue())
            }
            return value
        }

        ctx.setPropertyFunc(obj: wrapper, name: "createElement", fn: { ctx, _, args in
            guard let tagName = ctx.toSwiftString(args.first ?? .undefined) else { return JeffJSValue.null }
            return adopt(DOMNode.element(tag: tagName), ctx)
        }, length: 1)

        ctx.setPropertyFunc(obj: wrapper, name: "createElementNS", fn: { ctx, _, args in
            let tagName = (args.count > 1 ? ctx.toSwiftString(args[1]) : nil)
                ?? ctx.toSwiftString(args.first ?? .undefined) ?? "div"
            return adopt(DOMNode.element(tag: tagName), ctx)
        }, length: 2)

        ctx.setPropertyFunc(obj: wrapper, name: "createTextNode", fn: { ctx, _, args in
            adopt(DOMNode.text(ctx.toSwiftString(args.first ?? .undefined) ?? ""), ctx)
        }, length: 1)

        ctx.setPropertyFunc(obj: wrapper, name: "createComment", fn: { ctx, _, args in
            adopt(DOMNode.comment(ctx.toSwiftString(args.first ?? .undefined) ?? ""), ctx)
        }, length: 1)

        ctx.setPropertyFunc(obj: wrapper, name: "createDocumentFragment", fn: { ctx, _, _ in
            adopt(DOMNode.documentFragment(), ctx)
        }, length: 0)

        ctx.setPropertyFunc(obj: wrapper, name: "getElementById", fn: { [weak self] ctx, _, args in
            guard let self, let idStr = ctx.toSwiftString(args.first ?? .undefined),
                  let node = self.findElement(in: docNode, where: { $0.idAttribute == idStr }) else {
                return JeffJSValue.null
            }
            return self.wrapElement(node, ctx: ctx)
        }, length: 1)

        ctx.setPropertyFunc(obj: wrapper, name: "importNode", fn: { [weak self] ctx, _, args in
            guard let self, !args.isEmpty, let node = self.extractNode(from: args[0]) else { return JeffJSValue.null }
            let deep = args.count > 1 && args[1].toBool()
            return adopt(self.cloneDOMNode(node, deep: deep), ctx)
        }, length: 2)

        ctx.setPropertyFunc(obj: wrapper, name: "adoptNode", fn: { [weak self] ctx, _, args in
            guard let self, !args.isEmpty, let node = self.extractNode(from: args[0]) else { return JeffJSValue.null }
            node.parent?.removeChild(node)
            return adopt(node, ctx)
        }, length: 1)

        ctx.setPropertyFunc(obj: wrapper, name: "contains", fn: { [weak self] _, _, args in
            guard let self, !args.isEmpty, let other = self.extractNode(from: args[0]) else { return .newBool(false) }
            return .newBool(other === docNode || self.nodeContains(docNode, child: other))
        }, length: 1)

        return wrapper
    }

    // MARK: - Document Property Getters

    private func registerDocumentPropertyGetters(on doc: JeffJSValue, ctx: JeffJSContext) {
        // body
        ctx.setPropertyFunc(obj: doc, name: "__get_body", fn: { [weak self] ctx, _, _ in
            guard let self else { return JeffJSValue.null }
            guard let body = self.findElement(in: self.root, where: { $0.tagName == "body" }) else {
                return JeffJSValue.null
            }
            return self.wrapElement(body, ctx: ctx)
        }, length: 0)

        // head
        ctx.setPropertyFunc(obj: doc, name: "__get_head", fn: { [weak self] ctx, _, _ in
            guard let self else { return JeffJSValue.null }
            guard let head = self.findElement(in: self.root, where: { $0.tagName == "head" }) else {
                return JeffJSValue.null
            }
            return self.wrapElement(head, ctx: ctx)
        }, length: 0)

        // documentElement (<html>)
        ctx.setPropertyFunc(obj: doc, name: "__get_documentElement", fn: { [weak self] ctx, _, _ in
            guard let self else { return JeffJSValue.null }
            guard let html = self.findElement(in: self.root, where: { $0.tagName == "html" }) else {
                return JeffJSValue.null
            }
            return self.wrapElement(html, ctx: ctx)
        }, length: 0)

        // scrollingElement (standards mode: <html>)
        ctx.setPropertyFunc(obj: doc, name: "__get_scrollingElement", fn: { [weak self] ctx, _, _ in
            guard let self else { return JeffJSValue.null }
            guard let html = self.findElement(in: self.root, where: { $0.tagName == "html" }) else {
                return JeffJSValue.null
            }
            return self.wrapElement(html, ctx: ctx)
        }, length: 0)

        // Install getter properties via a small eval shim.
        // Uses literal property names (no forEach+closure) to avoid JeffJS var_ref issues.
        let shim = """
        (function(d) {
            if (typeof d.__get_scrollingElement === 'function') {
                Object.defineProperty(d, 'scrollingElement', {
                    configurable: true, enumerable: true,
                    get: function() { return this.__get_scrollingElement(); }
                });
            }
            if (typeof d.__get_body === 'function') {
                Object.defineProperty(d, 'body', {
                    configurable: true, enumerable: true,
                    get: function() { return this.__get_body(); }
                });
            }
            if (typeof d.__get_head === 'function') {
                Object.defineProperty(d, 'head', {
                    configurable: true, enumerable: true,
                    get: function() { return this.__get_head(); }
                });
            }
            if (typeof d.__get_documentElement === 'function') {
                Object.defineProperty(d, 'documentElement', {
                    configurable: true, enumerable: true,
                    get: function() { return this.__get_documentElement(); }
                });
            }
            // Fallback for engines where defineProperty getter behavior is incomplete
            // during early bootstrap: eagerly materialize missing/null values.
            if ((typeof d.documentElement === 'undefined' || d.documentElement == null) &&
                typeof d.__get_documentElement === 'function') {
                d.documentElement = d.__get_documentElement();
            }
            if ((typeof d.head === 'undefined' || d.head == null) &&
                typeof d.__get_head === 'function') {
                d.head = d.__get_head();
            }
            if ((typeof d.body === 'undefined' || d.body == null) &&
                typeof d.__get_body === 'function') {
                d.body = d.__get_body();
            }
        })
        """
        let shimFn = ctx.eval(input: shim, filename: "<dom-bridge-shim>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        if !shimFn.isException && shimFn.isFunction {
            _ = ctx.call(shimFn, this: .undefined, args: [doc])
        }
    }

    // MARK: - Element Wrapping

    /// Wraps a DOMNode as a JeffJS object with all element methods and properties.
    /// Returns a cached wrapper if one already exists for this node.
    func wrapElement(_ node: DOMNode, ctx: JeffJSContext) -> JeffJSValue {
        if let cached = elementCache[node.id] {
            return cached.dupValue()
        }

        // Lazily build the shared element prototype (methods + accessors)
        if elementPrototype == nil {
            elementPrototype = buildElementPrototype(ctx: ctx)
        }

        // Create element instance with shared prototype — methods are inherited
        // (non-enumerable), matching browser behavior.
        let el = ctx.newObjectProto(proto: elementPrototype!)

        // Store the DOMNode reference in the object's opaque payload
        if let obj = el.toObject() {
            obj.payload = .opaque(node)
        }

        // -- Per-instance read-only properties --
        ctx.setPropertyStr(obj: el, name: "nodeType", value: .newInt32(nodeTypeInt(node)))
        ctx.setPropertyStr(obj: el, name: "nodeName", value: ctx.newStringValue(nodeNameStr(node)))
        ctx.setPropertyStr(obj: el, name: "tagName", value: ctx.newStringValue((node.tagName ?? "").uppercased()))
        ctx.setPropertyStr(obj: el, name: "localName", value: ctx.newStringValue(node.tagName ?? ""))
        ctx.setPropertyStr(obj: el, name: "nativeNodeID", value: ctx.newStringValue(node.id.uuidString))
        if let owner = ownerDocumentValue(for: node) {
            ctx.setPropertyStr(obj: el, name: "ownerDocument", value: owner)
        }

        // -- Per-instance style sub-object --
        if node.nodeType == .element {
            let styleObj = buildStyleObject(for: node, ctx: ctx)
            ctx.setPropertyStr(obj: el, name: "style", value: styleObj)
        }

        // For <video> elements, trigger native event registration so media
        // events (timeupdate, play, pause, ended, etc.) flow from AVPlayer to JS.
        if node.tagName == "video" {
            let regFn = ctx.getPropertyStr(obj: el, name: "__registerVideoEvents")
            if !regFn.isUndefined && !regFn.isNull {
                _ = ctx.call(regFn, this: el, args: [])
                regFn.freeValue()
            }
        }

        nodeRegistry[node.id] = node
        elementCache[node.id] = el.dupValue()
        return el
    }

    /// The `ownerDocument` value for a node: the page document unless the node
    /// belongs to a detached document handed out by `createHTMLDocument` /
    /// `DOMParser`. The subtree walk only runs once such a document exists, so
    /// ordinary pages pay nothing.
    private func ownerDocumentValue(for node: DOMNode) -> JeffJSValue? {
        if !detachedDocumentRoots.isEmpty {
            var cursor: DOMNode? = node
            while let current = cursor {
                if let owner = detachedDocuments[current.id] { return owner.dupValue() }
                cursor = current.parent
            }
        }
        return documentJSValue?.dupValue()
    }

    /// Wraps an array of DOMNodes as a JeffJS array.
    private func wrapElementArray(_ nodes: [DOMNode], ctx: JeffJSContext) -> JeffJSValue {
        let arr = ctx.newArray()
        for (i, node) in nodes.enumerated() {
            let wrapped = wrapElement(node, ctx: ctx)
            ctx.setPropertyUint32(obj: arr, index: UInt32(i), value: wrapped)
        }
        // Set the length property
        ctx.setPropertyStr(obj: arr, name: "length", value: .newInt32(Int32(nodes.count)))
        installNodeListShape(on: arr, ctx: ctx)
        return arr
    }

    /// Adds the `item()`/`namedItem()` methods real NodeList/HTMLCollection
    /// objects carry. The function objects are built once and duped onto each
    /// list, so this costs two refcount bumps per query instead of two closures.
    private func installNodeListShape(on arr: JeffJSValue, ctx: JeffJSContext) {
        if nodeListItemFn == nil {
            nodeListItemFn = ctx.newCFunction({ ctx, thisVal, args in
                guard let raw = args.first, let idx = ctx.toInt32(raw), idx >= 0 else { return JeffJSValue.null }
                let lenVal = ctx.getPropertyStr(obj: thisVal, name: "length")
                let len = ctx.toInt32(lenVal) ?? 0
                lenVal.freeValue()
                guard idx < len else { return JeffJSValue.null }
                return ctx.getPropertyUint32(obj: thisVal, index: UInt32(idx))
            }, name: "item", length: 1)
        }
        if nodeListNamedItemFn == nil {
            nodeListNamedItemFn = ctx.newCFunction({ ctx, thisVal, args in
                guard let name = ctx.toSwiftString(args.first ?? .undefined), !name.isEmpty else {
                    return JeffJSValue.null
                }
                let lenVal = ctx.getPropertyStr(obj: thisVal, name: "length")
                let len = ctx.toInt32(lenVal) ?? 0
                lenVal.freeValue()
                var i: Int32 = 0
                while i < len {
                    let entry = ctx.getPropertyUint32(obj: thisVal, index: UInt32(i))
                    let idVal = ctx.getPropertyStr(obj: entry, name: "id")
                    let idStr = ctx.toSwiftString(idVal)
                    idVal.freeValue()
                    if idStr == name { return entry }
                    let nameVal = ctx.getPropertyStr(obj: entry, name: "name")
                    let nameStr = ctx.toSwiftString(nameVal)
                    nameVal.freeValue()
                    if nameStr == name { return entry }
                    entry.freeValue()
                    i += 1
                }
                return JeffJSValue.null
            }, name: "namedItem", length: 1)
        }
        if let item = nodeListItemFn {
            ctx.setPropertyStr(obj: arr, name: "item", value: item.dupValue())
        }
        if let named = nodeListNamedItemFn {
            ctx.setPropertyStr(obj: arr, name: "namedItem", value: named.dupValue())
        }
    }

    /// Builds the shared element prototype. All DOM methods and property accessors
    /// live here — they're inherited by element instances via the prototype chain.
    /// Methods are non-enumerable (via setPropertyFunc), matching browser behavior.
    private func buildElementPrototype(ctx: JeffJSContext) -> JeffJSValue {
        let proto = ctx.newObject()

        // Register all methods on the prototype
        registerElementMethods(on: proto, ctx: ctx)

        // Register __get_*/__set_* native functions on the prototype
        registerElementPropertyAccessors(on: proto, ctx: ctx)

        // Install accessor properties (textContent, className, etc.) on the prototype
        installElementPropertyShim(on: proto, ctx: ctx)

        // Install on* event handler properties (initially null) so that
        // Preact's `'onclick' in element` check returns true, causing it to
        // use lowercase event names ('click') that match our event dispatch.
        let eventNames = [
            "onclick", "ondblclick", "onmousedown", "onmouseup", "onmousemove",
            "onmouseover", "onmouseout", "onmouseenter", "onmouseleave",
            "onkeydown", "onkeyup", "onkeypress",
            "onfocus", "onblur", "onfocusin", "onfocusout",
            "oninput", "onchange", "onsubmit", "onreset",
            "ontouchstart", "ontouchend", "ontouchmove", "ontouchcancel",
            "onpointerdown", "onpointerup", "onpointermove",
            "onpointerover", "onpointerout", "onpointerenter", "onpointerleave",
            "onscroll", "onwheel", "onresize",
            "ondrag", "ondragstart", "ondragend", "ondragover", "ondragenter", "ondragleave", "ondrop",
            "onanimationstart", "onanimationend", "onanimationiteration",
            "ontransitionend", "onload", "onerror",
            "oncontextmenu", "onselect", "oncopy", "oncut", "onpaste",
        ]
        for name in eventNames {
            ctx.setPropertyStr(obj: proto, name: name, value: .null)
        }

        // Node.* constants are also exposed on every node instance.
        let nodeConstants: [(String, Int32)] = [
            ("ELEMENT_NODE", 1), ("ATTRIBUTE_NODE", 2), ("TEXT_NODE", 3),
            ("CDATA_SECTION_NODE", 4), ("PROCESSING_INSTRUCTION_NODE", 7),
            ("COMMENT_NODE", 8), ("DOCUMENT_NODE", 9), ("DOCUMENT_TYPE_NODE", 10),
            ("DOCUMENT_FRAGMENT_NODE", 11),
            ("DOCUMENT_POSITION_DISCONNECTED", 1), ("DOCUMENT_POSITION_PRECEDING", 2),
            ("DOCUMENT_POSITION_FOLLOWING", 4), ("DOCUMENT_POSITION_CONTAINS", 8),
            ("DOCUMENT_POSITION_CONTAINED_BY", 16),
        ]
        for (name, value) in nodeConstants {
            ctx.setPropertyStr(obj: proto, name: name, value: .newInt32(value))
        }

        return proto
    }

    // MARK: - Element Methods

    private func registerElementMethods(on el: JeffJSValue, ctx: JeffJSContext) {
        var methodCount = 0
        func trackMethod(_ name: String) {
            methodCount += 1
        }

        // getAttribute(name) -> string | null
        ctx.setPropertyFunc(obj: el, name: "getAttribute", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.null }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.null }
            guard let name = self.extractString(ctx: ctx, args: args, index: 0) else {
                return JeffJSValue.null
            }
            guard let value = targetNode.attributes[name.lowercased()] else {
                return JeffJSValue.null
            }
            return ctx.newStringValue(value)
        }, length: 1)

        // setAttribute(name, value)
        ctx.setPropertyFunc(obj: el, name: "setAttribute", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            guard let name = self.extractString(ctx: ctx, args: args, index: 0),
                  let value = self.extractString(ctx: ctx, args: args, index: 1) else {
                return JeffJSValue.undefined
            }
            targetNode.setAttribute(name: name, value: value)
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 2)

        // removeAttribute(name)
        ctx.setPropertyFunc(obj: el, name: "removeAttribute", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            guard let name = self.extractString(ctx: ctx, args: args, index: 0) else {
                return JeffJSValue.undefined
            }
            targetNode.removeAttribute(name: name)
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // hasAttribute(name) -> bool
        ctx.setPropertyFunc(obj: el, name: "hasAttribute", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.JS_FALSE }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.JS_FALSE }
            guard let name = self.extractString(ctx: ctx, args: args, index: 0) else {
                return JeffJSValue.JS_FALSE
            }
            return .newBool(targetNode.attributes[name.lowercased()] != nil)
        }, length: 1)

        // getAttributeNames() -> array of strings
        ctx.setPropertyFunc(obj: el, name: "getAttributeNames", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return ctx.newArray() }
            guard let targetNode = self.extractNode(from: thisVal) else { return ctx.newArray() }
            let arr = ctx.newArray()
            let keys = Array(targetNode.attributes.keys)
            for (i, key) in keys.enumerated() {
                ctx.setPropertyUint32(obj: arr, index: UInt32(i), value: ctx.newStringValue(key))
            }
            ctx.setPropertyStr(obj: arr, name: "length", value: .newInt32(Int32(keys.count)))
            return arr
        }, length: 0)

        // appendChild(child) -> child
        ctx.setPropertyFunc(obj: el, name: "appendChild", fn: { [weak self] ctx, thisVal, args in
            guard let self, !args.isEmpty else { return JeffJSValue.null }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.null }
            guard let childNode = self.extractNode(from: args[0], ctx: ctx) else { return JeffJSValue.null }
            // Remove from old parent first
            if let oldParent = childNode.parent {
                oldParent.removeChild(childNode)
            }
            targetNode.appendChild(childNode)
            self.notifyMutation(for: targetNode)
            return args[0].dupValue()
        }, length: 1)

        // removeChild(child) -> child
        ctx.setPropertyFunc(obj: el, name: "removeChild", fn: { [weak self] ctx, thisVal, args in
            guard let self, !args.isEmpty else { return JeffJSValue.null }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.null }
            guard let childNode = self.extractNode(from: args[0], ctx: ctx) else { return JeffJSValue.null }
            targetNode.removeChild(childNode)
            self.clearNodeAndDescendants(childNode)
            self.notifyMutation(for: targetNode)
            return args[0].dupValue()
        }, length: 1)

        // insertBefore(newChild, referenceChild) -> newChild
        ctx.setPropertyFunc(obj: el, name: "insertBefore", fn: { [weak self] ctx, thisVal, args in
            guard let self, !args.isEmpty else { return JeffJSValue.null }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.null }
            guard let newChild = self.extractNode(from: args[0], ctx: ctx) else { return JeffJSValue.null }

            // Remove from old parent first
            if let oldParent = newChild.parent {
                oldParent.removeChild(newChild)
            }

            if args.count > 1, !args[1].isNull, !args[1].isUndefined,
               let refChild = self.extractNode(from: args[1], ctx: ctx) {
                targetNode.insertChild(newChild, before: refChild)
            } else {
                targetNode.appendChild(newChild)
            }
            self.notifyMutation(for: targetNode)
            return args[0].dupValue()
        }, length: 2)

        // replaceChild(newChild, oldChild) -> oldChild
        ctx.setPropertyFunc(obj: el, name: "replaceChild", fn: { [weak self] ctx, thisVal, args in
            guard let self, args.count >= 2 else { return JeffJSValue.null }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.null }
            guard let newChild = self.extractNode(from: args[0]),
                  let oldChild = self.extractNode(from: args[1]) else { return JeffJSValue.null }
            if let oldParent = newChild.parent {
                oldParent.removeChild(newChild)
            }
            targetNode.insertChild(newChild, before: oldChild)
            targetNode.removeChild(oldChild)
            self.clearNodeAndDescendants(oldChild)
            self.notifyMutation(for: targetNode)
            return args[1].dupValue()
        }, length: 2)

        // remove() — removes self from parent
        ctx.setPropertyFunc(obj: el, name: "remove", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            guard let parent = targetNode.parent else { return JeffJSValue.undefined }
            parent.removeChild(targetNode)
            self.clearNodeAndDescendants(targetNode)
            self.notifyMutation(for: parent)
            return JeffJSValue.undefined
        }, length: 0)

        // append(...nodes) — append multiple children (strings become text nodes)
        ctx.setPropertyFunc(obj: el, name: "append", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            for arg in args {
                if let childNode = self.extractNode(from: arg, ctx: ctx) {
                    if let oldParent = childNode.parent { oldParent.removeChild(childNode) }
                    targetNode.appendChild(childNode)
                } else if let text = ctx.toSwiftString(arg) {
                    targetNode.appendChild(DOMNode.text(text))
                }
            }
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 0)

        // prepend(...nodes)
        ctx.setPropertyFunc(obj: el, name: "prepend", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            let firstChild = targetNode.children.first
            for arg in args {
                if let childNode = self.extractNode(from: arg, ctx: ctx) {
                    if let oldParent = childNode.parent { oldParent.removeChild(childNode) }
                    if let ref = firstChild {
                        targetNode.insertChild(childNode, before: ref)
                    } else {
                        targetNode.appendChild(childNode)
                    }
                } else if let text = ctx.toSwiftString(arg) {
                    let textNode = DOMNode.text(text)
                    if let ref = firstChild {
                        targetNode.insertChild(textNode, before: ref)
                    } else {
                        targetNode.appendChild(textNode)
                    }
                }
            }
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 0)

        // before(...nodes) — insert before this element
        ctx.setPropertyFunc(obj: el, name: "before", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            guard let parent = targetNode.parent else { return JeffJSValue.undefined }
            for arg in args {
                if let childNode = self.extractNode(from: arg, ctx: ctx) {
                    if let oldParent = childNode.parent { oldParent.removeChild(childNode) }
                    parent.insertChild(childNode, before: targetNode)
                } else if let text = ctx.toSwiftString(arg) {
                    parent.insertChild(DOMNode.text(text), before: targetNode)
                }
            }
            self.notifyMutation(for: parent)
            return JeffJSValue.undefined
        }, length: 0)

        // after(...nodes) — insert after this element
        ctx.setPropertyFunc(obj: el, name: "after", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            guard let parent = targetNode.parent else { return JeffJSValue.undefined }
            let nextSibling = self.nextSibling(of: targetNode)
            for arg in args {
                if let childNode = self.extractNode(from: arg, ctx: ctx) {
                    if let oldParent = childNode.parent { oldParent.removeChild(childNode) }
                    if let ref = nextSibling {
                        parent.insertChild(childNode, before: ref)
                    } else {
                        parent.appendChild(childNode)
                    }
                } else if let text = ctx.toSwiftString(arg) {
                    let textNode = DOMNode.text(text)
                    if let ref = nextSibling {
                        parent.insertChild(textNode, before: ref)
                    } else {
                        parent.appendChild(textNode)
                    }
                }
            }
            self.notifyMutation(for: parent)
            return JeffJSValue.undefined
        }, length: 0)

        // replaceWith(...nodes) — replace this element with other nodes
        ctx.setPropertyFunc(obj: el, name: "replaceWith", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            guard let parent = targetNode.parent else { return JeffJSValue.undefined }
            for arg in args {
                if let childNode = self.extractNode(from: arg, ctx: ctx) {
                    if let oldParent = childNode.parent { oldParent.removeChild(childNode) }
                    parent.insertChild(childNode, before: targetNode)
                } else if let text = ctx.toSwiftString(arg) {
                    parent.insertChild(DOMNode.text(text), before: targetNode)
                }
            }
            parent.removeChild(targetNode)
            self.notifyMutation(for: parent)
            return JeffJSValue.undefined
        }, length: 0)

        // querySelector(selector) on element
        ctx.setPropertyFunc(obj: el, name: "querySelector", fn: { [weak self] ctx, thisVal, args in
            guard let self, let selector = self.extractString(ctx: ctx, args: args, index: 0) else {
                return JeffJSValue.null
            }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.null }
            guard let found = targetNode.querySelector(selector) else { return JeffJSValue.null }
            return self.wrapElement(found, ctx: ctx)
        }, length: 1)

        // querySelectorAll(selector) on element
        ctx.setPropertyFunc(obj: el, name: "querySelectorAll", fn: { [weak self] ctx, thisVal, args in
            guard let self, let selector = self.extractString(ctx: ctx, args: args, index: 0) else {
                return self?.wrapElementArray([], ctx: ctx) ?? JeffJSValue.null
            }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.null }
            let nodes = targetNode.querySelectorAll(selector)
            return self.wrapElementArray(nodes, ctx: ctx)
        }, length: 1)

        // getElementsByClassName on element
        ctx.setPropertyFunc(obj: el, name: "getElementsByClassName", fn: { [weak self] ctx, thisVal, args in
            guard let self, let className = self.extractString(ctx: ctx, args: args, index: 0) else {
                return self?.wrapElementArray([], ctx: ctx) ?? JeffJSValue.null
            }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.null }
            let classes = DOMNode.splitASCIIWhitespace(className)
            guard !classes.isEmpty else { return self.wrapElementArray([], ctx: ctx) }
            let nodes = self.allElementDescendants(of: targetNode).filter { n in
                let nc = n.classList
                return classes.allSatisfy { nc.contains($0) }
            }
            return self.wrapElementArray(nodes, ctx: ctx)
        }, length: 1)

        // getElementsByTagName on element
        ctx.setPropertyFunc(obj: el, name: "getElementsByTagName", fn: { [weak self] ctx, thisVal, args in
            guard let self, let tagName = self.extractString(ctx: ctx, args: args, index: 0) else {
                return self?.wrapElementArray([], ctx: ctx) ?? JeffJSValue.null
            }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.null }
            let normalized = tagName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let nodes = self.allElementDescendants(of: targetNode).filter {
                normalized == "*" || $0.tagName == normalized
            }
            return self.wrapElementArray(nodes, ctx: ctx)
        }, length: 1)

        // addEventListener(type, handler, options?) — routes through centralized event bridge
        // for proper capture/bubble phase support (required by React 18's event delegation)
        ctx.setPropertyFunc(obj: el, name: "addEventListener", fn: { [weak self] ctx, thisVal, args in
            guard let self, args.count >= 2 else { return JeffJSValue.undefined }
            let options = args.count >= 3 ? args[2] : JeffJSValue.undefined
            self.eventBridge?.addEventListener(ctx: ctx, target: thisVal, type: args[0], listener: args[1], options: options)
            return JeffJSValue.undefined
        }, length: 2)

        // removeEventListener(type, handler) — routes through centralized event bridge
        ctx.setPropertyFunc(obj: el, name: "removeEventListener", fn: { [weak self] ctx, thisVal, args in
            guard let self, args.count >= 2 else { return JeffJSValue.undefined }
            let options = args.count >= 3 ? args[2] : JeffJSValue.undefined
            self.eventBridge?.removeEventListener(ctx: ctx, target: thisVal, type: args[0], listener: args[1], options: options)
            return JeffJSValue.undefined
        }, length: 2)

        // dispatchEvent(event) — routes through centralized event bridge
        // for proper capture/at-target/bubble phase dispatch with full bubble path traversal
        ctx.setPropertyFunc(obj: el, name: "dispatchEvent", fn: { [weak self] ctx, thisVal, args in
            guard let self, !args.isEmpty else { return .newBool(true) }
            let result = self.eventBridge?.dispatchEvent(ctx: ctx, target: thisVal, event: args[0]) ?? true
            return .newBool(result)
        }, length: 1)

        // matches(selector) -> bool
        ctx.setPropertyFunc(obj: el, name: "matches", fn: { [weak self] ctx, thisVal, args in
            guard let self, let selector = self.extractString(ctx: ctx, args: args, index: 0) else {
                return .newBool(false)
            }
            guard let targetNode = self.extractNode(from: thisVal) else { return .newBool(false) }
            // Match the node directly: the old parent-scoped test reported false
            // for every detached element (jQuery filters parsed fragments).
            return .newBool(targetNode.matchesSelector(selector))
        }, length: 1)

        // webkitMatchesSelector / msMatchesSelector aliases (Sizzle probes them)
        for alias in ["webkitMatchesSelector", "msMatchesSelector"] {
            ctx.setPropertyFunc(obj: el, name: alias, fn: { [weak self] ctx, thisVal, args in
                guard let self, let selector = self.extractString(ctx: ctx, args: args, index: 0),
                      let targetNode = self.extractNode(from: thisVal) else { return .newBool(false) }
                return .newBool(targetNode.matchesSelector(selector))
            }, length: 1)
        }

        // closest(selector) -> nearest self-or-ancestor element, or null
        ctx.setPropertyFunc(obj: el, name: "closest", fn: { [weak self] ctx, thisVal, args in
            guard let self, let selector = self.extractString(ctx: ctx, args: args, index: 0),
                  let targetNode = self.extractNode(from: thisVal),
                  let found = targetNode.closestMatching(selector) else { return JeffJSValue.null }
            return self.wrapElement(found, ctx: ctx)
        }, length: 1)

        // hasAttributes() -> bool
        ctx.setPropertyFunc(obj: el, name: "hasAttributes", fn: { [weak self] ctx, thisVal, _ in
            guard let self, let targetNode = self.extractNode(from: thisVal) else { return .newBool(false) }
            return .newBool(!targetNode.attributes.isEmpty)
        }, length: 0)

        // toggleAttribute(name, force?) -> bool (the attribute's new presence)
        ctx.setPropertyFunc(obj: el, name: "toggleAttribute", fn: { [weak self] ctx, thisVal, args in
            guard let self, let targetNode = self.extractNode(from: thisVal),
                  let rawName = self.extractString(ctx: ctx, args: args, index: 0) else { return .newBool(false) }
            let name = rawName.lowercased()
            let present = targetNode.attributes[name] != nil
            let hasForce = args.count >= 2 && !args[1].isUndefined
            let shouldSet = hasForce ? args[1].toBool() : !present
            if shouldSet {
                if !present { targetNode.setAttribute(name: name, value: "") }
            } else if present {
                targetNode.removeAttribute(name: name)
            }
            if shouldSet != present { self.notifyMutation(for: targetNode) }
            return .newBool(shouldSet)
        }, length: 2)

        // compareDocumentPosition(other) -> bitmask (DISCONNECTED 1, PRECEDING 2,
        // FOLLOWING 4, CONTAINS 8, CONTAINED_BY 16)
        ctx.setPropertyFunc(obj: el, name: "compareDocumentPosition", fn: { [weak self] ctx, thisVal, args in
            guard let self, !args.isEmpty,
                  let a = self.extractNode(from: thisVal),
                  let b = self.extractNode(from: args[0]) else { return .newInt32(1) }
            return .newInt32(self.documentPosition(of: a, relativeTo: b))
        }, length: 1)

        // insertAdjacentElement(position, element) -> element | null
        ctx.setPropertyFunc(obj: el, name: "insertAdjacentElement", fn: { [weak self] ctx, thisVal, args in
            guard let self, args.count >= 2,
                  let position = self.extractString(ctx: ctx, args: args, index: 0),
                  let targetNode = self.extractNode(from: thisVal),
                  let newNode = self.extractNode(from: args[1], ctx: ctx) else { return JeffJSValue.null }
            guard self.insertAdjacent(position: position, target: targetNode, nodes: [newNode]) else {
                return JeffJSValue.null
            }
            return args[1].dupValue()
        }, length: 2)

        // insertAdjacentText(position, text)
        ctx.setPropertyFunc(obj: el, name: "insertAdjacentText", fn: { [weak self] ctx, thisVal, args in
            guard let self, args.count >= 2,
                  let position = self.extractString(ctx: ctx, args: args, index: 0),
                  let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            let text = self.extractString(ctx: ctx, args: args, index: 1) ?? ""
            _ = self.insertAdjacent(position: position, target: targetNode, nodes: [DOMNode.text(text)])
            return JeffJSValue.undefined
        }, length: 2)

        // insertAdjacentHTML(position, html)
        ctx.setPropertyFunc(obj: el, name: "insertAdjacentHTML", fn: { [weak self] ctx, thisVal, args in
            guard let self, args.count >= 2,
                  let position = self.extractString(ctx: ctx, args: args, index: 0),
                  let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            let html = self.extractString(ctx: ctx, args: args, index: 1) ?? ""
            _ = self.insertAdjacent(position: position, target: targetNode, nodes: Self.parseHTMLFragment(html))
            return JeffJSValue.undefined
        }, length: 2)

        // replaceChildren(...nodes) — drop every child, then append the arguments
        ctx.setPropertyFunc(obj: el, name: "replaceChildren", fn: { [weak self] ctx, thisVal, args in
            guard let self, let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            for child in targetNode.children { self.clearNodeAndDescendants(child) }
            targetNode.clearChildren()
            for arg in args {
                if let childNode = self.extractNode(from: arg, ctx: ctx) {
                    if let oldParent = childNode.parent { oldParent.removeChild(childNode) }
                    targetNode.appendChild(childNode)
                } else if let text = ctx.toSwiftString(arg) {
                    targetNode.appendChild(DOMNode.text(text))
                }
            }
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 0)

        // cloneNode(deep) -> element
        ctx.setPropertyFunc(obj: el, name: "cloneNode", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.null }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.null }
            let deep = !args.isEmpty && args[0].toBool()
            let cloned = self.cloneDOMNode(targetNode, deep: deep)
            return self.wrapElement(cloned, ctx: ctx)
        }, length: 1)

        // contains(other) -> bool
        ctx.setPropertyFunc(obj: el, name: "contains", fn: { [weak self] ctx, thisVal, args in
            guard let self, !args.isEmpty else { return .newBool(false) }
            guard let targetNode = self.extractNode(from: thisVal) else { return .newBool(false) }
            guard let otherNode = self.extractNode(from: args[0]) else { return .newBool(false) }
            return .newBool(self.nodeContains(targetNode, child: otherNode))
        }, length: 1)

        // focus() / blur() — no-ops in this environment
        ctx.setPropertyFunc(obj: el, name: "focus", fn: { _, _, _ in JeffJSValue.undefined }, length: 0)
        ctx.setPropertyFunc(obj: el, name: "blur", fn: { _, _, _ in JeffJSValue.undefined }, length: 0)

        // -- Geometry: getBoundingClientRect / getClientRects / scrolling --
        registerElementGeometryMethods(on: el, ctx: ctx)

        // checkVisibility(options?) — used by apple.com's globalheader.umd.js.
        // Returns true unless the element has the `hidden` attribute, or
        // inline styles set visibility:hidden / opacity:0 (when requested via options).
        ctx.setPropertyFunc(obj: el, name: "checkVisibility", fn: { [weak self] ctx, thisVal, args in
            guard let self, let node = self.extractNode(from: thisVal) else {
                return JeffJSValue.JS_TRUE
            }
            if node.attributes["hidden"] != nil { return JeffJSValue.JS_FALSE }
            if args.count > 0 && !args[0].isUndefined && !args[0].isNull,
               let style = node.attributes["style"]?.lowercased() {
                let opts = args[0]
                let vp = ctx.getPropertyStr(obj: opts, name: "visibilityProperty")
                let checkVis = vp.toBool()
                vp.freeValue()
                if checkVis && style.contains("visibility") && style.contains("hidden") {
                    return JeffJSValue.JS_FALSE
                }
                let op = ctx.getPropertyStr(obj: opts, name: "opacityProperty")
                let checkOp = op.toBool()
                op.freeValue()
                if checkOp && style.contains("opacity") && (style.contains(":0") || style.contains(": 0")) {
                    return JeffJSValue.JS_FALSE
                }
            }
            return JeffJSValue.JS_TRUE
        }, length: 1)
    }

    // MARK: - Element Property Accessors

    private func registerElementPropertyAccessors(on el: JeffJSValue, ctx: JeffJSContext) {
        // -- textContent (read-write) --
        ctx.setPropertyFunc(obj: el, name: "__get_textContent", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return ctx.newStringValue("") }
            guard let targetNode = self.extractNode(from: thisVal) else { return ctx.newStringValue("") }
            return ctx.newStringValue(targetNode.rawTextDescendants)
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__set_textContent", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            let text = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            for child in targetNode.children { self.clearNodeAndDescendants(child) }
            targetNode.setTextContent(text)
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- innerText (read-write) --
        ctx.setPropertyFunc(obj: el, name: "__get_innerText", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return ctx.newStringValue("") }
            guard let targetNode = self.extractNode(from: thisVal) else { return ctx.newStringValue("") }
            return ctx.newStringValue(targetNode.textDescendants)
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__set_innerText", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            let text = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            for child in targetNode.children { self.clearNodeAndDescendants(child) }
            targetNode.setTextContent(text)
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- innerHTML (read-write) --
        ctx.setPropertyFunc(obj: el, name: "__get_innerHTML", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return ctx.newStringValue("") }
            guard var targetNode = self.extractNode(from: thisVal) else { return ctx.newStringValue("") }
            // A <template>'s markup lives in its content fragment, not its children.
            if targetNode.tagName == "template" { targetNode = self.templateFragment(for: targetNode) }
            let html = targetNode.children.map { Self.serializeHTML($0) }.joined()
            return ctx.newStringValue(html)
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__set_innerHTML", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard var targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            if targetNode.tagName == "template" { targetNode = self.templateFragment(for: targetNode) }
            let html = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            for child in targetNode.children { self.clearNodeAndDescendants(child) }
            targetNode.clearChildren()
            let parsed = Self.parseHTMLFragment(html)
            for child in parsed {
                targetNode.appendChild(child)
            }
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- outerHTML (read) --
        ctx.setPropertyFunc(obj: el, name: "__get_outerHTML", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return ctx.newStringValue("") }
            guard let targetNode = self.extractNode(from: thisVal) else { return ctx.newStringValue("") }
            return ctx.newStringValue(Self.serializeHTML(targetNode))
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__set_outerHTML", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            guard let parent = targetNode.parent else { return JeffJSValue.undefined }
            let html = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            for node in Self.parseHTMLFragment(html) {
                parent.insertChild(node, before: targetNode)
            }
            parent.removeChild(targetNode)
            self.clearNodeAndDescendants(targetNode)
            self.notifyMutation(for: parent)
            return JeffJSValue.undefined
        }, length: 1)

        // -- content (a DocumentFragment on <template>, the reflected
        //    attribute everywhere else) --
        // `<meta name=… content=…>` is the common case: apple.com's global
        // header reads `meta.content` off every `meta[name^="globalnav-"]`,
        // and an undefined there took `.replace` down with it.
        ctx.setPropertyFunc(obj: el, name: "__get_content", fn: { [weak self] ctx, thisVal, _ in
            guard let self, let targetNode = self.extractNode(from: thisVal) else {
                return JeffJSValue.undefined
            }
            if targetNode.tagName == "template" {
                return self.wrapElement(self.templateFragment(for: targetNode), ctx: ctx)
            }
            return ctx.newStringValue(targetNode.attributes["content"] ?? "")
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__set_content", fn: { [weak self] ctx, thisVal, args in
            guard let self, let targetNode = self.extractNode(from: thisVal),
                  targetNode.tagName != "template" else { return JeffJSValue.undefined }
            targetNode.setAttribute(name: "content", value: self.extractString(ctx: ctx, args: args, index: 0) ?? "")
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- id (read-write) --
        ctx.setPropertyFunc(obj: el, name: "__get_id", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return ctx.newStringValue("") }
            guard let targetNode = self.extractNode(from: thisVal) else { return ctx.newStringValue("") }
            return ctx.newStringValue(targetNode.attributes["id"] ?? "")
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__set_id", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            let value = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            targetNode.setAttribute(name: "id", value: value)
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- className (read-write) --
        ctx.setPropertyFunc(obj: el, name: "__get_className", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return ctx.newStringValue("") }
            guard let targetNode = self.extractNode(from: thisVal) else { return ctx.newStringValue("") }
            return ctx.newStringValue(targetNode.attributes["class"] ?? "")
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__set_className", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            let value = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            targetNode.setAttribute(name: "class", value: value)
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- value (read-write, for form elements) --
        ctx.setPropertyFunc(obj: el, name: "__get_value", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return ctx.newStringValue("") }
            guard let targetNode = self.extractNode(from: thisVal) else { return ctx.newStringValue("") }
            return ctx.newStringValue(targetNode.attributes["value"] ?? "")
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__set_value", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            let value = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            targetNode.setAttribute(name: "value", value: value)
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- checked (read-write, for checkboxes) --
        ctx.setPropertyFunc(obj: el, name: "__get_checked", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return JeffJSValue.JS_FALSE }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.JS_FALSE }
            return .newBool(targetNode.attributes["checked"] != nil)
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__set_checked", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            let checked = !args.isEmpty && args[0].toBool()
            if checked {
                targetNode.setAttribute(name: "checked", value: "")
            } else {
                targetNode.removeAttribute(name: "checked")
            }
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- hidden (read-write) --
        ctx.setPropertyFunc(obj: el, name: "__get_hidden", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return JeffJSValue.JS_FALSE }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.JS_FALSE }
            return .newBool(targetNode.attributes["hidden"] != nil)
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__set_hidden", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            let hidden = !args.isEmpty && args[0].toBool()
            if hidden {
                targetNode.setAttribute(name: "hidden", value: "")
            } else {
                targetNode.removeAttribute(name: "hidden")
            }
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- src (read-write) --
        ctx.setPropertyFunc(obj: el, name: "__get_src", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return ctx.newStringValue("") }
            guard let targetNode = self.extractNode(from: thisVal) else { return ctx.newStringValue("") }
            return ctx.newStringValue(targetNode.attributes["src"] ?? "")
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__set_src", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            let value = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            targetNode.setAttribute(name: "src", value: value)
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- href (read-write) --
        ctx.setPropertyFunc(obj: el, name: "__get_href", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return ctx.newStringValue("") }
            guard let targetNode = self.extractNode(from: thisVal) else { return ctx.newStringValue("") }
            return ctx.newStringValue(targetNode.attributes["href"] ?? "")
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__set_href", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            let value = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            targetNode.setAttribute(name: "href", value: value)
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- nodeValue (read-write for text/comment nodes) --
        ctx.setPropertyFunc(obj: el, name: "__get_nodeValue", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return JeffJSValue.null }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.null }
            switch targetNode.nodeType {
            case .text, .comment:
                return ctx.newStringValue(targetNode.textContent ?? "")
            default:
                return JeffJSValue.null
            }
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__set_nodeValue", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            let value = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            switch targetNode.nodeType {
            case .text, .comment:
                targetNode.textContent = value
                self.notifyMutation(for: targetNode)
            default:
                break
            }
            return JeffJSValue.undefined
        }, length: 1)

        // -- isConnected (read-only) --
        ctx.setPropertyFunc(obj: el, name: "__get_isConnected", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return .newBool(false) }
            guard let targetNode = self.extractNode(from: thisVal) else { return .newBool(false) }
            return .newBool(self.isConnected(targetNode))
        }, length: 0)

        // -- parentNode / parentElement --
        ctx.setPropertyFunc(obj: el, name: "__get_parentNode", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return JeffJSValue.null }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.null }
            guard let parent = targetNode.parent else { return JeffJSValue.null }
            // `document.documentElement.parentNode === document` in browsers, so
            // hand back the real document object rather than a wrapper around the
            // root node — `getRootNode()`/`isConnected` walks depend on it.
            if parent === self.root, let docVal = self.documentJSValue {
                return docVal.dupValue()
            }
            return self.wrapElement(parent, ctx: ctx)
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__get_parentElement", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return JeffJSValue.null }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.null }
            guard let parent = targetNode.parent, parent.nodeType == .element else { return JeffJSValue.null }
            return self.wrapElement(parent, ctx: ctx)
        }, length: 0)

        // -- data (alias for nodeValue — used by Preact for text node updates) --
        ctx.setPropertyFunc(obj: el, name: "__get_data", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return ctx.newStringValue("") }
            guard let targetNode = self.extractNode(from: thisVal) else { return ctx.newStringValue("") }
            return ctx.newStringValue(targetNode.textContent ?? "")
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__set_data", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            let value = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            targetNode.textContent = value
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- childNodes --
        ctx.setPropertyFunc(obj: el, name: "__get_childNodes", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return ctx.newArray() }
            guard let targetNode = self.extractNode(from: thisVal) else { return ctx.newArray() }
            return self.wrapElementArray(targetNode.children, ctx: ctx)
        }, length: 0)

        // -- children (element children only) --
        ctx.setPropertyFunc(obj: el, name: "__get_children", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return ctx.newArray() }
            guard let targetNode = self.extractNode(from: thisVal) else { return ctx.newArray() }
            let elementChildren = targetNode.children.filter { $0.nodeType == .element }
            return self.wrapElementArray(elementChildren, ctx: ctx)
        }, length: 0)

        // -- firstChild / lastChild --
        ctx.setPropertyFunc(obj: el, name: "__get_firstChild", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return JeffJSValue.null }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.null }
            guard let first = targetNode.children.first else { return JeffJSValue.null }
            return self.wrapElement(first, ctx: ctx)
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__get_lastChild", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return JeffJSValue.null }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.null }
            guard let last = targetNode.children.last else { return JeffJSValue.null }
            return self.wrapElement(last, ctx: ctx)
        }, length: 0)

        // -- nextSibling / previousSibling --
        ctx.setPropertyFunc(obj: el, name: "__get_nextSibling", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return JeffJSValue.null }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.null }
            guard let sibling = self.nextSibling(of: targetNode) else { return JeffJSValue.null }
            return self.wrapElement(sibling, ctx: ctx)
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__get_previousSibling", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return JeffJSValue.null }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.null }
            guard let sibling = self.previousSibling(of: targetNode) else { return JeffJSValue.null }
            return self.wrapElement(sibling, ctx: ctx)
        }, length: 0)

        // -- nextElementSibling / previousElementSibling --
        ctx.setPropertyFunc(obj: el, name: "__get_nextElementSibling", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return JeffJSValue.null }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.null }
            guard let sibling = self.nextElementSibling(of: targetNode) else { return JeffJSValue.null }
            return self.wrapElement(sibling, ctx: ctx)
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__get_previousElementSibling", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return JeffJSValue.null }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.null }
            guard let sibling = self.previousElementSibling(of: targetNode) else { return JeffJSValue.null }
            return self.wrapElement(sibling, ctx: ctx)
        }, length: 0)

        // -- firstElementChild / lastElementChild --
        ctx.setPropertyFunc(obj: el, name: "__get_firstElementChild", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return JeffJSValue.null }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.null }
            guard let first = targetNode.children.first(where: { $0.nodeType == .element }) else { return JeffJSValue.null }
            return self.wrapElement(first, ctx: ctx)
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__get_lastElementChild", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return JeffJSValue.null }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.null }
            guard let last = targetNode.children.last(where: { $0.nodeType == .element }) else { return JeffJSValue.null }
            return self.wrapElement(last, ctx: ctx)
        }, length: 0)

        // -- childElementCount --
        ctx.setPropertyFunc(obj: el, name: "__get_childElementCount", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return .newInt32(0) }
            guard let targetNode = self.extractNode(from: thisVal) else { return .newInt32(0) }
            return .newInt32(Int32(targetNode.children.filter { $0.nodeType == .element }.count))
        }, length: 0)

        // -- style sub-object --
        ctx.setPropertyFunc(obj: el, name: "__get_style", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return ctx.newObject() }
            guard let targetNode = self.extractNode(from: thisVal) else { return ctx.newObject() }
            return self.buildStyleObject(for: targetNode, ctx: ctx)
        }, length: 0)

        // -- classList sub-object --
        ctx.setPropertyFunc(obj: el, name: "__get_classList", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return ctx.newObject() }
            guard let targetNode = self.extractNode(from: thisVal) else { return ctx.newObject() }
            if let cached = self.classListCache[targetNode.id] { return cached.dupValue() }
            let list = self.buildClassListObject(for: targetNode, ctx: ctx)
            self.classListCache[targetNode.id] = list.dupValue()
            return list
        }, length: 0)

        // -- relList sub-object (<a rel>, <link rel>, <area rel>) --
        ctx.setPropertyFunc(obj: el, name: "__get_relList", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return ctx.newObject() }
            guard let targetNode = self.extractNode(from: thisVal) else { return ctx.newObject() }
            if let cached = self.relListCache[targetNode.id] { return cached.dupValue() }
            let list = self.buildTokenListObject(for: targetNode, attribute: "rel", ctx: ctx)
            self.relListCache[targetNode.id] = list.dupValue()
            return list
        }, length: 0)

        // -- rel (read-write string reflection) --
        ctx.setPropertyFunc(obj: el, name: "__get_rel", fn: { [weak self] ctx, thisVal, _ in
            guard let self, let targetNode = self.extractNode(from: thisVal) else { return ctx.newStringValue("") }
            return ctx.newStringValue(targetNode.attributes["rel"] ?? "")
        }, length: 0)
        ctx.setPropertyFunc(obj: el, name: "__set_rel", fn: { [weak self] ctx, thisVal, args in
            guard let self, let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            targetNode.setAttribute(name: "rel", value: self.extractString(ctx: ctx, args: args, index: 0) ?? "")
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- Plain string reflections (HTML "reflect" IDL attributes) --
        // Each is `el.<x>` <-> the `<x>` content attribute, the same shape as
        // src/href/rel above. Without them `meta.name`, `img.alt`,
        // `input.placeholder` … all read as undefined, and real page code does
        // `el.name.replace(...)` on them without a guard.
        for reflected in ["name", "alt", "title", "placeholder"] {
            ctx.setPropertyFunc(obj: el, name: "__get_\(reflected)", fn: { [weak self] ctx, thisVal, _ in
                guard let self, let targetNode = self.extractNode(from: thisVal) else {
                    return ctx.newStringValue("")
                }
                return ctx.newStringValue(targetNode.attributes[reflected] ?? "")
            }, length: 0)
            ctx.setPropertyFunc(obj: el, name: "__set_\(reflected)", fn: { [weak self] ctx, thisVal, args in
                guard let self, let targetNode = self.extractNode(from: thisVal) else {
                    return JeffJSValue.undefined
                }
                targetNode.setAttribute(name: reflected,
                                        value: self.extractString(ctx: ctx, args: args, index: 0) ?? "")
                self.notifyMutation(for: targetNode)
                return JeffJSValue.undefined
            }, length: 1)
        }

        // -- type (reflected, with the HTML defaults the attribute omits) --
        ctx.setPropertyFunc(obj: el, name: "__get_type", fn: { [weak self] ctx, thisVal, _ in
            guard let self, let targetNode = self.extractNode(from: thisVal) else {
                return ctx.newStringValue("")
            }
            if let t = targetNode.attributes["type"] { return ctx.newStringValue(t) }
            switch targetNode.tagName {
            case "input":  return ctx.newStringValue("text")
            case "button": return ctx.newStringValue("submit")
            default:       return ctx.newStringValue("")
            }
        }, length: 0)
        ctx.setPropertyFunc(obj: el, name: "__set_type", fn: { [weak self] ctx, thisVal, args in
            guard let self, let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            targetNode.setAttribute(name: "type", value: self.extractString(ctx: ctx, args: args, index: 0) ?? "")
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- Geometry accessors (offset*/client*/scroll*) --
        registerElementGeometryAccessors(on: el, ctx: ctx)
    }

    /// Installs getter/setter accessor properties on the element object using
    /// `setPropertyGetSet` directly from Swift — bypasses JS-level `Object.defineProperty`
    /// entirely to avoid JeffJS defineProperty bugs that prevent React from working.
    ///
    /// Reuses the `__get_*`/`__set_*` native function objects already registered on the
    /// element by `registerElementPropertyAccessors`. The getPropertyStr calls dup the
    /// refcount; the accessor property takes implicit ownership (matching the pattern
    /// used by JeffJS's atom-based setPropertyGetSet overload).
    private func installElementPropertyShim(on el: JeffJSValue, ctx: JeffJSContext) {
        let props: [(String, Bool)] = [
            ("textContent", true), ("innerText", true), ("innerHTML", true), ("outerHTML", true),
            ("content", true), ("classList", false), ("relList", false), ("rel", true),
            ("name", true), ("alt", true), ("title", true), ("placeholder", true), ("type", true),
            ("id", true), ("className", true), ("value", true),
            ("checked", true), ("hidden", true), ("src", true), ("href", true),
            ("nodeValue", true), ("data", true), ("isConnected", false),
            ("parentNode", false), ("parentElement", false),
            ("childNodes", false), ("children", false),
            ("firstChild", false), ("lastChild", false),
            ("nextSibling", false), ("previousSibling", false),
            ("nextElementSibling", false), ("previousElementSibling", false),
            ("firstElementChild", false), ("lastElementChild", false),
            ("childElementCount", false),
            // Geometry (see registerElementGeometryAccessors)
            ("offsetWidth", false), ("offsetHeight", false),
            ("offsetTop", false), ("offsetLeft", false), ("offsetParent", false),
            ("clientWidth", false), ("clientHeight", false),
            ("clientTop", false), ("clientLeft", false),
            ("scrollWidth", false), ("scrollHeight", false),
            ("scrollTop", true), ("scrollLeft", true),
        ]

        for (name, hasSetter) in props {
            let getter = ctx.getPropertyStr(obj: el, name: "__get_\(name)")
            guard getter.isFunction else { getter.freeValue(); continue }

            if hasSetter {
                let setter = ctx.getPropertyStr(obj: el, name: "__set_\(name)")
                // setPropertyGetSet stores raw .toObject() pointers — the dup'd refs
                // from getPropertyStr transfer ownership to the accessor property.
                ctx.setPropertyGetSet(obj: el, name: name, getter: getter, setter: setter)
            } else {
                ctx.setPropertyGetSet(obj: el, name: name, getter: getter, setter: nil)
            }
        }

        // classList is installed as an accessor above (see the props table): the
        // old eager materialisation called `__get_classList` with `this` bound to
        // the prototype, which has no DOMNode, so every element shared one empty
        // object and `el.classList.add` was undefined.
    }

    // MARK: - Geometry (layout rects -> JS)

    /// Installs `scrollX`/`scrollY`/`pageXOffset`/`pageYOffset` accessors on the
    /// global object, backed by `scrollOffset`. Setters update the offset and fire
    /// `onScrollChange(nil, offset)` so the host can scroll the real view.
    private func registerWindowScrollAccessors(on global: JeffJSValue, ctx: JeffJSContext) {
        let axes: [(names: [String], horizontal: Bool)] = [
            (["scrollX", "pageXOffset"], true),
            (["scrollY", "pageYOffset"], false),
        ]
        for axis in axes {
            let horizontal = axis.horizontal
            for name in axis.names {
                // newCFunction returns an owned value; setPropertyGetSet stores the
                // raw object pointers, taking over that reference.
                let getter = ctx.newCFunction({ [weak self] _, _, _ in
                    guard let self else { return .newInt32(0) }
                    return Self.numberValue(horizontal ? self.scrollOffset.x : self.scrollOffset.y)
                }, name: "get \(name)", length: 0)
                let setter = ctx.newCFunction({ [weak self] ctx, _, args in
                    guard let self, !args.isEmpty else { return JeffJSValue.undefined }
                    let v = ctx.toFloat64(args[0]) ?? 0
                    if horizontal { self.scrollOffset.x = v } else { self.scrollOffset.y = v }
                    self.onScrollChange?(nil, self.scrollOffset)
                    return JeffJSValue.undefined
                }, name: "set \(name)", length: 1)
                ctx.setPropertyGetSet(obj: global, name: name, getter: getter, setter: setter)
            }
        }
    }

    /// getBoundingClientRect(), getClientRects(), scrollIntoView(), scrollTo/scroll/scrollBy.
    private func registerElementGeometryMethods(on el: JeffJSValue, ctx: JeffJSContext) {
        // getBoundingClientRect() -> DOMRect in viewport coordinates
        ctx.setPropertyFunc(obj: el, name: "getBoundingClientRect", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return ctx.newObject() }
            let node = self.extractNode(from: thisVal)
            let rect = node.map { self.resolvedLayoutRect(for: $0) } ?? .zero
            return self.buildDOMRect(rect, ctx: ctx)
        }, length: 0)

        // getClientRects() -> one-element array-like (DOMRectList shape: length + item())
        ctx.setPropertyFunc(obj: el, name: "getClientRects", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return ctx.newArray() }
            let node = self.extractNode(from: thisVal)
            let rect = node.map { self.resolvedLayoutRect(for: $0) } ?? .zero
            let list = ctx.newArray()
            ctx.setPropertyUint32(obj: list, index: 0, value: self.buildDOMRect(rect, ctx: ctx))
            ctx.setPropertyFunc(obj: list, name: "item", fn: { ctx, listVal, args in
                let idx = args.isEmpty ? 0 : (ctx.toInt32(args[0]) ?? -1)
                guard idx == 0 else { return JeffJSValue.null }
                return ctx.getPropertyUint32(obj: listVal, index: 0)  // owned -> returned to caller
            }, length: 1)
            return list
        }, length: 0)

        // scrollIntoView(arg?) — no-op for layout; records the request for the host.
        ctx.setPropertyFunc(obj: el, name: "scrollIntoView", fn: { [weak self] _, thisVal, _ in
            guard let self, let node = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            self.scrollIntoViewRequests.append(node.id)
            let rect = self.resolvedLayoutRect(for: node)
            self.onScrollChange?(node, CGPoint(x: rect.minX, y: rect.minY))
            return JeffJSValue.undefined
        }, length: 1)
        ctx.setPropertyFunc(obj: el, name: "scrollIntoViewIfNeeded", fn: { [weak self] _, thisVal, _ in
            guard let self, let node = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            self.scrollIntoViewRequests.append(node.id)
            return JeffJSValue.undefined
        }, length: 1)

        // scrollTo(x, y) / scrollTo({left, top}) / scroll(...) / scrollBy(...)
        let scrollFn: (Bool) -> JeffJSNativeFunc = { relative in
            { [weak self] ctx, thisVal, args in
                guard let self, let node = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
                let current = self.scrollPosition(of: node)
                var x = relative ? 0 : current.x
                var y = relative ? 0 : current.y
                if let first = args.first, first.isObject {
                    let left = ctx.getPropertyStr(obj: first, name: "left")
                    let top = ctx.getPropertyStr(obj: first, name: "top")
                    defer { left.freeValue(); top.freeValue() }
                    if !left.isUndefined { x = ctx.toFloat64(left) ?? 0 }
                    if !top.isUndefined { y = ctx.toFloat64(top) ?? 0 }
                } else {
                    if args.count > 0 { x = ctx.toFloat64(args[0]) ?? 0 }
                    if args.count > 1 { y = ctx.toFloat64(args[1]) ?? 0 }
                }
                let target = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                self.setScrollPosition(target, for: node)
                return JeffJSValue.undefined
            }
        }
        ctx.setPropertyFunc(obj: el, name: "scrollTo", fn: scrollFn(false), length: 2)
        ctx.setPropertyFunc(obj: el, name: "scroll", fn: scrollFn(false), length: 2)
        ctx.setPropertyFunc(obj: el, name: "scrollBy", fn: scrollFn(true), length: 2)
    }

    /// `__get_offsetWidth` … `__set_scrollLeft`; wired into accessor properties by
    /// `installElementPropertyShim`.
    private func registerElementGeometryAccessors(on el: JeffJSValue, ctx: JeffJSContext) {
        func metric(_ name: String, _ body: @escaping (JeffJSDOMBridge, DOMNode) -> Double) {
            ctx.setPropertyFunc(obj: el, name: "__get_\(name)", fn: { [weak self] _, thisVal, _ in
                guard let self, let node = self.extractNode(from: thisVal) else { return .newInt32(0) }
                // offset*/client*/scroll* are integer `long`s in the DOM; round like browsers do.
                return Self.numberValue(body(self, node).rounded())
            }, length: 0)
        }

        // offsetWidth/offsetHeight — border box = layout rect size.
        metric("offsetWidth") { b, n in b.resolvedLayoutRect(for: n).width }
        metric("offsetHeight") { b, n in b.resolvedLayoutRect(for: n).height }

        // clientWidth/clientHeight — TODO: padding box (rect minus borders/scrollbars) once
        // the host pushes box metrics; for now the border box. The document element
        // reports the viewport, as browsers do.
        metric("clientWidth") { b, n in b.clientSize(of: n).width }
        metric("clientHeight") { b, n in b.clientSize(of: n).height }
        metric("clientTop") { _, _ in 0 }
        metric("clientLeft") { _, _ in 0 }

        // scrollWidth/scrollHeight — max(rect size, extent of descendants' rects).
        metric("scrollWidth") { b, n in b.scrollSize(of: n).width }
        metric("scrollHeight") { b, n in b.scrollSize(of: n).height }

        // offsetTop/offsetLeft — relative to offsetParent's rect.
        metric("offsetTop") { b, n in
            let r = b.resolvedLayoutRect(for: n)
            guard let parent = b.offsetParent(of: n) else { return r.minY }
            return r.minY - b.resolvedLayoutRect(for: parent).minY
        }
        metric("offsetLeft") { b, n in
            let r = b.resolvedLayoutRect(for: n)
            guard let parent = b.offsetParent(of: n) else { return r.minX }
            return r.minX - b.resolvedLayoutRect(for: parent).minX
        }

        // offsetParent
        ctx.setPropertyFunc(obj: el, name: "__get_offsetParent", fn: { [weak self] ctx, thisVal, _ in
            guard let self, let node = self.extractNode(from: thisVal),
                  let parent = self.offsetParent(of: node) else { return JeffJSValue.null }
            return self.wrapElement(parent, ctx: ctx)
        }, length: 0)

        // scrollTop/scrollLeft — stored per node; the document element maps to scrollOffset.
        metric("scrollTop") { b, n in b.scrollPosition(of: n).y }
        metric("scrollLeft") { b, n in b.scrollPosition(of: n).x }
        ctx.setPropertyFunc(obj: el, name: "__set_scrollTop", fn: { [weak self] ctx, thisVal, args in
            guard let self, let node = self.extractNode(from: thisVal), !args.isEmpty else { return JeffJSValue.undefined }
            var pos = self.scrollPosition(of: node)
            pos.y = ctx.toFloat64(args[0]) ?? 0
            self.setScrollPosition(pos, for: node)
            return JeffJSValue.undefined
        }, length: 1)
        ctx.setPropertyFunc(obj: el, name: "__set_scrollLeft", fn: { [weak self] ctx, thisVal, args in
            guard let self, let node = self.extractNode(from: thisVal), !args.isEmpty else { return JeffJSValue.undefined }
            var pos = self.scrollPosition(of: node)
            pos.x = ctx.toFloat64(args[0]) ?? 0
            self.setScrollPosition(pos, for: node)
            return JeffJSValue.undefined
        }, length: 1)
    }

    // MARK: Geometry helpers

    /// Integer-valued doubles become int32 values (browsers report `long`s), the rest float64.
    private static func numberValue(_ v: Double) -> JeffJSValue {
        if v == v.rounded(), abs(v) < 2_147_483_647 { return .newInt32(Int32(v)) }
        return .newFloat64(v)
    }

    /// Document-coordinate rect for a node. Mirrors the JSC path's `resolvedLayoutRect`:
    /// the host's layout rect if present, else inline-style `left/top/width/height` px
    /// (elements created after the last layout pass), else zeros.
    private func resolvedLayoutRect(for node: DOMNode) -> CGRect {
        if let rect = layoutRects[node.id] { return rect }
        guard node.nodeType == .element else { return .zero }
        let styles = node.attributes["style"].map { Self.parseInlineStyles($0) } ?? [:]
        func px(_ key: String) -> Double {
            var text = (styles[key] ?? node.attributes[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasSuffix("px") { text = String(text.dropLast(2)) }
            return Double(text) ?? 0
        }
        return CGRect(x: px("left"), y: px("top"), width: px("width"), height: px("height"))
    }

    /// The document element's client box is the viewport (when known); everyone
    /// else's is the border box for now (see clientWidth TODO).
    private func clientSize(of node: DOMNode) -> CGSize {
        if node.tagName == "html", viewportSize != .zero { return viewportSize }
        return resolvedLayoutRect(for: node).size
    }

    /// max(own rect size, extent of all laid-out descendants measured from the node's origin).
    private func scrollSize(of node: DOMNode) -> CGSize {
        if let cached = scrollSizeCache[node.id] { return cached }
        let own = resolvedLayoutRect(for: node)
        var maxX = own.maxX
        var maxY = own.maxY
        func walk(_ n: DOMNode) {
            for child in n.children {
                if let r = layoutRects[child.id] {
                    maxX = max(maxX, r.maxX)
                    maxY = max(maxY, r.maxY)
                }
                walk(child)
            }
        }
        walk(node)
        let size = CGSize(width: max(own.width, maxX - own.minX), height: max(own.height, maxY - own.minY))
        scrollSizeCache[node.id] = size
        return size
    }

    /// Lowercased inline `position` value, or nil when not declared inline.
    private func inlinePosition(of node: DOMNode) -> String? {
        guard let style = node.attributes["style"] else { return nil }
        return Self.parseInlineStyles(style)["position"]?.lowercased()
    }

    /// Nearest ancestor that has a layout rect and a non-static inline `position`,
    /// else `<body>`. `<html>`, `<body>`, fixed-position and detached nodes yield nil.
    private func offsetParent(of node: DOMNode) -> DOMNode? {
        guard node.nodeType == .element, let tag = node.tagName, tag != "html", tag != "body" else { return nil }
        if inlinePosition(of: node) == "fixed" { return nil }
        var cursor = node.parent
        while let current = cursor, current.nodeType == .element {
            if current.tagName == "body" { return current }
            if layoutRects[current.id] != nil, let pos = inlinePosition(of: current), pos != "static" {
                return current
            }
            cursor = current.parent
        }
        return nil
    }

    private func scrollPosition(of node: DOMNode) -> CGPoint {
        if node.tagName == "html" { return scrollOffset }
        return elementScrollPositions[node.id] ?? .zero
    }

    /// Stores the scroll position, then notifies the host through the mutation
    /// callback (so it can react on its next pass) and the optional scroll hook.
    private func setScrollPosition(_ pos: CGPoint, for node: DOMNode) {
        let clamped = CGPoint(x: max(0, pos.x), y: max(0, pos.y))
        if node.tagName == "html" {
            scrollOffset = clamped
        } else {
            elementScrollPositions[node.id] = clamped
        }
        notifyMutation(for: node)
        onScrollChange?(node, clamped)
    }

    /// Builds a DOMRect-shaped object in viewport coordinates (document rect minus scrollOffset).
    private func buildDOMRect(_ documentRect: CGRect, ctx: JeffJSContext) -> JeffJSValue {
        if domRectPrototype == nil {
            domRectPrototype = buildDOMRectPrototype(ctx: ctx)
        }
        let x = Double(documentRect.minX - scrollOffset.x)
        let y = Double(documentRect.minY - scrollOffset.y)
        let w = Double(documentRect.width)
        let h = Double(documentRect.height)
        let rect = ctx.newObjectProto(proto: domRectPrototype!)
        ctx.setPropertyStr(obj: rect, name: "x", value: .newFloat64(x))
        ctx.setPropertyStr(obj: rect, name: "y", value: .newFloat64(y))
        ctx.setPropertyStr(obj: rect, name: "width", value: .newFloat64(w))
        ctx.setPropertyStr(obj: rect, name: "height", value: .newFloat64(h))
        ctx.setPropertyStr(obj: rect, name: "top", value: .newFloat64(min(y, y + h)))
        ctx.setPropertyStr(obj: rect, name: "right", value: .newFloat64(max(x, x + w)))
        ctx.setPropertyStr(obj: rect, name: "bottom", value: .newFloat64(max(y, y + h)))
        ctx.setPropertyStr(obj: rect, name: "left", value: .newFloat64(min(x, x + w)))
        return rect
    }

    /// Shared DOMRect prototype carrying `toJSON()` (so JSON.stringify(rect) works).
    private func buildDOMRectPrototype(ctx: JeffJSContext) -> JeffJSValue {
        let proto = ctx.newObject()
        let toJSON = ctx.eval(input: """
        (function() { return { x: this.x, y: this.y, width: this.width, height: this.height,
                               top: this.top, right: this.right, bottom: this.bottom, left: this.left }; })
        """, filename: "<domrect-toJSON>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        if !toJSON.isException && toJSON.isFunction {
            ctx.setPropertyStr(obj: proto, name: "toJSON", value: toJSON)  // takes ownership
        } else {
            toJSON.freeValue()
        }
        return proto
    }

    // MARK: - Style Sub-Object (Shared Prototype)

    /// All standard CSS camelCase property names for CSSStyleDeclaration.
    private static let cssPropertyNames = "alignContent,alignItems,alignSelf,animation,animationDelay,animationDirection,animationDuration,animationFillMode,animationIterationCount,animationName,animationPlayState,animationTimingFunction,appearance,aspectRatio,backfaceVisibility,background,backgroundAttachment,backgroundBlendMode,backgroundClip,backgroundColor,backgroundImage,backgroundOrigin,backgroundPosition,backgroundRepeat,backgroundSize,border,borderBottom,borderBottomColor,borderBottomLeftRadius,borderBottomRightRadius,borderBottomStyle,borderBottomWidth,borderCollapse,borderColor,borderImage,borderLeft,borderLeftColor,borderLeftStyle,borderLeftWidth,borderRadius,borderRight,borderRightColor,borderRightStyle,borderRightWidth,borderSpacing,borderStyle,borderTop,borderTopColor,borderTopLeftRadius,borderTopRightRadius,borderTopStyle,borderTopWidth,borderWidth,bottom,boxShadow,boxSizing,clear,clip,clipPath,color,columnCount,columnGap,columnRule,columnRuleColor,columnRuleStyle,columnRuleWidth,columns,columnSpan,columnWidth,contain,content,counterIncrement,counterReset,cursor,direction,display,emptyCells,filter,flex,flexBasis,flexDirection,flexFlow,flexGrow,flexShrink,flexWrap,float,font,fontFamily,fontFeatureSettings,fontKerning,fontSize,fontSizeAdjust,fontStretch,fontStyle,fontVariant,fontVariantCaps,fontVariantLigatures,fontVariantNumeric,fontWeight,gap,grid,gridArea,gridAutoColumns,gridAutoFlow,gridAutoRows,gridColumn,gridColumnEnd,gridColumnGap,gridColumnStart,gridGap,gridRow,gridRowEnd,gridRowGap,gridRowStart,gridTemplate,gridTemplateAreas,gridTemplateColumns,gridTemplateRows,height,hyphens,imageRendering,inlineSize,isolation,justifyContent,justifyItems,justifySelf,left,letterSpacing,lineBreak,lineHeight,listStyle,listStyleImage,listStylePosition,listStyleType,margin,marginBlock,marginBlockEnd,marginBlockStart,marginBottom,marginInline,marginInlineEnd,marginInlineStart,marginLeft,marginRight,marginTop,maxBlockSize,maxHeight,maxInlineSize,maxWidth,minBlockSize,minHeight,minInlineSize,minWidth,mixBlendMode,objectFit,objectPosition,opacity,order,orphans,outline,outlineColor,outlineOffset,outlineStyle,outlineWidth,overflow,overflowAnchor,overflowWrap,overflowX,overflowY,padding,paddingBlock,paddingBlockEnd,paddingBlockStart,paddingBottom,paddingInline,paddingInlineEnd,paddingInlineStart,paddingLeft,paddingRight,paddingTop,pageBreakAfter,pageBreakBefore,pageBreakInside,perspective,perspectiveOrigin,placeContent,placeItems,placeSelf,pointerEvents,position,quotes,resize,right,rotate,rowGap,scale,scrollBehavior,scrollMargin,scrollPadding,scrollSnapAlign,scrollSnapType,shapeOutside,tabSize,tableLayout,textAlign,textAlignLast,textCombineUpright,textDecoration,textDecorationColor,textDecorationLine,textDecorationStyle,textIndent,textJustify,textOrientation,textOverflow,textShadow,textTransform,textUnderlinePosition,top,touchAction,transform,transformOrigin,transformStyle,transition,transitionDelay,transitionDuration,transitionProperty,transitionTimingFunction,translate,unicodeBidi,userSelect,verticalAlign,visibility,whiteSpace,widows,width,willChange,wordBreak,wordSpacing,wordWrap,writingMode,zIndex,WebkitAnimation,WebkitAnimationIterationCount,WebkitTransform,WebkitTransition,msAnimation,msTransform,MozAnimation,MozTransform"

    private static let numPxProps: Set<String> = [
        "width","height","top","left","right","bottom",
        "margin","marginTop","marginRight","marginBottom","marginLeft",
        "padding","paddingTop","paddingRight","paddingBottom","paddingLeft",
        "fontSize","borderWidth","borderRadius","maxWidth","maxHeight","minWidth","minHeight",
        "flexBasis","gap","rowGap","columnGap",
        "borderTopWidth","borderRightWidth","borderBottomWidth","borderLeftWidth",
        "outlineWidth","letterSpacing","wordSpacing","textIndent"
    ]

    /// Builds the shared style prototype once. All native methods use `thisVal`
    /// to extract the DOMNode from the style object's opaque payload, so one
    /// prototype serves every element — no per-element closures, evals, or
    /// defineProperty calls.
    private func buildStylePrototype(ctx: JeffJSContext) -> JeffJSValue {
        let proto = ctx.newObject()

        // -- Native methods (use thisVal to find node) --

        ctx.setPropertyFunc(obj: proto, name: "__get_cssText", fn: { [weak self] ctx, thisVal, _ in
            guard let node = self?.extractNode(from: thisVal) else { return ctx.newStringValue("") }
            return ctx.newStringValue(node.attributes["style"] ?? "")
        }, length: 0)

        ctx.setPropertyFunc(obj: proto, name: "__set_cssText", fn: { [weak self] ctx, thisVal, args in
            guard let self, let node = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            let value = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            node.setAttribute(name: "style", value: value)
            self.notifyMutation(for: node)
            return JeffJSValue.undefined
        }, length: 1)

        ctx.setPropertyFunc(obj: proto, name: "setProperty", fn: { [weak self] ctx, thisVal, args in
            guard let self, let node = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            guard let propName = self.extractString(ctx: ctx, args: args, index: 0) else {
                return JeffJSValue.undefined
            }
            let propValue = self.extractString(ctx: ctx, args: args, index: 1) ?? ""
            let priority = self.extractString(ctx: ctx, args: args, index: 2) ?? ""
            var styles = Self.parseInlineStyles(node.attributes["style"] ?? "")
            if propValue.isEmpty {
                styles.removeValue(forKey: propName)
            } else {
                styles[propName] = priority == "important" ? "\(propValue) !important" : propValue
            }
            node.setAttribute(name: "style", value: Self.serializeInlineStyles(styles))
            self.notifyMutation(for: node)
            return JeffJSValue.undefined
        }, length: 3)

        ctx.setPropertyFunc(obj: proto, name: "getPropertyValue", fn: { [weak self] ctx, thisVal, args in
            guard let self, let node = self.extractNode(from: thisVal) else { return ctx.newStringValue("") }
            guard let propName = self.extractString(ctx: ctx, args: args, index: 0) else {
                return ctx.newStringValue("")
            }
            let styles = Self.parseInlineStyles(node.attributes["style"] ?? "")
            return ctx.newStringValue(styles[propName] ?? "")
        }, length: 1)

        ctx.setPropertyFunc(obj: proto, name: "removeProperty", fn: { [weak self] ctx, thisVal, args in
            guard let self, let node = self.extractNode(from: thisVal) else { return ctx.newStringValue("") }
            guard let propName = self.extractString(ctx: ctx, args: args, index: 0) else {
                return ctx.newStringValue("")
            }
            var styles = Self.parseInlineStyles(node.attributes["style"] ?? "")
            let old = styles.removeValue(forKey: propName) ?? ""
            node.setAttribute(name: "style", value: Self.serializeInlineStyles(styles))
            self.notifyMutation(for: node)
            return ctx.newStringValue(old)
        }, length: 1)

        // -- Install cssText defineProperty on prototype (uses `this`) --
        let cssTextFn = ctx.eval(input: """
        (function(s) {
            Object.defineProperty(s, 'cssText', {
                configurable: true, enumerable: true,
                get: function() { return this.__get_cssText(); },
                set: function(v) { this.__set_cssText(v); }
            });
        })
        """, filename: "<style-proto-csstext>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        if !cssTextFn.isException && cssTextFn.isFunction {
            let r = ctx.call(cssTextFn, this: .undefined, args: [proto])
            r.freeValue()
        }
        cssTextFn.freeValue()

        // -- Install camelCase getter/setters on prototype (uses `this`) --
        // Each getter/setter calls this.getPropertyValue/this.setProperty which
        // resolves to the native functions above via prototype chain. The `this`
        // context is the per-element style instance, so the native functions
        // extract the correct DOMNode from its opaque payload.
        let camelToKebab = """
        (function(s, prop, isNumPx) {
            var kebab = prop.replace(/[A-Z]/g, function(m) { return '-' + m.toLowerCase(); });
            Object.defineProperty(s, prop, {
                configurable: true, enumerable: true,
                get: function() { return this.getPropertyValue(kebab) || ''; },
                set: function(value) {
                    var v = value == null || value === '' ? '' : String(value);
                    if (typeof value === 'number' && isNumPx) v = value + 'px';
                    this.setProperty(kebab, v);
                }
            });
        })
        """
        let definerFn = ctx.eval(input: camelToKebab, filename: "<style-proto-prop>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        if !definerFn.isException && definerFn.isFunction {
            for prop in Self.cssPropertyNames.split(separator: ",") {
                let propStr = String(prop)
                if propStr == "cssText" { continue }
                let propVal = ctx.newStringValue(propStr)
                let isNumPx = JeffJSValue.newBool(Self.numPxProps.contains(propStr))
                let r = ctx.call(definerFn, this: .undefined, args: [proto, propVal, isNumPx])
                r.freeValue()
                propVal.freeValue()
            }
        }
        definerFn.freeValue()

        return proto
    }

    /// Creates a lightweight style object for `node` by inheriting from the
    /// shared prototype. Cost: 1 newObjectProto + 1 payload set (vs ~467 ops before).
    private func buildStyleObject(for node: DOMNode, ctx: JeffJSContext) -> JeffJSValue {
        if stylePrototype == nil {
            stylePrototype = buildStylePrototype(ctx: ctx)
        }
        let obj = ctx.newObjectProto(proto: stylePrototype!)
        // Store DOMNode so prototype methods can extract it via thisVal
        if let jsObj = obj.toObject() {
            jsObj.payload = .opaque(node)
        }
        return obj
    }

    // MARK: - ClassList Sub-Object

    private func buildClassListObject(for node: DOMNode, ctx: JeffJSContext) -> JeffJSValue {
        buildTokenListObject(for: node, attribute: "class", ctx: ctx)
    }

    /// A `DOMTokenList` over any token-list attribute (`class` -> `classList`,
    /// `rel` -> `relList`, ...). Tokens split on ASCII whitespace per HTML, so
    /// `class="\n\tfoo\n\tbar"` is two tokens and empty runs are dropped.
    private func buildTokenListObject(for node: DOMNode, attribute: String, ctx: JeffJSContext) -> JeffJSValue {
        let obj = ctx.newObject()

        // Document order is significant (`className` round-trips through CSS and
        // through code that string-matches it), so the list keeps insertion order
        // instead of the alphabetical sort the first implementation used.
        func tokens() -> [String] {
            DOMNode.orderedTokenSet(node.attributes[attribute] ?? "")
        }
        func store(_ list: [String]) {
            node.setAttribute(name: attribute, value: list.joined(separator: " "))
        }

        // add(cls, ...)
        ctx.setPropertyFunc(obj: obj, name: "add", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            var list = tokens()
            for arg in args {
                if let cls = ctx.toSwiftString(arg), !cls.isEmpty, !list.contains(cls) {
                    list.append(cls)
                }
            }
            store(list)
            self.notifyMutation(for: node)
            return JeffJSValue.undefined
        }, length: 1)

        // remove(cls, ...)
        ctx.setPropertyFunc(obj: obj, name: "remove", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            var list = tokens()
            for arg in args {
                if let cls = ctx.toSwiftString(arg) {
                    list.removeAll { $0 == cls }
                }
            }
            store(list)
            self.notifyMutation(for: node)
            return JeffJSValue.undefined
        }, length: 1)

        // toggle(cls, force?) -> bool
        ctx.setPropertyFunc(obj: obj, name: "toggle", fn: { [weak self] ctx, _, args in
            guard let self, let cls = self.extractString(ctx: ctx, args: args, index: 0), !cls.isEmpty else {
                return .newBool(false)
            }
            var list = tokens()
            let hasForce = args.count >= 2 && !args[1].isUndefined
            let shouldAdd = hasForce ? args[1].toBool() : !list.contains(cls)
            if shouldAdd {
                if !list.contains(cls) { list.append(cls) }
            } else {
                list.removeAll { $0 == cls }
            }
            store(list)
            self.notifyMutation(for: node)
            return .newBool(shouldAdd)
        }, length: 1)

        // contains(cls) -> bool
        ctx.setPropertyFunc(obj: obj, name: "contains", fn: { ctx, _, args in
            guard let cls = ctx.toSwiftString(args.first ?? .undefined) else { return .newBool(false) }
            return .newBool(tokens().contains(cls))
        }, length: 1)

        // replace(oldCls, newCls) -> bool
        ctx.setPropertyFunc(obj: obj, name: "replace", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 2,
                  let oldCls = ctx.toSwiftString(args[0]),
                  let newCls = ctx.toSwiftString(args[1]) else {
                return .newBool(false)
            }
            var list = tokens()
            guard let idx = list.firstIndex(of: oldCls) else { return .newBool(false) }
            if list.contains(newCls) {
                list.remove(at: idx)
            } else {
                list[idx] = newCls
            }
            store(list)
            self.notifyMutation(for: node)
            return .newBool(true)
        }, length: 2)

        // item(index) -> string | null
        ctx.setPropertyFunc(obj: obj, name: "item", fn: { ctx, _, args in
            let list = tokens()
            guard let raw = args.first, let idx = ctx.toInt32(raw), idx >= 0, Int(idx) < list.count else {
                return JeffJSValue.null
            }
            return ctx.newStringValue(list[Int(idx)])
        }, length: 1)

        ctx.setPropertyFunc(obj: obj, name: "toString", fn: { ctx, _, _ in
            ctx.newStringValue(node.attributes[attribute] ?? "")
        }, length: 0)

        // forEach(callback, thisArg)
        ctx.setPropertyFunc(obj: obj, name: "forEach", fn: { ctx, thisVal, args in
            guard let callback = args.first, callback.isObject else { return JeffJSValue.undefined }
            let thisArg = args.count > 1 ? args[1] : JeffJSValue.undefined
            for (i, token) in tokens().enumerated() {
                let r = ctx.call(callback, this: thisArg, args: [
                    ctx.newStringValue(token), .newInt32(Int32(i)), thisVal.dupValue()
                ])
                r.freeValue()
            }
            return JeffJSValue.undefined
        }, length: 1)

        // Iterable: values()/keys()/entries()/[Symbol.iterator]
        func tokenArray() -> JeffJSValue {
            let arr = ctx.newArray()
            for (i, token) in tokens().enumerated() {
                _ = ctx.setPropertyUint32(obj: arr, index: UInt32(i), value: ctx.newStringValue(token))
            }
            return arr
        }
        ctx.setPropertyFunc(obj: obj, name: "values", fn: { ctx, _, _ in
            ctx.createArrayIterator(obj: tokenArray(), kind: 1)
        }, length: 0)
        ctx.setPropertyFunc(obj: obj, name: "keys", fn: { ctx, _, _ in
            ctx.createArrayIterator(obj: tokenArray(), kind: 0)
        }, length: 0)
        ctx.setPropertyFunc(obj: obj, name: "entries", fn: { ctx, _, _ in
            ctx.createArrayIterator(obj: tokenArray(), kind: 2)
        }, length: 0)
        let iterFn = ctx.newCFunction({ ctx, _, _ in
            ctx.createArrayIterator(obj: tokenArray(), kind: 1)
        }, name: "[Symbol.iterator]", length: 0)
        _ = ctx.setProperty(obj: obj, atom: JeffJSAtomID.JS_ATOM_Symbol_iterator.rawValue, value: iterFn)

        // supports(token) — DOMTokenList.supports; only defined for attributes
        // with a known token set, which we do not model, so report true.
        ctx.setPropertyFunc(obj: obj, name: "supports", fn: { _, _, _ in
            .newBool(true)
        }, length: 1)

        // `length` and `value` are live accessors — the list object is cached per
        // element, so a snapshot taken at build time would go stale on the first
        // add()/remove().
        let lengthGetter = ctx.newCFunction({ _, _, _ in .newInt32(Int32(tokens().count)) },
                                            name: "get length", length: 0)
        ctx.setPropertyGetSet(obj: obj, name: "length", getter: lengthGetter, setter: nil)

        let valueGetter = ctx.newCFunction({ ctx, _, _ in
            ctx.newStringValue(node.attributes[attribute] ?? "")
        }, name: "get value", length: 0)
        let valueSetter = ctx.newCFunction({ [weak self] ctx, _, args in
            guard let self, let v = ctx.toSwiftString(args.first ?? .undefined) else { return .undefined }
            node.setAttribute(name: attribute, value: v)
            self.notifyMutation(for: node)
            return .undefined
        }, name: "set value", length: 1)
        ctx.setPropertyGetSet(obj: obj, name: "value", getter: valueGetter, setter: valueSetter)

        for (i, cls) in tokens().enumerated() {
            ctx.setPropertyUint32(obj: obj, index: UInt32(i), value: ctx.newStringValue(cls))
        }

        return obj
    }

    /// The content fragment backing a `<template>` element. Created on first use;
    /// any children the HTML parser left directly on the template are migrated in,
    /// matching the spec where template markup never becomes element children.
    private func templateFragment(for node: DOMNode) -> DOMNode {
        if let existing = templateContent[node.id] {
            for child in node.children { existing.appendChild(child) }
            if !node.children.isEmpty { node.clearChildren() }
            return existing
        }
        let fragment = DOMNode.documentFragment()
        for child in node.children { fragment.appendChild(child) }
        node.clearChildren()
        templateContent[node.id] = fragment
        return fragment
    }

    // MARK: - Update ReadyState

    /// Updates the document.readyState property on the context.
    func setReadyState(_ value: String, on doc: JeffJSValue, ctx: JeffJSContext) {
        ctx.setPropertyStr(obj: doc, name: "readyState", value: ctx.newStringValue(value))
    }

    // MARK: - Helpers

    /// Extracts a DOMNode from a JeffJS value via its opaque payload.
    func extractNode(from val: JeffJSValue) -> DOMNode? {
        guard val.isObject else { return nil }
        // Primary: check opaque payload
        if let obj = val.toObject(), case .opaque(let any) = obj.payload, let node = any as? DOMNode {
            return node
        }
        return nil
    }

    /// Variant that uses a JeffJSContext to read the nativeNodeID property as fallback.
    func extractNode(from val: JeffJSValue, ctx: JeffJSContext) -> DOMNode? {
        if let node = extractNode(from: val) { return node }
        // Fallback: read nativeNodeID via context API
        let idVal = ctx.getPropertyStr(obj: val, name: "nativeNodeID")
        defer { idVal.freeValue() }
        if let idStr = ctx.toSwiftString(idVal), let uuid = UUID(uuidString: idStr) {
            return nodeRegistry[uuid]
        }
        return nil
    }

    /// Extracts a Swift string from args at the given index.
    private func extractString(ctx: JeffJSContext, args: [JeffJSValue], index: Int) -> String? {
        guard index < args.count else { return nil }
        let val = args[index]
        if val.isUndefined || val.isNull { return nil }
        return ctx.toSwiftString(val)
    }

    /// Notifies the mutation observer of a change to the given node.
    private func notifyMutation(for node: DOMNode) {
        onMutated?([node.id])
        if node.tagName == "script", node.parent != nil {
            onScriptExecution?(node)
        }
    }

    /// Finds the first element node matching a predicate (DFS).
    private func findElement(in node: DOMNode, where predicate: (DOMNode) -> Bool) -> DOMNode? {
        if node.nodeType == .element && predicate(node) { return node }
        for child in node.children {
            if let found = findElement(in: child, where: predicate) {
                return found
            }
        }
        return nil
    }

    /// Returns all element descendants of a node (DFS, pre-order).
    private func allElementDescendants(of node: DOMNode) -> [DOMNode] {
        var result: [DOMNode] = []
        func traverse(_ n: DOMNode) {
            for child in n.children {
                if child.nodeType == .element { result.append(child) }
                traverse(child)
            }
        }
        traverse(node)
        return result
    }

    /// Checks if a node is connected to the root document.
    private func isConnected(_ node: DOMNode) -> Bool {
        var current: DOMNode? = node
        while let c = current {
            if c === root { return true }
            current = c.parent
        }
        return false
    }

    /// Returns the next sibling of a node in its parent's children.
    private func nextSibling(of node: DOMNode) -> DOMNode? {
        guard let parent = node.parent else { return nil }
        let siblings = parent.children
        guard let idx = siblings.firstIndex(where: { $0 === node }) else { return nil }
        let nextIdx = siblings.index(after: idx)
        return nextIdx < siblings.endIndex ? siblings[nextIdx] : nil
    }

    /// Returns the previous sibling of a node in its parent's children.
    private func previousSibling(of node: DOMNode) -> DOMNode? {
        guard let parent = node.parent else { return nil }
        let siblings = parent.children
        guard let idx = siblings.firstIndex(where: { $0 === node }), idx > siblings.startIndex else { return nil }
        return siblings[siblings.index(before: idx)]
    }

    /// Returns the next element sibling.
    private func nextElementSibling(of node: DOMNode) -> DOMNode? {
        guard let parent = node.parent else { return nil }
        let siblings = parent.children
        guard let idx = siblings.firstIndex(where: { $0 === node }) else { return nil }
        var i = siblings.index(after: idx)
        while i < siblings.endIndex {
            if siblings[i].nodeType == .element { return siblings[i] }
            i = siblings.index(after: i)
        }
        return nil
    }

    /// Returns the previous element sibling.
    private func previousElementSibling(of node: DOMNode) -> DOMNode? {
        guard let parent = node.parent else { return nil }
        let siblings = parent.children
        guard let idx = siblings.firstIndex(where: { $0 === node }), idx > siblings.startIndex else { return nil }
        var i = siblings.index(before: idx)
        while i >= siblings.startIndex {
            if siblings[i].nodeType == .element { return siblings[i] }
            if i == siblings.startIndex { break }
            i = siblings.index(before: i)
        }
        return nil
    }

    /// Checks if `parent` contains `child` anywhere in its subtree.
    /// Shared implementation for `insertAdjacentElement/Text/HTML`.
    /// Returns false for an unknown position or when the node has no parent and
    /// the position requires one.
    @discardableResult
    private func insertAdjacent(position: String, target: DOMNode, nodes: [DOMNode]) -> Bool {
        guard !nodes.isEmpty else { return true }
        for node in nodes where node.parent != nil {
            node.parent?.removeChild(node)
        }
        switch position.lowercased() {
        case "beforebegin":
            guard let parent = target.parent else { return false }
            for node in nodes { parent.insertChild(node, before: target) }
            notifyMutation(for: parent)
        case "afterbegin":
            if let first = target.children.first {
                for node in nodes { target.insertChild(node, before: first) }
            } else {
                for node in nodes { target.appendChild(node) }
            }
            notifyMutation(for: target)
        case "beforeend":
            for node in nodes { target.appendChild(node) }
            notifyMutation(for: target)
        case "afterend":
            guard let parent = target.parent else { return false }
            if let next = nextSibling(of: target) {
                for node in nodes { parent.insertChild(node, before: next) }
            } else {
                for node in nodes { parent.appendChild(node) }
            }
            notifyMutation(for: parent)
        default:
            return false
        }
        return true
    }

    /// `Node.compareDocumentPosition` bitmask for `a` compared with `b`.
    private func documentPosition(of a: DOMNode, relativeTo b: DOMNode) -> Int32 {
        if a === b { return 0 }
        if nodeContains(a, child: b) { return 0x14 }   // CONTAINED_BY | FOLLOWING
        if nodeContains(b, child: a) { return 0x0A }   // CONTAINS | PRECEDING
        // Walk the shared tree in document order to decide precedes/follows.
        var rootA = a
        while let p = rootA.parent { rootA = p }
        var rootB = b
        while let p = rootB.parent { rootB = p }
        guard rootA === rootB else { return 0x21 }     // DISCONNECTED | IMPLEMENTATION_SPECIFIC
        var found: Int32 = 0
        func walk(_ n: DOMNode) {
            if found != 0 { return }
            if n === a { found = 4; return }           // a first -> b FOLLOWING a
            if n === b { found = 2; return }           // b first -> b PRECEDING a
            for child in n.children {
                walk(child)
                if found != 0 { return }
            }
        }
        walk(rootA)
        return found == 0 ? 0x21 : found
    }

    private func nodeContains(_ parent: DOMNode, child: DOMNode) -> Bool {
        if parent === child { return true }
        for c in parent.children {
            if nodeContains(c, child: child) { return true }
        }
        return false
    }

    /// Deep or shallow clone of a DOMNode.
    private func cloneDOMNode(_ node: DOMNode, deep: Bool) -> DOMNode {
        switch node.nodeType {
        case .element:
            let cloned = DOMNode.element(tag: node.tagName ?? "div", attributes: node.attributes)
            if deep {
                for child in node.children {
                    cloned.appendChild(cloneDOMNode(child, deep: true))
                }
            }
            return cloned
        case .text:
            return DOMNode.text(node.textContent ?? "")
        case .comment:
            return DOMNode.comment(node.textContent ?? "")
        case .documentFragment:
            let frag = DOMNode.documentFragment()
            if deep {
                for child in node.children {
                    frag.appendChild(cloneDOMNode(child, deep: true))
                }
            }
            return frag
        case .document:
            return DOMNode.document()
        }
    }

    /// Extracts the <title> text from the DOM tree.
    private func extractTitle() -> String {
        guard let titleNode = findElement(in: root, where: { $0.tagName == "title" }) else { return "" }
        return titleNode.rawTextDescendants
    }

    /// Returns the numeric nodeType for a DOMNode.
    private func nodeTypeInt(_ node: DOMNode) -> Int32 {
        switch node.nodeType {
        case .element: return 1
        case .text: return 3
        case .comment: return 8
        case .document: return 9
        case .documentFragment: return 11
        }
    }

    /// Returns the nodeName string for a DOMNode.
    private func nodeNameStr(_ node: DOMNode) -> String {
        switch node.nodeType {
        case .element: return (node.tagName ?? "").uppercased()
        case .text: return "#text"
        case .comment: return "#comment"
        case .document: return "#document"
        case .documentFragment: return "#document-fragment"
        }
    }

    // MARK: - HTML Serialization / Parsing

    private static func serializeHTML(_ node: DOMNode) -> String {
        switch node.nodeType {
        case .text:
            return escapeText(node.textContent ?? "")
        case .comment:
            return "<!--\(node.textContent ?? "")-->"
        case .document, .documentFragment:
            return node.children.map(serializeHTML).joined()
        case .element:
            guard let tag = node.tagName else { return "" }
            var html = "<\(tag)"
            for (key, val) in node.attributes.sorted(by: { $0.key < $1.key }) {
                html += " \(key)=\"\(escapeAttribute(val))\""
            }
            let voidTags: Set<String> = [
                "area", "base", "br", "col", "embed", "hr", "img",
                "input", "link", "meta", "param", "source", "track", "wbr"
            ]
            if voidTags.contains(tag.lowercased()) {
                return html + ">"
            }
            html += ">"
            html += node.children.map(serializeHTML).joined()
            html += "</\(tag)>"
            return html
        }
    }

    private static func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func parseHTMLFragment(_ html: String) -> [DOMNode] {
        let wrapped = "<html><body>\(html)</body></html>"
        let doc = HTMLParser.parse(wrapped)
        guard let body = doc.querySelector("body") else {
            return doc.children
        }
        return body.children
    }

    // MARK: - Inline Style Helpers

    private static func parseInlineStyles(_ style: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in style.split(separator: ";") {
            let kv = part.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]).trimmingCharacters(in: .whitespaces)
            let val = String(kv[1]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = val }
        }
        return result
    }

    private static func serializeInlineStyles(_ styles: [String: String]) -> String {
        styles.sorted(by: { $0.key < $1.key })
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "; ")
    }
}
