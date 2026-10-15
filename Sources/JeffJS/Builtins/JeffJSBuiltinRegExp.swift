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
nonisolated private func js_regexp_getPattern(_ obj: JeffJSObject) -> JeffJSString? {
    if case .regexp(let pattern, _) = obj.payload {
        return pattern
    }
    return nil
}

// MARK: - Pattern ownership
//
// A RegExp payload owns one counted JS reference on its pattern string, like
// QuickJS's regexp object holds `re->pattern` until `js_regexp_finalizer`.
// The count is taken when the pattern is stored (constructor, compile(),
// the matchAll copy) and dropped by `js_regexp_releasePattern` when the
// object dies (`freeObject`) or compile() replaces the pattern. The payload's
// Swift reference alone only kept the memory: the string's JS refcount
// reached zero as soon as the value that supplied the pattern died, the
// `source` getter then handed the freed string back to JS with a fresh count,
// and every later dup/free touched a freed string (JEFFJS_ZOMBIES=1 on
// apple.com: marked.js's `edit(re).replace(..).getRegex()`, which rebuilds
// patterns from `re.source`).
//
// Every pattern string satisfies the string invariant "refCount > 0 means one
// outstanding JS ARC retain", so the payload's count can be dropped with a
// plain `freeValue` and `source` can return `borrowedString(p).dupValue()`.

/// Take the payload's reference for a pattern supplied as a JS value. A flat
/// string is shared (one more count on it); a rope or buffer is copied into a
/// fresh flat string (the rope's cached `flat` is owned by the rope and has
/// no JS reference of its own to count against). nil for non-strings.
nonisolated private func js_regexp_adoptPattern(_ val: JeffJSValue) -> JeffJSString? {
    guard let sb = val.stringBase else { return nil }
    if sb.kind == JeffJSStringBase.kindFlat {
        _ = val.dupValue()
        return unsafeDowncast(sb, to: JeffJSString.self)
    }
    guard let flat = val.stringValue else { return nil }
    return js_regexp_adoptFreshPattern(
        JeffJSString(len: flat.len, isWideChar: flat.isWideChar, storage: flat.storage))
}

/// A newly created pattern string (refCount 1, never wrapped): wrapping it
/// once gives it the JS ARC retain its single count stands for.
nonisolated private func js_regexp_adoptFreshPattern(_ s: JeffJSString) -> JeffJSString {
    _ = JeffJSValue.makeString(s)
    return s
}

/// Share another RegExp's pattern: one more count on it.
nonisolated private func js_regexp_sharePattern(_ s: JeffJSString) -> JeffJSString {
    _ = JeffJSValue.borrowedString(s).dupValue()
    return s
}

/// Drop the payload's reference on its pattern (the object is dying, or
/// compile() is replacing the pattern).
nonisolated func js_regexp_releasePattern(_ s: JeffJSString?) {
    if let s { JeffJSValue.borrowedString(s).freeValue() }
}

/// Extract the compiled bytecode from a RegExp object.
nonisolated private func js_regexp_getBytecode(_ obj: JeffJSObject) -> JeffJSString? {
    if case .regexp(_, let bytecode) = obj.payload {
        return bytecode
    }
    return nil
}

/// Extract flags from the compiled regex bytecode header.
///
/// In QuickJS the first byte of the regex bytecode stores the flags.
/// Layout: `lre_byte_code[0]` = flags (LRE_FLAG_*).
nonisolated private func js_regexp_getFlags(_ obj: JeffJSObject) -> Int {
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
nonisolated private func js_regexp_getCaptureCount(_ obj: JeffJSObject) -> Int {
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
nonisolated(unsafe) private let js_regexp_flag_chars: [(flag: Int, char: Character)] = [
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
nonisolated private func js_regexp_parseFlags(_ flagsStr: JeffJSString?) -> Int {
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
nonisolated private func js_regexp_buildFlagsString(_ flags: Int) -> JeffJSString {
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
nonisolated func js_regexp_constructor(
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

        // Extract the source pattern (shared: the new payload takes a count).
        patternStr = js_regexp_getPattern(patternObj).map(js_regexp_sharePattern)

        if flagsArg.isUndefined {
            // Use the original flags.
            let flagBits = js_regexp_getFlags(patternObj)
            flagsStr = js_regexp_buildFlagsString(flagBits)
        } else {
            // Use the provided flags.
            flagsStr = flagsArg.stringValue
        }
    } else {
        // Coerce pattern to string (undefined -> ""); the payload owns a
        // counted reference on it (see "Pattern ownership").
        if patternArg.isUndefined {
            patternStr = js_regexp_adoptFreshPattern(JeffJSString(swiftString: ""))
        } else if patternArg.isString {
            patternStr = js_regexp_adoptPattern(patternArg)
        } else {
            let sv = ctx.toString(patternArg)
            if sv.isException { return .exception }
            patternStr = js_regexp_adoptPattern(sv)
            sv.freeValue()
        }
        if patternStr == nil {
            patternStr = js_regexp_adoptFreshPattern(JeffJSString(swiftString: ""))
        }
        flagsStr = flagsArg.isUndefined ? nil : flagsArg.stringValue
    }

    // Parse flags.
    let flagBits = js_regexp_parseFlags(flagsStr)
    if flagBits < 0 {
        js_regexp_releasePattern(patternStr)
        return ctx.throwTypeError("RegExp: invalid flags")
    }

    // Compile the pattern.
    let compiledBytecode = js_regexp_compile(ctx: ctx, pattern: patternStr, flags: flagBits)
    if compiledBytecode == nil {
        // Compilation error was already thrown.
        js_regexp_releasePattern(patternStr)
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
nonisolated func js_regexp_exec(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    guard let obj = this.toObject(),
          obj.classID == JSClassID.JS_CLASS_REGEXP.rawValue else {
        return ctx.throwTypeError("RegExp.prototype.exec called on incompatible receiver")
    }

    let inputVal = argv.count >= 1 ? argv[0] : JeffJSValue.undefined
    guard let input = js_regexp_coerceInput(ctx: ctx, val: inputVal) else {
        return .exception
    }
    defer { input.value.freeValue() }
    let inputStr = input.str

    let flags = js_regexp_getFlags(obj)
    let isGlobal = (flags & LRE_FLAG_GLOBAL) != 0
    let isSticky = (flags & LRE_FLAG_STICKY) != 0
    let hasIndices = (flags & LRE_FLAG_INDICES) != 0

    // Read lastIndex: always (ToLength may run a `valueOf`), used only when
    // global or sticky.
    guard let readLastIndex = js_regexp_getLastIndex(ctx, obj) else { return .exception }
    let lastIndex = (isGlobal || isSticky) ? readLastIndex : 0

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
            if !js_regexp_setLastIndex(ctx, obj, value: 0) { return .exception }
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

    // `groups`: named capture groups, if the pattern has any. The names are
    // parsed once per compiled pattern (this used to copy the bytecode and
    // re-parse it on every match).
    var groupsVal: JeffJSValue = .undefined
    if case .regexp(_, let bytecodeStr) = obj.payload, let bc = bytecodeStr {
        let groupNames = ctx.rt.regexCaches.groupNames(of: bc)
        var hasNamedGroup = false
        for name in groupNames { if name != nil { hasNamedGroup = true; break } }
        if hasNamedGroup {
            // Per ES2018 the `groups` object has a *null* prototype, so a group
            // named "toString"/"constructor" cannot shadow Object.prototype.
            let groupsObj = ctx.newObjectProto(proto: .null)
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

    // length, index, input, groups: on the shared match-result shape after
    // the first result, four slot appends instead of four transition lookups.
    let lengthVal = JeffJSValue.newInt32(Int32(arrayValues.count))
    let indexVal = JeffJSValue.newInt32(Int32(matchStart))
    let inputStrVal = input.value.dupValue()   // the subject: its own counted reference
    if let shape = ctx.regexpMatchShape, shape.isHashed, shape.propCount == 4,
       resultArray.propValues.count == 0, let old = resultArray.shape {
        shape.refCount += 1
        resultArray.shape = shape
        jeffJS_leaveShape(ctx.rt, old)
        resultArray.appendDataValue(lengthVal)
        resultArray.appendDataValue(indexVal)
        resultArray.appendDataValue(inputStrVal)
        resultArray.appendDataValue(groupsVal)
    } else {
        jeffJS_appendOwnProperty(ctx, resultArray, atom: JeffJSAtomID.JS_ATOM_length.rawValue,
                                 flags: [.writable], value: lengthVal)
        jeffJS_appendOwnProperty(ctx, resultArray, atom: JeffJSAtomID.JS_ATOM_index.rawValue,
                                 flags: [.writable, .enumerable, .configurable], value: indexVal)
        jeffJS_appendOwnProperty(ctx, resultArray, atom: JeffJSAtomID.JS_ATOM_input.rawValue,
                                 flags: [.writable, .enumerable, .configurable], value: inputStrVal)
        jeffJS_appendOwnProperty(ctx, resultArray, atom: JeffJSAtomID.JS_ATOM_groups.rawValue,
                                 flags: [.writable, .enumerable, .configurable], value: groupsVal)
        if ctx.regexpMatchShape == nil, let sh = resultArray.shape, sh.isHashed, sh.propCount == 4,
           resultArray.propValues.count == 4 {
            sh.refCount += 1   // the context keeps it alive
            ctx.regexpMatchShape = sh
        }
    }

    // Set `indices` property (if 'd' flag).
    if hasIndices {
        let indicesArray = js_regexp_buildIndicesArray(ctx: ctx, captures: captures)
        jeffJS_appendOwnProperty(ctx, resultArray,
                                 atom: JeffJSAtomID.JS_ATOM_indices.rawValue,
                                 flags: [.writable, .enumerable, .configurable],
                                 value: JeffJSValue.makeObject(indicesArray))
    }

    // Update lastIndex.
    let resultVal = JeffJSValue.makeObject(resultArray)
    if isGlobal || isSticky {
        if !js_regexp_setLastIndex(ctx, obj, value: matchEnd) {
            resultVal.freeValue()
            return .exception
        }
    }

    return resultVal
}

// MARK: - RegExpExec (ES §22.2.7.1)

/// `magic` of the intrinsic RegExp.prototype.exec (a `.generic` native never
/// reads its magic): RegExpExec tells it apart from a page's own `exec`.
nonisolated(unsafe) let JEFFJS_REGEXP_EXEC_MAGIC: Int16 = 0x7E5E

/// The `exec` RegExpExec must call instead of the builtin one: `R.exec` when
/// it is callable and not the intrinsic (own or inherited), else nil (the
/// caller keeps its native path). `.exception` when the read threw. The
/// symbol methods used to run the builtin matcher whatever `exec` was, so
/// core-js's fix-regexp-well-known-symbol-logic judged @@match / @@replace /
/// @@search broken and replaced String.prototype.match / replace / search
/// with JS wrappers on every page that ships it.
nonisolated func js_regexp_userExecFunction(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue? {
    guard this.isObject else { return nil }
    let ex = ctx.getProperty(obj: this, atom: JeffJSAtomID.JS_ATOM_exec.rawValue)
    if ex.isException { return .exception }
    if let o = ex.toObject(), o.isCallable {
        if case .cFunc(_, _, _, _, let m) = o.payload, m == JEFFJS_REGEXP_EXEC_MAGIC {
            ex.freeValue()
            return nil
        }
        return ex
    }
    ex.freeValue()
    return nil
}

/// RegExpExec with a resolved `exec` (see js_regexp_userExecFunction): calls
/// it and requires an object or null (step 2.b); nil `userExec` = builtin.
nonisolated func js_regexp_execVia(ctx: JeffJSContext, this: JeffJSValue, input: JeffJSValue,
                       userExec: JeffJSValue?) -> JeffJSValue {
    guard let fn = userExec else { return js_regexp_exec(ctx: ctx, this: this, argv: [input]) }
    let r = ctx.callFunction(fn, thisVal: this, args: [input])
    if r.isException || r.isNull || r.isObject { return r }
    r.freeValue()
    return ctx.throwTypeError("exec result must be an object or null")
}

// MARK: - RegExp.prototype.test

/// `RegExp.prototype.test(string)` -- shorthand for `exec !== null`.
///
/// Mirrors QuickJS `js_regexp_test`.
nonisolated func js_regexp_test(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    let userExec = js_regexp_userExecFunction(ctx: ctx, this: this)
    if let u = userExec, u.isException { return .exception }
    defer { userExec?.freeValue() }
    let result: JeffJSValue
    if let u = userExec {
        let input = argv.first.map { ctx.toString($0) } ?? ctx.newStringValue("undefined")
        if input.isException { return .exception }
        result = js_regexp_execVia(ctx: ctx, this: this, input: input, userExec: u)
        input.freeValue()
    } else {
        result = js_regexp_exec(ctx: ctx, this: this, argv: argv)
    }
    if result.isException {
        return .exception
    }
    let matched = !result.isNull
    result.freeValue()   // the match array is ours (it leaked on every successful test())
    return JeffJSValue.newBool(matched)
}

// MARK: - RegExp.prototype.toString

/// `RegExp.prototype.toString()` -- returns "/pattern/flags".
///
/// Mirrors QuickJS `js_regexp_toString`.
nonisolated func js_regexp_toString(
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
            // Owned value (freed below with the slow path's reads).
            sourceVal = JeffJSValue.borrowedString(pattern).dupValue()
        } else {
            sourceVal = JeffJSValue.makeString(JeffJSString(swiftString: "(?:)"))
        }

        let flagBits = js_regexp_getFlags(obj)
        let flagStr = js_regexp_buildFlagsString(flagBits)
        flagsVal = JeffJSValue.makeString(flagStr)
    } else {
        // Slow path: read "source" and "flags" properties.
        sourceVal = obj.getOwnPropertyValue(atom: JeffJSAtomID.JS_ATOM_source.rawValue).dupValue()
        flagsVal = obj.getOwnPropertyValue(atom: JeffJSAtomID.JS_ATOM_flags.rawValue).dupValue()
    }
    defer { sourceVal.freeValue(); flagsVal.freeValue() }

    // Build "/source/flags".
    let buf = JeffJSStringBuffer()
    buf.putc8(0x2F) // '/'

    if let sourceStr = sourceVal.stringValue {
        // `source` is already EscapeRegExpPattern'd (js_regexp_get_source /
        // js_regexp_escapedSource); a second pass turned /a\/b/ into /a\\/b/.
        // A subclass's own `source` string is used as is (ES §22.2.6.17).
        if obj.classID == JSClassID.JS_CLASS_REGEXP.rawValue {
            let esc = JeffJSValue.makeString(js_regexp_escapedSource(sourceStr))   // owned
            if let e = esc.stringValue { buf.concat(e) }
            esc.freeValue()
        } else {
            buf.concat(sourceStr)
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
nonisolated func js_regexp_compile(
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
        patternStr = js_regexp_getPattern(patternObj).map(js_regexp_sharePattern)
        let bits = js_regexp_getFlags(patternObj)
        flagsStr = js_regexp_buildFlagsString(bits)
    } else {
        if patternArg.isUndefined {
            patternStr = js_regexp_adoptFreshPattern(JeffJSString(swiftString: ""))
        } else if patternArg.isString {
            patternStr = js_regexp_adoptPattern(patternArg)
        } else {
            let sv = ctx.toString(patternArg)
            if sv.isException { return .exception }
            patternStr = js_regexp_adoptPattern(sv)
            sv.freeValue()
        }
        if patternStr == nil {
            patternStr = js_regexp_adoptFreshPattern(JeffJSString(swiftString: ""))
        }
        flagsStr = flagsArg.isUndefined ? nil : flagsArg.stringValue
    }

    let flagBits = js_regexp_parseFlags(flagsStr)
    if flagBits < 0 {
        js_regexp_releasePattern(patternStr)
        return ctx.throwTypeError("RegExp.compile: invalid flags")
    }

    let compiled = js_regexp_compile(ctx: ctx, pattern: patternStr, flags: flagBits)
    if compiled == nil {
        js_regexp_releasePattern(patternStr)
        return .exception
    }

    // The old pattern's count goes with the old payload.
    let oldPattern = js_regexp_getPattern(obj)
    obj.payload = JeffJSObjectPayload.regexp(pattern: patternStr, bytecode: compiled)
    js_regexp_releasePattern(oldPattern)
    if !js_regexp_setLastIndex(ctx, obj, value: 0) { return .exception }

    return this.dupValue()
}

// MARK: - Flag getters

/// Generic flag getter.  `magic` encodes which flag bit to test.
///
/// Mirrors QuickJS `js_regexp_get_flag` with magic parameter.
nonisolated func js_regexp_get_flag(
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
nonisolated func js_regexp_get_global(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
    return js_regexp_get_flag(ctx: ctx, this: this, magic: LRE_FLAG_GLOBAL)
}

/// `get RegExp.prototype.ignoreCase`
nonisolated func js_regexp_get_ignoreCase(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
    return js_regexp_get_flag(ctx: ctx, this: this, magic: LRE_FLAG_IGNORECASE)
}

/// `get RegExp.prototype.multiline`
nonisolated func js_regexp_get_multiline(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
    return js_regexp_get_flag(ctx: ctx, this: this, magic: LRE_FLAG_MULTILINE)
}

/// `get RegExp.prototype.dotAll`
nonisolated func js_regexp_get_dotAll(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
    return js_regexp_get_flag(ctx: ctx, this: this, magic: LRE_FLAG_DOTALL)
}

/// `get RegExp.prototype.unicode`
nonisolated func js_regexp_get_unicode(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
    return js_regexp_get_flag(ctx: ctx, this: this, magic: LRE_FLAG_UNICODE)
}

/// `get RegExp.prototype.unicodeSets`
nonisolated func js_regexp_get_unicodeSets(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
    return js_regexp_get_flag(ctx: ctx, this: this, magic: LRE_FLAG_UNICODE_SETS)
}

/// `get RegExp.prototype.sticky`
nonisolated func js_regexp_get_sticky(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
    return js_regexp_get_flag(ctx: ctx, this: this, magic: LRE_FLAG_STICKY)
}

/// `get RegExp.prototype.hasIndices`
nonisolated func js_regexp_get_hasIndices(ctx: JeffJSContext, this: JeffJSValue) -> JeffJSValue {
    return js_regexp_get_flag(ctx: ctx, this: this, magic: LRE_FLAG_INDICES)
}

/// `get RegExp.prototype.source`
///
/// Returns the pattern with appropriate escaping.
/// Mirrors QuickJS `js_regexp_get_source`.
nonisolated func js_regexp_get_source(
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
        return JeffJSValue.makeString(js_regexp_escapedSource(pattern))
    }
    return JeffJSValue.makeString(JeffJSString(swiftString: "(?:)"))
}

/// EscapeRegExpPattern (ES §22.2.6.13.1) as JavaScriptCore writes it: "(?:)"
/// for an empty pattern, a "/" that is neither escaped nor inside a class
/// becomes "\/", and line terminators become "\n", "\r", "\u2028",
/// "\u2029" — so `new RegExp("a/b").source` is "a\/b" and `/a\/b/.source`
/// stays "a\/b" (it was "a/b", and toString escaped the escape: "/a\\/b/").
nonisolated func js_regexp_escapedSource(_ pattern: JeffJSString) -> JeffJSString {
    if pattern.len == 0 { return JeffJSString(swiftString: "(?:)") }
    var out: [UInt16] = []
    out.reserveCapacity(pattern.len + 4)
    var inClass = false
    var escaped = false
    var changed = false
    for i in 0 ..< pattern.len {
        let ch = UInt16(truncatingIfNeeded: jeffJS_getString(str: pattern, at: i))
        switch ch {
        case 0x0A, 0x0D, 0x2028, 0x2029:
            if !escaped { out.append(0x5C) }
            switch ch {
            case 0x0A: out.append(0x6E)                              // n
            case 0x0D: out.append(0x72)                              // r
            case 0x2028: out.append(contentsOf: Array("u2028".utf16))
            default: out.append(contentsOf: Array("u2029".utf16))
            }
            changed = true
            escaped = false
            continue
        case 0x2F where !escaped && !inClass:
            out.append(0x5C); out.append(0x2F)
            changed = true
            continue
        default:
            break
        }
        out.append(ch)
        if escaped { escaped = false; continue }
        if ch == 0x5C { escaped = true }
        else if ch == 0x5B { inClass = true }
        else if ch == 0x5D { inClass = false }
    }
    if !changed { return pattern.retain() }
    return JeffJSString(swiftString: String(decoding: out, as: UTF16.self))
}

/// `get RegExp.prototype.flags`
///
/// Returns a string containing the flag characters in canonical order.
/// Mirrors QuickJS `js_regexp_get_flags`.
nonisolated func js_regexp_get_flags(
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
nonisolated func js_regexp_Symbol_match(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    guard let obj = this.toObject() else {
        return ctx.throwTypeError("[Symbol.match] called on non-object")
    }

    let inputVal = argv.count >= 1 ? argv[0] : JeffJSValue.undefined
    guard let input = js_regexp_coerceInput(ctx: ctx, val: inputVal) else {
        return .exception
    }
    defer { input.value.freeValue() }
    let inputStr = input.str

    let flags = js_regexp_getFlags(obj)
    let isGlobal = (flags & LRE_FLAG_GLOBAL) != 0
    let userExec = js_regexp_userExecFunction(ctx: ctx, this: this)
    if let u = userExec, u.isException { return .exception }
    defer { userExec?.freeValue() }

    if !isGlobal {
        // Non-global: single RegExpExec.
        return js_regexp_execVia(ctx: ctx, this: this, input: input.value, userExec: userExec)
    }

    // Fast path: for standard RegExp with /g flag, bypass the full exec()
    // machinery and use the optimized global match loop that creates ONE
    // REVirtualMachine and reuses it for all matches. This avoids per-match:
    // - bytecode extraction/allocation
    // - input string -> [UInt32] conversion
    // - REVirtualMachine instantiation
    // - full JS result object creation (index, input, groups properties)
    if userExec == nil, js_isStandardRegexp(obj) {
        let fastResult = js_regexp_globalMatchFast(ctx: ctx, obj: obj, inputStr: inputStr, flags: flags)
        if !fastResult.isException {
            return fastResult
        }
        // Fall through to slow path if fast path fails (e.g. bytecode extraction issue).
    }

    // Slow path: standard spec-compliant global match loop (used when exec is
    // overridden, or as fallback).
    let isUnicode = (flags & LRE_FLAG_UNICODE) != 0 || (flags & LRE_FLAG_UNICODE_SETS) != 0

    if !js_regexp_setLastIndex(ctx, obj, value: 0) { return .exception }

    var matches: [JeffJSValue] = []
    var safetyLimit = 1_000_000  // prevent infinite loop on pathological patterns

    while safetyLimit > 0 {
        safetyLimit -= 1
        // exec borrows its argument; the match array is ours.
        let result = js_regexp_execVia(ctx: ctx, this: this, input: input.value, userExec: userExec)
        if result.isException {
            for m in matches { m.freeValue() }
            return .exception
        }
        if result.isNull {
            break
        }
        defer { result.freeValue() }

        // Extract match[0].
        if let resObj = result.toObject() {
            let matchStr = resObj.getArrayElement(0)
            matches.append(matchStr.dupValue())

            // If match[0] is empty string, advance lastIndex to avoid infinite loop.
            if let ms = matchStr.stringValue, ms.len == 0 {
                guard let li = js_regexp_getLastIndex(ctx, obj),
                      js_regexp_setLastIndex(ctx, obj, value: js_regexp_advanceIndex(inputStr, index: li, unicode: isUnicode)) else {
                    for m in matches { m.freeValue() }
                    return .exception
                }
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
nonisolated private func js_regexp_globalMatchFast(
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
    // UTF-16 code units in both modes (see js_regexp_execInternal): the match
    // ranges index the JS string, and the substrings below are rebuilt from
    // these units — decoded code points truncated astral characters to their
    // low surrogate.
    let inputCodeUnits = ctx.rt.regexCaches.codeUnits(of: inputStr)

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
    if !js_regexp_setLastIndex(ctx, obj, value: 0) { return .exception }

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
nonisolated func js_regexp_Symbol_matchAll(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    guard let obj = this.toObject() else {
        return ctx.throwTypeError("[Symbol.matchAll] called on non-object")
    }

    let inputVal = argv.count >= 1 ? argv[0] : JeffJSValue.undefined
    guard let input = js_regexp_coerceInput(ctx: ctx, val: inputVal) else {
        return .exception
    }
    defer { input.value.freeValue() }
    let inputStr = input.str

    // Create a copy of the regexp (to preserve the original's lastIndex).
    let flags = js_regexp_getFlags(obj)
    let isGlobal = (flags & LRE_FLAG_GLOBAL) != 0
    let isUnicode = (flags & LRE_FLAG_UNICODE) != 0 || (flags & LRE_FLAG_UNICODE_SETS) != 0

    // Ensure the flags string includes 'g' (matchAll always uses global).
    var copyFlags = flags | LRE_FLAG_GLOBAL

    // The original's lastIndex, for the copy.
    guard let origLastIndex = js_regexp_getLastIndex(ctx, obj) else { return .exception }

    let regexpCopy = jeffJS_createObject(ctx: ctx, proto: nil,
                                          classID: UInt16(JSClassID.JS_CLASS_REGEXP.rawValue))
    regexpCopy.payload = .regexp(
        pattern: js_regexp_getPattern(obj).map(js_regexp_sharePattern),
        bytecode: js_regexp_getBytecode(obj)?.retain()
    )

    // Set lastIndex from the original.
    jeffJS_appendOwnProperty(ctx, regexpCopy,
                             atom: JeffJSAtomID.JS_ATOM_lastIndex.rawValue,
                             flags: [.writable],
                             value: origLastIndex >= 0 && origLastIndex <= Int(Int32.max)
                                ? JeffJSValue.newInt32(Int32(origLastIndex))
                                : JeffJSValue.newFloat64(Double(max(origLastIndex, 0))))

    // Create the iterator object.
    let iterData = JSRegExpStringIteratorData(
        iteratingRegExp: regexpCopy,
        iteratedString: inputStr,
        iteratedValue: input.value.dupValue(),
        isGlobal: isGlobal,
        isUnicode: isUnicode,
        done: false
    )

    // %RegExpStringIteratorPrototype% carries next() and [Symbol.iterator];
    // this object used to be created with a nil prototype, so the result of
    // `"aa".matchAll(/a/g)` was not iterable at all.
    let iterProtoVal = ctx.regexpStringIteratorProto()
    let iterObj = jeffJS_createObject(ctx: ctx, proto: iterProtoVal.toObject(),
                                       classID: UInt16(JeffJSClassID.stringIterator.rawValue))
    // No per-object dup: the iterator prototype's root shape owns its count.
    iterObj.payload = .opaque(iterData)

    return JeffJSValue.makeObject(iterObj)
}

/// `RegExp.prototype[@@replace](string, replaceValue)`
///
/// Mirrors QuickJS `js_regexp_Symbol_replace`.
///
/// If replaceValue is a function, it is called for each match.
/// If replaceValue is a string, it is interpolated with $-substitutions.
nonisolated func js_regexp_Symbol_replace(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    guard let obj = this.toObject() else {
        return ctx.throwTypeError("[Symbol.replace] called on non-object")
    }

    let inputVal = argv.count >= 1 ? argv[0] : JeffJSValue.undefined
    let replaceVal = argv.count >= 2 ? argv[1] : JeffJSValue.undefined

    guard let input = js_regexp_coerceInput(ctx: ctx, val: inputVal) else {
        return .exception
    }
    defer { input.value.freeValue() }
    let inputStr = input.str

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
        if !js_regexp_setLastIndex(ctx, obj, value: 0) { return .exception }
    }
    let userExec = js_regexp_userExecFunction(ctx: ctx, this: this)
    if let u = userExec, u.isException { return .exception }
    defer { userExec?.freeValue() }

    let buf = JeffJSStringBuffer()
    var lastMatchEnd = 0

    // Execute the regex repeatedly (once for non-global, loop for global).
    var loopCount = 0
    let maxLoops = isGlobal ? inputStr.len + 1 : 1

    while loopCount < maxLoops {
        loopCount += 1

        // exec borrows its argument; the match array is ours (it leaked once
        // per match: every regex String.prototype.replace grew the heap).
        let result = js_regexp_execVia(ctx: ctx, this: this, input: input.value, userExec: userExec)
        if result.isException {
            buf.free()
            return .exception
        }
        if result.isNull {
            break
        }
        defer { result.freeValue() }

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
            // `ms` is result[0], a flat string exec created (it carries its own
            // retain), so a dup is the owned reference; `makeString(ms.retain())`
            // added a second Swift retain that nothing released.
            if let ms = matchedStr {
                callArgs.append(JeffJSValue.borrowedString(ms).dupValue())
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
            // Full input string: the subject value, a counted reference.
            callArgs.append(input.value.dupValue())
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
            // `$<name>` needs the match's `groups` object.
            let groupsAtom = ctx.rt.findAtom("groups")
            let namedGroups = resObj.getOwnPropertyValue(atom: groupsAtom)
            ctx.rt.freeAtom(groupsAtom)
            let sub = js_getSubstitution(
                ctx: ctx,
                matched: matchedStr,
                input: inputStr,
                matchStart: matchStart,
                captures: resObj,
                namedGroups: namedGroups,
                replacement: rs
            )
            buf.concat(sub)
        }

        lastMatchEnd = matchStart + matchLen

        // For global, check if match was empty to avoid infinite loop.
        if isGlobal && matchLen == 0 {
            guard let li = js_regexp_getLastIndex(ctx, obj),
                  js_regexp_setLastIndex(ctx, obj, value: js_regexp_advanceIndex(inputStr, index: li, unicode: isUnicode)) else {
                return .exception
            }
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
nonisolated func js_regexp_Symbol_search(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    guard let obj = this.toObject() else {
        return ctx.throwTypeError("[Symbol.search] called on non-object")
    }

    let userExec = js_regexp_userExecFunction(ctx: ctx, this: this)
    if let u = userExec, u.isException { return .exception }
    defer { userExec?.freeValue() }

    // Save lastIndex; set it to 0 only when it is not 0 already (ES §22.2.6.12
    // steps 4-5: a frozen regexp whose lastIndex is 0 can still be searched).
    guard let savedLastIndex = js_regexp_getLastIndex(ctx, obj) else { return .exception }
    if savedLastIndex != 0, !js_regexp_setLastIndex(ctx, obj, value: 0) { return .exception }

    let result: JeffJSValue
    if let u = userExec {
        let input = argv.first.map { ctx.toString($0) } ?? ctx.newStringValue("undefined")
        result = input.isException ? .exception : js_regexp_execVia(ctx: ctx, this: this, input: input, userExec: u)
        input.freeValue()
    } else {
        result = js_regexp_exec(ctx: ctx, this: this, argv: argv)
    }

    if result.isException {
        return .exception
    }

    // Restore lastIndex (steps 7-8: only when it changed).
    guard let nowLastIndex = js_regexp_getLastIndex(ctx, obj) else {
        result.freeValue()
        return .exception
    }
    if nowLastIndex != savedLastIndex, !js_regexp_setLastIndex(ctx, obj, value: savedLastIndex) {
        result.freeValue()
        return .exception
    }
    if result.isNull {
        return JeffJSValue.newInt32(-1)
    }

    guard let resObj = result.toObject() else {
        result.freeValue()
        return JeffJSValue.newInt32(-1)
    }

    let indexVal = resObj.getOwnPropertyValue(atom: JeffJSAtomID.JS_ATOM_index.rawValue).dupValue()
    result.freeValue()   // the match array is ours
    return indexVal
}

/// `RegExp.prototype[@@split](string, limit)`
///
/// Mirrors QuickJS `js_regexp_Symbol_split`.
nonisolated func js_regexp_Symbol_split(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    guard let obj = this.toObject() else {
        return ctx.throwTypeError("[Symbol.split] called on non-object")
    }

    let inputVal = argv.count >= 1 ? argv[0] : JeffJSValue.undefined
    let limitVal = argv.count >= 2 ? argv[1] : JeffJSValue.undefined

    guard let input = js_regexp_coerceInput(ctx: ctx, val: inputVal) else {
        return .exception
    }
    defer { input.value.freeValue() }
    let inputStr = input.str

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

    // Not a plain RegExp (another class, a page `exec`, or a constructor /
    // @@species that is not %RegExp%): the spec's splitter loop through
    // RegExpExec (core-js probes exactly this and otherwise replaces
    // String.prototype.split with a JS wrapper).
    do {
        var generic = obj.classID != JSClassID.JS_CLASS_REGEXP.rawValue
        if !generic {
            let u = js_regexp_userExecFunction(ctx: ctx, this: this)
            if let u = u { u.freeValue(); if u.isException { return .exception } ; generic = true }
        }
        if !generic {
            let c = ctx.getProperty(obj: this, atom: JeffJSAtomID.JS_ATOM_constructor.rawValue)
            if c.isException { return .exception }
            generic = !(c.isUndefined || c.bits == ctx.regexpCtor.bits)
            c.freeValue()
        }
        if generic {
            return js_regexp_split_generic(ctx: ctx, rx: this, input: input.value, inputStr: inputStr, limit: limit)
        }
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

    // ES §22.2.6.14 step 16: an empty subject is answered by one probe, not by
    // the loop — `"".split(/(?:)/)` is `[]` and `"".split(/a/)` is `[""]`.
    if inputStr.len == 0 {
        let probe = js_regexp_execInternal(ctx: ctx, obj: obj, inputStr: inputStr,
                                           startIndex: 0, flags: flags,
                                           captureCount: captureCount)
        let arrVal = ctx.newArray()
        if probe == nil || probe!.isEmpty, limit > 0 {
            _ = ctx.setPropertyStr(obj: arrVal, name: "0", value: input.value.dupValue())
            _ = ctx.setPropertyStr(obj: arrVal, name: "length", value: .newInt32(1))
        }
        return arrVal
    }

    // `q < size`, not `q <= size` (step 19). At `q == size` the forced-sticky
    // probe finds the empty match every `*`-quantified pattern has there, and
    // because that match's end differs from `p` it emitted one extra segment
    // and then an empty tail: `"a,b,,c".split(/,*/)` came back as
    // ["a","b","c",""].
    while q < inputStr.len {
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

/// RegExp.prototype[@@split] steps 4-25 (ES §22.2.6.14) for a receiver that is
/// not a plain RegExp: SpeciesConstructor, `flags` read through Get, a sticky
/// splitter built with Construct, and RegExpExec at each position.
nonisolated private func js_regexp_split_generic(ctx: JeffJSContext, rx: JeffJSValue, input: JeffJSValue,
                                     inputStr: JeffJSString, limit: UInt32) -> JeffJSValue {
    // C = SpeciesConstructor(rx, %RegExp%)
    var ctor = ctx.regexpCtor.dupValue()
    let c = ctx.getProperty(obj: rx, atom: JeffJSAtomID.JS_ATOM_constructor.rawValue)
    if c.isException { ctor.freeValue(); return .exception }
    if !c.isUndefined {
        guard c.isObject else { c.freeValue(); ctor.freeValue(); return ctx.throwTypeError("object.constructor is not an object") }
        let sp = ctx.getProperty(obj: c, atom: JeffJSAtomID.JS_ATOM_Symbol_species.rawValue)
        c.freeValue()
        if sp.isException { ctor.freeValue(); return .exception }
        if !(sp.isUndefined || sp.isNull) {
            guard ctx.isConstructor(sp) else { sp.freeValue(); ctor.freeValue(); return ctx.throwTypeError("object.constructor[Symbol.species] is not a constructor") }
            ctor.freeValue(); ctor = sp
        }
    }
    defer { ctor.freeValue() }
    let flagsVal = ctx.getProperty(obj: rx, atom: JeffJSAtomID.JS_ATOM_flags.rawValue)
    if flagsVal.isException { return .exception }
    let flagsStrVal = ctx.toString(flagsVal)
    flagsVal.freeValue()
    if flagsStrVal.isException { return .exception }
    let flags = flagsStrVal.stringValue?.toSwiftString() ?? ""
    flagsStrVal.freeValue()
    let unicodeMatching = flags.contains("u") || flags.contains("v")
    let newFlags = ctx.newStringValue(flags.contains("y") ? flags : flags + "y")
    let splitter = ctx.callConstructor(ctor, args: [rx, newFlags])
    newFlags.freeValue()
    if splitter.isException { return .exception }
    defer { splitter.freeValue() }

    var results: [JeffJSValue] = []
    func finish() -> JeffJSValue {
        let arrVal = ctx.newArray()
        if let arr = arrVal.toObject() {
            arr.payload = .array(size: UInt32(results.count), values: results, count: UInt32(results.count))
            arr.fastArray = true
        }
        _ = ctx.setPropertyStr(obj: arrVal, name: "length", value: .newInt32(Int32(results.count)))
        return arrVal
    }
    func fail() -> JeffJSValue { for r in results { r.freeValue() }; return .exception }
    if limit == 0 { return finish() }
    let userExec = js_regexp_userExecFunction(ctx: ctx, this: splitter)
    if let u = userExec, u.isException { return .exception }
    defer { userExec?.freeValue() }
    let size = inputStr.len
    if size == 0 {
        let z = js_regexp_execVia(ctx: ctx, this: splitter, input: input, userExec: userExec)
        if z.isException { return .exception }
        let matched = !z.isNull
        z.freeValue()
        if !matched { results.append(input.dupValue()) }
        return finish()
    }
    let lastIndexAtom = JeffJSAtomID.JS_ATOM_lastIndex.rawValue
    var p = 0, q = 0
    while q < size {
        if ctx.setProperty(obj: splitter, atom: lastIndexAtom, value: .newInt32(Int32(q))) < 0 { return fail() }
        let z = js_regexp_execVia(ctx: ctx, this: splitter, input: input, userExec: userExec)
        if z.isException { return fail() }
        if z.isNull { q = js_regexp_advanceIndex(inputStr, index: q, unicode: unicodeMatching); continue }
        let liVal = ctx.getProperty(obj: splitter, atom: lastIndexAtom)
        if liVal.isException { z.freeValue(); return fail() }
        let e = Int(min(max(ctx.toLength(liVal), 0), Int64(size)))
        liVal.freeValue()
        if e == p { z.freeValue(); q = js_regexp_advanceIndex(inputStr, index: q, unicode: unicodeMatching); continue }
        if let sub = jeffJS_subString(str: inputStr, start: p, end: q) { results.append(JeffJSValue.makeString(sub)) }
        if UInt32(results.count) >= limit { z.freeValue(); return finish() }
        p = e
        let lenVal = ctx.getProperty(obj: z, atom: JeffJSAtomID.JS_ATOM_length.rawValue)
        if lenVal.isException { z.freeValue(); return fail() }
        let nCaps = max(Int(ctx.toLength(lenVal)) - 1, 0)
        lenVal.freeValue()
        if nCaps > 0 {
            for i in 1 ... nCaps {
                let cap = ctx.getPropertyUint32(obj: z, index: UInt32(i))
                if cap.isException { z.freeValue(); return fail() }
                results.append(cap)
                if UInt32(results.count) >= limit { z.freeValue(); return finish() }
            }
        }
        z.freeValue()
        q = p
    }
    if let tail = jeffJS_subString(str: inputStr, start: p, end: size) { results.append(JeffJSValue.makeString(tail)) }
    return finish()
}

/// `get RegExp[@@species]` -- returns the constructor.
nonisolated func js_regexp_get_species(
    ctx: JeffJSContext,
    this: JeffJSValue
) -> JeffJSValue {
    return this.dupValue()
}

// MARK: - RegExp String Iterator (JS_CLASS_REGEXP_STRING_ITERATOR)

/// Internal state for the RegExp String Iterator.
///
/// Mirrors QuickJS `JSRegExpStringIteratorData`.
nonisolated final class JSRegExpStringIteratorData {
    var iteratingRegExp: JeffJSObject
    /// Flat view of `iteratedValue` (kept alive by it).
    var iteratedString: JeffJSString
    /// The subject string, owned (see js_regexp_coerceInput).
    let iteratedValue: JeffJSValue
    var isGlobal: Bool
    var isUnicode: Bool
    var done: Bool

    init(iteratingRegExp: JeffJSObject,
         iteratedString: JeffJSString,
         iteratedValue: JeffJSValue,
         isGlobal: Bool,
         isUnicode: Bool,
         done: Bool) {
        self.iteratingRegExp = iteratingRegExp
        self.iteratedString = iteratedString
        self.iteratedValue = iteratedValue
        self.isGlobal = isGlobal
        self.isUnicode = isUnicode
        self.done = done
    }

    /// The copy of the regexp (created with a count of 1) and the retained
    /// string die with the iterator; they leaked once per matchAll().
    deinit {
        if JeffJSGCObjectHeader.activeRuntime != nil {
            // The copy was never handed out as a value (jeffJS_createObject takes no
            // Swift retain): this `makeObject` takes the one its free gives back.
            JeffJSValue.makeObject(iteratingRegExp).freeValue()
            iteratedValue.freeValue()
        }
    }
}

/// `%RegExpStringIteratorPrototype%.next()`
///
/// Mirrors QuickJS `js_regexp_string_iterator_next`.
nonisolated func js_regexp_string_iterator_next(
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

    let regexpThisVal = JeffJSValue.borrowedObject(data.iteratingRegExp)
    // exec borrows its argument; js_createIteratorResult dups the match array,
    // so ours is released on the way out.
    let result = js_regexp_exec(
        ctx: ctx,
        this: regexpThisVal,
        argv: [data.iteratedValue]
    )
    defer { result.freeValue() }

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
            guard let li = js_regexp_getLastIndex(ctx, data.iteratingRegExp),
                  js_regexp_setLastIndex(ctx, data.iteratingRegExp,
                                         value: js_regexp_advanceIndex(data.iteratedString, index: li, unicode: data.isUnicode)) else {
                return .exception
            }
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
nonisolated func js_isStandardRegexp(_ obj: JeffJSObject) -> Bool {
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
nonisolated private func js_regexp_compile(
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

/// Whether slot 0 of a RegExp is its own `lastIndex` data property (every RegExp
/// instance gets it first, non-configurable, so it stays there), and writable.
@inline(__always)
nonisolated private func js_regexp_lastIndexSlot(_ obj: JeffJSObject, writable: Bool) -> Bool {
    guard obj.propValues.count > 0, let sh = obj.shape, !sh.prop.isEmpty,
          sh.prop[0].atom == JeffJSAtomID.JS_ATOM_lastIndex.rawValue,
          !sh.prop[0].flags.isGetSet, obj.extra(at: 0) == nil else { return false }
    return !writable || sh.prop[0].flags.contains(.writable)
}

/// `ToLength(? Get(R, "lastIndex"))` (ES §22.2.7.2 RegExpBuiltinExec step 2). nil when
/// reading or converting it threw (a `valueOf` on an object `lastIndex`).
///
/// The fast path reads slot 0 (QuickJS keeps lastIndex as the first property); a value
/// that is not a number goes through ToNumber — `re.lastIndex = "1"` was read as 0.
nonisolated private func js_regexp_getLastIndex(_ ctx: JeffJSContext, _ obj: JeffJSObject) -> Int? {
    if js_regexp_lastIndexSlot(obj, writable: false) {
        let v = obj.propValues[0]
        // `Int(d)` trapped on `re.lastIndex = Infinity` / 1e20.
        if v.isInt { return max(0, Int(v.toInt32())) }
        if v.isFloat64 { return max(0, jeffJS_intArg(v.toFloat64())) }
    }
    let v = ctx.getProperty(obj: .borrowedObject(obj), atom: JeffJSAtomID.JS_ATOM_lastIndex.rawValue)
    if v.isException { return nil }
    let (d, ok) = JeffJSTypeConvert.toNumber(ctx: ctx, val: v)
    v.freeValue()
    if !ok { return nil }
    return max(0, jeffJS_intArg(d))
}

/// `? Set(R, "lastIndex", value, true)`. false with a TypeError pending when the
/// property is read-only (`Object.freeze(/a/g).exec("a")`).
///
/// The fast path writes slot 0 like any own data-property write: the replaced value
/// is released. It used to store over slot 0 without releasing it (a string or object
/// a page had assigned to `lastIndex` leaked on the next global/sticky exec), without
/// checking that the property was writable, and appended a slot with no shape entry
/// when the object had none.
@discardableResult
nonisolated private func js_regexp_setLastIndex(_ ctx: JeffJSContext, _ obj: JeffJSObject, value: Int) -> Bool {
    // `Int32(value)` trapped past 2^31 (a lastIndex advanced from 2^53).
    let v = value >= Int(Int32.min) && value <= Int(Int32.max)
        ? JeffJSValue.newInt32(Int32(value)) : JeffJSValue.newFloat64(Double(value))
    if js_regexp_lastIndexSlot(obj, writable: true) {
        let old = obj.propValues[0]
        obj.propValues[0] = v
        old.freeValue()
        return true
    }
    return ctx.setProperty(obj: .borrowedObject(obj), atom: JeffJSAtomID.JS_ATOM_lastIndex.rawValue, value: v) >= 0
}

/// Advance a string index by one code point, handling surrogate pairs
/// when the `unicode` flag is set.
///
/// Mirrors QuickJS `js_regexp_advance_string_index`.
nonisolated private func js_regexp_advanceIndex(
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

/// ToString(input) for the RegExp builtins, held as ONE owned reference for
/// the whole call (mirrors QuickJS `str = JS_ToString(ctx, argv[0])` ...
/// `JS_FreeValue(ctx, str)`). `value` is the caller's to release (a `defer`
/// right after the call); `str` is its flat view, valid while `value` is.
///
/// Ownership rule for the subject string: every value these builtins hand
/// out that *is* the subject — a match array's `input`, the one-element
/// result of splitting an empty string, the replacer callback's `string`
/// argument, the iterator's subject — is `value.dupValue()`, a counted
/// reference of its own. The subject used to be a bare borrowed
/// `JeffJSString` (the argument's own string, a rope's flattened cache, or an
/// unowned coerced copy) that each site wrapped differently: `"".split(/\s+/)`
/// wrapped it with `makeString` and no count, so the array freed the
/// caller's string (google.com's `a.trim().split(ZOa)` freed the shared ""
/// literal and a later array recycle crashed on it), and the
/// `makeString(s.retain())` wraps took an ARC retain that nothing released.
/// Internal exec calls pass `value` (never a borrowed flat string, which has
/// no JS owner of its own once its rope is gone).
nonisolated private func js_regexp_coerceInput(
    ctx: JeffJSContext,
    val: JeffJSValue
) -> (value: JeffJSValue, str: JeffJSString)? {
    let v = val.isString ? val.dupValue() : ctx.toString(val)
    if v.isException { return nil }
    guard let s = v.stringValue else {
        v.freeValue()
        _ = ctx.throwTypeError("cannot convert to string")
        return nil
    }
    return (v, s)
}

/// Capture group result from the regex engine.
nonisolated struct JSRegExpCapture {
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
/// `JEFFJS_REGEX_WATCH=1` (diagnostic, see `js_regexp_execInternal`).
nonisolated(unsafe) let jeffJSRegexWatch = ProcessInfo.processInfo.environment["JEFFJS_REGEX_WATCH"] == "1"

nonisolated func jeffJSRegexWatchReport(_ ctx: JeffJSContext, _ obj: JeffJSObject, flags: Int, inputLength: Int, tried: Int, ms: Double, done: Bool, input: [UInt32] = []) {
    var source = "?"
    if case .regexp(let pattern, _) = obj.payload, let p = pattern { source = p.toSwiftString() }
    if source.count > 300 { source = String(source.prefix(300)) + "…" }
    let line = "[jeffjs:regex] \(done ? "slow" : "still running") /\(source)/ flags=\(flags) input=\(inputLength) "
        + "starts=\(tried) \(String(format: "%.0f", ms)) ms\n"
        + "[jeffjs:regex]   input: " + String(String.UnicodeScalarView(input.prefix(240).compactMap { Unicode.Scalar($0) })).replacingOccurrences(of: "\n", with: "\\n") + "\n"
        + "[jeffjs:regex]   at " + ctx.formatStackTrace(errorName: "", message: "", frames: ctx.captureStackFrames(maxDepth: 8))
            .split(separator: "\n").map { String($0.prefix(160)) }.joined(separator: " <- ") + "\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    print(line, terminator: "")
}

nonisolated private func js_regexp_execInternal(
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
        bytecode = buf.count == bc.len ? buf : Array(buf.prefix(bc.len))   // no per-exec copy
    } else {
        return nil  // bytecode must be str8
    }

    guard bytecode.count >= 5 else { return nil }  // need at least the header

    // 2. Convert the input JeffJSString to [UInt32] code units.
    //    For non-unicode mode we use UTF-16 code units (matching JS semantics).
    // Input as UInt32 code units, converted once per string and cached on it:
    // split/replace/global match run one exec per match (or per position),
    // and re-encoding the whole input each time made them quadratic.
    // Always UTF-16 code units, in unicode mode too: capture offsets are
    // indices into the JS string, and the caller slices the original
    // JeffJSString with them. Feeding the VM decoded code points made
    // `"a\u{1F600}b".match(/./gu)` report three matches whose middle one
    // sliced the wrong half of the surrogate pair ("" instead of the emoji).
    // The VM decodes surrogate pairs itself when the `u`/`v` flag is set
    // (REVirtualMachine.getCharUnicodeFast), so `/./u` still consumes a whole
    // astral character — it just advances `pos` by two units.
    let inputCodeUnits = ctx.rt.regexCaches.codeUnits(of: inputStr)

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
    // One VM for every start position tried by this exec (each attempt
    // used to allocate its own backtrack stack).
    let vm = REVirtualMachine(bytecode: bytecode, input: inputCodeUnits,
                              startPos: startIndex, flags: regexpFlags)
    var pos = startIndex
    // `JEFFJS_REGEX_WATCH=1`: name every exec that takes > 250 ms (pattern,
    // flags, input length, start positions tried) — a page stalled in regex
    // backtracking shows only REVirtualMachine frames in a sample.
    let watchStart = jeffJSRegexWatch ? CFAbsoluteTimeGetCurrent() : 0
    var watchReported = false
    defer {
        if jeffJSRegexWatch {
            let ms = (CFAbsoluteTimeGetCurrent() - watchStart) * 1000
            if ms > 250 { jeffJSRegexWatchReport(ctx, obj, flags: flags, inputLength: inputCodeUnits.count,
                                                 tried: pos - startIndex + 1, ms: ms, done: true, input: inputCodeUnits) }
        }
    }
    while pos <= inputCodeUnits.count {
        vm.reset(startPos: pos)
        if jeffJSRegexWatch, !watchReported, (pos - startIndex) & 1023 == 0,
           CFAbsoluteTimeGetCurrent() - watchStart > 2 {
            watchReported = true
            jeffJSRegexWatchReport(ctx, obj, flags: flags, inputLength: inputCodeUnits.count,
                                   tried: pos - startIndex, ms: (CFAbsoluteTimeGetCurrent() - watchStart) * 1000, done: false)
        }
        let result = vm.exec()

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
        // With u / v the next start is the next code point, never the low
        // half of a surrogate pair (/[^\u{10428}]/u must not match "\u{10428}").
        if regexpFlags.isUnicode && pos < inputCodeUnits.count,
           inputCodeUnits[pos] >= 0xDC00 && inputCodeUnits[pos] <= 0xDFFF,
           inputCodeUnits[pos - 1] >= 0xD800 && inputCodeUnits[pos - 1] <= 0xDBFF {
            pos += 1
        }
    }

    return nil
}

/// Build the `indices` array for `exec` result when the `d` flag is set.
///
/// Each element is a 2-element array [start, end] or undefined for
/// unmatched captures.
///
/// Mirrors QuickJS `js_regexp_build_indices`.
nonisolated private func js_regexp_buildIndicesArray(
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
nonisolated private func js_getSubstitution(
    ctx: JeffJSContext,
    matched: JeffJSString?,
    input: JeffJSString,
    matchStart: Int,
    captures: JeffJSObject,
    namedGroups: JeffJSValue,
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

            if j >= replacement.len || namedGroups.isUndefined {
                // No closing '>', or the regexp has no named groups at all:
                // per spec `$<` is then a literal.
                buf.putc8(0x24)
                buf.putc(next)
                i += 2
            } else {
                // $<name> -> the named capture, or "" when it did not
                // participate / does not exist.
                guard let name = jeffJS_subString(str: replacement, start: i + 2, end: j) else {
                    i = j + 1
                    break
                }
                let nameAtom = ctx.rt.findAtom(name.toSwiftString())
                let capture = ctx.getProperty(obj: namedGroups, atom: nameAtom)
                ctx.rt.freeAtom(nameAtom)
                if !capture.isUndefined {
                    let capStr = ctx.toString(capture)
                    if let cs = capStr.stringValue { buf.concat(cs) }
                    capStr.freeValue()
                }
                capture.freeValue()
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
nonisolated private func js_createIteratorResult(
    ctx: JeffJSContext,
    value: JeffJSValue,
    done: Bool
) -> JeffJSValue {
    let obj = jeffJS_createObject(ctx: ctx, proto: nil,
                                   classID: UInt16(JeffJSClassID.object.rawValue))

    // Set `value` property.
    jeffJS_appendOwnProperty(ctx, obj,
                             atom: JeffJSAtomID.JS_ATOM_value.rawValue,
                             flags: [.writable, .enumerable, .configurable],
                             value: value.dupValue())

    // Set `done` property.
    jeffJS_appendOwnProperty(ctx, obj,
                             atom: JeffJSAtomID.JS_ATOM_done.rawValue,
                             flags: [.writable, .enumerable, .configurable],
                             value: JeffJSValue.newBool(done))

    return JeffJSValue.makeObject(obj)
}

// MARK: - Property table definitions

/// Function list for `RegExp.prototype`.
/// Mirrors QuickJS `js_regexp_proto_funcs`.
nonisolated(unsafe) let js_regexp_proto_funcs: [(name: String, func_: JSCFunctionType, length: Int)] = [
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
nonisolated(unsafe) let js_regexp_proto_getters: [(name: String, getter: JSCFunctionType)] = [
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
nonisolated func js_addIntrinsicRegExp(rt: JeffJSRuntime) {
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
nonisolated func js_initRegExp(ctx: JeffJSContext) {
    // The plumbing for JS_NewCFunction2 / JS_SetConstructor /
    // JS_DefinePropertyValueStr does not yet exist in JeffJS, so we
    // record the intent here and the setup will be completed when the
    // context infrastructure is in place.
}


// MARK: - %RegExpStringIteratorPrototype%

nonisolated extension JeffJSContext {
    /// The RegExp String Iterator prototype, created on first use and cached in
    /// `classProto[JS_CLASS_REGEXP_STRING_ITERATOR]`. It inherits
    /// %IteratorPrototype% (for the `map`/`filter`/... helpers) and carries
    /// `next` plus `[Symbol.iterator]`.
    func regexpStringIteratorProto() -> JeffJSValue {
        let idx = Int(JSClassID.JS_CLASS_REGEXP_STRING_ITERATOR.rawValue)
        while classProto.count <= idx { classProto.append(.undefined) }
        if classProto[idx].isObject { return classProto[idx] }

        let proto = iteratorProto.isObject ? newObjectProto(proto: iteratorProto) : newObject()
        let nextFn = newCFunction({ ctx, this, args in
            return js_regexp_string_iterator_next(ctx: ctx, this: this, argv: args)
        }, name: "next", length: 0)
        let nextAtom = rt.findAtom("next")
        // definePropertyValue dups: each value's creation count is released here
        // (the two functions and the tag string outlived every runtime).
        _ = definePropertyValue(obj: proto, atom: nextAtom,
                                value: nextFn,
                                flags: JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE)
        nextFn.freeValue()
        rt.freeAtom(nextAtom)
        let selfIterFn = newCFunction({ _, this, _ in this.dupValue() },
                                      name: "[Symbol.iterator]", length: 0)
        _ = definePropertyValue(obj: proto,
                                atom: JeffJSAtomID.JS_ATOM_Symbol_iterator.rawValue,
                                value: selfIterFn,
                                flags: JS_PROP_CONFIGURABLE | JS_PROP_WRITABLE)
        selfIterFn.freeValue()
        let tag = newStringValue("RegExp String Iterator")
        _ = definePropertyValue(obj: proto,
                                atom: JeffJSAtomID.JS_ATOM_Symbol_toStringTag.rawValue,
                                value: tag, flags: JS_PROP_CONFIGURABLE)
        tag.freeValue()
        classProto[idx] = proto
        return proto
    }
}


// MARK: - Regex input / group-name caches (perf/watch-object-size)

/// What used to be three fields on every JeffJSString (`codeUnits32`,
/// `codePoints32`, `regexpGroupNames`): the UInt32 code units of a regex
/// input — kept for the string's whole life, 4 bytes per character of every
/// string a regex ever ran over — and a compiled pattern's group names.
/// Now a few most-recent entries per runtime (single-threaded, no lock).
/// An entry holds a strong reference to its string, so its identity cannot
/// be reused while it is cached; a `/g` loop, `replace` or a tokenizer
/// re-running over the same input still converts it once.
nonisolated final class JeffJSRegexCaches {
    private var inputs: [(JeffJSString, [UInt32])] = []
    private var names: [(JeffJSString, [String?])] = []
    private static let maxInputs = 2
    private static let maxNames = 8

    @inline(__always)
    func codeUnits(of s: JeffJSString) -> [UInt32] {
        if let e = inputs.first, e.0 === s { return e.1 }
        return codeUnitsSlow(s)
    }

    @inline(never)
    private func codeUnitsSlow(_ s: JeffJSString) -> [UInt32] {
        if let i = inputs.firstIndex(where: { $0.0 === s }) {
            let e = inputs.remove(at: i)
            inputs.insert(e, at: 0)
            return e.1
        }
        var c = [UInt32](); c.reserveCapacity(s.len)
        switch s.storage {
        case .str8(let b): for u in b.prefix(s.len) { c.append(UInt32(u)) }
        case .str16(let b): for u in b.prefix(s.len) { c.append(UInt32(u)) }
        }
        inputs.insert((s, c), at: 0)
        if inputs.count > Self.maxInputs { inputs.removeLast() }
        return c
    }

    func groupNames(of bc: JeffJSString) -> [String?] {
        if let i = names.firstIndex(where: { $0.0 === bc }) {
            if i != 0 { let e = names.remove(at: i); names.insert(e, at: 0) }
            return names[0].1
        }
        let g: [String?]
        if case .str8(let bcBuf) = bc.storage {
            g = lreGetGroupNames(bcBuf.count == bc.len ? bcBuf : Array(bcBuf.prefix(bc.len)))
        } else {
            g = []
        }
        names.insert((bc, g), at: 0)
        if names.count > Self.maxNames { names.removeLast() }
        return g
    }

    func removeAll() { inputs.removeAll(); names.removeAll() }
}
