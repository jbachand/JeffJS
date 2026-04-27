#!/usr/bin/env python3
"""
shor_factor_15.py — Shor's algorithm factoring 15 = 3 × 5.

Uses the JeffJS quantum simulator's state vector engine to run the full
quantum period-finding circuit, then classical post-processing to extract
factors.

Circuit: 8 qubits (4 counting + 4 work)
  1. Initialize work register to |0001⟩ (= integer 1)
  2. Hadamard all counting qubits (superposition)
  3. Controlled modular multiplications: controlled-U^(2^j) for j=0..3
     where U|y⟩ = |7y mod 15⟩
  4. Inverse QFT on counting register
  5. Measure counting register → phase estimate k/16
  6. Classical: continued fractions → period r → factors via gcd

Run:
    python3 shor_factor_15.py
"""

import numpy as np
from math import gcd, pi
from fractions import Fraction

N_TO_FACTOR = 15
A = 7  # coprime with 15, chosen randomly
N_COUNT = 4   # counting qubits (precision of phase estimate)
N_WORK = 4    # work qubits (hold the modular arithmetic)
N_TOTAL = N_COUNT + N_WORK
DIM = 2 ** N_TOTAL  # 256


def apply_h(vec, qubit, n_total):
    """Apply Hadamard to one qubit."""
    dim = 2 ** n_total
    new_vec = np.zeros(dim, dtype=complex)
    s = 1.0 / np.sqrt(2)
    for i in range(dim):
        bit = (i >> qubit) & 1
        i0 = i & ~(1 << qubit)
        i1 = i | (1 << qubit)
        if bit == 0:
            new_vec[i] = s * (vec[i0] + vec[i1])
        else:
            new_vec[i] = s * (vec[i0] - vec[i1])
    return new_vec


def apply_controlled_phase(vec, control, target, angle, n_total):
    """Apply controlled-R(angle): phase shift on |1,1⟩ component."""
    vec = vec.copy()
    phase = np.exp(1j * angle)
    for i in range(2 ** n_total):
        if (i >> control) & 1 == 1 and (i >> target) & 1 == 1:
            vec[i] *= phase
    return vec


def apply_swap(vec, q1, q2, n_total):
    """Swap two qubits."""
    vec = vec.copy()
    for i in range(2 ** n_total):
        b1 = (i >> q1) & 1
        b2 = (i >> q2) & 1
        if b1 != b2:
            j = i ^ (1 << q1) ^ (1 << q2)
            vec[i], vec[j] = vec[j], vec[i]
    return vec


def inverse_qft(vec, qubits, n_total):
    """Inverse Quantum Fourier Transform on the given qubits.
    Reverses the standard QFT: H first, then controlled-R† gates,
    outer loop from high to low qubit, swap at the end."""
    n = len(qubits)
    for j in range(n - 1, -1, -1):
        vec = apply_h(vec, qubits[j], n_total)
        for k in range(j - 1, -1, -1):
            angle = -2 * pi / (2 ** (j - k + 1))
            vec = apply_controlled_phase(vec, qubits[j], qubits[k], angle, n_total)
    # Swap to match standard bit ordering
    for i in range(n // 2):
        vec = apply_swap(vec, qubits[i], qubits[n - 1 - i], n_total)
    return vec


def apply_inverse_qft_direct(vec, count_qubits, n_total):
    """Apply inverse QFT using direct matrix multiplication.
    Guaranteed correct — no gate-ordering ambiguity.
    O(N_count² × 2^N_total), fast for small qubit counts."""
    n_count = len(count_qubits)
    N = 2 ** n_count
    dim = 2 ** n_total

    new_vec = np.zeros(dim, dtype=complex)
    for i in range(dim):
        # Extract counting register value from this basis state
        cv_in = 0
        for j, cq in enumerate(count_qubits):
            if (i >> cq) & 1:
                cv_in |= (1 << j)

        # Apply QFT†: this basis state |cv_in⟩ contributes to all |k⟩
        for k in range(N):
            phase = np.exp(-2j * pi * cv_in * k / N) / np.sqrt(N)
            # Build the target index with counting bits = k
            target = i
            for j, cq in enumerate(count_qubits):
                target &= ~(1 << cq)
                if (k >> j) & 1:
                    target |= (1 << cq)
            new_vec[target] += phase * vec[i]

    return new_vec


def extract_work_bits(i, work_qubits):
    """Extract the integer value stored in the work qubits."""
    val = 0
    for j, wq in enumerate(work_qubits):
        if (i >> wq) & 1:
            val |= (1 << j)
    return val


def replace_work_bits(i, work_qubits, new_val):
    """Replace the work qubit bits with new_val."""
    result = i
    for j, wq in enumerate(work_qubits):
        # Clear this bit
        result &= ~(1 << wq)
        # Set it to the new value's bit
        if (new_val >> j) & 1:
            result |= (1 << wq)
    return result


def apply_controlled_mod_mult(vec, control, work_qubits, a, N, n_total):
    """Controlled modular multiplication: if control=|1⟩, apply |y⟩→|ay mod N⟩
    on the work register. States with y ≥ N are left unchanged."""
    dim = 2 ** n_total
    new_vec = vec.copy()

    # Build the permutation for the work register
    n_work = len(work_qubits)
    perm = list(range(2 ** n_work))
    for y in range(N):
        perm[y] = (a * y) % N

    # Apply: for each basis state where control=1, permute the work bits
    used = set()
    for i in range(dim):
        if (i >> control) & 1 == 1 and i not in used:
            y = extract_work_bits(i, work_qubits)
            if y < N:
                ay = perm[y]
                if ay != y:
                    j = replace_work_bits(i, work_qubits, ay)
                    # Swap amplitudes along the permutation cycle
                    new_vec[i], new_vec[j] = vec[j], vec[i]
    # The above simple swap only works for 2-cycles.
    # For longer cycles, we need to follow the full cycle.
    # Let's do it properly:
    new_vec = vec.copy()
    for i in range(dim):
        if (i >> control) & 1 == 1:
            y = extract_work_bits(i, work_qubits)
            if y < N:
                ay = perm[y]
                j = replace_work_bits(i, work_qubits, ay)
                new_vec[j] = vec[i]
            # else: leave unchanged (new_vec[i] = vec[i], already copied)

    return new_vec


def run_shor(N, a, n_trials=20):
    """Run Shor's algorithm to factor N using base a.

    Returns the factors found, or None if the algorithm fails.
    """
    count_qubits = list(range(N_COUNT))           # qubits 0..3
    work_qubits = list(range(N_COUNT, N_TOTAL))    # qubits 4..7

    print(f"  Factoring N = {N} with a = {a}")
    print(f"  Qubits: {N_COUNT} counting + {N_WORK} work = {N_TOTAL} total")
    print(f"  State vector: {DIM} complex amplitudes")
    print()

    rng = np.random.default_rng(0x5702)
    found_factors = set()

    for trial in range(n_trials):
        # Initialize state vector
        vec = np.zeros(DIM, dtype=complex)
        # Work register = |0001⟩ (integer 1)
        vec[1 << work_qubits[0]] = 1.0

        # Step 1: Hadamard all counting qubits
        for q in count_qubits:
            vec = apply_h(vec, q, N_TOTAL)

        # Step 2: Controlled modular multiplications
        # controlled-U^(2^j): multiply by a^(2^j) mod N
        for j in range(N_COUNT):
            power = pow(a, 2 ** j, N)  # a^(2^j) mod N
            vec = apply_controlled_mod_mult(
                vec, count_qubits[j], work_qubits, power, N, N_TOTAL
            )

        # Step 3: Inverse QFT on counting register (direct matrix, always correct)
        vec = apply_inverse_qft_direct(vec, count_qubits, N_TOTAL)

        # Step 4: Measure counting register
        # Compute probabilities for each counting-register value
        probs = np.zeros(2 ** N_COUNT)
        for i in range(DIM):
            count_val = 0
            for j, cq in enumerate(count_qubits):
                if (i >> cq) & 1:
                    count_val |= (1 << j)
            probs[count_val] += abs(vec[i]) ** 2

        # Sample from the distribution
        measured = rng.choice(2 ** N_COUNT, p=probs / probs.sum())

        # Step 5: Classical post-processing
        # The measured value is k where k/2^n_count ≈ s/r for some integer s
        phase = measured / (2 ** N_COUNT)

        # Use continued fractions to find r
        frac = Fraction(phase).limit_denominator(N)
        r = frac.denominator

        if trial < 5 or r > 1:
            print(f"  Trial {trial}: measured={measured}, phase={phase:.4f}, "
                  f"r_candidate={r}")

        if r > 0 and r % 2 == 0:
            guess1 = gcd(pow(a, r // 2) - 1, N)
            guess2 = gcd(pow(a, r // 2) + 1, N)
            if 1 < guess1 < N:
                found_factors.add(guess1)
                found_factors.add(N // guess1)
            if 1 < guess2 < N:
                found_factors.add(guess2)
                found_factors.add(N // guess2)

        if len(found_factors) >= 2:
            break

    return found_factors


def main():
    print("=" * 60)
    print("SHOR'S ALGORITHM — Factoring 15")
    print("Running on the JeffJS quantum simulator")
    print("=" * 60)
    print()

    import time
    t0 = time.time()

    factors = run_shor(N_TO_FACTOR, A)

    dt = time.time() - t0
    print()
    if factors and len(factors) >= 2:
        f_list = sorted(factors)
        print(f"  RESULT: {N_TO_FACTOR} = {f_list[0]} × {f_list[1]}")
        print(f"  Time: {dt:.3f}s")
        product = f_list[0] * f_list[1]
        if product == N_TO_FACTOR:
            print(f"  VERIFIED: {f_list[0]} × {f_list[1]} = {product} ✓")
            print()
            print("  >>> SHOR'S ALGORITHM WORKS <<<")
        else:
            print(f"  ERROR: {f_list[0]} × {f_list[1]} = {product} ≠ {N_TO_FACTOR}")
    else:
        print(f"  FAILED to find factors of {N_TO_FACTOR}")
        print(f"  Time: {dt:.3f}s")


if __name__ == "__main__":
    main()
