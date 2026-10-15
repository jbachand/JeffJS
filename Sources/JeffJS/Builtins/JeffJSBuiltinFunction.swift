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
nonisolated struct JeffJSBuiltinFunction {

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
        ctx.funcProtoCallObj = callMethod.toObject()

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

        installFunctionPrototypeShape(ctx: ctx)
    }

    /// The rest of Function.prototype's own properties (ES §20.2.3; what
    /// JavaScriptCore has): `length` 0, `name` "", `constructor` = Function,
    /// `[Symbol.hasInstance]` (non-writable, non-enumerable, non-configurable), and
    /// JSC's `arguments` / `caller` accessors (here `null`, never a throw: sloppy
    /// code reads `f.caller`). The phase-1 stub put the hasInstance function under a
    /// *string* key "@@hasInstance", and `(function(){}).constructor` was Object.
    /// akamai navigation fix, 2026-09-29 (bot defence reads these shapes).
    static func installFunctionPrototypeShape(ctx: JeffJSContext) {
        let fp = ctx.functionProto
        guard fp.isObject else { return }
        let junk = ctx.rt.findAtom("@@hasInstance")
        _ = ctx.deleteProperty(obj: fp, atom: junk)
        ctx.rt.freeAtom(junk)

        // JavaScriptCore's own-key order (pages fingerprint
        // `Object.getOwnPropertyNames(Function.prototype)`): length, name, toString, apply,
        // call, bind, arguments, caller, constructor (google on JeffJS, 2026-10-06; was
        // call, apply, bind, toString, length, name, constructor, arguments, caller).
        var methods: [(JSAtom, JeffJSValue)] = []
        for n in ["toString", "apply", "call", "bind"] {
            let atom = ctx.rt.findAtom(n)
            let v = ctx.getPropertyStr(obj: fp, name: n)
            if v.isObject { _ = ctx.deleteProperty(obj: fp, atom: atom); methods.append((atom, v)) }
            else { v.freeValue(); ctx.rt.freeAtom(atom) }
        }
        ctx.definePropertyValue(obj: fp, atom: JeffJSAtomID.JS_ATOM_length.rawValue,
                                value: JeffJSValue.newInt32(0), flags: JS_PROP_CONFIGURABLE)
        let emptyName = ctx.newStringValue("")
        ctx.definePropertyValue(obj: fp, atom: JeffJSAtomID.JS_ATOM_name.rawValue, value: emptyName, flags: JS_PROP_CONFIGURABLE)
        emptyName.freeValue()
        for (atom, v) in methods {
            ctx.definePropertyValue(obj: fp, atom: atom, value: v, flags: JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE)
            v.freeValue()
            ctx.rt.freeAtom(atom)
        }

        let hasInstanceFn = ctx.newCFunction({ c, thisVal, args in
            hasInstance(ctx: c, this: thisVal, args: args)
        }, name: "[Symbol.hasInstance]", length: 1)
        ctx.definePropertyValue(obj: fp, atom: JSPredefinedAtom.Symbol_hasInstance.rawValue, value: hasInstanceFn, flags: 0)
        hasInstanceFn.freeValue()

        for name in ["arguments", "caller"] {
            let isCaller = name == "caller"
            let getter = ctx.newCFunction({ c, thisVal, _ in
                isCaller ? callerGetter(ctx: c, this: thisVal) : argumentsGetter(ctx: c, this: thisVal)
            }, name: name, length: 0)
            // Assignment is ignored (JSC), but only for a function that may be asked.
            let setter = ctx.newCFunction({ c, thisVal, _ in
                sloppyOrdinaryFunction(thisVal) == nil ? c.throwTypeError(restrictedPropertyMessage) : .undefined
            }, name: name, length: 1)
            ctx.setPropertyGetSet(obj: fp, name: name, getter: getter, setter: setter)
        }

        let fnCtor = ctx.getPropertyStr(obj: ctx.globalObj, name: "Function")
        if fnCtor.isObject {
            let ctorAtom = ctx.rt.findAtom("constructor")
            ctx.definePropertyValue(obj: fp, atom: ctorAtom, value: fnCtor, flags: JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE)
            ctx.rt.freeAtom(ctorAtom)
        }
        fnCtor.freeValue()
    }

    // MARK: - Function.prototype.caller / .arguments (JSC's legacy accessors)

    /// JSC's TypeError text for `caller` / `arguments` of a function that has none.
    static let restrictedPropertyMessage = "'arguments', 'callee', and 'caller' cannot be accessed in this context."

    /// The function whose `caller` / `arguments` JavaScriptCore answers: a sloppy,
    /// ordinary function (not strict, arrow, method, accessor, class, generator,
    /// async, bound or native). Everything else throws — `Math.max.caller`,
    /// `(() => 1).caller`, `({ m(){} }).m.arguments` (ES §17 "Forbidden
    /// Extensions", JSC's `FunctionPrototype` accessors).
    static func sloppyOrdinaryFunction(_ v: JeffJSValue) -> JeffJSObject? {
        guard let o = v.toObject(), o.isConstructor else { return nil }
        var fb = o.fbFast
        if fb == nil, case .bytecodeFunc(let f, _, _) = o.payload { fb = f }
        guard let b = fb, !b.isStrictMode, !b.isArrow, !b.isGenerator, !b.isAsyncFunc,
              !b.isDerivedClassConstructor else { return nil }
        return o
    }

    /// The innermost active frame running `fo`, if it is on the stack.
    static func activeFrame(ctx: JeffJSContext, of fo: JeffJSObject) -> JeffJSStackFrame? {
        var f = ctx.currentFrame
        var guardCount = 0
        while let fr = f, guardCount < 100_000 {
            if let o = fr.curFunc.toObject(), o === fo { return fr }
            f = fr.prevFrame
            guardCount += 1
        }
        return nil
    }

    /// `f.caller`: the function that called the innermost activation of `f`
    /// when that caller is a sloppy function; null when `f` is not running or
    /// was called from global / eval code or from strict code (JSC).
    static func callerGetter(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
        guard let fo = sloppyOrdinaryFunction(this) else {
            return ctx.throwTypeError(restrictedPropertyMessage)
        }
        guard let fr = activeFrame(ctx: ctx, of: fo), let prev = fr.prevFrame,
              let co = prev.curFunc.toObject() else { return .null }
        var cfb = co.fbFast
        if cfb == nil, case .bytecodeFunc(let f, _, _) = co.payload { cfb = f }
        guard let b = cfb, !b.isStrictMode, !b.isTopLevelCode else { return .null }
        return prev.curFunc.dupValue()
    }

    /// `f.arguments`: a fresh Arguments object with the innermost activation's
    /// arguments while `f` runs, else null (JSC).
    static func argumentsGetter(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
        guard let fo = sloppyOrdinaryFunction(this) else {
            return ctx.throwTypeError(restrictedPropertyMessage)
        }
        guard let fr = activeFrame(ctx: ctx, of: fo) else { return .null }
        var values: [JeffJSValue] = []
        if let b = fr.buf {
            for i in 0 ..< fr.argCount { values.append(b[i]) }
        } else {
            values = Array(fr.argBuf.prefix(fr.argCount))
        }
        let argsObj = ctx.newObject()
        guard let o = argsObj.toObject() else { return argsObj }
        o.classID = JeffJSClassID.arguments.rawValue
        for (i, v) in values.enumerated() {
            _ = ctx.setPropertyUint32(obj: argsObj, index: UInt32(i), value: v.dupValue())
        }
        let wc = JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE
        _ = ctx.definePropertyValue(obj: argsObj, atom: JeffJSAtomID.JS_ATOM_length.rawValue,
                                    value: .newInt32(Int32(values.count)), flags: wc)
        _ = ctx.definePropertyValue(obj: argsObj, atom: JeffJSAtomID.JS_ATOM_callee.rawValue,
                                    value: this, flags: wc)
        if ctx.arrayProtoValues.isFunction {
            _ = ctx.definePropertyValue(obj: argsObj, atom: JeffJSAtomID.JS_ATOM_Symbol_iterator.rawValue,
                                        value: ctx.arrayProtoValues, flags: wc)
        }
        return argsObj
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
        // The newline after the parameter list matches QuickJS byte for byte,
        // so `toString()` of the result reads
        // `function anonymous(a\n) {\n<body>\n}` there and here.
        let source = "(\(funcPrefix) anonymous(\(paramStr)\n) {\n\(bodyStr)\n})\(funcSuffix)"

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
        guard let targetObj = getObject(this), targetObj.isCallable else {
            return ctx.throwTypeError("not a function")
        }
        let thisArg: JeffJSValue = (args.isEmpty ? .undefined : args[0]).dupValue()
        let boundArgs: [JeffJSValue] = args.count > 1 ? args[1...].map { $0.dupValue() } : []

        // A bytecode function's `name`/`length` are created on first access,
        // so force them out before reading the target's own properties —
        // otherwise every bound function was named "bound " with length 0.
        if targetObj.needsLazyNameLength { ctx.materializeFunctionNameLength(targetObj) }

        // length = max(0, target.length - bound argument count).
        // In Double: a target length of 1e20 / 2^53 / Infinity is legal
        // (`Int32(d)` trapped); ToIntegerOrInfinity, NaN → 0.
        var targetLength: Double = 0
        let targetLengthVal = targetObj.getOwnPropertyValue(
            atom: JeffJSAtomID.JS_ATOM_length.rawValue)
        if targetLengthVal.isInt {
            targetLength = Double(targetLengthVal.toInt32())
        } else if targetLengthVal.isFloat64 {
            let d = targetLengthVal.toFloat64()
            if !d.isNaN { targetLength = d.isInfinite ? d : d.rounded(.towardZero) }
        } else if let fb = targetObj.fbFast {
            targetLength = Double(fb.argCount)
        }
        let newLengthD = max(0, targetLength - Double(boundArgs.count))
        let newLengthVal: JeffJSValue = newLengthD <= Double(Int32.max)
            ? .newInt32(Int32(newLengthD)) : .newFloat64(newLengthD)
        // name = "bound " + target.name (an empty string when the target has
        // no string-valued name, per ES §10.4.1.3).
        var targetName = ""
        let targetNameVal = targetObj.getOwnPropertyValue(
            atom: JeffJSAtomID.JS_ATOM_name.rawValue)
        if targetNameVal.isString, let nameStr = targetNameVal.stringValue {
            targetName = nameStr.toSwiftString()
        }
        let boundName = "bound \(targetName)"

        // A real bound-function object (JS_CLASS_BOUND_FUNCTION with a
        // .boundFunction payload): callFunction, callInternal and
        // callConstructor unwrap it directly, and instanceof walks through it
        // to the target. The old version wrapped a Swift closure in a C
        // function, so every call through a bound function paid native
        // dispatch, a closure context and an array concatenation on top of the
        // target call; `new` through it lost the bound arguments, and it
        // carried an enumerable copy of the target's prototype.
        let boundVal = ctx.newObjectClass(classID: JSClassID.JS_CLASS_BOUND_FUNCTION.rawValue)
        guard let boundObj = boundVal.toObject() else { return boundVal }
        boundObj.payload = .boundFunction(JeffJSBoundFunction(funcObj: this.dupValue(), thisVal: thisArg,
                                                              argc: boundArgs.count, argv: boundArgs))
        // `length` then `name` (ES §20.2.3.2 steps 5-10; JSC's own-key order).
        _ = ctx.definePropertyValue(obj: boundVal, atom: JeffJSAtomID.JS_ATOM_length.rawValue,
                                    value: newLengthVal, flags: JS_PROP_CONFIGURABLE)
        let nameVal = ctx.newStringValue(boundName)
        _ = ctx.definePropertyValue(obj: boundVal, atom: JeffJSAtomID.JS_ATOM_name.rawValue,
                                    value: nameVal, flags: JS_PROP_CONFIGURABLE)
        nameVal.freeValue()   // definePropertyValue dups
        return boundVal
    }

    // MARK: - Function.prototype.toString

    /// The name JavaScriptCore puts in a native function's source text: the
    /// function's `name` without its "bound " / "get " / "set " prefixes.
    static func nativeCodeName(_ name: String, keepAccessorPrefix: Bool = false) -> String {
        var n = Substring(name)
        while n.hasPrefix("bound ") { n = n.dropFirst(6) }
        if !keepAccessorPrefix, n.hasPrefix("get ") || n.hasPrefix("set ") { n = n.dropFirst(4) }
        return String(n)
    }

    /// `Function.prototype.toString()`
    /// Returns the source code of the function, or a "[native code]" placeholder.
    ///
    /// Mirrors `js_function_toString` in QuickJS.
    static func toString(ctx: JeffJSContext, this: JeffJSValue,
                         args: [JeffJSValue]) -> JeffJSValue {
        // JSC's text for a non-function receiver is the bare "Type error"
        // (bot-defence scripts compare it: Function.prototype.toString.call(
        // Object.create(fn)) must fail exactly like WebKit's).
        guard let obj = getObject(this) else {
            return ctx.throwTypeError("Type error")
        }

        let classID = obj.classID

        switch obj.payload {
        case .bytecodeFunc(_, _, _) where obj.isPlatformFunction:
            // A host polyfill standing in for a WebKit built-in prints the
            // way WebKit prints its natives (DOM naming: no "get "/"set ").
            // Its `name` may still be the closure's deferred one.
            if obj.needsLazyNameLength { ctx.materializeFunctionNameLength(obj) }
            let name = nativeCodeName(getFunctionName(obj: obj))
            return JeffJSValue.makeString(JeffJSString(swiftString: "function \(name)() {\n    [native code]\n}"))

        case .bytecodeFunc(let functionBytecode, _, _):
            // Bytecode function — the parser recorded the source span of every
            // function it compiled (QuickJS `JSFunctionDef.source`), so return
            // the original text verbatim: `function f(){ ... }`, `x=>x`,
            // `get x(){ ... }`, `class A { ... }`, `async *g(){ ... }`.
            if let fb = functionBytecode, fb.sourceLen >= 0, let text = fb.sourceText {
                if let s = ctx.rt.functionSourceString(text, start: Int(fb.sourceStart), len: Int(fb.sourceLen)) {
                    return s
                }
            }

            // No recorded source (stripped or synthesized bytecode) — QuickJS
            // falls back to the native-code form here too.
            let name = getFunctionName(obj: obj)
            let result = "function \(name)() {\n    [native code]\n}"
            return JeffJSValue.makeString(JeffJSString(swiftString: result))

        case .cFunc(_, _, _, _, _):
            // C function — "function name() {\n    [native code]\n}", named as
            // JavaScriptCore prints it: a DOM accessor's "get x" / "set x" is
            // "x" (`function cookie()`), an ECMAScript builtin accessor keeps
            // it (`function get size()`, `function get __proto__()`) — both
            // from a WKWebView capture; pages fingerprint them.
            // An empty-named native prints `function () {` (JSC: Function.prototype itself,
            // which is a C function since 2026-10-06), never "anonymous".
            let rawName = getFunctionName(obj: obj)
            let ownName = obj.getOwnPropertyValue(atom: JeffJSAtomID.JS_ATOM_name.rawValue)
            let emptyName = ownName.isString && (ownName.stringValue?.toSwiftString().isEmpty ?? false)
            let name = emptyName ? "" : nativeCodeName(rawName, keepAccessorPrefix: obj.nativeNameKeepsAccessorPrefix)
            let result = "function \(name)() {\n    [native code]\n}"
            return JeffJSValue.makeString(JeffJSString(swiftString: result))

        case .boundFunction(_):
            // Bound function — JavaScriptCore prints the target's name without
            // the "bound " prefix: `f.bind(o)` → "function f() { [native code] }".
            let name = nativeCodeName(getFunctionName(obj: obj))
            let result = "function \(name)() {\n    [native code]\n}"
            return JeffJSValue.makeString(JeffJSString(swiftString: result))

        default:
            // Not a recognized function type. If it has a call handler
            // (proxy or class-based callable), still produce output.
            if classID == JeffJSClassID.proxy.rawValue {
                // Proxy wrapping a function: JSC names its callable proxy class
                // "ProxyObject" — `Function.prototype.toString.call(new
                // Proxy(Math.max, {}))` is "function ProxyObject() {…}".
                let result = "function ProxyObject() {\n    [native code]\n}"
                return JeffJSValue.makeString(JeffJSString(swiftString: result))
            }
            return ctx.throwTypeError("Type error")
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
                // A fresh string: `makeString(fn)` wrapped the bytecode's own
                // file name without a count, so the value's release freed it.
                return ctx.newStringValue(fn.toSwiftString())
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
        if argsObj.isArray, let snap = argsObj.arraySnapshot() {
            let actualCount = min(length, snap.count)
            return Array(snap.values.prefix(actualCount))
        }

        // General path: read indexed properties. An array-like's length is
        // arbitrary (`{length: 2**32 + 1}`): reserving/looping that many
        // slots hung or exhausted memory. QuickJS throws "too many arguments"
        // past 65,535; allow more (engines differ) but not unbounded.
        if length > 10_000_000 {
            _ = ctx.throwRangeError(message: "too many arguments in function call")
            return nil
        }
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
        // (a Proxy on the chain answers with its [[GetPrototypeOf]])
        var keep: [JeffJSValue] = []
        defer { for v in keep { v.freeValue() } }
        let maxProtoChain = 1000
        for _ in 0..<maxProtoChain {
            guard let parentProto = ctx.prototypeForWalk(valObj, keep: &keep) else {
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

        // Add (or replace in place) the method on the prototype
        ctx.defineOrReplaceOwnPropertyFree(.borrowedObject(proto), atom: name,
                                           value: JeffJSValue.makeObject(methodObj),
                                           flags: JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE, intrinsic: true)
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

        ctx.defineOrReplaceOwnPropertyFree(.borrowedObject(proto), atom: name,
                                           value: JeffJSValue.makeObject(methodObj),
                                           flags: JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE, intrinsic: true)
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

        // A getter-only accessor, defined or replaced in place (it used to write the
        // prototype's last slot). `makeObject` takes the ARC retain the hand-built
        // getter's creation count needs; the property dups, that count is dropped.
        let gv = JeffJSValue.makeObject(getterObj)
        ctx.defineOrReplaceOwnProperty(.borrowedObject(proto), atom: name, getter: gv, setter: nil,
                                       flags: JS_PROP_CONFIGURABLE | JS_PROP_GETSET, intrinsic: true)
        gv.freeValue()
    }

    /// Helper for creating new JeffJSValue with .newBool.
    private static func newBool(_ val: Bool) -> JeffJSValue {
        return JeffJSValue.newBool(val)
    }
}
