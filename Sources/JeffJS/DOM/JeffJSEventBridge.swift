// JeffJSEventBridge.swift
// JeffJS — the DOM `EventTarget` interface (DOM §2.7–2.10), shared by every
// event target the engine exposes.
//
// One implementation, one listener store, one dispatch algorithm:
//   - `EventTarget.prototype.{addEventListener, removeEventListener, dispatchEvent}`
//     are three native functions created once here. `window` gets the same
//     function objects as own properties; `document` and every element wrapper
//     inherit them (their prototypes chain to `EventTarget.prototype`); the JS
//     polyfill targets (XMLHttpRequest, AbortSignal, MediaQueryList,
//     MessagePort, `class X extends EventTarget`) inherit them too.
//   - `Event` / `CustomEvent` / `EventTarget` constructors are installed unless
//     a usable one already exists.
//   - `__nativeEventBridge` (addEventListener, removeEventListener,
//     dispatchEvent, dispatchEventByName, dispatchClickSequence, dispatchEvents)
//     is the host-facing API and routes into the same code, as do the Swift
//     entry points `dispatchFromTarget(ctx:target:type:event:)` and
//     `dispatchClickSequence(ctx:target:)`.
//
// Dispatch follows the DOM "dispatch" algorithm: the path is fixed up front
// (target, its ancestors, then `document` and `window` for a node in the page
// document); capture listeners run from `window` down to the target, then the
// target's non-capture listeners, then — when `event.bubbles` — the ancestors
// back up to `window`. Listener lists are cloned per target, listeners removed
// mid-dispatch are skipped, `once` listeners are removed before they run,
// `passive` listeners cannot cancel, and the stop-propagation flags are
// cleared when dispatch ends.
//
// Event objects carry their state in plain fields so script-defined Event
// polyfills interoperate: `type`, `bubbles`, `cancelable`, `defaultPrevented`,
// `cancelBubble` (stop propagation flag), `__immediateStopped` (stop immediate
// propagation flag), `eventPhase`, `target`, `currentTarget`.
//
// Ownership: records own (dup) their listener and signal; every removal path
// frees them exactly once (`release`). Listeners are dup'd around each call so
// a listener that removes itself is never freed while it runs.

import Foundation

// MARK: - Listener Record

/// One registered listener (DOM "event listener" struct).
private final class JeffJSEventListenerRecord {
    let listener: JeffJSValue       // owned: function or object with handleEvent
    let capture: Bool
    let once: Bool
    let passive: Bool
    let signal: JeffJSValue?        // owned AbortSignal, or nil
    /// The DOM "removed" flag: set when the listener leaves its list, so a
    /// dispatch holding a cloned list skips it.
    private(set) var removed = false

    init(listener: JeffJSValue, capture: Bool, once: Bool, passive: Bool, signal: JeffJSValue?) {
        self.listener = listener
        self.capture = capture
        self.once = once
        self.passive = passive
        self.signal = signal
    }

    /// Marks the record removed and frees the values it owns. Idempotent.
    func release() {
        guard !removed else { return }
        removed = true
        listener.freeValue()
        signal?.freeValue()
    }
}

// MARK: - Listener Store

/// targetKey -> event type -> listener list (registration order).
private final class JeffJSEventListenerStore {
    private var store: [String: [String: [JeffJSEventListenerRecord]]] = [:]

    /// A snapshot (clone) of the listener list — what dispatch iterates.
    func handlers(for targetKey: String, type: String) -> [JeffJSEventListenerRecord] {
        store[targetKey]?[type] ?? []
    }

    func find(targetKey: String, type: String, listener: JeffJSValue, capture: Bool) -> JeffJSEventListenerRecord? {
        store[targetKey]?[type]?.first { $0.listener == listener && $0.capture == capture }
    }

    func append(targetKey: String, type: String, record: JeffJSEventListenerRecord) {
        store[targetKey, default: [:]][type, default: []].append(record)
    }

    /// Removes `record` from its list and releases it.
    func remove(_ record: JeffJSEventListenerRecord, targetKey: String, type: String) {
        record.release()
        guard var list = store[targetKey]?[type] else { return }
        list.removeAll { $0 === record }
        if list.isEmpty {
            store[targetKey]?.removeValue(forKey: type)
            if store[targetKey]?.isEmpty == true { store.removeValue(forKey: targetKey) }
        } else {
            store[targetKey]?[type] = list
        }
    }

    /// Removes and releases every listener registered on `targetKey`.
    func removeAll(for targetKey: String) {
        guard let typeMap = store.removeValue(forKey: targetKey) else { return }
        for (_, records) in typeMap { for rec in records { rec.release() } }
    }

    /// Number of targets with at least one listener (diagnostics / tests).
    var targetCount: Int { store.count }

    /// Removes and releases every listener.
    func removeAll() {
        let all = store
        store.removeAll()
        for (_, typeMap) in all {
            for (_, records) in typeMap { for rec in records { rec.release() } }
        }
    }
}

// MARK: - Dispatch Frame

/// State of one in-progress dispatch (DOM "dispatch flag" + event path).
private final class JeffJSEventDispatchFrame {
    let event: JeffJSValue          // owned
    let path: [JeffJSValue]         // owned
    /// > 0 while a passive listener runs ("in passive listener flag").
    var passiveDepth = 0

    init(event: JeffJSValue, path: [JeffJSValue]) {
        self.event = event
        self.path = path
    }

    func release() {
        event.freeValue()
        for v in path { v.freeValue() }
    }
}

// MARK: - JeffJSEventBridge

/// The engine's `EventTarget` implementation. Register it before the DOM
/// bridge so `document` and element wrappers can chain to
/// `EventTarget.prototype`:
/// ```swift
/// let eventBridge = JeffJSEventBridge()
/// eventBridge.register(on: ctx)
/// domBridge.eventBridge = eventBridge
/// domBridge.register(on: ctx)
/// ```
@MainActor
final class JeffJSEventBridge {

    private let listenerStore = JeffJSEventListenerStore()
    private var dispatchStack: [JeffJSEventDispatchFrame] = []

    /// Reference to the DOM bridge for node lookups (event path, target keys).
    weak var domBridge: JeffJSDOMBridge?

    /// Called when a JS event listener throws an exception.
    var onError: ((String) -> Void)?

    /// `EventTarget.prototype` (owned). `document` and the element prototype
    /// chain to it.
    private(set) var eventTargetPrototype: JeffJSValue?
    /// Prototype of events built natively by `dispatchFromTarget(event: nil)`
    /// (owned): the engine's `Event.prototype`, or a private object carrying
    /// the same methods when a host-defined `Event` was already installed.
    private var nativeEventPrototype: JeffJSValue?
    /// The shared native EventTarget methods (owned).
    private var addListenerFn: JeffJSValue?
    private var removeListenerFn: JeffJSValue?
    private var dispatchEventFn: JeffJSValue?

    // MARK: - Registration

    /// Installs `Event`, `CustomEvent`, `EventTarget`, window's EventTarget
    /// methods and `__nativeEventBridge` on the global object.
    func register(on ctx: JeffJSContext) {
        let global = ctx.getGlobalObject()
        defer { global.freeValue() }

        installEventTargetInterface(ctx: ctx, global: global)
        installNativeBridgeObject(ctx: ctx, global: global)
    }

    /// Frees every listener and the values the bridge owns. Call on page teardown.
    func teardown() {
        listenerStore.removeAll()
        for frame in dispatchStack { frame.release() }
        dispatchStack.removeAll()
        eventTargetPrototype?.freeValue(); eventTargetPrototype = nil
        nativeEventPrototype?.freeValue(); nativeEventPrototype = nil
        addListenerFn?.freeValue(); addListenerFn = nil
        removeListenerFn?.freeValue(); removeListenerFn = nil
        dispatchEventFn?.freeValue(); dispatchEventFn = nil
    }

    /// Number of event targets holding listeners (diagnostics / tests).
    var listenerTargetCount: Int { listenerStore.targetCount }

    /// Removes all listeners for a specific DOMNode UUID, freeing dup'd values.
    /// Called when the node is collected (see JeffJSDOMBridge.collectDetachedNodes);
    /// removal from the tree keeps them.
    func removeAllListeners(forNodeID nodeID: UUID) {
        listenerStore.removeAll(for: "node:\(nodeID.uuidString)")
    }

    // MARK: - Interface installation

    private static let constructorsSource = #"""
    (function (g) {
      // Strict: sloppy-mode constructors that read `arguments` leak their
      // mapped arguments object on `new` (engine bug, see the round notes).
      'use strict';
      var out = { event: null, target: null };
      var def = function (o, k, v) {
        Object.defineProperty(o, k, { value: v, writable: true, configurable: true, enumerable: false });
      };
      var now = function () {
        var p = g.performance;
        return (p && typeof p.now === 'function') ? p.now() : Date.now();
      };
      var phases = [['NONE', 0], ['CAPTURING_PHASE', 1], ['AT_TARGET', 2], ['BUBBLING_PHASE', 3]];

      var E = g.Event, ownEvent = false;
      if (!(typeof E === 'function' && E.prototype && typeof E.prototype.preventDefault === 'function')) {
        ownEvent = true;
        E = function Event(type, eventInitDict) {
          if (!(this instanceof E)) throw new TypeError("Failed to construct 'Event': Please use the 'new' operator, this DOM object constructor cannot be called as a function.");
          if (arguments.length < 1) throw new TypeError("Failed to construct 'Event': 1 argument required, but only 0 present.");
          var init = eventInitDict == null ? {} : eventInitDict;
          if (typeof init !== 'object' && typeof init !== 'function') throw new TypeError("Failed to construct 'Event': The provided value is not of type 'EventInit'.");
          this.type = String(type);
          this.bubbles = !!init.bubbles;
          this.cancelable = !!init.cancelable;
          this.composed = !!init.composed;
          this.defaultPrevented = false;
          this.cancelBubble = false;
          this.isTrusted = false;
          this.target = null;
          this.currentTarget = null;
          this.srcElement = null;
          this.eventPhase = 0;
          this.timeStamp = now();
          def(this, '__immediateStopped', false);
        };
        for (var i = 0; i < phases.length; i++) {
          Object.defineProperty(E, phases[i][0], { value: phases[i][1] });
          Object.defineProperty(E.prototype, phases[i][0], { value: phases[i][1] });
        }
        def(E.prototype, 'stopPropagation', function stopPropagation() { this.cancelBubble = true; });
        def(E.prototype, 'stopImmediatePropagation', function stopImmediatePropagation() {
          this.cancelBubble = true; this.__immediateStopped = true;
        });
        def(E.prototype, 'initEvent', function initEvent(type, bubbles, cancelable) {
          if (this.eventPhase !== 0) return;
          this.type = String(type); this.bubbles = !!bubbles; this.cancelable = !!cancelable;
          this.defaultPrevented = false; this.cancelBubble = false;
          this.__immediateStopped = false; this.target = null; this.srcElement = null;
        });
        // DOM §2.2 legacy `returnValue`: the negation of the canceled flag;
        // setting it to false cancels (same rules as preventDefault).
        Object.defineProperty(E.prototype, 'returnValue', {
          configurable: true, enumerable: true,
          get: function () { return !this.defaultPrevented; },
          set: function (v) { if (!v && !this.defaultPrevented) this.preventDefault(); }
        });
        // Marks the engine's Event as the real one, so host glue that tests
        // `Event.__jeffjsReal` keeps it (and the passive/composedPath logic
        // that lives in its native methods) instead of installing its own.
        Object.defineProperty(E, '__jeffjsReal', { value: true });
        g.Event = E;
        out.event = E.prototype;
      }

      var C = g.CustomEvent;
      if (!(typeof C === 'function' && C.prototype instanceof E)) {
        C = function CustomEvent(type, eventInitDict) {
          if (!(this instanceof C)) throw new TypeError("Failed to construct 'CustomEvent': Please use the 'new' operator, this DOM object constructor cannot be called as a function.");
          if (arguments.length < 1) throw new TypeError("Failed to construct 'CustomEvent': 1 argument required, but only 0 present.");
          E.call(this, type, eventInitDict);
          this.detail = (eventInitDict != null && eventInitDict.detail !== undefined) ? eventInitDict.detail : null;
        };
        C.prototype = Object.create(E.prototype);
        def(C.prototype, 'constructor', C);
        def(C.prototype, 'initCustomEvent', function initCustomEvent(type, bubbles, cancelable, detail) {
          if (this.eventPhase !== 0) return;
          this.initEvent(type, bubbles, cancelable);
          this.detail = detail === undefined ? null : detail;
        });
        g.CustomEvent = C;
      }

      // UI Events / HTML event interfaces over the engine's Event. Each
      // takes its init dictionary's members (unknown ones are ignored, as in
      // a browser). Only installed alongside the engine's own Event, and
      // never over an existing constructor.
      if (ownEvent) {
        var mk = function (name, Parent, defaults) {
          if (typeof g[name] === 'function') return g[name];
          var C = function (type, eventInitDict) {
            if (!(this instanceof C)) throw new TypeError("Failed to construct '" + name + "': Please use the 'new' operator, this DOM object constructor cannot be called as a function.");
            if (arguments.length < 1) throw new TypeError("Failed to construct '" + name + "': 1 argument required, but only 0 present.");
            Parent.call(this, type, eventInitDict);
            var init = (eventInitDict != null && typeof eventInitDict === 'object') ? eventInitDict : null;
            for (var k in defaults) {
              var d = defaults[k];
              this[k] = (init && init[k] !== undefined) ? init[k] : (Array.isArray(d) ? [] : d);
            }
          };
          Object.defineProperty(C, 'name', { value: name, configurable: true });
          C.prototype = Object.create(Parent.prototype);
          def(C.prototype, 'constructor', C);
          g[name] = C;
          return C;
        };
        var UI = mk('UIEvent', E, { view: null, detail: 0, which: 0 });
        var ME = mk('MouseEvent', UI, { screenX: 0, screenY: 0, clientX: 0, clientY: 0, pageX: 0, pageY: 0, offsetX: 0, offsetY: 0, x: 0, y: 0, movementX: 0, movementY: 0, ctrlKey: false, shiftKey: false, altKey: false, metaKey: false, button: 0, buttons: 0, relatedTarget: null });
        mk('PointerEvent', ME, { pointerId: 0, width: 1, height: 1, pressure: 0, tangentialPressure: 0, tiltX: 0, tiltY: 0, twist: 0, pointerType: '', isPrimary: false });
        mk('WheelEvent', ME, { deltaX: 0, deltaY: 0, deltaZ: 0, deltaMode: 0 });
        mk('DragEvent', ME, { dataTransfer: null });
        mk('KeyboardEvent', UI, { key: '', code: '', location: 0, ctrlKey: false, shiftKey: false, altKey: false, metaKey: false, repeat: false, isComposing: false, charCode: 0, keyCode: 0 });
        mk('InputEvent', UI, { data: null, isComposing: false, inputType: '', dataTransfer: null });
        mk('FocusEvent', UI, { relatedTarget: null });
        mk('TouchEvent', UI, { touches: [], targetTouches: [], changedTouches: [], ctrlKey: false, shiftKey: false, altKey: false, metaKey: false });
        mk('CompositionEvent', UI, { data: '' });
        mk('ErrorEvent', E, { message: '', filename: '', lineno: 0, colno: 0, error: null });
        mk('ProgressEvent', E, { lengthComputable: false, loaded: 0, total: 0 });
        mk('SubmitEvent', E, { submitter: null });
        mk('HashChangeEvent', E, { oldURL: '', newURL: '' });
        mk('PopStateEvent', E, { state: null });
        mk('PageTransitionEvent', E, { persisted: false });
        mk('TransitionEvent', E, { propertyName: '', elapsedTime: 0, pseudoElement: '' });
        mk('AnimationEvent', E, { animationName: '', elapsedTime: 0, pseudoElement: '' });
        mk('ClipboardEvent', E, { clipboardData: null });
        mk('MessageEvent', E, { data: null, origin: '', lastEventId: '', source: null, ports: [] });
        mk('StorageEvent', E, { key: null, oldValue: null, newValue: null, url: '', storageArea: null });
        mk('CloseEvent', E, { wasClean: false, code: 0, reason: '' });
        mk('PromiseRejectionEvent', E, { promise: null, reason: undefined });
        mk('MediaQueryListEvent', E, { media: '', matches: false });
        mk('BeforeUnloadEvent', E, {});
        mk('SecurityPolicyViolationEvent', E, { blockedURI: '', violatedDirective: '', effectiveDirective: '', originalPolicy: '', disposition: 'enforce', statusCode: 0 });
        mk('FormDataEvent', E, { formData: null });
        mk('ToggleEvent', E, { oldState: '', newState: '' });
        mk('AnimationPlaybackEvent', E, { currentTime: null, timelineTime: null });
        if (typeof g.Touch !== 'function') {
          g.Touch = function Touch(init) {
            init = init || {};
            var keys = ['identifier', 'target', 'clientX', 'clientY', 'screenX', 'screenY', 'pageX', 'pageY', 'radiusX', 'radiusY', 'rotationAngle', 'force'];
            for (var i = 0; i < keys.length; i++) this[keys[i]] = init[keys[i]] !== undefined ? init[keys[i]] : (keys[i] === 'target' ? null : 0);
          };
        }
      }

      var T = g.EventTarget;
      if (!(typeof T === 'function' && T.__jeffjsReal === true)) {
        T = function EventTarget() {
          if (!(this instanceof T)) throw new TypeError("Failed to construct 'EventTarget': Please use the 'new' operator, this DOM object constructor cannot be called as a function.");
        };
        Object.defineProperty(T, '__jeffjsReal', { value: true });
        g.EventTarget = T;
      }
      out.target = T.prototype;
      return out;
    })(this)
    """#

    private func installEventTargetInterface(ctx: JeffJSContext, global: JeffJSValue) {
        let out = ctx.eval(input: Self.constructorsSource, filename: "<event-target>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        if out.isException {
            reportExceptionIfNeeded(out, ctx: ctx, label: "EventTarget install")
            return
        }
        defer { out.freeValue() }

        // The shared EventTarget methods. `this` undefined/null (a bare
        // `addEventListener(...)` call) means the global object.
        let add = ctx.newCFunction({ [weak self] ctx, thisVal, args in
            guard let self else { return .undefined }
            guard args.count >= 2 else {
                return ctx.throwTypeError(message: "Failed to execute 'addEventListener' on 'EventTarget': 2 arguments required, but only \(args.count) present.")
            }
            let listener = args[1]
            if listener.isUndefined || listener.isNull { return .undefined }
            guard listener.isObject else {
                return ctx.throwTypeError(message: "Failed to execute 'addEventListener' on 'EventTarget': parameter 2 is not of type 'Object'.")
            }
            let global = ctx.getGlobalObject()
            defer { global.freeValue() }
            let target = thisVal.isObject ? thisVal : global
            self.addEventListener(ctx: ctx, target: target, type: args[0], listener: listener,
                                  options: args.count >= 3 ? args[2] : .undefined)
            return .undefined
        }, name: "addEventListener", length: 2)

        let remove = ctx.newCFunction({ [weak self] ctx, thisVal, args in
            guard let self else { return .undefined }
            guard args.count >= 2 else {
                return ctx.throwTypeError(message: "Failed to execute 'removeEventListener' on 'EventTarget': 2 arguments required, but only \(args.count) present.")
            }
            let global = ctx.getGlobalObject()
            defer { global.freeValue() }
            let target = thisVal.isObject ? thisVal : global
            self.removeEventListener(ctx: ctx, target: target, type: args[0], listener: args[1],
                                     options: args.count >= 3 ? args[2] : .undefined)
            return .undefined
        }, name: "removeEventListener", length: 2)

        let dispatch = ctx.newCFunction({ [weak self] ctx, thisVal, args in
            guard let self else { return .newBool(true) }
            guard let event = args.first else {
                return ctx.throwTypeError(message: "Failed to execute 'dispatchEvent' on 'EventTarget': 1 argument required, but only 0 present.")
            }
            let typeVal = event.isObject ? ctx.getPropertyStr(obj: event, name: "type") : JeffJSValue.undefined
            defer { typeVal.freeValue() }
            guard event.isObject, typeVal.isString, let type = ctx.toSwiftString(typeVal) else {
                return ctx.throwTypeError(message: "Failed to execute 'dispatchEvent' on 'EventTarget': parameter 1 is not of type 'Event'.")
            }
            if self.frame(for: event) != nil {
                return self.throwDOMException(ctx: ctx, name: "InvalidStateError",
                    message: "Failed to execute 'dispatchEvent' on 'EventTarget': The event is already being dispatched.")
            }
            let global = ctx.getGlobalObject()
            defer { global.freeValue() }
            let target = thisVal.isObject ? thisVal : global
            return .newBool(self.dispatch(ctx: ctx, target: target, event: event, type: type))
        }, name: "dispatchEvent", length: 1)

        addListenerFn = add
        removeListenerFn = remove
        dispatchEventFn = dispatch

        // EventTarget.prototype gets the methods; so does window (as own
        // properties: the global object's prototype is Object.prototype).
        let etProto = ctx.getPropertyStr(obj: out, name: "target")
        if etProto.isObject {
            installMethods(on: etProto, ctx: ctx)
            eventTargetPrototype = etProto
        } else {
            etProto.freeValue()
        }
        installMethods(on: global, ctx: ctx)

        // Event.prototype methods that need dispatch state.
        let evProto = ctx.getPropertyStr(obj: out, name: "event")
        let proto: JeffJSValue
        if evProto.isObject {
            proto = evProto
        } else {
            // A host Event was already installed; native events get a private
            // prototype with the same semantics.
            evProto.freeValue()
            proto = ctx.newObject()
            ctx.setPropertyFunc(obj: proto, name: "stopPropagation", fn: { ctx, thisVal, _ in
                ctx.setPropertyStr(obj: thisVal, name: "cancelBubble", value: .newBool(true))
                return .undefined
            }, length: 0)
            ctx.setPropertyFunc(obj: proto, name: "stopImmediatePropagation", fn: { ctx, thisVal, _ in
                ctx.setPropertyStr(obj: thisVal, name: "cancelBubble", value: .newBool(true))
                ctx.setPropertyStr(obj: thisVal, name: "__immediateStopped", value: .newBool(true))
                return .undefined
            }, length: 0)
        }
        ctx.setPropertyFunc(obj: proto, name: "preventDefault", fn: { [weak self] ctx, thisVal, _ in
            guard thisVal.isObject else { return .undefined }
            let cancelable = ctx.getPropertyStr(obj: thisVal, name: "cancelable")
            let isCancelable = ctx.toBool(cancelable)
            cancelable.freeValue()
            guard isCancelable else { return .undefined }
            if let frame = self?.frame(for: thisVal), frame.passiveDepth > 0 { return .undefined }
            ctx.setPropertyStr(obj: thisVal, name: "defaultPrevented", value: .newBool(true))
            ctx.setPropertyStr(obj: thisVal, name: "returnValue", value: .newBool(false))
            return .undefined
        }, length: 0)
        ctx.setPropertyFunc(obj: proto, name: "composedPath", fn: { [weak self] ctx, thisVal, _ in
            let arr = ctx.newArray()
            guard let frame = self?.frame(for: thisVal) else { return arr }
            for (i, v) in frame.path.enumerated() {
                _ = ctx.setPropertyUint32(obj: arr, index: UInt32(i), value: v.dupValue())
            }
            return arr
        }, length: 0)
        nativeEventPrototype = proto
    }

    /// Puts the shared EventTarget methods on `obj` as non-enumerable own
    /// properties.
    private func installMethods(on obj: JeffJSValue, ctx: JeffJSContext) {
        let methods: [(String, JeffJSValue?)] = [
            ("addEventListener", addListenerFn),
            ("removeEventListener", removeListenerFn),
            ("dispatchEvent", dispatchEventFn),
        ]
        for (name, fn) in methods {
            guard let fn else { continue }
            // definePropertyValue takes its own reference (the value is borrowed).
            let atom = ctx.rt.findAtom(name)
            _ = ctx.definePropertyValue(obj: obj, atom: atom, value: fn,
                                        flags: JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE)
            ctx.rt.freeAtom(atom)
        }
    }

    /// Host-facing `__nativeEventBridge`. The method names and argument orders
    /// are the app's contract — keep them stable.
    private func installNativeBridgeObject(ctx: JeffJSContext, global: JeffJSValue) {
        let bridge = ctx.newObject()

        // addEventListener(target, type, listener, options)
        ctx.setPropertyFunc(obj: bridge, name: "addEventListener", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 3 else { return .undefined }
            self.addEventListener(ctx: ctx, target: args[0], type: args[1], listener: args[2],
                                  options: args.count >= 4 ? args[3] : .undefined)
            return .undefined
        }, length: 4)

        // removeEventListener(target, type, listener, options)
        ctx.setPropertyFunc(obj: bridge, name: "removeEventListener", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 3 else { return .undefined }
            self.removeEventListener(ctx: ctx, target: args[0], type: args[1], listener: args[2],
                                     options: args.count >= 4 ? args[3] : .undefined)
            return .undefined
        }, length: 4)

        // dispatchEvent(target, event) -> bool
        ctx.setPropertyFunc(obj: bridge, name: "dispatchEvent", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 2 else { return .newBool(true) }
            return .newBool(self.dispatchEvent(ctx: ctx, target: args[0], event: args[1]))
        }, length: 2)

        // dispatchEventByName(target, type) -> bool
        ctx.setPropertyFunc(obj: bridge, name: "dispatchEventByName", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 2 else { return .newBool(true) }
            let typeStr = ctx.toSwiftString(args[1]) ?? ""
            guard !typeStr.isEmpty else { return .newBool(true) }
            return .newBool(self.dispatchFromTarget(ctx: ctx, target: args[0], type: typeStr, event: nil))
        }, length: 2)

        // dispatchClickSequence(target)
        ctx.setPropertyFunc(obj: bridge, name: "dispatchClickSequence", fn: { [weak self] ctx, _, args in
            guard let self, !args.isEmpty else { return .undefined }
            self.dispatchClickSequence(ctx: ctx, target: args[0])
            return .undefined
        }, length: 1)

        // dispatchEvents(target, typesArray)
        ctx.setPropertyFunc(obj: bridge, name: "dispatchEvents", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 2 else { return .undefined }
            self.dispatchEvents(ctx: ctx, target: args[0], types: args[1])
            return .undefined
        }, length: 2)

        // focus(target) / blur(target): the host's own focus changes (a native
        // text field became / stopped being first responder). Runs the HTML
        // focus update steps — blur/focusout, focus/focusin, activeElement —
        // without calling back into the host's `onFocusChange` hook.
        ctx.setPropertyFunc(obj: bridge, name: "focus", fn: { [weak self] ctx, _, args in
            guard let dom = self?.domBridge, let target = args.first,
                  let node = dom.extractNode(from: target) else { return .undefined }
            dom.hostFocusChanged(to: node, ctx: ctx)
            return .undefined
        }, length: 1)
        ctx.setPropertyFunc(obj: bridge, name: "blur", fn: { [weak self] ctx, _, args in
            guard let dom = self?.domBridge, let target = args.first,
                  let node = dom.extractNode(from: target) else { return .undefined }
            dom.hostBlurred(node, ctx: ctx)
            return .undefined
        }, length: 1)

        // click(target) -> bool: `HTMLElement.click()` (synthetic, untrusted
        // click + activation behaviour). False when a listener canceled it.
        ctx.setPropertyFunc(obj: bridge, name: "click", fn: { [weak self] ctx, _, args in
            guard let dom = self?.domBridge, let target = args.first,
                  let node = dom.extractNode(from: target) else { return .newBool(true) }
            return .newBool(dom.click(node, ctx: ctx))
        }, length: 1)

        ctx.setPropertyStr(obj: global, name: "__nativeEventBridge", value: bridge)
    }

    // MARK: - addEventListener

    func addEventListener(ctx: JeffJSContext, target: JeffJSValue, type: JeffJSValue, listener: JeffJSValue, options: JeffJSValue) {
        guard listener.isObject else { return }
        let typeStr = ctx.toSwiftString(type) ?? ""

        let (capture, once, passiveOption, signal) = parseListenerOptions(ctx: ctx, options: options)
        defer { signal?.freeValue() }

        if let signal, isAborted(ctx: ctx, signal) { return }

        let targetKey = eventTargetKey(ctx: ctx, value: target)
        // DOM §2.7 "default passive value" (the WebKit/Blink intervention):
        // touchstart/touchmove/wheel/mousewheel listeners on window, document,
        // the document element or the body are passive unless `passive` is given.
        let passive = passiveOption
            ?? (Self.defaultPassiveTypes.contains(typeStr) && isDefaultPassiveTarget(targetKey: targetKey, target: target))
        if let existing = listenerStore.find(targetKey: targetKey, type: typeStr, listener: listener, capture: capture) {
            // Same (type, callback, capture) is registered once — unless the
            // earlier registration's signal has aborted since (it is gone).
            guard let s = existing.signal, isAborted(ctx: ctx, s) else { return }
            listenerStore.remove(existing, targetKey: targetKey, type: typeStr)
        }

        let record = JeffJSEventListenerRecord(
            listener: listener.dupValue(),
            capture: capture,
            once: once,
            passive: passive,
            signal: signal?.dupValue()
        )
        listenerStore.append(targetKey: targetKey, type: typeStr, record: record)
    }

    // MARK: - removeEventListener

    func removeEventListener(ctx: JeffJSContext, target: JeffJSValue, type: JeffJSValue, listener: JeffJSValue, options: JeffJSValue) {
        guard listener.isObject else { return }
        let typeStr = ctx.toSwiftString(type) ?? ""
        let (capture, _, _, signal) = parseListenerOptions(ctx: ctx, options: options)
        signal?.freeValue()
        let targetKey = eventTargetKey(ctx: ctx, value: target)
        if let rec = listenerStore.find(targetKey: targetKey, type: typeStr, listener: listener, capture: capture) {
            listenerStore.remove(rec, targetKey: targetKey, type: typeStr)
        }
    }

    // MARK: - dispatchEvent (host API: lenient about the event object)

    func dispatchEvent(ctx: JeffJSContext, target: JeffJSValue, event: JeffJSValue) -> Bool {
        guard event.isObject else { return true }
        let typeVal = ctx.getPropertyStr(obj: event, name: "type")
        let type = ctx.toSwiftString(typeVal) ?? ""
        typeVal.freeValue()
        guard !type.isEmpty, frame(for: event) == nil else { return true }
        return dispatch(ctx: ctx, target: target, event: event, type: type)
    }

    // MARK: - dispatchClickSequence (internal for direct Swift calls)

    func dispatchClickSequence(ctx: JeffJSContext, target: JeffJSValue) {
        let types = ["touchstart", "pointerdown", "mousedown", "touchend", "pointerup", "mouseup", "tap", "click"]
        for type in types {
            _ = dispatchFromTarget(ctx: ctx, target: target, type: type, event: nil)
        }
    }

    // MARK: - dispatchEvents

    private func dispatchEvents(ctx: JeffJSContext, target: JeffJSValue, types: JeffJSValue) {
        guard types.isObject else { return }
        let lengthVal = ctx.getPropertyStr(obj: types, name: "length")
        guard let length = ctx.toInt32(lengthVal), length > 0 else { lengthVal.freeValue(); return }
        lengthVal.freeValue()
        for i in 0..<length {
            let item = ctx.getPropertyUint32(obj: types, index: UInt32(i))
            if let typeName = ctx.toSwiftString(item), !typeName.isEmpty {
                _ = dispatchFromTarget(ctx: ctx, target: target, type: typeName, event: nil)
            }
            item.freeValue()
        }
    }

    // MARK: - Event Dispatch (internal for direct Swift calls)

    /// Dispatches `event` (or, when nil / without a `type`, a native trusted
    /// event of `type` that bubbles and is cancelable) at `target`. Returns
    /// false if a listener canceled it.
    @discardableResult
    func dispatchFromTarget(ctx: JeffJSContext, target: JeffJSValue, type: String, event: JeffJSValue?) -> Bool {
        if let event, event.isObject {
            let typeVal = ctx.getPropertyStr(obj: event, name: "type")
            let existing = typeVal.isUndefined ? nil : ctx.toSwiftString(typeVal)
            typeVal.freeValue()
            if let existing {
                if frame(for: event) != nil { return true }
                return dispatch(ctx: ctx, target: target, event: event, type: existing)
            }
        }
        let built = buildEvent(ctx: ctx, type: type)
        defer { built.freeValue() }
        return dispatch(ctx: ctx, target: target, event: built, type: type)
    }

    /// DOM §2.9 "dispatch". `target` and `event` are borrowed.
    private func dispatch(ctx: JeffJSContext, target rawTarget: JeffJSValue, event: JeffJSValue, type: String) -> Bool {
        let global = ctx.getGlobalObject()
        defer { global.freeValue() }
        let target = rawTarget.isObject ? rawTarget : global

        let path = buildEventPath(ctx: ctx, from: target, global: global, type: type)
        let frame = JeffJSEventDispatchFrame(event: event.dupValue(), path: path)
        dispatchStack.append(frame)

        ctx.setPropertyStr(obj: event, name: "target", value: target.dupValue())
        ctx.setPropertyStr(obj: event, name: "srcElement", value: target.dupValue())
        let bubbles = readBool(ctx, event, "bubbles")

        // Capture: window -> ... -> parent (CAPTURING_PHASE), then the target's
        // capture listeners (AT_TARGET).
        for i in stride(from: path.count - 1, through: 0, by: -1) {
            setPhase(ctx, event, i == 0 ? 2 : 1)
            invoke(ctx: ctx, currentTarget: path[i], event: event, type: type, capturing: true, frame: frame)
        }
        // The target's non-capture listeners (AT_TARGET), then bubbling back up.
        for i in 0..<path.count {
            if i == 0 {
                setPhase(ctx, event, 2)
            } else {
                if !bubbles { break }
                setPhase(ctx, event, 3)
            }
            invoke(ctx: ctx, currentTarget: path[i], event: event, type: type, capturing: false, frame: frame)
        }

        // Dispatch done: phase NONE, no currentTarget, stop flags cleared.
        setPhase(ctx, event, 0)
        ctx.setPropertyStr(obj: event, name: "currentTarget", value: .null)
        if readBool(ctx, event, "cancelBubble") {
            ctx.setPropertyStr(obj: event, name: "cancelBubble", value: .newBool(false))
        }
        if readBool(ctx, event, "__immediateStopped") {
            ctx.setPropertyStr(obj: event, name: "__immediateStopped", value: .newBool(false))
        }
        let notCanceled = !readBool(ctx, event, "defaultPrevented")

        if let idx = dispatchStack.lastIndex(where: { $0 === frame }) { dispatchStack.remove(at: idx) }
        frame.release()
        return notCanceled
    }

    /// DOM §2.9 "invoke" + "inner invoke" for one path entry and one pass.
    private func invoke(ctx: JeffJSContext, currentTarget: JeffJSValue, event: JeffJSValue, type: String,
                        capturing: Bool, frame: JeffJSEventDispatchFrame) {
        if readBool(ctx, event, "cancelBubble") { return }
        ctx.setPropertyStr(obj: event, name: "currentTarget", value: currentTarget.dupValue())

        let targetKey = eventTargetKey(ctx: ctx, value: currentTarget)
        // Clone the list: listeners added from here on do not run for this target.
        let records = listenerStore.handlers(for: targetKey, type: type)

        // The `on<type>` event handler attribute acts as a non-capture listener.
        if !capturing {
            let handler = ctx.getPropertyStr(obj: currentTarget, name: "on\(type)")
            if handler.isFunction {
                let r = ctx.call(handler, this: currentTarget, args: [event])
                reportExceptionIfNeeded(r, ctx: ctx, label: "on\(type) handler")
                // HTML §8.1.8.1 "the event handler processing algorithm": a
                // return value of false cancels the event (true for window's
                // onerror, an OnErrorEventHandler).
                if r.isBool {
                    let windowError = type == "error" && eventTargetKey(ctx: ctx, value: currentTarget) == "window"
                    if r.toBool() == windowError {
                        let pd = ctx.getPropertyStr(obj: event, name: "preventDefault")
                        if pd.isFunction { ctx.call(pd, this: event, args: []).freeValue() }
                        pd.freeValue()
                    }
                }
                r.freeValue()
            } else if handler.isException {
                reportExceptionIfNeeded(handler, ctx: ctx, label: "on\(type) handler")
            }
            handler.freeValue()
            if readBool(ctx, event, "__immediateStopped") { return }
        }

        for record in records {
            if record.removed { continue }
            if capturing != record.capture { continue }
            if let signal = record.signal, isAborted(ctx: ctx, signal) {
                listenerStore.remove(record, targetKey: targetKey, type: type)
                continue
            }

            // Keep the listener alive across the call: it may remove itself.
            let listener = record.listener.dupValue()
            if record.once {
                listenerStore.remove(record, targetKey: targetKey, type: type)
            }

            var preventedBefore = false
            if record.passive {
                frame.passiveDepth += 1
                preventedBefore = readBool(ctx, event, "defaultPrevented")
            }

            if listener.isFunction {
                let r = ctx.call(listener, this: currentTarget, args: [event])
                reportExceptionIfNeeded(r, ctx: ctx, label: "\(type) listener")
                r.freeValue()
            } else {
                // EventListener object: call its handleEvent with this = the object.
                let handleEvent = ctx.getPropertyStr(obj: listener, name: "handleEvent")
                if handleEvent.isException {
                    reportExceptionIfNeeded(handleEvent, ctx: ctx, label: "\(type) listener")
                } else if handleEvent.isFunction {
                    let r = ctx.call(handleEvent, this: listener, args: [event])
                    reportExceptionIfNeeded(r, ctx: ctx, label: "\(type) listener")
                    r.freeValue()
                } else {
                    onError?("[JeffJS] \(type) listener: TypeError: The listener object has no callable handleEvent")
                }
                handleEvent.freeValue()
            }
            listener.freeValue()

            if record.passive {
                frame.passiveDepth -= 1
                // Script-defined preventDefault implementations do not know
                // about passive listeners: undo a cancelation made in one.
                if !preventedBefore && readBool(ctx, event, "defaultPrevented") {
                    ctx.setPropertyStr(obj: event, name: "defaultPrevented", value: .newBool(false))
                    ctx.setPropertyStr(obj: event, name: "returnValue", value: .newBool(true))
                }
            }

            if readBool(ctx, event, "__immediateStopped") { return }
        }
    }

    // MARK: - Dispatch helpers

    private func frame(for event: JeffJSValue) -> JeffJSEventDispatchFrame? {
        guard event.isObject else { return nil }
        return dispatchStack.last { $0.event == event }
    }

    private func readBool(_ ctx: JeffJSContext, _ obj: JeffJSValue, _ name: String) -> Bool {
        let v = ctx.getPropertyStr(obj: obj, name: name)
        if v.isException {
            ctx.getException().freeValue()
            return false
        }
        let b = ctx.toBool(v)
        v.freeValue()
        return b
    }

    private func setPhase(_ ctx: JeffJSContext, _ event: JeffJSValue, _ phase: Int32) {
        ctx.setPropertyStr(obj: event, name: "eventPhase", value: .newInt32(phase))
    }

    private func isAborted(ctx: JeffJSContext, _ signal: JeffJSValue) -> Bool {
        guard signal.isObject else { return false }
        return readBool(ctx, signal, "aborted")
    }

    private func throwDOMException(ctx: JeffJSContext, name: String, message: String) -> JeffJSValue {
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

    // MARK: - Error Reporting

    private func reportExceptionIfNeeded(_ result: JeffJSValue, ctx: JeffJSContext, label: String) {
        guard result.isException else { return }
        let exc = ctx.getException()
        var errMsg = "Unknown error"
        if ctx.isError(exc) {
            let nameVal = ctx.getPropertyStr(obj: exc, name: "name")
            let msgVal = ctx.getPropertyStr(obj: exc, name: "message")
            let stackVal = ctx.getPropertyStr(obj: exc, name: "stack")
            let name = ctx.toSwiftString(nameVal) ?? "Error"
            let message = ctx.toSwiftString(msgVal) ?? ""
            let stack = ctx.toSwiftString(stackVal)
            nameVal.freeValue()
            msgVal.freeValue()
            stackVal.freeValue()
            errMsg = message.isEmpty ? name : "\(name): \(message)"
            if let stack, !stack.isEmpty {
                errMsg += "\n\(stack)"
            }
        } else if let str = ctx.toSwiftString(exc) {
            errMsg = str
        }
        exc.freeValue()
        onError?("[JeffJS] \(label): \(errMsg)")
    }

    // MARK: - Event Path

    /// The event path (all values owned): the target; for a node, its
    /// ancestors; and for a node in the page document, `document` then
    /// `window`. `document`'s path is [document, window]; `window`'s and any
    /// non-node target's is just the target.
    ///
    /// HTML §7.2.1 (Document's "get the parent"): a `load` event stops at the
    /// document — a `<script>`/`<img>`/`<iframe>` load never reaches window's
    /// capture listeners. It used to: web-vitals' `whenReady` (netflix.com)
    /// re-registers a capturing window `load` listener every time one fires
    /// before `readyState` is "complete", so each subresource load doubled
    /// them — a 60 s+ main-thread hang and gigabytes of closures.
    private func buildEventPath(ctx: JeffJSContext, from target: JeffJSValue, global: JeffJSValue,
                                type: String = "") -> [JeffJSValue] {
        var path: [JeffJSValue] = [target.dupValue()]
        if target == global { return path }
        let reachesWindow = type != "load"

        let docVal = documentValue(ctx: ctx, global: global)
        defer { docVal?.freeValue() }
        if let docVal, target == docVal {
            if reachesWindow { path.append(global.dupValue()) }
            return path
        }

        guard let dom = domBridge, let node = dom.extractNode(from: target) else { return path }
        if node === dom.root {
            if reachesWindow { path.append(global.dupValue()) }
            return path
        }
        var cursor = node.parent
        while let ancestor = cursor {
            if ancestor === dom.root {
                if let docVal {
                    path.append(docVal.dupValue())
                    if reachesWindow { path.append(global.dupValue()) }
                }
                break
            }
            path.append(dom.wrapElement(ancestor, ctx: ctx))
            cursor = ancestor.parent
        }
        return path
    }

    /// The page `document` (owned), preferring the DOM bridge's own reference.
    private func documentValue(ctx: JeffJSContext, global: JeffJSValue) -> JeffJSValue? {
        if let doc = domBridge?.documentJSValue { return doc.dupValue() }
        let doc = ctx.getPropertyStr(obj: global, name: "document")
        if doc.isObject { return doc }
        doc.freeValue()
        return nil
    }

    // MARK: - Event Object Builder

    /// A native trusted event (bubbles, cancelable) for host-generated input.
    private func buildEvent(ctx: JeffJSContext, type: String) -> JeffJSValue {
        let event = nativeEventPrototype.map { ctx.newObjectProto(proto: $0) } ?? ctx.newObject()
        ctx.setPropertyStr(obj: event, name: "type", value: ctx.newStringValue(type))
        ctx.setPropertyStr(obj: event, name: "target", value: .null)
        ctx.setPropertyStr(obj: event, name: "currentTarget", value: .null)
        ctx.setPropertyStr(obj: event, name: "defaultPrevented", value: .newBool(false))
        ctx.setPropertyStr(obj: event, name: "cancelBubble", value: .newBool(false))
        ctx.setPropertyStr(obj: event, name: "returnValue", value: .newBool(true))
        ctx.setPropertyStr(obj: event, name: "bubbles", value: .newBool(true))
        ctx.setPropertyStr(obj: event, name: "cancelable", value: .newBool(true))
        ctx.setPropertyStr(obj: event, name: "composed", value: .newBool(false))
        ctx.setPropertyStr(obj: event, name: "isTrusted", value: .newBool(true))
        ctx.setPropertyStr(obj: event, name: "eventPhase", value: .newInt32(0))
        let atom = ctx.rt.findAtom("__immediateStopped")
        _ = ctx.definePropertyValue(obj: event, atom: atom, value: .newBool(false),
                                    flags: JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE)
        ctx.rt.freeAtom(atom)
        // Mouse/pointer event properties — React 18 checks event.button === 0
        ctx.setPropertyStr(obj: event, name: "button", value: .newInt32(0))
        ctx.setPropertyStr(obj: event, name: "buttons", value: .newInt32(1))
        ctx.setPropertyStr(obj: event, name: "clientX", value: .newInt32(0))
        ctx.setPropertyStr(obj: event, name: "clientY", value: .newInt32(0))
        ctx.setPropertyStr(obj: event, name: "pageX", value: .newInt32(0))
        ctx.setPropertyStr(obj: event, name: "pageY", value: .newInt32(0))
        ctx.setPropertyStr(obj: event, name: "screenX", value: .newInt32(0))
        ctx.setPropertyStr(obj: event, name: "screenY", value: .newInt32(0))
        ctx.setPropertyStr(obj: event, name: "detail", value: .newInt32(1))
        ctx.setPropertyStr(obj: event, name: "which", value: .newInt32(1))
        ctx.setPropertyStr(obj: event, name: "timeStamp", value: .newFloat64(Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000))
        return event
    }

    // MARK: - Options Parsing

    /// Flattens `options` (boolean capture, or {capture, once, passive,
    /// signal}). The returned signal is owned by the caller.
    private func parseListenerOptions(ctx: JeffJSContext, options: JeffJSValue) -> (capture: Bool, once: Bool, passive: Bool?, signal: JeffJSValue?) {
        guard options.isObject else {
            return (ctx.toBool(options), false, nil, nil)
        }
        let capture = readBool(ctx, options, "capture")
        let once = readBool(ctx, options, "once")
        // nil when the dictionary does not say (the default passive value applies).
        let passiveVal = ctx.getPropertyStr(obj: options, name: "passive")
        if passiveVal.isException { ctx.getException().freeValue() }
        let passive: Bool? = (passiveVal.isUndefined || passiveVal.isException) ? nil : ctx.toBool(passiveVal)
        passiveVal.freeValue()
        let signal = ctx.getPropertyStr(obj: options, name: "signal")
        if signal.isObject { return (capture, once, passive, signal) }
        if signal.isException { ctx.getException().freeValue() }
        signal.freeValue()
        return (capture, once, passive, nil)
    }

    /// Event types whose listeners default to passive on the document-level
    /// targets (DOM §2.7 "default passive value").
    private static let defaultPassiveTypes: Set<String> = ["touchstart", "touchmove", "wheel", "mousewheel"]

    /// window, document, or the page document's `<html>` / `<body>`.
    private func isDefaultPassiveTarget(targetKey: String, target: JeffJSValue) -> Bool {
        if targetKey == "window" || targetKey == "document" { return true }
        guard let dom = domBridge, let node = dom.extractNode(from: target),
              node.nodeType == .element, node.isHTMLNamespace, let parent = node.parent else { return false }
        switch node.tagName {
        case "html": return parent === dom.root
        case "body": return parent.tagName == "html" && parent.parent === dom.root
        default: return false
        }
    }

    // MARK: - Target Key

    /// A stable key for an event target: "window", "document", "node:<uuid>"
    /// for DOM wrappers, or a generated key stored (non-enumerable) on any
    /// other object.
    private func eventTargetKey(ctx: JeffJSContext, value: JeffJSValue) -> String {
        guard value.isObject else { return "window" }

        if let dom = domBridge, let node = dom.extractNode(from: value) {
            return node === dom.root ? "document" : "node:\(node.id.uuidString)"
        }

        let global = ctx.getGlobalObject()
        let isWindow = (value == global)
        if isWindow { global.freeValue(); return "window" }
        let doc = documentValue(ctx: ctx, global: global)
        global.freeValue()
        let isDoc = doc.map { $0 == value } ?? false
        doc?.freeValue()
        if isDoc { return "document" }

        // Wrappers whose payload is not a DOMNode but that carry one's id.
        let nodeID = ctx.getPropertyStr(obj: value, name: "nativeNodeID")
        if nodeID.isString, let idStr = ctx.toSwiftString(nodeID) {
            nodeID.freeValue()
            return "node:\(idStr)"
        }
        if nodeID.isException { ctx.getException().freeValue() }
        nodeID.freeValue()

        // The key must be an *own* property: read through the prototype chain,
        // every object inheriting from a keyed one (Closure/reCAPTCHA event
        // targets, `Object.create(target)`) shared its listener list — dispatch
        // on one ran them all, and handlers that re-register grew the list
        // quadratically (netflix.com hung 60+ s).
        let atom = ctx.rt.findAtom("__nativeEventTargetKey")
        if let obj = value.toObject() {
            let own = obj.getOwnPropertyValue(atom: atom)
            if own.isString, let key = ctx.toSwiftString(own) {
                ctx.rt.freeAtom(atom)
                return key
            }
        }

        let newKey = "object:\(UUID().uuidString)"
        let keyVal = ctx.newStringValue(newKey)
        _ = ctx.definePropertyValue(obj: value, atom: atom, value: keyVal, flags: JS_PROP_CONFIGURABLE)
        keyVal.freeValue()   // borrowed by definePropertyValue
        ctx.rt.freeAtom(atom)
        return newKey
    }
}
