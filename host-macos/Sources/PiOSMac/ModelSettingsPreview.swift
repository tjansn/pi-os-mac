import AppKit
import PiOSCore

/// Standalone UI fixture; no SDK, provider discovery, model calls, TCC prompts or downloads.
/// Every dictionary entry and voice take here is synthetic fixture data (ordinary apps, no user content).
@MainActor public enum ModelSettingsPreview {
    private static var controller: SettingsWindow?
    final class Service: ModelSettingsService {
        var current: HarnessClient.ModelSelection?
        var classifierKind = "off"
        var classifierPython: String?
        var classifierModel: String?
        /// Every POSTed /settings/classifier body, as JSON objects.
        private(set) var classifierPosts: [[String: Any]] = []
        init(current: HarnessClient.ModelSelection? = nil) { self.current = current }
        func reserve() -> UUID { UUID() }
        func release(_ id: UUID) {}
        func models() async throws -> HarnessClient.ModelCatalog {
            HarnessClient.ModelCatalog(models: [
                .init(provider: "Preview", id: "fast", name: "Fast model", thinkingLevels: ["off", "low"]),
                .init(provider: "Preview", id: "reasoning", name: "Reasoning model", thinkingLevels: ["low", "medium", "high", "xhigh"]),
                .init(provider: "Another provider", id: "default", name: "General model", thinkingLevels: ["off"]),
                .init(provider: "pi-os", id: "auto", name: "Auto", thinkingLevels: ["low", "medium", "high"]),
            ], current: current)
        }
        func setModel(_ selection: HarnessClient.ModelSelection) async throws { /* preview only */ }
        /// The stored resource mode ("isolated" or "trustedGlobal"), as Node's resources.json.
        var resourceMode = "isolated"
        /// What a full-mode harness reports as `status` while the mode is trustedGlobal (nil: an older harness without
        /// one). Isolated reports `fullSession: false, guard: none`, as Node does, whenever this is set.
        var fullStatus: ResourceStatus?
        /// Every POST /settings/resources (true: trustedGlobal with the acknowledgement).
        private(set) var resourcePosts: [Bool] = []
        func resources() async throws -> HarnessClient.ResourceSettings {
            let status = fullStatus.map { resourceMode == "trustedGlobal" ? $0 : ResourceStatus(fullSession: false, bashGuard: .unguarded) }
            return .init(current: .init(mode: resourceMode), warning: "Mock preview only", status: status)
        }
        func setResources(trusted: Bool) async throws {
            // Preview only: no extension code is loaded.
            resourcePosts.append(trusted); resourceMode = trusted ? "trustedGlobal" : "isolated"
        }
        /// Mirrors Node: paths come only from what was posted (no PI_OS_LAYA_* here); nothing spawns.
        func classifier() async throws -> ClassifierSettings {
            let reason = classifierPython == nil ? "python_not_configured" : classifierModel == nil ? "model_dir_not_configured" : nil
            let laya = classifierKind == "laya"
            return ClassifierSettings(kind: classifierKind, statusState: laya ? (reason == nil ? "stopped" : "unavailable") : "off",
                                      statusReason: laya ? reason : nil, launchOK: reason == nil, launchReason: reason,
                                      python: classifierPython, modelDir: classifierModel)
        }
        func setClassifier(_ settings: ClassifierSettings) async throws -> ClassifierSettings {
            classifierPosts.append(try JSONSerialization.jsonObject(with: settings.body()) as? [String: Any] ?? [:])
            classifierKind = settings.kind; classifierPython = settings.python; classifierModel = settings.modelDir
            return try await classifier()
        }
    }
    /// Scripted voice services: fixed permission/asset states, nothing prompts or downloads.
    public final class FakeVoiceSystem: VoiceSystem {
        public var engineAvailable: Bool
        public var permissionsValue: VoicePermissions
        public var assets: [VoiceLanguage: VoiceAssetStatus]
        /// Overrides the dictation-only support derived from `assets` (for example the SpeechTranscriber fallback).
        public var support: [VoiceLanguage: VoiceLocaleSupport] = [:]
        public private(set) var requests: [String] = []
        public init(engineAvailable: Bool = true,
                    permissions: VoicePermissions = VoicePermissions(microphone: .granted, speechRecognition: .notDetermined),
                    assets: [VoiceLanguage: VoiceAssetStatus] = [.englishUS: .installed, .germanDE: .notInstalled]) {
            self.engineAvailable = engineAvailable; permissionsValue = permissions; self.assets = assets
        }
        public func permissions() -> VoicePermissions { permissionsValue }
        public func requestMicrophone() async -> VoicePermissionState { requests.append("microphone"); return permissionsValue.microphone }
        public func requestSpeechRecognition() async -> VoicePermissionState { requests.append("speech"); return permissionsValue.speechRecognition }
        public func assetStatus(_ language: VoiceLanguage) async -> VoiceAssetStatus { supportFor(language).installStatus }
        public func installAssets(_ language: VoiceLanguage, progress: ((Double) -> Void)?) async throws {
            requests.append("install:" + language.identifier); progress?(0.5); progress?(1)
        }
        public func readiness(enabled: Bool, language: VoiceLanguage) async -> VoiceReadiness {
            VoiceReadiness.evaluate(enabled: enabled, engineAvailable: engineAvailable, permissions: permissionsValue,
                                    asset: supportFor(language).status, language: language)
        }
        public func localeSupport(_ languages: [VoiceLanguage]) async -> [VoiceLocaleSupport] { languages.map(supportFor) }
        public func releaseAssets(_ language: VoiceLanguage) async { requests.append("release:" + language.identifier) }
        func supportFor(_ language: VoiceLanguage) -> VoiceLocaleSupport {
            if let support = support[language] { return support }
            let status = assets[language] ?? .unsupported
            return VoiceLocaleSupport(language: language, dictation: status, dictationLocale: status == .unsupported ? nil : language.locale,
                                      speech: .unsupported)
        }
    }

    /// The dictionary routes over an in-memory document, with Node's outcomes for the cases Settings shows: shadowing an
    /// installed app asks first, a phrase without a content word is refused (alias guard), an app that is not installed
    /// is refused, entry ops return an Undo token. Invalid input is a 400, as from Node. Never touches a file.
    final class FakeDictionaryService: DictionaryService {
        var document: DictionaryDocument
        /// Installed apps by bundle id (display names), as the host app index lists them.
        var installed: [String: String]
        private(set) var edits: [DictionaryEditRequest] = []
        private(set) var reads = 0
        /// Thrown by every call when set (an older harness, a stopped harness).
        var failure: DomainError?
        /// One scripted response for the next edit.
        var nextResponse: DictionaryWriteResponse?
        private var undo: [String: DictionaryDocument] = [:]
        private var counter = 0
        static let now = "2026-10-07T12:00:00Z"

        init(document: DictionaryDocument = DictionaryDocument(), installed: [String: String] = ModelSettingsPreview.fixtureApps) {
            self.document = document; self.installed = installed
        }
        func learn(_ learn: DictionaryLearnRequest) async throws -> DictionaryWriteResponse {
            if let failure { throw failure }
            return DictionaryWriteResponse(status: .refused, code: "unknown_take", line: "That take is too old to learn from.", revision: document.revision)
        }
        func dictionary() async throws -> DictionaryDocument {
            if let failure { throw failure }
            reads += 1
            return document
        }
        func recognizerTerms(max: Int) async throws -> RecognizerTermsResponse {
            if let failure { throw failure }
            // Like Node: the dictionary's own words and app names first, then installed app names (never empty once the
            // app index is in; the host treats an empty answer as "not ready yet").
            let words = document.terms.map(\.text) + document.appNames.map(\.display)
            let texts = Array((words + ["Safari", "Notes"]).prefix(Swift.max(1, max)))
            return RecognizerTermsResponse(revision: document.revision, terms: texts.map { RecognizerTerm(text: $0, lang: .any) })
        }
        func editDictionary(_ edit: DictionaryEditRequest) async throws -> DictionaryWriteResponse {
            if let failure { throw failure }
            // Through the wire, as Node parses it: a bad body is a 400.
            guard let data = try? JSONEncoder().encode(edit), let parsed = try? JSONDecoder().decode(DictionaryEditRequest.self, from: data) else {
                throw DomainError("invalid_arguments", "Invalid request.")
            }
            edits.append(parsed)
            if let scripted = nextResponse { nextResponse = nil; return scripted }
            switch parsed {
            case .upsert(let input, let source, let confirmed): return upsert(input, source: source ?? .manual, confirmed: confirmed == true)
            case .entry(let op, let list, let id): return entry(op, list: list, id: id)
            case .undo(let token):
                guard let previous = undo.removeValue(forKey: token) else {
                    return DictionaryWriteResponse(status: .refused, code: "undo_expired", line: "That can no longer be undone.", revision: document.revision)
                }
                document = previous; document.revision += 1
                return DictionaryWriteResponse(status: .updated, code: "undone", line: "Undone.", revision: document.revision)
            case .reset:
                document = DictionaryDocument(revision: document.revision + 1, settings: document.settings)
                return DictionaryWriteResponse(status: .updated, code: "reset", line: "Forgot everything pi learned.", revision: document.revision)
            case .settings(let change):
                if let learn = change.learn { document.settings.learn = learn }
                if let value = change.applyToRecognizer { document.settings.applyToRecognizer = value }
                if let value = change.explainToAgent { document.settings.explainToAgent = value }
                document.revision += 1
                return DictionaryWriteResponse(status: .updated, revision: document.revision)
            }
        }

        private func token() -> String { counter += 1; return String(format: "fixture-undo-%06d", counter) }
        private func newMeta(_ id: String?, prefix: String, recognizer: String?, source: DictionarySource, pinned: Bool?) -> DictionaryEntryMeta {
            counter += 1
            return DictionaryEntryMeta(id: id ?? "\(prefix)_fixture\(counter)", recognizer: recognizer ?? RecognizerID.any, source: source,
                                       createdAt: Self.now, pinned: pinned == true ? true : nil)
        }
        private func refused(_ code: String, _ line: String) -> DictionaryWriteResponse {
            DictionaryWriteResponse(status: .refused, code: code, line: line, revision: document.revision)
        }
        /// Node's alias guard, roughly: at least one word of three letters or more.
        private func hasContentWord(_ phrase: String) -> Bool {
            DictionaryPhrase.fold(phrase).split(separator: " ").contains { $0.count >= 3 && !["open", "oben", "bitte", "please", "the"].contains(String($0)) }
        }
        private func upsert(_ input: DictionaryEntryInput, source: DictionarySource, confirmed: Bool) -> DictionaryWriteResponse {
            let before = document
            func existing<T>(_ list: [T], _ meta: (T) -> DictionaryEntryMeta) -> DictionaryEntryMeta? {
                input.id.flatMap { id in list.first { meta($0).id == id }.map(meta) }
            }
            var ref: DictionaryEntryRef
            switch input.content {
            case .term(let text, let forms, let lang, let kind, let bundleId):
                var meta = existing(document.terms, \.meta) ?? newMeta(input.id, prefix: "t", recognizer: input.recognizer, source: source, pinned: input.pinned)
                meta.source = source
                let term = DictionaryTerm(meta: meta, text: text, soundsLike: forms, lang: lang, kind: kind, bundleId: bundleId)
                document.terms.removeAll { $0.meta.id == meta.id }; document.terms.append(term)
                ref = DictionaryEntryRef(list: .terms, id: meta.id)
            case .appName(let heard, let bundleId, let display):
                guard hasContentWord(heard) else { return refused("alias_guard", "Too short to remember safely.") }
                guard installed[bundleId] != nil else { return refused("unsafe_target", "pi cannot learn that action.") }
                let owner = installed.first { DictionaryPhrase.fold($0.value) == heard && $0.key != bundleId }?.key
                if let owner, !confirmed {
                    return DictionaryWriteResponse(status: .needsConfirmation, code: "shadows_app",
                                                   line: "“\(heard)” will open \(display) instead of \(installed[owner] ?? owner). Save anyway?",
                                                   revision: document.revision)
                }
                var meta = existing(document.appNames, \.meta) ?? newMeta(input.id, prefix: "n", recognizer: input.recognizer, source: source, pinned: input.pinned)
                meta.source = source
                document.appNames.removeAll { $0.meta.id == meta.id }
                document.appNames.append(LearnedAppName(meta: meta, heard: heard, bundleId: bundleId, display: display, shadows: owner))
                ref = DictionaryEntryRef(list: .appNames, id: meta.id)
            case .alias(let phrase, let target):
                guard hasContentWord(phrase) else { return refused("alias_guard", "Too short to remember safely.") }
                if case .openApp(let bundleId) = target, installed[bundleId] == nil { return refused("unsafe_target", "pi cannot learn that action.") }
                var meta = existing(document.aliases, \.meta) ?? newMeta(input.id, prefix: "a", recognizer: input.recognizer, source: source, pinned: input.pinned)
                meta.source = source
                document.aliases.removeAll { $0.meta.id == meta.id }
                document.aliases.append(LearnedAlias(meta: meta, phrase: phrase, target: target))
                ref = DictionaryEntryRef(list: .aliases, id: meta.id)
            case .fix(let heard, let intended):
                guard hasContentWord(heard) else { return refused("alias_guard", "Too short to remember safely.") }
                var meta = existing(document.fixes, \.meta) ?? newMeta(input.id, prefix: "f", recognizer: input.recognizer, source: source, pinned: input.pinned)
                meta.source = source
                document.fixes.removeAll { $0.meta.id == meta.id }
                document.fixes.append(LearnedFix(meta: meta, heard: heard, intended: intended))
                ref = DictionaryEntryRef(list: .fixes, id: meta.id)
            }
            document.revision += 1
            let undoToken = token(); undo[undoToken] = before
            return DictionaryWriteResponse(status: .updated, entry: ref, undoToken: undoToken, revision: document.revision)
        }
        private func entry(_ op: DictionaryEditRequest.EntryOp, list: DictionaryList, id: String) -> DictionaryWriteResponse {
            let before = document
            func change(_ meta: inout DictionaryEntryMeta) {
                switch op {
                case .disable: meta.disabledAt = meta.disabledAt ?? Self.now
                case .enable: meta.disabledAt = nil; meta.rejections = 0
                case .pin: meta.pinned = true
                case .unpin: meta.pinned = nil
                case .delete: break
                }
            }
            var found = false
            switch list {
            case .terms:
                if let index = document.terms.firstIndex(where: { $0.meta.id == id }) {
                    found = true; if op == .delete { document.terms.remove(at: index) } else { change(&document.terms[index].meta) }
                }
            case .appNames:
                if let index = document.appNames.firstIndex(where: { $0.meta.id == id }) {
                    found = true; if op == .delete { document.appNames.remove(at: index) } else { change(&document.appNames[index].meta) }
                }
            case .aliases:
                if let index = document.aliases.firstIndex(where: { $0.meta.id == id }) {
                    found = true; if op == .delete { document.aliases.remove(at: index) } else { change(&document.aliases[index].meta) }
                }
            case .fixes:
                if let index = document.fixes.firstIndex(where: { $0.meta.id == id }) {
                    found = true; if op == .delete { document.fixes.remove(at: index) } else { change(&document.fixes[index].meta) }
                }
            }
            guard found else { return refused("unknown_entry", "That entry no longer exists.") }
            document.revision += 1
            let undoToken = token(); undo[undoToken] = before
            return DictionaryWriteResponse(status: .updated, entry: DictionaryEntryRef(list: list, id: id), undoToken: undoToken, revision: document.revision)
        }
    }

    /// An in-memory voice journal with the real one's rules for the opt-in (append/update are no-ops while off) and its
    /// change notification, posted off the main thread. No files, no audio.
    final class FakeVoiceJournal: VoiceJournaling, @unchecked Sendable {
        private let lock = NSLock()
        private var enabled: Bool
        private var records: [VoiceTakeRecord]
        private var log: [String] = []
        /// `setEnabled(true)` throws this (the folder cannot be used); the opt-in then stays off.
        var enableError: DomainError?
        var deleteError: DomainError?
        init(enabled: Bool = true, takes: [VoiceTakeRecord] = []) { self.enabled = enabled; records = takes }
        var calls: [String] { lock.withLock { log } }
        private func note(_ call: String) { lock.withLock { log.append(call) } }
        private func changed() { NotificationCenter.default.post(name: VoiceJournal.changed, object: nil) }
        func isEnabled() async -> Bool { lock.withLock { enabled } }
        func setEnabled(_ enabled: Bool) async throws {
            note("setEnabled:\(enabled)")
            if enabled, let enableError { throw enableError }
            lock.withLock { self.enabled = enabled }
            changed()
        }
        func append(_ record: VoiceTakeRecord, audio: VoiceAudio?) async throws {
            guard lock.withLock({ enabled }) else { return }
            lock.withLock { records.removeAll { $0.takeId == record.takeId }; records.insert(record, at: 0) }
            changed()
        }
        func update(takeId: String, outcome: VoiceTakeOutcome, chosen: String?, corrected: String?) async throws {
            note("update:\(takeId):\(outcome.rawValue):\(chosen ?? "-"):\(corrected ?? "-")")
            let done: Bool = lock.withLock {
                guard enabled, let index = records.firstIndex(where: { $0.takeId == takeId }) else { return false }
                records[index] = VoiceJournalPolicy.updated(records[index], outcome: outcome, chosen: chosen, corrected: corrected)
                return true
            }
            if done { changed() }
        }
        func takes() async -> [VoiceTakeRecord] { lock.withLock { records } }
        func audioURL(takeId: String) async -> URL? {
            lock.withLock { records.first { $0.takeId == takeId && $0.hasAudio } }.map { _ in
                FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-fixture-\(takeId).wav")
            }
        }
        func delete(takeId: String) async throws {
            note("delete:\(takeId)")
            if let deleteError { throw deleteError }
            lock.withLock { records.removeAll { $0.takeId == takeId } }
            changed()
        }
        func deleteAll() async throws {
            note("deleteAll")
            if let deleteError { throw deleteError }
            lock.withLock { records.removeAll() }
            changed()
        }
        func regressionTakes() async -> [RegressionTake] { [] }
    }

    /// A scripted model store: `download()` walks `downloadSteps` (the last one is where it settles). Nothing is
    /// downloaded, compiled or locked.
    final class FakeSpeechModelStore: SpeechModelStoring, @unchecked Sendable {
        let descriptor: SpeechModelDescriptor
        private let lock = NSLock()
        private var current: SpeechModelState
        private var continuations: [UUID: AsyncStream<SpeechModelState>.Continuation] = [:]
        private var log: [String] = []
        var downloadSteps: [SpeechModelState] = [.downloading(progress: 0.4), .compiling, .ready]
        var deleteError: Error?
        init(state: SpeechModelState = .notDownloaded, descriptor: SpeechModelDescriptor = ModelSettingsPreview.fixtureModel) {
            current = state; self.descriptor = descriptor
        }
        var calls: [String] { lock.withLock { log } }
        func state() async -> SpeechModelState { lock.withLock { current } }
        func stateUpdates() -> AsyncStream<SpeechModelState> {
            AsyncStream { continuation in
                let id = UUID()
                let state: SpeechModelState = lock.withLock { continuations[id] = continuation; return current }
                continuation.yield(state)
                continuation.onTermination = { [weak self] _ in self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) } }
            }
        }
        func set(_ state: SpeechModelState) {
            let targets: [AsyncStream<SpeechModelState>.Continuation] = lock.withLock { current = state; return Array(continuations.values) }
            targets.forEach { $0.yield(state) }
        }
        func download() async {
            lock.withLock { log.append("download") }
            for step in downloadSteps { set(step) }
        }
        func cancel() async { lock.withLock { log.append("cancel") }; set(.notDownloaded) }
        func delete() async throws {
            lock.withLock { log.append("delete") }
            if let deleteError { throw deleteError }
            set(.notDownloaded)
        }
        func prepare() async { lock.withLock { log.append("prepare") } }
    }

    /// Ordinary apps only (fixture names for the rows; nothing is opened).
    nonisolated static let fixtureApps: [String: String] = [
        "com.raycast.macos": "Raycast", "com.spotify.client": "Spotify", "com.apple.Siri": "Siri", "com.apple.Keynote": "Keynote",
        "com.apple.Numbers": "Numbers", "com.mitchellh.ghostty": "Ghostty", "com.apple.Pages": "Pages",
        "com.apple.calculator": "Calculator", "com.apple.TextEdit": "TextEdit",
    ]
    /// The shipped Parakeet descriptor (pinned revision and size), so previews and tests show what the app shows.
    nonisolated static let fixtureModel = SpeechModelDescriptor.parakeetV3
    /// A populated dictionary (the shapes of shared/fixtures/dictionary/valid.json).
    nonisolated static func fixtureDictionary() -> DictionaryDocument {
        func meta(_ id: String, _ recognizer: String, _ source: DictionarySource, uses: Int, created: String, disabled: String? = nil,
                  pinned: Bool? = nil, count: Int = 1, rejections: Int = 0) -> DictionaryEntryMeta {
            DictionaryEntryMeta(id: id, recognizer: recognizer, source: source, count: count, rejections: rejections, uses: uses,
                                createdAt: created, disabledAt: disabled, pinned: pinned)
        }
        return DictionaryDocument(
            revision: 42,
            terms: [
                DictionaryTerm(meta: meta("t_ghostty01", "any", .manual, uses: 3, created: "2026-10-01T09:00:00Z", pinned: true),
                               text: "Ghostty", soundsLike: ["gousti"], lang: .any, kind: .app, bundleId: "com.mitchellh.ghostty"),
                DictionaryTerm(meta: meta("t_draco0001", "any", .manual, uses: 0, created: "2026-10-02T10:00:00Z"), text: "DRACO", lang: .en),
            ],
            appNames: [
                LearnedAppName(meta: meta("n_8f3a2c1d", "parakeet-v3", .didYouMean, uses: 5, created: "2026-10-03T08:30:00Z", count: 2),
                               heard: "recast", bundleId: "com.raycast.macos", display: "Raycast"),
                LearnedAppName(meta: meta("n_nummer001", "apple-dt/de-DE", .confirm, uses: 1, created: "2026-10-04T12:00:00Z", rejections: 1),
                               heard: "nummer", bundleId: "com.apple.Numbers", display: "Numbers"),
                LearnedAppName(meta: meta("n_siri00001", "apple-dt/en-US", .listPick, uses: 0, created: "2026-10-05T12:00:00Z"),
                               heard: "siri", bundleId: "com.spotify.client", display: "Spotify", shadows: "com.apple.Siri"),
                LearnedAppName(meta: meta("n_recastold", "parakeet-v3", .didYouMean, uses: 0, created: "2026-10-02T08:30:00Z",
                                          disabled: "2026-10-03T08:30:00Z"),
                               heard: "recast", bundleId: "com.example.Recast", display: "Recast"),
            ],
            aliases: [
                LearnedAlias(meta: meta("a_keynote01", "apple-dt/de-DE", .transcriptEdit, uses: 2, created: "2026-10-05T09:00:00Z"),
                             phrase: "mach kein note auf", target: .openApp(bundleId: "com.apple.Keynote")),
                LearnedAlias(meta: meta("a_leiser001", "any", .manual, uses: 0, created: "2026-10-05T09:01:00Z"),
                             phrase: "etwas leiser", target: .volumeStep(-0.1)),
            ],
            fixes: [
                LearnedFix(meta: meta("f_clod00001", "apple-dt/en-US", .transcriptEdit, uses: 4, created: "2026-10-06T10:00:00Z"),
                           heard: "clod", intended: "Claude"),
            ])
    }
    /// Three synthetic takes: a did-you-mean pick with audio, a fixed agent hand-off, and an empty take.
    nonisolated static func fixtureTakes(now: Date = Date()) -> [VoiceTakeRecord] {
        [
            VoiceTakeRecord(takeId: "take-fixture-1", at: now.addingTimeInterval(-120), durationMs: 1_400,
                            hypotheses: [VoiceHypothesis(text: "Open recast", source: "apple-dt/en-US", role: .peer, confidence: 0.62),
                                         VoiceHypothesis(text: "Öffne Recast", source: "apple-dt/de-DE", role: .peer, confidence: 0.41)],
                            decision: "list", offered: ["com.raycast.macos"], chosen: "com.raycast.macos", outcome: .confirmed, hasAudio: true),
            VoiceTakeRecord(takeId: "take-fixture-2", at: now.addingTimeInterval(-900), durationMs: 2_100,
                            hypotheses: [VoiceHypothesis(text: "Mach mal kein Note auf", source: "apple-dt/de-DE", role: .peer, confidence: 0.55),
                                         VoiceHypothesis(text: "Mark mal kino tour", source: "apple-dt/en-US", role: .peer, confidence: 0.22)],
                            decision: "fallthrough", corrected: "Mach mal Keynote auf", outcome: .agent, hasAudio: true),
            VoiceTakeRecord(takeId: "take-fixture-3", at: now.addingTimeInterval(-3_600), durationMs: 600, hypotheses: [],
                            outcome: .empty, hasAudio: false),
        ]
    }
    nonisolated static func fixtureAppName(_ bundleId: String) -> String? { fixtureApps[bundleId] }
    /// Prompts that never show a panel: questions are answered with `confirm`.
    static func prompts(confirm: Bool = false) -> SettingsPrompts {
        SettingsPrompts(confirm: { _ in confirm }, chooseExport: { nil }, chooseImport: { nil }, chooseApp: { nil })
    }

    /// A settings window over fixture services and an isolated preferences suite. Not shown.
    static func make(page: SettingsWindow.Page = .general, voiceEnabled: Bool = true,
                     current: HarnessClient.ModelSelection? = nil, notifier: ResultNotifier? = nil,
                     dictionary: DictionaryDocument? = ModelSettingsPreview.fixtureDictionary(),
                     takes: [VoiceTakeRecord] = ModelSettingsPreview.fixtureTakes(), model: SpeechModelState? = .notDownloaded,
                     service: Service? = nil) -> SettingsWindow {
        let defaults = UserDefaults(suiteName: "dev.pi-os.settings-preview." + UUID().uuidString)!
        let voiceSettings = VoiceSettings(defaults: defaults, systemLanguages: { ["en-US", "de-DE"] })
        voiceSettings.enabled = voiceEnabled
        let window = SettingsWindow(harness: service ?? Service(current: current), notifier: notifier,
                                    voice: FakeVoiceSystem(), voiceSettings: voiceSettings, contextDefaults: defaults,
                                    dictionary: dictionary.map { FakeDictionaryService(document: $0) },
                                    journal: FakeVoiceJournal(enabled: true, takes: takes),
                                    speechModels: model.map { FakeSpeechModelStore(state: $0) },
                                    prompts: prompts(), appName: fixtureAppName, makeAudio: { _ in SilentTakeAudio() })
        window.recognition?.presentConsent = { _ in false }
        // The full session's acknowledgement is declined: the preview never shows a sheet or loads extension code.
        window.acknowledgeFullSession = { _, _, done in done(false) }
        window.window?.title = "pi-os Settings — Mock Preview"
        window.show(page)
        return window
    }
    static func page(_ name: String) -> SettingsWindow.Page {
        switch name {
        case "voice": .voice
        case "classifier": .classifier
        case "context": .context
        case "dictionary", "recent-takes": .dictionary
        default: .general
        }
    }
    public static func show(page: String = "general") {
        let window = make(page: Self.page(page), notifier: ResultNotifier())
        if page == "recent-takes" { window.dictionaryPage.select(.recentTakes) }
        controller = window
        window.onClosed = { controller = nil; NSApp.terminate(nil) }
        window.present()
    }
    /// Offscreen: lays the window out over fixture data and returns its content view (never shown).
    /// Pages: general, context, voice, classifier, dictionary, recent-takes.
    public static func offscreen(page: String, auto: Bool = true) async -> (view: NSView, keepAlive: AnyObject) {
        let window = make(page: Self.page(page),
                          current: auto ? nil : .init(provider: "Preview", modelId: "reasoning", thinkingLevel: "high"))
        if page == "recent-takes" { window.dictionaryPage.select(.recentTakes) }
        await window.waitUntilLoaded()
        return (window.window!.contentView!, window)
    }
}

/// Playback that makes no sound (previews and tests never play audio).
@MainActor final class SilentTakeAudio: VoiceTakeAudio {
    var onFinish: (@MainActor () -> Void)?
    private(set) var playing = false
    func play() -> Bool { playing = true; return true }
    func stop() { playing = false }
}
