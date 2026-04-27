// QuantumState.swift
// Core quantum state vector representation for the JeffJS quantum simulator.
//
// Complex64 is layout-compatible with Metal's float2 so GPU buffers can be
// reinterpreted directly. QuantumState holds a full 2^N amplitude vector and
// implements every gate as a bulk operation over index pairs — no per-amplitude
// branching.
//
// The deterministic PRNG (SplitMix64) used for measurement is defined in
// QuantumQubit.swift and shared across the project.

import Foundation

// MARK: - Complex64

/// A complex number stored as two `Float` values. Memory layout matches
/// Metal's `float2` (two contiguous 32-bit floats), so arrays of Complex64
/// can be blitted to/from GPU buffers without conversion.
struct Complex64: Equatable {
    var real: Float
    var imag: Float

    // MARK: Init

    init(_ real: Float, _ imag: Float) {
        self.real = real
        self.imag = imag
    }

    init(real: Float, imag: Float) {
        self.real = real
        self.imag = imag
    }

    /// Construct from polar form: magnitude * e^{i * phase}.
    init(magnitude: Float, phase: Float) {
        self.real = magnitude * cos(phase)
        self.imag = magnitude * sin(phase)
    }

    // MARK: Constants

    static let zero = Complex64(0, 0)
    static let one  = Complex64(1, 0)
    static let i    = Complex64(0, 1)

    // MARK: Derived properties

    /// |z|^2 = real^2 + imag^2. Avoids the sqrt needed by true magnitude.
    var magnitudeSquared: Float {
        real * real + imag * imag
    }

    /// arg(z) = atan2(imag, real).
    var phase: Float {
        atan2(imag, real)
    }

    // MARK: Arithmetic operators

    static func + (lhs: Complex64, rhs: Complex64) -> Complex64 {
        Complex64(lhs.real + rhs.real, lhs.imag + rhs.imag)
    }

    static func - (lhs: Complex64, rhs: Complex64) -> Complex64 {
        Complex64(lhs.real - rhs.real, lhs.imag - rhs.imag)
    }

    /// Complex multiplication: (a+bi)(c+di) = (ac-bd) + (ad+bc)i.
    static func * (lhs: Complex64, rhs: Complex64) -> Complex64 {
        Complex64(
            lhs.real * rhs.real - lhs.imag * rhs.imag,
            lhs.real * rhs.imag + lhs.imag * rhs.real
        )
    }

    /// Scalar-complex multiplication.
    static func * (scalar: Float, rhs: Complex64) -> Complex64 {
        Complex64(scalar * rhs.real, scalar * rhs.imag)
    }

    /// Complex-scalar multiplication.
    static func * (lhs: Complex64, scalar: Float) -> Complex64 {
        Complex64(lhs.real * scalar, lhs.imag * scalar)
    }
}

// MARK: - QuantumState

/// Full state vector for an N-qubit quantum register.
///
/// The amplitudes array has `2^numQubits` entries. Index `k` corresponds to
/// the computational basis state whose binary representation is `k`, with
/// qubit 0 as the least-significant bit.
///
/// All gate operations mutate the amplitudes array in-place using
/// stride-based pair iteration. For an N-qubit register and a gate on
/// qubit `q`, we iterate over all index pairs `(i0, i1)` that differ only
/// in bit `q`. This is O(2^N) per gate, the theoretical minimum.
final class QuantumState {

    let numQubits: Int
    let dimension: Int
    var amplitudes: [Complex64]

    // MARK: Init

    /// Create the |0...0> state: first amplitude = 1, rest = 0.
    init(numQubits: Int) {
        precondition(numQubits > 0 && numQubits <= 33, "numQubits must be in 1...33")
        self.numQubits = numQubits
        self.dimension = 1 << numQubits
        self.amplitudes = [Complex64](repeating: .zero, count: 1 << numQubits)
        self.amplitudes[0] = .one
    }

    // MARK: - Single-Qubit Gates

    /// Hadamard on qubit `q`.
    /// For each pair (i0, i1) differing only at bit q:
    ///   new[i0] = (old[i0] + old[i1]) / sqrt(2)
    ///   new[i1] = (old[i0] - old[i1]) / sqrt(2)
    func applyHadamard(qubit q: Int) {
        let invSqrt2: Float = 1.0 / sqrtf(2.0)
        enumeratePairs(qubit: q) { i0, i1 in
            let a0 = amplitudes[i0]
            let a1 = amplitudes[i1]
            amplitudes[i0] = (a0 + a1) * invSqrt2
            amplitudes[i1] = (a0 - a1) * invSqrt2
        }
    }

    /// Pauli-X (NOT): swap |0> and |1> amplitudes.
    func applyPauliX(qubit q: Int) {
        enumeratePairs(qubit: q) { i0, i1 in
            let tmp = amplitudes[i0]
            amplitudes[i0] = amplitudes[i1]
            amplitudes[i1] = tmp
        }
    }

    /// Pauli-Y: |0> -> i|1>, |1> -> -i|0>.
    /// Matrix: [[0, -i], [i, 0]]
    func applyPauliY(qubit q: Int) {
        enumeratePairs(qubit: q) { i0, i1 in
            let a0 = amplitudes[i0]
            let a1 = amplitudes[i1]
            // new[i0] = -i * a1 = Complex64(a1.imag, -a1.real)
            amplitudes[i0] = Complex64(a1.imag, -a1.real)
            // new[i1] =  i * a0 = Complex64(-a0.imag, a0.real)
            amplitudes[i1] = Complex64(-a0.imag, a0.real)
        }
    }

    /// Pauli-Z: negate the |1> amplitudes (where bit q = 1).
    func applyPauliZ(qubit q: Int) {
        enumeratePairs(qubit: q) { _, i1 in
            amplitudes[i1] = Complex64(-amplitudes[i1].real, -amplitudes[i1].imag)
        }
    }

    /// Phase gate: multiply |1> amplitudes by e^{i*angle}.
    func applyPhase(qubit q: Int, angle: Float) {
        let c = cos(angle)
        let s = sin(angle)
        let phasor = Complex64(c, s)
        enumeratePairs(qubit: q) { _, i1 in
            amplitudes[i1] = amplitudes[i1] * phasor
        }
    }

    /// S gate = Phase(pi/2). Multiplies |1> by i.
    func applyS(qubit q: Int) {
        applyPhase(qubit: q, angle: .pi / 2)
    }

    /// T gate = Phase(pi/4).
    func applyT(qubit q: Int) {
        applyPhase(qubit: q, angle: .pi / 4)
    }

    /// T-dagger = Phase(-pi/4).
    func applyTDagger(qubit q: Int) {
        applyPhase(qubit: q, angle: -.pi / 4)
    }

    // MARK: - Two-Qubit Gates

    /// CNOT (controlled-X): flip the target bit wherever the control bit is 1.
    /// This is equivalent to swapping amplitudes at index pairs where the
    /// control bit is 1 and the target bit differs.
    func applyCNOT(control: Int, target: Int) {
        let maskC = 1 << control
        let maskT = 1 << target
        for idx in 0 ..< dimension {
            // Only process each pair once: require target bit = 0.
            guard idx & maskT == 0 else { continue }
            // Only act when control bit is 1.
            guard idx & maskC != 0 else { continue }
            let partner = idx | maskT
            let tmp = amplitudes[idx]
            amplitudes[idx] = amplitudes[partner]
            amplitudes[partner] = tmp
        }
    }

    /// Controlled modular multiplication for Shor's algorithm.
    ///
    /// When the control qubit is |1>, this gate applies the unitary
    /// |x> -> |a*x mod N> on the work register (qubits at workOffset
    /// through workOffset+nWork-1). Values x >= N are left unchanged.
    ///
    /// Uses a temporary copy of the amplitudes for the permutation.
    func applyControlledModMult(control: Int, workOffset: Int, nWork: Int, a: UInt32, N: UInt32) {
        let maskC = 1 << control
        let workMask = ((1 << nWork) - 1) << workOffset

        // We need a scratch buffer because the permutation is not in-place.
        var scratch = amplitudes

        for idx in 0 ..< dimension {
            // Only permute when control qubit is 1.
            guard idx & maskC != 0 else { continue }

            // Extract the work register value.
            let x = UInt32((idx & workMask) >> workOffset)
            guard x < N else { continue }

            let ax = (UInt64(a) * UInt64(x)) % UInt64(N)
            let newWork = Int(ax) << workOffset
            let target = (idx & ~workMask) | newWork

            scratch[target] = amplitudes[idx]
        }

        amplitudes = scratch
    }

    // MARK: - Measurement

    /// Probability that qubit `q` measures as |0>.
    /// Sums |amplitude|^2 for all basis states where bit q = 0.
    func probabilityOfZero(qubit q: Int) -> Float {
        let mask = 1 << q
        var prob: Float = 0
        for idx in 0 ..< dimension {
            if idx & mask == 0 {
                prob += amplitudes[idx].magnitudeSquared
            }
        }
        return prob
    }

    /// Measure qubit `q`, collapsing the state and returning 0 or 1.
    ///
    /// Samples using the supplied SplitMix64 PRNG, then zeroes out all
    /// amplitudes inconsistent with the result and renormalises.
    func measure(qubit q: Int, rng: inout SplitMix64) -> Int {
        let pZero = probabilityOfZero(qubit: q)
        let r = rng.nextFloat()
        let outcome = r < pZero ? 0 : 1

        let mask = 1 << q
        let keepBitValue = outcome == 0 ? 0 : mask
        var norm: Float = 0

        // Zero out amplitudes inconsistent with the measurement outcome.
        for idx in 0 ..< dimension {
            if idx & mask == keepBitValue {
                norm += amplitudes[idx].magnitudeSquared
            } else {
                amplitudes[idx] = .zero
            }
        }

        // Renormalize the surviving amplitudes.
        if norm > 0 {
            let scale = 1.0 / sqrtf(norm)
            for idx in 0 ..< dimension where amplitudes[idx].magnitudeSquared > 0 {
                amplitudes[idx] = amplitudes[idx] * scale
            }
        }

        return outcome
    }

    // MARK: - Copy

    /// Deep copy: duplicates the amplitudes array.
    func copy() -> QuantumState {
        let clone = QuantumState(numQubits: numQubits)
        for i in 0 ..< dimension {
            clone.amplitudes[i] = amplitudes[i]
        }
        return clone
    }

    // MARK: - Pair Enumeration (private)

    /// Iterate over all index pairs `(i0, i1)` that differ only at bit
    /// position `q`. `i0` has bit q = 0, `i1` has bit q = 1.
    ///
    /// The stride-based iteration avoids branching: we split the index into
    /// the bits above and below position `q`, then combine them with the
    /// qubit bit inserted.
    @inline(__always)
    private func enumeratePairs(qubit q: Int, body: (Int, Int) -> Void) {
        let step = 1 << q
        let doubleStep = step << 1
        var block = 0
        while block < dimension {
            for j in 0 ..< step {
                let i0 = block + j          // bit q = 0
                let i1 = i0 + step          // bit q = 1
                body(i0, i1)
            }
            block += doubleStep
        }
    }
}
