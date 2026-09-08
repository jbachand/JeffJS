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

let jeffJSObjectPoolCapacity = 4096

/// Called from JeffJSValue.freeValueHeap when an object's refcount is about
/// to reach zero. Returns true when the object was recycled.
@inline(never)
func jeffJS_recycleObject(_ ptr: UnsafeRawPointer) -> Bool {
    return Unmanaged<JeffJSObject>.fromOpaque(ptr)._withUnsafeGuaranteedRef { o -> Bool in
        guard !jeffJSObjectPoolDisabled, o.refCount == 1, o.isPoolable,
              let rt = o.ownerRuntime, rt.initComplete,
              rt.gcPhase == .JS_GC_PHASE_NONE, !rt.inFreeChain,
              rt.objectPool.count < jeffJSObjectPoolCapacity else { return false }
        o.refCount = 0
        if !rt.gcWeakRefMap.isEmpty { weakrefFree(rt, o) }
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
        o.extensible = true
        o.freeMark = false
        o.tmpMark = false
        o.mark = JeffJSGCMark.white
        o.weakrefCount = 0
        o.needsLazyPrototype = false
        if let capturedThis = o.arrowThisVal {
            // The closure owns its captured `this` (dup'd at creation); frames borrow it.
            o.arrowThisVal = nil
            capturedThis.freeValue()
        }
        if o.storedCFunction != nil { o.storedCFunction = nil; o.storedCFunctionLength = 0 }
        if !o.varRefsFast.isEmpty { o.varRefsFast = [] }
        o.payload = .opaque(nil)
        rt.mallocState.mallocCount -= 1
        rt.objectPool.append(o)
        if !rt.gcZeroRefCountObjects.isEmpty {
            while let d = rt.gcZeroRefCountObjects.popLast() {
                if d.refCount == 0 { freeGCObjectAtZeroRefcount(rt, d) }
            }
        }
        return true
    }
}

extension JeffJSRuntime {
    /// Release the Swift references the pooled objects still carry (their
    /// original makeObject retain). Called from free().
    func drainObjectPool() {
        for o in objectPool { Unmanaged.passUnretained(o).release() }
        objectPool.removeAll()
    }
}
