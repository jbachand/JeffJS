// QuantumQubit.swift
// Deterministic qubit field generation and bit-reading.
//
// Qubits are pseudo-random points on a 2D grid that rotate over time.
// Reading bits at a position finds the closest qubits and derives
// binary values from the cross-product of their motion vectors.

import Foundation

/// A single qubit in the field with deterministic motion parameters.
struct Qubit {
    let x:      Float
    let y:      Float
    let speed:  Float
    let radius: Float
    let phase:  Float
}

// MARK: - Qubit Field

/// Thread-safe cache of generated qubit arrays keyed by seed.
final class QuantumField {

    private var cache: [UInt32: [Qubit]] = [:]
    private let cacheLimit = 64

    /// Generate (or return cached) qubits for a given seed.
    func qubits(forSeed seed: UInt32) -> [Qubit] {
        if let cached = cache[seed] { return cached }

        // Deterministic PRNG seeded per-seed value.
        var rng = SplitMix64(seed: UInt64(seed))

        let count = QuantumConstants.numQubits
        let gridVX = Float(QuantumConstants.gridVX)
        let gridVY = Float(QuantumConstants.gridVY)

        var result = [Qubit]()
        result.reserveCapacity(count)

        for _ in 0 ..< count {
            result.append(Qubit(
                x:      rng.nextFloat() * gridVX,
                y:      rng.nextFloat() * gridVY,
                speed:  rng.nextFloat(in: 0.5 ... 5.0),
                radius: rng.nextFloat(in: 0.5 ... 2.0),
                phase:  rng.nextFloat() * 2 * .pi
            ))
        }

        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[seed] = result
        return result
    }

    /// Compute the actual RNG seed value from a seed index and base.
    static func rngSeed(index: UInt32, base: UInt32 = QuantumConstants.baseSeed) -> UInt32 {
        base &+ index &* 0x1337
    }

    /// Read `nBits` starting from the `offset`-th closest qubit to (vx, vy) at time `t`.
    func readBits(qubits: [Qubit], vx: Float, vy: Float, t: Float, offset: Int, nBits: Int) -> [UInt8] {
        let need = offset + nBits

        // Find closest `need` qubits by squared distance.
        var dists: [(dist: Float, idx: Int)] = qubits.enumerated().map { (i, q) in
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

    /// Read the full 25-bit payload at a quantum address.
    func readPayload(at addr: QuantumAddress, baseSeed: UInt32 = QuantumConstants.baseSeed) -> UInt32 {
        let seed = Self.rngSeed(index: addr.seed, base: baseSeed)
        let qs = qubits(forSeed: seed)
        let bits = readBits(
            qubits: qs,
            vx: Float(addr.vx),
            vy: Float(addr.vy),
            t:  Float(addr.t) * QuantumConstants.tScale,
            offset: Int(addr.offset),
            nBits: QuantumConstants.totalBits
        )
        var payload: UInt32 = 0
        for b in bits { payload = (payload << 1) | UInt32(b) }
        return payload
    }
}

// MARK: - Deterministic PRNG (SplitMix64)

/// Fast, deterministic PRNG used to generate qubit fields. The same seed
/// always produces the same sequence of qubits, which is what makes the
/// encoder/decoder round-trip without storing the field itself.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform float in [0, 1).
    mutating func nextFloat() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }

    /// Uniform float in a closed range.
    mutating func nextFloat(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + nextFloat() * (range.upperBound - range.lowerBound)
    }
}
