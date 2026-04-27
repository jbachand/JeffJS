// QuantumSimulator.metal
// GPU-accelerated quantum gate operations for state-vector simulation.
//
// State vector layout: float2[dim] where dim = 2^numQubits.
// Each float2 represents one complex amplitude: .x = real, .y = imaginary.
// Index i corresponds to computational basis state |i>.

#include <metal_stdlib>
using namespace metal;

// MARK: - Complex Arithmetic

/// Complex multiplication: (a.x + a.y*i) * (b.x + b.y*i)
static inline float2 cmul(float2 a, float2 b) {
    return float2(a.x * b.x - a.y * b.y,
                  a.x * b.y + a.y * b.x);
}

// MARK: - Kernel 1: Hadamard Gate (double-buffered)

kernel void quantum_hadamard(
    device const float2* vec_in  [[buffer(0)]],
    device float2*       vec_out [[buffer(1)]],
    constant uint&       qubit   [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    uint mask = 1u << qubit;
    uint i0 = tid & ~mask;       // index with qubit bit cleared
    uint i1 = tid | mask;        // index with qubit bit set

    float2 a0 = vec_in[i0];
    float2 a1 = vec_in[i1];

    float inv_sqrt2 = 0.70710678118f;

    if ((tid & mask) == 0) {
        // |0> component: (a0 + a1) / sqrt(2)
        vec_out[tid] = (a0 + a1) * inv_sqrt2;
    } else {
        // |1> component: (a0 - a1) / sqrt(2)
        vec_out[tid] = (a0 - a1) * inv_sqrt2;
    }
}

// MARK: - Kernel 2: Pauli-X Gate (in-place)

kernel void quantum_pauli_x(
    device float2* vec   [[buffer(0)]],
    constant uint& qubit [[buffer(1)]],
    uint tid [[thread_position_in_grid]]
) {
    uint mask = 1u << qubit;

    // Only threads where qubit bit = 0 perform the swap to avoid double-swap.
    if ((tid & mask) == 0) {
        uint partner = tid | mask;
        float2 tmp = vec[tid];
        vec[tid] = vec[partner];
        vec[partner] = tmp;
    }
}

// MARK: - Kernel 3: CNOT Gate (double-buffered)

kernel void quantum_cnot(
    device const float2* vec_in  [[buffer(0)]],
    device float2*       vec_out [[buffer(1)]],
    constant uint&       control [[buffer(2)]],
    constant uint&       target  [[buffer(3)]],
    uint tid [[thread_position_in_grid]]
) {
    uint ctrl_mask = 1u << control;
    uint tgt_mask  = 1u << target;

    if ((tid & ctrl_mask) == 0) {
        // Control bit is 0: copy unchanged
        vec_out[tid] = vec_in[tid];
    } else {
        // Control bit is 1: read from index with target bit flipped
        uint src = tid ^ tgt_mask;
        vec_out[tid] = vec_in[src];
    }
}

// MARK: - Kernel 4: Controlled Modular Multiplication (double-buffered)

kernel void quantum_controlled_mod_mult(
    device const float2* vec_in      [[buffer(0)]],
    device float2*       vec_out     [[buffer(1)]],
    constant uint&       control     [[buffer(2)]],
    constant uint&       work_offset [[buffer(3)]],
    constant uint&       n_work      [[buffer(4)]],
    constant uint&       a_val       [[buffer(5)]],
    constant uint&       N_val       [[buffer(6)]],
    uint tid [[thread_position_in_grid]]
) {
    uint ctrl_mask = 1u << control;

    // Extract the work register value from bits [work_offset .. work_offset+n_work-1]
    uint work_mask = ((1u << n_work) - 1u) << work_offset;
    uint work_val  = (tid & work_mask) >> work_offset;

    if ((tid & ctrl_mask) == 0 || work_val >= N_val) {
        // Control is 0 or work value is out of range: copy unchanged
        vec_out[tid] = vec_in[tid];
    } else {
        // Compute modular multiplication: target_work = (a * work_val) mod N
        uint target_work = (a_val * work_val) % N_val;

        // Build the target index: replace work register bits with target_work
        uint target_idx = (tid & ~work_mask) | (target_work << work_offset);

        // The amplitude at target_idx in the output comes from tid in the input
        vec_out[target_idx] = vec_in[tid];
    }
}

// MARK: - Kernel 5: Phase Gate (in-place)

kernel void quantum_phase_gate(
    device float2*  vec   [[buffer(0)]],
    constant uint&  qubit [[buffer(1)]],
    constant float& angle [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    uint mask = 1u << qubit;

    if ((tid & mask) != 0) {
        // Multiply by e^{i*angle} = (cos(angle), sin(angle))
        float2 phase = float2(cos(angle), sin(angle));
        vec[tid] = cmul(vec[tid], phase);
    }
}

// MARK: - Kernel 6: Measure Probability (reduction)

kernel void quantum_measure_prob(
    device const float2* vec           [[buffer(0)]],
    constant uint&       qubit         [[buffer(1)]],
    device float*        partial_sums  [[buffer(2)]],
    uint tid_in_group  [[thread_position_in_threadgroup]],
    uint group_id      [[threadgroup_position_in_grid]],
    uint threads_per_group [[threads_per_threadgroup]],
    uint tid           [[thread_position_in_grid]]
) {
    uint mask = 1u << qubit;

    // Each thread computes |amplitude|^2 for its index, but only if qubit bit = 0
    float val = 0.0f;
    if ((tid & mask) == 0) {
        float2 amp = vec[tid];
        val = amp.x * amp.x + amp.y * amp.y;
    }

    // Threadgroup shared memory for parallel reduction
    threadgroup float shared[256];
    shared[tid_in_group] = val;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Tree reduction within the threadgroup
    for (uint stride = threads_per_group / 2; stride > 0; stride >>= 1) {
        if (tid_in_group < stride) {
            shared[tid_in_group] += shared[tid_in_group + stride];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    // Thread 0 of each group writes the partial sum
    if (tid_in_group == 0) {
        partial_sums[group_id] = shared[0];
    }
}

// Kernel 7: Collapse + renormalize after measurement (in-place)
// Zeroes amplitudes incompatible with the outcome, divides survivors by norm.
// Buffer layout: [0]=vec (float2[dim]), [1]=qubit (uint), [2]=outcome (uint), [3]=inv_norm (float)
kernel void quantum_collapse_and_normalize(
    device float2*  vec      [[buffer(0)]],
    constant uint&  qubit    [[buffer(1)]],
    constant uint&  outcome  [[buffer(2)]],
    constant float& inv_norm [[buffer(3)]],
    uint tid [[thread_position_in_grid]]
) {
    uint bit = (tid >> qubit) & 1;
    if (bit != outcome) {
        vec[tid] = float2(0.0, 0.0);
    } else {
        vec[tid] = vec[tid] * inv_norm;
    }
}
