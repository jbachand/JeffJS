// StorageBridgeTests.swift
// JeffJS — localStorage/sessionStorage semantics on JeffJSStorageBridge.
//
// Regression: a missing key used to come back as "" from the native bridge, so
// `JSON.parse(localStorage.getItem(k))` threw "SyntaxError: JSON.parse:
// unexpected end of data" instead of yielding null (browsers/JSC return null).
//
// Usage:
//   swift test --filter StorageBridgeTests

import XCTest
@testable import JeffJS

final class StorageBridgeTests: XCTestCase {

    @MainActor
    private func makeEnvironment() -> JeffJSEnvironment {
        let scope = "jeffjs.test.\(UUID().uuidString)"
        return JeffJSEnvironment(configuration: .init(storageScope: scope))
    }

    @MainActor
    private func evalString(_ env: JeffJSEnvironment, _ js: String,
                            file: StaticString = #filePath, line: UInt = #line) -> String {
        switch env.eval(js) {
        case .success(let s): return s ?? "undefined"
        case .exception(let msg):
            XCTFail("JS threw: \(msg) — while evaluating: \(js)", file: file, line: line)
            return "<exception>"
        }
    }

    @MainActor
    func testMissingKeyReturnsNull() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, "String(localStorage.getItem('missing') === null)"), "true")
        XCTAssertEqual(evalString(env, "String(JSON.parse(localStorage.getItem('missing')) === null)"), "true")
        XCTAssertEqual(evalString(env, "String(sessionStorage.getItem('missing') === null)"), "true")
    }

    @MainActor
    func testStoredEmptyStringIsNotNull() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        localStorage.setItem('empty', '');
        String(localStorage.getItem('empty') === '' && localStorage.getItem('empty') !== null);
        """), "true")
    }

    @MainActor
    func testRemovedKeyReturnsNullAndKeyOutOfRangeIsNull() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        localStorage.setItem('gone', 'v');
        localStorage.removeItem('gone');
        String(localStorage.getItem('gone') === null);
        """), "true")
        XCTAssertEqual(evalString(env, "String(localStorage.key(999) === null && localStorage.key(-1) === null)"), "true")
    }

    @MainActor
    func testJSONParseOfEmptyStringStillThrows() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        (function () { try { JSON.parse(''); return 'no-throw'; } catch (e) { return e.name; } })();
        """), "SyntaxError")
    }

    @MainActor
    func testRoundTripAndJSONParse() {
        let env = makeEnvironment()
        XCTAssertEqual(evalString(env, """
        localStorage.setItem('obj', JSON.stringify({ a: 1 }));
        String(JSON.parse(localStorage.getItem('obj')).a);
        """), "1")
    }
}
