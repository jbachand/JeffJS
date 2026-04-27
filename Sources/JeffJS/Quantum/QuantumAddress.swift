// QuantumAddress.swift
// 25-bit address packing/unpacking and popcount utilities.

import Foundation

/// A 25-bit address in the quantum field: (vx, vy, t, offset, seed).
struct QuantumAddress: Equatable, Hashable, CustomStringConvertible {
    let vx:      UInt32   // 5 bits
    let vy:      UInt32   // 5 bits
    let t:       UInt32   // 5 bits
    let offset:  UInt32   // 5 bits
    let seed:    UInt32   // 5 bits

    /// The packed 25-bit representation.
    var packed: UInt32 {
        ((vx & 0x1F) << 20) |
        ((vy & 0x1F) << 15) |
        ((t  & 0x1F) << 10) |
        ((offset & 0x1F) << 5) |
        (seed & 0x1F)
    }

    init(vx: UInt32, vy: UInt32, t: UInt32, offset: UInt32, seed: UInt32) {
        self.vx     = vx & 0x1F
        self.vy     = vy & 0x1F
        self.t      = t  & 0x1F
        self.offset = offset & 0x1F
        self.seed   = seed & 0x1F
    }

    /// Unpack a 25-bit integer into address components.
    init(packed addr: UInt32) {
        vx     = (addr >> 20) & 0x1F
        vy     = (addr >> 15) & 0x1F
        t      = (addr >> 10) & 0x1F
        offset = (addr >>  5) & 0x1F
        seed   = addr & 0x1F
    }

    var description: String {
        String(format: "0x%07X (vx=%d vy=%d t=%d off=%d seed=%d)", packed, vx, vy, t, offset, seed)
    }
}

// MARK: - Bit Utilities

enum QuantumBits {

    /// Count of set bits in a 25-bit value.
    @inline(__always)
    static func popcount(_ x: UInt32) -> UInt32 {
        UInt32(truncatingIfNeeded: (x & 0x1FF_FFFF).nonzeroBitCount)
    }

    /// Data slice index derived from a 25-bit payload, or `nil` for end markers.
    static func sliceFromPayload(_ payload: UInt32) -> Int? {
        QuantumConstants.sliceIndex(forPopcount: popcount(payload))
    }

    /// Whether the payload indicates end-of-chain.
    static func isEndMarker(_ payload: UInt32) -> Bool {
        let pop = popcount(payload)
        return pop <= QuantumConstants.endMarkerLow || pop >= QuantumConstants.endMarkerHigh
    }
}
