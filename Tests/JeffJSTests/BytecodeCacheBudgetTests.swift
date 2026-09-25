// BytecodeCacheBudgetTests.swift
// JeffJS — "BytecodeCacheBudget" group.
//
// The disk tier of the bytecode cache is byte-budgeted with LRU eviction, is
// invalidated by compiler version + engine identity (never by the app
// binary's modification date), deletes corrupt entries, and caches large
// bundles (the old 1 MB top-level-bytecode cap skipped exactly those).
//
//   swift test -c release --filter BytecodeCacheBudget

import XCTest
@testable import JeffJS

final class BytecodeCacheBudgetTests: XCTestCase {

    private var tmpRoots: [URL] = []

    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jfbc-budget-\(UUID().uuidString)", isDirectory: true)
        tmpRoots.append(url)
        return url
    }

    override func tearDown() {
        for r in tmpRoots { try? FileManager.default.removeItem(at: r) }
        tmpRoots.removeAll()
        super.tearDown()
    }

    private func setUsed(_ url: URL, secondsAgo: Double) {
        let t = Date().addingTimeInterval(-secondsAgo).timeIntervalSince1970
        var times = [timeval(tv_sec: Int(t), tv_usec: 0), timeval(tv_sec: Int(t), tv_usec: 0)]
        _ = url.withUnsafeFileSystemRepresentation { utimes($0!, &times) }
    }

    private func entryExists(_ store: JeffJSBytecodeDiskStore, _ hash: UInt64) -> Bool {
        FileManager.default.fileExists(atPath: store.url(for: hash).path)
    }

    private func describe(_ ctx: JeffJSContext, _ v: JeffJSValue) -> String {
        if v.isException { return "!exception: " + (ctx.toSwiftString(ctx.rt.currentException) ?? "?") }
        return ctx.toSwiftString(v) ?? "!unstringifiable"
    }

    // MARK: - Identity

    /// `engineSourceHash` must match the sources it names; otherwise a changed
    /// parser/compiler would read blobs written by the engine before it.
    func testEngineSourceHashIsCurrent() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let root = testsDir.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/JeffJS", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { throw XCTSkip("sources not found at \(root.path)") }
        var rel: [String] = ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("Parser").path)) ?? [])
            .filter { $0.hasSuffix(".swift") }.map { "Parser/" + $0 }
        rel += ["Bytecode/JeffJSBytecodeCache.swift", "Bytecode/JeffJSCompiler.swift", "Bytecode/JeffJSOpcodes.swift"]
        rel.sort()
        var h: UInt64 = 0xcbf29ce484222325
        func mix<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
            for b in bytes { h ^= UInt64(b); h &*= 0x100000001b3 }
        }
        for r in rel {
            let text = try String(contentsOf: root.appendingPathComponent(r), encoding: .utf8)
            let kept = text.components(separatedBy: "\n").filter { !$0.contains("// bytecode-identity") }
            mix(Array(r.utf8)); mix([0])
            mix(Array(kept.joined(separator: "\n").utf8)); mix([0])
        }
        XCTAssertEqual(JeffJSBytecodeCache.engineSourceHash, h,
                       "engineSourceHash is stale (computed 0x\(String(h, radix: 16))): run Scripts/update_bytecode_identity.sh")
    }

    /// The directory name carries the disk layout, the compiler version and
    /// the engine identity — and nothing derived from the executable in a
    /// release build, so a reinstall of the same engine keeps its entries.
    func testDirectoryNameIsTheEngineIdentity() {
        let name = JeffJSBytecodeCache.diskDirectoryName
        XCTAssertTrue(name.hasPrefix("v\(JeffJSBytecodeCache.diskVersion)-cv\(JeffJSBytecodeCache.compilerVersion)-"), name)
        XCTAssertEqual(name, JeffJSBytecodeCache.diskDirectoryName, "stable within a process")
        XCTAssertTrue(name.hasSuffix(String(JeffJSBytecodeCache.engineIdentity, radix: 16)), name)
    }

    /// Opening a store deletes other engines' directories (the old `v4/`
    /// layout with its `.build_stamp`, other compiler versions) and keeps
    /// every entry of the current one — also across a second open, which is
    /// what a relaunch after `simctl install` of a rebuilt app does. The old
    /// cache purged all entries whenever the executable's mtime changed.
    func testReopeningKeepsEntriesAndDropsOtherEngines() throws {
        let root = tempRoot()
        let fm = FileManager.default
        let name = JeffJSBytecodeCache.diskDirectoryName
        let v4 = root.appendingPathComponent("v4", isDirectory: true)
        let otherCV = root.appendingPathComponent("v5-cv1-0000000000000001", isDirectory: true)
        for d in [v4, otherCV] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: d.appendingPathComponent("42.jfbc"))
        }
        try "12345".write(to: v4.appendingPathComponent(".build_stamp"), atomically: true, encoding: .utf8)

        let store = try XCTUnwrap(JeffJSBytecodeDiskStore(root: root, name: name, budgetBytes: 1 << 20))
        XCTAssertTrue(store.write(7, [UInt8](repeating: 9, count: 1000)))
        // A stamp file in the current directory means nothing any more.
        try "not-this-binary".write(to: store.directory.appendingPathComponent(".build_stamp"), atomically: true, encoding: .utf8)
        store.synchronize()
        XCTAssertFalse(fm.fileExists(atPath: v4.path), "old layout removed")
        XCTAssertFalse(fm.fileExists(atPath: otherCV.path), "other compiler version removed")

        let reopened = try XCTUnwrap(JeffJSBytecodeDiskStore(root: root, name: name, budgetBytes: 1 << 20))
        reopened.synchronize()
        XCTAssertTrue(entryExists(reopened, 7), "a relaunch / reinstall keeps the entry")
        XCTAssertEqual(reopened.read(7)?.count, 1000)
    }

    // MARK: - Budget and LRU

    func testEvictionRemovesLeastRecentlyUsedFirst() throws {
        let root = tempRoot()
        let store = try XCTUnwrap(JeffJSBytecodeDiskStore(root: root, name: "lru", budgetBytes: 100_000))
        store.synchronize()
        // 8 x 20 KB = 160 KB against a 100 KB budget, written behind the
        // store's back so no scan runs before the access times are set.
        // Entry i was last used (100 - i) s ago, so 0 is the oldest...
        for i in 0..<8 {
            try Data(repeating: UInt8(i), count: 20_000).write(to: store.url(for: UInt64(i)))
            setUsed(store.url(for: UInt64(i)), secondsAgo: Double(100 - i))
        }
        // ... but a hit on 0 makes it the most recently used.
        XCTAssertNotNil(store.read(0))
        let (bytes, _) = store.enforceBudget()
        XCTAssertLessThanOrEqual(bytes, 100_000)
        XCTAssertLessThanOrEqual(bytes, 90_000, "evicts down to 90 % of the budget")
        XCTAssertTrue(entryExists(store, 0), "a hit refreshes an entry")
        XCTAssertTrue(entryExists(store, 7), "newest entry kept")
        XCTAssertTrue(entryExists(store, 6))
        XCTAssertFalse(entryExists(store, 1), "oldest unused entry evicted first")
        XCTAssertFalse(entryExists(store, 2))
    }

    func testWritesPastTheBudgetStayWithinIt() throws {
        let root = tempRoot()
        let store = try XCTUnwrap(JeffJSBytecodeDiskStore(root: root, name: "b", budgetBytes: 200_000))
        store.synchronize()
        for i in 0..<60 {
            XCTAssertTrue(store.write(UInt64(i), [UInt8](repeating: 1, count: 10_000)))
            // Never over the budget after a write returns (no async lag).
            var onDisk = 0
            for f in (try? FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])) ?? [] {
                onDisk += (try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
            }
            XCTAssertLessThanOrEqual(onDisk, 200_000, "after write \(i)")
        }
        store.synchronize()
        XCTAssertLessThanOrEqual(store.enforceBudget().bytes, 200_000)
        XCTAssertGreaterThan(store.evictedCount, 0)
        XCTAssertTrue(entryExists(store, 59), "the entry just written survives")
    }

    func testEntryOverAQuarterOfTheBudgetIsNotWritten() throws {
        let store = try XCTUnwrap(JeffJSBytecodeDiskStore(root: tempRoot(), name: "q", budgetBytes: 100_000))
        XCTAssertFalse(store.write(1, [UInt8](repeating: 0, count: 25_001)))
        XCTAssertFalse(entryExists(store, 1))
        XCTAssertTrue(store.write(2, [UInt8](repeating: 0, count: 24_000)))
    }

    // MARK: - Through the eval pipeline

    private func runtime(with store: JeffJSBytecodeDiskStore) -> (JeffJSRuntime, JeffJSContext) {
        let rt = JeffJSRuntime()
        rt.bytecodeCache.diskStore = store
        return (rt, rt.newContext())
    }

    /// A deserialize failure behind a valid header deletes the entry, and the
    /// next eval recompiles and rewrites it.
    func testCorruptEntryIsDeleted() throws {
        let store = try XCTUnwrap(JeffJSBytecodeDiskStore(root: tempRoot(), name: "c", budgetBytes: 1 << 24))
        let src = "function corruptProbe(a) { return a + 1 } corruptProbe(41)"
        let file = "corrupt-\(UUID().uuidString).js"
        let k = JeffJSBytecodeCache.key(source: src, filename: file, evalFlags: 0)
        let (_, ctx) = runtime(with: store)
        XCTAssertEqual(describe(ctx, ctx.eval(input: src, filename: file, evalFlags: 0)), "42")
        let url = store.url(for: k.hash)
        var bytes = [UInt8](try Data(contentsOf: url))
        let headerLen = 29 + k.desc.utf8.count
        XCTAssertGreaterThan(bytes.count, headerLen + 8)
        for i in headerLen..<(headerLen + 4) { bytes[i] ^= 0xFF }   // JFBC magic
        try Data(bytes).write(to: url)

        let (rt2, ctx2) = runtime(with: store)
        XCTAssertNil(rt2.bytecodeCache.lookup(k, ctx: ctx2))
        XCTAssertEqual(rt2.bytecodeCache.lastRejectReason, "disk deserialize failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "corrupt entry deleted")

        let (rt3, ctx3) = runtime(with: store)
        XCTAssertEqual(describe(ctx3, ctx3.eval(input: src, filename: file, evalFlags: 0)), "42")
        XCTAssertEqual(rt3.bytecodeCache.storeCount, 1, "recompiled and rewritten")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// A script whose top-level bytecode is over the old 1 MB cap is cached
    /// and a fresh runtime runs it from disk.
    func testLargeTopLevelScriptIsCached() throws {
        let store = try XCTUnwrap(JeffJSBytecodeDiskStore(root: tempRoot(), name: "l", budgetBytes: 1 << 28))
        var src = "var acc = 0;\n"
        for i in 0..<60_000 { src += "acc = (acc + \(i % 97)) | 0; var v\(i) = acc;\n" }
        src += "acc"
        let file = "large-\(UUID().uuidString).js"
        let (rt, ctx) = runtime(with: store)
        let expected = describe(ctx, ctx.eval(input: src, filename: file, evalFlags: 0))
        XCTAssertFalse(expected.hasPrefix("!"), expected)
        XCTAssertGreaterThan(ctx.lastBytecodeSize, 1_000_000, "top level over the old cap")
        XCTAssertEqual(rt.bytecodeCache.storeCount, 1)
        XCTAssertEqual(rt.bytecodeCache.storeSkipCount, 0)

        let (rt2, ctx2) = runtime(with: store)
        XCTAssertEqual(describe(ctx2, ctx2.eval(input: src, filename: file, evalFlags: 0)), expected)
        XCTAssertEqual(rt2.bytecodeCache.diskHitCount, 1)
    }

    /// The memory tier never holds more than its budget.
    func testMemoryTierIsByteBudgeted() throws {
        let store = try XCTUnwrap(JeffJSBytecodeDiskStore(root: tempRoot(), name: "m", budgetBytes: 1 << 26))
        let (rt, ctx) = runtime(with: store)
        rt.bytecodeCache.memoryBudget = 64 * 1024
        for i in 0..<200 {
            var src = "var s\(i) = [\n"
            for j in 0..<200 { src += "\"m\(i)x\(j)\",\n" }
            src += "]; s\(i).length"
            _ = ctx.eval(input: src, filename: "mem-\(i).js", evalFlags: 0)
        }
        XCTAssertLessThanOrEqual(rt.bytecodeCache.memoryTierBytes, 64 * 1024)
        XCTAssertGreaterThan(rt.bytecodeCache.memoryTierBytes, 0)
        // The newest script is still a memory hit; the first was evicted to disk.
        let hits = rt.bytecodeCache.hitCount, disk = rt.bytecodeCache.diskHitCount
        var last = "var s199 = [\n"
        for j in 0..<200 { last += "\"m199x\(j)\",\n" }
        last += "]; s199.length"
        XCTAssertEqual(describe(ctx, ctx.eval(input: last, filename: "mem-199.js", evalFlags: 0)), "200")
        XCTAssertEqual(rt.bytecodeCache.hitCount, hits + 1)
        XCTAssertEqual(rt.bytecodeCache.diskHitCount, disk, "memory hit")
        XCTAssertEqual(rt.bytecodeCache.storeCount, 200)
    }

    // MARK: - Cost: disk hit vs recompile

    /// A multi-MB bundle must load from the cache much faster than it
    /// compiles. `JEFFJS_BC_BENCH_FILE=<js>` benchmarks a real bundle (e.g.
    /// homedepot's 3.7 MB HomepageMetadataContainer); otherwise a synthetic
    /// ~2 MB one.
    func testDiskHitBeatsRecompileOnALargeBundle() throws {
        let src: String
        if let path = ProcessInfo.processInfo.environment["JEFFJS_BC_BENCH_FILE"] {
            src = try String(contentsOfFile: path, encoding: .utf8)
        } else {
            var s = ""
            for i in 0..<2500 {
                s += """
                (function () {
                    function rec\(i)(n) { return n <= 0 ? \(i) : rec\(i)(n - 1); }
                    class Base\(i) { constructor(x) { this.tag\(i) = "b\(i)" + x; } get t() { return this.tag\(i); } }
                    var obj\(i) = { tag: "t\(i)", list: [1, 2, 3, "\(i)"], go: function (n) { return rec\(i)(n) + this.list.length; } };
                    globalThis.p\(i) = function () { return new Base\(i)(obj\(i).go(2)).t; };
                })();

                """
            }
            src = s
        }
        let store = try XCTUnwrap(JeffJSBytecodeDiskStore(root: tempRoot(), name: "bench", budgetBytes: 1 << 30))
        let file = "bench-\(UUID().uuidString).js"
        let k = JeffJSBytecodeCache.key(source: src, filename: file, evalFlags: 0)

        let (rt, ctx) = runtime(with: store)
        _ = ctx.eval(input: src, filename: file, evalFlags: 0)
        let compileMs = rt.bytecodeCache.compileMs
        XCTAssertEqual(rt.bytecodeCache.storeCount, 1, "bundle was cached")

        var hitMs = Double.infinity
        for _ in 0..<3 {
            let (rt2, ctx2) = runtime(with: store)
            let t0 = CFAbsoluteTimeGetCurrent()
            let fb = rt2.bytecodeCache.lookup(k, ctx: ctx2)
            hitMs = min(hitMs, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            XCTAssertNotNil(fb)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: store.url(for: k.hash).path)[.size] as? Int) ?? 0
        print("[bccache-bench] source=\(src.utf8.count) bytes entry=\(size) bytes compile=\(Int(compileMs)) ms "
              + "serialize=\(Int(rt.bytecodeCache.serializeMs)) ms disk-hit=\(Int(hitMs)) ms")
        XCTAssertLessThan(hitMs, compileMs / 2, "a disk hit must clearly beat recompiling")
    }
}
