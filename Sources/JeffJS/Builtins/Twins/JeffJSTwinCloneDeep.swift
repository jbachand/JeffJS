// JeffJSTwinCloneDeep.swift
// JeffJS — native twin of Apollo Client's `cloneDeep` (@apollo/client
// utilities), the helper Apollo's cache and Home Depot's product pages copy
// query results with (14 % of the product listing page's JS time).
//
//   cloneDeep(v) = helper(v, undefined)
//   helper(v, seen) by Object.prototype.toString.call(v):
//     [object Array]:  seen ||= new Map; the copy already made for v, or
//                      copy = v.slice(0), seen.set(v, copy),
//                      copy.forEach((c, i) => copy[i] = helper(c, seen))
//     [object Object]: seen ||= new Map; the copy already made for v, or
//                      copy = Object.create(Object.getPrototypeOf(v)),
//                      seen.set(v, copy),
//                      Object.keys(v).forEach(k => copy[k] = helper(v[k], seen))
//     otherwise:       v
//
// The copies are fresh objects nobody else has seen until the call returns,
// so a declined call (proxy, accessor, a setter on a copy's prototype chain,
// holes, a class other than a plain object or array) leaves nothing behind.

import Foundation

nonisolated enum JeffJSTwinCloneDeep {

    static let family = JeffJSNativeTwins.Family(
        name: "cloneDeep",
        roles: ["Tv", "Iu"],
        values: ["BO"],
        source: reference,
        needs: .clone,
        accepts: { _, _, _ in true },
        run: run)

    /// As homedepot.com ships it (browse-mobile build, names kept).
    static let reference = """
        var BO=Object.prototype.toString;function Tv(e){return Iu(e)}function Iu(e,t){switch(BO.call(e)){case"[object Array]":{if(t=t||new Map,t.has(e))return t.get(e);var r=e.slice(0);return t.set(e,r),r.forEach(function(i,o){r[o]=Iu(i,t)}),r}case"[object Object]":{if(t=t||new Map,t.has(e))return t.get(e);var n=Object.create(Object.getPrototypeOf(e));return t.set(e,n),Object.keys(e).forEach(function(i){n[i]=Iu(e[i],t)}),n}default:return e}}
        """

    static func run(_ ctx: JeffJSContext, _ fam: JeffJSNativeTwins.Resolved,
                    _ argv: UnsafePointer<JeffJSValue>?, _ argc: Int) throws -> JeffJSValue {
        guard let intrinsics = ctx.twinIntrinsics,
              fam.values[0].toObject() === intrinsics.toString, intrinsics.toString != nil else {
            throw JeffJSTwinDecline(reason: "toString cell changed")
        }
        var c = Cloner(rd: JeffJSTwinReader(ctx), arrayProto: intrinsics.arrayProto)
        defer { c.finish() }
        return try c.clone(argc > 0 ? argv![0] : .undefined, depth: 0)
    }

    struct Cloner {
        let rd: JeffJSTwinReader
        let arrayProto: JeffJSObject?
        /// v → its copy (owned references, released by `finish`).
        var seen: [ObjectIdentifier: JeffJSValue] = [:]

        func finish() { for (_, v) in seen { v.freeValue() } }

        mutating func clone(_ v: JeffJSValue, depth: Int) throws -> JeffJSValue {
            guard let o = v.toObject() else { return v.dupValue() }
            switch try rd.tag(v) {
            case .array:
                if let copy = seen[ObjectIdentifier(o)] { return copy.dupValue() }
                try rd.depthGuard(depth)
                let (_, values) = try rd.plainArray(v, arrayProto: arrayProto)
                var out: [JeffJSValue] = []
                out.reserveCapacity(values.count)
                // The copy goes into `seen` before its children: a child that
                // is this array gets the copy itself. Children are filled in
                // place below, so the array has to exist first.
                let copy = rd.ctx.newArrayFrom(Array(values.map { $0.dupValue() }))
                seen[ObjectIdentifier(o)] = copy.dupValue()
                guard let copyObj = copy.toObject() else { copy.freeValue(); throw JeffJSTwinDecline(reason: "array") }
                do {
                    for i in 0..<values.count {
                        let c = try clone(values[i], depth: depth + 1)
                        out.append(c)
                    }
                } catch {
                    for x in out { x.freeValue() }
                    copy.freeValue()
                    throw error
                }
                for (i, c) in out.enumerated() {
                    if rd.ctx.setPropertyUint32(obj: copy, index: UInt32(i), value: c) < 0 {
                        copy.freeValue()
                        throw JeffJSTwinDecline(reason: "array write")
                    }
                }
                _ = copyObj
                return copy
            case .object:
                if let copy = seen[ObjectIdentifier(o)] { return copy.dupValue() }
                try rd.depthGuard(depth)
                let src = try rd.plainObject(v)
                let keys = try rd.ownKeys(src, enumerableOnly: true, symbols: false)
                let proto = src.proto
                for k in keys { try rd.setCreatesOwn(proto, k) }
                let copy = rd.ctx.newObjectProto(proto: proto.map { .borrowedObject($0) } ?? .null)
                seen[ObjectIdentifier(o)] = copy.dupValue()
                guard let copyObj = copy.toObject() else { copy.freeValue(); throw JeffJSTwinDecline(reason: "object") }
                do {
                    for k in keys {
                        let c = try clone(try rd.ownData(src, k), depth: depth + 1)
                        try rd.define(copyObj, k, c)
                    }
                } catch {
                    copy.freeValue()
                    throw error
                }
                return copy
            default:
                return v.dupValue()
            }
        }
    }
}
