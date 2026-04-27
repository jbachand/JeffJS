#!/usr/bin/env python3
"""
shor_iterative.py — Shor's algorithm with iterative phase estimation.

Uses only n+1 qubits (1 counting + n work) instead of 3n qubits.
The counting register is a SINGLE qubit, measured and recycled 2n times.
Phase corrections from the semi-classical QFT replace the full QFT circuit.

Memory comparison for factoring N:
  Full QPE:      2^(3n) amplitudes  (143 → 16M,   323 → 134M, 1007 → 1B)
  Iterative QPE: 2^(n+1) amplitudes (143 → 512,   323 → 1K,   1007 → 2K)

This lets us factor MUCH larger numbers on the same hardware.

Run:
    python3 shor_iterative.py
"""

import numpy as np
from math import gcd, ceil, log2, pi
from fractions import Fraction
import time
import random


def bits_needed(N):
    return ceil(log2(N + 1))


# =====================================================================
# Vectorized gate operations (same as shor_fast.py)
# =====================================================================

def h_gate(vec, qubit):
    dim = len(vec)
    mask = np.int64(1) << qubit
    idx = np.arange(dim, dtype=np.int64)
    i0 = idx & ~mask
    i1 = idx | mask
    bit = (idx >> qubit) & 1
    s = np.float32(1.0 / np.sqrt(2))
    return np.where(bit == 0, s * (vec[i0] + vec[i1]), s * (vec[i0] - vec[i1]))


def x_gate(vec, qubit):
    dim = len(vec)
    idx = np.arange(dim, dtype=np.int64)
    return vec[idx ^ (np.int64(1) << qubit)]


def phase_gate(vec, qubit, angle):
    """Apply P(angle) to qubit: |1⟩ → e^{iθ}|1⟩, |0⟩ unchanged."""
    dim = len(vec)
    result = vec.copy()
    idx = np.arange(dim, dtype=np.int64)
    mask = np.int64(1) << qubit
    active = (idx & mask) != 0
    result[active] *= np.exp(1j * angle).astype(np.complex64)
    return result


def controlled_mod_mult(vec, control, work_offset, n_work, a, N):
    """Vectorized controlled modular multiplication."""
    dim = len(vec)
    idx = np.arange(dim, dtype=np.int64)
    result = vec.copy()

    ctrl_mask = np.int64(1) << control
    work_mask = np.int64(((1 << n_work) - 1)) << work_offset
    active = (idx & ctrl_mask) != 0
    work_val = (idx & work_mask) >> work_offset
    valid = active & (work_val < N)

    if not np.any(valid):
        return result

    valid_idx = idx[valid]
    valid_work = work_val[valid]
    new_work = (np.int64(a) * valid_work) % np.int64(N)
    target = (valid_idx & ~work_mask) | (new_work << work_offset)

    result_new = vec.copy()
    result_new[target] = vec[valid_idx]
    result_new[~valid] = vec[~valid]
    return result_new


def measure_qubit(vec, qubit, rng):
    """Measure a qubit, collapse the state, return (outcome, collapsed_vec)."""
    dim = len(vec)
    idx = np.arange(dim, dtype=np.int64)
    mask = np.int64(1) << qubit
    is_zero = (idx & mask) == 0

    p0 = float(np.sum(np.abs(vec[is_zero]) ** 2))
    p0 = max(0.0, min(1.0, p0))

    outcome = 0 if rng.random() < p0 else 1

    collapsed = vec.copy()
    if outcome == 0:
        collapsed[~is_zero] = 0
    else:
        collapsed[is_zero] = 0
    norm = np.linalg.norm(collapsed)
    if norm > 1e-15:
        collapsed /= norm

    return outcome, collapsed


# =====================================================================
# Iterative Phase Estimation Shor's Algorithm
# =====================================================================

def shor_iterative(N, max_trials=30, verbose=True):
    """Run Shor's algorithm with iterative phase estimation.

    Uses only n+1 qubits: 1 counting qubit (measured and recycled)
    + n work qubits. The full QFT is replaced by sequential single-qubit
    measurements with classical phase corrections.
    """
    if N % 2 == 0:
        return 2, N // 2

    n_bits = bits_needed(N)
    m = 2 * n_bits  # number of phase estimation rounds
    n_work = n_bits
    n_total = n_work + 1  # 1 counting qubit + work qubits
    counting_qubit = 0
    work_offset = 1
    dim = 2 ** n_total

    if verbose:
        print(f"  N={N}, {n_bits} bits")
        print(f"  Qubits: 1 counting + {n_work} work = {n_total} total")
        print(f"  State vector: {dim:,} amplitudes ({dim * 8 / 1e3:.1f} KB)")
        print(f"  Phase estimation rounds: {m}")

    rng = np.random.default_rng(0x5702 + N)
    seed_rng = random.Random(42 + N)

    for trial in range(max_trials):
        a = seed_rng.randint(2, N - 1)
        g = gcd(a, N)
        if g > 1:
            if verbose:
                print(f"  Trial {trial}: lucky gcd({a},{N})={g}")
            return g, N // g

        # Initialize: counting qubit = |0⟩, work register = |1⟩
        vec = np.zeros(dim, dtype=np.complex64)
        vec[1 << work_offset] = 1.0

        measured_bits = []  # collected from MSB to LSB

        for round_idx in range(m):
            j = m - 1 - round_idx  # phase estimation index (MSB first)

            # Reset counting qubit to |0⟩
            if measured_bits:
                last_bit = measured_bits[-1]
                if last_bit == 1:
                    vec = x_gate(vec, counting_qubit)

            # H on counting qubit → |+⟩
            vec = h_gate(vec, counting_qubit)

            # Controlled-U^(2^j) on work register
            power = pow(a, 2 ** j, N)
            if power != 1:  # skip identity multiplications
                vec = controlled_mod_mult(
                    vec, counting_qubit, work_offset, n_work, power, N
                )

            # Phase correction from previously measured bits
            # In the semi-classical QFT, the correction for round_idx is:
            # P(angle) where angle = -Σ_{prev rounds} b_k × 2π/2^(distance+1)
            correction = 0.0
            for prev_idx, b_k in enumerate(measured_bits):
                distance = round_idx - prev_idx  # how many rounds ago
                if b_k == 1:
                    correction -= 2 * pi / (2 ** (distance + 1))

            if abs(correction) > 1e-10:
                vec = phase_gate(vec, counting_qubit, correction)

            # H on counting qubit
            vec = h_gate(vec, counting_qubit)

            # Measure counting qubit
            outcome, vec = measure_qubit(vec, counting_qubit, rng)
            measured_bits.append(outcome)

        # Construct phase estimate from measured bits
        # measured_bits[0] is the MSB, measured_bits[-1] is the LSB
        phase_int = 0
        for idx, b in enumerate(measured_bits):
            phase_int |= (b << (m - 1 - idx))
        phase = phase_int / (2 ** m)

        frac = Fraction(phase).limit_denominator(N)
        r = frac.denominator

        if verbose and (trial < 5 or r > 1):
            bits_str = ''.join(str(b) for b in measured_bits[:8])
            if len(measured_bits) > 8:
                bits_str += '...'
            print(f"  Trial {trial}: a={a}, phase={phase:.6f}, "
                  f"r={r}, bits={bits_str}")

        if r > 0 and r % 2 == 0:
            for gg in [gcd(pow(a, r // 2) - 1, N),
                       gcd(pow(a, r // 2) + 1, N)]:
                if 1 < gg < N:
                    if verbose:
                        print(f"  → factor found: {gg}")
                    return gg, N // gg

    return None


# =====================================================================
# Main
# =====================================================================

def main():
    print("=" * 70)
    print("SHOR'S ALGORITHM — Iterative Phase Estimation")
    print("1 counting qubit + n work qubits = n+1 total")
    print("State vector: 2^(n+1) instead of 2^(3n)")
    print("=" * 70)

    # Validation: same numbers as before
    print("\n--- Validation (should match shor_fast.py results) ---")
    validate = [15, 21, 35, 77, 143, 323]
    print(f"\n  {'N':>6s} | {'bits':>4s} | {'qubits':>6s} | {'amps':>10s} | "
          f"{'result':>15s} | {'time':>8s}")
    print("  " + "-" * 70)

    for N in validate:
        n = bits_needed(N)
        n_total = n + 1
        dim = 2 ** n_total
        t0 = time.time()
        result = shor_iterative(N, verbose=False)
        dt = time.time() - t0
        if result:
            p, q = sorted(result)
            ok = p * q == N
            rstr = f"{p} × {q}" + (" ✓" if ok else " ✗")
        else:
            rstr = "FAIL"
        print(f"  {N:6d} | {n:4d} | {n_total:6d} | {dim:10,d} | "
              f"{rstr:>15s} | {dt:7.2f}s")

    # Scale: push to much larger numbers
    print("\n--- Scaling past previous limits ---")
    scale = [1007, 3127, 5767, 11009, 29999, 100003, 524287]
    print(f"\n  {'N':>8s} | {'bits':>4s} | {'qubits':>6s} | {'amps':>10s} | "
          f"{'result':>20s} | {'time':>8s}")
    print("  " + "-" * 75)

    for N in scale:
        n = bits_needed(N)
        n_total = n + 1
        dim = 2 ** n_total
        t0 = time.time()
        result = shor_iterative(N, verbose=False, max_trials=50)
        dt = time.time() - t0
        if result:
            p, q = sorted(result)
            ok = p * q == N
            rstr = f"{p} × {q}" + (" ✓" if ok else " ✗")
        else:
            rstr = "FAIL"
        print(f"  {N:8d} | {n:4d} | {n_total:6d} | {dim:10,d} | "
              f"{rstr:>20s} | {dt:7.2f}s")
        if dt > 300:
            print("  (stopping)")
            break

    print()
    print("  State vector for ALL of these: ≤ 2^21 = 2M amplitudes = 16 MB")
    print("  Compare: shor_fast.py needed 134M amplitudes (1 GB) just for 323.")


if __name__ == "__main__":
    main()
