// One-time (and on-demand) import of files already in the downloads folder.
// Read-only: files are never moved, renamed, overwritten or deleted.
import Foundation

struct ImportRun {      // files that share one exact stem, i.e. one processing run
    var stem: String
    var media: [URL] = []
    var summary: URL?
    var transcriptText: URL?
    var transcriptJSON: URL?
    var paths: [String] { (media + [summary, transcriptText, transcriptJSON].compactMap { $0 }).map(\.path) }
}

struct ImportGroup {    // every run that belongs to one video
    var key: String
    var title: String
    var channel: String?
    var platform: String?
    var runs: [ImportRun]
}

enum Importer {
    /// Groups the folder's files by video, leaving out any run whose files the history already knows.
    static func scan(_ dir: URL, known: Set<String>) -> [ImportGroup] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var runs: [String: ImportRun] = [:]
        for name in names.sorted() where !name.hasPrefix(".") {
            guard let (stem, role) = FileNames.role(of: name) else { continue }
            let url = dir.appendingPathComponent(name)
            var run = runs[stem] ?? ImportRun(stem: stem)
            switch role {
            case .media: run.media.append(url)
            case .summary: run.summary = url
            case .transcriptText: run.transcriptText = url
            case .transcriptJSON: run.transcriptJSON = url
            }
            runs[stem] = run
        }
        var groups: [String: ImportGroup] = [:]
        for run in runs.values.sorted(by: { $0.stem < $1.stem }) where !run.paths.contains(where: known.contains) {
            let p = FileNames.parse(stem: run.stem)
            var g = groups[p.groupKey] ?? ImportGroup(key: p.groupKey, title: p.title, channel: p.channel, platform: p.platform, runs: [])
            if g.channel == nil { g.channel = p.channel }
            if g.platform == nil { g.platform = p.platform }
            g.runs.append(run)
            groups[p.groupKey] = g
        }
        return groups.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Writes the groups into history. The original URL is unknown for these files, so it stays unknown.
    static func run(_ groups: [ImportGroup], db: Database) async throws -> (videos: Int, jobs: Int) {
        var videos = Set<Int64>(), jobs = 0
        for g in groups {
            let key = try await db.matchingVideoKey(title: g.title, channel: g.channel) ?? "file:\(g.key)"
            let info = VideoInfo(title: g.title, channel: g.channel, platform: g.platform)
            var firstMedia: String?, videoID: Int64?
            for run in g.runs {
                for job in jobsFor(run) {
                    if let r = try await db.recordCompleted(key: key, url: nil, platform: g.platform, info: info, job: job) {
                        videos.insert(r.video)
                        videoID = r.video
                        jobs += 1
                    }
                }
                firstMedia = firstMedia ?? run.media.first?.path
            }
            if let id = videoID, (try await db.video(id))?.duration == nil, let media = firstMedia,
               let d = await MetadataFetcher.probeDuration(media) {
                try await db.applyInfo(id, VideoInfo(duration: d), override: false)
            }
        }
        return (videos.count, jobs)
    }

    private static func jobsFor(_ run: ImportRun) -> [NewJob] {
        let fm = FileManager.default
        func size(_ u: URL) -> Int? { (try? fm.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.intValue }
        func date(_ u: URL) -> Date { (try? fm.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? Date() }
        var jobs: [NewJob] = []
        let audio = run.media.first { FileItem.mediaRole($0.path) == .audio }
        if run.summary != nil || run.transcriptText != nil {
            let base = run.summary.map { String($0.path.dropLast(".summary.md".count)) }
                ?? String(run.transcriptText!.path.dropLast(".transcript.txt".count))
            let o = SummaryOutputs.load(base: base)
            let when = date(run.summary ?? run.transcriptText!)
            jobs.append(NewJob(kind: .summary, status: o.summary == nil ? .failed : .succeeded, source: .imported,
                               started: when, finished: when, filePath: audio?.path, fileSize: audio.flatMap(size),
                               summaryPath: o.summaryPath, transcriptPath: o.transcriptPath, summary: o.summary,
                               transcript: o.transcript, segmentsJSON: o.segmentsJSON, transcriptLanguage: o.language,
                               error: o.summary == nil ? "Imported without a summary" : nil))
        }
        let audioIsInSummaryJob = !jobs.isEmpty && audio != nil
        for m in run.media where !(audioIsInSummaryJob && m == audio) {
            let when = date(m)
            jobs.append(NewJob(kind: FileItem.mediaRole(m.path) == .video ? .video : .audio, status: .succeeded, source: .imported,
                               started: when, finished: when, filePath: m.path, fileSize: size(m)))
        }
        return jobs
    }
}
