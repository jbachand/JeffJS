# Quantum — Claude neuron

> Area: `Sources/JeffJS/Quantum/` · Repo: engine · Last reviewed: 2026-11-02 (app 20c9d08 / engine 1bcbde2)

## Purpose
Two things exposed to JavaScript as `window.jeffjs.quantum` from any `JeffJSEnvironment` (step 17 of its init):
(1) an experimental **procedural-field data encoder** (`.slice` / `.chain`: data stored as master keys into a
deterministic field of 256 moving "qubits" — a teaching artifact about locality, explicitly *not* crypto or
compression) and (2) a **quantum circuit simulator** (`.simulator`: state vector on CPU, Metal for 18+ qubits,
stabilizer tableau for Clifford-only circuits; Shor, Deutsch-Jozsa, Bernstein-Vazirani, teleportation, superdense
coding, error correction, CHSH/GHZ). The React Natively page engine never registers it; the JeffJSConsole apps do.

## Key files
- `JeffJSQuantumBridge.swift` — `register(on:)`: `window.jeffjs` namespace (`version`, `quantum.enabled` = `JeffJSConfig.quantumEnabled`), `registerSlice` / `registerChain` (sync + Promise-based `encodeAsync`/`decodeAsync`, fetch-bridge style resolve/reject natives), installs the simulator sub-namespace.
- `QuantumSimulatorBridge.swift` — the `.simulator` JS API (createCircuit/gate/measure, createStabilizer/stab*, the algorithm Promises); the only actor-confined piece of the simulator.
- `QuantumCircuit.swift`, `QuantumState.swift`, `QuantumAlgorithms.swift`, `QuantumBellCHSH.swift`, `QuantumStabilizer.swift`, `QuantumCliffordT.swift` — the CPU simulators; `QuantumSimulatorGPU.swift` — Metal state-vector gates (`../Resources/QuantumSimulator.metal`).
- `QuantumConfig.swift` (`QuantumConstants`: 25-bit address layout, 256 qubits), `QuantumQubit.swift`, `QuantumAddress.swift`, `QuantumEncoder.swift` / `QuantumDecoder.swift` (slice), `QuantumChain{Key,Field,Encoder,Decoder}.swift` (resolution-deepening chain), `QuantumCache.swift`, `QuantumTransport.swift`, `QuantumGPU.swift` (Metal slice/exact/search-and-trace kernels, `../Resources/QuantumSearch.metal`).
- Non-Swift: `README.md` (the long explanation), `paper.md` / `paper-engineer.md` (+ PDFs, built by `build_paper.sh` + `typeset_math.py`, see `PAPER_BUILD.md`), `experiments.md`, the `*.py` prototypes (`chsh_*`, `ghz_simulator`, `stabilizer_sim`, `shor_*`, `quantum_algorithms`, visualisations) and their `*.png`/`*.gif`, `sha.zip`.

## Invariants
- **A new non-Swift file here must be added to two exclude lists**: `Package.swift` `exclude:` (SwiftPM warns about every unhandled file in a target with `resources:`) and the "React Natively Watch" `PBXFileSystemSynchronizedBuildFileExceptionSet` for `Vendor/JeffJS/Sources/JeffJS` in the app's pbxproj (which also excludes every `Resources/*` file — no Metal on the watch). The phone target has no such exceptions for `Quantum/`.
- All Metal paths are `#if canImport(Metal)` with a CPU fallback; the simulator's GPU path must still produce the CPU result (`Tests/JeffJSTests/QuantumTests.swift` round-trips slice and chain encoders).
- Everything is `nonisolated` except the two bridges, which follow `JeffJSFetchBridge`'s pattern: background `Task`, then `await JeffJSHostActor.run` to settle the JS promise — never touch the context from the worker.
- The whole subsystem is gated on `quantum.enabled` (`true` in both shipped plists, `false` in code) and `quantum.preferGPU`; `quantum.dataBits` / `maxChainValues` / `maxEncodeAttempts` tune the encoder (`JeffJSConfig`).

## Gotchas
- `chain.encode` is synchronous and bounded (≤ 10 s; one master key, input ≤ 6 chars); use the `*Async` forms from pages.
- `sha.zip` is in the Xcode exception set but **not** in `Package.swift`'s `exclude:` (the only Quantum file in one list and not the other).
- The papers' build chain needs `pandoc` + `tectonic` (first run downloads ~50 MB); it is not part of any Swift build.

## Patterns to follow
- New simulator ops: Swift in a `Quantum*.swift` file, a native in `QuantumSimulatorBridge.swift`, a README row; keep the CPU path authoritative and the Metal kernel an accelerator of it.
- Prototype in Python here first (the `*.py` files are the record), then port; remember both exclude lists.

## Debug switches
- `JEFFJS_QUANTUM_ENABLED=0` / `JEFFJS_QUANTUM_PREFERGPU=0` — env overrides of the config keys (no dedicated debug logging here).

## Cross-area links
- [Environment](../Environment/CLAUDE.md) — where the bridge is registered (always, enabled flag mirrored).
- [Config](../Config/CLAUDE.md) — `quantum.*` keys, `Resources/` shaders and the plist-override rule.
- [DOM](../DOM/CLAUDE.md) — `JeffJSFetchBridge`, the async-native pattern the bridges copy.
- [React Natively app](../../../../../CLAUDE.md) — "Apple Watch target" (the watch exception set this folder is part of).

## Deep docs
- [`README.md`](README.md) — concept, the two encoders, GPU acceleration, usage; [`PAPER_BUILD.md`](PAPER_BUILD.md), [`paper.md`](paper.md), [`experiments.md`](experiments.md).
- [engine `README.md` § "The Quantum module"](../../../README.md) — the JS examples (Shor on the wrist).

## Suspected dead code
- None found (searched: `grep -rn "QuantumSimulatorBridge\|JeffJSQuantumBridge" Sources` → registered from `Environment/JeffJSEnvironment.swift`; the Python/markdown files are deliberately excluded sources, not code).

## Suspected stale
None (the root CLAUDE.md only mentions this folder in the watch target's exception set, verified in the pbxproj).
