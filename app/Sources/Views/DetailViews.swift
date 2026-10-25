// The selected video: the video column (player, details, About) and the AI panel (Summary, Transcript, Downloads).
// Everything here is read from the library: opening an entry never downloads, transcribes or calls Claude.
import SwiftUI

/// The middle column: player, title, channel, actions and About this video.
struct VideoColumn: View {
    let video: Video
    var body: some View {
        ScrollView { VideoDetail(video: video).padding(16) }
            .scrollIndicators(.never)
            .panelStyle()
    }
}

struct VideoDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let video: Video

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailMedia(video: video)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(video.displayTitle).font(.title2.weight(.bold)).lineLimit(3).textSelection(.enabled)
                Spacer(minLength: 4)
                IconButton(icon: video.favorite ? "star.fill" : "star", label: video.favorite ? "Remove from favorites" : "Add to favorites",
                           tint: video.favorite ? p.gold : p.secondary) { model.toggleFavorite(video) }
                    .font(.title3)
            }
            // its playlist, like an album name under a song: opens the playlist with this episode selected
            ForEach(model.store.playlistsOf(video.id)) { pl in
                Button { model.openPlaylist(pl.id, selecting: video.id) } label: {
                    Label([pl.name, model.store.episode(video.id, in: pl.id).map { "Episode \($0) of \(model.store.members[pl.id]?.count ?? pl.count)" }]
                            .compactMap { $0 }.joined(separator: " • "), systemImage: "music.note.list")
                        .font(.callout.weight(.medium)).foregroundStyle(p.accent).lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Open this playlist")
            }
            HStack(spacing: 10) {
                Avatar(name: video.channel)
                VStack(alignment: .leading, spacing: 1) {
                    Text(video.displayChannel).font(.headline)
                    if let f = Fmt.followers(video.channelFollowers) { Text(f).font(.callout).foregroundStyle(p.secondary) }
                }
            }
            FlowLayout(spacing: 16) {
                if let d = Fmt.duration(video.duration) { MetaRow(icon: "clock", text: d) }
                if let u = Fmt.uploadDate(video.uploadDate) { MetaRow(icon: "calendar", text: u) }
                if let platform = video.platform {
                    HStack(spacing: 7) {
                        Image(systemName: "play.rectangle.fill").foregroundStyle(p.accent)
                        Text(platform).foregroundStyle(p.text.opacity(0.9))
                    }
                    .font(.callout)
                }
            }
            DetailActions(video: video)
            Divider().overlay(p.border)
            AboutVideo(video: video)
        }
    }
}

/// Play | Show in Finder | Copy Link | Favorite | ⋯
struct DetailActions: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let video: Video

    var body: some View {
        let media = model.existingMedia(video)
        let playable = model.store.playable(for: video.id)
        let playingHere = model.playback.currentVideoID == video.id && model.playback.player != nil
        HStack(spacing: 8) {
            Button {
                if playingHere { model.playback.togglePlayPause() } else { model.play(video) }
            } label: {
                Label(playingHere && model.playback.isPlaying ? "Pause" : "Play", systemImage: playingHere && model.playback.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(PrimaryButtonStyle(height: 54, font: .headline))
            .fixedSize()
            .disabled(playable == nil)
            .help(playable == nil ? "Not on this Mac yet: use Video above or ⋯ → Make Available Offline" : "Play on this Mac (works offline)")
            tile("Show in Finder", "folder", short: "Finder", disabled: media == nil) { if let m = media { FileOps.reveal(m.path) } }
                .help(media?.path ?? "No downloaded file is on this Mac")
                .accessibilityLabel("Show in Finder")
            tile("Copy Link", "link", disabled: video.url == nil) { model.copyLink(video) }
            tile("Favorite", video.favorite ? "heart.fill" : "heart", tint: video.favorite ? p.accent : nil) { model.toggleFavorite(video) }
                .accessibilityLabel(video.favorite ? "Remove from favorites" : "Add to favorites")
            Menu { VideoActions(video: video) } label: {
                Image(systemName: "ellipsis").font(.title3.weight(.semibold))
                    .frame(width: 48, height: 54)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.elevated))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.border))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
            .accessibilityLabel("More actions")
        }
    }

    /// 4.0 G2: `short` is shown when the title doesn't fit (it was cut to "Show in Fi…").
    private func tile(_ title: String, _ icon: String, short: String? = nil, tint: Color? = nil, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.body.weight(.medium)).foregroundStyle(tint ?? p.text)
                ViewThatFits(in: .horizontal) {
                    Text(title).lineLimit(1)
                    Text(short ?? title).lineLimit(1).minimumScaleFactor(0.8)
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SecondaryButtonStyle(height: 54, font: .caption, hPadding: 4))
        .disabled(disabled)
    }
}

/// The platform's description and tags (read with yt-dlp, never made up), plus what the library knows.
struct AboutVideo: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let video: Video
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About this video").font(.headline).accessibilityAddTraits(.isHeader)
            if let d = video.description?.nilIfBlank {
                Text(d).font(.callout).foregroundStyle(p.text.opacity(0.85)).lineSpacing(3)
                    .lineLimit(expanded ? nil : 3)
                    .textSelection(.enabled)
                    .environment(\.layoutDirection, Markdown.isRTL(d) ? .rightToLeft : .leftToRight)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if video.url != nil {
                HStack(spacing: 10) {
                    Button { model.loadDetails(video) } label: {
                        Label(model.loadingDetails.contains(video.id) ? "Loading…" : "Load details", systemImage: "text.below.photo")
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 32, font: .callout))
                    .disabled(model.loadingDetails.contains(video.id))
                    Text("Reads the description from \(video.platform ?? "the site"). Nothing is downloaded.")
                        .font(.caption).foregroundStyle(p.secondary)
                }
            } else {
                Text("No description: this entry was imported from files.").font(.callout).foregroundStyle(p.secondary)
            }
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text(expanded ? "Show less" : "Show more")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption.weight(.bold))
                }
                .font(.callout.weight(.medium)).foregroundStyle(p.accent)
            }
            .buttonStyle(.plain)
            if !video.tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(video.tags.prefix(expanded ? 30 : 8), id: \.self) { tag in
                        Text(tag).font(.caption.weight(.medium)).lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(p.elevated))
                            .overlay(Capsule().strokeBorder(p.border.opacity(0.8)))
                    }
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    MetaRow(icon: "calendar.badge.clock", text: "Processed \(Fmt.date(video.lastProcessed))")
                    MetaRow(icon: "translate", text: "Transcript language: \(Fmt.language(video.language) ?? "unknown")")
                    if let url = video.url {
                        Button { FileOps.openLink(url) } label: { MetaRow(icon: "link", text: "Open the original video") }
                            .buttonStyle(.plain).help(url)
                    } else {
                        MetaRow(icon: "link", text: "Original link unknown (imported)")
                    }
                    if model.store.hasLocalVideo(video.id) {
                        Label("On this Mac: watch it offline", systemImage: "laptopcomputer").font(.callout).foregroundStyle(p.green)
                    } else if video.url != nil {
                        Button { model.makeAvailableOffline(video) } label: { Label("Make Available Offline", systemImage: "arrow.down.circle") }
                            .buttonStyle(SecondaryButtonStyle(height: 32, font: .callout))
                            .help("Download the video file so you can watch it without internet")
                    }
                }
                .padding(.top, 4)
            }
        }
        .onChange(of: video.id) { expanded = false }
    }
}

/// Summary | Transcript | Downloads (and Video when the window is narrow).
struct AIPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let video: Video
    let tabs: [DetailTab]

    var body: some View {
        let current = tabs.contains(model.detailTab) ? model.detailTab : .summary
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                ForEach(tabs) { tab in
                    let selected = current == tab
                    Button { model.detailTab = tab } label: {
                        Text(tab.rawValue)
                            .font(.title3.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? p.accent : p.text.opacity(0.8))
                            .padding(.vertical, 12)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(selected ? p.accent : .clear).frame(height: 2).offset(y: 1)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
            Group {
                switch current {
                case .video: ScrollView { VideoDetail(video: video).padding(16) }
                case .summary: SummaryTab(video: video)
                case .transcript: TranscriptTab()
                case .downloads: DownloadsTab(video: video)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .panelStyle()
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct SummaryTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let video: Video
    @State private var versionID: Int64?

    var body: some View {
        let versions = model.store.summaryJobs
        let current = versions.first { $0.id == versionID } ?? versions.first
        let canRegenerate = model.store.transcriptJob != nil
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if versions.count > 1 {
                    Menu {
                        ForEach(Array(versions.enumerated()), id: \.element.id) { i, job in
                            Button(versionLabel(job, number: versions.count - i)) { versionID = job.id }
                        }
                    } label: {
                        Label("Version \(versions.count - (versions.firstIndex { $0.id == current?.id } ?? 0)) of \(versions.count)",
                              systemImage: "square.stack")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                if let c = current {
                    Text("\(c.summaryFormat ?? "Standard") • \(c.summaryLanguage ?? "English")")
                        .font(.caption).foregroundStyle(p.secondary).lineLimit(1)
                }
                Spacer()
                if let s = current?.summary {
                    IconButton(icon: "doc.on.doc", label: "Copy summary as Markdown") { FileOps.copy(s); model.notice = "Summary copied as Markdown" }
                    IconButton(icon: "square.and.arrow.up", label: "Export summary as .md") {
                        if FileOps.export(s, suggestedName: video.displayTitle + " summary", ext: "md") { model.notice = "Summary exported" }
                    }
                }
                Menu {
                    Button("Regenerate with Current Settings") { model.regenerate() }
                    Section("Format") {
                        ForEach(SummaryFormat.allCases) { f in Button(f.rawValue) { model.regenerate(format: f) } }
                    }
                    Section("Language") {
                        ForEach(SummaryLanguage.allCases) { l in Button(l.rawValue) { model.regenerate(language: l) } }
                    }
                } label: {
                    Label("Regenerate", systemImage: "arrow.triangle.2.circlepath")
                } primaryAction: {
                    model.regenerate()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!canRegenerate)
                .help(model.store.transcriptJob == nil ? "Needs a saved transcript" : "Make a new summary from the saved transcript (keeps the old ones; waits for internet if you're offline)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if let s = current?.summary {
                ScrollView {
                    SummaryCards(text: s)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 14)
                }
            } else {
                NoSummaryYet(video: video)
            }
        }
        .onChange(of: video.id) { versionID = nil }
        .onChange(of: versions.count) { versionID = nil }
    }

    private func versionLabel(_ job: Job, number: Int) -> String {
        "Version \(number): \(job.summaryFormat ?? "Standard") • \(job.summaryLanguage ?? "English") • \(Fmt.date(job.finished ?? job.started))"
    }
}

struct TranscriptTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @State private var query = ""
    @AppStorage("followTranscript") private var follow = true

    var body: some View {
        if let job = model.store.transcriptJob, let text = job.transcript, let video = model.store.selectedVideo {
            let segments = job.segments
            let rows: [(start: Double?, text: String)] = segments.isEmpty
                ? text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { (nil, $0) }
                : segments.map { ($0.start, $0.text) }
            let shown = Array(rows.enumerated()).filter { query.isEmpty || $0.element.text.localizedCaseInsensitiveContains(query) }
            let canSeek = model.store.playable(for: video.id) != nil && !segments.isEmpty
            let current = model.playback.currentVideoID == video.id ? segments.index(at: model.playback.currentTime) : nil
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SearchField(text: $query, prompt: "Search transcript")
                    if !query.isEmpty { Text("\(shown.count) of \(rows.count)").font(.caption).foregroundStyle(p.secondary).fixedSize() }
                    IconButton(icon: "doc.on.doc", label: "Copy transcript") { FileOps.copy(text); model.notice = "Transcript copied" }
                    IconButton(icon: "square.and.arrow.up", label: "Export transcript as .txt") {
                        if FileOps.export(text, suggestedName: video.displayTitle + " transcript", ext: "txt") {
                            model.notice = "Transcript exported"
                        }
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "translate").foregroundStyle(p.secondary)
                    Text("\(Fmt.language(job.transcriptLanguage) ?? "Language unknown")")
                    Text(segments.isEmpty ? "• no timestamps" : "• \(segments.count) lines")
                    Spacer()
                    if canSeek {
                        Toggle("Follow playback", isOn: $follow).toggleStyle(.checkbox)
                            .help("Keep the line being spoken in view while the video plays")
                    }
                }
                .font(.caption).foregroundStyle(p.secondary)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(shown, id: \.offset) { item in
                                let row = item.element
                                let isCurrent = item.offset == current
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    if let start = row.start {
                                        Text(Fmt.timestamp(start)).font(.callout.monospacedDigit().weight(.medium))
                                            .foregroundStyle(p.accent).frame(minWidth: 52, alignment: .leading)
                                    }
                                    Text(highlight(row.text)).fontWeight(isCurrent ? .semibold : .regular)
                                        .foregroundStyle(isCurrent ? p.text : p.text.opacity(0.85))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.vertical, 5).padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8).fill(isCurrent ? p.accentDark.opacity(0.28) : .clear))
                                .overlay(alignment: .leading) {
                                    if isCurrent { Capsule().fill(p.accent).frame(width: 3).padding(.vertical, 4) }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { if canSeek, let start = row.start { model.seek(video, to: start) } }
                                .help(canSeek ? "Play from here" : "")
                                .id(item.offset)
                            }
                        }
                        .textSelection(.enabled)
                    }
                    .onChange(of: current) {
                        guard follow, query.isEmpty, let current else { return }
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(current, anchor: .center) }
                    }
                }
            }
            .padding(14)
            .environment(\.layoutDirection, Markdown.isRTL(text) ? .rightToLeft : .leftToRight)
        } else if let video = model.store.selectedVideo, model.store.mediaFiles(for: video.id).contains(where: \.exists) {
            VStack(spacing: 14) {
                EmptyState(icon: "text.bubble", title: "No transcript yet",
                           message: "This entry has a file on your Mac. Transcribe it here: it runs on-device and works without internet.")
                    .frame(maxHeight: 220)
                Button { model.transcribe(video) } label: { Label("Transcribe on this Mac", systemImage: "waveform.badge.mic") }
                    .buttonStyle(PrimaryButtonStyle(height: 40, font: .headline))
                Spacer()
            }
        } else {
            EmptyState(icon: "text.bubble", title: "No transcript",
                       message: "Summarize the video, or save its audio or video with + Transcript ticked.")
        }
    }

    private func highlight(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        guard !query.isEmpty else { return a }
        var searchRange = a.startIndex..<a.endIndex
        while let r = a[searchRange].range(of: query, options: .caseInsensitive) {
            a[r].backgroundColor = p.accent.opacity(0.35)
            a[r].inlinePresentationIntent = .stronglyEmphasized
            searchRange = r.upperBound..<a.endIndex
        }
        return a
    }
}

/// What to do when there's no summary yet: summarize the saved transcript, transcribe a local file, or process the link.
struct NoSummaryYet: View {
    @Environment(AppModel.self) private var model
    let video: Video

    var body: some View {
        let hasTranscript = model.store.transcriptJob != nil
        let hasLocal = model.store.mediaFiles(for: video.id).contains(where: \.exists)
        VStack(spacing: 14) {
            EmptyState(icon: "sparkles", title: "No summary yet",
                       message: hasTranscript
                           ? "There's a saved transcript. Summarize it now, or while offline: it runs when you're back online."
                           : hasLocal ? "Transcribe the file on this Mac first (works offline), then summarize it."
                           : video.url != nil ? "Summarize the link to download, transcribe and summarize it."
                           : "This entry only has files; there's nothing to summarize from.")
                .frame(maxHeight: 220)
            if hasTranscript {
                Button { model.regenerate() } label: { Label("Summarize Transcript", systemImage: "sparkles") }
                    .buttonStyle(PrimaryButtonStyle(height: 40, font: .headline))
            } else if hasLocal {
                Button { model.transcribe(video) } label: { Label("Transcribe on this Mac", systemImage: "waveform.badge.mic") }
                    .buttonStyle(PrimaryButtonStyle(height: 40, font: .headline))
            } else if video.url != nil {
                Button { model.processAgain(video) } label: { Label("Summarize", systemImage: "sparkles") }
                    .buttonStyle(PrimaryButtonStyle(height: 40, font: .headline))
            }
            Spacer()
        }
    }
}

struct DownloadsTab: View {
    @Environment(AppModel.self) private var model
    let video: Video

    var body: some View {
        let files = model.store.files(for: video.id)
        if files.isEmpty {
            EmptyState(icon: "arrow.down.circle", title: "No files recorded",
                       message: "Use Video or Audio above to save this video's files.")
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(files) { item in
                        FileRow(item: item, onDownloadAgain: item.isMedia && video.url != nil
                                ? { model.downloadAgain(video, kind: item.role == .video ? .video : .audio) } : nil)
                    }
                }
                .padding(14)
            }
        }
    }
}
