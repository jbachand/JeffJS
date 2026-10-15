import Foundation

// The actor the host-facing DOM bridges (DOM/, Environment/) are isolated to.
//
// By default its executor is the main actor's, so the engine behaves exactly as before
// (`@MainActor` on the bridges): the CLI, the tests and any host that does nothing see no
// change. A host that wants page JavaScript off its UI thread installs a serial executor
// once, before the first runtime is created (`JeffJSHost.install`); everything isolated to
// `JeffJSHostActor` then runs there and `Task { @JeffJSHostActor in … }` / `await` deliveries
// (fetch, WebSocket, storage events, dynamic import) land on that thread.
// Annotations and delivery hops only — no engine semantics depend on which thread this is.

public enum JeffJSHost {
    nonisolated(unsafe) private static var installed: (any SerialExecutor)?

    /// Installs the executor `JeffJSHostActor` runs on. Call once, before any runtime exists.
    public static func install(_ executor: any SerialExecutor) {
        installed = executor
    }

    /// True when `JeffJSHostActor` runs on the main actor's executor (nothing installed).
    public static var usesMainExecutor: Bool { installed == nil }

    nonisolated static var unownedExecutor: UnownedSerialExecutor {
        if let installed { return installed.asUnownedSerialExecutor() }
        return MainActor.sharedUnownedExecutor
    }
}

@globalActor
public actor JeffJSHostActor {
    public static let shared = JeffJSHostActor()
    public nonisolated var unownedExecutor: UnownedSerialExecutor { JeffJSHost.unownedExecutor }

    /// `MainActor.run` for this actor.
    public static func run<T: Sendable>(resultType: T.Type = T.self, body: @JeffJSHostActor @Sendable () throws -> T) async rethrows -> T {
        try await body()
    }

    /// `MainActor.assumeIsolated` for this actor (traps when not on its executor).
    public static func assumeIsolated<T>(_ operation: @JeffJSHostActor () throws -> T) rethrows -> T {
        typealias YesActor = @JeffJSHostActor () throws -> T
        typealias NoActor = () throws -> T
        JeffJSHostActor.shared.preconditionIsolated()
        return try withoutActuallyEscaping(operation) { (_ fn: @escaping YesActor) throws -> T in
            let rawFn = unsafeBitCast(fn, to: NoActor.self)
            return try rawFn()
        }
    }
}
