// PrecompilerTests.swift
// JeffJS — off-JS-thread compile into the bytecode cache (JeffJSPrecompiler,
// perf/bytecode-paging): a background thread compiles a script in a private
// runtime and writes the cache entry; the JS thread's eval maps it.
//
//   swift test --filter PrecompilerTests

import XCTest
@testable import JeffJS

final class PrecompilerTests: XCTestCase {

    private var tmpRoots: [URL] = []

    private func tempStore(_ name: String) throws -> JeffJSBytecodeDiskStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jfbc-pre-\(UUID().uuidString)", isDirectory: true)
        tmpRoots.append(url)
        return try XCTUnwrap(JeffJSBytecodeDiskStore(root: url, name: name, budgetBytes: 1 << 28))
    }

    override func tearDown() {
        for r in tmpRoots { try? FileManager.default.removeItem(at: r) }
        tmpRoots.removeAll()
        super.tearDown()
    }

    private func onBackground<T>(_ body: @escaping () -> T) -> T {
        var result: T? = nil
        let done = DispatchSemaphore(value: 0)
        let th = Thread { result = body(); done.signal() }
        th.stackSize = 16 << 20
        th.start()
        done.wait()
        return result!
    }

    private func describe(_ ctx: JeffJSContext, _ v: JeffJSValue) -> String {
        if v.isException { return "!exception: " + (ctx.toSwiftString(ctx.rt.currentException) ?? "?") }
        return ctx.toSwiftString(v) ?? "!unstringifiable"
    }

    private let script = """
        function tag(s, ...v) { return s.raw.join('|') + ':' + v.join(','); }
        var tpl = tag`a${1}b${2}c`;
        class Pt { constructor(x) { this.x = x; } get twice() { return this.x * 2; } }
        var big = 12345678901234567890n;
        function lazyOne(o) { return o.k + new Pt(o.k).twice; }
        var arrow = (a) => a.map(x => `<${x}>`).join('');
        [tpl, lazyOne({ k: 3 }), arrow([1, 2]), String(big % 97n)].join(' ')
        """

    /// A background precompile writes the entry the eval would have stored;
    /// the JS thread's eval is a disk hit and gives the same result.
    func testPrecompiledEntryIsUsedByTheEval() throws {
        let store = try tempStore("use")
        let file = "https://example.test/pre-\(UUID().uuidString).js"
        let outcome = onBackground { JeffJSPrecompiler.precompileScript(self.script, filename: file, evalFlags: 0, store: store) }
        guard case .compiled = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(onBackground { JeffJSPrecompiler.precompileScript(self.script, filename: file, evalFlags: 0, store: store) },
                       .alreadyCached)

        // Reference: a plain compile in a runtime without a cache.
        let ref = JeffJSRuntime(); ref.bytecodeCache.diskStore = nil
        let refCtx = ref.newContext()
        let expected = describe(refCtx, refCtx.eval(input: script, filename: file, evalFlags: 0))
        XCTAssertEqual(expected, "a|b|c:1,2 9 <1><2> \(UInt64(12345678901234567890) % 97)")

        let rt = JeffJSRuntime(); rt.bytecodeCache.diskStore = store
        let ctx = rt.newContext()
        XCTAssertEqual(describe(ctx, ctx.eval(input: script, filename: file, evalFlags: 0)), expected)
        XCTAssertEqual(rt.bytecodeCache.diskHitCount, 1)
        XCTAssertEqual(rt.bytecodeCache.storeCount, 0, "nothing compiled on the JS thread")
        // The blob is what the JS thread would have written.
        let k = JeffJSBytecodeCache.key(source: script, filename: file, evalFlags: 0)
        let fileBytes = [UInt8](try Data(contentsOf: store.url(for: k.hash)))
        let rt2 = JeffJSRuntime(); rt2.bytecodeCache.diskStore = nil
        let ctx2 = rt2.newContext()
        guard case .compiled(let fb) = ctx2.compileProgram(input: script, filename: file, evalFlags: 0, cacheHash: k.hash) else {
            return XCTFail("compile")
        }
        let blob = JeffJSBytecodeSerializer.serialize(fb, rt: rt2)
        XCTAssertEqual(Array(fileBytes[(29 + k.desc.utf8.count)...]), blob, "same blob as a JS-thread compile")
    }

    /// Syntax errors are left to the JS thread (it reports them as before);
    /// pseudo filenames and modules are not precompiled.
    func testErrorsAndSkips() throws {
        let store = try tempStore("skip")
        let bad = onBackground { JeffJSPrecompiler.precompileScript("var = ;", filename: "https://x.test/bad.js", evalFlags: 0, store: store) }
        XCTAssertEqual(bad, .failed("syntax error"))
        if case .skipped = JeffJSPrecompiler.precompileScript("1", filename: "https://x.test/main.js", evalFlags: 0, store: store) {} else {
            XCTFail("the main thread is refused")
        }
        let pseudo = onBackground { JeffJSPrecompiler.precompileScript("1", filename: "<native-event>", evalFlags: 0, store: store) }
        XCTAssertEqual(pseudo, .skipped("pseudo filename"))
        let module = onBackground { JeffJSPrecompiler.precompileScript("export var a = 1", filename: "https://x.test/m.js",
                                                                       evalFlags: JS_EVAL_TYPE_MODULE, store: store) }
        XCTAssertEqual(module, .skipped("module"))
        let rt = JeffJSRuntime(); rt.bytecodeCache.diskStore = store
        let ctx = rt.newContext()
        XCTAssertTrue(describe(ctx, ctx.eval(input: "var = ;", filename: "https://x.test/bad.js", evalFlags: 0)).hasPrefix("!exception: SyntaxError"))
    }

    /// The JS thread keeps running (and creating objects) while background
    /// compiles run: every object it makes belongs to its own runtime, every
    /// object the compiles make to theirs (template objects, the compile
    /// runtime's intrinsics), and a lookup of a key being precompiled waits
    /// for it.
    func testConcurrentCompilesKeepOwnership() throws {
        let store = try tempStore("conc")
        let rt = JeffJSRuntime(); rt.bytecodeCache.diskStore = store
        let ctx = rt.newContext()
        var sources: [(String, String)] = []
        for i in 0 ..< 12 {
            var s = "var acc\(i) = 0;\n"
            for j in 0 ..< 300 { s += "function f\(i)_\(j)(a) { return tag`x${a}y` + a + \(j); }\n" }
            s += "function tag(s, v) { return s.raw[0] + v; }\nacc\(i) = f\(i)_7(\(i)); acc\(i)"
            sources.append((s, "https://example.test/conc-\(i)-\(UUID().uuidString).js"))
        }
        let done = DispatchSemaphore(value: 0)
        let th = Thread {
            for (s, f) in sources { _ = JeffJSPrecompiler.precompileScript(s, filename: f, evalFlags: 0, store: store) }
            done.signal()
        }
        th.stackSize = 16 << 20
        th.start()
        // Meanwhile: allocate on the JS thread and check ownership.
        var wrongOwner = 0
        for n in 0 ..< 200 {
            let v = ctx.eval(input: "({ n: \(n), a: [\(n), 'x' + \(n)], f: function () { return \(n) } })",
                             filename: "<alloc>", evalFlags: 0)
            if let o = v.toObject(), o.ownerRuntime !== rt { wrongOwner += 1 }
            v.freeValue()
        }
        // Run the scripts in order: each is a disk hit (waited for if in flight) or a compile.
        for (i, (s, f)) in sources.enumerated() {
            XCTAssertEqual(describe(ctx, ctx.eval(input: s, filename: f, evalFlags: 0)), "x\(i)\(i)7")
        }
        done.wait()
        XCTAssertEqual(wrongOwner, 0, "JS-thread objects owned by a compile runtime")
        XCTAssertGreaterThan(rt.bytecodeCache.diskHitCount, 0)
        XCTAssertEqual(jeffJS_threadOwnersActive, 0)
        XCTAssertNil(jeffJS_threadOwnerRuntime())
        rt.runGC()
    }
}
