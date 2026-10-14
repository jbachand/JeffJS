// TypedArrayFastPathTests.swift
// JeffJS — integer-indexed typed-array reads/writes take a payload-free fast path
// (JeffJSObject.typedArrayGet/typedArraySet); results must equal the general path's.

import XCTest
@testable import JeffJS

final class TypedArrayFastPathTests: XCTestCase {
    @MainActor
    private func eval(_ js: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let env = JeffJSEnvironment(configuration: .init(storageScope: "jeffjs.test.typedarrayfast"))
        switch env.eval(js) {
        case .success(let s): return s ?? "undefined"
        case .exception(let m): XCTFail("JS threw: \(m)", file: file, line: line); return "<exception>"
        }
    }

    @MainActor
    func testConversionsMatchSpec() {
        // Each store converts like ES ToInt8/ToUint8Clamp/ToInt32/... and reads back.
        XCTAssertEqual(eval("var a=new Int8Array(1); a[0]=200; a[0]"), "-56")
        XCTAssertEqual(eval("var a=new Uint8ClampedArray(1); a[0]=254.4; a[0]"), "254")
        XCTAssertEqual(eval("var a=new Uint8ClampedArray(1); a[0]=-3; a[0]"), "0")
        XCTAssertEqual(eval("var a=new Uint8ClampedArray(1); a[0]=300; a[0]"), "255")
        XCTAssertEqual(eval("var a=new Uint16Array(1); a[0]=-1; a[0]"), "65535")
        XCTAssertEqual(eval("var a=new Uint32Array(1); a[0]=-1; a[0]"), "4294967295")
        XCTAssertEqual(eval("var a=new Int32Array(1); a[0]=4294967297; a[0]"), "1")
        XCTAssertEqual(eval("var a=new Float32Array(1); a[0]=0.1; a[0]"), "0.10000000149011612")
        XCTAssertEqual(eval("var a=new Float64Array(1); a[0]=NaN; String(a[0])"), "NaN")
        XCTAssertEqual(eval("var a=new Int32Array(1); a[0]=Infinity; a[0]"), "0")
    }

    @MainActor
    func testBoundsViewsAndDetach() {
        XCTAssertEqual(eval("var a=new Uint8Array(2); a[5]=9; String(a[5])+a.length"), "undefined2")
        XCTAssertEqual(eval("var b=new ArrayBuffer(16); var v=new Int16Array(b,4,3); v[2]=-2; new Uint8Array(b)[8]+','+new Uint8Array(b)[9]"), "254,255")
        XCTAssertEqual(eval("var b=new ArrayBuffer(8); var u=new Uint8Array(b); u[0]=1; b.transfer(); String(u[0])+(u[0]=5)"), "undefined5")
        XCTAssertEqual(eval("var a=new BigInt64Array(1); a[0]=7n; String(a[0])"), "7")
    }
}
