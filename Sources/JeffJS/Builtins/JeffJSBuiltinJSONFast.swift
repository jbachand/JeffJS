// JeffJSBuiltinJSONFast.swift
// JeffJS — 1:1 Swift port of QuickJS JavaScript engine
//
// JSON.stringify without a replacer function or property list (the common
// call), written the way QuickJS's js_json_to_str works: the output is
// appended to one code-unit buffer, an object's values are read straight
// from its property slots in the shape's cached enumeration order, an
// array's from its element store, and strings are quoted from their code
// units. The generic serializer (JeffJSBuiltinJSON.stringify) built a Swift
// String per value, looked every key up by name and concatenated the
// pieces: json-stringify ran at 3.8x QuickJS on bench/realworld.js.
//
// Anything this path does not model hands the whole call back to the
// generic serializer before writing a byte (`nil`): a gap/indent, a Proxy,
// a typed array, a host-lazy object. Semantics kept exactly: toJSON (with
// the key argument), wrapper unwrapping, undefined/function/symbol omitted
// in objects and "null" in arrays, non-finite numbers as null, a BigInt is
// a TypeError, circular structures are a TypeError, holes are null, lone
// surrogates are escaped.

import Foundation

/// The output buffer: Latin-1 bytes until a wider unit shows up, then UTF-16.
nonisolated struct JeffJSJSONOut {
    var bytes: [UInt8] = []
    var wide: [UInt16]? = nil

    init(capacity: Int) { bytes.reserveCapacity(capacity) }

    @inline(__always) mutating func put(_ b: UInt8) {
        if wide != nil { wide!.append(UInt16(b)) } else { bytes.append(b) }
    }
    @inline(__always) mutating func unit(_ u: UInt16) {
        if u <= 0xFF && wide == nil { bytes.append(UInt8(truncatingIfNeeded: u)); return }
        if wide == nil {
            var w = [UInt16](); w.reserveCapacity(bytes.count * 2 + 16)
            for b in bytes { w.append(UInt16(b)) }
            wide = w
            bytes = []
        }
        wide!.append(u)
    }
    @inline(__always) mutating func ascii(_ s: StaticString) {
        s.withUTF8Buffer { buf in for b in buf { put(b) } }
    }
    /// ASCII-only text (number formatting).
    @inline(__always) mutating func asciiString(_ s: String) {
        for b in s.utf8 { put(b) }
    }

    private static let hex: [UInt8] = Array("0123456789abcdef".utf8)

    mutating func escapeUnit(_ u: UInt16) {
        put(0x5C); put(0x75)   // \u
        put(Self.hex[Int((u >> 12) & 0xF)]); put(Self.hex[Int((u >> 8) & 0xF)])
        put(Self.hex[Int((u >> 4) & 0xF)]); put(Self.hex[Int(u & 0xF)])
    }

    /// `"..."` with the JSON escapes (QuickJS JS_ToQuotedString): lone
    /// surrogates as \uXXXX, a valid pair as its two units.
    mutating func quoted(_ js: JeffJSString) {
        put(0x22)
        switch js.storage {
        case .str8(let b):
            for c in b {
                switch c {
                case 0x22: put(0x5C); put(0x22)
                case 0x5C: put(0x5C); put(0x5C)
                case 0x08: put(0x5C); put(0x62)
                case 0x0C: put(0x5C); put(0x66)
                case 0x0A: put(0x5C); put(0x6E)
                case 0x0D: put(0x5C); put(0x72)
                case 0x09: put(0x5C); put(0x74)
                default:
                    if c < 0x20 { escapeUnit(UInt16(c)) } else { put(c) }
                }
            }
        case .str16(let w):
            let n = w.count
            var i = 0
            while i < n {
                let u = w[i]; i += 1
                switch u {
                case 0x22: put(0x5C); put(0x22)
                case 0x5C: put(0x5C); put(0x5C)
                case 0x08: put(0x5C); put(0x62)
                case 0x0C: put(0x5C); put(0x66)
                case 0x0A: put(0x5C); put(0x6E)
                case 0x0D: put(0x5C); put(0x72)
                case 0x09: put(0x5C); put(0x74)
                default:
                    if u < 0x20 {
                        escapeUnit(u)
                    } else if u >= 0xD800 && u <= 0xDBFF, i < n, w[i] >= 0xDC00 && w[i] <= 0xDFFF {
                        unit(u); unit(w[i]); i += 1
                    } else if u >= 0xD800 && u <= 0xDFFF {
                        escapeUnit(u)
                    } else {
                        unit(u)
                    }
                }
            }
        }
        put(0x22)
    }

    func finish() -> JeffJSValue {
        if let w = wide {
            return JeffJSValue.makeString(JeffJSString(refCount: 1, len: w.count, isWideChar: true, storage: .str16(w)))
        }
        return JeffJSValue.makeString(JeffJSString(refCount: 1, len: bytes.count, isWideChar: false, storage: .str8(bytes)))
    }
}

nonisolated extension JeffJSBuiltinJSON {

    /// The fast serializer. `nil`: not handled, run the generic one (nothing
    /// was observable yet: no user code ran). `.exception`: pending.
    static func stringifyFast(ctx: JeffJSContext, root: JeffJSValue) -> JeffJSValue? {
        // Quick rejections before any work: the generic path decides these.
        if let o = root.obj, o.classID == JeffJSClassID.proxy.rawValue { return nil }
        var st = FastState(ctx: ctx)
        let r = st.value(root, key: .undefined, inArray: false)
        switch r {
        case .wrote: return st.out.finish()
        case .omitted: return .undefined
        case .exception: return .exception
        case .unsupported: return nil
        }
    }

    private enum FastResult: Equatable { case wrote, omitted, exception, unsupported }

    private struct FastState {
        let ctx: JeffJSContext
        var out: JeffJSJSONOut
        /// Objects on the current path (circular-structure check).
        var stack: [UnsafeRawPointer] = []
        /// Shapes known to have no `toJSON` anywhere on their chain. Cleared
        /// whenever user code runs (a toJSON call), which could add one.
        var noToJSON: [UnsafeRawPointer: Bool] = [:]

        init(ctx: JeffJSContext) {
            self.ctx = ctx
            self.out = JeffJSJSONOut(capacity: 256)
        }

        /// `toJSON` of an object value, or nil when it has none (memoised per
        /// shape). Owned when non-nil.
        mutating func toJSONFunction(_ v: JeffJSValue, _ o: JeffJSObject) -> JeffJSValue?? {
            let sid = o.shapeIdentity
            if let sid = sid, noToJSON[sid] != nil { return .some(nil) }
            let fn = ctx.getProperty(obj: v, atom: JSPredefinedAtom.toJSON.rawValue)
            if fn.isException { return nil }
            if ctx.isFunction(fn) { return .some(fn) }
            fn.freeValue()
            if let sid = sid { noToJSON[sid] = true }
            return .some(nil)
        }

        /// Serializes one value (borrowed). `key` (borrowed) is what toJSON
        /// receives; `inArray` turns an omitted value into "null".
        mutating func value(_ input: JeffJSValue, key: JeffJSValue, inArray: Bool) -> FastResult {
            var v = input
            var owned = false
            defer { if owned { v.freeValue() } }

            // toJSON, then wrapper unwrapping, as the generic path (ES §25.5.2.2 steps 2-4).
            if let o = v.obj {
                let jo = o._obj
                if jo.classID == JeffJSClassID.proxy.rawValue { return .unsupported }
                guard let fnOpt = toJSONFunction(v, jo) else { return .exception }
                if let fn = fnOpt {
                    let keyArg: JeffJSValue
                    let keyOwned: Bool
                    if key.isUndefined { keyArg = ctx.newStringValue(""); keyOwned = true } else { keyArg = key; keyOwned = false }
                    let r = ctx.callFunction(func_: fn, this: v, args: [keyArg])
                    if keyOwned { keyArg.freeValue() }
                    fn.freeValue()
                    noToJSON.removeAll(keepingCapacity: true)
                    if r.isException { return .exception }
                    if owned { v.freeValue() }
                    v = r; owned = true
                }
            }
            if let o = v.obj {
                let cid = o._obj.classID
                if cid == JeffJSClassID.number.rawValue {
                    let n = ctx.toNumber(v); if n.isException { return .exception }
                    if owned { v.freeValue() }; v = n; owned = true
                } else if cid == JeffJSClassID.string.rawValue {
                    let s = ctx.toString(v); if s.isException { return .exception }
                    if owned { v.freeValue() }; v = s; owned = true
                } else if cid == JeffJSClassID.boolean.rawValue {
                    let b = ctx.getObjectData(v)
                    if owned { v.freeValue() }; v = b; owned = false
                } else if cid == JeffJSClassID.bigInt.rawValue {
                    _ = ctx.throwTypeError("Do not know how to serialize a BigInt")
                    return .exception
                }
            }

            if v.isUndefined || v.isSymbol || ctx.isFunction(v) {
                if inArray { out.ascii("null"); return .wrote }
                return .omitted
            }
            if v.isNull { out.ascii("null"); return .wrote }
            if v.isBool { if v.toBool() { out.ascii("true") } else { out.ascii("false") }; return .wrote }
            if v.isInt { out.asciiString(String(v.toInt32())); return .wrote }
            if v.isFloat64 {
                let d = v.toFloat64()
                if d.isNaN || d.isInfinite { out.ascii("null"); return .wrote }
                if d == 0 { out.put(0x30); return .wrote }   // -0 -> "0"
                out.asciiString(JeffJSBuiltinNumber.numberToStringBase10(d))
                return .wrote
            }
            if v.isBigInt {
                _ = ctx.throwTypeError("Do not know how to serialize a BigInt")
                return .exception
            }
            if v.isString {
                guard let js = v.stringValue else { out.ascii("\"\""); return .wrote }
                out.quoted(js)
                return .wrote
            }
            guard let o = v.obj else { return .omitted }
            let jo = o._obj
            let ptr = UnsafeRawPointer(Unmanaged.passUnretained(jo).toOpaque())
            for p in stack where p == ptr {
                _ = ctx.throwTypeError("Converting circular structure to JSON")
                return .exception
            }
            stack.append(ptr)
            defer { stack.removeLast() }
            if ctx.isArray(v) { return array(v, jo) }
            return object(v, jo)
        }

        mutating func array(_ v: JeffJSValue, _ jo: JeffJSObject) -> FastResult {
            let len = ctx.getPropertyLength(v)
            out.put(0x5B)   // [
            var i = 0
            while i < len {
                if i > 0 { out.put(0x2C) }
                // Elements straight from the store when it still covers `i`
                // (user code in a toJSON may shrink the array underneath).
                var el: JeffJSValue = .undefined
                var elOwned = false
                if let storage = jo._fastArrayValues, i < Int(storage.count), i < storage.values.count {
                    el = storage.values[i]
                    if el.isUninitialized { el = .undefined }   // hole
                } else {
                    el = ctx.getPropertyUInt32(obj: v, index: UInt32(i))
                    if el.isException { return .exception }
                    elOwned = true
                }
                let keyVal = ctx.intKeyString(i)
                let r = value(el, key: keyVal, inArray: true)
                keyVal.freeValue()
                if elOwned { el.freeValue() }
                switch r {
                case .wrote, .omitted: break
                case .exception: return .exception
                case .unsupported: return .unsupported
                }
                i += 1
            }
            out.put(0x5D)   // ]
            return .wrote
        }

        mutating func object(_ v: JeffJSValue, _ jo: JeffJSObject) -> FastResult {
            if (jo.lazyFlags & JeffJSObject.lazyHostBit) != 0 { return .unsupported }
            jo.ensureLazyMaterialized()
            guard let shape = jo.shape else { out.ascii("{}"); return .wrote }
            let rt = ctx.rt
            let keys = ctx.shapeEnumKeys(shape).keys
            out.put(0x7B)   // {
            var first = true
            // A typed array serializes as an object whose index keys come
            // first, from the buffer (ES §9.1.12 order; the generic path
            // listed none of them: JSON.stringify(new Uint8Array(2)) was "{}").
            if let n = jo.typedArrayLengthFast() {
                var i = 0
                while i < n {
                    guard let el = jo.typedArrayGet(UInt32(i)) else { break }
                    if !first { out.put(0x2C) }
                    out.put(0x22); out.asciiString(String(i)); out.put(0x22); out.put(0x3A)
                    let r = value(el, key: .undefined, inArray: false)   // numbers: never omitted
                    if r == .exception { return .exception }
                    first = false
                    i += 1
                }
            }
            for k in keys {
                guard let ks = k.stringValue else { continue }
                let atom = rt.findAtom(jsString: ks)
                if atom == 0 { continue }
                // The slot, unless user code changed the object's shape meanwhile.
                var pv: JeffJSValue
                var pvOwned = false
                if let cur = jo.shape, let idx = findShapeProperty(cur, atom), idx < jo.propCount, jo.extra(at: idx) == nil {
                    pv = jo.dataValue(at: idx)
                } else {
                    pv = ctx.getProperty(obj: v, atom: atom)
                    pvOwned = true
                }
                rt.freeAtom(atom)
                if pv.isException { return .exception }
                // Write the key only once the value turned out to be written.
                let mark = out.wide?.count ?? out.bytes.count
                let wasWide = out.wide != nil
                if !first { out.put(0x2C) }
                out.quoted(ks)
                out.put(0x3A)   // :
                let r = value(pv, key: k, inArray: false)
                if pvOwned { pv.freeValue() }
                switch r {
                case .wrote: first = false
                case .omitted:
                    // Roll the key back.
                    if wasWide || out.wide == nil {
                        if out.wide != nil { out.wide!.removeSubrange(mark...) } else { out.bytes.removeSubrange(mark...) }
                    } else {
                        // Went wide while writing the key: everything before
                        // `mark` was narrow, so the rollback point is the same index.
                        out.wide!.removeSubrange(mark...)
                    }
                case .exception: return .exception
                case .unsupported: return .unsupported
                }
            }
            out.put(0x7D)   // }
            return .wrote
        }
    }
}
