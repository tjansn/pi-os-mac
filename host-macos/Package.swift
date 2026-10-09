// swift-tools-version: 6.1
import PackageDescription

// Tools 6.1 for package traits (SE-0450): FluidAudio's `NemoTextProcessing` trait (a prebuilt xcframework for TTS
// text normalization, unused by speech recognition) is switched off, so no binary artifact enters the signed bundle.
// Every pi-os target stays in the Swift 5 language mode (`swiftLanguageModes` below), as under tools 5.9.
let package = Package(
    name: "pi-os",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "pi-os", targets: ["PiOS"]),
        .executable(name: "pi-os-ui-preview", targets: ["PiOSPreview"]),
        .executable(name: "pi-os-input-fixture", targets: ["PiOSInputFixture"]),
        .executable(name: "pi-os-native-probe", targets: ["PiOSNativeProbe"]),
        .executable(name: "pi-os-voice-bench", targets: ["PiOSVoiceBench"]),
    ],
    dependencies: [
        // Parakeet TDT v3 on the Neural Engine (DESIGN4 §4.2, D-T1). Apache-2.0; an exact release, no traits.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5", traits: []),
    ],
    targets: [
        .target(name: "PiOSCore", dependencies: ["PiOSContextScorerData"]),
        // The context scorer's trained weights. SwiftPM bundles resources only from a target's own directory;
        // the dataset, reference scores and training script live beside them but are not shipped.
        .target(name: "PiOSContextScorerData", path: "Resources/context-scorer",
                exclude: ["dataset", "reference.jsonl", "train-context-scorer.swift"],
                resources: [.copy("context-scorer-weights.json")]),
        .target(name: "PiOSMac", dependencies: ["PiOSCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(name: "PiOS", dependencies: ["PiOSCore", "PiOSMac"]),
        .executableTarget(name: "PiOSPreview", dependencies: ["PiOSCore", "PiOSMac"]),
        .executableTarget(name: "PiOSInputFixture", dependencies: ["PiOSCore"]),
        .executableTarget(name: "PiOSNativeProbe", dependencies: ["PiOSCore", "PiOSMac"]),
        // Developer bench (DESIGN4 §9.2): WAV files through the production engines, JSONL out. Never shipped.
        .executableTarget(name: "PiOSVoiceBench", dependencies: ["PiOSCore", "PiOSMac"]),
        .testTarget(name: "PiOSTests", dependencies: ["PiOSCore", "PiOSMac"]),
    ],
    swiftLanguageModes: [.v5]
)
