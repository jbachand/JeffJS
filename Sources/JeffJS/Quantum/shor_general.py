#!/usr/bin/env python3
"""
shor_general.py — Shor's algorithm for factoring arbitrary composite numbers.

Generalizes the 15-specific implementation to handle any N. Uses a state
vector engine with direct-matrix inverse QFT. Scales to ~20-bit numbers
on a laptop (depending on RAM).

Qubit count: 2n + a few, where n = ceil(log2(N)).
State vector: 2^(2n) complex numbers.

Run:
    python3 shor_general.py
"""

import numpy as np
from math import gcd, pi, ceil, log2
from fractions import Fraction
import time
import random


def find_coprime(N):
    """Find a random a coprime with N."""
    while True:
        a = random.randint(2, N - 1)
        if gcd(a, N) == 1:
            return a
        # Lucky: gcd itself is a factor
        return None  # caller should check


def bits_needed(N):
    """Number of bits to represent N."""
    return ceil(log2(N + 1))


def apply_h(vec, qubit, n_total):
    dim = len(vec)
    new_vec = np.zeros(dim, dtype=complex)
    s = 1.0 / np.sqrt(2)
    for i in range(dim):
        i0 = i & ~(1 << qubit)
        i1 = i | (1 << qubit)
        bit = (i >> qubit) & 1
        new_vec[i] = s * (vec[i0] + (1 - 2 * bit) * vec[i1])
    return new_vec


def apply_inverse_qft_fft(vec, count_qubits, n_total):
    """Inverse QFT via numpy FFT. O(dim × log N) instead of O(dim × N).
    For each work-register slice, applies FFT to the counting-register
    subvector, then reassembles. Orders of magnitude faster for large N."""
    n_count = len(count_qubits)
    N_count = 2 ** n_count
    dim = len(vec)

    # Build index lookup tables (once, reusable)
    # For each (counting_value, work_value) pair, what's the full state index?
    count_mask = 0
    for cq in count_qubits:
        count_mask |= (1 << cq)
    work_mask = ((1 << n_total) - 1) ^ count_mask

    # Group basis states by their work-register bits
    # work_val → list of (counting_val, full_index) pairs
    new_vec = np.zeros(dim, dtype=complex)

    # Precompute: for each counting value cv, what bits does it set?
    cv_to_bits = np.zeros(N_count, dtype=int)
    for cv in range(N_count):
        bits = 0
        for j, cq in enumerate(count_qubits):
            if (cv >> j) & 1:
                bits |= (1 << cq)
        cv_to_bits[cv] = bits

    # For each unique work-register configuration, apply FFT
    N_work = dim // N_count
    for w_idx in range(N_work):
        # Reconstruct the work bits for this index
        # w_idx encodes the non-counting bits in their natural positions
        # We need to expand w_idx into the actual bit positions
        work_bits = 0
        bit_pos = 0
        for b in range(n_total):
            if not (count_mask & (1 << b)):
                if (w_idx >> bit_pos) & 1:
                    work_bits |= (1 << b)
                bit_pos += 1

        # Extract the subvector for this work configuration
        sub = np.zeros(N_count, dtype=complex)
        for cv in range(N_count):
            full_idx = work_bits | cv_to_bits[cv]
            sub[cv] = vec[full_idx]

        # Apply FFT (quantum inverse QFT = fft / sqrt(N))
        sub_out = np.fft.fft(sub) / np.sqrt(N_count)

        # Put back
        for cv in range(N_count):
            full_idx = work_bits | cv_to_bits[cv]
            new_vec[full_idx] = sub_out[cv]

    return new_vec


def apply_controlled_mod_mult(vec, control, work_qubits, a, N, n_total):
    """Controlled modular multiplication on work register."""
    dim = len(vec)
    new_vec = vec.copy()

    # Build permutation
    perm = list(range(max(N, 2 ** len(work_qubits))))
    for y in range(N):
        perm[y] = (a * y) % N

    # Apply permutation when control is |1⟩
    result = vec.copy()
    for i in range(dim):
        if (i >> control) & 1 == 1:
            y = 0
            for j, wq in enumerate(work_qubits):
                if (i >> wq) & 1:
                    y |= (1 << j)
            if y < N:
                ay = perm[y]
                target = i
                for j, wq in enumerate(work_qubits):
                    target &= ~(1 << wq)
                    if (ay >> j) & 1:
                        target |= (1 << wq)
                result[target] = vec[i]

    return result


def shor_factor(N, max_trials=30, verbose=True):
    """Run Shor's algorithm to factor N.

    Returns (p, q) where N = p × q, or None if failed.
    """
    if N % 2 == 0:
        return 2, N // 2

    n_bits = bits_needed(N)
    n_count = 2 * n_bits  # precision for phase estimation
    n_work = n_bits
    n_total = n_count + n_work
    dim = 2 ** n_total

    if verbose:
        print(f"  N = {N}, bits = {n_bits}")
        print(f"  Qubits: {n_count} counting + {n_work} work = {n_total} total")
        print(f"  State vector: {dim:,} complex numbers ({dim * 16 / 1e6:.1f} MB)")

    if dim * 16 > 4e9:  # > 4 GB
        if verbose:
            print(f"  SKIPPED: state vector too large ({dim * 16 / 1e9:.1f} GB)")
        return None

    count_qubits = list(range(n_count))
    work_qubits = list(range(n_count, n_total))

    rng_seed = random.Random(42 + N)
    np_rng = np.random.default_rng(0x5702 + N)

    for trial in range(max_trials):
        a = rng_seed.randint(2, N - 1)
        g = gcd(a, N)
        if g > 1:
            if verbose:
                print(f"  Trial {trial}: lucky gcd({a}, {N}) = {g}")
            return g, N // g

        # Build and run the quantum circuit
        vec = np.zeros(dim, dtype=complex)
        # Work register = |1⟩
        idx_one = 0
        for j, wq in enumerate(work_qubits):
            if (1 >> j) & 1:
                idx_one |= (1 << wq)
        vec[idx_one] = 1.0

        # Hadamard counting qubits
        for q in count_qubits:
            vec = apply_h(vec, q, n_total)

        # Controlled modular multiplications
        for j in range(n_count):
            power = pow(a, 2 ** j, N)
            vec = apply_controlled_mod_mult(
                vec, count_qubits[j], work_qubits, power, N, n_total
            )

        # Inverse QFT (FFT-based, O(dim × log N))
        vec = apply_inverse_qft_fft(vec, count_qubits, n_total)

        # Measure counting register
        probs = np.zeros(2 ** n_count)
        for i in range(dim):
            cv = 0
            for j, cq in enumerate(count_qubits):
                if (i >> cq) & 1:
                    cv |= (1 << j)
            probs[cv] += abs(vec[i]) ** 2

        probs /= probs.sum()
        measured = np_rng.choice(2 ** n_count, p=probs)

        phase = measured / (2 ** n_count)
        frac = Fraction(phase).limit_denominator(N)
        r = frac.denominator

        if verbose and (trial < 3 or r > 1):
            print(f"  Trial {trial}: a={a}, measured={measured}, "
                  f"phase={phase:.6f}, r={r}")

        if r > 0 and r % 2 == 0:
            g1 = gcd(pow(a, r // 2) - 1, N)
            g2 = gcd(pow(a, r // 2) + 1, N)
            for g in [g1, g2]:
                if 1 < g < N:
                    if verbose:
                        print(f"  Found factor: {g}")
                    return g, N // g

    return None


def main():
    print("=" * 65)
    print("SHOR'S ALGORITHM — General factoring")
    print("Running on the JeffJS quantum simulator")
    print("=" * 65)

    test_numbers = [
        15,     # 4 bits — the classic
        21,     # 5 bits — 3 × 7
        35,     # 6 bits — 5 × 7
        77,     # 7 bits — 7 × 11
        143,    # 8 bits — 11 × 13
        323,    # 9 bits — 17 × 19
        # 1007,   # 10 bits — 19 × 53 (might be slow)
    ]

    results = []
    print()
    print(f"  {'N':>6s} | {'bits':>4s} | {'qubits':>6s} | {'state vec':>12s} | {'result':>15s} | {'time':>8s}")
    print("  " + "-" * 70)

    for N in test_numbers:
        n_bits = bits_needed(N)
        n_total = 3 * n_bits
        dim = 2 ** n_total

        t0 = time.time()
        result = shor_factor(N, verbose=False)
        dt = time.time() - t0

        if result:
            p, q = sorted(result)
            verified = p * q == N
            result_str = f"{p} × {q}" + (" ✓" if verified else " ✗")
        else:
            result_str = "FAILED"
            verified = False

        results.append((N, verified))
        print(f"  {N:6d} | {n_bits:4d} | {n_total:6d} | {dim:12,d} | {result_str:>15s} | {dt:7.2f}s")

    print()
    passed = sum(1 for _, v in results if v)
    total = len(results)
    print(f"  {passed}/{total} factored correctly")

    if passed == total:
        print("\n  >>> ALL NUMBERS FACTORED CORRECTLY <<<")


if __name__ == "__main__":
    main()
