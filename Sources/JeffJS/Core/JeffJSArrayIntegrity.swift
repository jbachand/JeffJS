// JeffJSArrayIntegrity.swift
// JeffJS - integrity levels and property attributes for fast-array elements.
//
// Array elements live in `JeffJSFastArrayStorage`, not in the shape, so
// `Object.freeze` / `seal` / `preventExtensions` and a non-writable `length`
// used to change only the shape and leave every element write, delete and
// length change unchecked. The storage now carries per-element attribute
// bits (`attrs`, nil for ordinary arrays) and a `checked` flag that every
// unchecked write path tests; once it is set, element writes, deletes and
// length changes come here and follow ES2024:
//   §10.1.9.2 OrdinarySetWithOwnDescriptor (writable / extensible checks)
//   §10.1.10  [[Delete]] (configurable check)
//   §10.4.2.1 array [[DefineOwnProperty]] and §10.4.2.4 ArraySetLength.

import Foundation

extension JeffJSObject {
    /// Clear [[Extensible]]. Arrays also switch their element writes to the
    /// checked path, since adding an element is now an error.
    func makeNonExtensible() {
        extensible = false
        if classID == JeffJSClassID.array.rawValue { markArrayWritesChecked() }
    }
}

extension JeffJSContext {

    /// A failed [[Set]]: releases the consumed value and throws only when
    /// the caller asked for it (strict code, `Set(O, P, V, true)`).
    @inline(never)
    func failElementWrite(_ value: JeffJSValue, flags: Int, _ message: String) -> Int {
        value.freeValue()
        if (flags & JS_PROP_THROW) == 0 { return 0 }
        _ = throwTypeError(message: message)
        return -1
    }

    /// A rejected [[DefineOwnProperty]] (ValidateAndApplyPropertyDescriptor
    /// returned false).
    @inline(never)
    private func rejectDefine(flags: Int, _ message: String) -> Int {
        if (flags & JS_PROP_THROW) != 0 { _ = throwTypeError(message: message) }
        return -1
    }

    /// The array's own `length` slot: slot index, [[Writable]], and value.
    func arrayLengthInfo(_ o: JeffJSObject) -> (slot: Int, writable: Bool, length: UInt32)? {
        let slot = jeffJS_findOwnPropertyIndex(obj: o, atom: JeffJSAtomID.JS_ATOM_length.rawValue)
        guard slot >= 0, let sh = o.shape, slot < sh.prop.count, slot < o.propValues.count else { return nil }
        let v = o.propValues[slot]
        var len: UInt32 = 0
        if v.isInt {
            len = UInt32(bitPattern: v.toInt32())
        } else if v.isFloat64 {
            let d = v.toFloat64()
            if d >= 0 && d < 4294967296.0 { len = UInt32(d) }
        }
        return (slot, sh.prop[slot].flags.contains(.writable), len)
    }

    /// Store `len` in the array's `length` slot (attributes untouched).
    private func storeArrayLength(_ o: JeffJSObject, slot: Int, _ len: Int) {
        let old = o.propValues[slot]
        o.propValues[slot] = newInt64(Int64(len))
        o.setExtraSlot(slot, nil)
        old.freeValue()
    }

    /// [[Set]] of array index `index` on a fast array whose storage is
    /// `checked`. Returns 1/0/-1 when the write was performed or refused
    /// (`value` consumed), or nil when it is a permitted add of a new element
    /// that the caller completes through the ordinary element store.
    func setArrayElementChecked(_ o: JeffJSObject, _ st: JeffJSFastArrayStorage,
                                index: UInt32, value: JeffJSValue, flags: Int) -> Int? {
        let i = Int(index)
        if st.isPresent(i) {
            if st.attr(i) & JeffJSFastArrayStorage.attrWritable == 0 {
                return failElementWrite(value, flags: flags,
                    "Cannot assign to read only property '\(index)' of object '[object Array]'")
            }
            let old = st.values[i]
            st.values[i] = value
            old.freeValue()
            return 1
        }
        // A new element: CreateDataProperty -> array [[DefineOwnProperty]].
        if !o.extensible {
            return failElementWrite(value, flags: flags,
                "Cannot add property \(index), object is not extensible")
        }
        if let len = arrayLengthInfo(o), index >= len.length, !len.writable {
            return failElementWrite(value, flags: flags,
                "Cannot add property \(index), array length is read-only")
        }
        // The new element is an ordinary data property.
        if st.attrs != nil { st.setAttr(i, JeffJSFastArrayStorage.attrDefault) }
        return nil
    }

    /// [[Delete]] of a present element: false when it is non-configurable.
    @inline(__always)
    func arrayElementIsDeletable(_ o: JeffJSObject, index: UInt32) -> Bool {
        guard let st = o._fastArrayValues, st.checked, st.attrs != nil else { return true }
        let i = Int(index)
        return !st.isPresent(i) || st.attr(i) & JeffJSFastArrayStorage.attrConfigurable != 0
    }

    /// Drop the elements at `newLen` and above, stopping above the highest
    /// non-configurable one (ArraySetLength step 17). Returns the length the
    /// array can actually shrink to.
    private func truncateArrayElements(_ o: JeffJSObject, to newLen: Int) -> Int {
        var keep = newLen
        if let st = o._fastArrayValues, st.attrs != nil {
            var i = Int(st.count) - 1
            while i >= newLen {
                if st.isPresent(i), st.attr(i) & JeffJSFastArrayStorage.attrConfigurable == 0 {
                    keep = i + 1
                    break
                }
                i -= 1
            }
        }
        o.truncateFastArray(to: keep)
        return keep
    }

    /// `arr.length = value` on an array whose storage is `checked`
    /// (ArraySetLength via OrdinarySet). nil when the value is not a valid
    /// array length number, which the generic path handles as before.
    func setArrayLengthChecked(_ o: JeffJSObject, value: JeffJSValue, flags: Int) -> Int? {
        guard let info = arrayLengthInfo(o) else { return nil }
        let newLen: Int
        if value.isInt, value.toInt32() >= 0 {
            newLen = Int(value.toInt32())
        } else if value.isFloat64 {
            let d = value.toFloat64()
            guard d >= 0, d < 4294967296.0, d == d.rounded(.towardZero) else { return nil }
            newLen = Int(d)
        } else {
            return nil
        }
        if !info.writable {
            return failElementWrite(value, flags: flags,
                "Cannot assign to read only property 'length' of object '[object Array]'")
        }
        value.freeValue()
        let keep = newLen < Int(info.length) ? truncateArrayElements(o, to: newLen) : newLen
        storeArrayLength(o, slot: info.slot, keep)
        if keep != newLen {
            if (flags & JS_PROP_THROW) == 0 { return 0 }
            _ = throwTypeError(message: "Cannot delete property '\(keep - 1)' of [object Array]")
            return -1
        }
        return 1
    }

    /// Array [[DefineOwnProperty]] (§10.4.2.1) for an array index or
    /// `length` on an array with fast elements. nil when the definition is
    /// not one this handles (accessors on elements, non-number lengths, no
    /// fast storage); the caller then runs the ordinary shape definition.
    func defineArrayOwnProperty(_ obj: JeffJSValue, _ o: JeffJSObject, atom: UInt32,
                                value: JeffJSValue, flags: Int) -> Int? {
        if (flags & JS_PROP_TMASK) == JS_PROP_GETSET { return nil }
        if atom == JeffJSAtomID.JS_ATOM_length.rawValue {
            return defineArrayLength(obj, o, value: value, flags: flags)
        }
        guard rt.atomIsArrayIndex(atom), let index = rt.atomToUInt32(atom),
              let st = o.fastArrayStorage() else { return nil }
        let isDefine = (flags & JS_PROP_DEFINE_PROPERTY) != 0
        let hasValue = !isDefine || (flags & JS_PROP_HAS_VALUE) != 0
        var bits: UInt8 = 0
        if (flags & JS_PROP_WRITABLE) != 0 { bits |= JeffJSFastArrayStorage.attrWritable }
        if (flags & JS_PROP_ENUMERABLE) != 0 { bits |= JeffJSFastArrayStorage.attrEnumerable }
        if (flags & JS_PROP_CONFIGURABLE) != 0 { bits |= JeffJSFastArrayStorage.attrConfigurable }
        let i = Int(index)

        if st.isPresent(i) {
            let cur = st.attr(i)
            if isDefine {
                // Omitted attributes keep their current value.
                if (flags & JS_PROP_HAS_WRITABLE) == 0 { bits |= cur & JeffJSFastArrayStorage.attrWritable }
                if (flags & JS_PROP_HAS_ENUMERABLE) == 0 { bits |= cur & JeffJSFastArrayStorage.attrEnumerable }
                if (flags & JS_PROP_HAS_CONFIGURABLE) == 0 { bits |= cur & JeffJSFastArrayStorage.attrConfigurable }
                // ValidateAndApplyPropertyDescriptor for a non-configurable
                // data property.
                if cur & JeffJSFastArrayStorage.attrConfigurable == 0 {
                    if (flags & JS_PROP_HAS_CONFIGURABLE) != 0, (flags & JS_PROP_CONFIGURABLE) != 0 {
                        return rejectDefine(flags: flags, "Cannot redefine property: \(index)")
                    }
                    if (flags & JS_PROP_HAS_ENUMERABLE) != 0,
                       ((flags & JS_PROP_ENUMERABLE) != 0) != (cur & JeffJSFastArrayStorage.attrEnumerable != 0) {
                        return rejectDefine(flags: flags, "Cannot redefine property: \(index)")
                    }
                    if cur & JeffJSFastArrayStorage.attrWritable == 0 {
                        if (flags & JS_PROP_HAS_WRITABLE) != 0, (flags & JS_PROP_WRITABLE) != 0 {
                            return rejectDefine(flags: flags, "Cannot redefine property: \(index)")
                        }
                        if hasValue, !sameValue(st.values[i], value) {
                            return rejectDefine(flags: flags, "Cannot redefine property: \(index)")
                        }
                    }
                }
            }
            if hasValue {
                let old = st.values[i]
                st.values[i] = value.dupValue()
                old.freeValue()
            }
            st.setAttr(i, bits)
            return 1
        }

        // A new element.
        if !o.extensible {
            return rejectDefine(flags: flags, "Cannot define property \(index), object is not extensible")
        }
        let len = arrayLengthInfo(o)
        if let len = len, index >= len.length, !len.writable {
            return rejectDefine(flags: flags, "Cannot define property \(index), array length is read-only")
        }
        _ = o.setArrayElement(index, value: hasValue ? value.dupValue() : .undefined)
        if st.attrs != nil || bits != JeffJSFastArrayStorage.attrDefault { st.setAttr(i, bits) }
        if let len = len, index >= len.length { storeArrayLength(o, slot: len.slot, i + 1) }
        o.shape?.enumKeyCache = nil
        return 1
    }

    /// ArraySetLength (§10.4.2.4) through [[DefineOwnProperty]]:
    /// `Object.defineProperty(arr, "length", desc)`.
    private func defineArrayLength(_ obj: JeffJSValue, _ o: JeffJSObject,
                                   value: JeffJSValue, flags: Int) -> Int? {
        guard let info = arrayLengthInfo(o) else { return nil }
        let lengthAtom = JeffJSAtomID.JS_ATOM_length.rawValue
        let isDefine = (flags & JS_PROP_DEFINE_PROPERTY) != 0
        let hasValue = !isDefine || (flags & JS_PROP_HAS_VALUE) != 0
        let setsNonWritable = (!isDefine || (flags & JS_PROP_HAS_WRITABLE) != 0)
            && (flags & JS_PROP_WRITABLE) == 0

        var newLen = -1
        if hasValue {
            if value.isInt {
                let v = value.toInt32()
                if v < 0 { _ = throwRangeError(message: "Invalid array length"); return -1 }
                newLen = Int(v)
            } else if value.isFloat64 {
                let d = value.toFloat64()
                guard d >= 0, d < 4294967296.0, d == d.rounded(.towardZero) else {
                    _ = throwRangeError(message: "Invalid array length"); return -1
                }
                newLen = Int(d)
            } else {
                // Strings, objects: the generic path (unchanged behaviour),
                // but keep the checked flag in step with the attributes.
                let r = defineProperty(obj: obj, atom: lengthAtom, value: value,
                                       flags: flags | JS_PROP_NO_EXOTIC)
                if r >= 0, setsNonWritable { o.markArrayWritesChecked() }
                return r
            }
        }

        if !hasValue || newLen >= Int(info.length) {
            let r = defineProperty(obj: obj, atom: lengthAtom, value: value,
                                   flags: flags | JS_PROP_NO_EXOTIC)
            if r >= 0, setsNonWritable { o.markArrayWritesChecked() }
            return r
        }

        // Shrinking. Validate and store the new length first, still writable
        // if it is about to become read-only (steps 11-15), then delete.
        var firstFlags = flags | JS_PROP_NO_EXOTIC
        if setsNonWritable { firstFlags |= JS_PROP_WRITABLE }
        let r = defineProperty(obj: obj, atom: lengthAtom, value: newInt64(Int64(newLen)),
                               flags: firstFlags)
        if r < 0 { return r }
        let keep = truncateArrayElements(o, to: newLen)
        if keep != newLen { storeArrayLength(o, slot: info.slot, keep) }
        if setsNonWritable {
            _ = defineProperty(obj: obj, atom: lengthAtom, value: .undefined,
                               flags: JS_PROP_DEFINE_PROPERTY | JS_PROP_HAS_WRITABLE | JS_PROP_NO_EXOTIC)
            o.markArrayWritesChecked()
        }
        if keep != newLen {
            return rejectDefine(flags: flags, "Cannot delete property '\(keep - 1)' of [object Array]")
        }
        return 1
    }

    // MARK: - Integrity levels

    /// SetIntegrityLevel's element half for a fast array: every present
    /// element becomes non-configurable (and, for `.frozen`, non-writable).
    func applyArrayIntegrityLevel(_ o: JeffJSObject, level: JeffJSIntegrityLevel) {
        guard let st = o.markArrayWritesChecked() else { return }
        let n = min(Int(st.count), st.values.count)
        if n == 0 { return }
        var mask: UInt8 = ~JeffJSFastArrayStorage.attrConfigurable
        if level == .frozen { mask &= ~JeffJSFastArrayStorage.attrWritable }
        var a = st.attrs ?? ContiguousArray(repeating: JeffJSFastArrayStorage.attrDefault,
                                            count: st.values.count)
        if a.count < n {
            a.append(contentsOf: repeatElement(JeffJSFastArrayStorage.attrDefault, count: n - a.count))
        }
        for i in 0 ..< n where !st.values[i].isUninitialized { a[i] &= mask }
        st.attrs = a
    }

    /// TestIntegrityLevel's element half: false when some present element
    /// is configurable (or, for `.frozen`, writable).
    func arrayElementsSatisfy(_ o: JeffJSObject, level: JeffJSIntegrityLevel) -> Bool {
        guard let snap = o.arraySnapshot() else { return true }
        let attrs = o._fastArrayValues?.attrs
        let n = min(snap.count, snap.values.count)
        for i in 0 ..< n where !snap.values[i].isUninitialized {
            let a = (attrs != nil && i < attrs!.count) ? attrs![i] : JeffJSFastArrayStorage.attrDefault
            if a & JeffJSFastArrayStorage.attrConfigurable != 0 { return false }
            if level == .frozen, a & JeffJSFastArrayStorage.attrWritable != 0 { return false }
        }
        return true
    }
}
