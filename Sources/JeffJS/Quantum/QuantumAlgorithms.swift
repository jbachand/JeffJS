// QuantumAlgorithms.swift
// Quantum algorithms implemented on the JeffJS QuantumCircuit API.
//
// Ported from quantum_algorithms.py and shor_iterative.py. Each algorithm
// is a static method on the QuantumAlgorithms enum. All circuits use
// QuantumCircuit for gate operations and deterministic SplitMix64 for
// measurement randomness.
//
// Algorithms:
//   1. Deutsch-Jozsa  — constant vs balanced, one query
//   2. Bernstein-Vazirani — recover secret string in one query
//   3. Toffoli (CCX) — Clifford+T decomposition (15 gates)
//   4. Shor's factoring — iterative phase estimation (n+1 qubits)
//   5. Quantum teleportation — transfer state via entanglement
//   6. Superdense coding — send 2 classical bits via 1 qubit

import Foundation

// MARK: - Result Types

/// Result of the Deutsch-Jozsa algorithm.
struct DeutschJozsaResult {
    let isConstant: Bool
    let measurements: [Int]
}

/// Oracle type for Deutsch-Jozsa.
enum OracleType {
    case constant0
    case constant1
    case balanced
}

/// Result of the Bernstein-Vazirani algorithm.
struct BernsteinVaziraniResult {
    let recoveredSecret: String
    let measurements: [Int]
}

/// Result of error correction.
struct ErrorCorrectionResult {
    let errorQubit: Int
    let syndrome: (Int, Int)
    let corrected: Bool
}

/// Result of Shor's factoring algorithm.
struct ShorResult {
    let factors: (Int, Int)?
    let N: Int
    let numQubits: Int
    let numTrials: Int
}

/// Result of quantum teleportation.
struct TeleportResult {
    let aliceMeasurements: (Int, Int)
    let bobOutcome: Int
    let success: Bool
}

/// Result of superdense coding.
struct SuperdenseResult {
    let sent: (Int, Int)
    let received: (Int, Int)
    let success: Bool
}

// MARK: - Helpers

/// Modular exponentiation: (base^exp) mod modulus, using repeated squaring.
/// Equivalent to Python's pow(base, exp, mod).
private func modPow(base: Int, exp: Int, mod: Int) -> Int {
    guard mod > 1 else { return 0 }
    var result = 1
    var b = base % mod
    var e = exp
    while e > 0 {
        if e & 1 == 1 {
            result = result * b % mod
        }
        e >>= 1
        b = b * b % mod
    }
    return result
}

/// Greatest common divisor (Euclidean algorithm).
private func gcd(_ a: Int, _ b: Int) -> Int {
    var a = abs(a)
    var b = abs(b)
    while b != 0 {
        let t = b
        b = a % b
        a = t
    }
    return a
}

/// Find the denominator of the closest fraction p/q to `value` with q <= maxDenom.
/// Uses the continued fraction expansion to converge on the best rational
/// approximation, which is what extracts the period in Shor's algorithm.
private func continuedFractionDenominator(of value: Double, maxDenom: Int) -> Int {
    guard value > 0 && value < 1 else { return 1 }

    var remainder = value
    var h0 = 0, h1 = 1
    var k0 = 1, k1 = 0

    for _ in 0 ..< 64 {
        let a = Int(floor(1.0 / remainder))
        let h2 = a * h1 + h0
        let k2 = a * k1 + k0

        if k2 > maxDenom { break }

        h0 = h1; h1 = h2
        k0 = k1; k1 = k2

        remainder = 1.0 / remainder - Double(a)
        if remainder < 1e-12 { break }
    }

    return k1 > 0 ? k1 : 1
}

/// Number of bits needed to represent N: ceil(log2(N+1)).
private func bitsNeeded(_ N: Int) -> Int {
    Int(ceil(log2(Double(N + 1))))
}

// MARK: - QuantumAlgorithms

/// Namespace for quantum algorithm implementations.
/// All methods are static; the enum has no cases (unconstructable).

enum QuantumAlgorithms {

    // MARK: 1. Deutsch-Jozsa

    /// Deutsch-Jozsa algorithm: determines whether an oracle function is
    /// constant or balanced using a single quantum query.
    ///
    /// - Parameters:
    ///   - numInputQubits: number of input qubits (n). Total circuit is n+1.
    ///   - oracle: the type of oracle to apply.
    ///   - oracleBits: for balanced oracles, which input qubits participate.
    ///     If nil, all input qubits are used.
    /// - Returns: result indicating constant/balanced and the measurement outcomes.
    static func deutschJozsa(
        numInputQubits: Int,
        oracle: OracleType,
        oracleBits: [Int]? = nil,
        seed: UInt64 = 0xDECA
    ) -> DeutschJozsaResult {
        let totalQubits = numInputQubits + 1
        let ancilla = numInputQubits
        let circuit = QuantumCircuit(numQubits: totalQubits, seed: seed)

        // Step 1: Prepare ancilla in |1>
        circuit.x(ancilla)

        // Step 2: Hadamard all qubits
        for q in 0 ..< totalQubits {
            circuit.h(q)
        }

        // Step 3: Apply oracle
        switch oracle {
        case .constant0:
            // f(x) = 0 for all x -> identity (do nothing)
            break
        case .constant1:
            // f(x) = 1 for all x -> flip the ancilla unconditionally
            circuit.x(ancilla)
        case .balanced:
            // f depends on specific input qubits -> CNOT from each to ancilla
            let bits = oracleBits ?? Array(0 ..< numInputQubits)
            for q in bits {
                circuit.cnot(control: q, target: ancilla)
            }
        }

        // Step 4: Hadamard input qubits only
        for q in 0 ..< numInputQubits {
            circuit.h(q)
        }

        // Step 5: Measure input qubits
        var measurements = [Int]()
        measurements.reserveCapacity(numInputQubits)
        for q in 0 ..< numInputQubits {
            measurements.append(circuit.measure(q))
        }

        // All zeros -> constant; any non-zero -> balanced
        let isConstant = measurements.allSatisfy { $0 == 0 }
        return DeutschJozsaResult(isConstant: isConstant, measurements: measurements)
    }

    // MARK: 2. Bernstein-Vazirani

    /// Bernstein-Vazirani algorithm: recovers a secret n-bit string s from
    /// a single query to an oracle computing f(x) = s . x (mod 2).
    ///
    /// - Parameter secretString: the secret string, e.g., "10110".
    /// - Returns: the recovered secret and raw measurements.
    static func bernsteinVazirani(
        secretString: String,
        seed: UInt64 = 0xBEEF
    ) -> BernsteinVaziraniResult {
        let n = secretString.count
        let totalQubits = n + 1
        let ancilla = n
        let circuit = QuantumCircuit(numQubits: totalQubits, seed: seed)

        // Step 1: Prepare ancilla in |1>
        circuit.x(ancilla)

        // Step 2: Hadamard all qubits
        for q in 0 ..< totalQubits {
            circuit.h(q)
        }

        // Step 3: Oracle -- CNOT from qubit i to ancilla where s[i] == '1'
        let chars = Array(secretString)
        for (i, bit) in chars.enumerated() {
            if bit == "1" {
                circuit.cnot(control: i, target: ancilla)
            }
        }

        // Step 4: Hadamard input qubits
        for q in 0 ..< n {
            circuit.h(q)
        }

        // Step 5: Measure input qubits
        var measurements = [Int]()
        measurements.reserveCapacity(n)
        for q in 0 ..< n {
            measurements.append(circuit.measure(q))
        }

        let recovered = measurements.map { String($0) }.joined()
        return BernsteinVaziraniResult(recoveredSecret: recovered, measurements: measurements)
    }

    // MARK: 3. Toffoli (CCX)

    /// Apply a Toffoli (controlled-controlled-NOT) gate using the standard
    /// Clifford+T decomposition (Barenco et al. 1995 / Nielsen & Chuang Fig 4.9).
    ///
    /// 6 CNOTs + 7 T/T-dagger + 2 H = 15 gates total.
    /// Flips q2 if and only if both q0 and q1 are |1>.
    static func toffoli(circuit: QuantumCircuit, q0: Int, q1: Int, q2: Int) {
        circuit.h(q2)                              //  1. H on target
        circuit.cnot(control: q1, target: q2)      //  2. CNOT(control2, target)
        circuit.tDagger(q2)                        //  3. T-dagger on target
        circuit.cnot(control: q0, target: q2)      //  4. CNOT(control1, target)
        circuit.t(q2)                              //  5. T on target
        circuit.cnot(control: q1, target: q2)      //  6. CNOT(control2, target)
        circuit.tDagger(q2)                        //  7. T-dagger on target
        circuit.cnot(control: q0, target: q2)      //  8. CNOT(control1, target)
        circuit.t(q1)                              //  9. T on control2
        circuit.t(q2)                              // 10. T on target
        circuit.h(q2)                              // 11. H on target
        circuit.cnot(control: q0, target: q1)      // 12. CNOT(control1, control2)
        circuit.t(q0)                              // 13. T on control1
        circuit.tDagger(q1)                        // 14. T-dagger on control2
        circuit.cnot(control: q0, target: q1)      // 15. CNOT(control1, control2)
    }

    // MARK: 4. Shor's Algorithm (Iterative Phase Estimation)

    /// Shor's factoring algorithm using iterative (semi-classical) phase estimation.
    ///
    /// Uses only n+1 qubits (1 counting + n work) where n = ceil(log2(N+1)).
    /// The counting qubit is measured and recycled 2n times with classical
    /// phase corrections replacing the full QFT.
    ///
    /// - Parameters:
    ///   - N: the number to factor (must be odd and composite).
    ///   - maxTrials: maximum number of random bases to try.
    ///   - seed: PRNG seed for deterministic results.
    /// - Returns: ShorResult with factors (if found), qubit count, and trial count.
    static func shorFactor(_ N: Int, maxTrials: Int = 30, seed: UInt64 = 0xDEAD) -> ShorResult {
        // Handle trivial even case
        if N % 2 == 0 {
            return ShorResult(factors: (2, N / 2), N: N, numQubits: 2, numTrials: 0)
        }

        let nBits = bitsNeeded(N)
        let m = 2 * nBits                // phase estimation rounds
        let nWork = nBits
        let nTotal = nWork + 1           // 1 counting + n work qubits
        let countingQubit = 0
        let workOffset = 1

        // Separate RNG for choosing random bases
        var baseRng = SplitMix64(seed: 42 + UInt64(N))

        for trial in 0 ..< maxTrials {
            // Pick a random base a in [2, N-1]
            let range = UInt64(N - 2)
            let a = Int(baseRng.next() % range) + 2
            let g = gcd(a, N)
            if g > 1 {
                // Lucky: gcd(a, N) is already a factor
                return ShorResult(factors: (g, N / g), N: N, numQubits: nTotal, numTrials: trial + 1)
            }

            // Build the circuit: 1 counting qubit + nWork work qubits
            let circuit = QuantumCircuit(numQubits: nTotal, seed: seed &+ UInt64(trial))

            // Initialize work register to |1> (qubit at workOffset = LSB of work reg)
            circuit.x(workOffset)

            var measuredBits = [Int]()
            measuredBits.reserveCapacity(m)

            for roundIdx in 0 ..< m {
                let j = m - 1 - roundIdx    // phase estimation index (MSB first)

                // Reset counting qubit to |0> by flipping if last measurement was 1
                if let lastBit = measuredBits.last, lastBit == 1 {
                    circuit.x(countingQubit)
                }

                // H on counting qubit -> |+>
                circuit.h(countingQubit)

                // Controlled-U^(2^j): modular multiplication by a^(2^j) mod N
                let power = modPow(base: a, exp: 1 << j, mod: N)
                if power != 1 {
                    circuit.controlledModMult(
                        control: countingQubit,
                        workOffset: workOffset,
                        nWork: nWork,
                        a: UInt32(power),
                        N: UInt32(N)
                    )
                }

                // Phase correction from previously measured bits (semi-classical QFT)
                var correction: Float = 0.0
                for (prevIdx, bk) in measuredBits.enumerated() {
                    let distance = roundIdx - prevIdx
                    if bk == 1 {
                        correction -= 2.0 * .pi / Float(1 << (distance + 1))
                    }
                }
                if abs(correction) > 1e-10 {
                    circuit.phase(countingQubit, angle: correction)
                }

                // H on counting qubit
                circuit.h(countingQubit)

                // Measure counting qubit
                let outcome = circuit.measure(countingQubit)
                measuredBits.append(outcome)
            }

            // Construct phase estimate from measured bits (MSB first)
            var phaseInt = 0
            for (idx, b) in measuredBits.enumerated() {
                phaseInt |= (b << (m - 1 - idx))
            }
            let phaseValue = Double(phaseInt) / Double(1 << m)

            // Use continued fractions to find the period
            guard phaseValue > 0 else { continue }
            let r = continuedFractionDenominator(of: phaseValue, maxDenom: N)

            // Free the circuit's memory before trying to extract factors
            circuit.deallocate()

            // Try to extract factors from the period
            if r > 0 && r % 2 == 0 {
                let halfPow = modPow(base: a, exp: r / 2, mod: N)
                let candidates = [gcd(halfPow - 1, N), gcd(halfPow + 1, N)]
                for g in candidates {
                    if g > 1 && g < N {
                        return ShorResult(
                            factors: (g, N / g),
                            N: N,
                            numQubits: nTotal,
                            numTrials: trial + 1
                        )
                    }
                }
            }
        }

        // No factors found within maxTrials
        return ShorResult(factors: nil, N: N, numQubits: nTotal, numTrials: maxTrials)
    }

    // MARK: 5. Quantum Teleportation

    /// Quantum teleportation: transfers a quantum state from one qubit to
    /// another using entanglement and classical communication.
    ///
    /// Protocol:
    ///   - Qubit 0 (data): prepared in |+> (the state to teleport)
    ///   - Qubit 1 (alice): half of a Bell pair
    ///   - Qubit 2 (bob): other half of the Bell pair
    ///
    /// After teleportation, Bob's qubit should be in the |+> state.
    /// Verification: measure Bob in the X basis (H then measure) -- should get 0.
    static func teleport(seed: UInt64 = 0x7E1E) -> TeleportResult {
        let circuit = QuantumCircuit(numQubits: 3, seed: seed)
        let data = 0
        let alice = 1
        let bob = 2

        // Prepare data qubit in |+> state
        circuit.h(data)

        // Create Bell pair between alice and bob
        circuit.h(alice)
        circuit.cnot(control: alice, target: bob)

        // Alice's operations: entangle data with her half of the Bell pair
        circuit.cnot(control: data, target: alice)
        circuit.h(data)

        // Alice measures both her qubits
        let m0 = circuit.measure(data)
        let m1 = circuit.measure(alice)

        // Bob applies corrections based on Alice's measurements
        if m1 == 1 {
            circuit.x(bob)      // correct for alice's bit flip
        }
        if m0 == 1 {
            circuit.z(bob)      // correct for data's phase flip
        }

        // Verify Bob has |+> by measuring in X basis (apply H then measure)
        circuit.h(bob)
        let bobResult = circuit.measure(bob)

        // Success if Bob measures 0 (meaning he was in |+> before the H)
        let success = (bobResult == 0)
        return TeleportResult(
            aliceMeasurements: (m0, m1),
            bobOutcome: bobResult,
            success: success
        )
    }

    // MARK: 6. Superdense Coding

    /// Superdense coding: transmit 2 classical bits by sending 1 qubit,
    /// using a pre-shared Bell pair.
    ///
    /// Protocol:
    ///   1. Create Bell pair (qubit 0 to Alice, qubit 1 to Bob).
    ///   2. Alice encodes 2 bits by applying gates to her qubit:
    ///      - (0,0): identity
    ///      - (0,1): X
    ///      - (1,0): Z
    ///      - (1,1): X then Z (equivalently, iY)
    ///   3. Alice sends her qubit to Bob.
    ///   4. Bob applies CNOT(alice, bob) then H(alice), then measures both.
    ///   5. Measurement results = the two sent bits.
    static func superdenseCoding(
        bit0: Int,
        bit1: Int,
        seed: UInt64 = 0x5D5D
    ) -> SuperdenseResult {
        let circuit = QuantumCircuit(numQubits: 2, seed: seed)
        let aliceQubit = 0
        let bobQubit = 1

        // Create Bell pair |00> + |11> (unnormalized)
        circuit.h(aliceQubit)
        circuit.cnot(control: aliceQubit, target: bobQubit)

        // Alice encodes 2 classical bits
        if bit1 == 1 {
            circuit.x(aliceQubit)
        }
        if bit0 == 1 {
            circuit.z(aliceQubit)
        }

        // Bob decodes: CNOT then H
        circuit.cnot(control: aliceQubit, target: bobQubit)
        circuit.h(aliceQubit)

        // Measure both qubits
        let r0 = circuit.measure(aliceQubit)
        let r1 = circuit.measure(bobQubit)

        let success = (r0 == bit0 && r1 == bit1)
        return SuperdenseResult(
            sent: (bit0, bit1),
            received: (r0, r1),
            success: success
        )
    }

    // MARK: - Error Correction (3-qubit bit-flip code)

    /// Encode 1 logical qubit into 3 physical qubits (bit-flip code),
    /// introduce an error on one qubit, detect and correct it.
    /// Returns whether the correction succeeded.
    static func errorCorrection(errorQubit: Int = 1, seed: UInt64 = 0xEC01) -> ErrorCorrectionResult {
        // 5 qubits: 0 = data, 1-2 = encoded copies, 3-4 = syndrome ancillas
        let circuit = QuantumCircuit(numQubits: 5, seed: seed)

        // Prepare data qubit in |+⟩ for a non-trivial test
        circuit.h(0)

        // Encode: CNOT from data to copies (bit-flip repetition code)
        // |ψ⟩ → |ψψψ⟩ (logical qubit spread across qubits 0, 1, 2)
        circuit.cnot(control: 0, target: 1)
        circuit.cnot(control: 0, target: 2)

        // Introduce a bit-flip error on the specified qubit
        let errorTarget = min(max(errorQubit, 0), 2)
        circuit.x(errorTarget)

        // Syndrome extraction using ancilla qubits 3, 4
        // Ancilla 3 = parity of qubits 0 and 1
        circuit.cnot(control: 0, target: 3)
        circuit.cnot(control: 1, target: 3)
        // Ancilla 4 = parity of qubits 1 and 2
        circuit.cnot(control: 1, target: 4)
        circuit.cnot(control: 2, target: 4)

        // Measure syndrome ancillas
        let s0 = circuit.measure(3)
        let s1 = circuit.measure(4)

        // Decode syndrome and apply correction
        // s0=0, s1=0 → no error
        // s0=1, s1=0 → error on qubit 0
        // s0=1, s1=1 → error on qubit 1
        // s0=0, s1=1 → error on qubit 2
        if s0 == 1 && s1 == 0 {
            circuit.x(0)  // correct qubit 0
        } else if s0 == 1 && s1 == 1 {
            circuit.x(1)  // correct qubit 1
        } else if s0 == 0 && s1 == 1 {
            circuit.x(2)  // correct qubit 2
        }

        // Decode: reverse the encoding
        circuit.cnot(control: 0, target: 2)
        circuit.cnot(control: 0, target: 1)

        // Verify: measure data qubit in X basis (should get |+⟩ = 0 after H)
        circuit.h(0)
        let dataResult = circuit.measure(0)

        // If correction worked, data qubit should be |+⟩ → measure 0 after H
        let success = (dataResult == 0)

        return ErrorCorrectionResult(
            errorQubit: errorTarget,
            syndrome: (s0, s1),
            corrected: success
        )
    }
}
