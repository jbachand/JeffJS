import Foundation
import Synchronization

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
// `parent` assignment (insert / remove / move), any attribute mutation, and
// any node's deallocation (which zeroes its children's weak `parent` without
// running their observers). A style pass does not mutate the tree, so each
// element computes its entry once per pass, from its parent's entry.
//
// Threads (see the contract in `DOMNode.swift`): the epoch is an `Atomic`,
// bumped with release ordering *after* the mutation (under the node's lock) it
// announces, and loaded with acquire ordering — so a reader that sees epoch E
// sees every mutation made before E was published. An entry is built into a
// local from the node's state and its parent's entry (each read under that
// node's own lock, never two at once) and published whole under the node's
// lock, tagged with the epoch the reader loaded *before* it read any input. A
// mutation racing the build bumps the epoch past that tag, so the entry is
// never trusted by a later read; readers of different epochs may publish in
// either order, and an older entry never replaces a newer one.

/// The global selector epoch.
let domSelectorEpoch = Atomic<UInt64>(1)

/// One node's selector-matching cache entry: valid while `epoch` equals the
/// global selector epoch.
struct DOMSelectorCacheEntry {
    var epoch: UInt64 = 0
    /// Interned language (`DOMLanguageTable`).
    var languageID: UInt32 = DOMLanguageTable.none
    /// The identifiers of the node and every element ancestor.
    var inclusiveFilter = DOMAncestorFilter()
    /// The identifiers of every element ancestor (the parent's inclusive
    /// filter), what a selector's left-hand compounds are tested against —
    /// stored so the test needs neither the parent pointer nor its lock.
    var ancestorFilter = DOMAncestorFilter()
}

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
/// integer.
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
    /// read without the lock afterwards (a reader got the ID through the
    /// lock, or through a node's lock taken after this one was released).
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
    @inline(__always) static var selectorEpoch: UInt64 { domSelectorEpoch.load(ordering: .acquiring) }

    /// Announces a mutation the selector caches depend on. Called after the
    /// mutation is visible (the node's lock released).
    @inline(__always) static func bumpSelectorEpoch() {
        domSelectorEpoch.wrappingAdd(1, ordering: .releasing)
    }

    /// The node's own `lang` / `xml:lang` value, if it declares one.
    @inline(__always)
    fileprivate var declaredLanguage: String? {
        guard nodeType == .element else { return nil }
        return state.withLock { s in
            s.attributes.isEmpty ? nil : (s.attributes["lang"] ?? s.attributes["xml:lang"])
        }
    }

    /// The element's language (HTML §3.2.6.2): the nearest ancestor-or-self
    /// `lang` (or `xml:lang`) attribute, lowercased. `""` when that attribute is
    /// empty (the language is explicitly unknown — it does not inherit past
    /// it); nil when no ancestor declares one.
    public var language: String? {
        switch selectorLanguageID(Self.selectorEpoch) {
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
    @inline(__always)
    func ancestorFilterForMatching() -> DOMAncestorFilter {
        let epoch = Self.selectorEpoch
        let cached = state.withLock { $0.selectorCache.epoch == epoch ? $0.selectorCache.ancestorFilter : nil }
        if let cached { return cached }
        return refreshSelectorCacheSlow(epoch).ancestorFilter
    }

    /// The node's interned language at `epoch`. Lock-free: `:lang()` is
    /// tested once per rule per element, so the language rides in one atomic
    /// word next to the entry (`selectorLanguageStamp`, see `languageStamp`).
    @inline(__always)
    func selectorLanguageID(_ epoch: UInt64) -> UInt32 {
        let word = selectorLanguageStamp.load(ordering: .acquiring)
        if word >> 16 == epoch & Self.languageStampEpochMask {
            let id = UInt32(truncatingIfNeeded: word & 0xFFFF)
            return id == 0xFFFF ? DOMLanguageTable.uncached : id
        }
        return refreshSelectorCacheSlow(epoch).languageID
    }

    /// The low 48 bits of the epoch go in the stamp (a stale stamp would have
    /// to be exactly a multiple of 2^48 mutations old to be mistaken for a
    /// current one).
    @inline(__always) static var languageStampEpochMask: UInt64 { (1 << 48) - 1 }

    /// `(epoch & mask) << 16 | languageID` (`uncached` as 0xFFFF; the
    /// language table holds 2^14 IDs).
    @inline(__always)
    static func languageStamp(epoch: UInt64, languageID: UInt32) -> UInt64 {
        let id = languageID == DOMLanguageTable.uncached ? 0xFFFF : UInt64(languageID & 0xFFFF)
        return (epoch & languageStampEpochMask) << 16 | id
    }

    /// Brings the node's entry (and any stale ancestor's) up to `epoch`
    /// and returns it.
    private func refreshSelectorCacheSlow(_ epoch: UInt64) -> DOMSelectorCacheEntry {
        guard let parent = self.parent else {
            return computeSelectorCache(parentEntry: nil, epoch: epoch)
        }
        let parentEntry = parent.state.withLock { $0.selectorCache }
        if parentEntry.epoch == epoch {
            return computeSelectorCache(parentEntry: parentEntry, epoch: epoch)
        }
        // Collect the stale part of the chain (strong references), then fill
        // it in from the top down.
        var chain: [DOMNode] = [self, parent]
        var above: DOMSelectorCacheEntry?
        var cursor = parent.parent
        while let node = cursor {
            let entry = node.state.withLock { $0.selectorCache }
            if entry.epoch == epoch { above = entry; break }
            chain.append(node)
            cursor = node.parent
        }
        for node in chain.reversed() {
            above = node.computeSelectorCache(parentEntry: above, epoch: epoch)
        }
        return above.unsafelyUnwrapped
    }

    private func computeSelectorCache(parentEntry: DOMSelectorCacheEntry?, epoch: UInt64) -> DOMSelectorCacheEntry {
        let ancestorFilter = parentEntry?.inclusiveFilter ?? DOMAncestorFilter()
        var filter = ancestorFilter
        var languageID = parentEntry?.languageID ?? DOMLanguageTable.none
        if nodeType == .element {
            let (declared, id, hasClass) = state.withLock { s -> (String?, String?, Bool) in
                let declared = s.attributes.isEmpty ? nil : (s.attributes["lang"] ?? s.attributes["xml:lang"])
                return (declared, s.idValue, s.attributes["class"] != nil)
            }
            if let declared {
                languageID = declared.isEmpty
                    ? DOMLanguageTable.unknown
                    : DOMLanguageTable.shared.id(forLowercased: declared.lowercased())
            }
            if let tag = lowercasedTagName {
                filter.insert(DOMSelectorKeyHash.hash(DOMSelectorKeyHash.tagKind, tag))
            }
            if let id {
                filter.insert(DOMSelectorKeyHash.hash(DOMSelectorKeyHash.idKind, id))
            }
            if hasClass {
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
        let entry = DOMSelectorCacheEntry(epoch: epoch, languageID: languageID,
                                          inclusiveFilter: filter, ancestorFilter: ancestorFilter)
        // Published under the lock, so concurrent publishers are ordered and
        // the stamp always matches the stored entry; release ordering makes
        // the language table slot behind the ID visible with it.
        let stamp = Self.languageStamp(epoch: epoch, languageID: languageID)
        state.withLock {
            if $0.selectorCache.epoch <= epoch {
                $0.selectorCache = entry
                selectorLanguageStamp.store(stamp, ordering: .releasing)
            }
        }
        return entry
    }
}
