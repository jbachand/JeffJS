import Foundation
import Darwin
import ObjectiveC

/// Memory census (perf fix "memory census", PERF_PLAN.md) — measurement only.
///
/// `heap`/`vmmap`/`leaks` cannot attach to simulator processes ("Failed to get DYLD
/// info"), so the app walks its own malloc zones the way `heap` does: every in-use
/// block is enumerated in-process (the enumerator locks each zone), and each block is
/// attributed to the class its first word points at (ObjC isa / Swift metadata).
/// Generic Swift classes (`_ContiguousArrayStorage<T>`, `_DictionaryStorage<K, V>`)
/// are instantiated at run time and are not in the ObjC class list; a candidate
/// isa whose superclass word is a known class is accepted as class metadata and
/// named with `_typeName`. Blocks with no class are grouped by size.
///
/// `RN_MEM_CENSUS_AT=30,120,300` prints a `[MemCensus]` block at those seconds after
/// the first JS engine is created (`RN_MEM_CENSUS_TOP`, default 40 rows). While a
/// zone is enumerated, threads that malloc from it wait (~0.2–1 s for a 500 MB heap).
nonisolated enum MallocCensus {
    nonisolated(unsafe) private static var scheduled = false
    private static let scheduleLock = NSLock()

    /// Idempotent; call from anything that exists once a page loads.
    static func scheduleFromEnvironment() {
        let env = ProcessInfo.processInfo.environment
        guard let spec = env["RN_MEM_CENSUS_AT"], !spec.isEmpty else { return }
        scheduleLock.lock()
        defer { scheduleLock.unlock() }
        if scheduled { return }
        scheduled = true
        let top = Int(env["RN_MEM_CENSUS_TOP"] ?? "") ?? 40
        for s in spec.split(separator: ",").compactMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + s) {
                let text = report(label: "t+\(Int(s))s", top: top)
                print(text)
                fflush(stdout)
            }
        }
    }

    // MARK: - Enumeration state (no allocation inside the recorder)

    fileprivate struct Slot {
        var key: UInt
        var count: Int
        var bytes: Int
    }

    fileprivate struct State {
        var slots: UnsafeMutablePointer<Slot>
        var capacity: Int
        var used: Int
        var totalBytes: Int
        var totalBlocks: Int
        var overflowBytes: Int
        var overflowBlocks: Int
        /// log2 size buckets for blocks whose first word is not a plausible pointer.
        var bucketBytes: UnsafeMutablePointer<Int>
        var bucketCounts: UnsafeMutablePointer<Int>
        var known: UnsafeMutablePointer<UInt>   // open-addressed set of class pointers
        var knownCapacity: Int
    }

    private static let isaMaskSim: UInt = 0x007f_ffff_ffff_fff8
    private static let isaMaskDevice: UInt = 0x0000_000f_ffff_fff8

    @inline(__always) private static func hash(_ k: UInt) -> Int {
        Int(truncatingIfNeeded: ((k >> 3) &* 0x9E37_79B9_7F4A_7C15) >> 17)
    }

    @inline(__always) private static func knownContains(_ s: UnsafeMutablePointer<State>, _ k: UInt) -> Bool {
        if k == 0 { return false }
        let mask = s.pointee.knownCapacity - 1
        var i = hash(k) & mask
        while true {
            let v = s.pointee.known[i]
            if v == k { return true }
            if v == 0 { return false }
            i = (i + 1) & mask
        }
    }

    private static func knownInsert(_ s: UnsafeMutablePointer<State>, _ k: UInt) {
        let mask = s.pointee.knownCapacity - 1
        var i = hash(k) & mask
        while true {
            let v = s.pointee.known[i]
            if v == k { return }
            if v == 0 { s.pointee.known[i] = k; return }
            i = (i + 1) & mask
        }
    }

    @inline(__always) private static func record(_ s: UnsafeMutablePointer<State>, key: UInt, size: Int) {
        let mask = s.pointee.capacity - 1
        var i = hash(key) & mask
        while true {
            let k = s.pointee.slots[i].key
            if k == key {
                s.pointee.slots[i].count += 1
                s.pointee.slots[i].bytes += size
                return
            }
            if k == 0 {
                if s.pointee.used * 4 >= s.pointee.capacity * 3 {
                    s.pointee.overflowBytes += size
                    s.pointee.overflowBlocks += 1
                    return
                }
                s.pointee.slots[i] = Slot(key: key, count: 1, bytes: size)
                s.pointee.used += 1
                return
            }
            i = (i + 1) & mask
        }
    }

    @inline(__always) private static func bucket(_ s: UnsafeMutablePointer<State>, size: Int) {
        var b = 0
        var v = max(size, 1) - 1
        while v > 0 { v >>= 1; b += 1 }
        b = min(b, 40)
        s.pointee.bucketBytes[b] += size
        s.pointee.bucketCounts[b] += 1
    }

    fileprivate static func recordRanges(_ context: UnsafeMutableRawPointer?, _ ranges: UnsafeMutablePointer<vm_range_t>?, _ count: UInt32) {
        guard let context, let ranges else { return }
        let s = context.assumingMemoryBound(to: State.self)
        for i in 0..<Int(count) {
            let r = ranges[i]
            let size = Int(r.size)
            s.pointee.totalBytes += size
            s.pointee.totalBlocks += 1
            guard size >= 16, let p = UnsafePointer<UInt>(bitPattern: UInt(r.address)) else {
                bucket(s, size: size)
                continue
            }
            let w = p.pointee
            var key: UInt = 0
            if knownContains(s, w) {
                key = w
            } else {
                if knownContains(s, w & 0x007f_ffff_ffff_fff8) { key = w & 0x007f_ffff_ffff_fff8 }
                else if knownContains(s, w & 0x0000_000f_ffff_fff8) { key = w & 0x0000_000f_ffff_fff8 }
            }
            if key == 0, w & 7 == 0, w > 0x1_0000_0000, w < 0x0000_7fff_ffff_ffff {
                key = w | 1   // unverified candidate (checked after the zones unlock)
            }
            if key == 0 { bucket(s, size: size) } else { record(s, key: key, size: size) }
        }
    }


    // MARK: - Report

    static func report(label: String, top: Int = 40) -> String {
        let start = CFAbsoluteTimeGetCurrent()
        // Known classes (allocates: before any zone is locked).
        var classCount: UInt32 = 0
        let classList = objc_copyClassList(&classCount)
        var knownCap = 1
        while knownCap < Int(classCount) * 4 { knownCap <<= 1 }
        let known = UnsafeMutablePointer<UInt>.allocate(capacity: knownCap)
        known.initialize(repeating: 0, count: knownCap)
        let capacity = 1 << 18
        let slots = UnsafeMutablePointer<Slot>.allocate(capacity: capacity)
        slots.initialize(repeating: Slot(key: 0, count: 0, bytes: 0), count: capacity)
        let bucketBytes = UnsafeMutablePointer<Int>.allocate(capacity: 41)
        bucketBytes.initialize(repeating: 0, count: 41)
        let bucketCounts = UnsafeMutablePointer<Int>.allocate(capacity: 41)
        bucketCounts.initialize(repeating: 0, count: 41)
        let state = UnsafeMutablePointer<State>.allocate(capacity: 1)
        state.initialize(to: State(slots: slots, capacity: capacity, used: 0, totalBytes: 0, totalBlocks: 0,
                                   overflowBytes: 0, overflowBlocks: 0, bucketBytes: bucketBytes,
                                   bucketCounts: bucketCounts, known: known, knownCapacity: knownCap))
        if let classList {
            // Raw loads: touching an element as `AnyClass` retains it, and some
            // root classes (`__NSGenericDeallocHandler`) abort on any message.
            let raw = UnsafeRawPointer(classList)
            for i in 0..<Int(classCount) {
                knownInsert(state, raw.load(fromByteOffset: i * MemoryLayout<UInt>.stride, as: UInt.self))
            }
        }

        var zonesPtr: UnsafeMutablePointer<vm_address_t>? = nil
        var zoneCount: UInt32 = 0
        _ = malloc_get_all_zones(mach_task_self_, nil, &zonesPtr, &zoneCount)
        var zoneLines: [String] = []
        zoneLines.reserveCapacity(Int(zoneCount))
        var zoneTotals = [(String, Int, Int)](repeating: ("", 0, 0), count: Int(zoneCount))
        var zones: [UnsafeMutablePointer<malloc_zone_t>] = []
        for z in 0..<Int(zoneCount) {
            if let zp = UnsafeMutablePointer<malloc_zone_t>(bitPattern: UInt(zonesPtr![z])) { zones.append(zp) }
        }
        let lockStart = CFAbsoluteTimeGetCurrent()
        // No `force_lock`: iOS's (and the simulator's) zone enumerators take the zone
        // lock themselves — a force-locked zone is a recursive os_unfair_lock and the
        // process is killed. The recorder runs under that lock, so it never allocates.
        for (zi, zp) in zones.enumerated() {
            let beforeBytes = state.pointee.totalBytes, beforeBlocks = state.pointee.totalBlocks
            if let intro = zp.pointee.introspect, let enumerate = intro.pointee.enumerator {
                _ = enumerate(mach_task_self_, UnsafeMutableRawPointer(state), UInt32(MALLOC_PTR_IN_USE_RANGE_TYPE),
                              vm_address_t(UInt(bitPattern: zp)), mallocCensusReader, mallocCensusRecorder)
            }
            zoneTotals[zi].1 = state.pointee.totalBytes - beforeBytes
            zoneTotals[zi].2 = state.pointee.totalBlocks - beforeBlocks
        }
        let lockedMs = (CFAbsoluteTimeGetCurrent() - lockStart) * 1000
        for (zi, zp) in zones.enumerated() {
            let name = zp.pointee.zone_name.map { String(cString: $0) } ?? "zone\(zi)"
            zoneTotals[zi].0 = name
        }
        for z in zoneTotals where z.2 > 0 {
            zoneLines.append("\(z.0) \(z.1 / 1024) KB / \(z.2)")
        }

        // Resolve keys to names.
        var byName: [String: (count: Int, bytes: Int)] = [:]
        var unverifiedBytes = 0, unverifiedBlocks = 0
        for i in 0..<capacity {
            let slot = slots[i]
            if slot.key == 0 { continue }
            var name: String? = nil
            if slot.key & 1 == 0 {
                name = className(slot.key)
            } else {
                let p = slot.key & ~1
                if slot.count >= 20, isPlausibleMetadata(p, state) {
                    name = className(p)
                } else if let target = UnsafeRawPointer(bitPattern: p), isReadable(target) {
                    // A raw buffer whose first word points at an object (a value
                    // array, a table of references): named by what it points at.
                    let isa = target.load(as: UInt.self)
                    if knownContains(state, isa) { name = "buffer→" + className(isa) }
                    else if knownContains(state, isa & 0x007f_ffff_ffff_fff8) { name = "buffer→" + className(isa & 0x007f_ffff_ffff_fff8) }
                }
            }
            if let name {
                byName[name, default: (0, 0)].count += slot.count
                byName[name, default: (0, 0)].bytes += slot.bytes
            } else {
                unverifiedBytes += slot.bytes
                unverifiedBlocks += slot.count
            }
        }

        let st = state.pointee
        var lines: [String] = []
        let fp = cliFootprintMB()
        lines.append(String(format: "[MemCensus] %@ phys_footprint=%.0fMB malloc=%.1fMB blocks=%d classified=%.1fMB walk=%.0fms total=%.0fms",
                            label, fp, Double(st.totalBytes) / 1_048_576, st.totalBlocks,
                            Double(byName.values.reduce(0) { $0 + $1.bytes }) / 1_048_576, lockedMs,
                            (CFAbsoluteTimeGetCurrent() - start) * 1000))
        lines.append("[MemCensus]   zones: " + zoneLines.joined(separator: ", "))
        for (name, v) in byName.sorted(by: { $0.value.bytes > $1.value.bytes }).prefix(top) {
            lines.append(String(format: "[MemCensus]   %8.2f MB %9d x %6d B  %@", Double(v.bytes) / 1_048_576, v.count,
                                v.count > 0 ? v.bytes / v.count : 0, name))
        }
        var buckets: [String] = []
        for b in 0...40 where bucketCounts[b] > 0 {
            buckets.append(String(format: "<=%d:%.1fMB/%d", 1 << b, Double(bucketBytes[b]) / 1_048_576, bucketCounts[b]))
        }
        let bucketTotal = (0...40).reduce(0) { $0 + bucketBytes[$1] }
        lines.append(String(format: "[MemCensus]   unclassified(no pointer at word 0) %.1fMB: ", Double(bucketTotal) / 1_048_576) + buckets.joined(separator: " "))
        lines.append(String(format: "[MemCensus]   unverified-pointer-first blocks %.1fMB / %d, table overflow %.1fMB / %d",
                            Double(unverifiedBytes) / 1_048_576, unverifiedBlocks,
                            Double(st.overflowBytes) / 1_048_576, st.overflowBlocks))

        free(UnsafeMutableRawPointer(classList))
        known.deallocate(); slots.deallocate(); bucketBytes.deallocate(); bucketCounts.deallocate(); state.deallocate()
        return lines.joined(separator: "\n")
    }

    /// Class metadata check for a pointer that is not in the ObjC class list: it
    /// must be readable (inside a malloc zone or a loaded image) and its
    /// superclass word must be a known class (generic Swift classes derive from
    /// non-generic runtime bases: `__ContiguousArrayStorageBase`,
    /// `__RawDictionaryStorage`, `__RawSetStorage`, …).
    private static func isPlausibleMetadata(_ p: UInt, _ state: UnsafeMutablePointer<State>) -> Bool {
        guard let raw = UnsafeRawPointer(bitPattern: p), isReadable(raw) else { return false }
        let superWord = raw.load(fromByteOffset: 8, as: UInt.self)
        guard knownContains(state, superWord), let superRaw = UnsafeRawPointer(bitPattern: superWord) else { return false }
        // The metaclass must be consistent too (a bogus candidate crashed `_typeName`):
        // candidate.isa = its metaclass M, readable, and M.superclass = the metaclass
        // of the candidate's (known) superclass.
        let mask: UInt = 0x007f_ffff_ffff_fff8
        let meta = raw.load(as: UInt.self) & mask
        guard let metaRaw = UnsafeRawPointer(bitPattern: meta), isReadable(metaRaw) else { return false }
        let superMeta = superRaw.load(as: UInt.self) & mask
        return superMeta != 0 && metaRaw.load(fromByteOffset: 8, as: UInt.self) & mask == superMeta
    }

    /// Inside a malloc zone or a loaded image (so at least 16 bytes can be read).
    private static func isReadable(_ raw: UnsafeRawPointer) -> Bool {
        var info = Dl_info()
        if dladdr(raw, &info) != 0 && info.dli_fbase != nil { return true }
        return malloc_zone_from_ptr(raw) != nil
    }

    private static func className(_ p: UInt) -> String {
        guard let raw = UnsafeRawPointer(bitPattern: p) else { return "?" }
        // As a metatype (no retain, see the class list above).
        return _typeName(unsafeBitCast(raw, to: Any.Type.self), qualified: false)
    }
}

/// C callbacks for the zone enumerator (no allocation, no captures).
nonisolated private func mallocCensusRecorder(_ task: task_t, _ context: UnsafeMutableRawPointer?, _ type: UInt32,
                                  _ ranges: UnsafeMutablePointer<vm_range_t>?, _ count: UInt32) {
    MallocCensus.recordRanges(context, ranges, count)
}

nonisolated private func mallocCensusReader(_ task: task_t, _ address: vm_address_t, _ size: vm_size_t,
                                _ out: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> kern_return_t {
    out?.pointee = UnsafeMutableRawPointer(bitPattern: UInt(address))
    return KERN_SUCCESS
}


// MARK: - Referrer search (CLI only): who points at the live instances of a class?
nonisolated(unsafe) var refTargets: UnsafeMutablePointer<UInt>? = nil
nonisolated(unsafe) var refTargetCap = 0
nonisolated(unsafe) var refTargetCount = 0
nonisolated(unsafe) var refTargetIsa: UInt = 0
nonisolated(unsafe) var refPhase = 0
nonisolated(unsafe) var refOut: UnsafeMutablePointer<(UInt, Int)>? = nil   // referrer isa -> count
nonisolated(unsafe) var refOutCap = 1 << 16
nonisolated(unsafe) var refSamples: UnsafeMutablePointer<UInt>? = nil
nonisolated(unsafe) var refSampleCount = 0

@inline(__always) func refHash(_ k: UInt) -> Int { Int(truncatingIfNeeded: ((k >> 3) &* 0x9E37_79B9_7F4A_7C15) >> 17) }
func refTargetContains(_ k: UInt) -> Bool {
    guard let t = refTargets, k != 0 else { return false }
    var i = refHash(k) & (refTargetCap - 1)
    while true { let v = t[i]; if v == k { return true }; if v == 0 { return false }; i = (i + 1) & (refTargetCap - 1) }
}
func refRecorder(_ task: task_t, _ ctx: UnsafeMutableRawPointer?, _ type: UInt32, _ ranges: UnsafeMutablePointer<vm_range_t>?, _ count: UInt32) {
    guard let ranges else { return }
    for i in 0..<Int(count) {
        let r = ranges[i]
        guard r.size >= 16, let p = UnsafePointer<UInt>(bitPattern: UInt(r.address)) else { continue }
        if refPhase == 0 {
            if p.pointee == refTargetIsa, let t = refTargets, refTargetCount < refTargetCap / 2 {
                var j = refHash(UInt(r.address)) & (refTargetCap - 1)
                while t[j] != 0 { j = (j + 1) & (refTargetCap - 1) }
                t[j] = UInt(r.address); refTargetCount += 1
            }
        } else {
            let words = Int(r.size) / 8
            for w in 0..<words where refTargetContains(p[w]) {
                let isa = p.pointee
                var j = refHash(isa) & (refOutCap - 1)
                while refOut![j].0 != 0 && refOut![j].0 != isa { j = (j + 1) & (refOutCap - 1) }
                refOut![j].0 = isa; refOut![j].1 += 1
                if refSampleCount < 64 { refSamples![refSampleCount] = UInt(r.address); refSampleCount += 1 }
            }
        }
    }
}
func refReader(_ task: task_t, _ address: vm_address_t, _ size: vm_size_t, _ out: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> kern_return_t {
    out?.pointee = UnsafeMutableRawPointer(bitPattern: UInt(address)); return KERN_SUCCESS
}
func referrerReport(className: String) -> String {
    guard let cls = NSClassFromString(className) else { return "[Refs] no class \(className)" }
    refTargetIsa = unsafeBitCast(cls, to: UInt.self)
    refTargetCap = 1 << 20
    refTargets = .allocate(capacity: refTargetCap); refTargets!.initialize(repeating: 0, count: refTargetCap)
    refOut = .allocate(capacity: refOutCap); refOut!.initialize(repeating: (0, 0), count: refOutCap)
    refSamples = .allocate(capacity: 64)
    var zonesPtr: UnsafeMutablePointer<vm_address_t>? = nil
    var zoneCount: UInt32 = 0
    _ = malloc_get_all_zones(mach_task_self_, nil, &zonesPtr, &zoneCount)
    for phase in 0...1 {
        refPhase = phase
        for z in 0..<Int(zoneCount) {
            guard let zp = UnsafeMutablePointer<malloc_zone_t>(bitPattern: UInt(zonesPtr![z])),
                  let en = zp.pointee.introspect?.pointee.enumerator else { continue }
            _ = en(mach_task_self_, nil, UInt32(MALLOC_PTR_IN_USE_RANGE_TYPE), vm_address_t(UInt(bitPattern: zp)), refReader, refRecorder)
        }
    }
    var lines = ["[Refs] \(className): \(refTargetCount) instances"]
    var rows: [(String, Int)] = []
    for j in 0..<refOutCap where refOut![j].0 != 0 {
        let isa = refOut![j].0
        var name = String(format: "0x%lx", isa)
        if let raw = UnsafeRawPointer(bitPattern: isa) {
            var info = Dl_info()
            if dladdr(raw, &info) != 0, let s = info.dli_sname { name = String(cString: s) }
            else if let c = objc_getClassList_contains(isa) { name = c }
        }
        rows.append((name, refOut![j].1))
    }
    for (n, c) in rows.sorted(by: { $0.1 > $1.1 }).prefix(20) { lines.append("[Refs]   \(c) from \(n)") }
    return lines.joined(separator: "\n")
}

func objc_getClassList_contains(_ p: UInt) -> String? {
    var n: UInt32 = 0
    guard let list = objc_copyClassList(&n) else { return nil }
    defer { free(UnsafeMutableRawPointer(list)) }
    let raw = UnsafeRawPointer(list)
    for i in 0..<Int(n) where raw.load(fromByteOffset: i * 8, as: UInt.self) == p {
        return _typeName(unsafeBitCast(UnsafeRawPointer(bitPattern: p)!, to: Any.Type.self), qualified: false)
    }
    return nil
}
