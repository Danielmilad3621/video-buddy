// Picks up jobs that Raycast finished while the app was closed or in the background.
// Raycast's record-history.sh appends one JSON line per event to inbox.jsonl; this reads them back.
import AppKit
import Foundation

struct InboxEvent: Decodable {
    let id: String
    let kind: String
    let url: String?
    let file: String
    let at: Double?
}

enum Inbox {
    /// Complete lines after `offset`. A trailing partial line (writer mid-append) waits for the next read;
    /// lines that aren't valid JSON are counted and skipped. Returns the offset to store once events are recorded.
    static func readNew(_ inbox: URL, offset: Int) -> (events: [InboxEvent], newOffset: Int, skipped: Int) {
        guard let handle = try? FileHandle(forReadingFrom: inbox) else { return ([], offset, 0) }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        let start = size < offset ? 0 : offset   // file replaced or truncated: start over, event ids prevent duplicates
        guard size > start else { return ([], start, 0) }
        try? handle.seek(toOffset: UInt64(start))
        let data = (try? handle.readToEnd()) ?? Data()
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return ([], start, 0) }
        let complete = data[data.startIndex...lastNewline]
        var events: [InboxEvent] = [], skipped = 0
        for line in complete.split(separator: 0x0A) where !line.isEmpty {
            if let event = try? JSONDecoder().decode(InboxEvent.self, from: Data(line)) { events.append(event) } else { skipped += 1 }
        }
        return (events, start + complete.count, skipped)
    }

    /// Records one event. Returns the video id when it was new (nil for duplicates and unknown kinds).
    static func ingest(_ e: InboxEvent, db: Database) async throws -> Int64? {
        guard let kind = JobKind(rawValue: e.kind) else { return nil }
        let media = URL(fileURLWithPath: e.file)
        let ref = e.url.flatMap(VideoRef.parse)
        let parsed = FileNames.parse(stem: media.deletingPathExtension().lastPathComponent)
        let when = e.at.map { Date(timeIntervalSince1970: $0) } ?? Date()
        var job = NewJob(kind: kind, status: .succeeded, source: .raycast, eventID: e.id, started: when, finished: when,
                         filePath: media.path,
                         fileSize: (try? FileManager.default.attributesOfItem(atPath: media.path)[.size] as? NSNumber)?.intValue)
        if kind == .summary {
            let outputs = SummaryOutputs.load(base: media.deletingPathExtension().path)
            job.summary = outputs.summary
            job.summaryPath = outputs.summaryPath
            job.summaryLanguage = SummaryLanguage.english.rawValue   // Raycast always uses the default prompt
            job.summaryFormat = SummaryFormat.standard.rawValue
            job.transcript = outputs.transcript
            job.transcriptPath = outputs.transcriptPath
            job.segmentsJSON = outputs.segmentsJSON
            job.transcriptLanguage = outputs.language
        }
        let key = ref?.key ?? "file:" + parsed.groupKey
        let info = VideoInfo(title: parsed.title, channel: parsed.channel, thumbnail: ref?.thumbnailFallback,
                             platform: ref?.platform ?? parsed.platform)
        return try await db.recordCompleted(key: key, url: ref?.url, platform: info.platform, info: info, job: job)?.video
    }
}

@MainActor
final class Ingestor {
    let store: HistoryStore
    let inbox: URL
    private var timer: Timer?
    private var busy = false

    init(store: HistoryStore, inbox: URL) {
        self.store = store
        self.inbox = inbox
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task { await tick() }
    }

    func tick() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let db = store.db
        let offset = Int(await db.meta("inbox_offset") ?? "") ?? 0
        let batch = Inbox.readNew(inbox, offset: offset)
        guard batch.newOffset != offset || !batch.events.isEmpty else { return }

        var added: [(video: Int64, url: String?, file: String)] = []
        for event in batch.events {
            do {
                if let video = try await Inbox.ingest(event, db: db) { added.append((video, event.url, event.file)) }
            } catch {
                // keep the offset: the whole batch is retried next tick and already-recorded events are skipped
                store.lastError = "Couldn't record a Raycast job: \(error)"
                return
            }
        }
        try? await db.setMeta("inbox_offset", String(batch.newOffset))
        guard !added.isEmpty else { return }
        await store.reload()

        // metadata afterwards, so new entries appear right away
        for item in added {
            if let url = item.url, let info = await MetadataFetcher.fetch(url) {
                try? await db.applyInfo(item.video, info, override: true)
                if let v = (try? await db.video(item.video)) ?? nil {
                    await Thumbnails.ensure(v, localVideo: FileItem.mediaRole(item.file) == .video ? item.file : nil, db: db, online: true)
                }
            }
            if (try? await db.video(item.video))??.duration == nil, let d = await MetadataFetcher.probeDuration(item.file) {
                try? await db.applyInfo(item.video, VideoInfo(duration: d), override: false)
            }
            try? await db.mergeImportedDuplicates(into: item.video)
        }
        await store.reload()
    }
}
