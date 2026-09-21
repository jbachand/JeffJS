// JeffJSBuiltinToStringTag.swift
// JeffJS - 1:1 Swift port of QuickJS
//
// Installs the `Symbol.toStringTag` own properties the spec puts on builtin
// prototypes and namespace objects.  Without them
// `Object.prototype.toString.call(new Map())` answers "[object Object]", which
// breaks every type-sniffing library (Prism, lodash's `getTag`, core-js
// feature tests, React's `typeof` helpers, ...).
//
// Spec: each tag is { writable: false, enumerable: false, configurable: true }.
// QuickJS installs them with JS_PROP_CONFIGURABLE inside each
// JS_AddIntrinsic* routine; JeffJS's intrinsics are spread over many files, so
// they are installed in one pass at the end of context initialisation, keyed
// off `classProto[]` (which by then holds every builtin prototype).

import Foundation

/// classID -> @@toStringTag string for prototypes reachable through
/// `ctx.classProto`.
private let jeffJS_toStringTagByClass: [(JSClassID, String)] = [
    (.JS_CLASS_MAP,                    "Map"),
    (.JS_CLASS_SET,                    "Set"),
    (.JS_CLASS_WEAKMAP,                "WeakMap"),
    (.JS_CLASS_WEAKSET,                "WeakSet"),
    (.JS_CLASS_PROMISE,                "Promise"),
    (.JS_CLASS_ARRAY_BUFFER,           "ArrayBuffer"),
    (.JS_CLASS_SHARED_ARRAY_BUFFER,    "SharedArrayBuffer"),
    (.JS_CLASS_DATAVIEW,               "DataView"),
    (.JS_CLASS_SYMBOL,                 "Symbol"),
    (.JS_CLASS_BIG_INT,                "BigInt"),
    (.JS_CLASS_WEAKREF,                "WeakRef"),
    (.JS_CLASS_FINALIZATION_REGISTRY,  "FinalizationRegistry"),
    (.JS_CLASS_MODULE_NS,              "Module"),
    // Iterators
    (.JS_CLASS_MAP_ITERATOR,           "Map Iterator"),
    (.JS_CLASS_SET_ITERATOR,           "Set Iterator"),
    (.JS_CLASS_ARRAY_ITERATOR,         "Array Iterator"),
    (.JS_CLASS_STRING_ITERATOR,        "String Iterator"),
    (.JS_CLASS_REGEXP_STRING_ITERATOR, "RegExp String Iterator"),
    // Generators / async functions
    (.JS_CLASS_GENERATOR,              "Generator"),
    (.JS_CLASS_GENERATOR_FUNCTION,     "GeneratorFunction"),
    (.JS_CLASS_ASYNC_FUNCTION,         "AsyncFunction"),
    (.JS_CLASS_ASYNC_GENERATOR,        "AsyncGenerator"),
    (.JS_CLASS_ASYNC_GENERATOR_FUNCTION, "AsyncGeneratorFunction"),
    (.JS_CLASS_ASYNC_FROM_SYNC_ITERATOR, "Async-from-Sync Iterator"),
    // Typed arrays: the spec puts an accessor on %TypedArray%.prototype that
    // reports the concrete constructor name.  A per-prototype data property is
    // observationally identical for instances and far cheaper here.
    (.JS_CLASS_UINT8C_ARRAY,           "Uint8ClampedArray"),
    (.JS_CLASS_INT8_ARRAY,             "Int8Array"),
    (.JS_CLASS_UINT8_ARRAY,            "Uint8Array"),
    (.JS_CLASS_INT16_ARRAY,            "Int16Array"),
    (.JS_CLASS_UINT16_ARRAY,           "Uint16Array"),
    (.JS_CLASS_INT32_ARRAY,            "Int32Array"),
    (.JS_CLASS_UINT32_ARRAY,           "Uint32Array"),
    (.JS_CLASS_BIG_INT64_ARRAY,        "BigInt64Array"),
    (.JS_CLASS_BIG_UINT64_ARRAY,       "BigUint64Array"),
    (.JS_CLASS_FLOAT32_ARRAY,          "Float32Array"),
    (.JS_CLASS_FLOAT64_ARRAY,          "Float64Array"),
]

/// Namespace/global singletons that carry the tag on the object itself.
private let jeffJS_toStringTagByGlobal: [(String, String)] = [
    ("Math", "Math"),
    ("JSON", "JSON"),
    ("Reflect", "Reflect"),
    ("Atomics", "Atomics"),
]

/// Globals whose `.prototype` carries the tag, for builtins that do not
/// register a `classProto[]` entry (Intl objects, the Iterator helper base).
private let jeffJS_toStringTagByCtorProto: [(String, String)] = [
    ("Intl.Collator", "Intl.Collator"),
    ("Intl.DateTimeFormat", "Intl.DateTimeFormat"),
    ("Intl.NumberFormat", "Intl.NumberFormat"),
    ("Intl.ListFormat", "Intl.ListFormat"),
    ("Intl.PluralRules", "Intl.PluralRules"),
    ("Intl.RelativeTimeFormat", "Intl.RelativeTimeFormat"),
    ("Intl.Segmenter", "Intl.Segmenter"),
    ("Intl.Locale", "Intl.Locale"),
]

extension JeffJSContext {

    /// Define `obj[Symbol.toStringTag] = tag` with spec attributes
    /// (non-writable, non-enumerable, configurable). No-op when the object
    /// already has an own tag (a builtin that installed its own accessor wins).
    private func installToStringTag(_ obj: JeffJSValue, _ tag: String) {
        guard obj.isObject, let jsObj = obj.toObject() else { return }
        let atom = JeffJSAtomID.JS_ATOM_Symbol_toStringTag.rawValue
        if let shape = jsObj.shape, shape.prop.contains(where: { $0.atom == atom }) { return }
        _ = definePropertyValue(obj: obj, atom: atom,
                                value: newStringValue(tag),
                                flags: JS_PROP_CONFIGURABLE)
    }

    /// Install every builtin `Symbol.toStringTag`. Called once, at the end of
    /// context initialisation, after all intrinsics exist.
    func addIntrinsicToStringTags() {
        for (cls, tag) in jeffJS_toStringTagByClass {
            let idx = Int(cls.rawValue)
            guard idx < classProto.count else { continue }
            installToStringTag(classProto[idx], tag)
        }

        for (name, tag) in jeffJS_toStringTagByGlobal {
            let v = getPropertyStr(obj: globalObj, name: name)
            installToStringTag(v, tag)
            v.freeValue()
        }

        for (path, tag) in jeffJS_toStringTagByCtorProto {
            var cur = globalObj.dupValue()
            var ok = true
            for part in path.split(separator: ".") {
                let next = getPropertyStr(obj: cur, name: String(part))
                cur.freeValue()
                cur = next
                if !cur.isObject { ok = false; break }
            }
            if ok {
                let proto = getProperty(obj: cur, atom: JeffJSAtomID.JS_ATOM_prototype.rawValue)
                installToStringTag(proto, tag)
                proto.freeValue()
            }
            cur.freeValue()
        }
    }
}
