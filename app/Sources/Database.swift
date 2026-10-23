// History database. Every write goes through this actor (one writer, off the main thread);
// every multi-row change runs in a single transaction. Summaries are append-only.
import Foundation

actor Database {
    /// 4.0 Phase 5: asked before every queued job (action, video key): why this build refuses it, or nil. The app sets
    /// it to AppSettings.queueRefusal (only the RC refuses anything); self-tests set it only where they test it.
    nonisolated(unsafe) static var queueRule: ((JobAction, String) -> String?)?
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
    /// Additive steps after v3, numbered in the order they were written: every number used once, none skipped, so a
    /// database at any version gets exactly the steps it lacks (v4 authorizations, v5 Watch Later, v6 job options). Each only
    /// creates what doesn't exist yet, inside a transaction, after a verified backup of an existing database.
    static let additive: [(version: Int, label: String, sql: String)] = [
        (4, "authorizations", """
            CREATE TABLE IF NOT EXISTS authorizations(
              video_key TEXT PRIMARY KEY, basis TEXT NOT NULL, reference TEXT, recorded REAL NOT NULL);
            """),
        // 4.0 Phase 3: videos you saved to watch later, apart from the library (no link to `videos`: removing a library
        // entry or clearing the history leaves them); one row per video, by the same key the library uses
        (5, "watch later", """
            CREATE TABLE IF NOT EXISTS watch_later(
              video_key TEXT PRIMARY KEY, url TEXT NOT NULL, title TEXT, channel TEXT, duration REAL,
              thumbnail_url TEXT, added REAL NOT NULL);
            """),
        // 4.0 Phase 4: what a prepared download was queued with (its quality and size estimate) and how often low disk
        // space stopped it; its own table so the step stays safe to re-run, and a job's options go with it
        (6, "job options", """
            CREATE TABLE IF NOT EXISTS job_options(
              job_id INTEGER PRIMARY KEY REFERENCES jobs(id) ON DELETE CASCADE,
              video_quality TEXT, estimated_bytes INTEGER, size_kind TEXT, low_space_stops INTEGER NOT NULL DEFAULT 0);
            """),
    ]
    static var latestVersion: Int { additive.last?.version ?? 3 }

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
        if version < 3 {
            // a v1 database was just backed up as pre-v2, so only an existing v2 one needs its own copy
            if version >= 2, let backupDir { try backupBeforeUpgrade(db, to: backupDir, label: "pre-v3") }
            try db.transaction {
                try db.exec("""
                ALTER TABLE videos ADD COLUMN description TEXT;
                ALTER TABLE videos ADD COLUMN tags TEXT;
                PRAGMA user_version = 3;
                """)
            }
        }
        // an existing v3+ database gets one verified copy before its first additive step (older ones were copied above)
        var backedUp = version < 3
        for step in additive where version < step.version {
            if !backedUp, let backupDir { try backupBeforeUpgrade(db, to: backupDir, label: "pre-v\(step.version)") }
            backedUp = true
            try db.transaction { try db.exec(step.sql + "\nPRAGMA user_version = \(step.version);") }
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
    func enqueue(_ ref: VideoRef, action: JobAction, format: String? = nil, language: String? = nil, options: JobOptions? = nil,
                 at: Date = Date()) throws -> (video: Int64, job: Int64) {
        try db.transaction {
            let video = try upsertVideo(key: ref.key, url: ref.url, platform: ref.platform, at: at,
                                        info: VideoInfo(thumbnail: ref.thumbnailFallback))
            guard let job = try insertJob(video, NewJob(kind: action.kind, status: .queued, source: .app, action: action, started: at,
                                                        summaryLanguage: language, summaryFormat: format)) else {
                throw AlreadyQueued(videoID: video)
            }
            try setOptions(job, options)
            return (video, job)
        }
    }

    /// Queues a job on an existing entry (transcribe a local file, summarize a saved transcript, download again).
    func enqueue(videoID: Int64, action: JobAction, filePath: String? = nil, format: String? = nil,
                 language: String? = nil, options: JobOptions? = nil, at: Date = Date()) throws -> Int64 {
        try db.transaction {
            guard let job = try insertJob(videoID, NewJob(kind: action.kind, status: .queued, source: .app, action: action, started: at,
                                                          filePath: filePath, summaryLanguage: language, summaryFormat: format)) else {
                throw AlreadyQueued(videoID: videoID)
            }
            try setOptions(job, options)
            return job
        }
    }

    private func setOptions(_ job: Int64, _ o: JobOptions?) throws {
        guard let o else { return }
        try db.run("INSERT INTO job_options(job_id, video_quality, estimated_bytes, size_kind) VALUES(?, ?, ?, ?)",
                   [job, o.quality, o.estimatedBytes, o.sizeKind.rawValue])
    }

    /// The oldest queued job that can run now. Without internet only on-device work qualifies; `downloadsAllowed`
    /// false (Wi-Fi or Ethernet only, on another network) holds back everything that downloads media.
    func nextQueued(networkAvailable: Bool, downloadsAllowed: Bool? = nil) throws -> Job? {
        try db.query("""
            SELECT j.*, o.video_quality, o.estimated_bytes, o.size_kind, o.low_space_stops
            FROM jobs j LEFT JOIN job_options o ON o.job_id = j.id
            WHERE j.status='queued' AND (j.action='transcribe' OR (?1 AND j.action='resummarize')
                                         OR (?2 AND j.action NOT IN ('transcribe', 'resummarize')))
            ORDER BY j.id LIMIT 1
            """, [networkAvailable, downloadsAllowed ?? networkAvailable]).first.map(Database.job)
    }

    func queuedJobs() throws -> [(job: Job, title: String?)] {
        try db.query("""
            SELECT j.*, o.video_quality, o.estimated_bytes, o.size_kind, o.low_space_stops, v.title AS video_title
            FROM jobs j JOIN videos v ON v.id = j.video_id LEFT JOIN job_options o ON o.job_id = j.id
            WHERE j.status='queued' ORDER BY j.id
            """).map { (Database.job($0), $0.string("video_title")) }
    }

    /// Low disk space stopped this running job: counted, and back in the queue the first time (the queue pauses, so it
    /// isn't retried until you resume). Returns how many times it has been stopped; from the 2nd, the caller fails it.
    func lowSpaceStop(_ id: Int64) throws -> Int {
        try db.transaction {
            try db.run("INSERT OR IGNORE INTO job_options(job_id) VALUES(?)", [id])
            try db.run("UPDATE job_options SET low_space_stops = low_space_stops + 1 WHERE job_id=?", [id])
            let stops = try db.query("SELECT low_space_stops FROM job_options WHERE job_id=?", [id]).first?.int("low_space_stops") ?? 1
            if stops < 2 { try db.run("UPDATE jobs SET status='queued' WHERE id=? AND status='running'", [id]) }
            return stops
        }
    }

    /// Failed or interrupted jobs that nothing newer of the same kind has replaced (a retry, or a later success).
    func failedJobs(limit: Int = 20) throws -> [(job: Job, title: String?)] {
        try db.query("""
            SELECT j.*, v.title AS video_title FROM jobs j JOIN videos v ON v.id = j.video_id
            WHERE j.status IN ('failed', 'interrupted')
              AND NOT EXISTS(SELECT 1 FROM jobs k WHERE k.video_id = j.video_id AND k.kind = j.kind AND k.id > j.id)
            ORDER BY j.id DESC LIMIT ?
            """, [limit]).map { (Database.job($0), $0.string("video_title")) }
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
            SELECT c.id, c.name, c.source_url, count(i.video_id) AS n, coalesce(sum(v.duration), 0) AS total,
              (SELECT f.thumbnail_path FROM collection_items fi JOIN videos f ON f.id = fi.video_id
                 WHERE fi.collection_id = c.id ORDER BY fi.position LIMIT 1) AS cover_path,
              (SELECT f.thumbnail_url FROM collection_items fi JOIN videos f ON f.id = fi.video_id
                 WHERE fi.collection_id = c.id ORDER BY fi.position LIMIT 1) AS cover_url
            FROM collections c LEFT JOIN collection_items i ON i.collection_id = c.id
            LEFT JOIN videos v ON v.id = i.video_id
            GROUP BY c.id ORDER BY c.created DESC, c.id DESC
            """).map { PlaylistSummary(id: $0.int64("id") ?? 0, name: $0.string("name") ?? "Playlist", sourceURL: $0.string("source_url"),
                                      count: $0.int("n") ?? 0, totalDuration: $0.double("total") ?? 0,
                                      coverPath: $0.string("cover_path"), coverURL: $0.string("cover_url")) }
    }

    func playlistIDs(containing videoID: Int64) throws -> Set<Int64> {
        Set(try db.query("SELECT collection_id FROM collection_items WHERE video_id=?", [videoID]).compactMap { $0.int64("collection_id") })
    }

    /// Every playlist membership, each playlist's videos in their saved order.
    func memberships() throws -> [(playlist: Int64, video: Int64)] {
        try db.query("SELECT collection_id, video_id FROM collection_items ORDER BY collection_id, position, added")
            .compactMap { r in r.int64("collection_id").flatMap { c in r.int64("video_id").map { (c, $0) } } }
    }

    /// Queues the chosen playlist entries in one transaction (an entry per video, existing ones reused; a download
    /// already waiting or running is not queued twice) and, with a target, saves the playlist: every entry of the
    /// YouTube playlist that's in the library joins it by video id, ticked or not. Members it already has keep their
    /// positions; new ones are slotted in next to their YouTube neighbours.
    /// `queue` false (4.0): the ticked videos join the library and the playlist without downloads; Prepare for Offline
    /// then queues them, one video at a time through the download checks.
    func importPlaylist(_ chosen: [PlaylistEntry], all: [PlaylistEntry]? = nil, action: JobAction, format: String?, language: String?,
                        into target: PlaylistTarget?, sourceURL: String?, queue: Bool = true, at: Date = Date()) throws -> PlaylistImportResult {
        try db.transaction {
            var jobs = 0
            for (i, e) in chosen.enumerated() {
                let video = try upsertVideo(key: "youtube:\(e.id)", url: e.url, platform: "YouTube", at: at,
                                            info: VideoInfo(title: e.title, channel: e.channel,
                                                            thumbnail: "https://i.ytimg.com/vi/\(e.id)/mqdefault.jpg"))
                if let d = e.duration { try db.run("UPDATE videos SET duration = coalesce(duration, ?) WHERE id=?", [d, video]) }
                if queue, try insertJob(video, NewJob(kind: action.kind, status: .queued, source: .app, action: action,
                                               started: at.addingTimeInterval(Double(i) / 1000),
                                               summaryLanguage: language, summaryFormat: format)) != nil { jobs += 1 }
            }
            guard let target else { return PlaylistImportResult(playlist: nil, jobs: jobs, linked: 0) }
            let playlist: Int64
            switch target {
            case let .new(name):
                try db.run("INSERT INTO collections(name, source_url, created) VALUES(?, ?, ?)", [name, sourceURL, at])
                playlist = db.lastInsertRowID
            case let .existing(id):
                playlist = id
                try db.run("UPDATE collections SET source_url = coalesce(source_url, ?) WHERE id=?", [sourceURL, id])
            }
            var youtube: [Int64] = []
            for e in (all ?? chosen).sorted(by: { $0.index < $1.index }) {
                if let id = try db.query("SELECT id FROM videos WHERE key=?", ["youtube:\(e.id)"]).first?.int64("id") { youtube.append(id) }
            }
            var position: [Int64: Double] = [:]
            var current: [Int64] = []
            for r in try db.query("SELECT video_id, position FROM collection_items WHERE collection_id=? ORDER BY position, added", [playlist]) {
                guard let v = r.int64("video_id") else { continue }
                current.append(v)
                position[v] = r.double("position") ?? 0
            }
            var linked = 0
            for (id, p) in PlaylistOrder.newPositions(PlaylistOrder.merge(current: current, youtube: youtube), existing: position) {
                linked += try db.run("""
                    INSERT INTO collection_items(collection_id, video_id, position, added) VALUES(?, ?, ?, ?) ON CONFLICT DO NOTHING
                    """, [playlist, id, p, at])
            }
            return PlaylistImportResult(playlist: playlist, jobs: jobs, linked: linked)
        }
    }

    // MARK: download authorizations (4.0)

    /// The declaration you recorded for a video (by its key, so it can exist before a library entry), if any.
    func authorization(_ key: String) -> DownloadAuthorization? {
        guard let r = (try? db.query("SELECT basis, reference, recorded FROM authorizations WHERE video_key=?", [key]))?.first,
              let basis = r.string("basis").flatMap(DownloadAuthorization.Basis.init) else { return nil }
        return DownloadAuthorization(basis: basis, reference: r.string("reference"), recorded: r.date("recorded") ?? Date())
    }

    func allAuthorizations() throws -> [String: DownloadAuthorization] {
        var out: [String: DownloadAuthorization] = [:]
        for r in try db.query("SELECT video_key, basis, reference, recorded FROM authorizations") {
            guard let key = r.string("video_key"), let basis = r.string("basis").flatMap(DownloadAuthorization.Basis.init) else { continue }
            out[key] = DownloadAuthorization(basis: basis, reference: r.string("reference"), recorded: r.date("recorded") ?? Date())
        }
        return out
    }

    func setAuthorization(_ key: String, _ a: DownloadAuthorization) throws {
        try db.run("""
            INSERT INTO authorizations(video_key, basis, reference, recorded) VALUES(?, ?, ?, ?)
            ON CONFLICT(video_key) DO UPDATE SET basis=excluded.basis, reference=excluded.reference, recorded=excluded.recorded
            """, [key, a.basis.rawValue, a.reference, a.recorded])
    }

    /// Channels you said are yours (ids like UC…, or @handles), kept in this profile's database.
    func ownChannels() -> [String] {
        (meta("own_channels") ?? "").split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " }).map(String.init)
    }

    func setOwnChannels(_ list: [String]) throws { try setMeta("own_channels", list.joined(separator: ",")) }

    // MARK: Offline Hub (4.0 Phase 4)

    /// A registered file that moved: the jobs (and the resume position) that named the old path now name the new one, in
    /// one transaction. Only paths change: no file is touched. Refused if the new file doesn't exist, or another entry
    /// already uses it. Returns how many job paths changed.
    func relinkFile(from old: String, to new: String) throws -> Int {
        guard FileManager.default.fileExists(atPath: new) else { throw SQLiteError(message: "the new file doesn't exist") }
        return try db.transaction {
            let taken = try db.query("SELECT 1 AS x FROM jobs WHERE file_path=?1 OR summary_path=?1 OR transcript_path=?1 LIMIT 1", [new])
            guard taken.isEmpty else { throw SQLiteError(message: "another entry already uses that file") }
            let n = try db.run("UPDATE jobs SET file_path=? WHERE file_path=?", [new, old])
                + db.run("UPDATE jobs SET summary_path=? WHERE summary_path=?", [new, old])
                + db.run("UPDATE jobs SET transcript_path=? WHERE transcript_path=?", [new, old])
            try db.run("UPDATE OR IGNORE playback SET file_path=? WHERE file_path=?", [new, old])
            return n
        }
    }

    // MARK: Watch Later (4.0 Phase 3)

    /// Everything saved, newest first.
    func watchLater() throws -> [WatchLaterItem] {
        try db.query("SELECT * FROM watch_later ORDER BY added DESC").compactMap { r in
            guard let key = r.string("video_key"), let url = r.string("url") else { return nil }
            return WatchLaterItem(key: key, url: url, title: r.string("title"), channel: r.string("channel"), duration: r.double("duration"),
                                  thumbnailURL: r.string("thumbnail_url"), added: r.date("added") ?? Date())
        }
    }

    /// Saves a video once: false when it was already saved (the key is the table's primary key).
    func saveToWatchLater(_ item: WatchLaterItem) throws -> Bool {
        try db.run("""
            INSERT INTO watch_later(video_key, url, title, channel, duration, thumbnail_url, added) VALUES(?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(video_key) DO NOTHING
            """, [item.key, item.url, item.title, item.channel, item.duration, item.thumbnailURL, item.added]) == 1
    }

    /// A lookup's details, written to the video they belong to: an UPDATE only, so an item removed meanwhile never comes
    /// back (false then). The lookup's title replaces a guess; channel and duration only fill what's empty.
    @discardableResult
    func fillWatchLaterInfo(_ key: String, _ info: VideoInfo) throws -> Bool {
        try db.run("""
            UPDATE watch_later SET title = coalesce(?, title), channel = coalesce(channel, ?), duration = coalesce(duration, ?)
            WHERE video_key = ?
            """, [info.title?.nilIfBlank, info.channel?.nilIfBlank, info.duration, key]) == 1
    }

    func isInWatchLater(_ key: String) -> Bool {
        (try? db.query("SELECT 1 AS x FROM watch_later WHERE video_key=?", [key]))?.isEmpty == false
    }

    /// In one transaction; files on this Mac are never touched.
    @discardableResult
    func removeFromWatchLater(_ keys: [String]) throws -> Int {
        try db.transaction { try keys.reduce(0) { $0 + (try db.run("DELETE FROM watch_later WHERE video_key=?", [$1])) } }
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

    /// Entries with a resume position that isn't "nearly finished" (the player's rule: the last 5%, at most 10 s), latest first.
    func continueWatching(limit: Int = 3) throws -> [(videoID: Int64, position: Double, duration: Double?)] {
        try db.query("""
            SELECT j.video_id, p.position, p.duration, max(p.updated) AS latest FROM playback p
            JOIN jobs j ON j.file_path = p.file_path AND j.status = 'succeeded'
            WHERE p.position > 1 AND (p.duration IS NULL OR p.position < p.duration - min(10, p.duration * 0.05))
            GROUP BY j.video_id ORDER BY latest DESC LIMIT ?
            """, [limit]).compactMap { r in r.int64("video_id").map { ($0, r.double("position") ?? 0, r.double("duration")) } }
    }

    /// How far you got in each video: its most recently saved position (any of its files).
    func watchStates() throws -> [Int64: Watch] {
        var out: [Int64: Watch] = [:]
        for r in try db.query("""
            SELECT j.video_id, p.position, p.duration, max(p.updated) AS latest FROM playback p
            JOIN jobs j ON j.file_path = p.file_path AND j.status = 'succeeded'
            GROUP BY j.video_id
            """) {
            guard let v = r.int64("video_id") else { continue }
            out[v] = Watch(state: WatchState(position: r.double("position") ?? 0, duration: r.double("duration")),
                           updated: r.date("latest") ?? .distantPast)
        }
        return out
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
        let cols = ["title", "channel", "channel_followers", "thumbnail_url", "duration", "upload_date", "platform", "description", "tags"]
        let sets = cols.map { "\($0) = " + String(format: pick, $0) }.joined(separator: ", ")
        let tags = i.tags.flatMap { $0.isEmpty ? nil : try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        try db.run("UPDATE videos SET \(sets) WHERE id=?",
                   [i.title?.nilIfBlank, i.channel?.nilIfBlank, i.followers, i.thumbnail, i.duration, i.uploadDate, i.platform,
                    i.description?.nilIfBlank, tags, videoID])
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
        case .video: "has_video"
        case .offline: "1"          // file existence is checked by HistoryStore, not SQL
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
                     OR EXISTS(SELECT 1 FROM collection_items ci JOIN collections c ON c.id = ci.collection_id
                               WHERE ci.video_id = v.id AND c.name LIKE ?2 ESCAPE '\\')
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

    /// Returns nil when the event id was already recorded, or for a download (audio or video) of a video that already
    /// has one of the same kind waiting or running, so nothing downloads twice.
    private func insertJob(_ videoID: Int64, _ j: NewJob) throws -> Int64? {
        // 4.0: the last line of defence: whatever asked, a YouTube download is never queued without a declaration on
        // record (a declaration, labelled not independently verified; the technical checks run before it starts)
        if j.status == .queued, let rule = Self.queueRule,
           let key = try db.query("SELECT key FROM videos WHERE id=?", [videoID]).first?.string("key"),
           let reason = rule(j.action ?? JobAction.from(kind: j.kind), key) {
            throw QueueRefused(reason: reason)
        }
        if j.status == .queued, (j.action ?? JobAction.from(kind: j.kind)).downloadsMedia,
           let r = try db.query("""
               SELECT v.key, EXISTS(SELECT 1 FROM authorizations a WHERE a.video_key = v.key) AS declared FROM videos v WHERE v.id=?
               """, [videoID]).first, let key = r.string("key"), key.hasPrefix("youtube:"), !r.bool("declared") {
            throw AuthorizationRequired(key: key)
        }
        if j.status == .queued, j.kind == .audio || j.kind == .video, try !db.query("""
            SELECT 1 FROM jobs WHERE video_id=? AND kind=? AND status IN ('queued', 'running') LIMIT 1
            """, [videoID, j.kind.rawValue]).isEmpty { return nil }
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
              description: r.string("description"),
              tags: r.string("tags").flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [],
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
            transcriptLanguage: r.string("transcript_language"), error: r.string("error"),
            quality: r.string("video_quality"), estimatedBytes: r.int64("estimated_bytes"),
            sizeKind: r.string("size_kind").flatMap(SizeKind.init), lowSpaceStops: r.int("low_space_stops") ?? 0)
    }
}
