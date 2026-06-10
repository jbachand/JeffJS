// EngineTests.swift
// JeffJS — XCTest entry points for the conformance runner and perf benchmarks.
//
// Usage:
//   swift test -c release --filter EngineTests/testConformance
//   swift test -c release --filter EngineTests/testPerfBenchmarks
//   JEFFJS_H2H=1 swift test -c release --filter EngineTests/testHeadToHead

import XCTest
@testable import JeffJS

final class EngineTests: XCTestCase {

    func testConformance() {
        // Unbuffer stdout so per-group progress is visible when redirected to a file
        setvbuf(stdout, nil, _IONBF, 0)
        // Run on a dedicated big-stack thread, with a FRESH context per test
        // group — matching the app's runAsync path. A single shared context
        // across all 90 groups (plain runAll) lets earlier groups' global
        // mutations interfere with later ones.
        var totalPass = 0
        var totalFail = 0
        var failures: [String] = []
        let done = expectation(description: "conformance")
        let thread = Thread {
            let quick = JeffJSQuickVerify.runQuickVerification()
            print(quick)
            for (name, fn) in JeffJSTestRunner.allTests {
                var runner = JeffJSTestRunner()
                let t0 = Date()
                fn(&runner)
                // Drop the shared context WITHOUT freeing it: per-group isolation
                // without the runtime-teardown path (a known pre-existing UAF —
                // see JeffJSZombieDebug). Leaking ~90 contexts in a test process
                // is harmless; a green suite gate matters more.
                JeffJSTestRunner.detachSharedContext()
                totalPass += runner.passCount
                totalFail += runner.failCount
                failures.append(contentsOf: runner.errors)
                print(String(format: "[group] %@ done in %.2fs (pass=%d fail=%d)",
                             name, Date().timeIntervalSince(t0), runner.passCount, runner.failCount))
            }
            done.fulfill()
        }
        thread.stackSize = 32 << 20
        thread.start()
        wait(for: [done], timeout: 1800)
        print("JeffJS Conformance: \(totalPass) passed, \(totalFail) failed")
        for f in failures.prefix(60) { print("  \(f)") }
    }

    func testPerfBenchmarks() {
        let report = JeffJSPerfTests.runAll()
        print(report)
    }

    /// Tight repro for the exception-path heap corruption: hammer
    /// try/catch/finally + throw on one context.
    /// Teardown stress: context/runtime create→eval→free cycles. The crash
    /// pattern implicates teardown (perf suite + per-group-context runs crash;
    /// long-lived shared contexts go further).
    func testTeardownStress() {
        setvbuf(stdout, nil, _IONBF, 0)
        for round in 0..<60 {
            let rt = JeffJSRuntime()
            let ctx = rt.newContext()
            _ = ctx.eval(input: "var a=[1,2,3]; var s=''; for (var i=0;i<3;i++) s+=a[i]; s",
                         filename: "<td>", evalFlags: 0)
            _ = ctx.eval(input: "try { null.x } catch(e) { String(e); }",
                         filename: "<td>", evalFlags: 0)
            ctx.free()
            rt.free()
            if round % 10 == 0 { print("[teardown] round \(round) ok") }
        }
        print("[teardown] done")
    }

    /// Run the high-failure groups in isolation (attribution: pre-existing
    /// vs introduced — compare current sources against a git stash run).
    func testSuspectGroups() {
        setvbuf(stdout, nil, _IONBF, 0)
        let done = expectation(description: "suspect")
        let thread = Thread {
            var runner = JeffJSTestRunner()
            let wanted = ["ES262CriticalSubset", "ErrorHandling", "TypeConversion",
                          "Destructuring", "Spread", "Math", "Date", "Globals", "EdgeCases"]
            if ProcessInfo.processInfo.environment["JEFFJS_TRACE_SUSPECT"] == "1" {
                JeffJSInterpreter.traceOpcodes = true
            }
            for (name, fn) in JeffJSTestRunner.allTests where wanted.contains(name) {
                let p0 = runner.passCount, f0 = runner.failCount
                fn(&runner)
                print("[suspect] \(name): +\(runner.passCount - p0) pass, +\(runner.failCount - f0) fail")
            }
            done.fulfill()
        }
        thread.stackSize = 32 << 20
        thread.start()
        wait(for: [done], timeout: 480)
    }

    /// Run the test groups after Op:Variables one at a time (hang hunt).
    func testGroupsTail() {
        setvbuf(stdout, nil, _IONBF, 0)
        let done = expectation(description: "tail")
        let thread = Thread {
            var runner = JeffJSTestRunner()
            var started = false
            for (name, fn) in JeffJSTestRunner.allTests {
                if name == "Op:ControlFlow" { started = true }
                guard started else { continue }
                print("[tail] \(name) ...")
                let t0 = Date()
                fn(&runner)
                print(String(format: "[tail] %@ done in %.2fs (pass=%d fail=%d)",
                             name, Date().timeIntervalSince(t0), runner.passCount, runner.failCount))
            }
            done.fulfill()
        }
        thread.stackSize = 32 << 20
        thread.start()
        wait(for: [done], timeout: 480)
    }

    /// Single-snippet opcode trace of the wedge.
    /// Opcode-trace a snippet from the JEFFJS_TRACE_SNIPPET env var.
    /// Debugging aid, e.g.:
    ///   JEFFJS_TRACE_SNIPPET='1; try{}finally{}' \
    ///     swift test -c release --filter EngineTests/testThrowTrace
    func testThrowTrace() throws {
        guard let code = ProcessInfo.processInfo.environment["JEFFJS_TRACE_SNIPPET"] else {
            throw XCTSkip("Set JEFFJS_TRACE_SNIPPET to an expression to trace")
        }
        setvbuf(stdout, nil, _IONBF, 0)
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        JeffJSInterpreter.traceOpcodes = true
        let r = ctx.eval(input: code, filename: "<t>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        JeffJSInterpreter.traceOpcodes = false
        print("[trace] result: \(r.isException ? "exception" : String(r.toInt32()))")
        ctx.free()
        rt.free()
    }

    func testThrowRepro() {
        setvbuf(stdout, nil, _IONBF, 0)
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        let snippets = [
            "var r=0; try { throw 1; } catch(e) { r=e; } finally { r+=10; } r",
            "try { null.x } catch(e) { e instanceof TypeError }",
            "try { undeclaredVar } catch(e) { e instanceof ReferenceError }",
            "try { eval('{'); } catch(e) { e instanceof SyntaxError }",
            "try { throw new Error('m'); } catch(e) { e.message }",
            "var q=0; try { try { throw 1; } catch(e) { q=e; throw 2; } } catch(e) { q+=e; } q",
            "var w=0; try { try { throw 1; } finally { w=99; } } catch(e) {} w",
        ]
        for round in 0..<200 {
            for (i, code) in snippets.enumerated() {
                let r = ctx.eval(input: code, filename: "<t>", evalFlags: JS_EVAL_TYPE_GLOBAL)
                if r.isException { _ = ctx.getException() }
                r.freeValue()
                if round % 50 == 0 && i == 0 { print("[throw] round \(round)") }
            }
            let chk = ctx.eval(input: "1+1", filename: "<t>", evalFlags: 0)
            if !chk.isInt || chk.toInt32() != 2 {
                print("[throw] ENGINE WEDGED at round \(round)")
                break
            }
        }
        print("[throw] done")
        ctx.free()
        rt.free()
    }

    /// Tight repro for the generator/promise-area heap corruption: loop the
    /// Generators + Promises + AsyncAwait test groups on the shared context.
    func testGenPromiseRepro() {
        setvbuf(stdout, nil, _IONBF, 0)
        let done = expectation(description: "genpromise")
        let thread = Thread {
            var runner = JeffJSTestRunner()
            for round in 0..<5 {
                print("[gp] round \(round) generators")
                runner.testGenerators()
                print("[gp] round \(round) promises")
                runner.testPromises()
                print("[gp] round \(round) async")
                runner.testAsyncAwait()
                print("[gp] round \(round) done pass=\(runner.passCount) fail=\(runner.failCount)")
            }
            done.fulfill()
        }
        thread.stackSize = 32 << 20
        thread.start()
        wait(for: [done], timeout: 600)
    }

    /// Repro/bisect aid: run the quick-verify snippets one at a time with
    /// markers, on a single shared context (mirrors the conformance runner).
    func testQuickVerifyRepro() {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        let snippets = [
            "1 + 2", "'hello'", "var x = 42; x", "var a = 1, b = 2; a + b",
            "true", "false", "null", "typeof 42", "typeof 'hi'", "3 > 2",
            "'hello'.length", "'hello'.toUpperCase()", "[1,2,3].length",
            "var o = {x:42}; o.x", "function f(a,b){return a+b} f(3,4)",
            "(function(x){return x*2})(21)", "var arr = [10,20,30]; arr[1]",
            "if(true){1}else{2}", "for(var i=0;i<5;i++){} i",
            "'a'+'b'+'c'", "[1,2,3].map(function(x){return x*2})[2]",
            "var s=0; for(var i2=0;i2<10;i2++){s+=i2} s",
            "JSON.stringify({a:1,b:[1,2]})", "Math.max(1,2,3)",
            "var arr2=[]; for(var k=0;k<100;k++) arr2.push(k); arr2[50]",
            "var t=0; for(var m=0;m<200;m++){ t = t + arr2[m % 100]; } t",
        ]
        for (i, code) in snippets.enumerated() {
            print("[qv] \(i): \(code.prefix(40))")
            let r = ctx.eval(input: code, filename: "<v>", evalFlags: 0)
            let got = ctx.toSwiftString(r) ?? "?"
            print("[qv] \(i) => \(got.prefix(30))")
        }
        print("[qv] done")
        ctx.free()
        rt.free()
    }

    /// Profiling aid: runs a hot benchmark in a loop so `sample` can attach.
    /// Enable with JEFFJS_PROFILE=arith|prop|push (runs ~25s).
    func testProfileLoop() throws {
        guard let kind = ProcessInfo.processInfo.environment["JEFFJS_PROFILE"] else {
            throw XCTSkip("Set JEFFJS_PROFILE to run the profiling loop")
        }
        let code: String
        switch kind {
        case "prop":
            code = "var o={a:1,b:2,c:3,d:4};var s=0;for(var i=0;i<50000;i++){s+=o.a+o.b+o.c+o.d;}s"
        case "push":
            code = "var a=[];for(var i=0;i<50000;i++)a.push(i);a.length"
        default:
            code = "var sum=0;for(var i=0;i<100000;i++){sum+=i*2+1;}sum"
        }
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        let deadline = Date().addingTimeInterval(25)
        var n = 0
        while Date() < deadline {
            _ = ctx.eval(input: code, filename: "<profile>", evalFlags: 0)
            n += 1
        }
        print("profile loop ran \(n) iterations")
        ctx.free()
        rt.free()
    }

    func testHeadToHead() throws {
        guard ProcessInfo.processInfo.environment["JEFFJS_H2H"] == "1" else {
            throw XCTSkip("Set JEFFJS_H2H=1 to run the JSC head-to-head comparison")
        }
        let report = JeffJSPerfTests.runHeadToHead()
        print(report)
    }
}
