//  JeffJSMetalRegex.swift
//  JeffJS — Metal GPU-accelerated regex matching orchestrator
//  Copyright 2026 Jeff Bachand. All rights reserved.
//
//  Compiles regex patterns to a simplified NFA instruction set, dispatches
//  the NFA to a Metal compute shader that tests every starting position in
//  parallel, and returns deduplicated match results.
//
//  Wraps everything in `#if canImport(Metal)` so the CLI test runner
//  (which compiles with swiftc directly) still builds cleanly.

import Foundation

// ============================================================================
// MARK: - GPU NFA instruction (shared layout with Metal shader)
// ============================================================================

/// Mirrors the `NFAInstr` struct in JeffJSMetalRegex.metal exactly.
/// 8 bytes, naturally aligned — no padding issues across Swift/Metal boundary.
struct NFAInstruction {
    var op: UInt8 = 0
    var padding: UInt8 = 0
    var arg1: UInt16 = 0   // character or jump target
    var arg2: UInt16 = 0   // second jump target for SPLIT, or range hi
    var arg3: UInt16 = 0   // extra (class count, etc.)
}

/// Mirrors the `MatchResult` struct in JeffJSMetalRegex.metal.
struct GPUMatchResult {
    var matchStart: Int32 = -1
    var matchLength: Int32 = 0
}

// ============================================================================
// MARK: - NFA opcodes (must match Metal constants)
// ============================================================================

private enum NFAOp: UInt8 {
    case char_     = 1
    case any       = 2
    case range     = 3
    case notRange  = 4
    case match     = 5
    case split     = 6
    case jmp       = 7
    case charClass = 8
    case dotAll    = 9
    case wordBoundary = 10
    case start     = 11
    case end       = 12
}

// ============================================================================
// MARK: - Metal-backed implementation
// ============================================================================

#if canImport(Metal)
import Metal

/// GPU-accelerated regex matching using Metal compute shaders.
/// Singleton — lazily initialises the Metal pipeline on first use.
final class JeffJSMetalRegex {

    // MARK: Singleton

    static let shared = JeffJSMetalRegex()

    // MARK: Metal state (lazy)

    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLComputePipelineState?
    private var metalReady = false
    private var metalInitAttempted = false

    private init() {}

    /// Lazily creates the Metal device, command queue, and compute pipeline.
    /// Returns `true` if Metal is ready to use.
    private func ensureMetal() -> Bool {
        if metalReady { return true }
        if metalInitAttempted { return false }
        metalInitAttempted = true

        guard let dev = MTLCreateSystemDefaultDevice() else { return false }
        device = dev

        guard let queue = dev.makeCommandQueue() else { return false }
        commandQueue = queue

        guard let library = dev.makeDefaultLibrary() else { return false }
        guard let function = library.makeFunction(name: "regex_match_all") else { return false }

        do {
            pipelineState = try dev.makeComputePipelineState(function: function)
        } catch {
            return false
        }

        metalReady = true
        return true
    }

    // MARK: - Threshold

    /// Minimum input length for GPU dispatch to be worthwhile.
    /// Below this, CPU backtracking is faster due to dispatch overhead.
    func shouldUseGPU(inputLength: Int) -> Bool {
        return inputLength > 1000
    }

    // MARK: - Public API

    /// Attempts GPU-accelerated global match of `pattern` against `input`.
    ///
    /// Returns an array of (start, length) tuples for each non-overlapping match,
    /// or `nil` if:
    /// - The pattern uses unsupported features (backreferences, lookahead, etc.)
    /// - The input is too short for GPU to be beneficial
    /// - Metal is unavailable on this device
    func gpuMatchAll(
        pattern: String,
        flags: JeffJSRegExpFlags,
        input: String
    ) -> [(start: Int, length: Int)]? {
        // Compile pattern to GPU-friendly NFA
        guard let nfa = compileToNFA(pattern: pattern, flags: flags) else {
            return nil  // unsupported pattern — caller falls back to CPU
        }

        // Check threshold
        let utf16 = Array(input.utf16)
        guard shouldUseGPU(inputLength: utf16.count) else {
            return nil  // too short — caller falls back to CPU
        }

        // Run on GPU
        let rawResults = findAllMatches(input: utf16, nfa: nfa)
        guard !rawResults.isEmpty else { return [] }

        // Convert to public tuple format
        return rawResults.map { (start: Int($0.matchStart), length: Int($0.matchLength)) }
    }

    // MARK: - NFA compiler

    /// Compiles a regex pattern string into GPU-friendly NFA instructions.
    ///
    /// Supports: literal chars, `.`, `[a-z]`, `[^a-z]`, `*`, `+`, `?`, `|`,
    /// `^`, `$`, `\d`, `\w`, `\s`, and their negations.
    ///
    /// Returns `nil` for unsupported patterns (backreferences, lookahead,
    /// lookbehind, named groups, atomic groups, etc.).
    func compileToNFA(pattern: String, flags: JeffJSRegExpFlags) -> [NFAInstruction]? {
        var compiler = NFACompiler(pattern: Array(pattern.unicodeScalars), flags: flags)
        return compiler.compile()
    }

    // MARK: - GPU dispatch

    /// Dispatches the NFA program to the GPU, running one thread per starting
    /// position. Returns deduplicated, non-overlapping matches (leftmost-longest).
    func findAllMatches(input: [UInt16], nfa: [NFAInstruction]) -> [GPUMatchResult] {
        guard !input.isEmpty, !nfa.isEmpty else { return [] }
        guard ensureMetal() else { return [] }
        guard let device = device,
              let commandQueue = commandQueue,
              let pipelineState = pipelineState else { return [] }

        let inputCount = input.count

        // --- Allocate shared Metal buffers ---

        // Buffer 0: input string (UTF-16)
        let inputSize = inputCount * MemoryLayout<UInt16>.stride
        guard let inputBuffer = device.makeBuffer(
            bytes: input,
            length: inputSize,
            options: .storageModeShared
        ) else { return [] }

        // Buffer 1: input length
        var inputLen = UInt32(inputCount)
        guard let inputLenBuffer = device.makeBuffer(
            bytes: &inputLen,
            length: MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else { return [] }

        // Buffer 2: NFA program
        let programSize = nfa.count * MemoryLayout<NFAInstruction>.stride
        guard let programBuffer = device.makeBuffer(
            bytes: nfa,
            length: programSize,
            options: .storageModeShared
        ) else { return [] }

        // Buffer 3: program length
        var progLen = UInt32(nfa.count)
        guard let progLenBuffer = device.makeBuffer(
            bytes: &progLen,
            length: MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else { return [] }

        // Buffer 4: results (one per starting position)
        let resultsSize = inputCount * MemoryLayout<GPUMatchResult>.stride
        guard let resultsBuffer = device.makeBuffer(
            length: resultsSize,
            options: .storageModeShared
        ) else { return [] }

        // --- Encode and dispatch ---

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return [] }

        encoder.setComputePipelineState(pipelineState)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(inputLenBuffer, offset: 0, index: 1)
        encoder.setBuffer(programBuffer, offset: 0, index: 2)
        encoder.setBuffer(progLenBuffer, offset: 0, index: 3)
        encoder.setBuffer(resultsBuffer, offset: 0, index: 4)

        // Thread group size: 256 threads per group
        let threadGroupSize = MTLSize(width: 256, height: 1, depth: 1)
        let gridSize = MTLSize(width: inputCount, height: 1, depth: 1)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadGroupSize)

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // --- Read back results ---

        let resultsPtr = resultsBuffer.contents().bindMemory(
            to: GPUMatchResult.self,
            capacity: inputCount
        )

        // Collect all positions that produced a match
        var rawMatches: [GPUMatchResult] = []
        rawMatches.reserveCapacity(inputCount / 4) // heuristic
        for i in 0 ..< inputCount {
            let r = resultsPtr[i]
            if r.matchStart >= 0 && r.matchLength > 0 {
                rawMatches.append(r)
            }
        }

        // Deduplicate: keep leftmost-longest, non-overlapping
        return deduplicateMatches(rawMatches)
    }

    // MARK: - Deduplication

    /// Given raw per-position match results, returns non-overlapping matches
    /// using a leftmost-longest strategy (matches sorted by start, ties broken
    /// by longest length, overlaps removed).
    private func deduplicateMatches(_ raw: [GPUMatchResult]) -> [GPUMatchResult] {
        guard !raw.isEmpty else { return [] }

        // Sort by start position ascending, then by length descending
        let sorted = raw.sorted { a, b in
            if a.matchStart != b.matchStart {
                return a.matchStart < b.matchStart
            }
            return a.matchLength > b.matchLength
        }

        var result: [GPUMatchResult] = []
        var lastEnd: Int32 = -1

        for m in sorted {
            // Skip matches that overlap with the previous accepted match
            if m.matchStart >= lastEnd {
                result.append(m)
                lastEnd = m.matchStart + m.matchLength
            }
        }

        return result
    }
}

// ============================================================================
// MARK: - NFA Compiler (pattern string -> [NFAInstruction])
// ============================================================================

/// Recursive-descent compiler that translates a regex pattern into a flat
/// array of NFA instructions suitable for the Metal compute shader.
private struct NFACompiler {
    let pattern: [Unicode.Scalar]
    let flags: JeffJSRegExpFlags
    var pos: Int = 0
    var instructions: [NFAInstruction] = []

    /// Returns `nil` if the pattern contains unsupported features.
    mutating func compile() -> [NFAInstruction]? {
        guard let _ = parseAlternation() else { return nil }
        instructions.append(NFAInstruction(op: NFAOp.match.rawValue))
        return instructions
    }

    // MARK: Alternation  (a|b|c)

    /// Parses `term ('|' term)*`.
    /// Emits OP_SPLIT/OP_JMP chains for each alternative.
    private mutating func parseAlternation() -> Bool? {
        // Record where the first alternative starts
        let startPc = instructions.count

        guard let _ = parseConcatenation() else { return nil }

        // No alternation — just return
        if pos >= pattern.count || pattern[pos] != "|" {
            return true
        }

        // We have alternation. We need to restructure what we emitted.
        // Strategy: collect all alternatives, then emit SPLIT chains.

        // Save the first alternative's instructions
        var alternatives: [[NFAInstruction]] = []
        alternatives.append(Array(instructions[startPc...]))
        instructions.removeSubrange(startPc...)

        while pos < pattern.count && pattern[pos] == "|" {
            pos += 1 // consume '|'
            let altStart = instructions.count
            guard let _ = parseConcatenation() else { return nil }
            alternatives.append(Array(instructions[altStart...]))
            instructions.removeSubrange(altStart...)
        }

        // Emit SPLIT chain
        // For N alternatives: SPLIT(alt0, next) alt0... JMP(end) SPLIT(alt1, next) alt1... JMP(end) ... altN
        emitAlternationChain(alternatives, at: startPc)

        return true
    }

    /// Emits a chain of SPLIT/JMP instructions for multiple alternatives.
    private mutating func emitAlternationChain(_ alternatives: [[NFAInstruction]], at basePc: Int) {
        if alternatives.count == 1 {
            instructions.append(contentsOf: alternatives[0])
            return
        }

        // We need to calculate absolute PC offsets.
        // Layout: for each alt except last:
        //   SPLIT(here+1, nextSplitOrLastAlt)
        //   <alt instructions>
        //   JMP(endOfAll)
        // Last alt: <alt instructions>

        // First, calculate total sizes
        struct AltInfo {
            let instrs: [NFAInstruction]
            var splitPc: Int = 0  // where the SPLIT for this alt goes
            var bodyPc: Int = 0   // where the alt body starts
            var jmpPc: Int = 0    // where the JMP after this alt goes
        }

        var infos: [AltInfo] = []
        var pc = basePc

        for (i, alt) in alternatives.enumerated() {
            var info = AltInfo(instrs: alt)
            if i < alternatives.count - 1 {
                info.splitPc = pc
                pc += 1  // SPLIT
                info.bodyPc = pc
                pc += alt.count
                info.jmpPc = pc
                pc += 1  // JMP
            } else {
                info.bodyPc = pc
                pc += alt.count
            }
            infos.append(info)
        }
        let endPc = pc

        // Now emit
        for (i, info) in infos.enumerated() {
            if i < infos.count - 1 {
                // SPLIT: arg1 = body of this alt, arg2 = next SPLIT (or last alt body)
                let nextTarget: UInt16
                if i + 1 < infos.count - 1 {
                    nextTarget = UInt16(infos[i + 1].splitPc)
                } else {
                    nextTarget = UInt16(infos[infos.count - 1].bodyPc)
                }
                instructions.append(NFAInstruction(
                    op: NFAOp.split.rawValue,
                    arg1: UInt16(info.bodyPc),
                    arg2: nextTarget
                ))
                instructions.append(contentsOf: info.instrs)
                instructions.append(NFAInstruction(
                    op: NFAOp.jmp.rawValue,
                    arg1: UInt16(endPc)
                ))
            } else {
                instructions.append(contentsOf: info.instrs)
            }
        }
    }

    // MARK: Concatenation

    /// Parses a sequence of quantified atoms.
    private mutating func parseConcatenation() -> Bool? {
        while pos < pattern.count {
            let ch = pattern[pos]
            // Stop at alternation or group close
            if ch == "|" || ch == ")" { break }
            guard let _ = parseQuantified() else { return nil }
        }
        return true
    }

    // MARK: Quantified  (atom [*+?])

    /// Parses an atom followed by an optional quantifier (`*`, `+`, `?`).
    private mutating func parseQuantified() -> Bool? {
        let atomStart = instructions.count
        guard let _ = parseAtom() else { return nil }
        let atomEnd = instructions.count

        guard pos < pattern.count else { return true }

        let ch = pattern[pos]
        if ch == "*" {
            pos += 1
            emitStar(atomStart: atomStart, atomEnd: atomEnd)
            return true
        } else if ch == "+" {
            pos += 1
            emitPlus(atomStart: atomStart, atomEnd: atomEnd)
            return true
        } else if ch == "?" {
            pos += 1
            emitQuestion(atomStart: atomStart, atomEnd: atomEnd)
            return true
        }

        return true
    }

    /// `a*` => SPLIT(body, after) body JMP(split)
    private mutating func emitStar(atomStart: Int, atomEnd: Int) {
        // Extract atom instructions
        let atomInstrs = Array(instructions[atomStart ..< atomEnd])
        instructions.removeSubrange(atomStart...)

        let splitPc = instructions.count
        let bodyPc = splitPc + 1
        let afterBody = bodyPc + atomInstrs.count
        let afterJmp = afterBody + 1

        // SPLIT: try body first (greedy), or skip to after
        instructions.append(NFAInstruction(
            op: NFAOp.split.rawValue,
            arg1: UInt16(bodyPc),
            arg2: UInt16(afterJmp)
        ))
        instructions.append(contentsOf: atomInstrs)
        // JMP back to SPLIT
        instructions.append(NFAInstruction(
            op: NFAOp.jmp.rawValue,
            arg1: UInt16(splitPc)
        ))
    }

    /// `a+` => body SPLIT(body, after)
    private mutating func emitPlus(atomStart: Int, atomEnd: Int) {
        // Body is already emitted at atomStart..atomEnd
        let bodyPc = atomStart
        let splitPc = instructions.count
        let afterSplit = splitPc + 1

        instructions.append(NFAInstruction(
            op: NFAOp.split.rawValue,
            arg1: UInt16(bodyPc),
            arg2: UInt16(afterSplit)
        ))
    }

    /// `a?` => SPLIT(body, after) body
    private mutating func emitQuestion(atomStart: Int, atomEnd: Int) {
        let atomInstrs = Array(instructions[atomStart ..< atomEnd])
        instructions.removeSubrange(atomStart...)

        let splitPc = instructions.count
        let bodyPc = splitPc + 1
        let afterBody = bodyPc + atomInstrs.count

        instructions.append(NFAInstruction(
            op: NFAOp.split.rawValue,
            arg1: UInt16(bodyPc),
            arg2: UInt16(afterBody)
        ))
        instructions.append(contentsOf: atomInstrs)
    }

    // MARK: Atom

    /// Parses a single atom: literal, `.`, `^`, `$`, escape, character class,
    /// or parenthesized group.
    private mutating func parseAtom() -> Bool? {
        guard pos < pattern.count else { return true }

        let ch = pattern[pos]

        switch ch {
        case ".":
            pos += 1
            if flags.contains(.dotAll) {
                instructions.append(NFAInstruction(op: NFAOp.dotAll.rawValue))
            } else {
                instructions.append(NFAInstruction(op: NFAOp.any.rawValue))
            }
            return true

        case "^":
            pos += 1
            instructions.append(NFAInstruction(op: NFAOp.start.rawValue))
            return true

        case "$":
            pos += 1
            instructions.append(NFAInstruction(op: NFAOp.end.rawValue))
            return true

        case "\\":
            return parseEscape()

        case "[":
            return parseCharacterClass()

        case "(":
            return parseGroup()

        case ")":
            // Should not be consumed here — caller handles it
            return true

        case "*", "+", "?", "|":
            // Quantifiers/alternation handled by caller
            return true

        case "{":
            // Bounded quantifiers not supported on GPU — bail out
            return nil

        default:
            // Literal character
            pos += 1
            instructions.append(NFAInstruction(
                op: NFAOp.char_.rawValue,
                arg1: UInt16(ch.value & 0xFFFF)
            ))
            return true
        }
    }

    // MARK: Escape sequences

    /// Parses `\d`, `\w`, `\s`, `\D`, `\W`, `\S`, `\n`, `\t`, `\r`,
    /// and literal escapes like `\.`, `\\`, etc.
    /// Returns `nil` for unsupported escapes (backreferences, etc.).
    private mutating func parseEscape() -> Bool? {
        pos += 1  // consume '\'
        guard pos < pattern.count else { return nil }

        let ch = pattern[pos]
        pos += 1

        switch ch {
        // \d — digit [0-9]
        case "d":
            instructions.append(NFAInstruction(
                op: NFAOp.range.rawValue,
                arg1: UInt16(0x30),  // '0'
                arg2: UInt16(0x39)   // '9'
            ))
            return true

        // \D — non-digit
        case "D":
            instructions.append(NFAInstruction(
                op: NFAOp.notRange.rawValue,
                arg1: UInt16(0x30),
                arg2: UInt16(0x39)
            ))
            return true

        // \w — word character [a-zA-Z0-9_]
        // Emit as alternation of ranges: SPLIT chains
        case "w":
            emitWordCharClass(negated: false)
            return true

        // \W — non-word character
        case "W":
            emitWordCharClass(negated: true)
            return true

        // \s — whitespace [ \t\n\r\f\v]
        case "s":
            emitWhitespaceClass(negated: false)
            return true

        // \S — non-whitespace
        case "S":
            emitWhitespaceClass(negated: true)
            return true

        // Common literal escapes
        case "n":
            instructions.append(NFAInstruction(op: NFAOp.char_.rawValue, arg1: 0x0A))
            return true
        case "r":
            instructions.append(NFAInstruction(op: NFAOp.char_.rawValue, arg1: 0x0D))
            return true
        case "t":
            instructions.append(NFAInstruction(op: NFAOp.char_.rawValue, arg1: 0x09))
            return true
        case "f":
            instructions.append(NFAInstruction(op: NFAOp.char_.rawValue, arg1: 0x0C))
            return true
        case "v":
            instructions.append(NFAInstruction(op: NFAOp.char_.rawValue, arg1: 0x0B))
            return true
        case "0":
            instructions.append(NFAInstruction(op: NFAOp.char_.rawValue, arg1: 0x00))
            return true

        // \b — word boundary (not supported on GPU for simplicity)
        case "b", "B":
            return nil

        // Backreferences \1-\9 — not supported on GPU
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            return nil

        // Literal escape of special chars: \., \\, \*, etc.
        case ".", "\\", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|", "^", "$", "/":
            instructions.append(NFAInstruction(
                op: NFAOp.char_.rawValue,
                arg1: UInt16(ch.value & 0xFFFF)
            ))
            return true

        default:
            // Unknown escape — treat as literal
            instructions.append(NFAInstruction(
                op: NFAOp.char_.rawValue,
                arg1: UInt16(ch.value & 0xFFFF)
            ))
            return true
        }
    }

    // MARK: \w / \W helper

    /// Emits NFA instructions for \w (word character) or \W (non-word).
    /// \w = [a-zA-Z0-9_] — emitted as alternation of 4 ranges.
    private mutating func emitWordCharClass(negated: Bool) {
        if negated {
            // \W: NOT a word char. We approximate with a series of NOT_RANGE checks
            // that are ANDed together. Since the GPU NFA doesn't support AND directly,
            // we use a SPLIT-based approach that tries each valid range and fails
            // only if ALL ranges fail.
            // Simpler approach: emit as the complement ranges.
            // [^a-zA-Z0-9_] = [\x00-\x2F \x3A-\x40 \x5B-\x5E \x60 \x7B-\xFFFF]
            let ranges: [(UInt16, UInt16)] = [
                (0x0000, 0x002F),  // before '0'
                (0x003A, 0x0040),  // between '9' and 'A'
                (0x005B, 0x005E),  // between 'Z' and '_'
                (0x0060, 0x0060),  // between '_' and 'a' (backtick)
                (0x007B, 0xFFFF),  // after 'z'
            ]
            emitRangeAlternation(ranges)
        } else {
            // \w = [a-zA-Z0-9_]
            let ranges: [(UInt16, UInt16)] = [
                (0x0030, 0x0039),  // 0-9
                (0x0041, 0x005A),  // A-Z
                (0x005F, 0x005F),  // _
                (0x0061, 0x007A),  // a-z
            ]
            emitRangeAlternation(ranges)
        }
    }

    // MARK: \s / \S helper

    /// Emits NFA instructions for \s or \S.
    /// \s = [ \t\n\r\f\v] (ASCII whitespace)
    private mutating func emitWhitespaceClass(negated: Bool) {
        if negated {
            // \S: non-whitespace — complement of whitespace chars
            let ranges: [(UInt16, UInt16)] = [
                (0x0000, 0x0008),  // before \t
                (0x000E, 0x001F),  // between \r and space
                (0x0021, 0xFFFF),  // after space
            ]
            emitRangeAlternation(ranges)
        } else {
            // \s = space(0x20), \t(0x09), \n(0x0A), \r(0x0D), \f(0x0C), \v(0x0B)
            let ranges: [(UInt16, UInt16)] = [
                (0x0009, 0x000D),  // \t through \r
                (0x0020, 0x0020),  // space
            ]
            emitRangeAlternation(ranges)
        }
    }

    /// Emits a SPLIT-based alternation of OP_RANGE instructions.
    private mutating func emitRangeAlternation(_ ranges: [(UInt16, UInt16)]) {
        guard !ranges.isEmpty else { return }

        if ranges.count == 1 {
            instructions.append(NFAInstruction(
                op: NFAOp.range.rawValue,
                arg1: ranges[0].0,
                arg2: ranges[0].1
            ))
            return
        }

        // Build range instructions as "alternatives"
        var alternatives: [[NFAInstruction]] = []
        for r in ranges {
            alternatives.append([NFAInstruction(
                op: NFAOp.range.rawValue,
                arg1: r.0,
                arg2: r.1
            )])
        }

        let basePc = instructions.count
        emitAlternationChain(alternatives, at: basePc)
    }

    // MARK: Character class [...]

    /// Parses `[...]` and `[^...]` character classes.
    /// Emits a SPLIT-based alternation of OP_RANGE/OP_CHAR instructions.
    private mutating func parseCharacterClass() -> Bool? {
        pos += 1  // consume '['

        guard pos < pattern.count else { return nil }

        let negated = pattern[pos] == "^"
        if negated { pos += 1 }

        var ranges: [(UInt16, UInt16)] = []

        while pos < pattern.count && pattern[pos] != "]" {
            let startChar = pattern[pos]

            // Handle escape inside class
            if startChar == "\\" {
                pos += 1
                guard pos < pattern.count else { return nil }
                let escaped = pattern[pos]
                pos += 1

                switch escaped {
                case "d":
                    ranges.append((0x30, 0x39))
                    continue
                case "D":
                    ranges.append((0x00, 0x2F))
                    ranges.append((0x3A, 0xFFFF))
                    continue
                case "w":
                    ranges.append((0x30, 0x39))
                    ranges.append((0x41, 0x5A))
                    ranges.append((0x5F, 0x5F))
                    ranges.append((0x61, 0x7A))
                    continue
                case "W":
                    ranges.append((0x00, 0x2F))
                    ranges.append((0x3A, 0x40))
                    ranges.append((0x5B, 0x5E))
                    ranges.append((0x60, 0x60))
                    ranges.append((0x7B, 0xFFFF))
                    continue
                case "s":
                    ranges.append((0x09, 0x0D))
                    ranges.append((0x20, 0x20))
                    continue
                case "S":
                    ranges.append((0x00, 0x08))
                    ranges.append((0x0E, 0x1F))
                    ranges.append((0x21, 0xFFFF))
                    continue
                case "n":
                    ranges.append((0x0A, 0x0A))
                    continue
                case "r":
                    ranges.append((0x0D, 0x0D))
                    continue
                case "t":
                    ranges.append((0x09, 0x09))
                    continue
                default:
                    // Literal escaped char
                    let val = UInt16(escaped.value & 0xFFFF)
                    ranges.append((val, val))
                    continue
                }
            }

            pos += 1
            let lo = UInt16(startChar.value & 0xFFFF)

            // Check for range: a-z
            if pos + 1 < pattern.count && pattern[pos] == "-" && pattern[pos + 1] != "]" {
                pos += 1  // consume '-'
                let endChar = pattern[pos]
                pos += 1
                let hi = UInt16(endChar.value & 0xFFFF)
                ranges.append((lo, hi))
            } else {
                ranges.append((lo, lo))
            }
        }

        // Consume ']'
        guard pos < pattern.count && pattern[pos] == "]" else { return nil }
        pos += 1

        guard !ranges.isEmpty else { return nil }

        if negated {
            // Build complement ranges
            let complemented = complementRanges(ranges)
            emitRangeAlternation(complemented)
        } else {
            emitRangeAlternation(ranges)
        }

        return true
    }

    /// Computes the complement of a set of ranges over [0x0000, 0xFFFF].
    private func complementRanges(_ ranges: [(UInt16, UInt16)]) -> [(UInt16, UInt16)] {
        // Sort and merge
        let sorted = ranges.sorted { $0.0 < $1.0 }
        var merged: [(UInt16, UInt16)] = []
        for r in sorted {
            if let last = merged.last, r.0 <= last.1 &+ 1 {
                merged[merged.count - 1].1 = max(last.1, r.1)
            } else {
                merged.append(r)
            }
        }

        // Build complement
        var result: [(UInt16, UInt16)] = []
        var prev: UInt16 = 0
        for r in merged {
            if r.0 > prev {
                result.append((prev, r.0 - 1))
            }
            prev = r.1 &+ 1
            if prev == 0 { break }  // wrapped around — full range covered
        }
        if prev <= 0xFFFF && (merged.isEmpty || merged.last!.1 < 0xFFFF) {
            result.append((prev, 0xFFFF))
        }
        return result
    }

    // MARK: Groups

    /// Parses a parenthesized group. Supports basic `(...)` and non-capturing
    /// `(?:...)`. Returns `nil` for lookahead/lookbehind/named groups.
    private mutating func parseGroup() -> Bool? {
        pos += 1  // consume '('
        guard pos < pattern.count else { return nil }

        // Check for special group syntax
        if pattern[pos] == "?" {
            pos += 1
            guard pos < pattern.count else { return nil }
            let modifier = pattern[pos]

            switch modifier {
            case ":":
                // Non-capturing group (?:...) — just parse contents
                pos += 1
            case "=", "!":
                // Lookahead — not supported on GPU
                return nil
            case "<":
                // Could be lookbehind (?<=...), (?<!...) or named group (?<name>...)
                return nil
            default:
                return nil
            }
        }
        // else: capturing group — we ignore captures on GPU, just parse contents

        guard let _ = parseAlternation() else { return nil }

        // Consume ')'
        guard pos < pattern.count && pattern[pos] == ")" else { return nil }
        pos += 1

        return true
    }
}

#else
// ============================================================================
// MARK: - Stub implementation for non-Metal platforms (CLI, etc.)
// ============================================================================

/// Stub that always returns nil when Metal is unavailable.
final class JeffJSMetalRegex {

    static let shared = JeffJSMetalRegex()

    private init() {}

    func shouldUseGPU(inputLength: Int) -> Bool {
        return false
    }

    func gpuMatchAll(
        pattern: String,
        flags: JeffJSRegExpFlags,
        input: String
    ) -> [(start: Int, length: Int)]? {
        return nil
    }

    func compileToNFA(pattern: String, flags: JeffJSRegExpFlags) -> [NFAInstruction]? {
        return nil
    }

    func findAllMatches(input: [UInt16], nfa: [NFAInstruction]) -> [GPUMatchResult] {
        return []
    }
}

#endif
