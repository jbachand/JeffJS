// QuantumDecoder.swift
// Decodes quantum master keys back into the original byte data.
//
// Given one or more master keys (and the seed offset used during encoding),
// traces each chain through the quantum field, collects slice values,
// and reassembles the original bit stream.

import Foundation

/// Decodes quantum-encoded master keys back to data.
final class QuantumDecoder {

    private let field = QuantumField()

    // MARK: - Public API

    /// Decode a single master key to a UTF-8 string.
    func decodeString(key: UInt32, messageLength: Int? = nil, seedOffset: Int = 0) -> String? {
        let data = decode(keys: [key], messageLength: messageLength, seedOffset: seedOffset)
        return String(bytes: data, encoding: .utf8)
    }

    /// Decode multiple master keys (chunked message) to a UTF-8 string.
    func decodeString(keys: [UInt32], messageLength: Int? = nil, seedOffset: Int = 0) -> String? {
        let data = decode(keys: keys, messageLength: messageLength, seedOffset: seedOffset)
        return String(bytes: data, encoding: .utf8)
    }

    /// Decode from an `QuantumEncodeResult`.
    func decode(result: QuantumEncodeResult) -> [UInt8] {
        decode(keys: result.keys, messageLength: result.messageLength, seedOffset: result.seedOffset)
    }

    /// Decode from an `QuantumEncodeResult` to string.
    func decodeString(result: QuantumEncodeResult) -> String? {
        String(bytes: decode(result: result), encoding: .utf8)
    }

    // MARK: - Core Decode

    /// Decode master keys to raw bytes.
    func decode(keys: [UInt32], messageLength: Int? = nil, seedOffset: Int = 0) -> [UInt8] {
        var allValues = [UInt32]()

        for (i, key) in keys.enumerated() {
            let chunkOffset = seedOffset + i * 100
            let baseSeed = QuantumConstants.baseSeed &+ UInt32(truncatingIfNeeded: chunkOffset) &* 0x7FFF_FFFF

            let maxVals = keys.count > 1 ? QuantumConstants.maxChainValues : nil
            let values = decodeSingle(key: key, baseSeed: baseSeed, maxValues: maxVals)
            allValues.append(contentsOf: values)
        }

        return sliceValuesToData(allValues, messageLength: messageLength)
    }

    // MARK: - Internals

    /// Decode a single chain, returning slice values.
    private func decodeSingle(key: UInt32, baseSeed: UInt32, maxValues: Int?) -> [UInt32] {
        let addr = QuantumAddress(packed: key)
        let payload = field.readPayload(at: addr, baseSeed: baseSeed)

        if QuantumBits.isEndMarker(payload) { return [] }

        var current = payload
        var values = [UInt32]()
        let limit = maxValues ?? 1000

        var lastSeedIdx = addr.seed

        for _ in 0 ..< limit {
            guard let slice = QuantumBits.sliceFromPayload(current) else { break }
            values.append(UInt32(slice))

            if let maxValues, values.count >= maxValues { break }

            let next = QuantumAddress(packed: current)
            let nextSeed = QuantumField.rngSeed(index: next.seed, base: baseSeed)
            let qs: [Qubit]
            if next.seed != lastSeedIdx {
                qs = field.qubits(forSeed: nextSeed)
                lastSeedIdx = next.seed
            } else {
                qs = field.qubits(forSeed: QuantumField.rngSeed(index: lastSeedIdx, base: baseSeed))
            }

            let nextPayload = field.readPayload(
                at: next,
                baseSeed: baseSeed
            )

            if QuantumBits.isEndMarker(nextPayload) { break }
            current = nextPayload
        }

        return values
    }

    /// Convert slice values back to bytes.
    private func sliceValuesToData(_ values: [UInt32], messageLength: Int?) -> [UInt8] {
        let db = QuantumConstants.dataBits

        // Flatten slice values to bits.
        var bits = [UInt8]()
        bits.reserveCapacity(values.count * db)
        for v in values {
            for shift in stride(from: db - 1, through: 0, by: -1) {
                bits.append(UInt8((v >> shift) & 1))
            }
        }

        // Group into bytes.
        var bytes = [UInt8]()
        for i in stride(from: 0, to: bits.count - 7, by: 8) {
            var byte: UInt8 = 0
            for j in 0 ..< 8 { byte = (byte << 1) | bits[i + j] }
            bytes.append(byte)
        }

        if let len = messageLength, bytes.count > len {
            bytes = Array(bytes.prefix(len))
        }
        return bytes
    }
}
