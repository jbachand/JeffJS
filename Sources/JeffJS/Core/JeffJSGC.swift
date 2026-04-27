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

    /// True while the target is still alive.
    var isLive: Bool { target != nil }

    init(target: JeffJSObject) {
        self.target = target
    }
}

// MARK: - GC object list management

/// Approximate byte cost of a single GC-tracked object (object + shape + props).
private let JS_GC_OBJ_COST = JeffJSConfig.gcObjectCost

/// Append `header` to the runtime's main GC object list.
/// Called every time a new GC-managed object is created.
func addGCObject(_ rt: JeffJSRuntime, _ header: JeffJSGCObjectHeader) {
    rt.gcObjects.append(header)
    header.mark = JeffJSGCMark.white
    header.ownerRuntime = rt
    // Track allocation size for GC threshold (actual collection deferred to safe points)
    rt.mallocState.mallocSize += JS_GC_OBJ_COST
    rt.mallocState.mallocCount += 1
}

/// Remove `header` from whichever GC tracking list it is on.
func removeGCObject(_ rt: JeffJSRuntime, _ header: JeffJSGCObjectHeader) {
    if let idx = rt.gcObjects.firstIndex(where: { $0 === header }) {
        rt.gcObjects.remove(at: idx)
        rt.mallocState.mallocSize -= JS_GC_OBJ_COST
        rt.mallocState.mallocCount -= 1
        return
    }
    if let idx = rt.gcTmpObjects.firstIndex(where: { $0 === header }) {
        rt.gcTmpObjects.remove(at: idx)
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

/// Internal free.  Decrements the ref count of a heap value and, if it
/// reaches zero, either frees it immediately (outside of GC) or enqueues
/// it on the zero-refcount list (during GC).
func freeValueRT(_ rt: JeffJSRuntime, _ v: JeffJSValue) {
    // GC-tracked objects (JeffJSObject, JeffJSShape, JeffJSVarRef, JeffJSBigInt)
    if let hdr = v.toGCObjectHeader() {
        guard hdr.refCount > 0 else { return } // already freed or being freed

        hdr.refCount -= 1

        if hdr.refCount == 0 {
            if rt.gcPhase != .JS_GC_PHASE_NONE || rt.inFreeChain {
                // GC is running or we're inside a recursive free chain — defer.
                rt.gcZeroRefCountObjects.append(hdr)
            } else {
                // Two-phase free: first process all children (decrement their
                // refcounts, collect more zero-ref objects), then release ARC
                // retains in a batch. This prevents use-after-free when cyclic
                // objects reference each other.
                rt.inFreeChain = true
                var toRelease: [JeffJSGCObjectHeader] = []

                // Phase 1: Process children (freeObject/freeShape/etc nil out refs)
                freeGCObjectChildren(rt, hdr)
                toRelease.append(hdr)

                // Drain deferred zero-ref objects iteratively
                while !rt.gcZeroRefCountObjects.isEmpty {
                    let deferred = rt.gcZeroRefCountObjects.removeFirst()
                    if deferred.refCount == 0 {
                        freeGCObjectChildren(rt, deferred)
                        toRelease.append(deferred)
                    }
                }
                rt.inFreeChain = false

                // Phase 2: Release ARC retains (may deallocate objects).
                // Safe because all child references have been nil'd out.
                for obj in toRelease {
                    Unmanaged.passUnretained(obj).release()
                }
            }
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
    #if canImport(Metal)
    if JeffJSMetalGC.shared.shouldUseMetalGC(objectCount: rt.gcObjects.count) {
        JeffJSMetalGC.shared.runMetalGC(rt: rt)
        freeZeroRefcount(rt)
        pruneWeakRefs(rt)
        rt.mallocGCThreshold = max(rt.mallocState.mallocSize * 2, 256 * 1024)
        return
    }
    #endif

    // Phase 1: trial decrements
    rt.gcPhase = .JS_GC_PHASE_DECREF
    gcDecref(rt)

    // Phase 2: scan / rescue
    gcScan(rt)

    // Phase 3: free unreachable cycles
    rt.gcPhase = .JS_GC_PHASE_REMOVE_CYCLES
    gcFreeCycles(rt)

    rt.gcPhase = .JS_GC_PHASE_NONE

    // Drain objects that hit zero during the collection.
    freeZeroRefcount(rt)

    // Prune dead weak references
    pruneWeakRefs(rt)

    // Adjust threshold: next GC when allocation doubles.
    rt.mallocGCThreshold = max(rt.mallocState.mallocSize * 2, 256 * 1024)
}

// MARK: - Phase 1: Trial deletion (gcDecref)

/// Walk all GC objects and perform a trial decrement of every child reference.
/// After this pass, an object whose effective refcount is zero is *probably*
/// garbage (it might still be rescued in Phase 2).
private func gcDecref(_ rt: JeffJSRuntime) {
    for hdr in rt.gcObjects {
        hdr.mark = JeffJSGCMark.white
        markChildren(rt, hdr) { rt, child in
            gcDecrefChild(rt, child)
        }
    }
}

/// Called for every child of an object during Phase 1.
/// Decrements the child's refcount (trial deletion).
/// Guard against objects already at zero (freed via freeValue but still in GC list).
func gcDecrefChild(_ rt: JeffJSRuntime, _ header: JeffJSGCObjectHeader) {
    guard header.refCount > 0 else { return }
    header.refCount -= 1
}

// MARK: - Phase 2: Scan / rescue (gcScan)

/// Walk all GC objects.  Any object whose refcount is still > 0 after trial
/// deletion is externally reachable — "rescue" it and all of its children
/// by restoring their reference counts and marking them black.
private func gcScan(_ rt: JeffJSRuntime) {
    for hdr in rt.gcObjects {
        if hdr.refCount > 0 {
            // Externally reachable — rescue
            hdr.mark = JeffJSGCMark.black
            markChildren(rt, hdr) { rt, child in
                gcScanIncrefChild(rt, child)
            }
        }
    }
}

/// Recursively rescue a child: restore its refcount and, if this is the
/// first rescue (mark transitions white -> black), recurse into its children.
func gcScanIncrefChild(_ rt: JeffJSRuntime, _ header: JeffJSGCObjectHeader) {
    header.refCount += 1
    if header.mark == JeffJSGCMark.white {
        header.mark = JeffJSGCMark.black
        markChildren(rt, header) { rt, child in
            gcScanIncrefChild(rt, child)
        }
    }
}

// MARK: - Phase 3: Free cycles (gcFreeCycles)

/// Any object still marked white after scanning is part of an unreachable
/// cycle — move it to the temporary list and then free everything on that list.
private func gcFreeCycles(_ rt: JeffJSRuntime) {
    // Move white objects to tmp list, keep black objects
    rt.gcTmpObjects.removeAll()
    var remaining: [JeffJSGCObjectHeader] = []
    for hdr in rt.gcObjects {
        if hdr.mark == JeffJSGCMark.white {
            rt.gcTmpObjects.append(hdr)
        } else {
            remaining.append(hdr)
        }
    }
    rt.gcObjects = remaining

    // Free everything on the tmp list.
    // We must be careful: freeing an object might remove other objects from the
    // tmp list via child decrements that hit zero.
    while !rt.gcTmpObjects.isEmpty {
        let hdr = rt.gcTmpObjects.removeFirst()
        // Set refcount to 1 so that freeGCObject does not try to re-enqueue.
        hdr.refCount = 1
        freeGCObject(rt, hdr)
    }
}

// MARK: - GC trigger

/// Check if the allocation watermark has crossed the GC threshold.
/// If so, run a full collection.
func triggerGC(_ rt: JeffJSRuntime, size: Int) {
    rt.mallocState.mallocSize += size
    if rt.mallocState.mallocSize >= rt.mallocGCThreshold {
        runGC(rt)
    }
}

// MARK: - Mark function dispatch

/// Visitor callback type.
typealias JeffJSMarkFunc = (_ rt: JeffJSRuntime, _ child: JeffJSGCObjectHeader) -> Void

/// Enumerate all GC-managed children of `header`, calling `markFunc` for each.
/// This dispatches on the object's ``JSGCObjectTypeEnum``.
func markChildren(_ rt: JeffJSRuntime,
                  _ header: JeffJSGCObjectHeader,
                  _ markFunc: JeffJSMarkFunc) {
    switch header.gcObjType {
    case .jsObject:
        let obj = unsafeBitCast(header, to: JeffJSObject.self)
        markObject(rt, obj, markFunc)
    case .shape:
        let shape = unsafeBitCast(header, to: JeffJSShape.self)
        markShape(rt, shape, markFunc)
    case .functionBytecode:
        // Mark constant pool values and closure var refs in bytecode.
        let obj = unsafeBitCast(header, to: JeffJSObject.self)
        if case .bytecodeFunc(let fb, let varRefs, _) = obj.payload, let fb = fb {
            // Mark constant pool entries
            for cpVal in fb.cpool {
                if let child = cpVal.toGCObjectHeader() {
                    markFunc(rt, child)
                }
            }
            // Mark closure variable references
            for vr in varRefs {
                if let vr = vr {
                    markFunc(rt, vr)
                }
            }
        }
    case .varRef:
        // Mark the value stored in the var-ref.
        let vr = unsafeBitCast(header, to: JeffJSVarRef.self)
        if let child = vr.pvalue.toGCObjectHeader() {
            markFunc(rt, child)
        }
    case .bigInt, .bigFloat, .bigDecimal:
        // Leaf types — no children.
        break
    case .asyncFunction:
        // TODO: mark async function state.
        break
    case .mapIteratorData, .arrayIteratorData,
         .regexpStringIteratorData:
        // TODO: mark iterator state.
        break
    }
}

/// Mark all children of a JSObject.
func markObject(_ rt: JeffJSRuntime,
                _ obj: JeffJSObject,
                _ markFunc: JeffJSMarkFunc) {
    // 1. Shape
    if let shape = obj.shape {
        markFunc(rt, shape)
    }

    // 2. Prototype (obj.proto is the single source of truth)
    if let proto = obj.proto {
        markFunc(rt, proto)
    }

    // 3. Property values
    for propEntry in obj.prop {
        switch propEntry {
        case .value(let val):
            if let child = val.toGCObjectHeader() {
                markFunc(rt, child)
            }
        case .getset(let getter, let setter):
            if let g = getter { markFunc(rt, g) }
            if let s = setter { markFunc(rt, s) }
        case .varRef(let vr):
            markFunc(rt, vr)
        case .autoInit:
            break
        }
    }

    // 4. Payload — mark reachable children in object payload
    switch obj.payload {
    case .bytecodeFunc(let fb, let varRefs, let homeObject):
        if let fb = fb {
            for cpVal in fb.cpool {
                if let child = cpVal.toGCObjectHeader() { markFunc(rt, child) }
            }
        }
        for vr in varRefs {
            if let vr = vr { markFunc(rt, vr) }
        }
        if let ho = homeObject { markFunc(rt, ho) }
    case .array(_, let values, let count):
        for i in 0..<Int(count) where i < values.count {
            if let child = values[i].toGCObjectHeader() { markFunc(rt, child) }
        }
    case .boundFunction(let bf):
        if let child = bf.thisVal.toGCObjectHeader() { markFunc(rt, child) }
        if let child = bf.funcObj.toGCObjectHeader() { markFunc(rt, child) }
        for arg in bf.argv {
            if let child = arg.toGCObjectHeader() { markFunc(rt, child) }
        }
    case .proxyData(let pd):
        if let child = pd.target.toGCObjectHeader() { markFunc(rt, child) }
        if let child = pd.handler.toGCObjectHeader() { markFunc(rt, child) }
    case .objectData(let val):
        if let child = val.toGCObjectHeader() { markFunc(rt, child) }
    case .generatorData(let gd):
        // Mark async state's saved values
        if let child = gd.asyncState.thisVal.toGCObjectHeader() { markFunc(rt, child) }
        if let child = gd.asyncState.resolveFunc.toGCObjectHeader() { markFunc(rt, child) }
        if let child = gd.asyncState.rejectFunc.toGCObjectHeader() { markFunc(rt, child) }
    case .promiseData(let pd):
        if let child = pd.promiseResult.toGCObjectHeader() { markFunc(rt, child) }
        for reaction in pd.promiseFulfillReactions {
            if let child = reaction.handler.toGCObjectHeader() { markFunc(rt, child) }
            if let child = reaction.resolveFunc.toGCObjectHeader() { markFunc(rt, child) }
            if let child = reaction.rejectFunc.toGCObjectHeader() { markFunc(rt, child) }
        }
        for reaction in pd.promiseRejectReactions {
            if let child = reaction.handler.toGCObjectHeader() { markFunc(rt, child) }
            if let child = reaction.resolveFunc.toGCObjectHeader() { markFunc(rt, child) }
            if let child = reaction.rejectFunc.toGCObjectHeader() { markFunc(rt, child) }
        }
    default:
        break  // cFunc, regexp, mapState, asyncFunctionData, etc.
    }
}

/// Mark children of a Shape (just the prototype).
func markShape(_ rt: JeffJSRuntime,
               _ shape: JeffJSShape,
               _ markFunc: JeffJSMarkFunc) {
    if let proto = shape.proto {
        markFunc(rt, proto)
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
        rt.mallocState.mallocCount -= 1
    case .varRef:
        let vr = unsafeBitCast(header, to: JeffJSVarRef.self)
        if vr.isDetached {
            freeValue(rt, vr.value)
            vr.value = .undefined
        }
        rt.mallocState.mallocCount -= 1
    default:
        rt.mallocState.mallocCount -= 1
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
        Unmanaged.passUnretained(header).release()
    default:
        break // shapes, varRefs — ARC managed by strong property references
    }
}

/// Free a JSObject: release every property value, release the shape, then
/// let ARC reclaim the Swift object.
func freeObject(_ rt: JeffJSRuntime, _ obj: JeffJSObject) {
    // Capture and clear payload/properties FIRST, then free values.
    // This prevents re-entrant access to obj during cascading frees.
    let savedProps = obj.prop
    let savedPayload = obj.payload
    obj.prop = []
    obj.payload = .opaque(nil)

    // Release each property value.
    for propEntry in savedProps {
        switch propEntry {
        case .value(let val):
            freeValue(rt, val)
        case .getset(_, _):
            break  // ARC handles getter/setter object refs
        case .varRef(let vr):
            if vr.isDetached {
                freeValue(rt, vr.value)
                vr.value = .undefined
            }
        case .autoInit:
            break
        }
    }

    // Payload was already cleared to .opaque(nil) above.
    // The saved payload's Swift class references (JeffJSFunctionBytecode,
    // arrays, etc.) will be released by ARC when savedPayload goes out of scope.
    // Explicit cpool/varRef/element freeing is deferred until the full
    // QuickJS refcount discipline is implemented in all operator functions.
    _ = savedPayload  // ensure ARC release happens

    // Release shape — nil first (ARC -1), then process children if refCount=0.
    // Shapes are normal Swift objects (not NaN-boxed), so ARC manages their lifecycle.
    if let shape = obj.shape {
        obj.shape = nil  // ARC releases our strong ref
        shape.refCount -= 1
        if shape.refCount == 0 {
            freeGCObjectChildren(rt, shape)
            // No Unmanaged.release — shapes are ARC-managed.
            // ARC will deallocate when all strong refs (gcObjects, other obj.shape) go away.
        }
    }

    // Invalidate any weak references pointing at this object.
    weakrefFree(rt, obj)

    rt.mallocState.mallocCount -= 1
}

/// Free a Shape: remove from the runtime hash table if necessary, release the
/// prototype reference.
func freeShape(_ rt: JeffJSRuntime, _ shape: JeffJSShape) {
    if shape.isHashed {
        removeHashedShape(rt, shape)
    }

    // Shapes store protos as ARC strong refs, not NaN-boxed values.
    // Just nil the reference — ARC handles the release.
    shape.proto = nil

    shape.prop.removeAll()
    shape.propHash.removeAll()

    rt.mallocState.mallocCount -= 1
}

/// Drain the list of objects whose refcount dropped to zero during a GC
/// cycle.  Those objects were deferred because freeing inside the collector
/// could mutate the object graph while we are iterating it.
func freeZeroRefcount(_ rt: JeffJSRuntime) {
    while !rt.gcZeroRefCountObjects.isEmpty {
        let hdr = rt.gcZeroRefCountObjects.removeFirst()
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
    return ref
}

/// Release the weak reference associated with `target`.
/// Called when the target object is being freed.
func weakrefFree(_ rt: JeffJSRuntime, _ target: JeffJSObject) {
    let key = ObjectIdentifier(target)
    rt.gcWeakRefMap.removeValue(forKey: key)
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
    // Break reference cycles on all tracked objects so ARC can deallocate them.
    for hdr in rt.gcObjects {
        hdr.ownerRuntime = nil
        if hdr.gcObjType == .jsObject || hdr.gcObjType == .functionBytecode {
            let obj = unsafeBitCast(hdr, to: JeffJSObject.self)
            obj.prop.removeAll()
            obj.shape = nil
            obj.proto = nil
            obj.payload = .opaque(nil)
        }
        if hdr.gcObjType == .shape {
            let shape = unsafeBitCast(hdr, to: JeffJSShape.self)
            shape.proto = nil
            shape.prop.removeAll()
            shape.propHash.removeAll()
            shape.shapeHashNext = nil
        }
    }
    for hdr in rt.gcTmpObjects {
        hdr.ownerRuntime = nil
        if hdr.gcObjType == .jsObject || hdr.gcObjType == .functionBytecode {
            let obj = unsafeBitCast(hdr, to: JeffJSObject.self)
            obj.prop.removeAll()
            obj.shape = nil
            obj.proto = nil
            obj.payload = .opaque(nil)
        }
    }
    rt.gcObjects.removeAll()
    rt.gcZeroRefCountObjects.removeAll()
    rt.gcTmpObjects.removeAll()
    rt.gcWeakRefMap.removeAll()
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
