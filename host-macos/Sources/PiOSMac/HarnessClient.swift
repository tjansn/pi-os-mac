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
    /// Default idle TTL while push-to-talk is enabled, so a hold rarely pays a Node cold start.
    public static let voiceWarmTTL: Double = 600
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
    /// Idle time a warm Node child is kept: the explicit knob, else 600 s with voice on, else 120 s.
    public func warmTTL(voiceEnabled: Bool) -> Double {
        warmTTLExplicit || !voiceEnabled ? warmTTL : Self.voiceWarmTTL
    }
    public init(env: [String: String] = ProcessInfo.processInfo.environment) throws {
        support = URL(fileURLWithPath: env["PI_OS_SUPPORT_DIR"] ?? NSHomeDirectory() + "/Library/Application Support/pi-os", isDirectory: true)
        captures = URL(fileURLWithPath: env["PI_OS_CAPTURES_DIR"] ?? support.appendingPathComponent("captures").path, isDirectory: true)
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
    /// Push-to-talk raises the default warm TTL (see MacConfiguration.warmTTL(voiceEnabled:)).
    public var voiceEnabled: () -> Bool = { false }
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
            while child != nil && Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard child == nil else { throw DomainError("harness_unreachable", "Previous agent process is still stopping") }
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
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                try Task.checkCancellation()
                guard self.generation == run, self.child?.exited == false else {
                    throw DomainError("harness_unreachable", "Node stopped during startup")
                }
                if let data = try? await self.request("GET", "/health", authenticated: false),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["sessionId"] as? String == run.uuidString { return }
                try await Task.sleep(nanoseconds: 100_000_000)
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
        guard reservations.isEmpty, child?.exited == false, !expectedExit else { return }
        retention = Task { [weak self] in
            guard let self else { return }
            let ttl = self.config.warmTTL(voiceEnabled: self.voiceEnabled())
            do { try await Task.sleep(nanoseconds: UInt64(ttl * 1_000_000_000)) }
            catch { return }
            self.stop()
        }
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
    /// (Windows never sends it) and tells the agent the prompt was spoken.
    public func submit(id: String, context: String, prompt: String, takeId: String?, input: AgentInput?) async throws {
        var payload: [String: Any] = ["invocationId": id, "contextId": context, "prompt": prompt, "retainSession": true,
                                      "invokedAt": ISO8601DateFormatter().string(from: Date())]
        if let takeId { payload["takeId"] = takeId }
        if let input { payload["input"] = input.payload }
        _ = try await request("POST", "/invoke", payload: payload)
    }
    /// POST /invocations/prepare at key-down: Node pre-builds the take's session. Best effort;
    /// an older harness without the route (404) or a failure just means no reuse.
    public func prepare(contextId: String, takeId: String) async {
        _ = try? await request("POST", "/invocations/prepare", payload: ["contextId": contextId, "takeId": takeId])
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
    public func followup(_ id: String, prompt: String) async throws {
        _ = try await request("POST", "/invocations/\(id)/followup", payload: ["prompt": prompt])
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
    public struct ResourceSettings: Decodable { public let current: ResourceSelection; public let warning: String? }
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
        public struct Route: Decodable, Equatable {
            public let tier: String?
            public let model: String?
            public let thinkingLevel: String?
            public let auto: Bool?
        }
        private enum Keys: String, CodingKey {
            case state, activity, responseText, failureMessage, followupAvailable, revision, partialText, card, cardComplete, route
        }
        public init(state: String, activity: String? = nil, responseText: String? = nil, failureMessage: String? = nil,
                    followupAvailable: Bool? = nil, revision: Int? = nil, partialText: String? = nil, card: CardSpec? = nil,
                    cardComplete: Bool? = nil) {
            self.state = state; self.activity = activity; self.responseText = responseText; self.failureMessage = failureMessage
            self.followupAvailable = followupAvailable; self.revision = revision; self.partialText = partialText
            self.card = card; self.cardComplete = cardComplete; route = nil
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

/// `input` on POST /invoke (protocol §3.5). Additive: Windows never sends it.
public struct AgentInput: Equatable, Sendable {
    public var mode: String
    public var locale: String?
    public var durationMs: Int?
    public var engine: String?
    public init(mode: String, locale: String? = nil, durationMs: Int? = nil, engine: String? = nil) {
        self.mode = mode; self.locale = locale; self.durationMs = durationMs; self.engine = engine
    }
    public static func voice(_ language: VoiceLanguage, durationMs: Int?) -> AgentInput {
        AgentInput(mode: "voice", locale: language.identifier, durationMs: durationMs, engine: "apple-speech")
    }
    var payload: [String: Any] {
        var value: [String: Any] = ["mode": mode]
        if let locale { value["locale"] = locale }
        if let durationMs { value["durationMs"] = durationMs }
        if let engine { value["engine"] = engine }
        return value
    }
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
