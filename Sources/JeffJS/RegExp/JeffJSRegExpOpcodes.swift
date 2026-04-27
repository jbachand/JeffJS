// JeffJSRegExpOpcodes.swift
// JeffJS — 1:1 Swift port of QuickJS libregexp-opcode.h
// Copyright 2026 Jeff Bachand. All rights reserved.
//
// Every opcode, its encoding width, and metadata match QuickJS exactly.

import Foundation

// MARK: - Opcode enum

/// All regex bytecode opcodes from libregexp-opcode.h.
/// Raw values are the single-byte opcode IDs emitted in compiled bytecode.
enum JeffJSRegExpOpcode: UInt8 {
    case invalid              = 0
    case char_                = 1   // match one 16-bit char (2-byte payload)
    case char32               = 2   // match one 32-bit char (4-byte payload)
    case dot                  = 3   // match any except line terminators (no s flag)
    case any                  = 4   // match any char (s flag)
    case lineStart            = 5   // ^
    case lineEnd              = 6   // $
    case goto_                = 7   // unconditional jump (4-byte signed offset)
    case splitGotoFirst       = 8   // ordered choice: try goto branch first
    case splitNextFirst       = 9   // ordered choice: try next instruction first
    case match                = 10  // successful match
    case saveStart            = 11  // save capture group start (1-byte group id)
    case saveEnd              = 12  // save capture group end   (1-byte group id)
    case saveReset            = 13  // reset captures in range  (2-byte: start, count)
    case loop                 = 14  // loop counter management  (4-byte)
    case pushI32              = 15  // push int32 on backtrack stack (4-byte)
    case drop                 = 16  // pop from backtrack stack
    case wordBoundary         = 17  // \b
    case notWordBoundary      = 18  // \B
    case backReference        = 19  // \1-\99 (1-byte group id)
    case backwardBackReference = 20 // lookbehind back reference (1-byte group id)
    case range                = 21  // character class [...]  (2-byte length + pairs)
    case range32              = 22  // 32-bit character class (2-byte length + pairs)
    case lookahead            = 23  // (?=...)  (4-byte offset + 1-byte group count)
    case negativeLookahead    = 24  // (?!...)  (4-byte offset + 1-byte group count)
    case pushCharPos          = 25  // push current char position
    case checkAdvance         = 26  // check that position advanced (prevents empty loops)
    case prev                 = 27  // move backward one char (for lookbehind)
    case simpleGreedyQuant    = 28  // optimised {n,m} quantifier
    // Total opcode count (not a real opcode):
    case opcodeCount          = 29
}

// MARK: - Opcode sizes

/// Returns the total size in bytes of an instruction, including the opcode byte.
/// Variable-length opcodes (range, range32, simpleGreedyQuant) return only their
/// fixed-header size here; the caller must add the variable part.
func lreOpcodeSize(_ op: JeffJSRegExpOpcode) -> Int {
    switch op {
    case .invalid:                return 1
    case .char_:                  return 3      // 1 opcode + 2 char
    case .char32:                 return 5      // 1 opcode + 4 char
    case .dot:                    return 1
    case .any:                    return 1
    case .lineStart:              return 1
    case .lineEnd:                return 1
    case .goto_:                  return 5      // 1 opcode + 4 offset
    case .splitGotoFirst:         return 5
    case .splitNextFirst:         return 5
    case .match:                  return 1
    case .saveStart:              return 2      // 1 opcode + 1 group id
    case .saveEnd:                return 2
    case .saveReset:              return 3      // 1 opcode + 1 start + 1 count
    case .loop:                   return 5      // 1 opcode + 4 (value)
    case .pushI32:                return 5      // 1 opcode + 4 (value)
    case .drop:                   return 1
    case .wordBoundary:           return 1
    case .notWordBoundary:        return 1
    case .backReference:          return 2      // 1 opcode + 1 group id
    case .backwardBackReference:  return 2
    case .range:                  return 3      // 1 opcode + 2 pair count (then pairs follow)
    case .range32:                return 3      // 1 opcode + 2 pair count (then pairs follow)
    case .lookahead:              return 6      // 1 opcode + 4 offset + 1 group count
    case .negativeLookahead:      return 6
    case .pushCharPos:            return 1
    case .checkAdvance:           return 1
    case .prev:                   return 1
    case .simpleGreedyQuant:      return 17     // 1 + 4 offset + 4 min + 4 max + 4 body_len
    case .opcodeCount:            return 1
    }
}

// MARK: - Opcode names (for debug dumps)

/// Human-readable name for each opcode.
func lreOpcodeName(_ op: JeffJSRegExpOpcode) -> String {
    switch op {
    case .invalid:                return "invalid"
    case .char_:                  return "char"
    case .char32:                 return "char32"
    case .dot:                    return "dot"
    case .any:                    return "any"
    case .lineStart:              return "line_start"
    case .lineEnd:                return "line_end"
    case .goto_:                  return "goto"
    case .splitGotoFirst:         return "split_goto_first"
    case .splitNextFirst:         return "split_next_first"
    case .match:                  return "match"
    case .saveStart:              return "save_start"
    case .saveEnd:                return "save_end"
    case .saveReset:              return "save_reset"
    case .loop:                   return "loop"
    case .pushI32:                return "push_i32"
    case .drop:                   return "drop"
    case .wordBoundary:           return "word_boundary"
    case .notWordBoundary:        return "not_word_boundary"
    case .backReference:          return "back_reference"
    case .backwardBackReference:  return "backward_back_reference"
    case .range:                  return "range"
    case .range32:                return "range32"
    case .lookahead:              return "lookahead"
    case .negativeLookahead:      return "negative_lookahead"
    case .pushCharPos:            return "push_char_pos"
    case .checkAdvance:           return "check_advance"
    case .prev:                   return "prev"
    case .simpleGreedyQuant:      return "simple_greedy_quant"
    case .opcodeCount:            return "opcode_count"
    }
}
