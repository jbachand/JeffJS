// JeffJSFetchBody.swift
// JeffJS — binary body plumbing for the fetch/XHR bridge.
//
// Converts between JS values and raw bytes in both directions:
//   * request bodies: String | ArrayBuffer | TypedArray | DataView |
//     Blob-like `{ __blobParts: [...], type }` | FormData-like `{ __formEntries: [...] }`
//   * response bodies: an ArrayBuffer-backed JS value plus lazily decoded text
//     (UTF-8 with BOM handling, charset from Content-Type when recognised).
//
// Ownership (docs/PERFORMANCE_PLAN.md Round 9): every `ctx.getPropertyStr` /
// `ctx.toObject()` result below is owned and released on all paths; values
// stored into a JS object are dup'd by the setter, values returned are owned
// by the caller.

import Foundation

// MARK: - ArrayBuffer <-> [UInt8]

extension JeffJSContext {

    /// Create a real JS `ArrayBuffer` holding `bytes`.
    func newArrayBufferValue(bytes: [UInt8]) -> JeffJSValue {
        let ab = JeffJSArrayBuffer(byteLength: bytes.count)
        ab.data = bytes
        var abProto: JeffJSObject? = nil
        let abClassID = Int(JSClassID.JS_CLASS_ARRAY_BUFFER.rawValue)
        if abClassID < classProto.count {
            let protoVal = classProto[abClassID]
            if protoVal.isObject { abProto = protoVal.toObject() }
        }
        let obj = jeffJS_createObject(ctx: self, proto: abProto,
                                      classID: UInt16(JeffJSClassID.arrayBuffer.rawValue))
        obj.payload = JeffJSObjectPayload.arrayBuffer(ab)
        return .makeObject(obj)
    }

    /// Bytes behind an `ArrayBuffer`, a TypedArray or a `DataView`
    /// (honouring byteOffset/byteLength). Returns nil for anything else.
    func arrayBufferBytes(of value: JeffJSValue) -> [UInt8]? {
        guard value.isObject, let obj = value.toObject() else { return nil }
        if obj.classID == JeffJSClassID.arrayBuffer.rawValue
            || obj.classID == JeffJSClassID.sharedArrayBuffer.rawValue {
            if case .arrayBuffer(let ab) = obj.payload {
                return ab.detached ? [] : Array(ab.data.prefix(ab.byteLength))
            }
            return nil
        }
        if case .typedArray(let ta) = obj.payload,
           let bufObj = ta.buffer, case .arrayBuffer(let ab) = bufObj.payload, !ab.detached {
            let lo = min(ta.byteOffset, ab.data.count)
            let hi = min(ta.byteOffset + ta.byteLength, ab.data.count)
            return lo <= hi ? Array(ab.data[lo..<hi]) : []
        }
        return nil
    }
}

// MARK: - Charset / text decoding

enum JeffJSFetchText {

    /// `charset=` parameter of a Content-Type value, lowercased, or nil.
    static func charset(fromContentType contentType: String?) -> String? {
        guard let contentType else { return nil }
        for part in contentType.split(separator: ";").dropFirst() {
            let kv = part.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if kv.count == 2, kv[0].lowercased() == "charset" {
                return kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
            }
        }
        return nil
    }

    /// The media type (before any `;`), lowercased.
    static func mimeType(fromContentType contentType: String?) -> String {
        guard let contentType else { return "" }
        return String(contentType.split(separator: ";").first ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func encoding(forCharset charset: String?) -> String.Encoding? {
        guard let charset else { return nil }
        switch charset {
        case "utf-8", "utf8", "unicode-1-1-utf-8", "us-ascii", "ascii":
            return .utf8
        case "iso-8859-1", "latin1", "latin-1", "iso8859-1", "iso_8859-1", "windows-1252", "cp1252":
            return .windowsCP1252
        case "utf-16", "utf16":       return .utf16
        case "utf-16le", "utf16le":   return .utf16LittleEndian
        case "utf-16be", "utf16be":   return .utf16BigEndian
        case "windows-1251", "cp1251": return .windowsCP1251
        case "iso-8859-2":            return .isoLatin2
        case "shift_jis", "shift-jis", "sjis": return .shiftJIS
        case "euc-jp":                return .japaneseEUC
        default:                      return nil
        }
    }

    /// Decode response bytes: BOM wins, then the Content-Type charset, then
    /// UTF-8, then a lossy CP1252 fallback so text is never silently lost.
    static func decode(bytes: [UInt8], charset: String?) -> String {
        if bytes.isEmpty { return "" }
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return String(decoding: bytes.dropFirst(3), as: UTF8.self)
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
            return String(data: Data(bytes.dropFirst(2)), encoding: .utf16LittleEndian) ?? ""
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            return String(data: Data(bytes.dropFirst(2)), encoding: .utf16BigEndian) ?? ""
        }
        let data = Data(bytes)
        if let enc = encoding(forCharset: charset), let s = String(data: data, encoding: enc) {
            return s
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .windowsCP1252) ?? ""
    }

    /// True for media types whose bytes are not worth decoding into the
    /// legacy `body` string.
    static func isBinaryMime(_ mime: String) -> Bool {
        if mime.isEmpty { return false }
        if mime.hasPrefix("image/") || mime.hasPrefix("audio/")
            || mime.hasPrefix("video/") || mime.hasPrefix("font/") { return true }
        switch mime {
        case "application/octet-stream", "application/pdf", "application/zip",
             "application/gzip", "application/wasm", "application/x-protobuf":
            return true
        default:
            return false
        }
    }
}

// MARK: - Request body extraction

/// Bytes plus the Content-Type the body implies (nil = caller's header wins).
struct JeffJSFetchBodyData {
    var bytes: [UInt8]
    var contentType: String?
}

enum JeffJSFetchBodyExtractor {

    /// Extract request-body bytes from a JS value.
    ///
    /// Accepted shapes:
    ///   * `String`                      -> UTF-8, `text/plain;charset=UTF-8`
    ///   * `ArrayBuffer`/TypedArray/`DataView` -> raw bytes, no Content-Type
    ///   * `{ __blobParts: [...], type }`      -> concatenated parts, `type`
    ///   * `{ __formEntries: [...] }`          -> multipart/form-data
    ///   * `{ __urlSearchParams: "a=b&c=d" }`  -> form-urlencoded
    ///   * anything else                        -> `String(value)`
    static func extract(ctx: JeffJSContext, value: JeffJSValue) -> JeffJSFetchBodyData? {
        if value.isUndefined || value.isNull { return nil }

        if value.isString {
            let s = ctx.toSwiftString(value) ?? ""
            return JeffJSFetchBodyData(bytes: Array(s.utf8),
                                       contentType: "text/plain;charset=UTF-8")
        }

        if let bytes = ctx.arrayBufferBytes(of: value) {
            return JeffJSFetchBodyData(bytes: bytes, contentType: nil)
        }

        if value.isObject {
            // FormData-like: `__formEntries`, or the host app's `_entries`
            // ([{ name, value, filename }]).
            let entries = ctx.getPropertyStr(obj: value, name: "__formEntries")
            defer { entries.freeValue() }
            if entries.isObject {
                return multipart(ctx: ctx, entries: entries)
            }
            let altEntries = ctx.getPropertyStr(obj: value, name: "_entries")
            defer { altEntries.freeValue() }
            if altEntries.isObject, looksLikeFormEntries(ctx: ctx, altEntries) {
                return multipart(ctx: ctx, entries: altEntries)
            }
            // Blob-like: `__blobParts`, or the host app's `parts` (guarded by
            // the Blob-ish `size`/`type` properties so a random object with a
            // `parts` field is not mistaken for a Blob).
            let parts = ctx.getPropertyStr(obj: value, name: "__blobParts")
            defer { parts.freeValue() }
            let altParts = ctx.getPropertyStr(obj: value, name: "parts")
            defer { altParts.freeValue() }
            let blobParts: JeffJSValue? = parts.isObject ? parts
                : (altParts.isObject && looksLikeBlob(ctx: ctx, value) ? altParts : nil)
            if let blobParts {
                let typeVal = ctx.getPropertyStr(obj: value, name: "type")
                defer { typeVal.freeValue() }
                let type = ctx.toSwiftString(typeVal) ?? ""
                return JeffJSFetchBodyData(bytes: blobBytes(ctx: ctx, parts: blobParts),
                                           contentType: type.isEmpty ? nil : type)
            }
            // URLSearchParams-like
            let usp = ctx.getPropertyStr(obj: value, name: "__urlSearchParams")
            defer { usp.freeValue() }
            if usp.isString {
                let s = ctx.toSwiftString(usp) ?? ""
                return JeffJSFetchBodyData(
                    bytes: Array(s.utf8),
                    contentType: "application/x-www-form-urlencoded;charset=UTF-8")
            }
        }

        let s = ctx.toSwiftString(value) ?? ""
        return JeffJSFetchBodyData(bytes: Array(s.utf8),
                                   contentType: "text/plain;charset=UTF-8")
    }

    /// `{ _entries: [{ name, value }] }` — the FormData shape used by the
    /// host app's own polyfill.
    private static func looksLikeFormEntries(ctx: JeffJSContext, _ entries: JeffJSValue) -> Bool {
        guard ctx.getArrayLength(entries) > 0 else { return false }
        let first = ctx.getPropertyUint32(obj: entries, index: 0)
        defer { first.freeValue() }
        guard first.isObject else { return false }
        let name = ctx.getPropertyStr(obj: first, name: "name")
        defer { name.freeValue() }
        return !name.isUndefined
    }

    /// `{ parts: [...], size|type }` — the Blob shape used by the host app.
    private static func looksLikeBlob(ctx: JeffJSContext, _ value: JeffJSValue) -> Bool {
        let size = ctx.getPropertyStr(obj: value, name: "size")
        defer { size.freeValue() }
        if !size.isUndefined { return true }
        let type = ctx.getPropertyStr(obj: value, name: "type")
        defer { type.freeValue() }
        return type.isString
    }

    /// Flatten `__blobParts` (strings, ArrayBuffers, TypedArrays, nested blobs).
    private static func blobBytes(ctx: JeffJSContext, parts: JeffJSValue) -> [UInt8] {
        var out: [UInt8] = []
        let len = Int(ctx.getArrayLength(parts))
        for i in 0..<max(0, len) {
            let part = ctx.getPropertyUint32(obj: parts, index: UInt32(i))
            defer { part.freeValue() }
            if part.isString {
                out.append(contentsOf: Array((ctx.toSwiftString(part) ?? "").utf8))
            } else if let bytes = ctx.arrayBufferBytes(of: part) {
                out.append(contentsOf: bytes)
            } else if part.isObject {
                let nested = ctx.getPropertyStr(obj: part, name: "__blobParts")
                defer { nested.freeValue() }
                if nested.isObject {
                    out.append(contentsOf: blobBytes(ctx: ctx, parts: nested))
                } else {
                    out.append(contentsOf: Array((ctx.toSwiftString(part) ?? "").utf8))
                }
            }
        }
        return out
    }

    /// Build a `multipart/form-data` body from FormData-like entries:
    /// `[{ name, value }]` where `value` is a string, or a file part
    /// `{ name, filename, type, value: <bytes|blob-like|string> }`.
    private static func multipart(ctx: JeffJSContext, entries: JeffJSValue) -> JeffJSFetchBodyData {
        let boundary = "----JeffJSFormBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var out: [UInt8] = []
        let crlf = Array("\r\n".utf8)

        let count = Int(ctx.getArrayLength(entries))
        for i in 0..<max(0, count) {
            let entry = ctx.getPropertyUint32(obj: entries, index: UInt32(i))
            defer { entry.freeValue() }
            guard entry.isObject else { continue }

            let nameVal = ctx.getPropertyStr(obj: entry, name: "name")
            defer { nameVal.freeValue() }
            let name = ctx.toSwiftString(nameVal) ?? ""

            let valueVal = ctx.getPropertyStr(obj: entry, name: "value")
            defer { valueVal.freeValue() }

            // Explicit filename on the entry, else the blob's own `name`.
            let fnVal = ctx.getPropertyStr(obj: entry, name: "filename")
            defer { fnVal.freeValue() }
            var filename = fnVal.isString ? (ctx.toSwiftString(fnVal) ?? "") : ""
            if filename.isEmpty, valueVal.isObject {
                let blobName = ctx.getPropertyStr(obj: valueVal, name: "name")
                defer { blobName.freeValue() }
                if blobName.isString { filename = ctx.toSwiftString(blobName) ?? "" }
            }

            let typeVal = ctx.getPropertyStr(obj: entry, name: "type")
            defer { typeVal.freeValue() }
            var partType = typeVal.isString ? (ctx.toSwiftString(typeVal) ?? "") : ""

            var partBytes: [UInt8]
            if valueVal.isString {
                partBytes = Array((ctx.toSwiftString(valueVal) ?? "").utf8)
            } else if let bytes = ctx.arrayBufferBytes(of: valueVal) {
                partBytes = bytes
                if filename.isEmpty { filename = "blob" }
            } else if valueVal.isObject {
                let parts = ctx.getPropertyStr(obj: valueVal, name: "__blobParts")
                defer { parts.freeValue() }
                if parts.isObject {
                    partBytes = blobBytes(ctx: ctx, parts: parts)
                    if partType.isEmpty {
                        let bt = ctx.getPropertyStr(obj: valueVal, name: "type")
                        defer { bt.freeValue() }
                        partType = ctx.toSwiftString(bt) ?? ""
                    }
                    if filename.isEmpty { filename = "blob" }
                } else {
                    partBytes = Array((ctx.toSwiftString(valueVal) ?? "").utf8)
                }
            } else {
                partBytes = Array((ctx.toSwiftString(valueVal) ?? "").utf8)
            }

            out.append(contentsOf: Array("--\(boundary)\r\n".utf8))
            var disposition = "Content-Disposition: form-data; name=\"\(escapeHeader(name))\""
            if !filename.isEmpty {
                disposition += "; filename=\"\(escapeHeader(filename))\""
            }
            out.append(contentsOf: Array(disposition.utf8))
            out.append(contentsOf: crlf)
            if !filename.isEmpty || !partType.isEmpty {
                let ct = partType.isEmpty ? "application/octet-stream" : partType
                out.append(contentsOf: Array("Content-Type: \(ct)\r\n".utf8))
            }
            out.append(contentsOf: crlf)
            out.append(contentsOf: partBytes)
            out.append(contentsOf: crlf)
        }
        out.append(contentsOf: Array("--\(boundary)--\r\n".utf8))

        return JeffJSFetchBodyData(bytes: out,
                                   contentType: "multipart/form-data; boundary=\(boundary)")
    }

    private static func escapeHeader(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}
