// BytecodeCacheClosureTests.swift
// JeffJS — "BytecodeCacheClosures" group.
//
// Every snippet here is run twice: once from source text (the cache-miss
// path) and once through serialize -> deserialize -> execute (the path a
// bytecode-cache hit and `evalPrecompiled` take). The two must agree.
//
// The deserializing runtime is deliberately given a *different* atom
// numbering from the one that compiled the blob (`atomShift`), because that
// is the real precompiled-bundle situation: the `.jfbc` is produced by
// Scripts/generate_polyfill_bytecode.swift in one process and loaded by the
// app in another. With identical numbering a broken atom remap is the
// identity function and every test passes for the wrong reason.
//
//   swift test -c release --filter BytecodeCacheClosures

import XCTest
@testable import JeffJS

final class BytecodeCacheClosuresTests: XCTestCase {

    /// How many throwaway atoms to intern in the loading runtime before
    /// deserializing, so its atom IDs do not line up with the writer's.
    private let atomShift = 500

    // MARK: - Harness

    /// Compile exactly the way `nativeEvalPipeline` does on a cache miss.
    private func compile(_ src: String, ctx: JeffJSContext, filename: String) -> JeffJSFunctionBytecode? {
        let parseState = JeffJSParseState(source: src, filename: filename, ctx: ctx)
        parseState.isModule = false
        parseState.allowHTMLComments = true
        let fd = JeffJSFunctionDefCompiler()
        fd.filename = ctx.rt.findAtom(filename)
        fd.source = src
        fd.sourceText = JeffJSSourceText(bytes: parseState.buf)
        fd.sourceStart = 0
        fd.sourceEnd = parseState.buf.count
        let parser = JeffJSParser(s: parseState, fd: fd)
        parser.parseProgram()
        if parser.hasError || fd.byteCode.error { return nil }
        return JeffJSCompiler.createFunction(ctx: ctx, fd: fd)
    }

    /// Serialize `src` from a fresh runtime (the generator's job).
    private func serialize(_ src: String, file: StaticString = #filePath, line: UInt = #line) -> [UInt8]? {
        let rt = JeffJSRuntime()
        let ctx = JeffJSContext(rt: rt)
        guard let fb = compile(src, ctx: ctx, filename: "<bcc-bytecode>") else {
            XCTFail("compile failed", file: file, line: line)
            return nil
        }
        return JeffJSBytecodeSerializer.serialize(fb, rt: rt)
    }

    /// Run `src` from source text.
    private func runText(_ src: String) -> String {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        return describe(ctx, ctx.eval(input: src, filename: "<bcc-text>", evalFlags: 0))
    }

    /// Compile `src` in one runtime, serialize, then deserialize + run it in a
    /// *fresh* runtime with shifted atom numbering.
    private func runSerialized(_ src: String) -> String {
        guard let bytes = serialize(src) else { return "!compile-failed" }
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        for i in 0..<atomShift { _ = rt.findAtom("__bccShift\(i)") }
        return describe(ctx, ctx.evalPrecompiled(bytes))
    }

    private func describe(_ ctx: JeffJSContext, _ v: JeffJSValue) -> String {
        if v.isException {
            return "!exception: " + (ctx.toSwiftString(ctx.rt.currentException) ?? "?")
        }
        return ctx.toSwiftString(v) ?? "!unstringifiable"
    }

    /// The whole point: both paths must produce the same answer.
    private func check(_ name: String, _ src: String, file: StaticString = #filePath, line: UInt = #line) {
        let text = runText(src)
        let bc = runSerialized(src)
        XCTAssertFalse(text.hasPrefix("!"), "\(name): text path failed: \(text)", file: file, line: line)
        XCTAssertEqual(bc, text, "\(name): bytecode-cache path diverged", file: file, line: line)
    }

    /// A blob must survive deserialize -> re-serialize byte for byte. Any
    /// field the writer emits and the reader drops (or two distinct atoms the
    /// table collapses into one) shows up here.
    private func checkStable(_ name: String, _ src: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let once = serialize(src, file: file, line: line) else { return }
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        for i in 0..<atomShift { _ = rt.findAtom("__bccShift\(i)") }
        guard let fb = JeffJSBytecodeDeserializer.deserialize(once, rt: rt, ctx: ctx) else {
            XCTFail("\(name): deserialize failed", file: file, line: line)
            return
        }
        let twice = JeffJSBytecodeSerializer.serialize(fb, rt: rt)
        XCTAssertEqual(twice.count, once.count, "\(name): re-serialized blob changed size", file: file, line: line)
        XCTAssertEqual(twice, once, "\(name): blob is not stable across a cache round trip", file: file, line: line)
    }

    // MARK: - (a) self-recursive function declaration + (b) sibling caller

    func testSelfRecursiveDeclarationVisibleToSiblings() {
        let src = """
        var out = [];
        (function () {
            function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); }
            function sibling() { return typeof fact; }
            function plain(n) { return n * 2; }
            function siblingPlain() { return typeof plain; }
            out.push(sibling(), fact(5), siblingPlain(), plain(3));
        })();
        out.join("|");
        """
        check("selfrec-decl", src)
        checkStable("selfrec-decl", src)
    }

    /// The shape that broke the app: the closure that calls the self-recursive
    /// declaration is *created before* the declaration.
    func testForwardReferenceFromEarlierClosure() {
        check("forward-ref", """
        var out = [];
        (function () {
            var early = function () { return typeof walk; };
            var earlyCall = function (n) { return walk(n); };
            function walk(n) { return n <= 0 ? 0 : 1 + walk(n - 1); }
            out.push(early(), earlyCall(4), typeof walk);
        })();
        out.join("|");
        """)
    }

    // MARK: - (c) named function expression calling itself by its own name

    func testNamedFunctionExpressionSelfReference() {
        let src = """
        var out = [];
        (function () {
            var f = function inner(n) { return n <= 0 ? 0 : 1 + inner(n - 1); };
            function sibling() { return typeof f + "/" + f(3); }
            out.push(f(4), sibling(), typeof inner);
        })();
        out.join("|");
        """
        check("named-func-expr", src)
        checkStable("named-func-expr", src)
    }

    func testNamedFunctionExpressionNameIsConstInside() {
        check("nfe-const", """
        var out = [];
        (function () {
            var g = function me(n) { try { me = 1; } catch (e) { out.push("TypeError"); } return typeof me; };
            out.push(g(1));
        })();
        out.join("|");
        """)
    }

    // MARK: - (d) mutual recursion

    func testMutualRecursion() {
        check("mutual", """
        var out = [];
        (function () {
            function isEven(n) { return n === 0 ? true : isOdd(n - 1); }
            function isOdd(n) { return n === 0 ? false : isEven(n - 1); }
            function probe() { return typeof isEven + "," + typeof isOdd; }
            out.push(probe(), isEven(10), isOdd(7));
        })();
        out.join("|");
        """)
    }

    // MARK: - (e) nested function and class method

    func testSelfRecursiveInsideNestedFunction() {
        check("nested", """
        var out = [];
        (function () {
            function outer() {
                function rec(n) { return n <= 0 ? 0 : 1 + rec(n - 1); }
                function peer() { return typeof rec; }
                return peer() + ":" + rec(3);
            }
            function probe() { return typeof outer; }
            out.push(probe(), outer());
        })();
        out.join("|");
        """)
    }

    func testSelfRecursiveInsideClassMethod() {
        check("class-method", """
        var out = [];
        (function () {
            class C {
                run(n) {
                    function rec(k) { return k <= 0 ? 0 : 1 + rec(k - 1); }
                    function peer() { return typeof rec; }
                    return peer() + ":" + rec(n);
                }
                static sRun(n) {
                    var early = function () { return typeof helper; };
                    function helper(k) { return k <= 0 ? 0 : 1 + helper(k - 1); }
                    return early() + ":" + helper(n);
                }
            }
            out.push(new C().run(4), C.sRun(3));
        })();
        out.join("|");
        """)
    }

    // MARK: - (f) self-recursive arrow bound with const

    func testSelfRecursiveConstArrow() {
        check("const-arrow", """
        var out = [];
        (function () {
            const rec = (n) => n <= 0 ? 0 : 1 + rec(n - 1);
            const peer = () => typeof rec;
            function probe() { return typeof rec + "," + typeof peer; }
            out.push(peer(), rec(5), probe());
        })();
        out.join("|");
        """)
    }

    // MARK: - Closures that outlive the frame that created them
    //
    // gtag.js fails this way on a real page: a `setTimeout` callback created
    // inside a big IIFE calls a plain sibling function declaration (`Sb`) of
    // that IIFE, and the call happens long after the IIFE frame has exited.
    // The var_ref the callback holds has been detached by then, so this
    // exercises a different path from a synchronous sibling call.

    /// A JS-level timer queue, so the test needs no host timers: callbacks are
    /// collected and drained explicitly after the top-level script has run.
    private let timerShim = """
    globalThis.__TIMERS = [];
    globalThis.__ERRS = [];
    globalThis.setTimeout = function (f) { globalThis.__TIMERS.push(f); return globalThis.__TIMERS.length; };
    globalThis.clearTimeout = function () {};
    globalThis.__drain = function () {
        var t = globalThis.__TIMERS; globalThis.__TIMERS = [];
        for (var i = 0; i < t.length; i++) { try { t[i](); } catch (e) { globalThis.__ERRS.push("" + e); } }
    };

    """

    /// Run `src`, then drain the timer queue `rounds` times and report.
    private func runDeferred(_ src: String, rounds: Int, viaBytecode: Bool) -> String {
        let full = timerShim + src
        let drain = String(repeating: "__drain(); ", count: rounds) +
                    "out.join(\"|\") + \" errs=\" + globalThis.__ERRS.join(\";\")"
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        if viaBytecode {
            guard let bytes = serialize(full) else { return "!compile-failed" }
            for i in 0..<atomShift { _ = rt.findAtom("__bccShift\(i)") }
            let r = ctx.evalPrecompiled(bytes)
            if r.isException { return describe(ctx, r) }
        } else {
            let r = ctx.eval(input: full, filename: "<bcc-text>", evalFlags: 0)
            if r.isException { return describe(ctx, r) }
        }
        _ = rt.executePendingJobs()
        let v = ctx.eval(input: drain, filename: "<bcc-drain>", evalFlags: 0)
        _ = rt.executePendingJobs()
        return describe(ctx, v)
    }

    private func checkDeferred(_ name: String, _ src: String, rounds: Int = 2,
                               file: StaticString = #filePath, line: UInt = #line) {
        let text = runDeferred(src, rounds: rounds, viaBytecode: false)
        let bc = runDeferred(src, rounds: rounds, viaBytecode: true)
        XCTAssertFalse(text.hasPrefix("!"), "\(name): text path failed: \(text)", file: file, line: line)
        XCTAssertTrue(text.hasSuffix("errs="), "\(name): text path reported errors: \(text)", file: file, line: line)
        XCTAssertEqual(bc, text, "\(name): bytecode-cache path diverged", file: file, line: line)
    }

    func testDeferredClosureSeesHoistedSibling() {
        checkDeferred("deferred-sibling", """
        var out = [];
        (function () {
            function Rb() { return new Date(0); }
            function Sb() { return Rb().getTime(); }
            function y() { out.push("y:" + typeof Sb + "/" + Sb()); }
            setTimeout(y, 0);
            setTimeout(function () { out.push("anon:" + typeof Sb + "/" + Sb()); }, 0);
            var early = function () { out.push("early:" + typeof Later + "/" + Later()); };
            setTimeout(early, 0);
            function Later() { return 7; }
        })();
        """)
    }

    func testDeferredClosureNestedAndRescheduled() {
        checkDeferred("deferred-nested", """
        var out = [];
        (function () {
            function Sb() { return 42; }
            (function () {
                function inner() { out.push("in:" + typeof Sb + "/" + Sb()); }
                setTimeout(inner, 0);
            })();
            setTimeout(function () {
                setTimeout(function () { out.push("deep:" + typeof Sb + "/" + Sb()); }, 0);
            }, 0);
        })();
        """, rounds: 3)
    }

    func testDeferredClosureViaMicrotask() {
        checkDeferred("deferred-microtask", """
        var out = [];
        (function () {
            function Sb() { return 42; }
            Promise.resolve().then(function () { out.push("p:" + typeof Sb + "/" + Sb()); });
        })();
        """, rounds: 1)
    }

    // MARK: - Wide (0x00-prefixed) opcodes in the middle of a function
    //
    // `init_this` (raw 280) and `private_in` (raw 281) are emitted as a 0x00
    // prefix plus a low byte. The atom-table walk used to read that prefix as
    // OP_invalid and step one byte, desynchronising the rest of the function:
    // atom operands past it were written to the blob as raw atom IDs of the
    // compiling runtime and never remapped, and non-atom operand bytes could
    // be overwritten with table indices. Both are invisible when the writing
    // and reading runtimes happen to agree on atom numbering — hence the
    // shift in `runSerialized`.

    func testDerivedConstructorWithAtomsAfterSuper() {
        let src = """
        var out = [];
        (function () {
            class Base { constructor() { this.baseField = 1; } }
            class D extends Base {
                constructor() {
                    super();
                    this.alphaOne = 10;
                    this.betaTwo = this.alphaOne + 1;
                    this.gammaThree = helperRec(3);
                    this.deltaFour = { nestedKeyOne: this.betaTwo, nestedKeyTwo: "tailValue" };
                }
            }
            function helperRec(n) { return n <= 0 ? 0 : 1 + helperRec(n - 1); }
            function sibling() { return typeof helperRec; }
            var d = new D();
            out.push(d.baseField, d.alphaOne, d.betaTwo, d.gammaThree,
                     d.deltaFour.nestedKeyOne, d.deltaFour.nestedKeyTwo,
                     sibling(), Object.keys(d).join(","));
        })();
        out.join("|");
        """
        check("derived-ctor", src)
        checkStable("derived-ctor", src)
    }

    func testPrivateInWithAtomsAfterIt() {
        let src = """
        var out = [];
        (function () {
            class P {
                #secretField = 5;
                static has(o) { return #secretField in o; }
                probe(o) {
                    var hit = (#secretField in o);
                    var tailAtomOne = "tailValueOne";
                    var tailAtomTwo = { tailKeyOne: 1, tailKeyTwo: 2 };
                    return hit + "/" + tailAtomOne + "/" + Object.keys(tailAtomTwo).join(",") +
                           "/" + typeof recFn;
                }
            }
            function recFn(n) { return n <= 0 ? 0 : 1 + recFn(n - 1); }
            var p = new P();
            out.push(P.has(p), P.has({}), p.probe(p), recFn(2));
        })();
        out.join("|");
        """
        check("private-in", src)
        checkStable("private-in", src)
    }

    /// Direct structural guard for the wide-opcode fix: the atom-table walk
    /// has to break the stream into exactly the instructions the interpreter
    /// does. A snippet-level test only catches this when the desynchronised
    /// walk happens to land on an atom operand, which depends on whatever
    /// opcode the wide low byte aliases to (today `perm3` / `perm4`, both
    /// one byte, so the walk re-synchronises by luck).
    func testAtomWalkAgreesWithInterpreterDecode() {
        let src = """
        (function () {
            class Base { constructor() { this.baseField = 1; } }
            class D extends Base {
                #hidden = 2;
                constructor() { super(); this.alphaOne = 10; this.betaTwo = this.alphaOne; }
                static has(o) { return #hidden in o; }
                read(o) { return (#hidden in o) ? this.alphaOne : this.betaTwo; }
            }
            var d = new D();
            return D.has(d) + "" + d.read(d);
        })();
        """
        let rt = JeffJSRuntime()
        let ctx = JeffJSContext(rt: rt)
        guard let fb = compile(src, ctx: ctx, filename: "<walk>") else { return XCTFail("compile failed") }

        var wideSeen = 0
        var checked = 0
        func visit(_ f: JeffJSFunctionBytecode, _ path: String) {
            let bc = f.bytecode
            // Reference decode: the one the compiler and interpreter use.
            var reference: [Int] = []
            var pc = 0
            while pc < bc.count {
                reference.append(pc)
                guard let (op, w) = JeffJSCompiler.readOpcodeFromBuf(bc, pc) else { break }
                if w == 2 { wideSeen += 1 }
                let info = jeffJSOpcodeInfo[Int(op.rawValue)]
                pc += max(Int(info.size) + (w - 1), 1)
            }
            XCTAssertEqual(pc, bc.count, "\(path): reference walk did not land on the end")
            XCTAssertEqual(JeffJSBytecodeWalk.instructionBoundaries(bc), reference,
                           "\(path): atom-table walk disagrees with the interpreter's decode")
            checked += 1
            for (i, v) in f.cpool.enumerated() {
                if let nested = v.toFunctionBytecode() { visit(nested, path + "/c\(i)") }
            }
        }
        visit(fb, "root")
        XCTAssertGreaterThan(checked, 1, "expected nested functions to walk")
        XCTAssertGreaterThan(wideSeen, 0, "snippet no longer contains a wide (0x00-prefixed) opcode")
    }

    // MARK: - The null atom is not the empty-string atom

    func testNullAtomAndEmptyStringAtomStayDistinct() {
        // The top-level script function has nameAtom == JS_ATOM_NULL, and the
        // body mentions the empty string, so both land in the atom table.
        let src = """
        var out = [];
        (function () {
            var anon = function () { return ""; };
            var o = {}; o[""] = "emptyKey";
            out.push(anon(), o[""], JSON.stringify(o), anon.name === "" ? "noname" : anon.name);
        })();
        out.join("|");
        """
        check("null-atom", src)
        checkStable("null-atom", src)
    }

    // MARK: - The app's bundle shape: a list of sibling IIFEs

    func testIIFEListBundleShape() {
        var src = "var out = [];\n"
        for i in 0..<40 {
            src += """
            (function () {
                var early\(i) = function () { return typeof rec\(i); };
                function rec\(i)(n) { return n <= 0 ? \(i) : rec\(i)(n - 1); }
                function peer\(i)() { return typeof rec\(i) + typeof early\(i); }
                globalThis.probe\(i) = function () { return early\(i)() + "/" + peer\(i)() + "/" + rec\(i)(3); };
            })();

            """
        }
        src += """
        for (var i = 0; i < 40; i++) out.push(globalThis["probe" + i]());
        out.join("|");
        """
        check("iife-bundle", src)
    }

    /// Many locals in the enclosing scope, so the captured slot indices are
    /// past the short-form (u8) opcode range.
    func testSelfRecursiveWithWideLocalIndices() {
        var src = "var out = [];\n(function () {\n"
        for i in 0..<300 { src += "  var pad\(i) = \(i);\n" }
        src += """
          var early = function () { return typeof deep; };
          function deep(n) { return n <= 0 ? pad299 : deep(n - 1); }
          function peer() { return typeof deep; }
          out.push(early(), peer(), deep(3));
        })();
        out.join("|");
        """
        check("wide-locals", src)
    }

    // MARK: - Reader/writer agreement on bundle-sized input

    /// Synthetic stand-in for the app's precompiled bundle: a 300-plus-KB IIFE
    /// list with derived classes and private fields mixed in, so it contains
    /// wide opcodes as well as self-recursive helpers.
    func testLargeBundleRoundTripIsByteIdentical() {
        var src = ""
        for i in 0..<500 {
            src += """
            (function () {
                var early\(i) = function () { return typeof rec\(i); };
                function rec\(i)(n) { return n <= 0 ? \(i) : rec\(i)(n - 1); }
                class Base\(i) { constructor() { this.tag\(i) = "b\(i)"; } }
                class Derived\(i) extends Base\(i) {
                    #priv\(i) = \(i);
                    constructor() { super(); this.extra\(i) = rec\(i)(2); }
                    static has\(i)(o) { return #priv\(i) in o; }
                }
                var obj\(i) = { tag: "t\(i)", go: function (n) { return rec\(i)(n); } };
                globalThis.probe\(i) = function () {
                    var d = new Derived\(i)();
                    return early\(i)() + obj\(i).go(2) + d.tag\(i) + d.extra\(i) +
                           Derived\(i).has\(i)(d);
                };
            })();

            """
        }
        XCTAssertGreaterThan(src.utf8.count, 300_000, "bundle stand-in should be bundle-sized")
        checkStable("large-bundle", src)
    }

    /// And it must still run identically from the blob.
    func testLargeBundleRunsIdenticallyFromBytecode() {
        var src = "var out = [];\n"
        for i in 0..<60 {
            src += """
            (function () {
                var early\(i) = function () { return typeof rec\(i); };
                function rec\(i)(n) { return n <= 0 ? \(i) : rec\(i)(n - 1); }
                class Base\(i) { constructor() { this.tag\(i) = "b\(i)"; } }
                class Derived\(i) extends Base\(i) {
                    #priv\(i) = \(i);
                    constructor() { super(); this.extra\(i) = rec\(i)(2); }
                    static has\(i)(o) { return #priv\(i) in o; }
                }
                globalThis.probe\(i) = function () {
                    var d = new Derived\(i)();
                    return early\(i)() + "/" + d.tag\(i) + "/" + d.extra\(i) + "/" + Derived\(i).has\(i)(d);
                };
            })();

            """
        }
        src += """
        for (var i = 0; i < 60; i++) out.push(globalThis["probe" + i]());
        out.join("|");
        """
        check("large-bundle-run", src)
    }

    /// The app's real precompiled bundle, when it was built by this engine.
    /// Skipped (with the reason) after a `compilerVersion` bump until
    /// `./Scripts/precompile_polyfills.sh` has been re-run.
    func testPrecompiledBundleRoundTripIsByteIdentical() throws {
        let path = "/Users/jeffbachand/www/React Natively/React Natively/renderengine/JS/precompiled_static_polyfills.jfbc"
        guard let data = FileManager.default.contents(atPath: path) else {
            throw XCTSkip("fixture not present: \(path)")
        }
        var bytes = [UInt8](data)
        guard bytes.count > 8 else { throw XCTSkip("fixture too small") }
        // 8-byte little-endian compiler-version header (generate_polyfill_bytecode).
        var version: UInt64 = 0
        for i in 0..<8 { version |= UInt64(bytes[i]) << (i * 8) }
        bytes.removeFirst(8)
        guard version == JeffJSBytecodeCache.compilerVersion else {
            throw XCTSkip("fixture was built by compiler version \(version), current is \(JeffJSBytecodeCache.compilerVersion) — re-run Scripts/precompile_polyfills.sh")
        }

        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        for i in 0..<atomShift { _ = rt.findAtom("__bccShift\(i)") }
        guard let fb = JeffJSBytecodeDeserializer.deserialize(bytes, rt: rt, ctx: ctx) else {
            return XCTFail("could not deserialize the precompiled bundle")
        }
        let again = JeffJSBytecodeSerializer.serialize(fb, rt: rt)
        XCTAssertEqual(again.count, bytes.count, "re-serialized bundle changed size")
        XCTAssertEqual(again, bytes, "precompiled bundle is not stable across a cache round trip")
    }

    /// Whole-file corpus check: everything the repo ships as .js must survive
    /// the round trip byte for byte.
    func testRepoScriptCorpusRoundTrip() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // JeffJSTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
        var files: [URL] = []
        for dir in ["bench", "scratch"] {
            let d = root.appendingPathComponent(dir)
            if let fs = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) {
                files.append(contentsOf: fs.filter { $0.pathExtension == "js" })
            }
        }
        XCTAssertFalse(files.isEmpty, "no corpus scripts found under \(root.path)")
        for f in files {
            guard let src = try? String(contentsOf: f, encoding: .utf8) else { continue }
            checkStable(f.lastPathComponent, src)
        }
    }
}
