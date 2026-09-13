// swift-tools-version: 5.9
import PackageDescription

// Nagi Engine — architecture validation spikes.
//
// These targets exist to answer empirical questions that the ADRs deliberately
// left open. They are NOT the engine, and they must not grow into it.
//
//   Spike A  Locator <-> Native Position round-trip stability
//   Spike B  CoreText as a controllable typography backend
//
// See docs/adr/0011-rendering-and-golden-validation.md for the fixed conditions
// (bundled font, fixed viewport, fixed locale, quantized metrics).
let package = Package(
    name: "NagiEngineSpikes",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "spike-a", targets: ["SpikeA"]),
        .executable(name: "spike-b", targets: ["SpikeB"])
    ],
    targets: [
        .target(
            name: "SpikeKit",
            resources: [
                // Bundled so that glyph metrics cannot drift under us when the
                // OS updates its system fonts. See ADR-0011.
                .copy("Resources/NagiRounded-Regular.ttf")
            ]
        ),
        // Spike A reuses SpikeKit's reporting primitives (Quantize, SHA256,
        // ProbeOutcome, ArtifactManifest, DeterminismRecord, ReportIO) rather
        // than restating them. That makes `SpikeKit` stand for two things at
        // once — Spike B's kit and the shared reporting primitives — which is
        // a name that will need splitting the day a third spike appears.
        // Deferred on purpose: Spike B is sealed, and re-partitioning it to
        // tidy a name is not worth the churn yet.
        //
        // `TerminalColumns.swift` is shared on the same terms.
        .target(
            name: "SpikeAKit",
            dependencies: ["SpikeKit"]
        ),
        .executableTarget(
            name: "SpikeA",
            // Named because `main.swift` imports it; until now it reached
            // `SpikeKit` through the package's transitive search paths.
            dependencies: ["SpikeAKit", "SpikeKit"]
        ),
        .executableTarget(
            name: "SpikeB",
            dependencies: ["SpikeKit"]
        ),
        .testTarget(
            name: "SpikeKitTests",
            dependencies: ["SpikeKit"]
        ),
        .testTarget(
            name: "SpikeAKitTests",
            dependencies: ["SpikeAKit"]
        )
    ]
)
