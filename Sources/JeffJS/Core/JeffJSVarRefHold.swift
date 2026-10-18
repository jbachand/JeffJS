import Foundation

// JeffJSVarRefHold.swift
// JeffJS — var-ref lifetime without Swift ARC (build flag JEFFJS_MANUAL_MEMORY).
//
// quickjs counts a closure variable's holders in `JSVarRef.header.ref_count`
// (js_closure2 / close_var_refs / free_var_ref) and nothing else. Here a
// var-ref is still a `JeffJSVarRef` (a GC header, so the collectors, the
// instance census and the zombie tooling see the same object as before), but
// its *lifetime* is a manual count:
//
//   - `holdCount` counts the holders on the hot paths: one per entry of a
//     closure's var-ref buffer (`JeffJSObjectAux.varRefsRaw`) and one while
//     it is on its frame's live list (`JeffJSStackFrame.liveVarRefs`).
//   - The object itself is kept alive by ONE manual Swift retain, taken when
//     the count leaves zero and given back (or handed to the runtime's
//     var-ref pool) when it returns to zero. Capture, `get/put_var_ref`,
//     close and free therefore cost no `swift_retain`/`swift_release`, and a
//     var-ref that dies — live or detached — is parked and reused instead of
//     being deallocated (a detached one used to cost a malloc, the GC-list
//     insert and removal, the value release and a free via ARC deinit).
//   - The rare holders the count does not see keep plain Swift references, as
//     before: a mapped `arguments` slot (`JeffJSPropertyExtra`), a ref object
//     (`make_loc_ref`), a `.bytecodeFunc` payload list (eval code;
//     leanClosurePayload off). (A suspended generator / async activation
//     keeps its frame, so its var-refs stay on the frame's counted list.)
//     They set `coldHeld`, which keeps the var-ref out of the pool for good:
//     when the count reaches zero only the manual retain is given back, and
//     the last ARC holder's release runs `deinit` exactly as before.
//
// `refCount` (the GC header's) is untouched: it stays the collector's scratch
// count, seeded and recomputed by each collection (`gcSeedVarRefs`).
//
// A/B: built without `JEFFJS_MANUAL_MEMORY` (the default) every hold is a
// Swift retain and every drop a release (the ARC lifetime, on the same raw
// lists); parking happens only at frame exit, as before. Build with
// `JEFFJS_MANUAL_MEMORY=1 swift build` (Package.swift) or the compilation
// condition `JEFFJS_MANUAL_MEMORY` in Xcode for the manual count.
//
// Ownership: `jeffJS_makeVarRef` returns a var-ref carrying one hold (the
// frame list's). Whoever stores an `Unmanaged<JeffJSVarRef>` in a counted
// holder takes a hold first (`jeffJS_varRefHold`) and drops it when the entry
// goes (`jeffJS_varRefDrop`).

/// The build-time switch (`JEFFJS_MANUAL_MEMORY`, JeffJS issue #1): a
/// constant, so the lifetime the build does not use is compiled out of every
/// hold and drop. Off (the default) is the ARC lifetime.
#if JEFFJS_MANUAL_MEMORY
@inline(__always) nonisolated var jeffJSArclessVarRefs: Bool { true }
#else
@inline(__always) nonisolated var jeffJSArclessVarRefs: Bool { false }
#endif

/// Take a hold on `u` for a counted holder.
@inline(__always)
nonisolated func jeffJS_varRefHold(_ u: Unmanaged<JeffJSVarRef>) {
    if jeffJSArclessVarRefs {
        let first = u._withUnsafeGuaranteedRef { vr -> Bool in
            let h = vr.holdCount
            vr.holdCount = h &+ 1
            return h == 0
        }
        if first { jeffJS_varRefFirstHold(u) }
    } else {
        _ = u.retain()
    }
}

/// Give back a counted holder's hold on `u`. `rt` is the runtime when the
/// caller has it at hand (the pool lives there); nil reads the var-ref's own.
@inline(__always)
nonisolated func jeffJS_varRefDrop(_ u: Unmanaged<JeffJSVarRef>, _ rt: JeffJSRuntime?) {
    if jeffJSArclessVarRefs {
        let last = u._withUnsafeGuaranteedRef { vr -> Bool in
            let h = vr.holdCount &- 1
            vr.holdCount = h
            return h <= 0
        }
        if last { jeffJS_varRefLastDrop(u, rt) }
    } else {
        u.release()
    }
}

/// The count left zero: the object needs its manual retain again. Only a
/// var-ref that some ARC holder kept alive at zero gets here (a fresh or
/// pooled one starts at one hold) — a suspended generator's var-ref on
/// resume, an `arguments`-only one captured by a new closure.
@inline(never)
nonisolated func jeffJS_varRefFirstHold(_ u: Unmanaged<JeffJSVarRef>) {
    if jeffJSZombiesEnabled, u._withUnsafeGuaranteedRef({ $0.zombie }) {
        JeffJSZombieDebug.reportTouch("VARREF-HOLD", u.takeUnretainedValue())
    }
    _ = u.retain()
}

/// The count reached zero: park the var-ref for reuse (releasing its
/// detached value and taking it off the GC list), or give back the manual
/// retain. Never parks during a collection or teardown, under
/// JEFFJS_NO_POOL / JEFFJS_ZOMBIES, or when an ARC holder may still read it.
@inline(never)
nonisolated func jeffJS_varRefLastDrop(_ u: Unmanaged<JeffJSVarRef>, _ rtHint: JeffJSRuntime?) {
    if jeffJSZombiesEnabled { jeffJS_varRefLastDropZombie(u, rtHint); return }
    // Borrowed throughout (no retain of the var-ref or the runtime): the
    // manual retain keeps the var-ref alive until it is parked or released.
    let park: Unmanaged<JeffJSRuntime>? = u._withUnsafeGuaranteedRef { vr in
        if vr.holdCount < 0 {
            // One drop too many: a holder gave back a hold it never took.
            vr.holdCount = 0
            assertionFailure("JeffJSVarRef dropped below zero holds")
            return nil
        }
        guard !vr.coldHeld, jeffJSRecycleVarRefs, !jeffJSObjectPoolDisabled else { return nil }
        let rtU: Unmanaged<JeffJSRuntime>
        if let rt = rtHint { rtU = .passUnretained(rt) }
        else if let rt = vr.ownerRuntime { rtU = .passUnretained(rt) }
        else { return nil }
        return rtU._withUnsafeGuaranteedRef { rt -> Unmanaged<JeffJSRuntime>? in
            guard rt.varRefPoolOpen, rt.gcPhase == .JS_GC_PHASE_NONE,
                  rt.varRefPool.count < jeffJSVarRefPoolCapacity else { return nil }
            if vr.isDetached {
                // close_var_refs' copy is released here instead of in deinit.
                let v = vr.value
                vr.value = .undefined
                vr.isDetached = false
                if vr.gcListIndex != -1 { removeGCObject(rt, vr) }
                v.freeValue()
            }
            vr.parentFrame = nil; vr.slot = nil
            return rtU
        }
    }
    if let rtU = park {
        rtU._withUnsafeGuaranteedRef { $0.varRefPool.appendUnmanaged(u) }
    } else {
        u.release()
    }
}

/// JEFFJS_ZOMBIES=1: the shell stays allocated (and flagged) so a later hold
/// through a stale pointer is reported; the binding's value is released now,
/// as it would have been.
@inline(never)
nonisolated func jeffJS_varRefLastDropZombie(_ u: Unmanaged<JeffJSVarRef>, _ rtHint: JeffJSRuntime?) {
    let vr = u.takeUnretainedValue()
    if vr.holdCount < 0 {
        vr.holdCount = 0
        JeffJSZombieDebug.reportTouch("VARREF-DROP", vr)
        return
    }
    if !vr.coldHeld, let rt = rtHint ?? vr.ownerRuntime {
        if vr.isDetached {
            let v = vr.value
            vr.value = .undefined
            if vr.gcListIndex != -1 { removeGCObject(rt, vr) }
            v.freeValue()
        }
        vr.zombie = true
        rt.zombieKeepAlive.append(vr)
    }
    u.release()
}

/// A live var-ref over `frame`'s slot `varIdx`, carrying one hold (the
/// frame list's: append it to `frame.liveVarRefs`). Reuses a parked one.
@inline(__always)
nonisolated func jeffJS_makeVarRef(_ rt: JeffJSRuntime, isArg: Bool, varIdx: UInt16,
                                   frame: JeffJSStackFrame) -> Unmanaged<JeffJSVarRef> {
    if jeffJSRecycleVarRefs, let u = rt.varRefPool.popLastUnmanaged() {
        // A parked var-ref: never detached (its value is undefined), on no
        // GC list, the pool's manual retain becomes this hold's.
        u._withUnsafeGuaranteedRef { pv in
            pv.isArg = isArg
            pv.varIdx = varIdx
            pv.parentFrame = frame
            pv.argOwned = false
            pv.mark = false
            pv.holdCount = 1
        }
        return u
    }
    let vr = JeffJSVarRef(isDetached: false, isArg: isArg, varIdx: varIdx, parentFrame: frame)
    vr.holdCount = 1
    return Unmanaged.passRetained(vr)
}

/// A frame's live var-refs: unmanaged entries in a malloc'd buffer, each
/// carrying one hold. Frames are pooled for the life of the runtime, so the
/// buffer is kept across activations.
nonisolated struct JeffJSVarRefList {
    // 16 bytes (a frame field; the array it replaced was 8).
    private(set) var base: UnsafeMutablePointer<Unmanaged<JeffJSVarRef>>? = nil
    private var _count: Int32 = 0
    private var capacity: Int32 = 0

    @inline(__always) var count: Int { Int(_count) }

    @inline(__always) var isEmpty: Bool { count == 0 }

    @inline(__always)
    subscript(i: Int) -> Unmanaged<JeffJSVarRef> { base.unsafelyUnwrapped[i] }

    /// Append an entry whose hold the caller has already taken.
    @inline(__always)
    mutating func append(_ u: Unmanaged<JeffJSVarRef>) {
        if _count == capacity { grow() }
        base.unsafelyUnwrapped[count] = u
        _count &+= 1
    }

    /// Remove entry `i` (the last one moves into its place); its hold goes
    /// to the caller.
    @inline(__always)
    mutating func swapRemove(at i: Int) -> Unmanaged<JeffJSVarRef> {
        let p = base.unsafelyUnwrapped
        let u = p[i]
        _count &-= 1
        if i != count { p[i] = p[count] }
        return u
    }

    /// Empty the list without touching the entries (their holds went
    /// elsewhere).
    @inline(__always)
    mutating func removeAllKeepingHolds() { _count = 0 }

    /// Empty the list, dropping every entry's hold.
    @inline(never)
    mutating func dropAll(_ rt: JeffJSRuntime?) {
        let n = count
        _count = 0
        guard n > 0 else { return }
        let p = base.unsafelyUnwrapped
        var i = 0
        while i < n { jeffJS_varRefDrop(p[i], rt); i += 1 }
    }

    /// The first live entry over slot (`isArg`, `varIdx`), unretained.
    @inline(__always)
    func findLive(isArg: Bool, varIdx: UInt16) -> Unmanaged<JeffJSVarRef>? {
        guard let p = base else { return nil }
        var i = 0
        while i < count {
            let u = p[i]
            let hit = u._withUnsafeGuaranteedRef { v in
                v.varIdx == varIdx && v.isArg == isArg && !v.isDetached
            }
            if hit { return u }
            i += 1
        }
        return nil
    }

    /// Calls `body` with each entry (no retain).
    @inline(__always)
    func forEach(_ body: (Unmanaged<JeffJSVarRef>) -> Void) {
        guard let p = base else { return }
        var i = 0
        while i < count { body(p[i]); i += 1 }
    }

    /// Free the buffer (the frame is going away; entries must be gone).
    mutating func deallocate() {
        base?.deallocate()
        base = nil
        _count = 0
        capacity = 0
    }

    private mutating func grow() {
        let ncap: Int32 = capacity == 0 ? 8 : capacity * 2
        let nb = UnsafeMutablePointer<Unmanaged<JeffJSVarRef>>.allocate(capacity: Int(ncap))
        if let b = base {
            nb.moveInitialize(from: b, count: count)
            b.deallocate()
        }
        base = nb
        capacity = ncap
    }
}
