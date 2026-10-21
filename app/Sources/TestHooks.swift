// Test-only remote control, active only when launched with VS_TEST_HOOKS=1 (and VS_SNAPSHOT_DIR for output).
// It calls the same AppModel methods the buttons call, and dumps state as JSON for the end-to-end checks.
import AppKit
import Foundation

@MainActor
enum TestHooks {
    static func install() {
        let env = ProcessInfo.processInfo.environment
        guard env["VS_TEST_HOOKS"] == "1", let dir = env["VS_SNAPSHOT_DIR"] else { return }
        DistributedNotificationCenter.default().addObserver(forName: .init("local.video-summarizer.test"), object: nil, queue: .main) { note in
            let cmd = note.object as? String ?? ""
            MainActor.assumeIsolated { handle(cmd, dir: dir) }
        }
    }

    private static func handle(_ line: String, dir: String) {
        let model = AppModel.shared, store = model.store
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "link": model.link = arg
        case "start": model.start(JobKind(rawValue: arg) ?? .summary)
        case "cancel": model.jobs.cancel()
        case "select":
            if let v = store.videos.first(where: { $0.displayTitle.localizedCaseInsensitiveContains(arg) }) { model.open(v, tab: model.detailTab) }
        case "favorite": if let v = store.selectedVideo { model.toggleFavorite(v) }
        case "search": store.search = arg
        case "filter": store.filter = HistoryFilter(rawValue: arg) ?? .all
        case "sort": store.sort = HistorySort(rawValue: arg) ?? .recent
        case "section": model.section = AppSection(rawValue: arg) ?? .library
        case "tab": model.detailTab = DetailTab(rawValue: arg) ?? .summary
        case "regenerate":
            let f = arg.split(separator: "|").map(String.init)
            model.regenerate(format: SummaryFormat(rawValue: f.first ?? "") ?? AppSettings.format,
                             language: SummaryLanguage(rawValue: f.count > 1 ? f[1] : "") ?? AppSettings.language)
        case "import": model.runImport(model.importOffer)
        case "declineImport": model.declineImport()
        case "remove": if let v = store.selectedVideo { model.pendingRemoval = v; model.confirmRemoval() }
        case "clearAll": model.clearAll()
        case "reload": Task { await store.reload() }
        case "offline": model.network.forcedOffline = arg == "on"
        case "play": if let v = store.selectedVideo { model.play(v) }
        case "pause": model.playback.pause()
        case "seek": model.playback.seek(to: Double(arg) ?? 0)
        case "seekLine":
            if let v = store.selectedVideo, let segs = store.transcriptJob?.segments, let i = Int(arg), segs.indices.contains(i) {
                model.seek(v, to: segs[i].start)
            }
        case "rate": model.playback.rate = Float(arg) ?? 1
        case "mute": model.playback.muted = arg != "off"
        case "stopPlayer": model.playback.stop()
        case "transcribe": if let v = store.selectedVideo { model.transcribe(v) }
        case "offlineVideo": if let v = store.selectedVideo { model.makeAvailableOffline(v) }
        case "summarizeTranscript": model.regenerate()
        case "pauseQueue": model.jobs.pauseQueue()
        case "resumeQueue": model.jobs.resumeQueue()
        case "clearQueue": model.jobs.clearQueue()
        case "thumbnails": Task { await model.backfillThumbnails() }
        case "playlistPreview":
            if let link = PlaylistLink.parse(arg) { model.readPlaylist(link, kind: .audio) }
        case "playlistImport":
            // "<action>|<how many>|<playlist name or empty>" — picks the shortest available videos, to keep tests quick
            let f = arg.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if let state = model.playlistImport, f.count == 3, let action = JobAction(rawValue: f[0]), let n = Int(f[1]) {
                let picks = state.preview.available.sorted { ($0.duration ?? .infinity) < ($1.duration ?? .infinity) }.prefix(n)
                let ordered = state.preview.entries.filter { e in picks.contains { $0.id == e.id } }
                model.importPlaylist(ordered, all: state.preview.entries, action: action,
                                     into: f[2].nilIfBlank.map { .new($0) }, sourceURL: state.preview.url)
            }
        case "newPlaylist": model.createPlaylist(arg, adding: store.selectedVideo?.id)
        case "addToPlaylist":
            if let pl = store.playlists.first(where: { $0.name == arg }), let v = store.selectedVideo { model.addToPlaylist(pl.id, video: v) }
        case "openPlaylist": store.openPlaylistID = store.playlists.first { $0.name == arg }?.id; model.section = .playlists
        case "movePlaylistItem":
            let f = arg.split(separator: "|").compactMap { Int($0) }
            if f.count == 2 { model.movePlaylistItems(from: IndexSet(integer: f[0]), to: f[1]) }
        case "removeFromPlaylist": if let v = store.selectedVideo { model.removeFromOpenPlaylist(v) }
        case "playAll": model.playAll()
        case "makeAllOffline": model.askDownloadMissing(); model.confirmOfflineBatch()
        case "deletePlaylist":
            if let pl = store.playlists.first(where: { $0.name == arg }) { model.pendingPlaylistDeletion = pl; model.confirmPlaylistDeletion() }
        case "next": model.playback.next()
        case "previous": model.playback.previous()
        case "volume": model.playback.volume = Float(arg) ?? 1
        case "loadDetails": if let v = store.selectedVideo { model.loadDetails(v) }
        case "retryFailed": if let f = store.failed.first { model.retry(f.retry) }
        case "showSteps":
            // test-only: a sample of the 4-stage strip, so its look can be checked without a download or an AI call
            let states: [StepState] = [.done, .running, .pending, .pending]
            model.jobs.steps = ["Download audio", "Transcribe on-device", "Generate AI summary", "Save to library"].enumerated()
                .map { JobStep(id: $0.offset, label: $0.element, state: states[$0.offset]) }
            model.jobs.banner = arg == "off" ? nil : .running("Summarizing (sample)…")
        case "settings": NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        // 3.1: playlists as collections
        case "layout": UserDefaults.standard.set(arg, forKey: "libraryLayout")
        case "expand":
            switch arg {
            case "all": store.expanded = Set(store.playlists.map(\.id))
            case "none": store.expanded = []
            default: if let pl = store.playlists.first(where: { $0.name.contains(arg) }) { store.expanded.insert(pl.id) }
            }
        case "playPlaylist": if let pl = store.playlists.first(where: { $0.name.contains(arg) }) { model.playAll(pl.id) }
        case "continuePlaylist": if let pl = store.playlists.first(where: { $0.name.contains(arg) }) { model.continuePlaylist(pl.id) }
        case "checkPlaylist": if let pl = store.playlists.first(where: { $0.name.contains(arg) }) { model.checkPlaylist(pl) }
        case "linkPlaylist":
            // the sheet's main button in Check mode: nothing ticked, so it only links library videos
            if let state = model.playlistImport, let id = state.checking {
                model.importPlaylist([], all: state.preview.entries, action: .video, into: .existing(id), sourceURL: state.preview.url)
            }
        case "closeSheet": model.playlistImport = nil
        case "downloadMissing": if let pl = store.playlists.first(where: { $0.name.contains(arg) }) { model.askDownloadMissing(pl.id) }
        case "confirmOffline": model.confirmOfflineBatch()
        case "cancelOffline": model.pendingOfflineBatch = nil
        case "selectEpisode":
            // "<playlist name part>|<episode number>"
            let f = arg.split(separator: "|").map(String.init)
            if f.count == 2, let pl = store.playlists.first(where: { $0.name.contains(f[0]) }), let n = Int(f[1]),
               let id = store.members[pl.id].flatMap({ $0.indices.contains(n - 1) ? $0[n - 1] : nil }), let v = store.video(id) {
                model.open(v, tab: model.detailTab)
            }
        case "snapshot": Snapshot.save(to: dir)
        case "state": writeState(to: dir)
        default: break
        }
    }

    private static func writeState(to dir: String) {
        let model = AppModel.shared, store = model.store, jobs = model.jobs
        let selected = store.selectedVideo
        var banner: [String: String] = [:]
        switch jobs.banner {
        case let .running(t)?: banner = ["kind": "running", "title": t]
        case let .success(t, s, f)?: banner = ["kind": "success", "title": t, "subtitle": s, "file": f ?? ""]
        case let .failure(t, d, _)?: banner = ["kind": "failure", "title": t, "detail": String(d.suffix(600))]
        case .cancelled?: banner = ["kind": "cancelled"]
        case nil: break
        }
        let state: [String: Any] = [
            "section": model.section.rawValue, "filter": store.filter.rawValue, "sort": store.sort.rawValue, "search": store.search,
            "tab": model.detailTab.rawValue, "isRunning": jobs.isRunning, "notice": model.notice ?? "",
            "importOffer": model.importOffer?.count ?? -1, "importStatus": model.importStatus ?? "",
            "visible": store.videos.map { ["title": $0.displayTitle, "favorite": $0.favorite, "summary": $0.hasSummary,
                                           "audio": $0.hasAudio, "video": $0.hasVideo, "status": $0.latestStatus?.rawValue ?? ""] },
            "selected": selected.map { ["title": $0.displayTitle, "channel": $0.displayChannel, "favorite": $0.favorite,
                                        "duration": $0.duration ?? -1, "upload": $0.uploadDate ?? "", "url": $0.url ?? "",
                                        "platform": $0.platform ?? "", "language": $0.language ?? ""] } ?? [:],
            "selectedJobs": store.selectedJobs.map { ["kind": $0.kind.rawValue, "status": $0.status.rawValue, "format": $0.summaryFormat ?? "",
                                                      "language": $0.summaryLanguage ?? "", "summaryChars": $0.summary?.count ?? 0,
                                                      "segments": $0.segments.count, "file": $0.filePath ?? ""] },
            "files": store.selectedID.map { id in store.files(for: id).map { ["name": $0.name, "role": $0.role.rawValue, "exists": $0.exists] } } ?? [],
            "steps": jobs.steps.map { "\($0.label)=\($0.state)" },
            "banner": banner,
            "stats": ["videos": store.stats.videos, "watch": store.stats.watchSeconds, "summaries": store.stats.summaries, "downloads": store.stats.downloads],
            "existingMedia": selected.flatMap { model.existingMedia($0)?.name } ?? "",
            "lastError": store.lastError ?? "",
            "isOnline": model.network.isOnline,
            "playlists": store.playlists.map { "\($0.name) (\($0.count))" },
            "openPlaylist": store.playlistVideos.map(\.displayTitle),
            "upNext": model.playback.upNext.count,
            "played": model.playback.played.count,
            "layout": UserDefaults.standard.string(forKey: "libraryLayout") ?? "Grouped",
            "groups": { () -> [[String: Any]] in
                let g = Grouping.make(store.videos, playlists: store.playlists, members: store.members)
                return g.groups.map { grp in
                    let id = grp.playlist.id
                    return ["name": grp.playlist.name, "members": store.members[id]?.count ?? 0, "shown": grp.videos.count,
                            "offline": store.offlineCount(id), "audioOnly": store.audioOnlyCount(id),
                            "expanded": store.expanded.contains(id), "first": grp.videos.first?.displayTitle ?? "",
                            "episodes": grp.videos.map { store.episode($0.id, in: id) ?? 0 },
                            "resume": store.resumeTarget(id).flatMap { store.episode($0, in: id) } ?? 0] as [String: Any]
                } + [["name": "Individual Videos", "titles": g.individual.map(\.displayTitle)]]
            }(),
            "watch": selected.flatMap { store.watch[$0.id] }.map { "\($0.state)" } ?? "none",
            "videoOnMac": store.videoOnMacIDs.count,
            "offlineBatch": model.pendingOfflineBatch?.videoIDs.count ?? -1,
            "previewChecking": model.playlistImport?.checking ?? -1,
            "context": model.playback.context.map { ["name": $0.name, "count": $0.count,
                                                     "episode": model.playback.currentVideoID.flatMap { store.episode($0, in: model.playback.context!.id) } ?? 0] as [String: Any] } ?? [:],
            "preview": model.playlistImport.map { ["title": $0.preview.title, "count": $0.preview.entries.count,
                                                   "available": $0.preview.available.count,
                                                   "entries": $0.preview.entries.prefix(8).map { "\($0.title) [\(Fmt.duration($0.duration) ?? "?")]" }] as [String: Any] } ?? [:],
            "queuePaused": jobs.paused,
            "failed": store.failed.map { "\($0.job.action.rawValue): \($0.title)" },
            "continueWatching": store.continueWatching.map { "\($0.video.displayTitle) \(Int($0.progress * 100))%" },
            "description": selected?.description ?? "",
            "tags": selected?.tags ?? [],
            "queueBadge": jobs.queue.count + (jobs.current == nil ? 0 : 1),
            "current": jobs.current.map { "\($0.action.rawValue): \($0.title)" } ?? "",
            "queue": jobs.queue.map { "\($0.action.rawValue): \($0.title)" },
            "onMac": store.videos.filter { store.onMacIDs.contains($0.id) }.map(\.displayTitle),
            "thumbnailPath": selected?.thumbnailPath ?? "",
            "playback": ["path": model.playback.currentPath ?? "", "time": model.playback.currentTime,
                         "duration": model.playback.duration, "playing": model.playback.isPlaying, "rate": model.playback.rate,
                         "volume": model.playback.volume, "hasPrevious": model.playback.hasPrevious,
                         "line": (model.playback.currentVideoID == selected?.id ? store.transcriptJob?.segments.index(at: model.playback.currentTime) : nil) ?? -1],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("state.json"))
        }
    }
}
