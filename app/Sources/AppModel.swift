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
    let network = NetworkMonitor()
    let playback: PlaybackController
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
        jobs = JobController(store: store, network: network)
        ingestor = Ingestor(store: store, inbox: dataDir.appendingPathComponent("inbox.jsonl"))
        playback = PlaybackController(db: db)
        jobs.onNotice = { [weak self] in self?.notice = $0 }
        playback.onAdvance = { [weak self] in self?.store.select($0) }
    }

    func launch() async {
        guard !launched else { return }
        launched = true
        let db = store.db
        if let aside = await db.recoveredCorruptFile {
            startupWarning = "The history database was damaged. It was kept as \(aside.lastPathComponent) and a fresh one was started."
        }
        _ = try? await db.recoverInterrupted()     // queued jobs stay queued and continue below
        network.start { [weak self] online in
            guard let self else { return }
            if online { self.jobs.pump(); Task { await self.backfillThumbnails() } }
        }
        if AppSettings.retentionDays > 0 { _ = try? await db.prune(olderThanDays: AppSettings.retentionDays) }
        do { try await db.backupIfDue() } catch { notice = "Backup skipped: \(error)" }
        await store.reload()
        store.selectFirstIfNeeded()
        ingestor.start()
        await jobs.refreshQueue()
        jobs.pump()
        Task {
            await backfillMetadata()
            await backfillThumbnails()
        }
        if await db.meta("import_offered") == nil {
            let groups = await scanDownloads()
            if groups.isEmpty { try? await db.setMeta("import_offered", "1") } else { importOffer = groups }
        }
    }

    /// Entries whose job never got far enough to save metadata (cancelled, crashed) get it on the next launch.
    private func backfillMetadata() async {
        let missing = ((try? await store.db.videos()) ?? []).filter { $0.title == nil && $0.url != nil }.prefix(10)
        for v in missing {
            guard let url = v.url, let info = await MetadataFetcher.fetch(url) else { continue }
            try? await store.db.applyInfo(v.id, info, override: true)
        }
        if !missing.isEmpty { await store.reload() }
    }

    /// Saves thumbnails on this Mac for entries that don't have one yet: from the web when online, otherwise
    /// from a frame of a local video.
    func backfillThumbnails() async {
        let videos = (try? await store.db.videos()) ?? []
        var changed = false
        for v in videos where v.thumbnailPath.map({ !FileManager.default.fileExists(atPath: $0) }) ?? true {
            let localVideo = store.mediaFiles(for: v.id).first { $0.role == .video && $0.exists }?.path
            guard network.isOnline || localVideo != nil else { continue }
            if await Thumbnails.ensure(v, localVideo: localVideo, db: store.db, online: network.isOnline) != nil { changed = true }
        }
        if changed { await store.reload() }
    }

    // MARK: processing

    func start(_ kind: JobKind) {
        guard let link = link.nilIfBlank else { focusLinkToken += 1; return }
        jobs.enqueue(JobAction.from(kind: kind), link: link)
    }

    func pasteLink() {
        if let text = NSPasteboard.general.string(forType: .string)?.nilIfBlank { link = text }
    }

    func retry(_ r: RetryInfo) { jobs.retry(r) }

    func processAgain(_ v: Video) {
        guard v.url != nil else { return }
        jobs.enqueue(.summarize, videoID: v.id, format: AppSettings.format, language: AppSettings.language)
    }

    func downloadAgain(_ v: Video, kind: JobKind) {
        guard v.url != nil else { return }
        jobs.enqueue(JobAction.from(kind: kind), videoID: v.id)
    }

    /// Downloads the video file, so the entry can be watched without internet.
    func makeAvailableOffline(_ v: Video) {
        guard v.url != nil else { return }
        jobs.enqueue(.video, videoID: v.id)
        notice = network.isOnline ? "Downloading “\(v.displayTitle)” for offline viewing." : "Queued: it downloads when you're back online."
    }

    /// On-device transcript of a file already on this Mac (audio first: it needs no conversion).
    func transcribe(_ v: Video) {
        let local = store.mediaFiles(for: v.id).filter(\.exists)
        guard let file = local.first(where: { $0.role == .audio }) ?? local.first else {
            notice = "There's no audio or video file of this entry on this Mac."
            return
        }
        jobs.enqueue(.transcribe, videoID: v.id, filePath: file.path)
    }

    /// A new summary from the saved transcript (queued until online when needed).
    func regenerate(format: SummaryFormat = AppSettings.format, language: SummaryLanguage = AppSettings.language) {
        guard let v = store.selectedVideo, store.transcriptJob != nil else { return }
        detailTab = .summary
        jobs.enqueue(.resummarize, videoID: v.id, format: format, language: language)
    }

    // MARK: playback

    func play(_ v: Video) {
        guard let file = store.playable(for: v.id) else { return }
        store.select(v.id)
        playback.play(path: file.path, videoID: v.id)
    }

    /// Jumps the built-in player to a transcript line, starting playback if needed.
    func seek(_ v: Video, to seconds: Double) {
        guard let file = store.playable(for: v.id) else { return }
        if !playback.isCurrent(file.path) { playback.play(path: file.path, videoID: v.id) }
        playback.seek(to: seconds)
        if !playback.isPlaying { playback.togglePlayPause() }
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
            if playback.currentVideoID == v.id { playback.stop() }
            try? await store.db.deleteVideo(v.id)
            Thumbnails.remove(videoIDs: [v.id])
            if store.selectedID == v.id { store.select(nil) }
            await store.reload()
            store.selectFirstIfNeeded()
            notice = "Removed “\(v.displayTitle)” from history. Its files were kept."
        }
    }

    func clearAll() {
        Task {
            playback.stop()
            try? await store.db.deleteAll()
            Thumbnails.removeAll()
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
