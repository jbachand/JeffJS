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
        let since: CFAbsoluteTime
        var waits: Int
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [ObjectIdentifier: Entry] = [:]

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
        var natives: [(before: Int, name: String)] = []
        let frames = ctx.captureStackFrames(maxDepth: 12, natives: &natives, skipInnermostNative: false)
        let text = ctx.formatStackTrace(errorName: "", message: "", frames: frames, natives: natives)
        let stack = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty && $0 != ": " }.joined(separator: " < ")
        lock.lock()
        pending[key] = Entry(stack: stack.isEmpty ? "(no JS frame: native/microtask)" : stack,
                             since: CFAbsoluteTimeGetCurrent(), waits: 1)
        lock.unlock()
    }

    /// The promise settled or was freed.
    static func noteDone(_ data: JeffJSPromiseData) {
        lock.lock()
        pending[ObjectIdentifier(data)] = nil
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
            var g = groups[e.stack] ?? (0, 0, 0)
            g.count += 1; g.waits += e.waits; g.oldest = max(g.oldest, now - e.since)
            groups[e.stack] = g
        }
        let lines = groups.sorted { $0.value.oldest > $1.value.oldest }.prefix(limit).map { stack, g in
            String(format: "%5.1fs x%d waits=%d | ", g.oldest, g.count, g.waits) + String(stack.prefix(600))
        }
        return ["pending promises (waited on >= \(seconds)s): \(entries.count)"] + lines
    }
}
