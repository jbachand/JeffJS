// QuantumGPU.swift
// Metal GPU interface for quantum search kernels.
//
// Wraps the three QuantumSearch.metal kernels behind a Swift API.
// Falls back gracefully when Metal is unavailable (tvOS Simulator, Linux, etc.).

#if canImport(Metal)
import Foundation
import Metal

/// GPU-accelerated search over the quantum field.
final class QuantumGPU {

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeSlice:        MTLComputePipelineState
    private let pipeExact:        MTLComputePipelineState
    private let pipeSearchTrace:  MTLComputePipelineState

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q   = dev.makeCommandQueue()
        else { return nil }

        // Load and compile the .metal source at runtime so Metal works in
        // pure SPM, not just Xcode app target consumers.
        guard let url = Bundle.module.url(forResource: "QuantumSearch", withExtension: "metal"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let lib = try? dev.makeLibrary(source: source, options: nil)
        else { return nil }

        guard let fnSlice = lib.makeFunction(name: "quantum_search_by_slice"),
              let fnExact = lib.makeFunction(name: "quantum_search_exact"),
              let fnST    = lib.makeFunction(name: "quantum_search_and_trace"),
              let psSlice = try? dev.makeComputePipelineState(function: fnSlice),
              let psExact = try? dev.makeComputePipelineState(function: fnExact),
              let psST    = try? dev.makeComputePipelineState(function: fnST)
        else { return nil }

        self.device = dev
        self.queue  = q
        self.pipeSlice       = psSlice
        self.pipeExact       = psExact
        self.pipeSearchTrace = psST
    }

    // MARK: - Buffer Helpers

    private func makeBuffer<T>(_ value: T) -> MTLBuffer? {
        var v = value
        return device.makeBuffer(bytes: &v, length: MemoryLayout<T>.size, options: .storageModeShared)
    }

    private func makeBuffer(bytes: UnsafeRawPointer, length: Int) -> MTLBuffer? {
        device.makeBuffer(bytes: bytes, length: length, options: .storageModeShared)
    }

    private func packQubits(_ qubits: [Qubit]) -> MTLBuffer? {
        let data = qubits.flatMap { [$0.x, $0.y, $0.speed, $0.radius, $0.phase] }
        return data.withUnsafeBufferPointer { ptr in
            device.makeBuffer(bytes: ptr.baseAddress!, length: ptr.count * MemoryLayout<Float>.size, options: .storageModeShared)
        }
    }

    // MARK: - Search by Slice

    /// Find positions whose payload popcount falls in `targetSlice`.
    func searchBySlice(
        qubits: [Qubit],
        targetSlice: UInt32,
        seedIndex: UInt32,
        requiredAddrSlice: Int32 = -1,
        maxResults: UInt32 = 100
    ) -> [QuantumAddress] {
        guard let qbuf = packQubits(qubits),
              let tbuf = makeBuffer(targetSlice),
              let dbuf = makeBuffer(requiredAddrSlice),
              let sbuf = makeBuffer(seedIndex),
              let mbuf = makeBuffer(maxResults)
        else { return [] }

        var zero: UInt32 = 0
        guard let cbuf = device.makeBuffer(bytes: &zero, length: 4, options: .storageModeShared),
              let rbuf = device.makeBuffer(length: 16 * Int(maxResults), options: .storageModeShared)
        else { return [] }

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder()
        else { return [] }

        enc.setComputePipelineState(pipeSlice)
        enc.setBuffer(qbuf, offset: 0, index: 0)
        enc.setBuffer(tbuf, offset: 0, index: 1)
        enc.setBuffer(dbuf, offset: 0, index: 2)
        enc.setBuffer(sbuf, offset: 0, index: 3)
        enc.setBuffer(cbuf, offset: 0, index: 4)
        enc.setBuffer(rbuf, offset: 0, index: 5)
        enc.setBuffer(mbuf, offset: 0, index: 6)

        let gridZ = Int(QuantumConstants.gridT * QuantumConstants.gridOffset)
        enc.dispatchThreads(
            MTLSize(width: Int(QuantumConstants.gridVX), height: Int(QuantumConstants.gridVY), depth: gridZ),
            threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 16)
        )
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        let count = min(cbuf.contents().load(as: UInt32.self), maxResults)
        let ptr = rbuf.contents().bindMemory(to: SIMD4<UInt32>.self, capacity: Int(count))

        return (0 ..< Int(count)).map { i in
            let v = ptr[i]
            return QuantumAddress(vx: v.x, vy: v.y, t: v.z, offset: v.w, seed: seedIndex)
        }
    }

    // MARK: - Search and Trace (combined single-pass)

    /// Search all positions in one seed and trace chains that match `targetValues`.
    /// Returns packed master keys.
    func searchAndTrace(
        allQubitsBuffer: MTLBuffer,
        targetValues: [UInt32],
        seedIndex: UInt32,
        maxMatches: UInt32 = 10
    ) -> [UInt32] {
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder()
        else { return [] }

        let targetData = targetValues.withUnsafeBufferPointer { ptr in
            device.makeBuffer(bytes: ptr.baseAddress!, length: ptr.count * 4, options: .storageModeShared)
        }
        guard let tBuf = targetData else { return [] }

        var tLen = UInt32(targetValues.count)
        var sid  = seedIndex
        var zero: UInt32 = 0
        var maxM = maxMatches

        guard let tLenBuf  = makeBuffer(tLen),
              let sidBuf   = makeBuffer(sid),
              let countBuf = device.makeBuffer(bytes: &zero, length: 4, options: .storageModeShared),
              let matchBuf = device.makeBuffer(length: 20 * Int(maxMatches), options: .storageModeShared),
              let maxBuf   = makeBuffer(maxM)
        else { return [] }

        enc.setComputePipelineState(pipeSearchTrace)
        enc.setBuffer(allQubitsBuffer, offset: 0, index: 0)
        enc.setBuffer(tBuf,            offset: 0, index: 1)
        enc.setBuffer(tLenBuf,         offset: 0, index: 2)
        enc.setBuffer(sidBuf,          offset: 0, index: 3)
        enc.setBuffer(countBuf,        offset: 0, index: 4)
        enc.setBuffer(matchBuf,        offset: 0, index: 5)
        enc.setBuffer(maxBuf,          offset: 0, index: 6)

        let gridZ = Int(QuantumConstants.gridT * QuantumConstants.gridOffset)
        enc.dispatchThreads(
            MTLSize(width: Int(QuantumConstants.gridVX), height: Int(QuantumConstants.gridVY), depth: gridZ),
            threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 16)
        )
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        let count = min(countBuf.contents().load(as: UInt32.self), maxMatches)
        let ptr = matchBuf.contents().bindMemory(to: UInt32.self, capacity: Int(count) * 5)

        return (0 ..< Int(count)).map { i in
            let vx  = ptr[i * 5 + 0]
            let vy  = ptr[i * 5 + 1]
            let t   = ptr[i * 5 + 2]
            let off = ptr[i * 5 + 3]
            let sid = ptr[i * 5 + 4]
            return QuantumAddress(vx: vx, vy: vy, t: t, offset: off, seed: sid).packed
        }
    }

    // MARK: - All-Seeds Qubit Buffer

    /// Build a single buffer containing all 32 seeds' qubit arrays for chain tracing.
    func makeAllQubitsBuffer(field: QuantumField, baseSeed: UInt32) -> MTLBuffer? {
        var allFloats = [Float]()
        allFloats.reserveCapacity(Int(QuantumConstants.gridSeed) * QuantumConstants.numQubits * 5)

        for seedIdx in 0 ..< QuantumConstants.gridSeed {
            let seed = QuantumField.rngSeed(index: seedIdx, base: baseSeed)
            let qs = field.qubits(forSeed: seed)
            for q in qs {
                allFloats.append(contentsOf: [q.x, q.y, q.speed, q.radius, q.phase])
            }
        }

        return allFloats.withUnsafeBufferPointer { ptr in
            device.makeBuffer(bytes: ptr.baseAddress!, length: ptr.count * MemoryLayout<Float>.size, options: .storageModeShared)
        }
    }
}

#endif // canImport(Metal)
