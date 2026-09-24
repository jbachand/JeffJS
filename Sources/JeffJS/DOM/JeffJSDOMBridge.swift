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
    /// Host script runner: called once per script-inserted `<script>` element
    /// the page made ready to run, with that element, already marked
    /// `scriptAlreadyStarted` (HTML §4.12.1.1). Inline classic scripts must be
    /// executed before the callback returns. Full contract at the top of
    /// `JeffJSDOMBridge+Scripts.swift`.
    let onScriptExecution: ((DOMNode) -> Void)?

    /// Called when a JS event listener throws an exception.
    var onError: ((String) -> Void)?

    /// Cache of wrapped JS element objects keyed by DOMNode UUID.
    /// Ensures identity: the same DOMNode always maps to the same JS object.
    var elementCache: [UUID: JeffJSValue] = [:]

    /// Registry of all DOMNodes that have been wrapped, keyed by UUID.
    /// Used by extractNode fallback when opaque payload is unavailable.
    var nodeRegistry: [UUID: DOMNode] = [:]

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

    /// The engine's EventTarget implementation. `document` and the element
    /// prototype chain to its `EventTarget.prototype`, so window, document and
    /// every node share one addEventListener/removeEventListener/dispatchEvent
    /// and one capture/at-target/bubble dispatch. Set before `register(on:)`.
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
    var elementScrollPositions: [UUID: CGPoint] = [:]

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
    var classListCache: [UUID: JeffJSValue] = [:]

    /// Per-node `relList` wrappers, keyed by `DOMNode.id`. Same lifetime rules
    /// as `classListCache`.
    var relListCache: [UUID: JeffJSValue] = [:]

    /// Detached documents handed out by `document.implementation.createHTMLDocument`
    /// and `DOMParser.parseFromString`, keyed by their root `DOMNode.id`.
    /// Non-empty only on pages that ask for one, so the `ownerDocument` walk in
    /// `wrapElement` stays free for everything else.
    var detachedDocuments: [UUID: JeffJSValue] = [:]
    var detachedDocumentRoots: [DOMNode] = []

    /// `<template>` content fragments, keyed by the template element's id.
    var templateContent: [UUID: DOMNode] = [:]

    /// `<textarea>` elements whose `value` script has set (the dirty value
    /// flag): from then on `value` no longer follows the child text.
    var dirtyTextareas: Set<UUID> = []

    /// The `<script>` element currently being evaluated (`document.currentScript`).
    var currentScriptNode: DOMNode?

    /// Shared `item`/`namedItem` implementations spliced onto every array
    /// returned by `wrapElementArray` (HTMLCollection/NodeList shape).
    private var nodeListItemFn: JeffJSValue?
    private var nodeListNamedItemFn: JeffJSValue?

    /// The context this bridge registered on (for mutation records, queued
    /// tasks and events built outside a native call's own `ctx`).
    private(set) weak var jsContext: JeffJSContext?

    // MARK: Node lifetimes (JeffJSDOMBridge+Interaction.swift)

    /// Nodes that left a tree, or were wrapped while detached. A node's
    /// wrapper and listeners belong to the node (DOM §2.7): removal keeps
    /// them, and they are dropped only when the whole detached subtree is
    /// unreachable from script (`collectDetachedNodes`).
    var detachedCandidates: [DOMNode] = []
    var detachedCandidateIDs: Set<UUID> = []
    var detachedSweepThreshold = 64

    // MARK: dataset / MutationObserver / focus / click / tasks

    /// Per-node `dataset` proxies (owned), keyed like the element cache.
    var datasetCache: [UUID: JeffJSValue] = [:]
    /// `function (target) -> Proxy` built by the dataset shim (owned).
    var datasetFactory: JeffJSValue?

    var moObservers: [Int: JeffJSMutationObserverEntry] = [:]
    var moRegistrations: [UUID: [JeffJSMutationRegistration]] = [:]
    var moDeliveryScheduled = false

    /// The focused element (HTML "focused area"); nil = the viewport/body.
    weak var focusedElement: DOMNode?
    /// Script moved focus (`el.focus()`, `el.blur()`, autofocus, a focused
    /// node's removal is silent): `(newFocus, oldFocus)`. The host moves its
    /// first responder to match. Not called for host-initiated changes
    /// (`hostFocusChanged(to:ctx:)` / `__nativeEventBridge.focus`).
    var onFocusChange: ((_ newFocus: DOMNode?, _ oldFocus: DOMNode?) -> Void)?
    /// Activation behaviour the DOM cannot perform itself, run after an
    /// uncanceled `click()`: kind "hyperlink" (`a`/`area` with `href`),
    /// "submit" / "reset" (when the form has no `requestSubmit` / `reset`).
    /// Return true when handled. Falls back to the JS function
    /// `window.__nativeActivationBehavior(element, kind)` when nil.
    var onActivationBehavior: ((_ element: DOMNode, _ kind: String) -> Bool)?
    /// Computed style for layout-dependent DOM getters (`innerText`,
    /// focusability): the resolved value of a CSS property, or nil when
    /// unknown. Without it the bridge asks the host's
    /// `__nativeGetComputedStyleValue(nodeID, property)`, then the inline
    /// style and the UA defaults.
    var computedStyleProvider: ((_ node: DOMNode, _ property: String) -> String?)?

    /// Host hook for the page-visible content attribute of a form control
    /// whose `attributes` slot holds its *state* (value / checked /
    /// selected): return `.some(content)` (`nil` = absent) to override,
    /// `.none` when `attributes[name]` is the content attribute. Consulted
    /// by getAttribute, hasAttribute, getAttributeNames, hasAttributes,
    /// toggleAttribute and the HTML serializer (innerHTML/outerHTML), only
    /// for the names in `contentAttributeOverrideNames`.
    var contentAttributeOverride: ((_ node: DOMNode, _ name: String) -> String??)?

    var clickInProgress: Set<UUID> = []
    /// Details elements with a queued `toggle` task -> the old `open` state.
    var pendingDetailsToggles: [UUID: Bool] = [:]
    /// Queued tasks (HTML "queue a task"), run from one `setTimeout(…, 0)`.
    var pendingTasks: [() -> Void] = []
    var taskScheduled = false
    var taskRunnerFn: JeffJSValue?
    /// The inert documents holding `<template>` contents, per owner document.
    var inertDocuments: [UUID: DOMNode] = [:]

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
        dirtyTextareas.removeAll()
        currentScriptNode = nil
        nodeListItemFn?.freeValue(); nodeListItemFn = nil
        nodeListNamedItemFn?.freeValue(); nodeListNamedItemFn = nil

        for (_, v) in datasetCache { v.freeValue() }
        datasetCache.removeAll()
        datasetFactory?.freeValue(); datasetFactory = nil
        for (_, entry) in moObservers { entry.release() }
        moObservers.removeAll()
        moRegistrations.removeAll()
        moDeliveryScheduled = false
        focusedElement = nil
        clickInProgress.removeAll()
        pendingDetailsToggles.removeAll()
        pendingTasks.removeAll()
        taskScheduled = false
        taskRunnerFn?.freeValue(); taskRunnerFn = nil
        inertDocuments.removeAll()
        detachedCandidates.removeAll()
        detachedCandidateIDs.removeAll()

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

    /// Drops the event listeners, wrapper and caches of one node that script
    /// can no longer reach (see `collectDetachedNodes`). Removal from the
    /// tree does NOT call this: listeners belong to the node (DOM §2.7).
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
        if let ds = datasetCache.removeValue(forKey: nodeID) { ds.freeValue() }
        dirtyTextareas.remove(nodeID)
        pendingDetailsToggles.removeValue(forKey: nodeID)
        if moRegistrations.removeValue(forKey: nodeID) != nil { pruneIdleMutationObservers() }
    }

    // MARK: - document.currentScript

    /// Records the `<script>` element being evaluated so `document.currentScript`
    /// reports it (AdSense and most tag loaders read it to find their own tag).
    /// Pass `nil` when evaluation finishes.
    func setCurrentScriptNode(_ node: DOMNode?) {
        currentScriptNode = node
    }

    /// Elements whose `src` IDL attribute reflects as a URL.
    static let urlSrcTags: Set<String> = ["script", "img", "iframe", "frame", "embed", "audio", "video", "source", "track", "input"]

    // MARK: - Registration Entry Point

    /// Registers `document` and `window` objects on the JeffJS context's global scope.
    func register(on ctx: JeffJSContext) {
        jsContext = ctx
        // The scripts already in the document were parser-inserted and are
        // the host's to run: moving one later must not run it again. Only the
        // ones the parser's own "prepare" would have started (§4.12.1.1: an
        // empty or non-JavaScript one stays startable, e.g. a consent
        // manager's `type="text/plain"` script cloned with a real type).
        Self.markScriptsAlreadyStarted(in: [root], onlyIfWouldStart: true)
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

        // on* handlers on window (GlobalEventHandlers + WindowEventHandlers)
        // and document; `'ontouchstart' in window` is true as on iOS.
        installEventHandlerAccessors(on: global, names: Self.elementEventHandlerNames + Self.windowEventHandlerNames, ctx: ctx)
        if let docValue = documentJSValue { installEventHandlerAccessors(on: docValue, names: Self.elementEventHandlerNames + ["onreadystatechange", "onvisibilitychange", "onpointerlockchange", "onpointerlockerror", "onfullscreenchange", "onfullscreenerror", "onselectionchange"], ctx: ctx) }

        // CSS.escape (CSSOM §2.1).
        installCSSNamespace(on: global, ctx: ctx)

        // MutationObserver (DOM §4.3), native: replaces any stub installed
        // earlier; host polyfills test `typeof MutationObserver` and skip.
        installMutationObserver(on: global, ctx: ctx)

        global.freeValue()
    }

    // MARK: - Document Object

    private func buildDocumentObject(ctx: JeffJSContext) -> JeffJSValue {
        // Document is an EventTarget: chain to EventTarget.prototype so it
        // shares addEventListener/removeEventListener/dispatchEvent with window
        // and every element.
        let doc = eventBridge?.eventTargetPrototype.map { ctx.newObjectProto(proto: $0) } ?? ctx.newObject()

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
        // The real value the parser decided from the DOCTYPE, not a guess made
        // by re-scanning the source text.
        ctx.setPropertyStr(obj: doc, name: "compatMode", value: ctx.newStringValue(root.compatMode))
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
        registerContextualFragment(on: doc, ctx: ctx)
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
            let raw = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
            let nodes = self.allElementDescendants(of: self.root).filter {
                normalized == "*" || $0.tagName == ($0.isHTMLNamespace ? normalized : raw)
            }
            return self.wrapElementArray(nodes, ctx: ctx)
        }, length: 1)

        // createElement
        ctx.setPropertyFunc(obj: doc, name: "createElement", fn: { [weak self] ctx, thisVal, args in
            guard let self, let tag = self.extractString(ctx: ctx, args: args, index: 0) else {
                return JeffJSValue.null
            }
            self.maybeCollectDetachedNodes()
            let node = DOMNode.element(tag: tag)
            return self.wrapElement(node, ctx: ctx)
        }, length: 1)

        // createElementNS(namespace, qualifiedName, options?) — DOM §4.5: the
        // element carries the namespace and its local name keeps its case, so
        // `createElementNS(svgNS, 'linearGradient')` is an SVG element and an
        // SVG context element fragment-parses as foreign content.
        ctx.setPropertyFunc(obj: doc, name: "createElementNS", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.null }
            self.maybeCollectDetachedNodes()
            guard let node = Self.makeElementNS(ctx: ctx, args: args) else { return JeffJSValue.null }
            return self.wrapElement(node, ctx: ctx)
        }, length: 2)

        // createTextNode
        ctx.setPropertyFunc(obj: doc, name: "createTextNode", fn: { [weak self] ctx, thisVal, args in
            guard let self, let text = self.extractString(ctx: ctx, args: args, index: 0) else {
                return JeffJSValue.null
            }
            self.maybeCollectDetachedNodes()
            let node = DOMNode.text(text)
            return self.wrapElement(node, ctx: ctx)
        }, length: 1)

        // createDocumentFragment
        ctx.setPropertyFunc(obj: doc, name: "createDocumentFragment", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.null }
            self.maybeCollectDetachedNodes()
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

        // addEventListener / removeEventListener / dispatchEvent are inherited
        // from EventTarget.prototype (see buildDocumentObject).

        // contains(node) -> bool (jQuery.contains and focus-trap libraries call it)
        ctx.setPropertyFunc(obj: doc, name: "contains", fn: { [weak self] ctx, _, args in
            guard let self, !args.isEmpty, let other = self.extractNode(from: args[0]) else {
                return .newBool(false)
            }
            return .newBool(self.nodeContains(self.root, child: other) || other === self.root)
        }, length: 1)

        // importNode(node, deep) / adoptNode(node) — DOM §4.5: the clone /
        // the adopted node (removed from its old parent) belongs to this document.
        ctx.setPropertyFunc(obj: doc, name: "importNode", fn: { [weak self] ctx, _, args in
            guard let self, !args.isEmpty, let node = self.extractNode(from: args[0]) else {
                return JeffJSValue.null
            }
            if node.nodeType == .document {
                return self.throwDOMException(ctx: ctx, name: "NotSupportedError",
                                              message: "Failed to execute 'importNode' on 'Document': The node provided is a document, which may not be imported.")
            }
            let deep = args.count > 1 && args[1].toBool()
            let clone = self.cloneDOMNode(node, deep: deep)
            clone.nodeDocument = nil
            return self.wrapElement(clone, ctx: ctx)
        }, length: 2)

        ctx.setPropertyFunc(obj: doc, name: "adoptNode", fn: { [weak self] ctx, _, args in
            guard let self, !args.isEmpty, let node = self.extractNode(from: args[0]) else {
                return JeffJSValue.null
            }
            if node.nodeType == .document {
                return self.throwDOMException(ctx: ctx, name: "NotSupportedError",
                                              message: "Failed to execute 'adoptNode' on 'Document': The node provided is a document, which may not be adopted.")
            }
            self.adopt(node, into: self.root)
            return args[0].dupValue()
        }, length: 1)

        // document.activeElement (HTML §6.6.4): the focused element, else the
        // body, else the document element.
        let activeGetter = ctx.newCFunction({ [weak self] ctx, _, _ in
            guard let self, let node = self.activeElement() else { return JeffJSValue.null }
            return self.wrapElement(node, ctx: ctx)
        }, name: "get activeElement", length: 0)
        ctx.setPropertyGetSet(obj: doc, name: "activeElement", getter: activeGetter, setter: nil)

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

        // document.doctype — the DocumentType node the parser created (null
        // for a page without a DOCTYPE, i.e. a quirks-mode page).
        let doctypeGetter = ctx.newCFunction({ [weak self] ctx, _, _ in
            guard let self, let node = self.root.doctype else { return JeffJSValue.null }
            return self.wrapElement(node, ctx: ctx)
        }, name: "get doctype", length: 0)
        ctx.setPropertyGetSet(obj: doc, name: "doctype", getter: doctypeGetter, setter: nil)

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
            // DOM §4.5.1: the title element exists only when a title is given.
            let title: String? = (args.isEmpty || args[0].isUndefined) ? nil : (ctx.toSwiftString(args[0]) ?? "")
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

    /// DOM §4.5.1 `createHTMLDocument(title)`: `<!DOCTYPE html>`, then
    /// `html > head (> title > text) + body`, in no-quirks mode. The title
    /// element (holding a Text node, even an empty one) only when a title is given.
    private func makeDetachedDocument(title: String?) -> DOMNode {
        let docNode = DOMNode.document()
        docNode.appendChild(DOMNode.documentType(name: "html"))
        let html = DOMNode.element(tag: "html")
        let head = DOMNode.element(tag: "head")
        if let title {
            let titleNode = DOMNode.element(tag: "title")
            titleNode.appendChild(DOMNode.text(title))
            head.appendChild(titleNode)
        }
        html.appendChild(head)
        html.appendChild(DOMNode.element(tag: "body"))
        docNode.appendChild(html)
        return docNode
    }

    /// Parses `html` into a detached `Document`, for `DOMParser.parseFromString`.
    /// DOM Parsing §2: the document has no browsing context, so it is parsed
    /// with scripting DISABLED (`<noscript>` content becomes elements), and its
    /// mode (`compatMode`) is whatever its own DOCTYPE decided.
    func parseDetachedDocument(html: String, ctx: JeffJSContext) -> JeffJSValue {
        // DOMParser / parseHTMLUnsafe documents: their scripts never run,
        // not even once adopted into the page (HTML §8.5.1).
        let doc = HTMLParser.parse(html, scriptingEnabled: false)
        Self.markScriptsAlreadyStarted(in: [doc])
        return wrapDetachedDocument(doc, ctx: ctx)
    }

    /// `createElementNS(namespace, qualifiedName)` arguments -> an element.
    /// `nil` on a DOMNode means the HTML namespace; "" is the null namespace.
    static func makeElementNS(ctx: JeffJSContext, args: [JeffJSValue]) -> DOMNode? {
        guard args.count >= 2 else {
            // Lenient: a lone argument is a tag name (old callers passed one).
            guard let tag = args.first.flatMap({ ctx.toSwiftString($0) }) else { return nil }
            return DOMNode.element(tag: tag)
        }
        let rawNS: String? = (args[0].isNull || args[0].isUndefined) ? nil : ctx.toSwiftString(args[0])
        guard let qualified = ctx.toSwiftString(args[1]) else { return nil }
        let local: String
        if let colon = qualified.lastIndex(of: ":") {
            local = String(qualified[qualified.index(after: colon)...])
        } else {
            local = qualified
        }
        let namespace: String?
        switch rawNS {
        case nil, "": namespace = ""
        case DOMNode.htmlNamespace: namespace = nil
        default: namespace = rawNS
        }
        return DOMNode.element(tag: local, preserveCase: true, namespace: namespace)
    }

    /// Wraps a detached document root as a Document-shaped JS object: the element
    /// wrapper already supplies querySelector/getElementsByTagName/appendChild
    /// scoped to this subtree, so only the Document-only surface is added here.
    func wrapDetachedDocument(_ docNode: DOMNode, ctx: JeffJSContext) -> JeffJSValue {
        if let cached = detachedDocuments[docNode.id] { return cached.dupValue() }

        detachedDocumentRoots.append(docNode)
        let wrapper = wrapElement(docNode, ctx: ctx)
        detachedDocuments[docNode.id] = wrapper.dupValue()

        // Document.ownerDocument is null (the prototype's accessor answers
        // that for a document node); defaultView is null for a document that
        // has no browsing context.
        ctx.setPropertyStr(obj: wrapper, name: "defaultView", value: .null)
        // The mode the parser decided from this document's own DOCTYPE
        // (quirks without one), not the page's.
        ctx.setPropertyStr(obj: wrapper, name: "compatMode", value: ctx.newStringValue(docNode.compatMode))
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
            ("body", { tag("body") ?? tag("frameset") }),
            ("doctype", { docNode.doctype }),
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

        // Factory methods create nodes owned by *this* document (their node
        // document, read back by the `ownerDocument` accessor). `adopt`
        // captures self weakly so the closures parked on the wrapper never
        // retain the bridge; `docNode` is kept alive by `detachedDocumentRoots`.
        let adopt: (DOMNode, JeffJSContext) -> JeffJSValue = { [weak self, weak docNode] node, ctx in
            guard let self else { return JeffJSValue.null }
            if node.parent == nil { node.nodeDocument = docNode }
            return self.wrapElement(node, ctx: ctx)
        }

        ctx.setPropertyFunc(obj: wrapper, name: "createElement", fn: { ctx, _, args in
            guard let tagName = ctx.toSwiftString(args.first ?? .undefined) else { return JeffJSValue.null }
            return adopt(DOMNode.element(tag: tagName), ctx)
        }, length: 1)

        ctx.setPropertyFunc(obj: wrapper, name: "createElementNS", fn: { ctx, _, args in
            adopt(Self.makeElementNS(ctx: ctx, args: args) ?? DOMNode.element(tag: "div"), ctx)
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

        ctx.setPropertyFunc(obj: wrapper, name: "adoptNode", fn: { [weak self, weak docNode] ctx, _, args in
            guard let self, let docNode, !args.isEmpty, let node = self.extractNode(from: args[0]),
                  node.nodeType != .document else { return JeffJSValue.null }
            self.adopt(node, into: docNode)
            return args[0].dupValue()
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
        ctx.setPropertyStr(obj: el, name: "tagName", value: ctx.newStringValue(Self.qualifiedTagName(node)))
        ctx.setPropertyStr(obj: el, name: "localName", value: ctx.newStringValue(node.tagName ?? ""))
        if node.isDocumentType {
            // DocumentType: `name` comes from the shared prototype's reflected
            // `name` accessor (the doctype keeps its name under that key).
            ctx.setPropertyStr(obj: el, name: "publicId", value: ctx.newStringValue(node.doctypePublicId))
            ctx.setPropertyStr(obj: el, name: "systemId", value: ctx.newStringValue(node.doctypeSystemId))
        }
        ctx.setPropertyStr(obj: el, name: "nativeNodeID", value: ctx.newStringValue(node.id.uuidString))
        // `ownerDocument` is an accessor on the shared prototype (it follows
        // adoption and removal from another document's tree).

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
        // A wrapper for a node outside any tree is a collection candidate.
        if node.parent == nil, node !== root, node.nodeType != .document { noteDetached(node) }
        return el
    }

    /// Wraps an array of DOMNodes as a JeffJS array.
    func wrapElementArray(_ nodes: [DOMNode], ctx: JeffJSContext) -> JeffJSValue {
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
        // Nodes are EventTargets: the element prototype chains to
        // EventTarget.prototype for addEventListener/removeEventListener/dispatchEvent.
        let proto = eventBridge?.eventTargetPrototype.map { ctx.newObjectProto(proto: $0) } ?? ctx.newObject()

        // Register all methods on the prototype
        registerElementMethods(on: proto, ctx: ctx)

        // Register __get_*/__set_* native functions on the prototype
        registerElementPropertyAccessors(on: proto, ctx: ctx)

        // HTMLScriptElement IDL (async/defer/noModule/text/...)
        registerScriptElementAccessors(on: proto, ctx: ctx)

        // HTMLInputElement.defaultChecked (reflects the `checked` content attribute)
        registerFormControlAccessors(on: proto, ctx: ctx)

        // Install accessor properties (textContent, className, etc.) on the prototype
        installElementPropertyShim(on: proto, ctx: ctx)

        // on* event handler IDL attributes (HTML §8.1.8.1): accessors that
        // read null until set, store a function/object (anything else is
        // null), and are what the event dispatch invokes. Preact's
        // `'onclick' in element` check relies on them being present.
        installEventHandlerAccessors(on: proto, names: Self.elementEventHandlerNames, ctx: ctx)

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
        // No element this bridge creates has a namespace prefix.
        ctx.setPropertyStr(obj: proto, name: "prefix", value: .null)

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
            // DOM §4.9: names are lowercased only on HTML elements; an SVG
            // element's `viewBox` is looked up as written (the lowercase alias
            // the parser registers keeps the lenient spelling working).
            let value = targetNode.isHTMLNamespace
                ? self.pageAttribute(targetNode, name.lowercased())
                : (targetNode.attributes[name] ?? targetNode.attributes[name.lowercased()])
            guard let value else { return JeffJSValue.null }
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
            // Foreign elements keep the name's case (`viewBox`); see setAttributeValue.
            self.setAttributeValue(targetNode, name: name, value: value)
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
            self.removeAttributeValue(targetNode, name: name)
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
            if !targetNode.isHTMLNamespace, targetNode.attributes[name] != nil { return .newBool(true) }
            return .newBool(self.pageAttribute(targetNode, name.lowercased()) != nil)
        }, length: 1)

        // getAttributeNames() -> array of strings
        ctx.setPropertyFunc(obj: el, name: "getAttributeNames", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return ctx.newArray() }
            guard let targetNode = self.extractNode(from: thisVal) else { return ctx.newArray() }
            let arr = ctx.newArray()
            // Attribute-list order (source order, then append order).
            var keys = targetNode.orderedAttributeNames
            if self.contentAttributeOverride != nil {
                keys = keys.filter { self.pageAttribute(targetNode, $0) != nil }
                for name in Self.contentAttributeOverrideNames.sorted()
                where targetNode.attributes[name] == nil && self.pageAttribute(targetNode, name) != nil {
                    keys.append(name)
                }
            }
            for (i, key) in keys.enumerated() {
                ctx.setPropertyUint32(obj: arr, index: UInt32(i), value: ctx.newStringValue(key))
            }
            ctx.setPropertyStr(obj: arr, name: "length", value: .newInt32(Int32(keys.count)))
            return arr
        }, length: 0)

        // appendChild(child) -> child. DOM §4.2.3: a DocumentFragment
        // inserts its children (and is left empty); the fragment is returned.
        ctx.setPropertyFunc(obj: el, name: "appendChild", fn: { [weak self] ctx, thisVal, args in
            guard let self, !args.isEmpty else { return JeffJSValue.null }
            guard let targetNode = self.nodeFromValue(thisVal) else { return JeffJSValue.null }
            guard let childNode = self.extractNode(from: args[0], ctx: ctx) else { return JeffJSValue.null }
            guard self.insertNode(childNode, into: targetNode, before: nil) else {
                return self.throwHierarchyRequestError(ctx: ctx, method: "appendChild")
            }
            self.notifyMutation(for: targetNode)
            return args[0].dupValue()
        }, length: 1)

        // removeChild(child) -> child. The node keeps its wrapper and its
        // event listeners (they belong to the node, DOM §2.7).
        ctx.setPropertyFunc(obj: el, name: "removeChild", fn: { [weak self] ctx, thisVal, args in
            guard let self, !args.isEmpty else { return JeffJSValue.null }
            guard let targetNode = self.nodeFromValue(thisVal) else { return JeffJSValue.null }
            guard let childNode = self.extractNode(from: args[0], ctx: ctx) else { return JeffJSValue.null }
            self.maybeCollectDetachedNodes()
            guard childNode.parent === targetNode else {
                return self.throwDOMException(ctx: ctx, name: "NotFoundError",
                    message: "Failed to execute 'removeChild' on 'Node': The node to be removed is not a child of this node.")
            }
            self.removeNodeFromParent(childNode)
            self.notifyMutation(for: targetNode)
            return args[0].dupValue()
        }, length: 1)

        // insertBefore(newChild, referenceChild) -> newChild
        ctx.setPropertyFunc(obj: el, name: "insertBefore", fn: { [weak self] ctx, thisVal, args in
            guard let self, !args.isEmpty else { return JeffJSValue.null }
            guard let targetNode = self.nodeFromValue(thisVal) else { return JeffJSValue.null }
            guard let newChild = self.extractNode(from: args[0], ctx: ctx) else { return JeffJSValue.null }
            var reference: DOMNode?
            if args.count > 1, !args[1].isNull, !args[1].isUndefined {
                reference = self.extractNode(from: args[1], ctx: ctx)
            }
            guard self.insertNode(newChild, into: targetNode, before: reference) else {
                return self.throwHierarchyRequestError(ctx: ctx, method: "insertBefore")
            }
            self.notifyMutation(for: targetNode)
            return args[0].dupValue()
        }, length: 2)

        // replaceChild(newChild, oldChild) -> oldChild
        ctx.setPropertyFunc(obj: el, name: "replaceChild", fn: { [weak self] ctx, thisVal, args in
            guard let self, args.count >= 2 else { return JeffJSValue.null }
            guard let targetNode = self.nodeFromValue(thisVal) else { return JeffJSValue.null }
            guard let newChild = self.extractNode(from: args[0], ctx: ctx),
                  let oldChild = self.extractNode(from: args[1], ctx: ctx) else { return JeffJSValue.null }
            self.maybeCollectDetachedNodes()
            guard oldChild.parent === targetNode else {
                return self.throwDOMException(ctx: ctx, name: "NotFoundError",
                    message: "Failed to execute 'replaceChild' on 'Node': The node to be replaced is not a child of this node.")
            }
            guard self.replaceChildNode(oldChild, with: newChild, in: targetNode) else {
                return self.throwHierarchyRequestError(ctx: ctx, method: "replaceChild")
            }
            self.notifyMutation(for: targetNode)
            return args[1].dupValue()
        }, length: 2)

        // remove() — removes self from parent
        ctx.setPropertyFunc(obj: el, name: "remove", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            guard let parent = targetNode.parent else { return JeffJSValue.undefined }
            self.maybeCollectDetachedNodes()
            self.removeNodeFromParent(targetNode)
            self.notifyMutation(for: parent)
            return JeffJSValue.undefined
        }, length: 0)

        // append(...nodes) / prepend(...nodes) — ParentNode (DOM §4.2.6):
        // strings become Text nodes, fragments contribute their children.
        ctx.setPropertyFunc(obj: el, name: "append", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.nodeFromValue(thisVal) else { return JeffJSValue.undefined }
            let nodes = self.convertNodesForInsertion(args, into: targetNode, ctx: ctx)
            self.insertNodes(nodes, into: targetNode, before: nil)
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "prepend", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.nodeFromValue(thisVal) else { return JeffJSValue.undefined }
            let nodes = self.convertNodesForInsertion(args, into: targetNode, ctx: ctx)
            self.insertNodes(nodes, into: targetNode, before: targetNode.children.first)
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 0)

        // before(...nodes) / after(...nodes) / replaceWith(...nodes) —
        // ChildNode (DOM §4.2.8), relative to the viable siblings (the
        // nearest ones not among the arguments).
        ctx.setPropertyFunc(obj: el, name: "before", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            guard let parent = targetNode.parent else { return JeffJSValue.undefined }
            let moving = self.argumentNodeSet(args, ctx: ctx)
            var viablePrevious = self.previousSibling(of: targetNode)
            while let v = viablePrevious, moving.contains(ObjectIdentifier(v)) { viablePrevious = self.previousSibling(of: v) }
            let nodes = self.convertNodesForInsertion(args, into: parent, ctx: ctx)
            let reference = viablePrevious.map { self.nextSibling(of: $0) } ?? parent.children.first
            self.insertNodes(nodes, into: parent, before: reference)
            self.notifyMutation(for: parent)
            return JeffJSValue.undefined
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "after", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            guard let parent = targetNode.parent else { return JeffJSValue.undefined }
            let moving = self.argumentNodeSet(args, ctx: ctx)
            var viableNext = self.nextSibling(of: targetNode)
            while let v = viableNext, moving.contains(ObjectIdentifier(v)) { viableNext = self.nextSibling(of: v) }
            let nodes = self.convertNodesForInsertion(args, into: parent, ctx: ctx)
            self.insertNodes(nodes, into: parent, before: viableNext)
            self.notifyMutation(for: parent)
            return JeffJSValue.undefined
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "replaceWith", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            guard let parent = targetNode.parent else { return JeffJSValue.undefined }
            let moving = self.argumentNodeSet(args, ctx: ctx)
            var viableNext = self.nextSibling(of: targetNode)
            while let v = viableNext, moving.contains(ObjectIdentifier(v)) { viableNext = self.nextSibling(of: v) }
            let nodes = self.convertNodesForInsertion(args, into: parent, ctx: ctx)
            if targetNode.parent === parent {
                self.replaceChildNode(targetNode, withNodes: nodes, in: parent)
            } else {
                self.insertNodes(nodes, into: parent, before: viableNext)
            }
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
            let raw = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
            let nodes = self.allElementDescendants(of: targetNode).filter {
                normalized == "*" || $0.tagName == ($0.isHTMLNamespace ? normalized : raw)
            }
            return self.wrapElementArray(nodes, ctx: ctx)
        }, length: 1)

        // addEventListener / removeEventListener / dispatchEvent are inherited
        // from EventTarget.prototype (see buildElementPrototype).

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
            if self.contentAttributeOverride != nil {
                return .newBool(targetNode.orderedAttributeNames.contains { self.pageAttribute(targetNode, $0) != nil }
                    || Self.contentAttributeOverrideNames.contains { self.pageAttribute(targetNode, $0) != nil })
            }
            return .newBool(!targetNode.attributes.isEmpty)
        }, length: 0)

        // toggleAttribute(name, force?) -> bool (the attribute's new presence)
        ctx.setPropertyFunc(obj: el, name: "toggleAttribute", fn: { [weak self] ctx, thisVal, args in
            guard let self, let targetNode = self.extractNode(from: thisVal),
                  let rawName = self.extractString(ctx: ctx, args: args, index: 0) else { return .newBool(false) }
            let name = rawName.lowercased()
            let present = self.pageAttribute(targetNode, name) != nil
            let hasForce = args.count >= 2 && !args[1].isUndefined
            let shouldSet = hasForce ? args[1].toBool() : !present
            if shouldSet {
                if !present { self.setAttributeValue(targetNode, name: name, value: "") }
            } else if present {
                self.removeAttributeValue(targetNode, name: name)
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
            guard self.insertAdjacent(position: position, target: targetNode, node: newNode) else {
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
            _ = self.insertAdjacent(position: position, target: targetNode, node: DOMNode.text(text))
            return JeffJSValue.undefined
        }, length: 2)

        // insertAdjacentHTML(position, html)
        ctx.setPropertyFunc(obj: el, name: "insertAdjacentHTML", fn: { [weak self] ctx, thisVal, args in
            guard let self, args.count >= 2,
                  let position = self.extractString(ctx: ctx, args: args, index: 0),
                  let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            let html = self.extractString(ctx: ctx, args: args, index: 1) ?? ""
            // beforebegin/afterend parse in the *parent's* context, beforeend/
            // afterbegin in the element's own.
            let context = (position.lowercased() == "beforebegin" || position.lowercased() == "afterend")
                ? (targetNode.parent ?? targetNode) : targetNode
            let fragment = DOMNode.documentFragment()
            for node in Self.parseHTMLFragment(html, context: context) { fragment.appendChild(node) }
            _ = self.insertAdjacent(position: position, target: targetNode, node: fragment)
            return JeffJSValue.undefined
        }, length: 2)

        // replaceChildren(...nodes) — drop every child, then append the arguments
        ctx.setPropertyFunc(obj: el, name: "replaceChildren", fn: { [weak self] ctx, thisVal, args in
            guard let self, let targetNode = self.nodeFromValue(thisVal) else { return JeffJSValue.undefined }
            self.maybeCollectDetachedNodes()
            let nodes = self.convertNodesForInsertion(args, into: targetNode, ctx: ctx)
            self.replaceAllChildren(of: targetNode, with: nodes)
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 0)

        // cloneNode(deep) -> element
        ctx.setPropertyFunc(obj: el, name: "cloneNode", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.null }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.null }
            self.maybeCollectDetachedNodes()
            let deep = !args.isEmpty && args[0].toBool()
            let cloned = self.cloneDOMNode(targetNode, deep: deep)
            // The clone's node document is the original's (DOM §4.5 "clone").
            let document = self.nodeDocument(of: targetNode)
            cloned.nodeDocument = document === self.root ? nil : document
            return self.wrapElement(cloned, ctx: ctx)
        }, length: 1)

        // contains(other) -> bool
        ctx.setPropertyFunc(obj: el, name: "contains", fn: { [weak self] ctx, thisVal, args in
            guard let self, !args.isEmpty else { return .newBool(false) }
            guard let targetNode = self.extractNode(from: thisVal) else { return .newBool(false) }
            guard let otherNode = self.extractNode(from: args[0]) else { return .newBool(false) }
            return .newBool(self.nodeContains(targetNode, child: otherNode))
        }, length: 1)

        // focus(options?) / blur() — HTML §6.6.6 focusing / unfocusing steps.
        ctx.setPropertyFunc(obj: el, name: "focus", fn: { [weak self] ctx, thisVal, _ in
            guard let self, let node = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            self.focusElement(node, ctx: ctx)
            return JeffJSValue.undefined
        }, length: 0)
        ctx.setPropertyFunc(obj: el, name: "blur", fn: { [weak self] ctx, thisVal, _ in
            guard let self, let node = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            self.blurElement(node, ctx: ctx)
            return JeffJSValue.undefined
        }, length: 0)

        // click() — HTML §6.2: a synthetic (untrusted) click, then the
        // activation behaviour (checkbox/radio, label, summary, links and
        // form submission through `onActivationBehavior`).
        ctx.setPropertyFunc(obj: el, name: "click", fn: { [weak self] ctx, thisVal, _ in
            guard let self, let node = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            self.click(node, ctx: ctx)
            return JeffJSValue.undefined
        }, length: 0)

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
            self.maybeCollectDetachedNodes()
            switch targetNode.nodeType {
            case .text, .comment:
                if !targetNode.isDocumentType { self.setCharacterData(targetNode, text) }
            case .element, .documentFragment:
                // DOM "string replace all": one Text node (none for "").
                self.replaceAllChildren(of: targetNode, with: text.isEmpty ? [] : [DOMNode.text(text)])
            case .document:
                break
            }
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- innerText (read-write) — HTML §3.2.7 (rendered text) --
        ctx.setPropertyFunc(obj: el, name: "__get_innerText", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return ctx.newStringValue("") }
            guard let targetNode = self.extractNode(from: thisVal) else { return ctx.newStringValue("") }
            return ctx.newStringValue(self.innerText(of: targetNode, ctx: ctx))
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__set_innerText", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            let text = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            self.maybeCollectDetachedNodes()
            self.setInnerText(targetNode, text)
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- innerHTML (read-write) --
        ctx.setPropertyFunc(obj: el, name: "__get_innerHTML", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return ctx.newStringValue("") }
            guard let targetNode = self.extractNode(from: thisVal) else { return ctx.newStringValue("") }
            // A <template>'s markup lives in its content fragment, not its
            // children (serializeChildren reads it from there).
            var html = ""
            self.serializeChildren(of: targetNode, into: &html, scripting: self.scriptingEnabled(for: targetNode))
            return ctx.newStringValue(html)
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__set_innerHTML", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let element = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            // HTML §4.12.3 / §13.2.9: a template's markup goes into its content
            // fragment, but it is parsed with the *template* as the context
            // element ("in template" mode), so `<tr><td>` keeps its table parts.
            let targetNode = Self.isHTMLTemplate(element) ? self.templateFragment(for: element) : element
            let html = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            self.maybeCollectDetachedNodes()
            // One childList record: every old child removed, the parse added.
            self.replaceAllChildren(of: targetNode, with: Self.parseHTMLFragment(html, context: element))
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- outerHTML (read) --
        ctx.setPropertyFunc(obj: el, name: "__get_outerHTML", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return ctx.newStringValue("") }
            guard let targetNode = self.extractNode(from: thisVal) else { return ctx.newStringValue("") }
            var html = ""
            self.serializeNode(targetNode, rawTextParent: false, into: &html,
                               scripting: self.scriptingEnabled(for: targetNode))
            return ctx.newStringValue(html)
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__set_outerHTML", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            guard let parent = targetNode.parent else { return JeffJSValue.undefined }
            let html = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            self.maybeCollectDetachedNodes()
            self.replaceChildNode(targetNode, withNodes: Self.parseHTMLFragment(html, context: parent), in: parent)
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
            self.setAttributeValue(targetNode, name: "content", value: self.extractString(ctx: ctx, args: args, index: 0) ?? "")
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- namespaceURI (read-only) --
        // DOM §4.9: every element has a namespace; the parser leaves HTML
        // elements' nil (= XHTML) and "" is createElementNS's null namespace.
        ctx.setPropertyFunc(obj: el, name: "__get_namespaceURI", fn: { [weak self] ctx, thisVal, _ in
            guard let self, let node = self.extractNode(from: thisVal), node.nodeType == .element else {
                return JeffJSValue.null
            }
            let ns = node.namespaceURI ?? DOMNode.htmlNamespace
            return ns.isEmpty ? JeffJSValue.null : ctx.newStringValue(ns)
        }, length: 0)

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
            self.setAttributeValue(targetNode, name: "id", value: value)
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
            self.setAttributeValue(targetNode, name: "class", value: value)
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- value (read-write, for form elements) --
        // <textarea> (HTML §4.10.11): the raw value is the element's child
        // text content (its default value) until script sets `value` (the
        // dirty flag); the `value` content attribute is never consulted. The
        // setter still writes the attribute, which is where the host's
        // renderer reads a textarea's displayed text from.
        ctx.setPropertyFunc(obj: el, name: "__get_value", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return ctx.newStringValue("") }
            guard let targetNode = self.extractNode(from: thisVal) else { return ctx.newStringValue("") }
            if Self.isTextarea(targetNode), !self.dirtyTextareas.contains(targetNode.id) {
                return ctx.newStringValue(Self.childTextContent(targetNode))
            }
            return ctx.newStringValue(targetNode.attributes["value"] ?? "")
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__set_value", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            let value = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            if Self.isTextarea(targetNode) { self.dirtyTextareas.insert(targetNode.id) }
            // The IDL value / checked setters stand in for the dirty value /
            // checkedness (no form-control state yet): not attribute
            // mutations as far as MutationObserver is concerned.
            targetNode.setAttribute(name: "value", value: value)
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- defaultValue --
        // <textarea>: its child text content; setting it replaces the children
        // with one Text node. Elsewhere (input/output…) the `value` attribute.
        ctx.setPropertyFunc(obj: el, name: "__get_defaultValue", fn: { [weak self] ctx, thisVal, _ in
            guard let self, let targetNode = self.extractNode(from: thisVal) else { return ctx.newStringValue("") }
            if Self.isTextarea(targetNode) { return ctx.newStringValue(Self.childTextContent(targetNode)) }
            return ctx.newStringValue(targetNode.attributes["value"] ?? "")
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__set_defaultValue", fn: { [weak self] ctx, thisVal, args in
            guard let self, let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            let value = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            if Self.isTextarea(targetNode) {
                self.replaceAllChildren(of: targetNode, with: value.isEmpty ? [] : [DOMNode.text(value)])
            } else {
                self.setAttributeValue(targetNode, name: "value", value: value)
            }
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
            // HTML §6.1: the enumerated attribute's "until-found" state reads
            // as that string; any other present value is the hidden state.
            guard let v = targetNode.attributes["hidden"] else { return JeffJSValue.JS_FALSE }
            if v.lowercased() == "until-found" { return ctx.newStringValue("until-found") }
            return JeffJSValue.JS_TRUE
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__set_hidden", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            let value = args.first ?? .undefined
            // "until-found" (ASCII case-insensitive) sets that keyword; any
            // other truthy value sets "", a falsy one removes the attribute.
            if value.isString, let str = ctx.toSwiftString(value), str.lowercased() == "until-found" {
                self.setAttributeValue(targetNode, name: "hidden", value: "until-found")
            } else if ctx.toBool(value) {
                self.setAttributeValue(targetNode, name: "hidden", value: "")
            } else {
                self.removeAttributeValue(targetNode, name: "hidden")
            }
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- src (read-write) --
        ctx.setPropertyFunc(obj: el, name: "__get_src", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return ctx.newStringValue("") }
            guard let targetNode = self.extractNode(from: thisVal) else { return ctx.newStringValue("") }
            // HTML "reflect as a URL" for the elements whose `src` is a URL:
            // resolved against the document base (the raw value when it does
            // not parse). Loaders take their own base from
            // `document.currentScript.src`.
            let raw = targetNode.attributes["src"] ?? ""
            if !raw.isEmpty, targetNode.isHTMLNamespace, Self.urlSrcTags.contains(targetNode.tagName ?? ""),
               let url = JeffJSHyperlinkURL(raw, base: self.documentBaseURL()) {
                return ctx.newStringValue(url.href)
            }
            return ctx.newStringValue(raw)
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__set_src", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            let value = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            self.setAttributeValue(targetNode, name: "src", value: value)
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- href (read-write) --
        ctx.setPropertyFunc(obj: el, name: "__get_href", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return ctx.newStringValue("") }
            guard let targetNode = self.extractNode(from: thisVal) else { return ctx.newStringValue("") }
            // <a>/<area>/<link>/<base>: the href URL resolved against the
            // document base (HTML §4.6.1 / §4.2.4 "reflect as a URL"); the raw
            // attribute when it does not parse. Other elements: the attribute.
            let raw = targetNode.attributes["href"]
            if JeffJSHyperlinkURL.resolvesHref(targetNode), let raw {
                if let url = JeffJSHyperlinkURL(raw, base: self.documentBaseURL()) {
                    return ctx.newStringValue(url.href)
                }
            }
            return ctx.newStringValue(raw ?? "")
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__set_href", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            let value = self.extractString(ctx: ctx, args: args, index: 0) ?? ""
            self.setAttributeValue(targetNode, name: "href", value: value)
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- nodeValue (read-write for text/comment nodes) --
        ctx.setPropertyFunc(obj: el, name: "__get_nodeValue", fn: { [weak self] ctx, thisVal, _ in
            guard let self else { return JeffJSValue.null }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.null }
            if targetNode.isDocumentType { return JeffJSValue.null }
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
                guard !targetNode.isDocumentType else { break }
                self.setCharacterData(targetNode, value)
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
            guard targetNode.nodeType == .text || targetNode.nodeType == .comment,
                  !targetNode.isDocumentType else { return JeffJSValue.undefined }
            self.setCharacterData(targetNode, value)
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
            if let cached = self.classListCache[targetNode.id] {
                self.syncTokenListIndices(cached, DOMNode.orderedTokenSet(targetNode.attributes["class"] ?? ""), ctx: ctx)
                return cached.dupValue()
            }
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
            self.setAttributeValue(targetNode, name: "rel", value: self.extractString(ctx: ctx, args: args, index: 0) ?? "")
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- Hyperlink / link reflections (HTML §4.6.1 HTMLHyperlinkElementUtils,
        //    §4.6.2 HTMLAnchorElement, §4.6.3 HTMLAreaElement, §4.2.4 HTMLLinkElement) --
        // One shared element prototype serves every tag, so each accessor
        // checks the element's tag: where the IDL attribute does not exist
        // it reads the content attribute if present (undefined otherwise)
        // and writes it, as the attribute path frameworks fall back to.
        func installReflection(_ idl: String, tags: Set<String>,
                               get: @escaping (JeffJSDOMBridge, DOMNode) -> String,
                               set: @escaping (JeffJSDOMBridge, DOMNode, String) -> Void) {
            let contentAttr = idl.lowercased()
            ctx.setPropertyFunc(obj: el, name: "__get_\(idl)", fn: { [weak self] ctx, thisVal, _ in
                guard let self, let node = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
                guard tags.contains(node.tagName?.lowercased() ?? "") else {
                    if let v = node.attributes[contentAttr] { return ctx.newStringValue(v) }
                    return JeffJSValue.undefined
                }
                return ctx.newStringValue(get(self, node))
            }, length: 0)
            ctx.setPropertyFunc(obj: el, name: "__set_\(idl)", fn: { [weak self] ctx, thisVal, args in
                guard let self, let node = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
                // DOMString conversion: null -> "null", undefined -> "undefined".
                let value = args.isEmpty ? "undefined" : (ctx.toSwiftString(args[0]) ?? "")
                if tags.contains(node.tagName?.lowercased() ?? "") {
                    set(self, node, value)
                } else {
                    self.setAttributeValue(node, name: contentAttr, value: value)
                }
                self.notifyMutation(for: node)
                return JeffJSValue.undefined
            }, length: 1)
        }
        func plain(_ attr: String) -> (JeffJSDOMBridge, DOMNode) -> String {
            return { _, node in node.attributes[attr] ?? "" }
        }
        func setPlain(_ attr: String) -> (JeffJSDOMBridge, DOMNode, String) -> Void {
            return { bridge, node, v in bridge.setAttributeValue(node, name: attr, value: v) }
        }
        let hyperlink: Set<String> = ["a", "area"]
        installReflection("hreflang", tags: ["a", "link"], get: plain("hreflang"), set: setPlain("hreflang"))
        installReflection("target", tags: ["a", "area", "base", "form"], get: plain("target"), set: setPlain("target"))
        installReflection("download", tags: hyperlink, get: plain("download"), set: setPlain("download"))
        installReflection("ping", tags: hyperlink, get: plain("ping"), set: setPlain("ping"))
        // referrerPolicy: an enumerated attribute limited to known values.
        installReflection("referrerPolicy", tags: ["a", "area", "img", "iframe", "link", "script"],
                          get: { _, node in
                              JeffJSHyperlinkURL.referrerPolicy(node.attributes["referrerpolicy"])
                          },
                          set: setPlain("referrerpolicy"))
        // URL decomposition (HTMLHyperlinkElementUtils) on <a> and <area>.
        // A missing or unparsable href reads as "" (":" for protocol) and
        // makes the setters no-ops, per the spec's "url is null" steps.
        for part in JeffJSHyperlinkURL.Part.allCases {
            installReflection(part.rawValue, tags: hyperlink,
                              get: { bridge, node in
                                  guard let raw = node.attributes["href"],
                                        let url = JeffJSHyperlinkURL(raw, base: bridge.documentBaseURL()) else {
                                      return part == .`protocol` ? ":" : ""
                                  }
                                  return url.get(part)
                              },
                              set: { bridge, node, value in
                                  guard part != .origin, let raw = node.attributes["href"],
                                        var url = JeffJSHyperlinkURL(raw, base: bridge.documentBaseURL()) else { return }
                                  if url.set(part, value) {
                                      bridge.setAttributeValue(node, name: "href", value: url.href)
                                  }
                              })
        }

        // -- Plain string reflections (HTML "reflect" IDL attributes) --
        // Each is `el.<x>` <-> the `<x>` content attribute, the same shape as
        // src/href/rel above. Without them `meta.name`, `img.alt`,
        // `input.placeholder` … all read as undefined, and real page code does
        // `el.name.replace(...)` on them without a guard.
        // `lang` is HTMLElement's (HTML §3.2.6.2); MediaWiki's
        // ExternalGuidance does `documentElement.lang.indexOf(...)`.
        for reflected in ["name", "alt", "title", "placeholder", "lang"] {
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
                self.setAttributeValue(targetNode, name: reflected,
                                        value: self.extractString(ctx: ctx, args: args, index: 0) ?? "")
                self.notifyMutation(for: targetNode)
                return JeffJSValue.undefined
            }, length: 1)
        }

        // -- dir (HTML §3.2.6.4): reflected, limited to only known values —
        // ltr / rtl / auto, ASCII case-insensitively, read back lowercase;
        // anything else (or no attribute) reads "". --
        ctx.setPropertyFunc(obj: el, name: "__get_dir", fn: { [weak self] ctx, thisVal, _ in
            guard let self, let targetNode = self.extractNode(from: thisVal) else {
                return ctx.newStringValue("")
            }
            let v = (targetNode.attributes["dir"] ?? "").lowercased()
            return ctx.newStringValue(["ltr", "rtl", "auto"].contains(v) ? v : "")
        }, length: 0)
        ctx.setPropertyFunc(obj: el, name: "__set_dir", fn: { [weak self] ctx, thisVal, args in
            guard let self, let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
            self.setAttributeValue(targetNode, name: "dir", value: self.extractString(ctx: ctx, args: args, index: 0) ?? "")
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

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
            self.setAttributeValue(targetNode, name: "type", value: self.extractString(ctx: ctx, args: args, index: 0) ?? "")
            self.notifyMutation(for: targetNode)
            return JeffJSValue.undefined
        }, length: 1)

        // -- Geometry accessors (offset*/client*/scroll*) --
        registerElementGeometryAccessors(on: el, ctx: ctx)

        // -- ownerDocument / dataset / open / control / labels --
        registerInteractionAccessors(on: el, ctx: ctx)
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
            ("hreflang", true), ("target", true), ("download", true), ("ping", true),
            ("referrerPolicy", true), ("origin", false), ("protocol", true),
            ("username", true), ("password", true), ("host", true), ("hostname", true),
            ("port", true), ("pathname", true), ("search", true), ("hash", true),
            ("name", true), ("alt", true), ("title", true), ("placeholder", true), ("type", true),
            ("lang", true), ("dir", true),
            ("id", true), ("className", true), ("value", true), ("defaultValue", true),
            ("namespaceURI", false),
            ("checked", true), ("hidden", true), ("src", true), ("href", true),
            ("nodeValue", true), ("data", true), ("isConnected", false),
            ("parentNode", false), ("parentElement", false),
            ("childNodes", false), ("children", false),
            ("firstChild", false), ("lastChild", false),
            ("nextSibling", false), ("previousSibling", false),
            ("nextElementSibling", false), ("previousElementSibling", false),
            ("firstElementChild", false), ("lastElementChild", false),
            ("childElementCount", false),
            ("ownerDocument", false), ("dataset", false), ("open", true),
            ("control", true), ("labels", true),
            // Geometry (see registerElementGeometryAccessors)
            ("offsetWidth", false), ("offsetHeight", false),
            ("offsetTop", false), ("offsetLeft", false), ("offsetParent", false),
            ("clientWidth", false), ("clientHeight", false),
            ("clientTop", false), ("clientLeft", false),
            ("scrollWidth", false), ("scrollHeight", false),
            ("scrollTop", true), ("scrollLeft", true),
        ] + Self.scriptIDLNames.map { ($0, true) } + Self.formControlIDLNames.map { ($0, true) }

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
            self.setAttributeValue(node, name: "style", value: value)
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
            self.setAttributeValue(node, name: "style", value: Self.serializeInlineStyles(styles))
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
            self.setAttributeValue(node, name: "style", value: Self.serializeInlineStyles(styles))
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
        // DOM §7.1 "update steps": no attribute is created for an empty set.
        let store: ([String]) -> Void = { [weak self] list in
            guard let self else { return }
            if list.isEmpty, node.attributes[attribute] == nil { return }
            self.setAttributeValue(node, name: attribute, value: list.joined(separator: " "))
        }
        // DOM §7.1 validation: "" is a SyntaxError, ASCII whitespace an
        // InvalidCharacterError. Returns the thrown exception or nil.
        func validate(_ bridge: JeffJSDOMBridge, _ ctx: JeffJSContext, _ tokens: [String]) -> JeffJSValue? {
            for t in tokens {
                if t.isEmpty {
                    return bridge.throwDOMException(ctx: ctx, name: "SyntaxError", message: "The token provided must not be empty.")
                }
                if t.unicodeScalars.contains(where: { DOMNode.isASCIIWhitespace($0) }) {
                    return bridge.throwDOMException(ctx: ctx, name: "InvalidCharacterError",
                        message: "The token provided ('\(t)') contains HTML space characters, which are not valid in tokens.")
                }
            }
            return nil
        }
        func strings(_ ctx: JeffJSContext, _ args: [JeffJSValue]) -> [String] {
            args.map { ctx.toSwiftString($0) ?? "" }
        }

        // add(token, ...)
        ctx.setPropertyFunc(obj: obj, name: "add", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            let add = strings(ctx, args)
            if let exc = validate(self, ctx, add) { return exc }
            var list = tokens()
            for cls in add where !list.contains(cls) { list.append(cls) }
            store(list)
            self.syncTokenListIndices(thisVal, list, ctx: ctx)
            self.notifyMutation(for: node)
            return JeffJSValue.undefined
        }, length: 0)

        // remove(token, ...)
        ctx.setPropertyFunc(obj: obj, name: "remove", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            let remove = strings(ctx, args)
            if let exc = validate(self, ctx, remove) { return exc }
            var list = tokens()
            list.removeAll { remove.contains($0) }
            store(list)
            self.syncTokenListIndices(thisVal, list, ctx: ctx)
            self.notifyMutation(for: node)
            return JeffJSValue.undefined
        }, length: 0)

        // toggle(token, force?) -> bool
        ctx.setPropertyFunc(obj: obj, name: "toggle", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return .newBool(false) }
            let cls = ctx.toSwiftString(args.first ?? .undefined) ?? ""
            if let exc = validate(self, ctx, [cls]) { return exc }
            var list = tokens()
            let present = list.contains(cls)
            let hasForce = args.count >= 2 && !args[1].isUndefined
            let force = hasForce ? ctx.toBool(args[1]) : !present
            if present == force { return .newBool(present) }   // nothing to do
            if force { list.append(cls) } else { list.removeAll { $0 == cls } }
            store(list)
            self.syncTokenListIndices(thisVal, list, ctx: ctx)
            self.notifyMutation(for: node)
            return .newBool(force)
        }, length: 1)

        // contains(cls) -> bool
        ctx.setPropertyFunc(obj: obj, name: "contains", fn: { ctx, _, args in
            guard let cls = ctx.toSwiftString(args.first ?? .undefined) else { return .newBool(false) }
            return .newBool(tokens().contains(cls))
        }, length: 1)

        // replace(oldCls, newCls) -> bool
        ctx.setPropertyFunc(obj: obj, name: "replace", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return .newBool(false) }
            guard args.count >= 2 else {
                return ctx.throwTypeError(message: "Failed to execute 'replace' on 'DOMTokenList': 2 arguments required, but only \(args.count) present.")
            }
            let oldCls = ctx.toSwiftString(args[0]) ?? "", newCls = ctx.toSwiftString(args[1]) ?? ""
            if let exc = validate(self, ctx, [oldCls, newCls]) { return exc }
            var list = tokens()
            guard let idx = list.firstIndex(of: oldCls) else { return .newBool(false) }
            // DOM §7.1 "replace": the first of old/new keeps the position.
            if let newIdx = list.firstIndex(of: newCls) {
                if newIdx < idx { list.remove(at: idx) } else { list[idx] = newCls; list.remove(at: newIdx) }
            } else {
                list[idx] = newCls
            }
            store(list)
            self.syncTokenListIndices(thisVal, list, ctx: ctx)
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
            // The callee borrows its arguments: the token string is ours to free.
            for (i, token) in tokens().enumerated() {
                let tokenVal = ctx.newStringValue(token)
                let r = ctx.callRetained(callback, this: thisArg, args: [tokenVal, .newInt32(Int32(i)), thisVal])
                tokenVal.freeValue()
                if r.isException { return r }
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
            self.setAttributeValue(node, name: attribute, value: v)
            self.notifyMutation(for: node)
            return .undefined
        }, name: "set value", length: 1)
        // (the indices are re-synced by the classList/relList getters too)
        ctx.setPropertyGetSet(obj: obj, name: "value", getter: valueGetter, setter: valueSetter)

        for (i, cls) in tokens().enumerated() {
            ctx.setPropertyUint32(obj: obj, index: UInt32(i), value: ctx.newStringValue(cls))
        }

        return obj
    }

    /// Keeps a cached DOMTokenList's indexed properties equal to `list`
    /// (the object outlives attribute changes made by other APIs).
    func syncTokenListIndices(_ obj: JeffJSValue, _ list: [String], ctx: JeffJSContext) {
        guard obj.isObject else { return }
        for (i, t) in list.enumerated() {
            ctx.setPropertyUint32(obj: obj, index: UInt32(i), value: ctx.newStringValue(t))
        }
        var i = UInt32(list.count)
        while ctx.hasPropertyByIndex(obj: obj, index: i) {
            _ = ctx.deletePropertyByIndex(obj: obj, index: i)
            i += 1
        }
    }

    /// The content fragment backing a `<template>` element. Created on first use;
    /// any children the HTML parser left directly on the template are migrated in,
    /// matching the spec where template markup never becomes element children.
    func templateFragment(for node: DOMNode) -> DOMNode {
        // Move, don't clear: `appendChild` has already re-parented each child
        // to the fragment, and `clearChildren()` would reset those parent
        // pointers to nil (so `content.firstChild.parentNode` was null).
        let fragment: DOMNode
        if let existing = templateContent[node.id] {
            fragment = existing
        } else {
            fragment = DOMNode.documentFragment()
            // HTML §4.12.3: the contents belong to the template's inert
            // document ("appropriate template contents owner document").
            fragment.nodeDocument = inertDocument(for: nodeDocument(of: node))
            templateContent[node.id] = fragment
        }
        let moved = node.detachChildrenArray()
        for child in moved { fragment.appendChild(child) }
        return fragment
    }

    // MARK: - Update ReadyState

    /// Updates the document.readyState property on the context.
    func setReadyState(_ value: String, on doc: JeffJSValue, ctx: JeffJSContext) {
        ctx.setPropertyStr(obj: doc, name: "readyState", value: ctx.newStringValue(value))
        // HTML §6.6.5: autofocus candidates are flushed at the next rendering
        // update after parsing — a queued task here.
        if value == "interactive" {
            queueTask { [weak self] in self?.runAutofocus() }
        }
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

    /// The document base URL (HTML §2.4.1): the first `<base href>` in the
    /// document's head resolved against the document URL, else the document
    /// URL itself.
    func documentBaseURL() -> URL {
        let html = root.children.first { $0.nodeType == .element && $0.tagName?.lowercased() == "html" }
        let head = html?.children.first { $0.nodeType == .element && $0.tagName?.lowercased() == "head" }
        if let base = head?.children.first(where: {
               $0.nodeType == .element && $0.tagName?.lowercased() == "base" && $0.attributes["href"] != nil
           }),
           let href = base.attributes["href"],
           let resolved = JeffJSHyperlinkURL(href, base: baseURL),
           let url = URL(string: resolved.href) {
            return url
        }
        return baseURL
    }

    /// Extracts a Swift string from args at the given index.
    func extractString(ctx: JeffJSContext, args: [JeffJSValue], index: Int) -> String? {
        guard index < args.count else { return nil }
        let val = args[index]
        if val.isUndefined || val.isNull { return nil }
        return ctx.toSwiftString(val)
    }

    /// Notifies the mutation observer of a change to the given node.
    ///
    /// Scripts are no longer started from here: the insertion and attribute
    /// algorithms prepare them (`JeffJSDOMBridge+Scripts.swift`), once per
    /// script, with the <script> element itself.
    func notifyMutation(for node: DOMNode) {
        onMutated?([node.id])
    }

    /// Finds the first element node matching a predicate (DFS).
    func findElement(in node: DOMNode, where predicate: (DOMNode) -> Bool) -> DOMNode? {
        if node.nodeType == .element && predicate(node) { return node }
        for child in node.children {
            if let found = findElement(in: child, where: predicate) {
                return found
            }
        }
        return nil
    }

    /// Returns all element descendants of a node (DFS, pre-order).
    func allElementDescendants(of node: DOMNode) -> [DOMNode] {
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
    func isConnected(_ node: DOMNode) -> Bool {
        var current: DOMNode? = node
        while let c = current {
            if c === root { return true }
            current = c.parent
        }
        return false
    }

    /// Returns the next sibling of a node in its parent's children.
    func nextSibling(of node: DOMNode) -> DOMNode? {
        guard let parent = node.parent else { return nil }
        let siblings = parent.children
        guard let idx = siblings.firstIndex(where: { $0 === node }) else { return nil }
        let nextIdx = siblings.index(after: idx)
        return nextIdx < siblings.endIndex ? siblings[nextIdx] : nil
    }

    /// Returns the previous sibling of a node in its parent's children.
    func previousSibling(of node: DOMNode) -> DOMNode? {
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
    private func insertAdjacent(position: String, target: DOMNode, node: DOMNode) -> Bool {
        switch position.lowercased() {
        case "beforebegin":
            guard let parent = target.parent, insertNode(node, into: parent, before: target) else { return false }
            notifyMutation(for: parent)
        case "afterbegin":
            guard insertNode(node, into: target, before: target.children.first) else { return false }
            notifyMutation(for: target)
        case "beforeend":
            guard insertNode(node, into: target, before: nil) else { return false }
            notifyMutation(for: target)
        case "afterend":
            guard let parent = target.parent,
                  insertNode(node, into: parent, before: nextSibling(of: target)) else { return false }
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

    func nodeContains(_ parent: DOMNode, child: DOMNode) -> Bool {
        if parent === child { return true }
        for c in parent.children {
            if nodeContains(c, child: child) { return true }
        }
        return false
    }

    /// Deep or shallow clone of a DOMNode.
    func cloneDOMNode(_ node: DOMNode, deep: Bool) -> DOMNode {
        switch node.nodeType {
        case .element:
            let cloned = DOMNode.element(
                tag: node.tagName ?? "div",
                preserveCase: true,
                namespace: node.namespaceURI
            )
            cloned.copyAttributes(from: node)
            // HTML §4.12.1 script cloning steps: "already started" is copied.
            cloned.scriptAlreadyStarted = node.scriptAlreadyStarted
            if deep {
                // A template's contents are cloned with it (HTML §4.12.3
                // cloning steps); they sit in its content fragment.
                for child in serializationChildren(of: node) {
                    cloned.appendChild(cloneDOMNode(child, deep: true))
                }
            }
            return cloned
        case .text:
            return DOMNode.text(node.textContent ?? "")
        case .comment:
            if node.isDocumentType {
                return DOMNode.documentType(name: node.doctypeName, publicId: node.doctypePublicId,
                                            systemId: node.doctypeSystemId)
            }
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
        case .comment: return node.isDocumentType ? 10 : 8
        case .document: return 9
        case .documentFragment: return 11
        }
    }

    /// Returns the nodeName string for a DOMNode.
    private func nodeNameStr(_ node: DOMNode) -> String {
        switch node.nodeType {
        case .element: return Self.qualifiedTagName(node)
        case .text: return "#text"
        case .comment: return node.isDocumentType ? node.doctypeName : "#comment"
        case .document: return "#document"
        case .documentFragment: return "#document-fragment"
        }
    }

    private static func isTextarea(_ node: DOMNode) -> Bool {
        node.nodeType == .element && node.tagName == "textarea" && node.isHTMLNamespace
    }

    /// DOM "child text content": the concatenated data of the Text children.
    static func childTextContent(_ node: DOMNode) -> String {
        var out = ""
        for child in node.children where child.nodeType == .text { out += child.textContent ?? "" }
        return out
    }

    /// `Element.tagName` (DOM §4.9 "HTML-uppercased qualified name"): HTML
    /// elements ASCII-uppercase, SVG/MathML/other namespaces keep their case
    /// (`foreignObject`, `clipPath`). Non-elements: "".
    static func qualifiedTagName(_ node: DOMNode) -> String {
        guard node.nodeType == .element, let tag = node.tagName else { return "" }
        guard node.isHTMLNamespace else { return tag }
        return asciiUppercased(tag)
    }

    private static func asciiUppercased(_ s: String) -> String {
        var needs = false
        for b in s.utf8 where b >= 0x61 && b <= 0x7A { needs = true; break }
        guard needs else { return s }
        return String(decoding: s.utf8.map { ($0 >= 0x61 && $0 <= 0x7A) ? $0 - 0x20 : $0 }, as: UTF8.self)
    }

    // MARK: - HTML Serialization / Parsing

    // §13.3 "serializing HTML fragments".

    /// HTML void elements: no children serialised, no end tag.
    private static let serializerVoidElements: Set<String> = [
        "area", "base", "basefont", "bgsound", "br", "col", "embed", "frame", "hr",
        "img", "input", "keygen", "link", "meta", "param", "source", "track", "wbr",
    ]

    /// Elements whose Text children are written verbatim (their content was
    /// RAWTEXT / script data / PLAINTEXT to the parser). `noscript` joins them
    /// only when scripting is enabled for the node.
    private static let serializerRawTextParents: Set<String> = [
        "style", "script", "xmp", "iframe", "noembed", "noframes", "plaintext",
    ]

    static func isHTMLTemplate(_ node: DOMNode) -> Bool {
        node.nodeType == .element && node.tagName == "template" && node.isHTMLNamespace
    }

    /// "Scripting is enabled for the node": its node document has a browsing
    /// context. Nodes of a DOMParser / createHTMLDocument document and template
    /// contents (an inert document) do not; everything else here belongs to
    /// the page.
    private func scriptingEnabled(for node: DOMNode) -> Bool {
        var top = node
        while let p = top.parent { top = p }
        if top === root { return true }
        if top.nodeType == .document { return false }
        if top.nodeType == .documentFragment, !templateContent.isEmpty,
           templateContent.values.contains(where: { $0 === top }) {
            return false
        }
        return true
    }

    /// The children the serializer walks: a template's contents (its content
    /// fragment, then anything the parser left on the element and
    /// `templateFragment` has not migrated yet), otherwise the children.
    func serializationChildren(of node: DOMNode) -> [DOMNode] {
        guard Self.isHTMLTemplate(node) else { return node.children }
        if let fragment = templateContent[node.id] { return fragment.children + node.children }
        return node.children
    }

    private func serializeChildren(of node: DOMNode, into out: inout String, scripting: Bool) {
        var raw = false
        if node.nodeType == .element, node.isHTMLNamespace, let tag = node.tagName {
            raw = Self.serializerRawTextParents.contains(tag) || (scripting && tag == "noscript")
        }
        for child in serializationChildren(of: node) {
            serializeNode(child, rawTextParent: raw, into: &out, scripting: scripting)
        }
    }

    private func serializeNode(_ node: DOMNode, rawTextParent: Bool, into out: inout String, scripting: Bool) {
        switch node.nodeType {
        case .text:
            let text = node.textContent ?? ""
            if rawTextParent { out += text } else { Self.appendEscaped(text, attribute: false, into: &out) }
        case .comment:
            if node.isDocumentType {
                out += "<!DOCTYPE "
                out += node.doctypeName
                out += ">"
            } else {
                out += "<!--"
                out += node.textContent ?? ""
                out += "-->"
            }
        case .document, .documentFragment:
            serializeChildren(of: node, into: &out, scripting: scripting)
        case .element:
            guard let tag = node.tagName else { return }
            out += "<"
            out += tag
            // Attribute-list order (source order, then append order).
            var attrs = node.orderedAttributes
            if contentAttributeOverride != nil, node.nodeType == .element {
                attrs = attrs.compactMap { pair in pageAttribute(node, pair.name).map { (name: pair.name, value: $0) } }
                for name in Self.contentAttributeOverrideNames.sorted()
                where node.attributes[name] == nil {
                    if let v = pageAttribute(node, name) { attrs.append((name: name, value: v)) }
                }
            }
            for (key, val) in attrs {
                out += " "
                out += key
                out += "=\""
                Self.appendEscaped(val, attribute: true, into: &out)
                out += "\""
            }
            out += ">"
            if node.isHTMLNamespace, Self.serializerVoidElements.contains(tag) { return }
            serializeChildren(of: node, into: &out, scripting: scripting)
            out += "</"
            out += tag
            out += ">"
        }
    }

    /// §13.3 "escaping a string": `&` -> `&amp;`, U+00A0 -> `&nbsp;`; in text
    /// `<`/`>` -> `&lt;`/`&gt;`; in attribute values `"` -> `&quot;` (and `<`/`>`
    /// too, as current browsers do).
    private static func appendEscaped(_ text: String, attribute: Bool, into out: inout String) {
        var needs = false
        for b in text.utf8 where b == 0x26 || b == 0x3C || b == 0x3E || b == 0xC2 || (attribute && b == 0x22) {
            needs = true
            break
        }
        guard needs else { out += text; return }
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "\u{A0}": out += "&nbsp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where attribute: out += "&quot;"
            default: out.unicodeScalars.append(scalar)
            }
        }
    }

    /// The HTML fragment parsing algorithm, run with `context` as the context
    /// element — which is what makes `table.innerHTML = "<tr>…"` keep its rows
    /// instead of foster-parenting them out of the table.
    /// Scripts it creates are marked "already started" (HTML §13.4: markup
    /// inserted with innerHTML/outerHTML/insertAdjacentHTML never runs its
    /// scripts); `createContextualFragment` passes false (DOM Parsing §7.1
    /// "unmark all scripts as already started").
    static func parseHTMLFragment(_ html: String, context: DOMNode? = nil, markScriptsStarted: Bool = true) -> [DOMNode] {
        let nodes = HTMLParser.parseFragment(
            html,
            context: context?.tagName,
            contextNamespace: context?.namespaceURI
        )
        if markScriptsStarted { markScriptsAlreadyStarted(in: nodes) }
        return nodes
    }

    // MARK: - Inline Style Helpers

    static func parseInlineStyles(_ style: String) -> [String: String] {
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

// MARK: - Hyperlink URL (HTMLHyperlinkElementUtils)

/// A WHATWG-flavoured view of a hyperlink's URL over Foundation's parser:
/// scheme and host lower-cased, default ports dropped, special schemes
/// always carry a path ("https://a.b" -> "https://a.b/"). Used by the
/// `href` / `origin` / `protocol` / `host` / `hostname` / `port` /
/// `pathname` / `search` / `hash` reflections on `<a>` and `<area>`.
struct JeffJSHyperlinkURL {
    enum Part: String, CaseIterable {
        case origin, `protocol`, username, password, host, hostname, port, pathname, search, hash
    }

    private static let defaultPorts: [String: Int] = ["http": 80, "https": 443, "ws": 80, "wss": 443, "ftp": 21]
    private static let specialSchemes: Set<String> = ["http", "https", "ws", "wss", "ftp", "file"]

    private var comps: URLComponents

    /// Parse `string` against `base`; nil when it is not a valid URL.
    init?(_ string: String, base: URL) {
        let trimmed = string.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\u{0C}"))
        var url: URL?
        if trimmed.isEmpty {
            url = base
        } else {
            url = URL(string: trimmed, relativeTo: base)
            if url == nil {
                url = URL(string: Self.encode(trimmed, allowed: .urlFragmentAllowed.union(["#"])), relativeTo: base)
            }
        }
        guard let abs = url?.absoluteURL,
              var c = URLComponents(url: abs, resolvingAgainstBaseURL: false),
              let scheme = c.scheme, !scheme.isEmpty else { return nil }
        c.scheme = scheme.lowercased()
        if let h = c.percentEncodedHost { c.percentEncodedHost = h.lowercased() }
        comps = c
        normalize()
    }

    private var scheme: String { comps.scheme ?? "" }
    private var isSpecial: Bool { Self.specialSchemes.contains(scheme) }

    private mutating func normalize() {
        if let p = comps.port, Self.defaultPorts[scheme] == p { comps.port = nil }
        if isSpecial && comps.percentEncodedPath.isEmpty { comps.percentEncodedPath = "/" }
    }

    var href: String { comps.string ?? "" }

    func get(_ part: Part) -> String {
        switch part {
        case .origin:
            guard Self.defaultPorts[scheme] != nil, let h = comps.percentEncodedHost, !h.isEmpty else { return "null" }
            return "\(scheme)://\(h)\(comps.port.map { ":\($0)" } ?? "")"
        case .`protocol`: return scheme + ":"
        case .username: return comps.percentEncodedUser ?? ""
        case .password: return comps.percentEncodedPassword ?? ""
        case .host:
            guard let h = comps.percentEncodedHost else { return "" }
            return h + (comps.port.map { ":\($0)" } ?? "")
        case .hostname: return comps.percentEncodedHost ?? ""
        case .port: return comps.port.map(String.init) ?? ""
        case .pathname: return comps.percentEncodedPath
        case .search:
            guard let q = comps.percentEncodedQuery, !q.isEmpty else { return "" }
            return "?" + q
        case .hash:
            guard let f = comps.percentEncodedFragment, !f.isEmpty else { return "" }
            return "#" + f
        }
    }

    /// Apply a component setter; false when the spec's basic-URL-parser
    /// state override leaves the URL unchanged.
    mutating func set(_ part: Part, _ value: String) -> Bool {
        let hasHost = comps.percentEncodedHost != nil
        switch part {
        case .origin:
            return false
        case .`protocol`:
            let s = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?.lowercased() ?? ""
            guard let first = s.unicodeScalars.first, CharacterSet.letters.contains(first), first.isASCII,
                  s.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0)) })
            else { return false }
            // Special and non-special schemes do not convert into each other.
            if Self.specialSchemes.contains(s) != isSpecial { return false }
            if s == "file" && (comps.port != nil || comps.percentEncodedUser != nil) { return false }
            comps.scheme = s
        case .username, .password:
            guard hasHost, scheme != "file", !(comps.percentEncodedHost ?? "").isEmpty else { return false }
            let enc = Self.encode(value, allowed: .urlUserAllowed)
            if part == .username { comps.percentEncodedUser = enc.isEmpty ? nil : enc }
            else { comps.percentEncodedPassword = enc.isEmpty ? nil : enc }
        case .host, .hostname:
            guard hasHost else { return false }
            let cut = value.prefix { !"/?#\\".contains($0) }
            var hostPart = String(cut)
            var portPart: String? = nil
            if part == .host, !hostPart.hasPrefix("["), let colon = hostPart.firstIndex(of: ":") {
                portPart = String(hostPart[hostPart.index(after: colon)...])
                hostPart = String(hostPart[..<colon])
            }
            if hostPart.isEmpty && isSpecial { return false }
            let forbidden = CharacterSet(charactersIn: " #%/:<>?@[\\]^|\t\n\r")
            if hostPart.unicodeScalars.contains(where: { forbidden.contains($0) }) { return false }
            comps.host = hostPart.lowercased()
            if let portPart {
                let digits = portPart.prefix { $0.isASCII && $0.isNumber }
                if !digits.isEmpty, let p = Int(digits), p <= 65535 { comps.port = p }
            }
        case .port:
            guard hasHost, scheme != "file", !(comps.percentEncodedHost ?? "").isEmpty else { return false }
            if value.isEmpty {
                comps.port = nil
            } else {
                let digits = value.prefix { $0.isASCII && $0.isNumber }
                guard !digits.isEmpty, let p = Int(digits), p <= 65535 else { return false }
                comps.port = p
            }
        case .pathname:
            // An opaque path (mailto:, javascript:) cannot be replaced.
            guard hasHost || comps.percentEncodedPath.hasPrefix("/") else { return false }
            var p = Self.encode(value, allowed: .urlPathAllowed)
            if isSpecial && !p.hasPrefix("/") { p = "/" + p }
            comps.percentEncodedPath = p
        case .search:
            let v = value.hasPrefix("?") ? String(value.dropFirst()) : value
            comps.percentEncodedQuery = v.isEmpty ? nil : Self.encode(v, allowed: .urlQueryAllowed)
        case .hash:
            let v = value.hasPrefix("#") ? String(value.dropFirst()) : value
            comps.percentEncodedFragment = v.isEmpty ? nil : Self.encode(v, allowed: .urlFragmentAllowed)
        }
        normalize()
        return true
    }

    /// Percent-encode everything outside `allowed`, keeping existing valid
    /// `%XX` escapes (the WHATWG encode sets never re-encode `%`), so the
    /// result is always acceptable to URLComponents' percentEncoded* setters.
    static func encode(_ s: String, allowed: CharacterSet) -> String {
        let scalars = Array(s.unicodeScalars)
        var out = ""
        var i = 0
        func isHex(_ u: Unicode.Scalar) -> Bool { u.isASCII && u.properties.isASCIIHexDigit }
        while i < scalars.count {
            let u = scalars[i]
            if u == "%" {
                if i + 2 < scalars.count, isHex(scalars[i + 1]), isHex(scalars[i + 2]) {
                    out.unicodeScalars.append(contentsOf: scalars[i...(i + 2)])
                    i += 3
                    continue
                }
                out += "%25"
            } else if u.isASCII && allowed.contains(u) {
                out.unicodeScalars.append(u)
            } else {
                for b in String(u).utf8 { out += String(format: "%%%02X", b) }
            }
            i += 1
        }
        return out
    }

    /// Elements whose `href` IDL attribute reflects as a URL.
    static func resolvesHref(_ node: DOMNode) -> Bool {
        switch node.tagName?.lowercased() {
        case "a", "area", "link", "base": return true
        default: return false
        }
    }

    /// `referrerPolicy`: limited to the referrer-policy tokens, ASCII
    /// case-insensitive; anything else (or no attribute) reads as "".
    static func referrerPolicy(_ raw: String?) -> String {
        guard let v = raw?.lowercased() else { return "" }
        let known: Set<String> = [
            "no-referrer", "no-referrer-when-downgrade", "same-origin", "origin",
            "strict-origin", "origin-when-cross-origin", "strict-origin-when-cross-origin", "unsafe-url",
        ]
        return known.contains(v) ? v : ""
    }
}
