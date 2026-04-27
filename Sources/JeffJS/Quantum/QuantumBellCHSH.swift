// QuantumBellCHSH.swift
// All 8 CHSH variants and GHZ O(N) streaming sampler.
//
// Implements the CHSH inequality test for all protocol variants from the
// Python chsh_prototype.py, plus the efficient GHZ correlator from
// ghz_simulator.py.
//
// Uses SplitMix64 from QuantumQubit.swift.

import Foundation

// MARK: - CHSH Variant Enum

/// The 8 CHSH protocol variants.
enum CHSHVariant: String, CaseIterable {
    /// V1: Shared random angle, independent sampling. S ~ sqrt(2).
    case naiveProbabilistic
    /// V2: Shared random angle, deterministic sign. S ~ 2 (Bell bound).
    case deterministicSign
    /// V3: Seed mutation. Broken (introduces signaling).
    case seedMutation
    /// V4: Quantum singlet state Born rule. S ~ 2*sqrt(2) (Tsirelson bound).
    case quantumSinglet
    /// V5: PR box (XOR rule). S = 4 (algebraic maximum).
    case prBox
    /// V6: Common randomness with correlated noise.
    case commonRandomness
    /// V7: Symmetric joint distribution.
    case symmetricJoint
    /// V8: Bound qubit pair (Bohmian-style). S ~ 2*sqrt(2).
    case boundQubitPair
}

// MARK: - CHSH Result

struct CHSHResult {
    /// The CHSH S-value. Quantum limit = 2*sqrt(2) ~ 2.828.
    let S: Float
    /// Per-setting correlations: (Alice angle, Bob angle, E-value).
    let correlations: [(aAngle: Float, bAngle: Float, E: Float)]
    /// Which variant was used.
    let variant: CHSHVariant
    /// Number of trials per setting pair.
    let numTrials: Int
    /// Whether the no-signaling condition was satisfied.
    let noSignaling: Bool
}

// MARK: - QuantumBellTests

enum QuantumBellTests {

    // MARK: Standard CHSH Angles

    /// Alice's measurement angles: 0 and pi/2.
    static let chshAnglesA: [Float] = [0.0, Float.pi / 2]
    /// Bob's measurement angles: pi/4 and 3*pi/4.
    static let chshAnglesB: [Float] = [Float.pi / 4, 3 * Float.pi / 4]

    // MARK: - Run CHSH

    /// Run a complete CHSH test for the given variant.
    /// Tests all 4 combinations of (Alice angle, Bob angle) and computes
    /// the S-value: S = E(a0,b0) - E(a0,b1) + E(a1,b0) + E(a1,b1).
    static func runCHSH(variant: CHSHVariant, numTrials: Int, seed: UInt64) -> CHSHResult {
        var rng = SplitMix64(seed: seed)

        var correlations: [(aAngle: Float, bAngle: Float, E: Float)] = []

        for aAngle in chshAnglesA {
            for bAngle in chshAnglesB {
                let (bitsA, bitsB) = generateBits(
                    variant: variant,
                    alphaA: aAngle,
                    alphaB: bAngle,
                    numTrials: numTrials,
                    rng: &rng
                )

                // Compute E = <A*B> where outcomes are +1/-1.
                var sum: Float = 0
                for i in 0 ..< numTrials {
                    let a = bitsA[i] == 0 ? 1 : -1
                    let b = bitsB[i] == 0 ? 1 : -1
                    sum += Float(a * b)
                }
                let E = sum / Float(numTrials)
                correlations.append((aAngle: aAngle, bAngle: bAngle, E: E))
            }
        }

        // S = E(a0,b0) - E(a0,b1) + E(a1,b0) + E(a1,b1)
        // correlations order: (a0,b0), (a0,b1), (a1,b0), (a1,b1)
        let sValue = correlations[0].E - correlations[1].E
                   + correlations[2].E + correlations[3].E

        // No-signaling check: Alice's marginal shouldn't depend on Bob's setting.
        let noSig = checkNoSignaling(variant: variant, numTrials: numTrials, rng: &rng)

        return CHSHResult(
            S: sValue,
            correlations: correlations,
            variant: variant,
            numTrials: numTrials,
            noSignaling: noSig
        )
    }

    // MARK: - Variant Dispatch

    private static func generateBits(
        variant: CHSHVariant,
        alphaA: Float,
        alphaB: Float,
        numTrials: Int,
        rng: inout SplitMix64
    ) -> (bitsA: [Int], bitsB: [Int]) {
        switch variant {
        case .naiveProbabilistic:
            return naiveProbabilistic(alphaA: alphaA, alphaB: alphaB, numTrials: numTrials, rng: &rng)
        case .deterministicSign:
            return deterministicSign(alphaA: alphaA, alphaB: alphaB, numTrials: numTrials, rng: &rng)
        case .seedMutation:
            return seedMutation(alphaA: alphaA, alphaB: alphaB, numTrials: numTrials, rng: &rng)
        case .quantumSinglet:
            return quantumSinglet(alphaA: alphaA, alphaB: alphaB, numTrials: numTrials, rng: &rng)
        case .prBox:
            return prBox(alphaA: alphaA, alphaB: alphaB, numTrials: numTrials, rng: &rng)
        case .commonRandomness:
            return commonRandomness(alphaA: alphaA, alphaB: alphaB, numTrials: numTrials, rng: &rng)
        case .symmetricJoint:
            return symmetricJoint(alphaA: alphaA, alphaB: alphaB, numTrials: numTrials, rng: &rng)
        case .boundQubitPair:
            return boundQubitPair(alphaA: alphaA, alphaB: alphaB, numTrials: numTrials, rng: &rng)
        }
    }

    // MARK: - V1: Naive Probabilistic

    /// Shared random angle theta. Each party independently samples with
    /// p = (1 + cos(theta - alpha)) / 2. Produces S ~ sqrt(2).
    private static func naiveProbabilistic(
        alphaA: Float, alphaB: Float, numTrials: Int, rng: inout SplitMix64
    ) -> (bitsA: [Int], bitsB: [Int]) {
        var bitsA = [Int]()
        var bitsB = [Int]()
        bitsA.reserveCapacity(numTrials)
        bitsB.reserveCapacity(numTrials)

        for _ in 0 ..< numTrials {
            let theta = rng.nextFloat() * 2 * Float.pi
            let pA = (1 + cos(theta - alphaA)) / 2
            let pB = (1 + cos(theta - alphaB)) / 2
            bitsA.append(rng.nextFloat() < pA ? 0 : 1)
            bitsB.append(rng.nextFloat() < pB ? 0 : 1)
        }

        return (bitsA, bitsB)
    }

    // MARK: - V2: Deterministic Sign

    /// Shared random angle theta. Output = sign(cos(theta - alpha)).
    /// Maps to +1 when cos >= 0, -1 otherwise. Produces S ~ 2 (Bell bound).
    private static func deterministicSign(
        alphaA: Float, alphaB: Float, numTrials: Int, rng: inout SplitMix64
    ) -> (bitsA: [Int], bitsB: [Int]) {
        var bitsA = [Int]()
        var bitsB = [Int]()
        bitsA.reserveCapacity(numTrials)
        bitsB.reserveCapacity(numTrials)

        for _ in 0 ..< numTrials {
            let theta = rng.nextFloat() * 2 * Float.pi
            bitsA.append(cos(theta - alphaA) >= 0 ? 0 : 1)
            bitsB.append(cos(theta - alphaB) >= 0 ? 0 : 1)
        }

        return (bitsA, bitsB)
    }

    // MARK: - V3: Seed Mutation (Broken - Signaling)

    /// Shared seed, but Alice's setting mutates the shared state.
    /// This violates no-signaling.
    private static func seedMutation(
        alphaA: Float, alphaB: Float, numTrials: Int, rng: inout SplitMix64
    ) -> (bitsA: [Int], bitsB: [Int]) {
        var bitsA = [Int]()
        var bitsB = [Int]()
        bitsA.reserveCapacity(numTrials)
        bitsB.reserveCapacity(numTrials)

        for _ in 0 ..< numTrials {
            let theta = rng.nextFloat() * 2 * Float.pi
            // Alice's measurement mutates theta (this is the signaling flaw).
            let thetaA = theta + alphaA * 0.1
            let pA = (1 + cos(thetaA - alphaA)) / 2
            // Bob sees the mutated theta.
            let pB = (1 + cos(thetaA - alphaB)) / 2
            bitsA.append(rng.nextFloat() < pA ? 0 : 1)
            bitsB.append(rng.nextFloat() < pB ? 0 : 1)
        }

        return (bitsA, bitsB)
    }

    // MARK: - V4: Quantum Singlet

    /// True quantum singlet correlations via Born rule.
    /// P(same outcome) = sin^2(delta_alpha / 2)
    /// P(different)    = cos^2(delta_alpha / 2)
    /// Produces S ~ 2*sqrt(2) (Tsirelson bound).
    private static func quantumSinglet(
        alphaA: Float, alphaB: Float, numTrials: Int, rng: inout SplitMix64
    ) -> (bitsA: [Int], bitsB: [Int]) {
        var bitsA = [Int]()
        var bitsB = [Int]()
        bitsA.reserveCapacity(numTrials)
        bitsB.reserveCapacity(numTrials)

        let delta = alphaA - alphaB
        let pSame = sin(delta / 2) * sin(delta / 2)

        for _ in 0 ..< numTrials {
            // Alice's outcome is uniformly random.
            let a = rng.nextFloat() < 0.5 ? 0 : 1
            // Bob's outcome is correlated via the singlet Born rule.
            let r = rng.nextFloat()
            let b: Int
            if r < pSame {
                b = a       // same outcome
            } else {
                b = 1 - a   // different outcome
            }
            bitsA.append(a)
            bitsB.append(b)
        }

        return (bitsA, bitsB)
    }

    // MARK: - V5: PR Box

    /// Popescu-Rohrlich box: a = random, b = a XOR (x AND y).
    /// Here x, y are the binary labels for Alice's and Bob's settings.
    /// Achieves S = 4 (algebraic maximum). Violates Tsirelson bound.
    private static func prBox(
        alphaA: Float, alphaB: Float, numTrials: Int, rng: inout SplitMix64
    ) -> (bitsA: [Int], bitsB: [Int]) {
        var bitsA = [Int]()
        var bitsB = [Int]()
        bitsA.reserveCapacity(numTrials)
        bitsB.reserveCapacity(numTrials)

        // Map angles to binary setting labels.
        // x = 0 for alphaA == 0, x = 1 for alphaA == pi/2
        // y = 0 for alphaB == pi/4, y = 1 for alphaB == 3*pi/4
        let x = abs(alphaA) > 0.01 ? 1 : 0
        let y = abs(alphaB - Float.pi / 4) > 0.01 ? 1 : 0

        for _ in 0 ..< numTrials {
            let a = rng.nextFloat() < 0.5 ? 0 : 1
            // PR box: b = a XOR (x AND y)
            let b = a ^ (x & y)
            bitsA.append(a)
            bitsB.append(b)
        }

        return (bitsA, bitsB)
    }

    // MARK: - V6: Common Randomness

    /// Shared random angle with correlated Gaussian noise added.
    private static func commonRandomness(
        alphaA: Float, alphaB: Float, numTrials: Int, rng: inout SplitMix64
    ) -> (bitsA: [Int], bitsB: [Int]) {
        var bitsA = [Int]()
        var bitsB = [Int]()
        bitsA.reserveCapacity(numTrials)
        bitsB.reserveCapacity(numTrials)

        let noiseScale: Float = 0.3

        for _ in 0 ..< numTrials {
            let theta = rng.nextFloat() * 2 * Float.pi
            // Box-Muller for Gaussian noise.
            let u1 = max(rng.nextFloat(), 1e-10)
            let u2 = rng.nextFloat()
            let gaussA = sqrtf(-2 * logf(u1)) * cos(2 * Float.pi * u2) * noiseScale
            let gaussB = sqrtf(-2 * logf(u1)) * sin(2 * Float.pi * u2) * noiseScale

            let pA = (1 + cos(theta + gaussA - alphaA)) / 2
            let pB = (1 + cos(theta + gaussB - alphaB)) / 2
            bitsA.append(rng.nextFloat() < pA ? 0 : 1)
            bitsB.append(rng.nextFloat() < pB ? 0 : 1)
        }

        return (bitsA, bitsB)
    }

    // MARK: - V7: Symmetric Joint

    /// Symmetric joint distribution: shared angle determines a joint outcome
    /// via a symmetric conditional probability table.
    private static func symmetricJoint(
        alphaA: Float, alphaB: Float, numTrials: Int, rng: inout SplitMix64
    ) -> (bitsA: [Int], bitsB: [Int]) {
        var bitsA = [Int]()
        var bitsB = [Int]()
        bitsA.reserveCapacity(numTrials)
        bitsB.reserveCapacity(numTrials)

        let delta = alphaA - alphaB

        for _ in 0 ..< numTrials {
            // Symmetric joint: p(00) = p(11) = cos^2(delta/2)/2,
            // p(01) = p(10) = sin^2(delta/2)/2.
            let pSame = cos(delta / 2) * cos(delta / 2)
            let r = rng.nextFloat()

            if r < pSame / 2 {
                bitsA.append(0); bitsB.append(0)  // 00
            } else if r < pSame {
                bitsA.append(1); bitsB.append(1)  // 11
            } else if r < pSame + (1 - pSame) / 2 {
                bitsA.append(0); bitsB.append(1)  // 01
            } else {
                bitsA.append(1); bitsB.append(0)  // 10
            }
        }

        return (bitsA, bitsB)
    }

    // MARK: - V8: Bound Qubit Pair (Bohmian-style)

    /// Shared hidden angle phi. Alice samples via Born rule for her setting.
    /// Her outcome non-locally collapses the shared state to the singlet
    /// conjugate, and Bob samples from that collapsed state.
    /// Achieves S ~ 2*sqrt(2).
    private static func boundQubitPair(
        alphaA: Float, alphaB: Float, numTrials: Int, rng: inout SplitMix64
    ) -> (bitsA: [Int], bitsB: [Int]) {
        var bitsA = [Int]()
        var bitsB = [Int]()
        bitsA.reserveCapacity(numTrials)
        bitsB.reserveCapacity(numTrials)

        for _ in 0 ..< numTrials {
            // Shared hidden variable: angle on the Bloch sphere.
            let phi = rng.nextFloat() * 2 * Float.pi

            // Alice's Born rule: P(0|phi, alphaA) = cos^2((phi - alphaA)/2)
            let pA0 = cos((phi - alphaA) / 2) * cos((phi - alphaA) / 2)
            let a: Int
            if rng.nextFloat() < pA0 {
                a = 0
            } else {
                a = 1
            }

            // Non-local phase collapse: Alice's outcome determines the
            // effective angle for Bob. If Alice got 0, the state collapses
            // to alignment with alphaA; if 1, to anti-alignment.
            let collapsedAngle: Float
            if a == 0 {
                collapsedAngle = alphaA       // aligned with Alice's axis
            } else {
                collapsedAngle = alphaA + Float.pi  // anti-aligned
            }

            // Bob's Born rule against the collapsed state (singlet correlation).
            // P(0|collapsed, alphaB) = sin^2((collapsedAngle - alphaB)/2)
            // The sin^2 (rather than cos^2) gives the singlet anti-correlation.
            let pB0 = sin((collapsedAngle - alphaB) / 2) * sin((collapsedAngle - alphaB) / 2)
            let b: Int
            if rng.nextFloat() < pB0 {
                b = 0
            } else {
                b = 1
            }

            bitsA.append(a)
            bitsB.append(b)
        }

        return (bitsA, bitsB)
    }

    // MARK: - No-Signaling Check

    /// Check the no-signaling condition: Alice's marginal distribution should
    /// not depend on Bob's measurement setting (and vice versa).
    private static func checkNoSignaling(
        variant: CHSHVariant, numTrials: Int, rng: inout SplitMix64
    ) -> Bool {
        // Run Alice with fixed alphaA = 0 but two different Bob settings.
        let alphaA: Float = 0
        let (bitsA_b0, _) = generateBits(
            variant: variant,
            alphaA: alphaA,
            alphaB: chshAnglesB[0],
            numTrials: numTrials,
            rng: &rng
        )
        let (bitsA_b1, _) = generateBits(
            variant: variant,
            alphaA: alphaA,
            alphaB: chshAnglesB[1],
            numTrials: numTrials,
            rng: &rng
        )

        // Compare Alice's marginal probabilities.
        let meanA_b0 = Float(bitsA_b0.reduce(0, +)) / Float(numTrials)
        let meanA_b1 = Float(bitsA_b1.reduce(0, +)) / Float(numTrials)

        // Allow statistical fluctuation: |difference| < 5 / sqrt(N).
        let tolerance = 5.0 / sqrtf(Float(numTrials))
        return abs(meanA_b0 - meanA_b1) < tolerance
    }

    // MARK: - GHZ Streaming Sampler

    /// O(N) streaming GHZ correlation sampler.
    ///
    /// Uses the interference-at-last-qubit trick: for qubits 1..N-1, the
    /// measurement probability has no interference between the |0...0> and
    /// |1...1> branches. Only the last qubit sees interference because its
    /// outcome is fully determined by the accumulated coefficients.
    ///
    /// For each qubit k (not the last):
    ///   P(+1) = a^2 cos^2(alpha_k/2) + b^2 sin^2(alpha_k/2)
    ///
    /// For the last qubit N:
    ///   P(+1) = (a cos(alpha_N/2) + b sin(alpha_N/2))^2
    ///
    /// where a, b track the amplitudes of the |0...0> and |1...1> branches
    /// with correct sign updates at each step.
    static func ghzCorrelation(
        numQubits: Int, angles: [Float], numTrials: Int, seed: UInt64
    ) -> Float {
        precondition(angles.count == numQubits, "Need one angle per qubit")
        var rng = SplitMix64(seed: seed)
        var paritySum: Float = 0

        for _ in 0 ..< numTrials {
            // Start with GHZ state: (|0...0> + |1...1>) / sqrt(2)
            var a: Float = 1.0 / sqrtf(2.0)  // amplitude of |0...0> branch
            var b: Float = 1.0 / sqrtf(2.0)  // amplitude of |1...1> branch
            var parity = 0

            for k in 0 ..< numQubits {
                let alpha = angles[k]
                let cosHalf = cos(alpha / 2)
                let sinHalf = sin(alpha / 2)

                if k < numQubits - 1 {
                    // Not the last qubit: no interference.
                    let p0 = a * a * cosHalf * cosHalf + b * b * sinHalf * sinHalf
                    let r = rng.nextFloat()

                    if r < p0 {
                        // Outcome +1 (eigenvalue, mapped from bit 0).
                        // Update coefficients: a *= cos(alpha/2), b *= sin(alpha/2),
                        // then renormalize.
                        a = a * cosHalf
                        b = b * sinHalf
                    } else {
                        // Outcome -1 (from bit 1).
                        parity ^= 1
                        // a *= sin(alpha/2), b *= -cos(alpha/2)
                        // (the minus sign comes from the |1> branch phase).
                        let newA = a * sinHalf
                        let newB = -b * cosHalf
                        a = newA
                        b = newB
                    }

                    // Renormalize.
                    let norm = sqrtf(a * a + b * b)
                    if norm > 0 {
                        a /= norm
                        b /= norm
                    }
                } else {
                    // Last qubit: interference.
                    let ampPlus = a * cosHalf + b * sinHalf
                    let p0 = ampPlus * ampPlus
                    let r = rng.nextFloat()

                    if r >= p0 {
                        parity ^= 1
                    }
                }
            }

            // Convert parity to +1/-1.
            paritySum += parity == 0 ? 1.0 : -1.0
        }

        return paritySum / Float(numTrials)
    }

    /// Exact GHZ correlation for N qubits with given measurement angles.
    /// For N-qubit GHZ state measured in the XY plane at angles alpha_k:
    ///   <M1 M2 ... MN> = cos(alpha_1 + alpha_2 + ... + alpha_N)
    /// This is the Mermin inequality prediction.
    static func ghzExactCorrelation(angles: [Float]) -> Float {
        let totalAngle = angles.reduce(0, +)
        return cos(totalAngle)
    }
}
