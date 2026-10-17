// `VideoSummarizer --selftest`: checks the logic that must not break, on throwaway data. build.sh runs it.
import Foundation

enum SelfTest {
    nonisolated(unsafe) private static var failures: [String] = []
    nonisolated(unsafe) private static var passed = 0

    private static func check(_ ok: Bool, _ what: String, file: StaticString = #fileID, line: UInt = #line) {
        if ok { passed += 1 } else { failures.append("\(what)  (\(file):\(line))") }
    }

    static func runBlocking() -> Int32 {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { try await run() } catch { failures.append("threw: \(error)") }
            done.signal()
        }
        done.wait()
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
        let summarized = try await db.videos(filter: .summaries), downloaded = try await db.videos(filter: .downloads)
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
