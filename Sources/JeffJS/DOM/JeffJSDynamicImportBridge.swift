// JeffJSDynamicImportBridge.swift
// JeffJS Dynamic Import Bridge — Registers __nativeDynamicImport on a JeffJS context.
//
// When JS calls __nativeDynamicImport(specifier, callerURL, resolveID, rejectID),
// this bridge resolves the module URL, fetches and bundles the module tree off
// the main thread, evaluates the bundle in JeffJS, and resolves the promise.

import Foundation

// MARK: - Dynamic Import Delegate

/// Protocol for providing module bundling to the dynamic import bridge.
/// The host app (e.g. rendering engine) conforms to this to supply
/// module fetching, bundling, and caching.
@MainActor
public protocol JeffJSDynamicImportDelegate: AnyObject {
    var baseURL: URL? { get }
    var userAgent: String { get }
    var jsContext: JeffJSContext? { get }
    func buildModuleBundle(entryURL: URL, visited: Set<URL>, userAgent: String) async throws -> (bundle: String, visited: Set<URL>)
    func cacheModuleBundle(_ bundle: String, for url: URL)
}

// MARK: - JeffJSDynamicImportBridge

/// Bridges dynamic `import()` calls from JeffJS to the native module loader.
///
/// Usage:
/// ```swift
/// let bridge = JeffJSDynamicImportBridge(delegate: myDelegate)
/// bridge.register(on: ctx)
/// ```
@MainActor
final class JeffJSDynamicImportBridge {

    // MARK: - State

    /// Weak reference to the delegate for access to the module
    /// bundler, caches, and eval pipeline.
    private weak var delegate: JeffJSDynamicImportDelegate?

    // MARK: - Init

    init(delegate: JeffJSDynamicImportDelegate) {
        self.delegate = delegate
    }

    // MARK: - Registration

    /// Registers `__nativeDynamicImport` as a native function on the JeffJS
    /// global object and evaluates a small JS wrapper that makes
    /// `window.__dynamicImport(specifier, callerURL)` return a Promise.
    func register(on ctx: JeffJSContext) {
        let global = ctx.getGlobalObject()

        // Register the native handler.
        // JS calls: __nativeDynamicImport(specifier, callerURL, resolve, reject)
        // where resolve/reject are JS callback functions from a Promise executor.
        ctx.setPropertyFunc(obj: global, name: "__nativeDynamicImport", fn: { [weak self] ctx, thisVal, args in
            guard let self, let delegate = self.delegate else {
                // Delegate deallocated — call reject if available
                if args.count >= 4 {
                    _ = ctx.call(args[3], this: .undefined,
                                args: [ctx.newStringValue("Engine deallocated")])
                }
                return JeffJSValue.undefined
            }

            // Extract arguments
            let specifier = ctx.toSwiftString(args.count > 0 ? args[0] : .undefined) ?? ""
            let callerModuleURL = ctx.toSwiftString(args.count > 1 ? args[1] : .undefined) ?? ""
            let resolve = args.count > 2 ? args[2] : JeffJSValue.undefined
            let reject = args.count > 3 ? args[3] : JeffJSValue.undefined

            // Dup the callbacks so they survive across the async gap
            let resolveRef = resolve.dupValue()
            let rejectRef = reject.dupValue()

            // Resolve the URL
            let callerURL = URL(string: callerModuleURL) ?? delegate.baseURL ?? URL(string: "about:blank")!
            guard let resolvedURL = Self.resolveImportSpecifier(specifier, moduleURL: callerURL) else {
                _ = ctx.call(rejectRef, this: .undefined,
                             args: [ctx.newStringValue("Cannot resolve module specifier: \(specifier)")])
                rejectRef.freeValue()
                resolveRef.freeValue()
                return JeffJSValue.undefined
            }

            // Block remote imports if security flag is enabled
            if JeffJSConfig.blockRemoteImports {
                let scheme = resolvedURL.scheme?.lowercased() ?? ""
                if scheme == "http" || scheme == "https" {
                    _ = ctx.call(rejectRef, this: .undefined,
                                 args: [ctx.newStringValue("Remote imports are disabled (security.blockRemoteImports is enabled). Cannot import '\(specifier)' — only local/relative module paths are allowed.")])
                    rejectRef.freeValue()
                    resolveRef.freeValue()
                    return JeffJSValue.undefined
                }
            }

            let urlString = resolvedURL.absoluteString

            // Check if already loaded in __nativeModules
            let checkResult = ctx.eval(
                input: "window.__nativeModules && window.__nativeModules['\(Self.escapeJSString(urlString))']",
                filename: "<import-check>",
                evalFlags: JS_EVAL_TYPE_GLOBAL
            )
            if !checkResult.isUndefined && !checkResult.isNull && !checkResult.isException {
                _ = ctx.call(resolveRef, this: .undefined, args: [checkResult])
                resolveRef.freeValue()
                rejectRef.freeValue()
                return JeffJSValue.undefined
            }

            // Fetch, bundle, and evaluate asynchronously
            let userAgent = delegate.userAgent
            Task { @MainActor [weak delegate] in
                guard let delegate, let jsCtx = delegate.jsContext else {
                    resolveRef.freeValue()
                    rejectRef.freeValue()
                    return
                }
                do {
                    let (bundle, _) = try await Task.detached(priority: .userInitiated) {
                        try await delegate.buildModuleBundle(
                            entryURL: resolvedURL, visited: [],
                            userAgent: userAgent
                        )
                    }.value
                    delegate.cacheModuleBundle(bundle, for: resolvedURL)

                    // Evaluate the bundle in JeffJS
                    let evalResult = jsCtx.eval(input: bundle, filename: resolvedURL.lastPathComponent, evalFlags: JS_EVAL_TYPE_GLOBAL)
                    if evalResult.isException {
                        let exc = jsCtx.getException()
                        let errMsg = jsCtx.toSwiftString(exc) ?? "Module evaluation failed"
                        exc.freeValue()
                        _ = jsCtx.call(rejectRef, this: .undefined,
                                       args: [jsCtx.newStringValue("Failed to load module: \(errMsg)")])
                    } else {
                        // Retrieve the module exports
                        let exportsResult = jsCtx.eval(
                            input: "window.__nativeModules['\(Self.escapeJSString(urlString))'] || {}",
                            filename: "<import-resolve>",
                            evalFlags: JS_EVAL_TYPE_GLOBAL
                        )
                        _ = jsCtx.call(resolveRef, this: .undefined, args: [exportsResult])
                    }
                } catch {
                    _ = jsCtx.call(rejectRef, this: .undefined,
                                   args: [jsCtx.newStringValue("Failed to load module: \(error.localizedDescription)")])
                }
                resolveRef.freeValue()
                rejectRef.freeValue()
            }

            return JeffJSValue.undefined
        }, length: 4)

        // Install the JS-side __dynamicImport wrapper that returns a Promise.
        // This replaces the stub installed during JeffJS init.
        _ = ctx.eval(input: """
            window.__dynamicImport = function(specifier, callerURL) {
                return new Promise(function(resolve, reject) {
                    __nativeDynamicImport(specifier, callerURL || '', resolve, reject);
                });
            };
            """, filename: "<dynamic-import-bridge>", evalFlags: JS_EVAL_TYPE_GLOBAL)
    }

    // MARK: - URL Resolution

    /// Resolves a module specifier relative to the caller's module URL.
    nonisolated private static func resolveImportSpecifier(_ specifier: String, moduleURL: URL) -> URL? {
        let trimmed = specifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        if trimmed.hasPrefix("//"), let scheme = moduleURL.scheme {
            return URL(string: "\(scheme):\(trimmed)")
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix(".") {
            return URL(string: trimmed, relativeTo: moduleURL)?.absoluteURL
        }

        // Bare specifier fallback for common ESM packages.
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        return URL(string: "https://esm.sh/\(encoded)")
    }

    /// Escapes a string for safe embedding in JS single-quoted strings.
    nonisolated private static func escapeJSString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
