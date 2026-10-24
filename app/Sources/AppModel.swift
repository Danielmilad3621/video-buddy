// App-wide state and the actions the views call. Views stay dumb; this decides.
import AppKit
import Foundation
import Observation

enum AppSection: String, CaseIterable, Identifiable {
    case home = "Home", youtube = "YouTube", watchLater = "Watch Later", library = "Library", favorites = "Favorites", playlists = "Playlists",
         downloads = "Downloads", queue = "Queue", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: "house.fill"
        case .youtube: "play.tv"
        case .watchLater: "clock"
        case .library: "rectangle.stack"
        case .favorites: "heart"
        case .playlists: "music.note"
        case .downloads: "arrow.down.to.line"
        case .queue: "slider.horizontal.3"
        case .settings: "gearshape"
        }
    }
}

/// The AI panel's tabs. `video` (player and details) is a tab only when the window is too narrow for its own column.
enum DetailTab: String, CaseIterable, Identifiable {
    case video = "Video", summary = "Summary", transcript = "Transcript", downloads = "Downloads"
    var id: String { rawValue }
    static let panel: [DetailTab] = [.summary, .transcript, .downloads]
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let store: HistoryStore
    let jobs: JobController
    let ingestor: Ingestor
    let network = NetworkMonitor()
    let playback: PlaybackController
    /// 4.0: the YouTube section (its own WebKit data store in the data folder).
    let browser: BrowserController
    let dataDir: URL

    var section = AppSection.home {
        didSet {
            if section == .favorites { store.filter = .favorites }
            else if oldValue == .favorites, store.filter == .favorites { store.filter = .all }
            if section == .youtube, oldValue != .youtube { browser.shown(); updateBrowserCheck() }
            if oldValue == .youtube, section != .youtube {
                browser.hidden(allowBackgroundAudio: UserDefaults.standard.bool(forKey: "browserBackgroundAudio"))
            }
        }
    }
    var detailTab = DetailTab.summary
    var link = ""
    var focusLinkToken = 0
    var focusSearchToken = 0
    var startupWarning: String?
    var importOffer: [ImportGroup]?
    var importStatus: String?
    var pendingRemoval: Video?
    var notice: String?
    /// A watch link inside a playlist: ask whether they mean the video or the whole playlist.
    var playlistChoice: (link: PlaylistLink, kind: JobKind)?
    /// The playlist preview sheet.
    var playlistImport: PlaylistImportState?
    var readingPlaylist = false
    var namePrompt: NamePrompt?
    var pendingPlaylistDeletion: PlaylistSummary?
    var pendingOfflineBatch: OfflineBatch?
    /// The Add Videos sheet's playlist.
    var addingVideosTo: PlaylistSummary?
    /// 4.0 Phase 1b: declarations you recorded (by video key), your own channels, and the declaration sheet.
    var authorizations: [String: DownloadAuthorization] = [:]
    var ownChannels: [String] = []
    var declaration: DeclarationRequest?
    /// Entries whose details (description, tags) are being read from the platform right now.
    var loadingDetails: Set<Int64> = []
    private var launched = false

    private init() {
        dataDir = AppSettings.dataDir
        Database.queueRule = AppSettings.queueRefusal
        // 4.0 G1a: the RC claims its live-download window (once) before the queue starts; any other launch locks it
        if AppSettings.isRC { LiveGrant.claimAtLaunch() }
        let db: Database
        var warning: String?
        do {
            db = try Database(directory: dataDir)
        } catch {
            warning = "History couldn't be opened (\(error)). This session works, but nothing will be saved."
            db = try! Database(inMemory: ())
        }
        startupWarning = warning
        store = HistoryStore(db: db)
        jobs = JobController(store: store, network: network)
        // 4.0 G1a: when the RC's live-download window ends while it's open, the lock is written back and the queue pauses
        if LiveGrant.claimedByThisLaunch, let until = LiveGrant.until {
            Task { @MainActor [jobs] in
                try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))
                LiveGrant.relock()
                jobs.pauseQueue()
            }
        }
        ingestor = Ingestor(store: store, inbox: dataDir.appendingPathComponent("inbox.jsonl"))
        playback = PlaybackController(db: db)
        browser = BrowserController(dataDir: dataDir)
        jobs.onNotice = { [weak self] in self?.notice = $0 }
        jobs.authorize = { [weak self] _, video in await self?.lastCheck(video) }
        playback.onAdvance = { [weak self] in self?.store.select($0) }
        // only one thing plays: the native player pauses YouTube, and YouTube playing pauses the native player
        playback.onWillPlay = { [weak self] in self?.browser.pauseAll() }
        browser.onWebPlaying = { [weak self] in if self?.playback.isPlaying == true { self?.playback.pause() } }
        playback.onSaved = { [weak self] in Task { await self?.store.reloadWatch() } }
    }

    func launch() async {
        guard !launched else { return }
        launched = true
        let db = store.db
        if let aside = await db.recoveredCorruptFile {
            startupWarning = "The history database was damaged. It was kept as \(aside.lastPathComponent) and a fresh one was started."
        }
        _ = try? await db.recoverInterrupted()     // queued jobs stay queued and continue below
        network.start { [weak self] online in
            guard let self else { return }
            if online { self.jobs.pump(); Task { await self.backfillThumbnails() }; self.completeWatchLater() }
        }
        if AppSettings.retentionDays > 0 { _ = try? await db.prune(olderThanDays: AppSettings.retentionDays) }
        do { try await db.backupIfDue() } catch { notice = "Backup skipped: \(error)" }
        await store.reload()
        store.selectFirstIfNeeded()
        authorizations = (try? await db.allAuthorizations()) ?? [:]
        ownChannels = await db.ownChannels()
        browser.onPageChange = { [weak self] _ in self?.updateBrowserCheck() }
        browser.onNotice = { [weak self] in self?.notice = $0 }
        if let problem = browser.restore() { notice = problem }
        completeWatchLater()
        // the preview exists to try the YouTube browser (test runs pick their own section, so --remove can clear the store)
        // (a launch argument, -previewStartSection "Watch Later", can pick another section for that launch only)
        if AppSettings.isolated, ProcessInfo.processInfo.environment["VS_TEST_HOOKS"] != "1" {
            section = UserDefaults.standard.string(forKey: "previewStartSection").flatMap(AppSection.init) ?? .youtube
        }
        ingestor.start()
        await jobs.refreshQueue()
        jobs.pump()
        Task {
            await backfillMetadata()
            await backfillThumbnails()
        }
        if await db.meta("import_offered") == nil {
            let groups = await scanDownloads()
            if groups.isEmpty { try? await db.setMeta("import_offered", "1") } else { importOffer = groups }
        }
    }

    /// Entries whose job never got far enough to save metadata (cancelled, crashed) get it on the next launch.
    private func backfillMetadata() async {
        let missing = ((try? await store.db.videos()) ?? []).filter { $0.title == nil && $0.url != nil }.prefix(10)
        for v in missing {
            guard let url = v.url, let info = await MetadataFetcher.fetch(url) else { continue }
            try? await store.db.applyInfo(v.id, info, override: true)
        }
        if !missing.isEmpty { await store.reload() }
    }

    /// Saves thumbnails on this Mac for entries that don't have one yet: from the web when online, otherwise
    /// from a frame of a local video.
    func backfillThumbnails() async {
        let videos = (try? await store.db.videos()) ?? []
        var changed = false
        for v in videos where v.thumbnailPath.map({ !FileManager.default.fileExists(atPath: $0) }) ?? true {
            let localVideo = store.mediaFiles(for: v.id).first { $0.role == .video && $0.exists }?.path
            guard network.isOnline || localVideo != nil else { continue }
            if await Thumbnails.ensure(v, localVideo: localVideo, db: store.db, online: network.isOnline) != nil { changed = true }
        }
        if changed { await store.reload() }
    }

    // MARK: processing

    func start(_ kind: JobKind) {
        // the YouTube section hides the link field: its shortcuts act for the active tab's video, through the bar's checks
        if section == .youtube { startFromBrowser(kind); return }
        guard let link = link.nilIfBlank else { focusLinkToken += 1; return }
        if let playlist = PlaylistLink.parse(link) {
            if playlist.videoID != nil { playlistChoice = (playlist, kind) } else { readPlaylist(playlist, kind: kind) }
            return
        }
        requestDownload(DownloadRequest(action: downloadAction(kind), youtubeID: VideoRef.parse(link)?.youtubeID, link: link))
    }

    /// The Video Buddy bar in the YouTube section: the same actions as the toolbar, for the page's video.
    // MARK: the YouTube section's action bar (4.0 Phase 1b)

    /// What the library has for a YouTube video, from its canonical id, real files and the queue.
    func availability(youtubeID id: String) -> VideoAvailability {
        guard let v = store.byKey["youtube:\(id)"] else { return VideoAvailability() }
        let current = jobs.current?.videoID == v.id ? jobs.current : nil
        return .make(inLibrary: true, files: store.files(for: v.id),
                     usable: { FileManager.default.fileExists(atPath: $0.path) && (DownloadsList.diskSize($0.path) ?? 0) > 0 },
                     queue: jobs.queue.filter { $0.videoID == v.id }, current: current,
                     failed: store.failed.filter { $0.job.videoID == v.id }, hasSummary: v.hasSummary)
    }

    /// The technical check plus your declaration for that video; nil while checking.
    func browserGate(_ id: String) -> DownloadGate.Decision? {
        DownloadGate.decide(check: browser.checker.results[id], authorization: authorizations["youtube:\(id)"])
    }

    func slotState(_ slot: BarSlot, _ id: String) -> SlotState {
        let a = availability(youtubeID: id), g = browserGate(id)
        return switch slot {
        case .video: .video(a, g)
        case .audio: .audio(a, g)
        case .summary: .summary(a, g)
        }
    }

    /// Starts the metadata check for the video on screen, unless there's nothing left it could unlock.
    func updateBrowserCheck() {
        let id = section == .youtube ? browser.currentVideoID : nil
        let needed = id.map { id in [BarSlot.video, .audio, .summary].contains { s in
            switch slotState(s, id) { case .offline, .queued, .running: false; default: true }
        } } ?? false
        browser.checker.show(id, needed: needed)
    }

    /// Every bar button comes here with the tab and the video id it showed. Nothing is queued unless that tab is still
    /// the active one and that is still its video, the technical checks passed and a declaration is on record; then the
    /// usual queue (with its duplicate guard).
    func requestFromBrowser(_ slot: BarSlot, videoID clicked: String, tabID: UUID?, anotherCopy: Bool = false) {
        let current = browser.active.flatMap { $0.id == tabID ? $0.page.videoID : nil }
        let outcome = BrowserActionOutcome.decide(clicked: clicked, current: current, slot: slotState(slot, clicked),
                                                  anotherCopy: anotherCopy)
        switch outcome {
        case let .queue(id): queueFromBrowser(slot, id)
        case .pageChanged: notice = "The page changed before your click, so nothing was queued. Try again."
        case let .declare(id): declaration = DeclarationRequest(videoID: id, slot: slot, title: browserTitle(id), after: .bar)
        case let .explain(reason): notice = reason
        case .alreadyHave: notice = slot == .summary ? "This video already has a summary." : "You already have this on this Mac."
        case .alreadyQueued: notice = "Already in the queue."
        }
    }

    /// ⌘⇧D, ⌘⇧A and ⌘↩ in the YouTube section: the same as the bar's button for the active tab's video.
    private func startFromBrowser(_ kind: JobKind) {
        guard let t = browser.active, let id = t.page.videoID else {
            notice = "Open a video in this tab first: these shortcuts act for the video on screen."
            return
        }
        requestFromBrowser(kind == .video ? .video : kind == .audio ? .audio : .summary, videoID: id, tabID: t.id)
    }

    /// The title to show for a YouTube video: the active tab's, if it's that video's page, else the library's.
    func browserTitle(_ id: String) -> String? {
        let t = browser.active
        let page = t.flatMap { $0.page.videoID == id ? $0.videoTitle : nil }
        return page ?? store.byKey["youtube:\(id)"]?.title
    }

    /// ⌘T, and the menu's New Tab from any section: YouTube Home in a new tab, its address field ready to type in.
    func newBrowserTab() {
        section = .youtube
        browser.open()
        // the new tab's toolbar is a new view: focus it once it's there
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.focusLinkToken += 1 }
    }

    /// 4.0 Phase 4: the runner's last check before a YouTube download (whatever queued it): a declaration on record
    /// (still only declared, never verified) and the technical checks passed, looked up again when over 30 minutes old.
    func lastCheck(_ v: Video) async -> String? {
        guard v.key.hasPrefix("youtube:") else { return nil }
        guard await store.db.authorization(v.key) != nil else { return "No declaration is on record for this video." }
        switch await browser.checker.fresh(String(v.key.dropFirst("youtube:".count)), maxAge: 30 * 60) {
        case .passed: return nil
        case let .blocked(reason): return reason
        case let .unknown(reason): return "It couldn't be checked: \(reason)"
        }
    }

    // MARK: Watch Later (4.0 Phase 3)

    /// Lookups (details and thumbnail) waiting, one at a time, by video key; the one under way can be cancelled.
    @ObservationIgnored private var lookupQueue: [String] = []
    @ObservationIgnored private var lookup: (key: String, task: Task<Void, Never>)?
    /// Looked up this launch already. ponytail: one try per launch; a video YouTube gave nothing for is tried next launch.
    @ObservationIgnored private var lookedUp: Set<String> = []
    /// Items whose lookup hasn't answered yet (their rows say "Getting details…").
    private(set) var lookupPending: Set<String> = []
    /// The item to select when the Watch Later page opens (Show in Watch Later).
    var watchLaterFocus: String?

    /// Saves the video a button or menu showed (its id came with the click; saving never queues anything). The title is
    /// that tab's only if it was read at that video's address, else the library's, else the lookup's when it answers.
    func saveToWatchLater(_ id: String, from tab: BrowserTab?) {
        let key = "youtube:\(id)"
        guard !store.savedKeys.contains(key) else { notice = "Already in Watch Later."; return }
        let library = store.byKey[key]
        let title = (tab?.page.videoID == id ? tab?.videoTitle : nil) ?? library?.title
        let item = WatchLaterItem.new(youtubeID: id, title: title, channel: library?.channel, duration: library?.duration)
        Task {
            do {
                let added = try await store.db.saveToWatchLater(item)
                await store.reloadWatchLater()
                notice = added ? "Saved to Watch Later." : "Already in Watch Later."
                if added { completeWatchLater([key]) }
            } catch {
                notice = "Couldn't save to Watch Later: \(error)"
            }
        }
    }

    /// Removing is final: a lookup or thumbnail still under way for these is cancelled (its result dropped), and their
    /// thumbnail copies go. Files on this Mac are never touched.
    func removeFromWatchLater(_ keys: [String]) {
        let gone = Set(keys)
        lookupQueue.removeAll { gone.contains($0) }
        if let l = lookup, gone.contains(l.key) { l.task.cancel() }
        lookupPending.subtract(gone)
        Task {
            do {
                let n = try await store.db.removeFromWatchLater(keys)
                for k in keys { Thumbnails.removeWatchLater(String(k.dropFirst("youtube:".count))) }
                await store.reloadWatchLater()
                notice = n == 1 ? "Removed from Watch Later." : "Removed \(n) videos from Watch Later."
            } catch {
                notice = "Couldn't remove: \(error)"
            }
        }
    }

    /// Fills in what saved items lack (a thumbnail copy, and the title, channel or duration from a yt-dlp lookup:
    /// metadata only, nothing downloaded), one at a time. `keys`: these items; nil: every item that needs it.
    func completeWatchLater(_ keys: [String]? = nil) {
        let items = store.watchLater.filter { keys?.contains($0.key) ?? true }
        for item in items where !lookupQueue.contains(item.key) && lookup?.key != item.key {
            let needsThumb = !FileManager.default.fileExists(atPath: Thumbnails.watchLaterPath(item.youtubeID))
            let needsInfo = (item.title == nil || item.channel == nil || item.duration == nil) && !lookedUp.contains(item.key)
            guard needsThumb || needsInfo else { continue }
            lookupQueue.append(item.key)
            if needsInfo { lookupPending.insert(item.key) }
        }
        nextLookup()
    }

    private func nextLookup() {
        guard lookup == nil, let key = lookupQueue.first else { return }
        guard let item = store.watchLater.first(where: { $0.key == key }) else {
            lookupQueue.removeFirst()
            lookupPending.remove(key)
            return nextLookup()
        }
        // offline: the library's thumbnail copy can still be used; the lookup waits until you're back online
        let online = network.isOnline
        guard online || store.byKey[key]?.thumbnailPath != nil else { return }
        lookupQueue.removeFirst()
        let db = store.db
        let task = Task { [weak self] in
            guard let self else { return }
            if !FileManager.default.fileExists(atPath: Thumbnails.watchLaterPath(item.youtubeID)) {
                await Thumbnails.saveWatchLater(item, libraryCopy: self.store.byKey[key]?.thumbnailPath, online: online) { await db.isInWatchLater(key) }
            }
            if online, item.title == nil || item.channel == nil || item.duration == nil, !self.lookedUp.contains(key), !Task.isCancelled {
                self.lookedUp.insert(key)
                // the answer is written to the video it was asked for, and only if that item is still saved
                if let info = await MetadataFetcher.fetch(item.url), !Task.isCancelled { _ = try? await db.fillWatchLaterInfo(key, info) }
            }
            self.lookupDone(key)
        }
        lookup = (key, task)
    }

    private func lookupDone(_ key: String) {
        guard lookup?.key == key else { return }
        lookup = nil
        if !lookupQueue.contains(key) { lookupPending.remove(key) }
        Task {
            await store.reloadWatchLater()
            nextLookup()
        }
    }

    /// What didn't fit when opening several saved videos in tabs (shown until you close it).
    var openReport: String?

    /// A row's main button: play what's on this Mac (the library entry, in the player on the right), else open on YouTube.
    func primaryAction(_ item: WatchLaterItem) {
        guard let v = store.byKey[item.key], WatchLater.primary(availability(youtubeID: item.youtubeID)) != .openInYouTube else {
            openInYouTube(item)
            return
        }
        store.select(v.id)
        play(v)
    }

    /// The tab already showing this video if there is one, else a new tab (in front, or behind and asleep).
    func openInYouTube(_ item: WatchLaterItem, background: Bool = false) {
        if let t = browser.tabs.first(where: { $0.page.videoID == item.youtubeID }) {
            if !background { browser.select(t); section = .youtube }
            return
        }
        guard browser.tabs.count < BrowserController.maxTabs, let url = URL(string: item.url) else {
            openReport = "\(BrowserController.maxTabs) tabs are open, the most Video Buddy keeps, so “\(item.title ?? item.url)” wasn't opened. Close some tabs and try again."
            return
        }
        // the tab first, then the section: showing YouTube with no tabs would add a Home tab of its own
        browser.open(url, background: background)
        if background { notice = "Opened in a tab behind." } else { section = .youtube }
    }

    /// Open in Tabs for several: each behind (asleep until selected), as many as there's room for; one already open is
    /// reused. The ones that didn't fit are named.
    func openInTabs(_ items: [WatchLaterItem]) {
        var opened = 0, first: BrowserTab?, skipped: [WatchLaterItem] = []
        for item in items {
            if let t = browser.tabs.first(where: { $0.page.videoID == item.youtubeID }) {
                opened += 1
                first = first ?? t
            } else if browser.tabs.count < BrowserController.maxTabs, let url = URL(string: item.url) {
                browser.open(url, background: true)
                opened += 1
                first = first ?? browser.tabs.last
            } else {
                skipped.append(item)
            }
        }
        if let first { browser.select(first); section = .youtube }
        if !skipped.isEmpty {
            let names = skipped.map { "• " + ($0.title ?? "youtube.com/watch?v=\($0.youtubeID)") }.joined(separator: "\n")
            openReport = "Opened \(opened) of \(items.count). \(skipped.count == 1 ? "This one wasn't" : "These \(skipped.count) weren't") opened because "
                + "\(BrowserController.maxTabs) tabs are open, the most Video Buddy keeps:\n\(names)\nClose some tabs and try again."
        }
    }

    /// Shows the Watch Later page, with an item selected.
    func showWatchLater(select key: String? = nil) {
        watchLaterFocus = key
        section = .watchLater
    }

    /// The Tab menu's commands act only while the YouTube section is shown.
    func inBrowser(_ act: (BrowserController) -> Void) { if section == .youtube { act(browser) } }

    func reopenTab() {
        guard !browser.closed.isEmpty else { return }
        section = .youtube
        browser.reopenClosed()
    }

    private func queueFromBrowser(_ slot: BarSlot, _ id: String) {
        let action: JobAction = switch slot {
        case .video: downloadAction(.video)
        case .audio: downloadAction(.audio)
        case .summary: .summarize
        }
        jobs.enqueue(action, link: BrowserPolicy.watchURL(id))
    }

    /// Records your declaration for the video it was made for, then carries on with that video's action (even if the
    /// tab moved on meanwhile: the request was for this one).
    func declare(_ request: DeclarationRequest, basis: DownloadAuthorization.Basis, reference: String?) {
        declaration = nil
        let key = "youtube:\(request.videoID)"
        let a = DownloadAuthorization(basis: basis, reference: reference?.nilIfBlank, recorded: Date())
        Task {
            do { try await store.db.setAuthorization(key, a) } catch { notice = "Couldn't save the declaration: \(error)"; return }
            authorizations[key] = a
            switch request.after {
            case .bar:
                switch slotState(request.slot, request.videoID) {
                case .ready, .retry, .downloadAgain: queueFromBrowser(request.slot, request.videoID)
                case let state: notice = "Declaration saved. \(state == .checking ? "Still checking the video; try again in a moment." : "Nothing queued.")"
                }
            case let .queue(r): requestDownload(r)          // the action it was asked for, through the same checks
            case .prepare: notice = "Declaration saved (declared, not independently verified)."
            }
        }
    }

    func setOwnChannels(_ text: String) {
        let list = text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
        ownChannels = list
        Task { try? await store.db.setOwnChannels(list) }
    }

    /// Audio and Video follow the "+ Transcript" checkbox; Summarize always transcribes anyway.
    private func downloadAction(_ kind: JobKind) -> JobAction { .download(kind, transcript: AppSettings.transcribeDownloads) }

    // MARK: playlists

    func justThisVideo() {
        guard let choice = playlistChoice else { return }
        playlistChoice = nil
        requestDownload(DownloadRequest(action: downloadAction(choice.kind), youtubeID: VideoRef.parse(link)?.youtubeID, link: link))
    }

    func wholePlaylist() {
        guard let choice = playlistChoice else { return }
        playlistChoice = nil
        readPlaylist(choice.link, kind: choice.kind)
    }

    /// Lists the playlist's videos (a few seconds, nothing downloaded) and opens the preview sheet. `checking`: opened
    /// from Check Against YouTube on that playlist, so nothing is ticked and saving only links library videos.
    /// `linkOnly` (from the YouTube section): the sheet can only link library videos, never queue downloads, since
    /// downloads from there go through the bar's checks one video at a time.
    func readPlaylist(_ playlist: PlaylistLink, kind: JobKind, checking: Int64? = nil, linkOnly: Bool = false) {
        guard network.isOnline else { notice = "Reading a playlist needs internet."; return }
        readingPlaylist = true
        notice = "Reading the playlist…"
        Task {
            let result = await PlaylistImport.fetch(playlist.url)
            readingPlaylist = false
            switch result {
            case let .success(preview):
                notice = nil
                playlistImport = PlaylistImportState(preview: preview, action: downloadAction(kind), checking: checking, linkOnly: linkOnly)
            case let .failure(error):
                notice = "Couldn't read the playlist: \(error.message)"
            }
        }
    }

    /// Check Against YouTube: reads the playlist's saved link (metadata only) and opens the sheet in linking mode.
    func checkPlaylist(_ p: PlaylistSummary) {
        guard let url = p.sourceURL, let link = PlaylistLink.parse(url) else { return }
        readPlaylist(link, kind: .video, checking: p.id)
    }

    /// The playlist a pasted link already belongs to (same YouTube playlist), if any.
    func playlist(forSource url: String) -> PlaylistSummary? {
        let list = PlaylistLink.parse(url)?.listID
        return store.playlists.first { $0.sourceURL.flatMap(PlaylistLink.parse)?.listID == list && list != nil }
    }

    /// Queues the chosen videos (one at a time, oldest first) and, with a target, saves the playlist: library videos
    /// that are in the YouTube playlist join it by video id even when not chosen. Nothing is downloaded that isn't chosen.
    func importPlaylist(_ entries: [PlaylistEntry], all: [PlaylistEntry], action: JobAction, into target: PlaylistTarget?, sourceURL: String) {
        let entries = playlistImport?.linkOnly == true ? [] : entries
        playlistImport = nil
        // 4.0: the ticked YouTube videos join the library and the playlist without downloads; Prepare for Offline
        // queues them, each through the download checks
        let prepareThese = action.downloadsMedia ? entries.map { (id: $0.id, title: Optional($0.title)) } : []
        guard !entries.isEmpty || target != nil else { return }
        let (format, language) = action == .summarize ? (AppSettings.format.rawValue, AppSettings.language.rawValue) : (nil, nil)
        Task {
            do {
                let r = try await store.db.importPlaylist(entries, all: all, action: action, format: format, language: language,
                                                          into: target, sourceURL: sourceURL, queue: prepareThese.isEmpty)
                await store.reload()
                await jobs.refreshQueue()
                jobs.pump()
                if let id = r.playlist {
                    section = .playlists
                    store.openPlaylistID = id
                }
                let linked = r.playlist == nil ? nil : "\(r.linked) \(r.linked == 1 ? "video" : "videos") linked to the playlist"
                notice = "\(linked ?? "Nothing changed"). Nothing was downloaded."
                if !prepareThese.isEmpty { prepareForOffline(prepareThese, from: "Playlist") }
            } catch {
                notice = "Couldn't add the playlist: \(error)"
            }
        }
    }

    /// Opens a playlist's page (and selects one of its videos when given).
    func openPlaylist(_ id: Int64, selecting videoID: Int64? = nil) {
        section = .playlists
        store.openPlaylistID = id
        if let videoID { store.select(videoID) }
    }

    func createPlaylist(_ name: String, adding videoID: Int64? = nil) {
        guard let name = name.nilIfBlank else { return }
        Task {
            guard let id = try? await store.db.createPlaylist(name) else { return }
            if let videoID { try? await store.db.addToPlaylist(id, videoIDs: [videoID]) }
            await store.reloadPlaylists()
            notice = videoID == nil ? "Created “\(name)”." : "Added to the new playlist “\(name)”."
        }
    }

    func renamePlaylist(_ id: Int64, to name: String) {
        guard let name = name.nilIfBlank else { return }
        Task { try? await store.db.renamePlaylist(id, name); await store.reloadPlaylists() }
    }

    func confirmPlaylistDeletion() {
        guard let p = pendingPlaylistDeletion else { return }
        pendingPlaylistDeletion = nil
        Task {
            try? await store.db.deletePlaylist(p.id)
            if store.openPlaylistID == p.id { store.openPlaylistID = nil }
            await store.reloadPlaylists()
            notice = "Deleted the playlist “\(p.name)”. Its videos are still in your history and on disk."
        }
    }

    func addToPlaylist(_ id: Int64, video: Video) {
        Task {
            try? await store.db.addToPlaylist(id, videoIDs: [video.id])
            await store.reloadPlaylists()
            notice = "Added to “\(store.playlists.first { $0.id == id }?.name ?? "playlist")”."
        }
    }

    func addVideos(_ ids: [Int64], to playlistID: Int64) {
        addingVideosTo = nil
        guard !ids.isEmpty else { return }
        Task {
            try? await store.db.addToPlaylist(playlistID, videoIDs: ids)
            await store.reloadPlaylists()
            notice = "Added \(ids.count) \(ids.count == 1 ? "video" : "videos") to the playlist."
        }
    }

    func removeFromOpenPlaylist(_ video: Video) {
        guard let id = store.openPlaylistID else { return }
        Task { try? await store.db.removeFromPlaylist(id, videoID: video.id); await store.reloadPlaylists() }
    }

    func movePlaylistItems(from source: IndexSet, to destination: Int) {
        guard let id = store.openPlaylistID else { return }
        var ids = store.playlistVideos.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        store.playlistVideos.move(fromOffsets: source, toOffset: destination)   // instant feedback
        Task { try? await store.db.reorderPlaylist(id, videoIDs: ids); await store.reloadPlaylists() }
    }

    /// Plays a playlist in order from its first episode on this Mac (Play All), skipping ones that aren't here.
    func playAll(_ playlistID: Int64? = nil) {
        guard let id = playlistID ?? store.openPlaylistID else { return }
        let items = store.playableMembers(id)
        guard let first = items.first, let v = store.video(first.videoID) else {
            notice = "None of these videos are on this Mac yet. Use Download Missing first."
            return
        }
        play(v, in: id)
        let total = store.members[id]?.count ?? 0
        if items.count < total { notice = "Playing \(items.count) of \(total): the others aren't on this Mac yet." }
    }

    /// Continue: the episode you stopped in, or the next one after the last you finished (else Play All).
    func continuePlaylist(_ playlistID: Int64) {
        guard let id = store.resumeTarget(playlistID), let v = store.video(id) else { playAll(playlistID); return }
        play(v, in: playlistID)
    }

    /// Asks first (with the size and free disk space), then queues a video download for every member without a video
    /// file on this Mac. Ones already waiting or downloading are left out (and the database refuses duplicates anyway).
    func askDownloadMissing(_ playlistID: Int64? = nil) {
        guard let id = playlistID ?? store.openPlaylistID else { return }
        let busy = Set(jobs.queue.filter { $0.action.kind == .video }.map(\.videoID) + [jobs.current?.videoID].compactMap { $0 })
        let missing = store.memberVideos(id).filter { $0.url != nil && !store.hasLocalVideo($0.id) && !busy.contains($0.id) }
        guard !missing.isEmpty else {
            notice = busy.isEmpty ? "Every video in this playlist is already on this Mac." : "The missing videos are already in the queue."
            return
        }
        // 4.0: YouTube videos go through Prepare for Offline (checked one at a time); others as in 3.1
        let youtube = missing.compactMap { v in Self.youtubeID(v).map { (id: $0, title: Optional(v.displayTitle)) } }
        if !youtube.isEmpty {
            prepareForOffline(youtube, from: store.playlists.first { $0.id == id }?.name ?? "Playlist")
            return
        }
        pendingOfflineBatch = OfflineBatch(videoIDs: missing.map(\.id), totalDuration: missing.compactMap(\.duration).reduce(0, +))
    }

    func confirmOfflineBatch() {
        guard let batch = pendingOfflineBatch else { return }
        pendingOfflineBatch = nil
        Task {
            var queued = 0
            for id in batch.videoIDs where (try? await store.db.enqueue(videoID: id, action: .video)) != nil { queued += 1 }
            await store.reload()
            await jobs.refreshQueue()
            jobs.pump()
            let skipped = batch.videoIDs.count - queued
            notice = "Queued \(queued) video \(queued == 1 ? "download" : "downloads")"
                + (skipped > 0 ? " (\(skipped) already in the queue)" : "")
                + (network.isOnline || queued == 0 ? "." : ": they start when you're back online.")
        }
    }

    func pasteLink() {
        if let text = NSPasteboard.general.string(forType: .string)?.nilIfBlank { paste(text) }
    }

    func paste(_ text: String) {
        // the YouTube section has no link field: a copied YouTube link opens in a new tab instead
        guard section == .youtube else { link = text; return }
        if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), BrowserPolicy.decide(url, mainFrame: true) == .allow,
           url.host.map({ BrowserPolicy.isInApp(host: $0) }) == true {
            browser.open(url)
        } else {
            notice = "Not a YouTube link."
        }
    }

    /// Retry: a download or summary of a YouTube video goes through the download checks again; on-device work doesn't.
    func retry(_ r: RetryInfo) {
        guard r.action.downloadsMedia, let v = store.video(r.videoID), let id = Self.youtubeID(v) else { jobs.retry(r); return }
        requestDownload(DownloadRequest(action: r.action, youtubeID: id, videoID: r.videoID))
    }

    func processAgain(_ v: Video) {
        guard v.url != nil else { return }
        requestDownload(DownloadRequest(action: .summarize, youtubeID: Self.youtubeID(v), videoID: v.id, format: AppSettings.format, language: AppSettings.language))
    }

    func downloadAgain(_ v: Video, kind: JobKind) {
        guard v.url != nil else { return }
        requestDownload(DownloadRequest(action: JobAction.from(kind: kind), youtubeID: Self.youtubeID(v), videoID: v.id))
    }

    /// Downloads the video file, so the entry can be watched without internet.
    func makeAvailableOffline(_ v: Video) {
        guard v.url != nil else { return }
        requestDownload(DownloadRequest(action: .video, youtubeID: Self.youtubeID(v), videoID: v.id))
    }

    // MARK: the download checks for every way of starting one (4.0 Phase 4)

    static func youtubeID(_ v: Video) -> String? { v.key.hasPrefix("youtube:") ? String(v.key.dropFirst("youtube:".count)) : nil }

    /// Every way of starting a download in the app comes here, except the browser bar (whose buttons already show the
    /// checks) and Prepare for Offline (which checks each row): a YouTube video is queued only with a declaration on
    /// record and passed technical checks; without a declaration, the declaration sheet opens for that video;
    /// unavailable or unchecked, it says why. Other sites and on-device work go to the queue as in 3.1.
    func requestDownload(_ r: DownloadRequest) {
        // the RC: not before you've approved AI summaries, nor a video that isn't on its live-test list (the database
        // and the runner check this too)
        let key = r.youtubeID.map { "youtube:\($0)" } ?? r.videoID.flatMap { store.video($0)?.key } ?? r.link.flatMap { VideoRef.parse($0)?.key } ?? ""
        if let refusal = AppSettings.queueRefusal(r.action, key: key) {
            notice = "Not queued: \(refusal)."
            return
        }
        // 4.0 G1a: never a second copy without asking (the bar asks the same way); G1b: saying which qualities are
        // here and which one would come
        if !r.anotherCopy, case let have = existingCopies(r), !have.isEmpty {
            Task { pendingCopy = await copyPrompt(r, have) }
            return
        }
        guard r.action.downloadsMedia, let id = r.youtubeID else { enqueueNow(r); return }
        Task {
            var decision = browserGate(id)
            if decision == nil {
                notice = "Checking this video before downloading…"
                _ = await browser.checker.fresh(id, maxAge: 30 * 60)
                decision = browserGate(id)
            }
            switch decision {
            case .allowed?: enqueueNow(r)
            case .needsDeclaration?:
                notice = nil
                declaration = DeclarationRequest(videoID: id, slot: BarSlot(r.action), title: browserTitle(id), after: .queue(r))
            case let .blocked(reason)?: notice = "Not downloaded: \(reason)"
            case let .unknown(reason)?: notice = "Couldn't check this video, so nothing was queued: \(reason)"
            case nil: notice = "Couldn't check this video, so nothing was queued."
            }
        }
    }

    /// A download asked for while that video's (or audio's) file is already on this Mac, waiting for you to say whether
    /// you want another copy.
    var pendingCopy: CopyPrompt?

    /// The files of that kind this video already has on this Mac (a video download for video files, audio for audio).
    func existingCopies(_ r: DownloadRequest) -> [FileItem] {
        let role: FileItem.Role
        switch r.action {
        case .video, .videoTranscript: role = .video
        case .audio, .audioTranscript: role = .audio
        default: return []
        }
        let key = r.youtubeID.map { "youtube:\($0)" } ?? r.link.flatMap { VideoRef.parse($0)?.key }
        guard let v = r.videoID.flatMap({ store.video($0) }) ?? key.flatMap({ store.byKey[$0] }) else { return [] }
        return store.mediaFiles(for: v.id).filter { $0.role == role && $0.exists && (DownloadsList.diskSize($0.path) ?? 0) > 0 }
    }

    /// What's here (each copy's resolution, read with ffprobe) and what the request would bring (from the video's
    /// formats at your quality setting), in words.
    private func copyPrompt(_ r: DownloadRequest, _ have: [FileItem]) async -> CopyPrompt {
        var heights: [Int?] = []
        for f in have { heights.append(f.role == .video ? await MediaChecker.quickCheck(f.path).info?.height : nil) }
        var coming: Int?
        if have.first?.role == .video, let id = r.youtubeID {
            if browser.checker.facts[id] == nil { _ = await browser.checker.fresh(id, maxAge: 30 * 60) }
            coming = browser.checker.facts[id].flatMap { SizeEstimate.video($0, quality: AppSettings.videoQuality.scriptValue).height }
        }
        let w = CopyPrompt.wording(role: have.first?.role ?? .video, names: have.map(\.name), existing: heights, coming: coming,
                                   quality: AppSettings.videoQuality.label)
        return CopyPrompt(request: r, files: have, title: w.title, message: w.message, confirm: w.confirm, sameQuality: w.same)
    }

    /// Download Another Copy: the request goes on, through every usual check.
    func confirmCopy() {
        guard var r = pendingCopy?.request else { return }
        pendingCopy = nil
        r.anotherCopy = true
        requestDownload(r)
    }

    private func enqueueNow(_ r: DownloadRequest) {
        if let v = r.videoID {
            jobs.enqueue(r.action, videoID: v, format: r.format, language: r.language)
        } else if let link = r.link {
            jobs.enqueue(r.action, link: link)
        }
    }

    // MARK: requests from other apps (4.0 Phase 5)

    /// A videobuddy:// request waiting for your confirmation (one at a time).
    var externalRequest: ExternalRequest?

    /// From Raycast, or any other app or web page: checked, then shown for you to confirm. Nothing is queued here.
    func receive(_ url: URL) {
        switch ExternalRequest.parse(url) {
        case let .failure(r):
            notice = "Ignored a request from another app: \(r.reason)."
        case var .success(request):
            // one at a time, and never on top of something you're in the middle of
            guard externalRequest == nil, !NSApp.windows.contains(where: { $0.attachedSheet != nil }) else {
                notice = "Ignored a request from another app: finish what's open in Video Buddy first, then send it again."
                return
            }
            request.title = request.youtubeID.flatMap { store.byKey["youtube:\($0)"]?.title }
            externalRequest = request
            NSApp.activate()
            guard let id = request.youtubeID, request.title == nil else { return }
            Task {
                let info = await MetadataFetcher.fetch(BrowserPolicy.watchURL(id))
                guard externalRequest?.id == request.id else { return }   // cancelled meanwhile
                externalRequest?.title = info?.title
                externalRequest?.channel = info?.channel
            }
        }
    }

    /// Download: as if you'd pasted the link and pressed the button (your declaration and the checks; a playlist
    /// opens its list, then Prepare).
    func confirmExternal() {
        guard let r = externalRequest else { return }
        externalRequest = nil
        if let playlist = r.playlist { readPlaylist(playlist, kind: r.kind); return }
        requestDownload(DownloadRequest(action: downloadAction(r.kind), youtubeID: r.youtubeID, link: r.link))
    }

    // MARK: Ready for Offline (4.0 Phase 4)

    /// Checks registered media files (read-only).
    let media = MediaChecker()
    /// Locate… / Relink, waiting for your confirmation: the file the library has, and where it is now.
    var pendingRelink: (file: FileItem, to: String)?

    /// Locate…: you pick where the file is now; nothing changes until you confirm.
    func locate(_ f: FileItem) {
        let panel = NSOpenPanel()
        panel.message = "Where is “\(f.name)” now? Only Video Buddy's record changes; the file isn't moved or renamed."
        panel.directoryURL = URL(fileURLWithPath: (f.path as NSString).deletingLastPathComponent)
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingRelink = (f, url.path)
    }

    /// After you confirm: the library's record (and resume position) points at the file's new place.
    func confirmRelink() {
        guard let r = pendingRelink else { return }
        pendingRelink = nil
        Task {
            do {
                _ = try await store.db.relinkFile(from: r.file.path, to: r.to)
                media.forget(r.file.path)
                await store.reload()
                media.check([r.to])
                notice = "Relinked “\(r.file.name)” to \(r.to) (it was \(r.file.path)). No file was moved."
            } catch {
                notice = "Not relinked: \(error)"
            }
        }
    }

    /// The "Play Offline" / "Play Audio" of a file row: that file, in the built-in player.
    func playFile(_ f: FileItem) {
        store.select(f.videoID)
        playback.play(path: f.path, videoID: f.videoID)
    }

    // MARK: Prepare for Offline (4.0 Phase 4)

    /// The Prepare sheet, when open.
    var prepare: PrepareState?

    /// Opens Prepare for Offline for these YouTube videos (Watch Later, a playlist, Downloads) and starts their checks,
    /// one at a time. Nothing is queued until you press Queue.
    func prepareForOffline(_ items: [(id: String, title: String?)], from source: String) {
        var seen = Set<String>()
        let rows = items.filter { seen.insert($0.id).inserted }.map { PrepareRow(id: $0.id, title: $0.title ?? store.byKey["youtube:\($0.id)"]?.title) }
        guard !rows.isEmpty else { notice = "Nothing to prepare."; return }
        prepare = PrepareState(rows: rows, source: source)
        browser.checker.checkAll(rows.map(\.id))
    }

    /// A row's state right now, from what's on this Mac, the queue and the download checks.
    func prepareStatus(_ row: PrepareRow) -> PrepareRule.Status {
        PrepareRule.status(kind: row.kind, availability: availability(youtubeID: row.id), gate: browserGate(row.id),
                           refused: AppSettings.queueRefusal(.from(kind: row.kind), key: "youtube:\(row.id)"))
    }

    /// Queue N Downloads: each ticked row is checked again now (ready, not already here, not already queued), then
    /// queued with its quality and size estimate; anything else is skipped and counted. Never anything unticked.
    func queuePrepared(_ rows: [PrepareRow], quality: String?, transcript: Bool) {
        prepare = nil
        browser.checker.cancelBatch()
        Task {
            var queued = 0, skipped = 0
            for row in rows where row.include {
                guard prepareStatus(row) == .ready, let ref = VideoRef.parse(BrowserPolicy.watchURL(row.id)) else { skipped += 1; continue }
                let facts = browser.checker.facts[row.id]
                let estimate: (Int64?, SizeKind) = row.kind == .video
                    ? facts.map { let e = SizeEstimate.video($0, quality: quality); return (e.bytes, e.kind) } ?? (nil, .unknown)
                    : facts.map { SizeEstimate.audio($0) } ?? (nil, .unknown)
                let options = JobOptions(quality: row.kind == .video ? quality : nil, estimatedBytes: estimate.0, sizeKind: estimate.1)
                do {
                    _ = try await store.db.enqueue(ref, action: .download(row.kind, transcript: transcript), options: options)
                    queued += 1
                } catch {
                    skipped += 1
                }
            }
            await store.reload()
            await jobs.refreshQueue()
            jobs.pump()
            notice = "Queued \(queued) \(queued == 1 ? "download" : "downloads")" + (skipped > 0 ? "; \(skipped) not queued (already here, queued or not allowed)" : "")
                + (JobController.canRun ? "." : ". They wait: \(AppSettings.jobsLockReason ?? "the queue is locked").")
        }
    }

    /// On-device transcript of a file already on this Mac (audio first: it needs no conversion).
    func transcribe(_ v: Video) {
        let local = store.mediaFiles(for: v.id).filter(\.exists)
        guard let file = local.first(where: { $0.role == .audio }) ?? local.first else {
            notice = "There's no audio or video file of this entry on this Mac."
            return
        }
        jobs.enqueue(.transcribe, videoID: v.id, filePath: file.path)
    }

    /// A new summary from the saved transcript (queued until online when needed).
    func regenerate(format: SummaryFormat = AppSettings.format, language: SummaryLanguage = AppSettings.language) {
        guard let v = store.selectedVideo, store.transcriptJob != nil else { return }
        if let refusal = AppSettings.queueRefusal(.resummarize, key: v.key) { notice = "Not queued: \(refusal)."; return }
        detailTab = .summary
        jobs.enqueue(.resummarize, videoID: v.id, format: format, language: language)
    }

    // MARK: playback

    /// Plays a video; in a playlist (the one given, else the first it's in) Next, Previous and Up Next follow that
    /// playlist. A video in no playlist plays on its own, as before.
    func play(_ v: Video, in playlistID: Int64? = nil) {
        guard let file = store.playable(for: v.id) else { return }
        store.select(v.id)
        let items = (playlistID ?? store.playlistsOf(v.id).first?.id).map { store.playableMembers($0) } ?? []
        guard let pid = playlistID ?? store.playlistsOf(v.id).first?.id, let i = items.firstIndex(where: { $0.videoID == v.id }),
              let p = store.playlists.first(where: { $0.id == pid }) else {
            playback.play(path: file.path, videoID: v.id)
            return
        }
        playback.play(path: items[i].path, videoID: v.id, upNext: Array(items[(i + 1)...]), played: Array(items[..<i]),
                      context: PlaylistContext(id: pid, name: p.name, count: store.members[pid]?.count ?? 0))
    }

    /// Jumps the built-in player to a transcript line, starting playback if needed.
    func seek(_ v: Video, to seconds: Double) {
        guard let file = store.playable(for: v.id) else { return }
        if !playback.isCurrent(file.path) { playback.play(path: file.path, videoID: v.id) }
        playback.seek(to: seconds)
        if !playback.isPlaying { playback.togglePlayPause() }
    }

    // MARK: per-video actions

    func open(_ v: Video, tab: DetailTab) {
        store.select(v.id)
        detailTab = tab
    }

    func copyLink(_ v: Video) {
        guard let url = v.url else { return }
        FileOps.copy(url)
        notice = "Link copied"
    }

    /// Reads the description and tags with yt-dlp (metadata only: nothing is downloaded, no AI).
    func loadDetails(_ v: Video) {
        guard let url = v.url, !loadingDetails.contains(v.id) else { return }
        guard network.isOnline else { notice = "Loading details needs internet."; return }
        loadingDetails.insert(v.id)
        Task {
            let info = await MetadataFetcher.fetch(url)
            loadingDetails.remove(v.id)
            guard let info else { notice = "Couldn't read this video's details."; return }
            try? await store.db.applyInfo(v.id, info, override: true)
            await store.reload()
            if info.description?.nilIfBlank == nil { notice = "This video has no description." }
        }
    }

    func toggleFavorite(_ v: Video) {
        Task {
            try? await store.db.setFavorite(v.id, !v.favorite)
            await store.reload()
        }
    }

    func copySummary(_ v: Video) {
        Task {
            let jobs = (try? await store.db.jobs(for: v.id)) ?? []
            if let s = jobs.first(where: { $0.kind == .summary && $0.status == .succeeded && $0.summary != nil })?.summary {
                FileOps.copy(s)
                notice = "Summary copied as Markdown"
            } else {
                notice = "This video has no saved summary yet"
            }
        }
    }

    func copyTranscript(_ v: Video) {
        Task {
            let jobs = (try? await store.db.jobs(for: v.id)) ?? []
            if let t = jobs.first(where: { $0.transcript?.nilIfBlank != nil })?.transcript {
                FileOps.copy(t)
                notice = "Transcript copied"
            } else {
                notice = "This video has no saved transcript"
            }
        }
    }

    /// The newest media file of this video that still exists on disk.
    func existingMedia(_ v: Video) -> FileItem? { store.mediaFiles(for: v.id).first(where: \.exists) }

    func confirmRemoval() {
        guard let v = pendingRemoval else { return }
        pendingRemoval = nil
        Task {
            if playback.currentVideoID == v.id { playback.stop() }
            try? await store.db.deleteVideo(v.id)
            Thumbnails.remove(videoIDs: [v.id])
            if store.selectedID == v.id { store.select(nil) }
            await store.reload()
            store.selectFirstIfNeeded()
            notice = "Removed “\(v.displayTitle)” from history. Its files were kept."
        }
    }

    func clearAll() {
        Task {
            playback.stop()
            try? await store.db.deleteAll()
            Thumbnails.removeAll()
            store.select(nil)
            await store.reload()
            notice = "History cleared. Your files in the downloads folder were kept."
        }
    }

    // MARK: import

    private func scanDownloads() async -> [ImportGroup] {
        let known = (try? await store.db.knownPaths()) ?? []
        let dir = URL(fileURLWithPath: AppSettings.downloadDir)
        return await Task.detached { Importer.scan(dir, known: known) }.value
    }

    func runImport(_ offered: [ImportGroup]? = nil) {
        importOffer = nil
        importStatus = "Importing…"
        Task {
            let groups: [ImportGroup]
            if let offered { groups = offered } else { groups = await scanDownloads() }
            do {
                let r = try await Importer.run(groups, db: store.db)
                importStatus = r.jobs == 0 ? "Nothing new to import." : "Imported \(r.videos) videos (\(r.jobs) items). No files were changed."
            } catch {
                importStatus = "Import stopped: \(error)"
            }
            try? await store.db.setMeta("import_offered", "1")
            await store.reload()
            store.selectFirstIfNeeded()
            notice = importStatus
        }
    }

    func declineImport() {
        importOffer = nil
        Task { try? await store.db.setMeta("import_offered", "1") }
    }

    func applyRetention() {
        let days = AppSettings.retentionDays
        guard days > 0 else { return }
        Task {
            let n = (try? await store.db.prune(olderThanDays: days)) ?? 0
            if n > 0 { notice = "Removed \(n) old entries (favorites are always kept)." }
            await store.reload()
        }
    }

    var freeDiskSpace: Int64? { DiskSpace.free(at: AppSettings.downloadDir) }

    func revealDatabase() {
        NSWorkspace.shared.activateFileViewerSelecting([dataDir.appendingPathComponent("history.sqlite")])
    }
}

/// The action bar's three slots, in their fixed order.
enum BarSlot: String { case video, audio, summary }

/// The declaration sheet, for one video and the action you asked for.
struct DeclarationRequest: Identifiable {
    let id = UUID()
    let videoID: String
    let slot: BarSlot
    /// Shown in the sheet, so you always see which video the declaration is for.
    let title: String?
    /// What happens once you've declared: the bar's button, the action it was asked for, or nothing (Prepare's row).
    var after: AfterDeclaring = .bar
}

enum AfterDeclaring { case bar, queue(DownloadRequest), prepare }

extension BarSlot {
    init(_ action: JobAction) { self = action.kind == .video ? .video : action.kind == .audio ? .audio : .summary }
}

/// 4.0 Phase 4: a download asked for from the Library, the link field or Retry, with the video it's for.
/// 4.0 Phase 5: a request from another app (Raycast), videobuddy://request?url=<link>&action=video|audio|summarize.
/// It carries no secret, since anything on this Mac (or a web page, after Safari asks) can send one: every request is
/// checked strictly here, then shown for you to confirm; only Download goes on, through the same checks as a pasted link.
struct ExternalRequest: Identifiable, Equatable {
    struct Refusal: Error { let reason: String }

    let id = UUID()
    let kind: JobKind
    let link: String                // the video's canonical link, or the playlist's
    let youtubeID: String?          // a YouTube video, or
    let playlist: PlaylistLink?     // a playlist (it opens Prepare, which still needs its own Queue)
    var title: String? = nil
    var channel: String? = nil

    static let maxLink = 2048

    static func parse(_ url: URL) -> Result<ExternalRequest, Refusal> {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme?.lowercased() == "videobuddy",
              c.host?.lowercased() == "request", c.path.isEmpty || c.path == "/",
              c.user == nil, c.password == nil, c.port == nil, c.fragment == nil else {
            return .failure(Refusal(reason: "it isn't a videobuddy://request link"))
        }
        let items = c.queryItems ?? []
        guard items.count == 2, Set(items.map(\.name)) == ["url", "action"] else {
            return .failure(Refusal(reason: "it must have exactly a link and an action"))
        }
        let value = { (name: String) in items.first { $0.name == name }?.value ?? "" }
        let kind: JobKind
        switch value("action") {
        case "video": kind = .video
        case "audio": kind = .audio
        case "summarize": kind = .summary
        default: return .failure(Refusal(reason: "it asks for something Video Buddy doesn't do"))
        }
        let link = value("url")
        guard !link.isEmpty, link.count <= maxLink, let scheme = URLComponents(string: link)?.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return .failure(Refusal(reason: "its link isn't a web link"))
        }
        if let id = VideoRef.parse(link)?.youtubeID {
            return .success(ExternalRequest(kind: kind, link: BrowserPolicy.watchURL(id), youtubeID: id, playlist: nil))
        }
        if let playlist = PlaylistLink.parse(link) {
            return .success(ExternalRequest(kind: kind, link: playlist.url, youtubeID: nil, playlist: playlist))
        }
        return .failure(Refusal(reason: "only YouTube videos and playlists can be sent to Video Buddy"))
    }
}

/// 4.0 G1b: "Download another copy?", saying what's on this Mac and what would come. Nothing happens without a click.
struct CopyPrompt {
    let request: DownloadRequest
    let files: [FileItem]
    let title: String, message: String, confirm: String
    let sameQuality: Bool

    /// existing: the resolution of each video copy here (nil when unknown); coming: the resolution the request would
    /// get (nil when unknown); quality: the setting's name. Pure (self-tested).
    static func wording(role: FileItem.Role, names: [String], existing: [Int?], coming: Int?, quality: String)
        -> (title: String, message: String, confirm: String, same: Bool) {
        let files = names.map { "“\($0)”" }.joined(separator: ", ")
        guard role == .video else {
            return ("Download another copy?", "This audio is already on this Mac (\(files)). Another MP3 is a separate file; the one you have stays.",
                    "Download Another MP3", false)
        }
        let here = existing.compactMap { $0 }
        let haveText = here.isEmpty ? "" : " at " + Array(Set(here)).sorted().map { "\($0)p" }.joined(separator: " and ")
        if let c = coming, here.contains(c) {
            return ("Already on this Mac at \(c)p",
                    "This video is already on this Mac\(haveText) (\(files)). \(quality) gives \(c)p for this video, so another copy would be the same quality.",
                    "Download Same Quality Again", true)
        }
        if let c = coming {
            return ("Download a \(c)p copy too?",
                    "This video is on this Mac\(haveText) (\(files)). A \(c)p copy is a separate file; the ones you have stay.",
                    "Download \(c)p Copy", false)
        }
        return ("Download another copy?",
                "This video is already on this Mac\(haveText) (\(files)). Another copy at your Video quality setting (\(quality)) is a separate file; the ones you have stay.",
                "Download Another Copy", false)
    }
}

struct DownloadRequest {
    let action: JobAction
    let youtubeID: String?           // nil: not a YouTube video (3.1's behaviour)
    var link: String? = nil          // a pasted link (a new library entry), or
    var videoID: Int64? = nil        // an existing library entry
    var format: SummaryFormat? = nil
    var language: SummaryLanguage? = nil
    /// You confirmed another copy of a file that's already on this Mac.
    var anotherCopy = false
}

/// 4.0 Phase 4: one video in Prepare for Offline, and what you chose for it.
struct PrepareRow: Identifiable, Equatable {
    let id: String                   // the YouTube id
    var title: String?
    var include = true
    var kind = JobKind.video         // .video or .audio
}

struct PrepareState: Identifiable {
    let id = UUID()
    var rows: [PrepareRow]
    let source: String
}

/// What a Prepare row can do now (pure, self-tested): only `.ready` is queued.
enum PrepareRule {
    enum Status: Equatable { case haveIt, queued, checking, needsDeclaration, unavailable(String), unknown(String), ready }

    /// `refused`: why this build won't queue it at all (the RC's live-test list), whatever the checks say.
    static func status(kind: JobKind, availability a: VideoAvailability, gate: DownloadGate.Decision?, refused: String? = nil) -> Status {
        if kind == .video ? a.videoFile != nil : a.audioFile != nil { return .haveIt }
        if (kind == .video ? a.video : a.audio) == .queued || (kind == .video ? a.video : a.audio) == .running { return .queued }
        if let refused { return .unavailable(refused) }
        switch gate {
        case nil: return .checking
        case let .blocked(r)?: return .unavailable(r)
        case let .unknown(r)?: return .unknown(r)
        case .needsDeclaration?: return .needsDeclaration
        case .allowed?: return .ready
        }
    }
}

struct PlaylistImportState: Identifiable {
    let id = UUID()
    let preview: PlaylistPreview
    let action: JobAction
    var checking: Int64? = nil
    var linkOnly = false
}

enum NamePrompt: Identifiable {
    case new(adding: Int64?)
    case rename(PlaylistSummary)
    var id: String {
        switch self {
        case let .new(v): "new-\(v ?? 0)"
        case let .rename(p): "rename-\(p.id)"
        }
    }
}

struct OfflineBatch: Identifiable {
    let id = UUID()
    let videoIDs: [Int64]
    let totalDuration: Double
}

enum DiskSpace {
    /// Space macOS can free up for important files on the volume holding `path` (what Finder shows as available).
    static func free(at path: String) -> Int64? {
        if let test = FakeRunner.freeSpace(at: path) { return test }
        return (try? existing(path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// Where downloads are put together before they're moved into place (the scripts make their temporary folder here).
    static var temporaryFolder: String { NSTemporaryDirectory() }

    /// Whether two folders are on the same volume (a download put together on one and kept on another needs room on both).
    static func sameVolume(_ a: String, _ b: String) -> Bool {
        if FakeRunner.enabled, ProcessInfo.processInfo.environment["VS_TEST_SEPARATE_VOLUMES"] == "1" { return false }
        let id = { (p: String) in (try? existing(p).resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier.map { "\($0)" } }
        return id(a) != nil && id(a) == id(b)
    }

    /// The nearest folder of `path` that exists.
    private static func existing(_ path: String) -> URL {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 { url.deleteLastPathComponent() }
        return url
    }
}
