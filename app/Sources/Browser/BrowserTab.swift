// 4.0 Phase 1: one browser tab. It owns its WKWebView (not a SwiftUI view, so switching sections never destroys the
// page), mirrors the web view's state through KVO, and applies BrowserPolicy to every navigation.
import AppKit
import WebKit

@MainActor @Observable
final class BrowserTab: NSObject {
    private(set) var webView: WKWebView?
    private(set) var url: URL?
    private(set) var title = ""
    /// The address the title was read at: during YouTube's in-page navigation the address changes first, so a title
    /// from the previous video is never shown as the new one's.
    private(set) var titleURL: URL?
    /// Called when the page kind or video changes (the action bar's checks follow it).
    @ObservationIgnored var onPageChange: (YouTubePage) -> Void = { _ in }
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

    private let recordExternalOnly: Bool
    private var observations: [NSKeyValueObservation] = []

    init(configuration: WKWebViewConfiguration, recordExternalOnly: Bool) {
        self.recordExternalOnly = recordExternalOnly
        super.init()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view
        observe(view)
    }

    private func observe(_ v: WKWebView) {
        observations = [
            v.observe(\.url, options: [.initial, .new]) { [weak self] v, _ in
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
        if page != old { onPageChange(page) }
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
        if !recordExternalOnly { NSWorkspace.shared.open(link) }
    }

    /// Stops everything and lets go of the web view (and its web process). Done before its data store is removed.
    func close() async {
        guard let v = webView else { return }
        v.stopLoading()
        await v.pauseAllMediaPlayback()
        await v.closeAllMediaPresentations()
        observations.forEach { $0.invalidate() }
        observations = []
        v.navigationDelegate = nil
        v.uiDelegate = nil
        v.removeFromSuperview()
        webView = nil
    }
}

extension BrowserTab: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let target = action.request.url else { return .cancel }
        let main = action.targetFrame?.isMainFrame ?? true
        let decision = BrowserPolicy.decide(target, mainFrame: main)
        if main { note("navigate \(decision): \(target.absoluteString)") }
        switch decision {
        case .allow: return .allow
        case .openExternally: openExternally(target); return .cancel
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

    /// target=_blank and window.open: YouTube links stay in this tab (tabs come in Phase 2), others open outside.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let target = action.request.url else { return nil }
        if BrowserPolicy.decide(target, mainFrame: true) == .allow {
            note("new window → this tab: \(target.absoluteString)")
            load(target)
        } else {
            openExternally(target)
        }
        return nil
    }

    /// The YouTube section never uses the camera or microphone.
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
                 type: WKMediaCaptureType) async -> WKPermissionDecision {
        note("refused \(type == .camera ? "camera" : "microphone") for \(origin.host)")
        return .deny
    }
}
