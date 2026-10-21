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
            SectionHeader(title: "My Playlists", icon: "music.note.list") {
                Button { model.namePrompt = .new(adding: nil) } label: { Label("New Playlist", systemImage: "plus") }
                    .buttonStyle(SecondaryButtonStyle(height: 32, font: .callout))
            }
            if store.playlists.isEmpty {
                EmptyState(icon: "music.note.list", title: "No playlists yet",
                           message: "Paste a YouTube playlist link above, or use ⋮ → Add to Playlist on any video in your library.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.playlists) { playlist in
                            Button { store.openPlaylistID = playlist.id } label: { row(playlist) }
                                .buttonStyle(.plain)
                                .contextMenu { PlaylistActions(playlist: playlist) }
                        }
                    }
                    .padding(2)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ playlist: PlaylistSummary) -> some View {
        HStack(spacing: 12) {
            Thumbnail(url: playlist.coverURL, localPath: playlist.coverPath, cornerRadius: 9, icon: "music.note.list")
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name).font(.headline).lineLimit(2)
                Text(([("\(playlist.count) videos"), "\(model.store.offlineCount(playlist.id)) offline"]
                      + [totalTime(playlist.totalDuration)].compactMap { $0 }).joined(separator: " • "))
                    .font(.callout).foregroundStyle(p.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(p.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(p.card))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One playlist, laid out like an album: artwork, title, counts, Play All / Continue, then the numbered episodes.
struct PlaylistDetailCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let playlist: PlaylistSummary

    var body: some View {
        let store = model.store
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IconButton(icon: "chevron.left", label: "All playlists", tint: p.text) { store.openPlaylistID = nil }
                Text("Playlists").font(.callout).foregroundStyle(p.secondary)
                Spacer()
                Menu { PlaylistActions(playlist: playlist) } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.bold)).foregroundStyle(p.secondary)
                        .frame(width: 32, height: 32).background(Circle().fill(p.elevated))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Playlist options").accessibilityLabel("Playlist options")
            }
            List {
                header.listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 10, trailing: 0))
                if store.playlistVideos.isEmpty {
                    EmptyState(icon: "tray", title: "This playlist is empty",
                               message: "Use Add Videos, or ⋮ → Add to Playlist on any video in your library.")
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                ForEach(Array(store.playlistVideos.enumerated()), id: \.element.id) { i, video in
                    VideoRow(video: video, playlistID: playlist.id, number: i + 1)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                }
                .onMove { model.movePlaylistItems(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            if !store.playlistVideos.isEmpty {
                Text("Drag episodes to reorder.").font(.caption).foregroundStyle(p.secondary)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        let store = model.store
        let total = store.playlistVideos.count
        let missing = store.playlistVideos.filter { !store.hasLocalVideo($0.id) }.count
        let audioOnly = store.audioOnlyCount(playlist.id)
        let resume = store.resumeTarget(playlist.id)
        let playable = !store.playableMembers(playlist.id).isEmpty
        return VStack(spacing: 10) {
            Thumbnail(url: playlist.coverURL, localPath: playlist.coverPath, cornerRadius: 16, icon: "music.note.list")
                .frame(width: 176, height: 176)
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
            Text(playlist.name).font(.title3.weight(.bold)).multilineTextAlignment(.center).lineLimit(3)
                .accessibilityAddTraits(.isHeader)
            Text((["\(total) videos"] + [totalTime(playlist.totalDuration)].compactMap { $0 }
                  + ["\(total - missing) downloaded"] + (audioOnly > 0 ? ["\(audioOnly) audio only"] : [])).joined(separator: " • "))
                .font(.callout).foregroundStyle(p.secondary).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button { model.playAll(playlist.id) } label: { Label("Play All", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle(height: 36, font: .callout.weight(.semibold)))
                    .disabled(!playable)
                    .help(playable ? "Play the episodes on this Mac in order" : "Download the videos first")
                if let id = resume, let n = store.episode(id, in: playlist.id) {
                    Button { model.continuePlaylist(playlist.id) } label: { Label("Continue Ep \(n)", systemImage: "arrow.clockwise") }
                        .buttonStyle(SecondaryButtonStyle(height: 36, font: .callout.weight(.semibold)))
                        .help("Resume where you are in this playlist")
                }
            }
            HStack(spacing: 8) {
                Button { model.askDownloadMissing(playlist.id) } label: {
                    Label(missing == 0 ? "All Downloaded" : "Download \(missing) Missing", systemImage: missing == 0 ? "checkmark.circle" : "arrow.down.circle")
                }
                .buttonStyle(SecondaryButtonStyle(height: 30, font: .caption.weight(.semibold)))
                .disabled(missing == 0)
                .help("Download the video of every episode that isn't on this Mac (asks first; files you have are never downloaded again)")
                Button { model.addingVideosTo = playlist } label: { Label("Add Videos", systemImage: "plus") }
                    .buttonStyle(SecondaryButtonStyle(height: 30, font: .caption.weight(.semibold)))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Add library videos to a playlist by hand, or every library video whose file is in a folder you pick.
struct AddVideosSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let playlist: PlaylistSummary
    @State private var picked: Set<Int64> = []
    @State private var query = ""
    @State private var folderNote: String?

    var body: some View {
        let store = model.store
        let inside = Set(store.members[playlist.id] ?? [])
        let candidates = store.all.filter { !inside.contains($0.id) }
        let shown = query.isEmpty ? candidates : candidates.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query) || $0.displayChannel.localizedCaseInsensitiveContains(query)
        }
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to “\(playlist.name)”").font(.title2.weight(.semibold)).lineLimit(2)
            Text("Pick videos from your library. Nothing is downloaded, moved or renamed.").foregroundStyle(.secondary)
            HStack {
                SearchField(text: $query, prompt: "Search your library…")
                Button("From Folder…") { pickFolder(candidates) }
                    .help("Tick the library videos whose files are in a folder you choose")
            }
            if let folderNote { Text(folderNote).font(.caption).foregroundStyle(.secondary) }
            List(shown) { v in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { picked.contains(v.id) },
                                             set: { if $0 { picked.insert(v.id) } else { picked.remove(v.id) } }))
                        .toggleStyle(.checkbox).labelsHidden()
                    Thumbnail(url: v.thumbnailURL, localPath: v.thumbnailPath, cornerRadius: 5).frame(width: 64, height: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(v.displayTitle).lineLimit(1)
                        Text(v.displayChannel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .frame(minHeight: 260)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.addingVideosTo = nil }.keyboardShortcut(.cancelAction)
                Button("Add \(picked.count)") { model.addVideos(candidates.filter { picked.contains($0.id) }.map(\.id), to: playlist.id) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
        .background(p.bg)
    }

    private func pickFolder(_ candidates: [Video]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ids = AddVideosSheet.videos(in: url.path, files: model.store.files, among: Set(candidates.map(\.id)))
        picked.formUnion(ids)
        folderNote = ids.isEmpty ? "No library video has a file in that folder." : "Ticked \(ids.count) videos with files in \(url.lastPathComponent)."
    }

    /// Library videos with an audio or video file directly in `folder` (a path match, never a title guess).
    static func videos(in folder: String, files: [FileItem], among ids: Set<Int64>) -> Set<Int64> {
        Set(files.filter { $0.isMedia && ($0.path as NSString).deletingLastPathComponent == folder && ids.contains($0.videoID) }.map(\.videoID))
    }
}

/// Preview of a YouTube playlist before anything is queued: what's already in the library, which videos to queue,
/// and which playlist to save into. In Check mode (from a playlist's Check Against YouTube) nothing is ticked, so the
/// main button only links library videos by their YouTube id.
struct PlaylistImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let state: PlaylistImportState
    @State private var selected: Set<String> = []
    @State private var action = JobAction.summarize
    @AppStorage("transcribeDownloads") private var transcribe = false
    @State private var save = true
    @State private var target: Int64 = 0       // 0 = a new playlist
    @State private var name = ""

    var body: some View {
        let store = model.store
        let preview = state.preview
        let chosen = preview.entries.filter { selected.contains($0.id) }
        let unavailable = preview.entries.count - preview.available.count
        let byKey = Dictionary(store.all.map { ($0.key, $0.id) }, uniquingKeysWith: { a, _ in a })
        let libraryID = { (e: PlaylistEntry) in byKey["youtube:\(e.id)"] }
        let inLibrary = preview.entries.compactMap(libraryID)
        let onMac = inLibrary.filter(store.videoOnMacIDs.contains).count
        let members = Set(target == 0 ? [] : store.members[target] ?? [])
        // videos that would join the playlist: library ones not in it yet, plus ticked ones new to the library
        let toLink = save ? Set(inLibrary).subtracting(members).count + chosen.filter { libraryID($0) == nil }.count : 0
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.checking != nil ? "Check Against YouTube" : preview.title).font(.title2.weight(.semibold)).lineLimit(2)
                if state.checking != nil { Text(preview.title).foregroundStyle(.secondary).lineLimit(1) }
                Text((["\(preview.entries.count) videos on YouTube", "\(inLibrary.count) in your library", "\(onMac) on this Mac"]
                      + (unavailable > 0 ? ["\(unavailable) private or deleted"] : [])).joined(separator: " • "))
                    .foregroundStyle(.secondary)
                if state.checking != nil {
                    Text("Nothing is downloaded. Videos already in your library join the playlist by their YouTube ID, and the order you have stays. Tick episodes only if you want to download them.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Picker("For ticked videos", selection: $action) {
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
                Button("Select Not in Library") { selected = Set(preview.available.filter { libraryID($0) == nil }.map(\.id)) }
                Button("Select None") { selected = [] }
                Spacer()
                Text("\(chosen.count) ticked" + (totalTime(chosen.compactMap(\.duration).reduce(0, +)).map { " • \($0)" } ?? ""))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.link)
            List(preview.entries) { entry in
                let id = libraryID(entry)
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { selected.contains(entry.id) },
                                             set: { if $0 { selected.insert(entry.id) } else { selected.remove(entry.id) } }))
                        .toggleStyle(.checkbox).labelsHidden()
                        .disabled(!entry.available)
                    Text("\(entry.index + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 22, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title).lineLimit(1)
                        if let c = entry.channel { Text(c).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if let id {
                        let video = store.videoOnMacIDs.contains(id), audio = store.onMacIDs.contains(id)
                        Text(video ? "On this Mac" : audio ? "Audio on this Mac" : "In library")
                            .font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                            .foregroundStyle(video ? p.green : p.secondary)
                            .background(Capsule().fill((video ? p.green : p.secondary).opacity(0.15)))
                    }
                    Text(Fmt.duration(entry.duration) ?? "").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                .opacity(entry.available ? 1 : 0.4)
            }
            .frame(minHeight: 200)
            Toggle("Save as one of My Playlists", isOn: $save)
            if save {
                HStack {
                    Picker("Save to", selection: $target) {
                        Text("New playlist").tag(Int64(0))
                        ForEach(store.playlists) { Text($0.name).tag($0.id) }
                    }
                    .fixedSize()
                    if target == 0 { TextField("Playlist name", text: $name).textFieldStyle(.roundedBorder) }
                }
            }
            HStack {
                if action == .video, !chosen.isEmpty, let free = model.freeDiskSpace {
                    Label("\(Fmt.bytes(Int(free))) free on this Mac", systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { model.playlistImport = nil }.keyboardShortcut(.cancelAction)
                Button(chosen.isEmpty ? "Link \(toLink) Library \(toLink == 1 ? "Video" : "Videos")" : "Add \(chosen.count) to Queue") {
                    model.importPlaylist(chosen, all: preview.entries, action: .download(action.kind, transcript: transcribe),
                                         into: save ? (target == 0 ? .new(name.nilIfBlank ?? preview.title) : .existing(target)) : nil,
                                         sourceURL: preview.url)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty && toLink == 0)
            }
        }
        .padding(20)
        .frame(width: 640, height: 680)
        .background(p.bg)
        .onAppear {
            // Check mode ticks nothing; a pasted link ticks only what isn't in the library at all
            selected = state.checking != nil ? [] : Set(preview.available.filter { libraryID($0) == nil }.map(\.id))
            action = state.action.kind == .audio || state.action.kind == .video ? .from(kind: state.action.kind) : .summarize
            name = preview.title
            target = state.checking ?? model.playlist(forSource: preview.url)?.id ?? 0
        }
    }
}
