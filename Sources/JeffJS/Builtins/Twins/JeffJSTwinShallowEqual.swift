// JeffJSTwinShallowEqual.swift
// JeffJS — native twins of React's `shallowEqual` (React.memo, PureComponent,
// useSyncExternalStore, …) and of fbjs's `shallowEqual` module (Meta's app
// code: Relay / Comet).
//
//   shallowEqual(a, b):
//     objectIs(a, b)                                    → true
//     a or b not a non-null object (typeof "object")   → false
//     Object.keys(a).length !== Object.keys(b).length  → false
//     for each key k of a: !hasOwnProperty.call(b, k) || !objectIs(a[k], b[k]) → false
//     → true
//
// React: `objectIs` is a closure cell holding `Object.is` (React's own `is`
// fallback only when Object.is is missing) and `hasOwnProperty` a cell holding
// Object.prototype.hasOwnProperty. Shipped as:
//   A  16.x / 17.x (UMD and cjs): `for(d=0;…)if(!$i.call(b,c[d])||!Qa(a[c[d]],b[c[d]]))`
//   B  18.x (UMD and cjs) and 19.x cjs: `var e=c[d]; if(!ja.call(b,e)||!He(a[e],b[e]))`
//   C  Meta's www build (19.3.0-www-classic, Facebook and Instagram, re-minified:
//      `typeof e!="object"`, `t===null`)
// fbjs (Meta's `__d("shallowEqual")`, identical in every Facebook / Instagram
// bundle seen 2026-10-18 … 10-23): `is` is a function of the module (a member)
// and `hasOwnProperty` a bound `call` (`hasOwnProperty.call.bind(hasOwnProperty)`).
//
// The twin reads ordinary objects with data properties only (props objects):
// a proxy, an accessor, an array or a host object anywhere it would read
// declines and the bytecode runs. Nothing is written.

import Foundation

nonisolated enum JeffJSTwinShallowEqual {

    static let family = JeffJSNativeTwins.Family(
        name: "react-shallowEqual",
        roles: ["Ob"],
        values: ["Qa", "$i"],
        source: referenceA,
        alternates: [
            (referenceB, ["qc"], ["ua", "Zd"]),
            (referenceC, ["vo"], ["Bn", "xt"]),
            (referenceD, ["shallowEqual"], ["objectIs", "hasOwnProperty"]),
            (referenceE, ["Je"], ["He", "Ie"]),
            (referenceF, ["Ie"], ["He", "ja"]),
            (referenceG, ["Jn"], ["ee", "Na"]),
        ],
        needs: .shallow,
        accepts: { _, _, _ in true },
        run: { ctx, fam, argv, argc in try react(ctx, fam.values[0], fam.values[1], argv, argc) },
        runLeaf: { ctx, cells, argv, argc in try react(ctx, try cells.value(0), try cells.value(1), argv, argc) })

    /// React 16.13.1 UMD (homedepot.com); 16.14 / 17.0.2 are the same code.
    static let referenceA = """
        var Qa="function"===typeof Object.is?Object.is:function(a,b){return a===b&&(0!==a||1/a===1/b)||a!==a&&b!==b},$i=Object.prototype.hasOwnProperty;function Ob(a,b){if(Qa(a,b))return!0;if("object"!==typeof a||null===a||"object"!==typeof b||null===b)return!1;var c=Object.keys(a),d=Object.keys(b);if(c.length!==d.length)return!1;for(d=0;d<c.length;d++)if(!$i.call(b,c[d])||!Qa(a[c[d]],b[c[d]]))return!1;return!0}
        """

    /// React 18.2 / 18.3 UMD and cjs.
    static let referenceB = """
        var ua="function"===typeof Object.is?Object.is:function(a,b){return a===b&&(0!==a||1/a===1/b)||a!==a&&b!==b},Zd=Object.prototype.hasOwnProperty;function qc(a,b){if(ua(a,b))return!0;if("object"!==typeof a||null===a||"object"!==typeof b||null===b)return!1;var c=Object.keys(a),d=Object.keys(b);if(c.length!==d.length)return!1;for(d=0;d<c.length;d++){var e=c[d];if(!Zd.call(b,e)||!ua(a[e],b[e]))return!1}return!0}
        """

    /// Meta's ReactDOM-prod.classic (19.3.0-www-classic-07dde64d / a6792708).
    static let referenceC = """
        function On(e,t){return e===t&&(e!==0||1/e===1/t)||e!==e&&t!==t}var Bn=typeof Object.is=="function"?Object.is:On,xt=Object.prototype.hasOwnProperty;function vo(e,t){if(Bn(e,t))return!0;if(typeof e!="object"||e===null||typeof t!="object"||t===null)return!1;var n=Object.keys(e),r=Object.keys(t);if(n.length!==r.length)return!1;for(r=0;r<n.length;r++){var o=n[r];if(!xt.call(t,o)||!Bn(e[o],t[o]))return!1}return!0}
        """

    /// React 19.2 cjs (react-dom-client.production.js, unminified).
    static let referenceD = """
        var hasOwnProperty = Object.prototype.hasOwnProperty;
        function is(x, y) {
          return (x === y && (0 !== x || 1 / x === 1 / y)) || (x !== x && y !== y);
        }
        var objectIs = "function" === typeof Object.is ? Object.is : is;
        function shallowEqual(objA, objB) {
          if (objectIs(objA, objB)) return !0;
          if (
            "object" !== typeof objA ||
            null === objA ||
            "object" !== typeof objB ||
            null === objB
          )
            return !1;
          var keysA = Object.keys(objA),
            keysB = Object.keys(objB);
          if (keysA.length !== keysB.length) return !1;
          for (keysB = 0; keysB < keysA.length; keysB++) {
            var currentKey = keysA[keysB];
            if (
              !hasOwnProperty.call(objB, currentKey) ||
              !objectIs(objA[currentKey], objB[currentKey])
            )
              return !1;
          }
          return !0;
        }
        """

    /// A or B re-minified by a site's bundler: terser 5 (webpack's default)
    /// turns `"object"!==typeof a` into `"object"!=typeof e`; esbuild (Vite)
    /// also writes `e===null`. E = terser of 16.x / 17.x, F = terser of 18.x /
    /// 19.x, G = esbuild of 16.x / 17.x (esbuild of 18.x / 19.x is C's code).
    static let referenceE = """
        var He="function"==typeof Object.is?Object.is:function(e,t){return e===t&&(0!==e||1/e==1/t)||e!=e&&t!=t},Ie=Object.prototype.hasOwnProperty;function Je(e,t){if(He(e,t))return!0;if("object"!=typeof e||null===e||"object"!=typeof t||null===t)return!1;var n=Object.keys(e),r=Object.keys(t);if(n.length!==r.length)return!1;for(r=0;r<n.length;r++)if(!Ie.call(t,n[r])||!He(e[n[r]],t[n[r]]))return!1;return!0}
        """
    static let referenceF = """
        var He="function"==typeof Object.is?Object.is:function(e,t){return e===t&&(0!==e||1/e==1/t)||e!=e&&t!=t},ja=Object.prototype.hasOwnProperty;function Ie(e,n){if(He(e,n))return!0;if("object"!=typeof e||null===e||"object"!=typeof n||null===n)return!1;var t=Object.keys(e),r=Object.keys(n);if(t.length!==r.length)return!1;for(r=0;r<t.length;r++){var l=t[r];if(!ja.call(n,l)||!He(e[l],n[l]))return!1}return!0}
        """
    static let referenceG = """
        function Ca(e,n){return e===n&&(e!==0||1/e===1/n)||e!==e&&n!==n}var ee=typeof Object.is=="function"?Object.is:Ca,Na=Object.prototype.hasOwnProperty;function Jn(e,n){if(ee(e,n))return!0;if(typeof e!="object"||e===null||typeof n!="object"||n===null)return!1;var t=Object.keys(e),r=Object.keys(n);if(t.length!==r.length)return!1;for(r=0;r<t.length;r++)if(!Na.call(n,t[r])||!ee(e[t[r]],n[t[r]]))return!1;return!0}
        """

    static let fbjsFamily = JeffJSNativeTwins.Family(
        name: "fbjs-shallowEqual",
        roles: ["s", "l"],
        values: ["e"],
        source: referenceFBJS,
        needs: .shallow,
        accepts: { _, _, _ in true },
        run: runFBJS)

    /// Meta's `__d("shallowEqual",[],…)` module body (Facebook and Instagram).
    static let referenceFBJS = """
        var e=Object.prototype.hasOwnProperty.call.bind(Object.prototype.hasOwnProperty);function l(e,t){return e===t?e!==0||t!==0||1/e===1/t:e!==e&&t!==t}function s(t,n){if(l(t,n))return!0;if(typeof t!="object"||t===null||typeof n!="object"||n===null)return!1;var r=Object.keys(t),o=Object.keys(n);if(r.length!==o.length)return!1;for(var a=0;a<r.length;a++)if(!e(n,r[a])||!l(t[r[a]],n[r[a]]))return!1;return!0}
        """

    static func react(_ ctx: JeffJSContext, _ objectIs: JeffJSValue, _ hasOwn: JeffJSValue,
                      _ argv: UnsafePointer<JeffJSValue>?, _ argc: Int) throws -> JeffJSValue {
        guard let intrinsics = ctx.twinIntrinsics,
              let isFn = intrinsics.objectIs, objectIs.toObject() === isFn,
              let hop = intrinsics.hasOwnProperty, hasOwn.toObject() === hop else {
            throw JeffJSTwinDecline(reason: "objectIs / hasOwnProperty cell changed")
        }
        return try compare(ctx, argv, argc) ? .JS_TRUE : .JS_FALSE
    }

    static func runFBJS(_ ctx: JeffJSContext, _ fam: JeffJSNativeTwins.Resolved,
                        _ argv: UnsafePointer<JeffJSValue>?, _ argc: Int) throws -> JeffJSValue {
        // e: Function.prototype.call bound to Object.prototype.hasOwnProperty, no arguments.
        guard let intrinsics = ctx.twinIntrinsics, let eo = fam.values[0].toObject(),
              case .boundFunction(let bf) = eo.payload, bf.argv.isEmpty,
              let callFn = intrinsics.call, bf.funcObj.toObject() === callFn,
              let hop = intrinsics.hasOwnProperty, bf.thisVal.toObject() === hop else {
            throw JeffJSTwinDecline(reason: "bound hasOwnProperty changed")
        }
        return try compare(ctx, argv, argc) ? .JS_TRUE : .JS_FALSE
    }

    /// shallowEqual(argv[0], argv[1]) with SameValue and an own-property test.
    /// The answer does not depend on the order the keys are visited in, but
    /// a getter would run at the point the bytecode reaches its key: a's keys
    /// are visited in [[OwnPropertyKeys]] order (shape order when it has no
    /// index keys) and any accessor declines before the bytecode would have
    /// called it.
    static func compare(_ ctx: JeffJSContext, _ argv: UnsafePointer<JeffJSValue>?, _ argc: Int) throws -> Bool {
        let a = argc > 0 ? argv![0] : .undefined
        let b = argc > 1 ? argv![1] : .undefined
        if sameValue(ctx, a, b) { return true }
        // typeof x === "object" && x !== null: a non-callable object. A
        // non-ordinary one declines below before anything is answered.
        guard a.isObject, b.isObject, !ctx.isCallable(a), !ctx.isCallable(b) else { return false }
        let rd = JeffJSTwinReader(ctx)
        let ao = try rd.plainObject(a), bo = try rd.plainObject(b)
        // Object.keys(b).length (b's values are read only through a's keys).
        guard let na = keyCount(rd, ao), let nb = keyCount(rd, bo) else {
            return try compareSorted(ctx, rd, ao, bo)
        }
        if na != nb { return false }
        guard let shape = ao.shape else { return true }
        let n = min(shape.prop.count, ao.propCount)
        for i in 0..<n {
            let p = shape.prop[i]
            let atom = p.atom
            if atom == 0 || p.flags.contains(.hidden) || !p.flags.contains(.enumerable) { continue }
            if isSymbolOrPrivate(rd, atom) { continue }
            if !p.flags.isPlainData || ao.extra(at: i) != nil { throw JeffJSTwinDecline(reason: "accessor") }
            if !ctx.hasOwnPropertyAtom(bo, atom) { return false }
            if !sameValue(ctx, ao.dataValue(at: i), try rd.ownData(bo, atom)) { return false }
        }
        return true
    }

    /// Object.is: equal bits are the same value (also NaN / -0 against themselves).
    @inline(__always)
    static func sameValue(_ ctx: JeffJSContext, _ x: JeffJSValue, _ y: JeffJSValue) -> Bool {
        return x.bits == y.bits || ctx.sameValue(x, y)
    }

    /// Enumerable string keys of `o` (Object.keys(o).length), nil when one is
    /// an index key (the slow path visits those first, sorted).
    @inline(__always)
    static func keyCount(_ rd: JeffJSTwinReader, _ o: JeffJSObject) -> Int? {
        guard let shape = o.shape else { return 0 }
        var c = 0
        let n = min(shape.prop.count, o.propCount)
        for i in 0..<n {
            let p = shape.prop[i]
            if p.atom == 0 || p.flags.contains(.hidden) || !p.flags.contains(.enumerable) { continue }
            if rd.rt.atomIsArrayIndex(p.atom) { return nil }
            if isSymbolOrPrivate(rd, p.atom) { continue }
            c += 1
        }
        return c
    }

    @inline(__always)
    static func isSymbolOrPrivate(_ rd: JeffJSTwinReader, _ atom: UInt32) -> Bool {
        guard let entry = rd.rt.atomArray[Int(atom)] else { return false }
        let t = entry.atomType
        return t == .JS_ATOM_TYPE_SYMBOL || t == .JS_ATOM_TYPE_GLOBAL_SYMBOL || t == .JS_ATOM_TYPE_PRIVATE
    }

    /// The general case (index keys): the key lists as Object.keys makes them.
    static func compareSorted(_ ctx: JeffJSContext, _ rd: JeffJSTwinReader,
                              _ ao: JeffJSObject, _ bo: JeffJSObject) throws -> Bool {
        let ka = try rd.ownKeys(ao, enumerableOnly: true, symbols: false)
        let kb = try rd.ownKeys(bo, enumerableOnly: true, symbols: false)
        if ka.count != kb.count { return false }
        for k in ka {
            if !ctx.hasOwnPropertyAtom(bo, k) { return false }
            if !ctx.sameValue(try rd.ownData(ao, k), try rd.ownData(bo, k)) { return false }
        }
        return true
    }
}
