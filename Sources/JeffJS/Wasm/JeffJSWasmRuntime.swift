// JeffJSWasmRuntime.swift
// JeffJS — WebAssembly (issue #13): instances and the interpreter.
//
// WebAssembly Core 2.0 §4 (execution). Values live in 64-bit slots as bit
// patterns: i32 / f32 zero-extended (so `i64.extend_i32_u` and the reinterprets
// are free), references as `WasmRefs` ids (0 = null). A frame is a window of the
// value stack: slots 0 ..< localCount are its locals, then its operand stack; a call
// puts the callee's frame on the caller's argument slots, so the results land
// where the caller expects them (JeffJSWasmCompiler.swift). Calls between wasm
// functions run in one loop with an explicit frame stack; imports call JS.
//
// A memory's bytes are the `data` of the JeffJSArrayBuffer `memory.buffer`
// exposes; `memory.grow` detaches that buffer and moves the bytes to a new one
// (JS API §5.2). The interpreter caches the bytes' address and re-reads it after
// every call out to JS (a typed-array write may have moved an array it shares).
//
// Copyright 2026 Jeff Bachand. All rights reserved.

import Foundation

nonisolated final class WasmMemory {
    var ab: JeffJSArrayBuffer
    var maxPages: UInt32?
    /// The ArrayBuffer object over `ab` (`memory.buffer`), made on first read; dropped at grow.
    var bufferObject: JeffJSValue = .undefined
    /// The JS `WebAssembly.Memory` object (identity across exports), set by the JS API.
    var jsObject: JeffJSValue = .undefined

    init(pages: UInt32, max: UInt32?) {
        ab = JeffJSArrayBuffer(byteLength: Int(pages) * 65536)
        maxPages = max
    }

    var pages: UInt32 { UInt32(ab.byteLength / 65536) }

    /// `memory.grow`: the old size in pages, or nil when it cannot grow. A successful grow, by 0
    /// pages too, detaches the old buffer (JS API "refresh the memory buffer"; V8 does the same for
    /// memory.grow in wasm); a failed one leaves it.
    func grow(by delta: UInt32) -> UInt32? {
        let old = pages
        let limit = min(maxPages ?? WasmDecoder.maxMemoryPages, WasmDecoder.maxMemoryPages)
        guard UInt64(old) + UInt64(delta) <= UInt64(limit) else { return nil }
        let newBytes = Int(old + delta) * 65536
        // Engines refuse growth they cannot back; so do we, past 1 GiB.
        guard newBytes <= 1 << 30 else { return nil }
        let fresh = JeffJSArrayBuffer(byteLength: 0)
        var data = ab.data
        ab.data = []
        ab.byteLength = 0
        ab.detached = true
        data.append(contentsOf: repeatElement(0, count: newBytes - data.count))
        fresh.data = data
        fresh.byteLength = newBytes
        ab = fresh
        bufferObject.freeValue()
        bufferObject = .undefined
        return old
    }
}

nonisolated final class WasmTable {
    let elemType: WasmValType
    var elems: [UInt64]
    var max: UInt32?
    var jsObject: JeffJSValue = .undefined

    init(type: WasmValType, size: UInt32, max: UInt32?, fill: UInt64 = 0) {
        elemType = type
        elems = [UInt64](repeating: fill, count: Int(size))
        self.max = max
    }

    func grow(by delta: UInt32, fill: UInt64) -> UInt32? {
        let old = UInt32(elems.count)
        let limit = min(max ?? WasmDecoder.maxTableSize, WasmDecoder.maxTableSize)
        guard UInt64(old) + UInt64(delta) <= UInt64(limit) else { return nil }
        elems.append(contentsOf: repeatElement(fill, count: Int(delta)))
        return old
    }
}

nonisolated final class WasmGlobal {
    let type: WasmGlobalType
    var bits: UInt64
    var jsObject: JeffJSValue = .undefined
    init(type: WasmGlobalType, bits: UInt64) { self.type = type; self.bits = bits }
}

/// A function: defined in an instance, or a host (JS) function imported into one.
nonisolated final class WasmFunction {
    let type: WasmFuncType
    unowned(unsafe) var instance: WasmInstance?
    /// Keeps `instance` alive while the function is reachable (a table, an exported JS function,
    /// another instance's imports): a failed instantiation's functions can outlive it in an imported
    /// table (linking.wast). The instance → function → instance cycle is broken by `WasmStore.release`.
    var instanceRef: WasmInstance?
    let code: WasmCompiledFunction?
    /// A host function: the JS callable and its realm.
    var host: JeffJSValue = .undefined
    unowned(unsafe) var hostCtx: JeffJSContext?
    /// The function's index in its module (exported functions are named after it).
    let index: Int
    /// The exported JS function object (identity across exports / tables), made on demand.
    var jsObject: JeffJSValue = .undefined
    /// The store of the realm the function was made in (owns its reference id).
    let store: WasmStore
    private var refIDStorage: UInt64 = 0
    /// The funcref bits of this function, registered on first use.
    var refID: UInt64 {
        if refIDStorage == 0 { refIDStorage = WasmRefs.shared.register(self, store: store) }
        return refIDStorage
    }

    init(type: WasmFuncType, instance: WasmInstance?, code: WasmCompiledFunction?, index: Int, store: WasmStore) {
        self.type = type
        self.instance = instance
        self.instanceRef = instance
        self.code = code
        self.index = index
        self.store = store
    }
}

/// Reference values (funcref / externref) as slot bits: an id into this table, 0 = null. Ids are
/// never reused; an entry lives until the store that registered it is released, after which its id
/// reads as null.
nonisolated final class WasmRefs {
    nonisolated(unsafe) static let shared = WasmRefs()
    private var objects: [UInt64: AnyObject] = [:]
    private var next: UInt64 = 1
    private let lock = NSLock()

    final class Extern {
        let value: JeffJSValue
        init(_ v: JeffJSValue) { value = v.dupValue() }
        deinit { value.freeValue() }
    }

    func register(_ o: AnyObject, store: WasmStore) -> UInt64 {
        lock.lock()
        let id = next
        next += 1
        objects[id] = o
        lock.unlock()
        store.refIDs.append(id)
        return id
    }

    func unregister(_ ids: [UInt64]) {
        lock.lock()
        var dropped: [AnyObject] = []   // released after the lock (an Extern's deinit frees a JS value)
        dropped.reserveCapacity(ids.count)
        for id in ids { if let o = objects.removeValue(forKey: id) { dropped.append(o) } }
        lock.unlock()
        dropped.removeAll()
    }

    func object(_ id: UInt64) -> AnyObject? {
        guard id != 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        return objects[id]
    }

    func function(_ id: UInt64) -> WasmFunction? { object(id) as? WasmFunction }

    /// An externref for a JS value (null → 0); one id per object per store.
    func extern(_ v: JeffJSValue, store: WasmStore) -> UInt64 {
        if v.isNull { return 0 }
        guard let o = v.toObject() else { return register(Extern(v), store: store) }
        let key = ObjectIdentifier(o)
        if let id = store.externIDs[key] { return id }
        let id = register(Extern(v), store: store)
        store.externIDs[key] = id
        return id
    }
}

/// The store (Core §4.2.1) of one realm: the instances, host functions, reference ids and JS
/// wrappers made in it. Swift objects here hold JS values (an exported function's JS object, a
/// memory's handle, an externref) that hold them back, a cycle the JS collector cannot see, so the
/// whole store lives until its realm is freed (`JeffJSContext.free`), which calls `release`.
nonisolated final class WasmStore {
    var instances: [WasmInstance] = []
    var hostFunctions: [WasmFunction] = []
    var refIDs: [UInt64] = []
    var externIDs: [ObjectIdentifier: UInt64] = [:]
    /// Exported function objects listed in `WasmJSAPI.exported` by this realm.
    var exportedKeys: [ObjectIdentifier] = []
    /// Functions, memories, tables and globals whose JS objects were made in this realm.
    var wrapped: [AnyObject] = []
    var errorCtors: (compile: JeffJSValue, link: JeffJSValue, runtime: JeffJSValue)?

    static func of(_ ctx: JeffJSContext) -> WasmStore {
        if let s = ctx.wasmStore { return s }
        let s = WasmStore()
        ctx.wasmStore = s
        return s
    }

    /// The realm is going away: drop every JS value held from Swift and break the instance cycles.
    /// A function another realm still holds keeps its (now dead) instance; calling it traps.
    func release() {
        WasmJSAPI.forgetExported(exportedKeys)
        exportedKeys = []
        for o in wrapped {
            switch o {
            case let f as WasmFunction: f.jsObject.freeValue(); f.jsObject = .undefined
            case let m as WasmMemory:
                m.jsObject.freeValue(); m.jsObject = .undefined
                m.bufferObject.freeValue(); m.bufferObject = .undefined
            case let t as WasmTable: t.jsObject.freeValue(); t.jsObject = .undefined
            case let g as WasmGlobal: g.jsObject.freeValue(); g.jsObject = .undefined
            default: break
            }
        }
        wrapped = []
        for f in hostFunctions { f.host.freeValue(); f.host = .undefined; f.hostCtx = nil }
        hostFunctions = []
        for inst in instances {
            inst.dead = true
            inst.functions = []
            inst.tables = []
            inst.memories = []
            inst.globals = []
        }
        instances = []
        let ids = refIDs
        refIDs = []
        externIDs = [:]
        WasmRefs.shared.unregister(ids)
        if let e = errorCtors { e.compile.freeValue(); e.link.freeValue(); e.runtime.freeValue() }
        errorCtors = nil
    }
}

nonisolated final class WasmInstance {
    let module: WasmModule
    var functions: [WasmFunction] = []
    var tables: [WasmTable] = []
    var memories: [WasmMemory] = []
    var globals: [WasmGlobal] = []
    var droppedData: [Bool] = []
    var droppedElems: [Bool] = []
    /// The realm the instance was made in (host calls, exported functions).
    unowned(unsafe) let ctx: JeffJSContext
    let store: WasmStore
    /// Set when the realm's store was released: the instance's state is gone, calls into it trap.
    var dead = false

    init(module: WasmModule, ctx: JeffJSContext) {
        self.module = module
        self.ctx = ctx
        self.store = WasmStore.of(ctx)
    }

    /// Instantiation (§4.5.4) after the imports were resolved and type-checked by the JS API:
    /// globals, tables, memories, element and data segments, then the start function.
    func initialize(importedFunctions: [WasmFunction], importedTables: [WasmTable],
                    importedMemories: [WasmMemory], importedGlobals: [WasmGlobal]) throws {
        let m = module
        functions = importedFunctions
        for (i, code) in m.code.enumerated() {
            let idx = m.importedFuncCount + i
            functions.append(WasmFunction(type: m.types[m.funcTypes[idx]], instance: self, code: code, index: idx, store: store))
        }
        globals = importedGlobals
        for def in m.globalDefs {
            globals.append(WasmGlobal(type: def.type, bits: evalConst(def.initExpr)))
        }
        tables = importedTables
        for t in m.tables.dropFirst(m.importedTableCount) {
            tables.append(WasmTable(type: t.elem, size: t.limits.min, max: t.limits.max))
        }
        memories = importedMemories
        for l in m.memories.dropFirst(m.importedMemoryCount) {
            memories.append(WasmMemory(pages: l.min, max: l.max))
        }
        droppedData = [Bool](repeating: false, count: m.datas.count)
        droppedElems = [Bool](repeating: false, count: m.elems.count)
        // Element segments (active: copied, then dropped; declarative: dropped).
        for (i, seg) in m.elems.enumerated() {
            switch seg.mode {
            case .active(let t, let off):
                let offset = UInt32(truncatingIfNeeded: evalConst(off))
                let table = tables[t]
                guard UInt64(offset) + UInt64(seg.items.count) <= UInt64(table.elems.count) else {
                    throw WasmError.trap("Out of bounds table access")
                }
                for (k, item) in seg.items.enumerated() { table.elems[Int(offset) + k] = evalConst(item) }
                droppedElems[i] = true
            case .declarative: droppedElems[i] = true
            case .passive: break
            }
        }
        for (i, seg) in m.datas.enumerated() {
            guard case .active(let mi, let off) = seg.mode else { continue }
            let offset = UInt32(truncatingIfNeeded: evalConst(off))
            let mem = memories[mi]
            guard UInt64(offset) + UInt64(seg.bytes.count) <= UInt64(mem.ab.byteLength) else {
                throw WasmError.trap("Out of bounds memory access")
            }
            if !seg.bytes.isEmpty {
                mem.ab.data.withUnsafeMutableBytes { raw in
                    seg.bytes.withUnsafeBytes { src in
                        raw.baseAddress!.advanced(by: Int(offset)).copyMemory(from: src.baseAddress!, byteCount: seg.bytes.count)
                    }
                }
            }
            droppedData[i] = true
        }
        if let s = m.start {
            _ = try WasmInterpreter.invoke(functions[s], args: [], ctx: ctx)
        }
    }

    func evalConst(_ e: WasmConstExpr) -> UInt64 {
        switch e {
        case .i32(let v): return UInt64(UInt32(bitPattern: v))
        case .i64(let v): return UInt64(bitPattern: v)
        case .f32(let b): return UInt64(b)
        case .f64(let b): return b
        case .globalGet(let g): return globals[g].bits
        case .refNull: return 0
        case .refFunc(let f): return functions[f].refID
        case .program(let ops):
            var st: [UInt64] = []
            for op in ops {
                switch op {
                case .push(let e): st.append(evalConst(e))
                default:
                    let b = st.removeLast(), a = st.removeLast()
                    switch op {
                    case .i32Add: st.append(UInt64(UInt32(truncatingIfNeeded: a) &+ UInt32(truncatingIfNeeded: b)))
                    case .i32Sub: st.append(UInt64(UInt32(truncatingIfNeeded: a) &- UInt32(truncatingIfNeeded: b)))
                    case .i32Mul: st.append(UInt64(UInt32(truncatingIfNeeded: a) &* UInt32(truncatingIfNeeded: b)))
                    case .i64Add: st.append(a &+ b)
                    case .i64Sub: st.append(a &- b)
                    case .i64Mul: st.append(a &* b)
                    case .push: break
                    }
                }
            }
            return st.last ?? 0
        }
    }
}

/// The value stack shared by every wasm call on one thread (re-entered calls stack up).
nonisolated final class WasmStack {
    static let slots = 1 << 19   // 4 MiB of 64-bit slots
    let base: UnsafeMutablePointer<UInt64>
    var top: Int = 0   // first free slot
    var depth = 0

    init() {
        base = UnsafeMutablePointer<UInt64>.allocate(capacity: Self.slots)
        base.initialize(repeating: 0, count: Self.slots)
    }
    deinit { base.deallocate() }

    static func current() -> WasmStack {
        let key = "jeffjs.wasm.stack"
        if let s = Thread.current.threadDictionary[key] as? WasmStack { return s }
        let s = WasmStack()
        Thread.current.threadDictionary[key] = s
        return s
    }
}

nonisolated enum WasmInterpreter {
    /// Calls deeper than this (wasm frames, across re-entries) are a stack overflow.
    static let maxFrames = 20_000

    /// Calls `f` with `args` (slot bits); returns the results' bits.
    static func invoke(_ f: WasmFunction, args: [UInt64], ctx: JeffJSContext) throws -> [UInt64] {
        if f.code == nil { return try callHost(f, args: args) }
        if f.instance?.dead ?? true { throw WasmError.trap(deadRealm) }
        let stack = WasmStack.current()
        let fp = stack.top
        guard let code = f.code, fp + code.frameSize < WasmStack.slots else { throw WasmError.stackOverflow }
        for (i, a) in args.enumerated() { stack.base[fp + i] = a }
        let saved = stack.top
        defer { stack.top = saved }
        try run(f, fp: fp, stack: stack)
        let n = f.type.results.count
        return (0..<n).map { stack.base[fp + $0] }
    }

    /// A host function called from wasm or through `invoke`: wasm values to JS, the call, the result back.
    static func callHost(_ f: WasmFunction, args: [UInt64]) throws -> [UInt64] {
        guard let ctx = f.hostCtx else { throw WasmError.trap("call to a function with no realm") }
        var jsArgs: [JeffJSValue] = []
        jsArgs.reserveCapacity(args.count)
        for (i, t) in f.type.params.enumerated() { jsArgs.append(WasmJSAPI.toJS(args[i], t, ctx: ctx)) }
        let r = ctx.callFunction(f.host, thisVal: .undefined, args: jsArgs)
        for v in jsArgs { v.freeValue() }
        if r.isException { throw WasmError.jsException }
        defer { r.freeValue() }
        let results = f.type.results
        if results.isEmpty { return [] }
        if results.count == 1 {
            return [try WasmJSAPI.toWasm(r, results[0], ctx: ctx)]
        }
        // Multi-value: the result is iterated (JS API §4.3 "run a host function" step 9).
        guard let list = WasmJSAPI.iterableToList(r, ctx: ctx) else { throw WasmError.jsException }
        defer { for v in list { v.freeValue() } }
        guard list.count == results.count else {
            _ = ctx.throwTypeError("Incorrect number of values returned to WebAssembly from JavaScript")
            throw WasmError.jsException
        }
        return try zip(list, results).map { try WasmJSAPI.toWasm($0, $1, ctx: ctx) }
    }

    private struct Frame {
        var fn: WasmFunction
        var pc: Int
        var fp: Int
    }

    @inline(__always) static func f32(_ b: UInt64) -> Float { Float(bitPattern: UInt32(truncatingIfNeeded: b)) }
    @inline(__always) static func f64(_ b: UInt64) -> Double { Double(bitPattern: b) }
    @inline(__always) static func bits(_ v: Float) -> UInt64 { UInt64(v.bitPattern) }
    @inline(__always) static func bits(_ v: Double) -> UInt64 { v.bitPattern }
    @inline(__always) static func u32(_ b: UInt64) -> UInt32 { UInt32(truncatingIfNeeded: b) }
    @inline(__always) static func i32(_ b: UInt64) -> Int32 { Int32(truncatingIfNeeded: b) }
    @inline(__always) static func z(_ v: UInt32) -> UInt64 { UInt64(v) }
    @inline(__always) static func z(_ v: Int32) -> UInt64 { UInt64(UInt32(bitPattern: v)) }
    @inline(__always) static func b(_ v: Bool) -> UInt64 { v ? 1 : 0 }

    static func fmin<T: BinaryFloatingPoint>(_ a: T, _ b: T) -> T {
        if a.isNaN || b.isNaN { return T.nan }
        if a == 0 && b == 0 { return a.sign == .minus ? a : b }
        return a < b ? a : b
    }
    static func fmax<T: BinaryFloatingPoint>(_ a: T, _ b: T) -> T {
        if a.isNaN || b.isNaN { return T.nan }
        if a == 0 && b == 0 { return a.sign == .minus ? b : a }
        return a > b ? a : b
    }

    static let truncTrap = "Out of bounds Trunc operation"
    static let deadRealm = "call to a function whose realm was destroyed"

    /// Truncation to an integer range [lo, hi): the value if in range, nil otherwise (NaN included).
    @inline(__always) static func truncIn(_ v: Double, _ lo: Double, _ hi: Double) -> Double? {
        guard !v.isNaN else { return nil }
        let t = v.rounded(.towardZero)
        guard t >= lo, t < hi else { return nil }
        return t
    }

    @inline(__always) static func satI32(_ v: Double) -> Int32 {
        if v.isNaN { return 0 }
        if v <= -2147483648.0 { return Int32.min }
        if v >= 2147483648.0 { return Int32.max }
        return Int32(v.rounded(.towardZero))
    }
    @inline(__always) static func satU32(_ v: Double) -> UInt32 {
        if v.isNaN || v <= -1 { return 0 }
        if v >= 4294967296.0 { return UInt32.max }
        return UInt32(v.rounded(.towardZero))
    }
    @inline(__always) static func satI64(_ v: Double) -> Int64 {
        if v.isNaN { return 0 }
        if v <= -9223372036854775808.0 { return Int64.min }
        if v >= 9223372036854775808.0 { return Int64.max }
        return Int64(v.rounded(.towardZero))
    }
    @inline(__always) static func satU64(_ v: Double) -> UInt64 {
        if v.isNaN || v <= -1 { return 0 }
        if v >= 18446744073709551616.0 { return UInt64.max }
        return UInt64(v.rounded(.towardZero))
    }

    /// u64 → f32 with one rounding (Float(UInt64) is correctly rounded in Swift).
    @inline(__always) static func u64ToF32(_ v: UInt64) -> Float { Float(v) }

    /// The memory's bytes (address, size) for the interpreter; re-read after anything that may move them.
    @inline(__always)
    private static func memoryView(_ inst: WasmInstance) -> (UnsafeMutablePointer<UInt8>?, Int) {
        guard let m = inst.memories.first, !m.ab.data.isEmpty else { return (nil, 0) }
        let p = m.ab.data.withUnsafeMutableBufferPointer { $0.baseAddress }
        return (p, m.ab.byteLength)
    }

    /// A callee's frame at slot `f`: room checked, non-parameter locals zeroed.
    @inline(__always)
    private static func enterFrame(_ c: WasmCompiledFunction, at f: Int, stack: WasmStack) throws {
        guard f + c.frameSize < WasmStack.slots else { throw WasmError.stackOverflow }
        if c.localCount > c.paramCount {
            (stack.base + f + c.paramCount).update(repeating: 0, count: c.localCount - c.paramCount)
        }
        stack.top = max(stack.top, f + c.frameSize)
    }

    /// The effective address of an access of `size` bytes, or a trap.
    @inline(__always)
    private static func ea(_ addr: UInt64, _ off: UInt64, _ memSize: Int, _ size: Int) throws -> Int {
        let e = (addr & 0xFFFF_FFFF) &+ off
        guard e &+ UInt64(size) <= UInt64(memSize) else { throw WasmError.trap("Out of bounds memory access") }
        return Int(e)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func run(_ entry: WasmFunction, fp entryFP: Int, stack: WasmStack) throws {
        var frames: [Frame] = []
        var fn = entry
        var code = entry.code!
        var fp = entryFP
        var pc = 0
        var inst = entry.instance!
        var mem: UnsafeMutablePointer<UInt8>? = nil
        var memSize = 0
        let S = stack.base
        stack.depth += 1
        defer { stack.depth -= 1 }
        if stack.depth > maxFrames { throw WasmError.stackOverflow }

        try enterFrame(code, at: fp, stack: stack)
        (mem, memSize) = memoryView(inst)

        var instrs = code.code
        while true {
            let ins = instrs[pc]
            pc += 1
            let s = fp + Int(ins.s)
            switch ins.op {
            case .unreachable: throw WasmError.trap("Unreachable code should not be executed")
            case .jump: pc = Int(ins.a)
            case .br:
                let keep = Int(ins.b & 0xFFFF_FFFF), src = fp + Int(ins.b >> 32)
                if keep > 0, src != s { (S + s).update(from: S + src, count: keep) }
                pc = Int(ins.a)
            case .brIf:
                let keep = Int(ins.b & 0xFFFF_FFFF), src = fp + Int(ins.b >> 32)
                if u32(S[src + keep]) != 0 {
                    if keep > 0, src != s { (S + s).update(from: S + src, count: keep) }
                    pc = Int(ins.a)
                }
            case .brUnless:
                if u32(S[s]) == 0 { pc = Int(ins.a) }
            case .brTable:
                let n = Int(ins.b)
                var idx = Int(u32(S[s + Int(code.branchTables[Int(ins.a)].keep)]))
                if idx > n { idx = n }
                let t = code.branchTables[Int(ins.a) + idx]
                let dest = fp + Int(t.dest), keep = Int(t.keep)
                if keep > 0, s != dest { (S + dest).update(from: S + s, count: keep) }
                pc = Int(t.pc)
            case .ret:
                let keep = Int(ins.b & 0xFFFF_FFFF), src = fp + Int(ins.b >> 32)
                if keep > 0, src != fp { (S + fp).update(from: S + src, count: keep) }
                guard let caller = frames.popLast() else { return }
                fn = caller.fn
                code = fn.code!
                instrs = code.code
                pc = caller.pc
                fp = caller.fp
                if fn.instance !== inst { inst = fn.instance!; (mem, memSize) = memoryView(inst) }
            case .call, .callIndirect:
                let callee: WasmFunction
                if ins.op == .call {
                    callee = inst.functions[Int(ins.a)]
                } else {
                    let table = inst.tables[Int(ins.b)]
                    let type = inst.module.types[Int(ins.a)]
                    let i = Int(u32(S[s + type.params.count]))
                    guard i < table.elems.count else { throw WasmError.trap("Out of bounds call_indirect") }
                    let ref = table.elems[i]
                    guard ref != 0, let f = WasmRefs.shared.function(ref) else {
                        throw WasmError.trap("call_indirect to a null table entry")
                    }
                    guard f.type == type else { throw WasmError.trap("call_indirect to a signature that does not match") }
                    callee = f
                }
                if let c = callee.code {
                    guard frames.count + stack.depth < maxFrames else { throw WasmError.stackOverflow }
                    frames.append(Frame(fn: fn, pc: pc, fp: fp))
                    try enterFrame(c, at: s, stack: stack)
                    fn = callee
                    code = c
                    instrs = c.code
                    pc = 0
                    fp = s
                    if callee.instance !== inst {
                        guard let ci = callee.instance, !ci.dead else { throw WasmError.trap(deadRealm) }
                        inst = ci
                        (mem, memSize) = memoryView(inst)
                    }
                } else {
                    let n = callee.type.params.count
                    let args = (0..<n).map { S[s + $0] }
                    let savedTop = stack.top
                    let results = try callHost(callee, args: args)
                    stack.top = savedTop
                    for (i, r) in results.enumerated() { S[s + i] = r }
                    (mem, memSize) = memoryView(inst)
                }
            case .localGet: S[s] = S[fp + Int(ins.a)]
            case .localSet: S[fp + Int(ins.a)] = S[s]
            case .localTee: S[fp + Int(ins.a)] = S[s]
            case .copySlot: S[s] = S[fp + Int(ins.a)]
            case .globalGet: S[s] = inst.globals[Int(ins.a)].bits
            case .globalSet: inst.globals[Int(ins.a)].bits = S[s]
            case .select: if u32(S[s + 2]) == 0 { S[s] = S[s + 1] }
            case .const_: S[s] = ins.b

            case .i32Load: let e = try ea(S[s], ins.b, memSize, 4); S[s] = z(UnsafeRawPointer(mem! + e).loadUnaligned(as: UInt32.self))
            case .i64Load: let e = try ea(S[s], ins.b, memSize, 8); S[s] = UnsafeRawPointer(mem! + e).loadUnaligned(as: UInt64.self)
            case .f32Load: let e = try ea(S[s], ins.b, memSize, 4); S[s] = z(UnsafeRawPointer(mem! + e).loadUnaligned(as: UInt32.self))
            case .f64Load: let e = try ea(S[s], ins.b, memSize, 8); S[s] = UnsafeRawPointer(mem! + e).loadUnaligned(as: UInt64.self)
            case .i32Load8S: let e = try ea(S[s], ins.b, memSize, 1); S[s] = z(Int32(Int8(bitPattern: mem![e])))
            case .i32Load8U: let e = try ea(S[s], ins.b, memSize, 1); S[s] = UInt64(mem![e])
            case .i32Load16S: let e = try ea(S[s], ins.b, memSize, 2); S[s] = z(Int32(UnsafeRawPointer(mem! + e).loadUnaligned(as: Int16.self)))
            case .i32Load16U: let e = try ea(S[s], ins.b, memSize, 2); S[s] = UInt64(UnsafeRawPointer(mem! + e).loadUnaligned(as: UInt16.self))
            case .i64Load8S: let e = try ea(S[s], ins.b, memSize, 1); S[s] = UInt64(bitPattern: Int64(Int8(bitPattern: mem![e])))
            case .i64Load8U: let e = try ea(S[s], ins.b, memSize, 1); S[s] = UInt64(mem![e])
            case .i64Load16S: let e = try ea(S[s], ins.b, memSize, 2); S[s] = UInt64(bitPattern: Int64(UnsafeRawPointer(mem! + e).loadUnaligned(as: Int16.self)))
            case .i64Load16U: let e = try ea(S[s], ins.b, memSize, 2); S[s] = UInt64(UnsafeRawPointer(mem! + e).loadUnaligned(as: UInt16.self))
            case .i64Load32S: let e = try ea(S[s], ins.b, memSize, 4); S[s] = UInt64(bitPattern: Int64(UnsafeRawPointer(mem! + e).loadUnaligned(as: Int32.self)))
            case .i64Load32U: let e = try ea(S[s], ins.b, memSize, 4); S[s] = UInt64(UnsafeRawPointer(mem! + e).loadUnaligned(as: UInt32.self))
            case .i32Store, .f32Store:
                let e = try ea(S[s], ins.b, memSize, 4); UnsafeMutableRawPointer(mem! + e).storeBytes(of: u32(S[s + 1]), as: UInt32.self)
            case .i64Store, .f64Store:
                let e = try ea(S[s], ins.b, memSize, 8); UnsafeMutableRawPointer(mem! + e).storeBytes(of: S[s + 1], as: UInt64.self)
            case .i32Store8, .i64Store8:
                let e = try ea(S[s], ins.b, memSize, 1); mem![e] = UInt8(truncatingIfNeeded: S[s + 1])
            case .i32Store16, .i64Store16:
                let e = try ea(S[s], ins.b, memSize, 2); UnsafeMutableRawPointer(mem! + e).storeBytes(of: UInt16(truncatingIfNeeded: S[s + 1]), as: UInt16.self)
            case .i64Store32:
                let e = try ea(S[s], ins.b, memSize, 4); UnsafeMutableRawPointer(mem! + e).storeBytes(of: UInt32(truncatingIfNeeded: S[s + 1]), as: UInt32.self)
            case .memorySize: S[s] = z(inst.memories[0].pages)
            case .memoryGrow:
                let m = inst.memories[0]
                if let old = m.grow(by: u32(S[s])) { S[s] = z(old) } else { S[s] = z(UInt32.max) }
                (mem, memSize) = memoryView(inst)
            case .memoryInit:
                let seg = inst.module.datas[Int(ins.a)]
                let d = UInt64(u32(S[s])), sOff = UInt64(u32(S[s + 1])), n = UInt64(u32(S[s + 2]))
                let len = inst.droppedData[Int(ins.a)] ? 0 : UInt64(seg.bytes.count)
                guard sOff + n <= len, d + n <= UInt64(memSize) else { throw WasmError.trap("Out of bounds memory access") }
                if n > 0 {
                    seg.bytes.withUnsafeBytes { src in
                        UnsafeMutableRawPointer(mem! + Int(d)).copyMemory(from: src.baseAddress! + Int(sOff), byteCount: Int(n))
                    }
                }
            case .dataDrop: inst.droppedData[Int(ins.a)] = true
            case .memoryCopy:
                let d = UInt64(u32(S[s])), src = UInt64(u32(S[s + 1])), n = UInt64(u32(S[s + 2]))
                guard src + n <= UInt64(memSize), d + n <= UInt64(memSize) else { throw WasmError.trap("Out of bounds memory access") }
                if n > 0 { memmove(mem! + Int(d), mem! + Int(src), Int(n)) }
            case .memoryFill:
                let d = UInt64(u32(S[s])), v = UInt8(truncatingIfNeeded: S[s + 1]), n = UInt64(u32(S[s + 2]))
                guard d + n <= UInt64(memSize) else { throw WasmError.trap("Out of bounds memory access") }
                if n > 0 { memset(mem! + Int(d), Int32(v), Int(n)) }

            case .tableGet:
                let t = inst.tables[Int(ins.a)], i = Int(u32(S[s]))
                guard i < t.elems.count else { throw WasmError.trap("Out of bounds table access") }
                S[s] = t.elems[i]
            case .tableSet:
                let t = inst.tables[Int(ins.a)], i = Int(u32(S[s]))
                guard i < t.elems.count else { throw WasmError.trap("Out of bounds table access") }
                t.elems[i] = S[s + 1]
            case .tableSize: S[s] = UInt64(inst.tables[Int(ins.a)].elems.count)
            case .tableGrow:
                let t = inst.tables[Int(ins.a)]
                if let old = t.grow(by: u32(S[s + 1]), fill: S[s]) { S[s] = z(old) } else { S[s] = z(UInt32.max) }
            case .tableFill:
                let t = inst.tables[Int(ins.a)]
                let i = UInt64(u32(S[s])), v = S[s + 1], n = UInt64(u32(S[s + 2]))
                guard i + n <= UInt64(t.elems.count) else { throw WasmError.trap("Out of bounds table access") }
                for k in 0..<Int(n) { t.elems[Int(i) + k] = v }
            case .tableCopy:
                let dt = inst.tables[Int(ins.a)], st = inst.tables[Int(ins.b)]
                let d = UInt64(u32(S[s])), src = UInt64(u32(S[s + 1])), n = UInt64(u32(S[s + 2]))
                guard src + n <= UInt64(st.elems.count), d + n <= UInt64(dt.elems.count) else { throw WasmError.trap("Out of bounds table access") }
                let tmp = Array(st.elems[Int(src)..<Int(src + n)])
                for k in 0..<Int(n) { dt.elems[Int(d) + k] = tmp[k] }
            case .tableInit:
                let segIndex = Int(ins.a)
                let seg = inst.module.elems[segIndex]
                let t = inst.tables[Int(ins.b)]
                let d = UInt64(u32(S[s])), src = UInt64(u32(S[s + 1])), n = UInt64(u32(S[s + 2]))
                let len = inst.droppedElems[segIndex] ? 0 : UInt64(seg.items.count)
                guard src + n <= len, d + n <= UInt64(t.elems.count) else { throw WasmError.trap("Out of bounds table access") }
                for k in 0..<Int(n) { t.elems[Int(d) + k] = inst.evalConst(seg.items[Int(src) + k]) }
            case .elemDrop: inst.droppedElems[Int(ins.a)] = true
            case .refNull: S[s] = 0
            case .refIsNull: S[s] = b(S[s] == 0)
            case .refFunc: S[s] = inst.functions[Int(ins.a)].refID

            case .i32Eqz: S[s] = b(u32(S[s]) == 0)
            case .i32Eq: S[s] = b(u32(S[s]) == u32(S[s + 1]))
            case .i32Ne: S[s] = b(u32(S[s]) != u32(S[s + 1]))
            case .i32LtS: S[s] = b(i32(S[s]) < i32(S[s + 1]))
            case .i32LtU: S[s] = b(u32(S[s]) < u32(S[s + 1]))
            case .i32GtS: S[s] = b(i32(S[s]) > i32(S[s + 1]))
            case .i32GtU: S[s] = b(u32(S[s]) > u32(S[s + 1]))
            case .i32LeS: S[s] = b(i32(S[s]) <= i32(S[s + 1]))
            case .i32LeU: S[s] = b(u32(S[s]) <= u32(S[s + 1]))
            case .i32GeS: S[s] = b(i32(S[s]) >= i32(S[s + 1]))
            case .i32GeU: S[s] = b(u32(S[s]) >= u32(S[s + 1]))
            case .i64Eqz: S[s] = b(S[s] == 0)
            case .i64Eq: S[s] = b(S[s] == S[s + 1])
            case .i64Ne: S[s] = b(S[s] != S[s + 1])
            case .i64LtS: S[s] = b(Int64(bitPattern: S[s]) < Int64(bitPattern: S[s + 1]))
            case .i64LtU: S[s] = b(S[s] < S[s + 1])
            case .i64GtS: S[s] = b(Int64(bitPattern: S[s]) > Int64(bitPattern: S[s + 1]))
            case .i64GtU: S[s] = b(S[s] > S[s + 1])
            case .i64LeS: S[s] = b(Int64(bitPattern: S[s]) <= Int64(bitPattern: S[s + 1]))
            case .i64LeU: S[s] = b(S[s] <= S[s + 1])
            case .i64GeS: S[s] = b(Int64(bitPattern: S[s]) >= Int64(bitPattern: S[s + 1]))
            case .i64GeU: S[s] = b(S[s] >= S[s + 1])
            case .f32Eq: S[s] = b(f32(S[s]) == f32(S[s + 1]))
            case .f32Ne: S[s] = b(f32(S[s]) != f32(S[s + 1]))
            case .f32Lt: S[s] = b(f32(S[s]) < f32(S[s + 1]))
            case .f32Gt: S[s] = b(f32(S[s]) > f32(S[s + 1]))
            case .f32Le: S[s] = b(f32(S[s]) <= f32(S[s + 1]))
            case .f32Ge: S[s] = b(f32(S[s]) >= f32(S[s + 1]))
            case .f64Eq: S[s] = b(f64(S[s]) == f64(S[s + 1]))
            case .f64Ne: S[s] = b(f64(S[s]) != f64(S[s + 1]))
            case .f64Lt: S[s] = b(f64(S[s]) < f64(S[s + 1]))
            case .f64Gt: S[s] = b(f64(S[s]) > f64(S[s + 1]))
            case .f64Le: S[s] = b(f64(S[s]) <= f64(S[s + 1]))
            case .f64Ge: S[s] = b(f64(S[s]) >= f64(S[s + 1]))

            case .i32Clz: S[s] = UInt64(u32(S[s]).leadingZeroBitCount)
            case .i32Ctz: S[s] = UInt64(u32(S[s]).trailingZeroBitCount)
            case .i32Popcnt: S[s] = UInt64(u32(S[s]).nonzeroBitCount)
            case .i32Add: S[s] = z(u32(S[s]) &+ u32(S[s + 1]))
            case .i32Sub: S[s] = z(u32(S[s]) &- u32(S[s + 1]))
            case .i32Mul: S[s] = z(u32(S[s]) &* u32(S[s + 1]))
            case .i32DivS:
                let a = i32(S[s]), c = i32(S[s + 1])
                guard c != 0 else { throw WasmError.trap("Division by zero") }
                guard !(a == Int32.min && c == -1) else { throw WasmError.trap("Integer overflow") }
                S[s] = z(a / c)
            case .i32DivU:
                let c = u32(S[s + 1])
                guard c != 0 else { throw WasmError.trap("Division by zero") }
                S[s] = z(u32(S[s]) / c)
            case .i32RemS:
                let a = i32(S[s]), c = i32(S[s + 1])
                guard c != 0 else { throw WasmError.trap("Remainder by zero") }
                S[s] = c == -1 ? 0 : z(a % c)
            case .i32RemU:
                let c = u32(S[s + 1])
                guard c != 0 else { throw WasmError.trap("Remainder by zero") }
                S[s] = z(u32(S[s]) % c)
            case .i32And: S[s] = z(u32(S[s]) & u32(S[s + 1]))
            case .i32Or: S[s] = z(u32(S[s]) | u32(S[s + 1]))
            case .i32Xor: S[s] = z(u32(S[s]) ^ u32(S[s + 1]))
            case .i32Shl: S[s] = z(u32(S[s]) &<< (u32(S[s + 1]) & 31))
            case .i32ShrS: S[s] = z(i32(S[s]) &>> Int32(u32(S[s + 1]) & 31))
            case .i32ShrU: S[s] = z(u32(S[s]) &>> (u32(S[s + 1]) & 31))
            case .i32Rotl:
                let v = u32(S[s]), k = u32(S[s + 1]) & 31
                S[s] = z((v &<< k) | (v &>> ((32 &- k) & 31)))
            case .i32Rotr:
                let v = u32(S[s]), k = u32(S[s + 1]) & 31
                S[s] = z((v &>> k) | (v &<< ((32 &- k) & 31)))
            case .i64Clz: S[s] = UInt64(S[s].leadingZeroBitCount)
            case .i64Ctz: S[s] = UInt64(S[s].trailingZeroBitCount)
            case .i64Popcnt: S[s] = UInt64(S[s].nonzeroBitCount)
            case .i64Add: S[s] = S[s] &+ S[s + 1]
            case .i64Sub: S[s] = S[s] &- S[s + 1]
            case .i64Mul: S[s] = S[s] &* S[s + 1]
            case .i64DivS:
                let a = Int64(bitPattern: S[s]), c = Int64(bitPattern: S[s + 1])
                guard c != 0 else { throw WasmError.trap("Division by zero") }
                guard !(a == Int64.min && c == -1) else { throw WasmError.trap("Integer overflow") }
                S[s] = UInt64(bitPattern: a / c)
            case .i64DivU:
                let c = S[s + 1]
                guard c != 0 else { throw WasmError.trap("Division by zero") }
                S[s] = S[s] / c
            case .i64RemS:
                let a = Int64(bitPattern: S[s]), c = Int64(bitPattern: S[s + 1])
                guard c != 0 else { throw WasmError.trap("Remainder by zero") }
                S[s] = c == -1 ? 0 : UInt64(bitPattern: a % c)
            case .i64RemU:
                let c = S[s + 1]
                guard c != 0 else { throw WasmError.trap("Remainder by zero") }
                S[s] = S[s] % c
            case .i64And: S[s] = S[s] & S[s + 1]
            case .i64Or: S[s] = S[s] | S[s + 1]
            case .i64Xor: S[s] = S[s] ^ S[s + 1]
            case .i64Shl: S[s] = S[s] &<< (S[s + 1] & 63)
            case .i64ShrS: S[s] = UInt64(bitPattern: Int64(bitPattern: S[s]) &>> Int64(S[s + 1] & 63))
            case .i64ShrU: S[s] = S[s] &>> (S[s + 1] & 63)
            case .i64Rotl:
                let v = S[s], k = S[s + 1] & 63
                S[s] = (v &<< k) | (v &>> ((64 &- k) & 63))
            case .i64Rotr:
                let v = S[s], k = S[s + 1] & 63
                S[s] = (v &>> k) | (v &<< ((64 &- k) & 63))

            case .f32Abs: S[s] = S[s] & 0x7FFF_FFFF
            case .f32Neg: S[s] = (S[s] ^ 0x8000_0000) & 0xFFFF_FFFF
            case .f32Ceil: S[s] = bits(f32(S[s]).rounded(.up))
            case .f32Floor: S[s] = bits(f32(S[s]).rounded(.down))
            case .f32Trunc: S[s] = bits(f32(S[s]).rounded(.towardZero))
            case .f32Nearest: S[s] = bits(f32(S[s]).rounded(.toNearestOrEven))
            case .f32Sqrt: S[s] = bits(f32(S[s]).squareRoot())
            case .f32Add: S[s] = bits(f32(S[s]) + f32(S[s + 1]))
            case .f32Sub: S[s] = bits(f32(S[s]) - f32(S[s + 1]))
            case .f32Mul: S[s] = bits(f32(S[s]) * f32(S[s + 1]))
            case .f32Div: S[s] = bits(f32(S[s]) / f32(S[s + 1]))
            case .f32Min: S[s] = bits(fmin(f32(S[s]), f32(S[s + 1])))
            case .f32Max: S[s] = bits(fmax(f32(S[s]), f32(S[s + 1])))
            case .f32Copysign: S[s] = (S[s] & 0x7FFF_FFFF) | (S[s + 1] & 0x8000_0000)
            case .f64Abs: S[s] = S[s] & 0x7FFF_FFFF_FFFF_FFFF
            case .f64Neg: S[s] = S[s] ^ 0x8000_0000_0000_0000
            case .f64Ceil: S[s] = bits(f64(S[s]).rounded(.up))
            case .f64Floor: S[s] = bits(f64(S[s]).rounded(.down))
            case .f64Trunc: S[s] = bits(f64(S[s]).rounded(.towardZero))
            case .f64Nearest: S[s] = bits(f64(S[s]).rounded(.toNearestOrEven))
            case .f64Sqrt: S[s] = bits(f64(S[s]).squareRoot())
            case .f64Add: S[s] = bits(f64(S[s]) + f64(S[s + 1]))
            case .f64Sub: S[s] = bits(f64(S[s]) - f64(S[s + 1]))
            case .f64Mul: S[s] = bits(f64(S[s]) * f64(S[s + 1]))
            case .f64Div: S[s] = bits(f64(S[s]) / f64(S[s + 1]))
            case .f64Min: S[s] = bits(fmin(f64(S[s]), f64(S[s + 1])))
            case .f64Max: S[s] = bits(fmax(f64(S[s]), f64(S[s + 1])))
            case .f64Copysign: S[s] = (S[s] & 0x7FFF_FFFF_FFFF_FFFF) | (S[s + 1] & 0x8000_0000_0000_0000)

            case .i32WrapI64: S[s] = S[s] & 0xFFFF_FFFF
            case .i32TruncF32S:
                guard let t = truncIn(Double(f32(S[s])), -2147483648.0, 2147483648.0) else { throw WasmError.trap(truncTrap) }
                S[s] = z(Int32(t))
            case .i32TruncF32U:
                guard let t = truncIn(Double(f32(S[s])), -0.0, 4294967296.0), t > -1 else { throw WasmError.trap(truncTrap) }
                S[s] = z(UInt32(t))
            case .i32TruncF64S:
                guard let t = truncIn(f64(S[s]), -2147483648.0, 2147483648.0) else { throw WasmError.trap(truncTrap) }
                S[s] = z(Int32(t))
            case .i32TruncF64U:
                guard let t = truncIn(f64(S[s]), -0.0, 4294967296.0), t > -1 else { throw WasmError.trap(truncTrap) }
                S[s] = z(UInt32(t))
            case .i64ExtendI32S: S[s] = UInt64(bitPattern: Int64(i32(S[s])))
            case .i64ExtendI32U: S[s] = S[s] & 0xFFFF_FFFF
            case .i64TruncF32S:
                guard let t = truncIn(Double(f32(S[s])), -9223372036854775808.0, 9223372036854775808.0) else { throw WasmError.trap(truncTrap) }
                S[s] = UInt64(bitPattern: Int64(t))
            case .i64TruncF32U:
                guard let t = truncIn(Double(f32(S[s])), -0.0, 18446744073709551616.0), t > -1 else { throw WasmError.trap(truncTrap) }
                S[s] = UInt64(t)
            case .i64TruncF64S:
                guard let t = truncIn(f64(S[s]), -9223372036854775808.0, 9223372036854775808.0) else { throw WasmError.trap(truncTrap) }
                S[s] = UInt64(bitPattern: Int64(t))
            case .i64TruncF64U:
                guard let t = truncIn(f64(S[s]), -0.0, 18446744073709551616.0), t > -1 else { throw WasmError.trap(truncTrap) }
                S[s] = UInt64(t)
            case .f32ConvertI32S: S[s] = bits(Float(i32(S[s])))
            case .f32ConvertI32U: S[s] = bits(Float(u32(S[s])))
            case .f32ConvertI64S: S[s] = bits(Float(Int64(bitPattern: S[s])))
            case .f32ConvertI64U: S[s] = bits(u64ToF32(S[s]))
            case .f32DemoteF64: S[s] = bits(Float(f64(S[s])))
            case .f64ConvertI32S: S[s] = bits(Double(i32(S[s])))
            case .f64ConvertI32U: S[s] = bits(Double(u32(S[s])))
            case .f64ConvertI64S: S[s] = bits(Double(Int64(bitPattern: S[s])))
            case .f64ConvertI64U: S[s] = bits(Double(S[s]))
            case .f64PromoteF32: S[s] = bits(Double(f32(S[s])))
            case .i32Extend8S: S[s] = z(Int32(Int8(truncatingIfNeeded: S[s])))
            case .i32Extend16S: S[s] = z(Int32(Int16(truncatingIfNeeded: S[s])))
            case .i64Extend8S: S[s] = UInt64(bitPattern: Int64(Int8(truncatingIfNeeded: S[s])))
            case .i64Extend16S: S[s] = UInt64(bitPattern: Int64(Int16(truncatingIfNeeded: S[s])))
            case .i64Extend32S: S[s] = UInt64(bitPattern: Int64(Int32(truncatingIfNeeded: S[s])))
            case .i32TruncSatF32S: S[s] = z(satI32(Double(f32(S[s]))))
            case .i32TruncSatF32U: S[s] = z(satU32(Double(f32(S[s]))))
            case .i32TruncSatF64S: S[s] = z(satI32(f64(S[s])))
            case .i32TruncSatF64U: S[s] = z(satU32(f64(S[s])))
            case .i64TruncSatF32S: S[s] = UInt64(bitPattern: satI64(Double(f32(S[s]))))
            case .i64TruncSatF32U: S[s] = satU64(Double(f32(S[s])))
            case .i64TruncSatF64S: S[s] = UInt64(bitPattern: satI64(f64(S[s])))
            case .i64TruncSatF64U: S[s] = satU64(f64(S[s]))
            }
        }
    }
}
