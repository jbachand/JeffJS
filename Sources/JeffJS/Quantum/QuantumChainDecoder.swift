// QuantumChainDecoder.swift
// Forward octree-walk decoder. Plays back a `QuantumChainKey` by starting
// at the deepest level (the master key itself) and truncating one bit per
// axis at each step until the observable level-1 cell is reached.
//
// At each level k (counting from N down to 1), the decoder:
//   1. Reads the cell-centered payload at the current `(vx, vy, t)` truncated
//      to k bits per axis.
//   2. Derives a single bit from the payload's popcount slice.
//   3. Appends that bit to the output (this is `b[N - k]` in playback order).
//   4. Right-shifts each axis by 1 to step out one octree level.
//
// The first bit produced is therefore `b[0]` (read at level N — highest
// resolution, master-key starting point), and the last bit produced is
// `b[N-1]` (read at level 1 — lowest resolution, "observable" cell).

import Foundation

/// Decodes a `QuantumChainKey` back into the original byte data.
///
/// Not actor-isolated: pure compute that owns its own field cache.
/// Create a fresh decoder per background task to keep cache access
/// thread-confined.
final class QuantumChainDecoder {

    private let field = QuantumChainField()
    private let encoder = QuantumChainEncoder()  // reused for cellBit() helper

    // MARK: - Public API

    /// Decode the key to a UTF-8 string.
    func decodeString(_ key: QuantumChainKey) -> String? {
        String(bytes: decode(key), encoding: .utf8)
    }

    /// Decode the key to raw bytes.
    func decode(_ key: QuantumChainKey) -> [UInt8] {
        let qubits = field.qubits(forSeed: key.seed)
        var bits = [UInt8]()
        bits.reserveCapacity(key.bitCount)

        var vx = key.vx
        var vy = key.vy
        var t  = key.t

        // Walk from level `bitCount` (deepest) down to level 1 (observable).
        // At each level, the truncated coordinates already have the right
        // number of bits because we shifted at the end of the previous step.
        for level in stride(from: key.bitCount, through: 1, by: -1) {
            let bit = encoder.cellBit(level: level, vx: vx, vy: vy, t: t, qubits: qubits)
            bits.append(bit)
            vx >>= 1
            vy >>= 1
            t  >>= 1
        }

        return bitsToBytes(bits, byteCount: key.messageLength)
    }

    // MARK: - Bit Conversion

    private func bitsToBytes(_ bits: [UInt8], byteCount: Int) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(byteCount)
        var i = 0
        while i + 7 < bits.count && bytes.count < byteCount {
            var byte: UInt8 = 0
            for j in 0 ..< 8 {
                byte = (byte << 1) | bits[i + j]
            }
            bytes.append(byte)
            i += 8
        }
        return bytes
    }
}
