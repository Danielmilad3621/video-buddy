// What the views show, loaded from the database. All loading is async; the main thread never waits on SQLite.
import Foundation
import Observation

@MainActor @Observable
final class HistoryStore {
    let db: Database
    var videos: [Video] = []
    var recent: [Video] = []
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
    /// My Playlists, and the videos of the open one in their saved order.
    var playlists: [PlaylistSummary] = []
    var openPlaylistID: Int64? { didSet { if openPlaylistID != oldValue { Task { await reloadPlaylists() } } } }
    var playlistVideos: [Video] = []
    /// Home's "Continue watching": entries you stopped part-way through, with how far you got (0…1).
    var continueWatching: [(video: Video, progress: Double)] = []
    /// The Queue's "Failed" list: jobs that failed or were interrupted and haven't been retried or redone.
    var failed: [FailedItem] = []
    var lastError: String?

    init(db: Database) { self.db = db }

    func reload() async {
        let (filter, sort, search) = (filter, sort, search)
        do {
            async let list = db.videos(filter: filter, sort: sort, search: search)
            async let latest = db.videos(limit: 8)
            async let allFiles = db.files()
            async let counts = db.stats()
            let files = try await allFiles
            let onMac = Set(files.filter { $0.isMedia && $0.exists }.map(\.videoID))
            let loaded = try await list
            videos = filter == .offline ? loaded.filter { onMac.contains($0.id) } : loaded
            recent = try await latest
            self.files = files
            onMacIDs = onMac
            stats = try await counts
            failed = try await db.failedJobs().map { FailedItem(job: $0.job, title: $0.title ?? "Untitled video") }
            var resume: [(video: Video, progress: Double)] = []
            for r in try await db.continueWatching() {
                guard let v = try await db.video(r.videoID), playable(for: v.id) != nil else { continue }
                let total = r.duration ?? v.duration ?? 0
                resume.append((v, total > 0 ? min(r.position / total, 1) : 0))
            }
            continueWatching = resume
            lastError = nil
        } catch {
            lastError = "Couldn't load history: \(error)"
        }
        await reloadPlaylists()
        await refreshSelection()
    }

    func reloadPlaylists() async {
        playlists = (try? await db.playlists()) ?? []
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

    func move(_ step: Int) {
        guard !videos.isEmpty else { return }
        let i = videos.firstIndex { $0.id == selectedID } ?? (step > 0 ? -1 : videos.count)
        select(videos[min(max(i + step, 0), videos.count - 1)].id)
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
