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
}
