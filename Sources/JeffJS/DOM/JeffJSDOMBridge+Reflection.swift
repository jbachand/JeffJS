// JeffJSDOMBridge+Reflection.swift
// JeffJS DOM bridge — IDL surface found missing on real pages (the app's
// spec-ladder rung 16, wiki-1 / wiki-2):
//
//   - HTMLScriptElement: async (non-blocking), defer, noModule, text,
//     charset, event, htmlFor, crossOrigin, integrity (HTML §4.12.1).
//   - on* event handler IDL attributes as accessors on elements, document and
//     window (HTML §8.1.8.1); `'ontouchstart' in window` is true (iOS).
//   - CSS.escape (CSSOM §2.1 "serialize an identifier").
//   - document.__createContextualFragment(context, html): the fragment
//     parse of Range.createContextualFragment, scripts left startable (the
//     host's Range / document.write polyfills call it).
//   - contentAttributeOverride: lets a host whose `attributes` hold a form
//     control's *state* report the page's content attribute instead.
//   - HTMLInputElement.defaultChecked (netflix.com: React's input update
//     assigns it), an accessor on the shared prototype like value/checked.

import Foundation

extension JeffJSDOMBridge {

    // MARK: - Event handler names

    /// GlobalEventHandlers (+ the touch, pointer, animation and transition
    /// handlers WebKit exposes on iOS, and the legacy focusin/focusout the
    /// bridge already had).
    static let elementEventHandlerNames: [String] = [
        "onabort", "onauxclick", "onbeforeinput", "onbeforematch", "onbeforetoggle", "onblur", "oncancel",
        "oncanplay", "oncanplaythrough", "onchange", "onclick", "onclose", "oncontextlost", "oncontextmenu",
        "oncontextrestored", "oncopy", "oncuechange", "oncut", "ondblclick", "ondrag", "ondragend",
        "ondragenter", "ondragleave", "ondragover", "ondragstart", "ondrop", "ondurationchange",
        "onemptied", "onended", "onerror", "onfocus", "onformdata", "oninput", "oninvalid", "onkeydown",
        "onkeypress", "onkeyup", "onload", "onloadeddata", "onloadedmetadata", "onloadstart",
        "onmousedown", "onmouseenter", "onmouseleave", "onmousemove", "onmouseout", "onmouseover",
        "onmouseup", "onpaste", "onpause", "onplay", "onplaying", "onprogress", "onratechange", "onreset",
        "onresize", "onscroll", "onscrollend", "onsecuritypolicyviolation", "onseeked", "onseeking",
        "onselect", "onslotchange", "onstalled", "onsubmit", "onsuspend", "ontimeupdate", "ontoggle",
        "onvolumechange", "onwaiting", "onwheel", "onselectstart", "onselectionchange",
        "onfocusin", "onfocusout",
        "ontouchstart", "ontouchend", "ontouchmove", "ontouchcancel",
        "onpointerdown", "onpointerup", "onpointermove", "onpointerover", "onpointerout",
        "onpointerenter", "onpointerleave", "onpointercancel", "ongotpointercapture",
        "onlostpointercapture",
        "onanimationstart", "onanimationend", "onanimationiteration", "onanimationcancel",
        "ontransitionstart", "ontransitionend", "ontransitionrun", "ontransitioncancel",
        "onwebkitanimationstart", "onwebkitanimationend", "onwebkitanimationiteration",
        "onwebkittransitionend", "ongesturestart", "ongesturechange", "ongestureend",
    ]

    /// WindowEventHandlers + window-only handlers.
    static let windowEventHandlerNames: [String] = [
        "onafterprint", "onbeforeprint", "onbeforeunload", "onhashchange", "onlanguagechange",
        "onmessage", "onmessageerror", "onoffline", "ononline", "onpagehide", "onpageshow",
        "onpopstate", "onrejectionhandled", "onstorage", "onunhandledrejection", "onunload",
        "onorientationchange", "ondevicemotion", "ondeviceorientation",
    ]

    private static let eventHandlerInstaller = #"""
    (function (target, names) {
      function def(name) {
        var key = '__jjeh_' + name;
        Object.defineProperty(target, name, {
          configurable: true, enumerable: true,
          get: function () {
            var o = (this === undefined || this === null) ? globalThis : Object(this);
            var v = Object.prototype.hasOwnProperty.call(o, key) ? o[key] : null;
            return v === undefined ? null : v;
          },
          set: function (v) {
            var o = (this === undefined || this === null) ? globalThis : Object(this);
            // [LegacyTreatNonObjectAsNull]: a non-object stores null.
            Object.defineProperty(o, key, { value: (typeof v === 'function' || (typeof v === 'object' && v !== null)) ? v : null,
              writable: true, configurable: true, enumerable: false });
          }
        });
      }
      for (var i = 0; i < names.length; i++) def(names[i]);
    })
    """#

    /// Installs the on* accessors on `target` (the element prototype, the
    /// document, the global object).
    func installEventHandlerAccessors(on target: JeffJSValue, names: [String], ctx: JeffJSContext) {
        let installer = ctx.eval(input: Self.eventHandlerInstaller, filename: "<event-handlers>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        defer { installer.freeValue() }
        guard installer.isFunction else { reportIfException(installer, ctx: ctx, label: "event handler install"); return }
        let arr = ctx.newArray()
        for (i, n) in names.enumerated() { ctx.setPropertyUint32(obj: arr, index: UInt32(i), value: ctx.newStringValue(n)) }
        let r = ctx.call(installer, this: .undefined, args: [target, arr])
        reportIfException(r, ctx: ctx, label: "event handler install")
        r.freeValue()
        arr.freeValue()
    }

    // MARK: - HTMLScriptElement IDL

    /// `__get_*` / `__set_*` for the script IDL attributes; names added to
    /// `installElementPropertyShim`'s table as accessors.
    static let scriptIDLNames: [String] = ["async", "defer", "noModule", "text", "charset", "event", "htmlFor", "crossOrigin", "integrity"]

    func registerScriptElementAccessors(on el: JeffJSValue, ctx: JeffJSContext) {
        func shadow(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ name: String, _ value: JeffJSValue) {
            let atom = ctx.rt.findAtom(name)
            _ = ctx.definePropertyValue(obj: thisVal, atom: atom, value: value,
                                        flags: JS_PROP_WRITABLE | JS_PROP_ENUMERABLE | JS_PROP_CONFIGURABLE)
            ctx.rt.freeAtom(atom)
        }
        func isScript(_ n: DOMNode) -> Bool { Self.isHTMLScript(n) }

        // async: "non-blocking" or the attribute; setting clears non-blocking.
        ctx.setPropertyFunc(obj: el, name: "__get_async", fn: { [weak self] _, thisVal, _ in
            guard let self, let node = self.extractNode(from: thisVal), isScript(node) else { return .undefined }
            return .newBool(node.scriptNonBlocking || node.attributes["async"] != nil)
        }, length: 0)
        ctx.setPropertyFunc(obj: el, name: "__set_async", fn: { [weak self] ctx, thisVal, args in
            guard let self, let node = self.extractNode(from: thisVal) else { return .undefined }
            let value = args.first ?? .undefined
            guard isScript(node) else { shadow(ctx, thisVal, "async", value); return .undefined }
            node.scriptNonBlocking = false
            self.setBooleanAttribute(node, "async", ctx.toBool(value))
            return .undefined
        }, length: 1)

        // Boolean reflections.
        for (idl, attr) in [("defer", "defer"), ("noModule", "nomodule")] {
            ctx.setPropertyFunc(obj: el, name: "__get_\(idl)", fn: { [weak self] _, thisVal, _ in
                guard let self, let node = self.extractNode(from: thisVal), isScript(node) else { return .undefined }
                return .newBool(node.attributes[attr] != nil)
            }, length: 0)
            ctx.setPropertyFunc(obj: el, name: "__set_\(idl)", fn: { [weak self] ctx, thisVal, args in
                guard let self, let node = self.extractNode(from: thisVal) else { return .undefined }
                let value = args.first ?? .undefined
                guard isScript(node) else { shadow(ctx, thisVal, idl, value); return .undefined }
                self.setBooleanAttribute(node, attr, ctx.toBool(value))
                return .undefined
            }, length: 1)
        }

        // String reflections (crossOrigin is nullable, limited to known values).
        for (idl, attr) in [("charset", "charset"), ("event", "event"), ("htmlFor", "for"), ("integrity", "integrity"), ("crossOrigin", "crossorigin")] {
            ctx.setPropertyFunc(obj: el, name: "__get_\(idl)", fn: { [weak self] ctx, thisVal, _ in
                guard let self, let node = self.extractNode(from: thisVal) else { return .undefined }
                let applies = isScript(node) || (idl == "crossOrigin" && ["link", "img", "audio", "video"].contains(node.tagName ?? ""))
                guard applies else { return .undefined }
                if idl == "crossOrigin" {
                    guard let v = node.attributes[attr] else { return .null }
                    return ctx.newStringValue(v.lowercased() == "use-credentials" ? "use-credentials" : "anonymous")
                }
                return ctx.newStringValue(node.attributes[attr] ?? "")
            }, length: 0)
            ctx.setPropertyFunc(obj: el, name: "__set_\(idl)", fn: { [weak self] ctx, thisVal, args in
                guard let self, let node = self.extractNode(from: thisVal) else { return .undefined }
                let value = args.first ?? .undefined
                let applies = isScript(node) || (idl == "crossOrigin" && ["link", "img", "audio", "video"].contains(node.tagName ?? ""))
                guard applies else { shadow(ctx, thisVal, idl, value); return .undefined }
                if idl == "crossOrigin", value.isNull {
                    self.removeAttributeValue(node, name: attr)
                } else {
                    self.setAttributeValue(node, name: attr, value: ctx.toSwiftString(value) ?? "")
                }
                self.notifyMutation(for: node)
                return .undefined
            }, length: 1)
        }

        // text: script = child text content (setting = string replace all);
        // a / title = textContent; option = stripped and collapsed text.
        ctx.setPropertyFunc(obj: el, name: "__get_text", fn: { [weak self] ctx, thisVal, _ in
            guard let self, let node = self.extractNode(from: thisVal), node.nodeType == .element, node.isHTMLNamespace else { return .undefined }
            switch node.tagName ?? "" {
            case "script": return ctx.newStringValue(Self.childTextContent(node))
            case "a", "title": return ctx.newStringValue(node.rawTextDescendants)
            case "option":
                return ctx.newStringValue(DOMNode.splitASCIIWhitespace(node.rawTextDescendants).joined(separator: " "))
            default: return .undefined
            }
        }, length: 0)
        ctx.setPropertyFunc(obj: el, name: "__set_text", fn: { [weak self] ctx, thisVal, args in
            guard let self, let node = self.extractNode(from: thisVal) else { return .undefined }
            let value = args.first ?? .undefined
            guard node.nodeType == .element, node.isHTMLNamespace,
                  ["script", "a", "title", "option"].contains(node.tagName ?? "") else {
                shadow(ctx, thisVal, "text", value)
                return .undefined
            }
            let text = ctx.toSwiftString(value) ?? ""
            self.maybeCollectDetachedNodes()
            self.replaceAllChildren(of: node, with: text.isEmpty ? [] : [DOMNode.text(text)])
            self.notifyMutation(for: node)
            return .undefined
        }, length: 1)
    }

    // MARK: - Form control IDL

    /// Form control IDL attributes beyond value / defaultValue / checked;
    /// accessors on the shared element prototype like every other IDL
    /// attribute (WebIDL §3.7.6: configurable, enumerable, get + set), so a
    /// page may shadow one on an instance with `Object.defineProperty` and
    /// `delete` it again (React's input value tracking does both).
    static let formControlIDLNames: [String] = ["defaultChecked"]

    func registerFormControlAccessors(on el: JeffJSValue, ctx: JeffJSContext) {
        func isInput(_ n: DOMNode) -> Bool {
            n.nodeType == .element && n.isHTMLNamespace && n.tagName == "input"
        }
        // HTML §4.10.5: defaultChecked reflects the `checked` content
        // attribute (the page's, when the host keeps the checkedness in
        // `attributes`). Other elements have no such member: undefined, and
        // an assignment makes an ordinary own property.
        ctx.setPropertyFunc(obj: el, name: "__get_defaultChecked", fn: { [weak self] _, thisVal, _ in
            guard let self, let node = self.extractNode(from: thisVal), isInput(node) else { return .undefined }
            return .newBool(self.pageAttribute(node, "checked") != nil)
        }, length: 0)
        ctx.setPropertyFunc(obj: el, name: "__set_defaultChecked", fn: { [weak self] ctx, thisVal, args in
            guard let self, let node = self.extractNode(from: thisVal) else { return .undefined }
            let value = args.first ?? .undefined
            guard isInput(node) else {
                let atom = ctx.rt.findAtom("defaultChecked")
                _ = ctx.definePropertyValue(obj: thisVal, atom: atom, value: value,
                                            flags: JS_PROP_WRITABLE | JS_PROP_ENUMERABLE | JS_PROP_CONFIGURABLE)
                ctx.rt.freeAtom(atom)
                return .undefined
            }
            if ctx.toBool(value) {
                if self.pageAttribute(node, "checked") == nil { self.setAttributeValue(node, name: "checked", value: "") }
            } else if self.pageAttribute(node, "checked") != nil {
                self.removeAttributeValue(node, name: "checked")
            }
            self.notifyMutation(for: node)
            return .undefined
        }, length: 1)
    }

    func setBooleanAttribute(_ node: DOMNode, _ name: String, _ on: Bool) {
        if on {
            if node.attributes[name] == nil { setAttributeValue(node, name: name, value: ""); notifyMutation(for: node) }
        } else if node.attributes[name] != nil {
            removeAttributeValue(node, name: name)
            notifyMutation(for: node)
        }
    }

    // MARK: - CSS namespace, contextual fragments

    private static let cssNamespaceShim = #"""
    (function (g) {
      var CSS = (typeof g.CSS === 'object' && g.CSS !== null) ? g.CSS : {};
      // CSSOM §2.1 "serialize an identifier".
      Object.defineProperty(CSS, 'escape', { writable: true, configurable: true, enumerable: true, value: function escape(ident) {
        if (arguments.length === 0) throw new TypeError("Failed to execute 'escape' on 'CSS': 1 argument required, but only 0 present.");
        var s = String(ident), n = s.length, out = '', first = n ? s.charCodeAt(0) : 0;
        for (var i = 0; i < n; i++) {
          var c = s.charCodeAt(i);
          if (c === 0) { out += '�'; continue; }
          if ((c >= 0x1 && c <= 0x1f) || c === 0x7f || (i === 0 && c >= 0x30 && c <= 0x39) ||
              (i === 1 && c >= 0x30 && c <= 0x39 && first === 0x2d)) { out += '\\' + c.toString(16) + ' '; continue; }
          if (i === 0 && n === 1 && c === 0x2d) { out += '\\' + s.charAt(i); continue; }
          if (c >= 0x80 || c === 0x2d || c === 0x5f || (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a)) {
            out += s.charAt(i); continue;
          }
          out += '\\' + s.charAt(i);
        }
        return out;
      } });
      g.CSS = CSS;
    })
    """#

    func installCSSNamespace(on global: JeffJSValue, ctx: JeffJSContext) {
        let fn = ctx.eval(input: Self.cssNamespaceShim, filename: "<css-namespace>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        defer { fn.freeValue() }
        guard fn.isFunction else { reportIfException(fn, ctx: ctx, label: "CSS install"); return }
        let r = ctx.call(fn, this: .undefined, args: [global])
        reportIfException(r, ctx: ctx, label: "CSS install")
        r.freeValue()
    }

    /// `document.__createContextualFragment(contextElement, html)` — DOM
    /// Parsing §7.1 steps 2-4: the fragment parse with `contextElement`
    /// (null / html -> body), scripts *not* marked already started, so a
    /// host's Range.createContextualFragment and document.write insert
    /// scripts that run.
    func registerContextualFragment(on doc: JeffJSValue, ctx: JeffJSContext) {
        ctx.setPropertyFunc(obj: doc, name: "__createContextualFragment", fn: { [weak self] ctx, _, args in
            guard let self else { return .null }
            var context = args.first.flatMap { self.extractNode(from: $0) }
            if let c = context, c.nodeType != .element || (c.isHTMLNamespace && c.tagName == "html") { context = nil }
            let html = args.count > 1 ? (ctx.toSwiftString(args[1]) ?? "") : ""
            let fragment = DOMNode.documentFragment()
            let contextNode = context ?? DOMNode.element(tag: "body")
            for node in Self.parseHTMLFragment(html, context: contextNode, markScriptsStarted: false) {
                fragment.appendChild(node)
            }
            return self.wrapElement(fragment, ctx: ctx)
        }, length: 2)
    }

    // MARK: - Content attribute override (form control state)

    /// The page-visible content attribute `name` of `node` when the host keeps
    /// something else in `node.attributes[name]`: `.some(value)` (nil =
    /// absent) overrides, `.none` means `attributes[name]` is it.
    func contentAttribute(_ node: DOMNode, _ name: String) -> String?? {
        guard let hook = contentAttributeOverride, Self.contentAttributeOverrideNames.contains(name),
              node.nodeType == .element else { return .none }
        return hook(node, name)
    }

    /// `attributes[name]` as the page sees it.
    func pageAttribute(_ node: DOMNode, _ name: String) -> String? {
        if case .some(let v) = contentAttribute(node, name) { return v }
        return node.attributes[name]
    }

    /// The names the host may override (the form control state names).
    static let contentAttributeOverrideNames: Set<String> = ["value", "checked", "selected"]
}
