// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "pi-os",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "pi-os", targets: ["PiOS"]),
        .executable(name: "pi-os-ui-preview", targets: ["PiOSPreview"]),
        .executable(name: "pi-os-input-fixture", targets: ["PiOSInputFixture"]),
        .executable(name: "pi-os-native-probe", targets: ["PiOSNativeProbe"]),
    ],
    targets: [
        .target(name: "PiOSCore", dependencies: ["PiOSContextScorerData"]),
        // The context scorer's trained weights. SwiftPM bundles resources only from a target's own directory;
        // the dataset, reference scores and training script live beside them but are not shipped.
        .target(name: "PiOSContextScorerData", path: "Resources/context-scorer",
                exclude: ["dataset", "reference.jsonl", "train-context-scorer.swift"],
                resources: [.copy("context-scorer-weights.json")]),
        .target(name: "PiOSMac", dependencies: ["PiOSCore"]),
        .executableTarget(name: "PiOS", dependencies: ["PiOSCore", "PiOSMac"]),
        .executableTarget(name: "PiOSPreview", dependencies: ["PiOSCore", "PiOSMac"]),
        .executableTarget(name: "PiOSInputFixture", dependencies: ["PiOSCore"]),
        .executableTarget(name: "PiOSNativeProbe", dependencies: ["PiOSCore", "PiOSMac"]),
        .testTarget(name: "PiOSTests", dependencies: ["PiOSCore", "PiOSMac"]),
    ]
)
