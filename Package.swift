// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JeffJS",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .watchOS(.v9),
        .tvOS(.v16),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "JeffJS", targets: ["JeffJS"]),
    ],
    targets: [
        .target(
            name: "JeffJS",
            path: "Sources/JeffJS",
            exclude: [
                "Quantum/README.md",
                "Quantum/PAPER_BUILD.md",
                "Quantum/paper.md",
                "Quantum/paper.pdf",
                "Quantum/paper-engineer.md",
                "Quantum/paper-engineer.pdf",
                "Quantum/experiments.md",
                "Quantum/chsh_prototype.py",
                "Quantum/chsh_correlation_plot.py",
                "Quantum/ghz_simulator.py",
                "Quantum/stabilizer_sim.py",
                "Quantum/quantum_algorithms.py",
                "Quantum/shor_factor_15.py",
                "Quantum/shor_general.py",
                "Quantum/shor_fast.py",
                "Quantum/shor_metal.py",
                "Quantum/shor_iterative.py",
                "Quantum/chsh_correlation_curves.png",
                "Quantum/qubit_field_entanglement_viz.py",
                "Quantum/qubit_field_entanglement.png",
                "Quantum/qubit_field_filmstrip.png",
                "Quantum/qubit_field_entanglement.gif",
                "Quantum/hourglass_viz.py",
                "Quantum/hourglass_model.png",
                "Quantum/waist_tomography.py",
                "Quantum/waist_tomography.png",
                "Quantum/ghz_simulator.py",
                "Quantum/stabilizer_sim.py",
                "Quantum/quantum_algorithms.py",
                "Quantum/shor_factor_15.py",
                "Quantum/shor_general.py",
                "Quantum/build_paper.sh",
                "Quantum/typeset_math.py",
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                // Disable Swift's DYNAMIC exclusivity-enforcement in release builds.
                // Profiling showed these runtime checks (SwiftTLSContext::get +
                // beginAccess + AccessSet::insert) were the single largest cost in
                // the interpreter — ~30% of a pure arithmetic loop, and 1.5–2.3x
                // overall. The engine is single-threaded per runtime, so the checks
                // guard against an aliasing class of bug that cannot occur here;
                // STATIC (compile-time) exclusivity remains on. Correctness is
                // gated by the full conformance suite (EngineTests/testConformance).
                //
                // Tradeoff: `unsafeFlags` makes this target ineligible as a *remote*
                // SwiftPM dependency (it's fine for local builds and the bundled
                // apps). Remove this block to restore remote-dependency eligibility
                // at a 1.5–2.3x speed cost.
                .unsafeFlags(["-enforce-exclusivity=unchecked"], .when(configuration: .release)),
            ]
        ),
        .executableTarget(
            name: "jeffjs-cli",
            dependencies: ["JeffJS"],
            path: "Sources/jeffjs-cli",
            swiftSettings: [
                .unsafeFlags(["-enforce-exclusivity=unchecked"], .when(configuration: .release)),
            ]
        ),
        .testTarget(
            name: "JeffJSTests",
            dependencies: ["JeffJS"]
        ),
    ]
)
