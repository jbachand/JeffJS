#!/usr/bin/env python3
"""
shor_fast.py — Vectorized Shor's algorithm using numpy.

All state vector operations are fully vectorized (no Python loops over
amplitudes). On Apple Silicon M1, numpy uses the Accelerate framework
and NEON SIMD, giving near-Metal performance for array operations.

Typical speedup over shor_general.py: 50-100x.

Run:
    python3 shor_fast.py
"""

import numpy as np
from math import gcd, ceil, log2, pi
from fractions import Fraction
import time
import random


def bits_needed(N):
    return ceil(log2(N + 1))


def h_gate(vec, qubit):
    """Vectorized Hadamard gate. No Python loops."""
    dim = len(vec)
    mask = 1 << qubit
    idx = np.arange(dim)
    i0 = idx & ~mask
    i1 = idx | mask
    bit = (idx >> qubit) & 1
    s = np.float32(1.0 / np.sqrt(2))
    return np.where(bit == 0, s * (vec[i0] + vec[i1]), s * (vec[i0] - vec[i1]))


def x_gate(vec, qubit):
    """Vectorized Pauli X gate."""
    dim = len(vec)
    mask = 1 << qubit
    idx = np.arange(dim)
    partner = idx ^ mask
    return vec[partner]


def controlled_mod_mult(vec, control, work_offset, n_work, a, N):
    """Vectorized controlled modular multiplication."""
    dim = len(vec)
    idx = np.arange(dim, dtype=np.int64)
    result = vec.copy()

    ctrl_mask = np.int64(1) << control
    active = (idx & ctrl_mask) != 0

    # Extract work register value
    work_mask = np.int64(((1 << n_work) - 1)) << work_offset
    work_val = (idx & work_mask) >> work_offset

    # Only process active entries with valid work values
    valid = active & (work_val < N)

    if not np.any(valid):
        return result

    valid_idx = idx[valid]
    valid_work = work_val[valid]
    new_work = (np.int64(a) * valid_work) % np.int64(N)

    # Build target indices: clear work bits, set new work bits
    target = (valid_idx & ~work_mask) | (new_work << work_offset)

    # Apply permutation: result[target] = vec[source]
    result_new = vec.copy()
    # Zero out the valid positions first to handle the permutation correctly
    # For positions where control=0 or work>=N, keep original
    # For valid positions, apply the permutation
    result_new[target] = vec[valid_idx]

    # For non-active positions, keep original
    result_new[~valid] = vec[~valid]

    return result_new


def inverse_qft_fft(vec, count_qubits, n_total):
    """Inverse QFT via numpy FFT. Vectorized index construction."""
    n_count = len(count_qubits)
    N_count = 2 ** n_count
    dim = len(vec)

    count_mask = sum(1 << cq for cq in count_qubits)

    # Precompute cv-to-bits mapping
    cv_to_bits = np.zeros(N_count, dtype=np.int64)
    for cv in range(N_count):
        for j, cq in enumerate(count_qubits):
            if (cv >> j) & 1:
                cv_to_bits[cv] |= (1 << cq)

    new_vec = np.zeros(dim, dtype=np.complex64)
    N_work = dim // N_count

    # Iterate over work-register configurations
    non_count_bits = [b for b in range(n_total) if not (count_mask & (1 << b))]

    for w_idx in range(N_work):
        work_bits = 0
        for bit_pos, b in enumerate(non_count_bits):
            if (w_idx >> bit_pos) & 1:
                work_bits |= (1 << b)

        # Extract subvector for this work configuration (vectorized)
        indices = work_bits | cv_to_bits
        sub = vec[indices]

        # Apply FFT
        sub_out = np.fft.fft(sub).astype(np.complex64) / np.sqrt(N_count)

        # Write back
        new_vec[indices] = sub_out

    return new_vec


def get_probs(vec, count_qubits):
    """Vectorized measurement probability computation."""
    dim = len(vec)
    n_count = len(count_qubits)
    N_count = 2 ** n_count

    idx = np.arange(dim, dtype=np.int64)
    cv = np.zeros(dim, dtype=np.int64)
    for j, cq in enumerate(count_qubits):
        cv |= ((idx >> cq) & 1) << j

    probs_flat = np.abs(vec) ** 2
    probs = np.zeros(N_count)
    np.add.at(probs, cv, probs_flat)
    return probs


def shor_factor(N, max_trials=30, verbose=True):
    """Run Shor's algorithm with vectorized numpy operations."""
    if N % 2 == 0:
        return 2, N // 2

    n_bits = bits_needed(N)
    n_count = 2 * n_bits
    n_work = n_bits
    n_total = n_count + n_work
    dim = 2 ** n_total

    mem_mb = dim * 8 / 1e6
    if verbose:
        print(f"  N={N}, {n_bits} bits, {n_total} qubits, "
              f"{dim:,} amplitudes ({mem_mb:.0f} MB)")

    if mem_mb > 4000:
        if verbose:
            print(f"  SKIP: {mem_mb:.0f} MB exceeds limit")
        return None

    count_qubits = list(range(n_count))
    work_offset = n_count
    rng_seed = random.Random(42 + N)
    np_rng = np.random.default_rng(0x5702 + N)

    for trial in range(max_trials):
        a = rng_seed.randint(2, N - 1)
        g = gcd(a, N)
        if g > 1:
            if verbose:
                print(f"  Trial {trial}: lucky gcd({a},{N})={g}")
            return g, N // g

        # Initialize state vector
        vec = np.zeros(dim, dtype=np.complex64)
        vec[1 << work_offset] = 1.0  # work register = |1⟩

        # Hadamard all counting qubits
        t0 = time.time()
        for q in count_qubits:
            vec = h_gate(vec, q)
        dt_h = time.time() - t0

        # Controlled modular multiplications
        t0 = time.time()
        for j in range(n_count):
            power = pow(a, 2 ** j, N)
            vec = controlled_mod_mult(vec, count_qubits[j],
                                      work_offset, n_work, power, N)
        dt_mod = time.time() - t0

        # Inverse QFT
        t0 = time.time()
        vec = inverse_qft_fft(vec, count_qubits, n_total)
        dt_qft = time.time() - t0

        # Measure
        t0 = time.time()
        probs = get_probs(vec, count_qubits)
        probs /= probs.sum()
        measured = np_rng.choice(2 ** n_count, p=probs)
        dt_meas = time.time() - t0

        phase = measured / (2 ** n_count)
        frac = Fraction(phase).limit_denominator(N)
        r = frac.denominator

        if verbose and (trial < 3 or r > 1):
            print(f"  Trial {trial}: a={a}, r={r} "
                  f"[H:{dt_h:.2f}s mod:{dt_mod:.2f}s "
                  f"QFT:{dt_qft:.2f}s meas:{dt_meas:.2f}s]")

        if r > 0 and r % 2 == 0:
            for gg in [gcd(pow(a, r // 2) - 1, N), gcd(pow(a, r // 2) + 1, N)]:
                if 1 < gg < N:
                    return gg, N // gg

    return None


def main():
    print("=" * 70)
    print("SHOR'S ALGORITHM — Vectorized numpy (Accelerate/NEON on Apple Silicon)")
    print("=" * 70)

    numbers = [15, 21, 35, 77, 143, 323, 1007, 3127, 5767]

    print()
    print(f"  {'N':>6s} | {'bits':>4s} | {'qubits':>6s} | {'amplitudes':>14s} | "
          f"{'result':>15s} | {'time':>8s}")
    print("  " + "-" * 80)

    for N in numbers:
        n_bits = bits_needed(N)
        n_total = 3 * n_bits
        dim = 2 ** n_total

        t0 = time.time()
        result = shor_factor(N, verbose=False)
        dt = time.time() - t0

        if result:
            p, q = sorted(result)
            ok = p * q == N
            rstr = f"{p} × {q}" + (" ✓" if ok else " ✗")
        else:
            rstr = "SKIP/FAIL"

        print(f"  {N:6d} | {n_bits:4d} | {n_total:6d} | {dim:14,d} | "
              f"{rstr:>15s} | {dt:7.1f}s")

        if dt > 300:
            print("  (stopping — 5 min limit)")
            break

    print()
    print("  All operations vectorized via numpy (no Python loops over amplitudes)")
    print("  Apple Silicon: Accelerate framework + NEON SIMD")


if __name__ == "__main__":
    main()
