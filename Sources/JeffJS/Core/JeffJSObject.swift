// JeffJSObject.swift
// JeffJS — 1:1 Swift port of QuickJS JSObject and supporting types
// Copyright 2026 Jeff Bachand. All rights reserved.

import Foundation

// MARK: - Forward references

/// Forward reference for `JeffJSShape` (defined in a separate file).
protocol JeffJSShapeProtocol: AnyObject {
    var propCount: Int { get }
    var propHashEnd: Int { get }
    var proto: JeffJSObject? { get set }
    var propHashMask: UInt32 { get }
    var props: [JeffJSShapeProperty] { get set }
    func findProp(atom: UInt32, pHashNext: inout UInt32) -> Int?
}

// NOTE: typealias JeffJSShape = any JeffJSShapeProtocol has been removed.
// JeffJSShape is now a concrete final class defined in JeffJSShape.swift.

/// Forward reference for `JeffJSContext`.
protocol JeffJSContextRef: JeffJSContextProtocol {
    func throwOutOfMemory() -> JeffJSValue
    func throwTypeError(_ msg: String) -> JeffJSValue
}

// NOTE: typealias JeffJSContext = any JeffJSContextRef has been removed.
// JeffJSContext is now a concrete final class defined in JeffJSContext.swift.

// MARK: - Inline Cache

/// Monomorphic inline cache entry for property access.
/// Caches the shape identity + property offset for O(1) repeated lookups.
struct JeffJSICEntry {
    /// Raw pointer to the cached shape (identity comparison, no retain).
    var shapePtr: UnsafeRawPointer? = nil
    /// Bytecode offset this cache belongs to (for collision validation).
    var pc: Int = -1
    /// Property index into the object's prop array.
    var propOffset: Int = -1
    /// Cached `.writable` flag of the slot (valid while the shape matches:
    /// flag changes copy the shape, so identity covers it).
    var writable: Bool = false
    /// define_field transition target (retained): objects on `shapePtr` at
    /// this pc move to this shape when the field is added.
    var nextShapePtr: UnsafeRawPointer? = nil
    /// Prototype-chain entry (depth 1): the property lives on the receiver's
    /// direct prototype `holderPtr` (retained JeffJSObject) at `propOffset`,
    /// valid while the receiver's shape (which fixes its prototype and own
    /// properties) and the holder's shape `holderShapePtr` (retained) match.
    var holderPtr: UnsafeRawPointer? = nil
    var holderShapePtr: UnsafeRawPointer? = nil
}

/// Read through a prototype-chain IC entry. nil on any mismatch.
@inline(__always)
func jeffJS_icProtoHit(_ entry: JeffJSICEntry) -> JeffJSValue? {
    guard let hp = entry.holderPtr, let hsp = entry.holderShapePtr else { return nil }
    return Unmanaged<JeffJSObject>.fromOpaque(hp)._withUnsafeGuaranteedRef { h -> JeffJSValue? in
        guard h.shapeIdentity == hsp, entry.propOffset >= 0,
              entry.propOffset < h.propValues.count,
              h.extra(at: entry.propOffset) == nil else { return nil }
        return h.propValues[entry.propOffset]
    }
}

/// Reference-type IC table so interpreter can update entries in-place without COW copies.
///
/// Each cached shape is *retained* (Unmanaged.passRetained) for as long as its
/// entry lives. Without the pin, a dead shape's address can be recycled by a
/// new shape allocation and the pointer-identity check false-hits, reading
/// property slots through the wrong layout (observed as flaky engine crashes).
final class JeffJSInlineCache {
    static let size = 512
    static let mask = size - 1
    var entries: UnsafeMutableBufferPointer<JeffJSICEntry>

    init() {
        let ptr = UnsafeMutablePointer<JeffJSICEntry>.allocate(capacity: Self.size)
        ptr.initialize(repeating: JeffJSICEntry(), count: Self.size)
        entries = UnsafeMutableBufferPointer(start: ptr, count: Self.size)
    }

    deinit {
        for entry in entries {
            if let old = entry.shapePtr {
                Unmanaged<JeffJSShape>.fromOpaque(old).release()
            }
            if let old = entry.nextShapePtr {
                Unmanaged<JeffJSShape>.fromOpaque(old).release()
            }
            if let old = entry.holderPtr {
                Unmanaged<JeffJSObject>.fromOpaque(old).release()
            }
            if let old = entry.holderShapePtr {
                Unmanaged<JeffJSShape>.fromOpaque(old).release()
            }
        }
        entries.baseAddress?.deinitialize(count: Self.size)
        entries.baseAddress?.deallocate()
    }

    @inline(__always)
    func lookup(_ pc: Int) -> JeffJSICEntry {
        return entries[pc & Self.mask]
    }

    /// Release everything the entry at `idx` retains.
    @inline(__always)
    private func releaseEntry(_ idx: Int) {
        if let old = entries[idx].shapePtr {
            Unmanaged<JeffJSShape>.fromOpaque(old).release()
        }
        if let old = entries[idx].nextShapePtr {
            Unmanaged<JeffJSShape>.fromOpaque(old).release()
        }
        if let old = entries[idx].holderPtr {
            Unmanaged<JeffJSObject>.fromOpaque(old).release()
        }
        if let old = entries[idx].holderShapePtr {
            Unmanaged<JeffJSShape>.fromOpaque(old).release()
        }
    }

    /// Cache a depth-1 prototype hit: receivers on `receiverShape` find the
    /// property on `holder` (their prototype) at `propOffset`.
    @inline(__always)
    func updateProto(_ pc: Int, receiverShape: JeffJSShape, holder: JeffJSObject,
                     holderShape: JeffJSShape, propOffset: Int) {
        let idx = pc & Self.mask
        let rs = Unmanaged.passRetained(receiverShape).toOpaque()
        let hp = Unmanaged.passRetained(holder).toOpaque()
        let hs = Unmanaged.passRetained(holderShape).toOpaque()
        releaseEntry(idx)
        entries[idx] = JeffJSICEntry(
            shapePtr: UnsafeRawPointer(rs), pc: pc, propOffset: propOffset, writable: false,
            nextShapePtr: nil, holderPtr: UnsafeRawPointer(hp), holderShapePtr: UnsafeRawPointer(hs))
    }

    @inline(__always)
    func update(_ pc: Int, shape: JeffJSShape, propOffset: Int) {
        let idx = pc & Self.mask
        // Retain the new shape before releasing the old one (handles re-caching
        // the same shape without a transient zero refcount).
        let newPtr = Unmanaged.passRetained(shape).toOpaque()
        releaseEntry(idx)
        let writable = propOffset >= 0 && propOffset < shape.prop.count
            && shape.prop[propOffset].flags.contains(.writable)
        entries[idx] = JeffJSICEntry(
            shapePtr: UnsafeRawPointer(newPtr),
            pc: pc,
            propOffset: propOffset,
            writable: writable
        )
    }

    /// Cache a define_field transition: objects on `from` at `pc` move to `to`
    /// (both retained for the entry's lifetime).
    @inline(__always)
    func updateTransition(_ pc: Int, from: JeffJSShape, to: JeffJSShape) {
        let idx = pc & Self.mask
        let fromPtr = Unmanaged.passRetained(from).toOpaque()
        let toPtr = Unmanaged.passRetained(to).toOpaque()
        releaseEntry(idx)
        entries[idx] = JeffJSICEntry(
            shapePtr: UnsafeRawPointer(fromPtr),
            pc: pc,
            propOffset: to.propCount - 1,
            writable: true,
            nextShapePtr: UnsafeRawPointer(toPtr)
        )
    }
}

/// Describes a hot loop trace that the fast mini-interpreter can execute.
/// Created by the compiler's fuseBasicBlocks pass after label resolution.
final class TraceBlockInfo {
    /// First bytecode offset of the loop region (lowest backward-jump target
    /// among the merged overlapping loops that form this region)
    let entryPC: Int
    /// Bytecode offset just past the last backward jump of the region
    let exitPC: Int
    /// Where execution starts when this block is entered: the target of the
    /// backward jump that dispatched it. Equals entryPC for a simple loop; for
    /// a `for` loop laid out as header/body/update it may be the update pc.
    let startPC: Int
    /// Number of times this backward jump has been taken — saturates at 255
    var hitCount: UInt8 = 0
    /// Set to true when hitCount exceeds the hot threshold; interpreter then uses fast trace
    var isActive: Bool = false
    /// Consecutive trace runs that left the loop early (deopt); the block is
    /// disabled for good once this reaches the threshold in the interpreter.
    var deoptCount: UInt16 = 0
    var disabled: Bool = false
    /// Region contains calls / returns / closure-variable access: use the
    /// call-capable trace variant (see executeFastTraceLean).
    var hasCalls: Bool = false

    init(entryPC: Int, exitPC: Int, startPC: Int) {
        self.entryPC = entryPC
        self.exitPC = exitPC
        self.startPC = startPC
    }
}

/// Forward reference for `JeffJSFunctionBytecode`.
class JeffJSFunctionBytecode {
    var refCount: Int = 1
    var bytecodeLen: Int = 0
    var bytecode: [UInt8] = []

    /// Stable raw copy of `bytecode`, materialized lazily on first execution
    /// (when bytecode is final and immutable). The interpreter reads opcodes and
    /// operands through this pointer to avoid Swift Array bounds checks — the
    /// largest remaining per-opcode cost. Owned by this FB; freed in deinit, so
    /// the pointer is valid for the FB's entire lifetime (the FB is retained for
    /// the duration of any call that executes it).
    private var _bcBuffer: UnsafeMutableBufferPointer<UInt8>? = nil

    /// Raw pointer to the function's bytecode. Materializes `_bcBuffer` on first
    /// access. Must only be taken after `bytecode` is finalized (i.e. at execution
    /// time) — never mutate `bytecode` after this is called.
    /// Inlinable fast path for `bytecodePtr`: nil until first materialised.
    @inline(__always) var bcPtrFast: UnsafePointer<UInt8>? {
        if let b = _bcBuffer, let base = b.baseAddress { return UnsafePointer(base) }
        return nil
    }

    var bytecodePtr: UnsafePointer<UInt8> {
        if let b = _bcBuffer, let base = b.baseAddress {
            return UnsafePointer(base)
        }
        let n = bytecode.count
        let buf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(n, 1))
        if n > 0 {
            _ = buf.initialize(from: bytecode)
        } else {
            buf[0] = 0
        }
        _bcBuffer = buf
        return UnsafePointer(buf.baseAddress!)
    }

    deinit {
        _bcBuffer?.deallocate()
    }
    var fileName: JeffJSString?
    var lineNum: Int = 0
    var colNum: Int = 0
    var argCount: UInt16 = 0
    var varCount: UInt16 = 0
    var definedArgCount: UInt16 = 0
    var stackSize: UInt16 = 0
    var closureVarCount: UInt16 = 0
    /// Enter the fast trace at function entry (not only at loop back-edges).
    /// Cleared after repeated immediate deopts (see the interpreter).
    var traceEntryEnabled: Bool = true
    var traceEntryDeopts: UInt16 = 0
    /// Call-free function with at least one loop: run it in the lean trace
    /// variant from entry (set by the compiler's trace analysis).
    var traceLean: Bool = false
    var cpool: [JeffJSValue] = []
    var isGenerator: Bool = false
    var isAsyncFunc: Bool = false
    var isArrow: Bool = false
    var hasPrototype: Bool = false
    var hasSimpleParameterList: Bool = true
    var isDerivedClassConstructor: Bool = false
    var needHomeObject: Bool = false
    var isDirectOrIndirectEval: Bool = false
    var superCallAllowed: Bool = false
    var superAllowed: Bool = false
    var argumentsAllowed: Bool = false
    var hasDebug: Bool = false
    var backtrace: Bool = false
    var readOnly: Bool = false

    // Call-path caches: callInternal used to discover these via
    // `as? JeffJSFunctionBytecodeCompiled` — two dynamic casts per call.
    /// True when compiled in strict mode (JS_MODE_STRICT).
    var isStrictMode: Bool = false
    /// Local var index of a named function expression's self-binding, -1 if none.
    var selfRefVarIdx: Int = -1
    /// Closure-variable metadata (also on the Compiled subclass; mirrored here
    /// so createClosure avoids a downcast per closure creation).
    var closureVarsList: [JeffJSClosureVar] = []

    // MARK: - Inline Cache

    /// Lazily-allocated inline cache for property access sites.
    /// Reference type — interpreter updates entries in-place without COW.
    var ic: JeffJSInlineCache? = nil {
        didSet { icEntries = ic?.entries.baseAddress }
    }
    /// Raw pointer to `ic.entries` so the interpreter's hit path reads the
    /// table without retaining the cache object.
    var icEntries: UnsafeMutablePointer<JeffJSICEntry>? = nil

    /// Get or lazily create the IC table.
    @inline(__always)
    func getIC() -> JeffJSInlineCache {
        if let ic = ic { return ic }
        let newIC = JeffJSInlineCache()
        ic = newIC
        return newIC
    }

    // MARK: - Trace Blocks

    /// Trace blocks for hot loop optimization. Maps backward-jump target PC → trace info.
    /// Populated by JeffJSCompiler.fuseBasicBlocks() after bytecode compilation.
    /// nil until fuseBasicBlocks runs (saves memory for functions with no loops).
    var traceBlocks: [Int: TraceBlockInfo]?
}

// MARK: - Enums

/// GC object type tags (mirrors QuickJS `JS_GC_OBJ_TYPE_*`).
enum JSGCObjectTypeEnum: UInt8 {
    case jsObject       = 0
    case functionBytecode = 1
    case shape          = 2
    case varRef         = 3
    case asyncFunction  = 4
    case bigInt         = 5
    case bigFloat       = 6
    case bigDecimal     = 7
    case mapIteratorData = 8
    case arrayIteratorData = 9
    case regexpStringIteratorData = 10
}

/// QuickJS property flags (JS_PROP_*).
struct JeffJSPropertyFlags: OptionSet {
    let rawValue: UInt32

    static let configurable = JeffJSPropertyFlags(rawValue: 1 << 0)
    static let writable     = JeffJSPropertyFlags(rawValue: 1 << 1)
    static let enumerable   = JeffJSPropertyFlags(rawValue: 1 << 2)
    static let cWE          = JeffJSPropertyFlags(rawValue: 0x07) // C|W|E combined
    static let length       = JeffJSPropertyFlags(rawValue: 1 << 3)
    static let tmask        = JeffJSPropertyFlags(rawValue: 3 << 4) // 2-bit type field
    static let normal       = JeffJSPropertyFlags(rawValue: 0 << 4)
    static let getset       = JeffJSPropertyFlags(rawValue: 1 << 4)
    static let varref       = JeffJSPropertyFlags(rawValue: 2 << 4)
    static let autoinit     = JeffJSPropertyFlags(rawValue: 3 << 4)

    static let hasShift     = JeffJSPropertyFlags(rawValue: 1 << 8)
    static let hasConfigurable = JeffJSPropertyFlags(rawValue: 1 << 8)
    static let hasWritable  = JeffJSPropertyFlags(rawValue: 1 << 9)
    static let hasEnumerable = JeffJSPropertyFlags(rawValue: 1 << 10)
    static let hasGet       = JeffJSPropertyFlags(rawValue: 1 << 11)
    static let hasSet       = JeffJSPropertyFlags(rawValue: 1 << 12)
    static let hasValue     = JeffJSPropertyFlags(rawValue: 1 << 13)
    static let throwFlag    = JeffJSPropertyFlags(rawValue: 1 << 14)
    static let noAdd        = JeffJSPropertyFlags(rawValue: 1 << 16)
    static let noExotic     = JeffJSPropertyFlags(rawValue: 1 << 17)
}

// MARK: - C function type

/// Mirrors QuickJS `JSCFunctionType`.
enum JSCFunctionType {
    case generic( (JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue )
    case genericMagic( (JeffJSContext, JeffJSValue, [JeffJSValue], Int) -> JeffJSValue )
    case constructor( (JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue )
    case constructorOrFunc( (JeffJSContext, JeffJSValue, [JeffJSValue], Bool) -> JeffJSValue )
    case fFloat64( (Double) -> Double )
    case fFloat64_2( (Double, Double) -> Double )
    case getter( (JeffJSContext, JeffJSValue) -> JeffJSValue )
    case setter( (JeffJSContext, JeffJSValue, JeffJSValue) -> JeffJSValue )
    case getterMagic( (JeffJSContext, JeffJSValue, Int) -> JeffJSValue )
    case setterMagic( (JeffJSContext, JeffJSValue, JeffJSValue, Int) -> JeffJSValue )
    case iteratorNext( (JeffJSContext, JeffJSValue, [JeffJSValue], UnsafeMutablePointer<Int32>?, Int) -> JeffJSValue )
}

// MARK: - GC list node

/// Intrusive doubly-linked list node used by the GC.
/// Both prev and next are strong — GC lists require strong pointers to prevent
/// ARC from deallocating nodes that are still part of the list.
final class ListNode {
    var prev: ListNode?
    var next: ListNode?

    init() {
        self.prev = nil
        self.next = nil
    }

    /// Initialise as a self-referencing sentinel.
    func initSentinel() {
        prev = self
        next = self
    }

    /// Insert `self` before `node`.
    func insertBefore(_ node: ListNode) {
        self.prev = node.prev
        self.next = node
        node.prev?.next = self
        node.prev = self
    }

    /// Remove `self` from its list.
    func remove() {
        prev?.next = next
        next?.prev = prev
        prev = nil
        next = nil
    }

    var isEmpty: Bool {
        return next === self
    }
}

// MARK: - JeffJSGCObjectHeader

/// Base class for every GC-managed object.
class JeffJSGCObjectHeader {
    var refCount: Int
    var gcObjType: JSGCObjectTypeEnum
    var mark: Bool

    /// Intrusive position in the runtime's GC tracking lists, so removal is
    /// an O(1) swap-remove instead of a linear scan (removeGCObject was 98%
    /// of promise-chain time). Encoding: >= 0 → index in rt.gcObjects;
    /// -1 → not tracked; <= -2 → index (-2 - value) in rt.gcTmpObjects.
    var gcListIndex: Int = -1
    /// Back-pointer to the owning runtime so the zero-arg freeValue() can
    /// actually free the object when refCount hits 0.
    ///
    /// Strong, not weak: a weak reference here forced a side-table entry on
    /// EVERY GC object (formWeakReference per creation, weakLoadStrong per
    /// read, and slow-path retain/release on the runtime forever after).
    /// The runtime↔object cycle is broken explicitly by clearGCState()
    /// during runtime.free(), which nils this field on all tracked headers.
    var ownerRuntime: JeffJSRuntime?

    /// The currently active runtime. Set by JeffJSContext during init and eval
    /// so that newly created objects automatically know their owning runtime.
    /// nonisolated(unsafe) because JeffJS is single-threaded per runtime.
    /// Strong for the same side-table reason; runtime.free() clears it when
    /// it points at the runtime being freed.
    nonisolated(unsafe) static var activeRuntime: JeffJSRuntime?

    init(refCount: Int = 1,
         gcObjType: JSGCObjectTypeEnum = .jsObject,
         mark: Bool = false) {
        self.refCount = refCount
        self.gcObjType = gcObjType
        self.mark = mark
        self.ownerRuntime = JeffJSGCObjectHeader.activeRuntime
    }

    @discardableResult
    func retain() -> Self {
        refCount += 1
        return self
    }

    // MARK: - Refcount Tracking (for diagnostics)

    /// When true, tracks all refcount operations for leak detection.
    /// Stored literal (not a lazy global): a lazily-initialised static costs a
    /// swift_once-guarded addressor call on every read, and this is read on
    /// every object dup/free. Set from JeffJSConfig by JeffJSRuntime.init.
    nonisolated(unsafe) static var trackRefcounts: Bool = false

    /// Per-object high-water mark and current refcount, keyed by ObjectIdentifier.
    /// Only populated when trackRefcounts is true.
    nonisolated(unsafe) static var refcountLog: [ObjectIdentifier: RefcountEntry] = [:]

    struct RefcountEntry {
        var classID: Int
        var gcObjType: JSGCObjectTypeEnum
        var peakRefCount: Int
        var currentRefCount: Int
        var dupCount: Int    // total dupValue calls
        var freeCount: Int   // total freeValue calls
        var isAlive: Bool    // false if ARC deallocated
    }

    /// Call from dupValue to track increments.
    static func trackDup(_ hdr: JeffJSGCObjectHeader) {
        guard trackRefcounts else { return }
        let id = ObjectIdentifier(hdr)
        var entry = refcountLog[id] ?? RefcountEntry(
            classID: (hdr as? JeffJSObject)?.classID ?? -1,
            gcObjType: hdr.gcObjType,
            peakRefCount: hdr.refCount,
            currentRefCount: hdr.refCount,
            dupCount: 0, freeCount: 0, isAlive: true
        )
        entry.dupCount += 1
        entry.currentRefCount = hdr.refCount
        entry.peakRefCount = max(entry.peakRefCount, hdr.refCount)
        refcountLog[id] = entry
    }

    /// Call from freeValue to track decrements.
    static func trackFree(_ hdr: JeffJSGCObjectHeader) {
        guard trackRefcounts else { return }
        let id = ObjectIdentifier(hdr)
        var entry = refcountLog[id] ?? RefcountEntry(
            classID: (hdr as? JeffJSObject)?.classID ?? -1,
            gcObjType: hdr.gcObjType,
            peakRefCount: hdr.refCount + 1,
            currentRefCount: hdr.refCount,
            dupCount: 0, freeCount: 0, isAlive: true
        )
        entry.freeCount += 1
        entry.currentRefCount = hdr.refCount
        refcountLog[id] = entry
    }

    /// Register a newly created object.
    static func trackCreate(_ hdr: JeffJSGCObjectHeader) {
        guard trackRefcounts else { return }
        let id = ObjectIdentifier(hdr)
        refcountLog[id] = RefcountEntry(
            classID: (hdr as? JeffJSObject)?.classID ?? -1,
            gcObjType: hdr.gcObjType,
            peakRefCount: hdr.refCount,
            currentRefCount: hdr.refCount,
            dupCount: 0, freeCount: 0, isAlive: true
        )
    }

    /// Returns a summary of refcount imbalances.
    static func refcountReport() -> String {
        var lines: [String] = []
        var leakedByType: [String: (count: Int, totalRC: Int)] = [:]
        var zeroRC = 0
        var negRC = 0

        for (_, entry) in refcountLog {
            let typeStr: String
            if entry.classID >= 0 {
                typeStr = "obj(class=\(entry.classID))"
            } else {
                typeStr = "\(entry.gcObjType)"
            }

            if entry.currentRefCount < 0 {
                negRC += 1
                lines.append("  NEGATIVE RC: \(typeStr) rc=\(entry.currentRefCount) dup=\(entry.dupCount) free=\(entry.freeCount)")
            } else if entry.currentRefCount == 0 {
                zeroRC += 1
            } else {
                // refCount > 0 = leaked (never freed to 0)
                leakedByType[typeStr, default: (0, 0)].count += 1
                leakedByType[typeStr, default: (0, 0)].totalRC += entry.currentRefCount
            }
        }

        let total = refcountLog.count
        let leaked = total - zeroRC - negRC
        lines.insert("Refcount report: \(total) objects tracked, \(zeroRC) freed (rc=0), \(leaked) leaked (rc>0), \(negRC) over-freed (rc<0)", at: 0)

        if !leakedByType.isEmpty {
            let sorted = leakedByType.sorted { $0.value.count > $1.value.count }
            lines.append("  Leaked by type:")
            for (type, info) in sorted.prefix(10) {
                let avgRC = info.count > 0 ? info.totalRC / info.count : 0
                lines.append("    \(type): \(info.count) objects, avg rc=\(avgRC)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Reset tracking state.
    static func resetRefcountTracking() {
        refcountLog.removeAll()
    }

    func release() {
        refCount -= 1
    }
}

// MARK: - Supporting structs

/// Bound function data (`js_bound_function`).
struct JeffJSBoundFunction {
    var funcObj: JeffJSValue
    var thisVal: JeffJSValue
    var argc: Int
    var argv: [JeffJSValue]

    init(funcObj: JeffJSValue = .undefined,
         thisVal: JeffJSValue = .undefined,
         argc: Int = 0,
         argv: [JeffJSValue] = []) {
        self.funcObj = funcObj
        self.thisVal = thisVal
        self.argc = argc
        self.argv = argv
    }
}

/// For-in iterator data.
struct JeffJSForInIterator {
    var obj: JeffJSValue
    var isArray: Bool
    var arrayLength: UInt32
    var idx: UInt32

    init(obj: JeffJSValue = .undefined,
         isArray: Bool = false,
         arrayLength: UInt32 = 0,
         idx: UInt32 = 0) {
        self.obj = obj
        self.isArray = isArray
        self.arrayLength = arrayLength
        self.idx = idx
    }
}

/// ArrayBuffer data.
final class JeffJSArrayBuffer {
    var refCount: Int = 1
    var byteLength: Int = 0
    var detached: Bool = false
    var shared: Bool = false
    var data: [UInt8] = []
    var opaqueDealloc: ((Any?) -> Void)?
    var opaque: Any?

    init(byteLength: Int = 0) {
        self.byteLength = byteLength
        self.data = [UInt8](repeating: 0, count: byteLength)
    }
}

/// TypedArray data.
final class JeffJSTypedArray {
    var refCount: Int = 1
    var obj: JeffJSObject?
    var buffer: JeffJSObject?
    var classID: Int = 0
    var byteOffset: Int = 0
    var byteLength: Int = 0
    var length: Int = 0

    init() {}
}

/// Proxy data (`JSProxyData`).
struct JeffJSProxyData {
    var target: JeffJSValue
    var handler: JeffJSValue
    var isFunc: Bool
    var isRevoked: Bool

    init(target: JeffJSValue = .undefined,
         handler: JeffJSValue = .undefined,
         isFunc: Bool = false,
         isRevoked: Bool = false) {
        self.target = target
        self.handler = handler
        self.isFunc = isFunc
        self.isRevoked = isRevoked
    }
}

/// Promise reaction types.
enum JeffJSPromiseStateEnum: UInt8 {
    case pending   = 0
    case fulfilled = 1
    case rejected  = 2
}

/// Promise data (`JSPromiseData`).
final class JeffJSPromiseData {
    var promiseState: JeffJSPromiseStateEnum = .pending
    var promiseResult: JeffJSValue = .undefined
    var promiseFulfillReactions: [JeffJSPromiseReaction] = []
    var promiseRejectReactions: [JeffJSPromiseReaction] = []
    var isHandled: Bool = false

    init() {}
}

/// Async function execution state.
final class JeffJSAsyncFunctionState {
    var thisVal: JeffJSValue = .undefined
    var argc: Int = 0
    var throwFlag: Bool = false
    var isCompleted: Bool = false
    var resolveFunc: JeffJSValue = .undefined
    var rejectFunc: JeffJSValue = .undefined
    var frame: JeffJSStackFrame = JeffJSStackFrame()

    init() {}
}

/// Generator state.
enum JeffJSGeneratorStateEnum: UInt8 {
    case suspended_start  = 0
    case suspended_yield  = 1
    case suspended_yield_star = 2
    case executing        = 3
    case completed        = 4
}

/// Saved interpreter state for generator suspension/resumption.
/// When a generator yields, the entire execution context (program counter,
/// stack, locals, arguments) is captured here so that `.next()` can
/// re-enter the dispatch loop at the exact point where it left off.
struct GeneratorSavedState {
    var pc: Int
    var sp: Int
    var stack: [JeffJSValue]
    var varBuf: [JeffJSValue]
    var argBuf: [JeffJSValue]
    /// The bytecode function object that this generator was created from.
    /// Needed to restore the bytecode array, closure var refs, etc.
    var funcObj: JeffJSValue
    /// The `this` binding for the generator's execution context.
    var thisVal: JeffJSValue
    /// True if this state was saved from `initial_yield` (the generator
    /// hasn't executed any user code yet). When resuming from initial_yield,
    /// the resume value from `.next()` should NOT be pushed onto the stack
    /// because there is no yield expression to receive it.
    var isInitialYield: Bool = false
    /// For yield* delegation: the inner iterator being delegated to.
    /// When non-nil, the generator is in `suspended_yield_star` state
    /// and each .next() call should advance the inner iterator.
    var delegatedIter: JeffJSValue = .undefined
}

/// Generator data.
final class JeffJSGeneratorData {
    var state: JeffJSGeneratorStateEnum = .suspended_start
    var asyncState: JeffJSAsyncFunctionState = JeffJSAsyncFunctionState()
    /// Saved interpreter state from the last yield/initial_yield.
    /// Non-nil when the generator is in a suspended state.
    var savedState: GeneratorSavedState? = nil

    init() {}
}

/// Map / Set record entry.
final class JeffJSMapRecord {
    var refCount: Int = 1
    var map: JeffJSMapState?
    var key: JeffJSValue = .undefined
    var value: JeffJSValue = .undefined
    var hashNext: Int = -1
    var link: ListNode = ListNode()
    var empty: Bool = false

    init() {}
}

/// Map / Set state.
final class JeffJSMapState {
    var isWeak: Bool = false
    var records: [JeffJSMapRecord] = []
    var count: Int = 0
    var hashSize: Int = 0
    var hashTable: [Int] = []
    var recordListSentinel: ListNode = ListNode()

    init(isWeak: Bool = false) {
        self.isWeak = isWeak
        recordListSentinel.initSentinel()
    }
}

/// Global object extra data.
final class JeffJSGlobalObject {
    var globalVarCount: Int = 0
    var globalVarNames: [UInt32] = []
    var globalVarValues: [JeffJSValue] = []
    var varDefs: [JeffJSGlobalVarDef] = []

    init() {}
}

/// Global variable definition.
struct JeffJSGlobalVarDef {
    var flags: UInt8 = 0
    var atom: UInt32 = 0
}

/// Variable reference (closure upvalue).
///
/// When **not detached**, the var-ref is "live" — it reads/writes the
/// parent frame's local or arg slot via `parentFrame` + `varIdx`.
/// When **detached** (after `close_loc`), the current value is copied
/// into `value` and reads/writes go there instead.
final class JeffJSVarRef: JeffJSGCObjectHeader {
    /// Var-refs are shared by every closure capturing the same slot and are
    /// kept alive by their varRefs arrays (ARC); the detached value is
    /// released when the last closure lets go. The GC path clears `value`
    /// after releasing it, so this never double-frees.
    deinit { if isDetached, !value.isUndefined { value.freeValue() } }
    var isDetached: Bool
    var isArg: Bool
    var varIdx: UInt16

    /// The parent stack frame whose slots we point into while live.
    /// unowned(unsafe): frames are immortal (rt.allFrames), so no ARC here;
    /// this is read on every closure-variable access.
    unowned(unsafe) var parentFrame: JeffJSStackFrame?

    /// Direct pointer to the live slot in the parent frame's value buffer
    /// (set by createClosure for non-generator frames, cleared on detach).
    /// The hot get/put_var_ref path is then one load through this pointer
    /// instead of frame lookup + buf lookup + index arithmetic.
    var slot: UnsafeMutablePointer<JeffJSValue>? = nil

    /// Storage for the detached value (used after `close_loc`).
    var value: JeffJSValue

    /// Computed live-slot accessor.  When not detached, reads/writes go
    /// through the parent frame's unsafe buffer (if available) or arrays;
    /// when detached they fall back to `value`.
    var pvalue: JeffJSValue {
        get {
            if let p = slot { return p.pointee }
            guard !isDetached, let frame = parentFrame else { return value }
            // Prefer reading from the contiguous unsafe buffer (kept current by
            // the interpreter) over the frame arrays (which may be stale).
            if let buf = frame.buf {
                if isArg {
                    let idx = Int(varIdx)
                    return idx < frame.bufVarBase ? buf[idx] : .undefined
                } else {
                    let idx = Int(varIdx)
                    return buf[frame.bufVarBase + idx]
                }
            }
            // Fallback to frame arrays (when buf is not set, e.g. generator frames)
            if isArg {
                let idx = Int(varIdx)
                return idx < frame.argBuf.count ? frame.argBuf[idx] : .undefined
            } else {
                let idx = Int(varIdx)
                return idx < frame.varBuf.count ? frame.varBuf[idx] : .undefined
            }
        }
        set {
            if let p = slot { p.pointee = newValue; return }
            guard !isDetached, let frame = parentFrame else { value = newValue; return }
            // Write to both buf and frame arrays to keep them in sync
            if let buf = frame.buf {
                if isArg {
                    let idx = Int(varIdx)
                    if idx < frame.bufVarBase { buf[idx] = newValue }
                    if idx < frame.argBuf.count { frame.argBuf[idx] = newValue }
                } else {
                    let idx = Int(varIdx)
                    buf[frame.bufVarBase + idx] = newValue
                    if idx < frame.varBuf.count { frame.varBuf[idx] = newValue }
                }
            } else {
                if isArg {
                    let idx = Int(varIdx)
                    if idx < frame.argBuf.count { frame.argBuf[idx] = newValue }
                } else {
                    let idx = Int(varIdx)
                    if idx < frame.varBuf.count { frame.varBuf[idx] = newValue }
                }
            }
        }
    }

    init(isDetached: Bool = false,
         isArg: Bool = false,
         varIdx: UInt16 = 0,
         parentFrame: JeffJSStackFrame? = nil) {
        self.isDetached = isDetached
        self.isArg = isArg
        self.varIdx = varIdx
        self.parentFrame = parentFrame
        self.value = .undefined
        super.init(refCount: 1, gcObjType: .varRef)
    }
}

/// BigInt (arbitrary-precision integer).
final class JeffJSBigInt: JeffJSGCObjectHeader {
    var sign: Bool = false
    var len: Int = 0
    var limbs: [UInt64] = []

    override init(refCount: Int = 1,
                  gcObjType: JSGCObjectTypeEnum = .bigInt,
                  mark: Bool = false) {
        super.init(refCount: refCount, gcObjType: gcObjType, mark: mark)
    }
}

/// Call-stack frame.
/// Uses a class (not struct) because it self-references via `prevFrame`.
final class JeffJSStackFrame {
    /// Caller's frame. Strong, not weak: frames form a linear chain that
    /// releaseFrame explicitly breaks, and weak-reference side-table traffic
    /// (formWeakReference/weakLoadStrong) showed up per call in profiles.
    /// unowned(unsafe): frames are immortal — owned by the runtime's
    /// `allFrames` list and recycled through a free list — so caller links
    /// need no retain/release (two pairs per call otherwise).
    unowned(unsafe) var prevFrame: JeffJSStackFrame? = nil
    /// Free-list link (JeffJSRuntime.frameFreeListU); trivially copyable.
    var nextFree: Unmanaged<JeffJSStackFrame>? = nil
    /// True once argBuf/varBuf were materialised for this activation.
    var bufArraysLive: Bool = false
    var curFunc: JeffJSValue          = .undefined
    var thisVal: JeffJSValue          = .undefined
    var newTarget: JeffJSValue        = .undefined
    var curPC: Int                    = 0
    var argBuf: [JeffJSValue]         = []
    var argCount: Int                 = 0
    var varBuf: [JeffJSValue]         = []
    var varCount: Int                 = 0
    var spBase: Int                   = 0
    var sp: Int                       = 0
    /// Last receiver from a `get_field` opcode. Used as `this` fallback
    /// when `call` is used instead of `call_method` (transformMethodCalls
    /// can't handle ternary/complex args in method calls).
    var lastGetFieldReceiver: JeffJSValue = .undefined
    /// Bytecode pc of the get_field that stashed lastGetFieldReceiver.
    /// The stash is only valid for a call opcode IMMEDIATELY following that
    /// get_field — stale stashes (e.g. `throw obj.m` then a later `e()`)
    /// must not leak `obj` in as `this`.
    var lastGetFieldPC: Int = -1

    /// Contiguous unsafe buffer used by the interpreter's dispatch loop.
    /// Layout: [arg slots][var slots][value stack --->]
    /// The interpreter reads/writes this directly for zero-overhead access.
    /// frame.argBuf/varBuf are kept in sync for backward compatibility with
    /// JeffJSVarRef.pvalue, closure creation, and generator save/restore.
    var buf: UnsafeMutablePointer<JeffJSValue>? = nil
    var bufCapacity: Int              = 0
    var bufVarBase: Int               = 0  // offset where vars start (= argSlots)
    var bufSpBase: Int                = 0  // offset where value stack starts (= argSlots + varSlots)

    /// All live (non-detached) var-refs that point at this frame's slots.
    /// Populated by `fclosure`; consulted by `close_loc` to detach them.
    var liveVarRefs: [JeffJSVarRef]   = []
    /// Mirrors `!liveVarRefs.isEmpty` (Array.isEmpty was not inlined in the
    /// interpreter; this is read on every return).
    var hasLiveVarRefs: Bool = false

    init() {}

    // NOTE: The frame pool lives on JeffJSRuntime (acquireFrame/releaseFrame).
    // It used to be a static here, but static-var mutation costs a TLS-backed
    // exclusivity check per call and recycled frames across runtimes.
}

/// Shape property descriptor (one per own-property slot in the shape).
struct JeffJSShapeProperty {
    var hashNext: UInt32 = 0
    var flags: JeffJSPropertyFlags = []
    var atom: UInt32 = 0

    init(atom: UInt32 = 0, flags: JeffJSPropertyFlags = []) {
        self.atom = atom
        self.flags = flags
    }
}

// MARK: - Object payload enum

/// Union payload for `JeffJSObject`.  Mirrors the C union inside `JSObject`.
enum JeffJSObjectPayload {
    case opaque(Any?)

    case bytecodeFunc(
        functionBytecode: JeffJSFunctionBytecode?,
        varRefs: [JeffJSVarRef?],
        homeObject: JeffJSObject?
    )

    case cFunc(
        realm: JeffJSContext?,
        cFunction: JSCFunctionType,
        length: UInt8,
        cproto: UInt8,
        magic: Int16
    )

    case array(
        size: UInt32,
        values: [JeffJSValue],
        count: UInt32
    )

    case regexp(
        pattern: JeffJSString?,
        bytecode: JeffJSString?
    )

    case objectData(JeffJSValue)

    case boundFunction(JeffJSBoundFunction)

    case forInIterator(JeffJSForInIterator)

    case arrayBuffer(JeffJSArrayBuffer)

    case typedArray(JeffJSTypedArray)

    case mapState(JeffJSMapState)

    case generatorData(JeffJSGeneratorData)

    case proxyData(JeffJSProxyData)

    case promiseData(JeffJSPromiseData)

    case asyncFunctionData(JeffJSAsyncFunctionState)

    case globalObject(JeffJSGlobalObject)
}

// MARK: - JeffJSProperty

/// Property value union matching QuickJS `JSProperty`.
///
/// This is the value-level API for constructing/inspecting a single property.
/// Object STORAGE is split (see JeffJSObject.propValues / propExtra): the common
/// data-property case lives as a trivial `JeffJSValue` in `propValues` (zero ARC,
/// zero enum-witness per read); the rare accessor/varRef/autoInit cases live in
/// a parallel `JeffJSPropertyExtra` box. Use the object's `propEntry(at:)` /
/// `setPropEntry(at:_:)` / `appendProp(_:)` / `dataValue(at:)` helpers.
enum JeffJSProperty {
    case value(JeffJSValue)
    case getset(getter: JeffJSObject?, setter: JeffJSObject?)
    case varRef(JeffJSVarRef)
    case autoInit(realmAndId: UInt, opaque: Any?)
}

/// Out-of-line payload for the rare non-data property kinds. ARC-managed Swift
/// class, so getter/setter/varRef lifetimes are handled automatically exactly as
/// the enum's associated values were — no manual refcounting.
final class JeffJSPropertyExtra {
    enum Kind: UInt8 { case getset, varRef, autoInit }
    var kind: Kind
    var getter: JeffJSObject?
    var setter: JeffJSObject?
    var varRef: JeffJSVarRef?
    var autoRealmAndId: UInt
    var autoOpaque: Any?

    init(getter: JeffJSObject?, setter: JeffJSObject?) {
        self.kind = .getset; self.getter = getter; self.setter = setter
        self.varRef = nil; self.autoRealmAndId = 0; self.autoOpaque = nil
    }
    init(varRef: JeffJSVarRef) {
        self.kind = .varRef; self.varRef = varRef
        self.getter = nil; self.setter = nil; self.autoRealmAndId = 0; self.autoOpaque = nil
    }
    init(autoRealmAndId: UInt, opaque: Any?) {
        self.kind = .autoInit; self.autoRealmAndId = autoRealmAndId; self.autoOpaque = opaque
        self.getter = nil; self.setter = nil; self.varRef = nil
    }

    /// Reconstruct the enum form (cold paths).
    @inline(__always)
    func toProperty() -> JeffJSProperty {
        switch kind {
        case .getset:   return .getset(getter: getter, setter: setter)
        case .varRef:   return .varRef(varRef!)
        case .autoInit: return .autoInit(realmAndId: autoRealmAndId, opaque: autoOpaque)
        }
    }
}


// MARK: - Fast array storage (reference type, avoids COW)

/// Mutable, reference-type backing store for array payloads.
/// Used by the interpreter's push fast path so that appending an element
/// doesn't trigger Swift copy-on-write of the `[JeffJSValue]` inside the
/// `JeffJSObjectPayload.array` enum case.
final class JeffJSFastArrayStorage {
    var values: ContiguousArray<JeffJSValue>
    var count: UInt32

    init(values: ContiguousArray<JeffJSValue>, count: UInt32) {
        self.values = values
        self.count = count
    }

    /// Append a value and return the new count.
    @inline(__always)
    func push(_ value: JeffJSValue) -> UInt32 {
        let idx = Int(count)
        if idx >= values.count {
            let newCap = max(idx + 1, values.count * 2 + 8)
            values.reserveCapacity(newCap)
            let fillCount = newCap - values.count
            for _ in 0..<fillCount { values.append(.undefined) }
        }
        values[idx] = value
        count += 1
        return count
    }
}

// MARK: - JeffJSObject

/// Core object representation.  Mirrors QuickJS `JSObject`.
final class JeffJSObject: JeffJSGCObjectHeader {

    // -- Object flags (packed as individual bools to keep things readable) ----

    var isStdArrayPrototype: Bool       = false
    var extensible: Bool                = true
    var freeMark: Bool                  = false
    var isExotic: Bool                  = false
    var fastArray: Bool                 = false
    var isConstructor: Bool             = false
    var hasImmutablePrototype: Bool     = false
    var tmpMark: Bool                   = false
    var isHTMLDDA: Bool                 = false
    /// The context's global object (freeObject tripwire; never recycled).
    var isProtectedGlobal: Bool         = false

    // -- Class & weak-ref ----------------------------------------------------

    var classID: Int                    = 0
    var weakrefCount: UInt32            = 0

    // -- Shape / properties --------------------------------------------------

    var shape: JeffJSShape?             = nil {
        didSet { shapeIdentity = shape.map { UnsafeRawPointer(Unmanaged.passUnretained($0).toOpaque()) } }
    }
    /// Unretained identity of `shape` for inline-cache checks: comparing
    /// this avoids loading (retaining) the shape reference on every access.
    var shapeIdentity: UnsafeRawPointer? = nil

    /// Split property storage (see JeffJSProperty). `propValues` holds the data
    /// value for every slot (`.undefined` for accessor/varRef/autoInit slots);
    /// trivial ContiguousArray → no element ARC, no array bridging, no
    /// enum-witness per access. `propExtra` is the parallel array (same length),
    /// nil for plain data slots. Data values keep the existing manual refcount
    /// discipline (dup on read, freeValue on overwrite/object-free).
    /// INVARIANT: propValues.count == propExtra.count.
    /// Access via propEntry(at:)/setPropEntry(at:_:)/appendProp(_:)/dataValue(at:).
    var propValues = JeffJSPropStorage()
    var propExtra: ContiguousArray<JeffJSPropertyExtra?> = [] {
        didSet { propExtraCount = propExtra.count }
    }
    /// `propExtra.count` mirrored in a plain field: the hot `extra(at:)`
    /// test then reads one Int instead of the array buffer.
    var propExtraCount: Int = 0

    // -- First weak ref in chain ---------------------------------------------

    var firstWeakRef: AnyObject?        = nil

    // -- Payload (union) -----------------------------------------------------

    var payload: JeffJSObjectPayload    = .opaque(nil)

    // -- Denormalized .bytecodeFunc payload (call-path fast fields) -----------
    // Pattern-matching `case .bytecodeFunc(...) = payload` copies the enum
    // (retaining the FB and the varRefs array) on every JS call. The hot call
    // path reads these instead; they are kept in sync at every payload write.
    var fbFast: JeffJSFunctionBytecode? = nil {
        didSet { fbFastU = fbFast.map { Unmanaged.passUnretained($0) } }
    }
    /// Unmanaged mirror of `fbFast` for the trace's call path: a plain load,
    /// where reading the strong optional retains and releases per call.
    var fbFastU: Unmanaged<JeffJSFunctionBytecode>? = nil
    var varRefsFast: [JeffJSVarRef?]    = [] {
        didSet {
            // Mirror as an unmanaged raw buffer for the fast trace: no array
            // retain per call and no element retain per access. The array
            // keeps the var-refs alive, so unretained pointers are safe.
            if let p = varRefsRaw { p.deallocate(); varRefsRaw = nil; varRefsRawCount = 0 }
            if !varRefsFast.isEmpty {
                let p = UnsafeMutablePointer<Unmanaged<JeffJSVarRef>?>.allocate(capacity: varRefsFast.count)
                var i = 0
                for vr in varRefsFast {
                    if let vr = vr { p[i] = Unmanaged.passUnretained(vr) } else { p[i] = nil }
                    i += 1
                }
                varRefsRaw = p
                varRefsRawCount = varRefsFast.count
            }
        }
    }
    var varRefsRaw: UnsafeMutablePointer<Unmanaged<JeffJSVarRef>?>? = nil
    var varRefsRawCount: Int = 0

    // -- Fast array storage (reference-type bypass for COW avoidance) --------
    // When non-nil, this is the authoritative backing store for the array.
    // Used by the interpreter's Array.prototype.push fast path to avoid
    // the COW copy overhead of enum destructuring on every push.
    // Lazily populated by fastArrayPush(); synced back to payload when
    // external code reads .array payload via syncArrayPayload().
    var _fastArrayValues: JeffJSFastArrayStorage?

    // -- Arrow function lexical `this` capture --------------------------------
    // When an arrow function closure is created, the enclosing function's
    // `this` value is stored here so that `push_this` inside the arrow
    // function returns the lexical `this` instead of the call-site `this`.
    var arrowThisVal: JeffJSValue? = nil

    // -- Lazy function prototype ----------------------------------------------
    // Plain function closures defer building `F.prototype = { constructor: F }`
    // (an object + shape + two property defines per closure) until the first
    // read of `.prototype`. Mirrors QuickJS's JS_PROP_AUTOINIT.
    var needsLazyPrototype: Bool = false

    // -- Associated storage (moved from objc_setAssociatedObject) ----------
    var storedProto: JeffJSObject? = nil
    var storedCFunction: ((JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue)? = nil
    var storedCFunctionLength: Int = 0
    var storedPrimitiveValue: JeffJSValue = .undefined

    // -- Lifecycle -----------------------------------------------------------

    override init(refCount: Int = 1,
                  gcObjType: JSGCObjectTypeEnum = .jsObject,
                  mark: Bool = false) {
        super.init(refCount: refCount, gcObjType: gcObjType, mark: mark)
    }

    deinit { propValues.deallocateStorage() }
}

extension JeffJSObject {
    /// Recycle-pool eligibility (see JeffJSObjectPool.swift): a plain,
    /// non-exotic object holding only data slots, with no weak references,
    /// function payload or auxiliary storage. Cheap field tests only.
    @inline(__always) var isPoolable: Bool {
        classID == JeffJSClassID.object.rawValue && !isExotic && !fastArray && !isProtectedGlobal
            && !hasImmutablePrototype && !isHTMLDDA && !isStdArrayPrototype && !isConstructor
            && firstWeakRef == nil && propExtra.isEmpty && gcListIndex == -1
            && _fastArrayValues == nil && storedPrimitiveValue.isUndefined && fbFast == nil
    }
}

// MARK: - Well-known class IDs (subset)

/// Mirrors QuickJS `JS_CLASS_*` enum values.
/// MUST match JSClassID in JeffJSConstants.swift exactly.
enum JeffJSClassID: Int {
    case object          = 1
    case array           = 2
    case error           = 3
    case number          = 4
    case string          = 5
    case boolean         = 6
    case symbol          = 7
    case arguments       = 8
    case mappedArguments = 9
    case date            = 10
    case moduleNamespace = 11
    case cFunction       = 12
    case bytecodeFunction = 13
    case boundFunction   = 14
    case cFunctionData   = 15     // JS_CLASS_C_FUNCTION_DATA — was missing!
    case generatorFunction = 16
    case forInIterator   = 17
    case regexp          = 18
    case arrayBuffer     = 19
    case sharedArrayBuffer = 20
    case uint8cArray     = 21
    case int8Array       = 22
    case uint8Array      = 23
    case int16Array      = 24
    case uint16Array     = 25
    case int32Array      = 26
    case uint32Array     = 27
    case bigInt64Array   = 28
    case bigUint64Array  = 29
    case float32Array    = 30
    case float64Array    = 31
    case dataView        = 32
    case bigInt          = 33     // JS_CLASS_BIG_INT — was missing!
    case map             = 34
    case set             = 35
    case weakMap         = 36
    case weakSet         = 37
    case mapIterator     = 38
    case setIterator     = 39
    case arrayIterator   = 40
    case stringIterator  = 41
    case regexpStringIterator = 42  // JS_CLASS_REGEXP_STRING_ITERATOR — was missing!
    case generatorObject = 43
    case proxy           = 44
    case promise         = 45
    case promiseResolveFunction = 46
    case promiseRejectFunction  = 47
    case asyncFunction   = 48
    case asyncFunctionResolve = 49
    case asyncFunctionReject  = 50
    case asyncGeneratorFunction = 51
    case asyncGeneratorObject   = 52
    case asyncFromSyncIterator = 53  // JS_CLASS_ASYNC_FROM_SYNC_ITERATOR — was missing!
    case weakRef         = 54
    case finalizationRegistry = 55
    case callSite        = 56     // JS_CLASS_CALL_SITE
    case globalObject    = 57

    static let initialCount: UInt16 = 58
}

// MARK: - Object operations

/// Create a new JS object with a given prototype and class ID.
/// Mirrors `JS_NewObjectProtoClass`.
func jeffJS_createObject(ctx: JeffJSContext,
                         proto: JeffJSObject?,
                         classID: UInt16) -> JeffJSObject {
    let obj = JeffJSObject(refCount: 1, gcObjType: .jsObject, mark: false)
    obj.classID = Int(classID)
    obj.extensible = true

    // If no explicit prototype was given, look up the class prototype from the
    // context's classProto array.  This ensures that built-in constructors like
    // FinalizationRegistry (which pass proto: nil) get the correct prototype so
    // that instanceof works.
    var resolvedProto = proto
    if resolvedProto == nil {
        let cid = Int(classID)
        if cid < ctx.classProto.count {
            let cpVal = ctx.classProto[cid]
            if cpVal.isObject {
                resolvedProto = cpVal.toObject()
            }
        }
    }

    // Create an initial shape that references the prototype.
    obj.shape = jeffJS_rootShape(ctx, proto: resolvedProto)
    // Set the canonical prototype so getPropertyInternal's prototype-chain walk
    // (which reads obj.proto, not shape.proto) can find inherited methods.
    obj.proto = resolvedProto
    obj.clearProps()
    obj.payload = .opaque(nil)

    return obj
}

/// Find an own property on `obj` by its atom key and return its slot index,
/// or -1 if absent.  Hash-table lookup only — every property writer maintains
/// the shape hash (see `addShapeProperty` / `jeffJS_appendOwnProperty`), so no
/// linear fallback is needed.  This is the hot-path primitive: it returns a
/// plain Int, avoiding the `(JeffJSShapeProperty?, JeffJSProperty?)` tuple
/// copies that dominate profiles when enums with payloads cross function
/// boundaries.
///
/// Mirrors `find_own_property` in QuickJS.
@inline(__always)
func jeffJS_findOwnPropertyIndex(obj: JeffJSObject, atom: UInt32) -> Int {
    guard let shape = obj.shape else { return -1 }
    guard let idx = findShapeProperty(shape, atom) else { return -1 }
    // Soft-recover shape/prop desync: pad missing value slots so the caller
    // can index obj.propValues[idx] directly.
    if idx >= obj.propValues.count {
        while obj.propValues.count < shape.prop.count {
            obj.appendDataValue(.undefined)
        }
    }
    return idx
}

/// Find an own property on `obj` by its atom key.
/// Returns a tuple of the shape-property descriptor and the property storage
/// entry, or `(nil, nil)` if not found.
///
/// Compatibility wrapper around `jeffJS_findOwnPropertyIndex` for callers
/// that want the descriptor pair; hot paths should use the index form.
func jeffJS_findOwnProperty(obj: JeffJSObject,
                             atom: UInt32) -> (JeffJSShapeProperty?, JeffJSProperty?) {
    let idx = jeffJS_findOwnPropertyIndex(obj: obj, atom: atom)
    guard idx >= 0, let shape = obj.shape else { return (nil, nil) }
    let prop = idx < obj.propValues.count ? obj.propEntry(at: idx) : nil
    return (shape.prop[idx], prop)
}

/// Append a brand-new own data property to `obj`, maintaining the shape hash
/// table and propCount.  The caller must know the atom is not already present.
/// Use this instead of appending to `shape.prop` directly — raw appends bypass
/// the hash table and break `jeffJS_findOwnPropertyIndex`.
func jeffJS_appendOwnProperty(_ ctx: JeffJSContext,
                              _ obj: JeffJSObject,
                              atom: UInt32,
                              flags: JeffJSPropertyFlags,
                              value: JeffJSValue) {
    guard obj.shape != nil else { return }
    jeffJS_objectAddShapeProperty(ctx, obj, atom: atom, flags: flags.rawValue)
    obj.appendDataValue(value)
}

/// Add a new own property to `obj`.
/// Returns the new property entry on success, `nil` on failure (e.g. if the
/// object is not extensible).
///
/// Mirrors `add_property` in QuickJS.
@discardableResult
func jeffJS_addProperty(ctx: JeffJSContext,
                         obj: JeffJSObject,
                         atom: UInt32,
                         flags: JeffJSPropertyFlags) -> JeffJSProperty? {
    // Non-extensible objects cannot gain properties.
    if !obj.extensible {
        return nil
    }

    // Check whether the property already exists.
    let (existing, _) = jeffJS_findOwnProperty(obj: obj, atom: atom)
    if existing != nil {
        return nil // duplicate
    }

    // Add a new ShapeProperty via the transition-aware helper (may move the
    // object onto a shared shape, so re-read obj.shape afterwards).
    guard obj.shape != nil else { return nil }
    jeffJS_objectAddShapeProperty(ctx, obj, atom: atom, flags: flags.rawValue)

    // Append the corresponding value slot.
    let propEntry: JeffJSProperty
    if flags.contains(.getset) {
        propEntry = .getset(getter: nil, setter: nil)
    } else if flags.contains(.varref) {
        propEntry = .varRef(JeffJSVarRef())
    } else if flags.contains(.autoinit) {
        propEntry = .autoInit(realmAndId: 0, opaque: nil)
    } else {
        propEntry = .value(.undefined)
    }
    obj.appendProp(propEntry)

    // Invariant: shape.prop and obj.propValues must be the same length.
    // Use soft check instead of assert to avoid crashing in debug builds.
    if let shape = obj.shape, shape.prop.count != obj.propValues.count {
        // Recover by padding obj.propValues to match shape
        while obj.propValues.count < shape.prop.count {
            obj.appendDataValue(.undefined)
        }
    }

    return propEntry
}

/// Delete an own property identified by `atom`.
/// Returns `true` if the property was found and removed, `false` otherwise.
///
/// Mirrors `delete_property` in QuickJS.
func jeffJS_deleteProperty(ctx: JeffJSContext,
                            obj: JeffJSObject,
                            atom: UInt32) -> Bool {
    guard let shape = obj.shape else { return false }

    guard let idx = findShapeProperty(shape, atom) else {
        return false
    }

    // Non-configurable properties cannot be deleted.
    let sprop = shape.prop[idx]
    if !sprop.flags.contains(.configurable) {
        return false
    }

    // Free the property value.
    if idx < obj.propValues.count {
        switch obj.propEntry(at: idx) {
        case .value(let val):
            val.freeValue()
        case .getset(let getter, let setter):
            if let g = getter { JeffJSValue.makeObject(g).freeValue() }
            if let s = setter { JeffJSValue.makeObject(s).freeValue() }
        default:
            break
        }
        // Mark as deleted (keep slot to preserve indices for hash table)
        obj.setPropEntry(at: idx, .value(.undefined))
    }

    // Mark the shape property as deleted by zeroing the atom
    // (keeps indices stable so hash table entries remain valid).
    // The shape may be shared: give this object a private copy first.
    prepareShapeUpdate(ctx, obj)
    if let s = obj.shape, idx < s.prop.count {
        s.prop[idx].atom = 0
        s.prop[idx].flags = []
    }

    return true
}

// MARK: - Object helpers

extension JeffJSObject {

    /// Quick check: is this object callable?
    var isCallable: Bool {
        switch payload {
        case .bytecodeFunc, .cFunc, .boundFunction:
            return true
        case .proxyData(let pd):
            return pd.isFunc
        default:
            return false
        }
    }

    /// Quick check: is this an array (fast path)?
    var isArray: Bool {
        return classID == JeffJSClassID.array.rawValue
    }

    /// Return the property count (derived from the shape).
    var propertyCount: Int {
        return shape?.propCount ?? 0
    }

    // MARK: - Split property-storage accessors
    // (All O(1). Hot paths read `propValues`/`propExtra` directly; these are
    // the convenience API for warm/cold paths that want a JeffJSProperty.)

    /// Number of property slots.
    @inline(__always) var propCount: Int { propValues.count }

    /// The data value at slot `i` (.undefined for accessor/varRef/autoInit).
    @inline(__always) func dataValue(at i: Int) -> JeffJSValue { propValues[i] }

    /// The rare-case box at slot `i`, or nil for a plain data slot.
    /// `propExtra` is allocated lazily: it stays EMPTY while every slot is a
    /// plain data slot (the common case), saving one array allocation per
    /// object. INVARIANT: propExtra.isEmpty || propExtra.count == propValues.count.
    @inline(__always) func extra(at i: Int) -> JeffJSPropertyExtra? {
        i < propExtraCount ? propExtra[i] : nil
    }

    /// Store a box at slot `i`, materialising `propExtra` (nil-padded) on
    /// the first non-nil box.
    @inline(__always) func setExtraSlot(_ i: Int, _ e: JeffJSPropertyExtra?) {
        if propExtra.count < propValues.count {
            if e == nil { return }
            propExtra.append(contentsOf: repeatElement(nil, count: propValues.count - propExtra.count))
        }
        propExtra[i] = e
    }

    /// Reconstruct the enum form for slot `i`. O(1); cheap for data slots.
    @inline(__always) func propEntry(at i: Int) -> JeffJSProperty {
        if let e = extra(at: i) { return e.toProperty() }
        return .value(propValues[i])
    }

    /// Overwrite slot `i` with a property value (does NOT free the previous
    /// value — callers that own the old value free it explicitly, matching the
    /// prior `obj.prop[i] = ...` semantics).
    @inline(__always) func setPropEntry(at i: Int, _ p: JeffJSProperty) {
        switch p {
        case .value(let v):
            propValues[i] = v; setExtraSlot(i, nil)
        case .getset(let g, let s):
            propValues[i] = .undefined; setExtraSlot(i, JeffJSPropertyExtra(getter: g, setter: s))
        case .varRef(let vr):
            propValues[i] = .undefined; setExtraSlot(i, JeffJSPropertyExtra(varRef: vr))
        case .autoInit(let rid, let op):
            propValues[i] = .undefined; setExtraSlot(i, JeffJSPropertyExtra(autoRealmAndId: rid, opaque: op))
        }
    }

    /// Append a new property slot.
    @inline(__always) func appendProp(_ p: JeffJSProperty) {
        switch p {
        case .value(let v):
            propValues.append(v); if !propExtra.isEmpty { propExtra.append(nil) }
        case .getset(let g, let s):
            propValues.append(.undefined); setExtraSlot(propValues.count - 1, JeffJSPropertyExtra(getter: g, setter: s))
        case .varRef(let vr):
            propValues.append(.undefined); setExtraSlot(propValues.count - 1, JeffJSPropertyExtra(varRef: vr))
        case .autoInit(let rid, let op):
            propValues.append(.undefined); setExtraSlot(propValues.count - 1, JeffJSPropertyExtra(autoRealmAndId: rid, opaque: op))
        }
    }

    /// Append a plain data-value slot (fast path; no enum).
    @inline(__always) func appendDataValue(_ v: JeffJSValue) {
        propValues.append(v); if !propExtra.isEmpty { propExtra.append(nil) }
    }

    /// Clear all property slots (equivalent to the old `obj.prop = []`).
    @inline(__always) func clearProps() {
        propValues.removeAll(keepingCapacity: false)
        propExtra.removeAll(keepingCapacity: false)
    }

    /// Replace all slots from an array of entries (cold; e.g. compaction).
    func replaceProps(_ entries: [JeffJSProperty]) {
        propValues.removeAll(keepingCapacity: true)
        propExtra.removeAll(keepingCapacity: true)
        propValues.reserveCapacity(entries.count)
        propExtra.reserveCapacity(entries.count)
        for p in entries { appendProp(p) }
    }

    /// Lookup a property value by atom, returning `.undefined` if absent.
    func getOwnPropertyValue(atom: UInt32) -> JeffJSValue {
        let idx = jeffJS_findOwnPropertyIndex(obj: self, atom: atom)
        guard idx >= 0, idx < propValues.count else { return .undefined }
        // Data slots only (matches the old `if case .value`).
        if extra(at: idx) == nil { return propValues[idx] }
        return .undefined
    }

    /// Set a property value by atom.  Returns `true` on success.
    @discardableResult
    func setOwnPropertyValue(atom: UInt32, value: JeffJSValue) -> Bool {
        let idx = jeffJS_findOwnPropertyIndex(obj: self, atom: atom)
        guard idx >= 0, idx < propValues.count else { return false }
        propValues[idx] = value; setExtraSlot(idx, nil)
        return true
    }

    /// Number of elements for a fast array.
    var arrayCount: UInt32 {
        if let storage = _fastArrayValues { return storage.count }
        if case .array(_, _, let c) = payload { return c }
        return 0
    }

    /// Direct access to fast-array element at `index`.
    func getArrayElement(_ index: UInt32) -> JeffJSValue {
        if let storage = _fastArrayValues {
            guard index < storage.count, Int(index) < storage.values.count else { return .undefined }
            return storage.values[Int(index)]
        }
        if case .array(_, let vals, let count) = payload {
            guard index < count, Int(index) < vals.count else { return .undefined }
            return vals[Int(index)]
        }
        return .undefined
    }

    /// Set fast-array element.  Grows the backing array if needed.
    /// Limits growth factor to prevent sparse arrays from allocating
    /// excessively large backing stores (#21).
    @discardableResult
    func setArrayElement(_ index: UInt32, value: JeffJSValue) -> Bool {
        // If ref-type storage is active, use it directly
        if let storage = _fastArrayValues {
            let idx = Int(index)
            if idx >= storage.values.count {
                let minRequired = idx + 1
                let growthTarget = max(minRequired, storage.values.count * 2)
                let maxSafe = max(minRequired, Int(storage.count) * 4 + 8)
                let newSize = min(growthTarget, maxSafe)
                storage.values.reserveCapacity(newSize)
                let fillCount = newSize - storage.values.count
                for _ in 0..<fillCount { storage.values.append(.undefined) }
            }
            if index < storage.count { storage.values[idx].freeValue() }   // overwrite releases the old element
            storage.values[idx] = value
            if index >= storage.count { storage.count = index + 1 }
            return true
        }

        guard case .array(var size, var vals, var count) = payload else { return false }

        let idx = Int(index)
        if idx >= vals.count {
            // Cap growth: don't allocate more than 2x current count + 8,
            // to prevent arr[1_000_000] = x from allocating 1M slots.
            let minRequired = idx + 1
            let growthTarget = max(minRequired, vals.count * 2)
            let maxSafe = max(minRequired, Int(count) * 4 + 8)
            let newSize = min(growthTarget, maxSafe)
            vals.reserveCapacity(newSize)
            vals.append(contentsOf: repeatElement(JeffJSValue.undefined, count: newSize - vals.count))
            size = UInt32(newSize)
        }
        if index < count { vals[idx].freeValue() }   // overwrite releases the old element
        vals[idx] = value
        if index >= count { count = index + 1 }
        payload = .array(size: size, values: vals, count: count)
        return true
    }

    /// Shrink a fast array to `newLen` elements, releasing the dropped
    /// element references and clearing their slots (so later growth cannot
    /// resurrect stale references). No-op when `newLen` >= count.
    func truncateFastArray(to newLen: Int) {
        if let storage = _fastArrayValues {
            let cur = Int(storage.count)
            if newLen >= cur { return }
            var i = max(newLen, 0)
            while i < cur && i < storage.values.count {
                storage.values[i].freeValue(); storage.values[i] = .undefined; i += 1
            }
            storage.count = UInt32(max(newLen, 0))
        } else if case .array(let size, var vals, let count) = payload {
            let cur = Int(count)
            if newLen >= cur { return }
            var i = max(newLen, 0)
            while i < cur && i < vals.count { vals[i].freeValue(); vals[i] = .undefined; i += 1 }
            payload = .array(size: size, values: vals, count: UInt32(max(newLen, 0)))
        }
    }

    /// Append a value to the end of a fast array, returning the new count.
    /// Uses the reference-type `_fastArrayValues` to avoid COW copy overhead.
    /// On first call, lazily migrates from the `.array` payload to the
    /// ref-type storage. Returns 0 if the object is not a fast array.
    @inline(__always)
    func fastArrayPush(_ value: JeffJSValue) -> UInt32 {
        // Fast path: ref-type storage already active
        if let storage = _fastArrayValues {
            return storage.push(value)
        }
        // Lazy init: migrate from enum payload to ref-type storage
        guard case .array(_, let vals, let count) = payload else { return 0 }
        let storage = JeffJSFastArrayStorage(
            values: ContiguousArray(vals),
            count: count
        )
        _fastArrayValues = storage
        return storage.push(value)
    }

    /// Sync the ref-type fast array storage back into the `.array` payload.
    /// Must be called before any code that reads the `.array` enum case
    /// after a series of fastArrayPush calls.
    func syncArrayPayload() {
        guard let storage = _fastArrayValues else { return }
        payload = .array(
            size: UInt32(storage.values.count),
            values: Array(storage.values),
            count: storage.count
        )
    }
}

// MARK: - Debug helpers

extension JeffJSObject: CustomDebugStringConvertible {
    var debugDescription: String {
        let className: String
        if let cid = JeffJSClassID(rawValue: classID) {
            className = String(describing: cid)
        } else {
            className = "classID(\(classID))"
        }
        return "<JeffJSObject \(className) props=\(propCount) rc=\(refCount)>"
    }
}

extension JeffJSProperty: CustomDebugStringConvertible {
    var debugDescription: String {
        switch self {
        case .value(let v):
            return ".value(\(v.debugDescription))"
        case .getset(let g, let s):
            return ".getset(get:\(g != nil), set:\(s != nil))"
        case .varRef(let vr):
            return ".varRef(idx:\(vr.varIdx))"
        case .autoInit(let rid, _):
            return ".autoInit(id:\(rid))"
        }
    }
}

// =============================================================================
// MARK: - JeffJSObj (Zero-ARC Object Handle)
// =============================================================================

/// Zero-ARC handle to a JeffJSObject. Value type — no retain/release on copy.
/// The underlying object's lifetime is managed by JS-level refcount + GC,
/// NOT by Swift ARC. This is the Swift equivalent of C's `JSObject*`.
///
/// Usage:
///   let handle = val.obj!          // extract from JeffJSValue, zero ARC
///   let id = handle.classID        // access property, optimizer elides ARC
///   handle.refCount += 1           // direct refcount manipulation
///   if handle === other { ... }    // identity comparison via pointer
struct JeffJSObj {
    let _ptr: UnsafeMutableRawPointer

    @inline(__always)
    init(_ ptr: UnsafeMutableRawPointer) {
        _ptr = ptr
    }

    /// Get the underlying JeffJSObject reference.
    /// With -O, ARC is elided when the result is used immediately and doesn't escape.
    @inline(__always)
    var _obj: JeffJSObject {
        unsafeBitCast(_ptr, to: JeffJSObject.self)
    }

    // MARK: - GC Header Fields (from JeffJSGCObjectHeader)

    @inline(__always) var refCount: Int {
        get { _obj.refCount }
        nonmutating set { _obj.refCount = newValue }
    }

    @inline(__always) var gcObjType: JSGCObjectTypeEnum {
        get { _obj.gcObjType }
        nonmutating set { _obj.gcObjType = newValue }
    }

    @inline(__always) var mark: Bool {
        get { _obj.mark }
        nonmutating set { _obj.mark = newValue }
    }

    // MARK: - JeffJSObject Fields

    @inline(__always) var classID: Int {
        get { _obj.classID }
        nonmutating set { _obj.classID = newValue }
    }

    @inline(__always) var extensible: Bool {
        get { _obj.extensible }
        nonmutating set { _obj.extensible = newValue }
    }

    @inline(__always) var isConstructor: Bool {
        get { _obj.isConstructor }
        nonmutating set { _obj.isConstructor = newValue }
    }

    @inline(__always) var isExotic: Bool {
        _obj.isExotic
    }

    @inline(__always) var fastArray: Bool {
        get { _obj.fastArray }
        nonmutating set { _obj.fastArray = newValue }
    }

    @inline(__always) var isHTMLDDA: Bool {
        _obj.isHTMLDDA
    }

    @inline(__always) var tmpMark: Bool {
        get { _obj.tmpMark }
        nonmutating set { _obj.tmpMark = newValue }
    }

    @inline(__always) var isStdArrayPrototype: Bool {
        _obj.isStdArrayPrototype
    }

    @inline(__always) var hasImmutablePrototype: Bool {
        _obj.hasImmutablePrototype
    }

    @inline(__always) var freeMark: Bool {
        get { _obj.freeMark }
        nonmutating set { _obj.freeMark = newValue }
    }

    @inline(__always) var weakrefCount: UInt32 {
        get { _obj.weakrefCount }
        nonmutating set { _obj.weakrefCount = newValue }
    }

    @inline(__always) var shape: JeffJSShape? {
        get { _obj.shape }
        nonmutating set { _obj.shape = newValue }
    }
    @inline(__always) var shapeIdentity: UnsafeRawPointer? { _obj.shapeIdentity }

    // Split property storage (zero-ARC handle): index directly on _obj so the
    // ContiguousArray struct is never copied (no buffer retain).
    @inline(__always) var propValues: JeffJSPropStorage {
        get { _obj.propValues }
        nonmutating set { _obj.propValues = newValue }
    }
    @inline(__always) var propExtra: ContiguousArray<JeffJSPropertyExtra?> {
        get { _obj.propExtra }
        nonmutating set { _obj.propExtra = newValue }
    }
    @inline(__always) var propCount: Int { _obj.propValues.count }
    @inline(__always) func dataValue(at i: Int) -> JeffJSValue { _obj.propValues[i] }
    @inline(__always) func extra(at i: Int) -> JeffJSPropertyExtra? { _obj.extra(at: i) }
    @inline(__always) func setExtraSlot(_ i: Int, _ e: JeffJSPropertyExtra?) { _obj.setExtraSlot(i, e) }
    @inline(__always) func propEntry(at i: Int) -> JeffJSProperty { _obj.propEntry(at: i) }
    @inline(__always) func setPropEntry(at i: Int, _ p: JeffJSProperty) { _obj.setPropEntry(at: i, p) }
    @inline(__always) func appendProp(_ p: JeffJSProperty) { _obj.appendProp(p) }
    @inline(__always) func appendDataValue(_ v: JeffJSValue) { _obj.appendDataValue(v) }
    @inline(__always) func clearProps() { _obj.clearProps() }

    @inline(__always) var firstWeakRef: AnyObject? {
        get { _obj.firstWeakRef }
        nonmutating set { _obj.firstWeakRef = newValue }
    }

    @inline(__always) var payload: JeffJSObjectPayload {
        get { _obj.payload }
        nonmutating set { _obj.payload = newValue }
    }

    @inline(__always) var fbFast: JeffJSFunctionBytecode? {
        get { _obj.fbFast }
        nonmutating set { _obj.fbFast = newValue }
    }
    @inline(__always) var fbFastU: Unmanaged<JeffJSFunctionBytecode>? { _obj.fbFastU }

    @inline(__always) var varRefsRaw: UnsafeMutablePointer<Unmanaged<JeffJSVarRef>?>? { _obj.varRefsRaw }
    @inline(__always) var varRefsRawCount: Int { _obj.varRefsRawCount }
    @inline(__always) var varRefsFast: [JeffJSVarRef?] {
        get { _obj.varRefsFast }
        nonmutating set { _obj.varRefsFast = newValue }
    }

    @inline(__always) var _fastArrayValues: JeffJSFastArrayStorage? {
        get { _obj._fastArrayValues }
        nonmutating set { _obj._fastArrayValues = newValue }
    }

    @inline(__always) var arrowThisVal: JeffJSValue? {
        get { _obj.arrowThisVal }
        nonmutating set { _obj.arrowThisVal = newValue }
    }

    // MARK: - Computed Properties (delegated)

    /// Check if the object is callable (bytecodeFunc, cFunc, boundFunction, or callable proxy).
    @inline(__always) var isCallable: Bool {
        _obj.isCallable
    }

    /// The prototype, accessed through the computed property on JeffJSObject.
    /// Note: getter/setter use ObjC associated objects under the hood.
    @inline(__always) var proto: JeffJSObject? {
        get { _obj.proto }
        nonmutating set { _obj.proto = newValue }
    }

    // MARK: - Identity

    /// Identity comparison — same object if same pointer.
    @inline(__always)
    static func === (lhs: JeffJSObj, rhs: JeffJSObj) -> Bool {
        lhs._ptr == rhs._ptr
    }

    @inline(__always)
    static func !== (lhs: JeffJSObj, rhs: JeffJSObj) -> Bool {
        lhs._ptr != rhs._ptr
    }

    /// Compare with a class reference (for backward compatibility).
    @inline(__always)
    static func === (lhs: JeffJSObj, rhs: JeffJSObject) -> Bool {
        lhs._ptr == Unmanaged.passUnretained(rhs).toOpaque()
    }

    @inline(__always)
    static func === (lhs: JeffJSObject, rhs: JeffJSObj) -> Bool {
        Unmanaged.passUnretained(lhs).toOpaque() == rhs._ptr
    }

    // MARK: - Conversion

    /// Get the raw JeffJSObject class reference. Use sparingly — this creates an ARC reference.
    @inline(__always) var asClass: JeffJSObject { _obj }

    /// Convert to JeffJSValue (NaN-boxed). Zero-cost — just combines tag + pointer.
    @inline(__always) var asValue: JeffJSValue {
        JeffJSValue(bits: JeffJSValue._objectTag | UInt64(UInt(bitPattern: _ptr)))
    }
}
