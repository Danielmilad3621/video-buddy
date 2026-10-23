// Window layout (design/reference.png): sidebar | toolbar, processing strip, then library | video | AI panel,
// and the mini-player along the bottom. Narrow windows fold the video column into the AI panel as a "Video" tab.
import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false

    var body: some View {
        @Bindable var model = model
        GeometryReader { geo in
            let compactSidebar = sidebarCollapsed || geo.size.width < 1360
            let sidebarWidth: CGFloat = compactSidebar ? 76 : 256
            HStack(spacing: 0) {
                Sidebar(compact: compactSidebar) { sidebarCollapsed.toggle() }
                    .frame(width: sidebarWidth)
                VStack(alignment: .leading, spacing: 12) {
                    // the YouTube section has its own bar with the same actions for the page's video
                    if model.section != .youtube { TopBar() }
                    if let warning = model.startupWarning { WarningStrip(text: warning) { model.startupWarning = nil } }
                    if !model.network.isOnline { OfflineStrip() }
                    ProcessingStatus()
                    if model.section == .settings {
                        SettingsPage()
                    } else if model.section == .youtube {
                        BrowserView()
                    } else {
                        Workspace(width: geo.size.width - sidebarWidth - 32)
                    }
                    if model.playback.player != nil { MiniPlayerBar() }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 12)
            }
        }
        .background(p.bg)
        .ignoresSafeArea()
        .task { await model.launch() }
        .alert("Import your existing downloads?", isPresented: Binding(get: { model.importOffer != nil }, set: { if !$0 { model.importOffer = nil } })) {
            Button("Import") { model.runImport(model.importOffer) }
            Button("Not Now", role: .cancel) { model.declineImport() }
        } message: {
            Text("Found \(model.importOffer?.count ?? 0) videos in \(AppSettings.downloadDir). Their summaries, transcripts and files will appear in your library. Files are only read: nothing is moved, renamed or deleted.")
        }
        .confirmationDialog("Remove “\(model.pendingRemoval?.displayTitle ?? "")” from your library?",
                            isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
                            titleVisibility: .visible) {
            Button("Remove from Library", role: .destructive) { model.confirmRemoval() }
        } message: {
            Text("Its saved summary and transcript are removed from the app. Downloaded files and the files in your downloads folder stay where they are.")
        }
        .overlay(alignment: .bottom) { NoticeToast().padding(.bottom, model.playback.player != nil ? 70 : 0) }
        .sheet(item: $model.playlistImport) { PlaylistImportSheet(state: $0).environment(model) }
        .confirmationDialog("This video is part of a playlist", isPresented: Binding(get: { model.playlistChoice != nil },
                                                                                       set: { if !$0 { model.playlistChoice = nil } }),
                            titleVisibility: .visible) {
            Button("Just This Video") { model.justThisVideo() }
            Button("Whole Playlist…") { model.wholePlaylist() }
        } message: {
            Text("Process only this video, or see the whole playlist and choose which videos to add?")
        }
        .confirmationDialog("Delete the playlist “\(model.pendingPlaylistDeletion?.name ?? "")”?",
                            isPresented: Binding(get: { model.pendingPlaylistDeletion != nil }, set: { if !$0 { model.pendingPlaylistDeletion = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) { model.confirmPlaylistDeletion() }
        } message: {
            Text("Only the playlist is deleted. Its videos stay in your library, and their files stay on disk.")
        }
        .confirmationDialog("Download \(model.pendingOfflineBatch?.videoIDs.count ?? 0) missing videos?",
                            isPresented: Binding(get: { model.pendingOfflineBatch != nil }, set: { if !$0 { model.pendingOfflineBatch = nil } }),
                            titleVisibility: .visible) {
            Button("Download Videos") { model.confirmOfflineBatch() }
        } message: {
            Text(offlineBatchMessage)
        }
        .sheet(item: $model.namePrompt) { NamePromptSheet(prompt: $0).environment(model) }
        .sheet(item: $model.addingVideosTo) { AddVideosSheet(playlist: $0).environment(model) }
        // the declaration sheet opens over Prepare for Offline when that's open (one sheet over another)
        .sheet(item: Binding(get: { model.prepare == nil ? model.declaration : nil }, set: { model.declaration = $0 })) {
            DeclarationSheet(request: $0).environment(model)
        }
        .sheet(item: $model.prepare) { PrepareSheet(state: $0).environment(model) }
        // Watch Later's Open in Tabs, when some didn't fit (it switches to YouTube, so the window shows it)
        .alert("Not every video was opened", isPresented: Binding(get: { model.openReport != nil }, set: { if !$0 { model.openReport = nil } })) {
            Button("OK") { model.openReport = nil }
        } message: {
            Text(model.openReport ?? "")
        }
    }
}

extension RootView {
    var offlineBatchMessage: String {
        let batch = model.pendingOfflineBatch
        let time = (batch?.totalDuration ?? 0) > 0 ? " (\(Fmt.watchTime(batch!.totalDuration)) of video)" : ""
        let free = model.freeDiskSpace.map { " \(Fmt.bytes(Int($0))) is free on this Mac." } ?? ""
        return "Only videos that aren't on this Mac are downloaded, one at a time at your Video quality setting\(time). Files you already have are never downloaded again.\(free)"
    }
}

/// library | video | AI panel, or library | (Video, Summary, Transcript, Downloads) when there isn't room for three.
struct Workspace: View {
    @Environment(AppModel.self) private var model
    let width: CGFloat

    var body: some View {
        let three = width >= 1120
        let library = min(max(width * 0.31, 330), 400)
        let panel = min(max(width * 0.32, 340), 440)
        HStack(alignment: .top, spacing: 14) {
            LibraryColumn().frame(width: library)
            if let v = model.store.selectedVideo {
                if three {
                    VideoColumn(video: v)
                    AIPanel(video: v, tabs: DetailTab.panel).frame(width: panel)
                } else {
                    AIPanel(video: v, tabs: DetailTab.allCases)
                }
            } else {
                Group {
                    if model.section == .watchLater {
                        EmptyState(icon: "clock", title: "Watch Later",
                                   message: "A saved video that's on this Mac plays here. Others open in the YouTube section, where you can download them.")
                    } else {
                        EmptyState(icon: "rectangle.stack", title: "Select a video",
                                   message: "Pick something from your library to watch it and see its summary, transcript and files.")
                    }
                }
                .panelStyle()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Name a new playlist, or rename one.
struct NamePromptSheet: View {
    @Environment(AppModel.self) private var model
    let prompt: NamePrompt
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isRename ? "Rename Playlist" : "New Playlist").font(.title3.weight(.semibold))
            TextField("Playlist name", text: $name).textFieldStyle(.roundedBorder).onSubmit(done)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.namePrompt = nil }.keyboardShortcut(.cancelAction)
                Button(isRename ? "Rename" : "Create", action: done).keyboardShortcut(.defaultAction).disabled(name.nilIfBlank == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { if case let .rename(p) = prompt { name = p.name } }
    }

    private var isRename: Bool { if case .rename = prompt { true } else { false } }

    private func done() {
        switch prompt {
        case let .new(videoID): model.createPlaylist(name, adding: videoID)
        case let .rename(p): model.renamePlaylist(p.id, to: name)
        }
        model.namePrompt = nil
    }
}

/// The red play tile, drawn rather than loaded so it stays sharp at any size.
struct AppLogo: View {
    @Environment(\.palette) private var p
    var size: CGFloat = 44
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(p.accentGradient)
            .overlay(Image(systemName: "play.fill").font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white).offset(x: size * 0.03))
            .frame(width: size, height: size)
            .shadow(color: p.accent.opacity(0.35), radius: 8, y: 2)
            .accessibilityHidden(true)
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let compact: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 44) // room for the window buttons
            HStack(spacing: 12) {
                AppLogo(size: compact ? 40 : 46)
                if !compact {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Video Buddy").font(.title2.weight(.bold))
                        Text(AppSettings.isPreview ? "4.0 Preview · downloads off" : "Watch smarter. Learn faster.").font(.caption)
                            .foregroundStyle(AppSettings.isPreview ? Color.orange : p.secondary)
                    }
                }
            }
            .padding(.horizontal, compact ? 8 : 6)
            .padding(.bottom, 22)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Video Buddy")

            VStack(spacing: 4) {
                ForEach(AppSection.allCases) { NavItem(section: $0, compact: compact) }
            }
            if !compact {
                Divider().overlay(p.border).padding(.vertical, 14)
                PlaylistsShortcut()
            }
            Spacer(minLength: 12)
            if !compact { LearningStats().padding(.bottom, 10) }
            IconButton(icon: compact ? "sidebar.left" : "sidebar.leading", label: compact ? "Expand sidebar" : "Collapse sidebar", action: toggle)
                .padding(.leading, compact ? 10 : 2)
        }
        .padding(.horizontal, compact ? 10 : 14)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity)
        .background(p.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(p.border.opacity(0.6)).frame(width: 1) }
    }
}

struct NavItem: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let section: AppSection
    let compact: Bool
    @State private var hovering = false

    var body: some View {
        let selected = model.section == section
        let badge = section == .queue ? model.jobs.queue.count + (model.jobs.current == nil ? 0 : 1) : 0
        Button { model.section = section } label: {
            HStack(spacing: 14) {
                Image(systemName: section.icon)
                    .font(.title3).frame(width: 26)
                    .overlay(alignment: .topTrailing) { if compact, badge > 0 { Circle().fill(p.accent).frame(width: 9).offset(x: 4, y: -3) } }
                if !compact {
                    Text(section.rawValue).font(.title3.weight(selected ? .semibold : .regular))
                    Spacer(minLength: 0)
                    if badge > 0 {
                        Text("\(badge)").font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.white)
                            .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
                            .background(Capsule().fill(p.accent))
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, compact ? 13 : 14)
            .foregroundStyle(selected ? p.text : p.text.opacity(0.78))
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(
                selected ? AnyShapeStyle(LinearGradient(colors: [p.accentDark.opacity(0.75), p.accentDark.opacity(0.28)],
                                                        startPoint: .leading, endPoint: .trailing))
                         : AnyShapeStyle(hovering ? p.hover.opacity(0.55) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(section.rawValue)
        .accessibilityLabel(badge > 0 ? "\(section.rawValue), \(badge) jobs" : section.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// My Playlists under the navigation: artwork, name, size; opens the playlist in the library column.
struct PlaylistsShortcut: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("My Playlists").font(.callout.weight(.semibold)).foregroundStyle(p.secondary)
                Spacer()
                IconButton(icon: "plus", label: "New playlist", size: 24) { model.namePrompt = .new(adding: nil) }
            }
            .padding(.horizontal, 4)
            if model.store.playlists.isEmpty {
                Text("Paste a YouTube playlist link, or use ⋯ → Add to Playlist.").font(.caption).foregroundStyle(p.secondary)
                    .padding(.horizontal, 4)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.store.playlists) { pl in row(pl) }
                }
            }
            .scrollIndicators(.never)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ pl: PlaylistSummary) -> some View {
        let open = model.section == .playlists && model.store.openPlaylistID == pl.id
        return Button {
            model.section = .playlists
            model.store.openPlaylistID = pl.id
        } label: {
            HStack(spacing: 11) {
                Thumbnail(url: pl.coverURL, localPath: pl.coverPath, cornerRadius: 8, icon: "music.note.list")
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pl.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text("\(pl.count) videos").font(.caption).foregroundStyle(p.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 10).fill(open ? p.hover.opacity(0.6) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…") { model.namePrompt = .rename(pl) }
            Button("Delete Playlist…", role: .destructive) { model.pendingPlaylistDeletion = pl }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Real numbers from the library database.
struct LearningStats: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    var body: some View {
        let s = model.store.stats
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Learning Stats").font(.callout.weight(.semibold))
                Spacer()
                Image(systemName: "chart.bar.fill").foregroundStyle(p.secondary)
            }
            stat("play.fill", "\(s.videos)", "videos processed")
            stat("doc.text.fill", "\(s.summaries)", "summaries generated")
            stat("arrow.down", "\(model.store.videoOnMacIDs.count)", "videos offline")
            stat("clock.fill", Fmt.watchTime(s.watchSeconds), "learning time")
                .help("The total length of the videos you've summarized")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.border.opacity(0.7)))
    }

    private func stat(_ icon: String, _ value: String, _ label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(p.accent))
            Text(value).font(.callout.weight(.bold)).monospacedDigit()
            Text(label).font(.callout).foregroundStyle(p.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Link field, then Video → Audio → Summarize → + Transcript (this order is part of the design).
struct TopBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @FocusState private var focused: Bool
    @AppStorage("transcribeDownloads") private var transcribe = false

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "link").foregroundStyle(p.secondary).font(.title3)
                TextField("Paste a YouTube or video link…", text: $model.link)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { model.start(.summary) }
                    .accessibilityLabel("Video link")
                if model.link.isEmpty {
                    IconButton(icon: "doc.on.clipboard", label: "Paste a link from the clipboard (⇧⌘V)") { model.pasteLink() }
                } else {
                    IconButton(icon: "xmark.circle.fill", label: "Clear link") { model.link = "" }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .frame(minWidth: 220)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(p.card))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(focused ? p.accent.opacity(0.7) : p.border, lineWidth: focused ? 1.5 : 1))

            ViewThatFits(in: .horizontal) {
                actions(iconOnly: false)
                actions(iconOnly: true)
            }
            .fixedSize()
        }
        .onChange(of: model.focusLinkToken) { focused = true }
    }

    private func actions(iconOnly: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                Button { model.start(.video) } label: { Label("Video", systemImage: "video.fill") }
                    .buttonStyle(SecondaryButtonStyle(height: 50, font: .title3.weight(.medium), iconOnly: iconOnly))
                    .help(transcribe ? "Save the video, then transcribe it on this Mac (⇧⌘D)" : "Save the video (⇧⌘D)")
                Button { model.start(.audio) } label: { Label("Audio", systemImage: "music.note") }
                    .buttonStyle(SecondaryButtonStyle(height: 50, font: .title3.weight(.medium), iconOnly: iconOnly))
                    .help(transcribe ? "Save the audio as mp3, then transcribe it on this Mac (⇧⌘A)" : "Save the audio as mp3 (⇧⌘A)")
                Button { model.start(.summary) } label: { Label("Summarize", systemImage: "sparkles") }
                    .buttonStyle(PrimaryButtonStyle(height: 50, iconOnly: iconOnly))
                    .help("Download, transcribe on-device and summarize (⌘↩)")
            }
            .disabled(model.link.nilIfBlank == nil)
            // works before a link is pasted, and is remembered between launches
            Toggle(iconOnly ? "Transcript" : "+ Transcript", isOn: $transcribe)
                .toggleStyle(AccentCheckboxStyle())
                .help("Also transcribe Audio and Video downloads on this Mac (no summary). Summarize always makes a transcript.")
                .padding(.leading, 6)
        }
    }
}

/// No internet: say what still works, so the app is useful on a plane.
struct OfflineStrip: View {
    @Environment(\.palette) private var p
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash").foregroundStyle(p.accent)
            Text("You're offline: your library, saved summaries and downloaded videos all work. Downloads and new summaries wait in the queue until you're back online.")
                .font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(p.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(p.accent.opacity(0.45)))
        .accessibilityElement(children: .combine)
    }
}

struct WarningStrip: View {
    @Environment(\.palette) private var p
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(p.orange)
            Text(text).font(.callout)
            Spacer()
            IconButton(icon: "xmark", label: "Dismiss", action: dismiss)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(p.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(p.orange.opacity(0.4)))
    }
}

/// Short confirmations ("Summary copied"), gone after a few seconds.
struct NoticeToast: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let notice = model.notice {
                Text(notice)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(p.elevated))
                    .overlay(Capsule().strokeBorder(p.border))
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                    .padding(.bottom, 24)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(3))
                        if model.notice == notice { model.notice = nil }
                    }
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.notice)
    }
}
