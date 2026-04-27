#!/usr/bin/env python3
"""
qubit_field_entanglement_viz.py — visualize the chain encoder's qubit field
with multi-resolution octree overlays and visible entanglement links between
paired qubits across two fields.

Three outputs are generated:
  1. qubit_field_entanglement.png  — static snapshot at t=0
  2. qubit_field_filmstrip.png     — 4-frame filmstrip showing time evolution
  3. qubit_field_entanglement.gif  — animated GIF (48 frames, ~4 seconds loop)

Mathematical backing:
  - Qubit positions are deterministic from a seed (matches the chain encoder)
  - The octree grid at level k divides each axis into 2^k cells
  - The cell-center mapping matches the chain encoder's:
        fvx = (vx_int + 0.5) / 2^level * field_size
  - Phase rotation: phase(t) = phases[i] + speeds[i] * t
  - The "binding" between paired qubits is the V8 sub-resolution phase link
    (rendered as a curve; in the chain encoder it's a hidden phase update)

Run:
    python3 qubit_field_entanglement_viz.py
"""

import math
import os

import numpy as np
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import Circle, ConnectionPatch
from PIL import Image

FIELD_SIZE = 32.0
N_QUBITS = 256
SEED = 0xC5C5_FEED

OUTPUT_DIR = os.path.dirname(os.path.abspath(__file__))


def generate_field(seed):
    """Generate 256 qubits with deterministic positions, motions, and phases."""
    rng = np.random.default_rng(seed)
    positions = rng.uniform(1.0, FIELD_SIZE - 1.0, size=(N_QUBITS, 2))
    speeds = rng.uniform(0.0, 2.0 * math.pi, size=N_QUBITS)
    radii = rng.uniform(0.20, 0.45, size=N_QUBITS)
    phases = rng.uniform(0.0, 2.0 * math.pi, size=N_QUBITS)
    return positions, speeds, radii, phases


def draw_octree_grid(ax, level, color, alpha, lw):
    n = 2 ** level
    step = FIELD_SIZE / n
    for i in range(n + 1):
        ax.axvline(x=i * step, color=color, alpha=alpha, lw=lw, zorder=0)
        ax.axhline(y=i * step, color=color, alpha=alpha, lw=lw, zorder=0)


def highlight_cell(ax, position, level, color, lw=2.0):
    n = 2 ** level
    step = FIELD_SIZE / n
    cell_x = int(position[0] / step) * step
    cell_y = int(position[1] / step) * step
    rect = mpatches.Rectangle(
        (cell_x, cell_y), step, step,
        facecolor=color, alpha=0.18,
        edgecolor=color, linewidth=lw,
        zorder=1,
    )
    ax.add_patch(rect)


def draw_field(ax, positions, speeds, radii, phases, t=0.0, title="Field A",
               compact=False):
    """Render a 2D qubit field at time t."""
    ax.set_xlim(0, FIELD_SIZE)
    ax.set_ylim(0, FIELD_SIZE)
    ax.set_aspect("equal")
    ax.set_facecolor("#0a0a16")

    draw_octree_grid(ax, level=5, color="#445599", alpha=0.22, lw=0.5)
    draw_octree_grid(ax, level=4, color="#7799cc", alpha=0.45, lw=0.9)
    draw_octree_grid(ax, level=3, color="#aaccff", alpha=0.65, lw=1.6 if not compact else 1.1)

    arrow_lw = 1.1 if not compact else 0.7
    for i in range(N_QUBITS):
        x, y = positions[i]
        r = radii[i]
        phase = phases[i] + speeds[i] * t

        halo = Circle((x, y), r * 1.8, color="#ffd54a", alpha=0.10, zorder=2)
        ax.add_patch(halo)

        circle = Circle((x, y), r, color="#ffd54a", alpha=0.90, zorder=3)
        ax.add_patch(circle)

        dx = r * 1.6 * math.cos(phase)
        dy = r * 1.6 * math.sin(phase)
        ax.plot(
            [x, x + dx], [y, y + dy],
            color="#ff7755", alpha=0.92, lw=arrow_lw, solid_capstyle="round",
            zorder=4,
        )

    ax.set_title(title, color="white", fontsize=11 if not compact else 9, pad=6)
    ax.tick_params(colors="#7777aa", labelsize=6 if not compact else 5)
    for spine in ax.spines.values():
        spine.set_edgecolor("#7777aa")
        spine.set_linewidth(0.7)


def draw_entanglement_link(fig, ax_a, ax_b, positions, radii, idx, level,
                           level_color, label, label_offset, draw_label=True):
    pos_a = (positions[idx][0], positions[idx][1])
    pos_b = (positions[idx][0], positions[idx][1])

    highlight_cell(ax_a, pos_a, level, level_color)
    highlight_cell(ax_b, pos_b, level, level_color)

    rad = 0.18 + 0.10 * (level - 3)
    con = ConnectionPatch(
        xyA=pos_a, coordsA=ax_a.transData,
        xyB=pos_b, coordsB=ax_b.transData,
        connectionstyle=f"arc3,rad={rad}",
        color=level_color, alpha=0.95, lw=2.0,
        zorder=20,
    )
    fig.add_artist(con)

    for ax, pos in [(ax_a, pos_a), (ax_b, pos_b)]:
        ring = Circle(
            pos, radii[idx] * 2.6,
            facecolor="none", edgecolor=level_color, lw=1.6, alpha=1.0,
            zorder=15,
        )
        ax.add_patch(ring)

    if draw_label:
        ax_a_disp = ax_a.transData.transform(pos_a)
        ax_b_disp = ax_b.transData.transform(pos_b)
        fig_disp = ((ax_a_disp[0] + ax_b_disp[0]) / 2,
                    (ax_a_disp[1] + ax_b_disp[1]) / 2 + label_offset)
        fig_norm = fig.transFigure.inverted().transform(fig_disp)
        fig.text(
            fig_norm[0], fig_norm[1], label,
            color=level_color, fontsize=8.5, ha="center",
            weight="bold", alpha=1.0,
            bbox=dict(boxstyle="round,pad=0.25", fc="#06060e", ec=level_color, lw=0.8, alpha=0.85),
        )


# ---------------------------------------------------------------------
# Frame rendering — produces a fresh figure at time t
# ---------------------------------------------------------------------

def draw_sub_resolution_barrier(ax_strip, n_finer=64, label_barrier=True):
    """Render the sub-resolution layer in the middle strip.
    The strip shows a finer grid (level 6 = 64 cells per axis), bordered by
    thick orange 'barrier' lines that represent the observer resolution ceiling
    (I_max). The entanglement binding lives below this barrier."""
    ax_strip.set_xlim(0, 1)
    ax_strip.set_ylim(0, FIELD_SIZE)
    ax_strip.set_facecolor("#15152a")
    ax_strip.set_xticks([])
    ax_strip.set_yticks([])

    # Finer grid lines (level 6 — finer than the level-5 in the side panels)
    step = FIELD_SIZE / n_finer
    for i in range(1, n_finer):
        y = i * step
        # Brighter every fourth line so the eye sees the structure
        if i % 4 == 0:
            ax_strip.axhline(y=y, color="#7799ee", lw=0.4, alpha=0.55, zorder=2)
        else:
            ax_strip.axhline(y=y, color="#5577cc", lw=0.25, alpha=0.32, zorder=2)

    # Vertical "barrier" walls at the strip's left and right edges
    for spine_name in ("left", "right"):
        ax_strip.spines[spine_name].set_edgecolor("#ff9933")
        ax_strip.spines[spine_name].set_linewidth(2.5)
        ax_strip.spines[spine_name].set_alpha(0.9)
    for spine_name in ("top", "bottom"):
        ax_strip.spines[spine_name].set_edgecolor("#7777aa")
        ax_strip.spines[spine_name].set_linewidth(0.6)

    if label_barrier:
        # Title above the strip
        ax_strip.set_title(
            "I_max\nbarrier",
            color="#ff9933", fontsize=8, pad=4,
            fontweight="bold",
        )
        # Vertical label down the middle of the strip
        ax_strip.text(
            0.5, FIELD_SIZE / 2,
            "sub-resolution layer\n(level 6 — 64×64 cells)\nbinding lives here",
            color="#aaccff", fontsize=7.5,
            ha="center", va="center",
            rotation=90,
            alpha=0.85,
            bbox=dict(boxstyle="round,pad=0.3", fc="#06060e", ec="#aaccff",
                      lw=0.6, alpha=0.75),
        )


def render_frame(t, positions, speeds, radii, phases, pairs,
                 figsize=(15, 7.5), draw_labels=True, suptitle=None):
    """Render a complete two-field figure at time t with a sub-resolution
    barrier strip in the middle. Returns the figure."""
    fig = plt.figure(figsize=figsize, facecolor="#06060e")
    gs = fig.add_gridspec(
        1, 3,
        width_ratios=[1.0, 0.16, 1.0],
        left=0.04, right=0.96, top=0.86, bottom=0.06,
        wspace=0.07,
    )
    ax_a = fig.add_subplot(gs[0, 0])
    ax_strip = fig.add_subplot(gs[0, 1])
    ax_b = fig.add_subplot(gs[0, 2])

    draw_field(ax_a, positions, speeds, radii, phases, t=t,
               title=r"Field $F_A$  (procedural seed)")
    draw_field(ax_b, positions, speeds, radii, phases, t=t,
               title=r"Field $F_B$  (same seed, paired qubits)")

    # The middle strip — sub-resolution layer with the I_max barrier
    draw_sub_resolution_barrier(ax_strip, n_finer=64, label_barrier=draw_labels)

    for idx, level, color, label, offset in pairs:
        draw_entanglement_link(
            fig, ax_a, ax_b, positions, radii,
            idx, level, color, label, offset, draw_label=draw_labels,
        )

    if suptitle:
        fig.suptitle(suptitle, color="white", fontsize=12, y=0.96)

    return fig


# ---------------------------------------------------------------------
# Filmstrip — multi-frame paper figure showing time evolution
# ---------------------------------------------------------------------

def make_filmstrip(positions, speeds, radii, phases, pairs, output_path,
                   n_frames=4):
    """Generate a multi-row filmstrip figure with the sub-resolution barrier
    strip in each row."""
    fig = plt.figure(figsize=(14, 22), facecolor="#06060e")
    gs = fig.add_gridspec(
        n_frames, 3,
        width_ratios=[1.0, 0.16, 1.0],
        left=0.05, right=0.96, top=0.96, bottom=0.04,
        hspace=0.18, wspace=0.07,
    )

    times = np.linspace(0.0, 2.0 * math.pi * 0.85, n_frames)
    for row, t in enumerate(times):
        ax_a = fig.add_subplot(gs[row, 0])
        ax_strip = fig.add_subplot(gs[row, 1])
        ax_b = fig.add_subplot(gs[row, 2])
        time_label = f"t = {t:.2f}"

        draw_field(ax_a, positions, speeds, radii, phases, t=t,
                   title=rf"$F_A$ at {time_label}", compact=True)
        draw_field(ax_b, positions, speeds, radii, phases, t=t,
                   title=rf"$F_B$ at {time_label}", compact=True)

        # Sub-resolution barrier strip — only label in the first row to save space
        draw_sub_resolution_barrier(
            ax_strip, n_finer=64, label_barrier=(row == 0),
        )

        for idx, level, color, label, offset in pairs:
            draw_entanglement_link(
                fig, ax_a, ax_b, positions, radii,
                idx, level, color, label, offset, draw_label=False,
            )

    plt.savefig(output_path, dpi=140, facecolor="#06060e", edgecolor="none")
    plt.close(fig)
    print(f"Saved {output_path}")


# ---------------------------------------------------------------------
# Animated GIF — 48 frames of phase rotation
# ---------------------------------------------------------------------

def make_animation(positions, speeds, radii, phases, pairs, output_path,
                   n_frames=48, fps=12):
    """Generate an animated GIF showing qubit phase rotation over time t.
    Each frame is rendered as a PIL Image (via savefig + Image.open) and
    composed into a GIF with PIL."""
    print(f"Generating {n_frames} animation frames...")
    frame_dir = "/tmp/qubit_field_frames"
    os.makedirs(frame_dir, exist_ok=True)

    images = []
    for i in range(n_frames):
        t = 2.0 * math.pi * i / n_frames
        fig = render_frame(
            t, positions, speeds, radii, phases, pairs,
            figsize=(11, 5.7), draw_labels=False,
            suptitle=rf"Qubit field — phase rotation at t = {t:.2f}",
        )
        frame_path = f"{frame_dir}/frame_{i:03d}.png"
        fig.savefig(frame_path, dpi=80, facecolor="#06060e", edgecolor="none")
        plt.close(fig)
        images.append(Image.open(frame_path).convert("P", palette=Image.ADAPTIVE))
        if (i + 1) % 12 == 0:
            print(f"  rendered {i + 1}/{n_frames}")

    print("Composing GIF...")
    duration_ms = int(1000 / fps)
    images[0].save(
        output_path,
        save_all=True,
        append_images=images[1:],
        duration=duration_ms,
        loop=0,
        optimize=True,
        disposal=2,
    )
    print(f"Saved {output_path}")


# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------

def main():
    positions, speeds, radii, phases = generate_field(SEED)

    pairs = [
        (28,  3, "#ff5577", "level-3 link  (8×8 cell)",   45),
        (114, 4, "#55ccff", "level-4 link  (16×16 cell)", 60),
        (203, 5, "#88ff77", "level-5 link  (32×32 cell)", 75),
    ]

    # 1. Static snapshot at t=0
    fig = render_frame(
        0.0, positions, speeds, radii, phases, pairs,
        figsize=(15, 7.5),
        suptitle=(
            "Qubit field with multi-resolution octree overlay and entanglement links\n"
            r"Two procedural fields $F_A$ and $F_B$ sharing the same seed; "
            "selected qubit pairs linked across resolution layers via Bohmian sub-resolution binding (V8)"
        ),
    )
    fig.text(
        0.5, 0.015,
        ("Each yellow circle is a qubit at a deterministic position (256 per field). "
         "Orange arrows show phase orientation. "
         "Faint blue grids are nested octree resolution layers (8×8, 16×16, 32×32). "
         "Curved colored threads are entanglement links — sub-resolution phase bindings between paired qubits."),
        color="#bbbbcc", fontsize=8.2, ha="center", style="italic",
    )
    static_path = os.path.join(OUTPUT_DIR, "qubit_field_entanglement.png")
    fig.savefig(static_path, dpi=140, facecolor="#06060e", edgecolor="none")
    plt.close(fig)
    print(f"Saved {static_path}")

    # 2. Filmstrip — 4 time slices for the paper
    filmstrip_path = os.path.join(OUTPUT_DIR, "qubit_field_filmstrip.png")
    make_filmstrip(positions, speeds, radii, phases, pairs, filmstrip_path, n_frames=4)

    # 3. Animated GIF — full phase rotation
    gif_path = os.path.join(OUTPUT_DIR, "qubit_field_entanglement.gif")
    make_animation(positions, speeds, radii, phases, pairs, gif_path,
                   n_frames=48, fps=12)


if __name__ == "__main__":
    main()
