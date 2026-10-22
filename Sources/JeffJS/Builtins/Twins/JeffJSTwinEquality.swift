// JeffJSTwinEquality.swift
// JeffJS — native twin of `equal` from @wry/equality, the deep equality Apollo
// Client runs over query results (Home Depot's product listing page: inside its
// 14 s task).
//
//   equal(a, b) = check(a, b), then previousComparisons.clear()
//   check(a, b):
//     a === b                                  → true
//     tags differ (Object.prototype.toString)  → false
//     [object Array]   lengths differ → false, else as an object
//     [object Object]  a pair already being compared → true; keys of each
//                      whose value is not undefined; counts differ → false;
//                      every key of a own in b, and check(a[k], b[k])
//     [object Number]  a !== a → b !== b, else +a == +b
//     [object Boolean] [object Date] +a == +b
//     [object RegExp] [object String]  a == "" + b
//     Map / Set / Error / functions: their own rules
//     anything else                            → false
//
// The twin answers for plain objects, dense arrays and primitives; a Map, Set,
// Error, Date, RegExp, function or wrapper object anywhere declines (their
// rules call methods the page could replace). `previousComparisons` (a
// module-level Map) must be empty when the call starts — it always is unless
// a comparison is already running — and the twin leaves it empty, as
// `clear()` would.

import Foundation

nonisolated enum JeffJSTwinEquality {

    static let family = JeffJSNativeTwins.Family(
        name: "wry-equality",
        roles: ["F", "Ct", "Dr", "Cs", "As", "Ir"],
        values: ["wr", "Ns", "Nt"],
        source: reference,
        needs: .equal,
        accepts: { _, _, _ in true },
        run: run)

    /// As homedepot.com ships it (vendor-apollo build, names kept).
    static let reference = """
        var yn=Object.prototype,wr=yn.toString,Ns=yn.hasOwnProperty,xr=Function.prototype.toString,Nt=new Map;function F(r,e){try{return Ct(r,e)}finally{Nt.clear()}}function Ct(r,e){if(r===e)return!0;var t=wr.call(r),n=wr.call(e);if(t!==n)return!1;switch(t){case"[object Array]":if(r.length!==e.length)return!1;case"[object Object]":{if(Ir(r,e))return!0;var i=Dr(r),s=Dr(e),a=i.length;if(a!==s.length)return!1;for(var o=0;o<a;++o)if(!Ns.call(e,i[o]))return!1;for(var o=0;o<a;++o){var u=i[o];if(!Ct(r[u],e[u]))return!1}return!0}case"[object Error]":return r.name===e.name&&r.message===e.message;case"[object Number]":if(r!==r)return e!==e;case"[object Boolean]":case"[object Date]":return+r==+e;case"[object RegExp]":case"[object String]":return r==""+e;case"[object Map]":case"[object Set]":{if(r.size!==e.size)return!1;if(Ir(r,e))return!0;for(var c=r.entries(),l=t==="[object Map]";;){var f=c.next();if(f.done)break;var h=f.value,v=h[0],m=h[1];if(!e.has(v)||l&&!Ct(m,e.get(v)))return!1}return!0}case"[object AsyncFunction]":case"[object GeneratorFunction]":case"[object AsyncGeneratorFunction]":case"[object Function]":{var y=xr.call(r);return y!==xr.call(e)?!1:!As(y,Rs)}}return!1}function Dr(r){return Object.keys(r).filter(Cs,r)}function Cs(r){return this[r]!==void 0}var Rs="{ [native code] }";function As(r,e){var t=r.length-e.length;return t>=0&&r.indexOf(e,t)===t}function Ir(r,e){var t=Nt.get(r);if(t){if(t.has(e))return!0}else Nt.set(r,t=new Set);return t.add(e),!1}
        """

    static func run(_ ctx: JeffJSContext, _ fam: JeffJSNativeTwins.Resolved,
                    _ argv: UnsafePointer<JeffJSValue>?, _ argc: Int) throws -> JeffJSValue {
        guard let intrinsics = ctx.twinIntrinsics,
              let ts = intrinsics.toString, fam.values[0].toObject() === ts,
              let hop = intrinsics.hasOwnProperty, fam.values[1].toObject() === hop else {
            throw JeffJSTwinDecline(reason: "toString / hasOwnProperty cell changed")
        }
        // previousComparisons: an intrinsic Map, empty.
        guard let nt = fam.values[2].toObject(), nt.classID == JeffJSClassID.map.rawValue,
              nt.proto === intrinsics.mapProto, intrinsics.mapProto != nil,
              case .mapState(let state) = nt.payload, state.count == 0 else {
            throw JeffJSTwinDecline(reason: "previousComparisons")
        }
        var c = Comparer(rd: JeffJSTwinReader(ctx), arrayProto: intrinsics.arrayProto)
        let a = argc > 0 ? argv![0] : .undefined
        let b = argc > 1 ? argv![1] : .undefined
        return try c.equal(a, b, depth: 0) ? .JS_TRUE : .JS_FALSE
    }

    struct Comparer {
        let rd: JeffJSTwinReader
        let arrayProto: JeffJSObject?
        /// previousComparisons: a → the bs it is being compared with.
        var pairs: [ObjectIdentifier: Set<ObjectIdentifier>] = [:]

        /// Ir: true when (a, b) was seen before, else records it.
        mutating func seenBefore(_ a: JeffJSObject, _ b: JeffJSObject) -> Bool {
            let ka = ObjectIdentifier(a), kb = ObjectIdentifier(b)
            if pairs[ka, default: []].contains(kb) { return true }
            pairs[ka, default: []].insert(kb)
            return false
        }

        mutating func equal(_ a: JeffJSValue, _ b: JeffJSValue, depth: Int) throws -> Bool {
            if JeffJSTwinReader.strictEquals(a, b) { return true }
            let ta = try rd.tag(a), tb = try rd.tag(b)
            if ta != tb { return false }
            switch ta {
            case .array:
                try rd.depthGuard(depth)
                let (ao, av) = try rd.plainArray(a, arrayProto: arrayProto)
                let (bo, bv) = try rd.plainArray(b, arrayProto: arrayProto)
                if av.count != bv.count { return false }
                if seenBefore(ao, bo) { return true }
                // Keys whose value is not undefined; no holes, so every index
                // of a is own in b.
                var ka: [Int] = []
                var countB = 0
                for i in 0..<av.count where !av[i].isUndefined { ka.append(i) }
                for x in bv where !x.isUndefined { countB += 1 }
                if ka.count != countB { return false }
                for i in ka where try !equal(av[i], bv[i], depth: depth + 1) { return false }
                return true
            case .object:
                try rd.depthGuard(depth)
                let ao = try rd.plainObject(a), bo = try rd.plainObject(b)
                if seenBefore(ao, bo) { return true }
                let ka = try definedKeys(ao), kb = try definedKeys(bo)
                if ka.count != kb.count { return false }
                for k in ka where !rd.ctx.hasOwnPropertyAtom(bo, k) { return false }
                for k in ka {
                    let bv = try rd.ownData(bo, k)
                    if try !equal(try rd.ownData(ao, k), bv, depth: depth + 1) { return false }
                }
                return true
            case .number:
                guard !a.isObject, !b.isObject, let x = rd.ctx.extractFloat64(a), let y = rd.ctx.extractFloat64(b)
                else { throw JeffJSTwinDecline(reason: "Number object") }
                if x != x { return y != y }
                return x == y
            case .boolean:
                guard a.isBool, b.isBool else { throw JeffJSTwinDecline(reason: "Boolean object") }
                return a.toBool() == b.toBool()
            case .string:
                // a == "" + b on two primitive strings: equal contents (=== was false).
                guard a.isString, b.isString else { throw JeffJSTwinDecline(reason: "String object") }
                return false
            case .undefined, .null, .symbol, .bigint:
                return false   // no case: not === means not equal
            case .other(let name):
                if name == "AsyncFunction" || name == "GeneratorFunction" || name == "AsyncGeneratorFunction" {
                    throw JeffJSTwinDecline(reason: "function")
                }
                return false   // no case matches an unknown tag
            case .arguments:
                return false
            default:
                throw JeffJSTwinDecline(reason: "Map / Set / Error / Date / RegExp / function")
            }
        }

        /// Object.keys(o).filter(k => o[k] !== undefined).
        func definedKeys(_ o: JeffJSObject) throws -> [UInt32] {
            let keys = try rd.ownKeys(o, enumerableOnly: true, symbols: false)
            var out: [UInt32] = []
            out.reserveCapacity(keys.count)
            for k in keys where try !rd.ownData(o, k).isUndefined { out.append(k) }
            return out
        }
    }
}
