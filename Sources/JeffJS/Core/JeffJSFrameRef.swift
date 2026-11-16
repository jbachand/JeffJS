import Foundation

// JeffJSFrameRef.swift
// JeffJS — the interpreter's handle on the running activation's frame
// (JeffJS issue #1 step 3, build flag JEFFJS_MANUAL_MEMORY).
//
// quickjs.c JS_CallInternal keeps the frame as a C struct on the native
// stack (`JSStackFrame sf_s, *sf = &sf_s`) and links it into
// `rt->current_stack_frame` with plain pointer stores: nothing is counted.
// Here a frame is a pooled Swift object (immortal: owned by the runtime's
// frame list, recycled through a free list), so no count is needed either,
// but the dispatch held it in an `unowned(unsafe) var`, and the compiler
// copies such a reference (a retain/release pair) around member reads, when
// it is passed to a function and when it is stored into another
// `unowned(unsafe)` slot: `ctx.currentFrame = frame.prevFrame` on every
// return, `HotState(frame: frame)` on every trace entry, the var-ref detach
// of every frame whose locals a closure captured.
//
// Under JEFFJS_MANUAL_MEMORY the dispatch holds a `JeffJSFrameRef`: an
// unmanaged pointer with forwarding accessors, every one a guaranteed
// (uncounted) access. Without the flag `JeffJSFrameHandle` is the class and
// `handle` / `object` / `unmanaged` / `with` are identities, so the dispatch
// source is the same in both builds.
//
// In both builds the frame links are unmanaged storage now:
// `JeffJSStackFrame.prevFrameU` and `JeffJSContext.currentFrameU`
// (`prevFrame` / `currentFrame` stay as computed views for cold readers).

#if JEFFJS_MANUAL_MEMORY

nonisolated struct JeffJSFrameRef {
    let u: Unmanaged<JeffJSStackFrame>

    @inline(__always) init(u: Unmanaged<JeffJSStackFrame>) { self.u = u }
    @inline(__always) init(_ f: JeffJSStackFrame) { self.u = Unmanaged.passUnretained(f) }

    /// The frame as a Swift reference (a retain for the reference's life):
    /// cold paths only.
    @inline(__always) var object: JeffJSStackFrame { u.takeUnretainedValue() }
    @inline(__always) var handle: JeffJSFrameRef { self }
    @inline(__always) var unmanaged: Unmanaged<JeffJSStackFrame> { u }
    /// Runs `body` with the frame borrowed (no retain).
    @inline(__always) func with<R>(_ body: (JeffJSStackFrame) -> R) -> R {
        u._withUnsafeGuaranteedRef { body($0) }
    }
    /// The caller's frame as a Swift reference (cold readers).
    @inline(__always) var prevFrame: JeffJSStackFrame? { u._withUnsafeGuaranteedRef { $0.prevFrame } }
    @inline(__always) func bindPendingArrows(_ constructed: JeffJSValue) {
        u._withUnsafeGuaranteedRef { $0.bindPendingArrows(constructed) }
    }
    @inline(__always) var thisVal: JeffJSValue {
        get { u._withUnsafeGuaranteedRef { $0.thisVal } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.thisVal = newValue } }
    }
    @inline(__always) var curFunc: JeffJSValue {
        get { u._withUnsafeGuaranteedRef { $0.curFunc } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.curFunc = newValue } }
    }
    @inline(__always) var buf: UnsafeMutablePointer<JeffJSValue>? {
        get { u._withUnsafeGuaranteedRef { $0.buf } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.buf = newValue } }
    }
    @inline(__always) var curPC: Int {
        get { u._withUnsafeGuaranteedRef { $0.curPC } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.curPC = newValue } }
    }
    @inline(__always) var nativeCalleePtr: UnsafeMutableRawPointer? {
        get { u._withUnsafeGuaranteedRef { $0.nativeCalleePtr } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.nativeCalleePtr = newValue } }
    }
    @inline(__always) var argBuf: [JeffJSValue] {
        get { u._withUnsafeGuaranteedRef { $0.argBuf } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.argBuf = newValue } }
    }
    @inline(__always) var bufVarBase: Int {
        get { u._withUnsafeGuaranteedRef { $0.bufVarBase } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.bufVarBase = newValue } }
    }
    @inline(__always) var argCount: Int {
        get { u._withUnsafeGuaranteedRef { $0.argCount } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.argCount = newValue } }
    }
    @inline(__always) var hasLiveVarRefs: Bool {
        get { u._withUnsafeGuaranteedRef { $0.hasLiveVarRefs } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.hasLiveVarRefs = newValue } }
    }
    @inline(__always) var varCount: Int {
        get { u._withUnsafeGuaranteedRef { $0.varCount } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.varCount = newValue } }
    }
    @inline(__always) var bufCapacity: Int {
        get { u._withUnsafeGuaranteedRef { $0.bufCapacity } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.bufCapacity = newValue } }
    }
    @inline(__always) var liveVarRefs: JeffJSVarRefList {
        get { u._withUnsafeGuaranteedRef { $0.liveVarRefs } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.liveVarRefs = newValue } }
    }
    @inline(__always) var spBase: Int {
        get { u._withUnsafeGuaranteedRef { $0.spBase } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.spBase = newValue } }
    }
    @inline(__always) var bufSpBase: Int {
        get { u._withUnsafeGuaranteedRef { $0.bufSpBase } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.bufSpBase = newValue } }
    }
    @inline(__always) var varBuf: [JeffJSValue] {
        get { u._withUnsafeGuaranteedRef { $0.varBuf } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.varBuf = newValue } }
    }
    @inline(__always) var bufArraysLive: Bool {
        get { u._withUnsafeGuaranteedRef { $0.bufArraysLive } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.bufArraysLive = newValue } }
    }
    @inline(__always) var ownsThis: Bool {
        get { u._withUnsafeGuaranteedRef { $0.ownsThis } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.ownsThis = newValue } }
    }
    @inline(__always) var ownsBuf: Bool {
        get { u._withUnsafeGuaranteedRef { $0.ownsBuf } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.ownsBuf = newValue } }
    }
    @inline(__always) var newTarget: JeffJSValue {
        get { u._withUnsafeGuaranteedRef { $0.newTarget } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.newTarget = newValue } }
    }
    @inline(__always) var hasPendingArrows: Bool {
        get { u._withUnsafeGuaranteedRef { $0.hasPendingArrows } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.hasPendingArrows = newValue } }
    }
    @inline(__always) var pendingArrows: [JeffJSValue] {
        get { u._withUnsafeGuaranteedRef { $0.pendingArrows } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.pendingArrows = newValue } }
    }
    @inline(__always) var prevFrameU: Unmanaged<JeffJSStackFrame>? {
        get { u._withUnsafeGuaranteedRef { $0.prevFrameU } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.prevFrameU = newValue } }
    }
    @inline(__always) var sp: Int {
        get { u._withUnsafeGuaranteedRef { $0.sp } }
        nonmutating set { u._withUnsafeGuaranteedRef { $0.sp = newValue } }
    }
}

typealias JeffJSFrameHandle = JeffJSFrameRef

nonisolated extension JeffJSStackFrame {
    @inline(__always) final var handle: JeffJSFrameRef { JeffJSFrameRef(self) }
    @inline(__always) final var object: JeffJSStackFrame { self }
    @inline(__always) final var unmanaged: Unmanaged<JeffJSStackFrame> { Unmanaged.passUnretained(self) }
    @inline(__always) final func with<R>(_ body: (JeffJSStackFrame) -> R) -> R { body(self) }
}

#else

typealias JeffJSFrameHandle = JeffJSStackFrame

nonisolated extension JeffJSStackFrame {
    @inline(__always) final var handle: JeffJSStackFrame { self }
    @inline(__always) final var object: JeffJSStackFrame { self }
    @inline(__always) final var unmanaged: Unmanaged<JeffJSStackFrame> { Unmanaged.passUnretained(self) }
    @inline(__always) final func with<R>(_ body: (JeffJSStackFrame) -> R) -> R { body(self) }
}

#endif
