// QuantumChainEncoder.swift
// Backward octree-search encoder that produces a single master key.
//
// Algorithm
// ---------
// Given an N-bit message `b[0]…b[N-1]`:
//
//   1. Encode `b[N-1]` (the LAST bit) at level 1 (the OBSERVABLE end):
//      try all 8 candidate level-1 cells (vx, vy, t each ∈ {0, 1}); pick
//      one whose payload-popcount-slice equals `b[N-1]`.
//
//   2. Encode `b[N-2]` at level 2 by extending the chosen cell with one more
//      bit per axis (8 children): pick a child whose payload matches `b[N-2]`.
//
//   3. Continue until `b[0]` is encoded at level N. The final cell —
//      a tuple of N-bit `(vx, vy, t)` — IS the master key.
//
// At every level, the actual sample position is the *cell center*:
//
//     fvx = (vx_int + 0.5) / 2^level × FIELD_SIZE
//
// Cell-centered mapping is critical: parent cells and child cells are *not*
// at the same fractional position, so consecutive levels read genuinely
// different qubit windows.
//
// Decoding (in `QuantumChainDecoder`) walks the chain in the opposite
// direction: start at the master key (level N, deepest), read its bit, shift
// each axis right by 1, repeat until level 1 is reached. This recovers the
// bits in playback order: `b[0]` first, `b[N-1]` last.
//
// Backtracking
// ------------
// At each level, if no child cell matches the target bit, the recursion
// returns false and the parent tries a different combination. If the entire
// search exhausts under one seed, we retry with the next seed in
// `QuantumConstants.gridSeed`.
//
// Precision
// ---------
// Cell width at level k is `FIELD_SIZE / 2^k`. With Double precision and a
// 32-unit field, the floor is around level 52. We cap at `maxBits = 48` for
// safety headroom — that's 48 message bits ≈ 6 ASCII chars per single key.

import Foundation

/// Errors raised by the chain encoder.
enum QuantumChainError: Error, CustomStringConvertible {
    case messageTooLong(bits: Int, max: Int)
    case noChainFound

    var description: String {
        switch self {
        case .messageTooLong(let bits, let max):
            return "Message too long: \(bits) bits exceeds chain encoder limit of \(max) bits"
        case .noChainFound:
            return "No chain found within seed/backtrack budget"
        }
    }
}

/// Encodes byte data into a single `QuantumChainKey` via backward octree
/// search with progressively-deepening resolution.
///
/// Not actor-isolated: instances are pure compute and own their own
/// `QuantumChainField` cache. Create a fresh encoder per background task
/// to avoid sharing the cache across threads.
final class QuantumChainEncoder {

    private let field = QuantumChainField()

    /// Maximum message bits the chain encoder will attempt. Limited by Double
    /// precision: at level k, cell width is `fieldSize / 2^k`, and at level
    /// ~52 the cells become smaller than the field's representable spacing.
    static let maxBits = 48

    /// Maximum backtrack node visits per seed before giving up and trying
    /// the next seed. Caps worst-case latency from multi-minute hangs to
    /// sub-second seed rotation. Tuned so 32 seeds × budget ≈ 10s worst case.
    static let backtrackBudget = 5_000

    /// Tracks remaining budget for the current seed attempt.
    private var budget = 0

    /// Encode a UTF-8 string. Returns `nil` if the message is too long or no
    /// chain is found within the seed/backtrack budget.
    func encode(_ message: String) -> QuantumChainKey? {
        encode(Array(message.utf8))
    }

    /// Encode raw bytes.
    func encode(_ data: [UInt8]) -> QuantumChainKey? {
        let bits = bytesToBits(data)
        guard bits.count <= Self.maxBits else { return nil }
        guard !bits.isEmpty else { return nil }

        // Try every seed until one yields a complete chain (within its
        // backtrack budget).
        for seedTry in 0 ..< Int(QuantumConstants.gridSeed) {
            let seed = UInt32(seedTry)
            let qubits = field.qubits(forSeed: seed)

            var vx: UInt64 = 0
            var vy: UInt64 = 0
            var t:  UInt64 = 0
            budget = Self.backtrackBudget

            if backtrack(bits: bits, level: 1, qubits: qubits, vx: &vx, vy: &vy, t: &t) {
                return QuantumChainKey(
                    bitCount: bits.count,
                    messageLength: data.count,
                    seed: seed,
                    vx: vx, vy: vy, t: t
                )
            }
        }
        return nil
    }

    // MARK: - Bit Conversion

    private func bytesToBits(_ data: [UInt8]) -> [UInt8] {
        var bits = [UInt8]()
        bits.reserveCapacity(data.count * 8)
        for byte in data {
            for shift in stride(from: 7, through: 0, by: -1) {
                bits.append((byte >> shift) & 1)
            }
        }
        return bits
    }

    // MARK: - Backtracking Search
    //
    // Invariant on entry to `backtrack(level: k, vx, vy, t)`:
    //   - `vx`, `vy`, `t` already hold the (k-1) high-order bits chosen
    //     by parent recursions (zero on first call).
    //
    // Invariant on successful return:
    //   - `vx`, `vy`, `t` hold k bits each, and reading the cell at the
    //     extended coordinates produces a bit equal to `bits[bitCount - k]`.

    private func backtrack(
        bits: [UInt8],
        level: Int,
        qubits: [ChainQubit],
        vx: inout UInt64,
        vy: inout UInt64,
        t:  inout UInt64
    ) -> Bool {
        if budget <= 0 { return false }
        budget -= 1

        let n = bits.count
        let bitIdx = n - level     // which message bit lives at this level
        let target = bits[bitIdx]

        // Try all 8 child cells (each axis can pick its new bit ∈ {0, 1}).
        for combo in 0 ..< 8 {
            let nbX = UInt64((combo >> 0) & 1)
            let nbY = UInt64((combo >> 1) & 1)
            let nbT = UInt64((combo >> 2) & 1)

            // Save parent state for backtrack.
            let saveVx = vx, saveVy = vy, saveT = t

            // Extend each axis by one bit.
            vx = (vx << 1) | nbX
            vy = (vy << 1) | nbY
            t  = (t  << 1) | nbT

            if cellBit(level: level, vx: vx, vy: vy, t: t, qubits: qubits) == target {
                if level == n {
                    return true   // master key complete
                }
                if backtrack(bits: bits, level: level + 1, qubits: qubits, vx: &vx, vy: &vy, t: &t) {
                    return true
                }
            }

            // Backtrack — restore parent state and try the next combo.
            vx = saveVx
            vy = saveVy
            t  = saveT
        }
        return false
    }

    // MARK: - Cell-Centered Read

    /// Read a single derived bit from the cell `(vx, vy, t)` at the given
    /// octree `level`. The actual sample position is the *center* of the
    /// cell, so parent and child cells never collide.
    func cellBit(level: Int, vx: UInt64, vy: UInt64, t: UInt64, qubits: [ChainQubit]) -> UInt8 {
        let denom = Double(UInt64(1) << level)
        let fieldSize = QuantumChainField.fieldSize

        let fvx = (Double(vx) + 0.5) / denom * fieldSize
        let fvy = (Double(vy) + 0.5) / denom * fieldSize
        let ft  = (Double(t)  + 0.5) / denom * fieldSize * Double(QuantumConstants.tScale)

        return field.readSingleBit(qubits: qubits, vx: fvx, vy: fvy, t: ft)
    }
}
