// QuantumTests.swift
// Minimal sanity tests for the quantum demo. Three pure-data round-trips
// plus one bridge-shape probe — enough to catch the obvious silent
// regressions (broken serialization, missing bridge methods, address-pack
// off-by-ones) without pretending this concept demo deserves a test
// fortress.
//
// Deliberately omitted: real encoder runs. The chain encoder and slice
// encoder are probabilistic in their CPU runtime — pinning them in unit
// tests would either hang on unfriendly bit patterns or give false
// confidence that they "work." If you want to verify the algorithms,
// run the encoders by hand from the REPL or console app.

import XCTest
@testable import JeffJS

final class QuantumTests: XCTestCase {

    // MARK: - Address packing (instant, deterministic)

    func testAddressPackUnpackRoundTrip() {
        let cases: [(UInt32, UInt32, UInt32, UInt32, UInt32)] = [
            (0,  0,  0,  0,  0),
            (31, 31, 31, 31, 31),
            (5,  17, 22, 8,  13),
            (1,  2,  3,  4,  5),
        ]
        for (vx, vy, t, off, seed) in cases {
            let addr = QuantumAddress(vx: vx, vy: vy, t: t, offset: off, seed: seed)
            let unpacked = QuantumAddress(packed: addr.packed)
            XCTAssertEqual(unpacked, addr,
                "round-trip failed for (\(vx),\(vy),\(t),\(off),\(seed))")
            // 25-bit address must fit in the low 25 bits.
            XCTAssertLessThanOrEqual(addr.packed, (UInt32(1) << 25) - 1)
        }
    }

    // MARK: - Slice envelope serialization (deterministic, no encoder run)

    func testSliceEnvelopeHexRoundTrip() {
        let original = QuantumEnvelope(
            seedOffset: 7,
            messageLength: 12,
            keys: [0x12_3456, 0xAB_CDEF, 0x00_0001]
        )
        let hex = original.hexString
        guard let restored = QuantumEnvelope.fromHex(hex) else {
            XCTFail("fromHex returned nil for envelope hex \(hex)")
            return
        }
        XCTAssertEqual(restored.version,       original.version)
        XCTAssertEqual(restored.seedOffset,    original.seedOffset)
        XCTAssertEqual(restored.messageLength, original.messageLength)
        XCTAssertEqual(restored.keys,          original.keys)
    }

    // MARK: - Chain key serialization (deterministic, no encoder run)

    func testChainKeyHexRoundTrip() {
        let original = QuantumChainKey(
            bitCount: 16,
            messageLength: 2,
            seed: 3,
            vx: 0xDEAD_BEEF,
            vy: 0xCAFE_BABE,
            t:  0x1234_5678
        )
        let hex = original.hexString
        XCTAssertEqual(hex.count, 64, "chain key should serialize to 64 hex chars (32 bytes)")

        guard let restored = QuantumChainKey.fromHex(hex) else {
            XCTFail("fromHex returned nil for chain key hex \(hex)")
            return
        }
        XCTAssertEqual(restored, original)

        // Bad version byte should reject.
        let badVersion = "FF" + String(repeating: "00", count: 31)
        XCTAssertNil(QuantumChainKey.fromHex(badVersion))

        // Truncated should reject.
        XCTAssertNil(QuantumChainKey.fromHex("0102"))
    }

    // MARK: - JS bridge namespace shape (no encoder runs — just typeof probes)

    @MainActor
    func testJSBridgeNamespaceShape() {
        let env = JeffJSEnvironment()
        let probe = env.eval("""
        [
          typeof window.jeffjs.quantum.slice.encode,
          typeof window.jeffjs.quantum.slice.decode,
          typeof window.jeffjs.quantum.slice.encodeRaw,
          typeof window.jeffjs.quantum.slice.decodeRaw,
          typeof window.jeffjs.quantum.chain.encode,
          typeof window.jeffjs.quantum.chain.decode,
          typeof window.jeffjs.quantum.chain.encodeAsync,
          typeof window.jeffjs.quantum.chain.decodeAsync
        ].join(',');
        """)
        switch probe {
        case .success(let s):
            XCTAssertEqual(s, "function,function,function,function,function,function,function,function")
        case .exception(let msg):
            XCTFail("bridge probe threw: \(msg)")
        }
    }
}
