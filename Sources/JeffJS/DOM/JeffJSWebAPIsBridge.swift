// JeffJSWebAPIsBridge.swift
// Native implementations of Web APIs for JeffJS.
//
// Replaces interpreted JS polyfills with compiled Swift for hot-path APIs:
//   - performance          (CFAbsoluteTimeGetCurrent — no JS Date.now overhead)
//   - crypto.getRandomValues (SecRandomCopyBytes — no interpreted UTF loop)
//   - TextEncoder/TextDecoder (native Swift UTF-8 — replaces ~70-line JS loop)
//   - MessageChannel/MessagePort (React scheduler support)
//
// These are registered on the JeffJS context BEFORE polyfill evaluation so that
// the existing polyfill `if (typeof X === 'undefined')` guards skip the JS
// implementations automatically.

import Foundation
import Security

@MainActor
final class JeffJSWebAPIsBridge {

    // MARK: - State

    private let initTimeMS: Double
    private var perfMarks: [String: Double] = [:]
    private var perfMeasures: [(name: String, startTime: Double, duration: Double)] = []

    /// Helper: `(jsArray) -> Uint8Array`. Created once, reused by TextEncoder.encode.
    private var uint8FromArrayFn: JeffJSValue?

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
    }

    func teardown() {
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
                var P = function(){
                    this.onmessage = null;
                    this._listeners = [];
                    this._counterpart = null;
                    this._started = false;
                    this._closed = false;
                };
                P.prototype.start = function(){ this._started = true; };
                P.prototype.close = function(){ this._closed = true; };
                P.prototype.addEventListener = function(type, listener){
                    if (type === 'message' && typeof listener === 'function') this._listeners.push(listener);
                };
                P.prototype.removeEventListener = function(type, listener){
                    if (type === 'message') this._listeners = this._listeners.filter(function(l){ return l !== listener; });
                };
                P.prototype.postMessage = function(message){
                    if (this._closed || !this._counterpart || this._counterpart._closed) return;
                    var target = this._counterpart, data = message;
                    setTimeout(function(){
                        if (target._closed) return;
                        var evt = {type:'message',data:data,target:target,currentTarget:target,
                                   origin:'',source:null,ports:[],
                                   preventDefault:function(){},stopPropagation:function(){}};
                        if (typeof target.onmessage === 'function') try{target.onmessage(evt);}catch(e){}
                        for(var i=0;i<target._listeners.length;i++) try{target._listeners[i](evt);}catch(e){}
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
