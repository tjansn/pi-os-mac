// Resource-only target: SwiftPM bundles context-scorer-weights.json from here, because it only bundles files
// inside a target's own directory. PiOSCore reads it through ContextScorerWeights.bundled(), never through
// `Bundle.module`, whose generated accessor traps when an app build did not copy the bundle.
enum ContextScorerData {}
