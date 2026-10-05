// InterruptTerminationTests.swift
// JeffJS — an interrupt (`JeffJSRuntime.setInterruptHandler` returning true) ends the
// running script uncatchably; afterwards the context must be idle again: no current
// frame, call depth 0, no inline frames — the host checks exactly that before it runs
// idle work or tears the runtime down (the Apple Watch app's memory / script-time
// budgets, 2026-10-05). An interrupt raised inside an inline-called function used to
// leave `ctx.currentFrame` pointing at the abandoned inline caller frame.
//
//   swift test -c release --filter InterruptTerminationTests

import XCTest
@testable import JeffJS

final class InterruptTerminationTests: XCTestCase {

    /// Interrupts after `checks` handler calls (each call is one interrupt-counter expiry).
    private func run(_ source: String, checks: Int, file: StaticString = #filePath, line: UInt = #line) {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        var calls = 0
        rt.setInterruptHandler { _ in
            calls += 1
            return calls > checks
        }
        let r = ctx.eval(input: source, filename: "<interrupt>", evalFlags: 0)
        XCTAssertTrue(r.isException, "the script must end by the interrupt", file: file, line: line)
        r.freeValue()
        let exc = ctx.getException()
        exc.freeValue()
        XCTAssertNil(ctx.currentFrame, "no frame may stay current after an interrupt", file: file, line: line)
        XCTAssertEqual(ctx.callDepth, 0, "call depth back to 0", file: file, line: line)
        XCTAssertEqual(rt.inlineStackTop, 0, "no inline frames left", file: file, line: line)

        // The context keeps working: plain code, nested calls, a stack trace.
        rt.setInterruptHandler(nil)
        let after = ctx.eval(input: """
            function f(n) { return n <= 1 ? new Error('x').stack.length > 0 : f(n - 1) }
            var s = 0; for (var i = 0; i < 1000; i++) s += i; f(20) && s === 499500
            """, filename: "<after>", evalFlags: 0)
        XCTAssertTrue(after.isBool && after.toBool(), "context usable after the interrupt", file: file, line: line)
        after.freeValue()
        XCTAssertNil(ctx.currentFrame, file: file, line: line)
    }

    /// The loop is in the top-level code.
    func testInterruptInTopLevelLoop() {
        run("var t = 0; for (;;) { t++ }", checks: 3)
    }

    /// The interrupt fires inside functions called inline from a loop (three levels).
    func testInterruptInInlineCallee() {
        for checks in [1, 2, 5, 17] {
            run("""
                function c(i) { var x = 0; for (var k = 0; k < 50; k++) x += k; return x + i }
                function b(n) { var s = 0; for (var i = 0; i < 200; i++) s += c(i); return s }
                function a(n) { return b(n) + 1 }
                var t = 0; for (;;) { t += a(1) }
                """, checks: checks)
        }
    }

    /// A host call after an interrupted task (a timer callback) catches its own exceptions.
    func testHostCallAfterInterruptCatches() {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        defer { ctx.free(); rt.free() }
        var calls = 0
        rt.setInterruptHandler { _ in calls += 1; return calls > 2 }
        let setup = ctx.eval(input: "function cb() { try { throw new Error('x') } catch (e) { return 'caught' } }",
                             filename: "<setup>", evalFlags: 0)
        setup.freeValue()
        let r = ctx.eval(input: "for (;;) {}", filename: "<loop>", evalFlags: 0)
        XCTAssertTrue(r.isException)
        r.freeValue()
        ctx.getException().freeValue()
        rt.setInterruptHandler(nil)
        let global = ctx.getGlobalObject()
        let cb = ctx.getPropertyStr(obj: global, name: "cb")
        let out = ctx.callFunction(cb, thisVal: .undefined, args: [])
        XCTAssertEqual(ctx.toSwiftString(out), "caught")
        out.freeValue(); cb.freeValue(); global.freeValue()
    }

    /// A catch handler on the way out is skipped (uncatchable) and the frames still unwind.
    func testInterruptThroughTryCatch() {
        run("""
            function inner() { for (;;) {} }
            function mid() { try { inner() } catch (e) { return 'caught' } }
            for (;;) { try { mid() } catch (e) {} }
            """, checks: 4)
    }
}
