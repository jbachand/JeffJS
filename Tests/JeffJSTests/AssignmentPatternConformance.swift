// AssignmentPatternConformance.swift
// JeffJS — conformance group "AssignmentPatterns" (ES §13.15.5, §14.7.5):
// destructuring ASSIGNMENT whose targets are arbitrary references, not only
// identifiers. Wikipedia's load.php (mediawiki date formatting) does
// `[info.mwMonth, info.mwMonthGen, info.mwMonthAbbrev] = config.months[i] || []`,
// which failed to parse ("expected identifier or pattern in destructuring").
// Expression heads of for-in/of (`for (o.x of ..)`, `for ([a, b] of ..)`)
// were evaluated once and never assigned.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let assignmentPatternCases: [(String, String)] = [
        ("array pattern with member targets (wiki load.php shape)",
         "(function(){ var info = {}, config = {months: [['a', 'b', 'c']]}; [info.mwMonth, info.mwMonthGen, info.mwMonthAbbrev] = config.months[0] || []; return info.mwMonth === 'a' && info.mwMonthGen === 'b' && info.mwMonthAbbrev === 'c'; })()"),
        ("computed member targets and a swap",
         "(function(){ var a = [1, 2], k = 'x', o = {}; [a[0], a[1]] = [a[1], a[0]]; [o[k], o['y' + 1]] = [3, 4]; return a.join() === '2,1' && o.x === 3 && o.y1 === 4; })()"),
        ("object pattern with member targets",
         "(function(){ var o = {s: {}}, k = 'q'; ({ p: o.p, [k]: o[0], r: o.s.t } = { p: 1, q: 2, r: 3 }); return o.p === 1 && o[0] === 2 && o.s.t === 3; })()"),
        ("defaults on member targets",
         "(function(){ var o = {}; [o.a = 1, o.b = 2] = [undefined, null]; ({ c: o.c = 3, d: o['d'] = 4 } = { d: 0 }); return o.a === 1 && o.b === null && o.c === 3 && o.d === 0; })()"),
        ("rest element with a member target",
         "(function(){ var o = {}; [o.first, ...o.rest] = [1, 2, 3]; ({ a: o.a, ...o.others } = { a: 1, b: 2, c: 3 }); return o.first === 1 && o.rest.join() === '2,3' && Object.keys(o.others).join() === 'b,c'; })()"),
        ("nested patterns mixing members and identifiers",
         "(function(){ var o = {}, x, y; [o.a, [o.b, x], { c: o.c, d: y = 5 }] = [1, [2, 3], { c: 4 }]; return o.a === 1 && o.b === 2 && x === 3 && o.c === 4 && y === 5; })()"),
        ("parenthesized and chained member targets",
         "(function(){ var o = { n: {} }; [(o.a), ((o).b), o.n.c, o['n']['d']] = [1, 2, 3, 4]; return o.a === 1 && o.b === 2 && o.n.c === 3 && o.n.d === 4; })()"),
        ("private field target",
         "(function(){ class C { #p; set(v) { [this.#p] = [v]; ({ q: this.#p } = { q: this.#p + 1 }); return this.#p; } } return new C().set(41) === 42; })()"),
        ("the assignment evaluates to the right-hand side",
         "(function(){ var o = {}, src = [1, 2]; var r = ([o.a, o.b] = src); var s = {k: 1}; var t = ({ k: o.k } = s); return r === src && t === s && o.b === 2 && o.k === 1; })()"),
        ("setters run for member targets",
         "(function(){ var log = []; var o = { set x(v) { log.push('x' + v); } }; [o.x, o.x] = [1, 2]; ({ a: o.x } = { a: 3 }); return log.join() === 'x1,x2,x3'; })()"),
        ("array pattern order: target reference, then iterator step, then store",
         "(function(){ var log = []; var o = { set x(v) { log.push('set' + v); } }; function obj() { log.push('ref'); return o; } var it = { [Symbol.iterator]() { var i = 0; return { next() { log.push('next'); return { value: ++i, done: false }; }, return() { log.push('close'); return {}; } }; } }; [obj().x, obj()['x']] = it; return log.join() === 'ref,next,set1,ref,next,set2,close'; })()"),
        ("object pattern order: key, target reference, get, default, store",
         "(function(){ var log = []; var o = { set x(v) { log.push('set' + v); } }; function obj() { log.push('ref'); return o; } function key() { log.push('key'); return 'b'; } var src = { get b() { log.push('get'); return undefined; } }; ({ [key()]: obj().x = (log.push('default'), 7) } = src); return log.join() === 'key,ref,get,default,set7'; })()"),
        ("for-of with an array pattern head",
         "(function(){ var a, b, r = []; for ([a, b] of [[1, 2], [3, 4]]) r.push(a + b); return r.join() === '3,7'; })()"),
        ("for-of with member and pattern-of-member heads",
         "(function(){ var o = {}, r = []; for (o.x of [1, 2]) r.push(o.x); for ([o.a, ...o.b] of [[3, 4, 5]]) r.push(o.a, o.b.join('')); for ({ k: o['k'] = 'd' } of [{}, { k: 6 }]) r.push(o.k); return r.join() === '1,2,3,45,d,6'; })()"),
        ("for-of with an object pattern head",
         "(function(){ var a, b, r = []; for ({ a, b = 9 } of [{ a: 1 }, { a: 2, b: 3 }]) r.push(a, b); return r.join() === '1,9,2,3'; })()"),
        ("for-in with member and pattern heads",
         "(function(){ var o = {}, r = [], c, d; for (o.k in { m: 1, n: 2 }) r.push(o.k); for ([c, d] in { xy: 1 }) r.push(c + d); return r.join() === 'm,n,xy'; })()"),
        ("for-of head reference is evaluated after each value",
         "(function(){ var log = []; var o = {}; function obj() { log.push('ref'); return o; } var it = { [Symbol.iterator]() { var i = 0; return { next() { log.push('next'); return i < 2 ? { value: ++i, done: false } : { done: true }; } }; } }; for (obj().x of it) log.push('v' + o.x); return log.join() === 'next,ref,v1,next,ref,v2,next'; })()"),
        ("for-of over object patterns in a declaration keeps the iterator intact",
         "(function(){ var r = []; for (const { a } of [{ a: 1 }, { a: 2 }, { a: 3 }]) r.push(a); for (var { length } in { ab: 1, cde: 2 }) r.push(length); return r.join() === '1,2,3,2,3'; })()"),
        ("member targets inside a generator and across yield",
         "(function(){ function* g() { var o = {}; [o.a, o.b] = yield 1; return o.a + o.b; } var it = g(); it.next(); return it.next([2, 3]).value === 5; })()"),
        ("an assignment pattern reaches a variable of an enclosing function",
         "(function(){ var r, o = {}; (function(){ [...r] = [1, 2]; [o.v] = [r]; })(); return r.join() === '1,2' && o.v === r; })()"),
        ("invalid targets are early SyntaxErrors",
         "(function(){ var bad = ['[f()] = []', '({ a: f() } = {})', '[...a.b, c] = []', 'for (f() of []);', '[o?.x] = []']; return bad.every(function(src){ try { new Function(src); return false; } catch (e) { return e instanceof SyntaxError; } }); })()"),
    ]

    mutating func testAssignmentPatterns() {
        runTrueCases("AssignmentPatterns", JeffJSTestRunner.assignmentPatternCases)
    }
}
