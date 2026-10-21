// The library column: the video list (Home, Library, Favorites), My Playlists, Downloads or the Queue.
import SwiftUI

struct LibraryColumn: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        switch model.section {
        case .home: LibraryList(continueWatching: true)
        case .downloads: DownloadsList()
        case .playlists: PlaylistsCard()
        case .queue: QueueColumn()
        case .library, .favorites, .settings: LibraryList(continueWatching: false)
        }
    }
}

private struct QueryKey: Equatable {
    let filter: HistoryFilter
    let sort: HistorySort
    let search: String
}

struct LibraryList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let continueWatching: Bool
    @State private var confirmClear = false
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    var body: some View {
        @Bindable var store = model.store
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SearchField(text: $store.search, prompt: "Search your library…").focused($searchFocused)
                Menu {
                    Picker("Sort by", selection: $store.sort) {
                        ForEach(HistorySort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("Clear All History…", role: .destructive) { confirmClear = true }
                        .disabled(store.videos.isEmpty && store.filter == .all && store.search.isEmpty)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease").font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(p.card))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(p.border))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort: \(store.sort.rawValue)")
                .accessibilityLabel("Sort and more")
            }
            // one line like the reference: Favorites is a heart, and narrow columns get smaller chips
            ViewThatFits(in: .horizontal) {
                chips(compact: false)
                chips(compact: true)
                FlowLayout(spacing: 6) { chipButtons(compact: true) }
            }
            if store.videos.isEmpty && !(continueWatching && !store.continueWatching.isEmpty) {
                EmptyState(icon: store.search.isEmpty ? "tray" : "magnifyingglass",
                           title: store.search.isEmpty ? "Nothing here yet" : "No matches",
                           message: store.search.isEmpty
                               ? "Paste a link above and press Video, Audio or Summarize. Everything you process is kept here."
                               : "Nothing in titles, channels, links, summaries or transcripts matches “\(store.search)”.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if continueWatching, store.search.isEmpty, !store.continueWatching.isEmpty { ContinueWatching() }
                        ForEach(store.videos) { VideoRow(video: $0) }
                    }
                    .padding(2)
                }
                .scrollIndicators(.automatic)
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { store.move(1); return .handled }
                .onKeyPress(.upArrow) { store.move(-1); return .handled }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: QueryKey(filter: store.filter, sort: store.sort, search: store.search)) {
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return } // debounce typing
            await store.reload()
        }
        .onChange(of: model.focusSearchToken) { searchFocused = true }
        .confirmationDialog("Clear all history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear All History", role: .destructive) { model.clearAll() }
        } message: {
            Text("This removes every library record, including favorites. Downloaded files, summaries and transcripts in your downloads folder are not touched.")
        }
    }

    private func chips(compact: Bool) -> some View {
        HStack(spacing: compact ? 4 : 6) { chipButtons(compact: compact) }.fixedSize()
    }

    @ViewBuilder private func chipButtons(compact: Bool) -> some View {
        let store = model.store
        ForEach(HistoryFilter.allCases) { f in
            ChipButton(title: f.rawValue, icon: f == .favorites ? "heart.fill" : nil, iconOnly: f == .favorites,
                       compact: compact, selected: store.filter == f) {
                store.filter = f
                if model.section == .favorites, f != .favorites { model.section = .library }
            }
        }
    }
}

/// Home: what you stopped part-way through, resuming where you left off.
struct ContinueWatching: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Continue watching").font(.callout.weight(.semibold)).foregroundStyle(p.secondary)
            ForEach(model.store.continueWatching, id: \.video.id) { item in
                Button { model.play(item.video) } label: {
                    HStack(spacing: 10) {
                        Thumbnail(url: item.video.thumbnailURL, localPath: item.video.thumbnailPath, cornerRadius: 7)
                            .frame(width: 72, height: 40)
                            .overlay(Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).shadow(radius: 2))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.video.displayTitle).font(.callout.weight(.medium)).lineLimit(1)
                            ProgressView(value: item.progress).tint(p.accent).controlSize(.small)
                        }
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(p.card))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Play from where you stopped")
                .accessibilityLabel("Continue \(item.video.displayTitle), \(Int(item.progress * 100)) percent watched")
            }
            Text("Library").font(.callout.weight(.semibold)).foregroundStyle(p.secondary).padding(.top, 6)
        }
        .padding(.bottom, 2)
    }
}

struct VideoRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let video: Video
    @State private var hovering = false

    var body: some View {
        let selected = model.store.selectedID == video.id
        let onMac = model.store.onMacIDs.contains(video.id)
        HStack(alignment: .center, spacing: 12) {
            Thumbnail(url: video.thumbnailURL, localPath: video.thumbnailPath,
                      icon: video.hasSummary || video.hasVideo ? "play.rectangle.fill" : "waveform")
                .frame(width: 104, height: 58)
                .overlay(alignment: .topLeading) {
                    if onMac, video.hasSummary {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption.weight(.bold)).foregroundStyle(.white)
                            .padding(3).background(Circle().fill(.black.opacity(0.65))).padding(4)
                            .help("On this Mac: plays offline")
                            .accessibilityLabel("On this Mac")
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(video.displayTitle).font(.callout.weight(.semibold)).lineLimit(2)
                Text(video.displayChannel).font(.caption).foregroundStyle(p.secondary).lineLimit(1)
                ViewThatFits(in: .horizontal) {
                    bottomLine(onMac: onMac, compact: false)
                    bottomLine(onMac: onMac, compact: true)
                }
            }
            VStack(spacing: 6) {
                IconButton(icon: video.favorite ? "star.fill" : "star",
                           label: video.favorite ? "Remove from favorites" : "Add to favorites",
                           tint: video.favorite ? p.gold : p.secondary, size: 26) { model.toggleFavorite(video) }
                Menu { VideoActions(video: video) } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.bold)).foregroundStyle(p.secondary)
                        .rotationEffect(.degrees(90)).frame(width: 24, height: 26).contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("More actions")
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(selected ? p.accentDark.opacity(0.22) : hovering ? p.card : .clear))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? p.accent : .clear, lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
        .onTapGesture { model.open(video, tab: model.detailTab) }
        .contextMenu { VideoActions(video: video) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(video.displayTitle), \(video.displayChannel)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.open(video, tab: model.detailTab) }
    }

    private func bottomLine(onMac: Bool, compact: Bool) -> some View {
        HStack(spacing: 8) {
            Text(Fmt.duration(video.duration) ?? "—").font(.caption.monospacedDigit()).foregroundStyle(p.secondary).fixedSize()
            Spacer(minLength: 4)
            StatusPill(video: video, onMac: onMac, compact: compact)
        }
    }
}

/// Every per-video action; used by the ⋮ menu, the ⋯ button and the right-click menu.
struct VideoActions: View {
    @Environment(AppModel.self) private var model
    let video: Video

    var body: some View {
        let media = model.existingMedia(video)
        let playable = model.store.playable(for: video.id)
        Button("Play") { model.play(video) }.disabled(playable == nil)
        Divider()
        Button("Open Summary") { model.open(video, tab: .summary) }
        Button("Open Transcript") { model.open(video, tab: .transcript) }
        Divider()
        Button("Copy Summary") { model.copySummary(video) }
        Button("Copy Transcript") { model.copyTranscript(video) }
        Button("Copy Link") { model.copyLink(video) }.disabled(video.url == nil)
        Divider()
        Button("Open Original Link") { FileOps.openLink(video.url) }.disabled(video.url == nil)
        Button("Open Downloaded File") { if let m = media { FileOps.open(m.path) } }.disabled(media == nil)
        Button("Show in Finder") { if let m = media { FileOps.reveal(m.path) } }.disabled(media == nil)
        Divider()
        Button(video.favorite ? "Remove from Favorites" : "Add to Favorites") { model.toggleFavorite(video) }
        Menu("Add to Playlist") {
            ForEach(model.store.playlists) { pl in Button(pl.name) { model.addToPlaylist(pl.id, video: video) } }
            if !model.store.playlists.isEmpty { Divider() }
            Button("New Playlist…") { model.namePrompt = .new(adding: video.id) }
        }
        if model.section == .playlists, model.store.openPlaylistID != nil {
            Button("Remove from This Playlist") { model.removeFromOpenPlaylist(video) }
        }
        Button("Make Available Offline") { model.makeAvailableOffline(video) }
            .disabled(video.url == nil || model.store.hasLocalVideo(video.id))
        Button("Transcribe on This Mac") { model.transcribe(video) }.disabled(media == nil)
        Button("Process Again") { model.processAgain(video) }.disabled(video.url == nil)
        Divider()
        Button("Remove from Library…", role: .destructive) { model.pendingRemoval = video }
    }
}

/// Saved audio and video: storage used, what's missing, and the usual file actions.
struct DownloadsList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @State private var query = ""
    @State private var show = Show.all

    enum Show: String, CaseIterable { case all = "All", available = "Available", missing = "Missing" }

    var body: some View {
        let media = model.store.files.filter(\.isMedia)
        let onDisk = media.filter(\.exists)
        let usedBytes = onDisk.reduce(0) { $0 + (Self.diskSize($1.path) ?? 0) }
        let items = media.filter {
            (show == .all || (show == .available) == $0.exists)
                && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || ($0.videoTitle ?? "").localizedCaseInsensitiveContains(query))
        }
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Downloads", icon: "arrow.down.to.line")
            // what your saved audio and video take up, and what's left, for planning a flight
            HStack(spacing: 6) {
                Image(systemName: "internaldrive").foregroundStyle(p.secondary)
                Text(([("\(onDisk.count) files on this Mac"), Fmt.bytes(usedBytes)]
                      + [model.freeDiskSpace.map { "\(Fmt.bytes(Int($0))) free" }].compactMap { $0 }).joined(separator: " • "))
            }
            .font(.callout).foregroundStyle(p.secondary)
            .accessibilityElement(children: .combine)
            SearchField(text: $query, prompt: "Search downloads…")
            HStack(spacing: 7) {
                ForEach(Show.allCases, id: \.self) { s in
                    let n = s == .all ? media.count : s == .available ? onDisk.count : media.count - onDisk.count
                    ChipButton(title: "\(s.rawValue) \(n)", selected: show == s) { show = s }
                }
            }
            if items.isEmpty {
                EmptyState(icon: "arrow.down.circle", title: media.isEmpty ? "No downloads yet" : "Nothing here",
                           message: media.isEmpty ? "Audio and video you save appear here with their size and location."
                                                  : "No downloads match this filter.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(items) { item in
                            FileRow(item: item, showVideoTitle: true, onDownloadAgain: downloadAgain(item))
                                .contentShape(Rectangle())
                                .onTapGesture { model.store.select(item.videoID); model.detailTab = .downloads }
                        }
                    }
                    .padding(2)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func downloadAgain(_ item: FileItem) -> (() -> Void)? {
        guard let video = model.store.videos.first(where: { $0.id == item.videoID }) ?? model.store.recent.first(where: { $0.id == item.videoID }),
              video.url != nil else { return nil }
        return { model.downloadAgain(video, kind: item.role == .video ? .video : .audio) }
    }

    static func diskSize(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue
    }
}

/// A saved file with its format, real size, location and whether it's still on disk.
struct FileRow: View {
    @Environment(\.palette) private var p
    let item: FileItem
    var showVideoTitle = false
    var onDownloadAgain: (() -> Void)?

    var body: some View {
        let exists = item.exists
        let format = (item.path as NSString).pathExtension.uppercased()
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(exists ? p.accent : p.secondary)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(p.elevated))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.callout.weight(.semibold)).lineLimit(2)
                if showVideoTitle, let t = item.videoTitle { Text(t).font(.caption).foregroundStyle(p.secondary).lineLimit(1) }
                Text(([item.role.rawValue, format.isEmpty ? nil : format, Fmt.bytes(item.size ?? (exists ? diskSize : nil)), Fmt.date(item.date)] as [String?])
                    .compactMap { $0 }.joined(separator: " • "))
                    .font(.caption).foregroundStyle(p.secondary)
                Text(item.path).font(.caption2).foregroundStyle(p.secondary.opacity(0.8)).lineLimit(1).truncationMode(.middle)
                    .help(item.path)
                HStack(spacing: 10) {
                    Text(exists ? "Available" : "Missing")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .foregroundStyle(exists ? p.green : p.accent)
                        .background(Capsule().fill((exists ? p.green : p.accent).opacity(0.15)))
                    Button("Open") { FileOps.open(item.path) }.disabled(!exists).opacity(exists ? 1 : 0.35)
                    Button("Show in Finder") { FileOps.reveal(item.path) }.disabled(!exists).opacity(exists ? 1 : 0.35)
                    if !exists, item.isMedia, let onDownloadAgain { Button("Download Again", action: onDownloadAgain) }
                }
                .buttonStyle(.link)
                .tint(p.accent)
                .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(p.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(p.border.opacity(0.6)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.name), \(exists ? "available" : "missing")")
    }

    private var icon: String {
        switch item.role {
        case .audio: "music.note"
        case .video: "film"
        case .summary: "doc.text"
        case .transcript: "text.quote"
        }
    }

    private var diskSize: Int? { (try? FileManager.default.attributesOfItem(atPath: item.path)[.size] as? NSNumber)?.intValue }
}
