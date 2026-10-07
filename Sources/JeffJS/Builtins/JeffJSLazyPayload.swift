// JeffJSLazyPayload.swift
// JeffJS — lazy JSON payloads (perf/lazy-payload, 2026-10-06).
//
// A large `JSON.parse(text)` (text ≥ `json.lazyThresholdBytes`, default
// 16 KB) and a large pure-data object/array literal in script source
// (`ytInitialData = {…}`, `window.__APOLLO_STATE__ = {…}`, ≥
// `compile.lazyLiteralMinBytes`) cost memory proportional to what the page
// reads, not to their size:
//
//  * The text is validated once, up front, by a real JSON tokenizer
//    (`jeffJS_lazyJSONValidate`: no allocation; malformed input, a
//    `__proto__` key or a reviver take the eager parser, so every error and
//    every corner behaves exactly as before). The validator also records the
//    end offset of every container of ≥ `skipMinBytes` bytes (the buffer's
//    skip table), so a later scan steps over a large nested value in
//    O(log n) instead of byte by byte.
//  * The result is a *stub*: a plain JeffJSObject (class Object or Array, so
//    `Array.isArray`, `typeof` and `Object.prototype.toString` answer without
//    touching it) on the realm's lazy sentinel shape (no properties, the
//    right prototype, never cached by an inline cache), with
//    `lazyFlags & lazyPayloadBit` set and a record (buffer, start offset) in
//    the runtime's side table.
//  * Any own-property operation on a stub (get, set, has, delete, define,
//    keys, for-in, spread, stringify, freeze, setPrototypeOf …) first
//    *materializes its top level*: one scan of its own members builds the
//    ordinary shape (the same hashed transition shapes an eager parse makes,
//    so objects of one kind share one shape — the shape is the compact key
//    table) and its slots: numbers/booleans/null/strings become values,
//    nested objects and arrays become stubs over their spans. From then on
//    the object is an ordinary object — inline caches hit, every builtin's
//    fast path applies — and identity is stable (a child stub sits in its
//    parent's slot, so the same path is the same JS object).
//  * Writes need no special path: after materialization the object *is* the
//    normal object (copy-on-write at object granularity; the parent keeps
//    pointing at it).
//  * Eviction (`JeffJSRuntime.evictLazyPayloads`, run on memory pressure with
//    the aggressive lazy-body reclaim, or `json.lazyEvictOnIdle`): an object
//    materialized from a span whose state is still exactly what its span
//    says (`jeffJS_lazyIsPristine`: same keys/flags/order, equal primitive
//    values, every object-valued slot an unmaterialized stub of the right
//    span held only by this object, default prototype, extensible, no side
//    box) is reverted in place to a stub: its slots are freed (the child
//    stubs with them), its identity stays, and the next access rebuilds it
//    identically. Runs bottom-up (children before parents) with no JS on
//    the stack.
//
// The bytes come from a `LazyBytesSource` (JSON text: the parsed string's own
// UTF-8 bytes — shared with the JS string when it is ASCII; literals: the
// script's UTF-8 source), a protocol so a memory-mapped file can back it.
//
// Switches: `JEFFJS_JSON_LAZY=0`, `JEFFJS_COMPILE_LAZYLITERALS=0` (eager).

import Foundation

// MARK: - Byte sources

/// Immutable bytes a lazy payload is scanned from. The bytes must not change
/// for the lifetime of the source; `withBytes` may be called many times.
protocol LazyBytesSource: AnyObject {
    var byteCount: Int { get }
    func withBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) -> R) -> R
}

/// A Swift byte array (the JSON text's UTF-8; for an ASCII JS string it is
/// the string's own storage, copy-on-write shared).
nonisolated final class JeffJSByteArraySource: LazyBytesSource {
    let bytes: [UInt8]
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    var byteCount: Int { bytes.count }
    func withBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        bytes.withUnsafeBufferPointer(body)
    }
}

/// A script's UTF-8 source (shared with lazy compilation).
extension JeffJSSourceText: LazyBytesSource {
    var byteCount: Int { bytes.count }
    func withBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        bytes.withUnsafeBufferPointer(body)
    }
}

// MARK: - Buffers and records

/// One validated payload: its bytes, the skip table of its large containers
/// and the realm that materializes it. Pinned by every live record.
nonisolated final class JeffJSLazyPayloadBuffer {
    let source: LazyBytesSource
    /// `(start << 32) | endExclusive` of every container of ≥ skipMinBytes,
    /// sorted by start.
    let skips: [UInt64]
    weak var ctx: JeffJSContext?
    /// Slot in `JeffJSLazyPayloadState.buffers`.
    var index: Int = -1
    /// Records that point at this buffer: every unmaterialized stub, and the
    /// root (kept after it materializes: eviction walks down from it).
    var liveRecords: Int = 0
    /// The payload's root object (unretained; cleared when it is freed) and
    /// its span start. Eviction starts there.
    var root: Unmanaged<JeffJSObject>? = nil
    var rootStart: Int = 0
    /// Short string values already built from this buffer (≤ 24 bytes,
    /// no escapes): one string per spelling, as the eager parse dedups.
    /// Holds one reference each; released with the buffer.
    var strCache: [UInt64: JeffJSValue] = [:]
    static let strCacheMaxLen = 24
    static let strCacheMaxEntries = 2048

    init(source: LazyBytesSource, skips: [UInt64], ctx: JeffJSContext?) {
        self.source = source
        self.skips = skips
        self.ctx = ctx
    }

    func releaseStrings() {
        for (_, v) in strCache { v.freeValue() }
        strCache.removeAll()
    }

    /// End (exclusive) of the container starting at `start`, if recorded.
    @inline(__always)
    func skipEnd(_ start: Int) -> Int? {
        var lo = 0, hi = skips.count
        let key = UInt64(start)
        while lo < hi {
            let mid = (lo + hi) >> 1
            let s = skips[mid] >> 32
            if s < key { lo = mid + 1 } else { hi = mid }
        }
        if lo < skips.count, skips[lo] >> 32 == key { return Int(skips[lo] & 0xFFFF_FFFF) }
        return nil
    }
}

/// Per-runtime lazy payload state: the buffers and the object → (buffer,
/// start) records.
nonisolated final class JeffJSLazyPayloadState {
    var buffers: [JeffJSLazyPayloadBuffer?] = []
    var freeSlots: [Int] = []
    /// Key: the object's address. Value: `(bufferIndex << 32) | start`.
    var records: [UInt: UInt64] = [:]

    // Stats (jeffjs-cli --heap-report, tests).
    var payloads = 0            // lazy roots created (JSON.parse + literals)
    var literalPayloads = 0
    var payloadBytes = 0
    var stubsCreated = 0
    var objectsMaterialized = 0
    var arraysMaterialized = 0
    var evicted = 0
    var fallbacks = 0           // large inputs that took the eager parser

    func register(_ b: JeffJSLazyPayloadBuffer) {
        if let slot = freeSlots.popLast() {
            b.index = slot
            buffers[slot] = b
        } else {
            b.index = buffers.count
            buffers.append(b)
        }
    }

    @inline(__always)
    func addRecord(_ o: JeffJSObject, _ b: JeffJSLazyPayloadBuffer, start: Int) {
        let key = UInt(bitPattern: Unmanaged.passUnretained(o).toOpaque())
        records[key] = (UInt64(b.index) << 32) | UInt64(start)
        b.liveRecords += 1
        o.lazyFlags |= JeffJSObject.lazyOriginBit
    }

    @inline(__always)
    func record(_ o: JeffJSObject) -> (JeffJSLazyPayloadBuffer, Int)? {
        let key = UInt(bitPattern: Unmanaged.passUnretained(o).toOpaque())
        guard let r = records[key] else { return nil }
        let bi = Int(r >> 32)
        guard bi < buffers.count, let b = buffers[bi] else { return nil }
        return (b, Int(r & 0xFFFF_FFFF))
    }

    /// The object is going away (freed or recycled): drop its record and,
    /// with the last record, the buffer.
    func forget(_ o: JeffJSObject) {
        let key = UInt(bitPattern: Unmanaged.passUnretained(o).toOpaque())
        o.lazyFlags &= ~(JeffJSObject.lazyOriginBit | JeffJSObject.lazyPayloadBit)
        guard let r = records.removeValue(forKey: key) else { return }
        let bi = Int(r >> 32)
        guard bi < buffers.count, let b = buffers[bi] else { return }
        if let root = b.root, root.toOpaque() == Unmanaged.passUnretained(o).toOpaque() { b.root = nil }
        b.liveRecords -= 1
        if b.liveRecords <= 0 {
            buffers[bi] = nil
            freeSlots.append(bi)
            b.releaseStrings()
        }
    }

    /// A non-root object finished materializing: it is an ordinary object
    /// now and needs no record (eviction re-derives its span from its
    /// parent's). Records are the frontier, not the whole read set.
    func dropMaterialized(_ o: JeffJSObject, _ b: JeffJSLazyPayloadBuffer) {
        if let root = b.root, root.toOpaque() == Unmanaged.passUnretained(o).toOpaque() { return }
        forget(o)
        // A Dictionary keeps its high-water capacity: a 20 000-element array's
        // stubs, once read, would leave 32 K empty buckets behind.
        if records.capacity > 4096, records.count * 8 < records.capacity {
            var shrunk = [UInt: UInt64](minimumCapacity: records.count * 2)
            for (k, v) in records { shrunk[k] = v }
            records = shrunk
        }
    }

    /// Runtime teardown.
    func removeAll() {
        for b in buffers { b?.releaseStrings() }
        buffers.removeAll()
        freeSlots.removeAll()
        records.removeAll()
    }

    /// Bytes the live buffers pin (a shared script text counted once).
    var liveBufferBytes: Int {
        var n = 0
        var seen = Set<ObjectIdentifier>()
        for b in buffers {
            guard let b else { continue }
            n += b.skips.count * 8
            if seen.insert(ObjectIdentifier(b.source)).inserted { n += b.source.byteCount }
        }
        return n
    }
}

/// `json.lazy` / `compile.lazyLiterals`, read once.
nonisolated(unsafe) let jeffJS_jsonLazyEnabled = JeffJSConfig.jsonLazy
nonisolated(unsafe) let jeffJS_jsonLazyThreshold = JeffJSConfig.jsonLazyThresholdBytes
nonisolated(unsafe) let jeffJS_lazyLiteralsEnabled = JeffJSConfig.compileLazyLiterals
nonisolated(unsafe) let jeffJS_lazyLiteralMinBytes = JeffJSConfig.compileLazyLiteralMinBytes
/// Nesting deeper than this compiles eagerly (the parser's own limits apply).
let jeffJS_lazyLiteralMaxDepth = 256
nonisolated(unsafe) let jeffJS_lazyDebug = ProcessInfo.processInfo.environment["JEFFJS_LAZYDEBUG"] == "1"

// MARK: - Object helpers

extension JeffJSObject {
    /// `lazyFlags` bit: this object is an unmaterialized lazy payload stub.
    @inline(__always) static let lazyPayloadBit: UInt8 = 8
    /// `lazyFlags` bit: the object has a lazy payload record (stub or
    /// materialized from a span). Not an "active" lazy property: the
    /// property paths test `lazyFlags & lazyActiveMask`.
    @inline(__always) static let lazyOriginBit: UInt8 = 0x80
    /// Bits that defer own properties (function prototype / name+length /
    /// error stack / lazy payload).
    @inline(__always) static let lazyActiveMask: UInt8 = 0x7F

    @inline(__always) var isLazyPayloadStub: Bool { (lazyFlags & JeffJSObject.lazyPayloadBit) != 0 }

    /// Materialize a lazy payload stub's top level (no-op otherwise).
    @inline(__always) func ensureLazyMaterialized() {
        if (lazyFlags & JeffJSObject.lazyPayloadBit) != 0 { jeffJS_lazyMaterialize(self) }
    }
}

/// Free/recycle hook: the object is going away.
@inline(never)
func jeffJS_lazyForget(_ rt: JeffJSRuntime?, _ o: JeffJSObject) {
    guard let rt = rt ?? o.ownerRuntime ?? JeffJSGCObjectHeader.activeRuntime else {
        o.lazyFlags &= ~(JeffJSObject.lazyOriginBit | JeffJSObject.lazyPayloadBit)
        return
    }
    rt.lazyPayload.forget(o)
}

// MARK: - Validation

/// Byte classes.
@inline(__always) private func jsonIsWS(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
@inline(__always) private func jsonIsDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
@inline(__always) private func jsonIsHex(_ c: UInt8) -> Bool {
    (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
}

/// Result of validating one JSON value.
struct JeffJSLazyValidation {
    /// Offset just past the value.
    var end: Int
    var skips: [UInt64]
    /// A `__proto__` key occurs somewhere (the eager parser handles it).
    var sawProtoKey: Bool
    var containers: Int
    /// Deepest container nesting (1 = a flat object/array).
    var maxDepth: Int
}

/// Validate the JSON value at `start` (no leading whitespace) with exactly
/// the grammar the eager parser (JeffJSBuiltinJSON.parseValue) accepts.
/// Returns nil on any syntax error. Iterative: no depth limit, no allocation
/// beyond the container stack and the skip table.
func jeffJS_lazyJSONValidate(_ p: UnsafeBufferPointer<UInt8>, start: Int, end: Int,
                             skipMinBytes: Int = 256) -> JeffJSLazyValidation? {
    var i = start
    var stack: [Int] = []          // container start offsets (sign bit = array)
    var skips: [UInt64] = []
    var sawProto = false
    var containers = 0
    var maxDepth = 0

    @inline(__always) func skipWS() { while i < end, jsonIsWS(p[i]) { i += 1 } }

    // String at i (p[i] == '"'); advances past the closing quote.
    // Returns (hadEscape) or nil on error.
    func scanString() -> Bool? {
        i += 1
        var esc = false
        while i < end {
            let c = p[i]
            if c == 0x22 { i += 1; return esc }
            if c == 0x5C {
                esc = true
                guard i + 1 < end else { return nil }
                let e = p[i + 1]
                switch e {
                case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74: i += 2
                case 0x75:
                    guard i + 5 < end, jsonIsHex(p[i + 2]), jsonIsHex(p[i + 3]),
                          jsonIsHex(p[i + 4]), jsonIsHex(p[i + 5]) else { return nil }
                    i += 6
                default: return nil
                }
                continue
            }
            if c < 0x20 { return nil }
            i += 1
        }
        return nil
    }

    // Key string at i; flags a __proto__ key.
    func scanKey() -> Bool {
        guard i < end, p[i] == 0x22 else { return false }
        let ks = i
        guard let esc = scanString() else { return false }
        if esc {
            if let units = jeffJS_lazyDecodeUnits(p, ks, i), units == jeffJS_protoUnits { sawProto = true }
        } else if i - ks == 11 {
            // "__proto__"
            if p[ks + 1] == 0x5F, p[ks + 2] == 0x5F, p[ks + 3] == 0x70, p[ks + 4] == 0x72,
               p[ks + 5] == 0x6F, p[ks + 6] == 0x74, p[ks + 7] == 0x6F, p[ks + 8] == 0x5F,
               p[ks + 9] == 0x5F { sawProto = true }
        }
        skipWS()
        guard i < end, p[i] == 0x3A else { return false }
        i += 1
        skipWS()
        return true
    }

    func scanNumber() -> Bool {
        if p[i] == 0x2D { i += 1 }
        guard i < end, jsonIsDigit(p[i]) else { return false }
        if p[i] == 0x30 {
            i += 1
            if i < end, jsonIsDigit(p[i]) { return false }
        } else {
            while i < end, jsonIsDigit(p[i]) { i += 1 }
        }
        if i < end, p[i] == 0x2E {
            i += 1
            guard i < end, jsonIsDigit(p[i]) else { return false }
            while i < end, jsonIsDigit(p[i]) { i += 1 }
        }
        if i < end, p[i] == 0x65 || p[i] == 0x45 {
            i += 1
            if i < end, p[i] == 0x2B || p[i] == 0x2D { i += 1 }
            guard i < end, jsonIsDigit(p[i]) else { return false }
            while i < end, jsonIsDigit(p[i]) { i += 1 }
        }
        return true
    }

    func scanLiteral(_ lit: StaticString) -> Bool {
        let n = lit.utf8CodeUnitCount
        guard i + n <= end else { return false }
        let lp = lit.utf8Start
        for k in 0..<n where p[i + k] != lp[k] { return false }
        i += n
        return true
    }

    func close() {
        if stack.count > maxDepth { maxDepth = stack.count }
        let s = stack.removeLast()
        let cs = s < 0 ? ~s : s
        i += 1
        if i - cs >= skipMinBytes { skips.append((UInt64(cs) << 32) | UInt64(i)) }
    }

    outer: while true {
        // A value starts at i.
        guard i < end else { return nil }
        let c = p[i]
        switch c {
        case 0x7B:
            containers += 1
            stack.append(i)
            i += 1
            skipWS()
            guard i < end else { return nil }
            if p[i] == 0x7D { close() } else {
                guard scanKey() else { return nil }
                continue outer
            }
        case 0x5B:
            containers += 1
            stack.append(~i)
            i += 1
            skipWS()
            guard i < end else { return nil }
            if p[i] == 0x5D { close() } else {
                continue outer
            }
        case 0x22:
            guard scanString() != nil else { return nil }
        case 0x74:
            guard scanLiteral("true") else { return nil }
        case 0x66:
            guard scanLiteral("false") else { return nil }
        case 0x6E:
            guard scanLiteral("null") else { return nil }
        case 0x2D, 0x30...0x39:
            guard scanNumber() else { return nil }
        default:
            return nil
        }
        // After a value.
        while true {
            guard let top = stack.last else { break outer }
            skipWS()
            guard i < end else { return nil }
            let d = p[i]
            if top >= 0 {
                if d == 0x2C {
                    i += 1
                    skipWS()
                    guard scanKey() else { return nil }
                    continue outer
                }
                if d == 0x7D { close(); continue }
                return nil
            } else {
                if d == 0x2C {
                    i += 1
                    skipWS()
                    continue outer
                }
                if d == 0x5D { close(); continue }
                return nil
            }
        }
    }
    skips.sort()
    return JeffJSLazyValidation(end: i, skips: skips, sawProtoKey: sawProto, containers: containers,
                                maxDepth: maxDepth)
}

let jeffJS_protoUnits: [UInt16] = Array("__proto__".utf16)

// MARK: - Decoding (same results as JeffJSBuiltinJSON.parseString / parseNumber)

/// UTF-16 code units of the (validated) JSON string whose quotes are at
/// `qs` and `qe - 1`. nil only on malformed input.
func jeffJS_lazyDecodeUnits(_ p: UnsafeBufferPointer<UInt8>, _ qs: Int, _ qe: Int) -> [UInt16]? {
    var out: [UInt16] = []
    out.reserveCapacity(qe - qs - 2)
    var i = qs + 1
    let end = qe - 1
    @inline(__always) func hexv(_ c: UInt8) -> UInt16 {
        switch c {
        case 0x30...0x39: return UInt16(c - 0x30)
        case 0x41...0x46: return UInt16(c - 0x41 + 10)
        default: return UInt16(c &- 0x61 &+ 10)
        }
    }
    while i < end {
        let ch = p[i]; i += 1
        if ch == 0x5C {
            guard i < end else { return nil }
            let e = p[i]; i += 1
            switch e {
            case 0x22: out.append(0x22)
            case 0x5C: out.append(0x5C)
            case 0x2F: out.append(0x2F)
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x6E: out.append(0x0A)
            case 0x72: out.append(0x0D)
            case 0x74: out.append(0x09)
            case 0x75:
                guard i + 4 <= end else { return nil }
                let v = (hexv(p[i]) << 12) | (hexv(p[i + 1]) << 8) | (hexv(p[i + 2]) << 4) | hexv(p[i + 3])
                i += 4
                // The eager parser appends a high surrogate and whatever
                // \uXXXX follows it as two units: the same as appending each.
                out.append(v)
            default: return nil
            }
        } else if ch < 0x80 {
            out.append(UInt16(ch))
        } else if ch < 0xC0 {
            out.append(UInt16(ch))
        } else if ch < 0xE0 {
            guard i < end + 1 else { return nil }
            let b2 = p[i]; i += 1
            out.append(UInt16((UInt32(ch & 0x1F) << 6) | UInt32(b2 & 0x3F)))
        } else if ch < 0xF0 {
            guard i + 1 < end + 1 else { return nil }
            let b2 = p[i], b3 = p[i + 1]; i += 2
            out.append(UInt16((UInt32(ch & 0x0F) << 12) | (UInt32(b2 & 0x3F) << 6) | UInt32(b3 & 0x3F)))
        } else {
            guard i + 2 < end + 1 else { return nil }
            let b2 = p[i], b3 = p[i + 1], b4 = p[i + 2]; i += 3
            let cp = (UInt32(ch & 0x07) << 18) | (UInt32(b2 & 0x3F) << 12) | (UInt32(b3 & 0x3F) << 6) | UInt32(b4 & 0x3F)
            out.append(UInt16(0xD800 + ((cp - 0x10000) >> 10)))
            out.append(UInt16(0xDC00 + ((cp - 0x10000) & 0x3FF)))
        }
    }
    return out
}

/// The JS number for the validated JSON number in [s, e) — the eager
/// parser's rule (Int32 when integral and in range without '.'/exponent),
/// except that `-0` stays negative zero (ES §25.5.1: JSON.parse("-0") is -0).
func jeffJS_jsonNumberValue(_ p: UnsafeBufferPointer<UInt8>, _ s: Int, _ e: Int) -> JeffJSValue {
    var hasFrac = false
    var neg = false
    var small: Int64 = 0
    var digits = 0
    var k = s
    if k < e, p[k] == 0x2D { neg = true; k += 1 }
    while k < e {
        let c = p[k]
        if c >= 0x30 && c <= 0x39 {
            if digits < 18 { small = small * 10 + Int64(c - 0x30) }
            digits += 1
        } else { hasFrac = true; break }
        k += 1
    }
    // Fast path: plain integers of up to 9 digits.
    if !hasFrac, digits <= 9 {
        if neg && small == 0 { return JeffJSValue.newFloat64(-0.0) }
        let v = neg ? -small : small
        return JeffJSValue.newInt32(Int32(v))
    }
    let str = String(decoding: UnsafeBufferPointer(rebasing: p[s..<e]), as: UTF8.self)
    guard let value = Double(str) else { return JeffJSValue.newFloat64(.nan) }
    if !hasFrac {
        if value == 0 && neg { return JeffJSValue.newFloat64(-0.0) }
        if value >= Double(Int32.min) && value <= Double(Int32.max) && value == value.rounded(.towardZero) {
            return JeffJSValue.newInt32(Int32(value))
        }
    }
    return JeffJSValue.newFloat64(value)
}

@inline(__always)
private func jeffJS_fnv64(_ p: UnsafeBufferPointer<UInt8>, _ s: Int, _ e: Int) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    var k = s
    while k < e { h = (h ^ UInt64(p[k])) &* 0x0000_0100_0000_01B3; k += 1 }
    return h ^ UInt64(e - s)
}

/// The JS string for the validated JSON string literal [qs, qe).
private func jeffJS_lazyStringValue(_ b: JeffJSLazyPayloadBuffer, _ p: UnsafeBufferPointer<UInt8>,
                                    _ qs: Int, _ qe: Int) -> JeffJSValue {
    let s = qs + 1, e = qe - 1
    var simple = true
    var k = s
    while k < e { let c = p[k]; if c == 0x5C || c >= 0x80 { simple = false; break }; k += 1 }
    if simple {
        let n = e - s
        if n == 0 { return JeffJSValue.makeString(JeffJSString(refCount: 1, len: 0, isWideChar: false, storage: .str8([]))) }
        var key: UInt64 = 0
        if jeffJS_sharedStringsEnabled, n <= JeffJSLazyPayloadBuffer.strCacheMaxLen {
            key = jeffJS_fnv64(p, s, e)
            if let v = b.strCache[key], let js = v.stringValue, js.len == n, case .str8(let st) = js.storage,
               st.count >= n, st.withUnsafeBufferPointer({ memcmp($0.baseAddress!, p.baseAddress! + s, n) == 0 }) {
                return v.dupValue()
            }
        }
        let bytes = Array(UnsafeBufferPointer(rebasing: p[s..<e]))
        let v = JeffJSValue.makeString(JeffJSString(refCount: 1, len: n, isWideChar: false, storage: .str8(bytes)))
        if key != 0, b.strCache.count < JeffJSLazyPayloadBuffer.strCacheMaxEntries, b.strCache[key] == nil {
            b.strCache[key] = v.dupValue()
        }
        return v
    }
    let units = jeffJS_lazyDecodeUnits(p, qs, qe) ?? []
    var narrow = true
    for u in units where u > 0xFF { narrow = false; break }
    if narrow {
        var bs = [UInt8](); bs.reserveCapacity(units.count)
        for u in units { bs.append(UInt8(truncatingIfNeeded: u)) }
        return JeffJSValue.makeString(JeffJSString(refCount: 1, len: units.count, isWideChar: false, storage: .str8(bs)))
    }
    return JeffJSValue.makeString(JeffJSString(refCount: 1, len: units.count, isWideChar: true, storage: .str16(units)))
}

/// The (owned) atom for the validated JSON key literal [qs, qe).
private func jeffJS_lazyKeyAtom(_ rt: JeffJSRuntime, _ p: UnsafeBufferPointer<UInt8>, _ qs: Int, _ qe: Int) -> UInt32 {
    let s = qs + 1, e = qe - 1
    var k = s
    var esc = false
    while k < e { if p[k] == 0x5C { esc = true; break }; k += 1 }
    if !esc {
        if s == e { return rt.findAtom("") }
        return rt.findAtom(utf8: UnsafeBufferPointer(rebasing: p[s..<e]))
    }
    // Same as the eager parser: a JS string, then its atom.
    let units = jeffJS_lazyDecodeUnits(p, qs, qe) ?? []
    let js: JeffJSString
    var narrow = true
    for u in units where u > 0xFF { narrow = false; break }
    if narrow {
        var bs = [UInt8](); bs.reserveCapacity(units.count)
        for u in units { bs.append(UInt8(truncatingIfNeeded: u)) }
        js = JeffJSString(refCount: 1, len: units.count, isWideChar: false, storage: .str8(bs))
    } else {
        js = JeffJSString(refCount: 1, len: units.count, isWideChar: true, storage: .str16(units))
    }
    return rt.findAtom(jsString: js)
}

// MARK: - Scanning helpers (validated input)

@inline(__always)
private func lzSkipWS(_ p: UnsafeBufferPointer<UInt8>, _ i: inout Int) {
    while i < p.count, jsonIsWS(p[i]) { i += 1 }
}

/// Past the string starting at i (p[i] == '"').
@inline(__always)
private func lzSkipString(_ p: UnsafeBufferPointer<UInt8>, _ i: inout Int) {
    i += 1
    while i < p.count {
        let c = p[i]
        if c == 0x22 { i += 1; return }
        i += (c == 0x5C) ? 2 : 1
    }
}

/// Past the container starting at i (skip table, else bracket matching).
private func lzSkipContainer(_ b: JeffJSLazyPayloadBuffer, _ p: UnsafeBufferPointer<UInt8>, _ i: inout Int) {
    if let e = b.skipEnd(i) { i = e; return }
    var depth = 0
    while i < p.count {
        let c = p[i]
        if c == 0x22 { lzSkipString(p, &i); continue }
        if c == 0x7B || c == 0x5B { depth += 1 }
        else if c == 0x7D || c == 0x5D {
            depth -= 1
            if depth == 0 { i += 1; return }
        }
        i += 1
    }
}

@inline(__always)
private func lzSkipNumber(_ p: UnsafeBufferPointer<UInt8>, _ i: inout Int) {
    while i < p.count {
        let c = p[i]
        if (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2B || c == 0x2E || c == 0x65 || c == 0x45 { i += 1 } else { return }
    }
}

// MARK: - Stubs

extension JeffJSContext {
    /// The realm's sentinel shape for lazy stubs (prototype Object.prototype
    /// or Array.prototype, no properties, never inline-cached).
    func lazySentinelShape(array: Bool) -> JeffJSShape {
        if array, let s = lazyArraySentinel { return s }
        if !array, let s = lazyObjectSentinel { return s }
        let cid = array ? JSClassID.JS_CLASS_ARRAY.rawValue : JSClassID.JS_CLASS_OBJECT.rawValue
        let proto = cid < classProto.count ? classProto[cid].toObject() : nil
        let s = createShape(self, proto: proto, hashSize: 0, propSize: 0)   // refCount 1: the context's
        s.isLazySentinel = true
        if array { lazyArraySentinel = s } else { lazyObjectSentinel = s }
        return s
    }

    /// A new stub for the container at `start` of `b` (owned value).
    func newLazyStub(_ b: JeffJSLazyPayloadBuffer, start: Int, array: Bool) -> JeffJSValue {
        let sentinel = lazySentinelShape(array: array)
        let o = JeffJSObject()
        o.classID = array ? JSClassID.JS_CLASS_ARRAY.rawValue : JSClassID.JS_CLASS_OBJECT.rawValue
        sentinel.refCount += 1
        o.shape = sentinel
        o.extensible = true
        o.lazyFlags |= JeffJSObject.lazyPayloadBit
        rt.lazyPayload.addRecord(o, b, start: start)
        rt.lazyPayload.stubsCreated += 1
        return JeffJSValue.makeObject(o)
    }

    /// A lazy root over the validated JSON value at `start` of `source`
    /// (which must be an object or an array). Owned value.
    func newLazyPayloadRoot(source: LazyBytesSource, start: Int, validation v: JeffJSLazyValidation,
                            literal: Bool) -> JeffJSValue {
        let b = JeffJSLazyPayloadBuffer(source: source, skips: v.skips, ctx: self)
        let st = rt.lazyPayload
        st.register(b)
        st.payloads += 1
        if literal { st.literalPayloads += 1 }
        st.payloadBytes += v.end - start
        let isArray = source.withBytes { $0[start] == 0x5B }
        let v = newLazyStub(b, start: start, array: isArray)
        if let o = v.toObject() { b.root = Unmanaged.passUnretained(o) }
        b.rootStart = start
        return v
    }

    /// JSON.parse's lazy path: nil = take the eager parser (too small,
    /// switched off, not an object/array, malformed, `__proto__` key).
    func lazyJSONParse(bytes: [UInt8]) -> JeffJSValue? {
        guard jeffJS_jsonLazyEnabled, bytes.count >= jeffJS_jsonLazyThreshold, bytes.count < Int(UInt32.max) else { return nil }
        let r: (Int, JeffJSLazyValidation)? = bytes.withUnsafeBufferPointer { p in
            var i = 0
            while i < p.count, jsonIsWS(p[i]) { i += 1 }
            guard i < p.count, p[i] == 0x7B || p[i] == 0x5B else { return nil }
            guard let v = jeffJS_lazyJSONValidate(p, start: i, end: p.count), !v.sawProtoKey else { return nil }
            var j = v.end
            while j < p.count, jsonIsWS(p[j]) { j += 1 }
            guard j == p.count else { return nil }
            return (i, v)
        }
        guard let (start, v) = r else {
            rt.lazyPayload.fallbacks += 1
            return nil
        }
        // The buffer lives as long as the payload: no transcoding slack
        // (jeffJS_utf8Bytes reserves 1.5x for a UTF-16 string).
        var kept = bytes
        if bytes.capacity - bytes.count > bytes.count / 16 {
            kept = [UInt8](unsafeUninitializedCapacity: bytes.count) { buf, n in
                bytes.withUnsafeBufferPointer { src in
                    if let d = buf.baseAddress, let s = src.baseAddress { d.update(from: s, count: src.count) }
                }
                n = bytes.count
            }
        }
        return newLazyPayloadRoot(source: JeffJSByteArraySource(kept), start: start, validation: v, literal: false)
    }
}

// MARK: - Materialization

/// Build `o`'s top level from its span. Clears the stub bit first, so the
/// property operations used here (and any re-entrant lookup) see an
/// ordinary object.
@inline(never)
func jeffJS_lazyMaterialize(_ o: JeffJSObject) {
    o.lazyFlags &= ~JeffJSObject.lazyPayloadBit
    guard let rt = o.ownerRuntime ?? JeffJSGCObjectHeader.activeRuntime,
          let (b, start) = rt.lazyPayload.record(o),
          let ctx = b.ctx ?? rt.realm(at: 0) else { return }
    b.source.withBytes { p in
        if p[start] == 0x7B {
            jeffJS_lazyMaterializeObject(ctx, rt, o, b, p, start)
        } else {
            jeffJS_lazyMaterializeArray(ctx, rt, o, b, p, start)
        }
    }
    rt.lazyPayload.dropMaterialized(o, b)
}

/// The value at i (validated); advances i past it. Owned.
@inline(__always)
private func lzValue(_ ctx: JeffJSContext, _ b: JeffJSLazyPayloadBuffer,
                     _ p: UnsafeBufferPointer<UInt8>, _ i: inout Int) -> JeffJSValue {
    let c = p[i]
    switch c {
    case 0x7B, 0x5B:
        let v = ctx.newLazyStub(b, start: i, array: c == 0x5B)
        lzSkipContainer(b, p, &i)
        return v
    case 0x22:
        let qs = i
        lzSkipString(p, &i)
        return jeffJS_lazyStringValue(b, p, qs, i)
    case 0x74: i += 4; return .JS_TRUE
    case 0x66: i += 5; return .JS_FALSE
    case 0x6E: i += 4; return .null
    default:
        let s = i
        lzSkipNumber(p, &i)
        return jeffJS_jsonNumberValue(p, s, i)
    }
}

private func jeffJS_lazyMaterializeObject(_ ctx: JeffJSContext, _ rt: JeffJSRuntime, _ o: JeffJSObject,
                                          _ b: JeffJSLazyPayloadBuffer, _ p: UnsafeBufferPointer<UInt8>,
                                          _ start: Int) {
    rt.lazyPayload.objectsMaterialized += 1
    // Leave the sentinel for the ordinary root shape of the same prototype
    // (the shape an eager parse starts from), unless something already gave
    // the object a shape of its own.
    if let s = o.shape, s.isLazySentinel {
        let ns = jeffJS_rootShape(ctx, proto: s.proto)
        o.shape = ns
        jeffJS_leaveShape(rt, s)
    }
    let flags = JeffJSPropertyFlags.cWE.rawValue
    var i = start + 1
    lzSkipWS(p, &i)
    if p[i] == 0x7D { return }
    while true {
        lzSkipWS(p, &i)
        let qs = i
        lzSkipString(p, &i)
        let atom = jeffJS_lazyKeyAtom(rt, p, qs, i)
        lzSkipWS(p, &i)
        i += 1                      // ':'
        lzSkipWS(p, &i)
        let v = lzValue(ctx, b, p, &i)
        if let sh = o.shape, let idx = findShapeProperty(sh, atom), idx < o.propValues.count {
            // Duplicate key: the last value wins, the first position stays.
            let old = o.propValues[idx]
            o.propValues[idx] = v
            old.freeValue()
        } else {
            jeffJS_objectAddShapeProperty(ctx, o, atom: atom, flags: flags)
            o.appendDataValue(v)
        }
        rt.freeAtom(atom)
        lzSkipWS(p, &i)
        if p[i] == 0x2C { i += 1; continue }
        return                      // '}'
    }
}

private func jeffJS_lazyMaterializeArray(_ ctx: JeffJSContext, _ rt: JeffJSRuntime, _ o: JeffJSObject,
                                         _ b: JeffJSLazyPayloadBuffer, _ p: UnsafeBufferPointer<UInt8>,
                                         _ start: Int) {
    rt.lazyPayload.arraysMaterialized += 1
    var items = ContiguousArray<JeffJSValue>()
    var i = start + 1
    lzSkipWS(p, &i)
    if p[i] != 0x5D {
        while true {
            lzSkipWS(p, &i)
            items.append(lzValue(ctx, b, p, &i))
            lzSkipWS(p, &i)
            if p[i] == 0x2C { i += 1; continue }
            break                   // ']'
        }
    }
    // Become the array `newArray()` + the elements would have made: the
    // shared array shape (`length` in slot 0) and the element store.
    let n = items.count
    if let s = o.shape, s.isLazySentinel {
        if let cached = ctx.arrayShape, cached.proto === s.proto, o.propValues.count == 0 {
            cached.refCount += 1
            o.shape = cached
            jeffJS_leaveShape(rt, s)
            o.appendDataValue(.newInt32(0))
        } else {
            let ns = jeffJS_rootShape(ctx, proto: s.proto)
            o.shape = ns
            jeffJS_leaveShape(rt, s)
            jeffJS_objectAddShapeProperty(ctx, o, atom: JeffJSAtomID.JS_ATOM_length.rawValue,
                                          flags: JeffJSPropertyFlags.writable.rawValue)
            o.appendDataValue(.newInt32(0))
        }
    }
    o.payload = .array(size: 0, values: [], count: 0)
    o.fastArray = true
    if n > 0 { o.installFastArrayValues(items) }
    let lenIdx = jeffJS_findOwnPropertyIndex(obj: o, atom: JeffJSAtomID.JS_ATOM_length.rawValue)
    if lenIdx >= 0 { o.propValues[lenIdx] = .newInt32(Int32(n)) }
}

// MARK: - Eviction

extension JeffJSRuntime {
    /// Revert every pristine object materialized from a lazy payload back to
    /// a stub, walking down from each live root (children first). Call with
    /// no JS on the stack. Returns the number of objects reverted.
    @discardableResult
    func evictLazyPayloads() -> Int {
        guard inlineStackTop == 0, gcPhase == .JS_GC_PHASE_NONE, !inFreeChain else { return 0 }
        let st = lazyPayload
        var n = 0
        for b in st.buffers {
            guard let b, let r = b.root else { continue }
            let root = r.takeUnretainedValue()
            if root.isLazyPayloadStub { continue }
            _ = JSONEvict(rt: self, b: b).tree(root, b.rootStart, depth: 0, count: &n)
        }
        st.evicted += n
        return n
    }
}

/// One payload's eviction walk.
private struct JSONEvict {
    let rt: JeffJSRuntime
    let b: JeffJSLazyPayloadBuffer

    /// True when `o` is a stub (already, or reverted here). Reverts the
    /// subtree bottom-up; `count` gets the objects reverted.
    func tree(_ o: JeffJSObject, _ start: Int, depth: Int, count: inout Int) -> Bool {
        if o.isLazyPayloadStub { return true }
        guard depth < 256, let ctx = b.ctx, let children = structure(o, start, ctx) else { return false }
        var allStubs = true
        for (c, s) in children {
            if !tree(c, s, depth: depth + 1, count: &count) { allStubs = false; continue }
            // Its parent may let it go only if nothing else holds it.
            if c.refCount != 1 || c._auxU != nil { allStubs = false }
        }
        guard allStubs else { return false }
        revert(o, start, ctx)
        count += 1
        return true
    }

    /// The (object, span) of every container-valued slot when `o` holds
    /// exactly what its span says apart from those children (same keys in
    /// the same order with default flags, equal primitives, default
    /// prototype, extensible, no side box), else nil.
    func structure(_ o: JeffJSObject, _ start: Int, _ ctx: JeffJSContext) -> [(JeffJSObject, Int)]? {
        guard o.extensible, o._propExtraCount == 0, o._auxU == nil, let shape = o.shape,
              shape.deletedPropCount == 0 else { return nil }
        let isArray = o.classID == JSClassID.JS_CLASS_ARRAY.rawValue
        var children: [(JeffJSObject, Int)] = []
        let ok: Bool = b.source.withBytes { p in
            if isArray {
                guard p[start] == 0x5B, o.fastArray, let st = o._fastArrayValues, !st.checked, st.attrs == nil,
                      let cached = ctx.arrayShape, shape === cached, o.propValues.count == 1 else { return false }
                var i = start + 1
                var k = 0
                lzSkipWS(p, &i)
                if p[i] != 0x5D {
                    while true {
                        lzSkipWS(p, &i)
                        guard k < Int(st.count), k < st.values.count,
                              lzSameValue(rt, b, p, &i, st.values[k], &children) else { return false }
                        k += 1
                        lzSkipWS(p, &i)
                        if p[i] == 0x2C { i += 1; continue }
                        break
                    }
                }
                guard k == Int(st.count) else { return false }
                let len = o.propValues[0]
                return len.isInt && Int(len.toInt32()) == k
            }
            guard p[start] == 0x7B, o.classID == JSClassID.JS_CLASS_OBJECT.rawValue,
                  let proto = ctx.classProto[JSClassID.JS_CLASS_OBJECT.rawValue].toObject(),
                  shape.proto === proto else { return false }
            // Expected (key, value-span) list with duplicate keys folded.
            var keys: [UInt32] = []
            var spans: [Int] = []
            var i = start + 1
            lzSkipWS(p, &i)
            if p[i] != 0x7D {
                while true {
                    lzSkipWS(p, &i)
                    let qs = i
                    lzSkipString(p, &i)
                    let atom = jeffJS_lazyKeyAtom(rt, p, qs, i)
                    lzSkipWS(p, &i); i += 1; lzSkipWS(p, &i)
                    let vs = i
                    lzSkipAny(b, p, &i)
                    if let at = keys.firstIndex(of: atom) { spans[at] = vs; rt.freeAtom(atom) }
                    else { keys.append(atom); spans.append(vs) }
                    lzSkipWS(p, &i)
                    if p[i] == 0x2C { i += 1; continue }
                    break
                }
            }
            defer { for a in keys { rt.freeAtom(a) } }
            guard keys.count == shape.propCount, keys.count == o.propValues.count else { return false }
            for k in 0..<keys.count {
                let sp = shape.prop[k]
                guard sp.atom == keys[k], sp.flags.rawValue == JeffJSPropertyFlags.cWE.rawValue else { return false }
                var vi = spans[k]
                guard lzSameValue(rt, b, p, &vi, o.propValues[k], &children) else { return false }
            }
            return true
        }
        return ok ? children : nil
    }

    /// Back to a stub: the slots (and the child stubs they hold) go, the
    /// sentinel shape and the record come back.
    func revert(_ o: JeffJSObject, _ start: Int, _ ctx: JeffJSContext) {
        let isArray = o.classID == JSClassID.JS_CLASS_ARRAY.rawValue
        let sentinel = ctx.lazySentinelShape(array: isArray)
        rt.inFreeChain = true
        let n = o.propValues.count
        var vals: [JeffJSValue] = []
        vals.reserveCapacity(n)
        for k in 0..<n { vals.append(o.propValues[k]) }
        o.propValues.removeAll(keepingCapacity: false)
        var elems: ContiguousArray<JeffJSValue> = []
        if isArray, let st = o._fastArrayValues {
            elems = st.values
            let cnt = Int(st.count)
            if elems.count > cnt { elems.removeLast(elems.count - cnt) }
            o._fastArrayValues = nil
            o.fastArray = false
        }
        let old = o.shape!
        sentinel.refCount += 1
        o.shape = sentinel
        jeffJS_leaveShape(rt, old)
        o.lazyFlags |= JeffJSObject.lazyPayloadBit
        if (o.lazyFlags & JeffJSObject.lazyOriginBit) == 0 { rt.lazyPayload.addRecord(o, b, start: start) }
        for v in vals { v.freeValue() }
        for v in elems { v.freeValue() }
        rt.inFreeChain = false
        while let d = rt.gcZeroRefCountObjects.popLast() {
            if d.refCount == 0 { freeGCObjectAtZeroRefcount(rt, d) }
        }
    }
}

/// Past any value at i.
private func lzSkipAny(_ b: JeffJSLazyPayloadBuffer, _ p: UnsafeBufferPointer<UInt8>, _ i: inout Int) {
    let c = p[i]
    switch c {
    case 0x7B, 0x5B: lzSkipContainer(b, p, &i)
    case 0x22: lzSkipString(p, &i)
    case 0x74, 0x6E: i += 4
    case 0x66: i += 5
    default: lzSkipNumber(p, &i)
    }
}

/// Is `v` what the value at i materializes to? A container only has to be
/// an object (collected into `children` with its span for the caller to
/// check). Advances i.
private func lzSameValue(_ rt: JeffJSRuntime, _ b: JeffJSLazyPayloadBuffer, _ p: UnsafeBufferPointer<UInt8>,
                         _ i: inout Int, _ v: JeffJSValue, _ children: inout [(JeffJSObject, Int)]) -> Bool {
    let c = p[i]
    switch c {
    case 0x7B, 0x5B:
        let s = i
        lzSkipContainer(b, p, &i)
        guard let co = v.toObject(), co.classID == (c == 0x5B ? JSClassID.JS_CLASS_ARRAY.rawValue
                                                              : JSClassID.JS_CLASS_OBJECT.rawValue) else { return false }
        if co.isLazyPayloadStub {
            // A stub must be this span's.
            guard let (cb, cs) = rt.lazyPayload.record(co), cb === b, cs == s else { return false }
        }
        children.append((co, s))
        return true
    case 0x22:
        let qs = i
        lzSkipString(p, &i)
        guard v.isString, let js = v.stringValue else { return false }
        let units = jeffJS_lazyDecodeUnits(p, qs, i) ?? []
        guard js.len == units.count else { return false }
        return js.str16 == units
    case 0x74: i += 4; return v.isBool && v.toBool()
    case 0x66: i += 5; return v.isBool && !v.toBool()
    case 0x6E: i += 4; return v.isNull
    default:
        let s = i
        lzSkipNumber(p, &i)
        let n = jeffJS_jsonNumberValue(p, s, i)
        if n.isInt { return v.isInt && v.toInt32() == n.toInt32() }
        guard v.isFloat64 else { return false }
        return v.toFloat64().bitPattern == n.toFloat64().bitPattern
    }
}

// MARK: - Lazy literals (compiler side: JeffJSParser.tryLazyLiteral)

extension JeffJSContext {
    /// `lazy_literal`: a fresh lazy payload for the literal whose JSON text
    /// is `cpool[cpoolIndex]` (a string; released with a top-level script's
    /// constants after it ran) and which starts at `sourceOffset` of the
    /// script text. The script text is shared when it is still there (it is
    /// what lazy compilation keeps); the string constant is the fallback
    /// (bytecode-cache loads without the text). Owned value or exception.
    func lazyLiteralValue(fb: JeffJSFunctionBytecode, cpoolIndex: Int, sourceOffset: Int) -> JeffJSValue {
        let constant: JeffJSValue = cpoolIndex < fb.cpool.count ? fb.cpool[cpoolIndex] : .undefined
        let text = fb.sourceText ?? fb.lazyInfo?.script.source
        var source: LazyBytesSource? = nil
        var start = 0
        if let js = constant.stringValue {
            let bytes = jeffJS_utf8Bytes(of: js)
            if let t = text, sourceOffset >= 0, sourceOffset + bytes.count <= t.bytes.count,
               bytes.withUnsafeBufferPointer({ b in
                   t.bytes.withUnsafeBufferPointer { s in
                       memcmp(b.baseAddress!, s.baseAddress! + sourceOffset, b.count) == 0
                   }
               }) {
                source = t
                start = sourceOffset
            } else {
                source = JeffJSByteArraySource(bytes)
            }
        } else if let t = text, sourceOffset >= 0, sourceOffset < t.bytes.count {
            source = t
            start = sourceOffset
        }
        if jeffJS_lazyDebug {
            jeffJS_stderrLine("[lazy] literal cpool=\(cpoolIndex) off=\(sourceOffset) const=\(constant.isString) text=\(text?.bytes.count ?? -1) shared=\(source === text)")
        }
        guard let src = source else {
            return throwInternalError(message: "lazy literal: source text unavailable")
        }
        let v: JeffJSLazyValidation? = src.withBytes { p in
            guard start < p.count, p[start] == 0x7B || p[start] == 0x5B else { return nil }
            return jeffJS_lazyJSONValidate(p, start: start, end: p.count)
        }
        guard let val = v, !val.sawProtoKey else {
            return throwInternalError(message: "lazy literal: source text changed")
        }
        return newLazyPayloadRoot(source: src, start: start, validation: val, literal: true)
    }
}
