// IntrinsicAttributesConformance.swift
// JeffJS — conformance group "IntrinsicAttributes" (2026-10-07).
//
// Every builtin constructor's `prototype` is { [[Writable]]: false,
// [[Enumerable]]: false, [[Configurable]]: false } (ES §20–§28, each
// "C.prototype" entry). JeffJS defined them with [[Set]] — writable and
// configurable, the NativeErrors' also enumerable — so the app's Safari
// surface pass could replace `Object.prototype` outright (`{} instanceof
// Object` false). The fix is one helper at the source
// (JeffJSContext.defineIntrinsicPrototype / defineIntrinsicPrototypeLink);
// this group checks every intrinsic data property whose attributes the spec
// fixes, against the spec tables (the expected column is what
// JavaScriptCore reports, which matches them): prototype links and their
// `constructor` back-links, Function.prototype.length/name, the well-known
// symbols, @@toStringTag, Number/Math constants, globalThis.undefined/NaN/
// Infinity, Array.prototype[@@unscopables], RegExp.prototype accessors,
// @@species, BYTES_PER_ELEMENT, NativeError name/message.
// Flags: W/E/C for a data property, g/s/E/C for an accessor, "---" = all
// false, MISSING = no own property.

import Foundation
@testable import JeffJS

extension JeffJSTestRunner {

    /// (label, object expression, key expression, expected flags)
    static let intrinsicAttributeTable: [(String, String, String, String)] = [
        ("%TypedArray%.prototype", "Object.getPrototypeOf(Int8Array)", "'prototype'", "---"),
        ("%TypedArray%.prototype.constructor", "Object.getPrototypeOf(Int8Array).prototype", "'constructor'", "W-C"),
        ("%GeneratorFunction%.prototype", "Object.getPrototypeOf(function*(){}).constructor", "'prototype'", "---"),
        ("%GeneratorFunction%.prototype.constructor", "Object.getPrototypeOf(function*(){}).constructor.prototype", "'constructor'", "--C"),
        ("%AsyncGeneratorFunction%.prototype", "Object.getPrototypeOf(async function*(){}).constructor", "'prototype'", "---"),
        ("%AsyncGeneratorFunction%.prototype.constructor", "Object.getPrototypeOf(async function*(){}).constructor.prototype", "'constructor'", "--C"),
        ("%AsyncFunction%.prototype", "Object.getPrototypeOf(async function(){}).constructor", "'prototype'", "---"),
        ("%AsyncFunction%.prototype.constructor", "Object.getPrototypeOf(async function(){}).constructor.prototype", "'constructor'", "--C"),
        ("Object.prototype", "Object", "'prototype'", "---"),
        ("Object.prototype.constructor", "Object.prototype", "'constructor'", "W-C"),
        ("Function.prototype", "Function", "'prototype'", "---"),
        ("Function.prototype.constructor", "Function.prototype", "'constructor'", "W-C"),
        ("Array.prototype", "Array", "'prototype'", "---"),
        ("Array.prototype.constructor", "Array.prototype", "'constructor'", "W-C"),
        ("String.prototype", "String", "'prototype'", "---"),
        ("String.prototype.constructor", "String.prototype", "'constructor'", "W-C"),
        ("Number.prototype", "Number", "'prototype'", "---"),
        ("Number.prototype.constructor", "Number.prototype", "'constructor'", "W-C"),
        ("Boolean.prototype", "Boolean", "'prototype'", "---"),
        ("Boolean.prototype.constructor", "Boolean.prototype", "'constructor'", "W-C"),
        ("Symbol.prototype", "Symbol", "'prototype'", "---"),
        ("Symbol.prototype.constructor", "Symbol.prototype", "'constructor'", "W-C"),
        ("BigInt.prototype", "BigInt", "'prototype'", "---"),
        ("BigInt.prototype.constructor", "BigInt.prototype", "'constructor'", "W-C"),
        ("Date.prototype", "Date", "'prototype'", "---"),
        ("Date.prototype.constructor", "Date.prototype", "'constructor'", "W-C"),
        ("RegExp.prototype", "RegExp", "'prototype'", "---"),
        ("RegExp.prototype.constructor", "RegExp.prototype", "'constructor'", "W-C"),
        ("Error.prototype", "Error", "'prototype'", "---"),
        ("Error.prototype.constructor", "Error.prototype", "'constructor'", "W-C"),
        ("EvalError.prototype", "EvalError", "'prototype'", "---"),
        ("EvalError.prototype.constructor", "EvalError.prototype", "'constructor'", "W-C"),
        ("RangeError.prototype", "RangeError", "'prototype'", "---"),
        ("RangeError.prototype.constructor", "RangeError.prototype", "'constructor'", "W-C"),
        ("ReferenceError.prototype", "ReferenceError", "'prototype'", "---"),
        ("ReferenceError.prototype.constructor", "ReferenceError.prototype", "'constructor'", "W-C"),
        ("SyntaxError.prototype", "SyntaxError", "'prototype'", "---"),
        ("SyntaxError.prototype.constructor", "SyntaxError.prototype", "'constructor'", "W-C"),
        ("TypeError.prototype", "TypeError", "'prototype'", "---"),
        ("TypeError.prototype.constructor", "TypeError.prototype", "'constructor'", "W-C"),
        ("URIError.prototype", "URIError", "'prototype'", "---"),
        ("URIError.prototype.constructor", "URIError.prototype", "'constructor'", "W-C"),
        ("AggregateError.prototype", "AggregateError", "'prototype'", "---"),
        ("AggregateError.prototype.constructor", "AggregateError.prototype", "'constructor'", "W-C"),
        ("Promise.prototype", "Promise", "'prototype'", "---"),
        ("Promise.prototype.constructor", "Promise.prototype", "'constructor'", "W-C"),
        ("Map.prototype", "Map", "'prototype'", "---"),
        ("Map.prototype.constructor", "Map.prototype", "'constructor'", "W-C"),
        ("Set.prototype", "Set", "'prototype'", "---"),
        ("Set.prototype.constructor", "Set.prototype", "'constructor'", "W-C"),
        ("WeakMap.prototype", "WeakMap", "'prototype'", "---"),
        ("WeakMap.prototype.constructor", "WeakMap.prototype", "'constructor'", "W-C"),
        ("WeakSet.prototype", "WeakSet", "'prototype'", "---"),
        ("WeakSet.prototype.constructor", "WeakSet.prototype", "'constructor'", "W-C"),
        ("WeakRef.prototype", "WeakRef", "'prototype'", "---"),
        ("WeakRef.prototype.constructor", "WeakRef.prototype", "'constructor'", "W-C"),
        ("FinalizationRegistry.prototype", "FinalizationRegistry", "'prototype'", "---"),
        ("FinalizationRegistry.prototype.constructor", "FinalizationRegistry.prototype", "'constructor'", "W-C"),
        ("ArrayBuffer.prototype", "ArrayBuffer", "'prototype'", "---"),
        ("ArrayBuffer.prototype.constructor", "ArrayBuffer.prototype", "'constructor'", "W-C"),
        ("SharedArrayBuffer.prototype", "SharedArrayBuffer", "'prototype'", "---"),
        ("SharedArrayBuffer.prototype.constructor", "SharedArrayBuffer.prototype", "'constructor'", "W-C"),
        ("DataView.prototype", "DataView", "'prototype'", "---"),
        ("DataView.prototype.constructor", "DataView.prototype", "'constructor'", "W-C"),
        ("Int8Array.prototype", "Int8Array", "'prototype'", "---"),
        ("Int8Array.prototype.constructor", "Int8Array.prototype", "'constructor'", "W-C"),
        ("Uint8Array.prototype", "Uint8Array", "'prototype'", "---"),
        ("Uint8Array.prototype.constructor", "Uint8Array.prototype", "'constructor'", "W-C"),
        ("Uint8ClampedArray.prototype", "Uint8ClampedArray", "'prototype'", "---"),
        ("Uint8ClampedArray.prototype.constructor", "Uint8ClampedArray.prototype", "'constructor'", "W-C"),
        ("Int16Array.prototype", "Int16Array", "'prototype'", "---"),
        ("Int16Array.prototype.constructor", "Int16Array.prototype", "'constructor'", "W-C"),
        ("Uint16Array.prototype", "Uint16Array", "'prototype'", "---"),
        ("Uint16Array.prototype.constructor", "Uint16Array.prototype", "'constructor'", "W-C"),
        ("Int32Array.prototype", "Int32Array", "'prototype'", "---"),
        ("Int32Array.prototype.constructor", "Int32Array.prototype", "'constructor'", "W-C"),
        ("Uint32Array.prototype", "Uint32Array", "'prototype'", "---"),
        ("Uint32Array.prototype.constructor", "Uint32Array.prototype", "'constructor'", "W-C"),
        ("Float32Array.prototype", "Float32Array", "'prototype'", "---"),
        ("Float32Array.prototype.constructor", "Float32Array.prototype", "'constructor'", "W-C"),
        ("Float64Array.prototype", "Float64Array", "'prototype'", "---"),
        ("Float64Array.prototype.constructor", "Float64Array.prototype", "'constructor'", "W-C"),
        ("BigInt64Array.prototype", "BigInt64Array", "'prototype'", "---"),
        ("BigInt64Array.prototype.constructor", "BigInt64Array.prototype", "'constructor'", "W-C"),
        ("BigUint64Array.prototype", "BigUint64Array", "'prototype'", "---"),
        ("BigUint64Array.prototype.constructor", "BigUint64Array.prototype", "'constructor'", "W-C"),
        ("Iterator.prototype", "Iterator", "'prototype'", "---"),
        ("Intl.Collator.prototype", "Intl.Collator", "'prototype'", "---"),
        ("Intl.Collator.prototype.constructor", "Intl.Collator.prototype", "'constructor'", "W-C"),
        ("Intl.DateTimeFormat.prototype", "Intl.DateTimeFormat", "'prototype'", "---"),
        ("Intl.DateTimeFormat.prototype.constructor", "Intl.DateTimeFormat.prototype", "'constructor'", "W-C"),
        ("Intl.NumberFormat.prototype", "Intl.NumberFormat", "'prototype'", "---"),
        ("Intl.NumberFormat.prototype.constructor", "Intl.NumberFormat.prototype", "'constructor'", "W-C"),
        ("Intl.PluralRules.prototype", "Intl.PluralRules", "'prototype'", "---"),
        ("Intl.PluralRules.prototype.constructor", "Intl.PluralRules.prototype", "'constructor'", "W-C"),
        ("Intl.RelativeTimeFormat.prototype", "Intl.RelativeTimeFormat", "'prototype'", "---"),
        ("Intl.RelativeTimeFormat.prototype.constructor", "Intl.RelativeTimeFormat.prototype", "'constructor'", "W-C"),
        ("Intl.ListFormat.prototype", "Intl.ListFormat", "'prototype'", "---"),
        ("Intl.ListFormat.prototype.constructor", "Intl.ListFormat.prototype", "'constructor'", "W-C"),
        ("Intl.Locale.prototype", "Intl.Locale", "'prototype'", "---"),
        ("Intl.Locale.prototype.constructor", "Intl.Locale.prototype", "'constructor'", "W-C"),
        ("Intl.Segmenter.prototype", "Intl.Segmenter", "'prototype'", "---"),
        ("Intl.Segmenter.prototype.constructor", "Intl.Segmenter.prototype", "'constructor'", "W-C"),
        ("Intl.DisplayNames.prototype", "Intl.DisplayNames", "'prototype'", "---"),
        ("Intl.DisplayNames.prototype.constructor", "Intl.DisplayNames.prototype", "'constructor'", "W-C"),
        ("Iterator.prototype.constructor (accessor)", "Iterator.prototype", "'constructor'", "gs-C"),
        ("Proxy has no prototype", "Proxy", "'prototype'", "MISSING"),
        ("%GeneratorFunction.prototype%.prototype", "Object.getPrototypeOf(function*(){})", "'prototype'", "--C"),
        ("%GeneratorPrototype%.constructor", "Object.getPrototypeOf(function*(){}).prototype", "'constructor'", "--C"),
        ("%AsyncGeneratorFunction.prototype%.prototype", "Object.getPrototypeOf(async function*(){})", "'prototype'", "--C"),
        ("%AsyncGeneratorPrototype%.constructor", "Object.getPrototypeOf(async function*(){}).prototype", "'constructor'", "--C"),
        ("%GeneratorFunction.prototype%[@@toStringTag]", "Object.getPrototypeOf(function*(){})", "Symbol.toStringTag", "--C"),
        ("%AsyncGeneratorFunction.prototype%[@@toStringTag]", "Object.getPrototypeOf(async function*(){})", "Symbol.toStringTag", "--C"),
        ("%AsyncFunction.prototype%[@@toStringTag]", "Object.getPrototypeOf(async function(){})", "Symbol.toStringTag", "--C"),
        ("Function.prototype.length", "Function.prototype", "'length'", "--C"),
        ("Function.prototype.name", "Function.prototype", "'name'", "--C"),
        ("Object.length", "Object", "'length'", "--C"),
        ("Object.name", "Object", "'name'", "--C"),
        ("Symbol.length", "Symbol", "'length'", "--C"),
        ("Symbol.name", "Symbol", "'name'", "--C"),
        ("BigInt.length", "BigInt", "'length'", "--C"),
        ("BigInt.name", "BigInt", "'name'", "--C"),
        ("Proxy.length", "Proxy", "'length'", "--C"),
        ("Proxy.name", "Proxy", "'name'", "--C"),
        ("Promise.length", "Promise", "'length'", "--C"),
        ("Promise.name", "Promise", "'name'", "--C"),
        ("Map.length", "Map", "'length'", "--C"),
        ("Map.name", "Map", "'name'", "--C"),
        ("Symbol.asyncIterator", "Symbol", "'asyncIterator'", "---"),
        ("Symbol.hasInstance", "Symbol", "'hasInstance'", "---"),
        ("Symbol.isConcatSpreadable", "Symbol", "'isConcatSpreadable'", "---"),
        ("Symbol.iterator", "Symbol", "'iterator'", "---"),
        ("Symbol.match", "Symbol", "'match'", "---"),
        ("Symbol.matchAll", "Symbol", "'matchAll'", "---"),
        ("Symbol.replace", "Symbol", "'replace'", "---"),
        ("Symbol.search", "Symbol", "'search'", "---"),
        ("Symbol.species", "Symbol", "'species'", "---"),
        ("Symbol.split", "Symbol", "'split'", "---"),
        ("Symbol.toPrimitive", "Symbol", "'toPrimitive'", "---"),
        ("Symbol.toStringTag", "Symbol", "'toStringTag'", "---"),
        ("Symbol.unscopables", "Symbol", "'unscopables'", "---"),
        ("Math[@@toStringTag]", "Math", "Symbol.toStringTag", "--C"),
        ("JSON[@@toStringTag]", "JSON", "Symbol.toStringTag", "--C"),
        ("Reflect[@@toStringTag]", "Reflect", "Symbol.toStringTag", "--C"),
        ("Atomics[@@toStringTag]", "Atomics", "Symbol.toStringTag", "--C"),
        ("Symbol.prototype[@@toStringTag]", "Symbol.prototype", "Symbol.toStringTag", "--C"),
        ("BigInt.prototype[@@toStringTag]", "BigInt.prototype", "Symbol.toStringTag", "--C"),
        ("Promise.prototype[@@toStringTag]", "Promise.prototype", "Symbol.toStringTag", "--C"),
        ("Map.prototype[@@toStringTag]", "Map.prototype", "Symbol.toStringTag", "--C"),
        ("Set.prototype[@@toStringTag]", "Set.prototype", "Symbol.toStringTag", "--C"),
        ("WeakMap.prototype[@@toStringTag]", "WeakMap.prototype", "Symbol.toStringTag", "--C"),
        ("WeakSet.prototype[@@toStringTag]", "WeakSet.prototype", "Symbol.toStringTag", "--C"),
        ("WeakRef.prototype[@@toStringTag]", "WeakRef.prototype", "Symbol.toStringTag", "--C"),
        ("FinalizationRegistry.prototype[@@toStringTag]", "FinalizationRegistry.prototype", "Symbol.toStringTag", "--C"),
        ("ArrayBuffer.prototype[@@toStringTag]", "ArrayBuffer.prototype", "Symbol.toStringTag", "--C"),
        ("SharedArrayBuffer.prototype[@@toStringTag]", "SharedArrayBuffer.prototype", "Symbol.toStringTag", "--C"),
        ("DataView.prototype[@@toStringTag]", "DataView.prototype", "Symbol.toStringTag", "--C"),
        ("%TypedArray%.prototype[@@toStringTag]", "Object.getPrototypeOf(Int8Array).prototype", "Symbol.toStringTag", "g--C"),
        ("%MapIteratorPrototype%[@@toStringTag]", "Object.getPrototypeOf(new Map().entries())", "Symbol.toStringTag", "--C"),
        ("%SetIteratorPrototype%[@@toStringTag]", "Object.getPrototypeOf(new Set().values())", "Symbol.toStringTag", "--C"),
        ("Number.MAX_VALUE", "Number", "'MAX_VALUE'", "---"),
        ("Number.MIN_VALUE", "Number", "'MIN_VALUE'", "---"),
        ("Number.NaN", "Number", "'NaN'", "---"),
        ("Number.NEGATIVE_INFINITY", "Number", "'NEGATIVE_INFINITY'", "---"),
        ("Number.POSITIVE_INFINITY", "Number", "'POSITIVE_INFINITY'", "---"),
        ("Number.EPSILON", "Number", "'EPSILON'", "---"),
        ("Number.MAX_SAFE_INTEGER", "Number", "'MAX_SAFE_INTEGER'", "---"),
        ("Number.MIN_SAFE_INTEGER", "Number", "'MIN_SAFE_INTEGER'", "---"),
        ("Math.E", "Math", "'E'", "---"),
        ("Math.LN10", "Math", "'LN10'", "---"),
        ("Math.LN2", "Math", "'LN2'", "---"),
        ("Math.LOG10E", "Math", "'LOG10E'", "---"),
        ("Math.LOG2E", "Math", "'LOG2E'", "---"),
        ("Math.PI", "Math", "'PI'", "---"),
        ("Math.SQRT1_2", "Math", "'SQRT1_2'", "---"),
        ("Math.SQRT2", "Math", "'SQRT2'", "---"),
        ("globalThis.undefined", "globalThis", "'undefined'", "---"),
        ("globalThis.NaN", "globalThis", "'NaN'", "---"),
        ("globalThis.Infinity", "globalThis", "'Infinity'", "---"),
        ("globalThis.globalThis", "globalThis", "'globalThis'", "W-C"),
        ("Array.prototype[@@unscopables]", "Array.prototype", "Symbol.unscopables", "--C"),
        ("Array.prototype[@@unscopables].at", "Array.prototype[Symbol.unscopables]", "'at'", "WEC"),
        ("Array.prototype[@@iterator]", "Array.prototype", "Symbol.iterator", "W-C"),
        ("Iterator.prototype[@@iterator]", "Iterator.prototype", "Symbol.iterator", "W-C"),
        ("RegExp.prototype.flags", "RegExp.prototype", "'flags'", "g--C"),
        ("RegExp.prototype.global", "RegExp.prototype", "'global'", "g--C"),
        ("RegExp.prototype.ignoreCase", "RegExp.prototype", "'ignoreCase'", "g--C"),
        ("RegExp.prototype.multiline", "RegExp.prototype", "'multiline'", "g--C"),
        ("RegExp.prototype.dotAll", "RegExp.prototype", "'dotAll'", "g--C"),
        ("RegExp.prototype.unicode", "RegExp.prototype", "'unicode'", "g--C"),
        ("RegExp.prototype.unicodeSets", "RegExp.prototype", "'unicodeSets'", "g--C"),
        ("RegExp.prototype.sticky", "RegExp.prototype", "'sticky'", "g--C"),
        ("RegExp.prototype.hasIndices", "RegExp.prototype", "'hasIndices'", "g--C"),
        ("RegExp.prototype.source", "RegExp.prototype", "'source'", "g--C"),
        ("Array[@@species]", "Array", "Symbol.species", "g--C"),
        ("Map[@@species]", "Map", "Symbol.species", "g--C"),
        ("Set[@@species]", "Set", "Symbol.species", "g--C"),
        ("RegExp[@@species]", "RegExp", "Symbol.species", "g--C"),
        ("Promise[@@species]", "Promise", "Symbol.species", "g--C"),
        ("ArrayBuffer[@@species]", "ArrayBuffer", "Symbol.species", "g--C"),
        ("SharedArrayBuffer[@@species]", "SharedArrayBuffer", "Symbol.species", "g--C"),
        ("%TypedArray%[@@species]", "Object.getPrototypeOf(Int8Array)", "Symbol.species", "g--C"),
        ("Int8Array.BYTES_PER_ELEMENT", "Int8Array", "'BYTES_PER_ELEMENT'", "---"),
        ("Int8Array.prototype.BYTES_PER_ELEMENT", "Int8Array.prototype", "'BYTES_PER_ELEMENT'", "---"),
        ("Uint8Array.BYTES_PER_ELEMENT", "Uint8Array", "'BYTES_PER_ELEMENT'", "---"),
        ("Uint8Array.prototype.BYTES_PER_ELEMENT", "Uint8Array.prototype", "'BYTES_PER_ELEMENT'", "---"),
        ("Float64Array.BYTES_PER_ELEMENT", "Float64Array", "'BYTES_PER_ELEMENT'", "---"),
        ("Float64Array.prototype.BYTES_PER_ELEMENT", "Float64Array.prototype", "'BYTES_PER_ELEMENT'", "---"),
        ("BigInt64Array.BYTES_PER_ELEMENT", "BigInt64Array", "'BYTES_PER_ELEMENT'", "---"),
        ("BigInt64Array.prototype.BYTES_PER_ELEMENT", "BigInt64Array.prototype", "'BYTES_PER_ELEMENT'", "---"),
        ("Error.prototype.message", "Error.prototype", "'message'", "W-C"),
        ("Error.prototype.name", "Error.prototype", "'name'", "W-C"),
        ("TypeError.prototype.message", "TypeError.prototype", "'message'", "W-C"),
        ("TypeError.prototype.name", "TypeError.prototype", "'name'", "W-C"),
        ("RangeError.prototype.message", "RangeError.prototype", "'message'", "W-C"),
        ("RangeError.prototype.name", "RangeError.prototype", "'name'", "W-C"),
        ("AggregateError.prototype.message", "AggregateError.prototype", "'message'", "W-C"),
        ("AggregateError.prototype.name", "AggregateError.prototype", "'name'", "W-C"),
        ("Array.prototype.length", "Array.prototype", "'length'", "W--"),
        ("String.prototype.length", "String.prototype", "'length'", "---"),
        ("Symbol.prototype[@@toPrimitive]", "Symbol.prototype", "Symbol.toPrimitive", "--C"),
        ("Date.prototype[@@toPrimitive]", "Date.prototype", "Symbol.toPrimitive", "--C"),
        ("Function.prototype[@@hasInstance]", "Function.prototype", "Symbol.hasInstance", "---"),
        ("Object.prototype.__proto__", "Object.prototype", "'__proto__'", "gs-C")
    ]

    static let intrinsicFlagsJS = """
        function __iaFlags(o, k) { var d = Object.getOwnPropertyDescriptor(o, k); if (!d) return 'MISSING';
          var s = ('value' in d || 'writable' in d) ? (d.writable ? 'W' : '-') : (d.get ? 'g' : '-') + (d.set ? 's' : '-');
          return s + (d.enumerable ? 'E' : '-') + (d.configurable ? 'C' : '-'); }
        """

    mutating func testIntrinsicAttributes() {
        // A runtime of its own: the cases below try to replace builtins.
        let rt = JeffJSRuntime()
        let ctx = rt.newContext()
        func ev(_ js: String) -> String {
            let r = ctx.eval(input: js, filename: "<IntrinsicAttributes>", evalFlags: JS_EVAL_TYPE_GLOBAL)
            defer { r.freeValue() }
            if r.isException {
                let e = ctx.getException(); defer { e.freeValue() }
                return "THREW " + (ctx.toSwiftString(e) ?? "?")
            }
            return ctx.toSwiftString(r) ?? "?"
        }
        _ = ev(Self.intrinsicFlagsJS)
        // Intl comes with the environment (JeffJSIntlBridge): checked below.
        for (label, obj, key, want) in Self.intrinsicAttributeTable where !obj.hasPrefix("Intl.") {
            let got = ev("__iaFlags(\(obj), \(key))")
            assert(got == want, "IntrinsicAttributes: \(label) is \(got), spec \(want)")
        }

        // Behaviour the attributes imply (sloppy [[Set]] fails silently, strict
        // throws, delete answers false, [[DefineOwnProperty]] with another value
        // throws, with the same value succeeds).
        let cases: [(String, String)] = [
            ("sloppy assignment cannot replace Object.prototype",
             "(function(){ var P = Object.prototype; Object.prototype = {}; Array.prototype = []; Function.prototype = null; return Object.prototype === P && ({}) instanceof Object && [] instanceof Array; })()"),
            ("strict assignment throws TypeError",
             "(function(){ 'use strict'; try { Map.prototype = {}; return false; } catch (e) { return e instanceof TypeError; } })()"),
            ("delete answers false and keeps the link",
             "(function(){ var P = Error.prototype; return delete Error.prototype === false && delete TypeError.prototype === false && Error.prototype === P && new TypeError('x') instanceof Error; })()"),
            ("defineProperty with another value throws, with the same value succeeds",
             "(function(){ try { Object.defineProperty(Promise, 'prototype', { value: {} }); return false; } catch (e) {} Object.defineProperty(Promise, 'prototype', { value: Promise.prototype }); return Promise.resolve(1) instanceof Promise; })()"),
            ("Reflect.set / Reflect.defineProperty / Reflect.deleteProperty answer false",
             "Reflect.set(Date, 'prototype', {}) === false && Reflect.defineProperty(RegExp, 'prototype', { value: {} }) === false && Reflect.deleteProperty(Symbol, 'iterator') === false"),
            ("constructor back-links stay writable (core-js replaces them)",
             "(function(){ var C = WeakMap.prototype.constructor; WeakMap.prototype.constructor = function W(){}; var ok = WeakMap.prototype.constructor.name === 'W'; WeakMap.prototype.constructor = C; return ok && Object.keys(WeakMap.prototype).length === 0; })()"),
            ("well-known symbols and constants cannot be overwritten",
             "(function(){ var it = Symbol.iterator; Symbol.iterator = 1; Math.PI = 3; Number.MAX_SAFE_INTEGER = 1; Int8Array.BYTES_PER_ELEMENT = 9; return Symbol.iterator === it && Math.PI === 3.141592653589793 && Number.MAX_SAFE_INTEGER === 9007199254740991 && Int8Array.BYTES_PER_ELEMENT === 1; })()"),
            ("Math constants keep their values",
             "Math.E === 2.718281828459045 && Math.LN10 === 2.302585092994046 && Math.LN2 === 0.6931471805599453 && Math.LOG10E === 0.4342944819032518 && Math.LOG2E === 1.4426950408889634 && Math.SQRT1_2 === 0.7071067811865476 && Math.SQRT2 === 1.4142135623730951"),
            ("no string-keyed '@@toStringTag' / 'toStringTag' junk, no Proxy.Proxy",
             "Object.getOwnPropertyNames(Promise.prototype).indexOf('@@toStringTag') < 0 && Object.getOwnPropertyNames(JSON).indexOf('@@toStringTag') < 0 && Object.getOwnPropertyNames(Object.getPrototypeOf(function*(){})).indexOf('toStringTag') < 0 && !Object.prototype.hasOwnProperty.call(Proxy, 'Proxy') && Proxy.name === 'Proxy' && Proxy.length === 2"),
            ("@@species getters answer this",
             "Map[Symbol.species] === Map && Set[Symbol.species] === Set && RegExp[Symbol.species] === RegExp && Promise[Symbol.species] === Promise && ArrayBuffer[Symbol.species] === ArrayBuffer && Object.getPrototypeOf(Int8Array)[Symbol.species] === Object.getPrototypeOf(Int8Array) && Object.getOwnPropertyDescriptor(Map, Symbol.species).get.name === 'get [Symbol.species]'"),
            ("Array.prototype[@@unscopables] is a null-prototype list",
             "(function(){ var u = Array.prototype[Symbol.unscopables]; return Object.getPrototypeOf(u) === null && u.flat === true && u.values === true && u.map === undefined && Object.keys(u).length === 16; })()"),
            ("Symbol.prototype[@@toPrimitive]",
             "(function(){ var f = Symbol.prototype[Symbol.toPrimitive], s = Symbol('q'); return f.name === '[Symbol.toPrimitive]' && f.length === 1 && f.call(s) === s && f.call(Object(s)) === s; })()"),
            ("prototype lengths: String.prototype 0, Array.prototype 0; primitives unaffected",
             "String.prototype.length === 0 && Array.prototype.length === 0 && 'abc'.length === 3 && new String('ab').length === 2 && [1,2].length === 2 && Array.isArray(Array.prototype)"),
            ("%GeneratorFunction% / %AsyncGeneratorFunction% / %AsyncFunction% build their kind",
             "(function(){ var GF = Object.getPrototypeOf(function*(){}).constructor, AGF = Object.getPrototypeOf(async function*(){}).constructor, AF = Object.getPrototypeOf(async function(){}).constructor; var g = new GF('a', 'yield a; yield a + 1'); var it = g(5); return GF !== Function && GF.name === 'GeneratorFunction' && GF.length === 1 && Object.getPrototypeOf(GF) === Function && it.next().value === 5 && it.next().value === 6 && Object.getPrototypeOf(g) === GF.prototype && Object.getPrototypeOf(AF('return 1')) === AF.prototype && Object.getPrototypeOf(AGF('yield 1')) === AGF.prototype && AF.name === 'AsyncFunction' && AGF.name === 'AsyncGeneratorFunction' && typeof globalThis.GeneratorFunction === 'undefined'; })()"),
            ("%AsyncFunction% result runs",
             "(function(){ var AF = Object.getPrototypeOf(async function(){}).constructor; return AF('a', 'return await a * 2')(21) instanceof Promise; })()"),
        ]
        for (name, js) in cases {
            let got = ev(js)
            assert(got == "true", "IntrinsicAttributes: \(name) -> \(got)")
        }

        // Host-side writes still win: the internal define the host glue uses
        // (SafariSurfaceOrder forces captured attributes, iframe realms re-run
        // setup) replaces a non-configurable link instead of failing.
        let objCtor = ctx.getPropertyStr(obj: ctx.globalObj, name: "Object")
        let objProto = ctx.getPropertyStr(obj: objCtor, name: "prototype")
        let replacement = ctx.newObject()
        _ = ctx.definePropertyValue(obj: objCtor, atom: JeffJSAtomID.JS_ATOM_prototype.rawValue,
                                    value: replacement, flags: 0)
        assert(ev("Object.prototype !== Object.getPrototypeOf({}) && __iaFlags(Object, 'prototype') === '---'") == "true",
               "IntrinsicAttributes: an internal define replaces a non-configurable prototype")
        ctx.defineIntrinsicPrototype(ctor: objCtor, proto: objProto)
        assert(ev("Object.prototype === Object.getPrototypeOf({}) && __iaFlags(Object, 'prototype') === '---'") == "true",
               "IntrinsicAttributes: defineIntrinsicPrototype restores the link")
        replacement.freeValue(); objProto.freeValue(); objCtor.freeValue()

        // A second context of a live runtime (a realm) builds the same links.
        let ctx2 = rt.newContext()
        let r2 = ctx2.eval(input: Self.intrinsicFlagsJS + "; __iaFlags(Object, 'prototype') + __iaFlags(TypeError, 'prototype') + __iaFlags(Symbol, 'iterator') + __iaFlags(Math, 'PI') + (({}) instanceof Object)",
                           filename: "<IntrinsicAttributes>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        assert(ctx2.toSwiftString(r2) == "------------true", "IntrinsicAttributes: second context -> \(ctx2.toSwiftString(r2) ?? "?")")
        r2.freeValue()

        // In an environment: the Intl constructors (an eval'd shim of function
        // declarations, whose `prototype` is made non-writable), and the host
        // constructors made with newConstructorFunc (URL, URLSearchParams) get
        // the WebIDL attributes too.
        var hostOut = ""
        var intlOut: [(String, String, String)] = []
        let intlRows = Self.intrinsicAttributeTable.filter { $0.1.hasPrefix("Intl.") }
        let hostBody: @JeffJSHostActor () -> Void = {
            let env = JeffJSEnvironment()
            @JeffJSHostActor func run(_ js: String) -> String {
                switch env.eval(js, filename: "<IntrinsicAttributes>") {
                case .success(let v): return v ?? "undefined"
                case .exception(let m): return "THREW " + m
                }
            }
            _ = run(Self.intrinsicFlagsJS)
            hostOut = run("__iaFlags(URL, 'prototype') + __iaFlags(URL.prototype, 'constructor') + __iaFlags(URLSearchParams, 'prototype') + (new URL('https://a.b/c').pathname)")
            for (label, obj, key, want) in intlRows {
                intlOut.append((label, run("__iaFlags(\(obj), \(key))"), want))
            }
            intlOut.append(("Intl.NumberFormat still formats", run("new Intl.NumberFormat('en-US').format(1234.5)"), "1,234.5"))
        }
        if Thread.isMainThread { JeffJSHostActor.assumeIsolated { hostBody() } } else { DispatchQueue.main.sync { JeffJSHostActor.assumeIsolated { hostBody() } } }
        assert(hostOut == "---W-C---/c", "IntrinsicAttributes: URL / URLSearchParams -> \(hostOut)")
        for (label, got, want) in intlOut {
            assert(got == want, "IntrinsicAttributes: \(label) is \(got), spec \(want)")
        }
    }
}
