// JeffJSHeapDebug.swift
// Tooling hooks for jeffjs-cli's heap reports (--orphans, --heap-report):
// describe an engine instance found by a malloc-zone walk without the tool
// needing the engine's internal types.

import Foundation

nonisolated public enum JeffJSHeapDebug {
    /// Text (truncated) and refcount of the JeffJSString at `p`, or nil when
    /// `p` is not a flat JeffJSString.
    public static func describeString(at p: UnsafeRawPointer) -> String? {
        let any = Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue()
        guard let s = any as? JeffJSString else { return nil }
        let text = s.toSwiftString()
        return "rc=\(s.refCount) len=\(s.len) \"\(text.prefix(60).replacingOccurrences(of: "\n", with: "\\n"))\""
    }

    /// Class id, refcount and shape of the JeffJSObject at `p`.
    public static func describeObject(at p: UnsafeRawPointer) -> String? {
        let any = Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue()
        guard let o = any as? JeffJSObject else { return nil }
        return "class=\(o.classID) rc=\(o.refCount) props=\(o.propValues.count) listed=\(o.gcListIndex != -1)"
    }
}
