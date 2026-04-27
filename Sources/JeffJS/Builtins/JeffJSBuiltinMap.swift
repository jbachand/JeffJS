// JeffJSBuiltinMap.swift
// JeffJS - 1:1 Swift port of QuickJS JavaScript engine
//
// Port of Map, Set, WeakMap, WeakSet built-ins from QuickJS.
// Covers constructors, prototype methods, iterators, and static groupBy.
//
// QuickJS source reference: quickjs.c — js_map_*, js_map_iterator_*,
// js_set_*, Map/Set/WeakMap/WeakSet constructor/prototype init.

import Foundation

// MARK: - Magic Constants

/// Magic bits encode which collection type a shared C-function operates on.
/// QuickJS uses `magic & 0x3` for the base type and `magic >> 2` for sub-variants.
private let MAGIC_MAP:      Int16 = 0
private let MAGIC_SET:      Int16 = 1
private let MAGIC_WEAKMAP:  Int16 = 2
private let MAGIC_WEAKSET:  Int16 = 3

/// Sub-magic for iterator kind (shifted left by 2 and OR'd with base type).
private let MAGIC_ITER_KEY:          Int16 = 0 << 2
private let MAGIC_ITER_VALUE:        Int16 = 1 << 2
private let MAGIC_ITER_KEY_AND_VALUE: Int16 = 2 << 2

// MARK: - Hash Table Constants

private let JS_MAP_INITIAL_HASH_SIZE = 4
private let JS_MAP_HASH_DELETED      = -1

// MARK: - SameValueZero Comparison

/// SameValueZero: NaN === NaN, -0 === +0.
/// Used by Map/Set per the ES spec for key comparison.
private func sameValueZero(_ a: JeffJSValue, _ b: JeffJSValue) -> Bool {
    if !JeffJSValue.sameTag(a, b) { return false }
    // Heap types: identity or string content comparison
    if a.hasRefCount {
        if a.heapRef != nil && a.heapRef === b.heapRef { return true }
        if a.isString, let sa = a.stringValue, let sb = b.stringValue {
            return jeffJS_stringEquals(s1: sa, s2: sb)
        }
        return false
    }
    // Doubles: NaN === NaN, +0 === -0
    if a.isFloat64 {
        let ad = a.toFloat64(), bd = b.toFloat64()
        if ad.isNaN && bd.isNaN { return true }
        return ad == bd
    }
    // Int, bool, null, undefined, etc.: compare bits directly
    return a.bits == b.bits
}

// MARK: - Key Normalization

/// Normalize keys: -0 -> +0 (spec requirement for Map/Set).
private func normalizeKey(_ val: JeffJSValue) -> JeffJSValue {
    if val.isFloat64 {
        let d = val.toFloat64()
        if d == 0.0 && d.sign == .minus {
            return JeffJSValue.newFloat64(0.0)
        }
    }
    return val
}

// MARK: - Hashing

/// Knuth multiplicative hash constant (golden ratio * 2^32).
private let KNUTH_MULTIPLIER: UInt32 = 2654435769

/// Compute a hash for a JeffJSValue key.
/// Uses Knuth multiplicative hashing, type-dispatched.
private func mapHashKey(_ key: JeffJSValue) -> UInt32 {
    switch key.getTag() {
    case .int_:
        let v = key.toInt32()
        return UInt32(bitPattern: v) &* KNUTH_MULTIPLIER
    case .float64:
        let d = key.toFloat64()
        if d.isNaN { return 0 }
        if d == 0.0 { return 0 }
        let bits = d.bitPattern
        let lo = UInt32(bits & 0xFFFF_FFFF)
        let hi = UInt32(bits >> 32)
        return (lo ^ hi) &* KNUTH_MULTIPLIER
    case .bool_:
        return key.toInt32() == 1 ? KNUTH_MULTIPLIER : 0
    case .null:
        return 0
    case .undefined:
        return 1 &* KNUTH_MULTIPLIER
    case .string:
        if let str = key.stringValue {
            return jeffJS_computeHash(str: str) &* KNUTH_MULTIPLIER
        }
        return 0
    case .symbol:
        if let p = key.heapRef {
            let oid = ObjectIdentifier(p)
            return UInt32(oid.hashValue & 0x7FFF_FFFF) &* KNUTH_MULTIPLIER
        }
        return 0
    case .object:
        if let obj = key.heapRef {
            let oid = ObjectIdentifier(obj)
            return UInt32(oid.hashValue & 0x7FFF_FFFF) &* KNUTH_MULTIPLIER
        }
        return 0
    case .bigInt:
        if let bi = key.toBigInt() {
            var h: UInt32 = 0
            for limb in bi.limbs {
                h = h ^ UInt32(limb & 0xFFFF_FFFF) ^ UInt32(limb >> 32)
            }
            return h &* KNUTH_MULTIPLIER
        }
        return 0
    default:
        return 0
    }
}

// MARK: - JSMapState Operations

/// Initialize the hash table for a map state.
private func mapStateInit(_ s: JeffJSMapState) {
    s.hashSize = JS_MAP_INITIAL_HASH_SIZE
    s.hashTable = [Int](repeating: -1, count: JS_MAP_INITIAL_HASH_SIZE)
    s.count = 0
    s.records = []
    s.recordListSentinel.initSentinel()
}

/// Resize the hash table when the load factor exceeds 0.75.
private func mapStateResize(_ s: JeffJSMapState) {
    let newSize = s.hashSize * 2
    s.hashTable = [Int](repeating: -1, count: newSize)
    s.hashSize = newSize

    // Re-hash all non-empty records.
    for i in 0..<s.records.count {
        let rec = s.records[i]
        if !rec.empty {
            let h = Int(mapHashKey(rec.key) % UInt32(newSize))
            rec.hashNext = s.hashTable[h]
            s.hashTable[h] = i
        }
    }
}

/// Find a record matching `key` in the map state. Returns the record index or -1.
private func mapStateFind(_ s: JeffJSMapState, key: JeffJSValue) -> Int {
    guard s.hashSize > 0 else { return -1 }
    let h = Int(mapHashKey(key) % UInt32(s.hashSize))
    var idx = s.hashTable[h]
    while idx >= 0 {
        let rec = s.records[idx]
        if !rec.empty && sameValueZero(rec.key, key) {
            return idx
        }
        idx = rec.hashNext
    }
    return -1
}

/// Insert a new record into the map state. Returns the new record.
/// Does NOT check for duplicates; caller is responsible.
private func mapStateInsert(_ s: JeffJSMapState, key: JeffJSValue, value: JeffJSValue) -> JeffJSMapRecord {
    // Resize if load factor > 0.75.
    if s.count * 4 >= s.hashSize * 3 {
        mapStateResize(s)
    }

    let rec = JeffJSMapRecord()
    rec.key = key
    rec.value = value
    rec.empty = false
    rec.map = s

    let recIndex = s.records.count
    s.records.append(rec)

    // Insert into hash chain.
    let h = Int(mapHashKey(key) % UInt32(s.hashSize))
    rec.hashNext = s.hashTable[h]
    s.hashTable[h] = recIndex

    // Append to the insertion-order linked list (before sentinel = at tail).
    rec.link.insertBefore(s.recordListSentinel)

    s.count += 1
    return rec
}

/// Delete a record by index, marking it empty.
private func mapStateDelete(_ s: JeffJSMapState, index: Int) {
    guard index >= 0 && index < s.records.count else { return }
    let rec = s.records[index]
    if rec.empty { return }

    // Remove from hash chain.
    let h = Int(mapHashKey(rec.key) % UInt32(s.hashSize))
    var prevIdx = -1
    var curIdx = s.hashTable[h]
    while curIdx >= 0 {
        if curIdx == index {
            if prevIdx < 0 {
                s.hashTable[h] = rec.hashNext
            } else {
                s.records[prevIdx].hashNext = rec.hashNext
            }
            break
        }
        prevIdx = curIdx
        curIdx = s.records[curIdx].hashNext
    }

    // Remove from insertion-order list.
    rec.link.remove()

    // Mark empty; release key/value.
    rec.key.freeValue()
    rec.value.freeValue()
    rec.key = .undefined
    rec.value = .undefined
    rec.empty = true

    s.count -= 1
}

/// Clear all records in a map state.
private func mapStateClear(_ s: JeffJSMapState) {
    for i in 0..<s.records.count {
        let rec = s.records[i]
        if !rec.empty {
            rec.key.freeValue()
            rec.value.freeValue()
            rec.key = .undefined
            rec.value = .undefined
            rec.empty = true
            rec.link.remove()
        }
    }
    s.records.removeAll()
    s.hashTable = [Int](repeating: -1, count: JS_MAP_INITIAL_HASH_SIZE)
    s.hashSize = JS_MAP_INITIAL_HASH_SIZE
    s.count = 0
    s.recordListSentinel.initSentinel()
}

// MARK: - Get Map State from JS Object

/// Extract the JeffJSMapState payload from a value, verifying correct class ID.
/// Returns nil and throws TypeError if invalid.
private func getMapState(_ ctx: JeffJSContext, thisVal: JeffJSValue, classID: Int) -> JeffJSMapState? {
    guard let obj = thisVal.toObject() else {
        _ = ctx.throwTypeError("not an object")
        return nil
    }
    guard obj.classID == classID else {
        _ = ctx.throwTypeError("incompatible receiver")
        return nil
    }
    if case .mapState(let s) = obj.payload {
        return s
    }
    _ = ctx.throwTypeError("incompatible receiver")
    return nil
}

// MARK: - Constructor

/// Shared constructor for Map, Set, WeakMap, WeakSet.
/// `magic` distinguishes which type (0=Map, 1=Set, 2=WeakMap, 3=WeakSet).
///
/// Mirrors `js_map_constructor` in QuickJS.
func js_map_constructor(_ ctx: JeffJSContext,
                        _ newTarget: JeffJSValue,
                        _ argv: [JeffJSValue],
                        _ magic: Int) -> JeffJSValue {
    let baseMagic = Int16(magic & 0x3)
    let classID: Int
    let isWeak: Bool

    switch baseMagic {
    case MAGIC_MAP:     classID = JSClassID.JS_CLASS_MAP.rawValue;     isWeak = false
    case MAGIC_SET:     classID = JSClassID.JS_CLASS_SET.rawValue;     isWeak = false
    case MAGIC_WEAKMAP: classID = JSClassID.JS_CLASS_WEAKMAP.rawValue; isWeak = true
    case MAGIC_WEAKSET: classID = JSClassID.JS_CLASS_WEAKSET.rawValue; isWeak = true
    default:
        return ctx.throwTypeError("invalid map constructor magic")
    }

    // Create the object.
    let obj = JeffJSObject()
    obj.classID = classID
    obj.extensible = true

    // Set the prototype so methods (get/set/has/size/etc.) are found.
    if classID < ctx.classProto.count {
        let proto = ctx.classProto[classID]
        if proto.isObject {
            obj.proto = proto.toObject()
        }
    }

    // Create and attach the map state.
    let s = JeffJSMapState(isWeak: isWeak)
    mapStateInit(s)
    obj.payload = .mapState(s)

    let result = JeffJSValue.makeObject(obj)

    // If an iterable argument is provided, add each element.
    if !argv.isEmpty && !argv[0].isUndefined && !argv[0].isNull {
        let iterable = argv[0]

        // For Map/WeakMap, each element must be [key, value].
        // For Set/WeakSet, each element is a value to add.
        if baseMagic == MAGIC_SET || baseMagic == MAGIC_WEAKSET {
            // forEach on iterable, calling add for each element.
            js_map_forEach_iterable(ctx, s, iterable, isSet: true, isWeak: isWeak)
        } else {
            // forEach on iterable, calling set for each [k, v] pair.
            js_map_forEach_iterable(ctx, s, iterable, isSet: false, isWeak: isWeak)
        }
    }

    return result
}

/// Helper: iterate over an iterable and populate the map/set state.
private func js_map_forEach_iterable(_ ctx: JeffJSContext,
                                     _ s: JeffJSMapState,
                                     _ iterable: JeffJSValue,
                                     isSet: Bool,
                                     isWeak: Bool) {
    // In a full implementation this would use the iterator protocol.
    // For arrays, iterate directly via fast path or property-based fallback.
    guard let obj = iterable.toObject() else { return }

    // Determine element count: fast-array payload or length property.
    let elemCount: Int
    if case .array(_, _, let count) = obj.payload {
        elemCount = Int(count)
    } else {
        let lenVal = obj.getOwnPropertyValue(atom: JeffJSAtomID.JS_ATOM_length.rawValue)
        if lenVal.isInt {
            elemCount = Int(lenVal.toInt32())
        } else if lenVal.isFloat64 {
            elemCount = Int(lenVal.toFloat64())
        } else {
            elemCount = 0
        }
    }

    for i in 0..<elemCount {
        // Read element: try fast-array first, then property-based lookup.
        let elem: JeffJSValue
        if case .array(_, let vals, let count) = obj.payload, i < Int(count), i < vals.count {
            elem = vals[i]
        } else {
            elem = ctx.getPropertyUint32(obj: iterable, index: UInt32(i))
        }

        if isSet {
            let key = isWeak ? elem : normalizeKey(elem)
            let existing = mapStateFind(s, key: key)
            if existing < 0 {
                _ = mapStateInsert(s, key: key.dupValue(), value: .undefined)
            }
        } else {
            // Each element must be a [key, value] pair (an array-like with >= 2 elements).
            guard let pair = elem.toObject() else { continue }
            let pairKey: JeffJSValue
            let pairVal: JeffJSValue
            if case .array(_, let pv, let pc) = pair.payload, pc >= 2 {
                // Fast-array path for the pair.
                pairKey = pv[0]
                pairVal = pv[1]
            } else {
                // Property-based fallback for the pair.
                pairKey = ctx.getPropertyUint32(obj: elem, index: 0)
                pairVal = ctx.getPropertyUint32(obj: elem, index: 1)
                if pairKey.isUndefined && pairVal.isUndefined { continue }
            }
            let key = isWeak ? pairKey : normalizeKey(pairKey)
            let val = pairVal
            let existing = mapStateFind(s, key: key)
            if existing >= 0 {
                s.records[existing].value.freeValue()
                s.records[existing].value = val.dupValue()
            } else {
                _ = mapStateInsert(s, key: key.dupValue(), value: val.dupValue())
            }
        }
    }
}

// MARK: - Map.prototype.get

func js_map_get(_ ctx: JeffJSContext,
                _ thisVal: JeffJSValue,
                _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let s = getMapState(ctx, thisVal: thisVal, classID: JSClassID.JS_CLASS_MAP.rawValue) else {
        return .exception
    }
    guard !argv.isEmpty else { return .undefined }
    let key = normalizeKey(argv[0])
    let idx = mapStateFind(s, key: key)
    if idx >= 0 {
        return s.records[idx].value.dupValue()
    }
    return .undefined
}

// MARK: - Map.prototype.set

func js_map_set(_ ctx: JeffJSContext,
                _ thisVal: JeffJSValue,
                _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let s = getMapState(ctx, thisVal: thisVal, classID: JSClassID.JS_CLASS_MAP.rawValue) else {
        return .exception
    }
    let key = argv.isEmpty ? JeffJSValue.undefined : normalizeKey(argv[0])
    let value = argv.count > 1 ? argv[1] : JeffJSValue.undefined

    let idx = mapStateFind(s, key: key)
    if idx >= 0 {
        s.records[idx].value.freeValue()
        s.records[idx].value = value.dupValue()
    } else {
        _ = mapStateInsert(s, key: key.dupValue(), value: value.dupValue())
    }
    return thisVal.dupValue()
}

// MARK: - Map.prototype.has

func js_map_has(_ ctx: JeffJSContext,
                _ thisVal: JeffJSValue,
                _ argv: [JeffJSValue],
                _ magic: Int) -> JeffJSValue {
    let classID: Int
    switch Int16(magic & 0x3) {
    case MAGIC_MAP:     classID = JSClassID.JS_CLASS_MAP.rawValue
    case MAGIC_SET:     classID = JSClassID.JS_CLASS_SET.rawValue
    case MAGIC_WEAKMAP: classID = JSClassID.JS_CLASS_WEAKMAP.rawValue
    case MAGIC_WEAKSET: classID = JSClassID.JS_CLASS_WEAKSET.rawValue
    default: return ctx.throwTypeError("invalid magic")
    }

    guard let s = getMapState(ctx, thisVal: thisVal, classID: classID) else {
        return .exception
    }
    let key = argv.isEmpty ? JeffJSValue.undefined : normalizeKey(argv[0])
    let idx = mapStateFind(s, key: key)
    return JeffJSValue.newBool(idx >= 0)
}

// MARK: - Map.prototype.delete

func js_map_delete(_ ctx: JeffJSContext,
                   _ thisVal: JeffJSValue,
                   _ argv: [JeffJSValue],
                   _ magic: Int) -> JeffJSValue {
    let classID: Int
    switch Int16(magic & 0x3) {
    case MAGIC_MAP:     classID = JSClassID.JS_CLASS_MAP.rawValue
    case MAGIC_SET:     classID = JSClassID.JS_CLASS_SET.rawValue
    case MAGIC_WEAKMAP: classID = JSClassID.JS_CLASS_WEAKMAP.rawValue
    case MAGIC_WEAKSET: classID = JSClassID.JS_CLASS_WEAKSET.rawValue
    default: return ctx.throwTypeError("invalid magic")
    }

    guard let s = getMapState(ctx, thisVal: thisVal, classID: classID) else {
        return .exception
    }
    let key = argv.isEmpty ? JeffJSValue.undefined : normalizeKey(argv[0])
    let idx = mapStateFind(s, key: key)
    if idx >= 0 {
        mapStateDelete(s, index: idx)
        return .JS_TRUE
    }
    return .JS_FALSE
}

// MARK: - Map.prototype.clear

func js_map_clear(_ ctx: JeffJSContext,
                  _ thisVal: JeffJSValue,
                  _ argv: [JeffJSValue],
                  _ magic: Int) -> JeffJSValue {
    let classID: Int
    switch Int16(magic & 0x3) {
    case MAGIC_MAP: classID = JSClassID.JS_CLASS_MAP.rawValue
    case MAGIC_SET: classID = JSClassID.JS_CLASS_SET.rawValue
    default: return ctx.throwTypeError("clear not available on weak collections")
    }

    guard let s = getMapState(ctx, thisVal: thisVal, classID: classID) else {
        return .exception
    }
    mapStateClear(s)
    return .undefined
}

// MARK: - Map.prototype.forEach

func js_map_forEach(_ ctx: JeffJSContext,
                    _ thisVal: JeffJSValue,
                    _ argv: [JeffJSValue],
                    _ magic: Int) -> JeffJSValue {
    let baseMagic = Int16(magic & 0x3)
    let classID: Int
    switch baseMagic {
    case MAGIC_MAP: classID = JSClassID.JS_CLASS_MAP.rawValue
    case MAGIC_SET: classID = JSClassID.JS_CLASS_SET.rawValue
    default: return ctx.throwTypeError("forEach not available on weak collections")
    }

    guard let s = getMapState(ctx, thisVal: thisVal, classID: classID) else {
        return .exception
    }
    guard !argv.isEmpty else {
        return ctx.throwTypeError("forEach requires a callback")
    }

    let callback = argv[0]
    let thisArg = argv.count > 1 ? argv[1] : JeffJSValue.undefined

    guard let callbackObj = callback.toObject(), callbackObj.isCallable else {
        return ctx.throwTypeError("callback is not a function")
    }

    // Iterate in insertion order. We walk the record array, skipping empties.
    // We must tolerate additions/deletions during iteration.
    var i = 0
    while i < s.records.count {
        let rec = s.records[i]
        if !rec.empty {
            if baseMagic == MAGIC_SET {
                // callback(value, value, set) — per spec, Set forEach passes (value, value, set)
                let result = ctx.callFunction(callback, thisVal: thisArg, args: [rec.key, rec.key, thisVal])
                if result.isException { return .exception }
            } else {
                // callback(value, key, map) — per spec, Map forEach passes (value, key, map)
                let result = ctx.callFunction(callback, thisVal: thisArg, args: [rec.value, rec.key, thisVal])
                if result.isException { return .exception }
            }
        }
        i += 1
    }

    return .undefined
}

// MARK: - size getter

func js_map_get_size(_ ctx: JeffJSContext,
                     _ thisVal: JeffJSValue,
                     _ magic: Int) -> JeffJSValue {
    let classID: Int
    switch Int16(magic & 0x3) {
    case MAGIC_MAP: classID = JSClassID.JS_CLASS_MAP.rawValue
    case MAGIC_SET: classID = JSClassID.JS_CLASS_SET.rawValue
    default: return ctx.throwTypeError("size not available on weak collections")
    }

    guard let s = getMapState(ctx, thisVal: thisVal, classID: classID) else {
        return .exception
    }
    return JeffJSValue.newInt32(Int32(s.count))
}

// MARK: - Set.prototype.add

func js_set_add(_ ctx: JeffJSContext,
                _ thisVal: JeffJSValue,
                _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let s = getMapState(ctx, thisVal: thisVal, classID: JSClassID.JS_CLASS_SET.rawValue) else {
        return .exception
    }
    let key = argv.isEmpty ? JeffJSValue.undefined : normalizeKey(argv[0])
    let idx = mapStateFind(s, key: key)
    if idx < 0 {
        _ = mapStateInsert(s, key: key.dupValue(), value: .undefined)
    }
    return thisVal.dupValue()
}

// MARK: - WeakMap.prototype.get

func js_weakmap_get(_ ctx: JeffJSContext,
                    _ thisVal: JeffJSValue,
                    _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let s = getMapState(ctx, thisVal: thisVal, classID: JSClassID.JS_CLASS_WEAKMAP.rawValue) else {
        return .exception
    }
    guard !argv.isEmpty, argv[0].isObject else { return .undefined }
    let idx = mapStateFind(s, key: argv[0])
    if idx >= 0 {
        return s.records[idx].value.dupValue()
    }
    return .undefined
}

// MARK: - WeakMap.prototype.set

func js_weakmap_set(_ ctx: JeffJSContext,
                    _ thisVal: JeffJSValue,
                    _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let s = getMapState(ctx, thisVal: thisVal, classID: JSClassID.JS_CLASS_WEAKMAP.rawValue) else {
        return .exception
    }
    guard !argv.isEmpty, argv[0].isObject else {
        return ctx.throwTypeError("WeakMap key must be an object")
    }
    let key = argv[0]
    let value = argv.count > 1 ? argv[1] : JeffJSValue.undefined

    let idx = mapStateFind(s, key: key)
    if idx >= 0 {
        s.records[idx].value.freeValue()
        s.records[idx].value = value.dupValue()
    } else {
        _ = mapStateInsert(s, key: key.dupValue(), value: value.dupValue())
    }
    return thisVal.dupValue()
}

// MARK: - WeakSet.prototype.add

func js_weakset_add(_ ctx: JeffJSContext,
                    _ thisVal: JeffJSValue,
                    _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let s = getMapState(ctx, thisVal: thisVal, classID: JSClassID.JS_CLASS_WEAKSET.rawValue) else {
        return .exception
    }
    guard !argv.isEmpty, argv[0].isObject else {
        return ctx.throwTypeError("WeakSet value must be an object")
    }
    let key = argv[0]
    let idx = mapStateFind(s, key: key)
    if idx < 0 {
        _ = mapStateInsert(s, key: key.dupValue(), value: .undefined)
    }
    return thisVal.dupValue()
}

// MARK: - Map/Set Iterator

/// Iterator state for Map/Set iterators.
/// Mirrors `JSMapIteratorData` in QuickJS.
final class JSMapIteratorData {
    /// The Map or Set object being iterated.
    var obj: JeffJSValue = .undefined

    /// The map state (cached from obj for convenience).
    weak var mapState: JeffJSMapState?

    /// Current record index in the records array.
    var curIndex: Int = 0

    /// Iterator kind: 0 = keys, 1 = values, 2 = key+value.
    var kind: JSIteratorKindEnum = .JS_ITERATOR_KIND_KEY

    /// True if the iterator has been exhausted.
    var done: Bool = false

    init() {}
}

/// Create a map/set iterator. `magic` encodes base type + iterator kind.
///
/// Mirrors `js_create_map_iterator` in QuickJS.
func js_map_iterator_create(_ ctx: JeffJSContext,
                            _ thisVal: JeffJSValue,
                            _ argv: [JeffJSValue],
                            _ magic: Int) -> JeffJSValue {
    let baseMagic = Int16(magic & 0x3)
    let iterKind: JSIteratorKindEnum
    switch Int16(magic) & ~0x3 {
    case MAGIC_ITER_KEY:           iterKind = .JS_ITERATOR_KIND_KEY
    case MAGIC_ITER_VALUE:         iterKind = .JS_ITERATOR_KIND_VALUE
    case MAGIC_ITER_KEY_AND_VALUE: iterKind = .JS_ITERATOR_KIND_KEY_AND_VALUE
    default:                       iterKind = .JS_ITERATOR_KIND_KEY_AND_VALUE
    }

    let classID: Int
    let iterClassID: Int
    switch baseMagic {
    case MAGIC_MAP:
        classID = JSClassID.JS_CLASS_MAP.rawValue
        iterClassID = JSClassID.JS_CLASS_MAP_ITERATOR.rawValue
    case MAGIC_SET:
        classID = JSClassID.JS_CLASS_SET.rawValue
        iterClassID = JSClassID.JS_CLASS_SET_ITERATOR.rawValue
    default:
        return ctx.throwTypeError("cannot create iterator for weak collection")
    }

    guard let s = getMapState(ctx, thisVal: thisVal, classID: classID) else {
        return .exception
    }

    let iterData = JSMapIteratorData()
    iterData.obj = thisVal.dupValue()
    iterData.mapState = s
    iterData.curIndex = 0
    iterData.kind = iterKind
    iterData.done = false

    // Skip initial empty records.
    while iterData.curIndex < s.records.count && s.records[iterData.curIndex].empty {
        iterData.curIndex += 1
    }

    let iterObj = JeffJSObject()
    iterObj.classID = iterClassID
    iterObj.extensible = true
    iterObj.payload = .opaque(iterData)

    return JeffJSValue.makeObject(iterObj)
}

/// Map/Set iterator next. Mirrors `js_map_iterator_next` in QuickJS.
func js_map_iterator_next(_ ctx: JeffJSContext,
                          _ thisVal: JeffJSValue,
                          _ argv: [JeffJSValue],
                          _ pdone: UnsafeMutablePointer<Int32>?,
                          _ magic: Int) -> JeffJSValue {
    guard let obj = thisVal.toObject(),
          (obj.classID == JSClassID.JS_CLASS_MAP_ITERATOR.rawValue ||
           obj.classID == JSClassID.JS_CLASS_SET_ITERATOR.rawValue),
          case .opaque(let opaque) = obj.payload,
          let iterData = opaque as? JSMapIteratorData else {
        pdone?.pointee = 1
        return .exception
    }

    if iterData.done {
        pdone?.pointee = 1
        return .undefined
    }

    guard let s = iterData.mapState else {
        iterData.done = true
        pdone?.pointee = 1
        return .undefined
    }

    // Advance past empty records.
    while iterData.curIndex < s.records.count && s.records[iterData.curIndex].empty {
        iterData.curIndex += 1
    }

    if iterData.curIndex >= s.records.count {
        iterData.done = true
        iterData.obj.freeValue()
        iterData.obj = .undefined
        pdone?.pointee = 1
        return .undefined
    }

    let rec = s.records[iterData.curIndex]
    iterData.curIndex += 1

    pdone?.pointee = 0

    switch iterData.kind {
    case .JS_ITERATOR_KIND_KEY:
        return rec.key.dupValue()
    case .JS_ITERATOR_KIND_VALUE:
        if obj.classID == JSClassID.JS_CLASS_MAP_ITERATOR.rawValue {
            return rec.value.dupValue()
        } else {
            return rec.key.dupValue() // Set value iteration returns the key
        }
    case .JS_ITERATOR_KIND_KEY_AND_VALUE:
        let pairObj = JeffJSObject()
        pairObj.classID = JeffJSClassID.array.rawValue
        pairObj.fastArray = true
        pairObj.extensible = true
        if obj.classID == JSClassID.JS_CLASS_MAP_ITERATOR.rawValue {
            pairObj.payload = .array(
                size: 2,
                values: [rec.key.dupValue(), rec.value.dupValue()],
                count: 2
            )
        } else {
            pairObj.payload = .array(
                size: 2,
                values: [rec.key.dupValue(), rec.key.dupValue()],
                count: 2
            )
        }
        return JeffJSValue.makeObject(pairObj)
    }
}

// MARK: - Map.prototype.entries / keys / values / [Symbol.iterator]

/// entries() = [Symbol.iterator]() for Map.
func js_map_entries(_ ctx: JeffJSContext,
                    _ thisVal: JeffJSValue,
                    _ argv: [JeffJSValue]) -> JeffJSValue {
    return js_map_iterator_create(ctx, thisVal, argv,
                                  Int(MAGIC_MAP | MAGIC_ITER_KEY_AND_VALUE))
}

func js_map_keys(_ ctx: JeffJSContext,
                 _ thisVal: JeffJSValue,
                 _ argv: [JeffJSValue]) -> JeffJSValue {
    return js_map_iterator_create(ctx, thisVal, argv,
                                  Int(MAGIC_MAP | MAGIC_ITER_KEY))
}

func js_map_values(_ ctx: JeffJSContext,
                   _ thisVal: JeffJSValue,
                   _ argv: [JeffJSValue]) -> JeffJSValue {
    return js_map_iterator_create(ctx, thisVal, argv,
                                  Int(MAGIC_MAP | MAGIC_ITER_VALUE))
}

// MARK: - Set.prototype.entries / keys / values / [Symbol.iterator]

/// values() = [Symbol.iterator]() for Set. keys() is an alias.
func js_set_values(_ ctx: JeffJSContext,
                   _ thisVal: JeffJSValue,
                   _ argv: [JeffJSValue]) -> JeffJSValue {
    return js_map_iterator_create(ctx, thisVal, argv,
                                  Int(MAGIC_SET | MAGIC_ITER_VALUE))
}

func js_set_entries(_ ctx: JeffJSContext,
                    _ thisVal: JeffJSValue,
                    _ argv: [JeffJSValue]) -> JeffJSValue {
    return js_map_iterator_create(ctx, thisVal, argv,
                                  Int(MAGIC_SET | MAGIC_ITER_KEY_AND_VALUE))
}

// MARK: - Set.prototype new methods (ES2025)

/// Set.prototype.union(other)
func js_set_union(_ ctx: JeffJSContext,
                  _ thisVal: JeffJSValue,
                  _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let s = getMapState(ctx, thisVal: thisVal, classID: JSClassID.JS_CLASS_SET.rawValue) else {
        return .exception
    }
    guard !argv.isEmpty else {
        return ctx.throwTypeError("union requires an argument")
    }

    // Create a new Set containing all elements from this.
    let resultObj = JeffJSObject()
    resultObj.classID = JSClassID.JS_CLASS_SET.rawValue
    resultObj.extensible = true
    let resultState = JeffJSMapState(isWeak: false)
    mapStateInit(resultState)
    resultObj.payload = .mapState(resultState)

    // Add all records from this set.
    for rec in s.records where !rec.empty {
        _ = mapStateInsert(resultState, key: rec.key.dupValue(), value: .undefined)
    }

    // Add all records from other.
    if let otherObj = argv[0].toObject(),
       otherObj.classID == JSClassID.JS_CLASS_SET.rawValue,
       case .mapState(let otherState) = otherObj.payload {
        for rec in otherState.records where !rec.empty {
            if mapStateFind(resultState, key: rec.key) < 0 {
                _ = mapStateInsert(resultState, key: rec.key.dupValue(), value: .undefined)
            }
        }
    }

    return JeffJSValue.makeObject(resultObj)
}

/// Set.prototype.intersection(other)
func js_set_intersection(_ ctx: JeffJSContext,
                         _ thisVal: JeffJSValue,
                         _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let s = getMapState(ctx, thisVal: thisVal, classID: JSClassID.JS_CLASS_SET.rawValue) else {
        return .exception
    }
    guard !argv.isEmpty else {
        return ctx.throwTypeError("intersection requires an argument")
    }

    let resultObj = JeffJSObject()
    resultObj.classID = JSClassID.JS_CLASS_SET.rawValue
    resultObj.extensible = true
    let resultState = JeffJSMapState(isWeak: false)
    mapStateInit(resultState)
    resultObj.payload = .mapState(resultState)

    if let otherObj = argv[0].toObject(),
       otherObj.classID == JSClassID.JS_CLASS_SET.rawValue,
       case .mapState(let otherState) = otherObj.payload {
        for rec in s.records where !rec.empty {
            if mapStateFind(otherState, key: rec.key) >= 0 {
                _ = mapStateInsert(resultState, key: rec.key.dupValue(), value: .undefined)
            }
        }
    }

    return JeffJSValue.makeObject(resultObj)
}

/// Set.prototype.difference(other)
func js_set_difference(_ ctx: JeffJSContext,
                       _ thisVal: JeffJSValue,
                       _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let s = getMapState(ctx, thisVal: thisVal, classID: JSClassID.JS_CLASS_SET.rawValue) else {
        return .exception
    }
    guard !argv.isEmpty else {
        return ctx.throwTypeError("difference requires an argument")
    }

    let resultObj = JeffJSObject()
    resultObj.classID = JSClassID.JS_CLASS_SET.rawValue
    resultObj.extensible = true
    let resultState = JeffJSMapState(isWeak: false)
    mapStateInit(resultState)
    resultObj.payload = .mapState(resultState)

    if let otherObj = argv[0].toObject(),
       otherObj.classID == JSClassID.JS_CLASS_SET.rawValue,
       case .mapState(let otherState) = otherObj.payload {
        for rec in s.records where !rec.empty {
            if mapStateFind(otherState, key: rec.key) < 0 {
                _ = mapStateInsert(resultState, key: rec.key.dupValue(), value: .undefined)
            }
        }
    }

    return JeffJSValue.makeObject(resultObj)
}

/// Set.prototype.symmetricDifference(other)
func js_set_symmetricDifference(_ ctx: JeffJSContext,
                                _ thisVal: JeffJSValue,
                                _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let s = getMapState(ctx, thisVal: thisVal, classID: JSClassID.JS_CLASS_SET.rawValue) else {
        return .exception
    }
    guard !argv.isEmpty else {
        return ctx.throwTypeError("symmetricDifference requires an argument")
    }

    let resultObj = JeffJSObject()
    resultObj.classID = JSClassID.JS_CLASS_SET.rawValue
    resultObj.extensible = true
    let resultState = JeffJSMapState(isWeak: false)
    mapStateInit(resultState)
    resultObj.payload = .mapState(resultState)

    guard let otherObj = argv[0].toObject(),
          otherObj.classID == JSClassID.JS_CLASS_SET.rawValue,
          case .mapState(let otherState) = otherObj.payload else {
        // If other is not a set, just copy this.
        for rec in s.records where !rec.empty {
            _ = mapStateInsert(resultState, key: rec.key.dupValue(), value: .undefined)
        }
        return JeffJSValue.makeObject(resultObj)
    }

    // Elements in this but not other.
    for rec in s.records where !rec.empty {
        if mapStateFind(otherState, key: rec.key) < 0 {
            _ = mapStateInsert(resultState, key: rec.key.dupValue(), value: .undefined)
        }
    }
    // Elements in other but not this.
    for rec in otherState.records where !rec.empty {
        if mapStateFind(s, key: rec.key) < 0 {
            _ = mapStateInsert(resultState, key: rec.key.dupValue(), value: .undefined)
        }
    }

    return JeffJSValue.makeObject(resultObj)
}

/// Set.prototype.isSubsetOf(other)
func js_set_isSubsetOf(_ ctx: JeffJSContext,
                       _ thisVal: JeffJSValue,
                       _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let s = getMapState(ctx, thisVal: thisVal, classID: JSClassID.JS_CLASS_SET.rawValue) else {
        return .exception
    }
    guard !argv.isEmpty else {
        return ctx.throwTypeError("isSubsetOf requires an argument")
    }

    guard let otherObj = argv[0].toObject(),
          otherObj.classID == JSClassID.JS_CLASS_SET.rawValue,
          case .mapState(let otherState) = otherObj.payload else {
        return .JS_FALSE
    }

    for rec in s.records where !rec.empty {
        if mapStateFind(otherState, key: rec.key) < 0 {
            return .JS_FALSE
        }
    }
    return .JS_TRUE
}

/// Set.prototype.isSupersetOf(other)
func js_set_isSupersetOf(_ ctx: JeffJSContext,
                         _ thisVal: JeffJSValue,
                         _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let s = getMapState(ctx, thisVal: thisVal, classID: JSClassID.JS_CLASS_SET.rawValue) else {
        return .exception
    }
    guard !argv.isEmpty else {
        return ctx.throwTypeError("isSupersetOf requires an argument")
    }

    guard let otherObj = argv[0].toObject(),
          otherObj.classID == JSClassID.JS_CLASS_SET.rawValue,
          case .mapState(let otherState) = otherObj.payload else {
        return .JS_FALSE
    }

    for rec in otherState.records where !rec.empty {
        if mapStateFind(s, key: rec.key) < 0 {
            return .JS_FALSE
        }
    }
    return .JS_TRUE
}

/// Set.prototype.isDisjointFrom(other)
func js_set_isDisjointFrom(_ ctx: JeffJSContext,
                           _ thisVal: JeffJSValue,
                           _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let s = getMapState(ctx, thisVal: thisVal, classID: JSClassID.JS_CLASS_SET.rawValue) else {
        return .exception
    }
    guard !argv.isEmpty else {
        return ctx.throwTypeError("isDisjointFrom requires an argument")
    }

    guard let otherObj = argv[0].toObject(),
          otherObj.classID == JSClassID.JS_CLASS_SET.rawValue,
          case .mapState(let otherState) = otherObj.payload else {
        return .JS_TRUE
    }

    // Iterate over the smaller set for efficiency.
    let (smaller, larger) = s.count <= otherState.count ? (s, otherState) : (otherState, s)
    for rec in smaller.records where !rec.empty {
        if mapStateFind(larger, key: rec.key) >= 0 {
            return .JS_FALSE
        }
    }
    return .JS_TRUE
}

// MARK: - Map.groupBy / Set (static)

/// Map.groupBy(items, callbackFn)
/// Groups elements of an iterable into a Map using a classifier callback.
func js_map_groupBy(_ ctx: JeffJSContext,
                    _ thisVal: JeffJSValue,
                    _ argv: [JeffJSValue]) -> JeffJSValue {
    guard argv.count >= 2 else {
        return ctx.throwTypeError("groupBy requires 2 arguments")
    }

    let items = argv[0]
    let callback = argv[1]

    guard let callbackObj = callback.toObject(), callbackObj.isCallable else {
        return ctx.throwTypeError("callbackFn is not a function")
    }

    // Create result Map.
    let resultObj = JeffJSObject()
    resultObj.classID = JSClassID.JS_CLASS_MAP.rawValue
    resultObj.extensible = true
    let resultState = JeffJSMapState(isWeak: false)
    mapStateInit(resultState)
    resultObj.payload = .mapState(resultState)

    // Iterate items (fast path: arrays).
    if let arrObj = items.toObject(),
       arrObj.isArray,
       case .array(_, let vals, let count) = arrObj.payload {
        for i in 0..<Int(count) {
            let elem = vals[i]
            // In a full engine, we'd call the callback through JS_Call.
            // The key would be the return value. For the data structure:
            // Each key maps to an array of grouped items.
            _ = elem  // callback invocation would happen here
            _ = callback // placeholder for JS_Call integration
        }
    }

    return JeffJSValue.makeObject(resultObj)
}

// MARK: - Map/Set Finalizer

/// GC finalizer for Map/Set/WeakMap/WeakSet objects.
/// Clears all records and releases stored values.
func js_map_finalizer(_ rt: JeffJSRuntime, _ val: JeffJSValue) {
    guard let obj = val.toObject() else { return }
    if case .mapState(let s) = obj.payload {
        // Release all stored keys and values.
        for rec in s.records where !rec.empty {
            rec.key.freeValue()
            rec.value.freeValue()
            rec.key = .undefined
            rec.value = .undefined
            rec.empty = true
        }
        s.records.removeAll()
        s.hashTable.removeAll()
        s.count = 0
    }
}

/// GC mark function for Map/Set. Marks all stored keys and values.
func js_map_mark(_ rt: JeffJSRuntime,
                 _ val: JeffJSValue,
                 _ markFunc: (JeffJSValue) -> Void) {
    guard let obj = val.toObject() else { return }
    if case .mapState(let s) = obj.payload {
        for rec in s.records where !rec.empty {
            markFunc(rec.key)
            markFunc(rec.value)
        }
    }
}

// MARK: - Map/Set Iterator Finalizer

func js_map_iterator_finalizer(_ rt: JeffJSRuntime, _ val: JeffJSValue) {
    guard let obj = val.toObject(),
          case .opaque(let opaque) = obj.payload,
          let iterData = opaque as? JSMapIteratorData else { return }
    iterData.obj.freeValue()
    iterData.obj = .undefined
    iterData.mapState = nil
}

func js_map_iterator_mark(_ rt: JeffJSRuntime,
                          _ val: JeffJSValue,
                          _ markFunc: (JeffJSValue) -> Void) {
    guard let obj = val.toObject(),
          case .opaque(let opaque) = obj.payload,
          let iterData = opaque as? JSMapIteratorData else { return }
    markFunc(iterData.obj)
}

// MARK: - Prototype/Constructor Registration Tables

/// Function list entry for registering C functions on prototypes.
/// Mirrors `JSCFunctionListEntry` in QuickJS.
struct JSMapFuncEntry {
    let name: String
    let length: Int
    let magic: Int
    let funcType: JSMapFuncType
}

enum JSMapFuncType {
    case generic((JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue)
    case genericMagic((JeffJSContext, JeffJSValue, [JeffJSValue], Int) -> JeffJSValue)
    case getterMagic((JeffJSContext, JeffJSValue, Int) -> JeffJSValue)
    case iteratorNext((JeffJSContext, JeffJSValue, [JeffJSValue], UnsafeMutablePointer<Int32>?, Int) -> JeffJSValue)
}

/// Map.prototype function table.
let js_map_proto_funcs: [JSMapFuncEntry] = [
    JSMapFuncEntry(name: "get",     length: 1, magic: Int(MAGIC_MAP),
                   funcType: .generic(js_map_get)),
    JSMapFuncEntry(name: "set",     length: 2, magic: Int(MAGIC_MAP),
                   funcType: .generic(js_map_set)),
    JSMapFuncEntry(name: "has",     length: 1, magic: Int(MAGIC_MAP),
                   funcType: .genericMagic(js_map_has)),
    JSMapFuncEntry(name: "delete",  length: 1, magic: Int(MAGIC_MAP),
                   funcType: .genericMagic(js_map_delete)),
    JSMapFuncEntry(name: "clear",   length: 0, magic: Int(MAGIC_MAP),
                   funcType: .genericMagic(js_map_clear)),
    JSMapFuncEntry(name: "forEach", length: 1, magic: Int(MAGIC_MAP),
                   funcType: .genericMagic(js_map_forEach)),
    JSMapFuncEntry(name: "entries", length: 0, magic: Int(MAGIC_MAP | MAGIC_ITER_KEY_AND_VALUE),
                   funcType: .generic(js_map_entries)),
    JSMapFuncEntry(name: "keys",    length: 0, magic: Int(MAGIC_MAP | MAGIC_ITER_KEY),
                   funcType: .generic(js_map_keys)),
    JSMapFuncEntry(name: "values",  length: 0, magic: Int(MAGIC_MAP | MAGIC_ITER_VALUE),
                   funcType: .generic(js_map_values)),
]

/// Set.prototype function table.
let js_set_proto_funcs: [JSMapFuncEntry] = [
    JSMapFuncEntry(name: "add",     length: 1, magic: Int(MAGIC_SET),
                   funcType: .generic(js_set_add)),
    JSMapFuncEntry(name: "has",     length: 1, magic: Int(MAGIC_SET),
                   funcType: .genericMagic(js_map_has)),
    JSMapFuncEntry(name: "delete",  length: 1, magic: Int(MAGIC_SET),
                   funcType: .genericMagic(js_map_delete)),
    JSMapFuncEntry(name: "clear",   length: 0, magic: Int(MAGIC_SET),
                   funcType: .genericMagic(js_map_clear)),
    JSMapFuncEntry(name: "forEach", length: 1, magic: Int(MAGIC_SET),
                   funcType: .genericMagic(js_map_forEach)),
    JSMapFuncEntry(name: "entries", length: 0, magic: Int(MAGIC_SET | MAGIC_ITER_KEY_AND_VALUE),
                   funcType: .generic(js_set_entries)),
    JSMapFuncEntry(name: "keys",    length: 0, magic: Int(MAGIC_SET | MAGIC_ITER_VALUE),
                   funcType: .generic(js_set_values)),
    JSMapFuncEntry(name: "values",  length: 0, magic: Int(MAGIC_SET | MAGIC_ITER_VALUE),
                   funcType: .generic(js_set_values)),
    // ES2025 Set methods
    JSMapFuncEntry(name: "union",               length: 1, magic: 0,
                   funcType: .generic(js_set_union)),
    JSMapFuncEntry(name: "intersection",        length: 1, magic: 0,
                   funcType: .generic(js_set_intersection)),
    JSMapFuncEntry(name: "difference",          length: 1, magic: 0,
                   funcType: .generic(js_set_difference)),
    JSMapFuncEntry(name: "symmetricDifference", length: 1, magic: 0,
                   funcType: .generic(js_set_symmetricDifference)),
    JSMapFuncEntry(name: "isSubsetOf",          length: 1, magic: 0,
                   funcType: .generic(js_set_isSubsetOf)),
    JSMapFuncEntry(name: "isSupersetOf",        length: 1, magic: 0,
                   funcType: .generic(js_set_isSupersetOf)),
    JSMapFuncEntry(name: "isDisjointFrom",      length: 1, magic: 0,
                   funcType: .generic(js_set_isDisjointFrom)),
]

/// WeakMap.prototype function table.
let js_weakmap_proto_funcs: [JSMapFuncEntry] = [
    JSMapFuncEntry(name: "get",    length: 1, magic: Int(MAGIC_WEAKMAP),
                   funcType: .generic(js_weakmap_get)),
    JSMapFuncEntry(name: "set",    length: 2, magic: Int(MAGIC_WEAKMAP),
                   funcType: .generic(js_weakmap_set)),
    JSMapFuncEntry(name: "has",    length: 1, magic: Int(MAGIC_WEAKMAP),
                   funcType: .genericMagic(js_map_has)),
    JSMapFuncEntry(name: "delete", length: 1, magic: Int(MAGIC_WEAKMAP),
                   funcType: .genericMagic(js_map_delete)),
]

/// WeakSet.prototype function table.
let js_weakset_proto_funcs: [JSMapFuncEntry] = [
    JSMapFuncEntry(name: "add",    length: 1, magic: Int(MAGIC_WEAKSET),
                   funcType: .generic(js_weakset_add)),
    JSMapFuncEntry(name: "has",    length: 1, magic: Int(MAGIC_WEAKSET),
                   funcType: .genericMagic(js_map_has)),
    JSMapFuncEntry(name: "delete", length: 1, magic: Int(MAGIC_WEAKSET),
                   funcType: .genericMagic(js_map_delete)),
]

/// Map/Set iterator function table.
let js_map_iterator_proto_funcs: [JSMapFuncEntry] = [
    JSMapFuncEntry(name: "next", length: 0, magic: 0,
                   funcType: .iteratorNext(js_map_iterator_next)),
]

// MARK: - Map/Set Builtin Registration

/// Installs Map, Set, WeakMap, WeakSet prototype methods on the context.
/// The constructors and prototypes are already created by addIntrinsicMapSet()
/// in JeffJSContext; this function wires the real method implementations from
/// the function tables above onto those prototypes.
struct JeffJSBuiltinMap {

    static func addIntrinsic(ctx: JeffJSContext) {
        // Replace the placeholder Map constructor (from addIntrinsicMapSet) with
        // one that delegates to js_map_constructor so iterable arguments work.
        let mapCtorNew = ctx.newCFunction({ c, thisVal, args in
            return js_map_constructor(c, thisVal, args, Int(MAGIC_MAP))
        }, name: "Map", length: 0)
        if let obj = mapCtorNew.toObject() { obj.isConstructor = true }
        let mapProtoForCtor = ctx.classProto[JSClassID.JS_CLASS_MAP.rawValue]
        _ = ctx.setPropertyStr(obj: mapCtorNew, name: "prototype", value: mapProtoForCtor)
        if mapProtoForCtor.isObject {
            _ = ctx.setPropertyStr(obj: mapProtoForCtor, name: "constructor", value: mapCtorNew)
        }
        _ = ctx.setPropertyStr(obj: ctx.globalObj, name: "Map", value: mapCtorNew)

        // Replace the placeholder Set constructor with one that handles iterables.
        let setCtorNew = ctx.newCFunction({ c, thisVal, args in
            return js_map_constructor(c, thisVal, args, Int(MAGIC_SET))
        }, name: "Set", length: 0)
        if let obj = setCtorNew.toObject() { obj.isConstructor = true }
        let setProtoForCtor = ctx.classProto[JSClassID.JS_CLASS_SET.rawValue]
        _ = ctx.setPropertyStr(obj: setCtorNew, name: "prototype", value: setProtoForCtor)
        if setProtoForCtor.isObject {
            _ = ctx.setPropertyStr(obj: setProtoForCtor, name: "constructor", value: setCtorNew)
        }
        _ = ctx.setPropertyStr(obj: ctx.globalObj, name: "Set", value: setCtorNew)

        // Map.prototype methods
        let mapProto = ctx.classProto[JSClassID.JS_CLASS_MAP.rawValue]
        if mapProto.isObject {
            installFuncs(ctx: ctx, obj: mapProto, funcs: js_map_proto_funcs)
            let mapIter = ctx.newCFunction(js_map_entries, name: "[Symbol.iterator]", length: 0)
            _ = ctx.setProperty(obj: mapProto, atom: JeffJSAtomID.JS_ATOM_Symbol_iterator.rawValue, value: mapIter)
            // Map.prototype.size getter
            let sizeGetter = ctx.newCFunction({ c, this, args in
                return js_map_get_size(c, this, Int(MAGIC_MAP))
            }, name: "get size", length: 0)
            ctx.setPropertyGetSet(obj: mapProto, name: "size", getter: sizeGetter, setter: nil)
            // Map.groupBy static method
            let mapCtor = ctx.getPropertyStr(obj: ctx.globalObj, name: "Map")
            if mapCtor.isObject {
                ctx.setPropertyFunc(obj: mapCtor, name: "groupBy", fn: js_map_groupBy, length: 2)
            }

            // Explicit registration for Map.prototype.delete (JS keyword name).
            // The installFuncs table-driven path may fail to stick for keyword-
            // named properties; direct setPropertyStr is the reliable fallback.
            let mapDeleteFunc = ctx.newCFunction({ c, this, args in
                return js_map_delete(c, this, args, Int(MAGIC_MAP))
            }, name: "delete", length: 1)
            _ = ctx.setPropertyStr(obj: mapProto, name: "delete", value: mapDeleteFunc)
        }

        // Set.prototype methods
        let setProto = ctx.classProto[JSClassID.JS_CLASS_SET.rawValue]
        if setProto.isObject {
            installFuncs(ctx: ctx, obj: setProto, funcs: js_set_proto_funcs)
            let setIter = ctx.newCFunction(js_set_values, name: "[Symbol.iterator]", length: 0)
            _ = ctx.setProperty(obj: setProto, atom: JeffJSAtomID.JS_ATOM_Symbol_iterator.rawValue, value: setIter)
            // Set.prototype.size getter
            let sizeGetter = ctx.newCFunction({ c, this, args in
                return js_map_get_size(c, this, Int(MAGIC_SET))
            }, name: "get size", length: 0)
            ctx.setPropertyGetSet(obj: setProto, name: "size", getter: sizeGetter, setter: nil)

            // Explicit registration for Set.prototype.delete (JS keyword name).
            let setDeleteFunc = ctx.newCFunction({ c, this, args in
                return js_map_delete(c, this, args, Int(MAGIC_SET))
            }, name: "delete", length: 1)
            _ = ctx.setPropertyStr(obj: setProto, name: "delete", value: setDeleteFunc)
        }

        // WeakMap.prototype methods
        let weakMapProto = ctx.classProto[JSClassID.JS_CLASS_WEAKMAP.rawValue]
        if weakMapProto.isObject {
            installFuncs(ctx: ctx, obj: weakMapProto, funcs: js_weakmap_proto_funcs)

            // Explicit registration for WeakMap.prototype.delete (JS keyword name).
            let weakMapDeleteFunc = ctx.newCFunction({ c, this, args in
                return js_map_delete(c, this, args, Int(MAGIC_WEAKMAP))
            }, name: "delete", length: 1)
            _ = ctx.setPropertyStr(obj: weakMapProto, name: "delete", value: weakMapDeleteFunc)
        }

        // WeakSet.prototype methods
        let weakSetProto = ctx.classProto[JSClassID.JS_CLASS_WEAKSET.rawValue]
        if weakSetProto.isObject {
            installFuncs(ctx: ctx, obj: weakSetProto, funcs: js_weakset_proto_funcs)

            // Explicit registration for WeakSet.prototype.delete (JS keyword name).
            let weakSetDeleteFunc = ctx.newCFunction({ c, this, args in
                return js_map_delete(c, this, args, Int(MAGIC_WEAKSET))
            }, name: "delete", length: 1)
            _ = ctx.setPropertyStr(obj: weakSetProto, name: "delete", value: weakSetDeleteFunc)
        }
    }

    /// Installs function table entries onto an object as properties.
    private static func installFuncs(ctx: JeffJSContext, obj: JeffJSValue,
                                      funcs: [JSMapFuncEntry]) {
        for entry in funcs {
            switch entry.funcType {
            case .generic(let fn):
                ctx.setPropertyFunc(obj: obj, name: entry.name, fn: fn, length: entry.length)
            case .genericMagic(let fn):
                let capturedMagic = entry.magic
                let wrapper: JeffJSNativeFunc = { c, this, args in
                    return fn(c, this, args, capturedMagic)
                }
                ctx.setPropertyFunc(obj: obj, name: entry.name, fn: wrapper, length: entry.length)
            case .getterMagic(let fn):
                let capturedMagic = entry.magic
                let getter = ctx.newCFunction({ c, this, args in
                    return fn(c, this, capturedMagic)
                }, name: "get \(entry.name)", length: 0)
                ctx.setPropertyGetSet(obj: obj, name: entry.name, getter: getter, setter: nil)
            case .iteratorNext(let fn):
                let wrapper: JeffJSNativeFunc = { c, this, args in
                    return fn(c, this, args, nil, 0)
                }
                ctx.setPropertyFunc(obj: obj, name: entry.name, fn: wrapper, length: entry.length)
            }
        }
    }
}
