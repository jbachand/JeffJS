// JeffJSTwinClientStrip.swift
// JeffJS — native twin of Home Depot's data-model "server projection": the
// `_client` strip its data-sources package runs over every component's GraphQL
// field tree (8 % of the home page's JS time before the twins).
//
//   strip = (e, t) => Object.keys(e)
//       .map(r => typeof e[r] == "object" ? (t(e[r]) ? {} : {[r]: strip(e[r], t)}) : {[r]: e[r]})
//       .reduce((r, n) => spread(spread({}, r), n), {})        // or ({...r, ...n})
//   server = e => strip(e, r => !!r._client)
//
// The twin replaces `server` (its predicate is fixed): a fresh object with e's
// keys in order — a value that is an object becomes its own projection unless
// its `_client` is truthy, in which case the key is dropped; other values are
// copied. Shipped two ways: with Babel's objectSpread2 (that helper must be the
// recognised one, see JeffJSTwinObjectSpread) and with native spread.
// `typeof null == "object"`, so a null value makes the predicate throw: the twin
// declines and the bytecode throws it. Keys are listed from ordinary objects and
// dense arrays only.

import Foundation

nonisolated enum JeffJSTwinClientStrip {

    static let family = JeffJSNativeTwins.Family(
        name: "thd-client-strip",
        roles: ["Po", "Cr"],
        values: [],
        source: referenceA,
        alternates: [(referenceB, ["Lde", "VY"], [])],
        foreign: ["Lt": ("objectSpread2", 0)],
        needs: [.strip, .spread],
        accepts: { _, argv, argc in argc >= 1 && argv![0].isObject },
        run: run)

    /// vendor-thd-nucleus build: the spread goes through Babel's helper.
    static let referenceA = """
        function Nt(e,t){var r=Object.keys(e);if(Object.getOwnPropertySymbols){var n=Object.getOwnPropertySymbols(e);t&&(n=n.filter(function(o){return Object.getOwnPropertyDescriptor(e,o).enumerable})),r.push.apply(r,n)}return r}function Lt(e){for(var t=1;t<arguments.length;t++){var r=arguments[t]!=null?arguments[t]:{};t%2?Nt(Object(r),!0).forEach(function(n){go(e,n,r[n])}):Object.getOwnPropertyDescriptors?Object.defineProperties(e,Object.getOwnPropertyDescriptors(r)):Nt(Object(r)).forEach(function(n){Object.defineProperty(e,n,Object.getOwnPropertyDescriptor(r,n))})}return e}function go(e,t,r){return(t=wo(t))in e?Object.defineProperty(e,t,{value:r,enumerable:!0,configurable:!0,writable:!0}):e[t]=r,e}function wo(e){var t=Oo(e,"string");return typeof t=="symbol"?t:t+""}function Oo(e,t){if(typeof e!="object"||!e)return e;var r=e[Symbol.toPrimitive];if(r!==void 0){var n=r.call(e,t);if(typeof n!="object")return n;throw new TypeError("@@toPrimitive must return a primitive value.")}return(t==="string"?String:Number)(e)}const Cr=(e,t)=>Object.keys(e).map(r=>typeof e[r]=="object"?t(e[r])?{}:{[r]:Cr(e[r],t)}:{[r]:e[r]}).reduce((r,n)=>Lt(Lt({},r),n),{}),Po=e=>Cr(e,r=>!!r._client);
        """

    /// dataModel build: native object spread.
    static let referenceB = """
        const VY=(e,t)=>Object.keys(e).map(r=>typeof e[r]=="object"?t(e[r])?{}:{[r]:VY(e[r],t)}:{[r]:e[r]}).reduce((r,n)=>({...r,...n}),{}),Lde=e=>VY(e,r=>!!r._client);
        """

    static func run(_ ctx: JeffJSContext, _ fam: JeffJSNativeTwins.Resolved,
                    _ argv: UnsafePointer<JeffJSValue>?, _ argc: Int) throws -> JeffJSValue {
        guard let intrinsics = ctx.twinIntrinsics else { throw JeffJSTwinDecline(reason: "no intrinsics") }
        let rd = JeffJSTwinReader(ctx)
        let atomClient = ctx.rt.findAtom("_client")
        defer { ctx.rt.freeAtom(atomClient) }
        return try strip(rd, argv![0], atomClient: atomClient, arrayProto: intrinsics.arrayProto, depth: 0)
    }

    /// strip(e): e's keys and values (borrowed), then the projection.
    private static func strip(_ rd: JeffJSTwinReader, _ e: JeffJSValue, atomClient: UInt32,
                              arrayProto: JeffJSObject?, depth: Int) throws -> JeffJSValue {
        try rd.depthGuard(depth)
        guard let o = e.toObject() else { throw JeffJSTwinDecline(reason: "not an object") }
        if JeffJSTwinReader.isProxy(o) { throw JeffJSTwinDecline(reason: "proxy") }
        let out = rd.ctx.newObject()
        guard let outObj = out.toObject() else { throw JeffJSTwinDecline(reason: "object") }
        do {
            if o.classID == JeffJSClassID.array.rawValue {
                let (_, values) = try rd.plainArray(e, arrayProto: arrayProto)
                for (i, v) in values.enumerated() {
                    let atom = rd.rt.newAtomUInt32(UInt32(i))
                    defer { rd.rt.freeAtom(atom) }
                    try project(rd, outObj, atom, v, atomClient: atomClient, arrayProto: arrayProto, depth: depth)
                }
            } else {
                let src = try rd.plainObject(e)
                for k in try rd.ownKeys(src, enumerableOnly: true, symbols: false) {
                    try project(rd, outObj, k, try rd.ownData(src, k), atomClient: atomClient,
                                arrayProto: arrayProto, depth: depth)
                }
            }
        } catch {
            out.freeValue()
            throw error
        }
        return out
    }

    /// One key: `typeof v == "object" ? (v._client ? {} : {[k]: strip(v)}) : {[k]: v}`, merged into `out`.
    private static func project(_ rd: JeffJSTwinReader, _ out: JeffJSObject, _ k: UInt32, _ v: JeffJSValue,
                                atomClient: UInt32, arrayProto: JeffJSObject?, depth: Int) throws {
        if v.isNull { throw JeffJSTwinDecline(reason: "null value (the predicate throws)") }
        if let vo = v.toObject(), !rd.ctx.isCallable(v) {
            // `!!r._client`, read through the chain (data properties only).
            if let c = try rd.chainData(vo, atomClient), rd.ctx.toBool(c) { return }
            try rd.define(out, k, try strip(rd, v, atomClient: atomClient, arrayProto: arrayProto, depth: depth + 1))
        } else {
            try rd.define(out, k, v.dupValue())
        }
    }
}
