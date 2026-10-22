// JeffJSTwinDeepmerge.swift
// JeffJS — native twin of deepmerge 4.x (`deepmerge(target, source)`), the
// first entry of the twin table (JeffJSNativeTwins.swift).
//
// Home Depot's data-model code merges every component's GraphQL field tree
// with deepmerge (~85 % of the script time of its landing and product pages
// on JeffJS). The reference below is the library as homedepot.com ships it
// (vendor-sui-atomic, vendor-data-sources, HomepageMetadataContainer, Home,
// dataModel: five copies, one structure); names are the
// HomepageMetadataContainer build's.
//
// The twin serves calls with the default options only (no third argument:
// every Home Depot call site); a call with options runs the bytecode. It
// follows deepmerge step by step, in the same order:
//
//   deepmerge(e, t)       Array.isArray(t) === Array.isArray(e)
//                           ? (arrays ? e.concat(t).map(clone) : mergeObject(e, t))
//                           : clone(t)
//   clone(v)              isMergeable(v) ? deepmerge(Array.isArray(v) ? [] : {}, v) : v
//   mergeObject(e, t)     n = {}; if isMergeable(e) every enumerable own key a of e:
//                         n[a] = clone(e[a]); then every key a of t: skip when
//                         `a in e` but not an own enumerable property of e; else
//                         n[a] = a in e && isMergeable(t[a]) ? deepmerge(e[a], t[a])
//                                                            : clone(t[a])
//   isMergeable(v)        non-null object, Object.prototype.toString not
//                         [object RegExp] / [object Date], v.$$typeof !== the
//                         React element marker
//
// Everything read must be readable without running page code; otherwise the
// twin declines (JeffJSTwinDecline) and the bytecode runs from the start:
//   * objects whose keys are listed are ordinary objects (any prototype) and
//     arrays are dense arrays on Array.prototype with no own properties but
//     `length`; their enumerable own properties are data properties;
//   * no proxy anywhere a lookup walks; @@toStringTag and $$typeof are data
//     properties (or absent) along the chain;
//   * a mergeable object of another class (Map, Error, a DOM node, …) is
//     declined rather than modelled.
// New objects are written with [[DefineOwnProperty]]: on a fresh {} that is
// [[Set]] because JeffJSTwinIntrinsics.check saw no setter and no read-only
// member on Object.prototype; `__proto__` goes through [[Set]].

import Foundation

nonisolated enum JeffJSTwinDeepmerge {

    static let family = JeffJSNativeTwins.Family(
        name: "deepmerge",
        roles: ["yC", "kze", "$7", "Ize", "Nze", "Qme", "Dze", "tNe", "Rze", "Sze", "Oze", "Cze", "_ze", "Aze"],
        values: ["Tze"],
        source: reference,
        needs: .deepmerge,
        accepts: accepts,
        run: run)

    /// Default options (no or a falsy primitive third argument) and an
    /// object source; deepmerge's own recursive calls pass options and only
    /// reach here when a call was declined.
    static func accepts(_ ctx: JeffJSContext, _ argv: UnsafePointer<JeffJSValue>?, _ argc: Int) -> Bool {
        guard argc > 1, argv![1].isObject else { return false }
        if argc > 2 {
            let o = argv![2]
            if o.isObject || ctx.toBool(o) { return false }
        }
        return true
    }

    /// deepmerge 4.3 as homedepot.com ships it (HomepageMetadataContainer
    /// build, names kept).
    static let reference = """
        var Sze=function(t){return Oze(t)&&!Cze(t)};function Oze(e){return!!e&&typeof e=="object"}function Cze(e){var t=Object.prototype.toString.call(e);return t==="[object RegExp]"||t==="[object Date]"||_ze(e)}var Pze=typeof Symbol=="function"&&Symbol.for,Tze=Pze?Symbol.for("react.element"):60103;function _ze(e){return e.$$typeof===Tze}function Aze(e){return Array.isArray(e)?[]:{}}function $7(e,t){return t.clone!==!1&&t.isMergeableObject(e)?yC(Aze(e),e,t):e}function Ize(e,t,r){return e.concat(t).map(function(n){return $7(n,r)})}function Nze(e,t){if(!t.customMerge)return yC;var r=t.customMerge(e);return typeof r=="function"?r:yC}function Dze(e){return Object.getOwnPropertySymbols?Object.getOwnPropertySymbols(e).filter(function(t){return Object.propertyIsEnumerable.call(e,t)}):[]}function Qme(e){return Object.keys(e).concat(Dze(e))}function tNe(e,t){try{return t in e}catch{return!1}}function Rze(e,t){return tNe(e,t)&&!(Object.hasOwnProperty.call(e,t)&&Object.propertyIsEnumerable.call(e,t))}function kze(e,t,r){var n={};return r.isMergeableObject(e)&&Qme(e).forEach(function(a){n[a]=$7(e[a],r)}),Qme(t).forEach(function(a){Rze(e,a)||(tNe(e,a)&&r.isMergeableObject(t[a])?n[a]=Nze(a,r)(e[a],t[a],r):n[a]=$7(t[a],r))}),n}function yC(e,t,r){r=r||{},r.arrayMerge=r.arrayMerge||Ize,r.isMergeableObject=r.isMergeableObject||Sze,r.cloneUnlessOtherwiseSpecified=$7;var n=Array.isArray(t),a=Array.isArray(e),i=n===a;return i?n?r.arrayMerge(e,t,r):kze(e,t,r):$7(t,r)}yC.all=function(t,r){if(!Array.isArray(t))throw new Error("first argument should be an array");return t.reduce(function(n,a){return yC(n,a,r)},{})};
        """

    static func run(_ ctx: JeffJSContext, _ fam: JeffJSNativeTwins.Resolved,
                    _ argv: UnsafePointer<JeffJSValue>?, _ argc: Int) throws -> JeffJSValue {
        let e = argc > 0 ? argv![0] : .undefined
        let t = argc > 1 ? argv![1] : .undefined
        let options = argc > 2 ? argv![2] : .undefined
        // `r = r || {}`: only the default options (a falsy third argument).
        if options.isObject || ctx.toBool(options) { throw JeffJSTwinDecline(reason: "options") }
        // Object.keys(t) on a primitive throws or lists string indices.
        guard t.isObject else { throw JeffJSTwinDecline(reason: "source is not an object") }
        guard let intrinsics = ctx.twinIntrinsics else { throw JeffJSTwinDecline(reason: "no intrinsics") }
        var m = Merger(ctx: ctx, intrinsics: intrinsics, marker: fam.values[0])
        defer { m.finish() }
        return try m.deepmerge(e, t, depth: 0)
    }

    /// One call's state.
    struct Merger {
        let ctx: JeffJSContext
        let rt: JeffJSRuntime
        let intrinsics: JeffJSTwinIntrinsics
        /// The React element marker (`Symbol.for("react.element")` or 60103).
        let marker: JeffJSValue
        let atomTypeof: UInt32
        static let maxDepth = 400

        init(ctx: JeffJSContext, intrinsics: JeffJSTwinIntrinsics, marker: JeffJSValue) {
            self.ctx = ctx
            self.rt = ctx.rt
            self.intrinsics = intrinsics
            self.marker = marker
            self.atomTypeof = ctx.rt.findAtom("$$typeof")
        }

        func finish() { rt.freeAtom(atomTypeof) }

        // MARK: deepmerge / clone / arrayMerge / mergeObject

        mutating func deepmerge(_ e: JeffJSValue, _ t: JeffJSValue, depth: Int) throws -> JeffJSValue {
            if depth > Self.maxDepth || rt.checkStackOverflow() { throw JeffJSTwinDecline(reason: "depth") }
            let tArray = try isArray(t), eArray = try isArray(e)
            if tArray == eArray {
                return tArray ? try arrayMerge(e, t, depth: depth) : try mergeObject(e, t, depth: depth)
            }
            return try clone(t, depth: depth)
        }

        mutating func clone(_ v: JeffJSValue, depth: Int) throws -> JeffJSValue {
            guard try isMergeable(v) else { return v.dupValue() }
            if depth > Self.maxDepth || rt.checkStackOverflow() { throw JeffJSTwinDecline(reason: "depth") }
            // deepmerge(emptyTarget(v), v): [].concat(v).map(clone), or
            // mergeObject({}, v), whose keys that `{}` has through
            // Object.prototype are skipped as unsafe.
            if try isArray(v) { return try cloneArray([], v, depth: depth + 1) }
            return try mergeObject(nil, v, depth: depth + 1)
        }

        /// `e.concat(t).map(clone)` (both dense arrays on Array.prototype).
        mutating func arrayMerge(_ e: JeffJSValue, _ t: JeffJSValue, depth: Int) throws -> JeffJSValue {
            let ev = try plainArrayValues(e)
            return try cloneArray(ev, t, depth: depth + 1)
        }

        mutating func cloneArray(_ head: ContiguousArray<JeffJSValue>, _ t: JeffJSValue, depth: Int) throws -> JeffJSValue {
            let tv = try plainArrayValues(t)
            var out: [JeffJSValue] = []
            out.reserveCapacity(head.count + tv.count)
            do {
                for v in head { out.append(try clone(v, depth: depth)) }
                for v in tv { out.append(try clone(v, depth: depth)) }
            } catch {
                for v in out { v.freeValue() }
                throw error
            }
            return ctx.newArrayFrom(out)
        }

        /// kze(e, t); `e == nil` is the fresh `{}` of clone().
        mutating func mergeObject(_ e: JeffJSValue?, _ t: JeffJSValue, depth: Int) throws -> JeffJSValue {
            let n = ctx.newObject()
            do {
                if let e, try isMergeable(e) {
                    let eo = try plainObject(e)
                    for key in try enumerableOwnKeys(eo) {
                        let v = try ownEnumerableData(eo, key)
                        try put(n, key, try clone(v, depth: depth))
                    }
                }
                let to = try plainObject(t)
                for key in try enumerableOwnKeys(to) {
                    let inE = try propertyIsOnObject(e, key)
                    if inE {
                        // propertyIsUnsafe: on e, but not as an own enumerable property.
                        guard let e, try ownEnumerable(e, key) else { continue }
                    }
                    let tv = try ownEnumerableData(to, key)
                    if inE, try isMergeable(tv) {
                        let ev = try ownEnumerableData(try plainObject(e!), key)
                        try put(n, key, try deepmerge(ev, tv, depth: depth + 1))
                    } else {
                        try put(n, key, try clone(tv, depth: depth))
                    }
                }
            } catch {
                n.freeValue()
                throw error
            }
            return n
        }

        // MARK: Predicates

        /// Array.isArray (a proxy is declined).
        func isArray(_ v: JeffJSValue) throws -> Bool {
            guard let o = v.toObject() else { return false }
            if Self.isProxy(o) { throw JeffJSTwinDecline(reason: "proxy") }
            return o.classID == JeffJSClassID.array.rawValue
        }

        /// Sze: a non-null object whose Object.prototype.toString is not
        /// [object RegExp] / [object Date] and that is not a React element.
        func isMergeable(_ v: JeffJSValue) throws -> Bool {
            guard let o = v.toObject() else { return false }
            if Self.isProxy(o) { throw JeffJSTwinDecline(reason: "proxy") }
            if ctx.isCallable(v) { return false }   // typeof "function"
            // Object.prototype.toString: the builtin tag, then @@toStringTag.
            let cid = o.classID
            var tag: Int   // 0 Object/Array, 1 Date/RegExp, -1 another class
            if cid == JeffJSClassID.object.rawValue || cid == JeffJSClassID.array.rawValue { tag = 0 }
            else if cid == JeffJSClassID.date.rawValue || cid == JeffJSClassID.regexp.rawValue { tag = 1 }
            else { tag = -1 }
            if let s = try chainData(o, JSAtomID.Symbol_toStringTag), s.isString {
                let str = ctx.toSwiftString(s) ?? ""
                tag = (str == "RegExp" || str == "Date") ? 1 : 0
            }
            if tag < 0 { throw JeffJSTwinDecline(reason: "class \(cid)") }
            if tag == 1 { return false }
            // _ze: e.$$typeof === marker
            if let tv = try chainData(o, atomTypeof), Self.strictEquals(ctx, tv, marker) { return false }
            return true
        }

        /// tNe: `key in e` (false for a primitive: `in` throws, caught).
        func propertyIsOnObject(_ e: JeffJSValue?, _ key: UInt32) throws -> Bool {
            guard let e else {
                // The fresh {} of clone(): only Object.prototype can have it.
                guard let op = intrinsics.objectProto else { throw JeffJSTwinDecline(reason: "intrinsics gone") }
                return try chainHas(op, key)
            }
            guard let o = e.toObject() else { return false }
            return try chainHas(o, key)
        }

        func chainHas(_ start: JeffJSObject, _ key: UInt32) throws -> Bool {
            var p: JeffJSObject? = start
            var hops = 0
            while let o = p {
                if Self.isProxy(o) { throw JeffJSTwinDecline(reason: "proxy in chain") }
                hops += 1
                if hops > 64 { throw JeffJSTwinDecline(reason: "long chain") }
                p = o.proto
            }
            let r = ctx.hasPropertyEx(obj: .borrowedObject(start), atom: key)
            if r < 0 { throw JeffJSTwinDecline(reason: "has threw") }
            return r > 0
        }

        /// hasOwnProperty && propertyIsEnumerable on an ordinary object.
        func ownEnumerable(_ e: JeffJSValue, _ key: UInt32) throws -> Bool {
            let o = try plainObject(e)
            let idx = jeffJS_findOwnPropertyIndex(obj: o, atom: key)
            if idx < 0 { return false }
            guard let shape = o.shape, idx < o.propCount else { throw JeffJSTwinDecline(reason: "shape") }
            let f = shape.prop[idx].flags
            if f.contains(.hidden) { throw JeffJSTwinDecline(reason: "hidden property") }
            return f.contains(.enumerable)
        }

        // MARK: Reading

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

        /// The elements of a dense array on Array.prototype whose only own
        /// property is `length` (concat and map see nothing else).
        func plainArrayValues(_ v: JeffJSValue) throws -> ContiguousArray<JeffJSValue> {
            guard let o = v.toObject(), o.classID == JeffJSClassID.array.rawValue,
                  o.proto === intrinsics.arrayProto, o.fastArray,
                  o._fastArrayValues?.attrs == nil, let snap = o.arraySnapshot()
            else { throw JeffJSTwinDecline(reason: "not a dense array") }
            if let shape = o.shape {
                let n = min(shape.prop.count, o.propCount)
                for i in 0..<n where shape.prop[i].atom != 0 && shape.prop[i].atom != JSAtomID.length {
                    throw JeffJSTwinDecline(reason: "array with own properties")
                }
            }
            if snap.count != snap.values.count { throw JeffJSTwinDecline(reason: "array storage") }
            for x in snap.values where x.isUninitialized { throw JeffJSTwinDecline(reason: "hole") }
            return snap.values
        }

        /// Object.keys(o).concat(enumerable own symbols): index keys
        /// ascending, then strings and symbols in insertion order. Atoms are
        /// borrowed from the shape (nothing writes `o` meanwhile).
        func enumerableOwnKeys(_ o: JeffJSObject) throws -> [UInt32] {
            guard let shape = o.shape else { return [] }
            var ints: [(UInt32, UInt32)] = []
            var strings: [UInt32] = []
            var symbols: [UInt32] = []
            let n = min(shape.prop.count, o.propCount)
            for i in 0..<n {
                let p = shape.prop[i]
                let atom = p.atom
                if atom == 0 { continue }
                if p.flags.contains(.hidden) { continue }   // listed by no reflection
                if !p.flags.contains(.enumerable) { continue }
                if !p.flags.isPlainData || o.extra(at: i) != nil { throw JeffJSTwinDecline(reason: "enumerable accessor") }
                if rt.atomIsArrayIndex(atom) {
                    guard let idx = rt.atomToUInt32(atom) else { throw JeffJSTwinDecline(reason: "index atom") }
                    ints.append((idx, atom))
                } else if let entry = rt.atomArray[Int(atom)] {
                    if entry.atomType == .JS_ATOM_TYPE_PRIVATE { continue }
                    if entry.atomType == .JS_ATOM_TYPE_SYMBOL || entry.atomType == .JS_ATOM_TYPE_GLOBAL_SYMBOL {
                        symbols.append(atom)
                    } else {
                        strings.append(atom)
                    }
                } else {
                    throw JeffJSTwinDecline(reason: "atom")
                }
            }
            if ints.isEmpty && symbols.isEmpty { return strings }
            ints.sort { $0.0 < $1.0 }
            return ints.map { $0.1 } + strings + symbols
        }

        /// `o[key]` for an enumerable own data property (borrowed).
        func ownEnumerableData(_ o: JeffJSObject, _ key: UInt32) throws -> JeffJSValue {
            guard let v = try JeffJSTwinIntrinsics.ownData(o, key) else { throw JeffJSTwinDecline(reason: "missing key") }
            return v
        }

        /// The data property `atom` found first along `o`'s chain
        /// (borrowed), nil if no object has it.
        func chainData(_ start: JeffJSObject, _ atom: UInt32) throws -> JeffJSValue? {
            var p: JeffJSObject? = start
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

        // MARK: Writing

        /// `n[key] = v` on the fresh object `n` (consumes `v`).
        func put(_ n: JeffJSValue, _ key: UInt32, _ v: JeffJSValue) throws {
            if key == JSAtomID.__proto__ {
                // Object.prototype.__proto__'s setter (the intrinsic).
                if ctx.setProperty(obj: n, atom: key, value: v) < 0 { throw JeffJSTwinDecline(reason: "set failed") }
                return
            }
            let r = ctx.definePropertyValue(obj: n, atom: key, value: v, flags: JS_PROP_C_W_E)
            v.freeValue()
            if r < 0 { throw JeffJSTwinDecline(reason: "define failed") }
        }

        // MARK: Helpers

        @inline(__always)
        static func isProxy(_ o: JeffJSObject) -> Bool {
            let c = o.classID
            return c == JeffJSClassID.proxy.rawValue || c == JSClassID.JS_CLASS_PROXY.rawValue
        }

        /// `a === b` where b is the marker (a symbol or the number 60103).
        static func strictEquals(_ ctx: JeffJSContext, _ a: JeffJSValue, _ b: JeffJSValue) -> Bool {
            if a.isNumber && b.isNumber {
                guard let x = ctx.extractFloat64(a), let y = ctx.extractFloat64(b) else { return false }
                return x == y
            }
            if a.isSymbol && b.isSymbol { return a.bits == b.bits }
            if a.isObject && b.isObject { return a.bits == b.bits }
            if a.isString && b.isString { return ctx.toSwiftString(a) == ctx.toSwiftString(b) }
            if a.isBool && b.isBool { return a.toBool() == b.toBool() }
            return (a.isUndefined && b.isUndefined) || (a.isNull && b.isNull)
        }
    }
}
