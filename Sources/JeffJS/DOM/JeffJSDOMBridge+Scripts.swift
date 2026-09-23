// JeffJSDOMBridge+Scripts.swift
// JeffJS DOM bridge — script elements (HTML §4.12.1):
//
//   - "prepare the script element" triggers for script-inserted scripts
//     (§4.12.1.1): a <script> becoming connected (every insertion path, one
//     call per script, in tree order, after the whole insertion), a connected
//     script's children changing, and a connected script getting a `src`
//     attribute where it had none.
//   - the "already started" flag (`DOMNode.scriptAlreadyStarted`): set when
//     the bridge hands a script over, for the scripts already in the document
//     when the bridge registers (the host's parser prepared them), and for
//     every script the fragment parser creates (innerHTML, outerHTML,
//     insertAdjacentHTML, DOMParser): those never run (§13.4, §8.5.1).
//     `cloneNode` copies it.
//   - the HTMLScriptElement IDL: `async` (with the "non-blocking" flag),
//     `defer`, `noModule`, `text`, `charset`, `event`, `htmlFor`,
//     `crossOrigin`, `integrity`.
//   - a default runner (`runScriptElementDefault`) for hosts without their
//     own (JeffJSEnvironment, the CLI, the conformance tests).
//
// Host contract (`onScriptExecution`, see the init of JeffJSDOMBridge):
//   The callback receives the <script> element to *execute*. The bridge has
//   already run the prepare steps up to "set already started": the element is
//   connected, has a `src` attribute or non-empty child text, and its type is
//   classic JavaScript, "module" or "importmap". The host must not re-check
//   "already started" (it is now true) and must, per §4.12.1.1 onwards:
//     - inline classic script (no `src`): execute it synchronously, before
//       returning from the callback, with `document.currentScript` set to it
//       (`setCurrentScriptNode` / `document.__setCurrentScriptByID`), then
//       restore the previous current script; no load event.
//     - external script (`src`): fetch it; execute it later (in a task) with
//       `document.currentScript` = the element (null for modules), then fire
//       `load` (non-bubbling, not cancelable) at the element; on a fetch
//       failure fire `error` instead and do not execute. Script-inserted
//       scripts are async unless `script.async` was set to false
//       (`!node.scriptNonBlocking && node.attributes["async"] == nil`), in which
//       case they execute in insertion order.
//     - `nomodule` on a classic script, a disabled scripting flag, or a
//       blocked URL: simply do nothing (the element stays "already started").
//   Parser-inserted scripts the host prepares itself should get
//   `node.scriptAlreadyStarted = true` (the bridge sets it for every such
//   script present when it registers, so this only matters for markup the
//   host parses later).

import Foundation

extension JeffJSDOMBridge {

    /// MIME Sniffing §4.6 "JavaScript MIME type essence match" strings.
    static let javaScriptMIMETypes: Set<String> = [
        "application/ecmascript", "application/javascript", "application/x-ecmascript",
        "application/x-javascript", "text/ecmascript", "text/javascript", "text/javascript1.0",
        "text/javascript1.1", "text/javascript1.2", "text/javascript1.3", "text/javascript1.4",
        "text/javascript1.5", "text/jscript", "text/livescript", "text/x-ecmascript",
        "text/x-javascript",
    ]

    /// The script's type (HTML §4.12.1.1 "prepare", step 8): "classic",
    /// "module", "importmap", or nil when the user agent does not run it.
    static func scriptKind(of node: DOMNode) -> String? {
        let typeAttr = node.attributes["type"]
        let language = node.attributes["language"]
        let typeString: String
        if let t = typeAttr, !t.isEmpty {
            typeString = t
        } else if typeAttr == nil, let l = language, !l.isEmpty {
            typeString = "text/" + l
        } else {
            return "classic"
        }
        let trimmed = typeString.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\u{0C}\r")).lowercased()
        if javaScriptMIMETypes.contains(trimmed) { return "classic" }
        if trimmed == "module" { return "module" }
        if trimmed == "importmap" { return "importmap" }
        return nil
    }

    static func isHTMLScript(_ node: DOMNode) -> Bool {
        node.nodeType == .element && node.isHTMLNamespace && node.tagName == "script"
    }

    /// Whether `prepare` would set "already started" (steps 1-10, without the
    /// connectedness check).
    static func scriptWouldStart(_ node: DOMNode) -> Bool {
        guard isHTMLScript(node), !node.scriptAlreadyStarted else { return false }
        if node.attributes["src"] == nil && childTextContent(node).isEmpty { return false }
        return scriptKind(of: node) != nil
    }

    /// Marks every script in `nodes`' subtrees as already started (the
    /// fragment parser, DOMParser, and the document the host parsed).
    static func markScriptsAlreadyStarted(in nodes: [DOMNode], onlyIfWouldStart: Bool = false) {
        var stack = nodes.reversed() as [DOMNode]
        while let n = stack.popLast() {
            if isHTMLScript(n), !onlyIfWouldStart || scriptWouldStart(n) { n.scriptAlreadyStarted = true }
            for c in n.children.reversed() { stack.append(c) }
        }
    }

    /// Script elements among `nodes` and their descendants, in tree order
    /// (template contents are inert and not searched).
    private func scriptElements(in nodes: [DOMNode]) -> [DOMNode] {
        var out: [DOMNode] = []
        var stack = nodes.reversed() as [DOMNode]
        while let n = stack.popLast() {
            guard n.nodeType == .element || n.nodeType == .documentFragment else { continue }
            if Self.isHTMLScript(n) {
                if !n.scriptAlreadyStarted { out.append(n) }
            } else if Self.isHTMLTemplate(n) {
                continue
            }
            if n.children.isEmpty { continue }
            for c in n.children.reversed() { stack.append(c) }
        }
        return out
    }

    /// DOM "insert" step 7 (post-connection steps) + the script "children
    /// changed" steps, after `inserted` went into `parent`. Runs synchronously:
    /// an inline script executes before the inserting call returns.
    func runScriptInsertionSteps(inserted: [DOMNode], parent: DOMNode) {
        let parentIsScript = Self.isHTMLScript(parent)
        guard !inserted.isEmpty || parentIsScript else { return }
        guard isConnected(parent) else { return }
        // A static list first: scripts run by earlier ones may move later ones.
        for script in scriptElements(in: inserted) { prepareScript(script) }
        if parentIsScript { prepareScript(parent) }
    }

    /// The `src` attribute was set on `node` where it had none (§4.12.1.1).
    func scriptSrcAttributeAdded(_ node: DOMNode) {
        guard Self.isHTMLScript(node), !node.scriptAlreadyStarted, isConnected(node) else { return }
        prepareScript(node)
    }

    /// "Prepare the script element" up to "already started", then hand it to
    /// the host.
    func prepareScript(_ node: DOMNode) {
        guard Self.scriptWouldStart(node), isConnected(node) else { return }
        node.scriptAlreadyStarted = true
        onScriptExecution?(node)
    }

    // MARK: - Default runner (hosts without their own)

    /// Executes a prepared script: inline classic scripts synchronously,
    /// external ones (file: URLs and anything `loadExternal` returns) from a
    /// queued task in preparation order, then `load` / `error`. Modules and
    /// import maps are not run by this runner.
    func runScriptElementDefault(_ node: DOMNode, loadExternal: ((URL) -> String?)? = nil) {
        guard let ctx = jsContext else { return }
        let kind = Self.scriptKind(of: node) ?? ""
        if kind == "classic", node.attributes["nomodule"] != nil { return }
        if let raw = node.attributes["src"] {
            let url = raw.isEmpty ? nil : URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: documentBaseURL())?.absoluteURL
            queueTask { [weak self, node] in
                guard let self, let ctx = self.jsContext else { return }
                var source: String?
                if let url, kind == "classic" {
                    if let loadExternal { source = loadExternal(url) }
                    else if url.isFileURL { source = try? String(contentsOf: url, encoding: .utf8) }
                }
                guard let source else {
                    self.fireScriptEvent("error", at: node, ctx: ctx)
                    return
                }
                self.evaluateScriptElement(node, source: source, filename: url?.lastPathComponent ?? "<script>", ctx: ctx)
                self.fireScriptEvent("load", at: node, ctx: ctx)
            }
            return
        }
        guard kind == "classic" else { return }
        evaluateScriptElement(node, source: Self.childTextContent(node), filename: "<inline-script>", ctx: ctx)
    }

    /// Runs `source` as the classic script of `node` with
    /// `document.currentScript` set to it (restored afterwards).
    func evaluateScriptElement(_ node: DOMNode, source: String, filename: String, ctx: JeffJSContext) {
        let previous = currentScriptNode
        currentScriptNode = node
        let r = ctx.eval(input: source, filename: filename, evalFlags: JS_EVAL_TYPE_GLOBAL)
        currentScriptNode = previous
        reportIfException(r, ctx: ctx, label: "script \(filename)")
        r.freeValue()
    }

    /// `load` / `error` at a script element: not bubbling, not cancelable.
    func fireScriptEvent(_ type: String, at node: DOMNode, ctx: JeffJSContext) {
        let target = wrapElement(node, ctx: ctx)
        defer { target.freeValue() }
        guard let event = makeEvent(ctx: ctx, constructors: ["Event"], type: type,
                                    init: [("bubbles", .newBool(false)), ("cancelable", .newBool(false))]) else { return }
        ctx.setPropertyStr(obj: event, name: "isTrusted", value: .newBool(true))
        eventBridge?.dispatchFromTarget(ctx: ctx, target: target, type: type, event: event)
        event.freeValue()
    }
}
