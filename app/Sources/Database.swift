// History database. Every write goes through this actor (one writer, off the main thread);
// every multi-row change runs in a single transaction. Summaries are append-only.
import Foundation

actor Database {
    nonisolated let directory: URL?
    private let db: SQLite
    private(set) var recoveredCorruptFile: URL?

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (db, aside) = try Database.openChecked(directory.appendingPathComponent("history.sqlite"))
        self.db = db
        recoveredCorruptFile = aside
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
        try Database.migrate(db, backupDir: directory.appendingPathComponent("backups"))
    }

    /// Fallback when the real database can't be opened at all: the app still works, nothing is saved.
    init(inMemory: Void) throws {
        directory = nil
        db = try SQLite(path: ":memory:")
        try db.exec("PRAGMA foreign_keys=ON;")
        try Database.migrate(db)
    }

    /// Opens the file and runs quick_check. A corrupt file is moved aside (never deleted) and a fresh one started.
    static func openChecked(_ url: URL) throws -> (SQLite, URL?) {
        if let db = try? SQLite(path: url.path),
           (try? db.query("PRAGMA quick_check").first?.string("quick_check")) == "ok" {
            return (db, nil)
        }
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent("history.corrupt-\(Int(Date().timeIntervalSince1970)).sqlite")
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
            try FileManager.default.moveItem(atPath: url.path + suffix, toPath: aside.path + suffix)
        }
        return (try SQLite(path: url.path), aside)
    }

    /// Upgrades the schema step by step. Before changing an existing database it saves a verified copy to
    /// backups/history-pre-v<N>-<ms>.sqlite (a new name every time, never an existing file); if that copy can't be
    /// made, the upgrade doesn't run and the error stops the open, so the data on disk is left as it was.
    static func migrate(_ db: SQLite, backupDir: URL? = nil) throws {
        let version = try db.query("PRAGMA user_version").first?.int("user_version") ?? 0
        if version < 1 { try createV1(db) }
        if version < 2 {
            if version >= 1, let backupDir { try backupBeforeUpgrade(db, to: backupDir, label: "pre-v2") }
            try db.transaction {
                try db.exec("""
                ALTER TABLE videos ADD COLUMN thumbnail_path TEXT;
                ALTER TABLE jobs ADD COLUMN action TEXT;
                UPDATE jobs SET action = CASE kind WHEN 'audio' THEN 'audio' WHEN 'video' THEN 'video' ELSE 'summarize' END;
                CREATE INDEX jobs_queue ON jobs(status, id);
                CREATE TABLE playback(file_path TEXT PRIMARY KEY, position REAL NOT NULL, duration REAL, updated REAL NOT NULL);
                CREATE TABLE collections(id INTEGER PRIMARY KEY, name TEXT NOT NULL, source_url TEXT, created REAL NOT NULL);
                CREATE TABLE collection_items(
                  collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
                  video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
                  position REAL NOT NULL, added REAL NOT NULL,
                  PRIMARY KEY(collection_id, video_id));
                PRAGMA user_version = 2;
                """)
            }
        }
    }

    static func backupBeforeUpgrade(_ db: SQLite, to dir: URL, label: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent("history-\(label)-\(Int(Date().timeIntervalSince1970 * 1000)).sqlite")
        guard !FileManager.default.fileExists(atPath: copy.path) else { throw SQLiteError(message: "backup name already used") }
        try db.exec("VACUUM INTO '\(copy.path.replacingOccurrences(of: "'", with: "''"))'")
        guard isHealthy(copy) else {
            try? FileManager.default.removeItem(at: copy)
            throw SQLiteError(message: "couldn't make a verified backup before upgrading the history; nothing was changed")
        }
    }

    /// The original (version 1) schema. Kept verbatim so old databases and fresh ones upgrade the same way.
    static func createV1(_ db: SQLite) throws {
        try db.transaction {
            try db.exec("""
            CREATE TABLE videos(
              id INTEGER PRIMARY KEY,
              key TEXT NOT NULL UNIQUE,
              url TEXT, platform TEXT, title TEXT, channel TEXT, channel_followers INTEGER, thumbnail_url TEXT,
              duration REAL, upload_date TEXT,
              favorite INTEGER NOT NULL DEFAULT 0,
              first_processed REAL NOT NULL, last_processed REAL NOT NULL, last_opened REAL);
            CREATE TABLE jobs(
              id INTEGER PRIMARY KEY,
              video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
              kind TEXT NOT NULL, status TEXT NOT NULL, source TEXT NOT NULL,
              event_id TEXT UNIQUE,
              started REAL NOT NULL, finished REAL,
              file_path TEXT, file_size INTEGER, summary_path TEXT, transcript_path TEXT,
              summary TEXT, summary_language TEXT, summary_format TEXT,
              transcript TEXT, transcript_segments TEXT, transcript_language TEXT, error TEXT);
            CREATE INDEX jobs_video ON jobs(video_id, started);
            CREATE INDEX jobs_file ON jobs(file_path);
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
            PRAGMA user_version = 1;
            """)
        }
    }

    // MARK: queue

    /// Queues a job for a link. The video entry is created at once, so it shows up in history while it waits.
    func enqueue(_ ref: VideoRef, action: JobAction, format: String? = nil, language: String? = nil,
                 at: Date = Date()) throws -> (video: Int64, job: Int64) {
        try db.transaction {
            let video = try upsertVideo(key: ref.key, url: ref.url, platform: ref.platform, at: at,
                                        info: VideoInfo(thumbnail: ref.thumbnailFallback))
            guard let job = try insertJob(video, NewJob(kind: action.kind, status: .queued, source: .app, action: action, started: at,
                                                        summaryLanguage: language, summaryFormat: format)) else {
                throw SQLiteError(message: "could not queue job")
            }
            return (video, job)
        }
    }

    /// Queues a job on an existing entry (transcribe a local file, summarize a saved transcript, download again).
    func enqueue(videoID: Int64, action: JobAction, filePath: String? = nil, format: String? = nil,
                 language: String? = nil, at: Date = Date()) throws -> Int64 {
        try db.transaction {
            guard let job = try insertJob(videoID, NewJob(kind: action.kind, status: .queued, source: .app, action: action, started: at,
                                                          filePath: filePath, summaryLanguage: language, summaryFormat: format)) else {
                throw SQLiteError(message: "could not queue job")
            }
            return job
        }
    }

    /// The oldest queued job that can run now. Without internet only on-device work qualifies.
    func nextQueued(networkAvailable: Bool) throws -> Job? {
        try db.query("""
            SELECT * FROM jobs WHERE status='queued' AND (?1 OR action='transcribe') ORDER BY id LIMIT 1
            """, [networkAvailable]).first.map(Database.job)
    }

    func queuedJobs() throws -> [(job: Job, title: String?)] {
        try db.query("""
            SELECT j.*, v.title AS video_title FROM jobs j JOIN videos v ON v.id = j.video_id
            WHERE j.status='queued' ORDER BY j.id
            """).map { (Database.job($0), $0.string("video_title")) }
    }

    /// queued → running; false if the job was removed from the queue meanwhile.
    func markRunning(_ id: Int64, at: Date = Date()) throws -> Bool {
        try db.run("UPDATE jobs SET status='running', started=? WHERE id=? AND status='queued'", [at, id]) == 1
    }

    func removeQueued(_ id: Int64) throws {
        try db.run("UPDATE jobs SET status='cancelled', finished=?, error='Removed from the queue' WHERE id=? AND status='queued'",
                   [Date(), id])
    }

    @discardableResult
    func clearQueue() throws -> Int {
        try db.run("UPDATE jobs SET status='cancelled', finished=?, error='Removed from the queue' WHERE status='queued'", [Date()])
    }

    // MARK: my playlists (collections)

    func createPlaylist(_ name: String, sourceURL: String? = nil) throws -> Int64 {
        try db.run("INSERT INTO collections(name, source_url, created) VALUES(?, ?, ?)", [name, sourceURL, Date()])
        return db.lastInsertRowID
    }

    func renamePlaylist(_ id: Int64, _ name: String) throws { try db.run("UPDATE collections SET name=? WHERE id=?", [name, id]) }

    /// Deletes the playlist only; its videos stay in history and their files stay on disk.
    func deletePlaylist(_ id: Int64) throws { try db.run("DELETE FROM collections WHERE id=?", [id]) }

    /// Appends videos at the end, skipping ones already in the playlist.
    func addToPlaylist(_ id: Int64, videoIDs: [Int64]) throws {
        try db.transaction {
            var next = try db.query("SELECT coalesce(max(position), -1) + 1 AS n FROM collection_items WHERE collection_id=?", [id])
                .first?.double("n") ?? 0
            for v in videoIDs {
                let added = try db.run("""
                    INSERT INTO collection_items(collection_id, video_id, position, added) VALUES(?, ?, ?, ?)
                    ON CONFLICT(collection_id, video_id) DO NOTHING
                    """, [id, v, next, Date()])
                if added == 1 { next += 1 }
            }
        }
    }

    func removeFromPlaylist(_ id: Int64, videoID: Int64) throws {
        try db.run("DELETE FROM collection_items WHERE collection_id=? AND video_id=?", [id, videoID])
    }

    /// Saves a new order (the full list of the playlist's video ids, first to last).
    func reorderPlaylist(_ id: Int64, videoIDs: [Int64]) throws {
        try db.transaction {
            for (i, v) in videoIDs.enumerated() {
                try db.run("UPDATE collection_items SET position=? WHERE collection_id=? AND video_id=?", [Double(i), id, v])
            }
        }
    }

    func playlists() throws -> [PlaylistSummary] {
        try db.query("""
            SELECT c.id, c.name, c.source_url, count(i.video_id) AS n, coalesce(sum(v.duration), 0) AS total
            FROM collections c LEFT JOIN collection_items i ON i.collection_id = c.id
            LEFT JOIN videos v ON v.id = i.video_id
            GROUP BY c.id ORDER BY c.created DESC, c.id DESC
            """).map { PlaylistSummary(id: $0.int64("id") ?? 0, name: $0.string("name") ?? "Playlist", sourceURL: $0.string("source_url"),
                                      count: $0.int("n") ?? 0, totalDuration: $0.double("total") ?? 0) }
    }

    func playlistIDs(containing videoID: Int64) throws -> Set<Int64> {
        Set(try db.query("SELECT collection_id FROM collection_items WHERE video_id=?", [videoID]).compactMap { $0.int64("collection_id") })
    }

    /// Queues the chosen playlist entries in one transaction: an entry per video (existing ones are reused), a queued
    /// job each, and optionally a new playlist with them in the original order.
    func importPlaylist(_ entries: [PlaylistEntry], action: JobAction, format: String?, language: String?,
                        playlistName: String?, sourceURL: String?, at: Date = Date()) throws -> (playlist: Int64?, jobs: Int) {
        try db.transaction {
            var playlist: Int64?
            if let playlistName {
                try db.run("INSERT INTO collections(name, source_url, created) VALUES(?, ?, ?)", [playlistName, sourceURL, at])
                playlist = db.lastInsertRowID
            }
            var jobs = 0
            for (i, e) in entries.enumerated() {
                let video = try upsertVideo(key: "youtube:\(e.id)", url: e.url, platform: "YouTube", at: at,
                                            info: VideoInfo(title: e.title, channel: e.channel,
                                                            thumbnail: "https://i.ytimg.com/vi/\(e.id)/mqdefault.jpg"))
                if let d = e.duration { try db.run("UPDATE videos SET duration = coalesce(duration, ?) WHERE id=?", [d, video]) }
                if try insertJob(video, NewJob(kind: action.kind, status: .queued, source: .app, action: action,
                                               started: at.addingTimeInterval(Double(i) / 1000),
                                               summaryLanguage: language, summaryFormat: format)) != nil { jobs += 1 }
                if let playlist {
                    try db.run("INSERT INTO collection_items(collection_id, video_id, position, added) VALUES(?, ?, ?, ?) ON CONFLICT DO NOTHING",
                               [playlist, video, Double(i), at])
                }
            }
            return (playlist, jobs)
        }
    }

    // MARK: playback and thumbnails

    func savePosition(_ path: String, position: Double, duration: Double?) throws {
        try db.run("""
            INSERT INTO playback(file_path, position, duration, updated) VALUES(?, ?, ?, ?)
            ON CONFLICT(file_path) DO UPDATE SET position=excluded.position, duration=excluded.duration, updated=excluded.updated
            """, [path, position, duration, Date()])
    }

    func position(_ path: String) -> Double? {
        (try? db.query("SELECT position FROM playback WHERE file_path=?", [path]))?.first?.double("position")
    }

    func setThumbnailPath(_ videoID: Int64, _ path: String?) throws {
        try db.run("UPDATE videos SET thumbnail_path=? WHERE id=?", [path, videoID])
    }

    // MARK: writes

    func startJob(_ ref: VideoRef, kind: JobKind, source: JobSource, at: Date = Date()) throws -> (video: Int64, job: Int64) {
        try db.transaction {
            let video = try upsertVideo(key: ref.key, url: ref.url, platform: ref.platform, at: at,
                                        info: VideoInfo(thumbnail: ref.thumbnailFallback))
            guard let job = try insertJob(video, NewJob(kind: kind, status: .running, source: source, started: at)) else {
                throw SQLiteError(message: "could not create job")
            }
            return (video, job)
        }
    }

    /// A new job on an existing video (regenerated summaries).
    func startJob(videoID: Int64, kind: JobKind, source: JobSource, at: Date = Date()) throws -> Int64 {
        try db.transaction {
            guard let job = try insertJob(videoID, NewJob(kind: kind, status: .running, source: source, started: at)) else {
                throw SQLiteError(message: "could not create job")
            }
            return job
        }
    }

    func finishJob(_ id: Int64, videoID: Int64, _ j: NewJob, at: Date = Date()) throws {
        try db.transaction {
            try db.run("""
                UPDATE jobs SET status=?, finished=?, file_path=?, file_size=?, summary_path=?, transcript_path=?,
                  summary=?, summary_language=?, summary_format=?, transcript=?, transcript_segments=?,
                  transcript_language=?, error=? WHERE id=?
                """, [j.status.rawValue, at, j.filePath, j.fileSize, j.summaryPath, j.transcriptPath,
                      j.summary, j.summaryLanguage, j.summaryFormat, j.transcript, j.segmentsJSON,
                      j.transcriptLanguage, j.error, id])
            if j.status == .succeeded {
                try db.run("UPDATE videos SET last_processed=? WHERE id=?", [at, videoID])
            }
        }
    }

    /// Records a job that already finished elsewhere (Raycast, import). Returns nil when its event was seen before.
    @discardableResult
    func recordCompleted(key: String, url: String?, platform: String?, info: VideoInfo?, job: NewJob) throws -> (video: Int64, job: Int64)? {
        try db.transaction {
            if let e = job.eventID, try !db.query("SELECT 1 FROM jobs WHERE event_id=?", [e]).isEmpty { return nil }
            let video = try upsertVideo(key: key, url: url, platform: platform, at: job.finished ?? job.started, info: info)
            guard let id = try insertJob(video, job) else { return nil }
            return (video, id)
        }
    }

    /// `override`: yt-dlp metadata replaces guesses. Otherwise values only fill fields that are still empty.
    func applyInfo(_ videoID: Int64, _ i: VideoInfo, override: Bool) throws {
        let pick = override ? "coalesce(?, %@)" : "coalesce(%@, ?)"
        let cols = ["title", "channel", "channel_followers", "thumbnail_url", "duration", "upload_date", "platform"]
        let sets = cols.map { "\($0) = " + String(format: pick, $0) }.joined(separator: ", ")
        try db.run("UPDATE videos SET \(sets) WHERE id=?",
                   [i.title?.nilIfBlank, i.channel?.nilIfBlank, i.followers, i.thumbnail, i.duration, i.uploadDate, i.platform, videoID])
    }

    /// Imported (URL-less) entries for the same video are folded into the real one once title and channel are known.
    func mergeImportedDuplicates(into videoID: Int64) throws {
        try db.transaction {
            guard let v = try db.query("SELECT title, channel FROM videos WHERE id=?", [videoID]).first,
                  let title = v.string("title"), let channel = v.string("channel") else { return }
            let dups = try db.query("""
                SELECT id, favorite FROM videos WHERE key LIKE 'file:%' AND id != ?
                  AND title = ? COLLATE NOCASE AND channel = ? COLLATE NOCASE
                """, [videoID, title, channel])
            for d in dups {
                guard let dupID = d.int64("id") else { continue }
                try db.run("UPDATE jobs SET video_id=? WHERE video_id=?", [videoID, dupID])
                if d.bool("favorite") { try db.run("UPDATE videos SET favorite=1 WHERE id=?", [videoID]) }
                try db.run("""
                    UPDATE videos SET first_processed = min(first_processed, (SELECT first_processed FROM videos WHERE id=?))
                    WHERE id=?
                    """, [dupID, videoID])
                try db.run("DELETE FROM videos WHERE id=?", [dupID])
            }
        }
    }

    func setFavorite(_ id: Int64, _ on: Bool) throws { try db.run("UPDATE videos SET favorite=? WHERE id=?", [on, id]) }
    func touchOpened(_ id: Int64) throws { try db.run("UPDATE videos SET last_opened=? WHERE id=?", [Date(), id]) }
    /// Removes records only; files on disk are never touched.
    func deleteVideo(_ id: Int64) throws { try db.run("DELETE FROM videos WHERE id=?", [id]) }
    func deleteAll() throws { _ = try db.transaction { try db.run("DELETE FROM videos") } }

    /// Jobs left `running` by a crash or force-quit.
    @discardableResult
    func recoverInterrupted() throws -> Int {
        try db.run("UPDATE jobs SET status='interrupted', finished=?, error='The app closed while this was running.' WHERE status='running'",
                   [Date()])
    }

    @discardableResult
    func prune(olderThanDays days: Int, now: Date = Date()) throws -> Int {
        guard days > 0 else { return 0 }
        return try db.run("DELETE FROM videos WHERE favorite=0 AND last_processed < ?",
                          [now.addingTimeInterval(-Double(days) * 86_400)])
    }

    func meta(_ key: String) -> String? {
        (try? db.query("SELECT value FROM meta WHERE key=?", [key]))?.first?.string("value")
    }

    func setMeta(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value])
    }

    // MARK: reads

    func videos(filter: HistoryFilter = .all, sort: HistorySort = .recent, search: String = "",
                limit: Int? = nil, onlyID: Int64? = nil, playlist: Int64? = nil) throws -> [Video] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = term.isEmpty ? "" : "%" + term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
        let where_ = switch filter {
        case .all: "1"
        case .summaries: "has_summary"
        case .audio: "has_audio"
        case .downloads: "has_video"
        case .onMac: "1"            // file existence is checked by HistoryStore, not SQL
        case .favorites: "favorite = 1"
        }
        let sortOrder = switch sort {
        case .recent: "last_processed DESC"
        case .oldest: "first_processed ASC"
        case .duration: "duration IS NULL, duration DESC"
        case .title: "title IS NULL, title COLLATE NOCASE ASC"
        }
        // a playlist lists its videos in their saved order
        let order = playlist.map { "(SELECT position FROM collection_items WHERE collection_id = \($0) AND video_id = id)" } ?? sortOrder
        let rows = try db.query("""
            SELECT * FROM (
              SELECT v.*,
                EXISTS(SELECT 1 FROM jobs j WHERE j.video_id=v.id AND j.status='succeeded' AND j.kind='summary') AS has_summary,
                EXISTS(SELECT 1 FROM jobs j WHERE j.video_id=v.id AND j.status='succeeded'
                       AND (j.kind='audio' OR j.file_path LIKE '%.mp3')) AS has_audio,
                EXISTS(SELECT 1 FROM jobs j WHERE j.video_id=v.id AND j.status='succeeded' AND j.kind='video') AS has_video,
                (SELECT j.status FROM jobs j WHERE j.video_id=v.id ORDER BY j.started DESC, j.id DESC LIMIT 1) AS latest_status,
                (SELECT j.kind FROM jobs j WHERE j.video_id=v.id ORDER BY j.started DESC, j.id DESC LIMIT 1) AS latest_kind,
                (SELECT j.transcript_language FROM jobs j WHERE j.video_id=v.id AND j.transcript_language IS NOT NULL
                   ORDER BY j.started DESC LIMIT 1) AS language
              FROM videos v
              WHERE (?1 IS NULL OR v.id = ?1)
                AND (?3 IS NULL OR v.id IN (SELECT video_id FROM collection_items WHERE collection_id = ?3))
                AND (?2 = '' OR v.title LIKE ?2 ESCAPE '\\' OR v.channel LIKE ?2 ESCAPE '\\' OR v.url LIKE ?2 ESCAPE '\\'
                     OR EXISTS(SELECT 1 FROM jobs j WHERE j.video_id=v.id
                               AND (j.summary LIKE ?2 ESCAPE '\\' OR j.transcript LIKE ?2 ESCAPE '\\')))
            ) WHERE \(where_) ORDER BY \(order)\(limit.map { " LIMIT \($0)" } ?? "")
            """, [onlyID, pattern, playlist])
        return rows.map(Database.video)
    }

    func video(_ id: Int64) throws -> Video? { try videos(onlyID: id).first }

    func jobs(for videoID: Int64) throws -> [Job] {
        try db.query("SELECT * FROM jobs WHERE video_id=? ORDER BY started DESC, id DESC", [videoID]).map(Database.job)
    }

    /// Every file a successful job produced, newest first, one entry per path.
    func files() throws -> [FileItem] {
        let rows = try db.query("""
            SELECT j.id, j.video_id, j.file_path, j.file_size, j.summary_path, j.transcript_path,
                   coalesce(j.finished, j.started) AS at, v.title AS video_title
            FROM jobs j JOIN videos v ON v.id = j.video_id
            WHERE j.status='succeeded' AND (j.file_path IS NOT NULL OR j.summary_path IS NOT NULL OR j.transcript_path IS NOT NULL)
            ORDER BY at DESC, j.id DESC
            """)
        var seen = Set<String>(), items: [FileItem] = []
        for r in rows {
            guard let job = r.int64("id"), let video = r.int64("video_id") else { continue }
            let date = r.date("at") ?? Date()
            let entries: [(String?, FileItem.Role?, Int?)] = [
                (r.string("file_path"), r.string("file_path").map(FileItem.mediaRole), r.int("file_size")),
                (r.string("summary_path"), .summary, nil),
                (r.string("transcript_path"), .transcript, nil),
            ]
            for case let (path?, role?, size) in entries where seen.insert(path).inserted {
                items.append(FileItem(path: path, role: role, jobID: job, videoID: video, size: size,
                                      date: date, videoTitle: r.string("video_title")))
            }
        }
        return items
    }

    /// Every path any job recorded, so imports can skip files the history already knows.
    func knownPaths() throws -> Set<String> {
        var out = Set<String>()
        for r in try db.query("SELECT file_path, summary_path, transcript_path FROM jobs") {
            for k in ["file_path", "summary_path", "transcript_path"] { if let p = r.string(k) { out.insert(p) } }
        }
        return out
    }

    /// An existing URL-backed video with the same title and channel, so imported files join it instead of duplicating it.
    func matchingVideoKey(title: String, channel: String?) throws -> String? {
        guard let channel else { return nil }
        return try db.query("""
            SELECT key FROM videos WHERE key NOT LIKE 'file:%' AND title = ? COLLATE NOCASE AND channel = ? COLLATE NOCASE LIMIT 1
            """, [title, channel]).first?.string("key")
    }

    func stats() throws -> Stats {
        guard let r = try db.query("""
            SELECT
              (SELECT count(DISTINCT video_id) FROM jobs WHERE status='succeeded') AS videos,
              (SELECT coalesce(sum(duration), 0) FROM videos WHERE duration IS NOT NULL
                 AND id IN (SELECT video_id FROM jobs WHERE kind='summary' AND status='succeeded')) AS watch,
              (SELECT count(*) FROM jobs WHERE kind='summary' AND status='succeeded') AS summaries,
              (SELECT count(*) FROM jobs WHERE kind='video' AND status='succeeded') AS downloads
            """).first else { return Stats() }
        return Stats(videos: r.int("videos") ?? 0, watchSeconds: r.double("watch") ?? 0,
                     summaries: r.int("summaries") ?? 0, downloads: r.int("downloads") ?? 0)
    }

    func count(_ table: String) throws -> Int {
        try db.query("SELECT count(*) AS n FROM \(table)").first?.int("n") ?? 0
    }

    func schemaVersion() throws -> Int { try db.query("PRAGMA user_version").first?.int("user_version") ?? 0 }

    func quickCheck() throws -> String { try db.query("PRAGMA quick_check").first?.string("quick_check") ?? "?" }

    // MARK: backups

    /// Daily copy of the history. VACUUM INTO refuses an existing target, so it always writes a fresh temp file,
    /// verifies it, and only then rotates: backup → backup.prev, temp → backup. A bad copy never replaces a good one.
    @discardableResult
    func backupIfDue(now: Date = Date(), force: Bool = false,
                     verify: (URL) -> Bool = Database.isHealthy) throws -> Bool {
        guard let directory else { return false }
        let last = meta("last_backup").flatMap(Double.init) ?? 0
        guard force || now.timeIntervalSince1970 - last > 86_400 else { return false }

        let fm = FileManager.default
        let dir = directory.appendingPathComponent("backups")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // leftovers from an interrupted backup are our own temp copies
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix("history-") && name.hasSuffix(".tmp") {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
        let tmp = dir.appendingPathComponent("history-\(Int(now.timeIntervalSince1970 * 1000)).tmp")
        try db.exec("VACUUM INTO '\(tmp.path.replacingOccurrences(of: "'", with: "''"))'")
        guard verify(tmp) else {
            try? fm.removeItem(at: tmp)
            throw SQLiteError(message: "backup copy failed its integrity check; existing backups were kept")
        }
        let current = dir.appendingPathComponent("history-backup.sqlite")
        let previous = dir.appendingPathComponent("history-backup.prev.sqlite")
        if fm.fileExists(atPath: current.path), rename(current.path, previous.path) != 0 {
            try? fm.removeItem(at: tmp)
            throw SQLiteError(message: "could not rotate backups (\(String(cString: strerror(errno))))")
        }
        guard rename(tmp.path, current.path) == 0 else {
            throw SQLiteError(message: "could not install backup (\(String(cString: strerror(errno))))")
        }
        try setMeta("last_backup", String(now.timeIntervalSince1970))
        return true
    }

    nonisolated static func isHealthy(_ url: URL) -> Bool {
        guard let copy = try? SQLite(path: url.path, readOnly: true) else { return false }
        return (try? copy.query("PRAGMA quick_check").first?.string("quick_check")) == "ok"
    }

    // MARK: helpers

    private func upsertVideo(key: String, url: String?, platform: String?, at: Date, info: VideoInfo?) throws -> Int64 {
        let rows = try db.query("""
            INSERT INTO videos(key, url, platform, title, channel, thumbnail_url, first_processed, last_processed)
            VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)
            ON CONFLICT(key) DO UPDATE SET
              last_processed = max(last_processed, excluded.last_processed),
              url = coalesce(videos.url, excluded.url),
              platform = coalesce(videos.platform, excluded.platform),
              title = coalesce(videos.title, excluded.title),
              channel = coalesce(videos.channel, excluded.channel),
              thumbnail_url = coalesce(videos.thumbnail_url, excluded.thumbnail_url)
            RETURNING id
            """, [key, url, platform, info?.title?.nilIfBlank, info?.channel?.nilIfBlank, info?.thumbnail, at])
        guard let id = rows.first?.int64("id") else { throw SQLiteError(message: "upsert returned no id") }
        return id
    }

    /// Returns nil only when the event id was already recorded.
    private func insertJob(_ videoID: Int64, _ j: NewJob) throws -> Int64? {
        let changed = try db.run("""
            INSERT INTO jobs(video_id, kind, action, status, source, event_id, started, finished, file_path, file_size,
              summary_path, transcript_path, summary, summary_language, summary_format, transcript,
              transcript_segments, transcript_language, error)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(event_id) DO NOTHING
            """, [videoID, j.kind.rawValue, (j.action ?? JobAction.from(kind: j.kind)).rawValue, j.status.rawValue, j.source.rawValue, j.eventID, j.started, j.finished,
                  j.filePath, j.fileSize, j.summaryPath, j.transcriptPath, j.summary, j.summaryLanguage,
                  j.summaryFormat, j.transcript, j.segmentsJSON, j.transcriptLanguage, j.error])
        return changed == 1 ? db.lastInsertRowID : nil
    }

    private static func video(_ r: Row) -> Video {
        Video(id: r.int64("id") ?? 0, key: r.string("key") ?? "", url: r.string("url"), platform: r.string("platform"),
              title: r.string("title"), channel: r.string("channel"), channelFollowers: r.int("channel_followers"),
              thumbnailURL: r.string("thumbnail_url"), thumbnailPath: r.string("thumbnail_path"), duration: r.double("duration"), uploadDate: r.string("upload_date"),
              favorite: r.bool("favorite"), firstProcessed: r.date("first_processed") ?? Date(),
              lastProcessed: r.date("last_processed") ?? Date(), lastOpened: r.date("last_opened"),
              hasSummary: r.bool("has_summary"), hasAudio: r.bool("has_audio"), hasVideo: r.bool("has_video"),
              latestStatus: r.string("latest_status").flatMap(JobStatus.init), latestKind: r.string("latest_kind").flatMap(JobKind.init),
              language: r.string("language"))
    }

    private static func job(_ r: Row) -> Job {
        let kind = JobKind(rawValue: r.string("kind") ?? "") ?? .summary
        return Job(id: r.int64("id") ?? 0, videoID: r.int64("video_id") ?? 0, kind: kind,
            action: r.string("action").flatMap(JobAction.init) ?? JobAction.from(kind: kind),
            status: JobStatus(rawValue: r.string("status") ?? "") ?? .failed, source: JobSource(rawValue: r.string("source") ?? "") ?? .app,
            eventID: r.string("event_id"), started: r.date("started") ?? Date(), finished: r.date("finished"),
            filePath: r.string("file_path"), fileSize: r.int("file_size"), summaryPath: r.string("summary_path"),
            transcriptPath: r.string("transcript_path"), summary: r.string("summary"), summaryLanguage: r.string("summary_language"),
            summaryFormat: r.string("summary_format"), transcript: r.string("transcript"), segmentsJSON: r.string("transcript_segments"),
            transcriptLanguage: r.string("transcript_language"), error: r.string("error"))
    }
}
