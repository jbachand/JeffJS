// Cold error paths of JeffJSInterpreter.callInternal: the messages live here so LLVM does not hoist
// their string-literal constants into the interpreter prologue (stored to the stack on every call).
enum JeffJSColdError {
    case m0
    case m1
    case m2
    case m3
    case m4
    case m5
    case m6
    case m7
    case m8
    case m9
    case m10
    case m11
    case m12
    case constAssign
}

@inline(never) @discardableResult
func jeffJS_coldThrow(_ ctx: JeffJSContext, _ e: JeffJSColdError) -> JeffJSValue {
    switch e {
    case .m0: return ctx.throwRangeError(message: "Maximum call stack size exceeded.")
    case .m1: return ctx.throwTypeError(message: "not a bytecode function")
    case .m2: return ctx.throwTypeError(message: "iterator does not have a throw method")
    case .m3: return ctx.throwTypeError(message: "iterator does not have a next method")
    case .m4: return ctx.throwTypeError(message: "iterator result is not an object")
    case .m5: return ctx.throwReferenceError(message: "super() already called")
    case .m6: return ctx.throwTypeError(message: "derived constructor must return object or undefined")
    case .m7: return ctx.throwTypeError(message: "invalid brand on object")
    case .m8: return ctx.throwReferenceError(message: "Cannot access variable before initialization")
    case .m9: return ctx.throwReferenceError(message: "Must call super constructor before using 'this'")
    case .m10: return ctx.throwTypeError(message: "Cannot use 'in' operator to search for property in non-object")
    case .m11: return ctx.throwReferenceError(message: "must call super constructor before using 'this'")
    case .constAssign: return ctx.throwTypeError(message: "Attempted to assign to readonly property.")
    case .m12: return ctx.throwReferenceError(message: "must call super constructor before returning from derived constructor")
    }
}

@inline(never) @discardableResult
func jeffJS_coldThrowPC(_ ctx: JeffJSContext, _ k: Int, _ pc: Int) -> JeffJSValue {
    switch k {
    case 0: return ctx.throwInternalError(message: "Invalid opcode 0 (trap) at pc=\(pc) - uninitialized bytecode")
    case 1: return ctx.throwInternalError(message: "wide opcode dispatched directly at pc=\(pc)")
    default: return ctx.throwInternalError(message: "Unresolved scope opcode at pc=\(pc)")
    }
}

@inline(never)
func jeffJS_coldThrowClassCall(_ ctx: JeffJSContext, _ nm: String) {
    _ = ctx.throwTypeError(message: nm.isEmpty
        ? "Cannot call a class constructor without |new|"
        : "Cannot call a class constructor \(nm) without |new|")
}

@inline(never)
func jeffJS_coldThrowErrorMessage(_ ctx: JeffJSContext, _ errType: UInt8, _ atom: UInt32) -> String {
    return errType == ThrowErrorType.constAssign.rawValue
        ? "Attempted to assign to readonly property."
        : ctx.atomToSwiftString(atom)
}

@inline(never)
func jeffJS_coldThrowCantFind(_ ctx: JeffJSContext, _ atom: UInt32) {
    _ = ctx.throwReferenceError(message: "Can't find variable: \(ctx.rt.atomToString(atom) ?? "")")
}

@inline(never)
func jeffJS_coldTypeofIsFunction(_ val: JeffJSValue) -> Bool {
    return JeffJSOperators.jsTypeof(val) == "function"
}

@inline(never)
func jeffJS_coldPrint1(_ idx: Int, _ vr: JeffJSVarRef, _ val: JeffJSValue) {
    print("[VAR_REF] get idx=\(idx) isDetached=\(vr.isDetached) isArg=\(vr.isArg) varIdx=\(vr.varIdx) val.bits=0x\(String(val.bits, radix: 16)) frame=\(vr.parentFrame != nil)")
}
@inline(never)
func jeffJS_coldPrint2(_ idx: Int, _ vrCount: Int) {
    print("[VAR_REF] get idx=\(idx) OUT OF RANGE (count=\(vrCount))")
}
@inline(never)
func jeffJS_coldPrint3(_ vr: JeffJSVarRef, _ val: JeffJSValue) {
    print("[VAR_REF0] isDetached=\(vr.isDetached) isArg=\(vr.isArg) varIdx=\(vr.varIdx) val.bits=0x\(String(val.bits, radix: 16))/\(val.toInt32()) frame=\(vr.parentFrame != nil)")
}
@inline(never)
func jeffJS_coldPrint4() { print("[VAR_REF0] empty varRefs") }

@inline(never)
func jeffJS_coldForOfNext(_ ctx: JeffJSContext, _ method: JeffJSValue, _ iter: JeffJSValue) {
    print("[FOR-OF-NEXT] method.isFunction=\(method.isFunction) method.isUndefined=\(method.isUndefined) iter.isObject=\(iter.isObject)")
    if iter.toObject() != nil {
        print("[FOR-OF-NEXT] iter has _target: \(ctx.getPropertyStr(obj: iter, name: "_target").isObject)")
        print("[FOR-OF-NEXT] iter has next: \(ctx.getPropertyStr(obj: iter, name: "next").isFunction)")
    }
}

@inline(never)
func jeffJS_coldForOf(_ ctx: JeffJSContext, _ forOfResult: JeffJSValue, _ forOfDone: Bool, _ forOfDoneVal: JeffJSValue) {
    let v = ctx.getPropertyStr(obj: forOfResult, name: "value")
    print("[FOR-OF] result.isObject=\(forOfResult.isObject) done=\(forOfDone) doneVal.bits=0x\(String(forOfDoneVal.bits, radix: 16)) value=\(ctx.toSwiftString(v) ?? "nil")")
    if let obj = forOfResult.toObject() {
        print("[FOR-OF] result props: \(obj.propCount) shape: \(obj.shape?.propCount ?? -1)")
    }
}

@inline(never)
func jeffJS_coldTraceDeopt(_ traceInfo: TraceBlockInfo, _ resumePC: Int, _ fbChanged: Bool, _ opsRun: Int,
                           _ bc: UnsafePointer<UInt8>, _ bcLen: Int) {
    jeffJS_stderrLine("[trace] start=\(traceInfo.startPC) resume=\(resumePC) region=[\(traceInfo.entryPC),\(traceInfo.exitPC)) fbChanged=\(fbChanged) ops=\(opsRun) op=\(resumePC >= 0 && resumePC < bcLen ? String(describing: unsafeBitCast(UInt16(bc[resumePC]), to: JeffJSOpcode.self)) : "?")")
}

@inline(never)
func jeffJS_coldStackDelta(_ op: JeffJSOpcode, _ expected: Int, _ actual: Int, _ pc: Int) {
    print("[JeffJS-STACK] \(op): expected sp delta \(expected) but got \(actual) at pc=\(pc)")
}
