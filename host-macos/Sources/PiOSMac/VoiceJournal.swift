import AVFoundation
import Foundation
import PiOSCore

/// The opt-in local voice journal (DESIGN4 §6.7, Tom's answer #2): the last 50 voice takes in
/// `<support>/voice-takes/`, each as `<takeId>.wav` (the first 15 s, 16 kHz mono) and `<takeId>.take` (the JSON
/// record: what each engine heard, the decision, what was offered and chosen, any correction, the outcome). The
/// directory is 0700, files are 0600 and written atomically, and the directory and files are excluded from backups.
/// The rules live in `VoiceJournalPolicy`.
///
/// Privacy: audio and records never leave this directory. The only exception is `regressionTakes()`, a text-only list
/// that the command flow sends with `/dictionary/learn` while the journal is on. This type has no logging, printing or
/// network code (VoiceJournalTests scans this file for it), errors carry fixed messages, and records describe
/// themselves without content.
///
/// Off by default (`VoiceJournalLimits.enabledByDefault`); the opt-in is `VoiceJournalPolicy.enabledKey` in the given
/// defaults. While off, `append`, `update` and `regressionTakes` do nothing and kept takes can still be listed,
/// played and deleted. Use one instance per support directory: the app owns it and hands it to the command flow and
/// Settings. Every change posts `VoiceJournal.changed` (no object, no user info) on the journal's executor, so
/// observers hop to the main actor themselves.
public actor VoiceJournal: VoiceJournaling {
    public static let changed = Notification.Name("PiOSVoiceJournalChanged")

    public nonisolated let directory: URL
    private let defaults: UserDefaults

    public init(directory: URL, defaults: UserDefaults = .standard) {
        self.directory = directory.standardizedFileURL
        self.defaults = defaults
    }

    /// `<support>/voice-takes/`.
    public init(support: URL, defaults: UserDefaults = .standard) {
        self.init(directory: support.appendingPathComponent(VoiceJournalLimits.directoryName, isDirectory: true), defaults: defaults)
    }

    static let invalidTake = DomainError("voice_journal_invalid_take", "This voice take cannot be kept.")
    static let unavailable = DomainError("voice_journal_unavailable", "The voice journal folder cannot be used.")
    static let writeFailed = DomainError("voice_journal_write_failed", "The voice take could not be saved.")
    static let deleteFailed = DomainError("voice_journal_delete_failed", "Some voice takes could not be deleted.")

    // MARK: VoiceJournaling

    public func isEnabled() -> Bool {
        VoiceJournalPolicy.isEnabled(stored: defaults.object(forKey: VoiceJournalPolicy.enabledKey))
    }

    /// DESIGN5 §5.8 (change C6, D6): a take spoken while a credential or code field was focused may be the secret itself,
    /// so it is never kept: no audio, no text, no later update. The command flow asks this before `append`.
    public nonisolated static func keeps(field kind: InstantFieldKind?) -> Bool { kind != .credential && kind != .sensitive }

    /// Switching on prepares the directory (0700, excluded from backups) first: when it cannot be used this throws and
    /// the opt-in stays as it was, so a failed switch-on never leaves the journal recording. Switching off keeps
    /// existing takes.
    public func setEnabled(_ enabled: Bool) throws {
        if enabled { try prepareDirectory() }
        defaults.set(enabled, forKey: VoiceJournalPolicy.enabledKey)
        notify()
    }

    /// Stores the take as the newest of the ring and drops the oldest beyond 50. Audio is cut at 15 s; nil or empty
    /// audio stores the record alone. Appending a take id again replaces that take. No-op while off.
    public func append(_ record: VoiceTakeRecord, audio: VoiceAudio?) throws {
        guard isEnabled() else { return }
        guard var record = VoiceJournalPolicy.sanitized(record) else { throw Self.invalidTake }
        try prepareDirectory()
        let seq = min((repaired()?.entries.values.map(\.seq).max() ?? 0) + 1, VoiceJournalEntry.maximumSeq)
        let audioName = VoiceJournalPolicy.audioFileName(record.takeId)
        if let audio = audio.map(VoiceJournalPolicy.clipped), !audio.samples.isEmpty {
            try writeAtomically(VoiceJournalPolicy.wav(audio), name: audioName)
            record.hasAudio = true
        } else {
            remove(audioName)
            record.hasAudio = false
        }
        do {
            try writeAtomically(try VoiceJournalEntry(seq: seq, record: record).encoded(), name: VoiceJournalPolicy.recordFileName(record.takeId))
        } catch {
            if record.hasAudio { remove(audioName) }
            throw Self.writeFailed
        }
        _ = repaired()
        notify()
    }

    /// The outcome always changes; a nil `chosen` or `corrected` keeps the stored value. An unknown or evicted take,
    /// or a journal that is off, is a no-op.
    public func update(takeId: String, outcome: VoiceTakeOutcome, chosen: String?, corrected: String?) throws {
        guard isEnabled(), let entry = entry(takeId) else { return }
        let record = VoiceJournalPolicy.updated(entry.record, outcome: outcome, chosen: chosen, corrected: corrected)
        guard record != entry.record else { return }
        try prepareDirectory()
        do {
            try writeAtomically(try VoiceJournalEntry(seq: entry.seq, record: record).encoded(), name: VoiceJournalPolicy.recordFileName(takeId))
        } catch {
            throw Self.writeFailed
        }
        notify()
    }

    /// Newest first (append order). `hasAudio` is true only while the take's WAV is present.
    public func takes() -> [VoiceTakeRecord] {
        guard let snapshot = repaired() else { return [] }
        return snapshot.plan.keep.compactMap { takeId in
            guard var record = snapshot.entries[takeId]?.record else { return nil }
            record.hasAudio = record.hasAudio && snapshot.audio.contains(takeId)
            return record
        }
    }

    /// The take's WAV for Settings playback: a regular file beside a readable record, else nil.
    public func audioURL(takeId: String) -> URL? {
        guard entry(takeId) != nil else { return nil }
        let url = directory.appendingPathComponent(VoiceJournalPolicy.audioFileName(takeId), isDirectory: false)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return url
    }

    /// Removes the take's record and audio (also while off). An unknown take id is a no-op; a file that stays throws,
    /// so Settings never reports a deletion that did not happen.
    public func delete(takeId: String) throws {
        guard VoiceJournalPolicy.isTakeID(takeId), directoryState() == .usable else { return }
        try? prepareDirectory()
        let removedRecord = remove(VoiceJournalPolicy.recordFileName(takeId))
        let removedAudio = remove(VoiceJournalPolicy.audioFileName(takeId))
        notify()
        guard removedRecord, removedAudio else { throw Self.deleteFailed }
    }

    /// "Delete all takes" (also while off): removes every journal file, including unreadable records, orphan audio
    /// and interrupted writes, then the directory once nothing else is in it. Files that are not the journal's stay.
    /// Throws when a journal file could not be removed.
    public func deleteAll() throws {
        guard directoryState() == .usable else { return }
        try? prepareDirectory()
        var complete = true
        for item in listing() ?? [] where VoiceJournalPolicy.role(ofFileName: item.name) != .foreign {
            if !remove(item.name) { complete = false }
        }
        _ = rmdir(directory.path)
        notify()
        guard complete else { throw Self.deleteFailed }
    }

    public func regressionTakes() -> [RegressionTake] { regressionTakes(limit: DictionaryLimits.regressionTakes) }

    /// The last `limit` accepted takes as `/dictionary/learn` `regression` (text, recognizer, kept app), newest first,
    /// within the 50-take and 10 KB caps. Empty while off: nothing from the journal crosses the loopback then.
    public func regressionTakes(limit: Int) -> [RegressionTake] {
        guard isEnabled() else { return [] }
        return VoiceJournalPolicy.regressionTakes(takes(), limit: limit)
    }

    // MARK: Directory

    private enum DirectoryState { case missing, usable, unusable }

    /// Usable only as a real directory (never a symlink) owned by this user.
    private func directoryState() -> DirectoryState {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { return errno == ENOENT ? .missing : .unusable }
        return info.st_mode & S_IFMT == S_IFDIR && info.st_uid == geteuid() ? .usable : .unusable
    }

    /// Creates the directory if needed, then asserts 0700 and the backup exclusion.
    private func prepareDirectory() throws {
        let mode = mode_t(VoiceJournalLimits.directoryPermissions)
        switch directoryState() {
        case .unusable:
            throw Self.unavailable
        case .missing:
            do {
                try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: VoiceJournalLimits.directoryPermissions])
            } catch {
                throw Self.unavailable
            }
            guard mkdir(directory.path, mode) == 0 || errno == EEXIST, directoryState() == .usable else { throw Self.unavailable }
        case .usable:
            break
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.unavailable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid() else { throw Self.unavailable }
        if info.st_mode & 0o7777 != mode { guard fchmod(fd, mode) == 0 else { throw Self.unavailable } }
        // A fresh URL each time: URL instances cache resource values.
        var url = URL(fileURLWithPath: directory.path, isDirectory: true)
        if (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup != true {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            do { try url.setResourceValues(values) } catch { throw Self.unavailable }
        }
    }

    // MARK: Scan and repair

    private struct Snapshot {
        /// Readable records by take id.
        var entries: [String: VoiceJournalEntry]
        /// Take ids with a WAV.
        var audio: Set<String>
        var plan: VoiceJournalPolicy.Plan
    }

    /// The directory as the policy sees it, after removing what the plan drops; nil when there is no usable directory.
    private func repaired() -> Snapshot? {
        guard directoryState() == .usable, let listing = listing() else { return nil }
        var entries: [String: VoiceJournalEntry] = [:], audio = Set<String>()
        for item in listing {
            switch VoiceJournalPolicy.role(ofFileName: item.name) {
            case .record(let takeId):
                if let data = readRecord(item.name), let entry = VoiceJournalEntry.decode(data, takeId: takeId) { entries[takeId] = entry }
            case .audio(let takeId):
                audio.insert(takeId)
            case .temporary, .foreign:
                break
            }
        }
        let plan = VoiceJournalPolicy.plan(listing, readable: entries.mapValues(\.seq))
        for name in plan.remove {
            remove(name)
            switch VoiceJournalPolicy.role(ofFileName: name) {
            case .record(let takeId): entries[takeId] = nil
            case .audio(let takeId): audio.remove(takeId)
            case .temporary, .foreign: break
            }
        }
        return Snapshot(entries: entries, audio: audio, plan: plan)
    }

    private func entry(_ takeId: String) -> VoiceJournalEntry? {
        guard VoiceJournalPolicy.isTakeID(takeId), directoryState() == .usable,
              let data = readRecord(VoiceJournalPolicy.recordFileName(takeId)) else { return nil }
        return VoiceJournalEntry.decode(data, takeId: takeId)
    }

    private func listing() -> [VoiceJournalPolicy.DirectoryEntry]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        let now = Date().timeIntervalSince1970
        return names.map { name in
            var info = stat()
            guard lstat(path(name), &info) == 0 else { return .init(name: name, age: 0) }
            let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
            return .init(name: name, age: now - modified)
        }
    }

    // MARK: Files

    private func path(_ name: String) -> String { directory.appendingPathComponent(name, isDirectory: false).path }

    /// A regular file of at most `maximumRecordBytes`, opened without following links or blocking on a FIFO.
    private func readRecord(_ name: String) -> Data? {
        let fd = open(path(name), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= VoiceJournalPolicy.maximumRecordBytes else { return nil }
        var data = Data(count: Int(info.st_size))
        let complete = data.withUnsafeMutableBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = read(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        return complete ? data : nil
    }

    /// Writes `.<uuid>.tmp` (created 0600, never through a link), then renames it over `name`.
    private func writeAtomically(_ data: Data, name: String) throws {
        let mode = mode_t(VoiceJournalLimits.filePermissions)
        let temporary = path(VoiceJournalPolicy.temporaryFileName(UUID().uuidString))
        let target = path(name)
        let fd = open(temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw Self.writeFailed }
        var renamed = false
        defer { if !renamed { unlink(temporary) } }
        let written = fchmod(fd, mode) == 0 && data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard close(fd) == 0, written, rename(temporary, target) == 0 else { throw Self.writeFailed }
        renamed = true
        var url = URL(fileURLWithPath: target, isDirectory: false)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Unlinks a name (a link itself, never its target). True when it is gone (or was never there).
    @discardableResult private func remove(_ name: String) -> Bool { unlink(path(name)) == 0 || errno == ENOENT }

    private func notify() { NotificationCenter.default.post(name: Self.changed, object: nil) }
}

// MARK: - Playback (Settings → Dictionary → Recent takes)

/// One playable take. The app uses AVAudioPlayer; tests inject a fake and never produce sound.
@MainActor public protocol VoiceTakeAudio: AnyObject {
    /// Called once when playback ends by itself (not after `stop()`).
    var onFinish: (@MainActor () -> Void)? { get set }
    func play() -> Bool
    func stop()
}

/// Plays one journal take at a time, locally. `onChange` reports the playing take id, or nil once playback stops.
/// A take whose audio leaves the journal (deleted, all deleted, evicted) stops playing.
@MainActor public final class VoiceTakePlayer {
    public typealias AudioFactory = @MainActor (URL) throws -> VoiceTakeAudio

    public private(set) var playingTakeId: String?
    public var onChange: ((String?) -> Void)?
    private let journal: VoiceJournaling
    private let makeAudio: AudioFactory
    private var audio: VoiceTakeAudio?
    private var generation = 0
    private var observer: JournalObserver?

    public init(journal: VoiceJournaling, makeAudio: @escaping AudioFactory = VoiceTakePlayer.systemAudio) {
        self.journal = journal; self.makeAudio = makeAudio
        observer = JournalObserver(VoiceJournal.changed) { [weak self] in
            Task { @MainActor [weak self] in await self?.journalChanged() }
        }
    }

    private func journalChanged() async {
        guard let playing = playingTakeId else { return }
        let url = await journal.audioURL(takeId: playing)
        if url == nil, playingTakeId == playing { stop() }
    }

    /// Removes its observer when the player goes away.
    private final class JournalObserver {
        private let token: NSObjectProtocol
        init(_ name: Notification.Name, _ handler: @escaping @Sendable () -> Void) {
            token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in handler() }
        }
        deinit { NotificationCenter.default.removeObserver(token) }
    }

    /// Stops what is playing, then plays the take's audio. False when the take has no audio or it cannot be played,
    /// or when another `play` or `stop` came first.
    @discardableResult public func play(takeId: String) async -> Bool {
        stop()
        generation += 1
        let ticket = generation
        guard let url = await journal.audioURL(takeId: takeId), ticket == generation, let audio = try? makeAudio(url) else { return false }
        audio.onFinish = { [weak self, weak audio] in
            guard let self, let audio, self.audio === audio else { return }
            self.audio = nil
            self.playingTakeId = nil
            self.onChange?(nil)
        }
        guard audio.play() else { return false }
        self.audio = audio
        playingTakeId = takeId
        onChange?(takeId)
        return true
    }

    public func stop() {
        generation += 1
        guard let audio else { return }
        self.audio = nil
        audio.onFinish = nil
        audio.stop()
        playingTakeId = nil
        onChange?(nil)
    }

    public static func systemAudio(_ url: URL) throws -> VoiceTakeAudio { try SystemVoiceTakeAudio(url: url) }
}

/// AVAudioPlayer behind `VoiceTakeAudio`.
@MainActor final class SystemVoiceTakeAudio: NSObject, VoiceTakeAudio, AVAudioPlayerDelegate {
    var onFinish: (@MainActor () -> Void)?
    private let player: AVAudioPlayer

    init(url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url, fileTypeHint: AVFileType.wav.rawValue)
        super.init()
        player.delegate = self
    }

    func play() -> Bool { player.play() }
    func stop() { player.stop() }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.onFinish?() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.onFinish?() }
    }
}
