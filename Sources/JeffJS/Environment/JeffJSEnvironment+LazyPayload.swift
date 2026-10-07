// JeffJSEnvironment+LazyPayload.swift
// Host/CLI access to the lazy JSON payload counters and eviction
// (JeffJSLazyPayload.swift).

import Foundation

extension JeffJSEnvironment {
    /// One line: payloads, stubs, materializations, evictions, live buffers.
    public var lazyPayloadSummary: String {
        let s = runtime.lazyPayload
        let live = s.buffers.reduce(0) { $0 + ($1 == nil ? 0 : 1) }
        return "payloads=\(s.payloads) literals=\(s.literalPayloads) bytes=\(s.payloadBytes) fallbacks=\(s.fallbacks)"
            + " stubs=\(s.stubsCreated) objects=\(s.objectsMaterialized) arrays=\(s.arraysMaterialized)"
            + " evicted=\(s.evicted) records=\(s.records.count) liveBuffers=\(live) bufferBytes=\(s.liveBufferBytes)"
    }

    /// The counters as a JSON object text (tests).
    public var lazyPayloadStatsJSON: String {
        let s = runtime.lazyPayload
        let live = s.buffers.reduce(0) { $0 + ($1 == nil ? 0 : 1) }
        return "{\"payloads\":\(s.payloads),\"literals\":\(s.literalPayloads),\"bytes\":\(s.payloadBytes),"
            + "\"fallbacks\":\(s.fallbacks),\"stubs\":\(s.stubsCreated),\"objects\":\(s.objectsMaterialized),"
            + "\"arrays\":\(s.arraysMaterialized),\"evicted\":\(s.evicted),\"records\":\(s.records.count),"
            + "\"liveBuffers\":\(live),\"bufferBytes\":\(s.liveBufferBytes)}"
    }

    /// Revert pristine materialized payload objects to stubs (no JS on the
    /// stack). Returns how many were reverted.
    @discardableResult
    public func evictLazyPayloads() -> Int { runtime.evictLazyPayloads() }
}
