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
        case .watchLater: WatchLaterList()
        case .library, .favorites, .settings, .youtube: LibraryList(continueWatching: false)
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
                // 4.0 G2: an empty filter (Favorites, a chip) isn't an empty library
                let filtered = store.search.isEmpty && !store.all.isEmpty
                EmptyState(icon: !store.search.isEmpty ? "magnifyingglass" : store.filter == .favorites ? "heart" : "tray",
                           title: !store.search.isEmpty ? "No matches" : store.filter == .favorites ? "No favorites yet" : filtered ? "Nothing here" : "Nothing here yet",
                           message: !store.search.isEmpty
                               ? "Nothing in titles, channels, links, summaries or transcripts matches “\(store.search)”."
                               : store.filter == .favorites ? "Star a video (☆) to keep it here."
                               : filtered ? "No video in your library matches \(store.filter.rawValue). Choose All to see everything."
                               : "Paste a link above and press Video, Audio or Summarize. Everything you process is kept here.")
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
            Text("This removes every library record, including favorites. Downloaded files, summaries and transcripts in your downloads folder are not touched, and Watch Later is kept.")
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
                            Text(([shown < total ? "\(shown) of \(Fmt.count(total, "video"))" : Fmt.count(total, "video"),
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
        Button("Prepare Missing for Offline…") { model.askDownloadMissing(playlist.id) }
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
                            Text("\(Fmt.count(store.members[pl.id]?.count ?? pl.count, "video")) • \(store.offlineCount(pl.id)) offline")
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
    @AppStorage("downloadsShow") private var show = Show.ready
    @AppStorage("offlineReserveGB") private var reserveGB = 10

    /// 4.0 Phase 4 (Offline Hub): Ready = on this Mac and not found damaged; Problems = missing or damaged; Preparing =
    /// downloads waiting, running or failed; All = every registered file.
    enum Show: String, CaseIterable { case ready = "Ready", problems = "Problems", preparing = "Preparing", all = "All" }

    var body: some View {
        let store = model.store, checker = model.media
        // every registered file of every source (downloads, Raycast, import), by role: video, audio, transcript, summary
        let media = store.files.filter(\.isMedia)
        let onDisk = media.filter(\.exists)
        let usedBytes = onDisk.reduce(0) { $0 + (Self.diskSize($1.path) ?? 0) }
        let problem = { (f: FileItem) -> Bool in
            if case .damaged = checker.state(f.path) { return true }
            return !f.exists
        }
        let preparing = Set(store.all.filter { v in
            let a = Self.youtubeAvailability(model, v)
            return [a.video, a.audio].contains { $0 != .none }
        }.map(\.id))
        let items = media.filter { f in
            let inShow = switch show {
            case .ready: !problem(f)
            case .problems: problem(f)
            case .preparing: preparing.contains(f.videoID)
            case .all: true
            }
            return inShow && (query.isEmpty || f.name.localizedCaseInsensitiveContains(query) || (f.videoTitle ?? "").localizedCaseInsensitiveContains(query)
                              || store.playlistsOf(f.videoID).contains { $0.name.localizedCaseInsensitiveContains(query) })
        }
        let byVideo = Dictionary(grouping: items, by: \.videoID)
        // Preparing also lists videos with nothing on this Mac yet
        let videos = store.all.filter { byVideo[$0.id] != nil || (show == .preparing && preparing.contains($0.id)
                                                                     && (query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query))) }
        let g = Grouping.make(videos, playlists: store.playlists, members: store.members)
        let counts: [Show: Int] = [.ready: media.filter { !problem($0) }.count, .problems: media.filter(problem).count,
                                   .preparing: preparing.count, .all: media.count]
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Downloads", icon: "arrow.down.to.line")
                Spacer()
                prepareMenu
            }
            // what your saved audio and video take up, and what's left, for planning a trip
            HStack(spacing: 6) {
                Image(systemName: "internaldrive").foregroundStyle(p.secondary)
                Text(([Fmt.count(store.videoOnMacIDs.count, "video") + " offline", Fmt.count(onDisk.count, "file"), Fmt.bytes(usedBytes)]
                      + [model.freeDiskSpace.map { "\(Fmt.bytes(Int($0))) free" }, "keeping \(reserveGB) GB"]).compactMap { $0 }.joined(separator: " • "))
                Spacer(minLength: 6)
                Button { checker.check(onDisk.map(\.path)) } label: {
                    Label(checker.running == nil ? "Check Files" : "Checking…", systemImage: "checkmark.shield")
                }
                .buttonStyle(SecondaryButtonStyle(height: 26, font: .caption.weight(.semibold)))
                .help("Checks that each file opens and plays here (read-only; a quick check, not a full decode). Right-click a file for a deep check.")
                .testProbe("checkFiles")
            }
            .font(.callout).foregroundStyle(p.secondary)
            .accessibilityElement(children: .contain)
            SearchField(text: $query, prompt: "Search downloads or playlists…")
            HStack(spacing: 7) {
                ForEach(Show.allCases, id: \.self) { s in
                    ChipButton(title: "\(s.rawValue) \(counts[s] ?? 0)", selected: show == s) { show = s }
                }
            }
            if videos.isEmpty {
                EmptyState(icon: show == .problems ? "checkmark.seal" : "arrow.down.circle",
                           title: media.isEmpty && show != .preparing ? "No downloads yet" : show == .problems ? "No problems" : "Nothing here",
                           message: show == .problems ? "Every registered file is where the library expects it, and none was found damaged."
                               : show == .preparing ? "Nothing is waiting to download. Prepare for Offline queues videos from Watch Later or a playlist."
                               : media.isEmpty ? "Audio and video you save appear here with their size, quality and location." : "No downloads match this filter.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(g.groups) { group in
                            let open = !query.isEmpty || store.expanded.contains(group.playlist.id) || show != .ready
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
        // files you have are checked in the background (read-only); missing ones are looked for in the downloads folder
        .onAppear {
            checker.check(onDisk.map(\.path))
            checker.lookForMoved(media, in: AppSettings.downloadDir)
        }
        .onChange(of: store.files) { checker.lookForMoved(store.files.filter(\.isMedia), in: AppSettings.downloadDir) }
        .alert("Relink this file?", isPresented: Binding(get: { model.pendingRelink != nil }, set: { if !$0 { model.pendingRelink = nil } })) {
            Button("Relink") { model.confirmRelink() }.testProbe("confirmRelink")
            Button("Cancel", role: .cancel) { model.pendingRelink = nil }
        } message: {
            Text("Video Buddy's record of “\(model.pendingRelink?.file.name ?? "")” will point to\n\(model.pendingRelink?.to ?? "")\nThe file isn't moved, renamed or changed, and its resume position comes along.")
        }
    }

    /// Prepare for Offline from Watch Later or a playlist (the videos not on this Mac yet).
    private var prepareMenu: some View {
        let store = model.store
        let later = store.watchLater.filter { model.availability(youtubeID: $0.youtubeID).videoFile == nil }
        return Menu {
            Button("From Watch Later (\(later.count))") { model.prepareForOffline(later.map { (id: $0.youtubeID, title: $0.title) }, from: "Watch Later") }
                .disabled(later.isEmpty)
            if !store.playlists.isEmpty {
                Divider()
                ForEach(store.playlists) { pl in
                    Button("From “\(pl.name)”") { model.askDownloadMissing(pl.id) }
                }
            }
        } label: {
            Label("Prepare for Offline…", systemImage: "arrow.down.circle")
        }
        .menuStyle(.button).fixedSize()
        .help("Choose videos to download, with their checks, sizes and your free space; nothing starts until you queue them")
        .testProbe("prepareMenu")
    }

    /// A YouTube entry's availability (what the Preparing tab lists).
    static func youtubeAvailability(_ model: AppModel, _ v: Video) -> VideoAvailability {
        AppModel.youtubeID(v).map { model.availability(youtubeID: $0) } ?? VideoAvailability()
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
                Button { model.askDownloadMissing(pl.id) } label: { Label("Prepare Missing for Offline", systemImage: "arrow.down.circle") }
                    .buttonStyle(SecondaryButtonStyle(height: 28, font: .caption.weight(.semibold), iconOnly: true))
                    .help("Prepare the \(ids.count - have) missing videos for offline (you choose; nothing you have is downloaded again)")
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
                extras
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

    /// 4.0 Phase 4: a media file with its format, size, quality and length (once checked), what the check found, and
    /// what you can do: play it, show it, or for a missing one relink it (after you confirm) or download it again.
    private func line(_ f: FileItem) -> some View {
        let exists = f.exists
        let format = (f.path as NSString).pathExtension.uppercased()
        let state = model.media.state(f.path)
        let info = state.info
        let tone: Color = switch state {
        case .opensHere, .fullyChecked: p.green
        case .opensElsewhere, .notChecked, .checking: p.secondary
        case .missing, .damaged: p.orange
        }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: f.role == .video ? "film" : "music.note").foregroundStyle(exists ? p.accent : p.secondary).frame(width: 14)
                Text(([f.role == .video ? "Video" : "Audio", info?.quality, format.isEmpty ? nil : format,
                       Fmt.bytes(f.size ?? (exists ? DownloadsList.diskSize(f.path) : nil)), info?.duration.flatMap(Fmt.duration)] as [String?])
                    .compactMap { $0 }.joined(separator: " • "))
                    .font(.caption.monospacedDigit()).foregroundStyle(p.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if state.usable || state == .notChecked || state == .checking {
                    if f.isPlayable, !state.opensElsewhere {
                        Button(f.role == .video ? "Play Offline" : "Play Audio") { model.playFile(f) }   // exactly this file
                            .buttonStyle(.link).tint(p.accent).font(.caption.weight(.semibold))
                            .testProbe("play \(f.name)")
                    } else {
                        IconButton(icon: "arrow.up.forward.app", label: "Open \(f.name) in another app", size: 22) { FileOps.open(f.path) }
                    }
                    IconButton(icon: "folder", label: "Show in Finder", size: 22) { FileOps.reveal(f.path) }
                } else if case .missing = state {
                    if let found = model.media.foundElsewhere[f.path] {
                        Button("Relink…") { model.pendingRelink = (f, found) }.buttonStyle(.link).tint(p.accent).font(.caption.weight(.semibold))
                            .help("A file with this name is at \(found)")
                    }
                    Button("Locate…") { model.locate(f) }.buttonStyle(.link).font(.caption)
                }
                if !state.usable, state != .notChecked, state != .checking, video.url != nil {
                    Button("Download Again") { model.downloadAgain(video, kind: f.role == .video ? .video : .audio) }
                        .buttonStyle(.link).tint(p.accent).font(.caption)
                }
            }
            // 4.0 G1b: several copies of the same kind (e.g. 720p and 1080p) each name their file
            Text((state == .missing && model.media.foundElsewhere[f.path] != nil
                  ? "Missing here; a file of the same name is at \(model.media.foundElsewhere[f.path] ?? "")" : state.label)
                 + (files.filter { $0.role == f.role }.count > 1 ? " · \(f.name)" : ""))
                .font(.caption2.weight(.semibold)).foregroundStyle(tone).lineLimit(2).padding(.leading, 22)
        }
        .help(f.path)
        .contextMenu {
            if exists {
                Button("Check Again") { model.media.check([f.path], again: true) }
                Button("Deep Check (decode every frame)") { model.media.check([f.path], deep: true, again: true) }
                Button("Show in Finder") { FileOps.reveal(f.path) }
            }
            Button("Open in Library") { model.open(video, tab: .downloads); model.section = .library }
            if !exists { Button("Locate…") { model.locate(f) } }
        }
    }

    /// The video's transcript and summary, when the library has them.
    @ViewBuilder private var extras: some View {
        let texts = model.store.files(for: video.id).filter { !$0.isMedia }
        let transcript = texts.contains { $0.role == .transcript && $0.exists }
        let summary = video.hasSummary || texts.contains { $0.role == .summary && $0.exists }
        if transcript || summary {
            HStack(spacing: 10) {
                if summary { Label("Summary", systemImage: "sparkles").foregroundStyle(p.accent) }
                if transcript { Label("Transcript", systemImage: "text.quote").foregroundStyle(p.secondary) }
                Spacer(minLength: 0)
                Button("Open in Library") { model.open(video, tab: summary ? .summary : .transcript); model.section = .library }
                    .buttonStyle(.link).font(.caption)
            }
            .font(.caption2.weight(.semibold))
        }
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
