// JeffJSBuiltinTypedArray.swift
// JeffJS — 1:1 Swift port of QuickJS JavaScript engine
//
// Port of QuickJS typed array, ArrayBuffer, SharedArrayBuffer, and DataView
// built-ins from quickjs.c. (ECMA-262 sec 25)
//
// TypedArray objects provide array-like access to raw binary data buffers.
// This file implements:
//   - ArrayBuffer and SharedArrayBuffer constructors and prototypes
//   - The abstract %TypedArray% intrinsic and all 12 concrete typed array types
//   - DataView constructor and prototype

import Foundation

// MARK: - Typed Array Element Info

/// Metadata for each typed array element type.
struct TypedArrayElementInfo {
    let name: String
    let classID: Int
    let bytesPerElement: Int
    let isBigInt: Bool
    let isClamped: Bool
    let isSigned: Bool
    let isFloat: Bool

    /// Read one element from a byte buffer at the given byte offset.
    func readElement(_ data: [UInt8], offset: Int, littleEndian: Bool = true) -> JeffJSValue {
        guard offset >= 0, offset + bytesPerElement <= data.count else { return .undefined }

        switch classID {
        case JeffJSClassID.int8Array.rawValue:
            let val = Int8(bitPattern: data[offset])
            return .newInt32(Int32(val))

        case JeffJSClassID.uint8Array.rawValue:
            return .newInt32(Int32(data[offset]))

        case JeffJSClassID.uint8cArray.rawValue:
            return .newInt32(Int32(data[offset]))

        case JeffJSClassID.int16Array.rawValue:
            var raw = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            if !littleEndian { raw = raw.byteSwapped }
            return .newInt32(Int32(Int16(bitPattern: raw)))

        case JeffJSClassID.uint16Array.rawValue:
            var raw = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            if !littleEndian { raw = raw.byteSwapped }
            return .newInt32(Int32(raw))

        case JeffJSClassID.int32Array.rawValue:
            var raw = UInt32(data[offset])
                    | (UInt32(data[offset + 1]) << 8)
                    | (UInt32(data[offset + 2]) << 16)
                    | (UInt32(data[offset + 3]) << 24)
            if !littleEndian { raw = raw.byteSwapped }
            return .newInt32(Int32(bitPattern: raw))

        case JeffJSClassID.uint32Array.rawValue:
            var raw = UInt32(data[offset])
                    | (UInt32(data[offset + 1]) << 8)
                    | (UInt32(data[offset + 2]) << 16)
                    | (UInt32(data[offset + 3]) << 24)
            if !littleEndian { raw = raw.byteSwapped }
            return .newFloat64(Double(raw))

        case JeffJSClassID.float32Array.rawValue:
            var raw = UInt32(data[offset])
                    | (UInt32(data[offset + 1]) << 8)
                    | (UInt32(data[offset + 2]) << 16)
                    | (UInt32(data[offset + 3]) << 24)
            if !littleEndian { raw = raw.byteSwapped }
            let f = Float(bitPattern: raw)
            return .newFloat64(Double(f))

        case JeffJSClassID.float64Array.rawValue:
            var raw = UInt64(data[offset])
                    | (UInt64(data[offset + 1]) << 8)
                    | (UInt64(data[offset + 2]) << 16)
                    | (UInt64(data[offset + 3]) << 24)
                    | (UInt64(data[offset + 4]) << 32)
                    | (UInt64(data[offset + 5]) << 40)
                    | (UInt64(data[offset + 6]) << 48)
                    | (UInt64(data[offset + 7]) << 56)
            if !littleEndian { raw = raw.byteSwapped }
            return .newFloat64(Double(bitPattern: raw))

        case JeffJSClassID.bigInt64Array.rawValue:
            var raw = UInt64(data[offset])
                    | (UInt64(data[offset + 1]) << 8)
                    | (UInt64(data[offset + 2]) << 16)
                    | (UInt64(data[offset + 3]) << 24)
                    | (UInt64(data[offset + 4]) << 32)
                    | (UInt64(data[offset + 5]) << 40)
                    | (UInt64(data[offset + 6]) << 48)
                    | (UInt64(data[offset + 7]) << 56)
            if !littleEndian { raw = raw.byteSwapped }
            return .newBigInt(Int64(bitPattern: raw))

        case JeffJSClassID.bigUint64Array.rawValue:
            var raw = UInt64(data[offset])
                    | (UInt64(data[offset + 1]) << 8)
                    | (UInt64(data[offset + 2]) << 16)
                    | (UInt64(data[offset + 3]) << 24)
                    | (UInt64(data[offset + 4]) << 32)
                    | (UInt64(data[offset + 5]) << 40)
                    | (UInt64(data[offset + 6]) << 48)
                    | (UInt64(data[offset + 7]) << 56)
            if !littleEndian { raw = raw.byteSwapped }
            return .newBigInt(JBigInt(raw))

        default:
            return .undefined
        }
    }

    /// Safe conversion from double to Int32 — returns 0 for NaN/Inf (matching JS ToInt32 spec).
    @inline(__always)
    private static func safeDoubleToInt32(_ d: Double) -> Int32 {
        guard d.isFinite else { return 0 }
        let rem = d.truncatingRemainder(dividingBy: 4294967296.0)
        if rem.isNaN || rem.isInfinite || rem > 9.2e18 || rem < -9.2e18 { return 0 }
        return Int32(truncatingIfNeeded: Int64(rem))
    }

    /// Write one element to a byte buffer at the given byte offset.
    func writeElement(_ data: inout [UInt8], offset: Int, value: JeffJSValue, littleEndian: Bool = true) {
        guard offset >= 0, offset + bytesPerElement <= data.count else { return }

        switch classID {
        case JeffJSClassID.int8Array.rawValue:
            let v: Int32 = value.isInt ? value.toInt32() : Self.safeDoubleToInt32(value.toNumber())
            data[offset] = UInt8(bitPattern: Int8(truncatingIfNeeded: v))

        case JeffJSClassID.uint8Array.rawValue:
            let v: Int32 = value.isInt ? value.toInt32() : Self.safeDoubleToInt32(value.toNumber())
            data[offset] = UInt8(truncatingIfNeeded: v)

        case JeffJSClassID.uint8cArray.rawValue:
            let d = value.isInt ? Double(value.toInt32()) : value.toNumber()
            if d.isNaN || d <= 0 { data[offset] = 0 }
            else if d >= 255 { data[offset] = 255 }
            else { data[offset] = UInt8(Darwin.round(d)) }

        case JeffJSClassID.int16Array.rawValue:
            let v: Int32 = value.isInt ? value.toInt32() : Self.safeDoubleToInt32(value.toNumber())
            var raw = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
            if !littleEndian { raw = raw.byteSwapped }
            data[offset] = UInt8(raw & 0xFF)
            data[offset + 1] = UInt8((raw >> 8) & 0xFF)

        case JeffJSClassID.uint16Array.rawValue:
            let v: Int32 = value.isInt ? value.toInt32() : Self.safeDoubleToInt32(value.toNumber())
            var raw = UInt16(truncatingIfNeeded: v)
            if !littleEndian { raw = raw.byteSwapped }
            data[offset] = UInt8(raw & 0xFF)
            data[offset + 1] = UInt8((raw >> 8) & 0xFF)

        case JeffJSClassID.int32Array.rawValue:
            let v: Int32 = value.isInt ? value.toInt32() : Self.safeDoubleToInt32(value.toNumber())
            var raw = UInt32(bitPattern: v)
            if !littleEndian { raw = raw.byteSwapped }
            data[offset] = UInt8(raw & 0xFF)
            data[offset + 1] = UInt8((raw >> 8) & 0xFF)
            data[offset + 2] = UInt8((raw >> 16) & 0xFF)
            data[offset + 3] = UInt8((raw >> 24) & 0xFF)

        case JeffJSClassID.uint32Array.rawValue:
            // ToUint32 is modular: `UInt32(d)` trapped on negatives and on
            // anything >= 2^32 (e.g. `new Uint32Array(1)[0] = -1`).
            let v: Int32 = value.isInt ? value.toInt32() : Self.safeDoubleToInt32(value.toNumber())
            var raw = UInt32(bitPattern: v)
            if !littleEndian { raw = raw.byteSwapped }
            data[offset] = UInt8(raw & 0xFF)
            data[offset + 1] = UInt8((raw >> 8) & 0xFF)
            data[offset + 2] = UInt8((raw >> 16) & 0xFF)
            data[offset + 3] = UInt8((raw >> 24) & 0xFF)

        case JeffJSClassID.float32Array.rawValue:
            let d = value.isInt ? Double(value.toInt32()) : value.toNumber()
            var raw = Float(d).bitPattern
            if !littleEndian { raw = raw.byteSwapped }
            data[offset] = UInt8(raw & 0xFF)
            data[offset + 1] = UInt8((raw >> 8) & 0xFF)
            data[offset + 2] = UInt8((raw >> 16) & 0xFF)
            data[offset + 3] = UInt8((raw >> 24) & 0xFF)

        case JeffJSClassID.float64Array.rawValue:
            let d = value.isInt ? Double(value.toInt32()) : value.toNumber()
            var raw = d.bitPattern
            if !littleEndian { raw = raw.byteSwapped }
            for i in 0..<8 {
                data[offset + i] = UInt8((raw >> (i * 8)) & 0xFF)
            }

        case JeffJSClassID.bigInt64Array.rawValue, JeffJSClassID.bigUint64Array.rawValue:
            // The caller has already run ToBigInt, so a non-BigInt here means
            // an internal store; keep it lossless rather than writing zero.
            var raw: UInt64 = 0
            if value.isBigInt {
                raw = value.bigIntValue.lowUInt64
            } else if value.isInt {
                raw = UInt64(bitPattern: Int64(value.toInt32()))
            }
            if !littleEndian { raw = raw.byteSwapped }
            for i in 0..<8 {
                data[offset + i] = UInt8((raw >> (i * 8)) & 0xFF)
            }

        default:
            break
        }
    }
}

/// Table of all typed array types indexed by (classID - first typed array classID).
let typedArrayInfoTable: [TypedArrayElementInfo] = [
    TypedArrayElementInfo(name: "Int8Array",         classID: JeffJSClassID.int8Array.rawValue,      bytesPerElement: 1, isBigInt: false, isClamped: false, isSigned: true,  isFloat: false),
    TypedArrayElementInfo(name: "Uint8Array",        classID: JeffJSClassID.uint8Array.rawValue,     bytesPerElement: 1, isBigInt: false, isClamped: false, isSigned: false, isFloat: false),
    TypedArrayElementInfo(name: "Uint8ClampedArray", classID: JeffJSClassID.uint8cArray.rawValue,    bytesPerElement: 1, isBigInt: false, isClamped: true,  isSigned: false, isFloat: false),
    TypedArrayElementInfo(name: "Int16Array",        classID: JeffJSClassID.int16Array.rawValue,     bytesPerElement: 2, isBigInt: false, isClamped: false, isSigned: true,  isFloat: false),
    TypedArrayElementInfo(name: "Uint16Array",       classID: JeffJSClassID.uint16Array.rawValue,    bytesPerElement: 2, isBigInt: false, isClamped: false, isSigned: false, isFloat: false),
    TypedArrayElementInfo(name: "Int32Array",        classID: JeffJSClassID.int32Array.rawValue,     bytesPerElement: 4, isBigInt: false, isClamped: false, isSigned: true,  isFloat: false),
    TypedArrayElementInfo(name: "Uint32Array",       classID: JeffJSClassID.uint32Array.rawValue,    bytesPerElement: 4, isBigInt: false, isClamped: false, isSigned: false, isFloat: false),
    TypedArrayElementInfo(name: "BigInt64Array",     classID: JeffJSClassID.bigInt64Array.rawValue,  bytesPerElement: 8, isBigInt: true,  isClamped: false, isSigned: true,  isFloat: false),
    TypedArrayElementInfo(name: "BigUint64Array",    classID: JeffJSClassID.bigUint64Array.rawValue, bytesPerElement: 8, isBigInt: true,  isClamped: false, isSigned: false, isFloat: false),
    TypedArrayElementInfo(name: "Float32Array",      classID: JeffJSClassID.float32Array.rawValue,   bytesPerElement: 4, isBigInt: false, isClamped: false, isSigned: false, isFloat: true),
    TypedArrayElementInfo(name: "Float64Array",      classID: JeffJSClassID.float64Array.rawValue,   bytesPerElement: 8, isBigInt: false, isClamped: false, isSigned: false, isFloat: true),
]

/// Float16Array info (not backed by a classID yet, but included for completeness).
let float16ArrayInfo = TypedArrayElementInfo(
    name: "Float16Array", classID: 0, bytesPerElement: 2,
    isBigInt: false, isClamped: false, isSigned: false, isFloat: true
)

/// Lookup TypedArrayElementInfo by classID.
func typedArrayInfo(forClassID classID: Int) -> TypedArrayElementInfo? {
    return typedArrayInfoTable.first { $0.classID == classID }
}

// MARK: - ArrayBuffer Helpers

/// Validate and extract the JeffJSArrayBuffer from an object.
private func getArrayBuffer(_ thisVal: JeffJSValue) -> JeffJSArrayBuffer? {
    guard let obj = thisVal.toObject() else { return nil }
    if obj.classID == JeffJSClassID.arrayBuffer.rawValue ||
       obj.classID == JeffJSClassID.sharedArrayBuffer.rawValue {
        if case .arrayBuffer(let ab) = obj.payload { return ab }
    }
    return nil
}

/// Validate a typed array is not detached and return its buffer data.
private func validateTypedArray(_ thisVal: JeffJSValue) -> (JeffJSTypedArray, JeffJSArrayBuffer)? {
    guard let obj = thisVal.toObject() else { return nil }
    if case .typedArray(let ta) = obj.payload {
        if let bufObj = ta.buffer, case .arrayBuffer(let ab) = bufObj.payload {
            if ab.detached { return nil }
            return (ta, ab)
        }
    }
    return nil
}

// MARK: - ArrayBuffer Constructor

/// new ArrayBuffer(length) or new ArrayBuffer(length, { maxByteLength })
func jsArrayBuffer_constructor(_ ctx: JeffJSContext, _ thisVal: JeffJSValue,
                               _ argv: [JeffJSValue]) -> JeffJSValue {
    var byteLength = 0
    if argv.count >= 1 {
        if argv[0].isInt { byteLength = Int(argv[0].toInt32()) }
        else if argv[0].isFloat64 { byteLength = jeffJS_intArg(argv[0].toFloat64()) }
    }
    if byteLength < 0 || byteLength > jeffJS_maxByteLength {
        return ctx.throwRangeError("Invalid array buffer length")
    }

    // Check for options { maxByteLength } for resizable buffers.
    var maxByteLength = byteLength
    var isResizable = false
    if argv.count >= 2, argv[1].isObject {
        if let optsObj = argv[1].toObject() {
            // Look for maxByteLength property.
            let mbVal = optsObj.getOwnPropertyValue(atom: JeffJSAtomID.JS_ATOM_maxByteLength.rawValue)
            if !mbVal.isUndefined {
                if mbVal.isInt { maxByteLength = Int(mbVal.toInt32()) }
                else if mbVal.isFloat64 { maxByteLength = jeffJS_intArg(mbVal.toFloat64()) }
                if maxByteLength < byteLength {
                    return ctx.throwTypeError("maxByteLength must be >= byteLength")
                }
                if maxByteLength > jeffJS_maxByteLength {
                    return ctx.throwRangeError("Invalid array buffer max length")
                }
                isResizable = true
            }
        }
    }

    let ab = JeffJSArrayBuffer(byteLength: byteLength)
    if isResizable {
        ab.data.reserveCapacity(maxByteLength)
    }

    // Look up the ArrayBuffer prototype from the context's classProto array
    // so that byteLength and other prototype getters are accessible.
    var abProto: JeffJSObject? = nil
    let abClassID = Int(JSClassID.JS_CLASS_ARRAY_BUFFER.rawValue)
    if abClassID < ctx.classProto.count {
        let protoVal = ctx.classProto[abClassID]
        if protoVal.isObject {
            abProto = protoVal.toObject()
        }
    }
    let obj = jeffJS_createObject(ctx: ctx, proto: abProto, classID: UInt16(JeffJSClassID.arrayBuffer.rawValue))
    obj.payload = JeffJSObjectPayload.arrayBuffer(ab)
    return .makeObject(obj)
}

// MARK: - ArrayBuffer Prototype Methods

/// ArrayBuffer.prototype.byteLength getter
func jsArrayBuffer_byteLength(_ ctx: JeffJSContext, _ thisVal: JeffJSValue) -> JeffJSValue {
    guard let ab = getArrayBuffer(thisVal) else {
        return ctx.throwTypeError("not an ArrayBuffer")
    }
    if ab.detached { return .newInt32(0) }
    return .newInt32(Int32(ab.byteLength))
}

/// ArrayBuffer.prototype.slice(begin, end)
func jsArrayBuffer_slice(_ ctx: JeffJSContext, _ thisVal: JeffJSValue,
                         _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let ab = getArrayBuffer(thisVal), !ab.detached else {
        return ctx.throwTypeError("ArrayBuffer is detached")
    }

    let len = ab.byteLength
    var start = 0
    var end = len

    if argv.count >= 1 {
        start = argv[0].isInt ? Int(argv[0].toInt32()) : jeffJS_intArg(argv[0].toNumber())
        if start < 0 { start = max(len + start, 0) }
        start = min(start, len)
    }
    if argv.count >= 2, !argv[1].isUndefined {
        end = argv[1].isInt ? Int(argv[1].toInt32()) : jeffJS_intArg(argv[1].toNumber())
        if end < 0 { end = max(len + end, 0) }
        end = min(end, len)
    }

    let newLen = max(end - start, 0)
    let newAB = JeffJSArrayBuffer(byteLength: newLen)
    if newLen > 0 {
        newAB.data = Array(ab.data[start..<(start + newLen)])
    }

    let obj = jeffJS_createObject(ctx: ctx, proto: nil, classID: UInt16(JeffJSClassID.arrayBuffer.rawValue))
    obj.payload = JeffJSObjectPayload.arrayBuffer(newAB)
    return .makeObject(obj)
}

/// ArrayBuffer.prototype.resize(newLength)
func jsArrayBuffer_resize(_ ctx: JeffJSContext, _ thisVal: JeffJSValue,
                          _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let ab = getArrayBuffer(thisVal), !ab.detached else {
        return ctx.throwTypeError("ArrayBuffer is detached")
    }
    guard argv.count >= 1 else { return ctx.throwTypeError("missing argument") }
    let newLen = argv[0].isInt ? Int(argv[0].toInt32()) : jeffJS_intArg(argv[0].toNumber())
    if newLen < 0 || newLen > jeffJS_maxByteLength { return ctx.throwRangeError("Invalid length") }

    if newLen > ab.byteLength {
        ab.data.append(contentsOf: [UInt8](repeating: 0, count: newLen - ab.byteLength))
    } else if newLen < ab.byteLength {
        ab.data = Array(ab.data.prefix(newLen))
    }
    ab.byteLength = newLen
    return .undefined
}

/// ArrayBuffer.prototype.transfer() / transferToFixedLength()
func jsArrayBuffer_transfer(_ ctx: JeffJSContext, _ thisVal: JeffJSValue,
                            _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let ab = getArrayBuffer(thisVal), !ab.detached else {
        return ctx.throwTypeError("ArrayBuffer is detached")
    }

    var newLen = ab.byteLength
    if argv.count >= 1, !argv[0].isUndefined {
        newLen = argv[0].isInt ? Int(argv[0].toInt32()) : jeffJS_intArg(argv[0].toNumber())
    }
    if newLen < 0 || newLen > jeffJS_maxByteLength { return ctx.throwRangeError("Invalid length") }

    let newAB = JeffJSArrayBuffer(byteLength: newLen)
    let copyLen = min(ab.byteLength, newLen)
    if copyLen > 0 {
        newAB.data.replaceSubrange(0..<copyLen, with: ab.data.prefix(copyLen))
    }

    // Detach the old buffer.
    ab.detached = true
    ab.byteLength = 0
    ab.data = []

    let obj = jeffJS_createObject(ctx: ctx, proto: nil, classID: UInt16(JeffJSClassID.arrayBuffer.rawValue))
    obj.payload = JeffJSObjectPayload.arrayBuffer(newAB)
    return .makeObject(obj)
}

/// ArrayBuffer.isView(value) — static method.
func jsArrayBuffer_isView(_ ctx: JeffJSContext, _ thisVal: JeffJSValue,
                          _ argv: [JeffJSValue]) -> JeffJSValue {
    guard argv.count >= 1, let obj = argv[0].toObject() else { return .newBool(false) }
    if case .typedArray(_) = obj.payload { return .newBool(true) }
    if obj.classID == JeffJSClassID.dataView.rawValue { return .newBool(true) }
    return .newBool(false)
}

/// ArrayBuffer.prototype.maxByteLength getter
func jsArrayBuffer_maxByteLength(_ ctx: JeffJSContext, _ thisVal: JeffJSValue) -> JeffJSValue {
    guard let ab = getArrayBuffer(thisVal) else {
        return ctx.throwTypeError("not an ArrayBuffer")
    }
    return .newInt32(Int32(ab.data.capacity > ab.byteLength ? ab.data.capacity : ab.byteLength))
}

/// ArrayBuffer.prototype.resizable getter
func jsArrayBuffer_resizable(_ ctx: JeffJSContext, _ thisVal: JeffJSValue) -> JeffJSValue {
    guard let ab = getArrayBuffer(thisVal) else { return ctx.throwTypeError("not an ArrayBuffer") }
    return .newBool(ab.data.capacity > ab.byteLength)
}

/// ArrayBuffer.prototype.detached getter
func jsArrayBuffer_detached(_ ctx: JeffJSContext, _ thisVal: JeffJSValue) -> JeffJSValue {
    guard let ab = getArrayBuffer(thisVal) else { return ctx.throwTypeError("not an ArrayBuffer") }
    return .newBool(ab.detached)
}

// MARK: - SharedArrayBuffer Constructor

func jsSharedArrayBuffer_constructor(_ ctx: JeffJSContext, _ thisVal: JeffJSValue,
                                     _ argv: [JeffJSValue]) -> JeffJSValue {
    var byteLength = 0
    if argv.count >= 1 {
        byteLength = argv[0].isInt ? Int(argv[0].toInt32()) : jeffJS_intArg(argv[0].toNumber())
    }
    if byteLength < 0 || byteLength > jeffJS_maxByteLength { return ctx.throwRangeError("Invalid SharedArrayBuffer length") }

    let ab = JeffJSArrayBuffer(byteLength: byteLength)
    ab.shared = true

    // Check for maxByteLength option.
    if argv.count >= 2, argv[1].isObject, let opts = argv[1].toObject() {
        let mbVal = opts.getOwnPropertyValue(atom: JeffJSAtomID.JS_ATOM_maxByteLength.rawValue)
        if !mbVal.isUndefined {
            let mb = mbVal.isInt ? Int(mbVal.toInt32()) : jeffJS_intArg(mbVal.toNumber())
            if mb > jeffJS_maxByteLength { return ctx.throwRangeError("Invalid SharedArrayBuffer max length") }
            if mb >= byteLength { ab.data.reserveCapacity(mb) }
        }
    }

    let obj = jeffJS_createObject(ctx: ctx, proto: nil, classID: UInt16(JeffJSClassID.sharedArrayBuffer.rawValue))
    obj.payload = JeffJSObjectPayload.arrayBuffer(ab)
    return .makeObject(obj)
}

/// SharedArrayBuffer.prototype.grow(newLength)
func jsSharedArrayBuffer_grow(_ ctx: JeffJSContext, _ thisVal: JeffJSValue,
                              _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let ab = getArrayBuffer(thisVal), ab.shared else {
        return ctx.throwTypeError("not a SharedArrayBuffer")
    }
    guard argv.count >= 1 else { return ctx.throwTypeError("missing argument") }
    let newLen = argv[0].isInt ? Int(argv[0].toInt32()) : jeffJS_intArg(argv[0].toNumber())
    if newLen < ab.byteLength { return ctx.throwTypeError("Cannot shrink SharedArrayBuffer") }
    if newLen > jeffJS_maxByteLength { return ctx.throwRangeError("Invalid length") }
    ab.data.append(contentsOf: [UInt8](repeating: 0, count: newLen - ab.byteLength))
    ab.byteLength = newLen
    return .undefined
}

/// SharedArrayBuffer.prototype.growable getter
func jsSharedArrayBuffer_growable(_ ctx: JeffJSContext, _ thisVal: JeffJSValue) -> JeffJSValue {
    guard let ab = getArrayBuffer(thisVal), ab.shared else {
        return ctx.throwTypeError("not a SharedArrayBuffer")
    }
    return .newBool(ab.data.capacity > ab.byteLength)
}

// MARK: - Buffer ownership
//
// A typed array / DataView owns exactly one JS reference to its ArrayBuffer
// object; `freeObject` releases it when the view dies. Before that, the view
// stored a *borrowed* reference: `function f(){ var ab = new ArrayBuffer(4);
// return new Uint8Array(ab); }` came back with length 0 because the Round 9
// caller released the constructor argument the moment the constructor
// returned, and internally created buffers were never released at all.

/// Adopt a freshly created buffer object. It already carries the +1 JS
/// reference `jeffJS_createObject` gave it, but it is never handed out as a
/// `JeffJSValue`, so nothing has taken the `Unmanaged` retain that
/// `freeGCObject` releases at the end of its life — take it here, or
/// releasing the buffer over-releases a never-retained allocation
/// (`new Uint8Array(2);` as a statement crashed on the spot).
@inline(__always)
func typedArrayAdoptNewBuffer(_ ta: JeffJSTypedArray, _ bufObj: JeffJSObject) {
    _ = JeffJSValue.makeObject(bufObj)
    ta.buffer = bufObj
}

/// Adopt a buffer the caller only lends us — a constructor argument, or the
/// buffer another view already owns. The object has been boxed before, so it
/// needs the JS reference only. Bump the refcount directly rather than
/// through `JeffJSValue.makeObject(...).dupValue()`: that would take a second
/// `Unmanaged` retain which nothing ever releases.
@inline(__always)
func typedArrayAdoptBuffer(_ ta: JeffJSTypedArray, _ bufObj: JeffJSObject) {
    ta.buffer = bufObj
    bufObj.refCount += 1
    if JeffJSGCObjectHeader.trackRefcounts { JeffJSGCObjectHeader.trackDup(bufObj) }
}

/// Hand the caller its own reference to the buffer object (Round 9: every
/// returned value is owned). `JeffJSValue.makeObject` would take a second
/// `Unmanaged` retain that nothing releases — the object's ARC retain was
/// taken the first time it was boxed and is released when its JS refcount
/// reaches zero, which cannot happen while the value returned here holds one.
@inline(__always)
func typedArrayBufferValue(_ buf: JeffJSObject) -> JeffJSValue {
    return JeffJSValue.makeObjectRecycled(buf).dupValue()
}

// MARK: - TypedArray Constructor (generic)

/// Create a typed array from: length, another typed array, an array-like, or (buffer, offset, length).
func jsTypedArray_constructor(_ ctx: JeffJSContext, _ thisVal: JeffJSValue,
                              _ argv: [JeffJSValue], classID: Int) -> JeffJSValue {
    guard let info = typedArrayInfo(forClassID: classID) else {
        return ctx.throwTypeError("Unknown typed array type")
    }

    // Resolve the prototype for this typed array type from classProto.
    let proto = ctx.classProto[classID].toObject()
    let obj = jeffJS_createObject(ctx: ctx, proto: proto, classID: UInt16(classID))
    let ta = JeffJSTypedArray()
    ta.classID = classID

    if argv.isEmpty {
        // Empty typed array.
        let ab = JeffJSArrayBuffer(byteLength: 0)
        let bufObj = jeffJS_createObject(ctx: ctx, proto: nil, classID: UInt16(JeffJSClassID.arrayBuffer.rawValue))
        bufObj.payload = JeffJSObjectPayload.arrayBuffer(ab)
        typedArrayAdoptNewBuffer(ta, bufObj)
        ta.length = 0
        ta.byteLength = 0
        ta.byteOffset = 0
    } else if argv[0].isObject, let srcObj = argv[0].toObject(),
              (srcObj.classID == JeffJSClassID.arrayBuffer.rawValue ||
               srcObj.classID == JeffJSClassID.sharedArrayBuffer.rawValue) {
        // new TypedArray(buffer [, byteOffset [, length]])
        guard case .arrayBuffer(let ab) = srcObj.payload, !ab.detached else {
            return ctx.throwTypeError("ArrayBuffer is detached")
        }
        var byteOff = 0
        if argv.count >= 2, !argv[1].isUndefined {
            byteOff = argv[1].isInt ? Int(argv[1].toInt32()) : jeffJS_intArg(argv[1].toNumber())
        }
        if byteOff < 0 || byteOff % info.bytesPerElement != 0 {
            return ctx.throwTypeError("Invalid byteOffset")
        }

        var length: Int
        if argv.count >= 3, !argv[2].isUndefined {
            length = argv[2].isInt ? Int(argv[2].toInt32()) : jeffJS_intArg(argv[2].toNumber())
            if length < 0 || byteOff + length * info.bytesPerElement > ab.byteLength {
                return ctx.throwTypeError("Invalid length")
            }
        } else {
            let remaining = ab.byteLength - byteOff
            if remaining % info.bytesPerElement != 0 {
                return ctx.throwTypeError("Byte length not aligned")
            }
            length = remaining / info.bytesPerElement
        }

        typedArrayAdoptBuffer(ta, srcObj)
        ta.byteOffset = byteOff
        ta.byteLength = length * info.bytesPerElement
        ta.length = length
    } else if argv[0].isInt || argv[0].isFloat64 {
        // new TypedArray(length)
        let length = argv[0].isInt ? Int(argv[0].toInt32()) : jeffJS_intArg(argv[0].toNumber())
        if length < 0 || length > jeffJS_maxByteLength / info.bytesPerElement {
            return ctx.throwRangeError("Invalid typed array length")
        }
        let byteLen = length * info.bytesPerElement
        let ab = JeffJSArrayBuffer(byteLength: byteLen)
        let bufObj = jeffJS_createObject(ctx: ctx, proto: nil, classID: UInt16(JeffJSClassID.arrayBuffer.rawValue))
        bufObj.payload = JeffJSObjectPayload.arrayBuffer(ab)
        typedArrayAdoptNewBuffer(ta, bufObj)
        ta.byteOffset = 0
        ta.byteLength = byteLen
        ta.length = length
    } else if argv[0].isObject {
        // new TypedArray(arrayLike) — copy elements from array-like or iterable
        let srcVal = argv[0]
        // Read length from the source
        let lenVal = ctx.getPropertyStr(obj: srcVal, name: "length")
        let srcLen: Int
        if lenVal.isInt { srcLen = Int(lenVal.toInt32()) }
        else if lenVal.isFloat64 { srcLen = max(0, jeffJS_intArg(lenVal.toFloat64())) }
        else { srcLen = 0 }
        if srcLen > jeffJS_maxByteLength / info.bytesPerElement {
            return ctx.throwRangeError("Invalid typed array length")
        }

        let byteLen = srcLen * info.bytesPerElement
        let ab = JeffJSArrayBuffer(byteLength: byteLen)
        let bufObj = jeffJS_createObject(ctx: ctx, proto: nil, classID: UInt16(JeffJSClassID.arrayBuffer.rawValue))
        bufObj.payload = JeffJSObjectPayload.arrayBuffer(ab)

        // Copy elements from source into the buffer
        for i in 0..<srcLen {
            let elem = ctx.getPropertyUint32(obj: srcVal, index: UInt32(i))
            info.writeElement(&ab.data, offset: i * info.bytesPerElement, value: elem)
        }

        typedArrayAdoptNewBuffer(ta, bufObj)
        ta.byteOffset = 0
        ta.byteLength = byteLen
        ta.length = srcLen
    } else {
        // Fallback: single non-object, non-number argument — treat as length 0
        let ab = JeffJSArrayBuffer(byteLength: 0)
        let bufObj = jeffJS_createObject(ctx: ctx, proto: nil, classID: UInt16(JeffJSClassID.arrayBuffer.rawValue))
        bufObj.payload = JeffJSObjectPayload.arrayBuffer(ab)
        typedArrayAdoptNewBuffer(ta, bufObj)
        ta.length = 0
        ta.byteLength = 0
        ta.byteOffset = 0
    }

    ta.obj = obj
    obj.payload = JeffJSObjectPayload.typedArray(ta)
    return .makeObject(obj)
}

// MARK: - TypedArray Prototype Methods

/// %TypedArray%.prototype.at(index)
func jsTypedArray_at(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let (ta, ab) = validateTypedArray(thisVal) else {
        return ctx.throwTypeError("not a typed array or buffer detached")
    }
    guard let info = typedArrayInfo(forClassID: ta.classID) else { return .undefined }
    var idx = argv.count >= 1 ? (argv[0].isInt ? Int(argv[0].toInt32()) : jeffJS_intArg(argv[0].toNumber())) : 0
    if idx < 0 { idx += ta.length }
    if idx < 0 || idx >= ta.length { return .undefined }
    return info.readElement(ab.data, offset: ta.byteOffset + idx * info.bytesPerElement)
}

/// %TypedArray%.prototype.buffer getter
func jsTypedArray_buffer(_ ctx: JeffJSContext, _ thisVal: JeffJSValue) -> JeffJSValue {
    guard let obj = thisVal.toObject() else { return .undefined }
    if case .typedArray(let ta) = obj.payload, let buf = ta.buffer {
        // The buffer stays owned by the typed array: hand the caller its own
        // reference (Round 9 — the caller releases every value it receives).
        return typedArrayBufferValue(buf)
    }
    return .undefined
}

/// %TypedArray%.prototype.byteLength getter
func jsTypedArray_byteLength(_ ctx: JeffJSContext, _ thisVal: JeffJSValue) -> JeffJSValue {
    guard let (ta, ab) = validateTypedArray(thisVal) else { return .newInt32(0) }
    if ab.detached { return .newInt32(0) }
    return .newInt32(Int32(ta.byteLength))
}

/// %TypedArray%.prototype.byteOffset getter
func jsTypedArray_byteOffset(_ ctx: JeffJSContext, _ thisVal: JeffJSValue) -> JeffJSValue {
    guard let (ta, ab) = validateTypedArray(thisVal) else { return .newInt32(0) }
    if ab.detached { return .newInt32(0) }
    return .newInt32(Int32(ta.byteOffset))
}

/// %TypedArray%.prototype.length getter
func jsTypedArray_length(_ ctx: JeffJSContext, _ thisVal: JeffJSValue) -> JeffJSValue {
    guard let (ta, ab) = validateTypedArray(thisVal) else { return .newInt32(0) }
    if ab.detached { return .newInt32(0) }
    return .newInt32(Int32(ta.length))
}

/// %TypedArray%.prototype.set(source [, offset])
func jsTypedArray_set(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let (ta, ab) = validateTypedArray(thisVal) else {
        return ctx.throwTypeError("not a typed array")
    }
    guard let info = typedArrayInfo(forClassID: ta.classID) else { return .undefined }
    var targetOffset = 0
    if argv.count >= 2, !argv[1].isUndefined {
        targetOffset = argv[1].isInt ? Int(argv[1].toInt32()) : jeffJS_intArg(argv[1].toNumber())
    }
    if targetOffset < 0 { return ctx.throwTypeError("Invalid offset") }

    if argv.count >= 1, let srcObj = argv[0].toObject() {
        if case .typedArray(let srcTA) = srcObj.payload,
           let srcBuf = srcTA.buffer,
           case .arrayBuffer(let srcAB) = srcBuf.payload,
           let srcInfo = typedArrayInfo(forClassID: srcTA.classID) {
            // Copy from another typed array.
            if targetOffset + srcTA.length > ta.length {
                return ctx.throwTypeError("Source too large")
            }
            var data = ab.data
            for i in 0..<srcTA.length {
                let val = srcInfo.readElement(srcAB.data, offset: srcTA.byteOffset + i * srcInfo.bytesPerElement)
                info.writeElement(&data, offset: ta.byteOffset + (targetOffset + i) * info.bytesPerElement, value: val)
            }
            ab.data = data
        }
    }
    return .undefined
}

/// %TypedArray%.prototype.slice(start, end)
func jsTypedArray_slice(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let (ta, ab) = validateTypedArray(thisVal) else {
        return ctx.throwTypeError("not a typed array")
    }
    guard let info = typedArrayInfo(forClassID: ta.classID) else { return .undefined }

    let len = ta.length
    var start = argv.count >= 1 ? (argv[0].isInt ? Int(argv[0].toInt32()) : jeffJS_intArg(argv[0].toNumber())) : 0
    var end = argv.count >= 2 && !argv[1].isUndefined ? (argv[1].isInt ? Int(argv[1].toInt32()) : jeffJS_intArg(argv[1].toNumber())) : len

    if start < 0 { start = max(len + start, 0) }; start = min(start, len)
    if end < 0 { end = max(len + end, 0) }; end = min(end, len)

    let count = max(end - start, 0)
    let newByteLen = count * info.bytesPerElement
    let newAB = JeffJSArrayBuffer(byteLength: newByteLen)
    if count > 0 {
        let srcOffset = ta.byteOffset + start * info.bytesPerElement
        newAB.data = Array(ab.data[srcOffset..<(srcOffset + newByteLen)])
    }

    let newBufObj = jeffJS_createObject(ctx: ctx, proto: nil, classID: UInt16(JeffJSClassID.arrayBuffer.rawValue))
    newBufObj.payload = JeffJSObjectPayload.arrayBuffer(newAB)

    let sliceProto = ctx.classProto[ta.classID].toObject()
    let newObj = jeffJS_createObject(ctx: ctx, proto: sliceProto, classID: UInt16(ta.classID))
    let newTA = JeffJSTypedArray()
    newTA.classID = ta.classID
    typedArrayAdoptNewBuffer(newTA, newBufObj)
    newTA.byteOffset = 0
    newTA.byteLength = newByteLen
    newTA.length = count
    newTA.obj = newObj
    newObj.payload = JeffJSObjectPayload.typedArray(newTA)
    return .makeObject(newObj)
}

/// %TypedArray%.prototype.subarray(begin, end) — creates a view, no copy.
func jsTypedArray_subarray(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let (ta, _) = validateTypedArray(thisVal) else {
        return ctx.throwTypeError("not a typed array")
    }
    guard let info = typedArrayInfo(forClassID: ta.classID) else { return .undefined }

    let len = ta.length
    var start = argv.count >= 1 ? (argv[0].isInt ? Int(argv[0].toInt32()) : jeffJS_intArg(argv[0].toNumber())) : 0
    var end = argv.count >= 2 && !argv[1].isUndefined ? (argv[1].isInt ? Int(argv[1].toInt32()) : jeffJS_intArg(argv[1].toNumber())) : len

    if start < 0 { start = max(len + start, 0) }; start = min(start, len)
    if end < 0 { end = max(len + end, 0) }; end = min(end, len)
    let count = max(end - start, 0)

    let subProto = ctx.classProto[ta.classID].toObject()
    let newObj = jeffJS_createObject(ctx: ctx, proto: subProto, classID: UInt16(ta.classID))
    let newTA = JeffJSTypedArray()
    newTA.classID = ta.classID
    if let srcBuf = ta.buffer { typedArrayAdoptBuffer(newTA, srcBuf) }
    newTA.byteOffset = ta.byteOffset + start * info.bytesPerElement
    newTA.byteLength = count * info.bytesPerElement
    newTA.length = count
    newTA.obj = newObj
    newObj.payload = JeffJSObjectPayload.typedArray(newTA)
    return .makeObject(newObj)
}

/// %TypedArray%.prototype.fill(value [, start [, end]])
func jsTypedArray_fill(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let (ta, ab) = validateTypedArray(thisVal) else {
        return ctx.throwTypeError("not a typed array")
    }
    guard let info = typedArrayInfo(forClassID: ta.classID) else { return thisVal.dupValue() }
    let fillVal = argv.count >= 1 ? argv[0] : JeffJSValue.undefined
    let len = ta.length
    var start = argv.count >= 2 ? (argv[1].isInt ? Int(argv[1].toInt32()) : jeffJS_intArg(argv[1].toNumber())) : 0
    var end = argv.count >= 3 && !argv[2].isUndefined ? (argv[2].isInt ? Int(argv[2].toInt32()) : jeffJS_intArg(argv[2].toNumber())) : len
    if start < 0 { start = max(len + start, 0) }; start = min(start, len)
    if end < 0 { end = max(len + end, 0) }; end = min(end, len)

    // `start..<end` trapped when start > end (`ta.fill(0, 5, 2)`).
    if start < end {
        var data = ab.data
        for i in start..<end {
            info.writeElement(&data, offset: ta.byteOffset + i * info.bytesPerElement, value: fillVal)
        }
        ab.data = data
    }
    return thisVal.dupValue()   // the caller releases this argument; the result is a new reference
}

/// %TypedArray%.prototype.copyWithin(target, start [, end])
func jsTypedArray_copyWithin(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let (ta, ab) = validateTypedArray(thisVal) else {
        return ctx.throwTypeError("not a typed array")
    }
    guard let info = typedArrayInfo(forClassID: ta.classID) else { return thisVal.dupValue() }
    let len = ta.length
    var target = argv.count >= 1 ? (argv[0].isInt ? Int(argv[0].toInt32()) : jeffJS_intArg(argv[0].toNumber())) : 0
    var start = argv.count >= 2 ? (argv[1].isInt ? Int(argv[1].toInt32()) : jeffJS_intArg(argv[1].toNumber())) : 0
    var end = argv.count >= 3 && !argv[2].isUndefined ? (argv[2].isInt ? Int(argv[2].toInt32()) : jeffJS_intArg(argv[2].toNumber())) : len

    if target < 0 { target = max(len + target, 0) }; target = min(target, len)
    if start < 0 { start = max(len + start, 0) }; start = min(start, len)
    if end < 0 { end = max(len + end, 0) }; end = min(end, len)

    let count = min(end - start, len - target)
    // The result is a new reference: returning the borrowed `thisVal` here
    // released the typed array once too often (use-after-free, SIGSEGV).
    if count <= 0 { return thisVal.dupValue() }

    let bpe = info.bytesPerElement
    let srcByteOff = ta.byteOffset + start * bpe
    let dstByteOff = ta.byteOffset + target * bpe
    let byteCount = count * bpe

    var data = ab.data
    let temp = Array(data[srcByteOff..<(srcByteOff + byteCount)])
    data.replaceSubrange(dstByteOff..<(dstByteOff + byteCount), with: temp)
    ab.data = data
    return thisVal.dupValue()   // the caller releases this argument; the result is a new reference
}

/// %TypedArray%.prototype.reverse()
func jsTypedArray_reverse(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let (ta, ab) = validateTypedArray(thisVal) else {
        return ctx.throwTypeError("not a typed array")
    }
    guard let info = typedArrayInfo(forClassID: ta.classID) else { return thisVal.dupValue() }
    let bpe = info.bytesPerElement
    var data = ab.data
    var lo = 0
    var hi = ta.length - 1
    while lo < hi {
        let loOff = ta.byteOffset + lo * bpe
        let hiOff = ta.byteOffset + hi * bpe
        for b in 0..<bpe {
            let tmp = data[loOff + b]
            data[loOff + b] = data[hiOff + b]
            data[hiOff + b] = tmp
        }
        lo += 1; hi -= 1
    }
    ab.data = data
    return thisVal.dupValue()   // the caller releases this argument; the result is a new reference
}

/// %TypedArray%.prototype.indexOf(searchElement [, fromIndex])
func jsTypedArray_indexOf(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let (ta, ab) = validateTypedArray(thisVal) else { return .newInt32(-1) }
    guard let info = typedArrayInfo(forClassID: ta.classID) else { return .newInt32(-1) }
    let searchVal = argv.count >= 1 ? argv[0] : JeffJSValue.undefined
    var from = argv.count >= 2 ? (argv[1].isInt ? Int(argv[1].toInt32()) : jeffJS_intArg(argv[1].toNumber())) : 0
    if from < 0 { from = max(ta.length + from, 0) }
    if from >= ta.length { return .newInt32(-1) }   // `from..<length` trapped past the end

    for i in from..<ta.length {
        let elem = info.readElement(ab.data, offset: ta.byteOffset + i * info.bytesPerElement)
        if jeffJS_strictEqual(elem, searchVal) { return .newInt32(Int32(i)) }
    }
    return .newInt32(-1)
}

/// %TypedArray%.prototype.lastIndexOf(searchElement [, fromIndex])
func jsTypedArray_lastIndexOf(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let (ta, ab) = validateTypedArray(thisVal) else { return .newInt32(-1) }
    guard let info = typedArrayInfo(forClassID: ta.classID) else { return .newInt32(-1) }
    let searchVal = argv.count >= 1 ? argv[0] : JeffJSValue.undefined
    var from = argv.count >= 2 ? (argv[1].isInt ? Int(argv[1].toInt32()) : jeffJS_intArg(argv[1].toNumber())) : ta.length - 1
    if from < 0 { from = ta.length + from }
    from = min(from, ta.length - 1)

    var i = from
    while i >= 0 {
        let elem = info.readElement(ab.data, offset: ta.byteOffset + i * info.bytesPerElement)
        if jeffJS_strictEqual(elem, searchVal) { return .newInt32(Int32(i)) }
        i -= 1
    }
    return .newInt32(-1)
}

/// %TypedArray%.prototype.includes(searchElement [, fromIndex])
func jsTypedArray_includes(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let result = jsTypedArray_indexOf(ctx, thisVal, argv)
    if result.isInt { return .newBool(result.toInt32() >= 0) }
    return .newBool(false)
}

/// %TypedArray%.prototype.join([separator])
func jsTypedArray_join(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let (ta, ab) = validateTypedArray(thisVal) else {
        return .makeString(JeffJSString(swiftString: ""))
    }
    guard let info = typedArrayInfo(forClassID: ta.classID) else {
        return .makeString(JeffJSString(swiftString: ""))
    }

    var sep = ","
    if argv.count >= 1, !argv[0].isUndefined {
        guard let s = ctx.toSwiftString(argv[0]) else { return .exception }
        sep = s
    }

    // Number::toString / BigInt::toString per element: Swift's own
    // formatting wrote "3.0", "nan", "-inf", and nothing for BigInts.
    var parts = [String]()
    parts.reserveCapacity(ta.length)
    for i in 0..<ta.length {
        let val = info.readElement(ab.data, offset: ta.byteOffset + i * info.bytesPerElement)
        if val.isInt {
            parts.append(String(val.toInt32()))
        } else {
            parts.append(ctx.toSwiftString(val) ?? "")
        }
        val.freeValue()
    }
    return .makeString(JeffJSString(swiftString: parts.joined(separator: sep)))
}

/// %TypedArray%.prototype.toString() — same as Array.prototype.join
func jsTypedArray_toString(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return jsTypedArray_join(ctx, thisVal, [])
}

/// %TypedArray%.prototype.toLocaleString()
func jsTypedArray_toLocaleString(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return jsTypedArray_join(ctx, thisVal, [])
}

// MARK: - DataView

/// new DataView(buffer [, byteOffset [, byteLength]])
func jsDataView_constructor(_ ctx: JeffJSContext, _ thisVal: JeffJSValue,
                            _ argv: [JeffJSValue]) -> JeffJSValue {
    guard argv.count >= 1, let bufObj = argv[0].toObject() else {
        return ctx.throwTypeError("First argument must be an ArrayBuffer")
    }
    guard case .arrayBuffer(let ab) = bufObj.payload, !ab.detached else {
        return ctx.throwTypeError("ArrayBuffer is detached")
    }

    var byteOff = 0
    if argv.count >= 2, !argv[1].isUndefined {
        byteOff = argv[1].isInt ? Int(argv[1].toInt32()) : jeffJS_intArg(argv[1].toNumber())
    }
    if byteOff < 0 || byteOff > ab.byteLength {
        return ctx.throwTypeError("Invalid byteOffset")
    }

    var byteLen = ab.byteLength - byteOff
    if argv.count >= 3, !argv[2].isUndefined {
        byteLen = argv[2].isInt ? Int(argv[2].toInt32()) : jeffJS_intArg(argv[2].toNumber())
        if byteLen < 0 || byteOff + byteLen > ab.byteLength {
            return ctx.throwTypeError("Invalid byteLength")
        }
    }

    let obj = jeffJS_createObject(ctx: ctx, proto: nil, classID: UInt16(JeffJSClassID.dataView.rawValue))
    let ta = JeffJSTypedArray()
    typedArrayAdoptBuffer(ta, bufObj)
    ta.byteOffset = byteOff
    ta.byteLength = byteLen
    ta.length = byteLen
    ta.obj = obj
    obj.payload = JeffJSObjectPayload.typedArray(ta)
    return .makeObject(obj)
}

/// Generic DataView get method.
private func dataViewGet(_ ctx: JeffJSContext, _ thisVal: JeffJSValue,
                         _ argv: [JeffJSValue], bytesPerElement: Int,
                         reader: ([UInt8], Int, Bool) -> JeffJSValue) -> JeffJSValue {
    guard let obj = thisVal.toObject(), obj.classID == JeffJSClassID.dataView.rawValue,
          case .typedArray(let ta) = obj.payload,
          let bufObj = ta.buffer, case .arrayBuffer(let ab) = bufObj.payload, !ab.detached else {
        return ctx.throwTypeError("not a DataView or buffer detached")
    }

    guard argv.count >= 1 else { return ctx.throwTypeError("missing byte offset") }
    let byteOffset = argv[0].isInt ? Int(argv[0].toInt32()) : jeffJS_intArg(argv[0].toNumber())
    if byteOffset < 0 || byteOffset + bytesPerElement > ta.byteLength {
        return ctx.throwTypeError("byte offset out of range")
    }

    let littleEndian = argv.count >= 2 && !argv[1].isUndefined && !argv[1].isNull &&
                       (argv[1].isBool ? argv[1].toBool() : true)

    return reader(ab.data, ta.byteOffset + byteOffset, littleEndian)
}

/// Generic DataView set method.
private func dataViewSet(_ ctx: JeffJSContext, _ thisVal: JeffJSValue,
                         _ argv: [JeffJSValue], bytesPerElement: Int,
                         bigIntElement: Bool = false,
                         writer: (inout [UInt8], Int, JeffJSValue, Bool) -> Void) -> JeffJSValue {
    guard let obj = thisVal.toObject(), obj.classID == JeffJSClassID.dataView.rawValue,
          case .typedArray(let ta) = obj.payload,
          let bufObj = ta.buffer, case .arrayBuffer(let ab) = bufObj.payload, !ab.detached else {
        return ctx.throwTypeError("not a DataView or buffer detached")
    }

    guard argv.count >= 2 else { return ctx.throwTypeError("missing arguments") }
    let byteOffset = argv[0].isInt ? Int(argv[0].toInt32()) : jeffJS_intArg(argv[0].toNumber())
    if byteOffset < 0 || byteOffset + bytesPerElement > ta.byteLength {
        return ctx.throwTypeError("byte offset out of range")
    }

    let littleEndian = argv.count >= 3 && !argv[2].isUndefined && !argv[2].isNull &&
                       (argv[2].isBool ? argv[2].toBool() : true)

    var data = ab.data
    var v = argv[1]
    var ownedV = false
    if bigIntElement {
        // setBigInt64 / setBigUint64 run ToBigInt on the value.
        let b = ctx.toBigIntValue(v)
        if b.isException { return .exception }
        v = b; ownedV = true
    }
    writer(&data, ta.byteOffset + byteOffset, v, littleEndian)
    if ownedV { v.freeValue() }
    ab.data = data
    return .undefined
}

// DataView typed read helpers

func jsDataView_getInt8(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return dataViewGet(ctx, thisVal, argv, bytesPerElement: 1) { data, off, _ in
        .newInt32(Int32(Int8(bitPattern: data[off])))
    }
}

func jsDataView_getUint8(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return dataViewGet(ctx, thisVal, argv, bytesPerElement: 1) { data, off, _ in
        .newInt32(Int32(data[off]))
    }
}

func jsDataView_getInt16(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return dataViewGet(ctx, thisVal, argv, bytesPerElement: 2) { data, off, le in
        var raw = UInt16(data[off]) | (UInt16(data[off + 1]) << 8)
        if !le { raw = raw.byteSwapped }
        return .newInt32(Int32(Int16(bitPattern: raw)))
    }
}

func jsDataView_getUint16(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return dataViewGet(ctx, thisVal, argv, bytesPerElement: 2) { data, off, le in
        var raw = UInt16(data[off]) | (UInt16(data[off + 1]) << 8)
        if !le { raw = raw.byteSwapped }
        return .newInt32(Int32(raw))
    }
}

func jsDataView_getInt32(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return dataViewGet(ctx, thisVal, argv, bytesPerElement: 4) { data, off, le in
        var raw = UInt32(data[off]) | (UInt32(data[off+1]) << 8) | (UInt32(data[off+2]) << 16) | (UInt32(data[off+3]) << 24)
        if !le { raw = raw.byteSwapped }
        return .newInt32(Int32(bitPattern: raw))
    }
}

func jsDataView_getUint32(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return dataViewGet(ctx, thisVal, argv, bytesPerElement: 4) { data, off, le in
        var raw = UInt32(data[off]) | (UInt32(data[off+1]) << 8) | (UInt32(data[off+2]) << 16) | (UInt32(data[off+3]) << 24)
        if !le { raw = raw.byteSwapped }
        return .newFloat64(Double(raw))
    }
}

func jsDataView_getFloat32(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return dataViewGet(ctx, thisVal, argv, bytesPerElement: 4) { data, off, le in
        var raw = UInt32(data[off]) | (UInt32(data[off+1]) << 8) | (UInt32(data[off+2]) << 16) | (UInt32(data[off+3]) << 24)
        if !le { raw = raw.byteSwapped }
        return .newFloat64(Double(Float(bitPattern: raw)))
    }
}

func jsDataView_getFloat64(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return dataViewGet(ctx, thisVal, argv, bytesPerElement: 8) { data, off, le in
        var raw: UInt64 = 0
        for i in 0..<8 { raw |= UInt64(data[off + i]) << (i * 8) }
        if !le { raw = raw.byteSwapped }
        return .newFloat64(Double(bitPattern: raw))
    }
}

func jsDataView_getBigInt64(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return dataViewGet(ctx, thisVal, argv, bytesPerElement: 8) { data, off, le in
        var raw: UInt64 = 0
        for i in 0..<8 { raw |= UInt64(data[off + i]) << (i * 8) }
        if !le { raw = raw.byteSwapped }
        return .newBigInt(Int64(bitPattern: raw))
    }
}

func jsDataView_getBigUint64(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return dataViewGet(ctx, thisVal, argv, bytesPerElement: 8) { data, off, le in
        var raw: UInt64 = 0
        for i in 0..<8 { raw |= UInt64(data[off + i]) << (i * 8) }
        if !le { raw = raw.byteSwapped }
        return .newBigInt(JBigInt(raw))
    }
}

func jsDataView_getFloat16(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return dataViewGet(ctx, thisVal, argv, bytesPerElement: 2) { data, off, le in
        var raw = UInt16(data[off]) | (UInt16(data[off + 1]) << 8)
        if !le { raw = raw.byteSwapped }
        // Convert float16 to double
        let sign = (raw >> 15) & 1
        let exp = Int((raw >> 10) & 0x1F)
        let frac = raw & 0x3FF
        var result: Double
        if exp == 0 {
            result = frac == 0 ? 0.0 : Double(frac) / 1024.0 * pow(2.0, -14.0)
        } else if exp == 0x1F {
            result = frac == 0 ? Double.infinity : Double.nan
        } else {
            result = (1.0 + Double(frac) / 1024.0) * pow(2.0, Double(exp - 15))
        }
        if sign == 1 { result = -result }
        return .newFloat64(result)
    }
}

// DataView set methods

func jsDataView_setInt8(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return dataViewSet(ctx, thisVal, argv, bytesPerElement: 1) { data, off, val, _ in
        let v = val.isInt ? val.toInt32() : JeffJSTypeConvert.doubleToInt32(val.toNumber())  // ToInt32; `Int32(d)` trapped
        data[off] = UInt8(bitPattern: Int8(truncatingIfNeeded: v))
    }
}

func jsDataView_setUint8(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return dataViewSet(ctx, thisVal, argv, bytesPerElement: 1) { data, off, val, _ in
        let v = val.isInt ? val.toInt32() : JeffJSTypeConvert.doubleToInt32(val.toNumber())  // ToInt32; `Int32(d)` trapped
        data[off] = UInt8(truncatingIfNeeded: v)
    }
}

func jsDataView_setInt16(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return dataViewSet(ctx, thisVal, argv, bytesPerElement: 2) { data, off, val, le in
        let v = val.isInt ? val.toInt32() : JeffJSTypeConvert.doubleToInt32(val.toNumber())  // ToInt32; `Int32(d)` trapped
        var raw = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
        if !le { raw = raw.byteSwapped }
        data[off] = UInt8(raw & 0xFF); data[off+1] = UInt8((raw >> 8) & 0xFF)
    }
}

func jsDataView_setUint16(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return dataViewSet(ctx, thisVal, argv, bytesPerElement: 2) { data, off, val, le in
        let v = val.isInt ? val.toInt32() : JeffJSTypeConvert.doubleToInt32(val.toNumber())  // ToInt32; `Int32(d)` trapped
        var raw = UInt16(truncatingIfNeeded: v)
        if !le { raw = raw.byteSwapped }
        data[off] = UInt8(raw & 0xFF); data[off+1] = UInt8((raw >> 8) & 0xFF)
    }
}

func jsDataView_setInt32(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return dataViewSet(ctx, thisVal, argv, bytesPerElement: 4) { data, off, val, le in
        let v = val.isInt ? val.toInt32() : JeffJSTypeConvert.doubleToInt32(val.toNumber())  // ToInt32; `Int32(d)` trapped
        var raw = UInt32(bitPattern: v)
        if !le { raw = raw.byteSwapped }
        data[off] = UInt8(raw & 0xFF); data[off+1] = UInt8((raw>>8)&0xFF); data[off+2] = UInt8((raw>>16)&0xFF); data[off+3] = UInt8((raw>>24)&0xFF)
    }
}

func jsDataView_setUint32(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return dataViewSet(ctx, thisVal, argv, bytesPerElement: 4) { data, off, val, le in
        let d = val.isInt ? Double(val.toInt32()) : val.toNumber()
        var raw = JeffJSTypeConvert.doubleToUInt32(d)  // ToUint32; `UInt32(d)` trapped
        if !le { raw = raw.byteSwapped }
        data[off] = UInt8(raw & 0xFF); data[off+1] = UInt8((raw>>8)&0xFF); data[off+2] = UInt8((raw>>16)&0xFF); data[off+3] = UInt8((raw>>24)&0xFF)
    }
}

func jsDataView_setFloat32(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return dataViewSet(ctx, thisVal, argv, bytesPerElement: 4) { data, off, val, le in
        let d = val.isInt ? Double(val.toInt32()) : val.toNumber()
        var raw = Float(d).bitPattern
        if !le { raw = raw.byteSwapped }
        data[off] = UInt8(raw & 0xFF); data[off+1] = UInt8((raw>>8)&0xFF); data[off+2] = UInt8((raw>>16)&0xFF); data[off+3] = UInt8((raw>>24)&0xFF)
    }
}

func jsDataView_setFloat64(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return dataViewSet(ctx, thisVal, argv, bytesPerElement: 8) { data, off, val, le in
        let d = val.isInt ? Double(val.toInt32()) : val.toNumber()
        var raw = d.bitPattern
        if !le { raw = raw.byteSwapped }
        for i in 0..<8 { data[off + i] = UInt8((raw >> (i * 8)) & 0xFF) }
    }
}

func jsDataView_setBigInt64(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return dataViewSet(ctx, thisVal, argv, bytesPerElement: 8, bigIntElement: true) { data, off, val, le in
        var raw: UInt64 = val.isBigInt ? val.bigIntValue.lowUInt64 : 0
        if !le { raw = raw.byteSwapped }
        for i in 0..<8 { data[off + i] = UInt8((raw >> (i * 8)) & 0xFF) }
    }
}

func jsDataView_setBigUint64(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return dataViewSet(ctx, thisVal, argv, bytesPerElement: 8, bigIntElement: true) { data, off, val, le in
        var raw: UInt64 = val.isBigInt ? val.bigIntValue.lowUInt64 : 0
        if !le { raw = raw.byteSwapped }
        for i in 0..<8 { data[off + i] = UInt8((raw >> (i * 8)) & 0xFF) }
    }
}

func jsDataView_setFloat16(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    return dataViewSet(ctx, thisVal, argv, bytesPerElement: 2) { data, off, val, le in
        let d = val.isInt ? Double(val.toInt32()) : val.toNumber()
        let f32 = Float(d)
        let bits = f32.bitPattern
        let sign = UInt16((bits >> 31) & 1)
        let exp32 = Int((bits >> 23) & 0xFF) - 127
        let frac32 = bits & 0x7FFFFF
        var f16: UInt16
        if exp32 > 15 { f16 = (sign << 15) | 0x7C00 }
        else if exp32 < -24 { f16 = sign << 15 }
        else if exp32 < -14 { let shift = -14 - exp32; f16 = (sign << 15) | UInt16(((frac32 | 0x800000) >> (13 + shift)) & 0x3FF) }
        else { f16 = (sign << 15) | (UInt16(exp32 + 15) << 10) | UInt16((frac32 >> 13) & 0x3FF) }
        if !le { f16 = f16.byteSwapped }
        data[off] = UInt8(f16 & 0xFF); data[off+1] = UInt8((f16 >> 8) & 0xFF)
    }
}

// MARK: - DataView getters for buffer, byteLength, byteOffset

func jsDataView_buffer(_ ctx: JeffJSContext, _ thisVal: JeffJSValue) -> JeffJSValue {
    guard let obj = thisVal.toObject(), obj.classID == JeffJSClassID.dataView.rawValue,
          case .typedArray(let ta) = obj.payload, let buf = ta.buffer else { return .undefined }
    return typedArrayBufferValue(buf)
}

func jsDataView_byteLength(_ ctx: JeffJSContext, _ thisVal: JeffJSValue) -> JeffJSValue {
    guard let obj = thisVal.toObject(), obj.classID == JeffJSClassID.dataView.rawValue,
          case .typedArray(let ta) = obj.payload else { return .newInt32(0) }
    return .newInt32(Int32(ta.byteLength))
}

func jsDataView_byteOffset(_ ctx: JeffJSContext, _ thisVal: JeffJSValue) -> JeffJSValue {
    guard let obj = thisVal.toObject(), obj.classID == JeffJSClassID.dataView.rawValue,
          case .typedArray(let ta) = obj.payload else { return .newInt32(0) }
    return .newInt32(Int32(ta.byteOffset))
}

// MARK: - TypedArray.from() static method

/// `TypedArray.from(source, mapFn?, thisArg?)` — Create a typed array from an iterable or array-like.
func jsTypedArray_from(_ ctx: JeffJSContext, _ thisVal: JeffJSValue,
                       _ argv: [JeffJSValue], classID: Int) -> JeffJSValue {
    guard let info = typedArrayInfo(forClassID: classID) else {
        return ctx.throwTypeError("Unknown typed array type")
    }
    guard argv.count >= 1 else {
        return ctx.throwTypeError("TypedArray.from requires at least 1 argument")
    }

    let source = argv[0]
    let hasMapFn = argv.count >= 2 && !argv[1].isUndefined
    let mapFn = hasMapFn ? argv[1] : JeffJSValue.undefined
    let thisArg = argv.count >= 3 ? argv[2] : JeffJSValue.undefined

    if hasMapFn && !mapFn.isFunction {
        return ctx.throwTypeError("TypedArray.from: mapFn is not a function")
    }

    // Collect elements from the source
    var elements = [JeffJSValue]()

    if source.isObject, let srcObj = source.toObject() {
        // Check if source is a typed array
        if case .typedArray(let srcTA) = srcObj.payload,
           let srcBuf = srcTA.buffer,
           case .arrayBuffer(let srcAB) = srcBuf.payload,
           let srcInfo = typedArrayInfo(forClassID: srcTA.classID) {
            for i in 0..<srcTA.length {
                let val = srcInfo.readElement(srcAB.data, offset: srcTA.byteOffset + i * srcInfo.bytesPerElement)
                elements.append(val)
            }
        } else {
            // Array-like or iterable: read .length and index elements
            let lenVal = ctx.getPropertyStr(obj: source, name: "length")
            let len: Int
            if lenVal.isInt { len = Int(lenVal.toInt32()) }
            else if lenVal.isFloat64 { len = Int(lenVal.toFloat64()) }
            else { len = 0 }

            for i in 0..<len {
                let elem = ctx.getPropertyStr(obj: source, name: String(i))
                elements.append(elem)
            }
        }
    }

    // Apply mapFn if provided
    if hasMapFn {
        for i in 0..<elements.count {
            let mapped = ctx.call(mapFn, this: thisArg, args: [elements[i], .newInt32(Int32(i))])
            if mapped.isException { return .exception }
            elements[i] = mapped
        }
    }

    // Create the typed array with the collected elements
    let count = elements.count
    let byteLen = count * info.bytesPerElement
    let ab = JeffJSArrayBuffer(byteLength: byteLen)

    var data = ab.data
    for i in 0..<count {
        info.writeElement(&data, offset: i * info.bytesPerElement, value: elements[i])
    }
    ab.data = data

    let bufObj = jeffJS_createObject(ctx: ctx, proto: nil, classID: UInt16(JeffJSClassID.arrayBuffer.rawValue))
    bufObj.payload = JeffJSObjectPayload.arrayBuffer(ab)

    let fromProto = ctx.classProto[classID].toObject()
    let obj = jeffJS_createObject(ctx: ctx, proto: fromProto, classID: UInt16(classID))
    let ta = JeffJSTypedArray()
    ta.classID = classID
    typedArrayAdoptNewBuffer(ta, bufObj)
    ta.byteOffset = 0
    ta.byteLength = byteLen
    ta.length = count
    ta.obj = obj
    obj.payload = JeffJSObjectPayload.typedArray(ta)
    return .makeObject(obj)
}

// MARK: - TypedArray.of() static method

/// `TypedArray.of(...items)` — Create a typed array from arguments.
func jsTypedArray_of(_ ctx: JeffJSContext, _ thisVal: JeffJSValue,
                     _ argv: [JeffJSValue], classID: Int) -> JeffJSValue {
    guard let info = typedArrayInfo(forClassID: classID) else {
        return ctx.throwTypeError("Unknown typed array type")
    }

    let count = argv.count
    let byteLen = count * info.bytesPerElement
    let ab = JeffJSArrayBuffer(byteLength: byteLen)

    var data = ab.data
    for i in 0..<count {
        info.writeElement(&data, offset: i * info.bytesPerElement, value: argv[i])
    }
    ab.data = data

    let bufObj = jeffJS_createObject(ctx: ctx, proto: nil, classID: UInt16(JeffJSClassID.arrayBuffer.rawValue))
    bufObj.payload = JeffJSObjectPayload.arrayBuffer(ab)

    let ofProto = ctx.classProto[classID].toObject()
    let obj = jeffJS_createObject(ctx: ctx, proto: ofProto, classID: UInt16(classID))
    let ta = JeffJSTypedArray()
    ta.classID = classID
    typedArrayAdoptNewBuffer(ta, bufObj)
    ta.byteOffset = 0
    ta.byteLength = byteLen
    ta.length = count
    ta.obj = obj
    obj.payload = JeffJSObjectPayload.typedArray(ta)
    return .makeObject(obj)
}

// MARK: - %TypedArray%.prototype iteration and callback methods

/// The typed array behind `thisVal`, or a TypeError (ValidateTypedArray:
/// not a typed array, or its buffer is detached).
private func typedArrayReceiver(_ ctx: JeffJSContext, _ thisVal: JeffJSValue,
                                _ method: String)
    -> (ta: JeffJSTypedArray, ab: JeffJSArrayBuffer, info: TypedArrayElementInfo)? {
    guard let (ta, ab) = validateTypedArray(thisVal),
          let info = typedArrayInfo(forClassID: ta.classID) else {
        _ = ctx.throwTypeError(message: "%TypedArray%.prototype.\(method): not a TypedArray")
        return nil
    }
    return (ta, ab, info)
}

/// Element `i` of the view, re-read through the buffer each time (a callback
/// may have written to it). Out of range (or a detached buffer) reads as
/// undefined.
private func typedArrayElement(_ thisVal: JeffJSValue, _ i: Int) -> JeffJSValue {
    guard let (ta, ab) = validateTypedArray(thisVal), i < ta.length,
          let info = typedArrayInfo(forClassID: ta.classID) else { return .undefined }
    return info.readElement(ab.data, offset: ta.byteOffset + i * info.bytesPerElement)
}

/// `%TypedArray%.prototype.values()` / `keys()` / `entries()` and
/// `[Symbol.iterator]` (the same function object as `values`): an Array
/// Iterator over the view (QuickJS js_create_array_iterator accepts typed
/// arrays after validating them).
func jsTypedArray_iterator(_ ctx: JeffJSContext, _ thisVal: JeffJSValue,
                           kind: JeffJSArrayIteratorKind, method: String) -> JeffJSValue {
    guard typedArrayReceiver(ctx, thisVal, method) != nil else { return .exception }
    // createArrayIterator keeps the target: hand it its own reference.
    return ctx.createArrayIterator(obj: thisVal.dupValue(), kind: kind.rawValue)
}

/// `get %TypedArray%.prototype[@@toStringTag]`: the concrete constructor's
/// name for a typed array, undefined for anything else (no TypeError).
func jsTypedArray_toStringTag(_ ctx: JeffJSContext, _ thisVal: JeffJSValue) -> JeffJSValue {
    guard let obj = thisVal.toObject(), case .typedArray(let ta) = obj.payload,
          let info = typedArrayInfo(forClassID: ta.classID) else { return .undefined }
    return ctx.newStringValue(info.name)
}

/// The callback methods whose spec algorithm is the Array one over the
/// view's elements (forEach, every, some, find*, reduce*): validate the
/// receiver as a typed array, then run the generic Array.prototype
/// implementation, which reads `length` and the indexed elements.
func jsTypedArray_arrayGeneric(
    _ method: String,
    _ impl: @escaping (JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue
) -> (JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue {
    return { ctx, thisVal, argv in
        guard typedArrayReceiver(ctx, thisVal, method) != nil else { return .exception }
        return impl(ctx, thisVal, argv)
    }
}

/// A new typed array of `classID` holding `values` (borrowed).
private func typedArrayFromValues(_ ctx: JeffJSContext, classID: Int,
                                  _ values: [JeffJSValue]) -> JeffJSValue {
    return jsTypedArray_of(ctx, .undefined, values, classID: classID)
}

private func freeAll(_ values: [JeffJSValue]) {
    for v in values { v.freeValue() }
}

/// `%TypedArray%.prototype.map(callbackfn [, thisArg])` — same element type.
func jsTypedArray_map(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let (ta, _, _) = typedArrayReceiver(ctx, thisVal, "map") else { return .exception }
    let fn = argv.count > 0 ? argv[0] : .undefined
    guard ctx.isCallable(fn) else { return ctx.throwTypeError(message: "map: callback is not a function") }
    let thisArg = argv.count > 1 ? argv[1] : .undefined
    let len = ta.length
    var out: [JeffJSValue] = []
    out.reserveCapacity(len)
    for i in 0..<len {
        let v = typedArrayElement(thisVal, i)
        let r = ctx.call(fn, this: thisArg, args: [v, .newInt32(Int32(i)), thisVal])
        v.freeValue()
        if r.isException { freeAll(out); return r }
        out.append(r)
    }
    let result = typedArrayFromValues(ctx, classID: ta.classID, out)
    freeAll(out)
    return result
}

/// `%TypedArray%.prototype.filter(callbackfn [, thisArg])` — same element type.
func jsTypedArray_filter(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let (ta, _, _) = typedArrayReceiver(ctx, thisVal, "filter") else { return .exception }
    let fn = argv.count > 0 ? argv[0] : .undefined
    guard ctx.isCallable(fn) else { return ctx.throwTypeError(message: "filter: callback is not a function") }
    let thisArg = argv.count > 1 ? argv[1] : .undefined
    var kept: [JeffJSValue] = []
    for i in 0..<ta.length {
        let v = typedArrayElement(thisVal, i)
        let r = ctx.call(fn, this: thisArg, args: [v, .newInt32(Int32(i)), thisVal])
        if r.isException { v.freeValue(); freeAll(kept); return r }
        if ctx.toBoolFree(r) { kept.append(v) } else { v.freeValue() }
    }
    let result = typedArrayFromValues(ctx, classID: ta.classID, kept)
    freeAll(kept)
    return result
}

/// The view's elements in `%TypedArray%.prototype.sort` order, or nil after
/// a throwing comparator. Without a comparator the order is numeric (NaN
/// last, -0 before +0); BigInt views compare their 64-bit integers exactly.
private func typedArraySortedElements(_ ctx: JeffJSContext, _ ta: JeffJSTypedArray,
                                      _ ab: JeffJSArrayBuffer, _ info: TypedArrayElementInfo,
                                      comparefn: JeffJSValue) -> [JeffJSValue]? {
    let n = ta.length
    let stride = info.bytesPerElement
    if comparefn.isUndefined {
        if info.isBigInt {
            let data = ab.data
            func raw(_ i: Int) -> UInt64 {
                var r: UInt64 = 0
                let base = ta.byteOffset + i * 8
                for b in 0..<8 { r |= UInt64(data[base + b]) << (8 * UInt64(b)) }
                return r
            }
            var idx = Array(0..<n)
            if info.isSigned {
                idx.sort { Int64(bitPattern: raw($0)) < Int64(bitPattern: raw($1)) }
            } else {
                idx.sort { raw($0) < raw($1) }
            }
            return idx.map { info.readElement(data, offset: ta.byteOffset + $0 * stride) }
        }
        var vals: [(Double, JeffJSValue)] = (0..<n).map { i in
            let v = info.readElement(ab.data, offset: ta.byteOffset + i * stride)
            return (v.isInt ? Double(v.toInt32()) : v.toNumber(), v)
        }
        vals.sort { a, b in
            let x = a.0, y = b.0
            if x.isNaN { return false }
            if y.isNaN { return true }
            if x < y { return true }
            if x > y { return false }
            return x == 0 && x.sign == .minus && y.sign == .plus
        }
        return vals.map { $0.1 }
    }
    var vals: [JeffJSValue] = (0..<n).map {
        info.readElement(ab.data, offset: ta.byteOffset + $0 * stride)
    }
    struct Thrown: Error {}
    do {
        try vals.sort { a, b in
            let r = ctx.call(comparefn, this: .undefined, args: [a, b])
            if r.isException { throw Thrown() }
            let d = r.isInt ? Double(r.toInt32()) : (ctx.toFloat64(r) ?? .nan)
            r.freeValue()
            return d < 0
        }
    } catch {
        freeAll(vals)
        return nil
    }
    return vals
}

/// `%TypedArray%.prototype.sort([comparefn])` — in place, returns the view.
func jsTypedArray_sort(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let comparefn = argv.count > 0 ? argv[0] : .undefined
    if !comparefn.isUndefined && !ctx.isCallable(comparefn) {
        return ctx.throwTypeError(message: "sort: comparator must be a function")
    }
    guard let (ta, ab, info) = typedArrayReceiver(ctx, thisVal, "sort") else { return .exception }
    guard let sorted = typedArraySortedElements(ctx, ta, ab, info, comparefn: comparefn) else {
        return .exception
    }
    // A comparator may have detached or shrunk the buffer: write what fits.
    if let (ta2, ab2) = validateTypedArray(thisVal) {
        var data = ab2.data
        for (i, v) in sorted.enumerated() where i < ta2.length {
            info.writeElement(&data, offset: ta2.byteOffset + i * info.bytesPerElement, value: v)
        }
        ab2.data = data
    }
    freeAll(sorted)
    return thisVal.dupValue()
}

/// `%TypedArray%.prototype.toSorted([comparefn])` — a sorted copy.
func jsTypedArray_toSorted(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    let comparefn = argv.count > 0 ? argv[0] : .undefined
    if !comparefn.isUndefined && !ctx.isCallable(comparefn) {
        return ctx.throwTypeError(message: "toSorted: comparator must be a function")
    }
    guard let (ta, ab, info) = typedArrayReceiver(ctx, thisVal, "toSorted") else { return .exception }
    guard let sorted = typedArraySortedElements(ctx, ta, ab, info, comparefn: comparefn) else {
        return .exception
    }
    let result = typedArrayFromValues(ctx, classID: ta.classID, sorted)
    freeAll(sorted)
    return result
}

/// `%TypedArray%.prototype.toReversed()` — a reversed copy.
func jsTypedArray_toReversed(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let (ta, ab, info) = typedArrayReceiver(ctx, thisVal, "toReversed") else { return .exception }
    let vals: [JeffJSValue] = (0..<ta.length).reversed().map {
        info.readElement(ab.data, offset: ta.byteOffset + $0 * info.bytesPerElement)
    }
    let result = typedArrayFromValues(ctx, classID: ta.classID, vals)
    freeAll(vals)
    return result
}

/// `%TypedArray%.prototype.with(index, value)` — a copy with one element
/// replaced; RangeError when the index is outside the view.
func jsTypedArray_with(_ ctx: JeffJSContext, _ thisVal: JeffJSValue, _ argv: [JeffJSValue]) -> JeffJSValue {
    guard let (ta, ab, info) = typedArrayReceiver(ctx, thisVal, "with") else { return .exception }
    let len = ta.length
    var rel = ctx.toIntegerOrInfinity(argv.count > 0 ? argv[0] : .undefined)
    if rel < 0 { rel += Double(len) }
    guard rel >= 0, rel < Double(len) else { return ctx.throwRangeError(message: "invalid array index") }
    let at = Int(rel)
    var vals: [JeffJSValue] = (0..<len).map {
        info.readElement(ab.data, offset: ta.byteOffset + $0 * info.bytesPerElement)
    }
    let replacement = argv.count > 1 ? argv[1] : .undefined
    vals[at].freeValue()
    vals[at] = replacement   // borrowed: not freed below
    let result = typedArrayFromValues(ctx, classID: ta.classID, vals)
    for (i, v) in vals.enumerated() where i != at { v.freeValue() }
    return result
}

// MARK: - Strict Equality Helper

/// Simple strict equality for typed array element comparison.
private func jeffJS_strictEqual(_ a: JeffJSValue, _ b: JeffJSValue) -> Bool {
    if !JeffJSValue.sameTag(a, b) { return false }
    if a.isInt && b.isInt { return a.toInt32() == b.toInt32() }
    if a.isFloat64 && b.isFloat64 { return a.toFloat64() == b.toFloat64() }
    return a == b
}

// MARK: - Getter helper for typed array / ArrayBuffer properties

/// Add a getter property to a prototype object (for use by TypedArray/ArrayBuffer registration).
func jeffJS_addGetterProperty(
    ctx: JeffJSContext, proto: JeffJSObject, name: String,
    getter fn: @escaping (JeffJSContext, JeffJSValue) -> JeffJSValue
) {
    let getterObj = JeffJSObject()
    getterObj.classID = JeffJSClassID.cFunction.rawValue
    getterObj.extensible = true
    getterObj.payload = .cFunc(
        realm: ctx,
        cFunction: .getter(fn),
        length: 0,
        cproto: UInt8(JS_CFUNC_GETTER),
        magic: 0
    )
    // Give the getter a shape so property lookup works, over
    // Function.prototype: `Object.getOwnPropertyDescriptor(P, 'length').get`
    // is an ordinary function (`.call`, `.name`) in every engine.
    let fnProto = ctx.functionProto.isObject ? ctx.functionProto.toObject() : nil
    getterObj.shape = jeffJS_rootShape(ctx, proto: fnProto)
    getterObj.proto = fnProto
    getterObj.clearProps()

    let atom = ctx.rt.findAtom(name)
    jeffJS_addProperty(ctx: ctx, obj: proto, atom: atom, flags: [.configurable, .getset])
    let propIdx = proto.propValues.count - 1
    // The accessor slot is a counted edge (freeObject releases it), so the
    // getter needs the ARC retain `makeObject` would have taken; this one is
    // built by hand.
    _ = Unmanaged.passRetained(getterObj)
    if propIdx >= 0 {
        proto.setPropEntry(at: propIdx, .getset(getter: getterObj, setter: nil))
    }
    ctx.rt.freeAtom(atom)
}

// MARK: - Initialization

/// Install ArrayBuffer, SharedArrayBuffer, all 12 TypedArray types, and DataView on the global.
func jeffJS_initTypedArrays(ctx: JeffJSContext, globalObj: JeffJSObject) {
    // ArrayBuffer
    let abCtor = jeffJS_createObject(ctx: ctx, proto: nil, classID: UInt16(JeffJSClassID.cFunction.rawValue))
    abCtor.isConstructor = true
    jeffJS_defineBuiltinFunc(ctx: ctx, obj: abCtor, name: "isView", length: 1, func: jsArrayBuffer_isView)
    jeffJS_setPropertyStr(ctx: ctx, obj: globalObj, name: "ArrayBuffer", value: .makeObject(abCtor))

    // SharedArrayBuffer
    let sabCtor = jeffJS_createObject(ctx: ctx, proto: nil, classID: UInt16(JeffJSClassID.cFunction.rawValue))
    sabCtor.isConstructor = true
    jeffJS_setPropertyStr(ctx: ctx, obj: globalObj, name: "SharedArrayBuffer", value: .makeObject(sabCtor))

    // DataView
    let dvCtor = jeffJS_createObject(ctx: ctx, proto: nil, classID: UInt16(JeffJSClassID.cFunction.rawValue))
    dvCtor.isConstructor = true
    jeffJS_setPropertyStr(ctx: ctx, obj: globalObj, name: "DataView", value: .makeObject(dvCtor))

    // Typed arrays
    for info in typedArrayInfoTable {
        let ctor = jeffJS_createObject(ctx: ctx, proto: nil, classID: UInt16(JeffJSClassID.cFunction.rawValue))
        ctor.isConstructor = true
        jeffJS_setPropertyStr(ctx: ctx, obj: globalObj, name: info.name, value: .makeObject(ctor))
    }
}
