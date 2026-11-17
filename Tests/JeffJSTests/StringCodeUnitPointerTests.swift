// StringCodeUnitPointerTests.swift
// JeffJS — a flat string owns its code units in one malloc block (quickjs
// `JSString`; JeffJS issue #1 step 5) and hands out borrowed pointers
// (`units8` / `units16`). This pins the contents, width and pointer rules for
// every way a flat string gets its characters, and the in-place append.

import XCTest
@testable import JeffJS

final class StringCodeUnitPointerTests: XCTestCase {

    /// The string holds exactly `want` at the given width.
    private func check(_ s: JeffJSString, _ want: [UInt16], wide: Bool, _ label: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(s.len, want.count, "\(label): len", file: file, line: line)
        XCTAssertEqual(s.isWideChar, wide, "\(label): width", file: file, line: line)
        if want.isEmpty {
            XCTAssertNil(s.units8, label, file: file, line: line)
            XCTAssertNil(s.units16, label, file: file, line: line)
        } else if wide {
            XCTAssertNil(s.units8, label, file: file, line: line)
            guard let p = s.units16 else { return XCTFail("\(label): no 16-bit pointer", file: file, line: line) }
            XCTAssertEqual(Array(UnsafeBufferPointer(start: p, count: s.len)), want, label, file: file, line: line)
        } else {
            XCTAssertNil(s.units16, label, file: file, line: line)
            guard let p = s.units8 else { return XCTFail("\(label): no 8-bit pointer", file: file, line: line) }
            XCTAssertEqual(Array(UnsafeBufferPointer(start: p, count: s.len)).map { UInt16($0) }, want, label, file: file, line: line)
        }
        for i in 0..<want.count where s.unit(at: i) != UInt32(want[i]) {
            XCTFail("\(label): unit(at: \(i))", file: file, line: line); break
        }
        switch s.storage {
        case .str8(let a): XCTAssertFalse(wide, label, file: file, line: line); XCTAssertEqual(a.map { UInt16($0) }, want, label, file: file, line: line)
        case .str16(let a): XCTAssertTrue(wide, label, file: file, line: line); XCTAssertEqual(a, want, label, file: file, line: line)
        }
        XCTAssertEqual(s.str16, want, "\(label): str16", file: file, line: line)
    }

    private func fromSwift(_ t: String, wide: Bool, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let want: [UInt16] = wide ? Array(t.utf16) : t.unicodeScalars.map { UInt16($0.value) }
        check(JeffJSString(swiftString: t), want, wide: wide, label, file: file, line: line)
    }

    func testEveryCreatorHoldsItsUnits() {
        fromSwift("", wide: false, "empty")
        fromSwift("a", wide: false, "one byte")
        fromSwift("hello, world", wide: false, "ascii")
        fromSwift(String(repeating: "xy", count: 5000), wide: false, "long ascii")
        fromSwift("caf\u{e9}", wide: false, "latin-1")
        fromSwift("\u{3b1}\u{3b2}\u{3b3}", wide: true, "greek")
        fromSwift("a\u{1F600}b", wide: true, "surrogates")
        check(JeffJSString(refCount: 1, len: 3, isWideChar: false, storage: .str8([1, 2, 3])), [1, 2, 3], wide: false, "from bytes")
        check(JeffJSString(refCount: 1, len: 2, isWideChar: true, storage: .str16([0x3b1, 0x41])), [0x3b1, 0x41], wide: true, "from units")
        // `len` shorter than the array takes a prefix; longer zero-fills.
        check(JeffJSString(refCount: 1, len: 2, isWideChar: false, storage: .str8([7, 8, 9])), [7, 8], wide: false, "prefix")
        check(JeffJSString(refCount: 1, len: 4, isWideChar: false, storage: .str8([7])), [7, 0, 0, 0], wide: false, "zero filled")
        check(jeffJS_allocString(maxLen: 17, isWideChar: false)!, [UInt16](repeating: 0, count: 17), wide: false, "allocated 8")
        check(jeffJS_allocString(maxLen: 9, isWideChar: true)!, [UInt16](repeating: 0, count: 9), wide: true, "allocated 16")
        check(jeffJS_allocString(maxLen: 0, isWideChar: true)!, [], wide: true, "allocated empty")
        check(JeffJSString(latin1Count: 3) { $0[0] = 65; $0[1] = 66; $0[2] = 255 }, [65, 66, 255], wide: false, "filled 8")
        check(JeffJSString(utf16Count: 2) { $0[0] = 0x3b1; $0[1] = 0xD83D }, [0x3b1, 0xD83D], wide: true, "filled 16")
        check(JeffJSString(latin1Count: 0) { _ in }, [], wide: false, "filled empty")
        check(JeffJSString(latin1: [1, 2, 3, 4], count: 2), [1, 2], wide: false, "array prefix 8")
        check(JeffJSString(utf16: [0x100, 0x200, 0x300], count: 3), [0x100, 0x200, 0x300], wide: true, "array 16")
    }

    func testInPlaceAppends() {
        let s = JeffJSString(swiftString: "ab")
        var want: [UInt16] = [97, 98]
        for i in 0..<200 {
            let piece = "chunk\(i)"
            s.appendInPlace(JeffJSString(swiftString: piece))
            want += Array(piece.utf16)
            check(s, want, wide: false, "after 8-bit append \(i)")
        }
        s.appendInPlace(JeffJSString(swiftString: ""))
        check(s, want, wide: false, "after an empty append")
        s.appendInPlace(JeffJSString(swiftString: "\u{3c9}"))   // widens to 16-bit
        want.append(0x3c9)
        check(s, want, wide: true, "after widening")
        for i in 0..<50 {
            let piece = i & 1 == 0 ? "zz" : "\u{3b1}"
            s.appendInPlace(JeffJSString(swiftString: piece))
            want += Array(piece.utf16)
            check(s, want, wide: true, "after 16-bit append \(i)")
        }
        // Appending to an empty string of either width.
        let e8 = JeffJSString(swiftString: "")
        e8.appendInPlace(JeffJSString(swiftString: "q")); check(e8, [113], wide: false, "empty += 8")
        let e16 = JeffJSString(swiftString: "")
        e16.appendInPlace(JeffJSString(swiftString: "\u{3b1}")); check(e16, [0x3b1], wide: true, "empty += 16")
        // A string appended to itself.
        let d = JeffJSString(swiftString: "abc")
        d.appendInPlace(d); check(d, [97, 98, 99, 97, 98, 99], wide: false, "self append")
    }

    func testStorageSetterReplacesContentsAndWidth() {
        let t = JeffJSString(swiftString: "x")
        t.storage = .str16([0x41, 0x3b2]); check(t, [0x41, 0x3b2], wide: true, "set 16")
        t.storage = .str8([1, 2, 3]); check(t, [1, 2, 3], wide: false, "set 8")
        t.str8 = []; check(t, [], wide: false, "set empty")
        t.str16 = [9]; check(t, [9], wide: true, "set str16")
    }

    func testFlatStringStaysCompact() {
        XCTAssertLessThanOrEqual(class_getInstanceSize(JeffJSString.self), 48)
    }
}
