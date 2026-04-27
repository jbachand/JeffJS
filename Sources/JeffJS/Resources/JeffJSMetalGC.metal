// JeffJSMetalGC.metal
// JeffJS — Metal GPU-accelerated garbage collection
//
// Compute shaders for the 3 phases of Bacon-Rajan synchronous cycle detection:
//   1. Trial decrement — decrement refcounts of children
//   2. Scan/rescue — mark live objects black, restore child refcounts
//   3. Collect dead — gather indices of white (unreachable) objects

#include <metal_stdlib>
using namespace metal;

// MARK: - Shared structs

/// GPU-side representation of a GC object node.
/// Laid out for 16-byte alignment: 4 + 4 + 4 + 1 + 3 padding = 16 bytes.
struct GCNode {
    int32_t refCount;      // working refcount (modified by kernels)
    uint32_t childCount;   // number of children
    uint32_t childOffset;  // offset into children[] adjacency list
    uint8_t mark;          // 0=white, 1=black
    uint8_t padding[3];
};

// MARK: - Kernel 1: Trial decrement (Phase 1)

/// For each node, decrement the refcount of all its children.
/// After this pass, objects whose effective refcount is zero are candidates
/// for collection (but may still be rescued in Phase 2).
kernel void gc_trial_decref(
    device GCNode* nodes [[buffer(0)]],
    device const uint32_t* children [[buffer(1)]],
    constant uint32_t& nodeCount [[buffer(2)]],
    uint id [[thread_position_in_grid]])
{
    if (id >= nodeCount) return;
    GCNode node = nodes[id];
    for (uint32_t i = 0; i < node.childCount; i++) {
        uint32_t childIdx = children[node.childOffset + i];
        if (childIdx < nodeCount) {
            atomic_fetch_sub_explicit(
                (device atomic_int*)&nodes[childIdx].refCount,
                1, memory_order_relaxed);
        }
    }
}

// MARK: - Kernel 2: Scan/rescue (Phase 2)

/// Mark nodes with refCount > 0 as black (externally reachable).
/// Restore child refcounts for rescued nodes.
/// Must be run iteratively until rescueCount is zero (convergence).
kernel void gc_scan_rescue(
    device GCNode* nodes [[buffer(0)]],
    device const uint32_t* children [[buffer(1)]],
    constant uint32_t& nodeCount [[buffer(2)]],
    device atomic_uint* rescueCount [[buffer(3)]],
    uint id [[thread_position_in_grid]])
{
    if (id >= nodeCount) return;
    if (nodes[id].refCount > 0 && nodes[id].mark == 0) {
        nodes[id].mark = 1; // black — rescued
        atomic_fetch_add_explicit(rescueCount, 1, memory_order_relaxed);
        // Restore child refcounts so children are also candidates for rescue
        for (uint32_t i = 0; i < nodes[id].childCount; i++) {
            uint32_t childIdx = children[nodes[id].childOffset + i];
            if (childIdx < nodeCount) {
                atomic_fetch_add_explicit(
                    (device atomic_int*)&nodes[childIdx].refCount,
                    1, memory_order_relaxed);
            }
        }
    }
}

// MARK: - Kernel 3: Collect dead nodes

/// Write indices of white (mark == 0) nodes to the output array.
/// These are unreachable cycle members that should be freed.
kernel void gc_collect_dead(
    device const GCNode* nodes [[buffer(0)]],
    constant uint32_t& nodeCount [[buffer(1)]],
    device uint32_t* deadIndices [[buffer(2)]],
    device atomic_uint* deadCount [[buffer(3)]],
    uint id [[thread_position_in_grid]])
{
    if (id >= nodeCount) return;
    if (nodes[id].mark == 0) {
        uint pos = atomic_fetch_add_explicit(deadCount, 1, memory_order_relaxed);
        deadIndices[pos] = id;
    }
}
