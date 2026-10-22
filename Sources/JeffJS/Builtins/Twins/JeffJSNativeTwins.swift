// JeffJSNativeTwins.swift
// JeffJS — library-aware substitution: native twins of known npm functions
// (jbachand/JeffJS issue #3, docs/EXECUTION_ARCHITECTURE_RETHINK.md §8.3).
//
// The sites React Natively targets spend their JS time in the same npm
// packages (Home Depot: ~85 % of its landing's script time is deepmerge).
// Minifiers rename identifiers but keep structure, so a function is
// recognised by its bytecode with every name a minifier picks left out
// (JeffJSBytecodeSerializer.nameFreeBytes): function names, closure variable
// names and where the enclosing module keeps them. What stays is the code,
// the property names it reads and the globals it uses.
//
// The table is built from reference sources (the libraries' own text as a
// site ships it), compiled by this engine on first use, so a compiler change
// can never leave stale hashes behind. Each reference is compiled lazily and
// eagerly (closure variable order can differ) and sloppy and strict.
//
// A twin replaces one *entry* function (deepmerge itself). Its other
// functions are *members*: the twin only runs when every closure cell the
// family reads still holds the family's own functions (checked per call, a
// page can reassign them) and the intrinsics they call are the context's
// own (JeffJSTwinIntrinsics). Inside, a twin may only do what the bytecode
// would do without running page code: any getter, setter, proxy or patched
// builtin on the way makes it *decline* before it has changed anything the
// page can see, and the bytecode runs instead. A declined call costs the
// work done so far, never a different result.
//
// Hook: a body tagged as an entry never gets `fbFast` on its closures
// (createClosure / callInternal's payload path ask `allowsFastPath`), so
// every call reaches callInternal's payload path, which calls `call` first.
//
// Switches: `JEFFJS_NATIVETWINS_ENABLED=0` (no lookup), per runtime
// `rt.nativeTwins` (tests), `JEFFJS_NATIVETWINS_DEBUG=1` (recognised bodies,
// declined calls and why, hit counts on stderr).

import Foundation

/// Counters of one runtime (`rt.twinStats`).
nonisolated struct JeffJSNativeTwinStats {
    /// Calls the twin answered.
    var hits = 0
    /// Calls the twin declined (the bytecode ran).
    var declines = 0
    /// Bodies recognised as a family member.
    var recognised = 0
}

/// A guard failed: run the bytecode instead. Thrown before the twin has
/// done anything the page can observe.
nonisolated struct JeffJSTwinDecline: Error {
    let reason: String
}

nonisolated enum JeffJSNativeTwins {

    // MARK: Families

    /// One library a twin replaces.
    struct Family {
        let name: String
        /// The library's functions as the reference text names them. Role 0
        /// is the entry (the function the twin replaces).
        let roles: [String]
        /// Closure variables of the members that are not functions but whose
        /// value the twin reads (e.g. deepmerge's React element marker).
        let values: [String]
        /// The reference text: the library's functions as one site ships
        /// them, declared at the top of a function body.
        let source: String
        /// Cheap argument test before the per-call guards (false: decline).
        let accepts: (JeffJSContext, UnsafePointer<JeffJSValue>?, Int) -> Bool
        /// The twin: nil = declined.
        let run: (JeffJSContext, Resolved, UnsafePointer<JeffJSValue>?, Int) throws -> JeffJSValue
    }

    /// Every family the engine knows.
    static let families: [Family] = [
        JeffJSTwinDeepmerge.family,
    ]

    /// A family whose cells were checked for one call: its function objects
    /// by role and its values (borrowed from the cells).
    struct Resolved {
        let family: Family
        var functions: [JeffJSObject?]
        var values: [JeffJSValue]
    }

    // MARK: The table

    enum Cell { case role(Int), value(Int), other }

    struct Member {
        let family: Int
        let role: Int
        /// What each closure variable of the body holds.
        let cells: [Cell]
    }

    nonisolated final class Table {
        /// (bytecode length, arguments, closure variables) of every member:
        /// a body that matches none is never hashed.
        var prefilter: Set<UInt64> = []
        var byHash: [UInt64: Int] = [:]
        /// Hashes two references disagree on (same bytes, different cells).
        var ambiguous: Set<UInt64> = []
        var members: [Member] = []
        /// Prefilter key of each member (generation only).
        var memberKeys: [Int: UInt64] = [:]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _table: Table? = nil

    @inline(__always)
    static func prefilterKey(_ fb: JeffJSFunctionBytecode) -> UInt64 {
        return (UInt64(UInt32(truncatingIfNeeded: fb.bytecodeLen)) << 32)
            | (UInt64(fb.argCount & 0xFFFF) << 16) | UInt64(fb.closureVarCount & 0xFFFF)
    }

    static func structuralHash(_ fb: JeffJSFunctionBytecode, rt: JeffJSRuntime) -> UInt64 {
        var x: UInt64 = 0xcbf29ce484222325
        for b in JeffJSBytecodeSerializer.nameFreeBytes(fb, rt: rt) { x = (x ^ UInt64(b)) &* 0x100000001b3 }
        return x
    }

    /// Compile `fb`'s body and every nested body (a stub hashes without its
    /// code). false: a compile failed (its exception is cleared).
    @discardableResult
    static func ensureCompiled(_ ctx: JeffJSContext, _ fb: JeffJSFunctionBytecode, depth: Int = 0) -> Bool {
        if depth > 16 { return false }
        if fb.isLazyPending, !JeffJSCompiler.compileLazy(ctx: ctx, fb) {
            ctx.getException().freeValue()
            return false
        }
        for v in fb.cpool {
            if let inner = v.toFunctionBytecode(), !ensureCompiled(ctx, inner, depth: depth + 1) { return false }
        }
        return true
    }

    /// The table the engine runs with: `JeffJSTwinTableData` (generated by
    /// `jeffjs-cli --twin-table` from the reference texts; no page runtime
    /// ever compiles a reference).
    static func table(_ ctx: JeffJSContext) -> Table {
        lock.lock(); defer { lock.unlock() }
        if let t = _table { return t }
        let t = Table()
        for e in JeffJSTwinTableData.entries {
            guard let fi = families.firstIndex(where: { $0.name == e.family }), t.members.count < 253 else { continue }
            let cells: [Cell] = e.cells.map { c in c < 0 ? .other : (c >= 1000 ? .value(Int(c) - 1000) : .role(Int(c))) }
            t.byHash[e.hash] = t.members.count
            t.members.append(Member(family: fi, role: e.role, cells: cells))
            t.prefilter.insert(e.prefilter)
        }
        _table = t
        if JeffJSConfig.nativeTwinsDebug { log("table: \(t.members.count) members") }
        return t
    }

    /// The table computed from the reference texts with this engine's
    /// compiler (lazy and eager, sloppy and strict), compiled in `ctx`.
    static func buildTable(_ ctx: JeffJSContext) -> (table: Table, hashes: [Int: UInt64], keys: [Int: UInt64]) {
        let t = Table()
        var hashes: [Int: UInt64] = [:], keys: [Int: UInt64] = [:]
        for (fi, family) in families.enumerated() {
            for strict in [false, true] {
                for lazy in [true, false] {
                    register(ctx, t, familyIndex: fi, family: family, strict: strict, lazy: lazy)
                }
            }
        }
        for (h, i) in t.byHash { hashes[i] = h }
        for (i, _) in t.members.enumerated() { keys[i] = t.memberKeys[i] }
        return (t, hashes, keys)
    }

    /// `JeffJSTwinTableData.swift` for the reference texts (jeffjs-cli --twin-table).
    static func tableSource(_ ctx: JeffJSContext) -> String {
        let (t, hashes, keys) = buildTable(ctx)
        var out = """
            // JeffJSTwinTableData.swift
            // JeffJS — GENERATED by `jeffjs-cli --twin-table` (do not edit): the native twin
            // table (JeffJSNativeTwins.swift), the reference texts' members as this compiler
            // compiles them. NativeTwinsConformance fails when it is stale: regenerate with
            //   swift run -c release jeffjs-cli --twin-table > Sources/JeffJS/Builtins/Twins/JeffJSTwinTableData.swift
            // Cells: role index, 1000 + value index, -1 other.

            nonisolated enum JeffJSTwinTableData {
                struct Entry {
                    let hash: UInt64
                    let prefilter: UInt64
                    let family: String
                    let role: Int
                    let cells: [Int16]
                }
                static let entries: [Entry] = [

            """
        for (i, m) in t.members.enumerated() {
            guard let h = hashes[i], let k = keys[i] else { continue }
            let fam = families[m.family]
            let cells = m.cells.map { c -> String in
                switch c { case .role(let r): return "\(r)"; case .value(let v): return "\(1000 + v)"; case .other: return "-1" }
            }.joined(separator: ", ")
            out += "        Entry(hash: 0x\(String(h, radix: 16)), prefilter: 0x\(String(k, radix: 16)), family: \"\(fam.name)\", role: \(m.role), cells: [\(cells)]),   // \(fam.roles[m.role])\n"
        }
        out += "    ]\n}\n"
        return out
    }

    private static func register(_ ctx: JeffJSContext, _ t: Table, familyIndex: Int, family: Family,
                                 strict: Bool, lazy: Bool) {
        let rt = ctx.rt
        let savedLazy = rt.lazyFunctions
        rt.lazyFunctions = lazy
        defer { rt.lazyFunctions = savedLazy }
        let text = "function __jeffjsTwinReference(){" + (strict ? "'use strict';" : "") + family.source + "}"
        guard let top = ctx.compileTwinReference(text) else {
            log("\(family.name): reference does not compile")
            return
        }
        defer { ctx.releaseUnrunProgram(top) }
        guard let wrapper = top.cpool.compactMap({ $0.toFunctionBytecode() }).first,
              ensureCompiled(ctx, wrapper) else {
            log("\(family.name): reference wrapper not found")
            return
        }
        // The members, by the names the reference gives them.
        var byName: [String: JeffJSFunctionBytecode] = [:]
        let utf8 = Array(text.utf8)
        for v in wrapper.cpool {
            guard let fb = v.toFunctionBytecode() else { continue }
            if let name = rt.atomToString(fb.nameAtom), !name.isEmpty {
                byName[name] = fb
            } else if let name = assignedName(utf8, before: Int(fb.sourceStart)) {
                byName[name] = fb   // `var X=function(…){…}`: named at run time
            }
        }
        for (role, name) in family.roles.enumerated() {
            guard let fb = byName[name] else {
                log("\(family.name): reference has no function \(name)")
                continue
            }
            let cells: [Cell] = fb.closureVarsList.map { cv in
                let n = rt.atomToString(cv.varName) ?? ""
                if let r = family.roles.firstIndex(of: n) { return .role(r) }
                if let v = family.values.firstIndex(of: n) { return .value(v) }
                return .other
            }
            let h = structuralHash(fb, rt: rt)
            if t.ambiguous.contains(h) { continue }
            if let existing = t.byHash[h] {
                let m = t.members[existing]
                if m.family != familyIndex || m.role != role || !sameCells(m.cells, cells) {
                    t.byHash[h] = nil
                    t.ambiguous.insert(h)
                }
                continue
            }
            guard t.members.count < 253 else { log("table full"); return }   // twinTag is one byte
            t.byHash[h] = t.members.count
            t.memberKeys[t.members.count] = prefilterKey(fb)
            t.members.append(Member(family: familyIndex, role: role, cells: cells))
            t.prefilter.insert(prefilterKey(fb))
        }
    }

    /// `X` in `…X=` right before `offset` of the reference text.
    private static func assignedName(_ text: [UInt8], before offset: Int) -> String? {
        var i = offset - 1
        guard i >= 0, i < text.count, text[i] == UInt8(ascii: "=") else { return nil }
        let end = i
        i -= 1
        func isIdent(_ c: UInt8) -> Bool {
            return (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                || c == UInt8(ascii: "_") || c == UInt8(ascii: "$")
        }
        while i >= 0, isIdent(text[i]) { i -= 1 }
        guard i + 1 < end else { return nil }
        return String(decoding: text[(i + 1)..<end], as: UTF8.self)
    }

    private static func sameCells(_ a: [Cell], _ b: [Cell]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            switch (x, y) {
            case (.role(let p), .role(let q)) where p == q: continue
            case (.value(let p), .value(let q)) where p == q: continue
            case (.other, .other): continue
            default: return false
            }
        }
        return true
    }

    // MARK: Classification

    /// May closures of `fb` take the interpreter's fast call paths? False
    /// only for the entry of a twin (its calls must reach `call`).
    @inline(__always)
    static func allowsFastPath(_ ctx: JeffJSContext, _ fb: JeffJSFunctionBytecode) -> Bool {
        let tag = fb.twinTag
        if tag == 1 { return true }
        return allowsFastPathSlow(ctx, fb, tag)
    }

    @inline(never)
    private static func allowsFastPathSlow(_ ctx: JeffJSContext, _ fb: JeffJSFunctionBytecode, _ tag0: UInt8) -> Bool {
        var tag = tag0
        if tag == 0 {
            if fb.isLazyPending { return true }   // classified once compiled
            tag = classify(ctx, fb)
        }
        guard tag >= 2 else { return true }
        let t = table(ctx)
        return t.members[Int(tag - 2)].role != 0
    }

    /// Look `fb` up (once) and record the answer in `twinTag`.
    @discardableResult
    static func classify(_ ctx: JeffJSContext, _ fb: JeffJSFunctionBytecode) -> UInt8 {
        if fb.twinTag != 0 { return fb.twinTag }
        guard JeffJSConfig.nativeTwins, !fb.isLazyPending else {
            if !fb.isLazyPending { fb.twinTag = 1 }
            return fb.twinTag
        }
        let t = table(ctx)
        guard t.prefilter.contains(prefilterKey(fb)), ensureCompiled(ctx, fb) else {
            fb.twinTag = 1
            return 1
        }
        let h = structuralHash(fb, rt: ctx.rt)
        if let i = t.byHash[h] {
            fb.twinTag = UInt8(i + 2)
            ctx.rt.twinStats.recognised += 1
            if JeffJSConfig.nativeTwinsDebug {
                let m = t.members[i], fam = families[m.family]
                log("recognised \(fam.name).\(fam.roles[m.role]) as \(ctx.rt.atomToString(fb.nameAtom) ?? "?")")
            }
        } else {
            fb.twinTag = 1
        }
        return fb.twinTag
    }

    // MARK: Calls

    /// The twin of the entry `fb` called as `obj(thisVal, argv…)`: the
    /// result (owned), or nil to run the bytecode.
    static func call(_ ctx: JeffJSContext, _ obj: JeffJSObject, _ fb: JeffJSFunctionBytecode,
                     _ varRefs: [JeffJSVarRef?], _ thisVal: JeffJSValue,
                     _ argv: UnsafePointer<JeffJSValue>?, _ argc: Int) -> JeffJSValue? {
        let rt = ctx.rt
        guard rt.nativeTwins, fb.twinTag >= 2 else { return nil }
        let t = table(ctx)
        let member = t.members[Int(fb.twinTag - 2)]
        guard member.role == 0 else { return nil }
        let family = families[member.family]
        guard family.accepts(ctx, argv, argc) else {
            rt.twinStats.declines += 1
            return nil
        }
        do {
            guard let intrinsics = ctx.twinIntrinsics else { throw JeffJSTwinDecline(reason: "no intrinsics") }
            try intrinsics.check(ctx)
            let resolved = try resolve(ctx, t, family: family, entry: obj, entryMember: member, varRefs: varRefs)
            let r = try family.run(ctx, resolved, argv, argc)
            rt.twinStats.hits += 1
            if JeffJSConfig.nativeTwinsDebug, rt.twinStats.hits & (rt.twinStats.hits - 1) == 0 {
                log("\(family.name): \(rt.twinStats.hits) calls served, \(rt.twinStats.declines) declined")
            }
            return r
        } catch let d as JeffJSTwinDecline {
            // A guard failed before anything the page can see changed. Drop
            // an exception an engine call may have left pending.
            if !rt.currentException.isNull { ctx.getException().freeValue() }
            rt.twinStats.declines += 1
            if JeffJSConfig.nativeTwinsDebug { log("\(family.name): declined (\(d.reason))") }
            return nil
        } catch {
            return nil
        }
    }

    /// Walk the family from its entry: every closure cell that names a
    /// member must hold a function whose body is that member (recognised by
    /// hash), one object per role; values are read from their cells.
    private static func resolve(_ ctx: JeffJSContext, _ t: Table, family: Family, entry: JeffJSObject,
                                entryMember: Member, varRefs: [JeffJSVarRef?]) throws -> Resolved {
        var r = Resolved(family: family, functions: Array(repeating: nil, count: family.roles.count),
                         values: Array(repeating: .undefined, count: family.values.count))
        var valueSeen = Array(repeating: false, count: family.values.count)
        r.functions[0] = entry
        var queue: [(JeffJSObject, Member, [JeffJSVarRef?])] = [(entry, entryMember, varRefs)]
        while let (obj, member, refs) = queue.popLast() {
            guard obj.realmIndex == ctx.realmIndex else { throw JeffJSTwinDecline(reason: "other realm") }
            for (i, cell) in member.cells.enumerated() {
                if case .other = cell { continue }
                guard i < refs.count, let ref = refs[i] else { throw JeffJSTwinDecline(reason: "cell missing") }
                let v = ref.pvalue
                if v.isUninitialized { throw JeffJSTwinDecline(reason: "cell in TDZ") }
                switch cell {
                case .value(let k):
                    if valueSeen[k] {
                        guard v.bits == r.values[k].bits else { throw JeffJSTwinDecline(reason: "value differs") }
                    } else {
                        r.values[k] = v
                        valueSeen[k] = true
                    }
                case .role(let role):
                    guard let fo = v.toObject() else { throw JeffJSTwinDecline(reason: "\(family.roles[role]) replaced") }
                    if let known = r.functions[role] {
                        guard known === fo else { throw JeffJSTwinDecline(reason: "\(family.roles[role]) is two objects") }
                        continue
                    }
                    guard case .bytecodeFunc(let fbOpt, let vr, _) = fo.payload, let fb = fbOpt else {
                        throw JeffJSTwinDecline(reason: "\(family.roles[role]) is not bytecode")
                    }
                    // A member never called yet is still a stub: compile it to know.
                    if fb.twinTag == 0, fb.isLazyPending, !ensureCompiled(ctx, fb) {
                        throw JeffJSTwinDecline(reason: "\(family.roles[role]) does not compile")
                    }
                    let tag = classify(ctx, fb)
                    guard tag >= 2 else { throw JeffJSTwinDecline(reason: "\(family.roles[role]) is other code") }
                    let m = t.members[Int(tag - 2)]
                    guard families[m.family].name == family.name, m.role == role else {
                        throw JeffJSTwinDecline(reason: "\(family.roles[role]) is another member")
                    }
                    r.functions[role] = fo
                    queue.append((fo, m, vr.isEmpty ? fo.varRefsFast : vr))
                case .other:
                    break
                }
            }
        }
        for k in 0..<valueSeen.count where !valueSeen[k] {
            throw JeffJSTwinDecline(reason: "value \(family.values[k]) not reached")
        }
        return r
    }

    static func log(_ s: String) {
        FileHandle.standardError.write(("[jeffjs:twins] " + s + "\n").data(using: .utf8)!)
    }
}

// MARK: - Intrinsics a twin relies on

/// The builtins the replaced code calls, captured when the context's
/// intrinsics are built (before any page script). A twin runs only while the
/// page still reaches exactly these through the same lookups the bytecode
/// does (`check`).
nonisolated final class JeffJSTwinIntrinsics {
    weak var objectCtor: JeffJSObject?
    weak var objectProto: JeffJSObject?
    weak var functionProto: JeffJSObject?
    weak var arrayCtor: JeffJSObject?
    weak var arrayProto: JeffJSObject?
    weak var keys: JeffJSObject?
    weak var getOwnPropertySymbols: JeffJSObject?
    weak var toString: JeffJSObject?
    weak var hasOwnProperty: JeffJSObject?
    weak var propertyIsEnumerable: JeffJSObject?
    weak var call: JeffJSObject?
    weak var isArray: JeffJSObject?
    weak var concat: JeffJSObject?
    weak var map: JeffJSObject?
    weak var forEach: JeffJSObject?
    weak var filter: JeffJSObject?
    weak var speciesGetter: JeffJSObject?
    weak var protoGetter: JeffJSObject?
    weak var protoSetter: JeffJSObject?
    let atomObject: UInt32
    let atomArray: UInt32
    let atomToString: UInt32
    let atomConstructor: UInt32

    private init?(_ ctx: JeffJSContext) {
        func own(_ o: JeffJSObject?, _ atom: UInt32) -> JeffJSObject? {
            guard let o else { return nil }
            let idx = jeffJS_findOwnPropertyIndex(obj: o, atom: atom)
            guard idx >= 0, let shape = o.shape, idx < o.propCount, shape.prop[idx].flags.isPlainData,
                  o.extra(at: idx) == nil else { return nil }
            return o.dataValue(at: idx).toObject()
        }
        func getter(_ o: JeffJSObject?, _ atom: UInt32) -> (JeffJSObject?, JeffJSObject?)? {
            guard let o else { return nil }
            let idx = jeffJS_findOwnPropertyIndex(obj: o, atom: atom)
            guard idx >= 0, let prop = ctx.getOwnProperty(obj: .borrowedObject(o), atom: atom),
                  case .getset(let g, let s) = prop else { return nil }
            return (g, s)
        }
        // Predefined atoms (immortal: nothing to free).
        atomObject = JSPredefinedAtom.Object.rawValue
        atomArray = JSPredefinedAtom.Array_.rawValue
        atomToString = JSPredefinedAtom.toStringAtom.rawValue
        atomConstructor = JSPredefinedAtom.constructor_.rawValue
        guard let g = ctx.globalObj.toObject(),
              let oc = own(g, atomObject), let ac = own(g, atomArray),
              let op = ctx.classProto[JSClassID.JS_CLASS_OBJECT.rawValue].toObject(),
              let fp = ctx.functionProto.toObject(),
              let ap = ctx.classProto[JSClassID.JS_CLASS_ARRAY.rawValue].toObject(),
              let k = own(oc, JSAtomID.keys), let gops = own(oc, JSAtomID.getOwnPropertySymbols),
              let ts = own(op, atomToString), let hop = own(op, JSAtomID.hasOwnProperty),
              let pie = own(op, JSAtomID.propertyIsEnumerable), let cl = own(fp, JSAtomID.call),
              let ia = own(ac, JSAtomID.isArray), let cc = own(ap, JSAtomID.concat),
              let mp = own(ap, JSAtomID.map), let fe = own(ap, JSAtomID.forEach), let fl = own(ap, JSAtomID.filter),
              let sp = getter(ac, JSAtomID.Symbol_species)?.0 else { return nil }
        objectCtor = oc; objectProto = op; functionProto = fp; arrayCtor = ac; arrayProto = ap
        keys = k; getOwnPropertySymbols = gops; toString = ts; hasOwnProperty = hop
        propertyIsEnumerable = pie; call = cl; isArray = ia; concat = cc; map = mp; forEach = fe
        filter = fl; speciesGetter = sp
        let pg = getter(op, JSAtomID.__proto__)
        protoGetter = pg?.0
        protoSetter = pg?.1
    }

    static func capture(_ ctx: JeffJSContext) -> JeffJSTwinIntrinsics? {
        let r = JeffJSTwinIntrinsics(ctx)
        if r == nil, JeffJSConfig.nativeTwinsDebug { JeffJSNativeTwins.log("intrinsics not captured") }
        return r
    }

    /// The own plain data property `atom` of `o` (borrowed), nil if absent;
    /// throws if it is an accessor or exotic.
    @inline(__always)
    static func ownData(_ o: JeffJSObject, _ atom: UInt32) throws -> JeffJSValue? {
        let idx = jeffJS_findOwnPropertyIndex(obj: o, atom: atom)
        if idx < 0 { return nil }
        guard let shape = o.shape, idx < o.propCount, shape.prop[idx].flags.isPlainData,
              o.extra(at: idx) == nil else { throw JeffJSTwinDecline(reason: "accessor") }
        return o.dataValue(at: idx)
    }

    private static func expect(_ o: JeffJSObject, _ atom: UInt32, _ fn: JeffJSObject, _ what: String) throws {
        guard let v = try ownData(o, atom), v.toObject() === fn else {
            throw JeffJSTwinDecline(reason: "\(what) patched")
        }
    }

    private static func expectAbsent(_ o: JeffJSObject, _ atom: UInt32, _ what: String) throws {
        if jeffJS_findOwnPropertyIndex(obj: o, atom: atom) >= 0 { throw JeffJSTwinDecline(reason: "\(what) shadowed") }
    }

    /// The lookups the replaced code makes still reach the intrinsics, and
    /// [[Set]] on a fresh object can run no page code.
    func check(_ ctx: JeffJSContext) throws {
        // Held weakly (identity only): a freed one never matches again.
        guard let objectCtor, let objectProto, let functionProto, let arrayCtor, let arrayProto, let keys,
              let getOwnPropertySymbols, let toString, let hasOwnProperty, let propertyIsEnumerable, let call,
              let isArray, let concat, let map, let forEach, let filter, let speciesGetter
        else { throw JeffJSTwinDecline(reason: "intrinsics gone") }
        // Global `Object` / `Array`: no script-level let/const shadows them
        // and the global object holds the intrinsics as data properties.
        if ctx.globalLexCount > 0,
           ctx.globalLexIndex(atomObject) >= 0 || ctx.globalLexIndex(atomArray) >= 0 {
            throw JeffJSTwinDecline(reason: "global lexical Object/Array")
        }
        guard let g = ctx.globalObj.toObject() else { throw JeffJSTwinDecline(reason: "no global") }
        try Self.expect(g, atomObject, objectCtor, "Object")
        try Self.expect(g, atomArray, arrayCtor, "Array")
        // Object.keys / getOwnPropertySymbols / prototype, Array.isArray.
        try Self.expect(objectCtor, JSAtomID.keys, keys, "Object.keys")
        try Self.expect(objectCtor, JSAtomID.getOwnPropertySymbols, getOwnPropertySymbols, "Object.getOwnPropertySymbols")
        try Self.expect(objectCtor, JSAtomID.prototype, objectProto, "Object.prototype")
        try Self.expect(arrayCtor, JSAtomID.isArray, isArray, "Array.isArray")
        // Object.hasOwnProperty / Object.propertyIsEnumerable resolve through
        // Object → Function.prototype → Object.prototype.
        guard objectCtor.proto === functionProto, functionProto.proto === objectProto,
              objectProto.proto == nil else { throw JeffJSTwinDecline(reason: "prototype chain changed") }
        for o in [objectCtor, functionProto] {
            try Self.expectAbsent(o, JSAtomID.hasOwnProperty, "hasOwnProperty")
            try Self.expectAbsent(o, JSAtomID.propertyIsEnumerable, "propertyIsEnumerable")
        }
        try Self.expect(objectProto, atomToString, toString, "Object.prototype.toString")
        try Self.expect(objectProto, JSAtomID.hasOwnProperty, hasOwnProperty, "Object.prototype.hasOwnProperty")
        try Self.expect(objectProto, JSAtomID.propertyIsEnumerable, propertyIsEnumerable, "Object.prototype.propertyIsEnumerable")
        // `.call` on those three.
        for f in [toString, hasOwnProperty, propertyIsEnumerable] {
            guard f.proto === functionProto else { throw JeffJSTwinDecline(reason: "builtin prototype changed") }
            try Self.expectAbsent(f, JSAtomID.call, "call")
        }
        try Self.expect(functionProto, JSAtomID.call, call, "Function.prototype.call")
        // Arrays: concat / map / forEach / filter, species, spreading.
        guard arrayProto.proto === objectProto, arrayCtor.proto === functionProto else {
            throw JeffJSTwinDecline(reason: "array prototype chain changed")
        }
        try Self.expect(arrayProto, JSAtomID.concat, concat, "Array.prototype.concat")
        try Self.expect(arrayProto, JSAtomID.map, map, "Array.prototype.map")
        try Self.expect(arrayProto, JSAtomID.forEach, forEach, "Array.prototype.forEach")
        try Self.expect(arrayProto, JSAtomID.filter, filter, "Array.prototype.filter")
        try Self.expect(arrayProto, atomConstructor, arrayCtor, "Array.prototype.constructor")
        guard let sp = ctx.getOwnProperty(obj: .borrowedObject(arrayCtor), atom: JSAtomID.Symbol_species),
              case .getset(let sg, _) = sp, sg === speciesGetter else {
            throw JeffJSTwinDecline(reason: "Array[@@species] patched")
        }
        try Self.expectAbsent(arrayProto, JSAtomID.Symbol_isConcatSpreadable, "@@isConcatSpreadable")
        try Self.expectAbsent(objectProto, JSAtomID.Symbol_isConcatSpreadable, "@@isConcatSpreadable")
        // [[Set]] on a fresh {}: Object.prototype has only writable data
        // properties (a setter would run page code, a read-only one would
        // fail the write) and the intrinsic __proto__ accessor.
        guard let shape = objectProto.shape else { throw JeffJSTwinDecline(reason: "Object.prototype shape") }
        let n = min(shape.prop.count, objectProto.propCount)
        for i in 0..<n {
            let p = shape.prop[i]
            if p.atom == 0 { continue }
            if p.flags.isPlainData, objectProto.extra(at: i) == nil {
                if !p.flags.contains(.writable) { throw JeffJSTwinDecline(reason: "read-only Object.prototype member") }
                continue
            }
            if p.atom == JSAtomID.__proto__,
               let prop = ctx.getOwnProperty(obj: .borrowedObject(objectProto), atom: p.atom),
               case .getset(let pg, let ps) = prop, pg === protoGetter, ps === protoSetter { continue }
            throw JeffJSTwinDecline(reason: "Object.prototype accessor")
        }
    }
}

// MARK: - Reference compilation

nonisolated extension JeffJSContext {
    /// Parse and compile `input` as a global script without running it (the
    /// twin table's reference texts). Lazily compiled bodies follow
    /// `rt.lazyFunctions`, as for page scripts.
    func compileTwinReference(_ input: String) -> JeffJSFunctionBytecode? {
        let filename = "<jeffjs-twin-reference>"
        let parseState = JeffJSParseState(source: input, filename: filename, ctx: self)
        let fd = JeffJSFunctionDefCompiler()
        fd.filename = rt.findAtom(filename)
        fd.source = input
        fd.sourceText = JeffJSSourceText(span: parseState.buf)
        fd.sourceStart = 0
        fd.sourceEnd = parseState.buf.count
        fd.lazyScript = JeffJSLazyScript(source: fd.sourceText!, filename: filename, isModule: false)
        let parser = JeffJSParser(s: parseState, fd: fd)
        parser.parseProgram()
        if parser.failed || fd.byteCode.error {
            if !rt.currentException.isNull { getException().freeValue() }
            return nil
        }
        guard let fb = JeffJSCompiler.createFunction(ctx: self, fd: fd) else {
            if !rt.currentException.isNull { getException().freeValue() }
            return nil
        }
        return fb
    }
}
