import Foundation

// JeffJSFBRef.swift
// JeffJS — the interpreter's handle on the running function's bytecode record
// (JeffJS issue #1 step 2, build flag JEFFJS_MANUAL_MEMORY).
//
// quickjs.c JS_CallInternal reads the running function's JSFunctionBytecode
// through a plain pointer `b`: the function object the caller holds keeps it
// alive, and nothing is counted per call. Here the record is a Swift class,
// and a strong `fb` local in the dispatch costs a retain/release pair on
// every assignment (two per inline call + return, more around the trace
// tier), while `unowned(unsafe) var` makes the compiler copy the reference
// around member reads (docs/PERFORMANCE_PLAN.md, round 15).
//
// Under JEFFJS_MANUAL_MEMORY the dispatch holds a `JeffJSFBRef`: an
// unmanaged pointer with forwarding accessors, every one a guaranteed
// (uncounted) read. The record is kept alive exactly as in quickjs: by the
// function object in the caller's stack slot / `frame.curFunc`, which the
// saved inline frames already rely on (InlineCallFrame.fb).
//
// Without the flag `JeffJSFBHandle` is the class itself and `handle` /
// `object` / `with` are identities, so the dispatch source is the same in
// both builds.

nonisolated extension JeffJSFunctionBytecode {
    /// Unretained view of `ic` (its bits; no field): the global-variable
    /// cache probes read the table without counting the cache object.
    @inline(__always) final var icU: Unmanaged<JeffJSInlineCache>? {
        unsafeBitCast(ic, to: UnsafeRawPointer?.self).map { Unmanaged<JeffJSInlineCache>.fromOpaque($0) }
    }
}

#if JEFFJS_MANUAL_MEMORY

nonisolated struct JeffJSFBRef {
    let u: Unmanaged<JeffJSFunctionBytecode>

    @inline(__always) init(u: Unmanaged<JeffJSFunctionBytecode>) { self.u = u }
    @inline(__always) init(_ fb: JeffJSFunctionBytecode) { self.u = Unmanaged.passUnretained(fb) }

    /// The record as a Swift reference (a retain for the reference's life):
    /// cold paths only.
    @inline(__always) var object: JeffJSFunctionBytecode { u.takeUnretainedValue() }
    @inline(__always) var handle: JeffJSFBRef { self }
    /// Runs `body` with the record borrowed (no retain).
    @inline(__always) func with<R>(_ body: (JeffJSFunctionBytecode) -> R) -> R {
        u._withUnsafeGuaranteedRef { body($0) }
    }
    @inline(__always) var identity: UnsafeRawPointer { UnsafeRawPointer(u.toOpaque()) }
    @inline(__always) var icEntries: UnsafeMutablePointer<JeffJSICEntry>? { u._withUnsafeGuaranteedRef { $0.icEntries } }
    @inline(__always) var isGenerator: Bool { u._withUnsafeGuaranteedRef { $0.isGenerator } }
    @inline(__always) var closureVarCount: UInt16 { u._withUnsafeGuaranteedRef { $0.closureVarCount } }
    @inline(__always) var cpool: [JeffJSValue] { u._withUnsafeGuaranteedRef { $0.cpool } }
    @inline(__always) var isAsyncFunc: Bool { u._withUnsafeGuaranteedRef { $0.isAsyncFunc } }
    @inline(__always) var isStrictMode: Bool { u._withUnsafeGuaranteedRef { $0.isStrictMode } }
    @inline(__always) var traceLean: Bool { u._withUnsafeGuaranteedRef { $0.traceLean } }
    @inline(__always) var copiesArgs: Bool { u._withUnsafeGuaranteedRef { $0.copiesArgs } }
    @inline(__always) var argCount: UInt16 { u._withUnsafeGuaranteedRef { $0.argCount } }
    @inline(__always) var selfRefVarIdx: Int { u._withUnsafeGuaranteedRef { $0.selfRefVarIdx } }
    @inline(__always) var varCount: UInt16 { u._withUnsafeGuaranteedRef { $0.varCount } }
    @inline(__always) var bytecodeLen: Int { u._withUnsafeGuaranteedRef { $0.bytecodeLen } }
    @inline(__always) var stackSize: UInt16 { u._withUnsafeGuaranteedRef { $0.stackSize } }
    @inline(__always) var nameAtom: UInt32 { u._withUnsafeGuaranteedRef { $0.nameAtom } }
    @inline(__always) var argSlotsOwned: Bool { u._withUnsafeGuaranteedRef { $0.argSlotsOwned } }
    @inline(__always) var isArrow: Bool { u._withUnsafeGuaranteedRef { $0.isArrow } }
    @inline(__always) var bytecodePtr: UnsafePointer<UInt8> { u._withUnsafeGuaranteedRef { $0.bytecodePtr } }
    @inline(__always) var lineNum: Int { u._withUnsafeGuaranteedRef { $0.lineNum } }
    @inline(__always) var cpoolRawCount: Int { u._withUnsafeGuaranteedRef { $0.cpoolRawCount } }
    @inline(__always) var bcPtrFast: UnsafePointer<UInt8>? { u._withUnsafeGuaranteedRef { $0.bcPtrFast } }
    @inline(__always) var _cpoolRaw: UnsafeMutablePointer<JeffJSValue>? { u._withUnsafeGuaranteedRef { $0._cpoolRaw } }
    @inline(__always) var definedArgCount: UInt16 { u._withUnsafeGuaranteedRef { $0.definedArgCount } }
    @inline(__always) var closureVarsList: [JeffJSClosureVar] { u._withUnsafeGuaranteedRef { $0.closureVarsList } }
    @inline(__always) var bytecode: [UInt8] { u._withUnsafeGuaranteedRef { $0.bytecode } }
    @inline(__always) var sourceLen: Int32 { u._withUnsafeGuaranteedRef { $0.sourceLen } }
    @inline(__always) var isDirectOrIndirectEval: Bool { u._withUnsafeGuaranteedRef { $0.isDirectOrIndirectEval } }
    @inline(__always) var isDerivedClassConstructor: Bool { u._withUnsafeGuaranteedRef { $0.isDerivedClassConstructor } }
    @inline(__always) var ic: JeffJSInlineCache? { u._withUnsafeGuaranteedRef { $0.ic } }
    @inline(__always) var traceBlocks: [Int: TraceBlockInfo]? { u._withUnsafeGuaranteedRef { $0.traceBlocks } }
    @inline(__always) var sourceText: JeffJSSourceText? { u._withUnsafeGuaranteedRef { $0.sourceText } }
    @inline(__always) var sourceStart: Int32 { u._withUnsafeGuaranteedRef { $0.sourceStart } }
    @inline(__always) var fileName: JeffJSString? { u._withUnsafeGuaranteedRef { $0.fileName } }
    @inline(__always) var traceEntryEnabled: Bool {
        get { u._withUnsafeGuaranteedRef { $0.traceEntryEnabled } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.traceEntryEnabled = newValue } }
    }
    @inline(__always) var traceEntryDeopts: UInt16 {
        get { u._withUnsafeGuaranteedRef { $0.traceEntryDeopts } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.traceEntryDeopts = newValue } }
    }
    @inline(__always) var liveClosures: Int32 {
        get { u._withUnsafeGuaranteedRef { $0.liveClosures } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.liveClosures = newValue } }
    }
    @inline(__always) var icU: Unmanaged<JeffJSInlineCache>? { u._withUnsafeGuaranteedRef { $0.icU } }
    @inline(__always) func getIC() -> JeffJSInlineCache { u._withUnsafeGuaranteedRef { $0.getIC() } }
    @inline(__always) func constant(_ i: Int) -> JeffJSValue { u._withUnsafeGuaranteedRef { $0.constant(i) } }
    @inline(__always) func traceBlock(at pc: Int) -> TraceBlockInfo? { u._withUnsafeGuaranteedRef { $0.traceBlock(at: pc) } }
}

typealias JeffJSFBHandle = JeffJSFBRef

nonisolated extension JeffJSFunctionBytecode {
    @inline(__always) final var handle: JeffJSFBRef { JeffJSFBRef(self) }
    @inline(__always) final var object: JeffJSFunctionBytecode { self }
    @inline(__always) final func with<R>(_ body: (JeffJSFunctionBytecode) -> R) -> R { body(self) }
    @inline(__always) final var identity: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()) }
}

nonisolated extension JeffJSObject {
    /// The function's bytecode record as the dispatch's handle (uncounted).
    @inline(__always) final var fbFastH: JeffJSFBRef? {
        if let u = fbFastU { return JeffJSFBRef(u: u) }
        return nil
    }
}

nonisolated extension JeffJSObj {
    @inline(__always) var fbFastH: JeffJSFBRef? {
        if let u = fbFastU { return JeffJSFBRef(u: u) }
        return nil
    }
}


#else

typealias JeffJSFBHandle = JeffJSFunctionBytecode

nonisolated extension JeffJSFunctionBytecode {
    @inline(__always) final var handle: JeffJSFunctionBytecode { self }
    @inline(__always) final var object: JeffJSFunctionBytecode { self }
    @inline(__always) final func with<R>(_ body: (JeffJSFunctionBytecode) -> R) -> R { body(self) }
    @inline(__always) final var identity: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()) }
}

nonisolated extension JeffJSObject {
    @inline(__always) final var fbFastH: JeffJSFunctionBytecode? { fbFast }
}

nonisolated extension JeffJSObj {
    @inline(__always) var fbFastH: JeffJSFunctionBytecode? { fbFast }
}


#endif
