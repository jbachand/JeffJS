import Foundation

// MARK: - Raw property-slot storage

/// Manually managed slot array for `JeffJSObject.propValues`. A
/// ContiguousArray stored in a class cost a bounds check on every read, a
/// uniqueness check plus end-mutation call on every write, and a buffer
/// retain/release around many accesses; property access is the hottest path
/// in the engine after local variables. This is a plain (pointer, count,
/// capacity) triple: no ownership semantics of its own. The owning
/// JeffJSObject frees the buffer in deinit; code that moves the storage out
/// of an object (freeObject) calls `deallocateStorage()` itself.
struct JeffJSPropStorage: RandomAccessCollection {
    typealias Index = Int
    typealias Element = JeffJSValue

    private(set) var ptr: UnsafeMutablePointer<JeffJSValue>? = nil
    private(set) var count: Int = 0
    private(set) var capacity: Int = 0

    @inline(__always) init() {}

    @inline(__always) var startIndex: Int { 0 }
    @inline(__always) var endIndex: Int { count }
    @inline(__always) var isEmpty: Bool { count == 0 }

    @inline(__always) subscript(i: Int) -> JeffJSValue {
        get { ptr.unsafelyUnwrapped[i] }
        nonmutating set { ptr.unsafelyUnwrapped[i] = newValue }
    }

    @inline(__always) mutating func reserveCapacity(_ n: Int) {
        if n > capacity { grow(to: n) }
    }

    @inline(__always) mutating func append(_ v: JeffJSValue) {
        if count == capacity { grow(to: capacity < 4 ? 4 : capacity * 2) }
        ptr.unsafelyUnwrapped[count] = v
        count += 1
    }

    @inline(__always) mutating func removeAll(keepingCapacity: Bool = false) {
        count = 0
        if !keepingCapacity, let p = ptr { p.deallocate(); ptr = nil; capacity = 0 }
    }

    @inline(__always) @discardableResult mutating func removeLast() -> JeffJSValue {
        count -= 1
        return ptr.unsafelyUnwrapped[count]
    }

    @discardableResult mutating func remove(at i: Int) -> JeffJSValue {
        let p = ptr.unsafelyUnwrapped
        let v = p[i]
        var j = i
        while j < count - 1 { p[j] = p[j + 1]; j += 1 }
        count -= 1
        return v
    }

    mutating func insert(_ v: JeffJSValue, at i: Int) {
        if count == capacity { grow(to: capacity < 4 ? 4 : capacity * 2) }
        let p = ptr.unsafelyUnwrapped
        var j = count
        while j > i { p[j] = p[j - 1]; j -= 1 }
        p[i] = v
        count += 1
    }

    @inline(never) private mutating func grow(to n: Int) {
        let np = UnsafeMutablePointer<JeffJSValue>.allocate(capacity: n)
        if let p = ptr {
            np.moveInitialize(from: p, count: count)
            p.deallocate()
        }
        ptr = np
        capacity = n
    }

    /// Free the buffer (owner teardown). The struct must not be used after.
    @inline(__always) func deallocateStorage() { ptr?.deallocate() }
}

// MARK: - Inline-cache fast paths without ARC
//
// `JeffJSValue.obj` yields a wrapper whose every field access bit-casts the
// pointer to a class reference; the compiler cannot prove the object outlives
// the access and emits a retain/release pair per field. These helpers do the
// whole IC hit inside one guaranteed-reference scope. The receiver's shape
// identity is compared first; `entry.pc` is checked by the caller.

/// Own or prototype-chain read. nil on any mismatch. The returned value is
/// borrowed (dup before pushing).
@inline(__always)
func jeffJS_icRead(_ ptr: UnsafeRawPointer, _ entry: JeffJSICEntry) -> JeffJSValue? {
    return Unmanaged<JeffJSObject>.fromOpaque(ptr)._withUnsafeGuaranteedRef { o -> JeffJSValue? in
        guard let sid = o.shapeIdentity, sid == entry.shapePtr else { return nil }
        if entry.holderPtr != nil { return jeffJS_icProtoHit(entry) }
        let off = entry.propOffset
        guard off >= 0, off < o.propValues.count, o.extra(at: off) == nil else { return nil }
        return o.propValues[off]
    }
}

/// Own data-slot write. Takes the `val` reference and releases the previous
/// slot value (QuickJS set_value). Does not touch the receiver reference.
@inline(__always)
func jeffJS_icWrite(_ ptr: UnsafeRawPointer, _ entry: JeffJSICEntry, _ val: JeffJSValue) -> Bool {
    return Unmanaged<JeffJSObject>.fromOpaque(ptr)._withUnsafeGuaranteedRef { o -> Bool in
        guard entry.writable, let sid = o.shapeIdentity, sid == entry.shapePtr else { return false }
        let off = entry.propOffset
        guard off >= 0, off < o.propValues.count, o.extra(at: off) == nil else { return false }
        let old = o.propValues[off]
        o.propValues[off] = val
        old.freeValue()
        return true
    }
}

/// define_field transition-cache hit: move the receiver from the cached
/// starting shape to its successor and append `val` (reference taken).
@inline(__always)
func jeffJS_icDefine(_ ptr: UnsafeRawPointer, _ entry: JeffJSICEntry, _ val: JeffJSValue, _ rt: JeffJSRuntime) -> Bool {
    return Unmanaged<JeffJSObject>.fromOpaque(ptr)._withUnsafeGuaranteedRef { o -> Bool in
        guard let sid = o.shapeIdentity, sid == entry.shapePtr, let toPtr = entry.nextShapePtr, o.extensible else { return false }
        return Unmanaged<JeffJSShape>.fromOpaque(toPtr)._withUnsafeGuaranteedRef { next -> Bool in
            guard next.isHashed, o.propValues.count == next.propCount - 1, let old = o.shape else { return false }
            next.refCount += 1
            o.shape = next
            jeffJS_leaveShape(rt, old)
            o.propValues.append(val)
            if !o.propExtra.isEmpty { o.propExtra.append(nil) }
            return true
        }
    }
}
