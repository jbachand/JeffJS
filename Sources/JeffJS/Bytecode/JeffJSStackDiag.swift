// JeffJSStackDiag.swift
// JeffJS — VM value-stack overflow reporting.
//
// The interpreter's value stack is a raw buffer sized from the compiler's
// static stack-effect analysis (fb.stackSize) plus headroom. A push/pop
// imbalance in emitted bytecode (compiler bug) grows sp without bound inside
// loops and previously scribbled the heap past the buffer — the source of
// "impossible" downstream corruption (malloc freelist traps, ObjC cache
// aborts). push() now reports here and drops the write instead.

import Foundation

enum JeffJSStackDiag {
    /// Optional label stamped by test harnesses to localize reports.
    nonisolated(unsafe) static var currentLabel: String = ""

    /// Cap report spam; the first few reports carry all the signal.
    nonisolated(unsafe) static var reportsRemaining = 6

    /// Total overflows suppressed (cheap counter, always maintained).
    nonisolated(unsafe) static var overflowCount = 0

    static func reportOverflow(ctx: JeffJSContext, fb: JeffJSFunctionBytecode,
                               pc: Int, sp: Int, spBase: Int, capacity: Int,
                               bc: UnsafePointer<UInt8>, bcLen: Int,
                               buf: UnsafeMutablePointer<JeffJSValue>) {
        overflowCount += 1
        guard reportsRemaining > 0 else { return }
        reportsRemaining -= 1

        let fname = fb.fileName?.toSwiftString() ?? "?"
        var msg = "[VM-STACK-OVERFLOW] sp=\(sp) spBase=\(spBase) cap=\(capacity) "
        msg += "declaredStack=\(fb.stackSize) pc=\(pc) file=\(fname):\(fb.lineNum)"
        if !currentLabel.isEmpty { msg += " label=\(currentLabel)" }
        print(msg)

        // Tag profile of the stack region — repeated patterns identify the
        // cycle (e.g. a wall of catchOffset entries = catch_ re-entry).
        var tags = "  stack tags:"
        for i in max(0, spBase)..<min(sp, capacity) {
            let v = buf[i]
            if v.isCatchOffset { tags += " catch(\(v.toInt32()))" }
            else if v.isInt { tags += " int(\(v.toInt32()))" }
            else if v.isObject { tags += " obj" }
            else if v.isString { tags += " str" }
            else if v.isUndefined { tags += " undef" }
            else if v.isNull { tags += " null" }
            else { tags += " bits(0x\(String(v.bits, radix: 16)))" }
        }
        print(tags)

        // Dump a bytecode window around pc for sequence identification.
        let lo = max(0, pc - 16)
        let hi = min(bcLen, pc + 16)
        var window = "  bc[\(lo)..<\(hi)]:"
        for i in lo..<hi {
            window += i == pc ? " >\(bc[i])<" : " \(bc[i])"
        }
        print(window)

        // Decode a few opcodes forward from the window start for readability.
        var pos = lo
        var decoded = "  ops:"
        var count = 0
        while pos < hi && count < 12 {
            guard let op = JeffJSOpcode(rawValue: UInt16(bc[pos])) else { break }
            let info = jeffJSGetOpcodeInfo(op)
            var size = Int(info.size)
            var name = "\(op)"
            if bc[pos] == 0 && pos + 1 < bcLen,
               let wide = JeffJSOpcode(rawValue: 256 + UInt16(bc[pos + 1])) {
                name = "\(wide)"
                size = Int(jeffJSGetOpcodeInfo(wide).size) + 1
            }
            decoded += pos == pc ? " >\(name)<" : " \(name)"
            if size <= 0 { break }
            pos += size
            count += 1
        }
        print(decoded)
    }
}
