// StringCodeUnitPointerTests.swift
// JeffJS — a flat string's borrowed code-unit pointers (`units8` / `units16`,
// JeffJS issue #1 step 5) are computed from the layout of the array the string
// holds, not stored. This pins that computation against the array's own
// `withUnsafeBufferPointer` for every way a flat string gets its characters,
// so a change in the standard library's array layout fails here first.

import XCTest
@testable import JeffJS

final class StringCodeUnitPointerTests: XCTestCase {

    private func check(_ s: JeffJSString, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        switch s.storage {
        case .str8(let a):
            XCTAssertFalse(s.isWideChar, label, file: file, line: line)
            XCTAssertNil(s.units16, label, file: file, line: line)
            if s.len == 0 { XCTAssertNil(s.units8, label, file: file, line: line); return }
            let want = a.withUnsafeBufferPointer { $0.baseAddress }
            XCTAssertEqual(s.units8, want, "\(label): 8-bit pointer", file: file, line: line)
            for i in 0..<s.len { XCTAssertEqual(s.unit(at: i), UInt32(a[i]), "\(label)[\(i)]", file: file, line: line) }
        case .str16(let a):
            XCTAssertTrue(s.isWideChar, label, file: file, line: line)
            XCTAssertNil(s.units8, label, file: file, line: line)
            if s.len == 0 { XCTAssertNil(s.units16, label, file: file, line: line); return }
            let want = a.withUnsafeBufferPointer { $0.baseAddress }
            XCTAssertEqual(s.units16, want, "\(label): 16-bit pointer", file: file, line: line)
            for i in 0..<s.len { XCTAssertEqual(s.unit(at: i), UInt32(a[i]), "\(label)[\(i)]", file: file, line: line) }
        }
    }

    func testPointersMatchTheArrays() {
        check(JeffJSString(swiftString: ""), "empty")
        check(JeffJSString(swiftString: "a"), "one byte")
        check(JeffJSString(swiftString: "hello, world"), "ascii")
        check(JeffJSString(swiftString: String(repeating: "xy", count: 5000)), "long ascii")
        check(JeffJSString(swiftString: "caf\u{e9}"), "latin-1")
        check(JeffJSString(swiftString: "\u{3b1}\u{3b2}\u{3b3}"), "greek")
        check(JeffJSString(swiftString: "a\u{1F600}b"), "surrogates")
        check(JeffJSString(refCount: 1, len: 3, isWideChar: false, storage: .str8([1, 2, 3])), "from bytes")
        check(JeffJSString(refCount: 1, len: 2, isWideChar: true, storage: .str16([0x3b1, 0x41])), "from units")
        check(jeffJS_allocString(maxLen: 17, isWideChar: false)!, "allocated 8")
        check(jeffJS_allocString(maxLen: 9, isWideChar: true)!, "allocated 16")
        check(jeffJS_allocString(maxLen: 0, isWideChar: true)!, "allocated empty")
    }

    func testPointersFollowInPlaceAppends() {
        let s = JeffJSString(swiftString: "ab")
        for i in 0..<200 {
            s.appendInPlace(JeffJSString(swiftString: "chunk\(i)"))
            check(s, "after 8-bit append \(i)")
        }
        s.appendInPlace(JeffJSString(swiftString: "\u{3c9}"))   // widens to 16-bit
        check(s, "after widening")
        for i in 0..<50 { s.appendInPlace(JeffJSString(swiftString: i & 1 == 0 ? "z" : "\u{3b1}")); check(s, "after 16-bit append \(i)") }
        let t = JeffJSString(swiftString: "x"); t.storage = .str16([0x41, 0x3b2]); XCTAssertNotNil(t)
    }

    func testFlatStringStaysCompact() {
        XCTAssertLessThanOrEqual(class_getInstanceSize(JeffJSString.self), 48)
    }
}
