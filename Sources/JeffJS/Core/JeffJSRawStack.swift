import Foundation

/// A LIFO stack of class references stored as raw pointers in a malloc'd
/// buffer: no Swift Array buffer (no uniqueness check, no COW, no buffer
/// retain/release around a push or pop), and the engine decides who owns a
/// reference.
///
/// `retaining == true`: each entry holds its own +1 (append retains, popLast
/// transfers that +1 to the returned reference, removeAll releases) — the
/// same ownership a `[T]` has.
/// `retaining == false`: entries are unretained; the caller guarantees the
/// object is kept alive by some other owner while parked (the recycle pools
/// ride the Swift retain of the original `makeObject`, see
/// `JeffJSValue.makeObjectRecycled`). popLast then returns a normal strong
/// reference (one retain, balanced when the caller's reference dies).
nonisolated struct JeffJSRawStack<T: AnyObject> {
    private var base: UnsafeMutablePointer<Unmanaged<T>>? = nil
    private(set) var count: Int = 0
    private var capacity: Int = 0
    let retaining: Bool

    init(retaining: Bool) { self.retaining = retaining }

    @inline(__always) var isEmpty: Bool { count == 0 }

    @inline(__always)
    mutating func append(_ o: T) {
        if count == capacity { grow() }
        base.unsafelyUnwrapped[count] = retaining ? Unmanaged.passRetained(o) : Unmanaged.passUnretained(o)
        count += 1
    }

    @inline(__always)
    mutating func popLast() -> T? {
        if count == 0 { return nil }
        count -= 1
        let u = base.unsafelyUnwrapped[count]
        return retaining ? u.takeRetainedValue() : u.takeUnretainedValue()
    }

    /// Calls `body` with each parked entry, oldest first (no retain).
    func forEachUnretained(_ body: (Unmanaged<T>) -> Void) {
        var i = 0
        while i < count { body(base.unsafelyUnwrapped[i]); i += 1 }
    }

    /// Empties the stack, releasing the entries' own references when
    /// `retaining`.
    mutating func removeAll() {
        if retaining { while count > 0 { count -= 1; base.unsafelyUnwrapped[count].release() } }
        count = 0
    }

    private mutating func grow() {
        let ncap = capacity == 0 ? 64 : capacity * 2
        let nb = UnsafeMutablePointer<Unmanaged<T>>.allocate(capacity: ncap)
        if let b = base {
            nb.moveInitialize(from: b, count: count)
            b.deallocate()
        }
        base = nb
        capacity = ncap
    }
}
