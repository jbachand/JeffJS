// QuantumCircuit.swift
// High-level circuit API for the JeffJS quantum simulator.
//
// QuantumCircuit wraps a QuantumState and provides a gate-by-gate interface.
// Each gate method dispatches to the CPU-side QuantumState operations.
// GPU acceleration (via QuantumSimulatorGPU) is wired in later through
// conditional Metal imports; the hooks are already in place.
//
// Uses the project-wide SplitMix64 PRNG from QuantumQubit.swift.

import Foundation
#if canImport(Metal)
import Metal
#endif

// MARK: - QuantumGate

/// Describes a single gate operation applied to one or two qubits.
enum QuantumGate {
    case h(Int)
    case x(Int)
    case y(Int)
    case z(Int)
    case s(Int)
    case t(Int)
    case tDagger(Int)
    case cnot(control: Int, target: Int)
    case phase(qubit: Int, angle: Float)
    case controlledModMult(control: Int, workOffset: Int, nWork: Int, a: UInt32, N: UInt32)
}

// MARK: - QuantumCircuit

/// A quantum circuit that accumulates gates and measurements against an
/// N-qubit state vector.
///
/// NOT `@MainActor` — computation runs off the main thread via Task.
/// Only the bridge (QuantumSimulatorBridge) is actor-confined.

final class QuantumCircuit {

    // MARK: Public state

    let numQubits: Int
    let state: QuantumState
    private(set) var measurements: [(qubit: Int, outcome: Int)] = []

    /// Read-only access to the raw amplitude vector.
    var stateVector: [Complex64] { state.amplitudes }

    // MARK: Private

    private var rng: SplitMix64

    /// Release all memory (state vector + GPU buffers). Call when done.
    func deallocate() {
        state.amplitudes = []
        #if canImport(Metal)
        gpuBufferA = nil
        gpuBufferB = nil
        gpu = nil
        isOnGPU = false
        #endif
    }

    // MARK: GPU integration hooks

    #if canImport(Metal)
    private var gpu: QuantumSimulatorGPU?
    private var gpuBufferA: MTLBuffer?
    private var gpuBufferB: MTLBuffer?
    private var isOnGPU: Bool = false

    /// Dimensions at or above this threshold trigger GPU dispatch (when a GPU
    /// backend is available). Below this the CPU path is faster due to buffer
    /// copy overhead.
    static let gpuThreshold = 1 << 18  // 262K+ amplitudes (18+ qubits) for GPU to win
    #endif

    // MARK: Init

    /// Create a circuit with `numQubits` qubits, all initialised to |0>.
    /// The PRNG is seeded deterministically so results are reproducible.
    init(numQubits: Int, seed: UInt64 = 0) {
        self.numQubits = numQubits
        self.state = QuantumState(numQubits: numQubits)
        self.rng = SplitMix64(seed: seed)

        #if canImport(Metal)
        if state.dimension >= Self.gpuThreshold, let g = QuantumSimulatorGPU.shared {
            self.gpu = g
            self.gpuBufferA = g.uploadState(state)
            self.gpuBufferB = g.makeStateBuffer(dimension: state.dimension)
            if gpuBufferA != nil && gpuBufferB != nil {
                self.isOnGPU = true
            }
        }
        #endif
    }

    // MARK: - GPU Helpers

    #if canImport(Metal)
    /// Swap GPU double-buffers (A→B becomes B→A).
    private func swapGPUBuffers() {
        let tmp = gpuBufferA
        gpuBufferA = gpuBufferB
        gpuBufferB = tmp
    }

    /// Read GPU buffer contents into CPU state array.
    /// On Apple Silicon (shared memory), this is just pointer reads — no DMA copy.
    private func syncFromGPU() {
        guard isOnGPU, let buf = gpuBufferA else { return }
        let ptr = buf.contents().bindMemory(to: Complex64.self, capacity: state.dimension)
        for i in 0 ..< state.dimension {
            state.amplitudes[i] = ptr[i]
        }
        isOnGPU = false
    }

    /// Write CPU state array back to the EXISTING GPU buffer.
    /// No new buffer allocation — reuses the shared memory buffer.
    private func syncToGPU() {
        guard let buf = gpuBufferA else { return }
        let ptr = buf.contents().bindMemory(to: Complex64.self, capacity: state.dimension)
        for i in 0 ..< state.dimension {
            ptr[i] = state.amplitudes[i]
        }
        isOnGPU = true
    }
    #endif

    // MARK: - Single-Qubit Gates

    /// Hadamard gate on qubit `q`.
    func h(_ qubit: Int) {
        #if canImport(Metal)
        if isOnGPU, let gpu, let bufIn = gpuBufferA, let bufOut = gpuBufferB {
            gpu.hadamard(stateIn: bufIn, stateOut: bufOut, qubit: UInt32(qubit), dim: state.dimension)
            swapGPUBuffers()
            return
        }
        #endif
        state.applyHadamard(qubit: qubit)
    }

    /// Pauli-X (NOT) gate.
    func x(_ qubit: Int) {
        #if canImport(Metal)
        if isOnGPU, let gpu, let buf = gpuBufferA {
            gpu.pauliX(state: buf, qubit: UInt32(qubit), dim: state.dimension)
            return
        }
        #endif
        state.applyPauliX(qubit: qubit)
    }

    /// Pauli-Y gate.
    func y(_ qubit: Int) {
        state.applyPauliY(qubit: qubit)
    }

    /// Pauli-Z gate.
    func z(_ qubit: Int) {
        #if canImport(Metal)
        if isOnGPU, let gpu, let buf = gpuBufferA {
            gpu.phaseGate(state: buf, qubit: UInt32(qubit), angle: .pi, dim: state.dimension)
            return
        }
        #endif
        state.applyPauliZ(qubit: qubit)
    }

    /// S gate (phase pi/2).
    func s(_ qubit: Int) {
        #if canImport(Metal)
        if isOnGPU, let gpu, let buf = gpuBufferA {
            gpu.phaseGate(state: buf, qubit: UInt32(qubit), angle: .pi / 2, dim: state.dimension)
            return
        }
        #endif
        state.applyS(qubit: qubit)
    }

    /// T gate (phase pi/4).
    func t(_ qubit: Int) {
        #if canImport(Metal)
        if isOnGPU, let gpu, let buf = gpuBufferA {
            gpu.phaseGate(state: buf, qubit: UInt32(qubit), angle: .pi / 4, dim: state.dimension)
            return
        }
        #endif
        state.applyT(qubit: qubit)
    }

    /// T-dagger gate (phase -pi/4).
    func tDagger(_ qubit: Int) {
        #if canImport(Metal)
        if isOnGPU, let gpu, let buf = gpuBufferA {
            gpu.phaseGate(state: buf, qubit: UInt32(qubit), angle: -.pi / 4, dim: state.dimension)
            return
        }
        #endif
        state.applyTDagger(qubit: qubit)
    }

    /// Arbitrary phase rotation on a single qubit.
    func phase(_ qubit: Int, angle: Float) {
        #if canImport(Metal)
        if isOnGPU, let gpu, let buf = gpuBufferA {
            gpu.phaseGate(state: buf, qubit: UInt32(qubit), angle: angle, dim: state.dimension)
            return
        }
        #endif
        state.applyPhase(qubit: qubit, angle: angle)
    }

    // MARK: - Two-Qubit Gates

    /// CNOT (controlled-X) gate.
    func cnot(control: Int, target: Int) {
        #if canImport(Metal)
        if isOnGPU, let gpu, let bufIn = gpuBufferA, let bufOut = gpuBufferB {
            gpu.cnot(stateIn: bufIn, stateOut: bufOut, control: UInt32(control), target: UInt32(target), dim: state.dimension)
            swapGPUBuffers()
            return
        }
        #endif
        state.applyCNOT(control: control, target: target)
    }

    // MARK: - Multi-Qubit Gates

    /// Controlled modular multiplication for Shor's algorithm.
    func controlledModMult(control: Int, workOffset: Int, nWork: Int, a: UInt32, N: UInt32) {
        #if canImport(Metal)
        if isOnGPU, let gpu, let bufIn = gpuBufferA, let bufOut = gpuBufferB {
            gpu.controlledModMult(
                stateIn: bufIn, stateOut: bufOut,
                control: UInt32(control), workOffset: UInt32(workOffset),
                nWork: UInt32(nWork), a: a, N: N, dim: state.dimension
            )
            swapGPUBuffers()
            return
        }
        #endif
        state.applyControlledModMult(
            control: control,
            workOffset: workOffset,
            nWork: nWork,
            a: a,
            N: N
        )
    }

    // MARK: - Generic Gate Application

    /// Apply a `QuantumGate` value. Useful when replaying a recorded circuit.
    func apply(_ gate: QuantumGate) {
        switch gate {
        case .h(let q):                         h(q)
        case .x(let q):                         x(q)
        case .y(let q):                         y(q)
        case .z(let q):                         z(q)
        case .s(let q):                         s(q)
        case .t(let q):                         t(q)
        case .tDagger(let q):                   tDagger(q)
        case .cnot(let c, let t):               cnot(control: c, target: t)
        case .phase(let q, let a):              phase(q, angle: a)
        case .controlledModMult(let c, let w, let n, let a, let N):
            controlledModMult(control: c, workOffset: w, nWork: n, a: a, N: N)
        }
    }

    // MARK: - Measurement

    /// Measure a single qubit, collapsing the state. Returns 0 or 1.
    /// When on GPU: probability + collapse + renormalize all run on GPU.
    /// Only one float (the probability) comes back to CPU.
    @discardableResult
    func measure(_ qubit: Int) -> Int {
        #if canImport(Metal)
        if isOnGPU, let gpu, let buf = gpuBufferA {
            let outcome = gpu.measureOnGPU(state: buf, qubit: UInt32(qubit),
                                           dim: state.dimension, rng: &rng)
            measurements.append((qubit: qubit, outcome: outcome))
            return outcome
        }
        #endif
        let outcome = state.measure(qubit: qubit, rng: &rng)
        measurements.append((qubit: qubit, outcome: outcome))
        return outcome
    }

    /// Measure all qubits from 0 to numQubits-1. Returns an array of outcomes.
    func measureAll() -> [Int] {
        var results = [Int]()
        results.reserveCapacity(numQubits)
        for q in 0 ..< numQubits {
            results.append(measure(q))
        }
        return results
    }
}
