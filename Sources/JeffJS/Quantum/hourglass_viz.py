#!/usr/bin/env python3
"""
hourglass_viz.py — 3D Hourglass Resolution Model of Entanglement.
One continuous surface: spherical at each end, smoothly tapering to
a narrow choke point at the I_max barrier in the middle.
"""

import numpy as np
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d import Axes3D
import math


def profile(z):
    """Continuous hourglass: spherical envelope pinched at the waist.
    Closed at both poles (z = ±H), widest at the sphere equators,
    narrowest at z = 0 (the I_max barrier)."""
    H = 3.2       # half-height (poles at ±H)
    A = 1.5       # max radius
    depth = 0.83  # waist pinch depth (0 = no pinch, 1 = closes to zero)
    width = 0.75  # pinch width

    if abs(z) >= H:
        return 0.0
    envelope = math.sqrt(1 - (z / H) ** 2)          # spherical closure
    pinch = 1 - depth * math.exp(-z**2 / width**2)   # Gaussian waist dip
    return A * envelope * pinch


def main():
    fig = plt.figure(figsize=(10, 16), facecolor='#08081a')
    ax = fig.add_subplot(111, projection='3d', facecolor='#08081a')

    H = 3.2
    A = 1.5

    # --- Surface ---
    n_z, n_th = 200, 80
    z_arr = np.linspace(-H * 0.998, H * 0.998, n_z)
    th_arr = np.linspace(0, 2 * np.pi, n_th)
    Z, TH = np.meshgrid(z_arr, th_arr)
    R = np.vectorize(profile)(Z)
    X = R * np.cos(TH)
    Y = R * np.sin(TH)

    # Colors: blue above, violet below, orange glow at waist — very transparent
    colors = np.zeros((*Z.shape, 4))
    for i in range(Z.shape[0]):
        for j in range(Z.shape[1]):
            zz = Z[i, j]
            waist_glow = math.exp(-zz**2 / 0.2)
            if zz > 0.15:
                colors[i, j] = [0.2, 0.45, 0.85, 0.06]
            elif zz < -0.15:
                colors[i, j] = [0.45, 0.15, 0.7, 0.06]
            else:
                colors[i, j] = [1.0, 0.55, 0.1, 0.15 + 0.3 * waist_glow]

    ax.plot_surface(X, Y, Z, facecolors=colors, shade=False,
                    antialiased=True, rstride=1, cstride=1)

    # --- Light wireframe: meridians ---
    n_meridians = 14
    for k in range(n_meridians):
        angle = 2 * np.pi * k / n_meridians
        zw = np.linspace(-H * 0.995, H * 0.995, 300)
        rw = np.array([profile(zz) for zz in zw])
        xw = rw * np.cos(angle)
        yw = rw * np.sin(angle)
        # Single-color, very light
        above = zw > 0.1
        below = zw < -0.1
        mid = ~above & ~below
        ax.plot(xw[above], yw[above], zw[above],
                color='#5599dd', linewidth=0.3, alpha=0.15)
        ax.plot(xw[below], yw[below], zw[below],
                color='#8866cc', linewidth=0.3, alpha=0.15)
        ax.plot(xw[mid], yw[mid], zw[mid],
                color='#ff9933', linewidth=0.5, alpha=0.3)

    # --- Light wireframe: latitude rings ---
    th_ring = np.linspace(0, 2 * np.pi, 120)
    for zl in [0.8, 1.4, 2.0, 2.5, -0.8, -1.4, -2.0, -2.5]:
        r = profile(zl)
        c = '#5599dd' if zl > 0 else '#8866cc'
        ax.plot(r * np.cos(th_ring), r * np.sin(th_ring),
                np.full_like(th_ring, zl),
                color=c, linewidth=0.3, alpha=0.12)

    # --- Waist ring: bright orange I_max barrier ---
    r_w = profile(0)
    ax.plot(r_w * np.cos(th_ring), r_w * np.sin(th_ring),
            np.zeros_like(th_ring),
            color='#ff9933', linewidth=3.5, alpha=0.95, zorder=10)
    for dr, a in [(1.2, 0.35), (1.5, 0.15)]:
        ax.plot(r_w * dr * np.cos(th_ring), r_w * dr * np.sin(th_ring),
                np.zeros_like(th_ring),
                color='#ff9933', linewidth=1.0, alpha=a, zorder=9)

    # --- Particles at sphere centers ---
    p_z = 1.8  # approximate equator of each bulge
    ax.scatter(0, 0, p_z, s=180, c='#ffd54a', edgecolors='#ffaa00',
               linewidths=2, zorder=20, depthshade=False)
    ax.scatter(0, 0, -p_z, s=180, c='#aa77ff', edgecolors='#7744cc',
               linewidths=2, zorder=20, depthshade=False)

    # --- Interference helices through the waist ---
    link_z = np.linspace(-p_z, p_z, 250)
    tightness = np.exp(-4 * link_z**2)
    link_r = 0.04 + 0.1 * tightness
    for phase, color in [(0, '#44ffaa'), (np.pi, '#ff5588')]:
        lx = link_r * np.cos(link_z * 6 + phase)
        ly = link_r * np.sin(link_z * 6 + phase)
        for s in range(0, len(link_z) - 3, 3):
            a = 0.25 + 0.65 * math.exp(-link_z[s]**2 / 0.4)
            ax.plot(lx[s:s+4], ly[s:s+4], link_z[s:s+4],
                    color=color, linewidth=1.6, alpha=a, zorder=15)

    # --- Labels: OUTSIDE the surface so they're readable ---
    ax.text(A + 0.4, 0, p_z + 0.3, 'OBSERVABLE\nREGION',
            color='#aaccff', fontsize=11, ha='left', fontweight='bold')
    ax.text(A + 0.4, 0, -(p_z + 0.3), 'SUB-RESOLUTION\nREGION',
            color='#cc99ff', fontsize=11, ha='left', fontweight='bold')
    ax.text(A + 0.4, 0, 0.0, r'$\longleftarrow$  $I_{\max}$ BARRIER',
            color='#ff9933', fontsize=14, ha='left', fontweight='bold')
    ax.text(A + 0.4, 0, p_z - 0.3, 'particle\n(spacetime displacement)',
            color='#ffd54a', fontsize=8, ha='left')
    ax.text(A + 0.4, 0, -(p_z - 0.1), 'entangled partner\n(sub-resolution)',
            color='#aa77ff', fontsize=8, ha='left')
    ax.text(-A - 0.3, 0, 0.5, 'interference flows\nthrough the waist',
            color='#55ff88', fontsize=8, ha='right', style='italic')

    # --- Title ---
    ax.set_title(
        'Hourglass Resolution Model of Entanglement\n'
        'Spherical spacetime displacement connected through the '
        r'$I_{\max}$ barrier',
        color='white', fontsize=13, pad=15)

    # --- Styling ---
    ax.set_xlim(-A * 1.3, A * 1.3)
    ax.set_ylim(-A * 1.3, A * 1.3)
    ax.set_zlim(-H, H)
    ax.set_box_aspect([1, 1, H / (A * 1.3)])
    ax.set_xticklabels([])
    ax.set_yticklabels([])
    ax.set_zticklabels([])
    ax.set_xlabel('')
    ax.set_ylabel('')
    ax.set_zlabel('')
    ax.view_init(elev=12, azim=38)
    ax.xaxis.pane.fill = False
    ax.yaxis.pane.fill = False
    ax.zaxis.pane.fill = False
    ax.xaxis.pane.set_edgecolor('#1a1a2e')
    ax.yaxis.pane.set_edgecolor('#1a1a2e')
    ax.zaxis.pane.set_edgecolor('#1a1a2e')
    ax.grid(True, alpha=0.06, color='#333355')

    fig.text(0.5, 0.02,
             'Each bulge is the spacetime displacement of the particle.\n'
             'The hourglass waist at the $I_{max}$ barrier is the narrowest channel\n'
             'through which quantum interference flows between the two regions.',
             color='#aaaacc', fontsize=9, ha='center', style='italic')

    out = '/Users/jeffbachand/www/JeffJS/Sources/JeffJS/Quantum/hourglass_model.png'
    plt.savefig(out, dpi=150, facecolor='#08081a', bbox_inches='tight')
    print(f'Saved {out}')


if __name__ == '__main__':
    main()
