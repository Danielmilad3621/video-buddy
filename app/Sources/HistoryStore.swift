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
    var lastError: String?

    init(db: Database) { self.db = db }

    func reload() async {
        let (filter, sort, search) = (filter, sort, search)
        do {
            async let list = db.videos(filter: filter, sort: sort, search: search)
            async let latest = db.videos(limit: 8)
            async let allFiles = db.files()
            async let counts = db.stats()
            videos = try await list
            recent = try await latest
            files = try await allFiles
            stats = try await counts
            lastError = nil
        } catch {
            lastError = "Couldn't load history: \(error)"
        }
        await refreshSelection()
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

    var summaryJobs: [Job] {
        selectedJobs.filter { $0.kind == .summary && $0.status == .succeeded && $0.summary?.nilIfBlank != nil }
    }
    var transcriptJob: Job? { selectedJobs.first { $0.transcript?.nilIfBlank != nil } }
}
