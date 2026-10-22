// `VideoSummarizer --selftest`: checks the logic that must not break, on throwaway data. build.sh runs it.
import Foundation

enum SelfTest {
    nonisolated(unsafe) private static var failures: [String] = []
    nonisolated(unsafe) private static var passed = 0

    private static func check(_ ok: Bool, _ what: String, file: StaticString = #fileID, line: UInt = #line) {
        if ok { passed += 1 } else { failures.append("\(what)  (\(file):\(line))") }
    }

    static func runBlocking() -> Int32 {
        // keep the main run loop turning while the checks run, so the ones that need the main actor can
        nonisolated(unsafe) var done = false
        Task.detached {
            do { try await run() } catch { failures.append("threw: \(error)") }
            done = true
        }
        while !done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
        if failures.isEmpty {
            print("selftest: \(passed) checks passed")
            return 0
        }
        print("selftest: \(failures.count) FAILED, \(passed) passed")
        failures.forEach { print("  ✗ \($0)") }
        return 1
    }

    private static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vs-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        parsing()
        try await database(root.appendingPathComponent("db"))
        try await backups(root.appendingPathComponent("backup"))
        try corruption(root.appendingPathComponent("corrupt"))
        try await inbox(root.appendingPathComponent("inbox"))
        try await importer(root.appendingPathComponent("import"))
        try await upgrade(root.appendingPathComponent("upgrade"))
        try await queue(root.appendingPathComponent("queue"))
        try await playlists(root.appendingPathComponent("playlists"))
        try await grouping(root.appendingPathComponent("grouping"))
        browserPolicy()
        browserBar()
        browserTabs()
        await checkerRapidNavigation()
        try await migrations(root.appendingPathComponent("migrations"))
        preview()
    }

    /// Only inside Video Buddy 4.0 Preview.app (preview.sh runs this before installing): it must never share 3.1's data or run jobs.
    private static func preview() {
        guard AppSettings.isPreview else { return }
        check(AppSettings.dataDir.lastPathComponent.hasPrefix("Video Buddy 4.0 ") && AppSettings.dataDir.lastPathComponent != "Video Summarizer",
              "preview: its own data folder")
        check(AppSettings.defaultDownloadDir.hasPrefix(AppSettings.dataDir.path + "/"), "preview: downloads inside its data folder")
        check(JobController.locked(false), "preview: the queue can't be resumed")
    }

    // MARK: pure parsing

    private static func parsing() {
        let id = "jNQXAC9IVRw"
        for link in ["https://www.youtube.com/watch?v=\(id)", "https://youtu.be/\(id)?t=3", "https://m.youtube.com/watch?v=\(id)&list=x",
                     "https://youtube.com/shorts/\(id)", "https://www.youtube.com/embed/\(id)", "https://music.youtube.com/watch?v=\(id)"] {
            check(VideoRef.parse(link)?.key == "youtube:\(id)", "youtube link parses: \(link)")
        }
        check(VideoRef.parse("not a link") == nil, "rejects text")
        check(VideoRef.parse("ftp://example.com/x") == nil, "rejects non-http")
        check(VideoRef.parse("https://www.youtube.com/feed/library") == nil, "rejects non-video youtube page")
        check(VideoRef.parse("https://vimeo.com/123/#t=1")?.key == VideoRef.parse("https://www.vimeo.com/123")?.key, "normalises other sites")
        check(VideoRef.parse("https://vimeo.com/123")?.platform == "Vimeo", "names platform")

        let a = FileNames.parse(stem: "Me at the zoo - jawed (youtube)")
        check(a.title == "Me at the zoo" && a.channel == "jawed" && a.platform == "YouTube", "cobalt audio name")
        let v = FileNames.parse(stem: "Me at the zoo - jawed (240p, h264, youtube)")
        check(v.groupKey == a.groupKey && v.channel == "jawed", "cobalt video name groups with audio")
        check(FileNames.parse(stem: "Me at the zoo - jawed (youtube) (2)").groupKey == a.groupKey, "repeat download groups")
        let y = FileNames.parse(stem: "Inside the Mind ｜ Tim Urban ｜ TED")
        check(y.title == "Inside the Mind ｜ Tim Urban ｜ TED" && y.channel == nil, "yt-dlp name keeps title, no guessed channel")
        check(FileNames.role(of: "X.summary.md")?.stem == "X" && FileNames.role(of: "X.transcript.json")?.stem == "X", "roles")
        check(FileNames.role(of: "notes.txt") == nil, "ignores other files")

        let script = (try? String(contentsOfFile: Paths.summarize, encoding: .utf8)) ?? ""
        check(script.contains(Prompts.standard), "Standard prompt matches the bundled summarize.sh exactly (\(Paths.summarize))")
        check(FileManager.default.isExecutableFile(atPath: Paths.summarize) && FileManager.default.isExecutableFile(atPath: Paths.cobaltDL), "bundled scripts present and executable")
        check(Prompts.build(.standard, .english) == Prompts.standard, "Standard + English adds nothing")
        check(Prompts.build(.adhd, .masri).contains("ADHD") && Prompts.build(.adhd, .masri).contains("Egyptian"), "ADHD + Masri prompt")

        let md = Markdown.parse("""
        **TL;DR:** It is short.

        **Key points**
        - one **bold**
          - nested
        1. first
        # Heading
        ---
        plain
        """)
        check(md == [.heading("TL;DR", 2), .paragraph("It is short."), .heading("Key points", 2), .bullet("one **bold**", 0),
                     .bullet("nested", 1), .numbered("1", "first"), .heading("Heading", 1), .rule, .paragraph("plain")],
              "markdown blocks: \(md)")
        check(Markdown.isRTL("ده ملخص") && !Markdown.isRTL("Hello"), "RTL detection")
        check(Fmt.duration(18) == "0:18" && Fmt.duration(8316) == "2:18:36" && Fmt.duration(nil) == nil, "durations")
        check(Fmt.watchTime(44_640) == "12h 24m", "watch time")

        // 3.0: the summary as cards
        let cards = Markdown.sections(Markdown.parse("""
        # Video summary
        ## TL;DR
        Short.

        ## Key Points
        - a
        - b
          - nested
        ---
        ## Actionable Takeaways
        - do it
        """))
        check(cards.map(\.kind) == [.tldr, .keyPoints, .takeaways] && cards[1].blocks.count == 3 && cards[0].displayTitle == "TL;DR",
              "summary cards: \(cards.map(\.title))")
        let brief = Markdown.sections(Markdown.parse("One short paragraph."))
        check(brief.count == 1 && brief[0].kind == .tldr && brief[0].displayTitle == "Summary", "a summary without headings is one card")
        check(Markdown.sections(Markdown.parse("- a\n- b")).first?.kind == .keyPoints, "a bullets-only summary is Key Points")
        check(Markdown.sections(Markdown.parse("## ⭐ Key takeaways\n- x\n## أهم النقاط\n- y")).map(\.kind) == [.takeaways, .keyPoints],
              "ADHD takeaways and Arabic headings")
        check(HistoryFilter.allCases.map(\.rawValue) == ["All", "Summaries", "Audio", "Video", "Offline", "Favorites"], "library filter chips")
    }

    // MARK: database

    private static func database(_ dir: URL) async throws {
        let db = try Database(directory: dir)
        let ref = VideoRef.parse("https://youtu.be/jNQXAC9IVRw")!
        let first = try await db.startJob(ref, kind: .summary, source: .app)
        let again = try await db.startJob(ref, kind: .audio, source: .app)
        check(first.video == again.video, "same video, one entry")
        check(try await db.count("videos") == 1, "no duplicate video rows")

        try await db.finishJob(first.job, videoID: first.video,
                               NewJob(kind: .summary, status: .succeeded, source: .app, filePath: "/tmp/x.mp3", fileSize: 10,
                                      summary: "Elephants have long trunks.", transcript: "here we are with the 50% elephants"))
        try await db.finishJob(again.job, videoID: again.video, NewJob(kind: .audio, status: .failed, source: .app, error: "boom"))
        try await db.applyInfo(first.video, VideoInfo(title: "Me at the zoo", channel: "jawed", duration: 18), override: true)
        try await db.applyInfo(first.video, VideoInfo(title: "guess", duration: 99), override: false)
        let v = try await db.video(first.video)
        check(v?.title == "Me at the zoo" && v?.duration == 18, "guesses never overwrite metadata")
        check(v?.hasSummary == true && v?.hasAudio == true && v?.latestStatus == .failed, "derived flags")

        check(try await db.videos(search: "elephants").count == 1, "search summary/transcript")
        check(try await db.videos(search: "JAWED").count == 1, "search channel, case-insensitive")
        check(try await db.videos(search: "zzzq").isEmpty, "search miss")
        check(try await db.videos(search: "e_e").isEmpty, "search escapes _ (unescaped it would match \"ele\")")
        check(try await db.videos(search: "50%").count == 1, "search literal %")
        let summarized = try await db.videos(filter: .summaries), downloaded = try await db.videos(filter: .video)
        check(summarized.count == 1 && downloaded.isEmpty, "filters")

        try await db.setFavorite(first.video, true)
        check(try await db.videos(filter: .favorites).count == 1, "favorites filter")

        var stats = try await db.stats()
        check(stats == Stats(videos: 1, watchSeconds: 18, summaries: 1, downloads: 0), "stats \(stats)")

        // a failed regeneration leaves the saved summary alone
        let regen = try await db.startJob(videoID: first.video, kind: .summary, source: .app)
        try await db.finishJob(regen, videoID: first.video, NewJob(kind: .summary, status: .failed, source: .app, error: "x"))
        let saved = try await db.jobs(for: first.video).filter { $0.kind == .summary && $0.status == .succeeded }
        check(saved.count == 1 && saved[0].summary == "Elephants have long trunks.", "failed regeneration keeps summary")

        // crash recovery
        let crashed = try await db.startJob(ref, kind: .video, source: .app)
        check(try await db.recoverInterrupted() == 1, "recovers running jobs")
        check(try await db.jobs(for: crashed.video).first { $0.id == crashed.job }?.status == .interrupted, "marked interrupted")

        // Raycast events are recorded once
        let event = NewJob(kind: .video, status: .succeeded, source: .raycast, eventID: "E1", filePath: "/tmp/v.mp4")
        let r1 = try await db.recordCompleted(key: ref.key, url: ref.url, platform: "YouTube", info: nil, job: event)
        let r2 = try await db.recordCompleted(key: ref.key, url: ref.url, platform: "YouTube", info: nil, job: event)
        check(r1 != nil && r2 == nil, "duplicate event ignored")
        stats = try await db.stats()
        check(stats.downloads == 1, "video download counted")
        check(try await db.files().contains { $0.path == "/tmp/v.mp4" && $0.role == .video }, "files list")

        // an imported file-only entry folds into the real video once title and channel match
        let imp = try await db.recordCompleted(key: "file:me at the zoo - jawed", url: nil, platform: "YouTube",
                                               info: VideoInfo(title: "Me at the zoo", channel: "jawed"),
                                               job: NewJob(kind: .audio, status: .succeeded, source: .imported, filePath: "/tmp/old.mp3"))
        try await db.setFavorite(imp!.video, true)
        try await db.mergeImportedDuplicates(into: first.video)
        check(try await db.count("videos") == 1, "merged imported duplicate")
        check(try await db.jobs(for: first.video).contains { $0.filePath == "/tmp/old.mp3" }, "merged jobs moved")

        // delete removes records only
        let keep = dir.appendingPathComponent("keep.mp3")
        try Data("x".utf8).write(to: keep)
        let other = try await db.startJob(VideoRef.parse("https://vimeo.com/1")!, kind: .audio, source: .app)
        try await db.finishJob(other.job, videoID: other.video, NewJob(kind: .audio, status: .succeeded, source: .app, filePath: keep.path))
        try await db.deleteVideo(other.video)
        check(try await db.jobs(for: other.video).isEmpty, "cascade delete")
        check(FileManager.default.fileExists(atPath: keep.path), "delete keeps files")

        // retention never prunes favorites
        let old = try await db.startJob(VideoRef.parse("https://vimeo.com/2")!, kind: .audio, source: .app, at: Date(timeIntervalSinceNow: -400 * 86_400))
        _ = old
        check(try await db.prune(olderThanDays: 365) == 1, "prunes old non-favorites")
        check(try await db.video(first.video) != nil, "keeps favorites")

        // 3.0: description and tags from yt-dlp; guesses never replace them
        try await db.applyInfo(first.video, VideoInfo(description: "About elephants.", tags: ["zoo", "elephants"]), override: true)
        try await db.applyInfo(first.video, VideoInfo(description: "guess", tags: ["x"]), override: false)
        let described = try await db.video(first.video)
        check(described?.description == "About elephants." && described?.tags == ["zoo", "elephants"], "description and tags stored")

        // 3.0: failed jobs until something newer of the same kind replaces them
        let bad = try await db.enqueue(videoID: first.video, action: .transcribe, filePath: "/tmp/missing.mp4")
        _ = try await db.markRunning(bad)
        try await db.finishJob(bad, videoID: first.video, NewJob(kind: .transcript, status: .failed, source: .app, error: "no file"))
        let failedNow = try await db.failedJobs()
        // (a failed job's file path isn't kept; a retried transcription uses the entry's file that's on this Mac)
        check(failedNow.contains { $0.job.id == bad && $0.job.action == .transcribe && $0.job.videoID == first.video },
              "a failed job is listed with what Retry needs")
        let retried = try await db.enqueue(videoID: first.video, action: .transcribe, filePath: "/tmp/missing.mp4")
        check(try await !db.failedJobs().contains { $0.job.id == bad }, "a retried job leaves the failed list")
        try await db.removeQueued(retried)

        // 3.0: continue watching, with the player's "nearly finished" rule
        try await db.savePosition("/tmp/v.mp4", position: 30, duration: 100)
        check(try await db.continueWatching().first.map { $0.videoID == first.video && $0.position == 30 } == true, "continue watching")
        try await db.savePosition("/tmp/v.mp4", position: 97, duration: 100)
        check(try await db.continueWatching().isEmpty, "nearly finished files aren't offered again")
        check(try await db.quickCheck() == "ok", "integrity")
    }

    private static func backups(_ dir: URL) async throws {
        let db = try Database(directory: dir)
        _ = try await db.startJob(VideoRef.parse("https://youtu.be/jNQXAC9IVRw")!, kind: .audio, source: .app)
        let b = dir.appendingPathComponent("backups")
        let current = b.appendingPathComponent("history-backup.sqlite"), prev = b.appendingPathComponent("history-backup.prev.sqlite")
        check(try await db.backupIfDue(force: true), "first backup")
        check(try await db.backupIfDue(force: true), "second backup does not fail on an existing file")
        check(Database.isHealthy(current) && Database.isHealthy(prev), "both backups healthy")
        check(try await !db.backupIfDue(), "not due again within a day")
        let before = try Data(contentsOf: current), beforePrev = try Data(contentsOf: prev)
        var threw = false
        do { try await db.backupIfDue(force: true, verify: { _ in false }) } catch { threw = true }
        check(threw, "bad copy is rejected")
        check(try Data(contentsOf: current) == before && Data(contentsOf: prev) == beforePrev, "bad copy leaves both backups untouched")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: b.path).filter { $0.hasSuffix(".tmp") }
        check(leftovers.isEmpty, "no temp copies left")
    }

    private static func corruption(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 4096).write(to: dir.appendingPathComponent("history.sqlite"))
        _ = try Database(directory: dir)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        check(names.contains { $0.hasPrefix("history.corrupt-") }, "corrupt file kept aside, not deleted")
    }

    private static func inbox(_ dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(directory: dir)
        let file = dir.appendingPathComponent("inbox.jsonl")
        let e1 = #"{"id":"A","kind":"audio","url":"https://youtu.be/jNQXAC9IVRw","file":"/tmp/a.mp3","at":1}"#
        let e2 = #"{"id":"B","kind":"video","url":"https://vimeo.com/9","file":"/tmp/b.mp4","at":2}"#
        try (e1 + "\nnot json\n" + e2 + "\n" + #"{"id":"C","ki"#).write(to: file, atomically: true, encoding: .utf8)
        var r = Inbox.readNew(file, offset: 0)
        check(r.events.map(\.id) == ["A", "B"] && r.skipped == 1, "complete lines only, bad line skipped")
        for e in r.events { _ = try await Inbox.ingest(e, db: db) }
        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd()
        try h.write(contentsOf: Data(#"nd":"audio","url":"","file":"/tmp/c.mp3","at":3}"#.utf8 + [0x0A]))
        try h.close()
        r = Inbox.readNew(file, offset: r.newOffset)
        check(r.events.map(\.id) == ["C"], "partial line read once complete")
        for e in r.events { _ = try await Inbox.ingest(e, db: db) }
        // a crash before the offset was saved, or a truncated file, replays events: none may duplicate
        for e in Inbox.readNew(file, offset: 999_999).events { check(try await Inbox.ingest(e, db: db) == nil, "replayed event \(e.id) ignored") }
        check(try await db.count("jobs") == 3, "three events, three jobs")
    }

    /// A real version-1 database (as the app made before 2.1) upgrades without losing anything, after a verified backup.
    private static func upgrade(_ dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let v1 = try SQLite(path: dir.appendingPathComponent("history.sqlite").path)
            try Database.createV1(v1)
            try v1.run("INSERT INTO videos(key, url, title, favorite, first_processed, last_processed) VALUES('youtube:jNQXAC9IVRw', 'u', 'Me at the zoo', 1, 1, 2)")
            try v1.run("INSERT INTO jobs(video_id, kind, status, source, started, summary) VALUES(1, 'summary', 'succeeded', 'app', 1, 'S')")
            try v1.run("INSERT INTO jobs(video_id, kind, status, source, started, file_path) VALUES(1, 'video', 'succeeded', 'app', 2, '/tmp/v.mp4')")
        }
        let db = try Database(directory: dir)
        check(try await db.schemaVersion() == Database.latestVersion, "upgraded to the latest version")
        let v = try await db.video(1)
        check(v?.title == "Me at the zoo" && v?.favorite == true && v?.hasSummary == true && v?.hasVideo == true, "data kept through the upgrade")
        let jobs = try await db.jobs(for: 1)
        check(jobs.map(\.action) == [.video, .summarize] && jobs.last?.summary == "S", "existing jobs get their action")
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("backups").path)) ?? []
        let pre = backups.filter { $0.hasPrefix("history-pre-v2-") }
        check(pre.count == 1 && Database.isHealthy(dir.appendingPathComponent("backups/\(pre[0])")), "verified backup made before the upgrade")
        check(try await db.quickCheck() == "ok", "upgraded database healthy")
        _ = try Database(directory: dir)   // opening again must not upgrade or back up twice
        let after = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("backups").path)) ?? []
        check(after.filter { $0.hasPrefix("history-pre-v2-") }.count == 1 && !after.contains { $0.hasPrefix("history-pre-v3-") }
              && !after.contains { $0.hasPrefix("history-pre-v4-") }, "no second upgrade backup")

        // a 2.1 database (version 2) gets its own verified copy before the 3.0 columns are added
        let v2dir = dir.appendingPathComponent("v2")
        do {
            let fresh = try Database(directory: v2dir)
            _ = try await fresh.enqueue(VideoRef.parse("https://youtu.be/jNQXAC9IVRw")!, action: .audio)
        }
        do {
            let raw = try SQLite(path: v2dir.appendingPathComponent("history.sqlite").path)
            try raw.exec("ALTER TABLE videos DROP COLUMN description; ALTER TABLE videos DROP COLUMN tags; PRAGMA user_version = 2;")
        }
        let up = try Database(directory: v2dir)
        let kept = try await up.videos()
        check(try await up.schemaVersion() == Database.latestVersion && kept.count == 1 && kept[0].description == nil && kept[0].tags.isEmpty,
              "2.1 → 3.0 keeps entries; older ones have no description yet")
        let pre3 = ((try? FileManager.default.contentsOfDirectory(atPath: v2dir.appendingPathComponent("backups").path)) ?? [])
            .filter { $0.hasPrefix("history-pre-v3-") }
        check(pre3.count == 1 && Database.isHealthy(v2dir.appendingPathComponent("backups/\(pre3[0])")), "verified backup before the 3.0 upgrade")
    }

    private static func queue(_ dir: URL) async throws {
        let db = try Database(directory: dir)
        let a = try await db.enqueue(VideoRef.parse("https://youtu.be/jNQXAC9IVRw")!, action: .summarize, format: "ADHD-Friendly", language: "English")
        let t = try await db.enqueue(videoID: a.video, action: .transcribe, filePath: "/tmp/zoo.mp4")
        let b = try await db.enqueue(VideoRef.parse("https://vimeo.com/5")!, action: .audio)
        check(try await db.nextQueued(networkAvailable: true)?.id == a.job, "queue runs oldest first")
        check(try await db.nextQueued(networkAvailable: false)?.id == t, "offline: only on-device work is picked")
        check(try await db.queuedJobs().map(\.job.id) == [a.job, t, b.job], "queue order")
        check(try await db.jobs(for: a.video).first { $0.id == a.job }?.summaryFormat == "ADHD-Friendly", "queued job keeps its format")
        let firstStart = try await db.markRunning(a.job), secondStart = try await db.markRunning(a.job)
        check(firstStart && !secondStart, "a job starts only once")
        check(try await db.recoverInterrupted() == 1, "crash recovery touches the running job only")
        check(try await db.queuedJobs().count == 2, "queued jobs survive a restart")
        try await db.removeQueued(t)
        check(try await db.nextQueued(networkAvailable: false) == nil, "removed job is gone from the queue")
        let cleared = try await db.clearQueue(), left = try await db.queuedJobs()
        check(cleared == 1 && left.isEmpty, "clear queue")
        check(try await db.video(a.video)?.latestStatus == .interrupted, "an entry shows its most recently started job (the interrupted one)")

        try await db.savePosition("/tmp/zoo.mp4", position: 12.5, duration: 19)
        try await db.savePosition("/tmp/zoo.mp4", position: 14, duration: 19)
        let saved = await db.position("/tmp/zoo.mp4"), none = await db.position("/tmp/none.mp4")
        check(saved == 14 && none == nil, "resume position saved per file")
        try await db.setThumbnailPath(a.video, "/tmp/t.jpg")
        check(try await db.video(a.video)?.thumbnailPath == "/tmp/t.jpg", "thumbnail path stored")

        let segs = [Segment(start: 0, end: 4, text: "a"), Segment(start: 4, end: 12, text: "b"), Segment(start: 12, end: 19, text: "c")]
        check(segs.index(at: 5) == 1 && segs.index(at: 0) == 0 && segs.index(at: 30) == 2 && segs.index(at: -1) == nil, "transcript line at a time")
        check(VideoQuality.standard.scriptValue == nil && VideoQuality.p720.scriptValue == "720" && VideoQuality.best.scriptValue == "max",
              "quality: the default sends nothing to the scripts")
        check(JobAction.transcribe.needsNetwork == false && JobAction.resummarize.needsNetwork && JobAction.transcribe.kind == .transcript,
              "transcribing is on-device")
        check(JobAction.download(.audio, transcript: true) == .audioTranscript && JobAction.download(.video, transcript: true) == .videoTranscript
              && JobAction.download(.audio, transcript: false) == .audio && JobAction.download(.summary, transcript: true) == .summarize,
              "+ Transcript picks the action; unticked is the same as before")
        check(JobAction.audioTranscript.kind == .audio && JobAction.videoTranscript.kind == .video && JobAction.videoTranscript.needsNetwork
              && JobAction.videoTranscript.transcribesAfter && !JobAction.video.transcribesAfter && !JobAction.summarize.transcribesAfter,
              "+ Transcript downloads are still audio/video entries")
        _ = try await db.enqueue(VideoRef.parse("https://vimeo.com/6")!, action: .videoTranscript)
        let stored = try await db.queuedJobs().first?.job
        check(stored?.action == .videoTranscript && stored?.kind == .video, "+ Transcript survives the queue (no schema change)")
        try await db.clearQueue()
    }

    private static func playlists(_ dir: URL) async throws {
        let pl = "PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI"
        check(PlaylistLink.parse("https://www.youtube.com/playlist?list=\(pl)") == PlaylistLink(listID: pl, url: "https://www.youtube.com/playlist?list=\(pl)", videoID: nil),
              "playlist link")
        check(PlaylistLink.parse("https://www.youtube.com/watch?v=jNQXAC9IVRw&list=\(pl)&index=2")?.videoID == "jNQXAC9IVRw", "watch link inside a playlist")
        check(PlaylistLink.parse("https://youtu.be/jNQXAC9IVRw?list=\(pl)")?.listID == pl, "short link inside a playlist")
        check(PlaylistLink.parse("https://www.youtube.com/watch?v=jNQXAC9IVRw") == nil && PlaylistLink.parse("https://vimeo.com/1?list=\(pl)") == nil,
              "not a playlist")
        check(VideoRef.parse("https://www.youtube.com/watch?v=jNQXAC9IVRw&list=\(pl)")?.key == "youtube:jNQXAC9IVRw", "just-this-video still works")

        let sample = #"{"title":"Test list","entries":[{"id":"jNQXAC9IVRw","title":"Me at the zoo","duration":19,"channel":"jawed"},{"id":"AAAAAAAAAAA","title":"[Private video]"},{"id":"BBBBBBBBBBB","title":"[Deleted video]","duration":null},{"id":"bad","title":"x"},{"id":"CCCCCCCCCCC","title":"Third","duration":61.0,"uploader":"U"}]}"#
        let preview = PlaylistImport.parse(Data(sample.utf8), url: "u")
        check(preview?.title == "Test list" && preview?.entries.count == 4 && preview?.available.map(\.id) == ["jNQXAC9IVRw", "CCCCCCCCCCC"],
              "playlist listing: private/deleted marked, bad ids dropped")
        check(preview?.entries.last?.channel == "U" && preview?.entries.first?.url == "https://www.youtube.com/watch?v=jNQXAC9IVRw", "playlist entry details")

        let db = try Database(directory: dir)
        let existing = try await db.enqueue(VideoRef.parse("https://youtu.be/jNQXAC9IVRw")!, action: .audio)
        let r = try await db.importPlaylist(preview!.available, action: .video, format: nil, language: nil, into: .new("Trip"), sourceURL: "u")
        check(r.jobs == 2 && r.playlist != nil, "playlist import queues each video")
        check(try await db.count("videos") == 2, "an entry already in history is reused, not duplicated")
        let order = try await db.videos(playlist: r.playlist!).map(\.title)
        check(order == ["Me at the zoo", "Third"], "playlist keeps the original order: \(order)")
        check(try await db.video(existing.video)?.duration == 19, "duration from the listing")
        check(try await db.queuedJobs().map(\.job.action) == [.audio, .video, .video], "queued in order")

        let mine = try await db.createPlaylist("Mine")
        let third = try await db.videos(playlist: r.playlist!)[1].id
        try await db.addToPlaylist(mine, videoIDs: [third, existing.video, third])
        check(try await db.videos(playlist: mine).map(\.id) == [third, existing.video], "add appends and skips duplicates")
        try await db.reorderPlaylist(mine, videoIDs: [existing.video, third])
        check(try await db.videos(playlist: mine).map(\.id) == [existing.video, third], "reorder")
        try await db.removeFromPlaylist(mine, videoID: existing.video)
        check(try await db.videos(playlist: mine).map(\.id) == [third], "remove from playlist")
        try await db.setThumbnailPath(third, "/tmp/third.jpg")
        let lists = try await db.playlists()
        check(lists.first { $0.name == "Mine" }?.coverPath == "/tmp/third.jpg", "playlist artwork is its first video's thumbnail")
        check(lists.map(\.name) == ["Mine", "Trip"] && lists.first { $0.name == "Trip" }?.count == 2 && lists.first { $0.name == "Trip" }?.totalDuration == 80,
              "playlist summaries")
        try await db.deleteVideo(third)
        let mineAfter = try await db.videos(playlist: mine), tripAfter = try await db.videos(playlist: r.playlist!)
        check(mineAfter.isEmpty && tripAfter.count == 1, "removing history removes it from playlists")
        try await db.deletePlaylist(r.playlist!)
        let kept = try await db.video(existing.video), remaining = try await db.playlists()
        check(kept != nil && remaining.count == 1, "deleting a playlist keeps its videos")
    }

    /// 3.1: playlists as collections. An already-downloaded episode joins by video id without downloading anything,
    /// hand-made order survives, nothing downloads twice, grouping follows filters and search, and Continue knows
    /// finished from not started.
    private static func grouping(_ dir: URL) async throws {
        let db = try Database(directory: dir)
        let ids = (1...5).map { String(format: "EPISODE%04d", $0) }
        let all = ids.enumerated().map { i, id in
            PlaylistEntry(id: id, index: i, title: "Episode \(i + 1)", duration: 100, url: "https://www.youtube.com/watch?v=\(id)",
                          channel: "C", available: true)
        }
        let source = "https://www.youtube.com/playlist?list=PLtest000001"
        // episode 1 was downloaded on its own before the playlist existed
        let ep1 = try await db.recordCompleted(key: "youtube:\(ids[0])", url: all[0].url, platform: "YouTube", info: VideoInfo(title: "Episode 1"),
                                               job: NewJob(kind: .video, status: .succeeded, source: .app, finished: Date(), filePath: "/tmp/ep1.mp4"))!.video
        let made = try await db.importPlaylist(Array(all[1...]), all: all, action: .video, format: nil, language: nil,
                                               into: .new("Series"), sourceURL: source)
        let series = made.playlist!
        check(made.jobs == 4 && made.linked == 5, "a new playlist links every library video of it, queues only the chosen: \(made)")
        try await db.removeFromPlaylist(series, videoID: ep1)        // the 3.0 state: episode 1 left out
        let again = try await db.importPlaylist(Array(all[1...]), action: .video, format: nil, language: nil,
                                                into: .existing(series), sourceURL: source)
        check(again.jobs == 0 && again.linked == 0, "re-importing doesn't queue downloads that are already waiting: \(again)")
        check(try await db.playlists().count == 1, "re-importing into the playlist doesn't create another")
        let byKey = Dictionary(try await db.videos().map { ($0.key, $0.id) }, uniquingKeysWith: { a, _ in a })
        let (e2, e3, e4, e5) = (byKey["youtube:\(ids[1])"]!, byKey["youtube:\(ids[2])"]!, byKey["youtube:\(ids[3])"]!, byKey["youtube:\(ids[4])"]!)
        check(try await db.videos(playlist: series).map(\.id) == [e2, e3, e4, e5], "the playlist keeps YouTube's order")
        try await db.reorderPlaylist(series, videoIDs: [e3, e2, e4, e5])      // dragged by hand
        let queuedBefore = try await db.queuedJobs().count, jobsBefore = try await db.count("jobs")
        let checked = try await db.importPlaylist([], all: all, action: .video, format: nil, language: nil,
                                                  into: .existing(series), sourceURL: source)
        check(checked.jobs == 0 && checked.linked == 1, "Check Against YouTube links the downloaded episode and queues nothing: \(checked)")
        let (queuedAfter, jobsAfter) = (try await db.queuedJobs().count, try await db.count("jobs"))
        check(queuedAfter == queuedBefore && jobsAfter == jobsBefore, "linking adds no jobs")
        check(try await db.videos(playlist: series).map(\.id) == [e3, ep1, e2, e4, e5],
              "the hand-made order stays; episode 1 goes right before episode 2")
        check(try await db.count("videos") == 5, "one record per video")

        check(PlaylistOrder.merge(current: [], youtube: [1, 2, 3]) == [1, 2, 3], "a new playlist takes YouTube's order")
        check(PlaylistOrder.merge(current: [2], youtube: [1, 2, 3]) == [1, 2, 3], "missing ones slot in around existing members")
        check(PlaylistOrder.merge(current: [3, 1, 9], youtube: [1, 2, 3]) == [3, 1, 2, 9], "existing members never move")
        let placed = PlaylistOrder.newPositions([1, 2, 3], existing: [2: 0])
        check(placed.map(\.0) == [1, 3] && placed.map(\.1) == [-1, 1], "new positions sit between neighbours: \(placed)")

        // nothing downloads twice: the same video and media type while one waits or runs
        let ep1Video = try await db.enqueue(videoID: ep1, action: .video)
        var refused = false
        do { _ = try await db.enqueue(videoID: ep1, action: .videoTranscript) } catch is AlreadyQueued { refused = true }
        check(refused, "a second video download of the same video is refused while one is waiting")
        check((try? await db.enqueue(videoID: ep1, action: .audio)) != nil, "audio of the same video is a different download")
        _ = try await db.markRunning(ep1Video)
        refused = false
        do { _ = try await db.enqueue(VideoRef.parse(all[0].url)!, action: .video) } catch is AlreadyQueued { refused = true }
        check(refused, "nor while it's downloading")

        // many-to-many, grouping and search
        let other = try await db.createPlaylist("Road trip")
        try await db.addToPlaylist(other, videoIDs: [e3])
        let solo = try await db.enqueue(VideoRef.parse("https://youtu.be/SOLOVIDEO01")!, action: .audio).video
        let members = Dictionary(grouping: try await db.memberships(), by: \.playlist).mapValues { $0.map(\.video) }
        let lists = try await db.playlists()
        let g = Grouping.make(try await db.videos(), playlists: lists, members: members)
        check(g.groups.map(\.playlist.name) == ["Road trip", "Series"] && g.groups.last?.videos.map(\.id) == [e3, ep1, e2, e4, e5],
              "grouped: playlists in order, episodes in playlist order")
        check(g.groups.first?.videos.map(\.id) == [e3] && g.individual.map(\.id) == [solo], "a video in two playlists shows in both; others are individual")
        check(try await db.count("videos") == 6, "…and is still stored once")
        try await db.setFavorite(e4, true); try await db.setFavorite(e2, true)
        let fav = Grouping.make(try await db.videos(filter: .favorites), playlists: lists, members: members)
        check(fav.groups.map(\.playlist.name) == ["Series"] && fav.groups[0].videos.map(\.id) == [e2, e4] && fav.individual.isEmpty,
              "favorites stay under their playlist, in its order; empty playlists drop out")
        let found = try await db.videos(search: "series").map(\.id)
        check(Set(found) == Set([e3, ep1, e2, e4, e5]), "searching a playlist name finds its videos")
        let runs = Grouping.runs(["a", "a", "b", "x", "a"]) { $0 == "x" ? nil : $0 == "a" ? 1 : 2 }
        check(runs.map(\.playlist) == [1, 2, nil, 1] && runs[0].items.map(\.number) == [1, 2] && runs[3].items.map(\.number) == [5],
              "queue headers group consecutive jobs and keep their FIFO numbers")

        // finished vs not started: position 0 or an unknown length is never "finished"
        check(WatchState(position: 0, duration: 100) == .notStarted, "position 0 is not finished")
        check(WatchState(position: 100, duration: nil) == .partial(0), "an unknown length is never finished")
        check(WatchState(position: 100, duration: 100) == .finished && WatchState(position: 96, duration: 100) == .finished,
              "the end, or the nearly-finished margin, is finished")
        check(WatchState(position: 50, duration: 100) == .partial(0.5), "part-way is part-watched")
        let t = Date()
        let w = { (s: WatchState, ago: Double) in Watch(state: s, updated: t.addingTimeInterval(-ago)) }
        let order: [Int64] = [1, 2, 3, 4]
        check(PlaylistOrder.resume(order: order, watch: [1: w(.finished, 0)], playable: [1, 2, 3, 4]) == 2, "after finishing 1, Continue is 2")
        check(PlaylistOrder.resume(order: order, watch: [1: w(.partial(0.4), 0)], playable: [1, 2]) == 1, "part-way resumes the same one")
        check(PlaylistOrder.resume(order: order, watch: [1: w(.notStarted, 0)], playable: [1, 2]) == 1, "position 0 doesn't skip an episode")
        check(PlaylistOrder.resume(order: order, watch: [2: w(.finished, 0), 3: w(.finished, 50)], playable: [1, 2, 3, 4]) == 4,
              "skips ones already finished")
        check(PlaylistOrder.resume(order: order, watch: [1: w(.finished, 0)], playable: [1, 3]) == 3, "skips ones not on this Mac")
        check(PlaylistOrder.resume(order: order, watch: [:], playable: [1]) == nil, "never played: Play All instead")
        try await db.savePosition("/tmp/ep1.mp4", position: 0, duration: 100)
        check(try await db.watchStates()[ep1]?.state == .notStarted, "a saved 0 reads as not started")
        try await db.savePosition("/tmp/ep1.mp4", position: 100, duration: 100)
        check(try await db.watchStates()[ep1]?.state == .finished, "the player's end-of-file save reads as finished")
        check(try await db.continueWatching().isEmpty, "finished episodes aren't in Continue watching")

        let jobs = try await db.count("jobs")
        try await db.deletePlaylist(series)
        let (videosLeft, jobsLeft) = (try await db.count("videos"), try await db.count("jobs"))
        check(videosLeft == 6 && jobsLeft == jobs, "deleting a playlist keeps its videos and their jobs")
    }

    /// 4.0: what an address is (from the URL alone) and where each navigation may go.
    private static func browserPolicy() {
        let c = { (s: String) in BrowserPolicy.classify(URL(string: s)) }
        check(c("https://www.youtube.com/") == .home && c("https://m.youtube.com") == .home, "YouTube home")
        check(c("https://www.youtube.com/watch?v=jNQXAC9IVRw&t=42s") == .video(id: "jNQXAC9IVRw", playlist: nil), "watch page with a time")
        check(c("https://www.youtube.com/watch?v=jNQXAC9IVRw&list=PLWxXeIVlFzP7-v_wb0uRl4uJLAtUdKVwy&index=3")
              == .video(id: "jNQXAC9IVRw", playlist: "PLWxXeIVlFzP7-v_wb0uRl4uJLAtUdKVwy"), "watch page inside a playlist")
        check(c("https://www.youtube.com/shorts/jNQXAC9IVRw") == .shorts(id: "jNQXAC9IVRw"), "Shorts")
        check(c("https://youtu.be/jNQXAC9IVRw") == .video(id: "jNQXAC9IVRw", playlist: nil), "short link")
        check(c("https://www.youtube.com/live/jNQXAC9IVRw").videoID == "jNQXAC9IVRw" && c("https://music.youtube.com/watch?v=jNQXAC9IVRw").videoID == "jNQXAC9IVRw",
              "live and music links")
        check(c("https://www.youtube.com/playlist?list=PLWxXeIVlFzP7-v_wb0uRl4uJLAtUdKVwy") == .playlist(id: "PLWxXeIVlFzP7-v_wb0uRl4uJLAtUdKVwy"), "playlist page")
        check(c("https://www.youtube.com/@HashtagClassic/videos") == .channel("@HashtagClassic") && c("https://www.youtube.com/channel/UC123") == .channel("UC123"),
              "channel pages")
        check(c("https://www.youtube.com/results?search_query=swift+ui") == .search("swift ui"), "search results")
        check(c("https://accounts.google.com/ServiceLogin") == .signIn && c("https://consent.youtube.com/m?continue=x") == .consent, "sign-in and consent")
        check(c("https://www.youtube.com/feed/subscriptions") == .otherYouTube && c("https://example.com/a") == .other(host: "example.com")
              && c("about:blank") == .blank, "other pages")
        let d = { (s: String, main: Bool) in BrowserPolicy.decide(URL(string: s)!, mainFrame: main) }
        check(d("https://www.youtube.com/watch?v=x", true) == .allow && d("https://youtu.be/x", true) == .allow, "YouTube stays in the app")
        check(d("https://accounts.google.com/v3/signin", true) == .allow && d("https://consent.youtube.com/save", true) == .allow
              && d("https://www.google.com/sorry/index", true) == .allow, "sign-in, consent and Google's traffic check stay")
        check(d("https://www.google.com/search?q=x", true) == .openExternally && d("https://example.com", true) == .openExternally,
              "other sites open in your browser")
        check(d("https://googleads.g.doubleclick.net/pagead/x", false) == .allow, "frames inside a page are the page's")
        check(d("file:///etc/hosts", true) == .cancel && d("vbx://x", true) == .cancel && d("mailto:a@b.c", true) == .openExternally,
              "no file:// or unknown schemes")
        check(BrowserPolicy.address("youtube.com/@x")?.absoluteString == "https://youtube.com/@x"
              && BrowserPolicy.address("swift tutorial")?.absoluteString == "https://www.youtube.com/results?search_query=swift%20tutorial",
              "address field: links and searches")
    }

    /// 4.0 Phase 1b: what the action bar knows and allows. Pure: no files, no network.
    private static func browserBar() {
        // technical checks from yt-dlp's metadata (a restriction check, never proof of download rights)
        let json = { (extra: String) in Data(#"{"availability":"public","live_status":"not_live","is_live":false,"age_limit":0,"channel_id":"UCabc","uploader_id":"@me","channel":"Me","formats":[{"has_drm":false}]\#(extra)}"#.utf8) }
        let pc = { (j: Data?, status: Int32, err: String?) in PlatformCheck.from(status: status, json: j, error: err) }
        check(pc(json(""), 0, nil) == .passed(channelID: "UCabc", handle: "@me", channel: "Me"), "a public video passes the technical check")
        check(pc(Data(#"{"availability":"public","live_status":"is_live","formats":[]}"#.utf8), 0, nil) != .passed(channelID: nil, handle: nil, channel: nil)
              && { if case .blocked = pc(Data(#"{"availability":"public","live_status":"is_live","formats":[]}"#.utf8), 0, nil) { true } else { false } }(),
              "live streams are unavailable")
        for (avail, what) in [("premium_only", "Premium"), ("subscriber_only", "members-only"), ("needs_auth", "sign-in"), ("private", "private")] {
            let r = pc(Data(#"{"availability":"\#(avail)","live_status":"not_live","formats":[]}"#.utf8), 0, nil)
            check({ if case .blocked = r { true } else { false } }(), "\(what) content is unavailable")
        }
        check({ if case .blocked = pc(Data(#"{"availability":"public","live_status":"not_live","age_limit":18,"formats":[]}"#.utf8), 0, nil) { true } else { false } }(),
              "age-restricted videos are unavailable")
        check({ if case .blocked = pc(Data(#"{"availability":"public","live_status":"not_live","formats":[{"has_drm":true}]}"#.utf8), 0, nil) { true } else { false } }(),
              "DRM-protected videos are unavailable")
        check({ if case .unknown = pc(Data(#"{"live_status":"not_live","formats":[]}"#.utf8), 0, nil) { true } else { false } }(),
              "missing availability is inconclusive, not a pass")
        check({ if case .unknown = pc(nil, 1, "ERROR: [youtube] x: Some network problem") { true } else { false } }()
              && { if case .blocked = pc(nil, 1, "ERROR: Sign in to confirm your age") { true } else { false } }()
              && { if case .unknown = pc(Data("{garbage".utf8), 0, nil) { true } else { false } }(),
              "failures are unknown (or the restriction they name), never a pass")

        // availability from real-looking records; `usable` stands in for "exists and isn't empty"
        let item = { (path: String, role: FileItem.Role) in FileItem(path: path, role: role, jobID: 1, videoID: 7, size: 10, date: Date()) }
        let usable: (FileItem) -> Bool = { !$0.path.contains("gone") && !$0.path.contains("empty") }
        let q = { (a: JobAction) in QueueItem(id: 1, videoID: 7, title: "t", action: a) }
        let mk = { (files: [FileItem], queue: [QueueItem], current: QueueItem?, summary: Bool) in
            VideoAvailability.make(inLibrary: true, files: files, usable: usable, queue: queue, current: current, failed: [], hasSummary: summary)
        }
        let here = mk([item("/x/v.mp4", .video)], [], nil, false)
        check(here.videoFile == "/x/v.mp4" && !here.videoMissing, "a playable video file on disk is offline")
        let gone = mk([item("/x/gone.mp4", .video)], [], nil, false)
        check(gone.videoFile == nil && gone.videoMissing, "a recorded file that's gone is missing, not downloaded")
        check(mk([item("/x/empty.mp4", .video)], [], nil, false).videoFile == nil, "an empty file never counts as downloaded")
        let copies = mk([item("/x/gone.mp4", .video), item("/x/v (2).mp4", .video)], [], nil, false)
        check(copies.videoFile == "/x/v (2).mp4" && !copies.videoMissing, "a second copy on disk still counts")
        let audioOnly = mk([item("/x/a.mp3", .audio)], [], nil, true)
        check(audioOnly.videoFile == nil && audioOnly.audioFile == "/x/a.mp3" && audioOnly.summarized, "audio + summary without video")
        check(mk([], [q(.video), q(.audio)], q(.video), false).video == .running && mk([], [q(.video)], nil, false).video == .queued
              && mk([], [q(.videoTranscript)], nil, false).video == .queued, "running, then queued (+ Transcript downloads count as video)")

        // what each slot shows, one order for all
        let ok = DownloadGate.Decision.allowed(DownloadAuthorization(basis: .writtenPermission, reference: "r", recorded: Date()))
        check(SlotState.video(here, nil) == .offline && SlotState.video(here, .blocked("x")) == .offline,
              "a video on this Mac shows Play Offline, whatever the checks say")
        check(SlotState.make(have: false, job: .running, missing: false, gate: nil) == .running
              && SlotState.make(have: false, job: .queued, missing: false, gate: ok) == .queued, "running, then queued")
        check(SlotState.make(have: false, job: .none, missing: false, gate: nil) == .checking, "checking while the check runs")
        check(SlotState.make(have: false, job: .none, missing: false, gate: .blocked("live")) == .unavailable("live")
              && SlotState.make(have: false, job: .failed, missing: false, gate: .unknown("?")) == .unknown("?"),
              "restrictions and failed checks come before retrying")
        check(SlotState.make(have: false, job: .failed, missing: false, gate: .needsDeclaration) == .authorizationRequired,
              "no declaration: authorization required, even to retry")
        check(SlotState.make(have: false, job: .failed, missing: true, gate: ok) == .retry
              && SlotState.make(have: false, job: .none, missing: true, gate: ok) == .downloadAgain
              && SlotState.make(have: false, job: .none, missing: false, gate: ok) == .ready, "retry, download again, download")
        check(SlotState.summary(audioOnly, nil) == .offline && SlotState.video(audioOnly, ok) == .ready,
              "summarized: Open Summary; audio only: the video can still be downloaded")

        // the gate: a technical pass and a declaration, both
        let passed = PlatformCheck.passed(channelID: "UCabc", handle: "@Me", channel: "Me")
        check(DownloadGate.decide(check: nil, authorization: nil) == nil
              && DownloadGate.decide(check: passed, authorization: nil) == .needsDeclaration
              && DownloadGate.decide(check: .blocked("x"), authorization: DownloadAuthorization(basis: .ownChannel, reference: nil, recorded: Date())) == .blocked("x"),
              "no download without both a passed check and a declaration")
        check(DownloadGate.channelMatches(passed, ownChannels: ["ucabc"]) && DownloadGate.channelMatches(passed, ownChannels: ["@me"])
              && !DownloadGate.channelMatches(passed, ownChannels: ["@someoneelse"]) && !DownloadGate.channelMatches(nil, ownChannels: ["@me"]),
              "own channel only when it matches a channel you entered")
        check(DownloadAuthorization(basis: .writtenPermission, reference: "x", recorded: Date()).label.contains("not independently verified")
              && DownloadAuthorization(basis: .ownChannel, reference: nil, recorded: Date()).label.contains("not independently verified"),
              "declarations are never labelled verified")

        // clicks: always the video the button showed, and only if it's still the tab's video
        check(BrowserActionOutcome.decide(clicked: "A", current: "B", slot: .ready) == .pageChanged, "a click for a video that's no longer shown does nothing")
        check(BrowserActionOutcome.decide(clicked: "A", current: "A", slot: .ready) == .queue(videoID: "A"), "a click queues the shown video")
        check(BrowserActionOutcome.decide(clicked: "A", current: "A", slot: .offline) == .alreadyHave
              && BrowserActionOutcome.decide(clicked: "A", current: "A", slot: .offline, anotherCopy: true) == .queue(videoID: "A"),
              "already here: no download unless you ask for another copy")
        check(BrowserActionOutcome.decide(clicked: "A", current: "A", slot: .queued) == .alreadyQueued
              && BrowserActionOutcome.decide(clicked: "A", current: "A", slot: .authorizationRequired) == .declare(videoID: "A")
              && BrowserActionOutcome.decide(clicked: "A", current: "A", slot: .unknown("?")) == .explain("?"),
              "queued, declaration and unknown never queue")
    }

    /// Phase 2: where tabs go, which one is active after a close, what a tab keeps, and clicks from another tab.
    private static func browserTabs() {
        let a = UUID(), b = UUID()
        // Safari's order: link tabs line up after their opener and the ones it already opened
        check(BrowserController.insertIndex(opener: 0, openerID: a, openers: [nil, nil]) == 1, "a link tab goes right after its opener")
        check(BrowserController.insertIndex(opener: 0, openerID: a, openers: [nil, a, a, nil]) == 3, "…after the opener's earlier link tabs")
        check(BrowserController.insertIndex(opener: 1, openerID: a, openers: [nil, nil, b, a]) == 2, "…but not after another tab's")
        check(BrowserController.insertIndex(opener: 5, openerID: a, openers: [nil]) == 1, "an opener that's gone: last")
        check(BrowserController.afterClose(1, count: 3) == 2 && BrowserController.afterClose(2, count: 3) == 1 && BrowserController.afterClose(0, count: 1) == nil,
              "closing selects the next tab, else the previous; the last tab has none")
        let home = BrowserPolicy.home, watch = URL(string: BrowserPolicy.watchURL("aqz-KE-bpKQ"))!, state = Data(repeating: 1, count: 100)
        let kept = BrowserController.keep(page: .video(id: "aqz-KE-bpKQ", playlist: nil), url: watch, state: state)
        check(kept.url == watch && kept.state == state, "a tab keeps its address and history")
        let signIn = BrowserController.keep(page: .signIn, url: URL(string: "https://accounts.google.com/x?continue=y")!, state: state)
        let consent = BrowserController.keep(page: .consent, url: URL(string: "https://consent.youtube.com/m?x")!, state: state)
        check(signIn.url == home && signIn.state == nil && consent.url == home && consent.state == nil,
              "sign-in and consent pages are kept as YouTube Home, never their tokens")
        check(BrowserController.keep(page: .home, url: home, state: Data(count: BrowserController.maxSavedState + 1)).state == nil,
              "history past the size limit is dropped (the address stays)")
        // ⌘-click / middle click: behind; with ⇧ in front; a plain or ⌥-click follows the link in the tab
        check(BrowserPolicy.newTab(command: true, shift: false, button: 1) == .background && BrowserPolicy.newTab(command: false, shift: false, button: 4) == .background,
              "⌘-click and middle click open a tab behind")
        check(BrowserPolicy.newTab(command: true, shift: true, button: 1) == .foreground, "⌘⇧-click opens it in front")
        check(BrowserPolicy.newTab(command: false, shift: false, button: 1) == nil && BrowserPolicy.newTab(command: false, shift: true, button: 1) == nil
              && BrowserPolicy.newTab(command: false, shift: false, button: 2) == nil, "plain, ⇧, ⌥ and right clicks stay in the tab")
        // a click from a tab that isn't active any more arrives with no current video: never queued
        check(BrowserActionOutcome.decide(clicked: "A", current: nil, slot: .ready) == .pageChanged, "a click from another tab does nothing")
    }

    /// Rapid navigation: a slow answer for video A must never appear as video B's.
    @MainActor private static func checkerRapidNavigation() async {
        let checker = AvailabilityChecker { id in
            try? await Task.sleep(for: .milliseconds(id == "A" ? 120 : 250))
            return .passed(channelID: id, handle: nil, channel: nil)
        }
        checker.settle = .milliseconds(10)
        checker.show("A", needed: true)
        try? await Task.sleep(for: .milliseconds(60))      // A's lookup is running
        checker.show("B", needed: true)                     // the user moved on
        try? await Task.sleep(for: .milliseconds(500))
        check(checker.current == "B" && checker.results["B"] == .passed(channelID: "B", handle: nil, channel: nil),
              "after A → B, the shown result is B's own")
        check(checker.results["A"] == nil || checker.results["A"] == .passed(channelID: "A", handle: nil, channel: nil),
              "A's answer, if kept, is stored only under A")
        // and if A's answer lands while B is shown (B already cached), B's is untouched
        checker.show("A", needed: true)
        checker.show("B", needed: true)
        try? await Task.sleep(for: .milliseconds(300))
        check(checker.results["B"] == .passed(channelID: "B", handle: nil, channel: nil), "a late answer never overwrites the current video's")
    }

    /// The additive migrations: one order, none skipped, safe to run again, and an existing v3 database keeps its rows.
    private static func migrations(_ dir: URL) async throws {
        let versions = Database.additive.map(\.version)
        check(versions == Array(4..<(4 + versions.count)) && Set(versions).count == versions.count, "migration numbers are contiguous and unique")
        let fresh = try Database(directory: dir.appendingPathComponent("fresh"))
        check(try await fresh.schemaVersion() == Database.latestVersion, "a new database starts at the latest version")
        // a 3.1 (v3) database: build one, then upgrade it
        let v3 = dir.appendingPathComponent("v3")
        do {
            let db = try Database(directory: v3)
            _ = try await db.enqueue(VideoRef.parse("https://youtu.be/jNQXAC9IVRw")!, action: .audio)
        }
        do {
            let raw = try SQLite(path: v3.appendingPathComponent("history.sqlite").path)
            try raw.exec("DROP TABLE authorizations; PRAGMA user_version = 3;")
        }
        let up = try Database(directory: v3)
        let backups = { ((try? FileManager.default.contentsOfDirectory(atPath: v3.appendingPathComponent("backups").path)) ?? []).filter { $0.hasPrefix("history-pre-v4-") } }
        let (upVersion, upCount) = (try await up.schemaVersion(), try await up.videos().count)
        check(upVersion == 4 && upCount == 1, "3.1 → v4 keeps its entries")
        check(backups().count == 1 && Database.isHealthy(v3.appendingPathComponent("backups/\(backups()[0])")), "a verified backup before v4")
        _ = try Database(directory: v3)
        check(backups().count == 1, "opening again changes nothing and makes no second backup")
        do {   // a step that finds its table already there (a half-applied upgrade) still completes
            let raw = try SQLite(path: v3.appendingPathComponent("history.sqlite").path)
            try raw.exec("PRAGMA user_version = 3;")
        }
        let again = try Database(directory: v3)
        check(try await again.schemaVersion() == 4, "re-running a step is harmless (CREATE … IF NOT EXISTS)")
        // declarations and your channels
        let a = DownloadAuthorization(basis: .writtenPermission, reference: "Email from the rights holder, 2026-10-22", recorded: Date())
        try await again.setAuthorization("youtube:jNQXAC9IVRw", a)
        let (stored, count) = (await again.authorization("youtube:jNQXAC9IVRw"), try await again.allAuthorizations().count)
        check(stored?.reference == a.reference && count == 1, "a declaration is stored by video key")
        try await again.setOwnChannels(["@me", "UCabc"])
        check(await again.ownChannels() == ["@me", "UCabc"], "your channels are kept in this profile's database")
    }

    private static func importer(_ dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = ["Me at the zoo - jawed (youtube).mp3": "a", "Me at the zoo - jawed (youtube).summary.md": "**TL;DR:** zoo",
                     "Me at the zoo - jawed (youtube).transcript.txt": "elephants", "Me at the zoo - jawed (240p, h264, youtube).mp4": "v",
                     "B talk.mp3": "b", "B talk.summary.md": "b summary", "notes.txt": "n", ".hidden.mp3": "h"]
        for (name, body) in files { try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let before = try files.keys.map { try Data(contentsOf: dir.appendingPathComponent($0)) }
        let db = try Database(directory: dir.appendingPathComponent("data"))

        let groups = Importer.scan(dir, known: [])
        check(groups.count == 2, "two videos found: \(groups.map(\.title))")
        let zoo = groups.first { $0.title == "Me at the zoo" }
        check(zoo?.channel == "jawed" && zoo?.platform == "YouTube" && zoo?.runs.count == 2, "zoo grouped with its video")
        let result = try await Importer.run(groups, db: db)
        check(result == (2, 3), "imported 2 videos, 3 jobs: \(result)")
        check(Importer.scan(dir, known: try await db.knownPaths()).isEmpty, "second scan finds nothing new")
        let after = try files.keys.map { try Data(contentsOf: dir.appendingPathComponent($0)) }
        check(before == after, "import never changes files")
        check(try await db.videos(filter: .summaries).count == 2, "imported summaries searchable")
        check(try await db.videos().allSatisfy { $0.url == nil }, "unknown URLs stay unknown")
    }
}
