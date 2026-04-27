// JeffJSQuantumBridge.swift
// Exposes the quantum cache & transport engine to JavaScript via `window.jeffjs`.
//
// JS API:
//   window.jeffjs                       -- the JeffJS namespace object
//   window.jeffjs.version               -- engine version string
//   window.jeffjs.quantum.enabled       -- bool, mirrors quantum.enabled flag
//
//   // Slice-based encoder (multi-key envelope or raw 25-bit master keys)
//   window.jeffjs.quantum.slice.encode(s)         -- str -> hex envelope ("" on failure)
//   window.jeffjs.quantum.slice.decode(hex)       -- hex envelope -> str ("" on failure)
//   window.jeffjs.quantum.slice.encodeRaw(s)
//       -> { keys: ["0x1234567", ...], length: int, seedOffset: int }
//   window.jeffjs.quantum.slice.decodeRaw(resultObject)        -> str
//   window.jeffjs.quantum.slice.decodeRaw(keysArray, len, off) -> str
//
//   // Resolution-deepening chain encoder (SINGLE master key, ≤ 6 chars)
//   window.jeffjs.quantum.chain.encode(s)         -- str -> hex chain key (sync, ≤10s)
//   window.jeffjs.quantum.chain.decode(hex)       -- hex chain key -> str (sync)
//   window.jeffjs.quantum.chain.encodeAsync(s)    -- Promise<hex chain key>
//   window.jeffjs.quantum.chain.decodeAsync(hex)  -- Promise<str>
//
// `keys` from `slice.encodeRaw` are 7-hex-char strings ("0x" prefix)
// representing 25-bit master keys. `chain.encode` returns a 64-hex-char
// string encoding a single deep-octree master key.
//
// The async chain methods follow `JeffJSFetchBridge`: a native function
// takes (input, resolve, reject) callbacks; a JS shim wraps it in
// `new Promise(...)`. Background work runs in a `Task`, then
// `await MainActor.run` invokes the resolver and calls
// `executePendingJobs()` to flush microtasks.

import Foundation

/// JS bridge for the quantum subsystem. Registers `window.jeffjs.quantum`.
@MainActor
final class JeffJSQuantumBridge {

    // MARK: - State

    private let sliceEncoder = QuantumEncoder()
    private let sliceDecoder = QuantumDecoder()
    private let transport    = QuantumTransport()
    private let simulatorBridge = QuantumSimulatorBridge()

    /// JeffJS engine version surfaced as `window.jeffjs.version`.
    static let version = "1.0.0"

    /// Weak ref to the context so async tasks can come back to the main
    /// thread and resolve their Promises against the right runtime.
    private weak var ctx: JeffJSContext?

    /// Stored JS callback references keyed by request ID so resolve/reject
    /// stay alive across the async gap. Mirrors `JeffJSFetchBridge`.
    private var storedCallbacks: [Int: JeffJSValue] = [:]
    private var nextRequestID: Int = 1

    // MARK: - Init

    init() {
        transport.maxAttempts = JeffJSConfig.quantumMaxEncodeAttempts
    }

    // MARK: - Registration

    /// Registers `window.jeffjs.quantum` with `slice` and `chain` sub-namespaces.
    func register(on ctx: JeffJSContext) {
        self.ctx = ctx
        let global = ctx.getGlobalObject()

        // Build window.jeffjs
        let jeffjs = ctx.newPlainObject()
        _ = ctx.setPropertyStr(obj: jeffjs, name: "version", value: ctx.newStringValue(Self.version))

        // Build window.jeffjs.quantum
        let quantum = ctx.newPlainObject()
        _ = ctx.setPropertyStr(obj: quantum, name: "enabled", value: .newBool(JeffJSConfig.quantumEnabled))

        // Build the two sub-namespaces and attach them.
        let slice = registerSlice(on: ctx)
        _ = ctx.setPropertyStr(obj: quantum, name: "slice", value: slice)

        let chain = registerChain(on: ctx)
        _ = ctx.setPropertyStr(obj: quantum, name: "chain", value: chain)

        // Register the quantum simulator sub-namespace
        simulatorBridge.register(on: ctx, quantumObj: quantum)

        // Attach quantum to jeffjs
        _ = ctx.setPropertyStr(obj: jeffjs, name: "quantum", value: quantum)

        // Attach jeffjs to window (the global object IS window in this runtime)
        _ = ctx.setPropertyStr(obj: global, name: "jeffjs", value: jeffjs)

        // Install JS shims that wrap the async native fns in real Promises.
        let shim = """
        (function () {
          var c = window.jeffjs.quantum.chain;
          c.encodeAsync = function (plaintext) {
            return new Promise(function (resolve, reject) {
              c.__nativeEncodeAsync(String(plaintext), resolve, reject);
            });
          };
          c.decodeAsync = function (hexKey) {
            return new Promise(function (resolve, reject) {
              c.__nativeDecodeAsync(String(hexKey), resolve, reject);
            });
          };
        })();
        """
        let shimResult = ctx.eval(input: shim, filename: "<quantum-async-shim>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        shimResult.freeValue()

        // Install simulator async shims (must be after window.jeffjs.quantum.simulator exists)
        simulatorBridge.installShims(on: ctx)
    }

    // MARK: - quantum.slice.*

    private func registerSlice(on ctx: JeffJSContext) -> JeffJSValue {
        let slice = ctx.newPlainObject()

        // slice.encode(str) -> hex envelope ("" on failure)
        ctx.setPropertyFunc(obj: slice, name: "encode", fn: { [weak self] ctx, _, args in
            guard let self else { return ctx.newStringValue("") }
            guard args.count >= 1, let input = ctx.toSwiftString(args[0]) else {
                return ctx.newStringValue("")
            }
            guard let hex = self.transport.sendHex(input) else {
                return ctx.newStringValue("")
            }
            return ctx.newStringValue(hex)
        }, length: 1)

        // slice.decode(hex) -> str ("" on failure)
        ctx.setPropertyFunc(obj: slice, name: "decode", fn: { [weak self] ctx, _, args in
            guard let self else { return ctx.newStringValue("") }
            guard args.count >= 1, let hex = ctx.toSwiftString(args[0]) else {
                return ctx.newStringValue("")
            }
            guard let plain = self.transport.receive(hex: hex) else {
                return ctx.newStringValue("")
            }
            return ctx.newStringValue(plain)
        }, length: 1)

        // slice.encodeRaw(str) -> { keys, length, seedOffset } | null
        ctx.setPropertyFunc(obj: slice, name: "encodeRaw", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.null }
            guard args.count >= 1, let input = ctx.toSwiftString(args[0]) else {
                return JeffJSValue.null
            }
            guard let result = self.sliceEncoder.encode(input, maxAttempts: JeffJSConfig.quantumMaxEncodeAttempts) else {
                return JeffJSValue.null
            }

            let obj = ctx.newPlainObject()
            let keysArr = ctx.newArray()
            for (i, key) in result.keys.enumerated() {
                let hex = String(format: "0x%07X", key)
                _ = ctx.setPropertyUint32(obj: keysArr, index: UInt32(i), value: ctx.newStringValue(hex))
            }
            _ = ctx.setPropertyStr(obj: keysArr, name: "length", value: .newInt32(Int32(result.keys.count)))
            _ = ctx.setPropertyStr(obj: obj, name: "keys", value: keysArr)
            _ = ctx.setPropertyStr(obj: obj, name: "length", value: .newInt32(Int32(result.messageLength)))
            _ = ctx.setPropertyStr(obj: obj, name: "seedOffset", value: .newInt32(Int32(result.seedOffset)))
            return obj
        }, length: 1)

        // slice.decodeRaw(objOrKeys, length?, seedOffset?) -> str
        ctx.setPropertyFunc(obj: slice, name: "decodeRaw", fn: { [weak self] ctx, _, args in
            guard let self else { return ctx.newStringValue("") }
            guard !args.isEmpty else { return ctx.newStringValue("") }

            let first = args[0]

            // Form 1: decodeRaw(resultObject)
            if args.count == 1 && first.isObject {
                let keysVal       = ctx.getPropertyStr(obj: first, name: "keys")
                let lengthVal     = ctx.getPropertyStr(obj: first, name: "length")
                let seedOffsetVal = ctx.getPropertyStr(obj: first, name: "seedOffset")
                defer {
                    keysVal.freeValue()
                    lengthVal.freeValue()
                    seedOffsetVal.freeValue()
                }

                let keys = self.readHexKeys(ctx: ctx, arr: keysVal)
                let length = Int(ctx.toInt32(lengthVal) ?? 0)
                let seedOffset = Int(ctx.toInt32(seedOffsetVal) ?? 0)
                guard !keys.isEmpty else { return ctx.newStringValue("") }

                let plain = self.sliceDecoder.decodeString(keys: keys, messageLength: length, seedOffset: seedOffset) ?? ""
                return ctx.newStringValue(plain)
            }

            // Form 2: decodeRaw(keysArray, length, seedOffset)
            // Form 3: decodeRaw(singleHexString, length, seedOffset)
            let keys: [UInt32]
            if first.isString, let s = ctx.toSwiftString(first), let k = Self.parseHexKey(s) {
                keys = [k]
            } else if first.isObject {
                keys = self.readHexKeys(ctx: ctx, arr: first)
            } else {
                return ctx.newStringValue("")
            }

            let length     = args.count >= 2 ? Int(ctx.toInt32(args[1]) ?? 0) : 0
            let seedOffset = args.count >= 3 ? Int(ctx.toInt32(args[2]) ?? 0) : 0
            let lengthOpt: Int? = length > 0 ? length : nil

            let plain = self.sliceDecoder.decodeString(keys: keys, messageLength: lengthOpt, seedOffset: seedOffset) ?? ""
            return ctx.newStringValue(plain)
        }, length: 3)

        return slice
    }

    // MARK: - quantum.chain.*

    private func registerChain(on ctx: JeffJSContext) -> JeffJSValue {
        let chain = ctx.newPlainObject()

        // chain.encode(str) -> hex chain key (sync, may block up to ~10s)
        ctx.setPropertyFunc(obj: chain, name: "encode", fn: { ctx, _, args in
            guard args.count >= 1, let input = ctx.toSwiftString(args[0]) else {
                return ctx.newStringValue("")
            }
            // A fresh encoder per call keeps the field cache thread-confined.
            let encoder = QuantumChainEncoder()
            guard let key = encoder.encode(input) else {
                return ctx.newStringValue("")
            }
            return ctx.newStringValue(key.hexString)
        }, length: 1)

        // chain.decode(hex) -> str (sync, fast)
        ctx.setPropertyFunc(obj: chain, name: "decode", fn: { ctx, _, args in
            guard args.count >= 1, let hex = ctx.toSwiftString(args[0]) else {
                return ctx.newStringValue("")
            }
            guard let key = QuantumChainKey.fromHex(hex) else {
                return ctx.newStringValue("")
            }
            let decoder = QuantumChainDecoder()
            return ctx.newStringValue(decoder.decodeString(key) ?? "")
        }, length: 1)

        // chain.__nativeEncodeAsync(plaintext, resolve, reject) -> undefined
        ctx.setPropertyFunc(obj: chain, name: "__nativeEncodeAsync", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            guard args.count >= 3 else { return JeffJSValue.undefined }

            let plaintext = ctx.toSwiftString(args[0]) ?? ""
            let resolve = args[1]
            let reject  = args[2]

            let requestID = self.reserveRequestID()
            self.storedCallbacks[requestID]                      = resolve.dupValue()
            self.storedCallbacks[Self.rejectKey(for: requestID)] = reject.dupValue()

            Task { [weak self] in
                let encoder = QuantumChainEncoder()
                let key = encoder.encode(plaintext)

                await MainActor.run {
                    guard let self else { return }
                    self.deliverEncodeResult(requestID: requestID, key: key)
                }
            }

            return JeffJSValue.undefined
        }, length: 3)

        // chain.__nativeDecodeAsync(hexKey, resolve, reject) -> undefined
        ctx.setPropertyFunc(obj: chain, name: "__nativeDecodeAsync", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.undefined }
            guard args.count >= 3 else { return JeffJSValue.undefined }

            let hex = ctx.toSwiftString(args[0]) ?? ""
            let resolve = args[1]
            let reject  = args[2]

            let requestID = self.reserveRequestID()
            self.storedCallbacks[requestID]                      = resolve.dupValue()
            self.storedCallbacks[Self.rejectKey(for: requestID)] = reject.dupValue()

            Task { [weak self] in
                let plain: String?
                if let key = QuantumChainKey.fromHex(hex) {
                    plain = QuantumChainDecoder().decodeString(key)
                } else {
                    plain = nil
                }

                await MainActor.run {
                    guard let self else { return }
                    self.deliverDecodeResult(requestID: requestID, plain: plain)
                }
            }

            return JeffJSValue.undefined
        }, length: 3)

        return chain
    }

    // MARK: - Async result delivery

    private func reserveRequestID() -> Int {
        let id = nextRequestID
        nextRequestID += 2   // step by 2 so resolve and reject get distinct keys
        return id
    }

    private static func rejectKey(for requestID: Int) -> Int { requestID + 1 }

    private func popCallbacks(requestID: Int) -> (resolve: JeffJSValue?, reject: JeffJSValue?) {
        let resolve = storedCallbacks.removeValue(forKey: requestID)
        let reject  = storedCallbacks.removeValue(forKey: Self.rejectKey(for: requestID))
        return (resolve, reject)
    }

    private func deliverEncodeResult(requestID: Int, key: QuantumChainKey?) {
        let (resolveOpt, rejectOpt) = popCallbacks(requestID: requestID)
        defer {
            resolveOpt?.freeValue()
            rejectOpt?.freeValue()
        }
        guard let ctx else { return }

        // Re-bind the active runtime so newly-created JS values get the
        // correct owner — same trick the fetch bridge uses on its main-actor
        // hop. Without this, freshly-created strings can be misattributed.
        JeffJSGCObjectHeader.activeRuntime = ctx.rt

        if let key {
            if let resolve = resolveOpt {
                let arg = ctx.newStringValue(key.hexString)
                let r = ctx.call(resolve, this: .undefined, args: [arg])
                r.freeValue()
            }
        } else if let reject = rejectOpt {
            let err = ctx.newStringValue("chain.encodeAsync: no chain found within seed/backtrack budget")
            let r = ctx.call(reject, this: .undefined, args: [err])
            r.freeValue()
        }

        drainJobs(ctx: ctx)
    }

    private func deliverDecodeResult(requestID: Int, plain: String?) {
        let (resolveOpt, rejectOpt) = popCallbacks(requestID: requestID)
        defer {
            resolveOpt?.freeValue()
            rejectOpt?.freeValue()
        }
        guard let ctx else { return }

        JeffJSGCObjectHeader.activeRuntime = ctx.rt

        if let plain {
            if let resolve = resolveOpt {
                let arg = ctx.newStringValue(plain)
                let r = ctx.call(resolve, this: .undefined, args: [arg])
                r.freeValue()
            }
        } else if let reject = rejectOpt {
            let err = ctx.newStringValue("chain.decodeAsync: invalid hex key or decode failure")
            let r = ctx.call(reject, this: .undefined, args: [err])
            r.freeValue()
        }

        drainJobs(ctx: ctx)
    }

    /// Drain pending microtasks so freshly-resolved Promises fire their
    /// `.then()` handlers immediately.
    private func drainJobs(ctx: JeffJSContext) {
        var drained = ctx.rt.executePendingJobs()
        var retries = 0
        while drained < 0 && ctx.rt.isJobPending() && retries < 10 {
            // A microtask threw — clear the exception and keep draining so
            // unrelated failures don't block our Promise resolution.
            let exc = ctx.getException()
            exc.freeValue()
            drained = ctx.rt.executePendingJobs()
            retries += 1
        }
    }

    // MARK: - JS Array Helpers

    /// Read a JS array of hex strings into a Swift `[UInt32]`.
    private func readHexKeys(ctx: JeffJSContext, arr: JeffJSValue) -> [UInt32] {
        let lenVal = ctx.getPropertyStr(obj: arr, name: "length")
        let len = ctx.toInt32(lenVal) ?? 0
        lenVal.freeValue()
        guard len > 0 else { return [] }

        var keys = [UInt32]()
        keys.reserveCapacity(Int(len))
        for i in 0 ..< len {
            let elem = ctx.getPropertyUint32(obj: arr, index: UInt32(i))
            defer { elem.freeValue() }
            if let s = ctx.toSwiftString(elem), let k = Self.parseHexKey(s) {
                keys.append(k)
            }
        }
        return keys
    }

    /// Parse "0x1234567", "1234567", or any hex string into a UInt32.
    static func parseHexKey(_ s: String) -> UInt32? {
        var stripped = s.trimmingCharacters(in: .whitespaces)
        if stripped.hasPrefix("0x") || stripped.hasPrefix("0X") {
            stripped = String(stripped.dropFirst(2))
        }
        return UInt32(stripped, radix: 16)
    }

}
