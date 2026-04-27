// JeffJSEnvironment.swift
// Standalone JeffJS execution environment.
//
// Creates a JeffJS runtime + context, registers all bridges (DOM, events,
// fetch, storage, WebSocket, IndexedDB, video, Web APIs), evaluates
// polyfills, and installs GCD-backed timers.
//
// Extracted from JSScriptEngine.swift's JeffJS initialization path.

import Foundation

// MARK: - Eval Result

/// Result of evaluating JavaScript in a JeffJSEnvironment.
public enum JeffJSEvalResult {
    case success(String?)
    case exception(String)
}

// MARK: - JeffJSEnvironment

/// A self-contained JeffJS execution environment with DOM, event, and
/// networking bridges pre-registered. Creates a runtime, context, and
/// empty document on init.
///
/// Usage:
/// ```swift
/// let env = JeffJSEnvironment()
/// env.onConsoleMessage = { level, msg in print("[\(level)] \(msg)") }
/// let result = env.eval("document.createElement('div').tagName")
/// ```
@MainActor
public final class JeffJSEnvironment {

    // MARK: - Public Configuration

    /// Configuration for the JeffJS environment.
    public struct Configuration {
        public var baseURL: URL
        public var userAgent: String
        public var viewportWidth: Double
        public var viewportHeight: Double
        public var devicePixelRatio: Double
        public var storageScope: String
        public var videoProvider: JeffJSVideoProvider?
        public var dynamicImportDelegate: JeffJSDynamicImportDelegate?
        /// Additional polyfill JS to evaluate after the built-in polyfills.
        public var additionalPolyfills: [String]
        /// JavaScript to evaluate after init (e.g. helper functions on window).
        public var startupScripts: [String]

        public init(
            baseURL: URL = URL(string: "about:blank")!,
            userAgent: String = "JeffJS/1.0",
            viewportWidth: Double = 390,
            viewportHeight: Double = 844,
            devicePixelRatio: Double = 3,
            storageScope: String = "jeffjs",
            videoProvider: JeffJSVideoProvider? = nil,
            dynamicImportDelegate: JeffJSDynamicImportDelegate? = nil,
            additionalPolyfills: [String] = [],
            startupScripts: [String] = []
        ) {
            self.baseURL = baseURL
            self.userAgent = userAgent
            self.viewportWidth = viewportWidth
            self.viewportHeight = viewportHeight
            self.devicePixelRatio = devicePixelRatio
            self.storageScope = storageScope
            self.videoProvider = videoProvider
            self.dynamicImportDelegate = dynamicImportDelegate
            self.additionalPolyfills = additionalPolyfills
            self.startupScripts = startupScripts
        }
    }

    // MARK: - State

    private(set) var runtime: JeffJSRuntime
    private(set) var context: JeffJSContext
    public private(set) var document: DOMNode
    private(set) var domBridge: JeffJSDOMBridge?
    private(set) var eventBridge: JeffJSEventBridge?
    private(set) var fetchBridge: JeffJSFetchBridge?
    private(set) var webSocketBridge: JeffJSWebSocketBridge?
    private(set) var storageBridge: JeffJSStorageBridge?
    private(set) var indexedDBBridge: JeffJSIndexedDBBridge?
    private(set) var videoBridge: JeffJSVideoBridge?
    private(set) var webAPIsBridge: JeffJSWebAPIsBridge?
    private(set) var dynamicImportBridge: JeffJSDynamicImportBridge?
    private(set) var quantumBridge: JeffJSQuantumBridge?

    // MARK: - Callbacks

    /// Called when JS console.log/warn/error/etc fires.
    public var onConsoleMessage: ((_ level: String, _ message: String) -> Void)?
    /// Called when JS mutates the DOM tree (node IDs that changed).
    public var onDOMMutation: ((_ mutatedNodeIDs: Set<UUID>) -> Void)?
    /// Called when JS executes a dynamic script node.
    public var onScriptExecution: ((_ scriptNode: DOMNode) -> Void)?
    /// Called to look up computed style values for getComputedStyle().
    public var computedStyleLookup: ((_ nodeID: UUID, _ property: String) -> String?)?
    /// Called when JS changes window.location.
    public var onLocationChange: ((_ newURL: String) -> Void)?

    // MARK: - Timer State

    private var timerNextID: Int = 1
    private var timerCallbacks: [Int: JeffJSValue] = [:]
    private var timeoutItems: [Int: DispatchWorkItem] = [:]
    private var intervalTimers: [Int: DispatchSourceTimer] = [:]
    private let configuration: Configuration
    /// Retained so the weak delegate reference in the bridge stays alive.
    private var _defaultImportDelegate: DefaultDynamicImportDelegate?

    /// Names of every globalThis own property at the moment env init returned.
    /// Used by `snapshotUserGlobals` / `clearUserGlobals` to distinguish the
    /// engine's built-in surface from properties the user later added.
    private var baselineGlobalKeys: [String] = []

    // MARK: - Init

    /// Creates a new JeffJS environment with all bridges registered.
    public init(configuration: Configuration = .init()) {
        self.configuration = configuration

        // 1. Create runtime and context
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        self.runtime = rt
        self.context = ctx

        // 2. Create empty document
        let doc = DOMNode.document()
        let html = DOMNode.element(tag: "html")
        let head = DOMNode.element(tag: "head")
        let body = DOMNode.element(tag: "body")
        html.appendChild(head)
        html.appendChild(body)
        doc.appendChild(html)
        self.document = doc

        // 3. Evaluate init script
        let initResult = ctx.eval(input: Self.initScript, filename: "<init>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        initResult.freeValue()

        // 4. Register standard library (console, timers, performance, URL, etc.)
        JeffJSStdLib.addIntrinsics(ctx: ctx)

        // 5. Wire console output
        JeffJSStdLib.setConsoleCallback(ctx: ctx) { [weak self] level, message in
            if Thread.isMainThread {
                self?.onConsoleMessage?(level, message)
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.onConsoleMessage?(level, message)
                }
            }
        }

        // 6. Register native computed style lookup
        let global = ctx.getGlobalObject()
        ctx.setPropertyFunc(obj: global, name: "__nativeGetComputedStyleValue", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 2 else { return ctx.newStringValue("") }
            guard let nodeIdStr = ctx.toSwiftString(args[0]),
                  let property = ctx.toSwiftString(args[1]),
                  let uuid = UUID(uuidString: nodeIdStr) else {
                return ctx.newStringValue("")
            }
            let value = self.computedStyleLookup?(uuid, property) ?? ""
            return ctx.newStringValue(value)
        }, length: 2)

        // 7. Register native location change callback
        ctx.setPropertyFunc(obj: global, name: "__nativeLocationDidChange", fn: { [weak self] ctx, _, args in
            if let self, args.count >= 1, let newURL = ctx.toSwiftString(args[0]) {
                self.onLocationChange?(newURL)
            }
            return JeffJSValue.undefined
        }, length: 1)

        // 8. Register DOM bridge
        let domBridge = JeffJSDOMBridge(
            root: doc,
            baseURL: configuration.baseURL,
            onMutated: { [weak self] mutatedNodeIDs in
                Task { @MainActor in
                    self?.onDOMMutation?(mutatedNodeIDs)
                }
            },
            onScriptExecution: { [weak self] scriptNode in
                self?.onScriptExecution?(scriptNode)
            }
        )
        domBridge.onError = { [weak self] msg in
            self?.onConsoleMessage?("error", msg)
        }

        // 9. Register event bridge
        let evtBridge = JeffJSEventBridge()
        evtBridge.domBridge = domBridge
        evtBridge.onError = { [weak self] msg in
            self?.onConsoleMessage?("error", msg)
        }
        evtBridge.register(on: ctx)
        self.eventBridge = evtBridge

        domBridge.eventBridge = evtBridge
        domBridge.register(on: ctx)
        self.domBridge = domBridge

        // 10. Register storage bridge
        let storageBridge = JeffJSStorageBridge(scope: configuration.storageScope)
        storageBridge.register(on: ctx)
        self.storageBridge = storageBridge

        // 11. Register fetch bridge
        let fetchBridge = JeffJSFetchBridge(userAgent: configuration.userAgent)
        fetchBridge.baseURL = configuration.baseURL
        fetchBridge.onConsoleLog = { [weak self] level, message in
            self?.onConsoleMessage?(level, message)
        }
        fetchBridge.register(on: ctx)
        self.fetchBridge = fetchBridge

        // 12. Register WebSocket bridge
        let wsBridge = JeffJSWebSocketBridge()
        wsBridge.register(on: ctx)
        self.webSocketBridge = wsBridge

        // 13. Register IndexedDB bridge
        let idbBridge = JeffJSIndexedDBBridge(scope: configuration.storageScope)
        idbBridge.register(on: ctx)
        self.indexedDBBridge = idbBridge

        // 14. Register video bridge
        let videoBridge = JeffJSVideoBridge(provider: configuration.videoProvider)
        videoBridge.register(on: ctx)
        self.videoBridge = videoBridge

        // 15. Register dynamic import bridge
        let dynDelegate = configuration.dynamicImportDelegate ?? DefaultDynamicImportDelegate(
            baseURL: configuration.baseURL,
            userAgent: configuration.userAgent,
            context: ctx
        )
        let dynBridge = JeffJSDynamicImportBridge(delegate: dynDelegate)
        dynBridge.register(on: ctx)
        self.dynamicImportBridge = dynBridge
        self._defaultImportDelegate = dynDelegate as? DefaultDynamicImportDelegate

        // 16. Register Web APIs bridge (performance, crypto, TextEncoder, MessageChannel)
        let webAPIs = JeffJSWebAPIsBridge()
        webAPIs.register(on: ctx)
        self.webAPIsBridge = webAPIs

        // 17. Register quantum bridge (window.jeffjs.quantum) — always on
        let quantumBridge = JeffJSQuantumBridge()
        quantumBridge.register(on: ctx)
        self.quantumBridge = quantumBridge

        // 18. Evaluate built-in polyfills
        evaluatePolyfills()

        // 19. Install GCD-backed timers (replaces StdLib polling timers)
        installGCDTimers()

        // 20. Evaluate startup scripts
        for script in configuration.startupScripts {
            let r = ctx.eval(input: script, filename: "<startup>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            r.freeValue()
        }
        _ = runtime.executePendingJobs()

        // 21. Capture the built-in global surface so user-added keys can be
        //     diffed out later by snapshotUserGlobals() / clearUserGlobals().
        self.baselineGlobalKeys = captureBaselineGlobals()
    }

    /// Evaluate `listGlobalsScript` once and decode its JSON array result.
    /// Called from init() after every built-in is in place.
    private func captureBaselineGlobals() -> [String] {
        let result = context.eval(input: JeffJSGlobalSnapshot.listGlobalsScript,
                                  filename: "<baseline-capture>",
                                  evalFlags: JS_EVAL_TYPE_GLOBAL)
        defer { result.freeValue() }
        guard !result.isException,
              let json = context.toSwiftString(result),
              let data = json.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return names
    }

    // MARK: - Evaluation

    /// Evaluate JavaScript source code and return the result.
    @discardableResult
    public func eval(_ source: String, filename: String = "<eval>") -> JeffJSEvalResult {
        let result = context.eval(input: source, filename: filename, evalFlags: JS_EVAL_TYPE_GLOBAL)
        if result.isException {
            let exc = context.getException()
            let errMsg = context.toSwiftString(exc) ?? "unknown error"
            exc.freeValue()
            drainJobs()
            return .exception(errMsg)
        } else {
            let str = context.toSwiftString(result)
            result.freeValue()
            drainJobs()
            return .success(str)
        }
    }

    /// Evaluate JavaScript that may contain async operations (import, fetch).
    /// Waits up to `timeout` seconds for pending promises to settle.
    public func evalAsync(_ source: String, filename: String = "<eval>", timeout: TimeInterval = 10) async -> JeffJSEvalResult {
        let result = eval(source, filename: filename)
        // Give async operations (fetch, import) time to complete
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            drainJobs()
            // Check if there are pending async tasks (fetches, imports)
            let pending = (fetchBridge?.activeCount ?? 0) > 0 || runtime.isJobPending()
            if !pending { break }
            // Yield to let network callbacks fire
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            drainJobs()
        }
        return result
    }

    /// Drain the microtask/job queue.
    public func drainJobs() {
        _ = runtime.executePendingJobs()
    }

    // MARK: - Autocomplete

    /// Returns property name completions for a JS object expression.
    /// e.g. `consoleCompletions(objectExpr: "document", partial: "get")`
    /// returns `["getElementById", "getElementsByClassName", ...]`
    public func consoleCompletions(objectExpr: String, partial: String) -> [String] {
        let script = """
        (function() {
          try {
            var obj = \(objectExpr);
            var seen = {};
            var keys = [];
            var cur = obj;
            while (cur != null) {
              var names = Object.getOwnPropertyNames(cur);
              for (var i = 0; i < names.length; i++) {
                if (!seen[names[i]]) { seen[names[i]] = true; keys.push(names[i]); }
              }
              cur = Object.getPrototypeOf(cur);
            }
            return keys;
          } catch(e) { return []; }
        })()
        """
        let ctx = context
        let result = ctx.eval(input: script, filename: "<completions>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        defer { result.freeValue() }
        guard !result.isException else { return [] }

        let lenVal = ctx.getPropertyStr(obj: result, name: "length")
        let len = ctx.toInt32(lenVal) ?? 0
        lenVal.freeValue()

        var keys: [String] = []
        for i in 0..<len {
            let elem = ctx.getPropertyUint32(obj: result, index: UInt32(i))
            if let s = ctx.toSwiftString(elem) { keys.append(s) }
            elem.freeValue()
        }

        let lowerPartial = partial.lowercased()
        var matched = keys.filter { key in
            !key.isEmpty && (partial.isEmpty || key.lowercased().hasPrefix(lowerPartial))
        }
        matched.sort { a, b in
            let aStart = a.hasPrefix(partial)
            let bStart = b.hasPrefix(partial)
            if aStart != bStart { return aStart }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        return matched
    }

    // MARK: - User Globals Snapshot

    /// Serialize every user-added globalThis own property to a JSON blob.
    /// Functions, DOM nodes, native objects, getters/setters, and class
    /// instances are skipped — their names are returned in `skipped` so the
    /// caller can surface them in the UI.
    ///
    /// The blob is opaque from Swift's POV; pass it back to
    /// `restoreUserGlobals(from:)` on a fresh environment to rehydrate.
    public func snapshotUserGlobals() -> JeffJSSnapshotResult {
        let baselineLiteral = JeffJSGlobalSnapshot.jsArrayLiteral(baselineGlobalKeys)
        // Invoke the script as a function expression so the baseline list
        // never leaks into globalThis as a `var`.
        let script = "(\(JeffJSGlobalSnapshot.serializeScript))(\(baselineLiteral))"
        let result = context.eval(input: script,
                                  filename: "<snapshot-serialize>",
                                  evalFlags: JS_EVAL_TYPE_GLOBAL)
        defer { result.freeValue() }
        guard !result.isException, let json = context.toSwiftString(result) else {
            return JeffJSSnapshotResult(json: "{\"keys\":{},\"skipped\":[]}", skipped: [])
        }
        let skipped = JeffJSGlobalSnapshot.decodeSkipped(from: json)
        return JeffJSSnapshotResult(json: json, skipped: skipped)
    }

    /// Restore user globals from a blob produced by `snapshotUserGlobals()`.
    /// Writes values directly onto globalThis — no commands are replayed, so
    /// side effects in the original code do not re-fire.
    @discardableResult
    public func restoreUserGlobals(from json: String) -> JeffJSRestoreResult {
        let blobLiteral = JeffJSGlobalSnapshot.jsStringLiteral(json)
        let script = "(\(JeffJSGlobalSnapshot.restoreScript))(\(blobLiteral))"
        let result = context.eval(input: script,
                                  filename: "<snapshot-restore>",
                                  evalFlags: JS_EVAL_TYPE_GLOBAL)
        defer { result.freeValue() }
        guard !result.isException else {
            return JeffJSRestoreResult(restored: 0)
        }
        let count = Int(context.toInt32(result) ?? 0)
        return JeffJSRestoreResult(restored: count)
    }

    /// Delete every globalThis own property added since env init. Returns the
    /// number of keys removed. Built-in globals are untouched.
    @discardableResult
    public func clearUserGlobals() -> Int {
        let baselineLiteral = JeffJSGlobalSnapshot.jsArrayLiteral(baselineGlobalKeys)
        let script = "(\(JeffJSGlobalSnapshot.clearScript))(\(baselineLiteral))"
        let result = context.eval(input: script,
                                  filename: "<snapshot-clear>",
                                  evalFlags: JS_EVAL_TYPE_GLOBAL)
        defer { result.freeValue() }
        guard !result.isException else { return 0 }
        return Int(context.toInt32(result) ?? 0)
    }

    // MARK: - Teardown

    /// Tear down all bridges, cancel timers, and free the runtime.
    public func teardown() {
        teardownGCDTimers()
        fetchBridge?.cancelAll()
        webSocketBridge?.closeAll()
        videoBridge?.teardown()
        eventBridge?.teardown()
        eventBridge = nil

        domBridge?.resetBridge()
        domBridge = nil
        storageBridge = nil
        fetchBridge = nil
        webSocketBridge = nil
        indexedDBBridge = nil
        videoBridge = nil
        webAPIsBridge?.teardown()
        webAPIsBridge = nil
        dynamicImportBridge = nil

        JeffJSStdLib.removeState(ctx: context)
        context.free()
        runtime.free()
    }

    deinit {
        // Safety: teardown should be called explicitly, but guard against leaks
    }

    // MARK: - Polyfills

    private func evaluatePolyfills() {
        let ctx = context
        let cfg = configuration

        // Globals polyfill (DOMException, process, Event, Node constants, etc.)
        let globalsResult = ctx.eval(input: JeffJSPolyfills.globalsPolyfill, filename: "<poly:globals>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        globalsResult.freeValue()

        // Location polyfill
        let locPoly = JeffJSPolyfills.locationPolyfill(for: cfg.baseURL)
        let locResult = ctx.eval(input: locPoly, filename: "<poly:location>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        locResult.freeValue()

        // Navigator polyfill
        let navPoly = JeffJSPolyfills.navigatorPolyfill(userAgent: cfg.userAgent)
        let navResult = ctx.eval(input: navPoly, filename: "<poly:navigator>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        navResult.freeValue()

        // History polyfill
        let histPoly = JeffJSPolyfills.historyPolyfill(for: cfg.baseURL)
        let histResult = ctx.eval(input: histPoly, filename: "<poly:history>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        histResult.freeValue()

        // Viewport and media polyfill
        let vpPoly = JeffJSPolyfills.viewportAndMediaPolyfill(
            width: cfg.viewportWidth, height: cfg.viewportHeight,
            pixelRatio: cfg.devicePixelRatio
        )
        let vpResult = ctx.eval(input: vpPoly, filename: "<poly:viewport>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        vpResult.freeValue()

        // Fetch, XHR, localStorage, sessionStorage
        let fetchResult = ctx.eval(input: JeffJSPolyfills.fetchAndXHRPolyfill, filename: "<poly:fetch>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        fetchResult.freeValue()

        // Additional polyfills provided by the host
        for (i, poly) in cfg.additionalPolyfills.enumerated() {
            let r = ctx.eval(input: poly, filename: "<poly:custom-\(i)>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            if r.isException {
                let exc = ctx.getException()
                let msg = ctx.toSwiftString(exc) ?? "unknown"
                exc.freeValue()
                onConsoleMessage?("error", "[JeffJS] Custom polyfill \(i) failed: \(msg)")
            }
            r.freeValue()
        }

        _ = runtime.executePendingJobs()
    }

    // MARK: - GCD Timers

    private func installGCDTimers() {
        let ctx = context
        let global = ctx.getGlobalObject()
        defer { global.freeValue() }

        // setTimeout(callback, delay) → timerID
        ctx.setPropertyFunc(obj: global, name: "setTimeout", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            let callback = args.count > 0 ? args[0] : JeffJSValue.undefined
            let delay = args.count > 1 ? (ctx.toFloat64(args[1]) ?? 0) : 0
            let id = self.gcdSetTimeout(callback: callback, delayMs: max(0, delay))
            return JeffJSValue.newFloat64(Double(id))
        }, length: 2)

        // clearTimeout(id)
        ctx.setPropertyFunc(obj: global, name: "clearTimeout", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            let id = args.count > 0 ? Int(ctx.toFloat64(args[0]) ?? 0) : 0
            self.gcdClearTimeout(id)
            return JeffJSValue.undefined
        }, length: 1)

        // setInterval(callback, delay) → timerID
        ctx.setPropertyFunc(obj: global, name: "setInterval", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            let callback = args.count > 0 ? args[0] : JeffJSValue.undefined
            let delay = args.count > 1 ? (ctx.toFloat64(args[1]) ?? 0) : 0
            let id = self.gcdSetInterval(callback: callback, delayMs: max(1, delay))
            return JeffJSValue.newFloat64(Double(id))
        }, length: 2)

        // clearInterval(id)
        ctx.setPropertyFunc(obj: global, name: "clearInterval", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            let id = args.count > 0 ? Int(ctx.toFloat64(args[0]) ?? 0) : 0
            self.gcdClearInterval(id)
            return JeffJSValue.undefined
        }, length: 1)

        // requestAnimationFrame(callback) → timerID (backed by 16ms timeout)
        ctx.setPropertyFunc(obj: global, name: "requestAnimationFrame", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            let callback = args.count > 0 ? args[0] : JeffJSValue.undefined
            let id = self.gcdSetTimeout(callback: callback, delayMs: 16)
            return JeffJSValue.newFloat64(Double(id))
        }, length: 1)

        // cancelAnimationFrame(id)
        ctx.setPropertyFunc(obj: global, name: "cancelAnimationFrame", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            let id = args.count > 0 ? Int(ctx.toFloat64(args[0]) ?? 0) : 0
            self.gcdClearTimeout(id)
            return JeffJSValue.undefined
        }, length: 1)
    }

    private func gcdSetTimeout(callback: JeffJSValue, delayMs: Double) -> Int {
        let id = timerNextID
        timerNextID += 1
        let duped = callback.dupValue()
        timerCallbacks[id] = duped

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, let cb = self.timerCallbacks.removeValue(forKey: id) else { return }
                self.timeoutItems.removeValue(forKey: id)
                JeffJSGCObjectHeader.activeRuntime = self.context.rt
                let result = self.context.call(cb, this: .undefined, args: [])
                result.freeValue()
                cb.freeValue()
                self.drainJobs()
            }
        }
        timeoutItems[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: item)
        return id
    }

    private func gcdClearTimeout(_ id: Int) {
        timeoutItems.removeValue(forKey: id)?.cancel()
        if let cb = timerCallbacks.removeValue(forKey: id) {
            cb.freeValue()
        }
    }

    private func gcdSetInterval(callback: JeffJSValue, delayMs: Double) -> Int {
        let id = timerNextID
        timerNextID += 1
        let duped = callback.dupValue()
        timerCallbacks[id] = duped

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = max(1, delayMs)
        timer.schedule(deadline: .now() + .milliseconds(Int(interval)),
                       repeating: .milliseconds(Int(interval)))
        timer.setEventHandler { [weak self] in
            guard let self, let cb = self.timerCallbacks[id] else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                JeffJSGCObjectHeader.activeRuntime = self.context.rt
                let result = self.context.call(cb, this: .undefined, args: [])
                result.freeValue()
                self.drainJobs()
            }
        }
        timer.resume()
        intervalTimers[id] = timer
        return id
    }

    private func gcdClearInterval(_ id: Int) {
        intervalTimers.removeValue(forKey: id)?.cancel()
        if let cb = timerCallbacks.removeValue(forKey: id) {
            cb.freeValue()
        }
    }

    private func teardownGCDTimers() {
        for (_, item) in timeoutItems { item.cancel() }
        timeoutItems.removeAll()
        for (_, timer) in intervalTimers { timer.cancel() }
        intervalTimers.removeAll()
        for (_, cb) in timerCallbacks { cb.freeValue() }
        timerCallbacks.removeAll()
    }

    // MARK: - Init Script

    /// JavaScript init script that sets up window, module system, and browser stubs.
    /// Extracted from JSScriptEngine.swift's JeffJS init sequence.
    private static let initScript = """
        var window = this;
        window.__nativeModules = {};
        window.__dynamicImport = function(specifier, callerURL) {
            return new Promise(function(resolve, reject) {
                var mod = window.__nativeModules[specifier];
                if (mod) { resolve(mod); }
                else { reject(new Error('Module not found: ' + specifier)); }
            });
        };
        window.getComputedStyle = function(el) {
            var nodeId = el && el.nativeNodeID ? String(el.nativeNodeID) : '';
            var camelToKebab = function(s) { return s.replace(/[A-Z]/g, function(m) { return '-' + m.toLowerCase(); }); };
            return {
                getPropertyValue: function(name) {
                    if (typeof __nativeGetComputedStyleValue === 'function' && nodeId) {
                        var v = __nativeGetComputedStyleValue(nodeId, String(name));
                        if (v) return v;
                    }
                    if (el && el.style && typeof el.style.getPropertyValue === 'function') {
                        return el.style.getPropertyValue(String(name)) || '';
                    }
                    return '';
                }
            };
        };
        window.requestAnimationFrame = function(cb) { return setTimeout(cb, 16); };
        window.cancelAnimationFrame = function(id) { clearTimeout(id); };
        window.addEventListener = function() {};
        window.removeEventListener = function() {};
        window.dispatchEvent = function() { return true; };
        window.Event = function(type) { this.type = type; };
        window.CustomEvent = function(type, opts) { this.type = type; this.detail = (opts && opts.detail) || null; };
        window.MutationObserver = function() { this.observe = function(){}; this.disconnect = function(){}; };
        window.ResizeObserver = function() { this.observe = function(){}; this.disconnect = function(){}; };
        window.IntersectionObserver = function() { this.observe = function(){}; this.disconnect = function(){}; };
        var __cssProps = 'animation,animationDelay,animationDirection,animationDuration,animationFillMode,animationIterationCount,animationName,animationPlayState,animationTimingFunction,background,backgroundAttachment,backgroundClip,backgroundColor,backgroundImage,backgroundOrigin,backgroundPosition,backgroundRepeat,backgroundSize,border,borderBottom,borderBottomColor,borderBottomLeftRadius,borderBottomRightRadius,borderBottomStyle,borderBottomWidth,borderCollapse,borderColor,borderImage,borderLeft,borderLeftColor,borderLeftStyle,borderLeftWidth,borderRadius,borderRight,borderRightColor,borderRightStyle,borderRightWidth,borderSpacing,borderStyle,borderTop,borderTopColor,borderTopLeftRadius,borderTopRightRadius,borderTopStyle,borderTopWidth,borderWidth,bottom,boxShadow,boxSizing,clear,clip,color,content,cursor,direction,display,flex,flexBasis,flexDirection,flexFlow,flexGrow,flexShrink,flexWrap,float,font,fontFamily,fontSize,fontStyle,fontVariant,fontWeight,height,justifyContent,left,letterSpacing,lineHeight,listStyle,margin,marginBottom,marginLeft,marginRight,marginTop,maxHeight,maxWidth,minHeight,minWidth,opacity,order,outline,overflow,overflowX,overflowY,padding,paddingBottom,paddingLeft,paddingRight,paddingTop,position,right,tableLayout,textAlign,textDecoration,textIndent,textOverflow,textShadow,textTransform,top,transform,transformOrigin,transition,userSelect,verticalAlign,visibility,whiteSpace,width,wordBreak,wordSpacing,wordWrap,zIndex'.split(',');
        var __cssStyleDecl = {};
        for (var __i = 0; __i < __cssProps.length; __i++) { __cssStyleDecl[__cssProps[__i]] = ''; }
        if (!window.CSSStyleDeclaration) {
            window.CSSStyleDeclaration = function() {};
            window.CSSStyleDeclaration.prototype = __cssStyleDecl;
        }
        if (!document.createElement) {
            document.createElement = function(tag) { return { tagName: tag, style: Object.create(__cssStyleDecl), setAttribute: function(){}, getAttribute: function(){return null}, appendChild: function(){}, childNodes: [], children: [] }; };
        }
    """
}

// MARK: - Default Dynamic Import Delegate

/// Simple fetch-and-eval delegate for standalone use.
/// Fetches module source via URLSession and returns it directly (no bundling).
@MainActor
final class DefaultDynamicImportDelegate: JeffJSDynamicImportDelegate {
    let baseURL: URL?
    let userAgent: String
    private weak var _ctx: JeffJSContext?
    var jsContext: JeffJSContext? { _ctx }

    private var moduleCache: [URL: String] = [:]

    init(baseURL: URL?, userAgent: String, context: JeffJSContext) {
        self.baseURL = baseURL
        self.userAgent = userAgent
        self._ctx = context
    }

    func buildModuleBundle(entryURL: URL, visited: Set<URL>, userAgent: String) async throws -> (bundle: String, visited: Set<URL>) {
        // Check cache
        if let cached = await MainActor.run(body: { moduleCache[entryURL] }) {
            return (cached, visited.union([entryURL]))
        }

        var request = URLRequest(url: entryURL)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let source = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }

        // Wrap as a module that registers on __nativeModules
        let urlStr = entryURL.absoluteString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let bundle = """
        (function() {
            var __exports = {};
            var __module = { exports: __exports };
            (function(module, exports) {
                \(source)
            })(__module, __exports);
            if (typeof __module.exports === 'object' || typeof __module.exports === 'function') {
                window.__nativeModules['\(urlStr)'] = __module.exports;
            }
        })();
        """
        return (bundle, visited.union([entryURL]))
    }

    func cacheModuleBundle(_ bundle: String, for url: URL) {
        moduleCache[url] = bundle
    }
}
