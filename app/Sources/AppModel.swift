// App-wide state and the actions the views call. Views stay dumb; this decides.
import AppKit
import Foundation
import Observation

enum AppSection: String, CaseIterable, Identifiable {
    case home = "Home", history = "History", favorites = "Favorites", downloads = "Downloads", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: "house"
        case .history: "clock"
        case .favorites: "star"
        case .downloads: "arrow.down.to.line"
        case .settings: "gearshape"
        }
    }
}

enum DetailTab: String, CaseIterable, Identifiable {
    case summary = "Summary", transcript = "Transcript", downloads = "Downloads"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .summary: "doc.text"
        case .transcript: "text.bubble"
        case .downloads: "arrow.down.circle"
        }
    }
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let store: HistoryStore
    let jobs: JobController
    let ingestor: Ingestor
    let dataDir: URL

    var section = AppSection.history {
        didSet {
            if section == .favorites { store.filter = .favorites }
            else if section == .history, oldValue == .favorites { store.filter = .all }
        }
    }
    var detailTab = DetailTab.summary
    var link = ""
    var focusLinkToken = 0
    var focusSearchToken = 0
    var startupWarning: String?
    var importOffer: [ImportGroup]?
    var importStatus: String?
    var pendingRemoval: Video?
    var notice: String?
    private var launched = false

    private init() {
        dataDir = AppSettings.dataDir
        let db: Database
        var warning: String?
        do {
            db = try Database(directory: dataDir)
        } catch {
            warning = "History couldn't be opened (\(error)). This session works, but nothing will be saved."
            db = try! Database(inMemory: ())
        }
        startupWarning = warning
        store = HistoryStore(db: db)
        jobs = JobController(store: store)
        ingestor = Ingestor(store: store, inbox: dataDir.appendingPathComponent("inbox.jsonl"))
    }

    func launch() async {
        guard !launched else { return }
        launched = true
        let db = store.db
        if let aside = await db.recoveredCorruptFile {
            startupWarning = "The history database was damaged. It was kept as \(aside.lastPathComponent) and a fresh one was started."
        }
        _ = try? await db.recoverInterrupted()
        if AppSettings.retentionDays > 0 { _ = try? await db.prune(olderThanDays: AppSettings.retentionDays) }
        do { try await db.backupIfDue() } catch { notice = "Backup skipped: \(error)" }
        await store.reload()
        store.selectFirstIfNeeded()
        ingestor.start()
        if await db.meta("import_offered") == nil {
            let groups = await scanDownloads()
            if groups.isEmpty { try? await db.setMeta("import_offered", "1") } else { importOffer = groups }
        }
    }

    // MARK: processing

    func start(_ kind: JobKind) {
        guard let link = link.nilIfBlank else { focusLinkToken += 1; return }
        jobs.start(kind, link: link)
    }

    func pasteLink() {
        if let text = NSPasteboard.general.string(forType: .string)?.nilIfBlank { link = text }
    }

    func retry(_ r: RetryInfo) {
        link = r.url
        jobs.start(r.kind, link: r.url)
    }

    func processAgain(_ v: Video) {
        guard let url = v.url else { return }
        link = url
        jobs.start(.summary, link: url)
    }

    func downloadAgain(_ v: Video, kind: JobKind) {
        guard let url = v.url else { return }
        link = url
        jobs.start(kind, link: url)
    }

    func regenerate(format: SummaryFormat = AppSettings.format, language: SummaryLanguage = AppSettings.language) {
        guard let v = store.selectedVideo, let transcript = store.transcriptJob?.transcript else { return }
        detailTab = .summary
        jobs.regenerate(videoID: v.id, transcript: transcript, mediaPath: store.mediaFiles(for: v.id).first?.path,
                        format: format, language: language)
    }

    // MARK: per-video actions

    func open(_ v: Video, tab: DetailTab) {
        store.select(v.id)
        detailTab = tab
    }

    func toggleFavorite(_ v: Video) {
        Task {
            try? await store.db.setFavorite(v.id, !v.favorite)
            await store.reload()
        }
    }

    func copySummary(_ v: Video) {
        Task {
            let jobs = (try? await store.db.jobs(for: v.id)) ?? []
            if let s = jobs.first(where: { $0.kind == .summary && $0.status == .succeeded && $0.summary != nil })?.summary {
                FileOps.copy(s)
                notice = "Summary copied as Markdown"
            } else {
                notice = "This video has no saved summary yet"
            }
        }
    }

    func copyTranscript(_ v: Video) {
        Task {
            let jobs = (try? await store.db.jobs(for: v.id)) ?? []
            if let t = jobs.first(where: { $0.transcript?.nilIfBlank != nil })?.transcript {
                FileOps.copy(t)
                notice = "Transcript copied"
            } else {
                notice = "This video has no saved transcript"
            }
        }
    }

    /// The newest media file of this video that still exists on disk.
    func existingMedia(_ v: Video) -> FileItem? { store.mediaFiles(for: v.id).first(where: \.exists) }

    func confirmRemoval() {
        guard let v = pendingRemoval else { return }
        pendingRemoval = nil
        Task {
            try? await store.db.deleteVideo(v.id)
            if store.selectedID == v.id { store.select(nil) }
            await store.reload()
            store.selectFirstIfNeeded()
            notice = "Removed “\(v.displayTitle)” from history. Its files were kept."
        }
    }

    func clearAll() {
        Task {
            try? await store.db.deleteAll()
            store.select(nil)
            await store.reload()
            notice = "History cleared. Your files in the downloads folder were kept."
        }
    }

    // MARK: import

    private func scanDownloads() async -> [ImportGroup] {
        let known = (try? await store.db.knownPaths()) ?? []
        let dir = URL(fileURLWithPath: AppSettings.downloadDir)
        return await Task.detached { Importer.scan(dir, known: known) }.value
    }

    func runImport(_ offered: [ImportGroup]? = nil) {
        importOffer = nil
        importStatus = "Importing…"
        Task {
            let groups: [ImportGroup]
            if let offered { groups = offered } else { groups = await scanDownloads() }
            do {
                let r = try await Importer.run(groups, db: store.db)
                importStatus = r.jobs == 0 ? "Nothing new to import." : "Imported \(r.videos) videos (\(r.jobs) items). No files were changed."
            } catch {
                importStatus = "Import stopped: \(error)"
            }
            try? await store.db.setMeta("import_offered", "1")
            await store.reload()
            store.selectFirstIfNeeded()
            notice = importStatus
        }
    }

    func declineImport() {
        importOffer = nil
        Task { try? await store.db.setMeta("import_offered", "1") }
    }

    func applyRetention() {
        let days = AppSettings.retentionDays
        guard days > 0 else { return }
        Task {
            let n = (try? await store.db.prune(olderThanDays: days)) ?? 0
            if n > 0 { notice = "Removed \(n) old entries (favorites are always kept)." }
            await store.reload()
        }
    }

    func revealDatabase() {
        NSWorkspace.shared.activateFileViewerSelecting([dataDir.appendingPathComponent("history.sqlite")])
    }
}
