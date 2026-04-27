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
            ]
        ),
        .testTarget(
            name: "JeffJSTests",
            dependencies: ["JeffJS"]
        ),
    ]
)
