// BytecodeCacheKeyTests.swift
// JeffJS — "BytecodeCacheKey" group.
//
// The on-disk (and in-memory) bytecode cache used to be keyed by the source
// text alone. Byte-identical source compiled two different ways — script vs
// module, strict vs sloppy, one filename vs another — shared a single blob,
// and whichever compile ran first won. These tests pin down the fields that
// must separate two compiles, the fields that must not, and the header check
// that refuses a stale entry instead of executing it.
//
//   swift test -c release --filter BytecodeCacheKey

import XCTest
@testable import JeffJS

final class BytecodeCacheKeyTests: XCTestCase {

    /// Unique per test-process run, so a test never inherits a blob written by
    /// an earlier run of itself (the disk cache lives in ~/Library/Caches).
    private static let tag = "k\(UInt32.random(in: 1_000_000...4_000_000_000))"

    private func key(_ source: String, _ filename: String, _ flags: Int) -> JeffJSBytecodeCacheKey {
        JeffJSBytecodeCache.key(source: source, filename: filename, evalFlags: flags)
    }

    private func describe(_ ctx: JeffJSContext, _ v: JeffJSValue) -> String {
        if v.isException {
            return "!exception: " + (ctx.toSwiftString(ctx.rt.currentException) ?? "?")
        }
        return ctx.toSwiftString(v) ?? "!unstringifiable"
    }

    /// Evaluate in a brand-new runtime.
    private func evalFresh(_ source: String, filename: String, flags: Int) -> String {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        return describe(ctx, ctx.eval(input: source, filename: filename, evalFlags: flags))
    }

    // MARK: - The key itself

    func testKeySeparatesEveryCompileInput() {
        let src = "var a = 1; a + 1;"
        let base = key(src, "page.js", JS_EVAL_TYPE_GLOBAL)

        // Same compile, same key — otherwise nothing is ever cached.
        XCTAssertEqual(base.hash, key(src, "page.js", JS_EVAL_TYPE_GLOBAL).hash)
        XCTAssertEqual(base.desc, key(src, "page.js", JS_EVAL_TYPE_GLOBAL).desc)
        XCTAssertEqual(base.sourceLength, src.utf8.count)

        // Every one of these changes the bytes or the behaviour.
        XCTAssertNotEqual(base.hash, key(src, "other.js", JS_EVAL_TYPE_GLOBAL).hash,
                          "filename is written into the blob and read back by buildStackTrace")
        XCTAssertNotEqual(base.hash, key(src, "page.js", JS_EVAL_TYPE_MODULE).hash,
                          "module vs script")
        XCTAssertNotEqual(base.hash, key(src, "page.js", JS_EVAL_TYPE_DIRECT).hash,
                          "direct vs indirect eval")
        XCTAssertNotEqual(base.hash, key(src, "page.js", JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_STRICT).hash,
                          "strict vs sloppy")
        XCTAssertNotEqual(base.hash, key(src, "page.js", JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_BACKTRACE_BARRIER).hash,
                          "backtrace barrier")
        XCTAssertNotEqual(base.hash, key(src, "page.js", JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_ASYNC).hash)
        XCTAssertNotEqual(base.hash, key(src, "page.js", JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY).hash)
        XCTAssertNotEqual(base.hash, key(src + " ", "page.js", JS_EVAL_TYPE_GLOBAL).hash)

        // The desc must name the compiler version and the codegen toggles, so
        // a differently-configured build's entry is refused by the header check
        // even if the hash collides.
        XCTAssertTrue(base.desc.contains("cv=\(JeffJSBytecodeCache.compilerVersion)"), base.desc)
        XCTAssertTrue(base.desc.contains("opt="), base.desc)
        XCTAssertTrue(base.desc.contains("short="), base.desc)
        XCTAssertTrue(base.desc.contains("mlv="), base.desc)
        XCTAssertTrue(base.desc.contains("mss="), base.desc)
        XCTAssertTrue(base.desc.contains("fn=page.js"), base.desc)
        XCTAssertFalse(base.desc.utf8.contains(0), "desc must not contain the hash separator byte")
    }

    // MARK: - Strict vs sloppy, end to end

    /// Probes whose answer depends on the mode the source was compiled in.
    private var modeProbes: [(String, String)] {
        [
            ("this", "(function () { return this === undefined ? 'undefined-this' : 'global-this'; })()"),
            ("delete-unqualified", "var r; try { r = delete Object; } catch (e) { r = 'threw'; } String(r)"),
            ("implicit-global", "try { bccUndeclaredProbe = 1; 'assigned' } catch (e) { 'threw' }"),
        ]
    }

    func testStrictAndSloppyNeverShareABlob() {
        var sawADifference = false
        for (name, body) in modeProbes {
            // Distinct source per probe so probes cannot collide with each other.
            let src = "/*\(Self.tag)-\(name)*/\n" + body
            let file = "mode-\(name).js"

            // Ground truth: each mode measured in its own fresh runtime.
            let sloppy = evalFresh(src, filename: file, flags: JS_EVAL_TYPE_GLOBAL)
            let strict = evalFresh(src, filename: file, flags: JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_STRICT)
            if sloppy != strict { sawADifference = true }

            // Now both orders, in one runtime, through the cache. Whichever
            // compile ran first must not change what the second one sees.
            let rtA = JeffJSRuntime(), ctxA = rtA.newContext()
            let a1 = describe(ctxA, ctxA.eval(input: src, filename: file, evalFlags: JS_EVAL_TYPE_GLOBAL))
            let a2 = describe(ctxA, ctxA.eval(input: src, filename: file,
                                              evalFlags: JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_STRICT))
            let rtB = JeffJSRuntime(), ctxB = rtB.newContext()
            let b1 = describe(ctxB, ctxB.eval(input: src, filename: file,
                                              evalFlags: JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_STRICT))
            let b2 = describe(ctxB, ctxB.eval(input: src, filename: file, evalFlags: JS_EVAL_TYPE_GLOBAL))

            XCTAssertEqual(a1, sloppy, "\(name): sloppy-first sloppy result")
            XCTAssertEqual(a2, strict, "\(name): strict after a cached sloppy compile")
            XCTAssertEqual(b1, strict, "\(name): strict-first strict result")
            XCTAssertEqual(b2, sloppy, "\(name): sloppy after a cached strict compile")
        }
        XCTAssertTrue(sawADifference,
                      "no probe distinguished strict from sloppy — the test would pass vacuously")
    }

    // MARK: - Filename

    func testFilenameIsPartOfTheKey() {
        // Identical source, two filenames. The filename travels inside the
        // blob, so a source-only key hands the second page the first page's
        // stack frames.
        let src = "/*\(Self.tag)*/\nfunction probe() { return null.x } try { probe() } catch (e) { e.stack }"
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        let alpha = describe(ctx, ctx.eval(input: src, filename: "alpha-\(Self.tag).js", evalFlags: 0))
        let beta = describe(ctx, ctx.eval(input: src, filename: "beta-\(Self.tag).js", evalFlags: 0))
        XCTAssertTrue(alpha.contains("alpha-\(Self.tag).js"), "alpha stack: \(alpha)")
        XCTAssertTrue(beta.contains("beta-\(Self.tag).js"), "beta stack: \(beta)")
        XCTAssertFalse(beta.contains("alpha-\(Self.tag).js"), "beta got alpha's blob: \(beta)")
    }

    // MARK: - Sharing when nothing differs

    func testIdenticalCompilesShareOneBlob() {
        let src = "/*\(Self.tag)*/\nfunction shareProbe(a) { return a * 3 } shareProbe(14)"
        let file = "share-\(Self.tag).js"

        // Same runtime, twice: the second eval is an in-memory hit.
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        XCTAssertEqual(describe(ctx, ctx.eval(input: src, filename: file, evalFlags: 0)), "42")
        let hitsBefore = rt.bytecodeCache.hitCount
        XCTAssertEqual(describe(ctx, ctx.eval(input: src, filename: file, evalFlags: 0)), "42")
        XCTAssertEqual(rt.bytecodeCache.hitCount, hitsBefore + 1, "second identical eval must hit")

        // A fresh runtime picks the same blob up off disk.
        let rt2 = JeffJSRuntime()
        let ctx2 = rt2.newContext()
        XCTAssertEqual(describe(ctx2, ctx2.eval(input: src, filename: file, evalFlags: 0)), "42")
        XCTAssertGreaterThanOrEqual(rt2.bytecodeCache.diskHitCount, 1, "cross-runtime disk hit")
    }

    // MARK: - Header rejection

    func testEntryFromADifferentCompilerVersionIsRejected() {
        let src = "/*\(Self.tag)*/\nvar cvProbe = 1; cvProbe + 41;"
        let file = "cv-\(Self.tag).js"
        let k = key(src, file, 0)

        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        XCTAssertEqual(describe(ctx, ctx.eval(input: src, filename: file, evalFlags: 0)), "42")

        guard let url = rt.bytecodeCache.diskEntryURL(for: k),
              let data = try? Data(contentsOf: url) else {
            XCTFail("store did not write a disk entry")
            return
        }
        var bytes = [UInt8](data)
        XCTAssertGreaterThan(bytes.count, 32)
        // Header is: u32 magic | u8 version | u64 compilerVersion | ...
        bytes[5] ^= 0xFF
        try? Data(bytes).write(to: url, options: .atomic)

        let rt2 = JeffJSRuntime()
        let ctx2 = rt2.newContext()
        XCTAssertNil(rt2.bytecodeCache.lookup(k, ctx: ctx2))
        XCTAssertEqual(rt2.bytecodeCache.lastRejectReason, "disk compilerVersion mismatch")
        XCTAssertEqual(rt2.bytecodeCache.rejectCount, 1)
    }

    func testEntryHeaderCatchesAKeyThatOnlyLooksTheSame() {
        let k = key("var q = 1;", "hdr-\(Self.tag).js", 0)
        let other = key("var q = 1;", "hdr-\(Self.tag).js", JS_EVAL_FLAG_STRICT)
        let blob: [UInt8] = [1, 2, 3, 4, 5]
        let entry = JeffJSBytecodeCache.makeEntry(key: k, blob: blob)

        switch JeffJSBytecodeCache.openEntry(entry, key: k) {
        case .ok(let b): XCTAssertEqual(b, blob)
        case .refused(let r): XCTFail("round trip refused: \(r)")
        }
        // A different compile's key: caught by the hash field.
        if case .ok = JeffJSBytecodeCache.openEntry(entry, key: other) {
            XCTFail("an entry written for a different key was accepted")
        }
        // A forged hash still fails on the desc/source-length comparison.
        let forged = JeffJSBytecodeCacheKey(hash: k.hash, desc: other.desc,
                                            sourceLength: other.sourceLength)
        if case .ok = JeffJSBytecodeCache.openEntry(entry, key: forged) {
            XCTFail("a hash collision between two different compiles was accepted")
        }
        // Garbage, truncation, and a raw JFBC blob (no header) are all refused.
        if case .ok = JeffJSBytecodeCache.openEntry([0, 1, 2], key: k) {
            XCTFail("truncated entry accepted")
        }
        if case .ok = JeffJSBytecodeCache.openEntry(Array(entry.prefix(12)), key: k) {
            XCTFail("half a header accepted")
        }
    }

    // MARK: - In-memory cache uses the same key

    func testInMemoryCacheUsesTheSameKey() {
        let src = "/*\(Self.tag)*/\nvar memProbe = 7; memProbe;"
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        let k = key(src, "mem-\(Self.tag).js", 0)
        _ = ctx.eval(input: src, filename: "mem-\(Self.tag).js", evalFlags: 0)
        XCTAssertNotNil(rt.bytecodeCache.lookup(k, ctx: ctx), "stored key must be found in memory")

        // Same hash slot, different compile: the in-memory path must refuse it
        // exactly like the disk path does.
        let forged = JeffJSBytecodeCacheKey(hash: k.hash, desc: k.desc + ";x", sourceLength: k.sourceLength)
        XCTAssertNil(rt.bytecodeCache.lookup(forged, ctx: ctx))
        XCTAssertEqual(rt.bytecodeCache.lastRejectReason, "memory key mismatch")
    }

    // MARK: - Exclusion prefixes

    func testExcludedPrefixesAreStillNeverCached() {
        for prefix in ["<eval>", "<onclick>", "<diag>"] {
            XCTAssertTrue(JeffJSConfig.bytecodeExcludePrefixes.contains(prefix),
                          "\(prefix) dropped out of cache.bytecodeExcludePrefixes")
            let src = "/*\(Self.tag)-\(prefix)*/\n1 + 1"
            let rt = JeffJSRuntime()
            let ctx = rt.newContext()
            let hits = rt.bytecodeCache.hitCount
            let misses = rt.bytecodeCache.missCount
            _ = ctx.eval(input: src, filename: prefix, evalFlags: 0)
            _ = ctx.eval(input: src, filename: prefix, evalFlags: 0)
            XCTAssertEqual(rt.bytecodeCache.hitCount, hits, "\(prefix) was cached")
            XCTAssertEqual(rt.bytecodeCache.missCount, misses, "\(prefix) reached the cache at all")
        }
    }

    // MARK: - Concurrent writers

    func testConcurrentWritersLeaveAReadableEntry() {
        let k = key("/*\(Self.tag)*/\nvar concProbe = 1;", "conc-\(Self.tag).js", 0)
        guard let url = JeffJSBytecodeCache().diskEntryURL(for: k) else {
            XCTFail("no disk cache directory")
            return
        }
        // Two entries of different sizes for the same key slot, so a torn write
        // would leave a length the reader could detect.
        let small = JeffJSBytecodeCache.makeEntry(key: k, blob: [UInt8](repeating: 0xAB, count: 4_096))
        let large = JeffJSBytecodeCache.makeEntry(key: k, blob: [UInt8](repeating: 0xCD, count: 512_000))
        try? Data(small).write(to: url, options: .atomic)

        var torn = 0
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 32) { i in
            if i % 2 == 0 {
                try? Data(i % 4 == 0 ? small : large).write(to: url, options: .atomic)
            } else {
                guard let data = try? Data(contentsOf: url) else { return }
                if case .refused(let reason) = JeffJSBytecodeCache.openEntry([UInt8](data), key: k) {
                    lock.lock(); torn += 1; lock.unlock()
                    XCTFail("reader saw a partial entry: \(reason)")
                }
            }
        }
        XCTAssertEqual(torn, 0)
        try? FileManager.default.removeItem(at: url)
    }
}
