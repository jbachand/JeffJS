// JeffJSBuiltinRegExp.swift
// JeffJS -- 1:1 Swift port of QuickJS JavaScript engine
//
// Port of the RegExp built-in object integration from QuickJS.
// This file covers the RegExp constructor, prototype methods, Symbol methods,
// and the RegExp String Iterator -- everything EXCEPT the low-level regex
// bytecode compiler/executor (which lives in JeffJSRegExpOpcodes.swift and
// a future JeffJSRegExpEngine.swift).
//
// QuickJS source reference: quickjs.c --
//   js_regexp_constructor, js_regexp_exec, js_regexp_test,
//   js_regexp_toString, js_regexp_compile,
//   js_regexp_Symbol_match, js_regexp_Symbol_matchAll,
//   js_regexp_Symbol_replace, js_regexp_Symbol_search,
//   js_regexp_Symbol_split, js_regexp_string_iterator_next,
//   js_regexp_get_flag, js_regexp_get_source, js_regexp_get_flags,
//   js_is_standard_regexp, js_get_substitution, etc.

import Foundation

// MARK: - RegExp internal data accessors

/// Extract the pattern string from a RegExp object.
/// QuickJS stores pattern and compiled bytecode in the `.regexp` payload.
private func js_regexp_getPattern(_ obj: JeffJSObject) -> JeffJSString? {
    if case .regexp(let pattern, _) = obj.payload {
        return pattern
    }
    return nil
}

/// Extract the compiled bytecode from a RegExp object.
private func js_regexp_getBytecode(_ obj: JeffJSObject) -> JeffJSString? {
    if case .regexp(_, let bytecode) = obj.payload {
        return bytecode
    }
    return nil
}

/// Extract flags from the compiled regex bytecode header.
///
/// In QuickJS the first byte of the regex bytecode stores the flags.
/// Layout: `lre_byte_code[0]` = flags (LRE_FLAG_*).
private func js_regexp_getFlags(_ obj: JeffJSObject) -> Int {
    guard case .regexp(_, let bytecode) = obj.payload,
          let bc = bytecode,
          bc.len > 0 else {
        return 0
    }
    return Int(jeffJS_getString(str: bc, at: 0))
}

/// Extract the capture group count from the compiled regex bytecode header.
///
/// Header layout: [0..1] flags (UInt16), [2] capture_count, [3..4] bc length.
private func js_regexp_getCaptureCount(_ obj: JeffJSObject) -> Int {
    guard case .regexp(_, let bytecode) = obj.payload,
          let bc = bytecode,
          bc.len > 2 else {
        return 0
    }
    return Int(jeffJS_getString(str: bc, at: 2))
}

// MARK: - Flag characters and order

/// The flag characters in the canonical order defined by the spec.
/// Used by the `flags` getter and `toString`.
private let js_regexp_flag_chars: [(flag: Int, char: Character)] = [
    (LRE_FLAG_INDICES,       "d"),
    (LRE_FLAG_GLOBAL,        "g"),
    (LRE_FLAG_IGNORECASE,    "i"),
    (LRE_FLAG_MULTILINE,     "m"),
    (LRE_FLAG_DOTALL,        "s"),
    (LRE_FLAG_UNICODE,       "u"),
    (LRE_FLAG_UNICODE_SETS,  "v"),
    (LRE_FLAG_STICKY,        "y"),
]

// MARK: - Flag parsing

/// Parse a flags string (e.g. "gi") into a bitmask of LRE_FLAG_* values.
///
/// Returns -1 on error (duplicate or invalid flag).
/// Mirrors QuickJS `lre_parse_flags`.
private func js_regexp_parseFlags(_ flagsStr: JeffJSString?) -> Int {
    guard let str = flagsStr else { return 0 }

    var flags = 0
    for i in 0 ..< str.len {
        let ch = jeffJS_getString(str: str, at: i)
        let bit: Int
        switch ch {
        case 0x64: /* d */ bit = LRE_FLAG_INDICES
        case 0x67: /* g */ bit = LRE_FLAG_GLOBAL
        case 0x69: /* i */ bit = LRE_FLAG_IGNORECASE
        case 0x6D: /* m */ bit = LRE_FLAG_MULTILINE
        case 0x73: /* s */ bit = LRE_FLAG_DOTALL
        case 0x75: /* u */ bit = LRE_FLAG_UNICODE
        case 0x76: /* v */ bit = LRE_FLAG_UNICODE_SETS
        case 0x79: /* y */ bit = LRE_FLAG_STICKY
        default:
            return -1  // Invalid flag character.
        }
        if flags & bit != 0 {
            return -1  // Duplicate flag.
        }
        // 'u' and 'v' are mutually exclusive.
        if (bit == LRE_FLAG_UNICODE && flags & LRE_FLAG_UNICODE_SETS != 0) ||
           (bit == LRE_FLAG_UNICODE_SETS && flags & LRE_FLAG_UNICODE != 0) {
            return -1
        }
        flags |= bit
    }
    return flags
}

/// Build a canonical flags string from a bitmask.
///
/// The flags are emitted in alphabetical order: d, g, i, m, s, u, v, y.
/// Mirrors QuickJS flag string construction.
private func js_regexp_buildFlagsString(_ flags: Int) -> JeffJSString {
    var chars: [UInt8] = []
    for (flag, ch) in js_regexp_flag_chars {
        if flags & flag != 0 {
            chars.append(UInt8(ch.asciiValue ?? 0))
        }
    }
    return JeffJSString(
        refCount: 1,
        len: chars.count,
        isWideChar: false,
        storage: .str8(chars)
    )
}

// MARK: - RegExp constructor

/// `RegExp(pattern, flags)` constructor.
///
/// Mirrors QuickJS `js_regexp_constructor`.
///
/// Coercion rules (from the spec):
///   - If pattern is a RegExp and flags is undefined, return the pattern
///     (unless @@species is overridden or the constructor differs).
///   - If pattern is a RegExp, extract its source and flags.
///   - Otherwise, coerce pattern to string.
///   - Compile the regex.
func js_regexp_constructor(
    ctx: JeffJSContext,
    newTarget: JeffJSValue,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    let patternArg = argv.count >= 1 ? argv[0] : JeffJSValue.undefined
    let flagsArg = argv.count >= 2 ? argv[1] : JeffJSValue.undefined

    var patternStr: JeffJSString?
    var flagsStr: JeffJSString?

    // Check if pattern is already a RegExp.
    if let patternObj = patternArg.toObject(),
       patternObj.classID == JSClassID.JS_CLASS_REGEXP.rawValue {

        // Extract the source pattern.
        patternStr = js_regexp_getPattern(patternObj)

        if flagsArg.isUndefined {
            // Use the original flags.
            let flagBits = js_regexp_getFlags(patternObj)
            flagsStr = js_regexp_buildFlagsString(flagBits)
        } else {
            // Use the provided flags.
            flagsStr = flagsArg.stringValue
        }
    } else {
        // Coerce pattern to string (undefined -> "").
        if patternArg.isUndefined {
            patternStr = JeffJSString(swiftString: "")
        } else {
            patternStr = patternArg.stringValue
            if patternStr == nil {
                // In a full build, JS_ToString would be called here.
                patternStr = JeffJSString(swiftString: "")
            }
        }
        flagsStr = flagsArg.isUndefined ? nil : flagsArg.stringValue
    }

    // Parse flags.
    let flagBits = js_regexp_parseFlags(flagsStr)
    if flagBits < 0 {
        return ctx.throwTypeError("RegExp: invalid flags")
    }

    // Compile the pattern.
    let compiledBytecode = js_regexp_compile(ctx: ctx, pattern: patternStr, flags: flagBits)
    if compiledBytecode == nil {
        // Compilation error was already thrown.
        return .exception
    }

    // Create the RegExp object with the correct prototype.
    let regexpClassID = JSClassID.JS_CLASS_REGEXP.rawValue
    let regexpProto: JeffJSObject? = regexpClassID < ctx.classProto.count
        ? ctx.classProto[regexpClassID].toObject()
        : nil
    let obj = jeffJS_createObject(ctx: ctx, proto: regexpProto,
                                   classID: UInt16(regexpClassID))
    obj.payload = JeffJSObjectPayload.regexp(pattern: patternStr, bytecode: compiledBytecode)

    // Set lastIndex to 0 (first own property for fast-path access).
    // Use jeffJS_addProperty so shape.propCount stays in sync.
    jeffJS_addProperty(ctx: ctx, obj: obj,
                       atom: JeffJSAtomID.JS_ATOM_lastIndex.rawValue,
                       flags: [.writable])
    obj.setOwnPropertyValue(atom: JeffJSAtomID.JS_ATOM_lastIndex.rawValue,
                            value: JeffJSValue.newInt32(0))

    return JeffJSValue.makeObject(obj)
}

// MARK: - RegExp.prototype.exec

/// `RegExp.prototype.exec(string)` -- core execution method.
///
/// Mirrors QuickJS `js_regexp_exec`.
///
/// Returns a result array with:
///   - index: the start index of the match
///   - input: the input string
///   - groups: named capture groups (or undefined)
///   - indices: capture group start/end pairs (if 'd' flag)
///   - [0]: the full match
///   - [1]...[n]: capture groups
///
/// Returns null if no match.
func js_regexp_exec(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    guard let obj = this.toObject(),
          obj.classID == JSClassID.JS_CLASS_REGEXP.rawValue else {
        return ctx.throwTypeError("RegExp.prototype.exec called on incompatible receiver")
    }

    let inputVal = argv.count >= 1 ? argv[0] : JeffJSValue.undefined
    guard let inputStr = js_regexp_coerceToString(ctx: ctx, val: inputVal) else {
        return .exception
    }

    let flags = js_regexp_getFlags(obj)
    let isGlobal = (flags & LRE_FLAG_GLOBAL) != 0
    let isSticky = (flags & LRE_FLAG_STICKY) != 0
    let hasIndices = (flags & LRE_FLAG_INDICES) != 0

    // Read lastIndex.
    var lastIndex: Int = 0
    if isGlobal || isSticky {
        lastIndex = js_regexp_getLastIndex(obj)
        if lastIndex < 0 { lastIndex = 0 }
    }

    let captureCount = js_regexp_getCaptureCount(obj)

    // Execute the regex engine.
    // In a full build this calls `lre_exec` on the compiled bytecode.
    // We model the result as an array of (start, end) pairs for each capture.
    let matchResult = js_regexp_execInternal(
        ctx: ctx,
        obj: obj,
        inputStr: inputStr,
        startIndex: lastIndex,
        flags: flags,
        captureCount: captureCount
    )

    guard let captures = matchResult else {
        // No match.
        if isGlobal || isSticky {
            js_regexp_setLastIndex(obj, value: 0)
        }
        return .null
    }

    // Build the result array.
    let resultArray = jeffJS_createObject(ctx: ctx, proto: nil,
                                           classID: UInt16(JeffJSClassID.array.rawValue))

    var arrayValues: [JeffJSValue] = []

    // [0] = full match substring.
    let matchStart = captures[0].start
    let matchEnd = captures[0].end
    let fullMatchStr = jeffJS_subString(str: inputStr, start: matchStart, end: matchEnd)
    arrayValues.append(
        fullMatchStr.map { JeffJSValue.makeString($0) } ?? .undefined
    )

    // [1]...[n] = capture groups.
    for i in 1 ..< captures.count {
        let capStart = captures[i].start
        let capEnd = captures[i].end
        if capStart < 0 || capEnd < 0 {
            // Unmatched capture.
            arrayValues.append(.undefined)
        } else {
            let capStr = jeffJS_subString(str: inputStr, start: capStart, end: capEnd)
            arrayValues.append(
                capStr.map { JeffJSValue.makeString($0) } ?? .undefined
            )
        }
    }

    resultArray.payload = .array(
        size: UInt32(arrayValues.count),
        values: arrayValues,
        count: UInt32(arrayValues.count)
    )
    resultArray.fastArray = true

    // Set `length` property so array.length works.
    let lengthProp = JeffJSShapeProperty(
        atom: JeffJSAtomID.JS_ATOM_length.rawValue,
        flags: [.writable]
    )
    resultArray.shape?.prop.append(lengthProp)
    resultArray.prop.append(.value(JeffJSValue.newInt32(Int32(arrayValues.count))))

    // Set `index` property.
    let indexProp = JeffJSShapeProperty(
        atom: JeffJSAtomID.JS_ATOM_index.rawValue,
        flags: [.writable, .enumerable, .configurable]
    )
    resultArray.shape?.prop.append(indexProp)
    resultArray.prop.append(.value(JeffJSValue.newInt32(Int32(matchStart))))

    // Set `input` property.
    let inputProp = JeffJSShapeProperty(
        atom: JeffJSAtomID.JS_ATOM_input.rawValue,
        flags: [.writable, .enumerable, .configurable]
    )
    resultArray.shape?.prop.append(inputProp)
    resultArray.prop.append(.value(JeffJSValue.makeString(inputStr.retain())))

    // Set `groups` property — populate from named capture groups if present.
    let groupsProp = JeffJSShapeProperty(
        atom: JeffJSAtomID.JS_ATOM_groups.rawValue,
        flags: [.writable, .enumerable, .configurable]
    )
    resultArray.shape?.prop.append(groupsProp)
    var groupsVal: JeffJSValue = .undefined
    if case .regexp(_, let bytecodeStr) = obj.payload,
       let bc = bytecodeStr,
       case .str8(let bcBuf) = bc.storage {
        let bytecodeBytes = Array(bcBuf.prefix(bc.len))
        let groupNames = lreGetGroupNames(bytecodeBytes)
        var hasNamedGroup = false
        for name in groupNames { if name != nil { hasNamedGroup = true; break } }
        if hasNamedGroup {
            let groupsObj = ctx.newObject()
            for i in 0..<groupNames.count {
                if let name = groupNames[i] {
                    // groupNames[i] corresponds to arrayValues[i] (both include group 0)
                    let capVal: JeffJSValue
                    if i < arrayValues.count {
                        capVal = arrayValues[i].dupValue()
                    } else {
                        capVal = .undefined
                    }
                    ctx.setPropertyStr(obj: groupsObj, name: name, value: capVal)
                }
            }
            groupsVal = groupsObj
        }
    }
    resultArray.prop.append(.value(groupsVal))

    // Set `indices` property (if 'd' flag).
    if hasIndices {
        let indicesProp = JeffJSShapeProperty(
            atom: JeffJSAtomID.JS_ATOM_indices.rawValue,
            flags: [.writable, .enumerable, .configurable]
        )
        resultArray.shape?.prop.append(indicesProp)

        let indicesArray = js_regexp_buildIndicesArray(ctx: ctx, captures: captures)
        resultArray.prop.append(.value(JeffJSValue.makeObject(indicesArray)))
    }

    // Update lastIndex.
    if isGlobal || isSticky {
        js_regexp_setLastIndex(obj, value: matchEnd)
    }

    return JeffJSValue.makeObject(resultArray)
}

// MARK: - RegExp.prototype.test

/// `RegExp.prototype.test(string)` -- shorthand for `exec !== null`.
///
/// Mirrors QuickJS `js_regexp_test`.
func js_regexp_test(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    let result = js_regexp_exec(ctx: ctx, this: this, argv: argv)
    if result.isException {
        return .exception
    }
    return JeffJSValue.newBool(!result.isNull)
}

// MARK: - RegExp.prototype.toString

/// `RegExp.prototype.toString()` -- returns "/pattern/flags".
///
/// Mirrors QuickJS `js_regexp_toString`.
func js_regexp_toString(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    guard let obj = this.toObject() else {
        return ctx.throwTypeError("RegExp.prototype.toString called on non-object")
    }

    // Get "source" and "flags" properties (may be overridden on subclasses).
    let sourceVal: JeffJSValue
    let flagsVal: JeffJSValue

    if obj.classID == JSClassID.JS_CLASS_REGEXP.rawValue {
        // Fast path: native RegExp.
        if let pattern = js_regexp_getPattern(obj) {
            sourceVal = JeffJSValue.makeString(pattern.retain())
        } else {
            sourceVal = JeffJSValue.makeString(JeffJSString(swiftString: "(?:)"))
        }

        let flagBits = js_regexp_getFlags(obj)
        let flagStr = js_regexp_buildFlagsString(flagBits)
        flagsVal = JeffJSValue.makeString(flagStr)
    } else {
        // Slow path: read "source" and "flags" properties.
        sourceVal = obj.getOwnPropertyValue(atom: JeffJSAtomID.JS_ATOM_source.rawValue)
        flagsVal = obj.getOwnPropertyValue(atom: JeffJSAtomID.JS_ATOM_flags.rawValue)
    }

    // Build "/source/flags".
    let buf = JeffJSStringBuffer()
    buf.putc8(0x2F) // '/'

    if let sourceStr = sourceVal.stringValue {
        // Escape forward slashes in the source.
        for i in 0 ..< sourceStr.len {
            let ch = jeffJS_getString(str: sourceStr, at: i)
            if ch == 0x2F { // '/'
                buf.putc8(0x5C) // '\'
            }
            buf.putc(ch)
        }
    } else {
        buf.puts8("(?:)")
    }

    buf.putc8(0x2F) // '/'

    if let flagStr = flagsVal.stringValue {
        buf.concat(flagStr)
    }

    guard let result = buf.end() else {
        return ctx.throwOutOfMemory()
    }

    return JeffJSValue.makeString(result)
}

// MARK: - RegExp.prototype.compile (legacy)

/// `RegExp.prototype.compile(pattern, flags)` -- legacy method.
///
/// Mirrors QuickJS `js_regexp_compile`.
///
/// This is a non-standard method kept for web compatibility (Annex B).
/// It recompiles the RegExp in-place with a new pattern and/or flags.
func js_regexp_compile(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    guard let obj = this.toObject(),
          obj.classID == JSClassID.JS_CLASS_REGEXP.rawValue else {
        return ctx.throwTypeError("RegExp.prototype.compile called on incompatible receiver")
    }

    let patternArg = argv.count >= 1 ? argv[0] : JeffJSValue.undefined
    let flagsArg = argv.count >= 2 ? argv[1] : JeffJSValue.undefined

    var patternStr: JeffJSString?
    var flagsStr: JeffJSString?

    // If pattern is a RegExp, extract source and flags.
    if let patternObj = patternArg.toObject(),
       patternObj.classID == JSClassID.JS_CLASS_REGEXP.rawValue {
        if !flagsArg.isUndefined {
            return ctx.throwTypeError(
                "RegExp.prototype.compile: cannot supply flags when pattern is a RegExp"
            )
        }
        patternStr = js_regexp_getPattern(patternObj)
        let bits = js_regexp_getFlags(patternObj)
        flagsStr = js_regexp_buildFlagsString(bits)
    } else {
        patternStr = patternArg.isUndefined
            ? JeffJSString(swiftString: "")
            : patternArg.stringValue ?? JeffJSString(swiftString: "")
        flagsStr = flagsArg.isUndefined ? nil : flagsArg.stringValue
    }

    let flagBits = js_regexp_parseFlags(flagsStr)
    if flagBits < 0 {
        return ctx.throwTypeError("RegExp.compile: invalid flags")
    }

    let compiled = js_regexp_compile(ctx: ctx, pattern: patternStr, flags: flagBits)
    if compiled == nil {
        return .exception
    }

    obj.payload = JeffJSObjectPayload.regexp(pattern: patternStr, bytecode: compiled)
    js_regexp_setLastIndex(obj, value: 0)

    return this.dupValue()
}

// MARK: - Flag getters

/// Generic flag getter.  `magic` encodes which flag bit to test.
///
/// Mirrors QuickJS `js_regexp_get_flag` with magic parameter.
func js_regexp_get_flag(
    ctx: JeffJSContext,
    this: JeffJSValue,
    magic: Int
) -> JeffJSValue {
    guard let obj = this.toObject() else {
        // The spec says non-object `this` should not throw for
        // `RegExp.prototype` itself; return undefined.
        if this.isUndefined {
            return .undefined
        }
        return ctx.throwTypeError("RegExp flag getter called on non-object")
    }

    if obj.classID != JSClassID.JS_CLASS_REGEXP.rawValue {
        // If `this` is the RegExp.prototype object, return undefined.
        return .undefined
    }

    let flags = js_regexp_getFlags(obj)
    return JeffJSValue.newBool((flags & magic) != 0)
}

/// `get RegExp.prototype.global`
func js_regexp_get_global(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
    return js_regexp_get_flag(ctx: ctx, this: this, magic: LRE_FLAG_GLOBAL)
}

/// `get RegExp.prototype.ignoreCase`
func js_regexp_get_ignoreCase(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
    return js_regexp_get_flag(ctx: ctx, this: this, magic: LRE_FLAG_IGNORECASE)
}

/// `get RegExp.prototype.multiline`
func js_regexp_get_multiline(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
    return js_regexp_get_flag(ctx: ctx, this: this, magic: LRE_FLAG_MULTILINE)
}

/// `get RegExp.prototype.dotAll`
func js_regexp_get_dotAll(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
    return js_regexp_get_flag(ctx: ctx, this: this, magic: LRE_FLAG_DOTALL)
}

/// `get RegExp.prototype.unicode`
func js_regexp_get_unicode(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
    return js_regexp_get_flag(ctx: ctx, this: this, magic: LRE_FLAG_UNICODE)
}

/// `get RegExp.prototype.unicodeSets`
func js_regexp_get_unicodeSets(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
    return js_regexp_get_flag(ctx: ctx, this: this, magic: LRE_FLAG_UNICODE_SETS)
}

/// `get RegExp.prototype.sticky`
func js_regexp_get_sticky(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
    return js_regexp_get_flag(ctx: ctx, this: this, magic: LRE_FLAG_STICKY)
}

/// `get RegExp.prototype.hasIndices`
func js_regexp_get_hasIndices(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
    return js_regexp_get_flag(ctx: ctx, this: this, magic: LRE_FLAG_INDICES)
}

/// `get RegExp.prototype.source`
///
/// Returns the pattern with appropriate escaping.
/// Mirrors QuickJS `js_regexp_get_source`.
func js_regexp_get_source(
    ctx: JeffJSContext,
    this: JeffJSValue
) -> JeffJSValue {
    guard let obj = this.toObject() else {
        if this.isUndefined {
            return JeffJSValue.makeString(JeffJSString(swiftString: "(?:)"))
        }
        return ctx.throwTypeError("RegExp source getter called on non-object")
    }

    if obj.classID != JSClassID.JS_CLASS_REGEXP.rawValue {
        return JeffJSValue.makeString(JeffJSString(swiftString: "(?:)"))
    }

    if let pattern = js_regexp_getPattern(obj) {
        if pattern.len == 0 {
            return JeffJSValue.makeString(JeffJSString(swiftString: "(?:)"))
        }
        return JeffJSValue.makeString(pattern.retain())
    }
    return JeffJSValue.makeString(JeffJSString(swiftString: "(?:)"))
}

/// `get RegExp.prototype.flags`
///
/// Returns a string containing the flag characters in canonical order.
/// Mirrors QuickJS `js_regexp_get_flags`.
func js_regexp_get_flags(
    ctx: JeffJSContext,
    this: JeffJSValue
) -> JeffJSValue {
    guard let obj = this.toObject() else {
        return ctx.throwTypeError("RegExp flags getter called on non-object")
    }

    if obj.classID == JSClassID.JS_CLASS_REGEXP.rawValue {
        // Fast path for native RegExp.
        let bits = js_regexp_getFlags(obj)
        let str = js_regexp_buildFlagsString(bits)
        return JeffJSValue.makeString(str)
    }

    // Slow path: read individual flag getters.
    // This handles subclasses that override the flag getters.
    var chars: [UInt8] = []
    let flagAtoms: [(UInt32, Character)] = [
        (JeffJSAtomID.JS_ATOM_hasIndices.rawValue, "d"),
        (JeffJSAtomID.JS_ATOM_global.rawValue,     "g"),
        (JeffJSAtomID.JS_ATOM_ignoreCase.rawValue,  "i"),
        (JeffJSAtomID.JS_ATOM_multiline.rawValue,   "m"),
        (JeffJSAtomID.JS_ATOM_dotAll.rawValue,      "s"),
        (JeffJSAtomID.JS_ATOM_unicode.rawValue,     "u"),
        (JeffJSAtomID.JS_ATOM_unicodeSets.rawValue,  "v"),
        (JeffJSAtomID.JS_ATOM_sticky.rawValue,      "y"),
    ]

    for (atom, ch) in flagAtoms {
        let val = obj.getOwnPropertyValue(atom: atom)
        if val.isBool && val.toBool() {
            chars.append(UInt8(ch.asciiValue ?? 0))
        }
        // If it is a getter, we would need to call it.
        // For now we handle only the fast path.
    }

    let str = JeffJSString(
        refCount: 1,
        len: chars.count,
        isWideChar: false,
        storage: .str8(chars)
    )
    return JeffJSValue.makeString(str)
}

// MARK: - Symbol methods

/// `RegExp.prototype[@@match](string)`
///
/// Mirrors QuickJS `js_regexp_Symbol_match`.
///
/// Non-global: equivalent to exec(string).
/// Global: loop exec() collecting all matches, reset lastIndex to 0.
func js_regexp_Symbol_match(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    guard let obj = this.toObject() else {
        return ctx.throwTypeError("[Symbol.match] called on non-object")
    }

    let inputVal = argv.count >= 1 ? argv[0] : JeffJSValue.undefined
    guard let inputStr = js_regexp_coerceToString(ctx: ctx, val: inputVal) else {
        return .exception
    }

    let flags = js_regexp_getFlags(obj)
    let isGlobal = (flags & LRE_FLAG_GLOBAL) != 0

    if !isGlobal {
        // Non-global: single exec.
        return js_regexp_exec(ctx: ctx, this: this, argv: [JeffJSValue.makeString(inputStr)])
    }

    // Fast path: for standard RegExp with /g flag, bypass the full exec()
    // machinery and use the optimized global match loop that creates ONE
    // REVirtualMachine and reuses it for all matches. This avoids per-match:
    // - bytecode extraction/allocation
    // - input string -> [UInt32] conversion
    // - REVirtualMachine instantiation
    // - full JS result object creation (index, input, groups properties)
    if js_isStandardRegexp(obj) {
        let fastResult = js_regexp_globalMatchFast(ctx: ctx, obj: obj, inputStr: inputStr, flags: flags)
        if !fastResult.isException {
            return fastResult
        }
        // Fall through to slow path if fast path fails (e.g. bytecode extraction issue).
    }

    // Slow path: standard spec-compliant global match loop (used when exec is
    // overridden, or as fallback).
    let isUnicode = (flags & LRE_FLAG_UNICODE) != 0 || (flags & LRE_FLAG_UNICODE_SETS) != 0

    js_regexp_setLastIndex(obj, value: 0)

    var matches: [JeffJSValue] = []
    var safetyLimit = 1_000_000  // prevent infinite loop on pathological patterns

    while safetyLimit > 0 {
        safetyLimit -= 1
        let result = js_regexp_exec(ctx: ctx, this: this, argv: [JeffJSValue.makeString(inputStr.retain())])
        if result.isException {
            return .exception
        }
        if result.isNull {
            break
        }

        // Extract match[0].
        if let resObj = result.toObject() {
            let matchStr = resObj.getArrayElement(0)
            matches.append(matchStr.dupValue())

            // If match[0] is empty string, advance lastIndex to avoid infinite loop.
            if let ms = matchStr.stringValue, ms.len == 0 {
                var li = js_regexp_getLastIndex(obj)
                li = js_regexp_advanceIndex(inputStr, index: li, unicode: isUnicode)
                js_regexp_setLastIndex(obj, value: li)
            }
        } else {
            break
        }
    }

    if matches.isEmpty {
        return .null
    }

    // Build result array using newArray() so it has a proper length property.
    let arrVal = ctx.newArray()
    if let resultArray = arrVal.toObject() {
        resultArray.payload = .array(
            size: UInt32(matches.count),
            values: matches,
            count: UInt32(matches.count)
        )
        resultArray.fastArray = true
    }
    // Update the length property to reflect actual count.
    _ = ctx.setPropertyStr(obj: arrVal, name: "length",
                           value: .newInt32(Int32(matches.count)))

    return arrVal
}

// MARK: - Fast global match

/// Optimized global match path for standard RegExp objects with /g flag.
///
/// Instead of calling js_regexp_exec() per match (which re-extracts bytecode,
/// re-converts the input string, creates a new REVirtualMachine, and builds a
/// full JS result object every time), this function:
/// 1. Extracts bytecode ONCE from the RegExp payload
/// 2. Converts input string to [UInt32] ONCE
/// 3. Delegates to lreExecGlobalMatch() which creates ONE REVirtualMachine
///    and reuses it across all matches (resetting captures/stack between matches)
/// 4. Only creates JS string objects for the final result array
///
/// Returns .exception as a sentinel if the fast path cannot be used (bytecode
/// extraction fails), signaling the caller to fall back to the slow path.
private func js_regexp_globalMatchFast(
    ctx: JeffJSContext,
    obj: JeffJSObject,
    inputStr: JeffJSString,
    flags: Int
) -> JeffJSValue {
    // 1. Extract the compiled bytecode ONCE.
    guard case .regexp(_, let bytecodeStr) = obj.payload,
          let bc = bytecodeStr else {
        return .exception  // signal to fall back to slow path
    }

    let bytecode: [UInt8]
    if case .str8(let buf) = bc.storage {
        bytecode = Array(buf.prefix(bc.len))
    } else {
        return .exception  // bytecode must be str8
    }

    guard bytecode.count >= 5 else { return .exception }

    // 2. Convert the input string to [UInt32] ONCE.
    let isUnicode = (flags & LRE_FLAG_UNICODE) != 0 || (flags & LRE_FLAG_UNICODE_SETS) != 0
    let inputCodeUnits: [UInt32]
    if isUnicode {
        let s = inputStr.toSwiftString()
        inputCodeUnits = Array(s.unicodeScalars.map { $0.value })
    } else {
        let s = inputStr.toSwiftString()
        inputCodeUnits = Array(s.utf16.map { UInt32($0) })
    }

    // 3. Build the flags for the regex VM.
    var regexpFlags = JeffJSRegExpFlags()
    if flags & LRE_FLAG_GLOBAL != 0       { regexpFlags.insert(.global) }
    if flags & LRE_FLAG_IGNORECASE != 0   { regexpFlags.insert(.ignoreCase) }
    if flags & LRE_FLAG_MULTILINE != 0    { regexpFlags.insert(.multiline) }
    if flags & LRE_FLAG_DOTALL != 0       { regexpFlags.insert(.dotAll) }
    if flags & LRE_FLAG_UNICODE != 0      { regexpFlags.insert(.unicode) }
    if flags & LRE_FLAG_STICKY != 0       { regexpFlags.insert(.sticky) }
    if flags & LRE_FLAG_INDICES != 0      { regexpFlags.insert(.hasIndices) }
    if flags & LRE_FLAG_UNICODE_SETS != 0 { regexpFlags.insert(.unicodeSets) }

    // 4. Execute the fast global match loop (single VM, reused across matches).
    guard let matchRanges = lreExecGlobalMatch(
        bytecode: bytecode,
        input: inputCodeUnits,
        flags: regexpFlags,
        isUnicode: isUnicode
    ) else {
        return .exception  // error in regex execution
    }

    // 5. Update lastIndex on the RegExp object.
    //    After a global match that exhausts all matches, lastIndex is set to 0.
    //    (Per spec, String.prototype.match with /g sets lastIndex to 0 at the end.)
    js_regexp_setLastIndex(obj, value: 0)

    if matchRanges.isEmpty {
        return .null
    }

    // 6. Convert (start, end) ranges to JS string values.
    //    This is the ONLY place we create JS objects — one string per match.
    var matchValues = [JeffJSValue]()
    matchValues.reserveCapacity(matchRanges.count)

    for range in matchRanges {
        // Build a JeffJSString from the input code units slice.
        let matchLen = range.end - range.start
        if matchLen == 0 {
            matchValues.append(JeffJSValue.makeString(JeffJSString(swiftString: "")))
        } else {
            // Determine if the substring needs wide chars.
            var needsWide = false
            for i in range.start ..< range.end {
                if inputCodeUnits[i] > 0xFF {
                    needsWide = true
                    break
                }
            }
            let str: JeffJSString
            if needsWide {
                var buf = [UInt16](repeating: 0, count: matchLen)
                for i in 0 ..< matchLen {
                    buf[i] = UInt16(truncatingIfNeeded: inputCodeUnits[range.start + i])
                }
                str = JeffJSString(refCount: 1, len: matchLen, isWideChar: true,
                                   storage: .str16(buf))
            } else {
                var buf = [UInt8](repeating: 0, count: matchLen)
                for i in 0 ..< matchLen {
                    buf[i] = UInt8(truncatingIfNeeded: inputCodeUnits[range.start + i])
                }
                str = JeffJSString(refCount: 1, len: matchLen, isWideChar: false,
                                   storage: .str8(buf))
            }
            matchValues.append(JeffJSValue.makeString(str))
        }
    }

    // 7. Build the result array.
    let arrVal = ctx.newArray()
    if let resultArray = arrVal.toObject() {
        resultArray.payload = .array(
            size: UInt32(matchValues.count),
            values: matchValues,
            count: UInt32(matchValues.count)
        )
        resultArray.fastArray = true
    }
    _ = ctx.setPropertyStr(obj: arrVal, name: "length",
                           value: .newInt32(Int32(matchValues.count)))

    return arrVal
}

/// `RegExp.prototype[@@matchAll](string)` -- returns a RegExp String Iterator.
///
/// Mirrors QuickJS `js_regexp_Symbol_matchAll`.
func js_regexp_Symbol_matchAll(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    guard let obj = this.toObject() else {
        return ctx.throwTypeError("[Symbol.matchAll] called on non-object")
    }

    let inputVal = argv.count >= 1 ? argv[0] : JeffJSValue.undefined
    guard let inputStr = js_regexp_coerceToString(ctx: ctx, val: inputVal) else {
        return .exception
    }

    // Create a copy of the regexp (to preserve the original's lastIndex).
    let flags = js_regexp_getFlags(obj)
    let isGlobal = (flags & LRE_FLAG_GLOBAL) != 0
    let isUnicode = (flags & LRE_FLAG_UNICODE) != 0 || (flags & LRE_FLAG_UNICODE_SETS) != 0

    // Ensure the flags string includes 'g' (matchAll always uses global).
    var copyFlags = flags | LRE_FLAG_GLOBAL

    let regexpCopy = jeffJS_createObject(ctx: ctx, proto: nil,
                                          classID: UInt16(JSClassID.JS_CLASS_REGEXP.rawValue))
    regexpCopy.payload = .regexp(
        pattern: js_regexp_getPattern(obj)?.retain(),
        bytecode: js_regexp_getBytecode(obj)?.retain()
    )

    // Set lastIndex from the original.
    let origLastIndex = js_regexp_getLastIndex(obj)
    let liProp = JeffJSShapeProperty(
        atom: JeffJSAtomID.JS_ATOM_lastIndex.rawValue,
        flags: [.writable]
    )
    regexpCopy.shape?.prop.append(liProp)
    regexpCopy.prop.append(.value(JeffJSValue.newInt32(Int32(origLastIndex))))

    // Create the iterator object.
    let iterData = JSRegExpStringIteratorData(
        iteratingRegExp: regexpCopy,
        iteratedString: inputStr.retain(),
        isGlobal: isGlobal,
        isUnicode: isUnicode,
        done: false
    )

    let iterObj = jeffJS_createObject(ctx: ctx, proto: nil,
                                       classID: UInt16(JeffJSClassID.stringIterator.rawValue))
    iterObj.payload = .opaque(iterData)

    return JeffJSValue.makeObject(iterObj)
}

/// `RegExp.prototype[@@replace](string, replaceValue)`
///
/// Mirrors QuickJS `js_regexp_Symbol_replace`.
///
/// If replaceValue is a function, it is called for each match.
/// If replaceValue is a string, it is interpolated with $-substitutions.
func js_regexp_Symbol_replace(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    guard let obj = this.toObject() else {
        return ctx.throwTypeError("[Symbol.replace] called on non-object")
    }

    let inputVal = argv.count >= 1 ? argv[0] : JeffJSValue.undefined
    let replaceVal = argv.count >= 2 ? argv[1] : JeffJSValue.undefined

    guard let inputStr = js_regexp_coerceToString(ctx: ctx, val: inputVal) else {
        return .exception
    }

    let flags = js_regexp_getFlags(obj)
    let isGlobal = (flags & LRE_FLAG_GLOBAL) != 0
    let isUnicode = (flags & LRE_FLAG_UNICODE) != 0 || (flags & LRE_FLAG_UNICODE_SETS) != 0

    let replaceIsFunc: Bool
    if let replObj = replaceVal.toObject(), replObj.isCallable {
        replaceIsFunc = true
    } else {
        replaceIsFunc = false
    }

    let replaceStr: JeffJSString?
    if !replaceIsFunc {
        replaceStr = replaceVal.stringValue ?? JeffJSString(swiftString: "undefined")
    } else {
        replaceStr = nil
    }

    if isGlobal {
        js_regexp_setLastIndex(obj, value: 0)
    }

    let buf = JeffJSStringBuffer()
    var lastMatchEnd = 0

    // Execute the regex repeatedly (once for non-global, loop for global).
    var loopCount = 0
    let maxLoops = isGlobal ? inputStr.len + 1 : 1

    while loopCount < maxLoops {
        loopCount += 1

        let result = js_regexp_exec(ctx: ctx, this: this, argv: [JeffJSValue.makeString(inputStr.retain())])
        if result.isException {
            buf.free()
            return .exception
        }
        if result.isNull {
            break
        }

        guard let resObj = result.toObject() else { break }

        // Get the match position.
        let indexVal = resObj.getOwnPropertyValue(atom: JeffJSAtomID.JS_ATOM_index.rawValue)
        let matchStart: Int
        if indexVal.isInt {
            matchStart = Int(indexVal.toInt32())
        } else {
            matchStart = 0
        }

        let matched = resObj.getArrayElement(0)
        let matchedStr = matched.stringValue
        let matchLen = matchedStr?.len ?? 0

        // Append the part of the input before this match.
        if matchStart > lastMatchEnd {
            if let sub = jeffJS_subString(str: inputStr, start: lastMatchEnd, end: matchStart) {
                buf.concat(sub)
            }
        }

        // Compute the replacement.
        if replaceIsFunc {
            // Call replaceValue(matched, p1, p2, ..., offset, string[, groups])
            // per ES spec §22.2.5.9 step 14.
            var callArgs: [JeffJSValue] = []
            // First arg: matched substring
            if let ms = matchedStr {
                callArgs.append(JeffJSValue.makeString(ms.retain()))
            } else {
                callArgs.append(ctx.newStringValue(""))
            }
            // Capture groups: result[1], result[2], ...
            let nCaptures = Int(resObj.arrayCount)
            for i in 1 ..< nCaptures {
                let cap = resObj.getArrayElement(UInt32(i))
                callArgs.append(cap.isUndefined ? JeffJSValue.undefined : cap.dupValue())
            }
            // Offset (position)
            callArgs.append(JeffJSValue.newInt32(Int32(matchStart)))
            // Full input string
            callArgs.append(JeffJSValue.makeString(inputStr.retain()))
            // Named groups (if present)
            let groupsAtom = ctx.rt.findAtom("groups")
            let groupsVal = resObj.getOwnPropertyValue(atom: groupsAtom)
            ctx.rt.freeAtom(groupsAtom)
            if !groupsVal.isUndefined {
                callArgs.append(groupsVal.dupValue())
            }
            let replResult = ctx.callFunction(replaceVal, thisVal: .undefined, args: callArgs)
            // Free call args
            for arg in callArgs { arg.freeValue() }
            if replResult.isException {
                buf.free()
                return .exception
            }
            let replResultStr = ctx.toString(replResult)
            if let rs = replResultStr.stringValue {
                buf.concat(rs)
            }
            replResult.freeValue()
            replResultStr.freeValue()
        } else if let rs = replaceStr {
            // Apply $-substitution.
            let sub = js_getSubstitution(
                ctx: ctx,
                matched: matchedStr,
                input: inputStr,
                matchStart: matchStart,
                captures: resObj,
                replacement: rs
            )
            buf.concat(sub)
        }

        lastMatchEnd = matchStart + matchLen

        // For global, check if match was empty to avoid infinite loop.
        if isGlobal && matchLen == 0 {
            var li = js_regexp_getLastIndex(obj)
            li = js_regexp_advanceIndex(inputStr, index: li, unicode: isUnicode)
            js_regexp_setLastIndex(obj, value: li)
        }

        if !isGlobal {
            break
        }
    }

    // Append the tail of the input after the last match.
    if lastMatchEnd < inputStr.len {
        if let tail = jeffJS_subString(str: inputStr, start: lastMatchEnd, end: inputStr.len) {
            buf.concat(tail)
        }
    }

    guard let resultStr = buf.end() else {
        return ctx.throwOutOfMemory()
    }
    return JeffJSValue.makeString(resultStr)
}

/// `RegExp.prototype[@@search](string)`
///
/// Mirrors QuickJS `js_regexp_Symbol_search`.
///
/// Saves and restores lastIndex.  Returns the index of the first match, or -1.
func js_regexp_Symbol_search(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    guard let obj = this.toObject() else {
        return ctx.throwTypeError("[Symbol.search] called on non-object")
    }

    // Save lastIndex.
    let savedLastIndex = js_regexp_getLastIndex(obj)
    js_regexp_setLastIndex(obj, value: 0)

    let result = js_regexp_exec(ctx: ctx, this: this, argv: argv)

    // Restore lastIndex.
    js_regexp_setLastIndex(obj, value: savedLastIndex)

    if result.isException {
        return .exception
    }
    if result.isNull {
        return JeffJSValue.newInt32(-1)
    }

    guard let resObj = result.toObject() else {
        return JeffJSValue.newInt32(-1)
    }

    let indexVal = resObj.getOwnPropertyValue(atom: JeffJSAtomID.JS_ATOM_index.rawValue)
    return indexVal.dupValue()
}

/// `RegExp.prototype[@@split](string, limit)`
///
/// Mirrors QuickJS `js_regexp_Symbol_split`.
func js_regexp_Symbol_split(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    guard let obj = this.toObject() else {
        return ctx.throwTypeError("[Symbol.split] called on non-object")
    }

    let inputVal = argv.count >= 1 ? argv[0] : JeffJSValue.undefined
    let limitVal = argv.count >= 2 ? argv[1] : JeffJSValue.undefined

    guard let inputStr = js_regexp_coerceToString(ctx: ctx, val: inputVal) else {
        return .exception
    }

    // Compute limit.
    let limit: UInt32
    if limitVal.isUndefined {
        limit = UInt32.max
    } else if limitVal.isInt {
        limit = UInt32(bitPattern: limitVal.toInt32())
    } else if limitVal.isFloat64 {
        let d = limitVal.toFloat64()
        limit = (d.isNaN || d.isInfinite || d < 0) ? 0 : (d > Double(UInt32.max) ? UInt32.max : UInt32(d))
    } else {
        limit = UInt32.max
    }

    if limit == 0 {
        // Return an empty array.
        let arr = jeffJS_createObject(ctx: ctx, proto: nil,
                                       classID: UInt16(JeffJSClassID.array.rawValue))
        arr.payload = .array(size: 0, values: [], count: 0)
        arr.fastArray = true
        return JeffJSValue.makeObject(arr)
    }

    let flags = js_regexp_getFlags(obj)
    let isUnicode = (flags & LRE_FLAG_UNICODE) != 0 || (flags & LRE_FLAG_UNICODE_SETS) != 0

    // Use execInternal directly so we can control startIndex per iteration
    // and get exact capture positions without depending on lastIndex tracking.
    let captureCount = js_regexp_getCaptureCount(obj)

    var results: [JeffJSValue] = []
    var p = 0  // Previous match end position.
    var q = 0  // Current search position.

    while q <= inputStr.len {
        // Execute regex starting from position q using execInternal directly.
        let matchResult = js_regexp_execInternal(
            ctx: ctx,
            obj: obj,
            inputStr: inputStr,
            startIndex: q,
            flags: flags | LRE_FLAG_STICKY,  // Force sticky to only match at position q
            captureCount: captureCount
        )

        guard let captures = matchResult, !captures.isEmpty else {
            // No match at position q -- advance and retry.
            q = js_regexp_advanceIndex(inputStr, index: q, unicode: isUnicode)
            continue
        }

        let matchStart = captures[0].start
        let e = captures[0].end

        if e == p {
            // Empty match at the same position as previous -- advance to avoid infinite loop.
            q = js_regexp_advanceIndex(inputStr, index: q, unicode: isUnicode)
            continue
        }

        // Add substring from p to matchStart.
        if let sub = jeffJS_subString(str: inputStr, start: p, end: matchStart) {
            results.append(JeffJSValue.makeString(sub))
        }
        if UInt32(results.count) >= limit {
            break
        }

        // Add capture groups from the exec result.
        for i in 1 ..< captures.count {
            let capStart = captures[i].start
            let capEnd = captures[i].end
            if capStart < 0 || capEnd < 0 {
                results.append(.undefined)
            } else {
                let capStr = jeffJS_subString(str: inputStr, start: capStart, end: capEnd)
                results.append(capStr.map { JeffJSValue.makeString($0) } ?? .undefined)
            }
            if UInt32(results.count) >= limit {
                break
            }
        }

        p = e
        q = e
    }

    // Add the tail.
    if UInt32(results.count) < limit {
        if let tail = jeffJS_subString(str: inputStr, start: p, end: inputStr.len) {
            results.append(JeffJSValue.makeString(tail))
        }
    }

    // Build result array using newArray() so it has a proper length property.
    let arrVal = ctx.newArray()
    if let arr = arrVal.toObject() {
        arr.payload = .array(
            size: UInt32(results.count),
            values: results,
            count: UInt32(results.count)
        )
        arr.fastArray = true
    }
    _ = ctx.setPropertyStr(obj: arrVal, name: "length",
                           value: .newInt32(Int32(results.count)))

    return arrVal
}

/// `get RegExp[@@species]` -- returns the constructor.
func js_regexp_get_species(
    ctx: JeffJSContext,
    this: JeffJSValue
) -> JeffJSValue {
    return this.dupValue()
}

// MARK: - RegExp String Iterator (JS_CLASS_REGEXP_STRING_ITERATOR)

/// Internal state for the RegExp String Iterator.
///
/// Mirrors QuickJS `JSRegExpStringIteratorData`.
final class JSRegExpStringIteratorData {
    var iteratingRegExp: JeffJSObject
    var iteratedString: JeffJSString
    var isGlobal: Bool
    var isUnicode: Bool
    var done: Bool

    init(iteratingRegExp: JeffJSObject,
         iteratedString: JeffJSString,
         isGlobal: Bool,
         isUnicode: Bool,
         done: Bool) {
        self.iteratingRegExp = iteratingRegExp
        self.iteratedString = iteratedString
        self.isGlobal = isGlobal
        self.isUnicode = isUnicode
        self.done = done
    }
}

/// `%RegExpStringIteratorPrototype%.next()`
///
/// Mirrors QuickJS `js_regexp_string_iterator_next`.
func js_regexp_string_iterator_next(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    guard let iterObj = this.toObject(),
          case .opaque(let opaque) = iterObj.payload,
          let data = opaque as? JSRegExpStringIteratorData else {
        return ctx.throwTypeError("RegExp String Iterator next called on incompatible receiver")
    }

    if data.done {
        return js_createIteratorResult(ctx: ctx, value: .undefined, done: true)
    }

    let regexpThisVal = JeffJSValue.makeObject(data.iteratingRegExp)
    let result = js_regexp_exec(
        ctx: ctx,
        this: regexpThisVal,
        argv: [JeffJSValue.makeString(data.iteratedString.retain())]
    )

    if result.isException {
        return .exception
    }

    if result.isNull {
        data.done = true
        return js_createIteratorResult(ctx: ctx, value: .undefined, done: true)
    }

    if !data.isGlobal {
        data.done = true
        return js_createIteratorResult(ctx: ctx, value: result, done: false)
    }

    // Global: check if match is empty string.
    if let resObj = result.toObject() {
        let matchStr = resObj.getArrayElement(0)
        if let ms = matchStr.stringValue, ms.len == 0 {
            var li = js_regexp_getLastIndex(data.iteratingRegExp)
            li = js_regexp_advanceIndex(
                data.iteratedString, index: li, unicode: data.isUnicode
            )
            js_regexp_setLastIndex(data.iteratingRegExp, value: li)
        }
    }

    return js_createIteratorResult(ctx: ctx, value: result, done: false)
}

// MARK: - Internal helpers

/// Check if a RegExp object is a "standard" regexp -- i.e., its exec, flags,
/// etc. have not been overridden.  Used for fast-path optimization in String
/// methods.
///
/// Mirrors QuickJS `js_is_standard_regexp`.
func js_isStandardRegexp(_ obj: JeffJSObject) -> Bool {
    // A standard regexp has classID == regexp AND no overridden exec/flags.
    if obj.classID != JSClassID.JS_CLASS_REGEXP.rawValue {
        return false
    }

    // Check that `exec` has not been overridden on the instance.
    let (execProp, _) = jeffJS_findOwnProperty(obj: obj, atom: JeffJSAtomID.JS_ATOM_exec.rawValue)
    if execProp != nil {
        return false  // exec has been overridden.
    }

    // Check that `flags` has not been overridden on the instance.
    let (flagsProp, _) = jeffJS_findOwnProperty(obj: obj, atom: JeffJSAtomID.JS_ATOM_flags.rawValue)
    if flagsProp != nil {
        return false  // flags has been overridden.
    }

    return true
}

/// Compile a regexp pattern into bytecode using the real regex engine.
///
/// Calls `lreCompile` from JeffJSRegExp.swift to produce executable bytecode
/// and wraps the result in a JeffJSString for storage in the RegExp payload.
///
/// Mirrors QuickJS `lre_compile`.
private func js_regexp_compile(
    ctx: JeffJSContext,
    pattern: JeffJSString?,
    flags: Int
) -> JeffJSString? {
    let pat = pattern ?? JeffJSString(swiftString: "")
    let patternSwift = pat.toSwiftString()

    // Convert integer flag bitmask to JeffJSRegExpFlags option set.
    var regexpFlags = JeffJSRegExpFlags()
    if flags & LRE_FLAG_GLOBAL != 0       { regexpFlags.insert(.global) }
    if flags & LRE_FLAG_IGNORECASE != 0   { regexpFlags.insert(.ignoreCase) }
    if flags & LRE_FLAG_MULTILINE != 0    { regexpFlags.insert(.multiline) }
    if flags & LRE_FLAG_DOTALL != 0       { regexpFlags.insert(.dotAll) }
    if flags & LRE_FLAG_UNICODE != 0      { regexpFlags.insert(.unicode) }
    if flags & LRE_FLAG_STICKY != 0       { regexpFlags.insert(.sticky) }
    if flags & LRE_FLAG_INDICES != 0      { regexpFlags.insert(.hasIndices) }
    if flags & LRE_FLAG_UNICODE_SETS != 0 { regexpFlags.insert(.unicodeSets) }

    let compiled = lreCompile(pattern: patternSwift, flags: regexpFlags)

    if let error = compiled.error {
        _ = ctx.throwSyntaxError(message: "Invalid regular expression: /\(patternSwift)/: \(error)")
        return nil
    }

    let bytecode = compiled.bytecode
    guard !bytecode.isEmpty else {
        _ = ctx.throwSyntaxError(message: "Invalid regular expression: empty bytecode")
        return nil
    }

    // Wrap the [UInt8] bytecode into a JeffJSString (str8) for storage.
    let bc = JeffJSString(
        refCount: 1,
        len: bytecode.count,
        isWideChar: false,
        storage: .str8(bytecode)
    )
    return bc
}

/// Get the `lastIndex` property value from a RegExp object.
///
/// QuickJS stores lastIndex as the FIRST property of every RegExp for
/// fast-path access (property index 0).
///
/// Mirrors QuickJS fast-path `lastIndex` access.
private func js_regexp_getLastIndex(_ obj: JeffJSObject) -> Int {
    // Try the fast path: first property.
    if !obj.prop.isEmpty {
        if case .value(let v) = obj.prop[0] {
            if v.isInt {
                return Int(v.toInt32())
            } else if v.isFloat64 {
                return Int(v.toFloat64())
            }
        }
    }
    return 0
}

/// Set the `lastIndex` property on a RegExp object.
///
/// Uses the fast path (property index 0).
private func js_regexp_setLastIndex(_ obj: JeffJSObject, value: Int) {
    let v = JeffJSValue.newInt32(Int32(value))
    if !obj.prop.isEmpty {
        obj.prop[0] = .value(v)
    } else {
        obj.prop.append(.value(v))
    }
}

/// Advance a string index by one code point, handling surrogate pairs
/// when the `unicode` flag is set.
///
/// Mirrors QuickJS `js_regexp_advance_string_index`.
private func js_regexp_advanceIndex(
    _ str: JeffJSString,
    index: Int,
    unicode: Bool
) -> Int {
    if !unicode || index >= str.len {
        return index + 1
    }

    let ch = jeffJS_getString(str: str, at: index)
    // Check for high surrogate.
    if ch >= 0xD800 && ch <= 0xDBFF && index + 1 < str.len {
        let ch2 = jeffJS_getString(str: str, at: index + 1)
        if ch2 >= 0xDC00 && ch2 <= 0xDFFF {
            return index + 2  // Skip the surrogate pair.
        }
    }
    return index + 1
}

/// Coerce a value to a JeffJSString (for use as input to regex operations).
///
/// Mirrors QuickJS `JS_ToString`.
private func js_regexp_coerceToString(
    ctx: JeffJSContext,
    val: JeffJSValue
) -> JeffJSString? {
    if let s = val.stringValue {
        return s
    }
    if val.isUndefined {
        return JeffJSString(swiftString: "undefined")
    }
    if val.isNull {
        return JeffJSString(swiftString: "null")
    }
    if val.isBool {
        return JeffJSString(swiftString: val.toBool() ? "true" : "false")
    }
    if val.isInt {
        return JeffJSString(swiftString: "\(val.toInt32())")
    }
    if val.isFloat64 {
        return JeffJSString(swiftString: "\(val.toFloat64())")
    }
    // In a full build we would call JS_ToString which handles objects via
    // ToPrimitive.  For now, return "".
    return JeffJSString(swiftString: "")
}

/// Capture group result from the regex engine.
struct JSRegExpCapture {
    var start: Int
    var end: Int
}

/// Execute the regex engine on the input string.
///
/// Extracts the compiled bytecode from the RegExp object and delegates to
/// `lreExec` from JeffJSRegExp.swift.  On a successful match, returns an
/// array of `JSRegExpCapture` (one per capture group, including group 0 for
/// the full match).  Returns `nil` when there is no match.
///
/// Mirrors QuickJS `lre_exec`.
private func js_regexp_execInternal(
    ctx: JeffJSContext,
    obj: JeffJSObject,
    inputStr: JeffJSString,
    startIndex: Int,
    flags: Int,
    captureCount: Int
) -> [JSRegExpCapture]? {
    // 1. Extract the compiled bytecode stored in the .regexp payload.
    guard case .regexp(_, let bytecodeStr) = obj.payload,
          let bc = bytecodeStr else {
        return nil
    }

    // Unwrap the JeffJSString -> [UInt8].
    let bytecode: [UInt8]
    if case .str8(let buf) = bc.storage {
        bytecode = Array(buf.prefix(bc.len))
    } else {
        return nil  // bytecode must be str8
    }

    guard bytecode.count >= 5 else { return nil }  // need at least the header

    // 2. Convert the input JeffJSString to [UInt32] code units.
    //    For non-unicode mode we use UTF-16 code units (matching JS semantics).
    let inputCodeUnits: [UInt32]
    let isUnicode = (flags & LRE_FLAG_UNICODE) != 0 || (flags & LRE_FLAG_UNICODE_SETS) != 0
    if isUnicode {
        let s = inputStr.toSwiftString()
        inputCodeUnits = Array(s.unicodeScalars.map { $0.value })
    } else {
        // UTF-16 code units, matching JS string semantics.
        let s = inputStr.toSwiftString()
        inputCodeUnits = Array(s.utf16.map { UInt32($0) })
    }

    // 3. Build JeffJSRegExpFlags from the integer bitmask.
    var regexpFlags = JeffJSRegExpFlags()
    if flags & LRE_FLAG_GLOBAL != 0       { regexpFlags.insert(.global) }
    if flags & LRE_FLAG_IGNORECASE != 0   { regexpFlags.insert(.ignoreCase) }
    if flags & LRE_FLAG_MULTILINE != 0    { regexpFlags.insert(.multiline) }
    if flags & LRE_FLAG_DOTALL != 0       { regexpFlags.insert(.dotAll) }
    if flags & LRE_FLAG_UNICODE != 0      { regexpFlags.insert(.unicode) }
    if flags & LRE_FLAG_STICKY != 0       { regexpFlags.insert(.sticky) }
    if flags & LRE_FLAG_INDICES != 0      { regexpFlags.insert(.hasIndices) }
    if flags & LRE_FLAG_UNICODE_SETS != 0 { regexpFlags.insert(.unicodeSets) }

    let isSticky = (flags & LRE_FLAG_STICKY) != 0

    // 4. Execute. The VM now correctly uses `startPos` to begin matching
    //    at the specified position within the full input array, so we no
    //    longer need to create a sliced copy per starting position.
    //    For non-global/non-sticky regexps, we try successive start positions.
    //    For sticky, we only try at startIndex.
    var pos = startIndex
    while pos <= inputCodeUnits.count {
        let result = lreExec(bytecode: bytecode, input: inputCodeUnits,
                             startPos: pos, flags: regexpFlags)

        if result.result == .match {
            // Captures already have correct offsets (no slicing adjustment needed).
            var captures = [JSRegExpCapture]()
            for cap in result.captures {
                if let c = cap {
                    captures.append(JSRegExpCapture(start: c.start, end: c.end))
                } else {
                    captures.append(JSRegExpCapture(start: -1, end: -1))
                }
            }
            // Ensure at least one capture (the full match).
            if captures.isEmpty {
                return nil
            }
            return captures
        }

        if result.result == .error {
            return nil
        }

        // noMatch: if sticky, fail immediately; otherwise try next position.
        if isSticky {
            return nil
        }
        pos += 1
    }

    return nil
}

/// Build the `indices` array for `exec` result when the `d` flag is set.
///
/// Each element is a 2-element array [start, end] or undefined for
/// unmatched captures.
///
/// Mirrors QuickJS `js_regexp_build_indices`.
private func js_regexp_buildIndicesArray(
    ctx: JeffJSContext,
    captures: [JSRegExpCapture]
) -> JeffJSObject {
    let indicesArray = jeffJS_createObject(ctx: ctx, proto: nil,
                                            classID: UInt16(JeffJSClassID.array.rawValue))
    var vals: [JeffJSValue] = []

    for cap in captures {
        if cap.start < 0 || cap.end < 0 {
            vals.append(.undefined)
        } else {
            let pair = jeffJS_createObject(ctx: ctx, proto: nil,
                                            classID: UInt16(JeffJSClassID.array.rawValue))
            pair.payload = .array(
                size: 2,
                values: [JeffJSValue.newInt32(Int32(cap.start)),
                         JeffJSValue.newInt32(Int32(cap.end))],
                count: 2
            )
            pair.fastArray = true
            vals.append(JeffJSValue.makeObject(pair))
        }
    }

    indicesArray.payload = .array(
        size: UInt32(vals.count),
        values: vals,
        count: UInt32(vals.count)
    )
    indicesArray.fastArray = true

    return indicesArray
}

/// Implements the `GetSubstitution` abstract operation for
/// `String.prototype.replace` / `RegExp.prototype[@@replace]`.
///
/// Processes `$`-replacement patterns:
///   - `$$` -> `$`
///   - `$&` -> the matched substring
///   - `` $` `` -> the portion before the match
///   - `$'` -> the portion after the match
///   - `$nn` -> the nth capture group
///   - `$<name>` -> named capture group
///
/// Mirrors QuickJS `js_get_substitution`.
private func js_getSubstitution(
    ctx: JeffJSContext,
    matched: JeffJSString?,
    input: JeffJSString,
    matchStart: Int,
    captures: JeffJSObject,
    replacement: JeffJSString
) -> JeffJSString {
    let buf = JeffJSStringBuffer()
    let matchLen = matched?.len ?? 0

    var i = 0
    while i < replacement.len {
        let ch = jeffJS_getString(str: replacement, at: i)

        if ch != 0x24 /* $ */ || i + 1 >= replacement.len {
            buf.putc(ch)
            i += 1
            continue
        }

        let next = jeffJS_getString(str: replacement, at: i + 1)

        switch next {
        case 0x24: // $$
            buf.putc8(0x24)
            i += 2

        case 0x26: // $& -- matched substring
            if let m = matched {
                buf.concat(m)
            }
            i += 2

        case 0x60: // $` -- before match
            if let pre = jeffJS_subString(str: input, start: 0, end: matchStart) {
                buf.concat(pre)
            }
            i += 2

        case 0x27: // $' -- after match
            let afterStart = matchStart + matchLen
            if let post = jeffJS_subString(str: input, start: afterStart, end: input.len) {
                buf.concat(post)
            }
            i += 2

        case 0x30...0x39: // $0-$9 -- capture group reference
            var num = Int(next - 0x30)
            i += 2

            // Check for two-digit reference.
            if i < replacement.len {
                let digit2 = jeffJS_getString(str: replacement, at: i)
                if digit2 >= 0x30 && digit2 <= 0x39 {
                    let twoDigit = num * 10 + Int(digit2 - 0x30)
                    // Only use two-digit if it is a valid capture index.
                    let captureCount = js_regexp_getCaptureCount(captures)
                    if twoDigit > 0 && twoDigit <= captureCount {
                        num = twoDigit
                        i += 1
                    }
                }
            }

            if num > 0 {
                let capVal = captures.getArrayElement(UInt32(num))
                if let capStr = capVal.stringValue {
                    buf.concat(capStr)
                }
            } else {
                // $0 is not a valid reference; emit literally.
                buf.putc8(0x24)
                buf.putc(next)
            }

        case 0x3C: // $< -- named capture group
            // Find the closing '>'.
            var j = i + 2
            while j < replacement.len {
                if jeffJS_getString(str: replacement, at: j) == 0x3E { break }
                j += 1
            }

            if j >= replacement.len {
                // No closing '>' -- emit literally.
                buf.putc8(0x24)
                buf.putc(next)
                i += 2
            } else {
                // Extract the name.  Named group lookup would go here.
                // For now, emit undefined (no named groups support yet).
                i = j + 1
            }

        default:
            // Not a recognized substitution pattern -- emit the '$' literally.
            buf.putc8(0x24)
            i += 1
        }
    }

    return buf.end() ?? JeffJSString(swiftString: "")
}

/// Create an iterator result object { value: val, done: isDone }.
///
/// Mirrors QuickJS `js_create_iterator_result`.
private func js_createIteratorResult(
    ctx: JeffJSContext,
    value: JeffJSValue,
    done: Bool
) -> JeffJSValue {
    let obj = jeffJS_createObject(ctx: ctx, proto: nil,
                                   classID: UInt16(JeffJSClassID.object.rawValue))

    // Set `value` property.
    let valueProp = JeffJSShapeProperty(
        atom: JeffJSAtomID.JS_ATOM_value.rawValue,
        flags: [.writable, .enumerable, .configurable]
    )
    obj.shape?.prop.append(valueProp)
    obj.prop.append(.value(value.dupValue()))

    // Set `done` property.
    let doneProp = JeffJSShapeProperty(
        atom: JeffJSAtomID.JS_ATOM_done.rawValue,
        flags: [.writable, .enumerable, .configurable]
    )
    obj.shape?.prop.append(doneProp)
    obj.prop.append(.value(JeffJSValue.newBool(done)))

    return JeffJSValue.makeObject(obj)
}

// MARK: - Property table definitions

/// Function list for `RegExp.prototype`.
/// Mirrors QuickJS `js_regexp_proto_funcs`.
let js_regexp_proto_funcs: [(name: String, func_: JSCFunctionType, length: Int)] = [
    ("exec", .generic({ ctx, this, argv in
        js_regexp_exec(ctx: ctx, this: this, argv: argv)
    }), 1),
    ("test", .generic({ ctx, this, argv in
        js_regexp_test(ctx: ctx, this: this, argv: argv)
    }), 1),
    ("toString", .generic({ ctx, this, argv in
        js_regexp_toString(ctx: ctx, this: this, argv: argv)
    }), 0),
    ("compile", .generic({ ctx, this, argv in
        js_regexp_compile(ctx: ctx, this: this, argv: argv)
    }), 2),
]

/// Getter list for `RegExp.prototype`.
/// Mirrors QuickJS `js_regexp_proto_getters`.
let js_regexp_proto_getters: [(name: String, getter: JSCFunctionType)] = [
    ("global",      .getter({ ctx, this in js_regexp_get_global(ctx: ctx, this: this) })),
    ("ignoreCase",  .getter({ ctx, this in js_regexp_get_ignoreCase(ctx: ctx, this: this) })),
    ("multiline",   .getter({ ctx, this in js_regexp_get_multiline(ctx: ctx, this: this) })),
    ("dotAll",      .getter({ ctx, this in js_regexp_get_dotAll(ctx: ctx, this: this) })),
    ("unicode",     .getter({ ctx, this in js_regexp_get_unicode(ctx: ctx, this: this) })),
    ("unicodeSets", .getter({ ctx, this in js_regexp_get_unicodeSets(ctx: ctx, this: this) })),
    ("sticky",      .getter({ ctx, this in js_regexp_get_sticky(ctx: ctx, this: this) })),
    ("hasIndices",  .getter({ ctx, this in js_regexp_get_hasIndices(ctx: ctx, this: this) })),
    ("source",      .getter({ ctx, this in js_regexp_get_source(ctx: ctx, this: this) })),
    ("flags",       .getter({ ctx, this in js_regexp_get_flags(ctx: ctx, this: this) })),
]

// MARK: - Initialization

/// Register the RegExp class and install the constructor and prototype.
///
/// Mirrors QuickJS `JS_AddIntrinsicRegExp`.
func js_addIntrinsicRegExp(rt: JeffJSRuntime) {
    // Register JS_CLASS_REGEXP.
    let regexpClassIdx = Int(JSClassID.JS_CLASS_REGEXP.rawValue)
    while rt.classArray.count <= regexpClassIdx {
        rt.classArray.append(JeffJSClass())
    }
    rt.classArray[regexpClassIdx] = JeffJSClass()
    rt.classArray[regexpClassIdx].classNameAtom = JeffJSAtomID.JS_ATOM_RegExp.rawValue

    // Register JS_CLASS_REGEXP_STRING_ITERATOR.
    // (Using stringIterator as a placeholder until the dedicated class ID exists.)
    let iterClassIdx = Int(JeffJSClassID.stringIterator.rawValue)
    while rt.classArray.count <= iterClassIdx {
        rt.classArray.append(JeffJSClass())
    }

    if rt.classCount <= iterClassIdx + 1 {
        rt.classCount = iterClassIdx + 1
    }
}

/// Initialize RegExp on a context.
///
/// In a full build this would:
///   1. Create RegExp.prototype with exec, test, toString, compile,
///      all flag getters, and Symbol methods.
///   2. Create RegExp constructor (length=2).
///   3. Set RegExp[@@species].
///   4. Install RegExp on the global object.
///   5. Create %RegExpStringIteratorPrototype% with next().
func js_initRegExp(ctx: JeffJSContext) {
    // The plumbing for JS_NewCFunction2 / JS_SetConstructor /
    // JS_DefinePropertyValueStr does not yet exist in JeffJS, so we
    // record the intent here and the setup will be completed when the
    // context infrastructure is in place.
}
