#!/usr/bin/env python3
"""
waist_tomography.py — The CHSH correlation curve IS the hourglass waist
cross-section, viewed from above.

Left panel: the correlation curves from Figure 1 (E vs δ)
Right panel: the SAME data plotted in polar coordinates = the waist shape

The quantum cosine traces a CIRCLE (L₂ norm ball).
The classical triangle traces a DIAMOND (L∞ norm ball).
The Tsirelson bound (√2 at 45°) is the geometric difference between them.
"""

import numpy as np
import matplotlib.pyplot as plt
import math


def main():
    fig, axes = plt.subplots(1, 2, figsize=(16, 8), facecolor='#08081a')

    delta = np.linspace(0, 2 * np.pi, 500)

    # Correlation functions
    E_quantum = -np.cos(delta)          # quantum singlet: -cos(δ)
    E_classical = np.where(             # classical Bell: triangle wave
        delta <= np.pi,
        -1 + 2 * delta / np.pi,
        3 - 2 * delta / np.pi
    )

    # =============================================
    # LEFT: Standard correlation plot (like Fig 1)
    # =============================================
    ax1 = axes[0]
    ax1.set_facecolor('#0a0a16')

    ax1.plot(delta, E_classical, color='#3399ff', linewidth=2.5,
             label='Classical (triangle wave)', alpha=0.9)
    ax1.plot(delta, E_quantum, color='#ff4466', linewidth=2.5,
             label='Quantum (−cos δ)', alpha=0.9)

    # Mark the CHSH-optimal angles
    for d in [np.pi/4, 3*np.pi/4]:
        ax1.axvline(x=d, color='#ffffff', alpha=0.15, linestyle=':')
        # Show the gap at π/4
        e_q = -np.cos(d)
        e_c = -1 + 2*d/np.pi
        ax1.plot([d, d], [e_c, e_q], color='#ffaa00', linewidth=3, alpha=0.8)

    ax1.annotate(f'gap = √2/2 − 1/2\n= {np.sqrt(2)/2 - 0.5:.3f}',
                 xy=(np.pi/4, (-np.cos(np.pi/4) + (-1+2*np.pi/4/np.pi))/2),
                 xytext=(np.pi/4 + 0.5, -0.15),
                 color='#ffaa00', fontsize=10,
                 arrowprops=dict(arrowstyle='->', color='#ffaa00', alpha=0.6))

    ax1.set_xlabel('δ = α_B − α_A  (angle difference)', color='#aaaacc', fontsize=11)
    ax1.set_ylabel('Correlation E(δ)', color='#aaaacc', fontsize=11)
    ax1.set_title('CHSH Correlation Curves\n(the measurement)',
                  color='white', fontsize=13)
    ax1.legend(loc='lower right', fontsize=9, facecolor='#1a1a2e',
               edgecolor='#444466', labelcolor='#ccccdd')
    ax1.set_xticks([0, np.pi/4, np.pi/2, np.pi, 3*np.pi/2, 2*np.pi])
    ax1.set_xticklabels(['0', 'π/4', 'π/2', 'π', '3π/2', '2π'],
                        color='#888899')
    ax1.set_yticks([-1, -0.5, 0, 0.5, 1])
    ax1.tick_params(colors='#888899')
    ax1.grid(True, alpha=0.1, color='#444466')
    ax1.set_ylim(-1.15, 1.15)
    for spine in ax1.spines.values():
        spine.set_edgecolor('#333355')

    # =============================================
    # RIGHT: Polar plot = waist cross-section
    # =============================================
    ax2 = axes[1]
    ax2.set_facecolor('#0a0a16')

    # Convert to polar: r = |E(δ)|, θ = δ
    r_quantum = np.abs(E_quantum)
    r_classical = np.abs(E_classical)

    # Plot in Cartesian from polar coords for better control
    x_q = r_quantum * np.cos(delta)
    y_q = r_quantum * np.sin(delta)
    x_c = r_classical * np.cos(delta)
    y_c = r_classical * np.sin(delta)

    # Fill the shapes
    ax2.fill(x_c, y_c, color='#3399ff', alpha=0.08)
    ax2.fill(x_q, y_q, color='#ff4466', alpha=0.08)

    # Draw the outlines
    ax2.plot(x_c, y_c, color='#3399ff', linewidth=2.5,
             label='Classical waist (diamond/L∞)', alpha=0.9)
    ax2.plot(x_q, y_q, color='#ff4466', linewidth=2.5,
             label='Quantum waist (oval/L₂)', alpha=0.9)

    # The orange waist ring from the hourglass (at scale)
    waist_r = 0.28
    th = np.linspace(0, 2*np.pi, 100)
    ax2.plot(waist_r * np.cos(th), waist_r * np.sin(th),
             color='#ff9933', linewidth=2, alpha=0.5, linestyle='--',
             label=f'I_max barrier (r={waist_r})')

    # Mark the measurement angles at π/4
    for angle in [np.pi/4, 3*np.pi/4, 5*np.pi/4, 7*np.pi/4]:
        r_q = abs(-np.cos(angle))
        r_c_val = abs(-1 + 2*angle/np.pi) if angle <= np.pi else abs(3 - 2*angle/np.pi)
        # Line from origin to quantum boundary
        ax2.plot([0, r_q * np.cos(angle)], [0, r_q * np.sin(angle)],
                 color='#ff4466', linewidth=0.8, alpha=0.4)
        # Gap marker
        ax2.plot(r_q * np.cos(angle), r_q * np.sin(angle),
                 'o', color='#ff4466', markersize=6, zorder=10)
        ax2.plot(r_c_val * np.cos(angle), r_c_val * np.sin(angle),
                 's', color='#3399ff', markersize=6, zorder=10)

    # Annotate the √2 gap at 45°
    angle_45 = np.pi / 4
    r_q_45 = abs(np.cos(angle_45))   # √2/2
    r_c_45 = 0.5                      # triangle at π/4
    mid_r = (r_q_45 + r_c_45) / 2
    ax2.annotate(
        f'√2/2 vs 1/2\nratio = √2',
        xy=(mid_r * np.cos(angle_45), mid_r * np.sin(angle_45)),
        xytext=(0.85, 0.85),
        color='#ffaa00', fontsize=10, fontweight='bold',
        arrowprops=dict(arrowstyle='->', color='#ffaa00', alpha=0.7))

    # Axis lines
    ax2.axhline(y=0, color='#444466', linewidth=0.5, alpha=0.3)
    ax2.axvline(x=0, color='#444466', linewidth=0.5, alpha=0.3)

    ax2.set_xlim(-1.15, 1.15)
    ax2.set_ylim(-1.15, 1.15)
    ax2.set_aspect('equal')
    ax2.set_title('Waist Cross-Section (polar view)\n'
                  'the same data = the shape of the hole',
                  color='white', fontsize=13)
    ax2.legend(loc='lower right', fontsize=8.5, facecolor='#1a1a2e',
               edgecolor='#444466', labelcolor='#ccccdd')
    ax2.set_xlabel('x = |E| cos(δ)', color='#888899', fontsize=10)
    ax2.set_ylabel('y = |E| sin(δ)', color='#888899', fontsize=10)
    ax2.tick_params(colors='#888899')
    for spine in ax2.spines.values():
        spine.set_edgecolor('#333355')

    # Title for the whole figure
    fig.suptitle(
        'The CHSH correlation curve IS the hourglass waist cross-section\n'
        'Left: correlation vs angle (measurement).  Right: same data in polar (waist shape).',
        color='white', fontsize=14, y=0.98)

    fig.text(0.5, 0.01,
             'The quantum waist is an oval (L₂ norm). '
             'The classical waist is a diamond (L∞ norm). '
             'At 45° the oval is √2 wider → Tsirelson bound.',
             color='#aaaacc', fontsize=9, ha='center', style='italic')

    plt.tight_layout(rect=[0, 0.03, 1, 0.94])

    out = '/Users/jeffbachand/www/JeffJS/Sources/JeffJS/Quantum/waist_tomography.png'
    plt.savefig(out, dpi=150, facecolor='#08081a', bbox_inches='tight')
    print(f'Saved {out}')


if __name__ == '__main__':
    main()
