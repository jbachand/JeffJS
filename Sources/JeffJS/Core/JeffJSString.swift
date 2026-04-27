// JeffJSString.swift
// JeffJS — 1:1 Swift port of QuickJS JSString / JSStringRope / StringBuffer
// Copyright 2026 Jeff Bachand. All rights reserved.

import Foundation

// MARK: - Forward references for types defined elsewhere

/// Placeholder until JeffJSContext is defined.
protocol JeffJSContextProtocol: AnyObject {}

/// Placeholder until JeffJSRuntime is defined.
protocol JeffJSRuntimeProtocol: AnyObject {}

// NOTE: JeffJSValue, JSValueTag, and JSValuePayload are now defined in
// JeffJSValue.swift. The placeholder definitions that were here have been
// removed to avoid duplicate type declarations.

// MARK: - String storage

/// Backing store for an 8-bit (Latin-1) or 16-bit (UTF-16) character array.
enum JeffJSStringStorage {
    case str8([UInt8])
    case str16([UInt16])
}

// MARK: - JeffJSString

/// Port of QuickJS `JSString`.
/// Characters are stored either as Latin-1 (`str8`) or UTF-16 (`str16`).
/// Strings double as atom entries when `atomType != 0`.
final class JeffJSString {

    // -- Reference counting --------------------------------------------------

    var refCount: Int

    // -- Length (max 2^31 - 1) ------------------------------------------------

    private(set) var len: Int

    // -- Encoding flag -------------------------------------------------------

    /// `false` = 8-bit (Latin-1), `true` = 16-bit (UTF-16).
    private(set) var isWideChar: Bool

    // -- Hash / atom ---------------------------------------------------------

    /// Lower 30 bits: hash value.  Upper 2 bits: atom type.
    private var _hashAndAtomType: UInt32

    /// 30-bit hash value.
    var hash: UInt32 {
        get { _hashAndAtomType & 0x3FFF_FFFF }
        set {
            _hashAndAtomType = (newValue & 0x3FFF_FFFF) | (UInt32(atomType) << 30)
        }
    }

    /// Atom type: 0 = not an atom, 1-4 for atom types.
    var atomType: UInt8 {
        get { UInt8((_hashAndAtomType >> 30) & 0x3) }
        set {
            _hashAndAtomType = hash | (UInt32(newValue & 0x3) << 30)
        }
    }

    /// Next pointer in the atom hash chain.
    var hashNext: UInt32

    // -- Storage -------------------------------------------------------------

    var storage: JeffJSStringStorage

    // -- Convenience accessors -----------------------------------------------

    /// Returns the raw UInt8 buffer (only valid when `isWideChar == false`).
    var str8: [UInt8] {
        get {
            if case .str8(let arr) = storage { return arr }
            // Fallback: narrow the wide-char buffer instead of crashing
            if case .str16(let wide) = storage {
                return wide.map { UInt8(truncatingIfNeeded: $0) }
            }
            return []
        }
        set { storage = .str8(newValue) }
    }

    /// Returns the raw UInt16 buffer (only valid when `isWideChar == true`).
    var str16: [UInt16] {
        get {
            if case .str16(let arr) = storage { return arr }
            // Fallback: widen the 8-bit buffer instead of crashing
            if case .str8(let narrow) = storage {
                return narrow.map { UInt16($0) }
            }
            return []
        }
        set { storage = .str16(newValue) }
    }

    // -- Initialiser ---------------------------------------------------------

    init(refCount: Int = 1,
         len: Int = 0,
         isWideChar: Bool = false,
         hash: UInt32 = 0,
         atomType: UInt8 = 0,
         hashNext: UInt32 = 0,
         storage: JeffJSStringStorage = .str8([])) {
        self.refCount = refCount
        self.len = len
        self.isWideChar = isWideChar
        self._hashAndAtomType = (hash & 0x3FFF_FFFF) | (UInt32(atomType & 0x3) << 30)
        self.hashNext = hashNext
        self.storage = storage
    }

    // -- Retain / Release ----------------------------------------------------

    @discardableResult
    func retain() -> JeffJSString {
        refCount += 1
        return self
    }

    func release() {
        refCount -= 1
    }
}

// MARK: - JeffJSStringRope

/// Port of QuickJS rope node used by `js_concat_string`.
/// A rope postpones flattening until the string content is actually needed.
final class JeffJSStringRope {

    var refCount: Int
    var len: Int
    var isWideChar: Bool
    var depth: UInt8

    var left: JeffJSValue
    var right: JeffJSValue

    init(refCount: Int = 1,
         len: Int = 0,
         isWideChar: Bool = false,
         depth: UInt8 = 0,
         left: JeffJSValue = .undefined,
         right: JeffJSValue = .undefined) {
        self.refCount = refCount
        self.len = len
        self.isWideChar = isWideChar
        self.depth = depth
        self.left = left
        self.right = right
    }

    @discardableResult
    func retain() -> JeffJSStringRope {
        refCount += 1
        return self
    }

    func release() {
        refCount -= 1
    }
}

// MARK: - String allocation

/// Allocate a fresh, zeroed-out `JeffJSString` that can hold up to `maxLen`
/// characters of the requested width.
func jeffJS_allocString(maxLen: Int, isWideChar: Bool) -> JeffJSString? {
    guard maxLen >= 0, maxLen <= 0x7FFF_FFFF else { return nil }

    let storage: JeffJSStringStorage
    if isWideChar {
        storage = .str16([UInt16](repeating: 0, count: maxLen))
    } else {
        storage = .str8([UInt8](repeating: 0, count: maxLen))
    }

    return JeffJSString(refCount: 1,
                        len: maxLen,
                        isWideChar: isWideChar,
                        hash: 0,
                        atomType: 0,
                        hashNext: 0,
                        storage: storage)
}

// MARK: - Character access

/// Return the code unit at `index` as a UInt32 (works for both widths).
func jeffJS_getString(str: JeffJSString, at index: Int) -> UInt32 {
    guard index >= 0, index < str.len else { return 0 }
    switch str.storage {
    case .str8(let buf):
        return UInt32(buf[index])
    case .str16(let buf):
        return UInt32(buf[index])
    }
}

// MARK: - Substring

/// Create a new `JeffJSString` that is a copy of `str[start ..< end]`.
func jeffJS_subString(str: JeffJSString, start: Int, end: Int) -> JeffJSString? {
    let s = max(start, 0)

    switch str.storage {
    case .str8(let buf):
        let e = min(end, str.len, buf.count)
        guard s < e else {
            return jeffJS_allocString(maxLen: 0, isWideChar: false)
        }
        let slice = Array(buf[s ..< e])
        return JeffJSString(refCount: 1,
                            len: e - s,
                            isWideChar: false,
                            storage: .str8(slice))

    case .str16(let buf):
        let e = min(end, str.len, buf.count)
        guard s < e else {
            return jeffJS_allocString(maxLen: 0, isWideChar: false)
        }
        let subLen = e - s
        var canNarrow = true
        for i in s ..< e {
            if buf[i] > 0xFF { canNarrow = false; break }
        }
        if canNarrow {
            var narrow = [UInt8](repeating: 0, count: subLen)
            for i in 0 ..< subLen { narrow[i] = UInt8(buf[s + i]) }
            return JeffJSString(refCount: 1,
                                len: subLen,
                                isWideChar: false,
                                storage: .str8(narrow))
        } else {
            let slice = Array(buf[s ..< e])
            return JeffJSString(refCount: 1,
                                len: subLen,
                                isWideChar: true,
                                storage: .str16(slice))
        }
    }
}

// MARK: - Hashing (port of QuickJS hash_string8 / hash_string16)

// Precomputed powers of 263 for 4x-unrolled polynomial hash.
// Using file-scope lets so the compiler emits them as constants.
private let _h263_p1: UInt32 = 263
private let _h263_p2: UInt32 = 263 &* 263
private let _h263_p3: UInt32 = 263 &* 263 &* 263
private let _h263_p4: UInt32 = 263 &* 263 &* 263 &* 263

/// Polynomial hash for 8-bit data matching QuickJS `hash_string8`.
/// 4x unrolled: processes 4 bytes per iteration using precomputed powers of 263.
func jeffJS_hashString8(data: [UInt8], len: Int, h: UInt32 = 0) -> UInt32 {
    var hash = h
    let count = min(len, data.count)
    guard count > 0 else { return hash }
    return data.withUnsafeBufferPointer { buf in
        guard let p = buf.baseAddress else { return hash }
        var i = 0
        while i &+ 3 < count {
            hash = hash &* _h263_p4
                &+ UInt32(p[i])     &* _h263_p3
                &+ UInt32(p[i &+ 1]) &* _h263_p2
                &+ UInt32(p[i &+ 2]) &* _h263_p1
                &+ UInt32(p[i &+ 3])
            i &+= 4
        }
        while i < count {
            hash = hash &* 263 &+ UInt32(p[i])
            i &+= 1
        }
        return hash
    }
}

/// Polynomial hash for 16-bit data matching QuickJS `hash_string16`.
/// 4x unrolled: processes 4 code units per iteration.
func jeffJS_hashString16(data: [UInt16], len: Int, h: UInt32 = 0) -> UInt32 {
    var hash = h
    let count = min(len, data.count)
    guard count > 0 else { return hash }
    return data.withUnsafeBufferPointer { buf in
        guard let p = buf.baseAddress else { return hash }
        var i = 0
        while i &+ 3 < count {
            hash = hash &* _h263_p4
                &+ UInt32(p[i])     &* _h263_p3
                &+ UInt32(p[i &+ 1]) &* _h263_p2
                &+ UInt32(p[i &+ 2]) &* _h263_p1
                &+ UInt32(p[i &+ 3])
            i &+= 4
        }
        while i < count {
            hash = hash &* 263 &+ UInt32(p[i])
            i &+= 1
        }
        return hash
    }
}

/// Compute and cache the hash of a `JeffJSString`.
func jeffJS_computeHash(str: JeffJSString) -> UInt32 {
    let h: UInt32
    switch str.storage {
    case .str8(let buf):
        h = jeffJS_hashString8(data: buf, len: str.len)
    case .str16(let buf):
        h = jeffJS_hashString16(data: buf, len: str.len)
    }
    let masked = h & 0x3FFF_FFFF  // 30-bit
    str.hash = masked
    return masked
}

// MARK: - String comparison

/// Lexicographic comparison of two strings. Returns <0, 0, or >0.
/// Uses memcmp fast-path for same-width strings.
func jeffJS_stringCompare(s1: JeffJSString, s2: JeffJSString) -> Int {
    if s1 === s2 { return 0 }

    // Fast path: both 8-bit — memcmp is SIMD-optimized on Apple platforms
    if !s1.isWideChar && !s2.isWideChar {
        if case .str8(let a) = s1.storage, case .str8(let b) = s2.storage {
            let minLen = min(s1.len, s2.len, a.count, b.count)
            let cmp = a.withUnsafeBufferPointer { bufA in
                b.withUnsafeBufferPointer { bufB in
                    guard let pA = bufA.baseAddress, let pB = bufB.baseAddress else { return Int32(0) }
                    return Int32(memcmp(pA, pB, minLen))
                }
            }
            if cmp != 0 { return cmp < 0 ? -1 : 1 }
            return s1.len < s2.len ? -1 : (s1.len > s2.len ? 1 : 0)
        }
    }

    // Fast path: both 16-bit
    if s1.isWideChar && s2.isWideChar {
        if case .str16(let a) = s1.storage, case .str16(let b) = s2.storage {
            let minLen = min(s1.len, s2.len, a.count, b.count)
            let cmp = a.withUnsafeBufferPointer { bufA in
                b.withUnsafeBufferPointer { bufB in
                    guard let pA = bufA.baseAddress, let pB = bufB.baseAddress else { return Int32(0) }
                    return Int32(memcmp(pA, pB, minLen &* 2))
                }
            }
            if cmp != 0 { return cmp < 0 ? -1 : 1 }
            return s1.len < s2.len ? -1 : (s1.len > s2.len ? 1 : 0)
        }
    }

    // General case: mixed width — per-character
    let minLen = min(s1.len, s2.len)
    for i in 0 ..< minLen {
        let c1 = jeffJS_getString(str: s1, at: i)
        let c2 = jeffJS_getString(str: s2, at: i)
        if c1 != c2 { return c1 < c2 ? -1 : 1 }
    }
    return s1.len < s2.len ? -1 : (s1.len > s2.len ? 1 : 0)
}

// MARK: - String equality

/// Content equality (independent of encoding width).
/// Uses memcmp fast-path for same-width strings (SIMD-optimized on Apple platforms).
func jeffJS_stringEquals(s1: JeffJSString, s2: JeffJSString) -> Bool {
    if s1 === s2 { return true }
    if s1.len != s2.len { return false }
    if s1.len == 0 { return true }

    // Fast path: both 8-bit — single memcmp
    if !s1.isWideChar && !s2.isWideChar {
        if case .str8(let a) = s1.storage, case .str8(let b) = s2.storage {
            let len = min(s1.len, a.count, b.count)
            return a.withUnsafeBufferPointer { bufA in
                b.withUnsafeBufferPointer { bufB in
                    guard let pA = bufA.baseAddress, let pB = bufB.baseAddress else { return len == 0 }
                    return memcmp(pA, pB, len) == 0
                }
            }
        }
    }

    // Fast path: both 16-bit — single memcmp
    if s1.isWideChar && s2.isWideChar {
        if case .str16(let a) = s1.storage, case .str16(let b) = s2.storage {
            let len = min(s1.len, a.count, b.count)
            return a.withUnsafeBufferPointer { bufA in
                b.withUnsafeBufferPointer { bufB in
                    guard let pA = bufA.baseAddress, let pB = bufB.baseAddress else { return len == 0 }
                    return memcmp(pA, pB, len &* 2) == 0
                }
            }
        }
    }

    // Mixed width: per-character comparison
    for i in 0 ..< s1.len {
        if jeffJS_getString(str: s1, at: i) != jeffJS_getString(str: s2, at: i) {
            return false
        }
    }
    return true
}

// MARK: - Fast single-character search (uses memchr, SIMD-optimized on Apple)

/// Find the first occurrence of `needle` in the 8-bit string starting at `fromIndex`.
/// Returns the index, or -1 if not found. Uses memchr which is SIMD-optimized.
func jeffJS_indexOf8(_ str: JeffJSString, needle: UInt8, fromIndex: Int = 0) -> Int {
    guard !str.isWideChar, case .str8(let data) = str.storage else { return -1 }
    let start = max(fromIndex, 0)
    let len = min(str.len, data.count)
    guard start < len else { return -1 }
    return data.withUnsafeBufferPointer { buf in
        guard let base = buf.baseAddress else { return -1 }
        let searchBase = base + start
        let searchLen = len - start
        guard let found = memchr(searchBase, Int32(needle), searchLen) else { return -1 }
        return start + searchBase.distance(to: found.assumingMemoryBound(to: UInt8.self))
    }
}

/// Find the first occurrence of a substring in an 8-bit string.
/// Uses memchr to find the first byte, then memcmp to verify the rest.
func jeffJS_indexOfString8(_ haystack: JeffJSString, _ needle: JeffJSString, fromIndex: Int = 0) -> Int {
    guard !haystack.isWideChar && !needle.isWideChar else { return -1 }
    guard case .str8(let hData) = haystack.storage, case .str8(let nData) = needle.storage else { return -1 }
    let hLen = min(haystack.len, hData.count)
    let nLen = min(needle.len, nData.count)
    if nLen == 0 { return max(min(fromIndex, hLen), 0) }
    if nLen > hLen { return -1 }
    let start = max(fromIndex, 0)
    guard start + nLen <= hLen else { return -1 }

    return hData.withUnsafeBufferPointer { hBuf in
        nData.withUnsafeBufferPointer { nBuf in
            guard let hBase = hBuf.baseAddress, let nBase = nBuf.baseAddress else { return -1 }
            let firstByte = nBase[0]
            var pos = start
            while pos + nLen <= hLen {
                // Find next occurrence of first byte using memchr
                let remaining = hLen - pos
                guard let found = memchr(hBase + pos, Int32(firstByte), remaining) else { return -1 }
                let foundPos = hBase.distance(to: found.assumingMemoryBound(to: UInt8.self))
                if foundPos + nLen > hLen { return -1 }
                // Verify rest of needle
                if nLen == 1 || memcmp(hBase + foundPos, nBase, nLen) == 0 {
                    return foundPos
                }
                pos = foundPos + 1
            }
            return -1
        }
    }
}

// MARK: - Numeric string detection

/// Check whether `str` represents a non-negative integer that fits in a
/// UInt32 (for the integer-atom fast-path in QuickJS).
///
/// Returns `(true, value)` on success, `(false, 0)` otherwise.
func jeffJS_isNumericString(_ str: JeffJSString) -> (Bool, UInt32) {
    guard str.len > 0 else { return (false, 0) }

    let first = jeffJS_getString(str: str, at: 0)

    // Single '0' is numeric, but leading-zero multi-digit is not.
    if first == 0x30 /* '0' */ {
        return str.len == 1 ? (true, 0) : (false, 0)
    }

    guard first >= 0x31 && first <= 0x39 else { return (false, 0) } // '1'-'9'

    var val: UInt64 = UInt64(first - 0x30)
    for i in 1 ..< str.len {
        let c = jeffJS_getString(str: str, at: i)
        guard c >= 0x30 && c <= 0x39 else { return (false, 0) }
        val = val * 10 + UInt64(c - 0x30)
        if val > UInt64(UInt32.max) { return (false, 0) }
    }
    return (true, UInt32(val))
}

// MARK: - Concat / Rope

/// Maximum rope depth before we force-flatten.
private let kMaxRopeDepth: UInt8 = 32

/// Concatenate two string values.
/// If both sides are short enough or we've exceeded the max rope depth, the
/// result is a flat `JeffJSString`.  Otherwise it is a `JeffJSStringRope`
/// wrapped in a `JeffJSValue`.
///
/// Phase 4 optimization: When rope depth exceeds kMaxRopeDepth, instead of
/// creating a flat JeffJSString (O(n) copy), we flatten into a JeffJSStringBuffer
/// with geometric growth. On subsequent concats, if the left operand is already
/// a buffer, we append directly (amortized O(1)). This turns the `s += "x"`
/// loop pattern from O(n^2) to O(n).
func jeffJS_concatStrings(s1: JeffJSValue, s2: JeffJSValue) -> JeffJSValue {
    // Phase 4 fast path: left operand is already a buffer accumulator.
    // Append right operand directly — amortized O(1).
    if let buf = s1.heapRef as? JeffJSStringBuffer {
        buf.concatValue(s2)
        return s1.dupValue()  // caller may free s1; return owned copy
    }

    // Resolve both operands to flat strings for length checks.
    // Note: stringValue flattens ropes, but for buffer operands we handled above.
    guard let str1 = s1.stringValue, let str2 = s2.stringValue else {
        return .makeException()
    }

    // Degenerate cases — return owned copy so caller can safely free inputs
    if str1.len == 0 { return s2.dupValue() }
    if str2.len == 0 { return s1.dupValue() }

    let totalLen = str1.len + str2.len
    guard totalLen <= 0x7FFF_FFFF else { return .makeException() }

    // For short strings just flatten immediately.
    let shortThreshold = 256
    if totalLen <= shortThreshold {
        return JeffJSValue.makeString(jeffJS_flatConcatStrings(str1, str2))
    }

    // Build a rope node.
    let d1 = ropeDepth(s1)
    let d2 = ropeDepth(s2)
    let depth = max(d1, d2) + 1

    if depth > kMaxRopeDepth {
        // Phase 4: instead of flat concat, create a buffer accumulator.
        // This gives amortized O(1) appends on subsequent iterations.
        let buf = JeffJSStringBuffer()
        buf.concatValue(s1)
        buf.concatValue(s2)
        return JeffJSValue.mkPtr(tag: .string, ptr: buf)
    }

    let wide = str1.isWideChar || str2.isWideChar
    let rope = JeffJSStringRope(refCount: 1,
                                len: totalLen,
                                isWideChar: wide,
                                depth: depth > 255 ? 255 : UInt8(depth),
                                left: s1.dupValue(),
                                right: s2.dupValue())
    // Wrap in a value.  Ropes are represented as objects at the value level;
    // we store them via the `.ptr` union case.
    return JeffJSValue.mkPtr(tag: .string, ptr: rope)
}

/// Compute the depth of a value that might be a rope.
private func ropeDepth(_ v: JeffJSValue) -> UInt8 {
    if let rope = v.heapRef as? JeffJSStringRope {
        return rope.depth
    }
    return 0
}

/// Flatten two `JeffJSString`s into a single contiguous string.
/// Uses memcpy for same-width fast path.
private func jeffJS_flatConcatStrings(_ s1: JeffJSString, _ s2: JeffJSString) -> JeffJSString {
    let wide = s1.isWideChar || s2.isWideChar
    let totalLen = s1.len + s2.len

    if wide {
        var buf = [UInt16](repeating: 0, count: totalLen)
        let len1 = min(s1.len, totalLen)
        let len2 = min(s2.len, totalLen - len1)
        buf.withUnsafeMutableBufferPointer { dst in
            guard let dstBase = dst.baseAddress else { return }
            // Copy s1
            if s1.isWideChar, case .str16(let a) = s1.storage {
                a.withUnsafeBufferPointer { src in
                    guard let srcBase = src.baseAddress else { return }
                    memcpy(dstBase, srcBase, min(len1, a.count) &* 2)
                }
            } else {
                for i in 0 ..< len1 { dstBase[i] = UInt16(jeffJS_getString(str: s1, at: i)) }
            }
            // Copy s2
            if s2.isWideChar, case .str16(let a) = s2.storage {
                a.withUnsafeBufferPointer { src in
                    guard let srcBase = src.baseAddress else { return }
                    memcpy(dstBase + len1, srcBase, min(len2, a.count) &* 2)
                }
            } else {
                for i in 0 ..< len2 { (dstBase + len1)[i] = UInt16(jeffJS_getString(str: s2, at: i)) }
            }
        }
        return JeffJSString(refCount: 1,
                            len: totalLen,
                            isWideChar: true,
                            storage: .str16(buf))
    } else {
        var buf = [UInt8](repeating: 0, count: totalLen)
        buf.withUnsafeMutableBufferPointer { dst in
            guard let dstBase = dst.baseAddress else { return }
            if case .str8(let a) = s1.storage {
                a.withUnsafeBufferPointer { src in
                    guard let srcBase = src.baseAddress else { return }
                    let copyLen = min(s1.len, a.count, totalLen)
                    if copyLen > 0 { memcpy(dstBase, srcBase, copyLen) }
                }
            }
            if case .str8(let b) = s2.storage {
                b.withUnsafeBufferPointer { src in
                    guard let srcBase = src.baseAddress else { return }
                    let offset = min(s1.len, totalLen)
                    let copyLen = min(s2.len, b.count, totalLen - offset)
                    if copyLen > 0 { memcpy(dstBase + offset, srcBase, copyLen) }
                }
            }
        }
        return JeffJSString(refCount: 1,
                            len: totalLen,
                            isWideChar: false,
                            storage: .str8(buf))
    }
}

// MARK: - Flatten rope

/// Recursively flatten a `JeffJSStringRope` into a contiguous `JeffJSString`.
func jeffJS_flattenRope(_ rope: JeffJSStringRope) -> JeffJSString {
    let wide = rope.isWideChar

    if wide {
        var buf = [UInt16](repeating: 0, count: rope.len)
        var offset = 0
        flattenInto16(&buf, &offset, rope.left)
        flattenInto16(&buf, &offset, rope.right)
        return JeffJSString(refCount: 1,
                            len: rope.len,
                            isWideChar: true,
                            storage: .str16(buf))
    } else {
        var buf = [UInt8](repeating: 0, count: rope.len)
        var offset = 0
        flattenInto8(&buf, &offset, rope.left)
        flattenInto8(&buf, &offset, rope.right)
        return JeffJSString(refCount: 1,
                            len: rope.len,
                            isWideChar: false,
                            storage: .str8(buf))
    }
}

private func flattenInto16(_ buf: inout [UInt16], _ offset: inout Int, _ val: JeffJSValue) {
    if let obj = val.heapRef {
        if let rope = obj as? JeffJSStringRope {
            flattenInto16(&buf, &offset, rope.left)
            flattenInto16(&buf, &offset, rope.right)
            return
        }
        if let str = obj as? JeffJSString {
            for i in 0 ..< str.len {
                buf[offset] = UInt16(jeffJS_getString(str: str, at: i))
                offset += 1
            }
            return
        }
        // Phase 4: handle buffer accumulator in rope tree
        if let sbuf = obj as? JeffJSStringBuffer {
            if sbuf.isWideChar, let wide = sbuf._buf16Access {
                for i in 0 ..< sbuf.size {
                    buf[offset] = wide[i]
                    offset += 1
                }
            } else {
                let narrow = sbuf._buf8Access
                for i in 0 ..< sbuf.size {
                    buf[offset] = UInt16(narrow[i])
                    offset += 1
                }
            }
            return
        }
    }
}

private func flattenInto8(_ buf: inout [UInt8], _ offset: inout Int, _ val: JeffJSValue) {
    if let obj = val.heapRef {
        if let rope = obj as? JeffJSStringRope {
            flattenInto8(&buf, &offset, rope.left)
            flattenInto8(&buf, &offset, rope.right)
            return
        }
        if let str = obj as? JeffJSString {
            if case .str8(let data) = str.storage {
                let count = min(str.len, data.count)
                if count > 0 {
                    buf.withUnsafeMutableBufferPointer { dst in
                        data.withUnsafeBufferPointer { src in
                            guard let d = dst.baseAddress, let s = src.baseAddress else { return }
                            memcpy(d + offset, s, count)
                        }
                    }
                    offset += count
                }
            } else {
                for i in 0 ..< str.len {
                    buf[offset] = UInt8(jeffJS_getString(str: str, at: i) & 0xFF)
                    offset += 1
                }
            }
            return
        }
        // Phase 4: handle buffer accumulator in rope tree
        if let sbuf = obj as? JeffJSStringBuffer {
            let narrow = sbuf._buf8Access
            let count = min(sbuf.size, narrow.count)
            if count > 0 {
                buf.withUnsafeMutableBufferPointer { dst in
                    narrow.withUnsafeBufferPointer { src in
                        guard let d = dst.baseAddress, let s = src.baseAddress else { return }
                        memcpy(d + offset, s, count)
                    }
                }
                offset += count
            }
            return
        }
    }
}

// MARK: - StringBuffer (port of QuickJS StringBuffer)

/// Growable string builder matching the QuickJS `StringBuffer` API.
final class JeffJSStringBuffer {

    /// Reference count for when the buffer is stored directly in a JeffJSValue
    /// as an accumulator (Phase 4 string concat optimization).
    var refCount: Int

    /// The owning context (retained weakly to avoid cycles).
    private weak var ctx: (any JeffJSContextProtocol)?

    /// 8-bit backing store (used as long as all chars fit in Latin-1).
    private var buf8: [UInt8]

    /// 16-bit backing store (only non-nil after widening).
    private var buf16: [UInt16]?

    /// Number of code units written.
    private(set) var size: Int

    /// Whether the buffer has been widened to 16-bit.
    private(set) var isWideChar: Bool

    /// Tracks whether an unrecoverable error (e.g. OOM) has occurred.
    private(set) var hasError: Bool

    /// Initial allocation.
    private static let kInitialCapacity = 256

    // -- Internal buffer access (for flattenInto helpers) --------------------

    /// Read-only access to the 8-bit backing store (for rope flattening).
    var _buf8Access: [UInt8] { buf8 }

    /// Read-only access to the 16-bit backing store (for rope flattening).
    var _buf16Access: [UInt16]? { buf16 }

    // -- Lifecycle -----------------------------------------------------------

    init(ctx: (any JeffJSContextProtocol)? = nil) {
        self.refCount = 1
        self.ctx = ctx
        self.buf8 = [UInt8]()
        self.buf8.reserveCapacity(JeffJSStringBuffer.kInitialCapacity)
        self.buf16 = nil
        self.size = 0
        self.isWideChar = false
        self.hasError = false
    }

    // -- Capacity ------------------------------------------------------------

    private func ensureCapacity8(_ extra: Int) {
        let needed = size + extra
        if buf8.count < needed {
            // Nothing to do for Swift arrays — append will grow automatically.
        }
    }

    /// Widen from 8-bit to 16-bit storage, preserving existing content.
    private func widenTo16() {
        if isWideChar { return }
        var wide = [UInt16]()
        wide.reserveCapacity(max(buf8.count, size))
        for i in 0 ..< size {
            wide.append(UInt16(buf8[i]))
        }
        buf16 = wide
        isWideChar = true
    }

    // -- put helpers ---------------------------------------------------------

    /// Append a single byte (Latin-1 code point).
    func putc8(_ c: UInt8) {
        guard !hasError else { return }
        if isWideChar {
            buf16!.append(UInt16(c))
        } else {
            buf8.append(c)
        }
        size += 1
    }

    /// Append a 16-bit code unit.  Widens the buffer if necessary.
    func putc16(_ c: UInt16) {
        guard !hasError else { return }
        if c <= 0xFF && !isWideChar {
            buf8.append(UInt8(c))
            size += 1
            return
        }
        if !isWideChar { widenTo16() }
        buf16!.append(c)
        size += 1
    }

    /// Append a Unicode code point.  If the code point is in the supplementary
    /// planes (> 0xFFFF) it is encoded as a surrogate pair.
    func putc(_ codePoint: UInt32) {
        guard !hasError else { return }
        if codePoint < 0x100 && !isWideChar {
            buf8.append(UInt8(codePoint))
            size += 1
            return
        }
        if codePoint <= 0xFFFF {
            putc16(UInt16(codePoint))
            return
        }
        // Surrogate pair
        if !isWideChar { widenTo16() }
        let hi = UInt16(0xD800 + ((codePoint - 0x10000) >> 10))
        let lo = UInt16(0xDC00 + ((codePoint - 0x10000) & 0x3FF))
        buf16!.append(hi)
        buf16!.append(lo)
        size += 2
    }

    /// Append a Swift `String` interpreted as Latin-1 (only the low byte of
    /// each scalar is used).  This is the equivalent of QuickJS `string_buffer_puts8`.
    func puts8(_ string: String) {
        guard !hasError else { return }
        for scalar in string.unicodeScalars {
            let c = UInt8(scalar.value & 0xFF)
            if isWideChar {
                buf16!.append(UInt16(c))
            } else {
                buf8.append(c)
            }
            size += 1
        }
    }

    /// Append raw 16-bit data.
    func puts16(_ data: [UInt16]) {
        guard !hasError else { return }
        if !isWideChar { widenTo16() }
        buf16!.append(contentsOf: data)
        size += data.count
    }

    /// Append the full contents of a `JeffJSString`.
    func concat(_ str: JeffJSString) {
        guard !hasError else { return }
        switch str.storage {
        case .str8(let data):
            if isWideChar {
                for i in 0 ..< str.len {
                    buf16!.append(UInt16(data[i]))
                }
            } else {
                buf8.append(contentsOf: data.prefix(str.len))
            }
            size += str.len

        case .str16(let data):
            if !isWideChar { widenTo16() }
            buf16!.append(contentsOf: data.prefix(str.len))
            size += str.len
        }
    }

    /// Append `count` copies of the code unit `c`.
    func fill(_ c: UInt32, count: Int) {
        guard !hasError, count > 0 else { return }
        if c > 0xFF || isWideChar {
            if !isWideChar { widenTo16() }
            let unit = UInt16(c & 0xFFFF)
            for _ in 0 ..< count {
                buf16!.append(unit)
            }
        } else {
            let byte = UInt8(c & 0xFF)
            for _ in 0 ..< count {
                buf8.append(byte)
            }
        }
        size += count
    }

    // -- Accumulator concat support (Phase 4 optimization) --------------------

    /// Append the string content of a JeffJSValue (flat string, rope, or buffer).
    /// Used by `jeffJS_concatStrings` to append the right operand into this buffer.
    func concatValue(_ val: JeffJSValue) {
        guard !hasError else { return }
        if let ref = val.heapRef {
            if let str = ref as? JeffJSString {
                concat(str)
                return
            }
            if let rope = ref as? JeffJSStringRope {
                concatRope(rope)
                return
            }
            if let buf = ref as? JeffJSStringBuffer {
                concatBuffer(buf)
                return
            }
        }
    }

    /// Append the contents of a rope (recursively flattened into this buffer).
    private func concatRope(_ rope: JeffJSStringRope) {
        concatValue(rope.left)
        concatValue(rope.right)
    }

    /// Append the contents of another buffer.
    func concatBuffer(_ other: JeffJSStringBuffer) {
        guard !hasError else { return }
        if other.isWideChar {
            if let otherBuf = other.buf16 {
                if !isWideChar { widenTo16() }
                buf16!.append(contentsOf: otherBuf.prefix(other.size))
            }
        } else {
            if isWideChar {
                for i in 0 ..< other.size {
                    buf16!.append(UInt16(other.buf8[i]))
                }
            } else {
                buf8.append(contentsOf: other.buf8.prefix(other.size))
            }
        }
        size += other.size
    }

    /// Materialise the buffer contents as a `JeffJSString` without resetting.
    /// The buffer remains valid for further appends (unlike `end()` which resets).
    func toJeffJSString() -> JeffJSString {
        if isWideChar {
            let buf = buf16!
            var canNarrow = true
            for i in 0 ..< size {
                if buf[i] > 0xFF { canNarrow = false; break }
            }
            if canNarrow {
                var narrow = [UInt8](repeating: 0, count: size)
                for i in 0 ..< size { narrow[i] = UInt8(buf[i]) }
                return JeffJSString(refCount: 1,
                                    len: size,
                                    isWideChar: false,
                                    storage: .str8(narrow))
            } else {
                return JeffJSString(refCount: 1,
                                    len: size,
                                    isWideChar: true,
                                    storage: .str16(Array(buf.prefix(size))))
            }
        } else {
            return JeffJSString(refCount: 1,
                                len: size,
                                isWideChar: false,
                                storage: .str8(Array(buf8.prefix(size))))
        }
    }

    /// Convert buffer contents to a Swift String.
    func toSwiftString() -> String {
        if isWideChar, let buf = buf16 {
            return String(utf16CodeUnits: Array(buf.prefix(size)), count: size)
        } else {
            return String(buf8.prefix(size).map { Character(Unicode.Scalar($0)) })
        }
    }

    @discardableResult
    func retain() -> JeffJSStringBuffer {
        refCount += 1
        return self
    }

    func release() {
        refCount -= 1
    }

    /// Finalise the buffer and return a `JeffJSString`.
    /// After this call the buffer is invalidated (reset to empty).
    func end() -> JeffJSString? {
        guard !hasError else { return nil }

        let result: JeffJSString
        if isWideChar {
            // Try to narrow if all values fit in 8-bit.
            var canNarrow = true
            let buf = buf16!
            for i in 0 ..< size {
                if buf[i] > 0xFF { canNarrow = false; break }
            }
            if canNarrow {
                var narrow = [UInt8](repeating: 0, count: size)
                for i in 0 ..< size { narrow[i] = UInt8(buf[i]) }
                result = JeffJSString(refCount: 1,
                                      len: size,
                                      isWideChar: false,
                                      storage: .str8(narrow))
            } else {
                result = JeffJSString(refCount: 1,
                                      len: size,
                                      isWideChar: true,
                                      storage: .str16(Array(buf.prefix(size))))
            }
        } else {
            result = JeffJSString(refCount: 1,
                                  len: size,
                                  isWideChar: false,
                                  storage: .str8(Array(buf8.prefix(size))))
        }

        // Reset internal state so the buffer can be reused (QuickJS pattern).
        resetInternal()
        return result
    }

    /// Release all internal storage without producing a string.
    func free() {
        resetInternal()
    }

    private func resetInternal() {
        buf8.removeAll(keepingCapacity: false)
        buf16 = nil
        size = 0
        isWideChar = false
        hasError = false
    }
}

// MARK: - Swift String interop helpers

extension JeffJSString {

    /// Create a `JeffJSString` from a Swift `String`.
    /// Uses 8-bit storage when all scalars fit in Latin-1, otherwise 16-bit.
    convenience init(swiftString: String) {
        let scalars = Array(swiftString.unicodeScalars)
        let needsWide = scalars.contains { $0.value > 0xFF }

        if needsWide {
            var buf = [UInt16]()
            buf.reserveCapacity(swiftString.utf16.count)
            for unit in swiftString.utf16 {
                buf.append(unit)
            }
            self.init(refCount: 1,
                      len: buf.count,
                      isWideChar: true,
                      storage: .str16(buf))
        } else {
            var buf = [UInt8]()
            buf.reserveCapacity(scalars.count)
            for s in scalars {
                buf.append(UInt8(s.value & 0xFF))
            }
            self.init(refCount: 1,
                      len: buf.count,
                      isWideChar: false,
                      storage: .str8(buf))
        }
    }

    /// Convert back to a Swift `String`.
    func toSwiftString() -> String {
        switch storage {
        case .str8(let buf):
            return String(buf.prefix(len).map { Character(Unicode.Scalar($0)) })
        case .str16(let buf):
            return String(utf16CodeUnits: Array(buf.prefix(len)), count: len)
        }
    }
}
