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

        nodeRegistry.removeAll()
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
    }

    // MARK: - Registration Entry Point

    /// Registers `document` and `window` objects on the JeffJS context's global scope.
    func register(on ctx: JeffJSContext) {
        let global = ctx.getGlobalObject()

        // -- window alias --
        ctx.setPropertyStr(obj: global, name: "window", value: global.dupValue())

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
            let classes = className.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
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

        // Install getter properties via a small eval shim.
        // Uses literal property names (no forEach+closure) to avoid JeffJS var_ref issues.
        let shim = """
        (function(d) {
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
        if let docVal = documentJSValue {
            ctx.setPropertyStr(obj: el, name: "ownerDocument", value: docVal.dupValue())
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

    /// Wraps an array of DOMNodes as a JeffJS array.
    private func wrapElementArray(_ nodes: [DOMNode], ctx: JeffJSContext) -> JeffJSValue {
        let arr = ctx.newArray()
        for (i, node) in nodes.enumerated() {
            let wrapped = wrapElement(node, ctx: ctx)
            ctx.setPropertyUint32(obj: arr, index: UInt32(i), value: wrapped)
        }
        // Set the length property
        ctx.setPropertyStr(obj: arr, name: "length", value: .newInt32(Int32(nodes.count)))
        return arr
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
            let classes = className.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
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
            // Use the parent's querySelectorAll to check
            if let parent = targetNode.parent {
                let matches = parent.querySelectorAll(selector)
                return .newBool(matches.contains(where: { $0 === targetNode }))
            }
            return .newBool(false)
        }, length: 1)

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

        // getBoundingClientRect() — returns a zero rect (layout rects not yet wired)
        ctx.setPropertyFunc(obj: el, name: "getBoundingClientRect", fn: { ctx, _, _ in
            let rect = ctx.newObject()
            for name in ["x", "y", "top", "left", "bottom", "right", "width", "height"] {
                ctx.setPropertyStr(obj: rect, name: name, value: .newFloat64(0))
            }
            return rect
        }, length: 0)

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
            guard let targetNode = self.extractNode(from: thisVal) else { return ctx.newStringValue("") }
            let html = targetNode.children.map { Self.serializeHTML($0) }.joined()
            return ctx.newStringValue(html)
        }, length: 0)

        ctx.setPropertyFunc(obj: el, name: "__set_innerHTML", fn: { [weak self] ctx, thisVal, args in
            guard let self else { return JeffJSValue.undefined }
            guard let targetNode = self.extractNode(from: thisVal) else { return JeffJSValue.undefined }
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
            return self.buildClassListObject(for: targetNode, ctx: ctx)
        }, length: 0)
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
            ("textContent", true), ("innerText", true), ("innerHTML", true), ("outerHTML", false),
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

        // classList — eagerly materialize (no lazy getter needed)
        let getClassList = ctx.getPropertyStr(obj: el, name: "__get_classList")
        if getClassList.isFunction {
            let classList = ctx.callFunction(getClassList, thisVal: el, args: [])
            ctx.setPropertyStr(obj: el, name: "classList", value: classList)
        }
        getClassList.freeValue()
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
        let obj = ctx.newObject()

        // add(cls, ...)
        ctx.setPropertyFunc(obj: obj, name: "add", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            var classes = Set((node.attributes["class"] ?? "").split(separator: " ").map(String.init))
            for arg in args {
                if let cls = ctx.toSwiftString(arg), !cls.isEmpty {
                    classes.insert(cls)
                }
            }
            node.setAttribute(name: "class", value: classes.sorted().joined(separator: " "))
            self.notifyMutation(for: node)
            return JeffJSValue.undefined
        }, length: 1)

        // remove(cls, ...)
        ctx.setPropertyFunc(obj: obj, name: "remove", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            var classes = Set((node.attributes["class"] ?? "").split(separator: " ").map(String.init))
            for arg in args {
                if let cls = ctx.toSwiftString(arg) {
                    classes.remove(cls)
                }
            }
            node.setAttribute(name: "class", value: classes.sorted().joined(separator: " "))
            self.notifyMutation(for: node)
            return JeffJSValue.undefined
        }, length: 1)

        // toggle(cls, force?) -> bool
        ctx.setPropertyFunc(obj: obj, name: "toggle", fn: { [weak self] ctx, _, args in
            guard let self, let cls = self.extractString(ctx: ctx, args: args, index: 0), !cls.isEmpty else {
                return .newBool(false)
            }
            var classes = Set((node.attributes["class"] ?? "").split(separator: " ").map(String.init))
            let hasForce = args.count >= 2 && !args[1].isUndefined
            let force = hasForce ? args[1].toBool() : nil

            let shouldAdd: Bool
            if let force {
                shouldAdd = force
            } else {
                shouldAdd = !classes.contains(cls)
            }

            if shouldAdd {
                classes.insert(cls)
            } else {
                classes.remove(cls)
            }
            node.setAttribute(name: "class", value: classes.sorted().joined(separator: " "))
            self.notifyMutation(for: node)
            return .newBool(shouldAdd)
        }, length: 1)

        // contains(cls) -> bool
        ctx.setPropertyFunc(obj: obj, name: "contains", fn: { [weak self] ctx, _, args in
            guard self != nil, let cls = ctx.toSwiftString(args.first ?? .undefined) else {
                return .newBool(false)
            }
            return .newBool(node.classList.contains(cls))
        }, length: 1)

        // replace(oldCls, newCls) -> bool
        ctx.setPropertyFunc(obj: obj, name: "replace", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 2,
                  let oldCls = ctx.toSwiftString(args[0]),
                  let newCls = ctx.toSwiftString(args[1]) else {
                return .newBool(false)
            }
            var classes = Set((node.attributes["class"] ?? "").split(separator: " ").map(String.init))
            guard classes.remove(oldCls) != nil else { return .newBool(false) }
            classes.insert(newCls)
            node.setAttribute(name: "class", value: classes.sorted().joined(separator: " "))
            self.notifyMutation(for: node)
            return .newBool(true)
        }, length: 2)

        // length getter
        ctx.setPropertyStr(obj: obj, name: "length", value: .newInt32(Int32(node.classList.count)))

        return obj
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
