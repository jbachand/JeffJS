// JeffJSCompiler.swift
// JeffJS - 1:1 Swift port of QuickJS JavaScript engine
//
// Post-parse compilation passes that transform raw bytecode emitted by the
// parser into optimized final bytecode.  Ports resolve_variables(),
// resolve_labels(), and js_create_function() from QuickJS (quickjs.c).
//
// Copyright 2026 Jeff Bachand. All rights reserved.

import Foundation

// =============================================================================
// MARK: - Compiler-Specific Supporting Types
// =============================================================================

/// Scope variable definition used during compilation.
/// Mirrors `JSVarDef` in QuickJS.
struct JeffJSVarDef {
    var varName: JSAtom = 0
    var scopeLevel: Int = 0
    var scopeNext: Int = -1          // next var in same scope (-1 = end)
    var isConst: Bool = false
    var isLexical: Bool = false
    var isCaptured: Bool = false
    var varKind: Int = JSVarKindEnum.JS_VAR_NORMAL.rawValue
    var funcPoolIdx: Int = -1        // for function declarations
    var isExported: Bool = false
}

/// Closure variable reference stored in a compiled function.
/// Mirrors `JSClosureVar` in QuickJS.
struct JeffJSClosureVar {
    var varName: JSAtom = 0
    var isLocal: Bool = false        // true => captured from parent's locals
    var isArg: Bool = false          // true => captured from parent's args
    var isConst: Bool = false
    var isLexical: Bool = false
    var varKind: Int = JSVarKindEnum.JS_VAR_NORMAL.rawValue
    var varIdx: Int = 0              // index in parent (local/arg) or var_ref
}

/// Label slot used during bytecode compilation.
/// Mirrors `LabelSlot` in QuickJS.
struct JeffJSLabelSlot {
    var refCount: Int = 0            // number of references to this label
    var pos: Int = -1                // bytecode position (-1 if unresolved)
    var pos2: Int = -1               // secondary pos for peephole
    var addr: Int = -1               // resolved byte address
    var firstReloc: Int = -1         // head of relocation linked list
}

/// Label relocation entry.
struct JeffJSRelocEntry {
    var kind: RelocKind
    var pos: Int                     // offset in bytecode buffer where the reloc sits
    var next: Int                    // next reloc in linked list (-1 = end)

    enum RelocKind: Int {
        case rel32 = 0               // 32-bit relative offset
        case rel8 = 1                // 8-bit relative offset (short jump)
        case rel16 = 2               // 16-bit relative offset
    }
}

/// Scope definition used during parsing/compilation.
struct JeffJSScopeDef {
    var parent: Int = -1             // parent scope index (-1 = none)
    var first: Int = -1              // first variable in scope
}

/// Bytecode variable definition in the final function bytecode.
struct JeffJSBytecodeVarDef {
    var varName: JSAtom = 0
    var scopeNext: Int = -1
    var isConst: Bool = false
    var isLexical: Bool = false
    var isCaptured: Bool = false
    var hasScope: Bool = false
    var varKind: Int = JSVarKindEnum.JS_VAR_NORMAL.rawValue
    var varRefIdx: UInt16 = 0
}

// =============================================================================
// MARK: - JeffJSFunctionDefCompiler
// =============================================================================

/// Extended function definition used by the compiler.  The parser builds this,
/// then the compiler resolves variables and labels to produce final bytecode.
/// Mirrors `JSFunctionDef` in QuickJS.
class JeffJSFunctionDefCompiler {
    // -- Parent linkage --
    weak var parent: JeffJSFunctionDefCompiler?
    var childFunctions: [JeffJSFunctionDefCompiler] = []
    /// Byte ranges of hoisted function declarations (fclosure + scope_put_var_init).
    /// Stored as (startOffset, endOffset) in byteCode. These are moved to the
    /// beginning of the function body before label resolution.
    var hoistedFuncDeclRanges: [(Int, Int)] = []
    /// Atoms for top-level `var` declarations that need hoisting via `define_var`.
    /// Collected during parsing and inserted at position 0 by `parseProgram`.
    var hoistedGlobalVarAtoms: [JSAtom] = []
    /// Bytecode position where the function body starts (after prologue/args).
    var bodyBytecodeStart: Int = 0

    // -- Function identity --
    var funcName: JSAtom = 0
    var hasSimpleParameterList: Bool = true
    var isDerivedClassConstructor: Bool = false
    var hasPrototype: Bool = false
    var needHomeObject: Bool = false
    var isDirectOrIndirectEval: Bool = false
    var newTargetAllowed: Bool = false
    var superCallAllowed: Bool = false
    var superAllowed: Bool = false
    var argumentsAllowed: Bool = true
    var isArrow: Bool = false          // true for arrow functions (no own this/arguments)
    var funcKind: Int = JSFunctionKindEnum.JS_FUNC_NORMAL.rawValue
    var jsMode: Int = 0
    var funcNameVarIdx: Int = -1       // local var index for named function expression self-reference
    var definedScopeLevel: Int = 0     // scope level in parent where this function was defined

    // -- Source info --
    var filename: JSAtom = 0
    var lineNum: Int = 1
    var source: String?

    // -- Bytecode under construction --
    var byteCode: DynBuf = DynBuf()

    // -- Variables --
    var vars: [JeffJSVarDef] = []      // local variables
    var args: [JeffJSVarDef] = []      // parameters
    var closureVar: [JeffJSClosureVar] = []
    var argCount: Int = 0
    var varCount: Int { return vars.count }

    // -- Scopes --
    var scopes: [JeffJSScopeDef] = [JeffJSScopeDef()]  // scope 0 = function body scope
    var curScope: Int = 0

    // -- Labels --
    var labels: [JeffJSLabelSlot] = []
    var relocs: [JeffJSRelocEntry] = []

    // -- Constant pool --
    var cpool: [JeffJSValue] = []

    // -- Flags set during compilation --
    var hasEval: Bool = false
    var hasArguments: Bool = false
    var hasThisBinding: Bool = false
    var hasNewTarget: Bool = false
    var needsHomeObject: Bool = false
    var usesArguments: Bool = false
    var isGlobalVar: Bool = false

    // -- Debug line/column info --
    var pc2lineBuf: DynBuf = DynBuf()
    var pc2colBuf: DynBuf = DynBuf()
    var lastLineNum: Int = 1
    var lastColNum: Int = 1
    var lastPC: Int = 0
    var lastColPC: Int = 0

    // -- Stack --
    var stackSize: Int = 0

    init() {}
}

// =============================================================================
// MARK: - JeffJSFunctionBytecodeCompiled
// =============================================================================

/// The compiled bytecode object produced by createFunction.
/// This extends the JeffJSFunctionBytecode stub in JeffJSObject.swift with
/// all fields needed by the interpreter.
class JeffJSFunctionBytecodeCompiled: JeffJSFunctionBytecode {
    // All fields are inherited from JeffJSFunctionBytecode.
    // Additional compiler-produced fields:
    var vardefs: [JeffJSBytecodeVarDef] = []
    var closureVars: [JeffJSClosureVar] = []
    var closureVarCountInt: Int = 0
    var funcNameAtom: JSAtom = 0
    var jsModeFlags: UInt8 = 0
    var funcKindValue: Int = 0
    var newTargetAllowedFlag: Bool = false
    var superCallAllowedFlag: Bool = false
    var superAllowedFlag: Bool = false
    var argumentsAllowedFlag: Bool = false
    var hasDebugInfo: Bool = false
    var readOnlyBytecodeFlag: Bool = false
    var isDirectOrIndirectEvalFlag: Bool = false
    var funcNameVarIdx: Int = -1       // local var index for named function expression self-reference
    var debugFilenameAtom: JSAtom = 0
    var debugSourceLen: Int = 0
    var debugPc2lineLen: Int = 0
    var debugPc2lineBuf: [UInt8] = []
    var debugPc2colLen: Int = 0
    var debugPc2colBuf: [UInt8] = []
    var debugSourceStr: String?
    var definedArgCountValue: UInt16 = 0
    var varRefCountValue: UInt16 = 0
    var cpoolCountValue: Int = 0

    /// Decode the pc2line buffer to find the source line number for a given PC offset.
    /// Returns the 1-based line number, or 0 if debug info is unavailable.
    func lineForPC(_ targetPC: Int) -> Int {
        guard debugPc2lineLen > 0, !debugPc2lineBuf.isEmpty else { return 0 }
        let bufLen = debugPc2lineBuf.count
        var pc = 0
        var line = 1
        var offset = 0
        while offset < bufLen {
            let byte = Int(debugPc2lineBuf[offset])
            offset += 1
            if byte == 0 {
                // Multi-byte: two SLEB128 values (pcDelta, lineDelta)
                guard offset < bufLen else { break }
                let (pcDelta, off1) = getSLEB128(debugPc2lineBuf, offset)
                guard off1 <= bufLen else { break }
                guard off1 < bufLen else {
                    // Only one SLEB128 fits — treat as pcDelta only
                    pc += Int(pcDelta)
                    break
                }
                let (lineDelta, off2) = getSLEB128(debugPc2lineBuf, off1)
                guard off2 <= bufLen else { break }
                offset = off2
                pc += Int(pcDelta)
                line += Int(lineDelta)
            } else {
                // Compact single-byte encoding
                let val = byte - PC2LINE_OP_FIRST
                let pcDelta = val / PC2LINE_RANGE
                let lineDelta = (val % PC2LINE_RANGE) + PC2LINE_BASE
                pc += pcDelta
                line += lineDelta
            }
            if pc > targetPC { break }
        }
        return max(1, line)
    }

    /// Decode the pc2col buffer to find the source column number for a given PC offset.
    /// Returns the 1-based column number, or 0 if debug info is unavailable.
    func colForPC(_ targetPC: Int) -> Int {
        guard debugPc2colLen > 0, !debugPc2colBuf.isEmpty else { return 0 }
        let bufLen = debugPc2colBuf.count
        var pc = 0
        var col = 1
        var offset = 0
        while offset < bufLen {
            let byte = Int(debugPc2colBuf[offset])
            offset += 1
            if byte == 0 {
                guard offset < bufLen else { break }
                let (pcDelta, off1) = getSLEB128(debugPc2colBuf, offset)
                guard off1 <= bufLen else { break }
                guard off1 < bufLen else {
                    pc += Int(pcDelta)
                    break
                }
                let (colDelta, off2) = getSLEB128(debugPc2colBuf, off1)
                guard off2 <= bufLen else { break }
                offset = off2
                pc += Int(pcDelta)
                col += Int(colDelta)
            } else {
                let val = byte - PC2LINE_OP_FIRST
                let pcDelta = val / PC2LINE_RANGE
                let colDelta = (val % PC2LINE_RANGE) + PC2LINE_BASE
                pc += pcDelta
                col += colDelta
            }
            if pc > targetPC { break }
        }
        return max(1, col)
    }

    /// Extract source context around a given line (50 chars before/after the line start).
    func sourceSnippet(forLine lineNum: Int) -> (snippet: String, caretCol: Int)? {
        guard let src = debugSourceStr, !src.isEmpty, lineNum > 0 else { return nil }
        let lines = src.components(separatedBy: "\n")
        let idx = lineNum - 1
        guard idx >= 0 && idx < lines.count else { return nil }
        let sourceLine = lines[idx]
        let trimmed = sourceLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        // Show up to 100 chars of the line
        let snippet = trimmed.count > 100 ? String(trimmed.prefix(100)) + "…" : trimmed
        return (snippet, 1)
    }
}

// =============================================================================
// MARK: - JeffJSCompiler
// =============================================================================

struct JeffJSCompiler {

    // =========================================================================
    // MARK: 1. Variable Resolution Pass (resolve_variables)
    // =========================================================================

    /// Main resolution pass.  Rewrites every OP_scope_* opcode to a concrete
    /// local/arg/var_ref/global access opcode.
    ///
    /// Port of `resolve_variables()` from QuickJS quickjs.c.
    /// Returns true on success, false on error.
    @discardableResult
    static func resolveVariables(ctx: JeffJSContext,
                                 fd: JeffJSFunctionDefCompiler) -> Bool {
        // TDZ: scope 0 (function body scope) has no enter_scope opcode,
        // so we must insert set_loc_uninitialized opcodes for lexical
        // variables in scope 0 at the beginning of the bytecode.
        var scope0TdzBytes: [UInt8] = []
        if fd.scopes.count > 0 {
            var s0VarIdx = fd.scopes[0].first
            while s0VarIdx >= 0 && s0VarIdx < fd.vars.count {
                if fd.vars[s0VarIdx].isLexical {
                    scope0TdzBytes.append(UInt8(truncatingIfNeeded: JeffJSOpcode.set_loc_uninitialized.rawValue))
                    scope0TdzBytes.append(UInt8(s0VarIdx & 0xFF))
                    scope0TdzBytes.append(UInt8((s0VarIdx >> 8) & 0xFF))
                }
                s0VarIdx = fd.vars[s0VarIdx].scopeNext
            }
        }
        if !scope0TdzBytes.isEmpty {
            let insertLen = scope0TdzBytes.count
            fd.byteCode.buf.insert(contentsOf: scope0TdzBytes, at: 0)
            fd.byteCode.len += insertLen
            // Adjust byte offsets that were set during parsing
            fd.bodyBytecodeStart += insertLen
            fd.hoistedFuncDeclRanges = fd.hoistedFuncDeclRanges.map {
                ($0.0 + insertLen, $0.1 + insertLen)
            }
        }

        var pos = 0
        // NOTE: We read from fd.byteCode.buf / fd.byteCode.len directly
        // (not a snapshot) because leave_scope handling may insert bytes
        // into the buffer, shifting subsequent positions.

        while pos < fd.byteCode.len {
            guard pos < fd.byteCode.buf.count else { break }
            guard let (op, opWidth) = readOpcodeFromBuf(fd.byteCode.buf, pos) else {
                pos += 1
                continue
            }
            let info = jeffJSGetOpcodeInfo(op)
            // The info-table size assumes a 1-byte opcode. Wide opcodes
            // (rawValue >= 256) use 2 bytes, so add the extra byte.
            let instrSize = max(Int(info.size) + (opWidth - 1), 1)
            // Operands start after the opcode byte(s)
            let operandBase = pos + opWidth

            switch op {

            // -----------------------------------------------------------------
            // scope_get_var(atom, scope_level)
            // -----------------------------------------------------------------
            case .scope_get_var:
                let atom = readU32(fd.byteCode.buf, operandBase)
                let scopeLevel = Int(readU16(fd.byteCode.buf, operandBase + 4))
                let (resolvedOp, varIdx) = resolveScopeVar(
                    ctx: ctx, fd: fd, name: atom,
                    scopeLevel: scopeLevel,
                    opType: ScopeAccessType.get.rawValue
                )
                rewriteScopeAccess(fd: fd, pos: pos, origSize: instrSize,
                                   newOp: resolvedOp, varIdx: varIdx,
                                   atom: atom, accessType: .get)

            // -----------------------------------------------------------------
            // scope_get_var (with "undef" semantics via opType)
            //   Actually encoded the same way; the parser sets a flag.
            //   We differentiate in resolveScopeVar via accessType.
            // -----------------------------------------------------------------

            // -----------------------------------------------------------------
            // scope_put_var(atom, scope_level)
            // -----------------------------------------------------------------
            case .scope_put_var:
                let atom = readU32(fd.byteCode.buf, operandBase)
                let scopeLevel = Int(readU16(fd.byteCode.buf, operandBase + 4))
                let (resolvedOp, varIdx) = resolveScopeVar(
                    ctx: ctx, fd: fd, name: atom,
                    scopeLevel: scopeLevel,
                    opType: ScopeAccessType.put.rawValue
                )
                rewriteScopeAccess(fd: fd, pos: pos, origSize: instrSize,
                                   newOp: resolvedOp, varIdx: varIdx,
                                   atom: atom, accessType: .put)

            // -----------------------------------------------------------------
            // scope_put_var_init(atom, scope_level)
            // -----------------------------------------------------------------
            case .scope_put_var_init:
                let atom = readU32(fd.byteCode.buf, operandBase)
                let scopeLevel = Int(readU16(fd.byteCode.buf, operandBase + 4))
                let (resolvedOp, varIdx) = resolveScopeVar(
                    ctx: ctx, fd: fd, name: atom,
                    scopeLevel: scopeLevel,
                    opType: ScopeAccessType.putInit.rawValue
                )
                rewriteScopeAccess(fd: fd, pos: pos, origSize: instrSize,
                                   newOp: resolvedOp, varIdx: varIdx,
                                   atom: atom, accessType: .putInit)

            // -----------------------------------------------------------------
            // scope_delete_var(atom, scope_level)
            // -----------------------------------------------------------------
            case .scope_delete_var:
                let atom = readU32(fd.byteCode.buf, operandBase)
                let scopeLevel = Int(readU16(fd.byteCode.buf, operandBase + 4))
                let (resolvedOp, varIdx) = resolveScopeVar(
                    ctx: ctx, fd: fd, name: atom,
                    scopeLevel: scopeLevel,
                    opType: ScopeAccessType.delete.rawValue
                )
                rewriteScopeAccess(fd: fd, pos: pos, origSize: instrSize,
                                   newOp: resolvedOp, varIdx: varIdx,
                                   atom: atom, accessType: .delete)

            // -----------------------------------------------------------------
            // scope_make_ref(atom, label, scope_level)
            // -----------------------------------------------------------------
            case .scope_make_ref:
                let atom = readU32(fd.byteCode.buf, operandBase)
                // label at operandBase+4 (4 bytes)
                let scopeLevel = Int(readU16(fd.byteCode.buf, operandBase + 8))
                let (resolvedOp, varIdx) = resolveScopeVar(
                    ctx: ctx, fd: fd, name: atom,
                    scopeLevel: scopeLevel,
                    opType: ScopeAccessType.makeRef.rawValue
                )
                rewriteScopeMakeRef(fd: fd, pos: pos, origSize: instrSize,
                                    newOp: resolvedOp, varIdx: varIdx,
                                    atom: atom)

            // -----------------------------------------------------------------
            // scope_get_ref(atom, scope_level)
            // -----------------------------------------------------------------
            case .scope_get_ref:
                let atom = readU32(fd.byteCode.buf, operandBase)
                let scopeLevel = Int(readU16(fd.byteCode.buf, operandBase + 4))
                let (resolvedOp, varIdx) = resolveScopeVar(
                    ctx: ctx, fd: fd, name: atom,
                    scopeLevel: scopeLevel,
                    opType: ScopeAccessType.getRef.rawValue
                )
                rewriteScopeAccess(fd: fd, pos: pos, origSize: instrSize,
                                   newOp: resolvedOp, varIdx: varIdx,
                                   atom: atom, accessType: .getRef)

            // -----------------------------------------------------------------
            // scope_get_private_field(atom, scope_level)
            // -----------------------------------------------------------------
            case .scope_get_private_field:
                let atom = readU32(fd.byteCode.buf, operandBase)
                let scopeLevel = Int(readU16(fd.byteCode.buf, operandBase + 4))
                let (resolvedOp, varIdx) = resolveScopePrivateField(
                    ctx: ctx, fd: fd, name: atom, scopeLevel: scopeLevel
                )
                rewriteScopeAccess(fd: fd, pos: pos, origSize: instrSize,
                                   newOp: resolvedOp, varIdx: varIdx,
                                   atom: atom, accessType: .getPrivate)

            // -----------------------------------------------------------------
            // scope_put_private_field(atom, scope_level)
            // -----------------------------------------------------------------
            case .scope_put_private_field:
                let atom = readU32(fd.byteCode.buf, operandBase)
                let scopeLevel = Int(readU16(fd.byteCode.buf, operandBase + 4))
                let (resolvedOp, varIdx) = resolveScopePrivateField(
                    ctx: ctx, fd: fd, name: atom, scopeLevel: scopeLevel
                )
                rewriteScopeAccess(fd: fd, pos: pos, origSize: instrSize,
                                   newOp: resolvedOp, varIdx: varIdx,
                                   atom: atom, accessType: .putPrivate)

            // -----------------------------------------------------------------
            // scope_in_private_field(atom, scope_level)
            // -----------------------------------------------------------------
            case .scope_in_private_field:
                let atom = readU32(fd.byteCode.buf, operandBase)
                let scopeLevel = Int(readU16(fd.byteCode.buf, operandBase + 4))
                let (resolvedOp, varIdx) = resolveScopePrivateField(
                    ctx: ctx, fd: fd, name: atom, scopeLevel: scopeLevel
                )
                rewriteScopeAccess(fd: fd, pos: pos, origSize: instrSize,
                                   newOp: resolvedOp, varIdx: varIdx,
                                   atom: atom, accessType: .inPrivate)

            // -----------------------------------------------------------------
            // enter_scope -- emit set_loc_uninitialized for each lexical
            // variable in this scope so TDZ is enforced from scope entry.
            //
            // Uses the same insertion strategy as leave_scope → close_loc:
            // overwrite the enter_scope bytes first, then insert any extra
            // bytes that don't fit.
            // -----------------------------------------------------------------
            case .enter_scope:
                let esScopeIdx = Int(readU16(fd.byteCode.buf, operandBase))
                var tdzBytes: [UInt8] = []
                if esScopeIdx >= 0 && esScopeIdx < fd.scopes.count {
                    var esVarIdx = fd.scopes[esScopeIdx].first
                    while esVarIdx >= 0 && esVarIdx < fd.vars.count {
                        if fd.vars[esVarIdx].isLexical {
                            // set_loc_uninitialized(varIdx): opcode(1) + u16(2) = 3 bytes
                            tdzBytes.append(UInt8(truncatingIfNeeded: JeffJSOpcode.set_loc_uninitialized.rawValue))
                            tdzBytes.append(UInt8(esVarIdx & 0xFF))
                            tdzBytes.append(UInt8((esVarIdx >> 8) & 0xFF))
                        }
                        esVarIdx = fd.vars[esVarIdx].scopeNext
                    }
                }

                if tdzBytes.isEmpty {
                    nopOut(fd: fd, pos: pos, size: instrSize)
                } else {
                    nopOut(fd: fd, pos: pos, size: instrSize)

                    let totalTdzBytes = tdzBytes.count
                    let overwriteCount = min(totalTdzBytes, instrSize)
                    for i in 0 ..< overwriteCount {
                        fd.byteCode.buf[pos + i] = tdzBytes[i]
                    }

                    if totalTdzBytes > instrSize {
                        let extraBytes = Array(tdzBytes[instrSize...])
                        fd.byteCode.buf.insert(contentsOf: extraBytes, at: pos + instrSize)
                        fd.byteCode.len += extraBytes.count
                    }

                    pos += max(totalTdzBytes, instrSize)
                    continue  // skip the pos += instrSize at bottom of loop
                }

            // -----------------------------------------------------------------
            // leave_scope -- emit close_loc for each captured variable in the
            // scope, then NOP out the leave_scope opcode itself.
            //
            // In QuickJS, resolve_variables() replaces leave_scope with
            // close_loc opcodes so that captured lexical variables are
            // detached from the stack frame when their scope ends.  This is
            // essential for correct per-iteration capture semantics with
            // `let` in loops.
            //
            // The approach: collect the close_loc bytes we need to emit,
            // replace the leave_scope in-place with the first close_loc (both
            // are 3 bytes), and insert any remaining close_loc opcodes into
            // the buffer immediately after.  Because label references use
            // indices (not byte offsets) at this stage, insertions are safe.
            // -----------------------------------------------------------------
            case .leave_scope:
                let scopeIdx = Int(readU16(fd.byteCode.buf, operandBase))
                var closeLocBytes: [UInt8] = []
                if scopeIdx >= 0 && scopeIdx < fd.scopes.count {
                    var varIdx = fd.scopes[scopeIdx].first
                    while varIdx >= 0 && varIdx < fd.vars.count {
                        if fd.vars[varIdx].isCaptured {
                            // Emit close_loc(varIdx): opcode(1 byte) + u16(2 bytes)
                            closeLocBytes.append(UInt8(truncatingIfNeeded: JeffJSOpcode.close_loc.rawValue))
                            closeLocBytes.append(UInt8(varIdx & 0xFF))
                            closeLocBytes.append(UInt8((varIdx >> 8) & 0xFF))
                        }
                        varIdx = fd.vars[varIdx].scopeNext
                    }
                }

                if closeLocBytes.isEmpty {
                    // No captured variables in this scope -- just NOP it out
                    nopOut(fd: fd, pos: pos, size: instrSize)
                    pos += instrSize
                } else {
                    // leave_scope is a temporary opcode (2-byte encoding) with
                    // a u16 operand, so instrSize = 4.  Each close_loc is a
                    // regular opcode (1-byte) with u16 operand = 3 bytes.
                    //
                    // Strategy: NOP out the entire leave_scope, then overwrite
                    // starting at pos with ALL the close_loc opcodes.  If the
                    // total close_loc bytes exceed instrSize, insert the extras
                    // into the buffer (safe because label references at this
                    // stage use indices, not byte offsets).
                    nopOut(fd: fd, pos: pos, size: instrSize)

                    let totalCloseBytes = closeLocBytes.count
                    let overwriteCount = min(totalCloseBytes, instrSize)
                    for i in 0 ..< overwriteCount {
                        fd.byteCode.buf[pos + i] = closeLocBytes[i]
                    }

                    if totalCloseBytes > instrSize {
                        // Insert the extra bytes that don't fit in the
                        // leave_scope's original footprint.
                        let extraBytes = Array(closeLocBytes[instrSize...])
                        fd.byteCode.buf.insert(contentsOf: extraBytes, at: pos + instrSize)
                        fd.byteCode.len += extraBytes.count
                    }

                    // Advance pos past all the close_loc opcodes plus any
                    // leftover NOP bytes from the original leave_scope.
                    pos += max(totalCloseBytes, instrSize)
                }
                continue  // skip the pos += instrSize at bottom of loop

            default:
                break
            }

            pos += instrSize
        }

        // Add eval-accessible variables if this function contains eval()
        if fd.hasEval {
            addEvalVariables(ctx: ctx, fd: fd)
        }

        return true
    }

    // MARK: Scope Access Type

    enum ScopeAccessType: Int {
        case get = 0
        case getUndef = 1
        case put = 2
        case putInit = 3
        case delete = 4
        case makeRef = 5
        case getRef = 6
        case getPrivate = 7
        case putPrivate = 8
        case inPrivate = 9
    }

    // MARK: resolveScopeVar

    /// Resolve a single scope variable reference.
    /// Walks the scope chain from `scopeLevel` outward, then walks parent
    /// functions to find the binding.
    ///
    /// Returns the concrete opcode and variable index to use.
    static func resolveScopeVar(ctx: JeffJSContext,
                                fd: JeffJSFunctionDefCompiler,
                                name: JSAtom,
                                scopeLevel: Int,
                                opType: Int) -> (opcode: JeffJSOpcode, varIdx: Int) {
        // Check for pseudo-variables first
        if let pseudoResult = resolvePseudoVar(ctx: ctx, fd: fd, name: name) {
            return pseudoResult
        }

        // Search local variables in the current function, respecting scope
        let localResult = findLocalVar(fd: fd, name: name, scopeLevel: scopeLevel)
        if let (localIdx, varDef) = localResult {
            let accessType = ScopeAccessType(rawValue: opType) ?? .get
            return resolvedLocalAccess(fd: fd, localIdx: localIdx,
                                       varDef: varDef, accessType: accessType)
        }

        // Search arguments
        for i in 0 ..< fd.args.count {
            if fd.args[i].varName == name {
                let accessType = ScopeAccessType(rawValue: opType) ?? .get
                return resolvedArgAccess(fd: fd, argIdx: i, accessType: accessType)
            }
        }

        // Search parent functions (closure capture)
        var parentFd = fd.parent
        var curFd = fd
        while let p = parentFd {
            // Search parent locals respecting lexical scope. Use the child
            // function's definition scope level to find the correct binding
            // when multiple variables share the same name in different scopes.
            let parentScopeLevel = curFd.definedScopeLevel
            if let (i, varDef) = findLocalVar(fd: p, name: name, scopeLevel: parentScopeLevel) {
                    p.vars[i].isCaptured = true
                    let closureIdx = getClosureVar(
                        ctx: ctx, s: fd, fd: p,
                        isLocal: true, isArg: false,
                        varIdx: i, varName: name,
                        isConst: varDef.isConst,
                        isLexical: varDef.isLexical,
                        varKind: varDef.varKind
                    )
                    let accessType = ScopeAccessType(rawValue: opType) ?? .get
                    return resolvedVarRefAccess(closureIdx: closureIdx,
                                                isConst: varDef.isConst,
                                                isLexical: varDef.isLexical,
                                                accessType: accessType)
            }
            // Search parent args
            for i in 0 ..< p.args.count {
                if p.args[i].varName == name {
                    p.args[i].isCaptured = true
                    let closureIdx = getClosureVar(
                        ctx: ctx, s: fd, fd: p,
                        isLocal: true, isArg: true,
                        varIdx: i, varName: name,
                        isConst: false, isLexical: false,
                        varKind: JSVarKindEnum.JS_VAR_NORMAL.rawValue
                    )
                    let accessType = ScopeAccessType(rawValue: opType) ?? .get
                    return resolvedVarRefAccess(closureIdx: closureIdx,
                                                isConst: false,
                                                isLexical: false,
                                                accessType: accessType)
                }
            }
            curFd = p
            parentFd = p.parent
        }

        // Not found in any local scope -- treat as global
        let accessType = ScopeAccessType(rawValue: opType) ?? .get
        return resolvedGlobalAccess(accessType: accessType)
    }

    // MARK: resolveScopePrivateField

    /// Resolve a scope private field reference.
    /// Private fields are captured through the closure chain.
    static func resolveScopePrivateField(ctx: JeffJSContext,
                                          fd: JeffJSFunctionDefCompiler,
                                          name: JSAtom,
                                          scopeLevel: Int) -> (opcode: JeffJSOpcode, varIdx: Int) {
        // Search local variables
        for i in (0 ..< fd.vars.count).reversed() {
            if fd.vars[i].varName == name &&
               fd.vars[i].varKind >= JSVarKindEnum.JS_VAR_PRIVATE_FIELD.rawValue {
                return (.get_var_ref, i)
            }
        }

        // Search parent functions
        var parentFd = fd.parent
        var curFd = fd
        while let p = parentFd {
            for i in (0 ..< p.vars.count).reversed() {
                if p.vars[i].varName == name &&
                   p.vars[i].varKind >= JSVarKindEnum.JS_VAR_PRIVATE_FIELD.rawValue {
                    p.vars[i].isCaptured = true
                    let closureIdx = getClosureVar(
                        ctx: ctx, s: curFd, fd: p,
                        isLocal: true, isArg: false,
                        varIdx: i, varName: name,
                        isConst: p.vars[i].isConst,
                        isLexical: p.vars[i].isLexical,
                        varKind: p.vars[i].varKind
                    )
                    return (.get_var_ref, closureIdx)
                }
            }
            curFd = p
            parentFd = p.parent
        }

        // Should not happen -- private field must exist
        return (.nop, 0)
    }

    // MARK: captureVar

    /// Capture a variable from a parent function by creating the closure var chain.
    static func captureVar(ctx: JeffJSContext,
                           fd: JeffJSFunctionDefCompiler,
                           varIdx: Int) {
        guard varIdx < fd.vars.count else { return }
        fd.vars[varIdx].isCaptured = true
    }

    // MARK: getClosureVar

    /// Get or create a closure variable reference.
    /// Walks the parent chain and creates closure var entries as needed.
    /// Returns the closure var index in `s`.
    static func getClosureVar(ctx: JeffJSContext,
                               s: JeffJSFunctionDefCompiler,
                               fd: JeffJSFunctionDefCompiler,
                               isLocal: Bool,
                               isArg: Bool,
                               varIdx: Int,
                               varName: JSAtom,
                               isConst: Bool,
                               isLexical: Bool,
                               varKind: Int) -> Int {
        // Check if we already have this closure var
        for i in 0 ..< s.closureVar.count {
            let cv = s.closureVar[i]
            if cv.varName == varName && cv.isLocal == isLocal &&
               cv.varIdx == varIdx {
                return i
            }
        }

        // If the parent is not our immediate parent, we need to thread
        // the capture through intermediate functions.
        if let parent = s.parent, parent !== fd {
            // First, ensure the parent has it captured
            let parentClosureIdx: Int
            if isLocal {
                parentClosureIdx = getClosureVar(
                    ctx: ctx, s: parent, fd: fd,
                    isLocal: true, isArg: isArg,
                    varIdx: varIdx, varName: varName,
                    isConst: isConst, isLexical: isLexical,
                    varKind: varKind
                )
            } else {
                parentClosureIdx = getClosureVar(
                    ctx: ctx, s: parent, fd: fd,
                    isLocal: false, isArg: isArg,
                    varIdx: varIdx, varName: varName,
                    isConst: isConst, isLexical: isLexical,
                    varKind: varKind
                )
            }

            // Now create a closure var in s that references parent's closure var
            var cv = JeffJSClosureVar()
            cv.varName = varName
            cv.isLocal = false  // it is a var_ref from parent's closure
            cv.isArg = false
            cv.isConst = isConst
            cv.isLexical = isLexical
            cv.varKind = varKind
            cv.varIdx = parentClosureIdx
            s.closureVar.append(cv)
            return s.closureVar.count - 1
        }

        // Direct parent -- create closure var referencing parent's local/arg
        var cv = JeffJSClosureVar()
        cv.varName = varName
        cv.isLocal = isLocal
        cv.isArg = isArg
        cv.isConst = isConst
        cv.isLexical = isLexical
        cv.varKind = varKind
        cv.varIdx = varIdx
        s.closureVar.append(cv)
        return s.closureVar.count - 1
    }

    // MARK: resolvePseudoVar

    /// Resolve pseudo-variable references: `this`, `arguments`, `new.target`, etc.
    static func resolvePseudoVar(ctx: JeffJSContext,
                                  fd: JeffJSFunctionDefCompiler,
                                  name: JSAtom) -> (opcode: JeffJSOpcode, varIdx: Int)? {
        // `this` => push_this or special_object(this)
        if name == JSPredefinedAtom.this_.rawValue {
            return (.push_this, 0)
        }
        // `arguments` => special_object(arguments) or variable reference
        if name == JSPredefinedAtom.arguments_.rawValue {
            if fd.argumentsAllowed && fd.hasArguments {
                return nil  // let it be resolved as a regular local
            }
        }
        return nil
    }

    // MARK: addEvalVariables

    /// Add eval-accessible variables.
    /// When a function contains `eval()`, all local variables must be accessible
    /// dynamically.  This ensures proper closure var chain setup.
    static func addEvalVariables(ctx: JeffJSContext,
                                  fd: JeffJSFunctionDefCompiler) {
        // When a function uses eval, all its variables and parent variables
        // must be captured so eval can access them
        for i in 0 ..< fd.vars.count {
            fd.vars[i].isCaptured = true
        }
        for i in 0 ..< fd.args.count {
            fd.args[i].isCaptured = true
        }

        // Walk parent chain and mark their vars as captured too
        var p = fd.parent
        while let parent = p {
            if parent.hasEval {
                break  // already processed
            }
            for i in 0 ..< parent.vars.count {
                parent.vars[i].isCaptured = true
            }
            for i in 0 ..< parent.args.count {
                parent.args[i].isCaptured = true
            }
            p = parent.parent
        }
    }

    // =========================================================================
    // MARK: - Variable Resolution Helpers
    // =========================================================================

    /// Find a local variable by name within the given scope level.
    private static func findLocalVar(fd: JeffJSFunctionDefCompiler,
                                      name: JSAtom,
                                      scopeLevel: Int) -> (Int, JeffJSVarDef)? {
        // Walk scope chain from innermost to outermost
        var scope = scopeLevel
        while scope >= 0 && scope < fd.scopes.count {
            var varIdx = fd.scopes[scope].first
            while varIdx >= 0 && varIdx < fd.vars.count {
                if fd.vars[varIdx].varName == name {
                    return (varIdx, fd.vars[varIdx])
                }
                varIdx = fd.vars[varIdx].scopeNext
            }
            scope = fd.scopes[scope].parent
        }
        // Also check scope 0 variables that might not be in any scope chain.
        // Skip ALL lexically-scoped variables (let, const, catch, for-loop let).
        // These must only be found via their scope in the walk above. If the
        // scope walk didn't find them, the reference is outside their block
        // and must NOT resolve to them (ES spec: lexical scoping).
        // Only function-scoped `var` declarations (isLexical == false) are
        // visible throughout the entire function body.
        for i in 0 ..< fd.vars.count {
            if fd.vars[i].varName == name && !fd.vars[i].isLexical {
                return (i, fd.vars[i])
            }
        }
        return nil
    }

    /// Produce the resolved opcode + index for a local variable access.
    private static func resolvedLocalAccess(
        fd: JeffJSFunctionDefCompiler,
        localIdx: Int,
        varDef: JeffJSVarDef,
        accessType: ScopeAccessType
    ) -> (opcode: JeffJSOpcode, varIdx: Int) {
        switch accessType {
        case .get, .getUndef:
            if varDef.isLexical && varDef.isConst {
                return (.get_loc_check, localIdx)
            }
            if varDef.isLexical {
                return (.get_loc_check, localIdx)
            }
            return (.get_loc, localIdx)

        case .put:
            if varDef.isConst {
                // Assignment to const -- will be a runtime error
                return (.put_loc_check, localIdx)
            }
            if varDef.isLexical {
                return (.put_loc_check, localIdx)
            }
            return (.put_loc, localIdx)

        case .putInit:
            if varDef.isLexical {
                return (.put_loc_check_init, localIdx)
            }
            return (.put_loc, localIdx)

        case .delete:
            // delete on a local always returns false
            return (.push_false, 0)

        case .makeRef:
            return (.make_loc_ref, localIdx)

        case .getRef:
            return (.make_loc_ref, localIdx)

        default:
            return (.get_loc, localIdx)
        }
    }

    /// Produce the resolved opcode + index for an argument access.
    private static func resolvedArgAccess(
        fd: JeffJSFunctionDefCompiler,
        argIdx: Int,
        accessType: ScopeAccessType
    ) -> (opcode: JeffJSOpcode, varIdx: Int) {
        switch accessType {
        case .get, .getUndef:
            return (.get_arg, argIdx)
        case .put, .putInit:
            return (.put_arg, argIdx)
        case .delete:
            return (.push_false, 0)
        case .makeRef, .getRef:
            return (.make_arg_ref, argIdx)
        default:
            return (.get_arg, argIdx)
        }
    }

    /// Produce the resolved opcode + index for a closure variable access.
    private static func resolvedVarRefAccess(
        closureIdx: Int,
        isConst: Bool,
        isLexical: Bool,
        accessType: ScopeAccessType
    ) -> (opcode: JeffJSOpcode, varIdx: Int) {
        switch accessType {
        case .get, .getUndef:
            if isLexical {
                return (.get_var_ref_check, closureIdx)
            }
            return (.get_var_ref, closureIdx)

        case .put:
            if isConst {
                return (.put_var_ref_check, closureIdx)
            }
            if isLexical {
                return (.put_var_ref_check, closureIdx)
            }
            return (.put_var_ref, closureIdx)

        case .putInit:
            if isLexical {
                return (.put_var_ref_check_init, closureIdx)
            }
            return (.put_var_ref, closureIdx)

        case .delete:
            return (.push_false, 0)

        case .makeRef, .getRef:
            return (.make_var_ref_ref, closureIdx)

        default:
            return (.get_var_ref, closureIdx)
        }
    }

    /// Produce the resolved opcode for a global variable access.
    private static func resolvedGlobalAccess(
        accessType: ScopeAccessType
    ) -> (opcode: JeffJSOpcode, varIdx: Int) {
        switch accessType {
        case .get:
            return (.get_var, 0)
        case .getUndef:
            return (.get_var_undef, 0)
        case .put:
            return (.put_var, 0)
        case .putInit:
            return (.put_var_init, 0)
        case .delete:
            return (.delete_var, 0)
        case .makeRef:
            return (.make_var_ref, 0)
        case .getRef:
            return (.make_var_ref, 0)
        default:
            return (.get_var, 0)
        }
    }

    /// Rewrite a scope access opcode in the bytecode buffer.
    private static func rewriteScopeAccess(
        fd: JeffJSFunctionDefCompiler,
        pos: Int,
        origSize: Int,
        newOp: JeffJSOpcode,
        varIdx: Int,
        atom: JSAtom,
        accessType: ScopeAccessType
    ) {
        let newInfo = jeffJSGetOpcodeInfo(newOp)
        let newSize = Int(newInfo.size)

        // Write the new opcode
        fd.byteCode.buf[pos] = UInt8(truncatingIfNeeded: newOp.rawValue)

        // Write operands based on the new opcode's format
        switch newInfo.format {
        case .loc:
            // 3 bytes: opcode + u16 local index
            writeU16(&fd.byteCode.buf, pos + 1, UInt16(varIdx))
            // Pad remaining bytes with NOPs
            padWithNops(&fd.byteCode.buf, from: pos + newSize, count: origSize - newSize)

        case .arg:
            writeU16(&fd.byteCode.buf, pos + 1, UInt16(varIdx))
            padWithNops(&fd.byteCode.buf, from: pos + newSize, count: origSize - newSize)

        case .var_ref:
            writeU16(&fd.byteCode.buf, pos + 1, UInt16(varIdx))
            padWithNops(&fd.byteCode.buf, from: pos + newSize, count: origSize - newSize)

        case .atom:
            // Global access -- keep the atom
            writeU32(&fd.byteCode.buf, pos + 1, atom)
            padWithNops(&fd.byteCode.buf, from: pos + newSize, count: origSize - newSize)

        case .atom_u16:
            // make_loc_ref, make_arg_ref, make_var_ref_ref
            writeU32(&fd.byteCode.buf, pos + 1, atom)
            writeU16(&fd.byteCode.buf, pos + 5, UInt16(varIdx))
            padWithNops(&fd.byteCode.buf, from: pos + newSize, count: origSize - newSize)

        case .none, .none_int:
            // push_false, push_this, etc. -- single byte
            padWithNops(&fd.byteCode.buf, from: pos + newSize, count: origSize - newSize)

        default:
            padWithNops(&fd.byteCode.buf, from: pos + newSize, count: origSize - newSize)
        }
    }

    /// Rewrite a scope_make_ref opcode.
    private static func rewriteScopeMakeRef(
        fd: JeffJSFunctionDefCompiler,
        pos: Int,
        origSize: Int,
        newOp: JeffJSOpcode,
        varIdx: Int,
        atom: JSAtom
    ) {
        let newInfo = jeffJSGetOpcodeInfo(newOp)
        let newSize = Int(newInfo.size)

        fd.byteCode.buf[pos] = UInt8(truncatingIfNeeded: newOp.rawValue)

        switch newInfo.format {
        case .atom_u16:
            writeU32(&fd.byteCode.buf, pos + 1, atom)
            writeU16(&fd.byteCode.buf, pos + 5, UInt16(varIdx))
            padWithNops(&fd.byteCode.buf, from: pos + newSize, count: origSize - newSize)
        case .atom:
            writeU32(&fd.byteCode.buf, pos + 1, atom)
            padWithNops(&fd.byteCode.buf, from: pos + newSize, count: origSize - newSize)
        default:
            padWithNops(&fd.byteCode.buf, from: pos + newSize, count: origSize - newSize)
        }
    }

    /// Fill a range with NOP opcodes.
    private static func nopOut(fd: JeffJSFunctionDefCompiler,
                                pos: Int, size: Int) {
        for i in 0 ..< size {
            if pos + i < fd.byteCode.buf.count {
                fd.byteCode.buf[pos + i] = UInt8(truncatingIfNeeded: JeffJSOpcode.nop.rawValue)
            }
        }
    }

    private static func padWithNops(_ buf: inout [UInt8],
                                     from start: Int, count: Int) {
        for i in 0 ..< count {
            let idx = start + i
            if idx < buf.count {
                buf[idx] = UInt8(truncatingIfNeeded: JeffJSOpcode.nop.rawValue)
            }
        }
    }

    // =========================================================================
    // MARK: 2. Label Resolution and Peephole Optimization (resolve_labels)
    // =========================================================================

    /// Main label resolution and optimization pass.
    ///
    /// This is the core compiler pass that:
    /// 1. Processes opcodes sequentially, applying peephole optimizations
    /// 2. Resolves label references to byte offsets
    /// 3. Converts to short opcodes where possible
    /// 4. Computes the maximum stack depth
    ///
    /// Port of `resolve_labels()` from QuickJS quickjs.c.
    /// Returns true on success, false on error.
    @discardableResult
    static func resolveLabels(ctx: JeffJSContext,
                               fd: JeffJSFunctionDefCompiler) -> Bool {
        let srcBuf = fd.byteCode.buf
        let srcLen = fd.byteCode.len
        var bc = DynBuf()
        var pos = 0

        // Reset label addresses
        for i in 0 ..< fd.labels.count {
            fd.labels[i].addr = -1
        }

        // ------------------------------------------------------------------
        // Pass 1: Copy bytecode, apply peephole optimizations, resolve labels
        // ------------------------------------------------------------------
        while pos < srcLen {
            guard pos < srcBuf.count else { break }
            guard let (op, opWidth) = readOpcodeFromBuf(srcBuf, pos) else {
                bc.putU8(srcBuf[pos])
                pos += 1
                continue
            }

            // Skip NOPs
            if op == .nop {
                pos += 1
                continue
            }

            let info = jeffJSGetOpcodeInfo(op)
            // The info-table size assumes a 1-byte opcode. Wide opcodes
            // (rawValue >= 256) use 2 bytes, so add the extra byte.
            let instrSize = max(Int(info.size) + (opWidth - 1), 1)
            // Operands start after the opcode byte(s)
            let operandBase = pos + opWidth

            // Handle label definitions
            if op == .label_ {
                let labelIdx = Int(readU32(srcBuf, operandBase))
                if labelIdx < fd.labels.count {
                    fd.labels[labelIdx].addr = bc.len
                }
                pos += instrSize
                continue
            }

            // Handle line_num -- encode into pc2line and pc2col
            if op == .line_num {
                let lineNum = Int(readU32(srcBuf, operandBase))
                let colNum = Int(readU32(srcBuf, operandBase + 4))
                addPC2Line(fd: fd, pc: bc.len, lineNum: lineNum)
                addPC2Col(fd: fd, pc: bc.len, colNum: colNum)
                pos += instrSize
                continue
            }

            // ------------------------------------------------------------------
            // Peephole optimization window
            // ------------------------------------------------------------------
            let nextPos = pos + instrSize
            // Peephole lookahead: after resolveVariables, remaining opcodes at
            // nextPos are non-temporary (rawValue < 256) so single-byte read
            // is fine. Wide opcodes (line_num, opt_chain) are already handled
            // above or fall through to the default copy-verbatim case.
            let nextOp: JeffJSOpcode? = (nextPos < srcLen && nextPos < srcBuf.count)
                ? JeffJSOpcode(rawValue: UInt16(srcBuf[nextPos])) : nil

            // Optimization 1: push_i32(val) neg -> push_i32(-val)
            // Skip when val == 0: negating 0 must produce -0.0 (IEEE 754),
            // which push_i32(0) cannot represent.  This matters for
            // Object.is(0, -0) and 1/-0 === -Infinity.
            if op == .push_i32, nextOp == .neg {
                let val = Int32(bitPattern: readU32(srcBuf, pos + 1))
                if val != Int32.min && val != 0 {
                    pushShortInt(bc: &bc, val: -val)
                    pos = nextPos + 1  // skip neg opcode
                    continue
                }
            }

            // Optimization 2: undefined + return -> return_undef
            if op == .undefined, nextOp == .return_ {
                bc.putOpcode(JeffJSOpcode.return_undef.rawValue)
                pos = nextPos + 1
                continue
            }

            // Optimization 3: call(n) + return -> tail_call(n)
            if op == .call, nextOp == .return_ {
                let argc = readU16(srcBuf, pos + 1)
                bc.putOpcode(JeffJSOpcode.tail_call.rawValue)
                bc.putU16(argc)
                pos = nextPos + 1
                continue
            }

            // Optimization 3b: call_method(n) + return -> tail_call_method(n)
            if op == .call_method, nextOp == .return_ {
                let argc = readU16(srcBuf, pos + 1)
                bc.putOpcode(JeffJSOpcode.tail_call_method.rawValue)
                bc.putU16(argc)
                pos = nextPos + 1
                continue
            }

            // Optimization 4: push + drop -> nothing
            if isPushOpcode(op), nextOp == .drop {
                let pushInfo = jeffJSGetOpcodeInfo(op)
                if pushInfo.nPop == 0 && pushInfo.nPush == 1 {
                    pos = nextPos + 1  // skip both
                    continue
                }
            }

            // Optimization 5: push_null + strict_eq -> is_null
            if op == .push_null, nextOp == .strict_eq {
                bc.putOpcode(JeffJSOpcode.is_null.rawValue)
                pos = nextPos + 1
                continue
            }

            // Optimization 6: undefined + strict_eq -> is_undefined
            if op == .undefined, nextOp == .strict_eq {
                bc.putOpcode(JeffJSOpcode.is_undefined.rawValue)
                pos = nextPos + 1
                continue
            }

            // Optimization 7: get_field(atom("length")) -> get_length
            if op == .get_field {
                let atom = readU32(srcBuf, pos + 1)
                if atom == JSPredefinedAtom.length.rawValue {
                    bc.putOpcode(JeffJSOpcode.get_length.rawValue)
                    pos += instrSize
                    continue
                }
            }

            // Optimization 8: dup + put_loc(n) -> set_loc(n)
            if op == .dup, nextOp == .put_loc {
                let locIdx = readU16(srcBuf, nextPos + 1)
                putShortCode(bc: &bc, op: .set_loc, idx: Int(locIdx))
                pos = nextPos + 3
                continue
            }

            // Optimization 8b: dup + put_arg(n) -> set_arg(n)
            if op == .dup, nextOp == .put_arg {
                let argIdx = readU16(srcBuf, nextPos + 1)
                putShortCode(bc: &bc, op: .set_arg, idx: Int(argIdx))
                pos = nextPos + 3
                continue
            }

            // Optimization 8c: dup + put_var_ref(n) -> set_var_ref(n)
            if op == .dup, nextOp == .put_var_ref {
                let vrIdx = readU16(srcBuf, nextPos + 1)
                putShortCode(bc: &bc, op: .set_var_ref, idx: Int(vrIdx))
                pos = nextPos + 3
                continue
            }

            // Optimization 9: put_loc(n) + get_loc(n) -> set_loc(n)
            if op == .put_loc, nextOp == .get_loc {
                let putIdx = readU16(srcBuf, pos + 1)
                let getIdx = readU16(srcBuf, nextPos + 1)
                if putIdx == getIdx {
                    putShortCode(bc: &bc, op: .set_loc, idx: Int(putIdx))
                    pos = nextPos + 3
                    continue
                }
            }

            // Optimization 9b: put_arg(n) + get_arg(n) -> set_arg(n)
            if op == .put_arg, nextOp == .get_arg {
                let putIdx = readU16(srcBuf, pos + 1)
                let getIdx = readU16(srcBuf, nextPos + 1)
                if putIdx == getIdx {
                    putShortCode(bc: &bc, op: .set_arg, idx: Int(putIdx))
                    pos = nextPos + 3
                    continue
                }
            }

            // Optimization 9c: put_var_ref(n) + get_var_ref(n) -> set_var_ref(n)
            if op == .put_var_ref, nextOp == .get_var_ref {
                let putIdx = readU16(srcBuf, pos + 1)
                let getIdx = readU16(srcBuf, nextPos + 1)
                if putIdx == getIdx {
                    putShortCode(bc: &bc, op: .set_var_ref, idx: Int(putIdx))
                    pos = nextPos + 3
                    continue
                }
            }

            // Optimization 10: get_loc(n) + post_inc + put_loc(n) + drop -> inc_loc(n)
            if op == .get_loc, fd.byteCode.len > nextPos + 6 {
                let locIdx = readU16(srcBuf, pos + 1)
                let op2 = JeffJSOpcode(rawValue: UInt16(srcBuf[nextPos]))
                if op2 == .post_inc {
                    let nextPos2 = nextPos + 1
                    if nextPos2 < srcLen,
                       let op3 = JeffJSOpcode(rawValue: UInt16(srcBuf[nextPos2])),
                       op3 == .put_loc {
                        let putIdx = readU16(srcBuf, nextPos2 + 1)
                        let nextPos3 = nextPos2 + 3
                        if putIdx == locIdx && nextPos3 < srcLen,
                           let op4 = JeffJSOpcode(rawValue: UInt16(srcBuf[nextPos3])),
                           op4 == .drop {
                            if locIdx < 256 {
                                bc.putOpcode(JeffJSOpcode.inc_loc.rawValue)
                                bc.putU8(UInt8(locIdx))
                                pos = nextPos3 + 1
                                continue
                            }
                        }
                    }
                }
                // Optimization 10b: get_loc(n) + post_dec + put_loc(n) + drop -> dec_loc(n)
                if op2 == .post_dec {
                    let nextPos2 = nextPos + 1
                    if nextPos2 < srcLen,
                       let op3 = JeffJSOpcode(rawValue: UInt16(srcBuf[nextPos2])),
                       op3 == .put_loc {
                        let putIdx = readU16(srcBuf, nextPos2 + 1)
                        let nextPos3 = nextPos2 + 3
                        if putIdx == locIdx && nextPos3 < srcLen,
                           let op4 = JeffJSOpcode(rawValue: UInt16(srcBuf[nextPos3])),
                           op4 == .drop {
                            if locIdx < 256 {
                                bc.putOpcode(JeffJSOpcode.dec_loc.rawValue)
                                bc.putU8(UInt8(locIdx))
                                pos = nextPos3 + 1
                                continue
                            }
                        }
                    }
                }
            }

            // Optimization 11: post_inc + put_x + drop -> inc + put_x
            if op == .post_inc {
                if let next = nextOp,
                   (next == .put_loc || next == .put_arg || next == .put_var_ref) {
                    let putSize = Int(jeffJSGetOpcodeInfo(next).size)
                    let dropPos = nextPos + putSize
                    if dropPos < srcLen,
                       let dropOp = JeffJSOpcode(rawValue: UInt16(srcBuf[dropPos])),
                       dropOp == .drop {
                        bc.putOpcode(JeffJSOpcode.inc.rawValue)
                        // emit the put opcode as-is
                        for i in 0 ..< putSize {
                            bc.putU8(srcBuf[nextPos + i])
                        }
                        pos = dropPos + 1
                        continue
                    }
                }
            }

            // Optimization 11b: post_dec + put_x + drop -> dec + put_x
            if op == .post_dec {
                if let next = nextOp,
                   (next == .put_loc || next == .put_arg || next == .put_var_ref) {
                    let putSize = Int(jeffJSGetOpcodeInfo(next).size)
                    let dropPos = nextPos + putSize
                    if dropPos < srcLen,
                       let dropOp = JeffJSOpcode(rawValue: UInt16(srcBuf[dropPos])),
                       dropOp == .drop {
                        bc.putOpcode(JeffJSOpcode.dec.rawValue)
                        for i in 0 ..< putSize {
                            bc.putU8(srcBuf[nextPos + i])
                        }
                        pos = dropPos + 1
                        continue
                    }
                }
            }

            // Optimization 12: typeof + push_atom("undefined") + strict_eq -> typeof_is_undefined
            if op == .typeof_ {
                if let next = nextOp, next == .push_atom_value {
                    let atom = readU32(srcBuf, nextPos + 1)
                    let afterAtomPos = nextPos + 5
                    if afterAtomPos < srcLen,
                       let eqOp = JeffJSOpcode(rawValue: UInt16(srcBuf[afterAtomPos])),
                       eqOp == .strict_eq {
                        if atom == JSPredefinedAtom.undefined_.rawValue {
                            bc.putOpcode(JeffJSOpcode.typeof_is_undefined.rawValue)
                            pos = afterAtomPos + 1
                            continue
                        }
                        if atom == JSPredefinedAtom.function_.rawValue {
                            bc.putOpcode(JeffJSOpcode.typeof_is_function.rawValue)
                            pos = afterAtomPos + 1
                            continue
                        }
                    }
                }
            }

            // Optimization 13: get_loc(n) + push_i32(x) + add + dup + put_loc(n) + drop
            //                   -> push_i32(x) + add_loc(n)
            if op == .get_loc && instrSize + nextPos + 10 <= srcLen {
                let locIdx = readU16(srcBuf, pos + 1)
                if let next = nextOp, next == .push_i32 {
                    let addVal = Int32(bitPattern: readU32(srcBuf, nextPos + 1))
                    let p3 = nextPos + 5
                    if p3 < srcLen,
                       let op3 = JeffJSOpcode(rawValue: UInt16(srcBuf[p3])),
                       op3 == .add {
                        let p4 = p3 + 1
                        if p4 < srcLen,
                           let op4 = JeffJSOpcode(rawValue: UInt16(srcBuf[p4])),
                           op4 == .dup {
                            let p5 = p4 + 1
                            if p5 < srcLen,
                               let op5 = JeffJSOpcode(rawValue: UInt16(srcBuf[p5])),
                               op5 == .put_loc {
                                let putIdx2 = readU16(srcBuf, p5 + 1)
                                let p6 = p5 + 3
                                if putIdx2 == locIdx && p6 < srcLen,
                                   let op6 = JeffJSOpcode(rawValue: UInt16(srcBuf[p6])),
                                   op6 == .drop {
                                    if locIdx < 256 {
                                        // add_loc instruction format:
                                        // opcode(1) + u8 loc_idx(1) + i32 addend(4) = 6 bytes
                                        // The addend is encoded inline in the instruction,
                                        // NOT pushed onto the stack.
                                        bc.putOpcode(JeffJSOpcode.add_loc.rawValue)
                                        bc.putU8(UInt8(locIdx))
                                        bc.putU32(UInt32(bitPattern: addVal))
                                        pos = p6 + 1
                                        continue
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ------------------------------------------------------------------
            // Prefix ++/-- store-back fix
            //
            // The parser emits prefix ++/-- as:
            //   get_xxx(n) + inc/dec
            // without storing back to the variable. This peephole adds the
            // missing store-back.
            //
            // Pattern A (expression statement: ++n;):
            //   get_xxx(n) + inc + drop  ->  get_xxx(n) + inc + put_xxx(n)
            //   The put consumes the value, equivalent to drop.
            //
            // Pattern B (expression value: return ++n;):
            //   get_xxx(n) + inc  (not followed by drop)
            //   ->  get_xxx(n) + inc + dup + put_xxx(n)
            //   dup keeps the value on stack as the expression result.
            // ------------------------------------------------------------------
            if (op == .get_var_ref || op == .get_loc || op == .get_arg),
               let next = nextOp, (next == .inc || next == .dec) {
                let varIdx = readU16(srcBuf, operandBase)
                let afterIncPos = nextPos + 1 // position after inc/dec
                let afterIncOp: JeffJSOpcode? = (afterIncPos < srcLen && afterIncPos < srcBuf.count)
                    ? JeffJSOpcode(rawValue: UInt16(srcBuf[afterIncPos])) : nil

                // Determine the matching put opcode
                let putOp: JeffJSOpcode
                switch op {
                case .get_var_ref: putOp = .put_var_ref
                case .get_loc:     putOp = .put_loc
                case .get_arg:     putOp = .put_arg
                default:           putOp = .put_var_ref // unreachable
                }

                if afterIncOp == .drop {
                    // Pattern A: get(n) inc/dec drop -> get(n) inc/dec put(n)
                    // Emit the get opcode
                    bc.putOpcode(op.rawValue)
                    bc.putU16(varIdx)
                    // Emit inc or dec
                    bc.putOpcode(next.rawValue)
                    // Emit put instead of drop
                    bc.putOpcode(putOp.rawValue)
                    bc.putU16(varIdx)
                    pos = afterIncPos + 1 // skip past drop
                    continue
                } else {
                    // Pattern B: get(n) inc/dec <other> -> get(n) inc/dec dup put(n) <other>
                    // Emit the get opcode
                    bc.putOpcode(op.rawValue)
                    bc.putU16(varIdx)
                    // Emit inc or dec
                    bc.putOpcode(next.rawValue)
                    // Emit dup to keep value on stack
                    bc.putOpcode(JeffJSOpcode.dup.rawValue)
                    // Emit put to store back
                    bc.putOpcode(putOp.rawValue)
                    bc.putU16(varIdx)
                    pos = afterIncPos // continue from the opcode after inc/dec
                    continue
                }
            }

            // ------------------------------------------------------------------
            // Superinstruction fusion: fuse common opcode pairs into single
            // fused opcodes to reduce dispatch overhead.
            // ------------------------------------------------------------------

            // Fusion 1: get_loc(n) + get_field(atom) -> get_loc8_get_field(n, atom)
            if op == .get_loc, nextOp == .get_field {
                let locIdx = readU16(srcBuf, pos + 1)
                if locIdx < 256 {
                    let atom = readU32(srcBuf, nextPos + 1)
                    let nextInfo = jeffJSGetOpcodeInfo(.get_field)
                    let nextInstrSize = max(Int(nextInfo.size) + (1 - 1), 1)
                    bc.putOpcode(JeffJSOpcode.get_loc8_get_field.rawValue)
                    bc.putU8(UInt8(locIdx))
                    bc.putU32(atom)
                    pos = nextPos + nextInstrSize
                    continue
                }
            }

            // Fusion 2: get_arg(0) + get_field(atom) -> get_arg0_get_field(atom)
            if op == .get_arg, nextOp == .get_field {
                let argIdx = readU16(srcBuf, pos + 1)
                if argIdx == 0 {
                    let atom = readU32(srcBuf, nextPos + 1)
                    let nextInfo = jeffJSGetOpcodeInfo(.get_field)
                    let nextInstrSize = max(Int(nextInfo.size) + (1 - 1), 1)
                    bc.putOpcode(JeffJSOpcode.get_arg0_get_field.rawValue)
                    bc.putU32(atom)
                    pos = nextPos + nextInstrSize
                    continue
                }
            }

            // Fusion 3: get_loc(n) + add -> get_loc8_add(n)
            if op == .get_loc, nextOp == .add {
                let locIdx = readU16(srcBuf, pos + 1)
                if locIdx < 256 {
                    bc.putOpcode(JeffJSOpcode.get_loc8_add.rawValue)
                    bc.putU8(UInt8(locIdx))
                    pos = nextPos + 1  // skip 'add' (size 1)
                    continue
                }
            }

            // Fusion 4: put_loc(n) + return -> put_loc8_return(n)
            if op == .put_loc, nextOp == .return_ {
                let locIdx = readU16(srcBuf, pos + 1)
                if locIdx < 256 {
                    bc.putOpcode(JeffJSOpcode.put_loc8_return.rawValue)
                    bc.putU8(UInt8(locIdx))
                    pos = nextPos + 1  // skip 'return' (size 1)
                    continue
                }
            }

            // Fusion 5: push_i32(val) + put_loc(n) -> push_i32_put_loc8(val, n)
            if op == .push_i32, nextOp == .put_loc {
                let val32 = readU32(srcBuf, pos + 1)
                let locIdx = readU16(srcBuf, nextPos + 1)
                if locIdx < 256 {
                    bc.putOpcode(JeffJSOpcode.push_i32_put_loc8.rawValue)
                    bc.putU32(val32)
                    bc.putU8(UInt8(locIdx))
                    pos = nextPos + 3  // skip 'put_loc' (size 3)
                    continue
                }
            }

            // Fusion 6: get_loc(a) + get_loc(b) -> get_loc8_get_loc8(a, b)
            if op == .get_loc, nextOp == .get_loc {
                let idxA = readU16(srcBuf, pos + 1)
                let idxB = readU16(srcBuf, nextPos + 1)
                if idxA < 256 && idxB < 256 {
                    bc.putOpcode(JeffJSOpcode.get_loc8_get_loc8.rawValue)
                    bc.putU8(UInt8(idxA))
                    bc.putU8(UInt8(idxB))
                    pos = nextPos + 3  // skip second 'get_loc' (size 3)
                    continue
                }
            }

            // Fusion 7: get_loc(n) + call(argc) -> get_loc8_call(n, argc)
            if op == .get_loc, nextOp == .call {
                let locIdx = readU16(srcBuf, pos + 1)
                if locIdx < 256 {
                    let argc = readU16(srcBuf, nextPos + 1)
                    bc.putOpcode(JeffJSOpcode.get_loc8_call.rawValue)
                    bc.putU8(UInt8(locIdx))
                    bc.putU16(argc)
                    pos = nextPos + 3  // skip 'call' (size 3)
                    continue
                }
            }

            // Fusion 8: dup + put_loc(n) -> dup_put_loc8(n)
            // Note: Optimization 8 above already converts dup+put_loc to set_loc,
            // which is more compact. dup_put_loc8 exists as an opcode for cases
            // where the pattern appears after other transformations (e.g., in the
            // short opcode encoding phase), but we don't emit it here.

            // ------------------------------------------------------------------
            // Level-2 compound fusions (3+ opcodes → NOP prefix + sub-opcode)
            // These use NOP as a prefix byte, followed by a sub-opcode byte,
            // enabling 256 compound instructions beyond the 256 single-byte limit.
            // ------------------------------------------------------------------

            // Compound 0: get_loc(a) + get_field(atom) + call(argc) → obj.method(args)
            if op == .get_loc, nextOp == .get_field {
                let thirdPos = nextPos + 5  // get_field is 5 bytes
                if thirdPos < srcLen {
                    let thirdOp = JeffJSOpcode(rawValue: UInt16(srcBuf[thirdPos]))
                    if thirdOp == .call {
                        let locIdx = readU16(srcBuf, pos + 1)
                        if locIdx < 256 {
                            let atom = readU32(srcBuf, nextPos + 1)
                            let argc = readU16(srcBuf, thirdPos + 1)
                            bc.putOpcode(JeffJSOpcode.nop.rawValue)  // prefix
                            bc.putU8(0)  // sub-opcode 0: get_loc_get_field_call
                            bc.putU8(UInt8(locIdx))
                            bc.putU32(atom)
                            bc.putU16(argc)
                            pos = thirdPos + 3  // skip all 3 opcodes
                            continue
                        }
                    }
                }
            }

            // Compound 1: get_loc(a) + get_loc(b) + get_array_el → arr[i]
            if op == .get_loc, nextOp == .get_loc {
                let thirdPos = nextPos + 3  // get_loc is 3 bytes
                if thirdPos < srcLen {
                    let thirdOp = JeffJSOpcode(rawValue: UInt16(srcBuf[thirdPos]))
                    if thirdOp == .get_array_el {
                        let arrIdx = readU16(srcBuf, pos + 1)
                        let idxIdx = readU16(srcBuf, nextPos + 1)
                        if arrIdx < 256 && idxIdx < 256 {
                            bc.putOpcode(JeffJSOpcode.nop.rawValue)
                            bc.putU8(1)  // sub-opcode 1: get_loc_get_loc_get_array_el
                            bc.putU8(UInt8(arrIdx))
                            bc.putU8(UInt8(idxIdx))
                            pos = thirdPos + 1  // skip all 3 opcodes (get_array_el is 1 byte)
                            continue
                        }
                    }
                }
            }

            // Compound 2: get_loc(a) + get_field(atom) + put_loc(b) → x = obj.prop
            if op == .get_loc, nextOp == .get_field {
                let thirdPos = nextPos + 5
                if thirdPos < srcLen {
                    let thirdOp = JeffJSOpcode(rawValue: UInt16(srcBuf[thirdPos]))
                    if thirdOp == .put_loc {
                        let srcIdx = readU16(srcBuf, pos + 1)
                        let dstIdx = readU16(srcBuf, thirdPos + 1)
                        if srcIdx < 256 && dstIdx < 256 {
                            let atom = readU32(srcBuf, nextPos + 1)
                            bc.putOpcode(JeffJSOpcode.nop.rawValue)
                            bc.putU8(2)  // sub-opcode 2: get_loc_get_field_put_loc
                            bc.putU8(UInt8(srcIdx))
                            bc.putU32(atom)
                            bc.putU8(UInt8(dstIdx))
                            pos = thirdPos + 3  // skip put_loc (3 bytes)
                            continue
                        }
                    }
                }
            }

            // Compound 3: (removed — fusing jump instructions breaks offset resolution)

            // Compound 4: get_loc(a) + get_loc(b) + add + put_loc(c) → c = a + b
            if op == .get_loc, nextOp == .get_loc {
                let thirdPos = nextPos + 3
                if thirdPos < srcLen {
                    let thirdOp = JeffJSOpcode(rawValue: UInt16(srcBuf[thirdPos]))
                    if thirdOp == .add {
                        let fourthPos = thirdPos + 1
                        if fourthPos < srcLen {
                            let fourthOp = JeffJSOpcode(rawValue: UInt16(srcBuf[fourthPos]))
                            if fourthOp == .put_loc {
                                let aIdx = readU16(srcBuf, pos + 1)
                                let bIdx = readU16(srcBuf, nextPos + 1)
                                let cIdx = readU16(srcBuf, fourthPos + 1)
                                if aIdx < 256 && bIdx < 256 && cIdx < 256 {
                                    bc.putOpcode(JeffJSOpcode.nop.rawValue)
                                    bc.putU8(4)  // sub-opcode 4: add_loc_loc_put
                                    bc.putU8(UInt8(aIdx))
                                    bc.putU8(UInt8(bIdx))
                                    bc.putU8(UInt8(cIdx))
                                    pos = fourthPos + 3  // skip put_loc (3 bytes)
                                    continue
                                }
                            }
                        }
                    }
                }
            }

            // ------------------------------------------------------------------
            // Emit the opcode, converting to short forms where possible
            // ------------------------------------------------------------------

            switch op {

            // Short integer push optimizations
            case .push_i32:
                let val = Int32(bitPattern: readU32(srcBuf, pos + 1))
                pushShortInt(bc: &bc, val: val)

            // Short local access
            case .get_loc:
                let idx = Int(readU16(srcBuf, pos + 1))
                putShortCode(bc: &bc, op: .get_loc, idx: idx)

            case .put_loc:
                let idx = Int(readU16(srcBuf, pos + 1))
                putShortCode(bc: &bc, op: .put_loc, idx: idx)

            case .set_loc:
                let idx = Int(readU16(srcBuf, pos + 1))
                putShortCode(bc: &bc, op: .set_loc, idx: idx)

            // Short arg access
            case .get_arg:
                let idx = Int(readU16(srcBuf, pos + 1))
                putShortCode(bc: &bc, op: .get_arg, idx: idx)

            case .put_arg:
                let idx = Int(readU16(srcBuf, pos + 1))
                putShortCode(bc: &bc, op: .put_arg, idx: idx)

            case .set_arg:
                let idx = Int(readU16(srcBuf, pos + 1))
                putShortCode(bc: &bc, op: .set_arg, idx: idx)

            // Short closure var access
            case .get_var_ref:
                let idx = Int(readU16(srcBuf, pos + 1))
                putShortCode(bc: &bc, op: .get_var_ref, idx: idx)

            case .put_var_ref:
                let idx = Int(readU16(srcBuf, pos + 1))
                putShortCode(bc: &bc, op: .put_var_ref, idx: idx)

            case .set_var_ref:
                let idx = Int(readU16(srcBuf, pos + 1))
                putShortCode(bc: &bc, op: .set_var_ref, idx: idx)

            // Short constant pool
            case .push_const:
                let idx = Int(readU32(srcBuf, pos + 1))
                if idx < 256 {
                    bc.putOpcode(JeffJSOpcode.push_const8.rawValue)
                    bc.putU8(UInt8(idx))
                } else {
                    bc.putOpcode(op.rawValue)
                    bc.putU32(UInt32(idx))
                }

            // Short fclosure
            case .fclosure:
                let idx = Int(readU32(srcBuf, pos + 1))
                if idx < 256 {
                    bc.putOpcode(JeffJSOpcode.fclosure8.rawValue)
                    bc.putU8(UInt8(idx))
                } else {
                    bc.putOpcode(op.rawValue)
                    bc.putU32(UInt32(idx))
                }

            // Short call
            case .call:
                let argc = Int(readU16(srcBuf, pos + 1))
                if argc <= 3 {
                    switch argc {
                    case 0: bc.putOpcode(JeffJSOpcode.call0.rawValue)
                    case 1: bc.putOpcode(JeffJSOpcode.call1.rawValue)
                    case 2: bc.putOpcode(JeffJSOpcode.call2.rawValue)
                    case 3: bc.putOpcode(JeffJSOpcode.call3.rawValue)
                    default: break
                    }
                } else {
                    bc.putOpcode(op.rawValue)
                    bc.putU16(UInt16(argc))
                }

            // Jump opcodes -- record position for label resolution in pass 2
            case .if_false, .if_true, .goto_, .catch_, .gosub:
                let labelIdx = Int(readU32(srcBuf, pos + 1))
                let jumpPos = bc.len
                // Emit full-size jump for now; pass 2 will shorten if possible
                bc.putOpcode(op.rawValue)
                // Store label index temporarily; will be resolved in pass 2
                bc.putU32(UInt32(labelIdx))

                // Record this relocation
                if labelIdx < fd.labels.count {
                    let relocIdx = fd.relocs.count
                    fd.relocs.append(JeffJSRelocEntry(
                        kind: .rel32,
                        pos: jumpPos + 1,  // position of the label operand
                        next: fd.labels[labelIdx].firstReloc
                    ))
                    fd.labels[labelIdx].firstReloc = relocIdx
                }

            default:
                // Copy opcode and operands verbatim
                for i in 0 ..< instrSize {
                    if pos + i < srcBuf.count {
                        bc.putU8(srcBuf[pos + i])
                    }
                }
            }

            pos += instrSize
        }

        // ------------------------------------------------------------------
        // Pass 2: Resolve label references to byte offsets, apply short jumps
        // ------------------------------------------------------------------
        resolveJumpTargets(fd: fd, bc: &bc)

        // ------------------------------------------------------------------
        // Pass 3: Dead code elimination after terminal opcodes
        // ------------------------------------------------------------------
        eliminateDeadCode(fd: fd, bc: &bc)

        // ------------------------------------------------------------------
        // Compute stack size
        // ------------------------------------------------------------------
        fd.stackSize = computeStackSize(ctx: ctx, fd: fd, bc: bc)

        // Replace the bytecode buffer
        fd.byteCode = bc

        return true
    }

    // MARK: - Method Call Transformation

    /// Pre-pass that converts `get_field(atom) + call(argc)` pairs into
    /// `get_field2(atom) + call_method(argc)` so that method calls on
    /// primitives (e.g., `'hello'.toUpperCase()`) correctly pass `this`.
    ///
    /// The parser emits `get_field + call` for all `expr.method(args)` patterns
    /// because it doesn't distinguish property access from method calls.
    /// This pass identifies the matching `call` for each `get_field` by
    /// tracking the relative stack depth between the two instructions.
    ///
    /// Both replacement pairs have identical instruction sizes
    /// (`get_field` = 5, `get_field2` = 5; `call` = 3, `call_method` = 3),
    /// so the bytecode buffer can be patched in-place.
    ///
    /// Runs after `resolveVariables` (scope opcodes resolved) and before
    /// `resolveLabels` (labels still present, no short opcodes yet).
    static func transformMethodCalls(fd: JeffJSFunctionDefCompiler) {
        var buf = fd.byteCode.buf
        let bcLen = fd.byteCode.len

        // Collect (get_field_pos, call_pos) pairs to patch.
        var patches: [(Int, Int)] = []

        var pos = 0
        while pos < bcLen {
            guard pos < buf.count,
                  let (op, opWidth) = readOpcodeFromBuf(buf, pos) else {
                pos += 1
                continue
            }
            let info = jeffJSGetOpcodeInfo(op)
            let instrSize = max(Int(info.size) + (opWidth - 1), 1)

            if op == .get_field {
                // Scan forward to find the matching call(argc)
                if let callPos = findMatchingCall(buf: buf, bcLen: bcLen,
                                                  startPos: pos + instrSize) {
                    patches.append((pos, callPos))
                }
            }

            pos += instrSize
        }

        // Apply all patches in-place.
        for (getFieldPos, callPos) in patches {
            // get_field -> get_field2 (both 5 bytes: opcode + u32 atom)
            buf[getFieldPos] = UInt8(JeffJSOpcode.get_field2.rawValue & 0xFF)
            // call -> call_method (both 3 bytes: opcode + u16 argc)
            buf[callPos] = UInt8(JeffJSOpcode.call_method.rawValue & 0xFF)
        }

        fd.byteCode.buf = buf
    }

    /// Scans forward from `startPos` to find a `call(argc)` that consumes
    /// the value pushed by a preceding `get_field`.
    ///
    /// Tracks `depth` = the number of items on the stack ABOVE our method
    /// value. Initially 0 (method is on top). When `call(argc)` is found
    /// and `depth == argc`, the method value is exactly what `call` will
    /// pop as the function.
    ///
    /// For each instruction, we check whether its pops would consume our
    /// method value. If an instruction pops more than `depth` items
    /// (reaching through our value), we abort -- the value was consumed
    /// by something other than a matching `call`.
    ///
    /// Aborts (returns nil) on:
    /// - Control-flow opcodes (jumps, labels, returns, throws)
    /// - An instruction consuming our method value
    /// - Reaching end of bytecode
    private static func findMatchingCall(buf: [UInt8], bcLen: Int,
                                         startPos: Int) -> Int? {
        var pos = startPos
        var depth = 0  // items above our method value

        while pos < bcLen {
            guard pos < buf.count,
                  let (op, opWidth) = readOpcodeFromBuf(buf, pos) else {
                return nil
            }
            let info = jeffJSGetOpcodeInfo(op)
            let instrSize = max(Int(info.size) + (opWidth - 1), 1)

            // Abort on control flow that leaves the expression (returns, throws, catch).
            if isControlFlowOpcode(op) {
                return nil
            }

            // Forward goto (from ternary ?:): FOLLOW the jump to skip the else
            // branch, keeping stack depth accurate. Only follow FORWARD jumps.
            if op == .goto_ || op == .goto16 || op == .goto8 {
                let offset: Int
                if op == .goto8 {
                    offset = Int(Int8(bitPattern: buf[pos + opWidth]))
                } else if op == .goto16 {
                    offset = Int(Int16(bitPattern: readU16(buf, pos + opWidth)))
                } else {
                    offset = Int(Int32(bitPattern: readU32(buf, pos + opWidth)))
                }
                let target = pos + instrSize + offset
                if target > pos && target < bcLen {
                    pos = target  // follow forward jump
                    continue
                }
                return nil  // backward jump — abort
            }

            if op == .call {
                let argc = Int(readU16(buf, pos + opWidth))
                if depth == argc {
                    return pos  // Found the matching call.
                }
                // Not our call. call(argc) pops argc+1 items (func + args).
                let totalPop = argc + 1
                if totalPop > depth {
                    // This call reaches through our value. Abort.
                    return nil
                }
                // Pops items above our value, then pushes result.
                depth = depth - totalPop + 1
            } else {
                // Get actual pop count for this instruction.
                let nPop = actualPopCount(op: op, buf: buf, pos: pos,
                                          opWidth: opWidth)
                if nPop > depth {
                    // This instruction consumes our method value. Abort.
                    return nil
                }
                let nPush = actualPushCount(op: op)
                depth = depth - nPop + nPush
            }

            pos += instrSize
        }

        return nil
    }

    /// Returns the number of items an opcode pops from the stack.
    /// For variable-pop opcodes, reads argc from the operand.
    private static func actualPopCount(op: JeffJSOpcode, buf: [UInt8],
                                        pos: Int, opWidth: Int) -> Int {
        let info = jeffJSGetOpcodeInfo(op)
        let nPop = Int(info.nPop)
        if nPop >= 0 { return nPop }

        // Variable-pop opcodes.
        switch op {
        case .call:
            let argc = Int(readU16(buf, pos + opWidth))
            return argc + 1  // func + args
        case .call_method, .tail_call_method:
            let argc = Int(readU16(buf, pos + opWidth))
            return argc + 2  // obj + func + args
        case .call_constructor:
            let argc = Int(readU16(buf, pos + opWidth))
            return argc + 2  // func + new_target + args
        case .array_from:
            // The interpreter pops `count` element values AND the sentinel
            // object that the parser emits before every array literal.
            return Int(readU16(buf, pos + opWidth)) + 1
        case .apply:
            return 3  // func + this + args_array
        case .apply_constructor:
            return 3  // func + new.target + args_array
        case .eval, .apply_eval:
            let argc = Int(readU16(buf, pos + opWidth))
            return argc + 1
        default:
            return 0
        }
    }

    /// Returns the number of items an opcode pushes onto the stack.
    private static func actualPushCount(op: JeffJSOpcode) -> Int {
        let info = jeffJSGetOpcodeInfo(op)
        let nPush = Int(info.nPush)
        return nPush >= 0 ? nPush : 1  // variable-push ops push 1
    }

    /// Returns true if the opcode is a control-flow instruction that would
    /// make stack-depth tracking unreliable across it.
    private static func isControlFlowOpcode(_ op: JeffJSOpcode) -> Bool {
        switch op {
        case .goto_, .goto8, .goto16,
             // if_true/if_false/label_ are used for short-circuit operators (||, &&, ??)
             // and ternary (?:) within call arguments. They branch/land FORWARD within
             // the same expression and don't break the get_field → call pattern.
             // Allowing them lets transformMethodCalls match patterns like
             // `t.insertBefore(x, y || null)` which Preact/React use extensively.
             // .if_true, .if_false, .if_true8, .if_false8,
             // .label_,
             .return_, .return_undef, .return_async,
             .throw_, .throw_error,
             .catch_, .gosub, .ret:
            return true
        default:
            return false
        }
    }

    // MARK: pushShortInt

    /// Emit the shortest possible encoding for an integer constant.
    static func pushShortInt(bc: inout DynBuf, val: Int32) {
        guard JEFFJS_SHORT_OPCODES else {
            bc.putOpcode(JeffJSOpcode.push_i32.rawValue)
            bc.putU32(UInt32(bitPattern: val))
            return
        }

        switch val {
        case -1:
            bc.putOpcode(JeffJSOpcode.push_minus1.rawValue)
        case 0:
            bc.putOpcode(JeffJSOpcode.push_0.rawValue)
        case 1:
            bc.putOpcode(JeffJSOpcode.push_1.rawValue)
        case 2:
            bc.putOpcode(JeffJSOpcode.push_2.rawValue)
        case 3:
            bc.putOpcode(JeffJSOpcode.push_3.rawValue)
        case 4:
            bc.putOpcode(JeffJSOpcode.push_4.rawValue)
        case 5:
            bc.putOpcode(JeffJSOpcode.push_5.rawValue)
        case 6:
            bc.putOpcode(JeffJSOpcode.push_6.rawValue)
        case 7:
            bc.putOpcode(JeffJSOpcode.push_7.rawValue)
        default:
            if val >= -128 && val <= 127 {
                bc.putOpcode(JeffJSOpcode.push_i8.rawValue)
                bc.putU8(UInt8(bitPattern: Int8(val)))
            } else if val >= -32768 && val <= 32767 {
                bc.putOpcode(JeffJSOpcode.push_i16.rawValue)
                bc.putU16(UInt16(bitPattern: Int16(val)))
            } else {
                bc.putOpcode(JeffJSOpcode.push_i32.rawValue)
                bc.putU32(UInt32(bitPattern: val))
            }
        }
    }

    // MARK: putShortCode

    /// Emit a short-form opcode for local/arg/var_ref access if the index
    /// fits in the compact encoding (0-3 implicit, 4-255 via 8-bit, else 16-bit).
    static func putShortCode(bc: inout DynBuf, op: JeffJSOpcode, idx: Int) {
        guard JEFFJS_SHORT_OPCODES else {
            bc.putOpcode(op.rawValue)
            bc.putU16(UInt16(idx))
            return
        }

        switch op {
        // get_loc -> get_loc0..3, get_loc8, get_loc(u16)
        case .get_loc:
            switch idx {
            case 0: bc.putOpcode(JeffJSOpcode.get_loc0.rawValue)
            case 1: bc.putOpcode(JeffJSOpcode.get_loc1.rawValue)
            case 2: bc.putOpcode(JeffJSOpcode.get_loc2.rawValue)
            case 3: bc.putOpcode(JeffJSOpcode.get_loc3.rawValue)
            case 4...255:
                bc.putOpcode(JeffJSOpcode.get_loc8.rawValue)
                bc.putU8(UInt8(idx))
            default:
                bc.putOpcode(JeffJSOpcode.get_loc.rawValue)
                bc.putU16(UInt16(idx))
            }

        case .put_loc:
            switch idx {
            case 0: bc.putOpcode(JeffJSOpcode.put_loc0.rawValue)
            case 1: bc.putOpcode(JeffJSOpcode.put_loc1.rawValue)
            case 2: bc.putOpcode(JeffJSOpcode.put_loc2.rawValue)
            case 3: bc.putOpcode(JeffJSOpcode.put_loc3.rawValue)
            case 4...255:
                bc.putOpcode(JeffJSOpcode.put_loc8.rawValue)
                bc.putU8(UInt8(idx))
            default:
                bc.putOpcode(JeffJSOpcode.put_loc.rawValue)
                bc.putU16(UInt16(idx))
            }

        case .set_loc:
            switch idx {
            case 0: bc.putOpcode(JeffJSOpcode.set_loc0.rawValue)
            case 1: bc.putOpcode(JeffJSOpcode.set_loc1.rawValue)
            case 2: bc.putOpcode(JeffJSOpcode.set_loc2.rawValue)
            case 3: bc.putOpcode(JeffJSOpcode.set_loc3.rawValue)
            case 4...255:
                bc.putOpcode(JeffJSOpcode.set_loc8.rawValue)
                bc.putU8(UInt8(idx))
            default:
                bc.putOpcode(JeffJSOpcode.set_loc.rawValue)
                bc.putU16(UInt16(idx))
            }

        case .get_arg:
            switch idx {
            case 0: bc.putOpcode(JeffJSOpcode.get_arg0.rawValue)
            case 1: bc.putOpcode(JeffJSOpcode.get_arg1.rawValue)
            case 2: bc.putOpcode(JeffJSOpcode.get_arg2.rawValue)
            case 3: bc.putOpcode(JeffJSOpcode.get_arg3.rawValue)
            default:
                bc.putOpcode(JeffJSOpcode.get_arg.rawValue)
                bc.putU16(UInt16(idx))
            }

        case .put_arg:
            switch idx {
            case 0: bc.putOpcode(JeffJSOpcode.put_arg0.rawValue)
            case 1: bc.putOpcode(JeffJSOpcode.put_arg1.rawValue)
            case 2: bc.putOpcode(JeffJSOpcode.put_arg2.rawValue)
            case 3: bc.putOpcode(JeffJSOpcode.put_arg3.rawValue)
            default:
                bc.putOpcode(JeffJSOpcode.put_arg.rawValue)
                bc.putU16(UInt16(idx))
            }

        case .set_arg:
            switch idx {
            case 0: bc.putOpcode(JeffJSOpcode.set_arg0.rawValue)
            case 1: bc.putOpcode(JeffJSOpcode.set_arg1.rawValue)
            case 2: bc.putOpcode(JeffJSOpcode.set_arg2.rawValue)
            case 3: bc.putOpcode(JeffJSOpcode.set_arg3.rawValue)
            default:
                bc.putOpcode(JeffJSOpcode.set_arg.rawValue)
                bc.putU16(UInt16(idx))
            }

        case .get_var_ref:
            switch idx {
            case 0: bc.putOpcode(JeffJSOpcode.get_var_ref0.rawValue)
            case 1: bc.putOpcode(JeffJSOpcode.get_var_ref1.rawValue)
            case 2: bc.putOpcode(JeffJSOpcode.get_var_ref2.rawValue)
            case 3: bc.putOpcode(JeffJSOpcode.get_var_ref3.rawValue)
            default:
                bc.putOpcode(JeffJSOpcode.get_var_ref.rawValue)
                bc.putU16(UInt16(idx))
            }

        case .put_var_ref:
            switch idx {
            case 0: bc.putOpcode(JeffJSOpcode.put_var_ref0.rawValue)
            case 1: bc.putOpcode(JeffJSOpcode.put_var_ref1.rawValue)
            case 2: bc.putOpcode(JeffJSOpcode.put_var_ref2.rawValue)
            case 3: bc.putOpcode(JeffJSOpcode.put_var_ref3.rawValue)
            default:
                bc.putOpcode(JeffJSOpcode.put_var_ref.rawValue)
                bc.putU16(UInt16(idx))
            }

        case .set_var_ref:
            switch idx {
            case 0: bc.putOpcode(JeffJSOpcode.set_var_ref0.rawValue)
            case 1: bc.putOpcode(JeffJSOpcode.set_var_ref1.rawValue)
            case 2: bc.putOpcode(JeffJSOpcode.set_var_ref2.rawValue)
            case 3: bc.putOpcode(JeffJSOpcode.set_var_ref3.rawValue)
            default:
                bc.putOpcode(JeffJSOpcode.set_var_ref.rawValue)
                bc.putU16(UInt16(idx))
            }

        default:
            bc.putOpcode(op.rawValue)
            bc.putU16(UInt16(idx))
        }
    }

    // MARK: findJumpTarget

    /// Follow a chain of goto jumps to find the ultimate target label.
    /// Used for jump threading optimization.
    /// `bcBuf` is the output bytecode buffer (from pass 1) where label
    /// addresses point and goto operands contain label indices.
    static func findJumpTarget(fd: JeffJSFunctionDefCompiler,
                                label: Int,
                                bcBuf: [UInt8],
                                bcLen: Int) -> Int {
        var target = label
        var visited = Set<Int>()
        while target >= 0 && target < fd.labels.count && !visited.contains(target) {
            visited.insert(target)
            let addr = fd.labels[target].addr
            guard addr >= 0, addr < bcLen else { break }
            guard addr < bcBuf.count,
                  let op = JeffJSOpcode(rawValue: UInt16(bcBuf[addr])),
                  op == .goto_ else {
                break
            }
            let nextLabel = Int(readU32(bcBuf, addr + 1))
            if nextLabel < 0 || nextLabel >= fd.labels.count { break }
            target = nextLabel
        }
        return target
    }

    // MARK: computeStackSize

    /// Compute the maximum stack depth by simulating execution.
    /// This is a conservative estimate using basic block analysis.
    static func computeStackSize(ctx: JeffJSContext,
                                  fd: JeffJSFunctionDefCompiler,
                                  bc: DynBuf) -> Int {
        let buf = bc.buf
        let len = bc.len
        var maxStack = 0
        var curStack = 0
        var pos = 0

        // Track stack depth at each label
        var labelStacks = [Int](repeating: -1, count: fd.labels.count)

        while pos < len {
            guard pos < buf.count else { break }
            guard let op = JeffJSOpcode(rawValue: UInt16(buf[pos])) else {
                pos += 1
                continue
            }
            let info = jeffJSGetOpcodeInfo(op)
            let instrSize = Int(info.size)

            // Check if this position is a label target
            for i in 0 ..< fd.labels.count {
                if fd.labels[i].addr == pos {
                    if labelStacks[i] >= 0 {
                        curStack = max(curStack, labelStacks[i])
                    } else {
                        labelStacks[i] = curStack
                    }
                }
            }

            // Apply stack effect
            let nPop = Int(info.nPop)
            let nPush = Int(info.nPush)

            if nPop >= 0 {
                curStack -= nPop
            } else {
                // Variable pop count -- estimate from operand
                switch op {
                case .call, .tail_call, .call_method, .tail_call_method,
                     .call_constructor, .array_from, .apply, .apply_constructor:
                    if pos + 2 < buf.count {
                        let argc = Int(readU16(buf, pos + 1))
                        curStack -= argc + 1  // func + args (at minimum)
                    }
                case .get_loc8_call:
                    // Fused get_loc8(idx) + call(argc): pops argc args from stack
                    // (the func comes from the local, not the stack)
                    if pos + 3 < buf.count {
                        let argc = Int(readU16(buf, pos + 2))
                        curStack -= argc  // only pops args, func is from local
                    }
                case .eval, .apply_eval:
                    if pos + 2 < buf.count {
                        let argc = Int(readU16(buf, pos + 1))
                        curStack -= argc + 1
                    }
                default:
                    break
                }
            }
            if curStack < 0 { curStack = 0 }

            if nPush >= 0 {
                curStack += nPush
            } else {
                curStack += 1  // conservative estimate
            }

            if curStack > maxStack {
                maxStack = curStack
            }

            // Record stack depth at jump targets
            if op.isJump && !op.isTerminator {
                let format = info.format
                var targetLabel = -1
                switch format {
                case .label:
                    if pos + 4 < buf.count {
                        // After label resolution, the operand is a signed
                        // 32-bit relative offset from the end of the instruction.
                        let relOffset = Int32(bitPattern: readU32(buf, pos + 1))
                        let targetAddr = pos + Int(info.size) + Int(relOffset)
                        // Find which label points to this address
                        for i in 0 ..< fd.labels.count {
                            if fd.labels[i].addr == targetAddr {
                                targetLabel = i
                                break
                            }
                        }
                    }
                case .label8:
                    if pos + 1 < buf.count {
                        let offset = Int8(bitPattern: buf[pos + 1])
                        let targetAddr = pos + 2 + Int(offset)
                        for i in 0 ..< fd.labels.count {
                            if fd.labels[i].addr == targetAddr {
                                targetLabel = i
                                break
                            }
                        }
                    }
                case .label16:
                    if pos + 2 < buf.count {
                        let offset = Int16(bitPattern: readU16(buf, pos + 1))
                        let targetAddr = pos + 3 + Int(offset)
                        for i in 0 ..< fd.labels.count {
                            if fd.labels[i].addr == targetAddr {
                                targetLabel = i
                                break
                            }
                        }
                    }
                default:
                    break
                }

                if targetLabel >= 0 && targetLabel < fd.labels.count {
                    if labelStacks[targetLabel] < 0 {
                        labelStacks[targetLabel] = curStack
                    }
                }
            }

            // After terminal opcodes, reset stack to 0
            if op.isTerminator {
                curStack = 0
            }

            pos += instrSize
        }

        // Ensure at least enough stack for function overhead
        return max(maxStack, 1)
    }

    // MARK: Jump Resolution Helpers

    /// Resolve all jump label references to byte offsets.
    /// Applies short jump optimizations where the offset fits in 8 or 16 bits.
    private static func resolveJumpTargets(fd: JeffJSFunctionDefCompiler,
                                            bc: inout DynBuf) {
        let buf = bc.buf
        let len = bc.len
        var pos = 0

        while pos < len {
            guard pos < buf.count else { break }
            guard let op = JeffJSOpcode(rawValue: UInt16(buf[pos])) else {
                pos += 1
                continue
            }
            let info = jeffJSGetOpcodeInfo(op)
            let instrSize = Int(info.size)

            // Process jumps with label operands
            if info.format == .label && instrSize == 5 {
                let labelIdx = Int(readU32(buf, pos + 1))
                if labelIdx >= 0 && labelIdx < fd.labels.count {
                    var targetAddr = fd.labels[labelIdx].addr

                    // Jump threading: follow goto chains
                    let ultimateLabel = findJumpTarget(fd: fd, label: labelIdx,
                                                        bcBuf: buf, bcLen: len)
                    if ultimateLabel != labelIdx && ultimateLabel < fd.labels.count {
                        targetAddr = fd.labels[ultimateLabel].addr
                    }

                    if targetAddr >= 0 {
                        let instrEnd = pos + instrSize
                        let relOffset = targetAddr - instrEnd

                        // Condition inversion optimization:
                        // if_false(l1) goto(l2) label(l1) -> if_true(l2)
                        if (op == .if_false || op == .if_true) && relOffset == 5 {
                            let gotoPos = instrEnd
                            if gotoPos < len,
                               let gotoOp = JeffJSOpcode(rawValue: UInt16(buf[gotoPos])),
                               gotoOp == .goto_ {
                                let gotoLabel = Int(readU32(buf, gotoPos + 1))
                                if gotoLabel >= 0 && gotoLabel < fd.labels.count {
                                    let gotoTarget = fd.labels[gotoLabel].addr
                                    if gotoTarget >= 0 {
                                        let invertedOp: JeffJSOpcode = (op == .if_false) ? .if_true : .if_false
                                        let gotoEnd = gotoPos + 5
                                        let gotoRelOffset = gotoTarget - (pos + instrSize)
                                        // Replace if_false with inverted jump to goto's target
                                        bc.buf[pos] = UInt8(truncatingIfNeeded: invertedOp.rawValue)
                                        writeU32InBuf(&bc.buf, pos + 1, UInt32(bitPattern: Int32(gotoRelOffset)))
                                        // NOP out the goto
                                        for i in gotoPos ..< gotoEnd {
                                            if i < bc.buf.count {
                                                bc.buf[i] = UInt8(truncatingIfNeeded: JeffJSOpcode.nop.rawValue)
                                            }
                                        }
                                        // Skip past both the if_xxx (5 bytes) and
                                        // the NOP-ed goto (5 bytes) so the main
                                        // loop does not re-resolve the dead goto
                                        // from the snapshot buffer.
                                        pos = gotoEnd
                                        continue
                                    }
                                }
                            }
                        }

                        // Jump to next instruction elimination
                        if relOffset == 0 && op == .goto_ {
                            // Replace with NOPs
                            for i in 0 ..< instrSize {
                                bc.buf[pos + i] = UInt8(truncatingIfNeeded: JeffJSOpcode.nop.rawValue)
                            }
                            pos += instrSize
                            continue
                        }

                        // Try short jump encoding
                        if JEFFJS_SHORT_OPCODES {
                            if relOffset >= -128 && relOffset <= 127 {
                                // 8-bit relative offset
                                let shortOp: JeffJSOpcode
                                switch op {
                                case .if_false: shortOp = .if_false8
                                case .if_true: shortOp = .if_true8
                                case .goto_: shortOp = .goto8
                                default: shortOp = op
                                }
                                if shortOp != op {
                                    // Compute the new relative offset from the SHORT instruction end
                                    let shortInstrEnd = pos + 2
                                    let shortRelOffset = targetAddr - shortInstrEnd
                                    if shortRelOffset >= -128 && shortRelOffset <= 127 {
                                        bc.buf[pos] = UInt8(truncatingIfNeeded: shortOp.rawValue)
                                        bc.buf[pos + 1] = UInt8(bitPattern: Int8(shortRelOffset))
                                        // NOP out remaining bytes
                                        for i in 2 ..< instrSize {
                                            bc.buf[pos + i] = UInt8(truncatingIfNeeded: JeffJSOpcode.nop.rawValue)
                                        }
                                        pos += instrSize
                                        continue
                                    }
                                }
                            }
                            if relOffset >= -32768 && relOffset <= 32767 && op == .goto_ {
                                // 16-bit goto
                                let shortInstrEnd = pos + 3
                                let shortRelOffset = targetAddr - shortInstrEnd
                                if shortRelOffset >= -32768 && shortRelOffset <= 32767 {
                                    bc.buf[pos] = UInt8(truncatingIfNeeded: JeffJSOpcode.goto16.rawValue)
                                    let u16 = UInt16(bitPattern: Int16(shortRelOffset))
                                    bc.buf[pos + 1] = UInt8(u16 & 0xFF)
                                    bc.buf[pos + 2] = UInt8((u16 >> 8) & 0xFF)
                                    for i in 3 ..< instrSize {
                                        bc.buf[pos + i] = UInt8(truncatingIfNeeded: JeffJSOpcode.nop.rawValue)
                                    }
                                    pos += instrSize
                                    continue
                                }
                            }
                        }

                        // Full 32-bit relative offset
                        writeU32InBuf(&bc.buf, pos + 1,
                                      UInt32(bitPattern: Int32(relOffset)))
                    }
                }
            }

            pos += instrSize
        }
    }

    /// Remove dead code after terminal opcodes (return, throw, goto).
    /// Dead code regions end when a jump target (label address) points to the
    /// current position, since that means live code can reach this point.
    private static func eliminateDeadCode(fd: JeffJSFunctionDefCompiler,
                                           bc: inout DynBuf) {
        // Build a set of all label target addresses for fast lookup.
        // After label resolution, fd.labels[i].addr holds the byte offset
        // in the output buffer where each label points.
        var labelAddresses = Set<Int>()
        for label in fd.labels {
            if label.addr >= 0 {
                labelAddresses.insert(label.addr)
            }
        }

        let len = bc.len
        var pos = 0
        var isDeadCode = false

        while pos < len {
            guard pos < bc.buf.count else { break }
            guard let op = JeffJSOpcode(rawValue: UInt16(bc.buf[pos])) else {
                if isDeadCode { bc.buf[pos] = UInt8(truncatingIfNeeded: JeffJSOpcode.nop.rawValue) }
                pos += 1
                continue
            }

            // A jump target at this position ends the dead code region,
            // since live code can branch here.
            if isDeadCode && labelAddresses.contains(pos) {
                isDeadCode = false
            }

            if isDeadCode && op != .nop {
                let info = jeffJSGetOpcodeInfo(op)
                let instrSize = Int(info.size)
                for i in 0 ..< instrSize {
                    if pos + i < bc.buf.count {
                        bc.buf[pos + i] = UInt8(truncatingIfNeeded: JeffJSOpcode.nop.rawValue)
                    }
                }
                pos += instrSize
                continue
            }

            let info = jeffJSGetOpcodeInfo(op)
            let instrSize = Int(info.size)

            if op.isTerminator {
                isDeadCode = true
            }

            pos += instrSize
        }
    }

    /// Check if an opcode is a push (produces 1 value, consumes 0).
    private static func isPushOpcode(_ op: JeffJSOpcode) -> Bool {
        let info = jeffJSGetOpcodeInfo(op)
        return info.nPop == 0 && info.nPush == 1
    }

    // MARK: PC-to-line encoding

    /// Add a PC-to-line mapping for debug info.
    /// Uses the QuickJS pc2line delta encoding.
    private static func addPC2Line(fd: JeffJSFunctionDefCompiler,
                                    pc: Int, lineNum: Int) {
        let pcDelta = pc - fd.lastPC
        let lineDelta = lineNum - fd.lastLineNum

        // Encode using QuickJS's compact delta format
        if pcDelta == 0 && lineDelta == 0 { return }

        let adjustedDelta = lineDelta - PC2LINE_BASE
        let byte = PC2LINE_OP_FIRST + pcDelta * PC2LINE_RANGE + adjustedDelta
        if pcDelta >= 0 && adjustedDelta >= 0 &&
           adjustedDelta < PC2LINE_RANGE && byte >= 1 && byte <= 255 {
            // Compact single-byte encoding
            fd.pc2lineBuf.putU8(UInt8(byte))
        } else {
            // Multi-byte encoding: 0 marker followed by LEB128 values
            fd.pc2lineBuf.putU8(0)
            putSLEB128(&fd.pc2lineBuf, Int32(pcDelta))
            putSLEB128(&fd.pc2lineBuf, Int32(lineDelta))
        }

        fd.lastPC = pc
        fd.lastLineNum = lineNum
    }

    /// Add a PC-to-column mapping for debug info.
    /// Uses the same delta encoding as pc2line.
    private static func addPC2Col(fd: JeffJSFunctionDefCompiler,
                                   pc: Int, colNum: Int) {
        let pcDelta = pc - fd.lastColPC
        let colDelta = colNum - fd.lastColNum

        if pcDelta == 0 && colDelta == 0 { return }

        let adjustedDelta = colDelta - PC2LINE_BASE
        let byte = PC2LINE_OP_FIRST + pcDelta * PC2LINE_RANGE + adjustedDelta
        if pcDelta >= 0 && adjustedDelta >= 0 &&
           adjustedDelta < PC2LINE_RANGE && byte >= 1 && byte <= 255 {
            fd.pc2colBuf.putU8(UInt8(byte))
        } else {
            fd.pc2colBuf.putU8(0)
            putSLEB128(&fd.pc2colBuf, Int32(pcDelta))
            putSLEB128(&fd.pc2colBuf, Int32(colDelta))
        }

        fd.lastColPC = pc
        fd.lastColNum = colNum
    }

    // =========================================================================
    // MARK: 2c. Fix switch statement and array spread bytecode
    // =========================================================================

    /// The parser interleaves case tests with case bodies in switch
    /// statements, causing every case body to execute unconditionally.
    /// This pass detects the pattern:
    ///     if_true(L)  label_(L)  <body>  [dup next-case-test ...]
    /// and rewrites it to:
    ///     if_false(Lskip)  label_(L)  <body>  label_(Lskip)  [dup ...]
    /// so that when the case test fails, execution skips the body.
    ///
    /// It also fixes the backward `goto_(defaultLabel)` that the parser
    /// emits after all case bodies by replacing it with `goto_(breakLabel)`.
    static func fixSwitchAndSpread(fd: JeffJSFunctionDefCompiler) {
        let src = fd.byteCode.buf
        let srcLen = fd.byteCode.len
        guard srcLen > 0 else { return }

        // -- Phase 1: Identify switch if_true(L) + label_(L) pairs ---------

        struct SwitchFix {
            var ifTruePos: Int        // position of the if_true opcode
            var labelPos: Int         // position of the label_ opcode
            var labelIdx: Int         // original label index
            var bodyEndPos: Int       // position where the skip label goes
            var newLabelIdx: Int      // index of the newly created label
        }

        var fixes = [SwitchFix]()
        // Track all label_ positions so we can detect backward gotos
        var labelDefinitions = [Int: Int]()  // labelIdx -> source position

        var pos = 0
        while pos < srcLen {
            guard pos < src.count else { break }
            guard let (op, opWidth) = readOpcodeFromBuf(src, pos) else {
                pos += 1; continue
            }
            let info = jeffJSGetOpcodeInfo(op)
            let instrSize = max(Int(info.size) + (opWidth - 1), 1)

            // Record all label_ definitions
            if op == .label_ {
                let lblIdx = Int(readU32(src, pos + 1))
                labelDefinitions[lblIdx] = pos
            }

            // Look for: if_true(L) immediately followed by label_(L)
            if op == .if_true {
                let labelIdxInIfTrue = Int(readU32(src, pos + opWidth))
                let nextPos = pos + instrSize
                if nextPos < srcLen, nextPos < src.count {
                    if let (nextOp, _) = readOpcodeFromBuf(src, nextPos),
                       nextOp == .label_ {
                        let labelIdxInLabel = Int(readU32(src, nextPos + 1))
                        if labelIdxInIfTrue == labelIdxInLabel {
                            let nextInfo = jeffJSGetOpcodeInfo(nextOp)
                            let labelInstrSize = max(Int(nextInfo.size) + (1 - 1), 1)
                            let bodyStart = nextPos + labelInstrSize
                            let bodyEnd = findSwitchBodyEnd(src: src,
                                                            srcLen: srcLen,
                                                            bodyStart: bodyStart)
                            let newLabelIdx = fd.labels.count
                            fd.labels.append(JeffJSLabelSlot())

                            fixes.append(SwitchFix(
                                ifTruePos: pos,
                                labelPos: nextPos,
                                labelIdx: labelIdxInIfTrue,
                                bodyEndPos: bodyEnd,
                                newLabelIdx: newLabelIdx
                            ))
                        }
                    }
                }
            }

            pos += instrSize
        }

        guard !fixes.isEmpty else { return }

        // -- Phase 1b: Detect backward goto_(L) where label_(L) was already
        //    defined earlier.  The parser emits goto_(defaultLabel) after all
        //    case tests/bodies; when we reorder so the default body is inline
        //    above the goto, it becomes a backward jump creating an infinite
        //    loop.  Replace it with goto_(breakLabel) where breakLabel is the
        //    label defined in the label_ that immediately follows the goto_.

        // Collect goto_ positions that should be retargeted
        struct GotoFix {
            var gotoPos: Int       // position of the goto_ opcode
            var newLabelIdx: Int   // the breakLabel index to jump to instead
        }
        var gotoFixes = [GotoFix]()

        pos = 0
        while pos < srcLen {
            guard pos < src.count else { break }
            guard let (op, opWidth) = readOpcodeFromBuf(src, pos) else {
                pos += 1; continue
            }
            let info = jeffJSGetOpcodeInfo(op)
            let instrSize = max(Int(info.size) + (opWidth - 1), 1)

            if op == .goto_ {
                let targetLabelIdx = Int(readU32(src, pos + opWidth))
                // Check if this label was defined BEFORE this goto
                if let defPos = labelDefinitions[targetLabelIdx], defPos < pos {
                    // Backward goto.  Check if the next instruction is label_(breakLabel)
                    let nextPos = pos + instrSize
                    if nextPos < srcLen, nextPos < src.count,
                       let (nextOp, _) = readOpcodeFromBuf(src, nextPos),
                       nextOp == .label_ {
                        let breakLabelIdx = Int(readU32(src, nextPos + 1))
                        gotoFixes.append(GotoFix(gotoPos: pos,
                                                  newLabelIdx: breakLabelIdx))
                    }
                }
            }

            pos += instrSize
        }

        // -- Phase 2: Rebuild the bytecode with fixes applied ---------------

        let sortedFixes = fixes.sorted { $0.bodyEndPos < $1.bodyEndPos }

        var insertions = [(pos: Int, labelIdx: Int)]()
        for fix in sortedFixes {
            insertions.append((fix.bodyEndPos, fix.newLabelIdx))
        }

        var newBuf = DynBuf()
        var srcPos = 0
        var insertIdx = 0

        while srcPos < srcLen {
            // Insert skip labels at body-end positions
            while insertIdx < insertions.count && insertions[insertIdx].pos == srcPos {
                let lblIdx = insertions[insertIdx].labelIdx
                newBuf.putOpcode(JeffJSOpcode.label_.rawValue)
                newBuf.putU32(UInt32(lblIdx))
                insertIdx += 1
            }

            // Rewrite if_true -> if_false for switch cases
            var didRewrite = false
            for fix in fixes {
                if srcPos == fix.ifTruePos {
                    newBuf.putOpcode(JeffJSOpcode.if_false.rawValue)
                    newBuf.putU32(UInt32(fix.newLabelIdx))
                    guard let (_, opW) = readOpcodeFromBuf(src, srcPos) else { break }
                    let origInfo = jeffJSGetOpcodeInfo(.if_true)
                    srcPos += max(Int(origInfo.size) + (opW - 1), 1)
                    didRewrite = true
                    break
                }
            }
            if didRewrite { continue }

            // Retarget backward goto_(defaultLabel) -> goto_(breakLabel)
            for gf in gotoFixes {
                if srcPos == gf.gotoPos {
                    newBuf.putOpcode(JeffJSOpcode.goto_.rawValue)
                    newBuf.putU32(UInt32(gf.newLabelIdx))
                    guard let (_, opW) = readOpcodeFromBuf(src, srcPos) else { break }
                    let origInfo = jeffJSGetOpcodeInfo(.goto_)
                    srcPos += max(Int(origInfo.size) + (opW - 1), 1)
                    didRewrite = true
                    break
                }
            }
            if didRewrite { continue }

            // Copy byte verbatim
            if srcPos < src.count {
                newBuf.putU8(src[srcPos])
            }
            srcPos += 1
        }

        // Flush remaining insertions at the end
        while insertIdx < insertions.count {
            let lblIdx = insertions[insertIdx].labelIdx
            newBuf.putOpcode(JeffJSOpcode.label_.rawValue)
            newBuf.putU32(UInt32(lblIdx))
            insertIdx += 1
        }

        fd.byteCode = newBuf
    }

    /// Scan forward from bodyStart to find where the switch case body ends.
    /// Each case body ends with a `goto_(breakLabel)` from `break;`.
    /// The skip label should be placed right after that terminal goto.
    private static func findSwitchBodyEnd(src: [UInt8], srcLen: Int,
                                           bodyStart: Int) -> Int {
        // Strategy: find the first goto_ in the body.  That is typically
        // the `break` statement.  The skip target goes right after it.
        var pos = bodyStart
        while pos < srcLen && pos < src.count {
            guard let (op, opWidth) = readOpcodeFromBuf(src, pos) else {
                pos += 1; continue
            }
            let info = jeffJSGetOpcodeInfo(op)
            let instrSize = max(Int(info.size) + (opWidth - 1), 1)

            if op == .goto_ {
                // Return the position just after this goto_ instruction.
                return pos + instrSize
            }

            pos += instrSize
        }
        return pos // end of bytecode
    }

    // =========================================================================
    // MARK: 3. Function Creation (js_create_function)
    // =========================================================================

    /// Create a JeffJSFunctionBytecode from a compiled JeffJSFunctionDefCompiler.
    ///
    /// Port of `js_create_function()` from QuickJS quickjs.c.
    /// This is the top-level entry point that:
    ///   1. Recursively compiles child functions
    ///   2. Runs resolve_variables
    ///   3. Runs resolve_labels
    ///   4. Produces the final JeffJSFunctionBytecode object
    static func createFunction(ctx: JeffJSContext,
                                fd: JeffJSFunctionDefCompiler) -> JeffJSFunctionBytecodeCompiled? {
        // 1. Variable resolution pass FIRST.
        //    This must run before compiling children because resolveVariables
        //    populates each child's closureVar list when it encounters
        //    scope_get_var/scope_put_var that reference parent variables.
        //    Without this, children would be compiled with empty closureVars
        //    and closure variable access would fail.
        if !resolveVariables(ctx: ctx, fd: fd) {
            return nil
        }

        // 2. Recursively compile child functions (after resolveVariables).
        //    Scan the bytecode to find fclosure opcodes and extract their
        //    constant-pool indices so we replace the correct placeholder.
        var closureCpoolIndices = [Int]()
        do {
            var scanPos = 0
            let scanBuf = fd.byteCode.buf
            let scanLen = fd.byteCode.len
            while scanPos < scanLen && scanPos < scanBuf.count {
                guard let (op, opWidth) = readOpcodeFromBuf(scanBuf, scanPos) else {
                    scanPos += 1
                    continue
                }
                let info = jeffJSGetOpcodeInfo(op)
                let instrSize = max(Int(info.size) + (opWidth - 1), 1)
                if op == .fclosure {
                    let idx = Int(readU32(scanBuf, scanPos + opWidth))
                    closureCpoolIndices.append(idx)
                }
                scanPos += instrSize
            }
        }
        for i in 0 ..< fd.childFunctions.count {
            let childFd = fd.childFunctions[i]
            guard let childBc = createFunction(ctx: ctx, fd: childFd) else {
                return nil
            }
            // Replace the placeholder in the constant pool at the correct index.
            if i < closureCpoolIndices.count {
                let cpoolIdx = closureCpoolIndices[i]
                if cpoolIdx < fd.cpool.count {
                    fd.cpool[cpoolIdx] = JeffJSValue.makeFunctionBytecode(childBc)
                } else {
                    fd.cpool.append(JeffJSValue.makeFunctionBytecode(childBc))
                }
            } else if i < fd.cpool.count {
                fd.cpool[i] = JeffJSValue.makeFunctionBytecode(childBc)
            } else {
                fd.cpool.append(JeffJSValue.makeFunctionBytecode(childBc))
            }
        }

        // 2b. Hoist function declarations to the start of the function body.
        // JavaScript requires function declarations to be available before their
        // source position (ES spec §10.2.1 — hoisting). Move their bytecodes
        // (fclosure + scope_put_var_init) from declaration site to body start.
        if !fd.hoistedFuncDeclRanges.isEmpty {
            let sorted = fd.hoistedFuncDeclRanges.sorted { $0.0 < $1.0 }
            let bodyStart = fd.bodyBytecodeStart
            let origBuf = fd.byteCode.toBytes()
            let origLen = fd.byteCode.len

            // Build new bytecode: [pre-body] [hoisted decls] [body minus hoisted decls]
            var newBuf = [UInt8]()
            newBuf.reserveCapacity(origLen)

            // 1. Copy pre-body prologue (args, defaults, rest, arguments setup)
            newBuf.append(contentsOf: origBuf[0..<bodyStart])

            // 2. Copy hoisted function declaration bytecodes
            for (start, end) in sorted {
                newBuf.append(contentsOf: origBuf[start..<end])
            }

            // 3. Copy body bytecodes, skipping the hoisted ranges
            var pos = bodyStart
            for (start, end) in sorted {
                if pos < start {
                    newBuf.append(contentsOf: origBuf[pos..<start])
                }
                pos = end
            }
            if pos < origLen {
                newBuf.append(contentsOf: origBuf[pos..<origLen])
            }

            // Replace bytecode — label indices are still symbolic at this stage,
            // so reordering before resolveLabels is safe.
            var newDynBuf = DynBuf()
            newDynBuf.buf = newBuf
            newDynBuf.len = newBuf.count
            newDynBuf.size = newBuf.count
            fd.byteCode = newDynBuf
        }

        // 2c. Method call transformation: get_field + call -> get_field2 + call_method
        transformMethodCalls(fd: fd)

        // 2d. Fix switch statement case/body interleaving and array spread.
        fixSwitchAndSpread(fd: fd)

        // 3. Label resolution and peephole optimization
        if !resolveLabels(ctx: ctx, fd: fd) {
            return nil
        }

        // 4. Create the bytecode object
        return createFunctionBytecode(ctx: ctx, fd: fd)
    }

    /// Create the final function bytecode object from a compiled function def.
    static func createFunctionBytecode(ctx: JeffJSContext,
                                        fd: JeffJSFunctionDefCompiler) -> JeffJSFunctionBytecodeCompiled {
        let fb = JeffJSFunctionBytecodeCompiled()

        // Copy bytecode
        fb.bytecode = fd.byteCode.toBytes()
        fb.bytecodeLen = fd.byteCode.len

        // Function metadata
        fb.funcNameAtom = fd.funcName
        fb.argCount = UInt16(fd.argCount)
        fb.varCount = UInt16(fd.vars.count)
        fb.definedArgCountValue = UInt16(fd.argCount)
        fb.stackSize = UInt16(fd.stackSize)

        // Mode and flags
        fb.jsModeFlags = UInt8(fd.jsMode)
        fb.hasPrototype = fd.hasPrototype
        fb.hasSimpleParameterList = fd.hasSimpleParameterList
        fb.isDerivedClassConstructor = fd.isDerivedClassConstructor
        fb.needHomeObject = fd.needHomeObject
        fb.funcKindValue = fd.funcKind
        fb.isArrow = fd.isArrow
        fb.newTargetAllowedFlag = fd.newTargetAllowed
        fb.superCallAllowedFlag = fd.superCallAllowed
        fb.superAllowedFlag = fd.superAllowed
        fb.argumentsAllowedFlag = fd.argumentsAllowed
        fb.isDirectOrIndirectEval = fd.isDirectOrIndirectEval
        fb.funcNameVarIdx = fd.funcNameVarIdx

        // Generator/async flags
        fb.isGenerator = (fd.funcKind == JSFunctionKindEnum.JS_FUNC_GENERATOR.rawValue ||
                          fd.funcKind == JSFunctionKindEnum.JS_FUNC_ASYNC_GENERATOR.rawValue)
        fb.isAsyncFunc = (fd.funcKind == JSFunctionKindEnum.JS_FUNC_ASYNC.rawValue ||
                          fd.funcKind == JSFunctionKindEnum.JS_FUNC_ASYNC_GENERATOR.rawValue)

        // Variable definitions
        fb.vardefs = fd.vars.map { v in
            var bvd = JeffJSBytecodeVarDef()
            bvd.varName = v.varName
            bvd.scopeNext = v.scopeNext
            bvd.isConst = v.isConst
            bvd.isLexical = v.isLexical
            bvd.isCaptured = v.isCaptured
            bvd.varKind = v.varKind
            return bvd
        }

        // Closure variables
        fb.closureVars = fd.closureVar
        fb.closureVarCount = UInt16(fd.closureVar.count)
        fb.closureVarCountInt = fd.closureVar.count
        fb.varRefCountValue = UInt16(fd.closureVar.count)

        // Constant pool
        fb.cpool = fd.cpool
        fb.cpoolCountValue = fd.cpool.count

        // Debug info
        if fd.source != nil || fd.pc2lineBuf.len > 0 {
            fb.hasDebugInfo = true
            fb.hasDebug = true
            fb.debugFilenameAtom = fd.filename
            fb.debugSourceStr = fd.source
            fb.debugSourceLen = fd.source?.utf8.count ?? 0
            fb.debugPc2lineBuf = fd.pc2lineBuf.toBytes()
            fb.debugPc2lineLen = fd.pc2lineBuf.len
            fb.debugPc2colBuf = fd.pc2colBuf.toBytes()
            fb.debugPc2colLen = fd.pc2colBuf.len
        }

        // Trace block fusion: identify hot loop candidates for the fast mini-interpreter
        JeffJSCompiler.fuseBasicBlocks(fb)

        return fb
    }

    /// Create a closure from bytecode and an array of captured variable references.
    /// This is called at runtime when a `fclosure` opcode is executed.
    static func closure(ctx: JeffJSContext,
                         bytecode: JeffJSFunctionBytecodeCompiled,
                         varRefs: [JeffJSVarRef?]) -> JeffJSValue {
        // In the actual VM, this would create a JSObject of class
        // JS_CLASS_BYTECODE_FUNCTION with the bytecode and var_refs.
        // For now, return the bytecode wrapped in a value.
        return JeffJSValue.makeFunctionBytecode(bytecode)
    }

    // =========================================================================
    // MARK: 5. Bytecode Disassembler
    // =========================================================================

    /// Disassemble bytecode into a human-readable string.
    static func dumpByteCode(bytecode: [UInt8],
                              cpool: [JeffJSValue],
                              vars: [JeffJSBytecodeVarDef],
                              closureVars: [JeffJSClosureVar],
                              argCount: Int,
                              varCount: Int) -> String {
        var out = ""
        let len = bytecode.count
        var pos = 0

        out += "  args=\(argCount) vars=\(varCount)"
        out += " closures=\(closureVars.count) cpool=\(cpool.count)\n"

        // Dump variable definitions
        if !vars.isEmpty {
            out += "  vars:\n"
            for (i, v) in vars.enumerated() {
                var flags = ""
                if v.isConst { flags += "const " }
                if v.isLexical { flags += "lexical " }
                if v.isCaptured { flags += "captured " }
                out += "    [\(i)] atom=\(v.varName) \(flags)"
                out += "kind=\(v.varKind)\n"
            }
        }

        // Dump closure variables
        if !closureVars.isEmpty {
            out += "  closure vars:\n"
            for (i, cv) in closureVars.enumerated() {
                var flags = ""
                if cv.isLocal { flags += "local " }
                if cv.isArg { flags += "arg " }
                if cv.isConst { flags += "const " }
                if cv.isLexical { flags += "lexical " }
                out += "    [\(i)] atom=\(cv.varName) idx=\(cv.varIdx) \(flags)\n"
            }
        }

        // Dump bytecode
        out += "  bytecode (\(len) bytes):\n"

        while pos < len {
            guard pos < bytecode.count else { break }
            guard let op = JeffJSOpcode(rawValue: UInt16(bytecode[pos])) else {
                out += "    \(formatPC(pos)): <invalid 0x\(String(bytecode[pos], radix: 16))>\n"
                pos += 1
                continue
            }

            if op == .nop {
                pos += 1
                continue
            }

            let info = jeffJSGetOpcodeInfo(op)
            let instrSize = Int(info.size)

            out += "    \(formatPC(pos)): \(info.name)"

            // Decode and display operands based on format
            switch info.format {
            case .none, .none_int, .none_loc, .none_arg, .none_var_ref, .npopx:
                break

            case .u8:
                if pos + 1 < len {
                    out += " \(bytecode[pos + 1])"
                }

            case .i8:
                if pos + 1 < len {
                    out += " \(Int8(bitPattern: bytecode[pos + 1]))"
                }

            case .loc8, .const8:
                if pos + 1 < len {
                    out += " \(bytecode[pos + 1])"
                }

            case .label8:
                if pos + 1 < len {
                    let offset = Int8(bitPattern: bytecode[pos + 1])
                    let target = pos + 2 + Int(offset)
                    out += " -> \(formatPC(target))"
                }

            case .u16, .loc, .arg, .var_ref:
                if pos + 2 < len {
                    out += " \(readU16(bytecode, pos + 1))"
                }

            case .i16:
                if pos + 2 < len {
                    out += " \(Int16(bitPattern: readU16(bytecode, pos + 1)))"
                }

            case .label16:
                if pos + 2 < len {
                    let offset = Int16(bitPattern: readU16(bytecode, pos + 1))
                    let target = pos + 3 + Int(offset)
                    out += " -> \(formatPC(target))"
                }

            case .npop:
                if pos + 2 < len {
                    out += " argc=\(readU16(bytecode, pos + 1))"
                }

            case .npop_u16:
                if pos + 4 < len {
                    out += " \(readU16(bytecode, pos + 1)) \(readU16(bytecode, pos + 3))"
                }

            case .u32:
                if pos + 4 < len {
                    out += " \(readU32(bytecode, pos + 1))"
                }

            case .i32:
                if pos + 4 < len {
                    out += " \(Int32(bitPattern: readU32(bytecode, pos + 1)))"
                }

            case .const_:
                if pos + 4 < len {
                    let idx = Int(readU32(bytecode, pos + 1))
                    out += " [\(idx)]"
                    if idx < cpool.count {
                        out += " ; \(cpool[idx].debugDescription)"
                    }
                }

            case .label:
                if pos + 4 < len {
                    let offset = Int32(bitPattern: readU32(bytecode, pos + 1))
                    let target = pos + 5 + Int(offset)
                    out += " -> \(formatPC(target))"
                }

            case .atom:
                if pos + 4 < len {
                    out += " atom=\(readU32(bytecode, pos + 1))"
                }

            case .atom_u8:
                if pos + 5 < len {
                    out += " atom=\(readU32(bytecode, pos + 1))"
                    out += " \(bytecode[pos + 5])"
                }

            case .atom_u16:
                if pos + 6 < len {
                    out += " atom=\(readU32(bytecode, pos + 1))"
                    out += " \(readU16(bytecode, pos + 5))"
                }

            case .atom_label_u8:
                if pos + 9 < len {
                    out += " atom=\(readU32(bytecode, pos + 1))"
                    let offset = Int32(bitPattern: readU32(bytecode, pos + 5))
                    let target = pos + 10 + Int(offset)
                    out += " -> \(formatPC(target))"
                    out += " \(bytecode[pos + 9])"
                }

            case .atom_label_u16:
                if pos + 10 < len {
                    out += " atom=\(readU32(bytecode, pos + 1))"
                    let offset = Int32(bitPattern: readU32(bytecode, pos + 5))
                    let target = pos + 11 + Int(offset)
                    out += " -> \(formatPC(target))"
                    out += " \(readU16(bytecode, pos + 9))"
                }

            case .label_u16:
                if pos + 6 < len {
                    let offset = Int32(bitPattern: readU32(bytecode, pos + 1))
                    let target = pos + 7 + Int(offset)
                    out += " -> \(formatPC(target))"
                    out += " \(readU16(bytecode, pos + 5))"
                }
            }

            out += "\n"
            pos += instrSize
        }

        return out
    }

    /// Disassemble a complete function bytecode object.
    static func dumpFunctionBytecode(fb: JeffJSFunctionBytecodeCompiled) -> String {
        var out = "function atom=\(fb.funcNameAtom):\n"

        out += "  mode=0x\(String(fb.jsModeFlags, radix: 16))"
        out += " kind=\(fb.funcKindValue)"
        out += " args=\(fb.argCount)"
        out += " vars=\(fb.varCount)"
        out += " stack=\(fb.stackSize)"
        out += "\n"

        var flags: [String] = []
        if fb.hasPrototype { flags.append("prototype") }
        if fb.hasSimpleParameterList { flags.append("simple_params") }
        if fb.isDerivedClassConstructor { flags.append("derived_ctor") }
        if fb.needHomeObject { flags.append("home_obj") }
        if fb.isDirectOrIndirectEval { flags.append("eval") }
        if fb.newTargetAllowedFlag { flags.append("new.target") }
        if fb.superCallAllowedFlag { flags.append("super_call") }
        if fb.superAllowedFlag { flags.append("super") }
        if fb.argumentsAllowedFlag { flags.append("arguments") }
        if fb.isGenerator { flags.append("generator") }
        if fb.isAsyncFunc { flags.append("async") }

        if !flags.isEmpty {
            out += "  flags: \(flags.joined(separator: " "))\n"
        }

        out += dumpByteCode(
            bytecode: fb.bytecode,
            cpool: fb.cpool,
            vars: fb.vardefs,
            closureVars: fb.closureVars,
            argCount: Int(fb.argCount),
            varCount: Int(fb.varCount)
        )

        return out
    }

    /// Format a bytecode PC for display.
    private static func formatPC(_ pc: Int) -> String {
        return String(format: "%04d", pc)
    }

    // =========================================================================
    // MARK: - Binary Read/Write Helpers
    // =========================================================================

    /// Read an opcode from the bytecode buffer, handling the wide-opcode encoding.
    ///
    /// Opcodes with rawValue 1-255 are stored as a single byte.
    /// Opcodes with rawValue >= 256 are stored as 2 bytes: a 0x00 prefix
    /// followed by (rawValue - 256).
    ///
    /// Returns (opcode, width) where width is 1 for normal opcodes or 2 for
    /// wide opcodes. The caller must add (width - 1) to the info-table instrSize
    /// to get the actual byte span of the instruction in the buffer.
    /// Returns nil if the byte(s) do not correspond to a valid opcode.
    @inline(__always)
    static func readOpcodeFromBuf(_ buf: [UInt8], _ offset: Int) -> (op: JeffJSOpcode, width: Int)? {
        guard offset >= 0, offset < buf.count else { return nil }
        let byte0 = buf[offset]
        if byte0 != 0 {
            // Normal 1-byte opcode
            guard let op = JeffJSOpcode(rawValue: UInt16(byte0)) else { return nil }
            return (op, 1)
        }
        // Wide opcode: 0x00 prefix + low byte
        guard offset + 1 < buf.count else { return nil }
        let rawValue = 256 + UInt16(buf[offset + 1])
        guard let op = JeffJSOpcode(rawValue: rawValue) else { return nil }
        return (op, 2)
    }

    /// Read a little-endian UInt16 from a byte array.
    @inline(__always)
    private static func readU16(_ buf: [UInt8], _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 1 < buf.count else { return 0 }
        return UInt16(buf[offset]) | (UInt16(buf[offset + 1]) << 8)
    }

    /// Read a little-endian UInt32 from a byte array.
    @inline(__always)
    private static func readU32(_ buf: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 3 < buf.count else { return 0 }
        return UInt32(buf[offset])
             | (UInt32(buf[offset + 1]) << 8)
             | (UInt32(buf[offset + 2]) << 16)
             | (UInt32(buf[offset + 3]) << 24)
    }

    /// Write a little-endian UInt16 into a byte array.
    @inline(__always)
    private static func writeU16(_ buf: inout [UInt8], _ offset: Int, _ val: UInt16) {
        guard offset >= 0, offset + 1 < buf.count else { return }
        buf[offset]     = UInt8(val & 0xFF)
        buf[offset + 1] = UInt8((val >> 8) & 0xFF)
    }

    /// Write a little-endian UInt32 into a byte array.
    @inline(__always)
    private static func writeU32(_ buf: inout [UInt8], _ offset: Int, _ val: UInt32) {
        guard offset >= 0, offset + 3 < buf.count else { return }
        buf[offset]     = UInt8(val & 0xFF)
        buf[offset + 1] = UInt8((val >> 8) & 0xFF)
        buf[offset + 2] = UInt8((val >> 16) & 0xFF)
        buf[offset + 3] = UInt8((val >> 24) & 0xFF)
    }

    /// Write a UInt32 into a DynBuf's internal buffer at a given offset.
    @inline(__always)
    private static func writeU32InBuf(_ buf: inout [UInt8], _ offset: Int, _ val: UInt32) {
        guard offset >= 0, offset + 3 < buf.count else { return }
        buf[offset]     = UInt8(val & 0xFF)
        buf[offset + 1] = UInt8((val >> 8) & 0xFF)
        buf[offset + 2] = UInt8((val >> 16) & 0xFF)
        buf[offset + 3] = UInt8((val >> 24) & 0xFF)
    }

    // =========================================================================
    // MARK: 7. Trace Block Fusion
    // =========================================================================

    /// Opcodes eligible for the fast mini-interpreter trace execution.
    /// Only loops whose bodies contain exclusively these opcodes are traced.
    private static let traceEligibleOpcodes: Set<JeffJSOpcode> = [
        // Push values
        .push_i32, .push_const, .push_0, .push_1, .push_minus1,
        .push_2, .push_3, .push_4, .push_5, .push_6, .push_7,
        .push_i8, .push_i16, .push_false, .push_true, .push_null, .undefined,

        // Local access (including TDZ-check variants)
        .get_loc, .get_loc0, .get_loc1, .get_loc2, .get_loc3, .get_loc8,
        .put_loc, .put_loc0, .put_loc1, .put_loc2, .put_loc3, .put_loc8,
        .set_loc, .set_loc0, .set_loc1, .set_loc2, .set_loc3, .set_loc8,
        .get_loc_check, .get_loc_checkthis,

        // Argument access
        .get_arg, .get_arg0, .get_arg1, .get_arg2, .get_arg3,

        // Stack manipulation
        .dup, .drop, .nip, .nip1, .swap, .perm3, .perm4, .perm5,

        // Arithmetic
        .add, .sub, .mul, .div, .mod, .neg, .inc, .dec, .post_inc, .post_dec, .plus,

        // Comparison
        .lt, .lte, .gt, .gte, .eq, .neq, .strict_eq, .strict_neq,

        // Bitwise
        .shl, .sar, .shr, .and, .or, .xor, .not,

        // Boolean/type
        .lnot, .typeof_,

        // Control flow (branches + jumps — handled within the trace)
        .if_true, .if_false, .goto_, .if_true8, .if_false8, .goto8, .goto16,

        // Fused short forms (arithmetic + locals only)
        .get_loc8_add, .get_loc8_get_loc8, .push_i32_put_loc8,

        // NOP (skip harmlessly)
        .nop,
    ]

    /// Analyze final bytecode for hot loop candidates and populate trace blocks.
    /// Called after resolveLabels when jump offsets are finalized.
    static func fuseBasicBlocks(_ fb: JeffJSFunctionBytecode) {
        let bc = fb.bytecode
        let len = fb.bytecodeLen
        guard len > 0, !bc.isEmpty else { return }

        // Phase 1: Find all backward unconditional jumps (loop back-edges).
        // Collect (entryPC, exitPC) candidates.
        struct Candidate {
            let entryPC: Int
            let exitPC: Int
        }
        var candidates: [Candidate] = []

        var pc = 0
        while pc < len && pc < bc.count {
            guard let (op, opWidth) = readOpcodeFromBuf(bc, pc) else {
                pc += 1
                continue
            }
            let info = jeffJSGetOpcodeInfo(op)
            let instrSize = max(Int(info.size) + (opWidth - 1), 1)

            switch op {
            case .goto_:
                // 32-bit signed offset, relative to instruction end (pc + instrSize)
                guard pc + opWidth + 3 < bc.count else { break }
                let raw = readU32(bc, pc + opWidth)
                let offset = Int(Int32(bitPattern: raw))
                if offset < 0 {
                    let target = pc + instrSize + offset
                    if target >= 0 {
                        candidates.append(Candidate(entryPC: target, exitPC: pc + instrSize))
                    }
                }

            case .goto8:
                // 8-bit signed offset, relative to instruction end (pc + instrSize)
                guard pc + opWidth < bc.count else { break }
                let raw = bc[pc + opWidth]
                let offset = Int(Int8(bitPattern: raw))
                if offset < 0 {
                    let target = pc + instrSize + offset
                    if target >= 0 {
                        candidates.append(Candidate(entryPC: target, exitPC: pc + instrSize))
                    }
                }

            case .goto16:
                // 16-bit signed offset, relative to instruction end (pc + instrSize)
                guard pc + opWidth + 1 < bc.count else { break }
                let raw = readU16(bc, pc + opWidth)
                let offset = Int(Int16(bitPattern: raw))
                if offset < 0 {
                    let target = pc + instrSize + offset
                    if target >= 0 {
                        candidates.append(Candidate(entryPC: target, exitPC: pc + instrSize))
                    }
                }

            default:
                break
            }

            pc += instrSize
        }

        guard !candidates.isEmpty else { return }

        // Phase 2: Check eligibility for each candidate — all opcodes in
        // [entryPC, exitPC) must be in the traceEligibleOpcodes set.
        var traceBlocks: [Int: TraceBlockInfo] = [:]

        for candidate in candidates {
            let entryPC = candidate.entryPC
            let exitPC = candidate.exitPC
            guard entryPC >= 0, exitPC <= len, entryPC < exitPC else { continue }

            var eligible = true
            var checkPC = entryPC
            while checkPC < exitPC && checkPC < bc.count {
                guard let (checkOp, checkWidth) = readOpcodeFromBuf(bc, checkPC) else {
                    eligible = false
                    break
                }
                if !traceEligibleOpcodes.contains(checkOp) {
                    eligible = false
                    break
                }
                let checkInfo = jeffJSGetOpcodeInfo(checkOp)
                let checkSize = max(Int(checkInfo.size) + (checkWidth - 1), 1)
                checkPC += checkSize
            }

            // The walk must end exactly at exitPC for valid trace boundaries
            if eligible && checkPC == exitPC {
                traceBlocks[entryPC] = TraceBlockInfo(entryPC: entryPC, exitPC: exitPC)
            }
        }

        if !traceBlocks.isEmpty {
            fb.traceBlocks = traceBlocks
        }
    }
}

// =============================================================================
// MARK: - SLEB128 Encoding Helper
// =============================================================================

// putSLEB128 is defined in JeffJSCUtils.swift.
// This file uses it from there to avoid duplicate declarations.
