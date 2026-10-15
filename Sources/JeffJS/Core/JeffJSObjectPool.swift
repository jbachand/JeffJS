import Foundation

// MARK: - Plain-object recycle pool
//
// Allocation-heavy code (`{a: i, b: i + 1}` in a loop) spent a fifth of its
// time in malloc/free and another fifth in field initialisation and ARC
// traffic for the ~26 stored properties of JeffJSObject. A plain object whose
// refcount drops to zero is instead reset and parked on a runtime-owned free
// list (keeping its slot array capacity), and newObjectClass pops from it.
// Only objects that pass `isPoolable` (nothing but data slots, no weak refs,
// no payload) are recycled; everything else takes the regular free path.
// Debug modes (zombies, refcount tracking) bypass the pool so identities stay
// unique.

nonisolated(unsafe) let jeffJSObjectPoolCapacity = 4096

/// Called from JeffJSValue.freeValueHeap when an object's refcount is about
/// to reach zero. Returns true when the object was recycled.
@inline(never)
nonisolated func jeffJS_recycleObject(_ ptr: UnsafeRawPointer) -> Bool {
    return Unmanaged<JeffJSObject>.fromOpaque(ptr)._withUnsafeGuaranteedRef { o -> Bool in
        if o.classID == JeffJSClassID.array.rawValue { return jeffJS_recycleArray(o) }
        if o.classID == JeffJSClassID.bytecodeFunction.rawValue { return jeffJS_recycleFunction(o) }
        guard !jeffJSObjectPoolDisabled, o.refCount == 1, o.isPoolable,
              let rt = o.ownerRuntime, rt.initComplete,
              rt.gcPhase == .JS_GC_PHASE_NONE, !rt.inFreeChain,
              rt.objectPool.count < jeffJSObjectPoolCapacity else { return false }
        o.refCount = 0
        // Off the GC list while parked: a pooled object is dead, and leaving
        // it listed would make the collector walk (and try to rescue) it.
        removeGCObject(rt, o)
        // `isPoolable` already required `firstWeakRef == nil`, and that is now
        // set for every object with a weakref cell, so a pooled object never
        // has one. Kept as a field test rather than a dictionary probe.
        if o._auxU != nil, o.firstWeakRef != nil { weakrefFree(rt, o) }
        // Release the slots. Nested zero transitions are deferred while
        // inFreeChain is set and drained below, as freeGCObjectAtZeroRefcount
        // does, so deep object chains cannot recurse.
        let n = o.propValues.count
        if n > 0 {
            rt.inFreeChain = true
            var i = 0
            while i < n { o.propValues[i].freeValue(); i += 1 }
            o.propValues.removeAll(keepingCapacity: true)
            rt.inFreeChain = false
        }
        if let shape = o.shape {
            o.shape = nil
            shape.refCount -= 1
            if shape.refCount == 0 && !shape.isHashed { freeGCObjectChildren(rt, shape) }
        }
        o._flags = (o._flags | JeffJSObject.flagExtensible)
            & ~(JeffJSObject.flagFreeMark | JeffJSObject.flagTmpMark)
        o.mark = JeffJSGCMark.white
        o.weakrefCount = 0
        o.realmIndex = 0
        if (o.lazyFlags & JeffJSObject.lazyOriginBit) != 0 { jeffJS_lazyForget(rt, o) }
        o.lazyFlags = 0            // clears needsLazyPrototype / NameLength / stack
                                   // (the captured stack lives in payload, reset below)
        // Side-box fields (perf/watch-object-size): a plain object without a
        // box has nothing to reset.
        if o._auxU != nil {
            if let capturedThis = o.arrowThisVal {
                // The closure owns its captured `this` (dup'd at creation); frames borrow it.
                o.arrowThisVal = nil
                capturedThis.freeValue()
            }
            if o.storedCFunction != nil { o.storedCFunction = nil; o.storedCFunctionLength = 0 }
            if o.varRefsRawCount > 0 { o.varRefsFast = [] }
            o.payload = .opaque(nil)
        }
        rt.objectPool.append(o)
        if !rt.gcZeroRefCountObjects.isEmpty {
            while let d = rt.gcZeroRefCountObjects.popLast() {
                if d.refCount == 0 { freeGCObjectAtZeroRefcount(rt, d) }
            }
        }
        return true
    }
}

nonisolated(unsafe) let jeffJSFunctionPoolCapacity = 1024

/// Closures die as fast as they are made (`arr.forEach(function (v) {...})`
/// in a loop, React's inline handlers). A dying ordinary bytecode function
/// whose only own properties are data slots (its materialised `name` and
/// `length`, at most) is reset — payload, var-refs, captured `this`, shape —
/// and parked WITH its side box, so `createClosure` reuses both allocations
/// (perf/watch-object-size: a closure is an object + a side box; without the
/// pool every closure paid two mallocs and two frees). A/B: JEFFJS_NO_POOL=1
/// (all pools) or JEFFJS_GC_FUNCTIONPOOL=0.
@inline(never)
nonisolated func jeffJS_recycleFunction(_ o: JeffJSObject) -> Bool {
    let bad: UInt16 = JeffJSObject.flagExotic | JeffJSObject.flagFastArray | JeffJSObject.flagProtectedGlobal
        | JeffJSObject.flagImmutablePrototype | JeffJSObject.flagHTMLDDA | JeffJSObject.flagStdArrayPrototype
        | JeffJSObject.flagHasCFunc
    guard jeffJS_functionPoolEnabled, !jeffJSObjectPoolDisabled, o.refCount == 1,
          (o._flags & bad) == 0, o._propExtraCount == 0, o.weakrefCount == 0,
          o._fastArrayValues == nil, let a = o.aux,
          a.firstWeakRef == nil, a.storedCFunction == nil, a.storedPrimitiveValue.isUndefined,
          let rt = o.ownerRuntime, rt.initComplete,
          rt.gcPhase == .JS_GC_PHASE_NONE, !rt.inFreeChain,
          rt.functionPool.count < jeffJSFunctionPoolCapacity else { return false }
    o.refCount = 0
    removeGCObject(rt, o)
    // Release what the closure owns; nested zero transitions are deferred
    // while inFreeChain is set and drained below (see jeffJS_recycleObject).
    rt.inFreeChain = true
    let n = o.propValues.count
    if n > 0 {
        var i = 0
        while i < n { o.propValues[i].freeValue(); i += 1 }
        o.propValues.removeAll(keepingCapacity: true)
    }
    var payload: JeffJSObjectPayload = .opaque(nil)
    swap(&payload, &a.payload)     // a move: no copy of the enum
    if case .bytecodeFunc(let fb, _, _) = payload, let fb {
        fb.liveClosures &-= 1
        if fb.orphanOwned, fb.liveClosures == 0 { rt.queueOrphanBody(fb) }
    }
    if let t = a.arrowThisVal { a.arrowThisVal = nil; t.freeValue() }
    a.cMagicFast = 0
    a.storedCFunctionLength = 0
    a.storedProto = nil
    rt.inFreeChain = false
    o.fbFast = nil
    if (o._flags & JeffJSObject.flagHasVarRefs) != 0 {
        // interp.leanClosurePayload: keep the array's storage for the next
        // closure built on this object (createClosure fills it in place).
        if jeffJSLeanClosurePayload { a.clearVarRefsKeepingCapacity() } else { a.setVarRefs([]) }
    }
    if let shape = o.shape {
        o.shape = nil
        shape.refCount -= 1
        if shape.refCount == 0 && !shape.isHashed { freeGCObjectChildren(rt, shape) }
    }
    // Keep the slot bit: the side box stays with the parked closure.
    o._flags = JeffJSObject.flagExtensible | (o._flags & JeffJSObject.flagSlotIsAux)
    o.mark = JeffJSGCMark.white
    o.realmIndex = 0
    o.lazyFlags = 0
    rt.functionPool.append(o)
    _ = payload   // var-refs array, home object and body released here
    if !rt.gcZeroRefCountObjects.isEmpty {
        while let d = rt.gcZeroRefCountObjects.popLast() {
            if d.refCount == 0 { freeGCObjectAtZeroRefcount(rt, d) }
        }
    }
    return true
}

/// JEFFJS_GC_FUNCTIONPOOL=0 turns the function-object pool off (A/B).
nonisolated(unsafe) var jeffJS_functionPoolEnabled: Bool = true

nonisolated(unsafe) let jeffJSArrayPoolCapacity = 1024
let jeffJSArrayStorageKeepCapacity = 64

/// Array literals (`[a, b, c]`, `[]` in obfuscated predicates) die as fast
/// as they are made. A dying ordinary array is reset to what `newArray()`
/// returns — no element storage, `length` 0, the `.array` payload — and
/// parked; its element store (capacity kept, when small) goes to a second
/// pool that `newArrayFromSlots` fills. Anything else about the array
/// (extra properties, accessors, frozen/sealed, weak refs, a subclass shape
/// with more properties) takes the regular free path.
@inline(never)
nonisolated func jeffJS_recycleArray(_ o: JeffJSObject) -> Bool {
    guard !jeffJSObjectPoolDisabled, o.refCount == 1, o.isPoolableArray,
          let rt = o.ownerRuntime, rt.initComplete,
          rt.gcPhase == .JS_GC_PHASE_NONE, !rt.inFreeChain,
          rt.arrayPool.count < jeffJSArrayPoolCapacity,
          let st = o._fastArrayValues else { return false }
    o.refCount = 0
    removeGCObject(rt, o)
    // Release the elements; nested zero transitions are deferred and drained
    // below (see jeffJS_recycleObject). The emptied store stays on the array
    // (its `.array` payload is a view of it): small capacities are kept for
    // the next literal (newArrayFromSlots appends into it).
    let n = min(Int(st.count), st.values.count)
    rt.inFreeChain = true
    var i = 0
    while i < n { st.values[i].freeValue(); i += 1 }
    rt.inFreeChain = false
    if st.values.capacity <= jeffJSArrayStorageKeepCapacity {
        st.values.removeAll(keepingCapacity: true)
    } else {
        st.values = []
    }
    st.count = 0
    o.propValues[0] = .newInt32(0)     // `length` (a number: nothing to release)
    if let shape = o.shape {           // hashed (isPoolableArray): never freed here
        o.shape = nil
        shape.refCount -= 1
    }
    o.freeMark = false
    o.tmpMark = false
    o.mark = JeffJSGCMark.white
    o.weakrefCount = 0
    rt.arrayPool.append(o)
    if !rt.gcZeroRefCountObjects.isEmpty {
        while let d = rt.gcZeroRefCountObjects.popLast() {
            if d.refCount == 0 { freeGCObjectAtZeroRefcount(rt, d) }
        }
    }
    return true
}

nonisolated extension JeffJSRuntime {
    /// Release the Swift references the pooled objects still carry (their
    /// original makeObject retain). Called from free().
    func drainObjectPool() {
        // The pools are unretained: each entry rides the Swift retain of its
        // original makeObject, released here.
        objectPool.forEachUnretained { $0.release() }
        objectPool.removeAll()
        arrayPool.forEachUnretained { $0.release() }
        arrayPool.removeAll()
        functionPool.forEachUnretained { $0.release() }
        functionPool.removeAll()
        arrayStoragePool.removeAll()
        varRefPool.removeAll()   // parked var-refs hold the runtime (ownerRuntime)
    }
}

nonisolated(unsafe) let jeffJSVarRefPoolCapacity = 1024

/// interp.recycleVarRefs: detach the live var-refs of a frame that is going
/// away — or, for one that nothing but the frame holds any more (every
/// closure that captured it has died: `arr.forEach(function (k) { … })`,
/// a callback passed and dropped), skip the copy and park it for
/// createClosure. A detached copy of a value nobody can read cost a dup, a
/// GC-list insertion and, at deallocation, the list removal, the value's
/// release and a free. Callers sync the frame first when they need to
/// (jeffJS_syncForDetach).
@inline(never)
nonisolated func jeffJS_detachFrameVarRefs(_ frame: JeffJSStackFrame, _ rt: JeffJSRuntime) {
    if !jeffJSRecycleVarRefs {
        for vr in frame.liveVarRefs where !vr.isDetached {
            vr.value = vr.pvalue.dupValue()
            vr.isDetached = true
            vr.parentFrame = nil; vr.slot = nil
        }
        return
    }
    frame.liveVarRefs.withUnsafeMutableBufferPointer { b in
        for i in 0..<b.count {
            if b[i].isDetached { continue }
            if isKnownUniquelyReferenced(&b[i]), rt.varRefPool.count < jeffJSVarRefPoolCapacity {
                let vr = b[i]
                vr.parentFrame = nil; vr.slot = nil
                rt.varRefPool.append(vr)
            } else {
                let vr = b[i]
                vr.value = vr.pvalue.dupValue()
                vr.isDetached = true
                vr.parentFrame = nil; vr.slot = nil
            }
        }
    }
}
