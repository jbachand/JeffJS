// InterpreterLoopTests.swift
// JeffJS — the three dispatch loops (the lean trace, the call-capable trace,
// the main loop; quickjs JS_CallInternal): the operand stack pointer and pc in
// registers (the lean trace returns its stack pointer with the resume pc),
// index arithmetic without overflow traps, locals through one pointer, an
// opcode switch that names every opcode, the trace's progress measure counted
// where pc jumps instead of once per opcode. None of it may change what a
// program computes: each case below runs loops that leave a trace in the
// middle of an expression, across try / catch, through labelled jumps, with
// many locals and arguments, calls with missing and extra arguments, heap
// values pushed from locals, int / double transitions and repeated
// low-progress exits. The expected values are QuickJS's and JavaScriptCore's
// (they agree); every case runs twice in one runtime, so the second run meets
// warm traces and inline caches, and once in a runtime of its own.

import XCTest
@testable import JeffJS

final class InterpreterLoopTests: XCTestCase {

    /// (name, source, value as JSON).
    static let cases: [(String, String, String)] = [
        // A deopt in the middle of an expression: operands already on the stack when the trace leaves.
        ("deoptMidExpression", #"""
            (function () {
              var o = { v: 3 }; var s = 0;
              for (var i = 0; i < 300; i++) { s = s + i * (i % 7 === 3 ? (function () { return o.v; })() : 2) + (i & 1); }
              return s;
            })()
            """#, #"96300"#),
        // try / catch inside a hot loop (the traces hand the block to the main loop and take it back).
        ("tryInLoop", #"""
            (function () {
              var s = 0;
              for (var i = 0; i < 400; i++) { try { if (i % 97 === 5) throw i; s += i; } catch (e) { s -= e; } finally { s += 1; } }
              return s;
            })()
            """#, #"78210"#),
        // Forward and backward jumps, continue / break with labels.
        ("jumps", #"""
            (function () {
              var s = 0;
              outer: for (var i = 0; i < 60; i++) {
                for (var j = 0; j < 60; j++) {
                  if (j === i) continue;
                  if (j > 40 && (i & 3) === 0) continue outer;
                  if (i === 55 && j === 30) break outer;
                  s = (s + i * j) | 0;
                }
              }
              return s;
            })()
            """#, #"2259564"#),
        // Many locals and arguments (two-byte local indexes, argument slots below the locals).
        ("manyLocals", #"""
            (function () {
              function f(a, b, c, d, e) {
                var l0 = a, l1 = b, l2 = c, l3 = d, l4 = e, l5 = 5, l6 = 6, l7 = 7, l8 = 8, l9 = 9, l10 = 10, l11 = 11, l12 = 12;
                var s = 0;
                for (var i = 0; i < 200; i++) { l0 += l12; l5 = (l5 + l0 + a) | 0; l9 ^= i; s = (s + l1 + l2 * l3 - l4 + l5 + l6 + l7 + l8 + l9 + l10 + l11) | 0; }
                return s + l0;
              }
              return f(1, 2, 3, 4, 5);
            })()
            """#, #"16305433"#),
        // Calls in a loop with fewer, exact and more arguments than parameters, and a recursive callee.
        ("callsInLoop", #"""
            (function () {
              function g(a, b, c) { return (a | 0) + (b === undefined ? 100 : b) + (c === undefined ? 1000 : c); }
              function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
              var s = 0;
              for (var i = 0; i < 300; i++) { s = (s + g(i) + g(i, 1) + g(i, 1, 2) + g(i, 1, 2, 3)) | 0; }
              return s + fib(15);
            })()
            """#, #"812110"#),
        // Objects and strings pushed from locals (the inline count bump), dropped on every path.
        ("pushesOfHeapValues", #"""
            (function () {
              var o = { a: 1, b: "x" }, str = "abc", arr = [1, 2, 3], s = 0, t = "";
              for (var i = 0; i < 500; i++) {
                var p = o, q = str, r = arr;
                s += p.a + r[i % 3] + q.length;
                if ((i & 63) === 0) t = t + q + p.b;
                p = null; r = q;
              }
              return s + ":" + t.length + ":" + str + ":" + arr.length;
            })()
            """#, #""2999:32:abc:3""#),
        // Float, int and mixed arithmetic with overflow to double inside a loop.
        ("numeric", #"""
            (function () {
              var a = 2147483000, b = 0.5, s = 0;
              for (var i = 0; i < 2000; i++) { a = a + i; b = b * 1.001 + 0.25; s = (s + (a | 0) + (b | 0)) | 0; if (a > 2147483647) a = a - 4294967296; }
              return a + ":" + b.toFixed(6) + ":" + s;
            })()
            """#, #""-2145485296:1599.109751:1333136229""#),
        // A long straight-line body, then an early exit: a trace that leaves after little progress many times.
        ("lowProgressExits", #"""
            (function () {
              var s = 0, o = {};
              for (var i = 0; i < 1500; i++) {
                if (i % 2) { o["k" + (i % 5)] = i; delete o["k" + ((i + 1) % 5)]; }
                s += Object.keys(o).length + i;
              }
              return s;
            })()
            """#, #"1127246"#),
    ]

    private func run(_ ctx: JeffJSContext, _ name: String, _ src: String, _ want: String, _ label: String) {
        let r = ctx.eval(input: "JSON.stringify(" + src + ")", filename: "<interp-loop>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        if r.isException {
            let e = ctx.getException()
            XCTFail("\(name) (\(label)): threw \(ctx.toSwiftString(e) ?? "?")")
            e.freeValue()
            return
        }
        XCTAssertEqual(ctx.toSwiftString(r), want, "\(name) (\(label))")
        r.freeValue()
    }

    func testLoopsComputeWhatQuickJSComputes() {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        for round in 0..<2 {
            for (name, src, want) in Self.cases { run(ctx, name, src, want, "round \(round)") }
            rt.runGC()
        }
        XCTAssertNil(ctx.currentFrame, "no frame is current once every call has returned")
        XCTAssertEqual(ctx.callDepth, 0)
    }

    /// The same programs in a fresh runtime per case (cold caches, cold traces: every
    /// loop starts in the main loop and is handed to a trace part way through).
    func testLoopsFromCold() {
        for (name, src, want) in Self.cases {
            let rt = JeffJSRuntime()
            let ctx = rt.newContext()
            run(ctx, name, src, want, "cold")
            ctx.free(); rt.free()
        }
    }

    /// The opcode enum still decodes by bit pattern: the dispatch switches name every
    /// case and read one byte, so the first 256 cases must be the byte values.
    func testOpcodeBytesAreEnumCases() {
        XCTAssertEqual(MemoryLayout<JeffJSOpcode>.size, 2)
        for b in 0..<256 {
            let op = unsafeBitCast(UInt16(b), to: JeffJSOpcode.self)
            XCTAssertEqual(Int(op.rawValue), b, "opcode byte \(b) decodes to the case with that raw value")
        }
        XCTAssertGreaterThanOrEqual(JeffJSOpcode.allCases.count, 256)
    }
}
