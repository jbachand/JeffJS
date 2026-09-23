// ArrayIntegrityConformance.swift
// JeffJS — "ArrayIntegrity": integrity levels and property attributes of
// array elements.
//
// Array elements live in the fast element storage, not in the shape, so
// `Object.freeze` / `seal` / `preventExtensions` and a non-writable `length`
// only changed shape properties: `a[0] = 5`, `a.push(2)`, `pop`, `shift`,
// `unshift`, `splice`, `fill`, `copyWithin`, `reverse` and `sort` all
// mutated a frozen array, `delete` removed sealed elements, element
// descriptors always said writable/configurable, and the Array.prototype
// mutators ignored every refused write.
//
//   - ES §10.1.9.2 OrdinarySetWithOwnDescriptor: a read-only element or a
//     non-extensible array refuses the write (silently in sloppy code,
//     TypeError in strict code and in `Set(O, P, V, true)`).
//   - §10.1.10 [[Delete]]: a non-configurable element stays.
//   - §10.4.2.1 / §10.4.2.4 array [[DefineOwnProperty]] and ArraySetLength:
//     per-element attributes, a read-only `length` blocks growth, and
//     shrinking stops above the last non-configurable element.
//   - §23.1.3.* push/pop/shift/unshift/splice/fill/copyWithin/reverse/sort:
//     TypeError when any Set / DeletePropertyOrThrow / Set(length) fails.
//   - §7.3.15 SetIntegrityLevel / §7.3.16 TestIntegrityLevel on arrays and
//     typed arrays (which cannot be sealed or frozen with elements).
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let arrayIntegrityCases: [(String, String)] = [
        // Array.prototype mutators on frozen / sealed / non-extensible arrays.
        ("frozen push throws and leaves the array",
         "(function(){ var a = Object.freeze([1]); try { a.push(2); return false; } catch (e) { return e instanceof TypeError && a.length === 1 && !(1 in a); } })()"),
        ("frozen push() with no items still sets length",
         "(function(){ try { Object.freeze([]).push(); return false; } catch (e) { return e instanceof TypeError; } })()"),
        ("frozen pop / shift / unshift / splice throw",
         "(function(){ var n = 0, a = Object.freeze([1, 2]); [function(){ a.pop(); }, function(){ a.shift(); }, function(){ a.unshift(0); }, function(){ a.splice(0, 1); }, function(){ a.splice(0, 0); }, function(){ Object.freeze([]).pop(); }].forEach(function(f){ try { f(); } catch (e) { if (e instanceof TypeError) n++; } }); return n === 6 && a[0] === 1 && a[1] === 2 && a.length === 2; })()"),
        ("frozen fill / copyWithin / reverse / sort throw",
         "(function(){ var n = 0, a = Object.freeze([2, 1]); [function(){ a.fill(0); }, function(){ a.copyWithin(0, 1); }, function(){ a.reverse(); }, function(){ a.sort(); }].forEach(function(f){ try { f(); } catch (e) { if (e instanceof TypeError) n++; } }); return n === 4 && a[0] === 2 && a[1] === 1; })()"),
        ("frozen mutators that write nothing succeed",
         "(function(){ var a = Object.freeze([1, 2]); return a.fill(0, 2) === a && Object.freeze([1]).reverse()[0] === 1; })()"),
        ("sealed arrays: writes work, adds and deletes throw",
         "(function(){ var a = Object.seal([3, 1, 2]); a.reverse(); a.sort(); a.fill(7, 2); a.splice(0, 1, 9); var j = a.join(), n = 0; [function(){ a.push(1); }, function(){ a.pop(); }, function(){ a.shift(); }, function(){ a.unshift(0); }].forEach(function(f){ try { f(); } catch (e) { if (e instanceof TypeError) n++; } }); return n === 4 && j === '9,2,7' && a.length === 3; })()"),
        ("non-extensible arrays: deletes work, adds throw",
         "(function(){ var a = Object.preventExtensions([1, 2, 3]); var p = a.pop(), s = a.shift(); var n = 0; try { a.push(4); } catch (e) { n++; } try { a.unshift(0); } catch (e) { n++; } try { Object.preventExtensions([1, 2]).splice(0, 0, 5); } catch (e) { n++; } return p === 3 && s === 1 && a.length === 1 && a[0] === 2 && n === 3; })()"),
        ("read-only length: push/pop/shift/unshift/splice throw",
         "(function(){ var n = 0; [function(a){ a.push(2); }, function(a){ a.pop(); }, function(a){ a.shift(); }, function(a){ a.unshift(0); }, function(a){ a.splice(0, 1); }].forEach(function(f){ var a = [1, 2]; Object.defineProperty(a, 'length', { writable: false }); try { f(a); } catch (e) { if (e instanceof TypeError && a.length === 2) n++; } }); return n === 5; })()"),
        ("read-only length: fill and reverse still work",
         "(function(){ var a = [1, 2]; Object.defineProperty(a, 'length', { writable: false }); return a.reverse().join() === '2,1' && a.fill(0).join() === '0,0'; })()"),
        ("read-only element: fill throws, non-configurable element: pop throws",
         "(function(){ var a = [1, 2], b = [1, 2], n = 0; Object.defineProperty(a, '0', { writable: false }); Object.defineProperty(b, '1', { configurable: false }); try { a.fill(0); } catch (e) { n++; } try { b.pop(); } catch (e) { n++; } return n === 2 && a[0] === 1 && b.length === 2; })()"),
        ("generic push on a frozen array-like throws",
         "(function(){ try { Array.prototype.push.call(Object.freeze({ length: 0 }), 1); return false; } catch (e) { return e instanceof TypeError; } })()"),
        ("push in a loop on a frozen array throws every time",
         "(function(){ var a = Object.freeze([1]), n = 0; for (var i = 0; i < 50; i++) { try { a.push(i); } catch (e) { n++; } } return n === 50 && a.length === 1; })()"),

        // Assignment, delete and length through the interpreter.
        ("sloppy assignment to a frozen array is ignored",
         "(function(){ var a = Object.freeze([1, 2]); a[0] = 5; a[5] = 1; a[0]++; a.length = 0; return a[0] === 1 && a.length === 2 && a[5] === undefined; })()"),
        ("strict assignment to a frozen array throws",
         "(function(){ 'use strict'; var a = Object.freeze([1, 2]), n = 0; try { a[0] = 5; } catch (e) { n++; } try { a[2] = 5; } catch (e) { n++; } try { a[0] += 1; } catch (e) { n++; } try { a.length = 1; } catch (e) { n++; } return n === 4 && a.join() === '1,2'; })()"),
        ("strict add to sealed / non-extensible arrays throws, set works",
         "(function(){ 'use strict'; var s = Object.seal([1, 2]), p = Object.preventExtensions([1, 2]), n = 0; s[0] = 5; try { s[2] = 5; } catch (e) { n++; } try { p[2] = 5; } catch (e) { n++; } return n === 2 && s[0] === 5 && s.length === 2 && p.length === 2; })()"),
        ("a hole in a non-extensible array cannot be filled",
         "(function(){ var a = [1, , 3]; Object.preventExtensions(a); a[1] = 2; var sloppy = !(1 in a); try { (function(){ 'use strict'; a[1] = 2; })(); return false; } catch (e) { return sloppy && e instanceof TypeError; } })()"),
        ("hot loops respect a freeze that happens mid-loop",
         "(function(){ var a = [0, 0]; for (var i = 0; i < 20000; i++) { a[i & 1] = i; if (i === 10000) Object.freeze(a); } return a[0] === 10000 && a[1] === 9999; })()"),
        ("hot strict writes to a frozen array throw every time",
         "(function(){ 'use strict'; var a = Object.freeze([1, 2, 3]), n = 0; for (var i = 0; i < 5000; i++) { try { a[i % 3] = i; } catch (e) { n++; } } return n === 5000 && a.join() === '1,2,3'; })()"),
        ("delete of a sealed element fails (sloppy false, strict TypeError)",
         "(function(){ var a = Object.freeze([1, 2]); var r = delete a[0]; try { (function(){ 'use strict'; delete a[1]; })(); return false; } catch (e) { return r === false && e instanceof TypeError && a[0] === 1 && 1 in a; } })()"),
        ("delete of an element of a non-extensible array works",
         "(function(){ 'use strict'; var a = Object.preventExtensions([1, 2]); delete a[1]; return !(1 in a) && a.length === 2; })()"),
        ("strict delete of a non-configurable property throws",
         "(function(){ 'use strict'; try { delete Object.freeze({ a: 1 }).a; return false; } catch (e) { return e instanceof TypeError; } })()"),
        ("length cannot shrink past a non-configurable element",
         "(function(){ var a = [1, 2, 3]; Object.defineProperty(a, '1', { configurable: false }); a.length = 0; var sloppy = a.length === 2 && a[1] === 2; try { (function(){ 'use strict'; a.length = 0; })(); return false; } catch (e) { return sloppy && e instanceof TypeError && a.length === 2; } })()"),
        ("sealed length cannot shrink, non-extensible length can grow",
         "(function(){ var s = Object.seal([1, 2, 3]), p = Object.preventExtensions([1]); s.length = 1; p.length = 3; return s.length === 3 && s[2] === 3 && p.length === 3; })()"),
        ("read-only length blocks index growth, not in-range writes",
         "(function(){ var a = [1, 2]; Object.defineProperty(a, 'length', { writable: false }); a[2] = 3; a[1] = 9; var n = 0; try { (function(){ 'use strict'; a[2] = 3; })(); } catch (e) { n++; } try { (function(){ 'use strict'; a.length = 2; })(); } catch (e) { n++; } return a.length === 2 && a[2] === undefined && a[1] === 9 && n === 2; })()"),
        ("an invalid length on a frozen array never truncates it",
         "(function(){ var a = Object.freeze([1, 2]); try { a.length = -1; } catch (e) {} try { a.length = 'x'; } catch (e) {} return a.length === 2 && a[1] === 2; })()"),
        ("Reflect.set / deleteProperty / defineProperty report refusal",
         "(function(){ var a = Object.freeze([1]); return Reflect.set(a, 0, 2) === false && Reflect.set(a, 1, 2) === false && Reflect.deleteProperty(a, 0) === false && Reflect.defineProperty(a, 1, { value: 1 }) === false && Reflect.defineProperty(a, 0, { value: 1 }) === true && Reflect.defineProperty(a, 0, { value: 2 }) === false; })()"),

        // Descriptors and integrity tests.
        ("element descriptors of frozen and sealed arrays",
         "(function(){ var f = Object.getOwnPropertyDescriptor(Object.freeze([7]), '0'), s = Object.getOwnPropertyDescriptor(Object.seal([7]), 0); return f.value === 7 && !f.writable && f.enumerable && !f.configurable && s.writable && !s.configurable; })()"),
        ("isFrozen / isSealed look at the elements",
         "Object.isFrozen(Object.freeze([1, 2])) && Object.isSealed(Object.freeze([1])) && !Object.isFrozen(Object.seal([1])) && Object.isSealed(Object.seal([1])) && !Object.isSealed(Object.preventExtensions([1])) && !Object.isFrozen(Object.preventExtensions([1])) && !Object.isFrozen([1])"),
        ("empty non-extensible array: sealed, not frozen (length is writable)",
         "Object.isSealed(Object.preventExtensions([])) && !Object.isFrozen(Object.preventExtensions([])) && Object.isFrozen(Object.freeze([]))"),
        ("a frozen array with holes and a read-only length",
         "(function(){ var a = [1, , 3]; Object.freeze(a); a[1] = 2; var b = [1, 2]; Object.defineProperty(b, 'length', { writable: false }); Object.freeze(b); return !(1 in a) && Object.isFrozen(a) && Object.isFrozen(b); })()"),
        ("seal then freeze, and defineProperty on sealed elements",
         "(function(){ var a = Object.seal([1, 2]); Object.defineProperty(a, 0, { value: 5 }); Object.defineProperty(a, 1, { writable: false }); var ok = a[0] === 5 && !Object.isFrozen(a); Object.freeze(a); return ok && Object.isFrozen(a) && Object.getOwnPropertyDescriptor(a, 0).writable === false; })()"),
        ("frozen elements reject redefinition, accept the same value",
         "(function(){ var a = Object.freeze([1]); Object.defineProperty(a, '0', { value: 1 }); try { Object.defineProperty(a, '0', { value: 2 }); return false; } catch (e) { return e instanceof TypeError && a[0] === 1; } })()"),
        ("per-element attributes: read-only element",
         "(function(){ var a = [1, 2]; Object.defineProperty(a, '0', { writable: false }); a[0] = 9; var d = Object.getOwnPropertyDescriptor(a, 0); a.push(3); return a[0] === 1 && d.writable === false && d.configurable === true && a.length === 3 && Array.isArray(a); })()"),
        ("per-element attributes: writable again, delete resets",
         "(function(){ var a = [1, 2]; Object.defineProperty(a, 0, { writable: false }); Object.defineProperty(a, 0, { writable: true }); a[0] = 5; var b = [1, 2]; Object.defineProperty(b, 0, { writable: false }); delete b[0]; b[0] = 7; var d = Object.getOwnPropertyDescriptor(b, 0); return a[0] === 5 && b[0] === 7 && d.writable && d.enumerable && d.configurable; })()"),
        ("per-element attributes: non-configurable redefinition rules",
         "(function(){ var a = [1]; Object.defineProperty(a, 0, { configurable: false }); Object.defineProperty(a, 0, { writable: false }); return !Reflect.defineProperty(a, 0, { configurable: true }) && !Reflect.defineProperty(a, 0, { writable: true }) && Reflect.defineProperty(a, 0, { value: 1 }) && !Reflect.defineProperty(a, 0, { value: 2 }) && !Reflect.defineProperty(a, 0, { enumerable: false }); })()"),
        ("per-element attributes: non-enumerable element",
         "(function(){ var a = [1, 2, 3]; Object.defineProperty(a, 1, { enumerable: false }); var fi = []; for (var k in a) fi.push(k); return Object.keys(a).join() === '0,2' && fi.join() === '0,2' && !a.propertyIsEnumerable(1) && a[1] === 2 && JSON.stringify(a) === '[1,2,3]'; })()"),
        ("defineProperty past the end grows the array",
         "(function(){ var a = [1]; Object.defineProperty(a, '3', { value: 4 }); var d = Object.getOwnPropertyDescriptor(a, 3); return a.length === 4 && a[3] === 4 && !(1 in a) && !d.writable && !d.enumerable && !d.configurable; })()"),
        ("defineProperty length shrinks the array",
         "(function(){ var a = [1, 2, 3]; Object.defineProperty(a, 'length', { value: 1 }); var b = [1, 2, 3]; Object.defineProperty(b, 'length', { value: 1, writable: false }); return a.length === 1 && !(2 in a) && b.length === 1 && !(1 in b) && !Object.getOwnPropertyDescriptor(b, 'length').writable; })()"),
        ("defineProperty length stops at a non-configurable element",
         "(function(){ var a = [1, 2, 3]; Object.defineProperty(a, 1, { configurable: false }); try { Object.defineProperty(a, 'length', { value: 0, writable: false }); return false; } catch (e) { return e instanceof TypeError && a.length === 2 && !Object.getOwnPropertyDescriptor(a, 'length').writable; } })()"),
        ("defineProperty length: invalid value, read-only length",
         "(function(){ var a = [1], r; try { Object.defineProperty(a, 'length', { value: -1 }); r = false; } catch (e) { r = e instanceof RangeError; } Object.defineProperty(a, 'length', { writable: false }); return r && Reflect.defineProperty(a, 'length', { value: 1 }) && !Reflect.defineProperty(a, 'length', { value: 0 }) && !Reflect.defineProperty(a, 'length', { writable: true }); })()"),

        // Typed arrays, arguments, templates, readers.
        ("typed arrays cannot be frozen or sealed with elements",
         "(function(){ var n = 0; try { Object.freeze(new Uint8Array(2)); } catch (e) { if (e instanceof TypeError) n++; } try { Object.seal(new Uint8Array(2)); } catch (e) { if (e instanceof TypeError) n++; } return n === 2 && Object.isFrozen(Object.freeze(new Uint8Array(0))) && Object.isSealed(Object.seal(new Uint8Array(0))); })()"),
        ("typed array integrity tests and descriptors",
         "(function(){ var u = Object.preventExtensions(new Uint8Array(2)); u[0] = 3; var d = Object.getOwnPropertyDescriptor(u, 0); return u[0] === 3 && !Object.isFrozen(u) && !Object.isSealed(u) && d.value === 3 && d.writable && d.configurable; })()"),
        ("a frozen arguments object ignores sloppy writes",
         "(function(){ var f = function(){ Object.freeze(arguments); arguments[0] = 9; return arguments[0]; }; return f(1) === 1; })()"),
        ("tagged template objects are frozen",
         "(function(){ function tag(s){ return s; } var s = tag`a${1}b`; try { (function(){ 'use strict'; s[0] = 'z'; })(); return false; } catch (e) { return e instanceof TypeError && Object.isFrozen(s) && Object.isFrozen(s.raw) && s[0] === 'a'; } })()"),
        ("readers of frozen arrays are unaffected",
         "(function(){ var a = Object.freeze([1, 2, 3]), s = 0; for (var i = 0; i < 3; i++) s += a[i]; for (var x of a) s += x; return s === 12 && a.map(function(v){ return v * 2; }).join() === '2,4,6' && a.slice(1).join() === '2,3' && [].concat(a).length === 3 && [...a].length === 3 && a.indexOf(2) === 1 && Array.from(a).join() === '1,2,3'; })()"),
        ("Object.assign into a frozen array throws",
         "(function(){ try { Object.assign(Object.freeze([1]), [2]); return false; } catch (e) { return e instanceof TypeError; } })()"),
        ("Array.from into a frozen constructed result throws",
         "(function(){ var C = function(){ return Object.freeze([]); }; try { Array.from.call(C, [1]); return false; } catch (e) { return e instanceof TypeError; } })()"),
        ("ordinary arrays keep their fast behaviour",
         "(function(){ var a = []; for (var i = 0; i < 1000; i++) a[i] = i; for (var j = 0; j < 1000; j++) a.push(j); a.length = 10; delete a[3]; a.reverse(); return a.length === 10 && !(6 in a) && a[0] === 9 && Object.getOwnPropertyDescriptor(a, 0).configurable && !Object.isSealed(a); })()"),
    ]

    mutating func testArrayIntegrity() {
        runTrueCases("ArrayIntegrity", JeffJSTestRunner.arrayIntegrityCases)
    }
}
