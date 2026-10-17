// The middle card: History / Favorites browser, Home's recent activity, or the Downloads list.
import SwiftUI

struct CenterColumn: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        switch model.section {
        case .home: RecentCard()
        case .downloads: DownloadsCard()
        case .playlists: PlaylistsCard()
        case .favorites: HistoryCard(title: "Favorites", icon: "star")
        case .history, .settings: HistoryCard(title: "History", icon: "clock.arrow.circlepath")
        }
    }
}

private struct QueryKey: Equatable {
    let filter: HistoryFilter
    let sort: HistorySort
    let search: String
}

struct HistoryCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let title: String
    let icon: String
    @State private var confirmClear = false
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    var body: some View {
        @Bindable var store = model.store
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { confirmClear = true } label: { Label("Clear All", systemImage: "trash") }
                    .buttonStyle(SecondaryButtonStyle(height: 34, font: .callout))
                    .disabled(store.videos.isEmpty && store.filter == .all && store.search.isEmpty)
            }
            SearchField(text: $store.search, prompt: "Search your history…").focused($searchFocused)
            FlowLayout(spacing: 8) {
                ForEach(HistoryFilter.allCases) { f in
                    ChipButton(title: f.rawValue, icon: f == .favorites ? "star" : f == .onMac ? "laptopcomputer" : nil, selected: store.filter == f) {
                        store.filter = f
                        if model.section == .favorites, f != .favorites { model.section = .history }
                    }
                }
                Menu {
                    Picker("Sort by", selection: $store.sort) {
                        ForEach(HistorySort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(store.sort.rawValue, systemImage: "arrow.up.arrow.down").font(.callout)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .frame(height: 32)
                .help("Sort history")
            }
            if store.videos.isEmpty {
                EmptyState(icon: store.search.isEmpty ? "tray" : "magnifyingglass",
                           title: store.search.isEmpty ? "Nothing here yet" : "No matches",
                           message: store.search.isEmpty
                               ? "Paste a link above and press Summarize. Everything you process is saved here."
                               : "Nothing in titles, channels, links, summaries or transcripts matches “\(store.search)”.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.videos) { HistoryRow(video: $0) }
                    }
                    .padding(2)
                }
                .scrollIndicators(.visible)
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { store.move(1); return .handled }
                .onKeyPress(.upArrow) { store.move(-1); return .handled }
            }
        }
        .cardStyle()
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: QueryKey(filter: store.filter, sort: store.sort, search: store.search)) {
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return } // debounce typing
            await store.reload()
        }
        .onChange(of: model.focusSearchToken) { searchFocused = true }
        .confirmationDialog("Clear all history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear All History", role: .destructive) { model.clearAll() }
        } message: {
            Text("This removes every history record, including favorites. Downloaded files, summaries and transcripts in your downloads folder are not touched.")
        }
    }
}

struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let video: Video

    var body: some View {
        let selected = model.store.selectedID == video.id
        HStack(alignment: .top, spacing: 12) {
            Thumbnail(url: video.thumbnailURL, localPath: video.thumbnailPath, duration: video.duration,
                      icon: video.hasSummary || video.hasVideo ? "play.rectangle.fill" : "waveform")
                .frame(width: 128, height: 72)
                .overlay(alignment: .topLeading) {
                    if model.store.onMacIDs.contains(video.id) {
                        Image(systemName: "laptopcomputer")
                            .font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(4).background(Capsule().fill(p.green.opacity(0.9))).padding(5)
                            .help("On this Mac: plays offline")
                            .accessibilityLabel("On this Mac")
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(video.displayTitle).font(.headline).lineLimit(1)
                Text(video.displayChannel).foregroundStyle(p.secondary).lineLimit(1)
                Text(Fmt.date(video.lastProcessed)).font(.callout).foregroundStyle(p.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 6) {
                StatusPill(video: video)
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    IconButton(icon: video.favorite ? "star.fill" : "star",
                               label: video.favorite ? "Remove from favorites" : "Add to favorites",
                               tint: video.favorite ? p.gold : p.secondary) { model.toggleFavorite(video) }
                    Menu { VideoActions(video: video) } label: {
                        Image(systemName: "ellipsis").rotationEffect(.degrees(90)).frame(width: 26, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More actions")
                    .accessibilityLabel("More actions")
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(selected ? p.blue.opacity(0.10) : p.card))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(selected ? p.blue : .clear, lineWidth: 2))
        .shadow(color: p.blue.opacity(selected ? 0.25 : 0), radius: 6)
        .contentShape(RoundedRectangle(cornerRadius: 13))
        .onTapGesture { model.open(video, tab: model.detailTab) }
        .contextMenu { VideoActions(video: video) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(video.displayTitle), \(video.displayChannel)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.open(video, tab: model.detailTab) }
    }
}

/// Every per-video action; used by the ⋮ menu and the right-click menu.
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
        Button("Remove from History…", role: .destructive) { model.pendingRemoval = video }
    }
}

struct RecentCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "house").font(.title2)
                Text("Recent activity").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("See all") { model.section = .history }.buttonStyle(.link)
            }
            if model.store.recent.isEmpty {
                EmptyState(icon: "sparkles", title: "Welcome to your video library",
                           message: "Paste a YouTube link above and press Summarize. Summaries, transcripts and downloads are kept here for good.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) { ForEach(model.store.recent) { HistoryRow(video: $0) } }.padding(2)
                }
            }
        }
        .cardStyle()
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct DownloadsCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @State private var query = ""

    var body: some View {
        let items = model.store.files.filter(\.isMedia).filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || ($0.videoTitle ?? "").localizedCaseInsensitiveContains(query)
        }
        let onDisk = model.store.files.filter { $0.isMedia && $0.exists }
        let usedBytes = onDisk.reduce(0) { $0 + (Self.diskSize($1.path) ?? 0) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.to.line").font(.title2)
                Text("Downloads").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
            }
            // what your saved audio and video take up, and what's left, for planning a flight
            HStack(spacing: 6) {
                Image(systemName: "internaldrive").foregroundStyle(p.secondary)
                Text(([("\(onDisk.count) files on this Mac"), Fmt.bytes(usedBytes)]
                      + [model.freeDiskSpace.map { "\(Fmt.bytes(Int($0))) free" }].compactMap { $0 }).joined(separator: " • "))
            }
            .font(.callout).foregroundStyle(p.secondary)
            .accessibilityElement(children: .combine)
            SearchField(text: $query, prompt: "Search downloads…")
            if items.isEmpty {
                EmptyState(icon: "arrow.down.circle", title: "No downloads yet",
                           message: "Audio and video you save appear here with their size and location.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(items) { item in
                            FileRow(item: item, showVideoTitle: true)
                                .contentShape(Rectangle())
                                .onTapGesture { model.store.select(item.videoID); model.detailTab = .downloads }
                        }
                    }
                    .padding(2)
                }
            }
        }
        .cardStyle()
        .frame(maxHeight: .infinity, alignment: .top)
    }

    static func diskSize(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue
    }
}

/// A saved file with its real size, location and whether it's still on disk.
struct FileRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let item: FileItem
    var showVideoTitle = false
    var onDownloadAgain: (() -> Void)?

    var body: some View {
        let exists = item.exists
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(exists ? p.blue : p.secondary)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(p.elevated))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.callout.weight(.semibold)).lineLimit(2)
                if showVideoTitle, let t = item.videoTitle { Text(t).font(.caption).foregroundStyle(p.secondary).lineLimit(1) }
                Text("\(item.role.rawValue) • \(Fmt.bytes(item.size ?? (exists ? diskSize : nil))) • \(Fmt.date(item.date))")
                    .font(.caption).foregroundStyle(p.secondary)
                Text(item.path).font(.caption2).foregroundStyle(p.secondary.opacity(0.8)).lineLimit(1).truncationMode(.middle)
                    .help(item.path)
                HStack(spacing: 8) {
                    Text(exists ? "Available" : "Missing")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .foregroundStyle(exists ? p.green : p.red)
                        .background(Capsule().fill((exists ? p.green : p.red).opacity(0.15)))
                    Button("Open") { FileOps.open(item.path) }.disabled(!exists).opacity(exists ? 1 : 0.35)
                    Button("Show in Finder") { FileOps.reveal(item.path) }.disabled(!exists).opacity(exists ? 1 : 0.35)
                    if !exists, let onDownloadAgain { Button("Download Again", action: onDownloadAgain) }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(p.elevated.opacity(0.35)))
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
