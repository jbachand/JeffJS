// JeffJSBytecodeCache.swift
// JeffJS — Bytecode serialization, deserialization, and caching.
//
// Serializes compiled JeffJSFunctionBytecode to a portable [UInt8] format
// with atom remapping — bytecode is portable across runtimes.
//
// Like QuickJS's qjsc, atoms (property names, variable names) embedded in
// the bytecode stream are collected into an atom table during serialization
// and stored as strings. On deserialization, strings are re-interned in the
// target runtime and the bytecode is patched with the new atom IDs.

import Foundation

// MARK: - Serialization Format Constants

/// Magic bytes: "JFBC" (JeffJS Function ByteCode)
private let JFBC_MAGIC: UInt32 = 0x4A46_4243
/// Version 2: adds atom table for cross-runtime portability
/// 5: per-function source span + the script text (Function.prototype.toString)
/// 6: atom-table entries are tagged (u8 kind: 0 = JS_ATOM_NULL, 1 = string),
///    so the null atom no longer collapses onto the empty-string atom.
private let JFBC_VERSION: UInt8 = 6

/// Magic bytes for a *disk cache entry*: "JBCK" (JeffJS ByteCode Key).
/// A disk entry is this header followed by the JFBC blob. The blob format is
/// untouched, so a precompiled `.jfbc` produced by the polyfill generator
/// still loads through `evalPrecompiled`.
private let JBCK_MAGIC: UInt32 = 0x4A42_434B
/// Disk-entry header version. Bump when the header layout changes.
private let JBCK_HEADER_VERSION: UInt8 = 1

/// Atom-table entry kinds (v6+).
private let ATOM_ENTRY_NULL: UInt8 = 0
private let ATOM_ENTRY_STRING: UInt8 = 1

/// Constant pool entry tags
private let CPOOL_UNDEFINED: UInt8 = 0
private let CPOOL_NULL: UInt8 = 1
private let CPOOL_INT32: UInt8 = 2
private let CPOOL_FLOAT64: UInt8 = 3
private let CPOOL_BOOL_FALSE: UInt8 = 4
private let CPOOL_BOOL_TRUE: UInt8 = 5
private let CPOOL_STRING8: UInt8 = 6
private let CPOOL_STRING16: UInt8 = 7
private let CPOOL_FUNCTION: UInt8 = 8
/// Tagged-template site object: u32 part count, then per part the cooked
/// string (or undefined) and the raw string as nested cpool entries. Rebuilt
/// as a frozen array with a frozen `raw` array (JeffJSContext.newTemplateObject).
private let CPOOL_TEMPLATE: UInt8 = 9
/// BigInt literal: sign byte, then u32 limb count and that many u32 limbs
/// (little-endian magnitude, the JBigInt layout).
private let CPOOL_BIGINT: UInt8 = 10

// MARK: - Flag Packing

/// Pack boolean flags into a UInt16 bitmask.
private func packFlags(_ fb: JeffJSFunctionBytecode) -> UInt16 {
    var flags: UInt16 = 0
    if fb.isGenerator                   { flags |= 1 << 0 }
    if fb.isAsyncFunc                   { flags |= 1 << 1 }
    if fb.isArrow                       { flags |= 1 << 2 }
    if fb.hasPrototype                  { flags |= 1 << 3 }
    if fb.hasSimpleParameterList        { flags |= 1 << 4 }
    if fb.isDerivedClassConstructor     { flags |= 1 << 5 }
    if fb.needHomeObject                { flags |= 1 << 6 }
    if fb.isDirectOrIndirectEval        { flags |= 1 << 7 }
    if fb.superCallAllowed              { flags |= 1 << 8 }
    if fb.superAllowed                  { flags |= 1 << 9 }
    if fb.argumentsAllowed              { flags |= 1 << 10 }
    if fb.isStrictMode                  { flags |= 1 << 11 }
    if fb.hasDebug                      { flags |= 1 << 12 }
    if fb.readOnly                      { flags |= 1 << 13 }
    if fb.backtrace                     { flags |= 1 << 14 }
    // Direct-eval call sites follow the self-reference slot. Blobs without
    // one are byte-identical to before, so no compilerVersion bump.
    if fb.evalSites != nil              { flags |= 1 << 15 }
    return flags
}

/// Unpack boolean flags from a UInt16 bitmask.
private func unpackFlags(_ flags: UInt16, into fb: JeffJSFunctionBytecode) {
    fb.isGenerator                   = (flags & (1 << 0)) != 0
    fb.isAsyncFunc                   = (flags & (1 << 1)) != 0
    fb.isArrow                       = (flags & (1 << 2)) != 0
    fb.hasPrototype                  = (flags & (1 << 3)) != 0
    fb.hasSimpleParameterList        = (flags & (1 << 4)) != 0
    fb.isDerivedClassConstructor     = (flags & (1 << 5)) != 0
    fb.needHomeObject                = (flags & (1 << 6)) != 0
    fb.isDirectOrIndirectEval        = (flags & (1 << 7)) != 0
    fb.superCallAllowed              = (flags & (1 << 8)) != 0
    fb.superAllowed                  = (flags & (1 << 9)) != 0
    fb.argumentsAllowed              = (flags & (1 << 10)) != 0
    fb.isStrictMode                  = (flags & (1 << 11)) != 0
    fb.hasDebug                      = (flags & (1 << 12)) != 0
    fb.readOnly                      = (flags & (1 << 13)) != 0
    fb.backtrace                     = (flags & (1 << 14)) != 0
}

// MARK: - Opcode stream walking

/// One decoded instruction: how wide the opcode itself is, how many bytes
/// the whole instruction takes, and where its atom operand sits (if any).
private struct DecodedInstruction {
    let size: Int
    let atomOffset: Int?
}

/// Decode the instruction at `pc` the way the interpreter does.
///
/// Final bytecode is NOT a flat stream of one-byte opcodes: every opcode
/// whose raw value is >= 256 (`init_this`, `private_in`) is emitted as a
/// `0x00` prefix followed by the low byte (see
/// `JeffJSCompiler.readOpcodeFromBuf`). Reading `bc[pc]` directly decodes
/// that prefix as OP_invalid (size 1), so the walk lands on the low byte
/// and every following instruction is decoded at the wrong offset — atom
/// operands past that point are neither collected on write nor remapped on
/// read, and non-atom operand bytes get overwritten with table indices.
/// That is silent, per-function bytecode corruption that only shows up once
/// the blob is loaded into a runtime whose atom numbering differs from the
/// one that compiled it (a precompiled `.jfbc`, or a disk cache written by
/// an earlier process).
private func decodeInstruction(_ bc: [UInt8], _ pc: Int) -> DecodedInstruction? {
    guard pc < bc.count else { return nil }
    let b0 = bc[pc]
    let rawValue: Int
    let opWidth: Int
    if b0 != 0 {
        rawValue = Int(b0)
        opWidth = 1
    } else {
        guard pc + 1 < bc.count else { return nil }
        rawValue = 256 + Int(bc[pc + 1])
        opWidth = 2
    }
    guard rawValue < jeffJSOpcodeInfo.count else { return nil }
    let info = jeffJSOpcodeInfo[rawValue]
    let size = max(Int(info.size) + (opWidth - 1), 1)

    let atomOffset: Int?
    switch info.format {
    case .atom, .atom_u8, .atom_u16, .atom_label_u8, .atom_label_u16:
        atomOffset = pc + opWidth
    default:
        // Special case: get_loc8_get_field has loc8 at +1, atom at +2
        if rawValue == Int(JeffJSOpcode.get_loc8_get_field.rawValue) {
            atomOffset = pc + opWidth + 1
        } else {
            atomOffset = nil
        }
    }
    return DecodedInstruction(size: size, atomOffset: atomOffset)
}

/// The instruction boundaries and atom-operand offsets the atom-table walker
/// sees. Exposed for the bytecode-cache round-trip tests: this walk has to
/// agree instruction-for-instruction with the interpreter's decode, and a
/// disagreement is silent atom corruption rather than a crash, so it is worth
/// asserting directly instead of hoping a snippet happens to expose it.
enum JeffJSBytecodeWalk {

    /// Offset of the first byte of every instruction in `bc`.
    static func instructionBoundaries(_ bc: [UInt8]) -> [Int] {
        var out: [Int] = []
        var pc = 0
        while pc < bc.count {
            out.append(pc)
            guard let instr = decodeInstruction(bc, pc) else { pc += 1; continue }
            pc += instr.size
        }
        return out
    }

    /// Offset of every atom operand the writer rewrites and the reader remaps.
    static func atomOperandOffsets(_ bc: [UInt8]) -> [Int] {
        var out: [Int] = []
        var pc = 0
        while pc < bc.count {
            guard let instr = decodeInstruction(bc, pc) else { pc += 1; continue }
            if let off = instr.atomOffset, off + 3 < bc.count { out.append(off) }
            pc += instr.size
        }
        return out
    }
}

// MARK: - Atom Table Builder

/// Collects atoms from bytecode and builds a remapping table.
/// Walks the opcode stream using OpcodeInfo.format to find atom operands,
/// assigns each unique atom a sequential index, and rewrites the bytecode
/// in-place to use table indices instead of runtime atom IDs.
private struct AtomTableBuilder {

    /// Maps runtime atom ID → index in the atom table
    private var atomToIndex: [UInt32: UInt32] = [:]
    /// Ordered atom entries (index → string, or nil for JS_ATOM_NULL).
    ///
    /// The null atom is NOT the empty-string atom: `atomToString(0)` has no
    /// string to give, and writing it as `""` made it read back as the
    /// empty-string atom — two distinct runtime atoms collapsing onto one
    /// table slot, so a blob was not stable across deserialize → serialize.
    private(set) var atomEntries: [String?] = []

    /// Register an atom, returning its table index.
    mutating func intern(_ atomID: UInt32, rt: JeffJSRuntime) -> UInt32 {
        if let existing = atomToIndex[atomID] { return existing }
        let idx = UInt32(atomEntries.count)
        atomEntries.append(atomID == JS_ATOM_NULL ? nil : (rt.atomToString(atomID) ?? ""))
        atomToIndex[atomID] = idx
        return idx
    }

    /// Walk bytecode, collect all atom operands, and rewrite them to table indices.
    /// Returns the rewritten bytecode.
    mutating func rewriteBytecode(_ bc: [UInt8], rt: JeffJSRuntime) -> [UInt8] {
        var out = bc
        let len = bc.count
        var pc = 0

        while pc < len {
            guard let instr = decodeInstruction(bc, pc) else {
                // Unknown opcode — skip 1 byte (shouldn't happen in valid bytecode)
                pc += 1
                continue
            }
            if let offset = instr.atomOffset, offset + 3 < len {
                let oldAtom = readU32LE(out, offset)
                let newIdx = intern(oldAtom, rt: rt)
                writeU32LE(&out, offset, newIdx)
            }

            pc += instr.size
        }

        return out
    }
}

/// Read little-endian U32 from byte array.
private func readU32LE(_ data: [UInt8], _ pos: Int) -> UInt32 {
    UInt32(data[pos]) |
    (UInt32(data[pos + 1]) << 8) |
    (UInt32(data[pos + 2]) << 16) |
    (UInt32(data[pos + 3]) << 24)
}

/// Write little-endian U32 to byte array.
private func writeU32LE(_ data: inout [UInt8], _ pos: Int, _ val: UInt32) {
    data[pos]     = UInt8(val & 0xFF)
    data[pos + 1] = UInt8((val >> 8) & 0xFF)
    data[pos + 2] = UInt8((val >> 16) & 0xFF)
    data[pos + 3] = UInt8((val >> 24) & 0xFF)
}

// MARK: - Atom Remapper (Deserialization)

/// Remaps atom table indices in bytecode back to runtime atom IDs.
private struct AtomRemapper {

    /// Maps table index → runtime atom ID
    let indexToAtom: [UInt32]

    /// Walk bytecode and replace table indices with runtime atom IDs.
    /// Must decode instructions exactly the way `AtomTableBuilder`
    /// rewrote them, wide (`0x00`-prefixed) opcodes included.
    func remapBytecode(_ bc: inout [UInt8]) {
        let len = bc.count
        var pc = 0

        while pc < len {
            guard let instr = decodeInstruction(bc, pc) else {
                pc += 1
                continue
            }

            if let offset = instr.atomOffset, offset + 3 < len {
                let tableIdx = readU32LE(bc, offset)
                if tableIdx < indexToAtom.count {
                    writeU32LE(&bc, offset, indexToAtom[Int(tableIdx)])
                }
            }

            pc += instr.size
        }
    }
}

// MARK: - Serializer

/// Serializes a JeffJSFunctionBytecode to a portable byte array.
/// Atoms are stored as strings in an atom table — bytecode is cross-runtime portable.
struct JeffJSBytecodeSerializer {

    private var buf: [UInt8] = []
    private var atomTable: AtomTableBuilder

    /// Serialize a compiled function bytecode to bytes.
    /// Requires the runtime to resolve atom IDs to strings.
    static func serialize(_ fb: JeffJSFunctionBytecode, rt: JeffJSRuntime? = nil) -> [UInt8] {
        var s = JeffJSBytecodeSerializer(atomTable: AtomTableBuilder())
        s.writeFunctionBytecode(fb, rt: rt)

        // Append atom table at the end
        let atoms = s.atomTable.atomEntries
        s.writeU32(UInt32(atoms.count))
        for entry in atoms {
            if let str = entry {
                s.writeU8(ATOM_ENTRY_STRING)
                s.writeString(str)
            } else {
                s.writeU8(ATOM_ENTRY_NULL)
            }
        }

        // The script text, once for the whole function tree. Every function's
        // (start, len) above indexes into it, so a cache hit reproduces the
        // exact same `toString()` output as a fresh compile.
        if let src = fb.sourceText {
            s.writeU8(1)
            s.writeU32(UInt32(src.bytes.count))
            s.buf.append(contentsOf: src.bytes)
        } else {
            s.writeU8(0)
        }

        return s.buf
    }

    // MARK: Primitives

    private mutating func writeU8(_ v: UInt8) { buf.append(v) }

    private mutating func writeU16(_ v: UInt16) {
        buf.append(UInt8(v & 0xFF))
        buf.append(UInt8((v >> 8) & 0xFF))
    }

    private mutating func writeU32(_ v: UInt32) {
        buf.append(UInt8(v & 0xFF))
        buf.append(UInt8((v >> 8) & 0xFF))
        buf.append(UInt8((v >> 16) & 0xFF))
        buf.append(UInt8((v >> 24) & 0xFF))
    }

    private mutating func writeU64(_ v: UInt64) {
        writeU32(UInt32(v & 0xFFFF_FFFF))
        writeU32(UInt32((v >> 32) & 0xFFFF_FFFF))
    }

    private mutating func writeBytes(_ data: [UInt8]) {
        writeU32(UInt32(data.count))
        buf.append(contentsOf: data)
    }

    private mutating func writeString(_ s: String) {
        let utf8 = Array(s.utf8)
        writeU32(UInt32(utf8.count))
        buf.append(contentsOf: utf8)
    }

    // MARK: Function Bytecode

    private mutating func writeFunctionBytecode(_ fb: JeffJSFunctionBytecode, rt: JeffJSRuntime?) {
        // Header
        writeU32(JFBC_MAGIC)
        writeU8(JFBC_VERSION)
        writeU16(packFlags(fb))
        writeU16(fb.argCount)
        writeU16(fb.varCount)
        writeU16(fb.definedArgCount)
        // Function `name` atom, as an atom-table index (remapped on read).
        writeU32((rt != nil) ? atomTable.intern(fb.nameAtom, rt: rt!) : fb.nameAtom)
        writeU16(fb.stackSize)
        writeU16(fb.closureVarCount)
        writeU32(UInt32(fb.lineNum))
        writeU32(UInt32(fb.colNum))
        // Source span for Function.prototype.toString; the text itself is
        // written once for the whole tree, after the atom table.
        writeU32(UInt32(bitPattern: fb.sourceStart))
        writeU32(UInt32(bitPattern: fb.sourceLen))

        // Bytecode bytes — rewrite atom operands to table indices
        if let rt {
            let rewritten = atomTable.rewriteBytecode(fb.bytecode, rt: rt)
            writeBytes(rewritten)
        } else {
            // No runtime — write raw (same-runtime cache only)
            writeBytes(fb.bytecode)
        }

        // Filename (optional string)
        if let fn = fb.fileName {
            writeU8(1)
            let str: String
            if !fn.isWideChar, case .str8(let data) = fn.storage {
                str = String(bytes: data.prefix(fn.len), encoding: .isoLatin1) ?? ""
            } else if fn.isWideChar, case .str16(let data) = fn.storage {
                str = String(utf16CodeUnits: Array(data.prefix(fn.len)), count: min(fn.len, data.count))
            } else {
                str = ""
            }
            writeString(str)
        } else {
            writeU8(0)
        }

        // Constant pool
        writeU32(UInt32(fb.cpool.count))
        for val in fb.cpool {
            writeCpoolEntry(val, rt: rt)
        }
        // v3 trailer: closure variable descriptors (which parent slot each
        // var_ref binds) and the self-reference slot. Without them a
        // deserialized closure binds the wrong variables.
        writeU16(UInt16(fb.closureVarsList.count))
        for cv in fb.closureVarsList {
            let nameRef: UInt32 = (rt != nil) ? atomTable.intern(cv.varName, rt: rt!) : cv.varName
            writeU32(nameRef)
            var f: UInt8 = 0
            if cv.isLocal { f |= 1 }
            if cv.isArg { f |= 2 }
            if cv.isConst { f |= 4 }
            if cv.isLexical { f |= 8 }
            writeU8(f)
            writeU8(UInt8(truncatingIfNeeded: cv.varKind))
            writeU32(UInt32(bitPattern: Int32(truncatingIfNeeded: cv.varIdx)))
        }
        writeU32(UInt32(bitPattern: Int32(truncatingIfNeeded: fb.selfRefVarIdx)))
        if let sites = fb.evalSites {
            writeU16(UInt16(sites.count))
            for site in sites {
                writeU8(site.isStrict ? 1 : 0)
                writeU32(site.varEnvName == 0 ? UInt32.max
                         : ((rt != nil) ? atomTable.intern(site.varEnvName, rt: rt!) : site.varEnvName))
                writeU32(UInt32(site.items.count))
                for it in site.items {
                    writeU32((rt != nil) ? atomTable.intern(it.name, rt: rt!) : it.name)
                    var f: UInt8 = 0
                    if it.isLocal { f |= 1 }
                    if it.isArg { f |= 2 }
                    if it.isConst { f |= 4 }
                    if it.isLexical { f |= 8 }
                    if it.isDynamic { f |= 16 }
                    writeU8(f)
                    writeU8(UInt8(truncatingIfNeeded: it.varKind))
                    writeU8(it.region)
                    writeU32(UInt32(bitPattern: Int32(truncatingIfNeeded: it.idx)))
                }
            }
        }
    }

    // MARK: Constant Pool Entry

    private mutating func writeCpoolEntry(_ val: JeffJSValue, rt: JeffJSRuntime?) {
        if val.isUndefined {
            writeU8(CPOOL_UNDEFINED)
        } else if val.isNull {
            writeU8(CPOOL_NULL)
        } else if val.isBool {
            writeU8(val.toBool() ? CPOOL_BOOL_TRUE : CPOOL_BOOL_FALSE)
        } else if val.isInt {
            writeU8(CPOOL_INT32)
            writeU32(UInt32(bitPattern: val.toInt32()))
        } else if val.isBigInt {
            let b = val.bigIntValue
            writeU8(CPOOL_BIGINT)
            writeU8(b.negative ? 1 : 0)
            writeU32(UInt32(b.mag.count))
            for limb in b.mag { writeU32(limb) }
        } else if val.isNumber {
            writeU8(CPOOL_FLOAT64)
            writeU64(val.bits)
        } else if val.isString, let str = val.stringValue {
            if !str.isWideChar, case .str8(let data) = str.storage {
                writeU8(CPOOL_STRING8)
                let len = min(str.len, data.count)
                writeU32(UInt32(len))
                buf.append(contentsOf: data.prefix(len))
            } else if str.isWideChar, case .str16(let data) = str.storage {
                writeU8(CPOOL_STRING16)
                let len = min(str.len, data.count)
                writeU32(UInt32(len))
                for unit in data.prefix(len) {
                    writeU16(unit)
                }
            } else {
                writeU8(CPOOL_UNDEFINED)
            }
        } else if let fb = val.toFunctionBytecode() {
            // Nested function — recursive serialization (shares atom table)
            writeU8(CPOOL_FUNCTION)
            writeFunctionBytecode(fb, rt: rt)
        } else if let rt, val.isObject, let obj = val.toObject(),
                  let cooked = obj.arraySnapshot(),
                  let rawObj = obj.getOwnPropertyValue(atom: rt.findAtom("raw")).toObject(),
                  let raw = rawObj.arraySnapshot() {
            // The only objects the parser puts in a cpool are tagged-template objects.
            writeU8(CPOOL_TEMPLATE)
            writeU32(UInt32(cooked.count))
            for i in 0..<cooked.count {
                writeCpoolEntry(cooked.values[i], rt: rt)
                writeCpoolEntry(i < raw.count ? raw.values[i] : .JS_UNDEFINED, rt: rt)
            }
        } else {
            writeU8(CPOOL_UNDEFINED)
        }
    }
}

// MARK: - Deserializer

/// Deserializes bytes into a fresh JeffJSFunctionBytecode with new cpool values.
/// If a runtime is provided, atom table indices are remapped to the runtime's atom IDs.
struct JeffJSBytecodeDeserializer {

    private let data: [UInt8]
    private var pos: Int = 0
    private var remapper: AtomRemapper?
    /// Script text shared by every function in this blob (trailer, v5+).
    private var sourceText: JeffJSSourceText?
    /// Needed to rebuild tagged-template objects; without one, bytecode
    /// containing a tagged template fails to deserialize (cache miss).
    private var ctx: JeffJSContext?

    /// Deserialize bytes into a fresh function bytecode.
    /// If rt is provided, atoms are re-interned for cross-runtime portability.
    static func deserialize(_ data: [UInt8], rt: JeffJSRuntime? = nil,
                            ctx: JeffJSContext? = nil) -> JeffJSFunctionBytecode? {
        var d = JeffJSBytecodeDeserializer(data: data)
        d.ctx = ctx

        // Peek at version to decide whether atom table is present
        if data.count > 5 && data[4] >= 2, let rt {
            // Version 2+: read atom table from end, build remapper
            d.remapper = d.buildRemapper(rt: rt)
        }

        // v5 trailer: the script text, shared by every function below.
        d.sourceText = d.readTrailingSource()

        d.pos = 0
        return d.readFunctionBytecode()
    }

    /// Scan to the end of all function bytecodes to find the atom table.
    private mutating func buildRemapper(rt: JeffJSRuntime) -> AtomRemapper? {
        // The atom table is appended after all function bytecodes.
        // We need to skip through to find it. Use a simple approach:
        // scan from the current position, skip each function bytecode, then read the atom table.
        var scanPos = 0
        guard skipFunctionBytecode(data: data, pos: &scanPos) else { return nil }

        // Now at atom table
        guard scanPos + 3 < data.count else { return nil }
        let atomCount = readU32At(scanPos)
        scanPos += 4

        var indexToAtom: [UInt32] = []
        indexToAtom.reserveCapacity(Int(atomCount))
        for _ in 0..<atomCount {
            guard scanPos < data.count else { return nil }
            let kind = data[scanPos]
            scanPos += 1
            if kind == ATOM_ENTRY_NULL {
                indexToAtom.append(JS_ATOM_NULL)
                continue
            }
            guard scanPos + 3 < data.count else { return nil }
            let strLen = Int(readU32At(scanPos))
            scanPos += 4
            guard scanPos + strLen <= data.count else { return nil }
            let strBytes = Array(data[scanPos..<(scanPos + strLen)])
            scanPos += strLen
            let str = String(bytes: strBytes, encoding: .utf8) ?? ""
            let atomID = rt.findAtom(str)
            indexToAtom.append(atomID)
        }

        return AtomRemapper(indexToAtom: indexToAtom)
    }

    /// Skip the function tree and the atom table to reach the shared script
    /// text written by the serializer, and decode it.
    private func readTrailingSource() -> JeffJSSourceText? {
        var p = 0
        guard skipFunctionBytecode(data: data, pos: &p) else { return nil }
        guard p + 3 < data.count else { return nil }
        let atomCount = Int(readU32LE(data, p))
        p += 4
        for _ in 0..<atomCount {
            guard p < data.count else { return nil }
            let kind = data[p]
            p += 1
            if kind == ATOM_ENTRY_NULL { continue }
            guard p + 3 < data.count else { return nil }
            let strLen = Int(readU32LE(data, p))
            p += 4 + strLen
            guard p <= data.count else { return nil }
        }
        guard p < data.count, data[p] == 1 else { return nil }
        p += 1
        guard p + 3 < data.count else { return nil }
        let srcLen = Int(readU32LE(data, p))
        p += 4
        guard p + srcLen <= data.count else { return nil }
        return JeffJSSourceText(bytes: Array(data[p ..< (p + srcLen)]))
    }

    /// Read U32 at a specific position without advancing pos.
    private func readU32At(_ p: Int) -> UInt32 {
        readU32LE(data, p)
    }

    /// Skip past a serialized function bytecode (for finding atom table).
    private func skipFunctionBytecode(data: [UInt8], pos: inout Int) -> Bool {
        // Magic(4) + Version(1) + Flags(2) + argCount(2) + varCount(2) +
        // definedArgCount(2) + nameAtom(4) + stackSize(2) + closureVarCount(2) +
        // lineNum(4) + colNum(4) + sourceStart(4) + sourceLen(4)
        let headerSize = 4 + 1 + 2 + 2 + 2 + 2 + 4 + 2 + 2 + 4 + 4 + 4 + 4
        guard pos + headerSize <= data.count else { return false }
        let flags = Int(data[pos + 5]) | (Int(data[pos + 6]) << 8)
        pos += headerSize

        // Bytecode bytes: length(4) + data
        guard pos + 3 < data.count else { return false }
        let bcLen = Int(readU32LE(data, pos))
        pos += 4 + bcLen

        // Filename: hasFlag(1) + optional string
        guard pos < data.count else { return false }
        let hasFilename = data[pos]
        pos += 1
        if hasFilename == 1 {
            guard pos + 3 < data.count else { return false }
            let fnLen = Int(readU32LE(data, pos))
            pos += 4 + fnLen
        }

        // Constant pool
        guard pos + 3 < data.count else { return false }
        let cpoolCount = Int(readU32LE(data, pos))
        pos += 4
        for _ in 0..<cpoolCount {
            guard pos < data.count else { return false }
            guard skipCpoolEntry(data: data, pos: &pos) else { return false }
        }
        // v3 trailer: u16 count + (u32 name, u8 flags, u8 kind, u32 idx) per entry, u32 selfRef
        guard pos + 1 < data.count else { return false }
        let cvCount = Int(data[pos]) | (Int(data[pos + 1]) << 8)
        pos += 2 + cvCount * 10 + 4
        // Direct-eval call sites: u16 count, then per site u8 strict,
        // u32 varEnvName, u32 item count, 11 bytes per item.
        if flags & (1 << 15) != 0 {
            guard pos + 1 < data.count else { return false }
            let siteCount = Int(data[pos]) | (Int(data[pos + 1]) << 8)
            pos += 2
            for _ in 0 ..< siteCount {
                guard pos + 8 < data.count else { return false }
                let items = Int(readU32LE(data, pos + 5))
                pos += 9 + items * 11
            }
        }

        return pos <= data.count
    }

    /// Skip a single cpool entry.
    private func skipCpoolEntry(data: [UInt8], pos: inout Int) -> Bool {
        guard pos < data.count else { return false }
        let tag = data[pos]
        pos += 1
        switch tag {
        case CPOOL_UNDEFINED, CPOOL_NULL, CPOOL_BOOL_FALSE, CPOOL_BOOL_TRUE:
            break
        case CPOOL_INT32:
            pos += 4
        case CPOOL_FLOAT64:
            pos += 8
        case CPOOL_BIGINT:
            guard pos + 4 < data.count else { return false }
            let limbs = Int(readU32LE(data, pos + 1))
            pos += 5 + limbs * 4
        case CPOOL_STRING8:
            guard pos + 3 < data.count else { return false }
            let len = Int(readU32LE(data, pos))
            pos += 4 + len
        case CPOOL_STRING16:
            guard pos + 3 < data.count else { return false }
            let len = Int(readU32LE(data, pos))
            pos += 4 + len * 2
        case CPOOL_FUNCTION:
            return skipFunctionBytecode(data: data, pos: &pos)
        case CPOOL_TEMPLATE:
            guard pos + 3 < data.count else { return false }
            let count = Int(readU32LE(data, pos))
            pos += 4
            for _ in 0..<(count * 2) {
                guard skipCpoolEntry(data: data, pos: &pos) else { return false }
            }
        default:
            break
        }
        return true
    }

    // MARK: Primitives

    private mutating func readU8() -> UInt8? {
        guard pos < data.count else { return nil }
        let v = data[pos]; pos += 1; return v
    }

    private mutating func readU16() -> UInt16? {
        guard pos + 1 < data.count else { return nil }
        let v = UInt16(data[pos]) | (UInt16(data[pos + 1]) << 8)
        pos += 2; return v
    }

    /// An atom operand as written by the serializer: a table index when a
    /// remapper is present, else the raw atom.
    private func remapAtomRef(_ ref: UInt32) -> JSAtom? {
        guard let remapper else { return ref }
        guard Int(ref) < remapper.indexToAtom.count else { return nil }
        return remapper.indexToAtom[Int(ref)]
    }

    private mutating func readU32() -> UInt32? {
        guard pos + 3 < data.count else { return nil }
        let v = UInt32(data[pos]) | (UInt32(data[pos+1]) << 8) |
                (UInt32(data[pos+2]) << 16) | (UInt32(data[pos+3]) << 24)
        pos += 4; return v
    }

    private mutating func readU64() -> UInt64? {
        guard let lo = readU32(), let hi = readU32() else { return nil }
        return UInt64(lo) | (UInt64(hi) << 32)
    }

    private mutating func readBytes() -> [UInt8]? {
        guard let len = readU32() else { return nil }
        let count = Int(len)
        guard pos + count <= data.count else { return nil }
        let bytes = Array(data[pos..<(pos + count)])
        pos += count
        return bytes
    }

    private mutating func readString() -> String? {
        guard let utf8 = readBytes() else { return nil }
        return String(bytes: utf8, encoding: .utf8)
    }

    // MARK: Function Bytecode

    private mutating func readFunctionBytecode() -> JeffJSFunctionBytecode? {
        // Header
        guard let magic = readU32(), magic == JFBC_MAGIC else { return nil }
        guard let version = readU8(), version == JFBC_VERSION else { return nil }   // older layouts lack the function source span / tagged atom table
        guard let flags = readU16() else { return nil }
        guard let argCount = readU16() else { return nil }
        guard let varCount = readU16() else { return nil }
        guard let definedArgCount = readU16() else { return nil }
        guard let nameRef = readU32() else { return nil }
        guard let stackSize = readU16() else { return nil }
        guard let closureVarCount = readU16() else { return nil }
        guard let lineNum = readU32() else { return nil }
        guard let colNum = readU32() else { return nil }
        guard let sourceStartRaw = readU32() else { return nil }
        guard let sourceLenRaw = readU32() else { return nil }

        // Bytecode bytes
        guard var bytecode = readBytes() else { return nil }

        // Remap atom table indices → runtime atom IDs
        if version >= 2, let remapper {
            remapper.remapBytecode(&bytecode)
        }

        // Filename
        guard let hasFilename = readU8() else { return nil }
        var fileName: JeffJSString? = nil
        if hasFilename == 1 {
            guard let fnStr = readString() else { return nil }
            fileName = JeffJSString(swiftString: fnStr)
        }

        // Constant pool
        guard let cpoolCount = readU32() else { return nil }
        var cpool: [JeffJSValue] = []
        cpool.reserveCapacity(Int(cpoolCount))
        for _ in 0..<cpoolCount {
            guard let val = readCpoolEntry() else { return nil }
            cpool.append(val)
        }

        // v3 trailer: closure variable descriptors + self-reference slot
        guard let cvCount = readU16() else { return nil }
        var closureVars: [JeffJSClosureVar] = []
        closureVars.reserveCapacity(Int(cvCount))
        for _ in 0..<cvCount {
            guard let nameRef = readU32(), let f = readU8(), let kind = readU8(),
                  let idxRaw = readU32() else { return nil }
            var cv = JeffJSClosureVar()
            if let remapper {
                guard Int(nameRef) < remapper.indexToAtom.count else { return nil }
                cv.varName = remapper.indexToAtom[Int(nameRef)]
            } else {
                cv.varName = nameRef
            }
            cv.isLocal = (f & 1) != 0
            cv.isArg = (f & 2) != 0
            cv.isConst = (f & 4) != 0
            cv.isLexical = (f & 8) != 0
            cv.varKind = Int(kind)
            cv.varIdx = Int(Int32(bitPattern: idxRaw))
            closureVars.append(cv)
        }
        guard let selfRefRaw = readU32() else { return nil }
        var evalSites: [JeffJSEvalSite]? = nil
        if flags & (1 << 15) != 0 {
            guard let siteCount = readU16() else { return nil }
            var sites: [JeffJSEvalSite] = []
            for _ in 0 ..< siteCount {
                guard let strict = readU8(), let envRef = readU32(), let itemCount = readU32() else { return nil }
                let site = JeffJSEvalSite()
                site.isStrict = strict != 0
                if envRef != UInt32.max {
                    guard let a = remapAtomRef(envRef) else { return nil }
                    site.varEnvName = a
                }
                for _ in 0 ..< itemCount {
                    guard let nameRef = readU32(), let f = readU8(), let kind = readU8(),
                          let region = readU8(), let idxRaw = readU32(),
                          let name = remapAtomRef(nameRef) else { return nil }
                    var it = JeffJSEvalItem()
                    it.name = name
                    it.isLocal = (f & 1) != 0
                    it.isArg = (f & 2) != 0
                    it.isConst = (f & 4) != 0
                    it.isLexical = (f & 8) != 0
                    it.isDynamic = (f & 16) != 0
                    it.varKind = Int(kind)
                    it.region = region
                    it.idx = Int(Int32(bitPattern: idxRaw))
                    site.items.append(it)
                }
                sites.append(site)
            }
            evalSites = sites
        }

        // Construct fresh JeffJSFunctionBytecode
        let fb = JeffJSFunctionBytecode()
        fb.bytecode = bytecode
        fb.bytecodeLen = bytecode.count
        fb.argCount = argCount
        fb.varCount = varCount
        fb.definedArgCount = definedArgCount
        if let remapper, Int(nameRef) < remapper.indexToAtom.count {
            fb.nameAtom = remapper.indexToAtom[Int(nameRef)]
        } else {
            fb.nameAtom = nameRef
        }
        fb.stackSize = stackSize
        fb.closureVarCount = closureVarCount
        fb.lineNum = Int(lineNum)
        fb.colNum = Int(colNum)
        fb.fileName = fileName
        fb.cpool = cpool
        fb.sourceText = sourceText
        fb.sourceStart = Int32(bitPattern: sourceStartRaw)
        fb.sourceLen = Int32(bitPattern: sourceLenRaw)
        unpackFlags(flags, into: fb)
        fb.closureVarsList = closureVars
        fb.selfRefVarIdx = Int(Int32(bitPattern: selfRefRaw))
        fb.evalSites = evalSites
        // Trace regions are derived from the final bytecode (not stored):
        // recompute them so cached code runs with the same loop traces.
        JeffJSCompiler.fuseBasicBlocks(fb)
        JeffJSCompiler.computeArgSlotOwnership(fb)

        return fb
    }

    // MARK: Constant Pool Entry

    private mutating func readCpoolEntry() -> JeffJSValue? {
        guard let tag = readU8() else { return nil }

        switch tag {
        case CPOOL_UNDEFINED:
            return .JS_UNDEFINED

        case CPOOL_NULL:
            return .null

        case CPOOL_INT32:
            guard let raw = readU32() else { return nil }
            return .newInt32(Int32(bitPattern: raw))

        case CPOOL_FLOAT64:
            guard let bits = readU64() else { return nil }
            return .newFloat64(Double(bitPattern: bits))

        case CPOOL_BIGINT:
            guard let signByte = readU8(), let count = readU32() else { return nil }
            var mag: [UInt32] = []
            mag.reserveCapacity(Int(count))
            for _ in 0..<Int(count) {
                guard let limb = readU32() else { return nil }
                mag.append(limb)
            }
            return JeffJSValue.newBigInt(JBigInt(negative: signByte != 0, mag: mag))

        case CPOOL_BOOL_FALSE:
            return .newBool(false)

        case CPOOL_BOOL_TRUE:
            return .newBool(true)

        case CPOOL_STRING8:
            guard let len = readU32() else { return nil }
            let count = Int(len)
            guard pos + count <= data.count else { return nil }
            let bytes = Array(data[pos..<(pos + count)])
            pos += count
            let str = JeffJSString(
                refCount: 1,
                len: count,
                isWideChar: false,
                storage: .str8(bytes)
            )
            return JeffJSValue.makeString(str)

        case CPOOL_STRING16:
            guard let len = readU32() else { return nil }
            let count = Int(len)
            guard pos + count * 2 <= data.count else { return nil }
            var units: [UInt16] = []
            units.reserveCapacity(count)
            for _ in 0..<count {
                guard let unit = readU16() else { return nil }
                units.append(unit)
            }
            let str = JeffJSString(
                refCount: 1,
                len: count,
                isWideChar: true,
                storage: .str16(units)
            )
            return JeffJSValue.makeString(str)

        case CPOOL_FUNCTION:
            guard let nested = readFunctionBytecode() else { return nil }
            return JeffJSValue.makeFunctionBytecode(nested)

        case CPOOL_TEMPLATE:
            guard let count = readU32() else { return nil }
            var cooked: [JeffJSValue] = []
            var raw: [JeffJSValue] = []
            for _ in 0..<Int(count) {
                guard let c = readCpoolEntry(), let r = readCpoolEntry() else { return nil }
                cooked.append(c)
                raw.append(r)
            }
            guard let ctx else { return nil }
            return ctx.newTemplateObject(cooked: cooked, raw: raw)

        default:
            return .JS_UNDEFINED
        }
    }
}

// MARK: - Cache Key

/// Everything about a compile that can change the bytes of a cached blob, or
/// the behaviour of the code those bytes run.
///
/// The key used to be `FNV-1a(source) ^ compilerVersion` and nothing else, so
/// two evals of byte-identical source text shared one blob even when they were
/// compiled differently:
///
///   * `evalFlags` — script vs module (`JS_EVAL_TYPE_MASK`), strict vs sloppy
///     (`JS_EVAL_FLAG_STRICT`, which sets `fd.jsMode = JS_MODE_STRICT` and
///     changes scoping, `this`, and what the parser even accepts), plus the
///     backtrace-barrier / async / compile-only bits;
///   * `filename` — it is written into the blob (`fb.fileName`, read back by
///     `buildStackTrace`), so a hit under a different filename reports the
///     *other* page's file in every stack frame;
///   * the codegen toggles (`optimize.enabled`, `optimize.shortOpcodes`) and
///     the limits the compiler emits against (`stack.maxLocalVars`,
///     `stack.maxStackSize`);
///   * the blob format version itself (`JFBC_VERSION`).
///
/// All of them are folded in here.
struct JeffJSBytecodeCacheKey {
    /// FNV-1a over `desc`, a separator, then the source bytes.
    let hash: UInt64
    /// Canonical rendering of every compile input except the source text.
    /// Stored verbatim in the disk entry header and compared on load, so a
    /// 64-bit collision (or a file left by a differently-configured build) is
    /// rejected instead of executed.
    let desc: String
    /// Source length in UTF-8 bytes; also checked on load.
    let sourceLength: Int
}

// MARK: - Bytecode Cache

/// Per-runtime bytecode cache with disk persistence. Stores serialized
/// bytecode keyed by a `JeffJSBytecodeCacheKey` (source + flags + config +
/// filename), not by the source text alone.
///
/// Atom remapping (v2 format) makes bytecode portable across runtimes,
/// so disk-cached bytecode survives app relaunches and even CLI precompilation.
///
/// The cache is stored on JeffJSRuntime and shared across all contexts in
/// that runtime.
final class JeffJSBytecodeCache {

    /// One cached compile. `desc`/`sourceLength` are the in-memory equivalent
    /// of the disk entry header: the same mismatch check runs on both paths,
    /// so the two caches can never disagree about what a key means.
    struct Entry {
        let desc: String
        let sourceLength: Int
        let blob: [UInt8]
    }

    /// Serialized bytecode keyed by the cache key's hash.
    private var cache: [UInt64: Entry] = [:]

    /// Maximum cached entries.
    private let maxEntries = 512

    /// Number of cache hits (in-memory).
    private(set) var hitCount: Int = 0

    /// Number of cache hits from disk.
    private(set) var diskHitCount: Int = 0

    /// Lookups that found nothing.
    private(set) var missCount: Int = 0

    /// Lookups that found an entry and refused it (header/key mismatch, or a
    /// blob that would not deserialize).
    private(set) var rejectCount: Int = 0

    /// Why the last rejection happened — surfaced for tests and for
    /// `cache.bytecodeDebug` logging.
    private(set) var lastRejectReason: String?

    /// Runtime for atom remapping during deserialization.
    ///
    /// unowned(unsafe), not weak: a weak reference to the runtime forces a
    /// side-table entry on it, after which EVERY retain/release of the runtime
    /// (one pair per interpreter call for `ctx.rt`, one per GC object
    /// creation for `ownerRuntime`) takes the slow path. The cache is owned by
    /// the runtime, so it can never outlive it.
    unowned(unsafe) var rt: JeffJSRuntime?

    // MARK: - Debug Logging

    /// `cache.bytecodeDebug` (env `JEFFJS_CACHE_BYTECODEDEBUG=1`). Read once.
    static let debugLogging = JeffJSConfig.bytecodeDebug

    /// One line per hit / miss / reject / store, on stderr so a host app's
    /// console picks it up. Compiled to a flag test when the flag is off.
    @inline(__always)
    func debugLog(_ message: @autoclosure () -> String) {
        guard Self.debugLogging else { return }
        writeDebugLine(message())
    }

    @inline(never)
    private func writeDebugLine(_ message: String) {
        FileHandle.standardError.write(Data("[jeffjs:bccache] \(message)\n".utf8))
    }

    private func reject(_ reason: String, _ key: JeffJSBytecodeCacheKey) {
        rejectCount += 1
        lastRejectReason = reason
        debugLog("reject (\(reason)) key=\(key.desc) srcLen=\(key.sourceLength)")
    }

    // MARK: - Disk Cache

    /// Bump when the *disk entry* layout changes (it names the cache
    /// subdirectory, so old entries are simply never looked at again).
    /// 4 = entries carry a JBCK header (compiler version, key hash, source
    ///     length, canonical flags/config/filename string).
    private static let diskVersion: UInt32 = 4

    /// Bump when parser or compiler logic changes (bug fixes, new opcodes, etc.).
    /// This is mixed into the cache key so cached bytecode from an older compiler
    /// is never reused. Bump this number after ANY change to:
    ///   - JeffJSParser.swift (parsing, bytecode emission)
    ///   - JeffJSCompiler.swift (resolveLabels, resolveVariables, peephole)
    ///   - JeffJSOpcodes.swift (opcode additions/changes)
    ///   - JeffJSInterpreter.swift (only if opcode semantics change)
    // 11 = merge of two independent bumps to 10, each a distinct format change:
    //   10a (feat/function-tostring): per-function source span (start,len) + the
    //       script text stored once per blob -> JFBC v5, for Function.prototype.toString.
    //   10b (feat/bigint): CPOOL_BIGINT constant-pool entry kind (n-suffix literals,
    //       BigInt-aware arithmetic opcodes).
    // Both are present here, so neither 10 is a valid description of this format.
    // 12 = JFBC v6. Two fixes to the atom table, both of which change the bytes:
    //   - the opcode walk that finds atom operands now decodes wide
    //     (0x00-prefixed) opcodes, so atoms after an `init_this` /
    //     `private_in` are collected and remapped instead of being left as
    //     raw atom IDs of whichever runtime compiled the blob;
    //   - atom-table entries carry a kind byte, so JS_ATOM_NULL (an
    //     anonymous function's `name`) no longer reads back as the
    //     empty-string atom.
    // Still 12: the cache-key fix below changes the *entry* layout (diskVersion
    // 3 -> 4), not the JFBC blob, which precompiled bundles also use.
    // 13 = generators emit `initial_yield` after FunctionDeclarationInstantiation
    //   and the call runs up to it; a v12 generator body (no initial_yield)
    //   would run to completion at call time.
    // 14 = method calls decided by the parser only: `(0, o.m)()` and
    //   `(a || o.m)()` no longer compile to get_field2 + call_method.
    static let compilerVersion: UInt64 = 14  // 2026-09-24: no get_field+call rewrite

    /// Lazily-initialized disk cache directory.
    /// Automatically clears cached .jfbc files when the app binary changes (new build).
    private static let diskCacheDir: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("JeffJSBytecodeCache/v\(diskVersion)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Detect new build by checking executable modification date
        let stampFile = dir.appendingPathComponent(".build_stamp")
        let currentStamp: String
        if let execURL = Bundle.main.executableURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
           let modDate = attrs[.modificationDate] as? Date {
            currentStamp = String(Int(modDate.timeIntervalSince1970))
        } else {
            currentStamp = "unknown"
        }
        let savedStamp = (try? String(contentsOf: stampFile, encoding: .utf8)) ?? ""
        if savedStamp != currentStamp {
            // Build changed — purge all cached bytecode
            if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "jfbc" {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            try? currentStamp.write(to: stampFile, atomically: true, encoding: .utf8)
        }

        return dir
    }()

    private func diskURL(for hash: UInt64) -> URL? {
        Self.diskCacheDir?.appendingPathComponent("\(hash).jfbc")
    }

    /// The file a key maps to. Exposed for tests (header-rejection,
    /// concurrent-writer) and for host-side cache inspection.
    func diskEntryURL(for key: JeffJSBytecodeCacheKey) -> URL? {
        diskURL(for: key.hash)
    }

    // MARK: - Hashing

    /// Canonical string for every compile input that is *not* the source text.
    ///
    /// Anything appended here must be something that changes the emitted
    /// bytecode or the behaviour of running it; anything that changes the blob
    /// bytes but not behaviour (nothing today) could instead be stored in the
    /// blob and left out.
    static func keyDescription(filename: String, evalFlags: Int) -> String {
        var s = "cv=\(compilerVersion);jfbc=\(JFBC_VERSION);"
        // Eval flags: every bit that reaches the parser or the compiler.
        // `et` is script(0)/module(1)/direct(2)/indirect(3) — module flips
        // `isModule`, which turns off HTML comments and forces strict mode.
        s += "et=\(evalFlags & JS_EVAL_TYPE_MASK);"
        s += "strict=\((evalFlags & JS_EVAL_FLAG_STRICT) != 0 ? 1 : 0);"
        s += "bbarrier=\((evalFlags & JS_EVAL_FLAG_BACKTRACE_BARRIER) != 0 ? 1 : 0);"
        s += "async=\((evalFlags & JS_EVAL_FLAG_ASYNC) != 0 ? 1 : 0);"
        s += "compileOnly=\((evalFlags & JS_EVAL_FLAG_COMPILE_ONLY) != 0 ? 1 : 0);"
        // Codegen toggles and the limits the compiler emits against.
        s += "opt=\(JEFFJS_OPTIMIZE ? 1 : 0);short=\(JEFFJS_SHORT_OPCODES ? 1 : 0);"
        s += "mlv=\(JS_MAX_LOCAL_VARS);mss=\(JS_STACK_SIZE_MAX);"
        // The filename lands in the blob and comes back out in stack traces.
        s += "fn=\(filename)"
        return s
    }

    /// Build the full cache key for one compile.
    static func key(source: String, filename: String, evalFlags: Int) -> JeffJSBytecodeCacheKey {
        let desc = keyDescription(filename: filename, evalFlags: evalFlags)
        var hash: UInt64 = 0xcbf29ce484222325
        hash ^= compilerVersion
        hash &*= 0x100000001b3
        for byte in desc.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        // Separator: `desc` never contains a 0 byte, so no source text can
        // impersonate a different desc.
        hash ^= 0
        hash &*= 0x100000001b3
        var length = 0
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
            length &+= 1
        }
        return JeffJSBytecodeCacheKey(hash: hash, desc: desc, sourceLength: length)
    }

    /// FNV-1a 64-bit hash of source text alone, seeded with the compiler
    /// version. NOT the cache key — kept because the precompiled-polyfill
    /// generator prints it as a build-time fingerprint.
    static func hashSource(_ source: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        hash ^= compilerVersion
        hash &*= 0x100000001b3
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }

    // MARK: - Disk Entry Header

    /// `JBCK` header + the JFBC blob:
    ///   u32 magic | u8 headerVersion | u64 compilerVersion | u64 keyHash
    ///   | u32 sourceLength | u32 descLength | desc bytes | blob bytes
    static func makeEntry(key: JeffJSBytecodeCacheKey, blob: [UInt8]) -> [UInt8] {
        let desc = Array(key.desc.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(29 + desc.count + blob.count)
        func put32(_ v: UInt32) { for i in 0..<4 { out.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
        func put64(_ v: UInt64) { for i in 0..<8 { out.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) } }
        put32(JBCK_MAGIC)
        out.append(JBCK_HEADER_VERSION)
        put64(compilerVersion)
        put64(key.hash)
        put32(UInt32(truncatingIfNeeded: key.sourceLength))
        put32(UInt32(desc.count))
        out.append(contentsOf: desc)
        out.append(contentsOf: blob)
        return out
    }

    /// The JFBC blob inside a validated entry, or why the entry was refused.
    enum EntryResult {
        case ok([UInt8])
        case refused(String)
    }

    /// Validate an entry against the key it was looked up with and return the
    /// JFBC blob, or the reason it was refused.
    static func openEntry(_ bytes: [UInt8], key: JeffJSBytecodeCacheKey) -> EntryResult {
        var p = 0
        func get32() -> UInt32? {
            guard p + 4 <= bytes.count else { return nil }
            defer { p += 4 }
            return UInt32(bytes[p]) | UInt32(bytes[p + 1]) << 8 | UInt32(bytes[p + 2]) << 16 | UInt32(bytes[p + 3]) << 24
        }
        func get64() -> UInt64? {
            guard let lo = get32(), let hi = get32() else { return nil }
            return UInt64(lo) | UInt64(hi) << 32
        }
        guard let magic = get32() else { return .refused("truncated header") }
        guard magic == JBCK_MAGIC else { return .refused("bad magic") }
        guard p < bytes.count else { return .refused("truncated header") }
        let headerVersion = bytes[p]; p += 1
        guard headerVersion == JBCK_HEADER_VERSION else { return .refused("header version mismatch") }
        guard let cv = get64() else { return .refused("truncated header") }
        guard cv == compilerVersion else { return .refused("compilerVersion mismatch") }
        guard let storedHash = get64() else { return .refused("truncated header") }
        guard storedHash == key.hash else { return .refused("key hash mismatch") }
        guard let srcLen = get32() else { return .refused("truncated header") }
        guard Int(srcLen) == key.sourceLength else { return .refused("source length mismatch") }
        guard let descLen = get32() else { return .refused("truncated header") }
        guard p + Int(descLen) <= bytes.count else { return .refused("truncated desc") }
        let desc = String(decoding: bytes[p..<(p + Int(descLen))], as: UTF8.self)
        p += Int(descLen)
        guard desc == key.desc else { return .refused("key mismatch") }
        return .ok(Array(bytes[p...]))
    }

    // MARK: - Lookup

    /// Look up cached bytecode. Checks in-memory first, then disk.
    /// Atom table indices are remapped to the current runtime's atom IDs.
    func lookup(_ key: JeffJSBytecodeCacheKey, ctx: JeffJSContext? = nil) -> JeffJSFunctionBytecode? {
        // In-memory cache
        if let entry = cache[key.hash] {
            guard entry.desc == key.desc, entry.sourceLength == key.sourceLength else {
                // Same 64-bit hash, different compile. Never serve it.
                reject("memory key mismatch", key)
                cache.removeValue(forKey: key.hash)
                return nil
            }
            guard let fb = JeffJSBytecodeDeserializer.deserialize(entry.blob, rt: rt, ctx: ctx) else {
                reject("memory deserialize failed", key)
                cache.removeValue(forKey: key.hash)
                return nil
            }
            hitCount += 1
            debugLog("hit memory key=\(key.desc) srcLen=\(key.sourceLength)")
            return fb
        }
        // Disk fallback
        guard let url = diskURL(for: key.hash),
              let data = try? Data(contentsOf: url) else {
            missCount += 1
            debugLog("miss key=\(key.desc) srcLen=\(key.sourceLength)")
            return nil
        }
        let blob: [UInt8]
        switch Self.openEntry([UInt8](data), key: key) {
        case .refused(let reason):
            reject("disk \(reason)", key)
            try? FileManager.default.removeItem(at: url)
            return nil
        case .ok(let b):
            blob = b
        }
        guard let fb = JeffJSBytecodeDeserializer.deserialize(blob, rt: rt, ctx: ctx) else {
            reject("disk deserialize failed", key)
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        // Promote to in-memory cache
        cache[key.hash] = Entry(desc: key.desc, sourceLength: key.sourceLength, blob: blob)
        hitCount += 1
        diskHitCount += 1
        debugLog("hit disk key=\(key.desc) srcLen=\(key.sourceLength) bytes=\(blob.count)")
        return fb
    }

    // MARK: - Store

    /// Store compiled bytecode in the cache (serializes with atom table).
    /// Also persists to disk for cross-launch caching.
    func store(_ key: JeffJSBytecodeCacheKey, bytecode fb: JeffJSFunctionBytecode) {
        guard cache.count < maxEntries else {
            debugLog("store skipped (cache full) key=\(key.desc)")
            return
        }
        let serialized = JeffJSBytecodeSerializer.serialize(fb, rt: rt)
        cache[key.hash] = Entry(desc: key.desc, sourceLength: key.sourceLength, blob: serialized)
        // Persist to disk synchronously: a few hundred KB takes ~1 ms, and a
        // queued write is lost when a short-lived host (the CLI) exits first.
        // `.atomic` writes a sibling temp file and renames it, so a concurrent
        // reader sees either the whole old entry or the whole new one — never
        // a half-written blob.
        if let url = diskURL(for: key.hash) {
            do {
                try Data(Self.makeEntry(key: key, blob: serialized)).write(to: url, options: .atomic)
            } catch {
                debugLog("store write failed key=\(key.desc): \(error)")
            }
        }
        debugLog("store key=\(key.desc) srcLen=\(key.sourceLength) bytes=\(serialized.count)")
    }

    /// Clear all cached entries (in-memory and disk).
    func clear() {
        cache.removeAll()
        hitCount = 0
        diskHitCount = 0
        missCount = 0
        rejectCount = 0
        lastRejectReason = nil
    }
}
