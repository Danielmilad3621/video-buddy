// 4.0 Phase 1: the YouTube section. Native toolbar, the Video Buddy bar (outside the page), the page itself, and
// native offline / error screens instead of a broken page. Phase 2: the tab strip above them.
import AppKit
import SwiftUI
import WebKit

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p

    var body: some View {
        let browser = model.browser
        VStack(spacing: 10) {
            TabStrip()
            if let tab = browser.tab {
                // one identity per tab: nothing (address text, a dialog, the page container and its late re-attach)
                // carries over to another tab's page
                VStack(spacing: 10) {
                    BrowserToolbar(tab: tab)
                    ActionBar(tab: tab)
                    ZStack {
                        // hidden while a native screen covers it (and so left out of test snapshots, which paint pages last)
                        WebViewHost(tab: tab, hidden: !model.network.isOnline || tab.loadError != nil)
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
                }
                .id(tab.id)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// Phase 2: the tabs, Safari-style. Each shows its page kind (or the video's thumbnail), its title and what this Mac
/// has for its video (local only, never a network check). Drag to reorder; right-click for more.
private struct TabStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p

    var body: some View {
        let b = model.browser
        HStack(spacing: 6) {
            GeometryReader { g in
                // tabs share the row down to a minimum width, then the row scrolls
                let n = CGFloat(max(b.tabs.count, 1))
                let width = min(220, max(120, (g.size.width - (n - 1) * 4) / n))
                ScrollViewReader { scroller in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(b.tabs.enumerated()), id: \.element.id) { i, t in
                                TabChip(tab: t, index: i, active: t.id == b.activeID).frame(width: width).id(t.id)
                            }
                        }
                    }
                    .onChange(of: b.activeID) { if let id = b.activeID { withAnimation { scroller.scrollTo(id) } } }
                }
            }
            .frame(height: 30)
            IconButton(icon: "plus", label: "New Tab", tint: p.text) { model.newBrowserTab() }
                .help("New Tab (⌘T)")
                .testProbe("newTab")
        }
    }
}

private struct TabChip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let tab: BrowserTab
    let index: Int
    let active: Bool
    @State private var hover = false

    var body: some View {
        let b = model.browser
        let id = tab.page.videoID
        let name = title(id)
        HStack(spacing: 6) {
            if let id {
                Thumbnail(url: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg", cornerRadius: 3).frame(width: 26, height: 15)
            } else {
                Image(systemName: tab.page.icon).font(.caption).foregroundStyle(p.secondary).frame(width: 16)
            }
            Text(name).font(.caption.weight(active ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 0)
            if tab.media == "playing" {
                Button { b.pause(tab) } label: { Image(systemName: "speaker.wave.2.fill").font(.caption2).frame(width: 16, height: 16) }
                    .buttonStyle(.plain).foregroundStyle(p.accent)
                    .help(tab.id == b.audioTabID ? "Playing in the background. Click to pause." : "Playing. Click to pause.")
                    .accessibilityLabel("Pause \(name)")
            }
            badge(id)
            if hover || active {
                Button { b.close(tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(p.secondary)
                .help("Close Tab (⌘W)").accessibilityLabel("Close \(name)")
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(active ? p.card : p.elevated.opacity(hover ? 1 : 0.45)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(active ? p.accent.opacity(0.6) : p.border.opacity(0.5)))
        .contentShape(Rectangle())
        .onTapGesture { b.select(tab) }
        .onHover { hover = $0 }
        .help(name)
        .contextMenu {
            if let id {
                if model.store.savedKeys.contains("youtube:\(id)") {
                    Button("Remove from Watch Later") { model.removeFromWatchLater(["youtube:\(id)"]) }
                } else {
                    Button("Save to Watch Later") { model.saveToWatchLater(id, from: tab) }
                }
                Divider()
            }
            Button("Duplicate Tab") { b.duplicate(tab) }
            Button("Move Tab Left") { b.move(tab, to: index - 1) }.disabled(index == 0)
            Button("Move Tab Right") { b.move(tab, to: index + 1) }.disabled(index == b.tabs.count - 1)
            Divider()
            Button("Close Tab") { b.close(tab) }
        }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first.flatMap(UUID.init(uuidString:)).flatMap({ id in b.tabs.first { $0.id == id } }) else { return false }
            b.move(dragged, to: index)
            return true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tab \(index + 1) of \(b.tabs.count): \(name)")
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .testProbe("tab\(index + 1)")
    }

    /// The page's title; a tab that hasn't loaded yet (opened behind) shows the library's title or what it is.
    private func title(_ id: String?) -> String {
        if let t = BrowserTab.cleanTitle(tab.title) { return t }
        if let id, let t = model.store.all.first(where: { $0.key == "youtube:\(id)" })?.title { return t }
        return id != nil ? "YouTube video" : tab.page.label
    }

    /// What this Mac has for the tab's video: on this Mac (green), or waiting in the queue.
    @ViewBuilder private func badge(_ id: String?) -> some View {
        if let id {
            let a = model.availability(youtubeID: id)
            if a.videoFile != nil || a.audioFile != nil {
                Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(p.green)
                    .help(a.videoFile != nil ? "Video on this Mac" : "Audio on this Mac")
            } else if [a.video, a.audio, a.summary].contains(where: { $0 == .queued || $0 == .running }) {
                Image(systemName: "clock").font(.caption2).foregroundStyle(p.accent).help("In the queue")
            }
        }
    }
}

private extension YouTubePage {
    var icon: String {
        switch self {
        case .home: "house"
        case .video, .shorts: "play.rectangle"
        case .playlist: "music.note.list"
        case .channel: "person.crop.square"
        case .search: "magnifyingglass"
        case .signIn: "person.badge.key"
        case .consent: "checkmark.shield"
        case .otherYouTube, .other, .blank: "globe"
        }
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

/// The Video Buddy action bar, outside YouTube's page and always there: on a video it shows what you have and the
/// actions in their usual order (Video → Audio → Summarize → + Transcript); elsewhere the same buttons, dimmed.
private struct ActionBar: View {
    @Environment(\.palette) private var p
    let tab: BrowserTab

    var body: some View {
        Group {
            if let id = tab.page.videoID {
                VideoActionBar(id: id, tab: tab).id(id)       // a new video is a new bar: nothing carries over
            } else if case let .playlist(id) = tab.page {
                PlaylistBar(listID: id)
            } else {
                IdleBar(label: tab.page.label)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)     // the full width, like the toolbar, also when it wraps
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.border.opacity(0.7)))
    }
}

private enum LabelMode { case full, short, icons }

private struct VideoActionBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @AppStorage("transcribeDownloads") private var transcribe = false
    @State private var confirmCopy = false
    let id: String
    let tab: BrowserTab

    var body: some View {
        let a = model.availability(youtubeID: id)
        let g = model.browserGate(id)
        let checking = g == nil && model.browser.checker.running == id
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { info(a, g, checking); Spacer(minLength: 12); actions(a, g, .full) }
            HStack(spacing: 10) { info(a, g, checking); Spacer(minLength: 8); actions(a, g, .short) }
            VStack(alignment: .leading, spacing: 8) { info(a, g, checking); actions(a, g, .full) }
            VStack(alignment: .leading, spacing: 8) { info(a, g, checking); actions(a, g, .icons) }
        }
        .alert("Download another copy?", isPresented: $confirmCopy) {
            Button("Download Another Copy") { model.requestFromBrowser(.video, videoID: id, tabID: tab.id, anotherCopy: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This video is already on this Mac. Another copy is a second file, at your Video quality setting (\(AppSettings.videoQuality.label)).")
        }
    }

    /// Thumbnail, title and every status that applies.
    private func info(_ a: VideoAvailability, _ g: DownloadGate.Decision?, _ checking: Bool) -> some View {
        let library = model.store.all.first { $0.key == "youtube:\(id)" }
        let pageTitle = tab.videoTitle
        return HStack(spacing: 10) {
            Thumbnail(url: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg", localPath: library?.thumbnailPath, cornerRadius: 6)
                .frame(width: 64, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                // 4.0 G1b: the library's (original) title, as everywhere else; the page's (often translated) one after it
                // (two separate texts: one string mixing a right-to-left title with a left-to-right one gets reordered)
                let t = WatchLater.titles(library: library?.title, shown: pageTitle)
                HStack(spacing: 10) {
                    Text(t.main ?? "YouTube video").font(.callout.weight(.semibold)).lineLimit(1)
                    if let translation = t.translation {
                        Text(translation).font(.callout).foregroundStyle(p.secondary).lineLimit(1).layoutPriority(-1)
                    }
                }
                .help(t.translation.map { "YouTube shows: \($0)" } ?? t.main ?? "")
                HStack(spacing: 6) { ForEach(chips(a, g, checking), id: \.text) { chip($0) } }
            }
        }
        .layoutPriority(-1)
    }

    private struct Chip { let text: String; let icon: String; let color: Color }

    private func chips(_ a: VideoAvailability, _ g: DownloadGate.Decision?, _ checking: Bool) -> [Chip] {
        var c = a.labels().map { Chip(text: $0.text, icon: $0.icon, color: p.tone($0.tone)) }
        switch g {
        case nil where checking: c.append(Chip(text: "Checking availability…", icon: "magnifyingglass", color: p.secondary))
        case let .blocked(r)?: c.append(Chip(text: "Unavailable: \(r)", icon: "nosign", color: p.orange))
        case let .unknown(r)?: c.append(Chip(text: "Couldn't check: \(r)", icon: "questionmark.circle", color: p.orange))
        case .needsDeclaration?: c.append(Chip(text: "Authorization required", icon: "hand.raised", color: p.accent))
        case let .allowed(auth)?: c.append(Chip(text: auth.label, icon: "person.badge.shield.checkmark", color: p.secondary))
        default: break
        }
        return c
    }

    private func chip(_ c: Chip) -> some View {
        Label(c.text, systemImage: c.icon)
            .font(.caption.weight(.semibold)).foregroundStyle(c.color).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(c.color.opacity(0.14)))
            .help(c.text)
    }

    @ViewBuilder private func actions(_ a: VideoAvailability, _ g: DownloadGate.Decision?, _ mode: LabelMode) -> some View {
        let v = SlotState.video(a, g), au = SlotState.audio(a, g), su = SlotState.summary(a, g)
        HStack(spacing: 8) {
            watchLaterSlot(mode)
            videoSlot(v, a, mode)
            slot(.audio, au, mode)   // 4.0 G1b: Play Audio stays reachable when the video is here too
            slot(.summary, su, mode)
            Toggle(mode == .icons ? "+T" : "+ Transcript", isOn: $transcribe).toggleStyle(AccentCheckboxStyle()).font(.callout)
                .help("Downloads also get a transcript made on this Mac (no summary)").fixedSize()
        }
    }

    /// Phase 3: Save to Watch Later (nothing is downloaded), or, once saved, the way to it.
    @ViewBuilder private func watchLaterSlot(_ mode: LabelMode) -> some View {
        let key = "youtube:\(id)"
        if model.store.savedKeys.contains(key) {
            button("In Watch Later", short: "Saved", icon: "checkmark.circle.fill", mode: mode, probe: "inWatchLater",
                   help: "Saved to Watch Later. Click to see it; right-click to remove it") { model.showWatchLater(select: key) }
                .contextMenu { Button("Remove from Watch Later") { model.removeFromWatchLater([key]) } }
        } else {
            button("Save to Watch Later", short: "Later", icon: "clock.badge.plus", outline: true, mode: mode, probe: "saveWatchLater",
                   help: "Save to Watch Later (⌘D). Nothing is downloaded") { model.saveToWatchLater(id, from: tab) }
        }
    }

    @ViewBuilder private func videoSlot(_ state: SlotState, _ a: VideoAvailability, _ mode: LabelMode) -> some View {
        let library = model.store.all.first { $0.key == "youtube:\(id)" }
        switch state {
        case .offline:
            button("Play Offline", short: "Play", icon: "play.fill", primary: true, mode: mode, probe: "playOffline") {
                if let v = library { model.play(v) }
            }
            button("Show in Library", short: "Library", icon: "rectangle.stack", mode: mode, probe: "showInLibrary") {
                if let v = library { model.open(v, tab: .video); model.section = .library }
            }
            IconButton(icon: "folder", label: "Show in Finder") { if let f = a.videoFile { FileOps.reveal(f) } }
            Menu {
                Button("Download Another Copy…") { confirmCopy = true }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("More")
        default:
            stateButton(.video, state, mode)
        }
    }

    @ViewBuilder private func slot(_ slot: BarSlot, _ state: SlotState, _ mode: LabelMode) -> some View {
        let library = model.store.all.first { $0.key == "youtube:\(id)" }
        switch (slot, state) {
        case (.audio, .offline):
            // the audio file itself (playing the entry would pick its video when both are here)
            button("Play Audio", short: "Audio", icon: "headphones", mode: mode, probe: "playAudio") {
                if let v = library, let path = model.availability(youtubeID: id).audioFile { model.store.select(v.id); model.playback.play(path: path, videoID: v.id) }
                else if let v = library { model.play(v) }
            }
        case (.summary, .offline):
            button("Open Summary", short: "Summary", icon: "doc.text", mode: mode, probe: "openSummary") {
                if let v = library { model.open(v, tab: .summary); model.section = .library }
            }
        default:
            stateButton(slot, state, mode)
        }
    }

    /// The not-yet-here states of a slot; the red button is the video's.
    @ViewBuilder private func stateButton(_ slot: BarSlot, _ state: SlotState, _ mode: LabelMode) -> some View {
        let noun = slot == .video ? "Video" : slot == .audio ? "Audio" : "Summary"
        let primary = slot == .video
        let probe = slot.rawValue
        switch state {
        case .ready:
            let label = slot == .summary ? "Summarize" : "Download \(noun)"
            button(label, short: slot == .summary ? "Summarize" : noun, icon: icon(slot), primary: primary, mode: mode, probe: probe) {
                model.requestFromBrowser(slot, videoID: id, tabID: tab.id)
            }
        case .authorizationRequired:
            let label = slot == .video ? "Authorization Required" : slot == .summary ? "Summarize" : "Download Audio"
            button(label, short: slot == .video ? "Authorize" : noun, icon: slot == .video ? "hand.raised.fill" : icon(slot), primary: primary,
                   mode: mode, probe: probe, help: "Declare that you may download this video first (it isn't verified)") {
                model.requestFromBrowser(slot, videoID: id, tabID: tab.id)
            }
        case .retry:
            button("Retry \(slot == .summary ? "Summary" : "Download")", short: "Retry", icon: "arrow.clockwise", primary: primary, mode: mode, probe: probe) {
                model.requestFromBrowser(slot, videoID: id, tabID: tab.id)
            }
        case .downloadAgain:
            button("Download \(noun) Again", short: "Again", icon: "arrow.down.circle", primary: primary, mode: mode, probe: probe,
                   help: "The file isn't on this Mac any more") {
                model.requestFromBrowser(slot, videoID: id, tabID: tab.id)
            }
        case .queued, .running:
            let label = state == .running ? (slot == .summary ? "Summarizing…" : "Downloading…") : "\(noun) Queued"
            button(label, short: state == .running ? "…" : "Queued", icon: state == .running ? "arrow.down.circle" : "clock", mode: mode,
                   probe: probe, help: "Open the queue") { model.section = .queue }
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                if mode != .icons { Text(slot == .video ? "Checking availability…" : noun).font(.callout) }
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 10).fill(p.elevated))
            .help("Checking what YouTube allows for this video (no download)")
            .accessibilityLabel("Checking availability")
        case let .unavailable(reason):
            button(slot == .video ? "Unavailable" : noun, short: "Unavailable", icon: "nosign", mode: mode, probe: probe, help: reason) {
                model.notice = reason
            }
            .opacity(0.6)
        case let .unknown(reason):
            button("Check Again", short: "Check", icon: "arrow.clockwise", mode: mode, probe: probe, help: reason) {
                model.browser.checker.recheck(id)
            }
        case .offline:
            EmptyView()
        }
    }

    private func icon(_ slot: BarSlot) -> String {
        switch slot {
        case .video: "arrow.down.circle.fill"
        case .audio: "music.note"
        case .summary: "sparkles"
        }
    }

    private func button(_ title: String, short: String, icon: String, primary: Bool = false, outline: Bool = false, mode: LabelMode,
                        probe: String, help: String? = nil, action: @escaping () -> Void) -> some View {
        Group {
            if outline, mode != .icons {
                Button(action: action) { Label(mode == .short ? short : title, systemImage: icon) }
                    .buttonStyle(OutlineButtonStyle(height: 32))
            } else if primary {
                Button(action: action) { Label(mode == .short ? short : title, systemImage: icon) }
                    .buttonStyle(PrimaryButtonStyle(height: 32, font: .callout.weight(.semibold), iconOnly: mode == .icons))
            } else {
                Button(action: action) { Label(mode == .short ? short : title, systemImage: icon) }
                    .buttonStyle(SecondaryButtonStyle(height: 32, font: .callout, iconOnly: mode == .icons))
            }
        }
        .fixedSize()
        .help(help ?? title)
        .accessibilityLabel(title)
        .testProbe(probe)
    }
}

/// Not a video: the same buttons, dimmed, and what to do.
private struct IdleBar: View {
    @Environment(\.palette) private var p
    let label: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.rectangle").foregroundStyle(p.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.callout.weight(.semibold))
                Text("Open a video to download, summarize or play it offline.").font(.caption).foregroundStyle(p.secondary).lineLimit(1)
            }
            .layoutPriority(-1)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button {} label: { Label("Download Video", systemImage: "arrow.down.circle.fill") }
                    .buttonStyle(PrimaryButtonStyle(height: 32, font: .callout.weight(.semibold)))
                Button {} label: { Label("Download Audio", systemImage: "music.note") }
                    .buttonStyle(SecondaryButtonStyle(height: 32, font: .callout))
                Button {} label: { Label("Summarize", systemImage: "sparkles") }
                    .buttonStyle(SecondaryButtonStyle(height: 32, font: .callout))
            }
            .disabled(true)
            .fixedSize()
            .help("Open a video first")
        }
    }
}

private struct PlaylistBar: View {
    @Environment(AppModel.self) private var model
    let listID: String
    var body: some View {
        HStack {
            Label("Playlist on YouTube", systemImage: "music.note.list").font(.callout.weight(.semibold))
            Spacer()
            Button("Save to Video Buddy…") {
                if let link = PlaylistLink.parse("https://www.youtube.com/playlist?list=\(listID)") { model.readPlaylist(link, kind: .video, linkOnly: true) }
            }
            .buttonStyle(SecondaryButtonStyle(height: 32, font: .callout))
            .help("Lists the playlist so you can link it to your library. Nothing is downloaded from here: open a video to download it.")
            .testProbe("savePlaylist")
        }
    }
}

/// Before anything is downloaded from YouTube you declare why you may (YouTube's Terms only allow downloads it offers
/// itself, or with permission). Video Buddy records the declaration; it can't verify it, and says so.
struct DeclarationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let request: DeclarationRequest
    @State private var reference = ""

    var body: some View {
        let check = model.browser.checker.results[request.videoID]
        let ownMatch = DownloadGate.channelMatches(check, ownChannels: model.ownChannels)
        let channel: String? = if case let .passed(_, handle, name)? = check { name ?? handle } else { nil }
        VStack(alignment: .leading, spacing: 14) {
            Text("Authorization required").font(.title2.weight(.semibold))
            HStack(spacing: 10) {
                Thumbnail(url: "https://i.ytimg.com/vi/\(request.videoID)/mqdefault.jpg", cornerRadius: 6).frame(width: 96, height: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.title ?? "YouTube video").font(.headline).lineLimit(2)
                    Text("youtube.com/watch?v=\(request.videoID)").font(.caption.monospaced()).foregroundStyle(p.secondary).textSelection(.enabled)
                }
            }
            .testProbe("declarationVideo")
            Text("YouTube's Terms allow downloading only where YouTube offers it, or with permission from YouTube and the rights holders. Video Buddy can't check your rights: it records what you declare, labelled as not independently verified.")
                .fixedSize(horizontal: false, vertical: true)
            if let channel { Label("Channel: \(channel)", systemImage: "person.crop.square").font(.callout).foregroundStyle(p.secondary) }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("This is my own channel").font(.headline)
                    Text(ownMatch ? "The video's channel matches a channel you entered in Settings." :
                            "Only possible when the video's channel is one you entered in Settings → YouTube.")
                        .font(.callout).foregroundStyle(p.secondary)
                    Button("Declare: My Own Channel") { model.declare(request, basis: .ownChannel, reference: channel) }
                        .disabled(!ownMatch).testProbe("declareOwn")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("I have written permission").font(.headline)
                    Text("Who gave it, and when or where (a link, an email subject).").font(.callout).foregroundStyle(p.secondary)
                    TextField("Permission reference", text: $reference).textFieldStyle(.roundedBorder).testProbe("permissionField")
                    Button("Declare: Written Permission") { model.declare(request, basis: .writtenPermission, reference: reference) }
                        .disabled(reference.trimmingCharacters(in: .whitespaces).count < 3).testProbe("declareWritten")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("Saved as “declared — not independently verified”.").font(.caption).foregroundStyle(p.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { model.declaration = nil }.keyboardShortcut(.cancelAction).testProbe("declareCancel")
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(p.bg)
    }
}

/// 4.0 Phase 5: a videobuddy:// request (Raycast) waiting for you. Download isn't the default button, so it always
/// takes a click; it then goes through the same checks as a pasted link.
struct ExternalRequestSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let request: ExternalRequest

    var body: some View {
        let live = model.externalRequest?.id == request.id ? model.externalRequest ?? request : request
        VStack(alignment: .leading, spacing: 14) {
            Text("Another app sent a link").font(.title2.weight(.semibold))
            HStack(spacing: 10) {
                if let id = live.youtubeID {
                    Thumbnail(url: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg", cornerRadius: 6).frame(width: 96, height: 54)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(live.playlist != nil ? "YouTube playlist" : live.title ?? "Looking up the title…").font(.headline).lineLimit(2)
                    if let channel = live.channel { Text(channel).font(.callout).foregroundStyle(p.secondary) }
                    Text(live.youtubeID.map { "youtube.com/watch?v=\($0)" } ?? live.playlist.map { "youtube.com/playlist?list=\($0.listID)" } ?? live.link)
                        .font(.caption.monospaced()).foregroundStyle(p.secondary).textSelection(.enabled)
                }
            }
            .testProbe("externalVideo")
            Label(what(live), systemImage: live.kind == .summary ? "sparkles" : live.kind == .audio ? "music.note" : "film")
            Text("Nothing happens unless you choose \(button(live)). It then goes through the usual checks: your declaration for this video and its availability"
                 + (AppSettings.isRC ? ", and \(AppSettings.appName)'s live-test list." : "."))
                .font(.callout).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.externalRequest = nil }.keyboardShortcut(.cancelAction).testProbe("externalCancel")
                Button(button(live)) { model.confirmExternal() }.testProbe("externalDownload")
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(p.bg)
    }

    private func what(_ r: ExternalRequest) -> String {
        let quality = AppSettings.videoQuality.label
        switch (r.playlist != nil, r.kind) {
        case (true, _): return "Show the playlist, to choose videos to prepare for offline"
        case (false, .video): return "Download the video at \(quality)"
        case (false, .audio): return "Download the audio (MP3)"
        default: return "Summarize: download the audio, transcribe it, then a paid AI summary"
        }
    }

    private func button(_ r: ExternalRequest) -> String {
        r.playlist != nil ? "Show Playlist" : r.kind == .summary ? "Summarize" : r.kind == .audio ? "Download Audio" : "Download Video"
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
    var hidden = false

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // read both every time, so SwiftUI calls this again when full screen starts or ends
        let (fullscreen, _) = (tab.isFullscreen, tab.reattachToken)
        tab.webView?.isHidden = hidden
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
