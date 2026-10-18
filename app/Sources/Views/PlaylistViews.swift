// My Playlists (the sidebar section) and the YouTube playlist preview sheet.
import SwiftUI

struct PlaylistsCard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if let id = model.store.openPlaylistID, let playlist = model.store.playlists.first(where: { $0.id == id }) {
            PlaylistDetailCard(playlist: playlist)
        } else {
            PlaylistListCard()
        }
    }
}

private func totalTime(_ seconds: Double) -> String? { seconds > 0 ? Fmt.watchTime(seconds) : nil }

struct PlaylistListCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p

    var body: some View {
        let store = model.store
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "music.note.list").font(.title2)
                Text("My Playlists").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { model.namePrompt = .new(adding: nil) } label: { Label("New Playlist", systemImage: "plus") }
                    .buttonStyle(SecondaryButtonStyle(height: 34, font: .callout))
            }
            if store.playlists.isEmpty {
                EmptyState(icon: "music.note.list", title: "No playlists yet",
                           message: "Paste a YouTube playlist link above, or use ⋮ → Add to Playlist on any video in your history.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.playlists) { playlist in
                            Button { store.openPlaylistID = playlist.id } label: { row(playlist) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Rename…") { model.namePrompt = .rename(playlist) }
                                    Button("Delete Playlist…", role: .destructive) { model.pendingPlaylistDeletion = playlist }
                                }
                        }
                    }
                    .padding(2)
                }
            }
        }
        .cardStyle()
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ playlist: PlaylistSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: playlist.sourceURL != nil ? "play.rectangle.on.rectangle" : "music.note.list")
                .font(.title3).foregroundStyle(p.blue)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 11).fill(p.blue.opacity(0.15)))
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name).font(.headline).lineLimit(1)
                Text(([("\(playlist.count) videos")] + [totalTime(playlist.totalDuration)].compactMap { $0 }
                      + (playlist.sourceURL != nil ? ["from YouTube"] : [])).joined(separator: " • "))
                    .font(.callout).foregroundStyle(p.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(p.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(p.elevated.opacity(0.35)))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct PlaylistDetailCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let playlist: PlaylistSummary

    var body: some View {
        let store = model.store
        let onMac = store.playlistVideos.filter { store.onMacIDs.contains($0.id) }.count
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                IconButton(icon: "chevron.left", label: "All playlists", tint: p.text) { store.openPlaylistID = nil }
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name).font(.title2.weight(.semibold)).lineLimit(1).accessibilityAddTraits(.isHeader)
                    Text((["\(playlist.count) videos", "\(onMac) on this Mac"] + [totalTime(playlist.totalDuration)].compactMap { $0 })
                        .joined(separator: " • ")).font(.callout).foregroundStyle(p.secondary)
                }
                Spacer()
                Menu {
                    Button("Rename…") { model.namePrompt = .rename(playlist) }
                    if let url = playlist.sourceURL { Button("Open on YouTube") { FileOps.openLink(url) } }
                    Divider()
                    Button("Delete Playlist…", role: .destructive) { model.pendingPlaylistDeletion = playlist }
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Playlist options")
            }
            HStack(spacing: 10) {
                Button { model.playAll() } label: { Label("Play All", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle(height: 36))
                    .disabled(onMac == 0)
                    .help(onMac == 0 ? "Make the videos available offline first" : "Play the videos on this Mac in order")
                Button { model.askMakeAllAvailableOffline() } label: { Label("Make All Available Offline", systemImage: "arrow.down.circle") }
                    .buttonStyle(SecondaryButtonStyle(height: 36, font: .callout))
                    .disabled(onMac == playlist.count)
            }
            if store.playlistVideos.isEmpty {
                EmptyState(icon: "tray", title: "This playlist is empty",
                           message: "Use ⋮ → Add to Playlist on any video in your history.")
            } else {
                List {
                    ForEach(store.playlistVideos) { video in
                        HistoryRow(video: video)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                    .onMove { model.movePlaylistItems(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                Text("Drag videos to reorder.").font(.caption).foregroundStyle(p.secondary)
            }
        }
        .cardStyle()
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Preview of a YouTube playlist before anything is queued: tick videos, pick what to do, optionally save it.
struct PlaylistImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let state: PlaylistImportState
    @State private var selected: Set<String> = []
    @State private var action = JobAction.summarize
    @AppStorage("transcribeDownloads") private var transcribe = false
    @State private var save = true
    @State private var name = ""

    var body: some View {
        let preview = state.preview
        let chosen = preview.entries.filter { selected.contains($0.id) }
        let unavailable = preview.entries.count - preview.available.count
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.title).font(.title2.weight(.semibold)).lineLimit(2)
                Text((["\(preview.entries.count) videos"] + [totalTime(preview.available.compactMap(\.duration).reduce(0, +))].compactMap { $0 }
                      + (unavailable > 0 ? ["\(unavailable) private or deleted"] : [])).joined(separator: " • "))
                    .foregroundStyle(.secondary)
            }
            Picker("For each video", selection: $action) {
                Text("Summarize").tag(JobAction.summarize)
                Text("Audio").tag(JobAction.audio)
                Text("Video").tag(JobAction.video)
            }
            .pickerStyle(.segmented)
            if action != .summarize {
                Toggle("+ Transcript: also transcribe each one on this Mac (no summary)", isOn: $transcribe)
                    .toggleStyle(.checkbox)
            }
            HStack {
                Button("Select All") { selected = Set(preview.available.map(\.id)) }
                Button("Select None") { selected = [] }
                Spacer()
                Text("\(chosen.count) selected" + (totalTime(chosen.compactMap(\.duration).reduce(0, +)).map { " • \($0)" } ?? ""))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.link)
            List(preview.entries) { entry in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { selected.contains(entry.id) },
                                             set: { if $0 { selected.insert(entry.id) } else { selected.remove(entry.id) } }))
                        .toggleStyle(.checkbox).labelsHidden()
                        .disabled(!entry.available)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title).lineLimit(1)
                        if let c = entry.channel { Text(c).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(Fmt.duration(entry.duration) ?? "").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                .opacity(entry.available ? 1 : 0.4)
            }
            .frame(minHeight: 220)
            Toggle("Save as one of My Playlists", isOn: $save)
            if save { TextField("Playlist name", text: $name).textFieldStyle(.roundedBorder) }
            HStack {
                if action == .video, let free = model.freeDiskSpace {
                    Label("\(Fmt.bytes(Int(free))) free on this Mac", systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { model.playlistImport = nil }.keyboardShortcut(.cancelAction)
                Button("Add \(chosen.count) to Queue") {
                    model.importPlaylist(chosen, action: .download(action.kind, transcript: transcribe),
                                         saveAs: save ? name : nil, sourceURL: preview.url)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620, height: 640)
        .onAppear {
            selected = Set(preview.available.map(\.id))
            action = state.action.kind == .audio || state.action.kind == .video ? .from(kind: state.action.kind) : .summarize
            name = preview.title
        }
    }
}
