// QuantumSimulatorBridge.swift
// Exposes the quantum simulator, algorithms, and Bell tests to JavaScript
// via `window.jeffjs.quantum.simulator`.
//
// Follows the exact same patterns as JeffJSQuantumBridge.swift:
//   - Sync functions for small/fast operations
//   - Async functions (Task + MainActor.run + drainJobs) for heavy algorithms
//   - Stored callbacks for Promise resolution
//
// JS API:
//   // Circuit operations (sync)
//   window.jeffjs.quantum.simulator.createCircuit(numQubits) -> circuitId
//   window.jeffjs.quantum.simulator.gate(id, name, args)     -> undefined
//   window.jeffjs.quantum.simulator.measure(id, qubit)       -> 0 or 1
//   window.jeffjs.quantum.simulator.measureAll(id)           -> [int]
//   window.jeffjs.quantum.simulator.destroyCircuit(id)       -> undefined
//
//   // Algorithms (async, return Promises via JS shim)
//   window.jeffjs.quantum.simulator.shorFactorAsync(N, resolve, reject)
//   window.jeffjs.quantum.simulator.deutschJozsaAsync(...)
//   window.jeffjs.quantum.simulator.bernsteinVaziraniAsync(...)
//   window.jeffjs.quantum.simulator.teleportAsync(...)
//   window.jeffjs.quantum.simulator.superdenseCodingAsync(...)
//
//   // Bell tests (sync for small trials)
//   window.jeffjs.quantum.simulator.chsh(variant, numTrials) -> { S, noSignaling }
//   window.jeffjs.quantum.simulator.ghzCorrelation(n, angles, trials) -> float

import Foundation

@MainActor
final class QuantumSimulatorBridge {

    private weak var ctx: JeffJSContext?

    // Active circuits keyed by ID
    private var circuits: [Int: QuantumCircuit] = [:]
    private var nextCircuitID: Int = 1

    // Async callback storage (same pattern as JeffJSQuantumBridge)
    private var storedCallbacks: [Int: JeffJSValue] = [:]
    private var nextRequestID: Int = 1

    // MARK: - Registration

    /// Call this from JeffJSQuantumBridge.register(on:) to attach native fns.
    /// Does NOT install async shims — call installShims() after window.jeffjs.quantum is live.
    func register(on ctx: JeffJSContext, quantumObj: JeffJSValue) {
        self.ctx = ctx

        let sim = ctx.newPlainObject()

        // --- Circuit management (sync) ---
        registerCircuitOps(on: ctx, simObj: sim)

        // --- Algorithms (native async fns) ---
        registerAlgorithms(on: ctx, simObj: sim)

        // --- Stabilizer simulator (sync) ---
        registerStabilizer(on: ctx, simObj: sim)

        // --- Bell / CHSH tests (sync) ---
        registerBellTests(on: ctx, simObj: sim)

        // Attach simulator to the quantum object
        _ = ctx.setPropertyStr(obj: quantumObj, name: "simulator", value: sim)
    }

    /// Install Promise shims. Must be called AFTER window.jeffjs.quantum.simulator exists.
    func installShims(on ctx: JeffJSContext) {
        installAsyncShims(on: ctx)
    }

    // MARK: - Circuit Operations (sync)

    private func registerCircuitOps(on ctx: JeffJSContext, simObj: JeffJSValue) {

        // createCircuit(numQubits) -> circuitId
        ctx.setPropertyFunc(obj: simObj, name: "createCircuit", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.newInt32(0) }
            let n = Int(ctx.toInt32(args.first ?? .undefined) ?? 4)
            let circuit = QuantumCircuit(numQubits: n)
            let id = self.nextCircuitID
            self.nextCircuitID += 1
            self.circuits[id] = circuit
            return JeffJSValue.newInt32(Int32(id))
        }, length: 1)

        // gate(circuitId, gateName, argsObj) -> undefined
        ctx.setPropertyFunc(obj: simObj, name: "gate", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 2 else { return JeffJSValue.undefined }
            let id = Int(ctx.toInt32(args[0]) ?? 0)
            let name = ctx.toSwiftString(args[1]) ?? ""
            guard let circuit = self.circuits[id] else { return JeffJSValue.undefined }

            let gateArgs = args.count >= 3 ? args[2] : JeffJSValue.undefined
            let qubit = Int(ctx.toInt32(ctx.getPropertyStr(obj: gateArgs, name: "qubit")) ?? 0)

            switch name {
            case "h":       circuit.h(qubit)
            case "x":       circuit.x(qubit)
            case "y":       circuit.y(qubit)
            case "z":       circuit.z(qubit)
            case "s":       circuit.s(qubit)
            case "t":       circuit.t(qubit)
            case "tdagger": circuit.tDagger(qubit)
            case "cnot":
                let control = Int(ctx.toInt32(ctx.getPropertyStr(obj: gateArgs, name: "control")) ?? 0)
                let target  = Int(ctx.toInt32(ctx.getPropertyStr(obj: gateArgs, name: "target")) ?? 1)
                circuit.cnot(control: control, target: target)
            case "phase":
                let angle = Float(ctx.toFloat64(ctx.getPropertyStr(obj: gateArgs, name: "angle")) ?? 0)
                circuit.phase(qubit, angle: angle)
            default: break
            }

            return JeffJSValue.undefined
        }, length: 3)

        // measure(circuitId, qubit) -> 0 or 1
        ctx.setPropertyFunc(obj: simObj, name: "measure", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 2 else { return JeffJSValue.newInt32(0) }
            let id = Int(ctx.toInt32(args[0]) ?? 0)
            let qubit = Int(ctx.toInt32(args[1]) ?? 0)
            guard let circuit = self.circuits[id] else { return JeffJSValue.newInt32(0) }
            let outcome = circuit.measure(qubit)
            return JeffJSValue.newInt32(Int32(outcome))
        }, length: 2)

        // measureAll(circuitId) -> [int]
        ctx.setPropertyFunc(obj: simObj, name: "measureAll", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 1 else { return ctx.newArray() }
            let id = Int(ctx.toInt32(args[0]) ?? 0)
            guard let circuit = self.circuits[id] else { return ctx.newArray() }
            let outcomes = circuit.measureAll()
            let arr = ctx.newArray()
            for (i, outcome) in outcomes.enumerated() {
                let val = JeffJSValue.newInt32(Int32(outcome))
                _ = ctx.setPropertyUint32(obj: arr, index: UInt32(i), value: val)
            }
            return arr
        }, length: 1)

        // destroyCircuit(circuitId) -> undefined
        ctx.setPropertyFunc(obj: simObj, name: "destroyCircuit", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 1 else { return JeffJSValue.undefined }
            let id = Int(ctx.toInt32(args[0]) ?? 0)
            self.circuits.removeValue(forKey: id)
            return JeffJSValue.undefined
        }, length: 1)
    }

    // MARK: - Algorithms (async via stored callbacks)

    private func registerAlgorithms(on ctx: JeffJSContext, simObj: JeffJSValue) {

        // __nativeShorFactor(N, resolve, reject)
        ctx.setPropertyFunc(obj: simObj, name: "__nativeShorFactor", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 3 else { return JeffJSValue.undefined }
            let N = Int(ctx.toInt32(args[0]) ?? 15)
            let resolve = args[1]
            let reject  = args[2]

            let reqID = self.reserveRequestID()
            self.storedCallbacks[reqID] = resolve.dupValue()
            self.storedCallbacks[reqID + 1] = reject.dupValue()

            Task.detached {
                let result = QuantumAlgorithms.shorFactor(N)
                await MainActor.run { [weak self] in
                    guard let self, let ctx = self.ctx else { return }
                    self.deliverResult(reqID: reqID, ctx: ctx) { ctx in
                        let obj = ctx.newPlainObject()
                        if let (p, q) = result.factors {
                            let factors = ctx.newArray()
                            _ = ctx.setPropertyUint32(obj: factors, index: 0, value: JeffJSValue.newInt32(Int32(p)))
                            _ = ctx.setPropertyUint32(obj: factors, index: 1, value: JeffJSValue.newInt32(Int32(q)))
                            _ = ctx.setPropertyStr(obj: obj, name: "factors", value: factors)
                        }
                        _ = ctx.setPropertyStr(obj: obj, name: "N", value: JeffJSValue.newInt32(Int32(result.N)))
                        _ = ctx.setPropertyStr(obj: obj, name: "numQubits", value: JeffJSValue.newInt32(Int32(result.numQubits)))
                        _ = ctx.setPropertyStr(obj: obj, name: "numTrials", value: JeffJSValue.newInt32(Int32(result.numTrials)))
                        return obj
                    }
                }
            }
            return JeffJSValue.undefined
        }, length: 3)

        // __nativeDeutschJozsa(nInput, oracleType, oracleBitsArr, resolve, reject)
        ctx.setPropertyFunc(obj: simObj, name: "__nativeDeutschJozsa", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 5 else { return JeffJSValue.undefined }
            let nInput = Int(ctx.toInt32(args[0]) ?? 4)
            let oracleStr = ctx.toSwiftString(args[1]) ?? "constant0"
            let oracle: OracleType
            switch oracleStr {
            case "constant1": oracle = .constant1
            case "balanced":  oracle = .balanced
            default:          oracle = .constant0
            }
            // Parse oracle bits array
            var oracleBits: [Int]? = nil
            if args[2].isObject {
                let lenVal = ctx.getPropertyStr(obj: args[2], name: "length")
                let len = Int(ctx.toInt32(lenVal) ?? 0)
                lenVal.freeValue()
                if len > 0 {
                    oracleBits = (0 ..< len).map { i in
                        let v = ctx.getPropertyUint32(obj: args[2], index: UInt32(i))
                        defer { v.freeValue() }
                        return Int(ctx.toInt32(v) ?? 0)
                    }
                }
            }
            let resolve = args[3]
            let reject  = args[4]

            let reqID = self.reserveRequestID()
            self.storedCallbacks[reqID] = resolve.dupValue()
            self.storedCallbacks[reqID + 1] = reject.dupValue()

            Task.detached {
                let result = QuantumAlgorithms.deutschJozsa(numInputQubits: nInput, oracle: oracle, oracleBits: oracleBits)
                await MainActor.run { [weak self] in
                    guard let self, let ctx = self.ctx else { return }
                    self.deliverResult(reqID: reqID, ctx: ctx) { ctx in
                        let obj = ctx.newPlainObject()
                        _ = ctx.setPropertyStr(obj: obj, name: "isConstant", value: .newBool(result.isConstant))
                        let arr = ctx.newArray()
                        for (i, m) in result.measurements.enumerated() {
                            _ = ctx.setPropertyUint32(obj: arr, index: UInt32(i), value: JeffJSValue.newInt32(Int32(m)))
                        }
                        _ = ctx.setPropertyStr(obj: obj, name: "measurements", value: arr)
                        return obj
                    }
                }
            }
            return JeffJSValue.undefined
        }, length: 5)

        // __nativeBernsteinVazirani(secretString, resolve, reject)
        ctx.setPropertyFunc(obj: simObj, name: "__nativeBernsteinVazirani", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 3 else { return JeffJSValue.undefined }
            let secret = ctx.toSwiftString(args[0]) ?? "101"
            let resolve = args[1]
            let reject  = args[2]

            let reqID = self.reserveRequestID()
            self.storedCallbacks[reqID] = resolve.dupValue()
            self.storedCallbacks[reqID + 1] = reject.dupValue()

            Task.detached {
                let result = QuantumAlgorithms.bernsteinVazirani(secretString: secret)
                await MainActor.run { [weak self] in
                    guard let self, let ctx = self.ctx else { return }
                    self.deliverResult(reqID: reqID, ctx: ctx) { ctx in
                        let obj = ctx.newPlainObject()
                        _ = ctx.setPropertyStr(obj: obj, name: "recovered", value: ctx.newStringValue(result.recoveredSecret))
                        return obj
                    }
                }
            }
            return JeffJSValue.undefined
        }, length: 3)

        // __nativeTeleport(resolve, reject)
        ctx.setPropertyFunc(obj: simObj, name: "__nativeTeleport", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 2 else { return JeffJSValue.undefined }
            let resolve = args[0]
            let reject  = args[1]

            let reqID = self.reserveRequestID()
            self.storedCallbacks[reqID] = resolve.dupValue()
            self.storedCallbacks[reqID + 1] = reject.dupValue()

            Task.detached {
                let result = QuantumAlgorithms.teleport()
                await MainActor.run { [weak self] in
                    guard let self, let ctx = self.ctx else { return }
                    self.deliverResult(reqID: reqID, ctx: ctx) { ctx in
                        let obj = ctx.newPlainObject()
                        _ = ctx.setPropertyStr(obj: obj, name: "success", value: .newBool(result.success))
                        _ = ctx.setPropertyStr(obj: obj, name: "bobOutcome", value: JeffJSValue.newInt32(Int32(result.bobOutcome)))
                        return obj
                    }
                }
            }
            return JeffJSValue.undefined
        }, length: 2)

        // __nativeSuperdenseCoding(bit0, bit1, resolve, reject)
        ctx.setPropertyFunc(obj: simObj, name: "__nativeSuperdenseCoding", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 4 else { return JeffJSValue.undefined }
            let bit0 = Int(ctx.toInt32(args[0]) ?? 0)
            let bit1 = Int(ctx.toInt32(args[1]) ?? 0)
            let resolve = args[2]
            let reject  = args[3]

            let reqID = self.reserveRequestID()
            self.storedCallbacks[reqID] = resolve.dupValue()
            self.storedCallbacks[reqID + 1] = reject.dupValue()

            Task.detached {
                let result = QuantumAlgorithms.superdenseCoding(bit0: bit0, bit1: bit1)
                await MainActor.run { [weak self] in
                    guard let self, let ctx = self.ctx else { return }
                    self.deliverResult(reqID: reqID, ctx: ctx) { ctx in
                        let obj = ctx.newPlainObject()
                        _ = ctx.setPropertyStr(obj: obj, name: "success", value: .newBool(result.success))
                        let sent = ctx.newArray()
                        _ = ctx.setPropertyUint32(obj: sent, index: 0, value: JeffJSValue.newInt32(Int32(result.sent.0)))
                        _ = ctx.setPropertyUint32(obj: sent, index: 1, value: JeffJSValue.newInt32(Int32(result.sent.1)))
                        _ = ctx.setPropertyStr(obj: obj, name: "sent", value: sent)
                        let received = ctx.newArray()
                        _ = ctx.setPropertyUint32(obj: received, index: 0, value: JeffJSValue.newInt32(Int32(result.received.0)))
                        _ = ctx.setPropertyUint32(obj: received, index: 1, value: JeffJSValue.newInt32(Int32(result.received.1)))
                        _ = ctx.setPropertyStr(obj: obj, name: "received", value: received)
                        return obj
                    }
                }
            }
            return JeffJSValue.undefined
        }, length: 4)

        // __nativeErrorCorrection(errorQubit, resolve, reject)
        ctx.setPropertyFunc(obj: simObj, name: "__nativeErrorCorrection", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 3 else { return JeffJSValue.undefined }
            let errorQubit = Int(ctx.toInt32(args[0]) ?? 1)
            let resolve = args[1]
            let reject  = args[2]

            let reqID = self.reserveRequestID()
            self.storedCallbacks[reqID] = resolve.dupValue()
            self.storedCallbacks[reqID + 1] = reject.dupValue()

            Task.detached {
                let result = QuantumAlgorithms.errorCorrection(errorQubit: errorQubit)
                await MainActor.run { [weak self] in
                    guard let self, let ctx = self.ctx else { return }
                    self.deliverResult(reqID: reqID, ctx: ctx) { ctx in
                        let obj = ctx.newPlainObject()
                        _ = ctx.setPropertyStr(obj: obj, name: "corrected", value: .newBool(result.corrected))
                        _ = ctx.setPropertyStr(obj: obj, name: "errorQubit", value: JeffJSValue.newInt32(Int32(result.errorQubit)))
                        let syndrome = ctx.newArray()
                        _ = ctx.setPropertyUint32(obj: syndrome, index: 0, value: JeffJSValue.newInt32(Int32(result.syndrome.0)))
                        _ = ctx.setPropertyUint32(obj: syndrome, index: 1, value: JeffJSValue.newInt32(Int32(result.syndrome.1)))
                        _ = ctx.setPropertyStr(obj: obj, name: "syndrome", value: syndrome)
                        return obj
                    }
                }
            }
            return JeffJSValue.undefined
        }, length: 3)
    }

    // MARK: - Stabilizer Simulator (sync, scales to 1000+ qubits)

    private var stabilizers: [Int: StabilizerState] = [:]
    private var nextStabID: Int = 1

    private func registerStabilizer(on ctx: JeffJSContext, simObj: JeffJSValue) {

        // createStabilizer(numQubits) -> stabId
        ctx.setPropertyFunc(obj: simObj, name: "createStabilizer", fn: { [weak self] ctx, _, args in
            guard let self else { return JeffJSValue.newInt32(0) }
            let n = Int(ctx.toInt32(args.first ?? .undefined) ?? 4)
            let state = StabilizerState(numQubits: n)
            let id = self.nextStabID
            self.nextStabID += 1
            self.stabilizers[id] = state
            return JeffJSValue.newInt32(Int32(id))
        }, length: 1)

        // stabGate(stabId, gateName, argsObj) -> undefined
        ctx.setPropertyFunc(obj: simObj, name: "stabGate", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 2 else { return JeffJSValue.undefined }
            let id = Int(ctx.toInt32(args[0]) ?? 0)
            let name = ctx.toSwiftString(args[1]) ?? ""
            guard let state = self.stabilizers[id] else { return JeffJSValue.undefined }

            let gateArgs = args.count >= 3 ? args[2] : JeffJSValue.undefined
            let qubit = Int(ctx.toInt32(ctx.getPropertyStr(obj: gateArgs, name: "qubit")) ?? 0)

            switch name {
            case "h":    state.h(qubit)
            case "s":    state.s(qubit)
            case "x":    state.x(qubit)
            case "y":    state.y(qubit)
            case "z":    state.z(qubit)
            case "cnot":
                let control = Int(ctx.toInt32(ctx.getPropertyStr(obj: gateArgs, name: "control")) ?? 0)
                let target  = Int(ctx.toInt32(ctx.getPropertyStr(obj: gateArgs, name: "target")) ?? 1)
                state.cnot(control: control, target: target)
            default: break
            }

            return JeffJSValue.undefined
        }, length: 3)

        // stabMeasure(stabId, qubit) -> 0 or 1
        ctx.setPropertyFunc(obj: simObj, name: "stabMeasure", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 2 else { return JeffJSValue.newInt32(0) }
            let id = Int(ctx.toInt32(args[0]) ?? 0)
            let qubit = Int(ctx.toInt32(args[1]) ?? 0)
            guard let state = self.stabilizers[id] else { return JeffJSValue.newInt32(0) }
            var rng = SplitMix64(seed: UInt64(id) ^ 0xDEAD)
            let outcome = state.measure(qubit, rng: &rng)
            return JeffJSValue.newInt32(Int32(outcome))
        }, length: 2)

        // stabBellPair(stabId, q0, q1) -> undefined
        ctx.setPropertyFunc(obj: simObj, name: "stabBellPair", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 3 else { return JeffJSValue.undefined }
            let id = Int(ctx.toInt32(args[0]) ?? 0)
            let q0 = Int(ctx.toInt32(args[1]) ?? 0)
            let q1 = Int(ctx.toInt32(args[2]) ?? 1)
            guard let state = self.stabilizers[id] else { return JeffJSValue.undefined }
            state.bellPair(q0, q1)
            return JeffJSValue.undefined
        }, length: 3)

        // stabGHZ(stabId, qubitsArray) -> undefined
        ctx.setPropertyFunc(obj: simObj, name: "stabGHZ", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 2 else { return JeffJSValue.undefined }
            let id = Int(ctx.toInt32(args[0]) ?? 0)
            guard let state = self.stabilizers[id] else { return JeffJSValue.undefined }
            // Parse qubits array
            let arrVal = args[1]
            let lenVal = ctx.getPropertyStr(obj: arrVal, name: "length")
            let len = Int(ctx.toInt32(lenVal) ?? 0)
            lenVal.freeValue()
            var qubits = [Int]()
            for i in 0 ..< len {
                let v = ctx.getPropertyUint32(obj: arrVal, index: UInt32(i))
                defer { v.freeValue() }
                qubits.append(Int(ctx.toInt32(v) ?? 0))
            }
            if !qubits.isEmpty {
                state.ghz(qubits)
            }
            return JeffJSValue.undefined
        }, length: 2)

        // destroyStabilizer(stabId) -> undefined
        ctx.setPropertyFunc(obj: simObj, name: "destroyStabilizer", fn: { [weak self] ctx, _, args in
            guard let self, args.count >= 1 else { return JeffJSValue.undefined }
            let id = Int(ctx.toInt32(args[0]) ?? 0)
            self.stabilizers.removeValue(forKey: id)
            return JeffJSValue.undefined
        }, length: 1)
    }

    // MARK: - Bell / CHSH Tests (sync)

    private func registerBellTests(on ctx: JeffJSContext, simObj: JeffJSValue) {

        // chsh(variant, numTrials) -> { S, noSignaling }
        ctx.setPropertyFunc(obj: simObj, name: "chsh", fn: { ctx, _, args in
            let variantStr = ctx.toSwiftString(args.first ?? .undefined) ?? "boundQubitPair"
            let numTrials = Int(ctx.toInt32(args.count >= 2 ? args[1] : .undefined) ?? 10000)

            let variant = CHSHVariant(rawValue: variantStr) ?? .boundQubitPair
            let result = QuantumBellTests.runCHSH(variant: variant, numTrials: numTrials, seed: 0xC5C5)

            let obj = ctx.newPlainObject()
            _ = ctx.setPropertyStr(obj: obj, name: "S", value: JeffJSValue.newFloat64(Double(result.S)))
            _ = ctx.setPropertyStr(obj: obj, name: "noSignaling", value: .newBool(result.noSignaling))
            _ = ctx.setPropertyStr(obj: obj, name: "variant", value: ctx.newStringValue(result.variant.rawValue))
            _ = ctx.setPropertyStr(obj: obj, name: "numTrials", value: JeffJSValue.newInt32(Int32(result.numTrials)))
            return obj
        }, length: 2)

        // ghzCorrelation(n, anglesArray, numTrials) -> float
        ctx.setPropertyFunc(obj: simObj, name: "ghzCorrelation", fn: { ctx, _, args in
            guard args.count >= 3 else { return JeffJSValue.newFloat64(0) }
            let n = Int(ctx.toInt32(args[0]) ?? 3)
            let numTrials = Int(ctx.toInt32(args[2]) ?? 10000)

            // Parse angles array
            var angles = [Float](repeating: .pi / 2, count: n)
            if args[1].isObject {
                let lenVal = ctx.getPropertyStr(obj: args[1], name: "length")
                let len = Int(ctx.toInt32(lenVal) ?? 0)
                lenVal.freeValue()
                for i in 0 ..< min(len, n) {
                    let v = ctx.getPropertyUint32(obj: args[1], index: UInt32(i))
                    defer { v.freeValue() }
                    angles[i] = Float(ctx.toFloat64(v) ?? Double.pi / 2)
                }
            }

            let E = QuantumBellTests.ghzCorrelation(numQubits: n, angles: angles, numTrials: numTrials, seed: 0xA001)
            return JeffJSValue.newFloat64(Double(E))
        }, length: 3)
    }

    // MARK: - Promise Shims

    private func installAsyncShims(on ctx: JeffJSContext) {
        let shim = """
        (function () {
          var s = window.jeffjs.quantum.simulator;
          s.shorFactor = function (N) {
            return new Promise(function (resolve, reject) {
              s.__nativeShorFactor(Number(N), resolve, reject);
            });
          };
          s.deutschJozsa = function (nInput, oracleType, oracleBits) {
            return new Promise(function (resolve, reject) {
              s.__nativeDeutschJozsa(Number(nInput), String(oracleType), oracleBits || [], resolve, reject);
            });
          };
          s.bernsteinVazirani = function (secret) {
            return new Promise(function (resolve, reject) {
              s.__nativeBernsteinVazirani(String(secret), resolve, reject);
            });
          };
          s.teleport = function () {
            return new Promise(function (resolve, reject) {
              s.__nativeTeleport(resolve, reject);
            });
          };
          s.superdenseCoding = function (bit0, bit1) {
            return new Promise(function (resolve, reject) {
              s.__nativeSuperdenseCoding(Number(bit0), Number(bit1), resolve, reject);
            });
          };
          s.errorCorrection = function (errorQubit) {
            return new Promise(function (resolve, reject) {
              s.__nativeErrorCorrection(Number(errorQubit || 1), resolve, reject);
            });
          };
        })();
        """
        let result = ctx.eval(input: shim, filename: "<quantum-sim-async-shim>", evalFlags: JS_EVAL_TYPE_GLOBAL)
        result.freeValue()
    }

    // MARK: - Async Result Delivery (same pattern as JeffJSQuantumBridge)

    private func reserveRequestID() -> Int {
        let id = nextRequestID
        nextRequestID += 2
        return id
    }

    private func deliverResult(reqID: Int, ctx: JeffJSContext, builder: (JeffJSContext) -> JeffJSValue) {
        let resolve = storedCallbacks.removeValue(forKey: reqID)
        let reject  = storedCallbacks.removeValue(forKey: reqID + 1)
        defer {
            resolve?.freeValue()
            reject?.freeValue()
        }

        JeffJSGCObjectHeader.activeRuntime = ctx.rt

        if let resolve {
            let result = builder(ctx)
            let r = ctx.call(resolve, this: .undefined, args: [result])
            r.freeValue()
        }

        drainJobs(ctx: ctx)
    }

    private func drainJobs(ctx: JeffJSContext) {
        var drained = ctx.rt.executePendingJobs()
        var retries = 0
        while drained < 0 && ctx.rt.isJobPending() && retries < 10 {
            let exc = ctx.getException()
            exc.freeValue()
            drained = ctx.rt.executePendingJobs()
            retries += 1
        }
    }
}
