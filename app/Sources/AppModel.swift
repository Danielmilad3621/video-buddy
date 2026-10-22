// App-wide state and the actions the views call. Views stay dumb; this decides.
import AppKit
import Foundation
import Observation

enum AppSection: String, CaseIterable, Identifiable {
    case home = "Home", youtube = "YouTube", library = "Library", favorites = "Favorites", playlists = "Playlists", downloads = "Downloads",
         queue = "Queue", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: "house.fill"
        case .youtube: "play.tv"
        case .library: "rectangle.stack"
        case .favorites: "heart"
        case .playlists: "music.note"
        case .downloads: "arrow.down.to.line"
        case .queue: "slider.horizontal.3"
        case .settings: "gearshape"
        }
    }
}

/// The AI panel's tabs. `video` (player and details) is a tab only when the window is too narrow for its own column.
enum DetailTab: String, CaseIterable, Identifiable {
    case video = "Video", summary = "Summary", transcript = "Transcript", downloads = "Downloads"
    var id: String { rawValue }
    static let panel: [DetailTab] = [.summary, .transcript, .downloads]
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let store: HistoryStore
    let jobs: JobController
    let ingestor: Ingestor
    let network = NetworkMonitor()
    let playback: PlaybackController
    /// 4.0: the YouTube section (its own WebKit data store in the data folder).
    let browser: BrowserController
    let dataDir: URL

    var section = AppSection.home {
        didSet {
            if section == .favorites { store.filter = .favorites }
            else if oldValue == .favorites, store.filter == .favorites { store.filter = .all }
            if section == .youtube, oldValue != .youtube { browser.shown() }
            if oldValue == .youtube, section != .youtube {
                browser.hidden(allowBackgroundAudio: UserDefaults.standard.bool(forKey: "browserBackgroundAudio"))
            }
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
    /// A watch link inside a playlist: ask whether they mean the video or the whole playlist.
    var playlistChoice: (link: PlaylistLink, kind: JobKind)?
    /// The playlist preview sheet.
    var playlistImport: PlaylistImportState?
    var readingPlaylist = false
    var namePrompt: NamePrompt?
    var pendingPlaylistDeletion: PlaylistSummary?
    var pendingOfflineBatch: OfflineBatch?
    /// The Add Videos sheet's playlist.
    var addingVideosTo: PlaylistSummary?
    /// Entries whose details (description, tags) are being read from the platform right now.
    var loadingDetails: Set<Int64> = []
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
        browser = BrowserController(dataDir: dataDir)
        jobs.onNotice = { [weak self] in self?.notice = $0 }
        playback.onAdvance = { [weak self] in self?.store.select($0) }
        // only one thing plays: the native player pauses YouTube, and YouTube playing pauses the native player
        playback.onWillPlay = { [weak self] in self?.browser.pauseAll() }
        browser.onWebPlaying = { [weak self] in if self?.playback.isPlaying == true { self?.playback.pause() } }
        playback.onSaved = { [weak self] in Task { await self?.store.reloadWatch() } }
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
        if let playlist = PlaylistLink.parse(link) {
            if playlist.videoID != nil { playlistChoice = (playlist, kind) } else { readPlaylist(playlist, kind: kind) }
            return
        }
        jobs.enqueue(downloadAction(kind), link: link)
    }

    /// The Video Buddy bar in the YouTube section: the same actions as the toolbar, for the page's video.
    func startFromBrowser(_ kind: JobKind) {
        guard let id = browser.tab?.page.videoID else { return }
        jobs.enqueue(downloadAction(kind), link: BrowserPolicy.watchURL(id))
    }

    /// Audio and Video follow the "+ Transcript" checkbox; Summarize always transcribes anyway.
    private func downloadAction(_ kind: JobKind) -> JobAction { .download(kind, transcript: AppSettings.transcribeDownloads) }

    // MARK: playlists

    func justThisVideo() {
        guard let choice = playlistChoice else { return }
        playlistChoice = nil
        jobs.enqueue(downloadAction(choice.kind), link: link)
    }

    func wholePlaylist() {
        guard let choice = playlistChoice else { return }
        playlistChoice = nil
        readPlaylist(choice.link, kind: choice.kind)
    }

    /// Lists the playlist's videos (a few seconds, nothing downloaded) and opens the preview sheet. `checking`: opened
    /// from Check Against YouTube on that playlist, so nothing is ticked and saving only links library videos.
    func readPlaylist(_ playlist: PlaylistLink, kind: JobKind, checking: Int64? = nil) {
        guard network.isOnline else { notice = "Reading a playlist needs internet."; return }
        readingPlaylist = true
        notice = "Reading the playlist…"
        Task {
            let result = await PlaylistImport.fetch(playlist.url)
            readingPlaylist = false
            switch result {
            case let .success(preview):
                notice = nil
                playlistImport = PlaylistImportState(preview: preview, action: downloadAction(kind), checking: checking)
            case let .failure(error):
                notice = "Couldn't read the playlist: \(error.message)"
            }
        }
    }

    /// Check Against YouTube: reads the playlist's saved link (metadata only) and opens the sheet in linking mode.
    func checkPlaylist(_ p: PlaylistSummary) {
        guard let url = p.sourceURL, let link = PlaylistLink.parse(url) else { return }
        readPlaylist(link, kind: .video, checking: p.id)
    }

    /// The playlist a pasted link already belongs to (same YouTube playlist), if any.
    func playlist(forSource url: String) -> PlaylistSummary? {
        let list = PlaylistLink.parse(url)?.listID
        return store.playlists.first { $0.sourceURL.flatMap(PlaylistLink.parse)?.listID == list && list != nil }
    }

    /// Queues the chosen videos (one at a time, oldest first) and, with a target, saves the playlist: library videos
    /// that are in the YouTube playlist join it by video id even when not chosen. Nothing is downloaded that isn't chosen.
    func importPlaylist(_ entries: [PlaylistEntry], all: [PlaylistEntry], action: JobAction, into target: PlaylistTarget?, sourceURL: String) {
        playlistImport = nil
        guard !entries.isEmpty || target != nil else { return }
        let (format, language) = action == .summarize ? (AppSettings.format.rawValue, AppSettings.language.rawValue) : (nil, nil)
        Task {
            do {
                let r = try await store.db.importPlaylist(entries, all: all, action: action, format: format, language: language,
                                                          into: target, sourceURL: sourceURL)
                await store.reload()
                await jobs.refreshQueue()
                jobs.pump()
                if let id = r.playlist {
                    section = .playlists
                    store.openPlaylistID = id
                }
                let skipped = entries.count - r.jobs
                let linked = r.playlist == nil ? nil : "\(r.linked) \(r.linked == 1 ? "video" : "videos") linked to the playlist"
                notice = entries.isEmpty ? "\(linked ?? "Nothing changed"). Nothing was downloaded."
                    : ([r.jobs > 0 ? "Queued \(r.jobs) \(r.jobs == 1 ? "video" : "videos")" : nil,
                        skipped > 0 ? "\(skipped) already waiting in the queue" : nil, linked] as [String?])
                        .compactMap { $0 }.joined(separator: "; ") + "."
            } catch {
                notice = "Couldn't add the playlist: \(error)"
            }
        }
    }

    /// Opens a playlist's page (and selects one of its videos when given).
    func openPlaylist(_ id: Int64, selecting videoID: Int64? = nil) {
        section = .playlists
        store.openPlaylistID = id
        if let videoID { store.select(videoID) }
    }

    func createPlaylist(_ name: String, adding videoID: Int64? = nil) {
        guard let name = name.nilIfBlank else { return }
        Task {
            guard let id = try? await store.db.createPlaylist(name) else { return }
            if let videoID { try? await store.db.addToPlaylist(id, videoIDs: [videoID]) }
            await store.reloadPlaylists()
            notice = videoID == nil ? "Created “\(name)”." : "Added to the new playlist “\(name)”."
        }
    }

    func renamePlaylist(_ id: Int64, to name: String) {
        guard let name = name.nilIfBlank else { return }
        Task { try? await store.db.renamePlaylist(id, name); await store.reloadPlaylists() }
    }

    func confirmPlaylistDeletion() {
        guard let p = pendingPlaylistDeletion else { return }
        pendingPlaylistDeletion = nil
        Task {
            try? await store.db.deletePlaylist(p.id)
            if store.openPlaylistID == p.id { store.openPlaylistID = nil }
            await store.reloadPlaylists()
            notice = "Deleted the playlist “\(p.name)”. Its videos are still in your history and on disk."
        }
    }

    func addToPlaylist(_ id: Int64, video: Video) {
        Task {
            try? await store.db.addToPlaylist(id, videoIDs: [video.id])
            await store.reloadPlaylists()
            notice = "Added to “\(store.playlists.first { $0.id == id }?.name ?? "playlist")”."
        }
    }

    func addVideos(_ ids: [Int64], to playlistID: Int64) {
        addingVideosTo = nil
        guard !ids.isEmpty else { return }
        Task {
            try? await store.db.addToPlaylist(playlistID, videoIDs: ids)
            await store.reloadPlaylists()
            notice = "Added \(ids.count) \(ids.count == 1 ? "video" : "videos") to the playlist."
        }
    }

    func removeFromOpenPlaylist(_ video: Video) {
        guard let id = store.openPlaylistID else { return }
        Task { try? await store.db.removeFromPlaylist(id, videoID: video.id); await store.reloadPlaylists() }
    }

    func movePlaylistItems(from source: IndexSet, to destination: Int) {
        guard let id = store.openPlaylistID else { return }
        var ids = store.playlistVideos.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        store.playlistVideos.move(fromOffsets: source, toOffset: destination)   // instant feedback
        Task { try? await store.db.reorderPlaylist(id, videoIDs: ids); await store.reloadPlaylists() }
    }

    /// Plays a playlist in order from its first episode on this Mac (Play All), skipping ones that aren't here.
    func playAll(_ playlistID: Int64? = nil) {
        guard let id = playlistID ?? store.openPlaylistID else { return }
        let items = store.playableMembers(id)
        guard let first = items.first, let v = store.video(first.videoID) else {
            notice = "None of these videos are on this Mac yet. Use Download Missing first."
            return
        }
        play(v, in: id)
        let total = store.members[id]?.count ?? 0
        if items.count < total { notice = "Playing \(items.count) of \(total): the others aren't on this Mac yet." }
    }

    /// Continue: the episode you stopped in, or the next one after the last you finished (else Play All).
    func continuePlaylist(_ playlistID: Int64) {
        guard let id = store.resumeTarget(playlistID), let v = store.video(id) else { playAll(playlistID); return }
        play(v, in: playlistID)
    }

    /// Asks first (with the size and free disk space), then queues a video download for every member without a video
    /// file on this Mac. Ones already waiting or downloading are left out (and the database refuses duplicates anyway).
    func askDownloadMissing(_ playlistID: Int64? = nil) {
        guard let id = playlistID ?? store.openPlaylistID else { return }
        let busy = Set(jobs.queue.filter { $0.action.kind == .video }.map(\.videoID) + [jobs.current?.videoID].compactMap { $0 })
        let missing = store.memberVideos(id).filter { $0.url != nil && !store.hasLocalVideo($0.id) && !busy.contains($0.id) }
        guard !missing.isEmpty else {
            notice = busy.isEmpty ? "Every video in this playlist is already on this Mac." : "The missing videos are already in the queue."
            return
        }
        pendingOfflineBatch = OfflineBatch(videoIDs: missing.map(\.id), totalDuration: missing.compactMap(\.duration).reduce(0, +))
    }

    func confirmOfflineBatch() {
        guard let batch = pendingOfflineBatch else { return }
        pendingOfflineBatch = nil
        Task {
            var queued = 0
            for id in batch.videoIDs where (try? await store.db.enqueue(videoID: id, action: .video)) != nil { queued += 1 }
            await store.reload()
            await jobs.refreshQueue()
            jobs.pump()
            let skipped = batch.videoIDs.count - queued
            notice = "Queued \(queued) video \(queued == 1 ? "download" : "downloads")"
                + (skipped > 0 ? " (\(skipped) already in the queue)" : "")
                + (network.isOnline || queued == 0 ? "." : ": they start when you're back online.")
        }
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

    /// Plays a video; in a playlist (the one given, else the first it's in) Next, Previous and Up Next follow that
    /// playlist. A video in no playlist plays on its own, as before.
    func play(_ v: Video, in playlistID: Int64? = nil) {
        guard let file = store.playable(for: v.id) else { return }
        store.select(v.id)
        let items = (playlistID ?? store.playlistsOf(v.id).first?.id).map { store.playableMembers($0) } ?? []
        guard let pid = playlistID ?? store.playlistsOf(v.id).first?.id, let i = items.firstIndex(where: { $0.videoID == v.id }),
              let p = store.playlists.first(where: { $0.id == pid }) else {
            playback.play(path: file.path, videoID: v.id)
            return
        }
        playback.play(path: items[i].path, videoID: v.id, upNext: Array(items[(i + 1)...]), played: Array(items[..<i]),
                      context: PlaylistContext(id: pid, name: p.name, count: store.members[pid]?.count ?? 0))
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

    func copyLink(_ v: Video) {
        guard let url = v.url else { return }
        FileOps.copy(url)
        notice = "Link copied"
    }

    /// Reads the description and tags with yt-dlp (metadata only: nothing is downloaded, no AI).
    func loadDetails(_ v: Video) {
        guard let url = v.url, !loadingDetails.contains(v.id) else { return }
        guard network.isOnline else { notice = "Loading details needs internet."; return }
        loadingDetails.insert(v.id)
        Task {
            let info = await MetadataFetcher.fetch(url)
            loadingDetails.remove(v.id)
            guard let info else { notice = "Couldn't read this video's details."; return }
            try? await store.db.applyInfo(v.id, info, override: true)
            await store.reload()
            if info.description?.nilIfBlank == nil { notice = "This video has no description." }
        }
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

    var freeDiskSpace: Int64? { DiskSpace.free(at: AppSettings.downloadDir) }

    func revealDatabase() {
        NSWorkspace.shared.activateFileViewerSelecting([dataDir.appendingPathComponent("history.sqlite")])
    }
}

struct PlaylistImportState: Identifiable {
    let id = UUID()
    let preview: PlaylistPreview
    let action: JobAction
    var checking: Int64? = nil
}

enum NamePrompt: Identifiable {
    case new(adding: Int64?)
    case rename(PlaylistSummary)
    var id: String {
        switch self {
        case let .new(v): "new-\(v ?? 0)"
        case let .rename(p): "rename-\(p.id)"
        }
    }
}

struct OfflineBatch: Identifiable {
    let id = UUID()
    let videoIDs: [Int64]
    let totalDuration: Double
}

enum DiskSpace {
    /// Space macOS can free up for important files on the volume holding `path` (what Finder shows as available).
    static func free(at path: String) -> Int64? {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 { url.deleteLastPathComponent() }
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
}
