// JeffJSTwinObjectSpread.swift
// JeffJS — native twin of Babel's `_objectSpread2` helper (object spread
// `{...a, b: 1}` compiled for older browsers), with its `ownKeys`,
// `_defineProperty`, `_toPropertyKey` and `_toPrimitive` helpers.
//
// homedepot.com ships ~1 400 module copies of it in two Babel builds (the
// `_toPrimitive` call passes `t||"default"` in one and `t` in the other; the
// keys reaching it are always strings or symbols, so both behave alike here):
// `_objectSpread2(target, a, b, …)` is 20 % of the home page's JS time.
//
//   for t = 1 … n-1: r = arguments[t] ?? {}
//     t odd:  every enumerable own key k of Object(r) (strings, then symbols):
//             k in target ? defineProperty(target, k, {value: r[k], C/W/E})
//                         : target[k] = r[k]
//     t even: defineProperties(target, getOwnPropertyDescriptors(r))
//   return target
//
// Either branch of the odd case leaves an own data property with all three
// attributes (`k in target` is only false when nothing on the chain has k, so
// [[Set]] meets no setter), so the twin defines it. It runs only when no page
// code can run: the target is an ordinary extensible object with no proxy on
// its chain whose own properties it overwrites are configurable data
// properties; sources are ordinary objects with data properties (nullish,
// number, boolean, symbol and bigint sources have no own keys). Anything else
// (arrays, strings, accessors, host objects) declines before the first write.

import Foundation

nonisolated enum JeffJSTwinObjectSpread {

    static let family = JeffJSNativeTwins.Family(
        name: "objectSpread2",
        roles: ["bf", "Ef", "w0", "T0", "S0"],
        values: [],
        source: referenceA,
        alternates: [(referenceB, ["Qt", "lo", "Hl", "Bl", "Vl"], [])],
        needs: .spread,
        accepts: accepts,
        run: run)

    /// Babel's helpers as homedepot.com ships them (browse-mobile build).
    static let referenceA = """
        function Ef(e,t){var r=Object.keys(e);if(Object.getOwnPropertySymbols){var n=Object.getOwnPropertySymbols(e);t&&(n=n.filter(function(i){return Object.getOwnPropertyDescriptor(e,i).enumerable})),r.push.apply(r,n)}return r}function bf(e){for(var t=1;t<arguments.length;t++){var r=arguments[t]!=null?arguments[t]:{};t%2?Ef(Object(r),!0).forEach(function(n){w0(e,n,r[n])}):Object.getOwnPropertyDescriptors?Object.defineProperties(e,Object.getOwnPropertyDescriptors(r)):Ef(Object(r)).forEach(function(n){Object.defineProperty(e,n,Object.getOwnPropertyDescriptor(r,n))})}return e}function w0(e,t,r){return(t=T0(t))in e?Object.defineProperty(e,t,{value:r,enumerable:!0,configurable:!0,writable:!0}):e[t]=r,e}function T0(e){var t=S0(e,"string");return typeof t=="symbol"?t:t+""}function S0(e,t){if(typeof e!="object"||!e)return e;var r=e[Symbol.toPrimitive];if(r!==void 0){var n=r.call(e,t||"default");if(typeof n!="object")return n;throw new TypeError("@@toPrimitive must return a primitive value.")}return(t==="string"?String:Number)(e)}
        """

    /// The other build (app-header-interactive): `_toPrimitive` passes `t`.
    static let referenceB = """
        function lo(e,t){var n=Object.keys(e);if(Object.getOwnPropertySymbols){var r=Object.getOwnPropertySymbols(e);t&&(r=r.filter(function(a){return Object.getOwnPropertyDescriptor(e,a).enumerable})),n.push.apply(n,r)}return n}function Qt(e){for(var t=1;t<arguments.length;t++){var n=arguments[t]!=null?arguments[t]:{};t%2?lo(Object(n),!0).forEach(function(r){Hl(e,r,n[r])}):Object.getOwnPropertyDescriptors?Object.defineProperties(e,Object.getOwnPropertyDescriptors(n)):lo(Object(n)).forEach(function(r){Object.defineProperty(e,r,Object.getOwnPropertyDescriptor(n,r))})}return e}function Hl(e,t,n){return(t=Bl(t))in e?Object.defineProperty(e,t,{value:n,enumerable:!0,configurable:!0,writable:!0}):e[t]=n,e}function Bl(e){var t=Vl(e,"string");return typeof t=="symbol"?t:t+""}function Vl(e,t){if(typeof e!="object"||!e)return e;var n=e[Symbol.toPrimitive];if(n!==void 0){var r=n.call(e,t);if(typeof r!="object")return r;throw new TypeError("@@toPrimitive must return a primitive value.")}return(t==="string"?String:Number)(e)}
        """

    static func accepts(_ ctx: JeffJSContext, _ argv: UnsafePointer<JeffJSValue>?, _ argc: Int) -> Bool {
        return argc >= 1 && argv![0].isObject
    }

    /// A source: nil = no own keys (nullish / number / boolean / symbol /
    /// bigint), else its ordinary object.
    private static func source(_ rd: JeffJSTwinReader, _ v: JeffJSValue) throws -> JeffJSObject? {
        if v.isUndefined || v.isNull || v.isNumber || v.isBool || v.isSymbol || v.isBigInt { return nil }
        if v.isString { throw JeffJSTwinDecline(reason: "string source") }
        return try rd.plainObject(v)
    }

    static func run(_ ctx: JeffJSContext, _ fam: JeffJSNativeTwins.Resolved,
                    _ argv: UnsafePointer<JeffJSValue>?, _ argc: Int) throws -> JeffJSValue {
        let rd = JeffJSTwinReader(ctx)
        let target = argv![0]
        let e = try rd.plainObject(target)
        guard e.extensible else { throw JeffJSTwinDecline(reason: "target not extensible") }
        try rd.plainChain(e.proto)

        // Pass 1: everything that will be read and every target property
        // that will be replaced, before anything is written.
        var plans: [(obj: JeffJSObject, keys: [UInt32], odd: Bool)] = []
        plans.reserveCapacity(argc - 1)
        for t in 1..<max(argc, 1) {
            guard let r = try source(rd, argv![t]) else { continue }
            if r === e { throw JeffJSTwinDecline(reason: "source is the target") }
            let odd = t % 2 == 1
            let keys = try rd.ownKeys(r, enumerableOnly: odd, symbols: true)
            if keys.isEmpty { continue }
            for k in keys {
                let idx = jeffJS_findOwnPropertyIndex(obj: e, atom: k)
                if idx >= 0 {
                    guard let shape = e.shape, idx < e.propCount, shape.prop[idx].flags.isPlainData,
                          e.extra(at: idx) == nil, shape.prop[idx].flags.contains(.configurable),
                          !shape.prop[idx].flags.contains(.hidden)
                    else { throw JeffJSTwinDecline(reason: "target property not replaceable") }
                }
            }
            plans.append((r, keys, odd))
        }

        // Pass 2: the writes, in the order the helper makes them.
        for plan in plans {
            for k in plan.keys {
                let (v, flags) = try rd.ownDataWithFlags(plan.obj, k)
                let f = plan.odd ? JS_PROP_C_W_E : Int(flags.rawValue) & JS_PROP_C_W_E
                try rd.define(e, k, v.dupValue(), flags: f)
            }
        }
        return target.dupValue()
    }
}
