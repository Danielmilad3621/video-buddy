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
    let checker = AvailabilityChecker { id in await MetadataFetcher.platformCheck(BrowserPolicy.watchURL(id)) }
    /// The active tab's page changed, or another tab became active (the action bar's checks follow it).
    @ObservationIgnored var onPageChange: (YouTubePage) -> Void = { _ in }
    @ObservationIgnored var onNotice: (String) -> Void = { _ in }
    /// The id of the video in the active tab right now (what every action is checked against at the moment of a click).
    var currentVideoID: String? { active?.page.videoID }

    static let maxTabs = 50
    static let maxClosed = 20

    private let storeFile: URL
    private let testMode = ProcessInfo.processInfo.environment["VS_TEST_HOOKS"] == "1"
    private var poll: Timer?
    /// The YouTube section is on screen (tabs only get a web view then).
    private var isShown = false
    /// One data store for every tab: one cookie jar, so one sign-in.
    private var dataStore: WKWebsiteDataStore?

    init(dataDir: URL) {
        storeFile = dataDir.appendingPathComponent("browser/website-data-id")
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
    func pauseAll() { tabs.forEach { $0.webView?.pauseAllMediaPlayback() } }

    // MARK: tabs

    /// ⌘T, a pasted link, a ⌘-click: a new tab, after the tab it came from (and that tab's earlier link tabs), or last.
    /// One opened behind stays asleep (no web view, nothing playing) until you select it.
    func open(_ url: URL = BrowserPolicy.home, background: Bool = false, from opener: BrowserTab? = nil) {
        let t = make(url)
        t.openerID = opener?.id
        guard insert(t, at: position(after: opener)) else { return }
        if !background { select(t) }
    }

    func select(_ t: BrowserTab) {
        // full screen shows one tab's page outside the window: no switching until it ends
        guard t.id != activeID, tabs.contains(where: { $0 === t }), active?.isFullscreen != true else { return }
        let previous = active
        previous?.lastActive = Date()
        activeID = t.id
        t.lastActive = Date()
        previous?.webView?.pauseAllMediaPlayback()
        mediaState = "none"
        if isShown { wake(t) }
        onPageChange(t.page)
    }

    /// Closes a tab (it can be reopened); the next tab to the right becomes active, else the one to the left.
    /// The last tab closed leaves a fresh Home tab.
    func close(_ t: BrowserTab) {
        guard let i = tabs.firstIndex(where: { $0 === t }), !t.isFullscreen else { return }
        let s = t.snapshot
        closed.append(ClosedTab(url: s.url, title: t.title, state: s.state, index: i))
        if closed.count > Self.maxClosed { closed.removeFirst(closed.count - Self.maxClosed) }
        let next = t.id == activeID ? Self.afterClose(i, count: tabs.count).map { tabs[$0] } : nil
        tabs.remove(at: i)
        Task { await t.close() }
        if tabs.isEmpty {
            activeID = nil
            open()
        } else if let next {
            select(next)
        }
    }

    func closeActive() { if let t = active { close(t) } }

    func move(_ t: BrowserTab, to index: Int) {
        guard let i = tabs.firstIndex(where: { $0 === t }) else { return }
        let to = min(max(index, 0), tabs.count - 1)
        guard to != i else { return }
        tabs.remove(at: i)
        tabs.insert(t, at: to)
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
    }

    private func make(_ url: URL?, title: String = "", state: Data? = nil) -> BrowserTab {
        let t = BrowserTab(url: url, title: title, state: state)
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
    private static let audiblePlayback = """
        [...document.querySelectorAll('video, audio')].some(m => !m.paused && !m.ended && !m.muted && m.volume > 0 && m.readyState > 2) ? 'playing'
        : (document.querySelector('video, audio') ? 'paused' : 'none')
        """

    private func checkMedia() {
        guard let v = active?.webView else { mediaState = "none"; return }
        v.evaluateJavaScript(Self.audiblePlayback, in: nil, in: .world(name: "VideoBuddy")) { [weak self] result in
            MainActor.assumeIsolated {
                let state = (try? result.get()) as? String ?? "none"
                self?.mediaState = state
                if state == "playing" { self?.onWebPlaying() }
            }
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

    // MARK: clearing

    /// Releases the web view first, then removes every kind of website data and the data store itself (WebKit refuses
    /// while anything still uses the store, so our own reference is dropped first and removal is retried), and checks
    /// WebKit no longer lists it. Every step is reported.
    func clearBrowsingData() async {
        let id = storeID
        poll?.invalidate()
        poll = nil
        // every tab's web view first: WebKit won't remove a store anything still uses
        let all = tabs
        tabs = []
        activeID = nil
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
