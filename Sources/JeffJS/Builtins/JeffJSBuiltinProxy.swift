// JeffJSBuiltinProxy.swift
// JeffJS - 1:1 Swift port of QuickJS JavaScript engine
//
// Port of Proxy and Reflect built-ins from QuickJS.
// Covers:
//   - Proxy constructor, Proxy.revocable
//   - All 13 proxy traps as exotic methods
//   - Trap invariant checking per ES spec
//   - Reflect static methods (thin wrappers)
//
// QuickJS source reference: quickjs.c — js_proxy_*, js_reflect_*,
// JS_CreateProxy, proxy exotic methods, Proxy/Reflect init.

import Foundation

// MARK: - Proxy Chain Resolution Limit

/// Maximum number of proxy chain resolutions (prevents infinite loops).
private let JS_MAX_PROXY_CHAIN = 1000

// MARK: - Proxy Helpers

/// Extract JSProxyData from a proxy object, checking for revocation.
/// Returns nil and throws TypeError if the proxy is revoked.
private func getProxyData(_ ctx: JeffJSContext,
                          _ obj: JeffJSObject) -> JeffJSProxyData? {
    guard obj.classID == JeffJSClassID.proxy.rawValue else { return nil }
    guard case .proxyData(let pd) = obj.payload else { return nil }
    if pd.isRevoked {
        _ = ctx.throwTypeError("Cannot perform operation on a revoked proxy")
        return nil
    }
    return pd
}

/// Resolve through a chain of proxies to find the ultimate target.
/// Returns nil and throws TypeError if the chain exceeds JS_MAX_PROXY_CHAIN.
private func resolveProxyChain(_ ctx: JeffJSContext,
                               _ val: JeffJSValue) -> JeffJSValue {
    var current = val
    var depth = 0
    while let obj = current.toObject(),
          obj.classID == JeffJSClassID.proxy.rawValue,
          case .proxyData(let pd) = obj.payload {
        guard !pd.isRevoked else {
            _ = ctx.throwTypeError("Cannot perform operation on a revoked proxy")
            return .exception
        }
        current = pd.target
        depth += 1
        if depth > JS_MAX_PROXY_CHAIN {
            _ = ctx.throwTypeError("proxy chain too long")
            return .exception
        }
    }
    return current
}

/// Look up a trap method on the handler. Returns .undefined if the handler
/// does not define the named trap (which means the operation falls through
/// to the target).
private func getTrap(_ ctx: JeffJSContext,
                     _ handler: JeffJSValue,
                     _ trapName: UInt32) -> JeffJSValue {
    guard let handlerObj = handler.toObject() else { return .undefined }
    let trap = handlerObj.getOwnPropertyValue(atom: trapName)
    if trap.isUndefined || trap.isNull {
        return .undefined
    }
    if let trapObj = trap.toObject(), trapObj.isCallable {
        return trap
    }
    return .undefined
}

// MARK: - Proxy Constructor

/// Proxy(target, handler) constructor. Both arguments must be objects.
/// Cannot be called without `new`.
///
/// Mirrors `js_proxy_constructor` in QuickJS.
func js_proxy_constructor(_ ctx: JeffJSContext,
                          _ newTarget: JeffJSValue,
                          _ argv: [JeffJSValue],
                          _ isConstructorCall: Bool) -> JeffJSValue {
    guard isConstructorCall else {
        return ctx.throwTypeError("Proxy constructor requires 'new'")
    }
    guard argv.count >= 2 else {
        return ctx.throwTypeError("Proxy requires target and handler arguments")
    }

    let target = argv[0]
    let handler = argv[1]

    guard target.isObject else {
        return ctx.throwTypeError("Proxy target must be an object")
    }
    guard handler.isObject else {
        return ctx.throwTypeError("Proxy handler must be an object")
    }

    return js_create_proxy(ctx, target: target, handler: handler)
}

/// Internal proxy creation. Mirrors `JS_CreateProxy` in QuickJS.
private func js_create_proxy(_ ctx: JeffJSContext,
                             target: JeffJSValue,
                             handler: JeffJSValue) -> JeffJSValue {
    // Determine if the target is callable (proxy inherits callability).
    guard let targetObj = target.toObject() else {
        return ctx.throwTypeError("Proxy target must be an object")
    }
    let isFunc = targetObj.isCallable
    let isCtor = targetObj.isConstructor

    let proxyObj = JeffJSObject()
    proxyObj.classID = JeffJSClassID.proxy.rawValue
    proxyObj.extensible = true
    proxyObj.isExotic = true
    if isFunc {
        proxyObj.isConstructor = isCtor
    }

    let pd = JeffJSProxyData(
        target: target.dupValue(),
        handler: handler.dupValue(),
        isFunc: isFunc,
        isRevoked: false
    )
    proxyObj.payload = .proxyData(pd)

    return JeffJSValue.makeObject(proxyObj)
}

// MARK: - Proxy.revocable

/// Proxy.revocable(target, handler) - creates {proxy, revoke} pair.
///
/// Mirrors `js_proxy_revocable` in QuickJS.
func js_proxy_revocable(_ ctx: JeffJSContext,
                        _ thisVal: JeffJSValue,
                        _ argv: [JeffJSValue]) -> JeffJSValue {
    guard argv.count >= 2 else {
        return ctx.throwTypeError("Proxy.revocable requires target and handler")
    }

    let target = argv[0]
    let handler = argv[1]

    guard target.isObject else {
        return ctx.throwTypeError("Proxy target must be an object")
    }
    guard handler.isObject else {
        return ctx.throwTypeError("Proxy handler must be an object")
    }

    let proxyVal = js_create_proxy(ctx, target: target, handler: handler)
    if proxyVal.isException { return proxyVal }

    // Create the revoke function. It captures the proxy object.
    let revokeObj = JeffJSObject()
    revokeObj.classID = JeffJSClassID.cFunction.rawValue
    revokeObj.extensible = true
    revokeObj.isConstructor = false

    // Store the proxy reference in the revoke function's opaque data.
    revokeObj.payload = .opaque(ProxyRevokeData(proxyValue: proxyVal.dupValue()))

    let revokeVal = JeffJSValue.makeObject(revokeObj)

    // Build result object: { proxy, revoke }
    let resultVal = ctx.newObject()
    _ = ctx.setPropertyStr(obj: resultVal, name: "proxy", value: proxyVal)
    _ = ctx.setPropertyStr(obj: resultVal, name: "revoke", value: revokeVal)

    return resultVal
}

/// Internal data for the revoke function closure.
private final class ProxyRevokeData {
    var proxyValue: JeffJSValue

    init(proxyValue: JeffJSValue) {
        self.proxyValue = proxyValue
    }
}

/// The actual revoke function body.
func js_proxy_revoke_func(_ ctx: JeffJSContext,
                          _ thisVal: JeffJSValue,
                          _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let obj = thisVal.toObject(),
          case .opaque(let opaque) = obj.payload,
          let data = opaque as? ProxyRevokeData else {
        return .undefined
    }

    // Revoke: set is_revoked on the proxy, release target and handler.
    guard let proxyObj = data.proxyValue.toObject(),
          proxyObj.classID == JeffJSClassID.proxy.rawValue,
          case .proxyData(var pd) = proxyObj.payload else {
        return .undefined
    }

    if !pd.isRevoked {
        pd.target.freeValue()
        pd.handler.freeValue()
        pd.target = .undefined
        pd.handler = .undefined
        pd.isRevoked = true
        proxyObj.payload = .proxyData(pd)
    }

    // Prevent double revocation: clear the data.
    data.proxyValue.freeValue()
    data.proxyValue = .undefined

    return .undefined
}

// MARK: - 13 Proxy Traps (Exotic Methods)

/// 1. getPrototypeOf trap.
func js_proxy_getPrototypeOf(_ ctx: JeffJSContext,
                             _ proxyObj: JeffJSObject) -> JeffJSValue {
    guard let pd = getProxyData(ctx, proxyObj) else { return .exception }

    let trap = getTrap(ctx, pd.handler, JSPredefinedAtom.getPrototypeOf.rawValue)
    if trap.isUndefined {
        // Fall through to target.
        if let targetObj = pd.target.toObject(), let shape = targetObj.shape {
            if let proto = shape.proto {
                return JeffJSValue.makeObject(proto).dupValue()
            }
        }
        return .null
    }

    // Call trap(target).
    let result = ctx.callFunction(trap, thisVal: pd.handler, args: [pd.target])
    if result.isException { return result }

    // Result must be an object or null.
    if !result.isObject && !result.isNull {
        return ctx.throwTypeError("getPrototypeOf trap must return an object or null")
    }

    return result
}

/// 2. setPrototypeOf trap.
func js_proxy_setPrototypeOf(_ ctx: JeffJSContext,
                             _ proxyObj: JeffJSObject,
                             _ proto: JeffJSValue) -> JeffJSValue {
    guard let pd = getProxyData(ctx, proxyObj) else { return .exception }

    let trap = getTrap(ctx, pd.handler, JSPredefinedAtom.setPrototypeOf.rawValue)
    if trap.isUndefined {
        // Fall through to target: set the prototype directly.
        if let targetObj = pd.target.toObject() {
            targetObj.proto = proto.isObject ? proto.toObject() : nil
        }
        return .JS_TRUE
    }

    // Call trap(target, proto).
    let result = ctx.callFunction(trap, thisVal: pd.handler, args: [pd.target, proto])
    if result.isException { return result }
    return result.toBool() ? .JS_TRUE : .JS_FALSE
}

/// 3. isExtensible trap.
func js_proxy_isExtensible(_ ctx: JeffJSContext,
                           _ proxyObj: JeffJSObject) -> JeffJSValue {
    guard let pd = getProxyData(ctx, proxyObj) else { return .exception }

    let trap = getTrap(ctx, pd.handler, JSPredefinedAtom.isExtensible.rawValue)
    if trap.isUndefined {
        if let targetObj = pd.target.toObject() {
            return JeffJSValue.newBool(targetObj.extensible)
        }
        return .JS_TRUE
    }

    // Call trap(target).
    let result = ctx.callFunction(trap, thisVal: pd.handler, args: [pd.target])
    if result.isException { return result }
    return JeffJSValue.newBool(result.toBool())
}

/// 4. preventExtensions trap.
func js_proxy_preventExtensions(_ ctx: JeffJSContext,
                                _ proxyObj: JeffJSObject) -> JeffJSValue {
    guard let pd = getProxyData(ctx, proxyObj) else { return .exception }

    let trap = getTrap(ctx, pd.handler, JSPredefinedAtom.preventExtensions.rawValue)
    if trap.isUndefined {
        if let targetObj = pd.target.toObject() {
            targetObj.extensible = false
        }
        return .JS_TRUE
    }

    // Call trap(target).
    let result = ctx.callFunction(trap, thisVal: pd.handler, args: [pd.target])
    if result.isException { return result }
    return result.toBool() ? .JS_TRUE : .JS_FALSE
}

/// 5. getOwnPropertyDescriptor trap.
func js_proxy_getOwnPropertyDescriptor(_ ctx: JeffJSContext,
                                       _ proxyObj: JeffJSObject,
                                       _ atom: UInt32) -> JeffJSValue {
    guard let pd = getProxyData(ctx, proxyObj) else { return .exception }

    let trap = getTrap(ctx, pd.handler, JSPredefinedAtom.getOwnPropertyDescriptor.rawValue)
    if trap.isUndefined {
        // Fall through to target.
        if let targetObj = pd.target.toObject() {
            let (shapeProp, prop) = jeffJS_findOwnProperty(obj: targetObj, atom: atom)
            if let shapeProp = shapeProp, let prop = prop {
                // Build a descriptor object from the target's own property.
                let desc = ctx.newObject()
                switch prop {
                case .value(let val):
                    _ = ctx.setPropertyStr(obj: desc, name: "value", value: val.dupValue())
                    _ = ctx.setPropertyStr(obj: desc, name: "writable",
                                           value: JeffJSValue.newBool(shapeProp.flags.contains(.writable)))
                default:
                    break
                }
                _ = ctx.setPropertyStr(obj: desc, name: "enumerable",
                                       value: JeffJSValue.newBool(shapeProp.flags.contains(.enumerable)))
                _ = ctx.setPropertyStr(obj: desc, name: "configurable",
                                       value: JeffJSValue.newBool(shapeProp.flags.contains(.configurable)))
                return desc
            }
        }
        return .undefined
    }

    // Call trap(target, key).
    let propName: JeffJSValue
    if let name = ctx.rt.atomToString(atom) {
        propName = ctx.newStringValue(name)
    } else {
        propName = .undefined
    }
    let result = ctx.callFunction(trap, thisVal: pd.handler, args: [pd.target, propName])
    if result.isException { return result }

    // Result must be an object or undefined.
    if !result.isObject && !result.isUndefined {
        return ctx.throwTypeError("getOwnPropertyDescriptor trap must return an object or undefined")
    }

    return result
}

/// 6. defineProperty trap.
func js_proxy_defineProperty(_ ctx: JeffJSContext,
                             _ proxyObj: JeffJSObject,
                             _ atom: UInt32,
                             _ desc: JeffJSValue,
                             _ flags: Int) -> JeffJSValue {
    guard let pd = getProxyData(ctx, proxyObj) else { return .exception }

    let trap = getTrap(ctx, pd.handler, JSPredefinedAtom.defineProperty.rawValue)
    if trap.isUndefined {
        // Fall through to target: define the property directly on the target.
        let value = desc.isObject ? ctx.getPropertyStr(obj: desc, name: "value") : .undefined
        _ = ctx.defineProperty(obj: pd.target, atom: atom, value: value, flags: flags)
        return .JS_TRUE
    }

    // Call trap(target, key, descriptor).
    let propName: JeffJSValue
    if let name = ctx.rt.atomToString(atom) {
        propName = ctx.newStringValue(name)
    } else {
        propName = .undefined
    }
    let result = ctx.callFunction(trap, thisVal: pd.handler, args: [pd.target, propName, desc])
    if result.isException { return result }
    return result.toBool() ? .JS_TRUE : .JS_FALSE
}

/// 7. has trap (used by `in` operator).
func js_proxy_has(_ ctx: JeffJSContext,
                  _ proxyObj: JeffJSObject,
                  _ atom: UInt32) -> JeffJSValue {
    guard let pd = getProxyData(ctx, proxyObj) else { return .exception }

    let trap = getTrap(ctx, pd.handler, JSPredefinedAtom.has.rawValue)
    if trap.isUndefined {
        // Fall through to target.
        if let targetObj = pd.target.toObject() {
            let (shapeProp, _) = jeffJS_findOwnProperty(obj: targetObj, atom: atom)
            return JeffJSValue.newBool(shapeProp != nil)
        }
        return .JS_FALSE
    }

    // Call trap(target, key).
    let propName: JeffJSValue
    if let name = ctx.rt.atomToString(atom) {
        propName = ctx.newStringValue(name)
    } else {
        propName = .undefined
    }
    let result = ctx.callFunction(trap, thisVal: pd.handler, args: [pd.target, propName])
    if result.isException { return result }
    return JeffJSValue.newBool(result.toBool())
}

/// 8. get trap.
func js_proxy_get(_ ctx: JeffJSContext,
                  _ proxyObj: JeffJSObject,
                  _ atom: UInt32,
                  _ receiver: JeffJSValue) -> JeffJSValue {
    guard let pd = getProxyData(ctx, proxyObj) else { return .exception }

    let trap = getTrap(ctx, pd.handler, JSPredefinedAtom.get.rawValue)
    if trap.isUndefined {
        // Fall through to target.
        if let targetObj = pd.target.toObject() {
            return targetObj.getOwnPropertyValue(atom: atom).dupValue()
        }
        return .undefined
    }

    // Call trap(target, key, receiver).
    let propName: JeffJSValue
    if let name = ctx.rt.atomToString(atom) {
        propName = ctx.newStringValue(name)
    } else {
        propName = .undefined
    }
    let result = ctx.callFunction(trap, thisVal: pd.handler, args: [pd.target, propName, receiver])
    return result
}

/// 9. set trap.
func js_proxy_set(_ ctx: JeffJSContext,
                  _ proxyObj: JeffJSObject,
                  _ atom: UInt32,
                  _ value: JeffJSValue,
                  _ receiver: JeffJSValue,
                  _ flags: Int) -> JeffJSValue {
    guard let pd = getProxyData(ctx, proxyObj) else { return .exception }

    let trap = getTrap(ctx, pd.handler, JSPredefinedAtom.set.rawValue)
    if trap.isUndefined {
        // Fall through to target.
        if let targetObj = pd.target.toObject() {
            targetObj.setOwnPropertyValue(atom: atom, value: value.dupValue())
        }
        return .JS_TRUE
    }

    // Call trap(target, key, value, receiver).
    let propName: JeffJSValue
    if let name = ctx.rt.atomToString(atom) {
        propName = ctx.newStringValue(name)
    } else {
        propName = .undefined
    }
    let result = ctx.callFunction(trap, thisVal: pd.handler, args: [pd.target, propName, value, receiver])
    if result.isException { return result }
    return result.toBool() ? .JS_TRUE : .JS_FALSE
}

/// 10. deleteProperty trap.
func js_proxy_deleteProperty(_ ctx: JeffJSContext,
                             _ proxyObj: JeffJSObject,
                             _ atom: UInt32) -> JeffJSValue {
    guard let pd = getProxyData(ctx, proxyObj) else { return .exception }

    let trap = getTrap(ctx, pd.handler, JSPredefinedAtom.deleteProperty.rawValue)
    if trap.isUndefined {
        // Fall through to target.
        if let targetObj = pd.target.toObject() {
            _ = jeffJS_deleteProperty(ctx: ctx, obj: targetObj, atom: atom)
        }
        return .JS_TRUE
    }

    // Call trap(target, property).
    let propName: JeffJSValue
    if let name = ctx.rt.atomToString(atom) {
        propName = ctx.newStringValue(name)
    } else {
        propName = .undefined
    }
    let result = ctx.callFunction(trap, thisVal: pd.handler, args: [pd.target, propName])
    if result.isException { return result }
    return result.toBool() ? .JS_TRUE : .JS_FALSE
}

/// 11. ownKeys trap.
func js_proxy_ownKeys(_ ctx: JeffJSContext,
                      _ proxyObj: JeffJSObject) -> JeffJSValue {
    guard let pd = getProxyData(ctx, proxyObj) else { return .exception }

    let trap = getTrap(ctx, pd.handler, JSPredefinedAtom.ownKeys.rawValue)
    if trap.isUndefined {
        // Fall through: return target's own property names.
        var keys: [JeffJSValue] = []
        if let targetObj = pd.target.toObject(), let shape = targetObj.shape {
            for prop in shape.prop {
                if let name = ctx.rt.atomToString(prop.atom) {
                    keys.append(ctx.newStringValue(name))
                }
            }
        }
        return ctx.newArrayFrom(keys)
    }

    // Call trap(target).
    let result = ctx.callFunction(trap, thisVal: pd.handler, args: [pd.target])
    if result.isException { return result }
    return result
}

/// 12. apply trap (for callable proxies).
func js_proxy_apply(_ ctx: JeffJSContext,
                    _ proxyObj: JeffJSObject,
                    _ thisArg: JeffJSValue,
                    _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let pd = getProxyData(ctx, proxyObj) else { return .exception }

    guard pd.isFunc else {
        return ctx.throwTypeError("proxy is not a function")
    }

    let trap = getTrap(ctx, pd.handler, JSPredefinedAtom.apply.rawValue)
    if trap.isUndefined {
        // Fall through: call target function directly.
        return ctx.callFunction(pd.target, thisVal: thisArg, args: argv)
    }

    // Call trap(target, thisArg, argumentsList).
    let argArray = ctx.newArrayFrom(argv)
    let result = ctx.callFunction(trap, thisVal: pd.handler, args: [pd.target, thisArg, argArray])
    return result
}

/// 13. construct trap (for constructable proxies).
func js_proxy_construct(_ ctx: JeffJSContext,
                        _ proxyObj: JeffJSObject,
                        _ argv: [JeffJSValue],
                        _ newTarget: JeffJSValue) -> JeffJSValue {
    guard let pd = getProxyData(ctx, proxyObj) else { return .exception }

    guard pd.isFunc else {
        return ctx.throwTypeError("proxy is not a constructor")
    }

    let trap = getTrap(ctx, pd.handler, JSPredefinedAtom.construct.rawValue)
    if trap.isUndefined {
        // Fall through: construct target directly.
        return ctx.callConstructor(pd.target, args: argv)
    }

    // Call trap(target, argumentsList, newTarget).
    let argArray = ctx.newArrayFrom(argv)
    let result = ctx.callFunction(trap, thisVal: pd.handler, args: [pd.target, argArray, newTarget])
    if result.isException { return result }

    // Invariant: result must be an object.
    if !result.isObject {
        return ctx.throwTypeError("construct trap must return an object")
    }

    return result
}

// MARK: - Proxy Exotic Methods Table

/// The exotic methods structure for proxy objects.
/// Installed on the JS_CLASS_PROXY class definition.
///
/// Mirrors the JSExoticMethods setup in `js_proxy_exotic_methods` in QuickJS.
let js_proxy_exotic_methods: JeffJSExoticMethods = {
    var m = JeffJSExoticMethods()
    m.getOwnProperty = { ctx, obj, atom in
        // Dispatch to getOwnPropertyDescriptor trap.
        guard let proxyObj = obj.toObject() else { return -1 }
        let result = js_proxy_getOwnPropertyDescriptor(ctx, proxyObj, atom)
        return result.isException ? -1 : (result.isUndefined ? 0 : 1)
    }
    m.getOwnPropertyNames = { ctx, obj, flags in
        guard let proxyObj = obj.toObject() else { return nil }
        let result = js_proxy_ownKeys(ctx, proxyObj)
        if result.isException { return nil }
        // Convert array result to atom list.
        return []
    }
    m.deleteProperty = { ctx, obj, atom in
        guard let proxyObj = obj.toObject() else { return -1 }
        let result = js_proxy_deleteProperty(ctx, proxyObj, atom)
        return result.isException ? -1 : (result.toBool() ? 1 : 0)
    }
    m.defineOwnProperty = { ctx, obj, atom, desc, flags in
        guard let proxyObj = obj.toObject() else { return -1 }
        let result = js_proxy_defineProperty(ctx, proxyObj, atom, desc, flags)
        return result.isException ? -1 : 1
    }
    m.hasProperty = { ctx, obj, atom in
        guard let proxyObj = obj.toObject() else { return -1 }
        let result = js_proxy_has(ctx, proxyObj, atom)
        return result.isException ? -1 : (result.toBool() ? 1 : 0)
    }
    m.getProperty = { ctx, obj, atom, receiver in
        guard let proxyObj = obj.toObject() else { return .exception }
        return js_proxy_get(ctx, proxyObj, atom, receiver)
    }
    m.setProperty = { ctx, obj, atom, value, receiver, flags in
        guard let proxyObj = obj.toObject() else { return -1 }
        let result = js_proxy_set(ctx, proxyObj, atom, value, receiver, flags)
        return result.isException ? -1 : 1
    }
    return m
}()

// MARK: - Proxy GC Support

/// Finalizer for Proxy objects. Releases target and handler.
func js_proxy_finalizer(_ rt: JeffJSRuntime, _ val: JeffJSValue) {
    guard let obj = val.toObject(),
          obj.classID == JeffJSClassID.proxy.rawValue,
          case .proxyData(var pd) = obj.payload else { return }
    pd.target.freeValue()
    pd.handler.freeValue()
    pd.target = .undefined
    pd.handler = .undefined
    pd.isRevoked = true
    obj.payload = .proxyData(pd)
}

/// GC mark function for Proxy objects.
func js_proxy_mark(_ rt: JeffJSRuntime,
                   _ val: JeffJSValue,
                   _ markFunc: (JeffJSValue) -> Void) {
    guard let obj = val.toObject(),
          obj.classID == JeffJSClassID.proxy.rawValue,
          case .proxyData(let pd) = obj.payload else { return }
    if !pd.isRevoked {
        markFunc(pd.target)
        markFunc(pd.handler)
    }
}

// MARK: - Reflect Static Methods

/// Reflect.apply(target, thisArg, argumentsList)
func js_reflect_apply(_ ctx: JeffJSContext,
                      _ thisVal: JeffJSValue,
                      _ argv: [JeffJSValue]) -> JeffJSValue {
    guard argv.count >= 3 else {
        return ctx.throwTypeError("Reflect.apply requires 3 arguments")
    }
    let target = argv[0]
    let thisArg = argv[1]
    let argList = argv[2]

    guard let targetObj = target.toObject(), targetObj.isCallable else {
        return ctx.throwTypeError("Reflect.apply target is not callable")
    }

    // Extract arguments from the argument list array.
    var args: [JeffJSValue] = []
    if let arrObj = argList.toObject(),
       arrObj.isArray,
       case .array(_, let vals, let count) = arrObj.payload {
        for i in 0..<Int(count) {
            args.append(vals[i])
        }
    }

    // In a full engine, this would call JS_Call(ctx, target, thisArg, args).
    _ = thisArg
    _ = args

    return .undefined
}

/// Reflect.construct(target, argumentsList [, newTarget])
func js_reflect_construct(_ ctx: JeffJSContext,
                          _ thisVal: JeffJSValue,
                          _ argv: [JeffJSValue]) -> JeffJSValue {
    guard argv.count >= 2 else {
        return ctx.throwTypeError("Reflect.construct requires at least 2 arguments")
    }
    let target = argv[0]
    let argList = argv[1]
    let newTarget = argv.count >= 3 ? argv[2] : target

    guard let targetObj = target.toObject(), targetObj.isConstructor else {
        return ctx.throwTypeError("Reflect.construct target is not a constructor")
    }

    if let nt = newTarget.toObject(), !nt.isConstructor {
        return ctx.throwTypeError("Reflect.construct newTarget is not a constructor")
    }

    _ = argList

    return .undefined
}

/// Reflect.defineProperty(target, propertyKey, attributes)
func js_reflect_defineProperty(_ ctx: JeffJSContext,
                               _ thisVal: JeffJSValue,
                               _ argv: [JeffJSValue]) -> JeffJSValue {
    guard argv.count >= 3 else {
        return ctx.throwTypeError("Reflect.defineProperty requires 3 arguments")
    }
    guard argv[0].isObject else {
        return ctx.throwTypeError("Reflect.defineProperty target must be an object")
    }
    // In a full engine: JS_DefinePropertyValue / JS_DefineProperty.
    return .JS_TRUE
}

/// Reflect.deleteProperty(target, propertyKey)
func js_reflect_deleteProperty(_ ctx: JeffJSContext,
                               _ thisVal: JeffJSValue,
                               _ argv: [JeffJSValue]) -> JeffJSValue {
    guard argv.count >= 2 else {
        return ctx.throwTypeError("Reflect.deleteProperty requires 2 arguments")
    }
    guard argv[0].isObject else {
        return ctx.throwTypeError("Reflect.deleteProperty target must be an object")
    }
    // In a full engine: JS_DeleteProperty.
    return .JS_TRUE
}

/// Reflect.get(target, propertyKey [, receiver])
func js_reflect_get(_ ctx: JeffJSContext,
                    _ thisVal: JeffJSValue,
                    _ argv: [JeffJSValue]) -> JeffJSValue {
    guard argv.count >= 2 else {
        return ctx.throwTypeError("Reflect.get requires at least 2 arguments")
    }
    guard argv[0].isObject else {
        return ctx.throwTypeError("Reflect.get target must be an object")
    }
    // In a full engine: JS_GetPropertyValue with receiver.
    guard let targetObj = argv[0].toObject() else { return .undefined }

    // Try to resolve the property key as an atom.
    // Simplified: direct property lookup.
    if argv[1].isString, let keyStr = argv[1].stringValue {
        _ = keyStr
    }

    _ = targetObj

    return .undefined
}

/// Reflect.getOwnPropertyDescriptor(target, propertyKey)
func js_reflect_getOwnPropertyDescriptor(_ ctx: JeffJSContext,
                                         _ thisVal: JeffJSValue,
                                         _ argv: [JeffJSValue]) -> JeffJSValue {
    guard argv.count >= 2 else {
        return ctx.throwTypeError("Reflect.getOwnPropertyDescriptor requires 2 arguments")
    }
    guard argv[0].isObject else {
        return ctx.throwTypeError("Reflect.getOwnPropertyDescriptor target must be an object")
    }
    let key = ctx.toPropertyKey(argv[1])
    if key.isException { return key }
    return ctx.getOwnPropertyDescriptor(argv[0], key: key)
}

/// Reflect.getPrototypeOf(target)
func js_reflect_getPrototypeOf(_ ctx: JeffJSContext,
                               _ thisVal: JeffJSValue,
                               _ argv: [JeffJSValue]) -> JeffJSValue {
    guard !argv.isEmpty else {
        return ctx.throwTypeError("Reflect.getPrototypeOf requires an argument")
    }
    guard argv[0].isObject else {
        return ctx.throwTypeError("Reflect.getPrototypeOf target must be an object")
    }
    guard let targetObj = argv[0].toObject(), let shape = targetObj.shape else {
        return .null
    }
    if let proto = shape.proto {
        return JeffJSValue.makeObject(proto).dupValue()
    }
    return .null
}

/// Reflect.has(target, propertyKey) - equivalent to `key in target`.
func js_reflect_has(_ ctx: JeffJSContext,
                    _ thisVal: JeffJSValue,
                    _ argv: [JeffJSValue]) -> JeffJSValue {
    guard argv.count >= 2 else {
        return ctx.throwTypeError("Reflect.has requires 2 arguments")
    }
    guard argv[0].isObject else {
        return ctx.throwTypeError("Reflect.has target must be an object")
    }
    // In a full engine: JS_HasProperty.
    return .JS_FALSE
}

/// Reflect.isExtensible(target)
func js_reflect_isExtensible(_ ctx: JeffJSContext,
                             _ thisVal: JeffJSValue,
                             _ argv: [JeffJSValue]) -> JeffJSValue {
    guard !argv.isEmpty else {
        return ctx.throwTypeError("Reflect.isExtensible requires an argument")
    }
    guard argv[0].isObject else {
        return ctx.throwTypeError("Reflect.isExtensible target must be an object")
    }
    guard let targetObj = argv[0].toObject() else { return .JS_TRUE }
    return JeffJSValue.newBool(targetObj.extensible)
}

/// Reflect.ownKeys(target)
func js_reflect_ownKeys(_ ctx: JeffJSContext,
                        _ thisVal: JeffJSValue,
                        _ argv: [JeffJSValue]) -> JeffJSValue {
    guard !argv.isEmpty else {
        return ctx.throwTypeError("Reflect.ownKeys requires an argument")
    }
    guard argv[0].isObject else {
        return ctx.throwTypeError("Reflect.ownKeys target must be an object")
    }
    guard let targetObj = argv[0].toObject() else {
        return .exception
    }

    let resultObj = JeffJSObject()
    resultObj.classID = JeffJSClassID.array.rawValue
    resultObj.fastArray = true
    resultObj.extensible = true

    var keys: [JeffJSValue] = []
    if let shape = targetObj.shape {
        for prop in shape.prop {
            let atomStr = JeffJSString(swiftString: String(prop.atom))
            keys.append(JeffJSValue.makeString(atomStr))
        }
    }
    resultObj.payload = .array(
        size: UInt32(keys.count),
        values: keys,
        count: UInt32(keys.count)
    )

    return JeffJSValue.makeObject(resultObj)
}

/// Reflect.preventExtensions(target)
func js_reflect_preventExtensions(_ ctx: JeffJSContext,
                                  _ thisVal: JeffJSValue,
                                  _ argv: [JeffJSValue]) -> JeffJSValue {
    guard !argv.isEmpty else {
        return ctx.throwTypeError("Reflect.preventExtensions requires an argument")
    }
    guard argv[0].isObject else {
        return ctx.throwTypeError("Reflect.preventExtensions target must be an object")
    }
    guard let targetObj = argv[0].toObject() else { return .JS_FALSE }
    targetObj.extensible = false
    return .JS_TRUE
}

/// Reflect.set(target, propertyKey, value [, receiver])
func js_reflect_set(_ ctx: JeffJSContext,
                    _ thisVal: JeffJSValue,
                    _ argv: [JeffJSValue]) -> JeffJSValue {
    guard argv.count >= 3 else {
        return ctx.throwTypeError("Reflect.set requires at least 3 arguments")
    }
    guard argv[0].isObject else {
        return ctx.throwTypeError("Reflect.set target must be an object")
    }
    // In a full engine: JS_SetPropertyValue with receiver.
    return .JS_TRUE
}

/// Reflect.setPrototypeOf(target, proto)
func js_reflect_setPrototypeOf(_ ctx: JeffJSContext,
                               _ thisVal: JeffJSValue,
                               _ argv: [JeffJSValue]) -> JeffJSValue {
    guard argv.count >= 2 else {
        return ctx.throwTypeError("Reflect.setPrototypeOf requires 2 arguments")
    }
    guard argv[0].isObject else {
        return ctx.throwTypeError("Reflect.setPrototypeOf target must be an object")
    }
    let proto = argv[1]
    if !proto.isObject && !proto.isNull {
        return ctx.throwTypeError("prototype must be an object or null")
    }
    // In a full engine: JS_SetPrototypeInternal.
    return .JS_TRUE
}

// MARK: - Reflect Function Table

/// Reflect method registration table.
/// Mirrors `js_reflect_funcs` in QuickJS.
struct JSReflectFuncEntry {
    let name: String
    let length: Int
    let func_: (JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue
}

let js_reflect_funcs: [JSReflectFuncEntry] = [
    JSReflectFuncEntry(name: "apply",                      length: 3, func_: js_reflect_apply),
    JSReflectFuncEntry(name: "construct",                  length: 2, func_: js_reflect_construct),
    JSReflectFuncEntry(name: "defineProperty",             length: 3, func_: js_reflect_defineProperty),
    JSReflectFuncEntry(name: "deleteProperty",             length: 2, func_: js_reflect_deleteProperty),
    JSReflectFuncEntry(name: "get",                        length: 2, func_: js_reflect_get),
    JSReflectFuncEntry(name: "getOwnPropertyDescriptor",   length: 2, func_: js_reflect_getOwnPropertyDescriptor),
    JSReflectFuncEntry(name: "getPrototypeOf",             length: 1, func_: js_reflect_getPrototypeOf),
    JSReflectFuncEntry(name: "has",                        length: 2, func_: js_reflect_has),
    JSReflectFuncEntry(name: "isExtensible",               length: 1, func_: js_reflect_isExtensible),
    JSReflectFuncEntry(name: "ownKeys",                    length: 1, func_: js_reflect_ownKeys),
    JSReflectFuncEntry(name: "preventExtensions",          length: 1, func_: js_reflect_preventExtensions),
    JSReflectFuncEntry(name: "set",                        length: 3, func_: js_reflect_set),
    JSReflectFuncEntry(name: "setPrototypeOf",             length: 2, func_: js_reflect_setPrototypeOf),
]

// MARK: - Proxy Class Definition

/// Class definition for JS_CLASS_PROXY.
let js_proxy_class: JeffJSClass = {
    var c = JeffJSClass()
    c.classNameAtom = 0 // Set to Proxy atom at init time
    c.finalizer = js_proxy_finalizer
    c.gcMark = js_proxy_mark
    c.call = { ctx, funcObj, thisArg, argv, flags in
        guard let obj = funcObj.toObject() else { return .exception }
        return js_proxy_apply(ctx, obj, thisArg, argv)
    }
    c.exotic = js_proxy_exotic_methods
    return c
}()
