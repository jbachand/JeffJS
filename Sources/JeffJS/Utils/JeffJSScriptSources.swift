// JeffJSScriptSources.swift
// JeffJS — the evaluated text of every live script, by URL (weak).
//
// Each compiled script keeps its UTF-8 text alive as long as one of its
// functions lives (lazy compilation and Function.prototype.toString read it:
// JeffJSSourceText). This registry remembers, per script URL, a WEAK
// reference to that text, so a host can get the exact text an `Error.stack`
// frame's line:col refers to — after the app's rewrite passes, from a file
// mapping on a bytecode-cache hit — without a second fetch and without
// keeping anything alive (the JS unminifier in the app's console).
//
// Keys are the URL as stack frames print it (query and fragment stripped,
// `JeffJSContext.stackFrameURL`); placeholder names (`<inline>`, `<eval>`,
// ...) are not registered. Two scripts with one stripped URL: the later wins.
//
// Copyright 2026 Jeff Bachand. All rights reserved.

import Foundation

nonisolated public enum JeffJSScriptSources {

    private nonisolated final class WeakText {
        weak var text: JeffJSSourceText?
        init(_ t: JeffJSSourceText) { text = t }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var table: [String: WeakText] = [:]
    nonisolated(unsafe) private static var inserts = 0

    /// Called where a script's text is attached to its compiled code (fresh
    /// compile, bytecode-cache hit). Any thread.
    static func register(filename: String, text: JeffJSSourceText) {
        guard !filename.isEmpty, !(filename.hasPrefix("<") && filename.hasSuffix(">")) else { return }
        let key = JeffJSContext.stackFrameURL(filename)
        lock.lock(); defer { lock.unlock() }
        if let e = table[key], e.text === text { return }
        table[key] = WeakText(text)
        inserts += 1
        if inserts & 63 == 0 { table = table.filter { $0.value.text != nil } }
    }

    /// The UTF-8 text of the live script named `url` (a stack frame's URL;
    /// query / fragment ignored), or nil when no function of it is alive.
    /// The span keeps the bytes alive and is immutable: hand it to any
    /// thread. Call from the runtime's JS thread (the text may be re-homed
    /// into a file mapping there).
    public static func sourceBytes(forURL url: String) -> JeffJSBytesSpan? {
        let key = JeffJSContext.stackFrameURL(url)
        lock.lock(); defer { lock.unlock() }
        return table[key]?.text?.bytes
    }

    /// URLs with a live text (diagnostics).
    public static var liveURLs: [String] {
        lock.lock(); defer { lock.unlock() }
        return table.compactMap { $0.value.text != nil ? $0.key : nil }.sorted()
    }
}
