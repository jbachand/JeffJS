import Foundation

// MARK: - Pending-promise trace (debugging aid, `JEFFJS_PROMISE_TRACE=1`)
//
// Records every promise that something starts waiting on (`then` / `await` on a pending promise:
// `performPromiseThen`'s pending branch) with the JS stack of that first wait, and forgets it when the
// promise settles or is freed. `report(olderThan:)` lists the ones still pending — what a page that
// "just stops" is waiting for. No references are held (keyed by the promise's data object), so the
// trace never keeps a promise alive. Off: one Bool check on the pending branch.
nonisolated enum JeffJSPromiseTrace {
    static let enabled = ProcessInfo.processInfo.environment["JEFFJS_PROMISE_TRACE"] == "1"

    private struct Entry {
        let stack: String
        let created: String
        let since: CFAbsoluteTime
        var waits: Int
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [ObjectIdentifier: Entry] = [:]
    /// Creation stacks of promises not settled yet (only those with a JS frame).
    nonisolated(unsafe) private static var created: [ObjectIdentifier: String] = [:]

    private static func stackText(_ ctx: JeffJSContext) -> String {
        var natives: [(before: Int, name: String)] = []
        let frames = ctx.captureStackFrames(maxDepth: 12, natives: &natives, skipInnermostNative: false)
        let text = ctx.formatStackTrace(errorName: "", message: "", frames: frames, natives: natives)
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty && $0 != ": " }.joined(separator: " < ")
    }

    /// `new Promise(executor)`: the native functions the executor calls (what will settle it).
    nonisolated(unsafe) static var recordDepth = 0
    nonisolated(unsafe) private static var recorded: [[String]] = []
    static func beginExecutor() { lock.lock(); recordDepth += 1; recorded.append([]); lock.unlock() }
    static func noteNative(_ fn: JeffJSObject) {
        let v = fn.getOwnPropertyValue(atom: JeffJSAtomID.JS_ATOM_name.rawValue)
        let name = v.isString ? (v.stringValue?.toSwiftString() ?? "?") : "?"
        lock.lock(); defer { lock.unlock() }
        guard var top = recorded.popLast() else { return }
        // Distinct names in call order; glue internals (`__…`) and call/apply are noise.
        if top.count < 40, !name.hasPrefix("__"), name != "call", name != "apply", !top.contains(name) {
            top.append(name.isEmpty ? "(anonymous)" : name)
        }
        recorded.append(top)
    }
    static func endExecutor(_ data: JeffJSPromiseData) {
        let key = ObjectIdentifier(data)
        lock.lock()
        recordDepth = max(0, recordDepth - 1)
        guard let calls = recorded.popLast(), !calls.isEmpty else { lock.unlock(); return }
        created[key] = (created[key] ?? "") + " [executor called: " + calls.joined(separator: ", ") + "]"
        lock.unlock()
    }

    /// A promise object was made (`new Promise`, `then`'s derived promise, a capability, an async result).
    static func noteCreated(ctx: JeffJSContext, data: JeffJSPromiseData) {
        let stack = stackText(ctx)
        lock.lock(); created[ObjectIdentifier(data)] = stack; lock.unlock()
    }

    /// A reaction was queued on a pending promise.
    static func noteWait(ctx: JeffJSContext, data: JeffJSPromiseData) {
        let key = ObjectIdentifier(data)
        lock.lock()
        if var e = pending[key] {
            e.waits += 1
            pending[key] = e
            lock.unlock()
            return
        }
        lock.unlock()
        let stack = stackText(ctx)
        lock.lock()
        let made = created[key] ?? "?"
        pending[key] = Entry(stack: stack.isEmpty ? "(no JS frame: native/microtask)" : stack,
                             created: made.isEmpty ? "(no JS frame)" : made,
                             since: CFAbsoluteTimeGetCurrent(), waits: 1)
        lock.unlock()
    }

    /// The promise settled or was freed.
    static func noteDone(_ data: JeffJSPromiseData) {
        lock.lock()
        pending[ObjectIdentifier(data)] = nil
        created[ObjectIdentifier(data)] = nil
        lock.unlock()
    }

    /// Promises still pending after at least `seconds` of being waited on, oldest first, grouped by stack.
    static func report(olderThan seconds: Double = 2, limit: Int = 40) -> [String] {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let entries = pending.values.filter { now - $0.since >= seconds }
        lock.unlock()
        var groups: [String: (count: Int, waits: Int, oldest: Double)] = [:]
        for e in entries {
            let k = "created " + String(e.created.prefix(500)) + "  ||  waited " + e.stack
            var g = groups[k] ?? (0, 0, 0)
            g.count += 1; g.waits += e.waits; g.oldest = max(g.oldest, now - e.since)
            groups[k] = g
        }
        let lines = groups.sorted { $0.value.oldest > $1.value.oldest }.prefix(limit).map { stack, g in
            String(format: "%5.1fs x%d waits=%d | ", g.oldest, g.count, g.waits) + String(stack.prefix(1100))
        }
        return ["pending promises (waited on >= \(seconds)s): \(entries.count)"] + lines
    }
}
