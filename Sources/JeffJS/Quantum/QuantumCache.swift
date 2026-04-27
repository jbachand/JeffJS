// QuantumCache.swift
// Quantum-backed cache for JeffJS values.
//
// Stores small payloads (strings, bytecode hashes, tokens) as quantum master
// keys. The actual data lives in the deterministic qubit field -- only the
// compact key is persisted. This gives constant-size storage per entry
// regardless of original data length (chunked into 25-bit keys).
//
// Thread safety: all public methods are @MainActor to match JeffJS conventions.

import Foundation

/// A cache entry: the quantum key(s) plus metadata needed to decode.
struct QuantumCacheEntry: Codable {
    let keys: [UInt32]
    let messageLength: Int
    let seedOffset: Int
    let timestamp: Date
}

/// Quantum-backed key-value cache.
///
/// Usage:
/// ```swift
/// let cache = QuantumCache()
/// let entry = cache.store("Hello, world!")
/// let decoded = cache.retrieve(entry)  // "Hello, world!"
/// ```
@MainActor
final class QuantumCache {

    private let encoder = QuantumEncoder()
    private let decoder = QuantumDecoder()

    /// In-memory index mapping user-defined keys to quantum entries.
    private var index: [String: QuantumCacheEntry] = [:]

    /// Maximum encoding attempts per store operation.
    var maxAttempts: Int = 50

    // MARK: - Store

    /// Encode and cache a UTF-8 string under `key`. Returns the entry on success.
    @discardableResult
    func store(_ value: String, forKey key: String) -> QuantumCacheEntry? {
        guard let result = encoder.encode(value, maxAttempts: maxAttempts) else { return nil }
        let entry = QuantumCacheEntry(
            keys: result.keys,
            messageLength: result.messageLength,
            seedOffset: result.seedOffset,
            timestamp: Date()
        )
        index[key] = entry
        return entry
    }

    /// Encode raw bytes under `key`.
    @discardableResult
    func store(_ data: [UInt8], forKey key: String) -> QuantumCacheEntry? {
        guard let result = encoder.encode(data, maxAttempts: maxAttempts) else { return nil }
        let entry = QuantumCacheEntry(
            keys: result.keys,
            messageLength: result.messageLength,
            seedOffset: result.seedOffset,
            timestamp: Date()
        )
        index[key] = entry
        return entry
    }

    // MARK: - Retrieve

    /// Decode a cached value back to a string.
    func retrieve(forKey key: String) -> String? {
        guard let entry = index[key] else { return nil }
        return decoder.decodeString(
            keys: entry.keys,
            messageLength: entry.messageLength,
            seedOffset: entry.seedOffset
        )
    }

    /// Decode a cached value back to raw bytes.
    func retrieveData(forKey key: String) -> [UInt8]? {
        guard let entry = index[key] else { return nil }
        return decoder.decode(
            keys: entry.keys,
            messageLength: entry.messageLength,
            seedOffset: entry.seedOffset
        )
    }

    /// Decode directly from an entry (no index lookup).
    func retrieve(entry: QuantumCacheEntry) -> String? {
        decoder.decodeString(
            keys: entry.keys,
            messageLength: entry.messageLength,
            seedOffset: entry.seedOffset
        )
    }

    // MARK: - Management

    func remove(forKey key: String) { index.removeValue(forKey: key) }
    func removeAll() { index.removeAll() }
    var count: Int { index.count }
    var keys: [String] { Array(index.keys) }

    /// Export the full index as JSON data (for persistence).
    func exportIndex() throws -> Data {
        try JSONEncoder().encode(index)
    }

    /// Import a previously exported index.
    func importIndex(from data: Data) throws {
        index = try JSONDecoder().decode([String: QuantumCacheEntry].self, from: data)
    }
}
