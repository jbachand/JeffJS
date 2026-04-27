//  JeffJSMetalRegex.metal
//  JeffJS — Metal GPU-accelerated regex matching
//  Copyright 2026 Jeff Bachand. All rights reserved.
//
//  Compute shader that runs a simplified NFA regex matcher in parallel.
//  Each GPU thread tests one starting position in the input string.
//  For global searches (matchAll, replace with /g), this runs the NFA
//  from ALL starting positions simultaneously instead of sequentially.

#include <metal_stdlib>
using namespace metal;

// ============================================================================
// MARK: - NFA instruction opcodes
// ============================================================================

constant uint8_t OP_CHAR       = 1;   // match exact character
constant uint8_t OP_ANY        = 2;   // match any char (except newline)
constant uint8_t OP_RANGE      = 3;   // match char in range [lo, hi]
constant uint8_t OP_NOT_RANGE  = 4;   // match char NOT in range
constant uint8_t OP_MATCH      = 5;   // successful match
constant uint8_t OP_SPLIT      = 6;   // try two paths (greedy)
constant uint8_t OP_JMP        = 7;   // unconditional jump
//constant uint8_t OP_CHAR_CLASS = 8;   // match one of N chars
constant uint8_t OP_DOT_ALL    = 9;   // match any char including newline
//constant uint8_t OP_WORD_BOUNDARY = 10;
constant uint8_t OP_START      = 11;  // ^
constant uint8_t OP_END        = 12;  // $

// ============================================================================
// MARK: - Data structures
// ============================================================================

struct NFAInstr {
    uint8_t  op;
    uint8_t  padding;
    uint16_t arg1;   // character or jump offset
    uint16_t arg2;   // second jump offset for SPLIT, or range hi
    uint16_t arg3;   // extra (class count, etc.)
};

struct MatchResult {
    int32_t matchStart;    // -1 if no match from this position
    int32_t matchLength;   // length of match
};

// ============================================================================
// MARK: - Compute kernel
// ============================================================================

/// Each thread tests one starting position in the input string.
/// Uses bounded backtracking (max 64 entries) to prevent GPU hangs.
kernel void regex_match_all(
    device const uint16_t* input     [[buffer(0)]],   // UTF-16 input string
    constant uint32_t& inputLen      [[buffer(1)]],
    device const NFAInstr* program   [[buffer(2)]],   // compiled NFA program
    constant uint32_t& programLen    [[buffer(3)]],
    device MatchResult* results      [[buffer(4)]],   // one result per starting position
    uint pos [[thread_position_in_grid]])
{
    if (pos >= inputLen) {
        results[pos] = {-1, 0};
        return;
    }

    // Stack-based backtracking with a hard cap to prevent GPU hangs.
    // Each entry saves (program counter, input position) for an alternative path.
    uint32_t btStack[64];   // saved program counter
    uint32_t btPos[64];     // saved input position
    int btTop = -1;

    uint32_t pc = 0;
    uint32_t curPos = pos;

    while (pc < programLen) {
        NFAInstr instr = program[pc];

        switch (instr.op) {

        // --- OP_CHAR: match a single literal character ---
        case OP_CHAR:
            if (curPos < inputLen && input[curPos] == instr.arg1) {
                curPos++;
                pc++;
            } else {
                if (btTop >= 0) {
                    pc = btStack[btTop];
                    curPos = btPos[btTop];
                    btTop--;
                } else {
                    results[pos] = {-1, 0};
                    return;
                }
            }
            break;

        // --- OP_ANY: match any character except newline ---
        case OP_ANY:
            if (curPos < inputLen && input[curPos] != 0x0A) {
                curPos++;
                pc++;
            } else {
                if (btTop >= 0) {
                    pc = btStack[btTop];
                    curPos = btPos[btTop];
                    btTop--;
                } else {
                    results[pos] = {-1, 0};
                    return;
                }
            }
            break;

        // --- OP_DOT_ALL: match any character including newline (s flag) ---
        case OP_DOT_ALL:
            if (curPos < inputLen) {
                curPos++;
                pc++;
            } else {
                if (btTop >= 0) {
                    pc = btStack[btTop];
                    curPos = btPos[btTop];
                    btTop--;
                } else {
                    results[pos] = {-1, 0};
                    return;
                }
            }
            break;

        // --- OP_RANGE: match character in inclusive range [arg1, arg2] ---
        case OP_RANGE:
            if (curPos < inputLen && input[curPos] >= instr.arg1 && input[curPos] <= instr.arg2) {
                curPos++;
                pc++;
            } else {
                if (btTop >= 0) {
                    pc = btStack[btTop];
                    curPos = btPos[btTop];
                    btTop--;
                } else {
                    results[pos] = {-1, 0};
                    return;
                }
            }
            break;

        // --- OP_NOT_RANGE: match character NOT in range [arg1, arg2] ---
        case OP_NOT_RANGE:
            if (curPos < inputLen && (input[curPos] < instr.arg1 || input[curPos] > instr.arg2)) {
                curPos++;
                pc++;
            } else {
                if (btTop >= 0) {
                    pc = btStack[btTop];
                    curPos = btPos[btTop];
                    btTop--;
                } else {
                    results[pos] = {-1, 0};
                    return;
                }
            }
            break;

        // --- OP_SPLIT: try arg1 first (greedy), save arg2 as backtrack ---
        case OP_SPLIT:
            if (btTop < 63) {
                btTop++;
                btStack[btTop] = instr.arg2;
                btPos[btTop] = curPos;
            }
            pc = instr.arg1;
            break;

        // --- OP_JMP: unconditional jump ---
        case OP_JMP:
            pc = instr.arg1;
            break;

        // --- OP_START: anchor ^ (match only at position 0) ---
        case OP_START:
            if (curPos == 0) {
                pc++;
            } else {
                if (btTop >= 0) {
                    pc = btStack[btTop];
                    curPos = btPos[btTop];
                    btTop--;
                } else {
                    results[pos] = {-1, 0};
                    return;
                }
            }
            break;

        // --- OP_END: anchor $ (match only at end of input) ---
        case OP_END:
            if (curPos == inputLen) {
                pc++;
            } else {
                if (btTop >= 0) {
                    pc = btStack[btTop];
                    curPos = btPos[btTop];
                    btTop--;
                } else {
                    results[pos] = {-1, 0};
                    return;
                }
            }
            break;

        // --- OP_MATCH: successful match ---
        case OP_MATCH:
            results[pos] = {int32_t(pos), int32_t(curPos - pos)};
            return;

        // --- Unknown opcode: no match ---
        default:
            results[pos] = {-1, 0};
            return;
        }
    }

    // Fell off the end of the program without matching
    results[pos] = {-1, 0};
}
