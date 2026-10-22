// 4.0 Phase 1: the YouTube section. Native toolbar, the Video Buddy bar (outside the page), the page itself, and
// native offline / error screens instead of a broken page.
import AppKit
import SwiftUI
import WebKit

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p

    var body: some View {
        let browser = model.browser
        VStack(spacing: 10) {
            if let tab = browser.tab {
                BrowserToolbar(tab: tab)
                VideoBuddyBar(page: tab.page)
                ZStack {
                    WebViewHost(tab: tab)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.border.opacity(0.6)))
                    if !model.network.isOnline {
                        OfflineBrowserScreen()
                    } else if let error = tab.loadError {
                        EmptyState(icon: "exclamationmark.triangle", title: "This page didn't load", message: error)
                            .overlay(alignment: .bottom) {
                                Button("Try Again") { tab.reload() }.buttonStyle(PrimaryButtonStyle(height: 34, font: .callout.weight(.semibold)))
                                    .padding(.bottom, 40)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(p.bg.opacity(0.96))
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct BrowserToolbar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let tab: BrowserTab
    @State private var address = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 8) {
            IconButton(icon: "chevron.left", label: "Back", tint: tab.canGoBack ? p.text : p.secondary.opacity(0.5)) { tab.goBack() }
                .disabled(!tab.canGoBack)
            IconButton(icon: "chevron.right", label: "Forward", tint: tab.canGoForward ? p.text : p.secondary.opacity(0.5)) { tab.goForward() }
                .disabled(!tab.canGoForward)
            IconButton(icon: tab.isLoading ? "xmark" : "arrow.clockwise", label: tab.isLoading ? "Stop" : "Reload", tint: p.text) { tab.reload() }
            HStack(spacing: 8) {
                Image(systemName: tab.url?.scheme == "https" ? "lock.fill" : "globe").font(.caption).foregroundStyle(p.secondary)
                TextField("Search YouTube or type a link", text: $address)
                    .textFieldStyle(.plain)
                    .focused($editing)
                    .onSubmit { model.browser.go(address); editing = false }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.card))
            .overlay(alignment: .bottom) {
                if tab.isLoading {
                    GeometryReader { g in
                        Capsule().fill(p.accent).frame(width: max(8, g.size.width * tab.progress), height: 2)
                    }
                    .frame(height: 2)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(editing ? p.accent.opacity(0.7) : p.border))
            IconButton(icon: "safari", label: "Open in your browser", tint: p.text) {
                if let url = tab.url { NSWorkspace.shared.open(url) }
            }
            .disabled(tab.url == nil)
        }
        .onAppear { address = tab.url?.absoluteString ?? "" }
        .onChange(of: model.focusLinkToken) { editing = true }
        .onChange(of: tab.url) { if !editing { address = tab.url?.absoluteString ?? "" } }
    }
}

/// The current video's link to Video Buddy, outside YouTube's page: what the library has, and the usual actions in
/// their usual order (Video → Audio → Summarize → + Transcript), through the existing queue.
private struct VideoBuddyBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @AppStorage("transcribeDownloads") private var transcribe = false
    let page: YouTubePage

    var body: some View {
        HStack(spacing: 10) {
            switch page {
            case let .video(id, _), let .shorts(id):
                videoBar(id)
            case let .playlist(id):
                Label("Playlist on YouTube", systemImage: "music.note.list").font(.callout.weight(.semibold))
                Spacer()
                Button("Save to Video Buddy…") {
                    if let link = PlaylistLink.parse("https://www.youtube.com/playlist?list=\(id)") { model.readPlaylist(link, kind: .video) }
                }
                .buttonStyle(SecondaryButtonStyle(height: 30, font: .callout))
                .help("Lists the playlist (no download) so you can link it to your library")
            default:
                Label(page.label, systemImage: "play.rectangle").font(.callout).foregroundStyle(p.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.card))
    }

    @ViewBuilder private func videoBar(_ id: String) -> some View {
        let store = model.store
        let video = store.all.first { $0.key == "youtube:\(id)" }
        let queued = video.map { v in model.jobs.queue.contains { $0.videoID == v.id } || model.jobs.current?.videoID == v.id } ?? false
        HStack(spacing: 8) {
            Image(systemName: "play.rectangle.fill").foregroundStyle(p.accent)
            Text(status(video, queued: queued)).font(.callout.weight(.medium)).lineLimit(1)
        }
        Spacer(minLength: 8)
        if let v = video, store.playable(for: v.id) != nil {
            Button { model.play(v) } label: { Label("Play on this Mac", systemImage: "play.fill") }
                .buttonStyle(SecondaryButtonStyle(height: 30, font: .callout))
                .help("Pauses YouTube and plays your file in Video Buddy's player")
        }
        if let v = video {
            Button { model.open(v, tab: .summary); model.section = .library } label: { Label("Open in Library", systemImage: "rectangle.stack") }
                .buttonStyle(SecondaryButtonStyle(height: 30, font: .callout))
        }
        Divider().frame(height: 22)
        Button { model.startFromBrowser(.video) } label: { Label("Video", systemImage: "video.fill") }
            .buttonStyle(SecondaryButtonStyle(height: 30, font: .callout))
        Button { model.startFromBrowser(.audio) } label: { Label("Audio", systemImage: "music.note") }
            .buttonStyle(SecondaryButtonStyle(height: 30, font: .callout))
        Button { model.startFromBrowser(.summary) } label: { Label("Summarize", systemImage: "sparkles") }
            .buttonStyle(PrimaryButtonStyle(height: 30, font: .callout.weight(.semibold)))
        Toggle("+ Transcript", isOn: $transcribe).toggleStyle(AccentCheckboxStyle()).font(.callout)
    }

    private func status(_ v: Video?, queued: Bool) -> String {
        guard let v else { return "Not in your library" }
        let store = model.store
        if queued { return "In your library · in the queue" }
        if store.videoOnMacIDs.contains(v.id) { return "In your library · video on this Mac" }
        if store.onMacIDs.contains(v.id) { return "In your library · audio on this Mac" }
        return v.hasSummary ? "In your library · summarized" : "In your library"
    }
}

private struct OfflineBrowserScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.slash").font(.system(size: 40)).foregroundStyle(p.accent)
            Text("You're offline").font(.title2.weight(.semibold))
            Text("YouTube needs internet. Everything on this Mac still works.").foregroundStyle(p.secondary)
            HStack {
                Button("Your Library") { model.section = .library }.buttonStyle(PrimaryButtonStyle(height: 34, font: .callout.weight(.semibold)))
                Button("Downloads") { model.section = .downloads }.buttonStyle(SecondaryButtonStyle(height: 34, font: .callout))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(p.bg.opacity(0.97))
    }
}

/// Shows the tab's web view (owned by the tab, so it survives section switches). While a page is full screen,
/// WebKit takes the web view out of this container and puts it back afterwards.
struct WebViewHost: NSViewRepresentable {
    let tab: BrowserTab

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // read both every time, so SwiftUI calls this again when full screen starts or ends
        let (fullscreen, _) = (tab.isFullscreen, tab.reattachToken)
        guard !fullscreen else { return }
        attach(to: container)
        // WebKit hands the view back after its exit animation; check again once that's over
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { attach(to: container) }
    }

    private func attach(to container: NSView) {
        guard let web = tab.webView, web.superview !== container, !tab.isFullscreen else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        web.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.topAnchor.constraint(equalTo: container.topAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
