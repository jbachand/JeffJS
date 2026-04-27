// QuantumTransport.swift
// Quantum transport engine for encoding, transmitting, and decoding payloads.
//
// The key insight: only a small, fixed-size master key needs to travel over
// the wire. The receiver regenerates the identical qubit field deterministically
// and traces the chain to recover the original data. This decouples payload
// size from transmission cost -- a 1 KB message and a 1 byte message both
// produce the same-sized key set.
//
// Wire format (QuantumEnvelope):
//   - version:       UInt8   (protocol version, currently 1)
//   - seedOffset:    UInt32  (which qubit field generation was used)
//   - messageLength: UInt32  (original byte count)
//   - keyCount:      UInt8   (number of 25-bit master keys)
//   - keys:          [UInt32] (packed master keys)
//
// Total wire size for a short message: 1 + 4 + 4 + 1 + 4 = 14 bytes.

import Foundation

/// Compact wire-format envelope for quantum-encoded data.
struct QuantumEnvelope: Codable {
    static let protocolVersion: UInt8 = 1

    let version: UInt8
    let seedOffset: UInt32
    let messageLength: UInt32
    let keys: [UInt32]

    init(result: QuantumEncodeResult) {
        version       = Self.protocolVersion
        seedOffset    = UInt32(result.seedOffset)
        messageLength = UInt32(result.messageLength)
        keys          = result.keys
    }

    init(seedOffset: UInt32, messageLength: UInt32, keys: [UInt32]) {
        version            = Self.protocolVersion
        self.seedOffset    = seedOffset
        self.messageLength = messageLength
        self.keys          = keys
    }

    // MARK: - Binary Serialization

    /// Serialize to a compact binary representation.
    func serialize() -> Data {
        var data = Data()
        data.append(version)
        withUnsafeBytes(of: seedOffset.littleEndian)    { data.append(contentsOf: $0) }
        withUnsafeBytes(of: messageLength.littleEndian)  { data.append(contentsOf: $0) }
        data.append(UInt8(keys.count))
        for key in keys {
            withUnsafeBytes(of: key.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Deserialize from binary data.
    static func deserialize(from data: Data) -> QuantumEnvelope? {
        guard data.count >= 10 else { return nil }  // minimum: ver(1) + seed(4) + len(4) + count(1)

        var offset = 0
        let ver = data[offset]; offset += 1
        guard ver == protocolVersion else { return nil }

        let seed = data.subdata(in: offset ..< offset + 4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        offset += 4
        let msgLen = data.subdata(in: offset ..< offset + 4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        offset += 4
        let keyCount = Int(data[offset]); offset += 1

        guard data.count >= offset + keyCount * 4 else { return nil }

        var keys = [UInt32]()
        keys.reserveCapacity(keyCount)
        for _ in 0 ..< keyCount {
            let k = data.subdata(in: offset ..< offset + 4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            keys.append(k)
            offset += 4
        }

        return QuantumEnvelope(seedOffset: seed, messageLength: msgLen, keys: keys)
    }

    /// Hex string representation of the envelope (for text-based channels).
    var hexString: String {
        serialize().map { String(format: "%02x", $0) }.joined()
    }

    /// Parse from hex string.
    static func fromHex(_ hex: String) -> QuantumEnvelope? {
        var data = Data()
        var chars = hex.makeIterator()
        while let hi = chars.next(), let lo = chars.next() {
            guard let byte = UInt8(String([hi, lo]), radix: 16) else { return nil }
            data.append(byte)
        }
        return deserialize(from: data)
    }
}

// MARK: - Transport Engine

/// Encodes payloads into quantum envelopes for transmission and decodes
/// received envelopes back into the original data.
@MainActor
final class QuantumTransport {

    private let encoder = QuantumEncoder()
    private let decoder = QuantumDecoder()

    /// Maximum encoding attempts.
    var maxAttempts: Int = 100

    // MARK: - Send Path

    /// Encode a string into a compact envelope ready for transmission.
    func prepare(_ message: String) -> QuantumEnvelope? {
        guard let result = encoder.encode(message, maxAttempts: maxAttempts) else { return nil }
        return QuantumEnvelope(result: result)
    }

    /// Encode raw bytes into a compact envelope.
    func prepare(_ data: [UInt8]) -> QuantumEnvelope? {
        guard let result = encoder.encode(data, maxAttempts: maxAttempts) else { return nil }
        return QuantumEnvelope(result: result)
    }

    /// Encode and serialize to binary in one step.
    func send(_ message: String) -> Data? {
        prepare(message)?.serialize()
    }

    /// Encode and produce a hex string for text-based channels.
    func sendHex(_ message: String) -> String? {
        prepare(message)?.hexString
    }

    // MARK: - Receive Path

    /// Decode an envelope back to a string.
    func receive(envelope: QuantumEnvelope) -> String? {
        decoder.decodeString(
            keys: envelope.keys,
            messageLength: Int(envelope.messageLength),
            seedOffset: Int(envelope.seedOffset)
        )
    }

    /// Decode an envelope back to raw bytes.
    func receiveData(envelope: QuantumEnvelope) -> [UInt8] {
        decoder.decode(
            keys: envelope.keys,
            messageLength: Int(envelope.messageLength),
            seedOffset: Int(envelope.seedOffset)
        )
    }

    /// Decode from binary wire data.
    func receive(data: Data) -> String? {
        guard let env = QuantumEnvelope.deserialize(from: data) else { return nil }
        return receive(envelope: env)
    }

    /// Decode from hex string.
    func receive(hex: String) -> String? {
        guard let env = QuantumEnvelope.fromHex(hex) else { return nil }
        return receive(envelope: env)
    }
}
