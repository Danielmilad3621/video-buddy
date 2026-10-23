// 4.0 Phase 1: the YouTube section's browser: its own WebKit data store per data folder (cookies, cache, local
// storage), kept apart from everything else, and the rule that only one thing plays at a time.
// Phase 2: tabs. They share that one data store (one sign-in), sleep when they aren't needed, and the action bar only
// ever acts for the active tab's own video.
import AppKit
import WebKit

@MainActor @Observable
final class BrowserController {
    /// The tabs, in the order shown.
    private(set) var tabs: [BrowserTab] = []
    private(set) var activeID: UUID?
    /// Recently closed tabs, newest last (in memory only), for Reopen Closed Tab.
    private(set) var closed: [ClosedTab] = []
    var active: BrowserTab? { tabs.first { $0.id == activeID } }
    /// The inactive tab that keeps playing (Settings → background audio), shown with a speaker; nil when none is.
    private(set) var audioTabID: UUID?
    var audioTab: BrowserTab? { tabs.first { $0.id == audioTabID && !$0.isAsleep } }
    /// The active tab (Phase 1's name, kept for the menu commands and test hooks).
    var tab: BrowserTab? { active }
    /// The visible tab's media, checked about once a second while the YouTube section is shown: "playing" only when a
    /// video or audio element is really playing with sound.
    private(set) var mediaState = "none"
    /// What WebKit's own requestMediaPlaybackState says (kept for comparison: on YouTube it reports "playing" even
    /// when every element is paused, so it can't drive the one-player rule).
    private(set) var webkitMediaState = "none"
    /// The result of the last Clear Browsing Data, for the UI and the tests.
    private(set) var clearReport: String?
    var onWebPlaying: () -> Void = {}
    /// 4.0 Phase 1b: the technical check for the video on screen (metadata only), results kept per video id.
    let checker = AvailabilityChecker { id in
        // the test build's fake runner never looks anything up: its checks come from the test's control file
        FakeRunner.enabled ? FakeRunner.check(id) : await MetadataFetcher.platformCheck(BrowserPolicy.watchURL(id))
    }
    /// The active tab's page changed, or another tab became active (the action bar's checks follow it).
    @ObservationIgnored var onPageChange: (YouTubePage) -> Void = { _ in }
    @ObservationIgnored var onNotice: (String) -> Void = { _ in }
    /// The id of the video in the active tab right now (what every action is checked against at the moment of a click).
    var currentVideoID: String? { active?.page.videoID }

    static let maxTabs = 50
    static let maxClosed = 20
    /// ponytail: a count, not a measure (WebKit gives no per-tab memory figure). Each live tab is a web process of
    /// roughly 150–400 MB on a YouTube watch page; 4 was calibrated with Activity Monitor (3 would suit an 8 GB Mac).
    nonisolated static let maxLiveTabs = 4

    private let storeFile: URL
    /// The tabs, saved after every change (no cookies: those stay in the data store).
    private let sessionFile: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveFailed = false
    private let testMode = ProcessInfo.processInfo.environment["VS_TEST_HOOKS"] == "1"
    private var poll: Timer?
    /// The YouTube section is on screen (tabs only get a web view then).
    private var isShown = false
    /// One data store for every tab: one cookie jar, so one sign-in.
    private var dataStore: WKWebsiteDataStore?
    private let memory = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
    /// Test runs play videos muted (so the Mac stays silent) and count that as playing.
    private let mutedCounts = ProcessInfo.processInfo.environment["VS_TEST_MUTED_PLAYS"] == "1"

    init(dataDir: URL) {
        storeFile = dataDir.appendingPathComponent("browser/website-data-id")
        sessionFile = dataDir.appendingPathComponent("browser/tabs.json")
        memory.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.memoryWarning() } }
        memory.activate()
    }

    /// The id already saved, without making one (for reports).
    var existingStoreID: String? { (try? String(contentsOf: storeFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The data store's id, made once per data folder (so a test folder, or later a Fresh Start profile, has its own).
    var storeID: UUID {
        if let text = try? String(contentsOf: storeFile, encoding: .utf8), let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return id
        }
        let id = UUID()
        try? FileManager.default.createDirectory(at: storeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? id.uuidString.write(to: storeFile, atomically: true, encoding: .utf8)
        return id
    }

    private func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        let store = dataStore ?? WKWebsiteDataStore(forIdentifier: storeID)
        dataStore = store
        config.websiteDataStore = store
        config.preferences.isElementFullscreenEnabled = true
        // only a click opens a tab: on macOS WebKit would otherwise let scripts (ads too) open windows by themselves
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // tabs out of sight that aren't playing or loading are fully suspended: no scripts, no layout
        config.preferences.inactiveSchedulingPolicy = .suspend
        // restored or background pages never start playing by themselves; a click on the page does
        config.mediaTypesRequiringUserActionForPlayback = .all
        // honest: WebKit's own user agent plus our name, never another browser's (VS_BROWSER_UA=default leaves it as is)
        if ProcessInfo.processInfo.environment["VS_BROWSER_UA"] != "default" { config.applicationNameForUserAgent = "VideoBuddy/4.0" }
        return config
    }

    /// The active tab (YouTube Home if there are none), awake while the YouTube section is shown.
    @discardableResult
    func ensureTab() -> BrowserTab {
        if active == nil {
            if tabs.isEmpty { insert(make(BrowserPolicy.home), at: 0) }
            activeID = tabs[0].id
        }
        let t = active!
        if isShown { wake(t) }
        return t
    }

    /// The address field and the test hook: a link, or a YouTube search, in the active tab.
    func go(_ typed: String) {
        guard let target = BrowserPolicy.address(typed) else { return }
        let t = ensureTab()
        if BrowserPolicy.decide(target, mainFrame: true) == .openExternally { t.openExternally(target); return }
        wake(t)
        t.load(target)
    }

    /// Every tab's media (the native player is starting, or the section is left without background audio).
    func pauseAll() {
        tabs.forEach(pause)
        audioTabID = nil
    }

    /// The tab strip's speaker.
    func pause(_ t: BrowserTab) {
        t.webView?.pauseAllMediaPlayback()
        if t.media == "playing" { t.media = "paused" }
        if audioTabID == t.id { audioTabID = nil }
    }

    // MARK: tabs

    /// ⌘T, a pasted link, a ⌘-click: a new tab, after the tab it came from (and that tab's earlier link tabs), or last.
    /// One opened behind stays asleep (no web view, nothing playing) until you select it.
    func open(_ url: URL = BrowserPolicy.home, background: Bool = false, from opener: BrowserTab? = nil) {
        let t = make(url)
        t.openerID = opener?.id
        guard insert(t, at: position(after: opener)) else { return }
        if background { scheduleSave() } else { select(t) }
    }

    /// A page's new window (target=_blank, window.open in a click): WebKit made its configuration and loads it itself.
    func adopt(_ configuration: WKWebViewConfiguration, url: URL, background: Bool, from opener: BrowserTab) -> WKWebView? {
        let t = make(url)
        t.openerID = opener.id
        t.openedByPage = true
        guard insert(t, at: position(after: opener)) else { return nil }
        let view = t.wake(configuration, adopting: true)
        if background { enforceLimit(); scheduleSave() } else { select(t) }
        return view
    }

    /// A page closed its own window, or a tab only sent its page outside: it goes (not to Reopen Closed Tab), and
    /// the tab that opened it comes back to the front.
    func closeFromPage(_ t: BrowserTab) {
        close(t, remember: false, next: tabs.first { $0.id == t.openerID })
    }

    func select(_ t: BrowserTab) {
        // full screen shows one tab's page outside the window: no switching until it ends
        guard t.id != activeID, tabs.contains(where: { $0 === t }), active?.isFullscreen != true else { return }
        let previous = active
        previous?.lastActive = Date()
        activeID = t.id
        t.lastActive = Date()
        if audioTabID == t.id { audioTabID = nil }
        if let previous { leave(previous) }
        mediaState = "none"
        if isShown { wake(t) }
        onPageChange(t.page)
        scheduleSave()
    }

    /// Closes a tab (it can be reopened); the next tab to the right becomes active, else the one to the left.
    /// The last tab closed leaves a fresh Home tab.
    /// `next`: the tab to show instead of the neighbour, if the closed one was active.
    func close(_ t: BrowserTab, remember: Bool = true, next preferred: BrowserTab? = nil) {
        guard let i = tabs.firstIndex(where: { $0 === t }), !t.isFullscreen else { return }
        if remember {
            let s = t.snapshot
            closed.append(ClosedTab(url: s.url, title: t.title, state: s.state, index: i))
            if closed.count > Self.maxClosed { closed.removeFirst(closed.count - Self.maxClosed) }
        }
        let next = t.id != activeID ? nil : preferred.flatMap { p in tabs.contains { $0 === p } ? p : nil }
            ?? Self.afterClose(i, count: tabs.count).map { tabs[$0] }
        tabs.remove(at: i)
        if audioTabID == t.id { audioTabID = nil }
        Task { await t.close() }
        if tabs.isEmpty {
            activeID = nil
            open()
        } else if let next {
            select(next)
        }
        scheduleSave()
    }

    func closeActive() { if let t = active { close(t) } }

    func move(_ t: BrowserTab, to index: Int) {
        guard let i = tabs.firstIndex(where: { $0 === t }) else { return }
        let to = min(max(index, 0), tabs.count - 1)
        guard to != i else { return }
        tabs.remove(at: i)
        tabs.insert(t, at: to)
        scheduleSave()
    }

    /// A copy right after it, with its history, made active.
    func duplicate(_ t: BrowserTab) {
        guard let i = tabs.firstIndex(where: { $0 === t }) else { return }
        let s = t.snapshot
        let copy = make(s.url, title: t.title, state: s.state)
        if insert(copy, at: i + 1) { select(copy) }
    }

    /// The last closed tab, back where it was, with its history.
    func reopenClosed() {
        guard let c = closed.popLast() else { return }
        let t = make(c.url, title: c.title, state: c.state)
        if insert(t, at: c.index) { select(t) } else { closed.append(c) }
    }

    /// ⌃Tab / ⌃⇧Tab: the next or previous tab, round the end.
    func selectTab(offset: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == activeID }), tabs.count > 1 else { return }
        select(tabs[(i + offset + tabs.count) % tabs.count])
    }

    /// ⌘1–⌘8: that tab, if there is one; ⌘9: the last tab.
    func selectTab(number n: Int) {
        if n == 9, let last = tabs.last { select(last) } else if (1...tabs.count).contains(n) { select(tabs[n - 1]) }
    }

    /// A tab's address changed (it calls this itself).
    func tabChanged(_ t: BrowserTab, pageChanged: Bool) {
        if pageChanged, t.id == activeID { onPageChange(t.page) }
        scheduleSave()
    }

    // MARK: saving and restoring

    /// At launch: the tabs as they were, all asleep (no web view, no web process) until the YouTube section shows the
    /// active one, so a page can't crash the launch. A file it can't read is kept aside; YouTube starts with one tab.
    /// Returns what to tell you, if anything.
    func restore() -> String? {
        guard let data = try? Data(contentsOf: sessionFile) else { return nil }
        guard let s = TabSession.decode(data) else {
            let aside = sessionFile.deletingLastPathComponent().appendingPathComponent("tabs.corrupt.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: sessionFile, to: aside)
            return "Your YouTube tabs couldn't be restored (their saved list was damaged), so YouTube starts with one tab. The damaged list was kept as tabs.corrupt.json."
        }
        tabs = s.tabs.prefix(Self.maxTabs).map { make($0.url, title: $0.title, state: $0.state, id: $0.id) }
        activeID = tabs.contains { $0.id == s.active } ? s.active : tabs.first?.id
        return nil
    }

    /// After a change, at most once a second.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// The whole list, written atomically (never half a file). Also called when the app quits.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard !tabs.isEmpty else { return }
        let session = TabSession(active: activeID, tabs: tabs.compactMap { t in
            let kept = t.snapshot
            return kept.url.map { TabSession.Saved(id: t.id, url: $0, title: t.title, state: kept.state) }
        })
        do {
            try FileManager.default.createDirectory(at: sessionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(session).write(to: sessionFile, options: .atomic)
            saveFailed = false
        } catch {
            // said once, not every second
            if !saveFailed { onNotice("Your YouTube tabs couldn't be saved: \(error.localizedDescription)") }
            saveFailed = true
        }
    }

    private func make(_ url: URL?, title: String = "", state: Data? = nil, id: UUID = UUID()) -> BrowserTab {
        let t = BrowserTab(id: id, url: url, title: title, state: state)
        t.browser = self
        return t
    }

    @discardableResult
    private func insert(_ t: BrowserTab, at index: Int) -> Bool {
        guard tabs.count < Self.maxTabs else {
            onNotice("\(Self.maxTabs) tabs are open, the most Video Buddy keeps. Close one to open another.")
            return false
        }
        tabs.insert(t, at: min(max(index, 0), tabs.count))
        return true
    }

    private func position(after opener: BrowserTab?) -> Int {
        guard let opener, let i = tabs.firstIndex(where: { $0 === opener }) else { return tabs.count }
        return Self.insertIndex(opener: i, openerID: opener.id, openers: tabs.map(\.openerID))
    }

    private func wake(_ t: BrowserTab) {
        guard t.isAsleep else { return }
        t.wake(configuration())
        enforceLimit()
    }

    /// A tab that stops being active pauses, unless background audio is on and it's playing: then it's the audio tab
    /// (and the one before it pauses: one thing plays at a time).
    private func leave(_ t: BrowserTab) {
        guard !t.isAsleep else { return }
        if UserDefaults.standard.bool(forKey: "browserBackgroundAudio"), t.media == "playing" {
            if let old = audioTab, old !== t { pause(old) }
            audioTabID = t.id
        } else {
            pause(t)
        }
    }

    // MARK: memory

    /// At most `cap` live web views: the least recently used tabs sleep first, never the active tab, the audio tab or
    /// one in the middle of signing in.
    private func enforceLimit(cap: Int = maxLiveTabs) {
        let live = tabs.filter { !$0.isAsleep }.map { t in
            (id: t.id, lastActive: t.lastActive, protected: t.id == activeID || t.id == audioTabID || t.page == .signIn || t.page == .consent)
        }
        let sleepers = Set(Self.toSleep(live, cap: cap))
        for t in tabs where sleepers.contains(t.id) { t.sleep() }
    }

    /// macOS is short of memory: every tab that can sleeps.
    func memoryWarning() {
        let before = tabs.filter { !$0.isAsleep }.count
        enforceLimit(cap: 0)
        let slept = before - tabs.filter { !$0.isAsleep }.count
        if slept > 0 {
            onNotice("Your Mac is short of memory, so \(slept) background \(slept == 1 ? "tab was" : "tabs were") put to sleep. Each reloads when you select it.")
        }
    }

    // MARK: the rules (pure, self-tested)

    /// Where a tab opened from the tab at `opener` goes: after it and the link tabs it already opened (Safari's order).
    /// `openers` is each tab's opener id, in tab order.
    nonisolated static func insertIndex(opener: Int, openerID: UUID, openers: [UUID?]) -> Int {
        guard openers.indices.contains(opener) else { return openers.count }
        var i = opener + 1
        while i < openers.count, openers[i] == openerID { i += 1 }
        return i
    }

    /// The tab that becomes active after closing the one at `index` of `count`: the next, else the previous.
    nonisolated static func afterClose(_ index: Int, count: Int) -> Int? {
        count <= 1 ? nil : index < count - 1 ? index + 1 : index - 1
    }

    /// Which live tabs sleep so that at most `cap` stay live: the least recently used unprotected ones.
    nonisolated static func toSleep(_ live: [(id: UUID, lastActive: Date, protected: Bool)], cap: Int) -> [UUID] {
        let extra = live.count - cap
        guard extra > 0 else { return [] }
        return live.filter { !$0.protected }.sorted { $0.lastActive < $1.lastActive }.prefix(extra).map(\.id)
    }

    /// Saved history is kept up to this size; past it, a tab keeps only its address.
    nonisolated static let maxSavedState = 512 * 1024

    /// What a tab keeps when it sleeps, closes or is duplicated. Sign-in and consent pages keep only YouTube Home:
    /// their addresses carry one-time tokens.
    nonisolated static func keep(page: YouTubePage, url: URL?, state: Data?) -> (url: URL?, state: Data?) {
        switch page {
        case .signIn, .consent: (BrowserPolicy.home, nil)
        default: (url, (state?.count ?? 0) <= maxSavedState ? state : nil)
        }
    }

    // MARK: the YouTube section shown / hidden

    func shown() {
        isShown = true
        ensureTab()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMedia() }
        }
    }

    func hidden(allowBackgroundAudio: Bool) {
        isShown = false
        poll?.invalidate()
        poll = nil
        if !allowBackgroundAudio { pauseAll() }
    }

    /// A read-only look at the page's media elements, in a script world of our own (the page's scripts can't see or
    /// change it). Muted previews don't count; nothing is injected into or changed on the page.
    private static func audiblePlayback(mutedCounts: Bool) -> String {
        let audible = mutedCounts ? "true" : "!m.muted && m.volume > 0"
        return """
            [...document.querySelectorAll('video, audio')].some(m => !m.paused && !m.ended && \(audible) && m.readyState > 2) ? 'playing'
            : (document.querySelector('video, audio') ? 'paused' : 'none')
            """
    }

    /// The active tab and the audio tab only (a suspended tab would answer late, and nothing else can be playing).
    private func checkMedia() {
        guard let a = active, let v = a.webView else { mediaState = "none"; return }
        check(a) { [weak self] state in
            self?.mediaState = state
            guard state == "playing", let self else { return }
            self.onWebPlaying()
            // the active tab started: the one playing in the background stops
            if let old = self.audioTab, old !== a { self.pause(old) }
        }
        if let au = audioTab {
            check(au) { [weak self] state in if state != "playing", self?.audioTabID == au.id { self?.audioTabID = nil } }
        }
        v.requestMediaPlaybackState { [weak self] state in
            self?.webkitMediaState = switch state {
            case .playing: "playing"
            case .paused: "paused"
            case .suspended: "suspended"
            default: "none"
            }
        }
    }

    private func check(_ t: BrowserTab, then: @escaping (String) -> Void) {
        guard let v = t.webView, !t.mediaCheckPending else { return }
        t.mediaCheckPending = true
        v.evaluateJavaScript(Self.audiblePlayback(mutedCounts: mutedCounts), in: nil, in: .world(name: "VideoBuddy")) { [weak t] result in
            MainActor.assumeIsolated {
                guard let t else { return }
                t.mediaCheckPending = false
                let state = (try? result.get()) as? String ?? "none"
                t.media = state
                then(state)
            }
        }
    }

    /// Test evidence: the names (never the values) of the cookies in the data store.
    func cookieNames() async -> [String] {
        guard let store = dataStore else { return [] }
        return await store.httpCookieStore.allCookies().map { "\($0.domain):\($0.name)" }.sorted()
    }

    // MARK: clearing

    /// Releases the web view first, then removes every kind of website data and the data store itself (WebKit refuses
    /// while anything still uses the store, so our own reference is dropped first and removal is retried), and checks
    /// WebKit no longer lists it. Every step is reported.
    func clearBrowsingData() async {
        let id = storeID
        poll?.invalidate()
        poll = nil
        // no save after this (it would write the tabs back)
        saveTask?.cancel()
        saveTask = nil
        // every tab's web view first: WebKit won't remove a store anything still uses
        let all = tabs
        tabs = []
        activeID = nil
        audioTabID = nil
        closed = []
        for t in all { await t.close() }
        dataStore = nil
        var report = ["web views released (\(all.count) \(all.count == 1 ? "tab" : "tabs"))"]
        await Self.removeAllData(id)
        report.append("website data removed")
        var removed = false
        for attempt in 1...4 {
            try? await Task.sleep(for: .seconds(1))
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: id)
                removed = true
                report.append("data store \(id.uuidString) removed (attempt \(attempt))")
                break
            } catch {
                report.append("attempt \(attempt): \(error.localizedDescription)")
            }
        }
        if removed { try? FileManager.default.removeItem(at: storeFile) }
        // the saved tabs are browsing history too
        for f in [sessionFile, sessionFile.deletingLastPathComponent().appendingPathComponent("tabs.corrupt.json")] { try? FileManager.default.removeItem(at: f) }
        report.append(FileManager.default.fileExists(atPath: sessionFile.path) ? "saved tabs still there" : "saved tabs removed")
        let ids = await WKWebsiteDataStore.allDataStoreIdentifiers
        report.append(ids.contains(id) ? "store still listed by WebKit" : "store no longer listed by WebKit")
        clearReport = report.joined(separator: "; ")
    }

    /// In its own function, so the store object is gone once this returns.
    private static func removeAllData(_ id: UUID) async {
        let store = WKWebsiteDataStore(forIdentifier: id)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}

/// A closed tab, for Reopen Closed Tab: where it was and what it had.
struct ClosedTab {
    let url: URL?
    let title: String
    let state: Data?
    let index: Int
}

/// What tabs.json holds: each tab's address, title and WebKit's saved history (its back and forward list, scroll
/// positions and form data). No cookies or passwords: those stay in the data store.
struct TabSession: Codable, Equatable {
    var version = 1
    var active: UUID?
    var tabs: [Saved]

    struct Saved: Codable, Equatable {
        let id: UUID
        let url: URL
        let title: String
        let state: Data?
    }

    /// nil for a file that isn't a session this version can read (damaged, or written by a later version).
    static func decode(_ data: Data) -> TabSession? {
        guard let s = try? JSONDecoder().decode(TabSession.self, from: data), s.version == 1 else { return nil }
        return s
    }
}
