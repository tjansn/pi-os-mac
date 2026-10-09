import CryptoKit
import Darwin
import Foundation
import PiOSCore

// The downloadable multilingual speech model (DESIGN4 §4.2, D-T1, D-T2): NVIDIA Parakeet TDT 0.6B v3 in FluidInference's
// Core ML conversion, fetched once from a pinned Hugging Face revision after the user's consent in Settings, verified
// file by file against pinned sizes and SHA-256 digests, and moved into `<support>/models/parakeet-tdt-v3/` in one rename.
// The download and every model load (the first one compiles for the Neural Engine) take a NON-BLOCKING flock on the
// local-inference lock: when it is held the step is deferred (`.deferredByLock`) and Apple recognition is used meanwhile.
// Per-take inference never takes the lock (push-to-talk cannot wait).
// Files are 0600 in 0700 directories, excluded from backups. Privacy: nothing here logs; errors are fixed, content-free
// messages; no audio or text ever passes through this file.

// MARK: - The pinned model

/// One file of a pinned model, as listed by the repository at its revision.
public struct SpeechModelFile: Equatable, Sendable, Codable {
    /// Path inside the repository (and inside the install directory).
    public var path: String
    public var size: Int64
    /// Lowercase hex SHA-256 of the file's bytes.
    public var sha256: String
    public init(path: String, size: Int64, sha256: String) {
        self.path = path; self.size = size; self.sha256 = sha256
    }
}

/// NVIDIA Parakeet TDT 0.6B v3 (Core ML conversion by FluidInference), pinned in code.
public enum ParakeetModel {
    /// `FluidInference/parakeet-tdt-0.6b-v3-coreml` at its head on 2026-10-07 (commit of 2026-08-19). Verified that day
    /// against the Hugging Face tree API (sizes, LFS SHA-256, git blob ids) and against an independent download. Pinned
    /// once, in `SpeechModelDescriptor.parakeetV3`.
    public static let revision = SpeechModelDescriptor.parakeetV3.revision ?? ""

    /// What `AsrModels.loadLocal(version: .v3)` reads: the preprocessor (CPU), the int8 encoder, the decoder and the
    /// v3 joint (CPU + Neural Engine), and the vocabulary. 21 files, 483,105,645 bytes.
    public static let files: [SpeechModelFile] = [
        .init(path: "Preprocessor.mlmodelc/coremldata.bin", size: 486, sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
        .init(path: "Preprocessor.mlmodelc/metadata.json", size: 2841, sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
        .init(path: "Preprocessor.mlmodelc/model.mil", size: 28181, sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
        .init(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
        .init(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 491072, sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
        .init(path: "Encoder.mlmodelc/coremldata.bin", size: 485, sha256: "d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86"),
        .init(path: "Encoder.mlmodelc/metadata.json", size: 2921, sha256: "da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9"),
        .init(path: "Encoder.mlmodelc/model.mil", size: 959769, sha256: "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
        .init(path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
        .init(path: "Encoder.mlmodelc/weights/weight.bin", size: 445187200, sha256: "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421"),
        .init(path: "Decoder.mlmodelc/coremldata.bin", size: 554, sha256: "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99"),
        .init(path: "Decoder.mlmodelc/metadata.json", size: 3427, sha256: "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9"),
        .init(path: "Decoder.mlmodelc/model.mil", size: 13110, sha256: "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35"),
        .init(path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350"),
        .init(path: "Decoder.mlmodelc/weights/weight.bin", size: 23604992, sha256: "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"),
        .init(path: "JointDecisionv3.mlmodelc/coremldata.bin", size: 521, sha256: "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342"),
        .init(path: "JointDecisionv3.mlmodelc/metadata.json", size: 3453, sha256: "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f"),
        .init(path: "JointDecisionv3.mlmodelc/model.mil", size: 11775, sha256: "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d"),
        .init(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c"),
        .init(path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 12642764, sha256: "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"),
        .init(path: "parakeet_vocab.json", size: 151122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
    ]

    public static var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// The shipped model's descriptor: exactly `SpeechModelDescriptor.parakeetV3` (pinned revision, `totalBytes`); a test
    /// keeps the two and this manifest in step.
    public static let descriptor = SpeechModelDescriptor.parakeetV3

    /// The CC-BY-4.0 attribution line for the consent sheet and Settings (THIRD_PARTY_NOTICES.md has the full notice).
    public static let attribution = "NVIDIA Parakeet TDT 0.6B v3 by NVIDIA, licensed under CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Core ML conversion by FluidInference, downloaded unmodified from Hugging Face."
}

// MARK: - Seams (fake transport, lock and models in tests)

/// Downloads one file. Throws `CancellationError` when the calling task is cancelled.
public protocol SpeechModelTransport: Sendable {
    /// Writes `url`'s body to `destination` (a new file), reporting the bytes received so far.
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws
}

/// The local-inference lock (AGENTS.md, D-T2), always taken without blocking.
public protocol InferenceLocking: Sendable {
    /// nil while another process holds it.
    func tryAcquire() -> InferenceLockHold?
}

/// A held lock; released once (also on deinit).
public final class InferenceLockHold: @unchecked Sendable {
    private let lock = NSLock()
    private var onRelease: (() -> Void)?
    public init(onRelease: @escaping () -> Void = {}) { self.onRelease = onRelease }
    deinit { release() }
    public func release() {
        lock.lock(); let pending = onRelease; onRelease = nil; lock.unlock()
        pending?()
    }
}

/// Loads an installed model directory into a decoder (the first load compiles for the Neural Engine).
public protocol SpeechModelLoading: Sendable {
    func load(from directory: URL) async throws -> SpeechDecoding
}

/// `_LOCAL_AI/.local-inference.lock` (or `$PI_LOCAL_INFERENCE_LOCK`): a NON-BLOCKING exclusive flock on the existing file.
/// The file is opened read-only and never created, so nothing is ever written into `_LOCAL_AI`. Without the file there
/// is nothing to coordinate with; a file that exists but cannot be opened counts as held.
public struct FileInferenceLock: InferenceLocking {
    public let path: String
    public init(path: String) { self.path = path }

    /// `$PI_LOCAL_INFERENCE_LOCK`, else `<home>/dev/Projects/_LOCAL_AI/.local-inference.lock` under the account's real
    /// home directory: redirecting caches with CFFIXED_USER_HOME must not silently move the lock somewhere else.
    public static var standard: FileInferenceLock {
        if let path = ProcessInfo.processInfo.environment["PI_LOCAL_INFERENCE_LOCK"], !path.isEmpty { return FileInferenceLock(path: path) }
        return FileInferenceLock(path: accountHome + "/dev/Projects/_LOCAL_AI/.local-inference.lock")
    }

    static var accountHome: String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir { return String(cString: directory) }
        return NSHomeDirectory()
    }

    public func tryAcquire() -> InferenceLockHold? {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        if descriptor < 0 { return errno == ENOENT || errno == ENOTDIR ? InferenceLockHold() : nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return InferenceLockHold {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }
}

/// For a process that already holds the local-inference lock around its whole run (the bench, the opt-in test):
/// a second flock from the same process on a new descriptor would conflict with its own hold.
public struct HeldInferenceLock: InferenceLocking {
    public init() {}
    public func tryAcquire() -> InferenceLockHold? { InferenceLockHold() }
}

/// Plain URLSession download tasks (no cookies, no cache, no credentials). Redirects to the Hugging Face CDN are followed.
public final class URLSessionModelTransport: SpeechModelTransport, @unchecked Sendable {
    private let delegate = Delegate()
    private let session: URLSession

    /// `configuration` is injectable for tests (a URLProtocol stub); the default is ephemeral.
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = (configuration.copy() as? URLSessionConfiguration) ?? configuration
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    // The session retains its delegate until it is invalidated.
    deinit { session.invalidateAndCancel() }

    public func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try Task.checkCancellation()
        let task = session.downloadTask(with: URLRequest(url: url))
        let delegate = delegate
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.register(task, Delegate.Pending(destination: destination, progress: progress, continuation: continuation))
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        struct Pending {
            var destination: URL
            var progress: @Sendable (Int64) -> Void
            var continuation: CheckedContinuation<Void, Error>
            var failure: Error?
        }

        private let lock = NSLock()
        private var pending: [Int: Pending] = [:]

        func register(_ task: URLSessionTask, _ entry: Pending) {
            lock.lock(); pending[task.taskIdentifier] = entry; lock.unlock()
        }

        private func entry(_ task: URLSessionTask) -> Pending? {
            lock.lock(); defer { lock.unlock() }
            return pending[task.taskIdentifier]
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            entry(downloadTask)?.progress(totalBytesWritten)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let entry = entry(downloadTask) else { return }
            var failure: Error?
            if let response = downloadTask.response as? HTTPURLResponse, response.statusCode != 200 {
                failure = SpeechModelStore.Failure.network
            } else {
                // The system removes `location` when this returns: move it now.
                do { try FileManager.default.moveItem(at: location, to: entry.destination) } catch { failure = SpeechModelStore.Failure.write }
            }
            lock.lock(); pending[downloadTask.taskIdentifier]?.failure = failure; lock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let entry = pending.removeValue(forKey: task.taskIdentifier)
            lock.unlock()
            guard let entry else { return }
            if let error {
                entry.continuation.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : SpeechModelStore.Failure.network)
            } else if let failure = entry.failure {
                entry.continuation.resume(throwing: failure)
            } else {
                entry.continuation.resume()
            }
        }
    }
}

// MARK: - The store

/// `SpeechModelStoring` for one pinned model (Parakeet by default). One instance per support directory, owned by the app
/// and shared with Settings and the engine. `download()`, `prepare()` and `delete()` are serialized: a second call while
/// one runs waits for it (and `prepare()` during a download returns when the download has loaded the model).
public final class SpeechModelStore: SpeechModelStoring, @unchecked Sendable {
    /// Fixed, content-free reasons (`SpeechModelState.failed(message:)`).
    public enum Failure: Error, Equatable, Sendable {
        case unpinned, network, verification, diskSpace, write, load
        public var message: String {
            switch self {
            case .unpinned: return "This build has no pinned model revision, so nothing was downloaded."
            case .network: return "The download did not complete. Check the connection and try again."
            case .verification: return "The downloaded files did not match their pinned checksums, so nothing was installed."
            case .diskSpace: return "There is not enough free disk space for the model."
            case .write: return "The model folder could not be written."
            case .load: return "The model could not be loaded. Delete it and download it again."
            }
        }
    }

    /// Written last into a finished install (the install is complete iff it is there).
    static let installMarker = ".pi-os-model.json"
    /// Written after the first successful load (the Neural Engine compile).
    static let compiledMarker = ".pi-os-compiled"
    static let directoryMode: mode_t = 0o700
    static let fileMode: mode_t = 0o600
    /// Free space beyond the model itself.
    static let diskMargin: Int64 = 200_000_000

    public let descriptor: SpeechModelDescriptor
    public let files: [SpeechModelFile]
    /// `<support>/models/`.
    public let modelsRoot: URL
    /// `<support>/models/<descriptor.directoryName>/`.
    public let directory: URL

    private let transport: SpeechModelTransport
    private let inferenceLock: InferenceLocking
    private let loader: SpeechModelLoading
    private let baseURL: URL
    private let availableBytes: @Sendable (URL) -> Int64?

    private enum Operation { case download, prepare, delete }
    private let lock = NSLock()
    private var current: SpeechModelState
    private var observers: [UUID: AsyncStream<SpeechModelState>.Continuation] = [:]
    private var operation: Task<Void, Never>?
    private var operationKind: Operation?
    private var model: SpeechDecoding?
    private var lastProgressStep = -1

    /// The app's store: `<support>/models/parakeet-tdt-v3/`, Hugging Face over URLSession, the `_LOCAL_AI` lock, FluidAudio.
    public convenience init(support: URL) {
        self.init(support: support, descriptor: ParakeetModel.descriptor, files: ParakeetModel.files,
                  transport: URLSessionModelTransport(), inferenceLock: FileInferenceLock.standard, loader: ParakeetModelLoader())
    }

    /// Tests and the bench inject a fake transport, lock and loader (or a local mirror as `baseURL`).
    public init(support: URL, descriptor: SpeechModelDescriptor, files: [SpeechModelFile], transport: SpeechModelTransport,
                inferenceLock: InferenceLocking, loader: SpeechModelLoading,
                baseURL: URL = URL(string: "https://huggingface.co")!,
                availableBytes: @escaping @Sendable (URL) -> Int64? = { SpeechModelStore.volumeAvailableBytes($0) }) {
        self.descriptor = descriptor
        self.files = files
        modelsRoot = support.appendingPathComponent("models", isDirectory: true).standardizedFileURL
        directory = modelsRoot.appendingPathComponent(descriptor.directoryName, isDirectory: true)
        self.transport = transport
        self.inferenceLock = inferenceLock
        self.loader = loader
        self.baseURL = baseURL
        self.availableBytes = availableBytes
        // Cheap (one small file and 21 stats): a finished install is `.ready` until a load proves otherwise; the engine
        // runs only once `prepare()` loaded it (`loadedModel`).
        current = .notDownloaded
        if Self.isInstalled(directory: directory, revision: descriptor.revision, files: files) { current = .ready }
    }

    // MARK: SpeechModelStoring

    public func state() async -> SpeechModelState { snapshot }

    public func stateUpdates() -> AsyncStream<SpeechModelState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: SpeechModelState.self, bufferingPolicy: .bufferingNewest(16))
        lock.lock()
        observers[id] = continuation
        continuation.yield(current)
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.observers[id] = nil; self.lock.unlock()
        }
        return stream
    }

    public func download() async {
        await run(.download) { [self] in await performDownload() }
    }

    public func cancel() async {
        let pending = lock.withLock { operationKind == .download ? operation : nil }
        pending?.cancel()
        await pending?.value
    }

    public func delete() async throws {
        let pending = lock.withLock { () -> Task<Void, Never>? in
            if operationKind == .download { operation?.cancel() }
            return operation
        }
        await pending?.value
        // An operation that started meanwhile finishes first; then the delete runs as its own operation.
        while !(await run(.delete) { [self] in performDelete() }) {}
        if case .failed = snapshot { throw DomainError("speech_model_delete_failed", "The speech model could not be deleted.") }
    }

    public func prepare() async {
        await run(.prepare) { [self] in await performPrepare() }
    }

    // MARK: Engine access

    /// The loaded model, nil until `prepare()` (or `download()`) loaded it and again after `delete()`. Non-blocking, so
    /// key-down may read it: a take that starts while it is nil runs Apple only.
    public var loadedModel: SpeechDecoding? {
        lock.lock(); defer { lock.unlock() }
        return model
    }

    var snapshot: SpeechModelState {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    // MARK: Operations

    /// Runs `body` as the store's one operation and returns true, or waits for the one in flight and returns false.
    @discardableResult private func run(_ kind: Operation, _ body: @escaping @Sendable () async -> Void) async -> Bool {
        let (task, joined) = lock.withLock { () -> (Task<Void, Never>, Bool) in
            if let operation { return (operation, true) }
            let task = Task { await body() }
            operation = task
            operationKind = kind
            return (task, false)
        }
        await task.value
        if joined { return false }
        lock.withLock {
            if operation == task { operation = nil; operationKind = nil }
        }
        return true
    }

    private func performDownload() async {
        if snapshot == .ready, loadedModel != nil { return }
        if Self.isInstalled(directory: directory, revision: descriptor.revision, files: files) {
            await performPrepare()
            return
        }
        guard let revision = descriptor.revision else { return set(.failed(message: Failure.unpinned.message)) }
        guard let hold = inferenceLock.tryAcquire() else { return set(.deferredByLock) }
        defer { hold.release() }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        set(.downloading(progress: 0))
        let staging = modelsRoot.appendingPathComponent(".\(descriptor.directoryName).download-\(UUID().uuidString)", isDirectory: true)
        do {
            try Self.makeDirectory(modelsRoot)
            Self.removeLeftovers(in: modelsRoot, name: descriptor.directoryName)
            if let free = availableBytes(modelsRoot), free < total + Self.diskMargin { throw Failure.diskSpace }
            try Self.makeDirectory(staging)
            var done: Int64 = 0
            for file in files {
                try Task.checkCancellation()
                guard let target = Self.child(staging, file.path) else { throw Failure.verification }
                try Self.makeDirectory(target.deletingLastPathComponent(), inside: staging)
                let url = remoteURL(file, revision: revision)
                let base = done
                try await transport.download(url, to: target) { [weak self] received in
                    self?.reportProgress(Double(base + min(received, file.size)) / Double(max(total, 1)))
                }
                try Task.checkCancellation()
                guard Self.verify(target, file) else { throw Failure.verification }
                guard chmod(target.path, Self.fileMode) == 0 else { throw Failure.write }
                done += file.size
                reportProgress(Double(done) / Double(max(total, 1)))
            }
            try Self.writeFile(Self.marker(revision: revision, files: files), to: staging.appendingPathComponent(Self.installMarker))
            try Self.install(staging, at: directory)
        } catch {
            Self.removeTree(staging)
            if error is CancellationError || Task.isCancelled { return set(.notDownloaded) }
            return set(.failed(message: (error as? Failure ?? .network).message))
        }
        await load(firstCompile: true)
    }

    private func performPrepare() async {
        guard Self.isInstalled(directory: directory, revision: descriptor.revision, files: files) else {
            // Nothing to load. A download the benchmark's lock deferred keeps waiting for the user's Try Again: the app
            // calls prepare() at launch, when voice is enabled, when Settings → Voice opens and after takes.
            if snapshot != .deferredByLock { set(.notDownloaded) }
            return
        }
        if loadedModel != nil { return set(.ready) }
        guard let hold = inferenceLock.tryAcquire() else { return set(.deferredByLock) }
        defer { hold.release() }
        await load(firstCompile: !FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.compiledMarker).path))
    }

    /// Loads the installed model; the caller holds the inference lock. A cached load keeps showing `.ready`; the first one
    /// (the Neural Engine compile, 12–33 s) shows `.compiling`. Runs in a task of its own: a load cannot be interrupted, so
    /// cancelling the download that started it does not leave a half-loaded state.
    private func load(firstCompile: Bool) async {
        if firstCompile { set(.compiling) }
        let loader = loader, directory = directory
        let result = await Task { () -> Result<SpeechDecoding, Error> in
            do { return .success(try await loader.load(from: directory)) } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let decoder):
            lock.withLock { model = decoder }
            if firstCompile { try? Self.writeFile(Data(), to: directory.appendingPathComponent(Self.compiledMarker)) }
            set(.ready)
        case .failure:
            set(.failed(message: Failure.load.message))
        }
    }

    private func performDelete() {
        lock.lock(); model = nil; lock.unlock()
        Self.removeLeftovers(in: modelsRoot, name: descriptor.directoryName)
        var removed = true
        if FileManager.default.fileExists(atPath: directory.path) {
            let trash = modelsRoot.appendingPathComponent(".\(descriptor.directoryName).trash-\(UUID().uuidString)", isDirectory: true)
            if rename(directory.path, trash.path) == 0 { Self.removeTree(trash) } else { removed = false }
        }
        removed = removed && !FileManager.default.fileExists(atPath: directory.path)
        set(removed ? .notDownloaded : .failed(message: Failure.write.message))
    }

    // MARK: State

    private func set(_ state: SpeechModelState) {
        lock.lock()
        if case .downloading = state {} else { lastProgressStep = -1 }
        current = state
        let targets = Array(observers.values)
        lock.unlock()
        for observer in targets { observer.yield(state) }
    }

    /// At most one update per 0.5 %, so Settings is not flooded by 64 KB chunks.
    private func reportProgress(_ fraction: Double) {
        let value = min(1, max(0, fraction))
        let step = Int(value * 200)
        lock.lock()
        guard case .downloading = current, step > lastProgressStep else { lock.unlock(); return }
        lastProgressStep = step
        lock.unlock()
        set(.downloading(progress: value))
    }

    func remoteURL(_ file: SpeechModelFile, revision: String) -> URL {
        var url = baseURL
        for part in descriptor.repository.split(separator: "/") { url.appendPathComponent(String(part)) }
        url.appendPathComponent("resolve")
        url.appendPathComponent(revision)
        for part in file.path.split(separator: "/") { url.appendPathComponent(String(part)) }
        return url
    }

    // MARK: Files

    struct Marker: Codable, Equatable {
        var id: String
        var revision: String
        var files: [SpeechModelFile]
    }

    static func marker(revision: String, files: [SpeechModelFile]) throws -> Data {
        try JSONEncoder().encode(Marker(id: "speech-model", revision: revision, files: files))
    }

    /// A complete install of `revision`: the marker names it and every file has its pinned size. (Digests are checked at
    /// download; at launch only sizes are, so the check stays cheap.)
    static func isInstalled(directory: URL, revision: String?, files: [SpeechModelFile]) -> Bool {
        guard let revision, let data = try? Data(contentsOf: directory.appendingPathComponent(installMarker)),
              let marker = try? JSONDecoder().decode(Marker.self, from: data),
              marker.revision == revision, marker.files == files else { return false }
        for file in files {
            guard let url = child(directory, file.path),
                  let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
                  size.int64Value == file.size else { return false }
        }
        return true
    }

    /// Size and SHA-256 of a downloaded file, read in 1 MB chunks.
    static func verify(_ url: URL, _ file: SpeechModelFile) -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
              size.int64Value == file.size, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            // nil (or empty) at the end of the file.
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        } catch {
            return false
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256.lowercased()
    }

    /// `relative` inside `root`, refusing absolute paths and `..` (the manifest is in code, but stay strict).
    static func child(_ root: URL, _ relative: String) -> URL? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.hasPrefix("/"), !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return parts.reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    /// Creates `url` (and its parents up to `inside`, or any missing parents) as 0700, owned by this user, excluded from backups.
    static func makeDirectory(_ url: URL, inside root: URL? = nil) throws {
        var missing: [URL] = []
        var cursor = url.standardizedFileURL
        let stop = root?.standardizedFileURL.path
        while !FileManager.default.fileExists(atPath: cursor.path), cursor.path != "/", cursor.path != stop {
            missing.append(cursor)
            cursor = cursor.deletingLastPathComponent()
        }
        for directory in missing.reversed() {
            guard mkdir(directory.path, directoryMode) == 0 || errno == EEXIST else { throw Failure.write }
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { throw Failure.write }
        if info.st_mode & 0o777 != directoryMode { guard chmod(url.path, directoryMode) == 0 else { throw Failure.write } }
        excludeFromBackup(url)
    }

    static func excludeFromBackup(_ url: URL) {
        var target = URL(fileURLWithPath: url.path)
        if (try? target.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup != true {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? target.setResourceValues(values)
        }
    }

    static func writeFile(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: Int(fileMode)]),
              chmod(temporary.path, fileMode) == 0, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw Failure.write
        }
    }

    /// One rename makes the verified staging directory the install; an older install is moved aside first and removed.
    static func install(_ staging: URL, at directory: URL) throws {
        let parent = directory.deletingLastPathComponent()
        var aside: URL?
        if FileManager.default.fileExists(atPath: directory.path) {
            let trash = parent.appendingPathComponent(".\(directory.lastPathComponent).trash-\(UUID().uuidString)", isDirectory: true)
            guard rename(directory.path, trash.path) == 0 else { throw Failure.write }
            aside = trash
        }
        guard rename(staging.path, directory.path) == 0 else {
            if let aside { _ = rename(aside.path, directory.path) }
            throw Failure.write
        }
        if let aside { removeTree(aside) }
        excludeFromBackup(directory)
    }

    /// Removes partial downloads and set-aside installs of `name` left by an interrupted run.
    static func removeLeftovers(in root: URL, name: String) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for entry in entries where entry.hasPrefix(".\(name).download-") || entry.hasPrefix(".\(name).trash-") {
            removeTree(root.appendingPathComponent(entry, isDirectory: true))
        }
    }

    static func removeTree(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    public static func volumeAvailableBytes(_ url: URL) -> Int64? {
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
