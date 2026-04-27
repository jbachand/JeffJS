// QuantumConfig.swift
// Constants and slice-range configuration for the quantum encoder.
//
// 25-bit address layout:
//   vx:     5 bits (0-31)
//   vy:     5 bits (0-31)
//   t:      5 bits (0-31)
//   offset: 5 bits (0-31)
//   seed:   5 bits (0-31)
//
// Data is encoded via popcount slices over the 25-bit payload.
// Each position's data value is determined by which slice its payload
// popcount falls into (2 bits per step = 4 slices by default).

import Foundation

// MARK: - Grid Dimensions

enum QuantumConstants {

    static let bitsVX      = 5
    static let bitsVY      = 5
    static let bitsT       = 5
    static let bitsOffset  = 5
    static let bitsSeed    = 5
    static let totalBits   = bitsVX + bitsVY + bitsT + bitsOffset + bitsSeed  // 25

    static let gridVX:     UInt32 = 1 << 5   // 32
    static let gridVY:     UInt32 = 1 << 5   // 32
    static let gridT:      UInt32 = 1 << 5   // 32
    static let gridOffset: UInt32 = 1 << 5   // 32
    static let gridSeed:   UInt32 = 1 << 5   // 32

    // MARK: - Qubit System

    static let numQubits:  Int    = 256
    static let baseSeed:   UInt32 = 0xDEAD_BEEF
    static let tScale:     Float  = 0.1

    // MARK: - End Markers

    /// Popcount <= endMarkerLow means end of chain.
    static let endMarkerLow:  UInt32 = 2
    /// Popcount >= endMarkerHigh means end of chain.
    static let endMarkerHigh: UInt32 = 23

    // MARK: - Data Slice

    /// Bits encoded per chain step (2 = 4 slices, 3 = 8, 4 = 16).
    static let dataBits:   Int    = 2
    static let numSlices:  Int    = 1 << dataBits  // 4

    /// Maximum data values per chain before splitting into multiple keys.
    static let maxChainValues = 8  // 8 values = 16 bits = 2 characters

    // MARK: - Slice Ranges

    /// Popcount range (inclusive) for each data slice.
    /// Popcounts 0-2 and 23-25 are reserved for end markers.
    static let sliceRanges: [(min: UInt32, max: UInt32)] = {
        let usableMin = endMarkerLow + 1    // 3
        let usableMax = endMarkerHigh - 1   // 22
        let usableRange = usableMax - usableMin + 1  // 20
        let sliceSize = usableRange / UInt32(numSlices)

        return (0 ..< numSlices).map { i in
            let start = usableMin + UInt32(i) * sliceSize
            let end = i < numSlices - 1
                ? usableMin + UInt32(i + 1) * sliceSize - 1
                : usableMax
            return (start, end)
        }
    }()

    /// Convert a popcount to its slice index, or `nil` for end markers.
    static func sliceIndex(forPopcount pop: UInt32) -> Int? {
        if pop <= endMarkerLow  { return nil }
        if pop >= endMarkerHigh { return nil }
        for (i, range) in sliceRanges.enumerated() {
            if pop >= range.min && pop <= range.max { return i }
        }
        return 0  // fallback
    }
}
