// QuantumCliffordT.swift
// Clifford+T simulator using stabilizer decomposition with a parallel state vector.
//
// Clifford gates are tracked in O(N) via stabilizer tableaux. Each T gate
// doubles the number of stabilizer terms (T|psi> = cos(pi/8)|psi> + sin(pi/8)SZ|psi>).
// A parallel dense state vector (for N <= 20) is maintained alongside the
// stabilizer terms so that Born probabilities can be computed coherently,
// preserving interference that the individual stabilizer branches would lose.
//
// Uses Complex64 from QuantumState.swift and SplitMix64 from QuantumQubit.swift.

import Foundation

// MARK: - CliffordTSimulator

final class CliffordTSimulator {

    let n: Int
    /// Stabilizer decomposition: list of (coefficient, stabilizer state) terms.
    private(set) var terms: [(Complex64, StabilizerState)]
    /// Number of T gates applied (each doubles the number of terms).
    private(set) var tCount: Int = 0

    /// Parallel dense state vector for coherent measurement.
    /// Maintains the exact quantum state so that Born probabilities account
    /// for interference between stabilizer branches.
    private var stateVec: [Complex64]
    private let dim: Int

    // MARK: Init

    /// Create an N-qubit Clifford+T simulator in the |0...0> state.
    /// The parallel state vector is allocated only for N <= 20.
    init(numQubits: Int) {
        precondition(numQubits > 0, "numQubits must be positive")
        self.n = numQubits
        self.dim = 1 << numQubits
        self.terms = [(Complex64.one, StabilizerState(numQubits: numQubits))]

        // Initialize parallel state vector to |0...0>.
        precondition(numQubits <= 20, "Parallel state vector limited to 20 qubits")
        self.stateVec = [Complex64](repeating: .zero, count: 1 << numQubits)
        self.stateVec[0] = .one
    }

    // MARK: - Clifford Gates

    /// Hadamard on qubit `q`. Applied to all stabilizer terms and the state vector.
    func h(_ qubit: Int) {
        for i in 0 ..< terms.count {
            terms[i].1.h(qubit)
        }
        applyGateToVec(CliffordTSimulator.hadamardMatrix, qubit: qubit)
    }

    /// Phase gate (S) on qubit `q`.
    func s(_ qubit: Int) {
        for i in 0 ..< terms.count {
            terms[i].1.s(qubit)
        }
        applyGateToVec(CliffordTSimulator.sMatrix, qubit: qubit)
    }

    /// CNOT with `control` and `target`.
    func cnot(control: Int, target: Int) {
        for i in 0 ..< terms.count {
            terms[i].1.cnot(control: control, target: target)
        }
        applyCNOTToVec(control: control, target: target)
    }

    /// Pauli-X on qubit `q`.
    func x(_ qubit: Int) {
        for i in 0 ..< terms.count {
            terms[i].1.x(qubit)
        }
        applyGateToVec(CliffordTSimulator.xMatrix, qubit: qubit)
    }

    /// Pauli-Y on qubit `q`.
    func y(_ qubit: Int) {
        for i in 0 ..< terms.count {
            terms[i].1.y(qubit)
        }
        applyGateToVec(CliffordTSimulator.yMatrix, qubit: qubit)
    }

    /// Pauli-Z on qubit `q`.
    func z(_ qubit: Int) {
        for i in 0 ..< terms.count {
            terms[i].1.z(qubit)
        }
        applyGateToVec(CliffordTSimulator.zMatrix, qubit: qubit)
    }

    // MARK: - T Gate

    /// T gate on qubit `q`.
    /// Decomposes: T|psi> = cos(pi/8)|psi> + e^{i pi/4} sin(pi/8) Z|psi>.
    /// Each existing stabilizer term spawns two new terms, doubling the count.
    func t(_ qubit: Int) {
        tCount += 1

        let cosPi8 = Float(cos(Float.pi / 8))
        let sinPi8 = Float(sin(Float.pi / 8))
        // e^{i pi/4} = (1+i)/sqrt(2)
        let eiPi4 = Complex64(cos(Float.pi / 4), sin(Float.pi / 4))
        let coeffB = eiPi4 * sinPi8

        var newTerms: [(Complex64, StabilizerState)] = []
        newTerms.reserveCapacity(terms.count * 2)

        for (coeff, state) in terms {
            // Branch A: cos(pi/8) * coeff * |state>
            let branchA = state.copy()
            let coeffA = coeff * cosPi8

            // Branch B: e^{i pi/4} * sin(pi/8) * coeff * Z|state>
            let branchB = state.copy()
            branchB.z(qubit)
            let cB = coeff * coeffB

            newTerms.append((coeffA, branchA))
            newTerms.append((cB, branchB))
        }

        terms = newTerms

        // Apply T gate to the parallel state vector.
        applyGateToVec(CliffordTSimulator.tMatrix, qubit: qubit)
    }

    /// T-dagger gate on qubit `q`.
    /// Decomposes: T^dag|psi> = cos(pi/8)|psi> + e^{-i pi/4} sin(pi/8) Z|psi>.
    func tDagger(_ qubit: Int) {
        tCount += 1

        let cosPi8 = Float(cos(Float.pi / 8))
        let sinPi8 = Float(sin(Float.pi / 8))
        let eiMinusPi4 = Complex64(cos(Float.pi / 4), -sin(Float.pi / 4))
        let coeffB = eiMinusPi4 * sinPi8

        var newTerms: [(Complex64, StabilizerState)] = []
        newTerms.reserveCapacity(terms.count * 2)

        for (coeff, state) in terms {
            let branchA = state.copy()
            let coeffA = coeff * cosPi8

            let branchB = state.copy()
            branchB.z(qubit)
            let cB = coeff * coeffB

            newTerms.append((coeffA, branchA))
            newTerms.append((cB, branchB))
        }

        terms = newTerms
        applyGateToVec(CliffordTSimulator.tDaggerMatrix, qubit: qubit)
    }

    // MARK: - Measurement

    /// Measure qubit `q` using the parallel state vector for Born probabilities.
    /// This preserves quantum interference that individual stabilizer branches
    /// would lose. After measurement, the state vector and all stabilizer terms
    /// are collapsed and renormalized.
    func measure(_ qubit: Int, rng: inout SplitMix64) -> Int {
        // Compute P(0) from the parallel state vector.
        let mask = 1 << qubit
        var prob0: Float = 0
        for idx in 0 ..< dim {
            if idx & mask == 0 {
                prob0 += stateVec[idx].magnitudeSquared
            }
        }

        // Clamp for numerical safety.
        prob0 = min(max(prob0, 0), 1)

        let r = rng.nextFloat()
        let outcome = r < prob0 ? 0 : 1

        // Collapse the state vector.
        let keepBit = outcome == 0 ? 0 : mask
        var norm: Float = 0
        for idx in 0 ..< dim {
            if idx & mask == keepBit {
                norm += stateVec[idx].magnitudeSquared
            } else {
                stateVec[idx] = .zero
            }
        }
        if norm > 0 {
            let scale: Float = 1.0 / sqrtf(norm)
            for idx in 0 ..< dim {
                if stateVec[idx].magnitudeSquared > 0 {
                    stateVec[idx] = stateVec[idx] * scale
                }
            }
        }

        // Collapse stabilizer terms: force each term to the measured outcome.
        var survivingTerms: [(Complex64, StabilizerState)] = []
        for (coeff, state) in terms {
            let prob = state.forceMeasure(qubit, forcedOutcome: outcome)
            if prob > 0 {
                survivingTerms.append((coeff * prob, state))
            }
        }

        // Renormalize stabilizer coefficients.
        var totalWeight: Float = 0
        for (c, _) in survivingTerms {
            totalWeight += c.magnitudeSquared
        }
        if totalWeight > 0 {
            let scale: Float = 1.0 / sqrtf(totalWeight)
            for i in 0 ..< survivingTerms.count {
                survivingTerms[i].0 = survivingTerms[i].0 * scale
            }
        }
        terms = survivingTerms

        return outcome
    }

    /// Number of stabilizer terms in the decomposition.
    var numTerms: Int { terms.count }

    // MARK: - Gate Matrices

    private static let invSqrt2: Float = 1.0 / sqrtf(2.0)

    private static let hadamardMatrix: [[Complex64]] = [
        [Complex64(invSqrt2, 0), Complex64(invSqrt2, 0)],
        [Complex64(invSqrt2, 0), Complex64(-invSqrt2, 0)]
    ]

    private static let sMatrix: [[Complex64]] = [
        [Complex64.one, .zero],
        [.zero, Complex64.i]
    ]

    private static let xMatrix: [[Complex64]] = [
        [.zero, .one],
        [.one, .zero]
    ]

    private static let yMatrix: [[Complex64]] = [
        [.zero, Complex64(0, -1)],
        [Complex64(0, 1), .zero]
    ]

    private static let zMatrix: [[Complex64]] = [
        [.one, .zero],
        [.zero, Complex64(-1, 0)]
    ]

    private static let tMatrix: [[Complex64]] = [
        [.one, .zero],
        [.zero, Complex64(cos(Float.pi / 4), sin(Float.pi / 4))]
    ]

    private static let tDaggerMatrix: [[Complex64]] = [
        [.one, .zero],
        [.zero, Complex64(cos(Float.pi / 4), -sin(Float.pi / 4))]
    ]

    // MARK: - State Vector Helpers (Private)

    /// Apply a 2x2 unitary gate matrix to qubit `qubit` in the state vector.
    /// Iterates over all pairs of indices differing only at bit `qubit`.
    private func applyGateToVec(_ matrix: [[Complex64]], qubit: Int) {
        let step = 1 << qubit
        let doubleStep = step << 1
        var block = 0
        while block < dim {
            for j in 0 ..< step {
                let i0 = block + j       // bit qubit = 0
                let i1 = i0 + step       // bit qubit = 1
                let a0 = stateVec[i0]
                let a1 = stateVec[i1]
                stateVec[i0] = matrix[0][0] * a0 + matrix[0][1] * a1
                stateVec[i1] = matrix[1][0] * a0 + matrix[1][1] * a1
            }
            block += doubleStep
        }
    }

    /// Apply CNOT to the state vector. Swaps amplitudes where control = 1
    /// and target differs.
    private func applyCNOTToVec(control: Int, target: Int) {
        let maskC = 1 << control
        let maskT = 1 << target
        for idx in 0 ..< dim {
            guard idx & maskT == 0 else { continue }
            guard idx & maskC != 0 else { continue }
            let partner = idx | maskT
            let tmp = stateVec[idx]
            stateVec[idx] = stateVec[partner]
            stateVec[partner] = tmp
        }
    }
}
