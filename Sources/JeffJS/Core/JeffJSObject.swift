// JeffJSObject.swift
// JeffJS — 1:1 Swift port of QuickJS JSObject and supporting types
// Copyright 2026 Jeff Bachand. All rights reserved.

import Foundation
import Synchronization

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
    // Layout (perf/watch-object-size): 40 bytes, was 56. pc/offset are 32-bit
    // and a transition entry's successor shape and a prototype entry's holder
    // shape share one slot (an entry is one or the other: `holderPtr` says
    // which). Every field keeps its name and type, so the readers are unchanged.
    /// Raw pointer to the cached shape (identity comparison, no retain).
    var shapePtr: UnsafeRawPointer? = nil
    /// Prototype-chain entry (depth 1): the property lives on the receiver's
    /// direct prototype `holderPtr` (retained JeffJSObject) at `propOffset`,
    /// valid while the receiver's shape (which fixes its prototype and own
    /// properties) and the holder's shape `holderShapePtr` (retained) match.
    var holderPtr: UnsafeRawPointer? = nil
    /// `nextShapePtr` (transition entries) or `holderShapePtr` (prototype
    /// entries), retained.
    private var _secondShape: UnsafeRawPointer? = nil
    private var _pc: Int32 = -1
    private var _propOffset: Int32 = -1
    /// Property key of a computed-key site (`o[k]` with a string `k`):
    /// the entry is valid only for this atom. 0 for named sites, whose
    /// key is fixed by the pc. The retained shapes hold a reference to the
    /// atom, so it cannot be freed and reused while the entry lives.
    var atom: UInt32 = 0
    /// Cached `.writable` flag of the slot (valid while the shape matches:
    /// flag changes copy the shape, so identity covers it).
    var writable: Bool = false

    /// Bytecode offset this cache belongs to (for collision validation).
    var pc: Int {
        @inline(__always) get { Int(_pc) }
        @inline(__always) set { _pc = Int32(truncatingIfNeeded: newValue) }
    }
    /// Property index into the object's prop array.
    var propOffset: Int {
        @inline(__always) get { Int(_propOffset) }
        @inline(__always) set { _propOffset = Int32(truncatingIfNeeded: newValue) }
    }
    /// define_field transition target (retained): objects on `shapePtr` at
    /// this pc move to this shape when the field is added.
    var nextShapePtr: UnsafeRawPointer? {
        @inline(__always) get { holderPtr == nil ? _secondShape : nil }
    }
    var holderShapePtr: UnsafeRawPointer? {
        @inline(__always) get { holderPtr != nil ? _secondShape : nil }
    }

    init() {}

    init(shapePtr: UnsafeRawPointer?, pc: Int, propOffset: Int, writable: Bool,
         atom: UInt32 = 0, nextShapePtr: UnsafeRawPointer? = nil,
         holderPtr: UnsafeRawPointer? = nil, holderShapePtr: UnsafeRawPointer? = nil) {
        precondition(nextShapePtr == nil || holderPtr == nil, "IC entry is a transition or a prototype hit, not both")
        self.shapePtr = shapePtr
        self.holderPtr = holderPtr
        self._secondShape = holderPtr != nil ? holderShapePtr : nextShapePtr
        self._pc = Int32(truncatingIfNeeded: pc)
        self._propOffset = Int32(truncatingIfNeeded: propOffset)
        self.atom = atom
        self.writable = writable
    }
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
///
/// Sizing (IC table size fix, 2026-09-29): every site indexes the table with
/// `pc & mask` (512 slots), and every site's `pc` is the offset of an
/// instruction of the function that owns the table — the trace's inline calls
/// switch `fb`/`bc`/`icEntries` together, and the fused `this[<const>]` read
/// uses its `get_array_el`'s own pc (checked `< bcLen`). So a table only needs
/// the slots `[0, bytecodeLen)`: it is `forBytecodeLength(len)` = the next power
/// of two ≥ len (8 … 512) entries, not a fixed 512 × 56 B = 28 KB (a 12-byte
/// arrow function kept 28 KB; 3 000 small functions = 83 MB). A function of
/// ≤ 512 bytes maps every pc to its own slot exactly as before (no collision
/// that the fixed table did not have); longer ones keep 512 slots. The hot
/// path is unchanged (`pc & JeffJSInlineCache.mask`). Stores check the bound
/// (`pc < capacity`; a miss path), so a future site that broke the invariant
/// would lose its cache instead of writing past the table.
/// `JEFFJS_INTERP_ICTABLEFIXED=1` (`interp.icTableFixed`) = fixed 512 slots (A/B).
nonisolated final class JeffJSInlineCache {
    static let size = 512
    static let mask = size - 1
    static let minCapacity = 8
    var entries: UnsafeMutableBufferPointer<JeffJSICEntry>
    /// Slots in `entries` (a power of two, ≤ `size`).
    let capacity: Int

    /// Live tables / their bytes, process-wide (stats: `jeffjs-cli --settle`).
    static let liveTables = Atomic<Int>(0)
    static let liveBytes = Atomic<Int>(0)
    static var liveStats: (tables: Int, bytes: Int) {
        (liveTables.load(ordering: .relaxed), liveBytes.load(ordering: .relaxed))
    }

    /// Slots a table of a function with `len` bytes of bytecode needs.
    @inline(__always)
    static func capacity(forBytecodeLength len: Int) -> Int {
        if JeffJSConfig.icTableFixed || len >= size { return size }
        var c = minCapacity
        while c < len { c <<= 1 }
        return c
    }

    init(capacity requested: Int = JeffJSInlineCache.size) {
        let cap = max(1, min(Self.size, requested))
        capacity = cap
        let ptr = UnsafeMutablePointer<JeffJSICEntry>.allocate(capacity: cap)
        ptr.initialize(repeating: JeffJSICEntry(), count: cap)
        entries = UnsafeMutableBufferPointer(start: ptr, count: cap)
        Self.liveTables.wrappingAdd(1, ordering: .relaxed)
        Self.liveBytes.wrappingAdd(cap * MemoryLayout<JeffJSICEntry>.stride, ordering: .relaxed)
    }

    deinit {
        Self.liveTables.wrappingSubtract(1, ordering: .relaxed)
        Self.liveBytes.wrappingSubtract(capacity * MemoryLayout<JeffJSICEntry>.stride, ordering: .relaxed)
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
        entries.baseAddress?.deinitialize(count: capacity)
        entries.baseAddress?.deallocate()
    }

    @inline(__always)
    func lookup(_ pc: Int) -> JeffJSICEntry {
        let idx = pc & Self.mask
        guard idx < capacity else { return JeffJSICEntry() }
        return entries[idx]
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
                     holderShape: JeffJSShape, propOffset: Int, atom: UInt32 = 0) {
        let idx = pc & Self.mask
        guard idx < capacity, !receiverShape.isLazySentinel, !holderShape.isLazySentinel else { return }
        receiverShape.icCached = true   // "no own property here": stale if one is appended in place
        let rs = Unmanaged.passRetained(receiverShape).toOpaque()
        let hp = Unmanaged.passRetained(holder).toOpaque()
        let hs = Unmanaged.passRetained(holderShape).toOpaque()
        releaseEntry(idx)
        entries[idx] = JeffJSICEntry(
            shapePtr: UnsafeRawPointer(rs), pc: pc, propOffset: propOffset, writable: false,
            atom: atom,
            nextShapePtr: nil, holderPtr: UnsafeRawPointer(hp), holderShapePtr: UnsafeRawPointer(hs))
    }

    @inline(__always)
    func update(_ pc: Int, shape: JeffJSShape, propOffset: Int, atom: UInt32 = 0) {
        let idx = pc & Self.mask
        guard idx < capacity, !shape.isLazySentinel else { return }
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
            writable: writable,
            atom: atom
        )
    }

    /// Cache a define_field transition: objects on `from` at `pc` move to `to`
    /// (both retained for the entry's lifetime).
    @inline(__always)
    func updateTransition(_ pc: Int, from: JeffJSShape, to: JeffJSShape) {
        let idx = pc & Self.mask
        guard idx < capacity, !from.isLazySentinel else { return }
        from.icCached = true   // stale if `from` grows in place
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
nonisolated final class TraceBlockInfo {
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

/// The UTF-8 text of one script, shared by every function compiled from it.
///
/// QuickJS copies each function's own source span into the function bytecode
/// (`JSFunctionDef.source` / `source_len`). Here the span stays a
/// (offset, length) pair into this one buffer, so a script's functions cost
/// 24 bytes each instead of a private copy of their text, and the buffer
/// lives exactly as long as some function from that script is alive.
nonisolated final class JeffJSSourceText {
    let bytes: [UInt8]

    init(bytes: [UInt8]) { self.bytes = bytes }
    init(_ s: String) { self.bytes = Array(s.utf8) }

    var count: Int { return bytes.count }

    /// Decode the [start, start+len) byte range as a Swift string.
    func slice(start: Int, len: Int) -> String? {
        guard len >= 0, start >= 0, start &+ len <= bytes.count else { return nil }
        if len == 0 { return "" }
        return String(decoding: bytes[start ..< (start &+ len)], as: UTF8.self)
    }
}

/// How to re-parse one lazily compiled function (recorded by the parser
/// when the function was first parsed, see JeffJSParser.recordLazySeed).
struct JeffJSLazySeed {
    enum Kind: UInt8 {
        /// `(params) { body }` starting at the '(' token: function
        /// declarations/expressions, object-literal and class methods,
        /// getters and setters. The flags below rebuild the definition.
        case params = 0
        /// An arrow function: re-parsed as the AssignmentExpression that
        /// starts at its first token.
        case arrow = 1
    }
    var kind: Kind = .params
    /// Byte offset of the first token to parse and its line.
    var parseStart: Int32 = 0
    var parseLine: Int32 = 1
    var funcName: JSAtom = 0
    var funcKind: UInt8 = 0
    /// The mode the definition inherited (a body "use strict" is re-read).
    var jsMode: UInt8 = 0
    var flags: UInt16 = 0

    static let hasSelfBinding: UInt16          = 1 << 0
    static let argumentsAllowed: UInt16        = 1 << 1
    static let superAllowed: UInt16            = 1 << 2
    static let superCallAllowed: UInt16        = 1 << 3
    static let newTargetAllowed: UInt16        = 1 << 4
    static let needHomeObject: UInt16          = 1 << 5
    /// The `in` operator was allowed where the (concise) arrow was written.
    static let arrowInFlag: UInt16             = 1 << 6
    static let isDerivedClassConstructor: UInt16 = 1 << 7
    static let emitFieldInitAtBodyStart: UInt16 = 1 << 8
    static let hasPrototype: UInt16            = 1 << 9

    func has(_ f: UInt16) -> Bool { return flags & f != 0 }
}

/// The script a lazily compiled function comes from: the source text every
/// function of it re-parses from, and a line index for column numbers.
/// One per compiled (or cache-loaded) script, shared by all its functions.
nonisolated final class JeffJSLazyScript {
    let source: JeffJSSourceText
    let filename: String
    let isModule: Bool
    /// Hash of the bytecode-cache entry the script was stored under or
    /// loaded from; compiled bodies persist next to it (JeffJSLazyBodyStore).
    /// nil when the script is not cached.
    var cacheHash: UInt64? = nil

    init(source: JeffJSSourceText, filename: String, isModule: Bool) {
        self.source = source
        self.filename = filename
        self.isModule = isModule
    }

    /// Byte offsets where lines start, by the rule JeffJSParseState.getLineCol
    /// uses (\n, \r, \r\n). Built on the first lazy compile of the script.
    private var lineStarts: [Int32]? = nil

    /// Start of the line holding byte `offset`.
    func lineStart(containing offset: Int) -> Int {
        if lineStarts == nil {
            var starts: [Int32] = [0]
            let b = source.bytes
            var i = 0
            let n = b.count
            while i < n {
                let c = b[i]
                if c == 0x0A {
                    starts.append(Int32(truncatingIfNeeded: i + 1))
                } else if c == 0x0D {
                    if i + 1 < n && b[i + 1] == 0x0A { i += 1 }
                    starts.append(Int32(truncatingIfNeeded: i + 1))
                }
                i += 1
            }
            lineStarts = starts
        }
        let starts = lineStarts!
        var lo = 0, hi = starts.count - 1
        let t = Int32(truncatingIfNeeded: offset)
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        return Int(starts[lo])
    }
}

/// Everything a lazily compiled function needs besides its (stub) bytecode
/// object: where to re-parse it from and whether that happened yet.
nonisolated final class JeffJSLazyFunctionInfo {
    let seed: JeffJSLazySeed
    let script: JeffJSLazyScript
    /// True until the body is compiled into the owning bytecode object.
    var isPending: Bool = true
    /// Idle reclaim (JeffJSLazyReclaim.swift): the runtime's reclaim phase
    /// when the body was last seen in use — a call that had to go through
    /// callInternal's payload path, a new closure made from it, or a reclaim
    /// scan finding one of its function objects with `fbFast` set.
    private var _touch: Int32 = 0
    private var _seenCycle: Int32 = 0
    var touch: Int {
        get { Int(_touch) }
        set { _touch = Int32(truncatingIfNeeded: newValue) }
    }
    /// The reclaim cycle that last listed this function (dedup, no set).
    var seenCycle: Int {
        get { Int(_seenCycle) }
        set { _seenCycle = Int32(truncatingIfNeeded: newValue) }
    }

    init(seed: JeffJSLazySeed, script: JeffJSLazyScript) {
        self.seed = seed
        self.script = script
    }
}

/// Forward reference for `JeffJSFunctionBytecode`.
nonisolated class JeffJSFunctionBytecode {
    var refCount: Int = 1
    private var _bytecodeLen: Int32 = 0
    var bytecodeLen: Int {
        @inline(__always) get { Int(_bytecodeLen) }
        set { _bytecodeLen = Int32(truncatingIfNeeded: newValue) }
    }
    var bytecode: [UInt8] = []

    /// Stable raw copy of `bytecode`, materialized lazily on first execution
    /// (when bytecode is final and immutable). The interpreter reads opcodes and
    /// operands through this pointer to avoid Swift Array bounds checks — the
    /// largest remaining per-opcode cost. Owned by this FB; freed in deinit, so
    /// the pointer is valid for the FB's entire lifetime (the FB is retained for
    /// the duration of any call that executes it).
    /// (A bare pointer: its length is `bytecodeLen`/`bytecode.count`; the
    /// buffer-pointer form was 24 bytes of every body.)
    private var _bcBuffer: UnsafeMutablePointer<UInt8>? = nil

    /// Raw pointer to the function's bytecode. Materializes `_bcBuffer` on first
    /// access. Must only be taken after `bytecode` is finalized (i.e. at execution
    /// time) — never mutate `bytecode` after this is called.
    /// Inlinable fast path for `bytecodePtr`: nil until first materialised.
    @inline(__always) var bcPtrFast: UnsafePointer<UInt8>? {
        if let b = _bcBuffer { return UnsafePointer(b) }
        return nil
    }

    var bytecodePtr: UnsafePointer<UInt8> {
        if let b = _bcBuffer {
            return UnsafePointer(b)
        }
        materializeCpoolRaw()   // first execution: constants are final too
        let n = bytecode.count
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: max(n, 1))
        if n > 0 {
            bytecode.withUnsafeBufferPointer { buf.initialize(from: $0.baseAddress!, count: n) }
        } else {
            buf[0] = 0
        }
        _bcBuffer = buf
        return UnsafePointer(buf)
    }

    deinit {
        _bcBuffer?.deallocate()
        _cpoolRaw?.deallocate()
        _traceIndexPCs?.deallocate()
        _traceIndexInfos?.deallocate()
    }
    /// Set only on bodies loaded from the bytecode cache (cold box).
    var fileName: JeffJSString? {
        get { _cold?.fileName }
        set { if newValue == nil && _cold == nil { return }; coldBox().fileName = newValue }
    }
    private var _lineNum: Int32 = 0
    private var _colNum: Int32 = 0
    var lineNum: Int {
        @inline(__always) get { Int(_lineNum) }
        set { _lineNum = Int32(truncatingIfNeeded: newValue) }
    }
    var colNum: Int {
        @inline(__always) get { Int(_colNum) }
        set { _colNum = Int32(truncatingIfNeeded: newValue) }
    }
    var argCount: UInt16 = 0
    var varCount: UInt16 = 0
    /// The value of the function's `length` own property: the number of
    /// formal parameters before the first one with a default, and excluding
    /// the rest parameter (ES §20.2.4.1).
    var definedArgCount: UInt16 = 0
    /// Atom of the function's `name` own property (0 = anonymous).
    /// On the base class so the lazy materialiser needs no downcast and so a
    /// bytecode-cache round trip can restore it.
    var nameAtom: UInt32 = 0
    var stackSize: UInt16 = 0
    var closureVarCount: UInt16 = 0
    /// Enter the fast trace at function entry (not only at loop back-edges).
    /// Cleared after repeated immediate deopts (see the interpreter).
    var traceEntryEnabled: Bool = true
    var traceEntryDeopts: UInt16 = 0
    /// Call-free function with at least one loop: run it in the lean trace
    /// variant from entry (set by the compiler's trace analysis).
    var traceLean: Bool = false
    /// Argument-slot ownership (see "Ownership of call arguments" in
    /// JeffJSInterpreter.swift). Set by `JeffJSCompiler.computeArgSlotOwnership`
    /// from the final bytecode: true when something can store into one of
    /// this function's parameter slots (put_arg/set_arg, a mapped
    /// `arguments` object, a closure or direct eval capturing a parameter, an
    /// argument reference). A store then releases the value it replaces, so
    /// the slot must own it: plain frames of such a function take their own
    /// references to the arguments on entry (`copiesArgs`) and release their
    /// argument slots at exit; generator and async frames already own theirs
    /// (callFunction hands them copies). Functions that never store into a
    /// parameter keep borrowing the caller's references for free.
    /// (Declared here, next to traceLean, so it fills existing padding and
    /// leaves the hot fields' offsets alone.)
    var argSlotsOwned: Bool = false
    /// `argSlotsOwned` for a plain (non-generator, non-async) function: its
    /// call paths dup the arguments into the frame and release them at exit.
    var copiesArgs: Bool = false
    var cpool: [JeffJSValue] = [] {
        didSet { if _cpoolWanted { _rebuildCpoolRaw() } }
    }
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
    /// A script's (or eval's) top-level code: `Error.stack` names its frame
    /// `global code` / `eval code`, as JavaScriptCore does.
    var isTopLevelCode: Bool = false
    /// The name an anonymous function literal got from its binding
    /// (`var U = function(){}` → "U", ES SetFunctionName via `set_name`),
    /// recorded the first time `set_name` runs on one of its closures.
    /// `Error.stack` frames use it (JSC's ecmaName), never the bytecode's
    /// own name, which would create a self-binding.
    var inferredName: String? = nil

    // Call-path caches: callInternal used to discover these via
    // `as? JeffJSFunctionBytecodeCompiled` — two dynamic casts per call.
    /// True when compiled in strict mode (JS_MODE_STRICT).
    var isStrictMode: Bool = false
    /// Local var index of a named function expression's self-binding, -1 if none.
    private var _selfRefVarIdx: Int32 = -1
    var selfRefVarIdx: Int {
        @inline(__always) get { Int(_selfRefVarIdx) }
        set { _selfRefVarIdx = Int32(truncatingIfNeeded: newValue) }
    }
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
        let newIC = JeffJSInlineCache(capacity: JeffJSInlineCache.capacity(forBytecodeLength: bytecodeLen))
        ic = newIC
        return newIC
    }

    // MARK: - Trace Blocks

    /// Trace blocks for hot loop optimization. Maps backward-jump target PC → trace info.
    /// Populated by JeffJSCompiler.fuseBasicBlocks() after bytecode compilation.
    /// nil until fuseBasicBlocks runs (saves memory for functions with no loops).
    var traceBlocks: [Int: TraceBlockInfo]? {
        didSet { _dropTraceIndex() }
    }

    // MARK: - Function source text (Function.prototype.toString)
    //
    // These stay LAST. Declaring them earlier pushes `icEntries` / `bcPtrFast`
    // — read on every property-access and every opcode — 24 bytes further into
    // the object, which cost 11% on the whole real-world suite (measured).

    /// The whole script this function was compiled from (shared with every
    /// other function of that script, and retained for as long as any of them
    /// is alive). nil when the source is unavailable (bytecode with no
    /// recorded source).
    var sourceText: JeffJSSourceText? = nil
    /// Byte offset of this function's source span in `sourceText`.
    var sourceStart: Int32 = 0
    /// Byte length of the span; -1 when no span was recorded.
    var sourceLen: Int32 = -1
    /// Function objects whose payload runs this bytecode (counted where such a
    /// payload is made — createClosure, the class/method closure path,
    /// executeBytecode — and uncounted in freeObject). 0 + a refCount of 1 (its parent's constant
    /// pool) after the parent script finished = nothing can run it again
    /// (JeffJSContext.releaseTopLevelConstants).
    var liveClosures: Int32 = 0
    /// Trace index size (see `traceBlock(at:)`); -1: not built. Declared here
    /// to share liveClosures' 8-byte slot.
    private var _traceIndexCount: Int32 = -1

    /// Direct `eval` call sites of this function (see JeffJSEvalSite), nil
    /// when it has none. Indexed by the `eval`/`apply_eval` site operand.
    var evalSites: [JeffJSEvalSite]? {
        get { _cold?.evalSites }
        set { if newValue == nil && _cold == nil { return }; coldBox().evalSites = newValue }
    }

    /// Unretained copy of `cpool`'s element bits for the interpreters'
    /// constant loads: reading `cpool[i]` through the class retained and
    /// released the array buffer on every push_const8 (a hot opcode in
    /// string-keyed code). The values stay owned by `cpool`; once built, the
    /// copy is rebuilt on every mutation of `cpool`.
    private(set) var _cpoolRaw: UnsafeMutablePointer<JeffJSValue>? = nil
    private var _cpoolRawCount: Int32 = 0
    private(set) var cpoolRawCount: Int {
        @inline(__always) get { Int(_cpoolRawCount) }
        set { _cpoolRawCount = Int32(truncatingIfNeeded: newValue) }
    }
    private var _cpoolWanted = false

    /// Constant `i` (borrowed), or undefined when out of range, for the
    /// interpreters. Field loads only: any call on this path (even a cold
    /// fallback reading `cpool`) made the trace loops retain `fb` around
    /// every constant load. Valid for every executing function: the view is
    /// built with the bytecode pointer (`bytecodePtr`, which every execution
    /// path takes first) and kept in sync with `cpool` from then on.
    @inline(__always) func constant(_ i: Int) -> JeffJSValue {
        if let p = _cpoolRaw, i < cpoolRawCount { return p[i] }
        return .undefined
    }

    /// Build the unretained constant view and keep it in sync from now on.
    func materializeCpoolRaw() {
        if _cpoolWanted { return }
        _cpoolWanted = true
        _rebuildCpoolRaw()
    }

    /// Loop-head lookup table mirroring `traceBlocks` (sorted pcs + unretained
    /// infos; the dictionary keeps the infos alive). Every taken backward
    /// branch asks for its trace block; a Swift dictionary probe (SipHash of
    /// the pc) per iteration was ~4% of a call-heavy loop.
    /// (The two arrays live in the cold box; the count stays here so a body
    /// without trace blocks answers from one field.)
    private var _traceIndexPCs: UnsafeMutablePointer<Int>? {
        get { _cold?.traceIndexPCs }
        set { if newValue == nil && _cold == nil { return }; coldBox().traceIndexPCs = newValue }
    }
    private var _traceIndexInfos: UnsafeMutablePointer<Unmanaged<TraceBlockInfo>>? {
        get { _cold?.traceIndexInfos }
        set { if newValue == nil && _cold == nil { return }; coldBox().traceIndexInfos = newValue }
    }

    /// Trace block whose loop head is `pc`, if any.
    @inline(__always) func traceBlock(at pc: Int) -> TraceBlockInfo? {
        let n = Int(_traceIndexCount)
        if n == 0 { return nil }
        if n < 0 { return _buildTraceIndex(pc) }
        guard let pcs = _traceIndexPCs, let infos = _traceIndexInfos else { return nil }
        var lo = 0, hi = n - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let v = pcs[mid]
            if v == pc { return infos[mid].takeUnretainedValue() }
            if v < pc { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    @inline(never) private func _buildTraceIndex(_ pc: Int) -> TraceBlockInfo? {
        guard let blocks = traceBlocks, !blocks.isEmpty else { _traceIndexCount = 0; return nil }
        let sorted = blocks.sorted { $0.key < $1.key }
        let n = sorted.count
        let pcs = UnsafeMutablePointer<Int>.allocate(capacity: n)
        let infos = UnsafeMutablePointer<Unmanaged<TraceBlockInfo>>.allocate(capacity: n)
        for (i, kv) in sorted.enumerated() {
            (pcs + i).initialize(to: kv.key)
            (infos + i).initialize(to: Unmanaged.passUnretained(kv.value))
        }
        _traceIndexPCs = pcs; _traceIndexInfos = infos; _traceIndexCount = Int32(truncatingIfNeeded: n)
        return blocks[pc]
    }

    fileprivate func _dropTraceIndex() {
        _traceIndexPCs?.deallocate(); _traceIndexPCs = nil
        _traceIndexInfos?.deallocate(); _traceIndexInfos = nil
        _traceIndexCount = -1
    }

    fileprivate func _rebuildCpoolRaw() {
        _cpoolRaw?.deallocate()
        _cpoolRaw = nil
        cpoolRawCount = 0
        let n = cpool.count
        guard n > 0 else { return }
        let p = UnsafeMutablePointer<JeffJSValue>.allocate(capacity: n)
        cpool.withUnsafeBufferPointer { p.initialize(from: $0.baseAddress!, count: n) }
        _cpoolRaw = p
        cpoolRawCount = n
    }

    /// Lazy compilation (JeffJSLazyFunctionInfo): set on a function whose
    /// body is compiled on its first call. While `lazyInfo.isPending` the
    /// bytecode is empty and closure objects made from it keep `fbFast` nil,
    /// so every call reaches callInternal's payload path, which compiles the
    /// body into this object in place (JeffJSCompiler.compileLazy). Kept
    /// after compiling (the recipe to recompile, and the body cache key).
    var lazyInfo: JeffJSLazyFunctionInfo? = nil

    /// Rarely set fields of a body (perf/watch-object-size): the cache
    /// filename, direct-eval sites, the trace index arrays and, for the
    /// compiled subclass, debug tables / var defs / cached names. nil for a
    /// lazy stub.
    final var _cold: JeffJSFunctionBytecodeCold? = nil
    @inline(__always) final func coldBox() -> JeffJSFunctionBytecodeCold {
        if let c = _cold { return c }
        let c = JeffJSFunctionBytecodeCold()
        _cold = c
        return c
    }

    /// A lazily compiled function whose body is not compiled yet.
    @inline(__always) var isLazyPending: Bool { lazyInfo?.isPending ?? false }

    /// Drop the raw copy of `bytecode` materialized by `bytecodePtr` (lazy
    /// compilation replaced the bytecode of this object).
    func resetBytecodeBuffer() {
        _bcBuffer?.deallocate()
        _bcBuffer = nil
    }

    /// The function's own source text, exactly as written (QuickJS
    /// `js_function_toString`). nil when it was not recorded.
    var sourceSpanText: String? {
        guard sourceLen >= 0, let src = sourceText else { return nil }
        return src.slice(start: Int(sourceStart), len: Int(sourceLen))
    }
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

    /// The 2-bit type field (normal / getset / varref / autoinit). `contains`
    /// is the wrong test for it: `.autoinit` contains both `.getset` and
    /// `.varref` bits.
    @inline(__always) var propType: UInt32 { rawValue & JeffJSPropertyFlags.tmask.rawValue }
    /// A plain data slot: its value lives in `propValues`, so the inline
    /// caches may read and write it directly.
    @inline(__always) var isPlainData: Bool { propType == 0 }
    @inline(__always) var isGetSet: Bool { propType == JeffJSPropertyFlags.getset.rawValue }
    @inline(__always) var isVarRef: Bool { propType == JeffJSPropertyFlags.varref.rawValue }
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
nonisolated final class ListNode {
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
// nonisolated: GC objects are created and freed on whatever thread runs the
// engine. Without this they inherit the host's default actor isolation (React
// Natively builds with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor), which makes
// the implicit base deinit main-actor isolated and clashes with subclass deinits.
nonisolated class JeffJSGCObjectHeader {
    // Field order (perf/watch-object-size): the 8-byte fields first and the
    // 4/1/1-byte ones last, so the header ends at offset 38 and a subclass's
    // small fields pack into the remaining bytes (JeffJSObject is 80 bytes).
    var refCount: Int
    /// Back-pointer to the owning runtime so the zero-arg freeValue() can
    /// actually free the object when refCount hits 0.
    ///
    /// Strong, not weak: a weak reference here forced a side-table entry on
    /// EVERY GC object (formWeakReference per creation, weakLoadStrong per
    /// read, and slow-path retain/release on the runtime forever after).
    /// The runtime↔object cycle is broken explicitly by clearGCState()
    /// during runtime.free(), which nils this field on all tracked headers.
    var ownerRuntime: JeffJSRuntime?

    /// Intrusive position in the runtime's GC tracking lists, so removal is
    /// an O(1) swap-remove instead of a linear scan (removeGCObject was 98%
    /// of promise-chain time). Encoding: >= 0 → index in rt.gcObjects;
    /// -1 → not tracked; <= -2 → index (-2 - value) in rt.gcTmpObjects.
    final var gcListIndex: Int {
        @inline(__always) get { Int(_gcListIndex) }
        @inline(__always) set { _gcListIndex = Int32(truncatingIfNeeded: newValue) }
    }
    /// 32-bit storage (perf/watch-object-size): packs next to `gcObjType` and
    /// `mark`, 8 bytes off every GC object's header.
    final var _gcListIndex: Int32 = -1
    var gcObjType: JSGCObjectTypeEnum
    var mark: Bool

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

    /// The runtime's GC lists hold *unretained* pointers (see
    /// `JeffJSRuntime.gcObjects`), so anything that reaches ARC deallocation
    /// while still listed would leave a dangling entry for the next
    /// collection to walk. Every JS object leaves the list through
    /// `freeGCObjectChildren` or the recycle pool, but a detached var-ref is
    /// owned purely by ARC from the closures that captured it: when the last
    /// closure goes, this is the only unlink there is.
    deinit {
        if gcListIndex != -1, let rt = ownerRuntime { removeGCObject(rt, self) }
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

/// The keys one `for (k in obj)` visits, as owned JS string values. A list
/// built from a single shape is cached on that shape and shared by every
/// iterator over an object of that shape; the strings are released when the
/// last holder lets go.
nonisolated final class JeffJSForInKeyList {
    let keys: [JeffJSValue]
    init(keys: [JeffJSValue]) { self.keys = keys }
    deinit { for k in keys { k.freeValue() } }
}

/// For-in iterator state: the key list being walked and the position. Lives
/// in the iterator object's payload; the old implementation kept the keys in
/// a JS array under two internal properties and paid five property
/// operations per iteration.
nonisolated final class JeffJSForInIterator {
    let keys: JeffJSForInKeyList
    var idx: Int = 0
    init(keys: JeffJSForInKeyList) { self.keys = keys }
}

/// ArrayBuffer data.
nonisolated final class JeffJSArrayBuffer {
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
nonisolated final class JeffJSTypedArray {
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
nonisolated final class JeffJSPromiseData {
    var promiseState: JeffJSPromiseStateEnum = .pending
    var promiseResult: JeffJSValue = .undefined
    var promiseFulfillReactions: [JeffJSPromiseReaction] = []
    var promiseRejectReactions: [JeffJSPromiseReaction] = []
    var isHandled: Bool = false

    init() {}
}

/// Async function execution state.
nonisolated final class JeffJSAsyncFunctionState {
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
    /// Var-refs that closures created inside the generator hold on its
    /// locals/arguments. The frame epilogue detaches them at every yield (the
    /// frame's buffer is released), so they are re-attached to the fresh
    /// buffer on resume; without that the closure and the generator body see
    /// two different copies of the same binding after the first yield.
    var capturedVarRefs: [JeffJSVarRef] = []
    /// For yield* delegation: the inner iterator being delegated to.
    /// When non-nil, the generator is in `suspended_yield_star` state
    /// and each .next() call should advance the inner iterator.
    var delegatedIter: JeffJSValue = .undefined
}

/// Generator data.
/// One queued `next` / `return` / `throw` on an async generator, with the
/// promise capability whose settlement is that call's answer.
nonisolated final class JeffJSAsyncGenRequest {
    let completionType: Int
    var value: JeffJSValue      // owned
    var resolve: JeffJSValue    // owned
    var reject: JeffJSValue     // owned
    init(completionType: Int, value: JeffJSValue,
         resolve: JeffJSValue, reject: JeffJSValue) {
        self.completionType = completionType
        self.value = value
        self.resolve = resolve
        self.reject = reject
    }
    func release() {
        value.freeValue(); resolve.freeValue(); reject.freeValue()
        value = .undefined; resolve = .undefined; reject = .undefined
    }
}

nonisolated final class JeffJSGeneratorData {
    var state: JeffJSGeneratorStateEnum = .suspended_start
    var asyncState: JeffJSAsyncFunctionState = JeffJSAsyncFunctionState()

    // MARK: Async generators
    //
    // An async generator body suspends for two different reasons and the
    // driver has to tell them apart: a `yield` hands a value to the caller,
    // an `await` on a *pending* promise hands control to the microtask queue
    // and comes back to the same spot. Both leave `state == .suspended_yield`
    // and a `savedState`, so the awaited promise is the discriminator.

    /// The promise a parked `await` is waiting on; `.undefined` when the body
    /// is parked on a `yield` instead. Owned.
    var awaitedPromise: JeffJSValue = .undefined
    /// Set by the await continuation: the body is to be resumed with this
    /// value (or this exception) rather than with the head request's.
    var awaitResumePending = false
    var awaitResumeValue: JeffJSValue = .undefined   // owned
    var awaitResumeIsThrow = false
    /// The parked await is on a `yield*` delegate's iterator-result promise,
    /// so the value it resumes with *is* the iterator result and the
    /// delegation must not call `next()` again for it.
    var delegateAwaitPending = false
    /// Outstanding next/return/throw calls, oldest first.
    var asyncQueue: [JeffJSAsyncGenRequest] = []
    /// Re-entrancy guard for the drain loop.
    var asyncDraining = false
    /// Saved interpreter state from the last yield/initial_yield.
    /// Non-nil when the generator is in a suspended state.  The saved value
    /// stack is *owned* by this state (the suspending frame moves its slots
    /// here); resuming moves the values back into the interpreter buffer.
    var savedState: GeneratorSavedState? = nil

    init() {}

    deinit {
        // Generator dropped while suspended: release the value stack it was
        // holding across the yield (for-of iterator state, call operands...).
        if let saved = savedState, JeffJSGCObjectHeader.activeRuntime != nil {
            JeffJSGeneratorData.releaseSuspendedState(saved)
        }
        if JeffJSGCObjectHeader.activeRuntime != nil {
            awaitedPromise.freeValue()
            awaitResumeValue.freeValue()
            for req in asyncQueue { req.release() }
        }
        asyncQueue.removeAll()
    }

    /// Releases everything a suspended (never resumed) state owns: its value
    /// stack, locals and arguments, a `yield*` delegate, and the generator's
    /// own references to its function and `this`.
    static func releaseSuspendedState(_ saved: GeneratorSavedState) {
        for v in saved.stack { v.freeValue() }
        for v in saved.varBuf { v.freeValue() }
        for v in saved.argBuf { v.freeValue() }   // generator args are owned by the generator
        if !saved.delegatedIter.isUndefined { saved.delegatedIter.freeValue() }   // yield* delegate
        saved.thisVal.freeValue()
        saved.funcObj.freeValue()
    }
}

/// Map / Set record entry.
nonisolated final class JeffJSMapRecord {
    var refCount: Int = 1
    var map: JeffJSMapState?
    var key: JeffJSValue = .undefined
    var value: JeffJSValue = .undefined
    var hashNext: Int = -1
    var link: ListNode = ListNode()
    var empty: Bool = false
    /// WeakMap/WeakSet record whose key is held weakly: the record owns no
    /// reference to `key`, which lists the record in the runtime's
    /// `weakMapKeyRecords` instead (see "Weak collections" in
    /// JeffJSBuiltinMap.swift).
    var weakKey: Bool = false

    init() {}
}

/// Map / Set state.
nonisolated final class JeffJSMapState {
    var isWeak: Bool = false
    /// Live iterators and running `forEach` loops, which address `records`
    /// by index: the table is only compacted while this is zero.
    var iterating: Int = 0
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
nonisolated final class JeffJSGlobalObject {
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
nonisolated final class JeffJSVarRef: JeffJSGCObjectHeader {
    /// Var-refs are shared by every closure capturing the same slot and are
    /// kept alive by their varRefs arrays (ARC); the detached value is
    /// released when the last closure lets go. The GC path clears `value`
    /// after releasing it, so this never double-frees.
    deinit { if isDetached, !value.isUndefined { value.freeValue() } }
    /// A live var-ref reads through its parent frame, which is a GC root, so
    /// it takes no part in cycle detection. Detaching copies the value into
    /// `value` and the only things left holding the var-ref are closures,
    /// arguments objects and suspended generators — all of them GC objects,
    /// so from here on it is a node in the graph (quickjs does the same in
    /// `close_var_refs`: `add_gc_object(..., JS_GC_OBJ_TYPE_VAR_REF)`).
    /// Its `refCount` is not maintained incrementally — nothing counts a
    /// var-ref reference — so the collector recomputes it each run; see
    /// `gcSeedVarRefs`.
    var isDetached: Bool {
        didSet {
            if isDetached, !oldValue, gcListIndex == -1, let rt = ownerRuntime {
                addGCObject(rt, self)
            }
        }
    }
    var isArg: Bool
    /// An argument var-ref over a frame that owns its argument slots
    /// (`JeffJSFunctionBytecode.argSlotsOwned`): a store releases the value
    /// it replaces, like a local. Otherwise the slot holds the caller's
    /// borrowed reference and must not be released here.
    var argOwned: Bool = false
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

    /// `put_var_ref` / `set_var_ref`: store an owned value into the binding
    /// and release the one it replaces (quickjs `set_value`). The store
    /// opcodes used to overwrite the slot without freeing it, so every
    /// assignment to a captured variable leaked its previous value — React's
    /// `workInProgressHook = hook` alone leaked every hook of every render.
    ///
    /// A live var-ref over a *parameter* releases the replaced value only
    /// when its frame owns its argument slots (`argOwned`); otherwise the
    /// slot holds the caller's borrowed reference (see "Ownership of call
    /// arguments" in JeffJSInterpreter.swift). Every function whose parameter
    /// can be captured owns its slots, so in practice this always releases.
    @inline(__always)
    func store(_ v: JeffJSValue) {
        if isDetached {
            let old = value; value = v; old.freeValue()
        } else if isArg && !argOwned {
            pvalue = v
        } else {
            let old = pvalue; pvalue = v; old.freeValue()
        }
    }

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
///
/// Only values outside the 48-bit inline payload live here; everything
/// smaller is a `shortBigInt` in the NaN-boxed value itself.
nonisolated final class JeffJSBigInt: JeffJSGCObjectHeader {
    var value: JBigInt = .zero

    var sign: Bool { value.negative }

    override init(refCount: Int = 1,
                  gcObjType: JSGCObjectTypeEnum = .bigInt,
                  mark: Bool = false) {
        super.init(refCount: refCount, gcObjType: gcObjType, mark: mark)
    }

    convenience init(_ v: JBigInt) {
        self.init(refCount: 1, gcObjType: .bigInt, mark: false)
        self.value = v
    }
}

/// Call-stack frame.
/// Uses a class (not struct) because it self-references via `prevFrame`.
nonisolated final class JeffJSStackFrame {
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
    /// `thisVal` is a wrapper object this frame created (a sloppy-mode
    /// function called with a primitive `this`, ES §10.2.1.2 step 6.b:
    /// ToObject(thisArgument)); released with the frame. Callers pass
    /// `this` borrowed, so only the boxed copy is owned.
    var ownsThis: Bool                = false
    var newTarget: JeffJSValue        = .undefined
    var curPC: Int                    = 0
    /// The host (native) function this activation is calling right now, if
    /// any — JavaScriptCore lists it in `Error.stack` as `name@[native code]`
    /// above the caller (`toString@[native code]`, `map@[native code]`).
    /// Set around native dispatch; unowned: the callee is live on the stack.
    unowned(unsafe) var nativeCallee: JeffJSObject? = nil
    var argBuf: [JeffJSValue]         = []
    var argCount: Int                 = 0
    var varBuf: [JeffJSValue]         = []
    var varCount: Int                 = 0
    var spBase: Int                   = 0
    var sp: Int                       = 0

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

    /// An Error's captured call site, formatted into `stack` on first read.
    case pendingErrorStack(JeffJSPendingStack)

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
nonisolated final class JeffJSPropertyExtra {
    enum Kind: UInt8 { case getset, varRef, autoInit }
    // Layout (perf/watch-object-size): 48 bytes, was 96 (an `Any?` alone was
    // 32). Two reference slots carry whatever the kind needs — getter/setter,
    // the var-ref of a mapped `arguments` slot, or an autoinit's boxed opaque
    // — behind the same field names as before.
    var kind: Kind
    private var _a: AnyObject?
    private var _b: AnyObject?
    var autoRealmAndId: UInt

    nonisolated private final class OpaqueBox { let value: Any; init(_ v: Any) { value = v } }

    var getter: JeffJSObject? {
        @inline(__always) get { kind == .getset ? _a.map { unsafeDowncast($0, to: JeffJSObject.self) } : nil }
        set { _a = newValue }
    }
    var setter: JeffJSObject? {
        @inline(__always) get { kind == .getset ? _b.map { unsafeDowncast($0, to: JeffJSObject.self) } : nil }
        set { _b = newValue }
    }
    var varRef: JeffJSVarRef? {
        @inline(__always) get { kind == .varRef ? _a.map { unsafeDowncast($0, to: JeffJSVarRef.self) } : nil }
        set { _a = newValue }
    }
    var autoOpaque: Any? {
        get { kind == .autoInit ? _a.map { unsafeDowncast($0, to: OpaqueBox.self).value } : nil }
        set { _a = newValue.map { OpaqueBox($0) } }
    }

    init(getter: JeffJSObject?, setter: JeffJSObject?) {
        self.kind = .getset; self._a = getter; self._b = setter; self.autoRealmAndId = 0
    }
    init(varRef: JeffJSVarRef) {
        self.kind = .varRef; self._a = varRef; self._b = nil; self.autoRealmAndId = 0
    }
    init(autoRealmAndId: UInt, opaque: Any?) {
        self.kind = .autoInit; self.autoRealmAndId = autoRealmAndId
        self._a = opaque.map { OpaqueBox($0) }; self._b = nil
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
nonisolated final class JeffJSFastArrayStorage: JeffJSSideSlot {
    var values: ContiguousArray<JeffJSValue>
    var count: UInt32
    /// Per-element attribute bits (`attrWritable|attrEnumerable|
    /// attrConfigurable`), parallel to `values`. nil while every element is
    /// an ordinary `{writable, enumerable, configurable}` data property,
    /// which is the only state the unchecked fast paths may assume.
    var attrs: ContiguousArray<UInt8>? = nil
    /// Set once element writes need the checked path (ES §10.1.9 [[Set]],
    /// §10.4.2.1 array [[DefineOwnProperty]]): the owner is non-extensible,
    /// its `length` is non-writable, or some element has non-default
    /// attributes (`attrs`). Every unchecked element write — the
    /// interpreter's `put_array_el` fast paths and setPropertyInternal's
    /// element store — tests this one flag and takes
    /// `JeffJSContext.setArrayElementChecked` instead. Never cleared.
    var checked: Bool = false

    static let attrWritable: UInt8 = 1
    static let attrEnumerable: UInt8 = 2
    static let attrConfigurable: UInt8 = 4
    static let attrDefault: UInt8 = 7

    init(values: ContiguousArray<JeffJSValue>, count: UInt32) {
        self.values = values
        self.count = count
        super.init()
    }

    /// True when index `i` holds an element (not a hole, not past the end).
    @inline(__always)
    func isPresent(_ i: Int) -> Bool {
        return i >= 0 && i < Int(count) && i < values.count && !values[i].isUninitialized
    }

    /// Attribute bits of element `i` (meaningful only while it is present).
    @inline(__always)
    func attr(_ i: Int) -> UInt8 {
        guard let a = attrs, i < a.count else { return JeffJSFastArrayStorage.attrDefault }
        return a[i]
    }

    /// Set the attribute bits of element `i`; any non-default value switches
    /// the array to the checked write path.
    func setAttr(_ i: Int, _ bits: UInt8) {
        if attrs == nil {
            if bits == JeffJSFastArrayStorage.attrDefault { return }
            attrs = ContiguousArray(repeating: JeffJSFastArrayStorage.attrDefault,
                                    count: max(values.count, i + 1))
        }
        while attrs!.count <= i { attrs!.append(JeffJSFastArrayStorage.attrDefault) }
        attrs![i] = bits
        if bits != JeffJSFastArrayStorage.attrDefault { checked = true }
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
nonisolated final class JeffJSObject: JeffJSGCObjectHeader {

    // =========================================================================
    // Layout (perf/watch-object-size, 2026-10-05). 96 bytes per object, was
    // 320: the watch's 300 MB ceiling made bytes per object the budget.
    //   header: isa, Swift refcount, refCount, gcObjType, mark, gcListIndex32,
    //   ownerRuntime                                                  (40 B)
    //   _flags16, realmIndex, lazyFlags, _classID16, weakrefCount32,
    //   _propExtraCount32, shape (strong; its bits are the IC identity, so
    //   shapeIdentity needs no field), propValues (ptr + 2 x UInt32),
    //   aux, _fastArrayValues                                         (56 B)
    // Everything only functions, exotic objects or rare features use lives
    // in `aux` (JeffJSObjectAux), allocated on the first non-default write;
    // plain objects (90 % of a page's heap) never allocate one. Every moved
    // field keeps its name and type as a computed property, so call sites
    // are unchanged. The bool flags are bits of `_flags`.
    // =========================================================================

    /// Object flags, one bit each (see the computed properties below).
    final var _flags: UInt16 = JeffJSObject.flagExtensible
    /// The realm (JeffJSContext.realmIndex) a function object belongs to: the
    /// context whose code created the closure, or a native function's
    /// `realm`. 0 for everything created by a runtime's ordinary contexts.
    /// Calls switch to the callee's realm when it differs from the caller's
    /// (ES §10.2.1.1 PrepareForOrdinaryCall step 4-6, §10.3.1 [[Call]] of
    /// built-ins: the callee's realm becomes the current Realm Record).
    var realmIndex: UInt8 = 0
    /// Which own properties of this object are deferred (see "Lazy function
    /// prototype" below). One byte so the property-lookup fast path tests a
    /// single field (`lazyFlags != 0`).
    ///   bit 0: `prototype` (plain function)
    ///   bit 1: `name` + `length` (bytecode function)
    ///   bit 2: `stack` (Error)
    var lazyFlags: UInt8 = 0
    final var _classID: UInt16 = 0
    /// `propExtra.count` mirrored in a plain field: the hot `extra(at:)`
    /// test then reads one Int32 instead of the side box.
    final var _propExtraCount: Int32 = 0
    /// The shape, retained manually (+1 held while set): its raw bits are the
    /// inline-cache identity, so `shapeIdentity` needs no field of its own.
    /// The shape. A plain strong stored property on purpose: reads borrow it
    /// with no retain (an Unmanaged copy cost 7-22 % on property/array loops,
    /// every read became a retain). Its raw bits are the inline-cache
    /// identity, so `shapeIdentity` needs no field of its own.
    var shape: JeffJSShape? = nil
    /// Unretained identity of `shape` for inline-cache checks: the bits of
    /// the stored reference, read without a retain.
    var shapeIdentity: UnsafeRawPointer? {
        @inline(__always) get { unsafeBitCast(shape, to: UnsafeRawPointer?.self) }
    }

    /// Split property storage (see JeffJSProperty). `propValues` holds the data
    /// value for every slot (`.undefined` for accessor/varRef/autoInit slots);
    /// trivial storage → no element ARC, no array bridging, no enum-witness
    /// per access. `propExtra` is the parallel array (same length), nil for
    /// plain data slots. Data values keep the existing manual refcount
    /// discipline (dup on read, freeValue on overwrite/object-free).
    /// INVARIANT: propExtra.isEmpty || propValues.count == propExtra.count.
    /// Access via propEntry(at:)/setPropEntry(at:_:)/appendProp(_:)/dataValue(at:).
    var propValues = JeffJSPropStorage()

    /// Side box for the fields most objects never use (nil = all default),
    /// retained manually so the accessors read through it without ARC
    /// traffic (`_withUnsafeGuaranteedRef`).
    /// One strong slot: the side box (flagSlotIsAux) or, for an array
    /// without one, its element store. A plain strong native reference, so a
    /// read borrows it without a retain; the box keeps the array store when
    /// an array also needs a box.
    final var _slot: JeffJSSideSlot? = nil
    /// The side box without a retain (nil when the slot holds an array store
    /// or nothing).
    final var _auxU: Unmanaged<JeffJSObjectAux>? {
        @inline(__always) get {
            if (_flags & JeffJSObject.flagSlotIsAux) == 0 { return nil }
            return Unmanaged<JeffJSObjectAux>.fromOpaque(
                unsafeBitCast(_slot, to: UnsafeRawPointer?.self).unsafelyUnwrapped)
        }
    }
    final var aux: JeffJSObjectAux? {
        @inline(__always) get {
            if (_flags & JeffJSObject.flagSlotIsAux) == 0 { return nil }
            return unsafeBitCast(_slot, to: JeffJSObjectAux?.self)
        }
        set {
            if let a = newValue {
                if (_flags & JeffJSObject.flagSlotIsAux) == 0 {
                    a.fastArrayValues = unsafeBitCast(_slot, to: JeffJSFastArrayStorage?.self)
                }
                _slot = a
                _flags |= JeffJSObject.flagSlotIsAux
            } else if (_flags & JeffJSObject.flagSlotIsAux) != 0 {
                let st = unsafeBitCast(_slot, to: JeffJSObjectAux?.self)?.fastArrayValues
                _flags &= ~JeffJSObject.flagSlotIsAux
                _slot = st
            }
        }
    }

    // -- Fast array storage (reference-type bypass for COW avoidance) --------
    // When non-nil, this is the authoritative backing store for the array
    // (and the `.array` payload is a view of it). In `_slot`, or in the side
    // box when the array has one.
    var _fastArrayValues: JeffJSFastArrayStorage? {
        @inline(__always) get {
            if (_flags & JeffJSObject.flagSlotIsAux) == 0 {
                return unsafeBitCast(_slot, to: JeffJSFastArrayStorage?.self)
            }
            return unsafeBitCast(_slot, to: JeffJSObjectAux?.self).unsafelyUnwrapped.fastArrayValues
        }
        set {
            if (_flags & JeffJSObject.flagSlotIsAux) == 0 { _slot = newValue }
            else { unsafeBitCast(_slot, to: JeffJSObjectAux?.self).unsafelyUnwrapped.fastArrayValues = newValue }
        }
    }
    /// WeakMap/WeakSet key count (see "Weak collections" in
    /// JeffJSBuiltinMap.swift): zero for every object that is not a live weak
    /// key, so it lives in the side box.
    var weakrefCount: UInt32 {
        @inline(__always) get { auxRead(0) { $0.weakrefCount } }
        set { if newValue == 0 && _auxU == nil { return }; ensureAux().weakrefCount = newValue }
    }

    @inline(__always) final func ensureAux() -> JeffJSObjectAux {
        if let u = _auxU { return u.takeUnretainedValue() }
        return makeAux()
    }
    @inline(never) final func makeAux() -> JeffJSObjectAux {
        let a = JeffJSObjectAux()
        aux = a
        return a
    }
    /// Detach the side box (freeObject): the object reads every boxed field
    /// as its default from here on; the caller owns the returned box.
    @inline(__always) final func takeAux() -> JeffJSObjectAux? {
        guard let a = aux else { return nil }
        aux = nil   // the slot gets the array store back, if any
        a.fastArrayValues = nil
        _propExtraCount = 0
        _flags &= ~(JeffJSObject.flagHasCFunc | JeffJSObject.flagHasArrowThis | JeffJSObject.flagHasVarRefs)
        return a
    }
    /// Read a side-box field without retaining the box.
    @inline(__always) final func auxRead<T>(_ d: T, _ f: (JeffJSObjectAux) -> T) -> T {
        if let u = _auxU { return u._withUnsafeGuaranteedRef(f) }
        return d
    }

    // -- Flag bits -------------------------------------------------------------

    static let flagStdArrayPrototype: UInt16       = 1 << 0
    static let flagExtensible: UInt16              = 1 << 1
    static let flagFreeMark: UInt16                = 1 << 2
    static let flagExotic: UInt16                  = 1 << 3
    static let flagFastArray: UInt16               = 1 << 4
    static let flagConstructor: UInt16             = 1 << 5
    static let flagImmutablePrototype: UInt16      = 1 << 6
    static let flagTmpMark: UInt16                 = 1 << 7
    static let flagHTMLDDA: UInt16                 = 1 << 8
    static let flagProtectedGlobal: UInt16         = 1 << 9
    static let flagNativeNameKeepsPrefix: UInt16   = 1 << 10
    static let flagPlatformFunction: UInt16        = 1 << 11
    /// The side box holds a non-nil `cFuncFast` / `arrowThisVal` / non-empty
    /// var-refs: the call paths test the bit and touch the box only then.
    static let flagHasCFunc: UInt16                = 1 << 12
    static let flagHasArrowThis: UInt16            = 1 << 13
    static let flagHasVarRefs: UInt16              = 1 << 14
    /// `_slot` holds the side box (else an array store or nothing).
    static let flagSlotIsAux: UInt16               = 1 << 15

    @inline(__always) final func _flag(_ m: UInt16) -> Bool { (_flags & m) != 0 }
    @inline(__always) final func _setFlag(_ m: UInt16, _ v: Bool) {
        if v { _flags |= m } else { _flags &= ~m }
    }

    var isStdArrayPrototype: Bool {
        @inline(__always) get { _flag(JeffJSObject.flagStdArrayPrototype) }
        @inline(__always) set { _setFlag(JeffJSObject.flagStdArrayPrototype, newValue) }
    }
    var extensible: Bool {
        @inline(__always) get { _flag(JeffJSObject.flagExtensible) }
        @inline(__always) set { _setFlag(JeffJSObject.flagExtensible, newValue) }
    }
    var freeMark: Bool {
        @inline(__always) get { _flag(JeffJSObject.flagFreeMark) }
        @inline(__always) set { _setFlag(JeffJSObject.flagFreeMark, newValue) }
    }
    var isExotic: Bool {
        @inline(__always) get { _flag(JeffJSObject.flagExotic) }
        @inline(__always) set { _setFlag(JeffJSObject.flagExotic, newValue) }
    }
    var fastArray: Bool {
        @inline(__always) get { _flag(JeffJSObject.flagFastArray) }
        @inline(__always) set { _setFlag(JeffJSObject.flagFastArray, newValue) }
    }
    var isConstructor: Bool {
        @inline(__always) get { _flag(JeffJSObject.flagConstructor) }
        @inline(__always) set { _setFlag(JeffJSObject.flagConstructor, newValue) }
    }
    var hasImmutablePrototype: Bool {
        @inline(__always) get { _flag(JeffJSObject.flagImmutablePrototype) }
        @inline(__always) set { _setFlag(JeffJSObject.flagImmutablePrototype, newValue) }
    }
    var tmpMark: Bool {
        @inline(__always) get { _flag(JeffJSObject.flagTmpMark) }
        @inline(__always) set { _setFlag(JeffJSObject.flagTmpMark, newValue) }
    }
    var isHTMLDDA: Bool {
        @inline(__always) get { _flag(JeffJSObject.flagHTMLDDA) }
        @inline(__always) set { _setFlag(JeffJSObject.flagHTMLDDA, newValue) }
    }
    /// The context's global object (freeObject tripwire; never recycled).
    var isProtectedGlobal: Bool {
        @inline(__always) get { _flag(JeffJSObject.flagProtectedGlobal) }
        @inline(__always) set { _setFlag(JeffJSObject.flagProtectedGlobal, newValue) }
    }
    /// A native ECMAScript accessor ("get size", "get __proto__", "get
    /// [Symbol.species]") whose source text keeps the "get "/"set " prefix,
    /// as JavaScriptCore prints them; DOM (WebIDL) accessors print the bare
    /// attribute name (`function cookie()`).
    var nativeNameKeepsAccessorPrefix: Bool {
        @inline(__always) get { _flag(JeffJSObject.flagNativeNameKeepsPrefix) }
        @inline(__always) set { _setFlag(JeffJSObject.flagNativeNameKeepsPrefix, newValue) }
    }
    /// A JS-implemented platform function (a host polyfill standing in for a
    /// WebKit built-in): Function.prototype.toString prints it as native code.
    /// Set through `JeffJSContext.markPlatformFunction`.
    var isPlatformFunction: Bool {
        @inline(__always) get { _flag(JeffJSObject.flagPlatformFunction) }
        @inline(__always) set { _setFlag(JeffJSObject.flagPlatformFunction, newValue) }
    }

    // -- Class ------------------------------------------------------------------

    var classID: Int {
        @inline(__always) get { Int(_classID) }
        @inline(__always) set { _classID = UInt16(truncatingIfNeeded: newValue) }
    }

    // -- Shape --------------------------------------------------------------------


    // -- Rare-property side table --------------------------------------------

    var propExtra: ContiguousArray<JeffJSPropertyExtra?> {
        get { auxRead([]) { $0.propExtra } }
        set {
            if newValue.isEmpty && _auxU == nil { _propExtraCount = 0; return }
            let a = ensureAux()
            a.propExtra = newValue
            _propExtraCount = Int32(truncatingIfNeeded: a.propExtra.count)
        }
        _modify {
            let a = ensureAux()
            yield &a.propExtra
            _propExtraCount = Int32(truncatingIfNeeded: a.propExtra.count)
        }
    }
    var propExtraCount: Int {
        @inline(__always) get { Int(_propExtraCount) }
    }

    // -- First weak ref in chain ---------------------------------------------

    var firstWeakRef: AnyObject? {
        @inline(__always) get { auxRead(nil) { $0.firstWeakRef } }
        set { if newValue == nil && _auxU == nil { return }; ensureAux().firstWeakRef = newValue }
    }

    // -- Payload (union) -----------------------------------------------------

    /// An array's `.array` payload is a VIEW of its element store
    /// (`_fastArrayValues`, which every array now has): writing one installs
    /// a store, reading one wraps the store's buffer (O(1), shared). Arrays
    /// therefore need no side box (perf/watch-object-size: the box was 192 B
    /// per array, 80 k arrays on homedepot).
    var payload: JeffJSObjectPayload {
        @inline(__always) get {
            // Non-array objects (functions, typed arrays, maps...) never have
            // an element store: one nil test, then the box's payload as is.
            if _fastArrayValues == nil {
                if let u = _auxU { return u._withUnsafeGuaranteedRef { $0.payload } }
                return .opaque(nil)
            }
            return arrayPayloadSlow()
        }
        set {
            if case .array(_, let values, let count) = newValue {
                _fastArrayValues = JeffJSFastArrayStorage(values: ContiguousArray(values), count: count)
                if let u = _auxU {
                    u._withUnsafeGuaranteedRef { $0.payload = .opaque(nil) }
                    _flags &= ~JeffJSObject.flagHasCFunc
                }
                return
            }
            if _auxU == nil, case .opaque(let o) = newValue, o == nil { return }
            let a = ensureAux()
            a.payload = newValue
            if case .cFunc(let realm, let cf, _, _, let magic) = newValue {
                a.cFuncFast = cf; a.cMagicFast = Int(magic)
                _flags |= JeffJSObject.flagHasCFunc
                if let realm { realmIndex = realm.realmIndex }
            }
            else if (_flags & JeffJSObject.flagHasCFunc) != 0 {
                a.cFuncFast = nil
                _flags &= ~JeffJSObject.flagHasCFunc
            }
        }
    }

    // -- Denormalized .bytecodeFunc payload (call-path fast fields) -----------
    // Pattern-matching `case .bytecodeFunc(...) = payload` copies the enum
    // (retaining the FB and the varRefs array) on every JS call. The hot call
    // path reads these instead; they are kept in sync at every payload write.
    /// Native-function dispatch fields, mirrored from the `.cFunc` payload so
    /// callFunction never pattern-matches (copies) the payload enum: that copy
    /// retained the realm context, whose refcount lives in a side table.
    var cFuncFast: JSCFunctionType? {
        @inline(__always) get {
            if (_flags & JeffJSObject.flagHasCFunc) == 0 { return nil }
            return _auxU.unsafelyUnwrapped._withUnsafeGuaranteedRef { $0.cFuncFast }
        }
        set {
            if newValue == nil {
                _flags &= ~JeffJSObject.flagHasCFunc
                if let u = _auxU { u._withUnsafeGuaranteedRef { $0.cFuncFast = nil } }
                return
            }
            ensureAux().cFuncFast = newValue
            _flags |= JeffJSObject.flagHasCFunc
        }
    }
    var cMagicFast: Int {
        @inline(__always) get { auxRead(0) { $0.cMagicFast } }
        set { if newValue == 0 && _auxU == nil { return }; ensureAux().cMagicFast = newValue }
    }
    var fbFast: JeffJSFunctionBytecode? {
        @inline(__always) get { auxRead(nil) { $0.fbFast } }
        set {
            if newValue == nil && _auxU == nil { return }
            let a = ensureAux()
            a.fbFast = newValue
        }
    }
    /// Unmanaged mirror of `fbFast` for the trace's call path: a plain load,
    /// where reading the strong optional retains and releases per call.
    var fbFastU: Unmanaged<JeffJSFunctionBytecode>? {
        @inline(__always) get { auxRead(nil) { $0.fbFastU } }
    }
    var varRefsFast: [JeffJSVarRef?] {
        @inline(__always) get {
            if (_flags & JeffJSObject.flagHasVarRefs) == 0 { return [] }
            return _auxU.unsafelyUnwrapped._withUnsafeGuaranteedRef { $0.varRefsFast }
        }
        set {
            if newValue.isEmpty {
                _flags &= ~JeffJSObject.flagHasVarRefs
                if let u = _auxU { u._withUnsafeGuaranteedRef { $0.setVarRefs([]) } }
                return
            }
            ensureAux().setVarRefs(newValue)
            _flags |= JeffJSObject.flagHasVarRefs
        }
    }
    /// Unmanaged raw mirror of `varRefsFast` for the fast trace: no array
    /// retain per call and no element retain per access. The array keeps the
    /// var-refs alive, so unretained pointers are safe.
    var varRefsRaw: UnsafeMutablePointer<Unmanaged<JeffJSVarRef>?>? {
        @inline(__always) get {
            if (_flags & JeffJSObject.flagHasVarRefs) == 0 { return nil }
            return _auxU.unsafelyUnwrapped._withUnsafeGuaranteedRef { $0.varRefsRaw }
        }
    }
    var varRefsRawCount: Int {
        @inline(__always) get {
            if (_flags & JeffJSObject.flagHasVarRefs) == 0 { return 0 }
            return _auxU.unsafelyUnwrapped._withUnsafeGuaranteedRef { $0.varRefsRawCount }
        }
    }

    // -- Arrow function lexical `this` capture --------------------------------
    // When an arrow function closure is created, the enclosing function's
    // `this` value is stored here so that `push_this` inside the arrow
    // function returns the lexical `this` instead of the call-site `this`.
    var arrowThisVal: JeffJSValue? {
        @inline(__always) get {
            if (_flags & JeffJSObject.flagHasArrowThis) == 0 { return nil }
            return _auxU.unsafelyUnwrapped._withUnsafeGuaranteedRef { $0.arrowThisVal }
        }
        set {
            if newValue == nil {
                _flags &= ~JeffJSObject.flagHasArrowThis
                if let u = _auxU { u._withUnsafeGuaranteedRef { $0.arrowThisVal = nil } }
                return
            }
            ensureAux().arrowThisVal = newValue
            _flags |= JeffJSObject.flagHasArrowThis
        }
    }


    // -- Lazy function prototype ----------------------------------------------
    // Plain function closures defer building `F.prototype = { constructor: F }`
    // (an object + shape + two property defines per closure) until the first
    // read of `.prototype`. Mirrors QuickJS's JS_PROP_AUTOINIT.
    /// Which own properties of this object are deferred. Kept as one bitmask
    /// so the property-lookup fast path tests a single byte instead of three
    /// separate fields (`lazyFlags != 0`).
    @inline(__always) static let lazyPrototypeBit: UInt8 = 1
    @inline(__always) static let lazyNameLengthBit: UInt8 = 2
    @inline(__always) static let lazyStackBit: UInt8 = 4

    var needsLazyPrototype: Bool {
        @inline(__always) get { (lazyFlags & JeffJSObject.lazyPrototypeBit) != 0 }
        @inline(__always) set {
            if newValue { lazyFlags |= JeffJSObject.lazyPrototypeBit }
            else { lazyFlags &= ~JeffJSObject.lazyPrototypeBit }
        }
    }
    /// `name` and `length` on a bytecode function are materialised on first
    /// own-property access (see JeffJSContext.materializeFunctionNameLength).
    /// Defining them eagerly cost two property slots + two shape transitions
    /// on every closure creation, and almost no closure is ever asked for
    /// its name.
    var needsLazyNameLength: Bool {
        @inline(__always) get { (lazyFlags & JeffJSObject.lazyNameLengthBit) != 0 }
        @inline(__always) set {
            if newValue { lazyFlags |= JeffJSObject.lazyNameLengthBit }
            else { lazyFlags &= ~JeffJSObject.lazyNameLengthBit }
        }
    }
    /// Captured call site of an Error, formatted into `stack` on first read.
    /// Formatting eagerly cost ~2.3 us per `new Error()` (25 000 of them in
    /// bench/realworld.js `try-catch-throw`), and almost no thrown error ever
    /// has its `stack` looked at.
    /// The captured frames live in `payload` (an Error object has no other use
    /// for it), so JeffJSObject does not grow a field for them — an extra
    /// pointer on *every* object cost ~5% on object allocation.
    var pendingStack: JeffJSPendingStack? {
        @inline(__always) get {
            if case .pendingErrorStack(let p) = payload { return p }
            return nil
        }
    }

    @inline(__always)
    func setPendingStack(_ p: JeffJSPendingStack?) {
        if let p = p {
            payload = .pendingErrorStack(p)
            lazyFlags |= JeffJSObject.lazyStackBit
        } else {
            if case .pendingErrorStack = payload { payload = .opaque(nil) }
            lazyFlags &= ~JeffJSObject.lazyStackBit
        }
    }

    // -- Associated storage (moved from objc_setAssociatedObject) ----------
    /// The prototype mirror. The shape owns the counted reference to the
    /// prototype (`jeffJS_shapeSetProto`) and every write path keeps the two
    /// equal, so with a shape the prototype is read from it; only a
    /// shape-less object (transiently, while being built) keeps its own copy
    /// in the side box. Was a strong stored field on every object.
    var storedProto: JeffJSObject? {
        @inline(__always) get {
            if let s = shape { return s.proto }
            return auxRead(nil) { $0.storedProto }
        }
        set {
            if shape != nil {
                if let u = _auxU, u._withUnsafeGuaranteedRef({ $0.storedProto != nil }) {
                    u._withUnsafeGuaranteedRef { $0.storedProto = nil }
                }
                return
            }
            if newValue == nil && _auxU == nil { return }
            ensureAux().storedProto = newValue
        }
    }
    var storedCFunction: ((JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue)? {
        @inline(__always) get { auxRead(nil) { $0.storedCFunction } }
        set { if newValue == nil && _auxU == nil { return }; ensureAux().storedCFunction = newValue }
    }
    var storedCFunctionLength: Int {
        @inline(__always) get { auxRead(0) { $0.storedCFunctionLength } }
        set { if newValue == 0 && _auxU == nil { return }; ensureAux().storedCFunctionLength = newValue }
    }
    var storedPrimitiveValue: JeffJSValue {
        @inline(__always) get { auxRead(.undefined) { $0.storedPrimitiveValue } }
        set { if newValue.isUndefined && _auxU == nil { return }; ensureAux().storedPrimitiveValue = newValue }
    }

    // -- Lifecycle -----------------------------------------------------------

    override init(refCount: Int = 1,
                  gcObjType: JSGCObjectTypeEnum = .jsObject,
                  mark: Bool = false) {
        super.init(refCount: refCount, gcObjType: gcObjType, mark: mark)
        // Every JS object joins the runtime's GC list, as quickjs's
        // JS_NewObjectFromShape does with add_gc_object(): reference counting
        // alone can never reclaim `o.self = o`, a parent <-> child tree or a
        // closure captured by the instance it closes over. The recycle pool
        // takes objects back off the list (see jeffJS_recycleObject).
        // Objects built while the intrinsics are being installed are not
        // tracked. They are the engine's roots (prototypes, constructors, the
        // global object), and during init `freeValueSlow` deliberately lets
        // refcounts fall to zero without freeing — "objects are context-scoped
        // and freed by context.free()" — so their counts do not describe
        // reachability and the collector must not judge them. Leaving them off
        // the list also makes every one of their property edges an uncounted
        // root edge, which is exactly right: whatever a global or a prototype
        // still points at is reachable.
        if let rt = ownerRuntime, rt.initComplete {
            addGCObject(rt, self)
            // quickjs calls js_trigger_gc here, before the object is wired
            // into the graph: `self` is already listed with refCount 1, so a
            // collection triggered now cannot reclaim it.
            if rt.mallocState.mallocSize >= rt.mallocGCThreshold,
               rt.gcPhase == .JS_GC_PHASE_NONE, !rt.inFreeChain {
                runGC(rt)
            }
        } else if let rt = ownerRuntime {
            // Untracked, so the runtime's teardown finds it here (JeffJSRuntime.initObjects).
            rt.initObjects.append(Unmanaged.passRetained(self))
        }
    }

    deinit { propValues.deallocateStorage() }
}

/// The fields of a JeffJSObject that only functions, exotic objects and rare
/// features use (see the layout note on JeffJSObject). One per object that
/// needs any of them; its lifetime is the object's.
/// Common native base of what a JeffJSObject's one strong slot can hold
/// (the side box or an array's element store): a native class reference,
/// so the slot is retained/released with the fast native entry points.
nonisolated class JeffJSSideSlot {
    init() {}
}

/// The side box's rarely set fields (native functions, wrapper objects,
/// weak keys, shape-less prototypes, boxed arrays), one level further out so
/// a closure's box stays at 128 bytes (perf/watch-object-size).
nonisolated final class JeffJSObjectAuxRare {
    var fastArrayValues: JeffJSFastArrayStorage? = nil
    var cFuncFast: JSCFunctionType? = nil
    var cMagicFast: Int32 = 0
    var storedCFunctionLength: Int32 = 0
    var weakrefCount: UInt32 = 0
    var firstWeakRef: AnyObject? = nil
    var storedProto: JeffJSObject? = nil
    var storedCFunction: ((JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue)? = nil
    var storedPrimitiveValue: JeffJSValue = .undefined
    init() {}
}

nonisolated final class JeffJSObjectAux: JeffJSSideSlot {
    // Layout: what a closure uses inline (payload, body, var-refs and their
    // raw mirror, captured `this`, accessor slots), the rest in `rare`.
    var payload: JeffJSObjectPayload = .opaque(nil)
    var fbFast: JeffJSFunctionBytecode? = nil
    var varRefsFast: [JeffJSVarRef?] = []
    var varRefsRaw: UnsafeMutablePointer<Unmanaged<JeffJSVarRef>?>? = nil
    private var _varRefsRawCount: Int32 = 0
    /// Slots allocated at `varRefsRaw` (kept across setVarRefs, so a pooled
    /// closure re-captures without a malloc).
    private var _varRefsRawCapacity: Int32 = 0
    var arrowThisVal: JeffJSValue? = nil
    var propExtra: ContiguousArray<JeffJSPropertyExtra?> = []
    var rare: JeffJSObjectAuxRare? = nil

    @inline(__always) private func rareBox() -> JeffJSObjectAuxRare {
        if let r = rare { return r }
        let r = JeffJSObjectAuxRare()
        rare = r
        return r
    }

    var varRefsRawCount: Int {
        get { Int(_varRefsRawCount) }
        set { _varRefsRawCount = Int32(truncatingIfNeeded: newValue) }
    }
    /// Unretained view of `fbFast` (its bits; no field).
    var fbFastU: Unmanaged<JeffJSFunctionBytecode>? {
        @inline(__always) get {
            unsafeBitCast(fbFast, to: UnsafeRawPointer?.self).map { Unmanaged<JeffJSFunctionBytecode>.fromOpaque($0) }
        }
    }
    /// An array's element store while the array also needs this box.
    var fastArrayValues: JeffJSFastArrayStorage? {
        get { rare?.fastArrayValues }
        set { if newValue == nil && rare == nil { return }; rareBox().fastArrayValues = newValue }
    }
    var cFuncFast: JSCFunctionType? {
        get { rare?.cFuncFast }
        set { if newValue == nil && rare == nil { return }; rareBox().cFuncFast = newValue }
    }
    var cMagicFast: Int {
        get { Int(rare?.cMagicFast ?? 0) }
        set { if newValue == 0 && rare == nil { return }; rareBox().cMagicFast = Int32(truncatingIfNeeded: newValue) }
    }
    var storedCFunctionLength: Int {
        get { Int(rare?.storedCFunctionLength ?? 0) }
        set { if newValue == 0 && rare == nil { return }; rareBox().storedCFunctionLength = Int32(truncatingIfNeeded: newValue) }
    }
    var weakrefCount: UInt32 {
        get { rare?.weakrefCount ?? 0 }
        set { if newValue == 0 && rare == nil { return }; rareBox().weakrefCount = newValue }
    }
    var firstWeakRef: AnyObject? {
        get { rare?.firstWeakRef }
        set { if newValue == nil && rare == nil { return }; rareBox().firstWeakRef = newValue }
    }
    var storedProto: JeffJSObject? {
        get { rare?.storedProto }
        set { if newValue == nil && rare == nil { return }; rareBox().storedProto = newValue }
    }
    var storedCFunction: ((JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue)? {
        get { rare?.storedCFunction }
        set { if newValue == nil && rare == nil { return }; rareBox().storedCFunction = newValue }
    }
    var storedPrimitiveValue: JeffJSValue {
        get { rare?.storedPrimitiveValue ?? .undefined }
        set { if newValue.isUndefined && rare == nil { return }; rareBox().storedPrimitiveValue = newValue }
    }

    override init() {}

    /// Set the closure var-refs and rebuild their unmanaged raw mirror.
    func setVarRefs(_ refs: [JeffJSVarRef?]) {
        varRefsFast = refs
        varRefsRawCount = 0
        if refs.isEmpty { return }   // the mirror buffer stays for reuse
        if varRefsRaw == nil || Int(_varRefsRawCapacity) < refs.count {
            varRefsRaw?.deallocate()
            let cap = max(refs.count, 4)
            varRefsRaw = UnsafeMutablePointer<Unmanaged<JeffJSVarRef>?>.allocate(capacity: cap)
            _varRefsRawCapacity = Int32(truncatingIfNeeded: cap)
        }
        let p = varRefsRaw.unsafelyUnwrapped
        var i = 0
        for vr in refs {
            if let vr = vr { p[i] = Unmanaged.passUnretained(vr) } else { p[i] = nil }
            i += 1
        }
        varRefsRawCount = refs.count
    }

    deinit { varRefsRaw?.deallocate() }
}

extension JeffJSObject {
    /// Recycle-pool eligibility (see JeffJSObjectPool.swift): a plain,
    /// non-exotic object holding only data slots, with no weak references,
    /// function payload or auxiliary storage. Cheap field tests only.
    /// An ordinary array that can be parked in the runtime's array pool when
    /// it dies: nothing but its elements (ref-type storage, default element
    /// attributes, not frozen/sealed/non-extensible) and `length` on a shared
    /// hashed shape. See JeffJSObjectPool.swift.
    var isPoolableArray: Bool {
        guard classID == JeffJSClassID.array.rawValue, fastArray, extensible, !isExotic,
              !isProtectedGlobal, !hasImmutablePrototype, !isHTMLDDA, !isStdArrayPrototype,
              !isConstructor, firstWeakRef == nil, _propExtraCount == 0,
              storedPrimitiveValue.isUndefined, fbFast == nil, arrowThisVal == nil,
              storedCFunction == nil, lazyFlags == 0,
              let st = _fastArrayValues, !st.checked, st.attrs == nil,
              let sh = shape, sh.isHashed, sh.propCount == 1, propValues.count == 1,
              sh.prop[0].atom == JeffJSAtomID.JS_ATOM_length.rawValue else { return false }
        return true
    }

    @inline(__always) var isPoolable: Bool {
        let bad: UInt16 = JeffJSObject.flagExotic | JeffJSObject.flagFastArray | JeffJSObject.flagProtectedGlobal
            | JeffJSObject.flagImmutablePrototype | JeffJSObject.flagHTMLDDA | JeffJSObject.flagStdArrayPrototype
            | JeffJSObject.flagConstructor
        guard _classID == UInt16(JeffJSClassID.object.rawValue), (_flags & bad) == 0,
              _propExtraCount == 0, _fastArrayValues == nil else { return false }
        // No side box: every field it would hold is at its default.
        if _auxU == nil { return true }
        return firstWeakRef == nil && storedPrimitiveValue.isUndefined && fbFast == nil
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
    case iteratorHelper  = 58     // JS_CLASS_ITERATOR_HELPER
    case iteratorWrap    = 59     // JS_CLASS_ITERATOR_WRAP

    static let initialCount: UInt16 = 60
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
/// True when `o` keeps its elements in the fast-array store (ref-type
/// storage or the `.array` payload).
@inline(__always)
func jeffJS_isFastArray(_ o: JeffJSObject) -> Bool {
    if o._fastArrayValues != nil { return true }
    if case .array = o.payload { return true }
    return false
}

/// Mirrors `find_own_property` in QuickJS.
@inline(__always)
func jeffJS_findOwnPropertyIndex(obj: JeffJSObject, atom: UInt32) -> Int {
    guard let shape = obj.shape else { return -1 }
    guard let idx = findShapeProperty(shape, atom) else {
        // Safety net for paths that look up own properties without a
        // chokepoint: a lazy payload stub builds its top level, then retries.
        if (obj.lazyFlags & JeffJSObject.lazyPayloadBit) != 0 {
            jeffJS_lazyMaterialize(obj)
            return jeffJS_findOwnPropertyIndex(obj: obj, atom: atom)
        }
        return -1
    }
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
        // The mirrored fields answer for bytecode and C functions without
        // copying the payload enum (which retains its associated values):
        // this ran on every native call.
        if fbFast != nil || cFuncFast != nil { return true }
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
        // propExtraCount > 0 implies the side box exists.
        i < propExtraCount ? _auxU.unsafelyUnwrapped._withUnsafeGuaranteedRef { $0.propExtra[i] } : nil
    }

    /// Store a box at slot `i`, materialising `propExtra` (nil-padded) on
    /// the first non-nil box.
    @inline(__always) func setExtraSlot(_ i: Int, _ e: JeffJSPropertyExtra?) {
        // A plain data slot with no box to clear (the hot case: every data
        // store) touches nothing but `_propExtraCount`; the rest is out of
        // line so the interpreter's inlined copies stay small.
        if e == nil && i >= propExtraCount { return }
        setExtraSlotSlow(i, e)
    }
    @inline(never) func setExtraSlotSlow(_ i: Int, _ e: JeffJSPropertyExtra?) {
        if propExtraCount < propValues.count {
            if e == nil { return }
            propExtra.append(contentsOf: repeatElement(nil, count: propValues.count - propExtraCount))
        }
        propExtra[i] = e
    }
    @inline(never) func appendNilExtraSlot() { propExtra.append(nil) }

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
            propValues.append(v); if _propExtraCount != 0 { appendNilExtraSlot() }
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
        propValues.append(v); if _propExtraCount != 0 { appendNilExtraSlot() }
    }

    /// Clear all property slots (equivalent to the old `obj.prop = []`).
    @inline(__always) func clearProps() {
        propValues.removeAll(keepingCapacity: false)
        if _propExtraCount != 0 || _auxU != nil { propExtra.removeAll(keepingCapacity: false) }
    }

    /// Replace all slots from an array of entries (cold; e.g. compaction).
    func replaceProps(_ entries: [JeffJSProperty]) {
        propValues.removeAll(keepingCapacity: true)
        if _propExtraCount != 0 { propExtra.removeAll(keepingCapacity: true) }
        propValues.reserveCapacity(entries.count)
        for p in entries { appendProp(p) }
    }

    /// Lookup a property value by atom, returning `.undefined` if absent.
    ///
    /// Borrowed result (no dup), as for a plain data slot. Accessor and
    /// autoinit slots still report `.undefined` — they need a context to
    /// evaluate — but a **mapped `arguments` slot** reads through its
    /// var-ref, so `apply`/`bind`/`Reflect.apply`/`JSON`/`Object.*` see the
    /// live parameter instead of `undefined`.
    func getOwnPropertyValue(atom: UInt32) -> JeffJSValue {
        let idx = jeffJS_findOwnPropertyIndex(obj: self, atom: atom)
        guard idx >= 0, idx < propValues.count else { return .undefined }
        guard let e = extra(at: idx) else { return propValues[idx] }
        if e.kind == .varRef, let vr = e.varRef { return vr.pvalue }
        return .undefined
    }

    /// Set a property value by atom.  Returns `true` on success.
    /// A mapped `arguments` slot writes through to the live parameter and
    /// stays mapped (the caller owns `value`; the replaced value is freed).
    @discardableResult
    func setOwnPropertyValue(atom: UInt32, value: JeffJSValue) -> Bool {
        let idx = jeffJS_findOwnPropertyIndex(obj: self, atom: atom)
        guard idx >= 0, idx < propValues.count else { return false }
        if let e = extra(at: idx), e.kind == .varRef, let vr = e.varRef {
            vr.store(value)   // releases the replaced value when the slot owns it
            return true
        }
        propValues[idx] = value; setExtraSlot(idx, nil)
        return true
    }

    /// Number of elements for a fast array.
    var arrayCount: UInt32 {
        ensureLazyMaterialized()
        if let storage = _fastArrayValues { return storage.count }
        if case .array(_, _, let c) = payload { return c }
        return 0
    }

    /// Elements and count of a fast array from the authoritative storage
    /// (the enum payload is stale once the ref-type store exists). nil for
    /// non-array payloads. Readers must use this, not `case .array`.
    func arraySnapshot() -> (values: ContiguousArray<JeffJSValue>, count: Int)? {
        ensureLazyMaterialized()
        if let storage = _fastArrayValues { return (storage.values, Int(storage.count)) }
        if case .array(_, let vals, let count) = payload { return (ContiguousArray(vals), Int(count)) }
        return nil
    }

    /// Direct access to fast-array element at `index`.
    func getArrayElement(_ index: UInt32) -> JeffJSValue {
        if let storage = _fastArrayValues {
            guard index < storage.count, Int(index) < storage.values.count else { return .undefined }
            return storage.values[Int(index)].arrayHoleAsUndefined
        }
        if case .array(_, let vals, let count) = payload {
            guard index < count, Int(index) < vals.count else { return .undefined }
            return vals[Int(index)].arrayHoleAsUndefined
        }
        return .undefined
    }

    /// True when index `i` is a present (non-hole) fast-array element.
    func hasArrayElement(_ index: UInt32) -> Bool {
        if let storage = _fastArrayValues {
            guard index < storage.count, Int(index) < storage.values.count else { return false }
            return !storage.values[Int(index)].isUninitialized
        }
        if case .array(_, let vals, let count) = payload {
            guard index < count, Int(index) < vals.count else { return false }
            return !vals[Int(index)].isUninitialized
        }
        return false
    }

    /// `delete a[i]` on a fast array: punch a hole, keeping `length`.
    /// Returns false when `i` is not a fast-array slot (caller falls back to
    /// the shape path).
    func deleteArrayElement(_ index: UInt32) -> Bool {
        if let storage = _fastArrayValues {
            guard index < storage.count, Int(index) < storage.values.count else { return false }
            storage.values[Int(index)].freeValue()
            storage.values[Int(index)] = .uninitialized
            // A later add at this index is a fresh default property.
            if storage.attrs != nil { storage.setAttr(Int(index), JeffJSFastArrayStorage.attrDefault) }
            return true
        }
        if case .array(let size, var vals, let count) = payload {
            guard index < count, Int(index) < vals.count else { return false }
            vals[Int(index)].freeValue()
            vals[Int(index)] = .uninitialized
            payload = .array(size: size, values: vals, count: count)
            return true
        }
        return false
    }

    /// The ref-type element storage of a fast array, converting from the
    /// `.array` enum payload on first use (the same switch setArrayElement
    /// performs on the first store) so callers can read elements in place.
    /// nil when this object has no array payload.
    func fastArrayStorage() -> JeffJSFastArrayStorage? {
        if let st = _fastArrayValues { return st }
        guard case .array(_, let vals, let count) = payload else { return nil }
        let st = JeffJSFastArrayStorage(values: ContiguousArray(vals), count: count)
        _fastArrayValues = st
        return st
    }

    /// Switch this array's element writes to the checked path (see
    /// `JeffJSFastArrayStorage.checked`), materialising the ref-type storage
    /// if the elements still live in the `.array` payload. Returns the
    /// storage, or nil when the object has no fast elements.
    @discardableResult
    func markArrayWritesChecked() -> JeffJSFastArrayStorage? {
        guard let st = fastArrayStorage() else { return nil }
        st.checked = true
        return st
    }

    /// Bulk-installs `values` as this array's elements, taking ownership of
    /// each. Only valid on a fast array that has no elements yet.
    func installFastArrayValues(_ values: ContiguousArray<JeffJSValue>) {
        _fastArrayValues = JeffJSFastArrayStorage(values: values,
                                                  count: UInt32(values.count))
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
                // The slots skipped over by `a[1000] = 1` are holes, not
                // `undefined`: `5 in a` is false and `Object.keys` must not
                // invent them. Filling with `.undefined` made every skipped
                // index look like a present element.
                for _ in 0..<fillCount { storage.values.append(.uninitialized) }
            }
            if index < storage.count { storage.values[idx].freeValue() }   // overwrite releases the old element
            storage.values[idx] = value
            if index >= storage.count { storage.count = index + 1 }
            return true
        }

        guard case .array(_, let vals, let count) = payload else { return false }
        // First indexed store: switch to the ref-type storage so later stores
        // happen in place. Extracting the enum's array and writing it back
        // copied the whole array per store (map/filter/Array.from/split
        // results were quadratic: memmove was 71% of a callback profile).
        let storage = JeffJSFastArrayStorage(values: ContiguousArray(vals), count: count)
        _fastArrayValues = storage
        return setArrayElement(index, value: value)
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
            if var a = storage.attrs, a.count > max(newLen, 0) {
                a.removeSubrange(max(newLen, 0)...)
                storage.attrs = a
            }
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

    /// Formerly copied the ref-type store back into the `.array` payload;
    /// the payload is now a view of the store (see `payload`), so there is
    /// nothing to sync.
    func syncArrayPayload() {}

    /// `payload` of an object with an element store: the box's payload when
    /// it holds one (never for an array), else the view of the store.
    @inline(never)
    final func arrayPayloadSlow() -> JeffJSObjectPayload {
        if let u = _auxU {
            let p = u._withUnsafeGuaranteedRef { $0.payload }
            if case .opaque(.none) = p {} else { return p }
        }
        return JeffJSObject.arrayPayloadView(_fastArrayValues.unsafelyUnwrapped)
    }

    /// The `.array` payload view of an element store.
    @inline(__always)
    static func arrayPayloadView(_ st: JeffJSFastArrayStorage) -> JeffJSObjectPayload {
        .array(size: UInt32(st.values.count), values: Array(st.values), count: st.count)
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

    /// Read through a guaranteed (+0, no retain/release) reference. The
    /// fields that became computed properties (perf/watch-object-size: bit
    /// flags, 16-bit class id, unmanaged shape and side box) are read through
    /// this so the hot paths keep their zero-ARC access.
    @inline(__always)
    func _with<T>(_ f: (JeffJSObject) -> T) -> T {
        Unmanaged<JeffJSObject>.fromOpaque(UnsafeRawPointer(_ptr))._withUnsafeGuaranteedRef(f)
    }

    // MARK: - GC Header Fields (from JeffJSGCObjectHeader)

    @inline(__always) var refCount: Int {
        get { _with { $0.refCount } }
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
        get { _with { Int($0._classID) } }
        nonmutating set { _obj.classID = newValue }
    }

    @inline(__always) var extensible: Bool {
        get { _with { ($0._flags & JeffJSObject.flagExtensible) != 0 } }
        nonmutating set { _obj.extensible = newValue }
    }

    @inline(__always) var isConstructor: Bool {
        get { _with { ($0._flags & JeffJSObject.flagConstructor) != 0 } }
        nonmutating set { _obj.isConstructor = newValue }
    }

    @inline(__always) var isExotic: Bool {
        _with { ($0._flags & JeffJSObject.flagExotic) != 0 }
    }

    @inline(__always) var fastArray: Bool {
        get { _with { ($0._flags & JeffJSObject.flagFastArray) != 0 } }
        nonmutating set { _obj.fastArray = newValue }
    }

    @inline(__always) var isHTMLDDA: Bool {
        _with { ($0._flags & JeffJSObject.flagHTMLDDA) != 0 }
    }

    @inline(__always) var tmpMark: Bool {
        get { _with { ($0._flags & JeffJSObject.flagTmpMark) != 0 } }
        nonmutating set { _obj.tmpMark = newValue }
    }

    @inline(__always) var isStdArrayPrototype: Bool {
        _with { ($0._flags & JeffJSObject.flagStdArrayPrototype) != 0 }
    }

    @inline(__always) var hasImmutablePrototype: Bool {
        _with { ($0._flags & JeffJSObject.flagImmutablePrototype) != 0 }
    }

    @inline(__always) var freeMark: Bool {
        get { _with { ($0._flags & JeffJSObject.flagFreeMark) != 0 } }
        nonmutating set { _obj.freeMark = newValue }
    }

    @inline(__always) var weakrefCount: UInt32 {
        get { _with { $0.weakrefCount } }
        nonmutating set { _obj.weakrefCount = newValue }
    }

    @inline(__always) var shape: JeffJSShape? {
        get { _with { $0.shape } }
        nonmutating set { _obj.shape = newValue }
    }
    @inline(__always) var shapeIdentity: UnsafeRawPointer? { _with { $0.shapeIdentity } }

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
    @inline(__always) var propCount: Int { _with { $0.propValues.count } }
    @inline(__always) func dataValue(at i: Int) -> JeffJSValue { _with { $0.propValues[i] } }
    @inline(__always) func extra(at i: Int) -> JeffJSPropertyExtra? { _with { $0.extra(at: i) } }
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
        get { _with { $0.payload } }
        nonmutating set { _obj.payload = newValue }
    }

    @inline(__always) var fbFast: JeffJSFunctionBytecode? {
        get { _with { $0.fbFast } }
        nonmutating set { _obj.fbFast = newValue }
    }
    @inline(__always) var fbFastU: Unmanaged<JeffJSFunctionBytecode>? { _with { $0.fbFastU } }
    @inline(__always) var cFuncFast: JSCFunctionType? { _with { $0.cFuncFast } }
    @inline(__always) var realmIndex: UInt8 { _with { $0.realmIndex } }
    @inline(__always) var cMagicFast: Int { _with { $0.cMagicFast } }

    @inline(__always) var varRefsRaw: UnsafeMutablePointer<Unmanaged<JeffJSVarRef>?>? { _with { $0.varRefsRaw } }
    @inline(__always) var varRefsRawCount: Int { _with { $0.varRefsRawCount } }
    @inline(__always) var varRefsFast: [JeffJSVarRef?] {
        get { _obj.varRefsFast }
        nonmutating set { _obj.varRefsFast = newValue }
    }

    @inline(__always) var _fastArrayValues: JeffJSFastArrayStorage? {
        get { _with { $0._fastArrayValues } }
        nonmutating set { _obj._fastArrayValues = newValue }
    }

    @inline(__always) var arrowThisVal: JeffJSValue? {
        get { _with { $0.arrowThisVal } }
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


// MARK: - Deferred Error stack

/// The frames captured when an Error was constructed. `JeffJSContext`
/// turns this into the `stack` string the first time the property is read
/// (see materializeErrorStack).
nonisolated final class JeffJSPendingStack {
    let errorName: String
    let message: String
    /// (function bytecode, pc) per frame, innermost first.
    var frames: [(fb: JeffJSFunctionBytecode, pc: Int)]
    /// Native frames: (index of the script frame they sit above, name).
    var natives: [(before: Int, name: String)] = []

    init(errorName: String, message: String,
         frames: [(fb: JeffJSFunctionBytecode, pc: Int)],
         natives: [(before: Int, name: String)] = []) {
        self.errorName = errorName
        self.message = message
        self.frames = frames
        self.natives = natives
    }
}
