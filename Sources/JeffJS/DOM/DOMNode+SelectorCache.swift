import Foundation

// MARK: - Selector-matching caches
//
// Two facts about an element are needed over and over while a stylesheet is
// matched, and both used to be recomputed by walking the (weak) parent chain
// for every rule test:
//
// * its language (`:lang()`, HTML §3.2.6.2) — inherited from the nearest
//   ancestor-or-self with a `lang` (or `xml:lang`) attribute;
// * which tag names, ids, classes and languages occur on its ancestors — so a
//   selector such as `.a .b .c` or `#nav :lang(ja) .x` whose left-hand compounds
//   cannot match any ancestor is rejected in O(1) before the combinator walk
//   (WebKit's `SelectorFilter`, a Bloom filter of ancestor identifier hashes).
//
// Both are cached on the node and computed at most once per *selector epoch*.
// The epoch is a global counter bumped by every change they depend on: a
// `parent` assignment (insert / remove / move), any `attributes` mutation, and
// any node's deallocation (which zeroes its children's weak `parent` without
// running their observers). A style pass does not mutate the tree, so each
// element computes its entry once per pass, from its parent's entry. A stale
// read racing a mutation on another thread is caught by the epoch recorded
// with the entry (it was read before the entry was computed).

/// The global selector epoch. A raw pointer rather than a static var so the
/// hot reads are plain loads (no exclusivity bookkeeping, no lazy-init check)
/// and so a `deinit` can bump it from any context.
nonisolated(unsafe) let domSelectorEpochStorage: UnsafeMutablePointer<UInt64> = {
    let pointer = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    pointer.initialize(to: 1)
    return pointer
}()

/// A 512-bit Bloom filter of identifier hashes (tag names, ids, classes and
/// primary language subtags), two bits per key. "May contain" can be a false
/// positive, never a false negative, so it only ever *rejects* selectors.
public struct DOMAncestorFilter: Sendable, Equatable {
    var bits = SIMD8<UInt64>(repeating: 0)

    public init() {}

    @inline(__always)
    mutating func insert(_ hash: UInt32) {
        let a = Int(hash & 511), b = Int((hash >> 9) & 511)
        bits[a >> 6] |= 1 << UInt64(a & 63)
        bits[b >> 6] |= 1 << UInt64(b & 63)
    }

    @inline(__always)
    func mayContain(_ hash: UInt32) -> Bool {
        let a = Int(hash & 511), b = Int((hash >> 9) & 511)
        return bits[a >> 6] & (1 << UInt64(a & 63)) != 0
            && bits[b >> 6] & (1 << UInt64(b & 63)) != 0
    }
}

/// Identifier hashes shared by the filter's two sides (the element and the
/// selector): FNV-1a over the UTF-8 bytes, salted by kind, then an avalanche
/// so both 9-bit slices are well mixed.
enum DOMSelectorKeyHash {
    static let tagKind: UInt8 = 0x74      // "t"
    static let idKind: UInt8 = 0x69       // "i"
    static let classKind: UInt8 = 0x63    // "c"
    static let langKind: UInt8 = 0x6C     // "l"

    @inline(__always)
    static func hash<S: StringProtocol>(_ kind: UInt8, _ string: S) -> UInt32 {
        var h: UInt32 = (2_166_136_261 ^ UInt32(kind)) &* 16_777_619
        for byte in string.utf8 { h = (h ^ UInt32(byte)) &* 16_777_619 }
        h ^= h >> 16
        h &*= 0x85EB_CA6B
        h ^= h >> 13
        h &*= 0xC2B2_AE35
        h ^= h >> 16
        return h
    }

    /// The primary subtag of a (lowercased) language tag or range.
    @inline(__always)
    static func primarySubtag(_ tag: String) -> Substring {
        if let dash = tag.firstIndex(of: "-") { return tag[..<dash] }
        return tag[...]
    }
}

/// Interned lowercased language tags, so a node caches its language as an
/// integer (a plain field write, safe to race with another reader).
/// IDs 0 and 1 are reserved: no language, and "unknown" (`lang=""`).
final class DOMLanguageTable: @unchecked Sendable {
    static let shared = DOMLanguageTable()

    static let none: UInt32 = 0
    static let unknown: UInt32 = 1
    /// The table is full: resolve the language without the cache.
    static let uncached: UInt32 = .max

    private let lock = NSLock()
    private var ids: [String: UInt32] = [:]
    private let capacity = 1 << 14
    /// Written once per slot, under the lock, before its ID is handed out;
    /// read without the lock afterwards.
    private let tags: UnsafeMutablePointer<String>
    private let primaryHashes: UnsafeMutablePointer<UInt32>
    private var count: UInt32 = 2

    private init() {
        tags = .allocate(capacity: capacity)
        primaryHashes = .allocate(capacity: capacity)
        tags.initialize(to: "")
        (tags + 1).initialize(to: "")
        primaryHashes[0] = 0
        primaryHashes[1] = 0
    }

    func id(forLowercased tag: String) -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        if let existing = ids[tag] { return existing }
        guard Int(count) < capacity else { return Self.uncached }
        let id = count
        (tags + Int(id)).initialize(to: tag)
        primaryHashes[Int(id)] = DOMSelectorKeyHash.hash(DOMSelectorKeyHash.langKind,
                                                         DOMSelectorKeyHash.primarySubtag(tag))
        count += 1
        ids[tag] = id
        return id
    }

    /// The lowercased tag of a real language ID (>= 2, not `uncached`).
    @inline(__always) func tag(_ id: UInt32) -> String { tags[Int(id)] }
    @inline(__always) func primaryHash(_ id: UInt32) -> UInt32 { primaryHashes[Int(id)] }
}

extension DOMNode {

    /// The current selector epoch.
    @inline(__always) static var selectorEpoch: UInt64 { domSelectorEpochStorage.pointee }

    /// The node's own `lang` / `xml:lang` value, if it declares one.
    @inline(__always)
    fileprivate var declaredLanguage: String? {
        guard nodeType == .element, !attributes.isEmpty else { return nil }
        return attributes["lang"] ?? attributes["xml:lang"]
    }

    /// The element's language (HTML §3.2.6.2): the nearest ancestor-or-self
    /// `lang` (or `xml:lang`) attribute, lowercased. `""` when that attribute is
    /// empty (the language is explicitly unknown — it does not inherit past
    /// it); nil when no ancestor declares one.
    public var language: String? {
        refreshSelectorCache(Self.selectorEpoch)
        switch selectorLanguageID {
        case DOMLanguageTable.none: return nil
        case DOMLanguageTable.unknown: return ""
        case DOMLanguageTable.uncached: return uncachedLanguage()
        case let id: return DOMLanguageTable.shared.tag(id)
        }
    }

    /// The same walk without the cache (used only when the language table
    /// is full).
    func uncachedLanguage() -> String? {
        var cursor: DOMNode? = self
        while let current = cursor {
            if let value = current.declaredLanguage { return value.lowercased() }
            cursor = current.parent
        }
        return nil
    }

    /// The Bloom filter of every element ancestor's identifiers (not the
    /// node's own) — what a selector's left-hand compounds are tested against.
    func ancestorFilterForMatching() -> DOMAncestorFilter {
        guard let parent else { return DOMAncestorFilter() }
        parent.refreshSelectorCache(Self.selectorEpoch)
        return parent.selectorInclusiveFilter
    }

    /// Brings the node's cache entry (and any stale ancestor's) up to `epoch`.
    @inline(__always)
    func refreshSelectorCache(_ epoch: UInt64) {
        if selectorCacheEpoch == epoch { return }
        refreshSelectorCacheSlow(epoch)
    }

    private func refreshSelectorCacheSlow(_ epoch: UInt64) {
        guard let parent = self.parent else {
            computeSelectorCache(parent: nil, epoch: epoch)
            return
        }
        if parent.selectorCacheEpoch == epoch {
            computeSelectorCache(parent: parent, epoch: epoch)
            return
        }
        // Collect the stale part of the chain (strong references), then fill
        // it in from the top down.
        var chain: [DOMNode] = [self, parent]
        var cursor = parent.parent
        while let node = cursor, node.selectorCacheEpoch != epoch {
            chain.append(node)
            cursor = node.parent
        }
        var above: DOMNode? = cursor
        for node in chain.reversed() {
            node.computeSelectorCache(parent: above, epoch: epoch)
            above = node
        }
    }

    private func computeSelectorCache(parent: DOMNode?, epoch: UInt64) {
        var filter = parent?.selectorInclusiveFilter ?? DOMAncestorFilter()
        var languageID = parent?.selectorLanguageID ?? DOMLanguageTable.none
        if nodeType == .element {
            if let declared = declaredLanguage {
                languageID = declared.isEmpty
                    ? DOMLanguageTable.unknown
                    : DOMLanguageTable.shared.id(forLowercased: declared.lowercased())
            }
            if let tag = lowercasedTagName {
                filter.insert(DOMSelectorKeyHash.hash(DOMSelectorKeyHash.tagKind, tag))
            }
            if let id = idAttribute {
                filter.insert(DOMSelectorKeyHash.hash(DOMSelectorKeyHash.idKind, id))
            }
            if attributes["class"] != nil {
                for cls in classList {
                    filter.insert(DOMSelectorKeyHash.hash(DOMSelectorKeyHash.classKind, cls))
                }
            }
            if languageID >= 2 && languageID != DOMLanguageTable.uncached {
                filter.insert(DOMLanguageTable.shared.primaryHash(languageID))
            } else if languageID == DOMLanguageTable.uncached, let language = uncachedLanguage(), !language.isEmpty {
                filter.insert(DOMSelectorKeyHash.hash(DOMSelectorKeyHash.langKind,
                                                      DOMSelectorKeyHash.primarySubtag(language)))
            }
        }
        selectorInclusiveFilter = filter
        selectorLanguageID = languageID
        selectorCacheEpoch = epoch
    }
}
