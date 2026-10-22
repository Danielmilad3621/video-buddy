// 4.0 Phase 1: one browser tab. It owns its WKWebView (not a SwiftUI view, so switching sections never destroys the
// page), mirrors the web view's state through KVO, and applies BrowserPolicy to every navigation.
// Phase 2: a tab can sleep (no web view: only its address, title and WebKit's saved history) and wake where it was.
import AppKit
import WebKit

@MainActor @Observable
final class BrowserTab: NSObject, Identifiable {
    let id: UUID
    private(set) var webView: WKWebView?
    private(set) var url: URL?
    private(set) var title = ""
    /// The address the title was read at: during YouTube's in-page navigation the address changes first, so a title
    /// from the previous video is never shown as the new one's.
    private(set) var titleURL: URL?
    private(set) var isLoading = false
    private(set) var progress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isFullscreen = false
    /// Bumped when full screen ends, so the window's container takes the web view back (WebKit moved it out).
    private(set) var reattachToken = 0
    /// What the current address is (updates on YouTube's in-page navigation too, through `url`).
    private(set) var page = YouTubePage.blank
    /// The last failed load, shown over the page with Retry.
    private(set) var loadError: String?
    /// Test evidence: every page change and policy decision, newest last.
    private(set) var log: [String] = []
    /// Links sent to the default browser (recorded, not opened, in test runs).
    private(set) var externalOpens: [String] = []

    /// The tab whose link opened this one (link tabs line up after it, as in Safari).
    @ObservationIgnored var openerID: UUID?
    /// When it was last the active tab: the least recently used live tab sleeps first.
    @ObservationIgnored var lastActive = Date()
    @ObservationIgnored weak var browser: BrowserController?
    /// A sleeping tab's history, scroll position and form data (WebKit's opaque interactionState), to wake with.
    @ObservationIgnored private var savedState: Data?
    /// Opened by the page (target=_blank, window.open in a click): if it only sends its page outside YouTube, it closes.
    @ObservationIgnored var openedByPage = false

    private static let recordExternalOnly = ProcessInfo.processInfo.environment["VS_TEST_HOOKS"] == "1"
    private var observations: [NSKeyValueObservation] = []

    var isAsleep: Bool { webView == nil }

    /// A tab starts asleep: it gets its web view when it's first shown.
    init(id: UUID = UUID(), url: URL?, title: String = "", state: Data? = nil) {
        self.id = id
        super.init()
        self.url = url
        self.title = title
        titleURL = url
        savedState = state
        page = BrowserPolicy.classify(url)
    }

    /// Gives the tab a web view again: its saved history comes back (WebKit loads the page it was on), or its address
    /// loads. `adopting`: WebKit made this configuration for a page's new window and loads that page itself.
    @discardableResult
    func wake(_ configuration: WKWebViewConfiguration, adopting: Bool = false) -> WKWebView {
        if let webView { return webView }
        let view = TabWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view
        observe(view)
        if adopting { note("opened by the page: \(url?.absoluteString ?? "-")"); return view }
        if let savedState { view.interactionState = savedState }
        // nothing saved, or WebKit couldn't read it (its format can change with a macOS update): the address instead
        if view.backForwardList.currentItem == nil { load(url ?? BrowserPolicy.home) }
        note(savedState == nil ? "awake: \(url?.absoluteString ?? "-")" : "awake with its history")
        savedState = nil
        return view
    }

    /// What reopening, duplicating or sleeping keeps: the history as it is now (awake) or as saved (asleep).
    var snapshot: (url: URL?, state: Data?) {
        BrowserController.keep(page: page, url: url, state: (webView?.interactionState as? Data) ?? savedState)
    }

    /// Lets the web view go (and with it the tab's web process and its memory), keeping what it needs to come back.
    func sleep() {
        guard webView != nil else { return }
        let kept = snapshot
        release()
        savedState = kept.state
        if kept.url != url { urlChanged(kept.url) }
        note("asleep")
    }

    private func observe(_ v: WKWebView) {
        observations = [
            // no .initial: a new web view has no address yet, and a sleeping tab's own stays until the page loads
            v.observe(\.url, options: [.new]) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.urlChanged(v.url) }
            },
            v.observe(\.title, options: [.new]) { [weak self] v, _ in
                MainActor.assumeIsolated { self?.title = v.title ?? ""; self?.titleURL = v.url }
            },
            v.observe(\.isLoading, options: [.new]) { [weak self] v, _ in MainActor.assumeIsolated { self?.isLoading = v.isLoading } },
            v.observe(\.estimatedProgress, options: [.new]) { [weak self] v, _ in MainActor.assumeIsolated { self?.progress = v.estimatedProgress } },
            v.observe(\.canGoBack, options: [.new]) { [weak self] v, _ in MainActor.assumeIsolated { self?.canGoBack = v.canGoBack } },
            v.observe(\.canGoForward, options: [.new]) { [weak self] v, _ in MainActor.assumeIsolated { self?.canGoForward = v.canGoForward } },
            v.observe(\.fullscreenState, options: [.new]) { [weak self] v, _ in
                MainActor.assumeIsolated {
                    self?.isFullscreen = v.fullscreenState == .inFullscreen || v.fullscreenState == .enteringFullscreen
                    if v.fullscreenState == .notInFullscreen { self?.reattachToken += 1 }
                    self?.note("fullscreen: \(v.fullscreenState.rawValue)")
                }
            },
        ]
    }

    private func urlChanged(_ new: URL?) {
        guard new != url else { return }
        url = new
        let old = page
        page = BrowserPolicy.classify(new)
        browser?.tabChanged(self, pageChanged: page != old)
        note("url: \(new?.absoluteString ?? "-") → \(page.label)\(page.videoID.map { " \($0)" } ?? "")")
    }

    func note(_ line: String) {
        let stamp = Date().formatted(.dateTime.hour().minute().second())
        log.append("\(stamp) \(line)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    // MARK: navigation

    func load(_ target: URL) {
        loadError = nil
        webView?.load(URLRequest(url: target))
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() {
        loadError = nil
        if isLoading { webView?.stopLoading() } else { webView?.reload() }
    }

    func openExternally(_ link: URL) {
        externalOpens.append(link.absoluteString)
        note("outside: \(link.absoluteString)")
        if !Self.recordExternalOnly { NSWorkspace.shared.open(link) }
    }

    /// Lets go of the web view at once (so a wake that comes in meanwhile is never undone), then stops what it was doing.
    @discardableResult
    private func release() -> Task<Void, Never>? {
        guard let v = webView else { return nil }
        observations.forEach { $0.invalidate() }
        observations = []
        v.navigationDelegate = nil
        v.uiDelegate = nil
        v.removeFromSuperview()
        webView = nil
        isLoading = false
        progress = 0
        isFullscreen = false
        return Task {
            v.stopLoading()
            await v.pauseAllMediaPlayback()
            await v.closeAllMediaPresentations()
        }
    }

    /// Stops everything and lets go of the web view (and its web process). Done before its data store is removed.
    func close() async { await release()?.value }
}

extension BrowserTab: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let target = action.request.url else { return .cancel }
        let main = action.targetFrame?.isMainFrame ?? true
        let decision = BrowserPolicy.decide(target, mainFrame: main)
        if main { note("navigate \(decision): \(target.absoluteString)") }
        switch decision {
        case .allow:
            if action.navigationType == .linkActivated,
               let mode = BrowserPolicy.newTab(command: action.modifierFlags.contains(.command), shift: action.modifierFlags.contains(.shift),
                                               button: action.buttonNumber) {
                note("new tab, \(mode) (button \(action.buttonNumber)): \(target.absoluteString)")
                browser?.open(target, background: mode == .background, from: self)
                return .cancel
            }
            return .allow
        case .openExternally:
            openExternally(target)
            // a tab a page opened only to leave YouTube (description links go through youtube.com/redirect) closes again
            if main, openedByPage, !webView.canGoBack { Task { self.browser?.closeFromPage(self) } }
            return .cancel
        case .cancel: return .cancel
        }
    }

    /// Anything the page can't show is a download; the YouTube section never downloads files.
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if response.isForMainFrame, !response.canShowMIMEType {
            note("refused download: \(response.response.url?.absoluteString ?? "-")")
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }

    private func failed(_ error: Error) {
        let e = error as NSError
        // a navigation the policy cancelled (outside link) or a newer navigation isn't an error
        guard !(e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled), e.code != 102 else { return }
        loadError = e.code == NSURLErrorNotConnectedToInternet ? "You're offline." : e.localizedDescription
        note("load failed: \(e.domain) \(e.code) \(e.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        note("web process ended; reloading")
        webView.reload()
    }

    /// target=_blank and window.open in a click: a YouTube page opens in a new tab (in front; behind with ⌘), built
    /// from the configuration WebKit passes (it must be), which keeps the page's link to its opener. Others open outside.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let target = action.request.url else { note("refused a new window without an address"); return nil }
        guard BrowserPolicy.decide(target, mainFrame: true) == .allow else { openExternally(target); return nil }
        let mode = BrowserPolicy.newTab(command: action.modifierFlags.contains(.command), shift: action.modifierFlags.contains(.shift),
                                        button: action.buttonNumber) ?? .foreground
        note("new window → \(mode) tab: \(target.absoluteString)")
        return browser?.adopt(configuration, url: target, background: mode == .background, from: self)
    }

    /// The page closed its own window (window.close()).
    func webViewDidClose(_ webView: WKWebView) {
        note("the page closed its window")
        browser?.closeFromPage(self)
    }

    /// The YouTube section never uses the camera or microphone.
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
                 type: WKMediaCaptureType) async -> WKPermissionDecision {
        note("refused \(type == .camera ? "camera" : "microphone") for \(origin.host)")
        return .deny
    }
}

/// The page's right-click menu, Video Buddy's way: "Open Link in New Window" opens a tab, and WebKit's download items
/// are gone (the YouTube section never downloads). WebKit's item identifiers aren't public API: items it names
/// differently are left as they are.
final class TabWebView: WKWebView {
    /// Test evidence: the last menu shown, as "identifier: title".
    static var lastMenu: [String] = []

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items {
            let id = item.identifier?.rawValue ?? ""
            if id.hasPrefix("WKMenuItemIdentifierDownload") { menu.removeItem(item) }
            else if id == "WKMenuItemIdentifierOpenLinkInNewWindow" { item.title = "Open Link in New Tab" }
        }
        Self.lastMenu = menu.items.map { "\($0.identifier?.rawValue ?? "-"): \($0.title)" }
        // a test run closes it again by itself, as Escape would (nobody is at the mouse)
        if TestProbes.enabled {
            let close = Timer(timeInterval: 0.8, repeats: false) { _ in menu.cancelTracking() }
            RunLoop.main.add(close, forMode: .common)
        }
    }
}
