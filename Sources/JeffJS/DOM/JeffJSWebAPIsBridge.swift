// JeffJSWebAPIsBridge.swift
// Native implementations of Web APIs for JeffJS.
//
// Replaces interpreted JS polyfills with compiled Swift for hot-path APIs:
//   - performance          (CFAbsoluteTimeGetCurrent — no JS Date.now overhead)
//   - crypto.getRandomValues (SecRandomCopyBytes — no interpreted UTF loop)
//   - TextEncoder/TextDecoder (native Swift UTF-8 — replaces ~70-line JS loop)
//   - crypto.subtle.digest   (CryptoKit SHA-1/256/384/512 -> Promise<ArrayBuffer>)
//   - MessageChannel/MessagePort (React scheduler support)
//   - Intl                   (JeffJSIntlBridge — Foundation-backed ECMA-402)
//
// These are registered on the JeffJS context BEFORE polyfill evaluation so that
// the existing polyfill `if (typeof X === 'undefined')` guards skip the JS
// implementations automatically.

import Foundation
import Security
import CryptoKit

@MainActor
final class JeffJSWebAPIsBridge {

    // MARK: - State

    private let initTimeMS: Double
    private var perfMarks: [String: Double] = [:]
    private var perfMeasures: [(name: String, startTime: Double, duration: Double)] = []

    /// Helper: `(jsArray) -> Uint8Array`. Created once, reused by TextEncoder.encode.
    private var uint8FromArrayFn: JeffJSValue?

    /// Native ECMA-402 implementation (registered alongside the other Web APIs
    /// so a host that installs the bridges gets a real `Intl` before its own
    /// `typeof Intl`-guarded stubs run).
    private(set) var intlBridge: JeffJSIntlBridge?

    init() {
        self.initTimeMS = CFAbsoluteTimeGetCurrent() * 1000
    }

    // MARK: - Registration

    func register(on ctx: JeffJSContext) {
        let global = ctx.getGlobalObject()
        defer { global.freeValue() }

        // Uint8Array creation helper — needed by TextEncoder.encode.
        // Stored once; avoids repeated eval during encode calls.
        let helperFn = ctx.eval(
            input: "(function(a){return new Uint8Array(a)})",
            filename: "<uint8-helper>",
            evalFlags: JS_EVAL_TYPE_GLOBAL
        )
        if !helperFn.isException && helperFn.isFunction {
            self.uint8FromArrayFn = helperFn
        } else {
            helperFn.freeValue()
        }

        registerPerformance(on: ctx, global: global)
        registerCrypto(on: ctx, global: global)
        registerTextEncoding(on: ctx, global: global)
        registerMessageChannel(on: ctx, global: global)

        let intl = JeffJSIntlBridge()
        intl.register(on: ctx)
        self.intlBridge = intl
    }

    func teardown() {
        intlBridge?.teardown()
        intlBridge = nil
        uint8FromArrayFn?.freeValue()
        uint8FromArrayFn = nil
        perfMarks.removeAll()
        perfMeasures.removeAll()
    }

    // MARK: - performance

    private func registerPerformance(on ctx: JeffJSContext, global: JeffJSValue) {
        let perf = ctx.newObject()
        let startMS = initTimeMS

        // performance.now() → high-resolution timestamp
        ctx.setPropertyFunc(obj: perf, name: "now", fn: { _, _, _ in
            return .newFloat64(CFAbsoluteTimeGetCurrent() * 1000 - startMS)
        }, length: 0)

        // performance.timeOrigin
        _ = ctx.setPropertyStr(obj: perf, name: "timeOrigin", value: .newFloat64(startMS))

        // performance.mark(name)
        ctx.setPropertyFunc(obj: perf, name: "mark", fn: { [weak self] ctx, _, args in
            guard let self, args.count > 0,
                  let name = ctx.toSwiftString(args[0]), !name.isEmpty else {
                return JeffJSValue.undefined
            }
            self.perfMarks[name] = CFAbsoluteTimeGetCurrent() * 1000 - startMS
            return JeffJSValue.undefined
        }, length: 1)

        // performance.measure(name, startMark?, endMark?)
        ctx.setPropertyFunc(obj: perf, name: "measure", fn: { [weak self] ctx, _, args in
            guard let self, args.count > 0,
                  let name = ctx.toSwiftString(args[0]), !name.isEmpty else {
                return JeffJSValue.undefined
            }
            let now = CFAbsoluteTimeGetCurrent() * 1000 - startMS
            var start: Double = 0
            var end: Double = now
            if args.count > 1, let s = ctx.toSwiftString(args[1]), let v = self.perfMarks[s] { start = v }
            if args.count > 2, let e = ctx.toSwiftString(args[2]), let v = self.perfMarks[e] { end = v }
            self.perfMeasures.append((name: name, startTime: start, duration: max(0, end - start)))
            return JeffJSValue.undefined
        }, length: 3)

        // performance.getEntriesByType(type)
        ctx.setPropertyFunc(obj: perf, name: "getEntriesByType", fn: { [weak self] ctx, _, args in
            guard let self, args.count > 0,
                  let type = ctx.toSwiftString(args[0]), type == "measure" else {
                return ctx.newArray()
            }
            return self.buildMeasureArray(ctx: ctx, measures: self.perfMeasures)
        }, length: 1)

        // performance.getEntriesByName(name, type?)
        ctx.setPropertyFunc(obj: perf, name: "getEntriesByName", fn: { [weak self] ctx, _, args in
            guard let self, args.count > 0, let name = ctx.toSwiftString(args[0]) else {
                return ctx.newArray()
            }
            let type = args.count > 1 ? (ctx.toSwiftString(args[1]) ?? "measure") : "measure"
            guard type == "measure" else { return ctx.newArray() }
            return self.buildMeasureArray(ctx: ctx, measures: self.perfMeasures.filter { $0.name == name })
        }, length: 2)

        // performance.clearMarks(name?)
        ctx.setPropertyFunc(obj: perf, name: "clearMarks", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            if args.isEmpty || args[0].isUndefined {
                self.perfMarks.removeAll()
            } else if let name = ctx.toSwiftString(args[0]) {
                self.perfMarks.removeValue(forKey: name)
            }
            return JeffJSValue.undefined
        }, length: 0)

        // performance.clearMeasures(name?)
        ctx.setPropertyFunc(obj: perf, name: "clearMeasures", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            if args.isEmpty || args[0].isUndefined {
                self.perfMeasures.removeAll()
            } else if let name = ctx.toSwiftString(args[0]) {
                self.perfMeasures.removeAll { $0.name == name }
            }
            return JeffJSValue.undefined
        }, length: 0)

        _ = ctx.setPropertyStr(obj: global, name: "performance", value: perf)
    }

    private func buildMeasureArray(ctx: JeffJSContext,
                                   measures: [(name: String, startTime: Double, duration: Double)]) -> JeffJSValue {
        let arr = ctx.newArray()
        for (i, m) in measures.enumerated() {
            let entry = ctx.newObject()
            _ = ctx.setPropertyStr(obj: entry, name: "name", value: ctx.newStringValue(m.name))
            _ = ctx.setPropertyStr(obj: entry, name: "entryType", value: ctx.newStringValue("measure"))
            _ = ctx.setPropertyStr(obj: entry, name: "startTime", value: .newFloat64(m.startTime))
            _ = ctx.setPropertyStr(obj: entry, name: "duration", value: .newFloat64(m.duration))
            _ = ctx.setPropertyUint32(obj: arr, index: UInt32(i), value: entry)
        }
        ctx.setArrayLength(arr, Int64(measures.count))
        return arr
    }

    // MARK: - crypto

    private func registerCrypto(on ctx: JeffJSContext, global: JeffJSValue) {
        let crypto = ctx.newObject()

        // crypto.getRandomValues(typedArray) → fills with random bytes, returns same array
        ctx.setPropertyFunc(obj: crypto, name: "getRandomValues", fn: { ctx, _, args in
            guard args.count > 0 else { return JeffJSValue.undefined }
            let typedArray = args[0]
            let lengthVal = ctx.getPropertyStr(obj: typedArray, name: "length")
            let length = Int(ctx.toInt32(lengthVal) ?? 0)
            lengthVal.freeValue()
            guard length > 0 else { return typedArray.dupValue() }

            var bytes = [UInt8](repeating: 0, count: length)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            for i in 0..<length {
                _ = ctx.setPropertyUint32(obj: typedArray, index: UInt32(i), value: .newInt32(Int32(bytes[i])))
            }
            return typedArray.dupValue()
        }, length: 1)

        // crypto.randomUUID()
        ctx.setPropertyFunc(obj: crypto, name: "randomUUID", fn: { ctx, _, _ in
            return ctx.newStringValue(UUID().uuidString.lowercased())
        }, length: 0)

        _ = ctx.setPropertyStr(obj: global, name: "crypto", value: crypto)

        // After crypto is on the global: the JS wrapper below looks it up there.
        registerSubtleCrypto(on: ctx)
    }

    // MARK: - crypto.subtle

    /// `crypto.subtle.digest(algorithm, data) -> Promise<ArrayBuffer>` on
    /// CryptoKit, plus NotSupportedError-rejecting stubs for the rest of the
    /// SubtleCrypto surface (so callers see a real failure instead of a
    /// missing-method TypeError).
    private func registerSubtleCrypto(on ctx: JeffJSContext) {
        let global = ctx.getGlobalObject()
        defer { global.freeValue() }
        let crypto = ctx.getPropertyStr(obj: global, name: "crypto")
        defer { crypto.freeValue() }
        guard crypto.isObject else { return }

        // Native synchronous digest; the JS wrapper below turns it into a
        // Promise and owns the DOMException construction (DOMException is a
        // polyfill that does not exist yet at bridge-registration time).
        let digestFn = ctx.newCFunction({ ctx, _, args in
            guard args.count >= 2 else {
                return ctx.throwTypeError(message: "digest requires an algorithm and data")
            }
            let algorithm = ctx.toSwiftString(args[0])?.uppercased() ?? ""
            guard let bytes = JeffJSWebAPIsBridge.bufferBytes(args[1]) else {
                return ctx.throwTypeError(
                    message: "Argument 2 ('data') is not of type '(ArrayBuffer or ArrayBufferView)'")
            }
            let data = Data(bytes)
            let digest: [UInt8]
            switch algorithm {
            case "SHA-1":   digest = Array(Insecure.SHA1.hash(data: data))
            case "SHA-256": digest = Array(SHA256.hash(data: data))
            case "SHA-384": digest = Array(SHA384.hash(data: data))
            case "SHA-512": digest = Array(SHA512.hash(data: data))
            default:
                return ctx.throwTypeError(message: "Unrecognized algorithm name")
            }
            return JeffJSWebAPIsBridge.newArrayBufferValue(ctx: ctx, bytes: digest)
        }, name: "__jeffjsDigestSync", length: 2)
        _ = ctx.setPropertyStr(obj: global, name: "__jeffjsDigestSync", value: digestFn)

        let subtle = ctx.newObject()
        _ = ctx.setPropertyStr(obj: crypto, name: "subtle", value: subtle)

        let setup = ctx.eval(input: #"""
            (function () {
              var g = (typeof globalThis !== 'undefined') ? globalThis : window;
              var digestSync = g.__jeffjsDigestSync;
              try { delete g.__jeffjsDigestSync; } catch (e) {}
              var subtle = g.crypto ? g.crypto.subtle : null;
              if (!subtle || !digestSync) { return; }

              function domError(message, name) {
                var e;
                try { e = new DOMException(message, name); }
                catch (err) { e = new Error(message); e.name = name; }
                return e;
              }
              var SUPPORTED = { 'SHA-1': 1, 'SHA-256': 1, 'SHA-384': 1, 'SHA-512': 1 };
              subtle.digest = function digest(algorithm, data) {
                var name = (typeof algorithm === 'string')
                  ? algorithm
                  : (algorithm && algorithm.name !== undefined ? algorithm.name : '');
                name = String(name).toUpperCase();
                if (!SUPPORTED[name]) {
                  return Promise.reject(domError('Unrecognized algorithm name', 'NotSupportedError'));
                }
                try { return Promise.resolve(digestSync(name, data)); }
                catch (e) { return Promise.reject(e); }
              };
              var unsupported = ['encrypt', 'decrypt', 'sign', 'verify', 'generateKey',
                                 'deriveKey', 'deriveBits', 'importKey', 'exportKey',
                                 'wrapKey', 'unwrapKey'];
              function reject(method) {
                return function () {
                  return Promise.reject(
                    domError('crypto.subtle.' + method + ' is not supported', 'NotSupportedError'));
                };
              }
              for (var i = 0; i < unsupported.length; i++) {
                subtle[unsupported[i]] = reject(unsupported[i]);
              }
            })();
        """#, filename: "<native-subtle>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        setup.freeValue()
    }

    /// Bytes behind an ArrayBuffer, TypedArray or DataView argument.
    static func bufferBytes(_ value: JeffJSValue) -> [UInt8]? {
        guard let obj = value.toObject() else { return nil }
        if obj.classID == JeffJSClassID.arrayBuffer.rawValue ||
           obj.classID == JeffJSClassID.sharedArrayBuffer.rawValue {
            if case .arrayBuffer(let ab) = obj.payload, !ab.detached { return ab.data }
            return nil
        }
        if case .typedArray(let ta) = obj.payload,
           let bufObj = ta.buffer, case .arrayBuffer(let ab) = bufObj.payload, !ab.detached {
            let start = max(0, min(ta.byteOffset, ab.data.count))
            let end = max(start, min(start + ta.byteLength, ab.data.count))
            return Array(ab.data[start..<end])
        }
        return nil
    }

    /// A real ArrayBuffer object (so `new Uint8Array(result)` works).
    static func newArrayBufferValue(ctx: JeffJSContext, bytes: [UInt8]) -> JeffJSValue {
        let ab = JeffJSArrayBuffer(byteLength: bytes.count)
        ab.data = bytes
        var proto: JeffJSObject? = nil
        let abClassID = Int(JSClassID.JS_CLASS_ARRAY_BUFFER.rawValue)
        if abClassID < ctx.classProto.count, ctx.classProto[abClassID].isObject {
            proto = ctx.classProto[abClassID].toObject()
        }
        let obj = jeffJS_createObject(ctx: ctx, proto: proto,
                                      classID: UInt16(JeffJSClassID.arrayBuffer.rawValue))
        obj.payload = JeffJSObjectPayload.arrayBuffer(ab)
        return .makeObject(obj)
    }

    // MARK: - TextEncoder / TextDecoder

    private func registerTextEncoding(on ctx: JeffJSContext, global: JeffJSValue) {
        // Constructor bodies via eval (proven pattern for `new` support).
        // Only the constructors are JS — the hot-path encode/decode methods are native.
        let setup = ctx.eval(input: #"""
            (function(){
                window.TextEncoder = function TextEncoder(){ this.encoding = 'utf-8'; };
                window.TextDecoder = function TextDecoder(label){
                    this.encoding = String(label || 'utf-8').toLowerCase();
                    this.fatal = false;
                    this.ignoreBOM = false;
                };
            })()
        """#, filename: "<te-ctors>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        setup.freeValue()

        // --- TextEncoder.prototype.encode (NATIVE UTF-8) ---
        let teCtor = ctx.getPropertyStr(obj: global, name: "TextEncoder")
        let teProto = ctx.getPropertyStr(obj: teCtor, name: "prototype")

        ctx.setPropertyFunc(obj: teProto, name: "encode", fn: { [weak self] ctx, _, args in
            guard let self, let helper = self.uint8FromArrayFn else { return JeffJSValue.undefined }
            let str = args.count > 0 ? (ctx.toSwiftString(args[0]) ?? "") : ""
            let utf8 = Array(str.utf8)

            let arr = ctx.newArray()
            for (i, byte) in utf8.enumerated() {
                _ = ctx.setPropertyUint32(obj: arr, index: UInt32(i), value: .newInt32(Int32(byte)))
            }
            ctx.setArrayLength(arr, Int64(utf8.count))

            let result = ctx.callFunction(helper, thisVal: .undefined, args: [arr])
            arr.freeValue()
            return result
        }, length: 1)

        // TextEncoder.prototype.encodeInto(source, destination) → { read, written }
        ctx.setPropertyFunc(obj: teProto, name: "encodeInto", fn: { ctx, _, args in
            guard args.count >= 2 else { return JeffJSValue.undefined }
            let str = ctx.toSwiftString(args[0]) ?? ""
            let dest = args[1]
            let destLenVal = ctx.getPropertyStr(obj: dest, name: "length")
            let destLen = Int(ctx.toInt32(destLenVal) ?? 0)
            destLenVal.freeValue()

            let utf8 = Array(str.utf8)
            let written = min(utf8.count, destLen)
            for i in 0..<written {
                _ = ctx.setPropertyUint32(obj: dest, index: UInt32(i), value: .newInt32(Int32(utf8[i])))
            }

            let result = ctx.newObject()
            _ = ctx.setPropertyStr(obj: result, name: "read", value: .newInt32(Int32(str.count)))
            _ = ctx.setPropertyStr(obj: result, name: "written", value: .newInt32(Int32(written)))
            return result
        }, length: 2)

        teProto.freeValue()
        teCtor.freeValue()

        // --- TextDecoder.prototype.decode (NATIVE UTF-8) ---
        let tdCtor = ctx.getPropertyStr(obj: global, name: "TextDecoder")
        let tdProto = ctx.getPropertyStr(obj: tdCtor, name: "prototype")

        ctx.setPropertyFunc(obj: tdProto, name: "decode", fn: { ctx, _, args in
            guard args.count > 0, !args[0].isUndefined, !args[0].isNull else {
                return ctx.newStringValue("")
            }
            let input = args[0]
            let lengthVal = ctx.getPropertyStr(obj: input, name: "length")
            let length = Int(ctx.toInt32(lengthVal) ?? 0)
            lengthVal.freeValue()
            guard length > 0 else { return ctx.newStringValue("") }

            // Read bytes from TypedArray / ArrayBuffer view
            var bytes = [UInt8](repeating: 0, count: length)
            for i in 0..<length {
                let val = ctx.getPropertyUint32(obj: input, index: UInt32(i))
                bytes[i] = UInt8(clamping: ctx.toInt32(val) ?? 0)
                val.freeValue()
            }

            // Native Swift UTF-8 decoding — handles invalid sequences gracefully
            let str = String(bytes: bytes, encoding: .utf8)
                ?? String(bytes.map { Character(UnicodeScalar($0)) })
            return ctx.newStringValue(str)
        }, length: 1)

        tdProto.freeValue()
        tdCtor.freeValue()
    }

    // MARK: - MessageChannel / MessagePort

    private func registerMessageChannel(on ctx: JeffJSContext, global: JeffJSValue) {
        // MessageChannel/MessagePort via minimal JS — uses setTimeout for async delivery.
        // setTimeout isn't available during registration, but postMessage is only called
        // during actual script execution (after GCD timers are installed).
        let mc = ctx.eval(input: #"""
            (function(){
                if (typeof MessageChannel !== 'undefined') return;
                // MessagePort is an EventTarget: 'message' events go through
                // the engine's EventTarget (addEventListener + onmessage).
                // The engine's Event, captured now: a host polyfill may replace
                // window.Event later, and delivery must not depend on it.
                var ET = (typeof EventTarget === 'function') ? EventTarget : function(){};
                var Ev = (typeof Event === 'function') ? Event : null;
                var P = function(){
                    ET.call(this);
                    this.onmessage = null;
                    this.onmessageerror = null;
                    this._counterpart = null;
                    this._started = false;
                    this._closed = false;
                };
                P.prototype = Object.create(ET.prototype);
                Object.defineProperty(P.prototype, 'constructor', { value: P, writable: true, configurable: true });
                P.prototype.start = function(){ this._started = true; };
                P.prototype.close = function(){ this._closed = true; };
                P.prototype.postMessage = function(message){
                    if (this._closed || !this._counterpart || this._counterpart._closed) return;
                    var target = this._counterpart, data = message;
                    setTimeout(function(){
                        if (target._closed || typeof target.dispatchEvent !== 'function') return;
                        var evt = Ev ? new Ev('message') : { type: 'message' };
                        evt.data = data; evt.origin = ''; evt.lastEventId = ''; evt.source = null; evt.ports = [];
                        target.dispatchEvent(evt);
                    }, 0);
                };
                var C = function(){
                    this.port1 = new P();
                    this.port2 = new P();
                    this.port1._counterpart = this.port2;
                    this.port2._counterpart = this.port1;
                };
                window.MessagePort = P;
                window.MessageChannel = C;
            })();
        """#, filename: "<native-mc>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        mc.freeValue()
    }
}
