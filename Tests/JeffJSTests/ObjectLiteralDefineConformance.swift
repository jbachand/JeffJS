// ObjectLiteralDefineConformance.swift
// JeffJS — conformance group "ObjectLiteralDefine" (ES §13.2.5.5
// PropertyDefinitionEvaluation: a computed key is CreateDataPropertyOrThrow;
// §7.3.25 CopyDataProperties for `{...src}` and object rest: [[Get]] from
// ToObject(src) over its [[OwnPropertyKeys]], then CreateDataPropertyOrThrow).
// `{[k]: v}` compiled to put_array_el ([[Set]]): an Object.prototype setter for
// the key fired and nothing was defined, a computed "__proto__" key replaced the
// prototype; `{...src}` / `{...rest} = src` used [[Set]] too and only walked a
// plain object's shape, so array elements, string characters and proxy keys were
// never copied (`{...[7]}` was {}). `__proto__: v` (non-computed, non-shorthand)
// still sets the prototype.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let objectLiteralDefineCases: [(String, String)] = [
        ("a computed key does not run an Object.prototype setter",
         #"(function(){ var hits = 0; Object.defineProperty(Object.prototype, '__olx', { set: function(v){ hits++; }, get: function(){ return 'proto'; }, configurable: true }); try { var k = '__olx'; var o = { [k]: 2 }; return hits === 0 && o.__olx === 2 && Object.getOwnPropertyNames(o).join() === '__olx' && Object.getOwnPropertyDescriptor(o, '__olx').enumerable; } finally { delete Object.prototype.__olx; } })()"#),
        ("a computed integer key does not run an Object.prototype setter",
         #"(function(){ var hits = 0; Object.defineProperty(Object.prototype, '7', { set: function(v){ hits++; }, configurable: true }); try { var o = { [7]: 'a', [3 + 4 + '']: 'b' }; return hits === 0 && o[7] === 'b' && Object.keys(o).join() === '7'; } finally { delete Object.prototype[7]; } })()"#),
        ("a computed key ignores a non-writable inherited property",
         #"(function(){ var p = Object.defineProperty({}, 'ro', { value: 1, writable: false }); var o = { __proto__: p, ['ro']: 2 }; return o.ro === 2 && Object.getOwnPropertyDescriptor(o, 'ro').writable; })()"#),
        ("['__proto__']: v defines an own property; __proto__: v sets the prototype",
         #"(function(){ var proto = { m: 1 }; var a = { ['__proto__']: proto }, b = { __proto__: proto }, c = { '__proto__': proto }; var __proto__ = proto; var d = { __proto__ }; return Object.getPrototypeOf(a) === Object.prototype && Object.getOwnPropertyNames(a).join() === '__proto__' && a.__proto__ === proto && Object.getPrototypeOf(b) === proto && Object.getOwnPropertyNames(b).length === 0 && Object.getPrototypeOf(c) === proto && Object.getPrototypeOf(d) === Object.prototype && Object.getOwnPropertyNames(d).join() === '__proto__'; })()"#),
        ("computed symbol keys, evaluation order, later keys win",
         #"(function(){ var log = []; function k(n){ log.push('k' + n); return 'p'; } function v(n){ log.push('v' + n); return n; } var s = Symbol('s'); var o = { [k(1)]: v(1), [k(2)]: v(2), [s]: 3, [Symbol.toStringTag]: 'T' }; return log.join() === 'k1,v1,k2,v2' && o.p === 2 && o[s] === 3 && String(o) === '[object T]'; })()"#),
        ("spread does not run an Object.prototype setter and defines own data properties",
         #"(function(){ var hits = 0; Object.defineProperty(Object.prototype, '__ols', { set: function(v){ hits++; }, get: function(){ return 'proto'; }, configurable: true }); try { var o = { ...{ __ols: 3 } }; var { ...r } = { __ols: 4 }; return hits === 0 && o.__ols === 3 && r.__ols === 4 && Object.getOwnPropertyDescriptor(o, '__ols').writable; } finally { delete Object.prototype.__ols; } })()"#),
        ("spread of a frozen object gives writable properties; a getter is read once",
         #"(function(){ var n = 0; var r = { ...Object.freeze({ x: 1 }), ...{ get g(){ n++; return 5; } } }; r.x = 2; var d = Object.getOwnPropertyDescriptor(r, 'g'); return r.x === 2 && n === 1 && d.value === 5 && d.writable && d.enumerable && d.configurable; })()"#),
        ("spread copies array elements, string characters, typed arrays, not length",
         #"(function(){ return JSON.stringify({ ...[7, , 9] }) === '{"0":7,"2":9}' && JSON.stringify({ ...'ab' }) === '{"0":"a","1":"b"}' && JSON.stringify({ ...new Uint8Array([4, 5]) }) === '{"0":4,"1":5}' && JSON.stringify({ ...null, ...undefined, ...5, ...true }) === '{}'; })()"#),
        ("spread through a Proxy uses ownKeys / getOwnPropertyDescriptor / get",
         #"(function(){ var log = []; var px = new Proxy({ a: 1, b: 2 }, { ownKeys: function(t){ log.push('keys'); return ['b', 'a']; }, getOwnPropertyDescriptor: function(t, k){ log.push('desc ' + k); return { value: t[k], enumerable: k === 'a', configurable: true }; }, get: function(t, k){ log.push('get ' + String(k)); return t[k] * 10; } }); var o = { ...px }; return JSON.stringify(o) === '{"a":10}' && log.indexOf('keys') === 0 && log.indexOf('get a') > 0 && log.indexOf('get b') < 0; })()"#),
        ("spread skips non-enumerable keys, keeps symbols, later spreads override",
         #"(function(){ var s = Symbol('s'); var src = { [s]: 1, b: 2 }; Object.defineProperty(src, 'hidden', { value: 3, enumerable: false }); var o = { a: 1, ...src, ...{ a: 2 }, b: 4 }; return o[s] === 1 && o.hidden === undefined && o.a === 2 && o.b === 4 && Object.getOwnPropertySymbols(o).length === 1; })()"#),
        ("object rest excludes the named keys (including computed and integer keys)",
         #"(function(){ var k = 'b'; var { a, [k]: bb, 0: z, ...rest } = { a: 1, b: 2, 0: 'z', c: 3, 1: 'y' }; var { x, ...r2 } = 'xyz'.split(''); return a === 1 && bb === 2 && z === 'z' && JSON.stringify(rest) === '{"1":"y","c":3}' && x === undefined && JSON.stringify(r2) === '{"0":"x","1":"y","2":"z"}'; })()"#),
        ("a class computed field is defined too",
         #"(function(){ var hits = 0; var k = 'cf'; class B { set cf(v){ hits++; } } class A extends B { [k] = 1; static [k + 's'] = 2; } var a = new A(); return hits === 0 && Object.getOwnPropertyDescriptor(a, 'cf').value === 1 && A.cfs === 2; })()"#),
    ]

    mutating func testObjectLiteralDefine() {
        runTrueCases("ObjectLiteralDefine", JeffJSTestRunner.objectLiteralDefineCases)
    }
}
