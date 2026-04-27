// JeffJSStdLib.swift
// JeffJS - 1:1 Swift port of QuickJS JavaScript engine
//
// Port of quickjs-libc.c — standard library providing OS-level functionality:
// console, timers, performance, TextEncoder/TextDecoder, URL, structuredClone,
// queueMicrotask, atob/btoa, and the QuickJS-specific 'std' and 'os' modules.
//
// QuickJS source reference: quickjs-libc.c
// Ported to Swift by Jeff Bachand

import Foundation

// MARK: - Timer State

/// Internal timer entry matching QuickJS os_timer in quickjs-libc.c.
/// Each setTimeout/setInterval call creates one of these.
private final class JeffJSTimerEntry {
    let id: Int32
    let callback: JeffJSValue
    let args: [JeffJSValue]
    let interval: Double           // milliseconds
    let isInterval: Bool
    var fireTime: Double           // absolute time (CFAbsoluteTimeGetCurrent-based)
    var cancelled: Bool = false

    init(id: Int32, callback: JeffJSValue, args: [JeffJSValue],
         interval: Double, isInterval: Bool, fireTime: Double) {
        self.id = id
        self.callback = callback
        self.args = args
        self.interval = interval
        self.isInterval = isInterval
        self.fireTime = fireTime
    }
}

/// Internal state for console.count() / console.time() tracking.
private final class JeffJSConsoleState {
    var countMap: [String: Int] = [:]
    var timerMap: [String: Double] = [:]    // label -> start time (seconds)
    var groupDepth: Int = 0
}

// MARK: - JeffJSStdLib

/// Standard library module providing OS-level functionality to JeffJS contexts.
/// Port of QuickJS quickjs-libc.c.
///
/// Usage:
/// ```swift
/// let rt = JeffJS.newRuntime()
/// let ctx = rt.newContext()
/// JeffJSStdLib.addIntrinsics(ctx: ctx)
/// ```
struct JeffJSStdLib {

    /// Per-context console message callback: (level, message) -> Void.
    /// When set, console output routes here instead of stdout.
    private static var consoleCallbacks: [ObjectIdentifier: (String, String) -> Void] = [:]

    /// Set a callback to receive console messages for a given context.
    static func setConsoleCallback(ctx: JeffJSContext, callback: @escaping (String, String) -> Void) {
        let key = ObjectIdentifier(ctx as AnyObject)
        consoleCallbacks[key] = callback
    }

    /// Emit a console message: routes to callback if set, otherwise prints to stdout.
    private static func emitConsole(ctx: JeffJSContext, level: String, message: String) {
        let key = ObjectIdentifier(ctx as AnyObject)
        if let cb = consoleCallbacks[key] {
            cb(level, message)
        } else {
            print("[console.\(level)] \(message)")
        }
    }

    /// Remove console callback (call when context is freed).
    static func removeConsoleCallback(ctx: JeffJSContext) {
        let key = ObjectIdentifier(ctx as AnyObject)
        consoleCallbacks.removeValue(forKey: key)
    }

    // Per-context state stored as opaque data on the context.
    // This holds timer lists, console counters, etc.
    private static var contextStates: [ObjectIdentifier: JeffJSStdLibState] = [:]

    /// Retrieve or create the per-context standard library state.
    private static func getState(ctx: JeffJSContext) -> JeffJSStdLibState {
        let key = ObjectIdentifier(ctx as AnyObject)
        if let state = contextStates[key] {
            return state
        }
        let state = JeffJSStdLibState()
        contextStates[key] = state
        return state
    }

    /// Remove per-context state (call when context is freed).
    static func removeState(ctx: JeffJSContext) {
        let key = ObjectIdentifier(ctx as AnyObject)
        contextStates.removeValue(forKey: key)
    }

    // MARK: - Master Registration

    /// Add all standard library modules to a context.
    /// Mirrors `js_std_add_helpers` and `js_init_module_std`/`js_init_module_os`
    /// from quickjs-libc.c.
    static func addIntrinsics(ctx: JeffJSContext) {
        addConsole(ctx: ctx)
        addTimers(ctx: ctx)
        addPerformance(ctx: ctx)
        addTextCodec(ctx: ctx)
        addURL(ctx: ctx)
        addStructuredClone(ctx: ctx)
        addMicrotask(ctx: ctx)
        addBase64(ctx: ctx)
    }

    // MARK: - Console Module

    /// Register the `console` object on the global object.
    /// Mirrors the console setup in quickjs-libc.c `js_std_add_helpers`.
    ///
    /// Provides: console.log, console.warn, console.error, console.info,
    /// console.debug, console.assert, console.clear, console.count,
    /// console.countReset, console.group, console.groupEnd, console.time,
    /// console.timeEnd, console.timeLog, console.trace, console.dir,
    /// console.dirxml, console.table
    static func addConsole(ctx: JeffJSContext) {
        let global = ctx.getGlobalObject()
        let consoleObj = ctx.newPlainObject()

        // Logging methods
        ctx.setPropertyFunc(obj: consoleObj, name: "log", fn: consoleLog, length: 0)
        ctx.setPropertyFunc(obj: consoleObj, name: "warn", fn: consoleWarn, length: 0)
        ctx.setPropertyFunc(obj: consoleObj, name: "error", fn: consoleError, length: 0)
        ctx.setPropertyFunc(obj: consoleObj, name: "info", fn: consoleInfo, length: 0)
        ctx.setPropertyFunc(obj: consoleObj, name: "debug", fn: consoleDebug, length: 0)

        // Assertion
        ctx.setPropertyFunc(obj: consoleObj, name: "assert", fn: consoleAssert, length: 0)

        // Clear
        ctx.setPropertyFunc(obj: consoleObj, name: "clear", fn: consoleClear, length: 0)

        // Counting
        ctx.setPropertyFunc(obj: consoleObj, name: "count", fn: consoleCount, length: 0)
        ctx.setPropertyFunc(obj: consoleObj, name: "countReset", fn: consoleCountReset, length: 1)

        // Grouping
        ctx.setPropertyFunc(obj: consoleObj, name: "group", fn: consoleGroup, length: 0)
        ctx.setPropertyFunc(obj: consoleObj, name: "groupCollapsed", fn: consoleGroup, length: 0)
        ctx.setPropertyFunc(obj: consoleObj, name: "groupEnd", fn: consoleGroupEnd, length: 0)

        // Timing
        ctx.setPropertyFunc(obj: consoleObj, name: "time", fn: consoleTime, length: 0)
        ctx.setPropertyFunc(obj: consoleObj, name: "timeEnd", fn: consoleTimeEnd, length: 0)
        ctx.setPropertyFunc(obj: consoleObj, name: "timeLog", fn: consoleTimeLog, length: 0)

        // Trace
        ctx.setPropertyFunc(obj: consoleObj, name: "trace", fn: consoleTrace, length: 0)

        // Dir / DirXML / Table
        ctx.setPropertyFunc(obj: consoleObj, name: "dir", fn: consoleDir, length: 0)
        ctx.setPropertyFunc(obj: consoleObj, name: "dirxml", fn: consoleDirxml, length: 0)
        ctx.setPropertyFunc(obj: consoleObj, name: "table", fn: consoleTable, length: 0)

        _ = ctx.setPropertyStr(obj: global, name: "console", value: consoleObj)
    }

    // MARK: Console Implementations

    /// Format arguments for console output, matching QuickJS behavior.
    /// Concatenates all arguments with spaces, calling toString() on each.
    private static func formatConsoleArgs(ctx: JeffJSContext, args: [JeffJSValue]) -> String {
        var parts: [String] = []
        for arg in args {
            if arg.isString {
                if let s = arg.stringValue {
                    parts.append(s.toSwiftString())
                } else {
                    parts.append("undefined")
                }
            } else if arg.isNull {
                parts.append("null")
            } else if arg.isUndefined {
                parts.append("undefined")
            } else if arg.isBool {
                parts.append(arg.toBool() ? "true" : "false")
            } else if arg.isInt {
                parts.append(String(arg.toInt32()))
            } else if arg.isFloat64 {
                let d = arg.toFloat64()
                if d == Double(Int64(d)) && !d.isNaN && !d.isInfinite {
                    parts.append(String(Int64(d)))
                } else {
                    parts.append(String(d))
                }
            } else {
                // Object: call toString via the context
                let str = ctx.toString(arg)
                if str.isException {
                    parts.append("[object]")
                } else if let s = str.stringValue {
                    parts.append(s.toSwiftString())
                } else {
                    parts.append("[object]")
                }
            }
        }
        return parts.joined(separator: " ")
    }

    /// Build the indentation prefix based on console group depth.
    private static func groupPrefix(ctx: JeffJSContext) -> String {
        let state = getState(ctx: ctx)
        if state.console.groupDepth <= 0 { return "" }
        return String(repeating: "  ", count: state.console.groupDepth)
    }

    /// console.log(...args)
    /// Mirrors js_std_print in quickjs-libc.c.
    static func consoleLog(ctx: JeffJSContext, this: JeffJSValue,
                           args: [JeffJSValue]) -> JeffJSValue {
        let prefix = groupPrefix(ctx: ctx)
        let msg = formatConsoleArgs(ctx: ctx, args: args)
        emitConsole(ctx: ctx, level: "log", message: "\(prefix)\(msg)")
        return .undefined
    }

    /// console.warn(...args)
    static func consoleWarn(ctx: JeffJSContext, this: JeffJSValue,
                            args: [JeffJSValue]) -> JeffJSValue {
        let prefix = groupPrefix(ctx: ctx)
        let msg = formatConsoleArgs(ctx: ctx, args: args)
        emitConsole(ctx: ctx, level: "warn", message: "\(prefix)\(msg)")
        return .undefined
    }

    /// console.error(...args)
    static func consoleError(ctx: JeffJSContext, this: JeffJSValue,
                             args: [JeffJSValue]) -> JeffJSValue {
        let prefix = groupPrefix(ctx: ctx)
        let msg = formatConsoleArgs(ctx: ctx, args: args)
        emitConsole(ctx: ctx, level: "error", message: "\(prefix)\(msg)")
        return .undefined
    }

    /// console.info(...args)
    static func consoleInfo(ctx: JeffJSContext, this: JeffJSValue,
                            args: [JeffJSValue]) -> JeffJSValue {
        let prefix = groupPrefix(ctx: ctx)
        let msg = formatConsoleArgs(ctx: ctx, args: args)
        emitConsole(ctx: ctx, level: "info", message: "\(prefix)\(msg)")
        return .undefined
    }

    /// console.debug(...args)
    static func consoleDebug(ctx: JeffJSContext, this: JeffJSValue,
                             args: [JeffJSValue]) -> JeffJSValue {
        let prefix = groupPrefix(ctx: ctx)
        let msg = formatConsoleArgs(ctx: ctx, args: args)
        emitConsole(ctx: ctx, level: "debug", message: "\(prefix)\(msg)")
        return .undefined
    }

    /// console.assert(condition, ...args)
    /// If condition is falsy, prints "Assertion failed:" followed by args.
    static func consoleAssert(ctx: JeffJSContext, this: JeffJSValue,
                              args: [JeffJSValue]) -> JeffJSValue {
        let condition = args.count > 0 ? args[0] : .undefined
        // Evaluate truthiness
        let isTruthy: Bool
        if condition.isBool {
            isTruthy = condition.toBool()
        } else if condition.isInt {
            isTruthy = condition.toInt32() != 0
        } else if condition.isFloat64 {
            let d = condition.toFloat64()
            isTruthy = d != 0.0 && !d.isNaN
        } else if condition.isNull || condition.isUndefined {
            isTruthy = false
        } else if condition.isString {
            if let s = condition.stringValue {
                isTruthy = s.len > 0
            } else {
                isTruthy = false
            }
        } else {
            isTruthy = true  // objects are truthy
        }

        if !isTruthy {
            let prefix = groupPrefix(ctx: ctx)
            if args.count > 1 {
                let msg = formatConsoleArgs(ctx: ctx, args: Array(args[1...]))
                emitConsole(ctx: ctx, level: "error", message: "\(prefix)Assertion failed: \(msg)")
            } else {
                emitConsole(ctx: ctx, level: "error", message: "\(prefix)Assertion failed")
            }
        }
        return .undefined
    }

    /// console.clear()
    static func consoleClear(ctx: JeffJSContext, this: JeffJSValue,
                             args: [JeffJSValue]) -> JeffJSValue {
        emitConsole(ctx: ctx, level: "log", message: "Console was cleared")
        return .undefined
    }

    /// console.count(label?)
    /// Logs the number of times count() has been called with the given label.
    static func consoleCount(ctx: JeffJSContext, this: JeffJSValue,
                             args: [JeffJSValue]) -> JeffJSValue {
        let state = getState(ctx: ctx)
        let label: String
        if args.count > 0 && !args[0].isUndefined {
            label = formatConsoleArgs(ctx: ctx, args: [args[0]])
        } else {
            label = "default"
        }
        let count = (state.console.countMap[label] ?? 0) + 1
        state.console.countMap[label] = count
        let prefix = groupPrefix(ctx: ctx)
        emitConsole(ctx: ctx, level: "log", message: "\(prefix)\(label): \(count)")
        return .undefined
    }

    /// console.countReset(label?)
    /// Resets a counter previously started with console.count().
    static func consoleCountReset(ctx: JeffJSContext, this: JeffJSValue,
                                  args: [JeffJSValue]) -> JeffJSValue {
        let state = getState(ctx: ctx)
        let label: String
        if args.count > 0 && !args[0].isUndefined {
            label = formatConsoleArgs(ctx: ctx, args: [args[0]])
        } else {
            label = "default"
        }
        if state.console.countMap[label] != nil {
            state.console.countMap[label] = 0
        } else {
            let prefix = groupPrefix(ctx: ctx)
            emitConsole(ctx: ctx, level: "warn", message: "\(prefix)Count for '\(label)' does not exist")
        }
        return .undefined
    }

    /// console.group(...args)
    /// Increases the indentation of subsequent console messages.
    static func consoleGroup(ctx: JeffJSContext, this: JeffJSValue,
                             args: [JeffJSValue]) -> JeffJSValue {
        let state = getState(ctx: ctx)
        if !args.isEmpty {
            let prefix = groupPrefix(ctx: ctx)
            let msg = formatConsoleArgs(ctx: ctx, args: args)
            emitConsole(ctx: ctx, level: "log", message: "\(prefix)\(msg)")
        }
        state.console.groupDepth += 1
        return .undefined
    }

    /// console.groupEnd()
    /// Decreases the indentation of subsequent console messages.
    static func consoleGroupEnd(ctx: JeffJSContext, this: JeffJSValue,
                                args: [JeffJSValue]) -> JeffJSValue {
        let state = getState(ctx: ctx)
        if state.console.groupDepth > 0 {
            state.console.groupDepth -= 1
        }
        return .undefined
    }

    /// console.time(label?)
    /// Starts a timer with the given label.
    static func consoleTime(ctx: JeffJSContext, this: JeffJSValue,
                            args: [JeffJSValue]) -> JeffJSValue {
        let state = getState(ctx: ctx)
        let label: String
        if args.count > 0 && !args[0].isUndefined {
            label = formatConsoleArgs(ctx: ctx, args: [args[0]])
        } else {
            label = "default"
        }
        if state.console.timerMap[label] != nil {
            let prefix = groupPrefix(ctx: ctx)
            emitConsole(ctx: ctx, level: "warn", message: "\(prefix)Timer '\(label)' already exists")
            return .undefined
        }
        state.console.timerMap[label] = CFAbsoluteTimeGetCurrent()
        return .undefined
    }

    /// console.timeEnd(label?)
    /// Stops a timer and logs the elapsed time.
    static func consoleTimeEnd(ctx: JeffJSContext, this: JeffJSValue,
                               args: [JeffJSValue]) -> JeffJSValue {
        let state = getState(ctx: ctx)
        let label: String
        if args.count > 0 && !args[0].isUndefined {
            label = formatConsoleArgs(ctx: ctx, args: [args[0]])
        } else {
            label = "default"
        }
        guard let startTime = state.console.timerMap.removeValue(forKey: label) else {
            let prefix = groupPrefix(ctx: ctx)
            emitConsole(ctx: ctx, level: "warn", message: "\(prefix)Timer '\(label)' does not exist")
            return .undefined
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        let prefix = groupPrefix(ctx: ctx)
        emitConsole(ctx: ctx, level: "log", message: String(format: "%@%@: %.3fms", prefix, label, elapsed))
        return .undefined
    }

    /// console.timeLog(label?, ...args)
    /// Logs the current value of a timer without stopping it.
    static func consoleTimeLog(ctx: JeffJSContext, this: JeffJSValue,
                               args: [JeffJSValue]) -> JeffJSValue {
        let state = getState(ctx: ctx)
        let label: String
        if args.count > 0 && !args[0].isUndefined {
            label = formatConsoleArgs(ctx: ctx, args: [args[0]])
        } else {
            label = "default"
        }
        guard let startTime = state.console.timerMap[label] else {
            let prefix = groupPrefix(ctx: ctx)
            emitConsole(ctx: ctx, level: "warn", message: "\(prefix)Timer '\(label)' does not exist")
            return .undefined
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        let prefix = groupPrefix(ctx: ctx)
        if args.count > 1 {
            let extra = formatConsoleArgs(ctx: ctx, args: Array(args[1...]))
            emitConsole(ctx: ctx, level: "log", message: String(format: "%@%@: %.3fms %@", prefix, label, elapsed, extra))
        } else {
            emitConsole(ctx: ctx, level: "log", message: String(format: "%@%@: %.3fms", prefix, label, elapsed))
        }
        return .undefined
    }

    /// console.trace(...args)
    /// Outputs a stack trace to the console.
    static func consoleTrace(ctx: JeffJSContext, this: JeffJSValue,
                             args: [JeffJSValue]) -> JeffJSValue {
        let prefix = groupPrefix(ctx: ctx)
        if !args.isEmpty {
            let msg = formatConsoleArgs(ctx: ctx, args: args)
            emitConsole(ctx: ctx, level: "log", message: "\(prefix)Trace: \(msg)")
        } else {
            emitConsole(ctx: ctx, level: "log", message: "\(prefix)Trace")
        }
        return .undefined
    }

    /// console.dir(obj, options?)
    /// Displays an interactive listing of the properties of a specified object.
    /// In a non-interactive context, equivalent to console.log.
    static func consoleDir(ctx: JeffJSContext, this: JeffJSValue,
                           args: [JeffJSValue]) -> JeffJSValue {
        return consoleLog(ctx: ctx, this: this, args: args)
    }

    /// console.dirxml(...args)
    /// Displays an XML/HTML representation. Falls back to console.log.
    static func consoleDirxml(ctx: JeffJSContext, this: JeffJSValue,
                              args: [JeffJSValue]) -> JeffJSValue {
        return consoleLog(ctx: ctx, this: this, args: args)
    }

    /// console.table(data, columns?)
    /// Displays tabular data as a table. Falls back to console.log.
    static func consoleTable(ctx: JeffJSContext, this: JeffJSValue,
                             args: [JeffJSValue]) -> JeffJSValue {
        // Full table formatting is complex; fall back to log for now
        return consoleLog(ctx: ctx, this: this, args: args)
    }

    // MARK: - Timer Functions

    /// Register setTimeout, setInterval, clearTimeout, clearInterval on the global object.
    /// Mirrors os_setTimeout/os_clearTimeout from quickjs-libc.c.
    static func addTimers(ctx: JeffJSContext) {
        let global = ctx.getGlobalObject()

        ctx.setPropertyFunc(obj: global, name: "setTimeout", fn: jsSetTimeout, length: 1)
        ctx.setPropertyFunc(obj: global, name: "setInterval", fn: jsSetInterval, length: 1)
        ctx.setPropertyFunc(obj: global, name: "clearTimeout", fn: jsClearTimeout, length: 1)
        ctx.setPropertyFunc(obj: global, name: "clearInterval", fn: jsClearInterval, length: 1)
    }

    /// setTimeout(func, delay, ...args) -> timerId
    /// Schedules a function to be called after a delay.
    static func jsSetTimeout(ctx: JeffJSContext, this: JeffJSValue,
                             args: [JeffJSValue]) -> JeffJSValue {
        return createTimer(ctx: ctx, args: args, isInterval: false)
    }

    /// setInterval(func, delay, ...args) -> timerId
    /// Schedules a function to be called repeatedly at fixed intervals.
    static func jsSetInterval(ctx: JeffJSContext, this: JeffJSValue,
                              args: [JeffJSValue]) -> JeffJSValue {
        return createTimer(ctx: ctx, args: args, isInterval: true)
    }

    /// Internal: create a timer entry (shared by setTimeout/setInterval).
    private static func createTimer(ctx: JeffJSContext, args: [JeffJSValue],
                                    isInterval: Bool) -> JeffJSValue {
        guard args.count >= 1 else {
            return ctx.throwTypeError("setTimeout/setInterval requires at least 1 argument")
        }

        let callback = args[0]
        // callback must be callable
        if !callback.isObject {
            return ctx.throwTypeError("Callback is not a function")
        }

        // Parse delay (default 0)
        var delay: Double = 0
        if args.count >= 2 {
            if args[1].isInt {
                delay = Double(args[1].toInt32())
            } else if args[1].isFloat64 {
                delay = args[1].toFloat64()
            }
        }
        // Clamp delay to >= 0
        if delay < 0 || delay.isNaN { delay = 0 }

        // Collect additional arguments
        var extraArgs: [JeffJSValue] = []
        if args.count > 2 {
            extraArgs = Array(args[2...])
        }

        let state = getState(ctx: ctx)
        let id = state.nextTimerId
        state.nextTimerId += 1

        let now = CFAbsoluteTimeGetCurrent()
        let fireTime = now + (delay / 1000.0)

        let entry = JeffJSTimerEntry(
            id: id,
            callback: callback.dupValue(),
            args: extraArgs.map { $0.dupValue() },
            interval: delay,
            isInterval: isInterval,
            fireTime: fireTime
        )

        state.timers[id] = entry
        return .newInt32(id)
    }

    /// clearTimeout(id)
    /// Cancels a timeout previously established by setTimeout.
    static func jsClearTimeout(ctx: JeffJSContext, this: JeffJSValue,
                               args: [JeffJSValue]) -> JeffJSValue {
        return cancelTimer(ctx: ctx, args: args)
    }

    /// clearInterval(id)
    /// Cancels a repeated action established by setInterval.
    static func jsClearInterval(ctx: JeffJSContext, this: JeffJSValue,
                                args: [JeffJSValue]) -> JeffJSValue {
        return cancelTimer(ctx: ctx, args: args)
    }

    /// Internal: cancel a timer by ID.
    private static func cancelTimer(ctx: JeffJSContext, args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 1 else { return .undefined }

        let idVal = args[0]
        let id: Int32
        if idVal.isInt {
            id = idVal.toInt32()
        } else if idVal.isFloat64 {
            id = Int32(idVal.toFloat64())
        } else {
            return .undefined
        }

        let state = getState(ctx: ctx)
        if let entry = state.timers[id] {
            entry.cancelled = true
            // Free the callback and args
            entry.callback.freeValue()
            for arg in entry.args {
                arg.freeValue()
            }
            state.timers.removeValue(forKey: id)
        }
        return .undefined
    }

    /// Poll and execute any timers that have fired.
    /// Called by the event loop. Returns the number of timers executed.
    /// Mirrors `js_os_poll` timer handling from quickjs-libc.c.
    static func pollTimers(ctx: JeffJSContext) -> Int {
        let state = getState(ctx: ctx)
        let now = CFAbsoluteTimeGetCurrent()
        var fired = 0

        // Copy timer IDs to avoid mutation during iteration
        let timerIDs = Array(state.timers.keys)

        for id in timerIDs {
            guard let entry = state.timers[id], !entry.cancelled else { continue }
            if entry.fireTime <= now {
                // Fire the callback
                _ = ctx.call(entry.callback, thisArg: .undefined, args: entry.args)
                // Drain microtask queue so Promise reactions fire immediately
                _ = ctx.rt.executePendingJobs()
                fired += 1

                if entry.isInterval && !entry.cancelled {
                    // Reschedule
                    entry.fireTime = now + (entry.interval / 1000.0)
                } else {
                    // One-shot: clean up
                    entry.callback.freeValue()
                    for arg in entry.args {
                        arg.freeValue()
                    }
                    state.timers.removeValue(forKey: id)
                }
            }
        }

        return fired
    }

    /// Returns the delay (in ms) until the next timer fires, or -1 if no timers.
    /// Used by the event loop to determine how long to sleep.
    static func getTimerDelay(ctx: JeffJSContext) -> Double {
        let state = getState(ctx: ctx)
        if state.timers.isEmpty { return -1 }

        let now = CFAbsoluteTimeGetCurrent()
        var minDelay = Double.infinity

        for (_, entry) in state.timers where !entry.cancelled {
            let delay = (entry.fireTime - now) * 1000.0
            if delay < minDelay { minDelay = delay }
        }

        return minDelay == Double.infinity ? -1 : max(0, minDelay)
    }

    // MARK: - Performance

    /// Register the `performance` object on the global object.
    /// Provides performance.now() and performance.timeOrigin.
    static func addPerformance(ctx: JeffJSContext) {
        let state = getState(ctx: ctx)
        let global = ctx.getGlobalObject()
        let perfObj = ctx.newPlainObject()

        // performance.now() returns milliseconds since timeOrigin
        ctx.setPropertyFunc(obj: perfObj, name: "now", fn: performanceNow, length: 0)

        // performance.timeOrigin — the time when the context was created
        // Store as a double property (Unix timestamp in ms)
        let timeOriginMS = state.timeOrigin * 1000.0
        let timeOriginVal = JeffJSValue.newFloat64(timeOriginMS)
        _ = ctx.setPropertyStr(obj: perfObj, name: "timeOrigin", value: timeOriginVal)

        _ = ctx.setPropertyStr(obj: global, name: "performance", value: perfObj)
    }

    /// performance.now()
    /// Returns a DOMHighResTimeStamp in milliseconds since context creation.
    /// Mirrors os_now() from quickjs-libc.c (but relative to timeOrigin).
    static func performanceNow(ctx: JeffJSContext, this: JeffJSValue,
                               args: [JeffJSValue]) -> JeffJSValue {
        let state = getState(ctx: ctx)
        let elapsed = (CFAbsoluteTimeGetCurrent() - state.timeOrigin) * 1000.0
        return .newFloat64(elapsed)
    }

    // MARK: - TextEncoder / TextDecoder

    /// Register TextEncoder and TextDecoder constructors on the global object.
    /// Mirrors the approach used in quickjs-libc.c for custom classes.
    static func addTextCodec(ctx: JeffJSContext) {
        let global = ctx.getGlobalObject()

        // TextEncoder
        let encoderObj = ctx.newPlainObject()
        ctx.setPropertyFunc(obj: encoderObj, name: "encode", fn: textEncoderEncode, length: 1)
        ctx.setPropertyFunc(obj: encoderObj, name: "encodeInto", fn: textEncoderEncodeInto, length: 2)
        _ = ctx.setPropertyStr(obj: encoderObj, name: "encoding",
                               value: JeffJSValue.makeString(JeffJSString(swiftString: "utf-8")))

        // TextEncoder constructor function
        ctx.setPropertyFunc(obj: global, name: "TextEncoder", fn: textEncoderConstructor, length: 0)

        // TextDecoder
        let decoderObj = ctx.newPlainObject()
        ctx.setPropertyFunc(obj: decoderObj, name: "decode", fn: textDecoderDecode, length: 1)
        _ = ctx.setPropertyStr(obj: decoderObj, name: "encoding",
                               value: JeffJSValue.makeString(JeffJSString(swiftString: "utf-8")))

        // TextDecoder constructor function
        ctx.setPropertyFunc(obj: global, name: "TextDecoder", fn: textDecoderConstructor, length: 0)
    }

    /// new TextEncoder() constructor
    static func textEncoderConstructor(ctx: JeffJSContext, this: JeffJSValue,
                                       args: [JeffJSValue]) -> JeffJSValue {
        let obj = ctx.newPlainObject()
        _ = ctx.setPropertyStr(obj: obj, name: "encoding",
                               value: JeffJSValue.makeString(JeffJSString(swiftString: "utf-8")))
        ctx.setPropertyFunc(obj: obj, name: "encode", fn: textEncoderEncode, length: 1)
        ctx.setPropertyFunc(obj: obj, name: "encodeInto", fn: textEncoderEncodeInto, length: 2)
        return obj
    }

    /// TextEncoder.encode(string) -> Uint8Array
    /// Encodes a string into a Uint8Array of UTF-8 bytes.
    static func textEncoderEncode(ctx: JeffJSContext, this: JeffJSValue,
                                  args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 1 else {
            return ctx.newTypedArray(bytes: [])
        }

        let input = args[0]
        let swiftStr: String
        if input.isString, let s = input.stringValue {
            swiftStr = s.toSwiftString()
        } else {
            let str = ctx.toString(input)
            if str.isException { return str }
            if let s = str.stringValue {
                swiftStr = s.toSwiftString()
            } else {
                swiftStr = ""
            }
        }

        let utf8Bytes = Array(swiftStr.utf8)
        return ctx.newTypedArray(bytes: utf8Bytes)
    }

    /// TextEncoder.encodeInto(string, uint8array) -> { read, written }
    /// Encodes a string into an existing Uint8Array.
    static func textEncoderEncodeInto(ctx: JeffJSContext, this: JeffJSValue,
                                      args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 2 else {
            return ctx.throwTypeError("encodeInto requires 2 arguments")
        }

        let input = args[0]
        let destination = args[1]

        let swiftStr: String
        if input.isString, let s = input.stringValue {
            swiftStr = s.toSwiftString()
        } else {
            let str = ctx.toString(input)
            if str.isException { return str }
            if let s = str.stringValue {
                swiftStr = s.toSwiftString()
            } else {
                swiftStr = ""
            }
        }

        let utf8Bytes = Array(swiftStr.utf8)

        // Get the destination buffer length
        let destLength = ctx.getTypedArrayLength(destination)

        let writeCount = min(utf8Bytes.count, destLength)
        // Write bytes into the typed array
        for i in 0..<writeCount {
            _ = ctx.setTypedArrayByte(destination, index: i, value: utf8Bytes[i])
        }

        // Count how many characters were fully read
        var charsRead = 0
        var bytesConsumed = 0
        for scalar in swiftStr.unicodeScalars {
            let scalarByteLen = scalar.utf8.count
            if bytesConsumed + scalarByteLen > writeCount { break }
            bytesConsumed += scalarByteLen
            charsRead += 1
        }

        // Return { read, written }
        let result = ctx.newPlainObject()
        _ = ctx.setPropertyStr(obj: result, name: "read", value: .newInt32(Int32(charsRead)))
        _ = ctx.setPropertyStr(obj: result, name: "written", value: .newInt32(Int32(writeCount)))
        return result
    }

    /// new TextDecoder(encoding?) constructor
    static func textDecoderConstructor(ctx: JeffJSContext, this: JeffJSValue,
                                       args: [JeffJSValue]) -> JeffJSValue {
        // We only support UTF-8 for now (matching QuickJS behavior)
        let obj = ctx.newPlainObject()
        _ = ctx.setPropertyStr(obj: obj, name: "encoding",
                               value: JeffJSValue.makeString(JeffJSString(swiftString: "utf-8")))
        ctx.setPropertyFunc(obj: obj, name: "decode", fn: textDecoderDecode, length: 1)
        return obj
    }

    /// TextDecoder.decode(buffer) -> string
    /// Decodes a buffer of bytes into a string using UTF-8.
    static func textDecoderDecode(ctx: JeffJSContext, this: JeffJSValue,
                                  args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 1 else {
            return JeffJSValue.makeString(JeffJSString(swiftString: ""))
        }

        let buffer = args[0]
        let bytes = ctx.getTypedArrayBytes(buffer)
        if let decoded = String(bytes: bytes, encoding: .utf8) {
            return JeffJSValue.makeString(JeffJSString(swiftString: decoded))
        }
        // Invalid UTF-8: replace with replacement character (matching browser behavior)
        let decoded = String(decoding: bytes, as: UTF8.self)
        return JeffJSValue.makeString(JeffJSString(swiftString: decoded))
    }

    // MARK: - URL / URLSearchParams

    /// Register basic URL and URLSearchParams constructors on the global object.
    /// This is a simplified version; the full WHATWG URL spec is very large.
    static func addURL(ctx: JeffJSContext) {
        let global = ctx.getGlobalObject()

        // URL constructor
        ctx.setPropertyFunc(obj: global, name: "URL", fn: urlConstructor, length: 1)

        // URLSearchParams constructor
        ctx.setPropertyFunc(obj: global, name: "URLSearchParams",
                           fn: urlSearchParamsConstructor, length: 0)
    }

    /// new URL(url, base?)
    /// Parses a URL string. Uses Foundation's URLComponents for parsing.
    static func urlConstructor(ctx: JeffJSContext, this: JeffJSValue,
                               args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 1 else {
            return ctx.throwTypeError("Failed to construct 'URL': 1 argument required")
        }

        let urlStr: String
        if args[0].isString, let s = args[0].stringValue {
            urlStr = s.toSwiftString()
        } else {
            let str = ctx.toString(args[0])
            if str.isException { return str }
            if let s = str.stringValue {
                urlStr = s.toSwiftString()
            } else {
                urlStr = ""
            }
        }

        // Optional base URL
        var baseStr: String? = nil
        if args.count >= 2 && !args[1].isUndefined {
            if args[1].isString, let s = args[1].stringValue {
                baseStr = s.toSwiftString()
            } else {
                let str = ctx.toString(args[1])
                if !str.isException, let s = str.stringValue {
                    baseStr = s.toSwiftString()
                }
            }
        }

        // Parse using Foundation
        let resolvedURL: URL?
        if let base = baseStr, let baseURL = URL(string: base) {
            resolvedURL = URL(string: urlStr, relativeTo: baseURL)
        } else {
            resolvedURL = URL(string: urlStr)
        }

        guard let url = resolvedURL, let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return ctx.throwTypeError("Failed to construct 'URL': Invalid URL")
        }

        // Build the URL object
        let obj = ctx.newPlainObject()

        let absoluteString = url.absoluteString
        _ = ctx.setPropertyStr(obj: obj, name: "href",
                               value: JeffJSValue.makeString(JeffJSString(swiftString: absoluteString)))
        _ = ctx.setPropertyStr(obj: obj, name: "origin",
                               value: JeffJSValue.makeString(JeffJSString(swiftString: "\(components.scheme ?? "")://\(components.host ?? "")\(components.port.map { ":\($0)" } ?? "")")))
        _ = ctx.setPropertyStr(obj: obj, name: "protocol",
                               value: JeffJSValue.makeString(JeffJSString(swiftString: (components.scheme ?? "") + ":")))
        _ = ctx.setPropertyStr(obj: obj, name: "host",
                               value: JeffJSValue.makeString(JeffJSString(swiftString: components.host ?? "")))
        _ = ctx.setPropertyStr(obj: obj, name: "hostname",
                               value: JeffJSValue.makeString(JeffJSString(swiftString: components.host ?? "")))
        _ = ctx.setPropertyStr(obj: obj, name: "port",
                               value: JeffJSValue.makeString(JeffJSString(swiftString: components.port.map(String.init) ?? "")))
        _ = ctx.setPropertyStr(obj: obj, name: "pathname",
                               value: JeffJSValue.makeString(JeffJSString(swiftString: components.path)))
        _ = ctx.setPropertyStr(obj: obj, name: "search",
                               value: JeffJSValue.makeString(JeffJSString(swiftString: components.query.map { "?\($0)" } ?? "")))
        _ = ctx.setPropertyStr(obj: obj, name: "hash",
                               value: JeffJSValue.makeString(JeffJSString(swiftString: components.fragment.map { "#\($0)" } ?? "")))
        _ = ctx.setPropertyStr(obj: obj, name: "username",
                               value: JeffJSValue.makeString(JeffJSString(swiftString: components.user ?? "")))
        _ = ctx.setPropertyStr(obj: obj, name: "password",
                               value: JeffJSValue.makeString(JeffJSString(swiftString: components.password ?? "")))

        // toString() returns the href
        ctx.setPropertyFunc(obj: obj, name: "toString", fn: { ctx, this, _ in
            return ctx.getPropertyStr(obj: this, name: "href")
        }, length: 0)

        // toJSON() returns the href
        ctx.setPropertyFunc(obj: obj, name: "toJSON", fn: { ctx, this, _ in
            return ctx.getPropertyStr(obj: this, name: "href")
        }, length: 0)

        // searchParams property
        let searchParams = buildSearchParams(ctx: ctx, query: components.query ?? "")
        _ = ctx.setPropertyStr(obj: obj, name: "searchParams", value: searchParams)

        return obj
    }

    /// Build a URLSearchParams object from a query string.
    private static func buildSearchParams(ctx: JeffJSContext, query: String) -> JeffJSValue {
        let obj = ctx.newPlainObject()
        var entries: [(String, String)] = []

        // Parse query string
        let stripped = query.hasPrefix("?") ? String(query.dropFirst()) : query
        if !stripped.isEmpty {
            for pair in stripped.split(separator: "&", omittingEmptySubsequences: false) {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""
                entries.append((key, value))
            }
        }

        // Store entries as internal data
        let entriesArray = ctx.newArray()
        for (i, (key, value)) in entries.enumerated() {
            let pair = ctx.newArray()
            _ = ctx.setPropertyByIndex(obj: pair, index: 0,
                                       value: JeffJSValue.makeString(JeffJSString(swiftString: key)))
            _ = ctx.setPropertyByIndex(obj: pair, index: 1,
                                       value: JeffJSValue.makeString(JeffJSString(swiftString: value)))
            _ = ctx.setPropertyByIndex(obj: entriesArray, index: UInt32(i), value: pair)
        }
        _ = ctx.setPropertyStr(obj: obj, name: "_entries", value: entriesArray)

        // get(name) -> first value or null
        ctx.setPropertyFunc(obj: obj, name: "get", fn: urlSearchParamsGet, length: 1)
        // has(name) -> boolean
        ctx.setPropertyFunc(obj: obj, name: "has", fn: urlSearchParamsHas, length: 1)
        // toString()
        ctx.setPropertyFunc(obj: obj, name: "toString", fn: urlSearchParamsToString, length: 0)

        return obj
    }

    /// new URLSearchParams(init?)
    static func urlSearchParamsConstructor(ctx: JeffJSContext, this: JeffJSValue,
                                           args: [JeffJSValue]) -> JeffJSValue {
        let query: String
        if args.count >= 1 && args[0].isString, let s = args[0].stringValue {
            query = s.toSwiftString()
        } else {
            query = ""
        }
        return buildSearchParams(ctx: ctx, query: query)
    }

    /// URLSearchParams.get(name) -> string | null
    static func urlSearchParamsGet(ctx: JeffJSContext, this: JeffJSValue,
                                   args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 1 else { return .null }
        let nameStr: String
        if args[0].isString, let s = args[0].stringValue {
            nameStr = s.toSwiftString()
        } else {
            return .null
        }

        let entries = ctx.getPropertyStr(obj: this, name: "_entries")
        if entries.isUndefined { return .null }

        let len = ctx.getArrayLength(entries)
        for i in 0..<len {
            let pair = ctx.getPropertyByIndex(obj: entries, index: UInt32(i))
            let key = ctx.getPropertyByIndex(obj: pair, index: 0)
            if key.isString, let s = key.stringValue, s.toSwiftString() == nameStr {
                return ctx.getPropertyByIndex(obj: pair, index: 1)
            }
        }
        return .null
    }

    /// URLSearchParams.has(name) -> boolean
    static func urlSearchParamsHas(ctx: JeffJSContext, this: JeffJSValue,
                                   args: [JeffJSValue]) -> JeffJSValue {
        let result = urlSearchParamsGet(ctx: ctx, this: this, args: args)
        return result.isNull ? .JS_FALSE : .JS_TRUE
    }

    /// URLSearchParams.toString() -> string
    static func urlSearchParamsToString(ctx: JeffJSContext, this: JeffJSValue,
                                        args: [JeffJSValue]) -> JeffJSValue {
        let entries = ctx.getPropertyStr(obj: this, name: "_entries")
        if entries.isUndefined {
            return JeffJSValue.makeString(JeffJSString(swiftString: ""))
        }

        var parts: [String] = []
        let len = ctx.getArrayLength(entries)
        for i in 0..<len {
            let pair = ctx.getPropertyByIndex(obj: entries, index: UInt32(i))
            let key = ctx.getPropertyByIndex(obj: pair, index: 0)
            let value = ctx.getPropertyByIndex(obj: pair, index: 1)
            if let k = key.stringValue, let v = value.stringValue {
                let encodedKey = k.toSwiftString().addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? k.toSwiftString()
                let encodedValue = v.toSwiftString().addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? v.toSwiftString()
                parts.append("\(encodedKey)=\(encodedValue)")
            }
        }

        return JeffJSValue.makeString(JeffJSString(swiftString: parts.joined(separator: "&")))
    }

    // MARK: - structuredClone

    /// Register structuredClone on the global object.
    static func addStructuredClone(ctx: JeffJSContext) {
        let global = ctx.getGlobalObject()
        ctx.setPropertyFunc(obj: global, name: "structuredClone",
                           fn: jsStructuredClone, length: 1)
    }

    /// structuredClone(value, options?)
    /// Creates a deep clone of a value.
    /// This is a simplified implementation that handles primitives, plain objects,
    /// arrays, dates, RegExps, ArrayBuffers, and typed arrays.
    static func jsStructuredClone(ctx: JeffJSContext, this: JeffJSValue,
                                  args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 1 else {
            return .undefined
        }
        let value = args[0]

        // Primitives are returned as-is (they are value types in JS)
        if value.isUndefined || value.isNull || value.isBool || value.isInt ||
           value.isFloat64 || value.isString || value.isBigInt {
            return value.dupValue()
        }

        // Objects: do a deep clone
        if value.isObject {
            var seenMap: [ObjectIdentifier: JeffJSValue] = [:]
            return deepClone(ctx: ctx, value: value, seen: &seenMap)
        }

        return value.dupValue()
    }

    /// Internal recursive deep clone.
    private static func deepClone(ctx: JeffJSContext, value: JeffJSValue,
                                  seen: inout [ObjectIdentifier: JeffJSValue]) -> JeffJSValue {
        guard value.isObject else { return value.dupValue() }

        // Check for circular references
        if let obj = value.toObject() {
            let oid = ObjectIdentifier(obj)
            if let existing = seen[oid] {
                return existing.dupValue()
            }
        }

        // Check if it is an array
        if ctx.isArray(value) {
            let cloned = ctx.newArray()
            if let obj = value.toObject() {
                seen[ObjectIdentifier(obj)] = cloned
            }

            let len = ctx.getArrayLength(value)
            for i in 0..<len {
                let elem = ctx.getPropertyByIndex(obj: value, index: UInt32(i))
                let clonedElem = deepClone(ctx: ctx, value: elem, seen: &seen)
                _ = ctx.setPropertyByIndex(obj: cloned, index: UInt32(i), value: clonedElem)
            }
            return cloned
        }

        // Plain object
        let cloned = ctx.newPlainObject()
        if let obj = value.toObject() {
            seen[ObjectIdentifier(obj)] = cloned
        }

        let keys = ctx.getOwnPropertyNames(value, flags: JS_GPN_STRING_MASK | JS_GPN_SYMBOL_MASK)
        if !keys.isException {
            let len = ctx.getArrayLength(keys)
            for i in 0..<len {
                let key = ctx.getPropertyByIndex(obj: keys, index: UInt32(i))
                let val = ctx.getProperty(obj: value, key: key)
                let clonedVal = deepClone(ctx: ctx, value: val, seen: &seen)
                _ = ctx.setProperty(obj: cloned, key: key, value: clonedVal)
            }
        }

        return cloned
    }

    // MARK: - queueMicrotask

    /// Register queueMicrotask on the global object.
    static func addMicrotask(ctx: JeffJSContext) {
        let global = ctx.getGlobalObject()
        ctx.setPropertyFunc(obj: global, name: "queueMicrotask",
                           fn: jsQueueMicrotask, length: 1)
    }

    /// queueMicrotask(callback)
    /// Queues a microtask (runs before the next task, after the current one).
    /// In QuickJS, this enqueues a job on the job queue.
    static func jsQueueMicrotask(ctx: JeffJSContext, this: JeffJSValue,
                                 args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 1 else {
            return ctx.throwTypeError("queueMicrotask requires 1 argument")
        }

        let callback = args[0]
        if !callback.isObject {
            return ctx.throwTypeError("Argument to queueMicrotask must be a function")
        }

        // Enqueue as a job on the context's job queue
        let duped = callback.dupValue()
        ctx.rt.enqueueJob(ctx: ctx, jobFunc: { ctx, _, _ in
            return ctx.call(duped, thisArg: .undefined, args: [])
        }, args: [])
        return .undefined
    }

    // MARK: - Base64 (atob / btoa)

    /// Register atob and btoa on the global object.
    static func addBase64(ctx: JeffJSContext) {
        let global = ctx.getGlobalObject()
        ctx.setPropertyFunc(obj: global, name: "atob", fn: jsAtob, length: 1)
        ctx.setPropertyFunc(obj: global, name: "btoa", fn: jsBtoa, length: 1)
    }

    /// btoa(data) -> base64String
    /// Encodes a string of binary data to Base64.
    /// Mirrors the browser btoa() behavior (Latin-1 only).
    static func jsBtoa(ctx: JeffJSContext, this: JeffJSValue,
                       args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 1 else {
            return ctx.throwTypeError("btoa requires 1 argument")
        }

        let input = args[0]
        let swiftStr: String
        if input.isString, let s = input.stringValue {
            swiftStr = s.toSwiftString()
        } else {
            let str = ctx.toString(input)
            if str.isException { return str }
            if let s = str.stringValue {
                swiftStr = s.toSwiftString()
            } else {
                swiftStr = ""
            }
        }

        // btoa only accepts Latin-1 characters (0-255)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(swiftStr.count)
        for scalar in swiftStr.unicodeScalars {
            if scalar.value > 255 {
                return ctx.throwTypeError("The string to be encoded contains characters outside of the Latin1 range")
            }
            bytes.append(UInt8(scalar.value))
        }

        let data = Data(bytes)
        let base64 = data.base64EncodedString()
        return JeffJSValue.makeString(JeffJSString(swiftString: base64))
    }

    /// atob(base64String) -> data
    /// Decodes a Base64-encoded string.
    /// Mirrors the browser atob() behavior.
    static func jsAtob(ctx: JeffJSContext, this: JeffJSValue,
                       args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 1 else {
            return ctx.throwTypeError("atob requires 1 argument")
        }

        let input = args[0]
        let swiftStr: String
        if input.isString, let s = input.stringValue {
            swiftStr = s.toSwiftString()
        } else {
            let str = ctx.toString(input)
            if str.isException { return str }
            if let s = str.stringValue {
                swiftStr = s.toSwiftString()
            } else {
                swiftStr = ""
            }
        }

        // Strip whitespace (matching browser behavior)
        let stripped = swiftStr.filter { !$0.isWhitespace }

        guard let data = Data(base64Encoded: stripped) else {
            return ctx.throwTypeError("The string to be decoded is not correctly encoded")
        }

        // Convert back to a Latin-1 string (each byte maps to one char)
        let decoded = String(data.map { Character(Unicode.Scalar($0)) })
        return JeffJSValue.makeString(JeffJSString(swiftString: decoded))
    }
}

// MARK: - Per-Context State

/// Internal state maintained per JeffJSContext for the standard library.
private final class JeffJSStdLibState {
    var console: JeffJSConsoleState = JeffJSConsoleState()
    var timers: [Int32: JeffJSTimerEntry] = [:]
    var nextTimerId: Int32 = 1
    var timeOrigin: Double = CFAbsoluteTimeGetCurrent()  // for performance.now()
    var microtaskQueue: [JeffJSValue] = []

    init() {}
}

// MARK: - QuickJS 'std' Module

extension JeffJSStdLib {

    /// Register the 'std' module.
    /// Mirrors `js_init_module_std` from quickjs-libc.c.
    static func addStdModule(ctx: JeffJSContext) {
        let global = ctx.getGlobalObject()
        let stdObj = ctx.newPlainObject()

        ctx.setPropertyFunc(obj: stdObj, name: "exit", fn: stdExit, length: 1)
        ctx.setPropertyFunc(obj: stdObj, name: "gc", fn: stdGC, length: 0)
        ctx.setPropertyFunc(obj: stdObj, name: "evalScript", fn: stdEvalScript, length: 1)
        ctx.setPropertyFunc(obj: stdObj, name: "loadScript", fn: stdLoadScript, length: 1)
        ctx.setPropertyFunc(obj: stdObj, name: "loadFile", fn: stdLoadFile, length: 1)
        ctx.setPropertyFunc(obj: stdObj, name: "print", fn: stdPrint, length: 1)

        // Error constants
        _ = ctx.setPropertyStr(obj: stdObj, name: "SEEK_SET", value: .newInt32(0))
        _ = ctx.setPropertyStr(obj: stdObj, name: "SEEK_CUR", value: .newInt32(1))
        _ = ctx.setPropertyStr(obj: stdObj, name: "SEEK_END", value: .newInt32(2))

        _ = ctx.setPropertyStr(obj: global, name: "std", value: stdObj)
    }

    /// std.exit(exitCode)
    /// Terminates the process with the given exit code.
    /// Mirrors `js_std_exit` in quickjs-libc.c.
    static func stdExit(ctx: JeffJSContext, this: JeffJSValue,
                        args: [JeffJSValue]) -> JeffJSValue {
        var exitCode: Int32 = 0
        if args.count >= 1 {
            if args[0].isInt {
                exitCode = args[0].toInt32()
            } else if args[0].isFloat64 {
                exitCode = Int32(args[0].toFloat64())
            }
        }
        exit(exitCode)
        // unreachable
    }

    /// std.gc()
    /// Forces a garbage collection cycle.
    /// Mirrors `js_std_gc` in quickjs-libc.c.
    static func stdGC(ctx: JeffJSContext, this: JeffJSValue,
                      args: [JeffJSValue]) -> JeffJSValue {
        ctx.rt.runGC()
        return .undefined
    }

    /// std.evalScript(sourceStr, options?)
    /// Evaluates a string as JavaScript source.
    /// Mirrors `js_std_evalScript` in quickjs-libc.c.
    static func stdEvalScript(ctx: JeffJSContext, this: JeffJSValue,
                              args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 1 else {
            return ctx.throwTypeError("evalScript requires 1 argument")
        }

        let source = args[0]
        let swiftStr: String
        if source.isString, let s = source.stringValue {
            swiftStr = s.toSwiftString()
        } else {
            let str = ctx.toString(source)
            if str.isException { return str }
            if let s = str.stringValue {
                swiftStr = s.toSwiftString()
            } else {
                swiftStr = ""
            }
        }

        // Check for options.backtrace_barrier
        var flags = JS_EVAL_TYPE_GLOBAL
        if args.count >= 2 && args[1].isObject {
            let barrier = ctx.getPropertyStr(obj: args[1], name: "backtrace_barrier")
            if !barrier.isUndefined {
                let boolVal: Bool
                if barrier.isBool {
                    boolVal = barrier.toBool()
                } else {
                    boolVal = false
                }
                if boolVal {
                    flags |= JS_EVAL_FLAG_BACKTRACE_BARRIER
                }
            }
        }

        return ctx.eval(input: swiftStr, filename: "<evalScript>", evalFlags: flags)
    }

    /// std.loadScript(filename)
    /// Loads and evaluates a JavaScript file.
    /// Mirrors `js_std_loadScript` in quickjs-libc.c.
    static func stdLoadScript(ctx: JeffJSContext, this: JeffJSValue,
                              args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 1 else {
            return ctx.throwTypeError("loadScript requires a filename argument")
        }

        let filenameStr: String
        if args[0].isString, let s = args[0].stringValue {
            filenameStr = s.toSwiftString()
        } else {
            return ctx.throwTypeError("loadScript: filename must be a string")
        }

        // Read the file
        guard let data = FileManager.default.contents(atPath: filenameStr),
              let source = String(data: data, encoding: .utf8) else {
            return ctx.throwTypeError("loadScript: could not read file '\(filenameStr)'")
        }

        return ctx.eval(input: source, filename: filenameStr, evalFlags: JS_EVAL_TYPE_GLOBAL)
    }

    /// std.loadFile(filename) -> string | null
    /// Loads a file and returns its contents as a string.
    /// Mirrors `js_std_loadFile` in quickjs-libc.c.
    static func stdLoadFile(ctx: JeffJSContext, this: JeffJSValue,
                            args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 1 else { return .null }

        let filenameStr: String
        if args[0].isString, let s = args[0].stringValue {
            filenameStr = s.toSwiftString()
        } else {
            return .null
        }

        guard let data = FileManager.default.contents(atPath: filenameStr),
              let contents = String(data: data, encoding: .utf8) else {
            return .null
        }

        return JeffJSValue.makeString(JeffJSString(swiftString: contents))
    }

    /// std.print(...args)
    /// Prints arguments to stdout, separated by spaces, with a newline.
    /// Mirrors `js_std_print` in quickjs-libc.c.
    static func stdPrint(ctx: JeffJSContext, this: JeffJSValue,
                         args: [JeffJSValue]) -> JeffJSValue {
        let msg = formatConsoleArgs(ctx: ctx, args: args)
        print(msg)
        return .undefined
    }
}

// MARK: - QuickJS 'os' Module

extension JeffJSStdLib {

    /// Register the 'os' module.
    /// Mirrors `js_init_module_os` from quickjs-libc.c.
    static func addOsModule(ctx: JeffJSContext) {
        let global = ctx.getGlobalObject()
        let osObj = ctx.newPlainObject()

        ctx.setPropertyFunc(obj: osObj, name: "open", fn: osOpen, length: 2)
        ctx.setPropertyFunc(obj: osObj, name: "close", fn: osClose, length: 1)
        ctx.setPropertyFunc(obj: osObj, name: "read", fn: osRead, length: 3)
        ctx.setPropertyFunc(obj: osObj, name: "write", fn: osWrite, length: 3)
        ctx.setPropertyFunc(obj: osObj, name: "seek", fn: osSeek, length: 3)
        ctx.setPropertyFunc(obj: osObj, name: "sleep", fn: osSleep, length: 1)
        ctx.setPropertyFunc(obj: osObj, name: "setTimeout", fn: osSetTimeout, length: 2)
        ctx.setPropertyFunc(obj: osObj, name: "clearTimeout", fn: osClearTimeout, length: 1)
        ctx.setPropertyFunc(obj: osObj, name: "now", fn: osNow, length: 0)
        ctx.setPropertyFunc(obj: osObj, name: "getcwd", fn: osGetcwd, length: 0)
        ctx.setPropertyFunc(obj: osObj, name: "chdir", fn: osChdir, length: 1)
        ctx.setPropertyFunc(obj: osObj, name: "mkdir", fn: osMkdir, length: 1)
        ctx.setPropertyFunc(obj: osObj, name: "stat", fn: osStat, length: 1)
        ctx.setPropertyFunc(obj: osObj, name: "remove", fn: osRemove, length: 1)
        ctx.setPropertyFunc(obj: osObj, name: "rename", fn: osRename, length: 2)
        ctx.setPropertyFunc(obj: osObj, name: "realpath", fn: osRealpath, length: 1)
        ctx.setPropertyFunc(obj: osObj, name: "readdir", fn: osReaddir, length: 1)
        ctx.setPropertyFunc(obj: osObj, name: "tmpdir", fn: osTmpdir, length: 0)

        // POSIX open flags
        _ = ctx.setPropertyStr(obj: osObj, name: "O_RDONLY", value: .newInt32(0))
        _ = ctx.setPropertyStr(obj: osObj, name: "O_WRONLY", value: .newInt32(1))
        _ = ctx.setPropertyStr(obj: osObj, name: "O_RDWR", value: .newInt32(2))
        _ = ctx.setPropertyStr(obj: osObj, name: "O_CREAT", value: .newInt32(0x200))
        _ = ctx.setPropertyStr(obj: osObj, name: "O_EXCL", value: .newInt32(0x800))
        _ = ctx.setPropertyStr(obj: osObj, name: "O_TRUNC", value: .newInt32(0x400))
        _ = ctx.setPropertyStr(obj: osObj, name: "O_APPEND", value: .newInt32(8))

        // Platform string
        #if os(iOS)
        _ = ctx.setPropertyStr(obj: osObj, name: "platform",
                               value: JeffJSValue.makeString(JeffJSString(swiftString: "ios")))
        #elseif os(macOS)
        _ = ctx.setPropertyStr(obj: osObj, name: "platform",
                               value: JeffJSValue.makeString(JeffJSString(swiftString: "darwin")))
        #else
        _ = ctx.setPropertyStr(obj: osObj, name: "platform",
                               value: JeffJSValue.makeString(JeffJSString(swiftString: "unknown")))
        #endif

        _ = ctx.setPropertyStr(obj: global, name: "os", value: osObj)
    }

    /// os.open(filename, flags, mode?) -> fd
    /// Opens a file descriptor.
    /// Mirrors `js_os_open` in quickjs-libc.c.
    static func osOpen(ctx: JeffJSContext, this: JeffJSValue,
                       args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 2 else {
            return ctx.throwTypeError("os.open requires 2 arguments")
        }

        let filenameStr: String
        if args[0].isString, let s = args[0].stringValue {
            filenameStr = s.toSwiftString()
        } else {
            return ctx.throwTypeError("os.open: filename must be a string")
        }

        let flags: Int32
        if args[1].isInt {
            flags = args[1].toInt32()
        } else {
            flags = 0
        }

        let mode: Int32
        if args.count >= 3 && args[2].isInt {
            mode = args[2].toInt32()
        } else {
            mode = 0o666
        }

        let fd = Darwin.open(filenameStr, flags, mode_t(mode))
        if fd < 0 {
            return .newInt32(-Int32(errno))
        }
        return .newInt32(fd)
    }

    /// os.close(fd) -> 0 or negative error
    /// Closes a file descriptor.
    /// Mirrors `js_os_close` in quickjs-libc.c.
    static func osClose(ctx: JeffJSContext, this: JeffJSValue,
                        args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 1, args[0].isInt else {
            return .newInt32(-1)
        }
        let fd = args[0].toInt32()
        let ret = Darwin.close(fd)
        return .newInt32(ret < 0 ? -Int32(errno) : 0)
    }

    /// os.read(fd, buffer, offset, length) -> bytesRead
    /// Reads from a file descriptor into a buffer (ArrayBuffer/TypedArray).
    /// Mirrors `js_os_read` in quickjs-libc.c.
    static func osRead(ctx: JeffJSContext, this: JeffJSValue,
                       args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 3 else {
            return ctx.throwTypeError("os.read requires 3 arguments (fd, buffer, length)")
        }

        let fd: Int32
        if args[0].isInt {
            fd = args[0].toInt32()
        } else {
            return .newInt32(-1)
        }

        let length: Int
        if args[2].isInt {
            length = Int(args[2].toInt32())
        } else {
            return .newInt32(-1)
        }

        // Allocate a temporary buffer
        var buf = [UInt8](repeating: 0, count: length)
        let bytesRead = Darwin.read(fd, &buf, length)

        if bytesRead < 0 {
            return .newInt32(-Int32(errno))
        }

        // Write into the target buffer (args[1])
        for i in 0..<bytesRead {
            _ = ctx.setTypedArrayByte(args[1], index: i, value: buf[i])
        }

        return .newInt32(Int32(bytesRead))
    }

    /// os.write(fd, buffer, length) -> bytesWritten
    /// Writes from a buffer to a file descriptor.
    /// Mirrors `js_os_write` in quickjs-libc.c.
    static func osWrite(ctx: JeffJSContext, this: JeffJSValue,
                        args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 3 else {
            return ctx.throwTypeError("os.write requires 3 arguments (fd, buffer, length)")
        }

        let fd: Int32
        if args[0].isInt {
            fd = args[0].toInt32()
        } else {
            return .newInt32(-1)
        }

        let length: Int
        if args[2].isInt {
            length = Int(args[2].toInt32())
        } else {
            return .newInt32(-1)
        }

        // Read bytes from the source buffer
        let bytes = ctx.getTypedArrayBytes(args[1])
        let writeLen = min(length, bytes.count)

        var buf = Array(bytes.prefix(writeLen))
        let bytesWritten = Darwin.write(fd, &buf, writeLen)

        if bytesWritten < 0 {
            return .newInt32(-Int32(errno))
        }
        return .newInt32(Int32(bytesWritten))
    }

    /// os.seek(fd, offset, whence) -> newPosition
    /// Repositions the file offset of the given file descriptor.
    /// Mirrors `js_os_seek` in quickjs-libc.c.
    static func osSeek(ctx: JeffJSContext, this: JeffJSValue,
                       args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 3 else {
            return ctx.throwTypeError("os.seek requires 3 arguments")
        }

        let fd: Int32
        if args[0].isInt { fd = args[0].toInt32() }
        else { return .newInt32(-1) }

        let offset: Int64
        if args[1].isInt { offset = Int64(args[1].toInt32()) }
        else if args[1].isFloat64 { offset = Int64(args[1].toFloat64()) }
        else { return .newInt32(-1) }

        let whence: Int32
        if args[2].isInt { whence = args[2].toInt32() }
        else { whence = 0 }

        let result = lseek(fd, off_t(offset), whence)
        if result < 0 {
            return .newInt32(-Int32(errno))
        }
        return JeffJSValue.newInt64(Int64(result))
    }

    /// os.sleep(delayMs) -> undefined
    /// Sleeps for the specified number of milliseconds.
    /// Mirrors `js_os_sleep` in quickjs-libc.c.
    static func osSleep(ctx: JeffJSContext, this: JeffJSValue,
                        args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 1 else { return .undefined }

        let delayMs: Double
        if args[0].isInt {
            delayMs = Double(args[0].toInt32())
        } else if args[0].isFloat64 {
            delayMs = args[0].toFloat64()
        } else {
            return .undefined
        }

        if delayMs > 0 {
            Thread.sleep(forTimeInterval: delayMs / 1000.0)
        }
        return .undefined
    }

    /// os.setTimeout(func, delay) -> timerId
    /// OS-level setTimeout (uses the same timer infrastructure).
    /// Mirrors `js_os_setTimeout` in quickjs-libc.c.
    static func osSetTimeout(ctx: JeffJSContext, this: JeffJSValue,
                             args: [JeffJSValue]) -> JeffJSValue {
        return jsSetTimeout(ctx: ctx, this: this, args: args)
    }

    /// os.clearTimeout(id)
    /// OS-level clearTimeout.
    /// Mirrors `js_os_clearTimeout` in quickjs-libc.c.
    static func osClearTimeout(ctx: JeffJSContext, this: JeffJSValue,
                               args: [JeffJSValue]) -> JeffJSValue {
        return jsClearTimeout(ctx: ctx, this: this, args: args)
    }

    /// os.now() -> timestamp
    /// Returns the current time in milliseconds (monotonic clock).
    /// Mirrors `js_os_now` in quickjs-libc.c.
    static func osNow(ctx: JeffJSContext, this: JeffJSValue,
                      args: [JeffJSValue]) -> JeffJSValue {
        let now = CFAbsoluteTimeGetCurrent() * 1000.0
        return .newFloat64(now)
    }

    /// os.getcwd() -> string
    /// Returns the current working directory.
    static func osGetcwd(ctx: JeffJSContext, this: JeffJSValue,
                         args: [JeffJSValue]) -> JeffJSValue {
        let cwd = FileManager.default.currentDirectoryPath
        return JeffJSValue.makeString(JeffJSString(swiftString: cwd))
    }

    /// os.chdir(path) -> 0 or error
    /// Changes the current working directory.
    static func osChdir(ctx: JeffJSContext, this: JeffJSValue,
                        args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 1, let s = args[0].stringValue else {
            return .newInt32(-1)
        }
        let path = s.toSwiftString()
        let ret = Darwin.chdir(path)
        return .newInt32(ret < 0 ? -Int32(errno) : 0)
    }

    /// os.mkdir(path, mode?) -> 0 or error
    /// Creates a directory.
    static func osMkdir(ctx: JeffJSContext, this: JeffJSValue,
                        args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 1, let s = args[0].stringValue else {
            return .newInt32(-1)
        }
        let path = s.toSwiftString()
        let mode: mode_t
        if args.count >= 2 && args[1].isInt {
            mode = mode_t(args[1].toInt32())
        } else {
            mode = 0o777
        }
        let ret = Darwin.mkdir(path, mode)
        return .newInt32(ret < 0 ? -Int32(errno) : 0)
    }

    /// os.stat(path) -> { dev, ino, mode, nlink, uid, gid, rdev, size, ... } or null
    /// Returns file status information.
    static func osStat(ctx: JeffJSContext, this: JeffJSValue,
                       args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 1, let s = args[0].stringValue else {
            return .null
        }
        let path = s.toSwiftString()
        var sb = Darwin.stat()
        let ret = lstat(path, &sb)
        if ret < 0 { return .null }

        let obj = ctx.newPlainObject()
        _ = ctx.setPropertyStr(obj: obj, name: "dev", value: JeffJSValue.newInt64(Int64(sb.st_dev)))
        _ = ctx.setPropertyStr(obj: obj, name: "ino", value: JeffJSValue.newInt64(Int64(sb.st_ino)))
        _ = ctx.setPropertyStr(obj: obj, name: "mode", value: .newInt32(Int32(sb.st_mode)))
        _ = ctx.setPropertyStr(obj: obj, name: "nlink", value: JeffJSValue.newInt64(Int64(sb.st_nlink)))
        _ = ctx.setPropertyStr(obj: obj, name: "uid", value: .newInt32(Int32(sb.st_uid)))
        _ = ctx.setPropertyStr(obj: obj, name: "gid", value: .newInt32(Int32(sb.st_gid)))
        _ = ctx.setPropertyStr(obj: obj, name: "rdev", value: JeffJSValue.newInt64(Int64(sb.st_rdev)))
        _ = ctx.setPropertyStr(obj: obj, name: "size", value: JeffJSValue.newInt64(sb.st_size))
        _ = ctx.setPropertyStr(obj: obj, name: "atime",
                               value: .newFloat64(Double(sb.st_atimespec.tv_sec) * 1000.0 + Double(sb.st_atimespec.tv_nsec) / 1_000_000.0))
        _ = ctx.setPropertyStr(obj: obj, name: "mtime",
                               value: .newFloat64(Double(sb.st_mtimespec.tv_sec) * 1000.0 + Double(sb.st_mtimespec.tv_nsec) / 1_000_000.0))
        _ = ctx.setPropertyStr(obj: obj, name: "ctime",
                               value: .newFloat64(Double(sb.st_ctimespec.tv_sec) * 1000.0 + Double(sb.st_ctimespec.tv_nsec) / 1_000_000.0))
        return obj
    }

    /// os.remove(path) -> 0 or error
    /// Removes a file or empty directory.
    static func osRemove(ctx: JeffJSContext, this: JeffJSValue,
                         args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 1, let s = args[0].stringValue else {
            return .newInt32(-1)
        }
        let path = s.toSwiftString()
        let ret = Darwin.remove(path)
        return .newInt32(ret < 0 ? -Int32(errno) : 0)
    }

    /// os.rename(oldPath, newPath) -> 0 or error
    /// Renames a file or directory.
    static func osRename(ctx: JeffJSContext, this: JeffJSValue,
                         args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 2,
              let s1 = args[0].stringValue,
              let s2 = args[1].stringValue else {
            return .newInt32(-1)
        }
        let ret = Darwin.rename(s1.toSwiftString(), s2.toSwiftString())
        return .newInt32(ret < 0 ? -Int32(errno) : 0)
    }

    /// os.realpath(path) -> resolvedPath or null
    /// Returns the resolved absolute path.
    static func osRealpath(ctx: JeffJSContext, this: JeffJSValue,
                           args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 1, let s = args[0].stringValue else {
            return .null
        }
        let path = s.toSwiftString()
        guard let resolved = Darwin.realpath(path, nil) else {
            return .null
        }
        let result = String(cString: resolved)
        free(resolved)
        return JeffJSValue.makeString(JeffJSString(swiftString: result))
    }

    /// os.readdir(path) -> [filenames] or null
    /// Returns an array of filenames in the directory.
    static func osReaddir(ctx: JeffJSContext, this: JeffJSValue,
                          args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 1, let s = args[0].stringValue else {
            return .null
        }
        let path = s.toSwiftString()

        do {
            let entries = try FileManager.default.contentsOfDirectory(atPath: path)
            let arr = ctx.newArray()
            for (i, entry) in entries.enumerated() {
                _ = ctx.setPropertyByIndex(obj: arr, index: UInt32(i),
                                           value: JeffJSValue.makeString(JeffJSString(swiftString: entry)))
            }
            return arr
        } catch {
            return .null
        }
    }

    /// os.tmpdir() -> string
    /// Returns the system temporary directory path.
    static func osTmpdir(ctx: JeffJSContext, this: JeffJSValue,
                         args: [JeffJSValue]) -> JeffJSValue {
        let tmpDir = NSTemporaryDirectory()
        return JeffJSValue.makeString(JeffJSString(swiftString: tmpDir))
    }
}

// MARK: - Event Loop

extension JeffJSStdLib {

    /// Run the event loop until all pending jobs and timers have been processed.
    /// Mirrors `js_std_loop` from quickjs-libc.c.
    ///
    /// This processes:
    /// 1. The microtask/job queue (promise reactions, queueMicrotask)
    /// 2. Timer callbacks
    ///
    /// Returns when both queues are empty.
    static func loop(ctx: JeffJSContext) {
        while true {
            // 1. Drain the job queue (microtasks)
            let pendingJobCount = ctx.rt.executePendingJobs()
            let hasPendingJobs = pendingJobCount != 0

            // 2. Poll timers
            let timersFired = pollTimers(ctx: ctx)

            // If nothing happened and no more pending work, break
            if !hasPendingJobs && timersFired == 0 {
                let delay = getTimerDelay(ctx: ctx)
                if delay < 0 {
                    break  // no more timers
                }
                // Sleep for the minimum of delay or 100ms
                let sleepTime = min(delay, 100.0) / 1000.0
                if sleepTime > 0 {
                    Thread.sleep(forTimeInterval: sleepTime)
                }
            }
        }
    }
}

// MARK: - TypedArray Helpers

/// Extension on JeffJSContext providing TypedArray operations needed by the StdLib.
/// TODO: Replace with full TypedArray support once JeffJSContext natively supports TypedArrays.
extension JeffJSContext {

    /// Creates a new Uint8Array-like object from the given bytes.
    /// Currently returns a plain JS array of integers as a stub.
    func newTypedArray(bytes: [UInt8]) -> JeffJSValue {
        let arr = newArray()
        for (i, byte) in bytes.enumerated() {
            setPropertyByIndex(obj: arr, index: UInt32(i), value: .newInt32(Int32(byte)))
        }
        // Store length property for compatibility
        _ = setPropertyStr(obj: arr, name: "length", value: .newInt32(Int32(bytes.count)))
        _ = setPropertyStr(obj: arr, name: "byteLength", value: .newInt32(Int32(bytes.count)))
        return arr
    }

    /// Returns the length of a TypedArray (or array used as a TypedArray stub).
    func getTypedArrayLength(_ val: JeffJSValue) -> Int {
        let lenVal = getPropertyStr(obj: val, name: "length")
        if lenVal.isInt {
            return Int(lenVal.toInt32())
        }
        // Fall back to array length
        return Int(getArrayLength(val))
    }

    /// Returns the bytes from a TypedArray (or array used as a TypedArray stub).
    func getTypedArrayBytes(_ val: JeffJSValue) -> [UInt8] {
        let len = getTypedArrayLength(val)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(len)
        for i in 0..<len {
            let elem = getPropertyByIndex(obj: val, index: UInt32(i))
            if elem.isInt {
                bytes.append(UInt8(clamping: elem.toInt32()))
            } else if elem.isFloat64 {
                bytes.append(UInt8(clamping: Int(elem.toFloat64())))
            } else {
                bytes.append(0)
            }
        }
        return bytes
    }

    /// Sets a byte at the given index in a TypedArray (or array used as a TypedArray stub).
    @discardableResult
    func setTypedArrayByte(_ val: JeffJSValue, index: Int, value: UInt8) -> Bool {
        setPropertyByIndex(obj: val, index: UInt32(index), value: .newInt32(Int32(value)))
        return true
    }
}
