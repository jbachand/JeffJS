// JeffJSBuiltinError.swift
// JeffJS — 1:1 Swift port of QuickJS JavaScript engine
//
// Port of the Error built-in from QuickJS including ALL 8 native error types:
// EvalError, RangeError, ReferenceError, SyntaxError, TypeError, URIError,
// InternalError, AggregateError.
//
// QuickJS source reference: quickjs.c — js_error_constructor, js_error_toString,
// js_build_backtrace, JS_ThrowError, JS_ThrowTypeError, etc.
// Copyright 2026 Jeff Bachand. All rights reserved.

import Foundation

// MARK: - JeffJSBuiltinError

/// Implements the Error built-in and all native error subtypes for JeffJS.
/// Mirrors QuickJS `js_error_class` and `js_error_constructor` from quickjs.c.
struct JeffJSBuiltinError {

    // MARK: - Native Error Type Descriptors

    /// Native error type names indexed by JSErrorEnum raw value (0..7).
    /// Matches QuickJS `js_native_error_names`.
    private static let nativeErrorNames: [String] = [
        "EvalError",       // 0 = JS_EVAL_ERROR
        "RangeError",      // 1 = JS_RANGE_ERROR
        "ReferenceError",  // 2 = JS_REFERENCE_ERROR
        "SyntaxError",     // 3 = JS_SYNTAX_ERROR
        "TypeError",       // 4 = JS_TYPE_ERROR
        "URIError",        // 5 = JS_URI_ERROR
        "InternalError",   // 6 = JS_INTERNAL_ERROR
        "AggregateError",  // 7 = JS_AGGREGATE_ERROR
    ]

    /// Atom IDs for the native error constructor names, indexed by JSErrorEnum raw value.
    private static let nativeErrorAtoms: [UInt32] = [
        JeffJSAtomID.JS_ATOM_EvalError.rawValue,
        JeffJSAtomID.JS_ATOM_RangeError.rawValue,
        JeffJSAtomID.JS_ATOM_ReferenceError.rawValue,
        JeffJSAtomID.JS_ATOM_SyntaxError.rawValue,
        JeffJSAtomID.JS_ATOM_TypeError.rawValue,
        JeffJSAtomID.JS_ATOM_URIError.rawValue,
        JeffJSAtomID.JS_ATOM_InternalError.rawValue,
        JeffJSAtomID.JS_ATOM_AggregateError.rawValue,
    ]

    // MARK: - Intrinsic Registration

    /// Registers Error, Error.prototype, and all 8 native error subtypes on the context.
    /// Mirrors the error-related portion of `JS_AddIntrinsicBaseObjects` in QuickJS.
    ///
    /// Sets up:
    /// - Error constructor (magic=-1) and Error.prototype
    /// - Error.prototype.toString
    /// - Error.prototype.message = ""
    /// - Error.prototype.name = "Error"
    /// - Error.isError (ES2024 proposal)
    /// - All 8 native error types: EvalError..AggregateError
    ///   Each gets its own constructor (magic=0..7) and prototype
    ///   with name and message properties.
    static func addIntrinsic(ctx: JeffJSContext) {
        let rt = ctx.rt

        // =====================================================================
        // Error.prototype
        // =====================================================================
        let errorProtoObj = JeffJSObject()
        errorProtoObj.classID = JeffJSClassID.error.rawValue
        errorProtoObj.extensible = true

        // Error.prototype.name = "Error"
        jeffJS_addProperty(ctx: ctx, obj: errorProtoObj,
                           atom: JeffJSAtomID.JS_ATOM_name.rawValue,
                           flags: [.writable, .configurable])
        errorProtoObj.setOwnPropertyValue(
            atom: JeffJSAtomID.JS_ATOM_name.rawValue,
            value: JeffJSValue.makeString(JeffJSString(swiftString: "Error")))

        // Error.prototype.message = ""
        jeffJS_addProperty(ctx: ctx, obj: errorProtoObj,
                           atom: JeffJSAtomID.JS_ATOM_message.rawValue,
                           flags: [.writable, .configurable])
        errorProtoObj.setOwnPropertyValue(
            atom: JeffJSAtomID.JS_ATOM_message.rawValue,
            value: JeffJSValue.makeString(JeffJSString(swiftString: "")))

        // Error.prototype.toString
        addMethod(ctx: ctx, obj: errorProtoObj,
                  name: JeffJSAtomID.JS_ATOM_toString.rawValue,
                  func: toString, length: 0)

        let errorProtoVal = JeffJSValue.makeObject(errorProtoObj)

        // =====================================================================
        // Error constructor (magic = -1 for base Error)
        // =====================================================================
        let errorCtorObj = JeffJSObject()
        errorCtorObj.classID = JeffJSClassID.cFunction.rawValue
        errorCtorObj.extensible = true
        errorCtorObj.isConstructor = true
        errorCtorObj.payload = .cFunc(
            realm: ctx,
            cFunction: .constructorOrFunc({ ctxArg, thisArg, args, isNew in
                let newTarget = isNew ? thisArg : JeffJSValue.undefined
                return errorConstructor(ctx: ctxArg, newTarget: newTarget,
                                         this: thisArg, args: args, magic: -1)
            }),
            length: 1,
            cproto: UInt8(JS_CFUNC_CONSTRUCTOR_OR_FUNC),
            magic: -1
        )

        // Error.prototype.constructor = Error
        jeffJS_addProperty(ctx: ctx, obj: errorProtoObj,
                           atom: JeffJSAtomID.JS_ATOM_constructor.rawValue,
                           flags: [.writable, .configurable])
        errorProtoObj.setOwnPropertyValue(
            atom: JeffJSAtomID.JS_ATOM_constructor.rawValue,
            value: JeffJSValue.makeObject(errorCtorObj))

        // Error.prototype on constructor
        jeffJS_addProperty(ctx: ctx, obj: errorCtorObj,
                           atom: JeffJSAtomID.JS_ATOM_prototype.rawValue,
                           flags: [])
        errorCtorObj.setOwnPropertyValue(
            atom: JeffJSAtomID.JS_ATOM_prototype.rawValue,
            value: errorProtoVal)

        // Error constructor name and length
        setNameAndLength(ctx: ctx, obj: errorCtorObj, name: "Error", length: 1)

        // Error.isError (ES2024 proposal)
        addMethod(ctx: ctx, obj: errorCtorObj,
                  name: 0, // We use a dynamic atom below
                  func: isError, length: 1,
                  nameOverride: "isError")

        // =====================================================================
        // Native Error Types (EvalError, RangeError, ..., AggregateError)
        // =====================================================================
        for i in 0..<JSErrorEnum.JS_NATIVE_ERROR_COUNT.rawValue {
            let errorName = nativeErrorNames[i]
            let nameAtom = nativeErrorAtoms[i]

            // --- NativeError.prototype ---
            // Each native error prototype inherits from Error.prototype.
            let nativeProtoObj = JeffJSObject()
            nativeProtoObj.classID = JeffJSClassID.error.rawValue
            nativeProtoObj.extensible = true
            // Set the __proto__ of the native error prototype to Error.prototype
            nativeProtoObj.proto = errorProtoObj

            // NativeError.prototype.name = errorName
            jeffJS_addProperty(ctx: ctx, obj: nativeProtoObj,
                               atom: JeffJSAtomID.JS_ATOM_name.rawValue,
                               flags: [.writable, .configurable])
            nativeProtoObj.setOwnPropertyValue(
                atom: JeffJSAtomID.JS_ATOM_name.rawValue,
                value: JeffJSValue.makeString(JeffJSString(swiftString: errorName)))

            // NativeError.prototype.message = ""
            jeffJS_addProperty(ctx: ctx, obj: nativeProtoObj,
                               atom: JeffJSAtomID.JS_ATOM_message.rawValue,
                               flags: [.writable, .configurable])
            nativeProtoObj.setOwnPropertyValue(
                atom: JeffJSAtomID.JS_ATOM_message.rawValue,
                value: JeffJSValue.makeString(JeffJSString(swiftString: "")))

            let nativeProtoVal = JeffJSValue.makeObject(nativeProtoObj)

            // --- NativeError constructor (magic = i) ---
            let magic = i
            let nativeCtorObj = JeffJSObject()
            nativeCtorObj.classID = JeffJSClassID.cFunction.rawValue
            nativeCtorObj.extensible = true
            nativeCtorObj.isConstructor = true
            nativeCtorObj.payload = .cFunc(
                realm: ctx,
                cFunction: .constructorOrFunc({ ctxArg, thisArg, args, isNew in
                    let newTarget = isNew ? thisArg : JeffJSValue.undefined
                    return errorConstructor(ctx: ctxArg, newTarget: newTarget,
                                             this: thisArg, args: args, magic: magic)
                }),
                length: i == JSErrorEnum.JS_AGGREGATE_ERROR.rawValue ? 2 : 1,
                cproto: UInt8(JS_CFUNC_CONSTRUCTOR_OR_FUNC),
                magic: Int16(magic)
            )

            // NativeError.prototype.constructor = NativeError
            jeffJS_addProperty(ctx: ctx, obj: nativeProtoObj,
                               atom: JeffJSAtomID.JS_ATOM_constructor.rawValue,
                               flags: [.writable, .configurable])
            nativeProtoObj.setOwnPropertyValue(
                atom: JeffJSAtomID.JS_ATOM_constructor.rawValue,
                value: JeffJSValue.makeObject(nativeCtorObj))

            // NativeError.prototype on constructor
            jeffJS_addProperty(ctx: ctx, obj: nativeCtorObj,
                               atom: JeffJSAtomID.JS_ATOM_prototype.rawValue,
                               flags: [])
            nativeCtorObj.setOwnPropertyValue(
                atom: JeffJSAtomID.JS_ATOM_prototype.rawValue,
                value: nativeProtoVal)

            // Set name and length on the NativeError constructor
            let ctorLength: Int32 = (i == JSErrorEnum.JS_AGGREGATE_ERROR.rawValue) ? 2 : 1
            setNameAndLength(ctx: ctx, obj: nativeCtorObj,
                             name: errorName, length: ctorLength)
        }
    }

    // MARK: - Error Constructor

    /// Error constructor — creates a new Error (or native error subtype) object.
    ///
    /// magic: -1 = base Error, 0..7 = native error types (JSErrorEnum).
    ///
    /// For base Error and most native errors:
    ///   `new Error(message)` or `new Error(message, options)`
    ///
    /// For AggregateError (magic=7):
    ///   `new AggregateError(errors, message)` or
    ///   `new AggregateError(errors, message, options)`
    ///
    /// Supports ES2022 Error.cause via the `options` parameter:
    ///   `new Error("msg", { cause: someError })`
    ///
    /// Mirrors `js_error_constructor` in QuickJS.
    static func errorConstructor(ctx: JeffJSContext, newTarget: JeffJSValue,
                                  this: JeffJSValue, args: [JeffJSValue],
                                  magic: Int) -> JeffJSValue {
        // Create the error object
        let errObj = JeffJSObject()
        errObj.classID = JeffJSClassID.error.rawValue
        errObj.extensible = true

        // Set the prototype so that `instanceof` works correctly.
        // For native error types (magic >= 0), look up the NativeError.prototype
        // from the context's nativeErrorProto array. For base Error (magic == -1),
        // use the JS_CLASS_ERROR class prototype.
        if magic >= 0 && magic < ctx.nativeErrorProto.count {
            let proto = ctx.nativeErrorProto[magic]
            if proto.isObject {
                errObj.proto = proto.toObject()
            }
        } else {
            // Base Error: look up Error.prototype via class proto
            let errorClassID = Int(JSClassID.JS_CLASS_ERROR.rawValue)
            if errorClassID < ctx.classProto.count {
                let proto = ctx.classProto[errorClassID]
                if proto.isObject {
                    errObj.proto = proto.toObject()
                }
            }
        }

        let isAggregateError = (magic == JSErrorEnum.JS_AGGREGATE_ERROR.rawValue)

        // Determine message and options argument positions
        let messageArgIdx: Int
        let optionsArgIdx: Int
        if isAggregateError {
            // AggregateError(errors, message, options)
            messageArgIdx = 1
            optionsArgIdx = 2
        } else {
            // Error(message, options)
            messageArgIdx = 0
            optionsArgIdx = 1
        }

        // Set the message property if provided and not undefined
        if messageArgIdx < args.count && !args[messageArgIdx].isUndefined {
            let messageStr = jsValueToString(ctx: ctx, val: args[messageArgIdx])
            jeffJS_addProperty(ctx: ctx, obj: errObj,
                               atom: JeffJSAtomID.JS_ATOM_message.rawValue,
                               flags: [.writable, .configurable])
            errObj.setOwnPropertyValue(
                atom: JeffJSAtomID.JS_ATOM_message.rawValue,
                value: JeffJSValue.makeString(JeffJSString(swiftString: messageStr)))
        }

        // ES2022: Handle options parameter with cause
        if optionsArgIdx < args.count {
            let optionsVal = args[optionsArgIdx]
            if optionsVal.isObject, let optionsObj = getObject(optionsVal) {
                // Check if options has a "cause" property
                let causeVal = optionsObj.getOwnPropertyValue(
                    atom: JeffJSAtomID.JS_ATOM_cause.rawValue)
                if !causeVal.isUndefined {
                    jeffJS_addProperty(ctx: ctx, obj: errObj,
                                       atom: JeffJSAtomID.JS_ATOM_cause.rawValue,
                                       flags: [.writable, .configurable])
                    errObj.setOwnPropertyValue(
                        atom: JeffJSAtomID.JS_ATOM_cause.rawValue,
                        value: causeVal)
                }
            }
        }

        // AggregateError: set the "errors" property from the first argument
        if isAggregateError && args.count >= 1 {
            let errorsIterable = args[0]
            let errorsArray = createArrayFromIterable(ctx: ctx, iterable: errorsIterable)
            jeffJS_addProperty(ctx: ctx, obj: errObj,
                               atom: JeffJSAtomID.JS_ATOM_errors.rawValue,
                               flags: [.writable, .configurable])
            errObj.setOwnPropertyValue(
                atom: JeffJSAtomID.JS_ATOM_errors.rawValue,
                value: errorsArray)
        }

        // Build the stack trace / backtrace
        let errorName: String
        if magic < 0 {
            errorName = "Error"
        } else {
            errorName = nativeErrorNames[magic]
        }
        buildBacktrace(ctx: ctx, obj: JeffJSValue.makeObject(errObj),
                       filename: errorName, lineNum: 0, flags: 0)

        return JeffJSValue.makeObject(errObj)
    }

    // MARK: - Error.prototype.toString

    /// `Error.prototype.toString()`
    ///
    /// Follows the ES2023 spec (20.5.3.4):
    /// 1. If `this` is not an object, throw TypeError.
    /// 2. Let name = this.name; if undefined, set to "Error".
    /// 3. Let msg = this.message; if undefined, set to "".
    /// 4. If name is "", return msg.
    /// 5. If msg is "", return name.
    /// 6. Return name + ": " + msg.
    ///
    /// Mirrors `js_error_toString` in QuickJS.
    static func toString(ctx: JeffJSContext, this: JeffJSValue,
                         args: [JeffJSValue]) -> JeffJSValue {
        // Step 1: this must be an object
        guard let thisObj = getObject(this) else {
            return ctx.throwTypeError("Error.prototype.toString requires an object")
        }

        // Step 2: Get name, default to "Error"
        var name = "Error"
        let nameVal = thisObj.getOwnPropertyValue(
            atom: JeffJSAtomID.JS_ATOM_name.rawValue)
        if !nameVal.isUndefined {
            name = jsValueToString(ctx: ctx, val: nameVal)
        }

        // Step 3: Get message, default to ""
        var msg = ""
        let msgVal = thisObj.getOwnPropertyValue(
            atom: JeffJSAtomID.JS_ATOM_message.rawValue)
        if !msgVal.isUndefined {
            msg = jsValueToString(ctx: ctx, val: msgVal)
        }

        // Steps 4-6
        let result: String
        if name.isEmpty {
            result = msg
        } else if msg.isEmpty {
            result = name
        } else {
            result = "\(name): \(msg)"
        }

        return JeffJSValue.makeString(JeffJSString(swiftString: result))
    }

    // MARK: - Stack Trace / Backtrace

    /// Builds a stack trace string and attaches it to the error object as
    /// the "stack" property.
    ///
    /// Mirrors `build_backtrace` in QuickJS.
    ///
    /// Walks the call stack frames from `ctx.rt.currentStackFrame` and
    /// constructs a multi-line string of the form:
    /// ```
    /// ErrorName: message
    ///     at functionName (fileName:lineNumber:columnNumber)
    ///     at functionName (fileName:lineNumber:columnNumber)
    ///     ...
    /// ```
    ///
    /// - Parameters:
    ///   - ctx: The JS context.
    ///   - obj: The error object to attach the stack to.
    ///   - filename: The filename where the error was thrown.
    ///   - lineNum: The line number where the error was thrown.
    ///   - flags: Backtrace flags (JS_BACKTRACE_FLAG_SKIP_FIRST_LEVEL).
    static func buildBacktrace(ctx: JeffJSContext, obj: JeffJSValue,
                                filename: String, lineNum: Int, flags: Int) {
        guard let errObj = getObject(obj) else { return }

        let rt = ctx.rt

        // Build the header: "ErrorName: message" or just "ErrorName"
        var stackStr = ""

        // Get the error name
        let nameVal = errObj.getOwnPropertyValue(
            atom: JeffJSAtomID.JS_ATOM_name.rawValue)
        var errorName = "Error"
        if !nameVal.isUndefined {
            if nameVal.isString, let s = nameVal.stringValue {
                errorName = s.toSwiftString()
            }
        }
        stackStr += errorName

        // Get the message
        let msgVal = errObj.getOwnPropertyValue(
            atom: JeffJSAtomID.JS_ATOM_message.rawValue)
        if !msgVal.isUndefined {
            if msgVal.isString, let s = msgVal.stringValue {
                let msgStr = s.toSwiftString()
                if !msgStr.isEmpty {
                    stackStr += ": \(msgStr)"
                }
            }
        }

        // Add the throw location
        if !filename.isEmpty {
            stackStr += "\n    at \(filename)"
            if lineNum > 0 {
                stackStr += ":\(lineNum)"
            }
        }

        // Walk the stack frames
        let skipFirst = (flags & JS_BACKTRACE_FLAG_SKIP_FIRST_LEVEL) != 0
        var frame = rt.currentStackFrame
        var frameIndex = 0

        while let sf = frame {
            if skipFirst && frameIndex == 0 {
                frame = sf.prevFrame
                frameIndex += 1
                continue
            }

            // Get function name from the stack frame's curFunc
            var funcName = "<anonymous>"
            if let funcObj = getObject(sf.curFunc) {
                let fnNameVal = funcObj.getOwnPropertyValue(
                    atom: JeffJSAtomID.JS_ATOM_name.rawValue)
                if fnNameVal.isString, let s = fnNameVal.stringValue {
                    let n = s.toSwiftString()
                    if !n.isEmpty { funcName = n }
                }

                // Try to get filename and line from bytecode
                if case .bytecodeFunc(let bc, _, _) = funcObj.payload,
                   let bc = bc {
                    let fn = bc.fileName?.toSwiftString() ?? "<unknown>"
                    // Use PC-based line/col for accurate location within the function
                    if let fb = bc as? JeffJSFunctionBytecodeCompiled {
                        let pc = fb.bytecodeLen > 0 ? max(0, min(sf.curPC, fb.bytecodeLen - 1)) : 0
                        let ln = fb.debugPc2lineBuf.isEmpty ? bc.lineNum : fb.lineForPC(pc)
                        let col = fb.debugPc2colBuf.isEmpty ? bc.colNum : fb.colForPC(pc)
                        if col > 0 {
                            stackStr += "\n    at \(funcName) (\(fn):\(ln):\(col))"
                        } else {
                            stackStr += "\n    at \(funcName) (\(fn):\(ln))"
                        }
                    } else {
                        let ln = bc.lineNum
                        let col = bc.colNum
                        stackStr += "\n    at \(funcName) (\(fn):\(ln):\(col))"
                    }
                } else {
                    stackStr += "\n    at \(funcName) (native)"
                }
            } else {
                stackStr += "\n    at \(funcName)"
            }

            frame = sf.prevFrame
            frameIndex += 1

            // Safety limit on stack trace depth
            if frameIndex > 100 { break }
        }

        // Set the "stack" property on the error object
        jeffJS_addProperty(ctx: ctx, obj: errObj,
                           atom: JeffJSAtomID.JS_ATOM_stack.rawValue,
                           flags: [.writable, .configurable])
        errObj.setOwnPropertyValue(
            atom: JeffJSAtomID.JS_ATOM_stack.rawValue,
            value: JeffJSValue.makeString(JeffJSString(swiftString: stackStr)))
    }

    // MARK: - Error.isError (ES2024 proposal)

    /// `Error.isError(arg)`
    /// Returns true if arg is an Error instance (has class ID JS_CLASS_ERROR).
    ///
    /// Mirrors `js_error_isError` in QuickJS.
    static func isError(ctx: JeffJSContext, this: JeffJSValue,
                        args: [JeffJSValue]) -> JeffJSValue {
        let arg = args.isEmpty ? JeffJSValue.undefined : args[0]
        guard let obj = getObject(arg) else {
            return .newBool(false)
        }
        let result = (obj.classID == JeffJSClassID.error.rawValue)
        return .newBool(result)
    }

    // MARK: - Throw Helpers

    /// Creates and throws an error of the given type.
    /// Sets the context's current exception and returns JS_EXCEPTION.
    ///
    /// Mirrors `JS_ThrowError` in QuickJS.
    ///
    /// - Parameters:
    ///   - ctx: The JS context.
    ///   - errorType: JSErrorEnum raw value (-1 for base Error, 0..7 for native types).
    ///   - message: The error message string.
    /// - Returns: JS_EXCEPTION sentinel value.
    @discardableResult
    static func throwError(ctx: JeffJSContext, errorType: Int,
                            message: String) -> JeffJSValue {
        // Create the error object via the constructor
        let msgVal = JeffJSValue.makeString(JeffJSString(swiftString: message))
        let errVal = errorConstructor(
            ctx: ctx,
            newTarget: .undefined,
            this: .undefined,
            args: [msgVal],
            magic: errorType
        )

        // Set as the current exception on the runtime
        ctx.rt.currentException = errVal
        return .makeException()
    }

    /// Throws a TypeError with the given message.
    /// Mirrors `JS_ThrowTypeError` in QuickJS.
    @discardableResult
    static func throwTypeError(ctx: JeffJSContext, message: String) -> JeffJSValue {
        return throwError(ctx: ctx, errorType: JSErrorEnum.JS_TYPE_ERROR.rawValue,
                          message: message)
    }

    /// Throws a RangeError with the given message.
    /// Mirrors `JS_ThrowRangeError` in QuickJS.
    @discardableResult
    static func throwRangeError(ctx: JeffJSContext, message: String) -> JeffJSValue {
        return throwError(ctx: ctx, errorType: JSErrorEnum.JS_RANGE_ERROR.rawValue,
                          message: message)
    }

    /// Throws a ReferenceError with the given message.
    /// Mirrors `JS_ThrowReferenceError` in QuickJS.
    @discardableResult
    static func throwReferenceError(ctx: JeffJSContext, message: String) -> JeffJSValue {
        return throwError(ctx: ctx, errorType: JSErrorEnum.JS_REFERENCE_ERROR.rawValue,
                          message: message)
    }

    /// Throws a SyntaxError with the given message.
    /// Mirrors `JS_ThrowSyntaxError` in QuickJS.
    @discardableResult
    static func throwSyntaxError(ctx: JeffJSContext, message: String) -> JeffJSValue {
        return throwError(ctx: ctx, errorType: JSErrorEnum.JS_SYNTAX_ERROR.rawValue,
                          message: message)
    }

    /// Throws a URIError with the given message.
    /// Mirrors `JS_ThrowURIError` in QuickJS.
    @discardableResult
    static func throwURIError(ctx: JeffJSContext, message: String) -> JeffJSValue {
        return throwError(ctx: ctx, errorType: JSErrorEnum.JS_URI_ERROR.rawValue,
                          message: message)
    }

    /// Throws an InternalError with the given message.
    /// Mirrors `JS_ThrowInternalError` in QuickJS.
    @discardableResult
    static func throwInternalError(ctx: JeffJSContext, message: String) -> JeffJSValue {
        return throwError(ctx: ctx, errorType: JSErrorEnum.JS_INTERNAL_ERROR.rawValue,
                          message: message)
    }

    // MARK: - Private Helpers

    /// Extract the JeffJSObject from a JeffJSValue with tag == .object.
    private static func getObject(_ val: JeffJSValue) -> JeffJSObject? {
        return val.toObject()
    }

    /// Convert a JeffJSValue to its string representation.
    /// Handles string, int, float64, undefined, null, bool, and objects.
    private static func jsValueToString(ctx: JeffJSContext, val: JeffJSValue) -> String {
        if val.isString, let str = val.stringValue {
            return str.toSwiftString()
        }
        if val.isInt {
            return String(val.toInt32())
        }
        if val.isFloat64 {
            let v = val.toFloat64()
            if v.isNaN { return "NaN" }
            if v.isInfinite { return v > 0 ? "Infinity" : "-Infinity" }
            if v == Double(Int64(v)) && !v.isNaN && !v.isInfinite {
                return String(Int64(v))
            }
            return String(v)
        }
        if val.isUndefined { return "undefined" }
        if val.isNull { return "null" }
        if val.isBool { return val.toBool() ? "true" : "false" }
        // Object: try toString or valueOf
        if val.isObject, let obj = getObject(val) {
            // Check for a toString method
            let toStrVal = obj.getOwnPropertyValue(
                atom: JeffJSAtomID.JS_ATOM_toString.rawValue)
            if toStrVal.isObject, let toStrObj = getObject(toStrVal),
               toStrObj.isCallable {
                // In a full implementation we'd call it; for now return [object Object]
                return "[object Object]"
            }
            return "[object Object]"
        }
        return ""
    }

    /// Creates an array from an iterable value.
    /// Simplified version for AggregateError's errors parameter.
    ///
    /// In QuickJS this calls `JS_IterableToArrayLike` or `JS_CreateArrayFromIterable`.
    /// For arrays, it copies elements directly. For other iterables, it would
    /// need the iterator protocol.
    private static func createArrayFromIterable(ctx: JeffJSContext,
                                                 iterable: JeffJSValue) -> JeffJSValue {
        // Fast path: if it's already an array, clone its elements
        if let iterObj = getObject(iterable), iterObj.isArray {
            let cloneObj = JeffJSObject()
            cloneObj.classID = JeffJSClassID.array.rawValue
            cloneObj.extensible = true
            cloneObj.fastArray = true

            if case .array(let size, let values, let count) = iterObj.payload {
                cloneObj.payload = .array(size: size, values: values, count: count)
            } else {
                cloneObj.payload = .array(size: 0, values: [], count: 0)
            }

            // Set length property
            let count: UInt32
            if case .array(_, _, let c) = cloneObj.payload {
                count = c
            } else {
                count = 0
            }
            jeffJS_addProperty(ctx: ctx, obj: cloneObj,
                               atom: JeffJSAtomID.JS_ATOM_length.rawValue,
                               flags: [.writable])
            cloneObj.setOwnPropertyValue(
                atom: JeffJSAtomID.JS_ATOM_length.rawValue,
                value: .newInt32(Int32(count)))

            return JeffJSValue.makeObject(cloneObj)
        }

        // Handle array-like objects with a length property
        if let iterObj = getObject(iterable) {
            let lengthVal = iterObj.getOwnPropertyValue(
                atom: JeffJSAtomID.JS_ATOM_length.rawValue)
            var length: Int = 0
            if lengthVal.isInt {
                length = Int(lengthVal.toInt32())
            } else if lengthVal.isFloat64 {
                let d = lengthVal.toFloat64()
                if d.isFinite && abs(d) < Double(Int.max / 2) { length = Int(d) }
            }

            if length > 0 {
                let arrObj = JeffJSObject()
                arrObj.classID = JeffJSClassID.array.rawValue
                arrObj.extensible = true
                arrObj.fastArray = true

                var elements: [JeffJSValue] = []
                elements.reserveCapacity(length)
                for i in 0..<length {
                    let indexAtom = UInt32(i) | JS_ATOM_TAG_INT
                    let val = iterObj.getOwnPropertyValue(atom: indexAtom)
                    elements.append(val)
                }
                arrObj.payload = .array(size: UInt32(length),
                                        values: elements,
                                        count: UInt32(length))

                jeffJS_addProperty(ctx: ctx, obj: arrObj,
                                   atom: JeffJSAtomID.JS_ATOM_length.rawValue,
                                   flags: [.writable])
                arrObj.setOwnPropertyValue(
                    atom: JeffJSAtomID.JS_ATOM_length.rawValue,
                    value: .newInt32(Int32(length)))

                return JeffJSValue.makeObject(arrObj)
            }
        }

        // Fallback: empty array
        let emptyArr = JeffJSObject()
        emptyArr.classID = JeffJSClassID.array.rawValue
        emptyArr.extensible = true
        emptyArr.fastArray = true
        emptyArr.payload = .array(size: 0, values: [], count: 0)

        jeffJS_addProperty(ctx: ctx, obj: emptyArr,
                           atom: JeffJSAtomID.JS_ATOM_length.rawValue,
                           flags: [.writable])
        emptyArr.setOwnPropertyValue(
            atom: JeffJSAtomID.JS_ATOM_length.rawValue,
            value: .newInt32(0))

        return JeffJSValue.makeObject(emptyArr)
    }

    /// Add a method to an object.
    private static func addMethod(
        ctx: JeffJSContext, obj: JeffJSObject, name: UInt32,
        func fn: @escaping (JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue,
        length: Int,
        nameOverride: String? = nil
    ) {
        let methodObj = JeffJSObject()
        methodObj.classID = JeffJSClassID.cFunction.rawValue
        methodObj.extensible = true
        methodObj.payload = .cFunc(
            realm: ctx,
            cFunction: .generic(fn),
            length: UInt8(length),
            cproto: UInt8(JS_CFUNC_GENERIC),
            magic: 0
        )

        // Set length
        jeffJS_addProperty(ctx: ctx, obj: methodObj,
                           atom: JeffJSAtomID.JS_ATOM_length.rawValue,
                           flags: [.configurable])
        methodObj.setOwnPropertyValue(
            atom: JeffJSAtomID.JS_ATOM_length.rawValue,
            value: .newInt32(Int32(length)))

        // Set name
        if let nameStr = nameOverride {
            jeffJS_addProperty(ctx: ctx, obj: methodObj,
                               atom: JeffJSAtomID.JS_ATOM_name.rawValue,
                               flags: [.configurable])
            methodObj.setOwnPropertyValue(
                atom: JeffJSAtomID.JS_ATOM_name.rawValue,
                value: JeffJSValue.makeString(JeffJSString(swiftString: nameStr)))
        }

        // If name is 0 (dynamic), we use the runtime to create the atom
        let propAtom: UInt32
        if name == 0 {
            if let nameStr = nameOverride {
                propAtom = ctx.rt.findAtom(nameStr)
            } else {
                propAtom = JeffJSAtomID.JS_ATOM_toString.rawValue
            }
        } else {
            propAtom = name
        }

        jeffJS_addProperty(ctx: ctx, obj: obj, atom: propAtom,
                           flags: [.writable, .configurable])
        obj.setOwnPropertyValue(atom: propAtom,
                                value: JeffJSValue.makeObject(methodObj))
    }

    /// Helper to set name and length properties on a constructor.
    private static func setNameAndLength(ctx: JeffJSContext, obj: JeffJSObject,
                                          name: String, length: Int32) {
        jeffJS_addProperty(ctx: ctx, obj: obj,
                           atom: JeffJSAtomID.JS_ATOM_length.rawValue,
                           flags: [.configurable])
        obj.setOwnPropertyValue(atom: JeffJSAtomID.JS_ATOM_length.rawValue,
                                value: .newInt32(length))

        jeffJS_addProperty(ctx: ctx, obj: obj,
                           atom: JeffJSAtomID.JS_ATOM_name.rawValue,
                           flags: [.configurable])
        obj.setOwnPropertyValue(
            atom: JeffJSAtomID.JS_ATOM_name.rawValue,
            value: JeffJSValue.makeString(JeffJSString(swiftString: name)))
    }

    /// Helper for creating new JeffJSValue with .newBool, matching the pattern
    /// used elsewhere in JeffJSValue.
    private static func newBool(_ val: Bool) -> JeffJSValue {
        return JeffJSValue.newBool(val)
    }
}
