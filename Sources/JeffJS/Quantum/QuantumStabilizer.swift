// QuantumStabilizer.swift
// Stabilizer-state simulator using the Aaronson-Gottesman tableau formalism.
//
// An N-qubit stabilizer state is represented by a (2N) x (2N+1) binary matrix.
// Rows 0..N-1 are destabilizers (X-type generators), rows N..2N-1 are
// stabilizers (Z-type generators). Each row has N X-bits, N Z-bits, and one
// phase bit. All Clifford gates (H, S, CNOT, X, Y, Z) update the tableau in
// O(N) time; measurement is O(N^2).
//
// Uses the project-wide SplitMix64 PRNG from QuantumQubit.swift.

import Foundation

// MARK: - StabilizerState

/// Stabilizer state represented by a (2N) x (2N+1) binary tableau.
final class StabilizerState {

    let n: Int
    /// 2N rows, each with 2N+1 columns: [x0..xN-1, z0..zN-1, phase].
    var tableau: [[UInt8]]

    // MARK: Init

    /// Create the |0...0> state.
    /// Destabilizer row i has X_i = 1 (all other entries 0).
    /// Stabilizer row N+i has Z_i = 1 (all other entries 0).
    init(numQubits: Int) {
        precondition(numQubits > 0, "numQubits must be positive")
        self.n = numQubits
        let cols = 2 * n + 1
        var t = [[UInt8]](repeating: [UInt8](repeating: 0, count: cols), count: 2 * n)
        for i in 0 ..< n {
            t[i][i] = 1          // destabilizer: X_i = 1
            t[n + i][n + i] = 1  // stabilizer:   Z_i = 1
        }
        self.tableau = t
    }

    /// Private init for copy().
    private init(n: Int, tableau: [[UInt8]]) {
        self.n = n
        self.tableau = tableau.map { $0 }
    }

    // MARK: - Clifford Gates

    /// Hadamard on qubit `q`.
    /// Swaps X and Z columns for this qubit, then updates the phase:
    ///   r ^= x & z   (because HXH = Z and HZH = X, but HYH = -Y).
    func h(_ qubit: Int) {
        let q = qubit
        for row in 0 ..< 2 * n {
            let xq = tableau[row][q]
            let zq = tableau[row][n + q]
            // Phase update: r ^= x & z
            tableau[row][2 * n] ^= xq & zq
            // Swap X and Z
            tableau[row][q] = zq
            tableau[row][n + q] = xq
        }
    }

    /// Phase gate (S) on qubit `q`.
    /// S maps X -> Y (= iXZ), Z -> Z.
    /// Phase update: r ^= x & z, then z ^= x.
    func s(_ qubit: Int) {
        let q = qubit
        for row in 0 ..< 2 * n {
            let xq = tableau[row][q]
            let zq = tableau[row][n + q]
            // Phase: r ^= x & z
            tableau[row][2 * n] ^= xq & zq
            // Z column: z ^= x
            tableau[row][n + q] = zq ^ xq
        }
    }

    /// CNOT with control `control` and target `target`.
    /// Updates the tableau for all rows:
    ///   r ^= x_control & z_target & (x_target ^ z_control ^ 1)
    ///   x_target ^= x_control
    ///   z_control ^= z_target
    func cnot(control: Int, target: Int) {
        let c = control
        let t = target
        for row in 0 ..< 2 * n {
            let xc = tableau[row][c]
            let zc = tableau[row][n + c]
            let xt = tableau[row][t]
            let zt = tableau[row][n + t]
            // Phase update
            tableau[row][2 * n] ^= xc & zt & (xt ^ zc ^ 1)
            // X_target ^= X_control
            tableau[row][t] = xt ^ xc
            // Z_control ^= Z_target
            tableau[row][n + c] = zc ^ zt
        }
    }

    /// Pauli-X on qubit `q`.
    /// X anti-commutes with Z, so flip phase wherever Z_q = 1.
    func x(_ qubit: Int) {
        let q = qubit
        for row in 0 ..< 2 * n {
            tableau[row][2 * n] ^= tableau[row][n + q]
        }
    }

    /// Pauli-Y on qubit `q`.
    /// Y = iXZ. Flip phase wherever X_q ^ Z_q = 1 (anti-commutes with
    /// either X or Z but not both).
    func y(_ qubit: Int) {
        let q = qubit
        for row in 0 ..< 2 * n {
            tableau[row][2 * n] ^= tableau[row][q] ^ tableau[row][n + q]
        }
    }

    /// Pauli-Z on qubit `q`.
    /// Z anti-commutes with X, so flip phase wherever X_q = 1.
    func z(_ qubit: Int) {
        let q = qubit
        for row in 0 ..< 2 * n {
            tableau[row][2 * n] ^= tableau[row][q]
        }
    }

    // MARK: - Measurement

    /// Check whether measuring qubit `q` is deterministic.
    /// Returns (true, outcome) if deterministic, (false, nil) otherwise.
    /// Deterministic when no stabilizer row has X_q = 1.
    func isDeterministic(_ qubit: Int) -> (Bool, Int?) {
        let q = qubit
        // Search stabilizer rows N..2N-1 for one with X_q = 1.
        for p in n ..< 2 * n {
            if tableau[p][q] == 1 {
                return (false, nil)
            }
        }
        // Deterministic: compute outcome from destabilizer rows.
        // The outcome is the phase of the product of destabilizers with Z_q = 1,
        // but we can use a scratch row approach.
        // Use rowmult on a virtual "identity" row to accumulate.
        var scratchPhase: Int = 0
        for i in 0 ..< n {
            if tableau[i][q] == 1 {
                // We need to account for this destabilizer's contribution.
                // Multiply stabilizer row (n+i) into the accumulated phase.
                // For the first contributing row, just take its phase.
                // For subsequent rows, use the g-function to accumulate.
                scratchPhase = accumulatePhase(scratchPhase, stabilizer: n + i)
            }
        }
        let outcome = (scratchPhase & 1 == 0) ? 0 : 1
        return (true, outcome)
    }

    /// Accumulate phase from stabilizer row into running phase.
    /// This is a simplified version for deterministic measurement.
    private func accumulatePhase(_ currentPhase: Int, stabilizer row: Int) -> Int {
        // The full g-function computation for the accumulated product.
        var phase = currentPhase + Int(tableau[row][2 * n]) * 2
        // We just need to track the phase contribution.
        // For a simple accumulation, we can directly use the phase bit.
        return phase
    }

    /// Measure qubit `q`, returning 0 or 1. Uses the random bit from rng
    /// when the outcome is non-deterministic.
    func measure(_ qubit: Int, rng: inout SplitMix64) -> Int {
        let q = qubit

        // Step 1: Find a stabilizer row p in [N, 2N) with X_q = 1.
        var p: Int = -1
        for row in n ..< 2 * n {
            if tableau[row][q] == 1 {
                p = row
                break
            }
        }

        if p == -1 {
            // Deterministic case: no stabilizer has X_q = 1.
            // Outcome is determined by the destabilizer product.
            // Use a scratch row to accumulate via rowmult.
            let scratch = 2 * n  // We'll temporarily add a scratch row.
            var scratchRow = [UInt8](repeating: 0, count: 2 * n + 1)

            // Multiply in all stabilizers (row n+i) where destabilizer row i has X_q = 1.
            var first = true
            for i in 0 ..< n {
                if tableau[i][q] == 1 {
                    if first {
                        scratchRow = tableau[n + i]
                        first = false
                    } else {
                        // Multiply scratchRow by tableau[n+i] using the g-function.
                        scratchRow = rowMultExternal(scratchRow, tableau[n + i])
                    }
                }
            }

            return Int(scratchRow[2 * n])  // phase bit = outcome
        }

        // Non-deterministic case: stabilizer row p has X_q = 1.
        // Step 2: For all rows != p in [0, 2N) with X_q = 1, rowmult them with p.
        for i in 0 ..< 2 * n {
            if i != p && tableau[i][q] == 1 {
                rowmult(i, p)
            }
        }

        // Step 3: Set destabilizer row (p - n) = old stabilizer row p.
        let destRow = p - n
        tableau[destRow] = tableau[p]

        // Step 4: Set stabilizer row p to +Z_q or -Z_q randomly.
        tableau[p] = [UInt8](repeating: 0, count: 2 * n + 1)
        tableau[p][n + q] = 1  // Z_q = 1
        let outcome: Int
        if rng.nextFloat() < 0.5 {
            tableau[p][2 * n] = 0
            outcome = 0
        } else {
            tableau[p][2 * n] = 1
            outcome = 1
        }

        return outcome
    }

    /// Force a measurement on qubit `q` to yield `forcedOutcome` (0 or 1).
    /// Returns the probability of the forced outcome (0.5 for non-deterministic,
    /// 1.0 for deterministic matching, 0.0 for deterministic non-matching).
    func forceMeasure(_ qubit: Int, forcedOutcome: Int) -> Float {
        let q = qubit

        // Find a stabilizer row p in [N, 2N) with X_q = 1.
        var p: Int = -1
        for row in n ..< 2 * n {
            if tableau[row][q] == 1 {
                p = row
                break
            }
        }

        if p == -1 {
            // Deterministic case: check if natural outcome matches.
            let (_, naturalOutcome) = isDeterministic(q)
            if naturalOutcome == forcedOutcome {
                return 1.0
            } else {
                return 0.0
            }
        }

        // Non-deterministic: force the outcome.
        for i in 0 ..< 2 * n {
            if i != p && tableau[i][q] == 1 {
                rowmult(i, p)
            }
        }

        let destRow = p - n
        tableau[destRow] = tableau[p]

        tableau[p] = [UInt8](repeating: 0, count: 2 * n + 1)
        tableau[p][n + q] = 1
        tableau[p][2 * n] = UInt8(forcedOutcome)

        return 0.5
    }

    // MARK: - Convenience

    /// Create a Bell pair (|00> + |11>) / sqrt(2) on qubits q0, q1.
    func bellPair(_ q0: Int, _ q1: Int) {
        h(q0)
        cnot(control: q0, target: q1)
    }

    /// Create a GHZ state (|00...0> + |11...1>) / sqrt(2) on the given qubits.
    func ghz(_ qubits: [Int]) {
        guard let first = qubits.first else { return }
        h(first)
        for i in 1 ..< qubits.count {
            cnot(control: first, target: qubits[i])
        }
    }

    /// Deep copy of this stabilizer state.
    func copy() -> StabilizerState {
        StabilizerState(n: n, tableau: tableau)
    }

    // MARK: - Internal: Row Multiplication

    /// The g-function for combining two Pauli operators.
    /// Given (x1, z1) and (x2, z2) each representing a single-qubit Pauli,
    /// returns the phase contribution (0, 1, -1 mapped to 0, 2, -2 in the
    /// accumulated sum).
    ///
    /// CRITICAL: All arithmetic is done as Int to avoid UInt8 overflow.
    @inline(__always)
    private static func gFunc(_ x1: Int, _ z1: Int, _ x2: Int, _ z2: Int) -> Int {
        if x1 == 0 && z1 == 0 { return 0 }
        if x1 == 1 && z1 == 1 {
            // Y-type: Z*Y = -i*X, X*Y = i*Z, Y*Y = I
            return z2 - x2
        }
        if x1 == 1 && z1 == 0 {
            // X-type: X*X = I, X*Z = -i*Y, X*Y = i*Z
            return z2 * (2 * x2 - 1)
        }
        // z1 == 1, x1 == 0
        // Z-type: Z*X = i*Y, Z*Z = I, Z*Y = -i*X
        return x2 * (1 - 2 * z2)
    }

    /// Multiply row `source` into row `target`: target = target * source.
    /// Phase is updated using the g-function summed across all qubits.
    private func rowmult(_ target: Int, _ source: Int) {
        // Accumulate phase contribution from all N qubits.
        var phaseSum: Int = 0
        for j in 0 ..< n {
            let x1 = Int(tableau[target][j])
            let z1 = Int(tableau[target][n + j])
            let x2 = Int(tableau[source][j])
            let z2 = Int(tableau[source][n + j])
            phaseSum += StabilizerState.gFunc(x1, z1, x2, z2)
        }

        // Total phase = 2*r_target + 2*r_source + phaseSum
        let rTarget = Int(tableau[target][2 * n])
        let rSource = Int(tableau[source][2 * n])
        let totalPhase = 2 * rTarget + 2 * rSource + phaseSum

        // New phase bit: (totalPhase mod 4) / 2
        // Use ((totalPhase % 4) + 4) % 4 to handle negative values.
        let mod4 = ((totalPhase % 4) + 4) % 4
        tableau[target][2 * n] = (mod4 == 2 || mod4 == 3) ? 1 : 0

        // XOR the X and Z bits.
        for j in 0 ..< n {
            tableau[target][j] ^= tableau[source][j]
            tableau[target][n + j] ^= tableau[source][n + j]
        }
    }

    /// Multiply two external rows and return the result.
    /// Used in deterministic measurement where we accumulate into a scratch row.
    private func rowMultExternal(_ row1: [UInt8], _ row2: [UInt8]) -> [UInt8] {
        var result = row1

        var phaseSum: Int = 0
        for j in 0 ..< n {
            let x1 = Int(row1[j])
            let z1 = Int(row1[n + j])
            let x2 = Int(row2[j])
            let z2 = Int(row2[n + j])
            phaseSum += StabilizerState.gFunc(x1, z1, x2, z2)
        }

        let r1 = Int(row1[2 * n])
        let r2 = Int(row2[2 * n])
        let totalPhase = 2 * r1 + 2 * r2 + phaseSum
        let mod4 = ((totalPhase % 4) + 4) % 4
        result[2 * n] = (mod4 == 2 || mod4 == 3) ? 1 : 0

        for j in 0 ..< n {
            result[j] ^= row2[j]
            result[n + j] ^= row2[n + j]
        }

        return result
    }
}
