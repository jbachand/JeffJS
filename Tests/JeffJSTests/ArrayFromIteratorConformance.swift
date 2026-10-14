// ArrayFromIteratorConformance.swift
// JeffJS — conformance group "ArrayFromIterator" (ES §23.1.2.1 Array.from,
// §7.4.2 GetIterator, QuickJS js_array_iterator_next special cases).
// Array.from steps the intrinsic array iterator inline (no {value, done}
// object) only while the iterator's `next` resolves to the intrinsic
// %ArrayIteratorPrototype%.next and @@iterator is the intrinsic `values`.
// Patching the iterator's own `next`, %ArrayIteratorPrototype%.next or
// Array.prototype[Symbol.iterator] must fall back to the observable protocol:
// `next` is read once, called once per step, `done` and `value` are each
// read once per result.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    private static func afCase(_ body: String) -> String {
        "(function(){ var AIP = Object.getPrototypeOf([][Symbol.iterator]()); var origNext = AIP.next; var origIter = Array.prototype[Symbol.iterator]; \(body) })()"
    }

    static let arrayFromIteratorCases: [(String, String)] = [
        ("unpatched: arrays, keys, entries, mapFn and thisArg",
         afCase("var m = Array.from([5,6,7], function(v,i){ return v*10+i+this.k; }, {k:1}); return Array.from([1,2,3]).join() === '1,2,3' && Array.from([4,5].keys()).join() === '0,1' && Array.from(['a'].entries())[0].join() === '0,a' && m.join() === '51,62,73' && Array.from([]).length === 0;")),
        ("unpatched: sparse arrays and later pushes by mapFn are seen like the protocol",
         afCase("var a = [1,,3]; var r = Array.from(a); var b = [1,2]; var seen = Array.from(b, function(v){ if (b.length < 4) b.push(v + 10); return v; }); return r.length === 3 && r[1] === undefined && seen.join() === '1,2,11,12';")),
        ("patched %ArrayIteratorPrototype%.next is called per step and result getters read once",
         afCase("var calls = 0, dg = 0, vg = 0; AIP.next = function(){ calls++; var r = origNext.call(this); return { get done(){ dg++; return r.done; }, get value(){ vg++; return r.value; } }; }; try { var out = Array.from([7,8,9]); } finally { AIP.next = origNext; } return out.join() === '7,8,9' && calls === 4 && dg === 4 && vg === 3;")),
        ("%ArrayIteratorPrototype%.next is read once, not per step",
         afCase("var gets = 0; Object.defineProperty(AIP, 'next', { configurable: true, get: function(){ gets++; return origNext; } }); try { var out = Array.from([1,2,3,4]); } finally { Object.defineProperty(AIP, 'next', { configurable: true, writable: true, value: origNext }); } return out.join() === '1,2,3,4' && gets === 1;")),
        ("own next on the iterator wins over the intrinsic",
         afCase("var calls = 0; Array.prototype[Symbol.iterator] = function(){ var it = origIter.call(this); it.next = function(){ calls++; return origNext.call(this); }; return it; }; try { var out = Array.from([1,2]); } finally { Array.prototype[Symbol.iterator] = origIter; } return out.join() === '1,2' && calls === 3;")),
        ("an own next returning custom results is honoured",
         afCase("Array.prototype[Symbol.iterator] = function(){ var it = origIter.call(this), n = 0; it.next = function(){ return n < 2 ? { done: false, value: 'x' + n++ } : { done: true }; }; return it; }; try { var out = Array.from([1,2,3,4,5]); } finally { Array.prototype[Symbol.iterator] = origIter; } return out.join() === 'x0,x1';")),
        ("patched Array.prototype[Symbol.iterator] (generator) is used",
         afCase("Array.prototype[Symbol.iterator] = function*(){ yield 'g1'; yield 'g2'; }; try { var out = Array.from([1,2,3]); } finally { Array.prototype[Symbol.iterator] = origIter; } return out.join() === 'g1,g2';")),
        ("a non-object next result is a TypeError, also when mapped",
         afCase("AIP.next = function(){ return 1; }; var e1, e2; try { try { Array.from([1]); } catch (e) { e1 = e; } try { Array.from([1], function(v){ return v; }); } catch (e) { e2 = e; } } finally { AIP.next = origNext; } return e1 instanceof TypeError && e2 instanceof TypeError;")),
        ("a throwing mapFn closes the iterator through return()",
         afCase("var closed = 0; var it = { [Symbol.iterator](){ return { next(){ return { done: false, value: 1 }; }, return(){ closed++; return {}; } }; } }; var e; try { Array.from(it, function(){ throw 'boom'; }); } catch (err) { e = err; } return e === 'boom' && closed === 1;")),
        ("array iterator target mutated during iteration still follows the iterator protocol",
         afCase("var a = [1,2,3], out = []; var it = a[Symbol.iterator](); it.next(); var r = Array.from({ [Symbol.iterator]: function(){ return it; } }); return r.join() === '2,3';")),
    ]

    mutating func testArrayFromIterator() {
        runTrueCases("ArrayFromIterator", JeffJSTestRunner.arrayFromIteratorCases)
    }
}
