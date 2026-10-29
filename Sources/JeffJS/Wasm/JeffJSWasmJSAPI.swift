// JeffJSWasmJSAPI.swift
// JeffJS — WebAssembly (issue #13): the JavaScript interface.
//
// WebAssembly JavaScript Interface (W3C) + Web API (`compileStreaming`,
// `instantiateStreaming`). The namespace is JS (`glue`, evaluated once per realm by
// `install`) over natives (`__jeffjsWasm`, taken by the glue and deleted): the
// algorithms that read JS objects — import resolution, descriptors, promise
// plumbing — are written as the spec writes them, the natives do decoding,
// instantiation, execution and the value conversions (ToWebAssemblyValue /
// ToJSValue, §4.3). Every glue function is shaped like a JavaScriptCore native
// (`markPlatformFunction`: `toString` prints `[native code]`; hCaptcha's hsw
// fingerprints `Function.prototype.toString.call(WebAssembly.compile).length`).
// Exported wasm functions are host functions named after their index, as in JSC.
// `wasm.enabled` (JEFFJS_WASM_ENABLED=0) = no WebAssembly at all.
//
// Copyright 2026 Jeff Bachand. All rights reserved.

import Foundation

nonisolated enum WasmJSAPI {

    // MARK: Handles (opaque objects carrying the Swift object)

    final class ModuleBox { let module: WasmModule; init(_ m: WasmModule) { module = m } }
    final class InstanceBox { let instance: WasmInstance; init(_ i: WasmInstance) { instance = i } }

    static func newHandle(_ ctx: JeffJSContext, _ payload: AnyObject) -> JeffJSValue {
        let obj = jeffJS_createObject(ctx: ctx, proto: nil, classID: UInt16(JeffJSClassID.object.rawValue))
        obj.payload = .opaque(payload)
        return .makeObject(obj)
    }

    static func unbox<T>(_ v: JeffJSValue, _: T.Type) -> T? {
        guard let o = v.toObject(), case .opaque(let p) = o.payload else { return nil }
        return p as? T
    }

    /// The handle object of a memory / table / global (one per Swift object: identity).
    static func handle(_ ctx: JeffJSContext, memory m: WasmMemory) -> JeffJSValue {
        if m.jsObject.isUndefined { m.jsObject = newHandle(ctx, m) }
        return m.jsObject.dupValue()
    }
    static func handle(_ ctx: JeffJSContext, table t: WasmTable) -> JeffJSValue {
        if t.jsObject.isUndefined { t.jsObject = newHandle(ctx, t) }
        return t.jsObject.dupValue()
    }
    static func handle(_ ctx: JeffJSContext, global g: WasmGlobal) -> JeffJSValue {
        if g.jsObject.isUndefined { g.jsObject = newHandle(ctx, g) }
        return g.jsObject.dupValue()
    }

    // MARK: Error constructors (registered by the glue, per realm)

    nonisolated(unsafe) private static var errorCtors: [ObjectIdentifier: (compile: JeffJSValue, link: JeffJSValue, runtime: JeffJSValue)] = [:]
    private static let lock = NSLock()

    static func throwWasm(_ ctx: JeffJSContext, _ error: WasmError) -> JeffJSValue {
        switch error {
        case .jsException: return .exception
        case .stackOverflow: return ctx.throwRangeError(message: "Maximum call stack size exceeded.")
        case .compile(let m): return throwError(ctx, kind: 0, m)
        case .link(let m): return throwError(ctx, kind: 1, m)
        case .trap(let m): return throwError(ctx, kind: 2, m)
        }
    }

    static func throwError(_ ctx: JeffJSContext, kind: Int, _ message: String) -> JeffJSValue {
        lock.lock()
        let ctors = errorCtors[ObjectIdentifier(ctx)]
        lock.unlock()
        guard let ctors else { return ctx.throwTypeError(message: message) }
        let ctor = kind == 0 ? ctors.compile : kind == 1 ? ctors.link : ctors.runtime
        let msg = ctx.newStringValue(message)
        let err = ctx.callConstructor(ctor, args: [msg])
        msg.freeValue()
        if err.isException { return .exception }
        return ctx.throwValue(err)
    }

    // MARK: Values (JS API §4.3)

    static func toJS(_ bits: UInt64, _ t: WasmValType, ctx: JeffJSContext) -> JeffJSValue {
        switch t {
        case .i32: return .newInt32(Int32(truncatingIfNeeded: bits))
        case .i64: return JeffJSValue.newBigInt(Int64(bitPattern: bits))
        // NaN payloads are canonicalised: JeffJS values are NaN-boxed, a wasm NaN's bits could read as a tag.
        case .f32:
            let d = Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
            return .newFloat64(d.isNaN ? .nan : d)
        case .f64:
            let d = Double(bitPattern: bits)
            return .newFloat64(d.isNaN ? .nan : d)
        case .funcref:
            guard let f = WasmRefs.shared.function(bits) else { return .null }
            return exportedFunction(f, ctx: ctx)
        case .externref:
            guard bits != 0, let e = WasmRefs.shared.object(bits) as? WasmRefs.Extern else { return .null }
            return e.value.dupValue()
        case .v128: return .undefined
        }
    }

    /// ToWebAssemblyValue; a JS exception is left pending (`WasmError.jsException`).
    static func toWasm(_ v: JeffJSValue, _ t: WasmValType, ctx: JeffJSContext) throws -> UInt64 {
        switch t {
        case .i32:
            let (n, ok) = JeffJSTypeConvert.toInt32(ctx: ctx, val: v)
            guard ok else { throw WasmError.jsException }
            return UInt64(UInt32(bitPattern: n))
        case .i64:
            let b = ctx.toBigIntValue(v)
            if b.isException { throw WasmError.jsException }
            defer { b.freeValue() }
            let w = JBigInt.asIntN(64, b.bigIntValue)
            return UInt64(bitPattern: w.asInt64 ?? 0)
        case .f32:
            let (d, ok) = JeffJSTypeConvert.toNumber(ctx: ctx, val: v)
            guard ok else { throw WasmError.jsException }
            return UInt64(Float(d).bitPattern)
        case .f64:
            let (d, ok) = JeffJSTypeConvert.toNumber(ctx: ctx, val: v)
            guard ok else { throw WasmError.jsException }
            return d.bitPattern
        case .funcref:
            if v.isNull { return 0 }
            guard let f = wasmFunction(of: v) else {
                _ = ctx.throwTypeError(message: "Funcref must be an exported wasm function")
                throw WasmError.jsException
            }
            return f.refID
        case .externref:
            return WasmRefs.shared.extern(v)
        case .v128:
            _ = ctx.throwTypeError(message: "Invalid argument type")
            throw WasmError.jsException
        }
    }

    static func iterableToList(_ v: JeffJSValue, ctx: JeffJSContext) -> [JeffJSValue]? {
        ctx.iterableToList(v)
    }

    static func valType(_ s: String) -> WasmValType? {
        switch s {
        case "i32": return .i32
        case "i64": return .i64
        case "f32": return .f32
        case "f64": return .f64
        case "anyfunc", "funcref": return .funcref
        case "externref": return .externref
        default: return nil
        }
    }

    // MARK: Exported functions

    /// The JS function for a wasm function (JS API §4.5.1 "a new Exported Function"), one per function.
    static func exportedFunction(_ f: WasmFunction, ctx: JeffJSContext) -> JeffJSValue {
        if !f.jsObject.isUndefined { return f.jsObject.dupValue() }
        if f.code == nil, !f.host.isUndefined {
            // A host function re-exported: the same callable (§4.5.4 step "If func is a host function…").
            return f.host.dupValue()
        }
        let fnBox = f
        // An exported function keeps its instance alive (JS API §4.5.1: the function's [[FunctionAddress]]
        // lives in the store). The instance → function → JS function → instance cycle is only broken by
        // the page's teardown (open: a finalizer on the JS function would let instances be collected).
        f.instanceRef = f.instance
        let fn = ctx.newCFunction({ ctx, _, args in
            callExported(fnBox, args: args, ctx: ctx)
        }, name: String(f.index), length: f.type.params.count)
        if let o = fn.toObject() {
            o.isConstructor = false
            exportedLock.lock()
            exported[ObjectIdentifier(o)] = fnBox   // identity for ToWebAssemblyValue(funcref) and imports
            exportedLock.unlock()
        }
        f.jsObject = fn.dupValue()
        return fn
    }

    /// Exported function objects → their wasm function. Each object is kept alive by its function's
    /// `jsObject` (and the function by this table), so an address is never reused while listed.
    nonisolated(unsafe) private static var exported: [ObjectIdentifier: WasmFunction] = [:]
    private static let exportedLock = NSLock()

    static func wasmFunction(of v: JeffJSValue) -> WasmFunction? {
        guard let o = v.toObject() else { return nil }
        exportedLock.lock(); defer { exportedLock.unlock() }
        return exported[ObjectIdentifier(o)]
    }

    static func callExported(_ f: WasmFunction, args: [JeffJSValue], ctx: JeffJSContext) -> JeffJSValue {
        var bits: [UInt64] = []
        bits.reserveCapacity(f.type.params.count)
        do {
            for (i, t) in f.type.params.enumerated() {
                bits.append(try toWasm(i < args.count ? args[i] : .undefined, t, ctx: ctx))
            }
            let results = try WasmInterpreter.invoke(f, args: bits, ctx: ctx)
            if results.isEmpty { return .undefined }
            if results.count == 1 { return toJS(results[0], f.type.results[0], ctx: ctx) }
            let arr = ctx.newArray()
            for (i, r) in results.enumerated() {
                _ = ctx.setPropertyUint32(obj: arr, index: UInt32(i), value: toJS(r, f.type.results[i], ctx: ctx))
            }
            return arr
        } catch let e as WasmError {
            return throwWasm(ctx, e)
        } catch {
            return ctx.throwTypeError(message: "\(error)")
        }
    }

    // MARK: Natives

    static func bytes(of v: JeffJSValue) -> [UInt8]? {
        guard let obj = v.toObject() else { return nil }
        if case .arrayBuffer(let ab) = obj.payload { return ab.detached ? [] : ab.data }
        if case .typedArray(let ta) = obj.payload, let bufObj = ta.buffer, case .arrayBuffer(let ab) = bufObj.payload {
            if ab.detached { return [] }
            let start = max(0, min(ta.byteOffset, ab.data.count))
            let end = max(start, min(start + ta.byteLength, ab.data.count))
            return Array(ab.data[start..<end])
        }
        return nil
    }

    static func str(_ ctx: JeffJSContext, _ s: String) -> JeffJSValue { ctx.newStringValue(s) }

    static func array(_ ctx: JeffJSContext, _ items: [JeffJSValue]) -> JeffJSValue {
        let arr = ctx.newArray()
        for (i, v) in items.enumerated() { _ = ctx.setPropertyUint32(obj: arr, index: UInt32(i), value: v) }
        return arr
    }

    static func install(ctx: JeffJSContext) {
        guard JeffJSConfig.wasmEnabled else { return }
        let global = ctx.getGlobalObject()
        defer { global.freeValue() }
        let n = ctx.newObject()
        func def(_ name: String, _ len: Int, _ f: @escaping (JeffJSContext, [JeffJSValue]) -> JeffJSValue) {
            ctx.setPropertyFunc(obj: n, name: name, fn: { ctx, _, args in f(ctx, args) }, length: len)
        }
        def("mark", 2) { ctx, a in
            if let f = a.first { ctx.markPlatformFunction(f, isConstructor: a.count > 1 && a[1].isBool && a[1].toBool()) }
            return .undefined
        }
        def("errors", 3) { ctx, a in
            guard a.count == 3 else { return .undefined }
            lock.lock()
            errorCtors[ObjectIdentifier(ctx)] = (a[0].dupValue(), a[1].dupValue(), a[2].dupValue())
            lock.unlock()
            return .undefined
        }
        def("isBytes", 1) { _, a in .newBool(a.first.flatMap { bytes(of: $0) } != nil) }
        def("compile", 1) { ctx, a in
            guard let b = a.first.flatMap({ bytes(of: $0) }) else { return str(ctx, "TypeError:first argument must be an ArrayBufferView or an ArrayBuffer (evaluating 'new WebAssembly.Module(buffer)')") }
            do { return newHandle(ctx, ModuleBox(try WasmModule.compile(b))) }
            catch WasmError.compile(let m) { return str(ctx, "CompileError:" + m) }
            catch { return str(ctx, "CompileError:\(error)") }
        }
        def("validate", 1) { ctx, a in
            guard let b = a.first.flatMap({ bytes(of: $0) }) else { return ctx.throwTypeError(message: "first argument must be an ArrayBufferView or an ArrayBuffer (evaluating 'WebAssembly.validate(bytes)')") }
            return .newBool((try? WasmModule.compile(b)) != nil)
        }
        def("imports", 1) { ctx, a in
            guard let m = a.first.flatMap({ unbox($0, ModuleBox.self) })?.module else { return .undefined }
            return array(ctx, m.imports.map { array(ctx, [str(ctx, $0.module), str(ctx, $0.name), str(ctx, $0.kindName)]) })
        }
        def("exports", 1) { ctx, a in
            guard let m = a.first.flatMap({ unbox($0, ModuleBox.self) })?.module else { return .undefined }
            return array(ctx, m.exports.map { array(ctx, [str(ctx, $0.name), str(ctx, $0.kind.name)]) })
        }
        def("custom", 2) { ctx, a in
            guard a.count == 2, let m = unbox(a[0], ModuleBox.self)?.module, let name = ctx.toSwiftString(a[1]) else { return .undefined }
            return array(ctx, m.customSections.filter { $0.name == name }.map { section -> JeffJSValue in
                let ab = JeffJSArrayBuffer(byteLength: section.bytes.count)
                ab.data = section.bytes
                return arrayBufferObject(ctx, ab)
            })
        }
        def("instantiate", 2) { ctx, a in instantiate(ctx, a) }
        def("instanceExports", 1) { ctx, a in
            guard let inst = a.first.flatMap({ unbox($0, InstanceBox.self) })?.instance else { return .undefined }
            var items: [JeffJSValue] = []
            for e in inst.module.exports {
                let v: JeffJSValue
                switch e.kind {
                case .function: v = exportedFunction(inst.functions[e.index], ctx: ctx)
                case .memory: v = handle(ctx, memory: inst.memories[e.index])
                case .table: v = handle(ctx, table: inst.tables[e.index])
                case .global: v = handle(ctx, global: inst.globals[e.index])
                }
                items.append(array(ctx, [str(ctx, e.name), str(ctx, e.kind.name), v]))
            }
            return array(ctx, items)
        }
        // Memory
        def("memNew", 2) { ctx, a in
            let initial = UInt32(truncatingIfNeeded: Int(a[0].toNumber()))
            let maximum: UInt32? = a.count > 1 && !a[1].isUndefined ? UInt32(truncatingIfNeeded: Int(a[1].toNumber())) : nil
            guard Int(initial) * 65536 <= 1 << 30 else {
                return ctx.throwRangeError(message: "WebAssembly.Memory could not allocate the memory")
            }
            return handle(ctx, memory: WasmMemory(pages: initial, max: maximum))
        }
        def("memBuffer", 1) { ctx, a in
            guard let m = a.first.flatMap({ unbox($0, WasmMemory.self) }) else { return .undefined }
            if m.bufferObject.isUndefined { m.bufferObject = arrayBufferObject(ctx, m.ab) }
            return m.bufferObject.dupValue()
        }
        def("memGrow", 2) { ctx, a in
            guard a.count == 2, let m = unbox(a[0], WasmMemory.self) else { return .undefined }
            let d = a[1].toNumber()
            guard d >= 0, d <= Double(UInt32.max), let old = m.grow(by: UInt32(d)) else { return .newInt32(-1) }
            return .newFloat64(Double(old))
        }
        def("memPages", 1) { _, a in
            guard let m = a.first.flatMap({ unbox($0, WasmMemory.self) }) else { return .undefined }
            return .newFloat64(Double(m.pages))
        }
        def("memMax", 1) { _, a in
            guard let m = a.first.flatMap({ unbox($0, WasmMemory.self) }), let mx = m.maxPages else { return .undefined }
            return .newFloat64(Double(mx))
        }
        // Table
        def("tableNew", 4) { ctx, a in
            guard let s = ctx.toSwiftString(a[0]), let t = valType(s), t.isRef else { return .undefined }
            let initial = UInt32(truncatingIfNeeded: Int(a[1].toNumber()))
            let maximum: UInt32? = !a[2].isUndefined ? UInt32(truncatingIfNeeded: Int(a[2].toNumber())) : nil
            var fill: UInt64 = 0
            if a.count > 3, !a[3].isUndefined {
                do { fill = try toWasm(a[3], t, ctx: ctx) } catch { return .exception }
            }
            return handle(ctx, table: WasmTable(type: t, size: initial, max: maximum, fill: fill))
        }
        def("tableType", 1) { ctx, a in
            guard let t = a.first.flatMap({ unbox($0, WasmTable.self) }) else { return .undefined }
            return str(ctx, t.elemType == .funcref ? "anyfunc" : t.elemType.name)
        }
        def("tableLength", 1) { _, a in
            guard let t = a.first.flatMap({ unbox($0, WasmTable.self) }) else { return .undefined }
            return .newFloat64(Double(t.elems.count))
        }
        def("tableGet", 2) { ctx, a in
            guard let t = unbox(a[0], WasmTable.self) else { return .undefined }
            let i = a[1].toNumber()
            guard i >= 0, i < Double(t.elems.count) else { return ctx.throwRangeError(message: "WebAssembly.Table.prototype.get expects an integer less than the length of the table") }
            return toJS(t.elems[Int(i)], t.elemType, ctx: ctx)
        }
        def("tableSet", 3) { ctx, a in
            guard let t = unbox(a[0], WasmTable.self) else { return .undefined }
            let i = a[1].toNumber()
            guard i >= 0, i < Double(t.elems.count) else { return ctx.throwRangeError(message: "WebAssembly.Table.prototype.set expects an integer less than the length of the table") }
            do { t.elems[Int(i)] = a.count > 2 && !a[2].isUndefined ? try toWasm(a[2], t.elemType, ctx: ctx) : 0 }
            catch { return .exception }
            return .undefined
        }
        def("tableGrow", 3) { ctx, a in
            guard let t = unbox(a[0], WasmTable.self) else { return .undefined }
            let d = a[1].toNumber()
            var fill: UInt64 = 0
            if a.count > 2, !a[2].isUndefined {
                do { fill = try toWasm(a[2], t.elemType, ctx: ctx) } catch { return .exception }
            }
            guard d >= 0, d <= Double(UInt32.max), let old = t.grow(by: UInt32(d), fill: fill) else { return .newInt32(-1) }
            return .newFloat64(Double(old))
        }
        // Global
        def("globalNew", 3) { ctx, a in
            guard let s = ctx.toSwiftString(a[0]), let t = valType(s) else { return .undefined }
            let g = WasmGlobal(type: WasmGlobalType(type: t, mutable: a[1].toBool()), bits: 0)
            if a.count > 2, !a[2].isUndefined {
                do { g.bits = try toWasm(a[2], t, ctx: ctx) } catch { return .exception }
            }
            return handle(ctx, global: g)
        }
        def("globalType", 1) { ctx, a in
            guard let g = a.first.flatMap({ unbox($0, WasmGlobal.self) }) else { return .undefined }
            return array(ctx, [str(ctx, g.type.type == .funcref ? "anyfunc" : g.type.type.name), .newBool(g.type.mutable)])
        }
        def("globalGet", 1) { ctx, a in
            guard let g = a.first.flatMap({ unbox($0, WasmGlobal.self) }) else { return .undefined }
            return toJS(g.bits, g.type.type, ctx: ctx)
        }
        def("globalSet", 2) { ctx, a in
            guard let g = unbox(a[0], WasmGlobal.self) else { return .undefined }
            do { g.bits = try toWasm(a.count > 1 ? a[1] : .undefined, g.type.type, ctx: ctx) } catch { return .exception }
            return .undefined
        }
        def("kindOf", 1) { ctx, a in
            guard let v = a.first else { return .undefined }
            if unbox(v, WasmMemory.self) != nil { return str(ctx, "memory") }
            if unbox(v, WasmTable.self) != nil { return str(ctx, "table") }
            if unbox(v, WasmGlobal.self) != nil { return str(ctx, "global") }
            if unbox(v, ModuleBox.self) != nil { return str(ctx, "module") }
            if unbox(v, InstanceBox.self) != nil { return str(ctx, "instance") }
            return .undefined
        }
        ctx.setPropertyStr(obj: global, name: "__jeffjsWasm", value: n)
        let r = ctx.eval(input: glue, filename: "<wasm>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        if r.isException { ctx.getException().freeValue() }
        r.freeValue()
    }

    static func arrayBufferObject(_ ctx: JeffJSContext, _ ab: JeffJSArrayBuffer) -> JeffJSValue {
        var proto: JeffJSObject? = nil
        let abClassID = Int(JSClassID.JS_CLASS_ARRAY_BUFFER.rawValue)
        if abClassID < ctx.classProto.count, ctx.classProto[abClassID].isObject {
            proto = ctx.classProto[abClassID].toObject()
        }
        let obj = jeffJS_createObject(ctx: ctx, proto: proto, classID: UInt16(JeffJSClassID.arrayBuffer.rawValue))
        obj.payload = .arrayBuffer(ab)
        return .makeObject(obj)
    }

    /// `instantiate(moduleHandle, values)`: values are in import order, each already resolved by the
    /// glue (a callable, a memory/table/global handle, or a number / BigInt for a global).
    static func instantiate(_ ctx: JeffJSContext, _ a: [JeffJSValue]) -> JeffJSValue {
        guard a.count == 2, let m = unbox(a[0], ModuleBox.self)?.module else { return .undefined }
        let values = a[1]
        var funcs: [WasmFunction] = [], tables: [WasmTable] = [], mems: [WasmMemory] = [], globals: [WasmGlobal] = []
        for (i, imp) in m.imports.enumerated() {
            let v = ctx.getPropertyUint32(obj: values, index: UInt32(i))
            defer { v.freeValue() }
            let what = "import \(i) \"\(imp.module)\" \"\(imp.name)\""
            switch imp.desc {
            case .function(let ti):
                let type = m.types[ti]
                if let wf = wasmFunction(of: v) {
                    guard wf.type == type else { return str(ctx, "LinkError:\(what): imported function does not match the expected type") }
                    funcs.append(wf)
                } else {
                    guard ctx.isCallable(v) else { return str(ctx, "LinkError:\(what): import function must be callable") }
                    let f = WasmFunction(type: type, instance: nil, code: nil, index: m.funcTypes.count + i)
                    f.host = v.dupValue()
                    f.hostCtx = ctx
                    funcs.append(f)
                }
            case .memory(let l):
                guard let mem = unbox(v, WasmMemory.self) else { return str(ctx, "LinkError:\(what): Memory import must be a WebAssembly.Memory object") }
                guard mem.pages >= l.min else { return str(ctx, "LinkError:\(what): Memory import provided an 'initial' that is smaller than the module's declared 'minimum' import memory size") }
                if let mx = l.max {
                    guard let have = mem.maxPages else { return str(ctx, "LinkError:\(what): Memory import did not have a 'maximum' but the module requires that it does") }
                    guard have <= mx else { return str(ctx, "LinkError:\(what): Memory imports 'maximum' is larger than the module's expected 'maximum'") }
                }
                mems.append(mem)
            case .table(let tt):
                guard let t = unbox(v, WasmTable.self) else { return str(ctx, "LinkError:\(what): Table import must be a WebAssembly.Table object") }
                guard t.elemType == tt.elem else { return str(ctx, "LinkError:\(what): Table import has the wrong element type") }
                guard t.elems.count >= Int(tt.limits.min) else { return str(ctx, "LinkError:\(what): Table import provided an 'initial' that is too small") }
                if let mx = tt.limits.max {
                    guard let have = t.max, have <= mx else { return str(ctx, "LinkError:\(what): Table import has a larger 'maximum' than the module's") }
                }
                tables.append(t)
            case .global(let gt):
                if let g = unbox(v, WasmGlobal.self) {
                    guard g.type == gt else { return str(ctx, "LinkError:\(what): imported global's type does not match") }
                    globals.append(g)
                } else {
                    guard !gt.mutable else { return str(ctx, "LinkError:\(what): imported global must be a WebAssembly.Global object if mutable") }
                    if gt.type == .i64, !v.isBigInt { return str(ctx, "LinkError:\(what): imported global must be a BigInt or a WebAssembly.Global") }
                    if gt.type != .i64, gt.type != .externref, gt.type != .funcref, !v.isNumber {
                        return str(ctx, "LinkError:\(what): imported global must be a number or a WebAssembly.Global")
                    }
                    do { globals.append(WasmGlobal(type: gt, bits: try toWasm(v, gt.type, ctx: ctx))) }
                    catch { return .exception }
                }
            }
        }
        let inst = WasmInstance(module: m, ctx: ctx)
        do {
            try inst.initialize(importedFunctions: funcs, importedTables: tables, importedMemories: mems, importedGlobals: globals)
        } catch WasmError.trap(let msg) {
            return str(ctx, "RuntimeError:" + msg)
        } catch let e as WasmError {
            return throwWasm(ctx, e)
        } catch {
            return ctx.throwTypeError(message: "\(error)")
        }
        return newHandle(ctx, InstanceBox(inst))
    }

    // MARK: The namespace

    static let glue = #"""
    (function (N) {
      'use strict';
      var G = globalThis;
      var defineProperty = Object.defineProperty, freeze = Object.freeze, create = Object.create;
      var slots = new WeakMap();
      var wrappers = new WeakMap();
      function slot(o, kind, what) {
        var s = (o !== null && (typeof o === 'object' || typeof o === 'function')) ? slots.get(o) : undefined;
        if (!s || s.kind !== kind) throw new TypeError(what);
        return s;
      }
      function method(obj, name, len, f) {
        defineProperty(f, 'name', { value: name, configurable: true });
        defineProperty(f, 'length', { value: len, configurable: true });
        N.mark(f, false);
        defineProperty(obj, name, { value: f, writable: true, configurable: true, enumerable: true });
        return f;
      }
      function getter(obj, name, f) {
        defineProperty(f, 'name', { value: 'get ' + name, configurable: true });
        N.mark(f, false);
        defineProperty(obj, name, { get: f, configurable: true, enumerable: true });
      }
      function ctor(name, len, f) {
        defineProperty(f, 'name', { value: name, configurable: true });
        defineProperty(f, 'length', { value: len, configurable: true });
        N.mark(f, true);
        return f;
      }
      function needNew(nt, name) { if (nt === undefined) throw new TypeError('calling WebAssembly.' + name + ' constructor without new is invalid'); }
      function tag(proto, name) { defineProperty(proto, Symbol.toStringTag, { value: 'WebAssembly.' + name, configurable: true }); }

      // Errors: NativeError-like (JS API §8).
      function makeError(name) {
        var E = ctor(name, 1, function (message, options) {
          var self = Reflect.construct(Error, arguments.length ? [message] : [], new.target === undefined ? E : new.target);
          if (options !== null && typeof options === 'object' && 'cause' in options) {
            defineProperty(self, 'cause', { value: options.cause, writable: true, configurable: true, enumerable: false });
          }
          return self;
        });
        Object.setPrototypeOf(E, Error);
        E.prototype = create(Error.prototype, {
          constructor: { value: E, writable: true, configurable: true },
          name: { value: name, writable: true, configurable: true },
          message: { value: '', writable: true, configurable: true }
        });
        defineProperty(E, 'prototype', { writable: false, enumerable: false, configurable: false });
        return E;
      }
      var CompileError = makeError('CompileError'), LinkError = makeError('LinkError'), RuntimeError = makeError('RuntimeError');
      N.errors(CompileError, LinkError, RuntimeError);
      function fail(r) {
        if (typeof r !== 'string') return r;
        var i = r.indexOf(':'), k = r.slice(0, i), m = r.slice(i + 1);
        if (k === 'CompileError') throw new CompileError(m);
        if (k === 'LinkError') throw new LinkError(m);
        if (k === 'RuntimeError') throw new RuntimeError(m);
        throw new TypeError(m);
      }
      function toBytes(b, what) {
        if (!N.isBytes(b)) throw new TypeError('first argument must be an ArrayBufferView or an ArrayBuffer (evaluating \'' + what + '\')');
        return b;
      }

      var WA = {};
      defineProperty(WA, Symbol.toStringTag, { value: 'WebAssembly', configurable: true });

      // Module
      var Module = ctor('Module', 1, function Module(bytes) {
        needNew(new.target, 'Module');
        var h = fail(N.compile(toBytes(bytes, 'new WebAssembly.Module(buffer)')));
        var self = this;
        slots.set(self, { kind: 'module', h: h });
        return self;
      });
      function moduleFrom(h, proto) { var m = create(proto || Module.prototype); slots.set(m, { kind: 'module', h: h }); return m; }
      method(Module, 'exports', 1, function (module) {
        var s = slot(module, 'module', 'WebAssembly.Module.exports called with non WebAssembly.Module argument');
        return N.exports(s.h).map(function (e) { return { name: e[0], kind: e[1] }; });
      });
      method(Module, 'imports', 1, function (module) {
        var s = slot(module, 'module', 'WebAssembly.Module.imports called with non WebAssembly.Module argument');
        return N.imports(s.h).map(function (e) { return { module: e[0], name: e[1], kind: e[2] }; });
      });
      method(Module, 'customSections', 2, function (module, sectionName) {
        var s = slot(module, 'module', 'WebAssembly.Module.customSections called with non WebAssembly.Module argument');
        if (arguments.length < 2) throw new TypeError('WebAssembly.Module.customSections expects at least two arguments');
        return N.custom(s.h, String(sectionName));
      });
      tag(Module.prototype, 'Module');

      // Instance
      function resolveImports(mh, importObject) {
        var list = N.imports(mh);
        if (list.length && (importObject === undefined)) throw new TypeError('can\'t make WebAssembly.Instance because there is no imports Object and the WebAssembly.Module requires imports');
        if (importObject !== undefined && (importObject === null || (typeof importObject !== 'object' && typeof importObject !== 'function'))) {
          throw new TypeError('second argument to WebAssembly.Instance must be undefined or an Object');
        }
        var values = [];
        for (var i = 0; i < list.length; i++) {
          var mod = importObject[list[i][0]];
          if (mod === null || (typeof mod !== 'object' && typeof mod !== 'function')) {
            throw new TypeError('import ' + i + ':' + list[i][0] + ' must be an object');
          }
          var v = mod[list[i][1]];
          var kind = list[i][2];
          if (kind === 'function') {
            if (typeof v !== 'function') throw new LinkError('import function ' + list[i][0] + ':' + list[i][1] + ' must be callable');
            values.push(v);
          } else {
            var s = (v !== null && typeof v === 'object') ? slots.get(v) : undefined;
            if (kind === 'memory') {
              if (!s || s.kind !== 'memory') throw new LinkError('Memory import ' + list[i][0] + ':' + list[i][1] + ' is not an instance of WebAssembly.Memory');
              values.push(s.h);
            } else if (kind === 'table') {
              if (!s || s.kind !== 'table') throw new LinkError('Table import ' + list[i][0] + ':' + list[i][1] + ' is not an instance of WebAssembly.Table');
              values.push(s.h);
            } else {
              values.push(s && s.kind === 'global' ? s.h : v);
            }
          }
        }
        return values;
      }
      function wrap(kind, h) {
        var w = wrappers.get(h);
        if (w) return w;
        var proto = kind === 'memory' ? Memory.prototype : kind === 'table' ? Table.prototype : Global.prototype;
        w = create(proto);
        slots.set(w, { kind: kind, h: h });
        wrappers.set(h, w);
        return w;
      }
      function instantiateCore(mh, importObject, proto) {
        var ih = fail(N.instantiate(mh, resolveImports(mh, importObject)));
        var ex = create(null);
        var list = N.instanceExports(ih);
        for (var i = 0; i < list.length; i++) {
          var k = list[i][1], v = list[i][2];
          ex[list[i][0]] = k === 'function' ? v : wrap(k, v);
        }
        freeze(ex);
        var inst = create(proto || Instance.prototype);
        slots.set(inst, { kind: 'instance', h: ih, exports: ex });
        return inst;
      }
      var Instance = ctor('Instance', 1, function Instance(module, importObject) {
        needNew(new.target, 'Instance');
        var s = slot(module, 'module', 'first argument to WebAssembly.Instance must be a WebAssembly.Module');
        var inst = instantiateCore(s.h, importObject, new.target.prototype);
        return inst;
      });
      getter(Instance.prototype, 'exports', function () {
        return slot(this, 'instance', 'expected |this| value to be an instance of WebAssembly.Instance').exports;
      });
      tag(Instance.prototype, 'Instance');

      // Memory
      function index(v, what) {
        var n = Number(v);
        if (!(n >= 0) || n === Infinity || n > 4294967295) throw new TypeError(what);
        return Math.floor(n);
      }
      var Memory = ctor('Memory', 1, function Memory(descriptor) {
        needNew(new.target, 'Memory');
        if (descriptor === null || typeof descriptor !== 'object') throw new TypeError('WebAssembly.Memory expects its first argument to be an object');
        var initial = descriptor.initial;
        if (initial === undefined) throw new TypeError('WebAssembly.Memory expects its first argument to be an object with a property \'initial\'');
        initial = index(initial, 'WebAssembly.Memory expects the \'initial\' value to be an integer');
        var maximum = descriptor.maximum;
        if (maximum !== undefined) maximum = index(maximum, 'WebAssembly.Memory expects the \'maximum\' value to be an integer');
        if (initial > 65536) throw new RangeError('WebAssembly.Memory \'initial\' page count is too large');
        if (maximum !== undefined && maximum > 65536) throw new RangeError('WebAssembly.Memory \'maximum\' page count is too large');
        if (maximum !== undefined && maximum < initial) throw new RangeError('\'maximum\' page count must be than greater than or equal to the \'initial\' page count');
        if (descriptor.shared === true) throw new TypeError('WebAssembly.Memory shared memory is not supported');
        var h = N.memNew(initial, maximum);
        var self = create(new.target.prototype);
        slots.set(self, { kind: 'memory', h: h });
        wrappers.set(h, self);
        return self;
      });
      method(Memory.prototype, 'grow', 1, function (delta) {
        var s = slot(this, 'memory', 'WebAssembly.Memory.prototype.grow called with non WebAssembly.Memory |this| value');
        var d = index(delta, 'WebAssembly.Memory.grow expects the delta to be an integer');
        var old = N.memGrow(s.h, d);
        if (old < 0) throw new RangeError('WebAssembly.Memory.grow would exceed the memory\'s declared maximum size');
        return old;
      });
      getter(Memory.prototype, 'buffer', function () {
        return N.memBuffer(slot(this, 'memory', 'WebAssembly.Memory.prototype.buffer getter called with non WebAssembly.Memory |this| value').h);
      });
      tag(Memory.prototype, 'Memory');

      // Table
      var Table = ctor('Table', 1, function Table(descriptor, value) {
        needNew(new.target, 'Table');
        if (descriptor === null || typeof descriptor !== 'object') throw new TypeError('WebAssembly.Table expects its first argument to be an object');
        var element = String(descriptor.element);
        if (element !== 'anyfunc' && element !== 'funcref' && element !== 'externref') throw new TypeError('WebAssembly.Table expects its \'element\' field to be the string \'funcref\' or \'externref\'');
        if (descriptor.initial === undefined) throw new TypeError('WebAssembly.Table expects its first argument to be an object with a property \'initial\'');
        var initial = index(descriptor.initial, 'WebAssembly.Table expects its \'initial\' property to be an integer');
        var maximum = descriptor.maximum;
        if (maximum !== undefined) maximum = index(maximum, 'WebAssembly.Table expects its \'maximum\' property to be an integer');
        if (maximum !== undefined && maximum < initial) throw new RangeError('WebAssembly.Table expects its \'initial\' property to be less than or equal to its \'maximum\' property');
        var h = N.tableNew(element, initial, maximum, value);
        var self = create(new.target.prototype);
        slots.set(self, { kind: 'table', h: h });
        wrappers.set(h, self);
        return self;
      });
      var tableThis = 'expected |this| value to be an instance of WebAssembly.Table';
      method(Table.prototype, 'get', 1, function (i) {
        return N.tableGet(slot(this, 'table', tableThis).h, index(i, 'WebAssembly.Table.prototype.get expects an integer less than the length of the table'));
      });
      method(Table.prototype, 'set', 1, function (i, v) {
        N.tableSet(slot(this, 'table', tableThis).h, index(i, 'WebAssembly.Table.prototype.set expects an integer less than the length of the table'), v);
      });
      method(Table.prototype, 'grow', 1, function (delta, v) {
        var old = N.tableGrow(slot(this, 'table', tableThis).h, index(delta, 'WebAssembly.Table.prototype.grow expects an integer'), v);
        if (old < 0) throw new RangeError('WebAssembly.Table.prototype.grow could not grow the table');
        return old;
      });
      getter(Table.prototype, 'length', function () { return N.tableLength(slot(this, 'table', tableThis).h); });
      tag(Table.prototype, 'Table');

      // Global
      var Global = ctor('Global', 1, function Global(descriptor, v) {
        needNew(new.target, 'Global');
        if (descriptor === null || typeof descriptor !== 'object') throw new TypeError('WebAssembly.Global expects its first argument to be an object');
        var mutable = !!descriptor.mutable;
        var type = String(descriptor.value);
        if (['i32', 'i64', 'f32', 'f64', 'anyfunc', 'funcref', 'externref'].indexOf(type) < 0) throw new TypeError('WebAssembly.Global expects its \'value\' field to be the string \'i32\', \'i64\', \'f32\', \'f64\', \'anyfunc\', \'funcref\', or \'externref\'');
        if (v === undefined && type === 'externref' && arguments.length < 2) v = undefined;
        var h = N.globalNew(type, mutable, v);
        var self = create(new.target.prototype);
        slots.set(self, { kind: 'global', h: h });
        wrappers.set(h, self);
        return self;
      });
      var globalThisMsg = 'expected |this| value to be an instance of WebAssembly.Global';
      function valueGet() { return N.globalGet(slot(this, 'global', globalThisMsg).h); }
      method(Global.prototype, 'valueOf', 0, valueGet);
      var valueSet = function (v) {
        var s = slot(this, 'global', globalThisMsg);
        if (!N.globalType(s.h)[1]) throw new TypeError('WebAssembly.Global.prototype.value attempts to modify immutable global value');
        if (arguments.length < 1) throw new TypeError('WebAssembly.Global.prototype.value setter expects an argument');
        N.globalSet(s.h, v);
      };
      var vg = function () { return valueGet.call(this); };
      defineProperty(vg, 'name', { value: 'get value', configurable: true }); N.mark(vg, false);
      defineProperty(valueSet, 'name', { value: 'set value', configurable: true }); N.mark(valueSet, false);
      defineProperty(Global.prototype, 'value', { get: vg, set: valueSet, configurable: true, enumerable: true });
      tag(Global.prototype, 'Global');

      // Namespace functions
      var queue = function (f) { return Promise.resolve().then(f); };
      method(WA, 'validate', 1, function (bytes) {
        return N.validate(toBytes(bytes, 'WebAssembly.validate(bytes)'));
      });
      method(WA, 'compile', 1, function (bytes) {
        try { toBytes(bytes, 'WebAssembly.compile(bytes)'); } catch (e) { return Promise.reject(e); }
        var copy = bytes;
        return queue(function () { return moduleFrom(fail(N.compile(copy))); });
      });
      method(WA, 'instantiate', 1, function (source, importObject) {
        var s = (source !== null && typeof source === 'object') ? slots.get(source) : undefined;
        if (s && s.kind === 'module') {
          return queue(function () { return instantiateCore(s.h, importObject); });
        }
        try { toBytes(source, 'WebAssembly.instantiate(buffer, importObject)'); } catch (e) { return Promise.reject(e); }
        return queue(function () {
          var m = moduleFrom(fail(N.compile(source)));
          var inst = instantiateCore(slots.get(m).h, importObject);
          return { module: m, instance: inst };
        });
      });
      function responseBytes(source) {
        return Promise.resolve(source).then(function (r) {
          if (typeof Response !== 'function' || !(r instanceof Response)) throw new TypeError('first argument must be an Response or Promise for Response');
          var type = (r.headers && r.headers.get('content-type')) || '';
          if (String(type).split(';')[0].trim().toLowerCase() !== 'application/wasm') throw new TypeError('Unexpected response MIME type. Expected \'application/wasm\'');
          if (!r.ok) throw new TypeError('Response has not returned OK status');
          if (r.bodyUsed) throw new TypeError('Response is disturbed or locked');
          return r.arrayBuffer();
        });
      }
      method(WA, 'compileStreaming', 1, function (source) {
        return responseBytes(source).then(function (b) { return moduleFrom(fail(N.compile(b))); });
      });
      method(WA, 'instantiateStreaming', 1, function (source, importObject) {
        return responseBytes(source).then(function (b) {
          var m = moduleFrom(fail(N.compile(b)));
          return { module: m, instance: instantiateCore(slots.get(m).h, importObject) };
        });
      });
      [Module, Instance, Memory, Table, Global].forEach(function (C) {
        defineProperty(C.prototype, 'constructor', { value: C, writable: true, configurable: true, enumerable: false });
        defineProperty(C, 'prototype', { writable: false, enumerable: false, configurable: false });
      });
      [['Module', Module], ['Instance', Instance], ['Memory', Memory], ['Table', Table], ['Global', Global],
       ['CompileError', CompileError], ['LinkError', LinkError], ['RuntimeError', RuntimeError]].forEach(function (p) {
        defineProperty(WA, p[0], { value: p[1], writable: true, configurable: true, enumerable: false });
      });
      defineProperty(G, 'WebAssembly', { value: WA, writable: true, configurable: true, enumerable: false });
    })(globalThis.__jeffjsWasm);
    delete globalThis.__jeffjsWasm;
    """#
}
