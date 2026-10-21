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

/// Library display: playlists as collapsible albums with the rest under Individual Videos, or one flat list.
enum LibraryLayout: String { case grouped = "Grouped", flat = "All Videos" }

struct LibraryList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let continueWatching: Bool
    @AppStorage("libraryLayout") private var layout = LibraryLayout.grouped.rawValue
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
            SegmentedToggle(options: [(LibraryLayout.grouped.rawValue, "square.stack"), (LibraryLayout.flat.rawValue, "list.bullet")],
                            selection: $layout)
                .help("Grouped: each playlist is one collection. All Videos: every video in one list.")
            // one line like the reference: Favorites is a heart, and narrow columns get smaller chips
            ViewThatFits(in: .horizontal) {
                chips(compact: false)
                chips(compact: true)
                FlowLayout(spacing: 6) { chipButtons(compact: true) }
            }
            let grouped = layout == LibraryLayout.grouped.rawValue
            let g = Grouping.make(store.videos, playlists: store.playlists, members: store.members)
            let searching = !store.search.isEmpty
            let visible = grouped
                ? g.groups.flatMap { searching || store.expanded.contains($0.playlist.id) ? $0.videos.map(\.id) : [] } + g.individual.map(\.id)
                : store.videos.map(\.id)
            if store.videos.isEmpty && !(continueWatching && !store.continueWatching.isEmpty) {
                EmptyState(icon: store.search.isEmpty ? "tray" : "magnifyingglass",
                           title: store.search.isEmpty ? "Nothing here yet" : "No matches",
                           message: store.search.isEmpty
                               ? "Paste a link above and press Video, Audio or Summarize. Everything you process is kept here."
                               : "Nothing in titles, channels, links, summaries or transcripts matches “\(store.search)”.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if continueWatching, !searching {
                            if !store.playlists.isEmpty { PlaylistShelf() }
                            if !store.continueWatching.isEmpty { ContinueWatching() }
                            if !store.playlists.isEmpty || !store.continueWatching.isEmpty { heading("Library") }
                        }
                        if grouped {
                            ForEach(g.groups) { PlaylistGroupRow(group: $0, open: searching || store.expanded.contains($0.playlist.id)) }
                            if !g.individual.isEmpty {
                                if !g.groups.isEmpty { heading("Individual Videos") }
                                ForEach(g.individual) { VideoRow(video: $0) }
                            }
                        } else {
                            ForEach(store.videos) { VideoRow(video: $0) }
                        }
                    }
                    .padding(2)
                }
                .scrollIndicators(.automatic)
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { store.move(1, in: visible); return .handled }
                .onKeyPress(.upArrow) { store.move(-1, in: visible); return .handled }
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

    private func heading(_ text: String) -> some View {
        Text(text).font(.callout.weight(.semibold)).foregroundStyle(p.secondary).padding(.top, 6).accessibilityAddTraits(.isHeader)
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
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.video.displayTitle).font(.callout.weight(.medium)).lineLimit(1)
                            if let pl = model.store.playlistsOf(item.video.id).first {
                                Text([pl.name, model.store.episode(item.video.id, in: pl.id).map { "Episode \($0)" }].compactMap { $0 }
                                    .joined(separator: " • "))
                                    .font(.caption).foregroundStyle(p.secondary).lineLimit(1)
                            }
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
        }
        .padding(.bottom, 2)
    }
}

struct VideoRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let video: Video
    /// Set inside a playlist (group, page): its episode number shows, and Play follows that playlist.
    var playlistID: Int64? = nil
    var number: Int? = nil
    @State private var hovering = false

    var body: some View {
        let selected = model.store.selectedID == video.id
        let onMac = model.store.onMacIDs.contains(video.id)
        let audioOnly = onMac && !model.store.videoOnMacIDs.contains(video.id)
        HStack(alignment: .center, spacing: 12) {
            if let number {
                Text("\(number)").font(.callout.monospacedDigit().weight(.medium)).foregroundStyle(p.secondary)
                    .frame(minWidth: 20, alignment: .trailing)
                    .accessibilityLabel("Episode \(number)")
            }
            Thumbnail(url: video.thumbnailURL, localPath: video.thumbnailPath,
                      icon: video.hasSummary || video.hasVideo ? "play.rectangle.fill" : "waveform")
                .frame(width: 104, height: 58)
                .overlay(alignment: .bottom) { WatchMark(state: model.store.watch[video.id]?.state) }
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
                    bottomLine(onMac: onMac, audioOnly: audioOnly, compact: false)
                    bottomLine(onMac: onMac, audioOnly: audioOnly, compact: true)
                }
            }
            VStack(spacing: 6) {
                IconButton(icon: video.favorite ? "star.fill" : "star",
                           label: video.favorite ? "Remove from favorites" : "Add to favorites",
                           tint: video.favorite ? p.gold : p.secondary, size: 26) { model.toggleFavorite(video) }
                Menu { VideoActions(video: video, playlistID: playlistID) } label: {
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
        .contextMenu { VideoActions(video: video, playlistID: playlistID) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(video.displayTitle), \(video.displayChannel)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.open(video, tab: model.detailTab) }
    }

    private func bottomLine(onMac: Bool, audioOnly: Bool, compact: Bool) -> some View {
        HStack(spacing: 8) {
            Text(Fmt.duration(video.duration) ?? "—").font(.caption.monospacedDigit()).foregroundStyle(p.secondary).fixedSize()
            Spacer(minLength: 4)
            StatusPill(video: video, onMac: onMac, audioOnly: audioOnly, compact: compact)
        }
    }
}

/// A playlist in a grouped list, like an album: artwork, name, counts and play; it opens to its episodes in order.
struct PlaylistGroupRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let group: LibraryGroup
    let open: Bool

    var body: some View {
        let store = model.store
        let pl = group.playlist
        let total = store.members[pl.id]?.count ?? pl.count
        let shown = group.videos.count
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                        if store.expanded.contains(pl.id) { store.expanded.remove(pl.id) } else { store.expanded.insert(pl.id) }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Thumbnail(url: pl.coverURL, localPath: pl.coverPath, cornerRadius: 10, icon: "music.note.list")
                            .frame(width: 58, height: 58)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pl.name).font(.callout.weight(.semibold)).lineLimit(2)
                            Text(([shown < total ? "\(shown) of \(total) videos" : "\(total) videos",
                                   "\(store.offlineCount(pl.id)) offline"]).joined(separator: " • "))
                                .font(.caption).foregroundStyle(p.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.callout.weight(.semibold)).foregroundStyle(p.secondary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(pl.name), \(total) videos")
                .accessibilityValue(open ? "expanded" : "collapsed")
                PlaylistPlayButton(playlist: pl)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(p.card))
            .contextMenu { PlaylistActions(playlist: pl) }
            if open {
                ForEach(group.videos) { v in
                    VideoRow(video: v, playlistID: pl.id, number: store.episode(v.id, in: pl.id))
                }
                .padding(.leading, 6)
            }
        }
    }
}

/// ▶ for a playlist: Continue where you are in it, else Play All.
struct PlaylistPlayButton: View {
    @Environment(AppModel.self) private var model
    let playlist: PlaylistSummary
    var size: CGFloat = 34

    var body: some View {
        let store = model.store
        let resume = store.resumeTarget(playlist.id)
        let label = resume.flatMap { store.episode($0, in: playlist.id) }.map { "Continue: episode \($0)" } ?? "Play All"
        PlayCircle(label: label, size: size) { resume == nil ? model.playAll(playlist.id) : model.continuePlaylist(playlist.id) }
            .disabled(store.playableMembers(playlist.id).isEmpty)
    }
}

/// The playlist menu used by group rows, cards and the playlist page.
struct PlaylistActions: View {
    @Environment(AppModel.self) private var model
    let playlist: PlaylistSummary

    var body: some View {
        let store = model.store
        Button("Open Playlist") { model.openPlaylist(playlist.id) }
        Button("Play All") { model.playAll(playlist.id) }.disabled(store.playableMembers(playlist.id).isEmpty)
        if let id = store.resumeTarget(playlist.id) {
            Button("Continue Episode \(store.episode(id, in: playlist.id) ?? 1)") { model.continuePlaylist(playlist.id) }
        }
        Divider()
        Button("Download Missing Videos…") { model.askDownloadMissing(playlist.id) }
        if playlist.sourceURL != nil { Button("Check Against YouTube…") { model.checkPlaylist(playlist) } }
        Divider()
        Button("Rename…") { model.namePrompt = .rename(playlist) }
        if let url = playlist.sourceURL { Button("Open on YouTube") { FileOps.openLink(url) } }
        Button("Delete Playlist…", role: .destructive) { model.pendingPlaylistDeletion = playlist }
    }
}

/// Home: your playlists as cards, like albums.
struct PlaylistShelf: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p

    var body: some View {
        let store = model.store
        VStack(alignment: .leading, spacing: 8) {
            Text("Your Playlists").font(.callout.weight(.semibold)).foregroundStyle(p.secondary).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(store.playlists) { pl in
                        VStack(alignment: .leading, spacing: 5) {
                            Button { model.openPlaylist(pl.id) } label: {
                                Thumbnail(url: pl.coverURL, localPath: pl.coverPath, cornerRadius: 12, icon: "music.note.list")
                                    .frame(width: 128, height: 128)
                            }
                            .buttonStyle(.plain)
                            .overlay(alignment: .bottomTrailing) { PlaylistPlayButton(playlist: pl, size: 32).padding(7) }
                            .accessibilityLabel("Open \(pl.name)")
                            Text(pl.name).font(.callout.weight(.semibold)).lineLimit(2).frame(width: 128, alignment: .leading)
                            Text("\(store.members[pl.id]?.count ?? pl.count) videos • \(store.offlineCount(pl.id)) offline")
                                .font(.caption).foregroundStyle(p.secondary).lineLimit(1)
                            if let id = store.resumeTarget(pl.id), let n = store.episode(id, in: pl.id) {
                                Text("Continue: episode \(n)").font(.caption.weight(.medium)).foregroundStyle(p.accent).lineLimit(1)
                            }
                        }
                        .frame(width: 128, alignment: .leading)
                        .contextMenu { PlaylistActions(playlist: pl) }
                    }
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.never)
        }
    }
}

/// Watched state on a thumbnail: a progress bar part-way, a check when finished, nothing before you start.
struct WatchMark: View {
    @Environment(\.palette) private var p
    let state: WatchState?

    var body: some View {
        switch state {
        case let .partial(f)?:
            GeometryReader { g in
                Capsule().fill(.black.opacity(0.55)).overlay(alignment: .leading) {
                    Capsule().fill(p.accent).frame(width: max(4, g.size.width * f))
                }
            }
            .frame(height: 4).padding(.horizontal, 6).padding(.bottom, 5)
            .accessibilityLabel("\(Int(f * 100)) percent watched")
        case .finished?:
            HStack {
                Spacer()
                Image(systemName: "checkmark.circle.fill").font(.caption.weight(.bold)).foregroundStyle(.white, p.accent)
                    .padding(4).accessibilityLabel("Watched")
            }
        default:
            EmptyView()
        }
    }
}

/// Every per-video action; used by the ⋮ menu, the ⋯ button and the right-click menu.
struct VideoActions: View {
    @Environment(AppModel.self) private var model
    let video: Video
    var playlistID: Int64? = nil

    var body: some View {
        let media = model.existingMedia(video)
        let playable = model.store.playable(for: video.id)
        let context = playlistID ?? (model.section == .playlists ? model.store.openPlaylistID : nil)
        Button("Play") { model.play(video, in: context) }.disabled(playable == nil)
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
        ForEach(model.store.playlistsOf(video.id)) { pl in
            Button("Show in Playlist “\(pl.name)”") { model.openPlaylist(pl.id, selecting: video.id) }
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

/// Saved audio and video, grouped by playlist (then Individual Downloads), one row per video with its files.
struct DownloadsList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var show = Show.all

    enum Show: String, CaseIterable { case all = "All", available = "Available", missing = "Missing" }

    var body: some View {
        let store = model.store
        let media = store.files.filter(\.isMedia)
        let onDisk = media.filter(\.exists)
        let usedBytes = onDisk.reduce(0) { $0 + (Self.diskSize($1.path) ?? 0) }
        let items = media.filter {
            (show == .all || (show == .available) == $0.exists)
                && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || ($0.videoTitle ?? "").localizedCaseInsensitiveContains(query)
                    || store.playlistsOf($0.videoID).contains { $0.name.localizedCaseInsensitiveContains(query) })
        }
        let byVideo = Dictionary(grouping: items, by: \.videoID)
        let videos = store.all.filter { byVideo[$0.id] != nil }
        let g = Grouping.make(videos, playlists: store.playlists, members: store.members)
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Downloads", icon: "arrow.down.to.line")
            // what your saved audio and video take up, and what's left, for planning a flight
            HStack(spacing: 6) {
                Image(systemName: "internaldrive").foregroundStyle(p.secondary)
                Text((["\(store.videoOnMacIDs.count) videos offline", "\(onDisk.count) files", Fmt.bytes(usedBytes)]
                      + [model.freeDiskSpace.map { "\(Fmt.bytes(Int($0))) free" }].compactMap { $0 }).compactMap { $0 }.joined(separator: " • "))
            }
            .font(.callout).foregroundStyle(p.secondary)
            .accessibilityElement(children: .combine)
            SearchField(text: $query, prompt: "Search downloads or playlists…")
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
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(g.groups) { group in
                            let open = !query.isEmpty || store.expanded.contains(group.playlist.id)
                            header(group.playlist, open: open)
                            if open {
                                ForEach(group.videos) { v in
                                    VideoFilesRow(video: v, files: byVideo[v.id] ?? [], number: store.episode(v.id, in: group.playlist.id))
                                }
                                .padding(.leading, 6)
                            }
                        }
                        if !g.individual.isEmpty {
                            if !g.groups.isEmpty {
                                Text("Individual Downloads").font(.callout.weight(.semibold)).foregroundStyle(p.secondary).padding(.top, 6)
                            }
                            ForEach(g.individual) { v in VideoFilesRow(video: v, files: byVideo[v.id] ?? []) }
                        }
                    }
                    .padding(2)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The playlist's own numbers (unique videos, not files), whatever the filter shows.
    private func header(_ pl: PlaylistSummary, open: Bool) -> some View {
        let store = model.store
        let ids = store.members[pl.id] ?? []
        let have = store.offlineCount(pl.id)
        let audioOnly = store.audioOnlyCount(pl.id)
        let bytes = store.files.filter { $0.isMedia && $0.exists && ids.contains($0.videoID) }.reduce(0) { $0 + (Self.diskSize($1.path) ?? 0) }
        return HStack(spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                    if store.expanded.contains(pl.id) { store.expanded.remove(pl.id) } else { store.expanded.insert(pl.id) }
                }
            } label: {
                HStack(spacing: 12) {
                    Thumbnail(url: pl.coverURL, localPath: pl.coverPath, cornerRadius: 10, icon: "music.note.list").frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pl.name).font(.callout.weight(.semibold)).lineLimit(2)
                        Text(([("\(have) of \(ids.count) videos downloaded"), ids.count > have ? "\(ids.count - have) missing" : nil,
                               audioOnly > 0 ? "\(audioOnly) audio only" : nil, Fmt.bytes(bytes)] as [String?]).compactMap { $0 }.joined(separator: " • "))
                            .font(.caption).foregroundStyle(p.secondary).lineLimit(2)
                        Text(have == ids.count ? "Available offline" : have == 0 ? "Not offline yet" : "Partly offline")
                            .font(.caption2.weight(.semibold)).foregroundStyle(have == ids.count ? p.green : p.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.callout.weight(.semibold)).foregroundStyle(p.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "expanded" : "collapsed")
            if ids.count > have {
                Button { model.askDownloadMissing(pl.id) } label: { Label("Download Missing", systemImage: "arrow.down.circle") }
                    .buttonStyle(SecondaryButtonStyle(height: 28, font: .caption.weight(.semibold), iconOnly: true))
                    .help("Download the \(ids.count - have) missing videos (asks first; nothing you have is downloaded again)")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(p.card))
        .contextMenu { PlaylistActions(playlist: pl) }
    }

    /// The file's real size (through a symlink, if it is one).
    static func diskSize(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)[.size] as? NSNumber)?.intValue
    }
}

/// One video with each of its files (MP4, MP3…) as a line, so two downloads of one video are still one video.
struct VideoFilesRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let video: Video
    let files: [FileItem]
    var number: Int? = nil

    var body: some View {
        let selected = model.store.selectedID == video.id
        HStack(alignment: .top, spacing: 10) {
            if let number {
                Text("\(number)").font(.callout.monospacedDigit()).foregroundStyle(p.secondary).frame(minWidth: 20, alignment: .trailing).padding(.top, 10)
            }
            Thumbnail(url: video.thumbnailURL, localPath: video.thumbnailPath, cornerRadius: 7).frame(width: 64, height: 36).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(video.displayTitle).font(.callout.weight(.semibold)).lineLimit(2)
                ForEach(files.sorted { ($0.role == .video ? 0 : 1, $0.name) < ($1.role == .video ? 0 : 1, $1.name) }) { f in line(f) }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? p.accentDark.opacity(0.22) : p.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? p.accent : p.border.opacity(0.5)))
        .contentShape(Rectangle())
        .onTapGesture { model.open(video, tab: .downloads) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(video.displayTitle)
    }

    private func line(_ f: FileItem) -> some View {
        let exists = f.exists
        let format = (f.path as NSString).pathExtension.uppercased()
        return HStack(spacing: 8) {
            Image(systemName: f.role == .video ? "film" : "music.note").foregroundStyle(exists ? p.accent : p.secondary).frame(width: 14)
            Text(([format.isEmpty ? f.role.rawValue : format, Fmt.bytes(f.size ?? (exists ? DownloadsList.diskSize(f.path) : nil))] as [String?])
                .compactMap { $0 }.joined(separator: " • "))
                .font(.caption.monospacedDigit()).foregroundStyle(p.secondary)
            Text(exists ? "Available" : "Missing")
                .font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                .foregroundStyle(exists ? p.green : p.accent)
                .background(Capsule().fill((exists ? p.green : p.accent).opacity(0.15)))
            Spacer(minLength: 4)
            if exists {
                IconButton(icon: "play.circle", label: "Open \(f.name)", size: 22) { FileOps.open(f.path) }
                IconButton(icon: "folder", label: "Show in Finder", size: 22) { FileOps.reveal(f.path) }
            } else if video.url != nil {
                Button("Download Again") { model.downloadAgain(video, kind: f.role == .video ? .video : .audio) }
                    .buttonStyle(.link).tint(p.accent).font(.caption)
            }
        }
        .help(f.path)
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
