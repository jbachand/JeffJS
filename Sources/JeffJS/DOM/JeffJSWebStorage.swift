// JeffJSWebStorage.swift
// JeffJS — Web Storage (HTML §12.2) storage areas and the host store protocol.
//
// `localStorage` is a per-origin key/value area with a byte quota; the host
// supplies where it lives (`JeffJSWebStorageStore`: React Natively keeps one
// file per origin, the CLI and the tests keep it in memory). `sessionStorage`
// is an in-memory area per (top-level browsing context, origin) owned by the
// engine. `JeffJSStorageBridge` puts both behind `__nativeStorage`, throws
// `QuotaExceededError` and fires `storage` events.
//
// Nothing here may use `UserDefaults`: page data in the preferences plist grew
// it past the platform cap (watchOS aborted the app with
// `__CFPREFERENCES_HAS_DETECTED_THIS_APP_TRYING_TO_STORE_TOO_MUCH_DATA__` once
// Wikipedia's 940 KB module store was written, 2026-10-01).

import Foundation

// MARK: - Errors

nonisolated public enum JeffJSWebStorageError: Error, Equatable, Sendable {
    /// The write would take the origin past its quota; nothing was changed.
    case quotaExceeded(needed: Int, quota: Int)
}

// MARK: - Origin

nonisolated public enum JeffJSWebStorageOrigin {
    /// The serialized origin (HTML §7.1.1) that keys an origin's storage:
    /// `https://en.wikipedia.org`, `http://127.0.0.1:8123`, `file://`.
    /// Default ports are omitted; `blob:` URLs take their inner URL's origin.
    public static func key(for url: URL) -> String {
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == "blob", let inner = URL(string: String(url.absoluteString.dropFirst(5))), inner.scheme != nil {
            return key(for: inner)
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return scheme.isEmpty ? "null" : "\(scheme)://"
        }
        let defaults: [String: Int] = ["http": 80, "https": 443, "ws": 80, "wss": 443]
        let shownHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        if let port = url.port, defaults[scheme] != port {
            return "\(scheme)://\(shownHost):\(port)"
        }
        return "\(scheme)://\(shownHost)"
    }
}

// MARK: - Storage area

/// One storage area: keys in insertion order (an update keeps its key's
/// place; the order is "user-agent defined but stable while the key count
/// does not change", HTML §12.2.1) and WebKit's byte accounting.
nonisolated public struct JeffJSWebStorageArea: Sendable, Equatable {
    public private(set) var keys: [String] = []
    private var values: [String: String] = [:]
    /// Sum of `cost(key) + cost(value)` over the items.
    public private(set) var bytes: Int = 0

    public init() {}

    /// Restores an area from `(key, value)` pairs in order; pairs past
    /// `quota` (when given) are dropped.
    public init(pairs: [(String, String)], quota: Int? = nil) {
        for (k, v) in pairs where values[k] == nil {
            let c = Self.cost(k) + Self.cost(v)
            if let quota, bytes + c > quota { continue }
            keys.append(k)
            values[k] = v
            bytes += c
        }
    }

    /// WebKit `String::sizeInBytes()`: one byte per code unit for an 8-bit
    /// (Latin-1) string, two otherwise.
    public static func cost(_ s: String) -> Int {
        var n = 0, wide = false
        for u in s.utf16 {
            n += 1
            if u > 0xFF { wide = true }
        }
        return wide ? n * 2 : n
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }
    public var pairs: [(String, String)] { keys.map { ($0, values[$0] ?? "") } }

    public func value(for key: String) -> String? { values[key] }

    public func key(at index: Int) -> String? {
        index >= 0 && index < keys.count ? keys[index] : nil
    }

    /// The byte count after storing `value` under `key`.
    public func bytesAfterSetting(_ key: String, _ value: String) -> Int {
        if let old = values[key] { return bytes - Self.cost(old) + Self.cost(value) }
        return bytes + Self.cost(key) + Self.cost(value)
    }

    /// Stores `value`; returns the previous value. `extraBytes` = what other
    /// areas of the origin already use (they share the quota).
    @discardableResult
    public mutating func set(_ key: String, _ value: String, quota: Int?, extraBytes: Int = 0) throws -> String? {
        let after = bytesAfterSetting(key, value)
        if let quota, after + extraBytes > quota, after > bytes {
            throw JeffJSWebStorageError.quotaExceeded(needed: after + extraBytes, quota: quota)
        }
        let old = values.updateValue(value, forKey: key)
        if old == nil { keys.append(key) }
        bytes = after
        return old
    }

    @discardableResult
    public mutating func remove(_ key: String) -> String? {
        guard let old = values.removeValue(forKey: key) else { return nil }
        if let i = keys.firstIndex(of: key) { keys.remove(at: i) }
        bytes -= Self.cost(key) + Self.cost(old)
        return old
    }

    /// Empties the area; false when it was already empty.
    @discardableResult
    public mutating func removeAll() -> Bool {
        guard !keys.isEmpty else { return false }
        keys.removeAll()
        values.removeAll()
        bytes = 0
        return true
    }
}

// MARK: - Host store protocol

/// Where an origin's persistent storage areas live. `origin` is
/// `JeffJSWebStorageOrigin.key(for:)`; `area` is the namespace
/// (`local_storage`, plus the legacy `cookies` / `chrome_storage_*` ones).
/// Called from the JS thread; implementations must be thread-safe, keep reads
/// cheap (load lazily, cache in memory) and write back off that thread.
nonisolated public protocol JeffJSWebStorageStore: AnyObject, Sendable {
    func getItem(_ key: String, origin: String, area: String) -> String?
    /// Stores `value`; returns the previous value (nil = new key). Throws
    /// `JeffJSWebStorageError.quotaExceeded` without changing anything when
    /// the origin would go past its quota.
    func setItem(_ value: String, forKey key: String, origin: String, area: String) throws -> String?
    /// Removes `key`; returns the removed value (nil = there was none).
    func removeItem(_ key: String, origin: String, area: String) -> String?
    /// Empties the area; false when it was already empty.
    func clear(origin: String, area: String) -> Bool
    /// The keys in the area's order (`key(n)` = `keys[n]`).
    func keys(origin: String, area: String) -> [String]
    func count(origin: String, area: String) -> Int
    func key(at index: Int, origin: String, area: String) -> String?
}

nonisolated public extension JeffJSWebStorageStore {
    func count(origin: String, area: String) -> Int { keys(origin: origin, area: area).count }
    func key(at index: Int, origin: String, area: String) -> String? {
        let k = keys(origin: origin, area: area)
        return index >= 0 && index < k.count ? k[index] : nil
    }
}

// MARK: - In-memory store

/// The default store (CLI, tests, `sessionStorage`): every origin's areas in
/// memory, one quota per origin shared by its areas.
nonisolated public final class JeffJSMemoryWebStorage: JeffJSWebStorageStore, @unchecked Sendable {
    public let quotaBytes: Int
    private let lock = NSLock()
    private var origins: [String: [String: JeffJSWebStorageArea]] = [:]

    /// `quotaBytes` nil = `storage.localQuotaBytes`; 0 = no quota.
    public init(quotaBytes: Int? = nil) {
        self.quotaBytes = quotaBytes ?? JeffJSConfig.storageLocalQuotaBytes
    }

    private func otherBytes(_ areas: [String: JeffJSWebStorageArea], except area: String) -> Int {
        areas.reduce(0) { $0 + ($1.key == area ? 0 : $1.value.bytes) }
    }

    public func getItem(_ key: String, origin: String, area: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return origins[origin]?[area]?.value(for: key)
    }

    public func setItem(_ value: String, forKey key: String, origin: String, area: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        var areas = origins[origin] ?? [:]
        var a = areas[area] ?? JeffJSWebStorageArea()
        let old = try a.set(key, value, quota: quotaBytes > 0 ? quotaBytes : nil,
                            extraBytes: otherBytes(areas, except: area))
        areas[area] = a
        origins[origin] = areas
        return old
    }

    public func removeItem(_ key: String, origin: String, area: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard var a = origins[origin]?[area] else { return nil }
        let old = a.remove(key)
        origins[origin]?[area] = a
        return old
    }

    public func clear(origin: String, area: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var a = origins[origin]?[area] else { return false }
        let changed = a.removeAll()
        origins[origin]?[area] = a
        return changed
    }

    public func keys(origin: String, area: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return origins[origin]?[area]?.keys ?? []
    }

    public func count(origin: String, area: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return origins[origin]?[area]?.count ?? 0
    }

    public func key(at index: Int, origin: String, area: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return origins[origin]?[area]?.key(at: index)
    }

    /// Bytes the origin uses over all its areas.
    public func bytes(origin: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return (origins[origin] ?? [:]).values.reduce(0) { $0 + $1.bytes }
    }

    /// Forgets everything ("Clear Website Data").
    public func removeAll() {
        lock.lock(); origins.removeAll(); lock.unlock()
    }
}
