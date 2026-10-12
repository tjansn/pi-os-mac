import Foundation

// File commands on what the user sees (DESIGN6 with BUILD6): "lösche test" on the desktop. Node resolves the name
// against the take's visible items, stages the operation (argv, single use, 2 minutes, bound to the take) and answers an
// `act` (or a list whose rows bind) `fileOp {opId}`. The host performs that act by asking Node to run it: POST
// /fileops/run, token-authed like the other host → Node routes. Node runs the op only after the user's dcg guard reviewed
// it (dcg's own approval dialog may wait for the user), verifies its effect and answers one line of user copy. The host
// never sees a path, a command or dcg's verdict, never retries a run, and logs kinds and outcomes only.

/// FILE_OP limits (BUILD6). Lengths are UTF-16 units.
public enum FileOpLimits {
    /// `line` of a run's answer: one line of user copy.
    public static let maxLine = 300
    /// How long the host waits for one run: dcg's approval dialog can stay open that long.
    public static let runTimeout: TimeInterval = 180
}

/// POST /fileops/run body.
public struct FileOpRunRequest: Codable, Equatable, Sendable {
    public var opId: String
    public init(opId: String) { self.opId = opId }

    private enum Keys: String, CodingKey { case opId }

    /// The route's rule: an `opId` of `^[A-Za-z0-9_-]{16,64}$`; unknown keys are dropped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        opId = try c.decode(String.self, forKey: .opId)
        guard HostAction.isOpId(opId) else { throw DecodingError.dataCorruptedError(forKey: .opId, in: c, debugDescription: "invalid opId") }
    }
}

/// What one run did (FILE_OP_OUTCOMES).
public enum FileOpOutcome: String, Codable, CaseIterable, Sendable {
    /// The operation ran and its effect was verified.
    case done
    /// dcg said no (the line carries its reason) or the user declined dcg's dialog.
    case denied
    /// The operation ran but failed, or its effect could not be verified.
    case failed
    /// Unknown, used or expired opId, or the source changed since staging: nothing ran.
    case expired
}

/// POST /fileops/run's 200 answer: `{ok: true, outcome, line}`. Strict like Node's parser: `ok` is literally true, the
/// outcome is one of FILE_OP_OUTCOMES, `line` is one non-blank line of at most 300 UTF-16 units; unknown keys are dropped.
/// `line` is user copy that may name the file: shown, never logged.
public struct FileOpRunResult: Codable, Equatable, Sendable {
    public var outcome: FileOpOutcome
    public var line: String
    public init(outcome: FileOpOutcome, line: String) { self.outcome = outcome; self.line = line }

    private enum Keys: String, CodingKey { case ok, outcome, line }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard try c.decode(Bool.self, forKey: .ok) else { throw DecodingError.dataCorruptedError(forKey: .ok, in: c, debugDescription: "not ok") }
        outcome = try c.decode(FileOpOutcome.self, forKey: .outcome)
        line = try c.decode(String.self, forKey: .line)
        guard VoiceText.isValid(line, max: FileOpLimits.maxLine) else {
            throw DecodingError.dataCorruptedError(forKey: .line, in: c, debugDescription: "invalid line")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(true, forKey: .ok)
        try c.encode(outcome, forKey: .outcome)
        try c.encode(line, forKey: .line)
    }
}

/// The routes of the file commands (host → Node).
public enum FileOpRoutes {
    public static let run = "/fileops/run"
}
