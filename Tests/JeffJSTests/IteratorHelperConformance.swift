// IteratorHelperConformance.swift
// JeffJS — conformance group "IteratorHelpers" (ES2025 §27.1: the Iterator
// constructor, Iterator.from + %WrapForValidIteratorPrototype%,
// %IteratorHelperPrototype% and Iterator.prototype.{map, filter, take, drop,
// flatMap, reduce, toArray, forEach, some, every, find}; Iterator.concat from
// ES2026). The helpers were plain objects carrying `__underlying`/`__mapper`/…
// own properties and own `next`/`return` functions, with no
// %IteratorHelperPrototype% (`[1].values().map(f)` had no `toArray`), called
// `return` only when it was a native function, never closed the underlying
// iterator on a callback error, and the methods were enumerable. Now each
// helper is a generator-like object (state in the payload: suspended-start /
// suspended-yield / executing / completed) whose prototype carries `next`,
// `return` and @@toStringTag "Iterator Helper"; texts match JavaScriptCore.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let iteratorHelperCases: [(String, String)] = [
        ("a helper inherits %IteratorHelperPrototype% (next, return, @@toStringTag) and has no own properties",
         #"(function(){ var h = [1, 2, 3].values().map(function(x){ return x * 2; }); var hp = Object.getPrototypeOf(h); var d = Object.getOwnPropertyDescriptor(hp, Symbol.toStringTag); return Object.getOwnPropertyNames(hp).join() === 'next,return' && d.value === 'Iterator Helper' && !d.writable && !d.enumerable && d.configurable && Object.getPrototypeOf(hp) === Iterator.prototype && Reflect.ownKeys(h).length === 0 && String(h) === '[object Iterator Helper]' && h.toArray().join() === '2,4,6'; })()"#),
        ("every helper method returns the same kind of object",
         #"(function(){ var hp = Object.getPrototypeOf([].values().map(function(){})); var it = function(){ return [1].values(); }; return [it().filter(Boolean), it().take(1), it().drop(0), it().flatMap(function(x){ return [x]; }), Iterator.concat([1])].every(function(h){ return Object.getPrototypeOf(h) === hp; }); })()"#),
        ("Iterator.prototype methods: names, lengths, not enumerable",
         #"(function(){ var P = Iterator.prototype; var names = ['map','filter','take','drop','flatMap','reduce','toArray','forEach','some','every','find']; var lens = [1,1,1,1,1,1,0,1,1,1,1]; return Object.keys(P).length === 0 && names.every(function(n, i){ var d = Object.getOwnPropertyDescriptor(P, n); return d.writable && !d.enumerable && d.configurable && P[n].length === lens[i] && P[n].name === n; }); })()"#),
        ("the Iterator constructor: abstract, subclassable, prototype non-writable",
         #"(function(){ var a = false, b = false; try { Iterator(); } catch (e) { a = e instanceof TypeError; } try { new Iterator(); } catch (e) { b = e instanceof TypeError && e.message === 'Iterator cannot be constructed directly'; } class C extends Iterator { next(){ return { done: true }; } } var c = new C(); var d = Object.getOwnPropertyDescriptor(Iterator, 'prototype'); return a && b && c instanceof Iterator && Object.getPrototypeOf(c) === C.prototype && !d.writable && !d.enumerable && !d.configurable && Iterator.length === 0; })()"#),
        ("Iterator.prototype[@@toStringTag] / constructor are SetterThatIgnoresPrototypeProperties accessors",
         #"(function(){ var P = Iterator.prototype; var d = Object.getOwnPropertyDescriptor(P, Symbol.toStringTag), c = Object.getOwnPropertyDescriptor(P, 'constructor'); var o = Object.create(P); o.constructor = 1; o[Symbol.toStringTag] = 'Q'; var home = false; try { P.constructor = 2; } catch (e) { home = e instanceof TypeError; } return typeof d.get === 'function' && typeof d.set === 'function' && !d.enumerable && d.configurable && c.get.call(1) === Iterator && P.constructor === Iterator && P[Symbol.toStringTag] === 'Iterator' && Object.getOwnPropertyDescriptor(o, 'constructor').value === 1 && String(o) === '[object Q]' && home; })()"#),
        ("Iterator.from: iterables, strings, iterator-likes; an Iterator is returned as is",
         #"(function(){ var arrIt = [1].values(); var w = Iterator.from({ next: function(){ return { value: 7, done: false }; } }); var wp = Object.getPrototypeOf(w); return Iterator.from(arrIt) === arrIt && Iterator.from([5, 6]).toArray().join() === '5,6' && Iterator.from('a😀').toArray().length === 2 && Object.getOwnPropertyNames(wp).join() === 'next,return' && Object.getPrototypeOf(wp) === Iterator.prototype && w.take(2).toArray().join() === '7,7' && JSON.stringify(w.return()) === '{"done":true}'; })()"#),
        ("Iterator.from rejects non-objects other than strings; the wrapper's return forwards",
         #"(function(){ var t = false; try { Iterator.from(5); } catch (e) { t = e instanceof TypeError; } var w = Iterator.from({ next: function(){ return { done: true }; }, return: function(){ return { r: 1 }; } }); var foreign = false; try { Object.getPrototypeOf(w).next.call({}); } catch (e) { foreign = e instanceof TypeError; } return t && w.return().r === 1 && foreign; })()"#),
        ("map/filter pass (value, counter) with this undefined; laziness",
         #"(function(){ var calls = 0; var h = [5, 6, 7].values().map(function(v, i){ 'use strict'; calls++; return [v, i, this === undefined].join(); }); var before = calls; var first = h.next().value; return before === 0 && first === '5,0,true' && calls === 1 && [5, 6, 7].values().filter(function(v, i){ return i !== 1; }).toArray().join() === '5,7'; })()"#),
        ("take / drop: limits, Infinity, RangeErrors (JSC text), take(0) closes",
         #"(function(){ var r = []; try { [1].values().take(-1); } catch (e) { r.push(e instanceof RangeError && e.message === 'Iterator.prototype.take argument must be non-negative.'); } try { [1].values().drop(NaN); } catch (e) { r.push(e instanceof RangeError && e.message === 'Iterator.prototype.drop argument must not be NaN.'); } var n = 0; var src = { next: function(){ return { value: 1, done: false }; }, return: function(){ n++; return {}; }, __proto__: Iterator.prototype }; var t = src.take(0); t.next(); t.next(); return r.join() === 'true,true' && n === 1 && [1,2,3].values().take(Infinity).toArray().join() === '1,2,3' && [1,2,3].values().drop(1).take(1).toArray().join() === '2' && [1,2,3].values().drop(Infinity).toArray().length === 0 && [1,2].values().take('1').toArray().join() === '1'; })()"#),
        ("flatMap flattens iterables, rejects primitives (strings too)",
         #"(function(){ var ok = [1, 2].values().flatMap(function(x){ return [x, x * 10]; }).toArray().join() === '1,10,2,20'; var s = false; try { [1].values().flatMap(function(){ return 'ab'; }).toArray(); } catch (e) { s = e instanceof TypeError; } return ok && s && [1].values().flatMap(function(){ return new Set([3, 4]); }).toArray().join() === '3,4'; })()"#),
        ("reduce / toArray / forEach / some / every / find",
         #"(function(){ var it = function(){ return [1, 2, 3].values(); }; var fe = []; it().forEach(function(v, i){ fe.push(v + ':' + i); }); var noInit = false; try { [].values().reduce(function(a){ return a; }); } catch (e) { noInit = e instanceof TypeError; } return it().reduce(function(a, b){ return a + b; }) === 6 && it().reduce(function(a, b, i){ return a + b * i; }, 10) === 18 && it().toArray().join() === '1,2,3' && fe.join() === '1:0,2:1,3:2' && it().some(function(x){ return x > 2; }) && !it().every(function(x){ return x > 2; }) && it().find(function(x){ return x > 1; }) === 2 && it().find(function(){ return false; }) === undefined && noInit; })()"#),
        ("a non-callable callback throws and closes the iterator (JSC text)",
         #"(function(){ var log = []; var src = { next: function(){ return { done: true }; }, return: function(){ log.push('r'); return {}; }, __proto__: Iterator.prototype }; var msgs = []; ['map','filter','flatMap','some','every','find'].forEach(function(m){ try { src[m](1); } catch (e) { msgs.push(e.message === 'Iterator.prototype.' + m + ' callback must be a function.'); } }); try { src.reduce(1); } catch (e) { msgs.push(e instanceof TypeError); } try { src.forEach(); } catch (e) { msgs.push(e instanceof TypeError); } return log.length === 8 && msgs.length === 8 && msgs.every(Boolean); })()"#),
        ("a throwing callback closes the underlying iterator and rethrows the callback's error",
         #"(function(){ var closed = 0; var src = function(){ return { next: function(){ return { value: 1, done: false }; }, return: function(){ closed++; throw new Error('from return'); }, __proto__: Iterator.prototype }; }; var errs = []; [function(s){ s.map(function(){ throw new Error('cb'); }).next(); }, function(s){ s.filter(function(){ throw new Error('cb'); }).next(); }, function(s){ s.forEach(function(){ throw new Error('cb'); }); }, function(s){ s.reduce(function(){ throw new Error('cb'); }, 0); }, function(s){ s.flatMap(function(){ return 5; }).next(); }].forEach(function(f){ try { f(src()); } catch (e) { errs.push(e.message); } }); return closed === 5 && errs.slice(0, 4).join() === 'cb,cb,cb,cb' && errs[4] !== 'from return'; })()"#),
        ("an error from the underlying next() does not close it",
         #"(function(){ var closed = 0; var src = { next: function(){ throw new Error('n'); }, return: function(){ closed++; return {}; }, __proto__: Iterator.prototype }; var h = src.map(function(x){ return x; }); var e1; try { h.next(); } catch (e) { e1 = e.message; } return e1 === 'n' && closed === 0 && JSON.stringify(h.next()) === '{"done":true}'; })()"#),
        ("return(): suspended-start closes, completed is a no-op, value is undefined",
         #"(function(){ var closed = 0; var src = { i: 0, next: function(){ return { value: this.i++, done: false }; }, return: function(){ closed++; return {}; }, __proto__: Iterator.prototype }; var a = src.map(function(x){ return x; }); var r1 = a.return(); var r2 = a.return(); var b = src.filter(function(){ return true; }); b.next(); var r3 = b.return(7); return closed === 2 && r1.done && r1.value === undefined && r2.done && r3.done && r3.value === undefined && JSON.stringify(b.next()) === '{"done":true}'; })()"#),
        ("return() of a flatMap in its inner loop closes the inner then the outer",
         #"(function(){ var log = []; function mk(n){ return { next: function(){ return { value: n, done: false }; }, return: function(){ log.push(n); return {}; }, __proto__: Iterator.prototype }; } var f = mk('outer').flatMap(function(){ return mk('inner'); }); f.next(); f.return(); return log.join() === 'inner,outer'; })()"#),
        ("generator state: re-entering a running helper throws; a generator source is closed",
         #"(function(){ var h = [1].values().map(function(){ try { h.next(); return 'no'; } catch (e) { return e instanceof TypeError && e.message === 'Generator is executing'; } }); var fin = 0; function* g(){ try { yield 1; yield 2; } finally { fin++; } } var m = g().map(function(x){ return x; }); m.next(); m.return(); var foreign = false; try { Object.getPrototypeOf(h).next.call([].values()); } catch (e) { foreign = e instanceof TypeError; } return h.next().value === true && fin === 1 && foreign; })()"#),
        ("for-of, spread, destructuring over helpers close them on early exit",
         #"(function(){ var closed = 0; function src(){ return { i: 0, next: function(){ return { value: this.i++, done: false }; }, return: function(){ closed++; return {}; }, __proto__: Iterator.prototype }; } var out = []; for (var v of src().filter(function(x){ return x % 2; })) { if (v > 4) break; out.push(v); } var [a, b] = src().map(function(x){ return x * 10; }); return out.join() === '1,3' && a === 0 && b === 10 && closed === 2 && [...[1, 2].values().map(function(x){ return -x; })].join() === '-1,-2'; })()"#),
        ("helpers over Map / Set / String / RegExp-matchAll iterators and generators",
         #"(function(){ function* g(){ yield* [1, 2]; } return new Map([[1, 2]]).entries().map(function(e){ return e[0] + e[1]; }).toArray().join() === '3' && new Set('ab').values().map(function(c){ return c.toUpperCase(); }).toArray().join('') === 'AB' && 'xy'[Symbol.iterator]().drop(1).toArray().join() === 'y' && 'a1b2'.matchAll(/\d/g).map(function(m){ return m[0]; }).toArray().join() === '1,2' && g().map(function(x){ return x * 3; }).toArray().join() === '3,6'; })()"#),
        ("Iterator.concat: validation, order, return closes the current iterator",
         #"(function(){ var t1 = false, t2 = false; try { Iterator.concat(1); } catch (e) { t1 = e instanceof TypeError; } try { Iterator.concat({}); } catch (e) { t2 = e instanceof TypeError; } var closed = 0; var it = { next: function(){ return { value: 9, done: false }; }, return: function(){ closed++; return {}; }, [Symbol.iterator]: function(){ return this; } }; var c = Iterator.concat([1], it); var v = [c.next().value, c.next().value]; c.return(); return t1 && t2 && Iterator.concat.length === 0 && Iterator.concat([1], new Set([2, 3]), new String('ab')).toArray().join() === '1,2,3,a,b' && v.join() === '1,9' && closed === 1; })()"#),
        ("a helper whose next is not callable / whose result is not an object throws (JSC text)",
         #"(function(){ var a, b; try { Iterator.from({ next: function(){ return 1; } }).toArray(); } catch (e) { a = e instanceof TypeError && e.message === 'Iterator result interface is not an object.'; } try { Iterator.from({ next: 5 }).toArray(); } catch (e) { b = e instanceof TypeError && e.message === '5 is not a function'; } return a && b; })()"#),
        ("a thousand chained helpers do not leak state into later ones",
         #"(function(){ var s = 0; for (var i = 0; i < 1000; i++) s += [1, 2, 3].values().map(function(x){ return x + 1; }).filter(function(x){ return x > 2; }).take(5).toArray().length; return s === 2000; })()"#),
    ]

    mutating func testIteratorHelpers() {
        runTrueCases("IteratorHelpers", JeffJSTestRunner.iteratorHelperCases)
    }
}
