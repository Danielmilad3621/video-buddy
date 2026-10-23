// What the views show, loaded from the database. All loading is async; the main thread never waits on SQLite.
import Foundation
import Observation

@MainActor @Observable
final class HistoryStore {
    let db: Database
    var videos: [Video] = []
    /// Every entry, unfiltered (newest first), for screens that group by playlist whatever the filter is.
    var all: [Video] = []
    /// The same entries by key (youtube:<id>), for the browser bar and Watch Later.
    private(set) var byKey: [String: Video] = [:]
    var recent: [Video] { Array(all.prefix(8)) }
    var files: [FileItem] = []
    var stats = Stats()
    var filter = HistoryFilter.all
    var sort = HistorySort.recent
    var search = ""
    private(set) var selectedID: Int64?
    var selectedVideo: Video?
    var selectedJobs: [Job] = []
    /// Entries with an audio or video file that's on this Mac right now (watchable offline).
    private(set) var onMacIDs: Set<Int64> = []
    /// Entries with a video file on this Mac: what "offline" counts mean. Audio only doesn't count.
    private(set) var videoOnMacIDs: Set<Int64> = []
    /// Each playlist's video ids in order (a video can be in several).
    private(set) var members: [Int64: [Int64]] = [:]
    /// How far you got in each video.
    private(set) var watch: [Int64: Watch] = [:]
    /// Playlists opened in grouped lists (Library, Downloads), for this session.
    var expanded: Set<Int64> = []
    /// My Playlists, and the videos of the open one in their saved order.
    var playlists: [PlaylistSummary] = []
    var openPlaylistID: Int64? { didSet { if openPlaylistID != oldValue { Task { await reloadPlaylists() } } } }
    var playlistVideos: [Video] = []
    /// Home's "Continue watching": entries you stopped part-way through, with how far you got (0…1).
    var continueWatching: [(video: Video, progress: Double)] = []
    /// The Queue's "Failed" list: jobs that failed or were interrupted and haven't been retried or redone.
    var failed: [FailedItem] = []
    /// 4.0 Phase 3: Watch Later, newest first, and its keys (to tell at once that a video is saved).
    private(set) var watchLater: [WatchLaterItem] = []
    private(set) var savedKeys: Set<String> = []
    var lastError: String?

    init(db: Database) { self.db = db }

    func reload() async {
        let (filter, sort, search) = (filter, sort, search)
        do {
            async let list = db.videos(filter: filter, sort: sort, search: search)
            async let everything = db.videos()
            async let allFiles = db.files()
            async let counts = db.stats()
            let files = try await allFiles
            let onDisk = files.filter { $0.isMedia && $0.exists }
            let onMac = Set(onDisk.map(\.videoID))
            let loaded = try await list
            videos = filter == .offline ? loaded.filter { onMac.contains($0.id) } : loaded
            all = try await everything
            byKey = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            self.files = files
            onMacIDs = onMac
            videoOnMacIDs = Set(onDisk.filter { $0.role == .video }.map(\.videoID))
            stats = try await counts
            failed = try await db.failedJobs().map { FailedItem(job: $0.job, title: $0.title ?? "Untitled video") }
            lastError = nil
        } catch {
            lastError = "Couldn't load history: \(error)"
        }
        await reloadPlaylists()
        await reloadWatch()
        await reloadWatchLater()
        await refreshSelection()
    }

    func reloadWatchLater() async {
        do {
            watchLater = try await db.watchLater()
            savedKeys = Set(watchLater.map(\.key))
        } catch {
            lastError = "Couldn't load Watch Later: \(error)"
        }
    }

    /// What depends on resume positions (watched marks, Continue, Continue watching); the player calls this after saving one.
    func reloadWatch() async {
        watch = (try? await db.watchStates()) ?? watch
        var resume: [(video: Video, progress: Double)] = []
        for r in (try? await db.continueWatching()) ?? [] {
            guard let v = video(r.videoID), playable(for: v.id) != nil else { continue }
            let total = r.duration ?? v.duration ?? 0
            resume.append((v, total > 0 ? min(r.position / total, 1) : 0))
        }
        continueWatching = resume
    }

    func reloadPlaylists() async {
        playlists = (try? await db.playlists()) ?? []
        members = Dictionary(grouping: (try? await db.memberships()) ?? [], by: \.playlist).mapValues { $0.map(\.video) }
        if let id = openPlaylistID, playlists.contains(where: { $0.id == id }) {
            playlistVideos = (try? await db.videos(playlist: id)) ?? []
        } else {
            openPlaylistID = nil
            playlistVideos = []
        }
    }

    func select(_ id: Int64?) {
        selectedID = id
        Task {
            await refreshSelection()
            if let id { try? await db.touchOpened(id) }
        }
    }

    /// Picks the most recent entry when nothing is selected yet.
    func selectFirstIfNeeded() {
        if selectedID == nil, let first = videos.first ?? recent.first { select(first.id) }
    }

    /// ↑/↓ through what the list shows (grouped lists pass their visible order).
    func move(_ step: Int, in ids: [Int64]? = nil) {
        let ids = ids ?? videos.map(\.id)
        guard !ids.isEmpty else { return }
        let i = ids.firstIndex { $0 == selectedID } ?? (step > 0 ? -1 : ids.count)
        select(ids[min(max(i + step, 0), ids.count - 1)])
    }

    private func refreshSelection() async {
        guard let id = selectedID else { selectedVideo = nil; selectedJobs = []; return }
        let video = try? await db.video(id)
        let jobs = (try? await db.jobs(for: id)) ?? []
        guard selectedID == id else { return } // selection changed meanwhile
        if video == nil { selectedID = nil }
        selectedVideo = video
        selectedJobs = jobs
    }

    // MARK: derived data for the selected video

    func files(for videoID: Int64) -> [FileItem] { files.filter { $0.videoID == videoID } }
    func mediaFiles(for videoID: Int64) -> [FileItem] { files(for: videoID).filter(\.isMedia) }
    /// The best file to play in the built-in player: a local video first, then local audio.
    func playable(for videoID: Int64) -> FileItem? {
        let local = mediaFiles(for: videoID).filter { $0.exists && $0.isPlayable }
        return local.first { $0.role == .video } ?? local.first
    }
    func hasLocalVideo(_ videoID: Int64) -> Bool { mediaFiles(for: videoID).contains { $0.role == .video && $0.exists } }

    func video(_ id: Int64) -> Video? { all.first { $0.id == id } }

    // MARK: playlists

    func playlistsOf(_ videoID: Int64) -> [PlaylistSummary] { playlists.filter { members[$0.id]?.contains(videoID) == true } }
    func memberVideos(_ playlistID: Int64) -> [Video] { (members[playlistID] ?? []).compactMap(video) }
    /// Unique videos of the playlist with a video file on this Mac.
    func offlineCount(_ playlistID: Int64) -> Int { (members[playlistID] ?? []).filter(videoOnMacIDs.contains).count }
    /// Members with only an audio file here: playable, but not counted as offline video.
    func audioOnlyCount(_ playlistID: Int64) -> Int {
        (members[playlistID] ?? []).filter { onMacIDs.contains($0) && !videoOnMacIDs.contains($0) }.count
    }
    /// The playlist's episodes that can play here, in order, with the file each would play.
    func playableMembers(_ playlistID: Int64) -> [(videoID: Int64, path: String)] {
        (members[playlistID] ?? []).compactMap { id in playable(for: id).map { (id, $0.path) } }
    }
    /// What Continue plays for this playlist (see `PlaylistOrder.resume`).
    func resumeTarget(_ playlistID: Int64) -> Int64? {
        let order = members[playlistID] ?? []
        return PlaylistOrder.resume(order: order, watch: watch, playable: Set(order.filter { playable(for: $0) != nil }))
    }
    /// 1-based place of a video in a playlist.
    func episode(_ videoID: Int64, in playlistID: Int64) -> Int? { members[playlistID]?.firstIndex(of: videoID).map { $0 + 1 } }

    var summaryJobs: [Job] {
        selectedJobs.filter { $0.kind == .summary && $0.status == .succeeded && $0.summary?.nilIfBlank != nil }
    }
    var transcriptJob: Job? { selectedJobs.first { $0.transcript?.nilIfBlank != nil } }
}

struct FailedItem: Identifiable, Equatable {
    let job: Job
    let title: String
    var id: Int64 { job.id }
    var retry: RetryInfo { RetryInfo(action: job.action, videoID: job.videoID, filePath: job.filePath) }
}
