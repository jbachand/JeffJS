// JeffJSBuiltinFunction.swift
// JeffJS — 1:1 Swift port of QuickJS JavaScript engine
//
// Port of the Function built-in from QuickJS (js_function_proto_*, js_function_constructor).
// Covers Function.prototype, Function constructor, call, apply, bind, toString,
// Symbol.hasInstance, and debug info getters (fileName, lineNumber, columnNumber).
//
// QuickJS source reference: quickjs.c — js_function_proto, js_function_constructor,
// js_function_apply, js_function_bind, js_function_toString, etc.
// Copyright 2026 Jeff Bachand. All rights reserved.

import Foundation

// MARK: - JeffJSBuiltinFunction

/// Implements the Function built-in for JeffJS.
/// Mirrors QuickJS js_function_proto_* functions and the Function constructor.
struct JeffJSBuiltinFunction {

    // MARK: - Intrinsic Registration

    /// Registers Function.prototype and Function constructor on the context.
    /// Mirrors `JS_AddIntrinsicFunction` / the function-init portion of
    /// `JS_AddIntrinsicBaseObjects` in QuickJS.
    ///
    /// Sets up:
    /// - Function.prototype (callable, returns undefined)
    /// - Function constructor
    /// - Function.prototype.call / apply / bind / toString
    /// - Function.prototype[@@hasInstance]
    /// - fileName / lineNumber / columnNumber getters on Function.prototype
    static func addIntrinsic(ctx: JeffJSContext) {
        // --- Use the EXISTING Function.prototype from the context ---
        // addIntrinsicBaseObjects() already created Function.prototype and stored
        // it in ctx.functionProto / classProto[].  We must install our real
        // implementations on THAT object; otherwise the stub closures registered
        // by addFunctionProtoMethods() remain and every call/apply/bind returns
        // undefined.
        guard let funcProtoObj = ctx.functionProto.toObject() else {
            return  // nothing to do if base objects were not initialised yet
        }

        // --- Overwrite the stub methods with real implementations ---
        // The stubs set by addFunctionProtoMethods use setPropertyStr which
        // stores plain .value properties keyed by atom.  We overwrite them
        // with proper C-function objects using the same atoms.

        // Function.prototype.call
        let callMethod = ctx.newCFunction({ ctxArg, thisVal, args in
            return call_(ctx: ctxArg, this: thisVal, args: args)
        }, name: "call", length: 1)
        _ = ctx.setPropertyStr(obj: ctx.functionProto, name: "call", value: callMethod)

        // Function.prototype.apply
        let applyMethod = ctx.newCFunction({ ctxArg, thisVal, args in
            return apply(ctx: ctxArg, this: thisVal, args: args, magic: 0)
        }, name: "apply", length: 2)
        _ = ctx.setPropertyStr(obj: ctx.functionProto, name: "apply", value: applyMethod)

        // Function.prototype.bind
        let bindMethod = ctx.newCFunction({ ctxArg, thisVal, args in
            return bind(ctx: ctxArg, this: thisVal, args: args)
        }, name: "bind", length: 1)
        _ = ctx.setPropertyStr(obj: ctx.functionProto, name: "bind", value: bindMethod)

        // Function.prototype.toString
        let toStringMethod = ctx.newCFunction({ ctxArg, thisVal, args in
            return toString(ctx: ctxArg, this: thisVal, args: args)
        }, name: "toString", length: 0)
        _ = ctx.setPropertyStr(obj: ctx.functionProto, name: "toString", value: toStringMethod)
    }

    // MARK: - Function.prototype (callable, returns undefined)

    /// Function.prototype itself is a callable function that returns undefined.
    /// Mirrors `js_function_proto` in QuickJS.
    static func functionProto(ctx: JeffJSContext, this: JeffJSValue,
                              args: [JeffJSValue]) -> JeffJSValue {
        return .undefined
    }

    // MARK: - Function Constructor

    /// Function constructor — builds a function from string source.
    /// `new Function(p1, p2, ..., body)` constructs a function from argument strings.
    ///
    /// magic: 0=normal, 1=generator, 2=async, 3=async generator
    ///
    /// Mirrors `js_function_constructor` in QuickJS.
    /// Builds source string `(function anonymous(args) { body })` and evaluates it.
    static func functionConstructor(ctx: JeffJSContext, newTarget: JeffJSValue,
                                     this: JeffJSValue, args: [JeffJSValue],
                                     magic: Int) -> JeffJSValue {
        let argc = args.count

        // Determine the function kind prefix from magic
        let funcPrefix: String
        let funcSuffix: String
        switch magic {
        case 1: // generator
            funcPrefix = "function*"
            funcSuffix = ""
        case 2: // async
            funcPrefix = "async function"
            funcSuffix = ""
        case 3: // async generator
            funcPrefix = "async function*"
            funcSuffix = ""
        default: // normal
            funcPrefix = "function"
            funcSuffix = ""
        }

        // Build the parameter list and body strings
        var paramStr = ""
        var bodyStr = ""

        if argc == 0 {
            // No arguments: `(function anonymous() { })`
            paramStr = ""
            bodyStr = ""
        } else if argc == 1 {
            // One argument is the body
            bodyStr = jsValueToString(ctx: ctx, val: args[0])
        } else {
            // args[0..argc-2] are parameter names, args[argc-1] is the body
            var params: [String] = []
            for i in 0..<(argc - 1) {
                params.append(jsValueToString(ctx: ctx, val: args[i]))
            }
            paramStr = params.joined(separator: ",")
            bodyStr = jsValueToString(ctx: ctx, val: args[argc - 1])
        }

        // Construct the full source:
        // (function anonymous(paramStr) { bodyStr\n})
        // The newline before the closing brace ensures a trailing // comment in
        // body doesn't eat the closing brace.
        let source = "(\(funcPrefix) anonymous(\(paramStr)) {\n\(bodyStr)\n})\(funcSuffix)"

        // Evaluate the constructed source in the global scope.
        // QuickJS calls JS_EvalInternal here with the realm of the new.target.
        let evalFlags = JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_BACKTRACE_BARRIER
        let result = jsEvalInternal(ctx: ctx, input: source,
                                    filename: "<Function>",
                                    evalFlags: evalFlags)

        if result.isException {
            return .makeException()
        }

        return result
    }

    // MARK: - Function.prototype.call

    /// `Function.prototype.call(thisArg, ...args)`
    /// Mirrors `js_function_call` in QuickJS.
    static func call_(ctx: JeffJSContext, this: JeffJSValue,
                      args: [JeffJSValue]) -> JeffJSValue {
        // `this` must be callable (it is the function being .call'd)
        guard let funcObj = getObject(this), funcObj.isCallable else {
            return ctx.throwTypeError("not a function")
        }

        // First arg is thisArg, rest are call arguments
        let thisArg: JeffJSValue = args.isEmpty ? .undefined : args[0]
        let callArgs: [JeffJSValue] = args.count > 1 ? Array(args[1...]) : []

        // Delegate to the engine's main callFunction so bytecode, C-functions,
        // and bound functions all work correctly.
        return ctx.callFunction(this, thisVal: thisArg, args: callArgs)
    }

    // MARK: - Function.prototype.apply

    /// `Function.prototype.apply(thisArg, argsArray)` and
    /// `Reflect.apply(target, thisArg, argumentsList)` (magic=1)
    ///
    /// magic: 0 = Function.prototype.apply, 1 = Reflect.apply
    ///
    /// Mirrors `js_function_apply` in QuickJS.
    static func apply(ctx: JeffJSContext, this: JeffJSValue,
                      args: [JeffJSValue], magic: Int) -> JeffJSValue {
        let funcVal: JeffJSValue
        let thisArg: JeffJSValue
        let argsArrayVal: JeffJSValue

        if magic == 1 {
            // Reflect.apply(target, thisArg, argumentsList)
            guard args.count >= 1 else {
                return ctx.throwTypeError("Reflect.apply requires a target argument")
            }
            funcVal = args[0]
            thisArg = args.count >= 2 ? args[1] : .undefined
            argsArrayVal = args.count >= 3 ? args[2] : .undefined
        } else {
            // Function.prototype.apply(thisArg, argsArray)
            funcVal = this
            thisArg = args.isEmpty ? .undefined : args[0]
            argsArrayVal = args.count >= 2 ? args[1] : .undefined
        }

        // funcVal must be callable
        guard let funcObj = getObject(funcVal), funcObj.isCallable else {
            return ctx.throwTypeError("not a function")
        }

        // Handle null/undefined argsArray — call with zero args
        if argsArrayVal.isUndefined || argsArrayVal.isNull {
            return ctx.callFunction(funcVal, thisVal: thisArg, args: [])
        }

        // Build argument list from argsArray
        guard let argList = buildArgList(ctx: ctx, args: argsArrayVal) else {
            return .makeException()
        }

        // Delegate to the engine's main callFunction so bytecode, C-functions,
        // and bound functions all work correctly.
        return ctx.callFunction(funcVal, thisVal: thisArg, args: argList)
    }

    // MARK: - Function.prototype.bind

    /// `Function.prototype.bind(thisArg, ...args)`
    /// Creates a bound function that, when called, prepends the bound arguments
    /// and uses the bound `this`.
    ///
    /// The bound function is created as a C-function closure
    /// (JS_CLASS_C_FUNCTION) so the interpreter's main `callFunction` path
    /// dispatches it correctly through the `.cFunc` case without needing a
    /// separate `.boundFunction` handler in the interpreter.
    ///
    /// Mirrors `js_function_bind` in QuickJS.
    static func bind(ctx: JeffJSContext, this: JeffJSValue,
                     args: [JeffJSValue]) -> JeffJSValue {
        // `this` must be callable
        guard let targetObj = getObject(this), targetObj.isCallable else {
            return ctx.throwTypeError("not a function")
        }

        let thisArg: JeffJSValue = args.isEmpty ? .undefined : args[0]
        let boundArgs: [JeffJSValue] = args.count > 1 ? Array(args[1...]) : []

        // Capture the target function and bound state in a closure.
        // When the bound function is called, prepend boundArgs to the
        // call-site args and invoke the original target with the bound this.
        let capturedFunc = this
        let capturedThis = thisArg
        let capturedBoundArgs = boundArgs

        let boundClosure: (JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue = { callCtx, _, callArgs in
            let fullArgs = capturedBoundArgs + callArgs
            return callCtx.callFunction(capturedFunc, thisVal: capturedThis, args: fullArgs)
        }

        // Compute the new length: max(0, targetLength - boundArgs.count)
        var targetLength: Int32 = 0
        let targetLengthVal = targetObj.getOwnPropertyValue(
            atom: JeffJSAtomID.JS_ATOM_length.rawValue)
        if targetLengthVal.isInt {
            targetLength = targetLengthVal.toInt32()
        } else if targetLengthVal.isFloat64 {
            let d = targetLengthVal.toFloat64()
            if d.isFinite { targetLength = Int32(d) }
        }
        let newLength = max(Int32(0), targetLength - Int32(boundArgs.count))

        // Build the name: "bound " + targetName
        var targetName = "anonymous"
        let targetNameVal = targetObj.getOwnPropertyValue(
            atom: JeffJSAtomID.JS_ATOM_name.rawValue)
        if targetNameVal.isString, let nameStr = targetNameVal.stringValue {
            targetName = nameStr.toSwiftString()
        }
        let boundName = "bound \(targetName)"

        // Create the bound function via newCFunction so the interpreter's
        // callFunction dispatches it through the .cFunc path.
        let boundVal = ctx.newCFunction(boundClosure, name: boundName, length: Int(newLength))

        // Per ES spec, bound functions inherit the target's prototype for
        // instanceof checks. Copy the prototype property from the target.
        let targetProto = ctx.getProperty(obj: this,
                                          atom: JeffJSAtomID.JS_ATOM_prototype.rawValue)
        if targetProto.isObject {
            ctx.setPropertyStr(obj: boundVal, name: "prototype", value: targetProto)
        }

        return boundVal
    }

    // MARK: - Function.prototype.toString

    /// `Function.prototype.toString()`
    /// Returns the source code of the function, or a "[native code]" placeholder.
    ///
    /// Mirrors `js_function_toString` in QuickJS.
    static func toString(ctx: JeffJSContext, this: JeffJSValue,
                         args: [JeffJSValue]) -> JeffJSValue {
        guard let obj = getObject(this) else {
            return ctx.throwTypeError("not a function")
        }

        let classID = obj.classID

        switch obj.payload {
        case .bytecodeFunc(let functionBytecode, _, _):
            // Bytecode function — try to return the original source.
            // If debug info is available, reconstruct from bytecode source.
            // Otherwise, use the synthetic format.
            if let bc = functionBytecode, bc.hasDebug {
                // QuickJS stores the source in debug info; reconstruct a basic form
                let name = getFunctionName(obj: obj)
                let isGen = bc.isGenerator
                let isAsync = bc.isAsyncFunc
                var prefix = ""
                if isAsync { prefix += "async " }
                prefix += "function"
                if isGen { prefix += "*" }
                let result = "\(prefix) \(name)() { [bytecode] }"
                return JeffJSValue.makeString(JeffJSString(swiftString: result))
            }

            // No debug info — use the standard format
            let name = getFunctionName(obj: obj)
            let result = "function \(name)() { [native code] }"
            return JeffJSValue.makeString(JeffJSString(swiftString: result))

        case .cFunc(_, _, _, _, _):
            // C function — return "function name() { [native code] }"
            let name = getFunctionName(obj: obj)
            let result = "function \(name)() { [native code] }"
            return JeffJSValue.makeString(JeffJSString(swiftString: result))

        case .boundFunction(_):
            // Bound function — return "function () { [native code] }"
            let name = getFunctionName(obj: obj)
            let result = "function \(name)() { [native code] }"
            return JeffJSValue.makeString(JeffJSString(swiftString: result))

        default:
            // Not a recognized function type. If it has a call handler
            // (proxy or class-based callable), still produce output.
            if classID == JeffJSClassID.proxy.rawValue {
                // Proxy wrapping a function
                let result = "function () { [native code] }"
                return JeffJSValue.makeString(JeffJSString(swiftString: result))
            }
            return ctx.throwTypeError("Function.prototype.toString requires that 'this' be a Function")
        }
    }

    // MARK: - Function.prototype[@@hasInstance]

    /// `Function.prototype[Symbol.hasInstance](V)`
    /// Implements the `instanceof` operator via OrdinaryHasInstance.
    ///
    /// Mirrors `js_function_hasInstance` in QuickJS.
    static func hasInstance(ctx: JeffJSContext, this: JeffJSValue,
                            args: [JeffJSValue]) -> JeffJSValue {
        let val = args.isEmpty ? JeffJSValue.undefined : args[0]
        let result = ordinaryIsInstanceOf(ctx: ctx, val: val, obj: this)
        return .newBool(result)
    }

    // MARK: - Debug Info Getters

    /// Getter for `Function.prototype.fileName`.
    /// Returns the source file name from the bytecode debug info.
    ///
    /// Mirrors `js_function_proto_fileName` in QuickJS.
    static func fileName(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
        guard let obj = getObject(this) else {
            return .undefined
        }

        if case .bytecodeFunc(let bc, _, _) = obj.payload {
            if let bc = bc, let fn = bc.fileName {
                return JeffJSValue.makeString(fn)
            }
        }
        return .null
    }

    /// Getter for `Function.prototype.lineNumber`.
    /// Returns the starting line number from the bytecode debug info.
    ///
    /// Mirrors `js_function_proto_lineNumber` in QuickJS.
    static func lineNumber(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
        guard let obj = getObject(this) else {
            return .undefined
        }

        if case .bytecodeFunc(let bc, _, _) = obj.payload {
            if let bc = bc {
                return .newInt32(Int32(bc.lineNum))
            }
        }
        return .null
    }

    /// Getter for `Function.prototype.columnNumber`.
    /// Returns the starting column number from the bytecode debug info.
    ///
    /// Mirrors `js_function_proto_columnNumber` in QuickJS.
    static func columnNumber(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
        guard let obj = getObject(this) else {
            return .undefined
        }

        if case .bytecodeFunc(let bc, _, _) = obj.payload {
            if let bc = bc {
                return .newInt32(Int32(bc.colNum))
            }
        }
        return .null
    }

    // MARK: - Internal Helpers

    /// Builds an argument list from an array-like object (for apply / Reflect.apply).
    /// Returns nil on error (exception already thrown on context).
    ///
    /// Mirrors `build_arg_list` in QuickJS.
    static func buildArgList(ctx: JeffJSContext, args: JeffJSValue) -> [JeffJSValue]? {
        guard let argsObj = getObject(args) else {
            _ = ctx.throwTypeError("CreateListFromArrayLike called on non-object")
            return nil
        }

        // Get the length property
        let lengthVal = argsObj.getOwnPropertyValue(
            atom: JeffJSAtomID.JS_ATOM_length.rawValue)
        let length: Int
        if lengthVal.isInt {
            length = Int(lengthVal.toInt32())
        } else if lengthVal.isFloat64 {
            let d = lengthVal.toFloat64()
            length = (d.isFinite && abs(d) < Double(Int.max / 2)) ? Int(d) : 0
        } else {
            length = 0
        }

        guard length >= 0 else {
            _ = ctx.throwTypeError("invalid array length")
            return nil
        }

        // Fast path for arrays
        if argsObj.isArray, case .array(_, let values, let count) = argsObj.payload {
            let actualCount = min(length, Int(count))
            return Array(values.prefix(actualCount))
        }

        // General path: read indexed properties
        var result: [JeffJSValue] = []
        result.reserveCapacity(length)
        for i in 0..<length {
            let indexAtom = UInt32(i) | JS_ATOM_TAG_INT
            let val = argsObj.getOwnPropertyValue(atom: indexAtom)
            result.append(val)
        }

        return result
    }

    /// Implements OrdinaryHasInstance (ES2023 7.3.22).
    /// Used by `instanceof` and `Symbol.hasInstance`.
    ///
    /// Mirrors `JS_OrdinaryIsInstanceOf` in QuickJS.
    static func ordinaryIsInstanceOf(ctx: JeffJSContext, val: JeffJSValue,
                                      obj: JeffJSValue) -> Bool {
        // If obj is not callable, return false
        guard let funcObj = getObject(obj), funcObj.isCallable else {
            return false
        }

        // Handle bound functions: unwrap to the target function
        var targetObj = funcObj
        while case .boundFunction(let bd) = targetObj.payload {
            guard let nextObj = getObject(bd.funcObj) else { break }
            targetObj = nextObj
        }

        // Get the prototype property of the target function
        let protoVal = targetObj.getOwnPropertyValue(
            atom: JeffJSAtomID.JS_ATOM_prototype.rawValue)
        guard let protoObj = getObject(protoVal) else {
            // TypeError: prototype is not an object
            return false
        }

        // val must be an object
        guard var valObj = getObject(val) else {
            return false
        }

        // Walk the prototype chain of val (obj.proto is the single source of truth)
        let maxProtoChain = 1000
        for _ in 0..<maxProtoChain {
            guard let parentProto = valObj.proto else {
                return false
            }
            if parentProto === protoObj {
                return true
            }
            valObj = parentProto
        }

        return false
    }

    // MARK: - Private Helpers

    /// Extract the JeffJSObject from a JeffJSValue with tag == .object.
    private static func getObject(_ val: JeffJSValue) -> JeffJSObject? {
        return val.toObject()
    }

    /// Convert a JeffJSValue to its string representation.
    /// Simplified version — handles string, int, float64, and falls back to "".
    private static func jsValueToString(ctx: JeffJSContext, val: JeffJSValue) -> String {
        if val.isString, let str = val.stringValue { return str.toSwiftString() }
        if val.isInt { return String(val.toInt32()) }
        if val.isFloat64 { return String(val.toFloat64()) }
        if val.isUndefined { return "undefined" }
        if val.isNull { return "null" }
        if val.isBool { return val.toBool() ? "true" : "false" }
        return ""
    }

    /// Get the function name from a function object.
    /// Reads the "name" property or returns "anonymous".
    private static func getFunctionName(obj: JeffJSObject) -> String {
        let nameVal = obj.getOwnPropertyValue(atom: JeffJSAtomID.JS_ATOM_name.rawValue)
        if nameVal.isString, let nameStr = nameVal.stringValue {
            let s = nameStr.toSwiftString()
            if !s.isEmpty { return s }
        }
        return "anonymous"
    }

    /// Evaluate a JS source string in the context.
    /// Placeholder that delegates to the context's eval infrastructure.
    private static func jsEvalInternal(ctx: JeffJSContext, input: String,
                                       filename: String, evalFlags: Int) -> JeffJSValue {
        // In a full implementation this calls into the parser/compiler/interpreter
        // pipeline. For now, we construct the function object directly if possible,
        // or return an exception if parsing would be needed.
        //
        // QuickJS: JS_EvalInternal(ctx, thisObj, source, len, filename, flags)
        //
        // The real implementation parses `input`, compiles to bytecode, and executes.
        // This will be wired up once the parser/compiler pipeline is complete.
        _ = ctx.throwTypeError("Function constructor eval not yet implemented")
        return .makeException()
    }

    /// Call a function value with the given this and arguments.
    /// Delegates to the engine's call machinery.
    private static func jsCallInternal(ctx: JeffJSContext, func_: JeffJSValue,
                                       thisArg: JeffJSValue, args: [JeffJSValue],
                                       flags: Int) -> JeffJSValue {
        guard let funcObj = getObject(func_) else {
            return ctx.throwTypeError("not a function")
        }

        switch funcObj.payload {
        case .cFunc(let realm, let cFunction, _, _, let magic):
            let callCtx = realm ?? ctx
            switch cFunction {
            case .generic(let fn):
                return fn(callCtx, thisArg, args)
            case .genericMagic(let fn):
                return fn(callCtx, thisArg, args, Int(magic))
            case .constructor(let fn):
                if flags & JS_CALL_FLAG_CONSTRUCTOR != 0 {
                    return fn(callCtx, thisArg, args)
                }
                return fn(callCtx, thisArg, args)
            case .constructorOrFunc(let fn):
                let isNew = (flags & JS_CALL_FLAG_CONSTRUCTOR) != 0
                return fn(callCtx, thisArg, args, isNew)
            default:
                return ctx.throwTypeError("unsupported C function type in call")
            }

        case .boundFunction(let bd):
            // Unwrap the bound function: use stored thisVal and prepend bound args
            let effectiveThis: JeffJSValue
            if flags & JS_CALL_FLAG_CONSTRUCTOR != 0 {
                // For constructors, `this` from `new` takes precedence
                effectiveThis = thisArg
            } else {
                effectiveThis = bd.thisVal
            }
            let fullArgs = bd.argv + args
            return jsCallInternal(ctx: ctx, func_: bd.funcObj, thisArg: effectiveThis,
                                  args: fullArgs, flags: flags)

        case .bytecodeFunc(_, _, _):
            // Delegate bytecode function calls to the main callFunction path
            // which handles generators, async, and regular bytecode functions.
            return ctx.callFunction(func_, thisVal: thisArg, args: args)

        default:
            return ctx.throwTypeError("object is not a function")
        }
    }

    /// Add a method to a prototype object.
    private static func addPrototypeMethod(
        ctx: JeffJSContext, proto: JeffJSObject, name: UInt32,
        func fn: @escaping (JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue,
        length: Int
    ) {
        let methodObj = JeffJSObject()
        methodObj.classID = JeffJSClassID.cFunction.rawValue
        methodObj.extensible = true
        methodObj.payload = .cFunc(
            realm: ctx,
            cFunction: .generic(fn),
            length: UInt8(length),
            cproto: UInt8(JS_CFUNC_GENERIC),
            magic: 0
        )

        // Set name and length on the method
        jeffJS_addProperty(ctx: ctx, obj: methodObj,
                           atom: JeffJSAtomID.JS_ATOM_length.rawValue,
                           flags: [.configurable])
        methodObj.setOwnPropertyValue(atom: JeffJSAtomID.JS_ATOM_length.rawValue,
                                      value: .newInt32(Int32(length)))

        // Add the method to the prototype
        jeffJS_addProperty(ctx: ctx, obj: proto, atom: name,
                           flags: [.writable, .configurable])
        proto.setOwnPropertyValue(atom: name, value: JeffJSValue.makeObject(methodObj))
    }

    /// Add a method with magic parameter to a prototype object.
    private static func addPrototypeMethodMagic(
        ctx: JeffJSContext, proto: JeffJSObject, name: UInt32,
        func fn: @escaping (JeffJSContext, JeffJSValue, [JeffJSValue], Int) -> JeffJSValue,
        length: Int, magic: Int
    ) {
        let methodObj = JeffJSObject()
        methodObj.classID = JeffJSClassID.cFunction.rawValue
        methodObj.extensible = true
        methodObj.payload = .cFunc(
            realm: ctx,
            cFunction: .genericMagic(fn),
            length: UInt8(length),
            cproto: UInt8(JS_CFUNC_GENERIC_MAGIC),
            magic: Int16(magic)
        )

        jeffJS_addProperty(ctx: ctx, obj: methodObj,
                           atom: JeffJSAtomID.JS_ATOM_length.rawValue,
                           flags: [.configurable])
        methodObj.setOwnPropertyValue(atom: JeffJSAtomID.JS_ATOM_length.rawValue,
                                      value: .newInt32(Int32(length)))

        jeffJS_addProperty(ctx: ctx, obj: proto, atom: name,
                           flags: [.writable, .configurable])
        proto.setOwnPropertyValue(atom: name, value: JeffJSValue.makeObject(methodObj))
    }

    /// Add a getter property to a prototype object.
    private static func addPrototypeGetter(
        ctx: JeffJSContext, proto: JeffJSObject, name: UInt32,
        getter fn: @escaping (JeffJSContext, JeffJSValue) -> JeffJSValue
    ) {
        let getterObj = JeffJSObject()
        getterObj.classID = JeffJSClassID.cFunction.rawValue
        getterObj.extensible = true
        getterObj.payload = .cFunc(
            realm: ctx,
            cFunction: .getter(fn),
            length: 0,
            cproto: UInt8(JS_CFUNC_GETTER),
            magic: 0
        )

        jeffJS_addProperty(ctx: ctx, obj: proto, atom: name,
                           flags: [.configurable, .getset])
        // For a getter-only property, we store it as a getset with no setter
        let propIdx = proto.prop.count - 1
        if propIdx >= 0 {
            proto.prop[propIdx] = .getset(getter: getterObj, setter: nil)
        }
    }

    /// Helper for creating new JeffJSValue with .newBool.
    private static func newBool(_ val: Bool) -> JeffJSValue {
        return JeffJSValue.newBool(val)
    }
}
