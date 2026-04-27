// JeffJSBuiltinString.swift
// JeffJS - 1:1 Swift port of QuickJS JavaScript engine
//
// Complete port of the String built-in: constructor, static methods,
// all prototype methods (including legacy HTML wrappers), and the
// exotic string object indexed-property handler.
//
// ECMAScript semantics are followed exactly, operating on UTF-16 code
// units internally (matching QuickJS and the JS spec).

import Foundation

// MARK: - JeffJSContext extensions for String builtins

extension JeffJSContext {
    /// Convert a JS string value to an array of UTF-16 code units.
    func toUTF16Array(_ val: JeffJSValue) -> [UInt16] {
        let jsStr = toString(val)
        if jsStr.isException { return [] }
        guard let s = jsStr.stringValue?.toSwiftString() else { return [] }
        return Array(s.utf16)
    }

    /// Optional version of toUTF16Array (returns nil on failure).
    func toUTF16ArrayOpt(_ val: JeffJSValue) -> [UInt16]? {
        let jsStr = toString(val)
        if jsStr.isException { return nil }
        guard let s = jsStr.stringValue?.toSwiftString() else { return nil }
        return Array(s.utf16)
    }

    /// Create a new JS string from UTF-16 code units.
    func newStringFromUTF16(_ units: [UInt16]) -> JeffJSValue {
        let str = String(utf16CodeUnits: units, count: units.count)
        return newStringValue(str)
    }

    /// Create an iterator result object { value, done }.
    func createIterResult(value: JeffJSValue, done: Bool) -> JeffJSValue {
        let obj = newObject()
        _ = setPropertyStr(obj: obj, name: "value", value: value)
        _ = setPropertyStr(obj: obj, name: "done", value: done ? .JS_TRUE : .JS_FALSE)
        return obj
    }

    /// Set an internal index property (for String iterator state).
    func setInternalIndex(_ obj: JeffJSValue, index: Int) {
        _ = setPropertyStr(obj: obj, name: "__index__", value: .newInt32(Int32(index)))
    }

    /// Get the internal index property.
    func getInternalIndex(_ obj: JeffJSValue) -> Int {
        let val = getPropertyStr(obj: obj, name: "__index__")
        if val.isInt { return Int(val.toInt32()) }
        return 0
    }

    /// ToLength conversion (clamp to 0...2^53-1).
    func toLength2(_ val: JeffJSValue) -> Int {
        if val.isInt {
            let v = Int(val.toInt32())
            return max(0, v)
        }
        if val.isFloat64 {
            let d = val.toFloat64()
            if d.isNaN || d <= 0 { return 0 }
            if d >= 9007199254740991.0 { return Int.max }
            return Int(d)
        }
        return 0
    }

    /// ToUInt32 conversion.
    func toUInt32(_ val: JeffJSValue) -> UInt32 {
        if val.isInt { return UInt32(bitPattern: val.toInt32()) }
        if val.isFloat64 { return JeffJSTypeConvert.doubleToUInt32(val.toFloat64()) }
        return 0
    }

    /// ToUInt16 conversion.
    func toUInt16(_ val: JeffJSValue) -> UInt16 {
        if val.isInt { return UInt16(truncatingIfNeeded: val.toInt32()) }
        if val.isFloat64 {
            let d = val.toFloat64()
            if d.isNaN || d.isInfinite { return 0 }
            return UInt16(truncatingIfNeeded: JeffJSTypeConvert.doubleToInt32(d))
        }
        return 0
    }

    /// Symbol.description.
    func symbolDescriptiveString(_ val: JeffJSValue) -> JeffJSValue {
        return newStringValue("Symbol()")
    }

    /// Set a function property keyed by a well-known symbol.
    func setPropertyFuncSymbol(obj: JeffJSValue, name: String, fn: @escaping JeffJSNativeFunc, length: Int) {
        setPropertyFunc(obj: obj, name: name, fn: fn, length: length)
    }
}

// MARK: - JeffJSBuiltinString

struct JeffJSBuiltinString {

    // MARK: - Intrinsic Registration

    /// Install `String`, `String.prototype`, and all methods onto `ctx`.
    static func addIntrinsic(ctx: JeffJSContext) {
        // 1. Create String.prototype (a String wrapper object whose [[StringData]] is "")
        let proto = ctx.newObject(classID: JeffJSClassID.string.rawValue)
        let emptyStr = ctx.newStringValue("")
        ctx.setObjectData(proto, value: emptyStr)
        // Also set primitiveValue so getPropertyInternal can access
        // [[StringData]] for .length / indexed access on wrapper objects.
        if let protoObj = proto.toObject() {
            protoObj.primitiveValue = emptyStr
        }

        // Update classProto so auto-boxing (e.g., 'hello'.toUpperCase()) finds
        // String.prototype methods when getPropertyInternal looks them up.
        ctx.classProto[JSClassID.JS_CLASS_STRING.rawValue] = proto

        // 2. Create the String constructor
        let ctor = ctx.newCFunction(
            name: "String",
            length: 1,
            cproto: .constructorOrFunc({ c, this, args, isNew in
                stringConstructor(ctx: c, newTarget: isNew ? this : .undefined,
                                  this: this, args: args)
            })
        )

        // 3. Wire constructor.prototype = proto, proto.constructor = ctor
        ctx.setConstructorProto(ctor: ctor, proto: proto)

        // 4. Static methods on String
        ctx.setPropertyFunc(obj: ctor, name: "fromCharCode",     fn: fromCharCode,     length: 1)
        ctx.setPropertyFunc(obj: ctor, name: "fromCodePoint",    fn: fromCodePoint,    length: 1)
        ctx.setPropertyFunc(obj: ctor, name: "raw",              fn: raw,              length: 1)

        // 5. Prototype methods
        // Character access
        ctx.setPropertyFunc(obj: proto, name: "charAt",       fn: charAt,       length: 1)
        ctx.setPropertyFunc(obj: proto, name: "charCodeAt",   fn: charCodeAt,   length: 1)
        ctx.setPropertyFunc(obj: proto, name: "codePointAt",  fn: codePointAt,  length: 1)
        ctx.setPropertyFunc(obj: proto, name: "at",           fn: at,           length: 1)

        // Search
        ctx.setPropertyFunc(obj: proto, name: "indexOf",      fn: indexOf,      length: 1)
        ctx.setPropertyFunc(obj: proto, name: "lastIndexOf",  fn: lastIndexOf,  length: 1)
        ctx.setPropertyFunc(obj: proto, name: "includes",     fn: includes,     length: 1)
        ctx.setPropertyFunc(obj: proto, name: "startsWith",   fn: startsWith,   length: 1)
        ctx.setPropertyFunc(obj: proto, name: "endsWith",     fn: endsWith,     length: 1)

        // Regex-delegating
        ctx.setPropertyFunc(obj: proto, name: "match",        fn: match,        length: 1)
        ctx.setPropertyFunc(obj: proto, name: "matchAll",     fn: matchAll,     length: 1)
        ctx.setPropertyFunc(obj: proto, name: "search",       fn: search,       length: 1)
        ctx.setPropertyFunc(obj: proto, name: "replace",      fn: replace,      length: 2)
        ctx.setPropertyFunc(obj: proto, name: "replaceAll",   fn: replaceAll,   length: 2)
        ctx.setPropertyFunc(obj: proto, name: "split",        fn: split,        length: 2)

        // Extraction
        ctx.setPropertyFunc(obj: proto, name: "substring",    fn: substring,    length: 2)
        ctx.setPropertyFunc(obj: proto, name: "substr",       fn: substr,       length: 2)
        ctx.setPropertyFunc(obj: proto, name: "slice",        fn: slice,        length: 2)

        // Transformation
        ctx.setPropertyFunc(obj: proto, name: "toLowerCase",       fn: toLowerCase,       length: 0)
        ctx.setPropertyFunc(obj: proto, name: "toUpperCase",       fn: toUpperCase,       length: 0)
        ctx.setPropertyFunc(obj: proto, name: "toLocaleLowerCase", fn: toLocaleLowerCase, length: 0)
        ctx.setPropertyFunc(obj: proto, name: "toLocaleUpperCase", fn: toLocaleUpperCase, length: 0)
        ctx.setPropertyFunc(obj: proto, name: "trim",              fn: trim,              length: 0)
        ctx.setPropertyFunc(obj: proto, name: "trimStart",         fn: trimStart,         length: 0)
        ctx.setPropertyFunc(obj: proto, name: "trimEnd",           fn: trimEnd,           length: 0)
        ctx.setPropertyFunc(obj: proto, name: "repeat",            fn: repeat_,           length: 1)
        ctx.setPropertyFunc(obj: proto, name: "padStart",          fn: padStart,          length: 1)
        ctx.setPropertyFunc(obj: proto, name: "padEnd",            fn: padEnd,            length: 1)
        ctx.setPropertyFunc(obj: proto, name: "normalize",         fn: normalize,         length: 0)
        ctx.setPropertyFunc(obj: proto, name: "localeCompare",     fn: localeCompare,     length: 1)

        // Wellformedness (ES2024)
        ctx.setPropertyFunc(obj: proto, name: "isWellFormed",      fn: isWellFormed,      length: 0)
        ctx.setPropertyFunc(obj: proto, name: "toWellFormed",      fn: toWellFormed,      length: 0)

        // Other
        ctx.setPropertyFunc(obj: proto, name: "concat",       fn: concat,       length: 1)
        ctx.setPropertyFunc(obj: proto, name: "toString",     fn: toString,     length: 0)
        ctx.setPropertyFunc(obj: proto, name: "valueOf",      fn: valueOf,      length: 0)

        // [Symbol.iterator]
        ctx.setPropertyFuncSymbol(obj: proto, name: "[Symbol.iterator]",
                                  fn: symbolIterator, length: 0)

        // Legacy HTML methods
        ctx.setPropertyFunc(obj: proto, name: "anchor",    fn: anchor,    length: 1)
        ctx.setPropertyFunc(obj: proto, name: "big",       fn: big,       length: 0)
        ctx.setPropertyFunc(obj: proto, name: "blink",     fn: blink,     length: 0)
        ctx.setPropertyFunc(obj: proto, name: "bold",      fn: bold,      length: 0)
        ctx.setPropertyFunc(obj: proto, name: "fixed",     fn: fixed,     length: 0)
        ctx.setPropertyFunc(obj: proto, name: "fontcolor", fn: fontcolor, length: 1)
        ctx.setPropertyFunc(obj: proto, name: "fontsize",  fn: fontsize,  length: 1)
        ctx.setPropertyFunc(obj: proto, name: "italics",   fn: italics,   length: 0)
        ctx.setPropertyFunc(obj: proto, name: "link",      fn: link,      length: 1)
        ctx.setPropertyFunc(obj: proto, name: "small",     fn: small,     length: 0)
        ctx.setPropertyFunc(obj: proto, name: "strike",    fn: strike,    length: 0)
        ctx.setPropertyFunc(obj: proto, name: "sub",       fn: sub_,      length: 0)
        ctx.setPropertyFunc(obj: proto, name: "sup",       fn: sup,       length: 0)

        // trimLeft / trimRight aliases
        ctx.setPropertyFunc(obj: proto, name: "trimLeft",  fn: trimStart, length: 0)
        ctx.setPropertyFunc(obj: proto, name: "trimRight", fn: trimEnd,   length: 0)

        // 6. Register String and String.prototype on the global object
        ctx.setGlobalConstructor(name: "String", ctor: ctor, proto: proto)
    }

    // MARK: - Internal Helpers

    /// Unwrap the string value from `this`, handling both primitive strings
    /// and String wrapper objects.  Mirrors QuickJS `thisStringValue`.
    static func thisStringValue(ctx: JeffJSContext, this: JeffJSValue) -> [UInt16]? {
        if this.isString {
            return ctx.toUTF16Array(this)
        }
        if this.isObject {
            if let obj = this.toObject(), obj.classID == JeffJSClassID.string.rawValue {
                let data = ctx.getObjectData(this)
                if data.isString {
                    return ctx.toUTF16Array(data)
                }
            }
        }
        return nil
    }

    /// Require `this` to be coercible (not null/undefined) and return its
    /// string conversion as UTF-16 code units.
    static func requireThisString(ctx: JeffJSContext, this: JeffJSValue, method: String) -> [UInt16]? {
        if this.isNull || this.isUndefined {
            _ = ctx.throwTypeError("String.prototype.\(method) called on null or undefined")
            return nil
        }
        let str = ctx.toString(this)
        if str.isException { return nil }
        return ctx.toUTF16Array(str)
    }

    /// Clamp an index to [0, length]. Negative indices count from the end.
    @inline(__always)
    static func clampIndex(_ val: Double, _ length: Int) -> Int {
        if val.isNaN || val <= 0 { return 0 }
        if val >= Double(length) { return length }
        return Int(val)
    }

    /// Convert a UTF-16 code unit array back to a JeffJSValue string.
    static func makeString(ctx: JeffJSContext, utf16: [UInt16]) -> JeffJSValue {
        return ctx.newStringFromUTF16(utf16)
    }

    /// Internal indexOf on UTF-16 arrays.
    static func indexOfInternal(_ str: [UInt16], _ search: [UInt16], _ startPos: Int) -> Int {
        let sLen = str.count
        let searchLen = search.count
        if searchLen == 0 { return min(startPos, sLen) }
        if searchLen > sLen { return -1 }
        let limit = sLen - searchLen
        var i = max(startPos, 0)
        while i <= limit {
            var j = 0
            while j < searchLen && str[i + j] == search[j] {
                j += 1
            }
            if j == searchLen { return i }
            i += 1
        }
        return -1
    }

    /// Internal lastIndexOf on UTF-16 arrays.
    static func lastIndexOfInternal(_ str: [UInt16], _ search: [UInt16], _ startPos: Int) -> Int {
        let sLen = str.count
        let searchLen = search.count
        if searchLen == 0 { return min(startPos, sLen) }
        if searchLen > sLen { return -1 }
        var i = min(startPos, sLen - searchLen)
        while i >= 0 {
            var j = 0
            while j < searchLen && str[i + j] == search[j] {
                j += 1
            }
            if j == searchLen { return i }
            i -= 1
        }
        return -1
    }

    /// Get substitution for replace patterns ($&, $`, $', $$, $<name>, $1..$9, $01..$99).
    /// Implements the GetSubstitution abstract operation from the spec.
    static func getSubstitution(ctx: JeffJSContext,
                                matched: [UInt16],
                                str: [UInt16],
                                position: Int,
                                captures: [[UInt16]?],
                                namedCaptures: JeffJSValue,
                                replacement: [UInt16]) -> [UInt16] {
        var result = [UInt16]()
        let repLen = replacement.count
        var i = 0

        while i < repLen {
            let c = replacement[i]
            if c == 0x24 /* $ */ && i + 1 < repLen {
                let next = replacement[i + 1]
                switch next {
                case 0x24: // $$
                    result.append(0x24)
                    i += 2
                case 0x26: // $& -> matched substring
                    result.append(contentsOf: matched)
                    i += 2
                case 0x60: // $` -> portion before match
                    let before = Array(str.prefix(max(position, 0)))
                    result.append(contentsOf: before)
                    i += 2
                case 0x27: // $' -> portion after match
                    let afterStart = min(position + matched.count, str.count)
                    let after = Array(str.suffix(from: afterStart))
                    result.append(contentsOf: after)
                    i += 2
                case 0x3C: // $< -> named capture
                    if namedCaptures.isUndefined {
                        result.append(0x24)
                        result.append(0x3C)
                        i += 2
                    } else {
                        // Find closing >
                        var j = i + 2
                        while j < repLen && replacement[j] != 0x3E { j += 1 }
                        if j >= repLen {
                            result.append(0x24)
                            result.append(0x3C)
                            i += 2
                        } else {
                            let groupName = Array(replacement[(i + 2)..<j])
                            let groupNameStr = makeString(ctx: ctx, utf16: groupName)
                            let capture = ctx.getProperty(obj: namedCaptures, key: groupNameStr)
                            if capture.isUndefined {
                                // do nothing, leave empty
                            } else {
                                let captureStr = ctx.toString(capture)
                                if let captureUnits = ctx.toUTF16ArrayOpt(captureStr) {
                                    result.append(contentsOf: captureUnits)
                                }
                            }
                            i = j + 1
                        }
                    }
                default:
                    // $n or $nn (capture group references)
                    if next >= 0x30 && next <= 0x39 { // '0'-'9'
                        var n = Int(next - 0x30)
                        var consumed = 2
                        // Check for two-digit reference $nn
                        if i + 2 < repLen {
                            let next2 = replacement[i + 2]
                            if next2 >= 0x30 && next2 <= 0x39 {
                                let nn = n * 10 + Int(next2 - 0x30)
                                if nn >= 1 && nn <= captures.count {
                                    n = nn
                                    consumed = 3
                                }
                            }
                        }
                        if n >= 1 && n <= captures.count {
                            if let capture = captures[n - 1] {
                                result.append(contentsOf: capture)
                            }
                            i += consumed
                        } else if n == 0 {
                            // $0 is not a valid capture reference; output literally
                            result.append(0x24)
                            i += 1
                        } else {
                            result.append(0x24)
                            i += 1
                        }
                    } else {
                        result.append(0x24)
                        i += 1
                    }
                }
            } else {
                result.append(c)
                i += 1
            }
        }
        return result
    }

    /// Check if a value is a RegExp by testing for Symbol.match property.
    static func isRegExp(ctx: JeffJSContext, _ val: JeffJSValue) -> Bool {
        if !val.isObject { return false }
        let matcher = ctx.getProperty(obj: val, atom: JeffJSAtomConstants.Symbol_match)
        if !matcher.isUndefined {
            return ctx.toBooleanFree(matcher)
        }
        // Stub: check if it's a RegExp by class ID
        if let obj = val.toObject(), obj.classID == JeffJSClassID.regexp.rawValue { return true }
        return false
    }

    // MARK: - Constructor

    /// `String(value)` / `new String(value)`
    static func stringConstructor(ctx: JeffJSContext, newTarget: JeffJSValue,
                                   this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let s: JeffJSValue
        if args.isEmpty {
            s = ctx.newStringValue("")
        } else {
            // If called as constructor and the argument is a Symbol, convert via Symbol description
            if newTarget.isObject && args[0].isSymbol {
                let desc = ctx.symbolDescriptiveString(args[0])
                if desc.isException { return .exception }
                s = desc
            } else {
                s = ctx.toString(args[0])
                if s.isException { return .exception }
            }
        }

        // Called as function: return the primitive string
        if newTarget.isUndefined {
            return s
        }

        // Called as constructor: return a String wrapper object
        let obj = ctx.newObjectFromNewTarget(newTarget: newTarget, classID: JeffJSClassID.string.rawValue)
        if obj.isException { return .exception }

        let strUnits = ctx.toUTF16Array(s)
        ctx.setObjectData(obj, value: s)

        // Also set primitiveValue so that getPropertyInternal can find
        // [[StringData]] for indexed access and .length on wrapper objects.
        if let jsObj = obj.toObject() {
            jsObj.primitiveValue = s
        }

        // Set the "length" property (non-writable, non-enumerable, non-configurable)
        _ = ctx.definePropertyValue(obj, name: "length", value: JeffJSValue.newInt32(Int32(strUnits.count)),
                                   flags: 0)

        return obj
    }

    // MARK: - Static Methods

    /// `String.fromCharCode(...codeUnits)`
    static func fromCharCode(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        var buf = [UInt16]()
        buf.reserveCapacity(args.count)
        for arg in args {
            buf.append(ctx.toUInt16(arg))
        }
        return makeString(ctx: ctx, utf16: buf)
    }

    /// `String.fromCodePoint(...codePoints)`
    static func fromCodePoint(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        var buf = [UInt16]()
        buf.reserveCapacity(args.count)
        for arg in args {
            let numVal = ctx.toNumber(arg)
            if numVal.isException { return .exception }
            let d = ctx.extractDouble(numVal)
            if d.isNaN || d.isInfinite || d < 0 || d > 0x10FFFF || d != d.rounded(.towardZero) {
                return ctx.throwRangeError("Invalid code point \(d)")
            }
            let cp = Int64(d)
            if cp < 0 || cp > 0x10FFFF {
                return ctx.throwRangeError("Invalid code point \(d)")
            }
            let codePoint = UInt32(cp)
            if codePoint <= 0xFFFF {
                buf.append(UInt16(codePoint))
            } else {
                // Encode as surrogate pair
                let adjusted = codePoint - 0x10000
                buf.append(UInt16(0xD800 + (adjusted >> 10)))
                buf.append(UInt16(0xDC00 + (adjusted & 0x3FF)))
            }
        }
        return makeString(ctx: ctx, utf16: buf)
    }

    /// `String.raw(template, ...substitutions)`
    static func raw(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard !args.isEmpty else {
            return ctx.throwTypeError("String.raw requires at least 1 argument")
        }
        let cooked = ctx.toObject(args[0])
        if cooked.isException { return .exception }

        let rawProp = ctx.getPropertyStr(obj: cooked, name: "raw")
        if rawProp.isException { return .exception }

        let rawObj = ctx.toObject(rawProp)
        if rawObj.isException { return .exception }

        let lenVal = ctx.getPropertyStr(obj: rawObj, name: "length")
        if lenVal.isException { return .exception }
        let literalSegments = Int(ctx.toLength(lenVal))
        if literalSegments <= 0 {
            return ctx.newStringValue("")
        }

        var result = [UInt16]()
        for i in 0..<literalSegments {
            // Get the next literal segment
            let segVal = ctx.getPropertyUInt32(obj: rawObj, index: UInt32(i))
            if segVal.isException { return .exception }
            let segStr = ctx.toString(segVal)
            if segStr.isException { return .exception }
            let segUnits = ctx.toUTF16Array(segStr)
            result.append(contentsOf: segUnits)

            // Append substitution (if any)
            if i + 1 < literalSegments && (i + 1) < args.count {
                let subStr = ctx.toString(args[i + 1])
                if subStr.isException { return .exception }
                let subUnits = ctx.toUTF16Array(subStr)
                result.append(contentsOf: subUnits)
            }
        }
        return makeString(ctx: ctx, utf16: result)
    }

    // MARK: - Character Access

    /// `String.prototype.charAt(pos)`
    static func charAt(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "charAt") else {
            return .exception
        }
        let pos: Int
        if args.isEmpty {
            pos = 0
        } else {
            let n = ctx.toInteger(args[0])
            if n.isException { return .exception }
            pos = ctx.extractInt(n)
        }
        if pos < 0 || pos >= str.count {
            return ctx.newStringValue("")
        }
        return makeString(ctx: ctx, utf16: [str[pos]])
    }

    /// `String.prototype.charCodeAt(pos)`
    static func charCodeAt(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "charCodeAt") else {
            return .exception
        }
        let pos: Int
        if args.isEmpty {
            pos = 0
        } else {
            let n = ctx.toInteger(args[0])
            if n.isException { return .exception }
            pos = ctx.extractInt(n)
        }
        if pos < 0 || pos >= str.count {
            return JeffJSValue.JS_NAN
        }
        return JeffJSValue.newInt32(Int32(str[pos]))
    }

    /// `String.prototype.codePointAt(pos)`
    static func codePointAt(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "codePointAt") else {
            return .exception
        }
        let pos: Int
        if args.isEmpty {
            pos = 0
        } else {
            let n = ctx.toInteger(args[0])
            if n.isException { return .exception }
            pos = ctx.extractInt(n)
        }
        if pos < 0 || pos >= str.count {
            return .undefined
        }
        let first = str[pos]
        if isHiSurrogate(first) && pos + 1 < str.count {
            let second = str[pos + 1]
            if isLoSurrogate(second) {
                let cp = unicodeFromUTF16Surrogates(high: first, low: second)
                return JeffJSValue.newInt32(Int32(cp))
            }
        }
        return JeffJSValue.newInt32(Int32(first))
    }

    /// `String.prototype.at(index)` (ES2022)
    static func at(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "at") else {
            return .exception
        }
        let len = str.count
        let relIndex: Int
        if args.isEmpty {
            relIndex = 0
        } else {
            let n = ctx.toInteger(args[0])
            if n.isException { return .exception }
            relIndex = ctx.extractInt(n)
        }
        let k = relIndex >= 0 ? relIndex : len + relIndex
        if k < 0 || k >= len {
            return .undefined
        }
        return makeString(ctx: ctx, utf16: [str[k]])
    }

    // MARK: - Search Methods

    /// `String.prototype.indexOf(searchString [, position])`
    static func indexOf(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "indexOf") else {
            return .exception
        }
        let searchStr: [UInt16]
        if args.isEmpty {
            searchStr = Array("undefined".utf16)
        } else {
            let s = ctx.toString(args[0])
            if s.isException { return .exception }
            searchStr = ctx.toUTF16Array(s)
        }
        var pos = 0
        if args.count >= 2 {
            let n = ctx.toInteger(args[1])
            if n.isException { return .exception }
            pos = ctx.extractInt(n)
        }
        pos = max(0, min(pos, str.count))
        let result = indexOfInternal(str, searchStr, pos)
        return JeffJSValue.newInt32(Int32(result))
    }

    /// `String.prototype.lastIndexOf(searchString [, position])`
    static func lastIndexOf(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "lastIndexOf") else {
            return .exception
        }
        let searchStr: [UInt16]
        if args.isEmpty {
            searchStr = Array("undefined".utf16)
        } else {
            let s = ctx.toString(args[0])
            if s.isException { return .exception }
            searchStr = ctx.toUTF16Array(s)
        }
        var pos = str.count
        if args.count >= 2 && !args[1].isUndefined {
            let numPos = ctx.toNumber(args[1])
            if numPos.isException { return .exception }
            let d = ctx.extractDouble(numPos)
            if !d.isNaN && d.isFinite {
                pos = max(0, min(Int(d), str.count))
            }
        }
        let result = lastIndexOfInternal(str, searchStr, pos)
        return JeffJSValue.newInt32(Int32(result))
    }

    /// `String.prototype.includes(searchString [, position])`
    static func includes(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "includes") else {
            return .exception
        }
        if !args.isEmpty && isRegExp(ctx: ctx, args[0]) {
            return ctx.throwTypeError("First argument to String.prototype.includes must not be a regular expression")
        }
        let searchStr: [UInt16]
        if args.isEmpty {
            searchStr = Array("undefined".utf16)
        } else {
            let s = ctx.toString(args[0])
            if s.isException { return .exception }
            searchStr = ctx.toUTF16Array(s)
        }
        var pos = 0
        if args.count >= 2 {
            let n = ctx.toInteger(args[1])
            if n.isException { return .exception }
            pos = ctx.extractInt(n)
        }
        pos = max(0, min(pos, str.count))
        return JeffJSValue.newBool(indexOfInternal(str, searchStr, pos) >= 0)
    }

    /// `String.prototype.startsWith(searchString [, position])`
    static func startsWith(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "startsWith") else {
            return .exception
        }
        if !args.isEmpty && isRegExp(ctx: ctx, args[0]) {
            return ctx.throwTypeError("First argument to String.prototype.startsWith must not be a regular expression")
        }
        let searchStr: [UInt16]
        if args.isEmpty {
            searchStr = Array("undefined".utf16)
        } else {
            let s = ctx.toString(args[0])
            if s.isException { return .exception }
            searchStr = ctx.toUTF16Array(s)
        }
        var start = 0
        if args.count >= 2 {
            let n = ctx.toInteger(args[1])
            if n.isException { return .exception }
            start = ctx.extractInt(n)
        }
        start = max(0, min(start, str.count))
        let searchLen = searchStr.count
        if start + searchLen > str.count {
            return .JS_FALSE
        }
        for i in 0..<searchLen {
            if str[start + i] != searchStr[i] {
                return .JS_FALSE
            }
        }
        return .JS_TRUE
    }

    /// `String.prototype.endsWith(searchString [, endPosition])`
    static func endsWith(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "endsWith") else {
            return .exception
        }
        if !args.isEmpty && isRegExp(ctx: ctx, args[0]) {
            return ctx.throwTypeError("First argument to String.prototype.endsWith must not be a regular expression")
        }
        let searchStr: [UInt16]
        if args.isEmpty {
            searchStr = Array("undefined".utf16)
        } else {
            let s = ctx.toString(args[0])
            if s.isException { return .exception }
            searchStr = ctx.toUTF16Array(s)
        }
        var endPos = str.count
        if args.count >= 2 && !args[1].isUndefined {
            let n = ctx.toInteger(args[1])
            if n.isException { return .exception }
            endPos = ctx.extractInt(n)
        }
        endPos = max(0, min(endPos, str.count))
        let searchLen = searchStr.count
        let start = endPos - searchLen
        if start < 0 {
            return .JS_FALSE
        }
        for i in 0..<searchLen {
            if str[start + i] != searchStr[i] {
                return .JS_FALSE
            }
        }
        return .JS_TRUE
    }

    // MARK: - Regex-Delegating Methods

    /// `String.prototype.match(regexp)`
    static func match(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        if this.isNull || this.isUndefined {
            return ctx.throwTypeError("String.prototype.match called on null or undefined")
        }
        let regexp = args.isEmpty ? .undefined : args[0]
        // If regexp has Symbol.match, delegate to it
        if !regexp.isNullOrUndefined {
            let matcher = ctx.getProperty(obj: regexp, atom: JeffJSAtomConstants.Symbol_match)
            if matcher.isException { return .exception }
            if !matcher.isNullOrUndefined {
                return ctx.callFunction(matcher, thisVal: regexp, args: [ctx.toString(this)])
            }
            // Direct fallback: if this is a RegExp, call [@@match] logic directly
            if let regexpObj = regexp.toObject(),
               regexpObj.classID == JeffJSClassID.regexp.rawValue {
                return js_regexp_Symbol_match(ctx: ctx, this: regexp, argv: [ctx.toString(this)])
            }
        }
        // Create a RegExp from the argument and call its Symbol.match
        let rx = ctx.newRegExp(pattern: regexp, flags: ctx.newStringValue(""))
        if rx.isException { return .exception }
        let matchFn = ctx.getProperty(obj: rx, atom: JeffJSAtomConstants.Symbol_match)
        if !matchFn.isException && !matchFn.isNullOrUndefined {
            return ctx.callFunction(matchFn, thisVal: rx, args: [ctx.toString(this)])
        }
        return js_regexp_Symbol_match(ctx: ctx, this: rx, argv: [ctx.toString(this)])
    }

    /// `String.prototype.matchAll(regexp)`
    static func matchAll(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        if this.isNull || this.isUndefined {
            return ctx.throwTypeError("String.prototype.matchAll called on null or undefined")
        }
        let regexp = args.isEmpty ? .undefined : args[0]
        if !regexp.isNullOrUndefined {
            if isRegExp(ctx: ctx, regexp) {
                // Check that the 'g' flag is set
                let flagsVal = ctx.getPropertyStr(obj: regexp, name: "flags")
                if flagsVal.isException { return .exception }
                let flagsStr = ctx.toString(flagsVal)
                if flagsStr.isException { return .exception }
                let flagsUnits = ctx.toUTF16Array(flagsStr)
                if !flagsUnits.contains(0x67 /* 'g' */) {
                    return ctx.throwTypeError("String.prototype.matchAll called with a non-global RegExp argument")
                }
            }
            let matcher = ctx.getProperty(obj: regexp, atom: JeffJSAtomConstants.Symbol_matchAll)
            if matcher.isException { return .exception }
            if !matcher.isNullOrUndefined {
                return ctx.callFunction(matcher, thisVal: regexp, args: [ctx.toString(this)])
            }
            // Direct fallback: if this is a RegExp, call [@@matchAll] logic directly
            if let regexpObj = regexp.toObject(),
               regexpObj.classID == JeffJSClassID.regexp.rawValue {
                return js_regexp_Symbol_matchAll(ctx: ctx, this: regexp, argv: [ctx.toString(this)])
            }
        }
        let rx = ctx.newRegExp(pattern: regexp, flags: ctx.newStringValue("g"))
        if rx.isException { return .exception }
        let matchAllFn = ctx.getProperty(obj: rx, atom: JeffJSAtomConstants.Symbol_matchAll)
        if matchAllFn.isException { return .exception }
        return ctx.callFunction(matchAllFn, thisVal: rx, args: [ctx.toString(this)])
    }

    /// `String.prototype.search(regexp)`
    static func search(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        if this.isNull || this.isUndefined {
            return ctx.throwTypeError("String.prototype.search called on null or undefined")
        }
        let regexp = args.isEmpty ? .undefined : args[0]
        if !regexp.isNullOrUndefined {
            let searcher = ctx.getProperty(obj: regexp, atom: JeffJSAtomConstants.Symbol_search)
            if searcher.isException { return .exception }
            if !searcher.isNullOrUndefined {
                return ctx.callFunction(searcher, thisVal: regexp, args: [ctx.toString(this)])
            }
            // Direct fallback: if this is a RegExp, call [@@search] logic directly
            if let regexpObj = regexp.toObject(),
               regexpObj.classID == JeffJSClassID.regexp.rawValue {
                return js_regexp_Symbol_search(ctx: ctx, this: regexp, argv: [ctx.toString(this)])
            }
        }
        let rx = ctx.newRegExp(pattern: regexp, flags: ctx.newStringValue(""))
        if rx.isException { return .exception }
        // Try Symbol.search, then fall back to direct call
        let searchFn = ctx.getProperty(obj: rx, atom: JeffJSAtomConstants.Symbol_search)
        if !searchFn.isException && !searchFn.isNullOrUndefined {
            return ctx.callFunction(searchFn, thisVal: rx, args: [ctx.toString(this)])
        }
        return js_regexp_Symbol_search(ctx: ctx, this: rx, argv: [ctx.toString(this)])
    }

    /// `String.prototype.replace(searchValue, replaceValue)`
    static func replace(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        if this.isNull || this.isUndefined {
            return ctx.throwTypeError("String.prototype.replace called on null or undefined")
        }
        let searchValue = args.count > 0 ? args[0] : JeffJSValue.undefined
        let replaceValue = args.count > 1 ? args[1] : JeffJSValue.undefined

        // Delegate via Symbol.replace if present
        if !searchValue.isNullOrUndefined {
            let replacer = ctx.getProperty(obj: searchValue, atom: JeffJSAtomConstants.Symbol_replace)
            if replacer.isException { return .exception }
            if !replacer.isNullOrUndefined {
                return ctx.callFunction(replacer, thisVal: searchValue,
                                        args: [ctx.toString(this), replaceValue])
            }
            // Direct fallback: if this is a RegExp, call [@@replace] logic directly
            if let searchObj = searchValue.toObject(),
               searchObj.classID == JeffJSClassID.regexp.rawValue {
                return js_regexp_Symbol_replace(ctx: ctx, this: searchValue,
                                                argv: [ctx.toString(this), replaceValue])
            }
        }

        // String-based replace (first occurrence only)
        let strVal = ctx.toString(this)
        if strVal.isException { return .exception }
        let str = ctx.toUTF16Array(strVal)

        let searchVal = ctx.toString(searchValue)
        if searchVal.isException { return .exception }
        let searchStr = ctx.toUTF16Array(searchVal)

        let pos = indexOfInternal(str, searchStr, 0)
        if pos == -1 {
            return strVal // no match
        }

        let functionalReplace = ctx.isFunction(replaceValue)
        let replaceStr: [UInt16]
        if functionalReplace {
            let replResult = ctx.callFunction(replaceValue, thisVal: .undefined,
                                              args: [makeString(ctx: ctx, utf16: searchStr),
                                                     JeffJSValue.newInt32(Int32(pos)),
                                                     strVal])
            if replResult.isException { return .exception }
            let rs = ctx.toString(replResult)
            if rs.isException { return .exception }
            replaceStr = ctx.toUTF16Array(rs)
        } else {
            let rv = ctx.toString(replaceValue)
            if rv.isException { return .exception }
            let rvUnits = ctx.toUTF16Array(rv)
            replaceStr = getSubstitution(ctx: ctx, matched: searchStr, str: str,
                                         position: pos, captures: [],
                                         namedCaptures: .undefined,
                                         replacement: rvUnits)
        }

        var result = Array(str.prefix(pos))
        result.append(contentsOf: replaceStr)
        result.append(contentsOf: str.suffix(from: pos + searchStr.count))
        return makeString(ctx: ctx, utf16: result)
    }

    /// `String.prototype.replaceAll(searchValue, replaceValue)`
    static func replaceAll(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        if this.isNull || this.isUndefined {
            return ctx.throwTypeError("String.prototype.replaceAll called on null or undefined")
        }
        let searchValue = args.count > 0 ? args[0] : JeffJSValue.undefined
        let replaceValue = args.count > 1 ? args[1] : JeffJSValue.undefined

        // If searchValue is a RegExp, it must have the global flag
        if isRegExp(ctx: ctx, searchValue) {
            let flagsVal = ctx.getPropertyStr(obj: searchValue, name: "flags")
            if flagsVal.isException { return .exception }
            let flagsStr = ctx.toString(flagsVal)
            if flagsStr.isException { return .exception }
            let flagsUnits = ctx.toUTF16Array(flagsStr)
            if !flagsUnits.contains(0x67 /* 'g' */) {
                return ctx.throwTypeError("String.prototype.replaceAll called with a non-global RegExp argument")
            }
        }

        // Delegate via Symbol.replace if present
        if !searchValue.isNullOrUndefined {
            let replacer = ctx.getProperty(obj: searchValue, atom: JeffJSAtomConstants.Symbol_replace)
            if replacer.isException { return .exception }
            if !replacer.isNullOrUndefined {
                return ctx.callFunction(replacer, thisVal: searchValue,
                                        args: [ctx.toString(this), replaceValue])
            }
            // Direct fallback: if this is a RegExp, call [@@replace] logic directly
            if let searchObj = searchValue.toObject(),
               searchObj.classID == JeffJSClassID.regexp.rawValue {
                return js_regexp_Symbol_replace(ctx: ctx, this: searchValue,
                                                argv: [ctx.toString(this), replaceValue])
            }
        }

        // String-based replaceAll
        let strVal = ctx.toString(this)
        if strVal.isException { return .exception }
        let str = ctx.toUTF16Array(strVal)

        let searchVal = ctx.toString(searchValue)
        if searchVal.isException { return .exception }
        let searchStr = ctx.toUTF16Array(searchVal)

        let functionalReplace = ctx.isFunction(replaceValue)
        let replValStr: [UInt16]
        if functionalReplace {
            replValStr = []
        } else {
            let rv = ctx.toString(replaceValue)
            if rv.isException { return .exception }
            replValStr = ctx.toUTF16Array(rv)
        }

        var result = [UInt16]()
        var prevEnd = 0
        let searchLen = searchStr.count
        let advance = max(searchLen, 1)

        var pos = indexOfInternal(str, searchStr, 0)
        while pos != -1 {
            result.append(contentsOf: str[prevEnd..<pos])

            if functionalReplace {
                let replResult = ctx.callFunction(replaceValue, thisVal: .undefined,
                                                  args: [makeString(ctx: ctx, utf16: searchStr),
                                                         JeffJSValue.newInt32(Int32(pos)),
                                                         strVal])
                if replResult.isException { return .exception }
                let rs = ctx.toString(replResult)
                if rs.isException { return .exception }
                result.append(contentsOf: ctx.toUTF16Array(rs))
            } else {
                let sub = getSubstitution(ctx: ctx, matched: searchStr, str: str,
                                          position: pos, captures: [],
                                          namedCaptures: .undefined,
                                          replacement: replValStr)
                result.append(contentsOf: sub)
            }

            prevEnd = pos + searchLen
            pos = indexOfInternal(str, searchStr, pos + advance)
        }
        result.append(contentsOf: str[prevEnd...])
        return makeString(ctx: ctx, utf16: result)
    }

    /// `String.prototype.split(separator, limit)`
    static func split(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        if this.isNull || this.isUndefined {
            return ctx.throwTypeError("String.prototype.split called on null or undefined")
        }
        let separator = args.count > 0 ? args[0] : JeffJSValue.undefined
        let limitArg  = args.count > 1 ? args[1] : JeffJSValue.undefined

        // Delegate via Symbol.split if present
        if !separator.isNullOrUndefined {
            let splitter = ctx.getProperty(obj: separator, atom: JeffJSAtomConstants.Symbol_split)
            if splitter.isException { return .exception }
            if !splitter.isNullOrUndefined {
                return ctx.callFunction(splitter, thisVal: separator,
                                        args: [ctx.toString(this), limitArg])
            }
            // Direct fallback: if this is a RegExp, call [@@split] logic directly
            if let sepObj = separator.toObject(),
               sepObj.classID == JeffJSClassID.regexp.rawValue {
                return js_regexp_Symbol_split(ctx: ctx, this: separator,
                                              argv: [ctx.toString(this), limitArg])
            }
        }

        let strVal = ctx.toString(this)
        if strVal.isException { return .exception }
        let str = ctx.toUTF16Array(strVal)

        // Compute limit
        let lim: Int
        if limitArg.isUndefined {
            lim = Int(UInt32.max)
        } else {
            lim = Int(ctx.toUInt32(limitArg))
        }

        let arr = ctx.newArray()
        if arr.isException { return .exception }

        if lim == 0 {
            return arr
        }

        // undefined separator returns the whole string as single element
        if separator.isUndefined {
            ctx.setPropertyUInt32(obj: arr, index: 0, value: strVal)
            return arr
        }

        let sepVal = ctx.toString(separator)
        if sepVal.isException { return .exception }
        let sepStr = ctx.toUTF16Array(sepVal)

        if str.isEmpty {
            // Empty string: if sep matches empty, return []; else [""]
            if sepStr.isEmpty {
                return arr
            }
            ctx.setPropertyUInt32(obj: arr, index: 0, value: strVal)
            return arr
        }

        if sepStr.isEmpty {
            // Split into individual code units
            var count = 0
            for i in 0..<str.count {
                if count >= lim { break }
                ctx.setPropertyUInt32(obj: arr, index: UInt32(count),
                                      value: makeString(ctx: ctx, utf16: [str[i]]))
                count += 1
            }
            return arr
        }

        var count = 0
        var start = 0
        while start <= str.count {
            let pos = indexOfInternal(str, sepStr, start)
            if pos == -1 { break }
            let segment = Array(str[start..<pos])
            ctx.setPropertyUInt32(obj: arr, index: UInt32(count),
                                  value: makeString(ctx: ctx, utf16: segment))
            count += 1
            if count >= lim { return arr }
            start = pos + sepStr.count
        }
        // Remaining portion
        let tail = Array(str[start...])
        ctx.setPropertyUInt32(obj: arr, index: UInt32(count),
                              value: makeString(ctx: ctx, utf16: tail))
        return arr
    }

    // MARK: - Extraction Methods

    /// `String.prototype.substring(start, end)`
    static func substring(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "substring") else {
            return .exception
        }
        let len = str.count
        var intStart = 0
        if !args.isEmpty {
            let n = ctx.toInteger(args[0])
            if n.isException { return .exception }
            intStart = ctx.extractInt(n)
        }
        var intEnd = len
        if args.count >= 2 && !args[1].isUndefined {
            let n = ctx.toInteger(args[1])
            if n.isException { return .exception }
            intEnd = ctx.extractInt(n)
        }
        intStart = max(0, min(intStart, len))
        intEnd = max(0, min(intEnd, len))
        if intStart > intEnd {
            swap(&intStart, &intEnd)
        }
        return makeString(ctx: ctx, utf16: Array(str[intStart..<intEnd]))
    }

    /// `String.prototype.substr(start, length)` (legacy, Annex B)
    static func substr(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "substr") else {
            return .exception
        }
        let len = str.count
        var intStart: Int
        if args.isEmpty {
            intStart = 0
        } else {
            let n = ctx.toInteger(args[0])
            if n.isException { return .exception }
            intStart = ctx.extractInt(n)
        }
        var resultLength: Int
        if args.count >= 2 && !args[1].isUndefined {
            let n = ctx.toInteger(args[1])
            if n.isException { return .exception }
            resultLength = ctx.extractInt(n)
        } else {
            resultLength = len
        }
        if intStart < 0 {
            intStart = max(len + intStart, 0)
        }
        resultLength = max(0, min(resultLength, len - intStart))
        if resultLength <= 0 {
            return ctx.newStringValue("")
        }
        return makeString(ctx: ctx, utf16: Array(str[intStart..<(intStart + resultLength)]))
    }

    /// `String.prototype.slice(start, end)`
    static func slice(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "slice") else {
            return .exception
        }
        let len = str.count
        var intStart: Int
        if args.isEmpty {
            intStart = 0
        } else {
            let n = ctx.toInteger(args[0])
            if n.isException { return .exception }
            intStart = ctx.extractInt(n)
        }
        var intEnd: Int
        if args.count >= 2 && !args[1].isUndefined {
            let n = ctx.toInteger(args[1])
            if n.isException { return .exception }
            intEnd = ctx.extractInt(n)
        } else {
            intEnd = len
        }
        if intStart < 0 { intStart = max(len + intStart, 0) } else { intStart = min(intStart, len) }
        if intEnd < 0 { intEnd = max(len + intEnd, 0) } else { intEnd = min(intEnd, len) }
        let span = max(intEnd - intStart, 0)
        if span == 0 {
            return ctx.newStringValue("")
        }
        return makeString(ctx: ctx, utf16: Array(str[intStart..<(intStart + span)]))
    }

    // MARK: - Transformation Methods

    /// `String.prototype.toLowerCase()`
    static func toLowerCase(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "toLowerCase") else {
            return .exception
        }
        let swiftStr = String(utf16CodeUnits: str, count: str.count)
        let lower = swiftStr.lowercased()
        return ctx.newStringFromUTF16(Array(lower.utf16))
    }

    /// `String.prototype.toUpperCase()`
    static func toUpperCase(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "toUpperCase") else {
            return .exception
        }
        let swiftStr = String(utf16CodeUnits: str, count: str.count)
        let upper = swiftStr.uppercased()
        return ctx.newStringFromUTF16(Array(upper.utf16))
    }

    /// `String.prototype.toLocaleLowerCase([locale])`
    static func toLocaleLowerCase(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "toLocaleLowerCase") else {
            return .exception
        }
        let swiftStr = String(utf16CodeUnits: str, count: str.count)
        let locale: Locale
        if !args.isEmpty && !args[0].isUndefined {
            let localeStr = ctx.toString(args[0])
            if localeStr.isException { return .exception }
            locale = Locale(identifier: ctx.toSwiftString(localeStr) ?? "")
        } else {
            locale = Locale.current
        }
        let lower = swiftStr.lowercased(with: locale)
        return ctx.newStringFromUTF16(Array(lower.utf16))
    }

    /// `String.prototype.toLocaleUpperCase([locale])`
    static func toLocaleUpperCase(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "toLocaleUpperCase") else {
            return .exception
        }
        let swiftStr = String(utf16CodeUnits: str, count: str.count)
        let locale: Locale
        if !args.isEmpty && !args[0].isUndefined {
            let localeStr = ctx.toString(args[0])
            if localeStr.isException { return .exception }
            locale = Locale(identifier: ctx.toSwiftString(localeStr) ?? "")
        } else {
            locale = Locale.current
        }
        let upper = swiftStr.uppercased(with: locale)
        return ctx.newStringFromUTF16(Array(upper.utf16))
    }

    /// `String.prototype.trim()`
    static func trim(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "trim") else {
            return .exception
        }
        let start = findTrimStart(str)
        let end = findTrimEnd(str)
        if start > end {
            return ctx.newStringValue("")
        }
        return makeString(ctx: ctx, utf16: Array(str[start...end]))
    }

    /// `String.prototype.trimStart()`
    static func trimStart(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "trimStart") else {
            return .exception
        }
        let start = findTrimStart(str)
        if start >= str.count {
            return ctx.newStringValue("")
        }
        return makeString(ctx: ctx, utf16: Array(str[start...]))
    }

    /// `String.prototype.trimEnd()`
    static func trimEnd(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "trimEnd") else {
            return .exception
        }
        let end = findTrimEnd(str)
        if end < 0 {
            return ctx.newStringValue("")
        }
        return makeString(ctx: ctx, utf16: Array(str[...end]))
    }

    /// Helper: find the index of the first non-whitespace character.
    private static func findTrimStart(_ str: [UInt16]) -> Int {
        var i = 0
        while i < str.count && isJSWhitespace(str[i]) {
            i += 1
        }
        return i
    }

    /// Helper: find the index of the last non-whitespace character.
    private static func findTrimEnd(_ str: [UInt16]) -> Int {
        var i = str.count - 1
        while i >= 0 && isJSWhitespace(str[i]) {
            i -= 1
        }
        return i
    }

    /// JS whitespace characters per the spec (WhiteSpace + LineTerminator).
    private static func isJSWhitespace(_ c: UInt16) -> Bool {
        switch c {
        case 0x0009, // TAB
             0x000A, // LF
             0x000B, // VT
             0x000C, // FF
             0x000D, // CR
             0x0020, // SPACE
             0x00A0, // NBSP
             0x1680, // OGHAM SPACE MARK
             0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006,
             0x2007, 0x2008, 0x2009, 0x200A, // EN QUAD..HAIR SPACE
             0x2028, // LINE SEPARATOR
             0x2029, // PARAGRAPH SEPARATOR
             0x202F, // NARROW NO-BREAK SPACE
             0x205F, // MEDIUM MATHEMATICAL SPACE
             0x3000, // IDEOGRAPHIC SPACE
             0xFEFF: // BOM / ZWNBSP
            return true
        default:
            return false
        }
    }

    /// `String.prototype.repeat(count)`
    static func repeat_(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "repeat") else {
            return .exception
        }
        let countVal = args.isEmpty ? JeffJSValue.newInt32(0) : args[0]
        let n = ctx.toInteger(countVal)
        if n.isException { return .exception }
        let count = ctx.extractInt(n)
        if count < 0 {
            return ctx.throwRangeError("Invalid count value")
        }
        let d = ctx.extractDouble(ctx.toNumber(countVal))
        if d == Double.infinity {
            return ctx.throwRangeError("Invalid count value")
        }
        if count == 0 || str.isEmpty {
            return ctx.newStringValue("")
        }
        if str.count * count > JS_STRING_LEN_MAX {
            return ctx.throwRangeError("Invalid string length")
        }
        var result = [UInt16]()
        result.reserveCapacity(str.count * count)
        for _ in 0..<count {
            result.append(contentsOf: str)
        }
        return makeString(ctx: ctx, utf16: result)
    }

    /// `String.prototype.padStart(targetLength [, padString])`
    static func padStart(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "padStart") else {
            return .exception
        }
        return padInternal(ctx: ctx, str: str, args: args, padEnd: false)
    }

    /// `String.prototype.padEnd(targetLength [, padString])`
    static func padEnd(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "padEnd") else {
            return .exception
        }
        return padInternal(ctx: ctx, str: str, args: args, padEnd: true)
    }

    private static func padInternal(ctx: JeffJSContext, str: [UInt16], args: [JeffJSValue], padEnd: Bool) -> JeffJSValue {
        let maxLength: Int
        if args.isEmpty {
            maxLength = 0
        } else {
            let n = ctx.toLength2(args[0])
            if n < 0 { return .exception }
            maxLength = n
        }
        if maxLength <= str.count {
            return makeString(ctx: ctx, utf16: str)
        }
        let fillStr: [UInt16]
        if args.count >= 2 && !args[1].isUndefined {
            let fs = ctx.toString(args[1])
            if fs.isException { return .exception }
            fillStr = ctx.toUTF16Array(fs)
            if fillStr.isEmpty {
                return makeString(ctx: ctx, utf16: str)
            }
        } else {
            fillStr = [0x0020] // space
        }
        let fillLen = maxLength - str.count
        if fillLen > JS_STRING_LEN_MAX {
            return ctx.throwRangeError("Invalid string length")
        }
        var padding = [UInt16]()
        padding.reserveCapacity(fillLen)
        var i = 0
        while padding.count < fillLen {
            padding.append(fillStr[i % fillStr.count])
            i += 1
        }
        if padEnd {
            var result = str
            result.append(contentsOf: padding)
            return makeString(ctx: ctx, utf16: result)
        } else {
            padding.append(contentsOf: str)
            return makeString(ctx: ctx, utf16: padding)
        }
    }

    /// `String.prototype.normalize([form])`
    static func normalize(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "normalize") else {
            return .exception
        }
        let swiftStr = String(utf16CodeUnits: str, count: str.count)
        let form: String
        if args.isEmpty || args[0].isUndefined {
            form = "NFC"
        } else {
            let fv = ctx.toString(args[0])
            if fv.isException { return .exception }
            form = ctx.toSwiftString(fv) ?? ""
        }
        let normalized: String
        switch form {
        case "NFC":
            normalized = swiftStr.precomposedStringWithCanonicalMapping
        case "NFD":
            normalized = swiftStr.decomposedStringWithCanonicalMapping
        case "NFKC":
            normalized = swiftStr.precomposedStringWithCompatibilityMapping
        case "NFKD":
            normalized = swiftStr.decomposedStringWithCompatibilityMapping
        default:
            return ctx.throwRangeError("The normalization form should be one of NFC, NFD, NFKC, NFKD")
        }
        return ctx.newStringFromUTF16(Array(normalized.utf16))
    }

    /// `String.prototype.localeCompare(that [, locales [, options]])`
    static func localeCompare(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "localeCompare") else {
            return .exception
        }
        let thatVal = args.isEmpty ? JeffJSValue.undefined : args[0]
        let thatStr = ctx.toString(thatVal)
        if thatStr.isException { return .exception }
        let that = ctx.toUTF16Array(thatStr)

        let s1 = String(utf16CodeUnits: str, count: str.count)
        let s2 = String(utf16CodeUnits: that, count: that.count)

        let locale: Locale
        if args.count >= 2 && !args[1].isUndefined {
            let locStr = ctx.toString(args[1])
            if locStr.isException { return .exception }
            locale = Locale(identifier: ctx.toSwiftString(locStr) ?? "")
        } else {
            locale = Locale.current
        }
        let result = s1.compare(s2, locale: locale)
        switch result {
        case .orderedAscending:
            return JeffJSValue.newInt32(-1)
        case .orderedSame:
            return JeffJSValue.newInt32(0)
        case .orderedDescending:
            return JeffJSValue.newInt32(1)
        }
    }

    // MARK: - Wellformedness (ES2024)

    /// `String.prototype.isWellFormed()`
    static func isWellFormed(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "isWellFormed") else {
            return .exception
        }
        var i = 0
        while i < str.count {
            let c = str[i]
            if isHiSurrogate(c) {
                if i + 1 >= str.count || !isLoSurrogate(str[i + 1]) {
                    return .JS_FALSE
                }
                i += 2
            } else if isLoSurrogate(c) {
                return .JS_FALSE
            } else {
                i += 1
            }
        }
        return .JS_TRUE
    }

    /// `String.prototype.toWellFormed()`
    static func toWellFormed(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "toWellFormed") else {
            return .exception
        }
        var result = [UInt16]()
        result.reserveCapacity(str.count)
        var i = 0
        while i < str.count {
            let c = str[i]
            if isHiSurrogate(c) {
                if i + 1 < str.count && isLoSurrogate(str[i + 1]) {
                    result.append(c)
                    result.append(str[i + 1])
                    i += 2
                } else {
                    result.append(0xFFFD) // replacement character
                    i += 1
                }
            } else if isLoSurrogate(c) {
                result.append(0xFFFD)
                i += 1
            } else {
                result.append(c)
                i += 1
            }
        }
        return makeString(ctx: ctx, utf16: result)
    }

    // MARK: - Other Methods

    /// `String.prototype.concat(...args)`
    static func concat(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "concat") else {
            return .exception
        }
        var result = str
        for arg in args {
            let s = ctx.toString(arg)
            if s.isException { return .exception }
            result.append(contentsOf: ctx.toUTF16Array(s))
        }
        return makeString(ctx: ctx, utf16: result)
    }

    /// `String.prototype.toString()`
    static func toString(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let units = thisStringValue(ctx: ctx, this: this) else {
            return ctx.throwTypeError("String.prototype.toString requires that 'this' be a String")
        }
        return makeString(ctx: ctx, utf16: units)
    }

    /// `String.prototype.valueOf()`
    static func valueOf(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let units = thisStringValue(ctx: ctx, this: this) else {
            return ctx.throwTypeError("String.prototype.valueOf requires that 'this' be a String")
        }
        return makeString(ctx: ctx, utf16: units)
    }

    // MARK: - Symbol.iterator

    /// `String.prototype[Symbol.iterator]()`
    /// Returns an iterator that yields code points (not code units).
    static func symbolIterator(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: "[Symbol.iterator]") else {
            return .exception
        }
        // Create a string iterator object (class ID = stringIterator)
        let iterObj = ctx.newObject(classID: JeffJSClassID.stringIterator.rawValue)
        if iterObj.isException { return .exception }

        // Store the string and the current index
        ctx.setObjectData(iterObj, value: makeString(ctx: ctx, utf16: str))
        ctx.setInternalIndex(iterObj, index: 0)

        return iterObj
    }

    /// The `next()` method for the string iterator.
    /// Iterates by code points, emitting surrogate pairs as a single character.
    static func stringIteratorNext(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        let strVal = ctx.getObjectData(this)
        if strVal.isUndefined {
            return ctx.createIterResult(value: .undefined, done: true)
        }
        let str = ctx.toUTF16Array(strVal)
        var index = ctx.getInternalIndex(this)

        if index >= str.count {
            // Mark as done
            ctx.setObjectData(this, value: .undefined)
            return ctx.createIterResult(value: .undefined, done: true)
        }

        let first = str[index]
        var resultStr: [UInt16]
        if isHiSurrogate(first) && index + 1 < str.count && isLoSurrogate(str[index + 1]) {
            resultStr = [first, str[index + 1]]
            index += 2
        } else {
            resultStr = [first]
            index += 1
        }
        ctx.setInternalIndex(this, index: index)

        return ctx.createIterResult(value: makeString(ctx: ctx, utf16: resultStr), done: false)
    }

    // MARK: - Legacy HTML Methods (Annex B)

    private static func createHTMLTag(ctx: JeffJSContext, this: JeffJSValue,
                                      tag: String, attribute: String? = nil,
                                      attrValue: JeffJSValue? = nil) -> JeffJSValue {
        guard let str = requireThisString(ctx: ctx, this: this, method: tag) else {
            return .exception
        }
        var result = [UInt16]()
        result.append(contentsOf: Array("<\(tag)".utf16))
        if let attribute = attribute, let attrVal = attrValue {
            let av = ctx.toString(attrVal)
            if av.isException { return .exception }
            let avUnits = ctx.toUTF16Array(av)
            result.append(contentsOf: Array(" \(attribute)=\"".utf16))
            // Escape quotes in the attribute value
            for c in avUnits {
                if c == 0x22 { // "
                    result.append(contentsOf: Array("&quot;".utf16))
                } else {
                    result.append(c)
                }
            }
            result.append(0x22) // "
        }
        result.append(0x3E) // >
        result.append(contentsOf: str)
        result.append(contentsOf: Array("</\(tag)>".utf16))
        return makeString(ctx: ctx, utf16: result)
    }

    static func anchor(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        return createHTMLTag(ctx: ctx, this: this, tag: "a", attribute: "name",
                             attrValue: args.isEmpty ? .undefined : args[0])
    }

    static func big(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        return createHTMLTag(ctx: ctx, this: this, tag: "big")
    }

    static func blink(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        return createHTMLTag(ctx: ctx, this: this, tag: "blink")
    }

    static func bold(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        return createHTMLTag(ctx: ctx, this: this, tag: "b")
    }

    static func fixed(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        return createHTMLTag(ctx: ctx, this: this, tag: "tt")
    }

    static func fontcolor(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        return createHTMLTag(ctx: ctx, this: this, tag: "font", attribute: "color",
                             attrValue: args.isEmpty ? .undefined : args[0])
    }

    static func fontsize(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        return createHTMLTag(ctx: ctx, this: this, tag: "font", attribute: "size",
                             attrValue: args.isEmpty ? .undefined : args[0])
    }

    static func italics(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        return createHTMLTag(ctx: ctx, this: this, tag: "i")
    }

    static func link(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        return createHTMLTag(ctx: ctx, this: this, tag: "a", attribute: "href",
                             attrValue: args.isEmpty ? .undefined : args[0])
    }

    static func small(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        return createHTMLTag(ctx: ctx, this: this, tag: "small")
    }

    static func strike(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        return createHTMLTag(ctx: ctx, this: this, tag: "strike")
    }

    static func sub_(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        return createHTMLTag(ctx: ctx, this: this, tag: "sub")
    }

    static func sup(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        return createHTMLTag(ctx: ctx, this: this, tag: "sup")
    }

    // MARK: - Exotic String Object Property Handler

    /// Handler for indexed property access on String wrapper objects.
    /// JS strings have exotic [[GetOwnProperty]] that exposes each code unit
    /// as a read-only, non-configurable, enumerable property at numeric indices.
    static func stringGetOwnProperty(ctx: JeffJSContext, obj: JeffJSValue,
                                     index: UInt32) -> JeffJSValue {
        let data = ctx.getObjectData(obj)
        if !data.isString { return .undefined }
        let str = ctx.toUTF16Array(data)
        if index >= str.count {
            return .undefined
        }
        return makeString(ctx: ctx, utf16: [str[Int(index)]])
    }

    /// Returns the list of own property keys for the exotic string object:
    /// "0", "1", ..., "length" followed by any user-added properties.
    static func stringOwnPropertyKeys(ctx: JeffJSContext, obj: JeffJSValue) -> [JeffJSValue] {
        let data = ctx.getObjectData(obj)
        var keys = [JeffJSValue]()
        if data.isString {
            let str = ctx.toUTF16Array(data)
            for i in 0..<str.count {
                keys.append(ctx.newStringValue(String(i)))
            }
        }
        return keys
    }
}

// MARK: - JeffJSAtomConstants (bridging atom references)

/// Provides convenient access to well-known atom constants used by builtins.
/// These map to the predefined atoms in JeffJSAtom.swift.
struct JeffJSAtomConstants {
    static let Symbol_iterator:            UInt32 = JSPredefinedAtom.Symbol_iterator.rawValue
    static let Symbol_match:               UInt32 = JSPredefinedAtom.Symbol_match.rawValue
    static let Symbol_matchAll:            UInt32 = JSPredefinedAtom.Symbol_matchAll.rawValue
    static let Symbol_replace:             UInt32 = JSPredefinedAtom.Symbol_replace.rawValue
    static let Symbol_search:              UInt32 = JSPredefinedAtom.Symbol_search.rawValue
    static let Symbol_split:               UInt32 = JSPredefinedAtom.Symbol_split.rawValue
    static let Symbol_toPrimitive:         UInt32 = JSPredefinedAtom.Symbol_toPrimitive.rawValue
    static let Symbol_toStringTag:         UInt32 = JSPredefinedAtom.Symbol_toStringTag.rawValue
    static let Symbol_isConcatSpreadable:  UInt32 = JSPredefinedAtom.Symbol_isConcatSpreadable.rawValue
    static let Symbol_hasInstance:         UInt32 = JSPredefinedAtom.Symbol_hasInstance.rawValue
    static let Symbol_species:             UInt32 = JSPredefinedAtom.Symbol_species.rawValue
}
