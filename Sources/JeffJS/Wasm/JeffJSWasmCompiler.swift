// JeffJSWasmCompiler.swift
// JeffJS — WebAssembly (issue #13): function-body validation and compilation.
//
// WebAssembly Core 2.0 §3.3 (instruction validation) and Appendix "Validation
// Algorithm": one pass over each body with an operand-type stack and a control
// stack. Because a validated body's operand-stack height is known at every
// instruction, the compiled code addresses stack *slots* directly — slot 0 ..< L
// are the locals (parameters first), slot L + i is operand-stack position i — so
// the interpreter keeps no stack pointer and `drop` / `nop` / `block` compile to
// nothing. Branches carry their target, the height to restore and how many values
// to carry (copied only when they are not already in place).
//
// Copyright 2026 Jeff Bachand. All rights reserved.

import Foundation

/// One compiled instruction. `s` is the slot the instruction works on (its first operand / its
/// result); `a` and `b` are its immediates (see `WasmOp`).
nonisolated struct WasmInstr {
    var op: WasmOp
    var s: UInt32
    var a: UInt32
    var b: UInt64
}

nonisolated struct WasmBranchTarget {
    var pc: UInt32
    var dest: UInt32
    var keep: UInt32
}

nonisolated final class WasmCompiledFunction {
    let typeIndex: Int
    let paramCount: Int
    let localCount: Int        // parameters included
    let resultCount: Int
    /// Locals plus the deepest operand stack: the slots a frame needs.
    let frameSize: Int
    let code: [WasmInstr]
    let branchTables: [WasmBranchTarget]
    /// Slots `paramCount ..< localCount` start as zero (every value type's default bit pattern).
    init(typeIndex: Int, paramCount: Int, localCount: Int, resultCount: Int, frameSize: Int,
         code: [WasmInstr], branchTables: [WasmBranchTarget]) {
        self.typeIndex = typeIndex
        self.paramCount = paramCount
        self.localCount = localCount
        self.resultCount = resultCount
        self.frameSize = frameSize
        self.code = code
        self.branchTables = branchTables
    }
}

/// Interpreter operations. Naming: the wasm instruction, then the slot convention.
nonisolated enum WasmOp: UInt16 {
    // Control
    case unreachable, br, brIf, brUnless, brTable, ret, call, callIndirect
    case jump   // unconditional jump to `a` (the end of an `if` arm), nothing to move
    // Locals / globals (s = dest or source slot, a = local slot / global index)
    case localGet, localSet, localTee, globalGet, globalSet, copySlot
    case select   // s: v1 at s, v2 at s+1, cond at s+2 → s
    // Constants (s = dest, b = bits)
    case const_
    // Memory (s = address slot / result, b = static offset)
    case i32Load, i64Load, f32Load, f64Load
    case i32Load8S, i32Load8U, i32Load16S, i32Load16U
    case i64Load8S, i64Load8U, i64Load16S, i64Load16U, i64Load32S, i64Load32U
    case i32Store, i64Store, f32Store, f64Store, i32Store8, i32Store16, i64Store8, i64Store16, i64Store32
    case memorySize, memoryGrow, memoryInit, dataDrop, memoryCopy, memoryFill
    // Tables / refs
    case tableGet, tableSet, tableSize, tableGrow, tableFill, tableCopy, tableInit, elemDrop
    case refNull, refIsNull, refFunc
    // i32 unary/binary (binary: s, s+1 → s)
    case i32Eqz, i32Eq, i32Ne, i32LtS, i32LtU, i32GtS, i32GtU, i32LeS, i32LeU, i32GeS, i32GeU
    case i64Eqz, i64Eq, i64Ne, i64LtS, i64LtU, i64GtS, i64GtU, i64LeS, i64LeU, i64GeS, i64GeU
    case f32Eq, f32Ne, f32Lt, f32Gt, f32Le, f32Ge
    case f64Eq, f64Ne, f64Lt, f64Gt, f64Le, f64Ge
    case i32Clz, i32Ctz, i32Popcnt, i32Add, i32Sub, i32Mul, i32DivS, i32DivU, i32RemS, i32RemU
    case i32And, i32Or, i32Xor, i32Shl, i32ShrS, i32ShrU, i32Rotl, i32Rotr
    case i64Clz, i64Ctz, i64Popcnt, i64Add, i64Sub, i64Mul, i64DivS, i64DivU, i64RemS, i64RemU
    case i64And, i64Or, i64Xor, i64Shl, i64ShrS, i64ShrU, i64Rotl, i64Rotr
    case f32Abs, f32Neg, f32Ceil, f32Floor, f32Trunc, f32Nearest, f32Sqrt
    case f32Add, f32Sub, f32Mul, f32Div, f32Min, f32Max, f32Copysign
    case f64Abs, f64Neg, f64Ceil, f64Floor, f64Trunc, f64Nearest, f64Sqrt
    case f64Add, f64Sub, f64Mul, f64Div, f64Min, f64Max, f64Copysign
    case i32WrapI64, i32TruncF32S, i32TruncF32U, i32TruncF64S, i32TruncF64U
    case i64ExtendI32S, i64ExtendI32U, i64TruncF32S, i64TruncF32U, i64TruncF64S, i64TruncF64U
    case f32ConvertI32S, f32ConvertI32U, f32ConvertI64S, f32ConvertI64U, f32DemoteF64
    case f64ConvertI32S, f64ConvertI32U, f64ConvertI64S, f64ConvertI64U, f64PromoteF32
    case i32Extend8S, i32Extend16S, i64Extend8S, i64Extend16S, i64Extend32S
    case i32TruncSatF32S, i32TruncSatF32U, i32TruncSatF64S, i32TruncSatF64U
    case i64TruncSatF32S, i64TruncSatF32U, i64TruncSatF64S, i64TruncSatF64U
    // Fused: `local.get a; local.get b; i32.add` style patterns are left for later; the reinterpret
    // instructions and i64.extend_i32_u on a zero-extended slot are no-ops.
}

/// The validation algorithm's operand types: a value type, or "unknown" in unreachable code.
nonisolated enum WasmOperand: Equatable {
    case known(WasmValType)
    case unknown
}

nonisolated enum WasmCompiler {

    static func compileAll(_ m: WasmModule) throws {
        guard m.bodies.count == m.funcTypes.count - m.importedFuncCount else {
            throw WasmError.compile("WebAssembly.Module doesn't validate: function and code section have inconsistent lengths")
        }
        var out: [WasmCompiledFunction] = []
        out.reserveCapacity(m.bodies.count)
        for (i, body) in m.bodies.enumerated() {
            let funcIndex = m.importedFuncCount + i
            var c = FunctionCompiler(module: m, funcIndex: funcIndex, body: body)
            out.append(try c.compile())
        }
        m.code = out
    }

    private struct Control {
        enum Kind { case block, loop, ifThen, ifElse, function }
        var kind: Kind
        var params: [WasmValType]
        var results: [WasmValType]
        /// Operand-stack height (types) at entry, below the params.
        var height: Int
        var unreachable = false
        /// For a loop: where `br` jumps. Else: patched at `end`.
        var loopStart: Int = 0
        /// Code positions whose `a` (target pc) is this label's end.
        var pendingJumps: [Int] = []
        /// Branch-table entries whose `pc` is this label's end.
        var pendingTableEntries: [Int] = []
        /// The `if` instruction to patch at `else` / `end`.
        var ifInstr: Int = -1
        var labelTypes: [WasmValType] { kind == .loop ? params : results }
    }

    private struct FunctionCompiler {
        let m: WasmModule
        let funcIndex: Int
        let body: WasmBody
        var d: WasmDecoder
        var locals: [WasmValType] = []
        var stack: [WasmOperand] = []
        var ctrls: [Control] = []
        var code: [WasmInstr] = []
        var tables: [WasmBranchTarget] = []
        var maxHeight = 0

        init(module: WasmModule, funcIndex: Int, body: WasmBody) {
            self.m = module
            self.funcIndex = funcIndex
            self.body = body
            self.d = WasmDecoder(bytes: module.bytes)
            self.d.pos = body.codeStart
        }

        func err(_ msg: String) -> WasmError {
            .compile("WebAssembly.Module doesn't validate: \(msg), in function at index \(funcIndex)")
        }

        var slotBase: Int { locals.count }
        /// The absolute slot of operand-stack position `i`.
        func slot(_ i: Int) -> UInt32 { UInt32(slotBase + i) }

        mutating func push(_ t: WasmValType) {
            stack.append(.known(t))
            if stack.count > maxHeight { maxHeight = stack.count }
        }
        mutating func pushOperand(_ t: WasmOperand) {
            stack.append(t)
            if stack.count > maxHeight { maxHeight = stack.count }
        }

        mutating func pop() throws -> WasmOperand {
            let c = ctrls[ctrls.count - 1]
            if stack.count == c.height {
                if c.unreachable { return .unknown }
                throw err("can't pop empty stack")
            }
            return stack.removeLast()
        }

        @discardableResult
        mutating func pop(_ t: WasmValType) throws -> WasmOperand {
            let v = try pop()
            if case .known(let a) = v, a != t {
                throw err("type mismatch: expected \(t.name), got \(a.name)")
            }
            return v
        }

        mutating func pop(_ ts: [WasmValType]) throws {
            for t in ts.reversed() { try pop(t) }
        }

        mutating func push(_ ts: [WasmValType]) { for t in ts { push(t) } }

        mutating func emit(_ op: WasmOp, s: Int = 0, a: UInt32 = 0, b: UInt64 = 0) {
            code.append(WasmInstr(op: op, s: UInt32(max(0, s)), a: a, b: b))
        }

        var unreachableNow: Bool { ctrls[ctrls.count - 1].unreachable }

        mutating func setUnreachable() {
            let k = ctrls.count - 1
            stack.removeLast(stack.count - ctrls[k].height)
            ctrls[k].unreachable = true
        }

        mutating func blockType() throws -> (params: [WasmValType], results: [WasmValType]) {
            let at = d.pos
            let b = d.bytes[at]
            if b == 0x40 { d.pos += 1; return ([], []) }
            if let t = WasmValType(rawValue: b), t != .v128 { d.pos += 1; return ([], [t]) }
            let idx = try d.s33()
            guard idx >= 0, Int(idx) < m.types.count else { throw err("invalid block type") }
            let ft = m.types[Int(idx)]
            return (ft.params, ft.results)
        }

        func funcType(_ f: Int) -> WasmFuncType { m.types[m.funcTypes[f]] }

        mutating func localIndex() throws -> Int {
            let i = Int(try d.u32())
            guard i < locals.count else { throw err("local index \(i) is out of bounds") }
            return i
        }

        mutating func memArg(natural: Int) throws -> UInt64 {
            let align = try d.u32()
            let offset = try d.u32()
            guard !m.memories.isEmpty else { throw err("memory instruction without a memory") }
            guard align <= 31, (1 << align) <= natural else { throw err("alignment must not be larger than natural") }
            return UInt64(offset)
        }

        /// A branch to label `depth` from the current height: target, destination slot and
        /// how many values travel; registers the jump for patching when the label is a block.
        mutating func branch(_ depth: Int, op: WasmOp, condBelow: Bool) throws {
            guard depth < ctrls.count else { throw err("branch depth exceeds control stack") }
            let li = ctrls.count - 1 - depth
            let label = ctrls[li]
            let types = label.labelTypes
            try pop(types)
            push(types)
            let keep = types.count
            // `stack.count` is the height with the carried values on top (cond already popped).
            let src = stack.count - keep
            let dest = label.height
            let at = code.count
            emit(op, s: slotBase + dest, a: label.kind == .loop ? UInt32(label.loopStart) : 0,
                 b: UInt64(keep) | (UInt64(slotBase + src) << 32))
            if label.kind != .loop { ctrls[li].pendingJumps.append(at) }
            _ = condBelow
        }

        mutating func compile() throws -> WasmCompiledFunction {
            let ft = funcType(funcIndex)
            locals = ft.params + body.locals
            ctrls = [Control(kind: .function, params: [], results: ft.results, height: 0)]
            while !ctrls.isEmpty {
                guard d.pos < body.codeEnd else { throw err("function body must end with END opcode") }
                try instruction()
            }
            guard d.pos == body.codeEnd else { throw err("operators remaining after the end of the function") }
            let frame = locals.count + maxHeight + 1
            return WasmCompiledFunction(typeIndex: m.funcTypes[funcIndex], paramCount: ft.params.count,
                                        localCount: locals.count, resultCount: ft.results.count,
                                        frameSize: frame, code: code, branchTables: tables)
        }

        mutating func unary(_ op: WasmOp, _ from: WasmValType, _ to: WasmValType) throws {
            try pop(from)
            emit(op, s: Int(slot(stack.count)))
            push(to)
        }

        mutating func binary(_ op: WasmOp, _ t: WasmValType, _ to: WasmValType) throws {
            try pop(t); try pop(t)
            emit(op, s: Int(slot(stack.count)))
            push(to)
        }

        /// A conversion whose bit pattern is already right (reinterpret): typing only.
        mutating func retype(_ from: WasmValType, _ to: WasmValType) throws {
            try pop(from)
            push(to)
        }

        mutating func load(_ op: WasmOp, natural: Int, _ t: WasmValType) throws {
            let off = try memArg(natural: natural)
            try pop(.i32)
            emit(op, s: Int(slot(stack.count)), b: off)
            push(t)
        }

        mutating func store(_ op: WasmOp, natural: Int, _ t: WasmValType) throws {
            let off = try memArg(natural: natural)
            try pop(t); try pop(.i32)
            emit(op, s: Int(slot(stack.count)), b: off)
        }

        mutating func endBlock() throws {
            var c = ctrls[ctrls.count - 1]
            if c.kind == .ifThen {
                // An `if` without `else`: its params must equal its results (the implicit else).
                guard c.params == c.results else { throw err("if without else must have matching param and result types") }
            }
            try pop(c.results)
            guard stack.count == c.height else { throw err("block leaves extra values on the stack") }
            ctrls.removeLast()
            let here = UInt32(code.count)
            if c.kind == .ifThen, c.ifInstr >= 0 { code[c.ifInstr].a = here }
            for j in c.pendingJumps { code[j].a = here }
            for e in c.pendingTableEntries { tables[e].pc = here }
            c.pendingJumps.removeAll()
            if c.kind == .function {
                emit(.ret, s: 0, b: UInt64(c.results.count) | (UInt64(slotBase) << 32))
                return
            }
            push(c.results)
        }

        // swiftlint:disable:next cyclomatic_complexity function_body_length
        mutating func instruction() throws {
            let op = try d.byte()
            switch op {
            case 0x00:
                emit(.unreachable)
                setUnreachable()
            case 0x01: break
            case 0x02, 0x03:
                let bt = try blockType()
                try pop(bt.params)
                let h = stack.count
                push(bt.params)
                var c = Control(kind: op == 0x02 ? .block : .loop, params: bt.params, results: bt.results, height: h)
                c.loopStart = code.count
                ctrls.append(c)
            case 0x04:
                let bt = try blockType()
                try pop(.i32)
                try pop(bt.params)
                let h = stack.count
                // brUnless: jump to else/end when the condition (slot h + params) is zero.
                let condSlot = slotBase + h + bt.params.count
                var c = Control(kind: .ifThen, params: bt.params, results: bt.results, height: h)
                c.ifInstr = code.count
                emit(.brUnless, s: condSlot, a: 0, b: 0)
                push(bt.params)
                ctrls.append(c)
            case 0x05:
                var c = ctrls[ctrls.count - 1]
                guard c.kind == .ifThen else { throw err("else without matching if") }
                try pop(c.results)
                guard stack.count == c.height else { throw err("if arm leaves extra values on the stack") }
                // End of the then-arm: jump over the else-arm (values already in place).
                c.pendingJumps.append(code.count)
                emit(.jump)
                code[c.ifInstr].a = UInt32(code.count)
                c.ifInstr = -1
                c.kind = .ifElse
                c.unreachable = false
                ctrls[ctrls.count - 1] = c
                push(c.params)
            case 0x0B:
                try endBlock()
            case 0x0C:
                let depth = Int(try d.u32())
                try branch(depth, op: .br, condBelow: false)
                setUnreachable()
            case 0x0D:
                let depth = Int(try d.u32())
                try pop(.i32)
                // Condition at slot (height) after the carried values; `branch` computes src/dest.
                try branch(depth, op: .brIf, condBelow: true)
            case 0x0E:
                let n = Int(try d.u32())
                guard n < 1_000_000 else { throw err("br_table is too large") }
                var depths: [Int] = []
                for _ in 0..<n { depths.append(Int(try d.u32())) }
                let defaultDepth = Int(try d.u32())
                try pop(.i32)
                guard defaultDepth < ctrls.count else { throw err("br_table depth exceeds control stack") }
                let arity = ctrls[ctrls.count - 1 - defaultDepth].labelTypes.count
                for dp in depths + [defaultDepth] {
                    guard dp < ctrls.count else { throw err("br_table depth exceeds control stack") }
                    let lt = ctrls[ctrls.count - 1 - dp].labelTypes
                    guard lt.count == arity else { throw err("br_table targets have different arities") }
                    try pop(lt)
                    push(lt)
                }
                let src = stack.count - arity
                let start = tables.count
                for dp in depths + [defaultDepth] {
                    let li = ctrls.count - 1 - dp
                    let l = ctrls[li]
                    let e = tables.count
                    tables.append(WasmBranchTarget(pc: l.kind == .loop ? UInt32(l.loopStart) : 0,
                                                   dest: UInt32(slotBase + l.height), keep: UInt32(arity)))
                    if l.kind != .loop { ctrls[li].pendingTableEntries.append(e) }
                }
                emit(.brTable, s: slotBase + src, a: UInt32(start), b: UInt64(n))
                setUnreachable()
            case 0x0F:
                let r = ctrls[0].results
                try pop(r)
                push(r)
                emit(.ret, s: 0, b: UInt64(r.count) | (UInt64(slotBase + stack.count - r.count) << 32))
                setUnreachable()
            case 0x10:
                let f = Int(try d.u32())
                guard f < m.funcTypes.count else { throw err("call to an unknown function") }
                let t = funcType(f)
                try pop(t.params)
                let base = stack.count
                emit(.call, s: slotBase + base, a: UInt32(f))
                push(t.results)
                ensureFrameRoom(base + max(t.params.count, t.results.count))
            case 0x11:
                let ti = Int(try d.u32())
                let table = Int(try d.u32())
                guard ti < m.types.count else { throw err("call_indirect to an unknown type") }
                guard table < m.tables.count else { throw err("call_indirect to an unknown table") }
                guard m.tables[table].elem == .funcref else { throw err("call_indirect on a non-funcref table") }
                let t = m.types[ti]
                try pop(.i32)
                try pop(t.params)
                let base = stack.count
                emit(.callIndirect, s: slotBase + base, a: UInt32(ti), b: UInt64(table))
                push(t.results)
            case 0x1A:
                _ = try pop()
            case 0x1B, 0x1C:
                var explicit: WasmValType?
                if op == 0x1C {
                    let n = try d.u32()
                    guard n == 1 else { throw err("select must have exactly one type") }
                    explicit = try d.valType()
                }
                try pop(.i32)
                let t1 = try pop(), t2 = try pop()
                var result: WasmOperand
                if let e = explicit {
                    if case .known(let a) = t1, a != e { throw err("select operand type mismatch") }
                    if case .known(let a) = t2, a != e { throw err("select operand type mismatch") }
                    result = .known(e)
                } else {
                    if case .known(let a) = t1, a.isRef { throw err("untyped select of references") }
                    if case .known(let a) = t2, a.isRef { throw err("untyped select of references") }
                    if case .known(let a) = t1, case .known(let b) = t2, a != b { throw err("select operands have different types") }
                    result = t1 == .unknown ? t2 : t1
                }
                emit(.select, s: Int(slot(stack.count)))
                pushOperand(result)
            case 0x20:
                let i = try localIndex()
                emit(.localGet, s: Int(slot(stack.count)), a: UInt32(i))
                push(locals[i])
            case 0x21:
                let i = try localIndex()
                try pop(locals[i])
                emit(.localSet, s: Int(slot(stack.count)), a: UInt32(i))
            case 0x22:
                let i = try localIndex()
                try pop(locals[i])
                emit(.localTee, s: Int(slot(stack.count)), a: UInt32(i))
                push(locals[i])
            case 0x23:
                let g = Int(try d.u32())
                guard g < m.globals.count else { throw err("global.get of an unknown global") }
                emit(.globalGet, s: Int(slot(stack.count)), a: UInt32(g))
                push(m.globals[g].type)
            case 0x24:
                let g = Int(try d.u32())
                guard g < m.globals.count else { throw err("global.set of an unknown global") }
                guard m.globals[g].mutable else { throw err("global.set of an immutable global") }
                try pop(m.globals[g].type)
                emit(.globalSet, s: Int(slot(stack.count)), a: UInt32(g))
            case 0x25:
                let t = Int(try d.u32())
                guard t < m.tables.count else { throw err("table.get of an unknown table") }
                try pop(.i32)
                emit(.tableGet, s: Int(slot(stack.count)), a: UInt32(t))
                push(m.tables[t].elem)
            case 0x26:
                let t = Int(try d.u32())
                guard t < m.tables.count else { throw err("table.set of an unknown table") }
                try pop(m.tables[t].elem); try pop(.i32)
                emit(.tableSet, s: Int(slot(stack.count)), a: UInt32(t))
            case 0x28: try load(.i32Load, natural: 4, .i32)
            case 0x29: try load(.i64Load, natural: 8, .i64)
            case 0x2A: try load(.f32Load, natural: 4, .f32)
            case 0x2B: try load(.f64Load, natural: 8, .f64)
            case 0x2C: try load(.i32Load8S, natural: 1, .i32)
            case 0x2D: try load(.i32Load8U, natural: 1, .i32)
            case 0x2E: try load(.i32Load16S, natural: 2, .i32)
            case 0x2F: try load(.i32Load16U, natural: 2, .i32)
            case 0x30: try load(.i64Load8S, natural: 1, .i64)
            case 0x31: try load(.i64Load8U, natural: 1, .i64)
            case 0x32: try load(.i64Load16S, natural: 2, .i64)
            case 0x33: try load(.i64Load16U, natural: 2, .i64)
            case 0x34: try load(.i64Load32S, natural: 4, .i64)
            case 0x35: try load(.i64Load32U, natural: 4, .i64)
            case 0x36: try store(.i32Store, natural: 4, .i32)
            case 0x37: try store(.i64Store, natural: 8, .i64)
            case 0x38: try store(.f32Store, natural: 4, .f32)
            case 0x39: try store(.f64Store, natural: 8, .f64)
            case 0x3A: try store(.i32Store8, natural: 1, .i32)
            case 0x3B: try store(.i32Store16, natural: 2, .i32)
            case 0x3C: try store(.i64Store8, natural: 1, .i64)
            case 0x3D: try store(.i64Store16, natural: 2, .i64)
            case 0x3E: try store(.i64Store32, natural: 4, .i64)
            case 0x3F:
                guard try d.byte() == 0 else { throw err("memory.size reserved byte must be zero") }
                guard !m.memories.isEmpty else { throw err("memory.size without a memory") }
                emit(.memorySize, s: Int(slot(stack.count)))
                push(.i32)
            case 0x40:
                guard try d.byte() == 0 else { throw err("memory.grow reserved byte must be zero") }
                guard !m.memories.isEmpty else { throw err("memory.grow without a memory") }
                try pop(.i32)
                emit(.memoryGrow, s: Int(slot(stack.count)))
                push(.i32)
            case 0x41:
                let v = try d.s32()
                emit(.const_, s: Int(slot(stack.count)), b: UInt64(UInt32(bitPattern: v)))
                push(.i32)
            case 0x42:
                let v = try d.s64()
                emit(.const_, s: Int(slot(stack.count)), b: UInt64(bitPattern: v))
                push(.i64)
            case 0x43:
                let v = try d.fixed32()
                emit(.const_, s: Int(slot(stack.count)), b: UInt64(v))
                push(.f32)
            case 0x44:
                let v = try d.fixed64()
                emit(.const_, s: Int(slot(stack.count)), b: v)
                push(.f64)
            case 0x45: try unary(.i32Eqz, .i32, .i32)
            case 0x46: try binary(.i32Eq, .i32, .i32)
            case 0x47: try binary(.i32Ne, .i32, .i32)
            case 0x48: try binary(.i32LtS, .i32, .i32)
            case 0x49: try binary(.i32LtU, .i32, .i32)
            case 0x4A: try binary(.i32GtS, .i32, .i32)
            case 0x4B: try binary(.i32GtU, .i32, .i32)
            case 0x4C: try binary(.i32LeS, .i32, .i32)
            case 0x4D: try binary(.i32LeU, .i32, .i32)
            case 0x4E: try binary(.i32GeS, .i32, .i32)
            case 0x4F: try binary(.i32GeU, .i32, .i32)
            case 0x50: try unary(.i64Eqz, .i64, .i32)
            case 0x51: try binary(.i64Eq, .i64, .i32)
            case 0x52: try binary(.i64Ne, .i64, .i32)
            case 0x53: try binary(.i64LtS, .i64, .i32)
            case 0x54: try binary(.i64LtU, .i64, .i32)
            case 0x55: try binary(.i64GtS, .i64, .i32)
            case 0x56: try binary(.i64GtU, .i64, .i32)
            case 0x57: try binary(.i64LeS, .i64, .i32)
            case 0x58: try binary(.i64LeU, .i64, .i32)
            case 0x59: try binary(.i64GeS, .i64, .i32)
            case 0x5A: try binary(.i64GeU, .i64, .i32)
            case 0x5B: try binary(.f32Eq, .f32, .i32)
            case 0x5C: try binary(.f32Ne, .f32, .i32)
            case 0x5D: try binary(.f32Lt, .f32, .i32)
            case 0x5E: try binary(.f32Gt, .f32, .i32)
            case 0x5F: try binary(.f32Le, .f32, .i32)
            case 0x60: try binary(.f32Ge, .f32, .i32)
            case 0x61: try binary(.f64Eq, .f64, .i32)
            case 0x62: try binary(.f64Ne, .f64, .i32)
            case 0x63: try binary(.f64Lt, .f64, .i32)
            case 0x64: try binary(.f64Gt, .f64, .i32)
            case 0x65: try binary(.f64Le, .f64, .i32)
            case 0x66: try binary(.f64Ge, .f64, .i32)
            case 0x67: try unary(.i32Clz, .i32, .i32)
            case 0x68: try unary(.i32Ctz, .i32, .i32)
            case 0x69: try unary(.i32Popcnt, .i32, .i32)
            case 0x6A: try binary(.i32Add, .i32, .i32)
            case 0x6B: try binary(.i32Sub, .i32, .i32)
            case 0x6C: try binary(.i32Mul, .i32, .i32)
            case 0x6D: try binary(.i32DivS, .i32, .i32)
            case 0x6E: try binary(.i32DivU, .i32, .i32)
            case 0x6F: try binary(.i32RemS, .i32, .i32)
            case 0x70: try binary(.i32RemU, .i32, .i32)
            case 0x71: try binary(.i32And, .i32, .i32)
            case 0x72: try binary(.i32Or, .i32, .i32)
            case 0x73: try binary(.i32Xor, .i32, .i32)
            case 0x74: try binary(.i32Shl, .i32, .i32)
            case 0x75: try binary(.i32ShrS, .i32, .i32)
            case 0x76: try binary(.i32ShrU, .i32, .i32)
            case 0x77: try binary(.i32Rotl, .i32, .i32)
            case 0x78: try binary(.i32Rotr, .i32, .i32)
            case 0x79: try unary(.i64Clz, .i64, .i64)
            case 0x7A: try unary(.i64Ctz, .i64, .i64)
            case 0x7B: try unary(.i64Popcnt, .i64, .i64)
            case 0x7C: try binary(.i64Add, .i64, .i64)
            case 0x7D: try binary(.i64Sub, .i64, .i64)
            case 0x7E: try binary(.i64Mul, .i64, .i64)
            case 0x7F: try binary(.i64DivS, .i64, .i64)
            case 0x80: try binary(.i64DivU, .i64, .i64)
            case 0x81: try binary(.i64RemS, .i64, .i64)
            case 0x82: try binary(.i64RemU, .i64, .i64)
            case 0x83: try binary(.i64And, .i64, .i64)
            case 0x84: try binary(.i64Or, .i64, .i64)
            case 0x85: try binary(.i64Xor, .i64, .i64)
            case 0x86: try binary(.i64Shl, .i64, .i64)
            case 0x87: try binary(.i64ShrS, .i64, .i64)
            case 0x88: try binary(.i64ShrU, .i64, .i64)
            case 0x89: try binary(.i64Rotl, .i64, .i64)
            case 0x8A: try binary(.i64Rotr, .i64, .i64)
            case 0x8B: try unary(.f32Abs, .f32, .f32)
            case 0x8C: try unary(.f32Neg, .f32, .f32)
            case 0x8D: try unary(.f32Ceil, .f32, .f32)
            case 0x8E: try unary(.f32Floor, .f32, .f32)
            case 0x8F: try unary(.f32Trunc, .f32, .f32)
            case 0x90: try unary(.f32Nearest, .f32, .f32)
            case 0x91: try unary(.f32Sqrt, .f32, .f32)
            case 0x92: try binary(.f32Add, .f32, .f32)
            case 0x93: try binary(.f32Sub, .f32, .f32)
            case 0x94: try binary(.f32Mul, .f32, .f32)
            case 0x95: try binary(.f32Div, .f32, .f32)
            case 0x96: try binary(.f32Min, .f32, .f32)
            case 0x97: try binary(.f32Max, .f32, .f32)
            case 0x98: try binary(.f32Copysign, .f32, .f32)
            case 0x99: try unary(.f64Abs, .f64, .f64)
            case 0x9A: try unary(.f64Neg, .f64, .f64)
            case 0x9B: try unary(.f64Ceil, .f64, .f64)
            case 0x9C: try unary(.f64Floor, .f64, .f64)
            case 0x9D: try unary(.f64Trunc, .f64, .f64)
            case 0x9E: try unary(.f64Nearest, .f64, .f64)
            case 0x9F: try unary(.f64Sqrt, .f64, .f64)
            case 0xA0: try binary(.f64Add, .f64, .f64)
            case 0xA1: try binary(.f64Sub, .f64, .f64)
            case 0xA2: try binary(.f64Mul, .f64, .f64)
            case 0xA3: try binary(.f64Div, .f64, .f64)
            case 0xA4: try binary(.f64Min, .f64, .f64)
            case 0xA5: try binary(.f64Max, .f64, .f64)
            case 0xA6: try binary(.f64Copysign, .f64, .f64)
            case 0xA7: try unary(.i32WrapI64, .i64, .i32)
            case 0xA8: try unary(.i32TruncF32S, .f32, .i32)
            case 0xA9: try unary(.i32TruncF32U, .f32, .i32)
            case 0xAA: try unary(.i32TruncF64S, .f64, .i32)
            case 0xAB: try unary(.i32TruncF64U, .f64, .i32)
            case 0xAC: try unary(.i64ExtendI32S, .i32, .i64)
            case 0xAD: try retype(.i32, .i64)   // i64.extend_i32_u: slots hold i32s zero-extended
            case 0xAE: try unary(.i64TruncF32S, .f32, .i64)
            case 0xAF: try unary(.i64TruncF32U, .f32, .i64)
            case 0xB0: try unary(.i64TruncF64S, .f64, .i64)
            case 0xB1: try unary(.i64TruncF64U, .f64, .i64)
            case 0xB2: try unary(.f32ConvertI32S, .i32, .f32)
            case 0xB3: try unary(.f32ConvertI32U, .i32, .f32)
            case 0xB4: try unary(.f32ConvertI64S, .i64, .f32)
            case 0xB5: try unary(.f32ConvertI64U, .i64, .f32)
            case 0xB6: try unary(.f32DemoteF64, .f64, .f32)
            case 0xB7: try unary(.f64ConvertI32S, .i32, .f64)
            case 0xB8: try unary(.f64ConvertI32U, .i32, .f64)
            case 0xB9: try unary(.f64ConvertI64S, .i64, .f64)
            case 0xBA: try unary(.f64ConvertI64U, .i64, .f64)
            case 0xBB: try unary(.f64PromoteF32, .f32, .f64)
            case 0xBC: try retype(.f32, .i32)
            case 0xBD: try retype(.f64, .i64)
            case 0xBE: try retype(.i32, .f32)
            case 0xBF: try retype(.i64, .f64)
            case 0xC0: try unary(.i32Extend8S, .i32, .i32)
            case 0xC1: try unary(.i32Extend16S, .i32, .i32)
            case 0xC2: try unary(.i64Extend8S, .i64, .i64)
            case 0xC3: try unary(.i64Extend16S, .i64, .i64)
            case 0xC4: try unary(.i64Extend32S, .i64, .i64)
            case 0xD0:
                let t = try d.refType()
                emit(.refNull, s: Int(slot(stack.count)))
                push(t)
            case 0xD1:
                let v = try pop()
                if case .known(let t) = v, !t.isRef { throw err("ref.is_null of a non-reference") }
                emit(.refIsNull, s: Int(slot(stack.count)))
                push(.i32)
            case 0xD2:
                let f = Int(try d.u32())
                guard f < m.funcTypes.count else { throw err("ref.func of an unknown function") }
                guard m.declaredFuncRefs.contains(f) else { throw err("ref.func of an undeclared function reference") }
                emit(.refFunc, s: Int(slot(stack.count)), a: UInt32(f))
                push(.funcref)
            case 0xFC:
                try prefixed()
            case 0xFD:
                throw err("SIMD instructions are not supported")
            case 0xFE:
                throw err("atomic instructions are not supported")
            default:
                throw err("invalid opcode 0x\(String(op, radix: 16))")
            }
        }

        mutating func ensureFrameRoom(_ height: Int) {
            if height > maxHeight { maxHeight = height }
        }

        mutating func prefixed() throws {
            let sub = try d.u32()
            switch sub {
            case 0: try unary(.i32TruncSatF32S, .f32, .i32)
            case 1: try unary(.i32TruncSatF32U, .f32, .i32)
            case 2: try unary(.i32TruncSatF64S, .f64, .i32)
            case 3: try unary(.i32TruncSatF64U, .f64, .i32)
            case 4: try unary(.i64TruncSatF32S, .f32, .i64)
            case 5: try unary(.i64TruncSatF32U, .f32, .i64)
            case 6: try unary(.i64TruncSatF64S, .f64, .i64)
            case 7: try unary(.i64TruncSatF64U, .f64, .i64)
            case 8:
                let seg = Int(try d.u32())
                guard try d.byte() == 0 else { throw err("memory.init reserved byte must be zero") }
                guard !m.memories.isEmpty else { throw err("memory.init without a memory") }
                guard let dc = m.dataCount else { throw err("memory.init requires a data count section") }
                guard seg < dc else { throw err("memory.init of an unknown data segment") }
                try pop(.i32); try pop(.i32); try pop(.i32)
                emit(.memoryInit, s: Int(slot(stack.count)), a: UInt32(seg))
            case 9:
                let seg = Int(try d.u32())
                guard let dc = m.dataCount else { throw err("data.drop requires a data count section") }
                guard seg < dc else { throw err("data.drop of an unknown data segment") }
                emit(.dataDrop, a: UInt32(seg))
            case 10:
                guard try d.byte() == 0, try d.byte() == 0 else { throw err("memory.copy reserved bytes must be zero") }
                guard !m.memories.isEmpty else { throw err("memory.copy without a memory") }
                try pop(.i32); try pop(.i32); try pop(.i32)
                emit(.memoryCopy, s: Int(slot(stack.count)))
            case 11:
                guard try d.byte() == 0 else { throw err("memory.fill reserved byte must be zero") }
                guard !m.memories.isEmpty else { throw err("memory.fill without a memory") }
                try pop(.i32); try pop(.i32); try pop(.i32)
                emit(.memoryFill, s: Int(slot(stack.count)))
            case 12:
                let seg = Int(try d.u32())
                let t = Int(try d.u32())
                guard seg < m.elems.count else { throw err("table.init of an unknown element segment") }
                guard t < m.tables.count else { throw err("table.init of an unknown table") }
                guard m.elems[seg].type == m.tables[t].elem else { throw err("table.init type mismatch") }
                try pop(.i32); try pop(.i32); try pop(.i32)
                emit(.tableInit, s: Int(slot(stack.count)), a: UInt32(seg), b: UInt64(t))
            case 13:
                let seg = Int(try d.u32())
                guard seg < m.elems.count else { throw err("elem.drop of an unknown element segment") }
                emit(.elemDrop, a: UInt32(seg))
            case 14:
                let dst = Int(try d.u32()), src = Int(try d.u32())
                guard dst < m.tables.count, src < m.tables.count else { throw err("table.copy of an unknown table") }
                guard m.tables[dst].elem == m.tables[src].elem else { throw err("table.copy type mismatch") }
                try pop(.i32); try pop(.i32); try pop(.i32)
                emit(.tableCopy, s: Int(slot(stack.count)), a: UInt32(dst), b: UInt64(src))
            case 15:
                let t = Int(try d.u32())
                guard t < m.tables.count else { throw err("table.grow of an unknown table") }
                try pop(.i32); try pop(m.tables[t].elem)
                emit(.tableGrow, s: Int(slot(stack.count)), a: UInt32(t))
                push(.i32)
            case 16:
                let t = Int(try d.u32())
                guard t < m.tables.count else { throw err("table.size of an unknown table") }
                emit(.tableSize, s: Int(slot(stack.count)), a: UInt32(t))
                push(.i32)
            case 17:
                let t = Int(try d.u32())
                guard t < m.tables.count else { throw err("table.fill of an unknown table") }
                try pop(.i32); try pop(m.tables[t].elem); try pop(.i32)
                emit(.tableFill, s: Int(slot(stack.count)), a: UInt32(t))
            default:
                throw err("invalid 0xFC opcode \(sub)")
            }
        }
    }
}
