// JeffJSInterpreter.swift
// JeffJS - 1:1 Swift port of QuickJS JavaScript engine
//
// The bytecode interpreter: a single large function that dispatches over
// every opcode via a switch statement.  Port of JS_CallInternal() and
// all inline helper functions from QuickJS (quickjs.c).
//
// This file also includes type-conversion helpers (ToNumber, ToInt32,
// ToString, ToBool, ToPrimitive) and operator helpers (jsAdd, jsEq,
// jsStrictEq, jsCompare, jsInstanceof, jsTypeof).
//
// Copyright 2026 Jeff Bachand. All rights reserved.

import Foundation

// =============================================================================
// MARK: - JeffJSContext API Bridge Helpers
// =============================================================================

// _currentFrameStore and _mathFixupApplied moved to stored properties on JeffJSContext
// for O(1) access instead of dictionary lookups in the hot path.

/// Bridge helpers that adapt the interpreter's call-site conventions to the
/// actual JeffJSContext API (which uses named parameters like `message:`,
/// `obj:`, etc.).  Keeps the main interpreter switch compact.
extension JeffJSContext {
    /// Creates a new JS string value from a Swift String.
    /// Bridges `ctx.newString(s)` to a proper JeffJSString allocation.
    func newString(_ s: String) -> JeffJSValue {
        let jsStr = JeffJSString(swiftString: s)
        return JeffJSValue.makeString(jsStr)
    }

    /// Concatenates two JS string values into a new JS string.
    /// Uses the rope-based jeffJS_concatStrings for O(1) concat instead of
    /// round-tripping through Swift String (which was O(n) per concat, O(n^2) in loops).
    func concatStrings(_ a: JeffJSValue, _ b: JeffJSValue) -> JeffJSValue {
        return jeffJS_concatStrings(s1: a, s2: b)
    }

    // currentFrame is now a stored property on JeffJSContext directly (see JeffJSContext.swift).

    /// Returns the atom for a well-known symbol (e.g. "toPrimitive", "hasInstance").
    /// Maps well-known symbol names to their predefined atom IDs from the runtime.
    func getWellKnownSymbol(_ name: String) -> UInt32 {
        switch name {
        case "toPrimitive":      return JeffJSAtomID.JS_ATOM_Symbol_toPrimitive.rawValue
        case "iterator":         return JeffJSAtomID.JS_ATOM_Symbol_iterator.rawValue
        case "asyncIterator":    return JeffJSAtomID.JS_ATOM_Symbol_asyncIterator.rawValue
        case "hasInstance":      return JeffJSAtomID.JS_ATOM_Symbol_hasInstance.rawValue
        case "match":            return JeffJSAtomID.JS_ATOM_Symbol_match.rawValue
        case "matchAll":         return JeffJSAtomID.JS_ATOM_Symbol_matchAll.rawValue
        case "replace":          return JeffJSAtomID.JS_ATOM_Symbol_replace.rawValue
        case "search":           return JeffJSAtomID.JS_ATOM_Symbol_search.rawValue
        case "split":            return JeffJSAtomID.JS_ATOM_Symbol_split.rawValue
        case "toStringTag":      return JeffJSAtomID.JS_ATOM_Symbol_toStringTag.rawValue
        case "isConcatSpreadable": return JeffJSAtomID.JS_ATOM_Symbol_isConcatSpreadable.rawValue
        case "species":          return JeffJSAtomID.JS_ATOM_Symbol_species.rawValue
        case "unscopables":      return JeffJSAtomID.JS_ATOM_Symbol_unscopables.rawValue
        default:                 return 0
        }
    }

    /// OrdinaryHasInstance: walks the prototype chain of `val` looking for
    /// `target.prototype`.  Per ECMAScript spec section 7.3.21.
    func ordinaryHasInstance(_ target: JeffJSValue, _ val: JeffJSValue) -> Bool {
        // 1. If target is not callable, return false (handled by caller).
        // 2. Bound functions have .prototype copied from target at bind() time.
        // 3. If val is not an object, return false.
        guard let valObj = val.toObject() else { return false }
        // 4. Let P be target.prototype
        let protoVal = getProperty(obj: target, atom: JeffJSAtomID.JS_ATOM_prototype.rawValue)
        guard protoVal.isObject, let targetProto = protoVal.toObject() else { return false }
        // 5. Walk the prototype chain of val looking for P.
        //    obj.proto is the single source of truth for the prototype.
        var current: JeffJSObject? = valObj.proto
        while let cur = current {
            if cur === targetProto { return true }
            current = cur.proto
        }
        return false
    }

    /// Calls a JS function with the given this-value and arguments.
    /// Dispatches to C-function path or bytecode interpreter path.
    func callFunction(_ funcVal: JeffJSValue, thisVal: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        // activeRuntime is already set by JeffJSContext.init or eval() —
        // no need to write the static on every call.

        // Guard against stack overflow — C function callbacks can recurse back into callFunction
        JeffJSInterpreter.currentCallDepth += 1
        defer { JeffJSInterpreter.currentCallDepth -= 1 }
        if JeffJSInterpreter.currentCallDepth > JeffJSInterpreter.maxCallDepth {
            return throwInternalError(message: "Maximum call stack size exceeded")
        }

        guard let obj = funcVal.toObject() else {
            let desc: String
            if funcVal.isUndefined { desc = "undefined" }
            else if funcVal.isNull { desc = "null" }
            else if funcVal.isInt { desc = String(funcVal.toInt32()) }
            else if funcVal.isBool { desc = funcVal.toBool() ? "true" : "false" }
            else { desc = toSwiftString(funcVal) ?? "\(funcVal.tag)" }
            // Build context hint from current stack frame
            var hint = ""
            if let frame = self.currentFrame,
               let curFn = frame.curFunc.toObject(),
               case .bytecodeFunc(let fbOpt, _, _) = curFn.payload,
               let fb = fbOpt {
                let fname = fb.fileName?.toSwiftString() ?? "?"
                hint = " at \(fname):\(fb.lineNum) pc=\(frame.curPC)"
            }
            return throwTypeError(message: "\(desc) is not a function\(hint)")
        }
        // Bound function path: unwrap and recurse with bound this/args
        if case .boundFunction(let bound) = obj.payload {
            var fullArgs = bound.argv
            fullArgs.append(contentsOf: args)
            let boundThis = bound.thisVal.isUndefined ? thisVal : bound.thisVal
            return callFunction(bound.funcObj, thisVal: boundThis, args: fullArgs)
        }
        // C function path
        if case .cFunc(_, let cFunction, _, _, let magic) = obj.payload {
            switch cFunction {
            case .generic(let fn):
                return fn(self, thisVal, args)
            case .genericMagic(let fn):
                return fn(self, thisVal, args, Int(magic))
            case .constructor(let fn):
                return fn(self, thisVal, args)
            case .constructorOrFunc(let fn):
                return fn(self, thisVal, args, false)
            case .getter(let fn):
                return fn(self, thisVal)
            case .setter(let fn):
                return fn(self, thisVal, args.first ?? .undefined)
            case .getterMagic(let fn):
                return fn(self, thisVal, Int(magic))
            case .setterMagic(let fn):
                return fn(self, thisVal, args.first ?? .undefined, Int(magic))
            case .fFloat64(let fn):
                let x = args.first?.toFloat64() ?? Double.nan
                return .newFloat64(fn(x))
            case .fFloat64_2(let fn):
                let x = args.first?.toFloat64() ?? Double.nan
                let y = (args.count > 1 ? args[1] : JeffJSValue.undefined).toFloat64()
                return .newFloat64(fn(x, y))
            case .iteratorNext(let fn):
                return fn(self, thisVal, args, nil, Int(magic))
            }
        }
        // Generator function path: create a generator object and save the
        // initial interpreter state so that the first .next() call starts
        // execution from the beginning of the generator body.
        //
        // QuickJS emits an `initial_yield` opcode at the top of every
        // generator body.  The JeffJS parser/compiler does NOT emit this
        // opcode, so we synthesise the effect here: build a
        // GeneratorSavedState that points to pc=0 (the very first
        // bytecode) and mark it as isInitialYield so that the first
        // resumption doesn't push a spurious value onto the stack.
        if case .bytecodeFunc(let fbOpt, _, _) = obj.payload,
           let fb = fbOpt, fb.isGenerator {
            // Create the generator object with JS_CLASS_GENERATOR class
            let genObj = newObjectClass(classID: JSClassID.JS_CLASS_GENERATOR.rawValue)
            if genObj.isException { return .exception }

            // Build initial varBuf / argBuf that callInternal would create.
            // This replicates the frame setup at the top of callInternal.
            let varCount = Int(fb.varCount)
            let initVarBuf = [JeffJSValue](repeating: .undefined, count: varCount)
            let argSlots = Int(fb.argCount)
            var initArgBuf = args
            if initArgBuf.count < argSlots {
                initArgBuf.append(contentsOf:
                    [JeffJSValue](repeating: .undefined,
                                  count: argSlots - initArgBuf.count))
            }

            // Initialize generator data with the saved state pointing
            // to pc=0 (start of the generator body).
            let genData = JeffJSGeneratorData()
            genData.state = .suspended_start
            genData.savedState = GeneratorSavedState(
                pc: 0,
                sp: 0,
                stack: [],
                varBuf: initVarBuf,
                argBuf: initArgBuf,
                funcObj: funcVal,
                thisVal: thisVal,
                isInitialYield: true)
            genObj.toObject()?.payload = .generatorData(genData)

            return genObj
        }
        // Async function path: create a pending Promise, run the body.
        // If the body suspends at an `await` on a pending Promise, the
        // await_ opcode saves state and registers .then() callbacks to
        // resume later. Otherwise, we resolve/reject immediately.
        if case .bytecodeFunc(let fbOpt, _, _) = obj.payload,
           let fb = fbOpt, fb.isAsyncFunc {
            guard let cap = JeffJSBuiltinPromise.newPromiseCapability(ctx: self, ctor: .undefined) else {
                return JeffJSBuiltinPromise.resolve(ctx: self, this: .undefined, args: [.undefined])
            }

            // Thread resolve/reject through the context so await_ can access them
            let prevResolve = _asyncResolve
            let prevReject = _asyncReject
            let prevSuspended = _asyncSuspended
            _asyncResolve = cap.resolve
            _asyncReject = cap.reject
            _asyncSuspended = false

            let result = JeffJSInterpreter.callInternal(ctx: self, funcObj: funcVal,
                                                         thisVal: thisVal, args: args, flags: 0)

            let suspended = _asyncSuspended
            // Restore previous async state (for nested async calls)
            _asyncResolve = prevResolve
            _asyncReject = prevReject
            _asyncSuspended = prevSuspended

            if suspended {
                // Function suspended at await — return the pending Promise.
                // It will be resolved later when the awaited Promise settles.
                return cap.promise
            }
            if result.isException {
                let err = getException()
                _ = call(cap.reject, this: .undefined, args: [err])
            } else {
                _ = call(cap.resolve, this: .undefined, args: [result])
            }
            _ = rt.executePendingJobs()
            return cap.promise
        }

        // Callable proxy path: delegate to the proxy apply trap handler
        if case .proxyData = obj.payload {
            return js_proxy_apply(self, obj, thisVal, args)
        }

        // Regular bytecode function path — verify it IS a bytecode function
        guard case .bytecodeFunc = obj.payload else {
            // Not a callable type (plain object, array, etc.)
            let desc = toSwiftString(funcVal) ?? "[object]"
            var hint = ""
            if let frame = self.currentFrame,
               let curFn = frame.curFunc.toObject(),
               case .bytecodeFunc(let fbOpt, _, _) = curFn.payload,
               let fb = fbOpt {
                let fname = fb.fileName?.toSwiftString() ?? "?"
                hint = " at \(fname):\(fb.lineNum) pc=\(frame.curPC)"
            }
            return throwTypeError(message: "\(desc) is not a function\(hint)")
        }
        return JeffJSInterpreter.callInternal(ctx: self, funcObj: funcVal,
                                               thisVal: thisVal, args: args, flags: 0)
    }

    /// Resumes a suspended generator by restoring its saved state and
    /// re-entering the bytecode dispatch loop.
    ///
    /// - Parameters:
    ///   - genObj: The generator object (must have `.generatorData` payload).
    ///   - sendValue: The value passed to `.next(value)`.
    ///   - completionType: 0 = next, 1 = return, 2 = throw.
    /// - Returns: An iterator result `{value, done}`, or `.exception`.
    func generatorResume(genObj: JeffJSValue, sendValue: JeffJSValue,
                         completionType: Int) -> JeffJSValue {
        guard let obj = genObj.toObject(),
              case .generatorData(let genData) = obj.payload else {
            return throwTypeError(message: "not a generator object")
        }

        guard let saved = genData.savedState else {
            // No saved state means generator was never properly initialized
            genData.state = .completed
            if completionType == 2 {
                return throwValue(sendValue.dupValue())
            }
            return JeffJSBuiltinIterator.createIterResult(ctx: self, val: sendValue, done: true)
        }

        genData.state = .executing
        genData.savedState = nil

        // Resume via callInternal with the saved state
        let result = JeffJSInterpreter.callInternal(
            ctx: self,
            funcObj: saved.funcObj,
            thisVal: saved.thisVal,
            args: [],
            flags: JS_CALL_FLAG_GENERATOR,
            generatorObject: genObj,
            resumeState: saved,
            resumeValue: sendValue,
            resumeCompletionType: completionType)

        if result.isException {
            genData.state = .completed
            genData.savedState = nil
            return .exception
        }

        // If the generator completed (return_ or return_undef opcode was hit
        // rather than a yield), the state will be .executing still — mark completed.
        if genData.state == .executing {
            genData.state = .completed
            genData.savedState = nil
            return JeffJSBuiltinIterator.createIterResult(ctx: self, val: result, done: true)
        }

        // If still suspended (yield set the state), the result is the yielded
        // value, wrapped as {value, done: false}.
        return JeffJSBuiltinIterator.createIterResult(ctx: self, val: result, done: false)
    }

    // MARK: - Object Creation Stubs

    /// Creates a special object (arguments, mapped arguments, etc.) based on kind.
    func newSpecialObject(kind: UInt8, frame: JeffJSStackFrame) -> JeffJSValue {
        switch SpecialObjectType(rawValue: kind) {
        case .arguments, .mappedArguments:
            // Create an arguments object with the current frame's arguments
            let argsObj = newObject()
            for (i, arg) in frame.argBuf.enumerated() {
                _ = setPropertyUint32(obj: argsObj, index: UInt32(i), value: arg.dupValue())
            }
            let lengthAtom = JeffJSAtomID.JS_ATOM_length.rawValue
            _ = setProperty(obj: argsObj, atom: lengthAtom,
                           value: .newInt32(Int32(frame.argBuf.count)))
            // Set callee for non-strict mode
            if kind == SpecialObjectType.mappedArguments.rawValue {
                let calleeAtom = JeffJSAtomID.JS_ATOM_callee.rawValue
                _ = setProperty(obj: argsObj, atom: calleeAtom, value: frame.curFunc.dupValue())
            }
            // Add Symbol.iterator so arguments is iterable
            let symIterAtom = JeffJSAtomID.JS_ATOM_Symbol_iterator.rawValue
            let arrayProtoIterAtom = getProperty(obj: globalObj, atom: rt.findAtom("Array"))
            if arrayProtoIterAtom.isObject {
                let arrProto = getProperty(obj: arrayProtoIterAtom,
                                            atom: JeffJSAtomID.JS_ATOM_prototype.rawValue)
                if arrProto.isObject {
                    let iterFn = getProperty(obj: arrProto, atom: symIterAtom)
                    if iterFn.isFunction {
                        _ = setProperty(obj: argsObj, atom: symIterAtom, value: iterFn)
                    }
                }
            }
            return argsObj
        case .thisVal:
            return frame.thisVal.dupValue()
        case .newTarget:
            return frame.newTarget.dupValue()
        case .homeObject:
            // Return the home object from the current function for super references
            if let funcObj = frame.curFunc.toObject(),
               case .bytecodeFunc(_, _, let homeObj) = funcObj.payload,
               let home = homeObj {
                return JeffJSValue.makeObject(home)
            }
            return .undefined
        case .varObject:
            // Variable environment object for `with` statement
            return newObject()
        case .importMeta:
            // import.meta -- return a basic object for now
            return newObject()
        case .none:
            return newObject()
        }
    }

    /// Creates a rest-parameter array from the given args starting at fromIndex.
    func createRestArray(args: [JeffJSValue], fromIndex: Int) -> JeffJSValue {
        let arr = newArray()
        if(fromIndex <= args.count) {
            for i in fromIndex..<args.count {
                _ = setPropertyUint32(obj: arr, index: UInt32(i - fromIndex), value: args[i].dupValue())
            }
        }
        return arr
    }

    /// Creates a new array from the given items.
    func newArrayFrom(_ items: [JeffJSValue]) -> JeffJSValue {
        let arr = newArray()
        for (i, item) in items.enumerated() {
            _ = setPropertyUint32(obj: arr, index: UInt32(i), value: item)
        }
        // Update length to match the number of items
        if !items.isEmpty {
            setArrayLength(arr, Int64(items.count))
        }
        return arr
    }

    /// Creates a closure from a bytecode function.
    /// For generator functions, sets the classID to `.generatorFunction` and
    /// uses the GeneratorFunction prototype so that calling the function
    /// produces a generator object.
    ///
    /// Builds the child function's var_ref array from its `closureVars` list:
    /// - `isLocal` closure vars create a new `JeffJSVarRef` pointing at the
    ///   parent frame's local/arg slot (live reference).
    /// - Non-local closure vars reuse the parent's own var_ref (chaining).
    func createClosure(fb: JeffJSFunctionBytecode, cpoolIdx: Int,
                       varRefs: [JeffJSVarRef?], parentFrame: JeffJSStackFrame) -> JeffJSValue {
        guard cpoolIdx < fb.cpool.count else {
            return .undefined
        }
        let closureFB = fb.cpool[cpoolIdx]
        guard let innerFB = closureFB.toFunctionBytecode() else {
            return closureFB.dupValue()
        }
        let obj = JeffJSObject()

        // Determine the correct classID based on function kind
        if innerFB.isGenerator && innerFB.isAsyncFunc {
            obj.classID = JSClassID.JS_CLASS_ASYNC_GENERATOR_FUNCTION.rawValue
        } else if innerFB.isGenerator {
            obj.classID = JSClassID.JS_CLASS_GENERATOR_FUNCTION.rawValue
        } else if innerFB.isAsyncFunc {
            obj.classID = JSClassID.JS_CLASS_ASYNC_FUNCTION.rawValue
        } else {
            obj.classID = JeffJSClassID.bytecodeFunction.rawValue
        }

        obj.extensible = true

        // Build the child's var_ref array from its closureVars metadata.
        var childVarRefs: [JeffJSVarRef?] = []
        if let compiled = innerFB as? JeffJSFunctionBytecodeCompiled {
            childVarRefs.reserveCapacity(compiled.closureVars.count)
            for cv in compiled.closureVars {
                if cv.isLocal {
                    // The closure var references the parent's own local/arg slot.
                    // Check if we already have a live var_ref for this exact slot
                    // on the parent frame, so multiple closures share the same ref.
                    let existingVR = parentFrame.liveVarRefs.first {
                        $0.isArg == cv.isArg &&
                        $0.varIdx == UInt16(cv.varIdx) &&
                        !$0.isDetached
                    }
                    if let vr = existingVR {
                        childVarRefs.append(vr)
                    } else {
                        let vr = JeffJSVarRef(
                            isDetached: false,
                            isArg: cv.isArg,
                            varIdx: UInt16(cv.varIdx),
                            parentFrame: parentFrame
                        )
                        parentFrame.liveVarRefs.append(vr)
                        childVarRefs.append(vr)
                    }
                } else {
                    // The closure var references the parent's own closure var
                    // (threading through an intermediate function).
                    let parentIdx = cv.varIdx
                    if parentIdx < varRefs.count {
                        childVarRefs.append(varRefs[parentIdx])
                    } else {
                        childVarRefs.append(nil)
                    }
                }
            }
        }

        obj.payload = .bytecodeFunc(functionBytecode: innerFB, varRefs: childVarRefs, homeObject: nil)

        // Arrow functions capture the enclosing function's `this` value
        // so that `push_this` inside the arrow returns the lexical `this`.
        if innerFB.isArrow {
            obj.arrowThisVal = parentFrame.thisVal.dupValue()
        }

        // Set prototype: use the class-specific prototype if available,
        // otherwise fall back to the generic function prototype.
        let classProtoID = obj.classID
        var closureProto: JeffJSObject? = nil
        if classProtoID < classProto.count && classProto[classProtoID].isObject {
            closureProto = classProto[classProtoID].toObject()
        } else if functionProto.isObject {
            closureProto = functionProto.toObject()
        }

        // Ensure shape exists — use zero-alloc initial shape
        if obj.shape == nil {
            obj.shape = createShape(self, proto: closureProto, hashSize: 0, propSize: 0)
        }
        // Set proto after shape (proto may already be synced via shape)
        obj.proto = closureProto

        let funcVal = JeffJSValue.makeObject(obj)

        // For regular (non-arrow, non-generator, non-async) functions, set up
        // F.prototype = { constructor: F } so prototype-based OOP works.
        // Arrow functions don't have .prototype. Generators/async have different setup.
        if !innerFB.isGenerator && !innerFB.isAsyncFunc && !innerFB.isArrow {
            let protoObj = newObject()
            _ = setPropertyStr(obj: protoObj, name: "constructor", value: funcVal.dupValue())
            _ = setPropertyStr(obj: funcVal, name: "prototype", value: protoObj)
            obj.isConstructor = true
        }

        return funcVal
    }

    // MARK: - Atom Helpers

    /// Converts an atom to a JS string value.
    func atomToString(_ atom: UInt32) -> JeffJSValue {
        if let str = rt.atomToString(atom) {
            return newString(str)
        }
        return .undefined
    }

    /// Converts an atom to a Swift String.
    func atomToSwiftString(_ atom: UInt32) -> String {
        return rt.atomToString(atom) ?? ""
    }

    /// Creates a new symbol from an atom.
    /// For private fields, creates a unique symbol that serves as the property key.
    /// Each call creates a new unique symbol (identity is by reference).
    func newSymbolFromAtom(_ atom: UInt32, isPrivate: Bool) -> JeffJSValue {
        let desc = rt.atomToString(atom) ?? ""
        let atomStr = JeffJSString(swiftString: desc)
        atomStr.atomType = JSAtomType.symbol.rawValue
        return JeffJSValue.mkPtr(tag: .symbol, ptr: atomStr)
    }

    // MARK: - Call / Constructor Stubs

    /// Calls a function as a constructor.
    /// Per ECMAScript [[Construct]]:
    /// 1. Get the constructor's .prototype property.
    /// 2. Create a new object with that prototype.
    /// 3. Call the constructor with the new object as `this`.
    /// 4. If the constructor returns an object, use it; otherwise use the new object.
    func callConstructor(_ funcVal: JeffJSValue, newTarget: JeffJSValue,
                         args: [JeffJSValue]) -> JeffJSValue {
        guard let obj = funcVal.toObject() else {
            return throwTypeError(message: "not a constructor")
        }
        // C function constructor path
        if case .cFunc(_, let cFunction, _, _, let magic) = obj.payload {
            switch cFunction {
            case .constructor(let fn):
                return fn(self, newTarget, args)
            case .constructorOrFunc(let fn):
                return fn(self, newTarget, args, true)
            case .generic(let fn):
                // Some generic C functions can be called as constructors
                let newObj = newObject()
                let result = fn(self, newObj, args)
                if result.isException { return .exception }
                return result.isObject ? result : newObj
            default:
                return throwTypeError(message: "not a constructor")
            }
        }
        // Bound function constructor path: unwrap and recurse.
        // Per ES spec, bound functions forward [[Construct]] to the target,
        // prepending bound args. The bound thisVal is ignored for constructors.
        if case .boundFunction(let bound) = obj.payload {
            var fullArgs = bound.argv
            fullArgs.append(contentsOf: args)
            return callConstructor(bound.funcObj, newTarget: newTarget, args: fullArgs)
        }
        // Callable proxy constructor path: delegate to proxy construct trap
        if case .proxyData = obj.payload {
            return js_proxy_construct(self, obj, args, newTarget)
        }
        // Bytecode function constructor path — verify it IS a bytecode function
        guard case .bytecodeFunc = obj.payload else {
            let payloadDesc: String
            switch obj.payload {
            case .opaque(let v): payloadDesc = "opaque(\(v == nil ? "nil" : String(describing: type(of: v!))))"
            case .cFunc: payloadDesc = "cFunc"
            case .boundFunction: payloadDesc = "boundFunction"
            default: payloadDesc = "\(obj.payload)"
            }
            return throwTypeError(message: "not a constructor")
        }
        // 1. Get constructor's .prototype to use as the new object's [[Prototype]]
        let protoVal = getProperty(obj: funcVal, atom: JeffJSAtomID.JS_ATOM_prototype.rawValue)
        let newObj: JeffJSValue
        if protoVal.isObject {
            newObj = newObjectProto(proto: protoVal)
        } else {
            // If .prototype is not an object, use Object.prototype
            newObj = newObject()
        }
        // 2. Call the constructor with the new object as `this`
        let result = JeffJSInterpreter.callInternal(ctx: self, funcObj: funcVal,
                                                     thisVal: newObj, args: args,
                                                     flags: JS_CALL_FLAG_CONSTRUCTOR)
        if result.isException { return .exception }
        // 3. If the constructor explicitly returned an object, use it
        if result.isObject { return result }
        // 4. Otherwise return the newly created object
        return newObj
    }

    /// Converts a JS array (or array-like) value to a Swift array of JeffJSValues.
    /// Reads .length and indexes [0..length) to build the args array.
    func arrayToArgs(_ argsArray: JeffJSValue) -> [JeffJSValue] {
        guard argsArray.isObject else { return [] }
        let lenVal = getPropertyStr(obj: argsArray, name: "length")
        let len: Int
        if lenVal.isInt { len = Int(lenVal.toInt32()) }
        else if lenVal.isFloat64 { len = Int(lenVal.toFloat64()) }
        else { return [] }
        var result = [JeffJSValue]()
        result.reserveCapacity(len)
        for i in 0..<len {
            result.append(getPropertyUint32(obj: argsArray, index: UInt32(i)))
        }
        return result
    }

    // MARK: - Brand / Private Field Stubs

    /// Checks if an object has a private brand.
    /// Private brands are used by the spec to enforce that private field access
    /// only works on instances that were constructed by the right class.
    /// The brand is stored as a symbol-keyed property on the object.
    func checkBrand(obj: JeffJSValue, brand: JeffJSValue) -> Bool {
        guard let jsObj = obj.toObject() else { return false }
        // Check if the object has the brand symbol as a property
        if brand.isSymbol, let symStr = brand.toPtr() as? JeffJSString {
            let key = symStr.toSwiftString()
            let atom = rt.findAtom(key)
            let has = hasProperty(obj: obj, atom: atom)
            rt.freeAtom(atom)
            return has
        }
        // If brand is not a symbol, this is likely a class without private fields;
        // return true to allow access
        return true
    }

    /// Adds a private brand to an object.
    /// Marks the object as being an instance of the class that owns the private fields.
    func addBrand(obj: JeffJSValue, brand: JeffJSValue) {
        if brand.isSymbol, let symStr = brand.toPtr() as? JeffJSString {
            let key = symStr.toSwiftString()
            let atom = rt.findAtom(key)
            _ = setProperty(obj: obj, atom: atom, value: .newBool(true))
            rt.freeAtom(atom)
            // Don't free atom — setProperty stores it in the shape.
        }
    }

    /// Gets a private field value from an object.
    /// Private fields are stored as symbol-keyed properties.
    func getPrivateField(obj: JeffJSValue, field: JeffJSValue) -> JeffJSValue {
        if field.isSymbol, let symStr = field.toPtr() as? JeffJSString {
            let key = symStr.toSwiftString()
            let atom = rt.findAtom(key)
            let val = getProperty(obj: obj, atom: atom)
            rt.freeAtom(atom)
            return val
        }
        _ = throwTypeError(message: "cannot read private field")
        return .exception
    }

    /// Sets a private field value on an object.
    func putPrivateField(obj: JeffJSValue, field: JeffJSValue, val: JeffJSValue) -> Bool {
        if field.isSymbol, let symStr = field.toPtr() as? JeffJSString {
            let key = symStr.toSwiftString()
            let atom = rt.findAtom(key)
            let ok = setProperty(obj: obj, atom: atom, value: val) >= 0
            rt.freeAtom(atom)
            // Don't free atom — setProperty stores it in the shape.
            return ok
        }
        _ = throwTypeError(message: "cannot write private field")
        return false
    }

    /// Defines a new private field on an object.
    func definePrivateField(obj: JeffJSValue, field: JeffJSValue, val: JeffJSValue) {
        if field.isSymbol, let symStr = field.toPtr() as? JeffJSString {
            let key = symStr.toSwiftString()
            let atom = rt.findAtom(key)
            _ = definePropertyValue(obj: obj, atom: atom, value: val,
                                     flags: JS_PROP_C_W_E)
            rt.freeAtom(atom)
            // Don't free atom — definePropertyValue stores it in the shape.
        }
    }

    // MARK: - Async Function Support

    /// Resolves an async function.
    /// If the async function was called with a pending Promise, this resolves
    /// that Promise with the given value. For synchronous fallback (no Promise
    /// integration yet), this is still a no-op but kept for the return_async
    /// opcode path.
    func asyncFunctionResolve(frame: JeffJSStackFrame, val: JeffJSValue) {
        // TODO: When Promise integration is complete, resolve the async
        // function's implicit promise here. Requires:
        // - The Promise object stored in the async function state
        // - Calling resolveFunc(val) on that Promise
        // - Scheduling microtask queue processing via JeffJSRuntime
    }

    // MARK: - Error Throwing Stubs

    /// Throws an error based on a numeric error type code.
    /// Maps ThrowErrorType values from the throw_error opcode to the correct
    /// error constructor per ECMAScript / QuickJS semantics.
    func throwErrorFromType(errType: Int, msg: String) {
        switch errType {
        case 0: // deleteSuperProperty -> ReferenceError
            _ = throwReferenceError(message: msg)
        case 1: // setPropertyReadOnly -> TypeError
            _ = throwTypeError(message: msg)
        case 2: // varRedeclaration -> SyntaxError
            _ = throwSyntaxError(message: msg)
        case 3: // invalidOrDestructuring -> ReferenceError
            _ = throwReferenceError(message: msg)
        case 4: // notDefined -> ReferenceError
            _ = throwReferenceError(message: msg)
        case 5: // constAssign -> TypeError
            _ = throwTypeError(message: msg)
        default:
            _ = throwTypeError(message: msg)
        }
    }

    // MARK: - Eval / Import Stubs

    /// Direct eval (called from within bytecode).
    /// Note: direct eval should use the calling scope's variable environment,
    /// but currently uses global scope. The `scope` parameter is reserved for
    /// future per-scope eval support.
    ///
    /// KNOWN LIMITATION: This should use JS_EVAL_TYPE_DIRECT to inherit the
    /// calling scope's variable environment (let/const bindings, closures,
    /// etc.), but currently uses JS_EVAL_TYPE_GLOBAL. Fixing this requires
    /// passing the caller's scope chain into the eval compilation, which is
    /// not yet implemented. As a result, direct eval cannot see local
    /// variables from the enclosing function scope.
    func evalDirect(args: [JeffJSValue], scope: Int, frame: JeffJSStackFrame) -> JeffJSValue {
        guard let arg0 = args.first, arg0.isString, let str = arg0.stringValue else {
            return args.first ?? .undefined
        }
        // TODO: Use JS_EVAL_TYPE_DIRECT with scope chain access once implemented.
        return eval(input: str.toSwiftString(), filename: "<eval>", evalFlags: JS_EVAL_TYPE_GLOBAL)
    }

    /// Creates a new RegExp object.
    /// Delegates to the registered `compileRegexp` callback if available.
    func newRegExp(pattern: JeffJSValue, flags: JeffJSValue) -> JeffJSValue {
        if let compile = compileRegexp {
            return compile(self, pattern, flags)
        }
        _ = throwTypeError(message: "RegExp not available")
        return .exception
    }

    /// Gets the super constructor from a derived class.
    /// In ECMAScript, GetSuperConstructor returns the [[Prototype]] of the
    /// active function object (the class constructor), which is the parent class.
    func getSuperConstructor(obj: JeffJSValue) -> JeffJSValue {
        guard let jsObj = obj.toObject(), let proto = jsObj.proto else {
            _ = throwTypeError(message: "super constructor is not a constructor")
            return .exception
        }
        let protoVal = JeffJSValue.makeObject(proto)
        if !protoVal.isFunction {
            _ = throwTypeError(message: "super constructor is not a constructor")
            return .exception
        }
        return protoVal
    }

    /// Dynamic import().
    /// Routes to window.__dynamicImport(specifier) which is installed by
    /// JeffJSDynamicImportBridge and returns a Promise.
    func dynamicImport(specifier: JeffJSValue) -> JeffJSValue {
        let global = getGlobalObject()
        let fn = getPropertyStr(obj: global, name: "__dynamicImport")
        defer { fn.freeValue() }
        guard fn.isObject else {
            _ = throwTypeError(message: "dynamic import not supported")
            return .exception
        }
        let specStr = toSwiftString(specifier) ?? ""
        let arg = newStringValue(specStr)
        let result = call(fn, this: global, args: [arg])
        return result
    }

    // MARK: - Global Variable Stubs

    /// Checks if a global variable exists.
    func checkGlobalVar(atom: UInt32) -> Bool {
        return hasProperty(obj: globalObj, atom: atom)
    }

    /// Gets a global variable value.
    ///
    /// The previous implementation checked `val.isUndefined` to decide whether
    /// to throw a ReferenceError, which incorrectly threw for globals whose
    /// value *is* `undefined` (e.g. the global `undefined` property).
    /// The fix: first check whether the property actually exists on the global
    /// object (including its prototype chain).  Only throw ReferenceError when
    /// the property does not exist at all.
    func getGlobalVar(atom: UInt32, throwRefError: Bool) -> JeffJSValue {
        // Check existence first so that globals with an `undefined` value
        // (e.g. `undefined` itself) are returned correctly.
        if hasProperty(obj: globalObj, atom: atom) {
            return getProperty(obj: globalObj, atom: atom)
        }
        if throwRefError {
            let name = atomToSwiftString(atom)
            _ = throwReferenceError(message: "\(name) is not defined")
            return .exception
        }
        return .JS_UNDEFINED
    }

    /// Sets a global variable value.
    func putGlobalVar(atom: UInt32, val: JeffJSValue, flags: Int) -> Bool {
        return setProperty(obj: globalObj, atom: atom, value: val) >= 0
    }

    /// Defines a new global variable.
    func defineGlobalVar(atom: UInt32, flags: Int) -> Bool {
        return definePropertyValue(obj: globalObj, atom: atom, value: .undefined, flags: flags) >= 0
    }

    /// Checks if a global variable can be defined.
    /// Returns false if the global object is not extensible and the property doesn't exist.
    func checkDefineGlobalVar(atom: UInt32, flags: Int) -> Bool {
        // If the property already exists, it can be redefined (subject to other checks)
        if hasProperty(obj: globalObj, atom: atom) { return true }
        // If the global object is not extensible, can't add new properties
        if let obj = globalObj.toObject(), !obj.extensible {
            _ = throwTypeError(message: "Cannot define property on non-extensible object")
            return false
        }
        return true
    }

    /// Defines a global function.
    func defineGlobalFunc(atom: UInt32, val: JeffJSValue, flags: Int) -> Bool {
        return definePropertyValue(obj: globalObj, atom: atom, value: val,
                                   flags: flags | JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE) >= 0
    }

    /// Deletes a global variable.
    func deleteGlobalVar(atom: UInt32) -> Bool {
        return deleteProperty(obj: globalObj, atom: atom)
    }

    // MARK: - Property Access Stubs

    /// Gets a property using a dynamic key (string, number, or symbol).
    func getPropertyValue(obj: JeffJSValue, prop: JeffJSValue) -> JeffJSValue {
        if prop.isInt {
            return getPropertyUint32(obj: obj, index: UInt32(bitPattern: prop.toInt32()))
        }
        if prop.isString, let str = prop.stringValue {
            return getPropertyStr(obj: obj, name: str.toSwiftString())
        }
        if prop.isFloat64 {
            let d = prop.toFloat64()
            if d >= 0 && d <= Double(UInt32.max) {
                let u = UInt32(d)
                if Double(u) == d {
                    return getPropertyUint32(obj: obj, index: u)
                }
            }
            // Non-integer float key: convert to string
            let key = JeffJSTypeConvert.formatNumber(d)
            return getPropertyStr(obj: obj, name: key)
        }
        if prop.isSymbol {
            // For symbol keys, look up via the symbol's string description as atom.
            // Symbols are stored as mkPtr(tag: .symbol, ptr: JeffJSString).
            if let symStr = prop.toPtr() as? JeffJSString {
                let atomStr = symStr.toSwiftString()
                let atom = rt.findAtom(atomStr)
                let val = getProperty(obj: obj, atom: atom)
                rt.freeAtom(atom)
                return val
            }
        }
        // Fallback: convert to string
        let strVal = JeffJSTypeConvert.toString(ctx: self, val: prop)
        if strVal.isException { return .exception }
        if let str = strVal.stringValue {
            return getPropertyStr(obj: obj, name: str.toSwiftString())
        }
        return .undefined
    }

    /// Sets a property using a dynamic key (string, number, or symbol).
    func setPropertyValue(obj: JeffJSValue, prop: JeffJSValue, val: JeffJSValue) -> Bool {
        if prop.isInt {
            return setPropertyUint32(obj: obj, index: UInt32(bitPattern: prop.toInt32()),
                                     value: val) >= 0
        }
        if prop.isString, let str = prop.stringValue {
            let atom = rt.findAtom(str.toSwiftString())
            let result = setProperty(obj: obj, atom: atom, value: val) >= 0
            rt.freeAtom(atom)
            // Don't free atom — setProperty stores it in the shape.
            return result
        }
        if prop.isFloat64 {
            let d = prop.toFloat64()
            if d >= 0 && d <= Double(UInt32.max) {
                let u = UInt32(d)
                if Double(u) == d {
                    return setPropertyUint32(obj: obj, index: u, value: val) >= 0
                }
            }
            let key = JeffJSTypeConvert.formatNumber(d)
            let atom = rt.findAtom(key)
            let result = setProperty(obj: obj, atom: atom, value: val) >= 0
            rt.freeAtom(atom)
            // Don't free atom — setProperty stores it in the shape.
            return result
        }
        if prop.isSymbol {
            if let symStr = prop.toPtr() as? JeffJSString {
                let atomStr = symStr.toSwiftString()
                let atom = rt.findAtom(atomStr)
                let result = setProperty(obj: obj, atom: atom, value: val) >= 0
                rt.freeAtom(atom)
                // Don't free atom — setProperty stores it in the shape.
                return result
            }
        }
        // Fallback: convert to string
        let strVal = JeffJSTypeConvert.toString(ctx: self, val: prop)
        if strVal.isException { return false }
        if let str = strVal.stringValue {
            let atom = rt.findAtom(str.toSwiftString())
            let result = setProperty(obj: obj, atom: atom, value: val) >= 0
            rt.freeAtom(atom)
            // Don't free atom — setProperty stores it in the shape.
            return result
        }
        return false
    }

    /// Deletes a property using a dynamic key (string, number, or symbol).
    func deletePropertyValue(obj: JeffJSValue, key: JeffJSValue) -> Bool {
        if key.isString, let str = key.stringValue {
            let atom = rt.findAtom(str.toSwiftString())
            let result = deleteProperty(obj: obj, atom: atom)
            rt.freeAtom(atom)
            return result
        }
        if key.isInt {
            let atom = rt.newAtomUInt32(UInt32(bitPattern: key.toInt32()))
            let result = deleteProperty(obj: obj, atom: atom)
            rt.freeAtom(atom)
            return result
        }
        if key.isFloat64 {
            let k = JeffJSTypeConvert.formatNumber(key.toFloat64())
            let atom = rt.findAtom(k)
            let result = deleteProperty(obj: obj, atom: atom)
            rt.freeAtom(atom)
            return result
        }
        if key.isSymbol, let symStr = key.toPtr() as? JeffJSString {
            let atom = rt.findAtom(symStr.toSwiftString())
            let result = deleteProperty(obj: obj, atom: atom)
            rt.freeAtom(atom)
            return result
        }
        return false
    }

    /// Checks if an object has a property using a dynamic key.
    /// Handles string, int, float64, and symbol keys. For numeric string keys
    /// (e.g. "0", "1"), checks both the integer atom and string atom paths since
    /// arrays store elements with integer atoms but object literals may use string atoms.
    func hasPropertyValue(obj: JeffJSValue, key: JeffJSValue) -> Bool {
        if key.isString, let str = key.stringValue {
            let s = str.toSwiftString()
            // Check if the string represents an array index (e.g. "0", "1", ...)
            // Try the integer atom first (matches how arrays store elements),
            // then fall back to string atom (for object literals like {0: "a"}).
            if let idx = UInt32(s), String(idx) == s {
                let intAtom = rt.newAtomUInt32(idx)
                let intResult = hasProperty(obj: obj, atom: intAtom)
                rt.freeAtom(intAtom)
                if intResult { return true }
                // Fall through to check string atom too
            }
            let atom = rt.findAtom(s)
            let result = hasProperty(obj: obj, atom: atom)
            rt.freeAtom(atom)
            return result
        }
        if key.isInt {
            let atom = rt.newAtomUInt32(UInt32(bitPattern: key.toInt32()))
            let result = hasProperty(obj: obj, atom: atom)
            rt.freeAtom(atom)
            return result
        }
        if key.isFloat64 {
            let d = key.toFloat64()
            if d >= 0 && d <= Double(UInt32.max), Double(UInt32(d)) == d {
                let u = UInt32(d)
                let atom = rt.newAtomUInt32(u)
                let result = hasProperty(obj: obj, atom: atom)
                rt.freeAtom(atom)
                return result
            }
            // Non-integer float key: convert to string
            let k = JeffJSTypeConvert.formatNumber(d)
            let atom = rt.findAtom(k)
            let result = hasProperty(obj: obj, atom: atom)
            rt.freeAtom(atom)
            return result
        }
        if key.isSymbol, let symStr = key.toPtr() as? JeffJSString {
            let atom = rt.findAtom(symStr.toSwiftString())
            let result = hasProperty(obj: obj, atom: atom)
            rt.freeAtom(atom)
            return result
        }
        return false
    }

    // MARK: - Super Property Stubs

    /// Gets a property via the super binding.
    /// Per spec: reads from the super class's prototype (obj) but uses thisObj as receiver.
    func getSuperProperty(thisObj: JeffJSValue, obj: JeffJSValue, key: JeffJSValue) -> JeffJSValue {
        // Super property access reads from the super prototype chain.
        // The receiver (thisObj) is used for getter `this` binding.
        return getPropertyValue(obj: obj, prop: key)
    }

    /// Sets a property via the super binding.
    /// Per spec: writes to thisObj (the actual instance) not the super prototype.
    func putSuperProperty(thisObj: JeffJSValue, obj: JeffJSValue, key: JeffJSValue,
                          val: JeffJSValue) -> Bool {
        // Super property set writes to the receiver (thisObj), not the super prototype.
        return setPropertyValue(obj: thisObj, prop: key, val: val)
    }

    // MARK: - Object/Class Definition Stubs

    /// Defines a data property on an object.
    func defineField(obj: JeffJSValue, atom: UInt32, val: JeffJSValue) -> Bool {
        return definePropertyValue(obj: obj, atom: atom, value: val,
                                   flags: JS_PROP_C_W_E) >= 0
    }

    /// Sets the .name property on a function.
    func setFunctionName(_ funcVal: JeffJSValue, atom: UInt32) {
        if let name = rt.atomToString(atom) {
            let nameAtom = rt.findAtom("name")
            _ = setProperty(obj: funcVal, atom: nameAtom, value: newString(name))
            rt.freeAtom(nameAtom)
            // Don't free nameAtom — setProperty stores it in the shape.
        }
    }

    /// Sets the .name property on a function from a computed key.
    func setFunctionNameComputed(_ funcVal: JeffJSValue, key: JeffJSValue) {
        if key.isString, let str = key.stringValue {
            let nameAtom = rt.findAtom("name")
            _ = setProperty(obj: funcVal, atom: nameAtom, value: newString(str.toSwiftString()))
            rt.freeAtom(nameAtom)
            // Don't free nameAtom — setProperty stores it in the shape.
        }
    }

    /// Sets the [[Prototype]] of an object.
    func setPrototypeOf(obj: JeffJSValue, proto: JeffJSValue) -> Bool {
        guard let jsObj = obj.toObject() else { return false }
        let protoObj: JeffJSObject?
        if proto.isObject {
            protoObj = proto.toObject()
        } else if proto.isNull {
            protoObj = nil
        } else {
            return true
        }
        // obj.proto is the single source of truth; its setter auto-syncs shape.proto.
        jsObj.proto = protoObj
        return true
    }

    /// Sets the [[HomeObject]] internal slot on a method function.
    /// Required for `super` property access in methods to work correctly.
    func setHomeObject(funcVal: JeffJSValue, homeObj: JeffJSValue) {
        guard let funcObj = funcVal.toObject() else { return }
        // Update the payload to include the home object reference
        if case .bytecodeFunc(let fb, let varRefs, _) = funcObj.payload {
            funcObj.payload = .bytecodeFunc(functionBytecode: fb, varRefs: varRefs,
                                             homeObject: homeObj.toObject())
        }
    }

    /// Defines an array element and returns the next index.
    func defineArrayElement(obj: JeffJSValue, idx: JeffJSValue, val: JeffJSValue) -> JeffJSValue {
        if idx.isInt {
            let i = UInt32(bitPattern: idx.toInt32())
            _ = setPropertyUint32(obj: obj, index: i, value: val)
            let nextIdx = i + 1
            // Keep .length in sync: if we wrote past current length, update it
            let curLen = getArrayLength(obj)
            if Int64(nextIdx) > curLen {
                setArrayLength(obj, Int64(nextIdx))
            }
            return .newUInt32(nextIdx)
        }
        return .newInt32(0)
    }

    /// Appends a value to an array.
    func appendToArray(obj: JeffJSValue, val: JeffJSValue) {
        let lenVal = getPropertyStr(obj: obj, name: "length")
        let len: UInt32
        if lenVal.isInt { len = UInt32(bitPattern: lenVal.toInt32()) }
        else { len = 0 }
        _ = setPropertyUint32(obj: obj, index: len, value: val)
        // Update length after appending
        setArrayLength(obj, Int64(len) + 1)
    }

    /// Copies data properties from source to target (CopyDataProperties per spec).
    /// Used by object spread (`{...source}`) and Object.assign-like operations.
    func copyDataProperties(target: JeffJSValue, source: JeffJSValue,
                            excludeList: JeffJSValue) -> Bool {
        // If source is null or undefined, return success (no properties to copy)
        if source.isNull || source.isUndefined { return true }
        guard let srcObj = source.toObject() else { return true }
        guard let shape = srcObj.shape else { return true }

        // Collect excluded property atoms
        var excludedAtoms = Set<UInt32>()
        if excludeList.isObject {
            if let exclObj = excludeList.toObject(), let exclShape = exclObj.shape {
                for prop in exclShape.prop {
                    excludedAtoms.insert(prop.atom)
                }
            }
        }

        // Copy each enumerable own property from source to target
        for (i, shapeProp) in shape.prop.enumerated() {
            let atom = shapeProp.atom
            if atom == 0 { continue } // skip empty slots
            if excludedAtoms.contains(atom) { continue }
            // Only copy enumerable properties
            if !shapeProp.flags.contains(.enumerable) { continue }
            guard i < srcObj.prop.count else { continue }
            let propEntry = srcObj.prop[i]
            if case .value(let val) = propEntry {
                _ = setProperty(obj: target, atom: atom, value: val.dupValue())
            }
        }
        return true
    }

    /// Defines a method on an object.
    /// Flags: 0 = normal method, 2 = getter, 4 = setter.
    func defineMethod(obj: JeffJSValue, atom: UInt32, funcVal: JeffJSValue,
                      flags: Int) -> Bool {
        let isGetter = (flags & 2) != 0
        let isSetter = (flags & 4) != 0
        if isGetter || isSetter {
            return defineProperty(obj: obj, atom: atom, value: .JS_UNDEFINED,
                                  getter: isGetter ? funcVal : .JS_UNDEFINED,
                                  setter: isSetter ? funcVal : .JS_UNDEFINED,
                                  flags: JS_PROP_C_W_E | JS_PROP_GETSET | (isGetter ? JS_PROP_HAS_GET : 0) | (isSetter ? JS_PROP_HAS_SET : 0)) >= 0
        }
        return definePropertyValue(obj: obj, atom: atom, value: funcVal,
                                   flags: JS_PROP_C_W_E) >= 0
    }

    /// Defines a method with a computed key.
    /// Flags: 0 = normal method, 2 = getter, 4 = setter.
    func defineMethodComputed(obj: JeffJSValue, key: JeffJSValue, funcVal: JeffJSValue,
                              flags: Int) -> Bool {
        let isGetter = (flags & 2) != 0
        let isSetter = (flags & 4) != 0
        if key.isString, let str = key.stringValue {
            let atom = rt.findAtom(str.toSwiftString())
            let result: Bool
            if isGetter || isSetter {
                result = defineProperty(obj: obj, atom: atom, value: .JS_UNDEFINED,
                                        getter: isGetter ? funcVal : .JS_UNDEFINED,
                                        setter: isSetter ? funcVal : .JS_UNDEFINED,
                                        flags: JS_PROP_C_W_E | JS_PROP_GETSET | (isGetter ? JS_PROP_HAS_GET : 0) | (isSetter ? JS_PROP_HAS_SET : 0)) >= 0
            } else {
                result = definePropertyValue(obj: obj, atom: atom, value: funcVal,
                                              flags: JS_PROP_C_W_E) >= 0
            }
            // Don't free atom — defineProperty/definePropertyValue stores it in the shape.
            return result
        }
        if key.isSymbol, let symStr = key.toPtr() as? JeffJSString {
            let atomStr = symStr.toSwiftString()
            let atom = rt.findAtom(atomStr)
            let result: Bool
            if isGetter || isSetter {
                result = defineProperty(obj: obj, atom: atom, value: .JS_UNDEFINED,
                                        getter: isGetter ? funcVal : .JS_UNDEFINED,
                                        setter: isSetter ? funcVal : .JS_UNDEFINED,
                                        flags: JS_PROP_C_W_E | JS_PROP_GETSET | (isGetter ? JS_PROP_HAS_GET : 0) | (isSetter ? JS_PROP_HAS_SET : 0)) >= 0
            } else {
                result = definePropertyValue(obj: obj, atom: atom, value: funcVal,
                                              flags: JS_PROP_C_W_E) >= 0
            }
            // Don't free atom — defineProperty/definePropertyValue stores it in the shape.
            return result
        }
        return false
    }

    /// Defines a class (returns constructor and prototype).
    func defineClass(atom: UInt32, flags: Int, heritage: JeffJSValue,
                     ctorFunc: JeffJSValue) -> (JeffJSValue, JeffJSValue) {
        let proto: JeffJSValue
        let ctor = ctorFunc

        if heritage.isNull {
            // class Foo { } with no extends -- prototype is a plain object with null proto
            proto = newObjectProto(proto: .null)
        } else if heritage.isUndefined {
            // No heritage specified -- prototype inherits from Object.prototype
            proto = newObject()
        } else {
            // class Foo extends Bar -- prototype inherits from Bar.prototype
            let parentProto = getProperty(obj: heritage,
                                           atom: JeffJSAtomID.JS_ATOM_prototype.rawValue)
            if parentProto.isObject || parentProto.isNull {
                proto = newObjectProto(proto: parentProto)
            } else {
                proto = newObject()
            }
        }

        // Set constructor.prototype = proto
        _ = setProperty(obj: ctor, atom: JeffJSAtomID.JS_ATOM_prototype.rawValue,
                        value: proto.dupValue())
        // Set proto.constructor = ctor
        _ = setProperty(obj: proto, atom: JeffJSAtomID.JS_ATOM_constructor.rawValue,
                        value: ctor.dupValue())
        // Set the constructor's name
        if atom != 0 {
            setFunctionName(ctor, atom: atom)
        }

        return (ctor, proto)
    }

    /// Defines a class with a computed name.
    func defineClassComputed(key: JeffJSValue, flags: Int, heritage: JeffJSValue,
                             ctorFunc: JeffJSValue) -> (JeffJSValue, JeffJSValue) {
        // Use defineClass with atom=0, then set computed name
        let (ctor, proto) = defineClass(atom: 0, flags: flags, heritage: heritage,
                                         ctorFunc: ctorFunc)
        if ctor.isException { return (ctor, proto) }
        // Set the computed name on the constructor
        setFunctionNameComputed(ctor, key: key)
        return (ctor, proto)
    }

    // MARK: - Scope / Lexical Stubs

    /// Closes a lexical variable (detaches its var-ref from the stack frame).
    /// When a closure captures a local variable and that variable goes out of scope,
    /// the var-ref must be "detached" so the closure keeps its own copy of the value
    /// rather than pointing at the (now-dead) stack slot.
    ///
    /// Walks `frame.liveVarRefs` and detaches every var-ref that points at the
    /// given local variable index.  The current value is copied into the
    /// var-ref's own `value` storage so the closure keeps working after the
    /// parent frame is gone.
    func closeLexicalVar(frame: JeffJSStackFrame, idx: Int) {
        guard idx < frame.varBuf.count else { return }
        let val = frame.varBuf[idx]
        // Detach every live var-ref that targets this local slot.
        for vr in frame.liveVarRefs {
            if !vr.isDetached && !vr.isArg && Int(vr.varIdx) == idx {
                vr.value = val.dupValue()
                vr.isDetached = true
                vr.parentFrame = nil
            }
        }
    }

    /// Converts a value to a property key (string or symbol).
    /// Per ECMAScript ToPropertyKey: if the value is a symbol, return it;
    /// otherwise convert to string via ToString (which calls ToPrimitive for objects).
    func toPropertyKey(_ val: JeffJSValue) -> JeffJSValue {
        if val.isString || val.isSymbol { return val.dupValue() }
        if val.isInt { return newString(String(val.toInt32())) }
        if val.isFloat64 { return newString(JeffJSTypeConvert.formatNumber(val.toFloat64())) }
        if val.isBool { return newString(val.toBool() ? "true" : "false") }
        if val.isNull { return newString("null") }
        if val.isUndefined { return newString("undefined") }
        // For objects, ToPrimitive(hint string) then ToString
        return JeffJSTypeConvert.toString(ctx: self, val: val)
    }

    // MARK: - Reference Construction Stubs

    /// Creates a local variable reference object.
    /// Used by `with` statements and ref-based variable access to create a
    /// first-class reference to a local variable slot.
    func makeLocalRef(frame: JeffJSStackFrame, idx: Int) -> JeffJSObject {
        let vr = JeffJSVarRef(isDetached: false, isArg: false, varIdx: UInt16(idx),
                              parentFrame: frame)
        let obj = JeffJSObject()
        obj.payload = .opaque(vr)
        return obj
    }

    /// Creates an argument reference object.
    /// Similar to makeLocalRef but for argument slots.
    func makeArgRef(frame: JeffJSStackFrame, idx: Int) -> JeffJSObject {
        let vr = JeffJSVarRef(isDetached: false, isArg: true, varIdx: UInt16(idx),
                              parentFrame: frame)
        let obj = JeffJSObject()
        obj.payload = .opaque(vr)
        return obj
    }

    /// Creates a global variable reference.
    func makeGlobalVarRef(atom: UInt32) -> (JeffJSValue, JeffJSValue) {
        return (globalObj.dupValue(), atomToString(atom))
    }

    // MARK: - Iterator Stubs

    /// Creates a for-in iterator.
    /// Collects all enumerable string-keyed properties from the object and its
    /// prototype chain, then wraps them in an iterator object.
    func createForInIterator(obj: JeffJSValue) -> JeffJSValue {
        // For null/undefined, return an empty iterator
        if obj.isNull || obj.isUndefined {
            let iter = newObject()
            // Store empty keys array and index 0 in the iterator
            _ = setPropertyStr(obj: iter, name: "__forInKeys__",
                               value: newArrayFrom([]))
            _ = setPropertyStr(obj: iter, name: "__forInIdx__", value: .newInt32(0))
            return iter
        }
        // Collect all enumerable string-keyed properties from obj and its prototype chain.
        // Per ES spec §9.1.12, integer indices come first (ascending), then string keys
        // (insertion order). Each prototype level follows the same ordering.
        var keys = [JeffJSValue]()
        var seen = Set<String>()
        var current: JeffJSObject? = obj.toObject()
        while let cur = current {
            var intKeys: [(UInt32, String)] = []
            var strKeys: [String] = []
            if let shape = cur.shape {
                for prop in shape.prop {
                    let atom = prop.atom
                    if atom == 0 { continue }
                    let isEnumerable = prop.flags.contains(.enumerable)
                    // Non-enumerable own properties must shadow enumerable
                    // prototype properties (ES spec §14.7.5.9), so add all
                    // property names to `seen` but only collect enumerable ones.
                    if rt.atomIsArrayIndex(atom) {
                        if let idx = rt.atomToUInt32(atom) {
                            let name = String(idx)
                            if isEnumerable { intKeys.append((idx, name)) }
                            else { seen.insert(name) }
                        }
                    } else if let name = rt.atomToString(atom) {
                        if isEnumerable { strKeys.append(name) }
                        else { seen.insert(name) }
                    }
                }
            }
            intKeys.sort { $0.0 < $1.0 }
            for (_, name) in intKeys {
                if !seen.contains(name) {
                    seen.insert(name)
                    keys.append(newString(name))
                }
            }
            for name in strKeys {
                if !seen.contains(name) {
                    seen.insert(name)
                    keys.append(newString(name))
                }
            }
            current = cur.proto
        }
        let iter = newObject()
        _ = setPropertyStr(obj: iter, name: "__forInKeys__", value: newArrayFrom(keys))
        _ = setPropertyStr(obj: iter, name: "__forInIdx__", value: .newInt32(0))
        return iter
    }

    /// Gets an iterator from an iterable by calling its [Symbol.iterator]
    /// or [Symbol.asyncIterator] method.
    func getIterator(obj: JeffJSValue, isAsync: Bool) -> JeffJSValue {
        let symAtom: UInt32
        if isAsync {
            symAtom = JeffJSAtomID.JS_ATOM_Symbol_asyncIterator.rawValue
        } else {
            symAtom = JeffJSAtomID.JS_ATOM_Symbol_iterator.rawValue
        }
        // Try to get the iterator method via the well-known symbol atom
        let iterMethod = getProperty(obj: obj, atom: symAtom)
        if !iterMethod.isUndefined && !iterMethod.isNull {
            // Call the iterator method
            let iter = callFunction(iterMethod, thisVal: obj, args: [])
            if iter.isException { return .exception }
            if !iter.isObject {
                _ = throwTypeError(message: "iterator must return an object")
                return .exception
            }
            return iter
        }

        // Symbol.iterator not found. Try async fallback first.
        if isAsync {
            let syncMethod = getProperty(obj: obj,
                                          atom: JeffJSAtomID.JS_ATOM_Symbol_iterator.rawValue)
            if !syncMethod.isUndefined && !syncMethod.isNull {
                let syncIter = callFunction(syncMethod, thisVal: obj, args: [])
                if syncIter.isException { return .exception }
                return syncIter
            }
        }

        // Built-in iterable fallbacks for types whose [Symbol.iterator] may
        // have been registered under a string key (e.g. "[Symbol.iterator]")
        // rather than the actual symbol atom, or not at all.

        // String primitive: iterate over Unicode code points
        if obj.isString, !isAsync {
            return createStringIterator(obj: obj)
        }

        // Array / array-like: create an array values iterator
        if !isAsync, let jsObj = obj.toObject(),
           (jsObj.classID == JeffJSClassID.array.rawValue ||
            jsObj.classID == JSClassID.JS_CLASS_ARRAY.rawValue) {
            return createArrayIterator(obj: obj, kind: 1) // 1 = values
        }

        _ = throwTypeError(message: isAsync
            ? "object is not async iterable"
            : "object is not iterable")
        return .exception
    }

    /// Creates a string character iterator.
    /// Iterates over the Unicode code points of the string, returning
    /// one character per call to .next().
    func createStringIterator(obj: JeffJSValue) -> JeffJSValue {
        guard let str = obj.stringValue?.toSwiftString() ?? toSwiftString(obj) else {
            return createArrayIterator(obj: newArrayFrom([]), kind: 1)
        }
        // Build an array of single-character strings, then wrap in an array iterator
        var chars = [JeffJSValue]()
        for ch in str {
            chars.append(newStringValue(String(ch)))
        }
        let charArr = newArrayFrom(chars)
        return createArrayIterator(obj: charArr, kind: 1) // 1 = values
    }

    /// Gets the next value from a for-in iterator.
    /// Returns (nextKey, done). When done is true, iteration is complete.
    func forInNext(iter: JeffJSValue) -> (JeffJSValue, Bool) {
        let keysArr = getPropertyStr(obj: iter, name: "__forInKeys__")
        let idxVal = getPropertyStr(obj: iter, name: "__forInIdx__")
        let idx = idxVal.isInt ? Int(idxVal.toInt32()) : 0
        let lenVal = getPropertyStr(obj: keysArr, name: "length")
        let len = lenVal.isInt ? Int(lenVal.toInt32()) : 0
        if idx >= len {
            return (.undefined, true)
        }
        let key = getPropertyUint32(obj: keysArr, index: UInt32(idx))
        // Advance the index
        _ = setPropertyStr(obj: iter, name: "__forInIdx__", value: .newInt32(Int32(idx + 1)))
        return (key, false)
    }

    /// Gets the next value from an iterator.
    func iteratorNext(iter: JeffJSValue) -> JeffJSValue {
        let nextFn = getPropertyStr(obj: iter, name: "next")
        if nextFn.isFunction {
            return callFunction(nextFn, thisVal: iter, args: [])
        }
        return .undefined
    }

    /// Checks if an iterator result is done.
    func iteratorCheckDone(result: JeffJSValue) -> Bool {
        let done = getPropertyStr(obj: result, name: "done")
        return JeffJSTypeConvert.toBool(done)
    }

    /// Gets the value from an iterator result.
    func iteratorGetValue(result: JeffJSValue) -> JeffJSValue {
        return getPropertyStr(obj: result, name: "value")
    }

    /// Closes an iterator.
    func iteratorClose(iter: JeffJSValue, isThrow: Bool) {
        let returnFn = getPropertyStr(obj: iter, name: "return")
        if returnFn.isFunction {
            _ = callFunction(returnFn, thisVal: iter, args: [])
        }
    }

    /// Calls a specific method on an iterator.
    func iteratorCallMethod(iter: JeffJSValue, method: Int) -> JeffJSValue {
        // method: 0=next, 1=return, 2=throw
        let methodName: String
        switch method {
        case 1: methodName = "return"
        case 2: methodName = "throw"
        default: methodName = "next"
        }
        let fn = getPropertyStr(obj: iter, name: methodName)
        if fn.isFunction {
            return callFunction(fn, thisVal: iter, args: [])
        }
        return .undefined
    }

    // MARK: - Interrupt Check

    /// Checks if execution should be interrupted.
    func checkInterrupt() -> Bool {
        if let handler = rt.interruptHandler {
            return handler(rt)
        }
        return false
    }

    // MARK: - Math Builtin Fixup

    /// One-time fixup for Math builtins that may be missing or incorrect after
    /// context initialization.  The Phase 1 inline Math setup in
    /// JeffJSContext.addIntrinsicBaseObjects() creates a Math object but omits
    /// some methods (e.g. clz32) and has a precedence bug in Math.random().
    /// Phase 3 (jeffJS_initMath) tries to overwrite Math but fails because
    /// jeffJS_setPropertyStr does not update an already-existing property.
    /// This fixup patches the existing Math object in-place.
    func ensureMathFixup() {
        guard !mathFixupApplied else { return }
        mathFixupApplied = true

        // Find the existing Math object on the global.
        let mathVal = getPropertyStr(obj: globalObj, name: "Math")
        guard mathVal.toObject() != nil else { return }

        // -- Fix Math.clz32 --
        // Count Leading Zeros of the 32-bit integer representation.
        let clz32Fn = newCFunction({ ctx, thisVal, args in
            // ToInt32 conversion: extract int32 from the first argument.
            let n: Int32
            if let first = args.first {
                if first.isInt {
                    n = first.toInt32()
                } else if first.isFloat64 {
                    let d = first.toFloat64()
                    n = JeffJSTypeConvert.doubleToInt32(d)
                } else {
                    n = 0
                }
            } else {
                n = 0
            }
            let u = UInt32(bitPattern: n)
            return .newInt32(Int32(u == 0 ? 32 : u.leadingZeroBitCount))
        }, name: "clz32", length: 1)
        _ = setPropertyStr(obj: mathVal, name: "clz32", value: clz32Fn)

        // -- Fix Math.random --
        // The Phase 1 xorshift64* implementation has a Swift operator-precedence
        // bug: `x &* C >> 11` parses as `x &* (C >> 11)` instead of
        // `(x &* C) >> 11`, producing values outside [0, 1).
        // Replace with a correct implementation.
        let randomFn = newCFunction({ [weak self] ctx, thisVal, args in
            guard let self = self else { return .newFloat64(0) }
            var x = self.randomState
            x ^= x >> 12
            x ^= x << 25
            x ^= x >> 27
            self.randomState = x
            let product = x &* 0x2545F4914F6CDD1D
            let shifted = product >> 11
            let result = Double(shifted) / Double(UInt64(1) << 53)
            return .newFloat64(result)
        }, name: "random", length: 0)
        _ = setPropertyStr(obj: mathVal, name: "random", value: randomFn)
    }
}

// =============================================================================
// MARK: - Bytecode Reading Helpers
// =============================================================================

/// Read a UInt8 from bytecode at the given offset.
@inline(__always)
private func readU8(_ bc: [UInt8], _ pos: Int) -> UInt8 {
    guard pos < bc.count else { return 0 }
    return bc[pos]
}

/// Read a signed Int8 from bytecode.
@inline(__always)
private func readI8(_ bc: [UInt8], _ pos: Int) -> Int8 {
    return Int8(bitPattern: readU8(bc, pos))
}

/// Read a little-endian UInt16 from bytecode.
@inline(__always)
private func readU16(_ bc: [UInt8], _ pos: Int) -> UInt16 {
    guard pos + 1 < bc.count else { return 0 }
    return UInt16(bc[pos]) | (UInt16(bc[pos + 1]) << 8)
}

/// Read a little-endian Int16 from bytecode.
@inline(__always)
private func readI16(_ bc: [UInt8], _ pos: Int) -> Int16 {
    return Int16(bitPattern: readU16(bc, pos))
}

/// Read a little-endian UInt32 from bytecode.
@inline(__always)
private func readU32(_ bc: [UInt8], _ pos: Int) -> UInt32 {
    guard pos + 3 < bc.count else { return 0 }
    return UInt32(bc[pos]) |
           (UInt32(bc[pos + 1]) << 8) |
           (UInt32(bc[pos + 2]) << 16) |
           (UInt32(bc[pos + 3]) << 24)
}

/// Read a little-endian Int32 from bytecode.
@inline(__always)
private func readI32(_ bc: [UInt8], _ pos: Int) -> Int32 {
    return Int32(bitPattern: readU32(bc, pos))
}

/// Check if the opcode byte at `pos` in the bytecode is a "store variable"
/// opcode that pops a value from the stack.  Used to detect chained
/// assignment patterns (e.g., `a = b = c = 5`) where intermediate stores
/// must keep the value on the stack for the next store.
@inline(__always)
private func isStoreOpcode(_ bc: [UInt8], _ pos: Int, _ bcLen: Int) -> Bool {
    guard pos < bcLen, pos < bc.count else { return false }
    let b = bc[pos]
    // put_loc (3 bytes), put_loc0..3 (1 byte each), put_loc8 (2 bytes),
    // put_var (5 bytes), put_arg (3 bytes), put_arg0..3 (1 byte each),
    // put_var_ref (3 bytes)
    guard let op = JeffJSOpcode(rawValue: UInt16(b)) else { return false }
    switch op {
    case .put_loc, .put_loc0, .put_loc1, .put_loc2, .put_loc3, .put_loc8,
         .put_var,
         .put_arg, .put_arg0, .put_arg1, .put_arg2, .put_arg3,
         .put_var_ref,
         .put_field, .put_array_el:
        return true
    default:
        return false
    }
}

// =============================================================================
// MARK: - Fast Trace Mini-Interpreter
// =============================================================================

/// Fast mini-interpreter for hot loop traces.
/// Executes bytecode[entryPC..<exitPC] in a tight loop with only ~30 opcodes.
/// Returns the PC to resume at in the main interpreter:
///   - On loop exit (condition became false): returns the branch target (after loop)
///   - On deopt (unsupported opcode or non-int type): returns the PC to resume at
///   - On interrupt/exception: returns -1 (caller should set retVal = .exception)
@inline(never)
private func executeFastTrace(
    bc: [UInt8],
    bcLen: Int,
    entryPC: Int,
    exitPC: Int,
    buf: UnsafeMutablePointer<JeffJSValue>,
    varBase: Int,
    sp: inout Int,
    ctx: JeffJSContext,
    cpool: [JeffJSValue],
    stackLimit: Int
) -> Int {
    // Validate parameters
    guard entryPC >= 0, exitPC <= bc.count, entryPC < exitPC,
          sp >= 0, sp < stackLimit, stackLimit > 0 else {
        return entryPC
    }
    var pc = entryPC

    traceLoop: while pc >= entryPC && pc < exitPC {
        // Guard against stack overflow/underflow
        if sp >= stackLimit - 8 || sp < 0 { return pc }
        guard let op = JeffJSOpcode(rawValue: UInt16(bc[pc])) else {
            return pc // deopt: unknown opcode byte
        }

        switch op {

        // =================================================================
        // Push values
        // =================================================================

        case .push_i32:
            let val = readI32(bc, pc + 1)
            buf[sp] = .newInt32(val); sp += 1
            pc += 5

        case .push_0:  buf[sp] = .newInt32(0); sp += 1; pc += 1
        case .push_1:  buf[sp] = .newInt32(1); sp += 1; pc += 1
        case .push_minus1: buf[sp] = .newInt32(-1); sp += 1; pc += 1
        case .push_2:  buf[sp] = .newInt32(2); sp += 1; pc += 1
        case .push_3:  buf[sp] = .newInt32(3); sp += 1; pc += 1
        case .push_4:  buf[sp] = .newInt32(4); sp += 1; pc += 1
        case .push_5:  buf[sp] = .newInt32(5); sp += 1; pc += 1
        case .push_6:  buf[sp] = .newInt32(6); sp += 1; pc += 1
        case .push_7:  buf[sp] = .newInt32(7); sp += 1; pc += 1

        case .push_i8:
            let val = Int32(readI8(bc, pc + 1))
            buf[sp] = .newInt32(val); sp += 1
            pc += 2

        case .push_i16:
            let val = Int32(readI16(bc, pc + 1))
            buf[sp] = .newInt32(val); sp += 1
            pc += 3

        case .push_const:
            let idx = Int(readU32(bc, pc + 1))
            if idx < cpool.count {
                buf[sp] = cpool[idx].dupValue()
            } else {
                buf[sp] = .undefined
            }
            sp += 1
            pc += 5

        case .push_true:  buf[sp] = .JS_TRUE; sp += 1; pc += 1
        case .push_false: buf[sp] = .JS_FALSE; sp += 1; pc += 1
        case .push_null:  buf[sp] = .null; sp += 1; pc += 1
        case .undefined:  buf[sp] = .undefined; sp += 1; pc += 1

        // =================================================================
        // Local access (varBase-relative)
        // =================================================================

        case .get_loc0: buf[sp] = buf[varBase].dupValue(); sp += 1; pc += 1
        case .get_loc1: buf[sp] = buf[varBase + 1].dupValue(); sp += 1; pc += 1
        case .get_loc2: buf[sp] = buf[varBase + 2].dupValue(); sp += 1; pc += 1
        case .get_loc3: buf[sp] = buf[varBase + 3].dupValue(); sp += 1; pc += 1

        case .get_loc8:
            let idx = Int(bc[pc + 1])
            buf[sp] = buf[varBase + idx].dupValue(); sp += 1
            pc += 2

        case .get_loc:
            let idx = Int(readU16(bc, pc + 1))
            buf[sp] = buf[varBase + idx].dupValue(); sp += 1
            pc += 3

        case .put_loc0: sp -= 1; buf[varBase] = buf[sp]; pc += 1
        case .put_loc1: sp -= 1; buf[varBase + 1] = buf[sp]; pc += 1
        case .put_loc2: sp -= 1; buf[varBase + 2] = buf[sp]; pc += 1
        case .put_loc3: sp -= 1; buf[varBase + 3] = buf[sp]; pc += 1

        case .put_loc8:
            let idx = Int(bc[pc + 1])
            sp -= 1; buf[varBase + idx] = buf[sp]
            pc += 2

        case .put_loc:
            let idx = Int(readU16(bc, pc + 1))
            sp -= 1; buf[varBase + idx] = buf[sp]
            pc += 3

        case .set_loc0: buf[varBase] = buf[sp - 1]; pc += 1
        case .set_loc1: buf[varBase + 1] = buf[sp - 1]; pc += 1
        case .set_loc2: buf[varBase + 2] = buf[sp - 1]; pc += 1
        case .set_loc3: buf[varBase + 3] = buf[sp - 1]; pc += 1

        case .set_loc8:
            let idx = Int(bc[pc + 1])
            buf[varBase + idx] = buf[sp - 1]
            pc += 2

        case .set_loc:
            let idx = Int(readU16(bc, pc + 1))
            buf[varBase + idx] = buf[sp - 1]
            pc += 3

        case .get_loc_check:
            let idx = Int(readU16(bc, pc + 1))
            let val = buf[varBase + idx]
            if val.isUninitialized { return pc } // deopt: TDZ
            buf[sp] = val.dupValue(); sp += 1
            pc += 3

        // =================================================================
        // Argument access
        // =================================================================

        case .get_arg0: buf[sp] = buf[0].dupValue(); sp += 1; pc += 1
        case .get_arg1: buf[sp] = buf[1].dupValue(); sp += 1; pc += 1
        case .get_arg2: buf[sp] = buf[2].dupValue(); sp += 1; pc += 1
        case .get_arg3: buf[sp] = buf[3].dupValue(); sp += 1; pc += 1

        case .get_arg:
            let idx = Int(readU16(bc, pc + 1))
            buf[sp] = buf[idx].dupValue(); sp += 1
            pc += 3

        // =================================================================
        // Stack manipulation
        // =================================================================

        case .dup:
            buf[sp] = buf[sp - 1].dupValue(); sp += 1
            pc += 1

        case .drop:
            sp -= 1
            pc += 1

        case .nip:
            buf[sp - 2] = buf[sp - 1]; sp -= 1
            pc += 1

        case .nip1:
            buf[sp - 3] = buf[sp - 2]; buf[sp - 2] = buf[sp - 1]; sp -= 1
            pc += 1

        case .swap:
            let tmp = buf[sp - 1]; buf[sp - 1] = buf[sp - 2]; buf[sp - 2] = tmp
            pc += 1

        // =================================================================
        // Arithmetic (inline int fast paths)
        // =================================================================

        case .add:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                let a = lhs.toInt32(), b = rhs.toInt32()
                let (r, overflow) = a.addingReportingOverflow(b)
                sp -= 1
                buf[sp - 1] = overflow ? .newFloat64(Double(a) + Double(b)) : .newInt32(r)
                pc += 1
            } else {
                return pc // deopt: non-int add (strings, objects, etc.)
            }

        case .sub:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                let (r, overflow) = lhs.toInt32().subtractingReportingOverflow(rhs.toInt32())
                sp -= 1
                buf[sp - 1] = overflow ? .newFloat64(Double(lhs.toInt32()) - Double(rhs.toInt32())) : .newInt32(r)
                pc += 1
            } else {
                return pc // deopt
            }

        case .mul:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                let a = Int64(lhs.toInt32()), b = Int64(rhs.toInt32())
                let r = a * b
                sp -= 1
                if r >= Int64(Int32.min) && r <= Int64(Int32.max) && !(r == 0 && (a < 0 || b < 0)) {
                    buf[sp - 1] = .newInt32(Int32(r))
                } else {
                    buf[sp - 1] = .newFloat64(Double(a) * Double(b))
                }
                pc += 1
            } else {
                return pc // deopt
            }

        case .div:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                let a = lhs.toInt32(), b = rhs.toInt32()
                if b == 0 || (a == Int32.min && b == -1) {
                    return pc // deopt: div by zero or overflow
                }
                let r = a / b
                sp -= 1
                if r * b == a && !(r == 0 && a < 0) {
                    buf[sp - 1] = .newInt32(r)
                } else {
                    buf[sp - 1] = .newFloat64(Double(a) / Double(b))
                }
                pc += 1
            } else {
                return pc // deopt
            }

        case .mod:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                let a = lhs.toInt32(), b = rhs.toInt32()
                if b == 0 || (a == Int32.min && b == -1) {
                    return pc // deopt
                }
                let r = a % b
                sp -= 1
                if r != 0 || a >= 0 {
                    buf[sp - 1] = .newInt32(r)
                } else {
                    buf[sp - 1] = .newFloat64(Double(a).truncatingRemainder(dividingBy: Double(b)))
                }
                pc += 1
            } else {
                return pc // deopt
            }

        case .neg:
            let val = buf[sp - 1]
            if val.isInt {
                let v = val.toInt32()
                if v == 0 || v == Int32.min { return pc } // deopt: -0 or overflow
                buf[sp - 1] = .newInt32(-v)
                pc += 1
            } else {
                return pc // deopt
            }

        case .inc:
            let val = buf[sp - 1]
            if val.isInt {
                let v = val.toInt32()
                if v == Int32.max {
                    buf[sp - 1] = .newFloat64(Double(v) + 1)
                } else {
                    buf[sp - 1] = .newInt32(v + 1)
                }
                pc += 1
            } else {
                return pc // deopt
            }

        case .dec:
            let val = buf[sp - 1]
            if val.isInt {
                let v = val.toInt32()
                if v == Int32.min {
                    buf[sp - 1] = .newFloat64(Double(v) - 1)
                } else {
                    buf[sp - 1] = .newInt32(v - 1)
                }
                pc += 1
            } else {
                return pc // deopt
            }

        case .post_inc:
            let val = buf[sp - 1]
            if val.isInt {
                let v = val.toInt32()
                // original stays at sp-1, push incremented
                if v == Int32.max {
                    buf[sp] = .newFloat64(Double(v) + 1)
                } else {
                    buf[sp] = .newInt32(v + 1)
                }
                sp += 1
                pc += 1
            } else {
                return pc // deopt
            }

        case .post_dec:
            let val = buf[sp - 1]
            if val.isInt {
                let v = val.toInt32()
                if v == Int32.min {
                    buf[sp] = .newFloat64(Double(v) - 1)
                } else {
                    buf[sp] = .newInt32(v - 1)
                }
                sp += 1
                pc += 1
            } else {
                return pc // deopt
            }

        case .plus:
            let val = buf[sp - 1]
            if val.isInt {
                pc += 1 // int stays as-is
            } else {
                return pc // deopt
            }

        // =================================================================
        // Comparison (inline int fast paths)
        // =================================================================

        case .lt:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = lhs.toInt32() < rhs.toInt32() ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { return pc }

        case .lte:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = lhs.toInt32() <= rhs.toInt32() ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { return pc }

        case .gt:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = lhs.toInt32() > rhs.toInt32() ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { return pc }

        case .gte:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = lhs.toInt32() >= rhs.toInt32() ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { return pc }

        case .eq:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = lhs.toInt32() == rhs.toInt32() ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { return pc }

        case .neq:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = lhs.toInt32() != rhs.toInt32() ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { return pc }

        case .strict_eq:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = lhs.toInt32() == rhs.toInt32() ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { return pc }

        case .strict_neq:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = lhs.toInt32() != rhs.toInt32() ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { return pc }

        // =================================================================
        // Bitwise (inline int fast paths)
        // =================================================================

        case .shl:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = .newInt32(lhs.toInt32() << (rhs.toInt32() & 0x1F))
                pc += 1
            } else { return pc }

        case .sar:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = .newInt32(lhs.toInt32() >> (rhs.toInt32() & 0x1F))
                pc += 1
            } else { return pc }

        case .shr:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                let ua = UInt32(bitPattern: lhs.toInt32())
                let result = ua >> (UInt32(rhs.toInt32() & 0x1F))
                sp -= 1
                buf[sp - 1] = .newUInt32(result)
                pc += 1
            } else { return pc }

        case .and:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = .newInt32(lhs.toInt32() & rhs.toInt32())
                pc += 1
            } else { return pc }

        case .or:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = .newInt32(lhs.toInt32() | rhs.toInt32())
                pc += 1
            } else { return pc }

        case .xor:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = .newInt32(lhs.toInt32() ^ rhs.toInt32())
                pc += 1
            } else { return pc }

        case .not:
            let val = buf[sp - 1]
            if val.isInt {
                buf[sp - 1] = .newInt32(~val.toInt32())
                pc += 1
            } else { return pc }

        // =================================================================
        // Boolean / type
        // =================================================================

        case .lnot:
            let val = buf[sp - 1]
            buf[sp - 1] = JeffJSTypeConvert.toBool(val) ? .JS_FALSE : .JS_TRUE
            pc += 1

        case .typeof_:
            return pc // deopt: needs string allocation

        // =================================================================
        // Control flow
        // =================================================================

        case .if_false:
            sp -= 1
            let cond = buf[sp]
            let offset = Int(readI32(bc, pc + 1))
            if !JeffJSTypeConvert.toBool(cond) {
                let target = pc + 5 + offset
                if target < entryPC || target >= exitPC {
                    return target // loop exit
                }
                pc = target
            } else {
                pc += 5
            }

        case .if_true:
            sp -= 1
            let cond = buf[sp]
            let offset = Int(readI32(bc, pc + 1))
            if JeffJSTypeConvert.toBool(cond) {
                let target = pc + 5 + offset
                if target < entryPC || target >= exitPC {
                    return target // loop exit
                }
                pc = target
            } else {
                pc += 5
            }

        case .if_false8:
            sp -= 1
            let cond = buf[sp]
            let offset = Int(readI8(bc, pc + 1))
            if !JeffJSTypeConvert.toBool(cond) {
                let target = pc + 2 + offset
                if target < entryPC || target >= exitPC {
                    return target
                }
                pc = target
            } else {
                pc += 2
            }

        case .if_true8:
            sp -= 1
            let cond = buf[sp]
            let offset = Int(readI8(bc, pc + 1))
            if JeffJSTypeConvert.toBool(cond) {
                let target = pc + 2 + offset
                if target < entryPC || target >= exitPC {
                    return target
                }
                pc = target
            } else {
                pc += 2
            }

        case .goto_:
            let offset = Int(readI32(bc, pc + 1))
            let target = pc + 5 + offset
            if target == entryPC {
                // Loop-back: interrupt check then continue trace
                ctx.interruptCounter -= 1
                if ctx.interruptCounter <= 0 {
                    ctx.interruptCounter = JS_INTERRUPT_COUNTER_INIT
                    if ctx.checkInterrupt() { return -1 }
                }
                pc = entryPC
                continue traceLoop
            }
            if target >= entryPC && target < exitPC {
                pc = target
            } else {
                return target // jump outside trace
            }

        case .goto8:
            let offset = Int(readI8(bc, pc + 1))
            let target = pc + 2 + offset
            if target == entryPC {
                ctx.interruptCounter -= 1
                if ctx.interruptCounter <= 0 {
                    ctx.interruptCounter = JS_INTERRUPT_COUNTER_INIT
                    if ctx.checkInterrupt() { return -1 }
                }
                pc = entryPC
                continue traceLoop
            }
            if target >= entryPC && target < exitPC {
                pc = target
            } else {
                return target
            }

        case .goto16:
            let offset = Int(readI16(bc, pc + 1))
            let target = pc + 3 + offset
            if target == entryPC {
                ctx.interruptCounter -= 1
                if ctx.interruptCounter <= 0 {
                    ctx.interruptCounter = JS_INTERRUPT_COUNTER_INIT
                    if ctx.checkInterrupt() { return -1 }
                }
                pc = entryPC
                continue traceLoop
            }
            if target >= entryPC && target < exitPC {
                pc = target
            } else {
                return target
            }

        // =================================================================
        // Fused short forms
        // =================================================================

        case .get_loc8_get_loc8:
            let idxA = Int(bc[pc + 1])
            let idxB = Int(bc[pc + 2])
            buf[sp] = buf[varBase + idxA].dupValue(); sp += 1
            buf[sp] = buf[varBase + idxB].dupValue(); sp += 1
            pc += 3

        case .get_loc8_add:
            let locIdx = Int(bc[pc + 1])
            let lhs = buf[varBase + locIdx]
            let rhs = buf[sp - 1]
            if lhs.isInt && rhs.isInt {
                let a = lhs.toInt32(), b = rhs.toInt32()
                let (r, overflow) = a.addingReportingOverflow(b)
                buf[sp - 1] = overflow ? .newFloat64(Double(a) + Double(b)) : .newInt32(r)
                pc += 2
            } else {
                return pc // deopt
            }

        case .push_i32_put_loc8:
            let val = readI32(bc, pc + 1)
            let locIdx = Int(bc[pc + 5])
            buf[varBase + locIdx] = .newInt32(val)
            pc += 6

        // =================================================================
        // NOP
        // =================================================================

        case .nop:
            pc += 1

        // =================================================================
        // Default: deopt to main interpreter
        // =================================================================

        default:
            return pc
        }
    }

    // Fell through the trace boundary — return current pc for main interpreter
    return pc
}

// =============================================================================
// MARK: - Type Conversion Helpers
// =============================================================================

struct JeffJSTypeConvert {

    // MARK: ToNumber

    /// Convert a JS value to a Double (ToNumber abstract operation).
    /// Mirrors QuickJS `JS_ToFloat64Free` / `JS_ToFloat64`.
    static func toNumber(ctx: JeffJSContext, val: JeffJSValue) -> (Double, Bool) {
        if val.isInt { return (Double(val.toInt32()), true) }
        if val.isFloat64 { return (val.toFloat64(), true) }
        if val.isBool { return (val.toBool() ? 1.0 : 0.0, true) }
        if val.isNull { return (0.0, true) }
        if val.isUndefined { return (Double.nan, true) }
        if val.isString {
            if let s = val.stringValue {
                return (stringToNumber(s), true)
            }
            return (Double.nan, true)
        }
        if val.isObject {
            // ToPrimitive(hint Number) then recurse
            let prim = toPrimitive(ctx: ctx, val: val, hint: HINT_NUMBER)
            if prim.isException { return (Double.nan, false) }
            return toNumber(ctx: ctx, val: prim)
        }
        return (Double.nan, true)
    }

    /// Parse a JeffJSString as a number (for ToNumber on strings).
    static func stringToNumber(_ str: JeffJSString) -> Double {
        let s = jeffJS_toSwiftString(str).trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return 0.0 }
        if s == "Infinity" || s == "+Infinity" { return Double.infinity }
        if s == "-Infinity" { return -Double.infinity }
        // Hex
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            if let v = UInt64(s.dropFirst(2), radix: 16) { return Double(v) }
            return Double.nan
        }
        // Octal
        if s.hasPrefix("0o") || s.hasPrefix("0O") {
            if let v = UInt64(s.dropFirst(2), radix: 8) { return Double(v) }
            return Double.nan
        }
        // Binary
        if s.hasPrefix("0b") || s.hasPrefix("0B") {
            if let v = UInt64(s.dropFirst(2), radix: 2) { return Double(v) }
            return Double.nan
        }
        if let d = Double(s) { return d }
        return Double.nan
    }

    // MARK: ToInt32

    /// Convert a JS value to Int32 (ToInt32 abstract operation).
    static func toInt32(ctx: JeffJSContext, val: JeffJSValue) -> (Int32, Bool) {
        if val.isInt { return (val.toInt32(), true) }
        let (d, ok) = toNumber(ctx: ctx, val: val)
        if !ok { return (0, false) }
        return (doubleToInt32(d), true)
    }

    /// Convert a Double to Int32 per ECMAScript ToInt32.
    static func doubleToInt32(_ d: Double) -> Int32 {
        if d.isNaN || d.isInfinite || d == 0 { return 0 }
        let rem = d.truncatingRemainder(dividingBy: 4294967296.0)
        if rem.isNaN || rem.isInfinite || rem > 9.2e18 || rem < -9.2e18 { return 0 }
        let int64 = Int64(rem)
        var u32 = UInt32(truncatingIfNeeded: int64)
        if u32 >= 2147483648 {
            return Int32(bitPattern: u32)
        }
        return Int32(u32)
    }

    /// Convert a Double to UInt32 per ECMAScript ToUint32.
    static func doubleToUInt32(_ d: Double) -> UInt32 {
        if d.isNaN || d.isInfinite || d == 0 { return 0 }
        let rem = d.truncatingRemainder(dividingBy: 4294967296.0)
        if rem.isNaN || rem.isInfinite || rem > 9.2e18 || rem < -9.2e18 { return 0 }
        let int64 = Int64(rem)
        return UInt32(truncatingIfNeeded: int64)
    }

    // MARK: ToString

    /// Convert a JS value to a JeffJSString (ToString abstract operation).
    static func toString(ctx: JeffJSContext, val: JeffJSValue) -> JeffJSValue {
        if val.isString { return val.dupValue() }
        if val.isInt {
            let s = String(val.toInt32())
            return ctx.newString(s)
        }
        if val.isFloat64 {
            let d = val.toFloat64()
            let s = formatNumber(d)
            return ctx.newString(s)
        }
        if val.isBool {
            return ctx.newString(val.toBool() ? "true" : "false")
        }
        if val.isNull {
            return ctx.newString("null")
        }
        if val.isUndefined {
            return ctx.newString("undefined")
        }
        if val.isObject {
            let prim = toPrimitive(ctx: ctx, val: val, hint: HINT_STRING)
            if prim.isException { return .exception }
            return toString(ctx: ctx, val: prim)
        }
        if val.isSymbol {
            _ = ctx.throwTypeError(message: "Cannot convert a Symbol value to a string")
            return .exception
        }
        return ctx.newString("undefined")
    }

    /// Format a Double to string per ECMAScript Number::toString.
    static func formatNumber(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        if d == 0 { return "0" }
        // Use Swift's default which is close to spec for most values
        if abs(d) < 1e15 && d == Double(Int64(d)) {
            return String(Int64(d))
        }
        return String(d)
    }

    // MARK: ToBool

    /// Convert a JS value to Bool (ToBoolean abstract operation).
    static func toBool(_ val: JeffJSValue) -> Bool {
        if val.isBool { return val.toBool() }
        if val.isInt { return val.toInt32() != 0 }
        if val.isFloat64 {
            let d = val.toFloat64()
            return !d.isNaN && d != 0
        }
        if val.isNull || val.isUndefined { return false }
        if val.isString {
            if let s = val.stringValue { return s.len > 0 }
            return false
        }
        if val.isObject { return true }
        return false
    }

    // MARK: ToPrimitive

    /// ToPrimitive abstract operation.
    static func toPrimitive(ctx: JeffJSContext, val: JeffJSValue, hint: Int) -> JeffJSValue {
        if !val.isObject { return val }
        // Try [Symbol.toPrimitive] first
        let toPrimSym = ctx.getWellKnownSymbol("toPrimitive")
        if toPrimSym != 0 {
            let method = ctx.getProperty(obj: val, atom: toPrimSym)
            if !method.isUndefined && !method.isNull {
                let hintStr: JeffJSValue
                switch hint {
                case HINT_STRING: hintStr = ctx.newString("string")
                case HINT_NUMBER: hintStr = ctx.newString("number")
                default: hintStr = ctx.newString("default")
                }
                let result = ctx.callFunction(method, thisVal: val, args: [hintStr])
                if result.isException { return .exception }
                if !result.isObject { return result }
                _ = ctx.throwTypeError(message: "Cannot convert object to primitive value")
                return .exception
            }
        }
        // OrdinaryToPrimitive
        let methodNames: [String]
        if hint == HINT_STRING {
            methodNames = ["toString", "valueOf"]
        } else {
            methodNames = ["valueOf", "toString"]
        }
        for name in methodNames {
            let method = ctx.getPropertyStr(obj: val, name: name)
            if method.isUndefined || method.isNull { continue }
            if !method.isFunction { continue }
            let result = ctx.callFunction(method, thisVal: val, args: [])
            if result.isException { return .exception }
            if !result.isObject { return result }
        }
        _ = ctx.throwTypeError(message: "Cannot convert object to primitive value")
        return .exception
    }
}

// =============================================================================
// MARK: - Operator Helpers
// =============================================================================

struct JeffJSOperators {

    // MARK: Addition

    /// The + operator: handles string concatenation and numeric addition.
    static func jsAdd(ctx: JeffJSContext, lhs: JeffJSValue, rhs: JeffJSValue) -> JeffJSValue {
        // Fast path: both int32
        if lhs.isInt && rhs.isInt {
            let (result, overflow) = Int32(lhs.toInt32()).addingReportingOverflow(Int32(rhs.toInt32()))
            if !overflow {
                return .newInt32(result)
            }
            return .newFloat64(Double(lhs.toInt32()) + Double(rhs.toInt32()))
        }
        // Fast path: both float64
        if lhs.isNumber && rhs.isNumber {
            let a = lhs.isInt ? Double(lhs.toInt32()) : lhs.toFloat64()
            let b = rhs.isInt ? Double(rhs.toInt32()) : rhs.toFloat64()
            return .newFloat64(a + b)
        }
        // Fast path: either is string
        if lhs.isString || rhs.isString {
            let ls = JeffJSTypeConvert.toString(ctx: ctx, val: lhs)
            if ls.isException { return .exception }
            let rs = JeffJSTypeConvert.toString(ctx: ctx, val: rhs)
            if rs.isException { return .exception }
            return ctx.concatStrings(ls, rs)
        }
        // General case: ToPrimitive
        let lp = JeffJSTypeConvert.toPrimitive(ctx: ctx, val: lhs, hint: HINT_NONE)
        if lp.isException { return .exception }
        let rp = JeffJSTypeConvert.toPrimitive(ctx: ctx, val: rhs, hint: HINT_NONE)
        if rp.isException { return .exception }
        if lp.isString || rp.isString {
            let ls = JeffJSTypeConvert.toString(ctx: ctx, val: lp)
            if ls.isException { return .exception }
            let rs = JeffJSTypeConvert.toString(ctx: ctx, val: rp)
            if rs.isException { return .exception }
            return ctx.concatStrings(ls, rs)
        }
        let (a, ok1) = JeffJSTypeConvert.toNumber(ctx: ctx, val: lp)
        if !ok1 { return .exception }
        let (b, ok2) = JeffJSTypeConvert.toNumber(ctx: ctx, val: rp)
        if !ok2 { return .exception }
        return .newFloat64(a + b)
    }

    // MARK: Equality

    /// Abstract equality (==).
    static func jsEq(ctx: JeffJSContext, lhs: JeffJSValue, rhs: JeffJSValue) -> (Bool, Bool) {
        // Same type
        if JeffJSValue.sameTag(lhs, rhs) {
            return (jsStrictEqSameType(lhs: lhs, rhs: rhs), true)
        }
        // Both numbers but different tags (int32 vs float64)
        if lhs.isNumber && rhs.isNumber {
            let a = lhs.isInt ? Double(lhs.toInt32()) : lhs.toFloat64()
            let b = rhs.isInt ? Double(rhs.toInt32()) : rhs.toFloat64()
            return (a == b, true)
        }
        // null == undefined
        if (lhs.isNull && rhs.isUndefined) || (lhs.isUndefined && rhs.isNull) {
            return (true, true)
        }
        // Number == String -> toNumber(String)
        if lhs.isNumber && rhs.isString {
            let (n, ok) = JeffJSTypeConvert.toNumber(ctx: ctx, val: rhs)
            if !ok { return (false, false) }
            return jsEq(ctx: ctx, lhs: lhs, rhs: .newFloat64(n))
        }
        if lhs.isString && rhs.isNumber {
            let (n, ok) = JeffJSTypeConvert.toNumber(ctx: ctx, val: lhs)
            if !ok { return (false, false) }
            return jsEq(ctx: ctx, lhs: .newFloat64(n), rhs: rhs)
        }
        // Boolean -> Number
        if lhs.isBool {
            let n: JeffJSValue = .newInt32(lhs.toBool() ? 1 : 0)
            return jsEq(ctx: ctx, lhs: n, rhs: rhs)
        }
        if rhs.isBool {
            let n: JeffJSValue = .newInt32(rhs.toBool() ? 1 : 0)
            return jsEq(ctx: ctx, lhs: lhs, rhs: n)
        }
        // Object == primitive -> ToPrimitive(object)
        if lhs.isObject && (rhs.isNumber || rhs.isString || rhs.isSymbol) {
            let lp = JeffJSTypeConvert.toPrimitive(ctx: ctx, val: lhs, hint: HINT_NONE)
            if lp.isException { return (false, false) }
            return jsEq(ctx: ctx, lhs: lp, rhs: rhs)
        }
        if rhs.isObject && (lhs.isNumber || lhs.isString || lhs.isSymbol) {
            let rp = JeffJSTypeConvert.toPrimitive(ctx: ctx, val: rhs, hint: HINT_NONE)
            if rp.isException { return (false, false) }
            return jsEq(ctx: ctx, lhs: lhs, rhs: rp)
        }
        return (false, true)
    }

    /// Strict equality (===) for values of the same tag.
    static func jsStrictEqSameType(lhs: JeffJSValue, rhs: JeffJSValue) -> Bool {
        if lhs.isInt { return lhs.toInt32() == rhs.toInt32() }
        if lhs.isFloat64 {
            let a = lhs.toFloat64(), b = rhs.toFloat64()
            return a == b  // NaN != NaN by IEEE 754
        }
        if lhs.isBool { return lhs.toInt32() == rhs.toInt32() }
        if lhs.isNull || lhs.isUndefined { return true }
        if lhs.isString {
            guard let a = lhs.stringValue, let b = rhs.stringValue else { return false }
            return jeffJS_stringEqual(a, b)
        }
        if lhs.isObject || lhs.isSymbol {
            // Reference identity
            return lhs == rhs
        }
        return false
    }

    /// Strict equality (===) for values of potentially different types.
    static func jsStrictEq(lhs: JeffJSValue, rhs: JeffJSValue) -> Bool {
        if !JeffJSValue.sameTag(lhs, rhs) {
            // Special case: int vs float with same numeric value
            if lhs.isInt && rhs.isFloat64 {
                return Double(lhs.toInt32()) == rhs.toFloat64()
            }
            if lhs.isFloat64 && rhs.isInt {
                return lhs.toFloat64() == Double(rhs.toInt32())
            }
            return false
        }
        return jsStrictEqSameType(lhs: lhs, rhs: rhs)
    }

    // MARK: Comparison

    /// Comparison result constants for jsCompare.
    /// -1 = less than, 0 = not less than (ordered), 2 = unordered (NaN).
    private static let JS_CMP_LT = -1
    private static let JS_CMP_GE = 0
    private static let JS_CMP_UNORDERED = 2

    /// Relational comparison (< operator semantics), tri-state result.
    /// Returns (result, ok).
    ///   result: JS_CMP_LT (-1) if lhs < rhs,
    ///           JS_CMP_GE (0)  if lhs >= rhs (ordered),
    ///           JS_CMP_UNORDERED (2) if either operand is NaN.
    ///   ok: false means an exception was thrown.
    static func jsCompare(ctx: JeffJSContext, lhs: JeffJSValue, rhs: JeffJSValue) -> (Int, Bool) {
        // Fast path: both int (never NaN)
        if lhs.isInt && rhs.isInt {
            return (lhs.toInt32() < rhs.toInt32() ? JS_CMP_LT : JS_CMP_GE, true)
        }
        // Both numbers
        if lhs.isNumber && rhs.isNumber {
            let a = lhs.isInt ? Double(lhs.toInt32()) : lhs.toFloat64()
            let b = rhs.isInt ? Double(rhs.toInt32()) : rhs.toFloat64()
            if a.isNaN || b.isNaN { return (JS_CMP_UNORDERED, true) }
            return (a < b ? JS_CMP_LT : JS_CMP_GE, true)
        }
        // Both strings (never NaN)
        if lhs.isString && rhs.isString {
            if let a = lhs.stringValue, let b = rhs.stringValue {
                return (jeffJS_stringCompare(a, b) < 0 ? JS_CMP_LT : JS_CMP_GE, true)
            }
            return (JS_CMP_GE, true)
        }
        // General case
        let lp = JeffJSTypeConvert.toPrimitive(ctx: ctx, val: lhs, hint: HINT_NUMBER)
        if lp.isException { return (JS_CMP_GE, false) }
        let rp = JeffJSTypeConvert.toPrimitive(ctx: ctx, val: rhs, hint: HINT_NUMBER)
        if rp.isException { return (JS_CMP_GE, false) }
        if lp.isString && rp.isString {
            if let a = lp.stringValue, let b = rp.stringValue {
                return (jeffJS_stringCompare(a, b) < 0 ? JS_CMP_LT : JS_CMP_GE, true)
            }
            return (JS_CMP_GE, true)
        }
        let (a, ok1) = JeffJSTypeConvert.toNumber(ctx: ctx, val: lp)
        if !ok1 { return (JS_CMP_GE, false) }
        let (b, ok2) = JeffJSTypeConvert.toNumber(ctx: ctx, val: rp)
        if !ok2 { return (JS_CMP_GE, false) }
        if a.isNaN || b.isNaN { return (JS_CMP_UNORDERED, true) }
        return (a < b ? JS_CMP_LT : JS_CMP_GE, true)
    }

    // MARK: instanceof

    /// The instanceof operator.
    static func jsInstanceof(ctx: JeffJSContext, val: JeffJSValue, target: JeffJSValue) -> JeffJSValue {
        if !target.isObject {
            _ = ctx.throwTypeError(message: "Right-hand side of instanceof is not an object")
            return .exception
        }
        // Check [Symbol.hasInstance]
        let hasInstanceSym = ctx.getWellKnownSymbol("hasInstance")
        if hasInstanceSym != 0 {
            let method = ctx.getProperty(obj: target, atom: hasInstanceSym)
            if !method.isUndefined && !method.isNull {
                let result = ctx.callFunction(method, thisVal: target, args: [val])
                if result.isException { return .exception }
                return .newBool(JeffJSTypeConvert.toBool(result))
            }
        }
        // OrdinaryHasInstance
        if !target.isFunction {
            _ = ctx.throwTypeError(message: "Right-hand side of instanceof is not callable")
            return .exception
        }
        return .newBool(ctx.ordinaryHasInstance(target, val))
    }

    // MARK: typeof

    /// The typeof operator.
    static func jsTypeof(_ val: JeffJSValue) -> String {
        if val.isUndefined { return "undefined" }
        if val.isNull { return "object" }
        if val.isBool { return "boolean" }
        if val.isNumber { return "number" }
        if val.isString { return "string" }
        if val.isSymbol { return "symbol" }
        if val.isBigInt || val.isShortBigInt { return "bigint" }
        if val.isObject {
            if let obj = val.toObject() {
                if obj.isHTMLDDA { return "undefined" }
                let cid = obj.classID
                // Check both JeffJSClassID and JSClassID enums because
                // createClosure uses JSClassID for generator/async functions
                // but JeffJSClassID for regular bytecode functions.
                if cid == JeffJSClassID.cFunction.rawValue ||
                   cid == JeffJSClassID.bytecodeFunction.rawValue ||
                   cid == JeffJSClassID.boundFunction.rawValue ||
                   cid == JeffJSClassID.generatorFunction.rawValue ||
                   cid == JeffJSClassID.asyncFunction.rawValue ||
                   cid == JeffJSClassID.asyncGeneratorFunction.rawValue ||
                   cid == JSClassID.JS_CLASS_C_FUNCTION.rawValue ||
                   cid == JSClassID.JS_CLASS_C_FUNCTION_DATA.rawValue ||
                   cid == JSClassID.JS_CLASS_BYTECODE_FUNCTION.rawValue ||
                   cid == JSClassID.JS_CLASS_BOUND_FUNCTION.rawValue ||
                   cid == JSClassID.JS_CLASS_GENERATOR_FUNCTION.rawValue ||
                   cid == JSClassID.JS_CLASS_ASYNC_FUNCTION.rawValue ||
                   cid == JSClassID.JS_CLASS_ASYNC_GENERATOR_FUNCTION.rawValue {
                    return "function"
                }
            }
            return "object"
        }
        return "undefined"
    }
}

// =============================================================================
// MARK: - String Comparison Helpers
// =============================================================================

/// Compare two JeffJSString values for equality.
private func jeffJS_stringEqual(_ a: JeffJSString, _ b: JeffJSString) -> Bool {
    if a === b { return true }
    if a.len != b.len { return false }
    if a.isWideChar != b.isWideChar {
        // Different encodings but same length: compare code unit by code unit
        for i in 0..<a.len {
            if jeffJS_getString(str: a, at: i) != jeffJS_getString(str: b, at: i) {
                return false
            }
        }
        return true
    }
    switch (a.storage, b.storage) {
    case (.str8(let ab), .str8(let bb)):
        return ab == bb
    case (.str16(let ab), .str16(let bb)):
        return ab == bb
    default:
        return false
    }
}

/// Lexicographic comparison of two JeffJSString values.
/// Returns < 0, 0, or > 0.
private func jeffJS_stringCompare(_ a: JeffJSString, _ b: JeffJSString) -> Int {
    let len = min(a.len, b.len)
    for i in 0..<len {
        let ca = jeffJS_getString(str: a, at: i)
        let cb = jeffJS_getString(str: b, at: i)
        if ca != cb { return ca < cb ? -1 : 1 }
    }
    if a.len < b.len { return -1 }
    if a.len > b.len { return 1 }
    return 0
}

/// Convert a JeffJSString to a Swift String.
private func jeffJS_toSwiftString(_ s: JeffJSString) -> String {
    switch s.storage {
    case .str8(let buf):
        return String(buf.prefix(s.len).map { Character(Unicode.Scalar($0)) })
    case .str16(let buf):
        return String(utf16CodeUnits: Array(buf.prefix(s.len)), count: s.len)
    }
}

// =============================================================================
// MARK: - JeffJSInterpreter
// =============================================================================

/// The bytecode interpreter.  This struct contains the main execution loop
/// (callInternal) and all supporting dispatch logic.
///
/// Port of `JS_CallInternal()` from QuickJS quickjs.c.
struct JeffJSInterpreter {

    // =========================================================================
    // MARK: - Inline Call Frame
    // =========================================================================

    /// Saved caller state for inline (non-recursive) function calls.
    /// Instead of recursively calling `callInternal()` for every JS function
    /// call, we save the caller's state here and swap in the callee's state.
    struct InlineCallFrame {
        var pc: Int
        var sp: Int
        var buf: UnsafeMutablePointer<JeffJSValue>
        var bufCapacity: Int
        var varBase: Int
        var spBase: Int
        var bc: [UInt8]
        var bcLen: Int
        var fb: JeffJSFunctionBytecode
        var frame: JeffJSStackFrame
        var varRefs: [JeffJSVarRef?]
        var funcObj: JeffJSValue
        var flags: Int
    }

    /// Toggle to enable/disable inline calls for debugging.
    /// When false, all calls go through the recursive `callInternal` path.
    static var useInlineCalls = JeffJSConfig.useInlineCalls

    // =========================================================================
    // MARK: - Unsafe Buffer Pool
    // =========================================================================

    /// Pool of pre-allocated unsafe buffers to avoid malloc/free on every call.
    /// Each entry is (pointer, capacity). Reused when capacity >= needed.
    private static var bufPool: [(UnsafeMutablePointer<JeffJSValue>, Int)] = []
    private static let bufPoolMax = JeffJSConfig.bufPoolMax

    @inline(__always)
    static func acquireBuf(size: Int) -> (UnsafeMutablePointer<JeffJSValue>, Int) {
        if !bufPool.isEmpty {
            let (ptr, cap) = bufPool.removeLast()
            if cap >= size {
                // Reuse — use update (not initialize) since memory is already initialized
                for i in 0..<size { ptr[i] = .undefined }
                return (ptr, cap)
            }
            // Too small — deallocate and allocate new
            ptr.deinitialize(count: cap)
            ptr.deallocate()
        }
        let ptr = UnsafeMutablePointer<JeffJSValue>.allocate(capacity: size)
        ptr.initialize(repeating: .undefined, count: size)
        return (ptr, size)
    }

    @inline(__always)
    static func releaseBuf(_ ptr: UnsafeMutablePointer<JeffJSValue>, capacity: Int) {
        if bufPool.count < bufPoolMax && capacity <= 512 {
            bufPool.append((ptr, capacity))
        } else {
            ptr.deinitialize(count: capacity)
            ptr.deallocate()
        }
    }

    // =========================================================================
    // MARK: - Main Entry Point
    // =========================================================================

    /// Execute a bytecode function.
    ///
    /// - Parameters:
    ///   - ctx: The execution context.
    ///   - funcObj: The function value (must be a bytecode function object).
    ///   - thisVal: The `this` binding for this call.
    ///   - args: The arguments array.
    ///   - flags: Call flags (JS_CALL_FLAG_CONSTRUCTOR, JS_CALL_FLAG_GENERATOR, etc.).
    ///   - generatorObject: When called for a generator, the generator object
    ///     that holds `JeffJSGeneratorData`. Opcodes like `initial_yield` and
    ///     `yield_` save state into this object's generator data.
    ///   - resumeState: When resuming a suspended generator via `.next()`,
    ///     the previously-saved execution state. If non-nil, the interpreter
    ///     restores pc/sp/stack/varBuf/argBuf from this state instead of
    ///     initializing fresh.
    ///   - resumeValue: The value sent into the generator via `.next(value)`.
    ///     Pushed onto the stack after state restoration so it becomes the
    ///     result of the `yield` expression.
    ///   - resumeCompletionType: 0 = next (push resumeValue), 1 = return
    ///     (force return with resumeValue), 2 = throw (throw resumeValue).
    /// - Returns: The return value, or JeffJSValue.exception on error.
    /// Maximum native call depth to prevent stack overflow crashes.
    /// Each callInternal frame allocates a 32-element stack (~1KB) plus locals
    /// and frame overhead (~2KB total). With stack capped at 32 elements,
    /// 200 levels ≈ 400KB which fits comfortably in a 2MB+ thread stack.
    /// Both callFunction and callInternal increment this counter.
    static let maxCallDepth = JeffJSConfig.maxCallDepth
    static var currentCallDepth = 0
    static var traceOpcodes = JeffJSConfig.traceOpcodes
    /// Last two property atoms accessed via get_field — used to enrich error messages.
    static var lastGetFieldAtom: UInt32 = 0
    static var prevGetFieldAtom: UInt32 = 0

    static func callInternal(
        ctx: JeffJSContext,
        funcObj: JeffJSValue,
        thisVal: JeffJSValue,
        args: [JeffJSValue],
        flags: Int = 0,
        generatorObject: JeffJSValue = .undefined,
        resumeState: GeneratorSavedState? = nil,
        resumeValue: JeffJSValue = .undefined,
        resumeCompletionType: Int = 0
    ) -> JeffJSValue {
        // Guard against stack overflow from deep recursion
        currentCallDepth += 1
        defer { currentCallDepth -= 1 }
        if currentCallDepth > maxCallDepth {
            _ = ctx.throwInternalError(message: "Maximum call stack size exceeded")
            return .exception
        }

        guard let obj = funcObj.obj else {
            let desc: String
            if funcObj.isUndefined { desc = "undefined" }
            else if funcObj.isNull { desc = "null" }
            else if funcObj.isInt { desc = String(funcObj.toInt32()) }
            else if funcObj.isBool { desc = funcObj.toBool() ? "true" : "false" }
            else { desc = ctx.toSwiftString(funcObj) ?? "\(funcObj.tag)" }
            _ = ctx.throwTypeError(message: "\(desc) is not a function")
            return .exception
        }

        // Extract bytecode — or dispatch to callFunction for C functions
        // that were accidentally routed here (e.g., via Promise reaction jobs)
        if case .cFunc(_, let cFunction, _, _, let magic) = obj.payload {
            switch cFunction {
            case .generic(let fn): return fn(ctx, thisVal, args)
            case .genericMagic(let fn): return fn(ctx, thisVal, args, Int(magic))
            case .constructor(let fn): return fn(ctx, thisVal, args)
            case .constructorOrFunc(let fn): return fn(ctx, thisVal, args, false)
            case .getter(let fn): return fn(ctx, thisVal)
            case .setter(let fn): return fn(ctx, thisVal, args.first ?? .undefined)
            case .getterMagic(let fn): return fn(ctx, thisVal, Int(magic))
            case .setterMagic(let fn): return fn(ctx, thisVal, args.first ?? .undefined, Int(magic))
            case .fFloat64(let fn): return .newFloat64(fn(args.first?.toFloat64() ?? .nan))
            case .fFloat64_2(let fn): return .newFloat64(fn(args.first?.toFloat64() ?? .nan, (args.count > 1 ? args[1] : .undefined).toFloat64()))
            case .iteratorNext(let fn): return fn(ctx, thisVal, args, nil, Int(magic))
            }
        }
        // Bound function: unwrap and delegate to callFunction which handles
        // the full bound-function chain (bound args, bound this, etc.)
        if case .boundFunction(let bound) = obj.payload {
            var fullArgs = bound.argv
            fullArgs.append(contentsOf: args)
            let boundThis = bound.thisVal.isUndefined ? thisVal : bound.thisVal
            return ctx.callFunction(bound.funcObj, thisVal: boundThis, args: fullArgs)
        }
        // Callable proxy: delegate to the proxy apply trap handler
        if case .proxyData = obj.payload {
            return js_proxy_apply(ctx, obj._obj, thisVal, args)
        }
        guard case .bytecodeFunc(let fbOpt, let varRefsOpt, _) = obj.payload,
              let fb0 = fbOpt else {
            _ = ctx.throwTypeError(message: "not a bytecode function")
            return .exception
        }

        var fb = fb0  // mutable so inline calls can swap callee's bytecode in
        var bc = fb.bytecode
        var bcLen = fb.bytecodeLen

        // Set up the call frame (pooled to avoid malloc/free per call)
        var frame = JeffJSStackFrame.acquire()
        frame.prevFrame = ctx.currentFrame
        frame.curFunc = funcObj
        // ES spec §10.2.1.2: For non-strict functions, coerce undefined/null this
        // to the global object. Strict mode functions receive this as-is.
        let isConstructor = (flags & JS_CALL_FLAG_CONSTRUCTOR) != 0
        let isStrict: Bool = {
            if let compiled = fb0 as? JeffJSFunctionBytecodeCompiled {
                return (compiled.jsModeFlags & UInt8(JS_MODE_STRICT)) != 0
            }
            return false
        }()
        if !isConstructor && !isStrict {
            if thisVal.isUndefined || thisVal.isNull {
                frame.thisVal = ctx.globalObj
            } else {
                frame.thisVal = thisVal
            }
        } else {
            frame.thisVal = thisVal
        }
        // Arrow functions use the lexical `this` captured at closure creation
        // time, overriding whatever the caller passed.
        if fb0.isArrow, let arrowThis = obj.arrowThisVal {
            frame.thisVal = arrowThis.dupValue()
        }
        frame.argCount = args.count
        frame.argBuf = args

        // Initialize local variables
        let varCount = Int(fb.varCount)
        frame.varBuf = [JeffJSValue](repeating: .undefined, count: varCount)
        frame.varCount = varCount

        // Copy arguments to arg slots, padding with undefined
        let argSlots = max(Int(fb.argCount), args.count)
        if frame.argBuf.count < Int(fb.argCount) {
            frame.argBuf.append(contentsOf:
                [JeffJSValue](repeating: .undefined,
                              count: Int(fb.argCount) - frame.argBuf.count))
        }

        // Allocate contiguous unsafe buffer: [arg slots][var slots][value stack]
        let stackSlots = max(Int(fb.stackSize), 4) + 32
        let totalSlots = argSlots + varCount + stackSlots
        var (buf, bufCapacity) = JeffJSInterpreter.acquireBuf(size: totalSlots)
        var varBase = argSlots
        var spBase = argSlots + varCount

        // Copy args into buffer at offset 0
        for i in 0..<args.count { buf[i] = args[i] }
        // Remaining arg slots (padding) are already .undefined from initialization

        var sp = spBase  // stack pointer (absolute index into buf)

        // Store buf info on frame for potential external access
        frame.buf = buf
        frame.bufCapacity = bufCapacity
        frame.bufVarBase = varBase
        frame.bufSpBase = spBase

        // Named function expression self-reference: initialize the local variable
        // that holds the function's own name binding (ES spec §15.2.4).
        if let compiled = fb0 as? JeffJSFunctionBytecodeCompiled,
           compiled.funcNameVarIdx >= 0 {
            buf[varBase + compiled.funcNameVarIdx] = funcObj.dupValue()
        }

        // Push frame
        ctx.currentFrame = frame
        frame.spBase = 0

        var pc = 0  // program counter (index into bc[])
        var retVal: JeffJSValue = .undefined

        // Mutable copies of parameters for inline call state swapping
        var mFuncObj = funcObj
        var mFlags = flags

        // Closure variable references
        var varRefs: [JeffJSVarRef?] = varRefsOpt

        // Inline call stack for non-recursive function calls
        var inlineCallStack: [InlineCallFrame] = []
        inlineCallStack.reserveCapacity(16)

        // ---- Sync helpers: copy between buf and frame arrays ----

        /// Sync buf → frame.argBuf/varBuf so JeffJSVarRef.pvalue sees current values.
        /// Called before closure creation, close_loc, and var_ref detach.
        @inline(__always) func syncBufToFrame() {
            for i in 0..<frame.argBuf.count {
                if i < varBase { frame.argBuf[i] = buf[i] }
            }
            for i in 0..<frame.varBuf.count {
                frame.varBuf[i] = buf[varBase + i]
            }
        }

        /// Sync frame.argBuf/varBuf → buf after external code may have modified them
        /// (e.g. JeffJSVarRef.pvalue setter, generator restore).
        @inline(__always) func syncFrameToBuf() {
            for i in 0..<frame.argBuf.count {
                if i < varBase { buf[i] = frame.argBuf[i] }
            }
            for i in 0..<frame.varBuf.count {
                buf[varBase + i] = frame.varBuf[i]
            }
        }

        // ---- Generator resumption: restore saved state ----
        if let saved = resumeState {
            pc = saved.pc
            // Restore varBuf/argBuf from saved state
            frame.varBuf = saved.varBuf
            frame.varCount = saved.varBuf.count
            frame.argBuf = saved.argBuf
            frame.argCount = saved.argBuf.count

            // Copy saved stack into buf's value-stack region
            for i in 0..<saved.stack.count {
                if spBase + i < bufCapacity {
                    buf[spBase + i] = saved.stack[i]
                }
            }
            sp = spBase + saved.sp

            // Sync restored frame arrays into buf
            syncFrameToBuf()

            switch resumeCompletionType {
            case 1:
                retVal = resumeValue
                ctx.currentFrame = frame.prevFrame
                JeffJSInterpreter.releaseBuf(buf, capacity: bufCapacity)
                return retVal
            case 2:
                // Throw: inject the exception and fall through to the dispatch
                // loop so try/catch handlers in the generator body can catch it.
                ctx.throwValue(resumeValue.dupValue())
                retVal = .exception
            default:
                // yield* delegation: if we're resuming from a yield_star with
                // a delegated iterator, advance it instead of pushing resumeValue.
                if !saved.delegatedIter.isUndefined {
                    let iter = saved.delegatedIter
                    let result = ctx.iteratorNext(iter: iter)
                    if result.isException {
                        retVal = .exception
                    } else {
                        let done = ctx.iteratorCheckDone(result: result)
                        let value = ctx.iteratorGetValue(result: result)
                        if done {
                            // Inner iterator exhausted — push return value and
                            // advance pc past the yield_star opcode.
                            buf[sp] = value; sp += 1
                            pc += 1  // skip past yield_star
                        } else {
                            // More values — yield this one and re-suspend.
                            if let genObj = generatorObject.toObject(),
                               case .generatorData(let genData) = genObj.payload {
                                syncBufToFrame()
                                let stackCount = sp - spBase
                                var savedStack = [JeffJSValue](repeating: .undefined, count: stackCount)
                                for i in 0..<stackCount { savedStack[i] = buf[spBase + i] }
                                var newSaved = GeneratorSavedState(
                                    pc: pc,
                                    sp: stackCount,
                                    stack: savedStack,
                                    varBuf: frame.varBuf,
                                    argBuf: frame.argBuf,
                                    funcObj: mFuncObj,
                                    thisVal: thisVal)
                                newSaved.delegatedIter = iter
                                genData.savedState = newSaved
                                genData.state = .suspended_yield_star
                            }
                            retVal = value
                            ctx.currentFrame = frame.prevFrame
                            JeffJSInterpreter.releaseBuf(buf, capacity: bufCapacity)
                            return retVal
                        }
                    }
                } else if !saved.isInitialYield {
                    buf[sp] = resumeValue
                    sp += 1
                }
            }
        }

        // Helper closures for stack operations using the contiguous buffer.
        // Safety guards for sp underflow: if bytecode is malformed, return
        // .undefined rather than reading into arg/var slots.
        @inline(__always) func push(_ val: JeffJSValue) {
            buf[sp] = val
            sp += 1
        }

        @inline(__always) func pop() -> JeffJSValue {
            guard sp > spBase else { return .undefined }
            sp -= 1
            return buf[sp]
        }

        @inline(__always) func peek() -> JeffJSValue {
            guard sp > spBase else { return .undefined }
            return buf[sp - 1]
        }

        @inline(__always) func peekAt(_ offset: Int) -> JeffJSValue {
            let idx = sp - 1 - offset
            guard idx >= spBase else { return .undefined }
            return buf[idx]
        }

        // =====================================================================
        // MARK: Dispatch Loop
        // =====================================================================

        #if DEBUG
        var opcodeCount = 0
        #endif

        exceptionRetry: while true {
        // If an exception was injected before the dispatch loop (e.g.,
        // generator.throw() resume), skip straight to exception handling.
        if !retVal.isException {
        dispatchLoop: while pc < bcLen {
            // Fast opcode decode: force-unwrap since the compiler guarantees
            // only valid opcodes in final bytecode. Wide opcodes (rawValue >= 256)
            // are encoded as a 0x00 prefix byte which maps to .invalid; we
            // handle them in the .invalid case below (cold path).
            let op = JeffJSOpcode(rawValue: UInt16(bc[pc]))!

            #if DEBUG
            opcodeCount += 1
            #endif

            if JeffJSInterpreter.traceOpcodes {
                var extra = ""
                if op == .put_loc || op == .put_loc0 || op == .put_loc1 || op == .put_loc2 || op == .put_loc3
                    || op == .set_loc || op == .set_loc0 || op == .set_loc1 || op == .set_loc2 || op == .set_loc3
                    || op == .get_loc || op == .get_loc0 || op == .get_loc1 || op == .get_loc2 || op == .get_loc3 {
                    let idx: Int
                    switch op {
                    case .put_loc0, .set_loc0, .get_loc0: idx = 0
                    case .put_loc1, .set_loc1, .get_loc1: idx = 1
                    case .put_loc2, .set_loc2, .get_loc2: idx = 2
                    case .put_loc3, .set_loc3, .get_loc3: idx = 3
                    case .get_loc8, .put_loc8, .set_loc8: idx = Int(readU8(bc, pc + 1))
                    default: idx = Int(readU16(bc, pc + 1))
                    }
                    let curVal = buf[varBase + idx]
                    extra = " idx=\(idx) curVal=bits=0x\(String(curVal.bits, radix: 16))/\(curVal.toInt32())"
                    if sp > spBase { extra += " TOS=bits=0x\(String(buf[sp-1].bits, radix: 16))/\(buf[sp-1].toInt32())" }
                }
                if op == .push_i32 { extra = " val=\(readI32(bc, pc + 1))" }
                if op == .get_field || op == .get_field2 || op == .put_field {
                    let atom = readU32(bc, pc + 1)
                    let name = ctx.rt.atomToString(atom) ?? "?"
                    extra = " atom=\(atom) '\(name)'"
                }
                if op == .return_ && sp > spBase { extra = " TOS=bits=0x\(String(buf[sp-1].bits, radix: 16))/\(buf[sp-1].toInt32())" }
                print("[TRACE] pc=\(pc) op=\(op) sp=\(sp)\(extra)")
            }

            #if DEBUG
            let spBefore = sp
            let pcBefore = pc
            #endif

            switch op {

            // -----------------------------------------------------------------
            // Invalid opcode (trap for uninitialized bytecode)
            // -----------------------------------------------------------------

            case .invalid:
                // Wide opcode prefix: byte 0x00 followed by the low byte
                // encodes opcodes with rawValue >= 256 (e.g. line_num,
                // get_field_opt_chain). This path is cold -- wide opcodes
                // are rare in normal bytecode.
                if pc + 1 < bcLen {
                    let rawValue = 256 + UInt16(bc[pc + 1])
                    if let wideOp = JeffJSOpcode(rawValue: rawValue) {
                        // Handle the few wide opcodes that appear in practice
                        switch wideOp {
                        case .line_num:
                            // line_num is debug info, skip it (2-byte prefix + 4-byte line + 4-byte col)
                            pc += 2 + 4 + 4
                            continue dispatchLoop
                        case .get_field_opt_chain:
                            let atom = readU32(bc, pc + 2)
                            let obj = pop()
                            if obj.isUndefined || obj.isNull {
                                push(.undefined)
                            } else {
                                let val = ctx.getProperty(obj: obj, atom: atom)
                                if val.isException { retVal = .exception; break dispatchLoop }
                                push(val)
                            }
                            pc += 2 + 4
                            continue dispatchLoop
                        case .get_array_el_opt_chain:
                            let key = pop()
                            let obj = pop()
                            if obj.isUndefined || obj.isNull {
                                push(.undefined)
                            } else {
                                let val = ctx.getPropertyValue(obj: obj, prop: key)
                                if val.isException { retVal = .exception; break dispatchLoop }
                                push(val)
                            }
                            pc += 2
                            continue dispatchLoop
                        default:
                            break  // fall through to error below
                        }
                    }
                }
                _ = ctx.throwInternalError(message: "Invalid opcode 0 (trap) at pc=\(pc) - uninitialized bytecode")
                retVal = .exception
                break dispatchLoop

            // -----------------------------------------------------------------
            // Push Values
            // -----------------------------------------------------------------

            case .push_i32:
                let val = readI32(bc, pc + 1)
                push(.newInt32(val))
                pc += 5

            case .push_const:
                let idx = Int(readU32(bc, pc + 1))
                if idx < fb.cpool.count {
                    push(fb.cpool[idx].dupValue())
                } else {
                    push(.undefined)
                }
                pc += 5

            case .fclosure:
                let idx = Int(readU32(bc, pc + 1))
                // Sync buf → frame so JeffJSVarRef.pvalue sees current values
                syncBufToFrame()
                let closureVal = ctx.createClosure(fb: fb, cpoolIdx: idx, varRefs: varRefs,
                                                    parentFrame: frame)
                // Sync back in case closure creation modified frame arrays
                syncFrameToBuf()
                push(closureVal)
                pc += 5

            case .push_atom_value:
                let atom = readU32(bc, pc + 1)
                let str = ctx.atomToString(atom)
                push(str)
                pc += 5

            case .private_symbol:
                let atom = readU32(bc, pc + 1)
                let sym = ctx.newSymbolFromAtom(atom, isPrivate: true)
                push(sym)
                pc += 5

            case .undefined:
                push(.undefined)
                pc += 1

            case .push_false:
                push(.newBool(false))
                pc += 1

            case .push_true:
                push(.newBool(true))
                pc += 1

            case .object:
                let obj = ctx.newPlainObject()
                push(obj)
                pc += 1

            case .special_object:
                let kind = readU8(bc, pc + 1)
                // Sync buf → frame since newSpecialObject reads frame.argBuf
                syncBufToFrame()
                let obj = ctx.newSpecialObject(kind: kind, frame: frame)
                push(obj)
                pc += 2

            case .rest:
                let argIdx = Int(readU16(bc, pc + 1))
                // Build args array from buf for createRestArray
                var restSrcArgs = [JeffJSValue](repeating: .undefined, count: varBase)
                for i in 0..<varBase { restSrcArgs[i] = buf[i] }
                let restArr = ctx.createRestArray(args: restSrcArgs, fromIndex: argIdx)
                push(restArr)
                pc += 3

            // -----------------------------------------------------------------
            // Stack Manipulation
            // -----------------------------------------------------------------

            case .drop:
                let dropped = pop()
                dropped.freeValue()
                pc += 1

            case .nip:
                let top = pop()
                let discarded = pop()
                discarded.freeValue()
                push(top)
                pc += 1

            case .nip1:
                let a = pop(); let b = pop(); let discarded = pop()
                discarded.freeValue()
                push(b); push(a)
                pc += 1

            case .dup:
                let val = peek()
                push(val.dupValue())
                pc += 1

            case .dup1:
                // Duplicate the element below the top: a b -> a b a
                let a = peekAt(1)
                push(a.dupValue())
                pc += 1

            case .dup2:
                let b = peekAt(0)
                let a = peekAt(1)
                push(a.dupValue())
                push(b.dupValue())
                pc += 1

            case .dup3:
                let c = peekAt(0)
                let b = peekAt(1)
                let a = peekAt(2)
                push(a.dupValue())
                push(b.dupValue())
                push(c.dupValue())
                pc += 1

            case .insert2:
                // QuickJS: a b -> b a b (insert copy of TOS below top 2)
                // nPop=2, nPush=3
                let b = pop()
                let a = pop()
                push(b); push(a); push(b.dupValue())
                pc += 1

            case .insert3:
                // QuickJS: a b c -> c a b c (insert copy of TOS below top 3)
                // nPop=3, nPush=4
                let c = pop()
                let b = pop(); let a = pop()
                push(c); push(a); push(b); push(c.dupValue())
                pc += 1

            case .insert4:
                // QuickJS: a b c d -> d a b c d (insert copy of TOS below top 4)
                // nPop=4, nPush=5
                let d = pop()
                let c = pop(); let b = pop(); let a = pop()
                push(d); push(a); push(b); push(c); push(d.dupValue())
                pc += 1

            case .perm3:
                let c = pop(); let b = pop(); let a = pop()
                push(c); push(a); push(b)
                pc += 1

            case .perm4:
                let d = pop(); let c = pop(); let b = pop(); let a = pop()
                push(d); push(a); push(b); push(c)
                pc += 1

            case .perm5:
                let e = pop(); let d = pop(); let c = pop(); let b = pop(); let a = pop()
                push(e); push(a); push(b); push(c); push(d)
                pc += 1

            case .swap:
                let a = pop(); let b = pop()
                push(a); push(b)
                pc += 1

            case .swap2:
                // Swap top 2 pairs: a b c d -> c d a b
                let d = pop(); let c = pop(); let b = pop(); let a = pop()
                push(c); push(d); push(a); push(b)
                pc += 1

            case .rot3l:
                let c = pop(); let b = pop(); let a = pop()
                push(b); push(c); push(a)
                pc += 1

            case .rot3r:
                // Rotate 3 right: a b c -> c a b
                let c = pop(); let b = pop(); let a = pop()
                push(c); push(a); push(b)
                pc += 1

            case .rot4l:
                let d = pop(); let c = pop(); let b = pop(); let a = pop()
                push(b); push(c); push(d); push(a)
                pc += 1

            case .rot5l:
                // Rotate 5 left: a b c d e -> b c d e a
                let e = pop(); let d = pop(); let c = pop(); let b = pop(); let a = pop()
                push(b); push(c); push(d); push(e); push(a)
                pc += 1

            // -----------------------------------------------------------------
            // Function Calls
            // -----------------------------------------------------------------

            case .call, .call0, .call1, .call2, .call3:
                // --- Optimizations applied here ---
                // (a) For call0/call1/call2/call3: avoid allocating an args array;
                //     use fixed-size stack reads or empty literal.
                // (b) For bytecode functions (the common case): inline the call
                //     by saving/restoring frame state instead of recursive callInternal().
                // (c) Generators, async, bound, C functions use the recursive path.
                let argc: Int
                let instrSize: Int
                switch op {
                case .call:
                    argc = Int(readU16(bc, pc + 1))
                    instrSize = 3
                case .call0: argc = 0; instrSize = 1
                case .call1: argc = 1; instrSize = 1
                case .call2: argc = 2; instrSize = 1
                case .call3: argc = 3; instrSize = 1
                default: argc = 0; instrSize = 1
                }
                // Build args with minimal allocation for common cases
                let callArgs: [JeffJSValue]
                switch argc {
                case 0:
                    callArgs = []
                case 1:
                    let a0 = pop()
                    callArgs = [a0]
                case 2:
                    let a1 = pop(); let a0 = pop()
                    callArgs = [a0, a1]
                case 3:
                    let a2 = pop(); let a1 = pop(); let a0 = pop()
                    callArgs = [a0, a1, a2]
                default:
                    var tmp = [JeffJSValue](repeating: .undefined, count: argc)
                    for i in stride(from: argc - 1, through: 0, by: -1) { tmp[i] = pop() }
                    callArgs = tmp
                }
                let funcVal = pop()
                // Inline call fast path: regular bytecode function
                if JeffJSInterpreter.useInlineCalls,
                   let callObj = funcVal.obj,
                   case .bytecodeFunc(let fastFbOpt, let fastVarRefsOpt, _) = callObj.payload,
                   let fastFb = fastFbOpt, !fastFb.isGenerator, !fastFb.isAsyncFunc {
                    // Depth guard
                    if inlineCallStack.count > 10000 {
                        _ = ctx.throwInternalError(message: "Maximum call stack size exceeded")
                        retVal = .exception
                        break dispatchLoop
                    }
                    // Save caller state
                    inlineCallStack.append(InlineCallFrame(
                        pc: pc + instrSize, sp: sp,
                        buf: buf, bufCapacity: bufCapacity,
                        varBase: varBase, spBase: spBase,
                        bc: bc, bcLen: bcLen, fb: fb,
                        frame: frame, varRefs: varRefs,
                        funcObj: mFuncObj, flags: mFlags))
                    // Set up callee state
                    fb = fastFb
                    bc = fastFb.bytecode
                    bcLen = fastFb.bytecodeLen
                    varRefs = fastVarRefsOpt
                    mFuncObj = funcVal
                    mFlags = 0
                    // New frame
                    let newFrame = JeffJSStackFrame.acquire()
                    newFrame.prevFrame = ctx.currentFrame
                    newFrame.curFunc = funcVal
                    // ES spec: non-strict functions get globalObj as this for plain calls
                    let fastIsStrict: Bool = {
                        if let c = fastFb as? JeffJSFunctionBytecodeCompiled {
                            return (c.jsModeFlags & UInt8(JS_MODE_STRICT)) != 0
                        }
                        return false
                    }()
                    // Determine `this` for the call:
                    // 1. If arrow function: use captured lexical this
                    // 2. If get_field receiver available: use it (method call that
                    //    transformMethodCalls failed to convert to call_method)
                    // 3. Otherwise: globalObj (non-strict) or undefined (strict)
                    if fastFb.isArrow, let callObj = funcVal.obj,
                       let arrowThis = callObj.arrowThisVal {
                        newFrame.thisVal = arrowThis.dupValue()
                    } else if !frame.lastGetFieldReceiver.isUndefined {
                        newFrame.thisVal = frame.lastGetFieldReceiver.dupValue()
                        frame.lastGetFieldReceiver = .undefined  // clear after use
                    } else {
                        newFrame.thisVal = fastIsStrict ? .undefined : ctx.globalObj
                    }
                    newFrame.argCount = callArgs.count
                    newFrame.argBuf = callArgs
                    let newVarCount = Int(fastFb.varCount)
                    newFrame.varBuf = [JeffJSValue](repeating: .undefined, count: newVarCount)
                    newFrame.varCount = newVarCount
                    let newArgSlots = max(Int(fastFb.argCount), callArgs.count)
                    if newFrame.argBuf.count < Int(fastFb.argCount) {
                        newFrame.argBuf.append(contentsOf:
                            [JeffJSValue](repeating: .undefined,
                                          count: Int(fastFb.argCount) - newFrame.argBuf.count))
                    }
                    frame = newFrame
                    ctx.currentFrame = frame
                    frame.spBase = 0
                    // Allocate new contiguous buffer for callee
                    let newStackSlots = max(Int(fastFb.stackSize), 4) + 32
                    let newTotalSlots = newArgSlots + newVarCount + newStackSlots
                    let (newBuf, newBufCap) = JeffJSInterpreter.acquireBuf(size: newTotalSlots)
                    // Copy args into callee buf
                    for i in 0..<callArgs.count { newBuf[i] = callArgs[i] }
                    buf = newBuf
                    bufCapacity = newBufCap
                    varBase = newArgSlots
                    spBase = newArgSlots + newVarCount
                    sp = spBase
                    // Store buf info on frame
                    frame.buf = buf
                    frame.bufCapacity = bufCapacity
                    frame.bufVarBase = varBase
                    frame.bufSpBase = spBase
                    pc = 0
                    continue dispatchLoop
                } else {
                    // Slow path: bound functions, C functions, generators, async, etc.
                    // Use lastGetFieldReceiver as `this` if available (method call
                    // that transformMethodCalls couldn't convert to call_method).
                    let slowThis = frame.lastGetFieldReceiver.isUndefined ? JeffJSValue.undefined : frame.lastGetFieldReceiver
                    let result: JeffJSValue
                    if let callObj = funcVal.obj,
                       case .bytecodeFunc(let fbOpt2, _, _) = callObj.payload,
                       let fastFb2 = fbOpt2, !fastFb2.isGenerator, !fastFb2.isAsyncFunc {
                        result = JeffJSInterpreter.callInternal(ctx: ctx, funcObj: funcVal,
                                                                thisVal: slowThis, args: callArgs, flags: 0)
                    } else {
                        result = ctx.callFunction(funcVal, thisVal: slowThis, args: callArgs)
                    }
                    frame.lastGetFieldReceiver = .undefined  // clear after use
                    if result.isException {
                        retVal = .exception
                        break dispatchLoop
                    }
                    push(result)
                    pc += instrSize
                }

            case .call_method:
                let argc = Int(readU16(bc, pc + 1))
                // ── Array.prototype.push fast path ──────────────────────
                // For arr.push(val) (the overwhelmingly common case), skip
                // the full callFunction dispatch.  Conditions:
                //   1. Exactly one argument (argc == 1)
                //   2. The function object is Array.prototype.push (identity check)
                //   3. The receiver is a dense array (classID == array)
                //   4. The "length" property is at prop[0] (verified via shape atom)
                // Stack layout: [..., thisObj, funcVal, arg0]
                // Uses fastArrayPush() to avoid COW copy of the backing array.
                if argc == 1,
                   sp >= spBase + 3,
                   let pushObj = ctx.arrayProtoPushObj,
                   let funcObj = buf[sp - 2].obj,
                   funcObj === pushObj,
                   let arrObj = buf[sp - 3].obj,
                   arrObj.classID == JeffJSClassID.array.rawValue,
                   arrObj.prop.count > 0,
                   let shape = arrObj.shape,
                   shape.prop.count > 0,
                   shape.prop[0].atom == JeffJSAtomID.JS_ATOM_length.rawValue
                {
                    let newCount = arrObj.asClass.fastArrayPush(buf[sp - 1])
                    if newCount > 0 {
                        // Update the length property in-place (prop[0] == "length").
                        arrObj.asClass.prop[0] = .value(.newInt32(Int32(newCount)))
                        // Pop arg, funcVal, thisObj; push new length
                        sp -= 3
                        push(.newInt32(Int32(newCount)))
                        pc += 3
                        continue dispatchLoop
                    }
                }
                // ── General call_method path ────────────────────────────
                // Build args with minimal allocation for common cases
                let cmArgs: [JeffJSValue]
                switch argc {
                case 0:
                    cmArgs = []
                case 1:
                    let a0 = pop()
                    cmArgs = [a0]
                case 2:
                    let a1 = pop(); let a0 = pop()
                    cmArgs = [a0, a1]
                default:
                    var tmp = [JeffJSValue](repeating: .undefined, count: argc)
                    for i in stride(from: argc - 1, through: 0, by: -1) { tmp[i] = pop() }
                    cmArgs = tmp
                }
                let cmFuncVal = pop()
                let cmThisObj = pop()
                let cmResult: JeffJSValue
                if let cmCallObj = cmFuncVal.obj,
                   case .bytecodeFunc(let cmFbOpt2, _, _) = cmCallObj.payload,
                   let cmFastFb2 = cmFbOpt2, !cmFastFb2.isGenerator, !cmFastFb2.isAsyncFunc {
                    cmResult = JeffJSInterpreter.callInternal(ctx: ctx, funcObj: cmFuncVal,
                                                              thisVal: cmThisObj, args: cmArgs, flags: 0)
                } else {
                    cmResult = ctx.callFunction(cmFuncVal, thisVal: cmThisObj, args: cmArgs)
                }
                if cmResult.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(cmResult)
                pc += 3

            case .tail_call:
                let tcArgc = Int(readU16(bc, pc + 1))
                let tcArgs: [JeffJSValue]
                switch tcArgc {
                case 0:
                    tcArgs = []
                case 1:
                    let a0 = pop()
                    tcArgs = [a0]
                case 2:
                    let a1 = pop(); let a0 = pop()
                    tcArgs = [a0, a1]
                default:
                    var tmp = [JeffJSValue](repeating: .undefined, count: tcArgc)
                    for i in stride(from: tcArgc - 1, through: 0, by: -1) { tmp[i] = pop() }
                    tcArgs = tmp
                }
                let tcFuncVal = pop()
                ctx.currentFrame = frame.prevFrame
                retVal = ctx.callFunction(tcFuncVal, thisVal: .undefined, args: tcArgs)
                break dispatchLoop

            case .tail_call_method:
                let tcmArgc = Int(readU16(bc, pc + 1))
                let tcmArgs: [JeffJSValue]
                switch tcmArgc {
                case 0:
                    tcmArgs = []
                case 1:
                    let a0 = pop()
                    tcmArgs = [a0]
                case 2:
                    let a1 = pop(); let a0 = pop()
                    tcmArgs = [a0, a1]
                default:
                    var tmp = [JeffJSValue](repeating: .undefined, count: tcmArgc)
                    for i in stride(from: tcmArgc - 1, through: 0, by: -1) { tmp[i] = pop() }
                    tcmArgs = tmp
                }
                let tcmFuncVal = pop()
                let tcmThisObj = pop()
                ctx.currentFrame = frame.prevFrame
                retVal = ctx.callFunction(tcmFuncVal, thisVal: tcmThisObj, args: tcmArgs)
                break dispatchLoop

            case .call_constructor:
                JeffJSInterpreter.lastGetFieldAtom = 0
                let argc = Int(readU16(bc, pc + 1))
                var callArgs = [JeffJSValue](repeating: .undefined, count: argc)
                for i in stride(from: argc - 1, through: 0, by: -1) { callArgs[i] = pop() }
                let newTarget = pop()
                let funcVal = pop()
                let result = ctx.callConstructor(funcVal, newTarget: newTarget, args: callArgs)
                if result.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(result)
                pc += 3

            case .array_from:
                let count = Int(readU16(bc, pc + 1))
                var items = [JeffJSValue]()
                for _ in 0..<count { items.insert(pop(), at: 0) }
                // The parser emits an orphaned OP_object before every
                // array literal.  Pop it so the stack stays balanced.
                // Only pop if it looks like the parser's empty sentinel
                // (a plain object with no properties).
                if sp > 0 {
                    let below = peek()
                    if below.isObject, let obj = below.toObject(),
                       obj.classID == JeffJSClassID.object.rawValue,
                       obj.prop.isEmpty {
                        let _ = pop()
                    }
                }
                let arr = ctx.newArrayFrom(items)
                push(arr)
                pc += 3

            case .apply:
                let _ = readU16(bc, pc + 1)
                let argsArray = pop()
                let funcVal = pop()
                let thisObj = pop()
                let callArgs = ctx.arrayToArgs(argsArray)
                let result = ctx.callFunction(funcVal, thisVal: thisObj, args: callArgs)
                if result.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(result)
                pc += 3

            case .apply_constructor:
                let _ = readU16(bc, pc + 1)
                let argsArray = pop()
                let newTarget = pop()
                let funcVal = pop()
                let callArgs = ctx.arrayToArgs(argsArray)
                let result = ctx.callConstructor(funcVal, newTarget: newTarget, args: callArgs)
                if result.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(result)
                pc += 3

            case .return_:
                let returnValue = pop()
                if !inlineCallStack.isEmpty {
                    // ── Inline return: restore caller's frame ──
                    // 1. Sync buf → frame and detach live var-refs
                    syncBufToFrame()
                    for vr in frame.liveVarRefs {
                        if !vr.isDetached {
                            if vr.isArg {
                                let ai = Int(vr.varIdx)
                                vr.value = ai < frame.argBuf.count ? frame.argBuf[ai].dupValue() : .undefined
                            } else {
                                let vi = Int(vr.varIdx)
                                vr.value = vi < frame.varBuf.count ? frame.varBuf[vi].dupValue() : .undefined
                            }
                            vr.isDetached = true
                            vr.parentFrame = nil
                        }
                    }
                    // 2. Restore previous frame pointer and release callee frame
                    ctx.currentFrame = frame.prevFrame
                    JeffJSStackFrame.release(frame)
                    // 2b. Release callee's buf to pool
                    JeffJSInterpreter.releaseBuf(buf, capacity: bufCapacity)
                    // 3. Pop saved caller state
                    let saved = inlineCallStack.removeLast()
                    pc = saved.pc
                    sp = saved.sp
                    buf = saved.buf
                    bufCapacity = saved.bufCapacity
                    varBase = saved.varBase
                    spBase = saved.spBase
                    bc = saved.bc
                    bcLen = saved.bcLen
                    fb = saved.fb
                    frame = saved.frame
                    varRefs = saved.varRefs
                    mFuncObj = saved.funcObj
                    mFlags = saved.flags
                    // 4. Push return value onto caller's stack
                    push(returnValue)
                    continue dispatchLoop
                } else {
                    retVal = returnValue
                    break dispatchLoop
                }

            case .return_undef:
                if !inlineCallStack.isEmpty {
                    // ── Inline return undefined: restore caller's frame ──
                    syncBufToFrame()
                    for vr in frame.liveVarRefs {
                        if !vr.isDetached {
                            if vr.isArg {
                                let ai = Int(vr.varIdx)
                                vr.value = ai < frame.argBuf.count ? frame.argBuf[ai].dupValue() : .undefined
                            } else {
                                let vi = Int(vr.varIdx)
                                vr.value = vi < frame.varBuf.count ? frame.varBuf[vi].dupValue() : .undefined
                            }
                            vr.isDetached = true
                            vr.parentFrame = nil
                        }
                    }
                    ctx.currentFrame = frame.prevFrame
                    JeffJSStackFrame.release(frame)
                    JeffJSInterpreter.releaseBuf(buf, capacity: bufCapacity)
                    let saved = inlineCallStack.removeLast()
                    pc = saved.pc
                    sp = saved.sp
                    buf = saved.buf
                    bufCapacity = saved.bufCapacity
                    varBase = saved.varBase
                    spBase = saved.spBase
                    bc = saved.bc
                    bcLen = saved.bcLen
                    fb = saved.fb
                    frame = saved.frame
                    varRefs = saved.varRefs
                    mFuncObj = saved.funcObj
                    mFlags = saved.flags
                    push(.undefined)
                    continue dispatchLoop
                } else {
                    retVal = .undefined
                    break dispatchLoop
                }

            case .check_ctor_return:
                let val = peek()
                if val.isObject {
                    push(.newBool(true))
                } else if val.isUndefined {
                    push(.newBool(false))
                } else {
                    _ = ctx.throwTypeError(message: "derived constructor must return object or undefined")
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 1

            case .check_ctor:
                if mFlags & JS_CALL_FLAG_CONSTRUCTOR == 0 {
                    _ = ctx.throwTypeError(message: "class constructor cannot be called without 'new'")
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 1

            case .init_ctor:
                // Create a new empty object using the constructor's .prototype property
                // as its [[Prototype]]. In QuickJS this reads new.target's .prototype,
                // creates a new object with that proto, and pushes it as `this`.
                let ctorFunc = peek() // the constructor function is on the stack
                let protoVal = ctx.getProperty(obj: ctorFunc,
                                                atom: JeffJSAtomID.JS_ATOM_prototype.rawValue)
                let newObj: JeffJSValue
                if protoVal.isObject {
                    newObj = ctx.newObjectProto(proto: protoVal)
                } else {
                    // If .prototype is not an object, use the default Object.prototype
                    newObj = ctx.newObject()
                }
                push(newObj)
                pc += 1

            case .check_brand:
                let brand = peekAt(0)
                let obj = peekAt(1)
                if !ctx.checkBrand(obj: obj, brand: brand) {
                    _ = ctx.throwTypeError(message: "private member access denied")
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 1

            case .add_brand:
                let brand = pop()
                let obj = pop()
                ctx.addBrand(obj: obj, brand: brand)
                pc += 1

            case .return_async:
                let val = pop()
                // Return the actual value so callFunction can wrap it in
                // Promise.resolve(). Previously this returned .undefined,
                // discarding the async function's return value.
                retVal = val
                break dispatchLoop

            case .throw_:
                let val = pop()
                ctx.throwValue(val)
                retVal = .exception
                break dispatchLoop

            case .throw_error:
                let atom = readU32(bc, pc + 1)
                let errType = readU8(bc, pc + 5)
                let msg = ctx.atomToSwiftString(atom)
                ctx.throwErrorFromType(errType: Int(errType), msg: msg)
                retVal = .exception
                break dispatchLoop

            case .eval:
                let argc = Int(readU16(bc, pc + 1))
                let scope = Int(readU16(bc, pc + 3))
                var evalArgs = [JeffJSValue]()
                for _ in 0..<argc { evalArgs.insert(pop(), at: 0) }
                let result = ctx.evalDirect(args: evalArgs, scope: scope, frame: frame)
                if result.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(result)
                pc += 5

            case .apply_eval:
                let argc = Int(readU16(bc, pc + 1))
                var evalArgs = [JeffJSValue]()
                for _ in 0..<argc { evalArgs.insert(pop(), at: 0) }
                let result = ctx.evalDirect(args: evalArgs, scope: 0, frame: frame)
                if result.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(result)
                pc += 3

            case .regexp:
                let flagsVal = pop()
                let patternVal = pop()
                let result = ctx.newRegExp(pattern: patternVal, flags: flagsVal)
                if result.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(result)
                pc += 1

            case .get_super:
                // Get the super (parent) constructor.
                // Pop a value from the stack to keep the nPop=1 balance,
                // but always resolve the parent constructor from
                // frame.curFunc.__proto__ (the class inheritance chain).
                let _ = pop()   // discard the dummy value
                let result = ctx.getSuperConstructor(obj: frame.curFunc)
                if result.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(result)
                pc += 1

            case .import_:
                let _ = readU8(bc, pc + 1)
                let specifier = pop()
                let result = ctx.dynamicImport(specifier: specifier)
                if result.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(result)
                pc += 2

            // -----------------------------------------------------------------
            // Global/scoped Variable Access
            // -----------------------------------------------------------------

            case .check_var:
                let atom = readU32(bc, pc + 1)
                let exists = ctx.checkGlobalVar(atom: atom)
                push(.newBool(exists))
                pc += 5

            case .get_var_undef:
                let atom = readU32(bc, pc + 1)
                let val = ctx.getGlobalVar(atom: atom, throwRefError: false)
                push(val)
                pc += 5

            case .get_var:
                let atom = readU32(bc, pc + 1)
                // typeof on an undeclared variable must not throw ReferenceError
                // (ECMAScript spec: typeof returns "undefined" for unresolvable refs).
                // The parser emits get_var + typeof_ (or typeof_is_undefined/
                // typeof_is_function after peephole optimization). Look ahead at the
                // next opcode to suppress the ReferenceError when appropriate.
                let nextByte: UInt8 = (pc + 5 < bcLen) ? bc[pc + 5] : 0
                let nextIsTypeof = nextByte == UInt8(JeffJSOpcode.typeof_.rawValue & 0xFF)
                    || nextByte == UInt8(JeffJSOpcode.typeof_is_undefined.rawValue & 0xFF)
                    || nextByte == UInt8(JeffJSOpcode.typeof_is_function.rawValue & 0xFF)
                let val = ctx.getGlobalVar(atom: atom, throwRefError: !nextIsTypeof)
                if val.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(val)
                pc += 5

            case .put_var:
                let atom = readU32(bc, pc + 1)
                // Chained assignment: if next opcode is also a store, keep value on stack
                let chainedPutVar = isStoreOpcode(bc, pc + 5, bcLen)
                let val = chainedPutVar ? peek().dupValue() : pop()
                let ok = ctx.putGlobalVar(atom: atom, val: val, flags: 0)
                if !ok {
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 5

            case .put_var_init:
                let atom = readU32(bc, pc + 1)
                let val = pop()
                let ok = ctx.putGlobalVar(atom: atom, val: val, flags: JS_PROP_CONFIGURABLE)
                if !ok {
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 5

            case .put_var_strict:
                let atom = readU32(bc, pc + 1)
                let val = pop()
                let _ = pop() // ref object (unused in global mode)
                let ok = ctx.putGlobalVar(atom: atom, val: val, flags: JS_PROP_HAS_VALUE | JS_PROP_THROW)
                if !ok {
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 5

            case .get_ref_value:
                let prop = pop()
                let obj = pop()
                let val = ctx.getPropertyValue(obj: obj, prop: prop)
                if val.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(obj)
                push(prop)
                push(val)
                pc += 1

            case .put_ref_value:
                let val = pop()
                let prop = pop()
                let obj = pop()
                let ok = ctx.setPropertyValue(obj: obj, prop: prop, val: val)
                if !ok {
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 1

            // -----------------------------------------------------------------
            // Variable Definitions
            // -----------------------------------------------------------------

            case .define_var:
                let atom = readU32(bc, pc + 1)
                let defFlags = Int(readU8(bc, pc + 5))
                let ok = ctx.defineGlobalVar(atom: atom, flags: defFlags)
                if !ok {
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 6

            case .check_define_var:
                let atom = readU32(bc, pc + 1)
                let defFlags = Int(readU8(bc, pc + 5))
                let ok = ctx.checkDefineGlobalVar(atom: atom, flags: defFlags)
                if !ok {
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 6

            case .define_func:
                let atom = readU32(bc, pc + 1)
                let defFlags = Int(readU8(bc, pc + 5))
                let funcVal = pop()
                let ok = ctx.defineGlobalFunc(atom: atom, val: funcVal, flags: defFlags)
                if !ok {
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 6

            // -----------------------------------------------------------------
            // Property Access
            // -----------------------------------------------------------------

            case .get_field:
                let atom = readU32(bc, pc + 1)
                JeffJSInterpreter.prevGetFieldAtom = JeffJSInterpreter.lastGetFieldAtom
                JeffJSInterpreter.lastGetFieldAtom = atom
                let obj = pop()
                // Save receiver for the next `call` opcode — when transformMethodCalls
                // fails to convert get_field+call to get_field2+call_method (e.g. due
                // to ternary/short-circuit args), `call` uses this as `this`.
                frame.lastGetFieldReceiver = obj.dupValue()
                // Early check: property access on null/undefined with location info
                if obj.isNullOrUndefined {
                    let propName = ctx.rt.atomToString(atom) ?? "?"
                    let compiled = fb as? JeffJSFunctionBytecodeCompiled
                    let fnameAtom = compiled?.debugFilenameAtom ?? 0
                    let fname = fnameAtom > 0 ? (ctx.rt.atomToString(fnameAtom) ?? "?") : (fb.fileName?.toSwiftString() ?? "?")
                    let line = compiled?.lineForPC(pc) ?? fb.lineNum
                    // Walk the call stack for a full trace
                    var trace: [String] = ["\(fname):\(line) pc=\(pc)"]
                    var walkFrame = frame.prevFrame
                    while let f = walkFrame, trace.count < 8 {
                        if let fObj = f.curFunc.toObject(),
                           case .bytecodeFunc(let wfb, _, _) = fObj.payload,
                           let wf = wfb {
                            let wCompiled = wf as? JeffJSFunctionBytecodeCompiled
                            let wFnameAtom = wCompiled?.debugFilenameAtom ?? 0
                            let wFname = wFnameAtom > 0 ? (ctx.rt.atomToString(wFnameAtom) ?? "?") : (wf.fileName?.toSwiftString() ?? "?")
                            let wLine = wCompiled?.lineForPC(f.curPC) ?? wf.lineNum
                            trace.append("\(wFname):\(wLine) pc=\(f.curPC)")
                        }
                        walkFrame = f.prevFrame
                    }
                    _ = ctx.throwTypeError(message: "Cannot read properties of \(obj.isNull ? "null" : "undefined") (reading '\(propName)') at \(fname):\(line)")
                    retVal = .exception; break dispatchLoop
                }
                // Inline cache fast path: shape-matched direct property read
                if let jsObj = obj.obj, let shape = jsObj.shape {
                    let ic = fb.ic
                    if let ic = ic {
                        let entry = ic.lookup(pc)
                        if entry.pc == pc,
                           entry.shapePtr == UnsafeRawPointer(Unmanaged.passUnretained(shape).toOpaque()),
                           entry.propOffset >= 0, entry.propOffset < jsObj.prop.count {
                            if case .value(let v) = jsObj.prop[entry.propOffset] {
                                push(v.dupValue())
                                pc += 5
                                continue dispatchLoop
                            }
                        }
                    }
                    // IC miss: full lookup + cache update
                    let val = ctx.getProperty(obj: obj, atom: atom)
                    if val.isException { retVal = .exception; break dispatchLoop }
                    push(val)
                    if let propIdx = findShapeProperty(shape, atom) {
                        fb.getIC().update(pc, shape: shape, propOffset: propIdx)
                    }
                } else {
                    let val = ctx.getProperty(obj: obj, atom: atom)
                    if val.isException { retVal = .exception; break dispatchLoop }
                    push(val)
                }
                pc += 5

            case .get_field2:
                let atom = readU32(bc, pc + 1)
                let obj = peek()
                // ── Array.prototype.push super-instruction ──────────────
                // Fuses get_field2("push") + <arg> + call_method(1) into
                // a single dispatch. Avoids prototype lookup, function
                // identity check, and two extra opcode dispatches.
                if atom == JSPredefinedAtom.push.rawValue,
                   ctx.arrayProtoPushObj != nil,
                   let jsObj = obj.obj,
                   jsObj.classID == JeffJSClassID.array.rawValue {
                    // Peek ahead: get_field2 is 5 bytes. Check what follows.
                    let nextPc = pc + 5
                    if nextPc < bcLen {
                        let nextByte = bc[nextPc]
                        var argVal: JeffJSValue? = nil
                        var argSize = 0
                        // Helper: convert opcode enum to UInt8 for bytecode comparison
                        let _getLoc   = UInt8(truncatingIfNeeded: JeffJSOpcode.get_loc.rawValue)
                        let _getLoc8  = UInt8(truncatingIfNeeded: JeffJSOpcode.get_loc8.rawValue)
                        let _getLoc0  = UInt8(truncatingIfNeeded: JeffJSOpcode.get_loc0.rawValue)
                        let _getLoc1  = UInt8(truncatingIfNeeded: JeffJSOpcode.get_loc1.rawValue)
                        let _getLoc2  = UInt8(truncatingIfNeeded: JeffJSOpcode.get_loc2.rawValue)
                        let _getLoc3  = UInt8(truncatingIfNeeded: JeffJSOpcode.get_loc3.rawValue)
                        let _getArg   = UInt8(truncatingIfNeeded: JeffJSOpcode.get_arg.rawValue)
                        let _pushI32  = UInt8(truncatingIfNeeded: JeffJSOpcode.push_i32.rawValue)
                        let _push0    = UInt8(truncatingIfNeeded: JeffJSOpcode.push_0.rawValue)
                        let _push1    = UInt8(truncatingIfNeeded: JeffJSOpcode.push_1.rawValue)
                        let _pushI8   = UInt8(truncatingIfNeeded: JeffJSOpcode.push_i8.rawValue)
                        let _pushI16  = UInt8(truncatingIfNeeded: JeffJSOpcode.push_i16.rawValue)
                        let _callMeth = UInt8(truncatingIfNeeded: JeffJSOpcode.call_method.rawValue)
                        // Recognize common arg opcodes (including short variants)
                        if nextByte == _getLoc0 {
                            argVal = buf[varBase]; argSize = 1
                        } else if nextByte == _getLoc1 {
                            argVal = buf[varBase + 1]; argSize = 1
                        } else if nextByte == _getLoc2 {
                            argVal = buf[varBase + 2]; argSize = 1
                        } else if nextByte == _getLoc3 {
                            argVal = buf[varBase + 3]; argSize = 1
                        } else if nextByte == _getLoc8, nextPc + 1 < bcLen {
                            let locIdx = Int(bc[nextPc + 1])
                            argVal = buf[varBase + locIdx]; argSize = 2
                        } else if nextByte == _getLoc, nextPc + 2 < bcLen {
                            let locIdx = Int(readU16(bc, nextPc + 1))
                            argVal = buf[varBase + locIdx]; argSize = 3
                        } else if nextByte == _getArg, nextPc + 1 < bcLen {
                            let argIdx = Int(bc[nextPc + 1])
                            if argIdx < varBase { argVal = buf[argIdx]; argSize = 2 }
                        } else if nextByte == UInt8(truncatingIfNeeded: JeffJSOpcode.get_var.rawValue),
                                  nextPc + 4 < bcLen {
                            // get_var(atom) — 5 bytes
                            let varAtom = readU32(bc, nextPc + 1)
                            let v = ctx.getGlobalVar(atom: varAtom, throwRefError: false)
                            if !v.isException {
                                argVal = v
                                argSize = 5
                            }
                        } else if nextByte == _pushI32, nextPc + 4 < bcLen {
                            let val = Int32(bitPattern: readU32(bc, nextPc + 1))
                            argVal = .newInt32(val)
                            argSize = 5
                        } else if nextByte == _push0 {
                            argVal = .newInt32(0)
                            argSize = 1
                        } else if nextByte == _push1 {
                            argVal = .newInt32(1)
                            argSize = 1
                        } else if nextByte == _pushI8, nextPc + 1 < bcLen {
                            argVal = .newInt32(Int32(Int8(bitPattern: bc[nextPc + 1])))
                            argSize = 2
                        } else if nextByte == _pushI16, nextPc + 2 < bcLen {
                            let v = Int16(bitPattern: UInt16(bc[nextPc + 1]) | (UInt16(bc[nextPc + 2]) << 8))
                            argVal = .newInt32(Int32(v))
                            argSize = 3
                        }
                        // Check that call_method(1) follows the arg
                        if let arg = argVal, argSize > 0 {
                            let cmPc = nextPc + argSize
                            if cmPc + 2 < bcLen,
                               bc[cmPc] == _callMeth,
                               readU16(bc, cmPc + 1) == 1 {
                                // All conditions met — do the push inline.
                                // prop[0] check for length property
                                if jsObj.prop.count > 0,
                                   let shape = jsObj.shape,
                                   shape.prop.count > 0,
                                   shape.prop[0].atom == JeffJSAtomID.JS_ATOM_length.rawValue {
                                    let newCount = jsObj.asClass.fastArrayPush(arg)
                                    if newCount > 0 {
                                        jsObj.asClass.prop[0] = .value(.newInt32(Int32(newCount)))
                                        // Pop the array (from peek) and push the new length
                                        let _ = pop()
                                        push(.newInt32(Int32(newCount)))
                                        pc = cmPc + 3  // skip past call_method(1)
                                        continue dispatchLoop
                                    }
                                }
                            }
                        }
                    }
                    // Fallback: just resolve push function quickly
                    let pushVal = JeffJSValue.makeObject(ctx.arrayProtoPushObj!)
                    push(pushVal.dupValue())
                    pc += 5
                    continue dispatchLoop
                }
                // Inline cache fast path
                if let jsObj = obj.obj, let shape = jsObj.shape {
                    let ic = fb.ic
                    if let ic = ic {
                        let entry = ic.lookup(pc)
                        if entry.pc == pc,
                           entry.shapePtr == UnsafeRawPointer(Unmanaged.passUnretained(shape).toOpaque()),
                           entry.propOffset >= 0, entry.propOffset < jsObj.prop.count {
                            if case .value(let v) = jsObj.prop[entry.propOffset] {
                                push(v.dupValue())
                                pc += 5
                                continue dispatchLoop
                            }
                        }
                    }
                    // IC miss: full lookup + cache update
                    let val = ctx.getProperty(obj: obj, atom: atom)
                    if val.isException { retVal = .exception; break dispatchLoop }
                    push(val)
                    if let propIdx = findShapeProperty(shape, atom) {
                        fb.getIC().update(pc, shape: shape, propOffset: propIdx)
                    }
                } else {
                    let val = ctx.getProperty(obj: obj, atom: atom)
                    if val.isException { retVal = .exception; break dispatchLoop }
                    push(val)
                }
                pc += 5

            case .put_field:
                let atom = readU32(bc, pc + 1)
                let val = pop()
                let obj = pop()
                // Inline cache fast path: shape-matched direct property write
                if let jsObj = obj.obj, let shape = jsObj.shape {
                    let ic = fb.ic
                    if let ic = ic {
                        let entry = ic.lookup(pc)
                        if entry.pc == pc,
                           entry.shapePtr == UnsafeRawPointer(Unmanaged.passUnretained(shape).toOpaque()),
                           entry.propOffset >= 0, entry.propOffset < jsObj.prop.count {
                            // Must verify writable flag — defineProperty can change flags in-place
                            // on the same shape, so shape identity alone isn't sufficient.
                            if case .value = jsObj.prop[entry.propOffset],
                               entry.propOffset < shape.prop.count,
                               shape.prop[entry.propOffset].flags.contains(.writable) {
                                jsObj.asClass.prop[entry.propOffset] = .value(val)
                                pc += 5
                                continue dispatchLoop
                            }
                        }
                    }
                    // IC miss: full path + cache update
                    let ok = ctx.setProperty(obj: obj, atom: atom, value: val)
                    if ok < 0 { retVal = .exception; break dispatchLoop }
                    // Re-read shape after setProperty — it may have transitioned
                    if let curShape = jsObj.shape,
                       let propIdx = findShapeProperty(curShape, atom) {
                        fb.getIC().update(pc, shape: curShape, propOffset: propIdx)
                    }
                } else {
                    let ok = ctx.setProperty(obj: obj, atom: atom, value: val)
                    if ok < 0 { retVal = .exception; break dispatchLoop }
                }
                pc += 5

            case .get_private_field:
                let field = pop()
                let obj = pop()
                let val = ctx.getPrivateField(obj: obj, field: field)
                if val.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(val)
                pc += 1

            case .put_private_field:
                let val = pop()
                let field = pop()
                let obj = pop()
                let ok = ctx.putPrivateField(obj: obj, field: field, val: val)
                if !ok {
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 1

            case .define_private_field:
                let val = pop()
                let field = pop()
                let obj = pop()
                ctx.definePrivateField(obj: obj, field: field, val: val)
                pc += 1

            // -----------------------------------------------------------------
            // Array Element Access
            // -----------------------------------------------------------------

            case .get_array_el:
                let key = pop()
                let obj = pop()
                let val = ctx.getPropertyValue(obj: obj, prop: key)
                if val.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(val)
                pc += 1

            case .get_array_el2:
                let key = pop()
                let obj = peek()
                let val = ctx.getPropertyValue(obj: obj, prop: key)
                if val.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(val)
                pc += 1

            case .put_array_el:
                let val = pop()
                let key = pop()
                let obj = pop()
                let ok = ctx.setPropertyValue(obj: obj, prop: key, val: val)
                if !ok {
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 1

            // -----------------------------------------------------------------
            // Super Property Access
            // -----------------------------------------------------------------

            case .get_super_value:
                let key = pop()
                let obj = pop()
                let thisObj = pop()
                let val = ctx.getSuperProperty(thisObj: thisObj, obj: obj, key: key)
                if val.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(val)
                pc += 1

            case .put_super_value:
                let val = pop()
                let key = pop()
                let obj = pop()
                let thisObj = pop()
                let ok = ctx.putSuperProperty(thisObj: thisObj, obj: obj, key: key, val: val)
                if !ok {
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 1

            // -----------------------------------------------------------------
            // Object/Class Definition Helpers
            // -----------------------------------------------------------------

            case .define_field:
                let atom = readU32(bc, pc + 1)
                let val = pop()
                let obj = peek()
                let ok = ctx.defineField(obj: obj, atom: atom, val: val)
                if !ok {
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 5

            case .set_name:
                let atom = readU32(bc, pc + 1)
                let val = peek()
                ctx.setFunctionName(val, atom: atom)
                pc += 5

            case .set_name_computed:
                let key = pop()
                let val = peek()
                ctx.setFunctionNameComputed(val, key: key)
                pc += 1

            case .set_proto:
                let proto = pop()
                let obj = peek()
                let ok = ctx.setPrototypeOf(obj: obj, proto: proto)
                if !ok {
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 1

            case .set_home_object:
                let homeObj = peekAt(0)
                let funcVal = peekAt(1)
                ctx.setHomeObject(funcVal: funcVal, homeObj: homeObj)
                pc += 1

            case .define_array_el:
                let val = pop()
                let idx = pop()
                let obj = peek()
                let nextIdx = ctx.defineArrayElement(obj: obj, idx: idx, val: val)
                push(nextIdx)
                pc += 1

            case .append:
                let val = pop()
                let obj = peekAt(0)
                ctx.appendToArray(obj: obj, val: val)
                pc += 1

            case .copy_data_properties:
                let mask = Int(readU8(bc, pc + 1))
                let excludeList = (mask > 0) ? pop() : .undefined
                let source = pop()
                let target = peek()
                let ok = ctx.copyDataProperties(target: target, source: source,
                                                 excludeList: excludeList)
                if !ok {
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 2

            case .define_method:
                let atom = readU32(bc, pc + 1)
                let methodFlags = Int(readU8(bc, pc + 5))
                let funcVal = pop()
                let obj = peek()
                let ok = ctx.defineMethod(obj: obj, atom: atom, funcVal: funcVal,
                                           flags: methodFlags)
                if !ok {
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 6

            case .define_method_computed:
                let methodFlags = Int(readU8(bc, pc + 1))
                let funcVal = pop()
                let key = pop()
                let obj = peek()
                let ok = ctx.defineMethodComputed(obj: obj, key: key, funcVal: funcVal,
                                                   flags: methodFlags)
                if !ok {
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 2

            case .define_class:
                let atom = readU32(bc, pc + 1)
                let classFlags = Int(readU8(bc, pc + 5))
                let heritage = pop()
                let ctorFunc = pop()
                let (ctor, proto) = ctx.defineClass(atom: atom, flags: classFlags,
                                                      heritage: heritage, ctorFunc: ctorFunc)
                if ctor.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(ctor)
                push(proto)
                pc += 6

            case .define_class_computed:
                // QuickJS: ctor heritage key -> ctor proto key
                // nPop=3, nPush=3: the computed key is preserved on top.
                let classFlags = Int(readU8(bc, pc + 1))
                let key = pop()
                let heritage = pop()
                let ctorFunc = pop()
                let (ctor, proto) = ctx.defineClassComputed(key: key, flags: classFlags,
                                                             heritage: heritage,
                                                             ctorFunc: ctorFunc)
                if ctor.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(ctor)
                push(proto)
                push(key)
                pc += 2

            // -----------------------------------------------------------------
            // Local Variable Access
            // -----------------------------------------------------------------

            case .get_loc:
                let idx = Int(readU16(bc, pc + 1))
                push(buf[varBase + idx].dupValue())
                pc += 3

            case .put_loc:
                let idx = Int(readU16(bc, pc + 1))
                let oldPutLoc = buf[varBase + idx]
                // Chained assignment: if next opcode is also a store, keep value on stack
                if isStoreOpcode(bc, pc + 3, bcLen) {
                    buf[varBase + idx] = peek().dupValue()
                } else {
                    buf[varBase + idx] = pop()
                }
                oldPutLoc.freeValue()
                pc += 3

            case .set_loc:
                let idx = Int(readU16(bc, pc + 1))
                let oldSetLoc = buf[varBase + idx]
                buf[varBase + idx] = peek().dupValue()
                oldSetLoc.freeValue()
                pc += 3

            // Short local access
            case .get_loc8:
                let idx = Int(readU8(bc, pc + 1))
                push(buf[varBase + idx].dupValue())
                pc += 2

            case .put_loc8:
                let idx = Int(readU8(bc, pc + 1))
                let oldPutLoc8 = buf[varBase + idx]
                if isStoreOpcode(bc, pc + 2, bcLen) {
                    buf[varBase + idx] = peek().dupValue()
                } else {
                    buf[varBase + idx] = pop()
                }
                oldPutLoc8.freeValue()
                pc += 2

            case .set_loc8:
                let idx = Int(readU8(bc, pc + 1))
                let oldSetLoc8 = buf[varBase + idx]
                buf[varBase + idx] = peek().dupValue()
                oldSetLoc8.freeValue()
                pc += 2

            case .get_loc0: push(buf[varBase].dupValue()); pc += 1
            case .get_loc1: push(buf[varBase + 1].dupValue()); pc += 1
            case .get_loc2: push(buf[varBase + 2].dupValue()); pc += 1
            case .get_loc3: push(buf[varBase + 3].dupValue()); pc += 1

            case .put_loc0:
                do { let old = buf[varBase]; if isStoreOpcode(bc, pc + 1, bcLen) { buf[varBase] = peek().dupValue() } else { buf[varBase] = pop() }; old.freeValue() }
                pc += 1
            case .put_loc1:
                do { let old = buf[varBase + 1]; if isStoreOpcode(bc, pc + 1, bcLen) { buf[varBase + 1] = peek().dupValue() } else { buf[varBase + 1] = pop() }; old.freeValue() }
                pc += 1
            case .put_loc2:
                do { let old = buf[varBase + 2]; if isStoreOpcode(bc, pc + 1, bcLen) { buf[varBase + 2] = peek().dupValue() } else { buf[varBase + 2] = pop() }; old.freeValue() }
                pc += 1
            case .put_loc3:
                do { let old = buf[varBase + 3]; if isStoreOpcode(bc, pc + 1, bcLen) { buf[varBase + 3] = peek().dupValue() } else { buf[varBase + 3] = pop() }; old.freeValue() }
                pc += 1

            case .set_loc0: do { let old = buf[varBase]; buf[varBase] = peek().dupValue(); old.freeValue() }; pc += 1
            case .set_loc1: do { let old = buf[varBase + 1]; buf[varBase + 1] = peek().dupValue(); old.freeValue() }; pc += 1
            case .set_loc2: do { let old = buf[varBase + 2]; buf[varBase + 2] = peek().dupValue(); old.freeValue() }; pc += 1
            case .set_loc3: do { let old = buf[varBase + 3]; buf[varBase + 3] = peek().dupValue(); old.freeValue() }; pc += 1

            // -----------------------------------------------------------------
            // Argument Access
            // -----------------------------------------------------------------

            case .get_arg:
                let idx = Int(readU16(bc, pc + 1))
                if idx < varBase {
                    push(buf[idx].dupValue())
                } else {
                    push(.undefined)
                }
                pc += 3

            case .put_arg:
                let idx = Int(readU16(bc, pc + 1))
                if isStoreOpcode(bc, pc + 3, bcLen) {
                    let val = peek().dupValue()
                    if idx < varBase { buf[idx] = val }
                } else {
                    let val = pop()
                    if idx < varBase { buf[idx] = val }
                }
                pc += 3

            case .set_arg:
                let idx = Int(readU16(bc, pc + 1))
                if idx < varBase {
                    buf[idx] = peek().dupValue()
                }
                pc += 3

            case .get_arg0: push(varBase > 0 ? buf[0].dupValue() : .undefined); pc += 1
            case .get_arg1: push(varBase > 1 ? buf[1].dupValue() : .undefined); pc += 1
            case .get_arg2: push(varBase > 2 ? buf[2].dupValue() : .undefined); pc += 1
            case .get_arg3: push(varBase > 3 ? buf[3].dupValue() : .undefined); pc += 1

            case .put_arg0:
                if isStoreOpcode(bc, pc + 1, bcLen) {
                    if varBase > 0 { buf[0] = peek().dupValue() }
                } else {
                    if varBase > 0 { buf[0] = pop() } else { let _ = pop() }
                }
                pc += 1
            case .put_arg1:
                if isStoreOpcode(bc, pc + 1, bcLen) {
                    if varBase > 1 { buf[1] = peek().dupValue() }
                } else {
                    if varBase > 1 { buf[1] = pop() } else { let _ = pop() }
                }
                pc += 1
            case .put_arg2:
                if isStoreOpcode(bc, pc + 1, bcLen) {
                    if varBase > 2 { buf[2] = peek().dupValue() }
                } else {
                    if varBase > 2 { buf[2] = pop() } else { let _ = pop() }
                }
                pc += 1
            case .put_arg3:
                if isStoreOpcode(bc, pc + 1, bcLen) {
                    if varBase > 3 { buf[3] = peek().dupValue() }
                } else {
                    if varBase > 3 { buf[3] = pop() } else { let _ = pop() }
                }
                pc += 1

            case .set_arg0: if varBase > 0 { buf[0] = peek().dupValue() }; pc += 1
            case .set_arg1: if varBase > 1 { buf[1] = peek().dupValue() }; pc += 1
            case .set_arg2: if varBase > 2 { buf[2] = peek().dupValue() }; pc += 1
            case .set_arg3: if varBase > 3 { buf[3] = peek().dupValue() }; pc += 1

            // -----------------------------------------------------------------
            // Closure Variable Access
            // -----------------------------------------------------------------

            case .get_var_ref:
                let idx = Int(readU16(bc, pc + 1))
                if idx < varRefs.count, let vr = varRefs[idx] {
                    let val = vr.isDetached ? vr.value.dupValue() : vr.pvalue.dupValue()
                    if JeffJSInterpreter.traceOpcodes {
                        print("[VAR_REF] get idx=\(idx) isDetached=\(vr.isDetached) isArg=\(vr.isArg) varIdx=\(vr.varIdx) val.bits=0x\(String(val.bits, radix: 16)) frame=\(vr.parentFrame != nil)")
                    }
                    push(val)
                } else {
                    if JeffJSInterpreter.traceOpcodes {
                        print("[VAR_REF] get idx=\(idx) OUT OF RANGE (count=\(varRefs.count))")
                    }
                    push(.undefined)
                }
                pc += 3

            case .put_var_ref:
                let idx = Int(readU16(bc, pc + 1))
                if isStoreOpcode(bc, pc + 3, bcLen) {
                    let val = peek().dupValue()
                    if idx < varRefs.count, let vr = varRefs[idx] {
                        if vr.isDetached { vr.value = val } else { vr.pvalue = val }
                    }
                } else {
                    let val = pop()
                    if idx < varRefs.count, let vr = varRefs[idx] {
                        if vr.isDetached { vr.value = val } else { vr.pvalue = val }
                    }
                }
                pc += 3

            case .set_var_ref:
                let idx = Int(readU16(bc, pc + 1))
                if idx < varRefs.count, let vr = varRefs[idx] {
                    let val = peek().dupValue()
                    if vr.isDetached { vr.value = val } else { vr.pvalue = val }
                }
                pc += 3

            case .get_var_ref0:
                if varRefs.count > 0, let vr = varRefs[0] {
                    let val = vr.isDetached ? vr.value.dupValue() : vr.pvalue.dupValue()
                    if JeffJSInterpreter.traceOpcodes {
                        print("[VAR_REF0] isDetached=\(vr.isDetached) isArg=\(vr.isArg) varIdx=\(vr.varIdx) val.bits=0x\(String(val.bits, radix: 16))/\(val.toInt32()) frame=\(vr.parentFrame != nil)")
                    }
                    push(val)
                } else {
                    if JeffJSInterpreter.traceOpcodes { print("[VAR_REF0] empty varRefs") }
                    push(.undefined)
                }
                pc += 1
            case .get_var_ref1: if varRefs.count > 1, let vr = varRefs[1] { push(vr.isDetached ? vr.value.dupValue() : vr.pvalue.dupValue()) } else { push(.undefined) }; pc += 1
            case .get_var_ref2: if varRefs.count > 2, let vr = varRefs[2] { push(vr.isDetached ? vr.value.dupValue() : vr.pvalue.dupValue()) } else { push(.undefined) }; pc += 1
            case .get_var_ref3: if varRefs.count > 3, let vr = varRefs[3] { push(vr.isDetached ? vr.value.dupValue() : vr.pvalue.dupValue()) } else { push(.undefined) }; pc += 1

            case .put_var_ref0: if varRefs.count > 0, let vr = varRefs[0] { let v = pop(); if vr.isDetached { vr.value = v } else { vr.pvalue = v } } else { let _ = pop() }; pc += 1
            case .put_var_ref1: if varRefs.count > 1, let vr = varRefs[1] { let v = pop(); if vr.isDetached { vr.value = v } else { vr.pvalue = v } } else { let _ = pop() }; pc += 1
            case .put_var_ref2: if varRefs.count > 2, let vr = varRefs[2] { let v = pop(); if vr.isDetached { vr.value = v } else { vr.pvalue = v } } else { let _ = pop() }; pc += 1
            case .put_var_ref3: if varRefs.count > 3, let vr = varRefs[3] { let v = pop(); if vr.isDetached { vr.value = v } else { vr.pvalue = v } } else { let _ = pop() }; pc += 1

            case .set_var_ref0: if varRefs.count > 0, let vr = varRefs[0] { let v = peek().dupValue(); if vr.isDetached { vr.value = v } else { vr.pvalue = v } }; pc += 1
            case .set_var_ref1: if varRefs.count > 1, let vr = varRefs[1] { let v = peek().dupValue(); if vr.isDetached { vr.value = v } else { vr.pvalue = v } }; pc += 1
            case .set_var_ref2: if varRefs.count > 2, let vr = varRefs[2] { let v = peek().dupValue(); if vr.isDetached { vr.value = v } else { vr.pvalue = v } }; pc += 1
            case .set_var_ref3: if varRefs.count > 3, let vr = varRefs[3] { let v = peek().dupValue(); if vr.isDetached { vr.value = v } else { vr.pvalue = v } }; pc += 1

            // -----------------------------------------------------------------
            // TDZ (Temporal Dead Zone) Operations
            // -----------------------------------------------------------------

            case .set_loc_uninitialized:
                let idx = Int(readU16(bc, pc + 1))
                buf[varBase + idx] = .uninitialized
                pc += 3

            case .get_loc_check:
                let idx = Int(readU16(bc, pc + 1))
                let val = buf[varBase + idx]
                if val.isUninitialized {
                    _ = ctx.throwReferenceError(message: "Cannot access variable before initialization")
                    retVal = .exception
                    break dispatchLoop
                }
                push(val.dupValue())
                pc += 3

            case .put_loc_check:
                let idx = Int(readU16(bc, pc + 1))
                let current = buf[varBase + idx]
                if current.isUninitialized {
                    _ = ctx.throwReferenceError(message: "Cannot access variable before initialization")
                    retVal = .exception
                    break dispatchLoop
                }
                if let compiled = fb0 as? JeffJSFunctionBytecodeCompiled,
                   idx < compiled.vardefs.count,
                   compiled.vardefs[idx].isConst {
                    _ = pop()
                    _ = ctx.throwTypeError(message: "Assignment to constant variable.")
                    retVal = .exception
                    break dispatchLoop
                }
                buf[varBase + idx] = pop()
                current.freeValue()
                pc += 3

            case .put_loc_check_init:
                let idx = Int(readU16(bc, pc + 1))
                let oldCheckInit = buf[varBase + idx]
                buf[varBase + idx] = pop()
                oldCheckInit.freeValue()
                pc += 3

            case .get_loc_checkthis:
                let idx = Int(readU16(bc, pc + 1))
                let val = buf[varBase + idx]
                if val.isUninitialized {
                    _ = ctx.throwReferenceError(message: "Must call super constructor before using 'this'")
                    retVal = .exception
                    break dispatchLoop
                }
                push(val.dupValue())
                pc += 3

            case .get_var_ref_check:
                let idx = Int(readU16(bc, pc + 1))
                if idx < varRefs.count, let vr = varRefs[idx] {
                    let val = vr.isDetached ? vr.value : vr.pvalue
                    if val.isUninitialized {
                        _ = ctx.throwReferenceError(message: "Cannot access variable before initialization")
                        retVal = .exception
                        break dispatchLoop
                    }
                    push(val.dupValue())
                } else {
                    push(.undefined)
                }
                pc += 3

            case .put_var_ref_check:
                let idx = Int(readU16(bc, pc + 1))
                let val = pop()
                if idx < varRefs.count, let vr = varRefs[idx] {
                    let current = vr.isDetached ? vr.value : vr.pvalue
                    if current.isUninitialized {
                        _ = ctx.throwReferenceError(message: "Cannot access variable before initialization")
                        retVal = .exception
                        break dispatchLoop
                    }
                    if let compiled = fb0 as? JeffJSFunctionBytecodeCompiled,
                       idx < compiled.closureVars.count,
                       compiled.closureVars[idx].isConst {
                        _ = ctx.throwTypeError(message: "Assignment to constant variable.")
                        retVal = .exception
                        break dispatchLoop
                    }
                    if vr.isDetached { vr.value = val } else { vr.pvalue = val }
                }
                pc += 3

            case .put_var_ref_check_init:
                let idx = Int(readU16(bc, pc + 1))
                let val = pop()
                if idx < varRefs.count, let vr = varRefs[idx] {
                    if vr.isDetached { vr.value = val } else { vr.pvalue = val }
                }
                pc += 3

            // -----------------------------------------------------------------
            // Closure Operations
            // -----------------------------------------------------------------

            case .close_loc:
                let idx = Int(readU16(bc, pc + 1))
                // Sync buf → frame so closeLexicalVar sees current var values
                syncBufToFrame()
                ctx.closeLexicalVar(frame: frame, idx: idx)
                pc += 3

            // -----------------------------------------------------------------
            // Control Flow
            // -----------------------------------------------------------------

            case .if_false:
                let val = pop()
                let offset = readI32(bc, pc + 1)
                let condResult = !JeffJSTypeConvert.toBool(val)
                val.freeValue()
                if condResult {
                    pc += 5 + Int(offset)
                    if offset < 0 {
                        ctx.interruptCounter -= 1
                        if ctx.interruptCounter <= 0 {
                            ctx.interruptCounter = JS_INTERRUPT_COUNTER_INIT
                            if ctx.checkInterrupt() { retVal = .exception; break dispatchLoop }
                        }
                    }
                } else {
                    pc += 5
                }

            case .if_true:
                let val = pop()
                let offset = readI32(bc, pc + 1)
                let condResult2 = JeffJSTypeConvert.toBool(val)
                val.freeValue()
                if condResult2 {
                    pc += 5 + Int(offset)
                    if offset < 0 {
                        ctx.interruptCounter -= 1
                        if ctx.interruptCounter <= 0 {
                            ctx.interruptCounter = JS_INTERRUPT_COUNTER_INIT
                            if ctx.checkInterrupt() { retVal = .exception; break dispatchLoop }
                        }
                    }
                } else {
                    pc += 5
                }

            case .goto_:
                let offset = readI32(bc, pc + 1)
                let gotoTarget = pc + 5 + Int(offset)
                if offset < 0 {
                    ctx.interruptCounter -= 1
                    if ctx.interruptCounter <= 0 {
                        ctx.interruptCounter = JS_INTERRUPT_COUNTER_INIT
                        if ctx.checkInterrupt() { retVal = .exception; break dispatchLoop }
                    }
                    // Trace block dispatch for hot loops
                    if let traceInfo = fb.traceBlocks?[gotoTarget] {
                        if traceInfo.isActive {
                            let resumePC = executeFastTrace(
                                bc: bc, bcLen: bcLen,
                                entryPC: traceInfo.entryPC, exitPC: traceInfo.exitPC,
                                buf: buf, varBase: varBase, sp: &sp, ctx: ctx,
                                cpool: fb.cpool,
                                stackLimit: bufCapacity
                            )
                            if resumePC == -1 { retVal = .exception; break dispatchLoop }
                            pc = resumePC
                            continue dispatchLoop
                        } else {
                            traceInfo.hitCount &+= 1
                            if traceInfo.hitCount >= UInt8(JeffJSConfig.traceHitThreshold) { traceInfo.isActive = true }
                        }
                    }
                }
                pc = gotoTarget

            case .if_false8:
                let val = pop()
                let offset = Int(readI8(bc, pc + 1))
                let condResult8f = !JeffJSTypeConvert.toBool(val)
                val.freeValue()
                if condResult8f {
                    pc += 2 + offset
                    if offset < 0 {
                        ctx.interruptCounter -= 1
                        if ctx.interruptCounter <= 0 {
                            ctx.interruptCounter = JS_INTERRUPT_COUNTER_INIT
                            if ctx.checkInterrupt() { retVal = .exception; break dispatchLoop }
                        }
                    }
                } else {
                    pc += 2
                }

            case .if_true8:
                let val = pop()
                let offset = Int(readI8(bc, pc + 1))
                let condResult8t = JeffJSTypeConvert.toBool(val)
                val.freeValue()
                if condResult8t {
                    pc += 2 + offset
                    if offset < 0 {
                        ctx.interruptCounter -= 1
                        if ctx.interruptCounter <= 0 {
                            ctx.interruptCounter = JS_INTERRUPT_COUNTER_INIT
                            if ctx.checkInterrupt() { retVal = .exception; break dispatchLoop }
                        }
                    }
                } else {
                    pc += 2
                }

            case .goto8:
                let offset = Int(readI8(bc, pc + 1))
                let goto8Target = pc + 2 + offset
                if offset < 0 {
                    ctx.interruptCounter -= 1
                    if ctx.interruptCounter <= 0 {
                        ctx.interruptCounter = JS_INTERRUPT_COUNTER_INIT
                        if ctx.checkInterrupt() { retVal = .exception; break dispatchLoop }
                    }
                    // Trace block dispatch for hot loops
                    if let traceInfo = fb.traceBlocks?[goto8Target] {
                        if traceInfo.isActive {
                            let resumePC = executeFastTrace(
                                bc: bc, bcLen: bcLen,
                                entryPC: traceInfo.entryPC, exitPC: traceInfo.exitPC,
                                buf: buf, varBase: varBase, sp: &sp, ctx: ctx,
                                cpool: fb.cpool,
                                stackLimit: bufCapacity
                            )
                            if resumePC == -1 { retVal = .exception; break dispatchLoop }
                            pc = resumePC
                            continue dispatchLoop
                        } else {
                            traceInfo.hitCount &+= 1
                            if traceInfo.hitCount >= UInt8(JeffJSConfig.traceHitThreshold) { traceInfo.isActive = true }
                        }
                    }
                }
                pc = goto8Target

            case .goto16:
                let offset = Int(readI16(bc, pc + 1))
                let goto16Target = pc + 3 + offset
                if offset < 0 {
                    ctx.interruptCounter -= 1
                    if ctx.interruptCounter <= 0 {
                        ctx.interruptCounter = JS_INTERRUPT_COUNTER_INIT
                        if ctx.checkInterrupt() { retVal = .exception; break dispatchLoop }
                    }
                    // Trace block dispatch for hot loops
                    if let traceInfo = fb.traceBlocks?[goto16Target] {
                        if traceInfo.isActive {
                            let resumePC = executeFastTrace(
                                bc: bc, bcLen: bcLen,
                                entryPC: traceInfo.entryPC, exitPC: traceInfo.exitPC,
                                buf: buf, varBase: varBase, sp: &sp, ctx: ctx,
                                cpool: fb.cpool,
                                stackLimit: bufCapacity
                            )
                            if resumePC == -1 { retVal = .exception; break dispatchLoop }
                            pc = resumePC
                            continue dispatchLoop
                        } else {
                            traceInfo.hitCount &+= 1
                            if traceInfo.hitCount >= UInt8(JeffJSConfig.traceHitThreshold) { traceInfo.isActive = true }
                        }
                    }
                }
                pc = goto16Target

            case .catch_:
                // Push the absolute address of the catch handler onto the value stack.
                // The offset is relative to the end of this 5-byte instruction.
                let offset = readI32(bc, pc + 1)
                let catchAddr = pc + 5 + Int(offset)
                push(.newCatchOffset(Int32(catchAddr)))
                pc += 5

            case .gosub:
                // Push return address (instruction after gosub) then jump to finally block.
                // The offset is relative to the end of this 5-byte instruction.
                let offset = readI32(bc, pc + 1)
                push(.newInt32(Int32(pc + 5))) // return address
                pc += 5 + Int(offset)

            case .ret:
                let addr = pop()
                let target = Int(addr.toInt32())
                if target <= pc {
                    ctx.interruptCounter -= 1
                    if ctx.interruptCounter <= 0 {
                        ctx.interruptCounter = JS_INTERRUPT_COUNTER_INIT
                        if ctx.checkInterrupt() { retVal = .exception; break dispatchLoop }
                    }
                }
                pc = target

            case .nip_catch:
                // Remove the catch handler (second from top) while keeping the
                // top-of-stack value.  QuickJS: sp[-2] = sp[-1]; sp--;
                if sp >= spBase + 2 {
                    buf[sp - 2] = buf[sp - 1]
                    sp -= 1
                } else if sp >= spBase + 1 {
                    sp -= 1
                }
                pc += 1

            // -----------------------------------------------------------------
            // Type Conversions
            // -----------------------------------------------------------------

            case .to_object:
                let val = pop()
                let obj = ctx.toObject(val)
                val.freeValue()
                if obj.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(obj)
                pc += 1

            case .to_propkey:
                let val = pop()
                let key = ctx.toPropertyKey(val)
                val.freeValue()
                if key.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(key)
                pc += 1

            case .to_propkey2:
                // QuickJS: val key -> val ToPropertyKey(key)
                // Convert TOS to a property key in-place; leave the value below it untouched.
                let val = pop()
                let key = ctx.toPropertyKey(val)
                val.freeValue()
                if key.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(key)
                pc += 1

            // -----------------------------------------------------------------
            // with Statement Variable Access
            // -----------------------------------------------------------------

            case .with_get_var, .with_put_var, .with_delete_var,
                 .with_make_ref, .with_get_ref, .with_get_ref_undef:
                let atom = readU32(bc, pc + 1)
                let label = readI32(bc, pc + 5)
                let withFlags = Int(readU8(bc, pc + 9))
                let obj = peek()
                let hasProp = ctx.hasProperty(obj: obj, atom: atom)
                if hasProp {
                    switch op {
                    case .with_get_var:
                        // nPop=1, nPush=1: replace the with_obj on TOS with the property value
                        let _ = pop() // remove with object
                        let val = ctx.getProperty(obj: obj, atom: atom)
                        push(val)
                    case .with_get_ref, .with_get_ref_undef:
                        // nPop=1, nPush=2: replace with_obj with (obj, propKey) reference pair
                        let _ = pop() // remove with object
                        push(obj.dupValue())
                        let propKey = ctx.atomToString(atom)
                        push(propKey)
                    case .with_put_var:
                        // nPop=2, nPush=0: pop val and with_obj, set property
                        // Note: in QuickJS the table says nPush=1 but the code does sp -= 2.
                        // The with_obj is TOS, val is below it.
                        let _ = pop() // with object
                        let val = pop() // value to assign
                        let _ = ctx.setProperty(obj: obj, atom: atom, value: val)
                    case .with_delete_var:
                        // nPop=1, nPush=1: replace with_obj with delete result bool
                        let _ = pop() // remove with object
                        let ok = ctx.deleteProperty(obj: obj, atom: atom)
                        push(.newBool(ok))
                    case .with_make_ref:
                        // nPop=1, nPush=2: replace with_obj with (obj, propKey) reference
                        let _ = pop() // remove with object
                        push(obj.dupValue())
                        let propKey = ctx.atomToString(atom)
                        push(propKey)
                    default: break
                    }
                    pc += 10
                } else {
                    // Fall through to non-with access: jump past the with_xxx
                    // instruction. The label is a relative offset from the
                    // end of this 10-byte instruction.
                    let _ = withFlags
                    pc += 10 + Int(label)
                }

            // -----------------------------------------------------------------
            // Reference Construction
            // -----------------------------------------------------------------

            case .make_loc_ref:
                let atom = readU32(bc, pc + 1)
                let idx = Int(readU16(bc, pc + 5))
                let ref = ctx.makeLocalRef(frame: frame, idx: idx)
                push(.makeObject(ref))
                push(ctx.atomToString(atom))
                pc += 7

            case .make_arg_ref:
                let atom = readU32(bc, pc + 1)
                let idx = Int(readU16(bc, pc + 5))
                let ref = ctx.makeArgRef(frame: frame, idx: idx)
                push(.makeObject(ref))
                push(ctx.atomToString(atom))
                pc += 7

            case .make_var_ref_ref:
                let atom = readU32(bc, pc + 1)
                let idx = Int(readU16(bc, pc + 5))
                if idx < varRefs.count, let vr = varRefs[idx] {
                    push(.mkPtr(tag: .object, ptr: vr))
                } else {
                    push(.undefined)
                }
                push(ctx.atomToString(atom))
                pc += 7

            case .make_var_ref:
                let atom = readU32(bc, pc + 1)
                let ref = ctx.makeGlobalVarRef(atom: atom)
                push(ref.0)
                push(ref.1)
                pc += 5

            // -----------------------------------------------------------------
            // Iteration
            // -----------------------------------------------------------------

            case .for_in_start:
                let obj = pop()
                let iter = ctx.createForInIterator(obj: obj)
                obj.freeValue()
                push(iter)
                pc += 1

            case .for_of_start:
                // QuickJS: iterable -> iter_obj obj method
                // Pops the iterable, gets its [Symbol.iterator] method, calls it to
                // get the iterator object, then pushes the 3-element iterator state:
                // [iter_obj, obj, method] where method = iter_obj.next
                let obj = pop()
                let iter = ctx.getIterator(obj: obj, isAsync: false)
                if iter.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                let nextMethod = ctx.getPropertyStr(obj: iter, name: "next")
                push(iter)
                push(obj)
                push(nextMethod)
                pc += 1

            case .for_await_of_start:
                // QuickJS: iterable -> iter_obj obj method
                // Same as for_of_start but uses [Symbol.asyncIterator].
                let obj = pop()
                let iter = ctx.getIterator(obj: obj, isAsync: true)
                if iter.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                let nextMethod = ctx.getPropertyStr(obj: iter, name: "next")
                push(iter)
                push(obj)
                push(nextMethod)
                pc += 1

            case .for_in_next:
                let iter = peek()
                let result = ctx.forInNext(iter: iter)
                if result.0.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(result.0) // value
                push(.newBool(result.1)) // done
                pc += 1

            case .for_of_next:
                // QuickJS: iter obj method -> iter obj method value done
                // The 3-element iterator state [iter, obj, method] stays on
                // the stack; we peek at it via an offset and push value+done
                // on top.  This matches QuickJS behaviour exactly (peek, not
                // pop/push) and correctly handles non-zero offsets.
                let offset = Int(readU8(bc, pc + 1))
                // Peek at the iterator state without popping
                let method = peekAt(0 + offset)  // top of iter state
                let iter   = peekAt(2 + offset)  // bottom of iter state
                // Call method (next) with iter as this.
                if JeffJSInterpreter.traceOpcodes {
                    print("[FOR-OF-NEXT] method.isFunction=\(method.isFunction) method.isUndefined=\(method.isUndefined) iter.isObject=\(iter.isObject)")
                    if let iterObj = iter.toObject() {
                        print("[FOR-OF-NEXT] iter has _target: \(ctx.getPropertyStr(obj: iter, name: "_target").isObject)")
                        print("[FOR-OF-NEXT] iter has next: \(ctx.getPropertyStr(obj: iter, name: "next").isFunction)")
                    }
                }
                let forOfResult = ctx.callFunction(method, thisVal: iter, args: [])
                if forOfResult.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                // The result should be an iterator result object {value, done}.
                // If it's not an object, create a synthetic one. Some iterators
                // (e.g. for-in) return primitives.
                if !forOfResult.isObject {
                    // Treat non-object as {value: result, done: false}
                    push(forOfResult)
                    push(.newBool(false))
                    pc += 2
                    break // continue dispatch
                }
                // Extract .done and .value from the iterator result
                let forOfDoneVal = ctx.getPropertyStr(obj: forOfResult, name: "done")
                let forOfDone = JeffJSTypeConvert.toBool(forOfDoneVal)
                if JeffJSInterpreter.traceOpcodes {
                    let v = ctx.getPropertyStr(obj: forOfResult, name: "value")
                    print("[FOR-OF] result.isObject=\(forOfResult.isObject) done=\(forOfDone) doneVal.bits=0x\(String(forOfDoneVal.bits, radix: 16)) value=\(ctx.toSwiftString(v) ?? "nil")")
                    if let obj = forOfResult.toObject() {
                        print("[FOR-OF] result props: \(obj.prop.count) shape: \(obj.shape?.propCount ?? -1)")
                    }
                }
                if forOfDone {
                    push(.undefined)
                    push(.newBool(true))
                } else {
                    let forOfValue = ctx.getPropertyStr(obj: forOfResult, name: "value")
                    push(forOfValue)
                    push(.newBool(false))
                }
                pc += 2

            case .for_await_of_next:
                // QuickJS: iter obj method -> iter obj method value
                // nPop=3, nPush=4: pops the 3-element iterator state, calls method,
                // pushes back the state plus the raw result (to be awaited).
                // Full async iteration requires coroutine/promise support. For now,
                // we call next() synchronously. If the result is a promise, true
                // async iteration would require awaiting it.
                let method = pop()
                let iterObj = pop()
                let asyncIter = pop()
                let asyncResult: JeffJSValue
                if method.isFunction {
                    asyncResult = ctx.callFunction(method, thisVal: asyncIter, args: [])
                } else {
                    asyncResult = ctx.iteratorNext(iter: asyncIter)
                }
                if asyncResult.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                // Push back the 3-element state plus the result
                push(asyncIter)
                push(iterObj)
                push(method)
                push(asyncResult)
                pc += 1

            case .iterator_check_object:
                let val = peek()
                if !val.isObject {
                    _ = ctx.throwTypeError(message: "iterator result is not an object")
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 1

            case .iterator_get_value_done:
                let result = pop()
                let done = ctx.getPropertyStr(obj: result, name: "done")
                let value = ctx.getPropertyStr(obj: result, name: "value")
                push(value)
                push(.newBool(JeffJSTypeConvert.toBool(done)))
                pc += 1

            case .iterator_close:
                // QuickJS: iter obj method -> (empty)
                // nPop=3, nPush=0: pops the 3-element iterator state and closes the iterator.
                let _ = pop()   // method
                let _ = pop()   // obj
                let iter = pop() // iter
                ctx.iteratorClose(iter: iter, isThrow: false)
                pc += 1

            case .iterator_close_return:
                // QuickJS: ret_val iter obj method -> ret_val
                // nPop=4, nPush=1: pops the 3-element iterator state plus the
                // return value below, closes the iterator, then pushes the
                // return value back.
                let _ = pop()   // method
                let _ = pop()   // obj
                let iter = pop() // iter
                let retValue = pop() // return value that was below the iterator state
                ctx.iteratorClose(iter: iter, isThrow: false)
                push(retValue)
                pc += 1

            case .iterator_next:
                // QuickJS: val iter obj method -> result iter obj method
                // nPop=4, nPush=4: pops the 3-element iterator state plus the
                // value below, calls next on the iterator, pushes result then
                // the 3-element state back.
                let method = pop()
                let iterObj = pop()
                let iter = pop()
                let _ = pop()  // val (argument to pass, often unused)
                let result: JeffJSValue
                if method.isFunction {
                    result = ctx.callFunction(method, thisVal: iter, args: [])
                } else {
                    result = ctx.iteratorNext(iter: iter)
                }
                if result.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(result)
                push(iter)
                push(iterObj)
                push(method)
                pc += 1

            case .iterator_call:
                // QuickJS: val iter obj method -> result iter obj method
                // nPop=4, nPush=4: pops the 3-element iterator state plus the
                // value below, calls the specified method on the iterator, pushes
                // result then the 3-element state back.
                let methodType = Int(readU8(bc, pc + 1))
                let nextMethod = pop()
                let iterObj = pop()
                let iter = pop()
                let _ = pop()  // val (argument)
                let result = ctx.iteratorCallMethod(iter: iter, method: methodType)
                if result.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(result)
                push(iter)
                push(iterObj)
                push(nextMethod)
                pc += 2

            // -----------------------------------------------------------------
            // Generators / Async
            // -----------------------------------------------------------------

            case .initial_yield:
                // Save the current execution state into the generator object's
                // JeffJSGeneratorData so that the first .next() call can resume
                // execution right after this opcode.
                if let genObj = generatorObject.toObject(),
                   case .generatorData(let genData) = genObj.payload {
                    // Sync buf → frame for saved state
                    syncBufToFrame()
                    // Save value-stack region
                    let stackCount = sp - spBase
                    var savedStack = [JeffJSValue](repeating: .undefined, count: stackCount)
                    for i in 0..<stackCount { savedStack[i] = buf[spBase + i] }
                    // The pc saved points to the instruction *after* initial_yield
                    // so that when we resume, we continue with the next opcode.
                    genData.savedState = GeneratorSavedState(
                        pc: pc + 1,
                        sp: stackCount,
                        stack: savedStack,
                        varBuf: frame.varBuf,
                        argBuf: frame.argBuf,
                        funcObj: mFuncObj,
                        thisVal: thisVal,
                        isInitialYield: true)
                    genData.state = .suspended_start
                }
                // Return undefined to the callFunction that initiated the generator.
                // The caller (callFunction) returns the generator object, not this value.
                retVal = .undefined
                break dispatchLoop

            case .yield_:
                // Pop the value being yielded, save state, and break out.
                // The yielded value becomes the retVal so the caller
                // (generatorResume) can wrap it in {value, done: false}.
                let val = pop()
                if let genObj = generatorObject.toObject(),
                   case .generatorData(let genData) = genObj.payload {
                    // Sync buf → frame for saved state
                    syncBufToFrame()
                    // Save value-stack region as an array for GeneratorSavedState
                    let stackCount = sp - spBase
                    var savedStack = [JeffJSValue](repeating: .undefined, count: stackCount)
                    for i in 0..<stackCount { savedStack[i] = buf[spBase + i] }
                    // Save state for resumption. pc + 1 points past the yield_
                    // opcode so resumption continues with the next instruction.
                    genData.savedState = GeneratorSavedState(
                        pc: pc + 1,
                        sp: stackCount,
                        stack: savedStack,
                        varBuf: frame.varBuf,
                        argBuf: frame.argBuf,
                        funcObj: mFuncObj,
                        thisVal: thisVal)
                    genData.state = .suspended_yield
                }
                retVal = val
                break dispatchLoop

            case .yield_star:
                // yield* delegation: pop the iterable, get its iterator,
                // and yield each value lazily. When the inner iterator is
                // exhausted, push the return value and continue.
                let val = pop()
                if let genObj = generatorObject.toObject(),
                   case .generatorData(let genData) = genObj.payload {
                    // Get the iterator from the value
                    let iter = ctx.getIterator(obj: val, isAsync: false)
                    if iter.isException {
                        retVal = .exception
                        break dispatchLoop
                    }
                    // Get the first value from the inner iterator
                    let result = ctx.iteratorNext(iter: iter)
                    if result.isException {
                        retVal = .exception
                        break dispatchLoop
                    }
                    let done = ctx.iteratorCheckDone(result: result)
                    let value = ctx.iteratorGetValue(result: result)
                    if done {
                        // Inner iterator immediately done — push return value
                        push(value)
                        genData.state = .executing
                        pc += 1
                    } else {
                        // Yield this value and save state for lazy resumption.
                        // On resume, we'll continue iterating the inner iterator.
                        syncBufToFrame()
                        let stackCount = sp - spBase
                        var savedStack = [JeffJSValue](repeating: .undefined, count: stackCount)
                        for i in 0..<stackCount { savedStack[i] = buf[spBase + i] }
                        var saved = GeneratorSavedState(
                            pc: pc,  // resume at this same yield_star opcode
                            sp: stackCount,
                            stack: savedStack,
                            varBuf: frame.varBuf,
                            argBuf: frame.argBuf,
                            funcObj: mFuncObj,
                            thisVal: thisVal)
                        saved.delegatedIter = iter
                        genData.savedState = saved
                        genData.state = .suspended_yield_star
                        retVal = value
                        break dispatchLoop
                    }
                } else {
                    pc += 1
                }

            case .async_yield_star:
                // Async yield* delegation: similar to yield_star but for
                // async iterators. Falls back to synchronous iteration for
                // non-Promise values.
                let val = pop()
                if let genObj = generatorObject.toObject(),
                   case .generatorData(let genData) = genObj.payload {
                    let iter = ctx.getIterator(obj: val, isAsync: true)
                    if iter.isException {
                        retVal = .exception
                        break dispatchLoop
                    }
                    var lastValue: JeffJSValue = .undefined
                    var asyncYieldDone = false
                    while !asyncYieldDone {
                        let result = ctx.iteratorNext(iter: iter)
                        if result.isException {
                            retVal = .exception
                            break dispatchLoop
                        }
                        let done = ctx.iteratorCheckDone(result: result)
                        let value = ctx.iteratorGetValue(result: result)
                        if done {
                            lastValue = value
                            asyncYieldDone = true
                        } else {
                            lastValue = value
                        }
                    }
                    push(lastValue)
                    genData.state = .executing
                }
                pc += 1

            case .await_:
                // Await expression: synchronous Promise unwrapping.
                //
                // Per ECMAScript, `await expr` should:
                //   1. Evaluate expr to a value
                //   2. If the value is a Promise/thenable, suspend until settled
                //   3. Resume with the resolved value (or throw if rejected)
                //   4. If not a Promise, return the value unchanged
                //
                // Since JeffJS runs single-threaded without a real event loop,
                // we implement synchronous unwrapping: drain the microtask queue
                // to settle pending Promises, then extract the result directly.
                let val = pop()

                // Fast path: non-object values pass through unchanged.
                // `await 42` === 42, `await "hello"` === "hello"
                guard val.isObject else {
                    push(val)
                    pc += 1
                    break
                }

                // Check if the value is a JeffJS Promise object.
                if let promObj = val.toObject(),
                   case .promiseData(let promData) = promObj.payload {
                    // If the Promise is still pending, drain the microtask queue.
                    // Promise.resolve(x) where x is a non-thenable settles
                    // synchronously, but chained Promises (e.g. via .then())
                    // settle via enqueued reaction jobs. Draining gives them
                    // a chance to complete.
                    if promData.promiseState == .pending {
                        _ = ctx.rt.executePendingJobs()
                    }

                    switch promData.promiseState {
                    case .fulfilled:
                        push(promData.promiseResult)
                        pc += 1
                    case .rejected:
                        ctx.throwValue(promData.promiseResult.dupValue())
                        retVal = .exception
                        break dispatchLoop
                    case .pending:
                        // Promise still pending (async I/O). Suspend the async
                        // function and register .then() to resume when settled.
                        guard !ctx._asyncResolve.isUndefined else {
                            // Not inside an async function — fallback
                            push(.undefined)
                            pc += 1
                            break
                        }
                        // Capture stack, vars, args from buf
                        var stackSnap = [JeffJSValue]()
                        for i in spBase..<sp { stackSnap.append(buf[i]) }
                        var varSnap = [JeffJSValue]()
                        for i in 0..<frame.varBuf.count { varSnap.append(buf[varBase + i]) }
                        var argSnap = [JeffJSValue]()
                        for i in 0..<min(varBase, bufCapacity) { argSnap.append(buf[i]) }
                        syncBufToFrame()

                        let saved = GeneratorSavedState(
                            pc: pc + 1, sp: sp - spBase,
                            stack: stackSnap, varBuf: varSnap,
                            argBuf: argSnap, funcObj: mFuncObj,
                            thisVal: frame.thisVal)

                        let stateID = ctx.storeAsyncState(JeffJSContext.AsyncSavedEntry(
                            saved: saved,
                            resolve: ctx._asyncResolve.dupValue(),
                            reject: ctx._asyncReject.dupValue()))

                        // Create C-function callbacks for .then(onFulfilled, onRejected)
                        let onFulfilled = ctx.newCFunction({ [stateID] ctx, _, args in
                            let v = args.first ?? .undefined
                            ctx.resumeAsyncFunction(stateID: stateID, value: v, isRejection: false)
                            return JeffJSValue.undefined
                        }, name: "asyncResume", length: 1)
                        let onRejected = ctx.newCFunction({ [stateID] ctx, _, args in
                            let v = args.first ?? .undefined
                            ctx.resumeAsyncFunction(stateID: stateID, value: v, isRejection: true)
                            return JeffJSValue.undefined
                        }, name: "asyncReject", length: 1)

                        JeffJSBuiltinPromise.performPromiseThen(
                            ctx: ctx, promise: val,
                            onFulfilled: onFulfilled, onRejected: onRejected,
                            resultPromise: nil)

                        ctx._asyncSuspended = true
                        retVal = .undefined
                        break dispatchLoop
                    }
                    break
                }

                // Not a JeffJS Promise — check for generic thenable (.then method).
                let thenMethod = ctx.getProperty(
                    obj: val,
                    atom: JeffJSAtomID.JS_ATOM_then.rawValue)
                if thenMethod.isFunction {
                    // Generic thenable: call .then() synchronously to try to
                    // extract the value. Create a temporary Promise to capture
                    // the result.
                    let tempPromise = JeffJSBuiltinPromise.resolve(
                        ctx: ctx, this: ctx.promiseCtor, args: [val])
                    // Drain microtasks so the thenable chain settles
                    _ = ctx.rt.executePendingJobs()

                    if let tpObj = tempPromise.toObject(),
                       case .promiseData(let tpData) = tpObj.payload {
                        switch tpData.promiseState {
                        case .fulfilled:
                            push(tpData.promiseResult)
                        case .rejected:
                            ctx.throwValue(tpData.promiseResult.dupValue())
                            retVal = .exception
                            break dispatchLoop
                        case .pending:
                            push(.undefined)
                        }
                    } else {
                        // Fallback: push the original value
                        push(val)
                    }
                } else {
                    // Not a thenable: await on non-Promise is identity.
                    push(val)
                }
                pc += 1

            // -----------------------------------------------------------------
            // Unary Operators
            // -----------------------------------------------------------------

            case .neg:
                let val = pop()
                if val.isInt {
                    let v = val.toInt32()
                    if v == 0 { push(.newFloat64(-0.0)) }
                    else if v == Int32.min { push(.newFloat64(-Double(v))) }
                    else { push(.newInt32(-v)) }
                } else {
                    let (d, ok) = JeffJSTypeConvert.toNumber(ctx: ctx, val: val)
                    val.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    push(.newFloat64(-d))
                }
                pc += 1

            case .plus:
                let val = pop()
                if val.isNumber {
                    push(val)
                } else {
                    let (d, ok) = JeffJSTypeConvert.toNumber(ctx: ctx, val: val)
                    val.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    push(.newFloat64(d))
                }
                pc += 1

            case .inc:
                let val = pop()
                if val.isInt {
                    let v = val.toInt32()
                    if v == Int32.max { push(.newFloat64(Double(v) + 1)) }
                    else { push(.newInt32(v + 1)) }
                } else {
                    let (d, ok) = JeffJSTypeConvert.toNumber(ctx: ctx, val: val)
                    val.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    push(.newFloat64(d + 1))
                }
                pc += 1

            case .dec:
                let val = pop()
                if val.isInt {
                    let v = val.toInt32()
                    if v == Int32.min { push(.newFloat64(Double(v) - 1)) }
                    else { push(.newInt32(v - 1)) }
                } else {
                    let (d, ok) = JeffJSTypeConvert.toNumber(ctx: ctx, val: val)
                    val.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    push(.newFloat64(d - 1))
                }
                pc += 1

            case .post_inc:
                let val = pop()
                if val.isInt {
                    let v = val.toInt32()
                    push(val) // original value
                    if v == Int32.max { push(.newFloat64(Double(v) + 1)) }
                    else { push(.newInt32(v + 1)) }
                } else {
                    let (d, ok) = JeffJSTypeConvert.toNumber(ctx: ctx, val: val)
                    val.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    push(.newFloat64(d))
                    push(.newFloat64(d + 1))
                }
                pc += 1

            case .post_dec:
                let val = pop()
                if val.isInt {
                    let v = val.toInt32()
                    push(val)
                    if v == Int32.min { push(.newFloat64(Double(v) - 1)) }
                    else { push(.newInt32(v - 1)) }
                } else {
                    let (d, ok) = JeffJSTypeConvert.toNumber(ctx: ctx, val: val)
                    val.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    push(.newFloat64(d))
                    push(.newFloat64(d - 1))
                }
                pc += 1

            case .inc_loc:
                let idx = Int(readU8(bc, pc + 1))
                let val = buf[varBase + idx]
                if val.isInt && val.toInt32() != Int32.max {
                    buf[varBase + idx] = .newInt32(val.toInt32() + 1)
                } else {
                    let (d, ok) = JeffJSTypeConvert.toNumber(ctx: ctx, val: val)
                    val.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    buf[varBase + idx] = .newFloat64(d + 1)
                }
                pc += 2

            case .dec_loc:
                let idx = Int(readU8(bc, pc + 1))
                let val = buf[varBase + idx]
                if val.isInt && val.toInt32() != Int32.min {
                    buf[varBase + idx] = .newInt32(val.toInt32() - 1)
                } else {
                    let (d, ok) = JeffJSTypeConvert.toNumber(ctx: ctx, val: val)
                    val.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    buf[varBase + idx] = .newFloat64(d - 1)
                }
                pc += 2

            case .not:
                let val = pop()
                let (i, ok) = JeffJSTypeConvert.toInt32(ctx: ctx, val: val)
                val.freeValue()
                if !ok { retVal = .exception; break dispatchLoop }
                push(.newInt32(~i))
                pc += 1

            case .lnot:
                let val = pop()
                let lnotResult = !JeffJSTypeConvert.toBool(val)
                val.freeValue()
                push(.newBool(lnotResult))
                pc += 1

            case .typeof_:
                let val = pop()
                let t = JeffJSOperators.jsTypeof(val)
                val.freeValue()
                push(ctx.newString(t))
                pc += 1

            case .delete_:
                let key = pop()
                let obj = pop()
                let ok = ctx.deletePropertyValue(obj: obj, key: key)
                obj.freeValue(); key.freeValue()
                push(.newBool(ok))
                pc += 1

            case .delete_var:
                let atom = readU32(bc, pc + 1)
                let ok = ctx.deleteGlobalVar(atom: atom)
                push(.newBool(ok))
                pc += 5

            // -----------------------------------------------------------------
            // Binary Arithmetic Operators
            // -----------------------------------------------------------------

            case .add:
                let rhs = pop(); let lhs = pop()
                // Inline fast path for int+int avoids function call overhead
                if lhs.isInt && rhs.isInt {
                    let a = lhs.toInt32(), b = rhs.toInt32()
                    let (r, overflow) = a.addingReportingOverflow(b)
                    push(overflow ? .newFloat64(Double(a) + Double(b)) : .newInt32(r))
                } else if lhs.isString && rhs.isString {
                    // String+string fast path: rope-based O(1) concat, bypasses jsAdd
                    let concatResult = jeffJS_concatStrings(s1: lhs, s2: rhs)
                    lhs.freeValue(); rhs.freeValue()
                    push(concatResult)
                } else {
                    let result = JeffJSOperators.jsAdd(ctx: ctx, lhs: lhs, rhs: rhs)
                    lhs.freeValue(); rhs.freeValue()
                    if result.isException { retVal = .exception; break dispatchLoop }
                    push(result)
                }
                pc += 1

            case .sub:
                let rhs = pop(); let lhs = pop()
                if lhs.isInt && rhs.isInt {
                    let (r, overflow) = lhs.toInt32().subtractingReportingOverflow(rhs.toInt32())
                    push(overflow ? .newFloat64(Double(lhs.toInt32()) - Double(rhs.toInt32())) : .newInt32(r))
                } else {
                    let (a, ok1) = JeffJSTypeConvert.toNumber(ctx: ctx, val: lhs)
                    let (b, ok2) = JeffJSTypeConvert.toNumber(ctx: ctx, val: rhs)
                    lhs.freeValue(); rhs.freeValue()
                    if !ok1 || !ok2 { retVal = .exception; break dispatchLoop }
                    push(.newFloat64(a - b))
                }
                pc += 1

            case .mul:
                let rhs = pop(); let lhs = pop()
                if lhs.isInt && rhs.isInt {
                    let a = Int64(lhs.toInt32()), b = Int64(rhs.toInt32())
                    let r = a * b
                    if r >= Int64(Int32.min) && r <= Int64(Int32.max) && !(r == 0 && (a < 0 || b < 0)) {
                        push(.newInt32(Int32(r)))
                    } else {
                        push(.newFloat64(Double(a) * Double(b)))
                    }
                } else {
                    let (a, ok1) = JeffJSTypeConvert.toNumber(ctx: ctx, val: lhs)
                    let (b, ok2) = JeffJSTypeConvert.toNumber(ctx: ctx, val: rhs)
                    lhs.freeValue(); rhs.freeValue()
                    if !ok1 || !ok2 { retVal = .exception; break dispatchLoop }
                    push(.newFloat64(a * b))
                }
                pc += 1

            case .div:
                let rhs = pop(); let lhs = pop()
                let (a, ok1) = JeffJSTypeConvert.toNumber(ctx: ctx, val: lhs)
                let (b, ok2) = JeffJSTypeConvert.toNumber(ctx: ctx, val: rhs)
                lhs.freeValue(); rhs.freeValue()
                if !ok1 || !ok2 { retVal = .exception; break dispatchLoop }
                push(.newFloat64(a / b))
                pc += 1

            case .mod:
                let rhs = pop(); let lhs = pop()
                if lhs.isInt && rhs.isInt {
                    let a = lhs.toInt32(), b = rhs.toInt32()
                    if b != 0 && !(a == Int32.min && b == -1) {
                        let r = a % b
                        if r != 0 || a >= 0 { push(.newInt32(r)) }
                        else { push(.newFloat64(Double(a).truncatingRemainder(dividingBy: Double(b)))) }
                    } else {
                        push(.newFloat64(Double(a).truncatingRemainder(dividingBy: Double(b))))
                    }
                } else {
                    let (a, ok1) = JeffJSTypeConvert.toNumber(ctx: ctx, val: lhs)
                    let (b, ok2) = JeffJSTypeConvert.toNumber(ctx: ctx, val: rhs)
                    lhs.freeValue(); rhs.freeValue()
                    if !ok1 || !ok2 { retVal = .exception; break dispatchLoop }
                    push(.newFloat64(a.truncatingRemainder(dividingBy: b)))
                }
                pc += 1

            case .pow:
                let rhs = pop(); let lhs = pop()
                let (a, ok1) = JeffJSTypeConvert.toNumber(ctx: ctx, val: lhs)
                let (b, ok2) = JeffJSTypeConvert.toNumber(ctx: ctx, val: rhs)
                lhs.freeValue(); rhs.freeValue()
                if !ok1 || !ok2 { retVal = .exception; break dispatchLoop }
                push(.newFloat64(pow(a, b)))
                pc += 1

            // -----------------------------------------------------------------
            // Bitwise Shift Operators
            // -----------------------------------------------------------------

            case .shl:
                let rhs = pop(); let lhs = pop()
                let (a, ok1) = JeffJSTypeConvert.toInt32(ctx: ctx, val: lhs)
                let (b, ok2) = JeffJSTypeConvert.toInt32(ctx: ctx, val: rhs)
                lhs.freeValue(); rhs.freeValue()
                if !ok1 || !ok2 { retVal = .exception; break dispatchLoop }
                push(.newInt32(a << (b & 0x1F)))
                pc += 1

            case .sar:
                let rhs = pop(); let lhs = pop()
                let (a, ok1) = JeffJSTypeConvert.toInt32(ctx: ctx, val: lhs)
                let (b, ok2) = JeffJSTypeConvert.toInt32(ctx: ctx, val: rhs)
                lhs.freeValue(); rhs.freeValue()
                if !ok1 || !ok2 { retVal = .exception; break dispatchLoop }
                push(.newInt32(a >> (b & 0x1F)))
                pc += 1

            case .shr:
                let rhs = pop(); let lhs = pop()
                let (a32, ok1) = JeffJSTypeConvert.toInt32(ctx: ctx, val: lhs)
                let (b, ok2) = JeffJSTypeConvert.toInt32(ctx: ctx, val: rhs)
                lhs.freeValue(); rhs.freeValue()
                if !ok1 || !ok2 { retVal = .exception; break dispatchLoop }
                let ua = UInt32(bitPattern: a32)
                let result = ua >> (UInt32(b & 0x1F))
                push(.newUInt32(result))
                pc += 1

            // -----------------------------------------------------------------
            // Comparison Operators
            // -----------------------------------------------------------------

            case .lt:
                let rhs = pop(); let lhs = pop()
                // Inline fast path for int<int avoids function call
                if lhs.isInt && rhs.isInt {
                    push(.newBool(lhs.toInt32() < rhs.toInt32()))
                } else {
                    let (cmp, ok) = JeffJSOperators.jsCompare(ctx: ctx, lhs: lhs, rhs: rhs)
                    lhs.freeValue(); rhs.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    push(.newBool(cmp < 0)) // true only when LT; false for unordered (NaN)
                }
                pc += 1

            case .lte:
                let rhs = pop(); let lhs = pop()
                if lhs.isInt && rhs.isInt {
                    push(.newBool(lhs.toInt32() <= rhs.toInt32()))
                } else {
                    let (cmp, ok) = JeffJSOperators.jsCompare(ctx: ctx, lhs: rhs, rhs: lhs)
                    lhs.freeValue(); rhs.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    push(.newBool(cmp == 0))
                }
                pc += 1

            case .gt:
                let rhs = pop(); let lhs = pop()
                if lhs.isInt && rhs.isInt {
                    push(.newBool(lhs.toInt32() > rhs.toInt32()))
                } else {
                    let (cmp, ok) = JeffJSOperators.jsCompare(ctx: ctx, lhs: rhs, rhs: lhs)
                    lhs.freeValue(); rhs.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    push(.newBool(cmp < 0))
                }
                pc += 1

            case .gte:
                let rhs = pop(); let lhs = pop()
                if lhs.isInt && rhs.isInt {
                    push(.newBool(lhs.toInt32() >= rhs.toInt32()))
                } else {
                    let (cmp, ok) = JeffJSOperators.jsCompare(ctx: ctx, lhs: lhs, rhs: rhs)
                    lhs.freeValue(); rhs.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    push(.newBool(cmp == 0))
                }
                pc += 1

            case .instanceof_:
                let rhs = pop(); let lhs = pop()
                let result = JeffJSOperators.jsInstanceof(ctx: ctx, val: lhs, target: rhs)
                lhs.freeValue(); rhs.freeValue()
                if result.isException { retVal = .exception; break dispatchLoop }
                push(result)
                pc += 1

            case .in_:
                let rhs = pop(); let lhs = pop()
                if !rhs.isObject {
                    _ = ctx.throwTypeError(message: "Cannot use 'in' operator to search for property in non-object")
                    retVal = .exception; break dispatchLoop
                }
                // For numeric keys, pass directly to hasPropertyValue so it
                // uses integer atoms (matching how arrays store elements).
                // For other types, convert to property key first.
                let key: JeffJSValue
                if lhs.isInt || lhs.isFloat64 || lhs.isString || lhs.isSymbol {
                    key = lhs
                } else {
                    key = ctx.toPropertyKey(lhs)
                    if key.isException { retVal = .exception; break dispatchLoop }
                }
                let has = ctx.hasPropertyValue(obj: rhs, key: key)
                push(.newBool(has))
                pc += 1

            // -----------------------------------------------------------------
            // Equality Operators
            // -----------------------------------------------------------------

            case .eq:
                let rhs = pop(); let lhs = pop()
                let (result, ok) = JeffJSOperators.jsEq(ctx: ctx, lhs: lhs, rhs: rhs)
                lhs.freeValue(); rhs.freeValue()
                if !ok { retVal = .exception; break dispatchLoop }
                push(.newBool(result))
                pc += 1

            case .neq:
                let rhs = pop(); let lhs = pop()
                let (result, ok) = JeffJSOperators.jsEq(ctx: ctx, lhs: lhs, rhs: rhs)
                lhs.freeValue(); rhs.freeValue()
                if !ok { retVal = .exception; break dispatchLoop }
                push(.newBool(!result))
                pc += 1

            case .strict_eq:
                let rhs = pop(); let lhs = pop()
                let seqResult = JeffJSOperators.jsStrictEq(lhs: lhs, rhs: rhs)
                lhs.freeValue(); rhs.freeValue()
                push(.newBool(seqResult))
                pc += 1

            case .strict_neq:
                let rhs = pop(); let lhs = pop()
                let sneqResult = JeffJSOperators.jsStrictEq(lhs: lhs, rhs: rhs)
                lhs.freeValue(); rhs.freeValue()
                push(.newBool(!sneqResult))
                pc += 1

            // -----------------------------------------------------------------
            // Bitwise Operators
            // -----------------------------------------------------------------

            case .and:
                let rhs = pop(); let lhs = pop()
                let (a, ok1) = JeffJSTypeConvert.toInt32(ctx: ctx, val: lhs)
                let (b, ok2) = JeffJSTypeConvert.toInt32(ctx: ctx, val: rhs)
                lhs.freeValue(); rhs.freeValue()
                if !ok1 || !ok2 { retVal = .exception; break dispatchLoop }
                push(.newInt32(a & b))
                pc += 1

            case .xor:
                let rhs = pop(); let lhs = pop()
                let (a, ok1) = JeffJSTypeConvert.toInt32(ctx: ctx, val: lhs)
                let (b, ok2) = JeffJSTypeConvert.toInt32(ctx: ctx, val: rhs)
                lhs.freeValue(); rhs.freeValue()
                if !ok1 || !ok2 { retVal = .exception; break dispatchLoop }
                push(.newInt32(a ^ b))
                pc += 1

            case .or:
                let rhs = pop(); let lhs = pop()
                let (a, ok1) = JeffJSTypeConvert.toInt32(ctx: ctx, val: lhs)
                let (b, ok2) = JeffJSTypeConvert.toInt32(ctx: ctx, val: rhs)
                lhs.freeValue(); rhs.freeValue()
                if !ok1 || !ok2 { retVal = .exception; break dispatchLoop }
                push(.newInt32(a | b))
                pc += 1

            // -----------------------------------------------------------------
            // Optimization Predicates
            // -----------------------------------------------------------------

            case .is_undefined:
                let val = pop()
                let isUndefResult = val.isUndefined
                val.freeValue()
                push(.newBool(isUndefResult))
                pc += 1

            case .is_null:
                let val = pop()
                let isNullResult = val.isNull
                val.freeValue()
                push(.newBool(isNullResult))
                pc += 1

            case .typeof_is_undefined:
                let val = pop()
                let isUndef = val.isUndefined ||
                              (val.isObject && val.toObject()?.isHTMLDDA == true)
                val.freeValue()
                push(.newBool(isUndef))
                pc += 1

            case .typeof_is_function:
                let val = pop()
                let isFuncResult = JeffJSOperators.jsTypeof(val) == "function"
                val.freeValue()
                push(.newBool(isFuncResult))
                pc += 1

            case .is_undefined_or_null:
                let val = pop()
                let isUON = val.isNull || val.isUndefined
                val.freeValue()
                push(.newBool(isUON))
                pc += 1

            // -----------------------------------------------------------------
            // Short Push Opcodes
            // -----------------------------------------------------------------

            case .push_null:
                push(.null)
                pc += 1

            case .push_this:
                push(frame.thisVal.dupValue())
                pc += 1

            case .push_0: push(.newInt32(0)); pc += 1
            case .push_1: push(.newInt32(1)); pc += 1
            case .push_2: push(.newInt32(2)); pc += 1
            case .push_3: push(.newInt32(3)); pc += 1
            case .push_4: push(.newInt32(4)); pc += 1
            case .push_5: push(.newInt32(5)); pc += 1
            case .push_6: push(.newInt32(6)); pc += 1
            case .push_7: push(.newInt32(7)); pc += 1
            case .push_minus1: push(.newInt32(-1)); pc += 1

            case .push_i8:
                let val = readI8(bc, pc + 1)
                push(.newInt32(Int32(val)))
                pc += 2

            case .push_i16:
                let val = readI16(bc, pc + 1)
                push(.newInt32(Int32(val)))
                pc += 3

            case .push_const8:
                let idx = Int(readU8(bc, pc + 1))
                if idx < fb.cpool.count {
                    push(fb.cpool[idx].dupValue())
                } else {
                    push(.undefined)
                }
                pc += 2

            case .fclosure8:
                let idx = Int(readU8(bc, pc + 1))
                let closureVal = ctx.createClosure(fb: fb, cpoolIdx: idx, varRefs: varRefs,
                                                    parentFrame: frame)
                push(closureVal)
                pc += 2

            case .push_empty_string:
                push(ctx.newString(""))
                pc += 1

            case .get_length:
                let obj = pop()
                let len = ctx.getPropertyStr(obj: obj, name: "length")
                if len.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                push(len)
                pc += 1

            // -----------------------------------------------------------------
            // NOP and temporary compilation opcodes
            // -----------------------------------------------------------------

            case .nop:
                // NOP doubles as a compound superinstruction prefix.
                // Byte after NOP is a sub-opcode for 3+ instruction fusions.
                if pc + 1 < bcLen {
                    let sub = bc[pc + 1]
                    switch sub {

                    // Sub 0: get_loc(a) + get_field(atom) + call(argc)
                    // Method call: obj.method(args)  — saves 2 dispatches
                    case 0:
                        let locIdx = Int(bc[pc + 2])
                        let atom = readU32(bc, pc + 3)
                        let argc = Int(readU16(bc, pc + 7))
                        let obj = buf[varBase + locIdx].dupValue()
                        let val = ctx.getProperty(obj: obj, atom: atom)
                        if val.isException { retVal = .exception; break dispatchLoop }
                        var callArgs = [JeffJSValue](repeating: .undefined, count: argc)
                        for i in stride(from: argc - 1, through: 0, by: -1) { callArgs[i] = pop() }
                        let result = ctx.callFunction(val, thisVal: obj, args: callArgs)
                        if result.isException { retVal = .exception; break dispatchLoop }
                        push(result)
                        pc += 9  // 1(nop) + 1(sub) + 1(loc) + 4(atom) + 2(argc)

                    // Sub 1: get_loc(a) + get_loc(b) + get_array_el
                    // Array element access: arr[i]  — saves 2 dispatches
                    case 1:
                        let arrIdx = Int(bc[pc + 2])
                        let idxIdx = Int(bc[pc + 3])
                        let arr = buf[varBase + arrIdx]
                        let idx = buf[varBase + idxIdx]
                        let val = ctx.getPropertyValue(obj: arr, prop: idx)
                        if val.isException { retVal = .exception; break dispatchLoop }
                        push(val)
                        pc += 4  // 1(nop) + 1(sub) + 1(arr) + 1(idx)

                    // Sub 2: get_loc(a) + get_field(atom) + put_loc(b)
                    // Assign from property: var x = obj.prop  — saves 2 dispatches
                    case 2:
                        let srcIdx = Int(bc[pc + 2])
                        let atom = readU32(bc, pc + 3)
                        let dstIdx = Int(bc[pc + 7])
                        let obj = buf[varBase + srcIdx]
                        let val = ctx.getProperty(obj: obj, atom: atom)
                        if val.isException { retVal = .exception; break dispatchLoop }
                        buf[varBase + dstIdx] = val
                        pc += 8  // 1(nop) + 1(sub) + 1(src) + 4(atom) + 1(dst)

                    // Sub 3: reserved (jump fusion removed — breaks offset resolution)

                    // Sub 4: get_loc(a) + get_loc(b) + add + put_loc(c)
                    // Binary assign: c = a + b  — saves 3 dispatches
                    case 4:
                        let aIdx = Int(bc[pc + 2])
                        let bIdx = Int(bc[pc + 3])
                        let cIdx = Int(bc[pc + 4])
                        let a = buf[varBase + aIdx]
                        let b = buf[varBase + bIdx]
                        let result = JeffJSOperators.jsAdd(ctx: ctx, lhs: a.dupValue(), rhs: b.dupValue())
                        if result.isException { retVal = .exception; break dispatchLoop }
                        let oldSub4 = buf[varBase + cIdx]
                        buf[varBase + cIdx] = result
                        oldSub4.freeValue()
                        pc += 5  // 1(nop) + 1(sub) + 1(a) + 1(b) + 1(c)

                    // Sub 5: get_loc8_get_field(idx, atom) + call(argc)
                    // Level-2 fusion: fuses a level-1 superinstruction with call
                    // obj.method(args) using existing get_loc8_get_field — saves 2 dispatches total
                    case 5:
                        let locIdx = Int(bc[pc + 2])
                        let atom = readU32(bc, pc + 3)
                        let argc = Int(readU16(bc, pc + 7))
                        let obj = buf[varBase + locIdx].dupValue()
                        let method = ctx.getProperty(obj: obj, atom: atom)
                        if method.isException { retVal = .exception; break dispatchLoop }
                        var callArgs = [JeffJSValue](repeating: .undefined, count: argc)
                        for i in stride(from: argc - 1, through: 0, by: -1) { callArgs[i] = pop() }
                        let result = ctx.callFunction(method, thisVal: obj, args: callArgs)
                        if result.isException { retVal = .exception; break dispatchLoop }
                        push(result)
                        pc += 9

                    default:
                        // Unknown sub-opcode, treat as plain NOP
                        pc += 1
                    }
                } else {
                    pc += 1
                }

            case .line_num:
                // Debug info: record current line and column (wide opcode).
                // Now handled via .invalid wide-prefix path; this case is
                // kept for exhaustiveness. Wide prefix = 2 bytes + 4 line + 4 col.
                let _ = readU32(bc, pc + 2)
                pc += 2 + 4 + 4

            // Temporary opcodes should have been resolved by the compiler.
            // If we encounter one, it's an internal error.
            case .enter_scope:
                pc += 3

            case .leave_scope:
                pc += 3

            case .label_:
                pc += 5

            case .add_loc:
                let idx = Int(readU8(bc, pc + 1))
                let addend = readI32(bc, pc + 2)
                let val = buf[varBase + idx]
                if val.isInt {
                    let (r, overflow) = val.toInt32().addingReportingOverflow(addend)
                    if !overflow {
                        buf[varBase + idx] = .newInt32(r)
                    } else {
                        buf[varBase + idx] = .newFloat64(Double(val.toInt32()) + Double(addend))
                    }
                } else {
                    let (d, ok) = JeffJSTypeConvert.toNumber(ctx: ctx, val: val)
                    val.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    buf[varBase + idx] = .newFloat64(d + Double(addend))
                }
                pc += 6

            case .get_field_opt_chain:
                // Wide opcode: now handled via .invalid wide-prefix path.
                // Kept for exhaustiveness. Wide prefix = 2 bytes.
                let atom = readU32(bc, pc + 2)
                let obj = pop()
                if obj.isNull || obj.isUndefined {
                    push(.undefined)
                } else {
                    let val = ctx.getProperty(obj: obj, atom: atom)
                    if val.isException {
                        retVal = .exception
                        break dispatchLoop
                    }
                    push(val)
                }
                pc += 2 + 4  // wide prefix (2) + u32 atom (4)

            case .get_array_el_opt_chain:
                // Wide opcode: now handled via .invalid wide-prefix path.
                // Kept for exhaustiveness. Wide prefix = 2 bytes.
                let key = pop()
                let obj = pop()
                if obj.isNull || obj.isUndefined {
                    push(.undefined)
                } else {
                    let val = ctx.getPropertyValue(obj: obj, prop: key)
                    if val.isException {
                        retVal = .exception
                        break dispatchLoop
                    }
                    push(val)
                }
                pc += 2  // wide opcode, no operands

            // -----------------------------------------------------------------
            // Superinstructions (fused opcodes)
            // -----------------------------------------------------------------

            case .get_loc8_get_field:
                // Fused: get_loc8(idx) + get_field(atom)
                // Format: opcode(1) + loc8(1) + atom(4) = 6 bytes
                let locIdx = Int(readU8(bc, pc + 1))
                let atom = readU32(bc, pc + 2)
                let obj = buf[varBase + locIdx]
                // Inline cache fast path
                if let jsObj = obj.obj, let shape = jsObj.shape {
                    let ic = fb.ic
                    if let ic = ic {
                        let entry = ic.lookup(pc)
                        if entry.pc == pc,
                           entry.shapePtr == UnsafeRawPointer(Unmanaged.passUnretained(shape).toOpaque()),
                           entry.propOffset >= 0, entry.propOffset < jsObj.prop.count {
                            if case .value(let v) = jsObj.prop[entry.propOffset] {
                                push(v.dupValue())
                                pc += 6
                                continue dispatchLoop
                            }
                        }
                    }
                    let val = ctx.getProperty(obj: obj, atom: atom)
                    if val.isException { retVal = .exception; break dispatchLoop }
                    push(val)
                    if let propIdx = findShapeProperty(shape, atom) {
                        fb.getIC().update(pc, shape: shape, propOffset: propIdx)
                    }
                } else {
                    let val = ctx.getProperty(obj: obj, atom: atom)
                    if val.isException { retVal = .exception; break dispatchLoop }
                    push(val)
                }
                pc += 6

            case .get_arg0_get_field:
                // Fused: get_arg(0) + get_field(atom)
                // Format: opcode(1) + atom(4) = 5 bytes
                let atom = readU32(bc, pc + 1)
                let obj = varBase > 0 ? buf[0] : JeffJSValue.undefined
                // Inline cache fast path
                if let jsObj = obj.obj, let shape = jsObj.shape {
                    let ic = fb.ic
                    if let ic = ic {
                        let entry = ic.lookup(pc)
                        if entry.pc == pc,
                           entry.shapePtr == UnsafeRawPointer(Unmanaged.passUnretained(shape).toOpaque()),
                           entry.propOffset >= 0, entry.propOffset < jsObj.prop.count {
                            if case .value(let v) = jsObj.prop[entry.propOffset] {
                                push(v.dupValue())
                                pc += 5
                                continue dispatchLoop
                            }
                        }
                    }
                    let val = ctx.getProperty(obj: obj, atom: atom)
                    if val.isException { retVal = .exception; break dispatchLoop }
                    push(val)
                    if let propIdx = findShapeProperty(shape, atom) {
                        fb.getIC().update(pc, shape: shape, propOffset: propIdx)
                    }
                } else {
                    let val = ctx.getProperty(obj: obj, atom: atom)
                    if val.isException { retVal = .exception; break dispatchLoop }
                    push(val)
                }
                pc += 5

            case .get_loc8_add:
                // Fused: get_loc8(idx) + add
                // Format: opcode(1) + loc8(1) = 2 bytes
                // Stack: pops rhs, pushes (local[idx] + rhs)
                let locIdx = Int(readU8(bc, pc + 1))
                let rhs = pop()
                let lhs = buf[varBase + locIdx].dupValue()
                let result = JeffJSOperators.jsAdd(ctx: ctx, lhs: lhs, rhs: rhs)
                if result.isException { retVal = .exception; break dispatchLoop }
                push(result)
                pc += 2

            case .put_loc8_return:
                // Fused: put_loc8(idx) + return
                // Format: opcode(1) + loc8(1) = 2 bytes
                let locIdx = Int(readU8(bc, pc + 1))
                let val = pop()
                let oldPL8R = buf[varBase + locIdx]
                buf[varBase + locIdx] = val.dupValue()
                oldPL8R.freeValue()
                retVal = val
                break dispatchLoop

            case .push_i32_put_loc8:
                // Fused: push_i32(val) + put_loc8(idx)
                // Format: opcode(1) + i32(4) + loc8(1) = 6 bytes
                let val = readI32(bc, pc + 1)
                let locIdx = Int(readU8(bc, pc + 5))
                let oldI32PL8 = buf[varBase + locIdx]
                buf[varBase + locIdx] = .newInt32(val)
                oldI32PL8.freeValue()
                pc += 6

            case .get_loc8_get_loc8:
                // Fused: get_loc8(a) + get_loc8(b)
                // Format: opcode(1) + loc8(1) + loc8(1) = 3 bytes
                let idxA = Int(readU8(bc, pc + 1))
                let idxB = Int(readU8(bc, pc + 2))
                push(buf[varBase + idxA].dupValue())
                push(buf[varBase + idxB].dupValue())
                pc += 3

            case .get_loc8_call:
                // Fused: get_loc8(idx) + call(argc)
                // Format: opcode(1) + loc8(1) + u16(2) = 4 bytes
                let locIdx = Int(readU8(bc, pc + 1))
                let argc = Int(readU16(bc, pc + 2))
                var callArgs = [JeffJSValue](repeating: .undefined, count: argc)
                for i in stride(from: argc - 1, through: 0, by: -1) { callArgs[i] = pop() }
                let funcVal = buf[varBase + locIdx].dupValue()
                let result = ctx.callFunction(funcVal, thisVal: .undefined, args: callArgs)
                if result.isException { retVal = .exception; break dispatchLoop }
                push(result)
                pc += 4

            case .dup_put_loc8:
                // Fused: dup + put_loc8(idx)
                // Format: opcode(1) + loc8(1) = 2 bytes
                // Peek TOS and store copy to local (value remains on stack)
                let locIdx = Int(readU8(bc, pc + 1))
                let oldDupPL8 = buf[varBase + locIdx]
                buf[varBase + locIdx] = peek().dupValue()
                oldDupPL8.freeValue()
                pc += 2

            // Scope opcodes (should be resolved, but handle gracefully)
            case .scope_get_var, .scope_put_var, .scope_delete_var,
                 .scope_make_ref, .scope_get_ref, .scope_put_var_init,
                 .scope_get_private_field, .scope_put_private_field,
                 .scope_in_private_field:
                _ = ctx.throwInternalError(message: "Unresolved scope opcode at pc=\(pc)")
                retVal = .exception
                break dispatchLoop
            }

            #if DEBUG
            // Stack balance check: verify that the opcode handler changed sp
            // by exactly nPush - nPop. Skip opcodes with variable stack effects
            // (nPop or nPush == -1) and opcodes that break out of the dispatch
            // loop (return_, throw_, etc.) since sp may not be meaningful.
            // Also skip put_* opcodes that may keep the value on stack for
            // chained assignment (they peek instead of pop when followed by
            // another store).
            if Int(op.rawValue) < jeffJSOpcodeInfo.count {
                let info = jeffJSOpcodeInfo[Int(op.rawValue)]
                let expectedDelta = Int(info.nPush) - Int(info.nPop)
                if info.nPop >= 0 && info.nPush >= 0 {
                    let actualDelta = sp - spBefore
                    let isChainedStore = actualDelta == expectedDelta + 1 &&
                        (op == .put_loc || op == .put_loc0 || op == .put_loc1 || op == .put_loc2 || op == .put_loc3 ||
                         op == .put_loc8 || op == .put_var || op == .put_arg || op == .put_arg0 || op == .put_arg1 ||
                         op == .put_arg2 || op == .put_arg3 || op == .put_var_ref)
                    // Only print stack delta warnings when opcode tracing is on.
                    // Many false positives from control flow (catch/gosub/ret) and
                    // exception paths that unwind the stack non-linearly.
                    if actualDelta != expectedDelta && !isChainedStore && JeffJSInterpreter.traceOpcodes {
                        print("[JeffJS-STACK] \(op): expected sp delta \(expectedDelta) but got \(actualDelta) at pc=\(pcBefore)")
                    }
                }
            }
            #endif

            // Interrupt check moved to backward jumps only (see goto_, goto8,
            // goto16, if_false, if_true, if_false8, if_true8 handlers).
            // This avoids a decrement + branch on every single opcode.

        } // end dispatchLoop
        } // end if !retVal.isException

        // -----------------------------------------------------------------
        // Exception handler: when an exception breaks out of the dispatch
        // loop, scan the value stack for a catch handler (catchOffset entry).
        // If found, unwind the stack, push the exception value, set pc to
        // the handler address, and re-enter the dispatch loop.
        // With inline calls, if no handler is found in the current frame,
        // unwind through the inline call stack looking for a handler in
        // caller frames.
        // -----------------------------------------------------------------
        if retVal.isException {
            var handlerFound = false
            // Scan current frame's stack for catch handler
            while sp > spBase {
                sp -= 1
                let entry = buf[sp]
                if entry.isCatchOffset {
                    let catchAddr = Int(entry.toInt32())
                    let excVal = ctx.getException()
                    push(excVal)
                    pc = catchAddr
                    retVal = .undefined
                    handlerFound = true
                    break
                }
                entry.freeValue()
            }
            // If no handler found, unwind through inline call frames
            if !handlerFound {
                while !inlineCallStack.isEmpty {
                    // Run frame epilogue for current (callee) frame
                    syncBufToFrame()
                    for vr in frame.liveVarRefs {
                        if !vr.isDetached {
                            if vr.isArg {
                                let ai = Int(vr.varIdx)
                                vr.value = ai < frame.argBuf.count ? frame.argBuf[ai].dupValue() : .undefined
                            } else {
                                let vi = Int(vr.varIdx)
                                vr.value = vi < frame.varBuf.count ? frame.varBuf[vi].dupValue() : .undefined
                            }
                            vr.isDetached = true
                            vr.parentFrame = nil
                        }
                    }
                    ctx.currentFrame = frame.prevFrame
                    JeffJSStackFrame.release(frame)
                    JeffJSInterpreter.releaseBuf(buf, capacity: bufCapacity)
                    // Restore caller state
                    let saved = inlineCallStack.removeLast()
                    pc = saved.pc
                    sp = saved.sp
                    buf = saved.buf
                    bufCapacity = saved.bufCapacity
                    varBase = saved.varBase
                    spBase = saved.spBase
                    bc = saved.bc
                    bcLen = saved.bcLen
                    fb = saved.fb
                    frame = saved.frame
                    varRefs = saved.varRefs
                    mFuncObj = saved.funcObj
                    mFlags = saved.flags
                    // Scan caller's stack for catch handler
                    while sp > spBase {
                        sp -= 1
                        let entry = buf[sp]
                        if entry.isCatchOffset {
                            let catchAddr = Int(entry.toInt32())
                            let excVal = ctx.getException()
                            push(excVal)
                            pc = catchAddr
                            retVal = .undefined
                            handlerFound = true
                            break
                        }
                        entry.freeValue()
                    }
                    if handlerFound { break }
                }
            }
            if handlerFound {
                // Check interrupt on exception retry to prevent infinite
                // throw-catch loops from hanging.
                ctx.interruptCounter -= 1
                if ctx.interruptCounter <= 0 {
                    ctx.interruptCounter = JS_INTERRUPT_COUNTER_INIT
                    if ctx.checkInterrupt() { break exceptionRetry }
                }
                continue exceptionRetry
            }
        }
        break exceptionRetry
        } // end exceptionRetry

        // If the bytecode fell off the end without an explicit return_ opcode
        // (e.g. a top-level expression evaluation like "1 + 2"), return
        // whatever is on top of the value stack.
        if retVal.isUndefined && sp > spBase {
            retVal = pop()
        }

        // Free remaining stack values (left over from unclean exits)
        while sp > spBase {
            sp -= 1
            buf[sp].freeValue()
        }

        // Sync buf → frame for var-ref detach (they read frame.argBuf/varBuf)
        syncBufToFrame()

        // Detach any remaining live var-refs that still point at this frame.
        // This handles `var`-scoped captured variables whose lifetime equals
        // the entire function -- the compiler does not emit `close_loc` for
        // them, so we must detach here before the frame goes away.
        for vr in frame.liveVarRefs {
            if !vr.isDetached {
                if vr.isArg {
                    let ai = Int(vr.varIdx)
                    vr.value = ai < frame.argBuf.count ? frame.argBuf[ai].dupValue() : .undefined
                } else {
                    let vi = Int(vr.varIdx)
                    vr.value = vi < frame.varBuf.count ? frame.varBuf[vi].dupValue() : .undefined
                }
                vr.isDetached = true
                vr.parentFrame = nil
            }
        }

        // Restore previous frame
        ctx.currentFrame = frame.prevFrame

        // Release the contiguous buffer to pool
        JeffJSInterpreter.releaseBuf(buf, capacity: bufCapacity)

        // Return frame to pool for reuse (only if no live closures reference it,
        // since closures have already been detached above and copied their values)
        JeffJSStackFrame.release(frame)

        return retVal
    }
}

// =============================================================================
// MARK: - Opcode Info Lookup Helper
// =============================================================================

// jeffJSGetOpcodeInfo(_:) is defined in JeffJSOpcodes.swift.
// This file uses it from there to avoid duplicate declarations.
