// JeffJSBuiltinIntrinsicMembers.swift
// JeffJS - 1:1 Swift port of QuickJS
//
// Spec-defined members of the builtins that no intrinsic routine installed,
// with the attributes ECMA-262 fixes for them (QuickJS defines each in its
// JS_AddIntrinsic* routine; JeffJS's are spread over many files, so they go
// in one pass after every constructor exists):
//
// - `get [Symbol.species]` on Map, Set, RegExp, Promise, ArrayBuffer,
//   SharedArrayBuffer and %TypedArray% (ES §24.1.2.3, §24.2.3.2, §22.2.5.2,
//   §27.2.4.8, §25.1.5.3, §25.2.4.3, §23.2.2.4): { get, configurable }.
//   Array's is installed with the Array builtin.
// - Array.prototype[@@unscopables] (ES §23.1.3.41): a null-prototype object
//   of `true` data properties, { configurable } only.
// - Symbol.prototype[@@toPrimitive] (ES §20.4.3.5): { configurable } only.
// - `length` 0 of String.prototype (a String exotic object whose
//   [[StringData]] is "", ES §22.1.3: { all false }) and of Array.prototype
//   (an Array exotic object, ES §23.1.3: { writable }). Both read undefined.
//
// Each is defined only when the object has no own property of that key yet.

import Foundation

extension JeffJSContext {

    func addIntrinsicWellKnownMembers() {
        let speciesAtom = JeffJSAtomID.JS_ATOM_Symbol_species.rawValue
        func global(_ name: String) -> JeffJSValue { getPropertyStr(obj: globalObj, name: name) }
        func hasOwn(_ v: JeffJSValue, _ atom: UInt32) -> Bool {
            guard let o = v.toObject() else { return true }
            return jeffJS_findOwnPropertyIndex(obj: o, atom: atom) >= 0
        }

        // --- get [Symbol.species] ---
        var speciesCtors: [JeffJSValue] = ["Map", "Set", "RegExp", "Promise", "ArrayBuffer",
                                           "SharedArrayBuffer"].map { global($0) }
        let int8 = global("Int8Array")
        if int8.isObject { speciesCtors.append(getPrototypeOf(int8)) }   // %TypedArray%
        int8.freeValue()
        for c in speciesCtors {
            defer { c.freeValue() }
            guard c.isObject, !hasOwn(c, speciesAtom) else { continue }
            let getter = newCFunction({ _, this, _ in this.dupValue() },
                                      name: "get [Symbol.species]", length: 0)
            getter.toObject()?.nativeNameKeepsAccessorPrefix = true
            _ = defineProperty(obj: c, atom: speciesAtom, value: .undefined,
                               getter: getter, setter: .undefined,
                               flags: JS_PROP_GETSET | JS_PROP_HAS_GET | JS_PROP_CONFIGURABLE)
            getter.freeValue()   // defineProperty dups
        }

        // --- Array.prototype[@@unscopables] ---
        let unscopablesAtom = JeffJSAtomID.JS_ATOM_Symbol_unscopables.rawValue
        let arrayProto = classProto[JSClassID.JS_CLASS_ARRAY.rawValue]
        if arrayProto.isObject, !hasOwn(arrayProto, unscopablesAtom) {
            let list = newObjectProto(proto: .null)
            for name in ["at", "copyWithin", "entries", "fill", "find", "findIndex", "findLast",
                         "findLastIndex", "flat", "flatMap", "includes", "keys", "toReversed",
                         "toSorted", "toSpliced", "values"] {
                _ = definePropertyValue(list, name: name, value: .JS_TRUE, flags: JS_PROP_C_W_E)
            }
            _ = definePropertyValue(obj: arrayProto, atom: unscopablesAtom, value: list,
                                    flags: JS_PROP_CONFIGURABLE)
            list.freeValue()   // definePropertyValue dups
        }

        // --- String.prototype.length / Array.prototype.length ---
        let lengthAtom = JeffJSAtomID.JS_ATOM_length.rawValue
        let stringProto = classProto[JSClassID.JS_CLASS_STRING.rawValue]
        if stringProto.isObject, !hasOwn(stringProto, lengthAtom) {
            _ = definePropertyValue(obj: stringProto, atom: lengthAtom, value: .newInt32(0), flags: 0)
        }
        if arrayProto.isObject, !hasOwn(arrayProto, lengthAtom) {
            _ = definePropertyValue(obj: arrayProto, atom: lengthAtom, value: .newInt32(0),
                                    flags: JS_PROP_WRITABLE)
        }

        // --- Symbol.prototype[@@toPrimitive] ---
        let toPrimitiveAtom = JeffJSAtomID.JS_ATOM_Symbol_toPrimitive.rawValue
        let symbolProto = classProto[JSClassID.JS_CLASS_SYMBOL.rawValue]
        if symbolProto.isObject, !hasOwn(symbolProto, toPrimitiveAtom) {
            // thisSymbolValue(this value) (ES §20.4.3.4.1), as Symbol.prototype.valueOf.
            let fn = newCFunction({ ctx, this, _ in
                if this.isSymbol { return this.dupValue() }
                if let inner = jeffJS_unwrapSymbolObject(this) { return inner.dupValue() }
                return ctx.throwTypeError(message: "Symbol.prototype[Symbol.toPrimitive] requires that |this| be a symbol")
            }, name: "[Symbol.toPrimitive]", length: 1)
            _ = definePropertyValue(obj: symbolProto, atom: toPrimitiveAtom, value: fn,
                                    flags: JS_PROP_CONFIGURABLE)
            fn.freeValue()   // definePropertyValue dups
        }
    }
}
