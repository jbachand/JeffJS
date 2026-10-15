// JeffJSProxyReflection.swift
// JeffJS
//
// A Proxy's [[GetOwnProperty]], [[DefineOwnProperty]] and [[Set]]-with-receiver for the
// reflective entry points (ES2024 §10.5.5, §10.5.6, §10.1.9.2): Object.getOwnPropertyDescriptor(s),
// Object.defineProperty / defineProperties, Reflect.getOwnPropertyDescriptor / defineProperty /
// set(target, key, value, receiver). They read and wrote the proxy object's own (empty) shape:
// `Object.getOwnPropertyDescriptor(proxy, k)` was always undefined and `Reflect.defineProperty`
// never reached the `defineProperty` trap. Found with the DOM's NamedNodeMap (`element.attributes`
// is a legacy platform object: a Proxy in the app's polyfill), NamedNodeMap fixer 2026-10-07.

import Foundation

nonisolated extension JeffJSContext {

    @inline(__always)
    func isProxyObject(_ o: JeffJSObject) -> Bool {
        o.classID == JeffJSClassID.proxy.rawValue || o.classID == JSClassID.JS_CLASS_PROXY.rawValue
    }

    /// GetMethod(handler, name): an owned callable, `.undefined` when the handler has none,
    /// `.exception` when reading it threw or it is not callable.
    func proxyTrapMethod(_ pd: JeffJSProxyData, _ name: String) -> JeffJSValue {
        let a = rt.findAtom(name)
        let trap = getProperty(obj: pd.handler, atom: a)
        rt.freeAtom(a)
        if trap.isException { return trap }
        if trap.isNullOrUndefined { return .undefined }
        guard let t = trap.toObject(), t.isCallable else {
            trap.freeValue()
            return throwTypeError(message: "'\(name)' on proxy: trap is not a function")
        }
        return trap
    }

    /// The property key a trap receives (a String or the Symbol itself), owned.
    func proxyTrapKey(_ atom: UInt32) -> JeffJSValue {
        if rt.atomIsSymbol(atom), let sym = rt.symbolStringForAtom(atom) {
            return JeffJSValue.borrowedSymbol(sym).dupValue()
        }
        if let name = rt.atomToString(atom) { return newStringValue(name) }
        return .undefined
    }

    /// A Property Descriptor record (ES §6.2.6); present fields only. Values are owned.
    struct ReflectPropertyDescriptor {
        var value: JeffJSValue? = nil
        var writable: Bool? = nil
        var getter: JeffJSValue? = nil
        var setter: JeffJSValue? = nil
        var enumerable: Bool? = nil
        var configurable: Bool? = nil
        var isAccessor: Bool { getter != nil || setter != nil }
        var isData: Bool { value != nil || writable != nil }
        func free() { value?.freeValue(); getter?.freeValue(); setter?.freeValue() }
    }

    /// ToPropertyDescriptor (ES §6.2.6.5); nil when it threw.
    func toReflectPropertyDescriptor(_ o: JeffJSValue) -> ReflectPropertyDescriptor? {
        guard o.isObject else {
            _ = throwTypeError(message: "Property description must be an object")
            return nil
        }
        var d = ReflectPropertyDescriptor()
        func field(_ name: String) -> JeffJSValue? {
            let a = rt.findAtom(name)
            defer { rt.freeAtom(a) }
            guard hasProperty(obj: o, atom: a) else { return nil }
            return getProperty(obj: o, atom: a)
        }
        func fail(_ v: JeffJSValue?) -> ReflectPropertyDescriptor? { v?.freeValue(); d.free(); return nil }
        if let v = field("enumerable") { if v.isException { return fail(nil) }; d.enumerable = toBool(v); v.freeValue() }
        if let v = field("configurable") { if v.isException { return fail(nil) }; d.configurable = toBool(v); v.freeValue() }
        if let v = field("value") { if v.isException { return fail(nil) }; d.value = v }
        if let v = field("writable") { if v.isException { return fail(nil) }; d.writable = toBool(v); v.freeValue() }
        if let v = field("get") {
            if v.isException { return fail(nil) }
            if !v.isUndefined && !(v.toObject()?.isCallable ?? false) {
                _ = throwTypeError(message: "Getter must be a function.")
                return fail(v)
            }
            d.getter = v
        }
        if let v = field("set") {
            if v.isException { return fail(nil) }
            if !v.isUndefined && !(v.toObject()?.isCallable ?? false) {
                _ = throwTypeError(message: "Setter must be a function.")
                return fail(v)
            }
            d.setter = v
        }
        if d.isAccessor && d.isData {
            _ = throwTypeError(message: "Invalid property descriptor. Cannot both specify accessors and a value or writable attribute")
            return fail(nil)
        }
        return d
    }

    /// FromPropertyDescriptor (ES §6.2.6.4): the fields present, in the spec's order.
    func fromReflectPropertyDescriptor(_ d: ReflectPropertyDescriptor) -> JeffJSValue {
        let o = newPlainObject()
        if let v = d.value { _ = setPropertyStr(obj: o, name: "value", value: v.dupValue()) }
        if let w = d.writable { _ = setPropertyStr(obj: o, name: "writable", value: .newBool(w)) }
        if let g = d.getter { _ = setPropertyStr(obj: o, name: "get", value: g.dupValue()) }
        if let s = d.setter { _ = setPropertyStr(obj: o, name: "set", value: s.dupValue()) }
        if let e = d.enumerable { _ = setPropertyStr(obj: o, name: "enumerable", value: .newBool(e)) }
        if let c = d.configurable { _ = setPropertyStr(obj: o, name: "configurable", value: .newBool(c)) }
        return o
    }

    private func descriptorFlag(_ desc: JeffJSValue, _ name: String) -> Bool {
        let v = getPropertyStr(obj: desc, name: name)
        defer { v.freeValue() }
        return toBool(v)
    }

    private func keyName(_ atom: UInt32) -> String { rt.atomToString(atom) ?? "" }

    /// [[GetOwnProperty]] of a Proxy (ES §10.5.5): the trap's answer, completed and checked
    /// against the target's invariants, or the target's own descriptor when there is no trap.
    func proxyGetOwnPropertyDescriptor(_ pd: JeffJSProxyData, key: JeffJSValue, atom: UInt32) -> JeffJSValue {
        if pd.isRevoked {
            return throwTypeError(message: "Cannot perform 'getOwnPropertyDescriptor' on a proxy that has been revoked")
        }
        let trap = proxyTrapMethod(pd, "getOwnPropertyDescriptor")
        if trap.isException { return trap }
        if trap.isUndefined { return getOwnPropertyDescriptor(pd.target, key: key) }
        let k = proxyTrapKey(atom)
        let r = callFunction(trap, thisVal: pd.handler, args: [pd.target, k])
        trap.freeValue(); k.freeValue()
        if r.isException { return r }
        if !r.isObject && !r.isUndefined {
            r.freeValue()
            return throwTypeError(message: "result of 'getOwnPropertyDescriptor' call should either be an Object or undefined")
        }
        let td = getOwnPropertyDescriptor(pd.target, key: key)
        if td.isException { r.freeValue(); return td }
        defer { td.freeValue() }
        let targetConfigurable = td.isObject ? descriptorFlag(td, "configurable") : true
        if r.isUndefined {
            if td.isUndefined { return .undefined }
            if !targetConfigurable {
                return throwTypeError(message: "When the result of 'getOwnPropertyDescriptor' is undefined the target must be configurable")
            }
            if !isExtensible(pd.target) {
                return throwTypeError(message: "When 'getOwnPropertyDescriptor' returns undefined, the 'target' of a Proxy should be extensible")
            }
            return .undefined
        }
        guard var d = toReflectPropertyDescriptor(r) else { r.freeValue(); return .exception }
        r.freeValue()
        defer { d.free() }
        // CompletePropertyDescriptor (§6.2.6.6).
        if d.isAccessor {
            if d.getter == nil { d.getter = .undefined }
            if d.setter == nil { d.setter = .undefined }
        } else {
            if d.value == nil { d.value = .undefined }
            if d.writable == nil { d.writable = false }
        }
        if d.enumerable == nil { d.enumerable = false }
        if d.configurable == nil { d.configurable = false }
        if td.isUndefined && !isExtensible(pd.target) {
            return throwTypeError(message: "'getOwnPropertyDescriptor' returned a descriptor for property '\(keyName(atom))' that does not exist on the non-extensible proxy target")
        }
        if d.configurable == false && (td.isUndefined || targetConfigurable) {
            return throwTypeError(message: "Result from 'getOwnPropertyDescriptor' can't be non-configurable when the 'target' doesn't have it as an own property or if it is a configurable own property on 'target'")
        }
        return fromReflectPropertyDescriptor(d)
    }

    /// [[DefineOwnProperty]] of a Proxy (ES §10.5.6) for definePropertyFromDescriptor: `obj` on
    /// success, false (or a TypeError when `shouldThrow`) when the trap refuses.
    func proxyDefineOwnProperty(_ obj: JeffJSValue, _ pd: JeffJSProxyData, key: JeffJSValue, atom: UInt32,
                                desc: JeffJSValue, shouldThrow: Bool) -> JeffJSValue {
        if pd.isRevoked {
            return throwTypeError(message: "Cannot perform 'defineProperty' on a proxy that has been revoked")
        }
        guard let d = toReflectPropertyDescriptor(desc) else { return .exception }
        defer { d.free() }
        let trap = proxyTrapMethod(pd, "defineProperty")
        if trap.isException { return trap }
        if trap.isUndefined {
            let r = definePropertyFromDescriptor(pd.target, key: key, desc: desc, shouldThrow: shouldThrow)
            if r.isException || (r.isBool && !r.toBool()) { return r }
            return obj
        }
        let descObj = fromReflectPropertyDescriptor(d)
        let k = proxyTrapKey(atom)
        let r = callFunction(trap, thisVal: pd.handler, args: [pd.target, k, descObj])
        trap.freeValue(); k.freeValue(); descObj.freeValue()
        if r.isException { return r }
        let ok = toBool(r)
        r.freeValue()
        if !ok {
            if shouldThrow {
                return throwTypeError(message: "Proxy's 'defineProperty' trap returned false when defining property '\(keyName(atom))'")
            }
            return .JS_FALSE
        }
        let td = getOwnPropertyDescriptor(pd.target, key: key)
        if td.isException { return td }
        defer { td.freeValue() }
        let settingConfigFalse = d.configurable == false
        if td.isUndefined {
            if !isExtensible(pd.target) {
                return throwTypeError(message: "Proxy's 'defineProperty' trap returned true even though getOwnPropertyDescriptor of the Proxy's target returned undefined and the target is non-extensible")
            }
            if settingConfigFalse {
                return throwTypeError(message: "Proxy's 'defineProperty' trap returned true for a non-configurable field even though getOwnPropertyDescriptor of the Proxy's target returned undefined")
            }
        } else if settingConfigFalse && descriptorFlag(td, "configurable") {
            return throwTypeError(message: "Proxy's 'defineProperty' trap did not define a non-configurable property on its target even though the input descriptor to the trap said it must do so")
        }
        return obj
    }

    /// OrdinarySet (ES §10.1.9.2) with a Receiver other than the target, for
    /// `Reflect.set(target, key, value, receiver)`: 1 written, 0 refused, -1 exception.
    func reflectSet(_ o: JeffJSValue, key: JeffJSValue, atom: UInt32, value: JeffJSValue,
                    receiver: JeffJSValue, depth: Int = 0) -> Int {
        guard let oo = o.toObject() else { return 0 }
        if depth > 10_000 {
            _ = throwRangeError(message: "Maximum call stack size exceeded.")
            return -1
        }
        if isProxyObject(oo), case .proxyData(let pd) = oo.payload {
            if pd.isRevoked {
                _ = throwTypeError(message: "Cannot perform 'set' on a proxy that has been revoked")
                return -1
            }
            let trap = proxyTrapMethod(pd, "set")
            if trap.isException { return -1 }
            if trap.isUndefined { return reflectSet(pd.target, key: key, atom: atom, value: value, receiver: receiver, depth: depth + 1) }
            let k = proxyTrapKey(atom)
            let r = callFunction(trap, thisVal: pd.handler, args: [pd.target, k, value, receiver])
            trap.freeValue(); k.freeValue()
            if r.isException { return -1 }
            let ok = toBool(r)
            r.freeValue()
            return ok ? 1 : 0
        }
        let own = getOwnPropertyDescriptor(o, key: key)
        if own.isException { return -1 }
        if own.isUndefined {
            let parent = getPrototypeOf(o)
            if parent.isException { return -1 }
            defer { parent.freeValue() }
            if parent.isObject {
                return reflectSet(parent, key: key, atom: atom, value: value, receiver: receiver, depth: depth + 1)
            }
            return writeOnReceiver(key: key, value: value, receiver: receiver)
        }
        defer { own.freeValue() }
        if descriptorHas(own, "get") || descriptorHas(own, "set") {
            let setter = getPropertyStr(obj: own, name: "set")
            defer { setter.freeValue() }
            guard setter.toObject()?.isCallable == true else { return 0 }
            let r = callFunction(setter, thisVal: receiver, args: [value])
            if r.isException { return -1 }
            r.freeValue()
            return 1
        }
        if !descriptorFlag(own, "writable") { return 0 }
        return writeOnReceiver(key: key, value: value, receiver: receiver)
    }

    /// OrdinarySetWithOwnDescriptor steps 2.c-2.e: update or create the receiver's own data property.
    private func writeOnReceiver(key: JeffJSValue, value: JeffJSValue, receiver: JeffJSValue) -> Int {
        guard receiver.isObject else { return 0 }
        let existing = getOwnPropertyDescriptor(receiver, key: key)
        if existing.isException { return -1 }
        defer { existing.freeValue() }
        let d = newPlainObject()
        defer { d.freeValue() }
        if existing.isObject {
            if descriptorHas(existing, "get") || descriptorHas(existing, "set") { return 0 }
            if !descriptorFlag(existing, "writable") { return 0 }
            _ = setPropertyStr(obj: d, name: "value", value: value.dupValue())
        } else {
            _ = setPropertyStr(obj: d, name: "value", value: value.dupValue())
            _ = setPropertyStr(obj: d, name: "writable", value: .JS_TRUE)
            _ = setPropertyStr(obj: d, name: "enumerable", value: .JS_TRUE)
            _ = setPropertyStr(obj: d, name: "configurable", value: .JS_TRUE)
        }
        let r = definePropertyFromDescriptor(receiver, key: key, desc: d, shouldThrow: false)
        if r.isException { return -1 }
        return (r.isBool && !r.toBool()) ? 0 : 1
    }
}
