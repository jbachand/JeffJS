// JeffJSTwinIntrinsics.swift
// JeffJS — the builtins native twins rely on (JeffJSNativeTwins.swift).
//
// A twin replaces library code that calls builtins (Object.keys, `.call`,
// Array.prototype.filter, `new Map`, …). It may only run while the page still
// reaches exactly the context's own builtins through the same lookups the
// bytecode makes, so every call checks them. Spread helpers run per object
// literal, so the checks are cached: each (holder, key) remembers the shape
// and slot it was found in, and a later check whose holder is still on that
// shape compares one value. Holders are captured when the intrinsics are
// built (before any page script) and held strongly until the context is
// freed (JeffJSContext.free). Never weakly: a weak reference gives the object
// a side table, and every retain/release of Object.prototype, Array.prototype,
// … in the whole engine then takes Swift's slow path.

import Foundation

nonisolated final class JeffJSTwinIntrinsics {

    /// What a family's code reaches (checked per call).
    struct Needs: OptionSet {
        let rawValue: Int
        /// deepmerge: Object.keys / getOwnPropertySymbols / hasOwnProperty /
        /// propertyIsEnumerable / toString via `.call`, Array.isArray,
        /// concat / map / forEach / filter, species, and [[Set]] on a fresh {}.
        static let deepmerge = Needs(rawValue: 1 << 0)
        /// Babel's objectSpread2: keys / getOwnPropertySymbols /
        /// getOwnPropertyDescriptor(s) / defineProperty / defineProperties,
        /// push.apply, forEach, filter (+ species).
        static let spread = Needs(rawValue: 1 << 1)
        /// Apollo's cloneDeep: Object.create / getPrototypeOf / keys,
        /// toString via `.call`, slice / forEach (+ species), `new Map`.
        static let clone = Needs(rawValue: 1 << 2)
        /// @wry/equality: keys, filter (+ species), `.call`, Map get/set/clear,
        /// `new Set` has/add.
        static let equal = Needs(rawValue: 1 << 3)
        /// Home Depot's data-model `_client` strip: keys, map, reduce (+ species).
        static let strip = Needs(rawValue: 1 << 4)
    }

    var global: JeffJSObject?
    var objectCtor: JeffJSObject?
    var objectProto: JeffJSObject?
    var functionProto: JeffJSObject?
    var arrayCtor: JeffJSObject?
    var arrayProto: JeffJSObject?
    var mapCtor: JeffJSObject?
    var mapProto: JeffJSObject?
    var setCtor: JeffJSObject?
    var setProto: JeffJSObject?

    var keys: JeffJSObject?
    var getOwnPropertySymbols: JeffJSObject?
    var getOwnPropertyDescriptor: JeffJSObject?
    var getOwnPropertyDescriptors: JeffJSObject?
    var defineProperty: JeffJSObject?
    var defineProperties: JeffJSObject?
    var create: JeffJSObject?
    var getPrototypeOf: JeffJSObject?
    var toString: JeffJSObject?
    var hasOwnProperty: JeffJSObject?
    var propertyIsEnumerable: JeffJSObject?
    var call: JeffJSObject?
    var apply: JeffJSObject?
    var isArray: JeffJSObject?
    var concat: JeffJSObject?
    var map: JeffJSObject?
    var forEach: JeffJSObject?
    var filter: JeffJSObject?
    var push: JeffJSObject?
    var slice: JeffJSObject?
    var reduce: JeffJSObject?
    var speciesGetter: JeffJSObject?
    var protoGetter: JeffJSObject?
    var protoSetter: JeffJSObject?
    var mapGet: JeffJSObject?
    var mapHas: JeffJSObject?
    var mapSet: JeffJSObject?
    var mapClear: JeffJSObject?
    var setHas: JeffJSObject?
    var setAdd: JeffJSObject?

    /// Predefined atoms (immortal) except `defineProperties` (owned, given
    /// back by `release`).
    let atomObject = JSPredefinedAtom.Object.rawValue
    let atomArray = JSPredefinedAtom.Array_.rawValue
    let atomMap = JSPredefinedAtom.Map_.rawValue
    let atomSet = JSPredefinedAtom.Set_.rawValue
    let atomToString = JSPredefinedAtom.toStringAtom.rawValue
    let atomConstructor = JSPredefinedAtom.constructor_.rawValue
    let atomGetOwnPropertyDescriptor = JSPredefinedAtom.getOwnPropertyDescriptor.rawValue
    let atomGetOwnPropertyDescriptors = JSPredefinedAtom.getOwnPropertyDescriptors.rawValue
    let atomDefineProperty = JSPredefinedAtom.defineProperty.rawValue
    let atomCreate = JSPredefinedAtom.create.rawValue
    let atomGetPrototypeOf = JSPredefinedAtom.getPrototypeOf.rawValue
    let atomApply = JSPredefinedAtom.apply.rawValue
    let atomPush = JSPredefinedAtom.push.rawValue
    let atomSlice = JSPredefinedAtom.slice.rawValue
    let atomGet = JSPredefinedAtom.get.rawValue
    let atomHas = JSPredefinedAtom.has.rawValue
    let atomSetMethod = JSPredefinedAtom.set.rawValue
    let atomAdd = JSPredefinedAtom.add.rawValue
    let atomClear = JSPredefinedAtom.clear.rawValue
    private(set) var atomDefineProperties: UInt32 = 0

    /// Shape + slot each check last found its key at (index = check id).
    private var slotShape = [UnsafeRawPointer?](repeating: nil, count: 128)
    private var slotIndex = [Int](repeating: -1, count: 128)

    private init?(_ ctx: JeffJSContext) {
        let rt = ctx.rt
        atomDefineProperties = rt.findAtom("defineProperties")
        func own(_ o: JeffJSObject?, _ atom: UInt32) -> JeffJSObject? {
            guard let o else { return nil }
            let idx = jeffJS_findOwnPropertyIndex(obj: o, atom: atom)
            guard idx >= 0, let shape = o.shape, idx < o.propCount, shape.prop[idx].flags.isPlainData,
                  o.extra(at: idx) == nil else { return nil }
            return o.dataValue(at: idx).toObject()
        }
        func accessor(_ o: JeffJSObject?, _ atom: UInt32) -> (JeffJSObject?, JeffJSObject?)? {
            guard let o, let prop = ctx.getOwnProperty(obj: .borrowedObject(o), atom: atom),
                  case .getset(let g, let s) = prop else { return nil }
            return (g, s)
        }
        guard let g = ctx.globalObj.toObject(),
              let oc = own(g, atomObject), let ac = own(g, atomArray),
              let op = ctx.classProto[JSClassID.JS_CLASS_OBJECT.rawValue].toObject(),
              let fp = ctx.functionProto.toObject(),
              let ap = ctx.classProto[JSClassID.JS_CLASS_ARRAY.rawValue].toObject() else { return nil }
        global = g; objectCtor = oc; objectProto = op; functionProto = fp; arrayCtor = ac; arrayProto = ap
        mapCtor = own(g, atomMap); mapProto = own(mapCtor, JSAtomID.prototype)
        setCtor = own(g, atomSet); setProto = own(setCtor, JSAtomID.prototype)
        keys = own(oc, JSAtomID.keys)
        getOwnPropertySymbols = own(oc, JSAtomID.getOwnPropertySymbols)
        getOwnPropertyDescriptor = own(oc, atomGetOwnPropertyDescriptor)
        getOwnPropertyDescriptors = own(oc, atomGetOwnPropertyDescriptors)
        defineProperty = own(oc, atomDefineProperty)
        defineProperties = own(oc, atomDefineProperties)
        create = own(oc, atomCreate)
        getPrototypeOf = own(oc, atomGetPrototypeOf)
        toString = own(op, atomToString)
        hasOwnProperty = own(op, JSAtomID.hasOwnProperty)
        propertyIsEnumerable = own(op, JSAtomID.propertyIsEnumerable)
        call = own(fp, JSAtomID.call)
        apply = own(fp, atomApply)
        isArray = own(ac, JSAtomID.isArray)
        concat = own(ap, JSAtomID.concat)
        map = own(ap, JSAtomID.map)
        forEach = own(ap, JSAtomID.forEach)
        filter = own(ap, JSAtomID.filter)
        push = own(ap, atomPush)
        slice = own(ap, atomSlice)
        reduce = own(ap, JSPredefinedAtom.reduce.rawValue)
        speciesGetter = accessor(ac, JSAtomID.Symbol_species)?.0
        let pg = accessor(op, JSAtomID.__proto__)
        protoGetter = pg?.0
        protoSetter = pg?.1
        mapGet = own(mapProto, atomGet); mapHas = own(mapProto, atomHas)
        mapSet = own(mapProto, atomSetMethod); mapClear = own(mapProto, atomClear)
        setHas = own(setProto, atomHas); setAdd = own(setProto, atomAdd)
    }

    static func capture(_ ctx: JeffJSContext) -> JeffJSTwinIntrinsics? {
        let r = JeffJSTwinIntrinsics(ctx)
        if r == nil, JeffJSConfig.nativeTwinsDebug { JeffJSNativeTwins.log("intrinsics not captured") }
        return r
    }

    /// Give back the owned atom (context teardown, before the runtime goes).
    func release(_ rt: JeffJSRuntime) {
        if atomDefineProperties != 0 { rt.freeAtom(atomDefineProperties); atomDefineProperties = 0 }
    }

    // MARK: Lookups

    /// The own plain data property `atom` of `o` (borrowed), nil if absent;
    /// throws if it is an accessor or exotic.
    @inline(__always)
    static func ownData(_ o: JeffJSObject, _ atom: UInt32) throws -> JeffJSValue? {
        let idx = jeffJS_findOwnPropertyIndex(obj: o, atom: atom)
        if idx < 0 { return nil }
        guard let shape = o.shape, idx < o.propCount, shape.prop[idx].flags.isPlainData,
              o.extra(at: idx) == nil else { throw JeffJSTwinDecline(reason: "accessor") }
        return o.dataValue(at: idx)
    }

    /// `holder[atom]` is the data property `fn` (check `id`, cached by shape).
    private func expect(_ id: Int, _ holder: JeffJSObject?, _ atom: UInt32, _ fn: JeffJSObject?,
                        _ what: StaticString) throws {
        guard let holder, let fn else { throw JeffJSTwinDecline(reason: "\(what) gone") }
        let sid = holder.shapeIdentity
        var idx = -1
        if sid != nil, slotShape[id] == sid {
            idx = slotIndex[id]
        } else {
            idx = jeffJS_findOwnPropertyIndex(obj: holder, atom: atom)
            slotShape[id] = sid
            slotIndex[id] = idx
        }
        guard idx >= 0, idx < holder.propCount, let shape = holder.shape, shape.prop[idx].flags.isPlainData,
              holder.extra(at: idx) == nil, holder.dataValue(at: idx).toObject() === fn else {
            slotShape[id] = nil
            throw JeffJSTwinDecline(reason: "\(what) patched")
        }
    }

    /// `holder` has no own `atom` (check `id`, cached by shape).
    private func absent(_ id: Int, _ holder: JeffJSObject?, _ atom: UInt32, _ what: StaticString) throws {
        guard let holder else { throw JeffJSTwinDecline(reason: "\(what) gone") }
        let sid = holder.shapeIdentity
        if sid != nil, slotShape[id] == sid, slotIndex[id] < 0 { return }
        let idx = jeffJS_findOwnPropertyIndex(obj: holder, atom: atom)
        slotShape[id] = sid
        slotIndex[id] = idx
        if idx >= 0 { throw JeffJSTwinDecline(reason: "\(what) shadowed") }
    }

    /// `fn.call` / `fn.apply` reach Function.prototype's.
    private func callable(_ id: Int, _ fn: JeffJSObject?, _ atom: UInt32, _ what: StaticString) throws {
        guard let fn, fn.proto === functionProto else { throw JeffJSTwinDecline(reason: "\(what) prototype changed") }
        try absent(id, fn, atom, what)
    }

    // MARK: Checks

    /// The lookups the replaced code makes still reach the intrinsics.
    func check(_ ctx: JeffJSContext, _ needs: Needs) throws {
        guard let objectProto, let functionProto, let arrayProto else {
            throw JeffJSTwinDecline(reason: "intrinsics gone")
        }
        // Global `Object` / `Array` / `Map` / `Set`: no script-level
        // let/const shadows them, and the global object holds the intrinsics.
        if ctx.globalLexCount > 0 {
            for a in [atomObject, atomArray, atomMap, atomSet] where ctx.globalLexIndex(a) >= 0 {
                throw JeffJSTwinDecline(reason: "global lexical binding")
            }
        }
        try expect(0, global, atomObject, objectCtor, "Object")
        guard objectCtor?.proto === functionProto, functionProto.proto === objectProto, objectProto.proto == nil,
              arrayProto.proto === objectProto else {
            throw JeffJSTwinDecline(reason: "prototype chain changed")
        }
        if !needs.isDisjoint(with: [.deepmerge, .spread, .clone, .equal, .strip]) {
            try expect(1, objectCtor, JSAtomID.keys, keys, "Object.keys")
        }
        if needs.contains(.deepmerge) {
            try expect(2, global, atomArray, arrayCtor, "Array")
            try expect(3, objectCtor, JSAtomID.getOwnPropertySymbols, getOwnPropertySymbols, "Object.getOwnPropertySymbols")
            try expect(4, objectCtor, JSAtomID.prototype, objectProto, "Object.prototype")
            try expect(5, arrayCtor, JSAtomID.isArray, isArray, "Array.isArray")
            // Object.hasOwnProperty / propertyIsEnumerable resolve through
            // Object → Function.prototype → Object.prototype.
            try absent(6, objectCtor, JSAtomID.hasOwnProperty, "Object.hasOwnProperty")
            try absent(7, objectCtor, JSAtomID.propertyIsEnumerable, "Object.propertyIsEnumerable")
            try absent(8, functionProto, JSAtomID.hasOwnProperty, "Function.prototype.hasOwnProperty")
            try absent(9, functionProto, JSAtomID.propertyIsEnumerable, "Function.prototype.propertyIsEnumerable")
            try expect(10, objectProto, atomToString, toString, "Object.prototype.toString")
            try expect(11, objectProto, JSAtomID.hasOwnProperty, hasOwnProperty, "Object.prototype.hasOwnProperty")
            try expect(12, objectProto, JSAtomID.propertyIsEnumerable, propertyIsEnumerable, "Object.prototype.propertyIsEnumerable")
            try callable(13, toString, JSAtomID.call, "toString.call")
            try callable(14, hasOwnProperty, JSAtomID.call, "hasOwnProperty.call")
            try callable(15, propertyIsEnumerable, JSAtomID.call, "propertyIsEnumerable.call")
            try expect(16, functionProto, JSAtomID.call, call, "Function.prototype.call")
            try expect(17, arrayProto, JSAtomID.concat, concat, "Array.prototype.concat")
            try expect(18, arrayProto, JSAtomID.map, map, "Array.prototype.map")
            try expect(19, arrayProto, JSAtomID.forEach, forEach, "Array.prototype.forEach")
            try expect(20, arrayProto, JSAtomID.filter, filter, "Array.prototype.filter")
            try absent(21, arrayProto, JSAtomID.Symbol_isConcatSpreadable, "@@isConcatSpreadable")
            try absent(22, objectProto, JSAtomID.Symbol_isConcatSpreadable, "@@isConcatSpreadable")
            try species(ctx)
            try objectProtoPristine(ctx)
        }
        if needs.contains(.spread) {
            try expect(30, objectCtor, JSAtomID.getOwnPropertySymbols, getOwnPropertySymbols, "Object.getOwnPropertySymbols")
            try expect(31, objectCtor, atomGetOwnPropertyDescriptor, getOwnPropertyDescriptor, "Object.getOwnPropertyDescriptor")
            try expect(32, objectCtor, atomGetOwnPropertyDescriptors, getOwnPropertyDescriptors, "Object.getOwnPropertyDescriptors")
            try expect(33, objectCtor, atomDefineProperty, defineProperty, "Object.defineProperty")
            try expect(34, objectCtor, atomDefineProperties, defineProperties, "Object.defineProperties")
            try expect(35, arrayProto, atomPush, push, "Array.prototype.push")
            try expect(36, arrayProto, JSAtomID.forEach, forEach, "Array.prototype.forEach")
            try expect(37, arrayProto, JSAtomID.filter, filter, "Array.prototype.filter")
            try callable(38, push, atomApply, "push.apply")
            try expect(39, functionProto, atomApply, apply, "Function.prototype.apply")
            try species(ctx)
        }
        if needs.contains(.clone) {
            try expect(50, global, atomMap, mapCtor, "Map")
            try expect(51, mapCtor, JSAtomID.prototype, mapProto, "Map.prototype")
            try expect(52, mapProto, atomGet, mapGet, "Map.prototype.get")
            try expect(53, mapProto, atomHas, mapHas, "Map.prototype.has")
            try expect(54, mapProto, atomSetMethod, mapSet, "Map.prototype.set")
            try expect(55, objectCtor, atomCreate, create, "Object.create")
            try expect(56, objectCtor, atomGetPrototypeOf, getPrototypeOf, "Object.getPrototypeOf")
            try expect(57, arrayProto, atomSlice, slice, "Array.prototype.slice")
            try expect(58, arrayProto, JSAtomID.forEach, forEach, "Array.prototype.forEach")
            try callable(59, toString, JSAtomID.call, "toString.call")
            try expect(60, functionProto, JSAtomID.call, call, "Function.prototype.call")
            try species(ctx)
            try indexAccessorsAbsent()
        }
        if needs.contains(.strip) { try checkStrip(ctx) }
        if needs.contains(.equal) {
            try expect(70, global, atomSet, setCtor, "Set")
            try expect(71, setCtor, JSAtomID.prototype, setProto, "Set.prototype")
            try expect(72, setProto, atomHas, setHas, "Set.prototype.has")
            try expect(73, setProto, atomAdd, setAdd, "Set.prototype.add")
            try expect(74, mapProto, atomGet, mapGet, "Map.prototype.get")
            try expect(75, mapProto, atomSetMethod, mapSet, "Map.prototype.set")
            try expect(76, mapProto, atomClear, mapClear, "Map.prototype.clear")
            try expect(77, arrayProto, JSAtomID.filter, filter, "Array.prototype.filter")
            try callable(78, toString, JSAtomID.call, "toString.call")
            try callable(79, hasOwnProperty, JSAtomID.call, "hasOwnProperty.call")
            try expect(80, functionProto, JSAtomID.call, call, "Function.prototype.call")
            try species(ctx)
        }
    }

    private func checkStrip(_ ctx: JeffJSContext) throws {
        try expect(100, arrayProto, JSAtomID.map, map, "Array.prototype.map")
        try expect(101, arrayProto, JSPredefinedAtom.reduce.rawValue, reduce, "Array.prototype.reduce")
        try species(ctx)
    }

    /// ArraySpeciesCreate on a plain array makes a plain array:
    /// Array.prototype.constructor is Array and Array[@@species] the intrinsic getter.
    private func species(_ ctx: JeffJSContext) throws {
        guard let arrayCtor, arrayCtor.proto === functionProto else {
            throw JeffJSTwinDecline(reason: "Array changed")
        }
        try expect(90, arrayProto, atomConstructor, arrayCtor, "Array.prototype.constructor")
        guard let sp = ctx.getOwnProperty(obj: .borrowedObject(arrayCtor), atom: JSAtomID.Symbol_species),
              case .getset(let sg, _) = sp, sg === speciesGetter, sg != nil else {
            throw JeffJSTwinDecline(reason: "Array[@@species] patched")
        }
    }

    /// [[Set]] on a fresh {}: Object.prototype has only writable data
    /// properties (a setter would run page code, a read-only one would fail
    /// the write) and the intrinsic __proto__ accessor.
    func objectProtoPristine(_ ctx: JeffJSContext) throws {
        guard let objectProto, let shape = objectProto.shape else { throw JeffJSTwinDecline(reason: "Object.prototype shape") }
        let n = min(shape.prop.count, objectProto.propCount)
        for i in 0..<n {
            let p = shape.prop[i]
            if p.atom == 0 { continue }
            if p.flags.isPlainData, objectProto.extra(at: i) == nil {
                if !p.flags.contains(.writable) { throw JeffJSTwinDecline(reason: "read-only Object.prototype member") }
                continue
            }
            if p.atom == JSAtomID.__proto__,
               let prop = ctx.getOwnProperty(obj: .borrowedObject(objectProto), atom: p.atom),
               case .getset(let pg, let ps) = prop, pg === protoGetter, ps === protoSetter { continue }
            throw JeffJSTwinDecline(reason: "Object.prototype accessor")
        }
    }

    /// `copy[i] = v` on a fresh array: neither Array.prototype nor
    /// Object.prototype has an index property (a setter or read-only one).
    private func indexAccessorsAbsent() throws {
        for o in [arrayProto, objectProto] {
            guard let o, let shape = o.shape else { throw JeffJSTwinDecline(reason: "prototype shape") }
            if o.fastArray, let snap = o.arraySnapshot(), snap.count > 0 {
                throw JeffJSTwinDecline(reason: "indexed prototype")
            }
            let n = min(shape.prop.count, o.propCount)
            for i in 0..<n where shape.prop[i].atom != 0 && (shape.prop[i].atom & JS_ATOM_TAG_INT) != 0 {
                throw JeffJSTwinDecline(reason: "indexed prototype")
            }
        }
    }
}
