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
final class JeffJSShape: JeffJSGCObjectHeader {

    // Sentinel value for an empty hash-chain link.
    static let noNext: UInt32 = 0xFFFF_FFFF

    // ---- identity / hashing ----

    /// True when this shape is inserted into the runtime's shape hash table.
    var isHashed: Bool = false

    /// Computed hash that summarises (proto, property-atoms, flags).
    var hash: UInt32 = 0

    /// Bitmask for the per-shape property hash table (`propHash`).
    /// Always of the form 2^n - 1.
    var propHashMask: UInt32 = 0

    // ---- property storage ----

    /// Number of allocated slots in `prop`.
    var propSize: Int = 0

    /// Number of used slots (includes deleted entries).
    var propCount: Int = 0

    /// Number of slots that represent deleted properties.
    var deletedPropCount: Int = 0

    // ---- linkage ----

    /// Next shape in the same bucket of the runtime shape hash table.
    var shapeHashNext: JeffJSShape? = nil

    /// The prototype object that this shape was created for.
    /// Strong reference — shapes must keep their proto alive for GC correctness.
    var proto: JeffJSObject? = nil

    // ---- inline property table ----

    /// Property descriptors, indexed [0 ..< propCount].
    var prop: [JeffJSShapeProperty] = []

    /// Separate property-name hash table.
    /// `propHash[hash(atom) & propHashMask]` gives the index of the first
    /// `JeffJSShapeProperty` in the chain; follow `hashNext` from there.
    var propHash: [UInt32] = []

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

// MARK: - Shape creation / cloning

/// Create a new, empty shape for an object with the given prototype.
/// - Parameters:
///   - ctx: The JS context.
///   - proto: Prototype object (may be nil for `Object.create(null)`).
///   - hashSize: Must be a power of two (minimum 1).
///   - propSize: Number of property slots to pre-allocate.
func createShape(_ ctx: JeffJSContext,
                 proto: JeffJSObject?,
                 hashSize: Int,
                 propSize: Int) -> JeffJSShape {
    let shape = JeffJSShape(proto: proto, hashSize: hashSize, propSize: propSize)
    shape.hash = shapeInitialHash(proto)
    addGCObject(ctx.rt, shape)
    return shape
}

/// Create a deep copy of `shape`, producing an independent shape with identical
/// properties but its own storage.  The clone is **not** inserted into the
/// runtime shape hash table.
func cloneShape(_ ctx: JeffJSContext, _ shape: JeffJSShape) -> JeffJSShape {
    let s = JeffJSShape()
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

    addGCObject(ctx.rt, s)
    return s
}

// MARK: - Property lookup

/// Lookup a property by atom in a shape's property hash table.
/// - Returns: The property index into `shape.prop`, or `nil` if not found.
func findShapeProperty(_ shape: JeffJSShape, _ atom: UInt32) -> Int? {
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
func addShapeProperty(_ ctx: JeffJSContext,
                      _ shape: JeffJSShape,
                      atom: UInt32,
                      flags: UInt32) -> Int {

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
    return newIndex
}

/// Mark property at `propertyIndex` as deleted.  The slot is not physically
/// removed; instead its atom is set to 0 and the deleted count is incremented.
func removeShapeProperty(_ ctx: JeffJSContext,
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
}

/// Compact a shape's property list by removing deleted entries and
/// re-indexing the owning object's property values array to match.
func compactProperties(_ ctx: JeffJSContext, _ obj: JeffJSObject) {
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
            if i < obj.prop.count {
                newValues.append(obj.prop[i])
            }
        }
    }

    shape.prop = newProps
    shape.propCount = liveCount
    shape.propSize = liveCount
    shape.deletedPropCount = 0
    obj.prop = newValues

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
private func reshapePropertyHash(_ shape: JeffJSShape, newBits: Int) {
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
func shapeHash(_ h: UInt32, _ val: UInt32) -> UInt32 {
    return h &* 0x9e370001 &+ val
}

/// Compute the initial hash seed for a shape from its prototype.
/// Uses the object pointer identity converted to UInt32.
func shapeInitialHash(_ proto: JeffJSObject?) -> UInt32 {
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
func findHashedShape(_ rt: JeffJSRuntime,
                     _ baseShape: JeffJSShape,
                     atom: UInt32,
                     propFlags: UInt32) -> JeffJSShape? {
    guard rt.shapeHashSize > 0 else { return nil }

    // The target hash is the base shape's hash extended with the new property.
    var h = baseShape.hash
    h = shapeHash(h, atom)
    h = shapeHash(h, propFlags)

    let idx = Int(h & UInt32(rt.shapeHashSize - 1))
    var cur = rt.shapeHash[idx]

    while let shape = cur {
        if shape.hash == h,
           shape.proto === baseShape.proto,
           shape.propCount == baseShape.propCount + 1 {

            // Verify that the first N-1 properties match baseShape
            var matches = true
            let baseCount = baseShape.propCount
            if baseCount <= shape.propCount {
                for i in 0 ..< baseCount {
                    if shape.prop[i].atom  != baseShape.prop[i].atom ||
                       shape.prop[i].flags != baseShape.prop[i].flags {
                        matches = false
                        break
                    }
                }
            } else {
                matches = false
            }

            // Verify the new (last) property matches
            if matches {
                let lastIdx = shape.propCount - 1
                if shape.prop[lastIdx].atom == atom &&
                   shape.prop[lastIdx].flags.rawValue == propFlags {
                    return shape
                }
            }
        }
        cur = shape.shapeHashNext
    }
    return nil
}

/// Insert `shape` into the runtime's shape hash table.
func insertHashedShape(_ rt: JeffJSRuntime, _ shape: JeffJSShape) {
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
func removeHashedShape(_ rt: JeffJSRuntime, _ shape: JeffJSShape) {
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
func resizeShapeHash(_ rt: JeffJSRuntime, newBits: Int) {
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
func prepareShapeUpdate(_ ctx: JeffJSContext, _ obj: JeffJSObject) {
    guard let shape = obj.shape else { return }

    // Un-hash if necessary
    if shape.isHashed {
        removeHashedShape(ctx.rt, shape)
    }

    // Clone if shared
    if shape.refCount > 1 {
        let newShape = cloneShape(ctx, shape)
        shape.refCount -= 1
        obj.shape = newShape
        newShape.refCount = 1
    }
}

// MARK: - Utility

/// Round up to the nearest power of two (minimum 1).
private func nextPowerOfTwo(_ n: Int) -> Int {
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
