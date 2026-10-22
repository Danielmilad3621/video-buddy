// 4.0 Phase 1: the YouTube section's browser. One tab for now; its own WebKit data store per data folder (cookies,
// cache, local storage), kept apart from everything else; and the rule that only one thing plays at a time.
import AppKit
import WebKit

@MainActor @Observable
final class BrowserController {
    private(set) var tab: BrowserTab?
    /// The visible tab's media, checked about once a second while the YouTube section is shown: "playing" only when a
    /// video or audio element is really playing with sound.
    private(set) var mediaState = "none"
    /// What WebKit's own requestMediaPlaybackState says (kept for comparison: on YouTube it reports "playing" even
    /// when every element is paused, so it can't drive the one-player rule).
    private(set) var webkitMediaState = "none"
    /// The result of the last Clear Browsing Data, for the UI and the tests.
    private(set) var clearReport: String?
    var onWebPlaying: () -> Void = {}

    private let storeFile: URL
    private let testMode = ProcessInfo.processInfo.environment["VS_TEST_HOOKS"] == "1"
    private var poll: Timer?

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
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        config.preferences.isElementFullscreenEnabled = true
        // restored or background pages never start playing by themselves; a click on the page does
        config.mediaTypesRequiringUserActionForPlayback = .all
        // honest: WebKit's own user agent plus our name, never another browser's (VS_BROWSER_UA=default leaves it as is)
        if ProcessInfo.processInfo.environment["VS_BROWSER_UA"] != "default" { config.applicationNameForUserAgent = "VideoBuddy/4.0" }
        return config
    }

    @discardableResult
    func ensureTab() -> BrowserTab {
        if let tab { return tab }
        let t = BrowserTab(configuration: configuration(), recordExternalOnly: testMode)
        tab = t
        t.load(BrowserPolicy.home)
        return t
    }

    /// The address field and the test hook: a link, or a YouTube search.
    func go(_ typed: String) {
        guard let target = BrowserPolicy.address(typed) else { return }
        let t = ensureTab()
        if BrowserPolicy.decide(target, mainFrame: true) == .openExternally { t.openExternally(target) } else { t.load(target) }
    }

    func pauseAll() { tab?.webView?.pauseAllMediaPlayback() }

    // MARK: the YouTube section shown / hidden

    func shown() {
        ensureTab()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMedia() }
        }
    }

    func hidden(allowBackgroundAudio: Bool) {
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
        guard let v = tab?.webView else { mediaState = "none"; return }
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
        await tab?.close()
        tab = nil
        var report = ["web views released"]
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
