// BytecodeCacheLazyTests.swift
// JeffJS — bytecode cache round trips of lazily compiled functions
// (the cache half of the "LazyCompile" group, see LazyCompileConformance).
//
// A script compiled with lazy functions is cached as its top level plus
// stubs (closure variables, seed, source span; no body) and the script text
// once. A fresh runtime — with a different atom numbering — must run the
// stubs from that blob exactly like the source. Bodies compiled on a first
// call are appended to a sidecar next to the entry (JeffJSLazyBodyStore) and
// a later runtime reads them back instead of compiling.
//
//   swift test -c release --filter BytecodeCacheLazy

import XCTest
@testable import JeffJS

final class BytecodeCacheLazyTests: XCTestCase {

    private let atomShift = 500
    private var tmpRoots: [URL] = []

    private func tempStore(_ name: String) throws -> JeffJSBytecodeDiskStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jfbc-lazy-\(UUID().uuidString)", isDirectory: true)
        tmpRoots.append(url)
        return try XCTUnwrap(JeffJSBytecodeDiskStore(root: url, name: name, budgetBytes: 1 << 28))
    }

    override func tearDown() {
        for r in tmpRoots { try? FileManager.default.removeItem(at: r) }
        tmpRoots.removeAll()
        super.tearDown()
    }

    private func describe(_ ctx: JeffJSContext, _ v: JeffJSValue) -> String {
        if v.isException { return "!exception: " + (ctx.toSwiftString(ctx.rt.currentException) ?? "?") }
        return ctx.toSwiftString(v) ?? "!unstringifiable"
    }

    /// Compile like nativeEvalPipeline (lazy functions on).
    private func compile(_ src: String, ctx: JeffJSContext, filename: String) -> JeffJSFunctionBytecode? {
        let parseState = JeffJSParseState(source: src, filename: filename, ctx: ctx)
        parseState.allowHTMLComments = true
        let fd = JeffJSFunctionDefCompiler()
        fd.filename = ctx.rt.findAtom(filename)
        fd.source = src
        fd.sourceText = JeffJSSourceText(bytes: parseState.buf)
        fd.sourceStart = 0
        fd.sourceEnd = parseState.buf.count
        fd.lazyScript = JeffJSLazyScript(source: fd.sourceText!, filename: filename, isModule: false)
        let parser = JeffJSParser(s: parseState, fd: fd)
        parser.parseProgram()
        if parser.hasError || fd.byteCode.error { return nil }
        return JeffJSCompiler.createFunction(ctx: ctx, fd: fd)
    }

    private func countStubs(_ fb: JeffJSFunctionBytecode) -> (pending: Int, all: Int) {
        var pending = fb.isLazyPending ? 1 : 0
        var all = fb.lazyInfo != nil ? 1 : 0
        for v in fb.cpool {
            if let c = v.toFunctionBytecode() {
                let n = countStubs(c)
                pending += n.pending
                all += n.all
            }
        }
        return (pending, all)
    }

    /// Scripts whose functions are all stubs at load (the LazyCompile cases
    /// that do not need a DOM, plus a few shapes of their own).
    private var scripts: [String] {
        var out = JeffJSTestRunner.lazyCompileCases.map { $0.1 }
        out.append("""
            var log = [];
            function outer(a) { var b = a * 2; function mid() { let c = b + 1; return () => a + b + c; } return mid; }
            class K { #p = 3; static s(x) { return x + 1; } get v() { return this.#p; } m(q = () => this.#p) { return q(); } }
            var o = { async am() { return 1; }, *gen() { yield 1; yield 2; }, get g() { return 5; } };
            log.push(outer(1)()(), K.s(1), new K().v, new K().m(), [...o.gen()].join(), o.g, outer.toString().length);
            log.join('|')
            """)
        return out
    }

    /// Stubs survive serialize -> deserialize into a runtime with different
    /// atom numbering and compile there on their first call.
    func testLazyStubsRoundTrip() throws {
        var checked = 0
        for src in scripts {
            let rt1 = JeffJSRuntime()
            let ctx1 = rt1.newContext()
            rt1.bytecodeCache.diskStore = nil
            let expected = describe(ctx1, ctx1.eval(input: src, filename: "<eval>-lazy-text", evalFlags: 0))

            let rtW = JeffJSRuntime()
            let ctxW = JeffJSContext(rt: rtW)
            guard let fb = compile(src, ctx: ctxW, filename: "<lazy-blob>") else {
                XCTFail("compile failed: \(src.prefix(80))")
                continue
            }
            let bytes = JeffJSBytecodeSerializer.serialize(fb, rt: rtW)

            let rt2 = JeffJSRuntime()
            rt2.bytecodeCache.diskStore = nil
            let ctx2 = rt2.newContext()
            for i in 0 ..< atomShift { _ = rt2.findAtom("__lzShift\(i)") }
            let back = try XCTUnwrap(JeffJSBytecodeDeserializer.deserialize(bytes, rt: rt2, ctx: ctx2))
            let before = countStubs(fb), after = countStubs(back)
            XCTAssertEqual(before.pending, after.pending, "stubs survive the round trip")
            if before.pending > 0 { checked += 1 }
            let got = describe(ctx2, ctx2.evalPrecompiled(bytes))
            XCTAssertEqual(got, expected, "source vs cached stubs: \(src.prefix(120))")
            _ = after
        }
        XCTAssertGreaterThan(checked, 40, "the scripts had stubs")
    }

    /// The pipeline: a miss compiles lazily and stores stubs; the bodies that
    /// ran are appended to the sidecar; a fresh runtime hits the entry and
    /// reads every body back (no compile from source); results agree.
    func testLazyBodiesPersistNextToTheEntry() throws {
        let store = try tempStore("bodies")
        let src = scripts.last!
        let file = "lazy-bodies-\(UUID().uuidString).js"
        let key = JeffJSBytecodeCache.key(source: src, filename: file, evalFlags: 0)

        let rt1 = JeffJSRuntime()
        rt1.bytecodeCache.diskStore = store
        let ctx1 = rt1.newContext()
        let s1 = rt1.lazyStats
        let expected = describe(ctx1, ctx1.eval(input: src, filename: file, evalFlags: 0))
        XCTAssertFalse(expected.hasPrefix("!"), expected)
        let compiled1 = rt1.lazyStats.compiled - s1.compiled
        XCTAssertGreaterThan(rt1.lazyStats.stubs - s1.stubs, 0)
        XCTAssertGreaterThan(compiled1, 5)
        XCTAssertEqual(rt1.lazyStats.bodyCacheHits - s1.bodyCacheHits, 0)
        rt1.bytecodeCache.flushLazyBodies()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.sidecarURL(for: key.hash).path))

        let rt2 = JeffJSRuntime()
        rt2.bytecodeCache.diskStore = store
        let ctx2 = rt2.newContext()
        for i in 0 ..< atomShift { _ = rt2.findAtom("__lzShift\(i)") }
        let s2 = rt2.lazyStats
        let hits2 = rt2.bytecodeCache.diskHitCount
        XCTAssertEqual(describe(ctx2, ctx2.eval(input: src, filename: file, evalFlags: 0)), expected)
        XCTAssertEqual(rt2.bytecodeCache.diskHitCount - hits2, 1)
        XCTAssertEqual(rt2.lazyStats.stubs - s2.stubs, 0)
        XCTAssertEqual(rt2.lazyStats.compiled - s2.compiled, compiled1, "the same functions ran")
        XCTAssertEqual(rt2.lazyStats.bodyCacheHits - s2.bodyCacheHits, compiled1, "every body came from the sidecar")

        // A torn or corrupt sidecar only costs compiles.
        let url = store.sidecarURL(for: key.hash)
        var bytes = [UInt8](try Data(contentsOf: url))
        for i in stride(from: 40, to: bytes.count, by: 7) { bytes[i] ^= 0x5A }
        try Data(bytes.prefix(bytes.count - 3)).write(to: url)
        let rt3 = JeffJSRuntime()
        rt3.bytecodeCache.diskStore = store
        let ctx3 = rt3.newContext()
        XCTAssertEqual(describe(ctx3, ctx3.eval(input: src, filename: file, evalFlags: 0)), expected)

        // No sidecar at all.
        try FileManager.default.removeItem(at: url)
        let rt4 = JeffJSRuntime()
        rt4.bytecodeCache.diskStore = store
        let ctx4 = rt4.newContext()
        let s4 = rt4.lazyStats
        XCTAssertEqual(describe(ctx4, ctx4.eval(input: src, filename: file, evalFlags: 0)), expected)
        XCTAssertEqual(rt4.lazyStats.bodyCacheHits - s4.bodyCacheHits, 0)
        XCTAssertEqual(rt4.lazyStats.compiled - s4.compiled, compiled1)
    }

    /// Stubs make the cache entry of a function-heavy script much smaller
    /// than the eagerly compiled one (the script text is stored once).
    func testLazyEntryIsSmallerThanEager() throws {
        var src = "var api = {};\n"
        for i in 0 ..< 400 {
            src += "api.f\(i) = function (a, b) { var s = 0; for (var k = 0; k < a; k++) { s += k * b + \(i); if (s > 1e6) { s = s % 97; } } return { s: s, t: typeof a, n: 'f\(i)' }; };\n"
        }
        src += "api.f7(3, 4).s"
        let rtL = JeffJSRuntime()
        let ctxL = JeffJSContext(rt: rtL)
        let lazy = try XCTUnwrap(compile(src, ctx: ctxL, filename: "size.js"))
        let lazyBytes = JeffJSBytecodeSerializer.serialize(lazy, rt: rtL).count
        let rtE = JeffJSRuntime()
        rtE.lazyFunctions = false
        let ctxE = JeffJSContext(rt: rtE)
        let eager = try XCTUnwrap(compile(src, ctx: ctxE, filename: "size.js"))
        let eagerBytes = JeffJSBytecodeSerializer.serialize(eager, rt: rtE).count
        print("[lazy-cache] entry \(eagerBytes) -> \(lazyBytes) bytes (source \(src.utf8.count))")
        XCTAssertEqual(countStubs(lazy).pending, 400)
        XCTAssertLessThan(Double(lazyBytes), Double(eagerBytes) * 0.75)
    }
}
