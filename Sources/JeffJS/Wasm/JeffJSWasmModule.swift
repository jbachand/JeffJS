// JeffJSWasmModule.swift
// JeffJS — WebAssembly (issue #13): the module structure and the binary decoder.
//
// WebAssembly Core 2.0 §5 (binary format): the sections of a module, decoded into
// `WasmModule`. Function bodies are decoded and validated by `WasmCompiler`
// (JeffJSWasmCompiler.swift), which also turns them into the interpreter's code.
// Supported: the MVP, sign-extension, non-trapping float-to-int, bulk memory,
// reference types (funcref / externref), multi-value block types. Not supported (a
// CompileError): SIMD, threads, exceptions, GC, memory64, tail calls.
//
// Errors are `WasmError.compile(message)`; the JS API turns them into
// `WebAssembly.CompileError`. Messages follow JavaScriptCore's
// ("WebAssembly.Module doesn't parse at byte N: …").
//
// Copyright 2026 Jeff Bachand. All rights reserved.

import Foundation

nonisolated enum WasmValType: UInt8, Equatable {
    case i32 = 0x7F, i64 = 0x7E, f32 = 0x7D, f64 = 0x7C, v128 = 0x7B, funcref = 0x70, externref = 0x6F

    var isRef: Bool { self == .funcref || self == .externref }
    var name: String {
        switch self {
        case .i32: return "i32"
        case .i64: return "i64"
        case .f32: return "f32"
        case .f64: return "f64"
        case .v128: return "v128"
        case .funcref: return "funcref"
        case .externref: return "externref"
        }
    }
}

nonisolated struct WasmFuncType: Equatable {
    var params: [WasmValType]
    var results: [WasmValType]
}

nonisolated struct WasmLimits: Equatable {
    var min: UInt32
    var max: UInt32?
}

nonisolated struct WasmTableType: Equatable {
    var elem: WasmValType
    var limits: WasmLimits
}

nonisolated struct WasmGlobalType: Equatable {
    var type: WasmValType
    var mutable: Bool
}

nonisolated enum WasmImportDesc {
    case function(typeIndex: Int)
    case table(WasmTableType)
    case memory(WasmLimits)
    case global(WasmGlobalType)
}

nonisolated struct WasmImport {
    var module: String
    var name: String
    var desc: WasmImportDesc
    var kindName: String {
        switch desc {
        case .function: return "function"
        case .table: return "table"
        case .memory: return "memory"
        case .global: return "global"
        }
    }
}

nonisolated enum WasmExportKind: UInt8 {
    case function = 0, table = 1, memory = 2, global = 3
    var name: String {
        switch self {
        case .function: return "function"
        case .table: return "table"
        case .memory: return "memory"
        case .global: return "global"
        }
    }
}

nonisolated struct WasmExport {
    var name: String
    var kind: WasmExportKind
    var index: Int
}

/// A constant expression (§3.3.10): evaluated at instantiation.
nonisolated enum WasmConstExpr {
    case i32(Int32), i64(Int64), f32(UInt32), f64(UInt64)
    case globalGet(Int)
    case refNull(WasmValType)
    case refFunc(Int)
    /// Extended constant expressions (i32/i64 add, sub, mul) as a small postfix program.
    case program([WasmConstOp])
}

nonisolated enum WasmConstOp {
    case push(WasmConstExpr)
    case i32Add, i32Sub, i32Mul, i64Add, i64Sub, i64Mul
}

nonisolated struct WasmGlobalDef {
    var type: WasmGlobalType
    var initExpr: WasmConstExpr
}

nonisolated enum WasmElemMode {
    case passive
    case active(table: Int, offset: WasmConstExpr)
    case declarative
}

nonisolated struct WasmElemSegment {
    var type: WasmValType
    var items: [WasmConstExpr]
    var mode: WasmElemMode
}

nonisolated enum WasmDataMode {
    case passive
    case active(memory: Int, offset: WasmConstExpr)
}

nonisolated struct WasmDataSegment {
    var bytes: [UInt8]
    var mode: WasmDataMode
}

/// A function body as found in the code section (decoded lazily by the compiler).
nonisolated struct WasmBody {
    var locals: [WasmValType]
    /// Byte range of the instruction sequence (after the locals) in the module bytes.
    var codeStart: Int
    var codeEnd: Int
}

nonisolated enum WasmError: Error {
    case compile(String)
    case link(String)
    case trap(String)
    /// A JS exception is pending in the context (thrown by an import).
    case jsException
    /// Call stack exhausted (a RangeError in JS).
    case stackOverflow
}

/// A decoded (and, once `WasmCompiler` ran, validated) module.
nonisolated final class WasmModule {
    let bytes: [UInt8]
    var types: [WasmFuncType] = []
    var imports: [WasmImport] = []
    /// Type index of every function, imported ones first.
    var funcTypes: [Int] = []
    var importedFuncCount = 0
    var tables: [WasmTableType] = []
    var importedTableCount = 0
    var memories: [WasmLimits] = []
    var importedMemoryCount = 0
    var globals: [WasmGlobalType] = []
    var importedGlobalCount = 0
    var globalDefs: [WasmGlobalDef] = []
    var exports: [WasmExport] = []
    var start: Int?
    var elems: [WasmElemSegment] = []
    var datas: [WasmDataSegment] = []
    var dataCount: Int?
    var bodies: [WasmBody] = []
    var customSections: [(name: String, bytes: [UInt8])] = []
    /// Functions `ref.func` may name (C.refs, §3.4.10): referenced outside function bodies.
    var declaredFuncRefs: Set<Int> = []
    /// Compiled code of every defined function (filled by `WasmCompiler.compile`).
    var code: [WasmCompiledFunction] = []

    init(bytes: [UInt8]) { self.bytes = bytes }

    /// Decodes, validates and compiles `bytes`.
    static func compile(_ bytes: [UInt8]) throws -> WasmModule {
        let m = WasmModule(bytes: bytes)
        var d = WasmDecoder(bytes: bytes)
        try d.decodeModule(into: m)
        try WasmCompiler.compileAll(m)
        return m
    }
}

/// Reader over the module bytes (§5.1-5.5).
nonisolated struct WasmDecoder {
    let bytes: [UInt8]
    var pos = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    func fail(_ msg: String, at p: Int? = nil) -> WasmError {
        .compile("WebAssembly.Module doesn't parse at byte \(p ?? pos): \(msg)")
    }

    var atEnd: Bool { pos >= bytes.count }

    mutating func byte() throws -> UInt8 {
        guard pos < bytes.count else { throw fail("unexpected end of input") }
        let b = bytes[pos]
        pos += 1
        return b
    }

    mutating func u32() throws -> UInt32 {
        var result: UInt32 = 0
        var shift: UInt32 = 0
        while true {
            let b = try byte()
            if shift == 28, b & 0x70 != 0 { throw fail("can't parse integer (too large)") }
            result |= UInt32(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift > 28 { throw fail("can't parse integer (too long)") }
        }
    }

    /// Signed LEB128 of `bits` bits (§5.2.2): at most ceil(bits / 7) bytes, the unused bits of the
    /// last byte a sign extension.
    mutating func sleb(_ bits: Int) throws -> Int64 {
        let maxBytes = (bits + 6) / 7
        var result: Int64 = 0
        var shift = 0
        for i in 0..<maxBytes {
            let b = try byte()
            let payload = Int64(b & 0x7F)
            if i == maxBytes - 1 {
                let used = bits - shift
                guard b & 0x80 == 0 else { throw fail("can't parse signed \(bits)-bit integer (too long)") }
                let signBit = (payload >> Int64(used - 1)) & 1
                let rest = payload >> Int64(used)
                let expected: Int64 = signBit == 1 ? (1 << Int64(7 - used)) - 1 : 0
                guard rest == expected else { throw fail("can't parse signed \(bits)-bit integer (too large)") }
                result |= payload << Int64(shift)
                if bits < 64 { let s = Int64(64 - bits); result = (result << s) >> s }
                return result
            }
            result |= payload << Int64(shift)
            shift += 7
            if b & 0x80 == 0 {
                if b & 0x40 != 0 { result |= -1 << Int64(shift) }
                return result
            }
        }
        throw fail("can't parse signed integer")
    }

    mutating func s32() throws -> Int32 { Int32(truncatingIfNeeded: try sleb(32)) }
    mutating func s33() throws -> Int64 { try sleb(33) }
    mutating func s64() throws -> Int64 { try sleb(64) }

    mutating func fixed32() throws -> UInt32 {
        guard pos + 4 <= bytes.count else { throw fail("unexpected end of input") }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[pos + i]) << (8 * UInt32(i)) }
        pos += 4
        return v
    }

    mutating func fixed64() throws -> UInt64 {
        guard pos + 8 <= bytes.count else { throw fail("unexpected end of input") }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[pos + i]) << (8 * UInt64(i)) }
        pos += 8
        return v
    }

    mutating func name() throws -> String {
        let n = Int(try u32())
        guard pos + n <= bytes.count else { throw fail("unexpected end of input") }
        let slice = bytes[pos..<(pos + n)]
        guard let s = String(validating: slice, as: UTF8.self) else { throw fail("invalid UTF-8 name") }
        pos += n
        return s
    }

    mutating func valType() throws -> WasmValType {
        let at = pos
        let b = try byte()
        guard let t = WasmValType(rawValue: b), t != .v128 else { throw fail("invalid value type 0x\(String(b, radix: 16))", at: at) }
        return t
    }

    mutating func refType() throws -> WasmValType {
        let at = pos
        let t = try valType()
        guard t.isRef else { throw fail("invalid reference type", at: at) }
        return t
    }

    /// `maxAllowed` bounds the minimum, and the maximum too when `boundMax` (memories: 2^16 pages
    /// is a validity rule, §3.2.4); a table's maximum may be anything up to 2^32 - 1 (JSC / V8 clamp it).
    mutating func limits(maxAllowed: UInt32, boundMax: Bool = true) throws -> WasmLimits {
        let flag = try byte()
        switch flag {
        case 0x00:
            let mn = try u32()
            guard mn <= maxAllowed else { throw fail("initial size is too large") }
            return WasmLimits(min: mn, max: nil)
        case 0x01:
            let mn = try u32(), mx = try u32()
            guard mn <= maxAllowed else { throw fail("initial size is too large") }
            guard !boundMax || mx <= maxAllowed else { throw fail("maximum size is too large") }
            guard mn <= mx else { throw fail("size minimum must not be greater than maximum") }
            return WasmLimits(min: mn, max: mx)
        case 0x02, 0x03: throw fail("shared memory is not supported")
        default: throw fail("invalid limits flags")
        }
    }

    /// The largest memory, in 64 KiB pages (JavaScriptCore's limit: 4 GiB = 65 536 pages).
    static let maxMemoryPages: UInt32 = 65536
    static let maxTableSize: UInt32 = 10_000_000

    mutating func constExpr(_ m: WasmModule, expected: WasmValType, globalsVisible: Int) throws -> WasmConstExpr {
        var ops: [WasmConstOp] = []
        var stack: [WasmValType] = []
        while true {
            let at = pos
            let op = try byte()
            switch op {
            case 0x0B:
                guard stack.count == 1, stack[0] == expected else { throw fail("constant expression has the wrong type", at: at) }
                if ops.count == 1, case .push(let e) = ops[0] { return e }
                return .program(ops)
            case 0x41: ops.append(.push(.i32(try s32()))); stack.append(.i32)
            case 0x42: ops.append(.push(.i64(try s64()))); stack.append(.i64)
            case 0x43: ops.append(.push(.f32(try fixed32()))); stack.append(.f32)
            case 0x44: ops.append(.push(.f64(try fixed64()))); stack.append(.f64)
            case 0x23:
                let g = Int(try u32())
                guard g < globalsVisible, g < m.globals.count else { throw fail("global.get of an unknown global in a constant expression", at: at) }
                guard !m.globals[g].mutable else { throw fail("constant expression reads a mutable global", at: at) }
                ops.append(.push(.globalGet(g)))
                stack.append(m.globals[g].type)
            case 0xD0:
                let t = try refType()
                ops.append(.push(.refNull(t)))
                stack.append(t)
            case 0xD2:
                let f = Int(try u32())
                guard f < m.funcTypes.count else { throw fail("ref.func of an unknown function", at: at) }
                m.declaredFuncRefs.insert(f)
                ops.append(.push(.refFunc(f)))
                stack.append(.funcref)
            case 0x6A, 0x6B, 0x6C, 0x7C, 0x7D, 0x7E:
                let is32 = op <= 0x6C
                let t: WasmValType = is32 ? .i32 : .i64
                guard stack.count >= 2, stack[stack.count - 1] == t, stack[stack.count - 2] == t else {
                    throw fail("constant expression operand type mismatch", at: at)
                }
                stack.removeLast()
                switch op {
                case 0x6A: ops.append(.i32Add)
                case 0x6B: ops.append(.i32Sub)
                case 0x6C: ops.append(.i32Mul)
                case 0x7C: ops.append(.i64Add)
                case 0x7D: ops.append(.i64Sub)
                default: ops.append(.i64Mul)
                }
            default:
                throw fail("invalid instruction in a constant expression", at: at)
            }
        }
    }

    // MARK: Module

    mutating func decodeModule(into m: WasmModule) throws {
        guard bytes.count >= 8, bytes[0] == 0x00, bytes[1] == 0x61, bytes[2] == 0x73, bytes[3] == 0x6D else {
            throw WasmError.compile("WebAssembly.Module doesn't parse at byte 0: module doesn't start with '\\0asm'")
        }
        guard bytes[4] == 1, bytes[5] == 0, bytes[6] == 0, bytes[7] == 0 else {
            throw WasmError.compile("WebAssembly.Module doesn't parse at byte 4: unexpected version number")
        }
        pos = 8
        var lastID: UInt8 = 0
        // Section order (§5.5.2): type import func table memory tag global export start elem datacount code data.
        func order(_ id: UInt8) -> Int {
            switch id {
            case 1: return 1
            case 2: return 2
            case 3: return 3
            case 4: return 4
            case 5: return 5
            case 13: return 6
            case 6: return 7
            case 7: return 8
            case 8: return 9
            case 9: return 10
            case 12: return 11
            case 10: return 12
            case 11: return 13
            default: return 0
            }
        }
        var funcCount: Int?
        var sawData = false
        while !atEnd {
            let id = try byte()
            let size = Int(try u32())
            let start = pos
            guard start + size <= bytes.count else { throw fail("section size is past the end of the module") }
            let end = start + size
            if id == 0 {
                let n = try name()
                guard pos <= end else { throw fail("custom section name is past the section") }
                m.customSections.append((n, Array(bytes[pos..<end])))
                pos = end
                continue
            }
            let o = order(id)
            guard o != 0 else { throw fail("invalid section id \(id)", at: start - 2) }
            guard o > order(lastID) || lastID == 0 else { throw fail("section \(id) is out of order") }
            lastID = id
            switch id {
            case 1: try typeSection(m)
            case 2: try importSection(m)
            case 3:
                let n = Int(try u32())
                funcCount = n
                for _ in 0..<n {
                    let t = Int(try u32())
                    guard t < m.types.count else { throw fail("function uses an unknown type") }
                    m.funcTypes.append(t)
                }
            case 4:
                let n = Int(try u32())
                for _ in 0..<n {
                    let t = try refType()
                    m.tables.append(WasmTableType(elem: t, limits: try limits(maxAllowed: Self.maxTableSize, boundMax: false)))
                }
            case 5:
                let n = Int(try u32())
                for _ in 0..<n { m.memories.append(try limits(maxAllowed: Self.maxMemoryPages)) }
                guard m.memories.count <= 1 else { throw fail("multiple memories are not supported") }
            case 13: throw fail("exception handling (tag section) is not supported")
            case 6:
                let n = Int(try u32())
                for _ in 0..<n {
                    let t = try valType()
                    let mutByte = try byte()
                    guard mutByte <= 1 else { throw fail("invalid global mutability") }
                    let gt = WasmGlobalType(type: t, mutable: mutByte == 1)
                    let visible = m.globals.count
                    let e = try constExpr(m, expected: t, globalsVisible: visible)
                    m.globals.append(gt)
                    m.globalDefs.append(WasmGlobalDef(type: gt, initExpr: e))
                }
            case 7:
                let n = Int(try u32())
                // By code points: Swift's String == is canonical equivalence ("\u{C5}" == "A\u{30A}").
                var names = Set<[UInt8]>()
                for _ in 0..<n {
                    let nm = try name()
                    guard names.insert(Array(nm.utf8)).inserted else { throw fail("duplicate export name '\(nm)'") }
                    guard let k = WasmExportKind(rawValue: try byte()) else { throw fail("invalid export kind") }
                    let idx = Int(try u32())
                    switch k {
                    case .function:
                        guard idx < m.funcTypes.count else { throw fail("export of an unknown function") }
                        m.declaredFuncRefs.insert(idx)
                    case .table: guard idx < m.tables.count else { throw fail("export of an unknown table") }
                    case .memory: guard idx < m.memories.count else { throw fail("export of an unknown memory") }
                    case .global: guard idx < m.globals.count else { throw fail("export of an unknown global") }
                    }
                    m.exports.append(WasmExport(name: nm, kind: k, index: idx))
                }
            case 8:
                let f = Int(try u32())
                guard f < m.funcTypes.count else { throw fail("start function is unknown") }
                let t = m.types[m.funcTypes[f]]
                guard t.params.isEmpty, t.results.isEmpty else { throw fail("start function must take no arguments and return nothing") }
                m.start = f
            case 9: try elemSection(m)
            case 12: m.dataCount = Int(try u32())
            case 10:
                let n = Int(try u32())
                guard n == (funcCount ?? 0) else { throw fail("function and code section have inconsistent lengths") }
                for _ in 0..<n {
                    let size = Int(try u32())
                    let bodyEnd = pos + size
                    guard bodyEnd <= end else { throw fail("function body is past the section") }
                    var locals: [WasmValType] = []
                    let groups = Int(try u32())
                    var total = 0
                    for _ in 0..<groups {
                        let c = Int(try u32())
                        total += c
                        guard total <= 50_000 else { throw fail("too many locals") }
                        let t = try valType()
                        locals.append(contentsOf: repeatElement(t, count: c))
                    }
                    guard pos <= bodyEnd else { throw fail("function locals are past the body") }
                    m.bodies.append(WasmBody(locals: locals, codeStart: pos, codeEnd: bodyEnd))
                    pos = bodyEnd
                }
            case 11:
                sawData = true
                let n = Int(try u32())
                if let dc = m.dataCount, dc != n { throw fail("data section and data count section have inconsistent lengths") }
                for _ in 0..<n {
                    let flag = try u32()
                    var mode: WasmDataMode
                    switch flag {
                    case 0: mode = .active(memory: 0, offset: try constExpr(m, expected: .i32, globalsVisible: m.globals.count))
                    case 1: mode = .passive
                    case 2:
                        let mi = Int(try u32())
                        mode = .active(memory: mi, offset: try constExpr(m, expected: .i32, globalsVisible: m.globals.count))
                    default: throw fail("invalid data segment flags")
                    }
                    if case .active(let mi, _) = mode, mi >= m.memories.count { throw fail("data segment for an unknown memory") }
                    let len = Int(try u32())
                    guard pos + len <= end else { throw fail("data segment is past the section") }
                    m.datas.append(WasmDataSegment(bytes: Array(bytes[pos..<(pos + len)]), mode: mode))
                    pos += len
                }
            default: break
            }
            guard pos == end else { throw fail("section \(id) has the wrong size", at: end) }
        }
        if (funcCount ?? 0) != m.bodies.count { throw fail("function and code section have inconsistent lengths") }
        if !sawData, let dc = m.dataCount, dc != 0 { throw fail("data section and data count section have inconsistent lengths") }
    }

    private mutating func typeSection(_ m: WasmModule) throws {
        let n = Int(try u32())
        for _ in 0..<n {
            let form = try byte()
            guard form == 0x60 else { throw fail("invalid function type form") }
            let np = Int(try u32())
            var params: [WasmValType] = []
            for _ in 0..<np { params.append(try valType()) }
            let nr = Int(try u32())
            var results: [WasmValType] = []
            for _ in 0..<nr { results.append(try valType()) }
            m.types.append(WasmFuncType(params: params, results: results))
        }
    }

    private mutating func importSection(_ m: WasmModule) throws {
        let n = Int(try u32())
        for _ in 0..<n {
            let mod = try name()
            let nm = try name()
            let kind = try byte()
            switch kind {
            case 0:
                let t = Int(try u32())
                guard t < m.types.count else { throw fail("import uses an unknown type") }
                m.imports.append(WasmImport(module: mod, name: nm, desc: .function(typeIndex: t)))
                m.funcTypes.append(t)
                m.importedFuncCount += 1
            case 1:
                let t = try refType()
                let tt = WasmTableType(elem: t, limits: try limits(maxAllowed: Self.maxTableSize, boundMax: false))
                m.imports.append(WasmImport(module: mod, name: nm, desc: .table(tt)))
                m.tables.append(tt)
                m.importedTableCount += 1
            case 2:
                let l = try limits(maxAllowed: Self.maxMemoryPages)
                m.imports.append(WasmImport(module: mod, name: nm, desc: .memory(l)))
                m.memories.append(l)
                m.importedMemoryCount += 1
                guard m.memories.count <= 1 else { throw fail("multiple memories are not supported") }
            case 3:
                let t = try valType()
                let mutByte = try byte()
                guard mutByte <= 1 else { throw fail("invalid global mutability") }
                let gt = WasmGlobalType(type: t, mutable: mutByte == 1)
                m.imports.append(WasmImport(module: mod, name: nm, desc: .global(gt)))
                m.globals.append(gt)
                m.importedGlobalCount += 1
            case 4: throw fail("tag imports are not supported")
            default: throw fail("invalid import kind")
            }
        }
    }

    private mutating func elemSection(_ m: WasmModule) throws {
        let n = Int(try u32())
        for _ in 0..<n {
            let flag = try u32()
            guard flag <= 7 else { throw fail("invalid element segment flags") }
            let passiveOrDecl = flag & 1 != 0
            let explicitTable = flag & 2 != 0
            let usesExprs = flag & 4 != 0
            var mode: WasmElemMode
            if passiveOrDecl {
                mode = explicitTable ? .declarative : .passive
            } else {
                let table = explicitTable ? Int(try u32()) : 0
                guard table < m.tables.count else { throw fail("element segment for an unknown table") }
                mode = .active(table: table, offset: try constExpr(m, expected: .i32, globalsVisible: m.globals.count))
            }
            var type: WasmValType = .funcref
            if passiveOrDecl || explicitTable {
                if usesExprs { type = try refType() }
                else {
                    let kind = try byte()
                    guard kind == 0 else { throw fail("invalid element kind") }
                }
            }
            var items: [WasmConstExpr] = []
            let count = Int(try u32())
            for _ in 0..<count {
                if usesExprs {
                    items.append(try constExpr(m, expected: type, globalsVisible: m.globals.count))
                } else {
                    let f = Int(try u32())
                    guard f < m.funcTypes.count else { throw fail("element segment names an unknown function") }
                    m.declaredFuncRefs.insert(f)
                    items.append(.refFunc(f))
                }
            }
            if case .active(let t, _) = mode, m.tables[t].elem != type { throw fail("element segment type does not match its table") }
            m.elems.append(WasmElemSegment(type: type, items: items, mode: mode))
        }
    }
}
