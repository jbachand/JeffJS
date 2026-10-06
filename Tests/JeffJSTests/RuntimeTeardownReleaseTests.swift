// RuntimeTeardownReleaseTests.swift
// JeffJS — freeing a context and its runtime must give the whole JS heap back:
// objects, strings and function bytecode still referenced from the global object
// (a page's heap when the host tears its engine down) are deallocated.
//
//   swift test -c release --filter RuntimeTeardownReleaseTests

import XCTest
@testable import JeffJS

final class RuntimeTeardownReleaseTests: XCTestCase {

    func testFreeReleasesLiveHeap() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["JEFFJS_ZOMBIES"] == "1", "zombie mode keeps every freed object allocated on purpose")
        weak var object: JeffJSObject?
        weak var function: JeffJSObject?
        weak var string: JeffJSStringBase?
        weak var body: JeffJSFunctionBytecode?
        do {
            let rt = JeffJSRuntime()
            let ctx = rt.newContext()
            let v = ctx.eval(input: """
                // `s` is assigned, not an object-literal property: a literal's property
                // value keeps one count too many (a refcount leak of its own, open), and
                // teardown frees by counts — such a string still outlives the runtime.
                var keep = { list: [] };
                keep.s = 'abc'.repeat(50);
                for (var i = 0; i < 1000; i++) keep.list.push({ i: i, t: 'v' + i });
                keep.f = function (x) { return x + keep.s.length };
                keep.self = keep;   // a cycle
                keep
                """, filename: "<teardown>", evalFlags: 0)
            XCTAssertFalse(v.isException)
            object = v.toObject()
            let f = ctx.getPropertyStr(obj: v, name: "f")
            function = f.toObject()
            if case .bytecodeFunc(let fb, _, _)? = function?.payload { body = fb }
            let s = ctx.getPropertyStr(obj: v, name: "s")
            string = s.stringBase
            s.freeValue(); f.freeValue(); v.freeValue()
            XCTAssertNotNil(object); XCTAssertNotNil(function); XCTAssertNotNil(string); XCTAssertNotNil(body)
            ctx.free()
            rt.free()
        }
        XCTAssertNil(object, "a live object outlived its runtime")
        XCTAssertNil(function, "a live function outlived its runtime")
        XCTAssertNil(string, "a live string outlived its runtime")
        XCTAssertNil(body, "a live function body outlived its runtime")
    }

    /// A lazily compiled function's body is parsed and thrown away (only its free
    /// names are kept); the string literals the parser put in its constant pool —
    /// and in the pools of the definitions nested in it — own one reference each,
    /// which the drop must give back (JeffJSCompiler.releaseDroppedConstants). It
    /// used to empty the arrays only: every literal of every lazy function leaked
    /// at parse time, beyond the reach of the runtime's teardown (wikipedia: 36 k
    /// strings per page view).
    func testDroppedLazyDefinitionReleasesItsLiterals() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["JEFFJS_ZOMBIES"] == "1", "zombie mode keeps every freed object allocated on purpose")
        weak var outerLiteral: JeffJSStringBase?
        weak var innerLiteral: JeffJSStringBase?
        do {
            let outer = JeffJSFunctionDefCompiler()
            let inner = JeffJSFunctionDefCompiler()
            outer.childFunctions = [inner]
            let a = JeffJSValue.makeString(JeffJSString(swiftString: "outer literal " + String(repeating: "a", count: 40)))
            let b = JeffJSValue.makeString(JeffJSString(swiftString: "inner literal " + String(repeating: "b", count: 40)))
            outerLiteral = a.stringBase
            innerLiteral = b.stringBase
            outer.cpool = [.undefined, a, JeffJSValue.newFloat64(1.5)]
            inner.cpool = [b]
            XCTAssertNotNil(outerLiteral); XCTAssertNotNil(innerLiteral)
            JeffJSCompiler.releaseDroppedConstants(outer)
            XCTAssertTrue(outer.cpool.isEmpty); XCTAssertTrue(inner.cpool.isEmpty)
        }
        XCTAssertNil(outerLiteral, "a dropped lazy body's literal leaked")
        XCTAssertNil(innerLiteral, "a literal of a definition nested in a dropped lazy body leaked")
    }
}
