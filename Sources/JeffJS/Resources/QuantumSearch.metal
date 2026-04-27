// QuantumSearch.metal
// GPU-accelerated search kernels for the quantum cache & transport engine.
//
// Three kernels:
//   1. search_by_slice     - Find positions whose payload popcount falls in a target slice.
//   2. search_payload_exact - Find positions with an exact payload match.
//   3. search_and_trace    - Combined: find first-slice match, trace chain, verify full sequence.

#include <metal_stdlib>
using namespace metal;

// MARK: - Types & Constants

struct Qubit { float x, y, speed, radius, phase; };

constant uint NUM_QUBITS   = 256;
constant uint TOTAL_BITS   = 25;
constant uint GRID_VX      = 32;
constant uint GRID_VY      = 32;
constant uint GRID_T       = 32;
constant uint GRID_OFFSET  = 32;
constant float T_SCALE     = 0.1f;
constant uint END_MARKER_LOW  = 2;
constant uint END_MARKER_HIGH = 23;
constant uint DATA_BITS    = 2;
constant uint NUM_SLICES   = 4;   // 1 << DATA_BITS

// MARK: - Helpers

uint popcount25(uint n) {
    return popcount(n & 0x1FFFFFF);
}

uint popcount_to_slice(uint pop) {
    if (pop <= END_MARKER_LOW)  return 255;   // end marker low
    if (pop >= END_MARKER_HIGH) return 254;   // end marker high

    uint usable_min   = END_MARKER_LOW + 1;   // 3
    uint usable_range = (END_MARKER_HIGH - 1) - usable_min + 1; // 20
    uint slice_size   = usable_range / NUM_SLICES;

    uint idx = (pop - usable_min) / slice_size;
    return min(idx, NUM_SLICES - 1);
}

uint read_payload_gpu(device const Qubit* qubits, float vx, float vy, float t, uint offset) {
    uint need = offset + TOTAL_BITS;

    // Insertion-sort closest `need` qubits.
    float dists[64];
    uint  indices[64];
    for (uint i = 0; i < need && i < 64; i++) {
        dists[i]   = 1e30f;
        indices[i] = 0;
    }

    for (uint i = 0; i < NUM_QUBITS; i++) {
        float dx = qubits[i].x - vx;
        float dy = qubits[i].y - vy;
        float d  = dx * dx + dy * dy;

        if (d < dists[need - 1]) {
            int j = need - 1;
            while (j > 0 && d < dists[j - 1]) {
                dists[j]   = dists[j - 1];
                indices[j] = indices[j - 1];
                j--;
            }
            dists[j]   = d;
            indices[j] = i;
        }
    }

    uint payload = 0;
    for (uint i = 0; i < TOTAL_BITS; i++) {
        uint qi    = indices[offset + i];
        float dx   = qubits[qi].x - vx;
        float dy   = qubits[qi].y - vy;
        float angle = qubits[qi].phase + qubits[qi].speed * qubits[qi].radius * t;
        float cross = metal::fast::sin(angle) * dx - metal::fast::cos(angle) * dy;
        payload = (payload << 1) | ((cross < 0.0f) ? 1u : 0u);
    }
    return payload;
}

// MARK: - Kernel 1: Search by Slice

kernel void quantum_search_by_slice(
    device const Qubit*       qubits         [[buffer(0)]],
    constant uint&            target_slice   [[buffer(1)]],
    constant int&             req_addr_slice [[buffer(2)]],
    constant uint&            seed_idx       [[buffer(3)]],
    device atomic_uint*       count          [[buffer(4)]],
    device uint4*             results        [[buffer(5)]],
    constant uint&            max_results    [[buffer(6)]],
    uint3 gid [[thread_position_in_grid]]
) {
    uint vx = gid.x;
    uint vy = gid.y;
    uint t_off = gid.z;
    uint t      = t_off / GRID_OFFSET;
    uint offset = t_off % GRID_OFFSET;

    if (vx >= GRID_VX || vy >= GRID_VY || t >= GRID_T || offset >= GRID_OFFSET) return;

    uint addr = (vx << 20) | (vy << 15) | (t << 10) | (offset << 5) | seed_idx;
    if (req_addr_slice >= 0) {
        if (popcount_to_slice(popcount25(addr)) != uint(req_addr_slice)) return;
    }

    uint payload = read_payload_gpu(qubits, float(vx), float(vy), float(t) * T_SCALE, offset);
    uint pslice  = popcount_to_slice(popcount25(payload));

    if (pslice == target_slice) {
        uint idx = atomic_fetch_add_explicit(count, 1, memory_order_relaxed);
        if (idx < max_results) {
            results[idx] = uint4(vx, vy, t, offset);
        }
    }
}

// MARK: - Kernel 2: Exact Payload Match

kernel void quantum_search_exact(
    device const Qubit*       qubits         [[buffer(0)]],
    constant uint&            target         [[buffer(1)]],
    constant int&             req_addr_slice [[buffer(2)]],
    constant uint&            seed_idx       [[buffer(3)]],
    device atomic_uint*       count          [[buffer(4)]],
    device uint4*             results        [[buffer(5)]],
    constant uint&            max_results    [[buffer(6)]],
    uint3 gid [[thread_position_in_grid]]
) {
    uint vx = gid.x;
    uint vy = gid.y;
    uint t_off = gid.z;
    uint t      = t_off / GRID_OFFSET;
    uint offset = t_off % GRID_OFFSET;

    if (vx >= GRID_VX || vy >= GRID_VY || t >= GRID_T || offset >= GRID_OFFSET) return;

    uint addr = (vx << 20) | (vy << 15) | (t << 10) | (offset << 5) | seed_idx;
    if (req_addr_slice >= 0) {
        if (popcount_to_slice(popcount25(addr)) != uint(req_addr_slice)) return;
    }

    uint payload = read_payload_gpu(qubits, float(vx), float(vy), float(t) * T_SCALE, offset);
    if (payload == target) {
        uint idx = atomic_fetch_add_explicit(count, 1, memory_order_relaxed);
        if (idx < max_results) {
            results[idx] = uint4(vx, vy, t, offset);
        }
    }
}

// MARK: - Kernel 3: Search + Trace (combined single-pass)

kernel void quantum_search_and_trace(
    device const Qubit*       qubits_all     [[buffer(0)]],
    constant uint*            target_values  [[buffer(1)]],
    constant uint&            target_len     [[buffer(2)]],
    constant uint&            seed_idx       [[buffer(3)]],
    device atomic_uint*       match_count    [[buffer(4)]],
    device uint*              matches        [[buffer(5)]],
    constant uint&            max_matches    [[buffer(6)]],
    uint3 gid [[thread_position_in_grid]]
) {
    uint vx = gid.x;
    uint vy = gid.y;
    uint t_off = gid.z;
    uint t      = t_off / GRID_OFFSET;
    uint offset = t_off % GRID_OFFSET;

    if (vx >= GRID_VX || vy >= GRID_VY || t >= GRID_T || offset >= GRID_OFFSET) return;

    device const Qubit* qubits = qubits_all + seed_idx * NUM_QUBITS;

    uint payload = read_payload_gpu(qubits, float(vx), float(vy), float(t) * T_SCALE, offset);
    uint ppop = popcount25(payload);
    if (ppop <= END_MARKER_LOW || ppop >= END_MARKER_HIGH) return;

    uint addr = payload;
    for (uint i = 0; i < target_len; i++) {
        uint apop  = popcount25(addr);
        uint aslice = popcount_to_slice(apop);
        if (aslice >= NUM_SLICES) return;
        if (aslice != target_values[i]) return;

        if (i == target_len - 1) {
            uint idx = atomic_fetch_add_explicit(match_count, 1, memory_order_relaxed);
            if (idx < max_matches) {
                matches[idx * 5 + 0] = vx;
                matches[idx * 5 + 1] = vy;
                matches[idx * 5 + 2] = t;
                matches[idx * 5 + 3] = offset;
                matches[idx * 5 + 4] = seed_idx;
            }
            return;
        }

        uint nvx  = (addr >> 20) & 0x1F;
        uint nvy  = (addr >> 15) & 0x1F;
        uint nt   = (addr >> 10) & 0x1F;
        uint noff = (addr >>  5) & 0x1F;
        uint nsid = addr & 0x1F;

        device const Qubit* nq = qubits_all + nsid * NUM_QUBITS;
        payload = read_payload_gpu(nq, float(nvx), float(nvy), float(nt) * T_SCALE, noff);
        ppop = popcount25(payload);
        if (ppop <= END_MARKER_LOW || ppop >= END_MARKER_HIGH) return;

        addr = payload;
    }
}
