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
        case "section": model.section = AppSection(rawValue: arg) ?? .history
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
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("state.json"))
        }
    }
}
