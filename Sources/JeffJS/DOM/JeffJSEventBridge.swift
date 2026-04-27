// JeffJSEventBridge.swift
// JeffJS — Centralized event bridge ported from JSEventBridge (JSEventSystem.swift).
//
// Registers `__nativeEventBridge` on the JeffJS global with methods:
//   addEventListener, removeEventListener, dispatchEvent, dispatchEventByName,
//   dispatchClickSequence, dispatchEvents
//
// Provides listener deduplication, once/passive/capture/signal options,
// AbortSignal support, and capture/bubble/at-target event phases with
// full bubble path traversal — matching the JSC event bridge behavior.

import Foundation

// MARK: - Listener Record

/// A single event listener record, mirroring JSEventListenerRecord from JSC.
private struct JeffJSEventListenerRecord {
    let listener: JeffJSValue       // The callback function (dup'd)
    let capture: Bool
    let once: Bool
    let passive: Bool
    let signal: JeffJSValue?        // AbortSignal object, or nil
}

// MARK: - Listener Store

/// Storage for all event listeners, keyed by target key then event type.
/// Mirrors JSEventListenerStore from the JSC event bridge.
private final class JeffJSEventListenerStore {
    /// targetKey -> eventType -> [listener records]
    private var store: [String: [String: [JeffJSEventListenerRecord]]] = [:]

    func handlers(for targetKey: String, type: String) -> [JeffJSEventListenerRecord] {
        store[targetKey]?[type] ?? []
    }

    func addListener(targetKey: String, type: String, record: JeffJSEventListenerRecord) {
        if store[targetKey] == nil { store[targetKey] = [:] }
        if store[targetKey]![type] == nil { store[targetKey]![type] = [] }

        // Deduplicate per spec: same listener function + capture = no-op
        let existing = store[targetKey]![type]!
        for rec in existing {
            if rec.listener == record.listener && rec.capture == record.capture {
                return
            }
        }
        store[targetKey]![type]!.append(record)
    }

    func removeListener(targetKey: String, type: String, listener: JeffJSValue, capture: Bool) {
        guard var list = store[targetKey]?[type] else { return }
        list.removeAll { rec in
            rec.listener == listener && rec.capture == capture
        }
        store[targetKey]![type] = list
    }

    func removeAll() {
        store.removeAll()
    }

    func removeAll(for targetKey: String) {
        store.removeValue(forKey: targetKey)
    }

    /// Removes all listeners for a target key, freeing dup'd JeffJSValues.
    func removeAllAndFreeValues(for targetKey: String) {
        if let typeMap = store[targetKey] {
            for (_, records) in typeMap {
                for rec in records {
                    rec.listener.freeValue()
                    rec.signal?.freeValue()
                }
            }
        }
        store.removeValue(forKey: targetKey)
    }
}

// MARK: - JeffJSEventBridge

/// Centralized event bridge for JeffJS, installed as `__nativeEventBridge` on
/// the global object. JS polyfills route addEventListener/removeEventListener/
/// dispatchEvent through this bridge.
///
/// Usage:
/// ```swift
/// let eventBridge = JeffJSEventBridge()
/// eventBridge.register(on: ctx)
/// ```
@MainActor
final class JeffJSEventBridge {

    private let listenerStore = JeffJSEventListenerStore()

    /// Reference to the DOM bridge for node lookups via extractNode/wrapElement.
    weak var domBridge: JeffJSDOMBridge?

    /// Called when a JS event listener throws an exception.
    var onError: ((String) -> Void)?

    // MARK: - Registration

    /// Registers `__nativeEventBridge` on the JeffJS global object with all
    /// event bridge methods.
    func register(on ctx: JeffJSContext) {
        let global = ctx.getGlobalObject()
        defer { global.freeValue() }
        let bridge = ctx.newObject()

        // addEventListener(target, type, listener, options)
        ctx.setPropertyFunc(obj: bridge, name: "addEventListener", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 4 else { return JeffJSValue.undefined }
            self.addEventListener(ctx: ctx, target: args[0], type: args[1], listener: args[2], options: args[3])
            return JeffJSValue.undefined
        }, length: 4)

        // removeEventListener(target, type, listener, options)
        ctx.setPropertyFunc(obj: bridge, name: "removeEventListener", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 4 else { return JeffJSValue.undefined }
            self.removeEventListener(ctx: ctx, target: args[0], type: args[1], listener: args[2], options: args[3])
            return JeffJSValue.undefined
        }, length: 4)

        // dispatchEvent(target, event) -> bool
        ctx.setPropertyFunc(obj: bridge, name: "dispatchEvent", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 2 else { return .newBool(true) }
            let result = self.dispatchEvent(ctx: ctx, target: args[0], event: args[1])
            return .newBool(result)
        }, length: 2)

        // dispatchEventByName(target, type) -> bool
        ctx.setPropertyFunc(obj: bridge, name: "dispatchEventByName", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 2 else { return .newBool(true) }
            let typeStr = ctx.toSwiftString(args[1]) ?? ""
            guard !typeStr.isEmpty else { return .newBool(true) }
            let result = self.dispatchFromTarget(ctx: ctx, target: args[0], type: typeStr, event: nil)
            return .newBool(result)
        }, length: 2)

        // dispatchClickSequence(target)
        ctx.setPropertyFunc(obj: bridge, name: "dispatchClickSequence", fn: { [weak self] ctx, _, args in
            guard let self, !args.isEmpty else { return JeffJSValue.undefined }
            self.dispatchClickSequence(ctx: ctx, target: args[0])
            return JeffJSValue.undefined
        }, length: 1)

        // dispatchEvents(target, typesArray)
        ctx.setPropertyFunc(obj: bridge, name: "dispatchEvents", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 2 else { return JeffJSValue.undefined }
            self.dispatchEvents(ctx: ctx, target: args[0], types: args[1])
            return JeffJSValue.undefined
        }, length: 2)

        ctx.setPropertyStr(obj: global, name: "__nativeEventBridge", value: bridge)
    }

    /// Removes all stored listeners. Call on page teardown.
    func teardown() {
        listenerStore.removeAll()
    }

    /// Removes all listeners for a specific DOMNode UUID, freeing dup'd values.
    /// Called when a node is removed from the DOM tree.
    func removeAllListeners(forNodeID nodeID: UUID) {
        listenerStore.removeAllAndFreeValues(for: "node:\(nodeID.uuidString)")
    }

    // MARK: - addEventListener (internal for DOM bridge routing)

    func addEventListener(ctx: JeffJSContext, target: JeffJSValue, type: JeffJSValue, listener: JeffJSValue, options: JeffJSValue) {
        let typeStr = ctx.toSwiftString(type) ?? ""
        guard !typeStr.isEmpty else { return }
        guard listener.isFunction || listener.isObject else { return }

        let (capture, once, passive, signal) = parseListenerOptions(ctx: ctx, options: options)

        // Check if signal is already aborted
        if let signal, !signal.isUndefined, !signal.isNull {
            let aborted = ctx.getPropertyStr(obj: signal, name: "aborted")
            if aborted.toBool() {
                return
            }
        }

        let targetKey = eventTargetKey(ctx: ctx, value: target)

        let record = JeffJSEventListenerRecord(
            listener: listener.dupValue(),
            capture: capture,
            once: once,
            passive: passive,
            signal: signal?.dupValue()
        )

        listenerStore.addListener(targetKey: targetKey, type: typeStr, record: record)
    }

    // MARK: - removeEventListener (internal for DOM bridge routing)

    func removeEventListener(ctx: JeffJSContext, target: JeffJSValue, type: JeffJSValue, listener: JeffJSValue, options: JeffJSValue) {
        let typeStr = ctx.toSwiftString(type) ?? ""
        guard !typeStr.isEmpty else { return }
        let (capture, _, _, _) = parseListenerOptions(ctx: ctx, options: options)
        let targetKey = eventTargetKey(ctx: ctx, value: target)
        listenerStore.removeListener(targetKey: targetKey, type: typeStr, listener: listener, capture: capture)
    }

    // MARK: - dispatchEvent (internal for DOM bridge routing)

    func dispatchEvent(ctx: JeffJSContext, target: JeffJSValue, event: JeffJSValue) -> Bool {
        let typeVal = ctx.getPropertyStr(obj: event, name: "type")
        let type = ctx.toSwiftString(typeVal) ?? ""
        guard !type.isEmpty else { return true }
        return dispatchFromTarget(ctx: ctx, target: target, type: type, event: event)
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

    @discardableResult
    func dispatchFromTarget(ctx: JeffJSContext, target: JeffJSValue, type: String, event: JeffJSValue?) -> Bool {
        // Build or reuse event object
        let eventObj: JeffJSValue
        var ownsEvent = false
        if let event, event.isObject {
            let existingType = ctx.getPropertyStr(obj: event, name: "type")
            let hasType = !existingType.isUndefined
            existingType.freeValue()
            if hasType {
                eventObj = event
            } else {
                eventObj = buildEvent(ctx: ctx, type: type, target: target)
                ownsEvent = true
            }
        } else {
            eventObj = buildEvent(ctx: ctx, type: type, target: target)
            ownsEvent = true
        }

        // Set/overwrite standard fields
        ctx.setPropertyStr(obj: eventObj, name: "type", value: ctx.newStringValue(type))
        ctx.setPropertyStr(obj: eventObj, name: "target", value: target.dupValue())
        ctx.setPropertyStr(obj: eventObj, name: "currentTarget", value: target.dupValue())
        ctx.setPropertyStr(obj: eventObj, name: "defaultPrevented", value: .newBool(false))
        ctx.setPropertyStr(obj: eventObj, name: "cancelBubble", value: .newBool(false))
        ctx.setPropertyStr(obj: eventObj, name: "__immediateStopped", value: .newBool(false))

        // Build bubble path: target -> parent -> ... -> document -> window
        let path = buildBubblePath(ctx: ctx, from: target)

        // Helper to free owned path values (index 0 is the target, not owned by us)
        func freePath() {
            for i in 1..<path.count { path[i].freeValue() }
            if ownsEvent { eventObj.freeValue() }
        }

        // Capture phase: from outermost down to parent of target
        for i in stride(from: path.count - 1, through: 1, by: -1) {
            ctx.setPropertyStr(obj: eventObj, name: "eventPhase", value: .newInt32(1))
            invokeHandlers(ctx: ctx, on: path[i], event: eventObj, capturePhase: true)
            if ctx.getPropertyStr(obj: eventObj, name: "cancelBubble").toBool() {
                ctx.setPropertyStr(obj: eventObj, name: "eventPhase", value: .newInt32(0))
                let result = !ctx.getPropertyStr(obj: eventObj, name: "defaultPrevented").toBool()
                freePath()
                return result
            }
        }

        // At-target phase
        ctx.setPropertyStr(obj: eventObj, name: "eventPhase", value: .newInt32(2))
        invokeHandlers(ctx: ctx, on: target, event: eventObj, capturePhase: true)
        if !ctx.getPropertyStr(obj: eventObj, name: "__immediateStopped").toBool() {
            invokeHandlers(ctx: ctx, on: target, event: eventObj, capturePhase: false)
        }

        let bubbles = ctx.getPropertyStr(obj: eventObj, name: "bubbles").toBool()
        if ctx.getPropertyStr(obj: eventObj, name: "cancelBubble").toBool() || !bubbles {
            ctx.setPropertyStr(obj: eventObj, name: "eventPhase", value: .newInt32(0))
            let result = !ctx.getPropertyStr(obj: eventObj, name: "defaultPrevented").toBool()
            freePath()
            return result
        }

        // Bubble phase
        for i in 1..<path.count {
            ctx.setPropertyStr(obj: eventObj, name: "eventPhase", value: .newInt32(3))
            invokeHandlers(ctx: ctx, on: path[i], event: eventObj, capturePhase: false)
            if ctx.getPropertyStr(obj: eventObj, name: "cancelBubble").toBool() || !bubbles {
                break
            }
        }

        ctx.setPropertyStr(obj: eventObj, name: "eventPhase", value: .newInt32(0))
        let result = !ctx.getPropertyStr(obj: eventObj, name: "defaultPrevented").toBool()
        freePath()
        return result
    }

    private func invokeHandlers(ctx: JeffJSContext, on target: JeffJSValue, event: JeffJSValue, capturePhase: Bool) {
        let targetKey = eventTargetKey(ctx: ctx, value: target)
        let typeVal = ctx.getPropertyStr(obj: event, name: "type")
        let type = ctx.toSwiftString(typeVal) ?? ""
        typeVal.freeValue()

        ctx.setPropertyStr(obj: event, name: "currentTarget", value: target.dupValue())

        // on* handler (only in bubble/at-target phase)
        if !capturePhase {
            let handlerName = "on\(type)"
            let handler = ctx.getPropertyStr(obj: target, name: handlerName)
            if handler.isFunction {
                let r = ctx.call(handler, this: target, args: [event])
                reportExceptionIfNeeded(r, ctx: ctx, label: "on\(type) handler")
                r.freeValue()
            }
            handler.freeValue()
        }

        let records = listenerStore.handlers(for: targetKey, type: type)
        for record in records {
            // Check AbortSignal
            if let signal = record.signal, !signal.isUndefined, !signal.isNull {
                let aborted = ctx.getPropertyStr(obj: signal, name: "aborted")
                if aborted.toBool() {
                    aborted.freeValue()
                    // Signal was aborted — remove and skip
                    listenerStore.removeListener(targetKey: targetKey, type: type, listener: record.listener, capture: record.capture)
                    continue
                }
                aborted.freeValue()
            }

            if capturePhase && !record.capture { continue }
            if !capturePhase && record.capture { continue }

            let r = ctx.call(record.listener, this: target, args: [event])
            reportExceptionIfNeeded(r, ctx: ctx, label: "\(type) listener")
            r.freeValue()

            if record.once {
                listenerStore.removeListener(targetKey: targetKey, type: type, listener: record.listener, capture: record.capture)
            }
        }
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

    // MARK: - Bubble Path

    private func buildBubblePath(ctx: JeffJSContext, from target: JeffJSValue) -> [JeffJSValue] {
        var path: [JeffJSValue] = []
        var current: JeffJSValue? = target

        while let cur = current, !cur.isUndefined, !cur.isNull {
            path.append(cur)
            let parent = ctx.getPropertyStr(obj: cur, name: "parentElement")
            if !parent.isUndefined && !parent.isNull {
                current = parent
            } else {
                parent.freeValue()
                break
            }
        }

        let global = ctx.getGlobalObject()

        // Add document at end if not already there
        let doc = ctx.getPropertyStr(obj: global, name: "document")
        if !doc.isUndefined && !doc.isNull {
            let docKey = eventTargetKey(ctx: ctx, value: doc)
            if !path.contains(where: { eventTargetKey(ctx: ctx, value: $0) == docKey }) {
                path.append(doc)
            } else {
                doc.freeValue()
            }
        } else {
            doc.freeValue()
        }

        // Add window at end if not already there
        let win = ctx.getPropertyStr(obj: global, name: "window")
        if !win.isUndefined && !win.isNull {
            let winKey = eventTargetKey(ctx: ctx, value: win)
            if !path.contains(where: { eventTargetKey(ctx: ctx, value: $0) == winKey }) {
                path.append(win)
            } else {
                win.freeValue()
            }
        } else {
            win.freeValue()
        }

        global.freeValue()
        return path
    }

    // MARK: - Event Object Builder

    private func buildEvent(ctx: JeffJSContext, type: String, target: JeffJSValue) -> JeffJSValue {
        let event = ctx.newObject()
        ctx.setPropertyStr(obj: event, name: "type", value: ctx.newStringValue(type))
        ctx.setPropertyStr(obj: event, name: "target", value: target.dupValue())
        ctx.setPropertyStr(obj: event, name: "currentTarget", value: target.dupValue())
        ctx.setPropertyStr(obj: event, name: "defaultPrevented", value: .newBool(false))
        ctx.setPropertyStr(obj: event, name: "cancelBubble", value: .newBool(false))
        ctx.setPropertyStr(obj: event, name: "bubbles", value: .newBool(true))
        ctx.setPropertyStr(obj: event, name: "cancelable", value: .newBool(true))
        ctx.setPropertyStr(obj: event, name: "composed", value: .newBool(false))
        ctx.setPropertyStr(obj: event, name: "isTrusted", value: .newBool(true))
        ctx.setPropertyStr(obj: event, name: "eventPhase", value: .newInt32(0))
        ctx.setPropertyStr(obj: event, name: "__immediateStopped", value: .newBool(false))
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

        // preventDefault()
        ctx.setPropertyFunc(obj: event, name: "preventDefault", fn: { ctx, thisVal, _ in
            let cancelable = ctx.getPropertyStr(obj: thisVal, name: "cancelable")
            let isCancelable = cancelable.toBool()
            cancelable.freeValue()
            if isCancelable {
                ctx.setPropertyStr(obj: thisVal, name: "defaultPrevented", value: .newBool(true))
            }
            return JeffJSValue.undefined
        }, length: 0)

        // stopPropagation()
        ctx.setPropertyFunc(obj: event, name: "stopPropagation", fn: { ctx, thisVal, _ in
            ctx.setPropertyStr(obj: thisVal, name: "cancelBubble", value: .newBool(true))
            return JeffJSValue.undefined
        }, length: 0)

        // stopImmediatePropagation()
        ctx.setPropertyFunc(obj: event, name: "stopImmediatePropagation", fn: { ctx, thisVal, _ in
            ctx.setPropertyStr(obj: thisVal, name: "cancelBubble", value: .newBool(true))
            ctx.setPropertyStr(obj: thisVal, name: "__immediateStopped", value: .newBool(true))
            return JeffJSValue.undefined
        }, length: 0)

        // composedPath() — returns empty array (same as JSC bridge)
        ctx.setPropertyFunc(obj: event, name: "composedPath", fn: { ctx, _, _ in
            return ctx.newArray()
        }, length: 0)

        return event
    }

    // MARK: - Options Parsing

    private func parseListenerOptions(ctx: JeffJSContext, options: JeffJSValue) -> (capture: Bool, once: Bool, passive: Bool, signal: JeffJSValue?) {
        if options.isUndefined || options.isNull {
            return (false, false, false, nil)
        }

        // Boolean shorthand: addEventListener(target, type, fn, true)
        if options.isBool {
            return (options.toBool(), false, false, nil)
        }

        if options.isObject {
            let captureVal = ctx.getPropertyStr(obj: options, name: "capture")
            let capture = captureVal.toBool()
            captureVal.freeValue()
            let onceVal = ctx.getPropertyStr(obj: options, name: "once")
            let once = onceVal.toBool()
            onceVal.freeValue()
            let passiveVal = ctx.getPropertyStr(obj: options, name: "passive")
            let passive = passiveVal.toBool()
            passiveVal.freeValue()
            let signal = ctx.getPropertyStr(obj: options, name: "signal")
            let signalVal: JeffJSValue? = (signal.isUndefined || signal.isNull) ? nil : signal
            if signalVal == nil { signal.freeValue() }
            return (capture, once, passive, signalVal)
        }

        return (false, false, false, nil)
    }

    // MARK: - Target Key

    /// Generates a stable key for an event target, matching the JSC eventTargetKey() function.
    private func eventTargetKey(ctx: JeffJSContext, value: JeffJSValue) -> String {
        if value.isUndefined || value.isNull {
            return "window"
        }

        let global = ctx.getGlobalObject()
        defer { global.freeValue() }

        // Check if it's the window (global object)
        let windowVal = ctx.getPropertyStr(obj: global, name: "window")
        let isWindow = (value == windowVal)
        windowVal.freeValue()
        if isWindow { return "window" }

        // Check if it's the document
        let docVal = ctx.getPropertyStr(obj: global, name: "document")
        let isDoc = (value == docVal)
        docVal.freeValue()
        if isDoc { return "document" }

        // Check for nativeNodeID (DOM bridge element objects)
        let nodeID = ctx.getPropertyStr(obj: value, name: "nativeNodeID")
        if !nodeID.isUndefined && !nodeID.isNull {
            if let idStr = ctx.toSwiftString(nodeID) {
                nodeID.freeValue()
                return "node:\(idStr)"
            }
        }
        nodeID.freeValue()

        // Generate/retrieve a stable key for arbitrary objects
        let existingKey = ctx.getPropertyStr(obj: value, name: "__nativeEventTargetKey")
        if !existingKey.isUndefined && !existingKey.isNull {
            let result = ctx.toSwiftString(existingKey) ?? "unknown"
            existingKey.freeValue()
            return result
        }
        existingKey.freeValue()

        let newKey = "object:\(UUID().uuidString)"
        ctx.setPropertyStr(obj: value, name: "__nativeEventTargetKey", value: ctx.newStringValue(newKey))
        return newKey
    }
}
