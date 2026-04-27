// QuantumChainField.swift
// Double-precision qubit field for the resolution-deepening chain encoder.
//
// The main `QuantumField` uses Float qubit positions, which limits useful
// resolution to ~24 bits per axis. The chain encoder needs to address cells
// down to the precision floor of the underlying field, so we generate a
// parallel field with Double-precision positions, motion parameters, and
// reads. This pushes the precision floor to ~52 bits per axis.

import Foundation

/// A qubit with Double-precision motion parameters.
struct ChainQubit {
    let x:      Double
    let y:      Double
    let speed:  Double
    let radius: Double
    let phase:  Double
}

/// Double-precision qubit field. Same generation algorithm as `QuantumField`,
/// but every value is `Double` so cell positions remain distinguishable at
/// deep octree levels.
///
/// Not thread-safe: each instance owns a private cache that mutates on
/// `qubits(forSeed:)`. The chain encoder/decoder are designed so each
/// background task instantiates its own encoder/decoder (and therefore its
/// own field), keeping cache access thread-confined.
final class QuantumChainField {

    /// In-memory cache of generated fields.
    private var cache: [UInt32: [ChainQubit]] = [:]
    private let cacheLimit = 32

    /// Side length of the qubit field along each spatial axis.
    static let fieldSize: Double = Double(QuantumConstants.gridVX)

    /// Returns (or generates and caches) the qubit field for the given seed.
    func qubits(forSeed seed: UInt32) -> [ChainQubit] {
        if let cached = cache[seed] { return cached }

        var rng = SplitMix64(seed: UInt64(seed))
        let count = QuantumConstants.numQubits

        var result = [ChainQubit]()
        result.reserveCapacity(count)
        for _ in 0 ..< count {
            result.append(ChainQubit(
                x:      rng.nextDouble() * Self.fieldSize,
                y:      rng.nextDouble() * Self.fieldSize,
                speed:  rng.nextDouble(in: 0.5 ... 5.0),
                radius: rng.nextDouble(in: 0.5 ... 2.0),
                phase:  rng.nextDouble() * 2 * .pi
            ))
        }

        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[seed] = result
        return result
    }

    /// Read `nBits` from the position `(vx, vy)` at time `t`, starting from
    /// the `offset`-th closest qubit. Identical formula to `QuantumField`'s
    /// `readBits` but every operand is `Double`.
    func readBits(
        qubits: [ChainQubit],
        vx: Double, vy: Double, t: Double,
        offset: Int, nBits: Int
    ) -> [UInt8] {
        let need = offset + nBits

        var dists: [(dist: Double, idx: Int)] = qubits.enumerated().map { (i, q) in
            let dx = q.x - vx
            let dy = q.y - vy
            return (dx * dx + dy * dy, i)
        }
        dists.sort { $0.dist < $1.dist }

        var bits = [UInt8]()
        bits.reserveCapacity(nBits)

        for i in offset ..< need {
            guard i < dists.count else { bits.append(0); continue }
            let q = qubits[dists[i].idx]
            let dx = q.x - vx
            let dy = q.y - vy
            let angle = q.phase + q.speed * q.radius * t
            let cross = sin(angle) * dx - cos(angle) * dy
            bits.append(cross < 0 ? 1 : 0)
        }
        return bits
    }

    /// Read the full payload (`QuantumConstants.totalBits` bits) at a position
    /// and derive a single bit from its popcount slice (low half = 0, high
    /// half = 1). This is the bit-derivation function used by the chain
    /// encoder/decoder at every level.
    func readSingleBit(
        qubits: [ChainQubit],
        vx: Double, vy: Double, t: Double
    ) -> UInt8 {
        let bits = readBits(
            qubits: qubits,
            vx: vx, vy: vy, t: t,
            offset: 0, nBits: QuantumConstants.totalBits
        )
        var pop = 0
        for b in bits { pop += Int(b) }
        return pop >= QuantumConstants.totalBits / 2 ? 1 : 0
    }
}

// MARK: - SplitMix64 Double helpers

extension SplitMix64 {

    /// Uniform Double in [0, 1) — full 53 bits of mantissa precision.
    mutating func nextDouble() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }

    /// Uniform Double in a closed range.
    mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + nextDouble() * (range.upperBound - range.lowerBound)
    }
}
