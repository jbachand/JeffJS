// JeffJSBuiltinJSON.swift
// JeffJS - 1:1 Swift port of QuickJS JavaScript engine
//
// Port of the JSON built-in object from QuickJS.
// Implements JSON.parse() and JSON.stringify() per ECMA-262.
//
// QuickJS source reference: quickjs.c — js_json_parse, js_json_stringify,
// json_parse_value, json_next_token, JS_JSONStringify, etc.

import Foundation

// MARK: - JSON Parse Token

/// Token types used by the JSON lexer/parser.
private enum JSONToken {
    case string(String)
    case number(Double)
    case lbrace        // {
    case rbrace        // }
    case lbracket      // [
    case rbracket      // ]
    case comma         // ,
    case colon         // :
    case true_
    case false_
    case null_
    case eof
    case error(String)
}

// MARK: - JSON Parse State

/// Internal state for the recursive-descent JSON parser.
/// Mirrors the parse state in QuickJS json_parse_value / json_next_token.
private final class JSONParseState {
    let ctx: JeffJSContext
    let input: [UInt8]
    var pos: Int
    let end: Int
    var extJSON: Bool  // If true, allow extended JSON (trailing commas, etc.)

    init(ctx: JeffJSContext, input: [UInt8], extJSON: Bool = false) {
        self.ctx = ctx
        self.input = input
        self.pos = 0
        self.end = input.count
        self.extJSON = extJSON
    }

    var isEOF: Bool { pos >= end }

    func peek() -> UInt8? {
        guard pos < end else { return nil }
        return input[pos]
    }

    @discardableResult
    func advance() -> UInt8? {
        guard pos < end else { return nil }
        let ch = input[pos]
        pos += 1
        return ch
    }

    func skipWhitespace() {
        while pos < end {
            let ch = input[pos]
            if ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D {
                pos += 1
            } else {
                break
            }
        }
    }
}

// MARK: - JeffJSBuiltinJSON

struct JeffJSBuiltinJSON {

    // MARK: - Intrinsic Registration

    /// Registers the JSON object and its methods on the global object.
    /// Mirrors JS_AddIntrinsicJSON from QuickJS.
    static func addIntrinsic(ctx: JeffJSContext) {
        let jsonObj = ctx.newPlainObject()

        let parseFunc = ctx.newCFunction(name: "parse", length: 2) { c, this, args in
            return JeffJSBuiltinJSON.parse(ctx: c, this: this, args: args)
        }
        ctx.setPropertyStr(obj: jsonObj, name: "parse", value: parseFunc)

        let stringifyFunc = ctx.newCFunction(name: "stringify", length: 3) { c, this, args in
            return JeffJSBuiltinJSON.stringify(ctx: c, this: this, args: args)
        }
        ctx.setPropertyStr(obj: jsonObj, name: "stringify", value: stringifyFunc)

        // Set @@toStringTag to "JSON"
        ctx.setPropertyStr(obj: jsonObj, name: "@@toStringTag",
                           value: ctx.newStringValue("JSON"))

        ctx.setPropertyStr(obj: ctx.globalObject, name: "JSON", value: jsonObj)
    }

    // MARK: - JSON.parse

    /// JSON.parse(text [, reviver])
    /// Parses a JSON string and optionally transforms the result with a reviver function.
    static func parse(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        // Get the text argument as a string
        guard args.count >= 1 else {
            return ctx.throwSyntaxError("JSON.parse: unexpected end of data")
        }

        let textStr = ctx.toString(args[0])
        if textStr.isException { return textStr }

        guard let jsStr = textStr.stringValue else {
            ctx.freeValue(textStr)
            return ctx.throwSyntaxError("JSON.parse: expected string argument")
        }

        let swiftStr = jsStr.toSwiftString()
        ctx.freeValue(textStr)

        // Convert to UTF-8 bytes for parsing
        let bytes = Array(swiftStr.utf8)
        let state = JSONParseState(ctx: ctx, input: bytes, extJSON: false)

        // Parse the value
        state.skipWhitespace()
        let result = parseValue(state)
        if result.isException { return result }

        // Ensure no trailing content after the value
        state.skipWhitespace()
        if !state.isEOF {
            ctx.freeValue(result)
            return ctx.throwSyntaxError("JSON.parse: unexpected data after JSON value")
        }

        // Apply reviver if provided
        if args.count >= 2 {
            let reviver = args[1]
            if ctx.isFunction(reviver) {
                let root = ctx.newPlainObject()
                ctx.setPropertyStr(obj: root, name: "", value: result.dupValue())
                let walked = reviverWalk(ctx: ctx, reviver: reviver, holder: root,
                                         key: ctx.newStringValue(""))
                ctx.freeValue(root)
                ctx.freeValue(result)
                return walked
            }
        }

        return result
    }

    // MARK: - JSON.stringify

    /// JSON.stringify(value [, replacer [, space]])
    /// Converts a JavaScript value to a JSON string.
    static func stringify(ctx: JeffJSContext, this: JeffJSValue, args: [JeffJSValue]) -> JeffJSValue {
        guard args.count >= 1 else {
            return JeffJSValue.undefined
        }

        var sCtx = StringifyContext(ctx: ctx)

        // Process the replacer argument (args[1])
        if args.count >= 2 {
            let replacer = args[1]
            if ctx.isFunction(replacer) {
                sCtx.replacerFunc = replacer.dupValue()
            } else if ctx.isArray(replacer) {
                // Build the property list from the array replacer
                var propertyList: [String] = []
                var seen = Set<String>()
                let len = ctx.getPropertyLength(replacer)
                for i in 0..<len {
                    let item = ctx.getPropertyUInt32(obj: replacer, index: UInt32(i))
                    var key: String? = nil

                    if item.isString {
                        if let s = item.stringValue {
                            key = s.toSwiftString()
                        }
                    } else if item.isNumber {
                        let numStr = ctx.toString(item)
                        if let s = numStr.stringValue {
                            key = s.toSwiftString()
                        }
                        ctx.freeValue(numStr)
                    } else if item.isObject {
                        let classID = ctx.getObjectClassID(item)
                        if classID == JeffJSClassID.string.rawValue ||
                           classID == JeffJSClassID.number.rawValue {
                            let str = ctx.toString(item)
                            if let s = str.stringValue {
                                key = s.toSwiftString()
                            }
                            ctx.freeValue(str)
                        }
                    }

                    if let k = key, !seen.contains(k) {
                        seen.insert(k)
                        propertyList.append(k)
                    }
                    ctx.freeValue(item)
                }
                sCtx.propertyList = propertyList
            }
        }

        // Process the space argument (args[2])
        if args.count >= 3 {
            var spaceArg = args[2]

            // Unwrap Number/String wrapper objects
            if spaceArg.isObject {
                let classID = ctx.getObjectClassID(spaceArg)
                if classID == JeffJSClassID.number.rawValue {
                    let converted = ctx.toNumber(spaceArg)
                    if !converted.isException {
                        spaceArg = converted
                    }
                } else if classID == JeffJSClassID.string.rawValue {
                    let converted = ctx.toString(spaceArg)
                    if !converted.isException {
                        spaceArg = converted
                    }
                }
            }

            if spaceArg.isNumber {
                let n = Int(spaceArg.toNumber())
                let count = max(0, min(n, 10))
                if count > 0 {
                    sCtx.gap = String(repeating: " ", count: count)
                }
            } else if spaceArg.isString {
                if let s = spaceArg.stringValue {
                    let str = s.toSwiftString()
                    if str.count > 10 {
                        sCtx.gap = String(str.prefix(10))
                    } else {
                        sCtx.gap = str
                    }
                }
            }
        }

        let value = args[0]

        // Create a wrapper object: {"": value}
        let wrapper = ctx.newPlainObject()
        ctx.setPropertyStr(obj: wrapper, name: "", value: value.dupValue())

        let result = stringifyValue(&sCtx, holder: wrapper, key: "")

        ctx.freeValue(wrapper)

        // Clean up replacer
        if let rf = sCtx.replacerFunc {
            ctx.freeValue(rf)
        }

        switch result {
        case .undefined:
            return JeffJSValue.undefined
        case .value(let str):
            return ctx.newStringValue(str)
        case .exception:
            return JeffJSValue.exception
        }
    }

    // MARK: - JSON Parse Internals

    /// Recursive descent parser entry point.
    /// Dispatches on the next token to parse a JSON value.
    private static func parseValue(_ state: JSONParseState) -> JeffJSValue {
        state.skipWhitespace()

        guard let ch = state.peek() else {
            return state.ctx.throwSyntaxError("JSON.parse: unexpected end of data")
        }

        switch ch {
        case 0x22: // "
            return parseString(state)
        case 0x7B: // {
            return parseObject(state)
        case 0x5B: // [
            return parseArray(state)
        case 0x74: // t
            return parseLiteral(state, expected: "true", value: JeffJSValue.JS_TRUE)
        case 0x66: // f
            return parseLiteral(state, expected: "false", value: JeffJSValue.JS_FALSE)
        case 0x6E: // n
            return parseLiteral(state, expected: "null", value: JeffJSValue.null)
        case 0x2D, 0x30...0x39: // - or 0-9
            return parseNumber(state)
        default:
            return state.ctx.throwSyntaxError(
                "JSON.parse: unexpected character '\(Character(UnicodeScalar(ch)))'")
        }
    }

    /// Parse a JSON string with full escape sequence support.
    /// Handles: \n, \t, \r, \b, \f, \\, \", \/, \uXXXX (including surrogate pairs).
    private static func parseString(_ state: JSONParseState) -> JeffJSValue {
        guard state.advance() == 0x22 else { // opening "
            return state.ctx.throwSyntaxError("JSON.parse: expected '\"'")
        }

        var result: [UInt16] = []

        while !state.isEOF {
            guard let ch = state.advance() else {
                return state.ctx.throwSyntaxError("JSON.parse: unterminated string")
            }

            if ch == 0x22 { // closing "
                // Convert UTF-16 to Swift String
                let str = String(utf16CodeUnits: result, count: result.count)
                return state.ctx.newStringValue(str)
            }

            if ch == 0x5C { // backslash
                guard let esc = state.advance() else {
                    return state.ctx.throwSyntaxError("JSON.parse: unterminated escape")
                }
                switch esc {
                case 0x22: result.append(0x22)       // \"
                case 0x5C: result.append(0x5C)       // \\
                case 0x2F: result.append(0x2F)       // \/
                case 0x62: result.append(0x08)       // \b
                case 0x66: result.append(0x0C)       // \f
                case 0x6E: result.append(0x0A)       // \n
                case 0x72: result.append(0x0D)       // \r
                case 0x74: result.append(0x09)       // \t
                case 0x75:                           // \uXXXX
                    guard let codeUnit = parseHex4(state) else {
                        return state.ctx.throwSyntaxError(
                            "JSON.parse: invalid unicode escape")
                    }
                    // Check for surrogate pair
                    if codeUnit >= 0xD800 && codeUnit <= 0xDBFF {
                        // High surrogate - expect \uXXXX low surrogate
                        if state.pos + 1 < state.end &&
                           state.input[state.pos] == 0x5C &&
                           state.input[state.pos + 1] == 0x75 {
                            state.pos += 2 // skip \u
                            guard let lowSurrogate = parseHex4(state) else {
                                return state.ctx.throwSyntaxError(
                                    "JSON.parse: invalid unicode escape in surrogate pair")
                            }
                            if lowSurrogate >= 0xDC00 && lowSurrogate <= 0xDFFF {
                                result.append(codeUnit)
                                result.append(lowSurrogate)
                            } else {
                                // Not a valid low surrogate - emit high as-is, then the next
                                result.append(codeUnit)
                                result.append(lowSurrogate)
                            }
                        } else {
                            // Lone high surrogate
                            result.append(codeUnit)
                        }
                    } else {
                        result.append(codeUnit)
                    }
                default:
                    return state.ctx.throwSyntaxError(
                        "JSON.parse: invalid escape character '\\%c'")
                }
            } else if ch < 0x20 {
                // Control characters are not allowed in JSON strings
                return state.ctx.throwSyntaxError(
                    "JSON.parse: control character in string")
            } else {
                // Regular character - may be multi-byte UTF-8
                if ch < 0x80 {
                    result.append(UInt16(ch))
                } else if ch < 0xC0 {
                    // Unexpected continuation byte
                    result.append(UInt16(ch))
                } else if ch < 0xE0 {
                    // 2-byte sequence
                    guard let b2 = state.advance() else {
                        return state.ctx.throwSyntaxError("JSON.parse: invalid UTF-8")
                    }
                    let cp = (UInt32(ch & 0x1F) << 6) | UInt32(b2 & 0x3F)
                    result.append(UInt16(cp))
                } else if ch < 0xF0 {
                    // 3-byte sequence
                    guard let b2 = state.advance(), let b3 = state.advance() else {
                        return state.ctx.throwSyntaxError("JSON.parse: invalid UTF-8")
                    }
                    let cp = (UInt32(ch & 0x0F) << 12) |
                             (UInt32(b2 & 0x3F) << 6) |
                             UInt32(b3 & 0x3F)
                    result.append(UInt16(cp))
                } else {
                    // 4-byte sequence (supplementary plane -> surrogate pair)
                    guard let b2 = state.advance(),
                          let b3 = state.advance(),
                          let b4 = state.advance() else {
                        return state.ctx.throwSyntaxError("JSON.parse: invalid UTF-8")
                    }
                    let cp = (UInt32(ch & 0x07) << 18) |
                             (UInt32(b2 & 0x3F) << 12) |
                             (UInt32(b3 & 0x3F) << 6) |
                             UInt32(b4 & 0x3F)
                    let hi = UInt16(0xD800 + ((cp - 0x10000) >> 10))
                    let lo = UInt16(0xDC00 + ((cp - 0x10000) & 0x3FF))
                    result.append(hi)
                    result.append(lo)
                }
            }
        }

        return state.ctx.throwSyntaxError("JSON.parse: unterminated string")
    }

    /// Parse 4 hex digits for \uXXXX escape.
    private static func parseHex4(_ state: JSONParseState) -> UInt16? {
        var value: UInt16 = 0
        for _ in 0..<4 {
            guard let ch = state.advance() else { return nil }
            value <<= 4
            switch ch {
            case 0x30...0x39: value |= UInt16(ch - 0x30)
            case 0x41...0x46: value |= UInt16(ch - 0x41 + 10)
            case 0x61...0x66: value |= UInt16(ch - 0x61 + 10)
            default: return nil
            }
        }
        return value
    }

    /// Parse a JSON number.
    private static func parseNumber(_ state: JSONParseState) -> JeffJSValue {
        let startPos = state.pos
        var hasDecimal = false
        var hasExponent = false

        // Optional leading minus
        if state.peek() == 0x2D { state.advance() }

        // Integer part
        guard let firstDigit = state.peek(), firstDigit >= 0x30 && firstDigit <= 0x39 else {
            return state.ctx.throwSyntaxError("JSON.parse: expected digit")
        }

        if firstDigit == 0x30 {
            state.advance()
            // After leading 0, must not have another digit
            if let next = state.peek(), next >= 0x30 && next <= 0x39 {
                return state.ctx.throwSyntaxError("JSON.parse: leading zeros not allowed")
            }
        } else {
            while let ch = state.peek(), ch >= 0x30 && ch <= 0x39 {
                state.advance()
            }
        }

        // Fractional part
        if state.peek() == 0x2E { // .
            hasDecimal = true
            state.advance()
            guard let d = state.peek(), d >= 0x30 && d <= 0x39 else {
                return state.ctx.throwSyntaxError("JSON.parse: expected digit after decimal point")
            }
            while let ch = state.peek(), ch >= 0x30 && ch <= 0x39 {
                state.advance()
            }
        }

        // Exponent part
        if let ch = state.peek(), ch == 0x65 || ch == 0x45 { // e or E
            hasExponent = true
            state.advance()
            if let s = state.peek(), s == 0x2B || s == 0x2D { // + or -
                state.advance()
            }
            guard let d = state.peek(), d >= 0x30 && d <= 0x39 else {
                return state.ctx.throwSyntaxError("JSON.parse: expected digit in exponent")
            }
            while let ch = state.peek(), ch >= 0x30 && ch <= 0x39 {
                state.advance()
            }
        }

        let numBytes = Array(state.input[startPos..<state.pos])
        guard let numStr = String(bytes: numBytes, encoding: .utf8),
              let value = Double(numStr) else {
            return state.ctx.throwSyntaxError("JSON.parse: invalid number")
        }

        // If the number has no decimal or exponent and fits in Int32, use int
        if !hasDecimal && !hasExponent {
            if value >= Double(Int32.min) && value <= Double(Int32.max) && value == value.rounded(.towardZero) {
                return JeffJSValue.newInt32(Int32(value))
            }
        }

        return JeffJSValue.newFloat64(value)
    }

    /// Parse a JSON object: { key: value, ... }
    private static func parseObject(_ state: JSONParseState) -> JeffJSValue {
        state.advance() // consume {
        state.skipWhitespace()

        let obj = state.ctx.newPlainObject()

        if state.peek() == 0x7D { // }
            state.advance()
            return obj
        }

        while true {
            state.skipWhitespace()

            // Key must be a string
            guard state.peek() == 0x22 else {
                state.ctx.freeValue(obj)
                return state.ctx.throwSyntaxError("JSON.parse: expected property name")
            }

            let keyVal = parseString(state)
            if keyVal.isException {
                state.ctx.freeValue(obj)
                return keyVal
            }

            guard let keyStr = keyVal.stringValue else {
                state.ctx.freeValue(obj)
                state.ctx.freeValue(keyVal)
                return state.ctx.throwSyntaxError("JSON.parse: invalid property name")
            }
            let key = keyStr.toSwiftString()
            state.ctx.freeValue(keyVal)

            // Expect colon
            state.skipWhitespace()
            guard state.advance() == 0x3A else { // :
                state.ctx.freeValue(obj)
                return state.ctx.throwSyntaxError("JSON.parse: expected ':'")
            }

            // Parse value
            state.skipWhitespace()
            let value = parseValue(state)
            if value.isException {
                state.ctx.freeValue(obj)
                return value
            }

            // Set property on the object
            state.ctx.setPropertyStr(obj: obj, name: key, value: value)

            state.skipWhitespace()
            guard let sep = state.peek() else {
                state.ctx.freeValue(obj)
                return state.ctx.throwSyntaxError("JSON.parse: unexpected end of data in object")
            }

            if sep == 0x7D { // }
                state.advance()
                return obj
            }

            if sep == 0x2C { // ,
                state.advance()
                continue
            }

            state.ctx.freeValue(obj)
            return state.ctx.throwSyntaxError("JSON.parse: expected ',' or '}' in object")
        }
    }

    /// Parse a JSON array: [ value, ... ]
    private static func parseArray(_ state: JSONParseState) -> JeffJSValue {
        state.advance() // consume [
        state.skipWhitespace()

        let arr = state.ctx.newArray()

        if state.peek() == 0x5D { // ]
            state.advance()
            return arr
        }

        var index: UInt32 = 0
        while true {
            state.skipWhitespace()

            let value = parseValue(state)
            if value.isException {
                state.ctx.freeValue(arr)
                return value
            }

            state.ctx.setPropertyUInt32(obj: arr, index: index, value: value)
            index += 1

            state.skipWhitespace()
            guard let sep = state.peek() else {
                state.ctx.freeValue(arr)
                return state.ctx.throwSyntaxError("JSON.parse: unexpected end of data in array")
            }

            if sep == 0x5D { // ]
                state.advance()
                // Update the array length so that getPropertyLength and
                // JSON.stringify see the correct element count.
                state.ctx.setArrayLength(arr, Int64(index))
                return arr
            }

            if sep == 0x2C { // ,
                state.advance()
                continue
            }

            state.ctx.freeValue(arr)
            return state.ctx.throwSyntaxError("JSON.parse: expected ',' or ']' in array")
        }
    }

    /// Parse a literal token (true, false, null).
    private static func parseLiteral(_ state: JSONParseState, expected: String,
                                      value: JeffJSValue) -> JeffJSValue {
        let bytes = Array(expected.utf8)
        for byte in bytes {
            guard state.advance() == byte else {
                return state.ctx.throwSyntaxError(
                    "JSON.parse: unexpected token near '\(expected)'")
            }
        }
        return value
    }

    // MARK: - Reviver Walk

    /// Recursively walk the parsed structure calling the reviver function.
    /// Processes depth-first: children before parents.
    /// If reviver returns undefined, the property is deleted.
    private static func reviverWalk(ctx: JeffJSContext, reviver: JeffJSValue,
                                     holder: JeffJSValue, key: JeffJSValue) -> JeffJSValue {
        let val = ctx.getProperty(obj: holder, key: key)
        if val.isException { return val }

        if val.isObject {
            if ctx.isArray(val) {
                let len = ctx.getPropertyLength(val)
                var i: UInt32 = 0
                while i < UInt32(len) {
                    let childKey = ctx.newStringValue(String(i))
                    let newElement = reviverWalk(ctx: ctx, reviver: reviver,
                                                 holder: val, key: childKey)
                    if newElement.isException {
                        ctx.freeValue(childKey)
                        ctx.freeValue(val)
                        return newElement
                    }
                    if newElement.isUndefined {
                        ctx.deletePropertyStr(obj: val, name: String(i))
                    } else {
                        ctx.setPropertyStr(obj: val, name: String(i), value: newElement)
                    }
                    ctx.freeValue(childKey)
                    i += 1
                }
            } else {
                let keys = ctx.getOwnPropertyNames(obj: val)
                for keyName in keys {
                    let childKey = ctx.newStringValue(keyName)
                    let newElement = reviverWalk(ctx: ctx, reviver: reviver,
                                                 holder: val, key: childKey)
                    if newElement.isException {
                        ctx.freeValue(childKey)
                        ctx.freeValue(val)
                        return newElement
                    }
                    if newElement.isUndefined {
                        ctx.deletePropertyStr(obj: val, name: keyName)
                    } else {
                        ctx.setPropertyStr(obj: val, name: keyName, value: newElement)
                    }
                    ctx.freeValue(childKey)
                }
            }
        }

        // Call reviver(key, val) with holder as this
        let result = ctx.callFunction(func_: reviver, this: holder, args: [key, val])
        ctx.freeValue(val)
        return result
    }

    // MARK: - JSON Stringify Internals

    /// Result type for stringify operations (avoids mixing undefined with exceptions).
    private enum StringifyResult {
        case value(String)
        case undefined
        case exception
    }

    /// Internal context for JSON.stringify serialization.
    /// Mirrors QuickJS JObjRec / StringifyState.
    private struct StringifyContext {
        let ctx: JeffJSContext
        var replacerFunc: JeffJSValue? = nil
        var propertyList: [String]? = nil
        var stack: [JeffJSValue] = []       // Circular reference detection
        var gap: String = ""                // Indentation string (up to 10 chars)
        var indent: String = ""             // Current indentation level
    }

    /// Main stringify dispatch. Processes a single holder[key] pair.
    private static func stringifyValue(_ sCtx: inout StringifyContext,
                                        holder: JeffJSValue,
                                        key: String) -> StringifyResult {
        let ctx = sCtx.ctx

        // Step 1: Get the value
        // For array holders, numeric string keys need to go through
        // getPropertyUInt32 to reach the fast-array payload, because
        // getPropertyStr uses a string atom that won't match the
        // tagged-int atoms used to store array elements.
        var value: JeffJSValue
        if ctx.isArray(holder), let idx = UInt32(key), String(idx) == key {
            value = ctx.getPropertyUInt32(obj: holder, index: idx)
        } else {
            value = ctx.getPropertyStr(obj: holder, name: key)
        }
        if value.isException { return .exception }

        // Step 2: Call toJSON() if available
        if value.isObject {
            let toJSONFunc = ctx.getPropertyStr(obj: value, name: "toJSON")
            if ctx.isFunction(toJSONFunc) {
                let keyArg = ctx.newStringValue(key)
                let transformed = ctx.callFunction(func_: toJSONFunc, this: value, args: [keyArg])
                ctx.freeValue(keyArg)
                ctx.freeValue(value)
                value = transformed
                if value.isException {
                    ctx.freeValue(toJSONFunc)
                    return .exception
                }
            }
            ctx.freeValue(toJSONFunc)
        }

        // Step 3: Apply replacer function if present
        if let replacerFunc = sCtx.replacerFunc {
            let keyArg = ctx.newStringValue(key)
            let transformed = ctx.callFunction(func_: replacerFunc, this: holder, args: [keyArg, value])
            ctx.freeValue(keyArg)
            ctx.freeValue(value)
            value = transformed
            if value.isException { return .exception }
        }

        // Step 4: Unwrap wrapper objects (Number, String, Boolean, BigInt)
        if value.isObject {
            let classID = ctx.getObjectClassID(value)
            if classID == JeffJSClassID.number.rawValue {
                let unwrapped = ctx.toNumber(value)
                ctx.freeValue(value)
                value = unwrapped
                if value.isException { return .exception }
            } else if classID == JeffJSClassID.string.rawValue {
                let unwrapped = ctx.toString(value)
                ctx.freeValue(value)
                value = unwrapped
                if value.isException { return .exception }
            } else if classID == JeffJSClassID.boolean.rawValue {
                let unwrapped = ctx.getObjectData(value)
                ctx.freeValue(value)
                value = unwrapped
            }
        }

        // Step 5: Produce the serialized form based on the type

        // undefined, function, or symbol -> undefined (omit in objects, "null" in arrays)
        if value.isUndefined || ctx.isFunction(value) || value.isSymbol {
            ctx.freeValue(value)
            return .undefined
        }

        // null
        if value.isNull {
            ctx.freeValue(value)
            return .value("null")
        }

        // boolean
        if value.isBool {
            let b = value.toBool()
            ctx.freeValue(value)
            return .value(b ? "true" : "false")
        }

        // number
        if value.isNumber {
            let num = value.toNumber()
            ctx.freeValue(value)
            if num.isInfinite || num.isNaN {
                return .value("null")
            }
            return .value(formatNumber(num))
        }

        // BigInt -> throw TypeError
        if value.isBigInt {
            ctx.freeValue(value)
            _ = ctx.throwTypeError("Do not know how to serialize a BigInt")
            return .exception
        }

        // string
        if value.isString {
            guard let jsStr = value.stringValue else {
                ctx.freeValue(value)
                return .value("\"\"")
            }
            let quoted = quoteJSONString(jsStr.toSwiftString())
            ctx.freeValue(value)
            return .value(quoted)
        }

        // object (array or plain object)
        if value.isObject {
            // Circular reference check
            for stackItem in sCtx.stack {
                if ctx.strictEqual(stackItem, value) {
                    ctx.freeValue(value)
                    _ = ctx.throwTypeError("Converting circular structure to JSON")
                    return .exception
                }
            }

            sCtx.stack.append(value)

            let result: StringifyResult
            if ctx.isArray(value) {
                result = stringifyArray(&sCtx, array: value)
            } else {
                result = stringifyObject(&sCtx, object: value)
            }

            sCtx.stack.removeLast()
            ctx.freeValue(value)
            return result
        }

        ctx.freeValue(value)
        return .undefined
    }

    /// Serialize an array value.
    private static func stringifyArray(_ sCtx: inout StringifyContext,
                                        array: JeffJSValue) -> StringifyResult {
        let ctx = sCtx.ctx
        let len = ctx.getPropertyLength(array)

        if len == 0 {
            return .value("[]")
        }

        var output = "["
        let hasGap = !sCtx.gap.isEmpty
        let previousIndent = sCtx.indent

        if hasGap {
            sCtx.indent += sCtx.gap
        }

        for i in 0..<len {
            if i > 0 {
                output += ","
            }

            if hasGap {
                output += "\n" + sCtx.indent
            }

            let key = String(i)
            // We need a holder that has this index as a property.
            // The array itself is the holder.
            let result = stringifyValue(&sCtx, holder: array, key: key)
            switch result {
            case .value(let str):
                output += str
            case .undefined:
                output += "null"
            case .exception:
                return .exception
            }
        }

        sCtx.indent = previousIndent

        if hasGap {
            output += "\n" + sCtx.indent
        }
        output += "]"

        return .value(output)
    }

    /// Serialize an object value.
    private static func stringifyObject(_ sCtx: inout StringifyContext,
                                         object: JeffJSValue) -> StringifyResult {
        let ctx = sCtx.ctx

        // Determine the keys to iterate
        let keys: [String]
        if let propertyList = sCtx.propertyList {
            keys = propertyList
        } else {
            keys = ctx.getOwnPropertyNames(obj: object)
        }

        var output = "{"
        let hasGap = !sCtx.gap.isEmpty
        let previousIndent = sCtx.indent
        var first = true

        if hasGap {
            sCtx.indent += sCtx.gap
        }

        for key in keys {
            let result = stringifyValue(&sCtx, holder: object, key: key)
            switch result {
            case .value(let valueStr):
                if !first {
                    output += ","
                }
                if hasGap {
                    output += "\n" + sCtx.indent
                }
                output += quoteJSONString(key)
                output += hasGap ? ": " : ":"
                output += valueStr
                first = false
            case .undefined:
                // Omit undefined values in objects
                continue
            case .exception:
                sCtx.indent = previousIndent
                return .exception
            }
        }

        sCtx.indent = previousIndent

        if !first && hasGap {
            output += "\n" + sCtx.indent
        }
        output += "}"

        return .value(output)
    }

    // MARK: - String Quoting

    /// Quote a string for JSON output with proper escape sequences.
    /// Escapes: \t, \r, \n, \b, \f, \\, \", control chars < 0x20,
    /// and lone surrogates as \uXXXX.
    private static func quoteJSONString(_ str: String) -> String {
        var result = "\""
        for scalar in str.unicodeScalars {
            let cp = scalar.value
            switch cp {
            case 0x22: result += "\\\""      // "
            case 0x5C: result += "\\\\"      // \
            case 0x08: result += "\\b"       // backspace
            case 0x0C: result += "\\f"       // form feed
            case 0x0A: result += "\\n"       // newline
            case 0x0D: result += "\\r"       // carriage return
            case 0x09: result += "\\t"       // tab
            default:
                if cp < 0x20 {
                    // Control character -> \u00XX
                    result += String(format: "\\u%04x", cp)
                } else if cp >= 0xD800 && cp <= 0xDFFF {
                    // Lone surrogate -> \uXXXX
                    result += String(format: "\\u%04x", cp)
                } else {
                    result += String(scalar)
                }
            }
        }
        result += "\""
        return result
    }

    /// Format a number for JSON output.
    /// Matches QuickJS behavior: integers print without decimal, doubles use
    /// the shortest representation.
    private static func formatNumber(_ num: Double) -> String {
        if num == 0 {
            // Handle -0 -> "0"
            return "0"
        }
        if num == num.rounded(.towardZero) && !num.isInfinite && abs(num) < 1e20 {
            // Integer-valued doubles get no decimal point
            if num >= Double(Int64.min) && num <= Double(Int64.max) {
                return String(Int64(num))
            }
        }
        // Use Swift's default Double-to-String, which produces the shortest
        // representation that round-trips (matches the spec requirement).
        var s = String(num)
        // Remove trailing ".0" for integer-valued doubles not caught above
        if s.hasSuffix(".0") {
            s = String(s.dropLast(2))
        }
        return s
    }
}

// MARK: - Context Helper Extensions for JSON

/// These extensions provide the high-level operations that JeffJSBuiltinJSON
/// needs from the context. They call through to the underlying runtime/context
/// infrastructure. Methods that don't yet exist on the real JeffJSContext are
/// defined here as stubs that will be wired up when the full context is
/// implemented.
extension JeffJSContext {

    // MARK: - Value Creation

    func json_newStringValue(_ str: String) -> JeffJSValue {
        let jsStr = JeffJSString(swiftString: str)
        return JeffJSValue.mkPtr(tag: .string, ptr: jsStr)
    }

    func newPlainObject() -> JeffJSValue {
        return newObjectClass(classID: JeffJSClassID.object.rawValue)
    }

    func json_newArray() -> JeffJSValue {
        let obj = JeffJSObject()
        obj.classID = JeffJSClassID.array.rawValue
        obj.payload = .array(size: 0, values: [], count: 0)
        return JeffJSValue.mkPtr(tag: .object, ptr: obj)
    }

    func newCFunction(name: String, length: Int,
                      body: @escaping (JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue) -> JeffJSValue {
        // Delegate to the canonical newCFunction in JeffJSContext which properly
        // sets up the shape, Function.prototype, and name/length properties.
        // Without these, setPropertyStr silently fails (no shape = no property storage).
        return newCFunction(body, name: name, length: length)
    }

    // MARK: - Property Access

    // setPropertyStr removed -- use the canonical definition in JeffJSContext.swift

    func json_getPropertyStr(obj: JeffJSValue, name: String) -> JeffJSValue {
        guard let jsObj = obj.toObject() else { return .undefined }
        let atom = rt.findAtom(name)
        let val = jsObj.getOwnPropertyValue(atom: atom)
        rt.freeAtom(atom)
        return val
    }

    func getProperty(obj: JeffJSValue, key: JeffJSValue) -> JeffJSValue {
        if key.isString, let keyStr = key.stringValue {
            return getPropertyStr(obj: obj, name: keyStr.toSwiftString())
        }
        if key.isInt {
            return getPropertyUInt32(obj: obj, index: UInt32(key.toInt32()))
        }
        return .undefined
    }

    func setProperty(obj: JeffJSValue, key: JeffJSValue, value: JeffJSValue) -> Int32 {
        if key.isString, let keyStr = key.stringValue {
            return setPropertyStr(obj: obj, name: keyStr.toSwiftString(), value: value) ? 0 : -1
        }
        if key.isInt {
            return Int32(setPropertyUint32(obj: obj, index: UInt32(key.toInt32()), value: value))
        }
        return -1
    }

    func getPropertyUInt32(obj: JeffJSValue, index: UInt32) -> JeffJSValue {
        guard let jsObj = obj.toObject() else { return .undefined }
        if case .array(_, let vals, let count) = jsObj.payload {
            if index < count && Int(index) < vals.count {
                return vals[Int(index)]
            }
        }
        // Fall back to string-keyed lookup
        return getPropertyStr(obj: obj, name: String(index))
    }

    func setPropertyUInt32(obj: JeffJSValue, index: UInt32, value: JeffJSValue) {
        // Delegate to the canonical setPropertyUint32 which uses tagged-int
        // atoms, ensuring that elements stored here are found by bytecode
        // property access (get_array_el) which also uses tagged-int atoms.
        _ = setPropertyUint32(obj: obj, index: index, value: value)
    }

    func deletePropertyStr(obj: JeffJSValue, name: String) {
        guard let jsObj = obj.toObject() else { return }
        let atom = rt.findAtom(name)
        jeffJS_deleteProperty(ctx: self, obj: jsObj, atom: atom)
        rt.freeAtom(atom)
    }

    func getPropertyLength(_ obj: JeffJSValue) -> Int {
        let lenVal = getPropertyStr(obj: obj, name: "length")
        if lenVal.isInt {
            return Int(lenVal.toInt32())
        }
        if lenVal.isFloat64 {
            let d = lenVal.toFloat64()
            if d.isNaN || d.isInfinite || d < 0 { return 0 }
            return d > Double(Int.max / 2) ? 0 : Int(d)
        }
        // For arrays, try the count from the payload
        if let jsObj = obj.toObject() {
            return Int(jsObj.arrayCount)
        }
        return 0
    }

    func getOwnPropertyNames(obj: JeffJSValue) -> [String] {
        guard let jsObj = obj.toObject(), let shape = jsObj.shape else { return [] }
        // Per ES spec §9.1.12: integer indices first (ascending), then string keys (insertion order).
        var intKeys: [(UInt32, String)] = []
        var stringKeys: [String] = []
        for prop in shape.prop {
            if prop.flags.contains(.enumerable) {
                let atom = prop.atom
                if atom == 0 { continue }
                if rt.atomIsArrayIndex(atom) {
                    if let idx = rt.atomToUInt32(atom) {
                        intKeys.append((idx, String(idx)))
                    }
                } else if let name = rt.atomToString(atom) {
                    stringKeys.append(name)
                }
            }
        }
        intKeys.sort { $0.0 < $1.0 }
        var names: [String] = []
        names.reserveCapacity(intKeys.count + stringKeys.count)
        for (_, name) in intKeys { names.append(name) }
        names.append(contentsOf: stringKeys)
        return names
    }

    func getObjectClassID(_ val: JeffJSValue) -> Int {
        guard let obj = val.toObject() else { return 0 }
        return obj.classID
    }

    func getObjectData(_ val: JeffJSValue) -> JeffJSValue {
        guard let obj = val.toObject() else { return .undefined }
        if case .objectData(let data) = obj.payload { return data }
        return .undefined
    }

    // MARK: - Type Conversions

    func json_toString(_ val: JeffJSValue) -> JeffJSValue {
        if val.isString { return val.dupValue() }
        if val.isInt { return json_newStringValue(String(val.toInt32())) }
        if val.isFloat64 {
            let d = val.toFloat64()
            if d.isNaN { return json_newStringValue("NaN") }
            if d.isInfinite { return json_newStringValue(d > 0 ? "Infinity" : "-Infinity") }
            return json_newStringValue(String(d))
        }
        if val.isBool { return json_newStringValue(val.toBool() ? "true" : "false") }
        if val.isNull { return json_newStringValue("null") }
        if val.isUndefined { return json_newStringValue("undefined") }
        return json_newStringValue("")
    }

    func toNumber(_ val: JeffJSValue) -> JeffJSValue {
        if val.isInt || val.isFloat64 { return val }
        if val.isBool { return JeffJSValue.newInt32(val.toBool() ? 1 : 0) }
        if val.isNull { return JeffJSValue.newInt32(0) }
        if val.isUndefined { return JeffJSValue.newFloat64(Double.nan) }
        if val.isString, let s = val.stringValue {
            let str = s.toSwiftString().trimmingCharacters(in: .whitespaces)
            if str.isEmpty { return JeffJSValue.newInt32(0) }
            if let d = Double(str) { return JeffJSValue.newFloat64(d) }
            return JeffJSValue.newFloat64(Double.nan)
        }
        if val.isObject {
            let data = getObjectData(val)
            return toNumber(data)
        }
        return JeffJSValue.newFloat64(Double.nan)
    }

    // MARK: - Function Calls

    func callFunction(func_: JeffJSValue, this: JeffJSValue,
                      args: [JeffJSValue]) -> JeffJSValue {
        // Delegate to the canonical callFunction which handles C functions,
        // bytecode functions, bound functions, generators, etc.
        return callFunction(func_, thisVal: this, args: args)
    }

    // MARK: - Type Checks

    func isFunction(_ val: JeffJSValue) -> Bool {
        guard let obj = val.toObject() else { return false }
        return obj.isCallable
    }

    func isArray(_ val: JeffJSValue) -> Bool {
        guard let obj = val.toObject() else { return false }
        return obj.isArray
    }

    func strictEqual(_ a: JeffJSValue, _ b: JeffJSValue) -> Bool {
        if !JeffJSValue.sameTag(a, b) { return false }
        if a.isObject && b.isObject {
            return a.toObject() === b.toObject()
        }
        return a == b
    }

    // MARK: - Value Lifecycle

    func freeValue(_ val: JeffJSValue) {
        val.freeValue()
    }

    // MARK: - Error Throwing

    func throwSyntaxError(_ msg: String) -> JeffJSValue {
        rt.currentException = newStringValue(msg)
        return .exception
    }

    func throwTypeError(_ msg: String) -> JeffJSValue {
        rt.currentException = newStringValue(msg)
        return .exception
    }

    func throwRangeError(_ msg: String) -> JeffJSValue {
        rt.currentException = newStringValue(msg)
        return .exception
    }

    // MARK: - Global Object

    var globalObject: JeffJSValue {
        return globalObj
    }
}
