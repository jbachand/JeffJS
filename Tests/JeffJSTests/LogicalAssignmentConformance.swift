// LogicalAssignmentConformance.swift
// JeffJS — `&&=` / `||=` / `??=` on property references (ES2021 §13.15.2).
//
// The parser picked the "variable" code path whenever the LHS *started* with a
// variable read, so `o.a ||= v` stored v into `o` and left `o.a` untouched, and
// `o[k] ??= v` did the same. Google's search results bundle does
// `xva=function(){_.nTa||=new _.oTa;return _.nTa}` — it overwrote its `_`
// namespace object and every later `_.x(...)` threw "undefined is not a
// function". Member targets now evaluate the base (and key) once, read the
// property, short-circuit on the old value, and PutValue the new one.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let logicalAssignmentCases: [(String, String)] = [
        ("o.a ||= v stores into o.a, not o",
         "(function(){ var o = {}; var r = (o.a ||= 5); return r === 5 && o.a === 5 && typeof o === 'object'; })()"),
        ("the Google shape: _.n ||= new _.C; return _.n",
         "(function(){ var _ = {}; _.C = function(){ this.x = 1; }; var get = function(){ _.n ||= new _.C; return _.n; }; var a = get(), b = get(); return a === b && a.x === 1 && typeof _.C === 'function'; })()"),
        ("o.a &&= v / o.a ??= v keep or replace per the operator",
         "(function(){ var o = { a: 1, b: 0, c: null, d: 0 }; var r1 = (o.a &&= 2), r2 = (o.b &&= 3), r3 = (o.c ??= 4), r4 = (o.d ??= 5); return r1 === 2 && o.a === 2 && r2 === 0 && o.b === 0 && r3 === 4 && o.c === 4 && r4 === 0 && o.d === 0; })()"),
        ("short-circuit does not evaluate the RHS or call the setter",
         "(function(){ var sets = 0, rhs = 0; var o = { get v(){ return 1; }, set v(x){ sets++; } }; o.v ||= (rhs++, 2); return sets === 0 && rhs === 0; })()"),
        ("o[k] ||= v and arr[i] &&= v store into the element",
         "(function(){ var o = {}, arr = [0, 1]; o['k'] ||= 7; arr[0] ||= 4; arr[1] &&= 8; return o.k === 7 && arr[0] === 4 && arr[1] === 8 && Array.isArray(arr); })()"),
        ("base and key are evaluated once",
         "(function(){ var nb = 0, nk = 0, o = {}; function base(){ nb++; return o; } function key(){ nk++; return 'q'; } base()[key()] ??= 1; base().p ||= 2; return nb === 2 && nk === 1 && o.q === 1 && o.p === 2; })()"),
        ("a.b.c ||= v targets the innermost property",
         "(function(){ var a = { b: {} }; a.b.c ||= 3; return a.b.c === 3 && typeof a.b === 'object'; })()"),
        ("variables still work, and inside finally",
         "(function(){ var x = 0; x ||= 3; let y = null; y ??= 4; function f(){ var o = {}; try { return o.q ??= 3; } finally { o.z = 1; } } return x === 3 && y === 4 && f() === 3; })()"),
    ]

    mutating func testLogicalAssignment() {
        runTrueCases("LogicalAssignment", JeffJSTestRunner.logicalAssignmentCases)
    }
}
