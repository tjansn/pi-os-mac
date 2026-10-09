import CryptoKit
import Darwin
import XCTest
@testable import PiOSCore
@testable import PiOSMac

// MARK: - Fakes (no network, no models, no real lock)

/// Serves files from memory. `stall` makes one path hang until the download is cancelled.
final class FakeModelTransport: SpeechModelTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String: Data]
    private var requested: [URL] = []
    var stall: String?
    var failing: String?

    init(_ bodies: [String: Data]) { self.bodies = bodies }

    var requests: [URL] { lock.lock(); defer { lock.unlock() }; return requested }

    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        lock.withLock { requested.append(url) }
        let path = url.pathComponents.drop { $0 != "resolve" }.dropFirst(2).joined(separator: "/")
        if path == failing { throw SpeechModelStore.Failure.network }
        if path == stall {
            progress(1)
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            throw CancellationError()
        }
        guard let body = bodies[path] else { throw SpeechModelStore.Failure.network }
        progress(Int64(body.count / 2))
        try body.write(to: destination)
        progress(Int64(body.count))
    }
}

final class FakeInferenceLock: InferenceLocking, @unchecked Sendable {
    private let lock = NSLock()
    private var heldElsewhere: Bool
    private var acquired = 0, released = 0
    init(held: Bool = false) { heldElsewhere = held }
    var held: Bool {
        get { lock.lock(); defer { lock.unlock() }; return heldElsewhere }
        set { lock.lock(); heldElsewhere = newValue; lock.unlock() }
    }
    var counts: (acquired: Int, released: Int) { lock.lock(); defer { lock.unlock() }; return (acquired, released) }
    func tryAcquire() -> InferenceLockHold? {
        lock.lock(); defer { lock.unlock() }
        guard !heldElsewhere else { return nil }
        acquired += 1
        return InferenceLockHold { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.released += 1; self.lock.unlock()
        }
    }
}

final class FakeModelLoader: SpeechModelLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var loads: [URL] = []
    var fails = false
    var calls: [URL] { lock.lock(); defer { lock.unlock() }; return loads }
    func load(from directory: URL) async throws -> SpeechDecoding {
        let fails = lock.withLock { () -> Bool in loads.append(directory); return self.fails }
        if fails { throw SpeechModelStore.Failure.load }
        return FakeDecoder()
    }
}

/// Collects a store's state updates.
final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SpeechModelState] = []
    private var task: Task<Void, Never>?
    init(_ store: SpeechModelStore) {
        let stream = store.stateUpdates()
        task = Task { [weak self] in for await state in stream { self?.append(state) } }
    }
    deinit { task?.cancel() }
    private func append(_ state: SpeechModelState) { lock.lock(); stored.append(state); lock.unlock() }
    var states: [SpeechModelState] { lock.lock(); defer { lock.unlock() }; return stored }
    /// The states without progress values, consecutive repeats collapsed.
    var phases: [String] {
        var out: [String] = []
        for state in states {
            let name: String
            switch state {
            case .notDownloaded: name = "notDownloaded"
            case .downloading: name = "downloading"
            case .compiling: name = "compiling"
            case .ready: name = "ready"
            case .failed: name = "failed"
            case .deferredByLock: name = "deferredByLock"
            }
            if out.last != name { out.append(name) }
        }
        return out
    }
}

// MARK: - Tests

final class SpeechModelStoreTests: XCTestCase {
    private var support: URL!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: support)
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// A three-file fake model with real digests.
    private let bodies: [String: Data] = [
        "Encoder.mlmodelc/weights/weight.bin": Data(repeating: 7, count: 4096),
        "Encoder.mlmodelc/model.mil": Data("program".utf8),
        "parakeet_vocab.json": Data("{\"0\":\"a\"}".utf8),
    ]
    private var files: [SpeechModelFile] {
        bodies.keys.sorted().map { SpeechModelFile(path: $0, size: Int64(bodies[$0]!.count), sha256: Self.digest(bodies[$0]!)) }
    }

    private func makeStore(transport: SpeechModelTransport, lock: InferenceLocking = FakeInferenceLock(), loader: FakeModelLoader = FakeModelLoader(),
                       revision: String? = "0123456789abcdef0123456789abcdef01234567", free: Int64? = nil) -> SpeechModelStore {
        var descriptor = SpeechModelDescriptor.parakeetV3
        descriptor.revision = revision
        return SpeechModelStore(support: support, descriptor: descriptor, files: files, transport: transport, inferenceLock: lock,
                                loader: loader, availableBytes: { _ in free })
    }

    private func mode(_ url: URL) -> Int {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0, url.lastPathComponent)
        return Int(info.st_mode & 0o777)
    }

    private func leftovers(_ store: SpeechModelStore) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.modelsRoot.path)) ?? []).filter { $0.hasPrefix(".") }
    }

    private func settle(_ log: StateLog) async {
        for _ in 0..<50 where log.states.isEmpty { try? await Task.sleep(nanoseconds: 2_000_000) }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    // MARK: The pinned model

    func testTheParakeetDescriptorIsPinnedAndTheManifestMatchesTheRepository() throws {
        let descriptor = ParakeetModel.descriptor
        let frozen = SpeechModelDescriptor.parakeetV3
        XCTAssertEqual(descriptor, frozen, "one source of truth: the frozen contract carries the pinned revision and size")
        XCTAssertEqual(frozen.revision, "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe")
        XCTAssertEqual(frozen.approximateBytes, 483_105_645)
        XCTAssertEqual(SpeechModelStore(support: support).descriptor, frozen, "the app's store uses it")
        XCTAssertEqual(descriptor.revision, ParakeetModel.revision)
        XCTAssertNotNil(ParakeetModel.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression), "a full commit id")
        XCTAssertEqual([descriptor.id, descriptor.recognizer, descriptor.repository, descriptor.license, descriptor.directoryName],
                       [frozen.id, frozen.recognizer, frozen.repository, frozen.license, frozen.directoryName])
        XCTAssertEqual(descriptor.recognizer, RecognizerID.parakeetV3)
        XCTAssertEqual(descriptor.directoryName, "parakeet-tdt-v3")
        XCTAssertEqual(ParakeetModel.files.count, 21)
        XCTAssertEqual(ParakeetModel.totalBytes, 483_105_645)
        XCTAssertEqual(descriptor.approximateBytes, ParakeetModel.totalBytes)
        XCTAssertEqual(Set(ParakeetModel.files.map(\.path)).count, 21, "paths are unique")
        for file in ParakeetModel.files {
            XCTAssertNotNil(SpeechModelStore.child(URL(fileURLWithPath: "/m"), file.path), file.path)
            XCTAssertNotNil(file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression), file.path)
            XCTAssertGreaterThan(file.size, 0)
        }
        // What AsrModels.loadLocal(version: .v3, encoderPrecision: .int8) reads.
        let components = Set(ParakeetModel.files.map { String($0.path.split(separator: "/")[0]) })
        XCTAssertEqual(components, ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "parakeet_vocab.json"])
        XCTAssertTrue(ParakeetModel.attribution.contains("CC BY 4.0"))

        let store = SpeechModelStore(support: support)
        let url = store.remoteURL(ParakeetModel.files[9], revision: ParakeetModel.revision)
        XCTAssertEqual(url.absoluteString,
                       "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/7dd20fe6b1797d35f5e3307e8b1732d9a178edfe/Encoder.mlmodelc/weights/weight.bin")
        XCTAssertEqual(store.directory.path, support.appendingPathComponent("models/parakeet-tdt-v3").standardizedFileURL.path)
    }

    func testManifestPathsCannotLeaveTheDirectory() {
        let root = URL(fileURLWithPath: "/m")
        for bad in ["/etc/passwd", "../x", "a/../../x", "a//b", "", "a/./b"] { XCTAssertNil(SpeechModelStore.child(root, bad), bad) }
        XCTAssertEqual(SpeechModelStore.child(root, "a/b.bin")?.path, "/m/a/b.bin")
    }

    // MARK: Download

    func testDownloadVerifiesThenInstallsAtomicallyAndCompilesUnderTheLock() async throws {
        let transport = FakeModelTransport(bodies), lock = FakeInferenceLock(), loader = FakeModelLoader()
        let store = makeStore(transport: transport, lock: lock, loader: loader)
        let log = StateLog(store)
        let initial = await store.state()
        XCTAssertEqual(initial, .notDownloaded)
        XCTAssertNil(store.loadedModel)
        await store.download()
        await settle(log)
        let final = await store.state()
        XCTAssertEqual(final, .ready)
        XCTAssertEqual(log.phases, ["notDownloaded", "downloading", "compiling", "ready"])
        XCTAssertNotNil(store.loadedModel)
        XCTAssertEqual(loader.calls, [store.directory])
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertTrue(transport.requests.allSatisfy { $0.absoluteString.contains("/resolve/0123456789abcdef0123456789abcdef01234567/") })
        XCTAssertEqual(lock.counts.acquired, 1)
        XCTAssertEqual(lock.counts.released, 1, "released after the compile")
        // Progress is monotonic and ends at 1.
        let progress = log.states.compactMap { state -> Double? in if case .downloading(let value) = state { return value } else { return nil } }
        XCTAssertEqual(progress, progress.sorted())
        XCTAssertEqual(progress.last ?? 0, 1, accuracy: 0.001)
        // 0700 directories, 0600 files, excluded from backups, no staging left.
        XCTAssertEqual(mode(store.modelsRoot), 0o700)
        XCTAssertEqual(mode(store.directory), 0o700)
        XCTAssertEqual(mode(store.directory.appendingPathComponent("Encoder.mlmodelc")), 0o700)
        for file in files { XCTAssertEqual(mode(store.directory.appendingPathComponent(file.path)), 0o600, file.path) }
        XCTAssertEqual(mode(store.directory.appendingPathComponent(SpeechModelStore.installMarker)), 0o600)
        XCTAssertEqual(mode(store.directory.appendingPathComponent(SpeechModelStore.compiledMarker)), 0o600)
        for url in [store.modelsRoot, store.directory] {
            let excluded = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            XCTAssertEqual(excluded, true, url.lastPathComponent)
        }
        XCTAssertEqual(leftovers(store), [])
        // A second download of a loaded model does nothing.
        await store.download()
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testAVerificationFailureInstallsNothing() async {
        var tampered = bodies
        tampered["Encoder.mlmodelc/model.mil"] = Data("programX".utf8)
        let loader = FakeModelLoader()
        let store = makeStore(transport: FakeModelTransport(tampered), loader: loader)
        await store.download()
        let state = await store.state()
        XCTAssertEqual(state, .failed(message: SpeechModelStore.Failure.verification.message))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        XCTAssertEqual(leftovers(store), [], "the partial download is removed")
        XCTAssertEqual(loader.calls, [])
        XCTAssertNil(store.loadedModel)
    }

    func testANetworkFailureAndLowDiskSpaceInstallNothing() async {
        let transport = FakeModelTransport(bodies)
        transport.failing = "parakeet_vocab.json"
        let failing = makeStore(transport: transport)
        await failing.download()
        let failed = await failing.state()
        XCTAssertEqual(failed, .failed(message: SpeechModelStore.Failure.network.message))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failing.directory.path))
        XCTAssertEqual(leftovers(failing), [])

        let full = FakeModelTransport(bodies)
        let small = makeStore(transport: full, free: 1_000)
        await small.download()
        let state = await small.state()
        XCTAssertEqual(state, .failed(message: SpeechModelStore.Failure.diskSpace.message))
        XCTAssertEqual(full.requests, [], "nothing is fetched without room for it")
    }

    func testCancelStopsTheDownloadAndRemovesPartialFiles() async throws {
        let transport = FakeModelTransport(bodies)
        transport.stall = "parakeet_vocab.json"
        let loader = FakeModelLoader()
        let store = makeStore(transport: transport, loader: loader)
        let download = Task { await store.download() }
        for _ in 0..<500 where transport.requests.count < 3 { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(transport.requests.count, 3, "stalled on the last file")
        let staging = leftovers(store)
        XCTAssertEqual(staging.count, 1, "the partial download is in a staging directory")
        XCTAssertTrue(staging.first?.hasPrefix(".parakeet-tdt-v3.download-") == true)
        await store.cancel()
        await download.value
        let state = await store.state()
        XCTAssertEqual(state, .notDownloaded)
        XCTAssertEqual(leftovers(store), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        XCTAssertEqual(loader.calls, [])
    }

    func testDeleteRemovesTheModelAndUnloadsIt() async throws {
        let store = makeStore(transport: FakeModelTransport(bodies))
        await store.download()
        XCTAssertNotNil(store.loadedModel)
        try await store.delete()
        let state = await store.state()
        XCTAssertEqual(state, .notDownloaded)
        XCTAssertNil(store.loadedModel, "new takes run Apple only")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        XCTAssertEqual(leftovers(store), [])
        try await store.delete()   // idempotent
    }

    func testAHeldLockDefersTheDownloadAndTheCompileUntilTheNextAttempt() async {
        let transport = FakeModelTransport(bodies), lock = FakeInferenceLock(held: true), loader = FakeModelLoader()
        let store = makeStore(transport: transport, lock: lock, loader: loader)
        await store.download()
        var state = await store.state()
        XCTAssertEqual(state, .deferredByLock)
        XCTAssertEqual(transport.requests, [], "nothing is fetched while the benchmark holds the lock")
        lock.held = false
        await store.download()
        state = await store.state()
        XCTAssertEqual(state, .ready)

        // A later launch: installed and compiled, the lock held again → the load is deferred and retried by prepare().
        lock.held = true
        let relaunched = makeStore(transport: transport, lock: lock, loader: loader)
        state = await relaunched.state()
        XCTAssertEqual(state, .ready, "installed")
        XCTAssertNil(relaunched.loadedModel, "not loaded until prepare()")
        await relaunched.prepare()
        state = await relaunched.state()
        XCTAssertEqual(state, .deferredByLock)
        XCTAssertNil(relaunched.loadedModel)
        lock.held = false
        let log = StateLog(relaunched)
        await relaunched.prepare()
        await settle(log)
        XCTAssertNotNil(relaunched.loadedModel)
        XCTAssertEqual(log.phases, ["deferredByLock", "ready"], "a cached load never shows the first-compile state")
        XCTAssertEqual(loader.calls.count, 2)
    }

    /// The app calls prepare() at launch, when voice is enabled, when Settings → Voice opens and after a take while the
    /// state is `.deferredByLock`: that never downloads, and a deferred download keeps its "waiting" state.
    func testPrepareNeverDownloadsAndKeepsADeferredDownloadWaiting() async {
        let transport = FakeModelTransport(bodies), lock = FakeInferenceLock(held: true), loader = FakeModelLoader()
        let store = makeStore(transport: transport, lock: lock, loader: loader)
        await store.download()
        var state = await store.state()
        XCTAssertEqual(state, .deferredByLock)
        lock.held = false
        await store.prepare()
        state = await store.state()
        XCTAssertEqual(state, .deferredByLock, "still waiting for Try Again, not reset to Download")
        XCTAssertEqual(transport.requests, [], "prepare() never downloads")
        XCTAssertTrue(loader.calls.isEmpty)
        await store.download()
        state = await store.state()
        XCTAssertEqual(state, .ready)
    }

    func testPrepareWithoutAModelAndAFailedLoad() async throws {
        let loader = FakeModelLoader()
        let empty = makeStore(transport: FakeModelTransport(bodies), loader: loader)
        await empty.prepare()
        var state = await empty.state()
        XCTAssertEqual(state, .notDownloaded)
        XCTAssertEqual(loader.calls, [])

        loader.fails = true
        await empty.download()
        state = await empty.state()
        XCTAssertEqual(state, .failed(message: SpeechModelStore.Failure.load.message))
        XCTAssertNil(empty.loadedModel)
        loader.fails = false
        await empty.prepare()
        state = await empty.state()
        XCTAssertEqual(state, .ready, "prepare() retries the load of the installed files")
    }

    func testACorruptOrOtherRevisionInstallIsNotReady() async throws {
        let first = makeStore(transport: FakeModelTransport(bodies))
        await first.download()
        try Data("x".utf8).write(to: first.directory.appendingPathComponent("parakeet_vocab.json"))
        let truncated = makeStore(transport: FakeModelTransport(bodies))
        var state = await truncated.state()
        XCTAssertEqual(state, .notDownloaded, "a file of the wrong size")

        let other = makeStore(transport: FakeModelTransport(bodies), revision: "fedcba9876543210fedcba9876543210fedcba98")
        state = await other.state()
        XCTAssertEqual(state, .notDownloaded, "an install of another revision")
        await other.download()
        state = await other.state()
        XCTAssertEqual(state, .ready, "a new download replaces it")
        XCTAssertEqual(leftovers(other), [], "the old install is removed")
    }

    func testAnUnpinnedDescriptorDownloadsNothing() async {
        let transport = FakeModelTransport(bodies)
        let store = makeStore(transport: transport, revision: nil)
        await store.download()
        let state = await store.state()
        XCTAssertEqual(state, .failed(message: SpeechModelStore.Failure.unpinned.message))
        XCTAssertEqual(transport.requests, [])
    }

    func testStateUpdatesStartWithTheCurrentStateAndConcurrentCallsShareOneOperation() async {
        let transport = FakeModelTransport(bodies), loader = FakeModelLoader()
        let store = makeStore(transport: transport, loader: loader)
        var iterator = store.stateUpdates().makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .notDownloaded)
        async let a: Void = store.download()
        async let b: Void = store.prepare()
        async let c: Void = store.download()
        _ = await (a, b, c)
        XCTAssertEqual(transport.requests.count, 3, "one download")
        XCTAssertEqual(loader.calls.count, 1, "one load")
        let state = await store.state()
        XCTAssertEqual(state, .ready)
    }

    // MARK: Lock and transport

    func testTheFileLockIsNonBlockingAndNeverCreatesTheLockFile() throws {
        let path = support.appendingPathComponent("lock-dir/.local-inference.lock").path
        let missing = FileInferenceLock(path: path)
        let free = try XCTUnwrap(missing.tryAcquire(), "no lock file: nothing to coordinate with")
        free.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the lock file is never created")

        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: nil))
        let other = open(path, O_RDONLY)
        XCTAssertEqual(flock(other, LOCK_EX | LOCK_NB), 0, "another holder")
        let started = Date()
        XCTAssertNil(FileInferenceLock(path: path).tryAcquire(), "held elsewhere: deferred")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "never blocks")
        flock(other, LOCK_UN); close(other)
        let hold = try XCTUnwrap(FileInferenceLock(path: path).tryAcquire())
        let probe = open(path, O_RDONLY)
        XCTAssertNotEqual(flock(probe, LOCK_EX | LOCK_NB), 0, "the hold is a real exclusive flock")
        hold.release()
        XCTAssertEqual(flock(probe, LOCK_EX | LOCK_NB), 0, "released")
        flock(probe, LOCK_UN); close(probe)
        XCTAssertNotNil(HeldInferenceLock().tryAcquire())
        if ProcessInfo.processInfo.environment["PI_LOCAL_INFERENCE_LOCK"] == nil {
            XCTAssertTrue(FileInferenceLock.standard.path.hasSuffix("/dev/Projects/_LOCAL_AI/.local-inference.lock"))
            XCTAssertFalse(FileInferenceLock.standard.path.contains("/Library/Containers/"), "the account's real home")
        }
    }

    func testURLSessionTransportWritesTheBodyReportsProgressAndRejectsErrors() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubModelProtocol.self]
        let transport = URLSessionModelTransport(configuration: configuration)
        let destination = support.appendingPathComponent("body.bin")
        let received = ProgressLog()
        try await transport.download(URL(string: "https://models.test/ok")!, to: destination) { received.add($0) }
        XCTAssertEqual(try Data(contentsOf: destination), StubModelProtocol.body)
        XCTAssertEqual(received.values.last, Int64(StubModelProtocol.body.count))
        do {
            try await transport.download(URL(string: "https://models.test/missing")!, to: support.appendingPathComponent("x")) { _ in }
            XCTFail("a 404 is not a model file")
        } catch {
            XCTAssertEqual(error as? SpeechModelStore.Failure, .network)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("x").path))
        let cancelled = Task { try await transport.download(URL(string: "https://models.test/stall")!, to: support.appendingPathComponent("y")) { _ in } }
        try await Task.sleep(nanoseconds: 50_000_000)
        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int64] = []
    func add(_ value: Int64) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Int64] { lock.lock(); defer { lock.unlock() }; return stored }
}

/// `https://models.test/ok` → 200 with a body, `/missing` → 404, `/stall` → never finishes.
final class StubModelProtocol: URLProtocol {
    static let body = Data((0..<70_000).map { UInt8($0 % 251) })
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "models.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        switch url.path {
        case "/ok":
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": "\(Self.body.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body.prefix(30_000))
            client?.urlProtocol(self, didLoad: Self.body.suffix(from: 30_000))
            client?.urlProtocolDidFinishLoading(self)
        case "/missing":
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("not found".utf8))
            client?.urlProtocolDidFinishLoading(self)
        default:
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
    }
    override func stopLoading() {}
}
