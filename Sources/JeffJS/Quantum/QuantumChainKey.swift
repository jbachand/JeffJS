// QuantumChainKey.swift
// Single master key for the resolution-deepening chain encoder.
//
// Unlike the slice-based encoder (which produces multiple keys for long
// messages), the chain system encodes an N-bit message into ONE master key:
//
//   - vx, vy, t are each `bitCount` bits long.
//   - The MSB of each axis lives at level 1 (the "observable" coarse cell).
//   - Each subsequent bit zooms one octree step deeper.
//   - The full N-bit values are the deepest leaf: that's the master key.
//
// Decoding walks UP the octree by truncating one bit per axis per step;
// encoding walks DOWN by extending one bit per axis per step.

import Foundation

/// A single-key chain master key. Encodes an arbitrary-length message
/// (within the precision floor — see `QuantumChainEncoder.maxBits`) by
/// burying it in a deep octree address.
struct QuantumChainKey: Codable, Equatable {
    /// Number of message bits encoded (also = depth of the octree).
    let bitCount: Int
    /// Original message length in bytes (so the decoder can strip bit-padding).
    let messageLength: Int
    /// Field seed used to generate the qubit positions.
    let seed: UInt32
    /// vx coordinate, `bitCount` bits wide. Bit 0 (LSB) lives at level 1
    /// (the observable end); bit `bitCount-1` (MSB) is the master-key bit.
    let vx: UInt64
    /// vy coordinate, `bitCount` bits wide.
    let vy: UInt64
    /// t coordinate, `bitCount` bits wide.
    let t: UInt64

    // MARK: - Binary Serialization
    //
    // Wire format (16 bytes total):
    //   - version       : UInt8  (1)
    //   - bitCount      : UInt8  (≤ 64)
    //   - messageLength : UInt16 (≤ 65535 bytes)
    //   - seed          : UInt32
    //   - vx            : UInt64
    //   - vy            : UInt64
    //   - t             : UInt64
    // = 1 + 1 + 2 + 4 + 8 + 8 + 8 = 32 bytes / 64 hex chars

    static let protocolVersion: UInt8 = 1

    func serialize() -> Data {
        var data = Data()
        data.reserveCapacity(32)
        data.append(Self.protocolVersion)
        data.append(UInt8(bitCount))
        withUnsafeBytes(of: UInt16(messageLength).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: seed.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: vx.littleEndian)   { data.append(contentsOf: $0) }
        withUnsafeBytes(of: vy.littleEndian)   { data.append(contentsOf: $0) }
        withUnsafeBytes(of: t.littleEndian)    { data.append(contentsOf: $0) }
        return data
    }

    static func deserialize(from data: Data) -> QuantumChainKey? {
        guard data.count >= 32 else { return nil }
        var offset = 0

        guard data[offset] == protocolVersion else { return nil }
        offset += 1

        let bitCount = Int(data[offset]); offset += 1

        let msgLen = data.subdata(in: offset ..< offset + 2)
            .withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
        offset += 2

        let seed = data.subdata(in: offset ..< offset + 4)
            .withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        offset += 4

        let vx = data.subdata(in: offset ..< offset + 8)
            .withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        offset += 8

        let vy = data.subdata(in: offset ..< offset + 8)
            .withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        offset += 8

        let t = data.subdata(in: offset ..< offset + 8)
            .withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }

        return QuantumChainKey(
            bitCount: bitCount,
            messageLength: Int(msgLen),
            seed: seed,
            vx: vx, vy: vy, t: t
        )
    }

    var hexString: String {
        serialize().map { String(format: "%02x", $0) }.joined()
    }

    static func fromHex(_ hex: String) -> QuantumChainKey? {
        var data = Data()
        var iter = hex.makeIterator()
        while let hi = iter.next(), let lo = iter.next() {
            guard let byte = UInt8(String([hi, lo]), radix: 16) else { return nil }
            data.append(byte)
        }
        return deserialize(from: data)
    }
}
