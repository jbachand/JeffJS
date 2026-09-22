// JeffJSMetalGC.swift
// JeffJS — Metal GPU-accelerated garbage collection orchestrator
//
// Offloads the 3 phases of Bacon-Rajan cycle detection to Metal compute
// shaders when the object graph is large enough (> 5000 objects) for GPU
// parallelism to outperform the CPU linear walk.
//
// Architecture:
//   1. Snapshot the object graph into flat arrays (nodes + adjacency list)
//   2. Upload to shared Metal buffers (zero-copy on Apple Silicon)
//   3. Dispatch 3 kernels: trial_decref → scan_rescue (iterative) → collect_dead
//   4. Read back dead indices and free the corresponding objects on CPU

#if canImport(Metal)
import Metal
import Foundation

/// `JEFFJS_GC_METAL=1`: load the collector's kernels from the package resource
/// bundle when the process has no Metal default library of its own, so the CLI
/// and the test suite run the same GPU collector the host app does.
nonisolated(unsafe) let jeffJSForceMetalGC =
    ProcessInfo.processInfo.environment["JEFFJS_GC_METAL"] == "1"

// MARK: - GPU-side struct (must match JeffJSMetalGC.metal exactly)

/// Mirror of the Metal shader's GCNode struct.
/// 16 bytes, matching the GPU layout: int32 + uint32 + uint32 + uint8 + 3 padding.
struct MetalGCNode {
    var refCount: Int32
    var childCount: UInt32
    var childOffset: UInt32
    var mark: UInt8
    var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

// MARK: - JeffJSMetalGC

/// Singleton orchestrator for Metal-accelerated garbage collection.
/// Lazily initializes Metal resources on first use.
final class JeffJSMetalGC {

    static let shared = JeffJSMetalGC()

    /// Minimum object count before Metal GC is worthwhile.
    /// Below this threshold the CPU path is faster due to GPU dispatch overhead.
    private let metalThreshold = JeffJSConfig.gcMetalThreshold

    /// Thread group width for compute dispatches.
    private let threadGroupSize = JeffJSConfig.gcMetalThreadGroupSize

    /// Maximum iterations for the rescue kernel convergence loop.
    /// Safety valve to prevent infinite loops if the graph is pathological.
    private let maxRescueIterations = JeffJSConfig.gcMetalMaxRescue

    // MARK: - Metal resources (lazy)

    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var trialDecrefPipeline: MTLComputePipelineState?
    private var scanRescuePipeline: MTLComputePipelineState?
    private var collectDeadPipeline: MTLComputePipelineState?
    private var metalInitialized = false
    private var metalAvailable = false

    private init() {}

    // MARK: - Public API

    /// Returns true when the object count is large enough for Metal to
    /// outperform the CPU linear walk.
    /// `JEFFJS_GC_METAL=1` means "run the GPU collector", not "run it on big
    /// heaps": the whole point of the flag is to put the test suite and the CLI
    /// on the same code path the app uses above `gc.metalThreshold`, and a
    /// conformance group's heap is nowhere near 5 000 objects. An explicit
    /// `JEFFJS_GC_METALTHRESHOLD` still wins, so a benchmark can ask for the
    /// app's real crossover.
    var effectiveThreshold: Int {
        if let override = JeffJSMetalGC.thresholdOverride { return override }
        if jeffJSForceMetalGC, !JeffJSConfig.gcMetalThresholdIsExplicit { return 0 }
        return metalThreshold
    }

    /// Test hook: force the collector choice for one runtime's worth of work
    /// without a second process (see GCParityTests). `nil` = honour the
    /// environment.
    nonisolated(unsafe) static var thresholdOverride: Int? = nil

    /// Collections the GPU ran to completion, and collections it declined and
    /// handed back to the CPU. A parity test that only compared results would
    /// pass just as happily if the kernels never ran at all — which is exactly
    /// the state this suite was in until yesterday.
    private(set) var completedRuns = 0
    private(set) var declinedRuns = 0

    /// True when the kernels actually loaded. Tests skip rather than silently
    /// exercising the CPU collector twice — which is how the var-ref seeding
    /// bug survived a green suite.
    var isAvailable: Bool {
        ensureMetalInitialized()
        return metalAvailable
    }

    func shouldUseMetalGC(objectCount: Int) -> Bool {
        guard objectCount > effectiveThreshold else { return false }
        ensureMetalInitialized()
        return metalAvailable
    }

    /// Run all 3 GC phases on the GPU, then free dead objects on CPU.
    ///
    /// Returns `true` only when the collection ran to completion. Every other
    /// exit — Metal missing, a buffer that would not allocate, a command buffer
    /// that errored, a rescue wavefront that did not converge — returns `false`
    /// having freed nothing, and `runGC` re-runs the CPU collector on the same
    /// heap. A partial GPU scan must never reach phase 3: everything the
    /// wavefront had not touched is still white and would be freed while live.
    ///
    /// - Parameter rt: The JeffJS runtime whose gcObjects list to collect.
    @discardableResult
    func runMetalGC(rt: JeffJSRuntime) -> Bool {
        // The CPU collector's own switch. `runGC` checks it before dispatching
        // here, but `runMetalGC` is also reachable from tests and from the
        // environment's explicit runGC(), and "no cycle collection" has to mean
        // the same thing on both paths.
        guard !jeffJS_gcDisable else { declinedRuns += 1; return false }
        ensureMetalInitialized()
        guard metalAvailable,
              let device = device,
              let commandQueue = commandQueue,
              let trialDecrefPipeline = trialDecrefPipeline,
              let scanRescuePipeline = scanRescuePipeline,
              let collectDeadPipeline = collectDeadPipeline else {
            declinedRuns += 1
            return false
        }

        let objectCount = rt.gcObjects.count
        guard objectCount > 0 else { completedRuns += 1; return true }

        // ---- Step 1: Snapshot the object graph ----

        let snapshot = buildGraphSnapshot(rt: rt)
        var nodes = snapshot.nodes
        var children = snapshot.children

        // ---- Step 2: Allocate Metal shared buffers ----

        let nodeBufferSize = MemoryLayout<MetalGCNode>.stride * max(objectCount, 1)
        let childBufferSize = MemoryLayout<UInt32>.stride * max(children.count, 1)
        let deadIndicesBufferSize = MemoryLayout<UInt32>.stride * max(objectCount, 1)
        let counterBufferSize = MemoryLayout<UInt32>.stride

        guard let nodeBuffer = device.makeBuffer(
                bytes: &nodes,
                length: nodeBufferSize,
                options: .storageModeShared),
              let childBuffer = children.isEmpty
                ? device.makeBuffer(length: childBufferSize, options: .storageModeShared)
                : device.makeBuffer(bytes: &children, length: childBufferSize, options: .storageModeShared),
              let deadIndicesBuffer = device.makeBuffer(
                length: deadIndicesBufferSize,
                options: .storageModeShared),
              let rescueCountBuffer = device.makeBuffer(
                length: counterBufferSize,
                options: .storageModeShared),
              let deadCountBuffer = device.makeBuffer(
                length: counterBufferSize,
                options: .storageModeShared) else {
            if jeffJS_gcDebug { print("[GC-metal] buffer allocation failed; abandoning") }
            declinedRuns += 1
            return false
        }
        if jeffJS_gcDebug {
            print("[GC-metal] \(objectCount) node(s), \(children.count) edge(s)")
        }

        var nodeCountValue = UInt32(objectCount)

        // Use dispatchThreadgroups (not dispatchThreads) for compatibility with
        // all Metal devices including the iOS Simulator, which does not support
        // non-uniform threadgroups. The shaders guard with `if (id >= nodeCount) return`.
        let tgWidth = min(threadGroupSize, objectCount)
        let threadGroupDim = MTLSize(width: tgWidth, height: 1, depth: 1)
        let threadgroupCount = MTLSize(
            width: (objectCount + tgWidth - 1) / tgWidth,
            height: 1, depth: 1)

        // ---- Step 3a: Phase 1 — Trial decrement ----

        guard let cmdBuffer1 = commandQueue.makeCommandBuffer(),
              let encoder1 = cmdBuffer1.makeComputeCommandEncoder() else { declinedRuns += 1; return false }

        encoder1.setComputePipelineState(trialDecrefPipeline)
        encoder1.setBuffer(nodeBuffer, offset: 0, index: 0)
        encoder1.setBuffer(childBuffer, offset: 0, index: 1)
        encoder1.setBytes(&nodeCountValue, length: MemoryLayout<UInt32>.size, index: 2)
        encoder1.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadGroupDim)
        encoder1.endEncoding()
        cmdBuffer1.commit()
        cmdBuffer1.waitUntilCompleted()
        guard completed(cmdBuffer1, "trial_decref") else { declinedRuns += 1; return false }

        // ---- Step 3b: Phase 2 — Scan/rescue (iterative until convergence) ----

        var converged = false
        var iterations = 0
        for _ in 0 ..< maxRescueIterations {
            // Reset rescue counter to 0
            let rescuePtr = rescueCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1)
            rescuePtr.pointee = 0

            guard let cmdBuffer2 = commandQueue.makeCommandBuffer(),
                  let encoder2 = cmdBuffer2.makeComputeCommandEncoder() else { declinedRuns += 1; return false }

            encoder2.setComputePipelineState(scanRescuePipeline)
            encoder2.setBuffer(nodeBuffer, offset: 0, index: 0)
            encoder2.setBuffer(childBuffer, offset: 0, index: 1)
            encoder2.setBytes(&nodeCountValue, length: MemoryLayout<UInt32>.size, index: 2)
            encoder2.setBuffer(rescueCountBuffer, offset: 0, index: 3)
            encoder2.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadGroupDim)
            encoder2.endEncoding()
            cmdBuffer2.commit()
            cmdBuffer2.waitUntilCompleted()
            guard completed(cmdBuffer2, "scan_rescue") else { declinedRuns += 1; return false }
            iterations += 1

            // Check if any nodes were rescued this iteration
            let rescuedCount = rescuePtr.pointee
            if rescuedCount == 0 {
                converged = true
                break // Converged
            }
        }
        // Each iteration propagates the rescue one level, so a graph deeper
        // than the cap is only half-scanned: everything the wavefront had not
        // reached yet is still white and phase 3 would free it while it is
        // live. Abandon the collection instead — the next run gets another go.
        guard converged else {
            if jeffJS_gcDebug {
                print("[GC-metal] rescue did not converge in \(maxRescueIterations) iterations; abandoning")
            }
            declinedRuns += 1
            return false
        }
        if jeffJS_gcDebug { print("[GC-metal] rescue converged in \(iterations) iteration(s)") }

        // ---- Step 3c: Phase 3 — Collect dead node indices ----

        let deadCountPtr = deadCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1)
        deadCountPtr.pointee = 0

        guard let cmdBuffer3 = commandQueue.makeCommandBuffer(),
              let encoder3 = cmdBuffer3.makeComputeCommandEncoder() else { declinedRuns += 1; return false }

        encoder3.setComputePipelineState(collectDeadPipeline)
        encoder3.setBuffer(nodeBuffer, offset: 0, index: 0)
        encoder3.setBytes(&nodeCountValue, length: MemoryLayout<UInt32>.size, index: 1)
        encoder3.setBuffer(deadIndicesBuffer, offset: 0, index: 2)
        encoder3.setBuffer(deadCountBuffer, offset: 0, index: 3)
        encoder3.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadGroupDim)
        encoder3.endEncoding()
        cmdBuffer3.commit()
        cmdBuffer3.waitUntilCompleted()
        guard completed(cmdBuffer3, "collect_dead") else { declinedRuns += 1; return false }

        // ---- Step 4: Read back dead indices and free on CPU ----

        let deadCount = Int(deadCountPtr.pointee)
        guard deadCount > 0 else { completedRuns += 1; return true }

        let deadIndicesPtr = deadIndicesBuffer.contents().bindMemory(
            to: UInt32.self, capacity: deadCount)

        // Collect dead headers (snapshot to avoid mutation during iteration)
        var deadHeaders = [JeffJSGCObjectHeader]()
        deadHeaders.reserveCapacity(deadCount)

        // Build a set of dead indices for fast membership check
        var deadIndexSet = Set<Int>()
        deadIndexSet.reserveCapacity(deadCount)
        for i in 0 ..< deadCount {
            let idx = Int(deadIndicesPtr[i])
            if idx < objectCount {
                deadIndexSet.insert(idx)
            }
        }

        // Remove dead objects from gcObjects and collect them for freeing.
        // Walk in reverse to preserve indices during removal.
        var remaining = ContiguousArray<Unmanaged<JeffJSGCObjectHeader>>()
        remaining.reserveCapacity(objectCount - deadCount)

        for (i, u) in rt.gcObjects.enumerated() {
            let hdr = u.takeUnretainedValue()
            if deadIndexSet.contains(i),
               hdr.gcObjType == .jsObject || hdr.gcObjType == .functionBytecode
                || hdr.gcObjType == .varRef || jeffJS_shapeIsSweepable(rt, hdr) {
                // Unlinked by hand, so the malloc accounting the GC threshold
                // reads must be done here too (see gcUnlistDead).
                hdr.gcListIndex = -1
                rt.mallocState.mallocSize -= JeffJSConfig.gcObjectCost
                rt.mallocState.mallocCount -= 1
                if hdr.gcObjType == .shape { rt.shapesEvicted += 1 }
                deadHeaders.append(hdr)
            } else {
                hdr.gcListIndex = remaining.count
                remaining.append(u)
            }
        }
        rt.gcObjects = remaining

        // Free each dead object (set refcount to 1 so freeGCObject doesn't
        // re-enqueue). REMOVE_CYCLES defers every nested zero transition onto
        // gcZeroRefCountObjects instead of freeing it here: a dead child freed
        // by its dead parent would otherwise be freed a second time by this
        // loop, releasing its ARC retain twice.
        let savedPhase = rt.gcPhase
        rt.gcPhase = .JS_GC_PHASE_REMOVE_CYCLES
        rt.gcCyclesFreed += deadHeaders.count
        gcDebugDumpDead(rt, deadHeaders, collector: "metal")
        gcFreeDeadObjects(rt, deadHeaders)
        rt.gcPhase = savedPhase
        completedRuns += 1
        return true
    }

    /// A command buffer that errored has left its output buffers in whatever
    /// state the partial dispatch reached; reading a dead set out of them would
    /// free live objects. Treat anything but `.completed` as "abandon".
    private func completed(_ buffer: MTLCommandBuffer, _ label: String) -> Bool {
        if buffer.status == .completed, buffer.error == nil { return true }
        if jeffJS_gcDebug {
            print("[GC-metal] kernel \(label) failed (status \(buffer.status.rawValue), "
                  + "\(buffer.error.map { String(describing: $0) } ?? "no error")); abandoning")
        }
        return false
    }

    // MARK: - Metal initialization

    /// Lazily create the Metal device, command queue, and pipeline states.
    /// True when this process is allowed to compile the kernels out of the
    /// package resource bundle. A host app links them into its own default
    /// library and needs nothing here; a SwiftPM consumer has no default
    /// library at all, which is why the GPU collector never ran outside the app.
    private var mayLoadPackageLibrary: Bool {
        jeffJSForceMetalGC || JeffJSMetalGC.thresholdOverride != nil
    }

    /// The value of `mayLoadPackageLibrary` at the last failed attempt. A
    /// failure is only sticky while the answer to "may I load it?" has not
    /// changed: a test that pins the GPU collector after an unpinned call has
    /// to get a real second attempt, not the cached "no".
    private var failedUnder: Bool?

    private func ensureMetalInitialized() {
        if metalAvailable { return }
        let allow = mayLoadPackageLibrary
        if metalInitialized, failedUnder == allow { return }
        metalInitialized = true
        failedUnder = allow

        guard let dev = MTLCreateSystemDefaultDevice() else {
            metalAvailable = false
            return
        }
        self.device = dev

        guard let queue = dev.makeCommandQueue() else {
            metalAvailable = false
            return
        }
        self.commandQueue = queue

        // Load the shader library from the app bundle. A host app links the
        // shaders into its own default library; a SwiftPM consumer (the CLI,
        // the test suite) has no default library at all, which is why the GPU
        // collector never ran outside the app and its divergences from the CPU
        // collector went unseen. JEFFJS_GC_METAL=1 loads the same kernels out
        // of the package's resource bundle so both can be exercised here.
        var loaded: MTLLibrary? = dev.makeDefaultLibrary()
        if loaded == nil, allow {
            if let compiled = try? dev.makeDefaultLibrary(bundle: jeffJSResourceBundle) {
                loaded = compiled
            } else if let url = jeffJSResourceBundle.url(forResource: "JeffJSMetalGC",
                                                         withExtension: "metal"),
                      let source = try? String(contentsOf: url, encoding: .utf8) {
                loaded = try? dev.makeLibrary(source: source, options: nil)
            }
        }
        guard let library = loaded else {
            metalAvailable = false
            if jeffJS_gcDebug { print("[GC-metal] no shader library; CPU collector only") }
            return
        }

        // Create pipeline states for each kernel
        guard let trialDecrefFn = library.makeFunction(name: "gc_trial_decref"),
              let scanRescueFn = library.makeFunction(name: "gc_scan_rescue"),
              let collectDeadFn = library.makeFunction(name: "gc_collect_dead") else {
            metalAvailable = false
            return
        }

        do {
            trialDecrefPipeline = try dev.makeComputePipelineState(function: trialDecrefFn)
            scanRescuePipeline = try dev.makeComputePipelineState(function: scanRescueFn)
            collectDeadPipeline = try dev.makeComputePipelineState(function: collectDeadFn)
            metalAvailable = true
            if jeffJS_gcDebug { print("[GC-metal] kernels ready on \(dev.name)") }
        } catch {
            metalAvailable = false
            if jeffJS_gcDebug { print("[GC-metal] pipeline creation failed: \(error)") }
        }
    }

    // MARK: - Object graph child enumeration

    /// Flatten the runtime's GC list into the node array and adjacency list the
    /// kernels run on. Split out of `runMetalGC` so the seeding rules can be
    /// checked without a GPU (MetalGCVarRefTests).
    ///
    /// Every node starts at its header's refcount — *except* detached var-refs.
    /// Nothing maintains a var-ref's refcount: closures hold them through ARC,
    /// and `JeffJSVarRef.init` leaves it at 1 forever no matter how many
    /// closures capture the slot. The CPU collector handles that by seeding
    /// them to zero (`gcSeedVarRefs`) and then skipping them in the trial
    /// decrement (`gcDecrefChild`), so phases 2 and 2b recompute the in-degree.
    /// `gc_trial_decref` has no such exemption — it decrements every edge it is
    /// given — so the equivalent seed here is the in-degree itself: phase 1
    /// takes it back to zero and the rescue pass puts back one count per
    /// surviving holder, exactly as on the CPU.
    ///
    /// Seeding them with the header's 1 instead is what made `threes.day`
    /// render blank: Prism's module object is captured by ~30 closures, so its
    /// var-ref went to 1 - 30 in phase 1, could not be rescued, and was freed
    /// with every one of those closures still live. `freeGCObjectChildren`
    /// clears a dead var-ref's `value`, so `Prism.util.clone` then read its
    /// captured `n` as `undefined` and threw on `n.util`. Only the host app
    /// ever saw it: a SwiftPM consumer has no Metal default library, so the
    /// CLI and the test suite always took the (correct) CPU path.
    func buildGraphSnapshot(rt: JeffJSRuntime) -> (nodes: [MetalGCNode], children: [UInt32]) {
        let objectCount = rt.gcObjects.count
        var nodes = [MetalGCNode]()
        nodes.reserveCapacity(objectCount)
        var children = [UInt32]()
        children.reserveCapacity(objectCount * 4) // estimate ~4 children per object

        // Map from JeffJSGCObjectHeader identity to index in the nodes array
        var headerToIndex = [ObjectIdentifier: UInt32]()
        headerToIndex.reserveCapacity(objectCount)
        for (i, u) in rt.gcObjects.enumerated() {
            headerToIndex[ObjectIdentifier(u.takeUnretainedValue())] = UInt32(i)
        }

        var inDegree = [Int32](repeating: 0, count: objectCount)
        var varRefNodes: [Int] = []
        for (i, u) in rt.gcObjects.enumerated() {
            let hdr = u.takeUnretainedValue()
            let childOffset = UInt32(children.count)
            var childCount: UInt32 = 0
            // Children come from the CPU collector's markChildren, so the GPU
            // graph can never drift from the reference traversal.
            enumerateChildren(rt, hdr) { childHeader in
                guard let idx = headerToIndex[ObjectIdentifier(childHeader)] else { return }
                children.append(idx)
                childCount += 1
                inDegree[Int(idx)] += 1
            }
            nodes.append(MetalGCNode(
                refCount: Int32(clamping: hdr.refCount),
                childCount: childCount,
                childOffset: childOffset,
                mark: 0 // white
            ))
            if hdr.gcObjType == .varRef { varRefNodes.append(i) }
        }
        for i in varRefNodes { nodes[i].refCount = inDegree[i] }
        return (nodes, children)
    }

    /// Enumerate all GC-managed children of a header, calling the visitor for each.
    /// Delegates to the CPU collector's `markChildren` so the GPU graph can never
    /// drift from the reference traversal (payload edges, bound functions,
    /// arrow captured `this`, ...).
    private func enumerateChildren(
        _ rt: JeffJSRuntime,
        _ header: JeffJSGCObjectHeader,
        _ visitor: (JeffJSGCObjectHeader) -> Void
    ) {
        markChildren(rt, header) { _, child in visitor(child) }
    }
}

#endif // canImport(Metal)
