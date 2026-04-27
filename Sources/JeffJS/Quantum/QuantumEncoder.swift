// QuantumEncoder.swift
// Encodes arbitrary data into quantum master keys.
//
// The encoder converts a byte sequence into a chain of popcount-slice values,
// then searches the quantum field (GPU or CPU) for a master key whose chain
// reproduces that exact value sequence. Long messages are split into chunks,
// each getting its own master key.

import Foundation

/// Result of a successful encode operation.
struct QuantumEncodeResult {
    /// One master key per chunk (single key for short messages).
    let keys: [UInt32]
    /// Original message length in bytes.
    let messageLength: Int
    /// Seed offset that produced the match.
    let seedOffset: Int
}

/// Encodes byte data into quantum master keys.
final class QuantumEncoder {

    private let field = QuantumField()
    #if canImport(Metal)
    private lazy var gpu = QuantumGPU()
    #endif

    // MARK: - Public API

    /// Encode a UTF-8 string. Returns `nil` if no chain is found after `maxAttempts`.
    func encode(_ message: String, maxAttempts: Int = 100) -> QuantumEncodeResult? {
        encode(Array(message.utf8), maxAttempts: maxAttempts)
    }

    /// Encode raw bytes. Returns `nil` if no chain is found after `maxAttempts`.
    func encode(_ data: [UInt8], maxAttempts: Int = 100) -> QuantumEncodeResult? {
        let values = dataToSliceValues(data)

        for attempt in 0 ..< maxAttempts {
            if let keys = encodeAttempt(values, baseSeedOffset: attempt) {
                return QuantumEncodeResult(keys: keys, messageLength: data.count, seedOffset: attempt)
            }
        }
        return nil
    }

    // MARK: - Internals

    /// Convert bytes to a sequence of slice values (DATA_BITS bits each).
    private func dataToSliceValues(_ data: [UInt8]) -> [UInt32] {
        // Flatten to a bit string.
        var bits = [UInt8]()
        bits.reserveCapacity(data.count * 8)
        for byte in data {
            for shift in stride(from: 7, through: 0, by: -1) {
                bits.append((byte >> shift) & 1)
            }
        }
        // Pad to a multiple of DATA_BITS.
        while bits.count % QuantumConstants.dataBits != 0 { bits.append(0) }

        // Group into slice values.
        let db = QuantumConstants.dataBits
        return stride(from: 0, to: bits.count, by: db).map { i in
            var v: UInt32 = 0
            for j in 0 ..< db { v = (v << 1) | UInt32(bits[i + j]) }
            return v
        }
    }

    /// One encoding attempt with a specific seed offset.
    /// Splits long messages into chunks of `maxChainValues`.
    private func encodeAttempt(_ values: [UInt32], baseSeedOffset: Int) -> [UInt32]? {
        let maxChain = QuantumConstants.maxChainValues
        let numChunks = (values.count + maxChain - 1) / maxChain

        var keys = [UInt32]()
        keys.reserveCapacity(numChunks)

        for i in 0 ..< numChunks {
            let start = i * maxChain
            let end   = min(start + maxChain, values.count)
            let chunk = Array(values[start ..< end])
            let chunkOffset = baseSeedOffset + i * 100

            guard let key = searchForChain(chunk, seedOffset: chunkOffset) else { return nil }
            keys.append(key)
        }
        return keys
    }

    /// Search for a master key that produces the desired chain of values.
    /// Tries GPU first, then CPU exhaustive search.
    private func searchForChain(_ targetValues: [UInt32], seedOffset: Int) -> UInt32? {
        let baseSeed = QuantumConstants.baseSeed &+ UInt32(truncatingIfNeeded: seedOffset) &* 0x7FFF_FFFF

        #if canImport(Metal)
        if let g = gpu {
            if let key = gpuSearch(g, targetValues: targetValues, baseSeed: baseSeed) {
                return key
            }
        }
        #endif

        return cpuExhaustiveSearch(targetValues, baseSeed: baseSeed)
    }

    // MARK: - GPU Search

    #if canImport(Metal)
    private func gpuSearch(_ gpu: QuantumGPU, targetValues: [UInt32], baseSeed: UInt32) -> UInt32? {
        guard let qbuf = gpu.makeAllQubitsBuffer(field: field, baseSeed: baseSeed) else { return nil }

        for seedIdx in 0 ..< QuantumConstants.gridSeed {
            let matches = gpu.searchAndTrace(
                allQubitsBuffer: qbuf,
                targetValues: targetValues,
                seedIndex: seedIdx,
                maxMatches: 1
            )
            if let key = matches.first { return key }
        }
        return nil
    }
    #endif

    // MARK: - CPU Fallback

    private func cpuExhaustiveSearch(_ targetValues: [UInt32], baseSeed: UInt32) -> UInt32? {
        let targetLen = targetValues.count
        // Limit CPU search to first 4 seeds for reasonable performance.
        let seedLimit = min(4, QuantumConstants.gridSeed)

        for seedIdx: UInt32 in 0 ..< seedLimit {
            for t: UInt32 in 0 ..< QuantumConstants.gridT {
                for vy: UInt32 in 0 ..< QuantumConstants.gridVY {
                    for vx: UInt32 in 0 ..< QuantumConstants.gridVX {
                        for offset: UInt32 in 0 ..< QuantumConstants.gridOffset {
                            let addr = QuantumAddress(vx: vx, vy: vy, t: t, offset: offset, seed: seedIdx)
                            let (values, _, _) = traceChain(masterKey: addr.packed, baseSeed: baseSeed, maxLength: targetLen + 2)

                            if values.count >= targetLen && Array(values.prefix(targetLen)) == targetValues {
                                return addr.packed
                            }
                        }
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Chain Tracing

    /// Trace a chain from a master key and collect data values.
    /// Returns (values, payloads, endedNaturally).
    func traceChain(
        masterKey: UInt32,
        baseSeed: UInt32 = QuantumConstants.baseSeed,
        maxLength: Int = 100
    ) -> (values: [UInt32], payloads: [UInt32], ended: Bool) {
        let addr = QuantumAddress(packed: masterKey)
        let seed = QuantumField.rngSeed(index: addr.seed, base: baseSeed)
        let qs   = field.qubits(forSeed: seed)

        let bits = field.readBits(qubits: qs, vx: Float(addr.vx), vy: Float(addr.vy),
                                  t: Float(addr.t) * QuantumConstants.tScale,
                                  offset: Int(addr.offset), nBits: QuantumConstants.totalBits)
        var payload: UInt32 = 0
        for b in bits { payload = (payload << 1) | UInt32(b) }

        if QuantumBits.isEndMarker(payload) {
            return ([], [payload], true)
        }

        var current = payload
        var values   = [UInt32]()
        var payloads = [UInt32]()
        payloads.append(payload)

        var lastSeedIdx = addr.seed

        for _ in 0 ..< maxLength {
            guard let slice = QuantumBits.sliceFromPayload(current) else {
                return (values, payloads, false)
            }
            values.append(UInt32(slice))

            let next = QuantumAddress(packed: current)

            // Read next payload (re-use cached qubits if seed unchanged).
            let nextSeed = QuantumField.rngSeed(index: next.seed, base: baseSeed)
            let nextQs: [Qubit]
            if next.seed != lastSeedIdx {
                nextQs = field.qubits(forSeed: nextSeed)
                lastSeedIdx = next.seed
            } else {
                nextQs = field.qubits(forSeed: QuantumField.rngSeed(index: lastSeedIdx, base: baseSeed))
            }

            let nextBits = field.readBits(qubits: nextQs, vx: Float(next.vx), vy: Float(next.vy),
                                          t: Float(next.t) * QuantumConstants.tScale,
                                          offset: Int(next.offset), nBits: QuantumConstants.totalBits)
            payload = 0
            for b in nextBits { payload = (payload << 1) | UInt32(b) }
            payloads.append(payload)

            if QuantumBits.isEndMarker(payload) {
                return (values, payloads, true)
            }
            current = payload
        }

        return (values, payloads, false)
    }
}
