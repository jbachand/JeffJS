// Microbenchmark: how much does the *dispatch mechanism* cost in Swift?
// Same tiny language, same NaN-boxed values, same programs, five executors:
//   A. bytecode + switch loop (what JeffJS does today)
//   B. closure tree (each AST node compiled to a Swift closure; calls through a
//      dynamic name→closure map = "script as a class with dynamic method map")
//   B2. closure tree, call target resolved once (cached slot)
//   C. class-node AST interpreter (virtual exec), with a self-specialising add
//   D. threaded code (array of handler closures, no switch)
//   E. plain Swift (the floor)
// Programs: fib(27) recursive calls; a 20M-iteration arithmetic loop.
// Build: swiftc -O -wmo dispatch_bench.swift -o dispatch_bench
import Foundation

// MARK: - Values (NaN-boxed like JeffJSValue; ints + doubles only)
struct V {
    var bits: UInt64
    static let intTag: UInt64 = 0x7FF9_0000_0000_0000
    static let tagMask: UInt64 = 0xFFFF_0000_0000_0000
    @inline(__always) static func int(_ i: Int32) -> V { V(bits: intTag | UInt64(UInt32(bitPattern: i))) }
    @inline(__always) static func dbl(_ d: Double) -> V { V(bits: d.bitPattern) }
    @inline(__always) var isInt: Bool { bits & V.tagMask == V.intTag }
    @inline(__always) var i32: Int32 { Int32(bitPattern: UInt32(truncatingIfNeeded: bits)) }
    @inline(__always) var dbl: Double { isInt ? Double(i32) : Double(bitPattern: bits) }
}
@inline(__always) func vadd(_ a: V, _ b: V) -> V {
    if a.isInt && b.isInt { let (r, o) = a.i32.addingReportingOverflow(b.i32); if !o { return .int(r) } }
    return .dbl(a.dbl + b.dbl)
}
@inline(__always) func vsub(_ a: V, _ b: V) -> V {
    if a.isInt && b.isInt { let (r, o) = a.i32.subtractingReportingOverflow(b.i32); if !o { return .int(r) } }
    return .dbl(a.dbl - b.dbl)
}
@inline(__always) func vmul(_ a: V, _ b: V) -> V {
    if a.isInt && b.isInt { let (r, o) = a.i32.multipliedReportingOverflow(by: b.i32); if !o { return .int(r) } }
    return .dbl(a.dbl * b.dbl)
}
@inline(__always) func vlt(_ a: V, _ b: V) -> Bool {
    if a.isInt && b.isInt { return a.i32 < b.i32 }
    return a.dbl < b.dbl
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
func best(_ n: Int, _ f: () -> V) -> (Double, V) {
    var bestT = Double.infinity; var r = V(bits: 0)
    for _ in 0..<n { let t = now(); r = f(); bestT = min(bestT, now() - t) }
    return (bestT, r)
}

// MARK: - A. Bytecode stack VM --------------------------------------------
// ops: 0 const8 k | 1 getloc i | 2 setloc i (pops) | 3 add | 4 sub | 5 mul | 6 lt
//      7 jmpifnot off16 | 8 jmp off16 | 9 call fn argc | 10 ret | 11 dup | 12 drop
struct BCFunction { var code: [UInt8]; var nlocals: Int; var nargs: Int }
final class BCVM {
    var fns: [BCFunction] = []
    let stack: UnsafeMutablePointer<V>
    init() { stack = .allocate(capacity: 1 << 20) }
    // frame layout: [args/locals][operand stack]
    func run(_ fi: Int, _ base: UnsafeMutablePointer<V>) -> V {
        let f = fns[fi]
        return f.code.withUnsafeBufferPointer { cb -> V in
            let code = cb.baseAddress!
            var pc = 0
            var sp = base + f.nlocals
            while true {
                let op = code[pc]
                switch op {
                case 0: sp.pointee = .int(Int32(Int8(bitPattern: code[pc + 1]))); sp += 1; pc += 2
                case 1: sp.pointee = base[Int(code[pc + 1])]; sp += 1; pc += 2
                case 2: sp -= 1; base[Int(code[pc + 1])] = sp.pointee; pc += 2
                case 3: sp -= 1; (sp - 1).pointee = vadd((sp - 1).pointee, sp.pointee); pc += 1
                case 4: sp -= 1; (sp - 1).pointee = vsub((sp - 1).pointee, sp.pointee); pc += 1
                case 5: sp -= 1; (sp - 1).pointee = vmul((sp - 1).pointee, sp.pointee); pc += 1
                case 6: sp -= 1; (sp - 1).pointee = .int(vlt((sp - 1).pointee, sp.pointee) ? 1 : 0); pc += 1
                case 7:
                    sp -= 1
                    let off = Int(Int16(bitPattern: UInt16(code[pc + 1]) | UInt16(code[pc + 2]) << 8))
                    pc = sp.pointee.i32 == 0 ? pc + 3 + off : pc + 3
                case 8:
                    let off = Int(Int16(bitPattern: UInt16(code[pc + 1]) | UInt16(code[pc + 2]) << 8))
                    pc += 3 + off
                case 9:
                    let callee = Int(code[pc + 1]); let argc = Int(code[pc + 2])
                    let newBase = sp - argc           // args already in place = callee's first locals
                    let r = run(callee, newBase)
                    sp = newBase; sp.pointee = r; sp += 1; pc += 3
                case 10: sp -= 1; return sp.pointee
                case 11: sp.pointee = (sp - 1).pointee; sp += 1; pc += 1
                default: sp -= 1; pc += 1
                }
            }
        }
    }
}
func i16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)] }
// fib(n): if (n < 2) return n; return fib(n-1) + fib(n-2)
let bcFib = BCFunction(code:
    [1, 0, 0, 2, 6, 7] + i16(3) +          // n < 2 ? -> if false jump over "ret n"
    [1, 0, 10] +                           // return n
    [1, 0, 0, 1, 4, 9, 0, 1,               // fib(n-1)
     1, 0, 0, 2, 4, 9, 0, 1,               // fib(n-2)
     3, 10], nlocals: 1, nargs: 1)
// loop(n): s=0; i=0; while (i<n) { s = s + i*2 - 1; i = i + 1 } return s
let bcLoop = BCFunction(code:
    [0, 0, 2, 1, 0, 0, 2, 2] +                         // s=0 (loc1), i=0 (loc2)
    /* L: */ [1, 2, 1, 0, 6, 7] + i16(23) +           // while i<n
    [1, 1, 1, 2, 0, 2, 5, 3, 0, 1, 4, 2, 1,          // s = s + i*2 - 1
     1, 2, 0, 1, 3, 2, 2,                            // i = i + 1
     8] + i16(-31) +                                  // jmp L
    [1, 1, 10], nlocals: 3, nargs: 1)

// MARK: - B. Closure tree ----------------------------------------------------
typealias Frame = UnsafeMutablePointer<V>
typealias Expr = (Frame) -> V
typealias Stmt = (Frame) -> Void
final class ClosureFn { var body: Expr = { _ in V(bits: 0) }; let nlocals: Int; init(nlocals: Int) { self.nlocals = nlocals } }
final class ClosureWorld {
    var methods: [String: ClosureFn] = [:]        // the "dynamic method map"
    let stack: Frame = .allocate(capacity: 1 << 20)
}
func cConst(_ i: Int32) -> Expr { let v = V.int(i); return { _ in v } }
func cLoc(_ i: Int) -> Expr { { f in f[i] } }
func cAdd(_ a: @escaping Expr, _ b: @escaping Expr) -> Expr { { f in vadd(a(f), b(f)) } }
func cSub(_ a: @escaping Expr, _ b: @escaping Expr) -> Expr { { f in vsub(a(f), b(f)) } }
func cMul(_ a: @escaping Expr, _ b: @escaping Expr) -> Expr { { f in vmul(a(f), b(f)) } }
func cLt(_ a: @escaping Expr, _ b: @escaping Expr) -> Expr { { f in .int(vlt(a(f), b(f)) ? 1 : 0) } }
func cIf(_ c: @escaping Expr, _ t: @escaping Expr, _ e: @escaping Expr) -> Expr { { f in c(f).i32 != 0 ? t(f) : e(f) } }
func cSet(_ i: Int, _ e: @escaping Expr) -> Stmt { { f in f[i] = e(f) } }
func cWhile(_ c: @escaping Expr, _ body: [Stmt]) -> Stmt { { f in while c(f).i32 != 0 { for s in body { s(f) } } } }
func cBlock(_ ss: [Stmt], _ ret: @escaping Expr) -> Expr { { f in for s in ss { s(f) }; return ret(f) } }
// dynamic call: look the method up by name on every call
func cCallDyn(_ w: ClosureWorld, _ name: String, _ args: [Expr], _ frameSize: Int) -> Expr {
    return { f in
        let callee = w.methods[name]!
        let nf = f + frameSize
        for (i, a) in args.enumerated() { nf[i] = a(f) }
        return callee.body(nf)
    }
}
// cached call: target resolved at link time (what a real implementation would do)
func cCall(_ callee: ClosureFn, _ args: [Expr], _ frameSize: Int) -> Expr {
    let a0 = args[0]
    return { f in
        let nf = f + frameSize
        nf[0] = a0(f)
        return callee.body(nf)
    }
}
func buildClosureFib(_ w: ClosureWorld, dynamic: Bool) -> ClosureFn {
    let fn = ClosureFn(nlocals: 1); w.methods["fib"] = fn
    let call: ([Expr]) -> Expr = dynamic ? { cCallDyn(w, "fib", $0, 1) } : { cCall(fn, $0, 1) }
    fn.body = cIf(cLt(cLoc(0), cConst(2)), cLoc(0),
                  cAdd(call([cSub(cLoc(0), cConst(1))]), call([cSub(cLoc(0), cConst(2))])))
    return fn
}
func buildClosureLoop() -> ClosureFn {
    let fn = ClosureFn(nlocals: 3)
    fn.body = cBlock([cSet(1, cConst(0)), cSet(2, cConst(0)),
                      cWhile(cLt(cLoc(2), cLoc(0)), [
                        cSet(1, cSub(cAdd(cLoc(1), cMul(cLoc(2), cConst(2))), cConst(1))),
                        cSet(2, cAdd(cLoc(2), cConst(1)))])],
                     cLoc(1))
    return fn
}

// MARK: - C. Class-node AST (virtual dispatch), self-specialising add ---------
class Node { func exec(_ f: Frame) -> V { fatalError() } }
final class NConst: Node { let v: V; init(_ i: Int32) { v = .int(i) }; override func exec(_ f: Frame) -> V { v } }
final class NLoc: Node { let i: Int; init(_ i: Int) { self.i = i }; override func exec(_ f: Frame) -> V { f[i] } }
final class NBin: Node {
    let a: Node, b: Node, op: UInt8
    init(_ op: UInt8, _ a: Node, _ b: Node) { self.op = op; self.a = a; self.b = b }
    override func exec(_ f: Frame) -> V {
        let x = a.exec(f), y = b.exec(f)
        switch op { case 0: return vadd(x, y); case 1: return vsub(x, y); case 2: return vmul(x, y); default: return .int(vlt(x, y) ? 1 : 0) }
    }
}
// "Truffle-style" node that has observed ints and specialised: no op switch, int fast path first, deopt flag.
final class NAddInt: Node {
    let a: Node, b: Node
    init(_ a: Node, _ b: Node) { self.a = a; self.b = b }
    override func exec(_ f: Frame) -> V {
        let x = a.exec(f), y = b.exec(f)
        if x.isInt && y.isInt { let (r, o) = x.i32.addingReportingOverflow(y.i32); if !o { return .int(r) } }
        return .dbl(x.dbl + y.dbl)   // (would rewrite itself to a generic node)
    }
}
final class NIf: Node {
    let c: Node, t: Node, e: Node
    init(_ c: Node, _ t: Node, _ e: Node) { self.c = c; self.t = t; self.e = e }
    override func exec(_ f: Frame) -> V { c.exec(f).i32 != 0 ? t.exec(f) : e.exec(f) }
}
final class NSet: Node { let i: Int, e: Node; init(_ i: Int, _ e: Node) { self.i = i; self.e = e }; override func exec(_ f: Frame) -> V { f[i] = e.exec(f); return V(bits: 0) } }
final class NWhile: Node {
    let c: Node, body: [Node]
    init(_ c: Node, _ body: [Node]) { self.c = c; self.body = body }
    override func exec(_ f: Frame) -> V { while c.exec(f).i32 != 0 { for s in body { _ = s.exec(f) } }; return V(bits: 0) }
}
final class NBlock: Node { let ss: [Node], r: Node; init(_ ss: [Node], _ r: Node) { self.ss = ss; self.r = r }; override func exec(_ f: Frame) -> V { for s in ss { _ = s.exec(f) }; return r.exec(f) } }
final class NFunc { var body: Node = NConst(0); let frameSize: Int; init(_ n: Int) { frameSize = n } }
final class NCall: Node {
    let fn: NFunc, a0: Node
    init(_ fn: NFunc, _ a0: Node) { self.fn = fn; self.a0 = a0 }
    override func exec(_ f: Frame) -> V { let nf = f + fn.frameSize; nf[0] = a0.exec(f); return fn.body.exec(nf) }
}
func buildNodeFib() -> NFunc {
    let fn = NFunc(1)
    fn.body = NIf(NBin(3, NLoc(0), NConst(2)), NLoc(0),
                  NAddInt(NCall(fn, NBin(1, NLoc(0), NConst(1))), NCall(fn, NBin(1, NLoc(0), NConst(2)))))
    return fn
}
func buildNodeLoop() -> NFunc {
    let fn = NFunc(3)
    fn.body = NBlock([NSet(1, NConst(0)), NSet(2, NConst(0)),
                      NWhile(NBin(3, NLoc(2), NLoc(0)), [
                        NSet(1, NBin(1, NAddInt(NLoc(1), NBin(2, NLoc(2), NConst(2))), NConst(1))),
                        NSet(2, NAddInt(NLoc(2), NConst(1)))])], NLoc(1))
    return fn
}

// MARK: - D. Threaded code (handler table, no switch) --------------------------
struct TMachine { var sp: Frame; var base: Frame; var pc: Int; var ret: V; var done: Bool }
struct TInstr { let h: (inout TMachine, Int) -> Void; let a: Int }
final class TFunction { var code: [TInstr] = []; let nlocals: Int; init(_ n: Int) { nlocals = n } }
var tFns: [TFunction] = []
func tRun(_ f: TFunction, _ base: Frame) -> V {
    var m = TMachine(sp: base + f.nlocals, base: base, pc: 0, ret: V(bits: 0), done: false)
    let code = f.code
    while !m.done {
        let ins = code[m.pc]
        m.pc += 1
        ins.h(&m, ins.a)
    }
    return m.ret
}
let tConst: (inout TMachine, Int) -> Void = { m, a in m.sp.pointee = .int(Int32(a)); m.sp += 1 }
let tLoc: (inout TMachine, Int) -> Void = { m, a in m.sp.pointee = m.base[a]; m.sp += 1 }
let tSet: (inout TMachine, Int) -> Void = { m, a in m.sp -= 1; m.base[a] = m.sp.pointee }
let tAdd: (inout TMachine, Int) -> Void = { m, _ in m.sp -= 1; (m.sp - 1).pointee = vadd((m.sp - 1).pointee, m.sp.pointee) }
let tSub: (inout TMachine, Int) -> Void = { m, _ in m.sp -= 1; (m.sp - 1).pointee = vsub((m.sp - 1).pointee, m.sp.pointee) }
let tMul: (inout TMachine, Int) -> Void = { m, _ in m.sp -= 1; (m.sp - 1).pointee = vmul((m.sp - 1).pointee, m.sp.pointee) }
let tLt: (inout TMachine, Int) -> Void = { m, _ in m.sp -= 1; (m.sp - 1).pointee = .int(vlt((m.sp - 1).pointee, m.sp.pointee) ? 1 : 0) }
let tJmpIfNot: (inout TMachine, Int) -> Void = { m, a in m.sp -= 1; if m.sp.pointee.i32 == 0 { m.pc = a } }
let tJmp: (inout TMachine, Int) -> Void = { m, a in m.pc = a }
let tCall: (inout TMachine, Int) -> Void = { m, a in
    let nb = m.sp - 1; let r = tRun(tFns[a], nb); m.sp = nb; m.sp.pointee = r; m.sp += 1 }
let tRet: (inout TMachine, Int) -> Void = { m, _ in m.sp -= 1; m.ret = m.sp.pointee; m.done = true }
func buildThreaded() {
    let fib = TFunction(1)
    fib.code = [TInstr(h: tLoc, a: 0), TInstr(h: tConst, a: 2), TInstr(h: tLt, a: 0), TInstr(h: tJmpIfNot, a: 5),
                TInstr(h: tLoc, a: 0), TInstr(h: tRet, a: 0),  // idx 4 is unreachable filler? no: fix below
    ]
    // index: 0 loc,1 const,2 lt,3 jmpifnot->5? we want: if !(n<2) jump to 6. Rebuild explicitly:
    fib.code = [
        TInstr(h: tLoc, a: 0), TInstr(h: tConst, a: 2), TInstr(h: tLt, a: 0), TInstr(h: tJmpIfNot, a: 6),   // 0-3
        TInstr(h: tLoc, a: 0), TInstr(h: tRet, a: 0),                                                     // 4-5
        TInstr(h: tLoc, a: 0), TInstr(h: tConst, a: 1), TInstr(h: tSub, a: 0), TInstr(h: tCall, a: 0),     // 6-9
        TInstr(h: tLoc, a: 0), TInstr(h: tConst, a: 2), TInstr(h: tSub, a: 0), TInstr(h: tCall, a: 0),     // 10-13
        TInstr(h: tAdd, a: 0), TInstr(h: tRet, a: 0)]
    let loop = TFunction(3)
    loop.code = [
        TInstr(h: tConst, a: 0), TInstr(h: tSet, a: 1), TInstr(h: tConst, a: 0), TInstr(h: tSet, a: 2),   // 0-3
        TInstr(h: tLoc, a: 2), TInstr(h: tLoc, a: 0), TInstr(h: tLt, a: 0), TInstr(h: tJmpIfNot, a: 22),   // 4-7
        TInstr(h: tLoc, a: 1), TInstr(h: tLoc, a: 2), TInstr(h: tConst, a: 2), TInstr(h: tMul, a: 0),      // 8-11
        TInstr(h: tAdd, a: 0), TInstr(h: tConst, a: 1), TInstr(h: tSub, a: 0), TInstr(h: tSet, a: 1),      // 12-15
        TInstr(h: tLoc, a: 2), TInstr(h: tConst, a: 1), TInstr(h: tAdd, a: 0), TInstr(h: tSet, a: 2),      // 16-19
        TInstr(h: tJmp, a: 4), TInstr(h: tJmp, a: 4),                                                      // 20-21
        TInstr(h: tLoc, a: 1), TInstr(h: tRet, a: 0)]                                                      // 22-23
    tFns = [fib, loop]
}

// MARK: - E. Native Swift --------------------------------------------------------
@inline(never) func nativeFib(_ n: V) -> V {
    if vlt(n, .int(2)) { return n }
    return vadd(nativeFib(vsub(n, .int(1))), nativeFib(vsub(n, .int(2))))
}
@inline(never) func nativeLoop(_ n: V) -> V {
    var s = V.int(0), i = V.int(0)
    while vlt(i, n) { s = vsub(vadd(s, vmul(i, .int(2))), .int(1)); i = vadd(i, .int(1)) }
    return s
}

// MARK: - Run ------------------------------------------------------------------------
let FIBN: Int32 = 27, LOOPN: Int32 = 20_000_000
let fibCalls = 832_039.0  // calls made by fib(27)  (2*fib(28)-1)
let reps = 5
var rows: [(String, Double, Double)] = []
func report(_ name: String, _ tf: Double, _ tl: Double) { rows.append((name, tf / fibCalls * 1e9, tl / Double(LOOPN) * 1e9)) }

do { // A
    let vm = BCVM(); vm.fns = [bcFib, bcLoop]
    let (tf, rf) = best(reps) { vm.stack[0] = .int(FIBN); return vm.run(0, vm.stack) }
    let (tl, rl) = best(reps) { vm.stack[0] = .int(LOOPN); return vm.run(1, vm.stack) }
    precondition(rf.i32 == 196418 && rl.dbl == 399999960000000.0, "A wrong \(rf.i32) \(rl.dbl)")
    report("A bytecode switch VM", tf, tl)
}
do { // B dynamic
    let w = ClosureWorld(); let fib = buildClosureFib(w, dynamic: true)
    let (tf, rf) = best(reps) { w.stack[0] = .int(FIBN); return fib.body(w.stack) }
    precondition(rf.i32 == 196418)
    report("B closure tree, dyn map call", tf, .nan)
}
do { // B2 cached
    let w = ClosureWorld(); let fib = buildClosureFib(w, dynamic: false); let loop = buildClosureLoop()
    let (tf, rf) = best(reps) { w.stack[0] = .int(FIBN); return fib.body(w.stack) }
    let (tl, rl) = best(reps) { w.stack[0] = .int(LOOPN); return loop.body(w.stack) }
    precondition(rf.i32 == 196418 && rl.dbl == 399999960000000.0, "B2 wrong")
    report("B2 closure tree, cached call", tf, tl)
}
do { // C
    let stack: Frame = .allocate(capacity: 1 << 20)
    let fib = buildNodeFib(), loop = buildNodeLoop()
    let (tf, rf) = best(reps) { stack[0] = .int(FIBN); return fib.body.exec(stack) }
    let (tl, rl) = best(reps) { stack[0] = .int(LOOPN); return loop.body.exec(stack) }
    precondition(rf.i32 == 196418 && rl.dbl == 399999960000000.0, "C wrong")
    report("C class-node AST (virtual)", tf, tl)
}
do { // D
    buildThreaded()
    let stack: Frame = .allocate(capacity: 1 << 20)
    let (tf, rf) = best(reps) { stack[0] = .int(FIBN); return tRun(tFns[0], stack) }
    let (tl, rl) = best(reps) { stack[0] = .int(LOOPN); return tRun(tFns[1], stack) }
    precondition(rf.i32 == 196418 && rl.dbl == 399999960000000.0, "D wrong")
    report("D threaded handler table", tf, tl)
}
do { // E
    let (tf, rf) = best(reps) { nativeFib(.int(FIBN)) }
    let (tl, rl) = best(reps) { nativeLoop(.int(LOOPN)) }
    precondition(rf.i32 == 196418 && rl.dbl == 399999960000000.0, "E wrong")
    report("E native Swift", tf, tl)
}

// MARK: - B3. Closure tree with JS control flow: `throws` for exceptions, Flow for return/break
enum Flow { case next, brk, ret(V) }
struct JSError: Error {}
typealias TExpr = (Frame) throws -> V
typealias TStmt = (Frame) throws -> Flow
final class TFn { var body: TStmt = { _ in .next }; let frameSize: Int; init(_ n: Int) { frameSize = n } }
func tConstE(_ i: Int32) -> TExpr { let v = V.int(i); return { _ in v } }
func tLocE(_ i: Int) -> TExpr { { f in f[i] } }
func tAddE(_ a: @escaping TExpr, _ b: @escaping TExpr) -> TExpr { { f in vadd(try a(f), try b(f)) } }
func tSubE(_ a: @escaping TExpr, _ b: @escaping TExpr) -> TExpr { { f in vsub(try a(f), try b(f)) } }
func tMulE(_ a: @escaping TExpr, _ b: @escaping TExpr) -> TExpr { { f in vmul(try a(f), try b(f)) } }
func tLtE(_ a: @escaping TExpr, _ b: @escaping TExpr) -> TExpr { { f in .int(vlt(try a(f), try b(f)) ? 1 : 0) } }
func tSetS(_ i: Int, _ e: @escaping TExpr) -> TStmt { { f in f[i] = try e(f); return .next } }
func tRetS(_ e: @escaping TExpr) -> TStmt { { f in .ret(try e(f)) } }
func tIfS(_ c: @escaping TExpr, _ t: @escaping TStmt) -> TStmt { { f in try c(f).i32 != 0 ? try t(f) : .next } }
func tWhileS(_ c: @escaping TExpr, _ body: [TStmt]) -> TStmt {
    return { f in
        while try c(f).i32 != 0 {
            for s in body { switch try s(f) { case .next: continue; case .brk: return .next; case .ret: return try s(f) } }
        }
        return .next
    }
}
func tBlockS(_ ss: [TStmt]) -> TStmt { { f in for s in ss { let r = try s(f); if case .next = r { continue }; return r }; return .next } }
func tCallE(_ fn: TFn, _ a0: @escaping TExpr) -> TExpr {
    return { f in
        let nf = f + fn.frameSize
        nf[0] = try a0(f)
        if case .ret(let v) = try fn.body(nf) { return v }
        return V(bits: 0)
    }
}
func buildThrowingFib() -> TFn {
    let fn = TFn(1)
    fn.body = tBlockS([tIfS(tLtE(tLocE(0), tConstE(2)), tRetS(tLocE(0))),
                       tRetS(tAddE(tCallE(fn, tSubE(tLocE(0), tConstE(1))), tCallE(fn, tSubE(tLocE(0), tConstE(2)))))])
    return fn
}
func buildThrowingLoop() -> TFn {
    let fn = TFn(3)
    fn.body = tBlockS([tSetS(1, tConstE(0)), tSetS(2, tConstE(0)),
                       tWhileS(tLtE(tLocE(2), tLocE(0)), [
                         tSetS(1, tSubE(tAddE(tLocE(1), tMulE(tLocE(2), tConstE(2))), tConstE(1))),
                         tSetS(2, tAddE(tLocE(2), tConstE(1)))]),
                       tRetS(tLocE(1))])
    return fn
}
do { // B3
    let stack: Frame = .allocate(capacity: 1 << 20)
    let fib = buildThrowingFib(), loop = buildThrowingLoop()
    let (tf, rf) = best(reps) { stack[0] = .int(FIBN); if case .ret(let v) = try! fib.body(stack) { return v }; return V(bits: 0) }
    let (tl, rl) = best(reps) { stack[0] = .int(LOOPN); if case .ret(let v) = try! loop.body(stack) { return v }; return V(bits: 0) }
    precondition(rf.i32 == 196418 && rl.dbl == 399999960000000.0, "B3 wrong")
    report("B3 closure tree + throws/Flow", tf, tl)
}

// MARK: - Memory: bytes per closure node vs bytes per bytecode op
func residentBytes() -> Int {
    var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
    return kr == KERN_SUCCESS ? Int(info.resident_size) : -1
}
do {
    let n = 200_000
    let before = residentBytes()
    var keep: [Expr] = []; keep.reserveCapacity(n)
    for i in 0..<n {   // one "a + b" node tree: add(loc, const) = 3 closures, like 3 bytecode ops (get_loc, push_const, add = 4 bytes)
        keep.append(cAdd(cLoc(i & 7), cConst(Int32(i & 15))))
    }
    let after = residentBytes()
    print("closure tree: \(Double(after - before) / Double(n * 3)) bytes per node closure (3 closures per `a+b`; bytecode: ~1.3 bytes per op)")
    _ = keep.count
}

print("executor".padding(toLength: 32, withPad: " ", startingAt: 0) + "    ns/fib call   ns/loop iter")
for (n, a, b) in rows { print(n.padding(toLength: 32, withPad: " ", startingAt: 0) + String(format: " %14.1f %14.2f", a, b)) }
