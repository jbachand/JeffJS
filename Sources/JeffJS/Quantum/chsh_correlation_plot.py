#!/usr/bin/env python3
"""
chsh_correlation_plot.py — visualize the entanglement signature.

For each CHSH variant in chsh_prototype.py, sweep the angle difference
delta = alpha_B - alpha_A from 0 to 2*pi (with alpha_A held at 0) and
measure the joint correlation E(delta) = <b_A * b_B>.

Plot all variants on one axis. The visual signature of entanglement is
geometric: classical Bell-saturating strategies produce a triangle wave
in the angle difference, while quantum mechanics produces a smooth
cosine. The geometric difference (triangle vs cosine) at the
CHSH-optimal angles is exactly why quantum gets above S = 2.

The plot is mathematically backed end-to-end:
  - Each curve is data from running the corresponding variant
  - Theoretical references are overlaid as dashed lines
  - The vertical markers show the four CHSH-optimal angles
  - The shaded region shows the "Bell gap" — the area where the cosine
    has higher magnitude than the triangle wave at the same delta

Run:
  python3 chsh_correlation_plot.py

Output:
  chsh_correlation_curves.png  (next to this script)
"""

import math
import sys

import numpy as np
import matplotlib.pyplot as plt

# Import the CHSH variants from the prototype
from chsh_prototype import (
    naive_probabilistic,
    deterministic_sign,
    bound_qubit_pair,
    quantum_singlet,
)

NUM_TRIALS = 30_000
NUM_ANGLES = 73   # one sample every ~5 degrees, 0 to 2*pi inclusive


def correlation_sweep(strategy_fn, num_trials, num_angles, seed):
    """Sweep alpha_B from 0 to 2*pi with alpha_A fixed at 0.
    Returns (deltas, E_values)."""
    rng = np.random.default_rng(seed)
    deltas = np.linspace(0.0, 2.0 * math.pi, num_angles)
    correlations = np.empty(num_angles)
    alpha_a = 0.0
    for i, delta in enumerate(deltas):
        alpha_b = float(delta)
        bits_a, bits_b = strategy_fn(alpha_a, alpha_b, num_trials, rng)
        correlations[i] = float(np.mean(bits_a * bits_b))
    return deltas, correlations


def main():
    print(f"Sweeping correlation curves at {NUM_ANGLES} angles, {NUM_TRIALS} trials each...")

    # Run each variant
    deltas, E_v1 = correlation_sweep(naive_probabilistic, NUM_TRIALS, NUM_ANGLES, 0xC5C5)
    print("  V1 done")
    _, E_v2 = correlation_sweep(deterministic_sign, NUM_TRIALS, NUM_ANGLES, 0xD3D3)
    print("  V2 done")
    _, E_v8 = correlation_sweep(bound_qubit_pair, NUM_TRIALS, NUM_ANGLES, 0x8888)
    print("  V8 done")
    _, E_v4 = correlation_sweep(quantum_singlet, NUM_TRIALS, NUM_ANGLES, 0xF7F7)
    print("  V4 done")

    # V1 and V2 produce correlated outputs at delta=0 (same probability/sign function
    # on both sides). V4 (singlet) and V8 (Bohmian, also tracking the singlet)
    # produce anti-correlated outputs at delta=0. Flip V1 and V2 so all four are on
    # the same anti-correlation convention, which makes the geometric comparison direct.
    E_v1 = -E_v1
    E_v2 = -E_v2
    # V8 is already in the singlet convention (built that way).

    # Theoretical reference curves
    delta_smooth = np.linspace(0.0, 2.0 * math.pi, 400)
    E_classical_theory = np.where(
        delta_smooth <= math.pi,
        -1.0 + 2.0 * delta_smooth / math.pi,           # rising line on [0, pi]
        3.0 - 2.0 * delta_smooth / math.pi,            # falling line on [pi, 2*pi]
    )
    E_quantum_theory = -np.cos(delta_smooth)

    # ------------------------------------------------------------------
    # Build the figure
    # ------------------------------------------------------------------
    fig, ax = plt.subplots(figsize=(11, 6.5))

    # Theory references first (background)
    ax.fill_between(
        delta_smooth, E_classical_theory, E_quantum_theory,
        where=(np.abs(E_quantum_theory) > np.abs(E_classical_theory)),
        color="orange", alpha=0.15, label="Bell gap (quantum exceeds classical)",
    )
    ax.plot(delta_smooth, E_classical_theory, "k--", alpha=0.45,
            linewidth=1.2, label="theory: classical triangle wave")
    ax.plot(delta_smooth, E_quantum_theory, "r--", alpha=0.5,
            linewidth=1.4, label="theory: -cos(δ) singlet")

    # Empirical data points (foreground)
    ax.plot(deltas, E_v1, "o", color="#888888", markersize=5, alpha=0.85,
            label="V1: naive probabilistic (sub-classical)")
    ax.plot(deltas, E_v2, "s", color="#1f77b4", markersize=5, alpha=0.85,
            label="V2: deterministic Bell-saturating classical")
    ax.plot(deltas, E_v4, "d", color="#d62728", markersize=5, alpha=0.85,
            label="V4: quantum singlet (Born rule)")
    ax.plot(deltas, E_v8, "^", color="#2ca02c", markersize=5, alpha=0.85,
            label="V8: Bohmian sub-resolution binding")

    # CHSH-optimal angles as vertical markers
    chsh_angles = [math.pi / 4, 3 * math.pi / 4, 5 * math.pi / 4, 7 * math.pi / 4]
    for i, angle in enumerate(chsh_angles):
        ax.axvline(x=angle, color="gray", alpha=0.35, linestyle=":", linewidth=0.9)
    # Label them only once
    ax.text(math.pi / 4, 1.05, "π/4", ha="center", fontsize=8, color="gray")
    ax.text(3 * math.pi / 4, 1.05, "3π/4", ha="center", fontsize=8, color="gray")
    ax.text(5 * math.pi / 4, 1.05, "5π/4", ha="center", fontsize=8, color="gray")
    ax.text(7 * math.pi / 4, 1.05, "7π/4", ha="center", fontsize=8, color="gray")

    # Axes
    ax.set_xlabel("δ = α_B − α_A   (Bob's angle minus Alice's angle, radians)", fontsize=11)
    ax.set_ylabel("Correlation  E(δ) = ⟨b_A · b_B⟩", fontsize=11)
    ax.set_title(
        "The geometric signature of entanglement: classical triangle vs quantum cosine\n"
        "(empirical data from chsh_prototype.py with 30,000 trials per angle)",
        fontsize=12,
    )
    ax.legend(loc="lower right", fontsize=8.5, framealpha=0.9)
    ax.grid(True, alpha=0.3)
    ax.set_ylim(-1.18, 1.18)
    ax.set_xlim(0, 2 * math.pi)
    ax.set_xticks([0, math.pi / 2, math.pi, 3 * math.pi / 2, 2 * math.pi])
    ax.set_xticklabels(["0", "π/2", "π", "3π/2", "2π"])

    # Annotate the key visual finding
    ax.annotate(
        "Quantum cosine (V4, V8)\nhas LARGER magnitude than\nthe Bell-saturating triangle (V2)\n"
        "at the CHSH-optimal angles π/4, 3π/4.\nThis is why quantum reaches S = 2√2.",
        xy=(math.pi / 4, -math.sqrt(2) / 2),
        xytext=(0.4, -0.35),
        fontsize=8.5,
        bbox=dict(boxstyle="round,pad=0.4", fc="wheat", alpha=0.8),
        arrowprops=dict(arrowstyle="->", color="black", alpha=0.5, lw=0.8),
    )

    plt.tight_layout()

    # Save next to the script
    output_path = "/Users/jeffbachand/www/JeffJS/Sources/JeffJS/Quantum/chsh_correlation_curves.png"
    plt.savefig(output_path, dpi=150)
    print(f"\nSaved {output_path}")

    # Sanity check at the CHSH-optimal angles
    print("\nSanity check at delta = pi/4 (one of the four CHSH-optimal angles):")
    idx = np.argmin(np.abs(deltas - math.pi / 4))
    delta_actual = deltas[idx]
    print(f"  delta = {delta_actual:.4f}  (target pi/4 = {math.pi/4:.4f})")
    print(f"  V1 (naive prob, flipped): E = {E_v1[idx]:+.4f}   (theory: {-0.5*math.cos(delta_actual):+.4f})")
    print(f"  V2 (det. sign, flipped) : E = {E_v2[idx]:+.4f}   (theory triangle: {-1+2*delta_actual/math.pi:+.4f})")
    print(f"  V8 (Bohmian)           : E = {E_v8[idx]:+.4f}   (theory: {-math.cos(delta_actual):+.4f})")
    print(f"  V4 (quantum singlet)   : E = {E_v4[idx]:+.4f}   (theory: {-math.cos(delta_actual):+.4f})")


if __name__ == "__main__":
    main()
