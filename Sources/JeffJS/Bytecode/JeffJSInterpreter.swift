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

/// Numeric value of an int or float64 JeffJSValue (trace arithmetic).
@inline(__always)
func jeffJS_traceNum(_ v: JeffJSValue) -> Double {
    v.isInt ? Double(v.toInt32()) : v.toFloat64()
}

/// ToInt32 for an int or float64 value (trace bitwise ops on float operands).
@inline(__always)
func jeffJS_traceToInt32(_ v: JeffJSValue) -> Int32 {
    v.isInt ? v.toInt32() : JeffJSTypeConvert.doubleToInt32(v.toFloat64())
}

// MARK: - Fused compare / arithmetic superinstructions
// Sub-opcode byte: compare 0 lt, 1 lte, 2 gt, 3 gte, 4 eq, 5 neq, 6 strict_eq,
// 7 strict_neq; arithmetic 0 add, 1 sub, 2 mul. Emitted by the compiler
// peepholes (get_loc push_i8 <op>, get_loc get_loc <op>, push_const <op>).

@inline(__always)
func jeffJS_cmpInt(_ cmp: UInt8, _ x: Int32, _ y: Int32) -> Bool {
    switch cmp {
    case 0: return x < y
    case 1: return x <= y
    case 2: return x > y
    case 3: return x >= y
    case 4, 6: return x == y
    default: return x != y
    }
}

@inline(__always)
func jeffJS_cmpDouble(_ cmp: UInt8, _ x: Double, _ y: Double) -> Bool {
    switch cmp {
    case 0: return x < y
    case 1: return x <= y
    case 2: return x > y
    case 3: return x >= y
    case 4, 6: return x == y
    default: return x != y
    }
}

/// Generic (non-numeric) fused compare, mirroring the main loop's slow paths.
/// Consumes both values. nil on exception.
@inline(never)
func jeffJS_cmpGeneric(_ ctx: JeffJSContext, _ cmp: UInt8, _ lhs: JeffJSValue, _ rhs: JeffJSValue) -> Bool? {
    defer { lhs.freeValue(); rhs.freeValue() }
    switch cmp {
    case 0:
        let (c, ok) = JeffJSOperators.jsCompare(ctx: ctx, lhs: lhs, rhs: rhs); return ok ? (c < 0) : nil
    case 1:
        let (c, ok) = JeffJSOperators.jsCompare(ctx: ctx, lhs: rhs, rhs: lhs); return ok ? (c == 0) : nil
    case 2:
        let (c, ok) = JeffJSOperators.jsCompare(ctx: ctx, lhs: rhs, rhs: lhs); return ok ? (c < 0) : nil
    case 3:
        let (c, ok) = JeffJSOperators.jsCompare(ctx: ctx, lhs: lhs, rhs: rhs); return ok ? (c == 0) : nil
    case 4:
        let (r, ok) = JeffJSOperators.jsEq(ctx: ctx, lhs: lhs, rhs: rhs); return ok ? r : nil
    case 5:
        let (r, ok) = JeffJSOperators.jsEq(ctx: ctx, lhs: lhs, rhs: rhs); return ok ? !r : nil
    case 6:
        return JeffJSOperators.jsStrictEq(lhs: lhs, rhs: rhs)
    default:
        return !JeffJSOperators.jsStrictEq(lhs: lhs, rhs: rhs)
    }
}

/// Int32 arithmetic with the same overflow-to-double rules as add/sub/mul.
@inline(__always)
func jeffJS_arithInt(_ ar: UInt8, _ x: Int32, _ y: Int32) -> JeffJSValue {
    switch ar {
    case 0:
        let (r, o) = x.addingReportingOverflow(y)
        return o ? .newFloat64(Double(x) + Double(y)) : .newInt32(r)
    case 1:
        let (r, o) = x.subtractingReportingOverflow(y)
        return o ? .newFloat64(Double(x) - Double(y)) : .newInt32(r)
    case 2:
        let a = Int64(x), b = Int64(y)
        let r = a * b
        if r >= Int64(Int32.min) && r <= Int64(Int32.max) && !(r == 0 && (a < 0 || b < 0)) {
            return .newInt32(Int32(r))
        }
        return .newFloat64(Double(a) * Double(b))
    case 3: return .newInt32(x & y)
    case 4: return .newInt32(x | y)
    default: return .newInt32(x ^ y)
    }
}

/// Numeric (double operand) result of a fused arithmetic op. Sub-ops 3-5 are
/// the bitwise and/or/xor and produce an int32 like the plain opcodes do.
@inline(__always)
func jeffJS_arithNumeric(_ ar: UInt8, _ x: Double, _ y: Double) -> JeffJSValue {
    switch ar {
    case 0: return .newFloat64(x + y)
    case 1: return .newFloat64(x - y)
    case 2: return .newFloat64(x * y)
    case 3: return .newInt32(JeffJSTypeConvert.doubleToInt32(x) & JeffJSTypeConvert.doubleToInt32(y))
    case 4: return .newInt32(JeffJSTypeConvert.doubleToInt32(x) | JeffJSTypeConvert.doubleToInt32(y))
    default: return .newInt32(JeffJSTypeConvert.doubleToInt32(x) ^ JeffJSTypeConvert.doubleToInt32(y))
    }
}

/// Generic fused arithmetic (strings, objects, ...); consumes both values.
/// nil on exception.
@inline(never)
func jeffJS_arithGeneric(_ ctx: JeffJSContext, _ ar: UInt8, _ lhs: JeffJSValue, _ rhs: JeffJSValue) -> JeffJSValue? {
    if ar == 0 {
        let r = JeffJSOperators.jsAdd(ctx: ctx, lhs: lhs, rhs: rhs)
        lhs.freeValue(); rhs.freeValue()
        return r.isException ? nil : r
    }
    let (a, ok1) = JeffJSTypeConvert.toNumber(ctx: ctx, val: lhs)
    let (b, ok2) = JeffJSTypeConvert.toNumber(ctx: ctx, val: rhs)
    lhs.freeValue(); rhs.freeValue()
    if !ok1 || !ok2 { return nil }
    return jeffJS_arithNumeric(ar, a, b)
}

/// Guarded pop for the main dispatch loop (the fallback interpreter): a
/// bytecode sequence that pops more than it pushed returns undefined and is
/// reported once instead of reading below the value buffer. File-scope so it
/// captures none of the interpreter's locals (which would pin them to memory).
@inline(__always)
func jeffJS_pop(_ buf: UnsafeMutablePointer<JeffJSValue>, _ sp: inout Int, _ spBase: Int,
                _ ctx: JeffJSContext, _ fb: JeffJSFunctionBytecode, _ pc: Int) -> JeffJSValue {
    if sp <= spBase {
        jeffJS_reportStackUnderflow(ctx, fb, pc, sp, spBase)
        return .undefined
    }
    sp -= 1
    return buf[sp]
}

nonisolated(unsafe) var jeffJS_underflowReports = 0

@inline(never)
func jeffJS_reportStackUnderflow(_ ctx: JeffJSContext, _ fb: JeffJSFunctionBytecode, _ pc: Int, _ sp: Int, _ spBase: Int) {
    // The traces have no per-pop guards: keep this function out of them.
    fb.traceEntryEnabled = false
    if let blocks = fb.traceBlocks { for b in blocks.values { b.isActive = false; b.disabled = true } }
    guard jeffJS_underflowReports < 8 else { return }
    jeffJS_underflowReports += 1
    let opName: String
    if pc >= 0, pc < fb.bytecodeLen {
        let raw = fb.bytecode[pc]
        opName = raw == 0 && pc + 1 < fb.bytecodeLen ? "wide:\(fb.bytecode[pc + 1])" : (jeffJSGetOpcodeInfo(raw)?.name ?? "?\(raw)")
    } else { opName = "?" }
    let fname = ctx.rt.atomToString((fb as? JeffJSFunctionBytecodeCompiled)?.funcNameAtom ?? 0) ?? "<anon>"
    FileHandle.standardError.write("[JeffJS] VM stack underflow: op=\(opName) pc=\(pc) sp=\(sp) spBase=\(spBase) in \(fname)\n".data(using: .utf8)!)
}

/// Branch-condition fast path: comparison opcodes push exact JS_TRUE/JS_FALSE
/// bit patterns, so most `if_false`/`if_true` conditions never need the
/// generic ToBoolean.
@inline(__always)
func jeffJS_fastToBool(_ v: JeffJSValue) -> Bool {
    if v.bits == JeffJSValue.JS_TRUE.bits { return true }
    if v.bits == JeffJSValue.JS_FALSE.bits { return false }
    return JeffJSTypeConvert.toBool(v)
}

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
        // 2. A bound function has no prototype of its own: test against its
        //    target (following a chain of bindings).
        var target = target
        while let tObj = target.toObject(), case .boundFunction(let bound) = tObj.payload {
            target = bound.funcObj
        }
        // 3. If val is not an object, return false.
        guard let valObj = val.toObject() else { return false }
        // 4. Let P be target.prototype
        let protoVal = getProperty(obj: target, atom: JeffJSAtomID.JS_ATOM_prototype.rawValue)
        defer { protoVal.freeValue() }
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
    @inline(__always)
    static func dispatchCFunction(_ ctx: JeffJSContext, _ cFunction: JSCFunctionType,
                                  _ thisVal: JeffJSValue, _ args: [JeffJSValue], _ magic: Int) -> JeffJSValue {
        switch cFunction {
        case .generic(let fn): return fn(ctx, thisVal, args)
        case .genericMagic(let fn): return fn(ctx, thisVal, args, magic)
        case .constructor(let fn): return fn(ctx, thisVal, args)
        case .constructorOrFunc(let fn): return fn(ctx, thisVal, args, false)
        case .getter(let fn): return fn(ctx, thisVal)
        case .setter(let fn): return fn(ctx, thisVal, args.first ?? .undefined)
        case .getterMagic(let fn): return fn(ctx, thisVal, magic)
        case .setterMagic(let fn): return fn(ctx, thisVal, args.first ?? .undefined, magic)
        case .fFloat64(let fn): return .newFloat64(fn(args.first?.toFloat64() ?? .nan))
        case .fFloat64_2(let fn): return .newFloat64(fn(args.first?.toFloat64() ?? .nan, (args.count > 1 ? args[1] : .undefined).toFloat64()))
        case .iteratorNext(let fn): return fn(ctx, thisVal, args, nil, magic)
        }
    }

    func callFunction(_ funcVal: JeffJSValue, thisVal: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        if jeffJSZombiesEnabled, let zo = funcVal.obj, zo.asClass.freeMark {
            JeffJSZombieDebug.reportTouch("CALL", zo.asClass)   // calling a dead function: an under-retained reference
        }
        // activeRuntime is already set by JeffJSContext.init or eval() —
        // no need to write the static on every call.

        // Guard against stack overflow — C function callbacks can recurse back into callFunction
        callDepth += 1
        defer { callDepth -= 1 }
        if callDepth > JeffJSInterpreter.maxCallDepth {
            return throwInternalError(message: "Maximum call stack size exceeded")
        }
        if callDepth == 1 { rt.updateStackLimitForCurrentThread() }
        if rt.checkStackOverflow() {
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
        // Hot path: plain bytecode function — skip the payload-enum matches
        // below (each one copies the payload, retaining FB + varRefs array).
        if let fastFB = obj.fbFast, !fastFB.isGenerator, !fastFB.isAsyncFunc {
            return JeffJSInterpreter.callInternal(ctx: self, funcObj: funcVal,
                                                  thisVal: thisVal, args: args)
        }
        // C function path (mirrored fields: no payload copy per call). Checked
        // before the bound-function match below, which copies the payload.
        if let cf = obj.cFuncFast {
            return JeffJSContext.dispatchCFunction(self, cf, thisVal, args, obj.cMagicFast)
        }
        // Bound function path: unwrap and recurse with bound this/args
        if case .boundFunction(let bound) = obj.payload {
            var fullArgs = bound.argv
            fullArgs.append(contentsOf: args)
            return callFunction(bound.funcObj, thisVal: bound.thisVal, args: fullArgs)   // [[BoundThis]] as is
        }
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
            // Lazy capability: most async calls complete without suspending,
            // so the result-promise + resolver pair is only built if await_
            // actually suspends (it sees the `.uninitialized` marker). A
            // non-suspending call returns a directly-settled promise — no
            // resolver functions, no reactions, no microtask drain.
            let prevResolve = _asyncResolve
            let prevReject = _asyncReject
            let prevCapPromise = _asyncCapPromise
            let prevSuspended = _asyncSuspended
            _asyncResolve = .uninitialized
            _asyncReject = .uninitialized
            _asyncCapPromise = .undefined
            _asyncSuspended = false

            let result = JeffJSInterpreter.callInternal(ctx: self, funcObj: funcVal,
                                                         thisVal: thisVal, args: args, flags: 0)

            let suspended = _asyncSuspended
            let capPromise = _asyncCapPromise
            // Restore previous async state (for nested async calls)
            _asyncResolve = prevResolve
            _asyncReject = prevReject
            _asyncCapPromise = prevCapPromise
            _asyncSuspended = prevSuspended

            if suspended {
                // Function suspended at await — return the pending Promise
                // created lazily by await_. Resolved when the awaited Promise
                // settles (via the stored capability in AsyncSavedEntry).
                return capPromise
            }
            if result.isException {
                let err = getException()
                let rejected = JeffJSBuiltinPromise.makeSettledPromise(
                    ctx: self, value: err, fulfilled: false)
                err.freeValue()
                return rejected
            }
            if result.isObject {
                // The return value may be a promise/thenable, which the result
                // promise must ADOPT (not fulfill with). Use a real resolver.
                guard let cap = JeffJSBuiltinPromise.newPromiseCapability(ctx: self, ctor: .undefined) else {
                    return JeffJSBuiltinPromise.makeSettledPromise(ctx: self, value: result, fulfilled: true)
                }
                _ = call(cap.resolve, this: .undefined, args: [result])
                result.freeValue()
                _ = rt.executePendingJobs()
                return cap.promise
            }
            let fulfilled = JeffJSBuiltinPromise.makeSettledPromise(
                ctx: self, value: result, fulfilled: true)
            result.freeValue()
            return fulfilled
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
        // `result` (the returned or yielded value) is owned by us;
        // createIterResult copies it, so release it after wrapping.
        if genData.state == .executing {
            genData.state = .completed
            genData.savedState = nil
            let iterResult = JeffJSBuiltinIterator.createIterResult(ctx: self, val: result, done: true)
            result.freeValue()
            return iterResult
        }

        // If still suspended (yield set the state), the result is the yielded
        // value, wrapped as {value, done: false}.
        let iterResult = JeffJSBuiltinIterator.createIterResult(ctx: self, val: result, done: false)
        result.freeValue()
        return iterResult
    }

    // MARK: - Object Creation Stubs

    /// Creates a special object (arguments, mapped arguments, etc.) based on kind.
    func newSpecialObject(kind: UInt8, frame: JeffJSStackFrame) -> JeffJSValue {
        switch SpecialObjectType(rawValue: kind) {
        case .arguments, .mappedArguments:
            // Arguments objects of one kind and count all share one transition
            // shape (indices, length[, callee], @@iterator). After the first,
            // creation is one object plus slot appends; the old path paid N + 3
            // property adds through the transition table every time.
            let mapped = kind == SpecialObjectType.mappedArguments.rawValue
            let argc = frame.argBuf.count
            let fixedCount = mapped ? 3 : 2
            let argsObj = newObject()
            guard let o = argsObj.toObject() else { return argsObj }
            let iterFn: JeffJSValue = arrayProtoValues.isFunction ? arrayProtoValues.dupValue() : .undefined
            if argc < argumentsShapesMapped.count,
               let shape = (mapped ? argumentsShapesMapped : argumentsShapesStrict)[argc],
               shape.isHashed, shape.propCount == argc + fixedCount,
               o.propValues.count == 0, let old = o.shape {
                shape.refCount += 1
                o.shape = shape
                jeffJS_leaveShape(rt, old)
                for a in frame.argBuf { o.appendDataValue(a.dupValue()) }
                o.appendDataValue(.newInt32(Int32(argc)))                  // length
                if mapped { o.appendDataValue(frame.curFunc.dupValue()) }  // callee
                o.appendDataValue(iterFn)                                  // @@iterator
                return argsObj
            }
            // First object of this kind and count: build it property by
            // property (length, callee and @@iterator non-enumerable, as the
            // spec has them) and remember the resulting transition shape.
            for (i, arg) in frame.argBuf.enumerated() {
                _ = setPropertyUint32(obj: argsObj, index: UInt32(i), value: arg.dupValue())
            }
            let wc = JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE
            _ = definePropertyValue(obj: argsObj, atom: JeffJSAtomID.JS_ATOM_length.rawValue,
                                    value: .newInt32(Int32(argc)), flags: wc)
            if mapped {
                _ = definePropertyValue(obj: argsObj, atom: JeffJSAtomID.JS_ATOM_callee.rawValue,
                                        value: frame.curFunc.dupValue(), flags: wc)
            }
            _ = definePropertyValue(obj: argsObj, atom: JeffJSAtomID.JS_ATOM_Symbol_iterator.rawValue,
                                    value: iterFn, flags: wc)
            if argc < argumentsShapesMapped.count, let sh = o.shape, sh.isHashed,
               sh.propCount == argc + fixedCount, o.propValues.count == sh.propCount {
                sh.refCount += 1   // the context keeps the shape alive
                if mapped { argumentsShapesMapped[argc] = sh } else { argumentsShapesStrict[argc] = sh }
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
                return JeffJSValue.makeObjectRecycled(home).dupValue()   // owned reference
            }
            return .undefined
        case .homeObjectProto:
            // Base for `super.x`: the prototype of the method's [[HomeObject]].
            if let funcObj = frame.curFunc.toObject(),
               case .bytecodeFunc(_, _, let homeObj) = funcObj.payload,
               let home = homeObj {
                if let p = home.proto { return JeffJSValue.makeObjectRecycled(p).dupValue() }
                return .null
            }
            _ = throwSyntaxError(message: "'super' keyword unexpected here")
            return .exception
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

    /// Creates a new array from the given items, taking ownership of each.
    func newArrayFrom(_ items: [JeffJSValue]) -> JeffJSValue {
        let arr = newArray()
        if items.isEmpty { return arr }
        // Fill the element storage in one shot. Going through the generic
        // indexed setter interned an index atom, walked the prototype chain
        // and grew the backing store once per element; for-in key lists and
        // every builtin that returns an array paid that per element.
        if let obj = arr.toObject(), obj.fastArray, obj.arraySnapshot()?.count == 0 {
            obj.installFastArrayValues(ContiguousArray(items))
            setArrayLength(arr, Int64(items.count))
            return arr
        }
        for (i, item) in items.enumerated() {
            _ = setPropertyUint32(obj: arr, index: UInt32(i), value: item)
        }
        setArrayLength(arr, Int64(items.count))
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
        if !innerFB.closureVarsList.isEmpty {
            let closureVars = innerFB.closureVarsList
            childVarRefs.reserveCapacity(closureVars.count)
            for cv in closureVars {
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
                        // Direct slot pointer (see JeffJSVarRef.slot). Generator /
                        // async frames re-acquire their buffer on resume, so they
                        // keep the frame-based lookup.
                        if !fb.isGenerator, !fb.isAsyncFunc, let b = parentFrame.buf {
                            if cv.isArg {
                                if cv.varIdx < parentFrame.bufVarBase { vr.slot = b + cv.varIdx }
                            } else {
                                vr.slot = b + parentFrame.bufVarBase + cv.varIdx
                            }
                        }
                        parentFrame.liveVarRefs.append(vr)
                        parentFrame.hasLiveVarRefs = true
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
        obj.fbFast = innerFB
        obj.varRefsFast = childVarRefs

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
            obj.shape = jeffJS_rootShape(self, proto: closureProto)
        }
        // Set proto after shape (proto may already be synced via shape)
        obj.proto = closureProto

        let funcVal = JeffJSValue.makeObject(obj)

        // For regular (non-arrow, non-generator, non-async) functions,
        // F.prototype = { constructor: F } is built LAZILY on first access
        // (see materializeFunctionPrototype). Building it eagerly cost an
        // object + shape + two property defines per closure — most closures
        // are never used as constructors.
        if !innerFB.isGenerator && !innerFB.isAsyncFunc && !innerFB.isArrow {
            obj.needsLazyPrototype = true
            obj.isConstructor = true
        }

        return funcVal
    }

    /// Materialize the default `F.prototype = { constructor: F }` pair for a
    /// function whose prototype creation was deferred at closure time.
    /// Self-guarding: if an own `prototype` was defined in the meantime
    /// (class setup, explicit `F.prototype = x`), it is left untouched.
    func materializeFunctionPrototype(_ funcObj: JeffJSObject) {
        funcObj.needsLazyPrototype = false
        if jeffJS_findOwnPropertyIndex(obj: funcObj,
                                       atom: JeffJSAtomID.JS_ATOM_prototype.rawValue) >= 0 {
            return
        }
        let funcVal = JeffJSValue.mkPtr(tag: .object, ptr: funcObj)
        defer { funcVal.freeValue() }
        let protoObj = newObject()
        _ = setPropertyStr(obj: protoObj, name: "constructor", value: funcVal.dupValue())
        _ = setPropertyStr(obj: funcVal, name: "prototype", value: protoObj)
    }

    // MARK: - Atom Helpers

    /// Converts an atom to a JS string value.
    func atomToString(_ atom: UInt32) -> JeffJSValue {
        if (atom & JS_ATOM_TAG_INT) != 0 { return intKeyString(Int(atom & ~JS_ATOM_TAG_INT)) }
        if let cached = rt.atomJSStrings[atom] { return JeffJSValue.makeString(cached.retain()) }
        guard let str = rt.atomToString(atom) else { return .undefined }
        let js = JeffJSString(swiftString: str)   // refCount 1: the cache's reference
        rt.atomJSStrings[atom] = js
        return JeffJSValue.makeString(js.retain())
    }

    /// Shared JS string for a `typeof` result. Falls back to a fresh string
    /// for anything outside the fixed set.
    func typeofString(_ t: String) -> JeffJSValue {
        let idx: Int
        switch t {
        case "object": idx = 0
        case "function": idx = 1
        case "string": idx = 2
        case "number": idx = 3
        case "boolean": idx = 4
        case "undefined": idx = 5
        case "symbol": idx = 6
        case "bigint": idx = 7
        default: return newString(t)
        }
        if let cached = rt.typeofStrings[idx] { return JeffJSValue.makeString(cached.retain()) }
        let js = JeffJSString(swiftString: t)   // refCount 1: the cache's reference
        rt.typeofStrings[idx] = js
        return JeffJSValue.makeString(js.retain())
    }

    /// Cached string for a small integer key (array indices in for-in / keys).
    func intKeyString(_ i: Int) -> JeffJSValue {
        if i >= 0 && i < rt.intKeyStrings.count {
            if let c = rt.intKeyStrings[i] { return JeffJSValue.makeString(c.retain()) }
            let js = JeffJSString(swiftString: String(i))
            rt.intKeyStrings[i] = js
            return JeffJSValue.makeString(js.retain())
        }
        return newStringValue(String(i))
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
        let protoVal = JeffJSValue.makeObjectRecycled(proto)
        if !protoVal.isFunction {
            _ = throwTypeError(message: "super constructor is not a constructor")
            return .exception
        }
        return protoVal.dupValue()   // owned: the call site releases it
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
        // Fast path: plain data property on the global object itself.
        // One hash probe; covers the overwhelming majority of global reads
        // (top-level `var`s and builtins). Existence is established by the
        // shape hit, so globals whose value *is* `undefined` work correctly.
        if let gObj = globalObj.toObject() {
            let idx = jeffJS_findOwnPropertyIndex(obj: gObj, atom: atom)
            if idx >= 0 {
                if let shape = gObj.shape, idx < gObj.propCount,
                   !shape.prop[idx].flags.contains(.getset),
                   gObj.extra(at: idx) == nil {
                    return gObj.dataValue(at: idx).dupValue()
                }
                // Accessor or exotic slot — take the full path.
                return getProperty(obj: globalObj, atom: atom)
            }
            // Not an own property: check the prototype chain before deciding
            // between undefined and ReferenceError.
            var proto = gObj.proto
            while let p = proto {
                if jeffJS_findOwnPropertyIndex(obj: p, atom: atom) >= 0 {
                    return getProperty(obj: globalObj, atom: atom)
                }
                proto = p.proto
            }
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
        // Fast path: overwrite an existing writable data property in place.
        if let gObj = globalObj.toObject(), let shape = gObj.shape {
            let idx = jeffJS_findOwnPropertyIndex(obj: gObj, atom: atom)
            if idx >= 0, idx < gObj.propCount {
                let f = shape.prop[idx].flags
                if !f.contains(.getset), f.contains(.writable),
                   gObj.extra(at: idx) == nil {
                    let old = gObj.propValues[idx]
                    gObj.propValues[idx] = val
                    old.freeValue()
                    return true
                }
            }
        }
        return setProperty(obj: globalObj, atom: atom, value: val) >= 0
    }

    /// Defines a new global variable (CreateGlobalVarBinding).  An existing
    /// binding is left untouched: `var x = ...` inside a loop re-executes
    /// define_var every iteration, and redefining the slot with `undefined`
    /// would drop the previous value without releasing it.
    func defineGlobalVar(atom: UInt32, flags: Int) -> Bool {
        if let gObj = globalObj.toObject(), gObj.shape != nil,
           jeffJS_findOwnPropertyIndex(obj: gObj, atom: atom) >= 0 {
            return true
        }
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
            let atom = rt.findAtom(jsString: str)
            let result = getProperty(obj: obj, atom: atom)
            rt.freeAtom(atom)
            return result
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
            let atom = rt.findAtom(jsString: str)
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
        // "name" is a predefined atom and the name string is cached per atom:
        // this used to intern "name" and allocate a fresh string on every
        // closure creation, which React does constantly.
        guard atom != 0 else { return }
        let nameValue = atomToString(atom)
        if nameValue.isUndefined { return }
        _ = setProperty(obj: funcVal, atom: JeffJSAtomID.JS_ATOM_name.rawValue,
                        value: nameValue)
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
            guard i < srcObj.propCount else { continue }
            let propEntry = srcObj.propEntry(at: i)
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
        let val: JeffJSValue
        if let b = frame.buf {
            guard idx < frame.varCount else { return }
            val = b[frame.bufVarBase + idx]
        } else {
            guard idx < frame.varBuf.count else { return }
            val = frame.varBuf[idx]
        }
        // Detach every live var-ref that targets this local slot, and drop
        // detached refs from the list: it used to grow by one per closure
        // created in a loop and was scanned on every close_loc (quadratic).
        var i = 0
        var n = frame.liveVarRefs.count
        while i < n {
            let vr = frame.liveVarRefs[i]
            if !vr.isDetached && !vr.isArg && Int(vr.varIdx) == idx {
                vr.value = val.dupValue()
                vr.isDetached = true
                vr.parentFrame = nil; vr.slot = nil
            }
            if vr.isDetached {
                n -= 1
                if i != n { frame.liveVarRefs.swapAt(i, n) }
            } else {
                i += 1
            }
        }
        if n < frame.liveVarRefs.count { frame.liveVarRefs.removeLast(frame.liveVarRefs.count - n) }
        if n == 0 { frame.hasLiveVarRefs = false }
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
        let keys = forInKeyList(obj: obj)
        let iter = newObject()
        if let o = iter.toObject() { o.payload = .forInIterator(JeffJSForInIterator(keys: keys)) }
        return iter
    }

    /// Own enumerable string keys of `shape` in for-in order (integer keys
    /// ascending, then names in insertion order), from the shape's cache.
    /// Every object on a hashed shape shares one list, so a loop over the
    /// same kind of object (props, style, fiber...) builds no keys at all.
    func shapeEnumKeys(_ shape: JeffJSShape) -> JeffJSForInKeyList {
        if let cached = shape.enumKeyCache { return cached }
        var intKeys: [UInt32] = []
        var keys: [JeffJSValue] = []
        for prop in shape.prop {
            let atom = prop.atom
            if atom == 0 || !prop.flags.contains(.enumerable) { continue }
            if rt.atomIsArrayIndex(atom) {
                if let idx = rt.atomToUInt32(atom) { intKeys.append(idx) }
            } else if let entry = rt.atomArray[Int(atom)],
                      entry.atomType != .JS_ATOM_TYPE_SYMBOL,
                      entry.atomType != .JS_ATOM_TYPE_GLOBAL_SYMBOL {
                keys.append(atomToString(atom))
            }
        }
        if !intKeys.isEmpty {
            intKeys.sort()
            var ordered: [JeffJSValue] = []
            ordered.reserveCapacity(intKeys.count + keys.count)
            for idx in intKeys { ordered.append(intKeyString(Int(idx))) }
            ordered.append(contentsOf: keys)
            keys = ordered
        }
        let list = JeffJSForInKeyList(keys: keys)
        shape.enumKeyCache = list
        return list
    }

    /// The keys `for (k in obj)` visits. When neither the object nor any
    /// prototype has fast-array elements and no prototype contributes an
    /// enumerable key (the normal case: a plain object over Object.prototype),
    /// the object's own cached list is returned as is. Otherwise the list is
    /// built level by level with the usual shadowing rules.
    func forInKeyList(obj: JeffJSValue) -> JeffJSForInKeyList {
        guard let root = obj.toObject() else { return JeffJSForInKeyList(keys: []) }   // null / undefined
        if let rootShape = root.shape, root.arraySnapshot() == nil {
            var protosEmpty = true
            var p = root.proto
            while let cur = p {
                guard let sh = cur.shape, cur.arraySnapshot() == nil, shapeEnumKeys(sh).keys.isEmpty else {
                    protosEmpty = false
                    break
                }
                p = cur.proto
            }
            if protosEmpty { return shapeEnumKeys(rootShape) }
        }

        // General path: integer keys ascending then names per level, with a
        // non-enumerable own property shadowing an enumerable one further up
        // the chain (ES §14.7.5.9). Shadowing is resolved on interned identity
        // (index by value, name by atom).
        var keys = [JeffJSValue]()
        var seenIdx = JeffJSKeySeen()
        var seenAtom = JeffJSKeySeen()
        var intKeys: [UInt32] = []
        var strKeys: [UInt32] = []
        var current: JeffJSObject? = root
        while let cur = current {
            intKeys.removeAll(keepingCapacity: true)
            strKeys.removeAll(keepingCapacity: true)
            // Fast-array elements are not shape properties: enumerate their
            // indices (present, i.e. not a hole) first.
            if let snap = cur.arraySnapshot() {
                var i = 0
                while i < snap.count && i < snap.values.count {
                    if !snap.values[i].isUninitialized { intKeys.append(UInt32(i)) }
                    i += 1
                }
            }
            if let shape = cur.shape {
                for prop in shape.prop {
                    let atom = prop.atom
                    if atom == 0 { continue }
                    let isEnumerable = prop.flags.contains(.enumerable)
                    if rt.atomIsArrayIndex(atom) {
                        if let idx = rt.atomToUInt32(atom) {
                            if isEnumerable { intKeys.append(idx) } else { _ = seenIdx.insert(idx) }
                        }
                    } else if let entry = rt.atomArray[Int(atom)],
                              entry.atomType != .JS_ATOM_TYPE_SYMBOL,
                              entry.atomType != .JS_ATOM_TYPE_GLOBAL_SYMBOL {
                        // Symbol keys are never enumerated by for-in.
                        if isEnumerable { strKeys.append(atom) } else { _ = seenAtom.insert(atom) }
                    }
                }
            }
            intKeys.sort()
            for idx in intKeys where seenIdx.insert(idx) {
                keys.append(intKeyString(Int(idx)))
            }
            for atom in strKeys where seenAtom.insert(atom) {
                keys.append(atomToString(atom))
            }
            current = cur.proto
        }
        return JeffJSForInKeyList(keys: keys)
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
        guard let o = iter.toObject(), case .forInIterator(let st) = o.payload else {
            return (.undefined, true)
        }
        if st.idx >= st.keys.keys.count { return (.undefined, true) }
        let key = st.keys.keys[st.idx]
        st.idx += 1
        return (key.dupValue(), false)
    }

    /// Gets the next value from an iterator.
    func iteratorNext(iter: JeffJSValue) -> JeffJSValue {
        let nextFn = getProperty(obj: iter, atom: iterNextAtom)
        defer { nextFn.freeValue() }   // was leaked once per step
        if nextFn.isFunction {
            return callFunction(nextFn, thisVal: iter, args: [])
        }
        return .undefined
    }

    /// Checks if an iterator result is done.
    func iteratorCheckDone(result: JeffJSValue) -> Bool {
        let done = getProperty(obj: result, atom: JeffJSAtomID.JS_ATOM_done.rawValue)
        let r = jeffJS_fastToBool(done)
        done.freeValue()
        return r
    }

    /// Gets the value from an iterator result.
    func iteratorGetValue(result: JeffJSValue) -> JeffJSValue {
        return getProperty(obj: result, atom: JeffJSAtomID.JS_ATOM_value.rawValue)
    }

    /// Closes an iterator.
    func iteratorClose(iter: JeffJSValue, isThrow: Bool) {
        let returnFn = getProperty(obj: iter, atom: iterReturnAtom)
        if returnFn.isFunction {
            let r = callFunction(returnFn, thisVal: iter, args: [])
            r.freeValue()
        }
        returnFn.freeValue()
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
            if handler(rt) {
                // Interrupts are UNCATCHABLE termination: mark the context so
                // exception unwinding skips catch handlers entirely. Without
                // this, the interrupt "exception" (a null currentException)
                // was caught by user try/catch, the handler fired again at its
                // next check, and the cycle grew the VM stack by a
                // [catchOffset, null] pair per iteration until it overflowed —
                // the source of the long-standing heap corruption.
                interruptTerminated = true
                return true
            }
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

// Bytecode is read through a raw `UnsafePointer<UInt8>` into a stable,
// FB-owned buffer (JeffJSFunctionBytecode.bytecodePtr). This removes the
// per-read Array bounds checks that were ~24% of a pure dispatch loop after
// exclusivity enforcement was disabled. Operand presence is guaranteed by the
// compiler (well-formed bytecode), the same invariant the opcode bitcast
// relies on; the dispatch loop still bounds the program counter via `pc < bcLen`.

/// Read a UInt8 from bytecode at the given offset.
@inline(__always)
private func readU8(_ bc: UnsafePointer<UInt8>, _ pos: Int) -> UInt8 {
    return bc[pos]
}

/// Read a signed Int8 from bytecode.
@inline(__always)
private func readI8(_ bc: UnsafePointer<UInt8>, _ pos: Int) -> Int8 {
    return Int8(bitPattern: bc[pos])
}

/// Read a little-endian UInt16 from bytecode.
@inline(__always)
private func readU16(_ bc: UnsafePointer<UInt8>, _ pos: Int) -> UInt16 {
    return UInt16(bc[pos]) | (UInt16(bc[pos + 1]) << 8)
}

/// Read a little-endian Int16 from bytecode.
@inline(__always)
private func readI16(_ bc: UnsafePointer<UInt8>, _ pos: Int) -> Int16 {
    return Int16(bitPattern: readU16(bc, pos))
}

/// Read a little-endian UInt32 from bytecode.
@inline(__always)
private func readU32(_ bc: UnsafePointer<UInt8>, _ pos: Int) -> UInt32 {
    return UInt32(bc[pos]) |
           (UInt32(bc[pos + 1]) << 8) |
           (UInt32(bc[pos + 2]) << 16) |
           (UInt32(bc[pos + 3]) << 24)
}

/// Read a little-endian Int32 from bytecode.
@inline(__always)
private func readI32(_ bc: UnsafePointer<UInt8>, _ pos: Int) -> Int32 {
    return Int32(bitPattern: readU32(bc, pos))
}

/// Check if the opcode byte at `pos` in the bytecode is a "store variable"
/// opcode that pops a value from the stack.  Used to detect chained
/// assignment patterns (e.g., `a = b = c = 5`) where intermediate stores
/// must keep the value on the stack for the next store.
/// 256-bit store-opcode membership mask, indexed by raw opcode byte.
/// `isStoreOpcode` runs on EVERY put_loc/put_var execution (chained-assignment
/// lookahead), so it must be a couple of bit ops — not an enum init + switch.
/// True for a plain bytecode function: its frame borrows the caller's
/// argument references only for the duration of the call, so the caller
/// may release them afterwards. Generators and async functions keep their
/// frame (and those references) alive across suspensions.
@inline(__always)
func jeffJS_isPlainBytecodeCallee(_ v: JeffJSValue) -> Bool {
    guard let o = v.obj, let fb = o.fbFast else { return false }
    return !fb.isGenerator && !fb.isAsyncFunc
}

/// Filled once at runtime bootstrap (jeffJS_computeStoreOpcodeMask): a
/// stored global is a plain load, a lazily-initialised `let` costs a
/// swift_once-guarded addressor call on every isStoreOpcode.
nonisolated(unsafe) var jeffJS_storeOpcodeMask: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)

func jeffJS_computeStoreOpcodeMask() {
    var m: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    let ops: [JeffJSOpcode] = [
        .put_loc, .put_loc0, .put_loc1, .put_loc2, .put_loc3, .put_loc8,
        .put_var,
        .put_arg, .put_arg0, .put_arg1, .put_arg2, .put_arg3,
        .put_var_ref,
        .put_field, .put_array_el,
    ]
    for op in ops {
        let v = Int(op.rawValue)
        guard v < 256 else { continue }
        let bit = UInt64(1) << UInt64(v & 63)
        switch v >> 6 {
        case 0: m.0 |= bit
        case 1: m.1 |= bit
        case 2: m.2 |= bit
        default: m.3 |= bit
        }
    }
    jeffJS_storeOpcodeMask = m
}

@inline(__always)
private func isStoreOpcode(_ bc: UnsafePointer<UInt8>, _ pos: Int, _ bcLen: Int) -> Bool {
    guard pos < bcLen else { return false }
    let b = bc[pos]
    let m = jeffJS_storeOpcodeMask
    let bit = UInt64(b & 63)
    switch b >> 6 {
    case 0: return (m.0 >> bit) & 1 != 0
    case 1: return (m.1 >> bit) & 1 != 0
    case 2: return (m.2 >> bit) & 1 != 0
    default: return (m.3 >> bit) & 1 != 0
    }
}

/// True if `b` is one of the plain-call opcodes (call, call0…call3) that read
/// `frame.lastGetFieldReceiver` as the method `this`. Used by get_field to
/// decide whether to stash the receiver: the call consumer requires the call to
/// sit exactly 5 bytes after the get_field (pc == lastGetFieldPC + 5), so only a
/// directly-following call needs the stash. `call_method`/`call_constructor`
/// take their receiver from the stack instead and are intentionally excluded.
/// All five opcodes are < 256, so a single-byte compare is exact.
@inline(__always)
private func isCallOpcodeByte(_ b: UInt8) -> Bool {
    b == UInt8(truncatingIfNeeded: JeffJSOpcode.call.rawValue)
        || b == UInt8(truncatingIfNeeded: JeffJSOpcode.call0.rawValue)
        || b == UInt8(truncatingIfNeeded: JeffJSOpcode.call1.rawValue)
        || b == UInt8(truncatingIfNeeded: JeffJSOpcode.call2.rawValue)
        || b == UInt8(truncatingIfNeeded: JeffJSOpcode.call3.rawValue)
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
    state: inout JeffJSInterpreter.HotState,
    startPC: Int,
    ctx: JeffJSContext,
    rt: JeffJSRuntime,
    inlineBase: Int
) -> Int {
    // Unpack the per-opcode state into locals (registers). Values that only
    // calls/returns touch (capacity, stack base, function object, flags,
    // ownership bits) stay in `state`: as locals they pushed this function
    // into ~500 stack spills. Everything is written back at the single exit.
    var pc = startPC
    var sp = state.sp
    var buf = state.buf
    var varBase = state.varBase
    var bc = state.bc
    var bcLen = state.bcLen
    unowned(unsafe) var fb: JeffJSFunctionBytecode = state.fb   // no retain/release per call entry/return
    unowned(unsafe) var frame: JeffJSStackFrame = state.frame
    var varRefsRaw = state.varRefsRaw
    var varRefsRawCount = state.varRefsRawCount
    guard pc >= 0, pc < bcLen, sp >= 0, sp < state.bufCapacity else { return startPC }
    var resume = startPC
    var opsRun = 0   // progress measure for the main loop's deopt guard
    var interrupt = ctx.interruptCounter   // kept in a register; written back at exit

    traceLoop: while true {
        #if DEBUG
        assert(pc >= 0 && pc < bcLen && sp >= 0 && sp < state.bufCapacity, "fast trace out of bounds")
        #endif
        // Same raw decode as the main loop: every narrow byte is a valid
        // case; the 0x00 wide prefix decodes to .invalid and deopts below.
        // Raw byte test for the 0x00 wide-opcode prefix: an enum `==` here
        // compiled to an out-of-line generic call (15% of a pure loop).
        let opByte = bc[pc]
        opsRun &+= 1
        // Byte 0 is the wide-opcode prefix: it decodes to .invalid, whose
        // case below deopts (no separate compare per opcode).
        let op = unsafeBitCast(UInt16(opByte), to: JeffJSOpcode.self)
        #if JEFFJS_OPPROF
        jeffJS_opProfRecord(Int(opByte))
        #endif

        switch op {
        case .invalid:
            resume = pc; break traceLoop

        // =================================================================
        // Push values
        // =================================================================

        case .cmp_loc_i8:
            let cmp = bc[pc + 1]
            let cond: Bool
            let a = buf[varBase + Int(bc[pc + 2])]
            let k = Int32(Int8(bitPattern: bc[pc + 3]))
            if a.isInt {
                cond = jeffJS_cmpInt(cmp, a.toInt32(), k)
            } else if a.isNumber {
                cond = jeffJS_cmpDouble(cmp, a.toFloat64(), Double(k))
            } else { resume = pc; break traceLoop }
            // Fused branch: when if_true8 / if_false8 follows, branch here
            // instead of pushing a bool for the next dispatch to pop.
            let nb = bc[pc + 4]
            if nb == UInt8(truncatingIfNeeded: JeffJSOpcode.if_true8.rawValue)
                || nb == UInt8(truncatingIfNeeded: JeffJSOpcode.if_false8.rawValue) {
                let take = nb == UInt8(truncatingIfNeeded: JeffJSOpcode.if_true8.rawValue) ? cond : !cond
                if take {
                    let offset = Int(Int8(bitPattern: bc[pc + 5]))
                    let target = pc + 6 + offset
                    if target < 0 || target >= bcLen { resume = target; break traceLoop }
                    if offset < 0 {
                        interrupt -= 1
                        if interrupt <= 0 {
                            interrupt = JS_INTERRUPT_COUNTER_INIT
                            ctx.interruptCounter = interrupt
                            if ctx.checkInterrupt() { resume = -1; break traceLoop }
                        }
                    }
                    pc = target
                } else {
                    pc += 6
                }
            } else {
                buf[sp] = cond ? .JS_TRUE : .JS_FALSE; sp += 1
                pc += 4
            }

        case .cmp_loc_loc:
            let cmp = bc[pc + 1]
            let cond: Bool
            let a = buf[varBase + Int(bc[pc + 2])]
            let b = buf[varBase + Int(bc[pc + 3])]
            if a.isInt && b.isInt {
                cond = jeffJS_cmpInt(cmp, a.toInt32(), b.toInt32())
            } else if a.isNumber && b.isNumber {
                cond = jeffJS_cmpDouble(cmp, jeffJS_traceNum(a), jeffJS_traceNum(b))
            } else { resume = pc; break traceLoop }
            // Fused branch: when if_true8 / if_false8 follows, branch here
            // instead of pushing a bool for the next dispatch to pop.
            let nb = bc[pc + 4]
            if nb == UInt8(truncatingIfNeeded: JeffJSOpcode.if_true8.rawValue)
                || nb == UInt8(truncatingIfNeeded: JeffJSOpcode.if_false8.rawValue) {
                let take = nb == UInt8(truncatingIfNeeded: JeffJSOpcode.if_true8.rawValue) ? cond : !cond
                if take {
                    let offset = Int(Int8(bitPattern: bc[pc + 5]))
                    let target = pc + 6 + offset
                    if target < 0 || target >= bcLen { resume = target; break traceLoop }
                    if offset < 0 {
                        interrupt -= 1
                        if interrupt <= 0 {
                            interrupt = JS_INTERRUPT_COUNTER_INIT
                            ctx.interruptCounter = interrupt
                            if ctx.checkInterrupt() { resume = -1; break traceLoop }
                        }
                    }
                    pc = target
                } else {
                    pc += 6
                }
            } else {
                buf[sp] = cond ? .JS_TRUE : .JS_FALSE; sp += 1
                pc += 4
            }

        case .arith_loc_loc:
            let ar = bc[pc + 1]
            let a = buf[varBase + Int(bc[pc + 2])]
            let b = buf[varBase + Int(bc[pc + 3])]
            if a.isInt && b.isInt {
                buf[sp] = jeffJS_arithInt(ar, a.toInt32(), b.toInt32()); sp += 1
            } else if a.isNumber && b.isNumber {
                buf[sp] = jeffJS_arithNumeric(ar, jeffJS_traceNum(a), jeffJS_traceNum(b)); sp += 1
            } else if ar == 0 && a.isString && b.isString {
                let r = jeffJS_concatStrings(s1: a, s2: b)
                if r.isException { resume = pc; break traceLoop }
                buf[sp] = r; sp += 1
            } else { resume = pc; break traceLoop }
            pc += 4

        case .arith_loc_i8:
            let ar = bc[pc + 1]
            let a = buf[varBase + Int(bc[pc + 2])]
            let k = Int32(Int8(bitPattern: bc[pc + 3]))
            if a.isInt {
                buf[sp] = jeffJS_arithInt(ar, a.toInt32(), k); sp += 1
            } else if a.isNumber {
                buf[sp] = jeffJS_arithNumeric(ar, a.toFloat64(), Double(k)); sp += 1
            } else { resume = pc; break traceLoop }
            pc += 4

        case .to_int32:
            let v = buf[sp - 1]
            if v.isInt {
            } else if v.isNumber {
                buf[sp - 1] = .newInt32(JeffJSTypeConvert.doubleToInt32(v.toFloat64()))
            } else { resume = pc; break traceLoop }
            pc += 1

        case .arith_const8:
            let ar = bc[pc + 1]
            let k = Int(bc[pc + 2])
            guard k < fb.cpool.count else { resume = pc; break traceLoop }
            let c = fb.cpool[k]
            let v = buf[sp - 1]
            if v.isInt && c.isInt {
                buf[sp - 1] = jeffJS_arithInt(ar, v.toInt32(), c.toInt32())
            } else if v.isNumber && c.isNumber {
                buf[sp - 1] = jeffJS_arithNumeric(ar, jeffJS_traceNum(v), jeffJS_traceNum(c))
            } else if ar == 0 && v.isString && c.isString {
                // `s += "lit"`: rope/buffer append, TOS is consumed
                let r = jeffJS_concatStrings(s1: v, s2: c)
                if r.isException { resume = pc; break traceLoop }
                v.freeValue()
                buf[sp - 1] = r
            } else { resume = pc; break traceLoop }
            pc += 3

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
            if idx < fb.cpool.count {
                buf[sp] = fb.cpool[idx].dupValue()
            } else {
                buf[sp] = .undefined
            }
            sp += 1
            pc += 5

        case .push_const8:
            let idx = Int(bc[pc + 1])
            buf[sp] = idx < fb.cpool.count ? fb.cpool[idx].dupValue() : .undefined
            sp += 1
            pc += 2

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

        case .put_loc0: sp -= 1; let oP0 = buf[varBase]; buf[varBase] = buf[sp]; oP0.freeValueFast(); pc += 1
        case .put_loc1: sp -= 1; let oP1 = buf[varBase + 1]; buf[varBase + 1] = buf[sp]; oP1.freeValueFast(); pc += 1
        case .put_loc2: sp -= 1; let oP2 = buf[varBase + 2]; buf[varBase + 2] = buf[sp]; oP2.freeValueFast(); pc += 1
        case .put_loc3: sp -= 1; let oP3 = buf[varBase + 3]; buf[varBase + 3] = buf[sp]; oP3.freeValueFast(); pc += 1

        case .put_loc8:
            let idx = Int(bc[pc + 1])
            sp -= 1; let oPL8 = buf[varBase + idx]; buf[varBase + idx] = buf[sp]; oPL8.freeValueFast()
            pc += 2

        case .put_loc:
            let idx = Int(readU16(bc, pc + 1))
            sp -= 1; let oPL = buf[varBase + idx]; buf[varBase + idx] = buf[sp]; oPL.freeValueFast()
            pc += 3

        case .set_loc0: let oS0 = buf[varBase]; buf[varBase] = buf[sp - 1].dupValueFast(); oS0.freeValueFast(); pc += 1
        case .set_loc1: let oS1 = buf[varBase + 1]; buf[varBase + 1] = buf[sp - 1].dupValueFast(); oS1.freeValueFast(); pc += 1
        case .set_loc2: let oS2 = buf[varBase + 2]; buf[varBase + 2] = buf[sp - 1].dupValueFast(); oS2.freeValueFast(); pc += 1
        case .set_loc3: let oS3 = buf[varBase + 3]; buf[varBase + 3] = buf[sp - 1].dupValueFast(); oS3.freeValueFast(); pc += 1

        case .set_loc8:
            // Store and keep the value: the slot needs its own reference and the
            // previous binding goes (sharing one ref with the stack double-freed).
            let idx = Int(bc[pc + 1])
            let oldSL = buf[varBase + idx]
            buf[varBase + idx] = buf[sp - 1].dupValueFast()
            oldSL.freeValueFast()
            pc += 2

        case .set_loc:
            let idx = Int(readU16(bc, pc + 1))
            let oldSL = buf[varBase + idx]
            buf[varBase + idx] = buf[sp - 1].dupValueFast()
            oldSL.freeValueFast()
            pc += 3

        case .put_loc_check:
            // Pure TDZ check (const assignment is a compile-time throw_error).
            let idx = Int(readU16(bc, pc + 1))
            let current = buf[varBase + idx]
            if current.isUninitialized { resume = pc; break traceLoop } // deopt: main loop throws
            sp -= 1; buf[varBase + idx] = buf[sp]; current.freeValueFast()
            current.freeValue()
            pc += 3

        case .get_loc_check:
            let idx = Int(readU16(bc, pc + 1))
            let val = buf[varBase + idx]
            if val.isUninitialized { resume = pc; break traceLoop } // deopt: TDZ
            buf[sp] = val.dupValue(); sp += 1
            pc += 3

        // =================================================================
        // Global variable access (via the per-function inline cache)
        // =================================================================

        // Property access with inline-cache hits only; any miss deopts to the
        // main loop, which performs the full lookup and refills the cache so
        // the next iteration hits here. Mirrors the main-loop hit paths
        // exactly (including their reference-handling).
        // ------------------------------------------------------------------
        // Calls and returns (inline frames carved from the caller's buffer,
        // exactly as the main loop does). Anything the main loop would send
        // through callFunction deopts instead.
        // ------------------------------------------------------------------
        case .push_this:
            buf[sp] = frame.thisVal.dupValue(); sp += 1
            pc += 1

        case .call, .call0, .call1, .call2, .call3:
            let argc: Int
            let instrSize: Int
            switch op {
            case .call: argc = Int(readU16(bc, pc + 1)); instrSize = 3
            case .call0: argc = 0; instrSize = 1
            case .call1: argc = 1; instrSize = 1
            case .call2: argc = 2; instrSize = 1
            default: argc = 3; instrSize = 1
            }
            let calleeSlot = sp - argc - 1
            if calleeSlot >= state.spBase, let nObj = buf[calleeSlot].obj, let cf = nObj.cFuncFast {
                // Native callee: dispatch from the trace. A deopt per native
                // call made Math.* loops bounce between trace and main loop.
                var cargs = [JeffJSValue](); cargs.reserveCapacity(argc)
                var ai = 0
                while ai < argc { cargs.append(buf[calleeSlot + 1 + ai]); ai += 1 }
                let r = JeffJSContext.dispatchCFunction(ctx, cf, .undefined, cargs, nObj.cMagicFast)
                buf[calleeSlot].freeValueFast()
                sp = calleeSlot
                if r.isException { resume = -1; break traceLoop }
                buf[sp] = r; sp += 1
                pc += instrSize
                continue traceLoop
            }
            guard calleeSlot >= state.spBase,
                  let callObj = buf[calleeSlot].obj,
                  let fbU = callObj.fbFastU,
                  rt.inlineStackTop - inlineBase <= 10000 else { resume = pc; break traceLoop }
            unowned(unsafe) let fastFb: JeffJSFunctionBytecode = fbU.takeUnretainedValue()
            if fastFb.isGenerator || fastFb.isAsyncFunc { resume = pc; break traceLoop }
            let funcVal = buf[calleeSlot]
            let restoreSp = calleeSlot
            let thisVal: JeffJSValue = .undefined
            do {
                let argStart = calleeSlot + 1
                let newVarCount = Int(fastFb.varCount)
                let fbArgCount = Int(fastFb.argCount); let newArgSlots = fbArgCount > argc ? fbArgCount : argc
                let fbStack = Int(fastFb.stackSize); let newStackSlots = (fbStack > 4 ? fbStack : 4) + 32
                if argStart + newArgSlots + newVarCount + newStackSlots > state.bufCapacity { resume = pc; break traceLoop }
                rt.inlinePush(JeffJSInterpreter.InlineCallFrame(
                    pc: pc + instrSize, sp: restoreSp, spTop: sp,
                    buf: buf, bufCapacity: state.bufCapacity,
                    varBase: varBase, spBase: state.spBase,
                    bc: bc, bcLen: bcLen, fb: fb,
                    frame: frame,
                    funcObj: state.funcObj, flags: state.flags, bufOwned: state.bufOwned))
                fb = fastFb
                bc = fastFb.bcPtrFast ?? fastFb.bytecodePtr
                bcLen = fastFb.bytecodeLen
                varRefsRaw = callObj.varRefsRaw
                varRefsRawCount = callObj.varRefsRawCount
                state.funcObj = funcVal
                state.flags = 0
                unowned(unsafe) let newFrame: JeffJSStackFrame = rt.acquireFrameU().takeUnretainedValue()
                newFrame.prevFrame = ctx.currentFrame
                newFrame.curFunc = funcVal
                if fastFb.isArrow, let arrowThis = callObj.arrowThisVal {
                    newFrame.thisVal = arrowThis.dupValue()
                } else if !fastFb.isStrictMode && thisVal.isNullOrUndefined {
                    newFrame.thisVal = ctx.globalObj
                } else {
                    newFrame.thisVal = thisVal
                }
                newFrame.argCount = argc
                newFrame.varCount = newVarCount
                let newBuf = buf + argStart
                let prefix = newArgSlots + newVarCount
                let pad = prefix - argc
                if pad > 0 {   // straight-line stores; a loop became a memset call
                    newBuf[argc] = .undefined
                    if pad > 1 { newBuf[argc + 1] = .undefined }
                    if pad > 2 { newBuf[argc + 2] = .undefined }
                    if pad > 3 {
                        var i = argc + 3
                        while i < prefix { newBuf[i] = .undefined; i += 1 }
                    }
                }
                state.bufOwned = false
                frame = newFrame
                ctx.currentFrame = frame
                frame.spBase = 0
                state.bufCapacity = state.bufCapacity - argStart
                buf = newBuf
                varBase = newArgSlots
                state.spBase = newArgSlots + newVarCount
                sp = state.spBase
                if fastFb.selfRefVarIdx >= 0 {
                    buf[varBase + fastFb.selfRefVarIdx] = funcVal.dupValue()
                }
                frame.buf = buf
                frame.bufCapacity = state.bufCapacity
                frame.bufVarBase = varBase
                frame.bufSpBase = state.spBase
                pc = 0
                if fastFb.traceLean {
                    // Call-free callee with a loop: lean runs it and returns at
                    // its `return`, which this trace then executes.
                    let r = executeFastTraceLean(bc: bc, bcLen: bcLen, entryPC: 0, exitPC: bcLen, startPC: 0,
                                                 buf: buf, varBase: varBase, sp: &sp, ctx: ctx, cpool: fastFb.cpool,
                                                 stackLimit: state.bufCapacity, icEntries: fastFb.icEntries)
                    if r == -1 { resume = -1; break traceLoop }
                    opsRun &+= 64
                    pc = r
                }
            }

        case .call_method:
            let argc = Int(readU16(bc, pc + 1))
            // Array.prototype.push fast path (mirrors the main loop) so
            // `arr.push(x)` loops stay in the trace.
            if argc == 1, sp >= state.spBase + 3,
               let pushObj = ctx.arrayProtoPushObj,
               let funcObj = buf[sp - 2].obj, funcObj === pushObj,
               let arrObj = buf[sp - 3].obj,
               arrObj.classID == JeffJSClassID.array.rawValue,
               arrObj.propCount > 0,
               let shape = arrObj.shape, shape.prop.count > 0,
               shape.prop[0].atom == JeffJSAtomID.JS_ATOM_length.rawValue {
                let newCount = arrObj.asClass.fastArrayPush(buf[sp - 1])
                if newCount > 0 {
                    arrObj.asClass.setPropEntry(at: 0, .value(.newInt32(Int32(newCount))))
                    buf[sp - 2].freeValue(); buf[sp - 3].freeValue()   // callee and receiver refs
                    sp -= 3
                    buf[sp] = .newInt32(Int32(newCount)); sp += 1
                    pc += 3
                    continue traceLoop
                }
            }
            let instrSize = 3
            let calleeSlot = sp - argc - 1
            let thisSlot = calleeSlot - 1
            if thisSlot >= state.spBase, let nObj = buf[calleeSlot].obj, let cf = nObj.cFuncFast {
                var cargs = [JeffJSValue](); cargs.reserveCapacity(argc)
                var ai = 0
                while ai < argc { cargs.append(buf[calleeSlot + 1 + ai]); ai += 1 }
                let r = JeffJSContext.dispatchCFunction(ctx, cf, buf[thisSlot], cargs, nObj.cMagicFast)
                buf[calleeSlot].freeValueFast(); buf[thisSlot].freeValueFast()
                sp = thisSlot
                if r.isException { resume = -1; break traceLoop }
                buf[sp] = r; sp += 1
                pc += instrSize
                continue traceLoop
            }
            guard thisSlot >= state.spBase,
                  let callObj = buf[calleeSlot].obj,
                  let fbU = callObj.fbFastU,
                  rt.inlineStackTop - inlineBase <= 10000 else { resume = pc; break traceLoop }
            unowned(unsafe) let fastFb: JeffJSFunctionBytecode = fbU.takeUnretainedValue()
            if fastFb.isGenerator || fastFb.isAsyncFunc { resume = pc; break traceLoop }
            let funcVal = buf[calleeSlot]
            let restoreSp = thisSlot
            let thisVal = buf[thisSlot]
            do {
                let argStart = calleeSlot + 1
                let newVarCount = Int(fastFb.varCount)
                let fbArgCount = Int(fastFb.argCount); let newArgSlots = fbArgCount > argc ? fbArgCount : argc
                let fbStack = Int(fastFb.stackSize); let newStackSlots = (fbStack > 4 ? fbStack : 4) + 32
                if argStart + newArgSlots + newVarCount + newStackSlots > state.bufCapacity { resume = pc; break traceLoop }
                rt.inlinePush(JeffJSInterpreter.InlineCallFrame(
                    pc: pc + instrSize, sp: restoreSp, spTop: sp,
                    buf: buf, bufCapacity: state.bufCapacity,
                    varBase: varBase, spBase: state.spBase,
                    bc: bc, bcLen: bcLen, fb: fb,
                    frame: frame,
                    funcObj: state.funcObj, flags: state.flags, bufOwned: state.bufOwned))
                fb = fastFb
                bc = fastFb.bcPtrFast ?? fastFb.bytecodePtr
                bcLen = fastFb.bytecodeLen
                varRefsRaw = callObj.varRefsRaw
                varRefsRawCount = callObj.varRefsRawCount
                state.funcObj = funcVal
                state.flags = 0
                unowned(unsafe) let newFrame: JeffJSStackFrame = rt.acquireFrameU().takeUnretainedValue()
                newFrame.prevFrame = ctx.currentFrame
                newFrame.curFunc = funcVal
                if fastFb.isArrow, let arrowThis = callObj.arrowThisVal {
                    newFrame.thisVal = arrowThis.dupValue()
                } else if !fastFb.isStrictMode && thisVal.isNullOrUndefined {
                    newFrame.thisVal = ctx.globalObj
                } else {
                    newFrame.thisVal = thisVal
                }
                newFrame.argCount = argc
                newFrame.varCount = newVarCount
                let newBuf = buf + argStart
                let prefix = newArgSlots + newVarCount
                let pad = prefix - argc
                if pad > 0 {   // straight-line stores; a loop became a memset call
                    newBuf[argc] = .undefined
                    if pad > 1 { newBuf[argc + 1] = .undefined }
                    if pad > 2 { newBuf[argc + 2] = .undefined }
                    if pad > 3 {
                        var i = argc + 3
                        while i < prefix { newBuf[i] = .undefined; i += 1 }
                    }
                }
                state.bufOwned = false
                frame = newFrame
                ctx.currentFrame = frame
                frame.spBase = 0
                state.bufCapacity = state.bufCapacity - argStart
                buf = newBuf
                varBase = newArgSlots
                state.spBase = newArgSlots + newVarCount
                sp = state.spBase
                if fastFb.selfRefVarIdx >= 0 {
                    buf[varBase + fastFb.selfRefVarIdx] = funcVal.dupValue()
                }
                frame.buf = buf
                frame.bufCapacity = state.bufCapacity
                frame.bufVarBase = varBase
                frame.bufSpBase = state.spBase
                pc = 0
                if fastFb.traceLean {
                    // Call-free callee with a loop: lean runs it and returns at
                    // its `return`, which this trace then executes.
                    let r = executeFastTraceLean(bc: bc, bcLen: bcLen, entryPC: 0, exitPC: bcLen, startPC: 0,
                                                 buf: buf, varBase: varBase, sp: &sp, ctx: ctx, cpool: fastFb.cpool,
                                                 stackLimit: state.bufCapacity, icEntries: fastFb.icEntries)
                    if r == -1 { resume = -1; break traceLoop }
                    opsRun &+= 64
                    pc = r
                }
            }

        case .get_loc8_call:
            let locIdx = Int(bc[pc + 1])
            let argc = Int(readU16(bc, pc + 2))
            let instrSize = 4
            guard argc == 0,
                  let callObj = buf[varBase + locIdx].obj,
                  let fbU = callObj.fbFastU,
                  rt.inlineStackTop - inlineBase <= 10000 else { resume = pc; break traceLoop }
            unowned(unsafe) let fastFb: JeffJSFunctionBytecode = fbU.takeUnretainedValue()
            if fastFb.isGenerator || fastFb.isAsyncFunc { resume = pc; break traceLoop }
            // Fit check before pushing the callee (a deopt must leave the
            // stack exactly as the main loop expects for this opcode).
            do {
                let a = Int(fastFb.argCount); let st = Int(fastFb.stackSize)
                if sp + 1 + a + Int(fastFb.varCount) + (st > 4 ? st : 4) + 32 > state.bufCapacity { resume = pc; break traceLoop }
            }
            let funcVal = buf[varBase + locIdx].dupValue()
            let calleeSlot = sp
            buf[sp] = funcVal; sp += 1
            let restoreSp = calleeSlot
            let thisVal: JeffJSValue = .undefined
            do {
                let argStart = calleeSlot + 1
                let newVarCount = Int(fastFb.varCount)
                let fbArgCount = Int(fastFb.argCount); let newArgSlots = fbArgCount > argc ? fbArgCount : argc
                let fbStack = Int(fastFb.stackSize); let newStackSlots = (fbStack > 4 ? fbStack : 4) + 32
                if argStart + newArgSlots + newVarCount + newStackSlots > state.bufCapacity { resume = pc; break traceLoop }
                rt.inlinePush(JeffJSInterpreter.InlineCallFrame(
                    pc: pc + instrSize, sp: restoreSp, spTop: sp,
                    buf: buf, bufCapacity: state.bufCapacity,
                    varBase: varBase, spBase: state.spBase,
                    bc: bc, bcLen: bcLen, fb: fb,
                    frame: frame,
                    funcObj: state.funcObj, flags: state.flags, bufOwned: state.bufOwned))
                fb = fastFb
                bc = fastFb.bcPtrFast ?? fastFb.bytecodePtr
                bcLen = fastFb.bytecodeLen
                varRefsRaw = callObj.varRefsRaw
                varRefsRawCount = callObj.varRefsRawCount
                state.funcObj = funcVal
                state.flags = 0
                unowned(unsafe) let newFrame: JeffJSStackFrame = rt.acquireFrameU().takeUnretainedValue()
                newFrame.prevFrame = ctx.currentFrame
                newFrame.curFunc = funcVal
                if fastFb.isArrow, let arrowThis = callObj.arrowThisVal {
                    newFrame.thisVal = arrowThis.dupValue()
                } else if !fastFb.isStrictMode && thisVal.isNullOrUndefined {
                    newFrame.thisVal = ctx.globalObj
                } else {
                    newFrame.thisVal = thisVal
                }
                newFrame.argCount = argc
                newFrame.varCount = newVarCount
                let newBuf = buf + argStart
                let prefix = newArgSlots + newVarCount
                let pad = prefix - argc
                if pad > 0 {   // straight-line stores; a loop became a memset call
                    newBuf[argc] = .undefined
                    if pad > 1 { newBuf[argc + 1] = .undefined }
                    if pad > 2 { newBuf[argc + 2] = .undefined }
                    if pad > 3 {
                        var i = argc + 3
                        while i < prefix { newBuf[i] = .undefined; i += 1 }
                    }
                }
                state.bufOwned = false
                frame = newFrame
                ctx.currentFrame = frame
                frame.spBase = 0
                state.bufCapacity = state.bufCapacity - argStart
                buf = newBuf
                varBase = newArgSlots
                state.spBase = newArgSlots + newVarCount
                sp = state.spBase
                if fastFb.selfRefVarIdx >= 0 {
                    buf[varBase + fastFb.selfRefVarIdx] = funcVal.dupValue()
                }
                frame.buf = buf
                frame.bufCapacity = state.bufCapacity
                frame.bufVarBase = varBase
                frame.bufSpBase = state.spBase
                pc = 0
                if fastFb.traceLean {
                    // Call-free callee with a loop: lean runs it and returns at
                    // its `return`, which this trace then executes.
                    let r = executeFastTraceLean(bc: bc, bcLen: bcLen, entryPC: 0, exitPC: bcLen, startPC: 0,
                                                 buf: buf, varBase: varBase, sp: &sp, ctx: ctx, cpool: fastFb.cpool,
                                                 stackLimit: state.bufCapacity, icEntries: fastFb.icEntries)
                    if r == -1 { resume = -1; break traceLoop }
                    opsRun &+= 64
                    pc = r
                }
            }

        case .return_, .return_undef:
            // Only inline returns; the activation's final return and frames
            // with live closure references go to the main loop.
            guard rt.inlineStackTop != inlineBase, !frame.hasLiveVarRefs else { resume = pc; break traceLoop }
            let returnValue: JeffJSValue
            switch op {   // enum `==` would be an out-of-line call here
            case .return_undef: returnValue = .undefined
            default:
                if sp <= state.spBase { resume = pc; break traceLoop }
                sp -= 1; returnValue = buf[sp]
            }
            // Release the callee's variable slots (its args live in the
            // caller's stack, released below), like QuickJS frees var_buf at
            // function exit and the caller frees func/this/args after the call.
            do { var i = varBase; let n = state.spBase; while i < n { buf[i].freeValueFast(); i += 1 } }
            ctx.currentFrame = frame.prevFrame
            rt.releaseFrameU(Unmanaged.passUnretained(frame))
            if state.bufOwned { rt.releaseInterpBuf(buf, capacity: state.bufCapacity) }
            let saved = rt.inlinePop()
            do { var p = saved.sp; let e = saved.spTop; while p < e { saved.buf[p].freeValueFast(); p += 1 } }
            pc = saved.pc; sp = saved.sp
            buf = saved.buf; state.bufCapacity = saved.bufCapacity
            varBase = saved.varBase; state.spBase = saved.spBase
            bc = saved.bc; bcLen = saved.bcLen
            fb = saved.fb; frame = saved.frame
            state.funcObj = saved.funcObj; state.flags = saved.flags; state.bufOwned = saved.bufOwned
            if let fo = saved.funcObj.obj {
                varRefsRaw = fo.varRefsRaw; varRefsRawCount = fo.varRefsRawCount
            } else {
                varRefsRaw = nil; varRefsRawCount = 0
            }
            buf[sp] = returnValue; sp += 1

        // ------------------------------------------------------------------
        // Closure variables through the unmanaged mirror (no ARC); TDZ and
        // missing refs deopt to the main loop.
        // ------------------------------------------------------------------
        case .get_var_ref:
            let idx = Int(readU16(bc, pc + 1))
            guard idx < varRefsRawCount, let u = varRefsRaw![idx] else { resume = pc; break traceLoop }
            let val = u._withUnsafeGuaranteedRef { $0.isDetached ? $0.value : $0.pvalue }
            buf[sp] = val.dupValue(); sp += 1
            pc += 3

        case .get_var_ref_check:
            let idx = Int(readU16(bc, pc + 1))
            guard idx < varRefsRawCount, let u = varRefsRaw![idx] else { resume = pc; break traceLoop }
            let val = u._withUnsafeGuaranteedRef { $0.isDetached ? $0.value : $0.pvalue }
            if val.isUninitialized { resume = pc; break traceLoop }
            buf[sp] = val.dupValue(); sp += 1
            pc += 3

        case .get_var_ref0, .get_var_ref1, .get_var_ref2, .get_var_ref3:
            let idx = Int(opByte) - Int(UInt8(truncatingIfNeeded: JeffJSOpcode.get_var_ref0.rawValue))
            guard idx < varRefsRawCount, let u = varRefsRaw![idx] else { resume = pc; break traceLoop }
            let val = u._withUnsafeGuaranteedRef { $0.isDetached ? $0.value : $0.pvalue }
            buf[sp] = val.dupValue(); sp += 1
            pc += 1

        case .put_var_ref:
            let idx = Int(readU16(bc, pc + 1))
            guard idx < varRefsRawCount, let u = varRefsRaw![idx] else { resume = pc; break traceLoop }
            let v: JeffJSValue
            if isStoreOpcode(bc, pc + 3, bcLen) { v = buf[sp - 1].dupValue() } else { sp -= 1; v = buf[sp] }
            u._withUnsafeGuaranteedRef { vr in if vr.isDetached { vr.value = v } else { vr.pvalue = v } }
            pc += 3

        case .put_var_ref_check:
            let idx = Int(readU16(bc, pc + 1))
            guard idx < varRefsRawCount, let u = varRefsRaw![idx] else { resume = pc; break traceLoop }
            if u._withUnsafeGuaranteedRef({ $0.isDetached ? $0.value : $0.pvalue }).isUninitialized { resume = pc; break traceLoop }
            let v: JeffJSValue
            if isStoreOpcode(bc, pc + 3, bcLen) { v = buf[sp - 1].dupValue() } else { sp -= 1; v = buf[sp] }
            u._withUnsafeGuaranteedRef { vr in if vr.isDetached { vr.value = v } else { vr.pvalue = v } }
            pc += 3

        case .put_var_ref_check_init:
            let idx = Int(readU16(bc, pc + 1))
            guard idx < varRefsRawCount, let u = varRefsRaw![idx] else { resume = pc; break traceLoop }
            sp -= 1; let v = buf[sp]
            u._withUnsafeGuaranteedRef { vr in if vr.isDetached { vr.value = v } else { vr.pvalue = v } }
            pc += 3

        case .put_var_ref0, .put_var_ref1, .put_var_ref2, .put_var_ref3:
            let idx = Int(opByte) - Int(UInt8(truncatingIfNeeded: JeffJSOpcode.put_var_ref0.rawValue))
            guard idx < varRefsRawCount, let u = varRefsRaw![idx] else { resume = pc; break traceLoop }
            sp -= 1; let v = buf[sp]
            u._withUnsafeGuaranteedRef { vr in if vr.isDetached { vr.value = v } else { vr.pvalue = v } }
            pc += 1

        case .set_var_ref:
            let idx = Int(readU16(bc, pc + 1))
            guard idx < varRefsRawCount, let u = varRefsRaw![idx] else { resume = pc; break traceLoop }
            let v = buf[sp - 1].dupValue()
            u._withUnsafeGuaranteedRef { vr in if vr.isDetached { vr.value = v } else { vr.pvalue = v } }
            pc += 3

        case .set_var_ref0, .set_var_ref1, .set_var_ref2, .set_var_ref3:
            let idx = Int(opByte) - Int(UInt8(truncatingIfNeeded: JeffJSOpcode.set_var_ref0.rawValue))
            guard idx < varRefsRawCount, let u = varRefsRaw![idx] else { resume = pc; break traceLoop }
            let v = buf[sp - 1].dupValue()
            u._withUnsafeGuaranteedRef { vr in if vr.isDetached { vr.value = v } else { vr.pvalue = v } }
            pc += 1

        // ------------------------------------------------------------------
        // Object / array literals and TDZ slots (object-building loops).
        // ------------------------------------------------------------------
        case .object:
            buf[sp] = ctx.newPlainObject(); sp += 1
            pc += 1

        case .set_loc_uninitialized:
            let idx = Int(readU16(bc, pc + 1))
            let oldTDZ = buf[varBase + idx]
            buf[varBase + idx] = .uninitialized
            oldTDZ.freeValue()
            pc += 3

        case .put_loc_check_init:
            if sp <= state.spBase { resume = pc; break traceLoop }
            let idx = Int(readU16(bc, pc + 1))
            let old = buf[varBase + idx]
            sp -= 1; buf[varBase + idx] = buf[sp]
            old.freeValue()
            pc += 3

        case .define_field:
            // Transition IC hit only (mirrors the main loop's fast path).
            guard sp >= state.spBase + 2, let ents = fb.icEntries else { resume = pc; break traceLoop }
            let obj = buf[sp - 2]
            guard let jsObj = obj.obj else { resume = pc; break traceLoop }
            let entry = ents[pc & JeffJSInlineCache.mask]
            guard entry.pc == pc, jeffJS_icDefine(jsObj._ptr, entry, buf[sp - 1], rt) else { resume = pc; break traceLoop }
            sp -= 1   // the value ref moved into the new slot
            pc += 5

        case .array_from:
            // Empty literal `[]` only; the parser's orphan `object` sentinel
            // below it is dropped like the main loop does.
            guard readU16(bc, pc + 1) == 0, sp > state.spBase else { resume = pc; break traceLoop }
            let below = buf[sp - 1]
            guard let bo = below.obj, bo.classID == JeffJSClassID.object.rawValue, bo.propCount == 0 else { resume = pc; break traceLoop }
            below.freeValue()
            buf[sp - 1] = ctx.newArray()
            pc += 3

        case .get_field:
            // A directly-following plain call takes its `this` from a stash
            // that only the main loop maintains: let it handle that pair.
            if pc + 5 < bcLen, isCallOpcodeByte(bc[pc + 5]) { resume = pc; break traceLoop }
            guard let ents = fb.icEntries else { resume = pc; break traceLoop }
            let obj = buf[sp - 1]
            guard let jsObj = obj.obj else { resume = pc; break traceLoop }
            let entry = ents[pc & JeffJSInlineCache.mask]
            var icHit: JeffJSValue? = nil
            if entry.pc == pc { icHit = jeffJS_icRead(jsObj._ptr, entry) }
            if let hv = icHit {
                buf[sp - 1] = hv.dupValueFast()
                obj.freeValueFast()
                pc += 5
            } else {
                resume = pc; break traceLoop // deopt: IC miss
            }

        case .get_field2:
            guard let ents = fb.icEntries else { resume = pc; break traceLoop }
            let obj = buf[sp - 1]
            guard let jsObj = obj.obj else { resume = pc; break traceLoop }
            let entry = ents[pc & JeffJSInlineCache.mask]
            var icHit: JeffJSValue? = nil
            if entry.pc == pc { icHit = jeffJS_icRead(jsObj._ptr, entry) }
            if icHit == nil, jsObj.classID == JeffJSClassID.array.rawValue,
               readU32(bc, pc + 1) == JSPredefinedAtom.push.rawValue, ctx.arrayProtoPushObj != nil {
                // `arr.push`: exotic receivers never fill the IC; the
                // call_method fast path below consumes this borrowed value.
                icHit = ctx.arrayProtoPushVal
            }
            if let hv = icHit {
                buf[sp] = hv.dupValueFast(); sp += 1
                pc += 5
            } else {
                resume = pc; break traceLoop
            }

        case .put_field:
            guard let ents = fb.icEntries else { resume = pc; break traceLoop }
            let val = buf[sp - 1]
            let obj = buf[sp - 2]
            guard let jsObj = obj.obj else { resume = pc; break traceLoop }
            let entry = ents[pc & JeffJSInlineCache.mask]
            if entry.pc == pc, jeffJS_icWrite(jsObj._ptr, entry, val) {
                obj.freeValueFast()   // the popped receiver ref (QuickJS: JS_FreeValue(sp[-2]))
                sp -= 2
                pc += 5
            } else {
                resume = pc; break traceLoop
            }

        case .get_loc8_get_field:
            guard let ents = fb.icEntries else { resume = pc; break traceLoop }
            let obj = buf[varBase + Int(bc[pc + 1])]
            guard let jsObj = obj.obj else { resume = pc; break traceLoop }
            let entry = ents[pc & JeffJSInlineCache.mask]
            var icHit: JeffJSValue? = nil
            if entry.pc == pc { icHit = jeffJS_icRead(jsObj._ptr, entry) }
            if let hv = icHit {
                buf[sp] = hv.dupValueFast(); sp += 1
                pc += 6
            } else {
                resume = pc; break traceLoop
            }

        case .get_arg0_get_field:
            guard let ents = fb.icEntries else { resume = pc; break traceLoop }
            let obj = buf[0]
            guard let jsObj = obj.obj else { resume = pc; break traceLoop }
            let entry = ents[pc & JeffJSInlineCache.mask]
            var icHit: JeffJSValue? = nil
            if entry.pc == pc { icHit = jeffJS_icRead(jsObj._ptr, entry) }
            if let hv = icHit {
                buf[sp] = hv.dupValueFast(); sp += 1
                pc += 5
            } else {
                resume = pc; break traceLoop
            }

        case .get_length:
            guard let ents = fb.icEntries else { resume = pc; break traceLoop }
            let obj = buf[sp - 1]
            guard let jsObj = obj.obj, let sid = jsObj.shapeIdentity else { resume = pc; break traceLoop }
            let entry = ents[pc & JeffJSInlineCache.mask]
            if entry.pc == pc, entry.shapePtr == sid, entry.holderPtr == nil,
               entry.propOffset >= 0, entry.propOffset < jsObj.propCount,
               jsObj.extra(at: entry.propOffset) == nil {
                buf[sp - 1] = jsObj.dataValue(at: entry.propOffset).dupValue()
                obj.freeValueFast()
                pc += 1
            } else {
                resume = pc; break traceLoop // deopt
            }

        case .get_var, .get_var_undef:
            guard let ents = fb.icEntries, let gObj = ctx.globalObj.obj, let gShape = gObj.shape else {
                resume = pc; break traceLoop // deopt: no IC table yet
            }
            let entry = ents[pc & JeffJSInlineCache.mask]
            if entry.pc == pc,
               entry.shapePtr == UnsafeRawPointer(Unmanaged.passUnretained(gShape).toOpaque()),
               entry.propOffset >= 0, entry.propOffset < gObj.propCount,
               gObj.extra(at: entry.propOffset) == nil {
                buf[sp] = gObj.dataValue(at: entry.propOffset).dupValue(); sp += 1
                pc += 5
            } else {
                resume = pc; break traceLoop // deopt: IC miss — main loop refills the cache
            }

        case .put_var:
            guard let ents = fb.icEntries, let gObj = ctx.globalObj.obj, let gShape = gObj.shape else {
                resume = pc; break traceLoop // deopt
            }
            let entry = ents[pc & JeffJSInlineCache.mask]
            if entry.pc == pc,
               entry.shapePtr == UnsafeRawPointer(Unmanaged.passUnretained(gShape).toOpaque()),
               entry.propOffset >= 0, entry.propOffset < gObj.propCount,
               entry.propOffset < gShape.prop.count,
               gShape.prop[entry.propOffset].flags.contains(.writable),
               !gShape.prop[entry.propOffset].flags.contains(.getset),
               gObj.extra(at: entry.propOffset) == nil {
                let chained = isStoreOpcode(bc, pc + 5, bcLen)
                let val: JeffJSValue
                if chained { val = buf[sp - 1].dupValue() } else { sp -= 1; val = buf[sp] }
                let old = gObj.dataValue(at: entry.propOffset)
                gObj.asClass.propValues[entry.propOffset] = val
                old.freeValue()
                pc += 5
            } else {
                resume = pc; break traceLoop // deopt: IC miss
            }

        // =================================================================
        // Array element access (dense int-indexed fast paths)
        // =================================================================

        case .get_array_el:
            guard sp >= 2 else { resume = pc; break traceLoop } // deopt: stack too shallow
            let key = buf[sp - 1]
            let objV = buf[sp - 2]
            guard key.isInt, let jsObj = objV.obj,
                  jsObj.classID == JeffJSClassID.array.rawValue else {
                resume = pc; break traceLoop // deopt: non-array or non-int key
            }
            let idx = key.toInt32()
            guard idx >= 0 else { resume = pc; break traceLoop }
            let uidx = UInt32(idx)
            var element: JeffJSValue? = nil
            if let storage = jsObj._fastArrayValues {
                if uidx < storage.count, Int(uidx) < storage.values.count {
                    element = storage.values[Int(uidx)]
                }
            } else if case .array(_, let vals, let count) = jsObj.payload {
                if uidx < count, Int(uidx) < vals.count {
                    element = vals[Int(uidx)]
                }
            }
            guard let el = element else { resume = pc; break traceLoop } // deopt: OOB/holes — slow path decides
            let elDup = el.dupValue()
            objV.freeValueFast()   // the popped receiver ref (`arr[i]` leaked one per read)
            sp -= 1
            buf[sp - 1] = elDup
            pc += 1

        case .put_array_el:
            guard sp >= 3 else { resume = pc; break traceLoop } // deopt: stack too shallow
            let val = buf[sp - 1]
            let key = buf[sp - 2]
            let objV = buf[sp - 3]
            guard key.isInt, let jsObj = objV.obj,
                  jsObj.classID == JeffJSClassID.array.rawValue,
                  let storage = jsObj._fastArrayValues else {
                resume = pc; break traceLoop // deopt: only the ref-type storage is safe to poke here
            }
            let idx = key.toInt32()
            // In-bounds overwrite only — growth/length updates take the slow path.
            guard idx >= 0, UInt32(idx) < storage.count, Int(idx) < storage.values.count else {
                resume = pc; break traceLoop
            }
            let old = storage.values[Int(idx)]
            storage.values[Int(idx)] = val
            old.freeValue()
            objV.freeValueFast()   // the popped receiver ref
            sp -= 3
            pc += 1

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
            if sp <= state.spBase { resume = pc; break traceLoop }   // underflow: let the guarded main loop report it
            sp -= 1
            buf[sp].freeValueFast()   // `a[k] = obj;` compiles to dup/put/drop: the dropped ref must go
            pc += 1

        case .nip:
            buf[sp - 2].freeValueFast(); buf[sp - 2] = buf[sp - 1]; sp -= 1
            pc += 1

        case .nip1:
            buf[sp - 3].freeValueFast(); buf[sp - 3] = buf[sp - 2]; buf[sp - 2] = buf[sp - 1]; sp -= 1
            pc += 1

        case .perm3:
            // [a, b, c] -> [c, a, b]
            let c = buf[sp - 1], b = buf[sp - 2], a = buf[sp - 3]
            buf[sp - 3] = c; buf[sp - 2] = a; buf[sp - 1] = b
            pc += 1

        case .perm4:
            // [a, b, c, d] -> [d, a, b, c]
            let d = buf[sp - 1], c = buf[sp - 2], b = buf[sp - 3], a = buf[sp - 4]
            buf[sp - 4] = d; buf[sp - 3] = a; buf[sp - 2] = b; buf[sp - 1] = c
            pc += 1

        case .perm5:
            // [a, b, c, d, e] -> [e, a, b, c, d]
            let e = buf[sp - 1], d = buf[sp - 2], c = buf[sp - 3], b = buf[sp - 4], a = buf[sp - 5]
            buf[sp - 5] = e; buf[sp - 4] = a; buf[sp - 3] = b; buf[sp - 2] = c; buf[sp - 1] = d
            pc += 1

        case .get_loc_checkthis:
            let idx = Int(readU16(bc, pc + 1))
            let val = buf[varBase + idx]
            if val.isUninitialized { resume = pc; break traceLoop } // deopt: main loop throws
            buf[sp] = val.dupValue(); sp += 1
            pc += 3

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
            } else if lhs.isNumber && rhs.isNumber {
                // Mixed/float operands: plain double arithmetic keeps float
                // loops inside the trace instead of deopting every op.
                sp -= 1
                buf[sp - 1] = .newFloat64(jeffJS_traceNum(lhs) + jeffJS_traceNum(rhs))
                pc += 1
            } else if lhs.isString && rhs.isString {
                // String concat stays in the trace (rope/buffer append).
                let r = jeffJS_concatStrings(s1: lhs, s2: rhs)
                if r.isException { resume = pc; break traceLoop } // deopt: main loop rethrows
                lhs.freeValue(); rhs.freeValue()
                sp -= 1
                buf[sp - 1] = r
                pc += 1
            } else {
                resume = pc; break traceLoop // deopt: non-numeric, non-string operands
            }

        case .sub:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                let (r, overflow) = lhs.toInt32().subtractingReportingOverflow(rhs.toInt32())
                sp -= 1
                buf[sp - 1] = overflow ? .newFloat64(Double(lhs.toInt32()) - Double(rhs.toInt32())) : .newInt32(r)
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                // Mixed/float operands: plain double arithmetic keeps float
                // loops inside the trace instead of deopting every op.
                sp -= 1
                buf[sp - 1] = .newFloat64(jeffJS_traceNum(lhs) - jeffJS_traceNum(rhs))
                pc += 1
            } else {
                resume = pc; break traceLoop // deopt: non-numeric operands
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
            } else if lhs.isNumber && rhs.isNumber {
                // Mixed/float operands: plain double arithmetic keeps float
                // loops inside the trace instead of deopting every op.
                sp -= 1
                buf[sp - 1] = .newFloat64(jeffJS_traceNum(lhs) * jeffJS_traceNum(rhs))
                pc += 1
            } else {
                resume = pc; break traceLoop // deopt: non-numeric operands
            }

        case .div:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                let a = lhs.toInt32(), b = rhs.toInt32()
                if b == 0 || (a == Int32.min && b == -1) {
                    resume = pc; break traceLoop // deopt: div by zero or overflow
                }
                let r = a / b
                sp -= 1
                if r * b == a && !(r == 0 && a < 0) {
                    buf[sp - 1] = .newInt32(r)
                } else {
                    buf[sp - 1] = .newFloat64(Double(a) / Double(b))
                }
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                // Mixed/float operands: plain double arithmetic keeps float
                // loops inside the trace instead of deopting every op.
                sp -= 1
                buf[sp - 1] = .newFloat64(jeffJS_traceNum(lhs) / jeffJS_traceNum(rhs))
                pc += 1
            } else {
                resume = pc; break traceLoop // deopt: non-numeric operands
            }

        case .mod:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                let a = lhs.toInt32(), b = rhs.toInt32()
                if b == 0 || (a == Int32.min && b == -1) {
                    resume = pc; break traceLoop // deopt
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
                resume = pc; break traceLoop // deopt
            }

        case .neg:
            let val = buf[sp - 1]
            if val.isInt {
                let v = val.toInt32()
                if v == 0 || v == Int32.min { resume = pc; break traceLoop } // deopt: -0 or overflow
                buf[sp - 1] = .newInt32(-v)
                pc += 1
            } else {
                resume = pc; break traceLoop // deopt
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
                resume = pc; break traceLoop // deopt
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
                resume = pc; break traceLoop // deopt
            }

        case .inc_loc:
            let idx = Int(bc[pc + 1])
            let val = buf[varBase + idx]
            if val.isInt && val.toInt32() != Int32.max {
                buf[varBase + idx] = .newInt32(val.toInt32() + 1)
                pc += 2
            } else {
                resume = pc; break traceLoop // deopt
            }

        case .dec_loc:
            let idx = Int(bc[pc + 1])
            let val = buf[varBase + idx]
            if val.isInt && val.toInt32() != Int32.min {
                buf[varBase + idx] = .newInt32(val.toInt32() - 1)
                pc += 2
            } else {
                resume = pc; break traceLoop // deopt
            }

        case .add_loc:
            let idx = Int(bc[pc + 1])
            let addend = readI32(bc, pc + 2)
            let val = buf[varBase + idx]
            if val.isInt {
                let (r, overflow) = val.toInt32().addingReportingOverflow(addend)
                if overflow { resume = pc; break traceLoop } // deopt: main loop widens to double
                buf[varBase + idx] = .newInt32(r)
                pc += 6
            } else {
                resume = pc; break traceLoop // deopt
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
                resume = pc; break traceLoop // deopt
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
                resume = pc; break traceLoop // deopt
            }

        case .plus:
            let val = buf[sp - 1]
            if val.isInt {
                pc += 1 // int stays as-is
            } else {
                resume = pc; break traceLoop // deopt
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
            } else if lhs.isNumber && rhs.isNumber {
                sp -= 1
                buf[sp - 1] = jeffJS_traceNum(lhs) < jeffJS_traceNum(rhs) ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { resume = pc; break traceLoop }

        case .lte:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = lhs.toInt32() <= rhs.toInt32() ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                sp -= 1
                buf[sp - 1] = jeffJS_traceNum(lhs) <= jeffJS_traceNum(rhs) ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { resume = pc; break traceLoop }

        case .gt:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = lhs.toInt32() > rhs.toInt32() ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                sp -= 1
                buf[sp - 1] = jeffJS_traceNum(lhs) > jeffJS_traceNum(rhs) ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { resume = pc; break traceLoop }

        case .gte:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = lhs.toInt32() >= rhs.toInt32() ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                sp -= 1
                buf[sp - 1] = jeffJS_traceNum(lhs) >= jeffJS_traceNum(rhs) ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { resume = pc; break traceLoop }

        case .eq:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = lhs.toInt32() == rhs.toInt32() ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                sp -= 1
                buf[sp - 1] = jeffJS_traceNum(lhs) == jeffJS_traceNum(rhs) ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { resume = pc; break traceLoop }

        case .neq:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = lhs.toInt32() != rhs.toInt32() ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                sp -= 1
                buf[sp - 1] = jeffJS_traceNum(lhs) != jeffJS_traceNum(rhs) ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { resume = pc; break traceLoop }

        case .strict_eq:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = lhs.toInt32() == rhs.toInt32() ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                sp -= 1
                buf[sp - 1] = jeffJS_traceNum(lhs) == jeffJS_traceNum(rhs) ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { resume = pc; break traceLoop }

        case .strict_neq:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = lhs.toInt32() != rhs.toInt32() ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                sp -= 1
                buf[sp - 1] = jeffJS_traceNum(lhs) != jeffJS_traceNum(rhs) ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { resume = pc; break traceLoop }

        // =================================================================
        // Bitwise (inline int fast paths)
        // =================================================================

        case .shl:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = .newInt32(lhs.toInt32() << (rhs.toInt32() & 0x1F))
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                // Float operand (e.g. after an int32 overflow): ToInt32 inline.
                let a = jeffJS_traceToInt32(lhs), b = jeffJS_traceToInt32(rhs)
                sp -= 1
                buf[sp - 1] = .newInt32(a << (b & 0x1F))
                pc += 1
            } else { resume = pc; break traceLoop }

        case .sar:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = .newInt32(lhs.toInt32() >> (rhs.toInt32() & 0x1F))
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                // Float operand (e.g. after an int32 overflow): ToInt32 inline.
                let a = jeffJS_traceToInt32(lhs), b = jeffJS_traceToInt32(rhs)
                sp -= 1
                buf[sp - 1] = .newInt32(a >> (b & 0x1F))
                pc += 1
            } else { resume = pc; break traceLoop }

        case .shr:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                let ua = UInt32(bitPattern: lhs.toInt32())
                let result = ua >> (UInt32(rhs.toInt32() & 0x1F))
                sp -= 1
                buf[sp - 1] = .newUInt32(result)
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                let a = UInt32(bitPattern: jeffJS_traceToInt32(lhs)), b = jeffJS_traceToInt32(rhs)
                sp -= 1
                buf[sp - 1] = .newUInt32(a >> UInt32(b & 0x1F))
                pc += 1
            } else { resume = pc; break traceLoop }

        case .and:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = .newInt32(lhs.toInt32() & rhs.toInt32())
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                // Float operand (e.g. after an int32 overflow): ToInt32 inline.
                let a = jeffJS_traceToInt32(lhs), b = jeffJS_traceToInt32(rhs)
                sp -= 1
                buf[sp - 1] = .newInt32(a & b)
                pc += 1
            } else { resume = pc; break traceLoop }

        case .or:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = .newInt32(lhs.toInt32() | rhs.toInt32())
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                // Float operand (e.g. after an int32 overflow): ToInt32 inline.
                let a = jeffJS_traceToInt32(lhs), b = jeffJS_traceToInt32(rhs)
                sp -= 1
                buf[sp - 1] = .newInt32(a | b)
                pc += 1
            } else { resume = pc; break traceLoop }

        case .xor:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = .newInt32(lhs.toInt32() ^ rhs.toInt32())
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                // Float operand (e.g. after an int32 overflow): ToInt32 inline.
                let a = jeffJS_traceToInt32(lhs), b = jeffJS_traceToInt32(rhs)
                sp -= 1
                buf[sp - 1] = .newInt32(a ^ b)
                pc += 1
            } else { resume = pc; break traceLoop }

        case .not:
            let val = buf[sp - 1]
            if val.isInt {
                buf[sp - 1] = .newInt32(~val.toInt32())
                pc += 1
            } else { resume = pc; break traceLoop }

        // =================================================================
        // Boolean / type
        // =================================================================

        case .lnot:
            let val = buf[sp - 1]
            buf[sp - 1] = jeffJS_fastToBool(val) ? .JS_FALSE : .JS_TRUE
            pc += 1

        case .typeof_:
            resume = pc; break traceLoop // deopt: needs string allocation

        // =================================================================
        // Control flow
        // =================================================================

        case .if_false:
            sp -= 1
            let cond = buf[sp]
            let offset = Int(readI32(bc, pc + 1))
            if !jeffJS_fastToBool(cond) {
                let target = pc + 5 + offset
                if target < 0 || target >= bcLen {
                    resume = target; break traceLoop // loop exit
                }
                if offset < 0 {   // loop back-edge: interrupt check
                    interrupt -= 1
                    if interrupt <= 0 {
                        interrupt = JS_INTERRUPT_COUNTER_INIT
                        ctx.interruptCounter = interrupt
                        if ctx.checkInterrupt() { resume = -1; break traceLoop }
                    }
                }
                pc = target
            } else {
                pc += 5
            }

        case .if_true:
            sp -= 1
            let cond = buf[sp]
            let offset = Int(readI32(bc, pc + 1))
            if jeffJS_fastToBool(cond) {
                let target = pc + 5 + offset
                if target < 0 || target >= bcLen {
                    resume = target; break traceLoop // loop exit
                }
                if offset < 0 {   // loop back-edge: interrupt check
                    interrupt -= 1
                    if interrupt <= 0 {
                        interrupt = JS_INTERRUPT_COUNTER_INIT
                        ctx.interruptCounter = interrupt
                        if ctx.checkInterrupt() { resume = -1; break traceLoop }
                    }
                }
                pc = target
            } else {
                pc += 5
            }

        case .if_false8:
            sp -= 1
            let cond = buf[sp]
            let offset = Int(readI8(bc, pc + 1))
            if !jeffJS_fastToBool(cond) {
                let target = pc + 2 + offset
                if target < 0 || target >= bcLen {
                    resume = target; break traceLoop
                }
                if offset < 0 {   // loop back-edge: interrupt check
                    interrupt -= 1
                    if interrupt <= 0 {
                        interrupt = JS_INTERRUPT_COUNTER_INIT
                        ctx.interruptCounter = interrupt
                        if ctx.checkInterrupt() { resume = -1; break traceLoop }
                    }
                }
                pc = target
            } else {
                pc += 2
            }

        case .cmp_if8, .cmp_if:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            let cbSub = Int(bc[pc + 1])
            let cbShort = (op == .cmp_if8)
            let cbSize = cbShort ? 3 : 6
            var cbCond = false
            if lhs.isInt && rhs.isInt {
                let a = lhs.toInt32(), b = rhs.toInt32()
                switch cbSub & 7 { case 0: cbCond = a < b; case 1: cbCond = a <= b; case 2: cbCond = a > b; case 3: cbCond = a >= b; case 4, 6: cbCond = a == b; default: cbCond = a != b }
            } else if lhs.isNumber && rhs.isNumber {
                let a = jeffJS_traceNum(lhs), b = jeffJS_traceNum(rhs)
                switch cbSub & 7 { case 0: cbCond = a < b; case 1: cbCond = a <= b; case 2: cbCond = a > b; case 3: cbCond = a >= b; case 4, 6: cbCond = a == b; default: cbCond = a != b }
            } else { resume = pc; break traceLoop }
            sp -= 2
            if cbCond == ((cbSub & 8) != 0) {
                let offset = cbShort ? Int(readI8(bc, pc + 2)) : Int(readI32(bc, pc + 2))
                let target = pc + cbSize + offset
                if target < 0 || target >= bcLen {
                    resume = target; break traceLoop
                }
                if offset < 0 {   // loop back-edge: interrupt check
                    interrupt -= 1
                    if interrupt <= 0 {
                        interrupt = JS_INTERRUPT_COUNTER_INIT
                        ctx.interruptCounter = interrupt
                        if ctx.checkInterrupt() { resume = -1; break traceLoop }
                    }
                }
                pc = target
            } else {
                pc += cbSize
            }

        case .if_true8:
            sp -= 1
            let cond = buf[sp]
            let offset = Int(readI8(bc, pc + 1))
            if jeffJS_fastToBool(cond) {
                let target = pc + 2 + offset
                if target < 0 || target >= bcLen {
                    resume = target; break traceLoop
                }
                if offset < 0 {   // loop back-edge: interrupt check
                    interrupt -= 1
                    if interrupt <= 0 {
                        interrupt = JS_INTERRUPT_COUNTER_INIT
                        ctx.interruptCounter = interrupt
                        if ctx.checkInterrupt() { resume = -1; break traceLoop }
                    }
                }
                pc = target
            } else {
                pc += 2
            }

        case .goto_:
            let offset = Int(readI32(bc, pc + 1))
            let target = pc + 5 + offset
            if offset < 0 {
                // Loop-back (any backward jump inside the merged region):
                // interrupt check, then continue the trace at the target.
                interrupt -= 1
                if interrupt <= 0 {
                    interrupt = JS_INTERRUPT_COUNTER_INIT
                    ctx.interruptCounter = interrupt
                    if ctx.checkInterrupt() { resume = -1; break traceLoop }
                }
            }
            if target >= 0 && target < bcLen {
                pc = target
            } else {
                resume = target; break traceLoop // jump outside trace
            }

        case .goto8:
            let offset = Int(readI8(bc, pc + 1))
            let target = pc + 2 + offset
            if offset < 0 {
                // Loop-back (any backward jump inside the merged region):
                // interrupt check, then continue the trace at the target.
                interrupt -= 1
                if interrupt <= 0 {
                    interrupt = JS_INTERRUPT_COUNTER_INIT
                    ctx.interruptCounter = interrupt
                    if ctx.checkInterrupt() { resume = -1; break traceLoop }
                }
            }
            if target >= 0 && target < bcLen {
                pc = target
            } else {
                resume = target; break traceLoop // jump outside trace
            }

        case .goto16:
            let offset = Int(readI16(bc, pc + 1))
            let target = pc + 3 + offset
            if offset < 0 {
                // Loop-back (any backward jump inside the merged region):
                // interrupt check, then continue the trace at the target.
                interrupt -= 1
                if interrupt <= 0 {
                    interrupt = JS_INTERRUPT_COUNTER_INIT
                    ctx.interruptCounter = interrupt
                    if ctx.checkInterrupt() { resume = -1; break traceLoop }
                }
            }
            if target >= 0 && target < bcLen {
                pc = target
            } else {
                resume = target; break traceLoop // jump outside trace
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
            let lhs = buf[sp - 1]              // value pushed before get_loc
            let rhs = buf[varBase + locIdx]    // the local
            if lhs.isInt && rhs.isInt {
                let a = lhs.toInt32(), b = rhs.toInt32()
                let (r, overflow) = a.addingReportingOverflow(b)
                buf[sp - 1] = overflow ? .newFloat64(Double(a) + Double(b)) : .newInt32(r)
                pc += 2
            } else {
                resume = pc; break traceLoop // deopt
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
            resume = pc; break traceLoop
        }
    }
    // Single exit: publish the (possibly changed) interpreter state.
    state.sp = sp
    state.buf = buf
    state.varBase = varBase
    state.bc = bc
    state.bcLen = bcLen
    state.fb = fb
    state.frame = frame
    state.varRefsRaw = varRefsRaw
    state.varRefsRawCount = varRefsRawCount
    state.opsRun = opsRun
    ctx.interruptCounter = interrupt
    return resume
}

// =============================================================================
// MARK: - Lean fast trace (loops without calls / closure variables)
//
// Same opcode coverage as executeFastTrace minus calls, returns, push_this and
// closure-variable access. Kept separate on purpose: the call-capable variant
// carries ~15 extra live values and measured ~10% slower per opcode, which
// outweighs its benefit on loops that never call. The compiler marks each
// trace block with `hasCalls`; the main loop picks the variant.
// =============================================================================
private func executeFastTraceLean(
    bc: UnsafePointer<UInt8>,
    bcLen: Int,
    entryPC: Int,
    exitPC: Int,
    startPC: Int,
    buf: UnsafeMutablePointer<JeffJSValue>,
    varBase: Int,
    sp: inout Int,
    ctx: JeffJSContext,
    cpool: [JeffJSValue],
    stackLimit: Int,
    icEntries: UnsafeMutablePointer<JeffJSICEntry>?
) -> Int {
    // Validate parameters
    guard entryPC >= 0, exitPC <= bcLen, entryPC < exitPC,
          startPC >= entryPC, startPC < exitPC,
          sp >= 0, sp < stackLimit, stackLimit > 0 else {
        return startPC
    }
    var pc = startPC
    var interrupt = ctx.interruptCounter   // register copy; written back on every exit

    // No per-op range or stack checks: every jump handler returns to the
    // main loop when its target leaves [entryPC, exitPC); straight-line
    // advances cannot leave the region (it ends with a backward jump); and
    // the compiler-computed stackSize (+32 slack) bounds sp. DEBUG asserts.
    traceLoop: while true {
        #if DEBUG
        assert(pc >= entryPC && pc < exitPC && sp >= 0 && sp < stackLimit,
               "fast trace left its region or overflowed")
        #endif
        // Same raw decode as the main loop: every narrow byte is a valid
        // case; the 0x00 wide prefix decodes to .invalid and deopts below.
        let opByte = bc[pc]
        // Byte 0 (wide-opcode prefix) decodes to .invalid, which deopts below.
        let op = unsafeBitCast(UInt16(opByte), to: JeffJSOpcode.self)
        #if JEFFJS_OPPROF
        jeffJS_opProfRecord(Int(opByte))
        #endif

        switch op {
        case .invalid:
            ctx.interruptCounter = interrupt; return pc

        // =================================================================
        // Push values
        // =================================================================

        case .cmp_loc_i8:
            let cmp = bc[pc + 1]
            let cond: Bool
            let a = buf[varBase + Int(bc[pc + 2])]
            let k = Int32(Int8(bitPattern: bc[pc + 3]))
            if a.isInt {
                cond = jeffJS_cmpInt(cmp, a.toInt32(), k)
            } else if a.isNumber {
                cond = jeffJS_cmpDouble(cmp, a.toFloat64(), Double(k))
            } else { ctx.interruptCounter = interrupt; return pc }
            // Fused branch: when if_true8 / if_false8 follows, branch here
            // instead of pushing a bool for the next dispatch to pop.
            let nb = bc[pc + 4]
            if nb == UInt8(truncatingIfNeeded: JeffJSOpcode.if_true8.rawValue)
                || nb == UInt8(truncatingIfNeeded: JeffJSOpcode.if_false8.rawValue) {
                let take = nb == UInt8(truncatingIfNeeded: JeffJSOpcode.if_true8.rawValue) ? cond : !cond
                if take {
                    let offset = Int(Int8(bitPattern: bc[pc + 5]))
                    let target = pc + 6 + offset
                    if target < 0 || target >= bcLen { ctx.interruptCounter = interrupt; return target }
                    if offset < 0 {
                        interrupt -= 1
                        if interrupt <= 0 {
                            interrupt = JS_INTERRUPT_COUNTER_INIT
                            ctx.interruptCounter = interrupt
                            if ctx.checkInterrupt() { ctx.interruptCounter = interrupt; return -1 }
                        }
                    }
                    pc = target
                } else {
                    pc += 6
                }
            } else {
                buf[sp] = cond ? .JS_TRUE : .JS_FALSE; sp += 1
                pc += 4
            }

        case .cmp_loc_loc:
            let cmp = bc[pc + 1]
            let cond: Bool
            let a = buf[varBase + Int(bc[pc + 2])]
            let b = buf[varBase + Int(bc[pc + 3])]
            if a.isInt && b.isInt {
                cond = jeffJS_cmpInt(cmp, a.toInt32(), b.toInt32())
            } else if a.isNumber && b.isNumber {
                cond = jeffJS_cmpDouble(cmp, jeffJS_traceNum(a), jeffJS_traceNum(b))
            } else { ctx.interruptCounter = interrupt; return pc }
            // Fused branch: when if_true8 / if_false8 follows, branch here
            // instead of pushing a bool for the next dispatch to pop.
            let nb = bc[pc + 4]
            if nb == UInt8(truncatingIfNeeded: JeffJSOpcode.if_true8.rawValue)
                || nb == UInt8(truncatingIfNeeded: JeffJSOpcode.if_false8.rawValue) {
                let take = nb == UInt8(truncatingIfNeeded: JeffJSOpcode.if_true8.rawValue) ? cond : !cond
                if take {
                    let offset = Int(Int8(bitPattern: bc[pc + 5]))
                    let target = pc + 6 + offset
                    if target < 0 || target >= bcLen { ctx.interruptCounter = interrupt; return target }
                    if offset < 0 {
                        interrupt -= 1
                        if interrupt <= 0 {
                            interrupt = JS_INTERRUPT_COUNTER_INIT
                            ctx.interruptCounter = interrupt
                            if ctx.checkInterrupt() { ctx.interruptCounter = interrupt; return -1 }
                        }
                    }
                    pc = target
                } else {
                    pc += 6
                }
            } else {
                buf[sp] = cond ? .JS_TRUE : .JS_FALSE; sp += 1
                pc += 4
            }

        case .arith_loc_loc:
            let ar = bc[pc + 1]
            let a = buf[varBase + Int(bc[pc + 2])]
            let b = buf[varBase + Int(bc[pc + 3])]
            if a.isInt && b.isInt {
                buf[sp] = jeffJS_arithInt(ar, a.toInt32(), b.toInt32()); sp += 1
            } else if a.isNumber && b.isNumber {
                buf[sp] = jeffJS_arithNumeric(ar, jeffJS_traceNum(a), jeffJS_traceNum(b)); sp += 1
            } else if ar == 0 && a.isString && b.isString {
                let r = jeffJS_concatStrings(s1: a, s2: b)
                if r.isException { ctx.interruptCounter = interrupt; return pc }
                buf[sp] = r; sp += 1
            } else { ctx.interruptCounter = interrupt; return pc }
            pc += 4

        case .arith_loc_i8:
            let ar = bc[pc + 1]
            let a = buf[varBase + Int(bc[pc + 2])]
            let k = Int32(Int8(bitPattern: bc[pc + 3]))
            if a.isInt {
                buf[sp] = jeffJS_arithInt(ar, a.toInt32(), k); sp += 1
            } else if a.isNumber {
                buf[sp] = jeffJS_arithNumeric(ar, a.toFloat64(), Double(k)); sp += 1
            } else { ctx.interruptCounter = interrupt; return pc }
            pc += 4

        case .to_int32:
            let v = buf[sp - 1]
            if v.isInt {
            } else if v.isNumber {
                buf[sp - 1] = .newInt32(JeffJSTypeConvert.doubleToInt32(v.toFloat64()))
            } else { ctx.interruptCounter = interrupt; return pc }
            pc += 1

        case .arith_const8:
            let ar = bc[pc + 1]
            let k = Int(bc[pc + 2])
            guard k < cpool.count else { ctx.interruptCounter = interrupt; return pc }
            let c = cpool[k]
            let v = buf[sp - 1]
            if v.isInt && c.isInt {
                buf[sp - 1] = jeffJS_arithInt(ar, v.toInt32(), c.toInt32())
            } else if v.isNumber && c.isNumber {
                buf[sp - 1] = jeffJS_arithNumeric(ar, jeffJS_traceNum(v), jeffJS_traceNum(c))
            } else if ar == 0 && v.isString && c.isString {
                // `s += "lit"`: rope/buffer append, TOS is consumed
                let r = jeffJS_concatStrings(s1: v, s2: c)
                if r.isException { ctx.interruptCounter = interrupt; return pc }
                v.freeValue()
                buf[sp - 1] = r
            } else { ctx.interruptCounter = interrupt; return pc }
            pc += 3

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

        case .push_const8:
            let idx = Int(bc[pc + 1])
            buf[sp] = idx < cpool.count ? cpool[idx].dupValue() : .undefined
            sp += 1
            pc += 2

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

        case .put_loc0: sp -= 1; let oP0 = buf[varBase]; buf[varBase] = buf[sp]; oP0.freeValueFast(); pc += 1
        case .put_loc1: sp -= 1; let oP1 = buf[varBase + 1]; buf[varBase + 1] = buf[sp]; oP1.freeValueFast(); pc += 1
        case .put_loc2: sp -= 1; let oP2 = buf[varBase + 2]; buf[varBase + 2] = buf[sp]; oP2.freeValueFast(); pc += 1
        case .put_loc3: sp -= 1; let oP3 = buf[varBase + 3]; buf[varBase + 3] = buf[sp]; oP3.freeValueFast(); pc += 1

        case .put_loc8:
            let idx = Int(bc[pc + 1])
            sp -= 1; let oPL8 = buf[varBase + idx]; buf[varBase + idx] = buf[sp]; oPL8.freeValueFast()
            pc += 2

        case .put_loc:
            let idx = Int(readU16(bc, pc + 1))
            sp -= 1; let oPL = buf[varBase + idx]; buf[varBase + idx] = buf[sp]; oPL.freeValueFast()
            pc += 3

        case .set_loc0: let oS0 = buf[varBase]; buf[varBase] = buf[sp - 1].dupValueFast(); oS0.freeValueFast(); pc += 1
        case .set_loc1: let oS1 = buf[varBase + 1]; buf[varBase + 1] = buf[sp - 1].dupValueFast(); oS1.freeValueFast(); pc += 1
        case .set_loc2: let oS2 = buf[varBase + 2]; buf[varBase + 2] = buf[sp - 1].dupValueFast(); oS2.freeValueFast(); pc += 1
        case .set_loc3: let oS3 = buf[varBase + 3]; buf[varBase + 3] = buf[sp - 1].dupValueFast(); oS3.freeValueFast(); pc += 1

        case .set_loc8:
            // Store and keep the value: the slot needs its own reference and the
            // previous binding goes (sharing one ref with the stack double-freed).
            let idx = Int(bc[pc + 1])
            let oldSL = buf[varBase + idx]
            buf[varBase + idx] = buf[sp - 1].dupValueFast()
            oldSL.freeValueFast()
            pc += 2

        case .set_loc:
            let idx = Int(readU16(bc, pc + 1))
            let oldSL = buf[varBase + idx]
            buf[varBase + idx] = buf[sp - 1].dupValueFast()
            oldSL.freeValueFast()
            pc += 3

        case .put_loc_check:
            // Pure TDZ check (const assignment is a compile-time throw_error).
            let idx = Int(readU16(bc, pc + 1))
            let current = buf[varBase + idx]
            if current.isUninitialized { ctx.interruptCounter = interrupt; return pc } // deopt: main loop throws
            sp -= 1; buf[varBase + idx] = buf[sp]; current.freeValueFast()
            current.freeValue()
            pc += 3

        case .get_loc_check:
            let idx = Int(readU16(bc, pc + 1))
            let val = buf[varBase + idx]
            if val.isUninitialized { ctx.interruptCounter = interrupt; return pc } // deopt: TDZ
            buf[sp] = val.dupValue(); sp += 1
            pc += 3

        // =================================================================
        // Global variable access (via the per-function inline cache)
        // =================================================================

        // Property access with inline-cache hits only; any miss deopts to the
        // main loop, which performs the full lookup and refills the cache so
        // the next iteration hits here. Mirrors the main-loop hit paths
        // exactly (including their reference-handling).
        // ------------------------------------------------------------------
        // Object / array literals and TDZ slots (object-building loops).
        // ------------------------------------------------------------------
        case .object:
            buf[sp] = ctx.newPlainObject(); sp += 1
            pc += 1

        case .set_loc_uninitialized:
            let idx = Int(readU16(bc, pc + 1))
            let oldTDZ = buf[varBase + idx]
            buf[varBase + idx] = .uninitialized
            oldTDZ.freeValue()
            pc += 3

        case .put_loc_check_init:
            if sp <= varBase { ctx.interruptCounter = interrupt; return pc }
            let idx = Int(readU16(bc, pc + 1))
            let old = buf[varBase + idx]
            sp -= 1; buf[varBase + idx] = buf[sp]
            old.freeValue()
            pc += 3

        case .define_field:
            // Transition IC hit only (mirrors the main loop's fast path).
            guard sp >= varBase + 2, let ents = icEntries else { ctx.interruptCounter = interrupt; return pc }
            let obj = buf[sp - 2]
            guard let jsObj = obj.obj else { ctx.interruptCounter = interrupt; return pc }
            let entry = ents[pc & JeffJSInlineCache.mask]
            guard entry.pc == pc, jeffJS_icDefine(jsObj._ptr, entry, buf[sp - 1], ctx.rt) else { ctx.interruptCounter = interrupt; return pc }
            sp -= 1   // the value ref moved into the new slot
            pc += 5

        case .array_from:
            // Empty literal `[]` only; the parser's orphan `object` sentinel
            // below it is dropped like the main loop does.
            guard readU16(bc, pc + 1) == 0, sp > varBase else { ctx.interruptCounter = interrupt; return pc }
            let below = buf[sp - 1]
            guard let bo = below.obj, bo.classID == JeffJSClassID.object.rawValue, bo.propCount == 0 else { ctx.interruptCounter = interrupt; return pc }
            below.freeValue()
            buf[sp - 1] = ctx.newArray()
            pc += 3

        case .get_field:
            guard let ents = icEntries else { ctx.interruptCounter = interrupt; return pc }
            let obj = buf[sp - 1]
            guard let jsObj = obj.obj else { ctx.interruptCounter = interrupt; return pc }
            let entry = ents[pc & JeffJSInlineCache.mask]
            var icHit: JeffJSValue? = nil
            if entry.pc == pc { icHit = jeffJS_icRead(jsObj._ptr, entry) }
            if let hv = icHit {
                buf[sp - 1] = hv.dupValueFast()
                obj.freeValueFast()
                pc += 5
            } else {
                ctx.interruptCounter = interrupt; return pc // deopt: IC miss
            }

        case .get_field2:
            guard let ents = icEntries else { ctx.interruptCounter = interrupt; return pc }
            let obj = buf[sp - 1]
            guard let jsObj = obj.obj else { ctx.interruptCounter = interrupt; return pc }
            let entry = ents[pc & JeffJSInlineCache.mask]
            var icHit: JeffJSValue? = nil
            if entry.pc == pc { icHit = jeffJS_icRead(jsObj._ptr, entry) }
            if let hv = icHit {
                buf[sp] = hv.dupValueFast(); sp += 1
                pc += 5
            } else {
                ctx.interruptCounter = interrupt; return pc
            }

        case .put_field:
            guard let ents = icEntries else { ctx.interruptCounter = interrupt; return pc }
            let val = buf[sp - 1]
            let obj = buf[sp - 2]
            guard let jsObj = obj.obj else { ctx.interruptCounter = interrupt; return pc }
            let entry = ents[pc & JeffJSInlineCache.mask]
            if entry.pc == pc, jeffJS_icWrite(jsObj._ptr, entry, val) {
                obj.freeValueFast()   // the popped receiver ref (QuickJS: JS_FreeValue(sp[-2]))
                sp -= 2
                pc += 5
            } else {
                ctx.interruptCounter = interrupt; return pc
            }

        case .get_loc8_get_field:
            guard let ents = icEntries else { ctx.interruptCounter = interrupt; return pc }
            let obj = buf[varBase + Int(bc[pc + 1])]
            guard let jsObj = obj.obj else { ctx.interruptCounter = interrupt; return pc }
            let entry = ents[pc & JeffJSInlineCache.mask]
            var icHit: JeffJSValue? = nil
            if entry.pc == pc { icHit = jeffJS_icRead(jsObj._ptr, entry) }
            if let hv = icHit {
                buf[sp] = hv.dupValueFast(); sp += 1
                pc += 6
            } else {
                ctx.interruptCounter = interrupt; return pc
            }

        case .get_arg0_get_field:
            guard let ents = icEntries else { ctx.interruptCounter = interrupt; return pc }
            let obj = buf[0]
            guard let jsObj = obj.obj else { ctx.interruptCounter = interrupt; return pc }
            let entry = ents[pc & JeffJSInlineCache.mask]
            var icHit: JeffJSValue? = nil
            if entry.pc == pc { icHit = jeffJS_icRead(jsObj._ptr, entry) }
            if let hv = icHit {
                buf[sp] = hv.dupValueFast(); sp += 1
                pc += 5
            } else {
                ctx.interruptCounter = interrupt; return pc
            }

        case .get_length:
            guard let ents = icEntries else { ctx.interruptCounter = interrupt; return pc }
            let obj = buf[sp - 1]
            guard let jsObj = obj.obj, let sid = jsObj.shapeIdentity else { ctx.interruptCounter = interrupt; return pc }
            let entry = ents[pc & JeffJSInlineCache.mask]
            if entry.pc == pc, entry.shapePtr == sid, entry.holderPtr == nil,
               entry.propOffset >= 0, entry.propOffset < jsObj.propCount,
               jsObj.extra(at: entry.propOffset) == nil {
                buf[sp - 1] = jsObj.dataValue(at: entry.propOffset).dupValue()
                obj.freeValueFast()
                pc += 1
            } else {
                ctx.interruptCounter = interrupt; return pc // deopt
            }

        case .get_var, .get_var_undef:
            guard let ents = icEntries, let gObj = ctx.globalObj.obj, let gShape = gObj.shape else {
                ctx.interruptCounter = interrupt; return pc // deopt: no IC table yet
            }
            let entry = ents[pc & JeffJSInlineCache.mask]
            if entry.pc == pc,
               entry.shapePtr == UnsafeRawPointer(Unmanaged.passUnretained(gShape).toOpaque()),
               entry.propOffset >= 0, entry.propOffset < gObj.propCount,
               gObj.extra(at: entry.propOffset) == nil {
                buf[sp] = gObj.dataValue(at: entry.propOffset).dupValue(); sp += 1
                pc += 5
            } else {
                ctx.interruptCounter = interrupt; return pc // deopt: IC miss — main loop refills the cache
            }

        case .put_var:
            guard let ents = icEntries, let gObj = ctx.globalObj.obj, let gShape = gObj.shape else {
                ctx.interruptCounter = interrupt; return pc // deopt
            }
            let entry = ents[pc & JeffJSInlineCache.mask]
            if entry.pc == pc,
               entry.shapePtr == UnsafeRawPointer(Unmanaged.passUnretained(gShape).toOpaque()),
               entry.propOffset >= 0, entry.propOffset < gObj.propCount,
               entry.propOffset < gShape.prop.count,
               gShape.prop[entry.propOffset].flags.contains(.writable),
               !gShape.prop[entry.propOffset].flags.contains(.getset),
               gObj.extra(at: entry.propOffset) == nil {
                let chained = isStoreOpcode(bc, pc + 5, bcLen)
                let val: JeffJSValue
                if chained { val = buf[sp - 1].dupValue() } else { sp -= 1; val = buf[sp] }
                let old = gObj.dataValue(at: entry.propOffset)
                gObj.asClass.propValues[entry.propOffset] = val
                old.freeValue()
                pc += 5
            } else {
                ctx.interruptCounter = interrupt; return pc // deopt: IC miss
            }

        // =================================================================
        // Array element access (dense int-indexed fast paths)
        // =================================================================

        case .get_array_el:
            guard sp >= 2 else { ctx.interruptCounter = interrupt; return pc } // deopt: stack too shallow
            let key = buf[sp - 1]
            let objV = buf[sp - 2]
            guard key.isInt, let jsObj = objV.obj,
                  jsObj.classID == JeffJSClassID.array.rawValue else {
                ctx.interruptCounter = interrupt; return pc // deopt: non-array or non-int key
            }
            let idx = key.toInt32()
            guard idx >= 0 else { ctx.interruptCounter = interrupt; return pc }
            let uidx = UInt32(idx)
            var element: JeffJSValue? = nil
            if let storage = jsObj._fastArrayValues {
                if uidx < storage.count, Int(uidx) < storage.values.count {
                    element = storage.values[Int(uidx)]
                }
            } else if case .array(_, let vals, let count) = jsObj.payload {
                if uidx < count, Int(uidx) < vals.count {
                    element = vals[Int(uidx)]
                }
            }
            guard let el = element else { ctx.interruptCounter = interrupt; return pc } // deopt: OOB/holes — slow path decides
            let elDup = el.dupValue()
            objV.freeValueFast()
            sp -= 1
            buf[sp - 1] = elDup
            pc += 1

        case .put_array_el:
            guard sp >= 3 else { ctx.interruptCounter = interrupt; return pc } // deopt: stack too shallow
            let val = buf[sp - 1]
            let key = buf[sp - 2]
            let objV = buf[sp - 3]
            guard key.isInt, let jsObj = objV.obj,
                  jsObj.classID == JeffJSClassID.array.rawValue,
                  let storage = jsObj._fastArrayValues else {
                ctx.interruptCounter = interrupt; return pc // deopt: only the ref-type storage is safe to poke here
            }
            let idx = key.toInt32()
            // In-bounds overwrite only — growth/length updates take the slow path.
            guard idx >= 0, UInt32(idx) < storage.count, Int(idx) < storage.values.count else {
                ctx.interruptCounter = interrupt; return pc
            }
            let old = storage.values[Int(idx)]
            storage.values[Int(idx)] = val
            old.freeValue()
            objV.freeValueFast()   // the popped receiver ref
            sp -= 3
            pc += 1

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
            if sp <= varBase { ctx.interruptCounter = interrupt; return pc }   // underflow: let the guarded main loop report it
            sp -= 1
            buf[sp].freeValueFast()
            pc += 1

        case .nip:
            buf[sp - 2].freeValueFast(); buf[sp - 2] = buf[sp - 1]; sp -= 1
            pc += 1

        case .nip1:
            buf[sp - 3].freeValueFast(); buf[sp - 3] = buf[sp - 2]; buf[sp - 2] = buf[sp - 1]; sp -= 1
            pc += 1

        case .perm3:
            // [a, b, c] -> [c, a, b]
            let c = buf[sp - 1], b = buf[sp - 2], a = buf[sp - 3]
            buf[sp - 3] = c; buf[sp - 2] = a; buf[sp - 1] = b
            pc += 1

        case .perm4:
            // [a, b, c, d] -> [d, a, b, c]
            let d = buf[sp - 1], c = buf[sp - 2], b = buf[sp - 3], a = buf[sp - 4]
            buf[sp - 4] = d; buf[sp - 3] = a; buf[sp - 2] = b; buf[sp - 1] = c
            pc += 1

        case .perm5:
            // [a, b, c, d, e] -> [e, a, b, c, d]
            let e = buf[sp - 1], d = buf[sp - 2], c = buf[sp - 3], b = buf[sp - 4], a = buf[sp - 5]
            buf[sp - 5] = e; buf[sp - 4] = a; buf[sp - 3] = b; buf[sp - 2] = c; buf[sp - 1] = d
            pc += 1

        case .get_loc_checkthis:
            let idx = Int(readU16(bc, pc + 1))
            let val = buf[varBase + idx]
            if val.isUninitialized { ctx.interruptCounter = interrupt; return pc } // deopt: main loop throws
            buf[sp] = val.dupValue(); sp += 1
            pc += 3

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
            } else if lhs.isNumber && rhs.isNumber {
                // Mixed/float operands: plain double arithmetic keeps float
                // loops inside the trace instead of deopting every op.
                sp -= 1
                buf[sp - 1] = .newFloat64(jeffJS_traceNum(lhs) + jeffJS_traceNum(rhs))
                pc += 1
            } else if lhs.isString && rhs.isString {
                // String concat stays in the trace (rope/buffer append).
                let r = jeffJS_concatStrings(s1: lhs, s2: rhs)
                if r.isException { ctx.interruptCounter = interrupt; return pc } // deopt: main loop rethrows
                lhs.freeValue(); rhs.freeValue()
                sp -= 1
                buf[sp - 1] = r
                pc += 1
            } else {
                ctx.interruptCounter = interrupt; return pc // deopt: non-numeric, non-string operands
            }

        case .sub:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                let (r, overflow) = lhs.toInt32().subtractingReportingOverflow(rhs.toInt32())
                sp -= 1
                buf[sp - 1] = overflow ? .newFloat64(Double(lhs.toInt32()) - Double(rhs.toInt32())) : .newInt32(r)
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                // Mixed/float operands: plain double arithmetic keeps float
                // loops inside the trace instead of deopting every op.
                sp -= 1
                buf[sp - 1] = .newFloat64(jeffJS_traceNum(lhs) - jeffJS_traceNum(rhs))
                pc += 1
            } else {
                ctx.interruptCounter = interrupt; return pc // deopt: non-numeric operands
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
            } else if lhs.isNumber && rhs.isNumber {
                // Mixed/float operands: plain double arithmetic keeps float
                // loops inside the trace instead of deopting every op.
                sp -= 1
                buf[sp - 1] = .newFloat64(jeffJS_traceNum(lhs) * jeffJS_traceNum(rhs))
                pc += 1
            } else {
                ctx.interruptCounter = interrupt; return pc // deopt: non-numeric operands
            }

        case .div:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                let a = lhs.toInt32(), b = rhs.toInt32()
                if b == 0 || (a == Int32.min && b == -1) {
                    ctx.interruptCounter = interrupt; return pc // deopt: div by zero or overflow
                }
                let r = a / b
                sp -= 1
                if r * b == a && !(r == 0 && a < 0) {
                    buf[sp - 1] = .newInt32(r)
                } else {
                    buf[sp - 1] = .newFloat64(Double(a) / Double(b))
                }
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                // Mixed/float operands: plain double arithmetic keeps float
                // loops inside the trace instead of deopting every op.
                sp -= 1
                buf[sp - 1] = .newFloat64(jeffJS_traceNum(lhs) / jeffJS_traceNum(rhs))
                pc += 1
            } else {
                ctx.interruptCounter = interrupt; return pc // deopt: non-numeric operands
            }

        case .mod:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                let a = lhs.toInt32(), b = rhs.toInt32()
                if b == 0 || (a == Int32.min && b == -1) {
                    ctx.interruptCounter = interrupt; return pc // deopt
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
                ctx.interruptCounter = interrupt; return pc // deopt
            }

        case .neg:
            let val = buf[sp - 1]
            if val.isInt {
                let v = val.toInt32()
                if v == 0 || v == Int32.min { ctx.interruptCounter = interrupt; return pc } // deopt: -0 or overflow
                buf[sp - 1] = .newInt32(-v)
                pc += 1
            } else {
                ctx.interruptCounter = interrupt; return pc // deopt
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
                ctx.interruptCounter = interrupt; return pc // deopt
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
                ctx.interruptCounter = interrupt; return pc // deopt
            }

        case .inc_loc:
            let idx = Int(bc[pc + 1])
            let val = buf[varBase + idx]
            if val.isInt && val.toInt32() != Int32.max {
                buf[varBase + idx] = .newInt32(val.toInt32() + 1)
                pc += 2
            } else {
                ctx.interruptCounter = interrupt; return pc // deopt
            }

        case .dec_loc:
            let idx = Int(bc[pc + 1])
            let val = buf[varBase + idx]
            if val.isInt && val.toInt32() != Int32.min {
                buf[varBase + idx] = .newInt32(val.toInt32() - 1)
                pc += 2
            } else {
                ctx.interruptCounter = interrupt; return pc // deopt
            }

        case .add_loc:
            let idx = Int(bc[pc + 1])
            let addend = readI32(bc, pc + 2)
            let val = buf[varBase + idx]
            if val.isInt {
                let (r, overflow) = val.toInt32().addingReportingOverflow(addend)
                if overflow { ctx.interruptCounter = interrupt; return pc } // deopt: main loop widens to double
                buf[varBase + idx] = .newInt32(r)
                pc += 6
            } else {
                ctx.interruptCounter = interrupt; return pc // deopt
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
                ctx.interruptCounter = interrupt; return pc // deopt
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
                ctx.interruptCounter = interrupt; return pc // deopt
            }

        case .plus:
            let val = buf[sp - 1]
            if val.isInt {
                pc += 1 // int stays as-is
            } else {
                ctx.interruptCounter = interrupt; return pc // deopt
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
            } else if lhs.isNumber && rhs.isNumber {
                sp -= 1
                buf[sp - 1] = jeffJS_traceNum(lhs) < jeffJS_traceNum(rhs) ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { ctx.interruptCounter = interrupt; return pc }

        case .lte:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = lhs.toInt32() <= rhs.toInt32() ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                sp -= 1
                buf[sp - 1] = jeffJS_traceNum(lhs) <= jeffJS_traceNum(rhs) ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { ctx.interruptCounter = interrupt; return pc }

        case .gt:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = lhs.toInt32() > rhs.toInt32() ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                sp -= 1
                buf[sp - 1] = jeffJS_traceNum(lhs) > jeffJS_traceNum(rhs) ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { ctx.interruptCounter = interrupt; return pc }

        case .gte:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = lhs.toInt32() >= rhs.toInt32() ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                sp -= 1
                buf[sp - 1] = jeffJS_traceNum(lhs) >= jeffJS_traceNum(rhs) ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { ctx.interruptCounter = interrupt; return pc }

        case .eq:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = lhs.toInt32() == rhs.toInt32() ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                sp -= 1
                buf[sp - 1] = jeffJS_traceNum(lhs) == jeffJS_traceNum(rhs) ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { ctx.interruptCounter = interrupt; return pc }

        case .neq:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = lhs.toInt32() != rhs.toInt32() ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                sp -= 1
                buf[sp - 1] = jeffJS_traceNum(lhs) != jeffJS_traceNum(rhs) ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { ctx.interruptCounter = interrupt; return pc }

        case .strict_eq:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = lhs.toInt32() == rhs.toInt32() ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                sp -= 1
                buf[sp - 1] = jeffJS_traceNum(lhs) == jeffJS_traceNum(rhs) ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { ctx.interruptCounter = interrupt; return pc }

        case .strict_neq:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = lhs.toInt32() != rhs.toInt32() ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                sp -= 1
                buf[sp - 1] = jeffJS_traceNum(lhs) != jeffJS_traceNum(rhs) ? .JS_TRUE : .JS_FALSE
                pc += 1
            } else { ctx.interruptCounter = interrupt; return pc }

        // =================================================================
        // Bitwise (inline int fast paths)
        // =================================================================

        case .shl:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = .newInt32(lhs.toInt32() << (rhs.toInt32() & 0x1F))
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                let a = jeffJS_traceToInt32(lhs), b = jeffJS_traceToInt32(rhs)
                sp -= 1
                buf[sp - 1] = .newInt32(a << (b & 0x1F))
                pc += 1
            } else { ctx.interruptCounter = interrupt; return pc }

        case .sar:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = .newInt32(lhs.toInt32() >> (rhs.toInt32() & 0x1F))
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                let a = jeffJS_traceToInt32(lhs), b = jeffJS_traceToInt32(rhs)
                sp -= 1
                buf[sp - 1] = .newInt32(a >> (b & 0x1F))
                pc += 1
            } else { ctx.interruptCounter = interrupt; return pc }

        case .shr:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                let ua = UInt32(bitPattern: lhs.toInt32())
                let result = ua >> (UInt32(rhs.toInt32() & 0x1F))
                sp -= 1
                buf[sp - 1] = .newUInt32(result)
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                let a = UInt32(bitPattern: jeffJS_traceToInt32(lhs)), b = jeffJS_traceToInt32(rhs)
                sp -= 1
                buf[sp - 1] = .newUInt32(a >> UInt32(b & 0x1F))
                pc += 1
            } else { ctx.interruptCounter = interrupt; return pc }

        case .and:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = .newInt32(lhs.toInt32() & rhs.toInt32())
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                let a = jeffJS_traceToInt32(lhs), b = jeffJS_traceToInt32(rhs)
                sp -= 1
                buf[sp - 1] = .newInt32(a & b)
                pc += 1
            } else { ctx.interruptCounter = interrupt; return pc }

        case .or:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = .newInt32(lhs.toInt32() | rhs.toInt32())
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                let a = jeffJS_traceToInt32(lhs), b = jeffJS_traceToInt32(rhs)
                sp -= 1
                buf[sp - 1] = .newInt32(a | b)
                pc += 1
            } else { ctx.interruptCounter = interrupt; return pc }

        case .xor:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            if lhs.isInt && rhs.isInt {
                sp -= 1
                buf[sp - 1] = .newInt32(lhs.toInt32() ^ rhs.toInt32())
                pc += 1
            } else if lhs.isNumber && rhs.isNumber {
                let a = jeffJS_traceToInt32(lhs), b = jeffJS_traceToInt32(rhs)
                sp -= 1
                buf[sp - 1] = .newInt32(a ^ b)
                pc += 1
            } else { ctx.interruptCounter = interrupt; return pc }

        case .not:
            let val = buf[sp - 1]
            if val.isInt {
                buf[sp - 1] = .newInt32(~val.toInt32())
                pc += 1
            } else { ctx.interruptCounter = interrupt; return pc }

        // =================================================================
        // Boolean / type
        // =================================================================

        case .lnot:
            let val = buf[sp - 1]
            buf[sp - 1] = jeffJS_fastToBool(val) ? .JS_FALSE : .JS_TRUE
            pc += 1

        case .typeof_:
            ctx.interruptCounter = interrupt; return pc // deopt: needs string allocation

        // =================================================================
        // Control flow
        // =================================================================

        case .if_false:
            sp -= 1
            let cond = buf[sp]
            let offset = Int(readI32(bc, pc + 1))
            if !jeffJS_fastToBool(cond) {
                let target = pc + 5 + offset
                if target < entryPC || target >= exitPC {
                    ctx.interruptCounter = interrupt; return target // loop exit
                }
                if offset < 0 {   // loop back-edge: interrupt check
                    interrupt -= 1
                    if interrupt <= 0 {
                        interrupt = JS_INTERRUPT_COUNTER_INIT
                        ctx.interruptCounter = interrupt
                        if ctx.checkInterrupt() { ctx.interruptCounter = interrupt; return -1 }
                    }
                }
                pc = target
            } else {
                pc += 5
            }

        case .if_true:
            sp -= 1
            let cond = buf[sp]
            let offset = Int(readI32(bc, pc + 1))
            if jeffJS_fastToBool(cond) {
                let target = pc + 5 + offset
                if target < entryPC || target >= exitPC {
                    ctx.interruptCounter = interrupt; return target // loop exit
                }
                if offset < 0 {   // loop back-edge: interrupt check
                    interrupt -= 1
                    if interrupt <= 0 {
                        interrupt = JS_INTERRUPT_COUNTER_INIT
                        ctx.interruptCounter = interrupt
                        if ctx.checkInterrupt() { ctx.interruptCounter = interrupt; return -1 }
                    }
                }
                pc = target
            } else {
                pc += 5
            }

        case .if_false8:
            sp -= 1
            let cond = buf[sp]
            let offset = Int(readI8(bc, pc + 1))
            if !jeffJS_fastToBool(cond) {
                let target = pc + 2 + offset
                if target < entryPC || target >= exitPC {
                    ctx.interruptCounter = interrupt; return target
                }
                if offset < 0 {   // loop back-edge: interrupt check
                    interrupt -= 1
                    if interrupt <= 0 {
                        interrupt = JS_INTERRUPT_COUNTER_INIT
                        ctx.interruptCounter = interrupt
                        if ctx.checkInterrupt() { ctx.interruptCounter = interrupt; return -1 }
                    }
                }
                pc = target
            } else {
                pc += 2
            }

        case .cmp_if8, .cmp_if:
            let rhs = buf[sp - 1]; let lhs = buf[sp - 2]
            let cbSub = Int(bc[pc + 1])
            let cbShort = (op == .cmp_if8)
            let cbSize = cbShort ? 3 : 6
            var cbCond = false
            if lhs.isInt && rhs.isInt {
                let a = lhs.toInt32(), b = rhs.toInt32()
                switch cbSub & 7 { case 0: cbCond = a < b; case 1: cbCond = a <= b; case 2: cbCond = a > b; case 3: cbCond = a >= b; case 4, 6: cbCond = a == b; default: cbCond = a != b }
            } else if lhs.isNumber && rhs.isNumber {
                let a = jeffJS_traceNum(lhs), b = jeffJS_traceNum(rhs)
                switch cbSub & 7 { case 0: cbCond = a < b; case 1: cbCond = a <= b; case 2: cbCond = a > b; case 3: cbCond = a >= b; case 4, 6: cbCond = a == b; default: cbCond = a != b }
            } else { ctx.interruptCounter = interrupt; return pc }
            sp -= 2
            if cbCond == ((cbSub & 8) != 0) {
                let offset = cbShort ? Int(readI8(bc, pc + 2)) : Int(readI32(bc, pc + 2))
                let target = pc + cbSize + offset
                if target < entryPC || target >= exitPC {
                    ctx.interruptCounter = interrupt; return target
                }
                if offset < 0 {   // loop back-edge: interrupt check
                    interrupt -= 1
                    if interrupt <= 0 {
                        interrupt = JS_INTERRUPT_COUNTER_INIT
                        ctx.interruptCounter = interrupt
                        if ctx.checkInterrupt() { ctx.interruptCounter = interrupt; return -1 }
                    }
                }
                pc = target
            } else {
                pc += cbSize
            }

        case .if_true8:
            sp -= 1
            let cond = buf[sp]
            let offset = Int(readI8(bc, pc + 1))
            if jeffJS_fastToBool(cond) {
                let target = pc + 2 + offset
                if target < entryPC || target >= exitPC {
                    ctx.interruptCounter = interrupt; return target
                }
                if offset < 0 {   // loop back-edge: interrupt check
                    interrupt -= 1
                    if interrupt <= 0 {
                        interrupt = JS_INTERRUPT_COUNTER_INIT
                        ctx.interruptCounter = interrupt
                        if ctx.checkInterrupt() { ctx.interruptCounter = interrupt; return -1 }
                    }
                }
                pc = target
            } else {
                pc += 2
            }

        case .goto_:
            let offset = Int(readI32(bc, pc + 1))
            let target = pc + 5 + offset
            if offset < 0 {
                // Loop-back (any backward jump inside the merged region):
                // interrupt check, then continue the trace at the target.
                interrupt -= 1
                if interrupt <= 0 {
                    interrupt = JS_INTERRUPT_COUNTER_INIT
                    ctx.interruptCounter = interrupt
                    if ctx.checkInterrupt() { ctx.interruptCounter = interrupt; return -1 }
                }
            }
            if target >= entryPC && target < exitPC {
                pc = target
            } else {
                ctx.interruptCounter = interrupt; return target // jump outside trace
            }

        case .goto8:
            let offset = Int(readI8(bc, pc + 1))
            let target = pc + 2 + offset
            if offset < 0 {
                // Loop-back (any backward jump inside the merged region):
                // interrupt check, then continue the trace at the target.
                interrupt -= 1
                if interrupt <= 0 {
                    interrupt = JS_INTERRUPT_COUNTER_INIT
                    ctx.interruptCounter = interrupt
                    if ctx.checkInterrupt() { ctx.interruptCounter = interrupt; return -1 }
                }
            }
            if target >= entryPC && target < exitPC {
                pc = target
            } else {
                ctx.interruptCounter = interrupt; return target // jump outside trace
            }

        case .goto16:
            let offset = Int(readI16(bc, pc + 1))
            let target = pc + 3 + offset
            if offset < 0 {
                // Loop-back (any backward jump inside the merged region):
                // interrupt check, then continue the trace at the target.
                interrupt -= 1
                if interrupt <= 0 {
                    interrupt = JS_INTERRUPT_COUNTER_INIT
                    ctx.interruptCounter = interrupt
                    if ctx.checkInterrupt() { ctx.interruptCounter = interrupt; return -1 }
                }
            }
            if target >= entryPC && target < exitPC {
                pc = target
            } else {
                ctx.interruptCounter = interrupt; return target // jump outside trace
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
            let lhs = buf[sp - 1]              // value pushed before get_loc
            let rhs = buf[varBase + locIdx]    // the local
            if lhs.isInt && rhs.isInt {
                let a = lhs.toInt32(), b = rhs.toInt32()
                let (r, overflow) = a.addingReportingOverflow(b)
                buf[sp - 1] = overflow ? .newFloat64(Double(a) + Double(b)) : .newInt32(r)
                pc += 2
            } else {
                ctx.interruptCounter = interrupt; return pc // deopt
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
            ctx.interruptCounter = interrupt; return pc
        }
    }

    // Fell through the trace boundary — return current pc for main interpreter
    ctx.interruptCounter = interrupt; return pc
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
            // Digits straight into a Latin-1 string (the Swift String round
            // trip dominated `"s" + i` and template building).
            var n = Int(val.toInt32())
            var digits = [UInt8](); digits.reserveCapacity(11)
            if n == 0 { digits.append(48) } else {
                let neg = n < 0
                if neg { n = -n }
                while n > 0 { digits.append(UInt8(48 + n % 10)); n /= 10 }
                if neg { digits.append(45) }
                digits.reverse()
            }
            return JeffJSValue.makeString(JeffJSString(refCount: 1, len: digits.count, isWideChar: false, storage: .str8(digits)))
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
        if d == 0 { return "0" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        let a = Swift.abs(d)
        if a < 9007199254740992 && a == a.rounded(.towardZero) {
            return String(Int64(d))
        }
        // ES Number::toString layout (string concatenation used Swift's own
        // layout here: "1e-07" instead of "1e-7", "1e-06" for 0.000001).
        return jeffJS_formatDoubleJS(d)
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
            // toString returns owned strings (a dup, or a fresh number/bool
            // string); concatStrings borrows its inputs.
            let ls = JeffJSTypeConvert.toString(ctx: ctx, val: lhs)
            if ls.isException { return .exception }
            let rs = JeffJSTypeConvert.toString(ctx: ctx, val: rhs)
            if rs.isException { ls.freeValue(); return .exception }
            let r = ctx.concatStrings(ls, rs)
            ls.freeValue(); rs.freeValue()
            return r
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
            if rs.isException { ls.freeValue(); return .exception }
            let r = ctx.concatStrings(ls, rs)
            ls.freeValue(); rs.freeValue()
            return r
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
                return .newBool(jeffJS_fastToBool(result))
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
    /// Interpreter state handed to / back from the fast trace so it can run
    /// calls and returns (and deopt from inside a callee).
    struct HotState {
        var sp: Int
        var buf: UnsafeMutablePointer<JeffJSValue>
        var bufCapacity: Int
        var varBase: Int
        var spBase: Int
        var bc: UnsafePointer<UInt8>
        var bcLen: Int
        unowned(unsafe) var fb: JeffJSFunctionBytecode
        unowned(unsafe) var frame: JeffJSStackFrame
        var funcObj: JeffJSValue
        var flags: Int
        var bufOwned: Bool
        var varRefsLoaded: Bool
        /// Unmanaged mirror of the current function's varRefs (see
        /// JeffJSObject.varRefsRaw); the trace never touches the array.
        var varRefsRaw: UnsafeMutablePointer<Unmanaged<JeffJSVarRef>?>?
        var varRefsRawCount: Int
        /// Opcodes executed by the last trace run (set by the trace).
        var opsRun: Int = 0
    }

    struct InlineCallFrame {
        var pc: Int
        var sp: Int
        /// Caller's sp at the call: [sp, spTop) holds the callee/receiver/args
        /// the caller owns and releases at the inline return.
        var spTop: Int
        var buf: UnsafeMutablePointer<JeffJSValue>
        var bufCapacity: Int
        var varBase: Int
        var spBase: Int
        var bc: UnsafePointer<UInt8>
        var bcLen: Int
        // unowned(unsafe): the caller frame stays alive through the callee
        // frame's prevFrame chain, and its bytecode through frame.curFunc, so
        // these saved pointers never dangle. Strong references here cost a
        // retain/release pair per field per call.
        unowned(unsafe) var fb: JeffJSFunctionBytecode
        unowned(unsafe) var frame: JeffJSStackFrame
        // No varRefs field: the caller's varRefs are re-derived on pop from
        // funcObj (varRefsFast). Keeping the struct free of refcounted fields
        // makes push/pop plain stores on the runtime's unsafe inline stack.
        var funcObj: JeffJSValue
        var flags: Int
        var bufOwned: Bool
    }

    /// Toggle to enable/disable inline calls for debugging.
    /// When false, all calls go through the recursive `callInternal` path.
    static var useInlineCalls = JeffJSConfig.useInlineCalls

    // NOTE: The interpreter value-buffer pool lives on JeffJSRuntime
    // (acquireInterpBuf/releaseInterpBuf). It used to be a static here, but
    // static-var mutation costs a TLS-backed exclusivity check per call and
    // leaked buffers across runtimes.

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
    static var traceOpcodes = JeffJSConfig.traceOpcodes

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
        // Guard against stack overflow from deep recursion.
        // Depth lives on the context: static-var read-modify-writes here cost a
        // TLS-backed dynamic exclusivity check per call.
        ctx.callDepth += 1
        defer { ctx.callDepth -= 1 }
        if ctx.callDepth > maxCallDepth {
            _ = ctx.throwInternalError(message: "Maximum call stack size exceeded")
            return .exception
        }
        // Entering JS from native: bind the guard to this thread's stack.
        if ctx.callDepth == 1 { ctx.rt.updateStackLimitForCurrentThread() }
        // Native frames are large, so the depth limit alone does not bound stack
        // use; check the real stack pointer every call.
        if ctx.rt.checkStackOverflow() {
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

        // Hot path: a plain bytecode function. The denormalized fbFast field
        // avoids pattern-matching the payload enum, which copies it (retaining
        // the FB and the varRefs array) on every call.
        let fb0: JeffJSFunctionBytecode
        let varRefsOpt: [JeffJSVarRef?]
        if let fastFB = obj.fbFast {
            fb0 = fastFB
            varRefsOpt = obj.varRefsFast
        } else {
            // Cold paths: C functions (e.g. via Promise reaction jobs), bound
            // functions, callable proxies, or payload-only bytecode functions.
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
                return ctx.callFunction(bound.funcObj, thisVal: bound.thisVal, args: fullArgs)   // [[BoundThis]] as is
            }
            // Callable proxy: delegate to the proxy apply trap handler
            if case .proxyData = obj.payload {
                return js_proxy_apply(ctx, obj._obj, thisVal, args)
            }
            guard case .bytecodeFunc(let fbOpt, let varRefs, _) = obj.payload,
                  let fbFromPayload = fbOpt else {
                _ = ctx.throwTypeError(message: "not a bytecode function")
                return .exception
            }
            // Backfill the fast fields for the next call
            obj.fbFast = fbFromPayload
            obj.varRefsFast = varRefs
            fb0 = fbFromPayload
            varRefsOpt = varRefs
        }

        // NOTE: keep this a strong `var`. unowned(unsafe) here was measured
        // slower on call-heavy code three times (before and after the nested
        // function captures were removed): the compiler then copies (retains)
        // the reference around member accesses instead of relying on the
        // variable's own ownership.
        var fb = fb0  // mutable so inline calls can swap callee's bytecode in
        var bc = fb.bytecodePtr
        var bcLen = fb.bytecodeLen

        // Hoist config reads out of the dispatch loop. These come from the
        // runtime's cached copies — plain stored-property loads — because even
        // one static-let accessor per call shows up at 250k calls/sec.
        let rt = ctx.rt
        let traceOps = rt.cfgTraceOpcodes
        let inlineCallsEnabled = rt.cfgUseInlineCalls
        let traceHitThreshold = rt.cfgTraceHitThreshold

        // Set up the call frame (pooled to avoid malloc/free per call)
        unowned(unsafe) var frame: JeffJSStackFrame = rt.acquireFrame()   // frames are immortal (rt.allFrames)
        frame.prevFrame = ctx.currentFrame
        frame.curFunc = funcObj
        // ES spec §10.2.1.2: For non-strict functions, coerce undefined/null this
        // to the global object. Strict mode functions receive this as-is.
        let isConstructor = (flags & JS_CALL_FLAG_CONSTRUCTOR) != 0
        let isStrict = fb0.isStrictMode
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
        // No padding append: `buf` carries the undefined-padded arg slots, and
        // every argBuf consumer (varRef pvalue, detach, syncBufToFrame) bounds-
        // checks or prefers buf. The old pad forced a COW grow per call, and it
        // also made `arguments.length` over-report.
        frame.argBuf = args
        frame.bufArraysLive = true

        // Initialize local variables. Append into the pooled frame's array
        // (released with keepingCapacity) instead of assigning a fresh array —
        // steady-state this is allocation-free.
        // varBuf is materialised lazily by jeffJS_syncBufToFrame(frame, buf, varBase) when a consumer
        // needs it; the unsafe buffer below is the authoritative storage.
        let varCount = Int(fb.varCount)
        frame.varCount = varCount

        let argSlots = max(Int(fb.argCount), args.count)

        // Allocate contiguous unsafe buffer: [arg slots][var slots][value stack].
        // Only the args+vars prefix needs .undefined initialization — the value-
        // stack region is always written before it is read (push before pop;
        // unwind and exit cleanup only touch [spBase, sp)).
        let stackSlots = max(Int(fb.stackSize), 4) + 32
        let totalSlots = argSlots + varCount + stackSlots
        var (buf, bufCapacity) = rt.acquireInterpBuf(size: totalSlots,
                                                     initializedPrefix: argSlots + varCount)
        // True when `buf` was acquired from the pool by this frame and must be
        // released on exit. Inline callees normally carve their frame out of
        // the caller's buffer (bufOwned = false) — no allocation, no arg copy.
        var bufOwned = true
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
        if fb0.selfRefVarIdx >= 0 {
            buf[varBase + fb0.selfRefVarIdx] = funcObj.dupValue()
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
        // Tracks whether `varRefs` holds a non-empty array so the inline call
        // paths can skip the (out-of-line) isEmpty check per call/return.
        var varRefsLoaded = !varRefsOpt.isEmpty

        // Inline call stack for non-recursive function calls.
        // Lazy: the empty array literal is allocation-free; reserveCapacity here
        // forced a ~3KB malloc on EVERY call even with inline calls disabled.
        // Inline call frames live on the runtime's unsafe stack; this
        // activation owns the region above `inlineBase`.
        let inlineBase = rt.inlineStackTop

        // ---- Sync helpers: copy between buf and frame arrays ----

        /// Sync buf → frame.argBuf/varBuf so JeffJSVarRef.pvalue sees current values.
        /// Called before closure creation, close_loc, and var_ref detach.

        /// Sync frame.argBuf/varBuf → buf after external code may have modified them
        /// (e.g. JeffJSVarRef.pvalue setter, generator restore).

        /// Enter an inline call frame for a plain bytecode function.
        /// Stack before: buf[calleeSlot] = funcVal, buf[calleeSlot+1 ..< +argc] = args.
        /// `restoreSp` is the caller's sp after the call (before the result push).
        /// The callee frame is carved out of the caller's buffer starting at the
        /// first arg slot when it fits: no allocation and no argument copy. The
        /// caller's stack values above restoreSp become the callee's arg slots
        /// (their refs move, exactly as the old copy-based path did).

        // ---- Generator resumption: restore saved state ----
        if let saved = resumeState {
            pc = saved.pc
            // Restore varBuf/argBuf from saved state
            frame.varBuf = saved.varBuf
            frame.bufArraysLive = true
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
            jeffJS_syncFrameToBuf(frame, buf, varBase)

            // Result object produced by advancing a `yield*` delegated
            // iterator (next/throw forwarded from the outer generator's
            // caller); handled uniformly after the switch.
            var delegatedResult: JeffJSValue? = nil
            switch resumeCompletionType {
            case 1:
                if fb.isGenerator && !fb.isAsyncFunc && !saved.isInitialYield &&
                   saved.delegatedIter.isUndefined && saved.pc >= 1 &&
                   bc[saved.pc - 1] == JeffJSOpcode.yield_.rawValue {
                    // Suspended at a plain `yield` of a sync generator: resume
                    // with [value, true] so the parser-emitted check after the
                    // yield runs the enclosing finally blocks and returns.
                    buf[sp] = resumeValue; sp += 1
                    buf[sp] = .newBool(true); sp += 1
                } else if fb.isGenerator && !fb.isAsyncFunc && !saved.delegatedIter.isUndefined {
                    // Suspended inside a `yield*` delegation: forward the
                    // return to the inner iterator first (its finally blocks
                    // run there), then resume the outer generator with
                    // [value, true] so its own finally blocks run too.
                    let iter = saved.delegatedIter
                    var doneValue = resumeValue
                    var failed = false
                    let retM = ctx.getProperty(obj: iter, atom: ctx.iterReturnAtom)
                    if retM.isException {
                        failed = true
                    } else if retM.isFunction {
                        let res = ctx.callFunction(retM, thisVal: iter, args: [resumeValue])
                        retM.freeValue()
                        if res.isException {
                            failed = true
                        } else if !res.isObject {
                            _ = ctx.throwTypeError(message: "iterator result is not an object")
                            failed = true
                        } else {
                            // (If the inner return() reports done:false the spec
                            // re-yields its value; that pathological case is
                            // treated as done here.)
                            doneValue = ctx.iteratorGetValue(result: res)
                            res.freeValue()
                        }
                    } else {
                        retM.freeValue()
                    }
                    iter.freeValue()   // the delegation is over either way
                    if failed {
                        retVal = .exception   // dispatch loop runs the generator's handlers
                    } else {
                        buf[sp] = doneValue; sp += 1
                        buf[sp] = .newBool(true); sp += 1
                        pc += 1   // saved.pc points at the yield_star opcode: skip it
                    }
                } else {
                    retVal = resumeValue
                    // Early exit: same teardown as the epilogue (detach captured
                    // locals, return the frame to its pool).
                    if frame.hasLiveVarRefs {
                        jeffJS_syncBufToFrame(frame, buf, varBase)
                        for vr in frame.liveVarRefs where !vr.isDetached {
                            vr.value = vr.pvalue.dupValue()
                            vr.isDetached = true
                            vr.parentFrame = nil; vr.slot = nil
                        }
                    }
                    ctx.currentFrame = frame.prevFrame
                    if bufOwned { rt.releaseInterpBuf(buf, capacity: bufCapacity) }
                    rt.releaseFrame(frame)
                    rt.inlineStackTop = inlineBase
                    return retVal
                }
            case 2:
                if !saved.delegatedIter.isUndefined {
                    // Suspended inside `yield*`: forward the throw to the inner
                    // iterator (its try/catch sees it); the result decides
                    // whether the delegation continues.
                    let iter = saved.delegatedIter
                    let thM = ctx.getPropertyStr(obj: iter, name: "throw")
                    if thM.isException {
                        retVal = .exception
                    } else if thM.isFunction {
                        let res = ctx.callFunction(thM, thisVal: iter, args: [resumeValue])
                        thM.freeValue()
                        if res.isException { retVal = .exception } else { delegatedResult = res }
                    } else {
                        thM.freeValue()
                        // No throw method: close the inner iterator, then throw
                        // a TypeError at the yield* in the outer generator.
                        ctx.iteratorClose(iter: iter, isThrow: false)
                        _ = ctx.throwTypeError(message: "iterator does not have a throw method")
                        retVal = .exception
                    }
                    if delegatedResult == nil { iter.freeValue() }   // delegation ended by the exception
                } else {
                    // Throw: inject the exception and fall through to the dispatch
                    // loop so try/catch handlers in the generator body can catch it.
                    ctx.throwValue(resumeValue.dupValue())
                    retVal = .exception
                }
            default:
                if !saved.delegatedIter.isUndefined {
                    // yield* delegation: advance the inner iterator with the
                    // value sent by next(v) instead of pushing it.
                    let iter = saved.delegatedIter
                    let nextM = ctx.getProperty(obj: iter, atom: ctx.iterNextAtom)
                    if nextM.isException {
                        retVal = .exception
                    } else if nextM.isFunction {
                        let res = ctx.callFunction(nextM, thisVal: iter, args: [resumeValue])
                        nextM.freeValue()
                        if res.isException { retVal = .exception } else { delegatedResult = res }
                    } else {
                        nextM.freeValue()
                        _ = ctx.throwTypeError(message: "iterator does not have a next method")
                        retVal = .exception
                    }
                    if delegatedResult == nil { iter.freeValue() }   // delegation ended by the exception
                } else if !saved.isInitialYield {
                    buf[sp] = resumeValue
                    sp += 1
                    if fb.isGenerator && !fb.isAsyncFunc && saved.pc >= 1 &&
                       bc[saved.pc - 1] == JeffJSOpcode.yield_.rawValue {
                        buf[sp] = .newBool(false); sp += 1   // is_return flag for the check after yield_
                    }
                }
            }
            if let result = delegatedResult {
                let iter = saved.delegatedIter
                if !result.isObject {
                    result.freeValue()
                    iter.freeValue()
                    _ = ctx.throwTypeError(message: "iterator result is not an object")
                    retVal = .exception
                } else {
                    let done = ctx.iteratorCheckDone(result: result)
                    let value = ctx.iteratorGetValue(result: result)
                    result.freeValue()
                    if done {
                        // Inner iterator exhausted — its return value is the
                        // value of the yield* expression; skip the yield_star.
                        iter.freeValue()   // the delegation is over
                        buf[sp] = value; sp += 1
                        if fb.isGenerator && !fb.isAsyncFunc {
                            buf[sp] = .newBool(false); sp += 1   // is_return flag for the check after yield_star
                        }
                        pc += 1  // skip past yield_star
                    } else {
                        // More values — yield this one and re-suspend.
                        if let genObj = generatorObject.toObject(),
                           case .generatorData(let genData) = genObj.payload {
                            jeffJS_syncBufToFrame(frame, buf, varBase)
                            let stackCount = sp - spBase
                            var savedStack = [JeffJSValue](repeating: .undefined, count: stackCount)
                            for i in 0..<stackCount { savedStack[i] = buf[spBase + i]; buf[spBase + i] = .undefined }  // move: the saved state owns them now
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
                        // Early exit: same teardown as the epilogue (detach
                        // captured locals, return the frame to its pool).
                        if frame.hasLiveVarRefs {
                            jeffJS_syncBufToFrame(frame, buf, varBase)
                            for vr in frame.liveVarRefs where !vr.isDetached {
                                vr.value = vr.pvalue.dupValue()
                                vr.isDetached = true
                                vr.parentFrame = nil; vr.slot = nil
                            }
                        }
                        ctx.currentFrame = frame.prevFrame
                        if bufOwned { rt.releaseInterpBuf(buf, capacity: bufCapacity) }
                        rt.releaseFrame(frame)
                        rt.inlineStackTop = inlineBase
                        return retVal
                    }
                }
            }
        }

        // Helper closures for stack operations using the contiguous buffer.
        // Safety guards for sp underflow: if bytecode is malformed, return
        // .undefined rather than reading into arg/var slots.




        // =====================================================================
        // MARK: Dispatch Loop
        // =====================================================================

        #if DEBUG
        var opcodeCount = 0
        #endif

        exceptionRetry: while true {
        // Fast-trace entry at activation start (and at catch handlers after an
        // exception): the trace is the primary interpreter; this loop is the
        // fallback for whatever it cannot run.
        if !retVal.isException, resumeState == nil, fb.traceLean, pc < bcLen {
            let r = executeFastTraceLean(bc: bc, bcLen: bcLen, entryPC: 0, exitPC: bcLen, startPC: pc,
                                         buf: buf, varBase: varBase, sp: &sp, ctx: ctx, cpool: fb.cpool,
                                         stackLimit: bufCapacity, icEntries: fb.icEntries)
            if r == -1 { retVal = .exception } else { pc = r }
        }
        if !retVal.isException, resumeState == nil, fb.traceEntryEnabled, !fb.traceLean,
           !fb.isGenerator, !fb.isAsyncFunc, pc < bcLen {
            let fbIdBefore = ObjectIdentifier(fb)
            var hot = HotState(sp: sp, buf: buf, bufCapacity: bufCapacity, varBase: varBase, spBase: spBase, bc: bc, bcLen: bcLen, fb: fb, frame: frame, funcObj: mFuncObj, flags: mFlags, bufOwned: bufOwned, varRefsLoaded: varRefsLoaded, varRefsRaw: mFuncObj.obj?.varRefsRaw, varRefsRawCount: mFuncObj.obj?.varRefsRawCount ?? 0)
            let resumePC = executeFastTrace(state: &hot, startPC: pc, ctx: ctx, rt: rt, inlineBase: inlineBase)
            sp = hot.sp; buf = hot.buf; bufCapacity = hot.bufCapacity; varBase = hot.varBase; spBase = hot.spBase
            bc = hot.bc; bcLen = hot.bcLen; fb = hot.fb; frame = hot.frame
            mFuncObj = hot.funcObj; mFlags = hot.flags; bufOwned = hot.bufOwned
            if fb.closureVarCount > 0 { varRefs = mFuncObj.obj?.varRefsFast ?? []; varRefsLoaded = true } else if varRefsLoaded { varRefs = []; varRefsLoaded = false }
            // Entry deopt accounting: an early exit still inside this function
            // means the trace could not run it; stop trying after a while.
            if hot.opsRun < 16, ObjectIdentifier(fb) == fbIdBefore {
                fb.traceEntryDeopts &+= 1
                if fb.traceEntryDeopts >= 100 { fb.traceEntryEnabled = false }
            }
            if resumePC == -1 { retVal = .exception } else { pc = resumePC }
        }
        // If an exception was injected before the dispatch loop (e.g.,
        // generator.throw() resume), skip straight to exception handling.
        if !retVal.isException {
        dispatchLoop: while pc < bcLen {
            // Fast opcode decode. The synthesized `init(rawValue:)?` for this
            // 272-case enum compiled to a validating lookup that cost ~6% of a
            // pure dispatch loop. A no-payload enum's in-memory value IS its
            // declaration index (== auto-assigned rawValue), and every narrow
            // byte (0-255) is a valid case (<272), so a raw bitcast is sound.
            // Wide opcodes use the 0x00 (.invalid) prefix, handled below.
            // DEBUG cross-checks the bitcast against the safe initializer so any
            // future enum-layout drift is caught immediately.
            #if DEBUG
            let op = JeffJSOpcode(rawValue: UInt16(bc[pc]))!
            assert(op == unsafeBitCast(UInt16(bc[pc]), to: JeffJSOpcode.self),
                   "JeffJSOpcode layout drift: bitcast decode no longer valid")
            #else
            let op = unsafeBitCast(UInt16(bc[pc]), to: JeffJSOpcode.self)
            #endif
            #if JEFFJS_OPPROF
            jeffJS_opProfRecord(bc[pc] == 0 && pc + 1 < bcLen ? 256 + Int(bc[pc + 1]) : Int(bc[pc]))
            #endif

            #if DEBUG
            opcodeCount += 1
            #endif

            if traceOps {
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
                            let obj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                            if obj.isUndefined || obj.isNull {
                                buf[sp] = .undefined; sp += 1
                            } else {
                                let val = ctx.getProperty(obj: obj, atom: atom)
                                if val.isException { retVal = .exception; break dispatchLoop }
                                buf[sp] = val; sp += 1
                            }
                            pc += 2 + 4
                            continue dispatchLoop
                        case .get_array_el_opt_chain:
                            let key = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                            let obj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                            if obj.isUndefined || obj.isNull {
                                buf[sp] = .undefined; sp += 1
                            } else {
                                let val = ctx.getPropertyValue(obj: obj, prop: key)
                                if val.isException { retVal = .exception; break dispatchLoop }
                                buf[sp] = val; sp += 1
                            }
                            pc += 2
                            continue dispatchLoop
                        case .with_get_var, .with_put_var, .with_delete_var,
                             .with_make_ref, .with_get_ref, .with_get_ref_undef:
                            // Evicted to the wide range (see JeffJSOpcode). Skip
                            // the prefix byte; the handler's operand offsets are
                            // relative to the opcode byte.
                            pc += 1
                            let op = wideOp
                let atom = readU32(bc, pc + 1)
                let label = readI32(bc, pc + 5)
                let withFlags = Int(readU8(bc, pc + 9))
                let obj = buf[sp - 1]
                let hasProp = ctx.hasProperty(obj: obj, atom: atom)
                if hasProp {
                    switch op {
                    case .with_get_var:
                        // nPop=1, nPush=1: replace the with_obj on TOS with the property value
                        let _ = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) // remove with object
                        let val = ctx.getProperty(obj: obj, atom: atom)
                        buf[sp] = val; sp += 1
                    case .with_get_ref, .with_get_ref_undef:
                        // nPop=1, nPush=2: replace with_obj with (obj, propKey) reference pair
                        let _ = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) // remove with object
                        buf[sp] = obj.dupValue(); sp += 1
                        let propKey = ctx.atomToString(atom)
                        buf[sp] = propKey; sp += 1
                    case .with_put_var:
                        // nPop=2, nPush=0: pop val and with_obj, set property
                        // Note: in QuickJS the table says nPush=1 but the code does sp -= 2.
                        // The with_obj is TOS, val is below it.
                        let _ = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) // with object
                        let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) // value to assign
                        let _ = ctx.setProperty(obj: obj, atom: atom, value: val)
                    case .with_delete_var:
                        // nPop=1, nPush=1: replace with_obj with delete result bool
                        let _ = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) // remove with object
                        let ok = ctx.deleteProperty(obj: obj, atom: atom)
                        buf[sp] = .newBool(ok); sp += 1
                    case .with_make_ref:
                        // nPop=1, nPush=2: replace with_obj with (obj, propKey) reference
                        let _ = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) // remove with object
                        buf[sp] = obj.dupValue(); sp += 1
                        let propKey = ctx.atomToString(atom)
                        buf[sp] = propKey; sp += 1
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

            case .with_get_var, .with_put_var, .with_delete_var,
                 .with_make_ref, .with_get_ref, .with_get_ref_undef:
                // Wide opcodes: they only ever arrive through the 0x00 prefix
                // (handled in `.invalid`), never as a raw dispatch value.
                _ = ctx.throwInternalError(message: "wide opcode dispatched directly at pc=\(pc)")
                retVal = .exception
                break dispatchLoop

            // -----------------------------------------------------------------
            // Fused superinstructions (see JeffJSCompiler peepholes)
            // -----------------------------------------------------------------
            case .cmp_loc_i8:
                let cmp = bc[pc + 1]
                let a = buf[varBase + Int(bc[pc + 2])]
                let k = Int32(Int8(bitPattern: bc[pc + 3]))
                if a.isInt {
                    buf[sp] = .newBool(jeffJS_cmpInt(cmp, a.toInt32(), k)); sp += 1
                } else if a.isNumber {
                    buf[sp] = .newBool(jeffJS_cmpDouble(cmp, a.toFloat64(), Double(k))); sp += 1
                } else {
                    guard let r = jeffJS_cmpGeneric(ctx, cmp, a.dupValue(), .newInt32(k)) else { retVal = .exception; break dispatchLoop }
                    buf[sp] = .newBool(r); sp += 1
                }
                pc += 4

            case .cmp_loc_loc:
                let cmp = bc[pc + 1]
                let a = buf[varBase + Int(bc[pc + 2])]
                let b = buf[varBase + Int(bc[pc + 3])]
                if a.isInt && b.isInt {
                    buf[sp] = .newBool(jeffJS_cmpInt(cmp, a.toInt32(), b.toInt32())); sp += 1
                } else if a.isNumber && b.isNumber {
                    buf[sp] = .newBool(jeffJS_cmpDouble(cmp, jeffJS_traceNum(a), jeffJS_traceNum(b))); sp += 1
                } else {
                    guard let r = jeffJS_cmpGeneric(ctx, cmp, a.dupValue(), b.dupValue()) else { retVal = .exception; break dispatchLoop }
                    buf[sp] = .newBool(r); sp += 1
                }
                pc += 4

            case .arith_loc_loc:
                let ar = bc[pc + 1]
                let a = buf[varBase + Int(bc[pc + 2])]
                let b = buf[varBase + Int(bc[pc + 3])]
                if a.isInt && b.isInt {
                    buf[sp] = jeffJS_arithInt(ar, a.toInt32(), b.toInt32()); sp += 1
                } else if a.isNumber && b.isNumber {
                    buf[sp] = jeffJS_arithNumeric(ar, jeffJS_traceNum(a), jeffJS_traceNum(b)); sp += 1
                } else {
                    guard let r = jeffJS_arithGeneric(ctx, ar, a.dupValue(), b.dupValue()) else { retVal = .exception; break dispatchLoop }
                    buf[sp] = r; sp += 1
                }
                pc += 4

            case .arith_loc_i8:
                let ar = bc[pc + 1]
                let a = buf[varBase + Int(bc[pc + 2])]
                let k = Int32(Int8(bitPattern: bc[pc + 3]))
                if a.isInt {
                    buf[sp] = jeffJS_arithInt(ar, a.toInt32(), k); sp += 1
                } else if a.isNumber {
                    buf[sp] = jeffJS_arithNumeric(ar, a.toFloat64(), Double(k)); sp += 1
                } else {
                    guard let r = jeffJS_arithGeneric(ctx, ar, a.dupValue(), .newInt32(k)) else { retVal = .exception; break dispatchLoop }
                    buf[sp] = r; sp += 1
                }
                pc += 4

            case .to_int32:
                let v = buf[sp - 1]
                if v.isInt {
                    // already an int32
                } else if v.isNumber {
                    buf[sp - 1] = .newInt32(JeffJSTypeConvert.doubleToInt32(v.toFloat64()))
                } else {
                    let (i, ok) = JeffJSTypeConvert.toInt32(ctx: ctx, val: v)
                    v.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    buf[sp - 1] = .newInt32(i)
                }
                pc += 1

            case .arith_const8:
                let ar = bc[pc + 1]
                let k = Int(bc[pc + 2])
                let c: JeffJSValue = k < fb.cpool.count ? fb.cpool[k] : .undefined
                let v = buf[sp - 1]
                if v.isInt && c.isInt {
                    buf[sp - 1] = jeffJS_arithInt(ar, v.toInt32(), c.toInt32())
                } else if v.isNumber && c.isNumber {
                    buf[sp - 1] = jeffJS_arithNumeric(ar, jeffJS_traceNum(v), jeffJS_traceNum(c))
                } else {
                    guard let r = jeffJS_arithGeneric(ctx, ar, v, c.dupValue()) else { retVal = .exception; break dispatchLoop }
                    buf[sp - 1] = r
                }
                pc += 3

            case .push_i32:
                let val = readI32(bc, pc + 1)
                buf[sp] = .newInt32(val); sp += 1
                pc += 5

            case .push_const:
                let idx = Int(readU32(bc, pc + 1))
                if idx < fb.cpool.count {
                    buf[sp] = fb.cpool[idx].dupValue(); sp += 1
                } else {
                    buf[sp] = .undefined; sp += 1
                }
                pc += 5

            case .fclosure:
                let idx = Int(readU32(bc, pc + 1))
                // No buf↔frame sync needed: createClosure only builds VarRefs
                // pointing at the parent frame, and VarRef.pvalue reads through
                // frame.buf (always current) in preference to the frame arrays.
                let closureVal = ctx.createClosure(fb: fb, cpoolIdx: idx, varRefs: varRefs,
                                                    parentFrame: frame)
                buf[sp] = closureVal; sp += 1
                pc += 5

            case .push_atom_value:
                let atom = readU32(bc, pc + 1)
                let str = ctx.atomToString(atom)
                buf[sp] = str; sp += 1
                pc += 5

            case .private_symbol:
                let atom = readU32(bc, pc + 1)
                let sym = ctx.newSymbolFromAtom(atom, isPrivate: true)
                buf[sp] = sym; sp += 1
                pc += 5

            case .undefined:
                buf[sp] = .undefined; sp += 1
                pc += 1

            case .push_false:
                buf[sp] = .newBool(false); sp += 1
                pc += 1

            case .push_true:
                buf[sp] = .newBool(true); sp += 1
                pc += 1

            case .object:
                let obj = ctx.newPlainObject()
                buf[sp] = obj; sp += 1
                pc += 1

            case .special_object:
                let kind = readU8(bc, pc + 1)
                // Sync buf → frame since newSpecialObject reads frame.argBuf
                jeffJS_syncBufToFrame(frame, buf, varBase)
                let obj = ctx.newSpecialObject(kind: kind, frame: frame)
                buf[sp] = obj; sp += 1
                pc += 2

            case .rest:
                let argIdx = Int(readU16(bc, pc + 1))
                // Build args array from buf for createRestArray
                var restSrcArgs = [JeffJSValue](repeating: .undefined, count: varBase)
                for i in 0..<varBase { restSrcArgs[i] = buf[i] }
                let restArr = ctx.createRestArray(args: restSrcArgs, fromIndex: argIdx)
                buf[sp] = restArr; sp += 1
                pc += 3

            // -----------------------------------------------------------------
            // Stack Manipulation
            // -----------------------------------------------------------------

            case .drop:
                let dropped = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                dropped.freeValue()
                pc += 1

            case .nip:
                let top = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let discarded = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                discarded.freeValue()
                buf[sp] = top; sp += 1
                pc += 1

            case .nip1:
                let a = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let b = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let discarded = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                discarded.freeValue()
                buf[sp] = b; sp += 1; buf[sp] = a; sp += 1
                pc += 1

            case .dup:
                let val = buf[sp - 1]
                buf[sp] = val.dupValue(); sp += 1
                pc += 1

            case .dup1:
                // Duplicate the element below the top: a b -> a b a
                let a = buf[sp - 2]
                buf[sp] = a.dupValue(); sp += 1
                pc += 1

            case .dup2:
                let b = buf[sp - 1]
                let a = buf[sp - 2]
                buf[sp] = a.dupValue(); sp += 1
                buf[sp] = b.dupValue(); sp += 1
                pc += 1

            case .dup3:
                let c = buf[sp - 1]
                let b = buf[sp - 2]
                let a = buf[sp - 3]
                buf[sp] = a.dupValue(); sp += 1
                buf[sp] = b.dupValue(); sp += 1
                buf[sp] = c.dupValue(); sp += 1
                pc += 1

            case .insert2:
                // QuickJS: a b -> b a b (insert copy of TOS below top 2)
                // nPop=2, nPush=3
                let b = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let a = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                buf[sp] = b; sp += 1; buf[sp] = a; sp += 1; buf[sp] = b.dupValue(); sp += 1
                pc += 1

            case .insert3:
                // QuickJS: a b c -> c a b c (insert copy of TOS below top 3)
                // nPop=3, nPush=4
                let c = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let b = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let a = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                buf[sp] = c; sp += 1; buf[sp] = a; sp += 1; buf[sp] = b; sp += 1; buf[sp] = c.dupValue(); sp += 1
                pc += 1

            case .insert4:
                // QuickJS: a b c d -> d a b c d (insert copy of TOS below top 4)
                // nPop=4, nPush=5
                let d = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let c = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let b = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let a = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                buf[sp] = d; sp += 1; buf[sp] = a; sp += 1; buf[sp] = b; sp += 1; buf[sp] = c; sp += 1; buf[sp] = d.dupValue(); sp += 1
                pc += 1

            case .perm3:
                let c = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let b = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let a = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                buf[sp] = c; sp += 1; buf[sp] = a; sp += 1; buf[sp] = b; sp += 1
                pc += 1

            case .perm4:
                let d = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let c = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let b = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let a = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                buf[sp] = d; sp += 1; buf[sp] = a; sp += 1; buf[sp] = b; sp += 1; buf[sp] = c; sp += 1
                pc += 1

            case .perm5:
                let e = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let d = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let c = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let b = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let a = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                buf[sp] = e; sp += 1; buf[sp] = a; sp += 1; buf[sp] = b; sp += 1; buf[sp] = c; sp += 1; buf[sp] = d; sp += 1
                pc += 1

            case .swap:
                let a = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let b = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                buf[sp] = a; sp += 1; buf[sp] = b; sp += 1
                pc += 1

            case .swap2:
                // Swap top 2 pairs: a b c d -> c d a b
                let d = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let c = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let b = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let a = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                buf[sp] = c; sp += 1; buf[sp] = d; sp += 1; buf[sp] = a; sp += 1; buf[sp] = b; sp += 1
                pc += 1

            case .rot3l:
                let c = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let b = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let a = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                buf[sp] = b; sp += 1; buf[sp] = c; sp += 1; buf[sp] = a; sp += 1
                pc += 1

            case .rot3r:
                // Rotate 3 right: a b c -> c a b
                let c = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let b = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let a = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                buf[sp] = c; sp += 1; buf[sp] = a; sp += 1; buf[sp] = b; sp += 1
                pc += 1

            case .rot4l:
                let d = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let c = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let b = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let a = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                buf[sp] = b; sp += 1; buf[sp] = c; sp += 1; buf[sp] = d; sp += 1; buf[sp] = a; sp += 1
                pc += 1

            case .rot5l:
                // Rotate 5 left: a b c d e -> b c d e a
                let e = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let d = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let c = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let b = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let a = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                buf[sp] = b; sp += 1; buf[sp] = c; sp += 1; buf[sp] = d; sp += 1; buf[sp] = e; sp += 1; buf[sp] = a; sp += 1
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
                // Peek the callee WITHOUT popping. Stack layout is
                // [..., funcVal, arg0 … arg(argc-1)] with sp just past the last
                // arg, so funcVal sits at sp-argc-1. Peeking lets the inline fast
                // path move args straight from this buffer into the callee's,
                // skipping the per-call [JeffJSValue] args-array allocation that
                // dominated function-call cost. The slow path below pops normally.
                let calleeSlot = sp - argc - 1
                let funcVal: JeffJSValue = calleeSlot >= spBase ? buf[calleeSlot] : .undefined
                // Inline call fast path: regular bytecode function
                // fbFast/varRefsFast are denormalised copies of the payload
                // fields: pattern-matching the payload enum copies it (retaining
                // the FB and the varRefs array) on every call. nil fbFast
                // (never called before) takes the slow path, which backfills it.
                if inlineCallsEnabled, calleeSlot >= spBase,
                   let callObj = funcVal.obj,
                   let fastFb = callObj.fbFast, !fastFb.isGenerator, !fastFb.isAsyncFunc {
                    let fastVarRefsOpt = callObj.varRefsFast
                    // Depth guard (checked before any state mutation; on overflow
                    // args+funcVal stay on the caller stack and unwind normally).
                    if rt.inlineStackTop - inlineBase > 10000 {
                        _ = ctx.throwInternalError(message: "Maximum call stack size exceeded")
                        retVal = .exception
                        break dispatchLoop
                    }
                    // `this`: a get_field receiver stash consumed only by the
                    // directly-following call (arrow callees ignore it, so
                    // leave the stash alone for them).
                    var callThis: JeffJSValue = .undefined
                    if !fastFb.isArrow,
                       !frame.lastGetFieldReceiver.isUndefined,
                       frame.lastGetFieldPC >= 0, pc == frame.lastGetFieldPC + 5 {
                        callThis = frame.lastGetFieldReceiver   // move the stash's ref
                        frame.lastGetFieldReceiver = .undefined
                        frame.lastGetFieldPC = -1
                    }
                    do { // inline call (expanded; no nested-function capture of hot locals)
                        let e_fastFb = fastFb
                        let e_callObj = callObj
                        let e_funcVal = funcVal
                        let e_argc = argc
                        let e_calleeSlot = calleeSlot
                        let e_restoreSp = calleeSlot
                        let e_thisVal = callThis
                        let e_instrSize = instrSize
                        let argStart = e_calleeSlot + 1
                        rt.inlinePush(InlineCallFrame(
                            pc: pc + e_instrSize, sp: e_restoreSp, spTop: sp,
                            buf: buf, bufCapacity: bufCapacity,
                            varBase: varBase, spBase: spBase,
                            bc: bc, bcLen: bcLen, fb: fb,
                            frame: frame,
                            funcObj: mFuncObj, flags: mFlags, bufOwned: bufOwned))
                        fb = e_fastFb
                        bc = e_fastFb.bcPtrFast ?? e_fastFb.bytecodePtr
                        bcLen = e_fastFb.bytecodeLen
                        // Only functions with closure variables need their varRefs
                        // array (a retain/release pair per assignment otherwise).
                        if e_fastFb.closureVarCount > 0 {
                            varRefs = e_callObj.varRefsFast
                            varRefsLoaded = true
                        } else if varRefsLoaded {
                            varRefs = []
                            varRefsLoaded = false
                        }
                        mFuncObj = e_funcVal
                        mFlags = 0
                        unowned(unsafe) let newFrame: JeffJSStackFrame = rt.acquireFrameU().takeUnretainedValue()
                        newFrame.prevFrame = ctx.currentFrame
                        newFrame.curFunc = e_funcVal
                        if e_fastFb.isArrow, let arrowThis = e_callObj.arrowThisVal {
                            newFrame.thisVal = arrowThis.dupValue()
                        } else if !e_fastFb.isStrictMode && e_thisVal.isNullOrUndefined {
                            // ES §10.2.1.2: sloppy callees see the global object.
                            newFrame.thisVal = ctx.globalObj
                        } else {
                            newFrame.thisVal = e_thisVal
                        }
                        newFrame.argCount = e_argc
                        let newVarCount = Int(e_fastFb.varCount)
                        newFrame.varCount = newVarCount
                        let fbArgCount = Int(e_fastFb.argCount); let newArgSlots = fbArgCount > e_argc ? fbArgCount : e_argc
                        let fbStack = Int(e_fastFb.stackSize); let newStackSlots = (fbStack > 4 ? fbStack : 4) + 32
                        let newTotalSlots = newArgSlots + newVarCount + newStackSlots
                        let newBuf: UnsafeMutablePointer<JeffJSValue>
                        let newBufCap: Int
                        if argStart + newTotalSlots <= bufCapacity {
                            newBuf = buf + argStart
                            newBufCap = bufCapacity - argStart
                            // Args are already in place; pad missing args + locals.
                            // Straight-line stores for the common small counts: the loop
                            // form was turned into a memset_pattern16 call per call.
                            let prefix = newArgSlots + newVarCount
                            let pad = prefix - e_argc
                            if pad > 0 {
                                newBuf[e_argc] = .undefined
                                if pad > 1 { newBuf[e_argc + 1] = .undefined }
                                if pad > 2 { newBuf[e_argc + 2] = .undefined }
                                if pad > 3 {
                                    var i = e_argc + 3
                                    while i < prefix { newBuf[i] = .undefined; i += 1 }
                                }
                            }
                            bufOwned = false
                        } else {
                            (newBuf, newBufCap) = rt.acquireInterpBuf(size: newTotalSlots,
                                                                      initializedPrefix: newArgSlots + newVarCount)
                            for i in 0..<e_argc { newBuf[i] = buf[argStart + i] }
                            bufOwned = true
                        }
                        frame = newFrame
                        ctx.currentFrame = frame
                        frame.spBase = 0
                        buf = newBuf
                        bufCapacity = newBufCap
                        varBase = newArgSlots
                        spBase = newArgSlots + newVarCount
                        sp = spBase
                        // Named function expression self-reference (ES §15.2.4).
                        if e_fastFb.selfRefVarIdx >= 0 {
                            buf[varBase + e_fastFb.selfRefVarIdx] = e_funcVal.dupValue()
                        }
                        frame.buf = buf
                        frame.bufCapacity = bufCapacity
                        frame.bufVarBase = varBase
                        frame.bufSpBase = spBase
                        pc = 0
                    }
                    // Run the callee in the fast trace from its first instruction.
                    if fb.traceLean {
                        let r = executeFastTraceLean(bc: bc, bcLen: bcLen, entryPC: 0, exitPC: bcLen, startPC: pc,
                                                     buf: buf, varBase: varBase, sp: &sp, ctx: ctx, cpool: fb.cpool,
                                                     stackLimit: bufCapacity, icEntries: fb.icEntries)
                        if r == -1 { retVal = .exception; break dispatchLoop }
                        pc = r
                        continue dispatchLoop
                    }
                    if fb.traceEntryEnabled {
                        let fbIdBefore = ObjectIdentifier(fb)
                        var hot = HotState(sp: sp, buf: buf, bufCapacity: bufCapacity, varBase: varBase, spBase: spBase, bc: bc, bcLen: bcLen, fb: fb, frame: frame, funcObj: mFuncObj, flags: mFlags, bufOwned: bufOwned, varRefsLoaded: varRefsLoaded, varRefsRaw: mFuncObj.obj?.varRefsRaw, varRefsRawCount: mFuncObj.obj?.varRefsRawCount ?? 0)
                        let resumePC = executeFastTrace(state: &hot, startPC: pc, ctx: ctx, rt: rt, inlineBase: inlineBase)
                        sp = hot.sp; buf = hot.buf; bufCapacity = hot.bufCapacity; varBase = hot.varBase; spBase = hot.spBase
                        bc = hot.bc; bcLen = hot.bcLen; fb = hot.fb; frame = hot.frame
                        mFuncObj = hot.funcObj; mFlags = hot.flags; bufOwned = hot.bufOwned
                        if fb.closureVarCount > 0 { varRefs = mFuncObj.obj?.varRefsFast ?? []; varRefsLoaded = true } else if varRefsLoaded { varRefs = []; varRefsLoaded = false }
                        // Entry deopt accounting: an early exit still inside this function
                        // means the trace could not run it; stop trying after a while.
                        if hot.opsRun < 16, ObjectIdentifier(fb) == fbIdBefore {
                            fb.traceEntryDeopts &+= 1
                            if fb.traceEntryDeopts >= 100 { fb.traceEntryEnabled = false }
                        }
                        if resumePC == -1 { retVal = .exception; break dispatchLoop }
                        pc = resumePC
                    }
                    continue dispatchLoop
                } else {
                    // Slow path: bound functions, C functions, generators, async,
                    // etc. Now build the args array and pop funcVal + args.
                    let callArgs: [JeffJSValue]
                    switch argc {
                    case 0:
                        callArgs = []
                    case 1:
                        let a0 = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                        callArgs = [a0]
                    case 2:
                        let a1 = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let a0 = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                        callArgs = [a0, a1]
                    case 3:
                        let a2 = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let a1 = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let a0 = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                        callArgs = [a0, a1, a2]
                    default:
                        var tmp = [JeffJSValue](repeating: .undefined, count: argc)
                        for i in stride(from: argc - 1, through: 0, by: -1) { tmp[i] = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) }
                        callArgs = tmp
                    }
                    let funcVal = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                    // Use lastGetFieldReceiver as `this` if available (method call
                    // that transformMethodCalls couldn't convert to call_method).
                    let stashValid = !frame.lastGetFieldReceiver.isUndefined
                        && frame.lastGetFieldPC >= 0 && pc == frame.lastGetFieldPC + 5
                    let slowThis = stashValid ? frame.lastGetFieldReceiver : JeffJSValue.undefined
                    let result: JeffJSValue
                    var calleeIsBytecode = false
                    if let callObj = funcVal.obj,
                       let fastFb2 = callObj.fbFast, !fastFb2.isGenerator, !fastFb2.isAsyncFunc {
                        // fbFast avoids copying the payload enum per call;
                        // nil falls through to callFunction, which routes
                        // every callee kind (and backfills fbFast via
                        // callInternal for plain bytecode functions).
                        result = JeffJSInterpreter.callInternal(ctx: ctx, funcObj: funcVal,
                                                                thisVal: slowThis, args: callArgs, flags: 0)
                        calleeIsBytecode = true
                    } else {
                        result = ctx.callFunction(funcVal, thisVal: slowThis, args: callArgs)
                    }
                    // Drop the stash's reference (taken via dupValue in get_field)
                    frame.lastGetFieldReceiver.freeValue()
                    frame.lastGetFieldReceiver = .undefined  // clear after use
                    frame.lastGetFieldPC = -1
                    // The call borrows: release the popped callee, and the args
                    // for bytecode callees (C functions may store an arg
                    // without a dup; those keep the old leak for now).
                    funcVal.freeValue()
                    if calleeIsBytecode { for a in callArgs { a.freeValue() } }
                    if result.isException {
                        retVal = .exception
                        break dispatchLoop
                    }
                    buf[sp] = result; sp += 1
                    pc += instrSize
                }

            case .call_method:
                var argc = Int(readU16(bc, pc + 1))
                // ── Function.prototype.call intrinsic ───────────────────
                // f.call(thisArg, a, b) becomes a direct call of f with
                // this = thisArg and args (a, b), rewritten on the stack: the
                // receiver moves into the callee slot, the first argument
                // into the this slot, the rest shift down one. This skips the
                // native call layer and the argument array the builtin
                // allocated on every call; the rest of call_method sees an
                // ordinary call.
                // Only for callees the inline path below will take (plain
                // bytecode functions): that path reads the adjusted argc; the
                // general path re-derives it from the bytecode.
                if inlineCallsEnabled, let callObj = ctx.funcProtoCallObj,
                   sp - argc - 2 >= spBase,
                   let fnObj = buf[sp - argc - 1].obj, fnObj === callObj,
                   let target = buf[sp - argc - 2].obj,
                   let targetFb = target.fbFast, !targetFb.isGenerator, !targetFb.isAsyncFunc {
                    let calleeSlot = sp - argc - 1
                    let thisSlot = calleeSlot - 1
                    let targetVal = buf[thisSlot]
                    let callFnVal = buf[calleeSlot]
                    if argc >= 1 {
                        buf[thisSlot] = buf[calleeSlot + 1]
                        buf[calleeSlot] = targetVal
                        var i = calleeSlot + 1
                        while i + 1 < sp { buf[i] = buf[i + 1]; i += 1 }
                        sp -= 1
                        argc -= 1
                    } else {
                        buf[thisSlot] = .undefined
                        buf[calleeSlot] = targetVal
                    }
                    callFnVal.freeValue()   // the `call` function value the stack owned
                }
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
                   arrObj.propCount > 0,
                   let shape = arrObj.shape,
                   shape.prop.count > 0,
                   shape.prop[0].atom == JeffJSAtomID.JS_ATOM_length.rawValue
                {
                    let newCount = arrObj.asClass.fastArrayPush(buf[sp - 1])
                    if newCount > 0 {
                        // Update the length property in-place (prop[0] == "length").
                        arrObj.asClass.setPropEntry(at: 0, .value(.newInt32(Int32(newCount))))
                        // Pop arg, funcVal, thisObj; push new length
                        sp -= 3
                        buf[sp] = .newInt32(Int32(newCount)); sp += 1
                        pc += 3
                        continue dispatchLoop
                    }
                }
                // ── General call_method path ────────────────────────────
                // Build args with minimal allocation for common cases
                // Inline fast path: plain bytecode method. Stack layout is
                // [..., this, funcVal, arg0 … arg(argc-1)]; the callee frame
                // starts at the first arg slot and `this` is moved from the
                // stack into the callee frame.
                let cmCalleeSlot = sp - argc - 1
                let cmThisSlot = cmCalleeSlot - 1
                if inlineCallsEnabled, cmThisSlot >= spBase,
                   let cmCallObj = buf[cmCalleeSlot].obj,
                   let cmFastFb = cmCallObj.fbFast, !cmFastFb.isGenerator, !cmFastFb.isAsyncFunc {
                    if rt.inlineStackTop - inlineBase > 10000 {
                        _ = ctx.throwInternalError(message: "Maximum call stack size exceeded")
                        retVal = .exception
                        break dispatchLoop
                    }
                    do { // inline call (expanded; no nested-function capture of hot locals)
                        let e_fastFb = cmFastFb
                        let e_callObj = cmCallObj
                        let e_funcVal = buf[cmCalleeSlot]
                        let e_argc = argc
                        let e_calleeSlot = cmCalleeSlot
                        let e_restoreSp = cmThisSlot
                        let e_thisVal = buf[cmThisSlot]
                        let e_instrSize = 3
                        let argStart = e_calleeSlot + 1
                        rt.inlinePush(InlineCallFrame(
                            pc: pc + e_instrSize, sp: e_restoreSp, spTop: sp,
                            buf: buf, bufCapacity: bufCapacity,
                            varBase: varBase, spBase: spBase,
                            bc: bc, bcLen: bcLen, fb: fb,
                            frame: frame,
                            funcObj: mFuncObj, flags: mFlags, bufOwned: bufOwned))
                        fb = e_fastFb
                        bc = e_fastFb.bcPtrFast ?? e_fastFb.bytecodePtr
                        bcLen = e_fastFb.bytecodeLen
                        // Only functions with closure variables need their varRefs
                        // array (a retain/release pair per assignment otherwise).
                        if e_fastFb.closureVarCount > 0 {
                            varRefs = e_callObj.varRefsFast
                            varRefsLoaded = true
                        } else if varRefsLoaded {
                            varRefs = []
                            varRefsLoaded = false
                        }
                        mFuncObj = e_funcVal
                        mFlags = 0
                        unowned(unsafe) let newFrame: JeffJSStackFrame = rt.acquireFrameU().takeUnretainedValue()
                        newFrame.prevFrame = ctx.currentFrame
                        newFrame.curFunc = e_funcVal
                        if e_fastFb.isArrow, let arrowThis = e_callObj.arrowThisVal {
                            newFrame.thisVal = arrowThis.dupValue()
                        } else if !e_fastFb.isStrictMode && e_thisVal.isNullOrUndefined {
                            // ES §10.2.1.2: sloppy callees see the global object.
                            newFrame.thisVal = ctx.globalObj
                        } else {
                            newFrame.thisVal = e_thisVal
                        }
                        newFrame.argCount = e_argc
                        let newVarCount = Int(e_fastFb.varCount)
                        newFrame.varCount = newVarCount
                        let fbArgCount = Int(e_fastFb.argCount); let newArgSlots = fbArgCount > e_argc ? fbArgCount : e_argc
                        let fbStack = Int(e_fastFb.stackSize); let newStackSlots = (fbStack > 4 ? fbStack : 4) + 32
                        let newTotalSlots = newArgSlots + newVarCount + newStackSlots
                        let newBuf: UnsafeMutablePointer<JeffJSValue>
                        let newBufCap: Int
                        if argStart + newTotalSlots <= bufCapacity {
                            newBuf = buf + argStart
                            newBufCap = bufCapacity - argStart
                            // Args are already in place; pad missing args + locals.
                            // Straight-line stores for the common small counts: the loop
                            // form was turned into a memset_pattern16 call per call.
                            let prefix = newArgSlots + newVarCount
                            let pad = prefix - e_argc
                            if pad > 0 {
                                newBuf[e_argc] = .undefined
                                if pad > 1 { newBuf[e_argc + 1] = .undefined }
                                if pad > 2 { newBuf[e_argc + 2] = .undefined }
                                if pad > 3 {
                                    var i = e_argc + 3
                                    while i < prefix { newBuf[i] = .undefined; i += 1 }
                                }
                            }
                            bufOwned = false
                        } else {
                            (newBuf, newBufCap) = rt.acquireInterpBuf(size: newTotalSlots,
                                                                      initializedPrefix: newArgSlots + newVarCount)
                            for i in 0..<e_argc { newBuf[i] = buf[argStart + i] }
                            bufOwned = true
                        }
                        frame = newFrame
                        ctx.currentFrame = frame
                        frame.spBase = 0
                        buf = newBuf
                        bufCapacity = newBufCap
                        varBase = newArgSlots
                        spBase = newArgSlots + newVarCount
                        sp = spBase
                        // Named function expression self-reference (ES §15.2.4).
                        if e_fastFb.selfRefVarIdx >= 0 {
                            buf[varBase + e_fastFb.selfRefVarIdx] = e_funcVal.dupValue()
                        }
                        frame.buf = buf
                        frame.bufCapacity = bufCapacity
                        frame.bufVarBase = varBase
                        frame.bufSpBase = spBase
                        pc = 0
                    }
                    // Run the callee in the fast trace from its first instruction.
                    if fb.traceLean {
                        let r = executeFastTraceLean(bc: bc, bcLen: bcLen, entryPC: 0, exitPC: bcLen, startPC: pc,
                                                     buf: buf, varBase: varBase, sp: &sp, ctx: ctx, cpool: fb.cpool,
                                                     stackLimit: bufCapacity, icEntries: fb.icEntries)
                        if r == -1 { retVal = .exception; break dispatchLoop }
                        pc = r
                        continue dispatchLoop
                    }
                    if fb.traceEntryEnabled {
                        let fbIdBefore = ObjectIdentifier(fb)
                        var hot = HotState(sp: sp, buf: buf, bufCapacity: bufCapacity, varBase: varBase, spBase: spBase, bc: bc, bcLen: bcLen, fb: fb, frame: frame, funcObj: mFuncObj, flags: mFlags, bufOwned: bufOwned, varRefsLoaded: varRefsLoaded, varRefsRaw: mFuncObj.obj?.varRefsRaw, varRefsRawCount: mFuncObj.obj?.varRefsRawCount ?? 0)
                        let resumePC = executeFastTrace(state: &hot, startPC: pc, ctx: ctx, rt: rt, inlineBase: inlineBase)
                        sp = hot.sp; buf = hot.buf; bufCapacity = hot.bufCapacity; varBase = hot.varBase; spBase = hot.spBase
                        bc = hot.bc; bcLen = hot.bcLen; fb = hot.fb; frame = hot.frame
                        mFuncObj = hot.funcObj; mFlags = hot.flags; bufOwned = hot.bufOwned
                        if fb.closureVarCount > 0 { varRefs = mFuncObj.obj?.varRefsFast ?? []; varRefsLoaded = true } else if varRefsLoaded { varRefs = []; varRefsLoaded = false }
                        // Entry deopt accounting: an early exit still inside this function
                        // means the trace could not run it; stop trying after a while.
                        if hot.opsRun < 16, ObjectIdentifier(fb) == fbIdBefore {
                            fb.traceEntryDeopts &+= 1
                            if fb.traceEntryDeopts >= 100 { fb.traceEntryEnabled = false }
                        }
                        if resumePC == -1 { retVal = .exception; break dispatchLoop }
                        pc = resumePC
                    }
                    continue dispatchLoop
                }
                let cmArgs: [JeffJSValue]
                switch argc {
                case 0:
                    cmArgs = []
                case 1:
                    let a0 = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                    cmArgs = [a0]
                case 2:
                    let a1 = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let a0 = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                    cmArgs = [a0, a1]
                default:
                    var tmp = [JeffJSValue](repeating: .undefined, count: argc)
                    for i in stride(from: argc - 1, through: 0, by: -1) { tmp[i] = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) }
                    cmArgs = tmp
                }
                let cmFuncVal = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let cmThisObj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let cmResult: JeffJSValue
                var cmBytecode = false
                if let cmCallObj = cmFuncVal.obj,
                   case .bytecodeFunc(let cmFbOpt2, _, _) = cmCallObj.payload,
                   let cmFastFb2 = cmFbOpt2, !cmFastFb2.isGenerator, !cmFastFb2.isAsyncFunc {
                    cmResult = JeffJSInterpreter.callInternal(ctx: ctx, funcObj: cmFuncVal,
                                                              thisVal: cmThisObj, args: cmArgs, flags: 0)
                    cmBytecode = true
                } else {
                    cmResult = ctx.callFunction(cmFuncVal, thisVal: cmThisObj, args: cmArgs)
                }
                cmFuncVal.freeValue(); cmThisObj.freeValue()
                if cmBytecode { for a in cmArgs { a.freeValue() } }
                if cmResult.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = cmResult; sp += 1
                pc += 3

            case .tail_call:
                let tcArgc = Int(readU16(bc, pc + 1))
                let tcArgs: [JeffJSValue]
                switch tcArgc {
                case 0:
                    tcArgs = []
                case 1:
                    let a0 = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                    tcArgs = [a0]
                case 2:
                    let a1 = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let a0 = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                    tcArgs = [a0, a1]
                default:
                    var tmp = [JeffJSValue](repeating: .undefined, count: tcArgc)
                    for i in stride(from: tcArgc - 1, through: 0, by: -1) { tmp[i] = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) }
                    tcArgs = tmp
                }
                let tcFuncVal = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let tcBytecode = jeffJS_isPlainBytecodeCallee(tcFuncVal)
                if rt.inlineStackTop == inlineBase {
                    ctx.currentFrame = frame.prevFrame
                    retVal = ctx.callFunction(tcFuncVal, thisVal: .undefined, args: tcArgs)
                    tcFuncVal.freeValue()
                    if tcBytecode { for a in tcArgs { a.freeValue() } }
                    break dispatchLoop
                }
                // Inside an inline frame: `break dispatchLoop` would return from
                // the whole callInternal and abandon the caller's continuation
                // (the bug behind `return f()` inside an inline-called function).
                // Treat as call + inline-return: compute the result, unwind this
                // inline frame, and resume the caller — mirroring return_.
                let tcResult = ctx.callFunction(tcFuncVal, thisVal: .undefined, args: tcArgs)
                tcFuncVal.freeValue()
                if tcBytecode { for a in tcArgs { a.freeValue() } }
                if tcResult.isException { retVal = .exception; break dispatchLoop }
                if frame.hasLiveVarRefs {
                    jeffJS_syncBufToFrame(frame, buf, varBase)
                    for vr in frame.liveVarRefs where !vr.isDetached {
                        vr.value = vr.pvalue.dupValue(); vr.isDetached = true; vr.parentFrame = nil; vr.slot = nil
                    }
                }
                ctx.currentFrame = frame.prevFrame
                rt.releaseFrame(frame)
                if bufOwned { rt.releaseInterpBuf(buf, capacity: bufCapacity) }
                let tcSaved = rt.inlinePop()
                pc = tcSaved.pc; sp = tcSaved.sp
                buf = tcSaved.buf; bufCapacity = tcSaved.bufCapacity
                varBase = tcSaved.varBase; spBase = tcSaved.spBase
                bc = tcSaved.bc; bcLen = tcSaved.bcLen
                fb = tcSaved.fb; frame = tcSaved.frame; if tcSaved.fb.closureVarCount > 0 { varRefs = tcSaved.funcObj.obj?.varRefsFast ?? []; varRefsLoaded = true } else if varRefsLoaded { varRefs = []; varRefsLoaded = false }
                mFuncObj = tcSaved.funcObj; mFlags = tcSaved.flags; bufOwned = tcSaved.bufOwned
                buf[sp] = tcResult; sp += 1
                continue dispatchLoop

            case .tail_call_method:
                let tcmArgc = Int(readU16(bc, pc + 1))
                let tcmArgs: [JeffJSValue]
                switch tcmArgc {
                case 0:
                    tcmArgs = []
                case 1:
                    let a0 = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                    tcmArgs = [a0]
                case 2:
                    let a1 = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let a0 = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                    tcmArgs = [a0, a1]
                default:
                    var tmp = [JeffJSValue](repeating: .undefined, count: tcmArgc)
                    for i in stride(from: tcmArgc - 1, through: 0, by: -1) { tmp[i] = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) }
                    tcmArgs = tmp
                }
                let tcmFuncVal = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let tcmThisObj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let tcmBytecode = jeffJS_isPlainBytecodeCallee(tcmFuncVal)
                if rt.inlineStackTop == inlineBase {
                    ctx.currentFrame = frame.prevFrame
                    retVal = ctx.callFunction(tcmFuncVal, thisVal: tcmThisObj, args: tcmArgs)
                    tcmFuncVal.freeValue(); tcmThisObj.freeValue()
                    if tcmBytecode { for a in tcmArgs { a.freeValue() } }
                    break dispatchLoop
                }
                // Inside an inline frame: treat as call + inline-return (see
                // tail_call above for why `break dispatchLoop` is wrong here).
                let tcmResult = ctx.callFunction(tcmFuncVal, thisVal: tcmThisObj, args: tcmArgs)
                tcmFuncVal.freeValue(); tcmThisObj.freeValue()
                if tcmBytecode { for a in tcmArgs { a.freeValue() } }
                if tcmResult.isException { retVal = .exception; break dispatchLoop }
                if frame.hasLiveVarRefs {
                    jeffJS_syncBufToFrame(frame, buf, varBase)
                    for vr in frame.liveVarRefs where !vr.isDetached {
                        vr.value = vr.pvalue.dupValue(); vr.isDetached = true; vr.parentFrame = nil; vr.slot = nil
                    }
                }
                ctx.currentFrame = frame.prevFrame
                rt.releaseFrame(frame)
                if bufOwned { rt.releaseInterpBuf(buf, capacity: bufCapacity) }
                let tcmSaved = rt.inlinePop()
                pc = tcmSaved.pc; sp = tcmSaved.sp
                buf = tcmSaved.buf; bufCapacity = tcmSaved.bufCapacity
                varBase = tcmSaved.varBase; spBase = tcmSaved.spBase
                bc = tcmSaved.bc; bcLen = tcmSaved.bcLen
                fb = tcmSaved.fb; frame = tcmSaved.frame; if tcmSaved.fb.closureVarCount > 0 { varRefs = tcmSaved.funcObj.obj?.varRefsFast ?? []; varRefsLoaded = true } else if varRefsLoaded { varRefs = []; varRefsLoaded = false }
                mFuncObj = tcmSaved.funcObj; mFlags = tcmSaved.flags; bufOwned = tcmSaved.bufOwned
                buf[sp] = tcmResult; sp += 1
                continue dispatchLoop

            case .call_constructor:
                ctx.lastGetFieldAtom = 0
                let argc = Int(readU16(bc, pc + 1))
                var callArgs = [JeffJSValue](repeating: .undefined, count: argc)
                for i in stride(from: argc - 1, through: 0, by: -1) { callArgs[i] = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) }
                let newTarget = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let funcVal = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let ctorBytecode = jeffJS_isPlainBytecodeCallee(funcVal)
                let result = ctx.callConstructor(funcVal, newTarget: newTarget, args: callArgs)
                funcVal.freeValue(); newTarget.freeValue()
                if ctorBytecode { for a in callArgs { a.freeValue() } }
                if result.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = result; sp += 1
                pc += 3

            case .array_from:
                let count = Int(readU16(bc, pc + 1))
                var items = [JeffJSValue]()
                for _ in 0..<count { sp -= 1; items.insert(buf[sp], at: 0) }
                // The parser emits an orphaned OP_object before every
                // array literal.  Pop it so the stack stays balanced.
                // Only pop if it looks like the parser's empty sentinel
                // (a plain object with no properties).
                if sp > 0 {
                    let below = buf[sp - 1]
                    if below.isObject, let obj = below.toObject(),
                       obj.classID == JeffJSClassID.object.rawValue,
                       obj.propValues.isEmpty {
                        jeffJS_pop(buf, &sp, spBase, ctx, fb, pc).freeValue()   // the sentinel object
                    }
                }
                let arr = ctx.newArrayFrom(items)   // takes the popped references
                buf[sp] = arr; sp += 1
                pc += 3

            case .apply:
                let _ = readU16(bc, pc + 1)
                let argsArray = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let funcVal = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let thisObj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let callArgs = ctx.arrayToArgs(argsArray)   // owned copies
                let applyBytecode = jeffJS_isPlainBytecodeCallee(funcVal)
                let result = ctx.callFunction(funcVal, thisVal: thisObj, args: callArgs)
                argsArray.freeValue(); funcVal.freeValue(); thisObj.freeValue()
                if applyBytecode { for a in callArgs { a.freeValue() } }
                if result.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = result; sp += 1
                pc += 3

            case .apply_constructor:
                let _ = readU16(bc, pc + 1)
                let argsArray = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let newTarget = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let funcVal = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let callArgs = ctx.arrayToArgs(argsArray)   // owned copies
                let applyCtorBytecode = jeffJS_isPlainBytecodeCallee(funcVal)
                let result = ctx.callConstructor(funcVal, newTarget: newTarget, args: callArgs)
                argsArray.freeValue(); funcVal.freeValue(); newTarget.freeValue()
                if applyCtorBytecode { for a in callArgs { a.freeValue() } }
                if result.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = result; sp += 1
                pc += 3

            case .return_:
                let returnValue = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if rt.inlineStackTop != inlineBase {
                    // ── Inline return: restore caller's frame ──
                    // 1. Sync buf → frame and detach live var-refs
                    if frame.hasLiveVarRefs {
                        jeffJS_syncBufToFrame(frame, buf, varBase)
                        for vr in frame.liveVarRefs where !vr.isDetached {
                            // pvalue prefers frame.buf, which holds padded arg
                            // slots that argBuf (un-padded) does not.
                            vr.value = vr.pvalue.dupValue()
                            vr.isDetached = true
                            vr.parentFrame = nil; vr.slot = nil
                        }
                    }
                    // 2. Restore previous frame pointer and release callee frame
                    // 1b. Release the callee's variable slots; the caller's
                    // func/this/args slots are released after the pop.
                    do { var i = varBase; let n = spBase; while i < n { buf[i].freeValueFast(); i += 1 } }
                    ctx.currentFrame = frame.prevFrame
                    rt.releaseFrame(frame)
                    // 2b. Release callee's buf to pool
                    if bufOwned { rt.releaseInterpBuf(buf, capacity: bufCapacity) }
                    // 3. Pop saved caller state
                    let saved = rt.inlinePop()
                    do { var p = saved.sp; let e = saved.spTop; while p < e { saved.buf[p].freeValueFast(); p += 1 } }
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
                    if saved.fb.closureVarCount > 0 { varRefs = saved.funcObj.obj?.varRefsFast ?? []; varRefsLoaded = true } else if varRefsLoaded { varRefs = []; varRefsLoaded = false }
                    mFuncObj = saved.funcObj
                    mFlags = saved.flags; bufOwned = saved.bufOwned
                    // 4. Push return value onto caller's stack
                    buf[sp] = returnValue; sp += 1
                    continue dispatchLoop
                } else {
                    retVal = returnValue
                    break dispatchLoop
                }

            case .return_undef:
                if rt.inlineStackTop != inlineBase {
                    // ── Inline return undefined: restore caller's frame ──
                    if frame.hasLiveVarRefs {
                        jeffJS_syncBufToFrame(frame, buf, varBase)
                        for vr in frame.liveVarRefs where !vr.isDetached {
                            // pvalue prefers frame.buf, which holds padded arg
                            // slots that argBuf (un-padded) does not.
                            vr.value = vr.pvalue.dupValue()
                            vr.isDetached = true
                            vr.parentFrame = nil; vr.slot = nil
                        }
                    }
                    do { var i = varBase; let n = spBase; while i < n { buf[i].freeValueFast(); i += 1 } }
                    ctx.currentFrame = frame.prevFrame
                    rt.releaseFrame(frame)
                    if bufOwned { rt.releaseInterpBuf(buf, capacity: bufCapacity) }
                    let saved = rt.inlinePop()
                    do { var p = saved.sp; let e = saved.spTop; while p < e { saved.buf[p].freeValueFast(); p += 1 } }
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
                    if saved.fb.closureVarCount > 0 { varRefs = saved.funcObj.obj?.varRefsFast ?? []; varRefsLoaded = true } else if varRefsLoaded { varRefs = []; varRefsLoaded = false }
                    mFuncObj = saved.funcObj
                    mFlags = saved.flags; bufOwned = saved.bufOwned
                    buf[sp] = .undefined; sp += 1
                    continue dispatchLoop
                } else {
                    retVal = .undefined
                    break dispatchLoop
                }

            case .check_ctor_return:
                let val = buf[sp - 1]
                if val.isObject {
                    buf[sp] = .newBool(true); sp += 1
                } else if val.isUndefined {
                    buf[sp] = .newBool(false); sp += 1
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
                let ctorFunc = buf[sp - 1] // the constructor function is on the stack
                let protoVal = ctx.getProperty(obj: ctorFunc,
                                                atom: JeffJSAtomID.JS_ATOM_prototype.rawValue)
                let newObj: JeffJSValue
                if protoVal.isObject {
                    newObj = ctx.newObjectProto(proto: protoVal)
                } else {
                    // If .prototype is not an object, use the default Object.prototype
                    newObj = ctx.newObject()
                }
                buf[sp] = newObj; sp += 1
                pc += 1

            case .check_brand:
                let brand = buf[sp - 1]
                let obj = buf[sp - 2]
                if !ctx.checkBrand(obj: obj, brand: brand) {
                    _ = ctx.throwTypeError(message: "private member access denied")
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 1

            case .add_brand:
                let brand = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let obj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                ctx.addBrand(obj: obj, brand: brand)
                pc += 1

            case .return_async:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                // Return the actual value so callFunction can wrap it in
                // Promise.resolve(). Previously this returned .undefined,
                // discarding the async function's return value.
                retVal = val
                break dispatchLoop

            case .throw_:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                ctx.throwValue(val)
                retVal = .exception
                break dispatchLoop

            case .throw_error:
                let atom = readU32(bc, pc + 1)
                let errType = readU8(bc, pc + 5)
                let msg = errType == ThrowErrorType.constAssign.rawValue
                    ? "Assignment to constant variable."
                    : ctx.atomToSwiftString(atom)
                ctx.throwErrorFromType(errType: Int(errType), msg: msg)
                retVal = .exception
                break dispatchLoop

            case .eval:
                let argc = Int(readU16(bc, pc + 1))
                let scope = Int(readU16(bc, pc + 3))
                var evalArgs = [JeffJSValue]()
                for _ in 0..<argc { sp -= 1; evalArgs.insert(buf[sp], at: 0) }
                let result = ctx.evalDirect(args: evalArgs, scope: scope, frame: frame)
                if result.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = result; sp += 1
                pc += 5

            case .apply_eval:
                let argc = Int(readU16(bc, pc + 1))
                var evalArgs = [JeffJSValue]()
                for _ in 0..<argc { sp -= 1; evalArgs.insert(buf[sp], at: 0) }
                let result = ctx.evalDirect(args: evalArgs, scope: 0, frame: frame)
                if result.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = result; sp += 1
                pc += 3

            case .regexp:
                let flagsVal = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let patternVal = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let result = ctx.newRegExp(pattern: patternVal, flags: flagsVal)
                if result.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = result; sp += 1
                pc += 1

            case .get_super:
                // Get the super (parent) constructor.
                // Pop a value from the stack to keep the nPop=1 balance,
                // but always resolve the parent constructor from
                // frame.curFunc.__proto__ (the class inheritance chain).
                let _ = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)   // discard the dummy value
                let result = ctx.getSuperConstructor(obj: frame.curFunc)
                if result.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = result; sp += 1
                pc += 1

            case .import_:
                let _ = readU8(bc, pc + 1)
                let specifier = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let result = ctx.dynamicImport(specifier: specifier)
                if result.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = result; sp += 1
                pc += 2

            // -----------------------------------------------------------------
            // Global/scoped Variable Access
            // -----------------------------------------------------------------

            case .check_var:
                let atom = readU32(bc, pc + 1)
                let exists = ctx.checkGlobalVar(atom: atom)
                buf[sp] = .newBool(exists); sp += 1
                pc += 5

            case .get_var_undef:
                let atom = readU32(bc, pc + 1)
                let val = ctx.getGlobalVar(atom: atom, throwRefError: false)
                buf[sp] = val; sp += 1
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
                // Global-var inline cache: top-level `var`s are properties of the
                // global object, so a shape-matched (shape, slot) pair turns a
                // hash lookup per read into a direct slot load.
                if let gObj = ctx.globalObj.obj, let gShape = gObj.shape, let ic = fb.ic {
                    let entry = ic.lookup(pc)
                    if entry.pc == pc,
                       entry.shapePtr == UnsafeRawPointer(Unmanaged.passUnretained(gShape).toOpaque()),
                       entry.propOffset >= 0, entry.propOffset < gObj.propCount,
                       gObj.extra(at: entry.propOffset) == nil {
                        buf[sp] = gObj.dataValue(at: entry.propOffset).dupValue(); sp += 1
                        pc += 5
                        continue dispatchLoop
                    }
                }
                let val = ctx.getGlobalVar(atom: atom, throwRefError: !nextIsTypeof)
                if val.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = val; sp += 1
                // Cache plain data slots for the next read
                if let gObj = ctx.globalObj.obj, let gShape = gObj.shape {
                    if let idx = findShapeProperty(gShape, atom), idx < gObj.propCount,
                       !gShape.prop[idx].flags.contains(.getset),
                       gShape.prop[idx].flags.contains(.writable) {
                        fb.getIC().update(pc, shape: gShape, propOffset: idx)
                    }
                }
                pc += 5

            case .put_var:
                let atom = readU32(bc, pc + 1)
                // Chained assignment: if next opcode is also a store, keep value on stack
                let chainedPutVar = isStoreOpcode(bc, pc + 5, bcLen)
                let val: JeffJSValue
                if chainedPutVar { val = buf[sp - 1].dupValue() } else { val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) }
                // Global-var inline cache: shape-matched writable data slot
                if let gObj = ctx.globalObj.obj, let gShape = gObj.shape, let ic = fb.ic {
                    let entry = ic.lookup(pc)
                    if entry.pc == pc,
                       entry.shapePtr == UnsafeRawPointer(Unmanaged.passUnretained(gShape).toOpaque()),
                       entry.propOffset >= 0, entry.propOffset < gObj.propCount,
                       entry.propOffset < gShape.prop.count,
                       gShape.prop[entry.propOffset].flags.contains(.writable),
                       !gShape.prop[entry.propOffset].flags.contains(.getset),
                       gObj.extra(at: entry.propOffset) == nil {
                        let old = gObj.dataValue(at: entry.propOffset)
                        gObj.asClass.propValues[entry.propOffset] = val
                        old.freeValue()
                        pc += 5
                        continue dispatchLoop
                    }
                }
                let ok = ctx.putGlobalVar(atom: atom, val: val, flags: 0)
                if !ok {
                    retVal = .exception
                    break dispatchLoop
                }
                if let gObj = ctx.globalObj.obj, let gShape = gObj.shape {
                    if let idx = findShapeProperty(gShape, atom), idx < gObj.propCount,
                       !gShape.prop[idx].flags.contains(.getset),
                       gShape.prop[idx].flags.contains(.writable) {
                        fb.getIC().update(pc, shape: gShape, propOffset: idx)
                    }
                }
                pc += 5

            case .put_var_init:
                let atom = readU32(bc, pc + 1)
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let ok = ctx.putGlobalVar(atom: atom, val: val, flags: JS_PROP_CONFIGURABLE)
                if !ok {
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 5

            case .put_var_strict:
                let atom = readU32(bc, pc + 1)
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let _ = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) // ref object (unused in global mode)
                let ok = ctx.putGlobalVar(atom: atom, val: val, flags: JS_PROP_HAS_VALUE | JS_PROP_THROW)
                if !ok {
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 5

            case .get_ref_value:
                let prop = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let obj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let val = ctx.getPropertyValue(obj: obj, prop: prop)
                if val.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = obj; sp += 1
                buf[sp] = prop; sp += 1
                buf[sp] = val; sp += 1
                pc += 1

            case .put_ref_value:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let prop = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let obj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
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
                let funcVal = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
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
                ctx.prevGetFieldAtom = ctx.lastGetFieldAtom
                ctx.lastGetFieldAtom = atom
                let obj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                // The popped receiver owns one reference (from the get_var/get_loc
                // that pushed it). It is disposed of exactly once at each exit below:
                //  • a plain call directly follows — `call`/`call0…3` read the receiver
                //    as `this` when pc == lastGetFieldPC + 5 (the transformMethodCalls
                //    fallback for method calls it couldn't fuse into call_method):
                //    MOVE the ref into the stash; the call consumes it.
                //  • otherwise (the common plain property read): FREE it.
                // Previously every get_field unconditionally stashed (a receiver
                // dup + free on EVERY read) and leaked the popped ref. Gating on an
                // actually-following call removes that churn from hot read loops and
                // balances the reference.
                let nextIsCall = (pc + 5) < bcLen && isCallOpcodeByte(bc[pc + 5])
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
                if let jsObj = obj.obj, jsObj.shapeIdentity != nil {
                    if let ents = fb.icEntries {
                        let entry = ents[pc & JeffJSInlineCache.mask]
                        var icHit: JeffJSValue? = nil
                        if entry.pc == pc, entry.shapePtr == jsObj.shapeIdentity {
                            if entry.holderPtr != nil {
                                icHit = jeffJS_icProtoHit(entry)     // prototype method/field
                            } else if entry.propOffset >= 0, entry.propOffset < jsObj.propCount,
                                      jsObj.extra(at: entry.propOffset) == nil {
                                icHit = jsObj.dataValue(at: entry.propOffset)
                            }
                        }
                        if let hv = icHit {
                            do {
                                buf[sp] = hv.dupValue(); sp += 1
                                if nextIsCall {
                                    frame.lastGetFieldReceiver.freeValue()
                                    frame.lastGetFieldReceiver = obj   // move popped ref into stash
                                    frame.lastGetFieldPC = pc
                                } else {
                                    obj.freeValue()
                                }
                                pc += 5
                                continue dispatchLoop
                            }
                        }
                    }
                    // IC miss: full lookup + cache update
                    let val = ctx.getProperty(obj: obj, atom: atom)
                    if val.isException { obj.freeValue(); retVal = .exception; break dispatchLoop }
                    buf[sp] = val; sp += 1
                    if let shape = jsObj.shape {
                        if let propIdx = findShapeProperty(shape, atom) {
                            fb.getIC().update(pc, shape: shape, propOffset: propIdx)
                        } else if let holder = jsObj.proto, let hs = holder.shape,
                                  let hIdx = findShapeProperty(hs, atom),
                                  hIdx < holder.propValues.count, holder.extra(at: hIdx) == nil {
                            fb.getIC().updateProto(pc, receiverShape: shape, holder: holder,
                                                   holderShape: hs, propOffset: hIdx)
                        }
                    }
                    if nextIsCall {
                        frame.lastGetFieldReceiver.freeValue()
                        frame.lastGetFieldReceiver = obj   // move popped ref into stash
                        frame.lastGetFieldPC = pc
                    } else {
                        obj.freeValue()
                    }
                } else {
                    let val = ctx.getProperty(obj: obj, atom: atom)
                    if val.isException { obj.freeValue(); retVal = .exception; break dispatchLoop }
                    buf[sp] = val; sp += 1
                    if nextIsCall {
                        frame.lastGetFieldReceiver.freeValue()
                        frame.lastGetFieldReceiver = obj   // move popped ref into stash
                        frame.lastGetFieldPC = pc
                    } else {
                        obj.freeValue()
                    }
                }
                pc += 5

            case .get_field2:
                let atom = readU32(bc, pc + 1)
                let obj = buf[sp - 1]
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
                        var argOwned = false   // get_var yields an owned value; locals are peeked
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
                                argOwned = true
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
                                if jsObj.propCount > 0,
                                   let shape = jsObj.shape,
                                   shape.prop.count > 0,
                                   shape.prop[0].atom == JeffJSAtomID.JS_ATOM_length.rawValue {
                                    let newCount = jsObj.asClass.fastArrayPush(argOwned ? arg : arg.dupValue())
                                    if newCount > 0 {
                                        jsObj.asClass.setPropEntry(at: 0, .value(.newInt32(Int32(newCount))))
                                        // Pop the array (from peek) and push the new length
                                        jeffJS_pop(buf, &sp, spBase, ctx, fb, pc).freeValue()   // the array ref
                                        buf[sp] = .newInt32(Int32(newCount)); sp += 1
                                        pc = cmPc + 3  // skip past call_method(1)
                                        continue dispatchLoop
                                    }
                                }
                            }
                        }
                    }
                    // Fallback: just resolve push function quickly
                    let pushVal = JeffJSValue.makeObject(ctx.arrayProtoPushObj!)
                    buf[sp] = pushVal.dupValue(); sp += 1
                    pc += 5
                    continue dispatchLoop
                }
                // Inline cache fast path
                if let jsObj = obj.obj, jsObj.shapeIdentity != nil {
                    if let ents = fb.icEntries {
                        let entry = ents[pc & JeffJSInlineCache.mask]
                        var icHit: JeffJSValue? = nil
                        if entry.pc == pc, entry.shapePtr == jsObj.shapeIdentity {
                            if entry.holderPtr != nil {
                                icHit = jeffJS_icProtoHit(entry)     // prototype method/field
                            } else if entry.propOffset >= 0, entry.propOffset < jsObj.propCount,
                                      jsObj.extra(at: entry.propOffset) == nil {
                                icHit = jsObj.dataValue(at: entry.propOffset)
                            }
                        }
                        if let hv = icHit {
                            do {
                                buf[sp] = hv.dupValue(); sp += 1
                                pc += 5
                                continue dispatchLoop
                            }
                        }
                    }
                    // IC miss: full lookup + cache update
                    let val = ctx.getProperty(obj: obj, atom: atom)
                    if val.isException { retVal = .exception; break dispatchLoop }
                    buf[sp] = val; sp += 1
                    if let shape = jsObj.shape {
                        if let propIdx = findShapeProperty(shape, atom) {
                            fb.getIC().update(pc, shape: shape, propOffset: propIdx)
                        } else if let holder = jsObj.proto, let hs = holder.shape,
                                  let hIdx = findShapeProperty(hs, atom),
                                  hIdx < holder.propValues.count, holder.extra(at: hIdx) == nil {
                            fb.getIC().updateProto(pc, receiverShape: shape, holder: holder,
                                                   holderShape: hs, propOffset: hIdx)
                        }
                    }
                } else {
                    let val = ctx.getProperty(obj: obj, atom: atom)
                    if val.isException { retVal = .exception; break dispatchLoop }
                    buf[sp] = val; sp += 1
                }
                pc += 5

            case .put_field:
                let atom = readU32(bc, pc + 1)
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let obj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                // Inline cache fast path: shape-matched direct property write
                if let jsObj = obj.obj, jsObj.shapeIdentity != nil {
                    if let ents = fb.icEntries {
                        let entry = ents[pc & JeffJSInlineCache.mask]
                        if entry.pc == pc,
                           entry.shapePtr == jsObj.shapeIdentity,
                           entry.propOffset >= 0, entry.propOffset < jsObj.propCount {
                            // `writable` is cached in the entry: flag changes now copy
                            // the shape (prepareShapeUpdate), so identity covers it.
                            if jeffJS_icWrite(jsObj._ptr, entry, val) {
                                obj.freeValue()   // the popped receiver ref (QuickJS: JS_FreeValue(sp[-2]))
                                pc += 5
                                continue dispatchLoop
                            }
                        }
                    }
                    // IC miss: full path + cache update (sloppy writes to
                    // non-writable/frozen targets fail silently per spec)
                    let ok = ctx.setPropertyChecked(obj: obj, atom: atom, value: val,
                                                    strict: fb.isStrictMode)
                    if ok < 0 { obj.freeValue(); retVal = .exception; break dispatchLoop }
                    // Re-read shape after setProperty — it may have transitioned.
                    // Never cache `arr.length = n`: the slot write would skip
                    // the element truncation in setPropertyInternal.
                    if let curShape = jsObj.shape,
                       let propIdx = findShapeProperty(curShape, atom),
                       !(jsObj.classID == JeffJSClassID.array.rawValue && atom == JeffJSAtomID.JS_ATOM_length.rawValue) {
                        fb.getIC().update(pc, shape: curShape, propOffset: propIdx)
                    }
                    obj.freeValue()   // the popped receiver ref (every `this.x = v` that adds a property lands here)
                } else {
                    let ok = ctx.setPropertyChecked(obj: obj, atom: atom, value: val,
                                                    strict: fb.isStrictMode)
                    obj.freeValue()
                    if ok < 0 { retVal = .exception; break dispatchLoop }
                }
                pc += 5

            case .get_private_field:
                let field = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let obj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let val = ctx.getPrivateField(obj: obj, field: field)
                if val.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = val; sp += 1
                pc += 1

            case .put_private_field:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let field = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let obj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let ok = ctx.putPrivateField(obj: obj, field: field, val: val)
                if !ok {
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 1

            case .define_private_field:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let field = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let obj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                ctx.definePrivateField(obj: obj, field: field, val: val)
                pc += 1

            // -----------------------------------------------------------------
            // Array Element Access
            // -----------------------------------------------------------------

            case .get_array_el:
                let key = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let obj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                // Dense-array int-index fast path: skip the atom round-trip
                // (newAtomUInt32 + getPropertyInternal + freeAtom) per element.
                if key.isInt, let jsObj = obj.obj,
                   jsObj.classID == JeffJSClassID.array.rawValue {
                    let idx = key.toInt32()
                    if idx >= 0 {
                        let uidx = UInt32(idx)
                        if let storage = jsObj._fastArrayValues {
                            if uidx < storage.count, Int(uidx) < storage.values.count {
                                buf[sp] = storage.values[Int(uidx)].dupValue(); sp += 1
                                obj.freeValue()   // popped receiver
                                pc += 1
                                continue dispatchLoop
                            }
                        } else if case .array(_, let vals, let count) = jsObj.payload {
                            if uidx < count, Int(uidx) < vals.count {
                                buf[sp] = vals[Int(uidx)].dupValue(); sp += 1
                                obj.freeValue()
                                pc += 1
                                continue dispatchLoop
                            }
                        }
                    }
                }
                let val = ctx.getPropertyValue(obj: obj, prop: key)
                obj.freeValue(); key.freeValue()   // getPropertyValue borrows both
                if val.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = val; sp += 1
                pc += 1

            case .get_array_el2:
                let key = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let obj = buf[sp - 1]
                if key.isInt, let jsObj = obj.obj,
                   jsObj.classID == JeffJSClassID.array.rawValue {
                    let idx = key.toInt32()
                    if idx >= 0 {
                        let uidx = UInt32(idx)
                        if let storage = jsObj._fastArrayValues {
                            if uidx < storage.count, Int(uidx) < storage.values.count {
                                buf[sp] = storage.values[Int(uidx)].dupValue(); sp += 1
                                pc += 1
                                continue dispatchLoop
                            }
                        } else if case .array(_, let vals, let count) = jsObj.payload {
                            if uidx < count, Int(uidx) < vals.count {
                                buf[sp] = vals[Int(uidx)].dupValue(); sp += 1
                                pc += 1
                                continue dispatchLoop
                            }
                        }
                    }
                }
                let val = ctx.getPropertyValue(obj: obj, prop: key)
                key.freeValue()
                if val.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = val; sp += 1
                pc += 1

            case .put_array_el:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let key = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let obj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                // Dense-array in-bounds overwrite fast path. Growth, holes and
                // length updates take the full setPropertyValue path.
                if key.isInt, let jsObj = obj.obj,
                   jsObj.classID == JeffJSClassID.array.rawValue,
                   let storage = jsObj._fastArrayValues {
                    let idx = key.toInt32()
                    if idx >= 0, UInt32(idx) < storage.count, Int(idx) < storage.values.count {
                        let old = storage.values[Int(idx)]
                        storage.values[Int(idx)] = val
                        old.freeValue()
                        obj.freeValue()   // the popped receiver ref
                        pc += 1
                        continue dispatchLoop
                    }
                }
                let ok = ctx.setPropertyValue(obj: obj, prop: key, val: val)
                obj.freeValue()
                if !ok {
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 1

            // -----------------------------------------------------------------
            // Super Property Access
            // -----------------------------------------------------------------

            case .get_super_value:
                let key = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let obj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let thisObj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let val = ctx.getSuperProperty(thisObj: thisObj, obj: obj, key: key)
                if val.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = val; sp += 1
                pc += 1

            case .put_super_value:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let key = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let obj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let thisObj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
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
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let obj = buf[sp - 1]
                // Transition IC: an object on the same starting shape at this
                // pc moves straight to the cached successor shape and appends
                // its value slot, skipping the own-property lookup, the
                // transition-table search and defineProperty. This is the
                // object-literal fast path (`{a: .., b: ..}`).
                if let jsObj = obj.obj, let ents = fb.icEntries {
                    let entry = ents[pc & JeffJSInlineCache.mask]
                    if entry.pc == pc, jeffJS_icDefine(jsObj._ptr, entry, val, rt) {
                        pc += 5
                        continue dispatchLoop
                    }
                }
                let beforeShape = obj.obj?.shape
                let beforeCount = obj.obj?.propCount ?? -1
                let ok = ctx.defineField(obj: obj, atom: atom, val: val)
                if !ok {
                    retVal = .exception
                    break dispatchLoop
                }
                // Record the transition this define_field just performed.
                if let jsObj = obj.obj, let before = beforeShape, before.isHashed,
                   let after = jsObj.shape, after.isHashed, after !== before,
                   jsObj.propCount == beforeCount + 1, after.propCount == beforeCount + 1,
                   after.prop[after.propCount - 1].atom == atom,
                   jsObj.extra(at: after.propCount - 1) == nil {
                    fb.getIC().updateTransition(pc, from: before, to: after)
                }
                pc += 5

            case .set_name:
                let atom = readU32(bc, pc + 1)
                let val = buf[sp - 1]
                ctx.setFunctionName(val, atom: atom)
                pc += 5

            case .set_name_computed:
                let key = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let val = buf[sp - 1]
                ctx.setFunctionNameComputed(val, key: key)
                pc += 1

            case .set_proto:
                let proto = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let obj = buf[sp - 1]
                let ok = ctx.setPrototypeOf(obj: obj, proto: proto)
                if !ok {
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 1

            case .set_home_object:
                let homeObj = buf[sp - 1]
                let funcVal = buf[sp - 2]
                ctx.setHomeObject(funcVal: funcVal, homeObj: homeObj)
                pc += 1

            case .define_array_el:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let idx = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let obj = buf[sp - 1]
                let nextIdx = ctx.defineArrayElement(obj: obj, idx: idx, val: val)
                buf[sp] = nextIdx; sp += 1
                pc += 1

            case .append:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let obj = buf[sp - 1]
                ctx.appendToArray(obj: obj, val: val)
                pc += 1

            case .copy_data_properties:
                let mask = Int(readU8(bc, pc + 1))
                let excludeList: JeffJSValue
                if mask > 0 { excludeList = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) } else { excludeList = .undefined }
                let source = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let target = buf[sp - 1]
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
                let funcVal = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let obj = buf[sp - 1]
                // [[HomeObject]] for `super.x` inside the method (QuickJS sets it
                // in OP_define_method; class, static, object-literal methods and
                // accessors all come through here).
                ctx.setHomeObject(funcVal: funcVal, homeObj: obj)
                let ok = ctx.defineMethod(obj: obj, atom: atom, funcVal: funcVal,
                                           flags: methodFlags)
                if !ok {
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 6

            case .define_method_computed:
                let methodFlags = Int(readU8(bc, pc + 1))
                let funcVal = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let key = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let obj = buf[sp - 1]
                ctx.setHomeObject(funcVal: funcVal, homeObj: obj)
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
                let heritage = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let ctorFunc = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let (ctor, proto) = ctx.defineClass(atom: atom, flags: classFlags,
                                                      heritage: heritage, ctorFunc: ctorFunc)
                if ctor.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = ctor; sp += 1
                buf[sp] = proto; sp += 1
                pc += 6

            case .define_class_computed:
                // QuickJS: ctor heritage key -> ctor proto key
                // nPop=3, nPush=3: the computed key is preserved on top.
                let classFlags = Int(readU8(bc, pc + 1))
                let key = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let heritage = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let ctorFunc = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let (ctor, proto) = ctx.defineClassComputed(key: key, flags: classFlags,
                                                             heritage: heritage,
                                                             ctorFunc: ctorFunc)
                if ctor.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = ctor; sp += 1
                buf[sp] = proto; sp += 1
                buf[sp] = key; sp += 1
                pc += 2

            // -----------------------------------------------------------------
            // Local Variable Access
            // -----------------------------------------------------------------

            case .get_loc:
                let idx = Int(readU16(bc, pc + 1))
                buf[sp] = buf[varBase + idx].dupValue(); sp += 1
                pc += 3

            case .put_loc:
                let idx = Int(readU16(bc, pc + 1))
                let oldPutLoc = buf[varBase + idx]
                // Chained assignment: if next opcode is also a store, keep value on stack
                if isStoreOpcode(bc, pc + 3, bcLen) {
                    buf[varBase + idx] = buf[sp - 1].dupValue()
                } else {
                    buf[varBase + idx] = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                }
                oldPutLoc.freeValue()
                pc += 3

            case .set_loc:
                let idx = Int(readU16(bc, pc + 1))
                let oldSetLoc = buf[varBase + idx]
                buf[varBase + idx] = buf[sp - 1].dupValue()
                oldSetLoc.freeValue()
                pc += 3

            // Short local access
            case .get_loc8:
                let idx = Int(readU8(bc, pc + 1))
                buf[sp] = buf[varBase + idx].dupValue(); sp += 1
                pc += 2

            case .put_loc8:
                let idx = Int(readU8(bc, pc + 1))
                let oldPutLoc8 = buf[varBase + idx]
                if isStoreOpcode(bc, pc + 2, bcLen) {
                    buf[varBase + idx] = buf[sp - 1].dupValue()
                } else {
                    buf[varBase + idx] = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                }
                oldPutLoc8.freeValue()
                pc += 2

            case .set_loc8:
                let idx = Int(readU8(bc, pc + 1))
                let oldSetLoc8 = buf[varBase + idx]
                buf[varBase + idx] = buf[sp - 1].dupValue()
                oldSetLoc8.freeValue()
                pc += 2

            case .get_loc0: buf[sp] = buf[varBase].dupValue(); sp += 1; pc += 1
            case .get_loc1: buf[sp] = buf[varBase + 1].dupValue(); sp += 1; pc += 1
            case .get_loc2: buf[sp] = buf[varBase + 2].dupValue(); sp += 1; pc += 1
            case .get_loc3: buf[sp] = buf[varBase + 3].dupValue(); sp += 1; pc += 1

            case .put_loc0:
                do { let old = buf[varBase]; if isStoreOpcode(bc, pc + 1, bcLen) { buf[varBase] = buf[sp - 1].dupValue() } else { buf[varBase] = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) }; old.freeValue() }
                pc += 1
            case .put_loc1:
                do { let old = buf[varBase + 1]; if isStoreOpcode(bc, pc + 1, bcLen) { buf[varBase + 1] = buf[sp - 1].dupValue() } else { buf[varBase + 1] = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) }; old.freeValue() }
                pc += 1
            case .put_loc2:
                do { let old = buf[varBase + 2]; if isStoreOpcode(bc, pc + 1, bcLen) { buf[varBase + 2] = buf[sp - 1].dupValue() } else { buf[varBase + 2] = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) }; old.freeValue() }
                pc += 1
            case .put_loc3:
                do { let old = buf[varBase + 3]; if isStoreOpcode(bc, pc + 1, bcLen) { buf[varBase + 3] = buf[sp - 1].dupValue() } else { buf[varBase + 3] = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) }; old.freeValue() }
                pc += 1

            case .set_loc0: do { let old = buf[varBase]; buf[varBase] = buf[sp - 1].dupValue(); old.freeValue() }; pc += 1
            case .set_loc1: do { let old = buf[varBase + 1]; buf[varBase + 1] = buf[sp - 1].dupValue(); old.freeValue() }; pc += 1
            case .set_loc2: do { let old = buf[varBase + 2]; buf[varBase + 2] = buf[sp - 1].dupValue(); old.freeValue() }; pc += 1
            case .set_loc3: do { let old = buf[varBase + 3]; buf[varBase + 3] = buf[sp - 1].dupValue(); old.freeValue() }; pc += 1

            // -----------------------------------------------------------------
            // Argument Access
            // -----------------------------------------------------------------

            case .get_arg:
                let idx = Int(readU16(bc, pc + 1))
                if idx < varBase {
                    buf[sp] = buf[idx].dupValue(); sp += 1
                } else {
                    buf[sp] = .undefined; sp += 1
                }
                pc += 3

            case .put_arg:
                let idx = Int(readU16(bc, pc + 1))
                if isStoreOpcode(bc, pc + 3, bcLen) {
                    let val = buf[sp - 1].dupValue()
                    if idx < varBase { buf[idx] = val }
                } else {
                    let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                    if idx < varBase { buf[idx] = val }
                }
                pc += 3

            case .set_arg:
                let idx = Int(readU16(bc, pc + 1))
                if idx < varBase {
                    buf[idx] = buf[sp - 1].dupValue()
                }
                pc += 3

            case .get_arg0: buf[sp] = varBase > 0 ? buf[0].dupValue() : .undefined; sp += 1; pc += 1
            case .get_arg1: buf[sp] = varBase > 1 ? buf[1].dupValue() : .undefined; sp += 1; pc += 1
            case .get_arg2: buf[sp] = varBase > 2 ? buf[2].dupValue() : .undefined; sp += 1; pc += 1
            case .get_arg3: buf[sp] = varBase > 3 ? buf[3].dupValue() : .undefined; sp += 1; pc += 1

            case .put_arg0:
                if isStoreOpcode(bc, pc + 1, bcLen) {
                    if varBase > 0 { buf[0] = buf[sp - 1].dupValue() }
                } else {
                    if varBase > 0 { buf[0] = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) } else { let _ = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) }
                }
                pc += 1
            case .put_arg1:
                if isStoreOpcode(bc, pc + 1, bcLen) {
                    if varBase > 1 { buf[1] = buf[sp - 1].dupValue() }
                } else {
                    if varBase > 1 { buf[1] = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) } else { let _ = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) }
                }
                pc += 1
            case .put_arg2:
                if isStoreOpcode(bc, pc + 1, bcLen) {
                    if varBase > 2 { buf[2] = buf[sp - 1].dupValue() }
                } else {
                    if varBase > 2 { buf[2] = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) } else { let _ = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) }
                }
                pc += 1
            case .put_arg3:
                if isStoreOpcode(bc, pc + 1, bcLen) {
                    if varBase > 3 { buf[3] = buf[sp - 1].dupValue() }
                } else {
                    if varBase > 3 { buf[3] = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) } else { let _ = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) }
                }
                pc += 1

            case .set_arg0: if varBase > 0 { buf[0] = buf[sp - 1].dupValue() }; pc += 1
            case .set_arg1: if varBase > 1 { buf[1] = buf[sp - 1].dupValue() }; pc += 1
            case .set_arg2: if varBase > 2 { buf[2] = buf[sp - 1].dupValue() }; pc += 1
            case .set_arg3: if varBase > 3 { buf[3] = buf[sp - 1].dupValue() }; pc += 1

            // -----------------------------------------------------------------
            // Closure Variable Access
            // -----------------------------------------------------------------

            case .get_var_ref:
                let idx = Int(readU16(bc, pc + 1))
                if idx < varRefs.count, let vr = varRefs[idx] {
                    let val = vr.isDetached ? vr.value.dupValue() : vr.pvalue.dupValue()
                    if traceOps {
                        print("[VAR_REF] get idx=\(idx) isDetached=\(vr.isDetached) isArg=\(vr.isArg) varIdx=\(vr.varIdx) val.bits=0x\(String(val.bits, radix: 16)) frame=\(vr.parentFrame != nil)")
                    }
                    buf[sp] = val; sp += 1
                } else {
                    if traceOps {
                        print("[VAR_REF] get idx=\(idx) OUT OF RANGE (count=\(varRefs.count))")
                    }
                    buf[sp] = .undefined; sp += 1
                }
                pc += 3

            case .put_var_ref:
                let idx = Int(readU16(bc, pc + 1))
                if isStoreOpcode(bc, pc + 3, bcLen) {
                    let val = buf[sp - 1].dupValue()
                    if idx < varRefs.count, let vr = varRefs[idx] {
                        if vr.isDetached { vr.value = val } else { vr.pvalue = val }
                    }
                } else {
                    let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                    if idx < varRefs.count, let vr = varRefs[idx] {
                        if vr.isDetached { vr.value = val } else { vr.pvalue = val }
                    }
                }
                pc += 3

            case .set_var_ref:
                let idx = Int(readU16(bc, pc + 1))
                if idx < varRefs.count, let vr = varRefs[idx] {
                    let val = buf[sp - 1].dupValue()
                    if vr.isDetached { vr.value = val } else { vr.pvalue = val }
                }
                pc += 3

            case .get_var_ref0:
                if varRefs.count > 0, let vr = varRefs[0] {
                    let val = vr.isDetached ? vr.value.dupValue() : vr.pvalue.dupValue()
                    if traceOps {
                        print("[VAR_REF0] isDetached=\(vr.isDetached) isArg=\(vr.isArg) varIdx=\(vr.varIdx) val.bits=0x\(String(val.bits, radix: 16))/\(val.toInt32()) frame=\(vr.parentFrame != nil)")
                    }
                    buf[sp] = val; sp += 1
                } else {
                    if traceOps { print("[VAR_REF0] empty varRefs") }
                    buf[sp] = .undefined; sp += 1
                }
                pc += 1
            case .get_var_ref1: if varRefs.count > 1, let vr = varRefs[1] { buf[sp] = vr.isDetached ? vr.value.dupValue() : vr.pvalue.dupValue(); sp += 1 } else { buf[sp] = .undefined; sp += 1 }; pc += 1
            case .get_var_ref2: if varRefs.count > 2, let vr = varRefs[2] { buf[sp] = vr.isDetached ? vr.value.dupValue() : vr.pvalue.dupValue(); sp += 1 } else { buf[sp] = .undefined; sp += 1 }; pc += 1
            case .get_var_ref3: if varRefs.count > 3, let vr = varRefs[3] { buf[sp] = vr.isDetached ? vr.value.dupValue() : vr.pvalue.dupValue(); sp += 1 } else { buf[sp] = .undefined; sp += 1 }; pc += 1

            case .put_var_ref0: if varRefs.count > 0, let vr = varRefs[0] { let v = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); if vr.isDetached { vr.value = v } else { vr.pvalue = v } } else { let _ = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) }; pc += 1
            case .put_var_ref1: if varRefs.count > 1, let vr = varRefs[1] { let v = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); if vr.isDetached { vr.value = v } else { vr.pvalue = v } } else { let _ = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) }; pc += 1
            case .put_var_ref2: if varRefs.count > 2, let vr = varRefs[2] { let v = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); if vr.isDetached { vr.value = v } else { vr.pvalue = v } } else { let _ = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) }; pc += 1
            case .put_var_ref3: if varRefs.count > 3, let vr = varRefs[3] { let v = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); if vr.isDetached { vr.value = v } else { vr.pvalue = v } } else { let _ = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) }; pc += 1

            case .set_var_ref0: if varRefs.count > 0, let vr = varRefs[0] { let v = buf[sp - 1].dupValue(); if vr.isDetached { vr.value = v } else { vr.pvalue = v } }; pc += 1
            case .set_var_ref1: if varRefs.count > 1, let vr = varRefs[1] { let v = buf[sp - 1].dupValue(); if vr.isDetached { vr.value = v } else { vr.pvalue = v } }; pc += 1
            case .set_var_ref2: if varRefs.count > 2, let vr = varRefs[2] { let v = buf[sp - 1].dupValue(); if vr.isDetached { vr.value = v } else { vr.pvalue = v } }; pc += 1
            case .set_var_ref3: if varRefs.count > 3, let vr = varRefs[3] { let v = buf[sp - 1].dupValue(); if vr.isDetached { vr.value = v } else { vr.pvalue = v } }; pc += 1

            // -----------------------------------------------------------------
            // TDZ (Temporal Dead Zone) Operations
            // -----------------------------------------------------------------

            case .set_loc_uninitialized:
                // Block re-entry (loop bodies): the previous iteration's
                // binding is released here, like QuickJS's set_value.
                let idx = Int(readU16(bc, pc + 1))
                let oldTDZ = buf[varBase + idx]
                buf[varBase + idx] = .uninitialized
                oldTDZ.freeValue()
                pc += 3

            case .get_loc_check:
                let idx = Int(readU16(bc, pc + 1))
                let val = buf[varBase + idx]
                if val.isUninitialized {
                    _ = ctx.throwReferenceError(message: "Cannot access variable before initialization")
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = val.dupValue(); sp += 1
                pc += 3

            case .put_loc_check:
                let idx = Int(readU16(bc, pc + 1))
                let current = buf[varBase + idx]
                if current.isUninitialized {
                    _ = ctx.throwReferenceError(message: "Cannot access variable before initialization")
                    retVal = .exception
                    break dispatchLoop
                }
                // Const assignment is resolved to throw_error at compile time
                // (resolvedLocalAccess), so no per-store const lookup here.
                buf[varBase + idx] = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                current.freeValue()
                pc += 3

            case .put_loc_check_init:
                let idx = Int(readU16(bc, pc + 1))
                let oldCheckInit = buf[varBase + idx]
                buf[varBase + idx] = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
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
                buf[sp] = val.dupValue(); sp += 1
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
                    buf[sp] = val.dupValue(); sp += 1
                } else {
                    buf[sp] = .undefined; sp += 1
                }
                pc += 3

            case .put_var_ref_check:
                let idx = Int(readU16(bc, pc + 1))
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if idx < varRefs.count, let vr = varRefs[idx] {
                    let current = vr.isDetached ? vr.value : vr.pvalue
                    if current.isUninitialized {
                        _ = ctx.throwReferenceError(message: "Cannot access variable before initialization")
                        retVal = .exception
                        break dispatchLoop
                    }
                    if vr.isDetached { vr.value = val } else { vr.pvalue = val }
                }
                pc += 3

            case .put_var_ref_check_init:
                let idx = Int(readU16(bc, pc + 1))
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if idx < varRefs.count, let vr = varRefs[idx] {
                    if vr.isDetached { vr.value = val } else { vr.pvalue = val }
                }
                pc += 3

            // -----------------------------------------------------------------
            // Closure Operations
            // -----------------------------------------------------------------

            case .close_loc:
                let idx = Int(readU16(bc, pc + 1))
                // closeLexicalVar reads the live slot from frame.buf directly.
                ctx.closeLexicalVar(frame: frame, idx: idx)
                pc += 3

            // -----------------------------------------------------------------
            // Control Flow
            // -----------------------------------------------------------------

            case .if_false:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let offset = readI32(bc, pc + 1)
                let condResult = !jeffJS_fastToBool(val)
                val.freeValue()
                if condResult {
                    pc += 5 + Int(offset)
                    if offset < 0 {
                        ctx.interruptCounter -= 1
                        if ctx.interruptCounter <= 0 {
                            ctx.interruptCounter = JS_INTERRUPT_COUNTER_INIT
                            if ctx.checkInterrupt() { retVal = .exception; break dispatchLoop }
                        }
                    // Trace block dispatch for hot loops
                    if let traceInfo = fb.traceBlocks?[pc] {
                        if traceInfo.isActive {
                            if !traceInfo.hasCalls {
                                let resumePC = executeFastTraceLean(
                                    bc: bc, bcLen: bcLen,
                                    entryPC: traceInfo.entryPC, exitPC: traceInfo.exitPC,
                                    startPC: traceInfo.startPC,
                                    buf: buf, varBase: varBase, sp: &sp, ctx: ctx,
                                    cpool: fb.cpool, stackLimit: bufCapacity, icEntries: fb.icEntries)
                                if resumePC == -1 { retVal = .exception; break dispatchLoop }
                                pc = resumePC
                                continue dispatchLoop
                            }
                                let fbIdBefore = ObjectIdentifier(fb)
                                var hot = HotState(sp: sp, buf: buf, bufCapacity: bufCapacity, varBase: varBase, spBase: spBase, bc: bc, bcLen: bcLen, fb: fb, frame: frame, funcObj: mFuncObj, flags: mFlags, bufOwned: bufOwned, varRefsLoaded: varRefsLoaded, varRefsRaw: mFuncObj.obj?.varRefsRaw, varRefsRawCount: mFuncObj.obj?.varRefsRawCount ?? 0)
                                let resumePC = executeFastTrace(state: &hot, startPC: traceInfo.startPC, ctx: ctx, rt: rt, inlineBase: inlineBase)
                                sp = hot.sp; buf = hot.buf; bufCapacity = hot.bufCapacity; varBase = hot.varBase; spBase = hot.spBase
                                bc = hot.bc; bcLen = hot.bcLen; fb = hot.fb; frame = hot.frame
                                mFuncObj = hot.funcObj; mFlags = hot.flags; bufOwned = hot.bufOwned
                                if fb.closureVarCount > 0 { varRefs = mFuncObj.obj?.varRefsFast ?? []; varRefsLoaded = true } else if varRefsLoaded { varRefs = []; varRefsLoaded = false }
                                if resumePC == -1 { retVal = .exception; break dispatchLoop }
                                if jeffJSTraceDebug, traceInfo.deoptCount < 6 {
                                    FileHandle.standardError.write("[trace] start=\(traceInfo.startPC) resume=\(resumePC) region=[\(traceInfo.entryPC),\(traceInfo.exitPC)) fbChanged=\(ObjectIdentifier(fb) != fbIdBefore) ops=\(hot.opsRun)\n".data(using: .utf8)!)
                                }
                                // A block that keeps deopting (unsupported op in the
                                // body or in a callee) costs a state handoff per
                                // iteration: switch it off after 200 in a row.
                                // Only runs that made little progress count: a trace
                                // that executes most of the body before deopting is
                                // still a net win over the main loop.
                                if hot.opsRun < 16,
                                   ObjectIdentifier(fb) != fbIdBefore
                                    || (resumePC >= traceInfo.entryPC && resumePC < traceInfo.exitPC) {
                                    traceInfo.deoptCount &+= 1
                                    if traceInfo.deoptCount >= 200 { traceInfo.isActive = false; traceInfo.disabled = true }
                                } else {
                                    traceInfo.deoptCount = 0
                                }
                            pc = resumePC
                            continue dispatchLoop
                        } else {
                            traceInfo.hitCount &+= 1
                            if traceInfo.hitCount >= traceHitThreshold, !traceInfo.disabled { traceInfo.isActive = true }
                        }
                    }
                    }
                } else {
                    pc += 5
                }

            case .if_true:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let offset = readI32(bc, pc + 1)
                let condResult2 = jeffJS_fastToBool(val)
                val.freeValue()
                if condResult2 {
                    pc += 5 + Int(offset)
                    if offset < 0 {
                        ctx.interruptCounter -= 1
                        if ctx.interruptCounter <= 0 {
                            ctx.interruptCounter = JS_INTERRUPT_COUNTER_INIT
                            if ctx.checkInterrupt() { retVal = .exception; break dispatchLoop }
                        }
                    // Trace block dispatch for hot loops
                    if let traceInfo = fb.traceBlocks?[pc] {
                        if traceInfo.isActive {
                            if !traceInfo.hasCalls {
                                let resumePC = executeFastTraceLean(
                                    bc: bc, bcLen: bcLen,
                                    entryPC: traceInfo.entryPC, exitPC: traceInfo.exitPC,
                                    startPC: traceInfo.startPC,
                                    buf: buf, varBase: varBase, sp: &sp, ctx: ctx,
                                    cpool: fb.cpool, stackLimit: bufCapacity, icEntries: fb.icEntries)
                                if resumePC == -1 { retVal = .exception; break dispatchLoop }
                                pc = resumePC
                                continue dispatchLoop
                            }
                                let fbIdBefore = ObjectIdentifier(fb)
                                var hot = HotState(sp: sp, buf: buf, bufCapacity: bufCapacity, varBase: varBase, spBase: spBase, bc: bc, bcLen: bcLen, fb: fb, frame: frame, funcObj: mFuncObj, flags: mFlags, bufOwned: bufOwned, varRefsLoaded: varRefsLoaded, varRefsRaw: mFuncObj.obj?.varRefsRaw, varRefsRawCount: mFuncObj.obj?.varRefsRawCount ?? 0)
                                let resumePC = executeFastTrace(state: &hot, startPC: traceInfo.startPC, ctx: ctx, rt: rt, inlineBase: inlineBase)
                                sp = hot.sp; buf = hot.buf; bufCapacity = hot.bufCapacity; varBase = hot.varBase; spBase = hot.spBase
                                bc = hot.bc; bcLen = hot.bcLen; fb = hot.fb; frame = hot.frame
                                mFuncObj = hot.funcObj; mFlags = hot.flags; bufOwned = hot.bufOwned
                                if fb.closureVarCount > 0 { varRefs = mFuncObj.obj?.varRefsFast ?? []; varRefsLoaded = true } else if varRefsLoaded { varRefs = []; varRefsLoaded = false }
                                if resumePC == -1 { retVal = .exception; break dispatchLoop }
                                if jeffJSTraceDebug, traceInfo.deoptCount < 6 {
                                    FileHandle.standardError.write("[trace] start=\(traceInfo.startPC) resume=\(resumePC) region=[\(traceInfo.entryPC),\(traceInfo.exitPC)) fbChanged=\(ObjectIdentifier(fb) != fbIdBefore) ops=\(hot.opsRun)\n".data(using: .utf8)!)
                                }
                                // A block that keeps deopting (unsupported op in the
                                // body or in a callee) costs a state handoff per
                                // iteration: switch it off after 200 in a row.
                                // Only runs that made little progress count: a trace
                                // that executes most of the body before deopting is
                                // still a net win over the main loop.
                                if hot.opsRun < 16,
                                   ObjectIdentifier(fb) != fbIdBefore
                                    || (resumePC >= traceInfo.entryPC && resumePC < traceInfo.exitPC) {
                                    traceInfo.deoptCount &+= 1
                                    if traceInfo.deoptCount >= 200 { traceInfo.isActive = false; traceInfo.disabled = true }
                                } else {
                                    traceInfo.deoptCount = 0
                                }
                            pc = resumePC
                            continue dispatchLoop
                        } else {
                            traceInfo.hitCount &+= 1
                            if traceInfo.hitCount >= traceHitThreshold, !traceInfo.disabled { traceInfo.isActive = true }
                        }
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
                            if !traceInfo.hasCalls {
                                let resumePC = executeFastTraceLean(
                                    bc: bc, bcLen: bcLen,
                                    entryPC: traceInfo.entryPC, exitPC: traceInfo.exitPC,
                                    startPC: traceInfo.startPC,
                                    buf: buf, varBase: varBase, sp: &sp, ctx: ctx,
                                    cpool: fb.cpool, stackLimit: bufCapacity, icEntries: fb.icEntries)
                                if resumePC == -1 { retVal = .exception; break dispatchLoop }
                                pc = resumePC
                                continue dispatchLoop
                            }
                                let fbIdBefore = ObjectIdentifier(fb)
                                var hot = HotState(sp: sp, buf: buf, bufCapacity: bufCapacity, varBase: varBase, spBase: spBase, bc: bc, bcLen: bcLen, fb: fb, frame: frame, funcObj: mFuncObj, flags: mFlags, bufOwned: bufOwned, varRefsLoaded: varRefsLoaded, varRefsRaw: mFuncObj.obj?.varRefsRaw, varRefsRawCount: mFuncObj.obj?.varRefsRawCount ?? 0)
                                let resumePC = executeFastTrace(state: &hot, startPC: traceInfo.startPC, ctx: ctx, rt: rt, inlineBase: inlineBase)
                                sp = hot.sp; buf = hot.buf; bufCapacity = hot.bufCapacity; varBase = hot.varBase; spBase = hot.spBase
                                bc = hot.bc; bcLen = hot.bcLen; fb = hot.fb; frame = hot.frame
                                mFuncObj = hot.funcObj; mFlags = hot.flags; bufOwned = hot.bufOwned
                                if fb.closureVarCount > 0 { varRefs = mFuncObj.obj?.varRefsFast ?? []; varRefsLoaded = true } else if varRefsLoaded { varRefs = []; varRefsLoaded = false }
                                if resumePC == -1 { retVal = .exception; break dispatchLoop }
                                if jeffJSTraceDebug, traceInfo.deoptCount < 6 {
                                    FileHandle.standardError.write("[trace] start=\(traceInfo.startPC) resume=\(resumePC) region=[\(traceInfo.entryPC),\(traceInfo.exitPC)) fbChanged=\(ObjectIdentifier(fb) != fbIdBefore) ops=\(hot.opsRun)\n".data(using: .utf8)!)
                                }
                                // A block that keeps deopting (unsupported op in the
                                // body or in a callee) costs a state handoff per
                                // iteration: switch it off after 200 in a row.
                                // Only runs that made little progress count: a trace
                                // that executes most of the body before deopting is
                                // still a net win over the main loop.
                                if hot.opsRun < 16,
                                   ObjectIdentifier(fb) != fbIdBefore
                                    || (resumePC >= traceInfo.entryPC && resumePC < traceInfo.exitPC) {
                                    traceInfo.deoptCount &+= 1
                                    if traceInfo.deoptCount >= 200 { traceInfo.isActive = false; traceInfo.disabled = true }
                                } else {
                                    traceInfo.deoptCount = 0
                                }
                            pc = resumePC
                            continue dispatchLoop
                        } else {
                            traceInfo.hitCount &+= 1
                            if traceInfo.hitCount >= traceHitThreshold, !traceInfo.disabled { traceInfo.isActive = true }
                        }
                    }
                }
                pc = gotoTarget

            case .if_false8:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let offset = Int(readI8(bc, pc + 1))
                let condResult8f = !jeffJS_fastToBool(val)
                val.freeValue()
                if condResult8f {
                    pc += 2 + offset
                    if offset < 0 {
                        ctx.interruptCounter -= 1
                        if ctx.interruptCounter <= 0 {
                            ctx.interruptCounter = JS_INTERRUPT_COUNTER_INIT
                            if ctx.checkInterrupt() { retVal = .exception; break dispatchLoop }
                        }
                    // Trace block dispatch for hot loops
                    if let traceInfo = fb.traceBlocks?[pc] {
                        if traceInfo.isActive {
                            if !traceInfo.hasCalls {
                                let resumePC = executeFastTraceLean(
                                    bc: bc, bcLen: bcLen,
                                    entryPC: traceInfo.entryPC, exitPC: traceInfo.exitPC,
                                    startPC: traceInfo.startPC,
                                    buf: buf, varBase: varBase, sp: &sp, ctx: ctx,
                                    cpool: fb.cpool, stackLimit: bufCapacity, icEntries: fb.icEntries)
                                if resumePC == -1 { retVal = .exception; break dispatchLoop }
                                pc = resumePC
                                continue dispatchLoop
                            }
                                let fbIdBefore = ObjectIdentifier(fb)
                                var hot = HotState(sp: sp, buf: buf, bufCapacity: bufCapacity, varBase: varBase, spBase: spBase, bc: bc, bcLen: bcLen, fb: fb, frame: frame, funcObj: mFuncObj, flags: mFlags, bufOwned: bufOwned, varRefsLoaded: varRefsLoaded, varRefsRaw: mFuncObj.obj?.varRefsRaw, varRefsRawCount: mFuncObj.obj?.varRefsRawCount ?? 0)
                                let resumePC = executeFastTrace(state: &hot, startPC: traceInfo.startPC, ctx: ctx, rt: rt, inlineBase: inlineBase)
                                sp = hot.sp; buf = hot.buf; bufCapacity = hot.bufCapacity; varBase = hot.varBase; spBase = hot.spBase
                                bc = hot.bc; bcLen = hot.bcLen; fb = hot.fb; frame = hot.frame
                                mFuncObj = hot.funcObj; mFlags = hot.flags; bufOwned = hot.bufOwned
                                if fb.closureVarCount > 0 { varRefs = mFuncObj.obj?.varRefsFast ?? []; varRefsLoaded = true } else if varRefsLoaded { varRefs = []; varRefsLoaded = false }
                                if resumePC == -1 { retVal = .exception; break dispatchLoop }
                                if jeffJSTraceDebug, traceInfo.deoptCount < 6 {
                                    FileHandle.standardError.write("[trace] start=\(traceInfo.startPC) resume=\(resumePC) region=[\(traceInfo.entryPC),\(traceInfo.exitPC)) fbChanged=\(ObjectIdentifier(fb) != fbIdBefore) ops=\(hot.opsRun)\n".data(using: .utf8)!)
                                }
                                // A block that keeps deopting (unsupported op in the
                                // body or in a callee) costs a state handoff per
                                // iteration: switch it off after 200 in a row.
                                // Only runs that made little progress count: a trace
                                // that executes most of the body before deopting is
                                // still a net win over the main loop.
                                if hot.opsRun < 16,
                                   ObjectIdentifier(fb) != fbIdBefore
                                    || (resumePC >= traceInfo.entryPC && resumePC < traceInfo.exitPC) {
                                    traceInfo.deoptCount &+= 1
                                    if traceInfo.deoptCount >= 200 { traceInfo.isActive = false; traceInfo.disabled = true }
                                } else {
                                    traceInfo.deoptCount = 0
                                }
                            pc = resumePC
                            continue dispatchLoop
                        } else {
                            traceInfo.hitCount &+= 1
                            if traceInfo.hitCount >= traceHitThreshold, !traceInfo.disabled { traceInfo.isActive = true }
                        }
                    }
                    }
                } else {
                    pc += 2
                }

            case .cmp_if8, .cmp_if:
                // Fused compare + conditional branch (see fuseCompareBranches).
                let rhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let cbSub = Int(readU8(bc, pc + 1))
                let cbShort = (op == .cmp_if8)
                let cbSize = cbShort ? 3 : 6
                let offset = cbShort ? Int(readI8(bc, pc + 2)) : Int(readI32(bc, pc + 2))
                var cbCond = false
                if lhs.isInt && rhs.isInt {
                    let a = lhs.toInt32(), b = rhs.toInt32()
                    switch cbSub & 7 { case 0: cbCond = a < b; case 1: cbCond = a <= b; case 2: cbCond = a > b; case 3: cbCond = a >= b; case 4, 6: cbCond = a == b; default: cbCond = a != b }
                } else {
                    switch cbSub & 7 {
                    case 0:
                        let (cmp, ok) = JeffJSOperators.jsCompare(ctx: ctx, lhs: lhs, rhs: rhs)
                        lhs.freeValue(); rhs.freeValue()
                        if !ok { retVal = .exception; break dispatchLoop }
                        cbCond = cmp < 0
                    case 1:
                        let (cmp, ok) = JeffJSOperators.jsCompare(ctx: ctx, lhs: rhs, rhs: lhs)
                        lhs.freeValue(); rhs.freeValue()
                        if !ok { retVal = .exception; break dispatchLoop }
                        cbCond = cmp == 0
                    case 2:
                        let (cmp, ok) = JeffJSOperators.jsCompare(ctx: ctx, lhs: rhs, rhs: lhs)
                        lhs.freeValue(); rhs.freeValue()
                        if !ok { retVal = .exception; break dispatchLoop }
                        cbCond = cmp < 0
                    case 3:
                        let (cmp, ok) = JeffJSOperators.jsCompare(ctx: ctx, lhs: lhs, rhs: rhs)
                        lhs.freeValue(); rhs.freeValue()
                        if !ok { retVal = .exception; break dispatchLoop }
                        cbCond = cmp == 0
                    case 4, 5:
                        let (r, ok) = JeffJSOperators.jsEq(ctx: ctx, lhs: lhs, rhs: rhs)
                        lhs.freeValue(); rhs.freeValue()
                        if !ok { retVal = .exception; break dispatchLoop }
                        cbCond = (cbSub & 7) == 4 ? r : !r
                    default:
                        let r = JeffJSOperators.jsStrictEq(lhs: lhs, rhs: rhs)
                        lhs.freeValue(); rhs.freeValue()
                        cbCond = (cbSub & 7) == 6 ? r : !r
                    }
                }
                if cbCond == ((cbSub & 8) != 0) {
                    pc += cbSize + offset
                    if offset < 0 {
                        ctx.interruptCounter -= 1
                        if ctx.interruptCounter <= 0 {
                            ctx.interruptCounter = JS_INTERRUPT_COUNTER_INIT
                            if ctx.checkInterrupt() { retVal = .exception; break dispatchLoop }
                        }
                    // Trace block dispatch for hot loops
                    if let traceInfo = fb.traceBlocks?[pc] {
                        if traceInfo.isActive {
                            if !traceInfo.hasCalls {
                                let resumePC = executeFastTraceLean(
                                    bc: bc, bcLen: bcLen,
                                    entryPC: traceInfo.entryPC, exitPC: traceInfo.exitPC,
                                    startPC: traceInfo.startPC,
                                    buf: buf, varBase: varBase, sp: &sp, ctx: ctx,
                                    cpool: fb.cpool, stackLimit: bufCapacity, icEntries: fb.icEntries)
                                if resumePC == -1 { retVal = .exception; break dispatchLoop }
                                pc = resumePC
                                continue dispatchLoop
                            }
                                let fbIdBefore = ObjectIdentifier(fb)
                                var hot = HotState(sp: sp, buf: buf, bufCapacity: bufCapacity, varBase: varBase, spBase: spBase, bc: bc, bcLen: bcLen, fb: fb, frame: frame, funcObj: mFuncObj, flags: mFlags, bufOwned: bufOwned, varRefsLoaded: varRefsLoaded, varRefsRaw: mFuncObj.obj?.varRefsRaw, varRefsRawCount: mFuncObj.obj?.varRefsRawCount ?? 0)
                                let resumePC = executeFastTrace(state: &hot, startPC: traceInfo.startPC, ctx: ctx, rt: rt, inlineBase: inlineBase)
                                sp = hot.sp; buf = hot.buf; bufCapacity = hot.bufCapacity; varBase = hot.varBase; spBase = hot.spBase
                                bc = hot.bc; bcLen = hot.bcLen; fb = hot.fb; frame = hot.frame
                                mFuncObj = hot.funcObj; mFlags = hot.flags; bufOwned = hot.bufOwned
                                if fb.closureVarCount > 0 { varRefs = mFuncObj.obj?.varRefsFast ?? []; varRefsLoaded = true } else if varRefsLoaded { varRefs = []; varRefsLoaded = false }
                                if resumePC == -1 { retVal = .exception; break dispatchLoop }
                                if jeffJSTraceDebug, traceInfo.deoptCount < 6 {
                                    FileHandle.standardError.write("[trace] start=\(traceInfo.startPC) resume=\(resumePC) region=[\(traceInfo.entryPC),\(traceInfo.exitPC)) fbChanged=\(ObjectIdentifier(fb) != fbIdBefore) ops=\(hot.opsRun)\n".data(using: .utf8)!)
                                }
                                // A block that keeps deopting (unsupported op in the
                                // body or in a callee) costs a state handoff per
                                // iteration: switch it off after 200 in a row.
                                // Only runs that made little progress count: a trace
                                // that executes most of the body before deopting is
                                // still a net win over the main loop.
                                if hot.opsRun < 16,
                                   ObjectIdentifier(fb) != fbIdBefore
                                    || (resumePC >= traceInfo.entryPC && resumePC < traceInfo.exitPC) {
                                    traceInfo.deoptCount &+= 1
                                    if traceInfo.deoptCount >= 200 { traceInfo.isActive = false; traceInfo.disabled = true }
                                } else {
                                    traceInfo.deoptCount = 0
                                }
                            pc = resumePC
                            continue dispatchLoop
                        } else {
                            traceInfo.hitCount &+= 1
                            if traceInfo.hitCount >= traceHitThreshold, !traceInfo.disabled { traceInfo.isActive = true }
                        }
                    }
                    }
                } else {
                    pc += cbSize
                }

            case .if_true8:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let offset = Int(readI8(bc, pc + 1))
                let condResult8t = jeffJS_fastToBool(val)
                val.freeValue()
                if condResult8t {
                    pc += 2 + offset
                    if offset < 0 {
                        ctx.interruptCounter -= 1
                        if ctx.interruptCounter <= 0 {
                            ctx.interruptCounter = JS_INTERRUPT_COUNTER_INIT
                            if ctx.checkInterrupt() { retVal = .exception; break dispatchLoop }
                        }
                    // Trace block dispatch for hot loops
                    if let traceInfo = fb.traceBlocks?[pc] {
                        if traceInfo.isActive {
                            if !traceInfo.hasCalls {
                                let resumePC = executeFastTraceLean(
                                    bc: bc, bcLen: bcLen,
                                    entryPC: traceInfo.entryPC, exitPC: traceInfo.exitPC,
                                    startPC: traceInfo.startPC,
                                    buf: buf, varBase: varBase, sp: &sp, ctx: ctx,
                                    cpool: fb.cpool, stackLimit: bufCapacity, icEntries: fb.icEntries)
                                if resumePC == -1 { retVal = .exception; break dispatchLoop }
                                pc = resumePC
                                continue dispatchLoop
                            }
                                let fbIdBefore = ObjectIdentifier(fb)
                                var hot = HotState(sp: sp, buf: buf, bufCapacity: bufCapacity, varBase: varBase, spBase: spBase, bc: bc, bcLen: bcLen, fb: fb, frame: frame, funcObj: mFuncObj, flags: mFlags, bufOwned: bufOwned, varRefsLoaded: varRefsLoaded, varRefsRaw: mFuncObj.obj?.varRefsRaw, varRefsRawCount: mFuncObj.obj?.varRefsRawCount ?? 0)
                                let resumePC = executeFastTrace(state: &hot, startPC: traceInfo.startPC, ctx: ctx, rt: rt, inlineBase: inlineBase)
                                sp = hot.sp; buf = hot.buf; bufCapacity = hot.bufCapacity; varBase = hot.varBase; spBase = hot.spBase
                                bc = hot.bc; bcLen = hot.bcLen; fb = hot.fb; frame = hot.frame
                                mFuncObj = hot.funcObj; mFlags = hot.flags; bufOwned = hot.bufOwned
                                if fb.closureVarCount > 0 { varRefs = mFuncObj.obj?.varRefsFast ?? []; varRefsLoaded = true } else if varRefsLoaded { varRefs = []; varRefsLoaded = false }
                                if resumePC == -1 { retVal = .exception; break dispatchLoop }
                                if jeffJSTraceDebug, traceInfo.deoptCount < 6 {
                                    FileHandle.standardError.write("[trace] start=\(traceInfo.startPC) resume=\(resumePC) region=[\(traceInfo.entryPC),\(traceInfo.exitPC)) fbChanged=\(ObjectIdentifier(fb) != fbIdBefore) ops=\(hot.opsRun)\n".data(using: .utf8)!)
                                }
                                // A block that keeps deopting (unsupported op in the
                                // body or in a callee) costs a state handoff per
                                // iteration: switch it off after 200 in a row.
                                // Only runs that made little progress count: a trace
                                // that executes most of the body before deopting is
                                // still a net win over the main loop.
                                if hot.opsRun < 16,
                                   ObjectIdentifier(fb) != fbIdBefore
                                    || (resumePC >= traceInfo.entryPC && resumePC < traceInfo.exitPC) {
                                    traceInfo.deoptCount &+= 1
                                    if traceInfo.deoptCount >= 200 { traceInfo.isActive = false; traceInfo.disabled = true }
                                } else {
                                    traceInfo.deoptCount = 0
                                }
                            pc = resumePC
                            continue dispatchLoop
                        } else {
                            traceInfo.hitCount &+= 1
                            if traceInfo.hitCount >= traceHitThreshold, !traceInfo.disabled { traceInfo.isActive = true }
                        }
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
                            if !traceInfo.hasCalls {
                                let resumePC = executeFastTraceLean(
                                    bc: bc, bcLen: bcLen,
                                    entryPC: traceInfo.entryPC, exitPC: traceInfo.exitPC,
                                    startPC: traceInfo.startPC,
                                    buf: buf, varBase: varBase, sp: &sp, ctx: ctx,
                                    cpool: fb.cpool, stackLimit: bufCapacity, icEntries: fb.icEntries)
                                if resumePC == -1 { retVal = .exception; break dispatchLoop }
                                pc = resumePC
                                continue dispatchLoop
                            }
                                let fbIdBefore = ObjectIdentifier(fb)
                                var hot = HotState(sp: sp, buf: buf, bufCapacity: bufCapacity, varBase: varBase, spBase: spBase, bc: bc, bcLen: bcLen, fb: fb, frame: frame, funcObj: mFuncObj, flags: mFlags, bufOwned: bufOwned, varRefsLoaded: varRefsLoaded, varRefsRaw: mFuncObj.obj?.varRefsRaw, varRefsRawCount: mFuncObj.obj?.varRefsRawCount ?? 0)
                                let resumePC = executeFastTrace(state: &hot, startPC: traceInfo.startPC, ctx: ctx, rt: rt, inlineBase: inlineBase)
                                sp = hot.sp; buf = hot.buf; bufCapacity = hot.bufCapacity; varBase = hot.varBase; spBase = hot.spBase
                                bc = hot.bc; bcLen = hot.bcLen; fb = hot.fb; frame = hot.frame
                                mFuncObj = hot.funcObj; mFlags = hot.flags; bufOwned = hot.bufOwned
                                if fb.closureVarCount > 0 { varRefs = mFuncObj.obj?.varRefsFast ?? []; varRefsLoaded = true } else if varRefsLoaded { varRefs = []; varRefsLoaded = false }
                                if resumePC == -1 { retVal = .exception; break dispatchLoop }
                                if jeffJSTraceDebug, traceInfo.deoptCount < 6 {
                                    FileHandle.standardError.write("[trace] start=\(traceInfo.startPC) resume=\(resumePC) region=[\(traceInfo.entryPC),\(traceInfo.exitPC)) fbChanged=\(ObjectIdentifier(fb) != fbIdBefore) ops=\(hot.opsRun)\n".data(using: .utf8)!)
                                }
                                // A block that keeps deopting (unsupported op in the
                                // body or in a callee) costs a state handoff per
                                // iteration: switch it off after 200 in a row.
                                // Only runs that made little progress count: a trace
                                // that executes most of the body before deopting is
                                // still a net win over the main loop.
                                if hot.opsRun < 16,
                                   ObjectIdentifier(fb) != fbIdBefore
                                    || (resumePC >= traceInfo.entryPC && resumePC < traceInfo.exitPC) {
                                    traceInfo.deoptCount &+= 1
                                    if traceInfo.deoptCount >= 200 { traceInfo.isActive = false; traceInfo.disabled = true }
                                } else {
                                    traceInfo.deoptCount = 0
                                }
                            pc = resumePC
                            continue dispatchLoop
                        } else {
                            traceInfo.hitCount &+= 1
                            if traceInfo.hitCount >= traceHitThreshold, !traceInfo.disabled { traceInfo.isActive = true }
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
                            if !traceInfo.hasCalls {
                                let resumePC = executeFastTraceLean(
                                    bc: bc, bcLen: bcLen,
                                    entryPC: traceInfo.entryPC, exitPC: traceInfo.exitPC,
                                    startPC: traceInfo.startPC,
                                    buf: buf, varBase: varBase, sp: &sp, ctx: ctx,
                                    cpool: fb.cpool, stackLimit: bufCapacity, icEntries: fb.icEntries)
                                if resumePC == -1 { retVal = .exception; break dispatchLoop }
                                pc = resumePC
                                continue dispatchLoop
                            }
                                let fbIdBefore = ObjectIdentifier(fb)
                                var hot = HotState(sp: sp, buf: buf, bufCapacity: bufCapacity, varBase: varBase, spBase: spBase, bc: bc, bcLen: bcLen, fb: fb, frame: frame, funcObj: mFuncObj, flags: mFlags, bufOwned: bufOwned, varRefsLoaded: varRefsLoaded, varRefsRaw: mFuncObj.obj?.varRefsRaw, varRefsRawCount: mFuncObj.obj?.varRefsRawCount ?? 0)
                                let resumePC = executeFastTrace(state: &hot, startPC: traceInfo.startPC, ctx: ctx, rt: rt, inlineBase: inlineBase)
                                sp = hot.sp; buf = hot.buf; bufCapacity = hot.bufCapacity; varBase = hot.varBase; spBase = hot.spBase
                                bc = hot.bc; bcLen = hot.bcLen; fb = hot.fb; frame = hot.frame
                                mFuncObj = hot.funcObj; mFlags = hot.flags; bufOwned = hot.bufOwned
                                if fb.closureVarCount > 0 { varRefs = mFuncObj.obj?.varRefsFast ?? []; varRefsLoaded = true } else if varRefsLoaded { varRefs = []; varRefsLoaded = false }
                                if resumePC == -1 { retVal = .exception; break dispatchLoop }
                                if jeffJSTraceDebug, traceInfo.deoptCount < 6 {
                                    FileHandle.standardError.write("[trace] start=\(traceInfo.startPC) resume=\(resumePC) region=[\(traceInfo.entryPC),\(traceInfo.exitPC)) fbChanged=\(ObjectIdentifier(fb) != fbIdBefore) ops=\(hot.opsRun)\n".data(using: .utf8)!)
                                }
                                // A block that keeps deopting (unsupported op in the
                                // body or in a callee) costs a state handoff per
                                // iteration: switch it off after 200 in a row.
                                // Only runs that made little progress count: a trace
                                // that executes most of the body before deopting is
                                // still a net win over the main loop.
                                if hot.opsRun < 16,
                                   ObjectIdentifier(fb) != fbIdBefore
                                    || (resumePC >= traceInfo.entryPC && resumePC < traceInfo.exitPC) {
                                    traceInfo.deoptCount &+= 1
                                    if traceInfo.deoptCount >= 200 { traceInfo.isActive = false; traceInfo.disabled = true }
                                } else {
                                    traceInfo.deoptCount = 0
                                }
                            pc = resumePC
                            continue dispatchLoop
                        } else {
                            traceInfo.hitCount &+= 1
                            if traceInfo.hitCount >= traceHitThreshold, !traceInfo.disabled { traceInfo.isActive = true }
                        }
                    }
                }
                pc = goto16Target

            case .catch_:
                // Push the absolute address of the catch handler onto the value stack.
                // The offset is relative to the end of this 5-byte instruction.
                let offset = readI32(bc, pc + 1)
                let catchAddr = pc + 5 + Int(offset)
                buf[sp] = .newCatchOffset(Int32(catchAddr)); sp += 1
                pc += 5

            case .gosub:
                // Push return address (instruction after gosub) then jump to finally block.
                // The offset is relative to the end of this 5-byte instruction.
                let offset = readI32(bc, pc + 1)
                buf[sp] = .newInt32(Int32(pc + 5)); sp += 1 // return address
                pc += 5 + Int(offset)

            case .ret:
                let addr = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
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
                // QuickJS: catch_offset ... ret_val -> ret_val
                // Keep the top value, free everything below it down to the
                // nearest catch offset, and replace that catch offset with the
                // value (operands left by an enclosing expression, or iterator
                // state, are released here).  When the catch offset itself is
                // on top (normal end of a try body) it is simply popped.
                if sp > spBase && buf[sp - 1].isCatchOffset {
                    sp -= 1
                } else if sp > spBase {
                    let keptVal = buf[sp - 1]
                    sp -= 1
                    while sp > spBase && !buf[sp - 1].isCatchOffset {
                        sp -= 1
                        buf[sp].freeValue()
                    }
                    if sp > spBase {
                        buf[sp - 1] = keptVal   // overwrite the catch offset (no free needed)
                    } else {
                        buf[sp] = keptVal; sp += 1   // no handler on the stack: keep the value
                    }
                }
                pc += 1

            // -----------------------------------------------------------------
            // Type Conversions
            // -----------------------------------------------------------------

            case .to_object:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let obj = ctx.toObject(val)
                val.freeValue()
                if obj.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = obj; sp += 1
                pc += 1

            case .to_propkey:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let key = ctx.toPropertyKey(val)
                val.freeValue()
                if key.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = key; sp += 1
                pc += 1

            case .to_propkey2:
                // QuickJS: val key -> val ToPropertyKey(key)
                // Convert TOS to a property key in-place; leave the value below it untouched.
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let key = ctx.toPropertyKey(val)
                val.freeValue()
                if key.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = key; sp += 1
                pc += 1

            // -----------------------------------------------------------------
            // with Statement Variable Access
            // -----------------------------------------------------------------

            case .make_loc_ref:
                let atom = readU32(bc, pc + 1)
                let idx = Int(readU16(bc, pc + 5))
                let ref = ctx.makeLocalRef(frame: frame, idx: idx)
                buf[sp] = .makeObject(ref); sp += 1
                buf[sp] = ctx.atomToString(atom); sp += 1
                pc += 7

            case .make_arg_ref:
                let atom = readU32(bc, pc + 1)
                let idx = Int(readU16(bc, pc + 5))
                let ref = ctx.makeArgRef(frame: frame, idx: idx)
                buf[sp] = .makeObject(ref); sp += 1
                buf[sp] = ctx.atomToString(atom); sp += 1
                pc += 7

            case .make_var_ref_ref:
                let atom = readU32(bc, pc + 1)
                let idx = Int(readU16(bc, pc + 5))
                if idx < varRefs.count, let vr = varRefs[idx] {
                    buf[sp] = .mkPtr(tag: .object, ptr: vr); sp += 1
                } else {
                    buf[sp] = .undefined; sp += 1
                }
                buf[sp] = ctx.atomToString(atom); sp += 1
                pc += 7

            case .make_var_ref:
                let atom = readU32(bc, pc + 1)
                let ref = ctx.makeGlobalVarRef(atom: atom)
                buf[sp] = ref.0; sp += 1
                buf[sp] = ref.1; sp += 1
                pc += 5

            // -----------------------------------------------------------------
            // Iteration
            // -----------------------------------------------------------------

            case .for_in_start:
                let obj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let iter = ctx.createForInIterator(obj: obj)
                obj.freeValue()
                buf[sp] = iter; sp += 1
                pc += 1

            case .for_of_start:
                // QuickJS: iterable -> iter_obj obj method
                // Pops the iterable, gets its [Symbol.iterator] method, calls it to
                // get the iterator object, then pushes the 3-element iterator state:
                // [iter_obj, obj, method] where method = iter_obj.next
                let obj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let iter = ctx.getIterator(obj: obj, isAsync: false)
                if iter.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                let nextMethod = ctx.getProperty(obj: iter, atom: ctx.iterNextAtom)
                buf[sp] = iter; sp += 1
                buf[sp] = obj; sp += 1
                buf[sp] = nextMethod; sp += 1
                pc += 1

            case .for_await_of_start:
                // QuickJS: iterable -> iter_obj obj method
                // Same as for_of_start but uses [Symbol.asyncIterator].
                let obj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let iter = ctx.getIterator(obj: obj, isAsync: true)
                if iter.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                let nextMethod = ctx.getProperty(obj: iter, atom: ctx.iterNextAtom)
                buf[sp] = iter; sp += 1
                buf[sp] = obj; sp += 1
                buf[sp] = nextMethod; sp += 1
                pc += 1

            case .for_in_next:
                let iter = buf[sp - 1]
                let result = ctx.forInNext(iter: iter)
                if result.0.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = result.0; sp += 1 // value
                buf[sp] = .newBool(result.1); sp += 1 // done
                pc += 1

            case .for_of_next:
                // QuickJS: iter obj method -> iter obj method value done
                // The 3-element iterator state [iter, obj, method] stays on
                // the stack; we peek at it via an offset and push value+done
                // on top.  This matches QuickJS behaviour exactly (peek, not
                // pop/push) and correctly handles non-zero offsets.
                let offset = Int(readU8(bc, pc + 1))
                // Peek at the iterator state without popping
                let method = buf[sp - 1 - (0 + offset)]  // top of iter state
                let iter   = buf[sp - 1 - (2 + offset)]  // bottom of iter state
                // Call method (next) with iter as this.
                if traceOps {
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
                    buf[sp] = forOfResult; sp += 1
                    buf[sp] = .newBool(false); sp += 1
                    pc += 2
                    break // continue dispatch
                }
                // Extract .done and .value from the iterator result
                let forOfDoneVal = ctx.getPropertyStr(obj: forOfResult, name: "done")
                let forOfDone = jeffJS_fastToBool(forOfDoneVal)
                if traceOps {
                    let v = ctx.getPropertyStr(obj: forOfResult, name: "value")
                    print("[FOR-OF] result.isObject=\(forOfResult.isObject) done=\(forOfDone) doneVal.bits=0x\(String(forOfDoneVal.bits, radix: 16)) value=\(ctx.toSwiftString(v) ?? "nil")")
                    if let obj = forOfResult.toObject() {
                        print("[FOR-OF] result props: \(obj.propCount) shape: \(obj.shape?.propCount ?? -1)")
                    }
                }
                if forOfDone {
                    buf[sp] = .undefined; sp += 1
                    buf[sp] = .newBool(true); sp += 1
                } else {
                    let forOfValue = ctx.getPropertyStr(obj: forOfResult, name: "value")
                    buf[sp] = forOfValue; sp += 1
                    buf[sp] = .newBool(false); sp += 1
                }
                forOfDoneVal.freeValue()
                forOfResult.freeValue()   // the {value, done} object from next()
                pc += 2

            case .for_await_of_next:
                // QuickJS: iter obj method -> iter obj method value
                // nPop=3, nPush=4: pops the 3-element iterator state, calls method,
                // pushes back the state plus the raw result (to be awaited).
                // Full async iteration requires coroutine/promise support. For now,
                // we call next() synchronously. If the result is a promise, true
                // async iteration would require awaiting it.
                let method = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let iterObj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let asyncIter = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
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
                buf[sp] = asyncIter; sp += 1
                buf[sp] = iterObj; sp += 1
                buf[sp] = method; sp += 1
                buf[sp] = asyncResult; sp += 1
                pc += 1

            case .iterator_check_object:
                let val = buf[sp - 1]
                if !val.isObject {
                    _ = ctx.throwTypeError(message: "iterator result is not an object")
                    retVal = .exception
                    break dispatchLoop
                }
                pc += 1

            case .iterator_get_value_done:
                let result = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let done = ctx.getProperty(obj: result, atom: JeffJSAtomID.JS_ATOM_done.rawValue)
                let value = ctx.getProperty(obj: result, atom: JeffJSAtomID.JS_ATOM_value.rawValue)
                let isDone = jeffJS_fastToBool(done)
                done.freeValue()
                result.freeValue()   // the popped result object was leaked per step
                buf[sp] = value; sp += 1
                buf[sp] = .newBool(isDone); sp += 1
                pc += 1

            case .iterator_close:
                // QuickJS: iter obj method -> (empty)
                // nPop=3, nPush=0: pops the 3-element iterator state and closes the iterator.
                let icMethod = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)   // method
                let icObj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)      // obj
                let iter = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) // iter
                ctx.iteratorClose(iter: iter, isThrow: false)
                icMethod.freeValue(); icObj.freeValue(); iter.freeValue()
                pc += 1

            case .iterator_close_return:
                // QuickJS: ret_val iter obj method -> ret_val
                // nPop=4, nPush=1: pops the 3-element iterator state plus the
                // return value below, closes the iterator, then pushes the
                // return value back.
                let _ = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)   // method
                let _ = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)   // obj
                let iter = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) // iter
                let retValue = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) // return value that was below the iterator state
                ctx.iteratorClose(iter: iter, isThrow: false)
                buf[sp] = retValue; sp += 1
                pc += 1

            case .iterator_next:
                // QuickJS: val iter obj method -> result iter obj method
                // nPop=4, nPush=4: pops the 3-element iterator state plus the
                // value below, calls next on the iterator, pushes result then
                // the 3-element state back.
                let method = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let iterObj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let iter = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let _ = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)  // val (argument to pass, often unused)
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
                buf[sp] = result; sp += 1
                buf[sp] = iter; sp += 1
                buf[sp] = iterObj; sp += 1
                buf[sp] = method; sp += 1
                pc += 1

            case .iterator_call:
                // QuickJS: val iter obj method -> result iter obj method
                // nPop=4, nPush=4: pops the 3-element iterator state plus the
                // value below, calls the specified method on the iterator, pushes
                // result then the 3-element state back.
                let methodType = Int(readU8(bc, pc + 1))
                let nextMethod = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let iterObj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let iter = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let _ = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)  // val (argument)
                let result = ctx.iteratorCallMethod(iter: iter, method: methodType)
                if result.isException {
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = result; sp += 1
                buf[sp] = iter; sp += 1
                buf[sp] = iterObj; sp += 1
                buf[sp] = nextMethod; sp += 1
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
                    jeffJS_syncBufToFrame(frame, buf, varBase)
                    // Save value-stack region
                    let stackCount = sp - spBase
                    var savedStack = [JeffJSValue](repeating: .undefined, count: stackCount)
                    for i in 0..<stackCount { savedStack[i] = buf[spBase + i]; buf[spBase + i] = .undefined }  // move: the saved state owns them now
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
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if let genObj = generatorObject.toObject(),
                   case .generatorData(let genData) = genObj.payload {
                    // Sync buf → frame for saved state
                    jeffJS_syncBufToFrame(frame, buf, varBase)
                    // Save value-stack region as an array for GeneratorSavedState
                    let stackCount = sp - spBase
                    var savedStack = [JeffJSValue](repeating: .undefined, count: stackCount)
                    for i in 0..<stackCount { savedStack[i] = buf[spBase + i]; buf[spBase + i] = .undefined }  // move: the saved state owns them now
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
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if let genObj = generatorObject.toObject(),
                   case .generatorData(let genData) = genObj.payload {
                    // Get the iterator from the value (the iterator holds its
                    // own reference; the popped iterable is released here).
                    let iter = ctx.getIterator(obj: val, isAsync: false)
                    val.freeValue()
                    if iter.isException {
                        retVal = .exception
                        break dispatchLoop
                    }
                    // Get the first value from the inner iterator
                    let result = ctx.iteratorNext(iter: iter)
                    if result.isException {
                        iter.freeValue()
                        retVal = .exception
                        break dispatchLoop
                    }
                    let done = ctx.iteratorCheckDone(result: result)
                    let value = ctx.iteratorGetValue(result: result)
                    result.freeValue()
                    if done {
                        // Inner iterator immediately done — push return value;
                        // the delegation is over, release the iterator.
                        iter.freeValue()
                        buf[sp] = value; sp += 1
                        if fb.isGenerator && !fb.isAsyncFunc {
                            buf[sp] = .newBool(false); sp += 1   // is_return flag for the check after yield_star
                        }
                        genData.state = .executing
                        pc += 1
                    } else {
                        // Yield this value and save state for lazy resumption.
                        // On resume, we'll continue iterating the inner iterator.
                        jeffJS_syncBufToFrame(frame, buf, varBase)
                        let stackCount = sp - spBase
                        var savedStack = [JeffJSValue](repeating: .undefined, count: stackCount)
                        for i in 0..<stackCount { savedStack[i] = buf[spBase + i]; buf[spBase + i] = .undefined }  // move: the saved state owns them now
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
                    val.freeValue()
                    pc += 1
                }

            case .async_yield_star:
                // Async yield* delegation: similar to yield_star but for
                // async iterators. Falls back to synchronous iteration for
                // non-Promise values.
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
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
                    buf[sp] = lastValue; sp += 1
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
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)

                // Fast path: non-object values pass through unchanged.
                // `await 42` === 42, `await "hello"` === "hello"
                guard val.isObject else {
                    buf[sp] = val; sp += 1
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
                        // Dup: the promise owns its result; the VM stack takes
                        // its own reference (a borrowed push here over-freed).
                        buf[sp] = promData.promiseResult.dupValue(); sp += 1
                        pc += 1
                    case .rejected:
                        ctx.throwValue(promData.promiseResult.dupValue())
                        retVal = .exception
                        break dispatchLoop
                    case .pending:
                        // Promise still pending (async I/O). Suspend the async
                        // function and register a continuation to resume later.
                        guard !ctx._asyncResolve.isUndefined else {
                            // Not inside an async function — fallback
                            buf[sp] = .undefined; sp += 1
                            pc += 1
                            break
                        }
                        // Lazily create this async function's result promise.
                        // Non-suspending async calls (the common case) never
                        // pay for a capability + resolver pair.
                        if ctx._asyncResolve.isUninitialized {
                            guard let cap = JeffJSBuiltinPromise.newPromiseCapability(ctx: ctx, ctor: .undefined) else {
                                buf[sp] = .undefined; sp += 1
                                pc += 1
                                break
                            }
                            ctx._asyncResolve = cap.resolve
                            ctx._asyncReject = cap.reject
                            ctx._asyncCapPromise = cap.promise
                        }
                        // Capture stack, vars, args from buf
                        var stackSnap = [JeffJSValue]()
                        for i in spBase..<sp { stackSnap.append(buf[i]) }
                        var varSnap = [JeffJSValue]()
                        for i in 0..<frame.varCount { varSnap.append(buf[varBase + i]) }
                        var argSnap = [JeffJSValue]()
                        for i in 0..<min(varBase, bufCapacity) { argSnap.append(buf[i]) }
                        jeffJS_syncBufToFrame(frame, buf, varBase)

                        let saved = GeneratorSavedState(
                            pc: pc + 1, sp: sp - spBase,
                            stack: stackSnap, varBuf: varSnap,
                            argBuf: argSnap, funcObj: mFuncObj,
                            thisVal: frame.thisVal)

                        let stateID = ctx.storeAsyncState(JeffJSContext.AsyncSavedEntry(
                            saved: saved,
                            resolve: ctx._asyncResolve.dupValue(),
                            reject: ctx._asyncReject.dupValue()))

                        // Native continuation: no JS function objects per await.
                        JeffJSBuiltinPromise.performPromiseThen(
                            ctx: ctx, promise: val,
                            onFulfilled: .undefined, onRejected: .undefined,
                            resultPromise: nil,
                            nativeContinuation: { [stateID] ctx, value, isRejection in
                                ctx.resumeAsyncFunction(stateID: stateID, value: value,
                                                        isRejection: isRejection)
                            })

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
                            // Dup: the promise owns its result (borrowed push over-freed)
                            buf[sp] = tpData.promiseResult.dupValue(); sp += 1
                        case .rejected:
                            ctx.throwValue(tpData.promiseResult.dupValue())
                            retVal = .exception
                            break dispatchLoop
                        case .pending:
                            buf[sp] = .undefined; sp += 1
                        }
                    } else {
                        // Fallback: push the original value
                        buf[sp] = val; sp += 1
                    }
                } else {
                    // Not a thenable: await on non-Promise is identity.
                    buf[sp] = val; sp += 1
                }
                pc += 1

            // -----------------------------------------------------------------
            // Unary Operators
            // -----------------------------------------------------------------

            case .neg:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if val.isInt {
                    let v = val.toInt32()
                    if v == 0 { buf[sp] = .newFloat64(-0.0); sp += 1 }
                    else if v == Int32.min { buf[sp] = .newFloat64(-Double(v)); sp += 1 }
                    else { buf[sp] = .newInt32(-v); sp += 1 }
                } else {
                    let (d, ok) = JeffJSTypeConvert.toNumber(ctx: ctx, val: val)
                    val.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    buf[sp] = .newFloat64(-d); sp += 1
                }
                pc += 1

            case .plus:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if val.isNumber {
                    buf[sp] = val; sp += 1
                } else {
                    let (d, ok) = JeffJSTypeConvert.toNumber(ctx: ctx, val: val)
                    val.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    buf[sp] = .newFloat64(d); sp += 1
                }
                pc += 1

            case .inc:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if val.isInt {
                    let v = val.toInt32()
                    if v == Int32.max { buf[sp] = .newFloat64(Double(v) + 1); sp += 1 }
                    else { buf[sp] = .newInt32(v + 1); sp += 1 }
                } else {
                    let (d, ok) = JeffJSTypeConvert.toNumber(ctx: ctx, val: val)
                    val.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    buf[sp] = .newFloat64(d + 1); sp += 1
                }
                pc += 1

            case .dec:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if val.isInt {
                    let v = val.toInt32()
                    if v == Int32.min { buf[sp] = .newFloat64(Double(v) - 1); sp += 1 }
                    else { buf[sp] = .newInt32(v - 1); sp += 1 }
                } else {
                    let (d, ok) = JeffJSTypeConvert.toNumber(ctx: ctx, val: val)
                    val.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    buf[sp] = .newFloat64(d - 1); sp += 1
                }
                pc += 1

            case .post_inc:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if val.isInt {
                    let v = val.toInt32()
                    buf[sp] = val; sp += 1 // original value
                    if v == Int32.max { buf[sp] = .newFloat64(Double(v) + 1); sp += 1 }
                    else { buf[sp] = .newInt32(v + 1); sp += 1 }
                } else {
                    let (d, ok) = JeffJSTypeConvert.toNumber(ctx: ctx, val: val)
                    val.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    buf[sp] = .newFloat64(d); sp += 1
                    buf[sp] = .newFloat64(d + 1); sp += 1
                }
                pc += 1

            case .post_dec:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if val.isInt {
                    let v = val.toInt32()
                    buf[sp] = val; sp += 1
                    if v == Int32.min { buf[sp] = .newFloat64(Double(v) - 1); sp += 1 }
                    else { buf[sp] = .newInt32(v - 1); sp += 1 }
                } else {
                    let (d, ok) = JeffJSTypeConvert.toNumber(ctx: ctx, val: val)
                    val.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    buf[sp] = .newFloat64(d); sp += 1
                    buf[sp] = .newFloat64(d - 1); sp += 1
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
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let (i, ok) = JeffJSTypeConvert.toInt32(ctx: ctx, val: val)
                val.freeValue()
                if !ok { retVal = .exception; break dispatchLoop }
                buf[sp] = .newInt32(~i); sp += 1
                pc += 1

            case .lnot:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let lnotResult = !jeffJS_fastToBool(val)
                val.freeValue()
                buf[sp] = .newBool(lnotResult); sp += 1
                pc += 1

            case .typeof_:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let t = JeffJSOperators.jsTypeof(val)
                val.freeValue()
                buf[sp] = ctx.typeofString(t); sp += 1
                pc += 1

            case .delete_:
                let key = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let obj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let ok = ctx.deletePropertyValue(obj: obj, key: key)
                obj.freeValue(); key.freeValue()
                buf[sp] = .newBool(ok); sp += 1
                pc += 1

            case .delete_var:
                let atom = readU32(bc, pc + 1)
                let ok = ctx.deleteGlobalVar(atom: atom)
                buf[sp] = .newBool(ok); sp += 1
                pc += 5

            // -----------------------------------------------------------------
            // Binary Arithmetic Operators
            // -----------------------------------------------------------------

            case .add:
                let rhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                // Inline fast path for int+int avoids function call overhead
                if lhs.isInt && rhs.isInt {
                    let a = lhs.toInt32(), b = rhs.toInt32()
                    let (r, overflow) = a.addingReportingOverflow(b)
                    buf[sp] = overflow ? .newFloat64(Double(a) + Double(b)) : .newInt32(r); sp += 1
                } else if lhs.isString && rhs.isString {
                    // String+string fast path: rope-based O(1) concat, bypasses jsAdd
                    let concatResult = jeffJS_concatStrings(s1: lhs, s2: rhs)
                    lhs.freeValue(); rhs.freeValue()
                    buf[sp] = concatResult; sp += 1
                } else {
                    let result = JeffJSOperators.jsAdd(ctx: ctx, lhs: lhs, rhs: rhs)
                    lhs.freeValue(); rhs.freeValue()
                    if result.isException { retVal = .exception; break dispatchLoop }
                    buf[sp] = result; sp += 1
                }
                pc += 1

            case .sub:
                let rhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if lhs.isInt && rhs.isInt {
                    let (r, overflow) = lhs.toInt32().subtractingReportingOverflow(rhs.toInt32())
                    buf[sp] = overflow ? .newFloat64(Double(lhs.toInt32()) - Double(rhs.toInt32())) : .newInt32(r); sp += 1
                } else {
                    let (a, ok1) = JeffJSTypeConvert.toNumber(ctx: ctx, val: lhs)
                    let (b, ok2) = JeffJSTypeConvert.toNumber(ctx: ctx, val: rhs)
                    lhs.freeValue(); rhs.freeValue()
                    if !ok1 || !ok2 { retVal = .exception; break dispatchLoop }
                    buf[sp] = .newFloat64(a - b); sp += 1
                }
                pc += 1

            case .mul:
                let rhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if lhs.isInt && rhs.isInt {
                    let a = Int64(lhs.toInt32()), b = Int64(rhs.toInt32())
                    let r = a * b
                    if r >= Int64(Int32.min) && r <= Int64(Int32.max) && !(r == 0 && (a < 0 || b < 0)) {
                        buf[sp] = .newInt32(Int32(r)); sp += 1
                    } else {
                        buf[sp] = .newFloat64(Double(a) * Double(b)); sp += 1
                    }
                } else {
                    let (a, ok1) = JeffJSTypeConvert.toNumber(ctx: ctx, val: lhs)
                    let (b, ok2) = JeffJSTypeConvert.toNumber(ctx: ctx, val: rhs)
                    lhs.freeValue(); rhs.freeValue()
                    if !ok1 || !ok2 { retVal = .exception; break dispatchLoop }
                    buf[sp] = .newFloat64(a * b); sp += 1
                }
                pc += 1

            case .div:
                let rhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let (a, ok1) = JeffJSTypeConvert.toNumber(ctx: ctx, val: lhs)
                let (b, ok2) = JeffJSTypeConvert.toNumber(ctx: ctx, val: rhs)
                lhs.freeValue(); rhs.freeValue()
                if !ok1 || !ok2 { retVal = .exception; break dispatchLoop }
                buf[sp] = .newFloat64(a / b); sp += 1
                pc += 1

            case .mod:
                let rhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if lhs.isInt && rhs.isInt {
                    let a = lhs.toInt32(), b = rhs.toInt32()
                    if b != 0 && !(a == Int32.min && b == -1) {
                        let r = a % b
                        if r != 0 || a >= 0 { buf[sp] = .newInt32(r); sp += 1 }
                        else { buf[sp] = .newFloat64(Double(a).truncatingRemainder(dividingBy: Double(b))); sp += 1 }
                    } else {
                        buf[sp] = .newFloat64(Double(a).truncatingRemainder(dividingBy: Double(b))); sp += 1
                    }
                } else {
                    let (a, ok1) = JeffJSTypeConvert.toNumber(ctx: ctx, val: lhs)
                    let (b, ok2) = JeffJSTypeConvert.toNumber(ctx: ctx, val: rhs)
                    lhs.freeValue(); rhs.freeValue()
                    if !ok1 || !ok2 { retVal = .exception; break dispatchLoop }
                    buf[sp] = .newFloat64(a.truncatingRemainder(dividingBy: b)); sp += 1
                }
                pc += 1

            case .pow:
                let rhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let (a, ok1) = JeffJSTypeConvert.toNumber(ctx: ctx, val: lhs)
                let (b, ok2) = JeffJSTypeConvert.toNumber(ctx: ctx, val: rhs)
                lhs.freeValue(); rhs.freeValue()
                if !ok1 || !ok2 { retVal = .exception; break dispatchLoop }
                buf[sp] = .newFloat64(pow(a, b)); sp += 1
                pc += 1

            // -----------------------------------------------------------------
            // Bitwise Shift Operators
            // -----------------------------------------------------------------

            case .shl:
                let rhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if lhs.isInt && rhs.isInt {
                    buf[sp] = .newInt32(lhs.toInt32() << (rhs.toInt32() & 0x1F)); sp += 1
                    pc += 1
                    continue dispatchLoop
                }
                let (a, ok1) = JeffJSTypeConvert.toInt32(ctx: ctx, val: lhs)
                let (b, ok2) = JeffJSTypeConvert.toInt32(ctx: ctx, val: rhs)
                lhs.freeValue(); rhs.freeValue()
                if !ok1 || !ok2 { retVal = .exception; break dispatchLoop }
                buf[sp] = .newInt32(a << (b & 0x1F)); sp += 1
                pc += 1

            case .sar:
                let rhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if lhs.isInt && rhs.isInt {
                    buf[sp] = .newInt32(lhs.toInt32() >> (rhs.toInt32() & 0x1F)); sp += 1
                    pc += 1
                    continue dispatchLoop
                }
                let (a, ok1) = JeffJSTypeConvert.toInt32(ctx: ctx, val: lhs)
                let (b, ok2) = JeffJSTypeConvert.toInt32(ctx: ctx, val: rhs)
                lhs.freeValue(); rhs.freeValue()
                if !ok1 || !ok2 { retVal = .exception; break dispatchLoop }
                buf[sp] = .newInt32(a >> (b & 0x1F)); sp += 1
                pc += 1

            case .shr:
                let rhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let (a32, ok1) = JeffJSTypeConvert.toInt32(ctx: ctx, val: lhs)
                let (b, ok2) = JeffJSTypeConvert.toInt32(ctx: ctx, val: rhs)
                lhs.freeValue(); rhs.freeValue()
                if !ok1 || !ok2 { retVal = .exception; break dispatchLoop }
                let ua = UInt32(bitPattern: a32)
                let result = ua >> (UInt32(b & 0x1F))
                buf[sp] = .newUInt32(result); sp += 1
                pc += 1

            // -----------------------------------------------------------------
            // Comparison Operators
            // -----------------------------------------------------------------

            case .lt:
                let rhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                // Inline fast path for int<int avoids function call
                if lhs.isInt && rhs.isInt {
                    buf[sp] = .newBool(lhs.toInt32() < rhs.toInt32()); sp += 1
                } else {
                    let (cmp, ok) = JeffJSOperators.jsCompare(ctx: ctx, lhs: lhs, rhs: rhs)
                    lhs.freeValue(); rhs.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    buf[sp] = .newBool(cmp < 0); sp += 1 // true only when LT; false for unordered (NaN)
                }
                pc += 1

            case .lte:
                let rhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if lhs.isInt && rhs.isInt {
                    buf[sp] = .newBool(lhs.toInt32() <= rhs.toInt32()); sp += 1
                } else {
                    let (cmp, ok) = JeffJSOperators.jsCompare(ctx: ctx, lhs: rhs, rhs: lhs)
                    lhs.freeValue(); rhs.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    buf[sp] = .newBool(cmp == 0); sp += 1
                }
                pc += 1

            case .gt:
                let rhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if lhs.isInt && rhs.isInt {
                    buf[sp] = .newBool(lhs.toInt32() > rhs.toInt32()); sp += 1
                } else {
                    let (cmp, ok) = JeffJSOperators.jsCompare(ctx: ctx, lhs: rhs, rhs: lhs)
                    lhs.freeValue(); rhs.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    buf[sp] = .newBool(cmp < 0); sp += 1
                }
                pc += 1

            case .gte:
                let rhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if lhs.isInt && rhs.isInt {
                    buf[sp] = .newBool(lhs.toInt32() >= rhs.toInt32()); sp += 1
                } else {
                    let (cmp, ok) = JeffJSOperators.jsCompare(ctx: ctx, lhs: lhs, rhs: rhs)
                    lhs.freeValue(); rhs.freeValue()
                    if !ok { retVal = .exception; break dispatchLoop }
                    buf[sp] = .newBool(cmp == 0); sp += 1
                }
                pc += 1

            case .instanceof_:
                let rhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let result = JeffJSOperators.jsInstanceof(ctx: ctx, val: lhs, target: rhs)
                lhs.freeValue(); rhs.freeValue()
                if result.isException { retVal = .exception; break dispatchLoop }
                buf[sp] = result; sp += 1
                pc += 1

            case .in_:
                let rhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
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
                buf[sp] = .newBool(has); sp += 1
                pc += 1

            // -----------------------------------------------------------------
            // Equality Operators
            // -----------------------------------------------------------------

            case .eq:
                let rhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let (result, ok) = JeffJSOperators.jsEq(ctx: ctx, lhs: lhs, rhs: rhs)
                lhs.freeValue(); rhs.freeValue()
                if !ok { retVal = .exception; break dispatchLoop }
                buf[sp] = .newBool(result); sp += 1
                pc += 1

            case .neq:
                let rhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let (result, ok) = JeffJSOperators.jsEq(ctx: ctx, lhs: lhs, rhs: rhs)
                lhs.freeValue(); rhs.freeValue()
                if !ok { retVal = .exception; break dispatchLoop }
                buf[sp] = .newBool(!result); sp += 1
                pc += 1

            case .strict_eq:
                let rhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let seqResult = JeffJSOperators.jsStrictEq(lhs: lhs, rhs: rhs)
                lhs.freeValue(); rhs.freeValue()
                buf[sp] = .newBool(seqResult); sp += 1
                pc += 1

            case .strict_neq:
                let rhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let sneqResult = JeffJSOperators.jsStrictEq(lhs: lhs, rhs: rhs)
                lhs.freeValue(); rhs.freeValue()
                buf[sp] = .newBool(!sneqResult); sp += 1
                pc += 1

            // -----------------------------------------------------------------
            // Bitwise Operators
            // -----------------------------------------------------------------

            case .and:
                let rhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if lhs.isInt && rhs.isInt {
                    buf[sp] = .newInt32(lhs.toInt32() & rhs.toInt32()); sp += 1
                    pc += 1
                    continue dispatchLoop
                }
                let (a, ok1) = JeffJSTypeConvert.toInt32(ctx: ctx, val: lhs)
                let (b, ok2) = JeffJSTypeConvert.toInt32(ctx: ctx, val: rhs)
                lhs.freeValue(); rhs.freeValue()
                if !ok1 || !ok2 { retVal = .exception; break dispatchLoop }
                buf[sp] = .newInt32(a & b); sp += 1
                pc += 1

            case .xor:
                let rhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if lhs.isInt && rhs.isInt {
                    buf[sp] = .newInt32(lhs.toInt32() ^ rhs.toInt32()); sp += 1
                    pc += 1
                    continue dispatchLoop
                }
                let (a, ok1) = JeffJSTypeConvert.toInt32(ctx: ctx, val: lhs)
                let (b, ok2) = JeffJSTypeConvert.toInt32(ctx: ctx, val: rhs)
                lhs.freeValue(); rhs.freeValue()
                if !ok1 || !ok2 { retVal = .exception; break dispatchLoop }
                buf[sp] = .newInt32(a ^ b); sp += 1
                pc += 1

            case .or:
                let rhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc); let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if lhs.isInt && rhs.isInt {
                    buf[sp] = .newInt32(lhs.toInt32() | rhs.toInt32()); sp += 1
                    pc += 1
                    continue dispatchLoop
                }
                let (a, ok1) = JeffJSTypeConvert.toInt32(ctx: ctx, val: lhs)
                let (b, ok2) = JeffJSTypeConvert.toInt32(ctx: ctx, val: rhs)
                lhs.freeValue(); rhs.freeValue()
                if !ok1 || !ok2 { retVal = .exception; break dispatchLoop }
                buf[sp] = .newInt32(a | b); sp += 1
                pc += 1

            // -----------------------------------------------------------------
            // Optimization Predicates
            // -----------------------------------------------------------------

            case .is_undefined:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let isUndefResult = val.isUndefined
                val.freeValue()
                buf[sp] = .newBool(isUndefResult); sp += 1
                pc += 1

            case .is_null:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let isNullResult = val.isNull
                val.freeValue()
                buf[sp] = .newBool(isNullResult); sp += 1
                pc += 1

            case .typeof_is_undefined:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let isUndef = val.isUndefined ||
                              (val.isObject && val.toObject()?.isHTMLDDA == true)
                val.freeValue()
                buf[sp] = .newBool(isUndef); sp += 1
                pc += 1

            case .typeof_is_function:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let isFuncResult = JeffJSOperators.jsTypeof(val) == "function"
                val.freeValue()
                buf[sp] = .newBool(isFuncResult); sp += 1
                pc += 1

            case .is_undefined_or_null:
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let isUON = val.isNull || val.isUndefined
                val.freeValue()
                buf[sp] = .newBool(isUON); sp += 1
                pc += 1

            // -----------------------------------------------------------------
            // Short Push Opcodes
            // -----------------------------------------------------------------

            case .push_null:
                buf[sp] = .null; sp += 1
                pc += 1

            case .push_this:
                buf[sp] = frame.thisVal.dupValue(); sp += 1
                pc += 1

            case .push_0: buf[sp] = .newInt32(0); sp += 1; pc += 1
            case .push_1: buf[sp] = .newInt32(1); sp += 1; pc += 1
            case .push_2: buf[sp] = .newInt32(2); sp += 1; pc += 1
            case .push_3: buf[sp] = .newInt32(3); sp += 1; pc += 1
            case .push_4: buf[sp] = .newInt32(4); sp += 1; pc += 1
            case .push_5: buf[sp] = .newInt32(5); sp += 1; pc += 1
            case .push_6: buf[sp] = .newInt32(6); sp += 1; pc += 1
            case .push_7: buf[sp] = .newInt32(7); sp += 1; pc += 1
            case .push_minus1: buf[sp] = .newInt32(-1); sp += 1; pc += 1

            case .push_i8:
                let val = readI8(bc, pc + 1)
                buf[sp] = .newInt32(Int32(val)); sp += 1
                pc += 2

            case .push_i16:
                let val = readI16(bc, pc + 1)
                buf[sp] = .newInt32(Int32(val)); sp += 1
                pc += 3

            case .push_const8:
                let idx = Int(readU8(bc, pc + 1))
                if idx < fb.cpool.count {
                    buf[sp] = fb.cpool[idx].dupValue(); sp += 1
                } else {
                    buf[sp] = .undefined; sp += 1
                }
                pc += 2

            case .fclosure8:
                let idx = Int(readU8(bc, pc + 1))
                let closureVal = ctx.createClosure(fb: fb, cpoolIdx: idx, varRefs: varRefs,
                                                    parentFrame: frame)
                buf[sp] = closureVal; sp += 1
                pc += 2

            case .push_empty_string:
                buf[sp] = ctx.newString(""); sp += 1
                pc += 1

            case .get_length:
                let obj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                // IC fast path: own "length" data slot (arrays keep it at slot 0).
                if let jsObj = obj.obj, let sid = jsObj.shapeIdentity, let ents = fb.icEntries {
                    let entry = ents[pc & JeffJSInlineCache.mask]
                    if entry.pc == pc, entry.shapePtr == sid, entry.holderPtr == nil,
                       entry.propOffset >= 0, entry.propOffset < jsObj.propCount,
                       jsObj.extra(at: entry.propOffset) == nil {
                        buf[sp] = jsObj.dataValue(at: entry.propOffset).dupValue(); sp += 1
                        obj.freeValue()
                        pc += 1
                        continue dispatchLoop
                    }
                }
                // Atom-based lookup (the old string-keyed getPropertyStr re-interned
                // "length" on every execution) + cache fill.
                let lengthAtom = JeffJSAtomID.JS_ATOM_length.rawValue
                let len = ctx.getProperty(obj: obj, atom: lengthAtom)
                if len.isException {
                    obj.freeValue()
                    retVal = .exception
                    break dispatchLoop
                }
                buf[sp] = len; sp += 1
                if let jsObj = obj.obj, let shape = jsObj.shape,
                   let idx = findShapeProperty(shape, lengthAtom) {
                    fb.getIC().update(pc, shape: shape, propOffset: idx)
                }
                obj.freeValue()
                pc += 1

            // -----------------------------------------------------------------
            // NOP and temporary compilation opcodes
            // -----------------------------------------------------------------

            case .nop:
                // Padding only (the compiler compacts NOPs out of final bytecode;
                // the old NOP-prefixed compound fusions are gone).
                pc += 1

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
                let obj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if obj.isNull || obj.isUndefined {
                    buf[sp] = .undefined; sp += 1
                } else {
                    let val = ctx.getProperty(obj: obj, atom: atom)
                    if val.isException {
                        retVal = .exception
                        break dispatchLoop
                    }
                    buf[sp] = val; sp += 1
                }
                pc += 2 + 4  // wide prefix (2) + u32 atom (4)

            case .get_array_el_opt_chain:
                // Wide opcode: now handled via .invalid wide-prefix path.
                // Kept for exhaustiveness. Wide prefix = 2 bytes.
                let key = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let obj = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                if obj.isNull || obj.isUndefined {
                    buf[sp] = .undefined; sp += 1
                } else {
                    let val = ctx.getPropertyValue(obj: obj, prop: key)
                    if val.isException {
                        retVal = .exception
                        break dispatchLoop
                    }
                    buf[sp] = val; sp += 1
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
                if let jsObj = obj.obj, jsObj.shapeIdentity != nil {
                    if let ents = fb.icEntries {
                        let entry = ents[pc & JeffJSInlineCache.mask]
                        var icHit: JeffJSValue? = nil
                        if entry.pc == pc, entry.shapePtr == jsObj.shapeIdentity {
                            if entry.holderPtr != nil {
                                icHit = jeffJS_icProtoHit(entry)     // prototype method/field
                            } else if entry.propOffset >= 0, entry.propOffset < jsObj.propCount,
                                      jsObj.extra(at: entry.propOffset) == nil {
                                icHit = jsObj.dataValue(at: entry.propOffset)
                            }
                        }
                        if let hv = icHit {
                            do {
                                buf[sp] = hv.dupValue(); sp += 1
                                pc += 6
                                continue dispatchLoop
                            }
                        }
                    }
                    let val = ctx.getProperty(obj: obj, atom: atom)
                    if val.isException { retVal = .exception; break dispatchLoop }
                    buf[sp] = val; sp += 1
                    if let shape = jsObj.shape {
                        if let propIdx = findShapeProperty(shape, atom) {
                            fb.getIC().update(pc, shape: shape, propOffset: propIdx)
                        } else if let holder = jsObj.proto, let hs = holder.shape,
                                  let hIdx = findShapeProperty(hs, atom),
                                  hIdx < holder.propValues.count, holder.extra(at: hIdx) == nil {
                            fb.getIC().updateProto(pc, receiverShape: shape, holder: holder,
                                                   holderShape: hs, propOffset: hIdx)
                        }
                    }
                } else {
                    let val = ctx.getProperty(obj: obj, atom: atom)
                    if val.isException { retVal = .exception; break dispatchLoop }
                    buf[sp] = val; sp += 1
                }
                pc += 6

            case .get_arg0_get_field:
                // Fused: get_arg(0) + get_field(atom)
                // Format: opcode(1) + atom(4) = 5 bytes
                let atom = readU32(bc, pc + 1)
                let obj = varBase > 0 ? buf[0] : JeffJSValue.undefined
                // Inline cache fast path
                if let jsObj = obj.obj, jsObj.shapeIdentity != nil {
                    if let ents = fb.icEntries {
                        let entry = ents[pc & JeffJSInlineCache.mask]
                        var icHit: JeffJSValue? = nil
                        if entry.pc == pc, entry.shapePtr == jsObj.shapeIdentity {
                            if entry.holderPtr != nil {
                                icHit = jeffJS_icProtoHit(entry)     // prototype method/field
                            } else if entry.propOffset >= 0, entry.propOffset < jsObj.propCount,
                                      jsObj.extra(at: entry.propOffset) == nil {
                                icHit = jsObj.dataValue(at: entry.propOffset)
                            }
                        }
                        if let hv = icHit {
                            do {
                                buf[sp] = hv.dupValue(); sp += 1
                                pc += 5
                                continue dispatchLoop
                            }
                        }
                    }
                    let val = ctx.getProperty(obj: obj, atom: atom)
                    if val.isException { retVal = .exception; break dispatchLoop }
                    buf[sp] = val; sp += 1
                    if let shape = jsObj.shape {
                        if let propIdx = findShapeProperty(shape, atom) {
                            fb.getIC().update(pc, shape: shape, propOffset: propIdx)
                        } else if let holder = jsObj.proto, let hs = holder.shape,
                                  let hIdx = findShapeProperty(hs, atom),
                                  hIdx < holder.propValues.count, holder.extra(at: hIdx) == nil {
                            fb.getIC().updateProto(pc, receiverShape: shape, holder: holder,
                                                   holderShape: hs, propOffset: hIdx)
                        }
                    }
                } else {
                    let val = ctx.getProperty(obj: obj, atom: atom)
                    if val.isException { retVal = .exception; break dispatchLoop }
                    buf[sp] = val; sp += 1
                }
                pc += 5

            case .get_loc8_add:
                // Fused: get_loc8(idx) + add
                // Format: opcode(1) + loc8(1) = 2 bytes
                // Stack: pops the value pushed BEFORE the get_loc (lhs) and
                // pushes (lhs + local[idx]). Operand order matters for string
                // concatenation: `x + loc` compiles to <x> get_loc add.
                let locIdx = Int(readU8(bc, pc + 1))
                let lhs = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
                let rhs = buf[varBase + locIdx]          // borrowed from the slot
                let result = JeffJSOperators.jsAdd(ctx: ctx, lhs: lhs, rhs: rhs)
                lhs.freeValue()
                if result.isException { retVal = .exception; break dispatchLoop }
                buf[sp] = result; sp += 1
                pc += 2

            case .put_loc8_return:
                // Fused: put_loc8(idx) + return
                // Format: opcode(1) + loc8(1) = 2 bytes
                let locIdx = Int(readU8(bc, pc + 1))
                let val = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
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
                buf[sp] = buf[varBase + idxA].dupValue(); sp += 1
                buf[sp] = buf[varBase + idxB].dupValue(); sp += 1
                pc += 3

            case .get_loc8_call:
                // Fused: get_loc8(idx) + call(argc). Only emitted for argc == 0.
                // Format: opcode(1) + loc8(1) + u16(2) = 4 bytes
                let locIdx = Int(readU8(bc, pc + 1))
                let argc = Int(readU16(bc, pc + 2))
                // Same inline fast path as `call`: push the callee and enter
                // its frame in place (this used to go through callFunction,
                // which made every zero-arg closure call a full recursive
                // callInternal with an args array).
                if inlineCallsEnabled, argc == 0,
                   let callObj = buf[varBase + locIdx].obj,
                   let fastFb = callObj.fbFast, !fastFb.isGenerator, !fastFb.isAsyncFunc,
                   rt.inlineStackTop - inlineBase <= 10000 {
                    let calleeSlot = sp
                    let funcVal = buf[varBase + locIdx].dupValue()
                    buf[sp] = funcVal; sp += 1
                    do { // inline call (expanded; no nested-function capture of hot locals)
                        let e_fastFb = fastFb
                        let e_callObj = callObj
                        let e_funcVal = funcVal
                        let e_argc = 0
                        let e_calleeSlot = calleeSlot
                        let e_restoreSp = calleeSlot
                        let e_thisVal: JeffJSValue = .undefined
                        let e_instrSize = 4
                        let argStart = e_calleeSlot + 1
                        rt.inlinePush(InlineCallFrame(
                            pc: pc + e_instrSize, sp: e_restoreSp, spTop: sp,
                            buf: buf, bufCapacity: bufCapacity,
                            varBase: varBase, spBase: spBase,
                            bc: bc, bcLen: bcLen, fb: fb,
                            frame: frame,
                            funcObj: mFuncObj, flags: mFlags, bufOwned: bufOwned))
                        fb = e_fastFb
                        bc = e_fastFb.bcPtrFast ?? e_fastFb.bytecodePtr
                        bcLen = e_fastFb.bytecodeLen
                        // Only functions with closure variables need their varRefs
                        // array (a retain/release pair per assignment otherwise).
                        if e_fastFb.closureVarCount > 0 {
                            varRefs = e_callObj.varRefsFast
                            varRefsLoaded = true
                        } else if varRefsLoaded {
                            varRefs = []
                            varRefsLoaded = false
                        }
                        mFuncObj = e_funcVal
                        mFlags = 0
                        unowned(unsafe) let newFrame: JeffJSStackFrame = rt.acquireFrameU().takeUnretainedValue()
                        newFrame.prevFrame = ctx.currentFrame
                        newFrame.curFunc = e_funcVal
                        if e_fastFb.isArrow, let arrowThis = e_callObj.arrowThisVal {
                            newFrame.thisVal = arrowThis.dupValue()
                        } else if !e_fastFb.isStrictMode && e_thisVal.isNullOrUndefined {
                            // ES §10.2.1.2: sloppy callees see the global object.
                            newFrame.thisVal = ctx.globalObj
                        } else {
                            newFrame.thisVal = e_thisVal
                        }
                        newFrame.argCount = e_argc
                        let newVarCount = Int(e_fastFb.varCount)
                        newFrame.varCount = newVarCount
                        let fbArgCount = Int(e_fastFb.argCount); let newArgSlots = fbArgCount > e_argc ? fbArgCount : e_argc
                        let fbStack = Int(e_fastFb.stackSize); let newStackSlots = (fbStack > 4 ? fbStack : 4) + 32
                        let newTotalSlots = newArgSlots + newVarCount + newStackSlots
                        let newBuf: UnsafeMutablePointer<JeffJSValue>
                        let newBufCap: Int
                        if argStart + newTotalSlots <= bufCapacity {
                            newBuf = buf + argStart
                            newBufCap = bufCapacity - argStart
                            // Args are already in place; pad missing args + locals.
                            // Straight-line stores for the common small counts: the loop
                            // form was turned into a memset_pattern16 call per call.
                            let prefix = newArgSlots + newVarCount
                            let pad = prefix - e_argc
                            if pad > 0 {
                                newBuf[e_argc] = .undefined
                                if pad > 1 { newBuf[e_argc + 1] = .undefined }
                                if pad > 2 { newBuf[e_argc + 2] = .undefined }
                                if pad > 3 {
                                    var i = e_argc + 3
                                    while i < prefix { newBuf[i] = .undefined; i += 1 }
                                }
                            }
                            bufOwned = false
                        } else {
                            (newBuf, newBufCap) = rt.acquireInterpBuf(size: newTotalSlots,
                                                                      initializedPrefix: newArgSlots + newVarCount)
                            for i in 0..<e_argc { newBuf[i] = buf[argStart + i] }
                            bufOwned = true
                        }
                        frame = newFrame
                        ctx.currentFrame = frame
                        frame.spBase = 0
                        buf = newBuf
                        bufCapacity = newBufCap
                        varBase = newArgSlots
                        spBase = newArgSlots + newVarCount
                        sp = spBase
                        // Named function expression self-reference (ES §15.2.4).
                        if e_fastFb.selfRefVarIdx >= 0 {
                            buf[varBase + e_fastFb.selfRefVarIdx] = e_funcVal.dupValue()
                        }
                        frame.buf = buf
                        frame.bufCapacity = bufCapacity
                        frame.bufVarBase = varBase
                        frame.bufSpBase = spBase
                        pc = 0
                    }
                    // Run the callee in the fast trace from its first instruction.
                    if fb.traceLean {
                        let r = executeFastTraceLean(bc: bc, bcLen: bcLen, entryPC: 0, exitPC: bcLen, startPC: pc,
                                                     buf: buf, varBase: varBase, sp: &sp, ctx: ctx, cpool: fb.cpool,
                                                     stackLimit: bufCapacity, icEntries: fb.icEntries)
                        if r == -1 { retVal = .exception; break dispatchLoop }
                        pc = r
                        continue dispatchLoop
                    }
                    if fb.traceEntryEnabled {
                        let fbIdBefore = ObjectIdentifier(fb)
                        var hot = HotState(sp: sp, buf: buf, bufCapacity: bufCapacity, varBase: varBase, spBase: spBase, bc: bc, bcLen: bcLen, fb: fb, frame: frame, funcObj: mFuncObj, flags: mFlags, bufOwned: bufOwned, varRefsLoaded: varRefsLoaded, varRefsRaw: mFuncObj.obj?.varRefsRaw, varRefsRawCount: mFuncObj.obj?.varRefsRawCount ?? 0)
                        let resumePC = executeFastTrace(state: &hot, startPC: pc, ctx: ctx, rt: rt, inlineBase: inlineBase)
                        sp = hot.sp; buf = hot.buf; bufCapacity = hot.bufCapacity; varBase = hot.varBase; spBase = hot.spBase
                        bc = hot.bc; bcLen = hot.bcLen; fb = hot.fb; frame = hot.frame
                        mFuncObj = hot.funcObj; mFlags = hot.flags; bufOwned = hot.bufOwned
                        if fb.closureVarCount > 0 { varRefs = mFuncObj.obj?.varRefsFast ?? []; varRefsLoaded = true } else if varRefsLoaded { varRefs = []; varRefsLoaded = false }
                        // Entry deopt accounting: an early exit still inside this function
                        // means the trace could not run it; stop trying after a while.
                        if hot.opsRun < 16, ObjectIdentifier(fb) == fbIdBefore {
                            fb.traceEntryDeopts &+= 1
                            if fb.traceEntryDeopts >= 100 { fb.traceEntryEnabled = false }
                        }
                        if resumePC == -1 { retVal = .exception; break dispatchLoop }
                        pc = resumePC
                    }
                    continue dispatchLoop
                }
                var callArgs = [JeffJSValue](repeating: .undefined, count: argc)
                for i in stride(from: argc - 1, through: 0, by: -1) { callArgs[i] = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc) }
                let funcVal = buf[varBase + locIdx]       // borrowed from the slot
                let glcBytecode = jeffJS_isPlainBytecodeCallee(funcVal)
                let result = ctx.callFunction(funcVal, thisVal: .undefined, args: callArgs)
                if glcBytecode { for a in callArgs { a.freeValue() } }
                if result.isException { retVal = .exception; break dispatchLoop }
                buf[sp] = result; sp += 1
                pc += 4

            case .dup_put_loc8:
                // Fused: dup + put_loc8(idx)
                // Format: opcode(1) + loc8(1) = 2 bytes
                // Peek TOS and store copy to local (value remains on stack)
                let locIdx = Int(readU8(bc, pc + 1))
                let oldDupPL8 = buf[varBase + locIdx]
                buf[varBase + locIdx] = buf[sp - 1].dupValue()
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
                    if actualDelta != expectedDelta && !isChainedStore && traceOps {
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
            // Interrupt-requested termination is uncatchable: unwind the whole
            // stack (freeing values) without entering any catch handler.
            if ctx.interruptTerminated {
                while sp > spBase {
                    sp -= 1
                    buf[sp].freeValue()
                }
                break exceptionRetry
            }
            // Scan current frame's stack for catch handler
            while sp > spBase {
                sp -= 1
                let entry = buf[sp]
                if entry.isCatchOffset {
                    let catchAddr = Int(entry.toInt32())
                    let excVal = ctx.getException()
                    buf[sp] = excVal; sp += 1
                    pc = catchAddr
                    retVal = .undefined
                    handlerFound = true
                    break
                }
                entry.freeValue()
            }
            // If no handler found, unwind through inline call frames
            if !handlerFound {
                while rt.inlineStackTop != inlineBase {
                    // Run frame epilogue for current (callee) frame
                    if frame.hasLiveVarRefs {
                        jeffJS_syncBufToFrame(frame, buf, varBase)
                        for vr in frame.liveVarRefs where !vr.isDetached {
                            // pvalue prefers frame.buf, which holds padded arg
                            // slots that argBuf (un-padded) does not.
                            vr.value = vr.pvalue.dupValue()
                            vr.isDetached = true
                            vr.parentFrame = nil; vr.slot = nil
                        }
                    }
                    ctx.currentFrame = frame.prevFrame
                    rt.releaseFrame(frame)
                    if bufOwned { rt.releaseInterpBuf(buf, capacity: bufCapacity) }
                    // Restore caller state
                    let saved = rt.inlinePop()
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
                    if saved.fb.closureVarCount > 0 { varRefs = saved.funcObj.obj?.varRefsFast ?? []; varRefsLoaded = true } else if varRefsLoaded { varRefs = []; varRefsLoaded = false }
                    mFuncObj = saved.funcObj
                    mFlags = saved.flags; bufOwned = saved.bufOwned
                    // Scan caller's stack for catch handler (skipped entirely
                    // for uncatchable interrupt termination)
                    while !ctx.interruptTerminated && sp > spBase {
                        sp -= 1
                        let entry = buf[sp]
                        if entry.isCatchOffset {
                            let catchAddr = Int(entry.toInt32())
                            let excVal = ctx.getException()
                            buf[sp] = excVal; sp += 1
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
            retVal = jeffJS_pop(buf, &sp, spBase, ctx, fb, pc)
        }

        // Free remaining stack values (left over from unclean exits)
        while sp > spBase {
            sp -= 1
            buf[sp].freeValue()
        }
        // Release the variable slots (QuickJS frees var_buf at exit). Args are
        // the caller's (borrowed). Generator/async frames keep their state
        // while suspended; a generator that has completed (state still
        // .executing after the loop, i.e. no yield suspended it) releases
        // its locals and its arguments (generator args are owned by the
        // generator: the call site hands them over at creation).
        if !fb.isGenerator, !fb.isAsyncFunc, !frame.hasLiveVarRefs {
            var i = varBase
            while i < spBase { buf[i].freeValue(); i += 1 }
        } else if fb.isGenerator, !fb.isAsyncFunc, !frame.hasLiveVarRefs,
                  let genObj = generatorObject.toObject(),
                  case .generatorData(let genData) = genObj.payload,
                  genData.state == .executing {
            var i = 0
            while i < spBase { buf[i].freeValue(); i += 1 }
        }

        // Detach any remaining live var-refs that still point at this frame.
        // This handles `var`-scoped captured variables whose lifetime equals
        // the entire function -- the compiler does not emit `close_loc` for
        // them, so we must detach here before the frame goes away.
        // Skipped entirely for the common case (no captures): the sync loops
        // and detach walk cost real time at 250k calls/sec.
        if frame.hasLiveVarRefs {
            jeffJS_syncBufToFrame(frame, buf, varBase)
            for vr in frame.liveVarRefs where !vr.isDetached {
                // pvalue prefers frame.buf (still set here), which holds the
                // padded arg slots that the un-padded argBuf does not.
                vr.value = vr.pvalue.dupValue()
                vr.isDetached = true
                vr.parentFrame = nil; vr.slot = nil
            }
        }

        // Restore previous frame
        ctx.currentFrame = frame.prevFrame

        // Release the contiguous buffer to pool
        if bufOwned { rt.releaseInterpBuf(buf, capacity: bufCapacity) }

        // Return frame to pool for reuse (only if no live closures reference it,
        // since closures have already been detached above and copied their values)
        rt.releaseFrame(frame)

        // Abandon any inline frames left by an abrupt exit (uncatchable
        // interrupt termination) so the next activation starts clean.
        rt.inlineStackTop = inlineBase

        return retVal
    }
}

// =============================================================================
// MARK: - Opcode Info Lookup Helper
// =============================================================================

// jeffJSGetOpcodeInfo(_:) is defined in JeffJSOpcodes.swift.
// This file uses it from there to avoid duplicate declarations.


/// Materialise the frame's argBuf/varBuf from the unsafe buffer (lazy
/// arrays; see the interpreter). File-scope on purpose: a nested function
/// inside callInternal would capture `frame`/`buf`/`varBase` by reference and
/// pin those hot locals to memory.
@inline(never)
private func jeffJS_syncBufToFrame(_ frame: JeffJSStackFrame, _ buf: UnsafeMutablePointer<JeffJSValue>, _ varBase: Int) {
    // The frame arrays are materialised lazily: the call paths no
    // longer fill argBuf/varBuf per call (that array churn dominated
    // call cost). Consumers that need the arrays (arguments object,
    // generator save/restore) call this first, which (re)builds them
    // from the authoritative unsafe buffer.
    let ac = min(frame.argCount, varBase)
    frame.bufArraysLive = true
    if frame.argBuf.count != ac {
        frame.argBuf = Array(UnsafeBufferPointer(start: buf, count: ac))
    } else {
        for i in 0..<ac { frame.argBuf[i] = buf[i] }
    }
    let vc = frame.varCount
    if frame.varBuf.count != vc {
        frame.varBuf = Array(UnsafeBufferPointer(start: buf + varBase, count: vc))
    } else {
        for i in 0..<vc { frame.varBuf[i] = buf[varBase + i] }
    }
}

/// Copy the frame arrays back into the unsafe buffer (after external
/// modification, e.g. generator restore).
@inline(never)
private func jeffJS_syncFrameToBuf(_ frame: JeffJSStackFrame, _ buf: UnsafeMutablePointer<JeffJSValue>, _ varBase: Int) {
    for i in 0..<frame.argBuf.count {
        if i < varBase { buf[i] = frame.argBuf[i] }
    }
    for i in 0..<frame.varBuf.count {
        buf[varBase + i] = frame.varBuf[i]
    }
}

// MARK: - Unsafe inline call stack (per runtime)

extension JeffJSRuntime {
    /// Push a saved caller state. Frames are trivially copyable, so this is
    /// a plain store; the buffer grows geometrically and is never shrunk.
    @inline(__always)
    func inlinePush(_ f: JeffJSInterpreter.InlineCallFrame) {
        if inlineStackTop == inlineStackCap { growInlineStack() }
        (inlineStackBuf! + inlineStackTop).pointee = f   // trivially-copyable: plain store
        inlineStackTop += 1
    }

    @inline(__always)
    func inlinePop() -> JeffJSInterpreter.InlineCallFrame {
        inlineStackTop -= 1
        return (inlineStackBuf! + inlineStackTop).pointee
    }

    @inline(never)
    func growInlineStack() {
        let newCap = max(256, inlineStackCap * 2)
        let nb = UnsafeMutablePointer<JeffJSInterpreter.InlineCallFrame>.allocate(capacity: newCap)
        if let ob = inlineStackBuf {
            nb.moveInitialize(from: ob, count: inlineStackTop)
            ob.deallocate()
        }
        inlineStackBuf = nb
        inlineStackCap = newCap
    }
}


#if JEFFJS_OPPROF
// Dynamic opcode-sequence profile (build with -Xswiftc -DJEFFJS_OPPROF):
// counts executed opcodes and consecutive pairs across all three
// dispatchers, dumped to stderr at exit. Used to pick superinstructions.
let jeffJS_opProfN = 320
nonisolated(unsafe) var jeffJS_opProfPairs = [UInt64](repeating: 0, count: 320 * 320)
nonisolated(unsafe) var jeffJS_opProfSingles = [UInt64](repeating: 0, count: 320)
nonisolated(unsafe) var jeffJS_opProfPrev = 0
nonisolated(unsafe) var jeffJS_opProfRegistered = false
@inline(__always)
func jeffJS_opProfRecord(_ op: Int) {
    if !jeffJS_opProfRegistered { jeffJS_opProfRegistered = true; atexit(jeffJS_opProfDump) }
    jeffJS_opProfSingles[op] &+= 1
    jeffJS_opProfPairs[jeffJS_opProfPrev * jeffJS_opProfN + op] &+= 1
    jeffJS_opProfPrev = op
}
func jeffJS_opProfName(_ v: Int) -> String {
    if let op = JeffJSOpcode(rawValue: UInt16(v)) { return String(describing: op) }
    return "op\(v)"
}
func jeffJS_opProfDump() {
    var total: UInt64 = 0
    for c in jeffJS_opProfSingles { total &+= c }
    var out = "OPPROF total ops \(total)\n== top opcodes\n"
    let singles = (0..<jeffJS_opProfN).map { ($0, jeffJS_opProfSingles[$0]) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
    for (v, c) in singles {
        out += String(format: "%10llu %5.1f%%  %@\n", c, Double(c) * 100 / Double(max(total, 1)), jeffJS_opProfName(v))
    }
    let never = (1..<256).filter { jeffJS_opProfSingles[$0] == 0 && JeffJSOpcode(rawValue: UInt16($0)) != nil }
    out += "== narrow opcodes never executed (\(never.count)): " + never.map { jeffJS_opProfName($0) }.joined(separator: " ") + "\n"
    out += "== top pairs\n"
    var pairs: [(Int, Int, UInt64)] = []
    for a in 0..<jeffJS_opProfN { for b in 0..<jeffJS_opProfN { let c = jeffJS_opProfPairs[a * jeffJS_opProfN + b]; if c > 0 { pairs.append((a, b, c)) } } }
    pairs.sort { $0.2 > $1.2 }
    for (a, b, c) in pairs.prefix(60) {
        out += String(format: "%10llu %5.1f%%  %@ -> %@\n", c, Double(c) * 100 / Double(max(total, 1)), jeffJS_opProfName(a), jeffJS_opProfName(b))
    }
    FileHandle.standardError.write(out.data(using: .utf8)!)
}
#endif


/// Tracks which property keys a for-in enumeration has already produced.
/// A for-in normally sees a handful of keys, where a linear scan over
/// UInt32s is much cheaper than hashing each one; the set is only built
/// once an object turns out to be large.
struct JeffJSKeySeen {
    private var list: [UInt32] = []
    private var set: Set<UInt32>?
    private static let promoteAt = 48

    /// Records `v`, returning true if it had not been seen before.
    @inline(__always)
    mutating func insert(_ v: UInt32) -> Bool {
        if set != nil { return set!.insert(v).inserted }
        if list.contains(v) { return false }
        list.append(v)
        if list.count > Self.promoteAt { set = Set(list) }
        return true
    }
}
