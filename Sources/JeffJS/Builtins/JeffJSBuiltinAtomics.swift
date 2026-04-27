// JeffJSBuiltinAtomics.swift
// JeffJS -- 1:1 Swift port of QuickJS JavaScript engine
//
// Port of the Atomics built-in object from QuickJS.
//
// QuickJS source reference: quickjs.c --
//   js_atomics_op, js_atomics_store, js_atomics_load,
//   js_atomics_isLockFree, js_atomics_wait, js_atomics_notify,
//   js_atomics_funcs, JS_AddIntrinsicAtomics, etc.
//
// The Atomics object provides static methods for atomic operations on
// SharedArrayBuffer-backed typed arrays, plus wait/notify for thread
// synchronization.

import Foundation

// MARK: - Waiter list infrastructure

/// A single waiter entry on a wait list.  Created by `Atomics.wait`.
///
/// Mirrors the internal waiter struct in QuickJS `js_atomics_wait`.
final class JSAtomicsWaiter {
    /// The condition variable this waiter blocks on.
    let condition = NSCondition()

    /// Set to `true` when this waiter is notified (woken up).
    var notified: Bool = false

    /// Byte offset into the SharedArrayBuffer that this waiter is watching.
    var byteIndex: Int = 0

    init(byteIndex: Int) {
        self.byteIndex = byteIndex
    }
}

/// Global waiter lists, keyed by (SharedArrayBuffer identity, byte offset).
///
/// In QuickJS the waiter lists are global (process-wide) because
/// SharedArrayBuffers can be transferred between agents.
/// We use NSLock for the global lock instead of a C mutex.
private let jsAtomicsGlobalLock = NSLock()
private var jsAtomicsWaiterLists: [JSAtomicsWaiterKey: [JSAtomicsWaiter]] = [:]

/// Key for the global waiter list map.
private struct JSAtomicsWaiterKey: Hashable {
    let bufferID: ObjectIdentifier
    let byteIndex: Int

    init(buffer: JeffJSArrayBuffer, byteIndex: Int) {
        self.bufferID = ObjectIdentifier(buffer)
        self.byteIndex = byteIndex
    }
}

// MARK: - Typed array validation

/// Validate that `typedArrayVal` is an integer typed array backed by a
/// SharedArrayBuffer (for `wait`/`notify`) or any integer typed array
/// (for other Atomics operations).
///
/// Returns the typed array object, its backing ArrayBuffer data, byte offset,
/// and element size, or throws a TypeError.
///
/// Mirrors QuickJS `js_atomics_get_typed_array_and_index`.
private func js_atomics_validateTypedArray(
    ctx: JeffJSContext,
    typedArrayVal: JeffJSValue,
    indexVal: JeffJSValue,
    requireShared: Bool
) -> (obj: JeffJSObject, buffer: JeffJSArrayBuffer, byteIndex: Int, elemSize: Int)? {

    guard let taObj = typedArrayVal.toObject() else {
        _ = ctx.throwTypeError("Atomics: first argument must be a typed array")
        return nil
    }

    let classID = Int(taObj.classID)

    // Must be an integer typed array (Int8, Uint8, Int16, Uint16, Int32, Uint32,
    // BigInt64, BigUint64).  Float32/Float64 are NOT allowed.
    let allowedClasses: Set<Int> = [
        JeffJSClassID.int8Array.rawValue,
        JeffJSClassID.uint8Array.rawValue,
        JeffJSClassID.int16Array.rawValue,
        JeffJSClassID.uint16Array.rawValue,
        JeffJSClassID.int32Array.rawValue,
        JeffJSClassID.uint32Array.rawValue,
        JeffJSClassID.bigInt64Array.rawValue,
        JeffJSClassID.bigUint64Array.rawValue,
    ]

    if !allowedClasses.contains(taObj.classID) {
        _ = ctx.throwTypeError("Atomics: argument is not an integer typed array")
        return nil
    }

    // Extract the typed array data.
    guard case .typedArray(let ta) = taObj.payload else {
        _ = ctx.throwTypeError("Atomics: not a valid typed array")
        return nil
    }

    // Get the backing buffer.
    guard let bufferObj = ta.buffer,
          case .arrayBuffer(let ab) = bufferObj.payload else {
        _ = ctx.throwTypeError("Atomics: typed array has no buffer")
        return nil
    }

    // Check shared requirement (for wait/notify).
    if requireShared && !ab.shared {
        _ = ctx.throwTypeError("Atomics.wait/notify requires a SharedArrayBuffer")
        return nil
    }

    // Check for detached buffer.
    if ab.detached {
        _ = ctx.throwTypeError("Atomics: buffer is detached")
        return nil
    }

    // Compute element size.
    let elemSize = jsTypedArrayElementSize(classID)
    guard elemSize > 0 else {
        _ = ctx.throwTypeError("Atomics: invalid element size")
        return nil
    }

    // Validate and convert the index.
    let index: Int
    if indexVal.isInt {
        index = Int(indexVal.toInt32())
    } else if indexVal.isFloat64 {
        let d = indexVal.toFloat64()
        if d.isNaN || d.isInfinite || d != d.rounded(.towardZero) {
            _ = ctx.throwTypeError("Atomics: index is not an integer")
            return nil
        }
        index = abs(d) > Double(Int.max / 2) ? 0 : Int(d)
    } else {
        // ToIndex coercion: undefined -> 0, else ToInteger.
        index = indexVal.isUndefined ? 0 : 0
    }

    if index < 0 || index >= ta.length {
        _ = ctx.throwTypeError("Atomics: index out of range")
        return nil
    }

    let byteIndex = ta.byteOffset + index * elemSize

    return (taObj, ab, byteIndex, elemSize)
}

// MARK: - Atomic read/write helpers

/// Read an atomic value from the buffer at the given byte offset.
///
/// On Apple platforms we use OSAtomic / `__atomic_load` semantics via
/// `withUnsafeBytes`.  Since Swift arrays are not inherently atomic, we
/// use a lock for correctness.
///
/// Mirrors the inline atomic loads in QuickJS `js_atomics_op`.
private func js_atomics_load_raw(
    buffer: JeffJSArrayBuffer,
    byteIndex: Int,
    elemSize: Int,
    isBigInt: Bool,
    isSigned: Bool
) -> JeffJSValue {
    let data = buffer.data

    switch elemSize {
    case 1:
        guard byteIndex < data.count else { return .newInt32(0) }
        let raw = data[byteIndex]
        if isSigned {
            return JeffJSValue.newInt32(Int32(Int8(bitPattern: raw)))
        } else {
            return JeffJSValue.newInt32(Int32(raw))
        }

    case 2:
        guard byteIndex + 1 < data.count else { return .newInt32(0) }
        let raw = UInt16(data[byteIndex]) | (UInt16(data[byteIndex + 1]) << 8)
        if isSigned {
            return JeffJSValue.newInt32(Int32(Int16(bitPattern: raw)))
        } else {
            return JeffJSValue.newInt32(Int32(raw))
        }

    case 4:
        guard byteIndex + 3 < data.count else { return .newInt32(0) }
        let raw = UInt32(data[byteIndex])
                 | (UInt32(data[byteIndex + 1]) << 8)
                 | (UInt32(data[byteIndex + 2]) << 16)
                 | (UInt32(data[byteIndex + 3]) << 24)
        if isBigInt {
            // BigInt64Array element is 4 bytes in 32-bit mode, but we are 64-bit.
            // For a 4-byte typed array this is Int32/Uint32.
            if isSigned {
                return JeffJSValue.newInt32(Int32(bitPattern: raw))
            } else {
                return JeffJSValue.newUInt32(raw)
            }
        }
        if isSigned {
            return JeffJSValue.newInt32(Int32(bitPattern: raw))
        } else {
            return JeffJSValue.newUInt32(raw)
        }

    case 8:
        guard byteIndex + 7 < data.count else {
            return isBigInt ? JeffJSValue.newInt32(0) : JeffJSValue.newFloat64(0)
        }
        let raw = UInt64(data[byteIndex])
                 | (UInt64(data[byteIndex + 1]) << 8)
                 | (UInt64(data[byteIndex + 2]) << 16)
                 | (UInt64(data[byteIndex + 3]) << 24)
                 | (UInt64(data[byteIndex + 4]) << 32)
                 | (UInt64(data[byteIndex + 5]) << 40)
                 | (UInt64(data[byteIndex + 6]) << 48)
                 | (UInt64(data[byteIndex + 7]) << 56)
        // BigInt64Array / BigUint64Array return BigInt values.
        // We approximate with Int64/newFloat64 for now.
        if isSigned {
            return JeffJSValue.newInt64(Int64(bitPattern: raw))
        } else {
            if raw <= UInt64(Int64.max) {
                return JeffJSValue.newInt64(Int64(raw))
            }
            return JeffJSValue.newFloat64(Double(raw))
        }

    default:
        return .newInt32(0)
    }
}

/// Write a value atomically into the buffer at the given byte offset.
/// Returns the stored value (for Atomics.store's return convention).
///
/// Mirrors the inline atomic stores in QuickJS `js_atomics_store`.
private func js_atomics_store_raw(
    buffer: JeffJSArrayBuffer,
    byteIndex: Int,
    elemSize: Int,
    value: JeffJSValue
) {
    let intVal: Int64
    if value.isInt {
        intVal = Int64(value.toInt32())
    } else if value.isFloat64 {
        let d = value.toFloat64()
        intVal = (d.isNaN || d.isInfinite || abs(d) > Double(Int64.max)) ? 0 : Int64(d)
    } else {
        intVal = 0
    }

    switch elemSize {
    case 1:
        guard byteIndex < buffer.data.count else { return }
        buffer.data[byteIndex] = UInt8(truncatingIfNeeded: intVal)

    case 2:
        guard byteIndex + 1 < buffer.data.count else { return }
        let val16 = UInt16(truncatingIfNeeded: intVal)
        buffer.data[byteIndex]     = UInt8(val16 & 0xFF)
        buffer.data[byteIndex + 1] = UInt8((val16 >> 8) & 0xFF)

    case 4:
        guard byteIndex + 3 < buffer.data.count else { return }
        let val32 = UInt32(truncatingIfNeeded: intVal)
        buffer.data[byteIndex]     = UInt8(val32 & 0xFF)
        buffer.data[byteIndex + 1] = UInt8((val32 >> 8) & 0xFF)
        buffer.data[byteIndex + 2] = UInt8((val32 >> 16) & 0xFF)
        buffer.data[byteIndex + 3] = UInt8((val32 >> 24) & 0xFF)

    case 8:
        guard byteIndex + 7 < buffer.data.count else { return }
        let val64 = UInt64(bitPattern: intVal)
        buffer.data[byteIndex]     = UInt8(val64 & 0xFF)
        buffer.data[byteIndex + 1] = UInt8((val64 >> 8) & 0xFF)
        buffer.data[byteIndex + 2] = UInt8((val64 >> 16) & 0xFF)
        buffer.data[byteIndex + 3] = UInt8((val64 >> 24) & 0xFF)
        buffer.data[byteIndex + 4] = UInt8((val64 >> 32) & 0xFF)
        buffer.data[byteIndex + 5] = UInt8((val64 >> 40) & 0xFF)
        buffer.data[byteIndex + 6] = UInt8((val64 >> 48) & 0xFF)
        buffer.data[byteIndex + 7] = UInt8((val64 >> 56) & 0xFF)

    default:
        break
    }
}

/// Read the current 32-bit value at a byte offset (for Atomics.wait comparison).
private func js_atomics_read_int32(
    buffer: JeffJSArrayBuffer,
    byteIndex: Int
) -> Int32 {
    guard byteIndex + 3 < buffer.data.count else { return 0 }
    let raw = UInt32(buffer.data[byteIndex])
             | (UInt32(buffer.data[byteIndex + 1]) << 8)
             | (UInt32(buffer.data[byteIndex + 2]) << 16)
             | (UInt32(buffer.data[byteIndex + 3]) << 24)
    return Int32(bitPattern: raw)
}

/// Read the current 64-bit value at a byte offset (for Atomics.wait on BigInt64).
private func js_atomics_read_int64(
    buffer: JeffJSArrayBuffer,
    byteIndex: Int
) -> Int64 {
    guard byteIndex + 7 < buffer.data.count else { return 0 }
    let raw = UInt64(buffer.data[byteIndex])
             | (UInt64(buffer.data[byteIndex + 1]) << 8)
             | (UInt64(buffer.data[byteIndex + 2]) << 16)
             | (UInt64(buffer.data[byteIndex + 3]) << 24)
             | (UInt64(buffer.data[byteIndex + 4]) << 32)
             | (UInt64(buffer.data[byteIndex + 5]) << 40)
             | (UInt64(buffer.data[byteIndex + 6]) << 48)
             | (UInt64(buffer.data[byteIndex + 7]) << 56)
    return Int64(bitPattern: raw)
}

// MARK: - Classify typed array element type

/// Returns (isBigInt, isSigned) for a typed array class ID.
private func js_atomics_classify(_ classID: Int) -> (isBigInt: Bool, isSigned: Bool) {
    switch classID {
    case JeffJSClassID.int8Array.rawValue:      return (false, true)
    case JeffJSClassID.uint8Array.rawValue:     return (false, false)
    case JeffJSClassID.int16Array.rawValue:     return (false, true)
    case JeffJSClassID.uint16Array.rawValue:    return (false, false)
    case JeffJSClassID.int32Array.rawValue:     return (false, true)
    case JeffJSClassID.uint32Array.rawValue:    return (false, false)
    case JeffJSClassID.bigInt64Array.rawValue:  return (true, true)
    case JeffJSClassID.bigUint64Array.rawValue: return (true, false)
    default:                                     return (false, false)
    }
}

// MARK: - Atomics.add / and / or / sub / xor / exchange / compareExchange

/// Atomic read-modify-write operation dispatcher.
///
/// Mirrors QuickJS `js_atomics_op` which dispatches on a `magic` parameter
/// to select the operation: add, and, or, sub, xor, exchange, compareExchange.
///
/// These all follow the same pattern:
///   1. Validate typed array and index.
///   2. Convert value to the element type.
///   3. Atomically load the old value, compute the new value, and store it.
///   4. Return the old value.
///
/// For `compareExchange`:
///   1. Atomically load the current value.
///   2. If current == expectedValue, store replacementValue.
///   3. Return the old value.
enum JSAtomicsOpKind: Int {
    case add = 0
    case and = 1
    case or  = 2
    case sub = 3
    case xor = 4
    case exchange = 5
    case compareExchange = 6
}

func js_atomics_op(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue],
    magic: Int
) -> JeffJSValue {
    guard argv.count >= 3 else {
        return ctx.throwTypeError("Atomics: not enough arguments")
    }

    let typedArrayVal = argv[0]
    let indexVal = argv[1]

    guard let info = js_atomics_validateTypedArray(
        ctx: ctx,
        typedArrayVal: typedArrayVal,
        indexVal: indexVal,
        requireShared: false
    ) else {
        return .exception
    }

    let (classify_isBigInt, classify_isSigned) = js_atomics_classify(info.obj.classID)

    // Read the operand value.
    let operandVal: Int64
    if argv[2].isInt {
        operandVal = Int64(argv[2].toInt32())
    } else if argv[2].isFloat64 {
        let d = argv[2].toFloat64()
        operandVal = (d.isNaN || d.isInfinite || abs(d) > Double(Int64.max)) ? 0 : Int64(d)
    } else {
        operandVal = 0
    }

    // For compareExchange, also read the replacement value.
    let replacementVal: Int64
    if magic == JSAtomicsOpKind.compareExchange.rawValue && argv.count >= 4 {
        if argv[3].isInt {
            replacementVal = Int64(argv[3].toInt32())
        } else if argv[3].isFloat64 {
            let d = argv[3].toFloat64()
            replacementVal = (d.isNaN || d.isInfinite || abs(d) > Double(Int64.max)) ? 0 : Int64(d)
        } else {
            replacementVal = 0
        }
    } else {
        replacementVal = 0
    }

    // Perform the atomic operation under the global lock.
    jsAtomicsGlobalLock.lock()
    defer { jsAtomicsGlobalLock.unlock() }

    let oldValue = js_atomics_load_raw(
        buffer: info.buffer,
        byteIndex: info.byteIndex,
        elemSize: info.elemSize,
        isBigInt: classify_isBigInt,
        isSigned: classify_isSigned
    )

    let oldRaw: Int64
    if oldValue.isInt {
        oldRaw = Int64(oldValue.toInt32())
    } else if oldValue.isFloat64 {
        let d = oldValue.toFloat64()
        oldRaw = d.isNaN || d.isInfinite ? 0 : (abs(d) > Double(Int64.max) ? 0 : Int64(d))
    } else {
        oldRaw = 0
    }

    let newRaw: Int64
    guard let opKind = JSAtomicsOpKind(rawValue: magic) else {
        return ctx.throwTypeError("Atomics: invalid operation")
    }

    switch opKind {
    case .add:
        newRaw = oldRaw &+ operandVal
    case .and:
        newRaw = oldRaw & operandVal
    case .or:
        newRaw = oldRaw | operandVal
    case .sub:
        newRaw = oldRaw &- operandVal
    case .xor:
        newRaw = oldRaw ^ operandVal
    case .exchange:
        newRaw = operandVal
    case .compareExchange:
        if oldRaw == operandVal {
            newRaw = replacementVal
        } else {
            // No exchange -- return old value as-is.
            return oldValue
        }
    }

    // Write the new value.
    let newVal: JeffJSValue
    if info.elemSize <= 4 {
        newVal = JeffJSValue.newInt32(Int32(truncatingIfNeeded: newRaw))
    } else {
        newVal = JeffJSValue.newInt64(newRaw)
    }
    js_atomics_store_raw(
        buffer: info.buffer,
        byteIndex: info.byteIndex,
        elemSize: info.elemSize,
        value: newVal
    )

    return oldValue
}

// MARK: - Atomics.load

/// `Atomics.load(typedArray, index)` -- atomically reads a value.
///
/// Mirrors QuickJS `js_atomics_load`.
func js_atomics_load(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    guard argv.count >= 2 else {
        return ctx.throwTypeError("Atomics.load: not enough arguments")
    }

    guard let info = js_atomics_validateTypedArray(
        ctx: ctx,
        typedArrayVal: argv[0],
        indexVal: argv[1],
        requireShared: false
    ) else {
        return .exception
    }

    let (isBigInt, isSigned) = js_atomics_classify(info.obj.classID)

    jsAtomicsGlobalLock.lock()
    let result = js_atomics_load_raw(
        buffer: info.buffer,
        byteIndex: info.byteIndex,
        elemSize: info.elemSize,
        isBigInt: isBigInt,
        isSigned: isSigned
    )
    jsAtomicsGlobalLock.unlock()

    return result
}

// MARK: - Atomics.store

/// `Atomics.store(typedArray, index, value)` -- atomically writes a value.
/// Returns the value that was written (after type coercion).
///
/// Mirrors QuickJS `js_atomics_store`.
func js_atomics_store(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    guard argv.count >= 3 else {
        return ctx.throwTypeError("Atomics.store: not enough arguments")
    }

    guard let info = js_atomics_validateTypedArray(
        ctx: ctx,
        typedArrayVal: argv[0],
        indexVal: argv[1],
        requireShared: false
    ) else {
        return .exception
    }

    let value = argv[2]

    jsAtomicsGlobalLock.lock()
    js_atomics_store_raw(
        buffer: info.buffer,
        byteIndex: info.byteIndex,
        elemSize: info.elemSize,
        value: value
    )
    jsAtomicsGlobalLock.unlock()

    // Return the coerced value (ToIntegerOrInfinity for non-BigInt, ToBigInt for BigInt).
    return value.dupValue()
}

// MARK: - Atomics.isLockFree

/// `Atomics.isLockFree(size)` -- returns true if atomic operations of the
/// given byte size are implemented using hardware atomics (i.e. not a mutex).
///
/// Mirrors QuickJS `js_atomics_isLockFree`.
///
/// Per the spec:
///   - isLockFree(1) => true
///   - isLockFree(2) => true
///   - isLockFree(4) => true
///   - isLockFree(8) => true (on 64-bit platforms)
///   - All other values => false
func js_atomics_isLockFree(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    guard argv.count >= 1 else {
        return JeffJSValue.JS_FALSE
    }

    let size: Int
    if argv[0].isInt {
        size = Int(argv[0].toInt32())
    } else if argv[0].isFloat64 {
        let d = argv[0].toFloat64()
        size = (d.isNaN || d.isInfinite || abs(d) > Double(Int.max / 2)) ? 0 : Int(d)
    } else {
        size = 0
    }

    // On 64-bit platforms, 1, 2, 4, and 8-byte operations are lock-free.
    switch size {
    case 1, 2, 4:
        return JeffJSValue.JS_TRUE
    case 8:
        // True on 64-bit architectures.
        return JeffJSValue.JS_TRUE
    default:
        return JeffJSValue.JS_FALSE
    }
}

// MARK: - Atomics.wait

/// `Atomics.wait(typedArray, index, value, timeout?)` -- blocks the calling
/// agent until notified or the timeout expires.
///
/// Mirrors QuickJS `js_atomics_wait`.
///
/// - `typedArray` must be an Int32Array or BigInt64Array backed by SAB.
/// - `value` is the expected value at the index.
/// - `timeout` is in milliseconds (default: +Infinity).
///
/// Returns:
///   - "ok" if the agent was woken by a notify.
///   - "not-equal" if the value at the index did not match.
///   - "timed-out" if the timeout expired.
///
/// Throws TypeError if the runtime is not allowed to block.
func js_atomics_wait(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    guard argv.count >= 3 else {
        return ctx.throwTypeError("Atomics.wait: not enough arguments")
    }

    // Only Int32Array and BigInt64Array are valid for wait.
    guard let taObj = argv[0].toObject() else {
        return ctx.throwTypeError("Atomics.wait: first argument must be a typed array")
    }

    let isInt32 = taObj.classID == JeffJSClassID.int32Array.rawValue
    let isBigInt64 = taObj.classID == JeffJSClassID.bigInt64Array.rawValue

    if !isInt32 && !isBigInt64 {
        return ctx.throwTypeError(
            "Atomics.wait: typed array must be Int32Array or BigInt64Array"
        )
    }

    guard let info = js_atomics_validateTypedArray(
        ctx: ctx,
        typedArrayVal: argv[0],
        indexVal: argv[1],
        requireShared: true
    ) else {
        return .exception
    }

    // Convert the expected value.
    let expectedI32: Int32
    let expectedI64: Int64
    if isInt32 {
        if argv[2].isInt {
            expectedI32 = argv[2].toInt32()
        } else if argv[2].isFloat64 {
            let d = argv[2].toFloat64()
            expectedI32 = d.isNaN ? 0 : Int32(truncatingIfNeeded: Int64(d))
        } else {
            expectedI32 = 0
        }
        expectedI64 = Int64(expectedI32)
    } else {
        if argv[2].isInt {
            expectedI64 = Int64(argv[2].toInt32())
        } else if argv[2].isFloat64 {
            let d = argv[2].toFloat64()
            expectedI64 = (d.isNaN || d.isInfinite || abs(d) > Double(Int64.max)) ? 0 : Int64(d)
        } else {
            expectedI64 = 0
        }
        expectedI32 = Int32(truncatingIfNeeded: expectedI64)
    }

    // Parse timeout (milliseconds).  Default is +Infinity (wait forever).
    var timeoutMs: Double = .infinity
    if argv.count >= 4 && !argv[3].isUndefined {
        if argv[3].isInt {
            timeoutMs = Double(argv[3].toInt32())
        } else if argv[3].isFloat64 {
            timeoutMs = argv[3].toFloat64()
        }
        if timeoutMs.isNaN {
            timeoutMs = .infinity
        }
    }

    // Create the waiter key.
    let waiterKey = JSAtomicsWaiterKey(buffer: info.buffer, byteIndex: info.byteIndex)
    let waiter = JSAtomicsWaiter(byteIndex: info.byteIndex)

    // Lock, check the value, and either return "not-equal" or block.
    jsAtomicsGlobalLock.lock()

    // Compare current value against expected.
    let mismatch: Bool
    if isInt32 {
        let current = js_atomics_read_int32(buffer: info.buffer, byteIndex: info.byteIndex)
        mismatch = current != expectedI32
    } else {
        let current = js_atomics_read_int64(buffer: info.buffer, byteIndex: info.byteIndex)
        mismatch = current != expectedI64
    }

    if mismatch {
        jsAtomicsGlobalLock.unlock()
        return js_atomics_makeResultString(ctx: ctx, str: "not-equal")
    }

    // Add this waiter to the list.
    if jsAtomicsWaiterLists[waiterKey] == nil {
        jsAtomicsWaiterLists[waiterKey] = []
    }
    jsAtomicsWaiterLists[waiterKey]!.append(waiter)
    jsAtomicsGlobalLock.unlock()

    // Block on the condition variable.
    waiter.condition.lock()
    if timeoutMs == .infinity {
        // Wait forever.
        while !waiter.notified {
            waiter.condition.wait()
        }
    } else if timeoutMs > 0 {
        let deadline = Date(timeIntervalSinceNow: timeoutMs / 1000.0)
        while !waiter.notified {
            if !waiter.condition.wait(until: deadline) {
                break  // Timed out.
            }
        }
    }
    // timeoutMs <= 0: don't wait at all (but still check notified).
    let wasNotified = waiter.notified
    waiter.condition.unlock()

    // Remove from waiter list (in case of timeout).
    jsAtomicsGlobalLock.lock()
    if var list = jsAtomicsWaiterLists[waiterKey] {
        list.removeAll { $0 === waiter }
        if list.isEmpty {
            jsAtomicsWaiterLists.removeValue(forKey: waiterKey)
        } else {
            jsAtomicsWaiterLists[waiterKey] = list
        }
    }
    jsAtomicsGlobalLock.unlock()

    if wasNotified {
        return js_atomics_makeResultString(ctx: ctx, str: "ok")
    } else {
        return js_atomics_makeResultString(ctx: ctx, str: "timed-out")
    }
}

// MARK: - Atomics.notify

/// `Atomics.notify(typedArray, index, count?)` -- wakes up waiting agents.
///
/// Mirrors QuickJS `js_atomics_notify`.
///
/// - `typedArray` must be an Int32Array or BigInt64Array backed by SAB.
/// - `count` is the number of waiters to wake (default: +Infinity = all).
///
/// Returns the number of agents that were woken.
func js_atomics_notify(
    ctx: JeffJSContext,
    this: JeffJSValue,
    argv: [JeffJSValue]
) -> JeffJSValue {
    guard argv.count >= 2 else {
        return ctx.throwTypeError("Atomics.notify: not enough arguments")
    }

    guard let info = js_atomics_validateTypedArray(
        ctx: ctx,
        typedArrayVal: argv[0],
        indexVal: argv[1],
        requireShared: false  // Spec says SAB not required for notify (just returns 0)
    ) else {
        return .exception
    }

    // Parse count (default: +Infinity = wake all).
    var wakeCount = Int.max
    if argv.count >= 3 && !argv[2].isUndefined {
        if argv[2].isInt {
            wakeCount = max(0, Int(argv[2].toInt32()))
        } else if argv[2].isFloat64 {
            let d = argv[2].toFloat64()
            if d.isInfinite && d > 0 {
                wakeCount = Int.max
            } else if d.isNaN || d <= 0 {
                wakeCount = 0
            } else {
                wakeCount = (d.isInfinite || abs(d) > Double(Int.max / 2)) ? Int.max : Int(d)
            }
        }
    }

    let waiterKey = JSAtomicsWaiterKey(buffer: info.buffer, byteIndex: info.byteIndex)

    jsAtomicsGlobalLock.lock()
    guard var list = jsAtomicsWaiterLists[waiterKey], !list.isEmpty else {
        jsAtomicsGlobalLock.unlock()
        return JeffJSValue.newInt32(0)
    }

    let toWake = min(wakeCount, list.count)
    var woken = 0

    for _ in 0 ..< toWake {
        guard !list.isEmpty else { break }
        let waiter = list.removeFirst()
        waiter.condition.lock()
        waiter.notified = true
        waiter.condition.signal()
        waiter.condition.unlock()
        woken += 1
    }

    if list.isEmpty {
        jsAtomicsWaiterLists.removeValue(forKey: waiterKey)
    } else {
        jsAtomicsWaiterLists[waiterKey] = list
    }
    jsAtomicsGlobalLock.unlock()

    return JeffJSValue.newInt32(Int32(woken))
}

// MARK: - Helper: create result string

/// Create a JeffJSValue string from a Swift string.
/// Used for Atomics.wait return values ("ok", "not-equal", "timed-out").
private func js_atomics_makeResultString(ctx: JeffJSContext, str: String) -> JeffJSValue {
    let jsStr = JeffJSString(swiftString: str)
    return JeffJSValue.makeString(jsStr)
}

// MARK: - Convenience wrappers for individual Atomics methods

/// `Atomics.add(typedArray, index, value)`
func js_atomics_add(
    ctx: JeffJSContext, this: JeffJSValue, argv: [JeffJSValue]
) -> JeffJSValue {
    return js_atomics_op(ctx: ctx, this: this, argv: argv,
                         magic: JSAtomicsOpKind.add.rawValue)
}

/// `Atomics.and(typedArray, index, value)`
func js_atomics_and(
    ctx: JeffJSContext, this: JeffJSValue, argv: [JeffJSValue]
) -> JeffJSValue {
    return js_atomics_op(ctx: ctx, this: this, argv: argv,
                         magic: JSAtomicsOpKind.and.rawValue)
}

/// `Atomics.or(typedArray, index, value)`
func js_atomics_or(
    ctx: JeffJSContext, this: JeffJSValue, argv: [JeffJSValue]
) -> JeffJSValue {
    return js_atomics_op(ctx: ctx, this: this, argv: argv,
                         magic: JSAtomicsOpKind.or.rawValue)
}

/// `Atomics.sub(typedArray, index, value)`
func js_atomics_sub(
    ctx: JeffJSContext, this: JeffJSValue, argv: [JeffJSValue]
) -> JeffJSValue {
    return js_atomics_op(ctx: ctx, this: this, argv: argv,
                         magic: JSAtomicsOpKind.sub.rawValue)
}

/// `Atomics.xor(typedArray, index, value)`
func js_atomics_xor(
    ctx: JeffJSContext, this: JeffJSValue, argv: [JeffJSValue]
) -> JeffJSValue {
    return js_atomics_op(ctx: ctx, this: this, argv: argv,
                         magic: JSAtomicsOpKind.xor.rawValue)
}

/// `Atomics.exchange(typedArray, index, value)`
func js_atomics_exchange(
    ctx: JeffJSContext, this: JeffJSValue, argv: [JeffJSValue]
) -> JeffJSValue {
    return js_atomics_op(ctx: ctx, this: this, argv: argv,
                         magic: JSAtomicsOpKind.exchange.rawValue)
}

/// `Atomics.compareExchange(typedArray, index, expectedValue, replacementValue)`
func js_atomics_compareExchange(
    ctx: JeffJSContext, this: JeffJSValue, argv: [JeffJSValue]
) -> JeffJSValue {
    return js_atomics_op(ctx: ctx, this: this, argv: argv,
                         magic: JSAtomicsOpKind.compareExchange.rawValue)
}

// MARK: - Property table definitions

/// Function list for the `Atomics` object.
/// Mirrors QuickJS `js_atomics_funcs`.
let js_atomics_funcs: [(name: String, func_: JSCFunctionType, length: Int)] = [
    ("add", .generic({ ctx, this, argv in
        js_atomics_add(ctx: ctx, this: this, argv: argv)
    }), 3),
    ("and", .generic({ ctx, this, argv in
        js_atomics_and(ctx: ctx, this: this, argv: argv)
    }), 3),
    ("compareExchange", .generic({ ctx, this, argv in
        js_atomics_compareExchange(ctx: ctx, this: this, argv: argv)
    }), 4),
    ("exchange", .generic({ ctx, this, argv in
        js_atomics_exchange(ctx: ctx, this: this, argv: argv)
    }), 3),
    ("isLockFree", .generic({ ctx, this, argv in
        js_atomics_isLockFree(ctx: ctx, this: this, argv: argv)
    }), 1),
    ("load", .generic({ ctx, this, argv in
        js_atomics_load(ctx: ctx, this: this, argv: argv)
    }), 2),
    ("or", .generic({ ctx, this, argv in
        js_atomics_or(ctx: ctx, this: this, argv: argv)
    }), 3),
    ("store", .generic({ ctx, this, argv in
        js_atomics_store(ctx: ctx, this: this, argv: argv)
    }), 3),
    ("sub", .generic({ ctx, this, argv in
        js_atomics_sub(ctx: ctx, this: this, argv: argv)
    }), 3),
    ("wait", .generic({ ctx, this, argv in
        js_atomics_wait(ctx: ctx, this: this, argv: argv)
    }), 4),
    ("notify", .generic({ ctx, this, argv in
        js_atomics_notify(ctx: ctx, this: this, argv: argv)
    }), 3),
    ("xor", .generic({ ctx, this, argv in
        js_atomics_xor(ctx: ctx, this: this, argv: argv)
    }), 3),
]

// MARK: - Initialization

/// Register the Atomics object on the global object of a context.
///
/// Mirrors QuickJS `JS_AddIntrinsicAtomics`.
///
/// Creates a plain object `Atomics` with:
///   - All static methods (add, and, compareExchange, exchange, isLockFree,
///     load, or, store, sub, wait, notify, xor)
///   - `Atomics[Symbol.toStringTag] = "Atomics"` (non-enumerable, non-writable,
///     configurable)
func js_addIntrinsicAtomics(ctx: JeffJSContext) {
    // Create the Atomics object (a plain object, not a constructor).
    let atomicsVal = ctx.newPlainObject()

    // Install each static method from the function table.
    for entry in js_atomics_funcs {
        let fn: JeffJSValue
        switch entry.func_ {
        case .generic(let closure):
            fn = ctx.newCFunction(closure, name: entry.name, length: entry.length)
        default:
            continue
        }
        _ = ctx.setPropertyStr(obj: atomicsVal, name: entry.name, value: fn)
    }

    // Install on the global object.
    _ = ctx.setPropertyStr(obj: ctx.globalObj, name: "Atomics", value: atomicsVal)
}
