// DynamicImportCheckpointTests.swift
// JeffJS — `await import(x)` of a module that has to load resumes with no timer on the page
// (HTML §8.1.7.3 "perform a microtask checkpoint" after the task that settles the import).
// JeffJSDynamicImportBridge settles the promise from a Swift Task; without a checkpoint after it
// the reactions waited for some unrelated later task — forever on RendererModuleTest once the
// app stopped bundling import() targets with their importer (homedepot agent, 2026-09-30).
//
// Usage:
//   swift test --filter DynamicImportCheckpointTests

import XCTest
@testable import JeffJS

@JeffJSHostActor
final class DynamicImportCheckpointTests: XCTestCase {

    /// Serves every module URL as a one-line bundle exporting `v = 7`.
    final class Loader: JeffJSDynamicImportDelegate {
        weak var env: JeffJSEnvironment?
        var baseURL: URL? { URL(string: "https://example.test/page.html") }
        var userAgent: String { "test" }
        var jsContext: JeffJSContext? { env?.context }
        func buildModuleBundle(entryURL: URL, visited: Set<URL>, userAgent: String) async throws -> (bundle: String, visited: Set<URL>) {
            ("window.__nativeModules = window.__nativeModules || {}; window.__nativeModules['\(entryURL.absoluteString)'] = { v: 7 };", visited)
        }
        func cacheModuleBundle(_ bundle: String, for url: URL) {}
    }

    func testAwaitImportResumesWithoutATimer() async {
        let loader = Loader()
        let env = JeffJSEnvironment(configuration: .init(baseURL: URL(string: "https://example.test/page.html")!,
                                                         storageScope: "jeffjs.dynimport.\(UUID().uuidString)",
                                                         dynamicImportDelegate: loader))
        loader.env = env
        _ = env.eval("""
        window.__r = 'pending';
        (async function(){ var ns = await __dynamicImport('https://example.test/m.js', ''); window.__r = 'v=' + ns.v; })();
        __dynamicImport('https://example.test/n.js', '').then(function(ns){ window.__t = 'then ' + ns.v; });
        """)
        // Read without a microtask checkpoint (env.eval drains the queue after every script, which
        // would hide the bug): only the bridge's Task may run the reactions.
        func peek() -> String {
            let ctx = env.context
            let g = ctx.getGlobalObject()
            defer { g.freeValue() }
            let r = ctx.getPropertyStr(obj: g, name: "__r"), t = ctx.getPropertyStr(obj: g, name: "__t")
            defer { r.freeValue(); t.freeValue() }
            return (ctx.toSwiftString(r) ?? "?") + "|" + (ctx.toSwiftString(t) ?? "?")
        }
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if peek() == "v=7|then 7" { return }
        }
        XCTFail("await import() did not resume: \(peek())")
    }
}
