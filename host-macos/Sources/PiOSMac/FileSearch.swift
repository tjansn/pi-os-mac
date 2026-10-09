import Foundation
import CoreServices
import PiOSCore

/// Thread-safe host file tokens (random 128-bit, TTL 10 min, ≤ 500 live). Only
/// LauncherService resolves them; Node and cards only ever hold the opaque token.
public final class FileTokenStore: @unchecked Sendable {
    private let lock = NSLock()
    private var table: FileTokenTable
    private var random = SystemRandomNumberGenerator()
    private let clock: () -> Date

    public init(ttl: TimeInterval = FileTokenTable.defaultTTL, capacity: Int = FileTokenTable.defaultCapacity,
                clock: @escaping () -> Date = { Date() }) {
        table = FileTokenTable(ttl: ttl, capacity: capacity); self.clock = clock
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return table.count }

    func mint(path: String, contentType: String?, contextId: String?) -> String {
        lock.lock(); defer { lock.unlock() }
        return table.mint(path: path, contentType: contentType, contextId: contextId, now: clock(), using: &random)
    }

    /// Internal on purpose: LauncherService is the only caller.
    func resolve(_ token: String, contextId: String?) throws -> FileTokenRecord {
        lock.lock(); defer { lock.unlock() }
        return try table.resolve(token, contextId: contextId, now: clock())
    }

    /// Call when a pinned context is discarded; its tokens stop resolving immediately.
    public func revoke(contextId: String) {
        lock.lock(); defer { lock.unlock() }
        table.revoke(contextId: contextId)
    }
}

/// Runs blocking system work on a serial queue with a deadline. A late result is discarded,
/// and work that has not started by its deadline is skipped, so stale searches cannot pile up.
enum LauncherDeadline {
    static func run<T>(on queue: DispatchQueue, seconds: TimeInterval, timeout: DomainError,
                       _ work: @escaping () throws -> T) async throws -> T {
        try await run(on: queue, seconds: seconds, timeout: timeout) { _ in try work() }
    }
    /// The same, and `work` can ask whether its caller is already gone (timed out, cancelled or
    /// disconnected) so it can skip optional follow-up work.
    static func run<T>(on queue: DispatchQueue, seconds: TimeInterval, timeout: DomainError,
                       _ work: @escaping (_ abandoned: () -> Bool) throws -> T) async throws -> T {
        try await callback(seconds: seconds, onTimeout: .failure(timeout)) { done, isFinished in
            queue.async {
                guard !isFinished() else { return }
                done(Result { try work(isFinished) })
            }
        }
    }

    /// Bridges a completion-handler API; whichever of completion, timeout or cancellation
    /// comes first wins and later results are dropped.
    static func callback<T>(seconds: TimeInterval, onTimeout: Result<T, Error>,
                            _ start: (@escaping (Result<T, Error>) -> Void, @escaping () -> Bool) -> Void) async throws -> T {
        let gate = Gate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                start({ gate.finish($0) }, { gate.isFinished })
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                    gate.finish(onTimeout)
                }
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    private final class Gate<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var result: Result<T, Error>?
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }
        func install(_ continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result); return }
            self.continuation = continuation
            lock.unlock()
        }
        func finish(_ result: Result<T, Error>) {
            lock.lock()
            guard self.result == nil else { lock.unlock(); return }
            self.result = result
            let continuation = self.continuation; self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }
}

/// In-process Spotlight file search (raycast research §3.2/§12.2: word-prefix `cdw` name
/// queries with value-list attributes take ~45 ms warm, versus ~300 ms for `mdfind`).
/// Scope is the home folder unless the request names others. Results never include .Trash,
/// hidden or ~/Library items (except iCloud Drive) or bundle internals, and paths are never logged.
public final class FileSearch: @unchecked Sendable {
    /// (query, scope directories, max results) → raw hits. Injectable so tests use fixture hits.
    public typealias Engine = @Sendable (_ query: String, _ scopes: [String], _ maxCount: Int) throws -> [SpotlightHit]
    public static let queryCap = 200
    /// Below this many usable word-prefix hits, a substring query runs if time allows.
    public static let fallbackThreshold = 5

    private let tokens: FileTokenStore
    private let home: String
    private let timeout: TimeInterval
    private let engine: Engine
    private let queue = DispatchQueue(label: "dev.pi-os.launcher.file-search", qos: .userInitiated)
    /// Incremented by every `search()`; a search is superseded once a newer one was enqueued.
    private let generationLock = NSLock()
    private var generation = 0

    /// Searches started so far (tests wait on it instead of sleeping).
    var startedSearches: Int { generationLock.withLock { generation } }

    public init(tokens: FileTokenStore, home: String = NSHomeDirectory(), timeout: TimeInterval = 1.5,
                engine: @escaping Engine = FileSearch.spotlight) {
        self.tokens = tokens; self.home = home; self.timeout = timeout; self.engine = engine
    }

    /// Latest-wins on the serial queue: rapid previews must not keep it busy ahead of the final.
    /// Work whose caller is gone (Node aborted it, which closes the connection; a timeout; a
    /// cancellation) never starts. A running search skips its substring fallback, returning the
    /// word-prefix hits, once its caller is gone or a newer search is already waiting. A superseded
    /// search whose caller still waits still runs its primary query: the agent's find_files calls
    /// may run in parallel and must not fail just because another search was queued after them.
    public func search(_ request: FileSearchRequest) async throws -> FileSearchResult {
        let started = DispatchTime.now().uptimeNanoseconds
        let mine = generationLock.withLock { generation += 1; return generation }
        let superseded = { [weak self] in self.map { search in search.generationLock.withLock { search.generation != mine } } ?? true }
        let limit = request.maxResults ?? FileSearchRequest.defaultMaxResults
        guard (1...FileSearchRequest.maxResultsLimit).contains(limit) else {
            throw DomainError("invalid_arguments", "maxResults must be 1–\(FileSearchRequest.maxResultsLimit).")
        }
        let scopes = request.scopes ?? [.home]
        guard !scopes.isEmpty else { throw DomainError("invalid_arguments", "At least one search scope is required.") }
        let groups = try SpotlightQuery.normalizedGroups(request.nameGroups)
        let primary = try SpotlightQuery.withContentType(SpotlightQuery.names(groups), request.contentType)
        let fallback = try SpotlightQuery.substringFallback(groups).map { try SpotlightQuery.withContentType($0, request.contentType) }
        let roots = Self.roots(scopes, home: home)
        let (engine, home, cap, budget) = (self.engine, self.home, Self.queryCap, timeout)
        let gathered = try await LauncherDeadline.run(
            on: queue, seconds: timeout,
            timeout: DomainError("search_timeout", "File search took too long. Try a more specific name.")) { abandoned throws -> (hits: [SpotlightHit], capped: Bool) in
            var hits = try engine(primary, roots, cap)
            var capped = hits.count >= cap
            let usable = SpotlightResults.select(hits, roots: roots, home: home, limit: cap, capped: false).hits.count
            let spent = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            if usable < Self.fallbackThreshold, let fallback, spent < budget / 2, !abandoned(), !superseded() {
                let more = try engine(fallback, roots, cap)
                capped = capped || more.count >= cap
                hits += more
            }
            return (hits, capped)
        }
        let selection = SpotlightResults.select(gathered.hits, roots: roots, home: home, limit: limit, capped: gathered.capped)
        let contextId = request.contextId.flatMap { $0.isEmpty ? nil : $0 }
        let items = selection.hits.map { hit in
            SpotlightResults.candidate(hit, token: tokens.mint(path: hit.path, contentType: hit.contentType, contextId: contextId))
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        if ProcessInfo.processInfo.environment["PI_OS_PERF"] == "1" {
            print("[perf] launcher.searchFiles ms=\(elapsed) hits=\(items.count) truncated=\(selection.truncated)"); fflush(stdout)
        }
        return FileSearchResult(items: items, truncated: selection.truncated, elapsedMs: (elapsed * 10).rounded() / 10)
    }

    static func roots(_ scopes: [FileSearchScope], home: String) -> [String] {
        var roots: [String] = []
        for scope in scopes {
            let added: [String]
            switch scope {
            case .home: added = [home]
            case .applications: added = ["/Applications", "/System/Applications", home + "/Applications"]
            case .icloud: added = [home + "/Library/Mobile Documents/com~apple~CloudDocs"]
            }
            for root in added where !roots.contains(root) { roots.append(root) }
        }
        return roots
    }

    /// Synchronous MDQuery on the calling (background) thread. Paths come from the item
    /// (cheap); everything else from value lists, never per-item attribute dictionaries.
    @Sendable public static func spotlight(query: String, scopes: [String], maxCount: Int) throws -> [SpotlightHit] {
        let useCount = "kMDItemUseCount" as CFString
        let attributes = [kMDItemFSName, kMDItemContentType, kMDItemContentCreationDate, kMDItemContentModificationDate,
                          kMDItemLastUsedDate, useCount] as CFArray
        guard let md = MDQueryCreate(kCFAllocatorDefault, query as CFString, attributes, nil) else {
            throw DomainError("invalid_arguments", "The file search could not be built.")
        }
        MDQuerySetSearchScope(md, scopes as CFArray, 0)
        MDQuerySetMaxCount(md, maxCount)
        guard MDQueryExecute(md, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
            throw DomainError("search_unavailable", "Spotlight search is unavailable. Check that Spotlight indexing is on.")
        }
        var hits: [SpotlightHit] = []
        for index in 0..<MDQueryGetResultCount(md) {
            guard let raw = MDQueryGetResultAtIndex(md, index),
                  let path = MDItemCopyAttribute(Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue(), kMDItemPath) as? String else { continue }
            func value(_ name: CFString) -> CFTypeRef? {
                MDQueryGetAttributeValueOfResultAtIndex(md, name, index).map { Unmanaged<CFTypeRef>.fromOpaque($0).takeUnretainedValue() }
            }
            hits.append(SpotlightHit(path: path, name: value(kMDItemFSName) as? String, contentType: value(kMDItemContentType) as? String,
                                     created: value(kMDItemContentCreationDate) as? Date, modified: value(kMDItemContentModificationDate) as? Date,
                                     lastUsed: value(kMDItemLastUsedDate) as? Date, useCount: (value(useCount) as? NSNumber)?.intValue))
        }
        return hits
    }
}
