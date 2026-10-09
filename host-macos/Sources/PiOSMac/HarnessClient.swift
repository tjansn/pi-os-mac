import Foundation
import Darwin
import Security
import PiOSCore

public struct MacConfiguration {
    public let support: URL
    public let captures: URL
    public let token: String
    public let hostPort: UInt16
    public let nodePort: UInt16
    public let nodePath: String?
    public let nodeEntry: String?
    /// Explicit `PI_OS_NODE_WARM_TTL_SECONDS`, else 120 s. See `warmTTL(voiceEnabled:)`.
    public let warmTTL: Double
    /// True when `PI_OS_NODE_WARM_TTL_SECONDS` was set; the explicit knob always wins.
    public let warmTTLExplicit: Bool
    public let echo: Bool
    public let forceReadOnly: Bool
    public var canControl: Bool { !forceReadOnly && ControlAvailability.ready }
    public var trustedCompatibility: Bool {
        guard canControl,
              let size = try? support.appendingPathComponent("resources.json").resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 16_384,
              let data = try? Data(contentsOf: support.appendingPathComponent("resources.json")),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return value["mode"] as? String == "trustedGlobal" && value["trustAcknowledgement"] as? Int == 1
    }
    /// Idle time a warm Node child is kept: the explicit knob, else none while push-to-talk is enabled (nil: Node is
    /// started at launch and never idle-stopped, DESIGN4 §7 item 6, about 170 MB), else 120 s.
    public func warmTTL(voiceEnabled: Bool) -> Double? {
        warmTTLExplicit || !voiceEnabled ? warmTTL : nil
    }
    public init(env: [String: String] = ProcessInfo.processInfo.environment) throws {
        support = URL(fileURLWithPath: env["PI_OS_SUPPORT_DIR"] ?? NSHomeDirectory() + "/Library/Application Support/pi-os", isDirectory: true)
        // Standardized once: shelf files, the shelf's wire check and Node's PI_OS_CAPTURES_DIR share one string.
        captures = URL(fileURLWithPath: env["PI_OS_CAPTURES_DIR"] ?? support.appendingPathComponent("captures").path, isDirectory: true).standardizedFileURL
        if let configured = env["PI_OS_TOKEN"], !configured.isEmpty { token = configured }
        else {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw DomainError("startup_failed", "Secure session token generation failed")
            }
            token = bytes.map { String(format: "%02x", $0) }.joined()
        }
        func port(_ key: String, _ fallback: UInt16) throws -> UInt16 {
            guard let raw = env[key] else { return fallback }
            guard let port = UInt16(raw), port > 0 else { throw DomainError("configuration_error", "Invalid \(key)") }
            return port
        }
        hostPort = try port("PI_OS_HOST_PORT", 17831); nodePort = try port("PI_OS_NODE_PORT", 17832)
        nodePath = env["PI_OS_NODE_PATH"] ?? Bundle.main.url(forResource: "node", withExtension: nil, subdirectory: "runtime/bin")?.path
            ?? Bundle.main.object(forInfoDictionaryKey: "PiOSNodePath") as? String
        nodeEntry = env["PI_OS_NODE_ENTRY"] ?? Bundle.main.url(forResource: "index", withExtension: "js", subdirectory: "node-harness/dist")?.path
            ?? Bundle.main.object(forInfoDictionaryKey: "PiOSNodeEntry") as? String
        if let raw = env["PI_OS_NODE_WARM_TTL_SECONDS"] {
            guard let value = Double(raw), value.isFinite, value >= 0, value <= 3600 else {
                throw DomainError("configuration_error", "Warm TTL must be between 0 and 3600 seconds")
            }
            warmTTL = value; warmTTLExplicit = true
        } else { warmTTL = 120; warmTTLExplicit = false }
        echo = env["PI_OS_ECHO"] == "1"
        forceReadOnly = env["PI_OS_READ_ONLY"] == "1"
        for directory in [support, captures, support.appendingPathComponent("agent-cwd"), support.appendingPathComponent("logs")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }
}

/// Authoritative single-instance gate, independent of TCP readiness or port ownership.
public final class InstanceLock {
    private var fd: Int32 = -1
    public init(directory: URL) throws {
        fd = open(directory.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DomainError("startup_failed", "Cannot open the application lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); fd = -1
            throw DomainError("already_running", "pi-os is already running for this application-support directory")
        }
    }
    deinit { if fd >= 0 { close(fd) } }
}

/// posix_spawn establishes the process group atomically (no post-spawn setpgid race).
private final class OwnedChild {
    let pid: pid_t
    private var stdinFD: Int32
    private(set) var exited = false
    init(node: String, entry: String, cwd: String, env: [String: String], logPath: String) throws {
        guard node.hasPrefix("/"), entry.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: node),
              FileManager.default.fileExists(atPath: entry) else {
            throw DomainError("harness_unreachable", "Set absolute PI_OS_NODE_PATH and PI_OS_NODE_ENTRY, or use a bundled installation")
        }
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw DomainError("startup_failed", "Cannot create child stdin") }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC); _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        let log = open(logPath, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard log >= 0 else { close(fds[0]); close(fds[1]); throw DomainError("startup_failed", "Cannot open harness log") }
        defer { close(fds[0]); close(log) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, fds[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, log, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, log, STDERR_FILENO)
        posix_spawn_file_actions_addchdir_np(&actions, cwd)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv: [UnsafeMutablePointer<CChar>?] = [node, entry].map { value in value.withCString { strdup($0) } } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.sorted(by: { $0.key < $1.key }).map { pair in
            "\(pair.key)=\(pair.value)".withCString { strdup($0) }
        } + [nil]
        defer { for p in argv + envp { free(p) } }
        var child: pid_t = 0
        let status = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { vars in
                posix_spawn(&child, node, &actions, &attributes, args.baseAddress!, vars.baseAddress!)
            }
        }
        guard status == 0 else {
            close(fds[1]); throw DomainError("harness_unreachable", "Node could not start (posix_spawn \(status))")
        }
        pid = child; stdinFD = fds[1]
    }
    func observe(_ completed: @escaping (Int32) -> Void) {
        let childPID = pid
        DispatchQueue.global(qos: .utility).async { [self] in
            var status: Int32 = 0
            while waitpid(childPID, &status, 0) == -1 && errno == EINTR {}
            DispatchQueue.main.async {
                self.exited = true
                self.closeInput()
                // Only the group created by this exact spawn. Read-only children have no shell tools.
                kill(-childPID, SIGKILL)
                completed(status)
            }
        }
    }
    func closeInput() { if stdinFD >= 0 { close(stdinFD); stdinFD = -1 } }
    func stop() {
        closeInput()
        guard !exited else { return }
        kill(-pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            if !exited { kill(-pid, SIGKILL) }
        }
    }
}

@MainActor public final class HarnessClient {
    private let config: MacConfiguration
    private let session: URLSession
    /// SSE only (GET /invocations/{id}/events): long-lived, so it never shares the 10 s resource
    /// timeout of the request session. Pings arrive every 15 s; silence for 45 s fails over to polling.
    private let streamSession: URLSession
    private var child: OwnedChild?
    private var starting: Task<Void, Error>?
    private var retention: Task<Void, Never>?
    private var generation = UUID()
    private var expectedExit = false
    private var reservations: Set<UUID> = []
    public var onUnexpectedExit: (() -> Void)?
    /// Push-to-talk keeps Node warm without an idle stop (see MacConfiguration.warmTTL(voiceEnabled:)).
    public var voiceEnabled: () -> Bool = { false }
    /// `/health` poll interval while a child starts: 20 ms for the first second (instant-first Node answers in about
    /// 0.1 s), then 100 ms (DESIGN4 §7 item 6).
    nonisolated static func healthPollNanoseconds(elapsed: TimeInterval) -> UInt64 {
        elapsed < 1 ? 20_000_000 : 100_000_000
    }
    public var ownedPID: pid_t? { child?.exited == false ? child?.pid : nil }

    public init(config: MacConfiguration) {
        self.config = config
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5; c.timeoutIntervalForResource = 10
        c.connectionProxyDictionary = [:]
        session = URLSession(configuration: c)
        let stream = URLSessionConfiguration.ephemeral
        stream.timeoutIntervalForRequest = 45; stream.timeoutIntervalForResource = 7_200
        stream.connectionProxyDictionary = [:]; stream.httpMaximumConnectionsPerHost = 2
        streamSession = URLSession(configuration: stream)
    }
    public func warm() async throws {
        retention?.cancel(); retention = nil
        if let starting { return try await starting.value }
        // A previous cancellation may still be reaping its owned group. Only poll during a new warm request.
        if expectedExit {
            let deadline = Date().addingTimeInterval(3)
            // Two warms can wait here at once (a cancel's voice restart and the next key-down): the first one past the
            // reap starts the next child (`expectedExit` becomes false), and the other joins it below.
            while child != nil && expectedExit && Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            if let starting { return try await starting.value }
            guard child == nil || !expectedExit else { throw DomainError("harness_unreachable", "Previous agent process is still stopping") }
        }
        if let child, !child.exited { return }
        generation = UUID(); expectedExit = false
        let run = generation
        guard let node = config.nodePath, let entry = config.nodeEntry else {
            throw DomainError("harness_unreachable", "Node is not configured. Launch with host-macos/scripts/run-dev.sh.")
        }
        var env = ProcessInfo.processInfo.environment
        env["PI_OS_TOKEN"] = config.token
        env["PI_OS_SESSION_ID"] = run.uuidString
        env["PI_OS_HOST_URL"] = "http://127.0.0.1:\(config.hostPort)"
        env["PI_OS_NODE_PORT"] = String(config.nodePort)
        env["PI_OS_CAPTURES_DIR"] = config.captures.path
        env["PI_OS_SUPPORT_DIR"] = config.support.path
        env["PI_OS_SUPERVISED"] = "1"
        // Actual native capabilities are negotiated for each invocation, not frozen
        // into a warm child. Keep only the user's explicit read-only override here.
        env["PI_OS_READ_ONLY"] = config.forceReadOnly ? "1" : "0"
        env["PI_OS_INSECURE_DEV"] = nil
        // Never evaluate shell profiles or inherited Node preload hooks in a TCC-bearing child.
        env["NODE_OPTIONS"] = nil; env["NODE_PATH"] = nil
        let process = try OwnedChild(node: node, entry: entry, cwd: config.support.appendingPathComponent("agent-cwd").path,
                                     env: env, logPath: config.support.appendingPathComponent("logs/harness.log").path)
        child = process
        process.observe { [weak self, weak process] _ in
            guard let self, self.child === process else { return }
            self.child = nil
            self.starting?.cancel(); self.starting = nil
            if !self.expectedExit { self.onUnexpectedExit?() }
        }
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            let started = Date()
            let deadline = started.addingTimeInterval(12)
            while Date() < deadline {
                try Task.checkCancellation()
                guard self.generation == run, self.child?.exited == false else {
                    throw DomainError("harness_unreachable", "Node stopped during startup")
                }
                if let data = try? await self.request("GET", "/health", authenticated: false),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["sessionId"] as? String == run.uuidString { return }
                try await Task.sleep(nanoseconds: Self.healthPollNanoseconds(elapsed: Date().timeIntervalSince(started)))
            }
            throw DomainError("harness_unreachable", "Node readiness timed out; check logs/harness.log and port \(self.config.nodePort)")
        }
        starting = task
        do {
            try await task.value
            if generation == run { starting = nil }
        } catch {
            let startupFailed = generation == run
            if startupFailed { stop() }
            if startupFailed && error is CancellationError {
                throw DomainError("harness_unreachable", "Node exited before becoming ready; check logs/harness.log")
            }
            throw error
        }
    }
    public func reserve() -> UUID {
        retention?.cancel(); retention = nil
        let id = UUID(); reservations.insert(id); return id
    }
    public func release(_ id: UUID) {
        reservations.remove(id)
        retainWarm()
    }
    public func stopIfUnused() { if reservations.isEmpty { stop() } }
    public func retainWarm() {
        retention?.cancel(); retention = nil
        guard reservations.isEmpty, child?.exited == false, !expectedExit,
              let ttl = config.warmTTL(voiceEnabled: voiceEnabled()) else { return }
        retention = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(ttl * 1_000_000_000)) }
            catch { return }
            self?.stop()
        }
    }
    /// Push-to-talk is on: Node starts now (at launch or when voice is switched on), off the hotkey path, and stays up
    /// without an idle stop, so the first hold never pays a cold start. Best effort: a failure here is reported by
    /// the next take that needs Node.
    public func startForVoice() async -> Bool {
        do { try await warm() } catch { return false }
        retainWarm()
        return true
    }
    public func stop() {
        expectedExit = true; generation = UUID()
        retention?.cancel(); retention = nil
        starting?.cancel(); starting = nil
        child?.stop()
        // Keep ownership until waitpid completes; a new invocation must not attach to a stopping child.
    }
    public func submit(id: String, context: String, prompt: String) async throws {
        try await submit(id: id, context: context, prompt: prompt, takeId: nil, input: nil)
    }
    /// POST /invoke. `takeId` lets Node reuse the session prepared at key-down; `input` is additive
    /// (Windows never sends it) and tells the agent the prompt was spoken. `scope` is what the context
    /// chip showed (nil = legacy window behaviour); `attachments` is the context shelf, untrusted data.
    /// `workingDirectory` is the full pi session's folder (nil: none sent, as in isolated mode).
    public func submit(id: String, context: String, prompt: String, takeId: String?, input: AgentInput?,
                       scope: ContextWire? = nil, attachments: [Attachment] = [], workingDirectory: WorkingDirectory? = nil) async throws {
        let payload = try Self.invokePayload(id: id, contextId: context, prompt: prompt, invokedAt: Date(), takeId: takeId,
                                             input: input, context: scope, attachments: attachments, workingDirectory: workingDirectory)
        _ = try await request("POST", "/invoke", payload: payload)
    }
    /// The /invoke body (protocol §3.5, DESIGN3 wire additions). `context`, `attachments` and `workingDirectory`
    /// are additive: absent means legacy; an empty shelf sends no `attachments` key.
    static func invokePayload(id: String, contextId: String, prompt: String, invokedAt: Date, takeId: String?, input: AgentInput?,
                              context: ContextWire?, attachments: [Attachment], workingDirectory: WorkingDirectory? = nil) throws -> [String: Any] {
        var payload: [String: Any] = ["invocationId": id, "contextId": contextId, "prompt": prompt, "retainSession": true,
                                      "invokedAt": ISO8601DateFormatter().string(from: invokedAt)]
        if let takeId { payload["takeId"] = takeId }
        if let input { payload["input"] = input.payload }
        try addContext(context, attachments: attachments, to: &payload)
        if let workingDirectory { payload["workingDirectory"] = workingDirectory.path }
        return payload
    }
    /// The /followup body: the prompt plus the follow-up composer's chip and the shelf.
    static func followupPayload(prompt: String, context: ContextWire?, attachments: [Attachment]) throws -> [String: Any] {
        var payload: [String: Any] = ["prompt": prompt]
        try addContext(context, attachments: attachments, to: &payload)
        return payload
    }
    private static func addContext(_ context: ContextWire?, attachments: [Attachment], to payload: inout [String: Any]) throws {
        let encoder = JSONEncoder()
        if let context { payload["context"] = try JSONSerialization.jsonObject(with: encoder.encode(context)) }
        if !attachments.isEmpty { payload["attachments"] = try JSONSerialization.jsonObject(with: encoder.encode(attachments)) }
    }
    /// POST /invocations/prepare at key-down: Node pre-builds the take's session. Best effort;
    /// an older harness without the route (404) or a failure just means no reuse.
    /// `workingDirectory` must be the one the take's /invoke sends: a prepared session is adopted only for the same folder.
    public func prepare(contextId: String, takeId: String, workingDirectory: WorkingDirectory? = nil) async {
        _ = try? await request("POST", "/invocations/prepare", payload: Self.preparePayload(contextId: contextId, takeId: takeId,
                                                                                            workingDirectory: workingDirectory))
    }
    /// The /invocations/prepare body; `workingDirectory` is additive (absent: none, as in isolated mode).
    static func preparePayload(contextId: String, takeId: String, workingDirectory: WorkingDirectory?) -> [String: Any] {
        var payload: [String: Any] = ["contextId": contextId, "takeId": takeId]
        if let workingDirectory { payload["workingDirectory"] = workingDirectory.path }
        return payload
    }
    /// The take ended without an /invoke: Node may drop its prepared session now instead of at
    /// the 30 s expiry. Best effort; never starts or waits for a child.
    public func cancelPrepared(takeId: String) async {
        guard child?.exited == false, !expectedExit, starting == nil else { return }
        _ = try? await request("POST", "/invocations/prepare", payload: ["takeId": takeId, "cancel": true])
    }
    /// POST /instant: synchronous, latest-wins by `seq`. Never acts; the host performs any action.
    public func instant(_ instant: InstantRequest) async throws -> InstantResponse {
        try JSONDecoder().decode(InstantResponse.self, from: await request("POST", "/instant", body: JSONEncoder().encode(instant)))
    }
    public func followup(_ id: String, prompt: String, scope: ContextWire? = nil, attachments: [Attachment] = []) async throws {
        _ = try await request("POST", "/invocations/\(id)/followup", payload: Self.followupPayload(prompt: prompt, context: scope, attachments: attachments))
    }
    public func closeThread(_ id: String) async {
        // Do not warm/restart a dead child merely to close a session it no longer owns.
        guard ownedPID != nil, !expectedExit else { return }
        _ = try? await request("POST", "/invocations/\(id)/close", payload: [:])
    }
    public struct Model: Codable, Equatable {
        public let provider: String
        public let id: String
        public let name: String
        public let thinkingLevels: [String]
    }
    public struct ModelSelection: Codable, Equatable {
        public let provider: String
        public let modelId: String
        public let thinkingLevel: String
    }
    public struct ModelCatalog: Decodable { public let models: [Model]; public let current: ModelSelection? }
    public func models() async throws -> ModelCatalog {
        try await warm()
        return try JSONDecoder().decode(ModelCatalog.self, from: await request("GET", "/models"))
    }
    public func setModel(_ selection: ModelSelection) async throws {
        try await warm()
        _ = try await request("POST", "/settings/model", payload: ["provider": selection.provider, "modelId": selection.modelId, "thinkingLevel": selection.thinkingLevel])
    }
    public struct ResourceSelection: Codable { public let mode: String }
    /// GET /settings/resources. `status` (full session on/off, bash guard) is additive: nil from an older harness,
    /// and a status that fails strict decoding is dropped rather than failing Settings.
    public struct ResourceSettings: Decodable {
        public let current: ResourceSelection
        public let warning: String?
        public let status: ResourceStatus?
        public init(current: ResourceSelection, warning: String?, status: ResourceStatus? = nil) {
            self.current = current; self.warning = warning; self.status = status
        }
        private enum Keys: String, CodingKey { case current, warning, status }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            current = try c.decode(ResourceSelection.self, forKey: .current)
            warning = try c.decodeIfPresent(String.self, forKey: .warning)
            status = (try? c.decodeIfPresent(ResourceStatus.self, forKey: .status)) ?? nil
        }
    }
    public func resources() async throws -> ResourceSettings {
        try await warm()
        return try JSONDecoder().decode(ResourceSettings.self, from: await request("GET", "/settings/resources"))
    }
    public func setResources(trusted: Bool) async throws {
        try await warm()
        _ = try await request("POST", "/settings/resources", payload: ["mode": trusted ? "trustedGlobal" : "isolated", "acknowledgeUnpinnedAccess": trusted])
    }
    /// GET /settings/classifier: the stored settings plus a read-only `status`. Kept as a raw
    /// object so a POST preserves every field the user configured (paths stay in Node's file).
    public func classifier() async throws -> ClassifierSettings {
        try await warm()
        return try ClassifierSettings(json: await request("GET", "/settings/classifier"))
    }
    public func setClassifier(_ settings: ClassifierSettings) async throws -> ClassifierSettings {
        try await warm()
        return try ClassifierSettings(json: await request("POST", "/settings/classifier", body: settings.body()))
    }
    /// One InvocationRecord as the host reads it. Fields after `followupAvailable` are additive
    /// (protocol §3.5) and absent on older harnesses; a card that fails strict decoding is dropped
    /// so the reader falls back to responseText instead of failing the invocation.
    public struct Status: Decodable {
        public let state: String
        public let activity: String?
        public let responseText: String?
        public let failureMessage: String?
        public let followupAvailable: Bool?
        public let revision: Int?
        public let partialText: String?
        public let card: CardSpec?
        public let cardComplete: Bool?
        public let route: Route?
        /// Additive (DESIGN2 §5.1): the thread's scope and whether the agent looked at the window.
        public let context: ContextRecord?
        /// The record's step log as tool names only (`agent.<tool>` per agent tool execution, protocol.md
        /// "GET /invocations"), in order; a step's `detail` is never read. Nil when absent or malformed.
        public let steps: [String]?
        private struct Step: Decodable { let tool: String }
        public struct ContextRecord: Decodable, Equatable {
            public let scope: ContextScope
            public let source: ContextSource?
            /// Sticky: the agent looked at the window during the thread ("Looked at <app>").
            public let pulled: Bool
            /// The window is part of the thread right now (window scope, or pulled and not narrowed since).
            /// Optional: older harnesses omit it, and the host then keeps its own follow-up scope.
            public var included: Bool? = nil
        }
        public struct Route: Decodable, Equatable {
            public let tier: String?
            public let model: String?
            public let thinkingLevel: String?
            public let auto: Bool?
        }
        private enum Keys: String, CodingKey {
            case state, activity, responseText, failureMessage, followupAvailable, revision, partialText, card, cardComplete, route, context, steps
        }
        public init(state: String, activity: String? = nil, responseText: String? = nil, failureMessage: String? = nil,
                    followupAvailable: Bool? = nil, revision: Int? = nil, partialText: String? = nil, card: CardSpec? = nil,
                    cardComplete: Bool? = nil, steps: [String]? = nil) {
            self.state = state; self.activity = activity; self.responseText = responseText; self.failureMessage = failureMessage
            self.followupAvailable = followupAvailable; self.revision = revision; self.partialText = partialText
            self.card = card; self.cardComplete = cardComplete; route = nil; context = nil; self.steps = steps
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            state = try c.decode(String.self, forKey: .state)
            activity = try c.decodeIfPresent(String.self, forKey: .activity)
            responseText = try c.decodeIfPresent(String.self, forKey: .responseText)
            failureMessage = try c.decodeIfPresent(String.self, forKey: .failureMessage)
            followupAvailable = try c.decodeIfPresent(Bool.self, forKey: .followupAvailable)
            revision = (try? c.decodeIfPresent(Int.self, forKey: .revision)) ?? nil
            partialText = (try? c.decodeIfPresent(String.self, forKey: .partialText)) ?? nil
            card = (try? c.decodeIfPresent(CardSpec.self, forKey: .card)) ?? nil
            cardComplete = (try? c.decodeIfPresent(Bool.self, forKey: .cardComplete)) ?? nil
            route = (try? c.decodeIfPresent(Route.self, forKey: .route)) ?? nil
            context = (try? c.decodeIfPresent(ContextRecord.self, forKey: .context)) ?? nil
            steps = ((try? c.decodeIfPresent([Step].self, forKey: .steps)) ?? nil)?.map(\.tool)
        }
        public var isTerminal: Bool { !["queued", "running"].contains(state) }
    }
    public func status(_ id: String) async throws -> Status {
        try Self.decodeRecord(await request("GET", "/invocations/" + id))
    }
    /// One record, after `wellFormedJSON`: a lone surrogate in one text field must never fail the
    /// whole record (and with it a completed answer).
    nonisolated static func decodeRecord(_ data: Data) throws -> Status {
        try JSONDecoder().decode(Status.self, from: wellFormedJSON(data))
    }
    /// Replaces each `\uD800`–`\uDFFF` escape that is not half of a high+low escape pair with
    /// `\uFFFD`. Older harnesses could cut text inside a surrogate pair, which JSONDecoder rejects.
    /// Only real escapes count (an escaped backslash followed by "u" is text); nothing else changes.
    nonisolated static func wellFormedJSON(_ data: Data) -> Data {
        let backslash = UInt8(ascii: "\\")
        guard data.contains(backslash) else { return data }
        let bytes = [UInt8](data)
        /// The code unit of a `\uXXXX` escape whose backslash is at `at`, if there is one there.
        func escape(_ at: Int) -> UInt16? {
            guard at + 6 <= bytes.count, bytes[at] == backslash, bytes[at + 1] == UInt8(ascii: "u") else { return nil }
            var value: UInt16 = 0
            for byte in bytes[at + 2..<at + 6] {
                guard let digit = Character(Unicode.Scalar(byte)).hexDigitValue else { return nil }
                value = value << 4 | UInt16(digit)
            }
            return value
        }
        var output: [UInt8] = []; output.reserveCapacity(bytes.count)
        var changed = false, index = 0
        while index < bytes.count {
            guard bytes[index] == backslash, index + 1 < bytes.count else { output.append(bytes[index]); index += 1; continue }
            guard let unit = escape(index), (0xD800...0xDFFF).contains(unit) else {
                // Any other escape, an escaped backslash included, is copied as one unit.
                let length = escape(index) == nil ? 2 : 6
                output.append(contentsOf: bytes[index..<index + length]); index += length; continue
            }
            if unit <= 0xDBFF, let next = escape(index + 6), (0xDC00...0xDFFF).contains(next) {
                output.append(contentsOf: bytes[index..<index + 12]); index += 12; continue
            }
            output.append(contentsOf: Array("\\uFFFD".utf8)); changed = true; index += 6
        }
        return changed ? Data(output) : data
    }
    /// GET /invocations/{id}/events (SSE, macOS only): one full record per revision, the terminal
    /// record last. Ends by throwing when the route is missing or the stream stops early, so the
    /// caller falls back to `status` polling (the Windows-compatible path). Reading runs off the
    /// main actor; records are decoded by the consumer.
    public func events(_ id: String) -> AsyncThrowingStream<Status, Error> {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(config.nodePort)/invocations/\(id)/events")!)
        req.setValue(config.token, forHTTPHeaderField: "X-Harness-Token")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let raw = Self.recordStream(session: streamSession, request: req)
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    for try await data in raw {
                        let status = try Self.decodeRecord(data)
                        continuation.yield(status)
                        if status.isTerminal { continuation.finish(); return }
                    }
                    continuation.finish(throwing: DomainError("stream_ended", "The event stream ended before the task finished"))
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    nonisolated private static func recordStream(session: URLSession, request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                          (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().hasPrefix("text/event-stream") else {
                        throw DomainError("stream_unavailable", "The harness does not stream events")
                    }
                    var parser = ServerSentEventParser()
                    var chunk: [UInt8] = []; chunk.reserveCapacity(8_192)
                    func drain() throws {
                        for event in try parser.feed(chunk) where event.name == "record" { continuation.yield(Data(event.data.utf8)) }
                        chunk.removeAll(keepingCapacity: true)
                    }
                    for try await byte in bytes {
                        chunk.append(byte)
                        if byte == 10 || chunk.count >= 8_192 { try drain() }
                    }
                    try drain()
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    public func cancel(_ id: String) async -> Bool {
        do { _ = try await request("POST", "/invocations/\(id)/cancel", payload: [:]); return true }
        catch { return false }
    }
    // MARK: Personal dictionary (DESIGN4 §6.2): token-authed like /instant, synchronous in Node, no agent tool
    // reaches it. An older harness answers 404, which arrives here as a thrown DomainError: treat it as "no dictionary".
    /// POST /dictionary/learn: a user gesture in the bar (pick, confirm, edit, "No, I meant", reject). Never warms the
    /// harness: a take was just answered by /instant, so it is running.
    public func learn(_ learn: DictionaryLearnRequest) async throws -> DictionaryWriteResponse {
        try JSONDecoder().decode(DictionaryWriteResponse.self, from: await request("POST", DictionaryRoutes.learn, body: JSONEncoder().encode(learn)))
    }
    /// GET /dictionary: the whole document, disabled entries included (Settings only).
    public func dictionary() async throws -> DictionaryDocument {
        try await warm()
        return try JSONDecoder().decode(DictionaryDocument.self, from: await request("GET", DictionaryRoutes.document))
    }
    /// POST /dictionary/edit: Settings → Dictionary and the bar's Undo.
    public func editDictionary(_ edit: DictionaryEditRequest) async throws -> DictionaryWriteResponse {
        try await warm()
        return try JSONDecoder().decode(DictionaryWriteResponse.self, from: await request("POST", DictionaryRoutes.edit, body: JSONEncoder().encode(edit)))
    }
    /// GET /dictionary/recognizer-terms: the ranked contextual strings for the recognizers. Fetched at launch and when a
    /// write's `revision` changes, never on key-down.
    public func recognizerTerms(max: Int = DictionaryLimits.recognizerTerms) async throws -> RecognizerTermsResponse {
        try JSONDecoder().decode(RecognizerTermsResponse.self, from: await request("GET", DictionaryRoutes.recognizerTerms(max: max)))
    }
    private func request(_ method: String, _ path: String, payload: [String: Any]? = nil, authenticated: Bool = true) async throws -> Data {
        try await request(method, path, body: payload.map { try JSONSerialization.data(withJSONObject: $0) }, authenticated: authenticated)
    }
    private func request(_ method: String, _ path: String, body: Data?, authenticated: Bool = true) async throws -> Data {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(config.nodePort)" + path)!)
        req.httpMethod = method
        if authenticated { req.setValue(config.token, forHTTPHeaderField: "X-Harness-Token") }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { let error: DomainError }
            if let failure = try? JSONDecoder().decode(Failure.self, from: data) { throw failure.error }
            throw DomainError("harness_unreachable", "Harness rejected the request (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        return data
    }
}

/// The dictionary routes as the bar and Settings use them (DESIGN4 §6.2); tests and previews substitute fakes.
@MainActor protocol DictionaryService: AnyObject {
    func learn(_ learn: DictionaryLearnRequest) async throws -> DictionaryWriteResponse
    func dictionary() async throws -> DictionaryDocument
    func editDictionary(_ edit: DictionaryEditRequest) async throws -> DictionaryWriteResponse
    func recognizerTerms(max: Int) async throws -> RecognizerTermsResponse
}
extension HarnessClient: DictionaryService {}

/// `input` on POST /invoke (protocol §3.5). Additive: Windows never sends it.
public struct AgentInput: Equatable, Sendable {
    public var mode: String
    public var locale: String?
    public var durationMs: Int?
    /// The engine part of the deciding hypothesis's recognizer id (`apple-dt`, `parakeet-v3`; never the `/locale` part).
    public var engine: String?
    /// 0...1: the deciding hypothesis's mean word (or utterance) confidence.
    public var confidence: Double?
    public init(mode: String, locale: String? = nil, durationMs: Int? = nil, engine: String? = nil, confidence: Double? = nil) {
        self.mode = mode; self.locale = locale; self.durationMs = durationMs; self.engine = engine
        self.confidence = confidence.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
    }
    /// A spoken take: `/invoke` gets the take's language hint among the languages the user speaks (Settings → Voice), the
    /// engine and confidence of the hypothesis that decided (`voice.source`, else the host's pick) and the hold time
    /// (DESIGN4 §4.4, §8). The same locale is the take's `/instant` `locale`.
    public static func voice(_ final: VoiceFinal, decidedBy source: String? = nil, fallback language: VoiceLanguage,
                             durationMs: Int?, among languages: [VoiceLanguage] = VoiceLanguages.enabled) -> AgentInput {
        let usable = final.wireHypotheses
        let chosen = source.flatMap { source in usable.first { $0.source == source } } ?? usable.first
        let spoken = languages.isEmpty ? VoiceLanguages.enabled : languages
        let locale = final.languageHint(among: spoken)?.identifier ?? chosen?.locale.flatMap { VoiceText.isLocale($0) ? $0 : nil } ?? language.identifier
        return AgentInput(mode: "voice", locale: locale, durationMs: durationMs, engine: chosen.map(\.engine) ?? "apple-dt",
                          confidence: chosen?.confidence)
    }
    var payload: [String: Any] {
        var value: [String: Any] = ["mode": mode]
        if let locale { value["locale"] = locale }
        if let durationMs { value["durationMs"] = durationMs }
        if let engine { value["engine"] = engine }
        if let confidence { value["confidence"] = confidence }
        return value
    }
}

/// The recognizers' contextual strings from `GET /dictionary/recognizer-terms` (DESIGN4 §6.4): fetched at launch (once
/// Node is up), after a take while no fetch has succeeded yet, and whenever a learn or edit response carries a revision
/// other than the last one seen, never on key-down. Takes put the pinned app name and window title first, then these,
/// capped at 100. An older harness (404) or a failure leaves the list as it was. Terms are user content: never logged.
@MainActor final class RecognizerTerms {
    private let service: DictionaryService
    private(set) var strings: [String] = []
    /// The revision of `strings`, or of the newest write response seen while a fetch was pending.
    private(set) var revision: Int?
    private var fetching: Task<Void, Never>?
    private var again = false
    /// Completed fetches (tests).
    private(set) var fetches = 0
    /// An empty answer means Node had no app index yet (it asks the host for it, and right after launch the host may
    /// not answer within Node's short wait): it does not count as fetched, and is retried a few times off the hotkey path.
    private let emptyRetryDelay: Duration
    private let maximumEmptyRetries: Int
    private var emptyRetries = 0

    init(service: DictionaryService, emptyRetryDelay: Duration = .seconds(3), maximumEmptyRetries: Int = 3) {
        self.service = service; self.emptyRetryDelay = emptyRetryDelay; self.maximumEmptyRetries = maximumEmptyRetries
    }

    /// Fetches now (launch, voice switched on). A fetch already running is followed by one more.
    func refresh() {
        if fetching != nil { again = true; return }
        fetching = Task { [weak self] in
            guard let self else { return }
            var empty = false
            if let response = try? await self.service.recognizerTerms(max: DictionaryLimits.recognizerTerms) {
                self.strings = response.terms.map(\.text)
                empty = response.terms.isEmpty
                // Keep "never fetched" for an empty answer, so refreshIfNeverFetched tries again after a take.
                self.revision = empty ? nil : response.revision
                if !empty { self.emptyRetries = 0 }
            }
            self.fetches += 1
            self.fetching = nil
            if self.again { self.again = false; self.refresh(); return }
            if empty, self.emptyRetries < self.maximumEmptyRetries {
                self.emptyRetries += 1
                let delay = self.emptyRetryDelay
                Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    self?.refreshIfNeverFetched()
                }
            }
        }
    }
    /// After a take (Node just answered, off the hotkey path): fetches when no fetch ever succeeded, so a launch start that
    /// failed (a slow login, a spawn error) does not leave the recognizers without the dictionary for the whole session.
    func refreshIfNeverFetched() {
        guard revision == nil, fetching == nil else { return }
        refresh()
    }
    /// A learn or edit response's revision: refetches only when it changed.
    func noteRevision(_ revision: Int) {
        guard revision != self.revision else { return }
        self.revision = revision
        refresh()
    }
    /// Waits for a running fetch (tests).
    func settled() async { while let fetching { await fetching.value } }
}

/// /settings/classifier (protocol §3.5). `kind`, `python` and `modelDir` are edited here; every
/// other stored field is echoed back unchanged, and the read-only `status` is never posted.
public struct ClassifierSettings {
    public var kind: String
    public let statusState: String?
    public let statusReason: String?
    /// `status.layaLaunch` (additive; nil on older harnesses): whether Laya could start with the
    /// stored paths or PI_OS_LAYA_* (existence checks only; nothing is spawned to compute it).
    public let launchOK: Bool?
    public let launchReason: String?
    private var stored: [String: Any]
    public init(json: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any], let kind = object["kind"] as? String else {
            throw DomainError("invalid_response", "Classifier settings were not understood")
        }
        let status = object["status"] as? [String: Any]
        let launch = status?["layaLaunch"] as? [String: Any]
        self.kind = kind; statusState = status?["state"] as? String; statusReason = status?["reason"] as? String
        launchOK = launch?["ok"] as? Bool; launchReason = launch?["reason"] as? String
        stored = object; stored["status"] = nil
    }
    public init(kind: String, statusState: String? = nil, statusReason: String? = nil, launchOK: Bool? = nil, launchReason: String? = nil,
                python: String? = nil, modelDir: String? = nil) {
        self.kind = kind; self.statusState = statusState; self.statusReason = statusReason
        self.launchOK = launchOK; self.launchReason = launchReason; stored = ["kind": kind]
        self.python = python; self.modelDir = modelDir
    }
    public var shadowLog: Bool { stored["shadowLog"] as? Bool ?? false }
    /// Absolute path of the Laya environment's Python (nil removes it; Node then falls back to PI_OS_LAYA_PYTHON).
    public var python: String? {
        get { stored["python"] as? String }
        set { stored["python"] = newValue }
    }
    /// Absolute path of the Laya model folder (nil removes it; Node then falls back to PI_OS_LAYA_MODEL_DIR).
    public var modelDir: String? {
        get { stored["modelDir"] as? String }
        set { stored["modelDir"] = newValue }
    }
    func body() throws -> Data {
        var object = stored; object["kind"] = kind
        return try JSONSerialization.data(withJSONObject: object)
    }
}

/// Incremental `text/event-stream` decoder (WHATWG): `event:` and `data:` fields, `:` comment
/// lines (pings), LF / CRLF / CR line ends, dispatch on a blank line. An event without data is
/// dropped; an unfinished event at end of stream is discarded, as the spec requires.
public struct ServerSentEventParser {
    public struct Event: Equatable { public var name: String; public var data: String }
    /// One record is ≤ ~100 KB (partialText ≤ 8000, card ≤ 64 KB); anything far larger is not ours.
    public static let maximumEventBytes = 2_000_000
    private var line: [UInt8] = []
    private var afterCR = false
    private var name = ""
    private var data: [String] = []
    private var size = 0
    public init() {}

    public mutating func feed<S: Sequence>(_ bytes: S) throws -> [Event] where S.Element == UInt8 {
        var events: [Event] = []
        for byte in bytes {
            if afterCR { afterCR = false; if byte == 10 { continue } }
            if byte == 10 || byte == 13 {
                afterCR = byte == 13
                if let event = try endLine() { events.append(event) }
                continue
            }
            line.append(byte)
            guard line.count + size <= Self.maximumEventBytes else { throw DomainError("stream_invalid", "An event exceeded the size limit") }
        }
        return events
    }
    private mutating func endLine() throws -> Event? {
        defer { line.removeAll(keepingCapacity: true) }
        guard !line.isEmpty else {
            defer { name = ""; data = []; size = 0 }
            return data.isEmpty ? nil : Event(name: name.isEmpty ? "message" : name, data: data.joined(separator: "\n"))
        }
        guard line.first != UInt8(ascii: ":") else { return nil }
        let text = String(decoding: line, as: UTF8.self)
        let field: Substring, rawValue: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]; rawValue = text[text.index(after: colon)...]
        } else { field = Substring(text); rawValue = "" }
        let value = rawValue.hasPrefix(" ") ? String(rawValue.dropFirst()) : String(rawValue)
        switch field {
        case "event": name = value
        case "data": data.append(value); size += value.utf8.count + 1
        default: break // id/retry are not used by the harness
        }
        return nil
    }
}
