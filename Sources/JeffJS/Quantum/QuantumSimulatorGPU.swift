// QuantumSimulatorGPU.swift
// Metal GPU interface for quantum gate simulation kernels.
//
// Wraps the six QuantumSimulator.metal kernels behind a Swift API.
// Falls back gracefully when Metal is unavailable (tvOS Simulator, Linux, etc.).

#if canImport(Metal)
import Foundation
import Metal

// QuantumState is defined in QuantumState.swift (Complex64-based state vector).
// This file provides the Metal GPU acceleration layer for QuantumState operations.

// MARK: - QuantumSimulatorGPU

/// GPU-accelerated quantum gate operations using Metal compute kernels.
/// Singleton: the shader is compiled ONCE and reused across all circuits.
final class QuantumSimulatorGPU {

    /// Shared instance — avoids recompiling Metal shaders per circuit.
    static let shared: QuantumSimulatorGPU? = QuantumSimulatorGPU()

    let device: MTLDevice
    private let queue: MTLCommandQueue

    // Pipeline states for each kernel
    private let pipeHadamard:    MTLComputePipelineState
    private let pipePauliX:      MTLComputePipelineState
    private let pipeCNOT:        MTLComputePipelineState
    private let pipeModMult:     MTLComputePipelineState
    private let pipePhase:       MTLComputePipelineState
    private let pipeMeasureProb: MTLComputePipelineState

    private init?() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q   = dev.makeCommandQueue()
        else { return nil }

        // Try pre-compiled metallib first (SPM compiles .metal → .metallib),
        // then fall back to runtime source compilation.
        let lib: MTLLibrary
        if let compiled = try? dev.makeDefaultLibrary(bundle: Bundle.module) {
            lib = compiled
        } else if let url = Bundle.module.url(forResource: "QuantumSimulator", withExtension: "metal"),
                  let source = try? String(contentsOf: url, encoding: .utf8),
                  let fallback = try? dev.makeLibrary(source: source, options: nil) {
            lib = fallback
        } else {
            return nil
        }

        guard let fnHadamard    = lib.makeFunction(name: "quantum_hadamard"),
              let fnPauliX      = lib.makeFunction(name: "quantum_pauli_x"),
              let fnCNOT        = lib.makeFunction(name: "quantum_cnot"),
              let fnModMult     = lib.makeFunction(name: "quantum_controlled_mod_mult"),
              let fnPhase       = lib.makeFunction(name: "quantum_phase_gate"),
              let fnMeasureProb = lib.makeFunction(name: "quantum_measure_prob"),
              let psHadamard    = try? dev.makeComputePipelineState(function: fnHadamard),
              let psPauliX      = try? dev.makeComputePipelineState(function: fnPauliX),
              let psCNOT        = try? dev.makeComputePipelineState(function: fnCNOT),
              let psModMult     = try? dev.makeComputePipelineState(function: fnModMult),
              let psPhase       = try? dev.makeComputePipelineState(function: fnPhase),
              let psMeasureProb = try? dev.makeComputePipelineState(function: fnMeasureProb),
              let fnCollapse    = lib.makeFunction(name: "quantum_collapse_and_normalize"),
              let psCollapse    = try? dev.makeComputePipelineState(function: fnCollapse)
        else { return nil }

        self.device          = dev
        self.queue           = q
        self.pipeHadamard    = psHadamard
        self.pipePauliX      = psPauliX
        self.pipeCNOT        = psCNOT
        self.pipeModMult     = psModMult
        self.pipePhase       = psPhase
        self.pipeMeasureProb = psMeasureProb
        self.pipeCollapse    = psCollapse
    }

    private let pipeCollapse: MTLComputePipelineState

    /// Measure a qubit entirely on GPU: compute probability via reduction,
    /// then collapse + renormalize in one dispatch. Returns the outcome (0 or 1).
    /// Only ONE float is read back to CPU — the state vector stays on GPU.
    func measureOnGPU(state: MTLBuffer, qubit: UInt32, dim: Int, rng: inout SplitMix64) -> Int {
        // Step 1: compute P(0) via the reduction kernel
        let p0 = measureProbability(state: state, qubit: qubit, dim: dim)

        // Step 2: sample outcome on CPU (one random number)
        let r = rng.nextFloat()
        let outcome: UInt32 = r < p0 ? 0 : 1
        let prob = outcome == 0 ? p0 : (1.0 - p0)
        let invNorm = 1.0 / sqrtf(max(prob, 1e-15))

        // Step 3: collapse + renormalize on GPU (one dispatch, zero CPU-side array work)
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder(),
              let qBuf = makeUintBuffer(qubit),
              let oBuf = makeUintBuffer(outcome),
              let nBuf = makeFloatBuffer(invNorm)
        else { return Int(outcome) }

        let (grid, group) = threadConfig(dim: dim)
        enc.setComputePipelineState(pipeCollapse)
        enc.setBuffer(state, offset: 0, index: 0)
        enc.setBuffer(qBuf, offset: 0, index: 1)
        enc.setBuffer(oBuf, offset: 0, index: 2)
        enc.setBuffer(nBuf, offset: 0, index: 3)
        enc.dispatchThreads(grid, threadsPerThreadgroup: group)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        return Int(outcome)
    }

    // MARK: - Buffer Helpers

    private func makeUintBuffer(_ value: UInt32) -> MTLBuffer? {
        var v = value
        return device.makeBuffer(bytes: &v, length: MemoryLayout<UInt32>.size, options: .storageModeShared)
    }

    private func makeFloatBuffer(_ value: Float) -> MTLBuffer? {
        var v = value
        return device.makeBuffer(bytes: &v, length: MemoryLayout<Float>.size, options: .storageModeShared)
    }

    // MARK: - Buffer Management

    /// Create an uninitialized state buffer for `dimension` complex amplitudes.
    func makeStateBuffer(dimension: Int) -> MTLBuffer? {
        // Each complex amplitude is a float2 = 8 bytes
        device.makeBuffer(length: dimension * MemoryLayout<Float>.size * 2, options: .storageModeShared)
    }

    /// Upload a QuantumState into a Metal buffer.
    /// Complex64 is (Float, Float) = 8 bytes per entry, matching float2 in Metal.
    func uploadState(_ state: QuantumState) -> MTLBuffer? {
        let dim = state.dimension
        let byteCount = dim * MemoryLayout<Complex64>.size
        // Complex64 is two Floats laid out contiguously, matching Metal's float2.
        return state.amplitudes.withUnsafeBufferPointer { ptr in
            device.makeBuffer(bytes: ptr.baseAddress!, length: byteCount, options: .storageModeShared)
        }
    }

    /// Download a Metal buffer into a QuantumState.
    func downloadState(from buffer: MTLBuffer, numQubits: Int) -> QuantumState {
        let dim = 1 << numQubits
        let ptr = buffer.contents().bindMemory(to: Complex64.self, capacity: dim)
        let state = QuantumState(numQubits: numQubits)
        for i in 0 ..< dim {
            state.amplitudes[i] = ptr[i]
        }
        return state
    }

    // MARK: - Thread Configuration

    private func threadConfig(dim: Int) -> (grid: MTLSize, group: MTLSize) {
        let grid  = MTLSize(width: dim, height: 1, depth: 1)
        let group = MTLSize(width: min(256, dim), height: 1, depth: 1)
        return (grid, group)
    }

    // MARK: - Gate Dispatch: Hadamard (double-buffered)

    func hadamard(stateIn: MTLBuffer, stateOut: MTLBuffer, qubit: UInt32, dim: Int) {
        guard let qubitBuf = makeUintBuffer(qubit),
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder()
        else { return }

        let (grid, group) = threadConfig(dim: dim)

        enc.setComputePipelineState(pipeHadamard)
        enc.setBuffer(stateIn,  offset: 0, index: 0)
        enc.setBuffer(stateOut, offset: 0, index: 1)
        enc.setBuffer(qubitBuf, offset: 0, index: 2)
        enc.dispatchThreads(grid, threadsPerThreadgroup: group)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    // MARK: - Gate Dispatch: Pauli-X (in-place)

    func pauliX(state: MTLBuffer, qubit: UInt32, dim: Int) {
        guard let qubitBuf = makeUintBuffer(qubit),
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder()
        else { return }

        let (grid, group) = threadConfig(dim: dim)

        enc.setComputePipelineState(pipePauliX)
        enc.setBuffer(state,    offset: 0, index: 0)
        enc.setBuffer(qubitBuf, offset: 0, index: 1)
        enc.dispatchThreads(grid, threadsPerThreadgroup: group)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    // MARK: - Gate Dispatch: CNOT (double-buffered)

    func cnot(stateIn: MTLBuffer, stateOut: MTLBuffer, control: UInt32, target: UInt32, dim: Int) {
        guard let ctrlBuf = makeUintBuffer(control),
              let tgtBuf  = makeUintBuffer(target),
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder()
        else { return }

        let (grid, group) = threadConfig(dim: dim)

        enc.setComputePipelineState(pipeCNOT)
        enc.setBuffer(stateIn,  offset: 0, index: 0)
        enc.setBuffer(stateOut, offset: 0, index: 1)
        enc.setBuffer(ctrlBuf,  offset: 0, index: 2)
        enc.setBuffer(tgtBuf,   offset: 0, index: 3)
        enc.dispatchThreads(grid, threadsPerThreadgroup: group)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    // MARK: - Gate Dispatch: Controlled Modular Multiplication (double-buffered)

    func controlledModMult(stateIn: MTLBuffer, stateOut: MTLBuffer,
                           control: UInt32, workOffset: UInt32, nWork: UInt32,
                           a: UInt32, N: UInt32, dim: Int) {
        guard let ctrlBuf   = makeUintBuffer(control),
              let offsetBuf = makeUintBuffer(workOffset),
              let nWorkBuf  = makeUintBuffer(nWork),
              let aBuf      = makeUintBuffer(a),
              let nBuf      = makeUintBuffer(N),
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder()
        else { return }

        let (grid, group) = threadConfig(dim: dim)

        enc.setComputePipelineState(pipeModMult)
        enc.setBuffer(stateIn,   offset: 0, index: 0)
        enc.setBuffer(stateOut,  offset: 0, index: 1)
        enc.setBuffer(ctrlBuf,   offset: 0, index: 2)
        enc.setBuffer(offsetBuf, offset: 0, index: 3)
        enc.setBuffer(nWorkBuf,  offset: 0, index: 4)
        enc.setBuffer(aBuf,      offset: 0, index: 5)
        enc.setBuffer(nBuf,      offset: 0, index: 6)
        enc.dispatchThreads(grid, threadsPerThreadgroup: group)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    // MARK: - Gate Dispatch: Phase Gate (in-place)

    func phaseGate(state: MTLBuffer, qubit: UInt32, angle: Float, dim: Int) {
        guard let qubitBuf = makeUintBuffer(qubit),
              let angleBuf = makeFloatBuffer(angle),
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder()
        else { return }

        let (grid, group) = threadConfig(dim: dim)

        enc.setComputePipelineState(pipePhase)
        enc.setBuffer(state,    offset: 0, index: 0)
        enc.setBuffer(qubitBuf, offset: 0, index: 1)
        enc.setBuffer(angleBuf, offset: 0, index: 2)
        enc.dispatchThreads(grid, threadsPerThreadgroup: group)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    // MARK: - Gate Dispatch: Measure Probability (reduction)

    /// Returns the probability that the given qubit measures |0>.
    /// Dispatches a threadgroup reduction kernel, then sums partial results on CPU.
    func measureProbability(state: MTLBuffer, qubit: UInt32, dim: Int) -> Float {
        let groupSize = min(256, dim)
        let numGroups = (dim + groupSize - 1) / groupSize

        guard let qubitBuf = makeUintBuffer(qubit),
              let partialBuf = device.makeBuffer(length: numGroups * MemoryLayout<Float>.size,
                                                 options: .storageModeShared),
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder()
        else { return 0.0 }

        let grid  = MTLSize(width: dim, height: 1, depth: 1)
        let group = MTLSize(width: groupSize, height: 1, depth: 1)

        enc.setComputePipelineState(pipeMeasureProb)
        enc.setBuffer(state,      offset: 0, index: 0)
        enc.setBuffer(qubitBuf,   offset: 0, index: 1)
        enc.setBuffer(partialBuf, offset: 0, index: 2)
        enc.dispatchThreads(grid, threadsPerThreadgroup: group)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        // Sum partial results on CPU
        let ptr = partialBuf.contents().bindMemory(to: Float.self, capacity: numGroups)
        var total: Float = 0.0
        for i in 0 ..< numGroups {
            total += ptr[i]
        }
        return total
    }
}

#endif // canImport(Metal)
