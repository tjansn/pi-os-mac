import AppKit
import ApplicationServices
import UniformTypeIdentifiers
import PiOSCore

// Visible items (protocol.md "Visible items"; Tom, 2026-10-08: "öffne Radfotos" on the desktop opens the desktop's
// Radfotos folder before anything else is tried). At key-down the host captures, in the background, what the user sees
// in the take's target: the Finder desktop's icons, or the items of the target Finder window, through public AX reads
// under a budget; a Spotlight query for the folder's direct children when no item is readable (desktop icons hidden,
// a view without item URLs). Never AppleScript or Apple Events, never FileManager enumeration (that raises the
// Desktop folder's privacy prompt), and no file is opened or stat'ed. Host file tokens are minted only for the items a
// route call returns, bound to the take's contextId, and the capture is dropped with the context. Names and paths are
// user content: nothing here logs them (the perf line carries kinds, counts and durations only).

/// One visible file or folder before it becomes a token. `path` is never logged.
public struct VisibleEntry: Equatable, Sendable {
    public var path: String
    public var name: String
    public var contentType: String?
    public var isDirectory: Bool
    public var isPackage: Bool
    public var created: Date?
    public var modified: Date?
    public var lastUsed: Date?
    public var useCount: Int?
    public init(path: String, name: String, contentType: String? = nil, isDirectory: Bool = false, isPackage: Bool = false,
                created: Date? = nil, modified: Date? = nil, lastUsed: Date? = nil, useCount: Int? = nil) {
        self.path = path; self.name = name; self.contentType = contentType; self.isDirectory = isDirectory; self.isPackage = isPackage
        self.created = created; self.modified = modified; self.lastUsed = lastUsed; self.useCount = useCount
    }
}

/// What one capture read. `source` nil: the target is neither the desktop nor a readable Finder window (no items).
public struct VisibleCapture: Equatable, Sendable {
    public var source: VisibleSource?
    /// Display order (AX), or by name (Spotlight); at most `VisibleItemsLimits.maxResults`.
    public var entries: [VisibleEntry]
    /// More items were visible than the capture keeps.
    public var truncated: Bool
    public init(source: VisibleSource?, entries: [VisibleEntry], truncated: Bool = false) {
        self.source = source; self.entries = entries; self.truncated = truncated
    }
    public static let none = VisibleCapture(source: nil, entries: [])
}

/// The take's target as far as visible items go. WindowContext is a plain value; it only crosses to the capture queue.
public enum VisibleTarget: Equatable, @unchecked Sendable {
    /// The Finder desktop surface and the desktop folder it shows.
    case desktop(WindowContext, folder: String)
    /// A regular Finder window (its folder is read through AX at capture time).
    case finderWindow(WindowContext)

    public var kind: VisibleSourceKind {
        switch self {
        case .desktop: .desktop
        case .finderWindow: .finderWindow
        }
    }

    /// The Finder desktop surface → desktop; another Finder window → finderWindow; any other target → nil (no items).
    /// Cheap (no AX, no file system): safe at key-down on the main thread.
    public static func classify(_ window: WindowContext?, bundleId: String?) -> VisibleTarget? {
        guard let window else { return nil }
        if window.surface == FinderContextPolicy.desktopSurface {
            let folder = window.shellFolderPath ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
            return folder.map { .desktop(window, folder: VisibleItemsPolicy.normalized($0)) }
        }
        return bundleId == "com.apple.finder" ? .finderWindow(window) : nil
    }
}

/// An accessibility tree as the visible-items walk needs it (fakes in tests, `NativeVisibleTree` in the app).
public protocol VisibleTreeReader {
    associatedtype Node
    /// The AX budget is spent: the walk stops (incomplete).
    var exhausted: Bool { get }
    /// At most `limit` children and the element's total child count; nil when they cannot be read.
    func children(_ node: Node, limit: Int) -> (nodes: [Node], total: Int)?
    /// The element's file URL (kAXURLAttribute), if it has one.
    func fileURL(_ node: Node) -> URL?
}

/// The result of one bounded walk.
public struct VisibleWalk: Equatable {
    public var entries: [VisibleEntry]
    public var truncated: Bool
    /// False when the budget, the node bound or an unreadable or partial child list ended the walk early.
    public var complete: Bool
}

public enum VisibleItemsPolicy {
    /// Elements one walk visits at most.
    public static let maxNodes = 2_000
    /// Children read per element at most.
    public static let maxChildren = 1_000
    /// AX budget of one capture (seconds); the desktop takes about 30 ms.
    public static let axSeconds: TimeInterval = 0.3
    /// Raw Spotlight hits per fallback query: the folder's whole subtree matches, direct children are filtered here.
    /// A desktop with 13 000 nested items took about 650 ms (macOS 27), largely independent of this cap.
    public static let spotlightCap = 20_000
    /// A query every indexed item satisfies. `kMDItemFSName == "*"` matches nothing (verified on macOS 27).
    public static let everyItemQuery = #"kMDItemDisplayName == "*""#

    /// A folder path as items are compared against it: lexically standardized, without a trailing "/". Never touches
    /// the file system (no stat, which could raise a Files & Folders prompt).
    public static func normalized(_ folder: String) -> String {
        URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL.path
    }

    /// A direct child of `folder` that may be listed: not hidden, a valid single-line name and an absolute path.
    static func listable(path: String, name: String, folder: String) -> Bool {
        (path as NSString).deletingLastPathComponent == folder && !name.hasPrefix(".")
            && VoiceText.isValid(name, max: VisibleItemsLimits.maxNameChars) && AttachmentValidation.isAbsoluteHostPath(path)
    }

    /// An item of `folder` from a file URL (an AX item's kAXURLAttribute), without file-system access: Finder reports
    /// folders and packages with a trailing "/", and the type follows from the extension. A file whose extension maps to
    /// no declared type has no contentType (LauncherService then reveals it unless the live file says otherwise).
    public static func entry(url: URL, folder: String) -> VisibleEntry? {
        guard url.isFileURL else { return nil }
        let directory = url.hasDirectoryPath
        let path = url.standardizedFileURL.path
        let name = (path as NSString).lastPathComponent
        guard listable(path: path, name: name, folder: folder) else { return nil }
        let ext = (name as NSString).pathExtension.lowercased()
        let type = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        let package = directory && (SpotlightResults.packageExtensions.contains(ext) || type?.conforms(to: .package) == true)
        let contentType: String?
        if directory && !package { contentType = UTType.folder.identifier }
        else if let type, !type.isDynamic { contentType = type.identifier }
        else { contentType = nil }
        return VisibleEntry(path: path, name: name, contentType: contentType, isDirectory: directory && !package, isPackage: package)
    }

    /// An item of `folder` from a Spotlight hit (metadata only).
    public static func entry(hit: SpotlightHit, folder: String) -> VisibleEntry? {
        let path = hit.path
        let name = (path as NSString).lastPathComponent
        guard listable(path: path, name: name, folder: folder) else { return nil }
        let kind = SpotlightResults.kind(contentType: hit.contentType)
        return VisibleEntry(path: path, name: name, contentType: hit.contentType, isDirectory: kind.isDirectory, isPackage: kind.isPackage,
                            created: hit.created, modified: hit.modified, lastUsed: hit.lastUsed, useCount: hit.useCount)
    }

    /// Breadth-first under `root`, at most `maxDepth` levels and `maxNodes` elements: every element whose file URL is a
    /// direct child of `folder`, once per path, in display order. An element with a URL is an item: its own children
    /// (labels, badges) are not read. Elements elsewhere (a sidebar, a path bar, an expanded subfolder) are left out by
    /// the folder check.
    public static func collect<R: VisibleTreeReader>(reader: R, root: R.Node, folder: String, maxDepth: Int,
                                                     limit: Int = VisibleItemsLimits.maxResults, maxNodes: Int = maxNodes) -> VisibleWalk {
        var queue: [(node: R.Node, depth: Int)] = [(root, 0)]
        var head = 0, complete = true, truncated = false
        var seen = Set<String>(), entries: [VisibleEntry] = []
        walk: while head < queue.count {
            guard !reader.exhausted, head < maxNodes else { complete = false; break }
            let (node, depth) = queue[head]
            head += 1
            if depth > 0, let url = reader.fileURL(node) {
                if let entry = entry(url: url, folder: folder), seen.insert(entry.path).inserted {
                    guard entries.count < limit else { truncated = true; break walk }
                    entries.append(entry)
                }
                continue
            }
            guard depth < maxDepth else { continue }
            guard let read = reader.children(node, limit: maxChildren) else { complete = false; continue }
            if read.total > read.nodes.count { complete = false }
            queue.append(contentsOf: read.nodes.map { ($0, depth + 1) })
        }
        return VisibleWalk(entries: entries, truncated: truncated, complete: complete && !truncated)
    }

    /// The direct children of `folder` among a Spotlight query's hits: by name, at most `limit`.
    public static func spotlightCapture(_ hits: [SpotlightHit], folder: String, kind: VisibleSourceKind, capped: Bool,
                                        limit: Int = VisibleItemsLimits.maxResults) -> VisibleCapture {
        var seen = Set<String>()
        let entries = hits.compactMap { entry(hit: $0, folder: folder) }.filter { seen.insert($0.path).inserted }
            .sorted { a, b in
                let order = a.name.localizedStandardCompare(b.name)
                return order == .orderedSame ? a.path < b.path : order == .orderedAscending
            }
        return VisibleCapture(source: VisibleSource(kind: kind, via: .spotlight, complete: !capped && entries.count <= limit),
                              entries: Array(entries.prefix(limit)), truncated: entries.count > limit)
    }
}

/// Where a capture's items come from: blocking AX and Spotlight reads, called on the provider's queue (never the main thread).
public protocol VisibleItemsSource: Sendable {
    func capture(_ target: VisibleTarget) -> VisibleCapture
}

/// Public AX reads of one element tree under a shared budget (the visible-items walk).
final class NativeVisibleTree: VisibleTreeReader {
    let budget: DesktopAX.Budget
    init(budget: DesktopAX.Budget) { self.budget = budget }
    var exhausted: Bool { Date() >= budget.deadline }
    func children(_ node: AXUIElement, limit: Int) -> (nodes: [AXUIElement], total: Int)? {
        guard !exhausted else { return nil }
        AXUIElementSetMessagingTimeout(node, Float(min(0.05, max(0.001, budget.deadline.timeIntervalSinceNow))))
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(node, kAXChildrenAttribute as CFString, &count) == .success, count >= 0 else { return nil }
        guard count > 0 else { return ([], 0) }
        guard !exhausted else { return nil }
        AXUIElementSetMessagingTimeout(node, Float(min(0.05, max(0.001, budget.deadline.timeIntervalSinceNow))))
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(node, kAXChildrenAttribute as CFString, 0, min(count, limit), &values) == .success,
              let elements = values as? [AXUIElement] else { return nil }
        return (elements, count)
    }
    func fileURL(_ node: AXUIElement) -> URL? {
        let raw = budget.read(node, kAXURLAttribute)
        let url = (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:))
        return url?.isFileURL == true ? url : nil
    }
}

/// The app's source: the desktop's icons (Finder's desktop scroll area → group → icons with file URLs) or a Finder
/// window's items through AX, else Spotlight for the folder's direct children.
public final class NativeVisibleItemsSource: VisibleItemsSource, @unchecked Sendable {
    private let axSeconds: TimeInterval
    private let engine: FileSearch.Engine
    public init(axSeconds: TimeInterval = VisibleItemsPolicy.axSeconds, engine: @escaping FileSearch.Engine = FileSearch.spotlight) {
        self.axSeconds = axSeconds; self.engine = engine
    }

    public func capture(_ target: VisibleTarget) -> VisibleCapture {
        switch target {
        case .desktop(let window, let folder):
            if let walk = desktopIcons(window, folder: folder), !walk.entries.isEmpty {
                return VisibleCapture(source: VisibleSource(kind: .desktop, via: .ax, complete: walk.complete), entries: walk.entries,
                                      truncated: walk.truncated)
            }
            return spotlight(folder, kind: .desktop)
        case .finderWindow(let window):
            guard let (walk, folder) = windowItems(window) else { return .none }
            if !walk.entries.isEmpty {
                return VisibleCapture(source: VisibleSource(kind: .finderWindow, via: .ax, complete: walk.complete), entries: walk.entries,
                                      truncated: walk.truncated)
            }
            return spotlight(folder, kind: .finderWindow)
        }
    }

    /// The pinned desktop's container (the same unambiguous match desktop input uses), then its icons.
    private func desktopIcons(_ window: WindowContext, folder: String) -> VisibleWalk? {
        guard AXIsProcessTrusted(), let frame = try? DesktopIdentity.revalidate(window) else { return nil }
        let finder = NativeFinderTree(seconds: axSeconds)
        guard let container = FinderDesktop.container(target: window, frame: frame, reader: finder) else { return nil }
        return VisibleItemsPolicy.collect(reader: NativeVisibleTree(budget: finder.budget), root: container.element, folder: folder, maxDepth: 3)
    }

    /// The exact pinned Finder window, its folder (AXDocument) and the items of that folder it shows.
    private func windowItems(_ window: WindowContext) -> (VisibleWalk, String)? {
        guard AXIsProcessTrusted(), FinderDesktop.eligible(pid: window.processId), let frame = try? DesktopIdentity.revalidate(window) else { return nil }
        let budget = DesktopAX.Budget(axSeconds)
        guard let element = try? DesktopAX.matchWindow(window, frame: frame, budget: budget),
              let document = budget.read(element, kAXDocumentAttribute) as? String,
              let url = URL(string: document), url.isFileURL else { return nil }
        let folder = VisibleItemsPolicy.normalized(url.path)
        return (VisibleItemsPolicy.collect(reader: NativeVisibleTree(budget: budget), root: element, folder: folder, maxDepth: 12), folder)
    }

    private func spotlight(_ folder: String, kind: VisibleSourceKind) -> VisibleCapture {
        do {
            let hits = try engine(VisibleItemsPolicy.everyItemQuery, [folder], VisibleItemsPolicy.spotlightCap)
            return VisibleItemsPolicy.spotlightCapture(hits, folder: folder, kind: kind, capped: hits.count >= VisibleItemsPolicy.spotlightCap)
        } catch {
            return VisibleCapture(source: VisibleSource(kind: kind, via: .spotlight, complete: false), entries: [])
        }
    }
}

/// Kinds, counts and durations only: never a name, path, token or contextId.
public struct VisibleTraceEvent: Equatable, Sendable {
    /// "desktop", "finderWindow" or "none".
    public var kind: String
    /// "ax", "spotlight" or "-".
    public var via: String
    public var items: Int
    public var complete: Bool
    /// The capture was not in yet when the route answered (it waited up to 150 ms).
    public var waited: Bool
    public var timedOut: Bool
    public var routeMs: Double
    public var line: String {
        "[perf] launcher.visibleItems kind=\(kind) via=\(via) items=\(items) complete=\(complete) waited=\(waited) timedOut=\(timedOut) ms=\(routeMs)"
    }
}

/// The take's visible items: captured in the background at key-down (`prefetch`), answered from that capture by
/// POST /tools/launcher.visibleItems (waiting ≤ 150 ms for a capture still running), dropped with the context.
public final class VisibleItemsProvider: @unchecked Sendable {
    public static let routeWait: TimeInterval = 0.15
    /// Contexts kept at most (each is normally dropped with its take; this bounds a missed drop).
    public static let maxContexts = 8

    private final class Pending: @unchecked Sendable {
        let kind: VisibleSourceKind
        let via: VisibleSourceVia
        private let lock = NSLock()
        private var result: VisibleCapture?
        private var waiters: [(VisibleCapture) -> Void] = []
        private var droppedFlag = false
        init(kind: VisibleSourceKind, via: VisibleSourceVia) { self.kind = kind; self.via = via }
        var dropped: Bool { lock.withLock { droppedFlag } }
        var finished: VisibleCapture? { lock.withLock { result } }
        func drop() { lock.withLock { droppedFlag = true } }
        func fulfill(_ capture: VisibleCapture) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = capture
            let waiting = waiters; waiters = []
            lock.unlock()
            waiting.forEach { $0(capture) }
        }
        func notify(_ waiter: @escaping (VisibleCapture) -> Void) {
            lock.lock()
            if let result { lock.unlock(); waiter(result); return }
            waiters.append(waiter)
            lock.unlock()
        }
    }

    private let source: VisibleItemsSource
    private let tokens: FileTokenStore
    private let wait: TimeInterval
    private let queue = DispatchQueue(label: "dev.pi-os.launcher.visible-items", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: [String: Pending] = [:]
    private var order: [String] = []
    /// Content-free audit; by default a line is printed only when PI_OS_PERF=1.
    public var trace: (@Sendable (VisibleTraceEvent) -> Void)? = { event in
        guard ProcessInfo.processInfo.environment["PI_OS_PERF"] == "1" else { return }
        print(event.line); fflush(stdout)
    }

    public init(source: VisibleItemsSource, tokens: FileTokenStore, wait: TimeInterval = VisibleItemsProvider.routeWait) {
        self.source = source; self.tokens = tokens; self.wait = wait
    }

    /// Starts capturing `contextId`'s visible items on a background queue; nil (another app's window) captures nothing.
    /// Cheap on the calling thread. A newer prefetch of the same context replaces the older one.
    public func prefetch(contextId: String, target: VisibleTarget?) {
        guard let target else { drop(contextId: contextId); return }
        let via: VisibleSourceVia = AXIsProcessTrusted() ? .ax : .spotlight
        let entry = Pending(kind: target.kind, via: via)
        lock.withLock {
            pending.removeValue(forKey: contextId)?.drop()
            order.removeAll { $0 == contextId }
            pending[contextId] = entry; order.append(contextId)
            while order.count > Self.maxContexts { pending.removeValue(forKey: order.removeFirst())?.drop() }
        }
        let source = self.source
        queue.async {
            // A context dropped before its turn (a quick cancel, the next take) is never read.
            guard !entry.dropped else { entry.fulfill(.none); return }
            entry.fulfill(source.capture(target))
        }
    }

    /// The context is gone: its capture is forgotten (its tokens are revoked by LauncherService.revokeTokens).
    public func drop(contextId: String) {
        lock.withLock {
            pending.removeValue(forKey: contextId)?.drop()
            order.removeAll { $0 == contextId }
        }
    }

    /// Contexts with a capture (tests).
    var contexts: [String] { lock.withLock { order } }

    /// The route: the context's capture (waiting ≤ 150 ms for one still running), tokens minted for the items returned.
    /// An unknown context or another app's window has no sources and no items; a capture still running after the wait
    /// answers its kind with `complete: false` and no items.
    public func items(_ request: VisibleItemsRequest) async throws -> VisibleItemsResult {
        let started = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> Double { (Double(DispatchTime.now().uptimeNanoseconds - started) / 100_000).rounded() / 10 }
        let limit = request.maxResults ?? VisibleItemsLimits.defaultMaxResults
        guard (1...VisibleItemsLimits.maxResults).contains(limit) else {
            throw DomainError("invalid_arguments", "maxResults must be 1–\(VisibleItemsLimits.maxResults).")
        }
        guard let entry = lock.withLock({ pending[request.contextId] }) else {
            report(VisibleTraceEvent(kind: "none", via: "-", items: 0, complete: true, waited: false, timedOut: false, routeMs: elapsed()))
            return VisibleItemsResult(sources: [], items: [], truncated: false, elapsedMs: elapsed())
        }
        let ready = entry.finished
        let capture: VisibleCapture?
        if let ready { capture = ready } else {
            capture = try await LauncherDeadline.callback(seconds: wait, onTimeout: .success(nil)) { done, _ in
                entry.notify { done(.success($0)) }
            }
        }
        guard let capture else {
            report(VisibleTraceEvent(kind: entry.kind.rawValue, via: entry.via.rawValue, items: 0, complete: false, waited: true, timedOut: true,
                                     routeMs: elapsed()))
            return VisibleItemsResult(sources: [VisibleSource(kind: entry.kind, via: entry.via, complete: false)], items: [], truncated: false,
                                      elapsedMs: elapsed())
        }
        guard let source = capture.source, !entry.dropped else {
            report(VisibleTraceEvent(kind: "none", via: "-", items: 0, complete: true, waited: ready == nil, timedOut: false, routeMs: elapsed()))
            return VisibleItemsResult(sources: [], items: [], truncated: false, elapsedMs: elapsed())
        }
        let items = capture.entries.prefix(limit).map { entry in
            VisibleItem(FileCandidate(token: tokens.mint(path: entry.path, contentType: entry.contentType, contextId: request.contextId),
                                      name: entry.name, path: entry.path, contentType: entry.contentType,
                                      createdMs: SpotlightResults.milliseconds(entry.created), modifiedMs: SpotlightResults.milliseconds(entry.modified),
                                      lastUsedMs: SpotlightResults.milliseconds(entry.lastUsed), useCount: entry.useCount,
                                      isDirectory: entry.isDirectory, isPackage: entry.isPackage),
                        source: source.kind)
        }
        let truncated = capture.truncated || capture.entries.count > limit
        report(VisibleTraceEvent(kind: source.kind.rawValue, via: source.via.rawValue, items: items.count, complete: source.complete,
                                 waited: ready == nil, timedOut: false, routeMs: elapsed()))
        return VisibleItemsResult(sources: [source], items: Array(items), truncated: truncated, elapsedMs: elapsed())
    }

    private func report(_ event: VisibleTraceEvent) { trace?(event) }
}

/// A fixed capture for any target: `pi-os --conformance` and tests (no AX, Spotlight or TCC).
public struct FixtureVisibleItemsSource: VisibleItemsSource {
    public let fixed: VisibleCapture
    public init(_ fixed: VisibleCapture) { self.fixed = fixed }
    public func capture(_ target: VisibleTarget) -> VisibleCapture { fixed }
}
