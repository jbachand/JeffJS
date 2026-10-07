// JeffJSOwnPropertyOrder.swift
// JeffJS — host control over an object's own-key list (Safari surface parity, 2026-10-06).
//
// A browser built on JeffJS has to present WebKit's global surface: Google's /search challenge
// reads `Object.getOwnPropertyNames(window)` (and of interface prototypes), picks entries *by
// index* and hashes what it finds, so the list must equal WebKit's in content and order. Two
// primitives make that possible without moving the host's working implementations:
//
// - **Hidden own properties** (`JeffJSPropertyFlags.hidden`): the property exists and is found
//   by name (`window.__glue`, a bare `__glue` identifier, `in`, `delete`, the host's
//   getProperty), but no own-key enumeration lists it — getOwnPropertyNames, Reflect.ownKeys,
//   getOwnPropertySymbols, Object.keys/values/entries, for-in, JSON, Object.assign/spread
//   (hidden implies non-enumerable). For the host's glue globals and members WebKit lacks.
// - **Reordering** (`reorderOwnProperties`): own-property order = definition order in JS, so a
//   host that defines its members in another order than WebKit can move them afterwards. The
//   object gets a fresh private shape (a new identity: every inline cache keyed by the old one
//   misses), the slots — values, accessors, var-refs — move with their keys.

import Foundation

extension JeffJSPropertyFlags {
    /// Engine-private attribute: skipped by every own-key enumeration (see the file header).
    /// Stored in the shape next to C/W/E; kept when the property is redefined.
    static let hidden = JeffJSPropertyFlags(rawValue: 1 << 6)
    /// Engine-private attribute of a host stub accessor without a setter: an assignment that
    /// reaches it through the prototype chain defines an own data property on the receiver
    /// (instead of failing as for any getter-only accessor). The host's own implementations
    /// assign such members on their instances; a WebIDL-shaped stub added above them on the
    /// prototype must not break that. Kept when the property is redefined.
    static let shadowable = JeffJSPropertyFlags(rawValue: 1 << 7)
}

extension JeffJSContext {

    /// Hides (or shows again) the own property `atom` of `obj`. A hidden property is also made
    /// non-enumerable (the enumerable-only paths then need no check of their own); showing it
    /// again does not restore `enumerable`. Returns false when `obj` has no such own property.
    @discardableResult
    func setOwnPropertyHidden(_ obj: JeffJSValue, atom: UInt32, hidden: Bool) -> Bool {
        guard let jsObj = obj.toObject() else { return false }
        if jsObj.lazyFlags != 0 { jeffJS_materializeLazyProps(jsObj, atom) }
        guard let shape = jsObj.shape, let idx = findShapeProperty(shape, atom) else { return false }
        let cur = shape.prop[idx].flags
        if hidden == cur.contains(.hidden) && (!hidden || !cur.contains(.enumerable)) { return true }
        prepareShapeUpdate(self, jsObj)
        guard let s = jsObj.shape, idx < s.prop.count, s.prop[idx].atom == atom else { return false }
        if hidden { s.prop[idx].flags.insert(.hidden); s.prop[idx].flags.remove(.enumerable) }
        else { s.prop[idx].flags.remove(.hidden) }
        s.enumKeyCache = nil
        return true
    }

    /// Host override of an own property's attributes, whatever its `configurable`: the host
    /// shaping its own platform objects (WebIDL constants are enumerable and non-configurable,
    /// `F.prototype` is non-writable…) after the fact. `writable` applies to data properties only.
    /// Returns false when there is no such own property.
    @discardableResult
    func setOwnPropertyAttributes(_ obj: JeffJSValue, atom: UInt32, enumerable: Bool, configurable: Bool, writable: Bool) -> Bool {
        guard let jsObj = obj.toObject() else { return false }
        if jsObj.lazyFlags != 0 { jeffJS_materializeLazyProps(jsObj, atom) }
        guard let shape = jsObj.shape, let idx = findShapeProperty(shape, atom) else { return false }
        var f = shape.prop[idx].flags
        let isData = !f.isGetSet && f.propType != JeffJSPropertyFlags.autoinit.rawValue
        let want = (enumerable && !f.contains(.hidden), configurable, isData && writable)
        if f.contains(.enumerable) == want.0 && f.contains(.configurable) == want.1 && (!isData || f.contains(.writable) == want.2) { return true }
        if want.0 { f.insert(.enumerable) } else { f.remove(.enumerable) }
        if want.1 { f.insert(.configurable) } else { f.remove(.configurable) }
        if isData { if want.2 { f.insert(.writable) } else { f.remove(.writable) } }
        prepareShapeUpdate(self, jsObj)
        guard let s = jsObj.shape, idx < s.prop.count, s.prop[idx].atom == atom else { return false }
        s.prop[idx].flags = f
        s.enumKeyCache = nil
        return true
    }

    /// Marks the own accessor `atom` of `obj` `.shadowable` (see the flag).
    @discardableResult
    func setOwnPropertyShadowable(_ obj: JeffJSValue, atom: UInt32) -> Bool {
        guard let jsObj = obj.toObject(), let shape = jsObj.shape, let idx = findShapeProperty(shape, atom) else { return false }
        if shape.prop[idx].flags.contains(.shadowable) { return true }
        prepareShapeUpdate(self, jsObj)
        guard let s = jsObj.shape, idx < s.prop.count, s.prop[idx].atom == atom else { return false }
        s.prop[idx].flags.insert(.shadowable)
        return true
    }

    /// True when `obj` has the own property `atom` and it is hidden.
    func isOwnPropertyHidden(_ obj: JeffJSValue, atom: UInt32) -> Bool {
        guard let jsObj = obj.toObject(), let shape = jsObj.shape, let idx = findShapeProperty(shape, atom) else { return false }
        return shape.prop[idx].flags.contains(.hidden)
    }

    /// Puts `obj`'s own properties in a new order: the atoms of `order` that are own properties
    /// first, in that order (repeats and absent atoms are skipped), then every other own property
    /// in its current order. Array-index keys are listed first by the builtins whatever their
    /// slot, so moving them changes nothing visible. Deleted slots are dropped. The object gets a
    /// new private shape; returns false (nothing changed) for objects without an ordinary shape
    /// table (proxies, arrays with element storage) or when the order is already the requested one.
    @discardableResult
    func reorderOwnProperties(_ obj: JeffJSValue, order: [UInt32]) -> Bool {
        // An array's elements are not shape slots; one without elements (Array.prototype) is
        // ordered like any object.
        guard let jsObj = obj.toObject(), jsObj.classID != JeffJSClassID.proxy.rawValue else { return false }
        if jsObj.classID == JeffJSClassID.array.rawValue || jsObj.fastArray {
            if let snap = jsObj.arraySnapshot(), snap.count > 0 { return false }
        }
        // Deferred own properties (a function's name/length/prototype, an error's stack) are
        // slots like any other once they exist; create them so they can be placed.
        if jsObj.lazyFlags != 0 {
            if jsObj.needsLazyNameLength { materializeFunctionNameLength(jsObj) }
            if jsObj.needsLazyPrototype { materializeFunctionPrototype(jsObj) }
            if jsObj.pendingStack != nil { materializeErrorStack(jsObj) }
        }
        guard let shape = jsObj.shape else { return false }
        let count = shape.prop.count
        guard count > 0, jsObj.propValues.count >= count else { return false }
        var used = [Bool](repeating: false, count: count)
        var newIdx: [Int] = []
        newIdx.reserveCapacity(count)
        for a in order where a != 0 {
            if let i = findShapeProperty(shape, a), !used[i] { used[i] = true; newIdx.append(i) }
        }
        for i in 0 ..< count where shape.prop[i].atom != 0 && !used[i] { newIdx.append(i) }
        if newIdx.count == count && shape.deletedPropCount == 0 {
            var same = true
            for (j, i) in newIdx.enumerated() where i != j { same = false; break }
            if same { return false }
        }
        let rt = self.rt
        let ns = cloneShapeRT(rt, shape)   // refCount 1, unhashed, owns a count on the prototype
        var props: [JeffJSShapeProperty] = []
        props.reserveCapacity(newIdx.count)
        var entries: [JeffJSProperty] = []
        entries.reserveCapacity(newIdx.count)
        for i in newIdx {
            var p = shape.prop[i]
            p.hashNext = JeffJSShape.noNext
            props.append(p)
            entries.append(jsObj.propEntry(at: i))
        }
        let n = props.count
        var hashSize = 1
        while hashSize < n { hashSize <<= 1 }
        ns.prop = props
        ns.propCount = n
        ns.propSize = n
        ns.deletedPropCount = 0
        ns.enumKeyCache = nil
        ns.propHashMask = UInt32(hashSize - 1)
        ns.propHash = [UInt32](repeating: JeffJSShape.noNext, count: hashSize)
        for i in 0 ..< n {
            let h = Int(ns.prop[i].atom & ns.propHashMask)
            ns.prop[i].hashNext = ns.propHash[h]
            ns.propHash[h] = UInt32(i)
        }
        // Same pattern as compactProperties: the slot payloads (counted references) move as-is.
        jsObj.replaceProps(entries)
        jsObj.shape = ns
        jeffJS_leaveShape(rt, shape)
        return true
    }
}

// MARK: - Host-deferred own properties

extension JeffJSContext {

    /// Defers every own property of `obj` to `materializer`, which runs (once, with the object)
    /// the first time anything reads, lists, defines, deletes or looks up an own property of
    /// `obj` — directly or through a prototype chain. For host objects with many members that
    /// most pages never touch (WebIDL interface prototypes of APIs the host does not implement):
    /// their names and order appear only when something looks. The materialiser must not
    /// assume a particular caller; the bit is cleared before it runs.
    func setLazyOwnProperties(_ obj: JeffJSValue, _ materializer: @escaping (JeffJSContext, JeffJSValue) -> Void) {
        guard let jsObj = obj.toObject() else { return }
        rt.lazyOwnPropertyMaterializers[ObjectIdentifier(jsObj)] = materializer
        // A private shape: no inline cache can know it, so every access takes a path that
        // materialises first.
        prepareShapeUpdate(self, jsObj)
        if let s = jsObj.shape, s.icCached {
            let ns = jeffJS_moveShapeTables(rt, s)
            jsObj.shape = ns
            jeffJS_leaveShape(rt, s)
        }
        jsObj.lazyFlags |= JeffJSObject.lazyHostBit
    }

    /// True while `obj`'s own properties are still deferred to the host.
    func hasLazyOwnProperties(_ obj: JeffJSValue) -> Bool {
        guard let jsObj = obj.toObject() else { return false }
        return (jsObj.lazyFlags & JeffJSObject.lazyHostBit) != 0
    }

    /// Runs (and forgets) the host materialiser of `jsObj`.
    @inline(never)
    func materializeHostLazyProps(_ jsObj: JeffJSObject) {
        jsObj.lazyFlags &= ~JeffJSObject.lazyHostBit
        guard let m = rt.lazyOwnPropertyMaterializers.removeValue(forKey: ObjectIdentifier(jsObj)) else { return }
        let v = JeffJSValue.borrowedObject(jsObj)
        _ = v.dupValue()   // held for the call (same pattern as jeffJS_shapeSetProto)
        m(self, v)
        v.freeValue()
    }
}
