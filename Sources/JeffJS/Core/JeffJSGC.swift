// JeffJSGC.swift
// JeffJS — 1:1 Swift port of QuickJS
//
// Garbage collector: reference counting + Bacon-Rajan synchronous cycle
// detection, matching the design in quickjs.c.
//
// All GC tracking state lives on JeffJSRuntime (per-runtime), not in
// module-level globals.  This ensures objects are scoped to their runtime
// and fully released when the runtime is freed.

import Foundation

// MARK: - GC phases

/// Mirrors `JSGCPhaseEnum` in quickjs.c.
enum JSGCPhaseEnum: Int {
    /// No collection in progress.
    case JS_GC_PHASE_NONE         = 0
    /// Phase 1: trial decrements.
    case JS_GC_PHASE_DECREF       = 1
    /// Phase 3: freeing detected cycles.
    case JS_GC_PHASE_REMOVE_CYCLES = 2
}

// MARK: - GC mark colours

/// Mark colours used by the cycle collector.
/// Since JeffJSGCObjectHeader.mark is Bool, we use false for white
/// (unvisited / presumed garbage) and true for black (proven reachable).
struct JeffJSGCMark {
    static let white: Bool = false   // unvisited / presumed garbage
    static let black: Bool = true    // proven reachable — rescued
}

// NOTE: JSMallocState is now defined in JeffJSRuntime.swift.
// The duplicate definition that was here has been removed.

// MARK: - Weak references

/// A weak reference cell that can be invalidated when the target is collected.
/// Matches the WeakRef / weak-map semantics in quickjs.c.
final class JeffJSWeakRef {
    /// The target object.  Set to `nil` when the target is freed.
    weak var target: JeffJSObject?

    /// Set by `weakrefFree` the moment the target's contents are released.
    /// The weak Swift reference alone is not enough: an object freed by the
    /// cycle collector can still be *allocated* (another header holds an ARC
    /// reference, and JEFFJS_ZOMBIES=1 keeps every freed object alive on
    /// purpose), and `deref()` must not hand a gutted object back to JS.
    var cleared: Bool = false

    /// True while the target is still alive.
    var isLive: Bool { !cleared && target != nil }

    init(target: JeffJSObject) {
        self.target = target
    }
}

/// `JEFFJS_GC_DEBUG=1`: print the class and property names of the objects a
/// collection reclaims (the first 40 per run). An over-free shows up here as
/// a live builtin, which is how the two bugs in this round were found.
nonisolated(unsafe) let jeffJS_gcDebug =
    ProcessInfo.processInfo.environment["JEFFJS_GC_DEBUG"] == "1"
/// `JEFFJS_GC_OFF=1`: reference counting only, no cycle collection — answers
/// "is the collector responsible?" in one run. A `var` so the parity tests can
/// check that *both* collectors refuse when it is set, without a second
/// process per assertion.
nonisolated(unsafe) var jeffJS_gcDisable =
    ProcessInfo.processInfo.environment["JEFFJS_GC_OFF"] == "1"

// MARK: - GC object list management

/// Approximate byte cost of a single GC-tracked object (object + shape + props).
private let JS_GC_OBJ_COST = JeffJSConfig.gcObjectCost

/// Append `header` to the runtime's main GC object list.
/// Called every time a new GC-managed object is created.
func addGCObject(_ rt: JeffJSRuntime, _ header: JeffJSGCObjectHeader) {
    header.gcListIndex = rt.gcObjects.count
    rt.gcObjects.append(Unmanaged.passUnretained(header))
    header.mark = JeffJSGCMark.white
    header.ownerRuntime = rt
    // Track allocation size for GC threshold (actual collection deferred to safe points)
    rt.mallocState.mallocSize += JS_GC_OBJ_COST
    rt.mallocState.mallocCount += 1
}

/// Remove `header` from whichever GC tracking list it is on.
/// O(1) via the intrusive gcListIndex + swap-remove (list order is
/// irrelevant to the collector, which always iterates the whole array).
func removeGCObject(_ rt: JeffJSRuntime, _ header: JeffJSGCObjectHeader) {
    let li = header.gcListIndex
    let me = Unmanaged.passUnretained(header).toOpaque()
    if li >= 0 {
        if li < rt.gcObjects.count, rt.gcObjects[li].toOpaque() == me {
            let last = rt.gcObjects.count - 1
            if li != last {
                let moved = rt.gcObjects[last]
                rt.gcObjects[li] = moved
                moved._withUnsafeGuaranteedRef { $0.gcListIndex = li }
            }
            rt.gcObjects.removeLast()
            header.gcListIndex = -1
            rt.mallocState.mallocSize -= JS_GC_OBJ_COST
            rt.mallocState.mallocCount -= 1
            return
        }
    } else if li <= -2 {
        let ti = -2 - li
        if ti < rt.gcTmpObjects.count, rt.gcTmpObjects[ti].toOpaque() == me {
            let last = rt.gcTmpObjects.count - 1
            if ti != last {
                let moved = rt.gcTmpObjects[last]
                rt.gcTmpObjects[ti] = moved
                moved._withUnsafeGuaranteedRef { $0.gcListIndex = -2 - ti }
            }
            rt.gcTmpObjects.removeLast()
            header.gcListIndex = -1
            return
        }
    } else {
        // Not tracked — nothing to do.
        return
    }
    // Defensive fallback: index out of sync (should not happen) — restore
    // correctness with a linear scan rather than corrupting the lists.
    if let idx = rt.gcObjects.firstIndex(where: { $0.toOpaque() == me }) {
        rt.gcObjects.remove(at: idx)
        for i in idx ..< rt.gcObjects.count {
            rt.gcObjects[i]._withUnsafeGuaranteedRef { $0.gcListIndex = i }
        }
        header.gcListIndex = -1
        rt.mallocState.mallocSize -= JS_GC_OBJ_COST
        rt.mallocState.mallocCount -= 1
        return
    }
    if let idx = rt.gcTmpObjects.firstIndex(where: { $0.toOpaque() == me }) {
        rt.gcTmpObjects.remove(at: idx)
        for i in idx ..< rt.gcTmpObjects.count {
            rt.gcTmpObjects[i]._withUnsafeGuaranteedRef { $0.gcListIndex = -2 - i }
        }
        header.gcListIndex = -1
    }
}

// MARK: - Reference counting: public API

/// Increment the reference count of a value, returning it.
/// Non-heap values are returned unchanged.
@discardableResult
func dupValue(_ v: JeffJSValue) -> JeffJSValue {
    if let hdr = v.toGCObjectHeader() {
        hdr.refCount += 1
    }
    return v
}

/// Decrement the reference count of a value.
/// When the count reaches zero the object is scheduled for freeing.
///
/// This is the public entry point; it forwards to ``freeValueRT(_:_:)``
/// for heap values.
func freeValue(_ rt: JeffJSRuntime, _ v: JeffJSValue) {
    guard v.hasRefCount else { return }
    freeValueRT(rt, v)
}

/// Trampoline so JeffJSValue.freeValue() can call freeValueRT without
/// name collision with the freeValueRT() instance method on JeffJSValue.
func _freeValueRTImpl(_ rt: JeffJSRuntime, _ v: JeffJSValue) { freeValueRT(rt, v) }

/// Free a GC-tracked object whose refcount the caller has ALREADY decremented
/// to zero. Defers during a GC phase / recursive free chain, otherwise runs the
/// two-phase free (process children, then batch-release ARC retains). Shared by
/// `freeValueRT` and `JeffJSValue.freeValueSlow` so the zero-refcount path has a
/// single implementation.
func freeGCObjectAtZeroRefcount(_ rt: JeffJSRuntime, _ hdr: JeffJSGCObjectHeader) {
    if rt.gcPhase != .JS_GC_PHASE_NONE || rt.inFreeChain {
        // GC is running or we're inside a recursive free chain — defer.
        rt.gcZeroRefCountObjects.append(hdr)
        return
    }
    // Two-phase free: first process all children (decrement their refcounts,
    // collect more zero-ref objects), then release ARC retains in a batch. This
    // prevents use-after-free when cyclic objects reference each other.
    rt.inFreeChain = true
    var toRelease: [JeffJSGCObjectHeader] = []

    // Phase 1: Process children (freeObject/freeShape/etc nil out refs)
    freeGCObjectChildren(rt, hdr)
    toRelease.append(hdr)

    // Drain deferred zero-ref objects iteratively (popLast: O(1) per item;
    // removeFirst shifted the whole array each time)
    while let deferred = rt.gcZeroRefCountObjects.popLast() {
        if deferred.refCount == 0 {
            freeGCObjectChildren(rt, deferred)
            toRelease.append(deferred)
        }
    }
    rt.inFreeChain = false

    // Phase 2: Release ARC retains (may deallocate objects).
    // Safe because all child references have been nil'd out.
    for obj in toRelease {
        if jeffJSZombiesEnabled {
            if let o = obj as? JeffJSObject { o.freeMark = true }
            rt.zombieKeepAlive.append(obj)
        } else {
            Unmanaged.passUnretained(obj).release()
        }
    }
}

/// Internal free.  Decrements the ref count of a heap value and, if it
/// reaches zero, either frees it immediately (outside of GC) or enqueues
/// it on the zero-refcount list (during GC).
func freeValueRT(_ rt: JeffJSRuntime, _ v: JeffJSValue) {
    // GC-tracked objects (JeffJSObject, JeffJSShape, JeffJSVarRef, JeffJSBigInt)
    if let hdr = v.toGCObjectHeader() {
        guard hdr.refCount > 0 else { return } // already freed or being freed
        hdr.refCount -= 1
        if hdr.refCount == 0 {
            freeGCObjectAtZeroRefcount(rt, hdr)
        }
        return
    }

    // Handle strings (not GC-tracked, have their own refCount).
    // Do NOT use v.stringValue — that flattens ropes. Check the raw pointer type directly.
    if v.isString {
        if let ref = v.toPtr() {
            if let s = ref as? JeffJSString {
                guard s.refCount > 0 else { return }
                s.refCount -= 1
                if s.refCount == 0 {
                    // Release the Unmanaged retain from makeString
                    Unmanaged.passUnretained(s).release()
                }
            } else if let r = ref as? JeffJSStringRope {
                guard r.refCount > 0 else { return }
                r.refCount -= 1
                if r.refCount == 0 {
                    // Free the rope's children first
                    r.left.freeValue()
                    r.right.freeValue()
                    Unmanaged.passUnretained(r).release()
                }
            } else if let b = ref as? JeffJSStringBuffer {
                guard b.refCount > 0 else { return }
                b.refCount -= 1
                if b.refCount == 0 {
                    Unmanaged.passUnretained(b).release()
                }
            }
        }
        return
    }

    // Handle function bytecodes (not GC-tracked, have their own refCount).
    if v.isFunctionBytecode {
        if let fb = v.toFunctionBytecode() {
            guard fb.refCount > 0 else { return }
            fb.refCount -= 1
            if fb.refCount == 0 {
                // Free cpool values
                for cpVal in fb.cpool {
                    cpVal.freeValue()
                }
                Unmanaged.passUnretained(fb).release()
            }
        }
        return
    }
}

// MARK: - Main GC entry point

/// Trampoline so JeffJSRuntime.runGC() (instance method) can call the free
/// function runGC(_:) without name collision.
func _runGCImpl(_ rt: JeffJSRuntime) { runGC(rt) }

/// Run a full garbage-collection cycle: trial deletion, scan, sweep.
///
/// This implements the Bacon-Rajan synchronous cycle collector:
///   1. **Decref** — trial-delete by decrementing children of white objects.
///   2. **Scan** — rescue any object whose adjusted refcount is > 0.
///   3. **Free cycles** — anything still at zero is unreachable; free it.
func runGC(_ rt: JeffJSRuntime) {
    guard rt.gcPhase == .JS_GC_PHASE_NONE, !rt.inFreeChain, !jeffJS_gcDisable else { return }
    let gcStart = CFAbsoluteTimeGetCurrent()
    defer {
        let end = CFAbsoluteTimeGetCurrent()
        rt.gcLastEnd = end
        rt.gcLastDuration = end - gcStart
        rt.gcLiveAfterLast = rt.mallocState.mallocSize
    }

    // Objects whose refcount hit zero while a free chain was unwinding must be
    // gone before trial deletion: a dead object still on the GC list would be
    // decremented into the negative and confuse the scan.
    freeZeroRefcount(rt)
    let freedBefore = rt.gcCyclesFreed

    #if canImport(Metal)
    // The GPU collector declines (returns false) rather than guesses: a kernel
    // that failed, a rescue wavefront that did not converge inside the
    // iteration cap, or a heap shape it has no parity for all end with nothing
    // freed and the CPU collector running instead on the same heap. Abandoning
    // is always safe — the objects are still there for the next pass — while
    // freeing on a half-finished scan is not.
    if JeffJSMetalGC.shared.shouldUseMetalGC(objectCount: rt.gcObjects.count) {
        if JeffJSMetalGC.shared.runMetalGC(rt: rt) {
            freeZeroRefcount(rt)
            pruneWeakRefs(rt)
            rt.gcRuns += 1
            rt.mallocGCThreshold = jeffJS_nextGCThreshold(rt, reclaimed: rt.gcCyclesFreed - freedBefore)
            return
        }
        if jeffJS_gcDebug { print("[GC-metal] declined; falling back to the CPU collector") }
    }
    #endif

    // Phase 0: var-ref counts are not maintained incrementally (closures hold
    // them through ARC), so start them from zero — see gcDecrefChild.
    gcSeedVarRefs(rt)

    // Phase 1: trial decrements
    rt.gcPhase = .JS_GC_PHASE_DECREF
    gcDecref(rt)

    // Phase 2: scan — rescue everything reachable from an externally
    // referenced object, restoring the counts phase 1 removed.
    gcScan(rt)

    // Phase 2b: give the unreachable objects their counts back so that the
    // ordinary free path in phase 3 (which decrements children) stays
    // balanced. This is quickjs's `gc_scan_incref_child2` loop.
    gcRestoreUnreachable(rt)

    // Phase 3: free unreachable cycles
    rt.gcPhase = .JS_GC_PHASE_REMOVE_CYCLES
    gcFreeCycles(rt)

    rt.gcPhase = .JS_GC_PHASE_NONE

    // Drain objects that hit zero during the collection.
    freeZeroRefcount(rt)

    // Prune dead weak references
    pruneWeakRefs(rt)

    rt.gcRuns += 1
    rt.mallocGCThreshold = jeffJS_nextGCThreshold(rt, reclaimed: rt.gcCyclesFreed - freedBefore)
}

/// Next allocation watermark, quickjs's `JS_RunGC` tail: grow to 1.5x the
/// live heap, never below the initial threshold. `mallocSize` is decremented
/// on every free, so it tracks the *live* heap — transient allocations do not
/// push the threshold up and the collector only runs when the live set grows.
@inline(__always)
func jeffJS_nextGCThreshold(_ rt: JeffJSRuntime, reclaimed: Int) -> Int {
    let live = rt.mallocState.mallocSize
    // A run that reclaimed nothing says the heap is genuinely live; doubling
    // instead of 1.5x halves the number of fruitless full walks while a tree
    // is being built (bench/realworld.js `vdom-build-diff` grows to 700k live
    // objects and finds no cycles at all). Any run that *did* find garbage
    // keeps quickjs's 1.5x, so a leaky page is still collected promptly.
    let grown = reclaimed > 0 ? live + (live >> 1) : live << 1
    return max(grown, JeffJSConfig.gcMallocThreshold)
}

// MARK: - Phase 0: Var-ref seeding

/// Zero every listed (i.e. detached) var-ref's refcount. After the scan and
/// the restore pass each one holds exactly the number of references to it
/// from GC objects, so a var-ref reachable only from an unreachable closure
/// ends the run white and is collected with it.
private func gcSeedVarRefs(_ rt: JeffJSRuntime) {
    for u in rt.gcObjects {
        u._withUnsafeGuaranteedRef { hdr in
            if hdr.gcObjType == .varRef { hdr.refCount = 0 }
        }
    }
}

// MARK: - Phase 1: Trial deletion (gcDecref)

/// Walk all GC objects and perform a trial decrement of every child reference.
/// After this pass, an object whose effective refcount is zero is *probably*
/// garbage (it might still be rescued in Phase 2).
private func gcDecref(_ rt: JeffJSRuntime) {
    for u in rt.gcObjects {
        u._withUnsafeGuaranteedRef { hdr in
            hdr.mark = JeffJSGCMark.white
            markChildren(rt, hdr) { rt, child in
                gcDecrefChild(rt, child)
            }
        }
    }
}

/// Called for every child of an object during Phase 1.
/// Decrements the child's refcount (trial deletion).
///
/// No `refCount > 0` guard: the decrement and the phase-2 restore must be
/// exactly symmetric, or a skipped decrement becomes a permanent +1 on the
/// next scan. Every counted edge was paid for by a matching `dupValue`, so a
/// correctly refcounted graph can never go negative here.
func gcDecrefChild(_ rt: JeffJSRuntime, _ header: JeffJSGCObjectHeader) {
    guard isGCTracked(header) else { return }
    // Var-refs are seeded to zero by gcSeedVarRefs instead: nothing maintains
    // their refcount incrementally, so "in-degree minus in-degree" is already
    // the state trial deletion is trying to reach. Phase 2 and 2b still incref
    // them, which leaves the count at the true in-degree afterwards.
    if header.gcObjType == .varRef { return }
    header.refCount -= 1
}

/// True when `header` takes part in trial deletion, i.e. it is on one of the
/// runtime's GC lists (see `gcListIndex`).
///
/// Objects built while the intrinsics are installed are deliberately left off
/// the list (see `JeffJSObject.init`), and so are pooled objects while they are
/// parked. Trial deletion must therefore stay inside the tracked sub-graph: an
/// untracked node is never a scan root, so a count taken off it here could
/// never be put back, and the next dup/free pair would free a live object.
/// That is how `RegExp.prototype` lost all 15 of its properties after a single
/// chained `RegExp.prototype.x` read: the shape -> proto edge was decremented
/// on an untracked prototype once per GC. The decrement is fine now that the
/// edge is counted (`jeffJS_shapeSetProto`) *and* guarded by this predicate.
/// The Metal collector already works this way: it only records children it can
/// map to a tracked index.
@inline(__always)
func isGCTracked(_ header: JeffJSGCObjectHeader) -> Bool {
    return header.gcListIndex != -1
}

// MARK: - Phase 2: Scan / rescue (gcScan)

/// Walk all GC objects.  Any object whose refcount is still > 0 after trial
/// deletion is externally reachable — "rescue" it and all of its children
/// by restoring their reference counts and marking them black.
private func gcScan(_ rt: JeffJSRuntime) {
    // Explicit worklist, not recursion: a 200k-node parent chain would blow
    // the Swift stack (quickjs gets the same effect for free by appending
    // revived objects to the list it is iterating).
    var work: ContiguousArray<Unmanaged<JeffJSGCObjectHeader>> = []
    for u in rt.gcObjects {
        // `mark == white` matters: an object reached as a child of an earlier
        // root is already black and has had its children increfed once. Doing
        // it again here would inflate every one of them by one per GC.
        let isRoot = u._withUnsafeGuaranteedRef { hdr -> Bool in
            guard hdr.mark == JeffJSGCMark.white, hdr.refCount > 0 else { return false }
            hdr.mark = JeffJSGCMark.black
            return true
        }
        guard isRoot else { continue }
        work.append(u)
        while let cur = work.popLast() {
            cur._withUnsafeGuaranteedRef { hdr in
                markChildren(rt, hdr) { _, child in
                    // Symmetric with gcDecrefChild: untracked nodes were never
                    // decremented, so restoring them would inflate the count.
                    guard isGCTracked(child) else { return }
                    child.refCount += 1
                    if child.mark == JeffJSGCMark.white {
                        child.mark = JeffJSGCMark.black
                        work.append(Unmanaged.passUnretained(child))
                    }
                }
            }
        }
    }
}

/// Rescue a child: restore its refcount and, if this is the first rescue,
/// visit its children. Kept as a free function for the Metal collector and
/// tests; `gcScan` itself uses an explicit worklist.
func gcScanIncrefChild(_ rt: JeffJSRuntime, _ header: JeffJSGCObjectHeader) {
    guard isGCTracked(header) else { return }
    header.refCount += 1
    if header.mark == JeffJSGCMark.white {
        header.mark = JeffJSGCMark.black
        markChildren(rt, header) { rt, child in
            gcScanIncrefChild(rt, child)
        }
    }
}

// MARK: - Phase 2b: Restore the unreachable set (gc_scan_incref_child2)

/// Every object left white is unreachable. Give its children back the counts
/// phase 1 took, so the ordinary object-free path used in phase 3 — which
/// decrements each child exactly once — leaves the graph balanced. Without
/// this, a still-live object referenced only by a dying one is left one count
/// short and the free that follows drops it to zero while it is still in use.
private func gcRestoreUnreachable(_ rt: JeffJSRuntime) {
    for u in rt.gcObjects {
        u._withUnsafeGuaranteedRef { hdr in
            guard hdr.mark == JeffJSGCMark.white else { return }
            markChildren(rt, hdr) { _, child in
                guard isGCTracked(child) else { return }
                child.refCount += 1
            }
        }
    }
}

// MARK: - Phase 3: Free cycles (gcFreeCycles)

/// Any object still marked white after scanning is part of an unreachable
/// cycle — move it to the temporary list and then free everything on that list.
private func gcFreeCycles(_ rt: JeffJSRuntime) {
    // Move white objects to tmp list, keep black objects.
    // Maintain the intrusive gcListIndex on both lists.
    rt.gcTmpObjects.removeAll(keepingCapacity: true)
    var remaining: ContiguousArray<Unmanaged<JeffJSGCObjectHeader>> = []
    remaining.reserveCapacity(rt.gcObjects.count)
    for u in rt.gcObjects {
        // Unreachable JS values, plus the hashed shapes nothing is on any more
        // (`jeffJS_shapeIsSweepable`). The shapes have to go *with* this group
        // rather than after it: a white shape's prototype is white too, so a
        // collection that freed the prototype and left the shape behind left
        // the shape's `proto` pointing at freed memory — and the next thing to
        // release it read a dead object. `gcFreeDeadObjects` is exactly the
        // protocol for a mutually-dead group: it breaks every edge before it
        // hands any allocation back.
        let isDead = u._withUnsafeGuaranteedRef { hdr -> Bool in
            guard hdr.mark == JeffJSGCMark.white else { return false }
            if hdr.gcObjType == .jsObject || hdr.gcObjType == .functionBytecode
                || hdr.gcObjType == .varRef { return true }
            return jeffJS_shapeIsSweepable(rt, hdr)
                || jeffJS_shapeLosesProto(hdr) { p in
                    p.mark == JeffJSGCMark.white && isGCTracked(p)
                }
        }
        if isDead {
            u._withUnsafeGuaranteedRef { $0.gcListIndex = -2 - rt.gcTmpObjects.count }
            rt.gcTmpObjects.append(u)
        } else {
            u._withUnsafeGuaranteedRef { $0.gcListIndex = remaining.count }
            remaining.append(u)
        }
    }
    rt.gcObjects = remaining
    rt.gcCyclesFreed += rt.gcTmpObjects.count
    for u in rt.gcTmpObjects where u._withUnsafeGuaranteedRef({ $0.gcObjType == .shape }) {
        rt.shapesEvicted += 1
    }

    // Strong from here on: gcFreeDeadObjects hands the allocations back.
    var dead: [JeffJSGCObjectHeader] = []
    dead.reserveCapacity(rt.gcTmpObjects.count)
    for u in rt.gcTmpObjects {
        dead.append(gcUnlistDead(rt, u))
    }
    rt.gcTmpObjects.removeAll(keepingCapacity: true)
    gcDebugDumpDead(rt, dead, collector: "cpu")
    gcFreeDeadObjects(rt, dead)
}

/// `JEFFJS_GC_DEBUG=1`: print what a collection is about to free. Shared by the
/// CPU and Metal collectors so a divergence between the two reads as a diff of
/// two logs rather than one log and a silence.
func gcDebugDumpDead(_ rt: JeffJSRuntime, _ dead: [JeffJSGCObjectHeader], collector: String) {
    guard jeffJS_gcDebug else { return }
    print("[GC-\(collector)] freeing \(dead.count) object(s)")
    for hdr in dead.prefix(40) {
        guard let obj = hdr as? JeffJSObject, let sh = obj.shape else { continue }
        var names: [String] = []
        for pr in sh.prop.prefix(8) { names.append(rt.atomToString(pr.atom) ?? "?") }
        print("[GC-FREE] class=\(obj.classID) rc=\(obj.refCount) props=\(names)")
    }
}

/// True when `header` is a hashed shape with no owners left, i.e. one the
/// collection should sweep out of the transition table.
///
/// Nothing ever emptied that table: `removeHashedShape` was reachable only
/// from `freeShape`, and `freeObject` refused to free a hashed shape at zero
/// owners, so `shapeHashCount` only went up. Because a shape owns one counted
/// reference to its prototype (Round 12), a loop that builds a fresh prototype
/// parked one hashed root shape per prototype and kept that prototype alive
/// for the life of the runtime — 0.72 objects per iteration. Past
/// `shapes.maxHashed` (16 384) it got worse, not better: insertion is simply
/// skipped, so every later object builds a private shape and every property
/// access on it is a permanent inline-cache miss.
///
/// Sweeping is safe even though the inline caches compare shapes by raw
/// address, for three reasons that all had to hold:
///  * `refCount == 0` means no object is on the shape, so no live receiver can
///    match an IC entry naming it. All four context-level shape caches take a
///    count — `plainObjectRootShape` did not, and now does.
///  * Every IC entry retains the shapes it names (`JeffJSInlineCache` already
///    did this, against exactly this hazard), so the allocation outlives the
///    sweep and its address cannot be handed to a new shape while a stale
///    entry still points at it.
///  * `removeHashedShape` clears `isHashed`, and `jeffJS_icDefine` refuses a
///    transition target that is not hashed — so a `define_field` cache whose
///    `nextShapePtr` was swept misses instead of moving an object onto a
///    gutted shape. That is the invalidation, and it was already there.
@inline(__always)
func jeffJS_shapeIsSweepable(_ rt: JeffJSRuntime, _ header: JeffJSGCObjectHeader) -> Bool {
    guard header.gcObjType == .shape, header.refCount == 0,
          rt.shapeHashCount >= JeffJSConfig.shapesEvictThreshold else { return false }
    return unsafeBitCast(header, to: JeffJSShape.self).isHashed
}

/// True when `header` is a shape whose prototype this collection frees, so the
/// shape has to be freed in the same group (`isDying` answers "is this object
/// in the dead set" for the collector asking).
///
/// Only ever asked about an unreachable shape. An unreachable shape's owners
/// are all unreachable too (an owner outside the dead set would have rescued
/// it), so once the group is freed nothing is on it and it is exactly what
/// quickjs frees in `js_free_shape` when the last owner goes. Leaving it behind
/// is only harmless when its prototype survives: a hashed shape is kept cached
/// at zero owners for the inline caches, and it keeps its one counted
/// reference on the prototype (`jeffJS_shapeSetProto`). If the prototype is in
/// the dead set, that reference now names a freed object, and whatever frees
/// the shape later — the sweep in a later collection, which is what
/// `JEFFJS_ZOMBIES=1` caught on Google's tag script, or runtime teardown —
/// releases it a second time. Two ways in:
///  * the shape still had owners when the group was chosen (a prototype and
///    an instance in one cycle: `o = Object.create(P); P.o = o`), so
///    `jeffJS_shapeIsSweepable`'s `refCount == 0` test failed; freeing the
///    owners then dropped it to zero, and hashed shapes are not freed at zero;
///  * it had no owners but the table was below `shapes.evictThreshold`.
/// A dead shape whose prototype survives is still left to the eviction
/// policy, so a class whose instances die in cycles keeps its cached shapes.
@inline(__always)
func jeffJS_shapeLosesProto(_ header: JeffJSGCObjectHeader,
                            _ isDying: (JeffJSObject) -> Bool) -> Bool {
    guard header.gcObjType == .shape,
          let p = unsafeBitCast(header, to: JeffJSShape.self).proto else { return false }
    guard p.gcObjType == .jsObject || p.gcObjType == .functionBytecode else { return false }
    return isDying(p)
}

/// Take a doomed header off the GC lists by hand. The lists have already been
/// rebuilt around it, so `removeGCObject` would find nothing to unlink and,
/// crucially, would skip the malloc accounting — which is what the threshold
/// is computed from. Leaving that out made `mallocSize` ratchet up by one
/// collection's worth of garbage every run: the live heap stayed at 13 MB
/// while the accounted heap (and therefore the trigger) climbed past 250 MB,
/// so a long browsing session collected less and less often.
@inline(__always)
private func gcUnlistDead(_ rt: JeffJSRuntime,
                          _ u: Unmanaged<JeffJSGCObjectHeader>) -> JeffJSGCObjectHeader {
    let hdr = u.takeUnretainedValue()
    hdr.gcListIndex = -1
    rt.mallocState.mallocSize -= JS_GC_OBJ_COST
    rt.mallocState.mallocCount -= 1
    return hdr
}

/// Free a set of objects that are known to be unreachable **as a group**.
///
/// Two phases, for the same reason `freeGCObjectAtZeroRefcount` has them: a
/// cycle's members point at each other, so releasing A's ARC retain as soon as
/// A's children are processed lets A deallocate while B still holds A's raw
/// NaN-boxed pointer — and B's own free then reads a dead object. Phase 1
/// breaks every edge (and marks each header refCount = -1, which makes any
/// later `freeValue` on a stale pointer a no-op); only then does phase 2 hand
/// the allocations back.
func gcFreeDeadObjects(_ rt: JeffJSRuntime, _ dead: [JeffJSGCObjectHeader]) {
    var toRelease: [JeffJSGCObjectHeader] = []
    toRelease.reserveCapacity(dead.count)
    // Shapes last. A dead shape can still have owners in this group
    // (`jeffJS_shapeLosesProto`); freeing the owners first brings it to zero
    // the ordinary way, and nothing ever sees an object on an emptied shape.
    var hasShapes = false
    for hdr in dead {
        if hdr.gcObjType == .shape { hasShapes = true; continue }
        guard hdr.refCount >= 0 else { continue }   // already processed
        freeGCObjectChildren(rt, hdr)
        toRelease.append(hdr)
    }
    if hasShapes {
        for hdr in dead where hdr.gcObjType == .shape {
            // A non-hashed shape its last owner just freed is already done
            // (refCount -1); a hashed one is at zero and still holds its proto.
            if hdr.refCount < 0 { continue }
            if hdr.refCount > 0 {
                // Cannot happen while the mark set is exactly the counted edges
                // (an unreachable shape's owners are all in this group). If it
                // ever does, a live object is still on the shape: leave it
                // listed rather than empty it under that object.
                if jeffJS_gcDebug { print("[GC] dead shape kept: \(hdr.refCount) owner(s) outside the group") }
                addGCObject(rt, hdr)
                continue
            }
            freeGCObjectChildren(rt, hdr)
        }
    }
    // A dying object can drop a *non*-cycle object to zero (it held the last
    // reference to an acyclic subgraph); those were deferred by
    // freeGCObjectAtZeroRefcount because the GC phase is REMOVE_CYCLES.
    while let deferred = rt.gcZeroRefCountObjects.popLast() {
        if deferred.refCount == 0 {
            freeGCObjectChildren(rt, deferred)
            toRelease.append(deferred)
        }
    }
    for hdr in toRelease {
        switch hdr.gcObjType {
        case .jsObject, .bigInt, .functionBytecode:
            if jeffJSZombiesEnabled {
                if let obj = hdr as? JeffJSObject { obj.freeMark = true }
                rt.zombieKeepAlive.append(hdr)
            } else {
                Unmanaged.passUnretained(hdr).release()
            }
        default:
            break   // shapes and var-refs are ARC-managed
        }
    }
}

// MARK: - GC trigger

/// Idle collection. The allocation trigger (`mallocGCThreshold`, quickjs's
/// 1.5x-the-live-heap watermark) never fires on a page that only runs timers
/// and animation frames: each tick leaves a few hundred bytes of *cyclic*
/// garbage (a React commit's effect ring, a promise and its resolvers, a
/// closure and the object it was stored on), so the live count creeps up for
/// minutes before it crosses a watermark set at half again the page's whole
/// heap (threes.day: +300 objects/s, 90 000 live, next collection at 135 000).
///
/// So a collection also runs between tasks — at the start of a top-level
/// native -> JS call (timer, animation frame, event) — once the live heap has
/// grown by 1/2^`gc.idleGrowthShift` (1/64) since the last one and at least
/// `gc.idleIntervalMs` (1 s) has passed; the interval stretches to 50x the
/// last collection's duration, which caps these collections at 2% of the
/// thread. `gc.idleGrowthShift` 0 turns it off.
nonisolated(unsafe) let jeffJS_idleGCShift = JeffJSConfig.gcIdleGrowthShift
nonisolated(unsafe) let jeffJS_idleGCInterval = Double(JeffJSConfig.gcIdleIntervalMs) / 1000

@inline(__always)
func jeffJS_idleGCTick(_ rt: JeffJSRuntime) {
    guard jeffJS_idleGCShift > 0 else { return }
    let live = rt.mallocState.mallocSize
    let base = rt.gcLiveAfterLast
    guard live - base >= max(base >> jeffJS_idleGCShift, 64 * JeffJSConfig.gcObjectCost) else { return }
    jeffJS_idleGCTickSlow(rt)
}

@inline(never)
func jeffJS_idleGCTickSlow(_ rt: JeffJSRuntime) {
    let now = CFAbsoluteTimeGetCurrent()
    let interval = max(jeffJS_idleGCInterval, rt.gcLastDuration * 50) * Double(rt.gcIdleBackoff)
    guard now - rt.gcLastEnd >= interval else { return }
    guard rt.gcPhase == .JS_GC_PHASE_NONE, !rt.inFreeChain, rt.initComplete else { return }
    rt.gcIdleRuns += 1
    let grown = rt.mallocState.mallocSize - rt.gcLiveAfterLast
    let freedBefore = rt.gcCyclesFreed
    runGC(rt)
    // A collection that got back less than half of what the heap grew by
    // says the growth is live (or leaked, which no collection fixes): wait
    // twice as long before the next idle one, up to 64x. One that did
    // reclaim the growth resets the interval.
    let reclaimed = (rt.gcCyclesFreed - freedBefore) * JeffJSConfig.gcObjectCost
    if reclaimed * 2 < grown {
        rt.gcIdleBackoff = min(rt.gcIdleBackoff * 2, 64)
    } else {
        rt.gcIdleBackoff = 1
    }
}

/// Check if the allocation watermark has crossed the GC threshold.
/// If so, run a full collection.
func triggerGC(_ rt: JeffJSRuntime, size: Int) {
    rt.mallocState.mallocSize += size
    if rt.mallocState.mallocSize >= rt.mallocGCThreshold {
        runGC(rt)
    }
}

// MARK: - Mark function dispatch

/// `JS_CLASS_OBJECT`: a plain `{}`. Never carries a payload with GC edges.
private let jeffJS_plainObjectClassID = JSClassID.JS_CLASS_OBJECT.rawValue

/// Visitor callback type.
typealias JeffJSMarkFunc = (_ rt: JeffJSRuntime, _ child: JeffJSGCObjectHeader) -> Void

/// Enumerate all GC-managed children of `header`, calling `markFunc` for each.
/// This dispatches on the object's ``JSGCObjectTypeEnum``.
///
/// # The one invariant
///
/// Trial deletion subtracts, for every tracked node, the references its
/// children's `refCount` fields were incremented for. The set enumerated here
/// must therefore be **exactly the set of edges that hold a manual refcount**,
/// i.e. the edges `freeGCObjectChildren`/`freeObject` release. Two failure
/// modes bracket it:
///
/// * Marking an edge that was never counted (an ARC-only strong reference)
///   removes a reference nobody added: the child's count goes one too low on
///   every collection and the next `freeValue` frees a live object.
/// * *Not* marking a counted edge is always safe — the child keeps a
///   reference the collector cannot account for, so it looks externally
///   rooted and is rescued. Conservative: it leaks, it never over-frees.
///
/// The prototype chain is a counted edge and is marked, as quickjs marks
/// `sh->proto` through `js_shape_mark`: it hangs off the **shape**, which owns
/// the one reference (`jeffJS_shapeSetProto`, released by `freeShape`), and
/// the object reaches it through the owner count it holds on that shape
/// (marked by `markObject`). `obj.storedProto` is an uncounted mirror of
/// `obj.shape!.proto` and must *not* be marked as well — that would be the
/// same edge twice.
///
/// Edges that are ARC-only and therefore deliberately skipped: `obj.proto`
/// (the mirror), closure var-refs (`varRefsFast` / the `.bytecodeFunc`
/// payload and `JeffJSPropertyExtra.varRef` — see `JeffJSVarRef`, "kept alive
/// by their varRefs arrays (ARC)"), the function bytecode constant pool (the
/// FB is not a GC node), a shape's transition `parent`, and `homeObject`.
func markChildren(_ rt: JeffJSRuntime,
                  _ header: JeffJSGCObjectHeader,
                  _ markFunc: JeffJSMarkFunc) {
    switch header.gcObjType {
    case .jsObject, .functionBytecode:
        let obj = unsafeBitCast(header, to: JeffJSObject.self)
        markObject(rt, obj, markFunc)
    case .shape:
        // A shape's one counted reference is its prototype (quickjs's
        // js_shape_mark). `parent` is an ARC-only prefix witness.
        let shape = unsafeBitCast(header, to: JeffJSShape.self)
        if let p = shape.proto { markFunc(rt, p) }
    case .varRef:
        // Only detached var-refs are listed; their value is a counted edge
        // (`close_loc` dups it, freeGCObjectChildren releases it).
        let vr = unsafeBitCast(header, to: JeffJSVarRef.self)
        if vr.isDetached, let child = vr.value.toGCObjectHeader() { markFunc(rt, child) }
    case .bigInt, .bigFloat, .bigDecimal:
        // Leaf types — no children.
        break
    case .asyncFunction:
        break
    case .mapIteratorData, .arrayIteratorData,
         .regexpStringIteratorData:
        break
    }
}

/// Mark all counted children of a JSObject. See `markChildren` for the rule
/// that decides what belongs here; every edge below is released by
/// `freeObject`, and the two lists must be changed together.
func markObject(_ rt: JeffJSRuntime,
                _ obj: JeffJSObject,
                _ markFunc: JeffJSMarkFunc) {
    // 0. The shape. `shape.refCount` counts the objects sitting on it, so it
    // is a counted edge like any other (quickjs: `mark_func(rt, &p->shape->
    // header)`), and it is the edge through which the prototype is reached.
    // Without it a shape whose owners are all garbage still looks like a root,
    // rescues its prototype, and with it the whole dead class: `class B
    // extends A {}` dropped in a loop would never collect, because
    // `B.prototype`'s shape holds `A.prototype`.
    // The collector never *frees* a shape (hashed ones stay cached at zero
    // owners for the inline caches, which key on raw shape addresses), it only
    // stops treating them as roots.
    if let sh = obj.shape { markFunc(rt, sh) }

    // 1. Property values (split storage: data values + rare-case boxes).
    let n = obj.propValues.count
    if n > 0 {
        if obj.propExtraCount == 0 {
            for i in 0..<n {
                if let child = obj.propValues[i].toGCObjectHeader() { markFunc(rt, child) }
            }
        } else {
            for i in 0..<n {
                if let e = obj.extra(at: i) {
                    switch e.kind {
                    case .getset:
                        // Counted: defineProperty dups getter and setter.
                        if let g = e.getter { markFunc(rt, g) }
                        if let s = e.setter { markFunc(rt, s) }
                    case .varRef:
                        // A mapped `arguments` slot holds the var-ref the
                        // closures share; detached ones are graph nodes.
                        if let vr = e.varRef, vr.gcListIndex != -1 { markFunc(rt, vr) }
                    case .autoInit:
                        break
                    }
                } else if let child = obj.propValues[i].toGCObjectHeader() {
                    markFunc(rt, child)
                }
            }
        }
    }

    // 2. An arrow's captured `this` is a counted edge (dup'd by createClosure,
    // released by freeObject / the recycle pool): cycles through it
    // (instance.f = () => this) are only collectable if it is marked.
    if let at = obj.arrowThisVal, let child = at.toGCObjectHeader() { markFunc(rt, child) }

    // 3. Captured variables. `var node = {}; node.cb = function () { return node; }`
    // is the shape every React render produces, and it is only collectable if
    // the closure -> var-ref -> object chain is an edge. The unmanaged mirror
    // of `varRefsFast` is used so marking costs no ARC traffic.
    if let raw = obj.varRefsRaw {
        for i in 0..<obj.varRefsRawCount {
            if let vr = raw[i]?.takeUnretainedValue(), vr.gcListIndex != -1 {
                markFunc(rt, vr)
            }
        }
    }

    // 3b. Weak-collection values keyed by this object: an ephemeron's value
    // is reachable through its key, not through the WeakMap (see "Weak
    // collections" in JeffJSBuiltinMap.swift). `weakrefCount` is zero for
    // every object that is not a live WeakMap/WeakSet key.
    if obj.weakrefCount != 0 { jeffJS_markWeakKeyValues(rt, obj, markFunc) }

    // 4. Payload — only the counted edges (see markChildren). A plain
    // object has none, and both `_fastArrayValues` and `payload` are
    // ARC-bearing reads (copying the payload enum retains its associated
    // class), so the overwhelmingly common case skips both on one compare.
    if obj.classID == jeffJS_plainObjectClassID { return }
    if let storage = obj._fastArrayValues {
        // Authoritative array store when materialised; the enum payload holds
        // the same elements, so never mark both.
        let count = min(Int(storage.count), storage.values.count)
        for i in 0..<count {
            if let child = storage.values[i].toGCObjectHeader() { markFunc(rt, child) }
        }
        return
    }
    switch obj.payload {
    case .array(_, let values, let count):
        for i in 0..<Int(count) where i < values.count {
            if let child = values[i].toGCObjectHeader() { markFunc(rt, child) }
        }
    case .typedArray(let ta):
        // A typed array / DataView owns a counted reference to its
        // ArrayBuffer object (typedArrayAdoptBuffer), released by freeObject.
        if let buf = ta.buffer { markFunc(rt, buf) }
    case .generatorData(let gd):
        // A suspended generator owns its saved stack, locals, arguments,
        // `this` and function (JeffJSGeneratorData.releaseSuspendedState
        // releases exactly these), and holds the var-refs its own closures
        // captured.
        if let saved = gd.savedState {
            for v in saved.stack { if let c = v.toGCObjectHeader() { markFunc(rt, c) } }
            for v in saved.varBuf { if let c = v.toGCObjectHeader() { markFunc(rt, c) } }
            for v in saved.argBuf { if let c = v.toGCObjectHeader() { markFunc(rt, c) } }
            if let c = saved.delegatedIter.toGCObjectHeader() { markFunc(rt, c) }
            if let c = saved.thisVal.toGCObjectHeader() { markFunc(rt, c) }
            if let c = saved.funcObj.toGCObjectHeader() { markFunc(rt, c) }
            for vr in saved.capturedVarRefs where vr.gcListIndex != -1 { markFunc(rt, vr) }
        }
        for vr in gd.asyncState.frame.liveVarRefs where vr.gcListIndex != -1 { markFunc(rt, vr) }
    case .asyncFunctionData(let st):
        // A parked `await` keeps its whole frame; the var-refs its closures
        // captured are detached (the frame's buffer was released at the
        // suspend point) and nothing else on the GC graph points at them, so
        // without this edge the collector treats them as unreferenced and
        // clears the locals the continuation is going to read.
        for vr in st.frame.liveVarRefs where vr.gcListIndex != -1 { markFunc(rt, vr) }
    case .proxyData(let pd):
        // A proxy owns its target and handler (released by freeObject).
        if let c = pd.target.toGCObjectHeader() { markFunc(rt, c) }
        if let c = pd.handler.toGCObjectHeader() { markFunc(rt, c) }
    case .mapState(let ms):
        // A Map/Set owns a counted reference to every key and value
        // (released by jeffJS_mapStateFree). Weak collections own only the
        // values, which are marked from their keys (3b above).
        if !ms.isWeak {
            for rec in ms.records where !rec.empty {
                if let c = rec.key.toGCObjectHeader() { markFunc(rt, c) }
                if let c = rec.value.toGCObjectHeader() { markFunc(rt, c) }
            }
        }
    case .promiseData(let pd):
        // A promise owns its settled value and the handler and result promise
        // of every queued reaction (released by jeffJS_promiseDataFree):
        // `o.p = new Promise(...); o.p.then(() => o)` is a cycle.
        if let c = pd.promiseResult.toGCObjectHeader() { markFunc(rt, c) }
        for r in pd.promiseFulfillReactions {
            if let c = r.handler.toGCObjectHeader() { markFunc(rt, c) }
            if let c = r.resultPromise.toGCObjectHeader() { markFunc(rt, c) }
        }
        for r in pd.promiseRejectReactions {
            if let c = r.handler.toGCObjectHeader() { markFunc(rt, c) }
            if let c = r.resultPromise.toGCObjectHeader() { markFunc(rt, c) }
        }
    case .boundFunction(let bf):
        // A bound function owns its target, `this` and arguments (released
        // by freeObject): `obj.cb = obj.m.bind(obj)` is a cycle.
        if let c = bf.funcObj.toGCObjectHeader() { markFunc(rt, c) }
        if let c = bf.thisVal.toGCObjectHeader() { markFunc(rt, c) }
        for a in bf.argv { if let c = a.toGCObjectHeader() { markFunc(rt, c) } }
    default:
        break
    }
}

// MARK: - Free dispatch

/// Free a GC-managed object by type.
/// Process an object's children (free properties, shapes, cpool, var-refs)
/// WITHOUT releasing the ARC retain. This allows the caller to batch ARC
/// releases after all children in a cycle have been processed.
func freeGCObjectChildren(_ rt: JeffJSRuntime, _ header: JeffJSGCObjectHeader) {
    // Remove from the GC object list (may already have been removed).
    removeGCObject(rt, header)

    // Mark as being freed to prevent re-entrant processing
    header.refCount = -1

    switch header.gcObjType {
    case .jsObject:
        let obj = unsafeBitCast(header, to: JeffJSObject.self)
        freeObject(rt, obj)
    case .shape:
        let shape = unsafeBitCast(header, to: JeffJSShape.self)
        freeShape(rt, shape)
    case .functionBytecode:
        let obj = unsafeBitCast(header, to: JeffJSObject.self)
        if let at = obj.arrowThisVal { obj.arrowThisVal = nil; freeValue(rt, at) }
        if case .bytecodeFunc(let fb, let varRefs, _) = obj.payload, let fb = fb {
            for cpVal in fb.cpool {
                freeValue(rt, cpVal)
            }
            fb.cpool.removeAll()
            for vr in varRefs {
                if let vr = vr {
                    vr.refCount -= 1
                    if vr.refCount == 0 {
                        // Defer child var-ref freeing
                        rt.gcZeroRefCountObjects.append(vr)
                    }
                }
            }
        }
    case .varRef:
        let vr = unsafeBitCast(header, to: JeffJSVarRef.self)
        if vr.isDetached {
            freeValue(rt, vr.value)
            vr.value = .undefined
        }
    default:
        break
    }
}

/// Full free: process children then release ARC retain for NaN-boxed types.
/// Only jsObject and bigInt are created with Unmanaged.passRetained (NaN-boxing).
/// Shapes/varRefs are normal Swift objects — ARC managed by strong references.
func freeGCObject(_ rt: JeffJSRuntime, _ header: JeffJSGCObjectHeader) {
    freeGCObjectChildren(rt, header)
    // Only release the Unmanaged retain for types created via Unmanaged.passRetained
    switch header.gcObjType {
    case .jsObject, .bigInt, .functionBytecode:
        if jeffJSZombiesEnabled {
            // Zombie mode: keep the allocation alive and flag it so any later
            // dup/free through a stale NaN-boxed pointer is caught with a stack.
            if let obj = header as? JeffJSObject { obj.freeMark = true }
            rt.zombieKeepAlive.append(header)
        } else {
            Unmanaged.passUnretained(header).release()
        }
    default:
        break // shapes, varRefs — ARC managed by strong property references
    }
}

/// Free a JSObject: release every property value, release the shape, then
/// let ARC reclaim the Swift object.
func freeObject(_ rt: JeffJSRuntime, _ obj: JeffJSObject) {
    // The global object must only ever be freed at context teardown. If this
    // fires mid-run, some path over-released it; the stack identifies the
    // culprit (this is the root of the shape-wipe corruption family).
    if obj.isProtectedGlobal {
        print("[GLOBAL-FREE] global object freed mid-run (rc=\(obj.refCount)) — stack:")
        for sym in Thread.callStackSymbols.prefix(16) { print("    \(sym)") }
    }
    // Capture and clear payload/properties FIRST, then free values.
    // This prevents re-entrant access to obj during cascading frees.
    let savedValues = obj.propValues          // moved out: freed below
    // A plain object has no payload edges — `markObject` returns on the same
    // compare before it reads either `_fastArrayValues` or `payload`, and this
    // is the other half of that rule. Reading the enum into a local and writing
    // `.opaque(nil)` back costs a retain *and* a release of whatever class the
    // case carries, plus the `didSet` re-matching it, on **every object freed**;
    // the sampler put `JeffJSObjectPayload` copy/destroy second only to
    // `swift_release` on a tree-teardown profile. Nothing cascades from a plain
    // object's payload, so there is nothing to clear for re-entrancy either,
    // and `JeffJSObject.deinit` releases it a moment later regardless.
    let plain = obj.classID == jeffJS_plainObjectClassID && obj._fastArrayValues == nil
    let savedPayload: JeffJSObjectPayload
    if plain {
        savedPayload = .opaque(nil)
    } else {
        savedPayload = obj.payload
        obj.payload = .opaque(nil)
        obj.fbFast = nil
        if !obj.varRefsFast.isEmpty { obj.varRefsFast = [] }
    }
    // Same shape of saving: `propExtra` is lazily allocated and empty for the
    // overwhelming majority of objects, and both the copy and the `= []` store
    // (which fires the `propExtraCount` observer) are pure overhead then.
    let extraCount = obj.propExtraCount
    let savedExtra: ContiguousArray<JeffJSPropertyExtra?>
    if extraCount == 0 {
        savedExtra = []
    } else {
        savedExtra = obj.propExtra
        obj.propExtra = []
    }
    obj.propValues = JeffJSPropStorage()
    let savedArrowThis = obj.arrowThisVal    // owned by the closure; released below
    if savedArrowThis != nil { obj.arrowThisVal = nil }

    // Release each property value. Data values are manually refcounted;
    // an accessor's getter/setter are too (`defineProperty` dups them, and
    // `markObject` marks them as counted edges) even though the slot stores
    // them as ARC references; a varRef slot and autoInit refs are ARC-only.
    if extraCount == 0 {
        // Every slot is a plain data value: one tight loop, no per-slot
        // `savedExtra.count` reload out of the ContiguousArray buffer.
        var i = 0
        let n = savedValues.count
        while i < n { freeValue(rt, savedValues[i]); i += 1 }
    } else {
      for i in 0..<savedValues.count {
        // propExtra is lazily allocated: empty means every slot is plain data.
        if i < savedExtra.count, let e = savedExtra[i] {
            switch e.kind {
            case .varRef:
                // A mapped `arguments` slot holds the *same* var-ref the
                // closures over that parameter captured (jeffJS_argVarRef
                // hands out one per frame slot), so the detached value is not
                // this object's to free — ARC is, through
                // `JeffJSVarRef.deinit`, when the last holder (arguments
                // object or closure, whichever goes second) lets go. Freeing
                // it here cleared the binding out from under every surviving
                // closure: `function f(x){ var a = arguments;
                // return function () { return x } }` handed back a closure
                // that read `undefined` as soon as f's arguments object died.
                break
            case .getset:
                // Dropping only the ARC reference left the manual count one
                // too high, so every object literal getter/setter (and every
                // accessor installed through Object.defineProperty) outlived
                // the object that owned it.
                let g = e.getter, st = e.setter
                e.getter = nil; e.setter = nil
                if let g { freeValue(rt, .borrowedObject(g)) }
                if let st { freeValue(rt, .borrowedObject(st)) }
            case .autoInit:
                break
            }
        } else {
            freeValue(rt, savedValues[i])
        }
      }
    }
    savedArrowThis?.freeValue()
    savedValues.deallocateStorage()

    // Payload was already cleared to .opaque(nil) above.
    // The saved payload's Swift class references (JeffJSFunctionBytecode,
    // arrays, etc.) will be released by ARC when savedPayload goes out of scope.
    // Explicit cpool/varRef/element freeing is deferred until the full
    // QuickJS refcount discipline is implemented in all operator functions.
    // Arrays own their element references: release them from whichever
    // storage is authoritative (the ref-type store when materialised, else
    // the enum payload; the two hold the same elements, so never both).
    if let storage = obj._fastArrayValues {
        obj._fastArrayValues = nil
        let n = Int(storage.count)
        var i = 0
        while i < n && i < storage.values.count { freeValue(rt, storage.values[i]); i += 1 }
        storage.values.removeAll()
        storage.count = 0
    } else if case .array(_, let vals, let count) = savedPayload {
        let n = Int(count)
        var i = 0
        while i < n && i < vals.count { freeValue(rt, vals[i]); i += 1 }
    }
    // A typed array / DataView owns a reference to its ArrayBuffer object
    // (taken in typedArrayAdoptBuffer, or inherited from the buffer's own
    // creation reference) — release it here, or every buffer ever viewed
    // outlives the runtime.
    // A Map/Set/WeakMap/WeakSet owns a counted reference to every key and
    // value it stores (see `jeffJS_mapStateFree`).
    if case .mapState(let ms) = savedPayload { jeffJS_mapStateFree(ms) }
    // A promise owns its settled value and every reaction still queued on it.
    if case .promiseData(let pd) = savedPayload { jeffJS_promiseDataFree(pd) }
    // A RegExp owns a counted reference on its pattern string (see
    // "Pattern ownership" in JeffJSBuiltinRegExp.swift).
    if case .regexp(let pattern, _) = savedPayload { js_regexp_releasePattern(pattern) }
    // A proxy owns its target and handler (dup'd by createProxyObject;
    // revocation only sets isRevoked, so they are released here).
    if case .proxyData(let pd) = savedPayload {
        freeValue(rt, pd.target)
        freeValue(rt, pd.handler)
    }
    // A bound function owns its target, bound `this` and bound arguments
    // (all dup'd by Function.prototype.bind). They were never released, so
    // every `f.bind(...)` of a short-lived function leaked the function (and
    // its closure) for good.
    if case .boundFunction(let bf) = savedPayload {
        freeValue(rt, bf.funcObj)
        freeValue(rt, bf.thisVal)
        for a in bf.argv { freeValue(rt, a) }
    }
    if case .typedArray(let ta) = savedPayload, let buf = ta.buffer {
        ta.buffer = nil
        if buf.refCount > 0 {
            if JeffJSGCObjectHeader.trackRefcounts { JeffJSGCObjectHeader.trackFree(buf) }
            buf.refCount -= 1
            if buf.refCount == 0 { freeGCObjectAtZeroRefcount(rt, buf) }
        }
    }
    _ = savedPayload  // ensure ARC release happens

    // Release shape — nil first (ARC -1), then process children if refCount=0.
    // Shapes are normal Swift objects (not NaN-boxed), so ARC manages their lifecycle.
    if let shape = obj.shape {
        obj.shape = nil  // ARC releases our strong ref
        shape.refCount -= 1
        if shape.refCount == 0 && !shape.isHashed {   // hashed shapes stay cached
            freeGCObjectChildren(rt, shape)
            // No Unmanaged.release — shapes are ARC-managed.
            // ARC will deallocate when all strong refs (gcObjects, other obj.shape) go away.
        }
    }

    // Invalidate any weak reference pointing at this object. `firstWeakRef` is
    // set by `weakrefNew` and is the only way an object gets into
    // `gcWeakRefMap`, so the field test answers exactly what the dictionary
    // probe did — without hashing an ObjectIdentifier on every object freed.
    // One live `WeakMap` entry used to put that probe on the whole heap's
    // teardown path (a 40 x 20 000 plain-object allocate-and-drop loop was 21%
    // slower with one WeakRef in the runtime than without).
    if obj.firstWeakRef != nil { weakrefFree(rt, obj) }
}

/// Free a Shape: remove from the runtime hash table if necessary, release the
/// prototype reference.
func freeShape(_ rt: JeffJSRuntime, _ shape: JeffJSShape) {
    if shape.isHashed {
        removeHashedShape(rt, shape)
    }

    // The shape owns one counted reference to its prototype (quickjs's
    // js_free_shape releases sh->proto the same way). Dropping only the ARC
    // reference here is what left every prototype pinned by the dup that
    // created the shape.
    jeffJS_shapeSetProto(shape, nil)
    // The transition parent is a strong reference held only to prove a
    // property prefix; a freed shape must not keep a chain of them alive.
    shape.parent = nil

    // Reset the bookkeeping along with the arrays. A freed shape can still be
    // reached through stale references; stale propCount/propHashMask with
    // empty arrays makes any later addShapeProperty index out of bounds.
    shape.prop.removeAll()
    shape.enumKeyCache = nil
    shape.propHash.removeAll()
    shape.propCount = 0
    shape.propSize = 0
    shape.deletedPropCount = 0
    shape.propHashMask = 0
}

/// Drain the list of objects whose refcount dropped to zero during a GC
/// cycle.  Those objects were deferred because freeing inside the collector
/// could mutate the object graph while we are iterating it.
func freeZeroRefcount(_ rt: JeffJSRuntime) {
    while let hdr = rt.gcZeroRefCountObjects.popLast() {
        if hdr.refCount == 0 {
            freeGCObject(rt, hdr)
        }
    }
}

// MARK: - Weak reference support

/// Create a weak reference from the runtime to `target`.
/// If a weak ref already exists for this target it is returned.
func weakrefNew(_ rt: JeffJSRuntime, _ target: JeffJSObject) -> JeffJSWeakRef {
    let key = ObjectIdentifier(target)
    if let existing = rt.gcWeakRefMap[key] {
        return existing
    }
    let ref = JeffJSWeakRef(target: target)
    rt.gcWeakRefMap[key] = ref
    // The marker `freeObject` and the recycle pool test instead of probing the
    // map. It is never cleared while the object lives, which also keeps a
    // weak-referenced object out of the recycle pool (`isPoolable`) — where it
    // has no business being anyway.
    target.firstWeakRef = ref
    return ref
}

/// Release the weak reference associated with `target`.
/// Called when the target object is being freed.
func weakrefFree(_ rt: JeffJSRuntime, _ target: JeffJSObject) {
    let key = ObjectIdentifier(target)
    if let ref = rt.gcWeakRefMap.removeValue(forKey: key) { ref.cleared = true }
    if target.weakrefCount != 0 { jeffJS_weakKeyDied(rt, target) }
}

/// Returns `true` if the weak reference's target is still alive.
func weakrefIsLive(_ ref: JeffJSWeakRef) -> Bool {
    return ref.isLive
}

/// Prune stale entries from the weak reference map.
/// Called after each GC cycle to remove entries whose target has been deallocated.
private func pruneWeakRefs(_ rt: JeffJSRuntime) {
    rt.gcWeakRefMap = rt.gcWeakRefMap.filter { $0.value.isLive }
}

/// Clear all GC tracking state for a runtime. Called during runtime teardown.
/// Breaks all inter-object reference cycles so ARC can reclaim memory.
func clearGCState(_ rt: JeffJSRuntime) {
    // Three passes, in dependency order. A JS object reads its shape (and its
    // payload's var-refs) while it is being torn down, so nothing a live
    // object points at may be emptied before the object itself is emptied:
    //   1. JS objects and function objects — drop props, payload, shape and
    //      prototype links. After this nothing points at a shape or a var-ref.
    //   2. Var-refs — drop the captured value and the (already dead) frame.
    //   3. Shapes — drop the property tables and the hash chain.
    // References are *dropped*, not released: teardown discards the whole
    // graph at once, and running the refcount free paths here would walk
    // objects that the earlier passes have already emptied.
    // Strong for the duration: emptying one object drops ARC references that
    // can deallocate another header in the same snapshot, and the lists are
    // unretained, so a borrowed copy would be walked after it died.
    let all: [JeffJSGCObjectHeader] =
        (rt.gcObjects + rt.gcTmpObjects).map { $0.takeUnretainedValue() }
    for hdr in all {
        hdr.gcListIndex = -1
        hdr.ownerRuntime = nil
        guard hdr.gcObjType == .jsObject || hdr.gcObjType == .functionBytecode else { continue }
        let obj = unsafeBitCast(hdr, to: JeffJSObject.self)
        obj.propValues.removeAll()
        obj.propExtra.removeAll()
        obj.shape = nil
        obj.proto = nil
        obj.payload = .opaque(nil)
        obj.fbFast = nil
        obj.varRefsFast = []
        obj.arrowThisVal = nil
        obj._fastArrayValues = nil
        obj.storedProto = nil
        obj.storedCFunction = nil
        obj.firstWeakRef = nil
    }
    for hdr in all {
        guard hdr.gcObjType == .varRef else { continue }
        let vr = unsafeBitCast(hdr, to: JeffJSVarRef.self)
        vr.parentFrame = nil
        vr.slot = nil
        vr.value = .undefined
        vr.isDetached = false
    }
    for hdr in all {
        guard hdr.gcObjType == .shape else { continue }
        let shape = unsafeBitCast(hdr, to: JeffJSShape.self)
        shape.proto = nil
        shape.prop.removeAll()
        shape.enumKeyCache = nil
        shape.propHash.removeAll()
        shape.propCount = 0
        shape.propSize = 0
        shape.deletedPropCount = 0
        shape.propHashMask = 0
        shape.shapeHashNext = nil
    }
    rt.gcObjects.removeAll()
    rt.gcZeroRefCountObjects.removeAll()
    rt.gcTmpObjects.removeAll()
    rt.gcWeakRefMap.removeAll()
    rt.weakMapKeyRecords.removeAll()
}

/// Returns `true` if a value is eligible to be a WeakRef target.
/// In QuickJS only objects and non-private symbols qualify.
func weakrefIsTarget(_ v: JeffJSValue) -> Bool {
    if v.isObject {
        return true
    }
    if v.isSymbol {
        // Private symbols use the high bit as a flag in QuickJS.
        // For now, all symbols are considered valid targets.
        return true
    }
    return false
}

// MARK: - Low-level memory management

/// Allocate `size` bytes of zeroed memory, updating malloc accounting.
/// Returns `nil` if the malloc limit would be exceeded.
func jsMalloc(_ rt: JeffJSRuntime, _ size: Int) -> UnsafeMutableRawPointer? {
    guard size > 0 else { return nil }

    let state = rt.mallocState
    if state.mallocLimit > 0 &&
       state.mallocSize + size > state.mallocLimit {
        return nil
    }

    let ptr = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<UInt64>.alignment)
    ptr.initializeMemory(as: UInt8.self, repeating: 0, count: size)

    rt.mallocState.mallocSize += size
    rt.mallocState.mallocCount += 1

    return ptr
}

/// Free memory previously obtained from ``jsMalloc(_:_:)``.
/// `size` must match the original allocation size.
func jsFree(_ rt: JeffJSRuntime, _ ptr: UnsafeMutableRawPointer, size: Int) {
    ptr.deallocate()
    rt.mallocState.mallocSize -= size
    rt.mallocState.mallocCount -= 1
}

/// Reallocate memory, updating accounting.  If the new size is zero the
/// pointer is freed and `nil` is returned.
func jsRealloc(_ rt: JeffJSRuntime,
               _ ptr: UnsafeMutableRawPointer?,
               oldSize: Int,
               newSize: Int) -> UnsafeMutableRawPointer? {
    if newSize == 0 {
        if let ptr = ptr {
            jsFree(rt, ptr, size: oldSize)
        }
        return nil
    }

    let state = rt.mallocState
    let delta = newSize - oldSize
    if delta > 0 && state.mallocLimit > 0 &&
       state.mallocSize + delta > state.mallocLimit {
        return nil
    }

    let newPtr = UnsafeMutableRawPointer.allocate(byteCount: newSize, alignment: MemoryLayout<UInt64>.alignment)

    if let ptr = ptr {
        let copySize = min(oldSize, newSize)
        newPtr.copyMemory(from: ptr, byteCount: copySize)
        // Zero out newly added bytes, if any.
        if newSize > oldSize {
            let tail = newPtr.advanced(by: oldSize)
            tail.initializeMemory(as: UInt8.self, repeating: 0, count: newSize - oldSize)
        }
        ptr.deallocate()
    } else {
        newPtr.initializeMemory(as: UInt8.self, repeating: 0, count: newSize)
    }

    rt.mallocState.mallocSize += delta

    return newPtr
}
