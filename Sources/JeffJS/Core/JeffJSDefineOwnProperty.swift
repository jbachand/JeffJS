// JeffJSDefineOwnProperty.swift
// JeffJS — the one "define or replace own property" routine for native callers.
//
// Every native definition path (setPropertyGetSet, definePropertyValue / setPropertyFunc,
// the defineIntrinsic* helpers, the builtin installers jeffJS_defineBuiltinFunc /
// jeffJS_addGetterProperty / the Math constants / Function and Date prototype members)
// funnels into `defineOrReplaceOwnProperty`, which is `defineProperty` — the
// [[DefineOwnProperty]] behind `Object.defineProperty` — fed a *complete* descriptor:
//
// - a name the object already owns is replaced **in place** (ES §10.1.6.3
//   ValidateAndApplyPropertyDescriptor): same slot, same position in the key order; a data
//   property becomes an accessor or the reverse there, the replaced value / getter / setter
//   is released, and a change of kind or attributes gives the object a new shape identity
//   first (`prepareShapeUpdate`), so no inline cache keeps reading the old slot layout;
// - a non-configurable property rejects any change ValidateAndApply rejects (returns false;
//   throws a TypeError only when `JS_PROP_THROW` is passed) — unless the caller is the
//   engine's own intrinsic setup (`intrinsic: true`), which owns those properties and
//   re-links them between init phases;
// - a new property on a non-extensible object is refused the same way.
//
// Before (2026-10-07) `setPropertyGetSet` appended a second shape entry for a name the object
// already owned — two entries for one key: lookups found the newer, getOwnPropertyNames listed
// the key twice, `delete` uncovered the older one, `reorderOwnProperties` then put the older one
// first — and the builtin installers wrote their value into the object's *last* slot when the
// name already existed (`jeffJS_addProperty` appends nothing for a duplicate), clobbering an
// unrelated property.

import Foundation

extension JeffJSContext {

    /// Defines (or replaces in place) the own property `atom` of `obj` from a complete
    /// descriptor. Borrows `value`, `getter` and `setter` (the property takes its own counts).
    ///
    /// - flags: `JS_PROP_CONFIGURABLE` / `JS_PROP_ENUMERABLE` / `JS_PROP_WRITABLE`, plus
    ///   `JS_PROP_GETSET` for an accessor (then `getter` / `setter`, nil = undefined, and
    ///   `JS_PROP_WRITABLE` is ignored), plus optionally `JS_PROP_THROW`.
    /// - intrinsic: engine intrinsic setup only — skips the non-configurable validation.
    /// - Returns: true when the property now has the requested descriptor.
    @discardableResult
    func defineOrReplaceOwnProperty(_ obj: JeffJSValue, atom: UInt32,
                                    value: JeffJSValue = .undefined,
                                    getter: JeffJSValue? = nil, setter: JeffJSValue? = nil,
                                    flags: Int, intrinsic: Bool = false) -> Bool {
        guard obj.isObject else { return false }
        let accessor = (flags & JS_PROP_TMASK) == JS_PROP_GETSET
        var f = flags & (JS_PROP_CONFIGURABLE | JS_PROP_ENUMERABLE | JS_PROP_THROW)
            | JS_PROP_HAS_CONFIGURABLE | JS_PROP_HAS_ENUMERABLE
        if accessor {
            f |= JS_PROP_GETSET | JS_PROP_HAS_GET | JS_PROP_HAS_SET
        } else {
            f |= (flags & JS_PROP_WRITABLE) | JS_PROP_HAS_WRITABLE | JS_PROP_HAS_VALUE
        }
        // JS_PROP_DEFINE_PROPERTY turns on defineProperty's ValidateAndApply checks. With every
        // JS_PROP_HAS_* bit set the descriptor is complete, so nothing is merged from the old one.
        if !intrinsic { f |= JS_PROP_DEFINE_PROPERTY }
        let r = defineProperty(obj: obj, atom: atom, value: accessor ? .undefined : value,
                               getter: accessor ? (getter ?? .undefined) : .undefined,
                               setter: accessor ? (setter ?? .undefined) : .undefined,
                               flags: f)
        if r < 0, JeffJSDefineOwnPropertyDebug.enabled {
            let name = rt.atomToString(atom) ?? "#\(atom)"
            FileHandle.standardError.write(Data("[jeffjs:define] refused '\(name)' (\(accessor ? "accessor" : "data"), flags \(String(flags, radix: 16)))\n".utf8))
        }
        return r >= 0
    }

    /// `defineOrReplaceOwnProperty` that consumes `value` (the installers that build a value
    /// just to store it).
    @discardableResult
    func defineOrReplaceOwnPropertyFree(_ obj: JeffJSValue, atom: UInt32, value: JeffJSValue,
                                        flags: Int, intrinsic: Bool = false) -> Bool {
        let ok = defineOrReplaceOwnProperty(obj, atom: atom, value: value, flags: flags, intrinsic: intrinsic)
        value.freeValue()
        return ok
    }
}

/// `JEFFJS_DEBUG_DEFINEREFUSED=1`: one stderr line per native definition the routine refused
/// (a non-configurable property, a non-extensible object).
enum JeffJSDefineOwnPropertyDebug {
    static let enabled: Bool = ProcessInfo.processInfo.environment["JEFFJS_DEBUG_DEFINEREFUSED"] == "1"
}
