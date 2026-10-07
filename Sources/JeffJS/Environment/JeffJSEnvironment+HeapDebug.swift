// JeffJSEnvironment+HeapDebug.swift
// jeffjs-cli heap reports (--heap-report, --roots, --orphans): the environment-level
// walks of JeffJSHeapDebug. Lives in Environment/ because the app's polyfill precompile
// harness (Scripts/precompile_polyfills.sh) builds the engine without this folder.

import Foundation

extension JeffJSEnvironment {
    /// Live GC-heap composition: objects by class, plain-object property
    /// counts / spare slots, function-object field use, shapes. Tooling only.
    public func heapHistogram() -> String {
        let rt = runtime
        var byClass: [Int: Int] = [:]
        var varRefs = 0, others = 0
        var propCountHist: [Int: Int] = [:]
        var spareSlots = 0, usedSlots = 0, withStorage = 0
        var shapes = Set<ObjectIdentifier>()
        var hashedShapes = 0
        var fnWithVarRefs = 0, fnVarRefSlots = 0, fnArrowThis = 0, fnHome = 0, fnLazyProto = 0
        var withExtra = 0, withFastArray = 0, arrElems = 0, arrCap = 0
        var payloadKinds: [String: Int] = [:]
        var byShape: [ObjectIdentifier: (JeffJSShape, Int)] = [:]
        var valueKinds: [String: Int] = [:]
        for u in rt.gcObjects {
            let h = u.takeUnretainedValue()
            if h.gcObjType == .varRef { varRefs += 1; continue }
            guard let o = h as? JeffJSObject else { others += 1; continue }
            byClass[o.classID, default: 0] += 1
            let n = o.propValues.count
            propCountHist[min(n, 16), default: 0] += 1
            if o.propValues.capacity > 0 { withStorage += 1 }
            spareSlots += o.propValues.capacity - n; usedSlots += n
            if let s = o.shape, o.classID == 1 {
                byShape[ObjectIdentifier(s), default: (s, 0)].1 += 1
            }
            if o.classID == 1 {
                for i in 0..<n {
                    let v = o.propValues[i]
                    let k = v.isString ? "string" : v.isObject ? "object" : v.isInt ? "int" : v.isFloat64 ? "double" : v.isBool ? "bool" : v.isUndefined ? "undefined" : v.isNull ? "null" : "other"
                    valueKinds[k, default: 0] += 1
                }
            }
            if let s = o.shape {
                if shapes.insert(ObjectIdentifier(s)).inserted, s.isHashed { hashedShapes += 1 }
            }
            if o.fbFast != nil {
                if !o.varRefsFast.isEmpty { fnWithVarRefs += 1; fnVarRefSlots += o.varRefsFast.count }
                if o.arrowThisVal != nil { fnArrowThis += 1 }
                if o.needsLazyPrototype { fnLazyProto += 1 }
            }
            if case .bytecodeFunc(_, _, let home) = o.payload, home != nil { fnHome += 1 }
            if o.propExtraCount > 0 { withExtra += 1 }
            if let st = o._fastArrayValues { withFastArray += 1; arrElems += Int(st.count); arrCap += st.values.count }
            let k: String
            switch o.payload {
            case .opaque(let a): k = a == nil ? "opaque(nil)" : "opaque(\(type(of: a!)))"
            case .bytecodeFunc: k = "bytecodeFunc"
            case .cFunc: k = "cFunc"
            case .array: k = "array"
            case .regexp: k = "regexp"
            case .objectData: k = "objectData"
            case .pendingErrorStack: k = "pendingErrorStack"
            case .boundFunction: k = "boundFunction"
            case .forInIterator: k = "forInIterator"
            case .arrayBuffer: k = "arrayBuffer"
            case .typedArray: k = "typedArray"
            case .mapState: k = "mapState"
            case .generatorData: k = "generatorData"
            case .proxyData: k = "proxyData"
            case .promiseData: k = "promiseData"
            case .asyncFunctionData: k = "asyncFunctionData"
            case .globalObject: k = "globalObject"
            }
            payloadKinds[k, default: 0] += 1
        }
        var lines: [String] = []
        lines.append("[hist] instance sizes: object \(class_getInstanceSize(JeffJSObject.self)) aux \(class_getInstanceSize(JeffJSObjectAux.self)) string \(class_getInstanceSize(JeffJSString.self)) rope \(class_getInstanceSize(JeffJSStringRope.self)) shape \(class_getInstanceSize(JeffJSShape.self)) varRef \(class_getInstanceSize(JeffJSVarRef.self)) body \(class_getInstanceSize(JeffJSFunctionBytecodeCompiled.self)) atom \(class_getInstanceSize(JeffJSAtomStruct.self)) lazyInfo \(class_getInstanceSize(JeffJSLazyFunctionInfo.self))")
        lines.append("[hist] gc list: objects=\(byClass.values.reduce(0, +)) varRefs=\(varRefs) other=\(others) shapes=\(shapes.count) (hashed \(hashedShapes))")
        lines.append("[hist] by class: " + byClass.sorted { $0.value > $1.value }.prefix(16).map { "\($0.key):\($0.value)" }.joined(separator: " "))
        lines.append("[hist] payload: " + payloadKinds.sorted { $0.value > $1.value }.prefix(16).map { "\($0.key):\($0.value)" }.joined(separator: " "))
        lines.append("[hist] props per object: " + propCountHist.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))
        lines.append("[hist] prop slots used=\(usedSlots) spare=\(spareSlots) objectsWithStorage=\(withStorage) withExtra=\(withExtra)")
        lines.append("[hist] functions: withVarRefs=\(fnWithVarRefs) varRefSlots=\(fnVarRefSlots) arrowThis=\(fnArrowThis) homeObject=\(fnHome) lazyProto=\(fnLazyProto)")
        lines.append("[hist] arrays: fast=\(withFastArray) elems=\(arrElems) cap=\(arrCap)")
        // Function bodies reachable from function objects (and their nested
        // bodies through constant pools).
        var seenFB = Set<ObjectIdentifier>()
        var fbStack: [JeffJSFunctionBytecode] = []
        for u in rt.gcObjects {
            if let o = u.takeUnretainedValue() as? JeffJSObject, let fb = o.fbFast,
               seenFB.insert(ObjectIdentifier(fb)).inserted { fbStack.append(fb) }
        }
        var bcBytes = 0, bcExec = 0, cpoolSlots = 0, cvars = 0, icBytes = 0, lazyPending = 0, fbs = 0
        while let fb = fbStack.popLast() {
            fbs += 1
            bcBytes += fb.bytecodeLen
            if fb.bcPtrFast != nil { bcExec += fb.bytecodeLen }
            cpoolSlots += fb.cpool.count
            cvars += fb.closureVarsList.count
            if let ic = fb.ic { icBytes += ic.byteSize }
            if fb.isLazyPending { lazyPending += 1 }
            for v in fb.cpool where v.isFunctionBytecode {
                if let child = v.toPtr() as? JeffJSFunctionBytecode, seenFB.insert(ObjectIdentifier(child)).inserted { fbStack.append(child) }
            }
        }
        lines.append("[hist] bodies reachable=\(fbs) lazyPending=\(lazyPending) bytecode=\(bcBytes / 1024)KB (executed \(bcExec / 1024)KB of it) cpoolSlots=\(cpoolSlots) closureVars=\(cvars) ic=\(icBytes / 1024)KB entry=\(MemoryLayout<JeffJSICEntry>.stride)B")
        lines.append("[hist] plain-object values: " + valueKinds.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }.joined(separator: " "))
        for (s, c) in byShape.values.sorted(by: { $0.1 > $1.1 }).prefix(12) {
            let names = s.prop.prefix(s.propCount).map { rt.atomToString($0.atom) ?? "?" }.joined(separator: ",")
            let protoDesc = s.proto.map { "proto(class \($0.classID), \($0.propValues.count) props)" } ?? "null-proto"
            lines.append("[hist]   shape x\(c): {\(names.prefix(160))} \(protoDesc)")
        }
        return lines.joined(separator: "\n")
    }
}

extension JeffJSEnvironment {
    /// GC roots by kind: listed objects whose refCount exceeds the counted
    /// references other listed objects hold on them (what trial deletion
    /// leaves > 0). Legitimate roots are held by the stack, untracked
    /// intrinsics, the host; anything else is a refcount leak.
    public func rootReport(top: Int = 25) -> String {
        let rt = runtime
        var indeg: [ObjectIdentifier: Int] = [:]
        indeg.reserveCapacity(rt.gcObjects.count)
        for u in rt.gcObjects {
            let h = u.takeUnretainedValue()
            markChildren(rt, h) { _, c in
                if c.gcListIndex != -1 { indeg[ObjectIdentifier(c), default: 0] += 1 }
            }
        }
        var groups: [String: (n: Int, surplus: Int)] = [:]
        var totalRoots = 0
        for u in rt.gcObjects {
            let h = u.takeUnretainedValue()
            if h.gcObjType == .varRef { continue }
            let s = h.refCount - (indeg[ObjectIdentifier(h)] ?? 0)
            guard s > 0 else { continue }
            totalRoots += 1
            var key = "\(h.gcObjType)"
            if let o = h as? JeffJSObject {
                key = "class \(o.classID)"
                if let sh = o.shape {
                    let names = sh.prop.prefix(min(sh.propCount, 6)).map { rt.atomToString($0.atom) ?? "?" }.joined(separator: ",")
                    key += " {\(names)}"
                }
                if let fb = o.fbFast { key += " fn \(rt.atomToString(fb.nameAtom) ?? "?")" }
            }
            groups[key, default: (0, 0)].n += 1
            groups[key, default: (0, 0)].surplus += s
        }
        var lines = ["[roots] \(totalRoots) roots of \(rt.gcObjects.count) listed"]
        for (k, v) in groups.sorted(by: { $0.value.n > $1.value.n }).prefix(top) {
            lines.append("[roots]   \(v.n) x (surplus \(v.surplus)) \(k.prefix(150))")
        }
        return lines.joined(separator: "\n")
    }
}

extension JeffJSHeapDebug {
    /// Aggregate statistics over function-body instances found by a zone walk.
    public static func functionBodyReport(_ addrs: [UInt]) -> String {
        var n = 0, bc = 0, bcBuf = 0, dbg = 0, ic = 0, icTables = 0, cpool = 0, cvars = 0, vardefs = 0
        var pending = 0, topLevel = 0, withClosures = 0, rc1 = 0, srcSpan = 0
        var icSlots = 0, icSites = 0, icMapBytes = 0, icUsed = 0
        var icByCap: [Int: (n: Int, used: Int, top: Int)] = [:]
        for a in addrs {
            guard let p = UnsafeRawPointer(bitPattern: a) else { continue }
            let any = Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue()
            guard let fb = any as? JeffJSFunctionBytecode else { continue }
            n += 1
            bc += fb.withBytecodeBytes { $0.count }
            if fb.bcPtrFast != nil { bcBuf += fb.bytecodeLen }
            if let c = fb as? JeffJSFunctionBytecodeCompiled {
                dbg += c.debugPc2lineBuf.count + c.debugPc2colBuf.count + c.debugExprSpans.count
                vardefs += c.vardefs.count
            }
            if let t = fb.ic {
                ic += t.byteSize; icTables += 1
                icSlots += t.capacity; icSites += t.siteCount; icMapBytes += t.mapLength * 2
                var used = 0
                for e in t.entries where e.pc >= 0 { used += 1 }
                icUsed += used
                var bucket = 8
                while bucket < t.capacity { bucket <<= 1 }
                var r = icByCap[bucket] ?? (0, 0, 0)
                r.n += 1; r.used += used; if fb.isTopLevelCode { r.top += 1 }
                icByCap[bucket] = r
            }
            cpool += fb.cpool.count
            cvars += fb.closureVarsList.count
            if fb.isLazyPending { pending += 1 }
            if fb.isTopLevelCode { topLevel += 1 }
            if fb.liveClosures > 0 { withClosures += 1 }
            if fb.refCount <= 1 { rc1 += 1 }
            if fb.sourceLen > 0 { srcSpan += 1 }
        }
        let icLine = icByCap.sorted { $0.key < $1.key }.map { "cap\($0.key):\($0.value.n) tables, \($0.value.used) used slots, \($0.value.top) top-level" }.joined(separator: "; ")
        return "[bodies] IC by capacity: \(icLine)\n[bodies] \(n) live: bytecode \(bc / 1024)KB (executed \(bcBuf / 1024)KB of it), debug tables \(dbg / 1024)KB, IC \(icTables) tables \(ic / 1024)KB (\(icSlots) slots, \(icUsed) used, \(icSites) sites, map \(icMapBytes / 1024)KB), cpool \(cpool) slots, closureVars \(cvars), vardefs \(vardefs); lazyPending \(pending), topLevel \(topLevel), withLiveClosures \(withClosures), rc<=1 \(rc1), withSourceSpan \(srcSpan)"
    }
}

extension JeffJSHeapDebug {
    /// Duplicate-content analysis over string instances found by a zone walk.
    public static func stringDuplicateReport(_ addrs: [UInt]) -> String {
        var byContent: [String: Int] = [:]
        var total = 0, chars = 0, wide = 0
        var lenHist: [Int: Int] = [:]
        for a in addrs {
            guard let p = UnsafeRawPointer(bitPattern: a) else { continue }
            let any = Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue()
            guard let s = any as? JeffJSString else { continue }
            total += 1; chars += s.len; if s.isWideChar { wide += 1 }
            let b = s.len <= 8 ? 8 : s.len <= 16 ? 16 : s.len <= 32 ? 32 : s.len <= 64 ? 64 : s.len <= 256 ? 256 : 999
            lenHist[b, default: 0] += 1
            if s.len <= 64 { byContent[s.toSwiftString(), default: 0] += 1 }
        }
        var dupStrings = 0, dupKinds = 0
        for (_, c) in byContent where c > 1 { dupStrings += c - 1; dupKinds += 1 }
        let top = byContent.sorted { $0.value > $1.value }.prefix(15).map { "\($0.value)x\"\($0.key.prefix(24))\"" }.joined(separator: " ")
        let hist = lenHist.sorted { $0.key < $1.key }.map { "≤\($0.key == 999 ? "∞" : String($0.key)):\($0.value)" }.joined(separator: " ")
        return "[strings] \(total) strings, \(chars) chars, \(wide) wide; lengths \(hist)\n[strings] short (≤64) duplicates: \(dupStrings) redundant copies of \(dupKinds) contents; top: \(top)"
    }
}
