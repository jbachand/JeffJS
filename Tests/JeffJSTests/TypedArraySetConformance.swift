// TypedArraySetConformance.swift
// JeffJS — conformance group "TypedArraySet" (g429 agent, 2026-10-07).
// - %TypedArray%.prototype.set(source, offset) with a source that is not a typed
//   array (ES2024 §23.2.3.26.2 SetTypedArrayFromArrayLike): the elements are read
//   with Get and written with the typed array's [[Set]] (ToNumber / ToBigInt). The
//   path was missing — `u8.set([16, 0, 24], 2)` wrote nothing — so Google's protobuf
//   encoder produced all-zero tags and lengths (its `gs_lp` search parameter).
//   Offsets < 0 and sources that do not fit are RangeErrors (§23.2.3.26 step 6, .1 step 21).
// - Every element write converts with ToNumber / ToBigInt first (§10.4.5.16
//   TypedArraySetElement): `u8[0] = '5'`, `fill('7')`, `Uint8Array.of('3', true)`,
//   `new Uint8Array(['4'])` stored 0 (strings, booleans, null, valueOf objects).
// - crypto.getRandomValues (WebCrypto §10.1.2) overwrites every *byte* of an integer
//   typed array: a Uint32Array used to get one random byte per element (0-255);
//   non-integer arrays are a TypeMismatchError, > 65 536 bytes a QuotaExceededError.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let typedArraySetCases: [(String, String)] = [
        ("set(Array, offset) writes the elements at the offset",
         #"(function(){ var t = new Uint8Array(8); t.set([16, 0, 24, 128, 4], 2); return t.join() === '0,0,16,0,24,128,4,0'; })()"#),
        ("set(Array) defaults the offset to 0; values are converted (ToNumber, modular)",
         #"(function(){ var t = new Uint8Array(4); t.set([1, '2', 3.7]); var u = new Uint16Array(3); u.set([300, 70000, -1]); var i = new Int8Array(2); i.set([200, true]); return t.join() === '1,2,3,0' && u.join() === '300,4464,65535' && i.join() === '-56,1'; })()"#),
        ("set(array-like) and set(string) read length and indices",
         #"(function(){ var t = new Uint8Array(4); t.set({ length: 2, 0: 7, 1: 9 }, 1); var s = new Uint8Array(3); s.set('12'); var n = new Uint8Array(2); n.set(5); return t.join() === '0,7,9,0' && s.join() === '1,2,0' && n.join() === '0,0'; })()"#),
        ("set(Array) on float and BigInt arrays",
         #"(function(){ var f = new Float64Array(3); f.set([1.5, 2.5], 1); var b = new BigInt64Array(2); b.set([5n, -1n]); var ok = false; try { new BigInt64Array(1).set([1]); } catch (e) { ok = e instanceof TypeError; } return f.join() === '0,1.5,2.5' && b.join() === '5,-1' && ok; })()"#),
        ("holes read as undefined (NaN -> 0); getters run in index order",
         #"(function(){ var a = [1, , 3]; var t = new Uint8Array(3); t.set(a); var log = []; var o = { length: 2, get 0(){ log.push(0); return 4; }, get 1(){ log.push(1); return 5; } }; var u = new Uint8Array(2); u.set(o); return t.join() === '1,0,3' && u.join() === '4,5' && log.join() === '0,1'; })()"#),
        ("RangeError: negative offset, source past the end (also for a typed-array source)",
         #"(function(){ function r(f){ try { f(); return false; } catch (e) { return e instanceof RangeError; } } var t = new Uint8Array(4); return r(function(){ t.set([1], -1); }) && r(function(){ t.set([1, 2, 3], 2); }) && r(function(){ t.set([], 5); }) && r(function(){ t.set(new Uint8Array(3), 2); }) && r(function(){ t.set([1], Infinity); }) && t.join() === '0,0,0,0'; })()"#),
        ("set(TypedArray) still copies, overlapping views included",
         #"(function(){ var t = new Uint8Array([1, 2, 3, 4, 5]); t.set(t.subarray(0, 3), 2); var f = new Float32Array(2); f.set(new Int8Array([-3, 7])); return t.join() === '1,2,1,2,3' && f.join() === '-3,7'; })()"#),
        ("element writes convert with ToNumber: [[Set]], fill, of, from, the array-like constructor",
         #"(function(){ var x = new Uint8Array(3); x[0] = '5'; x[1] = true; x[2] = { valueOf: function(){ return 9; } }; var f = new Float64Array(2); f[0] = '1.5'; f[1] = null; var y = new Uint8Array(2).fill('7'); var log = []; var z = new Uint8Array(1); z[5] = { valueOf: function(){ log.push('v'); return 1; } }; var thrown = false; try { x[0] = Symbol(); } catch (e) { thrown = e instanceof TypeError; } return x.join() === '5,1,9' && f.join() === '1.5,0' && y.join() === '7,7' && Uint8Array.from(['3', true]).join() === '3,1' && new Uint8Array(['4', false, '0x10']).join() === '4,0,16' && Uint8Array.of('2', null, '0b11', ' 0o7 ').join() === '2,0,3,7' && log.join() === 'v' && thrown; })()"#),
        ("a protobuf-style writer (push bytes, then set into a Uint8Array) round-trips",
         #"(function(){ var parts = [[0x12, 0x11], [0x10, 0x00, 0x18, 0x80, 0x04]], len = 0; parts.forEach(function(p){ len += p.length; }); var out = new Uint8Array(len), off = 0; parts.forEach(function(p){ out.set(p, off); off += p.length; }); return out.join() === '18,17,16,0,24,128,4'; })()"#),
    ]

    static let getRandomValuesCases: [(String, String)] = [
        ("getRandomValues fills every byte of a Uint32Array (not one byte per element)",
         #"(function(){ var big = 0; for (var n = 0; n < 8; n++) { var a = new Uint32Array(64); var r = crypto.getRandomValues(a); if (r !== a) return false; for (var i = 0; i < a.length; i++) if (a[i] > 255) big++; } return big > 400; })()"#),
        ("getRandomValues on Uint16Array / BigUint64Array / a view at an offset",
         #"(function(){ var u = new Uint16Array(256); crypto.getRandomValues(u); var wide = 0; for (var i = 0; i < u.length; i++) if (u[i] > 255) wide++; var b = new BigUint64Array(16); crypto.getRandomValues(b); var bw = 0; for (var j = 0; j < b.length; j++) if (b[j] > 0xffffffffn) bw++; var buf = new ArrayBuffer(32); var v = new Uint8Array(buf, 8, 8); crypto.getRandomValues(v); var all = new Uint8Array(buf), outside = 0; for (var k = 0; k < 32; k++) if ((k < 8 || k >= 16) && all[k] !== 0) outside++; return wide > 200 && bw > 10 && outside === 0; })()"#),
        ("getRandomValues: TypeMismatchError for non-integer arrays, QuotaExceededError past 65536 bytes",
         #"(function(){ function n(f){ try { f(); return 'none'; } catch (e) { return e.name; } } return n(function(){ crypto.getRandomValues(new Float32Array(4)); }) === 'TypeMismatchError' && n(function(){ crypto.getRandomValues([1, 2]); }) === 'TypeMismatchError' && n(function(){ crypto.getRandomValues(new Uint8Array(65537)); }) === 'QuotaExceededError' && n(function(){ crypto.getRandomValues(new Uint32Array(16384)); }) === 'none'; })()"#),
    ]

    mutating func testTypedArraySet() {
        let (_, ctx) = makeCtx()
        for (name, js) in JeffJSTestRunner.typedArraySetCases {
            let r = ctx.eval(input: js, filename: "<TypedArraySet>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            if r.isException {
                let exc = ctx.getException()
                assert(false, "TypedArraySet: \(name) threw \(ctx.toSwiftString(exc) ?? "?")")
                exc.freeValue()
            } else {
                assert(r.isBool && r.toBool(), "TypedArraySet: \(name) -> \(ctx.toSwiftString(r) ?? "?")")
            }
            r.freeValue()
        }
        var outcomes: [(Bool, String)] = []
        let run = {
            MainActor.assumeIsolated {
                let env = JeffJSEnvironment()
                for (name, js) in JeffJSTestRunner.getRandomValuesCases {
                    switch env.eval(js, filename: "<getRandomValues>") {
                    case .success(let value):
                        outcomes.append((value == "true", "TypedArraySet: \(name) -> \(value ?? "undefined")"))
                    case .exception(let message):
                        outcomes.append((false, "TypedArraySet: \(name) threw \(message)"))
                    }
                }
            }
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.sync(execute: run) }
        for (ok, message) in outcomes { assert(ok, message) }
    }
}
