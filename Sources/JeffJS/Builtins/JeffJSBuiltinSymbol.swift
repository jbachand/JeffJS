// JeffJSBuiltinSymbol.swift
// JeffJS - 1:1 Swift port of QuickJS JavaScript engine
//
// Port of the Symbol built-in from QuickJS.
// Covers:
//   - Symbol() constructor (cannot be called with `new`)
//   - Symbol.for(key) / Symbol.keyFor(sym)
//   - Symbol.prototype: toString, valueOf, description, [Symbol.toPrimitive]
//   - All well-known symbols as static properties
//   - thisSymbolValue helper (unwrap Symbol objects)
//
// QuickJS source reference: quickjs.c — js_symbol_*, JS_NewSymbol,
// Symbol constructor/prototype init, well-known symbol atoms.

import Foundation

// MARK: - Global Symbol Registry

/// The global symbol registry, keyed by string description.
/// Used by Symbol.for() and Symbol.keyFor().
///
/// In QuickJS this is implemented through the atom table with
/// JS_ATOM_TYPE_GLOBAL_SYMBOL atoms. We replicate that here.
///
/// Thread safety: In a single-threaded JS engine this needs no locking.
/// If multi-context support is added, the registry lives on the runtime.
final class JeffJSSymbolRegistry {
    /// Maps description string -> atom index of the global symbol.
    var entries: [String: UInt32] = [:]

    /// Reverse map: atom index -> description string.
    var reverseEntries: [UInt32: String] = [:]

    init() {}
}

// MARK: - thisSymbolValue Helper

/// Extract the symbol atom from a value that is either a bare Symbol
/// or a Symbol wrapper object (boxed Symbol).
///
/// Mirrors `js_thisBooleanValue` / `js_thisNumberValue` pattern in QuickJS.
///
/// Returns the atom on success, or throws TypeError and returns 0 on failure.
private func thisSymbolValue(_ ctx: JeffJSContext,
                             _ thisVal: JeffJSValue) -> UInt32 {
    // Case 1: bare symbol value (tag == .symbol)
    if thisVal.isSymbol {
        if let atomEntry = thisVal.heapRef as? JSAtomEntry {
            _ = atomEntry  // The atom identity is the pointer itself.
        }
        // In JeffJS, a symbol value wraps an atom index in its int32 payload
        // or pointer payload. The atom index IS the symbol identity.
        // We return a sentinel to indicate "is a symbol".
        return extractSymbolAtom(thisVal)
    }

    // Case 2: Symbol wrapper object (classID == .symbol)
    if let obj = thisVal.toObject(),
       obj.classID == JeffJSClassID.symbol.rawValue {
        if case .objectData(let inner) = obj.payload {
            return extractSymbolAtom(inner)
        }
    }

    _ = ctx.throwTypeError("Symbol.prototype method called on non-Symbol value")
    return 0
}

/// Extract the atom index from a symbol JeffJSValue.
/// Symbols are stored as mkPtr(.symbol, ptr) where the ptr holds the
/// atom entry, or as a tagged int for well-known symbols.
private func extractSymbolAtom(_ val: JeffJSValue) -> UInt32 {
    if val.isInt {
        return UInt32(bitPattern: val.toInt32())
    }
    if let ref = val.heapRef {
        if let entry = ref as? JSAtomEntry {
            return entry.hash
        }
        return UInt32(ObjectIdentifier(ref).hashValue & 0x7FFF_FFFF)
    }
    return 0
}

// MARK: - Symbol Constructor

/// Symbol([description]) - creates a new unique symbol.
/// Cannot be called with `new` (throws TypeError).
///
/// Mirrors `js_symbol_constructor` in QuickJS.
func js_symbol_constructor(_ ctx: JeffJSContext,
                           _ newTarget: JeffJSValue,
                           _ argv: [JeffJSValue],
                           _ isConstructorCall: Bool) -> JeffJSValue {
    // Symbol cannot be called with `new`.
    if isConstructorCall {
        return ctx.throwTypeError("Symbol is not a constructor")
    }

    // Get the optional description.
    var description: String? = nil
    if !argv.isEmpty && !argv[0].isUndefined {
        if argv[0].isString, let str = argv[0].stringValue {
            description = str.toSwiftString()
        } else if argv[0].isInt {
            description = String(argv[0].toInt32())
        } else if argv[0].isFloat64 {
            description = String(argv[0].toFloat64())
        } else if argv[0].isBool {
            description = argv[0].toBool() ? "true" : "false"
        } else if argv[0].isNull {
            description = "null"
        }
    }

    // Create a new unique symbol atom.
    // In QuickJS, this calls JS_NewAtomStr with atom_type = JS_ATOM_TYPE_SYMBOL.
    let descStr = description ?? ""
    let atomStr = JeffJSString(swiftString: descStr)
    atomStr.atomType = JSAtomType.symbol.rawValue

    // The symbol value is the string pointer itself (unique identity).
    return JeffJSValue.mkPtr(tag: .symbol, ptr: atomStr)
}

// MARK: - Symbol.for(key)

/// Symbol.for(key) - returns the symbol from the global registry for the
/// given key, or creates one if it doesn't exist.
///
/// Mirrors `js_symbol_for` in QuickJS.
func js_symbol_for(_ ctx: JeffJSContext,
                   _ thisVal: JeffJSValue,
                   _ argv: [JeffJSValue]) -> JeffJSValue {
    guard !argv.isEmpty else {
        return ctx.throwTypeError("Symbol.for requires a string argument")
    }

    // Convert key to string.
    let keyStr: String
    if argv[0].isString, let str = argv[0].stringValue {
        keyStr = str.toSwiftString()
    } else if argv[0].isUndefined {
        keyStr = "undefined"
    } else if argv[0].isNull {
        keyStr = "null"
    } else if argv[0].isInt {
        keyStr = String(argv[0].toInt32())
    } else if argv[0].isFloat64 {
        keyStr = String(argv[0].toFloat64())
    } else if argv[0].isBool {
        keyStr = argv[0].toBool() ? "true" : "false"
    } else {
        keyStr = ""
    }

    // Look up in the global registry on the runtime.
    let rt = ctx.rt

    // If a global symbol with this key already exists, return it.
    if let existing = rt.globalSymbolRegistry[keyStr] {
        return existing.dupValue()
    }

    // Create a new global symbol with atomType = globalSymbol.
    let atomStr = JeffJSString(swiftString: keyStr)
    atomStr.atomType = JSAtomType.globalSymbol.rawValue
    let symVal = JeffJSValue.mkPtr(tag: .symbol, ptr: atomStr)

    // Store in the registry and return.
    rt.globalSymbolRegistry[keyStr] = symVal.dupValue()
    return symVal
}

// MARK: - Symbol.keyFor(sym)

/// Symbol.keyFor(sym) - returns the key string for a globally registered
/// symbol, or undefined if the symbol is not in the global registry.
///
/// Mirrors `js_symbol_keyFor` in QuickJS.
func js_symbol_keyFor(_ ctx: JeffJSContext,
                      _ thisVal: JeffJSValue,
                      _ argv: [JeffJSValue]) -> JeffJSValue {
    guard !argv.isEmpty else {
        return ctx.throwTypeError("Symbol.keyFor requires a symbol argument")
    }

    guard argv[0].isSymbol else {
        return ctx.throwTypeError("Symbol.keyFor argument must be a symbol")
    }

    // Check the runtime's global symbol registry for a reverse lookup.
    // A symbol is a global symbol if its JeffJSString pointer matches one
    // stored in the registry (pointer identity), or if its atomType is globalSymbol.
    let rt = ctx.rt

    if let atomStr = argv[0].heapRef as? JeffJSString {
        let p: AnyObject = atomStr
        // First, check by pointer identity against the registry.
        for (key, regVal) in rt.globalSymbolRegistry {
            if regVal.heapRef === p {
                return JeffJSValue.makeString(
                    JeffJSString(swiftString: key)
                )
            }
        }

        // Fallback: check atomType flag for global symbols created outside the registry.
        if atomStr.atomType == JSAtomType.globalSymbol.rawValue {
            return JeffJSValue.makeString(
                JeffJSString(swiftString: atomStr.toSwiftString())
            )
        }
    }

    // Not a global symbol.
    return .undefined
}

// MARK: - Symbol.prototype.toString

/// Symbol.prototype.toString() - returns "Symbol(description)".
///
/// Mirrors `js_symbol_toString` in QuickJS.
func js_symbol_toString(_ ctx: JeffJSContext,
                        _ thisVal: JeffJSValue,
                        _ argv: [JeffJSValue]) -> JeffJSValue {
    let atom = thisSymbolValue(ctx, thisVal)
    if atom == 0 && !thisVal.isSymbol {
        // thisSymbolValue already threw.
        return .exception
    }

    // Get the description.
    let desc = getSymbolDescription(thisVal)

    let result = "Symbol(\(desc))"
    return JeffJSValue.makeString(JeffJSString(swiftString: result))
}

// MARK: - Symbol.prototype.valueOf

/// Symbol.prototype.valueOf() - returns the primitive symbol value.
///
/// Mirrors `js_symbol_valueOf` in QuickJS.
func js_symbol_valueOf(_ ctx: JeffJSContext,
                       _ thisVal: JeffJSValue,
                       _ argv: [JeffJSValue]) -> JeffJSValue {
    // If thisVal is already a symbol, return it.
    if thisVal.isSymbol {
        return thisVal.dupValue()
    }

    // If it's a Symbol wrapper object, unwrap.
    if let obj = thisVal.toObject(),
       obj.classID == JeffJSClassID.symbol.rawValue {
        if case .objectData(let inner) = obj.payload {
            return inner.dupValue()
        }
    }

    return ctx.throwTypeError("Symbol.prototype.valueOf called on non-Symbol")
}

// MARK: - Symbol.prototype.description (getter)

/// Symbol.prototype.description getter - returns the description string
/// or undefined if the symbol was created without a description.
///
/// Mirrors `js_symbol_get_description` in QuickJS.
func js_symbol_get_description(_ ctx: JeffJSContext,
                               _ thisVal: JeffJSValue) -> JeffJSValue {
    // Validate that thisVal is a symbol or Symbol wrapper.
    let isValid: Bool
    if thisVal.isSymbol {
        isValid = true
    } else if let obj = thisVal.toObject(),
              obj.classID == JeffJSClassID.symbol.rawValue {
        isValid = true
    } else {
        isValid = false
    }

    guard isValid else {
        return ctx.throwTypeError("Symbol.prototype.description getter called on non-Symbol")
    }

    let desc = getSymbolDescription(thisVal)
    if desc.isEmpty {
        return .undefined
    }
    return JeffJSValue.makeString(JeffJSString(swiftString: desc))
}

/// Helper: extract the description string from a symbol value.
func getSymbolDescription(_ val: JeffJSValue) -> String {
    // Direct symbol.
    if val.isSymbol {
        if let atomStr = val.heapRef as? JeffJSString {
            return atomStr.toSwiftString()
        }
        return ""
    }

    // Symbol wrapper object.
    if let obj = val.toObject(),
       obj.classID == JeffJSClassID.symbol.rawValue,
       case .objectData(let inner) = obj.payload {
        if let atomStr = inner.heapRef as? JeffJSString {
            return atomStr.toSwiftString()
        }
    }

    return ""
}

// MARK: - Symbol.prototype[Symbol.toPrimitive]

/// Symbol.prototype[Symbol.toPrimitive](hint)
/// Returns the primitive symbol value, ignoring the hint.
///
/// Mirrors `js_symbol_toPrimitive` in QuickJS.
func js_symbol_toPrimitive(_ ctx: JeffJSContext,
                           _ thisVal: JeffJSValue,
                           _ argv: [JeffJSValue]) -> JeffJSValue {
    // Same as valueOf: return the primitive symbol.
    return js_symbol_valueOf(ctx, thisVal, argv)
}

// MARK: - Well-Known Symbols

/// Well-known symbol descriptors and their corresponding predefined atom IDs.
/// These are installed as static properties on the Symbol constructor.
///
/// In QuickJS, well-known symbols are predefined atoms with
/// JS_ATOM_TYPE_SYMBOL type, created at runtime initialization.
struct WellKnownSymbol {
    let name: String
    let atomID: UInt32

    /// The description string used in Symbol.prototype.toString output.
    let description: String
}

/// All well-known symbols from the ES specification.
/// The atomID values correspond to the JSPredefinedAtom / JeffJSAtomID enums.
let js_well_known_symbols: [WellKnownSymbol] = [
    WellKnownSymbol(name: "asyncIterator",       atomID: JSPredefinedAtom.Symbol_asyncIterator.rawValue,
                    description: "Symbol.asyncIterator"),
    WellKnownSymbol(name: "hasInstance",          atomID: JSPredefinedAtom.Symbol_hasInstance.rawValue,
                    description: "Symbol.hasInstance"),
    WellKnownSymbol(name: "isConcatSpreadable",  atomID: JSPredefinedAtom.Symbol_isConcatSpreadable.rawValue,
                    description: "Symbol.isConcatSpreadable"),
    WellKnownSymbol(name: "iterator",            atomID: JSPredefinedAtom.Symbol_iterator.rawValue,
                    description: "Symbol.iterator"),
    WellKnownSymbol(name: "match",               atomID: JSPredefinedAtom.Symbol_match.rawValue,
                    description: "Symbol.match"),
    WellKnownSymbol(name: "matchAll",            atomID: JSPredefinedAtom.Symbol_matchAll.rawValue,
                    description: "Symbol.matchAll"),
    WellKnownSymbol(name: "replace",             atomID: JSPredefinedAtom.Symbol_replace.rawValue,
                    description: "Symbol.replace"),
    WellKnownSymbol(name: "search",              atomID: JSPredefinedAtom.Symbol_search.rawValue,
                    description: "Symbol.search"),
    WellKnownSymbol(name: "split",               atomID: JSPredefinedAtom.Symbol_split.rawValue,
                    description: "Symbol.split"),
    WellKnownSymbol(name: "species",             atomID: JSPredefinedAtom.Symbol_species.rawValue,
                    description: "Symbol.species"),
    WellKnownSymbol(name: "toPrimitive",         atomID: JSPredefinedAtom.Symbol_toPrimitive.rawValue,
                    description: "Symbol.toPrimitive"),
    WellKnownSymbol(name: "toStringTag",         atomID: JSPredefinedAtom.Symbol_toStringTag.rawValue,
                    description: "Symbol.toStringTag"),
    WellKnownSymbol(name: "unscopables",         atomID: JSPredefinedAtom.Symbol_unscopables.rawValue,
                    description: "Symbol.unscopables"),
]

// MARK: - Symbol Prototype Function Table

/// Symbol.prototype method registration table.
struct JSSymbolFuncEntry {
    let name: String
    let length: Int
    let funcType: JSSymbolFuncType
}

enum JSSymbolFuncType {
    case generic((JeffJSContext, JeffJSValue, [JeffJSValue]) -> JeffJSValue)
    case getter((JeffJSContext, JeffJSValue) -> JeffJSValue)
}

let js_symbol_proto_funcs: [JSSymbolFuncEntry] = [
    JSSymbolFuncEntry(name: "toString",    length: 0,
                      funcType: .generic(js_symbol_toString)),
    JSSymbolFuncEntry(name: "valueOf",     length: 0,
                      funcType: .generic(js_symbol_valueOf)),
    // [Symbol.toPrimitive] is registered with the well-known symbol atom key,
    // not a string name. In a full engine, this is done via:
    //   JS_DefinePropertyValue(ctx, proto, JS_ATOM_Symbol_toPrimitive, ...)
]

/// Symbol constructor static function table (Symbol.for, Symbol.keyFor).
let js_symbol_static_funcs: [JSSymbolFuncEntry] = [
    JSSymbolFuncEntry(name: "for",     length: 1,
                      funcType: .generic(js_symbol_for)),
    JSSymbolFuncEntry(name: "keyFor",  length: 1,
                      funcType: .generic(js_symbol_keyFor)),
]

// MARK: - Symbol Built-in Initialization

/// Initialize the Symbol constructor, prototype, and well-known symbols.
/// Called during JS context creation.
///
/// Mirrors `JS_AddIntrinsicSymbol` / the Symbol section of
/// `JS_AddIntrinsicBasicObjects` in QuickJS.
///
/// Steps:
/// 1. Create Symbol.prototype with toString, valueOf, description,
///    and [Symbol.toPrimitive].
/// 2. Create the Symbol constructor function.
/// 3. Add Symbol.for and Symbol.keyFor as static methods.
/// 4. Add all well-known symbols as static properties on Symbol.
func js_init_symbol_builtin(_ ctx: JeffJSContext,
                            _ globalObj: JeffJSObject) {
    // 1. Create Symbol.prototype.
    let symProto = JeffJSObject()
    symProto.classID = JeffJSClassID.symbol.rawValue
    symProto.extensible = true
    // The prototype's [[SymbolData]] internal slot holds an empty symbol.
    let emptySymStr = JeffJSString(swiftString: "")
    emptySymStr.atomType = JSAtomType.symbol.rawValue
    symProto.payload = .objectData(JeffJSValue.mkPtr(tag: .symbol, ptr: emptySymStr))

    // 2. Create Symbol constructor.
    let symCtor = JeffJSObject()
    symCtor.classID = JeffJSClassID.cFunction.rawValue
    symCtor.extensible = true
    symCtor.isConstructor = false  // Symbol cannot be used with `new`
    symCtor.payload = .cFunc(
        realm: ctx,
        cFunction: .constructorOrFunc({ ctx, thisVal, argv, isNew in
            return js_symbol_constructor(ctx, thisVal, argv, isNew)
        }),
        length: 0,
        cproto: UInt8(JS_CFUNC_CONSTRUCTOR_OR_FUNC),
        magic: 0
    )

    // 3. Install well-known symbols as static properties on Symbol.
    let symCtorVal = JeffJSValue.makeObject(symCtor)
    for wks in js_well_known_symbols {
        // Each well-known symbol is a symbol-typed atom from the predefined table.
        // We create a symbol value from the atom.
        let symStr = JeffJSString(swiftString: wks.description)
        symStr.atomType = JSAtomType.symbol.rawValue
        let symVal = JeffJSValue.mkPtr(tag: .symbol, ptr: symStr)

        // Install as a non-writable, non-enumerable, non-configurable property.
        _ = ctx.setPropertyStr(obj: symCtorVal, name: wks.name, value: symVal)
    }

    // 4. Install Symbol.for and Symbol.keyFor.
    let symForFunc = ctx.newCFunction({ ctx, thisVal, args in
        return js_symbol_for(ctx, thisVal, args)
    }, name: "for", length: 1)
    _ = ctx.setPropertyStr(obj: symCtorVal, name: "for", value: symForFunc)

    let symKeyForFunc = ctx.newCFunction({ ctx, thisVal, args in
        return js_symbol_keyFor(ctx, thisVal, args)
    }, name: "keyFor", length: 1)
    _ = ctx.setPropertyStr(obj: symCtorVal, name: "keyFor", value: symKeyForFunc)

    // 4b. Install Symbol.prototype methods: toString, valueOf, description getter,
    //     and [Symbol.toPrimitive].
    let symProtoVal = JeffJSValue.makeObject(symProto)

    // Symbol.prototype.toString
    let toStringFunc = ctx.newCFunction({ ctx, thisVal, args in
        return js_symbol_toString(ctx, thisVal, args)
    }, name: "toString", length: 0)
    _ = ctx.setPropertyStr(obj: symProtoVal, name: "toString", value: toStringFunc)

    // Symbol.prototype.valueOf
    let valueOfFunc = ctx.newCFunction({ ctx, thisVal, args in
        return js_symbol_valueOf(ctx, thisVal, args)
    }, name: "valueOf", length: 0)
    _ = ctx.setPropertyStr(obj: symProtoVal, name: "valueOf", value: valueOfFunc)

    // Symbol.prototype.description (getter)
    // Install as a getter property so that `Symbol('foo').description` returns 'foo'.
    jeffJS_addGetterProperty(ctx: ctx, proto: symProto, name: "description") { ctx, thisVal in
        return js_symbol_get_description(ctx, thisVal)
    }

    // Symbol.prototype[Symbol.toPrimitive]
    let toPrimFunc = ctx.newCFunction({ ctx, thisVal, args in
        return js_symbol_toPrimitive(ctx, thisVal, args)
    }, name: "[Symbol.toPrimitive]", length: 1)
    _ = ctx.setPropertyStr(obj: symProtoVal, name: "Symbol.toPrimitive", value: toPrimFunc)

    // 5. Install prototype on constructor and constructor on global.
    _ = ctx.setPropertyStr(obj: symCtorVal, name: "prototype", value: symProtoVal)
    _ = ctx.setPropertyStr(obj: ctx.globalObj, name: "Symbol", value: symCtorVal)
}

// MARK: - Symbol GC Support

/// Finalizer for Symbol wrapper objects.
func js_symbol_finalizer(_ rt: JeffJSRuntime, _ val: JeffJSValue) {
    guard let obj = val.toObject(),
          obj.classID == JeffJSClassID.symbol.rawValue else { return }
    if case .objectData(let inner) = obj.payload {
        inner.freeValue()
        obj.payload = .objectData(.undefined)
    }
}

/// GC mark function for Symbol wrapper objects.
func js_symbol_mark(_ rt: JeffJSRuntime,
                    _ val: JeffJSValue,
                    _ markFunc: (JeffJSValue) -> Void) {
    guard let obj = val.toObject(),
          obj.classID == JeffJSClassID.symbol.rawValue else { return }
    if case .objectData(let inner) = obj.payload {
        markFunc(inner)
    }
}

// MARK: - Symbol Class Definition

/// Class definition for JS_CLASS_SYMBOL.
let js_symbol_class: JeffJSClass = {
    var c = JeffJSClass()
    c.classNameAtom = 0  // Set to "Symbol" atom at init time
    c.finalizer = js_symbol_finalizer
    c.gcMark = js_symbol_mark
    c.call = nil
    c.exotic = nil
    return c
}()
