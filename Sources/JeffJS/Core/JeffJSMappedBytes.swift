// JeffJSMappedBytes.swift
// JeffJS — immutable byte storage that does not have to live in the heap
// (perf/bytecode-paging).
//
// SHARED ABSTRACTION (also for perf/lazy-payload's lazy object literals):
//
//   * `JeffJSMappedBytes` — an immutable block of bytes and its lifetime.
//     Two implementations: `JeffJSFileMapping` (a read-only `mmap` of a
//     file: clean, file-backed pages the OS pages in on first touch and may
//     evict under pressure; they do not count in the process footprint) and
//     `JeffJSHeapBytes` (one malloc block, for text that has no file yet).
//   * `JeffJSBytesSpan` — (owner, offset, count) into one of them: a value
//     type that keeps its owner alive (the "pin"), so a span read by a parse,
//     a lazy compile or `Function.prototype.toString` can never outlive its
//     mapping. Holders swap spans (heap -> mapping once a file exists); a
//     reader that took a span copy keeps the old storage alive until done.
//
// Nothing here may be written to: the mappings are PROT_READ, a write
// faults. Cache files are replaced by rename (a mapping keeps the old inode)
// and sidecars are append-only, so a mapping never sees its bytes change or
// its file shrink (which would SIGBUS).

import Foundation

/// An immutable block of bytes with an owner that keeps it valid.
nonisolated public protocol JeffJSMappedBytes: AnyObject {
    /// First byte (valid for `count` bytes while the object lives).
    var baseAddress: UnsafeRawPointer { get }
    var count: Int { get }
    /// true: pages of a file mapping (not heap, not in the footprint while clean).
    var isFileBacked: Bool { get }
}

/// A read-only memory mapping of a whole file.
nonisolated public final class JeffJSFileMapping: JeffJSMappedBytes, @unchecked Sendable {
    public let baseAddress: UnsafeRawPointer
    public let count: Int
    public var isFileBacked: Bool { true }
    /// The mapped file (diagnostics).
    public let path: String

    /// Live mappings / mapped bytes, process-wide (stats, tests).
    nonisolated(unsafe) static var liveCount = 0
    nonisolated(unsafe) static var liveBytes = 0
    private static let statsLock = NSLock()

    /// Maps `path` read-only, or nil (missing, empty, or mmap failed).
    public init?(path: String) {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else { return nil }
        let n = Int(st.st_size)
        guard let p = mmap(nil, n, PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else { return nil }
        baseAddress = UnsafeRawPointer(p)
        count = n
        self.path = path
        Self.statsLock.lock(); Self.liveCount += 1; Self.liveBytes += n; Self.statsLock.unlock()
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: baseAddress), count)
        Self.statsLock.lock(); Self.liveCount -= 1; Self.liveBytes -= count; Self.statsLock.unlock()
    }

    static var liveStats: (count: Int, bytes: Int) {
        statsLock.lock(); defer { statsLock.unlock() }
        return (liveCount, liveBytes)
    }
}

/// One heap block (bytes that have no file behind them yet).
nonisolated public final class JeffJSHeapBytes: JeffJSMappedBytes, @unchecked Sendable {
    public let baseAddress: UnsafeRawPointer
    public let count: Int
    public var isFileBacked: Bool { false }

    /// `count` bytes written once by `fill`.
    public init(count n: Int, fill: (UnsafeMutablePointer<UInt8>) -> Void) {
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(n, 1))
        fill(p)
        baseAddress = UnsafeRawPointer(p)
        count = n
    }

    /// Copies `bytes`.
    public convenience init(copying bytes: [UInt8]) {
        self.init(count: bytes.count) { dst in
            bytes.withUnsafeBufferPointer { if let b = $0.baseAddress { dst.initialize(from: b, count: $0.count) } }
        }
    }

    /// The UTF-8 of `s` (one copy).
    public convenience init(utf8 s: String) {
        var s = s
        let n = s.utf8.count
        self.init(count: n) { dst in
            s.withUTF8 { if let b = $0.baseAddress { dst.initialize(from: b, count: n) } }
        }
    }

    deinit {
        UnsafeMutableRawPointer(mutating: baseAddress).deallocate()
    }
}

/// (owner, offset, count) into immutable bytes; keeps the owner alive.
/// Indexable like the `[UInt8]` it replaces (reads past the end give 0, the
/// QuickJS buffer terminator, instead of trapping).
nonisolated public struct JeffJSBytesSpan: RandomAccessCollection {
    public let owner: JeffJSMappedBytes?
    public let base: UnsafePointer<UInt8>?
    public let count: Int

    public typealias Index = Int
    public typealias Element = UInt8
    @inline(__always) public var startIndex: Int { 0 }
    @inline(__always) public var endIndex: Int { count }

    public init() { owner = nil; base = nil; count = 0 }

    public init(_ owner: JeffJSMappedBytes, offset: Int = 0, count: Int? = nil) {
        let n = count ?? (owner.count - offset)
        precondition(offset >= 0 && n >= 0 && offset + n <= owner.count, "span outside its bytes")
        self.owner = owner
        self.base = owner.baseAddress.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
        self.count = n
    }

    /// A heap copy of `bytes`.
    public init(copying bytes: [UInt8]) {
        if bytes.isEmpty { self.init(); return }
        self.init(JeffJSHeapBytes(copying: bytes))
    }

    /// The UTF-8 of `s`, on the heap.
    public init(utf8 s: String) {
        let h = JeffJSHeapBytes(utf8: s)
        if h.count == 0 { self.init(); return }
        self.init(h)
    }

    @inline(__always)
    public subscript(i: Int) -> UInt8 {
        guard let b = base, UInt(bitPattern: i) < UInt(bitPattern: count) else { return 0 }
        return b[i]
    }

    @inline(__always)
    public func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        return try body(UnsafeBufferPointer(start: base, count: base == nil ? 0 : count))
    }

    public func withContiguousStorageIfAvailable<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R? {
        return try body(UnsafeBufferPointer(start: base, count: base == nil ? 0 : count))
    }

    /// A sub-span sharing the owner.
    public func span(offset: Int, count n: Int) -> JeffJSBytesSpan? {
        guard let o = owner, let b = base, offset >= 0, n >= 0, offset + n <= count else { return nil }
        let start = UnsafeRawPointer(b).advanced(by: offset) - o.baseAddress
        return JeffJSBytesSpan(o, offset: start, count: n)
    }

    /// Bytes live in a file mapping (not the heap).
    public var isFileBacked: Bool { owner?.isFileBacked ?? false }

    /// Byte-equal to `other`.
    public func contentEquals(_ other: JeffJSBytesSpan) -> Bool {
        guard count == other.count else { return false }
        if count == 0 { return true }
        guard let a = base, let b = other.base else { return false }
        return memcmp(a, b, count) == 0
    }
}
