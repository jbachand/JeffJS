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
    func shouldUseMetalGC(objectCount: Int) -> Bool {
        guard objectCount > metalThreshold else { return false }
        ensureMetalInitialized()
        return metalAvailable
    }

    /// Run all 3 GC phases on the GPU, then free dead objects on CPU.
    ///
    /// - Parameter rt: The JeffJS runtime whose gcObjects list to collect.
    func runMetalGC(rt: JeffJSRuntime) {
        ensureMetalInitialized()
        guard metalAvailable,
              let device = device,
              let commandQueue = commandQueue,
              let trialDecrefPipeline = trialDecrefPipeline,
              let scanRescuePipeline = scanRescuePipeline,
              let collectDeadPipeline = collectDeadPipeline else {
            return
        }

        let objectCount = rt.gcObjects.count
        guard objectCount > 0 else { return }

        // ---- Step 1: Snapshot the object graph ----

        var nodes = [MetalGCNode]()
        nodes.reserveCapacity(objectCount)
        var children = [UInt32]()
        children.reserveCapacity(objectCount * 4) // estimate ~4 children per object

        // Map from JeffJSGCObjectHeader identity to index in the nodes array
        var headerToIndex = [ObjectIdentifier: UInt32]()
        headerToIndex.reserveCapacity(objectCount)

        for (i, hdr) in rt.gcObjects.enumerated() {
            headerToIndex[ObjectIdentifier(hdr)] = UInt32(i)
        }

        for hdr in rt.gcObjects {
            let childOffset = UInt32(children.count)

            // Enumerate children (replicates markChildren logic)
            var childIndices = [UInt32]()
            enumerateChildren(rt, hdr) { childHeader in
                if let idx = headerToIndex[ObjectIdentifier(childHeader)] {
                    childIndices.append(idx)
                }
            }

            children.append(contentsOf: childIndices)

            let node = MetalGCNode(
                refCount: Int32(clamping: hdr.refCount),
                childCount: UInt32(childIndices.count),
                childOffset: childOffset,
                mark: 0 // white
            )
            nodes.append(node)
        }

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
            return
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
              let encoder1 = cmdBuffer1.makeComputeCommandEncoder() else { return }

        encoder1.setComputePipelineState(trialDecrefPipeline)
        encoder1.setBuffer(nodeBuffer, offset: 0, index: 0)
        encoder1.setBuffer(childBuffer, offset: 0, index: 1)
        encoder1.setBytes(&nodeCountValue, length: MemoryLayout<UInt32>.size, index: 2)
        encoder1.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadGroupDim)
        encoder1.endEncoding()
        cmdBuffer1.commit()
        cmdBuffer1.waitUntilCompleted()

        // ---- Step 3b: Phase 2 — Scan/rescue (iterative until convergence) ----

        for _ in 0 ..< maxRescueIterations {
            // Reset rescue counter to 0
            let rescuePtr = rescueCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1)
            rescuePtr.pointee = 0

            guard let cmdBuffer2 = commandQueue.makeCommandBuffer(),
                  let encoder2 = cmdBuffer2.makeComputeCommandEncoder() else { return }

            encoder2.setComputePipelineState(scanRescuePipeline)
            encoder2.setBuffer(nodeBuffer, offset: 0, index: 0)
            encoder2.setBuffer(childBuffer, offset: 0, index: 1)
            encoder2.setBytes(&nodeCountValue, length: MemoryLayout<UInt32>.size, index: 2)
            encoder2.setBuffer(rescueCountBuffer, offset: 0, index: 3)
            encoder2.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadGroupDim)
            encoder2.endEncoding()
            cmdBuffer2.commit()
            cmdBuffer2.waitUntilCompleted()

            // Check if any nodes were rescued this iteration
            let rescuedCount = rescuePtr.pointee
            if rescuedCount == 0 {
                break // Converged
            }
        }

        // ---- Step 3c: Phase 3 — Collect dead node indices ----

        let deadCountPtr = deadCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1)
        deadCountPtr.pointee = 0

        guard let cmdBuffer3 = commandQueue.makeCommandBuffer(),
              let encoder3 = cmdBuffer3.makeComputeCommandEncoder() else { return }

        encoder3.setComputePipelineState(collectDeadPipeline)
        encoder3.setBuffer(nodeBuffer, offset: 0, index: 0)
        encoder3.setBytes(&nodeCountValue, length: MemoryLayout<UInt32>.size, index: 1)
        encoder3.setBuffer(deadIndicesBuffer, offset: 0, index: 2)
        encoder3.setBuffer(deadCountBuffer, offset: 0, index: 3)
        encoder3.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadGroupDim)
        encoder3.endEncoding()
        cmdBuffer3.commit()
        cmdBuffer3.waitUntilCompleted()

        // ---- Step 4: Read back dead indices and free on CPU ----

        let deadCount = Int(deadCountPtr.pointee)
        guard deadCount > 0 else { return }

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
        var remaining = [JeffJSGCObjectHeader]()
        remaining.reserveCapacity(objectCount - deadCount)

        for (i, hdr) in rt.gcObjects.enumerated() {
            if deadIndexSet.contains(i) {
                deadHeaders.append(hdr)
            } else {
                remaining.append(hdr)
            }
        }
        rt.gcObjects = remaining

        // Free each dead object (set refcount to 1 so freeGCObject doesn't re-enqueue)
        for hdr in deadHeaders {
            hdr.refCount = 1
            freeGCObject(rt, hdr)
        }
    }

    // MARK: - Metal initialization

    /// Lazily create the Metal device, command queue, and pipeline states.
    private func ensureMetalInitialized() {
        guard !metalInitialized else { return }
        metalInitialized = true

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

        // Load the shader library from the app bundle
        guard let library = dev.makeDefaultLibrary() else {
            metalAvailable = false
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
        } catch {
            metalAvailable = false
        }
    }

    // MARK: - Object graph child enumeration

    /// Enumerate all GC-managed children of a header, calling the visitor for each.
    /// Replicates the logic from markChildren in JeffJSGC.swift but collects
    /// child headers directly instead of calling a mark function.
    private func enumerateChildren(
        _ rt: JeffJSRuntime,
        _ header: JeffJSGCObjectHeader,
        _ visitor: (JeffJSGCObjectHeader) -> Void
    ) {
        switch header.gcObjType {
        case .jsObject:
            let obj = unsafeBitCast(header, to: JeffJSObject.self)
            enumerateObjectChildren(obj, visitor)
        case .shape:
            let shape = unsafeBitCast(header, to: JeffJSShape.self)
            if let proto = shape.proto {
                visitor(proto)
            }
        case .functionBytecode:
            let obj = unsafeBitCast(header, to: JeffJSObject.self)
            if case .bytecodeFunc(let fb, let varRefs, _) = obj.payload, let fb = fb {
                for cpVal in fb.cpool {
                    if let child = cpVal.toGCObjectHeader() {
                        visitor(child)
                    }
                }
                for vr in varRefs {
                    if let vr = vr {
                        visitor(vr)
                    }
                }
            }
        case .varRef:
            let vr = unsafeBitCast(header, to: JeffJSVarRef.self)
            if let child = vr.pvalue.toGCObjectHeader() {
                visitor(child)
            }
        case .bigInt, .bigFloat, .bigDecimal:
            break // leaf types
        case .asyncFunction:
            break
        case .mapIteratorData, .arrayIteratorData, .regexpStringIteratorData:
            break
        }
    }

    /// Enumerate children of a JeffJSObject (shape, prototype, property values).
    private func enumerateObjectChildren(
        _ obj: JeffJSObject,
        _ visitor: (JeffJSGCObjectHeader) -> Void
    ) {
        // 1. Shape
        if let shape = obj.shape {
            visitor(shape)
        }

        // 2. Prototype
        if let proto = obj.proto {
            visitor(proto)
        }

        // 3. Property values
        for propEntry in obj.prop {
            switch propEntry {
            case .value(let val):
                if let child = val.toGCObjectHeader() {
                    visitor(child)
                }
            case .getset(let getter, let setter):
                if let g = getter { visitor(g) }
                if let s = setter { visitor(s) }
            case .varRef(let vr):
                visitor(vr)
            case .autoInit:
                break
            }
        }
    }
}

#endif // canImport(Metal)
