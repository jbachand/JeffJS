import Foundation

// MARK: - JavaScriptCore-compatible runtime error text
//
// Pages read the text of the errors the engine raises: `e.message`, and
// `e.stack`, and some fingerprint it. Google's anti-abuse challenge
// (the "knitsail" VM on /search interstitials) provokes a TypeError on
// purpose and folds `message + ":" + stack` into the token Google checks;
// with a Safari User-Agent, V8's wording ("Cannot read properties of
// undefined (reading 'x')") plus a V8-style stack marked the client as
// automated, and every search came back as /sorry (HTTP 429). JeffJS
// stands in for WebKit's engine, so its runtime errors read like
// JavaScriptCore's:
//
//   undefined is not an object (evaluating 'w.C[b]')
//   o.f is not a function. (In 'o.f(1, 2)', 'o.f' is undefined)
//   undefined is not a constructor (evaluating 'new u()')
//   Can't find variable: foo
//
// The quoted source comes from the function's expression-span table (the
// compiler's equivalent of JSC's expression info, JeffJSParser.emitExprSpan):
// the throw site records a pending "source appender" (JSC:
// ErrorInstance::m_sourceAppender) and the interpreter completes the message
// when the exception unwinds through the bytecode instruction that raised it.
// Without a span (a native caller, a table-less cached function) the message
// stays JSC's base text.

/// A runtime error whose final text quotes the source of the instruction
/// that raised it.
struct JeffJSSourceAppender {
    enum Kind { case notAnObject, notAFunction, notAConstructor }
    /// Identity of the error object the text belongs to.
    let error: ObjectIdentifier
    let kind: Kind
    /// JSC's description of the offending value (`errorDescriptionForValue`).
    let valueDescription: String
    /// For `notAFunction`: what follows "' is " in the "(In ...)" clause.
    let displayValue: String
    let baseMessage: String
}

extension JeffJSContext {

    /// JSC `errorDescriptionForValue`: strings quoted, objects by class
    /// name, symbols by their descriptive string, the rest as ToString.
    func jscValueDescription(_ v: JeffJSValue) -> String {
        if v.isUndefined { return "undefined" }
        if v.isNull { return "null" }
        if v.isString { return "\"" + (toSwiftString(v) ?? "") + "\"" }
        if v.isSymbol { return toSwiftString(v) ?? "Symbol()" }
        if v.isObject { return jscClassName(v) }
        return toSwiftString(v) ?? "\(v.tag)"
    }

    /// JSC `JSObject::calculatedClassName`: the name of the constructor its
    /// prototype chain names, "Object" when there is none. Reads plain data
    /// properties only (no getter runs while an error is being built).
    func jscClassName(_ v: JeffJSValue) -> String {
        guard let obj = v.toObject() else { return "Object" }
        let ctorAtom = JeffJSAtomID.JS_ATOM_constructor.rawValue
        let nameAtom = JeffJSAtomID.JS_ATOM_name.rawValue
        var p: JeffJSObject? = obj.proto
        var depth = 0
        while let proto = p, depth < 32 {
            let ctor = proto.getOwnPropertyValue(atom: ctorAtom)
            if let c = ctor.toObject() {
                let n = c.getOwnPropertyValue(atom: nameAtom)
                if n.isString, let s = toSwiftString(n), !s.isEmpty { return s }
                break
            }
            p = proto.proto
            depth += 1
        }
        return "Object"
    }

    private func recordSourceAppender(kind: JeffJSSourceAppender.Kind, value: JeffJSValue,
                                      description: String, displayValue: String, message: String) {
        guard let err = rt.currentException.toObject() else { return }
        pendingSourceAppender = JeffJSSourceAppender(error: ObjectIdentifier(err), kind: kind,
                                                     valueDescription: description,
                                                     displayValue: displayValue, baseMessage: message)
    }

    /// Reading or writing a property of null/undefined (JSC: "undefined is
    /// not an object", completed with "(evaluating '<source>')").
    @discardableResult
    func throwNotAnObject(_ base: JeffJSValue) -> JeffJSValue {
        let desc = base.isNull ? "null" : "undefined"
        let message = "\(desc) is not an object"
        let r = throwTypeError(message: message)
        recordSourceAppender(kind: .notAnObject, value: base, description: desc, displayValue: desc, message: message)
        return r
    }

    /// Calling a value that is not callable (JSC: "<v> is not a function",
    /// completed with ". (In '<call>', '<callee>' is <v>)").
    @discardableResult
    func throwNotAFunction(_ value: JeffJSValue) -> JeffJSValue {
        let desc = jscValueDescription(value)
        let display: String
        if value.isSymbol { display = "a Symbol" }
        else if value.isObject { display = "an instance of " + desc }
        else { display = desc }
        let message = "\(desc) is not a function"
        let r = throwTypeError(message: message)
        recordSourceAppender(kind: .notAFunction, value: value, description: desc, displayValue: display, message: message)
        return r
    }

    /// `new` on a value that is not a constructor (JSC: "<v> is not a
    /// constructor", completed with " (evaluating 'new X()')").
    @discardableResult
    func throwNotAConstructor(_ value: JeffJSValue) -> JeffJSValue {
        let desc = jscValueDescription(value)
        let message = "\(desc) is not a constructor"
        let r = throwTypeError(message: message)
        recordSourceAppender(kind: .notAConstructor, value: value, description: desc, displayValue: desc, message: message)
        return r
    }

    /// Called by the interpreter when an exception starts unwinding at `pc`
    /// of `fb`: completes a pending appender's message when the exception is
    /// that error and the instruction at `pc` is the kind that raised it
    /// (an error thrown inside a native callee does not match its caller's
    /// instruction and keeps its base text). Always consumes the pending state.
    func applyPendingSourceAppender(fb: JeffJSFunctionBytecode, bc: UnsafePointer<UInt8>, bcLen: Int, pc: Int) {
        guard let pending = pendingSourceAppender else { return }
        pendingSourceAppender = nil
        guard let err = rt.currentException.toObject(), ObjectIdentifier(err) == pending.error,
              pc >= 0, pc < bcLen else { return }
        var raw = UInt16(bc[pc])
        if raw == 0, pc + 1 < bcLen { raw = 256 + UInt16(bc[pc + 1]) }   // wide prefix
        guard let op = JeffJSOpcode(rawValue: raw) else { return }
        let name = op.debugName
        switch pending.kind {
        case .notAnObject:
            guard name.contains("get_field") || name.contains("get_array_el") || name == "get_length"
                    || name.contains("put_field") || name.contains("put_array_el") || name.hasPrefix("delete") else { return }
        case .notAFunction:
            guard (name.contains("call") || name == "apply") && !name.contains("constructor") else { return }
        case .notAConstructor:
            guard name.contains("constructor") else { return }
        }
        guard let fbc = fb as? JeffJSFunctionBytecodeCompiled,
              let text = fbc.exprSpanText(atPC: pc), !text.isEmpty else { return }
        let message: String
        switch pending.kind {
        case .notAnObject, .notAConstructor:
            message = pending.baseMessage + " (evaluating '\(text)')"
        case .notAFunction:
            if let base = JeffJSContext.functionCallBase(text) {
                message = "\(base) is not a function. (In '\(text)', '\(base)' is \(pending.displayValue))"
            } else {
                message = pending.baseMessage + " (evaluating '\(text)')"
            }
        }
        let errVal = JeffJSValue.mkPtr(tag: .object, ptr: err)
        _ = setPropertyStr(obj: errVal, name: "message", value: newStringValue(message))
    }

    /// JSC `functionCallBase`: `foo.bar` out of `foo.bar(baz)` — the text
    /// before the argument list that closes the call, scanning right to left
    /// over balanced parentheses (and `/* */` comments). nil when the text does
    /// not end in `)` or the open parenthesis is its first character.
    static func functionCallBase(_ text: String) -> String? {
        let chars = Array(text.utf16)
        let n = chars.count
        guard n >= 2, chars[n - 1] == 0x29 else { return nil }   // ')'
        var parenStack = 1
        var inComment = false
        var idx = n - 2
        while parenStack > 0 && idx > 0 {
            let c = chars[idx]
            if inComment {
                if c == 0x2A, chars[idx - 1] == 0x2F { inComment = false; idx -= 1 }   // "/*"
            } else if c == 0x28 {        // '('
                parenStack -= 1
            } else if c == 0x29 {        // ')'
                parenStack += 1
            } else if c == 0x2F, chars[idx - 1] == 0x2A {                              // "*/"
                inComment = true; idx -= 1
            }
            if parenStack > 0 { idx -= 1 }
        }
        guard parenStack == 0, idx > 0 else { return nil }
        return String(utf16CodeUnits: Array(chars[0 ..< idx]), count: idx)
    }
}
