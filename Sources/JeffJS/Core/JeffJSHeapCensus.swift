// JeffJSHeapCensus.swift
// JeffJS — live-object census for leak hunting.
//
// `JeffJSRuntime.heapCensus()` walks the runtime's GC list and groups the live
// objects by what they are: class name, plus the first own property names for
// ordinary objects (`Object{type,target,…}`), `name@file:line` for bytecode
// functions and the prototype's constructor name for instances. A heap that grows
// at idle shows up as the few keys whose counts climb between two censuses.
//
// JEFFJS_HEAP_CENSUS_S=<seconds>: print a census (the keys that grew since the
// previous one first) at most every <seconds>, taken at the start of a top-level
// native -> JS call (timers, animation frames, event dispatch). Prefixed
// `[Heap]`. JEFFJS_HEAP_CENSUS_GC=1 runs the cycle collector before each census,
// which separates uncollected cycles (gone after the GC) from refcount leaks.

import Foundation

/// Seconds between periodic censuses (0 = off). Read once by JeffJSRuntime.init.
nonisolated(unsafe) var jeffJS_heapCensusInterval: Double = 0
nonisolated(unsafe) var jeffJS_heapCensusRunGC = false
/// JEFFJS_HEAP_CENSUS_REFS=<substring>: for the live objects whose census key
/// contains it, also print who points at them (parent keys by edge count)
/// and how many of their references come from outside the GC graph
/// (refCount minus in-heap edges): a steady excess there is a refcount leak.
nonisolated(unsafe) var jeffJS_heapCensusRefs: [String] = []

func jeffJS_bootstrapHeapCensus() {
    let env = ProcessInfo.processInfo.environment
    jeffJS_heapCensusInterval = env["JEFFJS_HEAP_CENSUS_S"].flatMap(Double.init) ?? 0
    jeffJS_heapCensusRunGC = env["JEFFJS_HEAP_CENSUS_GC"] == "1"
    jeffJS_heapCensusRefs = (env["JEFFJS_HEAP_CENSUS_REFS"] ?? "").split(separator: "|").map(String.init)
}

/// Called at the start of every top-level native -> JS call.
@inline(__always)
func jeffJS_heapCensusTick(_ rt: JeffJSRuntime) {
    guard jeffJS_heapCensusInterval > 0 else { return }
    jeffJS_heapCensusTickSlow(rt)
}

@inline(never)
func jeffJS_heapCensusTickSlow(_ rt: JeffJSRuntime) {
    rt.heapCensusCalls += 1
    let now = CFAbsoluteTimeGetCurrent()
    if rt.heapCensusLastTime == 0 { rt.heapCensusLastTime = now; rt.heapCensusStartTime = now }
    guard now - rt.heapCensusLastTime >= jeffJS_heapCensusInterval else { return }
    rt.heapCensusLastTime = now
    if jeffJS_heapCensusRunGC, rt.gcPhase == .JS_GC_PHASE_NONE, !rt.inFreeChain { runGC(rt) }
    print(rt.heapCensusReport(elapsed: now - rt.heapCensusStartTime))
    rt.heapCensusCalls = 0
    fflush(stdout)
}

extension JeffJSRuntime {
    /// Live GC objects by kind (see the file header). Keys are stable across
    /// calls, so two censuses can be diffed.
    public func heapCensus() -> [String: Int] {
        var counts: [String: Int] = [:]
        for u in gcObjects {
            u._withUnsafeGuaranteedRef { hdr in
                counts[censusKey(hdr), default: 0] += 1
            }
        }
        return counts
    }

    /// Census text: totals, the keys that changed since the previous report
    /// (largest growth first) and the largest classes overall.
    public func heapCensusReport(elapsed: Double = 0, top: Int = 25) -> String {
        let counts = heapCensus()
        let prev = heapCensusPrevious
        heapCensusPrevious = counts
        let total = gcObjects.count
        var lines: [String] = []
        let prevTotal = prev.values.reduce(0, +)
        lines.append(String(format: "[Heap] t=%.1fs live=%d (%+d) calls=%d gcRuns=%d idleGCs=%d cyclesFreed=%d lastGC=%.1fms mallocSize=%dKB",
                            elapsed, total, prev.isEmpty ? 0 : total - prevTotal, heapCensusCalls, gcRuns, gcIdleRuns, gcCyclesFreed,
                            gcLastDuration * 1000,
                            mallocState.mallocSize / 1024))
        if !prev.isEmpty {
            var deltas: [(String, Int, Int)] = []
            for (k, v) in counts where v != prev[k] ?? 0 { deltas.append((k, v - (prev[k] ?? 0), v)) }
            for (k, v) in prev where counts[k] == nil { deltas.append((k, -v, 0)) }
            deltas.sort { abs($0.1) > abs($1.1) }
            for (k, d, v) in deltas.prefix(top) {
                lines.append("[Heap]   grew \(d > 0 ? "+" : "")\(d) -> \(v)  \(k)")
            }
        }
        for (k, v) in counts.sorted(by: { $0.value > $1.value }).prefix(prev.isEmpty ? top : 8) {
            lines.append("[Heap]   live \(v)  \(k)")
        }
        for pat in jeffJS_heapCensusRefs where !pat.isEmpty { lines.append(contentsOf: censusReferrers(pat)) }
        return lines.joined(separator: "\n")
    }

    /// Parents of the objects whose key contains `pattern`, and the part of
    /// their refcounts no GC-graph edge accounts for.
    private func censusReferrers(_ pattern: String) -> [String] {
        var keyOf: [ObjectIdentifier: String] = [:]
        var targets: Set<ObjectIdentifier> = []
        for u in gcObjects {
            u._withUnsafeGuaranteedRef { hdr in
                let k = censusKey(hdr)
                keyOf[ObjectIdentifier(hdr)] = k
                if k.contains(pattern) { targets.insert(ObjectIdentifier(hdr)) }
            }
        }
        var inEdges: [ObjectIdentifier: Int] = [:]
        var parents: [String: Int] = [:]
        for u in gcObjects {
            u._withUnsafeGuaranteedRef { hdr in
                let pk = keyOf[ObjectIdentifier(hdr)] ?? "?"
                markChildren(self, hdr) { _, child in
                    let cid = ObjectIdentifier(child)
                    guard targets.contains(cid) else { return }
                    inEdges[cid, default: 0] += 1
                    parents[pk, default: 0] += 1
                }
            }
        }
        var external = 0, externalObjs = 0, rcTotal = 0
        for u in gcObjects {
            u._withUnsafeGuaranteedRef { hdr in
                let id = ObjectIdentifier(hdr)
                guard targets.contains(id) else { return }
                rcTotal += hdr.refCount
                let ext = hdr.refCount - (inEdges[id] ?? 0)
                if ext > 0 { external += ext; externalObjs += 1 }
            }
        }
        var out = ["[Heap] refs of '\(pattern)': \(targets.count) objects, rc sum \(rcTotal), \(external) refs from outside the graph on \(externalObjs) objects"]
        for (k, v) in parents.sorted(by: { $0.value > $1.value }).prefix(12) {
            out.append("[Heap]     \(v) from \(k)")
        }
        return out
    }

    private func censusClassName(_ classID: Int) -> String {
        if classID >= 0, classID < classArray.count,
           let n = atomToString(classArray[classID].classNameAtom), !n.isEmpty {
            return n
        }
        return "class\(classID)"
    }

    private func censusFunctionName(_ fb: JeffJSFunctionBytecode) -> String {
        let name = fb.nameAtom != 0 ? (atomToString(fb.nameAtom) ?? "?") : "<anon>"
        var file = fb.fileName?.toSwiftString() ?? "?"
        if let slash = file.lastIndex(of: "/") { file = String(file[file.index(after: slash)...]) }
        if file.count > 40 { file = String(file.suffix(40)) }
        return "\(name)@\(file):\(fb.lineNum)"
    }

    private func censusOwnKeys(_ shape: JeffJSShape?, limit: Int = 6) -> String {
        guard let shape else { return "" }
        var names: [String] = []
        var n = 0
        for p in shape.prop where p.atom != 0 {
            n += 1
            if names.count < limit { names.append(atomToString(p.atom) ?? "#\(p.atom)") }
        }
        return "{" + names.joined(separator: ",") + (n > limit ? ",…+\(n - limit)" : "") + "}"
    }

    /// Name of the function stored in `proto.constructor` (a data slot), if any.
    private func censusConstructorName(_ proto: JeffJSObject?) -> String? {
        guard let proto, let shape = proto.shape else { return nil }
        let ctorAtom = JeffJSAtomID.JS_ATOM_constructor.rawValue
        for (i, p) in shape.prop.enumerated() where p.atom == ctorAtom {
            guard i < proto.propValues.count else { return nil }
            let v = proto.propValues[i]
            guard let f = v.toObject() else { return nil }
            if let fb = f.fbFast, fb.nameAtom != 0 { return atomToString(fb.nameAtom) }
            return nil
        }
        return nil
    }

    private func censusKey(_ hdr: JeffJSGCObjectHeader) -> String {
        switch hdr.gcObjType {
        case .jsObject:
            guard let o = hdr as? JeffJSObject else { return "jsObject(?)" }
            if let fb = o.fbFast { return "Function \(censusFunctionName(fb))" }
            let cid = o.classID
            var key = censusClassName(cid)
            if cid == JeffJSClassID.object.rawValue {
                if let c = censusConstructorName(o.proto), c != "Object" { key = "\(c) instance" }
                key += censusOwnKeys(o.shape)
            } else if cid == JeffJSClassID.array.rawValue {
                if case .array(_, _, let count) = o.payload { key += "[len \(min(Int(count), 8))\(count > 8 ? "+" : "")]" }
            } else if cid == JeffJSClassID.cFunction.rawValue || cid == JeffJSClassID.cFunctionData.rawValue {
                key += censusOwnKeys(o.shape, limit: 3)
            } else if cid >= Int(JeffJSClassID.initialCount) {
                key += censusOwnKeys(o.shape, limit: 3)
            }
            return key
        case .shape:
            let s = hdr as? JeffJSShape
            return "shape\(s?.isHashed == true ? "(hashed)" : "")"
        default:
            return "\(hdr.gcObjType)"
        }
    }
}
