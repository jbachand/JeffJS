#!/usr/bin/env python3
"""
quantum_algorithms.py — three quantum algorithms running on the
JeffJS stabilizer + Clifford-T simulator.

1. Deutsch-Jozsa: is f constant or balanced? (0 T gates, pure Clifford)
2. Bernstein-Vazirani: find the secret string s. (0 T gates, pure Clifford)
3. Toffoli (CCX) gate: universal computation via Clifford+T decomposition.
   (7 T gates — demonstrates the full CliffordTSimulator pipeline)

Each algorithm is implemented as a self-contained test function that
constructs the circuit, runs it, and verifies the correct result.

Run:
    python3 quantum_algorithms.py
"""

import numpy as np
import time
from stabilizer_sim import StabilizerState, CliffordTSimulator


# =====================================================================
# Algorithm 1: Deutsch-Jozsa
# =====================================================================

def deutsch_jozsa(n_input, oracle_type, oracle_bits=None):
    """Run the Deutsch-Jozsa algorithm.

    Given a function f: {0,1}^n → {0,1} that is PROMISED to be either:
      - constant (f(x) = 0 for all x, or f(x) = 1 for all x)
      - balanced (f(x) = 0 for exactly half of all x, f(x) = 1 for the other half)

    Determine which in ONE query.

    Circuit (n+1 qubits, the last is the output/ancilla):
      1. Set ancilla to |1⟩ (apply X)
      2. Apply H to all qubits
      3. Apply oracle U_f
      4. Apply H to input qubits
      5. Measure input qubits: all 0 → constant, any 1 → balanced

    Args:
        n_input: number of input qubits
        oracle_type: "constant_0", "constant_1", "balanced"
        oracle_bits: for balanced oracle, which input qubits CNOT to output
                     (e.g., [0, 2] means f depends on qubits 0 and 2)

    Returns:
        (result, measurements): "constant" or "balanced", and the measurement list
    """
    n_total = n_input + 1
    ancilla = n_input  # last qubit is the output/ancilla

    state = StabilizerState(n_total)

    # Step 1: Prepare ancilla in |1⟩
    state.x(ancilla)

    # Step 2: Hadamard all qubits
    for i in range(n_total):
        state.h(i)

    # Step 3: Oracle U_f
    if oracle_type == "constant_0":
        pass  # f(x) = 0 for all x → do nothing (identity)
    elif oracle_type == "constant_1":
        # f(x) = 1 for all x → flip the ancilla unconditionally
        state.x(ancilla)
    elif oracle_type == "balanced":
        # f(x) depends on specific input qubits → CNOT from each to ancilla
        if oracle_bits is None:
            oracle_bits = list(range(n_input))  # all bits → XOR function
        for q in oracle_bits:
            state.cnot(q, ancilla)

    # Step 4: Hadamard input qubits
    for i in range(n_input):
        state.h(i)

    # Step 5: Measure input qubits
    rng = np.random.default_rng(0xDECA)
    measurements = [state.measure(i, rng) for i in range(n_input)]

    # Interpretation
    if all(m == 0 for m in measurements):
        return "constant", measurements
    else:
        return "balanced", measurements


def test_deutsch_jozsa():
    """Test Deutsch-Jozsa on multiple oracle configurations."""
    print("=" * 60)
    print("Algorithm 1: DEUTSCH-JOZSA")
    print("Is f constant or balanced? Answer in 1 query.")
    print("Pure Clifford circuit — 0 T gates.")
    print("=" * 60)

    tests = [
        (4, "constant_0", None, "constant"),
        (4, "constant_1", None, "constant"),
        (4, "balanced", [0], "balanced"),
        (4, "balanced", [0, 1], "balanced"),
        (4, "balanced", [0, 1, 2, 3], "balanced"),
        (8, "constant_0", None, "constant"),
        (8, "balanced", [0, 2, 4, 6], "balanced"),
        (16, "balanced", [0, 3, 7, 15], "balanced"),
    ]

    all_pass = True
    print(f"\n  {'n':>4s} | {'oracle':>15s} | {'expected':>10s} | {'got':>10s} | {'pass':>5s}")
    print("  " + "-" * 55)

    for n, oracle_type, oracle_bits, expected in tests:
        result, meas = deutsch_jozsa(n, oracle_type, oracle_bits)
        ok = result == expected
        all_pass &= ok
        label = oracle_type
        if oracle_bits:
            label += f" {oracle_bits}"
        print(f"  {n:4d} | {label:>15s} | {expected:>10s} | {result:>10s} | {'YES' if ok else 'NO':>5s}")

    print(f"\n  {'ALL PASSED' if all_pass else 'SOME FAILED'}")
    return all_pass


# =====================================================================
# Algorithm 2: Bernstein-Vazirani
# =====================================================================

def bernstein_vazirani(secret_string):
    """Run the Bernstein-Vazirani algorithm.

    Given a function f(x) = s·x (mod 2) where s is a secret n-bit string,
    find s in ONE query.

    Circuit (n+1 qubits):
      1. Set ancilla to |1⟩
      2. Apply H to all qubits
      3. Oracle: CNOT from qubit i to ancilla for each bit of s that is 1
      4. Apply H to input qubits
      5. Measure input qubits → gives s directly

    Args:
        secret_string: string of '0' and '1', e.g., "10110"

    Returns:
        recovered_string: the measured string (should match secret_string)
    """
    n = len(secret_string)
    n_total = n + 1
    ancilla = n

    state = StabilizerState(n_total)

    # Step 1: Prepare ancilla
    state.x(ancilla)

    # Step 2: Hadamard all
    for i in range(n_total):
        state.h(i)

    # Step 3: Oracle — CNOT from qubit i to ancilla where s[i] = '1'
    for i, bit in enumerate(secret_string):
        if bit == '1':
            state.cnot(i, ancilla)

    # Step 4: Hadamard input qubits
    for i in range(n):
        state.h(i)

    # Step 5: Measure
    rng = np.random.default_rng(0xBEEF)
    measurements = [state.measure(i, rng) for i in range(n)]
    recovered = ''.join(str(m) for m in measurements)

    return recovered


def test_bernstein_vazirani():
    """Test Bernstein-Vazirani with various secret strings."""
    print("\n" + "=" * 60)
    print("Algorithm 2: BERNSTEIN-VAZIRANI")
    print("Find the secret string s in 1 query (classical needs n queries).")
    print("Pure Clifford circuit — 0 T gates.")
    print("=" * 60)

    secrets = [
        "101",
        "1111",
        "10110011",
        "0000000000000001",  # 16 bits, only last bit is 1
        "1010101010101010",  # 16 bits, alternating
        "11111111111111111111",  # 20 bits, all ones
    ]

    all_pass = True
    print(f"\n  {'n':>4s} | {'secret':>25s} | {'recovered':>25s} | {'pass':>5s}")
    print("  " + "-" * 70)

    for secret in secrets:
        recovered = bernstein_vazirani(secret)
        ok = recovered == secret
        all_pass &= ok
        n = len(secret)
        print(f"  {n:4d} | {secret:>25s} | {recovered:>25s} | {'YES' if ok else 'NO':>5s}")

    print(f"\n  {'ALL PASSED' if all_pass else 'SOME FAILED'}")
    return all_pass


# =====================================================================
# Algorithm 3: Toffoli gate (CCX) via Clifford+T decomposition
# =====================================================================

def toffoli_clifford_t(sim, q0, q1, q2):
    """Apply a Toffoli (controlled-controlled-NOT) gate using the standard
    Clifford+T decomposition. Uses 7 T/T† gates.

    Decomposition (Nielsen & Chuang, Fig 4.9):
      H(q2)
      CNOT(q1, q2); T†(q2)
      CNOT(q0, q2); T(q2)
      CNOT(q1, q2); T†(q2)
      CNOT(q0, q2); T(q1); T(q2)
      CNOT(q0, q1); H(q2)
      T(q0); T†(q1)
      CNOT(q0, q1)
    """
    # Standard decomposition: Barenco et al. 1995 / Nielsen & Chuang Fig 4.9
    # 6 CNOTs + 7 T/T† + 2 H = 15 gates total
    sim.h(q2)                # 1.  H on target
    sim.cnot(q1, q2)         # 2.  CNOT(control2, target)
    sim.t_dagger(q2)         # 3.  T† on target
    sim.cnot(q0, q2)         # 4.  CNOT(control1, target)
    sim.t(q2)                # 5.  T on target
    sim.cnot(q1, q2)         # 6.  CNOT(control2, target)
    sim.t_dagger(q2)         # 7.  T† on target
    sim.cnot(q0, q2)         # 8.  CNOT(control1, target)
    sim.t(q1)                # 9.  T on control2
    sim.t(q2)                # 10. T on target
    sim.h(q2)                # 11. H on target  ← was swapped with 12
    sim.cnot(q0, q1)         # 12. CNOT(control1, control2)
    sim.t(q0)                # 13. T on control1
    sim.t_dagger(q1)         # 14. T† on control2
    sim.cnot(q0, q1)         # 15. CNOT(control1, control2)


def test_toffoli():
    """Test the Toffoli gate on all 8 input combinations.
    The Toffoli gate flips qubit 2 if and only if qubits 0 AND 1 are both |1⟩.
    This is the quantum AND gate — it requires T gates (non-Clifford)
    and is the key to universal quantum computation.
    """
    print("\n" + "=" * 60)
    print("Algorithm 3: TOFFOLI GATE (CCX)")
    print("Controlled-controlled-NOT via Clifford+T decomposition.")
    print("7 T/T† gates → 2^7 = 128 stabilizer terms (universal computation).")
    print("=" * 60)

    rng = np.random.default_rng(0xCCCC)
    all_pass = True

    print(f"\n  {'input':>10s} | {'expected':>10s} | {'got':>10s} | {'terms':>6s} | {'time':>8s} | {'pass':>5s}")
    print("  " + "-" * 65)

    for q0_in in [0, 1]:
        for q1_in in [0, 1]:
            for q2_in in [0, 1]:
                # Expected: q2 flips iff q0=1 AND q1=1
                expected_q2 = q2_in ^ (q0_in & q1_in)
                expected = f"|{q0_in}{q1_in}{expected_q2}⟩"

                sim = CliffordTSimulator(3)

                # Prepare input state
                if q0_in:
                    sim.x(0)
                if q1_in:
                    sim.x(1)
                if q2_in:
                    sim.x(2)

                # Apply Toffoli
                t0 = time.time()
                toffoli_clifford_t(sim, 0, 1, 2)
                terms = sim.num_terms
                dt_gate = time.time() - t0

                # Measure
                t0 = time.time()
                m0 = sim.measure(0, rng)
                m1 = sim.measure(1, rng)
                m2 = sim.measure(2, rng)
                dt_meas = time.time() - t0

                got = f"|{m0}{m1}{m2}⟩"
                ok = (m0 == q0_in and m1 == q1_in and m2 == expected_q2)
                all_pass &= ok

                input_str = f"|{q0_in}{q1_in}{q2_in}⟩"
                print(f"  {input_str:>10s} | {expected:>10s} | {got:>10s} | {terms:>6d} | {dt_gate + dt_meas:7.3f}s | {'YES' if ok else 'NO':>5s}")

    print(f"\n  {'ALL 8 INPUTS CORRECT' if all_pass else 'SOME INPUTS FAILED'}")
    if all_pass:
        print("  >>> Toffoli gate works: universal quantum computation confirmed <<<")
    return all_pass


# =====================================================================
# Main
# =====================================================================

def main():
    print("*" * 60)
    print("JeffJS Quantum Algorithm Test Suite")
    print("Testing 3 quantum algorithms on the stabilizer + Clifford-T sim")
    print("*" * 60)

    t0 = time.time()

    ok1 = test_deutsch_jozsa()
    ok2 = test_bernstein_vazirani()
    ok3 = test_toffoli()

    total = time.time() - t0

    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)
    print(f"  Deutsch-Jozsa:         {'PASS' if ok1 else 'FAIL'}  (0 T gates, pure Clifford)")
    print(f"  Bernstein-Vazirani:    {'PASS' if ok2 else 'FAIL'}  (0 T gates, pure Clifford)")
    print(f"  Toffoli (CCX):         {'PASS' if ok3 else 'FAIL'}  (7 T gates, universal)")
    print(f"  Total time:            {total:.1f}s")
    print()

    if ok1 and ok2 and ok3:
        print("  >>> ALL ALGORITHMS PASS <<<")
        print("  The simulator correctly executes:")
        print("    - Clifford-only algorithms (Deutsch-Jozsa, Bernstein-Vazirani)")
        print("    - Universal circuits via Clifford+T decomposition (Toffoli)")
        print("  This is a working quantum computer simulator.")
    else:
        print("  !!! SOME ALGORITHMS FAILED !!!")


if __name__ == "__main__":
    main()
