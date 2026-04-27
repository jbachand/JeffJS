// JeffJSPerfTests.swift
// JeffJS — Performance benchmarks for NaN-boxing, SIMD strings, inline caching,
// Metal GC, and GPU regex.
//
// Usage: let report = JeffJSPerfTests.runAll()
// Each benchmark runs N iterations and reports median time in microseconds.

import Foundation
@testable import JeffJS
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

// MARK: - Timing utility

private func measureMicroseconds(_ iterations: Int = 1, _ body: () -> Void) -> Double {
    // Warmup
    body()

    var times: [Double] = []
    times.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let start = CFAbsoluteTimeGetCurrent()
        body()
        let end = CFAbsoluteTimeGetCurrent()
        times.append((end - start) * 1_000_000) // microseconds
    }
    times.sort()
    return times[times.count / 2] // median
}

// MARK: - JeffJSPerfTests

struct JeffJSPerfTests {

    // MARK: - String hashing benchmark

    /// Benchmark: hash a 10KB string 1000 times.
    /// Tests the 4x-unrolled polynomial hash vs per-byte iteration.
    static func benchStringHash() -> (name: String, microseconds: Double) {
        let data = [UInt8](repeating: 0x41, count: 10_000) // 10KB of 'A's
        let str = JeffJSString(refCount: 1, len: data.count, isWideChar: false,
                               storage: .str8(data))
        let us = measureMicroseconds(20) {
            for _ in 0..<1000 {
                _ = jeffJS_computeHash(str: str)
            }
        }
        return ("StringHash(10KB×1000)", us)
    }

    /// Benchmark: hash a short string (32 bytes) 100K times.
    /// Tests overhead for common property name hashing.
    static func benchStringHashShort() -> (name: String, microseconds: Double) {
        let data = Array("constructor_prototype_".utf8)
        let str = JeffJSString(refCount: 1, len: data.count, isWideChar: false,
                               storage: .str8(data))
        let us = measureMicroseconds(20) {
            for _ in 0..<100_000 {
                _ = jeffJS_computeHash(str: str)
            }
        }
        return ("StringHash(32B×100K)", us)
    }

    // MARK: - String comparison benchmark

    /// Benchmark: compare two equal 10KB strings 1000 times.
    /// Tests memcmp fast path.
    static func benchStringCompare() -> (name: String, microseconds: Double) {
        let data = [UInt8](repeating: 0x42, count: 10_000)
        let s1 = JeffJSString(refCount: 1, len: data.count, isWideChar: false,
                               storage: .str8(data))
        let s2 = JeffJSString(refCount: 1, len: data.count, isWideChar: false,
                               storage: .str8(data))
        let us = measureMicroseconds(20) {
            for _ in 0..<1000 {
                _ = jeffJS_stringEquals(s1: s1, s2: s2)
            }
        }
        return ("StringCompare(10KB×1000)", us)
    }

    /// Benchmark: compare two different strings that differ at the last byte.
    /// Tests worst-case comparison.
    static func benchStringCompareMismatch() -> (name: String, microseconds: Double) {
        var data1 = [UInt8](repeating: 0x43, count: 10_000)
        var data2 = [UInt8](repeating: 0x43, count: 10_000)
        data2[9999] = 0x44 // differ at last byte
        let s1 = JeffJSString(refCount: 1, len: data1.count, isWideChar: false,
                               storage: .str8(data1))
        let s2 = JeffJSString(refCount: 1, len: data2.count, isWideChar: false,
                               storage: .str8(data2))
        let us = measureMicroseconds(20) {
            for _ in 0..<1000 {
                _ = jeffJS_stringEquals(s1: s1, s2: s2)
            }
        }
        return ("StringCompareMismatch(10KB×1000)", us)
    }

    // MARK: - String concat benchmark

    /// Benchmark: concatenate many small strings.
    static func benchStringConcat() -> (name: String, microseconds: Double) {
        let small = JeffJSString(swiftString: "hello world! ")
        let us = measureMicroseconds(10) {
            var result = JeffJSValue.makeString(JeffJSString(swiftString: ""))
            for _ in 0..<1000 {
                result = jeffJS_concatStrings(s1: result, s2: JeffJSValue.makeString(small))
            }
        }
        return ("StringConcat(×1000)", us)
    }

    // MARK: - Value type check benchmark

    /// Benchmark: type checking 1M values using NaN-boxed bit operations.
    static func benchValueTypeCheck() -> (name: String, microseconds: Double) {
        let values: [JeffJSValue] = [
            .newInt32(42), .newFloat64(3.14), .newBool(true), .null, .undefined,
            .makeString(JeffJSString(swiftString: "test")), .exception
        ]
        let us = measureMicroseconds(20) {
            var count = 0
            for _ in 0..<142_857 { // ~1M checks (7 values × 142857)
                for v in values {
                    if v.isInt { count += 1 }
                    if v.isFloat64 { count += 1 }
                    if v.isString { count += 1 }
                    if v.isObject { count += 1 }
                    if v.isNull { count += 1 }
                    if v.isBool { count += 1 }
                    if v.isUndefined { count += 1 }
                }
            }
            _ = count // prevent optimization
        }
        return ("ValueTypeCheck(1M)", us)
    }

    /// Benchmark: value extraction 1M times.
    static func benchValueExtract() -> (name: String, microseconds: Double) {
        let intVal = JeffJSValue.newInt32(42)
        let floatVal = JeffJSValue.newFloat64(3.14)
        let boolVal = JeffJSValue.newBool(true)
        let us = measureMicroseconds(20) {
            var sum: Double = 0
            for _ in 0..<333_333 {
                sum += Double(intVal.toInt32())
                sum += floatVal.toFloat64()
                sum += boolVal.toBool() ? 1.0 : 0.0
            }
            _ = sum
        }
        return ("ValueExtract(1M)", us)
    }

    // MARK: - Inline cache benchmark

    /// Benchmark: property access with inline cache (via eval).
    /// Measures the IC hit rate benefit on repeated property reads.
    static func benchInlineCache() -> (name: String, microseconds: Double) {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        // Warm up the IC
        _ = ctx.eval(input: """
            var obj = { x: 1, y: 2, z: 3 };
            var sum = 0;
            for (var i = 0; i < 10000; i++) {
                sum += obj.x + obj.y + obj.z;
            }
            sum
        """, filename: "<perf>", evalFlags: 0)

        let us = measureMicroseconds(10) {
            let result = ctx.eval(input: """
                var obj2 = { a: 1, b: 2, c: 3, d: 4 };
                var s = 0;
                for (var i = 0; i < 50000; i++) {
                    s += obj2.a + obj2.b + obj2.c + obj2.d;
                }
                s
            """, filename: "<perf>", evalFlags: 0)
            _ = result
        }
        ctx.free()
        rt.free()
        return ("InlineCachePropAccess(50K×4)", us)
    }

    // MARK: - Arithmetic benchmark

    /// Benchmark: tight arithmetic loop (tests interpreter dispatch + NaN-boxing overhead).
    static func benchArithmetic() -> (name: String, microseconds: Double) {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        let us = measureMicroseconds(10) {
            let result = ctx.eval(input: """
                var sum = 0;
                for (var i = 0; i < 100000; i++) {
                    sum += i * 2 + 1;
                }
                sum
            """, filename: "<perf>", evalFlags: 0)
            _ = result
        }
        ctx.free()
        rt.free()
        return ("ArithmeticLoop(100K)", us)
    }

    // MARK: - Array push benchmark

    /// Benchmark: push 50K integers into an array.
    /// Tests the call_method fast path for Array.prototype.push.
    static func benchArrayPush() -> (name: String, microseconds: Double) {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        let us = measureMicroseconds(10) {
            let result = ctx.eval(input: """
                var arr = [];
                for (var i = 0; i < 50000; i++) arr.push(i);
                arr.length
            """, filename: "<perf>", evalFlags: 0)
            _ = result
        }
        ctx.free()
        rt.free()
        return ("ArrayPush(50K)", us)
    }

    // MARK: - GC benchmark

    /// Benchmark: GC with many objects (tests CPU GC path, or Metal if available).
    static func benchGC() -> (name: String, microseconds: Double) {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        // Create many objects to stress GC
        _ = ctx.eval(input: """
            var arr = [];
            for (var i = 0; i < 5000; i++) {
                arr.push({ value: i, next: arr[i-1] || null });
            }
            arr.length
        """, filename: "<perf>", evalFlags: 0)

        let us = measureMicroseconds(5) {
            runGC(rt)
        }
        ctx.free()
        rt.free()
        return ("GC(5K objects)", us)
    }

    /// Benchmark: GC with large heap to test Metal GC threshold.
    static func benchGCLarge() -> (name: String, microseconds: Double) {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        _ = ctx.eval(input: """
            var arr = [];
            for (var i = 0; i < 20000; i++) {
                arr.push({ v: i, ref: arr[Math.max(0, i-1)] });
            }
            arr.length
        """, filename: "<perf>", evalFlags: 0)

        let us = measureMicroseconds(3) {
            runGC(rt)
        }
        ctx.free()
        rt.free()
        return ("GC(20K objects)", us)
    }

    // MARK: - Regex benchmark

    /// Benchmark: regex global match on a large string.
    static func benchRegexGlobal() -> (name: String, microseconds: Double) {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        let us = measureMicroseconds(5) {
            let result = ctx.eval(input: """
                var s = "";
                for (var i = 0; i < 2000; i++) s += "hello world foo bar ";
                var matches = s.match(/foo/g);
                matches ? matches.length : 0
            """, filename: "<perf>", evalFlags: 0)
            _ = result
        }
        ctx.free()
        rt.free()
        return ("RegexGlobal(/foo/g on 40KB)", us)
    }

    /// Benchmark: regex with character class on large input.
    static func benchRegexCharClass() -> (name: String, microseconds: Double) {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        let us = measureMicroseconds(5) {
            let result = ctx.eval(input: """
                var s = "";
                for (var i = 0; i < 1000; i++) s += "abc123def456ghi789 ";
                var matches = s.match(/[0-9]+/g);
                matches ? matches.length : 0
            """, filename: "<perf>", evalFlags: 0)
            _ = result
        }
        ctx.free()
        rt.free()
        return ("RegexCharClass(/[0-9]+/g on 20KB)", us)
    }

    // MARK: - Atom table benchmark

    /// Benchmark: atom table lookup (property name interning).
    static func benchAtomLookup() -> (name: String, microseconds: Double) {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        // Pre-populate atom table with many entries
        _ = ctx.eval(input: """
            var obj = {};
            for (var i = 0; i < 500; i++) {
                obj["prop_" + i] = i;
            }
        """, filename: "<perf>", evalFlags: 0)

        let us = measureMicroseconds(10) {
            let result = ctx.eval(input: """
                var s = 0;
                for (var i = 0; i < 10000; i++) {
                    s += obj["prop_" + (i % 500)];
                }
                s
            """, filename: "<perf>", evalFlags: 0)
            _ = result
        }
        ctx.free()
        rt.free()
        return ("AtomLookup(10K lookups)", us)
    }

    // MARK: - sameTag benchmark

    /// Benchmark: sameTag comparison (used by all equality operations).
    static func benchSameTag() -> (name: String, microseconds: Double) {
        let pairs: [(JeffJSValue, JeffJSValue)] = [
            (.newInt32(1), .newInt32(2)),
            (.newFloat64(1.0), .newFloat64(2.0)),
            (.newBool(true), .newBool(false)),
            (.null, .null),
            (.newInt32(1), .newFloat64(1.0)),
            (.newInt32(1), .null),
        ]
        let us = measureMicroseconds(20) {
            var count = 0
            for _ in 0..<166_666 { // ~1M comparisons
                for (a, b) in pairs {
                    if JeffJSValue.sameTag(a, b) { count += 1 }
                }
            }
            _ = count
        }
        return ("SameTag(1M comparisons)", us)
    }

    // MARK: - JSON parse benchmark

    /// Benchmark: JSON.parse on a medium object.
    static func benchJSONParse() -> (name: String, microseconds: Double) {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        let us = measureMicroseconds(5) {
            let result = ctx.eval(input: """
                var json = '{"users":[';
                for (var i = 0; i < 100; i++) {
                    if (i > 0) json += ',';
                    json += '{"id":' + i + ',"name":"user' + i + '","active":true}';
                }
                json += ']}';
                var obj = JSON.parse(json);
                obj.users.length
            """, filename: "<perf>", evalFlags: 0)
            _ = result
        }
        ctx.free()
        rt.free()
        return ("JSONParse(100 objects)", us)
    }

    // MARK: - JSC (JIT-disabled) vs JeffJS head-to-head

    /// Shared JS benchmarks run through both engines for comparison.
    private static let headToHeadTests: [(name: String, code: String)] = [
        ("Arithmetic 100K", """
            var sum = 0;
            for (var i = 0; i < 100000; i++) {
                sum += i * 2 + 1;
            }
            sum
        """),
        ("PropertyAccess 50K", """
            var obj = { a: 1, b: 2, c: 3, d: 4 };
            var s = 0;
            for (var i = 0; i < 50000; i++) {
                s += obj.a + obj.b + obj.c + obj.d;
            }
            s
        """),
        ("StringConcat 5K", """
            var s = "";
            for (var i = 0; i < 5000; i++) {
                s += "x";
            }
            s.length
        """),
        ("ArrayPush 50K", """
            var arr = [];
            for (var i = 0; i < 50000; i++) {
                arr.push(i);
            }
            arr.length
        """),
        ("FunctionCall 50K", """
            function add(a, b) { return a + b; }
            var s = 0;
            for (var i = 0; i < 50000; i++) {
                s = add(s, 1);
            }
            s
        """),
        ("ObjectCreate 10K", """
            var arr = [];
            for (var i = 0; i < 10000; i++) {
                arr.push({ x: i, y: i * 2, z: "hello" });
            }
            arr.length
        """),
        ("JSON parse+stringify", """
            var json = '{"users":[';
            for (var i = 0; i < 50; i++) {
                if (i > 0) json += ',';
                json += '{"id":' + i + ',"name":"user' + i + '"}';
            }
            json += ']}';
            var obj = JSON.parse(json);
            JSON.stringify(obj).length
        """),
        ("Fibonacci(25)", """
            function fib(n) {
                if (n <= 1) return n;
                return fib(n - 1) + fib(n - 2);
            }
            fib(25)
        """),
        ("Closures 10K", """
            function make(x) { return function() { return x + 1; }; }
            var s = 0;
            for (var i = 0; i < 10000; i++) {
                s += make(i)();
            }
            s
        """),
        ("Regex /\\d+/g on 10KB", """
            var s = "";
            for (var i = 0; i < 500; i++) s += "abc123def456 ";
            var m = s.match(/\\d+/g);
            m ? m.length : 0
        """),
    ]

    /// Run a single JS snippet through JeffJS, return time in microseconds.
    private static func timeJeffJS(_ code: String, iterations: Int = 5) -> Double {
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        // warmup
        _ = ctx.eval(input: code, filename: "<bench>", evalFlags: 0)
        let us = measureMicroseconds(iterations) {
            _ = ctx.eval(input: code, filename: "<bench>", evalFlags: 0)
        }
        ctx.free()
        rt.free()
        return us
    }

    #if canImport(JavaScriptCore)
    /// Run a single JS snippet through JSC (JIT disabled via env), return time in microseconds.
    /// Returns nil if JSC is unavailable or crashes.
    private static func timeJSC(_ code: String, iterations: Int = 5) -> Double? {
        // Disable JIT — forces JSC to use LLInt (interpreter only)
        // Must be set before first JSContext creation to take effect.
        setenv("JSC_useJIT", "0", 1)
        setenv("JSC_useDFGJIT", "0", 1)
        setenv("JSC_useFTLJIT", "0", 1)

        guard let jsContext = JSContext() else { return nil }
        // Install exception handler to avoid crashes
        jsContext.exceptionHandler = { _, _ in }

        // warmup
        let warmup = jsContext.evaluateScript(code)
        if warmup == nil || warmup!.isUndefined { /* ok, some scripts may return undefined */ }

        let us = measureMicroseconds(iterations) {
            _ = jsContext.evaluateScript(code)
        }
        return us
    }
    #else
    private static func timeJSC(_ code: String, iterations: Int = 5) -> Double? {
        return nil
    }
    #endif

    /// Run all head-to-head benchmarks and return formatted report.
    static func runHeadToHead() -> String {
        var report = "================================================\n"
        report += "JSC (JIT disabled) vs JeffJS — Head to Head\n"
        report += "================================================\n"
        report += "  Benchmark                      JSC(noJIT)       JeffJS    Ratio\n"
        report += "  " + String(repeating: "-", count: 62) + "\n"

        func fmtTime(_ us: Double) -> String {
            if us >= 1_000_000 { return "\(Int(us / 10000) / 100).s" }
            if us >= 1_000 { return "\(Int(us / 100) / 10).\(Int(us / 100) % 10) ms" }
            return "\(Int(us)) us"
        }

        print("[h2h] Starting \(headToHeadTests.count) benchmarks...")
        fflush(stdout)
        for test in headToHeadTests {
            print("  [h2h] \(test.name): JeffJS...", terminator: "")
            fflush(stdout)
            let jeffTime = timeJeffJS(test.code)
            print(" \(Int(jeffTime))us, JSC...", terminator: "")
            fflush(stdout)
            let jscTime = timeJSC(test.code)
            print(" done")

            if let jscTime = jscTime {
                let ratio = jeffTime / max(jscTime, 1)
                let ratioStr: String
                if ratio < 1.0 {
                    ratioStr = "\(Int(10.0 / ratio) / 10).\(Int(10.0 / ratio) % 10)x faster"
                } else {
                    ratioStr = "\(Int(ratio * 10) / 10).\(Int(ratio * 10) % 10)x slower"
                }
                let name = test.name.padding(toLength: 28, withPad: " ", startingAt: 0)
                report += "  \(name) \(fmtTime(jscTime).padding(toLength: 12, withPad: " ", startingAt: 0)) \(fmtTime(jeffTime).padding(toLength: 12, withPad: " ", startingAt: 0)) \(ratioStr)\n"
            } else {
                let name = test.name.padding(toLength: 28, withPad: " ", startingAt: 0)
                report += "  \(name) N/A          \(fmtTime(jeffTime).padding(toLength: 12, withPad: " ", startingAt: 0)) -\n"
            }
        }
        report += "================================================\n"
        return report
    }

    // MARK: - Run all benchmarks

    static func runAll() -> String {
        var report = "================================================\n"
        report += "JeffJS Performance Benchmarks\n"
        report += "================================================\n"

        let benchmarks: [(String, Double)] = [
            benchStringHash(),
            benchStringHashShort(),
            benchStringCompare(),
            benchStringCompareMismatch(),
            benchStringConcat(),
            benchValueTypeCheck(),
            benchValueExtract(),
            benchSameTag(),
            benchInlineCache(),
            benchArithmetic(),
            benchJSONParse(),
            benchArrayPush(),
            benchGC(),
            benchGCLarge(),
            benchRegexGlobal(),
            benchRegexCharClass(),
            benchAtomLookup(),
        ]

        for (name, us) in benchmarks {
            let usStr: String
            if us >= 1_000_000 {
                usStr = String(format: "%.1f s", us / 1_000_000)
            } else if us >= 1_000 {
                usStr = String(format: "%.1f ms", us / 1_000)
            } else {
                usStr = String(format: "%.0f us", us)
            }
            report += "  \(name): \(usStr)\n"
        }

        report += "================================================\n"
        return report
    }

    /// Run all benchmarks including JSC head-to-head comparison.
    static func runAllWithJSC() -> String {
        let allReport = runAll()
        print(allReport)
        fflush(stdout)
        let h2hReport = runHeadToHead()
        return h2hReport
    }
}
