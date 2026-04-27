// JeffJSParser.swift
// JeffJS - 1:1 Swift port of QuickJS JavaScript engine
//
// Single-pass recursive-descent parser that emits bytecode directly (no AST).
// Port of js_parse_source_element, js_parse_statement, js_parse_assign_expr,
// and all supporting parse functions from QuickJS (quickjs.c).
//
// Copyright 2026 Jeff Bachand. All rights reserved.

import Foundation

// =============================================================================
// MARK: - Parser-Specific Supporting Types
// =============================================================================

/// Variable scope descriptor used during parsing to track lexical scope chains.
struct JeffJSVarScope {
    var parent: Int = -1             // index of parent scope (-1 = none)
    var first: Int = -1              // first variable index in this scope
}

/// Block environment tracking for break/continue label targets.
struct JeffJSBlockEnv {
    var breakLabel: Int = -1         // label for break
    var continueLabel: Int = -1      // label for continue
    var labelName: JSAtom = 0        // named label (0 = anonymous)
    var scopeLevel: Int = 0          // scope level at block entry
    var hasIterator: Bool = false    // true if this is a for-of/for-in block
    var parent: Int = -1             // index of parent block env
}

/// LValue kind for assignments and update expressions.
enum LValueKind: Int {
    case none = 0
    case `var` = 1                   // simple variable
    case field = 2                   // object.property
    case arrayElem = 3               // object[key]
    case varRef = 4                  // closure variable
    case superField = 5              // super.property
    case superElem = 6               // super[key]
    case privateField = 7           // this.#field
}

/// Tracks the state of an LValue on the stack for compound assignments.
struct LValueInfo {
    var kind: LValueKind = .none
    var scopeLevel: Int = 0
    var atom: JSAtom = 0
    var label: Int = -1
}

/// Assignment operator kind for compound assignments.
enum AssignOpKind: Int {
    case plain = 0                   // =
    case add = 1                     // +=
    case sub = 2                     // -=
    case mul = 3                     // *=
    case div = 4                     // /=
    case mod = 5                     // %=
    case pow = 6                     // **=
    case shl = 7                     // <<=
    case sar = 8                     // >>=
    case shr = 9                     // >>>=
    case and = 10                    // &=
    case or = 11                     // |=
    case xor = 12                    // ^=
    case land = 13                   // &&=
    case lor = 14                    // ||=
    case nullishCoalescing = 15      // ??=
}

/// Destructuring target kind.
enum DestructuringKind: Int {
    case binding = 0                 // let/const/var binding
    case assignment = 1              // assignment target
}

/// Property definition kind for object/class members.
enum PropertyKind: Int {
    case data = 0
    case getter = 1
    case setter = 2
    case method = 3
    case spread = 4
    case shorthand = 5
    case computedMethod = 6
    case computedGetter = 7
    case computedSetter = 8
    case protoField = 9             // __proto__: value
}

/// Saved tokenizer state for replaying a default parameter expression.
struct JeffJSSavedDefaultParam {
    let argIndex: Int          // index in the childFd.args array
    let paramName: JSAtom      // atom for the parameter name
    let bufPtr: Int            // saved tokenizer bufPtr (just past '=')
    let lineNum: Int           // saved line number
    let token: JeffJSToken     // saved current token
    let gotLF: Bool
    let lastLineNum: Int
    let lastPtr: Int
    let templateNestLevel: Int
    // End positions (set after skipping)
    var endBufPtr: Int = 0
    var endLineNum: Int = 0
    var endToken: JeffJSToken = JeffJSToken()
    var endGotLF: Bool = false
    var endLastLineNum: Int = 0
    var endLastPtr: Int = 0
    var endTemplateNestLevel: Int = 0
}

/// Info about a rest parameter.
struct JeffJSRestParamInfo {
    let argIndex: Int      // position in parameter list (0-based)
    let paramName: JSAtom  // atom for the rest parameter name
}

/// Saved tokenizer state for replaying a destructuring parameter pattern.
/// During parseFormalParameters, when we encounter `{x, y}` or `[a, b]` in
/// parameter position, we save the tokenizer position so that parseFunctionBody
/// can emit `get_arg(argIndex)` followed by the destructuring binding code.
struct JeffJSSavedDestructParam {
    let argIndex: Int          // index in the childFd.args array
    let bufPtr: Int            // saved tokenizer bufPtr (at the '{' or '[')
    let lineNum: Int
    let token: JeffJSToken
    let gotLF: Bool
    let lastLineNum: Int
    let lastPtr: Int
    let templateNestLevel: Int
    // End positions (set after skipping the pattern + optional default)
    var endBufPtr: Int = 0
    var endLineNum: Int = 0
    var endToken: JeffJSToken = JeffJSToken()
    var endGotLF: Bool = false
    var endLastLineNum: Int = 0
    var endLastPtr: Int = 0
    var endTemplateNestLevel: Int = 0
}

// =============================================================================
// MARK: - JeffJSParser
// =============================================================================

/// The recursive-descent parser. Consumes tokens from JeffJSParseState and
/// emits bytecode into a JeffJSFunctionDefCompiler. This is a direct port of
/// the parser section of quickjs.c.
///
/// Usage:
/// ```swift
/// let s = JeffJSParseState(source: "var x = 42;", filename: "test.js")
/// let fd = JeffJSFunctionDefCompiler()
/// let parser = JeffJSParser(s: s, fd: fd)
/// parser.parseProgram()
/// ```
final class JeffJSParser {

    // -- Parse state (token stream) --
    let s: JeffJSParseState

    // -- Current function definition (bytecode target) --
    var fd: JeffJSFunctionDefCompiler

    // -- Block environment stack (for break/continue) --
    var blockEnvs: [JeffJSBlockEnv] = []
    var curBlockEnvIdx: Int = -1

    // -- Finally scope stack (for return inside try-finally) --
    // When a `return` is inside a try-finally block, the parser must emit
    // `gosub` to each enclosing finally block before the actual return.
    struct FinallyScope {
        let label: Int           // label for the finally block
        let needsNipCatch: Bool  // true if inside try body (catch handler on stack)
    }
    var finallyScopes: [FinallyScope] = []

    // -- Expression parsing flags --
    var inFlag: Bool = true          // allow 'in' in relational expressions
    /// Set to true after parsing 'super' as a primary expression so that
    /// parseCallExpr can emit call_constructor instead of a regular call.
    var lastExprWasSuper: Bool = false
    /// True while parsing an interpolated expression inside a template literal
    /// (`${...}`).  Prevents `parseCallExpr` from treating the next
    /// TOK_TEMPLATE (produced when the tokenizer hits `}`) as a tagged
    /// template call.
    var inTemplateExpr: Bool = false

    // -- Error state --
    var hasError: Bool = false

    // -- Safety limits to prevent OOM from parser bugs or adversarial input --
    /// Maximum recursion depth for the parser. Complex JS can nest expressions
    /// deeply (e.g., chained ternaries, nested calls). Kept conservative to
    /// avoid stack overflow on iOS devices (512KB thread stack).
    static let maxRecursionDepth = 200
    /// Maximum scope nesting depth.
    static let maxScopeDepth = 256
    /// Maximum bytecode buffer size in bytes (50 MB).
    /// This is a hard cap — if we exceed it, we abort with a syntax error.
    static let maxBytecodeSize = 50 * 1024 * 1024

    /// Current recursion depth. Incremented when entering expression/statement
    /// sub-parsers and decremented on exit.
    var recursionDepth: Int = 0
    /// Current scope nesting depth.
    var scopeDepth: Int = 0

    /// Check whether we have hit any limit (error, recursion, bytecode size).
    /// Every loop and recursive call in the parser should consult this.
    @inline(__always)
    var shouldAbort: Bool {
        return hasError || fd.byteCode.error
    }

    /// Increment recursion depth and check the limit.
    /// Returns `true` if parsing may continue, `false` if the limit was hit.
    @inline(__always)
    @discardableResult
    func enterRecursion() -> Bool {
        recursionDepth += 1
        if recursionDepth > JeffJSParser.maxRecursionDepth {
            syntaxError("expression too deeply nested (recursion limit \(JeffJSParser.maxRecursionDepth) exceeded)")
            return false
        }
        // Also check if the bytecode buffer blew its cap
        if fd.byteCode.len > JeffJSParser.maxBytecodeSize {
            syntaxError("bytecode size limit exceeded (\(JeffJSParser.maxBytecodeSize) bytes)")
            return false
        }
        return true
    }

    /// Decrement recursion depth.
    @inline(__always)
    func leaveRecursion() {
        recursionDepth -= 1
    }

    init(s: JeffJSParseState, fd: JeffJSFunctionDefCompiler) {
        self.s = s
        self.fd = fd
    }

    // =========================================================================
    // MARK: - Token Helpers
    // =========================================================================

    /// Current token type.
    @inline(__always)
    var tok: Int { return s.token.type }

    /// Advance to the next token.
    @inline(__always)
    @discardableResult
    func next() -> Bool {
        return s.nextToken()
    }

    /// Expect the current token to be `type` and consume it.
    /// Reports a syntax error if it does not match.
    @discardableResult
    func expect(_ type: Int) -> Bool {
        if tok != type {
            let expected = tokenName(type)
            let got = tokenName(tok)
            syntaxError("expected '\(expected)' but got '\(got)'")
            return false
        }
        return next()
    }

    /// Expect a semicolon: real ';', ASI via newline, '}', or EOF.
    @discardableResult
    func expectSemicolon() -> Bool {
        if tok == 0x3B { // ';'
            return next()
        }
        // Automatic Semicolon Insertion
        if s.gotLF || tok == 0x7D /* '}' */ || tok == JSTokenType.TOK_EOF.rawValue {
            return true
        }
        syntaxError("expected ';'")
        return false
    }

    /// Human-readable name for a token type.
    func tokenName(_ type: Int) -> String {
        if type < 128 {
            if type == 0 { return "EOF" }
            return String(Character(Unicode.Scalar(type)!))
        }
        switch type {
        case JSTokenType.TOK_NUMBER.rawValue: return "number"
        case JSTokenType.TOK_STRING.rawValue: return "string"
        case JSTokenType.TOK_TEMPLATE.rawValue: return "template"
        case JSTokenType.TOK_IDENT.rawValue: return "identifier"
        case JSTokenType.TOK_REGEXP.rawValue: return "regexp"
        case JSTokenType.TOK_EOF.rawValue: return "end of input"
        case JSTokenType.TOK_ARROW.rawValue: return "=>"
        case JSTokenType.TOK_ELLIPSIS.rawValue: return "..."
        case JSTokenType.TOK_IF.rawValue: return "if"
        case JSTokenType.TOK_ELSE.rawValue: return "else"
        case JSTokenType.TOK_RETURN.rawValue: return "return"
        case JSTokenType.TOK_VAR.rawValue: return "var"
        case JSTokenType.TOK_LET.rawValue: return "let"
        case JSTokenType.TOK_CONST.rawValue: return "const"
        case JSTokenType.TOK_FUNCTION.rawValue: return "function"
        case JSTokenType.TOK_CLASS.rawValue: return "class"
        case JSTokenType.TOK_FOR.rawValue: return "for"
        case JSTokenType.TOK_WHILE.rawValue: return "while"
        case JSTokenType.TOK_DO.rawValue: return "do"
        case JSTokenType.TOK_SWITCH.rawValue: return "switch"
        case JSTokenType.TOK_CASE.rawValue: return "case"
        case JSTokenType.TOK_DEFAULT.rawValue: return "default"
        case JSTokenType.TOK_BREAK.rawValue: return "break"
        case JSTokenType.TOK_CONTINUE.rawValue: return "continue"
        case JSTokenType.TOK_TRY.rawValue: return "try"
        case JSTokenType.TOK_CATCH.rawValue: return "catch"
        case JSTokenType.TOK_FINALLY.rawValue: return "finally"
        case JSTokenType.TOK_THROW.rawValue: return "throw"
        case JSTokenType.TOK_IMPORT.rawValue: return "import"
        case JSTokenType.TOK_EXPORT.rawValue: return "export"
        case JSTokenType.TOK_NEW.rawValue: return "new"
        case JSTokenType.TOK_THIS.rawValue: return "this"
        case JSTokenType.TOK_SUPER.rawValue: return "super"
        case JSTokenType.TOK_DEBUGGER.rawValue: return "debugger"
        case JSTokenType.TOK_WITH.rawValue: return "with"
        case JSTokenType.TOK_YIELD.rawValue: return "yield"
        case JSTokenType.TOK_AWAIT.rawValue: return "await"
        case JSTokenType.TOK_DELETE.rawValue: return "delete"
        case JSTokenType.TOK_TYPEOF.rawValue: return "typeof"
        case JSTokenType.TOK_VOID.rawValue: return "void"
        case JSTokenType.TOK_IN.rawValue: return "in"
        case JSTokenType.TOK_INSTANCEOF.rawValue: return "instanceof"
        case JSTokenType.TOK_NULL.rawValue: return "null"
        case JSTokenType.TOK_TRUE.rawValue: return "true"
        case JSTokenType.TOK_FALSE.rawValue: return "false"
        default: return "token(\(type))"
        }
    }

    /// Report a syntax error.
    func syntaxError(_ msg: String) {
        if !hasError {
            s.syntaxError(msg)
            hasError = true
        }
    }

    /// Check if current token is an identifier with a specific name.
    func isIdent(_ name: String) -> Bool {
        if tok != JSTokenType.TOK_IDENT.rawValue { return false }
        let atom = s.token.identAtom
        // Compare against the atom table
        if let ctx = s.ctx {
            return ctx.findAtom(name) == atom
        }
        return false
    }

    /// Check if the current token can start an expression.
    var isExprStart: Bool {
        switch tok {
        case JSTokenType.TOK_NUMBER.rawValue,
             JSTokenType.TOK_STRING.rawValue,
             JSTokenType.TOK_TEMPLATE.rawValue,
             JSTokenType.TOK_IDENT.rawValue,
             JSTokenType.TOK_THIS.rawValue,
             JSTokenType.TOK_SUPER.rawValue,
             JSTokenType.TOK_NULL.rawValue,
             JSTokenType.TOK_TRUE.rawValue,
             JSTokenType.TOK_FALSE.rawValue,
             JSTokenType.TOK_NEW.rawValue,
             JSTokenType.TOK_DELETE.rawValue,
             JSTokenType.TOK_TYPEOF.rawValue,
             JSTokenType.TOK_VOID.rawValue,
             JSTokenType.TOK_FUNCTION.rawValue,
             JSTokenType.TOK_CLASS.rawValue,
             JSTokenType.TOK_YIELD.rawValue,
             JSTokenType.TOK_AWAIT.rawValue,
             JSTokenType.TOK_INC.rawValue,
             JSTokenType.TOK_DEC.rawValue,
             JSTokenType.TOK_IMPORT.rawValue,
             0x28, // '('
             0x5B, // '['
             0x7B, // '{'
             0x2F, // '/'  (regex — fallback)
             JSTokenType.TOK_REGEXP.rawValue, // regex (tokenizer auto-detected)
             0x60, // '`'
             0x21, // '!'
             0x7E, // '~'
             0x2B, // '+'
             0x2D: // '-'
            return true
        default:
            return false
        }
    }

    // =========================================================================
    // MARK: - Bytecode Emission Helpers
    // =========================================================================

    /// Emit a single opcode byte.
    @inline(__always)
    func emitOp(_ op: JeffJSOpcode) {
        if fd.byteCode.error {
            // DynBuf already hit its size limit -- propagate as parse error
            if !hasError {
                hasError = true
                s.syntaxError("bytecode buffer size limit exceeded")
            }
            return
        }
        fd.byteCode.putOpcode(op.rawValue)
    }

    /// Emit a u8 operand.
    @inline(__always)
    func emitU8(_ val: UInt8) {
        fd.byteCode.putU8(val)
    }

    /// Emit a u16 operand (little-endian).
    @inline(__always)
    func emitU16(_ val: UInt16) {
        fd.byteCode.putU16(val)
    }

    /// Emit a u32 operand (little-endian).
    @inline(__always)
    func emitU32(_ val: UInt32) {
        fd.byteCode.putU32(val)
    }

    /// Emit an i32 operand (little-endian).
    @inline(__always)
    func emitI32(_ val: Int32) {
        fd.byteCode.putU32(UInt32(bitPattern: val))
    }

    /// Emit an atom operand (u32).
    @inline(__always)
    func emitAtom(_ atom: JSAtom) {
        fd.byteCode.putU32(atom)
    }

    /// Allocate a new label and return its index.
    func newLabel() -> Int {
        let idx = fd.labels.count
        fd.labels.append(JeffJSLabelSlot())
        return idx
    }

    /// Emit a label definition at the current bytecode position.
    func emitLabel(_ label: Int) {
        guard label >= 0 && label < fd.labels.count else { return }
        emitOp(.label_)
        emitU32(UInt32(label))
        fd.labels[label].pos = fd.byteCode.len
    }

    /// Emit an unconditional jump to a label.
    func emitGoto(_ label: Int) {
        emitOp(.goto_)
        emitU32(UInt32(label))
    }

    /// Emit a conditional branch (branch if false).
    func emitIfFalse(_ label: Int) {
        emitOp(.if_false)
        emitU32(UInt32(label))
    }

    /// Emit a conditional branch (branch if true).
    func emitIfTrue(_ label: Int) {
        emitOp(.if_true)
        emitU32(UInt32(label))
    }

    /// Emit OP_push_i32 with a 32-bit signed integer literal.
    func emitPushI32(_ val: Int32) {
        emitOp(.push_i32)
        emitI32(val)
    }

    /// Emit a push_const opcode referencing the constant pool.
    func emitPushConst(_ idx: Int) {
        emitOp(.push_const)
        emitU32(UInt32(idx))
    }

    /// Add a constant to the constant pool and return its index.
    func addConstPoolValue(_ val: JeffJSValue) -> Int {
        let idx = fd.cpool.count
        fd.cpool.append(val)
        return idx
    }

    /// Emit a scope_get_var opcode (to be resolved by the compiler later).
    func emitScopeGetVar(_ atom: JSAtom, scopeLevel: Int) {
        emitOp(.scope_get_var)
        emitAtom(atom)
        emitU16(UInt16(scopeLevel))
    }

    /// Emit a scope_put_var opcode.
    func emitScopePutVar(_ atom: JSAtom, scopeLevel: Int) {
        emitOp(.scope_put_var)
        emitAtom(atom)
        emitU16(UInt16(scopeLevel))
    }

    /// Emit a scope_put_var_init opcode.
    func emitScopePutVarInit(_ atom: JSAtom, scopeLevel: Int) {
        emitOp(.scope_put_var_init)
        emitAtom(atom)
        emitU16(UInt16(scopeLevel))
    }

    /// Emit a scope_delete_var opcode.
    func emitScopeDeleteVar(_ atom: JSAtom, scopeLevel: Int) {
        emitOp(.scope_delete_var)
        emitAtom(atom)
        emitU16(UInt16(scopeLevel))
    }

    // MARK: - Token helpers

    /// Returns the string name for a keyword token type.
    func keywordTokenName(_ t: Int) -> String {
        // Map each keyword token to its string representation.
        // This covers all JS keywords that can appear as property names after '.'.
        if let pa = JSPredefinedAtom(rawValue: UInt32(t - JSTokenType.TOK_NULL.rawValue + 1)) {
            return pa.stringValue
        }
        // Fallback: use strValue if available
        return s.token.strValue.isEmpty ? "?" : s.token.strValue
    }

    /// Returns true if the token is a keyword (which can also be used as a property name after `.`).
    func isKeywordToken(_ t: Int) -> Bool {
        // Keywords in the token type range: null, true, false, if, else, return, var, ...
        // All keyword token types are in the range [TOK_NULL .. TOK_AWAIT] which
        // corresponds to predefined atoms [1 .. 46] in JSPredefinedAtom.
        // Also accept 'of', 'from', 'as', 'get', 'set', 'let', 'async', 'yield', etc.
        return t >= JSTokenType.TOK_NULL.rawValue && t <= JSTokenType.TOK_OF.rawValue
    }

    // MARK: - Bytecode introspection helpers (for assignment rewriting)

    /// Peek at the opcode at the given bytecode position.
    func peekOpcodeAt(_ pos: Int) -> JeffJSOpcode? {
        guard pos < fd.byteCode.len else { return nil }
        // Wide opcode: byte 0 is 0x00 (invalid), real opcode is 256 + byte 1
        if fd.byteCode.buf[pos] == 0 && pos + 1 < fd.byteCode.len {
            return JeffJSOpcode(rawValue: 256 + UInt16(fd.byteCode.buf[pos + 1]))
        }
        return JeffJSOpcode(rawValue: UInt16(fd.byteCode.buf[pos]))
    }

    /// Check if the last opcode emitted (before current position) is get_field.
    /// get_field is 5 bytes: 1 byte opcode + 4 byte atom.
    func lastEmittedIsGetField() -> (isGetField: Bool, fieldStart: Int, atom: UInt32) {
        let len = fd.byteCode.len
        // get_field is 5 bytes: [opcode, atom0, atom1, atom2, atom3]
        guard len >= 5 else { return (false, 0, 0) }
        let pos = len - 5
        if let op = peekOpcodeAt(pos), op == .get_field {
            let atom = readU32FromBuf(fd.byteCode.buf, pos + 1)
            return (true, pos, atom)
        }
        return (false, 0, 0)
    }

    /// Read a little-endian u32 from a byte buffer.
    func readU32FromBuf(_ buf: [UInt8], _ pos: Int) -> UInt32 {
        guard pos + 3 < buf.count else { return 0 }
        return UInt32(buf[pos]) | (UInt32(buf[pos+1]) << 8) |
               (UInt32(buf[pos+2]) << 16) | (UInt32(buf[pos+3]) << 24)
    }

    /// Read a little-endian u16 from a byte buffer.
    func readU16FromBuf(_ buf: [UInt8], _ pos: Int) -> UInt16 {
        guard pos + 1 < buf.count else { return 0 }
        return UInt16(buf[pos]) | (UInt16(buf[pos+1]) << 8)
    }

    /// Read a single u8 from a byte buffer.
    func readU8FromBuf(_ buf: [UInt8], _ pos: Int) -> UInt8 {
        guard pos < buf.count else { return 0 }
        return buf[pos]
    }

    /// Scan bytecode backwards to find the last GET opcode (scope_get_var, get_field, get_array_el).
    /// Returns the opcode and its position, or (nil, nil) if not found.
    func findLastGetOpcode(from start: Int, to end: Int) -> (JeffJSOpcode?, Int?) {
        // Walk forward through bytecode to find positions of all instructions,
        // then return the last one that's a GET opcode.
        var pos = start
        var lastGetOp: JeffJSOpcode? = nil
        var lastGetPos: Int? = nil
        while pos < end {
            guard let op = peekOpcodeAt(pos) else { break }
            if op == .scope_get_var || op == .get_field || op == .get_array_el {
                lastGetOp = op
                lastGetPos = pos
            }
            // Advance by instruction size
            let info = jeffJSGetOpcodeInfo(op)
            let instrSize: Int
            if fd.byteCode.buf[pos] == 0 {
                instrSize = Int(info.size) + 1  // wide opcode: +1 for prefix byte
            } else {
                instrSize = Int(info.size)
            }
            if instrSize <= 0 { break }  // safety
            pos += instrSize
        }
        return (lastGetOp, lastGetPos)
    }

    /// After a prefix ++/-- (which emits get + inc/dec), emit the corresponding
    /// store-back opcode so the incremented value is written back to the variable.
    /// Without this, `++n` reads n, increments on the stack, but never stores back.
    func emitPrefixUpdateStore(from start: Int, to end: Int) {
        // Scan the bytecode emitted by the unary expression to find the last GET
        // opcode and emit the matching SET opcode.
        var pos = start
        var lastOp: JeffJSOpcode? = nil
        var lastPos: Int? = nil
        while pos < end {
            guard let op = peekOpcodeAt(pos) else { break }
            switch op {
            case .get_loc, .get_loc0, .get_loc1, .get_loc2, .get_loc3, .get_loc8,
                 .get_arg, .get_arg0, .get_arg1, .get_arg2, .get_arg3,
                 .get_var_ref, .get_var_ref0, .get_var_ref1, .get_var_ref2, .get_var_ref3,
                 .scope_get_var, .get_var, .get_field, .get_array_el:
                lastOp = op
                lastPos = pos
            default: break
            }
            let info = jeffJSGetOpcodeInfo(op)
            let instrSize = fd.byteCode.buf[pos] == 0 ? Int(info.size) + 1 : Int(info.size)
            if instrSize <= 0 { break }
            pos += instrSize
        }
        guard let op = lastOp, let lpos = lastPos else { return }
        let wide = fd.byteCode.buf[lpos] == 0
        let opcodeOffset = wide ? 1 : 0
        // Emit dup + put (dup keeps value on stack for the return, put stores it).
        // We use dup+put instead of set because scope_* opcodes resolved by
        // resolveVariables produce put_* variants (pop semantics), not set_* (peek).
        switch op {
        case .get_loc:
            let idx = readU16FromBuf(fd.byteCode.buf, lpos + opcodeOffset + 1)
            emitOp(.dup); emitOp(.put_loc); emitU16(idx)
        case .get_loc0: emitOp(.dup); emitOp(.put_loc0)
        case .get_loc1: emitOp(.dup); emitOp(.put_loc1)
        case .get_loc2: emitOp(.dup); emitOp(.put_loc2)
        case .get_loc3: emitOp(.dup); emitOp(.put_loc3)
        case .get_loc8:
            let idx = readU8FromBuf(fd.byteCode.buf, lpos + opcodeOffset + 1)
            emitOp(.dup); emitOp(.put_loc8); emitU8(idx)
        case .get_arg:
            let idx = readU16FromBuf(fd.byteCode.buf, lpos + opcodeOffset + 1)
            emitOp(.dup); emitOp(.put_arg); emitU16(idx)
        case .get_arg0: emitOp(.dup); emitOp(.put_arg0)
        case .get_arg1: emitOp(.dup); emitOp(.put_arg1)
        case .get_arg2: emitOp(.dup); emitOp(.put_arg2)
        case .get_arg3: emitOp(.dup); emitOp(.put_arg3)
        case .get_var_ref:
            let idx = readU16FromBuf(fd.byteCode.buf, lpos + opcodeOffset + 1)
            emitOp(.dup); emitOp(.put_var_ref); emitU16(idx)
        case .get_var_ref0: emitOp(.dup); emitOp(.put_var_ref0)
        case .get_var_ref1: emitOp(.dup); emitOp(.put_var_ref1)
        case .get_var_ref2: emitOp(.dup); emitOp(.put_var_ref2)
        case .get_var_ref3: emitOp(.dup); emitOp(.put_var_ref3)
        case .scope_get_var:
            let atom = readU32FromBuf(fd.byteCode.buf, lpos + opcodeOffset + 1)
            let scopeLevel = readU16FromBuf(fd.byteCode.buf, lpos + opcodeOffset + 5)
            // dup + scope_put_var: keeps value on stack (like set_ semantics)
            emitOp(.dup)
            emitScopePutVar(atom, scopeLevel: Int(scopeLevel))
        case .get_var:
            let atom = readU32FromBuf(fd.byteCode.buf, lpos + opcodeOffset + 1)
            emitOp(.dup)
            emitOp(.put_var); emitAtom(atom)
        case .get_field:
            // ++obj.prop: change get_field → get_field2 to preserve obj.
            // After get_field2 + inc: [obj, new_value]
            let fAtom = readU32FromBuf(fd.byteCode.buf, lpos + opcodeOffset + 1)
            let fRaw = JeffJSOpcode.get_field2.rawValue
            fd.byteCode.buf[lpos + opcodeOffset] = fRaw <= 255
                ? UInt8(truncatingIfNeeded: fRaw)
                : UInt8(truncatingIfNeeded: fRaw &- 256)
            // [obj, new] → dup → [obj, new, new] → rot3l → [new, new, obj]
            // → swap → [new, obj, new] → put_field → [new]
            emitOp(.dup)
            emitOp(.rot3l)
            emitOp(.swap)
            emitPutField(fAtom)
        case .get_array_el:
            // ++obj[key]: bytecode is ..., get_array_el, inc/dec
            // Read the inc/dec opcode before rewinding.
            let getElSize = wide ? 2 : 1
            let incDecByte = fd.byteCode.buf[lpos + getElSize]
            let incDecOp = JeffJSOpcode(rawValue: UInt16(incDecByte)) ?? .inc
            fd.byteCode.len = lpos   // rewind past get_array_el + inc/dec; stack: [obj, key]
            emitOp(.dup2)            // [obj, key, obj, key]
            emitOp(.get_array_el)    // [obj, key, value]
            emitOp(incDecOp)         // [obj, key, new_value]
            emitOp(.dup)             // [obj, key, new, new]
            emitOp(.perm4)           // [new, obj, key, new]
            emitOp(.put_array_el)    // [new]
        default: break
        }
    }

    /// Emit line and column debug info.
    func emitLineNum() {
        let lineNum = s.lineNum
        let (_, colNum) = s.getLineCol(s.bufPtr)
        if lineNum != fd.lastLineNum || colNum != fd.lastColNum {
            emitOp(.line_num)
            emitU32(UInt32(lineNum))
            emitU32(UInt32(colNum))
            fd.lastLineNum = lineNum
            fd.lastColNum = colNum
        }
    }

    /// Emit a get_field opcode.
    func emitGetField(_ atom: JSAtom) {
        emitOp(.get_field)
        emitAtom(atom)
    }

    /// Emit a put_field opcode.
    func emitPutField(_ atom: JSAtom) {
        emitOp(.put_field)
        emitAtom(atom)
    }

    /// Emit a define_field opcode.
    func emitDefineField(_ atom: JSAtom) {
        emitOp(.define_field)
        emitAtom(atom)
    }

    /// Emit a set_name opcode.
    func emitSetName(_ atom: JSAtom) {
        emitOp(.set_name)
        emitAtom(atom)
    }

    /// Emit an fclosure opcode referencing a child function in the cpool.
    func emitFClosure(_ cpoolIdx: Int) {
        emitOp(.fclosure)
        emitU32(UInt32(cpoolIdx))
    }

    /// Emit a call opcode.
    func emitCall(_ argc: Int) {
        emitOp(.call)
        emitU16(UInt16(argc))
    }

    /// Emit a call_method opcode.
    func emitCallMethod(_ argc: Int) {
        emitOp(.call_method)
        emitU16(UInt16(argc))
    }

    /// Emit a call_constructor opcode.
    func emitCallConstructor(_ argc: Int) {
        emitOp(.call_constructor)
        emitU16(UInt16(argc))
    }

    /// Emit enter_scope for a new lexical scope.
    func emitEnterScope(_ scopeIdx: Int) {
        emitOp(.enter_scope)
        emitU16(UInt16(scopeIdx))
    }

    /// Emit leave_scope.
    func emitLeaveScope(_ scopeIdx: Int) {
        emitOp(.leave_scope)
        emitU16(UInt16(scopeIdx))
    }

    /// Emit a catch opcode.
    func emitCatch(_ label: Int) {
        emitOp(.catch_)
        emitU32(UInt32(label))
    }

    /// Emit a gosub opcode (call finally block).
    func emitGosub(_ label: Int) {
        emitOp(.gosub)
        emitU32(UInt32(label))
    }

    /// Emit a throw_error opcode.
    func emitThrowError(_ atom: JSAtom, errorType: UInt8) {
        emitOp(.throw_error)
        emitAtom(atom)
        emitU8(errorType)
    }

    /// Emit a define_var opcode.
    func emitDefineVarOp(_ atom: JSAtom, flags: UInt8) {
        emitOp(.define_var)
        emitAtom(atom)
        emitU8(flags)
    }

    /// Emit a define_func opcode.
    func emitDefineFuncOp(_ atom: JSAtom, flags: UInt8) {
        emitOp(.define_func)
        emitAtom(atom)
        emitU8(flags)
    }

    // =========================================================================
    // MARK: - Scope Management
    // =========================================================================

    /// Push a new lexical scope. Returns the scope index.
    @discardableResult
    func pushScope() -> Int {
        scopeDepth += 1
        if scopeDepth > JeffJSParser.maxScopeDepth {
            syntaxError("scope nesting too deep (limit \(JeffJSParser.maxScopeDepth) exceeded)")
            scopeDepth -= 1
            return fd.curScope // return current scope to avoid crash
        }
        let idx = fd.scopes.count
        var scope = JeffJSScopeDef()
        scope.parent = fd.curScope
        scope.first = -1
        fd.scopes.append(scope)
        fd.curScope = idx
        emitEnterScope(idx)
        return idx
    }

    /// Pop the current lexical scope.
    func popScope(_ scopeIdx: Int) {
        scopeDepth -= 1
        guard scopeIdx >= 0 && scopeIdx < fd.scopes.count else { return }
        // Close all variables in this scope
        var varIdx = fd.scopes[scopeIdx].first
        while varIdx >= 0 && varIdx < fd.vars.count {
            let v = fd.vars[varIdx]
            if v.isCaptured {
                emitOp(.close_loc)
                emitU16(UInt16(varIdx))
            }
            varIdx = v.scopeNext
        }
        emitLeaveScope(scopeIdx)
        fd.curScope = fd.scopes[scopeIdx].parent
    }

    /// Define a variable in the current scope. Returns the variable index.
    @discardableResult
    func defineVar(_ name: JSAtom, isConst: Bool = false, isLexical: Bool = false,
                   varKind: Int = JSVarKindEnum.JS_VAR_NORMAL.rawValue) -> Int {
        var vd = JeffJSVarDef()
        vd.varName = name
        vd.scopeLevel = fd.curScope
        vd.scopeNext = fd.scopes[fd.curScope].first
        vd.isConst = isConst
        vd.isLexical = isLexical
        vd.varKind = varKind

        let idx = fd.vars.count
        fd.vars.append(vd)
        fd.scopes[fd.curScope].first = idx

        // TDZ: set_loc_uninitialized is now emitted at scope entry
        // (in resolveVariables when processing enter_scope) rather than
        // at the declaration point.  This ensures the variable is
        // uninitialized from the start of the scope, not just from where
        // the let/const statement appears.

        return idx
    }

    /// Find a variable by name in the current scope chain.
    /// Returns the variable index, or -1 if not found.
    func findVar(_ name: JSAtom) -> Int {
        var scope = fd.curScope
        while scope >= 0 && scope < fd.scopes.count {
            var varIdx = fd.scopes[scope].first
            while varIdx >= 0 && varIdx < fd.vars.count {
                if fd.vars[varIdx].varName == name {
                    return varIdx
                }
                varIdx = fd.vars[varIdx].scopeNext
            }
            scope = fd.scopes[scope].parent
        }
        return -1
    }

    /// Get the atom for a string, creating it if necessary.
    func getAtom(_ name: String) -> JSAtom {
        return s.ctx?.findAtom(name) ?? 0
    }

    // =========================================================================
    // MARK: - Block Environment (break/continue targets)
    // =========================================================================

    /// Push a new block environment for break/continue.
    func pushBlockEnv(breakLabel: Int, continueLabel: Int, labelName: JSAtom = 0,
                      hasIterator: Bool = false) {
        var env = JeffJSBlockEnv()
        env.breakLabel = breakLabel
        env.continueLabel = continueLabel
        env.labelName = labelName
        env.scopeLevel = fd.curScope
        env.hasIterator = hasIterator
        env.parent = curBlockEnvIdx
        blockEnvs.append(env)
        curBlockEnvIdx = blockEnvs.count - 1
    }

    /// Pop the current block environment.
    func popBlockEnv() {
        guard curBlockEnvIdx >= 0 else { return }
        curBlockEnvIdx = blockEnvs[curBlockEnvIdx].parent
    }

    /// Find a break label by optional label name.
    func findBreakLabel(_ labelName: JSAtom = 0) -> Int {
        var idx = curBlockEnvIdx
        while idx >= 0 {
            let env = blockEnvs[idx]
            if labelName == 0 || env.labelName == labelName {
                return env.breakLabel
            }
            idx = env.parent
        }
        return -1
    }

    /// Find a continue label by optional label name.
    func findContinueLabel(_ labelName: JSAtom = 0) -> Int {
        var idx = curBlockEnvIdx
        while idx >= 0 {
            let env = blockEnvs[idx]
            if labelName == 0 {
                // Unlabeled continue: find nearest loop
                if env.continueLabel >= 0 {
                    return env.continueLabel
                }
            } else if env.labelName == labelName {
                // Named continue: find this label's continue, or the nearest
                // inner continue (the loop inside the labeled statement).
                if env.continueLabel >= 0 {
                    return env.continueLabel
                }
                // The labeled statement doesn't have a continue label itself,
                // but the loop directly inside it does. Search inward from
                // the current position to find it.
                var inner = curBlockEnvIdx
                while inner > idx {
                    let innerEnv = blockEnvs[inner]
                    if innerEnv.continueLabel >= 0 {
                        return innerEnv.continueLabel
                    }
                    inner -= 1
                }
                return -1  // label found but no loop inside
            }
            idx = env.parent
        }
        return -1
    }

    // =========================================================================
    // MARK: - LValue Handling
    // =========================================================================

    /// Get the LValue that is currently on the stack.
    /// Used before an assignment or update expression.
    /// Emits the necessary bytecode to prepare the LValue for read (get) or write (put).
    func getLValue() -> LValueInfo {
        // The parser decides the LValue kind based on how the expression was emitted
        // This is a placeholder that returns the current lvalue state
        return LValueInfo()
    }

    /// Put a value into an LValue. The value and LValue pieces are on the stack.
    func putLValue(_ info: LValueInfo) {
        switch info.kind {
        case .none:
            break
        case .var:
            emitScopePutVar(info.atom, scopeLevel: info.scopeLevel)
        case .field:
            emitPutField(info.atom)
        case .arrayElem:
            emitOp(.put_array_el)
        case .varRef:
            emitOp(.put_var_ref)
            emitU16(UInt16(info.label))
        case .superField:
            emitOp(.put_super_value)
        case .superElem:
            emitOp(.put_super_value)
        case .privateField:
            emitOp(.put_private_field)
            emitAtom(info.atom)
        }
    }

    // =========================================================================
    // MARK: - Program / Module Entry Point
    // =========================================================================

    /// Parse a complete program (script or module).
    func parseProgram() {
        next() // prime the first token

        // Parse source elements (statements and declarations)
        while tok != JSTokenType.TOK_EOF.rawValue && !shouldAbort {
            parseSourceElement()
        }

        // Hoist top-level `var` declarations: insert `define_var` instructions
        // at position 0 so variables exist (as undefined) from the start.
        // This must happen before patchCompletionDrops because the bytecode
        // positions shift when we insert bytes at the front.
        if !fd.hoistedGlobalVarAtoms.isEmpty {
            // Build the define_var bytes for each atom
            var prefix = [UInt8]()
            for atom in fd.hoistedGlobalVarAtoms {
                prefix.append(UInt8(truncatingIfNeeded: JeffJSOpcode.define_var.rawValue))
                prefix.append(UInt8(truncatingIfNeeded: atom & 0xFF))
                prefix.append(UInt8(truncatingIfNeeded: (atom >> 8) & 0xFF))
                prefix.append(UInt8(truncatingIfNeeded: (atom >> 16) & 0xFF))
                prefix.append(UInt8(truncatingIfNeeded: (atom >> 24) & 0xFF))
                prefix.append(UInt8(JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE))
            }
            // Insert at position 0 and adjust all label/jump offsets
            fd.byteCode.buf.insert(contentsOf: prefix, at: 0)
            fd.byteCode.len += prefix.count
            // Shift hoisted function declaration ranges by the inserted prefix size
            fd.hoistedFuncDeclRanges = fd.hoistedFuncDeclRanges.map {
                ($0.0 + prefix.count, $0.1 + prefix.count)
            }
        }

        // For eval: find the last `drop` opcode in tail position and replace
        // it with `return_` so the expression value is returned. This handles
        // not just simple expression statements but also drops inside if/else
        // and try/catch branches.
        //
        // We scan backwards through the bytecode. Opcodes we can skip over
        // (they don't affect the value on TOS): label_, goto_, nip_catch,
        // leave_scope, gosub, ret (finally return), return_undef, nop.
        // When we find a `drop`, replace it with `nop` and emit `return_`
        // at the end. We replace ALL drops in tail position to handle both
        // branches of if/else.
        if patchCompletionDrops() {
            emitOp(.return_)
            return
        }

        // No expression statement at end — return undefined
        emitOp(.return_undef)
    }

    /// Scan backwards through bytecode and replace `drop` opcodes in tail
    /// position with `nop`. Returns true if at least one drop was replaced.
    ///
    /// Uses a work-list approach: starting from the last instruction, propagate
    /// "tail" status to predecessors and jump targets until no more changes.
    private func patchCompletionDrops() -> Bool {
        let buf = fd.byteCode.buf
        let bcLen = fd.byteCode.len
        guard bcLen > 0 else { return false }

        // Build an array of instruction positions and their opcodes.
        var instructions: [(pos: Int, op: JeffJSOpcode, size: Int)] = []
        var pos = 0
        while pos < bcLen {
            guard let op = peekOpcodeAt(pos) else { break }
            let info = jeffJSGetOpcodeInfo(op)
            let instrSize: Int
            if buf[pos] == 0 && pos + 1 < bcLen {
                instrSize = Int(info.size) + 1  // wide opcode
            } else {
                instrSize = Int(info.size)
            }
            if instrSize <= 0 { break }
            instructions.append((pos: pos, op: op, size: instrSize))
            pos += instrSize
        }

        guard !instructions.isEmpty else { return false }

        // Build a reverse map: label index -> instruction index of the label_ opcode
        var labelToInstrIdx: [Int: Int] = [:]
        // Build: label index -> [instruction indices that jump TO this label]
        var labelJumpSources: [Int: [Int]] = [:]

        for (i, instr) in instructions.enumerated() {
            if instr.op == .label_ {
                let opcodeSize = buf[instr.pos] == 0 ? 2 : 1
                let labelIdx = Int(readU32FromBuf(buf, instr.pos + opcodeSize))
                labelToInstrIdx[labelIdx] = i
            } else if instr.op == .goto_ || instr.op == .if_false || instr.op == .if_true
                        || instr.op == .gosub {
                let opcodeSize = buf[instr.pos] == 0 ? 2 : 1
                let labelIdx = Int(readU32FromBuf(buf, instr.pos + opcodeSize))
                labelJumpSources[labelIdx, default: []].append(i)
            }
        }

        let dropOp = JeffJSOpcode.drop
        let nopByte = UInt8(truncatingIfNeeded: JeffJSOpcode.nop.rawValue)
        var found = false

        // Work-list of instruction indices to process as "tail".
        var tailIndices = Set<Int>()
        var worklist = [instructions.count - 1]
        tailIndices.insert(instructions.count - 1)

        while !worklist.isEmpty {
            let i = worklist.removeLast()
            let (ipos, iop, _) = instructions[i]

            if iop == dropOp {
                // Replace this drop with nop
                fd.byteCode.buf[ipos] = nopByte
                found = true
                // Predecessor is also in tail position
                if i > 0 && !tailIndices.contains(i - 1) {
                    tailIndices.insert(i - 1)
                    worklist.append(i - 1)
                }
            } else if isTailTransparentOp(iop) {
                // Predecessor is in tail position
                if i > 0 && !tailIndices.contains(i - 1) {
                    tailIndices.insert(i - 1)
                    worklist.append(i - 1)
                }

                // For jump instructions, follow FORWARD jump targets
                if iop == .goto_ || iop == .if_false || iop == .if_true {
                    let opcodeSize = buf[ipos] == 0 ? 2 : 1
                    let labelIdx = Int(readU32FromBuf(buf, ipos + opcodeSize))
                    if let targetLabelInstrIdx = labelToInstrIdx[labelIdx] {
                        let afterLabelIdx = targetLabelInstrIdx + 1
                        if afterLabelIdx < instructions.count &&
                           afterLabelIdx > i &&  // forward jump only
                           !tailIndices.contains(afterLabelIdx) {
                            tailIndices.insert(afterLabelIdx)
                            worklist.append(afterLabelIdx)
                        }
                    }
                }

                // For label_ opcodes: if this label is a jump target and
                // this label instruction is in tail position, then all
                // instructions that jump HERE are also in tail position
                // (because landing at this label means we're in tail context).
                if iop == .label_ {
                    let opcodeSize = buf[ipos] == 0 ? 2 : 1
                    let labelIdx = Int(readU32FromBuf(buf, ipos + opcodeSize))
                    if let sources = labelJumpSources[labelIdx] {
                        for srcIdx in sources {
                            if !tailIndices.contains(srcIdx) {
                                tailIndices.insert(srcIdx)
                                worklist.append(srcIdx)
                            }
                        }
                    }
                }
            }
            // Any other opcode: not transparent, stop propagating from here
        }

        return found
    }

    /// Returns true if an opcode is "transparent" for tail-position completion
    /// value analysis -- i.e., it doesn't produce or consume the completion value.
    private func isTailTransparentOp(_ op: JeffJSOpcode) -> Bool {
        switch op {
        case .label_, .goto_, .if_false, .if_true,
             .nip_catch, .leave_scope, .enter_scope,
             .gosub, .ret, .return_undef, .return_async, .nop,
             .close_loc, .line_num:
            return true
        default:
            return false
        }
    }

    /// Parse a single source element (statement or declaration).
    func parseSourceElement() {
        guard !shouldAbort else { return }

        emitLineNum()

        // Check for 'async function' before the switch (async is TOK_IDENT)
        if tok == JSTokenType.TOK_IDENT.rawValue && isIdent("async") {
            let peekTok = s.simpleNextToken()
            if peekTok == JSTokenType.TOK_FUNCTION.rawValue {
                parseFunctionDeclaration() // parseFunctionDef handles async internally
                return
            }
        }

        switch tok {
        case JSTokenType.TOK_FUNCTION.rawValue:
            parseFunctionDeclaration()
        case JSTokenType.TOK_CLASS.rawValue:
            parseClassDeclaration()
        case JSTokenType.TOK_IMPORT.rawValue:
            parseImportStatement()
        case JSTokenType.TOK_EXPORT.rawValue:
            parseExportStatement()
        default:
            parseStatement()
        }
    }

    // =========================================================================
    // MARK: - Statement Parsers
    // =========================================================================

    /// Parse a statement. Dispatches to the appropriate sub-parser based on
    /// the current token.
    func parseStatement() {
        guard !shouldAbort else { return }
        guard enterRecursion() else { return }
        defer { leaveRecursion() }

        emitLineNum()

        switch tok {

        case 0x7B: // '{' block
            parseBlockStatement()

        case 0x3B: // ';' empty statement
            next()

        case JSTokenType.TOK_IF.rawValue:
            parseIfStatement()

        case JSTokenType.TOK_WHILE.rawValue:
            parseWhileStatement()

        case JSTokenType.TOK_DO.rawValue:
            parseDoWhileStatement()

        case JSTokenType.TOK_FOR.rawValue:
            parseForStatement()

        case JSTokenType.TOK_SWITCH.rawValue:
            parseSwitchStatement()

        case JSTokenType.TOK_TRY.rawValue:
            parseTryStatement()

        case JSTokenType.TOK_RETURN.rawValue:
            parseReturnStatement()

        case JSTokenType.TOK_THROW.rawValue:
            parseThrowStatement()

        case JSTokenType.TOK_BREAK.rawValue:
            parseBreakStatement()

        case JSTokenType.TOK_CONTINUE.rawValue:
            parseContinueStatement()

        case JSTokenType.TOK_WITH.rawValue:
            parseWithStatement()

        case JSTokenType.TOK_DEBUGGER.rawValue:
            parseDebuggerStatement()

        case JSTokenType.TOK_VAR.rawValue:
            parseVarStatement(isLexical: false, isConst: false)

        case JSTokenType.TOK_LET.rawValue:
            parseVarStatement(isLexical: true, isConst: false)

        case JSTokenType.TOK_CONST.rawValue:
            parseVarStatement(isLexical: true, isConst: true)

        case JSTokenType.TOK_FUNCTION.rawValue:
            parseFunctionDeclaration()

        case JSTokenType.TOK_CLASS.rawValue:
            parseClassDeclaration()

        case JSTokenType.TOK_IDENT.rawValue:
            // Check for 'async function' — async is a contextual keyword.
            // Don't consume 'async' here — parseFunctionDef handles it internally.
            if isIdent("async") &&
               s.simpleNextToken() == JSTokenType.TOK_FUNCTION.rawValue {
                parseFunctionDeclaration()
            }
            // Check for labeled statement: IDENT ':'
            else if s.simpleNextToken() == 0x3A { // ':'
                parseLabeledStatement()
            } else {
                // Expression statement
                parseExpressionStatement()
            }

        default:
            parseExpressionStatement()
        }
    }

    // MARK: Block Statement

    /// Parse a block statement: '{' StatementList '}'
    func parseBlockStatement() {
        expect(0x7B) // '{'
        let scopeIdx = pushScope()

        while tok != 0x7D && tok != JSTokenType.TOK_EOF.rawValue && !shouldAbort {
            parseStatement()
        }

        popScope(scopeIdx)
        expect(0x7D) // '}'
    }

    // MARK: If Statement

    /// Parse: if '(' Expression ')' Statement [else Statement]
    func parseIfStatement() {
        expect(JSTokenType.TOK_IF.rawValue)
        expect(0x28) // '('
        parseExpression()
        expect(0x29) // ')'

        let elseLabel = newLabel()
        emitIfFalse(elseLabel)

        parseStatement()

        if tok == JSTokenType.TOK_ELSE.rawValue {
            let endLabel = newLabel()
            emitGoto(endLabel)
            emitLabel(elseLabel)
            next() // consume 'else'
            parseStatement()
            emitLabel(endLabel)
        } else {
            emitLabel(elseLabel)
        }
    }

    // MARK: While Statement

    /// Parse: while '(' Expression ')' Statement
    func parseWhileStatement() {
        expect(JSTokenType.TOK_WHILE.rawValue)
        expect(0x28) // '('

        let loopLabel = newLabel()
        let breakLabel = newLabel()
        let continueLabel = newLabel()

        emitLabel(continueLabel)
        emitLabel(loopLabel)

        parseExpression()
        expect(0x29) // ')'

        emitIfFalse(breakLabel)

        pushBlockEnv(breakLabel: breakLabel, continueLabel: continueLabel)
        parseStatement()
        popBlockEnv()

        emitGoto(loopLabel)
        emitLabel(breakLabel)
    }

    // MARK: Do-While Statement

    /// Parse: do Statement while '(' Expression ')' ';'
    func parseDoWhileStatement() {
        expect(JSTokenType.TOK_DO.rawValue)

        let loopLabel = newLabel()
        let breakLabel = newLabel()
        let continueLabel = newLabel()

        emitLabel(loopLabel)

        pushBlockEnv(breakLabel: breakLabel, continueLabel: continueLabel)
        parseStatement()
        popBlockEnv()

        expect(JSTokenType.TOK_WHILE.rawValue)
        expect(0x28) // '('

        emitLabel(continueLabel)
        parseExpression()
        expect(0x29) // ')'

        emitIfTrue(loopLabel)
        emitLabel(breakLabel)

        expectSemicolon()
    }

    // MARK: For Statement

    /// Parse: for '(' ... ')' Statement
    /// Handles: for, for-in, for-of
    func parseForStatement() {
        expect(JSTokenType.TOK_FOR.rawValue)

        // Check for 'for await'
        let isAwait = isIdent("await")
        if isAwait {
            next() // consume 'await'
        }

        expect(0x28) // '('

        let scopeIdx = pushScope()
        let loopLabel = newLabel()
        let breakLabel = newLabel()
        let continueLabel = newLabel()

        // Parse the initializer / left-hand side
        if tok == 0x3B { // ';' -- for (;;)
            next()
            parseForClassic(loopLabel: loopLabel, breakLabel: breakLabel,
                            continueLabel: continueLabel, hasInit: false)
        } else if tok == JSTokenType.TOK_VAR.rawValue ||
                  tok == JSTokenType.TOK_LET.rawValue ||
                  tok == JSTokenType.TOK_CONST.rawValue {
            let isConst = tok == JSTokenType.TOK_CONST.rawValue
            let isLexical = tok != JSTokenType.TOK_VAR.rawValue
            next() // consume var/let/const

            // Check for for-in / for-of
            let varName = s.token.identAtom
            if tok == JSTokenType.TOK_IDENT.rawValue {
                let savedPtr = s.bufPtr
                let savedTok = s.token
                let savedLineNum = s.lineNum
                next()

                if tok == JSTokenType.TOK_IN.rawValue {
                    // for (var x in ...)
                    let varIdx = defineVar(varName, isConst: isConst, isLexical: isLexical)
                    next() // consume 'in'
                    parseForIn(varIdx: varIdx, varAtom: varName, scopeLevel: fd.curScope,
                               loopLabel: loopLabel, breakLabel: breakLabel,
                               continueLabel: continueLabel)
                    popScope(scopeIdx)
                    return
                } else if tok == JSTokenType.TOK_OF.rawValue ||
                          isIdent("of") {
                    // for (var x of ...)
                    let varIdx = defineVar(varName, isConst: isConst, isLexical: isLexical)
                    next() // consume 'of'
                    parseForOf(varIdx: varIdx, varAtom: varName, scopeLevel: fd.curScope,
                               loopLabel: loopLabel, breakLabel: breakLabel,
                               continueLabel: continueLabel, isAwait: isAwait)
                    popScope(scopeIdx)
                    return
                }

                // Restore and parse as classic for
                s.bufPtr = savedPtr
                s.token = savedTok
                s.lineNum = savedLineNum
            }

            // Check for destructuring pattern in for-in / for-of:
            // for (var {a, b} of ...) or for (var [a, b] of ...)
            if (tok == 0x7B || tok == 0x5B) && !shouldAbort {
                // Save tokenizer state at the destructuring pattern
                let dSavedBufPtr = s.bufPtr
                let dSavedToken = s.token
                let dSavedLineNum = s.lineNum
                let dSavedTemplateNest = s.templateNestLevel
                let dSavedGotLF = s.gotLF
                let dSavedLastLineNum = s.lastLineNum
                let dSavedLastPtr = s.lastPtr
                let dSavedLastTokenType = s.lastTokenType
                let isObjDestructure = tok == 0x7B

                skipDestructuringPattern()

                if tok == JSTokenType.TOK_IN.rawValue {
                    // for (var {a,b} in obj)
                    next() // consume 'in'
                    parseExpression()
                    expect(0x29) // ')'

                    let rhsBufPtr = s.bufPtr
                    let rhsToken = s.token
                    let rhsLineNum = s.lineNum
                    let rhsTemplateNest = s.templateNestLevel
                    let rhsGotLF = s.gotLF
                    let rhsLastLineNum = s.lastLineNum
                    let rhsLastPtr = s.lastPtr
                    let rhsLastTokenType = s.lastTokenType

                    emitOp(.for_in_start)
                    let doneLabel = newLabel()
                    emitLabel(loopLabel)
                    emitLabel(continueLabel)
                    emitOp(.for_in_next)
                    emitIfTrue(doneLabel)

                    // Rewind and parse destructuring binding
                    s.bufPtr = dSavedBufPtr; s.token = dSavedToken; s.lineNum = dSavedLineNum
                    s.templateNestLevel = dSavedTemplateNest; s.gotLF = dSavedGotLF
                    s.lastLineNum = dSavedLastLineNum; s.lastPtr = dSavedLastPtr
                    s.lastTokenType = dSavedLastTokenType

                    parseDestructuringBinding(kind: .binding, isLexical: isLexical, isConst: isConst)
                    if isObjDestructure { emitOp(.drop) }

                    s.bufPtr = rhsBufPtr; s.token = rhsToken; s.lineNum = rhsLineNum
                    s.templateNestLevel = rhsTemplateNest; s.gotLF = rhsGotLF
                    s.lastLineNum = rhsLastLineNum; s.lastPtr = rhsLastPtr
                    s.lastTokenType = rhsLastTokenType

                    pushBlockEnv(breakLabel: breakLabel, continueLabel: continueLabel, hasIterator: true)
                    parseStatement()
                    popBlockEnv()

                    emitGoto(loopLabel)

                    emitLabel(doneLabel)
                    emitOp(.drop) // drop value
                    emitLabel(breakLabel)
                    emitOp(.drop) // drop iterator

                    popScope(scopeIdx)
                    return
                } else if tok == JSTokenType.TOK_OF.rawValue || isIdent("of") {
                    // for (var {a,b} of arr)
                    next() // consume 'of'
                    parseAssignExpr()
                    expect(0x29) // ')'

                    let rhsBufPtr = s.bufPtr
                    let rhsToken = s.token
                    let rhsLineNum = s.lineNum
                    let rhsTemplateNest = s.templateNestLevel
                    let rhsGotLF = s.gotLF
                    let rhsLastLineNum = s.lastLineNum
                    let rhsLastPtr = s.lastPtr
                    let rhsLastTokenType = s.lastTokenType

                    if isAwait {
                        emitOp(.for_await_of_start)
                    } else {
                        emitOp(.for_of_start)
                    }
                    let doneLabel = newLabel()
                    emitLabel(loopLabel)
                    emitLabel(continueLabel)
                    emitOp(.for_of_next)
                    emitU8(0)
                    emitIfTrue(doneLabel)

                    // Rewind and parse destructuring binding
                    s.bufPtr = dSavedBufPtr; s.token = dSavedToken; s.lineNum = dSavedLineNum
                    s.templateNestLevel = dSavedTemplateNest; s.gotLF = dSavedGotLF
                    s.lastLineNum = dSavedLastLineNum; s.lastPtr = dSavedLastPtr
                    s.lastTokenType = dSavedLastTokenType

                    parseDestructuringBinding(kind: .binding, isLexical: isLexical, isConst: isConst)
                    if isObjDestructure { emitOp(.drop) }

                    s.bufPtr = rhsBufPtr; s.token = rhsToken; s.lineNum = rhsLineNum
                    s.templateNestLevel = rhsTemplateNest; s.gotLF = rhsGotLF
                    s.lastLineNum = rhsLastLineNum; s.lastPtr = rhsLastPtr
                    s.lastTokenType = rhsLastTokenType

                    pushBlockEnv(breakLabel: breakLabel, continueLabel: continueLabel, hasIterator: true)
                    parseStatement()
                    popBlockEnv()

                    emitGoto(loopLabel)

                    emitLabel(doneLabel)
                    emitOp(.drop) // drop value
                    emitLabel(breakLabel)
                    emitOp(.iterator_close) // pops [iter, obj, method]

                    popScope(scopeIdx)
                    return
                }

                // Not in/of — restore and fall through to classic for
                s.bufPtr = dSavedBufPtr; s.token = dSavedToken; s.lineNum = dSavedLineNum
                s.templateNestLevel = dSavedTemplateNest; s.gotLF = dSavedGotLF
                s.lastLineNum = dSavedLastLineNum; s.lastPtr = dSavedLastPtr
                s.lastTokenType = dSavedLastTokenType
            }

            // Classic for with var declaration
            parseVarDeclarationList(isLexical: isLexical, isConst: isConst)
            expect(0x3B) // ';'
            parseForClassic(loopLabel: loopLabel, breakLabel: breakLabel,
                            continueLabel: continueLabel, hasInit: true,
                            loopScopeIdx: isLexical ? scopeIdx : -1,
                            isLexical: isLexical)
        } else {
            // Expression initializer -- check for for-in / for-of.
            // Save the identifier atom in case this is `for (ident in/of ...)`
            // so we can emit the correct assignment inside the loop.
            let forLhsAtom: JSAtom = (tok == JSTokenType.TOK_IDENT.rawValue) ? s.token.identAtom : 0

            // Disable the `in` operator so `for(x in obj)` is parsed as
            // for-in, not as `for((x in obj); ...)`.
            let savedInFlag = inFlag
            inFlag = false
            parseExpression()
            inFlag = savedInFlag

            if tok == JSTokenType.TOK_IN.rawValue {
                // for (expr in ...)
                // Drop the expression VALUE (we need assignment target, not value)
                emitOp(.drop)
                next()
                parseForIn(varIdx: -1, varAtom: forLhsAtom, scopeLevel: fd.curScope,
                           loopLabel: loopLabel, breakLabel: breakLabel,
                           continueLabel: continueLabel)
                popScope(scopeIdx)
                return
            } else if tok == JSTokenType.TOK_OF.rawValue || isIdent("of") {
                // for (expr of ...)
                emitOp(.drop)
                next()
                parseForOf(varIdx: -1, varAtom: forLhsAtom, scopeLevel: fd.curScope,
                           loopLabel: loopLabel, breakLabel: breakLabel,
                           continueLabel: continueLabel, isAwait: isAwait)
                popScope(scopeIdx)
                return
            }

            emitOp(.drop)
            expect(0x3B) // ';'
            parseForClassic(loopLabel: loopLabel, breakLabel: breakLabel,
                            continueLabel: continueLabel, hasInit: true)
        }

        popScope(scopeIdx)
    }

    /// Parse the remainder of a classic for(init; cond; update) body.
    private func parseForClassic(loopLabel: Int, breakLabel: Int,
                                  continueLabel: Int, hasInit: Bool,
                                  loopScopeIdx: Int = -1, isLexical: Bool = false) {
        // Condition
        emitLabel(loopLabel)
        if tok != 0x3B {
            parseExpression()
            emitIfFalse(breakLabel)
        }
        expect(0x3B) // ';'

        // Update expression -- we jump past it on first iteration
        let updateLabel = newLabel()
        emitGoto(updateLabel) // skip update on first pass -- NO: jump to body

        emitLabel(continueLabel)
        // Per-iteration let scope: emit close_loc for lexical variables
        // BEFORE the update expression. This detaches any closures created
        // in the body so they capture the current iteration's value.
        if isLexical && loopScopeIdx >= 0 && loopScopeIdx < fd.scopes.count {
            var varIdx = fd.scopes[loopScopeIdx].first
            while varIdx >= 0 && varIdx < fd.vars.count {
                let v = fd.vars[varIdx]
                if v.isLexical {
                    emitOp(.close_loc)
                    emitU16(UInt16(varIdx))
                }
                varIdx = v.scopeNext
            }
        }
        if tok != 0x29 { // ')'
            parseExpression()
            emitOp(.drop)
        }
        emitGoto(loopLabel)

        // Body
        emitLabel(updateLabel)
        expect(0x29) // ')'

        pushBlockEnv(breakLabel: breakLabel, continueLabel: continueLabel)
        parseStatement()
        popBlockEnv()

        emitGoto(continueLabel)
        emitLabel(breakLabel)
    }

    /// Parse for-in loop body.
    private func parseForIn(varIdx: Int, varAtom: JSAtom, scopeLevel: Int,
                            loopLabel: Int, breakLabel: Int, continueLabel: Int) {
        // Evaluate the right-hand side
        parseExpression()
        expect(0x29) // ')'

        // Push iterator
        emitOp(.for_in_start)

        // Separate label for the "done" exit path so we can drop the
        // extra value that for_in_next pushed (the body-break path doesn't
        // have this extra value).
        let doneLabel = newLabel()

        emitLabel(loopLabel)
        emitLabel(continueLabel)

        // Get next key: for_in_next peeks the iterator and pushes [value, done].
        // Stack after: [iter, value, done]
        emitOp(.for_in_next)
        emitIfTrue(doneLabel) // done flag is true => exit via doneLabel
        // Stack here (not done): [iter, value]

        // Assign to the variable
        if varIdx >= 0 {
            emitScopePutVarInit(varAtom, scopeLevel: scopeLevel)
        } else if varAtom != 0 {
            // Pre-declared variable: assign the key to it
            emitScopePutVar(varAtom, scopeLevel: scopeLevel)
        } else {
            // Complex LHS expression (a.b, a[0]) — not yet supported, drop
            emitOp(.drop)
        }
        // Stack here: [iter]

        pushBlockEnv(breakLabel: breakLabel, continueLabel: continueLabel, hasIterator: true)
        parseStatement()
        popBlockEnv()

        emitGoto(loopLabel)

        // Done exit: for_in_next pushed [value, done]. if_true popped done,
        // leaving [iter, value]. Drop the value so stack matches break path.
        emitLabel(doneLabel)
        emitOp(.drop) // drop value, stack: [iter]

        // break from inside the body jumps here with [iter] on stack.
        emitLabel(breakLabel)
        emitOp(.drop) // drop iterator
    }

    /// Parse for-of loop body.
    private func parseForOf(varIdx: Int, varAtom: JSAtom, scopeLevel: Int,
                            loopLabel: Int, breakLabel: Int, continueLabel: Int,
                            isAwait: Bool) {
        // Evaluate the right-hand side
        parseAssignExpr()
        expect(0x29) // ')'

        // Push iterator
        if isAwait {
            emitOp(.for_await_of_start)
        } else {
            emitOp(.for_of_start)
        }

        // Separate label for the "done" exit path so we can drop the
        // extra value that for_of_next pushed (the body-break path doesn't
        // have this extra value).
        let doneLabel = newLabel()

        emitLabel(loopLabel)
        emitLabel(continueLabel)

        // Get next value: for_of_next extracts {value, done} from the
        // iterator result and pushes [iter, obj, method, value, done].
        emitOp(.for_of_next)
        emitU8(0) // flags
        emitIfTrue(doneLabel) // done flag => exit via doneLabel

        // Assign to the variable
        if varIdx >= 0 {
            emitScopePutVarInit(varAtom, scopeLevel: scopeLevel)
        } else if varAtom != 0 {
            emitScopePutVar(varAtom, scopeLevel: scopeLevel)
        } else {
            emitOp(.drop)
        }

        pushBlockEnv(breakLabel: breakLabel, continueLabel: continueLabel, hasIterator: true)
        parseStatement()
        popBlockEnv()

        emitGoto(loopLabel)

        // Done exit: for_of_next pushed [iter, obj, method, value, done].
        // if_true popped done, leaving [iter, obj, method, value].
        // Drop the value so the stack matches what iterator_close expects.
        emitLabel(doneLabel)
        emitOp(.drop)

        // break from inside the body jumps here with [iter, obj, method].
        emitLabel(breakLabel)

        // Close iterator: pops [iter, obj, method].
        emitOp(.iterator_close)
    }

    // MARK: Switch Statement

    /// Parse: switch '(' Expression ')' '{' CaseClause* '}'
    func parseSwitchStatement() {
        expect(JSTokenType.TOK_SWITCH.rawValue)
        expect(0x28) // '('
        parseExpression()
        expect(0x29) // ')'
        expect(0x7B) // '{'

        let breakLabel = newLabel()
        let scopeIdx = pushScope()
        pushBlockEnv(breakLabel: breakLabel, continueLabel: -1)

        // Interleaved single-pass switch compilation with fall-through support.
        //
        // For each case clause, the bytecode layout is:
        //   [comparison]: dup, expr, strict_eq, if_true(bodyEntry)
        //   goto(skip)        -- skip body during comparison chain
        //   bodyEntry: drop   -- drop switch_val (entered via match)
        //   [fallThrough:]    -- fall-through from previous body lands here
        //   [body statements]
        //   [goto(nextFT)]    -- fall-through to next body (if no break)
        //   skip:             -- comparison chain resumes
        //
        // After all clauses:
        //   goto(defaultEntry) or drop + goto(break)
        //   break:

        var skipLabel = -1          // skips past current body in comparison chain
        var fallThroughLabel = -1   // connects previous body to current body
        var defaultEntryLabel = -1  // entry to default body (includes drop)
        var hadBody = false         // tracks whether we're mid-body

        while tok != 0x7D && tok != JSTokenType.TOK_EOF.rawValue && !shouldAbort {
            if tok == JSTokenType.TOK_CASE.rawValue {
                // Close previous body: emit fall-through goto
                if hadBody {
                    fallThroughLabel = newLabel()
                    emitGoto(fallThroughLabel)
                    hadBody = false
                }

                // Resume comparison chain (emit previous skip label)
                if skipLabel >= 0 {
                    emitLabel(skipLabel)
                    skipLabel = -1
                }

                // Emit case comparison
                next() // consume 'case'
                emitOp(.dup)
                parseExpression()
                expect(0x3A) // ':'
                emitOp(.strict_eq)

                let bodyEntryLabel = newLabel()
                emitIfTrue(bodyEntryLabel)

                // Skip body if comparison didn't match
                skipLabel = newLabel()
                emitGoto(skipLabel)

                // Body entry via match: drop switch_val
                emitLabel(bodyEntryLabel)
                emitOp(.drop)

                // Fall-through entry from previous body (skips the drop)
                if fallThroughLabel >= 0 {
                    emitLabel(fallThroughLabel)
                    fallThroughLabel = -1
                }

                hadBody = true

            } else if tok == JSTokenType.TOK_DEFAULT.rawValue {
                // Close previous body
                if hadBody {
                    fallThroughLabel = newLabel()
                    emitGoto(fallThroughLabel)
                    hadBody = false
                }

                if skipLabel >= 0 {
                    emitLabel(skipLabel)
                    skipLabel = -1
                }

                next() // consume 'default'
                expect(0x3A) // ':'

                // Skip default body during comparison chain
                skipLabel = newLabel()
                emitGoto(skipLabel)

                // Default body entry (via goto from end of comparison chain)
                defaultEntryLabel = newLabel()
                emitLabel(defaultEntryLabel)
                emitOp(.drop) // drop switch_val

                // Fall-through from previous body
                if fallThroughLabel >= 0 {
                    emitLabel(fallThroughLabel)
                    fallThroughLabel = -1
                }

                hadBody = true

            } else {
                // Body statement
                parseStatement()
            }
        }

        // End of last body: ensure it doesn't fall into comparison chain epilogue
        if hadBody {
            emitGoto(breakLabel)
        }

        // Emit last skip label (comparison chain end)
        if skipLabel >= 0 {
            emitLabel(skipLabel)
            skipLabel = -1
        }

        // No case matched: goto default or break
        if defaultEntryLabel >= 0 {
            emitGoto(defaultEntryLabel)
        } else {
            emitOp(.drop) // drop switch_val
            emitGoto(breakLabel)
        }

        popBlockEnv()
        popScope(scopeIdx)
        expect(0x7D) // '}'

        emitLabel(breakLabel)
        // switch_val already dropped in all paths; no drop here
    }

    // MARK: Try Statement

    /// Parse: try Block [catch Block] [finally Block]
    func parseTryStatement() {
        expect(JSTokenType.TOK_TRY.rawValue)

        let catchLabel = newLabel()
        let finallyLabel = newLabel()
        let endLabel = newLabel()

        let hasCatch = s.simpleNextToken() == JSTokenType.TOK_CATCH.rawValue ||
                       tok == 0x7B  // look ahead past the try block

        // Emit catch handler
        emitCatch(catchLabel)

        // Push finally scope so return/break/continue inside the try body
        // emit gosub to the finally block. We always create the label; if
        // there's no finally clause, we emit a no-op finally (just ret).
        finallyScopes.append(FinallyScope(label: finallyLabel, needsNipCatch: true))

        // Parse try block
        parseBlockStatement()

        finallyScopes.removeLast()

        emitOp(.nip_catch) // remove catch handler

        // Check for finally
        let hasFinally = tok == JSTokenType.TOK_FINALLY.rawValue

        emitGosub(finallyLabel) // always gosub (might be no-op if no finally)
        emitGoto(endLabel)

        // Parse catch clause
        emitLabel(catchLabel)
        if tok == JSTokenType.TOK_CATCH.rawValue {
            next() // consume 'catch'

            let scopeIdx = pushScope()

            if tok == 0x28 { // '(' -- catch parameter
                next()
                if tok == JSTokenType.TOK_IDENT.rawValue {
                    let catchVarName = s.token.identAtom
                    let varIdx = defineVar(catchVarName, isConst: false, isLexical: true,
                                           varKind: JSVarKindEnum.JS_VAR_CATCH.rawValue)
                    next() // consume identifier
                    // Store the caught exception into the catch variable
                    emitOp(.put_loc)
                    emitU16(UInt16(varIdx))
                } else if tok == 0x7B || tok == 0x5B { // destructuring
                    parseDestructuringBinding(kind: .binding)
                } else {
                    syntaxError("expected catch parameter")
                }
                expect(0x29) // ')'
            } else {
                // catch without parameter (ES2019) -- the exception value is
                // on the stack from the catch handler; drop it so the stack
                // stays balanced.
                emitOp(.drop)
            }

            // Push finally scope for catch body (no nip_catch needed —
            // catch handler already consumed by the catch dispatch)
            finallyScopes.append(FinallyScope(label: finallyLabel, needsNipCatch: false))
            parseBlockStatement()
            finallyScopes.removeLast()
            popScope(scopeIdx)

            emitGosub(finallyLabel)
            emitGoto(endLabel)
        }

        // Parse finally clause (or emit no-op finally if none)
        if tok == JSTokenType.TOK_FINALLY.rawValue {
            next() // consume 'finally'
            emitLabel(finallyLabel)
            parseBlockStatement()
            emitOp(.ret) // return from gosub
        } else {
            // No finally clause — emit a no-op finally so gosub has a target
            emitLabel(finallyLabel)
            emitOp(.ret)
        }

        emitLabel(endLabel)
    }

    // MARK: Return Statement

    /// Parse: return [Expression] ';'
    ///
    /// For async functions, emits `return_async` instead of `return_` / `return_undef`.
    /// The `return_async` opcode tells the interpreter to return the value to
    /// callFunction, which wraps it in Promise.resolve().
    func parseReturnStatement() {
        expect(JSTokenType.TOK_RETURN.rawValue)

        let isAsync = fd.funcKind == JSFunctionKindEnum.JS_FUNC_ASYNC.rawValue ||
                      fd.funcKind == JSFunctionKindEnum.JS_FUNC_ASYNC_GENERATOR.rawValue

        if tok == 0x3B || tok == 0x7D || tok == JSTokenType.TOK_EOF.rawValue || s.gotLF {
            // return; (no value)
            if !finallyScopes.isEmpty {
                // Inside try-finally: push undefined as return value, then
                // gosub to each enclosing finally, then return.
                emitOp(.undefined)
                emitFinallyGosubs()
                emitOp(isAsync ? .return_async : .return_)
            } else if isAsync {
                emitOp(.undefined)
                emitOp(.return_async)
            } else {
                emitOp(.return_undef)
            }
        } else {
            parseExpression()
            if !finallyScopes.isEmpty {
                // Inside try-finally: return value is on stack,
                // gosub to each enclosing finally, then return.
                emitFinallyGosubs()
            }
            emitOp(isAsync ? .return_async : .return_)
        }

        expectSemicolon()
    }

    /// Emit nip_catch + gosub for each enclosing finally scope (innermost first).
    /// Called before return_ when inside try-finally blocks.
    private func emitFinallyGosubs() {
        // Process innermost scope first (top of stack).
        // Each scope may need nip_catch (if inside try body with catch handler on stack).
        for scope in finallyScopes.reversed() {
            if scope.needsNipCatch {
                emitOp(.nip_catch)
            }
            emitGosub(scope.label)
        }
    }

    // MARK: Throw Statement

    /// Parse: throw Expression ';'
    func parseThrowStatement() {
        expect(JSTokenType.TOK_THROW.rawValue)

        if s.gotLF {
            syntaxError("no newline allowed after 'throw'")
            return
        }

        parseExpression()
        emitOp(.throw_)
        expectSemicolon()
    }

    // MARK: Break Statement

    /// Parse: break [Identifier] ';'
    func parseBreakStatement() {
        expect(JSTokenType.TOK_BREAK.rawValue)

        var labelName: JSAtom = 0
        if !s.gotLF && tok == JSTokenType.TOK_IDENT.rawValue {
            labelName = s.token.identAtom
            next()
        }

        let label = findBreakLabel(labelName)
        if label < 0 {
            if labelName != 0 {
                syntaxError("undefined label")
            } else {
                syntaxError("break must be inside loop or switch")
            }
            return
        }

        emitGoto(label)
        expectSemicolon()
    }

    // MARK: Continue Statement

    /// Parse: continue [Identifier] ';'
    func parseContinueStatement() {
        expect(JSTokenType.TOK_CONTINUE.rawValue)

        var labelName: JSAtom = 0
        if !s.gotLF && tok == JSTokenType.TOK_IDENT.rawValue {
            labelName = s.token.identAtom
            next()
        }

        let label = findContinueLabel(labelName)
        if label < 0 {
            if labelName != 0 {
                syntaxError("undefined label")
            } else {
                syntaxError("continue must be inside loop")
            }
            return
        }

        emitGoto(label)
        expectSemicolon()
    }

    // MARK: With Statement

    /// Parse: with '(' Expression ')' Statement
    func parseWithStatement() {
        expect(JSTokenType.TOK_WITH.rawValue)

        if fd.jsMode & JS_MODE_STRICT != 0 {
            syntaxError("'with' is not allowed in strict mode")
            return
        }

        expect(0x28) // '('
        parseExpression()
        expect(0x29) // ')'

        emitOp(.to_object)

        let scopeIdx = pushScope()
        // The with object is stored as a special variable that the scope_*
        // opcodes check against
        let withVarIdx = defineVar(getAtom("*with*"), varKind: JSVarDefEnum.JS_VAR_DEF_WITH.rawValue)
        _ = withVarIdx

        parseStatement()

        popScope(scopeIdx)
        emitOp(.drop) // drop the with object
    }

    // MARK: Debugger Statement

    /// Parse: debugger ';'
    func parseDebuggerStatement() {
        expect(JSTokenType.TOK_DEBUGGER.rawValue)
        // Emit a NOP -- the debugger opcode is not implemented in the VM
        emitOp(.nop)
        expectSemicolon()
    }

    // MARK: Labeled Statement

    /// Parse: Identifier ':' Statement
    func parseLabeledStatement() {
        let labelName = s.token.identAtom
        next() // consume identifier
        expect(0x3A) // ':'

        let breakLabel = newLabel()
        pushBlockEnv(breakLabel: breakLabel, continueLabel: -1, labelName: labelName)
        parseStatement()
        popBlockEnv()
        emitLabel(breakLabel)
    }

    // MARK: Expression Statement

    /// Parse: Expression ';'
    func parseExpressionStatement() {
        parseExpression()
        emitOp(.drop)
        expectSemicolon()
    }

    // MARK: Var/Let/Const Declaration

    /// Parse: var/let/const VariableDeclarationList ';'
    func parseVarStatement(isLexical: Bool, isConst: Bool) {
        next() // consume var/let/const

        parseVarDeclarationList(isLexical: isLexical, isConst: isConst)
        expectSemicolon()
    }

    /// Parse a comma-separated list of variable declarations.
    func parseVarDeclarationList(isLexical: Bool, isConst: Bool) {
        repeat {
            parseVarDeclaration(isLexical: isLexical, isConst: isConst)
        } while tok == 0x2C && (next() != false)  // ','
    }

    /// Parse a single variable declaration: Identifier ['=' AssignmentExpression]
    /// or destructuring pattern.
    func parseVarDeclaration(isLexical: Bool, isConst: Bool) {
        if tok == 0x7B || tok == 0x5B { // '{' or '['
            // Destructuring: var [a, b] = expr  or  var {x, y} = expr
            //
            // The destructuring helpers assume the RHS value is already on the
            // stack, so we use a two-pass approach:
            //   Pass 1 – skip the pattern, parse '= expr' (emits RHS bytecode)
            //   Pass 2 – rewind and parse the destructuring pattern (emits binding bytecode)
            //   Then restore the token position to just after the RHS expression.

            // Save the full tokenizer position before the destructuring pattern.
            let savedBufPtr1 = s.bufPtr
            let savedToken1 = s.token
            let savedLineNum1 = s.lineNum
            let savedTemplateNest1 = s.templateNestLevel
            let savedGotLF1 = s.gotLF
            let savedLastLineNum1 = s.lastLineNum
            let savedLastPtr1 = s.lastPtr
            let savedLastTokenType1 = s.lastTokenType

            // Pass 1: skip the pattern to reach '=', then parse the RHS.
            skipDestructuringPattern()

            guard tok == 0x3D else { // '='
                syntaxError("destructuring declaration must have an initializer")
                return
            }
            next() // consume '='
            parseAssignExpr() // pushes the RHS value onto the stack

            // Save position after the RHS so we can jump back here later.
            let savedBufPtr2 = s.bufPtr
            let savedToken2 = s.token
            let savedLineNum2 = s.lineNum
            let savedTemplateNest2 = s.templateNestLevel
            let savedGotLF2 = s.gotLF
            let savedLastLineNum2 = s.lastLineNum
            let savedLastPtr2 = s.lastPtr
            let savedLastTokenType2 = s.lastTokenType

            // Pass 2: rewind to the pattern and emit destructuring bytecode.
            s.bufPtr = savedBufPtr1
            s.token = savedToken1
            s.lineNum = savedLineNum1
            s.templateNestLevel = savedTemplateNest1
            s.gotLF = savedGotLF1
            s.lastLineNum = savedLastLineNum1
            s.lastPtr = savedLastPtr1
            s.lastTokenType = savedLastTokenType1

            parseDestructuringBinding(kind: .binding, isLexical: isLexical, isConst: isConst)

            // Restore the token position to after the RHS expression so the
            // caller continues parsing from the correct point (e.g. at ';').
            s.bufPtr = savedBufPtr2
            s.token = savedToken2
            s.lineNum = savedLineNum2
            s.templateNestLevel = savedTemplateNest2
            s.gotLF = savedGotLF2
            s.lastLineNum = savedLastLineNum2
            s.lastPtr = savedLastPtr2
            s.lastTokenType = savedLastTokenType2

            return
        }

        // Accept identifiers and contextual keywords (of, get, set, let, etc.)
        // as variable names. Common in minified JS: var of='x', var in=1, etc.
        let varName: JSAtom
        if tok == JSTokenType.TOK_IDENT.rawValue {
            varName = s.token.identAtom
        } else if isKeywordToken(tok) {
            let kwName = keywordTokenName(tok)
            varName = getAtom(kwName)
        } else {
            syntaxError("expected identifier in variable declaration")
            return
        }
        next() // consume identifier

        // Top-level `var` in global eval: hoist to global object so the variable
        // is accessible from any scope (Promise reaction jobs, async callbacks,
        // other eval calls). `let`/`const` remain block-scoped.
        let isGlobalVar = !isLexical && fd.parent == nil

        if isGlobalVar {
            // Emit define_var to create the property on the global object.
            // Do NOT also create a local variable — that would create two copies
            // where closures capture the local but assignments go to global.
            // Per ES spec, `var` declarations are hoisted — the variable must
            // exist (as undefined) from the start of the script. Record the
            // atom so parseProgram inserts define_var at position 0.
            if !fd.hoistedGlobalVarAtoms.contains(varName) {
                fd.hoistedGlobalVarAtoms.append(varName)
            }
            emitOp(.define_var)
            emitAtom(varName)
            emitU8(UInt8(JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE))

            if tok == 0x3D { // '='
                next() // consume '='
                parseAssignExpr()
                emitOp(.put_var_init)
                emitAtom(varName)
            }
            // No initializer: variable is already undefined on global object
        } else {
            let varIdx = defineVar(varName, isConst: isConst, isLexical: isLexical)

            if tok == 0x3D { // '='
                next() // consume '='
                parseAssignExpr()

                if isLexical {
                    emitOp(.put_loc_check_init)
                    emitU16(UInt16(varIdx))
                } else {
                    emitScopePutVarInit(varName, scopeLevel: fd.curScope)
                }
            } else {
                // No initializer
                if isConst {
                    syntaxError("const declarations must be initialized")
                    return
                }
                // For lexical variables (let), the TDZ is lifted at the
                // declaration point.  Emit an explicit initialization to
                // undefined so get_loc_check no longer throws.
                if isLexical {
                    emitOp(.undefined)
                    emitOp(.put_loc_check_init)
                    emitU16(UInt16(varIdx))
                }
            }
        }
    }

    // =========================================================================
    // MARK: - Function Declaration
    // =========================================================================

    /// Parse: function [*] Identifier '(' FormalParameters ')' '{' FunctionBody '}'
    func parseFunctionDeclaration() {
        parseFunctionDef(isExpression: false, isArrow: false)
    }

    /// Parse a function definition (declaration or expression).
    func parseFunctionDef(isExpression: Bool, isArrow: Bool) {
        var isGenerator = false
        var isAsync = false

        if !isArrow {
            // Check for 'async'. For function declarations, newlines before
            // 'async' are allowed (the caller already verified async+function).
            // The !gotLF restriction only applies to expression contexts.
            if isIdent("async") {
                let nextTok = s.simpleNextToken()
                if nextTok == JSTokenType.TOK_FUNCTION.rawValue ||
                   (!s.gotLF && nextTok == JSTokenType.TOK_IDENT.rawValue) {
                    isAsync = true
                    next() // consume 'async'
                }
            }

            if tok == JSTokenType.TOK_FUNCTION.rawValue {
                next() // consume 'function'
            }

            // Check for generator *
            if tok == 0x2A { // '*'
                isGenerator = true
                next()
            }
        }

        // Parse function name (optional for expressions, required for declarations).
        // Keywords like 'of', 'get', 'set', 'let', 'static', 'async', 'yield' are
        // valid as function names in non-strict mode (common in minified JS).
        var funcName: JSAtom = 0
        if tok == JSTokenType.TOK_IDENT.rawValue {
            funcName = s.token.identAtom
            next()
        } else if isKeywordToken(tok) {
            let kwName = keywordTokenName(tok)
            funcName = getAtom(kwName)
            next()
        } else if !isExpression && !isArrow {
            syntaxError("expected function name")
            return
        }

        // Create a new child function definition
        let childFd = JeffJSFunctionDefCompiler()
        childFd.parent = fd
        childFd.definedScopeLevel = fd.curScope
        childFd.filename = fd.filename  // inherit parent's filename for debug info
        childFd.funcName = funcName
        childFd.funcKind = isGenerator
            ? (isAsync ? JSFunctionKindEnum.JS_FUNC_ASYNC_GENERATOR.rawValue
                       : JSFunctionKindEnum.JS_FUNC_GENERATOR.rawValue)
            : (isAsync ? JSFunctionKindEnum.JS_FUNC_ASYNC.rawValue
                       : JSFunctionKindEnum.JS_FUNC_NORMAL.rawValue)
        if fd.jsMode & JS_MODE_STRICT != 0 {
            childFd.jsMode = JS_MODE_STRICT
        }
        if isArrow {
            childFd.isArrow = true
            childFd.argumentsAllowed = false
        }
        fd.childFunctions.append(childFd)

        // For named function expressions, add a const self-reference variable
        // so the function name is accessible inside the body (ES spec §15.2.4).
        // Not marked as isLexical to avoid TDZ (set_loc_uninitialized) since
        // the interpreter initializes it at function entry.
        if isExpression && funcName != 0 && !isArrow {
            var vd = JeffJSVarDef()
            vd.varName = funcName
            vd.scopeLevel = 0
            vd.scopeNext = childFd.scopes[0].first
            vd.isConst = true
            vd.isLexical = false
            let idx = childFd.vars.count
            childFd.vars.append(vd)
            childFd.scopes[0].first = idx
            childFd.funcNameVarIdx = idx
        }

        if isArrow {
            // Arrow function: parameters are already parsed
            parseArrowFunctionBody(childFd: childFd, isAsync: isAsync)
        } else {
            // Regular function
            expect(0x28) // '('
            let (defaults, rest, dstructs) = parseFormalParameters(childFd: childFd)
            expect(0x29) // ')'
            expect(0x7B) // '{'
            parseFunctionBody(childFd: childFd, defaults: defaults, rest: rest, destructs: dstructs)
            expect(0x7D) // '}'
        }

        // Emit closure creation in parent
        let cpoolIdx = addConstPoolValue(.mkVal(tag: .undefined, val: 0))
        emitFClosure(cpoolIdx)

        if !isExpression && funcName != 0 {
            if fd.parent == nil {
                // Top-level function declaration in global eval: hoist to global object
                // via define_func so it's accessible from any scope (e.g., Promise
                // reaction jobs, async callbacks, other eval calls).
                // The fclosure was emitted just before (5 bytes). Record start position.
                let fclosureStart = fd.byteCode.len - 5
                emitOp(.define_func)
                emitAtom(funcName)
                emitU8(0) // defineGlobalFunc adds WRITABLE|CONFIGURABLE
                // Per ES spec, function declarations are hoisted to the top of the
                // script/function body. Record the byte range (fclosure + define_func)
                // so the compiler moves it to bodyBytecodeStart.
                fd.hoistedFuncDeclRanges.append((fclosureStart, fd.byteCode.len))
            } else {
                // Function declaration inside a function: define as local variable.
                // Mark byte range for hoisting (moved to body start before label resolution).
                let hoistStart = fd.byteCode.len
                let varIdx = defineVar(funcName,
                                       varKind: JSVarKindEnum.JS_VAR_FUNCTION_DECL.rawValue)
                emitScopePutVarInit(funcName, scopeLevel: fd.curScope)
                _ = varIdx
                // The fclosure was emitted just before this block (at line 2351-2352).
                // Save the range from fclosure through scope_put_var_init for hoisting.
                let fclosureStart = hoistStart - 5 // fclosure opcode is 1 + 4 bytes
                fd.hoistedFuncDeclRanges.append((fclosureStart, fd.byteCode.len))
            }
        }
    }

    /// Parse formal parameter list into the child function def.
    /// Returns information about default parameters, rest parameter, and
    /// destructuring parameters for use by parseFunctionBody.
    func parseFormalParameters(childFd: JeffJSFunctionDefCompiler)
        -> (defaults: [JeffJSSavedDefaultParam], rest: JeffJSRestParamInfo?,
            destructs: [JeffJSSavedDestructParam]) {
        var paramCount = 0
        var savedDefaults: [JeffJSSavedDefaultParam] = []
        var restParam: JeffJSRestParamInfo? = nil
        var savedDestructs: [JeffJSSavedDestructParam] = []

        while tok != 0x29 && tok != JSTokenType.TOK_EOF.rawValue && !shouldAbort { // ')'
            if tok == JSTokenType.TOK_ELLIPSIS.rawValue {
                // Rest parameter
                next()
                if tok == JSTokenType.TOK_IDENT.rawValue {
                    let paramName = s.token.identAtom
                    next()
                    var arg = JeffJSVarDef()
                    arg.varName = paramName
                    childFd.args.append(arg)
                    childFd.hasSimpleParameterList = false
                    restParam = JeffJSRestParamInfo(argIndex: paramCount, paramName: paramName)
                }
                break // rest must be last
            }

            if tok == 0x7B || tok == 0x5B {
                // Destructuring parameter: save tokenizer state so parseFunctionBody
                // can replay the pattern and emit destructuring bindings.
                childFd.hasSimpleParameterList = false

                // Save state BEFORE the '{' or '[' pattern
                var saved = JeffJSSavedDestructParam(
                    argIndex: paramCount,
                    bufPtr: s.bufPtr,
                    lineNum: s.lineNum,
                    token: s.token,
                    gotLF: s.gotLF,
                    lastLineNum: s.lastLineNum,
                    lastPtr: s.lastPtr,
                    templateNestLevel: s.templateNestLevel
                )

                // Record a positional arg (anonymous -- no user-visible name)
                var arg = JeffJSVarDef()
                arg.varName = 0
                childFd.args.append(arg)

                // Skip the destructuring pattern
                skipDestructuringPattern()

                // Also skip a default value if present: ({x, y} = {x: 1, y: 2})
                if tok == 0x3D { // '='
                    next()
                    skipExpression()
                }

                // Save end position
                saved.endBufPtr = s.bufPtr
                saved.endLineNum = s.lineNum
                saved.endToken = s.token
                saved.endGotLF = s.gotLF
                saved.endLastLineNum = s.lastLineNum
                saved.endLastPtr = s.lastPtr
                saved.endTemplateNestLevel = s.templateNestLevel

                savedDestructs.append(saved)
            } else if tok == JSTokenType.TOK_IDENT.rawValue {
                let paramName = s.token.identAtom
                next()

                var arg = JeffJSVarDef()
                arg.varName = paramName
                childFd.args.append(arg)

                // Default value -- save tokenizer position for replay in function body
                if tok == 0x3D { // '='
                    next()
                    childFd.hasSimpleParameterList = false

                    // Save state AFTER consuming '=', before the default expression
                    var saved = JeffJSSavedDefaultParam(
                        argIndex: paramCount,
                        paramName: paramName,
                        bufPtr: s.bufPtr,
                        lineNum: s.lineNum,
                        token: s.token,
                        gotLF: s.gotLF,
                        lastLineNum: s.lastLineNum,
                        lastPtr: s.lastPtr,
                        templateNestLevel: s.templateNestLevel
                    )

                    // Skip default expression
                    skipExpression()

                    // Save end position
                    saved.endBufPtr = s.bufPtr
                    saved.endLineNum = s.lineNum
                    saved.endToken = s.token
                    saved.endGotLF = s.gotLF
                    saved.endLastLineNum = s.lastLineNum
                    saved.endLastPtr = s.lastPtr
                    saved.endTemplateNestLevel = s.templateNestLevel

                    savedDefaults.append(saved)
                }
            } else {
                syntaxError("expected parameter name")
                return (savedDefaults, restParam, savedDestructs)
            }

            paramCount += 1
            if tok == 0x2C { // ','
                next()
            }
        }

        childFd.argCount = paramCount
        return (savedDefaults, restParam, savedDestructs)
    }

    /// Parse the body of a function (between { }).
    func parseFunctionBody(childFd: JeffJSFunctionDefCompiler,
                           defaults: [JeffJSSavedDefaultParam] = [],
                           rest: JeffJSRestParamInfo? = nil,
                           destructs: [JeffJSSavedDestructParam] = []) {
        let savedFd = fd
        let savedInFlag_ = inFlag
        let savedFinallyScopes = finallyScopes
        finallyScopes = []  // nested function has its own scope — don't leak outer try-finally
        inFlag = true // FunctionBody always uses [+In] per ECMAScript spec
        fd = childFd

        // Check for "use strict" directive
        if tok == JSTokenType.TOK_STRING.rawValue && s.token.strValue == "use strict" {
            fd.jsMode |= JS_MODE_STRICT
            next()
            expectSemicolon()
        }

        // -- Emit default parameter initialization --
        // For each parameter with a default value, check if the argument is
        // undefined and if so evaluate the default expression and store it
        // back into the argument slot.
        for dflt in defaults {
            let endLabel = newLabel()
            // get_arg pushes the argument value
            emitOp(.get_arg)
            emitU16(UInt16(dflt.argIndex))
            // Check if it's undefined
            emitOp(.undefined)
            emitOp(.strict_eq)
            emitIfFalse(endLabel) // if not undefined, skip default

            // Save current tokenizer state
            let curBufPtr = s.bufPtr
            let curLineNum = s.lineNum
            let curToken = s.token
            let curGotLF = s.gotLF
            let curLastLineNum = s.lastLineNum
            let curLastPtr = s.lastPtr
            let curTemplateNest = s.templateNestLevel

            // Rewind to the saved default expression position
            s.bufPtr = dflt.bufPtr
            s.lineNum = dflt.lineNum
            s.token = dflt.token
            s.gotLF = dflt.gotLF
            s.lastLineNum = dflt.lastLineNum
            s.lastPtr = dflt.lastPtr
            s.templateNestLevel = dflt.templateNestLevel

            // Parse the default expression (emits bytecode into childFd)
            parseAssignExpr()

            // Store into the argument slot
            emitOp(.put_arg)
            emitU16(UInt16(dflt.argIndex))

            // Restore tokenizer to body position
            s.bufPtr = curBufPtr
            s.lineNum = curLineNum
            s.token = curToken
            s.gotLF = curGotLF
            s.lastLineNum = curLastLineNum
            s.lastPtr = curLastPtr
            s.templateNestLevel = curTemplateNest

            emitLabel(endLabel)
        }

        // -- Emit rest parameter collection --
        // rest(argIndex) creates an array from arguments starting at argIndex
        // and pushes it onto the stack. We then define a local variable for it.
        if let restInfo = rest {
            emitOp(.rest)
            emitU16(UInt16(restInfo.argIndex))
            let varIdx = defineVar(restInfo.paramName)
            emitScopePutVarInit(restInfo.paramName, scopeLevel: fd.curScope)
            _ = varIdx
        }

        // -- Emit destructuring parameter bindings --
        // For each parameter that was a destructuring pattern ({x, y} or [a, b]),
        // push the argument value and replay the pattern to create local bindings.
        for dp in destructs {
            // Push the argument value onto the stack (the RHS for destructuring)
            emitOp(.get_arg)
            emitU16(UInt16(dp.argIndex))

            // Save current tokenizer state
            let curBufPtr = s.bufPtr
            let curLineNum = s.lineNum
            let curToken = s.token
            let curGotLF = s.gotLF
            let curLastLineNum = s.lastLineNum
            let curLastPtr = s.lastPtr
            let curTemplateNest = s.templateNestLevel

            // Rewind to the saved destructuring pattern position
            s.bufPtr = dp.bufPtr
            s.lineNum = dp.lineNum
            s.token = dp.token
            s.gotLF = dp.gotLF
            s.lastLineNum = dp.lastLineNum
            s.lastPtr = dp.lastPtr
            s.templateNestLevel = dp.templateNestLevel

            // Parse the destructuring pattern — this emits binding code that
            // pulls properties/elements from the value on the stack
            parseDestructuringBinding(kind: .binding)

            // Restore tokenizer to body position
            s.bufPtr = curBufPtr
            s.lineNum = curLineNum
            s.token = curToken
            s.gotLF = curGotLF
            s.lastLineNum = curLastLineNum
            s.lastPtr = curLastPtr
            s.templateNestLevel = curTemplateNest
        }

        // -- Define `arguments` object for non-arrow functions --
        // Non-arrow functions should have an `arguments` variable that
        // provides access to all passed arguments.
        if fd.argumentsAllowed {
            let argumentsAtom = JSPredefinedAtom.arguments_.rawValue
            fd.hasArguments = true
            let argVarIdx = defineVar(argumentsAtom)
            // special_object(1) = mapped arguments object
            emitOp(.special_object)
            emitU8(1) // mappedArguments
            emitScopePutVarInit(argumentsAtom, scopeLevel: fd.curScope)
            _ = argVarIdx
        }

        // Mark body start for function declaration hoisting
        fd.bodyBytecodeStart = fd.byteCode.len

        while tok != 0x7D && tok != JSTokenType.TOK_EOF.rawValue && !shouldAbort {
            parseSourceElement()
        }

        // Implicit return undefined — use return_async for async functions
        let fnIsAsync = fd.funcKind == JSFunctionKindEnum.JS_FUNC_ASYNC.rawValue ||
                        fd.funcKind == JSFunctionKindEnum.JS_FUNC_ASYNC_GENERATOR.rawValue
        if fnIsAsync {
            emitOp(.undefined)
            emitOp(.return_async)
        } else {
            emitOp(.return_undef)
        }

        fd = savedFd
        inFlag = savedInFlag_
        finallyScopes = savedFinallyScopes
    }

    /// Parse an arrow function body (concise or block).
    func parseArrowFunctionBody(childFd: JeffJSFunctionDefCompiler, isAsync: Bool,
                                defaults: [JeffJSSavedDefaultParam] = [],
                                rest: JeffJSRestParamInfo? = nil,
                                destructs: [JeffJSSavedDestructParam] = []) {
        let savedFd = fd
        let savedInFlagArrow = inFlag
        let savedFinallyScopesArrow = finallyScopes
        finallyScopes = []  // nested function has its own scope
        inFlag = true // Default params always use [+In]
        fd = childFd

        // -- Emit default parameter initialization --
        for dflt in defaults {
            let endLabel = newLabel()
            emitOp(.get_arg)
            emitU16(UInt16(dflt.argIndex))
            emitOp(.undefined)
            emitOp(.strict_eq)
            emitIfFalse(endLabel)

            // Save current tokenizer state
            let curBufPtr = s.bufPtr
            let curLineNum = s.lineNum
            let curToken = s.token
            let curGotLF = s.gotLF
            let curLastLineNum = s.lastLineNum
            let curLastPtr = s.lastPtr
            let curTemplateNest = s.templateNestLevel

            // Rewind to the saved default expression position
            s.bufPtr = dflt.bufPtr
            s.lineNum = dflt.lineNum
            s.token = dflt.token
            s.gotLF = dflt.gotLF
            s.lastLineNum = dflt.lastLineNum
            s.lastPtr = dflt.lastPtr
            s.templateNestLevel = dflt.templateNestLevel

            parseAssignExpr()

            emitOp(.put_arg)
            emitU16(UInt16(dflt.argIndex))

            // Restore tokenizer to body position
            s.bufPtr = curBufPtr
            s.lineNum = curLineNum
            s.token = curToken
            s.gotLF = curGotLF
            s.lastLineNum = curLastLineNum
            s.lastPtr = curLastPtr
            s.templateNestLevel = curTemplateNest

            emitLabel(endLabel)
        }

        // -- Emit rest parameter collection --
        if let restInfo = rest {
            emitOp(.rest)
            emitU16(UInt16(restInfo.argIndex))
            let varIdx = defineVar(restInfo.paramName)
            emitScopePutVarInit(restInfo.paramName, scopeLevel: fd.curScope)
            _ = varIdx
        }

        // -- Emit destructuring parameter bindings --
        for dp in destructs {
            emitOp(.get_arg)
            emitU16(UInt16(dp.argIndex))

            let curBufPtr = s.bufPtr
            let curLineNum = s.lineNum
            let curToken = s.token
            let curGotLF = s.gotLF
            let curLastLineNum = s.lastLineNum
            let curLastPtr = s.lastPtr
            let curTemplateNest = s.templateNestLevel

            s.bufPtr = dp.bufPtr
            s.lineNum = dp.lineNum
            s.token = dp.token
            s.gotLF = dp.gotLF
            s.lastLineNum = dp.lastLineNum
            s.lastPtr = dp.lastPtr
            s.templateNestLevel = dp.templateNestLevel

            parseDestructuringBinding(kind: .binding)

            s.bufPtr = curBufPtr
            s.lineNum = curLineNum
            s.token = curToken
            s.gotLF = curGotLF
            s.lastLineNum = curLastLineNum
            s.lastPtr = curLastPtr
            s.templateNestLevel = curTemplateNest
        }

        if tok == 0x7B { // '{' -- block body
            next()
            while tok != 0x7D && tok != JSTokenType.TOK_EOF.rawValue && !shouldAbort {
                parseSourceElement()
            }
            if isAsync {
                emitOp(.undefined)
                emitOp(.return_async)
            } else {
                emitOp(.return_undef)
            }
            expect(0x7D)
        } else {
            // Concise body -- single expression (arrow function)
            // Arrow concise bodies use [?In] — inherit from parent context
            inFlag = savedInFlagArrow
            parseAssignExpr()
            emitOp(isAsync ? .return_async : .return_)
        }

        fd = savedFd
        inFlag = savedInFlagArrow
        finallyScopes = savedFinallyScopesArrow
    }

    /// Skip a destructuring pattern without emitting bytecode (for parameters).
    func skipDestructuringPattern() {
        var depth = 0
        repeat {
            if tok == 0x7B || tok == 0x5B { depth += 1 }
            if tok == 0x7D || tok == 0x5D { depth -= 1 }
            next()
        } while depth > 0 && tok != JSTokenType.TOK_EOF.rawValue && !shouldAbort
    }

    /// Skip an expression without emitting bytecode (for default parameter values).
    func skipExpression() {
        var depth = 0
        while tok != JSTokenType.TOK_EOF.rawValue && !shouldAbort {
            if tok == 0x28 || tok == 0x5B || tok == 0x7B { depth += 1 }
            if tok == 0x29 || tok == 0x5D || tok == 0x7D {
                if depth == 0 { break }
                depth -= 1
            }
            if depth == 0 && tok == 0x2C { break } // ','
            next()
        }
    }

    // =========================================================================
    // MARK: - Class Declaration
    // =========================================================================

    /// Parse: class Identifier [extends Expression] ClassBody
    func parseClassDeclaration() {
        parseClassDef(isExpression: false)
    }

    /// Parse a class definition (declaration or expression).
    func parseClassDef(isExpression: Bool) {
        expect(JSTokenType.TOK_CLASS.rawValue)

        var className: JSAtom = 0
        if tok == JSTokenType.TOK_IDENT.rawValue {
            className = s.token.identAtom
            next()
        } else if !isExpression {
            syntaxError("expected class name")
            return
        }

        // Heritage clause
        var hasExtends = false
        if tok == JSTokenType.TOK_EXTENDS.rawValue {
            hasExtends = true
            next()
            parseAssignExpr() // superclass expression -- pushes it on stack
        }

        // Class body
        expect(0x7B) // '{'
        let scopeIdx = pushScope()

        // Create a default constructor first.  If parseClassBody finds an
        // explicit constructor it will replace this one on the stack.
        do {
            let defaultCtorFd = JeffJSFunctionDefCompiler()
            defaultCtorFd.parent = fd
            defaultCtorFd.funcName = className
            defaultCtorFd.newTargetAllowed = true
            if hasExtends {
                defaultCtorFd.isDerivedClassConstructor = true
                defaultCtorFd.superCallAllowed = true
            }
            fd.childFunctions.append(defaultCtorFd)

            let savedFd = fd
            fd = defaultCtorFd
            emitOp(.return_undef)
            fd = savedFd

            let cpoolIdx = addConstPoolValue(.mkVal(tag: .undefined, val: 0))
            emitFClosure(cpoolIdx)
        }

        // Build prototype object.
        // For extends: stack has superclass; build proto with
        //              proto.__proto__ = superclass.prototype.
        //              Keep superclass below ctor+proto for later __proto__ setup.
        // For no extends: build a plain object as proto.
        if hasExtends {
            // Stack: ..., superclass, ctorFunc
            emitOp(.swap)                            // ..., ctorFunc, superclass
            emitOp(.dup)                             // ..., ctorFunc, superclass, superclass
            emitGetField(getAtom("prototype"))       // ..., ctorFunc, superclass, superclass.prototype
            emitOp(.object)                          // ..., ctorFunc, superclass, superclass.prototype, proto
            emitOp(.swap)                            // ..., ctorFunc, superclass, proto, superclass.prototype
            emitOp(.set_proto)                       // ..., ctorFunc, superclass, proto
            //                                          (proto.__proto__ = superclass.prototype)
            // Move superclass below ctorFunc.
            emitOp(.rot3l)                           // ..., superclass, proto, ctorFunc
            emitOp(.swap)                            // ..., superclass, ctorFunc, proto
        } else {
            // Stack: ..., ctorFunc
            emitOp(.object)                          // ..., ctorFunc, proto
        }

        // Stack (extends): ..., superclass, ctorFunc, proto
        // Stack (base):    ..., ctorFunc, proto
        //
        // parseClassBody always has ctorFunc below proto.  If an explicit
        // constructor is found, it replaces the default ctorFunc in place.
        parseClassBody(className: className, hasExtends: hasExtends)

        // Stack (extends): ..., superclass, ctorFunc, proto
        // Stack (base):    ..., ctorFunc, proto

        // Wire up ctorFunc.prototype = proto
        emitOp(.dup2)                                // ..., [sc,] ctorFunc, proto, ctorFunc, proto
        emitPutField(getAtom("prototype"))           // ..., [sc,] ctorFunc, proto   (ctorFunc.prototype = proto)

        // Wire up proto.constructor = ctorFunc
        emitOp(.dup2)                                // ..., [sc,] ctorFunc, proto, ctorFunc, proto
        emitOp(.swap)                                // ..., [sc,] ctorFunc, proto, proto, ctorFunc
        emitPutField(getAtom("constructor"))         // ..., [sc,] ctorFunc, proto   (proto.constructor = ctorFunc)

        // Set the constructor's name
        if className != 0 {
            emitOp(.swap)                            // ..., [sc,] proto, ctorFunc
            emitOp(.set_name)
            emitAtom(className)                      // ..., [sc,] proto, ctorFunc   (ctorFunc.name = className)
            emitOp(.swap)                            // ..., [sc,] ctorFunc, proto
        }

        // Drop proto, keep ctorFunc
        emitOp(.drop)                                // ..., [sc,] ctorFunc

        if hasExtends {
            // Set ctorFunc.__proto__ = superclass (for super() and static inheritance)
            // Stack: ..., superclass, ctorFunc
            emitOp(.swap)                            // ..., ctorFunc, superclass
            emitOp(.set_proto)                       // ..., ctorFunc   (ctorFunc.__proto__ = superclass)
        }

        popScope(scopeIdx)
        expect(0x7D) // '}'

        if !isExpression && className != 0 {
            let varIdx = defineVar(className, isConst: true, isLexical: true)
            emitScopePutVarInit(className, scopeLevel: fd.curScope)
            _ = varIdx
        }
    }

    /// Parse the body of a class (between { }).
    /// On entry the stack has: ..., [superclass,] ctorFunc, proto.
    /// ctorFunc is the default constructor created by parseClassDef.
    /// If an explicit constructor method is found, it replaces ctorFunc.
    /// On exit the stack is: ..., [superclass,] ctorFunc, proto.
    @discardableResult
    func parseClassBody(className: JSAtom, hasExtends: Bool) -> Bool {
        let constructorAtom = getAtom("constructor")
        var ctorFound = false

        while tok != 0x7D && tok != JSTokenType.TOK_EOF.rawValue && !shouldAbort {
            if tok == 0x3B { // ';' -- empty member
                next()
                continue
            }

            var isStatic = false
            var isComputed = false
            var isAsync = false
            var isGenerator = false
            var propKind: PropertyKind = .method

            // Check for 'static'
            if tok == JSTokenType.TOK_STATIC.rawValue {
                isStatic = true
                next()
            }

            // Check for 'async' — [no LineTerminator here] between async and method name
            if isIdent("async") {
                let nextTok = s.simpleNextToken()
                if nextTok != 0x28 && nextTok != 0x3D && // not method() or =
                   nextTok != 0x3B && nextTok != 0x7D {  // not ; or }
                    let savedBufPtr = s.bufPtr
                    let savedLineNum = s.lineNum
                    let savedToken = s.token
                    let savedGotLF = s.gotLF
                    let savedLastLineNum = s.lastLineNum
                    let savedLastPtr = s.lastPtr
                    let savedTemplateNest = s.templateNestLevel
                    let savedLastTokenType = s.lastTokenType

                    next() // consume 'async'
                    if !s.gotLF {
                        isAsync = true
                    } else {
                        // LF between async and method name — backtrack
                        s.bufPtr = savedBufPtr
                        s.lineNum = savedLineNum
                        s.token = savedToken
                        s.gotLF = savedGotLF
                        s.lastLineNum = savedLastLineNum
                        s.lastPtr = savedLastPtr
                        s.templateNestLevel = savedTemplateNest
                        s.lastTokenType = savedLastTokenType
                    }
                }
            }

            // Check for generator '*'
            if tok == 0x2A { // '*'
                isGenerator = true
                next()
            }

            // Check for getter/setter
            if isIdent("get") && !isGenerator && !isAsync {
                let nextTok = s.simpleNextToken()
                if nextTok != 0x28 { // not get()
                    propKind = .getter
                    next()
                }
            } else if isIdent("set") && !isGenerator && !isAsync {
                let nextTok = s.simpleNextToken()
                if nextTok != 0x28 { // not set()
                    propKind = .setter
                    next()
                }
            }

            // Parse property name
            var propAtom: JSAtom = 0
            if tok == 0x5B { // '[' computed property
                isComputed = true
                next()
                parseAssignExpr()
                expect(0x5D) // ']'
                emitOp(.to_propkey)
            } else if tok == JSTokenType.TOK_IDENT.rawValue ||
                      tok == JSTokenType.TOK_STRING.rawValue {
                if tok == JSTokenType.TOK_IDENT.rawValue {
                    propAtom = s.token.identAtom
                } else {
                    propAtom = getAtom(s.token.strValue)
                }
                next()
            } else if tok == JSTokenType.TOK_NUMBER.rawValue {
                propAtom = getAtom(String(format: "%.0f", s.token.numValue))
                next()
            } else if tok == JSTokenType.TOK_PRIVATE_NAME.rawValue {
                propAtom = s.token.identAtom
                next()
            } else if isKeywordToken(tok) {
                // Keywords are valid as method/property names in classes
                let kwName = keywordTokenName(tok)
                propAtom = getAtom(kwName)
                next()
            } else {
                syntaxError("expected property name")
                return ctorFound
            }

            // Check for field (no parentheses after name)
            if tok != 0x28 && propKind == .method { // not a method
                // Class field
                if tok == 0x3D { // '=' initializer
                    next()
                    parseAssignExpr()
                } else {
                    emitOp(.undefined)
                }
                if isComputed {
                    emitOp(.define_array_el)
                } else {
                    emitDefineField(propAtom)
                }
                expectSemicolon()
                continue
            }

            // Detect whether this is the class constructor
            let isConstructor = !isStatic && !isComputed && propAtom == constructorAtom && propKind == .method

            // Parse method
            expect(0x28) // '('

            let methodFd = JeffJSFunctionDefCompiler()
            methodFd.parent = fd
            methodFd.funcName = propAtom
            if isGenerator {
                methodFd.funcKind = isAsync
                    ? JSFunctionKindEnum.JS_FUNC_ASYNC_GENERATOR.rawValue
                    : JSFunctionKindEnum.JS_FUNC_GENERATOR.rawValue
            } else if isAsync {
                methodFd.funcKind = JSFunctionKindEnum.JS_FUNC_ASYNC.rawValue
            }
            if isConstructor {
                methodFd.newTargetAllowed = true
                methodFd.funcName = className
                if hasExtends {
                    methodFd.isDerivedClassConstructor = true
                    methodFd.superCallAllowed = true
                }
            }
            fd.childFunctions.append(methodFd)

            let (mDefaults, mRest, mDstructs) = parseFormalParameters(childFd: methodFd)
            expect(0x29) // ')'
            expect(0x7B) // '{'
            parseFunctionBody(childFd: methodFd, defaults: mDefaults, rest: mRest, destructs: mDstructs)
            expect(0x7D) // '}'

            let cpoolIdx = addConstPoolValue(.mkVal(tag: .undefined, val: 0))
            emitFClosure(cpoolIdx)

            if isConstructor {
                // Replace the current ctorFunc (default or previous) with
                // the explicit constructor.
                // Stack: ..., ctorFunc, proto, newCtorFunc
                emitOp(.rot3l)   // ..., proto, newCtorFunc, ctorFunc
                emitOp(.drop)    // ..., proto, newCtorFunc
                emitOp(.swap)    // ..., newCtorFunc, proto
                ctorFound = true
            } else {
                // Regular method -- define it on proto (or ctor for static).
                if isStatic {
                    // For static methods, define on the constructor.
                    // Stack: ..., ctorFunc, proto, methodFunc
                    // Rearrange so ctorFunc is below methodFunc for define_method.
                    emitOp(.rot3l)   // ..., proto, methodFunc, ctorFunc
                    emitOp(.swap)    // ..., proto, ctorFunc, methodFunc
                    if isComputed {
                        emitOp(.define_method_computed)
                        let mf: UInt8 = (propKind == .getter ? 2 : 0) |
                                        (propKind == .setter ? 4 : 0)
                        emitU8(mf)
                    } else {
                        emitOp(.define_method)
                        emitAtom(propAtom)
                        let mf: UInt8 = (propKind == .getter ? 2 : 0) |
                                        (propKind == .setter ? 4 : 0)
                        emitU8(mf)
                    }
                    // Stack: ..., proto, ctorFunc
                    emitOp(.swap)    // ..., ctorFunc, proto
                } else if isComputed {
                    emitOp(.define_method_computed)
                    let methodFlags: UInt8 = (propKind == .getter ? 2 : 0) |
                                             (propKind == .setter ? 4 : 0)
                    emitU8(methodFlags)
                } else {
                    emitOp(.define_method)
                    emitAtom(propAtom)
                    let methodFlags: UInt8 = (propKind == .getter ? 2 : 0) |
                                             (propKind == .setter ? 4 : 0)
                    emitU8(methodFlags)
                }
            }
        }
        return ctorFound
    }

    // =========================================================================
    // MARK: - Import Statement
    // =========================================================================

    /// Parse: import ImportClause FromClause ';'
    ///     or import ModuleSpecifier ';'
    func parseImportStatement() {
        expect(JSTokenType.TOK_IMPORT.rawValue)

        // import "module" -- side-effect only
        if tok == JSTokenType.TOK_STRING.rawValue {
            let moduleName = s.token.strValue
            next()
            _ = moduleName
            expectSemicolon()
            return
        }

        // import(expr) -- dynamic import expression
        if tok == 0x28 { // '('
            // Re-parse as expression statement
            emitOp(.undefined) // this
            next() // consume '('
            parseAssignExpr()
            expect(0x29) // ')'
            emitOp(.import_)
            emitU8(0)
            emitOp(.drop)
            expectSemicolon()
            return
        }

        // import defaultExport from "module"
        // import { named } from "module"
        // import * as ns from "module"
        // import defaultExport, { named } from "module"

        var hasDefault = false
        if tok == JSTokenType.TOK_IDENT.rawValue {
            // Default import
            let importName = s.token.identAtom
            next()
            hasDefault = true
            let varIdx = defineVar(importName, isConst: true, isLexical: true)
            _ = varIdx

            if tok == 0x2C { // ','
                next()
            }
        }

        if tok == 0x2A { // '*' -- namespace import
            next()
            if isIdent("as") {
                next()
                if tok == JSTokenType.TOK_IDENT.rawValue {
                    let nsName = s.token.identAtom
                    next()
                    let varIdx = defineVar(nsName, isConst: true, isLexical: true)
                    _ = varIdx
                } else {
                    syntaxError("expected identifier after 'as'")
                }
            } else {
                syntaxError("expected 'as' after '*'")
            }
        } else if tok == 0x7B { // '{' named imports
            next()
            while tok != 0x7D && tok != JSTokenType.TOK_EOF.rawValue && !shouldAbort {
                var importedName: JSAtom = 0
                var localName: JSAtom = 0

                // Import specifier names can be identifiers OR keywords
                // (e.g., `import { default as foo }` is valid ES2020+)
                if tok == JSTokenType.TOK_IDENT.rawValue || tok >= JSTokenType.TOK_NULL.rawValue {
                    if tok == JSTokenType.TOK_IDENT.rawValue {
                        importedName = s.token.identAtom
                    } else {
                        importedName = getAtom(keywordTokenName(tok) ?? "default")
                    }
                    localName = importedName
                    next()
                } else if tok == JSTokenType.TOK_STRING.rawValue {
                    importedName = getAtom(s.token.strValue)
                    localName = importedName
                    next()
                } else {
                    syntaxError("expected import name")
                    return
                }

                if isIdent("as") {
                    next()
                    if tok == JSTokenType.TOK_IDENT.rawValue {
                        localName = s.token.identAtom
                        next()
                    } else {
                        syntaxError("expected identifier after 'as'")
                        return
                    }
                }

                let varIdx = defineVar(localName, isConst: true, isLexical: true)
                _ = varIdx
                _ = importedName

                if tok == 0x2C { // ','
                    next()
                } else {
                    break
                }
            }
            expect(0x7D) // '}'
        }

        // from clause
        if isIdent("from") || (hasDefault && tok == JSTokenType.TOK_IDENT.rawValue) {
            if isIdent("from") { next() }
            if tok == JSTokenType.TOK_STRING.rawValue {
                let moduleSpecifier = s.token.strValue
                _ = moduleSpecifier
                next()
            } else {
                syntaxError("expected module specifier string")
            }
        }

        expectSemicolon()
    }

    // =========================================================================
    // MARK: - Export Statement
    // =========================================================================

    /// Parse export statement.
    func parseExportStatement() {
        expect(JSTokenType.TOK_EXPORT.rawValue)

        if tok == JSTokenType.TOK_DEFAULT.rawValue {
            // export default Expression
            next()
            if tok == JSTokenType.TOK_FUNCTION.rawValue {
                parseFunctionDef(isExpression: false, isArrow: false)
            } else if tok == JSTokenType.TOK_CLASS.rawValue {
                parseClassDef(isExpression: false)
            } else {
                parseAssignExpr()
                expectSemicolon()
            }
            // Store as default export
            return
        }

        if tok == 0x2A { // '*'
            // export * from "module"
            next()
            if isIdent("as") {
                next() // consume 'as'
                next() // consume name
            }
            if isIdent("from") {
                next()
                if tok == JSTokenType.TOK_STRING.rawValue {
                    next() // consume module specifier
                }
            }
            expectSemicolon()
            return
        }

        if tok == 0x7B { // '{' named exports
            next()
            while tok != 0x7D && tok != JSTokenType.TOK_EOF.rawValue && !shouldAbort {
                // Export specifier names can be identifiers OR keywords
                // (e.g., `export { default } from "..."` is valid ES2020+)
                if tok == JSTokenType.TOK_IDENT.rawValue || tok >= JSTokenType.TOK_NULL.rawValue {
                    next()
                    if isIdent("as") {
                        next() // consume 'as'
                        next() // consume exported name
                    }
                }
                if tok == 0x2C { next() } else { break }
            }
            expect(0x7D) // '}'
            if isIdent("from") {
                next()
                if tok == JSTokenType.TOK_STRING.rawValue {
                    next()
                }
            }
            expectSemicolon()
            return
        }

        // export var/let/const/function/class
        if tok == JSTokenType.TOK_VAR.rawValue ||
           tok == JSTokenType.TOK_LET.rawValue ||
           tok == JSTokenType.TOK_CONST.rawValue {
            let isConst = tok == JSTokenType.TOK_CONST.rawValue
            let isLexical = tok != JSTokenType.TOK_VAR.rawValue
            parseVarStatement(isLexical: isLexical, isConst: isConst)
        } else if tok == JSTokenType.TOK_FUNCTION.rawValue {
            parseFunctionDeclaration()
        } else if tok == JSTokenType.TOK_CLASS.rawValue {
            parseClassDeclaration()
        } else {
            syntaxError("unexpected token in export")
        }
    }

    // =========================================================================
    // MARK: - Expression Parsers (by precedence, lowest to highest)
    // =========================================================================

    /// Parse a full expression (comma operator).
    /// Expression: AssignmentExpression (',' AssignmentExpression)*
    func parseExpression() {
        parseAssignExpr()

        while tok == 0x2C && !shouldAbort { // ','
            next()
            emitOp(.drop) // discard left value
            parseAssignExpr()
        }
    }

    /// Parse an assignment expression.
    /// AssignExpr: ConditionalExpr
    ///           | LeftHandSide AssignOp AssignExpr
    ///           | ArrowFunction
    ///           | yield Expression
    ///           | async ArrowFunction
    func parseAssignExpr() {
        guard enterRecursion() else { return }
        defer { leaveRecursion() }

        // Check for yield
        if tok == JSTokenType.TOK_YIELD.rawValue {
            parseYieldExpression()
            return
        }

        // ---- Arrow function early detection: IDENT '=>' ----
        // Check BEFORE parsing as a ternary/binary expression so that the
        // identifier is NOT emitted as a scope_get_var. This is the spec-
        // compliant location for ArrowFunction (AssignmentExpression).
        if tok == JSTokenType.TOK_IDENT.rawValue && !s.gotLF {
            let peeked = s.simpleNextToken()
            if peeked == JSTokenType.TOK_ARROW.rawValue {
                let atom = s.token.identAtom
                next() // consume identifier
                next() // consume '=>'
                emitArrowFunction(paramAtoms: [atom], isAsync: false)
                return
            }
        }

        // ---- Async arrow function early detection ----
        // async () => ..., async (a, b) => ..., async x => ...
        // Note: the spec's [no LineTerminator here] is between 'async' and the
        // parameter list, NOT before 'async'. We check s.gotLF AFTER consuming
        // 'async' to correctly detect the line terminator position.
        if tok == JSTokenType.TOK_IDENT.rawValue && isIdent("async") {
            let peekTok = s.simpleNextToken()
            if peekTok == 0x28 { // '(' — could be async arrow
                let savedBc = fd.byteCode.len
                let savedBufPtr = s.bufPtr
                let savedLineNum = s.lineNum
                let savedToken = s.token
                let savedGotLF = s.gotLF
                let savedLastLineNum = s.lastLineNum
                let savedLastPtr = s.lastPtr
                let savedTemplateNest = s.templateNestLevel
                let savedLastTokenType = s.lastTokenType

                next() // consume 'async'
                // [no LineTerminator here] between async and (
                if !s.gotLF {
                    next() // consume '('
                    if tok == 0x29 { // ')' — async () =>
                        next()
                        if tok == JSTokenType.TOK_ARROW.rawValue {
                            next()
                            emitArrowFunction(paramAtoms: [], isAsync: true)
                            return
                        }
                    } else if let arrowParams = scanParenArrowParams() {
                        let (dflts, rst) = consumeParenArrowParams(arrowParams)
                        emitArrowFunction(paramAtoms: arrowParams.map { $0.atom }, isAsync: true,
                                          defaults: dflts, rest: rst)
                        return
                    }
                }
                // Not an async arrow — restore state fully
                fd.byteCode.len = savedBc
                s.bufPtr = savedBufPtr
                s.lineNum = savedLineNum
                s.token = savedToken
                s.gotLF = savedGotLF
                s.lastLineNum = savedLastLineNum
                s.lastPtr = savedLastPtr
                s.templateNestLevel = savedTemplateNest
                s.lastTokenType = savedLastTokenType
            } else if peekTok == JSTokenType.TOK_IDENT.rawValue {
                // async x => ...
                let savedBc = fd.byteCode.len
                let savedBufPtr = s.bufPtr
                let savedLineNum = s.lineNum
                let savedToken = s.token
                let savedGotLF = s.gotLF
                let savedLastLineNum = s.lastLineNum
                let savedLastPtr = s.lastPtr
                let savedTemplateNest = s.templateNestLevel
                let savedLastTokenType = s.lastTokenType

                next() // consume 'async'
                // [no LineTerminator here] between async and param
                if !s.gotLF {
                    let paramAtom = s.token.identAtom
                    next() // consume param name
                    if tok == JSTokenType.TOK_ARROW.rawValue {
                        next()
                        emitArrowFunction(paramAtoms: [paramAtom], isAsync: true)
                        return
                    }
                }
                // Not arrow — restore state fully
                fd.byteCode.len = savedBc
                s.bufPtr = savedBufPtr
                s.lineNum = savedLineNum
                s.token = savedToken
                s.gotLF = savedGotLF
                s.lastLineNum = savedLastLineNum
                s.lastPtr = savedLastPtr
                s.templateNestLevel = savedTemplateNest
                s.lastTokenType = savedLastTokenType
            }
        }

        // ---- Arrow function early detection: '(' params ')' '=>' ----
        // Also check for parenthesized arrow params before parsing as
        // an expression. Uses the same lookahead scanner as parsePrimaryExpr.
        if tok == 0x28 { // '('
            let parenResult = scanFullArrowFromParen()
            if let params = parenResult {
                // Confirmed arrow: consume '(' then params then ')' then '=>'
                let hasDestructuring = params.contains(where: { $0.atom == 0 })
                next() // consume '('
                if params.isEmpty {
                    // () => ...
                    expect(0x29) // ')'
                    expect(JSTokenType.TOK_ARROW.rawValue)
                    emitArrowFunction(paramAtoms: [], isAsync: false)
                } else if hasDestructuring {
                    // Use parseFormalParameters to handle destructuring patterns
                    let arrowFd = JeffJSFunctionDefCompiler()
                    arrowFd.parent = fd
                    arrowFd.isArrow = true
                    arrowFd.argumentsAllowed = false
                    if fd.jsMode & JS_MODE_STRICT != 0 {
                        arrowFd.jsMode = JS_MODE_STRICT
                    }
                    let (adflts, arst, adstructs) = parseFormalParameters(childFd: arrowFd)
                    expect(0x29) // ')'
                    expect(JSTokenType.TOK_ARROW.rawValue)
                    fd.childFunctions.append(arrowFd)
                    parseArrowFunctionBody(childFd: arrowFd, isAsync: false,
                                           defaults: adflts, rest: arst, destructs: adstructs)
                    let cpoolIdx = addConstPoolValue(.mkVal(tag: .undefined, val: 0))
                    emitFClosure(cpoolIdx)
                } else {
                    let (dflts, rst) = consumeParenArrowParams(params)
                    emitArrowFunction(paramAtoms: params.map { $0.atom }, isAsync: false,
                                      defaults: dflts, rest: rst)
                }
                return
            }
        }

        // Save bytecode position before parsing LHS — we may need to rewrite
        // the last emitted GET into a PUT for assignment.
        let lhsBcStart = fd.byteCode.len

        // Save tokenizer state before LHS — needed to rewind if LHS turns out
        // to be a destructuring assignment pattern ([a,b] = ... or {a,b} = ...).
        let lhsTokIsBracketOrBrace = (tok == 0x5B || tok == 0x7B)
        let savedLhsBufPtr = s.bufPtr
        let savedLhsLineNum = s.lineNum
        let savedLhsToken = s.token
        let savedLhsGotLF = s.gotLF
        let savedLhsLastLineNum = s.lastLineNum
        let savedLhsLastPtr = s.lastPtr
        let savedLhsTemplateNest = s.templateNestLevel
        let savedLhsLastTokenType = s.lastTokenType
        let savedLhsChildCount = fd.childFunctions.count

        parseTernaryExpr()
        guard !shouldAbort else { return }

        // Check for assignment operator
        if let assignOp = getAssignOp(tok) {
            next() // consume the operator

            if assignOp == .plain {
                // Check for destructuring assignment: [a, b] = expr or {a, b} = expr
                // The LHS was parsed as an array/object literal. Detect this by
                // checking if the first opcode is .object (array literal sentinel).
                if lhsTokIsBracketOrBrace {
                    let firstLhsOp = peekOpcodeAt(lhsBcStart)
                    if firstLhsOp == .object || firstLhsOp == .dup {
                        // Rewind bytecode and tokenizer to re-parse as destructuring.
                        fd.byteCode.len = lhsBcStart
                        if fd.childFunctions.count > savedLhsChildCount {
                            fd.childFunctions.removeSubrange(savedLhsChildCount...)
                        }

                        // Save tokenizer at the '=' position (already consumed)
                        let eqBufPtr = s.bufPtr
                        let eqLineNum = s.lineNum
                        let eqToken = s.token
                        let eqGotLF = s.gotLF
                        let eqLastLineNum = s.lastLineNum
                        let eqLastPtr = s.lastPtr
                        let eqTemplateNest = s.templateNestLevel
                        let eqLastTokenType = s.lastTokenType

                        // First parse the RHS (we need its value on the stack
                        // before the destructuring pattern consumes it).
                        parseAssignExpr()

                        // Save position after RHS
                        let afterRhsBufPtr = s.bufPtr
                        let afterRhsLineNum = s.lineNum
                        let afterRhsToken = s.token
                        let afterRhsGotLF = s.gotLF
                        let afterRhsLastLineNum = s.lastLineNum
                        let afterRhsLastPtr = s.lastPtr
                        let afterRhsTemplateNest = s.templateNestLevel
                        let afterRhsLastTokenType = s.lastTokenType

                        // Rewind to the LHS pattern
                        s.bufPtr = savedLhsBufPtr
                        s.lineNum = savedLhsLineNum
                        s.token = savedLhsToken
                        s.gotLF = savedLhsGotLF
                        s.lastLineNum = savedLhsLastLineNum
                        s.lastPtr = savedLhsLastPtr
                        s.templateNestLevel = savedLhsTemplateNest
                        s.lastTokenType = savedLhsLastTokenType

                        // Parse the destructuring pattern in assignment mode
                        parseDestructuringBinding(kind: .assignment)

                        // Restore to after RHS
                        s.bufPtr = afterRhsBufPtr
                        s.lineNum = afterRhsLineNum
                        s.token = afterRhsToken
                        s.gotLF = afterRhsGotLF
                        s.lastLineNum = afterRhsLastLineNum
                        s.lastPtr = afterRhsLastPtr
                        s.templateNestLevel = afterRhsTemplateNest
                        s.lastTokenType = afterRhsLastTokenType
                        return
                    }
                }
                // Simple assignment: find the LAST get opcode emitted by the
                // LHS and replace it with the corresponding put.
                //
                // For `a = expr`:   LHS emits scope_get_var(a)
                // For `o.x = expr`: LHS emits <obj code> + get_field(x)
                // For `a[i] = expr`: LHS emits <obj code> + <idx code> + get_array_el
                //
                // We scan backwards from the current bytecode position to find
                // the last GET opcode emitted by the LHS.
                let lhsEnd = fd.byteCode.len
                let (lastGetOp, lastGetPos) = findLastGetOpcode(from: lhsBcStart, to: lhsEnd)

                if lastGetOp == .scope_get_var, let pos = lastGetPos {
                    let opcodeSize = fd.byteCode.buf[pos] == 0 ? 2 : 1
                    let atom = readU32FromBuf(fd.byteCode.buf, pos + opcodeSize)
                    let scopeLevel = readU16FromBuf(fd.byteCode.buf, pos + opcodeSize + 4)
                    fd.byteCode.len = pos  // rewind to remove scope_get_var
                    parseAssignExpr()
                    // Assignment expression must leave the value on the stack.
                    // dup + put_var: dup keeps a copy, put_var stores and pops.
                    emitOp(.dup)
                    emitScopePutVar(atom, scopeLevel: Int(scopeLevel))
                } else if lastGetOp == .get_field, let pos = lastGetPos {
                    let opcodeSize = fd.byteCode.buf[pos] == 0 ? 2 : 1
                    let atom = readU32FromBuf(fd.byteCode.buf, pos + opcodeSize)
                    fd.byteCode.len = pos   // rewind; stack: [obj]
                    parseAssignExpr()        // stack: [obj, val]
                    // We need put_field(obj, val) AND leave val on stack.
                    // Strategy: [obj, val] → swap → [val, obj] → over(val) → [val, obj, val]
                    //           → put_field → [val]
                    // But "over" doesn't exist. Use: dup val, insert obj above.
                    // [obj, val] → dup → [obj, val, val] → perm3(2,0,1) → [val, obj, val]
                    //           → put_field → [val]
                    emitOp(.dup)             // [obj, val, val]
                    emitOp(.perm3)           // [val, obj, val]  (rotate: TOS-2 goes to TOS)
                    emitPutField(atom)       // pops [obj, val]; stack: [val]
                } else if lastGetOp == .get_array_el, let pos = lastGetPos {
                    fd.byteCode.len = pos   // rewind; stack: [obj, index]
                    parseAssignExpr()        // stack: [obj, index, val]
                    // Keep val: dup, then rotate so put_array_el gets [obj,index,val]
                    emitOp(.dup)             // stack: [obj, index, val, val]
                    emitOp(.perm4)           // stack: [val, obj, index, val]
                    emitOp(.put_array_el)    // pops [obj,index,val]; stack: [val]
                } else {
                    // Fallback
                    parseAssignExpr()
                    emitOp(.nip)
                }
            } else if assignOp == .land || assignOp == .lor || assignOp == .nullishCoalescing {
                // Logical assignment: x &&= y, x ||= y, x ??= y
                //
                // Semantics:
                //   x ??= y  →  if (x == null || x == undefined) x = y; result = x
                //   x ||= y  →  if (!x) x = y; result = x
                //   x &&= y  →  if (x) x = y; result = x
                //
                // The LHS has already been emitted as a GET by parseTernaryExpr.
                // We need to: check condition, if short-circuit keep old value,
                // otherwise evaluate RHS, store back, and leave new value on stack.
                let lhsOp = peekOpcodeAt(lhsBcStart)
                let endLabel = newLabel()

                if lhsOp == .scope_get_var {
                    // --- Variable LHS: x ??= y ---
                    let opcodeSize = fd.byteCode.buf[lhsBcStart] == 0 ? 2 : 1
                    let atom = readU32FromBuf(fd.byteCode.buf, lhsBcStart + opcodeSize)
                    let scopeLevel = readU16FromBuf(fd.byteCode.buf, lhsBcStart + opcodeSize + 4)

                    // Stack: [oldValue]
                    emitOp(.dup)
                    // Stack: [oldValue, oldValue]
                    switch assignOp {
                    case .land:
                        emitIfFalse(endLabel) // if falsy, keep old value
                    case .lor:
                        emitIfTrue(endLabel)  // if truthy, keep old value
                    case .nullishCoalescing:
                        emitOp(.is_undefined_or_null)
                        emitOp(.lnot)
                        emitIfTrue(endLabel) // if NOT null/undefined, keep old value
                    default:
                        break
                    }
                    // Stack: [oldValue]  (condition says we should assign)
                    emitOp(.drop) // drop old value
                    parseAssignExpr() // evaluate RHS
                    // Stack: [newValue]
                    emitOp(.dup) // keep a copy for the expression result
                    // Stack: [newValue, newValue]
                    emitScopePutVar(atom, scopeLevel: Int(scopeLevel))
                    // Stack: [newValue]
                    emitLabel(endLabel)
                    // Stack: [value]  (either old or new)
                } else {
                    // Fallback for non-variable LHS (field, array element, etc.)
                    // Stack: [oldValue]
                    emitOp(.dup)
                    switch assignOp {
                    case .land:
                        emitIfFalse(endLabel)
                    case .lor:
                        emitIfTrue(endLabel)
                    case .nullishCoalescing:
                        emitOp(.is_undefined_or_null)
                        emitOp(.lnot)
                        emitIfTrue(endLabel)
                    default:
                        break
                    }
                    emitOp(.drop)
                    parseAssignExpr()
                    emitLabel(endLabel)
                }
            } else {
                // Compound assignment: +=, -=, etc.
                // LHS was already parsed and emitted a GET. We need to:
                //   1. Read old value (the GET is already there)
                //   2. Compute new value (RHS + binary op)
                //   3. Store back to the same lvalue
                // Check if the last emitted opcode is get_field (for obj.prop += rhs).
                let fieldCheck = lastEmittedIsGetField()
                if fieldCheck.isGetField {
                    let fieldStart = fieldCheck.fieldStart
                    let atom = fieldCheck.atom
                    // Rewind past get_field, use get_field2 to keep obj on stack
                    fd.byteCode.len = fieldStart             // rewind past get_field
                    emitOp(.get_field2)                      // stack: [..., obj, oldValue]
                    emitAtom(atom)
                    parseAssignExpr()                        // stack: [..., obj, oldValue, rhs]
                    emitBinaryOp(forAssignOp: assignOp)      // stack: [..., obj, newValue]
                    emitOp(.dup)                             // stack: [..., obj, newValue, newValue]
                    emitOp(.perm3)                           // stack: [..., newValue, obj, newValue]
                    emitPutField(atom)                       // stack: [..., newValue]
                } else {
                    // Check for computed property access (obj[key] op= rhs)
                    // MUST check get_array_el BEFORE scope_get_var — for expressions
                    // like flags['lanes'] |= 1, the first opcode is scope_get_var
                    // (for 'flags') but the last is get_array_el.
                    let (compOp, compPos) = findLastGetOpcode(from: lhsBcStart, to: fd.byteCode.len)
                    if compOp == .get_array_el, let pos = compPos {
                        fd.byteCode.len = pos     // rewind past get_array_el; stack: [obj, key]
                        emitOp(.dup2)              // [obj, key, obj, key]
                        emitOp(.get_array_el)      // [obj, key, old_value]
                        parseAssignExpr()          // [obj, key, old_value, rhs]
                        emitBinaryOp(forAssignOp: assignOp) // [obj, key, new_value]
                        emitOp(.dup)               // [obj, key, new, new]
                        emitOp(.perm4)             // [new, obj, key, new]
                        emitOp(.put_array_el)      // [new]
                    } else if compOp == .scope_get_var, let pos = compPos {
                        let opcodeSize = fd.byteCode.buf[pos] == 0 ? 2 : 1
                        let atom = readU32FromBuf(fd.byteCode.buf, pos + opcodeSize)
                        let scopeLevel = readU16FromBuf(fd.byteCode.buf, pos + opcodeSize + 4)
                        parseAssignExpr()
                        emitBinaryOp(forAssignOp: assignOp)
                        emitScopePutVar(atom, scopeLevel: Int(scopeLevel))
                    } else {
                        // Fallback
                        emitOp(.dup)
                        parseAssignExpr()
                        emitBinaryOp(forAssignOp: assignOp)
                        emitOp(.nip)
                    }
                }
            }
        }

        // Arrow functions are detected above (before parseTernaryExpr) for
        // IDENT => and (params) => patterns, and also in parsePrimaryExpr()
        // as a fallback for nested contexts (e.g., inside call arguments).
    }

    /// Determine if a token is an assignment operator.
    func getAssignOp(_ tokenType: Int) -> AssignOpKind? {
        switch tokenType {
        case 0x3D: // '='
            return .plain
        case JSTokenType.TOK_ADD_ASSIGN.rawValue: return .add
        case JSTokenType.TOK_SUB_ASSIGN.rawValue: return .sub
        case JSTokenType.TOK_MUL_ASSIGN.rawValue: return .mul
        case JSTokenType.TOK_DIV_ASSIGN.rawValue: return .div
        case JSTokenType.TOK_MOD_ASSIGN.rawValue: return .mod
        case JSTokenType.TOK_POW_ASSIGN.rawValue: return .pow
        case JSTokenType.TOK_SHL_ASSIGN.rawValue: return .shl
        case JSTokenType.TOK_SAR_ASSIGN.rawValue: return .sar
        case JSTokenType.TOK_SHR_ASSIGN.rawValue: return .shr
        case JSTokenType.TOK_AND_ASSIGN.rawValue: return .and
        case JSTokenType.TOK_OR_ASSIGN.rawValue: return .or
        case JSTokenType.TOK_XOR_ASSIGN.rawValue: return .xor
        case JSTokenType.TOK_LAND_ASSIGN.rawValue: return .land
        case JSTokenType.TOK_LOR_ASSIGN.rawValue: return .lor
        case JSTokenType.TOK_DOUBLE_QUESTION_MARK_ASSIGN.rawValue: return .nullishCoalescing
        default: return nil
        }
    }

    /// Emit the binary operation for a compound assignment operator.
    func emitBinaryOp(forAssignOp op: AssignOpKind) {
        switch op {
        case .add: emitOp(.add)
        case .sub: emitOp(.sub)
        case .mul: emitOp(.mul)
        case .div: emitOp(.div)
        case .mod: emitOp(.mod)
        case .pow: emitOp(.pow)
        case .shl: emitOp(.shl)
        case .sar: emitOp(.sar)
        case .shr: emitOp(.shr)
        case .and: emitOp(.and)
        case .or: emitOp(.or)
        case .xor: emitOp(.xor)
        default: break
        }
    }

    // MARK: Ternary (Conditional) Expression

    /// Parse: LogicalORExpr ['?' AssignExpr ':' AssignExpr]
    func parseTernaryExpr() {
        parseNullishCoalescingExpr()
        guard !shouldAbort else { return }

        if tok == 0x3F { // '?'
            next()
            let falseLabel = newLabel()
            let endLabel = newLabel()

            emitIfFalse(falseLabel)
            // True branch uses [+In] per ECMAScript spec
            let savedInFlagTern = inFlag
            inFlag = true
            parseAssignExpr()
            inFlag = savedInFlagTern
            emitGoto(endLabel)

            expect(0x3A) // ':'
            emitLabel(falseLabel)
            parseAssignExpr()
            emitLabel(endLabel)
        }
    }

    // MARK: Nullish Coalescing

    /// Parse: LogicalORExpr ['??' LogicalORExpr]*
    func parseNullishCoalescingExpr() {
        parseLogicalOrExpr()

        while tok == JSTokenType.TOK_DOUBLE_QUESTION_MARK.rawValue && !shouldAbort {
            next()
            let endLabel = newLabel()
            emitOp(.dup)
            emitOp(.is_undefined_or_null)
            emitOp(.lnot)
            emitIfTrue(endLabel) // if not null/undefined, skip
            emitOp(.drop)
            parseLogicalOrExpr()
            emitLabel(endLabel)
        }
    }

    // MARK: Logical OR

    /// Parse: LogicalANDExpr ['||' LogicalANDExpr]*
    func parseLogicalOrExpr() {
        parseLogicalAndExpr()

        while tok == JSTokenType.TOK_LOR.rawValue && !shouldAbort {
            next()
            let endLabel = newLabel()
            emitOp(.dup)
            emitIfTrue(endLabel) // short-circuit
            emitOp(.drop)
            parseLogicalAndExpr()
            emitLabel(endLabel)
        }
    }

    // MARK: Logical AND

    /// Parse: BitwiseORExpr ['&&' BitwiseORExpr]*
    func parseLogicalAndExpr() {
        parseBitwiseOrExpr()

        while tok == JSTokenType.TOK_LAND.rawValue && !shouldAbort {
            next()
            let endLabel = newLabel()
            emitOp(.dup)
            emitIfFalse(endLabel) // short-circuit
            emitOp(.drop)
            parseBitwiseOrExpr()
            emitLabel(endLabel)
        }
    }

    // MARK: Bitwise OR

    /// Parse: BitwiseXORExpr ['|' BitwiseXORExpr]*
    func parseBitwiseOrExpr() {
        parseBitwiseXorExpr()

        while tok == 0x7C && s.simpleNextToken() != 0x7C && !shouldAbort { // '|' but not '||'
            next()
            parseBitwiseXorExpr()
            emitOp(.or)
        }
    }

    // MARK: Bitwise XOR

    /// Parse: BitwiseANDExpr ['^' BitwiseANDExpr]*
    func parseBitwiseXorExpr() {
        parseBitwiseAndExpr()

        while tok == 0x5E && !shouldAbort { // '^'
            next()
            parseBitwiseAndExpr()
            emitOp(.xor)
        }
    }

    // MARK: Bitwise AND

    /// Parse: EqualityExpr ['&' EqualityExpr]*
    func parseBitwiseAndExpr() {
        parseEqualityExpr()

        while tok == 0x26 && s.simpleNextToken() != 0x26 && !shouldAbort { // '&' but not '&&'
            next()
            parseEqualityExpr()
            emitOp(.and)
        }
    }

    // MARK: Equality

    /// Parse: RelationalExpr [('=='|'!='|'==='|'!==') RelationalExpr]*
    func parseEqualityExpr() {
        parseRelationalExpr()

        while !shouldAbort {
            switch tok {
            case JSTokenType.TOK_EQ.rawValue:
                next(); parseRelationalExpr(); emitOp(.eq)
            case JSTokenType.TOK_NEQ.rawValue:
                next(); parseRelationalExpr(); emitOp(.neq)
            case JSTokenType.TOK_STRICT_EQ.rawValue:
                next(); parseRelationalExpr(); emitOp(.strict_eq)
            case JSTokenType.TOK_STRICT_NEQ.rawValue:
                next(); parseRelationalExpr(); emitOp(.strict_neq)
            default:
                return
            }
        }
    }

    // MARK: Relational

    /// Parse: ShiftExpr [('<'|'>'|'<='|'>='|'instanceof'|'in') ShiftExpr]*
    func parseRelationalExpr() {
        parseShiftExpr()

        while !shouldAbort {
            switch tok {
            case 0x3C: // '<'
                next(); parseShiftExpr(); emitOp(.lt)
            case 0x3E: // '>'
                next(); parseShiftExpr(); emitOp(.gt)
            case JSTokenType.TOK_LE.rawValue:
                next(); parseShiftExpr(); emitOp(.lte)
            case JSTokenType.TOK_GE.rawValue:
                next(); parseShiftExpr(); emitOp(.gte)
            case JSTokenType.TOK_INSTANCEOF.rawValue:
                next(); parseShiftExpr(); emitOp(.instanceof_)
            case JSTokenType.TOK_IN.rawValue:
                if inFlag {
                    next(); parseShiftExpr(); emitOp(.in_)
                } else {
                    return
                }
            default:
                return
            }
        }
    }

    // MARK: Shift

    /// Parse: AdditiveExpr [('<<'|'>>'|'>>>') AdditiveExpr]*
    func parseShiftExpr() {
        parseAdditiveExpr()

        while !shouldAbort {
            switch tok {
            case JSTokenType.TOK_SHL.rawValue:
                next(); parseAdditiveExpr(); emitOp(.shl)
            case JSTokenType.TOK_SAR.rawValue:
                next(); parseAdditiveExpr(); emitOp(.sar)
            case JSTokenType.TOK_SHR.rawValue:
                next(); parseAdditiveExpr(); emitOp(.shr)
            default:
                return
            }
        }
    }

    // MARK: Additive

    /// Parse: MultiplicativeExpr [('+'|'-') MultiplicativeExpr]*
    func parseAdditiveExpr() {
        parseMultiplicativeExpr()

        while !shouldAbort {
            switch tok {
            case 0x2B: // '+'
                next(); parseMultiplicativeExpr(); emitOp(.add)
            case 0x2D: // '-'
                next(); parseMultiplicativeExpr(); emitOp(.sub)
            default:
                return
            }
        }
    }

    // MARK: Multiplicative

    /// Parse: ExponentiationExpr [('*'|'/'|'%') ExponentiationExpr]*
    func parseMultiplicativeExpr() {
        parseExponentiationExpr()

        while !shouldAbort {
            switch tok {
            case 0x2A: // '*'
                if s.peekByteAt(0) == 0x2A { return } // '**' is handled by exponentiation
                next(); parseExponentiationExpr(); emitOp(.mul)
            case 0x2F: // '/'
                next(); parseExponentiationExpr(); emitOp(.div)
            case 0x25: // '%'
                next(); parseExponentiationExpr(); emitOp(.mod)
            default:
                return
            }
        }
    }

    // MARK: Exponentiation

    /// Parse: UnaryExpr ['**' ExponentiationExpr]
    /// Right-associative.
    func parseExponentiationExpr() {
        parseUnaryExpr()

        if tok == JSTokenType.TOK_POW.rawValue {
            next()
            parseExponentiationExpr() // right-associative recursion
            emitOp(.pow)
        }
    }

    // MARK: Unary

    /// Parse: ('+'|'-'|'~'|'!'|'typeof'|'void'|'delete'|'++'|'--') UnaryExpr
    ///      | UpdateExpr
    func parseUnaryExpr() {
        guard enterRecursion() else { return }
        defer { leaveRecursion() }
        guard !shouldAbort else { return }
        switch tok {
        case 0x2B: // '+' unary plus
            next()
            parseUnaryExpr()
            emitOp(.plus)

        case 0x2D: // '-' unary minus
            next()
            parseUnaryExpr()
            emitOp(.neg)

        case 0x7E: // '~' bitwise NOT
            next()
            parseUnaryExpr()
            emitOp(.not)

        case 0x21: // '!' logical NOT
            next()
            parseUnaryExpr()
            emitOp(.lnot)

        case JSTokenType.TOK_TYPEOF.rawValue:
            next()
            parseUnaryExpr()
            emitOp(.typeof_)

        case JSTokenType.TOK_VOID.rawValue:
            next()
            parseUnaryExpr()
            emitOp(.drop)
            emitOp(.undefined)

        case JSTokenType.TOK_DELETE.rawValue:
            next()
            // delete requires special handling: instead of evaluating the
            // operand to a value, we need to leave [obj, key] on the stack
            // so the delete_ opcode can remove the property.
            let deleteStart = fd.byteCode.len
            parseUnaryExpr()
            let deleteEnd = fd.byteCode.len
            // Check what the last opcode was to determine the delete target
            let (lastOp, lastPos) = findLastGetOpcode(from: deleteStart, to: deleteEnd)
            if lastOp == .get_field, let pos = lastPos {
                // delete obj.prop -- rewind to remove get_field, push the
                // property name as a string, then emit delete_
                let opcodeSize = fd.byteCode.buf[pos] == 0 ? 2 : 1
                let atom = readU32FromBuf(fd.byteCode.buf, pos + opcodeSize)
                fd.byteCode.len = pos  // rewind: stack has [obj]
                // Push the property name as a string value
                emitOp(.push_atom_value)
                emitAtom(atom)
                // Stack: [obj, key]
                emitOp(.delete_)
            } else if lastOp == .get_array_el, let pos = lastPos {
                // delete obj[key] -- rewind to remove get_array_el.
                // Stack already has [obj, key] before get_array_el.
                fd.byteCode.len = pos  // rewind: stack has [obj, key]
                emitOp(.delete_)
            } else if lastOp == .scope_get_var, let pos = lastPos {
                // delete variable -- use scope_delete_var
                let opcodeSize = fd.byteCode.buf[pos] == 0 ? 2 : 1
                let atom = readU32FromBuf(fd.byteCode.buf, pos + opcodeSize)
                let scopeLevel = readU16FromBuf(fd.byteCode.buf, pos + opcodeSize + 4)
                fd.byteCode.len = pos  // rewind
                emitScopeDeleteVar(atom, scopeLevel: Int(scopeLevel))
            } else {
                // delete on a non-reference (e.g. delete 42) always returns true
                emitOp(.drop)
                emitOp(.push_true)
            }

        case JSTokenType.TOK_INC.rawValue: // prefix ++
            next()
            let incStart = fd.byteCode.len
            parseUnaryExpr()
            let incEnd = fd.byteCode.len
            emitOp(.inc)
            emitPrefixUpdateStore(from: incStart, to: incEnd)

        case JSTokenType.TOK_DEC.rawValue: // prefix --
            next()
            let decStart = fd.byteCode.len
            parseUnaryExpr()
            let decEnd = fd.byteCode.len
            emitOp(.dec)
            emitPrefixUpdateStore(from: decStart, to: decEnd)

        case JSTokenType.TOK_AWAIT.rawValue:
            parseAwaitExpression()

        default:
            parseUpdateExpr()
        }
    }

    // MARK: Update (Postfix)

    /// Parse: LeftHandSideExpr ['++'|'--']
    func parseUpdateExpr() {
        let exprStart = fd.byteCode.len
        parseCallExpr()

        // Postfix increment/decrement (no LineTerminator before)
        if !s.gotLF {
            let isInc = tok == JSTokenType.TOK_INC.rawValue
            let isDec = tok == JSTokenType.TOK_DEC.rawValue
            if isInc || isDec {
                next()
                // post_inc/dec pushes [old_value, new_value] on stack.
                // We need to store new_value back to the lvalue.
                let exprEnd = fd.byteCode.len
                let (lastGetOp, lastGetPos) = findLastGetOpcode(from: exprStart, to: exprEnd)

                emitOp(isInc ? .post_inc : .post_dec)
                // Stack: [old_value, new_value]

                if lastGetOp == .scope_get_var, let pos = lastGetPos {
                    let opcodeSize = fd.byteCode.buf[pos] == 0 ? 2 : 1
                    let atom = readU32FromBuf(fd.byteCode.buf, pos + opcodeSize)
                    let scopeLevel = readU16FromBuf(fd.byteCode.buf, pos + opcodeSize + 4)
                    // Store new_value (TOS) back, leave old_value as expression result
                    emitScopePutVar(atom, scopeLevel: Int(scopeLevel))
                    // Stack: [old_value]  (put_var consumed new_value)
                } else if lastGetOp == .get_field, let pos = lastGetPos {
                    let opcodeSize = fd.byteCode.buf[pos] == 0 ? 2 : 1
                    let atom = readU32FromBuf(fd.byteCode.buf, pos + opcodeSize)
                    // For obj.prop++:
                    // Retroactively change get_field → get_field2 to preserve obj.
                    //   get_field:  [obj] → [value]        (consumes obj)
                    //   get_field2: [obj] → [obj, value]   (preserves obj)
                    // Both are 5 bytes with same atom layout, safe to swap.
                    let opcBytePos = opcodeSize == 2 ? pos + 1 : pos
                    let rawVal = JeffJSOpcode.get_field2.rawValue
                    fd.byteCode.buf[opcBytePos] = rawVal <= 255
                        ? UInt8(truncatingIfNeeded: rawVal)
                        : UInt8(truncatingIfNeeded: rawVal &- 256)
                    // Stack after get_field2 + post_inc: [obj, old, new]
                    emitOp(.rot3l)     // [obj, old, new] → [old, new, obj]
                    emitOp(.swap)      // [old, new, obj] → [old, obj, new]
                    emitPutField(atom) // pops new + obj, stores → [old]
                } else if lastGetOp == .get_array_el, let pos = lastGetPos {
                    // For obj[key]++:
                    // Bytecode so far: ..., <obj>, <key>, get_array_el, post_inc
                    // Rewind to get_array_el and re-emit with dup2 to preserve obj+key.
                    fd.byteCode.len = pos  // rewind past get_array_el + post_inc; stack: [..., obj, key]
                    emitOp(.dup2)          // [..., obj, key, obj, key]
                    emitOp(.get_array_el)  // [..., obj, key, value]
                    emitOp(isInc ? .post_inc : .post_dec) // [..., obj, key, old, new]
                    emitOp(.swap)          // [..., obj, key, new, old]
                    emitOp(.perm4)         // [..., old, obj, key, new]
                    emitOp(.put_array_el)  // [..., old]
                } else {
                    // No lvalue found — drop new_value, keep old
                    emitOp(.nip)
                }
            }
        }
    }

    // MARK: Call Expression

    /// Parse: MemberExpr [Arguments | '[' Expression ']' | '.' Identifier | TemplateLiteral]*
    func parseCallExpr() {
        parseNewExpr()

        while !shouldAbort {
            switch tok {
            case 0x28: // '(' -- function call
                let isSuperCall = lastExprWasSuper
                lastExprWasSuper = false

                if isSuperCall {
                    // super(args) in a derived constructor.
                    // We need to call the parent constructor as a regular
                    // function with the current `this` (the new object
                    // created by the outer callConstructor).
                    //
                    // Stack currently: ..., parentCtor  (from get_super)
                    // We need: ..., thisVal, parentCtor  (for call_method)
                    //
                    // Insert this below the parent ctor:
                    emitOp(.push_this)       // ..., parentCtor, this
                    emitOp(.swap)            // ..., this, parentCtor
                }

                next()
                var argc = 0
                var hasSpread = false

                // Re-enable `in` operator inside call arguments.
                // It may have been disabled by a parent for-loop init.
                let savedInFlagCall = inFlag
                inFlag = true
                while tok != 0x29 && tok != JSTokenType.TOK_EOF.rawValue && !shouldAbort {
                    if tok == JSTokenType.TOK_ELLIPSIS.rawValue {
                        hasSpread = true
                        next()
                    }
                    parseAssignExpr()
                    argc += 1
                    if tok == 0x2C { // ','
                        next()
                    }
                }
                inFlag = savedInFlagCall
                expect(0x29) // ')'

                if isSuperCall {
                    // Emit call_method so the parent constructor is called
                    // with the derived constructor's `this` as the receiver.
                    // Stack: ..., this, parentCtor, arg0, ..., argN
                    emitCallMethod(argc)
                    // The result is the return value of the parent constructor.
                    // Typically undefined, so drop it.
                    emitOp(.drop)
                } else if hasSpread {
                    // The .apply opcode expects stack: [thisObj, funcVal, argsArray].
                    // For plain function calls the parser only has [funcVal, argsArray]
                    // on the stack (no thisObj), so we insert `undefined` below them.
                    emitOp(.undefined)       // [func, argsArray, undefined]
                    emitOp(.rot3r)           // [undefined, func, argsArray]
                    emitOp(.apply)
                    emitU16(UInt16(argc))
                } else {
                    emitCall(argc)
                }

            case 0x5B: // '[' -- computed member access
                lastExprWasSuper = false
                next()
                parseExpression()
                expect(0x5D) // ']'
                emitOp(.get_array_el)

            case 0x2E: // '.' -- member access
                lastExprWasSuper = false
                next()
                // After '.', accept identifiers AND keywords as property names.
                // In JS, keywords are valid property names: obj.delete, Promise.finally,
                // Symbol.for, etc.
                if tok == JSTokenType.TOK_IDENT.rawValue {
                    let fieldAtom = s.token.identAtom
                    next()
                    emitGetField(fieldAtom)
                } else if isKeywordToken(tok) {
                    // Keywords as property names: resolve to the canonical string
                    // atom via getAtom(string). The keyword's identAtom is often 0
                    // for keyword tokens, so we must get the string from the token type.
                    let kwName = keywordTokenName(tok)
                    let fieldAtom = getAtom(kwName)
                    next()
                    emitGetField(fieldAtom)
                } else if tok == JSTokenType.TOK_PRIVATE_NAME.rawValue {
                    let fieldAtom = s.token.identAtom
                    next()
                    emitOp(.get_private_field)
                    emitAtom(fieldAtom)
                } else {
                    syntaxError("expected property name after '.'")
                    return
                }

            case JSTokenType.TOK_OPTIONAL_CHAIN.rawValue: // '?.'
                next()
                let nullishLabel = newLabel()
                let endLabel = newLabel()
                emitOp(.dup)
                emitOp(.is_undefined_or_null)
                emitIfTrue(nullishLabel)

                if tok == 0x28 { // '?.(args)'
                    next()
                    var argc = 0
                    while tok != 0x29 && tok != JSTokenType.TOK_EOF.rawValue && !shouldAbort {
                        parseAssignExpr()
                        argc += 1
                        if tok == 0x2C { next() }
                    }
                    expect(0x29)
                    emitCall(argc)
                } else if tok == 0x5B { // '?.[expr]'
                    next()
                    parseExpression()
                    expect(0x5D)
                    emitOp(.get_array_el)
                } else if tok == JSTokenType.TOK_IDENT.rawValue {
                    let fieldAtom = s.token.identAtom
                    next()
                    emitGetField(fieldAtom)
                } else if isKeywordToken(tok) {
                    let kwName = keywordTokenName(tok)
                    let fieldAtom = getAtom(kwName)
                    next()
                    emitGetField(fieldAtom)
                }
                emitGoto(endLabel)
                emitLabel(nullishLabel)
                emitOp(.drop)       // discard null/undefined obj
                emitOp(.undefined)  // result is undefined
                emitLabel(endLabel)

            case JSTokenType.TOK_TEMPLATE.rawValue: // tagged template
                // When we're inside a template interpolation (${...}), the
                // tokenizer produces TOK_TEMPLATE when it hits the closing
                // `}`.  That token belongs to the OUTER template literal,
                // not to a tagged-template call on the expression we just
                // parsed.  So bail out of the postfix loop and let the
                // outer parseTemplateLiteral handle it.
                if inTemplateExpr {
                    lastExprWasSuper = false
                    return
                }
                lastExprWasSuper = false

                // Tagged template: tag`text0 ${expr0} text1 ${expr1} text2`
                // calls tag(strings, expr0, expr1, ...) where strings is an
                // array of the text segments.
                //
                // Strategy: parse the template, collecting text strings into
                // an array and pushing expression values onto the stack as
                // individual arguments. Then emit a call.
                //
                // The tag function value is already on the stack.

                // First, build the strings array by collecting all text segments.
                // We also need to evaluate interpolated expressions.
                // Since we must push the strings array FIRST (as arg 0) but
                // expressions come between text segments, we collect text
                // segment constant pool indices, push expressions, then build
                // the strings array below the expressions.
                //
                // Approach: push strings array first (empty), then for each
                // interpolation push the expression value. We'll build the
                // strings array by emitting the text segments into it.

                var textCpoolIndices: [Int] = []
                var exprCount = 0

                // Parse template parts -- collect text cpools and emit expressions
                // in a temporary buffer approach: push expressions in order.
                // First pass: we need to know all text segments and emit all expressions.
                // The template token stream alternates: text, expr, text, expr, text
                while !shouldAbort {
                    // Text segment
                    let textStr = s.token.strValue
                    let jsStr = JeffJSString(swiftString: textStr)
                    let cpoolIdx = addConstPoolValue(JeffJSValue.makeString(jsStr))
                    textCpoolIndices.append(cpoolIdx)

                    if s.templateNestLevel <= 0 {
                        break
                    }

                    // Expression
                    next()
                    // Zero templateNestLevel to allow nested { } in expressions
                    let savedNestLevel2 = s.templateNestLevel
                    s.templateNestLevel = 0
                    let savedInTemplateExpr2 = inTemplateExpr
                    inTemplateExpr = true
                    parseExpression()
                    inTemplateExpr = savedInTemplateExpr2
                    exprCount += 1

                    // Handle the closing } of the interpolation
                    if tok == 0x7D {
                        s.templateNestLevel = savedNestLevel2 > 0 ? savedNestLevel2 - 1 : 0
                        _ = s.parseTemplatePart()
                        // tok now reads s.token.type which parseTemplatePart set to TOK_TEMPLATE
                    } else if tok == JSTokenType.TOK_TEMPLATE.rawValue {
                        s.templateNestLevel = savedNestLevel2 > 0 ? savedNestLevel2 - 1 : 0
                    } else {
                        s.templateNestLevel = savedNestLevel2
                        break
                    }

                    if tok != JSTokenType.TOK_TEMPLATE.rawValue {
                        break
                    }
                }
                next() // advance past the final TOK_TEMPLATE

                // Stack now: ... tagFunc expr0 expr1 ... exprN
                // We need: ... tagFunc stringsArr expr0 expr1 ... exprN
                //
                // Strategy: build the strings array on top of the stack,
                // then use a rotation opcode to move it below all expressions.

                // Build the strings array on top of the stack.
                // Emit sentinel object before elements — array_from pops
                // the sentinel after the element values, and the compiler's
                // method-call depth tracker (findMatchingCall) counts it.
                emitOp(.object)
                for cpIdx in textCpoolIndices {
                    emitPushConst(cpIdx)
                }
                emitOp(.array_from)
                emitU16(UInt16(textCpoolIndices.count))

                // Stack: ... tagFunc expr0 expr1 ... exprN stringsArr
                // Rotate stringsArr below all expressions using perm/swap opcodes.
                // perm(N+1) rotates top N+1 elements right: moves top to bottom.
                switch exprCount {
                case 0:
                    break // stringsArr is already the only arg
                case 1:
                    emitOp(.swap)       // a b -> b a
                case 2:
                    emitOp(.perm3)      // a b c -> c a b
                case 3:
                    emitOp(.perm4)      // a b c d -> d a b c
                case 4:
                    emitOp(.perm5)      // a b c d e -> e a b c d
                default:
                    // For >4 expressions, use repeated perm5 + smaller perm
                    // to bubble stringsArr down to the correct position.
                    var remaining = exprCount
                    while remaining >= 4 {
                        emitOp(.perm5)  // rotate top 5 right
                        remaining -= 4
                    }
                    switch remaining {
                    case 1: emitOp(.swap)
                    case 2: emitOp(.perm3)
                    case 3: emitOp(.perm4)
                    default: break
                    }
                }

                // Stack: ... tagFunc stringsArr expr0 expr1 ... exprN
                // Also add a .raw property to the strings array (ES spec requirement)
                // For now, .raw = strings (cooked and raw are the same for non-escape cases)

                // Emit the call: tag(stringsArray, expr0, expr1, ..., exprN)
                // argc = 1 (strings array) + exprCount
                emitCall(1 + exprCount)

            default:
                lastExprWasSuper = false
                return
            }
        }
    }

    // MARK: New Expression

    /// Parse: 'new' NewExpr [Arguments]
    ///      | MemberExpr
    func parseNewExpr() {
        if tok == JSTokenType.TOK_NEW.rawValue {
            next() // consume 'new'

            // Check for 'new.target'
            if tok == 0x2E { // '.'
                next()
                if isIdent("target") {
                    next()
                    emitOp(.special_object)
                    emitU8(2) // new.target
                    return
                }
                syntaxError("expected 'target' after 'new.'")
                return
            }

            parseNewExpr() // recursive for 'new new Foo()'

            // Parse member access suffixes BEFORE arguments.
            // Per ECMAScript §13.3.5, `new MemberExpression Arguments`
            // means member access (`.prop`, `[expr]`) binds tighter than `new`.
            // So `new X.Y()` → `new (X.Y)()`, NOT `(new X).Y()`.
            while tok == 0x2E || tok == 0x5B { // '.' or '['
                if tok == 0x2E { // '.' — property access
                    next()
                    if tok == JSTokenType.TOK_IDENT.rawValue {
                        let fieldAtom = s.token.identAtom
                        next()
                        emitGetField(fieldAtom)
                    } else if isKeywordToken(tok) {
                        let kwName = keywordTokenName(tok)
                        let fieldAtom = getAtom(kwName)
                        next()
                        emitGetField(fieldAtom)
                    } else {
                        syntaxError("expected property name after '.'")
                        return
                    }
                } else { // '[' — computed member access
                    next()
                    parseExpression()
                    expect(0x5D) // ']'
                    emitOp(.get_array_el)
                }
            }

            // Duplicate constructor value: call_constructor pops both
            // funcVal and new.target from the stack.  For a plain `new`
            // expression new.target === funcVal, so we dup.
            emitOp(.dup)

            // Parse constructor arguments
            if tok == 0x28 { // '('
                next()
                var argc = 0
                var hasSpread = false
                while tok != 0x29 && tok != JSTokenType.TOK_EOF.rawValue && !shouldAbort {
                    if tok == JSTokenType.TOK_ELLIPSIS.rawValue {
                        hasSpread = true
                        next()
                    }
                    parseAssignExpr()
                    argc += 1
                    if tok == 0x2C { next() }
                }
                expect(0x29)
                if hasSpread {
                    emitOp(.apply_constructor)
                    emitU16(UInt16(argc))
                } else {
                    emitCallConstructor(argc)
                }
            } else {
                emitCallConstructor(0)
            }
        } else {
            parsePrimaryExpr()
        }
    }

    // MARK: Arrow Function Helpers

    /// Emit a complete arrow function closure.
    /// Called after the parameter list and '=>' have been consumed.
    /// `paramAtoms` contains the JSAtom for each parameter name.
    func emitArrowFunction(paramAtoms: [JSAtom], isAsync: Bool,
                           defaults: [JeffJSSavedDefaultParam] = [],
                           rest: JeffJSRestParamInfo? = nil) {
        let childFd = JeffJSFunctionDefCompiler()
        childFd.parent = fd
        childFd.definedScopeLevel = fd.curScope
        childFd.filename = fd.filename
        childFd.isArrow = true
        childFd.argumentsAllowed = false  // arrow functions don't have own arguments
        if isAsync {
            childFd.funcKind = JSFunctionKindEnum.JS_FUNC_ASYNC.rawValue
        }
        if fd.jsMode & JS_MODE_STRICT != 0 {
            childFd.jsMode = JS_MODE_STRICT
        }

        if !defaults.isEmpty || rest != nil {
            childFd.hasSimpleParameterList = false
        }

        for atom in paramAtoms {
            var arg = JeffJSVarDef()
            arg.varName = atom
            childFd.args.append(arg)
        }
        childFd.argCount = paramAtoms.count

        fd.childFunctions.append(childFd)
        parseArrowFunctionBody(childFd: childFd, isAsync: isAsync,
                               defaults: defaults, rest: rest)
        let cpoolIdx = addConstPoolValue(.mkVal(tag: .undefined, val: 0))
        emitFClosure(cpoolIdx)
    }

    /// Scan ahead from '(' to determine if this is a parenthesized arrow:
    ///   '(' [params] ')' '=>'
    /// This is called BEFORE the '(' is consumed. It saves and restores
    /// the full tokenizer state and returns the param list, or nil.
    func scanFullArrowFromParen() -> [(atom: JSAtom, isRest: Bool)]? {
        guard tok == 0x28 else { return nil } // '('
        // Save full tokenizer state
        let savedBufPtr   = s.bufPtr
        let savedLineNum  = s.lineNum
        let savedToken    = s.token
        let savedGotLF    = s.gotLF
        let savedLastPtr  = s.lastPtr
        let savedLastLine = s.lastLineNum
        let savedTmplNest = s.templateNestLevel

        defer {
            s.bufPtr              = savedBufPtr
            s.lineNum             = savedLineNum
            s.token               = savedToken
            s.gotLF               = savedGotLF
            s.lastPtr             = savedLastPtr
            s.lastLineNum         = savedLastLine
            s.templateNestLevel   = savedTmplNest
        }

        _ = s.nextToken() // consume '(' in the lookahead

        // Check for empty parens: () =>
        if s.token.type == 0x29 { // ')'
            _ = s.nextToken()
            return s.token.type == JSTokenType.TOK_ARROW.rawValue ? [] : nil
        }

        // Scan for ident-based param list
        var params: [(atom: JSAtom, isRest: Bool)] = []
        var safety = 0

        while safety < 200 {
            safety += 1
            let curTok = s.token.type
            if curTok == JSTokenType.TOK_EOF.rawValue { return nil }

            // Rest parameter: '...' IDENT
            if curTok == JSTokenType.TOK_ELLIPSIS.rawValue {
                _ = s.nextToken()
                if s.token.type != JSTokenType.TOK_IDENT.rawValue { return nil }
                params.append((atom: s.token.identAtom, isRest: true))
                _ = s.nextToken()
                if s.token.type != 0x29 { return nil }
                _ = s.nextToken()
                return s.token.type == JSTokenType.TOK_ARROW.rawValue ? params : nil
            }

            // Destructuring parameter: skip balanced { } or [ ]
            if curTok == 0x7B || curTok == 0x5B {
                var depth = 1
                _ = s.nextToken()
                while depth > 0 && s.token.type != JSTokenType.TOK_EOF.rawValue {
                    let t = s.token.type
                    if t == 0x7B || t == 0x5B { depth += 1 }
                    if t == 0x7D || t == 0x5D { depth -= 1 }
                    _ = s.nextToken()
                }
                // Use atom 0 as sentinel for destructuring param
                params.append((atom: 0, isRest: false))

                // Optional default value after pattern: skip balanced tokens
                if s.token.type == 0x3D { // '='
                    _ = s.nextToken()
                    var dDepth = 0
                    while s.token.type != JSTokenType.TOK_EOF.rawValue {
                        let t = s.token.type
                        if t == 0x28 || t == 0x5B || t == 0x7B { dDepth += 1 }
                        if t == 0x29 || t == 0x5D || t == 0x7D {
                            if dDepth == 0 { break }
                            dDepth -= 1
                        }
                        if dDepth == 0 && t == 0x2C { break }
                        _ = s.nextToken()
                    }
                }

                let afterParam = s.token.type
                if afterParam == 0x2C { _ = s.nextToken(); continue }
                if afterParam == 0x29 {
                    _ = s.nextToken()
                    return s.token.type == JSTokenType.TOK_ARROW.rawValue ? params : nil
                }
                return nil
            }

            // Regular parameter: must be IDENT
            if curTok != JSTokenType.TOK_IDENT.rawValue { return nil }
            params.append((atom: s.token.identAtom, isRest: false))
            _ = s.nextToken()

            // Optional default value: skip balanced tokens until ',' or ')'
            if s.token.type == 0x3D { // '='
                _ = s.nextToken()
                var depth = 0
                while s.token.type != JSTokenType.TOK_EOF.rawValue {
                    let t = s.token.type
                    if t == 0x28 || t == 0x5B || t == 0x7B { depth += 1 }
                    if t == 0x29 || t == 0x5D || t == 0x7D {
                        if depth == 0 { break }
                        depth -= 1
                    }
                    if depth == 0 && t == 0x2C { break }
                    _ = s.nextToken()
                }
            }

            let afterParam = s.token.type
            if afterParam == 0x2C { _ = s.nextToken(); continue }
            if afterParam == 0x29 {
                _ = s.nextToken()
                return s.token.type == JSTokenType.TOK_ARROW.rawValue ? params : nil
            }
            return nil
        }
        return nil
    }

    /// After scanFullArrowFromParen confirmed an arrow, consume the real
    /// parameter tokens (the opening '(' is already consumed).
    /// Finishes by consuming ')' and '=>'.
    func consumeParenArrowParams(_ params: [(atom: JSAtom, isRest: Bool)])
        -> (defaults: [JeffJSSavedDefaultParam], rest: JeffJSRestParamInfo?) {
        var savedDefaults: [JeffJSSavedDefaultParam] = []
        var restParam: JeffJSRestParamInfo? = nil
        var paramIndex = 0

        for (i, p) in params.enumerated() {
            if p.isRest {
                expect(JSTokenType.TOK_ELLIPSIS.rawValue)
            }
            if tok == JSTokenType.TOK_IDENT.rawValue {
                next() // consume the identifier (atom was already captured by scan)
            }
            // Save default value tokenizer state for replay in arrow body
            if tok == 0x3D { // '='
                next()

                // Save state AFTER consuming '=', before the default expression
                var saved = JeffJSSavedDefaultParam(
                    argIndex: paramIndex,
                    paramName: p.atom,
                    bufPtr: s.bufPtr,
                    lineNum: s.lineNum,
                    token: s.token,
                    gotLF: s.gotLF,
                    lastLineNum: s.lastLineNum,
                    lastPtr: s.lastPtr,
                    templateNestLevel: s.templateNestLevel
                )

                // Skip default expression
                var depth = 0
                while tok != JSTokenType.TOK_EOF.rawValue && !shouldAbort {
                    if tok == 0x28 || tok == 0x5B || tok == 0x7B { depth += 1 }
                    if tok == 0x29 || tok == 0x5D || tok == 0x7D {
                        if depth == 0 { break }
                        depth -= 1
                    }
                    if depth == 0 && tok == 0x2C { break }
                    next()
                }

                // Save end position
                saved.endBufPtr = s.bufPtr
                saved.endLineNum = s.lineNum
                saved.endToken = s.token
                saved.endGotLF = s.gotLF
                saved.endLastLineNum = s.lastLineNum
                saved.endLastPtr = s.lastPtr
                saved.endTemplateNestLevel = s.templateNestLevel

                savedDefaults.append(saved)
            }

            if p.isRest {
                restParam = JeffJSRestParamInfo(argIndex: paramIndex, paramName: p.atom)
            }

            paramIndex += 1
            // Consume comma between params (but not after last)
            if tok == 0x2C && i < params.count - 1 {
                next()
            }
        }
        expect(0x29) // ')'
        expect(JSTokenType.TOK_ARROW.rawValue) // '=>'
        return (savedDefaults, restParam)
    }

    // MARK: Arrow Function Lookahead (for parsePrimaryExpr)

    /// Scan ahead (without consuming tokens) to determine if the current
    /// parenthesized token sequence is an arrow-function parameter list.
    ///
    /// Pre-condition: the opening '(' has already been consumed, so `tok`
    /// is the first token *inside* the parentheses.
    ///
    /// Returns an array of (atom, hasDefault) pairs if the pattern matches
    /// `IDENT ['=' expr] {',' IDENT ['=' expr]} [',' '...' IDENT] ')' '=>'`
    /// Returns nil if this is not an arrow parameter list (i.e. it is a
    /// normal parenthesized expression).
    ///
    /// The tokenizer state is always fully restored on return — this is a
    /// pure lookahead.
    func scanParenArrowParams() -> [(atom: JSAtom, isRest: Bool)]? {
        // Save full tokenizer state
        let savedBufPtr   = s.bufPtr
        let savedLineNum  = s.lineNum
        let savedToken    = s.token
        let savedGotLF    = s.gotLF
        let savedLastPtr  = s.lastPtr
        let savedLastLine = s.lastLineNum
        let savedTmplNest = s.templateNestLevel

        defer {
            // Restore tokenizer state unconditionally
            s.bufPtr              = savedBufPtr
            s.lineNum             = savedLineNum
            s.token               = savedToken
            s.gotLF               = savedGotLF
            s.lastPtr             = savedLastPtr
            s.lastLineNum         = savedLastLine
            s.templateNestLevel   = savedTmplNest
        }

        // The current token (first inside the parens) is already loaded.
        // Walk tokens looking for the pattern: ident [= expr] , ... ) =>
        var params: [(atom: JSAtom, isRest: Bool)] = []
        var safety = 0

        while safety < 200 {
            safety += 1
            let curTok = s.token.type

            if curTok == JSTokenType.TOK_EOF.rawValue { return nil }

            // Rest parameter: '...' IDENT
            if curTok == JSTokenType.TOK_ELLIPSIS.rawValue {
                _ = s.nextToken()
                if s.token.type != JSTokenType.TOK_IDENT.rawValue { return nil }
                params.append((atom: s.token.identAtom, isRest: true))
                _ = s.nextToken()
                // Must be followed by ')'
                if s.token.type != 0x29 { return nil }
                _ = s.nextToken()
                // Must be followed by '=>'
                return s.token.type == JSTokenType.TOK_ARROW.rawValue ? params : nil
            }

            // Regular parameter: IDENT
            if curTok != JSTokenType.TOK_IDENT.rawValue { return nil }
            let atom = s.token.identAtom
            params.append((atom: atom, isRest: false))

            _ = s.nextToken()

            // Optional default value: '=' <expr>
            // We don't need to evaluate it, just skip balanced tokens up to ',' or ')'
            if s.token.type == 0x3D { // '='
                _ = s.nextToken()
                // Skip the default expression: balanced parens/brackets/braces until ',' or ')'
                var depth = 0
                while s.token.type != JSTokenType.TOK_EOF.rawValue {
                    let t = s.token.type
                    if t == 0x28 || t == 0x5B || t == 0x7B { depth += 1 }
                    if t == 0x29 || t == 0x5D || t == 0x7D {
                        if depth == 0 { break }
                        depth -= 1
                    }
                    if depth == 0 && t == 0x2C { break } // ','
                    _ = s.nextToken()
                }
            }

            let afterParam = s.token.type
            if afterParam == 0x2C { // ','
                _ = s.nextToken()
                continue
            }
            if afterParam == 0x29 { // ')'
                _ = s.nextToken()
                return s.token.type == JSTokenType.TOK_ARROW.rawValue ? params : nil
            }
            // Anything else means not an arrow param list
            return nil
        }
        return nil
    }

    // MARK: Primary Expression

    /// Parse a primary expression: literals, identifiers, grouping, etc.
    func parsePrimaryExpr() {
        guard enterRecursion() else { return }
        defer { leaveRecursion() }
        guard !shouldAbort else { return }
        switch tok {

        case JSTokenType.TOK_NUMBER.rawValue:
            let val = s.token.numValue
            let intVal = Int32(exactly: val)
            if let iv = intVal, Double(iv) == val {
                emitPushI32(iv)
            } else {
                // Float constant -- add to constant pool with the actual double value
                let cpoolIdx = addConstPoolValue(JeffJSValue.newFloat64(val))
                emitPushConst(cpoolIdx)
            }
            next()

        case JSTokenType.TOK_STRING.rawValue:
            let str = s.token.strValue
            let jsStr = JeffJSString(swiftString: str)
            let cpoolIdx = addConstPoolValue(JeffJSValue.makeString(jsStr))
            emitPushConst(cpoolIdx)
            next()

        case JSTokenType.TOK_TEMPLATE.rawValue:
            parseTemplateLiteral(isTagged: false)

        case JSTokenType.TOK_REGEXP.rawValue:
            // Push pattern and flags, then create regexp
            let body = s.token.regexpBody
            let flags = s.token.regexpFlags
            let bodyAtom = getAtom(body)
            let flagsAtom = getAtom(flags)
            emitOp(.push_atom_value)
            emitAtom(bodyAtom)
            emitOp(.push_atom_value)
            emitAtom(flagsAtom)
            emitOp(.regexp)
            next()

        case JSTokenType.TOK_NULL.rawValue:
            emitOp(.push_null)
            next()

        case JSTokenType.TOK_TRUE.rawValue:
            emitOp(.push_true)
            next()

        case JSTokenType.TOK_FALSE.rawValue:
            emitOp(.push_false)
            next()

        case JSTokenType.TOK_THIS.rawValue:
            emitOp(.push_this)
            next()

        case JSTokenType.TOK_SUPER.rawValue:
            next()
            // Push a dummy value that get_super will pop (nPop=1).
            // The interpreter resolves the parent constructor from
            // frame.curFunc.__proto__ regardless of this value.
            emitOp(.push_this)
            emitOp(.get_super)
            lastExprWasSuper = true

        case JSTokenType.TOK_IDENT.rawValue:
            // Check for 'async function' expression (e.g. var f = async function(){})
            // [no LineTerminator here] is between async and function, so peek
            // and check gotLF after consuming async.
            if isIdent("async") &&
               s.simpleNextToken() == JSTokenType.TOK_FUNCTION.rawValue {
                let savedBc = fd.byteCode.len
                let savedBufPtr = s.bufPtr
                let savedLineNum = s.lineNum
                let savedToken = s.token
                let savedGotLF = s.gotLF
                let savedLastLineNum = s.lastLineNum
                let savedLastPtr = s.lastPtr
                let savedTemplateNest = s.templateNestLevel
                let savedLastTokenType = s.lastTokenType

                next() // consume 'async'
                if !s.gotLF {
                    parseFunctionDef(isExpression: true, isArrow: false)
                    return
                }
                // LF between async and function — backtrack
                fd.byteCode.len = savedBc
                s.bufPtr = savedBufPtr
                s.lineNum = savedLineNum
                s.token = savedToken
                s.gotLF = savedGotLF
                s.lastLineNum = savedLastLineNum
                s.lastPtr = savedLastPtr
                s.templateNestLevel = savedTemplateNest
                s.lastTokenType = savedLastTokenType
            }

            // Check for async arrow: async () =>, async (a,b) =>, async x =>
            // [no LineTerminator here] between async and params — check after consuming async.
            if isIdent("async") {
                let peekTok = s.simpleNextToken()
                if peekTok == 0x28 { // '(' — could be async arrow
                    // Save full state for backtrack
                    let savedBc = fd.byteCode.len
                    let savedBufPtr = s.bufPtr
                    let savedLineNum = s.lineNum
                    let savedToken = s.token
                    let savedGotLF = s.gotLF
                    let savedLastLineNum = s.lastLineNum
                    let savedLastPtr = s.lastPtr
                    let savedTemplateNest = s.templateNestLevel
                    let savedLastTokenType = s.lastTokenType

                    next() // consume 'async'
                    // [no LineTerminator here] between async and (
                    if !s.gotLF {
                        next() // consume '('
                        // Check for () => or (params) =>
                        if tok == 0x29 { // ')'
                            next()
                            if tok == JSTokenType.TOK_ARROW.rawValue {
                                next()
                                emitArrowFunction(paramAtoms: [], isAsync: true)
                                return
                            }
                        } else if let arrowParams = scanParenArrowParams() {
                            let (dflts, rst) = consumeParenArrowParams(arrowParams)
                            // consumeParenArrowParams already consumed ')' and '=>'
                            emitArrowFunction(paramAtoms: arrowParams.map { $0.atom }, isAsync: true,
                                              defaults: dflts, rest: rst)
                            return
                        }
                    }
                    // Not an async arrow — restore state fully
                    fd.byteCode.len = savedBc
                    s.bufPtr = savedBufPtr
                    s.lineNum = savedLineNum
                    s.token = savedToken
                    s.gotLF = savedGotLF
                    s.lastLineNum = savedLastLineNum
                    s.lastPtr = savedLastPtr
                    s.templateNestLevel = savedTemplateNest
                    s.lastTokenType = savedLastTokenType
                } else if peekTok == JSTokenType.TOK_IDENT.rawValue {
                    // async x => ... (single param async arrow)
                    let savedBc = fd.byteCode.len
                    let savedBufPtr = s.bufPtr
                    let savedLineNum = s.lineNum
                    let savedToken = s.token
                    let savedGotLF = s.gotLF
                    let savedLastLineNum = s.lastLineNum
                    let savedLastPtr = s.lastPtr
                    let savedTemplateNest = s.templateNestLevel
                    let savedLastTokenType = s.lastTokenType

                    next() // consume 'async'
                    if !s.gotLF {
                        let paramAtom = s.token.identAtom
                        next() // consume param name
                        if tok == JSTokenType.TOK_ARROW.rawValue {
                            next()
                            emitArrowFunction(paramAtoms: [paramAtom], isAsync: true)
                            return
                        }
                    }
                    // Not arrow — restore state fully
                    fd.byteCode.len = savedBc
                    s.bufPtr = savedBufPtr
                    s.lineNum = savedLineNum
                    s.token = savedToken
                    s.gotLF = savedGotLF
                    s.lastLineNum = savedLastLineNum
                    s.lastPtr = savedLastPtr
                    s.templateNestLevel = savedTemplateNest
                    s.lastTokenType = savedLastTokenType
                }
            }

            let atom = s.token.identAtom
            next()

            // Check for arrow function: x =>
            if tok == JSTokenType.TOK_ARROW.rawValue {
                next() // consume '=>'
                emitArrowFunction(paramAtoms: [atom], isAsync: false)
                return
            }

            // Regular identifier -- emit scope variable access
            emitScopeGetVar(atom, scopeLevel: fd.curScope)

        case 0x28: // '(' -- grouping or arrow params
            // Try full arrow scan first (handles destructuring patterns like ([e,t])=>...)
            if let params = scanFullArrowFromParen() {
                let hasDestructuring = params.contains(where: { $0.atom == 0 })
                next() // consume '('
                if params.isEmpty {
                    expect(0x29) // ')'
                    expect(JSTokenType.TOK_ARROW.rawValue)
                    emitArrowFunction(paramAtoms: [], isAsync: false)
                } else if hasDestructuring {
                    let arrowFd = JeffJSFunctionDefCompiler()
                    arrowFd.parent = fd
                    arrowFd.isArrow = true
                    arrowFd.argumentsAllowed = false
                    if fd.jsMode & JS_MODE_STRICT != 0 {
                        arrowFd.jsMode = JS_MODE_STRICT
                    }
                    let (adflts, arst, adstructs) = parseFormalParameters(childFd: arrowFd)
                    expect(0x29) // ')'
                    expect(JSTokenType.TOK_ARROW.rawValue)
                    fd.childFunctions.append(arrowFd)
                    parseArrowFunctionBody(childFd: arrowFd, isAsync: false,
                                           defaults: adflts, rest: arst, destructs: adstructs)
                    let cpoolIdx = addConstPoolValue(.mkVal(tag: .undefined, val: 0))
                    emitFClosure(cpoolIdx)
                } else {
                    let (dflts, rst) = consumeParenArrowParams(params)
                    emitArrowFunction(paramAtoms: params.map { $0.atom }, isAsync: false,
                                      defaults: dflts, rest: rst)
                }
                return
            }

            next()

            // Check for empty parens -> arrow: () =>
            if tok == 0x29 { // ')'
                next()
                if tok == JSTokenType.TOK_ARROW.rawValue {
                    next() // consume '=>'
                    emitArrowFunction(paramAtoms: [], isAsync: false)
                    return
                }
                // Empty parens without arrow -- error or undefined
                emitOp(.undefined)
                return
            }

            // Lookahead: check if this is a parenthesized arrow param list
            // e.g. (a, b) => ..., (x) => ..., (a, b, ...rest) => ...
            if let arrowParams = scanParenArrowParams() {
                let (dflts, rst) = consumeParenArrowParams(arrowParams)
                emitArrowFunction(paramAtoms: arrowParams.map { $0.atom }, isAsync: false,
                                  defaults: dflts, rest: rst)
                return
            }

            // Not an arrow — parse as normal parenthesized expression
            let savedBcLen = fd.byteCode.len
            let savedChildCount = fd.childFunctions.count
            // Re-enable `in` inside parentheses
            let savedInFlagGroup = inFlag
            inFlag = true
            parseExpression()
            inFlag = savedInFlagGroup
            expect(0x29) // ')'

            // Fallback: check for arrow after parenthesized expression
            // (handles complex cases the lookahead didn't match)
            if tok == JSTokenType.TOK_ARROW.rawValue {
                // Rewind bytecode emitted by the parenthesized expression
                fd.byteCode.len = savedBcLen
                // Remove any child functions that were added during
                // the aborted expression parse
                if fd.childFunctions.count > savedChildCount {
                    fd.childFunctions.removeSubrange(savedChildCount...)
                }
                next() // consume '=>'
                // We lost parameter info by parsing as an expression.
                // Create a zero-arg arrow (best effort for unusual cases).
                emitArrowFunction(paramAtoms: [], isAsync: false)
                return
            }

        case 0x5B: // '[' -- array literal
            parseArrayLiteral()

        case 0x7B: // '{' -- object literal
            parseObjectLiteral()

        case JSTokenType.TOK_FUNCTION.rawValue:
            parseFunctionDef(isExpression: true, isArrow: false)

        case JSTokenType.TOK_CLASS.rawValue:
            parseClassDef(isExpression: true)

        case 0x2F: // '/' -- regex literal
            s.reParseAsRegexp()
            let body = s.token.regexpBody
            let flags = s.token.regexpFlags
            let bodyAtom = getAtom(body)
            let flagsAtom = getAtom(flags)
            emitOp(.push_atom_value)
            emitAtom(bodyAtom)
            emitOp(.push_atom_value)
            emitAtom(flagsAtom)
            emitOp(.regexp)
            next()

        case JSTokenType.TOK_IMPORT.rawValue:
            // import.meta or import()
            next()
            if tok == 0x2E { // '.'
                next()
                if isIdent("meta") {
                    next()
                    emitOp(.special_object)
                    emitU8(3) // import.meta
                } else {
                    syntaxError("expected 'meta' after 'import.'")
                }
            } else if tok == 0x28 { // '(' dynamic import
                next()
                emitOp(.undefined) // this
                parseAssignExpr()
                expect(0x29)
                emitOp(.import_)
                emitU8(0)
            }

        default:
            // Keywords used as identifiers in expression context (common in minified JS).
            // e.g., `of(e,t)` where `of` is a function named with the keyword.
            if isKeywordToken(tok) {
                let kwName = keywordTokenName(tok)
                let atom = getAtom(kwName)
                next()
                // Check for arrow: keyword =>
                if tok == JSTokenType.TOK_ARROW.rawValue {
                    next()
                    emitArrowFunction(paramAtoms: [atom], isAsync: false)
                    return
                }
                emitScopeGetVar(atom, scopeLevel: fd.curScope)
            } else {
                syntaxError("unexpected token in expression: \(tokenName(tok))")
                // Skip the token to avoid infinite loops
                next()
            }
        }
    }

    // =========================================================================
    // MARK: - Array Literal
    // =========================================================================

    /// Parse: '[' [ElementList] ']'
    func parseArrayLiteral() {
        expect(0x5B) // '['
        // Array element expressions always use [+In] per ECMAScript spec
        let savedInFlagArr = inFlag
        inFlag = true
        emitOp(.object) // sentinel object (consumed by array_from)

        // Parse elements, tracking whether any spread (...) is present.
        var count = 0
        var hasSpread = false

        // Element descriptors: false = normal value, true = spread iterable.
        // We record these so we can emit the right bytecode AFTER parsing
        // all elements.  However, because parseAssignExpr() emits bytecode
        // eagerly we take a two-phase approach only when needed.
        //
        // Phase 1: parse all elements onto the stack.
        // Phase 2: if no spread, emit array_from(count).
        //          if spread, rewrite to incremental build.
        //
        // Because the interpreter's array_from does not expand spread
        // iterables, we must detect spread DURING parsing and switch to
        // the incremental path immediately.

        // We start optimistically with the collect-then-array_from strategy.
        // If we hit a spread, we switch mid-stream.

        while tok != 0x5D && tok != JSTokenType.TOK_EOF.rawValue && !shouldAbort {
            if tok == 0x2C { // elision
                if hasSpread {
                    emitOp(.undefined)
                    emitOp(.append)
                } else {
                    emitOp(.undefined)
                    count += 1
                }
                next()
                continue
            }

            if tok == JSTokenType.TOK_ELLIPSIS.rawValue {
                if !hasSpread {
                    // First spread encountered — switch to incremental build.
                    // We already have `count` normal values on the stack above
                    // the sentinel object.  Convert them: array_from(count)
                    // creates a proper Array from those values, consuming the
                    // sentinel.  Then append spread elements.
                    hasSpread = true
                    emitOp(.array_from)
                    emitU16(UInt16(count))
                    // Stack: [array]  (proper Array)
                    count = 0
                }

                // --- spread element: ...expr ---
                next()
                parseAssignExpr()
                // Stack: [array, iterable]

                emitOp(.for_of_start)
                // Stack: [array, iter, obj, method]

                let loopLabel = newLabel()
                let doneLabel = newLabel()

                emitLabel(loopLabel)
                emitOp(.for_of_next)
                emitU8(0)
                // Stack: [array, iter, obj, method, value, done]
                emitIfTrue(doneLabel)
                // Stack: [array, iter, obj, method, value]

                // Rotate value down next to array, then append.
                emitOp(.rot5l)
                // Stack: [iter, obj, method, value, array]
                emitOp(.swap)
                // Stack: [iter, obj, method, array, value]
                emitOp(.append)
                // Stack: [iter, obj, method, array]
                emitOp(.perm4)
                // Stack: [array, iter, obj, method]

                emitGoto(loopLabel)

                emitLabel(doneLabel)
                // Stack: [array, iter, obj, method, value]
                emitOp(.drop)           // drop value
                emitOp(.iterator_close) // pops [iter, obj, method]
                // Stack: [array]
            } else {
                // --- normal element ---
                parseAssignExpr()
                if hasSpread {
                    // Stack: [array, value]
                    emitOp(.append)
                    // Stack: [array]
                } else {
                    count += 1
                }
            }

            if tok == 0x2C { next() }
        }

        inFlag = savedInFlagArr
        expect(0x5D)

        if !hasSpread {
            // No spread was found — use the fast array_from path.
            emitOp(.array_from)
            emitU16(UInt16(count))
        }
        // If hasSpread, the array was already built incrementally and is on
        // the stack as a proper Array.  Nothing more to emit.
    }

    // =========================================================================
    // MARK: - Object Literal
    // =========================================================================

    /// Parse: '{' [PropertyDefinitionList] '}'
    func parseObjectLiteral() {
        expect(0x7B) // '{'
        // Object property values always use [+In] per ECMAScript spec
        let savedInFlagObj = inFlag
        inFlag = true
        emitOp(.object)

        while tok != 0x7D && tok != JSTokenType.TOK_EOF.rawValue && !shouldAbort {
            parsePropertyDefinition()

            if tok == 0x2C { // ','
                next()
            }
        }

        inFlag = savedInFlagObj
        expect(0x7D) // '}'
    }

    /// Parse a single property definition in an object literal.
    func parsePropertyDefinition() {
        // Spread: ...expr
        if tok == JSTokenType.TOK_ELLIPSIS.rawValue {
            next()
            parseAssignExpr()
            emitOp(.copy_data_properties)
            emitU8(0) // flags
            return
        }

        var isComputed = false
        var isAsync = false
        var isGenerator = false
        var propKind: PropertyKind = .data

        // Check for 'async' — [no LineTerminator here] between async and method name
        if isIdent("async") {
            let nextTok = s.simpleNextToken()
            if nextTok != 0x3A && nextTok != 0x2C && nextTok != 0x7D && // not :, ,, }
               nextTok != 0x28 { // not ( (shorthand method)
                let savedBufPtr = s.bufPtr
                let savedLineNum = s.lineNum
                let savedToken = s.token
                let savedGotLF = s.gotLF
                let savedLastLineNum = s.lastLineNum
                let savedLastPtr = s.lastPtr
                let savedTemplateNest = s.templateNestLevel
                let savedLastTokenType = s.lastTokenType

                next() // consume 'async'
                if !s.gotLF {
                    isAsync = true
                } else {
                    // LF between async and method name — backtrack
                    s.bufPtr = savedBufPtr
                    s.lineNum = savedLineNum
                    s.token = savedToken
                    s.gotLF = savedGotLF
                    s.lastLineNum = savedLastLineNum
                    s.lastPtr = savedLastPtr
                    s.templateNestLevel = savedTemplateNest
                    s.lastTokenType = savedLastTokenType
                }
            }
        }

        // Check for generator '*'
        if tok == 0x2A { // '*'
            isGenerator = true
            next()
        }

        // Check for getter/setter
        if isIdent("get") && !isGenerator && !isAsync {
            let nextTok = s.simpleNextToken()
            if nextTok != 0x3A && nextTok != 0x2C && nextTok != 0x7D && nextTok != 0x28 {
                propKind = .getter
                next()
            }
        } else if isIdent("set") && !isGenerator && !isAsync {
            let nextTok = s.simpleNextToken()
            if nextTok != 0x3A && nextTok != 0x2C && nextTok != 0x7D && nextTok != 0x28 {
                propKind = .setter
                next()
            }
        }

        // Parse property name
        var propAtom: JSAtom = 0

        if tok == 0x5B { // '[' computed property
            isComputed = true
            next()
            parseAssignExpr()
            expect(0x5D) // ']'
            emitOp(.to_propkey)
        } else if tok == JSTokenType.TOK_IDENT.rawValue {
            propAtom = s.token.identAtom
            next()
        } else if tok == JSTokenType.TOK_STRING.rawValue {
            propAtom = getAtom(s.token.strValue)
            next()
        } else if tok == JSTokenType.TOK_NUMBER.rawValue {
            let numStr: String
            let val = s.token.numValue
            if let iv = Int32(exactly: val), Double(iv) == val {
                numStr = String(iv)
            } else {
                numStr = String(val)
            }
            propAtom = getAtom(numStr)
            next()
        } else if isKeywordToken(tok) {
            // Keywords are valid as property names in object literals and class bodies.
            // e.g., { return: 42, delete: fn, for: 3 }
            let kwName = keywordTokenName(tok)
            propAtom = getAtom(kwName)
            next()
        } else {
            syntaxError("expected property name")
            return
        }

        // Check for __proto__
        if propAtom == JSPredefinedAtom.__proto__.rawValue && !isComputed {
            if tok == 0x3A { // ':'
                next()
                parseAssignExpr()
                emitOp(.set_proto)
                return
            }
        }

        if tok == 0x3A { // ':' -- data property
            next()
            if isComputed {
                // Stack before: [obj, key]
                // Rearrange to: [obj, obj_dup, key] so put_array_el can
                // consume [obj_dup, key, value] and leave [obj] on stack.
                emitOp(.swap)    // [key, obj]
                emitOp(.dup)     // [key, obj, obj]
                emitOp(.rot3l)   // [obj, obj, key]
                parseAssignExpr() // [obj, obj, key, value]
                emitOp(.put_array_el) // pops [obj, key, value] -> [obj]
            } else {
                parseAssignExpr()
                emitDefineField(propAtom)
            }
        } else if tok == 0x28 { // '(' -- method shorthand
            // Method
            let methodFd = JeffJSFunctionDefCompiler()
            methodFd.parent = fd
            methodFd.funcName = propAtom
            if isGenerator {
                methodFd.funcKind = isAsync
                    ? JSFunctionKindEnum.JS_FUNC_ASYNC_GENERATOR.rawValue
                    : JSFunctionKindEnum.JS_FUNC_GENERATOR.rawValue
            } else if isAsync {
                methodFd.funcKind = JSFunctionKindEnum.JS_FUNC_ASYNC.rawValue
            }
            fd.childFunctions.append(methodFd)

            next() // consume '('
            let (omDefaults, omRest, omDstructs) = parseFormalParameters(childFd: methodFd)
            expect(0x29) // ')'
            expect(0x7B) // '{'
            parseFunctionBody(childFd: methodFd, defaults: omDefaults, rest: omRest, destructs: omDstructs)
            expect(0x7D) // '}'

            let cpoolIdx = addConstPoolValue(.mkVal(tag: .undefined, val: 0))
            emitFClosure(cpoolIdx)

            if isComputed {
                emitOp(.define_method_computed)
            } else {
                emitOp(.define_method)
                emitAtom(propAtom)
            }
            let flags: UInt8 = (propKind == .getter ? 2 : 0) |
                               (propKind == .setter ? 4 : 0)
            emitU8(flags)
        } else if propKind == .getter || propKind == .setter {
            // Getter/setter
            let methodFd = JeffJSFunctionDefCompiler()
            methodFd.parent = fd
            methodFd.funcName = propAtom
            fd.childFunctions.append(methodFd)

            expect(0x28) // '('
            let (gsDefaults, gsRest, gsDstructs) = parseFormalParameters(childFd: methodFd)
            expect(0x29) // ')'
            expect(0x7B) // '{'
            parseFunctionBody(childFd: methodFd, defaults: gsDefaults, rest: gsRest, destructs: gsDstructs)
            expect(0x7D) // '}'

            let cpoolIdx = addConstPoolValue(.mkVal(tag: .undefined, val: 0))
            emitFClosure(cpoolIdx)

            if isComputed {
                emitOp(.define_method_computed)
            } else {
                emitOp(.define_method)
                emitAtom(propAtom)
            }
            let flags: UInt8 = (propKind == .getter ? 2 : 0) |
                               (propKind == .setter ? 4 : 0)
            emitU8(flags)
        } else if !isComputed && propAtom != 0 {
            // Shorthand: { x } or { x = default }
            emitScopeGetVar(propAtom, scopeLevel: fd.curScope)

            if tok == 0x3D { // '=' default value
                let endLabel = newLabel()
                emitOp(.dup)
                emitOp(.undefined)
                emitOp(.strict_eq)
                emitIfFalse(endLabel)
                emitOp(.drop)
                next()
                parseAssignExpr()
                emitLabel(endLabel)
            }

            emitDefineField(propAtom)
        } else {
            syntaxError("unexpected token in property definition")
        }
    }

    // =========================================================================
    // MARK: - Template Literal
    // =========================================================================

    /// Parse a template literal expression.
    ///
    /// Template literals like `` `hello ${name}, you are ${age}!` `` are compiled
    /// by pushing each string part and expression onto the stack and concatenating
    /// them incrementally with `add`.  For the example above the emitted sequence
    /// is:
    ///
    ///     push "hello "     // first string part
    ///     <evaluate name>   // expression 1
    ///     add               // "hello " + name
    ///     push ", you are " // second string part
    ///     add               // result + ", you are "
    ///     <evaluate age>    // expression 2
    ///     add               // result + age
    ///     push "!"          // third string part
    ///     add               // result + "!"
    ///
    /// This keeps at most 2 items on the stack at any point and naturally handles
    /// toString conversion of interpolated values because `add` converts to string
    /// when either operand is a string.
    func parseTemplateLiteral(isTagged: Bool) {
        // First part is already in the current token.
        //
        // Approach: push each text segment and each interpolated expression
        // onto the stack, concatenating incrementally with `add`.  For
        //   `hello ${name}, you are ${age}!`
        // the emitted sequence is:
        //   push "hello "     → <eval name> → add → push ", you are " → add
        //   → <eval age> → add → push "!" → add
        //
        // We detect end-of-template by checking templateNestLevel after the
        // tokenizer produces each TOK_TEMPLATE token: level > 0 means there
        // is a pending ${…} interpolation; level == 0 means the closing
        // backtick was consumed and this is the final text segment.

        var partCount = 0

        while !shouldAbort {
            // ---- text segment (always present, may be "") ----
            let textStr = s.token.strValue
            let jsStr = JeffJSString(swiftString: textStr)
            let cpoolIdx = addConstPoolValue(JeffJSValue.makeString(jsStr))
            emitPushConst(cpoolIdx)
            partCount += 1

            if !isTagged && partCount > 1 {
                emitOp(.add)
            }

            // If templateNestLevel == 0, the tokenizer consumed the closing
            // backtick while producing this token — there are no more parts.
            if s.templateNestLevel <= 0 {
                break
            }

            // ---- interpolated expression ----
            next() // advance past the TOK_TEMPLATE to the first expression token

            // Zero templateNestLevel so nested { } inside the expression
            // (e.g. object literals like `${{}}`) are treated as normal
            // braces by the tokenizer instead of prematurely closing the
            // interpolation. Nested template literals within the expression
            // will increment/decrement their own levels correctly.
            let savedNestLevel = s.templateNestLevel
            s.templateNestLevel = 0

            let savedInTemplateExpr = inTemplateExpr
            inTemplateExpr = true
            // Template substitutions always use [+In] per ECMAScript spec
            let savedInFlagTmpl = inFlag
            inFlag = true
            parseExpression()
            inFlag = savedInFlagTmpl
            inTemplateExpr = savedInTemplateExpr
            partCount += 1

            if !isTagged {
                emitOp(.add)
            }

            // After parseExpression, the current token should be '}' which
            // closes the ${...} interpolation. Since we zeroed templateNestLevel,
            // the tokenizer produced it as a plain brace. Now manually
            // trigger template part parsing to get the next text segment.
            if tok == 0x7D { // '}'
                // Restore nesting level (decremented by 1 for the consumed ${)
                s.templateNestLevel = savedNestLevel > 0 ? savedNestLevel - 1 : 0
                _ = s.parseTemplatePart()
                // tok now reads s.token.type which parseTemplatePart set to TOK_TEMPLATE
            } else if tok == JSTokenType.TOK_TEMPLATE.rawValue {
                // The tokenizer may have already produced TOK_TEMPLATE
                // (e.g. if the expression didn't contain braces)
                s.templateNestLevel = savedNestLevel > 0 ? savedNestLevel - 1 : 0
            } else {
                s.templateNestLevel = savedNestLevel
                break
            }

            if tok != JSTokenType.TOK_TEMPLATE.rawValue {
                break
            }
        }

        next() // advance past the final TOK_TEMPLATE to the token after the literal
    }

    // =========================================================================
    // MARK: - Destructuring
    // =========================================================================

    /// Parse a destructuring binding pattern and emit bytecode.
    func parseDestructuringBinding(kind: DestructuringKind,
                                   isLexical: Bool = false,
                                   isConst: Bool = false) {
        if tok == 0x5B { // '['
            parseArrayDestructuring(kind: kind, isLexical: isLexical, isConst: isConst)
        } else if tok == 0x7B { // '{'
            parseObjectDestructuring(kind: kind, isLexical: isLexical, isConst: isConst)
        } else {
            syntaxError("expected destructuring pattern")
        }
    }

    /// Parse array destructuring: [a, b, ...rest] = expr
    func parseArrayDestructuring(kind: DestructuringKind,
                                 isLexical: Bool, isConst: Bool) {
        expect(0x5B) // '['

        // The value to destructure should be on the stack
        emitOp(.for_of_start) // create iterator

        var idx = 0
        while tok != 0x5D && tok != JSTokenType.TOK_EOF.rawValue && !shouldAbort {
            if tok == 0x2C { // ',' elision
                emitOp(.for_of_next)
                emitU8(0)
                // for_of_next already pushes: iter obj method value done
                emitOp(.drop) // drop done flag
                emitOp(.drop) // drop value (elision — we don't bind it)
                next()
                idx += 1
                continue
            }

            if tok == JSTokenType.TOK_ELLIPSIS.rawValue {
                // Rest element: collect all remaining iterator values into an array.
                // We can't use the .rest opcode here because it collects from
                // frame.argBuf (function arguments), not from an iterator.
                // Instead, emit a loop that calls for_of_next until done,
                // appending each value to a new array.
                next()

                // Determine the binding target before emitting code
                var restVarName: JSAtom = 0
                var restIsNestedPattern = false
                if tok == JSTokenType.TOK_IDENT.rawValue {
                    restVarName = s.token.identAtom
                    next()
                } else if tok == 0x5B || tok == 0x7B {
                    restIsNestedPattern = true
                }

                // Define the rest variable (or a temp for nested patterns)
                let restVarIdx: Int
                if restIsNestedPattern {
                    // Use anonymous temp var for nested destructuring
                    restVarIdx = defineVar(0, isConst: false, isLexical: false)
                } else {
                    restVarIdx = defineVar(restVarName, isConst: isConst, isLexical: isLexical)
                }

                // Create an empty array and store it in the rest variable
                emitOp(.array_from)
                emitU16(0)
                if isLexical && !restIsNestedPattern {
                    emitOp(.put_loc_check_init)
                } else {
                    emitOp(.put_loc)
                }
                emitU16(UInt16(restVarIdx))

                // Loop: call for_of_next, check done, append value to array
                let loopLabel = newLabel()
                let doneLabel = newLabel()

                emitLabel(loopLabel)

                // for_of_next: iter obj method -> iter obj method value done
                emitOp(.for_of_next)
                emitU8(0)

                // If done, jump out
                emitIfTrue(doneLabel)

                // Stack: ... iter obj method value
                // Load the rest array, swap with value, append, then drop
                emitOp(.get_loc)
                emitU16(UInt16(restVarIdx))
                emitOp(.swap) // stack: ... iter obj method restArr value
                emitOp(.append) // append pops value, peeks at restArr
                emitOp(.drop) // drop restArr from stack

                emitGoto(loopLabel)

                emitLabel(doneLabel)
                // Stack: ... iter obj method value(undefined)
                emitOp(.drop) // drop the undefined from the last for_of_next

                // For nested destructuring patterns, apply them to the rest array
                if restIsNestedPattern {
                    emitOp(.get_loc)
                    emitU16(UInt16(restVarIdx))
                    parseDestructuringBinding(kind: kind, isLexical: isLexical, isConst: isConst)
                }

                break
            }

            // Get next value from iterator.
            // for_of_next pushes: iter obj method value done
            emitOp(.for_of_next)
            emitU8(0)
            emitOp(.drop) // drop done flag — value is now on top

            if tok == JSTokenType.TOK_IDENT.rawValue {
                let varName = s.token.identAtom
                next()

                // Default value
                if tok == 0x3D { // '='
                    let endLabel = newLabel()
                    emitOp(.dup)
                    emitOp(.undefined)
                    emitOp(.strict_eq)
                    emitIfFalse(endLabel)
                    emitOp(.drop)
                    next()
                    parseAssignExpr()
                    emitLabel(endLabel)
                }

                if kind == .assignment {
                    // Assignment mode: write to existing variable
                    emitScopePutVar(varName, scopeLevel: fd.curScope)
                } else {
                    let varIdx = defineVar(varName, isConst: isConst, isLexical: isLexical)
                    if isLexical {
                        emitOp(.put_loc_check_init)
                    } else {
                        emitOp(.put_loc)
                    }
                    emitU16(UInt16(varIdx))
                }
            } else if tok == 0x5B || tok == 0x7B {
                parseDestructuringBinding(kind: kind, isLexical: isLexical, isConst: isConst)
            } else {
                syntaxError("expected identifier or pattern in destructuring")
            }

            idx += 1
            if tok == 0x2C { next() }
        }

        expect(0x5D) // ']'
        emitOp(.iterator_close) // close the iterator
    }

    /// Parse object destructuring: {a, b: c, ...rest} = expr
    func parseObjectDestructuring(kind: DestructuringKind,
                                  isLexical: Bool, isConst: Bool) {
        expect(0x7B) // '{'

        while tok != 0x7D && tok != JSTokenType.TOK_EOF.rawValue && !shouldAbort {
            if tok == JSTokenType.TOK_ELLIPSIS.rawValue {
                // Rest element
                next()
                emitOp(.copy_data_properties)
                emitU8(0)

                if tok == JSTokenType.TOK_IDENT.rawValue {
                    let varName = s.token.identAtom
                    next()
                    if kind == .assignment {
                        emitScopePutVar(varName, scopeLevel: fd.curScope)
                    } else {
                        let varIdx = defineVar(varName, isConst: isConst, isLexical: isLexical)
                        if isLexical {
                            emitOp(.put_loc_check_init)
                        } else {
                            emitOp(.put_loc)
                        }
                        emitU16(UInt16(varIdx))
                    }
                }
                break
            }

            var propAtom: JSAtom = 0
            var isComputed = false

            // Parse property name
            if tok == 0x5B { // '[' computed
                isComputed = true
                next()
                parseAssignExpr()
                expect(0x5D) // ']'
            } else if tok == JSTokenType.TOK_IDENT.rawValue {
                propAtom = s.token.identAtom
                next()
            } else if tok == JSTokenType.TOK_STRING.rawValue {
                propAtom = getAtom(s.token.strValue)
                next()
            } else if tok == JSTokenType.TOK_NUMBER.rawValue {
                propAtom = getAtom(String(s.token.numValue))
                next()
            } else if isKeywordToken(tok) {
                let kwName = keywordTokenName(tok)
                propAtom = getAtom(kwName)
                next()
            } else {
                syntaxError("expected property name in destructuring")
                return
            }

            if tok == 0x3A { // ':' -- different binding name
                next()
                emitOp(.dup)
                if isComputed {
                    emitOp(.get_array_el)
                } else {
                    emitGetField(propAtom)
                }

                if tok == 0x5B || tok == 0x7B {
                    parseDestructuringBinding(kind: kind, isLexical: isLexical, isConst: isConst)
                } else if tok == JSTokenType.TOK_IDENT.rawValue {
                    let varName = s.token.identAtom
                    next()

                    // Default value
                    if tok == 0x3D { // '='
                        let endLabel = newLabel()
                        emitOp(.dup)
                        emitOp(.undefined)
                        emitOp(.strict_eq)
                        emitIfFalse(endLabel)
                        emitOp(.drop)
                        next()
                        parseAssignExpr()
                        emitLabel(endLabel)
                    }

                    if kind == .assignment {
                        emitScopePutVar(varName, scopeLevel: fd.curScope)
                    } else {
                        let varIdx = defineVar(varName, isConst: isConst, isLexical: isLexical)
                        if isLexical {
                            emitOp(.put_loc_check_init)
                        } else {
                            emitOp(.put_loc)
                        }
                        emitU16(UInt16(varIdx))
                    }
                } else {
                    syntaxError("expected identifier or pattern")
                }
            } else {
                // Shorthand: { x } or { x = default }
                emitOp(.dup)
                if !isComputed {
                    emitGetField(propAtom)
                } else {
                    emitOp(.get_array_el)
                }

                // Default value
                if tok == 0x3D { // '='
                    let endLabel = newLabel()
                    emitOp(.dup)
                    emitOp(.undefined)
                    emitOp(.strict_eq)
                    emitIfFalse(endLabel)
                    emitOp(.drop)
                    next()
                    parseAssignExpr()
                    emitLabel(endLabel)
                }

                if kind == .assignment {
                    emitScopePutVar(propAtom, scopeLevel: fd.curScope)
                } else {
                    let varIdx = defineVar(propAtom, isConst: isConst, isLexical: isLexical)
                    if isLexical {
                        emitOp(.put_loc_check_init)
                    } else {
                        emitOp(.put_loc)
                    }
                    emitU16(UInt16(varIdx))
                }
            }

            if tok == 0x2C { next() }
        }

        expect(0x7D) // '}'
        emitOp(.drop) // drop the original object from the stack
    }

    // =========================================================================
    // MARK: - Yield Expression
    // =========================================================================

    /// Parse: yield [* AssignmentExpression]
    ///      | yield [AssignmentExpression]
    func parseYieldExpression() {
        expect(JSTokenType.TOK_YIELD.rawValue)

        if s.gotLF || tok == 0x3B || tok == 0x7D || tok == 0x29 || tok == 0x5D ||
           tok == 0x3A || tok == 0x2C || tok == JSTokenType.TOK_EOF.rawValue {
            // yield without operand
            emitOp(.undefined)
            emitOp(.yield_)
            return
        }

        if tok == 0x2A { // '*'
            // yield*
            next()
            parseAssignExpr()
            emitOp(.yield_star)
        } else {
            parseAssignExpr()
            emitOp(.yield_)
        }
    }

    // =========================================================================
    // MARK: - Await Expression
    // =========================================================================

    /// Parse: await UnaryExpression
    func parseAwaitExpression() {
        expect(JSTokenType.TOK_AWAIT.rawValue)
        parseUnaryExpr()
        emitOp(.await_)
    }
}
