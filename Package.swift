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
        .executableTarget(
            name: "SpikeB",
            dependencies: ["SpikeKit"]
        ),
        .testTarget(
            name: "SpikeKitTests",
            dependencies: ["SpikeKit"]
        )
    ]
)
