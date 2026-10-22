// JeffJSTwinReader.swift
// JeffJS — what native twins may read without running page code
// (JeffJSNativeTwins.swift). Every read either answers exactly what the
// replaced code would see or throws JeffJSTwinDecline before anything changed:
// proxies, accessors (a getter or setter would run page code), host objects
// and lazily built objects that cannot be listed are declined.

import Foundation

/// `Object.prototype.toString`'s answer, as a tag.
nonisolated enum JeffJSTwinTag: Equatable {
    case undefined, null, number, string, boolean, symbol, bigint
    case array, object, function, error, date, regexp, arguments, map, set
    case other(String)

    init(name: String) {
        switch name {
        case "Undefined": self = .undefined
        case "Null": self = .null
        case "Number": self = .number
        case "String": self = .string
        case "Boolean": self = .boolean
        case "Symbol": self = .symbol
        case "BigInt": self = .bigint
        case "Array": self = .array
        case "Object": self = .object
        case "Function": self = .function
        case "Error": self = .error
        case "Date": self = .date
        case "RegExp": self = .regexp
        case "Arguments": self = .arguments
        case "Map": self = .map
        case "Set": self = .set
        default: self = .other(name)
        }
    }
}

nonisolated struct JeffJSTwinReader {
    let ctx: JeffJSContext
    let rt: JeffJSRuntime

    init(_ ctx: JeffJSContext) {
        self.ctx = ctx
        self.rt = ctx.rt
    }

    @inline(__always)
    static func isProxy(_ o: JeffJSObject) -> Bool {
        let c = o.classID
        return c == JeffJSClassID.proxy.rawValue || c == JSClassID.JS_CLASS_PROXY.rawValue
    }

    /// `a === b`.
    @inline(__always)
    static func strictEquals(_ a: JeffJSValue, _ b: JeffJSValue) -> Bool {
        return JeffJSOperators.jsStrictEq(lhs: a, rhs: b)
    }

    /// `Object.prototype.toString.call(v)`: the builtin tag of v's class,
    /// then a string @@toStringTag found along its chain (a data property:
    /// an accessor or a proxy on the way declines).
    func tag(_ v: JeffJSValue) throws -> JeffJSTwinTag {
        if v.isUndefined { return .undefined }
        if v.isNull { return .null }
        var builtin: JeffJSTwinTag
        var start: JeffJSObject?
        if let o = v.toObject() {
            if Self.isProxy(o) { throw JeffJSTwinDecline(reason: "proxy") }
            let cid = o.classID
            if cid == JeffJSClassID.array.rawValue { builtin = .array }
            else if ctx.isCallable(v) { builtin = .function }
            else if cid == JeffJSClassID.object.rawValue { builtin = .object }
            else if cid == JeffJSClassID.date.rawValue { builtin = .date }
            else if cid == JeffJSClassID.regexp.rawValue { builtin = .regexp }
            else if cid == JeffJSClassID.error.rawValue { builtin = .error }
            else if cid == JeffJSClassID.arguments.rawValue || cid == JeffJSClassID.mappedArguments.rawValue { builtin = .arguments }
            else if cid == JeffJSClassID.number.rawValue { builtin = .number }
            else if cid == JeffJSClassID.string.rawValue { builtin = .string }
            else if cid == JeffJSClassID.boolean.rawValue { builtin = .boolean }
            else { builtin = .other("?") }   // only a string @@toStringTag can name it
            start = o
        } else {
            // ToObject(v): the wrapper's builtin tag, its prototype's chain.
            let cls: Int
            if v.isNumber { builtin = .number; cls = JSClassID.JS_CLASS_NUMBER.rawValue }
            else if v.isString { builtin = .string; cls = JSClassID.JS_CLASS_STRING.rawValue }
            else if v.isBool { builtin = .boolean; cls = JSClassID.JS_CLASS_BOOLEAN.rawValue }
            else if v.isSymbol { builtin = .object; cls = JSClassID.JS_CLASS_SYMBOL.rawValue }
            else if v.isBigInt { builtin = .object; cls = JSClassID.JS_CLASS_BIG_INT.rawValue }
            else { throw JeffJSTwinDecline(reason: "value kind") }
            start = ctx.classProto[cls].toObject()
        }
        if let s = try chainData(start, JSAtomID.Symbol_toStringTag), s.isString {
            return JeffJSTwinTag(name: ctx.toSwiftString(s) ?? "")
        }
        if case .other = builtin { throw JeffJSTwinDecline(reason: "class") }
        return builtin
    }

    /// The data property `atom` found first along the chain from `start`
    /// (borrowed), nil if no object has it.
    func chainData(_ start: JeffJSObject?, _ atom: UInt32) throws -> JeffJSValue? {
        var p = start
        var hops = 0
        while let o = p {
            if Self.isProxy(o) { throw JeffJSTwinDecline(reason: "proxy in chain") }
            if o.isExotic, o.classID != JeffJSClassID.array.rawValue { throw JeffJSTwinDecline(reason: "exotic in chain") }
            if (o.lazyFlags & JeffJSObject.lazyActiveMask) != 0 { ctx.jeffJS_materializeLazyProps(o, atom) }
            if let v = try JeffJSTwinIntrinsics.ownData(o, atom) { return v }
            hops += 1
            if hops > 64 { throw JeffJSTwinDecline(reason: "long chain") }
            p = o.proto
        }
        return nil
    }

    /// No proxy along the chain (an `in` / [[Set]] walk would call a trap).
    func plainChain(_ start: JeffJSObject?) throws {
        var p = start
        var hops = 0
        while let o = p {
            if Self.isProxy(o) { throw JeffJSTwinDecline(reason: "proxy in chain") }
            hops += 1
            if hops > 64 { throw JeffJSTwinDecline(reason: "long chain") }
            p = o.proto
        }
    }

    /// [[Set]] of `atom` on a fresh object whose prototype is `proto` creates
    /// an own data property: nothing on the chain holds `atom` as an accessor
    /// (a setter) or a read-only data property.
    func setCreatesOwn(_ proto: JeffJSObject?, _ atom: UInt32) throws {
        var p = proto
        var hops = 0
        while let o = p {
            if Self.isProxy(o) { throw JeffJSTwinDecline(reason: "proxy in chain") }
            if o.isExotic, o.classID != JeffJSClassID.array.rawValue { throw JeffJSTwinDecline(reason: "exotic in chain") }
            if (o.lazyFlags & JeffJSObject.lazyActiveMask) != 0 { ctx.jeffJS_materializeLazyProps(o, atom) }
            let idx = jeffJS_findOwnPropertyIndex(obj: o, atom: atom)
            if idx >= 0 {
                guard let shape = o.shape, idx < o.propCount, shape.prop[idx].flags.isPlainData,
                      o.extra(at: idx) == nil, shape.prop[idx].flags.contains(.writable)
                else { throw JeffJSTwinDecline(reason: "setter or read-only on chain") }
                return
            }
            hops += 1
            if hops > 64 { throw JeffJSTwinDecline(reason: "long chain") }
            p = o.proto
        }
    }

    /// An ordinary object whose keys can be listed without page code.
    func plainObject(_ v: JeffJSValue) throws -> JeffJSObject {
        guard let o = v.toObject(), o.classID == JeffJSClassID.object.rawValue, !o.isExotic, !o.fastArray
        else { throw JeffJSTwinDecline(reason: "not an ordinary object") }
        if (o.lazyFlags & JeffJSObject.lazyActiveMask) != 0 {
            if (o.lazyFlags & JeffJSObject.lazyHostBit) != 0 { ctx.materializeHostLazyProps(o) }
            o.ensureLazyMaterialized()
            if (o.lazyFlags & JeffJSObject.lazyActiveMask) != 0 { throw JeffJSTwinDecline(reason: "lazy object") }
        }
        return o
    }

    /// A dense array on `arrayProto` whose only own property is `length`:
    /// the object and its elements.
    func plainArray(_ v: JeffJSValue, arrayProto: JeffJSObject?) throws -> (JeffJSObject, ContiguousArray<JeffJSValue>) {
        guard let o = v.toObject(), o.classID == JeffJSClassID.array.rawValue,
              o.proto === arrayProto, arrayProto != nil, o.fastArray,
              o._fastArrayValues?.attrs == nil, let snap = o.arraySnapshot()
        else { throw JeffJSTwinDecline(reason: "not a dense array") }
        if let shape = o.shape {
            let n = min(shape.prop.count, o.propCount)
            for i in 0..<n where shape.prop[i].atom != 0 && shape.prop[i].atom != JSAtomID.length {
                throw JeffJSTwinDecline(reason: "array with own properties")
            }
        }
        if snap.values.count < snap.count { throw JeffJSTwinDecline(reason: "array storage") }
        let values = snap.values.count == snap.count ? snap.values : ContiguousArray(snap.values.prefix(snap.count))
        for x in values where x.isUninitialized { throw JeffJSTwinDecline(reason: "hole") }
        return (o, values)
    }

    /// Own property keys of an ordinary object in [[OwnPropertyKeys]] order
    /// (index keys ascending, then strings, then symbols; host-hidden and
    /// private names left out). `enumerableOnly`: Object.keys + enumerable
    /// symbols. `symbols`: include symbol keys. Every listed property must be
    /// a data property (an accessor would be read through a getter). Atoms
    /// are borrowed from the shape (nothing writes `o` meanwhile).
    func ownKeys(_ o: JeffJSObject, enumerableOnly: Bool, symbols: Bool) throws -> [UInt32] {
        guard let shape = o.shape else { return [] }
        var ints: [(UInt32, UInt32)] = []
        var strings: [UInt32] = []
        var syms: [UInt32] = []
        let n = min(shape.prop.count, o.propCount)
        for i in 0..<n {
            let p = shape.prop[i]
            let atom = p.atom
            if atom == 0 { continue }
            if p.flags.contains(.hidden) { continue }
            if enumerableOnly && !p.flags.contains(.enumerable) { continue }
            if rt.atomIsArrayIndex(atom) {
                if !p.flags.isPlainData || o.extra(at: i) != nil { throw JeffJSTwinDecline(reason: "accessor") }
                guard let idx = rt.atomToUInt32(atom) else { throw JeffJSTwinDecline(reason: "index atom") }
                ints.append((idx, atom))
            } else if let entry = rt.atomArray[Int(atom)] {
                if entry.atomType == .JS_ATOM_TYPE_PRIVATE { continue }
                let isSym = entry.atomType == .JS_ATOM_TYPE_SYMBOL || entry.atomType == .JS_ATOM_TYPE_GLOBAL_SYMBOL
                if isSym && !symbols { continue }
                if !p.flags.isPlainData || o.extra(at: i) != nil { throw JeffJSTwinDecline(reason: "accessor") }
                if isSym { syms.append(atom) } else { strings.append(atom) }
            } else {
                throw JeffJSTwinDecline(reason: "atom")
            }
        }
        if ints.isEmpty && syms.isEmpty { return strings }
        ints.sort { $0.0 < $1.0 }
        return ints.map { $0.1 } + strings + syms
    }

    /// The own data property `atom` of `o` (borrowed) and its flags.
    func ownDataWithFlags(_ o: JeffJSObject, _ atom: UInt32) throws -> (JeffJSValue, JeffJSPropertyFlags) {
        let idx = jeffJS_findOwnPropertyIndex(obj: o, atom: atom)
        guard idx >= 0, let shape = o.shape, idx < o.propCount, shape.prop[idx].flags.isPlainData,
              o.extra(at: idx) == nil else { throw JeffJSTwinDecline(reason: "missing or accessor") }
        return (o.dataValue(at: idx), shape.prop[idx].flags)
    }

    /// `o[atom]` for an own data property (borrowed).
    @inline(__always)
    func ownData(_ o: JeffJSObject, _ atom: UInt32) throws -> JeffJSValue {
        guard let v = try JeffJSTwinIntrinsics.ownData(o, atom) else { throw JeffJSTwinDecline(reason: "missing key") }
        return v
    }

    /// Define `o[atom]` as an own data property with `flags` (C/W/E bits),
    /// over an absent or configurable data property. Consumes `v`.
    func define(_ o: JeffJSObject, _ atom: UInt32, _ v: JeffJSValue, flags: Int = JS_PROP_C_W_E) throws {
        let r = ctx.definePropertyValue(obj: .borrowedObject(o), atom: atom, value: v, flags: flags)
        v.freeValue()
        if r < 0 { throw JeffJSTwinDecline(reason: "define failed") }
    }

    @inline(__always)
    func depthGuard(_ depth: Int) throws {
        if depth > 400 || rt.checkStackOverflow() { throw JeffJSTwinDecline(reason: "depth") }
    }
}
