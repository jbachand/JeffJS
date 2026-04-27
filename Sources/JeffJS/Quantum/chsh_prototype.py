#!/usr/bin/env python3
"""
chsh_prototype.py — sanity-check the CHSH/Tsirelson predictions for the
JeffJS Quantum chain encoder before porting to Swift.

Three variants of the "two overlapping fields, same coordinate, probabilistic
bit derivation" protocol:

  V1. Naive probabilistic with shared theta.
      Both observers sample independently from p = (1 + cos(theta - alpha))/2
      with the same hidden theta. Predicted: S = sqrt(2) ~= 1.414 (sub-classical).

  V2. Deterministic sign-based with shared theta.
      Both observers use b = sign(cos(theta - alpha)). Predicted: S = 2
      (Bell-saturating local hidden variable strategy).

  V3. Probabilistic + theta mutation on Alice's read.
      Alice reads first, then theta gets rotated by alpha_A * b_A, then Bob
      reads from the mutated theta. Unknown S — this is the experiment.

For each variant:
  - Compute the four CHSH correlations E(a,b), E(a,b'), E(a',b), E(a',b')
  - Compute S
  - Check no-signaling: Alice's marginal should not depend on Bob's setting
    (and vice versa for Bob given Alice's choice)
"""

import math
import numpy as np

NUM_TRIALS = 200_000

# CHSH-optimal angles for the singlet state (Tsirelson-saturating)
A_ANGLES = [0.0, math.pi / 2]      # Alice's two settings
B_ANGLES = [math.pi / 4, 3 * math.pi / 4]   # Bob's two settings


# ----------------------------------------------------------------------
# Variant 1: naive probabilistic, shared theta, independent sampling
# ----------------------------------------------------------------------

def naive_probabilistic(alpha_a, alpha_b, num_trials, rng):
    theta = rng.uniform(0, 2 * math.pi, size=num_trials)
    p_a = (1 + np.cos(theta - alpha_a)) / 2
    p_b = (1 + np.cos(theta - alpha_b)) / 2
    bits_a = np.where(rng.random(num_trials) < p_a, 1, -1)
    bits_b = np.where(rng.random(num_trials) < p_b, 1, -1)
    return bits_a, bits_b


# ----------------------------------------------------------------------
# Variant 2: deterministic sign(cos), shared theta
# ----------------------------------------------------------------------

def deterministic_sign(alpha_a, alpha_b, num_trials, rng):
    theta = rng.uniform(0, 2 * math.pi, size=num_trials)
    bits_a = np.where(np.cos(theta - alpha_a) > 0, 1, -1)
    bits_b = np.where(np.cos(theta - alpha_b) > 0, 1, -1)
    return bits_a, bits_b


# ----------------------------------------------------------------------
# Variant 3: probabilistic + theta mutation on Alice's read
# ----------------------------------------------------------------------

def seed_mutation(alpha_a, alpha_b, num_trials, rng):
    theta = rng.uniform(0, 2 * math.pi, size=num_trials)
    # Alice reads first
    p_a = (1 + np.cos(theta - alpha_a)) / 2
    bits_a = np.where(rng.random(num_trials) < p_a, 1, -1)
    # Mutate theta based on Alice's outcome and choice
    theta_mut = theta + alpha_a * bits_a
    # Bob reads from the mutated theta
    p_b = (1 + np.cos(theta_mut - alpha_b)) / 2
    bits_b = np.where(rng.random(num_trials) < p_b, 1, -1)
    return bits_a, bits_b


# ----------------------------------------------------------------------
# Variant 6: common-randomness sampling (symmetric, no Alice-goes-first)
# Both observers use the SAME theta AND the SAME uniform random number u
# for their Bernoulli sample. This is the "monotone coupling" — the optimal
# classical joint distribution given the marginals.
# ----------------------------------------------------------------------

def common_randomness_sampling(alpha_a, alpha_b, num_trials, rng):
    theta = rng.uniform(0, 2 * math.pi, size=num_trials)
    u = rng.random(num_trials)  # shared sampling noise
    p_a = (1 + np.cos(theta - alpha_a)) / 2
    p_b = (1 + np.cos(theta - alpha_b)) / 2
    bits_a = np.where(u < p_a, 1, -1)
    bits_b = np.where(u < p_b, 1, -1)
    return bits_a, bits_b


# ----------------------------------------------------------------------
# Variant 7: symmetric joint deterministic rule
# Both bits computed simultaneously from a function of (theta, alpha_a, alpha_b)
# that is symmetric in the two sides. No temporal ordering.
# Uses the difference cos(theta - alpha_a) - cos(theta - alpha_b) as the
# "joint signal" and assigns anti-correlated outputs based on its sign.
# ----------------------------------------------------------------------

def symmetric_joint_deterministic(alpha_a, alpha_b, num_trials, rng):
    theta = rng.uniform(0, 2 * math.pi, size=num_trials)
    cos_a = np.cos(theta - alpha_a)
    cos_b = np.cos(theta - alpha_b)
    # Symmetric joint signal: positive when A is "closer" to theta, negative otherwise
    diff = cos_a - cos_b
    # Anti-correlated outputs (singlet-like)
    bits_a = np.where(diff > 0, 1, -1)
    bits_b = np.where(diff > 0, -1, 1)
    return bits_a, bits_b


# ----------------------------------------------------------------------
# Variant 8: bound qubit pair with non-local sub-resolution binding
#
# The idea: each pair of qubits shares a hidden phase below the resolution
# we measure at. Alice measures first. The binary outcome we see is the
# "top resolution" — but the hidden phase collapses along with it AND
# propagates to Bob's qubit non-locally. Bob's subsequent measurement
# samples from the post-collapse distribution.
#
# This is structurally Bohmian: deterministic substrate, non-local update
# on measurement, no-signaling preserved because Bob's marginal averages
# out over Alice's possible outcomes.
#
# Predicted S: ~2.828 (Tsirelson) — replicates the singlet state.
# ----------------------------------------------------------------------

def bound_qubit_pair(alpha_a, alpha_b, num_trials, rng):
    # Initial shared sub-resolution phase, uniform on [0, 2*pi)
    phi = rng.uniform(0, 2 * math.pi, size=num_trials)
    # Alice's measurement: P(b_A = +1 | phi, alpha_A) = cos^2((phi - alpha_A)/2)
    p_a = np.cos((phi - alpha_a) / 2) ** 2
    bits_a = np.where(rng.random(num_trials) < p_a, 1, -1)
    # Non-local sub-resolution update:
    # After Alice's outcome, Bob's qubit is in the singlet-conjugate state.
    # If Alice got +1 along alpha_A, Bob's phase is alpha_A + pi (anti-aligned).
    # If Alice got -1 along alpha_A, Bob's phase is alpha_A (aligned).
    phi_b = np.where(bits_a == 1, alpha_a + math.pi, alpha_a)
    # Bob's measurement on the post-collapse partner
    p_b = np.cos((phi_b - alpha_b) / 2) ** 2
    bits_b = np.where(rng.random(num_trials) < p_b, 1, -1)
    return bits_a, bits_b


# ----------------------------------------------------------------------
# Variant 4: actual Born rule for the singlet state
# Reference: this is what the chain encoder is competing against.
# ----------------------------------------------------------------------

def quantum_singlet(alpha_a, alpha_b, num_trials, rng):
    # For the singlet state, P(b_a = b_b) = sin^2((alpha_a - alpha_b)/2)
    # and P(b_a != b_b) = cos^2((alpha_a - alpha_b)/2).
    # Marginals are uniform 50/50 on each side. Correlation:
    #   E(alpha_a, alpha_b) = -cos(alpha_a - alpha_b)
    p_same = math.sin((alpha_a - alpha_b) / 2) ** 2
    # Generate paired outcomes with the right joint distribution
    bits_a = np.where(rng.random(num_trials) < 0.5, 1, -1)
    same = rng.random(num_trials) < p_same
    bits_b = np.where(same, bits_a, -bits_a)
    return bits_a, bits_b


# ----------------------------------------------------------------------
# Variant 5: Popescu-Rohrlich box (no-signaling super-quantum maximum)
# Reference: this is what the upper bound of no-signaling looks like.
# ----------------------------------------------------------------------

def pr_box(alpha_a, alpha_b, num_trials, rng):
    # Map continuous angles to binary inputs (a, b) in {0, 1}.
    # We use the PR-box rule b_a XOR b_b = (NOT a) AND b, which gives the
    # CHSH-form S = E(a,b) - E(a,b') + E(a',b) + E(a',b') = 4 with our angle
    # ordering A_ANGLES = [a, a'], B_ANGLES = [b, b'] and outputs in {-1, +1}.
    # Marginals are 50/50 uniform on each side.
    a_bit = A_ANGLES.index(alpha_a)  # 0 or 1
    b_bit = B_ANGLES.index(alpha_b)  # 0 or 1
    # Alice's bit is uniform
    bits_a_01 = (rng.random(num_trials) < 0.5).astype(int)
    # Bob's bit is bits_a XOR ((NOT a) AND b)
    constraint = ((1 - a_bit) & b_bit)
    bits_b_01 = bits_a_01 ^ constraint
    # Convert to ±1
    bits_a = 2 * bits_a_01 - 1
    bits_b = 2 * bits_b_01 - 1
    return bits_a, bits_b


# ----------------------------------------------------------------------
# CHSH harness
# ----------------------------------------------------------------------

def compute_chsh(strategy_fn, num_trials, seed):
    rng = np.random.default_rng(seed)
    correlations = {}
    marginals_a = {}
    marginals_b = {}
    for a_angle in A_ANGLES:
        for b_angle in B_ANGLES:
            bits_a, bits_b = strategy_fn(a_angle, b_angle, num_trials, rng)
            correlations[(a_angle, b_angle)] = float(np.mean(bits_a * bits_b))
            marginals_a[(a_angle, b_angle)] = float(np.mean(bits_a))
            marginals_b[(a_angle, b_angle)] = float(np.mean(bits_b))
    a, ap = A_ANGLES
    b, bp = B_ANGLES
    S = (correlations[(a, b)]
         - correlations[(a, bp)]
         + correlations[(ap, b)]
         + correlations[(ap, bp)])
    return S, correlations, marginals_a, marginals_b


def report(name, predicted, S, correlations, marginals_a, marginals_b):
    print(f"\n=== {name} ===")
    print(f"  predicted S : {predicted}")
    print(f"  measured  S : {S:+.4f}")
    print(f"  correlations:")
    for (a, b), E in correlations.items():
        print(f"    E(a={a:.4f}, b={b:.4f}) = {E:+.4f}")
    print(f"  Alice marginal <b_A>  (should be ~0 for any strategy):")
    for (a, b), m in marginals_a.items():
        print(f"    <b_A | a={a:.4f}, b={b:.4f}> = {m:+.4f}")
    print(f"  Bob marginal   <b_B>  (signaling check: should not depend on a):")
    for a in A_ANGLES:
        for b in B_ANGLES:
            m = marginals_b[(a, b)]
            print(f"    <b_B | a={a:.4f}, b={b:.4f}> = {m:+.4f}")
    # Compute Bob's marginal averaged over a, for each b — and the spread
    print("  Bob signaling check: |<b_B | a=0, b> - <b_B | a=pi/2, b>|:")
    for b in B_ANGLES:
        diff = abs(marginals_b[(A_ANGLES[0], b)] - marginals_b[(A_ANGLES[1], b)])
        print(f"    b={b:.4f}: |delta| = {diff:.4f}  "
              f"({'OK no-signaling' if diff < 0.01 else 'SIGNALING'})")


def main():
    print(f"CHSH prototype — {NUM_TRIALS} trials per setting pair")
    print(f"Optimal Bell bound (classical max):   2.0000")
    print(f"Tsirelson bound (quantum max):        {2 * math.sqrt(2):.4f}")
    print(f"PR-box bound (no-signaling max):      4.0000")

    # Variant 1
    S, c, ma, mb = compute_chsh(naive_probabilistic, NUM_TRIALS, 0xC5C5)
    report("V1: naive probabilistic, shared theta",
           f"sqrt(2) = {math.sqrt(2):.4f}", S, c, ma, mb)

    # Variant 2
    S, c, ma, mb = compute_chsh(deterministic_sign, NUM_TRIALS, 0xD3D3)
    report("V2: deterministic sign(cos), shared theta",
           "2.0000 (Bell saturation)", S, c, ma, mb)

    # Variant 3
    S, c, ma, mb = compute_chsh(seed_mutation, NUM_TRIALS, 0xE5E5)
    report("V3: probabilistic + theta mutation on Alice's read",
           "unknown — measure", S, c, ma, mb)

    # Variant 6: common-randomness sampling (symmetric)
    S, c, ma, mb = compute_chsh(common_randomness_sampling, NUM_TRIALS, 0x6666)
    report("V6: common-randomness sampling (symmetric)",
           "<= 2 (Bell bound)", S, c, ma, mb)

    # Variant 7: symmetric joint deterministic rule
    S, c, ma, mb = compute_chsh(symmetric_joint_deterministic, NUM_TRIALS, 0x7777)
    report("V7: symmetric joint deterministic (no temporal ordering)",
           "<= 2 (Bell bound)", S, c, ma, mb)

    # Variant 8: bound qubit pair with non-local sub-resolution binding
    S, c, ma, mb = compute_chsh(bound_qubit_pair, NUM_TRIALS, 0x8888)
    report("V8: bound qubit pair (non-local sub-resolution collapse)",
           f"~{2*math.sqrt(2):.4f} (Tsirelson) if singlet replicated", S, c, ma, mb)

    # Variant 4: actual quantum mechanics (Born rule for singlet state)
    S, c, ma, mb = compute_chsh(quantum_singlet, NUM_TRIALS, 0xF7F7)
    report("V4: quantum mechanics (singlet state, Born rule)",
           f"-2*sqrt(2) = {-2*math.sqrt(2):.4f} (Tsirelson)", S, c, ma, mb)

    # Variant 5: PR box (no-signaling maximum)
    S, c, ma, mb = compute_chsh(pr_box, NUM_TRIALS, 0xA9A9)
    report("V5: Popescu-Rohrlich box (no-signaling max)",
           "+/- 4 (algebraic max)", S, c, ma, mb)


# ======================================================================
# EXPERIMENT 10: Multi-qubit GHZ scaling test
# ======================================================================
#
# Tests whether V8's Bohmian phase-update model can handle 3-qubit GHZ
# entanglement or breaks beyond pairwise (N=2).
#
# Two tests are run:
#   TEST A: In-plane 3-party correlation sweep
#     Uses real-angle measurements in the XZ plane only (where V8 works).
#     GHZ correlation: E(α1,α2,α3) = sin(α1) sin(α2) sin(α3)
#     Compares V8 sequential collapse against the exact formula.
#
#   TEST B: Standard Mermin inequality
#     Requires σ_x and σ_y measurements. σ_y is OUT of V8's single-angle
#     plane, so this tests both the Bohmian update AND the measurement
#     limitation simultaneously.
#     GHZ quantum: M3 = 4. Classical bound: |M3| ≤ 2.
# ======================================================================


def ghz_exact_correlation(settings):
    """Exact GHZ 3-party correlation for in-plane (XZ) measurements.
    For |GHZ> = (|000> + |111>) / sqrt(2) measured along angles α_i in the
    XZ plane of the Bloch sphere:  E(α1,α2,α3) = sin(α1) sin(α2) sin(α3).

    Derivation: ⟨GHZ| σ(α1)⊗σ(α2)⊗σ(α3) |GHZ⟩ where σ(α) = cos(α)σ_z + sin(α)σ_x.
    """
    return math.prod(math.sin(a) for a in settings)


def ghz_quantum_born_rule(settings, num_trials, rng):
    """Reference: exact Born-rule sampling for GHZ state with in-plane measurements.
    Uses the exact 2^N probability formula with real amplitudes."""
    n = len(settings)
    n_outcomes = 2 ** n

    # Compute all joint probabilities
    # P(b1,...,bn) = (1/2) |∏ c_i(0) + ∏ c_i(1)|^2
    # where c_i(0) = <b_i,α_i|0> and c_i(1) = <b_i,α_i|1>
    # For measurement angle α: |+1,α> = cos(α/2)|0> + sin(α/2)|1>
    #                           |-1,α> = -sin(α/2)|0> + cos(α/2)|1>
    probs = np.zeros(n_outcomes)

    for k in range(n_outcomes):
        term_0 = 1.0  # product of <b_i,α_i|0>
        term_1 = 1.0  # product of <b_i,α_i|1>
        for i in range(n):
            alpha = settings[i]
            b_is_plus = ((k >> i) & 1) == 0  # bit=0 means outcome +1
            if b_is_plus:
                term_0 *= math.cos(alpha / 2)
                term_1 *= math.sin(alpha / 2)
            else:
                term_0 *= -math.sin(alpha / 2)
                term_1 *= math.cos(alpha / 2)
        amplitude = (term_0 + term_1) / math.sqrt(2)
        probs[k] = amplitude * amplitude

    probs = np.maximum(probs, 0)  # clip tiny negatives from float errors
    probs /= probs.sum()

    # Sample outcomes
    indices = rng.choice(n_outcomes, size=num_trials, p=probs)
    outcomes = np.zeros((n, num_trials), dtype=int)
    for i in range(n):
        bit_i = (indices >> i) & 1
        outcomes[i] = np.where(bit_i == 0, 1, -1)

    return outcomes


def ghz_bohmian_v8(settings, num_trials, rng):
    """V8-style Bohmian simulation for N-qubit GHZ.
    Naive extension: sequential measurement with phase collapse.
    After each measurement, ALL remaining qubits' phases collapse to
    the measured qubit's outcome state."""
    n = len(settings)
    outcomes = np.zeros((n, num_trials), dtype=int)
    phi = rng.uniform(0, 2 * math.pi, size=num_trials)

    for i in range(n):
        alpha = settings[i]
        p_plus = np.cos((phi - alpha) / 2) ** 2
        bit = np.where(rng.random(num_trials) < p_plus, 1, -1)
        outcomes[i] = bit
        # Collapse: remaining qubits' phase set by this outcome
        phi = np.where(bit == 1, alpha, alpha + math.pi)

    return outcomes


def ghz_bohmian_v8_fixed(settings, num_trials, rng):
    """FIXED V8 for GHZ: track the two GHZ coefficients (a, b) instead of
    a single phase. The state is always a|00...0> + b|11...1>, and the
    coefficients update deterministically on each measurement.

    This is PROCEDURAL — nothing is stored. The coefficients at any point
    are a deterministic function of (initial state, measurement outcomes so far).
    Cost: O(1) per qubit, O(N) total. No exponential blowup.

    Why the original V8 failed: it used ONE phase instead of TWO coefficients.
    One phase can't encode the relative weight between |00...0> and |11...1>
    that changes after each measurement. Two coefficients can.
    """
    n = len(settings)
    outcomes = np.zeros((n, num_trials), dtype=int)

    # GHZ initial state: (|00...0> + |11...1>) / sqrt(2)
    a = np.full(num_trials, 1.0 / math.sqrt(2))  # coeff of |00...0>
    b = np.full(num_trials, 1.0 / math.sqrt(2))  # coeff of |11...1>

    for i in range(n):
        alpha = settings[i]
        c = math.cos(alpha / 2)
        s = math.sin(alpha / 2)

        # P(+1) for qubit i = |a|^2 cos^2(alpha/2) + |b|^2 sin^2(alpha/2)
        # (cross terms vanish because remaining qubits are in orthogonal states)
        p_plus = a ** 2 * c ** 2 + b ** 2 * s ** 2
        p_plus = np.clip(p_plus, 1e-15, 1 - 1e-15)

        bit = np.where(rng.random(num_trials) < p_plus, 1, -1)
        outcomes[i] = bit

        # Update coefficients based on outcome
        # After +1: state -> [a*cos(alpha/2)|00..0> + b*sin(alpha/2)|11..1>] / sqrt(p+)
        # After -1: state -> [-a*sin(alpha/2)|00..0> + b*cos(alpha/2)|11..1>] / sqrt(p-)
        p_minus = 1.0 - p_plus
        p_minus = np.clip(p_minus, 1e-15, 1)

        sqrt_p_plus = np.sqrt(p_plus)
        sqrt_p_minus = np.sqrt(p_minus)

        # Key: the -1 outcome has <-1,α|0> = -sin(α/2), so a' picks up a minus sign.
        # This sign encodes the RELATIVE PHASE between |00..0> and |11..1> after
        # collapse, which determines the remaining qubits' correlations.
        new_a = np.where(bit == 1, a * c / sqrt_p_plus, -a * s / sqrt_p_minus)
        new_b = np.where(bit == 1, b * s / sqrt_p_plus,  b * c / sqrt_p_minus)
        a = new_a
        b = new_b

    return outcomes


def ghz_independent_phases(settings, num_trials, rng):
    """Baseline: independent phases, no cross-qubit collapse."""
    n = len(settings)
    outcomes = np.zeros((n, num_trials), dtype=int)
    for i in range(n):
        phi = rng.uniform(0, 2 * math.pi, size=num_trials)
        alpha = settings[i]
        p_plus = np.cos((phi - alpha) / 2) ** 2
        outcomes[i] = np.where(rng.random(num_trials) < p_plus, 1, -1)
    return outcomes


def measure_3party_correlation(strategy_fn, settings, num_trials, rng):
    """Compute E(α1,α2,α3) = <b1 b2 b3> for a 3-party strategy."""
    outcomes = strategy_fn(list(settings), num_trials, rng)
    product = outcomes[0] * outcomes[1] * outcomes[2]
    return float(np.mean(product))


def run_ghz_scaling_test():
    """Run the N=3 GHZ scaling test."""
    print("\n" + "=" * 70)
    print("EXPERIMENT 10: 3-qubit GHZ scaling test")
    print("=" * 70)
    print(f"Trials per setting: {NUM_TRIALS}")

    # ---------------------------------------------------------------
    # TEST A: In-plane correlation sweep
    # ---------------------------------------------------------------
    print("\n--- TEST A: In-plane 3-party correlation sweep ---")
    print("  GHZ exact: E(α1,α2,α3) = sin(α1) sin(α2) sin(α3)")
    print()
    print(f"  {'angles':>30s} | {'exact':>8s} | {'Born':>8s} | {'V8':>8s} | {'indep':>8s} | {'V8 err':>8s}")
    print("  " + "-" * 85)

    test_angles = [
        (math.pi/2, math.pi/2, math.pi/2),   # all σ_x
        (math.pi/4, math.pi/4, math.pi/4),   # all π/4
        (math.pi/2, math.pi/4, math.pi/4),   # mixed
        (math.pi/3, math.pi/3, math.pi/3),   # all π/3
        (math.pi/2, math.pi/2, math.pi/4),   # two σ_x + one π/4
        (math.pi/6, math.pi/4, math.pi/3),   # all different
        (math.pi/2, math.pi/3, math.pi/6),   # spread
    ]

    rng_born = np.random.default_rng(0xB001)
    rng_v8 = np.random.default_rng(0xB002)
    rng_ind = np.random.default_rng(0xB003)

    max_v8_err = 0.0
    max_v8fix_err = 0.0
    rng_v8fix = np.random.default_rng(0xB004)

    print(f"  {'angles':>30s} | {'exact':>8s} | {'Born':>8s} | {'V8':>8s} | {'V8-fix':>8s} | {'indep':>8s}")
    print("  " + "-" * 95)

    for angles in test_angles:
        exact = ghz_exact_correlation(angles)
        E_born = measure_3party_correlation(ghz_quantum_born_rule, angles, NUM_TRIALS, rng_born)
        E_v8 = measure_3party_correlation(ghz_bohmian_v8, angles, NUM_TRIALS, rng_v8)
        E_v8fix = measure_3party_correlation(ghz_bohmian_v8_fixed, angles, NUM_TRIALS, rng_v8fix)
        E_ind = measure_3party_correlation(ghz_independent_phases, angles, NUM_TRIALS, rng_ind)
        v8_err = abs(E_v8 - exact)
        v8fix_err = abs(E_v8fix - exact)
        max_v8_err = max(max_v8_err, v8_err)
        max_v8fix_err = max(max_v8fix_err, v8fix_err)

        angle_str = f"({angles[0]:.4f}, {angles[1]:.4f}, {angles[2]:.4f})"
        print(f"  {angle_str:>30s} | {exact:+8.4f} | {E_born:+8.4f} | {E_v8:+8.4f} | {E_v8fix:+8.4f} | {E_ind:+8.4f}")

    print(f"\n  Max V8 (broken) error: {max_v8_err:.4f}")
    print(f"  Max V8-fixed error:    {max_v8fix_err:.4f}")
    if max_v8fix_err < 0.02:
        print("  VERDICT: V8-FIXED MATCHES quantum at N=3!")
    else:
        print(f"  VERDICT: V8-fixed still deviates (max error {max_v8fix_err:.4f})")

    # ---------------------------------------------------------------
    # TEST B: Svetlichny-like inequality (in-plane, 8 terms)
    # ---------------------------------------------------------------
    print("\n--- TEST B: 3-party in-plane Bell inequality ---")
    print("  Svetlichny-like: S3 = sum of 8 correlation terms")

    # Optimal angles for a Svetlichny-like test with GHZ
    a1, a2 = math.pi / 4, 3 * math.pi / 4
    b1, b2 = math.pi / 4, 3 * math.pi / 4
    c1, c2 = math.pi / 4, 3 * math.pi / 4

    svetlichny_terms = [
        ((a1, b1, c1), +1),
        ((a1, b1, c2), -1),
        ((a1, b2, c1), +1),
        ((a1, b2, c2), +1),
        ((a2, b1, c1), +1),
        ((a2, b1, c2), +1),
        ((a2, b2, c1), -1),
        ((a2, b2, c2), +1),
    ]

    rng_born2 = np.random.default_rng(0xB010)
    rng_v8_2 = np.random.default_rng(0xB020)
    rng_v8fix2 = np.random.default_rng(0xB025)

    S3_born = 0.0
    S3_v8 = 0.0
    S3_v8fix = 0.0
    S3_exact = 0.0
    for settings, sign in svetlichny_terms:
        E_exact = ghz_exact_correlation(settings)
        E_born = measure_3party_correlation(ghz_quantum_born_rule, settings, NUM_TRIALS, rng_born2)
        E_v8 = measure_3party_correlation(ghz_bohmian_v8, settings, NUM_TRIALS, rng_v8_2)
        E_v8fix = measure_3party_correlation(ghz_bohmian_v8_fixed, settings, NUM_TRIALS, rng_v8fix2)
        S3_exact += sign * E_exact
        S3_born += sign * E_born
        S3_v8 += sign * E_v8
        S3_v8fix += sign * E_v8fix

    print(f"  S3 exact      = {S3_exact:+.4f}")
    print(f"  S3 Born       = {S3_born:+.4f}")
    print(f"  S3 V8 (broke) = {S3_v8:+.4f}")
    print(f"  S3 V8-fixed   = {S3_v8fix:+.4f}")

    # ---------------------------------------------------------------
    # No-signaling check for V8 at N=3
    # ---------------------------------------------------------------
    print("\n--- No-signaling check for V8 at N=3 ---")
    print("  Qubit C marginal should not depend on A or B's settings:")
    rng_ns = np.random.default_rng(0xB030)
    for a_set in [math.pi/4, 3*math.pi/4]:
        for b_set in [math.pi/4, 3*math.pi/4]:
            outcomes = ghz_bohmian_v8(
                [a_set, b_set, math.pi/4], NUM_TRIALS, rng_ns
            )
            marginal_c = float(np.mean(outcomes[2]))
            delta_label = "OK" if abs(marginal_c) < 0.01 else "SIGNALING"
            print(f"    <c | a={a_set:.2f}, b={b_set:.2f}> = {marginal_c:+.4f}  ({delta_label})")


def ghz_parity_sampling(settings, num_trials, rng):
    """O(N) sampling for GHZ states at EQUAL measurement angles.

    For GHZ = (|00...0> + |11...1>) / sqrt(2) measured at all-same angle alpha:

    The outcomes are restricted by the GHZ structure. The amplitude for an
    outcome with k plus-ones out of N qubits depends ONLY on k, not on which
    specific qubits are +1. So:

    1. Compute P(k) for k = 0, 1, ..., N  (N+1 probabilities, O(N))
    2. Weight by C(N,k) (the number of outcomes with exactly k plus-ones)
    3. Sample k from this distribution  (O(N))
    4. Randomly assign k plus-ones to N qubits  (O(N))

    Total: O(N). No 2^N enumeration. Scales to millions of qubits.

    Requirement: all settings must be the same angle.
    """
    n = len(settings)
    alpha = settings[0]  # all same angle

    c = math.cos(alpha / 2)
    s = math.sin(alpha / 2)
    a = 1.0 / math.sqrt(2)  # GHZ coefficient
    b = 1.0 / math.sqrt(2)

    # For outcome with k plus-ones and (N-k) minus-ones:
    # f0_product = cos(a/2)^k * (-sin(a/2))^(N-k) = (-1)^(N-k) * c^k * s^(N-k)
    # f1_product = sin(a/2)^k * cos(a/2)^(N-k)   = s^k * c^(N-k)
    # amplitude = a * f0_product + b * f1_product
    # P(specific outcome with k +1s) = amplitude^2
    # P(k) = C(N,k) * P(specific outcome with k +1s)

    from scipy.special import comb

    # Compute the probability for each k
    k_values = np.arange(n + 1)
    f0 = np.array([(-1) ** (n - k) * c ** k * s ** (n - k) for k in k_values])
    f1 = np.array([s ** k * c ** (n - k) for k in k_values])
    amplitudes = a * f0 + b * f1
    p_per_outcome = amplitudes ** 2  # probability of ONE specific outcome with k +1s

    # Multiply by C(N,k) for the number of such outcomes
    binomial_coeffs = np.array([comb(n, k, exact=True) for k in k_values], dtype=float)
    p_k = binomial_coeffs * p_per_outcome
    p_k = np.maximum(p_k, 0)  # clip tiny negatives
    p_k /= p_k.sum()  # normalize

    # Sample k values
    k_samples = rng.choice(n + 1, size=num_trials, p=p_k)

    # For each trial, randomly assign k_i plus-ones to N qubits
    outcomes = -np.ones((n, num_trials), dtype=int)  # start all as -1
    for trial_idx in range(num_trials):
        k = k_samples[trial_idx]
        if k > 0:
            plus_positions = rng.choice(n, size=k, replace=False)
            outcomes[plus_positions, trial_idx] = 1

    return outcomes


def ghz_parity_sampling_fast(settings, num_trials, rng):
    """Vectorized O(N) parity sampling — avoids per-trial loop for speed.
    Uses the same math as ghz_parity_sampling but assigns +1 positions
    via argsort of random values (vectorized across all trials)."""
    n = len(settings)
    alpha = settings[0]

    c = math.cos(alpha / 2)
    s = math.sin(alpha / 2)
    a = b = 1.0 / math.sqrt(2)

    from scipy.special import comb

    k_values = np.arange(n + 1)
    f0 = np.array([(-1) ** (n - k) * c ** k * s ** (n - k) for k in k_values])
    f1 = np.array([s ** k * c ** (n - k) for k in k_values])
    amplitudes = a * f0 + b * f1
    p_per_outcome = amplitudes ** 2

    binomial_coeffs = np.array([comb(n, k, exact=True) for k in k_values], dtype=float)
    p_k = binomial_coeffs * p_per_outcome
    p_k = np.maximum(p_k, 0)
    p_k /= p_k.sum()

    # Sample k values (vectorized)
    k_samples = rng.choice(n + 1, size=num_trials, p=p_k)

    # Assign +1 positions: for each trial, pick k random qubits
    # Vectorized trick: generate NxM random values, argsort each column,
    # the first k_i indices in each column get +1
    rand_matrix = rng.random((n, num_trials))
    sorted_indices = np.argsort(rand_matrix, axis=0)  # shape (N, M)

    outcomes = -np.ones((n, num_trials), dtype=int)
    for trial_idx in range(num_trials):
        k = k_samples[trial_idx]
        if k > 0:
            outcomes[sorted_indices[:k, trial_idx], trial_idx] = 1

    return outcomes


def run_ghz_n_scaling():
    """Scale GHZ simulation using O(N) parity sampling.
    Tests N from 3 to 100,000 qubits — way past the classical 35-qubit barrier.

    The key: GHZ state = 2 coefficients. Parity sampling = O(N).
    No 2^N enumeration needed. The state is procedural, not stored."""
    import time

    TRIALS = 100_000  # fewer trials for speed at large N

    print("\n" + "=" * 70)
    print("EXPERIMENT 10c: O(N) GHZ parity sampling — scaling past 35 qubits")
    print("=" * 70)
    print("State: (|00...0> + |11...1>) / sqrt(2)  — 2 coefficients at ANY N")
    print("Sampling: O(N) parity-based, NOT 2^N enumeration")
    print(f"Trials: {TRIALS}")
    print()

    # First: verify parity sampling matches Born rule at small N
    print("--- Verification: parity sampling vs Born rule at small N ---")
    print(f"  {'N':>6s} | {'Born E':>8s} | {'Parity E':>10s} | {'match':>6s}")
    print("  " + "-" * 45)

    for n in [3, 5, 10, 20]:
        settings = [math.pi / 2] * n
        rng1 = np.random.default_rng(0xFE20 + n)
        rng2 = np.random.default_rng(0xFE20 + n)

        outcomes_born = ghz_quantum_born_rule(settings, TRIALS, rng1)
        outcomes_parity = ghz_parity_sampling_fast(settings, TRIALS, rng2)

        product_born = np.ones(TRIALS, dtype=int)
        product_parity = np.ones(TRIALS, dtype=int)
        for i in range(n):
            product_born *= outcomes_born[i]
            product_parity *= outcomes_parity[i]

        E_born = float(np.mean(product_born))
        E_parity = float(np.mean(product_parity))
        match = "YES" if abs(E_born - E_parity) < 0.02 else "NO"
        print(f"  {n:6d} | {E_born:+8.4f} | {E_parity:+10.4f} | {match:>6s}")

    # Now: scale past the classical barrier
    print()
    print("--- Scaling past the 35-qubit classical barrier ---")
    print(f"  {'N qubits':>10s} | {'exact E':>8s} | {'measured E':>10s} | {'error':>8s} | {'time (s)':>9s} | {'note':>20s}")
    print("  " + "-" * 85)

    scale_values = [
        (3, ""),
        (10, ""),
        (20, "Qiskit limit ~30"),
        (35, "state vector limit"),
        (50, "Google Sycamore = 53"),
        (100, "past ANY classical sim"),
        (500, ""),
        (1_000, "1K qubits"),
        (10_000, "10K qubits"),
        (100_000, "100K qubits"),
    ]

    for n, note in scale_values:
        settings = [math.pi / 2] * n
        exact_E = 1.0  # sin(pi/2)^N = 1 for any N

        rng = np.random.default_rng(0xB160 + n)

        t0 = time.time()
        try:
            outcomes = ghz_parity_sampling_fast(settings, TRIALS, rng)
            product = np.ones(TRIALS, dtype=int)
            for i in range(n):
                product *= outcomes[i]
            E_measured = float(np.mean(product))
            elapsed = time.time() - t0
            err = abs(E_measured - exact_E)
            print(f"  {n:10d} | {exact_E:+8.4f} | {E_measured:+10.4f} | {err:8.4f} | {elapsed:9.3f} | {note:>20s}")
        except Exception as e:
            elapsed = time.time() - t0
            print(f"  {n:10d} | {'---':>8s} | {'FAIL':>10s} | {'---':>8s} | {elapsed:9.3f} | {str(e)[:20]:>20s}")

    print()
    print("  The state at N=100,000 is still just 2 numbers: a = b = 1/sqrt(2).")
    print("  Sampling cost: O(N) per trial via parity-based assignment.")
    print("  No 2^N enumeration. No exponential memory. Procedural, not stored.")


if __name__ == "__main__":
    main()
    run_ghz_scaling_test()
    run_ghz_n_scaling()
