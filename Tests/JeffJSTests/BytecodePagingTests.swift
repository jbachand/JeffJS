// BytecodePagingTests.swift
// JeffJS — code and its immutable companions out of the JS heap
// (perf/bytecode-paging): cache entries are used from read-only file
// mappings, script text lives in the entry's mapping (lazy compiles parse
// straight out of it), and a mapping stays valid exactly as long as something
// uses it.
//
//   swift test --filter BytecodePagingTests

import XCTest
@testable import JeffJS

final class BytecodePagingTests: XCTestCase {

    private var tmpRoots: [URL] = []

    private func tempStore(_ name: String) throws -> JeffJSBytecodeDiskStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jfbc-paging-\(UUID().uuidString)", isDirectory: true)
        tmpRoots.append(url)
        return try XCTUnwrap(JeffJSBytecodeDiskStore(root: url, name: name, budgetBytes: 1 << 28))
    }

    override func tearDown() {
        for r in tmpRoots { try? FileManager.default.removeItem(at: r) }
        tmpRoots.removeAll()
        super.tearDown()
    }

    private func runtime(_ store: JeffJSBytecodeDiskStore?) -> (JeffJSRuntime, JeffJSContext) {
        let rt = JeffJSRuntime()
        rt.bytecodeCache.diskStore = store
        return (rt, rt.newContext())
    }

    private func describe(_ ctx: JeffJSContext, _ v: JeffJSValue) -> String {
        if v.isException { return "!exception: " + (ctx.toSwiftString(ctx.rt.currentException) ?? "?") }
        return ctx.toSwiftString(v) ?? "!unstringifiable"
    }

    private func eval(_ ctx: JeffJSContext, _ src: String, _ file: String) -> String {
        let v = ctx.eval(input: src, filename: file, evalFlags: 0)
        defer { v.freeValue() }
        return describe(ctx, v)
    }

    private func global(_ ctx: JeffJSContext, _ name: String) -> JeffJSFunctionBytecode? {
        let v = ctx.getPropertyStr(obj: ctx.globalObj, name: name)
        defer { v.freeValue() }
        guard let o = v.toObject() else { return nil }
        if let fb = o.fbFast { return fb }
        if case .bytecodeFunc(let fb, _, _) = o.payload { return fb }
        return nil
    }

    /// A script with lazy functions (bodies compile on the first call, from
    /// the script text) and a `toString` that reads that text.
    private let script = """
        function lazyAdd(a, b) { return a + b + /* pad */ 0; }
        function lazyName() { return 'name:' + lazyAdd.name; }
        var later = function (x) { var o = { k: x }; return o.k * 2; };
        function src() { return lazyAdd.toString(); }
        'loaded'
        """
    private let file = "paging-script.js"

    private func entryURL(_ store: JeffJSBytecodeDiskStore) -> URL {
        store.url(for: JeffJSBytecodeCache.key(source: script, filename: file, evalFlags: 0).hash)
    }

    /// A cache hit keeps the script text in the entry's mapping; lazy
    /// functions compile out of it and `toString` reads it.
    func testCacheHitTextIsMapped() throws {
        let store = try tempStore("hit")
        let (_, ctx1) = runtime(store)
        XCTAssertEqual(eval(ctx1, script, file), "loaded")
        JeffJSBytecodeCache.flushPendingDiskWrites()

        let (_, ctx2) = runtime(store)
        XCTAssertEqual(eval(ctx2, script, file), "loaded")
        let fb = try XCTUnwrap(global(ctx2, "lazyAdd"))
        let text = try XCTUnwrap(fb.sourceText)
        XCTAssertEqual(text.isMapped, JeffJSConfig.compileMappedSource && JeffJSBytecodeCache.mappedMode)
        XCTAssertEqual(eval(ctx2, "lazyAdd(2, 3) + '|' + lazyName() + '|' + later(21)", "<probe>"), "5|name:lazyAdd|42")
        XCTAssertEqual(eval(ctx2, "src()", "<probe>"), "function lazyAdd(a, b) { return a + b + /* pad */ 0; }")
    }

    /// After a fresh compile's entry lands on disk, the live script's text
    /// moves from the heap to the entry's mapping; everything still works.
    func testFreshCompileTextMovesToTheMapping() throws {
        guard JeffJSConfig.compileMappedSource, JeffJSBytecodeCache.mappedMode else { return }
        let store = try tempStore("fresh")
        let (rt, ctx) = runtime(store)
        XCTAssertEqual(eval(ctx, script, file), "loaded")
        let fb = try XCTUnwrap(global(ctx, "lazyAdd"))
        let text = try XCTUnwrap(fb.sourceText)
        XCTAssertFalse(text.isMapped, "heap until the write lands")
        rt.bytecodeCache.flushLazyBodies()   // drains writes, adopts the mappings
        XCTAssertTrue(text.isMapped)
        XCTAssertEqual(rt.bytecodeCache.sourcesMapped, 1)
        XCTAssertEqual(rt.bytecodeCache.pendingSourceSwapCount, 0)
        XCTAssertEqual(eval(ctx, "lazyAdd(2, 3) + '|' + later(4) + '|' + src().length", "<probe>"), "5|8|54")
    }

    /// Mapping lifetime: the entry file deleted and the cache's own mappings
    /// dropped (eviction, `clear`) while a live script still uses the text —
    /// the script's spans pin the mapping; lazy compiles and `toString` keep
    /// working, nothing is unmapped under them.
    func testEvictedEntryStaysMappedWhileUsed() throws {
        let store = try tempStore("evict")
        let (_, ctx1) = runtime(store)
        XCTAssertEqual(eval(ctx1, script, file), "loaded")
        JeffJSBytecodeCache.flushPendingDiskWrites()

        let (rt2, ctx2) = runtime(store)
        XCTAssertEqual(eval(ctx2, script, file), "loaded")
        let liveBefore = JeffJSFileMapping.liveStats.count
        // Evict everything the cache holds and delete the files.
        rt2.bytecodeCache.mappedEntryCap = 0
        rt2.bytecodeCache.clear()
        try? FileManager.default.removeItem(at: entryURL(store))
        store.remove(JeffJSBytecodeCache.key(source: script, filename: file, evalFlags: 0).hash)
        if JeffJSConfig.compileMappedSource && JeffJSBytecodeCache.mappedMode {
            XCTAssertGreaterThanOrEqual(JeffJSFileMapping.liveStats.count, 1, "pinned by the live script")
            XCTAssertLessThanOrEqual(JeffJSFileMapping.liveStats.count, liveBefore)
        }
        // First calls compile from the (unlinked, still mapped) text.
        XCTAssertEqual(eval(ctx2, "lazyAdd(20, 22) + '|' + lazyName() + '|' + later(1)", "<probe>"), "42|name:lazyAdd|2")
        XCTAssertEqual(eval(ctx2, "src().indexOf('pad') > 0", "<probe>"), "true")
        // Idle reclaim drops compiled bodies; the recompile parses the mapping again.
        _ = rt2.reclaimLazyBodiesNow(aggressive: true)
        XCTAssertEqual(eval(ctx2, "lazyAdd(1, 1) + later(5)", "<probe>"), "12")
    }

    /// A span keeps its mapping alive after every other holder is gone (a
    /// parse that copied the span while the text was being swapped).
    func testSpanPinsItsMapping() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jfbc-pin-\(UUID().uuidString)")
        tmpRoots.append(dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("f.bin").path
        let payload = (0 ..< 100_000).map { UInt8(truncatingIfNeeded: $0 * 7) }
        try Data(payload).write(to: URL(fileURLWithPath: path))
        let before = JeffJSFileMapping.liveStats.count
        var span: JeffJSBytesSpan? = {
            let m = JeffJSFileMapping(path: path)!
            return JeffJSBytesSpan(m, offset: 1000, count: 5000)
        }()
        XCTAssertEqual(JeffJSFileMapping.liveStats.count, before + 1)
        try FileManager.default.removeItem(atPath: path)                   // unlinked: still mapped
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: path))         // a new file at the path
        XCTAssertEqual(span![0], payload[1000])
        XCTAssertEqual(span![4999], payload[5999])
        XCTAssertEqual(span![5000], 0, "past the end reads the terminator, never the mapping")
        XCTAssertTrue(span!.isFileBacked)
        let text = JeffJSSourceText(span: span!)
        span = nil
        XCTAssertEqual(JeffJSFileMapping.liveStats.count, before + 1, "the text pins it")
        XCTAssertEqual(text.bytes[1], payload[1001])
        _ = text.adoptMapping(JeffJSBytesSpan(copying: Array(payload[1000 ..< 6000])))
        XCTAssertFalse(text.isMapped)
        XCTAssertEqual(JeffJSFileMapping.liveStats.count, before, "unmapped once nothing uses it")
        XCTAssertFalse(text.adoptMapping(JeffJSBytesSpan(copying: [1, 2, 3])), "different bytes are refused")
    }

    /// Invalidation: an entry from another key / compiler is refused and
    /// deleted as before (the mapped path validates the same header), and a
    /// changed script recompiles.
    func testChangedScriptAndCorruptMappedEntryRecompile() throws {
        let store = try tempStore("inval")
        let (_, ctx1) = runtime(store)
        XCTAssertEqual(eval(ctx1, script, file), "loaded")
        JeffJSBytecodeCache.flushPendingDiskWrites()
        // Corrupt the blob's magic behind a valid header.
        let k = JeffJSBytecodeCache.key(source: script, filename: file, evalFlags: 0)
        var bytes = [UInt8](try Data(contentsOf: entryURL(store)))
        let headerLen = 29 + k.desc.utf8.count
        for i in headerLen ..< headerLen + 4 { bytes[i] ^= 0xFF }
        try Data(bytes).write(to: entryURL(store))
        let (rt2, ctx2) = runtime(store)
        XCTAssertEqual(eval(ctx2, script, file), "loaded")
        XCTAssertEqual(rt2.bytecodeCache.lastRejectReason, "disk deserialize failed")
        XCTAssertEqual(rt2.bytecodeCache.storeCount, 1, "recompiled")
        XCTAssertEqual(eval(ctx2, "lazyAdd(1, 2)", "<probe>"), "3")
        // A different script under the same name is a different key.
        let (rt3, ctx3) = runtime(store)
        XCTAssertEqual(eval(ctx3, script + ";'v2'", file), "v2")
        XCTAssertEqual(rt3.bytecodeCache.diskHitCount, 0)
    }

    /// Round trip through a mapped entry and its sidecar: functions compiled
    /// on first call in one runtime are read back (mapped) in the next, with
    /// identical results; the serialized blob of a mapped load equals the
    /// original (format unchanged).
    func testMappedRoundTripAndSidecarBodies() throws {
        let store = try tempStore("rt")
        let (rt1, ctx1) = runtime(store)
        XCTAssertEqual(eval(ctx1, script, file), "loaded")
        let probe = "lazyAdd(2, 3) + '|' + lazyName() + '|' + later(21)"
        XCTAssertEqual(eval(ctx1, probe, "<probe>"), "5|name:lazyAdd|42")
        rt1.bytecodeCache.flushLazyBodies()

        let (rt2, ctx2) = runtime(store)
        let k = JeffJSBytecodeCache.key(source: script, filename: file, evalFlags: 0)
        let fb = try XCTUnwrap(rt2.bytecodeCache.lookup(k, ctx: ctx2))
        let reserialized = JeffJSBytecodeSerializer.serialize(fb, rt: rt2)
        let fileBytes = [UInt8](try Data(contentsOf: entryURL(store)))
        let headerLen = 29 + k.desc.utf8.count
        XCTAssertEqual(reserialized, Array(fileBytes[headerLen...]), "mapped load re-serializes byte-identically")
        XCTAssertEqual(eval(ctx2, script, file), "loaded")
        XCTAssertEqual(eval(ctx2, probe, "<probe>"), "5|name:lazyAdd|42")
        XCTAssertGreaterThanOrEqual(rt2.lazyStats.bodyCacheHits, 2, "bodies read from the mapped sidecar")
    }
}
