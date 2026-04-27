// JeffJSCUtils.swift
// JeffJS - 1:1 Swift port of QuickJS JavaScript engine
//
// Port of QuickJS cutils.c / cutils.h — dynamic buffers, integer/unicode
// conversion helpers, LEB128 encoding, safe arithmetic, and sorting.

import Foundation

// MARK: - DynBuf (dynamic byte buffer)

/// Port of QuickJS `DynBuf` — a growable byte buffer used for bytecode
/// serialisation, string building, and general binary output.
struct DynBuf {
    var buf: [UInt8]
    var size: Int       // allocated capacity
    var len: Int        // used length (number of bytes written)
    var error: Bool     // sticky error flag (set on allocation failure)

    /// Create an empty dynamic buffer with optional initial capacity.
    init(initialCapacity: Int = 256) {
        self.buf = [UInt8]()
        self.buf.reserveCapacity(initialCapacity)
        self.size = initialCapacity
        self.len = 0
        self.error = false
    }

    /// Default init — zero-sized buffer.
    init() {
        self.buf = [UInt8]()
        self.size = 0
        self.len = 0
        self.error = false
    }

    // MARK: Realloc / Grow

    /// Maximum bytecode buffer size (50 MB) — prevents OOM from parser bugs.
    /// The parser checks this limit actively and aborts with a syntax error.
    static let maxSize = 50 * 1024 * 1024

    /// Ensure the buffer can hold at least `newSize` bytes.
    /// Mirrors `dbuf_realloc` in QuickJS.
    mutating func realloc(newSize: Int) {
        guard !error else { return }
        if newSize > DynBuf.maxSize {
            error = true
            return
        }
        if newSize <= size && buf.count >= newSize {
            return
        }
        if newSize > size {
            // Actually need more capacity — grow by 2x or to requested size.
            let target = min(max(newSize, size * 2, 16), DynBuf.maxSize)
            buf.reserveCapacity(target)
            size = target
        }
        // else: size is sufficient but buf.count is short — no need to change size
    }

    /// Ensure room for `extra` more bytes beyond `len`.
    private mutating func ensureSpace(_ extra: Int) {
        let needed = len + extra
        if needed > buf.count || needed > size {
            realloc(newSize: needed)
        }
    }

    // MARK: Put primitives

    /// Append a single byte. Mirrors `dbuf_putc` in QuickJS.
    mutating func putU8(_ val: UInt8) {
        guard !error else { return }
        if len >= buf.count {
            ensureSpace(1)
        }
        if len < buf.count {
            buf[len] = val
        } else {
            buf.append(val)
        }
        len += 1
    }

    /// Append an opcode to the bytecode buffer.
    ///
    /// Opcodes with rawValue 1-255 are stored as a single byte.
    /// Opcodes with rawValue >= 256 (temporary opcodes like scope_put_var_init,
    /// line_num, etc.) are stored as a 2-byte sequence: a 0x00 prefix byte
    /// (the `invalid` opcode, which never appears in valid bytecode) followed
    /// by (rawValue - 256). The compiler's resolve passes know how to read
    /// this encoding back via `JeffJSCompiler.readOpcodeFromBuf`.
    mutating func putOpcode(_ rawValue: UInt16) {
        if rawValue <= 255 {
            putU8(UInt8(rawValue))
        } else {
            // Wide opcode: prefix with 0x00 (invalid), then low byte
            putU8(0)  // wide-opcode prefix
            putU8(UInt8(rawValue - 256))
        }
    }

    /// Append a UInt16 in little-endian byte order.
    /// Mirrors `dbuf_put_u16` in QuickJS.
    mutating func putU16(_ val: UInt16) {
        putU8(UInt8(val & 0xFF))
        putU8(UInt8((val >> 8) & 0xFF))
    }

    /// Append a UInt32 in little-endian byte order.
    /// Mirrors `dbuf_put_u32` in QuickJS.
    mutating func putU32(_ val: UInt32) {
        putU8(UInt8(val & 0xFF))
        putU8(UInt8((val >> 8) & 0xFF))
        putU8(UInt8((val >> 16) & 0xFF))
        putU8(UInt8((val >> 24) & 0xFF))
    }

    /// Append a UInt64 in little-endian byte order.
    mutating func putU64(_ val: UInt64) {
        putU32(UInt32(val & 0xFFFF_FFFF))
        putU32(UInt32((val >> 32) & 0xFFFF_FFFF))
    }

    /// Append raw bytes from an array.
    /// Mirrors `dbuf_put` in QuickJS.
    mutating func putBytes(_ data: [UInt8]) {
        guard !error, !data.isEmpty else { return }
        ensureSpace(data.count)
        for byte in data {
            if len < buf.count {
                buf[len] = byte
            } else {
                buf.append(byte)
            }
            len += 1
        }
    }

    /// Append raw bytes from an ArraySlice.
    mutating func putBytes(_ data: ArraySlice<UInt8>) {
        guard !error, !data.isEmpty else { return }
        ensureSpace(data.count)
        for byte in data {
            if len < buf.count {
                buf[len] = byte
            } else {
                buf.append(byte)
            }
            len += 1
        }
    }

    /// Append a Swift string as UTF-8 bytes (including the NUL terminator
    /// is **not** appended — matches `dbuf_putstr` in QuickJS).
    mutating func putStr(_ str: String) {
        let utf8 = Array(str.utf8)
        putBytes(utf8)
    }

    /// Append `count` copies of `byte`.
    mutating func fill(_ byte: UInt8, count: Int) {
        guard !error, count > 0 else { return }
        ensureSpace(count)
        for _ in 0 ..< count {
            if len < buf.count {
                buf[len] = byte
            } else {
                buf.append(byte)
            }
            len += 1
        }
    }

    /// Reset the buffer to empty (keeps the allocated memory for reuse).
    mutating func free() {
        buf.removeAll(keepingCapacity: false)
        size = 0
        len = 0
        error = false
    }

    /// Return the written bytes as a contiguous array.
    func toBytes() -> [UInt8] {
        return Array(buf.prefix(len))
    }

    /// Read back a UInt8 at the given offset.
    func getU8(at offset: Int) -> UInt8 {
        guard offset >= 0, offset < len else { return 0 }
        return buf[offset]
    }

    /// Read back a little-endian UInt16 at the given offset.
    func getU16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 1 < len else { return 0 }
        return UInt16(buf[offset]) | (UInt16(buf[offset + 1]) << 8)
    }

    /// Read back a little-endian UInt32 at the given offset.
    func getU32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 3 < len else { return 0 }
        return UInt32(buf[offset])
             | (UInt32(buf[offset + 1]) << 8)
             | (UInt32(buf[offset + 2]) << 16)
             | (UInt32(buf[offset + 3]) << 24)
    }

    /// Write a UInt32 at the given offset (little-endian), for back-patching.
    mutating func setU32(at offset: Int, _ val: UInt32) {
        guard offset >= 0, offset + 3 < len else { return }
        buf[offset]     = UInt8(val & 0xFF)
        buf[offset + 1] = UInt8((val >> 8) & 0xFF)
        buf[offset + 2] = UInt8((val >> 16) & 0xFF)
        buf[offset + 3] = UInt8((val >> 24) & 0xFF)
    }

    /// Write a UInt16 at the given offset (little-endian), for back-patching.
    mutating func setU16(at offset: Int, _ val: UInt16) {
        guard offset >= 0, offset + 1 < len else { return }
        buf[offset]     = UInt8(val & 0xFF)
        buf[offset + 1] = UInt8((val >> 8) & 0xFF)
    }

    /// Write a UInt8 at the given offset, for back-patching.
    mutating func setU8(at offset: Int, _ val: UInt8) {
        guard offset >= 0, offset < len else { return }
        buf[offset] = val
    }
}

// MARK: - Integer Conversion Utilities

/// Digits table used by integer-to-string conversions (radix 2-36).
private let kDigits: [Character] = Array("0123456789abcdefghijklmnopqrstuvwxyz")

/// Convert a signed 64-bit integer to a string in the given radix (2-36).
/// Mirrors `i64toa` in QuickJS cutils.c.
func i64toa(_ val: Int64, radix: Int = 10) -> String {
    guard radix >= 2, radix <= 36 else { return "0" }

    if val == 0 { return "0" }

    var result = [Character]()
    let negative = val < 0
    var n: UInt64

    if negative {
        // Handle Int64.min carefully — its absolute value overflows Int64.
        if val == Int64.min {
            n = UInt64(bitPattern: val)
        } else {
            n = UInt64(-val)
        }
    } else {
        n = UInt64(val)
    }

    let r = UInt64(radix)
    while n > 0 {
        let digit = Int(n % r)
        result.append(kDigits[digit])
        n /= r
    }

    if negative {
        result.append("-")
    }

    result.reverse()
    return String(result)
}

/// Convert an unsigned 64-bit integer to a string in the given radix (2-36).
/// Mirrors `u64toa` in QuickJS cutils.c.
func u64toa(_ val: UInt64, radix: Int = 10) -> String {
    guard radix >= 2, radix <= 36 else { return "0" }

    if val == 0 { return "0" }

    var result = [Character]()
    var n = val
    let r = UInt64(radix)

    while n > 0 {
        let digit = Int(n % r)
        result.append(kDigits[digit])
        n /= r
    }

    result.reverse()
    return String(result)
}

/// Convert a signed 64-bit integer to a string in an arbitrary radix (2-36).
/// Same as `i64toa` but named to match the QuickJS `i64toa_radix` variant.
func i64toaRadix(_ val: Int64, radix: Int) -> String {
    return i64toa(val, radix: radix)
}

// MARK: - Unicode Utilities

/// Decode a single UTF-8 code point from `data` starting at `offset`.
/// Returns the decoded code point and the number of bytes consumed.
/// On malformed input, returns (0xFFFD, 1) — the Unicode replacement character.
///
/// Mirrors the UTF-8 decoding in QuickJS `unicode_from_utf8`.
func unicodeFromUTF8(_ data: [UInt8], offset: Int) -> (codePoint: UInt32, bytesConsumed: Int) {
    guard offset < data.count else {
        return (0xFFFD, 0)
    }

    let b0 = data[offset]

    // Single byte (ASCII): 0xxxxxxx
    if b0 < 0x80 {
        return (UInt32(b0), 1)
    }

    // Two bytes: 110xxxxx 10xxxxxx
    if b0 & 0xE0 == 0xC0 {
        guard offset + 1 < data.count else { return (0xFFFD, 1) }
        let b1 = data[offset + 1]
        guard b1 & 0xC0 == 0x80 else { return (0xFFFD, 1) }
        let cp = (UInt32(b0 & 0x1F) << 6) | UInt32(b1 & 0x3F)
        // Reject overlong encodings.
        if cp < 0x80 { return (0xFFFD, 2) }
        return (cp, 2)
    }

    // Three bytes: 1110xxxx 10xxxxxx 10xxxxxx
    if b0 & 0xF0 == 0xE0 {
        guard offset + 2 < data.count else { return (0xFFFD, 1) }
        let b1 = data[offset + 1]
        let b2 = data[offset + 2]
        guard b1 & 0xC0 == 0x80, b2 & 0xC0 == 0x80 else { return (0xFFFD, 1) }
        let cp = (UInt32(b0 & 0x0F) << 12)
               | (UInt32(b1 & 0x3F) << 6)
               | UInt32(b2 & 0x3F)
        // Reject overlong encodings and surrogates.
        if cp < 0x800 { return (0xFFFD, 3) }
        if cp >= 0xD800 && cp <= 0xDFFF { return (0xFFFD, 3) }
        return (cp, 3)
    }

    // Four bytes: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
    if b0 & 0xF8 == 0xF0 {
        guard offset + 3 < data.count else { return (0xFFFD, 1) }
        let b1 = data[offset + 1]
        let b2 = data[offset + 2]
        let b3 = data[offset + 3]
        guard b1 & 0xC0 == 0x80,
              b2 & 0xC0 == 0x80,
              b3 & 0xC0 == 0x80 else { return (0xFFFD, 1) }
        let cp = (UInt32(b0 & 0x07) << 18)
               | (UInt32(b1 & 0x3F) << 12)
               | (UInt32(b2 & 0x3F) << 6)
               | UInt32(b3 & 0x3F)
        // Reject overlong encodings and values above U+10FFFF.
        if cp < 0x10000 || cp > 0x10FFFF { return (0xFFFD, 4) }
        return (cp, 4)
    }

    // Invalid lead byte.
    return (0xFFFD, 1)
}

/// Encode a Unicode code point as UTF-8 into `buf` starting at the current end.
/// Returns the number of bytes written (1-4).
///
/// Mirrors `unicode_to_utf8` in QuickJS cutils.c.
@discardableResult
func unicodeToUTF8(_ buf: inout [UInt8], _ codePoint: UInt32) -> Int {
    if codePoint < 0x80 {
        buf.append(UInt8(codePoint))
        return 1
    }
    if codePoint < 0x800 {
        buf.append(UInt8(0xC0 | (codePoint >> 6)))
        buf.append(UInt8(0x80 | (codePoint & 0x3F)))
        return 2
    }
    if codePoint < 0x10000 {
        buf.append(UInt8(0xE0 | (codePoint >> 12)))
        buf.append(UInt8(0x80 | ((codePoint >> 6) & 0x3F)))
        buf.append(UInt8(0x80 | (codePoint & 0x3F)))
        return 3
    }
    if codePoint <= 0x10FFFF {
        buf.append(UInt8(0xF0 | (codePoint >> 18)))
        buf.append(UInt8(0x80 | ((codePoint >> 12) & 0x3F)))
        buf.append(UInt8(0x80 | ((codePoint >> 6) & 0x3F)))
        buf.append(UInt8(0x80 | (codePoint & 0x3F)))
        return 4
    }
    // Invalid code point — encode replacement character.
    return unicodeToUTF8(&buf, 0xFFFD)
}

/// Decode a supplementary code point from a UTF-16 surrogate pair.
/// Mirrors the macro in QuickJS: `(((hi) - 0xD800) << 10) + ((lo) - 0xDC00) + 0x10000`.
@inline(__always)
func unicodeFromUTF16Surrogates(high: UInt16, low: UInt16) -> UInt32 {
    return (UInt32(high) - 0xD800) * 0x400 + (UInt32(low) - 0xDC00) + 0x10000
}

/// Returns `true` if `c` is a UTF-16 high surrogate (U+D800..U+DBFF).
@inline(__always)
func isHiSurrogate(_ c: UInt16) -> Bool {
    return c >= 0xD800 && c <= 0xDBFF
}

/// Overload for UInt32.
@inline(__always)
func isHiSurrogate(_ c: UInt32) -> Bool {
    return c >= 0xD800 && c <= 0xDBFF
}

/// Returns `true` if `c` is a UTF-16 low surrogate (U+DC00..U+DFFF).
@inline(__always)
func isLoSurrogate(_ c: UInt16) -> Bool {
    return c >= 0xDC00 && c <= 0xDFFF
}

/// Overload for UInt32.
@inline(__always)
func isLoSurrogate(_ c: UInt32) -> Bool {
    return c >= 0xDC00 && c <= 0xDFFF
}

/// Returns `true` if `c` is any surrogate (high or low).
@inline(__always)
func isSurrogate(_ c: UInt32) -> Bool {
    return c >= 0xD800 && c <= 0xDFFF
}

// MARK: - Math Helpers

/// Count leading zeros of a 32-bit unsigned integer.
/// Returns 32 for input 0.  Mirrors `clz32` in QuickJS cutils.c.
@inline(__always)
func clz32(_ v: UInt32) -> Int {
    if v == 0 { return 32 }
    return v.leadingZeroBitCount
}

/// Count leading zeros of a 64-bit unsigned integer.
/// Returns 64 for input 0.  Mirrors `clz64` in QuickJS cutils.c.
@inline(__always)
func clz64(_ v: UInt64) -> Int {
    if v == 0 { return 64 }
    return v.leadingZeroBitCount
}

/// Count trailing zeros of a 32-bit unsigned integer.
/// Returns 32 for input 0.  Mirrors `ctz32` in QuickJS cutils.c.
@inline(__always)
func ctz32(_ v: UInt32) -> Int {
    if v == 0 { return 32 }
    return v.trailingZeroBitCount
}

/// Count trailing zeros of a 64-bit unsigned integer.
/// Returns 64 for input 0.  Mirrors `ctz64` in QuickJS cutils.c.
@inline(__always)
func ctz64(_ v: UInt64) -> Int {
    if v == 0 { return 64 }
    return v.trailingZeroBitCount
}

/// Returns `true` if `v` is a power of two (and non-zero).
@inline(__always)
func isPowerOf2(_ v: Int) -> Bool {
    return v > 0 && (v & (v - 1)) == 0
}

/// Returns the smallest power of 2 >= `v`.  If `v <= 0`, returns 1.
/// If the result would overflow `Int`, returns the largest power of 2.
func nextPowerOf2(_ v: Int) -> Int {
    if v <= 1 { return 1 }
    // If already a power of 2, return it.
    if v & (v - 1) == 0 { return v }
    let bits = Int.bitWidth - (v - 1).leadingZeroBitCount
    if bits >= Int.bitWidth - 1 {
        // Would overflow — return largest representable power of 2.
        return 1 << (Int.bitWidth - 2)
    }
    return 1 << bits
}

/// Ceiling integer division: ceil(a / b) for non-negative a, positive b.
@inline(__always)
func ceilDiv(_ a: Int, _ b: Int) -> Int {
    return (a + b - 1) / b
}

/// Maximum of two values.  Provided for parity with C macro usage.
@inline(__always)
func jeffMax<T: Comparable>(_ a: T, _ b: T) -> T {
    return a >= b ? a : b
}

/// Minimum of two values.
@inline(__always)
func jeffMin<T: Comparable>(_ a: T, _ b: T) -> T {
    return a <= b ? a : b
}

// MARK: - LEB128 Encoding / Decoding

/// Encode an unsigned 32-bit integer in unsigned LEB128 format into `buf`.
/// Mirrors `put_leb128` in QuickJS cutils.c.
func putLEB128(_ buf: inout DynBuf, _ val: UInt32) {
    var v = val
    while true {
        let byte = UInt8(v & 0x7F)
        v >>= 7
        if v != 0 {
            buf.putU8(byte | 0x80)
        } else {
            buf.putU8(byte)
            break
        }
    }
}

/// Encode a signed 32-bit integer in signed LEB128 format into `buf`.
/// Mirrors `put_sleb128` in QuickJS cutils.c.
func putSLEB128(_ buf: inout DynBuf, _ val: Int32) {
    var v = val
    while true {
        let byte = UInt8(v & 0x7F)
        v >>= 7
        // Check if the sign bit of the current group matches the remaining
        // value (all 0s or all 1s).
        if (v == 0 && (byte & 0x40) == 0) || (v == -1 && (byte & 0x40) != 0) {
            buf.putU8(byte)
            break
        } else {
            buf.putU8(byte | 0x80)
        }
    }
}

/// Decode an unsigned LEB128-encoded integer from `data` starting at `offset`.
/// Returns the decoded value and the new offset past the consumed bytes.
/// Mirrors `get_leb128` in QuickJS cutils.c.
func getLEB128(_ data: [UInt8], _ offset: Int) -> (val: UInt32, newOffset: Int) {
    var result: UInt32 = 0
    var shift: UInt32 = 0
    var pos = offset

    while pos < data.count {
        let byte = data[pos]
        pos += 1
        result |= UInt32(byte & 0x7F) << shift
        if byte & 0x80 == 0 {
            return (result, pos)
        }
        shift += 7
        if shift >= 35 {
            // Malformed — too many continuation bytes for UInt32.
            break
        }
    }
    return (result, pos)
}

/// Decode a signed LEB128-encoded integer from `data` starting at `offset`.
/// Returns the decoded value and the new offset past the consumed bytes.
/// Mirrors `get_sleb128` in QuickJS cutils.c.
func getSLEB128(_ data: [UInt8], _ offset: Int) -> (val: Int32, newOffset: Int) {
    var result: Int32 = 0
    var shift: Int32 = 0
    var pos = offset
    var byte: UInt8 = 0

    while pos < data.count {
        byte = data[pos]
        pos += 1
        result |= Int32(byte & 0x7F) << shift
        shift += 7
        if byte & 0x80 == 0 {
            break
        }
        if shift >= 35 {
            break
        }
    }

    // Sign-extend if the high bit of the last byte's payload is set.
    if shift < 32 && (byte & 0x40) != 0 {
        result |= -(1 << shift)
    }

    return (result, pos)
}

/// Convenience: encode unsigned LEB128 into a byte array.
func encodeLEB128(_ val: UInt32) -> [UInt8] {
    var dynbuf = DynBuf()
    putLEB128(&dynbuf, val)
    return dynbuf.toBytes()
}

/// Convenience: encode signed LEB128 into a byte array.
func encodeSLEB128(_ val: Int32) -> [UInt8] {
    var dynbuf = DynBuf()
    putSLEB128(&dynbuf, val)
    return dynbuf.toBytes()
}

// MARK: - String Utilities

/// Case-insensitive prefix check.
/// Returns `true` if `str` starts with `prefix` (case-insensitive).
/// Mirrors `has_suffix` / prefix checks in QuickJS cutils.c.
func jeffHasPrefix(_ str: String, _ prefix: String) -> Bool {
    return str.lowercased().hasPrefix(prefix.lowercased())
}

/// Null-safe string comparison. Two nil values are considered equal.
/// Returns `true` if both strings are equal or both are nil.
/// Mirrors `pstrcmp` behaviour in QuickJS cutils.c.
func pstrcmp(_ s1: String?, _ s2: String?) -> Bool {
    switch (s1, s2) {
    case (.none, .none):
        return true
    case (.some(let a), .some(let b)):
        return a == b
    default:
        return false
    }
}

/// Duplicate a string into a new allocation (identity in Swift, but
/// provided for API parity with C `pstrdup`).
func pstrdup(_ s: String?) -> String? {
    return s
}

// MARK: - Safe Arithmetic

/// Add two Int32 values with overflow detection.
/// Returns `(result, overflow)` where `overflow` is `true` if the
/// addition overflowed.  Mirrors QuickJS `safe_add_int32` in cutils.c.
@inline(__always)
func safeAddInt32(_ a: Int32, _ b: Int32) -> (result: Int32, overflow: Bool) {
    let (result, overflow) = a.addingReportingOverflow(b)
    return (result, overflow)
}

/// Multiply two Int32 values with overflow detection.
/// Mirrors QuickJS `safe_mul_int32` in cutils.c.
@inline(__always)
func safeMulInt32(_ a: Int32, _ b: Int32) -> (result: Int32, overflow: Bool) {
    let (result, overflow) = a.multipliedReportingOverflow(by: b)
    return (result, overflow)
}

/// Add two Int64 values with overflow detection.
/// Mirrors QuickJS `safe_add_int64` in cutils.c.
@inline(__always)
func safeAddInt64(_ a: Int64, _ b: Int64) -> (result: Int64, overflow: Bool) {
    let (result, overflow) = a.addingReportingOverflow(b)
    return (result, overflow)
}

/// Multiply two Int64 values with overflow detection.
/// Mirrors QuickJS `safe_mul_int64` in cutils.c.
@inline(__always)
func safeMulInt64(_ a: Int64, _ b: Int64) -> (result: Int64, overflow: Bool) {
    let (result, overflow) = a.multipliedReportingOverflow(by: b)
    return (result, overflow)
}

/// Subtract two Int32 values with overflow detection.
@inline(__always)
func safeSubInt32(_ a: Int32, _ b: Int32) -> (result: Int32, overflow: Bool) {
    let (result, overflow) = a.subtractingReportingOverflow(b)
    return (result, overflow)
}

/// Subtract two Int64 values with overflow detection.
@inline(__always)
func safeSubInt64(_ a: Int64, _ b: Int64) -> (result: Int64, overflow: Bool) {
    let (result, overflow) = a.subtractingReportingOverflow(b)
    return (result, overflow)
}

// MARK: - Sorting

/// Stable quicksort matching the QuickJS `rqsort` function.
///
/// Uses a three-way partition (Dutch national flag) combined with
/// insertion sort for small sub-arrays, then merges to guarantee
/// stability.
///
/// - Parameters:
///   - array: The array to sort in-place.
///   - compare: Comparison function returning <0, 0, or >0.
func rqsort<T>(array: inout [T], compare: (T, T) -> Int) {
    let n = array.count
    if n < 2 { return }
    rqsortImpl(array: &array, lo: 0, hi: n - 1, compare: compare)
}

/// Internal recursive quicksort implementation.
private func rqsortImpl<T>(array: inout [T], lo: Int, hi: Int, compare: (T, T) -> Int) {
    if hi - lo < 10 {
        // Insertion sort for small partitions (stable).
        insertionSort(array: &array, lo: lo, hi: hi, compare: compare)
        return
    }

    // Median-of-three pivot selection.
    let mid = lo + (hi - lo) / 2
    if compare(array[lo], array[mid]) > 0 {
        array.swapAt(lo, mid)
    }
    if compare(array[lo], array[hi]) > 0 {
        array.swapAt(lo, hi)
    }
    if compare(array[mid], array[hi]) > 0 {
        array.swapAt(mid, hi)
    }

    let pivot = array[mid]
    array.swapAt(mid, hi - 1)

    // Three-way partition (Dutch national flag).
    var lt = lo      // array[lo..lt-1] < pivot
    var gt = hi - 1  // array[gt+1..hi] > pivot
    var i = lo       // scanning index

    while i <= gt {
        let c = compare(array[i], pivot)
        if c < 0 {
            array.swapAt(i, lt)
            lt += 1
            i += 1
        } else if c > 0 {
            array.swapAt(i, gt)
            gt -= 1
        } else {
            i += 1
        }
    }

    // Recurse on partitions.
    if lt - 1 > lo {
        rqsortImpl(array: &array, lo: lo, hi: lt - 1, compare: compare)
    }
    if gt + 1 < hi {
        rqsortImpl(array: &array, lo: gt + 1, hi: hi, compare: compare)
    }
}

/// Insertion sort for small sub-arrays — stable and efficient for n < ~16.
private func insertionSort<T>(array: inout [T], lo: Int, hi: Int, compare: (T, T) -> Int) {
    for i in (lo + 1) ... hi {
        let key = array[i]
        var j = i - 1
        while j >= lo && compare(array[j], key) > 0 {
            array[j + 1] = array[j]
            j -= 1
        }
        array[j + 1] = key
    }
}

// MARK: - Byte-swap Helpers

/// Swap the byte order of a 16-bit value.
@inline(__always)
func bswap16(_ v: UInt16) -> UInt16 {
    return v.byteSwapped
}

/// Swap the byte order of a 32-bit value.
@inline(__always)
func bswap32(_ v: UInt32) -> UInt32 {
    return v.byteSwapped
}

/// Swap the byte order of a 64-bit value.
@inline(__always)
func bswap64(_ v: UInt64) -> UInt64 {
    return v.byteSwapped
}

// MARK: - Memory / Array Utilities

/// Read a little-endian UInt16 from a byte array at the given offset.
@inline(__always)
func getLE16(_ data: [UInt8], _ offset: Int) -> UInt16 {
    guard offset + 1 < data.count else { return 0 }
    return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

/// Read a little-endian UInt32 from a byte array at the given offset.
@inline(__always)
func getLE32(_ data: [UInt8], _ offset: Int) -> UInt32 {
    guard offset + 3 < data.count else { return 0 }
    return UInt32(data[offset])
         | (UInt32(data[offset + 1]) << 8)
         | (UInt32(data[offset + 2]) << 16)
         | (UInt32(data[offset + 3]) << 24)
}

/// Read a little-endian UInt64 from a byte array at the given offset.
@inline(__always)
func getLE64(_ data: [UInt8], _ offset: Int) -> UInt64 {
    let lo = UInt64(getLE32(data, offset))
    let hi = UInt64(getLE32(data, offset + 4))
    return lo | (hi << 32)
}

/// Write a little-endian UInt16 into a byte array at the given offset.
@inline(__always)
func putLE16(_ data: inout [UInt8], _ offset: Int, _ val: UInt16) {
    guard offset + 1 < data.count else { return }
    data[offset]     = UInt8(val & 0xFF)
    data[offset + 1] = UInt8((val >> 8) & 0xFF)
}

/// Write a little-endian UInt32 into a byte array at the given offset.
@inline(__always)
func putLE32(_ data: inout [UInt8], _ offset: Int, _ val: UInt32) {
    guard offset + 3 < data.count else { return }
    data[offset]     = UInt8(val & 0xFF)
    data[offset + 1] = UInt8((val >> 8) & 0xFF)
    data[offset + 2] = UInt8((val >> 16) & 0xFF)
    data[offset + 3] = UInt8((val >> 24) & 0xFF)
}

/// Write a little-endian UInt64 into a byte array at the given offset.
@inline(__always)
func putLE64(_ data: inout [UInt8], _ offset: Int, _ val: UInt64) {
    putLE32(&data, offset, UInt32(val & 0xFFFF_FFFF))
    putLE32(&data, offset + 4, UInt32((val >> 32) & 0xFFFF_FFFF))
}

// MARK: - Hex / Digit Utilities

/// Returns the numeric value of a hex digit character, or -1 if not a hex digit.
/// Mirrors `from_hex` in QuickJS cutils.c.
@inline(__always)
func fromHex(_ c: UInt8) -> Int {
    let ch = c
    if ch >= 0x30 && ch <= 0x39 { return Int(ch - 0x30) }        // '0'-'9'
    if ch >= 0x41 && ch <= 0x46 { return Int(ch - 0x41) + 10 }   // 'A'-'F'
    if ch >= 0x61 && ch <= 0x66 { return Int(ch - 0x61) + 10 }   // 'a'-'f'
    return -1
}

/// Returns `true` if the ASCII byte is a decimal digit.
@inline(__always)
func isDigit(_ c: UInt8) -> Bool {
    return c >= 0x30 && c <= 0x39
}

/// Returns `true` if the ASCII byte is a hex digit.
@inline(__always)
func isXDigit(_ c: UInt8) -> Bool {
    return fromHex(c) >= 0
}

/// Returns `true` if the ASCII byte is a letter (a-z, A-Z).
@inline(__always)
func isAlpha(_ c: UInt8) -> Bool {
    return (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
}

/// Returns `true` if the ASCII byte is alphanumeric.
@inline(__always)
func isAlnum(_ c: UInt8) -> Bool {
    return isAlpha(c) || isDigit(c)
}

/// Convert an ASCII byte to uppercase.
@inline(__always)
func toUpper(_ c: UInt8) -> UInt8 {
    if c >= 0x61 && c <= 0x7A { return c - 32 }
    return c
}

/// Convert an ASCII byte to lowercase.
@inline(__always)
func toLower(_ c: UInt8) -> UInt8 {
    if c >= 0x41 && c <= 0x5A { return c + 32 }
    return c
}
