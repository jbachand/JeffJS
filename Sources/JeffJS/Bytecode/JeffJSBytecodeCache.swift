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
private let JFBC_VERSION: UInt8 = 2

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
}

// MARK: - Atom Table Builder

/// Collects atoms from bytecode and builds a remapping table.
/// Walks the opcode stream using OpcodeInfo.format to find atom operands,
/// assigns each unique atom a sequential index, and rewrites the bytecode
/// in-place to use table indices instead of runtime atom IDs.
private struct AtomTableBuilder {

    /// Maps runtime atom ID → index in the atom table
    private var atomToIndex: [UInt32: UInt32] = [:]
    /// Ordered atom strings (index → string)
    private(set) var atomStrings: [String] = []

    /// Register an atom, returning its table index.
    mutating func intern(_ atomID: UInt32, rt: JeffJSRuntime) -> UInt32 {
        if let existing = atomToIndex[atomID] { return existing }
        let idx = UInt32(atomStrings.count)
        let str = rt.atomToString(atomID) ?? ""
        atomStrings.append(str)
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
            let op = bc[pc]
            guard let opcode = JeffJSOpcode(rawValue: UInt16(op)) else {
                // Unknown opcode — skip 1 byte (shouldn't happen in valid bytecode)
                pc += 1
                continue
            }
            let info = jeffJSOpcodeInfo[Int(op)]

            // Determine atom offset based on format
            let atomOffset: Int?
            switch info.format {
            case .atom, .atom_u8, .atom_u16, .atom_label_u8, .atom_label_u16:
                atomOffset = pc + 1
            default:
                // Special case: get_loc8_get_field has loc8 at +1, atom at +2
                if opcode == .get_loc8_get_field {
                    atomOffset = pc + 2
                } else {
                    atomOffset = nil
                }
            }

            if let offset = atomOffset, offset + 3 < len {
                let oldAtom = readU32LE(out, offset)
                let newIdx = intern(oldAtom, rt: rt)
                writeU32LE(&out, offset, newIdx)
            }

            pc += Int(info.size)
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
    func remapBytecode(_ bc: inout [UInt8]) {
        let len = bc.count
        var pc = 0

        while pc < len {
            let op = bc[pc]
            guard let opcode = JeffJSOpcode(rawValue: UInt16(op)) else {
                pc += 1
                continue
            }
            let info = jeffJSOpcodeInfo[Int(op)]

            let atomOffset: Int?
            switch info.format {
            case .atom, .atom_u8, .atom_u16, .atom_label_u8, .atom_label_u16:
                atomOffset = pc + 1
            default:
                if opcode == .get_loc8_get_field {
                    atomOffset = pc + 2
                } else {
                    atomOffset = nil
                }
            }

            if let offset = atomOffset, offset + 3 < len {
                let tableIdx = readU32LE(bc, offset)
                if tableIdx < indexToAtom.count {
                    writeU32LE(&bc, offset, indexToAtom[Int(tableIdx)])
                }
            }

            pc += Int(info.size)
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
        let atoms = s.atomTable.atomStrings
        s.writeU32(UInt32(atoms.count))
        for str in atoms {
            s.writeString(str)
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
        writeU16(fb.stackSize)
        writeU16(fb.closureVarCount)
        writeU32(UInt32(fb.lineNum))
        writeU32(UInt32(fb.colNum))

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

    /// Deserialize bytes into a fresh function bytecode.
    /// If rt is provided, atoms are re-interned for cross-runtime portability.
    static func deserialize(_ data: [UInt8], rt: JeffJSRuntime? = nil) -> JeffJSFunctionBytecode? {
        var d = JeffJSBytecodeDeserializer(data: data)

        // Peek at version to decide whether atom table is present
        if data.count > 5 && data[4] >= 2, let rt {
            // Version 2+: read atom table from end, build remapper
            d.remapper = d.buildRemapper(rt: rt)
        }

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

    /// Read U32 at a specific position without advancing pos.
    private func readU32At(_ p: Int) -> UInt32 {
        readU32LE(data, p)
    }

    /// Skip past a serialized function bytecode (for finding atom table).
    private func skipFunctionBytecode(data: [UInt8], pos: inout Int) -> Bool {
        // Magic(4) + Version(1) + Flags(2) + argCount(2) + varCount(2) +
        // definedArgCount(2) + stackSize(2) + closureVarCount(2) + lineNum(4) + colNum(4)
        let headerSize = 4 + 1 + 2 + 2 + 2 + 2 + 2 + 2 + 4 + 4
        guard pos + headerSize <= data.count else { return false }
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

        return true
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
        guard let version = readU8(), (version == 1 || version == 2) else { return nil }
        guard let flags = readU16() else { return nil }
        guard let argCount = readU16() else { return nil }
        guard let varCount = readU16() else { return nil }
        guard let definedArgCount = readU16() else { return nil }
        guard let stackSize = readU16() else { return nil }
        guard let closureVarCount = readU16() else { return nil }
        guard let lineNum = readU32() else { return nil }
        guard let colNum = readU32() else { return nil }

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

        // Construct fresh JeffJSFunctionBytecode
        let fb = JeffJSFunctionBytecode()
        fb.bytecode = bytecode
        fb.bytecodeLen = bytecode.count
        fb.argCount = argCount
        fb.varCount = varCount
        fb.definedArgCount = definedArgCount
        fb.stackSize = stackSize
        fb.closureVarCount = closureVarCount
        fb.lineNum = Int(lineNum)
        fb.colNum = Int(colNum)
        fb.fileName = fileName
        fb.cpool = cpool
        unpackFlags(flags, into: fb)

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

        default:
            return .JS_UNDEFINED
        }
    }
}

// MARK: - Bytecode Cache

/// Per-runtime bytecode cache with disk persistence. Stores serialized
/// bytecode keyed by FNV-1a hash of the source string.
///
/// Atom remapping (v2 format) makes bytecode portable across runtimes,
/// so disk-cached bytecode survives app relaunches and even CLI precompilation.
///
/// The cache is stored on JeffJSRuntime and shared across all contexts in
/// that runtime.
final class JeffJSBytecodeCache {

    /// Serialized bytecode keyed by source hash.
    private var cache: [UInt64: [UInt8]] = [:]

    /// Maximum cached entries.
    private let maxEntries = 512

    /// Number of cache hits (in-memory).
    private(set) var hitCount: Int = 0

    /// Number of cache hits from disk.
    private(set) var diskHitCount: Int = 0

    /// Runtime for atom remapping during deserialization.
    weak var rt: JeffJSRuntime?

    // MARK: - Disk Cache

    /// Bump when the bytecode format changes.
    private static let diskVersion: UInt32 = 2

    /// Bump when parser or compiler logic changes (bug fixes, new opcodes, etc.).
    /// This is mixed into the source hash so cached bytecode from an older compiler
    /// is never reused. Bump this number after ANY change to:
    ///   - JeffJSParser.swift (parsing, bytecode emission)
    ///   - JeffJSCompiler.swift (resolveLabels, resolveVariables, peephole)
    ///   - JeffJSOpcodes.swift (opcode additions/changes)
    ///   - JeffJSInterpreter.swift (only if opcode semantics change)
    static let compilerVersion: UInt64 = 1  // 2026-04-03: initial after try-finally + postfix++ fixes

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

    // MARK: - Hashing

    /// FNV-1a 64-bit hash, seeded with compiler version.
    /// Changing `compilerVersion` invalidates all cached bytecode automatically.
    static func hashSource(_ source: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        // Mix in compiler version so bug fixes invalidate the cache
        hash ^= compilerVersion
        hash &*= 0x100000001b3
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }

    // MARK: - Lookup

    /// Look up cached bytecode. Checks in-memory first, then disk.
    /// Atom table indices are remapped to the current runtime's atom IDs.
    func lookup(_ sourceHash: UInt64) -> JeffJSFunctionBytecode? {
        // In-memory cache
        if let serialized = cache[sourceHash] {
            guard let fb = JeffJSBytecodeDeserializer.deserialize(serialized, rt: rt) else {
                cache.removeValue(forKey: sourceHash)
                return nil
            }
            hitCount += 1
            return fb
        }
        // Disk fallback
        guard let url = diskURL(for: sourceHash),
              let data = try? Data(contentsOf: url) else { return nil }
        let bytes = [UInt8](data)
        guard let fb = JeffJSBytecodeDeserializer.deserialize(bytes, rt: rt) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        // Promote to in-memory cache
        cache[sourceHash] = bytes
        hitCount += 1
        diskHitCount += 1
        return fb
    }

    // MARK: - Store

    /// Store compiled bytecode in the cache (serializes with atom table).
    /// Also persists to disk for cross-launch caching.
    func store(_ sourceHash: UInt64, bytecode fb: JeffJSFunctionBytecode) {
        guard cache.count < maxEntries else { return }
        let serialized = JeffJSBytecodeSerializer.serialize(fb, rt: rt)
        cache[sourceHash] = serialized
        // Persist to disk on background queue
        if let url = diskURL(for: sourceHash) {
            let data = Data(serialized)
            DispatchQueue.global(qos: .utility).async {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Clear all cached entries (in-memory and disk).
    func clear() {
        cache.removeAll()
        hitCount = 0
        diskHitCount = 0
    }
}
