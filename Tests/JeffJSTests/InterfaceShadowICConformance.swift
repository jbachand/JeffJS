// InterfaceShadowICConformance.swift
// JeffJS — conformance group "InterfaceShadowIC": a property read through the
// inline cache must find the nearest definition on the prototype chain. An
// input's `type` lives on HTMLInputElement.prototype and shadows the generic
// reflector on HTMLElement.prototype; the deep-prototype fill
// (jeffJS_icFillDeep) cached the generic one two levels up whenever the
// depth-1 entry was not made, so the second read at a site gave '' (React's
// isTextInputElement then failed and onChange never fired: Instagram's and
// Facebook's login fields emptied on blur). JeffJS inline cache only (no
// QuickJS counterpart).

import Foundation
import XCTest
@testable import JeffJS

extension JeffJSTestRunner {

    static let interfaceShadowICCases: [(String, String)] = [
        ("an interface prototype's getter shadows the shared one at a cached site",
         #"(function(){ var EP = Object.getPrototypeOf(document.createElement('div')); var HE = Object.create(EP); var HI = Object.create(HE); Object.defineProperty(HE, 'type', { get: function(){ return 'generic'; }, configurable: true }); Object.defineProperty(HI, 'type', { get: function(){ return 'text'; }, configurable: true }); var T = Object.create(EP), C = Object.create(EP); if (typeof __rnSetNodeInterfaces === 'function') __rnSetNodeInterfaces({ input: HI }, HE, T, C); var a = document.createElement('input'), b = document.createElement('input'); if (Object.getPrototypeOf(a) !== HI) return 'no interfaces'; function site(e){ return e.type; } var out = [site(a), site(b), site(a), site(b)].join(); return out === 'text,text,text,text' || out; })()"#),
        ("plain objects: a getter one level up shadows a data property three levels up",
         #"(function(){ var C = { kind: 'deep' }; var B = Object.create(C); var A = Object.create(B); Object.defineProperty(A, 'kind', { get: function(){ return 'near'; }, configurable: true }); var x = Object.create(A), y = Object.create(A); function site(e){ return e.kind; } var out = [site(x), site(y), site(x), site(y)].join(); return out === 'near,near,near,near' || out; })()"#),
    ]

    mutating func testInterfaceShadowIC() {
        var outcomes: [(Bool, String)] = []
        func onMain(_ body: @escaping @JeffJSHostActor () -> Void) {
            if Thread.isMainThread { JeffJSHostActor.assumeIsolated { body() } } else { DispatchQueue.main.sync { JeffJSHostActor.assumeIsolated { body() } } }
        }
        onMain {
            let e = JeffJSEnvironment()
            for (name, js) in JeffJSTestRunner.interfaceShadowICCases {
                switch e.eval(js, filename: "<interface-shadow-ic>") {
                case .success(let v): outcomes.append((v == "true", "InterfaceShadowIC: \(name) -> \(v ?? "undefined")"))
                case .exception(let m): outcomes.append((false, "InterfaceShadowIC: \(name) threw \(m)"))
                }
            }
        }
        for (ok, message) in outcomes { assert(ok, message) }
    }
}

/// The group on its own (`swift test -c release --filter InterfaceShadowICTests`).
final class InterfaceShadowICTests: XCTestCase {
    func testGroup() {
        var r = JeffJSTestRunner()
        r.testInterfaceShadowIC()
        XCTAssertEqual(r.failCount, 0, r.errors.joined(separator: "\n"))
        XCTAssertEqual(r.passCount, JeffJSTestRunner.interfaceShadowICCases.count)
    }
}
