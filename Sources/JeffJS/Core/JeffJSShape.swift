// JeffJSShape.swift
// JeffJS — 1:1 Swift port of QuickJS
//
// Shape / hidden class system.
// Shapes implement inline caching and property transition tracking,
// matching the design in quickjs.c (JS_PROP_*, JSShapeProperty, JSShape).

import Foundation

// NOTE: JeffJSPropertyFlags and JeffJSShapeProperty are now defined in JeffJSObject.swift.
// The duplicate definitions that were here have been removed.

// MARK: - JeffJSShape

/// Hidden class / shape, corresponding to `JSShape` in quickjs.c.
///
/// Shapes form a transition tree: adding a new property to an object creates a
/// child shape that extends the parent's property list by one slot.  The runtime
/// keeps a hash table of shapes so that identical transitions are shared.
///
/// In the C implementation the property-hash array is stored at a *negative*
/// offset from the shape pointer.  In Swift we store it as a normal array member
/// (`propHash`).
nonisolated final class JeffJSShape: JeffJSGCObjectHeader {

    // Sentinel value for an empty hash-chain link.
    static let noNext: UInt32 = 0xFFFF_FFFF

    // ---- identity / hashing ----

    /// True when this shape is inserted into the runtime's shape hash table.
    var isHashed: Bool = false
    /// An inline cache holds this shape (`JeffJSInlineCache.update*`). A private shape is
    /// grown in place only while no cache can have seen it: a cached entry keyed by its
    /// identity ("no own `p`, `p` is on the prototype", or a define_field transition from
    /// it) would go stale when an own property is appended to the same object. Likewise a
    /// delete / flag change (`prepareShapeUpdate`) moves an icCached private shape's tables
    /// to a fresh identity: an own-slot or holder entry would otherwise still match.
    /// (Declared next to isHashed so the two flags share padding.)
    var icCached = false
    /// The realm's lazy-payload stub shape (JeffJSLazyPayload.swift): no
    /// properties, never cached by an inline cache.
    var isLazySentinel = false

    /// Computed hash that summarises (proto, property-atoms, flags).
    var hash: UInt32 = 0

    /// Bitmask for the per-shape property hash table (`propHash`).
    /// Always of the form 2^n - 1.
    var propHashMask: UInt32 = 0

    // ---- property storage ----

    // 32-bit counters (perf/watch-object-size): with the two flags they pack
    // the shape into 112 bytes (was 136 -> a 160-byte malloc block).
    private var _propSize: Int32 = 0
    private var _propCount: Int32 = 0
    private var _deletedPropCount: Int32 = 0

    /// Number of allocated slots in `prop`.
    var propSize: Int {
        @inline(__always) get { Int(_propSize) }
        @inline(__always) set { _propSize = Int32(truncatingIfNeeded: newValue) }
    }

    /// Number of used slots (includes deleted entries).
    var propCount: Int {
        @inline(__always) get { Int(_propCount) }
        @inline(__always) set { _propCount = Int32(truncatingIfNeeded: newValue) }
    }

    /// Number of slots that represent deleted properties.
    var deletedPropCount: Int {
        @inline(__always) get { Int(_deletedPropCount) }
        @inline(__always) set { _deletedPropCount = Int32(truncatingIfNeeded: newValue) }
    }

    // ---- linkage ----

    /// Next shape in the same bucket of the runtime shape hash table.
    var shapeHashNext: JeffJSShape? = nil

    /// The prototype object that this shape was created for.
    /// The shape owns **one counted reference** to it (see
    /// `jeffJS_shapeSetProto`): taken by `createShape` / `cloneShapeRT` /
    /// the `obj.proto` setter, released by `freeShape`, marked by
    /// `markChildren`. Write it through `jeffJS_shapeSetProto`, never
    /// directly, or the count and the pointer stop agreeing.
    var proto: JeffJSObject? = nil

    // ---- inline property table ----

    /// Property descriptors, indexed [0 ..< propCount].
    var prop: [JeffJSShapeProperty] = []

    /// Separate property-name hash table.
    /// `propHash[hash(atom) & propHashMask]` gives the index of the first
    /// `JeffJSShapeProperty` in the chain; follow `hashNext` from there.
    var propHash: [UInt32] = []
    /// Own enumerable string keys in for-in order, built on first use and
    /// dropped by every in-place mutation of the property table (append,
    /// delete, flag change, compaction). Clones start without one.
    var enumKeyCache: JeffJSForInKeyList? = nil
    /// For a hashed transition shape, the shape it was created from by
    /// appending its last property. Its identity proves the property prefix
    /// matches, so findHashedShape compares one property instead of all of
    /// them (building an object with N keys used to be O(N^2); a 5000-key
    /// dictionary spent 70% of its time there). Hashed shapes are never
    /// evicted, so the strong reference is safe.
    var parent: JeffJSShape? = nil
    // MARK: - Initialisers

    init() {
        super.init(gcObjType: .shape)
    }

    /// Designated shape initialiser used by `createShape`.
    /// Pass hashSize=0 and propSize=0 for a zero-allocation empty shape.
    init(proto: JeffJSObject?, hashSize: Int, propSize: Int) {
        super.init(gcObjType: .shape)
        self.proto = proto
        self.propSize = propSize
        self.propCount = 0
        self.deletedPropCount = 0

        if propSize > 0 {
            self.prop = []
            self.prop.reserveCapacity(propSize)
        }

        if hashSize > 0 {
            let resolvedHashSize = max(hashSize, 1)
            self.propHashMask = UInt32(resolvedHashSize - 1)
            self.propHash = [UInt32](repeating: JeffJSShape.noNext, count: resolvedHashSize)
        }
        // else: prop=[] and propHash=[] (defaults), propHashMask=0
        // addShapeProperty will allocate on first property addition
    }
}

// MARK: - Prototype ownership
//
// **Shapes own their prototype, objects do not.** A shape holds exactly one
// counted reference to `shape.proto`, taken when the shape is created (or when
// its prototype is replaced) and given back by `freeShape`; `markChildren`
// marks it, so it is a real GC edge. `obj.storedProto` is an uncounted mirror
// of `obj.shape!.proto` kept for the prototype-chain walk — the object's
// reference is paid for by the owner count it holds on its shape, which
// `markObject` marks for the same reason.
//
// This is quickjs's model: `js_new_shape` does one `JS_DupValue(proto)` per
// shape, `js_free_shape` releases it, `JS_SetPrototypeInternal` re-shapes and
// swaps the reference, and `mark_children` reaches `sh->proto` through
// `js_shape_mark`. Before this, every *object* built with an explicit
// prototype took a reference that nothing ever released (`Object.create(p)`
// 100 000 times added 100 000 permanent counts to `p`), while `shape.proto`
// was an uncounted ARC alias — two half-models of the same edge, which is
// also where the `RegExp.prototype` shape bug (829f9b2) came from.

/// Install `newProto` as `shape`'s prototype, taking the single counted
/// reference a shape owns and releasing the one it held.
nonisolated func jeffJS_shapeSetProto(_ shape: JeffJSShape, _ newProto: JeffJSObject?) {
    newProto?.ensureLazyMaterialized()
    let old = shape.proto
    if old === newProto { return }
    if let p = newProto { _ = JeffJSValue.borrowedObject(p).dupValue() }
    shape.proto = newProto
    if let o = old { JeffJSValue.borrowedObject(o).freeValue() }
}

// MARK: - Shape creation / cloning

/// Create a new, empty shape for an object with the given prototype.
/// - Parameters:
///   - ctx: The JS context.
///   - proto: Prototype object (may be nil for `Object.create(null)`).
///   - hashSize: Must be a power of two (minimum 1).
///   - propSize: Number of property slots to pre-allocate.
nonisolated func createShape(_ ctx: JeffJSContext,
                 proto: JeffJSObject?,
                 hashSize: Int,
                 propSize: Int) -> JeffJSShape {
    let shape = JeffJSShape(proto: proto, hashSize: hashSize, propSize: propSize)
    // The shape owns its prototype (one count per shape, freed by freeShape).
    if let p = proto { _ = JeffJSValue.borrowedObject(p).dupValue() }
    shape.hash = shapeInitialHash(proto)
    addGCObject(ctx.rt, shape)
    return shape
}

/// Create a deep copy of `shape`, producing an independent shape with identical
/// properties but its own storage.  The clone is **not** inserted into the
/// runtime shape hash table.
nonisolated func cloneShape(_ ctx: JeffJSContext, _ shape: JeffJSShape) -> JeffJSShape {
    return cloneShapeRT(ctx.rt, shape)
}

/// A private shape's tables under a new identity (for an object whose shape an inline
/// cache holds): the arrays move, nothing is copied; the old shape is left empty for its
/// owner to release.
nonisolated func jeffJS_moveShapeTables(_ rt: JeffJSRuntime, _ shape: JeffJSShape) -> JeffJSShape {
    let s = JeffJSShape()
    if let p = shape.proto { _ = JeffJSValue.borrowedObject(p).dupValue() }   // one count per shape
    s.proto = shape.proto
    s.propSize = shape.propSize
    s.propCount = shape.propCount
    s.deletedPropCount = shape.deletedPropCount
    s.hash = shape.hash
    s.propHashMask = shape.propHashMask
    s.isHashed = false
    s.prop = shape.prop
    s.propHash = shape.propHash
    s.enumKeyCache = shape.enumKeyCache
    shape.prop = []
    shape.propHash = []
    shape.enumKeyCache = nil
    shape.propCount = 0
    shape.propSize = 0
    shape.deletedPropCount = 0
    shape.propHashMask = 0
    addGCObject(rt, s)
    return s
}

/// `cloneShape` for callers that only have the runtime (object proto setter).
nonisolated func cloneShapeRT(_ rt: JeffJSRuntime, _ shape: JeffJSShape) -> JeffJSShape {
    let s = JeffJSShape()
    // The clone is a second owner of the prototype: one count per shape.
    if let p = shape.proto { _ = JeffJSValue.borrowedObject(p).dupValue() }
    s.proto = shape.proto
    s.propSize = shape.propSize
    s.propCount = shape.propCount
    s.deletedPropCount = shape.deletedPropCount
    s.hash = shape.hash
    s.propHashMask = shape.propHashMask
    s.isHashed = false

    // Deep-copy property descriptors
    s.prop = shape.prop
    s.prop.reserveCapacity(shape.propSize)

    // Deep-copy hash table
    s.propHash = shape.propHash

    addGCObject(rt, s)
    return s
}

// MARK: - Shape sharing (hidden-class transitions)
//
// Objects start on a hashed "root" shape for their prototype and move along
// hashed transition shapes as properties are added, so every `{a, b}` literal
// (and every instance built by the same constructor) shares one shape. That
// is what lets the interpreter's inline caches hit across objects and turns
// object creation into one allocation instead of a shape + two arrays each.
//
// Ownership: `shape.refCount` counts the objects currently on the shape (plus
// any context-level cache that holds one deliberately), and `markObject` marks
// that edge, so a shape whose owners are all garbage is not mistaken for a
// root and its prototype collects with them.
// Hashed shapes stay alive in the runtime table even at zero owners while the
// program runs; a collection then sweeps them out (`jeffJS_evictHashedShapes`).
// Freeing one the moment its last owner goes would recycle its address under
// the inline caches, which compare shapes by pointer — but a *swept* one is
// safe, because every IC entry holds an ARC retain on the shapes it names
// (`JeffJSInlineCache`), so the allocation cannot be reused while an entry
// still points at it, and a swept shape leaves the table with `isHashed`
// false, which is the condition `jeffJS_icDefine` checks before it moves an
// object onto a transition target.
// Any in-place mutation other than appending a property (delete, flag
// change, prototype change) must go through `prepareShapeUpdate`, which gives
// the object a private copy first. Mirrors QuickJS `find_hashed_shape_proto`
// / `find_hashed_shape_prop` / `js_shape_prepare_update`.

/// Find the hashed empty shape for `proto`.
nonisolated func findHashedShapeProto(_ rt: JeffJSRuntime, _ proto: JeffJSObject?) -> JeffJSShape? {
    guard rt.shapeHashSize > 0 else { return nil }
    let h = shapeInitialHash(proto)
    var cur = rt.shapeHash[Int(h & UInt32(rt.shapeHashSize - 1))]
    while let s = cur {
        if s.hash == h, s.proto === proto, s.propCount == 0, s.deletedPropCount == 0 {
            return s
        }
        cur = s.shapeHashNext
    }
    return nil
}

/// The shape a new empty object with prototype `proto` should start on.
/// Returns a shape with one owner reference accounted for the caller.
nonisolated func jeffJS_rootShape(_ ctx: JeffJSContext, proto: JeffJSObject?) -> JeffJSShape {
    proto?.ensureLazyMaterialized()
    let rt = ctx.rt
    if let s = findHashedShapeProto(rt, proto) {
        s.refCount += 1
        return s
    }
    let s = createShape(ctx, proto: proto, hashSize: 0, propSize: 0)   // refCount 1
    if rt.shapeHashCount < JeffJSRuntime.maxHashedShapes {
        insertHashedShape(rt, s)
    }
    return s
}

/// Drop one owner reference from `shape`. Private shapes are freed at zero;
/// hashed shapes remain cached in the transition table.
nonisolated func jeffJS_leaveShape(_ rt: JeffJSRuntime, _ shape: JeffJSShape) {
    guard shape.refCount > 0 else { return }
    shape.refCount -= 1
    if shape.refCount == 0 && !shape.isHashed {
        freeGCObjectChildren(rt, shape)
    }
}

/// Append property `atom`/`flags` to `obj`'s shape and return its slot index.
/// On a hashed (shared) shape this follows or creates a hashed transition;
/// on a private shape it appends in place.
@discardableResult
nonisolated func jeffJS_objectAddShapeProperty(_ ctx: JeffJSContext,
                                   _ obj: JeffJSObject,
                                   atom: UInt32,
                                   flags: UInt32) -> Int {
    guard let shape = obj.shape else { return -1 }
    guard shape.isHashed else {
        // A private shape grows in place, unless another object is on it (a copy) or an
        // inline cache knows it (a fresh identity that takes over the tables, no copy).
        if shape.refCount > 1 || shape.icCached {
            let rt = ctx.rt
            let ns = shape.refCount > 1 ? cloneShape(ctx, shape) : jeffJS_moveShapeTables(rt, shape)
            obj.shape = ns
            jeffJS_leaveShape(rt, shape)
            return addShapeProperty(ctx, ns, atom: atom, flags: flags)
        }
        return addShapeProperty(ctx, shape, atom: atom, flags: flags)
    }
    let rt = ctx.rt
    if let next = findHashedShape(rt, shape, atom: atom, propFlags: flags) {
        next.refCount += 1
        obj.shape = next
        jeffJS_leaveShape(rt, shape)
        return next.propCount - 1
    }
    let ns = cloneShape(ctx, shape)                       // private copy, refCount 1
    let idx = addShapeProperty(ctx, ns, atom: atom, flags: flags)
    let maxProps = JeffJSConfig.shapesMaxHashedProps
    if rt.shapeHashCount < JeffJSRuntime.maxHashedShapes, maxProps <= 0 || ns.propCount <= maxProps {
        ns.parent = shape
        insertHashedShape(rt, ns)                         // becomes the shared transition
    }
    obj.shape = ns
    jeffJS_leaveShape(rt, shape)
    return idx
}

// MARK: - Property lookup

/// Lookup a property by atom in a shape's property hash table.
/// - Returns: The property index into `shape.prop`, or `nil` if not found.
nonisolated func findShapeProperty(_ shape: JeffJSShape, _ atom: UInt32) -> Int? {
    guard shape.propCount > 0, !shape.prop.isEmpty, !shape.propHash.isEmpty else { return nil }

    let h = Int(atom & shape.propHashMask)
    guard h < shape.propHash.count else { return nil }
    var idx = shape.propHash[h]

    while idx != JeffJSShape.noNext {
        let i = Int(idx)
        guard i >= 0, i < shape.prop.count else { break }
        let sp = shape.prop[i]
        if sp.atom == atom {
            return i
        }
        idx = sp.hashNext
    }
    return nil
}

// MARK: - Property addition / removal

/// Add a new property slot to `shape`, growing storage if necessary.
/// The caller must have already ensured the shape is writable (via
/// ``prepareShapeUpdate(_:_:)``).
///
/// - Returns: The index of the newly added property.
@discardableResult
nonisolated func addShapeProperty(_ ctx: JeffJSContext,
                      _ shape: JeffJSShape,
                      atom: UInt32,
                      flags: UInt32) -> Int {
    // Defensive resync: a stale/freed shape can reach here with bookkeeping
    // that disagrees with its arrays. Re-deriving propCount from the array
    // turns a would-be out-of-bounds crash into a recoverable state.
    if shape.propCount != shape.prop.count {
        shape.propCount = shape.prop.count
    }

    // Lazy-init hash table on first property (shapes created with hashSize=0 start empty)
    if shape.propHash.isEmpty {
        let initialHashSize = JS_PROP_INITIAL_HASH_SIZE  // 4
        shape.propHashMask = UInt32(initialHashSize - 1)
        shape.propHash = [UInt32](repeating: JeffJSShape.noNext, count: initialHashSize)
        shape.propSize = JS_PROP_INITIAL_SIZE  // 2
        shape.prop.reserveCapacity(shape.propSize)
    }

    // Grow property array if full
    if shape.propCount >= shape.propSize {
        let newSize = max(shape.propSize * 2, 4)
        shape.prop.reserveCapacity(newSize)
        shape.propSize = newSize
    }

    // Rehash if load factor > 2  (propCount > 2 * hashTableSize)
    let hashTableSize = Int(shape.propHashMask) + 1
    if shape.propCount >= hashTableSize * 2 {
        reshapePropertyHash(shape, newBits: hashTableSize * 2)
    }

    // Insert into hash chain
    let h = Int(atom & shape.propHashMask)
    guard h < shape.propHash.count else { return shape.propCount }
    let newIndex = shape.propCount

    // The shape takes ownership of a reference to the atom.
    // Dup it so the caller can still free their own ref (matching QuickJS's
    // add_shape_property which calls JS_DupAtom).
    _ = ctx.rt.dupAtom(atom)
    var sp = JeffJSShapeProperty(atom: atom, flags: JeffJSPropertyFlags(rawValue: flags))
    sp.hashNext = shape.propHash[h]
    shape.prop.append(sp)

    shape.propHash[h] = UInt32(newIndex)

    // Update hash for the shape (used by runtime shape hash table)
    shape.hash = shapeHash(shape.hash, atom)
    shape.hash = shapeHash(shape.hash, flags)

    shape.propCount += 1
    shape.enumKeyCache = nil
    return newIndex
}

/// Mark property at `propertyIndex` as deleted.  The slot is not physically
/// removed; instead its atom is set to 0 and the deleted count is incremented.
nonisolated func removeShapeProperty(_ ctx: JeffJSContext,
                         _ shape: JeffJSShape,
                         propertyIndex: Int) {
    guard propertyIndex >= 0, propertyIndex < shape.prop.count else { return }

    let atom = shape.prop[propertyIndex].atom

    // Remove from hash chain
    let h = Int(atom & shape.propHashMask)
    guard h < shape.propHash.count else { return }
    var prevIdx: Int? = nil
    var idx = shape.propHash[h]
    while idx != JeffJSShape.noNext {
        let i = Int(idx)
        guard i >= 0, i < shape.prop.count else { break }
        if i == propertyIndex {
            if let p = prevIdx, p < shape.prop.count {
                shape.prop[p].hashNext = shape.prop[i].hashNext
            } else {
                shape.propHash[h] = shape.prop[i].hashNext
            }
            break
        }
        prevIdx = i
        idx = shape.prop[i].hashNext
    }

    // Blank out the slot
    shape.prop[propertyIndex].atom = 0        // JS_ATOM_NULL
    shape.prop[propertyIndex].hashNext = JeffJSShape.noNext
    shape.deletedPropCount += 1
    shape.enumKeyCache = nil
}

/// Compact a shape's property list by removing deleted entries and
/// re-indexing the owning object's property values array to match.
nonisolated func compactProperties(_ ctx: JeffJSContext, _ obj: JeffJSObject) {
    guard let shape = obj.shape else { return }
    guard shape.deletedPropCount > 0 else { return }

    let liveCount = shape.propCount - shape.deletedPropCount

    var newProps: [JeffJSShapeProperty] = []
    newProps.reserveCapacity(liveCount)

    var newValues: [JeffJSProperty] = []
    newValues.reserveCapacity(liveCount)

    // Mapping: old index -> new index (only for live slots)
    for i in 0 ..< shape.propCount {
        if shape.prop[i].atom != 0 {
            var sp = shape.prop[i]
            sp.hashNext = JeffJSShape.noNext  // will be rebuilt
            newProps.append(sp)
            if i < obj.propValues.count {
                newValues.append(obj.propEntry(at: i))
            }
        }
    }

    shape.prop = newProps
    shape.propCount = liveCount
    shape.propSize = liveCount
    shape.deletedPropCount = 0
    shape.enumKeyCache = nil
    obj.replaceProps(newValues)

    // Rebuild hash table
    let hashSize = nextPowerOfTwo(liveCount)
    shape.propHashMask = UInt32(hashSize - 1)
    shape.propHash = [UInt32](repeating: JeffJSShape.noNext, count: hashSize)

    for i in 0 ..< shape.propCount {
        let h = Int(shape.prop[i].atom & shape.propHashMask)
        shape.prop[i].hashNext = shape.propHash[h]
        shape.propHash[h] = UInt32(i)
    }
}

// MARK: - Property hash table resize (per-shape)

/// Rebuild the per-shape property hash table with a new size.
nonisolated private func reshapePropertyHash(_ shape: JeffJSShape, newBits: Int) {
    let newSize = nextPowerOfTwo(newBits)
    shape.propHashMask = UInt32(newSize - 1)
    shape.propHash = [UInt32](repeating: JeffJSShape.noNext, count: newSize)

    for i in 0 ..< shape.propCount {
        guard shape.prop[i].atom != 0 else { continue }
        let h = Int(shape.prop[i].atom & shape.propHashMask)
        shape.prop[i].hashNext = shape.propHash[h]
        shape.propHash[h] = UInt32(i)
    }
}

// MARK: - Shape hash table operations (on Runtime)

/// QuickJS's shape_hash: multiply-add with the magic constant 0x9e370001.
/// This is a Knuth multiplicative hash step.
nonisolated func shapeHash(_ h: UInt32, _ val: UInt32) -> UInt32 {
    return h &* 0x9e370001 &+ val
}

/// Compute the initial hash seed for a shape from its prototype.
/// Uses the object pointer identity converted to UInt32.
nonisolated func shapeInitialHash(_ proto: JeffJSObject?) -> UInt32 {
    guard let proto = proto else { return 0 }
    let bits = UInt(bitPattern: ObjectIdentifier(proto))
    // Fold 64-bit pointer into 32 bits
    let lo = UInt32(truncatingIfNeeded: bits)
    let hi = UInt32(truncatingIfNeeded: bits >> 32)
    return shapeHash(lo, hi)
}

/// Search the runtime shape hash table for a shape that extends `baseShape`
/// with one additional property (`atom` + `propFlags`).
///
/// This enables shape-transition sharing: if object A already went through
/// the same transition, we reuse its shape rather than creating a new one.
nonisolated func findHashedShape(_ rt: JeffJSRuntime,
                     _ baseShape: JeffJSShape,
                     atom: UInt32,
                     propFlags: UInt32) -> JeffJSShape? {
    guard rt.shapeHashSize > 0 else { return nil }
    // The target hash is the base shape's hash extended with the new property.
    var h = baseShape.hash
    h = shapeHash(h, atom)
    h = shapeHash(h, propFlags)
    let idx = Int(h & UInt32(rt.shapeHashSize - 1))
    // The chain through unretained handles: `while let shape = cur` retained
    // and released every shape visited (two pairs per property add on the
    // deepmerge bench).
    let baseProto = unsafeBitCast(baseShape.proto, to: UnsafeRawPointer?.self)
    let baseU = Unmanaged.passUnretained(baseShape)
    var curU = unsafeBitCast(rt.shapeHash[idx], to: UnsafeRawPointer?.self).map { Unmanaged<JeffJSShape>.fromOpaque($0) }
    while let u = curU {
        let (found, next): (Bool, Unmanaged<JeffJSShape>?) = u._withUnsafeGuaranteedRef { shape in
            let next = unsafeBitCast(shape.shapeHashNext, to: UnsafeRawPointer?.self).map { Unmanaged<JeffJSShape>.fromOpaque($0) }
            guard shape.hash == h,
                  unsafeBitCast(shape.proto, to: UnsafeRawPointer?.self) == baseProto,
                  shape.propCount == baseShape.propCount + 1 else { return (false, next) }
            let lastIdx = shape.propCount - 1
            let lastMatches = lastIdx < shape.prop.count &&
                shape.prop[lastIdx].atom == atom &&
                shape.prop[lastIdx].flags.rawValue == propFlags
            if let pb = unsafeBitCast(shape.parent, to: UnsafeRawPointer?.self) {
                // A transition recorded from a base shape: the base's identity
                // proves the prefix, only the last property needs checking.
                return (pb == UnsafeRawPointer(baseU.toOpaque()) && lastMatches, next)
            } else if lastMatches {
                // No parent link (root or captured shapes): verify that the
                // first N-1 properties match baseShape.
                let baseCount = baseShape.propCount
                if baseCount <= shape.prop.count {
                    for i in 0 ..< baseCount {
                        if shape.prop[i].atom  != baseShape.prop[i].atom ||
                           shape.prop[i].flags != baseShape.prop[i].flags {
                            return (false, next)
                        }
                    }
                    return (true, next)
                }
            }
            return (false, next)
        }
        if found { return u.takeUnretainedValue() }
        curU = next
    }
    return nil
}

/// Insert `shape` into the runtime's shape hash table.
nonisolated func insertHashedShape(_ rt: JeffJSRuntime, _ shape: JeffJSShape) {
    if rt.shapeHashSize == 0 {
        resizeShapeHash(rt, newBits: 1)
    }

    // Grow if load factor > 1
    if rt.shapeHashCount >= rt.shapeHashSize {
        resizeShapeHash(rt, newBits: rt.shapeHashSize * 2)
    }

    let idx = Int(shape.hash & UInt32(rt.shapeHashSize - 1))
    shape.shapeHashNext = rt.shapeHash[idx]
    rt.shapeHash[idx] = shape
    shape.isHashed = true
    rt.shapeHashCount += 1
}

/// Remove `shape` from the runtime's shape hash table.
nonisolated func removeHashedShape(_ rt: JeffJSRuntime, _ shape: JeffJSShape) {
    guard shape.isHashed, rt.shapeHashSize > 0 else { return }

    let idx = Int(shape.hash & UInt32(rt.shapeHashSize - 1))
    var prev: JeffJSShape? = nil
    var cur = rt.shapeHash[idx]

    while let s = cur {
        if s === shape {
            if let p = prev {
                p.shapeHashNext = s.shapeHashNext
            } else {
                rt.shapeHash[idx] = s.shapeHashNext
            }
            shape.shapeHashNext = nil
            shape.isHashed = false
            rt.shapeHashCount -= 1
            return
        }
        prev = s
        cur = s.shapeHashNext
    }
}

/// Resize the runtime shape hash table to `newSize` buckets (must be power of 2).
nonisolated func resizeShapeHash(_ rt: JeffJSRuntime, newBits: Int) {
    let newSize = nextPowerOfTwo(max(newBits, 1))
    var newTable = [JeffJSShape?](repeating: nil, count: newSize)

    // Re-insert all existing shapes
    for i in 0 ..< rt.shapeHashSize {
        var cur = rt.shapeHash[i]
        while let shape = cur {
            let next = shape.shapeHashNext
            let bucket = Int(shape.hash & UInt32(newSize - 1))
            shape.shapeHashNext = newTable[bucket]
            newTable[bucket] = shape
            cur = next
        }
    }

    rt.shapeHash = newTable
    rt.shapeHashSize = newSize
}

// MARK: - Shape prepare update

/// Ensure that `obj`'s shape is writable before mutating it.
///
/// If the shape is hashed (shared via the transition table) it is removed from
/// the hash table and cloned so that the mutation does not affect other objects
/// that share the same shape.
///
/// If the shape's reference count is > 1 (shared by multiple objects) it is
/// cloned so each object gets its own copy.
nonisolated func prepareShapeUpdate(_ ctx: JeffJSContext, _ obj: JeffJSObject) {
    prepareShapeUpdateRT(ctx.rt, obj)
}

nonisolated func prepareShapeUpdateRT(_ rt: JeffJSRuntime, _ obj: JeffJSObject) {
    guard let shape = obj.shape else { return }
    // A hashed shape is shared by definition (other objects may sit on it or
    // reach it through transitions); a private shape with several owners is
    // shared too. Either way this object gets its own unhashed copy.
    if shape.isHashed || shape.refCount > 1 {
        let newShape = cloneShapeRT(rt, shape)   // refCount 1, unhashed
        obj.shape = newShape
        jeffJS_leaveShape(rt, shape)
    } else if shape.icCached {
        // A private shape an inline cache has keyed: an in-place delete or
        // flag change would keep its identity, so a cached own slot / holder
        // slot / `writable` bit would go on matching a property that is gone
        // or changed (core-js deletes and redefines String.prototype.replace:
        // `"x".replace` then read the deleted slot's undefined). Give the
        // object a fresh identity that takes over the tables, as an in-place
        // append does (`jeffJS_objectAddShapeProperty`).
        let ns = jeffJS_moveShapeTables(rt, shape)
        obj.shape = ns
        jeffJS_leaveShape(rt, shape)
    }
    // The caller is about to edit the property table in place.
    obj.shape?.enumKeyCache = nil
}

// MARK: - Utility

/// Round up to the nearest power of two (minimum 1).
nonisolated private func nextPowerOfTwo(_ n: Int) -> Int {
    guard n > 1 else { return 1 }
    // Subtract 1 so exact powers of two stay unchanged.
    var v = n - 1
    v |= v >> 1
    v |= v >> 2
    v |= v >> 4
    v |= v >> 8
    v |= v >> 16
    return v + 1
}

// NOTE: Forward-declared type stubs (JeffJSGCObjectType, JeffJSGCObjectHeader,
// JeffJSObject, JeffJSValue, JeffJSStringValue, JeffJSContext, JeffJSRuntime)
// that were here have been removed. The canonical definitions now live in their
// own files under JeffJS/Core/.
