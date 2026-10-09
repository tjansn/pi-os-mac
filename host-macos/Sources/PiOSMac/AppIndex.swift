import AppKit
import CoreServices
import PiOSCore

/// One installed application as found on disk, before running state is applied.
public struct AppSeed: Equatable, Sendable {
    public var bundleId: String
    public var path: String
    /// Localized display name (FileManager.displayName), e.g. "Rechner" on a German system.
    public var name: String
    /// Other names a user may type or say: CFBundleDisplayName, CFBundleName, file name.
    public var alternateNames: [String]
    public init(bundleId: String, path: String, name: String, alternateNames: [String] = []) {
        self.bundleId = bundleId; self.path = path; self.name = name; self.alternateNames = alternateNames
    }
}

/// Cached index of installed applications for launcher.listApps and openApp validation.
/// One in-process MDQuery over the application folders (raycast research §3.2: 3–10 ms) plus
/// Info.plist names (~50–100 ms for ~110 apps, measured), built off the main thread. There is no
/// resident timer (the idle invariant): a list older than 60 s is served once and rebuilt in the
/// background, and launch/terminate notifications bump the version.
public final class AppIndex: @unchecked Sendable {
    public typealias Scanner = @Sendable () throws -> [AppSeed]
    public typealias RunningProvider = @Sendable () async -> Set<String>
    public static let refreshInterval: TimeInterval = 60

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.pi-os.launcher.app-index", qos: .userInitiated)
    private let scanner: Scanner
    private let running: RunningProvider
    private let maxAge: TimeInterval
    private let observeWorkspace: Bool
    private var seeds: [AppSeed]?
    private var builtAt = Date.distantPast
    private var generation = 1
    private var stale = false
    private var refreshing = false
    private var lastRunning: Set<String>?
    private var observers: [NSObjectProtocol] = []
    private var observing = false

    public init(scanner: @escaping Scanner = AppIndex.spotlightScan, running: @escaping RunningProvider = AppIndex.runningBundleIDs,
                maxAge: TimeInterval = AppIndex.refreshInterval, observeWorkspace: Bool = true) {
        self.scanner = scanner; self.running = running; self.maxAge = maxAge; self.observeWorkspace = observeWorkspace
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
    }

    public func list() async throws -> AppIndexResult {
        await startObserving()
        let seeds: [AppSeed]
        if let cached = cachedSeeds() { seeds = cached } else { seeds = try await rebuild() }
        let runningNow = await running()
        return AppIndexResult(version: "apps-\(noteRunning(runningNow))", apps: Self.records(seeds, running: runningNow))
    }

    /// Cached seeds; a stale list is still served while one background rebuild runs.
    private func cachedSeeds() -> [AppSeed]? {
        let (seeds, refresh) = lock.withLock { () -> ([AppSeed]?, Bool) in
            guard let seeds else { return (nil, false) }
            let refresh = (stale || Date().timeIntervalSince(builtAt) > maxAge) && !refreshing
            if refresh { refreshing = true }
            return (seeds, refresh)
        }
        if refresh {
            Task.detached(priority: .utility) { [self] in
                _ = try? await rebuild()
                lock.withLock { refreshing = false }
            }
        }
        return seeds
    }

    /// Running-state changes are index changes for Node's version cache.
    private func noteRunning(_ running: Set<String>) -> Int {
        lock.withLock {
            if lastRunning != running {
                if lastRunning != nil { generation += 1 }
                lastRunning = running
            }
            return generation
        }
    }

    @discardableResult
    private func rebuild() async throws -> [AppSeed] {
        let scanned = try await LauncherDeadline.run(on: queue, seconds: 5,
                                                     timeout: DomainError("apps_unavailable", "The app list is not ready yet."), scanner)
        return store(scanned)
    }

    private func store(_ scanned: [AppSeed]) -> [AppSeed] {
        lock.withLock {
            if let seeds, seeds != scanned { generation += 1 }
            seeds = scanned; builtAt = Date(); stale = false
            return scanned
        }
    }

    private func startObserving() async {
        guard observeWorkspace, lock.withLock({ () -> Bool in defer { observing = true }; return !observing }) else { return }
        let tokens = await MainActor.run { () -> [NSObjectProtocol] in
            let center = NSWorkspace.shared.notificationCenter
            return [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
                center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    self?.workspaceChanged(launched: name == NSWorkspace.didLaunchApplicationNotification ? app?.bundleIdentifier : nil)
                }
            }
        }
        lock.withLock { observers = tokens }
    }

    /// A launch of an app the index does not know (for example a fresh install) forces a rebuild.
    func workspaceChanged(launched bundleId: String?) {
        lock.withLock {
            generation += 1
            if let bundleId, let seeds, !seeds.contains(where: { $0.bundleId.caseInsensitiveCompare(bundleId) == .orderedSame }) {
                stale = true
            }
        }
    }

    /// Pure: drops invalid IDs, pi-os itself and apps nested in other bundles, keeps the first
    /// copy of each bundle ID, and lists aliases (always including the name) without duplicates.
    static func records(_ seeds: [AppSeed], running: Set<String>) -> [AppRecord] {
        var seen = Set<String>()
        var records: [AppRecord] = []
        for seed in seeds {
            let key = seed.bundleId.lowercased()
            guard LauncherPolicy.isBundleID(seed.bundleId), !LauncherPolicy.isBlockedBundle(seed.bundleId),
                  !isNested(seed.path), seen.insert(key).inserted else { continue }
            let fileName = ((seed.path as NSString).lastPathComponent as NSString).deletingPathExtension
            let name = [seed.name, seed.alternateNames.first ?? "", fileName].map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? seed.bundleId
            var aliases: [String] = []
            for alias in seed.alternateNames + [name] {
                let trimmed = alias.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, !aliases.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) { aliases.append(trimmed) }
            }
            records.append(AppRecord(bundleId: seed.bundleId, name: name, aliases: aliases, path: seed.path, running: running.contains(key)))
        }
        return records.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func isNested(_ path: String) -> Bool {
        path.split(separator: "/").dropLast().contains { $0.lowercased().hasSuffix(".app") }
    }

    /// Lower-cased bundle IDs of running apps (read on the main actor).
    @Sendable public static func runningBundleIDs() async -> Set<String> {
        await MainActor.run { Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() }) }
    }

    /// Application bundles in /Applications, /System/Applications (both include Utilities) and
    /// ~/Applications, plus Finder. Reads bundle metadata only; nothing is launched.
    @Sendable public static func spotlightScan() throws -> [AppSeed] {
        let roots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        guard let md = MDQueryCreate(kCFAllocatorDefault, SpotlightQuery.applications as CFString, [kMDItemCFBundleIdentifier] as CFArray, nil) else {
            throw DomainError("apps_unavailable", "The app list could not be built.")
        }
        MDQuerySetSearchScope(md, roots as CFArray, 0)
        MDQuerySetMaxCount(md, 5_000)
        guard MDQueryExecute(md, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
            throw DomainError("apps_unavailable", "Spotlight is unavailable, so the app list could not be built.")
        }
        var found: [(path: String, bundleId: String)] = []
        for index in 0..<MDQueryGetResultCount(md) {
            guard let raw = MDQueryGetResultAtIndex(md, index),
                  let path = MDItemCopyAttribute(Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue(), kMDItemPath) as? String,
                  let value = MDQueryGetAttributeValueOfResultAtIndex(md, kMDItemCFBundleIdentifier, index),
                  let bundleId = Unmanaged<CFTypeRef>.fromOpaque(value).takeUnretainedValue() as? String else { continue }
            found.append((path, bundleId))
        }
        // Deterministic preference when two copies share a bundle ID: root order, then path.
        func rank(_ path: String) -> Int { roots.firstIndex { path.hasPrefix($0 + "/") } ?? roots.count }
        found.sort { (rank($0.path), $0.path) < (rank($1.path), $1.path) }
        let finder = "/System/Library/CoreServices/Finder.app"
        if let info = CFBundleCopyInfoDictionaryForURL(URL(fileURLWithPath: finder, isDirectory: true) as CFURL) as? [String: Any],
           let bundleId = info["CFBundleIdentifier"] as? String {
            found.append((finder, bundleId))
        }
        return found.map { seed(path: $0.path, bundleId: $0.bundleId) }
    }

    static func seed(path: String, bundleId: String) -> AppSeed {
        func bare(_ name: String) -> String { name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name }
        let info = CFBundleCopyInfoDictionaryForURL(URL(fileURLWithPath: path, isDirectory: true) as CFURL) as? [String: Any] ?? [:]
        let fileName = bare((path as NSString).lastPathComponent)
        let names = [info["CFBundleDisplayName"] as? String, info["CFBundleName"] as? String, fileName].compactMap { $0 }
        return AppSeed(bundleId: bundleId, path: path, name: bare(FileManager.default.displayName(atPath: path)), alternateNames: names)
    }
}
