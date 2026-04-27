// JeffJSValue.swift
// JeffJS - 1:1 Swift port of QuickJS
//
// TRUE NaN-boxed value representation (8 bytes).
//
// Layout: { bits: UInt64 } = 8 bytes
//   Non-heap types: bits = NaN-boxed tag + inline payload
//   Heap types:     bits = NaN-boxed tag + raw pointer (low 48 bits)
//
// Down from 16-byte { bits: UInt64, _ref: AnyObject? }.
// 50% smaller — doubles stack density and cache efficiency.
//
// Heap objects are embedded as raw pointers via Unmanaged.passRetained().
// No heap table, no dictionary lookup, no dynamic cast, no ARC on access.
// The matching Unmanaged.release() happens in freeGCObject() (JeffJSGC.swift).
//
// All type checks are single-expression bit operations.
// Backward-compatible computed `tag` and `u` properties preserve existing callsites.
//
// This is the CANONICAL definition of JeffJSValue and JSValueTag.
// Other files should NOT redefine these types.

import Foundation

// MARK: - JSValueTag (backward compatibility)

/// Mirrors QuickJS JS_TAG_* constants exactly.
/// Kept for backward compatibility — existing code that reads `.tag` still works
/// through the computed property on JeffJSValue.
enum JSValueTag: Int64 {
    case first              = -11
    case bigInt             = -10
    case bigFloat           = -9
    case symbol             = -8
    case string             = -7
    case stringRope         = -6
    case module_            = -3
    case functionBytecode   = -2
    case object             = -1
    case int_               =  0
    case bool_              =  1
    case null               =  2
    case undefined          =  3
    case uninitialized      =  4
    case catchOffset        =  5
    case exception          =  6
    case shortBigInt        =  7
    case float64            =  8

    var isRefCounted: Bool { rawValue < 0 }
}

// MARK: - JSValuePayload (backward compatibility)

/// Backward-compatible payload enum. Existing code that pattern-matches on `.u`
/// still works through the computed property on JeffJSValue.
enum JSValuePayload {
    case int32(Int32)
    case float64(Double)
    case ptr(AnyObject?)
    case shortBigInt(Int64)
    case none
}

// MARK: - JeffJSValue (NaN-boxed, 8 bytes)

/// The core value type — true NaN-boxed, 8 bytes.
///
/// NaN-boxing scheme:
///   Non-refcounted tags (quiet NaN, positive sign):
///     0x7FF9 = int32      0x7FFA = bool       0x7FFB = null
///     0x7FFC = undefined   0x7FFD = exception   0x7FFE = uninitialized
///     0x7FFF = catchOffset
///   Refcounted tags (quiet NaN, negative sign):
///     0xFFF9 = object     0xFFFA = string      0xFFFB = symbol
///     0xFFFC = bigInt     0xFFFD = funcBytecode 0xFFFE = module
///     0xFFFF = (reserved)
///   Everything else = IEEE 754 double (stored as raw bits).
///
/// Heap types store a raw pointer in the low 48 bits (via Unmanaged.passRetained).
/// No heap table — direct pointer embedding like C/QuickJS.
///
/// Fast isDouble check: `((bits >> 48) &- 0x7FF9) & 0x7FFF >= 7`
struct JeffJSValue {

    // ---- 8-byte storage ----
    var bits: UInt64

    // ---- NaN-boxing tag constants (top 16 bits) ----
    // Non-refcounted
    @usableFromInline static let _intTag:     UInt64 = 0x7FF9_0000_0000_0000
    @usableFromInline static let _boolTag:    UInt64 = 0x7FFA_0000_0000_0000
    @usableFromInline static let _nullTag:    UInt64 = 0x7FFB_0000_0000_0000
    @usableFromInline static let _undefTag:   UInt64 = 0x7FFC_0000_0000_0000
    @usableFromInline static let _exceptTag:  UInt64 = 0x7FFD_0000_0000_0000
    @usableFromInline static let _uninitTag:  UInt64 = 0x7FFE_0000_0000_0000
    @usableFromInline static let _catchTag:   UInt64 = 0x7FFF_0000_0000_0000
    // Refcounted (heap objects — raw pointer embedded in low 48 bits)
    @usableFromInline static let _objectTag:  UInt64 = 0xFFF9_0000_0000_0000
    @usableFromInline static let _stringTag:  UInt64 = 0xFFFA_0000_0000_0000
    @usableFromInline static let _symbolTag:  UInt64 = 0xFFFB_0000_0000_0000
    @usableFromInline static let _bigIntTag:  UInt64 = 0xFFFC_0000_0000_0000
    @usableFromInline static let _fbTag:      UInt64 = 0xFFFD_0000_0000_0000
    @usableFromInline static let _moduleTag:  UInt64 = 0xFFFE_0000_0000_0000
    // Masks
    @usableFromInline static let _tagMask:    UInt64 = 0xFFFF_0000_0000_0000
    @usableFromInline static let _ptrMask:    UInt64 = 0x0000_FFFF_FFFF_FFFF

    // ================================================================
    // MARK: - Constructors
    // ================================================================

    /// JS_MKVAL(tag, val) -- backward-compatible constructor for int32-payload tags.
    @inline(__always)
    static func mkVal(tag: JSValueTag, val: Int32) -> JeffJSValue {
        let nbTag: UInt64
        switch tag {
        case .int_:          nbTag = _intTag
        case .bool_:         nbTag = _boolTag
        case .null:          nbTag = _nullTag
        case .undefined:     nbTag = _undefTag
        case .exception:     nbTag = _exceptTag
        case .uninitialized: nbTag = _uninitTag
        case .catchOffset:   nbTag = _catchTag
        default:             nbTag = _intTag
        }
        return JeffJSValue(bits: nbTag | UInt64(UInt32(bitPattern: val)))
    }

    /// JS_MKPTR(tag, ptr) -- backward-compatible constructor for pointer-payload tags.
    /// Embeds raw pointer via Unmanaged.passRetained (+1 ARC retain).
    @inline(__always)
    static func mkPtr(tag: JSValueTag, ptr: AnyObject?) -> JeffJSValue {
        let nbTag: UInt64
        switch tag {
        case .object:            nbTag = _objectTag
        case .string:            nbTag = _stringTag
        case .stringRope:        nbTag = _stringTag  // ropes use string tag
        case .symbol:            nbTag = _symbolTag
        case .bigInt:            nbTag = _bigIntTag
        case .functionBytecode:  nbTag = _fbTag
        case .module_:           nbTag = _moduleTag
        default:                 nbTag = _objectTag
        }
        guard let obj = ptr else {
            return JeffJSValue(bits: nbTag)
        }
        let raw = Unmanaged.passRetained(obj).toOpaque()
        return JeffJSValue(bits: nbTag | UInt64(UInt(bitPattern: raw)))
    }

    @inline(__always)
    static func newInt32(_ val: Int32) -> JeffJSValue {
        JeffJSValue(bits: _intTag | UInt64(UInt32(bitPattern: val)))
    }

    @inline(__always)
    static func newFloat64(_ val: Double) -> JeffJSValue {
        JeffJSValue(bits: val.bitPattern)
    }

    @inline(__always)
    static func newBool(_ val: Bool) -> JeffJSValue {
        JeffJSValue(bits: _boolTag | (val ? 1 : 0))
    }

    @inline(__always)
    static func newCatchOffset(_ val: Int32) -> JeffJSValue {
        JeffJSValue(bits: _catchTag | UInt64(UInt32(bitPattern: val)))
    }

    @inline(__always)
    static func newInt64(_ val: Int64) -> JeffJSValue {
        if val == Int64(Int32(val)) { return newInt32(Int32(val)) }
        return newFloat64(Double(val))
    }

    @inline(__always)
    static func newUInt32(_ val: UInt32) -> JeffJSValue {
        if val <= UInt32(Int32.max) { return newInt32(Int32(val)) }
        return newFloat64(Double(val))
    }

    // ================================================================
    // MARK: - Static Constants
    // ================================================================

    static let null         = JeffJSValue(bits: _nullTag)
    static let undefined    = JeffJSValue(bits: _undefTag)
    static let JS_UNDEFINED = undefined
    static let JS_FALSE     = JeffJSValue(bits: _boolTag)
    static let JS_TRUE      = JeffJSValue(bits: _boolTag | 1)
    static let exception    = JeffJSValue(bits: _exceptTag)
    static let uninitialized = JeffJSValue(bits: _uninitTag)

    // ================================================================
    // MARK: - Type Checks (bit operations, no enum dispatch)
    // ================================================================

    /// True if the bits encode a NaN-boxed tag (not a raw double).
    @inline(__always)
    private var _isTag: Bool {
        ((bits >> 48) &- 0x7FF9) & 0x7FFF < 7
    }

    /// True if this is a heap type (has a raw pointer in the low bits).
    @inline(__always)
    private var _isHeapTag: Bool {
        bits & Self._tagMask >= Self._objectTag
    }

    /// Extract the raw pointer from the low 48 bits.
    @inline(__always)
    private var _rawPtr: UnsafeRawPointer? {
        guard _isHeapTag else { return nil }
        let ptrBits = bits & Self._ptrMask
        guard ptrBits != 0 else { return nil }
        return UnsafeRawPointer(bitPattern: UInt(ptrBits))
    }

    /// Look up the heap object via Unmanaged extraction (backward compat).
    /// Uses takeUnretainedValue — no ARC retain on access.
    /// For non-hot-path callers (heapRef, stringValue, symbol builtins).
    @inline(__always)
    private var _heapRef: AnyObject? {
        guard let ptr = _rawPtr else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
    }

    @inline(__always)
    func getTag() -> JSValueTag { JSValueTag(rawValue: tag) ?? .first }

    @inline(__always) var isNumber: Bool  { isInt || isFloat64 }
    @inline(__always) var isBigInt: Bool  { (bits & Self._tagMask) == Self._bigIntTag }
    @inline(__always) var isShortBigInt: Bool { false }
    @inline(__always) var isString: Bool  { (bits & Self._tagMask) == Self._stringTag }
    @inline(__always) var isObject: Bool  { (bits & Self._tagMask) == Self._objectTag }
    @inline(__always) var isInt: Bool     { (bits & Self._tagMask) == Self._intTag }
    @inline(__always) var isBool: Bool    { (bits & Self._tagMask) == Self._boolTag }
    @inline(__always) var isNull: Bool    { bits == Self._nullTag }
    @inline(__always) var isUndefined: Bool { bits == Self._undefTag }
    @inline(__always) var isNullOrUndefined: Bool { isNull || isUndefined }
    @inline(__always) var isException: Bool { bits == Self._exceptTag }
    @inline(__always) var isUninitialized: Bool { bits == Self._uninitTag }

    var isFunction: Bool {
        guard let obj = toObject() else { return false }
        return obj.isCallable
    }

    @inline(__always) var isFloat64: Bool { !_isTag && !_isHeapTag }

    /// True if the value is a catchOffset (internal bytecode sentinel).
    @inline(__always) var isCatchOffset: Bool { (bits & Self._tagMask) == Self._catchTag }

    /// Fast tag comparison: true if two values are the same JS type.
    /// Replaces the old `a.tag == b.tag` pattern without the computed property overhead.
    @inline(__always)
    static func sameTag(_ a: JeffJSValue, _ b: JeffJSValue) -> Bool {
        // Both heap types: matching tag bits
        if a._isHeapTag || b._isHeapTag {
            return a._isHeapTag && b._isHeapTag && (a.bits & _tagMask) == (b.bits & _tagMask)
        }
        // Both non-heap: check if both doubles, or both same tagged type
        let aIsDouble = !a._isTag
        let bIsDouble = !b._isTag
        if aIsDouble != bIsDouble { return false }
        if aIsDouble { return true } // both doubles
        return (a.bits & _tagMask) == (b.bits & _tagMask) // both tagged: compare tags
    }
    @inline(__always) var isSymbol: Bool  { (bits & Self._tagMask) == Self._symbolTag }
    @inline(__always) var isModule: Bool  { (bits & Self._tagMask) == Self._moduleTag }
    @inline(__always) var isFunctionBytecode: Bool { (bits & Self._tagMask) == Self._fbTag }
    @inline(__always) var hasRefCount: Bool { _isHeapTag && (bits & Self._ptrMask) != 0 }

    // ================================================================
    // MARK: - Value Extraction (bit ops, no switch dispatch)
    // ================================================================

    @inline(__always)
    func toInt32() -> Int32 {
        guard isInt || isBool || (bits & Self._tagMask) == Self._catchTag else { return 0 }
        return Int32(bitPattern: UInt32(truncatingIfNeeded: bits))
    }

    @inline(__always)
    func toFloat64() -> Double {
        guard isFloat64 else { return 0.0 }
        return Double(bitPattern: bits)
    }

    @inline(__always)
    func toNumber() -> Double {
        if isInt { return Double(Int32(bitPattern: UInt32(truncatingIfNeeded: bits))) }
        if isFloat64 { return Double(bitPattern: bits) }
        return Double.nan
    }

    @inline(__always)
    func toBool() -> Bool {
        if isBool { return (bits & 1) != 0 }
        return false
    }

    @inline(__always)
    func toObject() -> JeffJSObject? {
        guard (bits & Self._tagMask) == Self._objectTag else { return nil }
        guard let ptr = _rawPtr else { return nil }
        return unsafeBitCast(ptr, to: JeffJSObject.self)
    }

    /// Extract a zero-ARC object handle. Returns nil if not an object.
    /// This is the hot-path equivalent of toObject() without ARC overhead.
    @inline(__always)
    var obj: JeffJSObj? {
        guard (bits & Self._tagMask) == Self._objectTag else { return nil }
        guard let ptr = UnsafeMutableRawPointer(bitPattern: UInt(bits & Self._ptrMask)) else { return nil }
        return JeffJSObj(ptr)
    }

    @inline(__always)
    var stringValue: JeffJSString? {
        guard (bits & Self._tagMask) == Self._stringTag else { return nil }
        guard let ref = _heapRef else { return nil }
        // Fast path: already a flat string
        if let str = ref as? JeffJSString { return str }
        // Rope: flatten to a contiguous JeffJSString
        if let rope = ref as? JeffJSStringRope { return jeffJS_flattenRope(rope) }
        // Phase 4: buffer accumulator — materialise to flat string
        if let buf = ref as? JeffJSStringBuffer { return buf.toJeffJSString() }
        return nil
    }

    @inline(__always)
    func toBigInt() -> JeffJSBigInt? {
        guard (bits & Self._tagMask) == Self._bigIntTag else { return nil }
        guard let ptr = _rawPtr else { return nil }
        return unsafeBitCast(ptr, to: JeffJSBigInt.self)
    }

    @inline(__always)
    func toFunctionBytecode() -> JeffJSFunctionBytecode? {
        guard (bits & Self._tagMask) == Self._fbTag else { return nil }
        guard let ptr = _rawPtr else { return nil }
        return unsafeBitCast(ptr, to: JeffJSFunctionBytecode.self)
    }

    @inline(__always)
    func toPtr() -> AnyObject? { _heapRef }

    @inline(__always)
    func toGCObjectHeader() -> JeffJSGCObjectHeader? {
        let tag = bits & Self._tagMask
        guard tag == Self._objectTag || tag == Self._bigIntTag || tag == Self._moduleTag else { return nil }
        guard let ptr = _rawPtr else { return nil }
        // Validate the pointer is in a plausible heap range. Corrupted NaN-boxed
        // values (from stale/freed objects) can have garbage pointer bits that
        // would crash on unsafeBitCast. Valid heap pointers on ARM64/x86_64 are
        // always below the 48-bit virtual address limit.
        let ptrVal = UInt64(UInt(bitPattern: ptr))
        guard ptrVal > 0x1000 && ptrVal < 0x0001_0000_0000_0000 else { return nil }
        return unsafeBitCast(ptr, to: JeffJSGCObjectHeader.self)
    }

    /// Access the raw heap reference for identity comparisons and type casting.
    /// This replaces direct `_ref` access in other files.
    @inline(__always)
    var heapRef: AnyObject? { _heapRef }

    // ================================================================
    // MARK: - Reference Counting
    // ================================================================

    @inline(__always)
    @discardableResult
    func dupValue() -> JeffJSValue {
        guard _isHeapTag else { return self }
        guard let ptr = _rawPtr else { return self }
        let tag = bits & Self._tagMask
        switch tag {
        case Self._objectTag:
            let obj = unsafeBitCast(ptr, to: JeffJSObject.self)
            obj.refCount += 1
            JeffJSGCObjectHeader.trackDup(obj)
        case Self._bigIntTag:
            unsafeBitCast(ptr, to: JeffJSBigInt.self).refCount += 1
        case Self._fbTag:
            unsafeBitCast(ptr, to: JeffJSFunctionBytecode.self).refCount += 1
        case Self._stringTag, Self._symbolTag:
            // String subtypes — need as? chain (3 possible classes)
            let ref = Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
            if let s = ref as? JeffJSString { s.refCount += 1 }
            else if let r = ref as? JeffJSStringRope { r.refCount += 1 }
            else if let b = ref as? JeffJSStringBuffer { b.refCount += 1 }
        case Self._moduleTag:
            unsafeBitCast(ptr, to: JeffJSGCObjectHeader.self).refCount += 1
        default: break
        }
        return self
    }

    @inline(__always)
    func freeValue() {
        guard _isHeapTag else { return }

        // GC-tracked objects: decrement refcount, free when it hits 0.
        // During context init (intrinsicsAdded == false), only decrement —
        // init objects are context-scoped and freed by context.free().
        if let hdr = toGCObjectHeader() {
            JeffJSGCObjectHeader.trackFree(hdr)
            guard hdr.refCount > 0 else { return }
            if let rt = hdr.ownerRuntime ?? JeffJSGCObjectHeader.activeRuntime {
                // Check if any context on this runtime has finished init
                if rt.initComplete {
                    _freeValueRTImpl(rt, self)
                } else {
                    hdr.refCount -= 1
                }
            } else {
                hdr.refCount -= 1
            }
            return
        }

        // Strings and FBs are not GC-tracked — handle directly.
        guard let ptr = _rawPtr else { return }
        let tag = bits & Self._tagMask
        switch tag {
        case Self._fbTag:
            let fb = unsafeBitCast(ptr, to: JeffJSFunctionBytecode.self)
            guard fb.refCount > 0 else { return }
            fb.refCount -= 1
            if fb.refCount == 0 { _freeFBSlow(fb) }
        case Self._stringTag, Self._symbolTag:
            let ref = Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
            if let s = ref as? JeffJSString {
                guard s.refCount > 0 else { return }
                s.refCount -= 1
                if s.refCount == 0 { Unmanaged.passUnretained(s).release() }
            } else if let r = ref as? JeffJSStringRope {
                guard r.refCount > 0 else { return }
                r.refCount -= 1
                if r.refCount == 0 {
                    r.left.freeValue()
                    r.right.freeValue()
                    Unmanaged.passUnretained(r).release()
                }
            } else if let b = ref as? JeffJSStringBuffer {
                guard b.refCount > 0 else { return }
                b.refCount -= 1
                if b.refCount == 0 { Unmanaged.passUnretained(b).release() }
            }
        default: break
        }
    }

    @inline(__always)
    func freeValueRT() { freeValue() }

    @inline(__always)
    func isLiveObject() -> Bool {
        if isObject, let p = toGCObjectHeader() { return p.refCount > 0 }
        return false
    }

    // ================================================================
    // MARK: - Heap Type Constructors
    // ================================================================

    @inline(__always)
    static func makeString(_ str: JeffJSString) -> JeffJSValue {
        let raw = Unmanaged.passRetained(str).toOpaque()
        return JeffJSValue(bits: _stringTag | UInt64(UInt(bitPattern: raw)))
    }

    @inline(__always)
    static func makeObject(_ obj: JeffJSObject) -> JeffJSValue {
        JeffJSGCObjectHeader.trackCreate(obj)
        let raw = Unmanaged.passRetained(obj).toOpaque()
        return JeffJSValue(bits: _objectTag | UInt64(UInt(bitPattern: raw)))
    }

    @inline(__always)
    static func makeBigInt(_ bi: JeffJSBigInt) -> JeffJSValue {
        let raw = Unmanaged.passRetained(bi).toOpaque()
        return JeffJSValue(bits: _bigIntTag | UInt64(UInt(bitPattern: raw)))
    }

    /// Short BigInt: fits in int32 -> store inline; otherwise promote to float64.
    static func mkShortBigInt(_ val: Int64) -> JeffJSValue {
        if val == Int64(Int32(val)) { return newInt32(Int32(val)) }
        return newFloat64(Double(val))
    }

    @inline(__always)
    static func makeFunctionBytecode(_ fb: JeffJSFunctionBytecode) -> JeffJSValue {
        let raw = Unmanaged.passRetained(fb).toOpaque()
        return JeffJSValue(bits: _fbTag | UInt64(UInt(bitPattern: raw)))
    }

    static func makeException() -> JeffJSValue { exception }

    // ---- NaN / Infinity constants ----
    static let JS_NAN               = newFloat64(Double.nan)
    static let JS_POSITIVE_INFINITY = newFloat64(Double.infinity)
    static let JS_NEGATIVE_INFINITY = newFloat64(-Double.infinity)
    static let JS_POSITIVE_ZERO     = newFloat64(0.0)
    static let JS_NEGATIVE_ZERO     = newFloat64(-0.0)

    // ================================================================
    // MARK: - Backward Compatibility (computed `tag` and `u`)
    // ================================================================

    /// Computed tag matching the old JSValueTag enum values.
    /// Prefer `isXxx` checks in new/hot code.
    var tag: Int64 {
        // Heap types (have raw pointer)
        if _isHeapTag {
            let t = bits & Self._tagMask
            switch t {
            case Self._objectTag:  return JSValueTag.object.rawValue
            case Self._stringTag:  return JSValueTag.string.rawValue
            case Self._symbolTag:  return JSValueTag.symbol.rawValue
            case Self._bigIntTag:  return JSValueTag.bigInt.rawValue
            case Self._fbTag:      return JSValueTag.functionBytecode.rawValue
            case Self._moduleTag:  return JSValueTag.module_.rawValue
            default:               return JSValueTag.object.rawValue
            }
        }
        // Double (not a NaN-boxed tag)
        if !_isTag { return JSValueTag.float64.rawValue }
        // Non-refcounted tags
        let top = UInt16(bits >> 48)
        switch top {
        case 0x7FF9: return JSValueTag.int_.rawValue
        case 0x7FFA: return JSValueTag.bool_.rawValue
        case 0x7FFB: return JSValueTag.null.rawValue
        case 0x7FFC: return JSValueTag.undefined.rawValue
        case 0x7FFD: return JSValueTag.exception.rawValue
        case 0x7FFE: return JSValueTag.uninitialized.rawValue
        case 0x7FFF: return JSValueTag.catchOffset.rawValue
        default:     return JSValueTag.float64.rawValue
        }
    }

    /// Computed payload matching the old JSValuePayload enum.
    /// Prefer `toXxx()` methods in new/hot code.
    var u: JSValuePayload {
        if _isHeapTag { return .ptr(_heapRef) }
        if !_isTag { return .float64(Double(bitPattern: bits)) }
        let top = UInt16(bits >> 48)
        switch top {
        case 0x7FF9: return .int32(toInt32())                     // int
        case 0x7FFA: return .int32(Int32(bits & 1))               // bool
        case 0x7FFB, 0x7FFC, 0x7FFD, 0x7FFE: return .none        // null/undef/except/uninit
        case 0x7FFF: return .int32(toInt32())                     // catchOffset
        default:     return .float64(Double(bitPattern: bits))
        }
    }
}

// MARK: - Equatable

extension JeffJSValue: Equatable {
    /// Structural equality (same tag and same pointer/payload).
    /// This is NOT JS `===`; it is used for internal identity checks.
    /// Two values are the same object if their bits are identical
    /// (same tag + same raw pointer).
    static func == (lhs: JeffJSValue, rhs: JeffJSValue) -> Bool {
        lhs.bits == rhs.bits
    }
}

// MARK: - CustomDebugStringConvertible

// MARK: - Slow-path free helpers (called when refcount hits 0)

/// Free a GC-tracked object (JeffJSObject, JeffJSBigInt, etc.) via its ownerRuntime.
/// Called from JeffJSValue.freeValue() when refcount reaches zero.
/// Respects GC phase: defers freeing during active collection.
@inline(never)
func _freeGCObjectSlow(_ hdr: JeffJSGCObjectHeader) {
    guard let rt = hdr.ownerRuntime else { return }
    if rt.gcPhase != .JS_GC_PHASE_NONE {
        rt.gcZeroRefCountObjects.append(hdr)
    } else {
        freeGCObject(rt, hdr)
    }
}

/// Free a standalone JeffJSFunctionBytecode when its refcount reaches zero.
/// Frees constant pool values and releases the Unmanaged retain.
@inline(never)
func _freeFBSlow(_ fb: JeffJSFunctionBytecode) {
    for cpVal in fb.cpool {
        cpVal.freeValue()
    }
    fb.cpool.removeAll()
    Unmanaged.passUnretained(fb).release()
}

/// Decrement string refcount and release when it hits zero.
/// Uses only Unmanaged operations to avoid ARC retain/release on intermediates.
@inline(never)
func _freeStringSlow(_ ptr: UnsafeRawPointer) {
    // Peek at the isa pointer to determine subtype without creating an ARC reference.
    // We use Unmanaged throughout to avoid ARC retain traffic on the hot path.
    let unmgd = Unmanaged<AnyObject>.fromOpaque(UnsafeMutableRawPointer(mutating: ptr))
    let ref = unmgd.takeUnretainedValue()
    if let s = ref as? JeffJSString {
        guard s.refCount > 0 else { return }
        s.refCount -= 1
        if s.refCount == 0 {
            unmgd.release()  // balances passRetained from makeString
        }
    } else if let r = ref as? JeffJSStringRope {
        guard r.refCount > 0 else { return }
        r.refCount -= 1
        if r.refCount == 0 {
            r.left.freeValue()
            r.right.freeValue()
            unmgd.release()
        }
    } else if let b = ref as? JeffJSStringBuffer {
        guard b.refCount > 0 else { return }
        b.refCount -= 1
        if b.refCount == 0 {
            unmgd.release()
        }
    }
}

extension JeffJSValue: CustomDebugStringConvertible {
    var debugDescription: String {
        let tagName = JSValueTag(rawValue: tag).map { "\($0)" } ?? "unknown(\(tag))"
        if _isHeapTag, let ptr = _rawPtr {
            let ref = Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
            return "JSValue(\(tagName): \(type(of: ref))@\(ptr))"
        }
        if isFloat64 { return "JSValue(float64: \(toFloat64()))" }
        if isInt {
            return "JSValue(int_: \(toInt32()))"
        }
        if isBool { return "JSValue(bool_: \(toBool()))" }
        return "JSValue(\(tagName))"
    }
}
