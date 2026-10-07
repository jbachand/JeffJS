// ProxyReflectionConformance.swift
// JeffJS — conformance group "ProxyReflection" (NamedNodeMap fixer, 2026-10-07).
// A Proxy's internal methods reached from the reflective entry points (ES2024 §10.5):
// - Object.getOwnPropertyDescriptor / Reflect.getOwnPropertyDescriptor call the
//   `getOwnPropertyDescriptor` trap (§10.5.5) and complete + check its answer; they read
//   the proxy object's own (empty) shape and always answered undefined.
// - Object.defineProperty / Reflect.defineProperty call the `defineProperty` trap
//   (§10.5.6) with a FromPropertyDescriptor object; a falsish answer is a TypeError /
//   false. They defined onto the proxy object itself.
// - Reflect.deleteProperty calls the `deleteProperty` trap (it used the shape-level
//   delete: no trap, and false for a missing property).
// - A falsish `set` trap is a TypeError in strict code (§10.5.9 + PutValue).
// - Reflect.set(target, key, value, receiver) honours the receiver (OrdinarySet,
//   §10.1.9.2): the receiver's own property is written through its [[GetOwnProperty]]
//   / [[DefineOwnProperty]], a setter is called with it as `this`.
// - for-in over a proxy also visits its prototype's enumerable keys (§14.7.5.9).
// Found with the DOM's NamedNodeMap (`element.attributes`, a WebIDL legacy platform
// object: indexed + named properties) which the app implements as a Proxy; the last
// case is that object's shape with WebKit's answers.
//
// Every case is (name, JS expression that must evaluate to `true`).

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    static let proxyReflectionCases: [(String, String)] = [
        ("Object.getOwnPropertyDescriptor calls the trap and completes the descriptor",
         #"(function(){ var log = []; var p = new Proxy({}, { getOwnPropertyDescriptor: function(t, k){ log.push(k); return k === 'x' ? { value: 1, configurable: true } : undefined; } }); var d = Object.getOwnPropertyDescriptor(p, 'x'); return JSON.stringify(d) === '{"value":1,"writable":false,"enumerable":false,"configurable":true}' && Object.getOwnPropertyDescriptor(p, 'y') === undefined && log.join() === 'x,y'; })()"#),
        ("Reflect.getOwnPropertyDescriptor: the trap, and the target's own (accessor) descriptor without one",
         #"(function(){ var p = new Proxy({}, { getOwnPropertyDescriptor: function(){ return { get: function(){ return 2; }, enumerable: true, configurable: true }; } }); var d = Reflect.getOwnPropertyDescriptor(p, 'a'); var t = {}; Object.defineProperty(t, 'g', { get: function(){ return 3; }, configurable: true }); var d2 = Object.getOwnPropertyDescriptor(new Proxy(t, {}), 'g'); return typeof d.get === 'function' && d.set === undefined && d.enumerable === true && !('value' in d) && typeof d2.get === 'function' && d2.get() === 3; })()"#),
        ("getOwnPropertyDescriptor trap invariants are TypeErrors",
         #"(function(){ function te(f){ try { f(); return false; } catch (e) { return e instanceof TypeError; } } var t = {}; Object.defineProperty(t, 'fixed', { value: 1 }); var p = new Proxy(t, { getOwnPropertyDescriptor: function(t, k){ if (k === 'fixed') return undefined; if (k === 'nc') return { value: 1, configurable: false }; return 5; } }); return te(function(){ Object.getOwnPropertyDescriptor(p, 'fixed'); }) && te(function(){ Object.getOwnPropertyDescriptor(p, 'nc'); }) && te(function(){ Object.getOwnPropertyDescriptor(p, 'other'); }); })()"#),
        ("hasOwnProperty, propertyIsEnumerable and Object.keys agree with the trap",
         #"(function(){ var p = new Proxy({}, { ownKeys: function(){ return ['a', 'b']; }, getOwnPropertyDescriptor: function(t, k){ return k === 'a' ? { value: 1, enumerable: true, configurable: true } : k === 'b' ? { value: 2, enumerable: false, configurable: true } : undefined; } }); return p.hasOwnProperty('b') && !p.hasOwnProperty('c') && p.propertyIsEnumerable('a') && !p.propertyIsEnumerable('b') && Object.keys(p).join() === 'a'; })()"#),
        ("Object.defineProperty / Reflect.defineProperty call the trap with a descriptor object of the given fields",
         #"(function(){ var seen = []; var p = new Proxy({}, { defineProperty: function(t, k, d){ seen.push(k + ':' + Object.keys(d).join('+')); if (k === 'no') return false; return Reflect.defineProperty(t, k, d); } }); Object.defineProperty(p, 'a', { value: 1, enumerable: true }); var r1 = Reflect.defineProperty(p, 'no', { value: 2 }); var thrown = false; try { Object.defineProperty(p, 'no', { get: function(){} }); } catch (e) { thrown = e instanceof TypeError; } return seen.join(' ') === 'a:value+enumerable no:value no:get' && r1 === false && thrown && p.a === 1; })()"#),
        ("defineProperty without a trap reaches the target (accessors included)",
         #"(function(){ var t = {}; var p = new Proxy(t, {}); Object.defineProperty(p, 'g', { get: function(){ return 7; }, configurable: true }); return t.g === 7 && Object.getOwnPropertyDescriptor(t, 'g').get() === 7 && Reflect.defineProperty(p, 'v', { value: 1 }) && t.v === 1; })()"#),
        ("Reflect.deleteProperty calls the trap; a missing property deletes as true",
         #"(function(){ var log = []; var p = new Proxy({ x: 1 }, { deleteProperty: function(t, k){ log.push(k); return k !== 'keep'; } }); var o = {}; Object.defineProperty(o, 'nc', { value: 1 }); return Reflect.deleteProperty(p, 'x') === true && Reflect.deleteProperty(p, 'keep') === false && log.join() === 'x,keep' && Reflect.deleteProperty({}, 'missing') === true && Reflect.deleteProperty(o, 'nc') === false; })()"#),
        ("a falsish set trap throws in strict code and is ignored in sloppy code",
         #"(function(){ var p = new Proxy({}, { set: function(){ return false; } }); p.a = 1; var strict = (function(){ 'use strict'; try { p.a = 1; return 'ok'; } catch (e) { return e instanceof TypeError ? 'te' : e.name; } })(); return strict === 'te' && p.a === undefined; })()"#),
        ("Reflect.set with a receiver writes the receiver, through its traps",
         #"(function(){ var t = { w: 0 }, r = {}; var ok1 = Reflect.set(t, 'w', 5, r); var ro = {}; Object.defineProperty(ro, 'w', { value: 1, writable: false, configurable: true }); var ok2 = Reflect.set(t, 'w', 6, ro); var self; var s = { set z(v){ self = this; } }; Reflect.set(s, 'z', 1, r); var log = []; var px = new Proxy({}, { set: function(tt, k, v, rr){ return Reflect.set(tt, k, v, rr); }, defineProperty: function(tt, k, d){ log.push('def:' + k); return Reflect.defineProperty(tt, k, d); }, getOwnPropertyDescriptor: function(tt, k){ log.push('gopd:' + k); return Reflect.getOwnPropertyDescriptor(tt, k); } }); px.q = 3; return ok1 && t.w === 0 && r.w === 5 && ok2 === false && ro.w === 1 && self === r && log.join() === 'gopd:q,def:q' && px.q === 3; })()"#),
        ("for-in over a proxy visits its prototype's enumerable keys, shadowed by the proxy's own properties",
         #"(function(){ var proto = { inherited: 1, shadow: 2 }; var p = new Proxy(Object.create(proto), { ownKeys: function(){ return ['own', 'shadow']; }, getOwnPropertyDescriptor: function(t, k){ return k === 'own' || k === 'shadow' ? { value: 0, enumerable: k === 'own', configurable: true } : undefined; } }); var ks = []; for (var k in p) ks.push(k); var q = new Proxy(Object.create(proto), {}); q.mine = 1; var ks2 = []; for (var k2 in q) ks2.push(k2); return ks.join() === 'own,inherited' && ks2.join() === 'mine,inherited,shadow'; })()"#),
        ("a NamedNodeMap-shaped legacy platform object answers as WebKit's element.attributes does",
         #"(function(){ var names = ['id', 'data-x', 'item']; var P = {}; Object.defineProperty(P, 'item', { value: function(i){ return null; }, enumerable: true, configurable: true }); var t = Object.create(P); function idx(k){ return typeof k === 'string' && /^(0|[1-9][0-9]*)$/.test(k) ? +k : -1; } function named(k){ return typeof k === 'string' && names.indexOf(k) >= 0 && !Object.prototype.hasOwnProperty.call(t, k) && !(k in P) ? '@' + k : null; } var a = new Proxy(t, { get: function(t, k, r){ var i = idx(k); if (i >= 0) return i < names.length ? '@' + names[i] : undefined; return named(k) || Reflect.get(t, k, r); }, getOwnPropertyDescriptor: function(t, k){ var i = idx(k); if (i >= 0 && i < names.length) return { value: '@' + names[i], writable: false, enumerable: true, configurable: true }; var n = named(k); return n ? { value: n, writable: false, enumerable: false, configurable: true } : Reflect.getOwnPropertyDescriptor(t, k); }, defineProperty: function(t, k, d){ if (idx(k) >= 0 || (typeof k === 'string' && names.indexOf(k) >= 0 && !Object.prototype.hasOwnProperty.call(t, k))) return false; return Reflect.defineProperty(t, k, d); }, set: function(t, k, v, r){ if (idx(k) >= 0 || named(k)) return false; return Reflect.set(t, k, v, r); }, deleteProperty: function(t, k){ var i = idx(k); if (i >= 0) return i >= names.length && Reflect.deleteProperty(t, k); return !named(k) && Reflect.deleteProperty(t, k); }, ownKeys: function(t){ return ['0', '1', '2'].concat(names, Reflect.ownKeys(t)); } }); var d0 = JSON.stringify(Object.getOwnPropertyDescriptor(a, '0')), dn = JSON.stringify(Object.getOwnPropertyDescriptor(a, 'id')); var strict = (function(){ 'use strict'; try { a.id = 5; return 'ok'; } catch (e) { return e.name; } })(); a.zz = 1; var ks = []; for (var k in a) ks.push(k); return d0 === '{"value":"@id","writable":false,"enumerable":true,"configurable":true}' && dn === '{"value":"@id","writable":false,"enumerable":false,"configurable":true}' && Reflect.set(a, 'id', 1) === false && Reflect.set(a, '0', 1) === false && Reflect.set(a, '9', 1) === false && Reflect.defineProperty(a, '9', { value: 1 }) === false && Reflect.deleteProperty(a, 'id') === false && Reflect.deleteProperty(a, '9') === true && strict === 'TypeError' && a.zz === 1 && Object.getOwnPropertyNames(a).join() === '0,1,2,id,data-x,item,zz' && ks.join() === '0,1,2,item,zz'; })()"#),
    ]

    mutating func testProxyReflection() {
        let (_, ctx) = makeCtx()
        for (name, js) in JeffJSTestRunner.proxyReflectionCases {
            let r = ctx.eval(input: js, filename: "<ProxyReflection>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            if r.isException {
                let exc = ctx.getException()
                assert(false, "ProxyReflection: \(name) threw \(ctx.toSwiftString(exc) ?? "?")")
                exc.freeValue()
            } else {
                assert(r.isBool && r.toBool(), "ProxyReflection: \(name) -> \(ctx.toSwiftString(r) ?? "?")")
            }
            r.freeValue()
        }
    }
}
