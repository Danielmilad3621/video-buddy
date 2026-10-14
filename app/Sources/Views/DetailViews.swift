// Right side of the window: the job banner, the selected video's card, and its Summary/Transcript/Downloads tabs.
// Everything here is read from history: opening an entry never downloads, transcribes or calls Claude.
import SwiftUI

struct RightColumn: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let stacked: Bool

    var body: some View {
        VStack(spacing: 16) {
            JobBanner()
            if let v = model.store.selectedVideo {
                if stacked {
                    VStack(spacing: 16) {
                        DetailCard(video: v, horizontal: true)
                        DetailTabs(video: v)
                    }
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        ScrollView { DetailCard(video: v, horizontal: false) }
                            .frame(width: 330)
                            .scrollIndicators(.never)
                        DetailTabs(video: v)
                    }
                }
            } else {
                EmptyState(icon: "rectangle.stack", title: "Select a video",
                           message: "Pick something from your history to see its summary, transcript and files.")
                    .cardStyle()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct JobBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @State private var showDetail = false

    var body: some View {
        if let banner = model.jobs.banner {
            let tint = tint(banner)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 14) {
                    icon(banner, tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(banner)).font(.headline).foregroundStyle(tint).lineLimit(2)
                        if let sub = subtitle(banner) { Text(sub).font(.callout).foregroundStyle(p.secondary).lineLimit(2) }
                    }
                    Spacer(minLength: 8)
                    actions(banner)
                }
                if case .running = banner { StepList(steps: model.jobs.steps) }
                if showDetail, case let .failure(_, detail, _) = banner {
                    ScrollView {
                        Text(detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(p.bg.opacity(0.6)))
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tint.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint.opacity(0.55)))
            .accessibilityElement(children: .contain)
            .onChange(of: banner) { showDetail = false }
        }
    }

    private func tint(_ b: Banner) -> Color {
        switch b {
        case .running: p.blue
        case .success: p.green
        case .failure: p.red
        case .cancelled: p.secondary
        }
    }

    @ViewBuilder private func icon(_ b: Banner, _ tint: Color) -> some View {
        switch b {
        case .running: ProgressView().controlSize(.regular).frame(width: 40, height: 40)
        case .success: Image(systemName: "checkmark.circle.fill").font(.system(size: 36)).foregroundStyle(tint)
        case .failure: Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 34)).foregroundStyle(tint)
        case .cancelled: Image(systemName: "xmark.circle.fill").font(.system(size: 34)).foregroundStyle(tint)
        }
    }

    private func title(_ b: Banner) -> String {
        switch b {
        case let .running(t): t
        case let .success(t, _, _): t
        case let .failure(t, _, _): t
        case .cancelled: "Cancelled. Nothing half-finished was kept."
        }
    }

    private func subtitle(_ b: Banner) -> String? {
        switch b {
        case .running: nil
        case let .success(_, s, _): s
        case let .failure(_, d, _): d.split(separator: "\n").last.map(String.init)
        case .cancelled: "Partial downloads and temporary files were removed."
        }
    }

    @ViewBuilder private func actions(_ b: Banner) -> some View {
        switch b {
        case .running:
            Button { model.jobs.cancel() } label: { Label("Cancel", systemImage: "stop.circle") }
                .buttonStyle(SecondaryButtonStyle(height: 36, font: .callout))
                .help("Stop this job and everything it started (⌘.)")
        case let .success(_, _, file):
            if let file, FileOps.exists(file) {
                Button { FileOps.reveal(file) } label: { Label("Show in Finder", systemImage: "folder") }
                    .buttonStyle(SecondaryButtonStyle(height: 36, font: .callout))
            }
            IconButton(icon: "xmark", label: "Dismiss") { model.jobs.dismissBanner() }
        case let .failure(_, _, retry):
            Button(showDetail ? "Hide Details" : "Details") { showDetail.toggle() }.buttonStyle(.link)
            if let retry {
                Button { model.retry(retry) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .buttonStyle(SecondaryButtonStyle(height: 36, font: .callout))
            }
            IconButton(icon: "xmark", label: "Dismiss") { model.jobs.dismissBanner() }
        case let .cancelled(retry):
            if let retry {
                Button { model.retry(retry) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .buttonStyle(SecondaryButtonStyle(height: 36, font: .callout))
            }
            IconButton(icon: "xmark", label: "Dismiss") { model.jobs.dismissBanner() }
        }
    }
}

struct StepList: View {
    @Environment(\.palette) private var p
    let steps: [JobStep]
    var body: some View {
        FlowLayout(spacing: 14) {
            ForEach(steps) { s in
                HStack(spacing: 6) {
                    switch s.state {
                    case .pending: Image(systemName: "circle").foregroundStyle(p.secondary)
                    case .running: ProgressView().controlSize(.mini)
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(p.green)
                    case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(p.red)
                    }
                    Text(s.label).font(.callout).foregroundStyle(s.state == .pending ? p.secondary : p.text)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(s.label): \(String(describing: s.state))")
            }
        }
    }
}

struct DetailCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let video: Video
    let horizontal: Bool

    var body: some View {
        let layout = horizontal ? AnyLayout(HStackLayout(alignment: .top, spacing: 18)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
        layout {
            Thumbnail(url: video.thumbnailURL, duration: video.duration, cornerRadius: 12, badgeFont: .callout.weight(.semibold))
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: horizontal ? 280 : .infinity)
            VStack(alignment: .leading, spacing: 14) {
                Text(video.displayTitle).font(.title2.weight(.bold)).lineLimit(3).textSelection(.enabled)
                HStack(spacing: 10) {
                    Avatar(name: video.channel)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(video.displayChannel).font(.headline)
                        if let f = Fmt.followers(video.channelFollowers) { Text(f).font(.callout).foregroundStyle(p.secondary) }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    MetaRow(icon: "clock", text: [Fmt.duration(video.duration) ?? "Duration unknown",
                                                  Fmt.uploadDate(video.uploadDate).map { "Uploaded \($0)" }].compactMap { $0 }.joined(separator: "  •  "))
                    MetaRow(icon: "calendar", text: "Processed \(Fmt.date(video.lastProcessed))")
                    MetaRow(icon: "globe", text: video.platform ?? "Platform unknown")
                    MetaRow(icon: "translate", text: Fmt.language(video.language) ?? "Language unknown")
                    if let url = video.url {
                        Button { FileOps.openLink(url) } label: { MetaRow(icon: "link", text: "Original video") }
                            .buttonStyle(.plain)
                            .help(url)
                    } else {
                        MetaRow(icon: "link", text: "Original link unknown (imported)")
                    }
                }
                actions
            }
        }
        .cardStyle()
    }

    private var actions: some View {
        let summaryJob = model.store.summaryJobs.first
        let media = model.existingMedia(video)
        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Button {
                    if let path = summaryJob?.summaryPath, FileOps.exists(path) { FileOps.open(path) } else { model.detailTab = .summary }
                } label: { Label("Reopen Summary", systemImage: "doc.text").frame(maxWidth: .infinity) }
                    .disabled(summaryJob == nil)
                    .help("Open the saved summary file")
                Button {
                    if let s = summaryJob?.summary { FileOps.copy(s); model.notice = "Summary copied as Markdown" }
                } label: { Label("Copy Summary", systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
                    .disabled(summaryJob == nil)
            }
            GridRow {
                Button { if let m = media { FileOps.open(m.path) } } label: { Label("Open File", systemImage: "folder").frame(maxWidth: .infinity) }
                    .disabled(media == nil)
                    .help(media == nil ? "No downloaded file is available on disk" : media!.path)
                Button { model.toggleFavorite(video) } label: {
                    Label(video.favorite ? "Favorited" : "Add to Favorites", systemImage: video.favorite ? "star.fill" : "star")
                        .frame(maxWidth: .infinity)
                }
                .foregroundStyle(video.favorite ? p.gold : p.text)
            }
        }
        .buttonStyle(SecondaryButtonStyle(height: 38, font: .footnote.weight(.medium)))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }
}

struct DetailTabs: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let video: Video

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(DetailTab.allCases) { tab in
                    let selected = model.detailTab == tab
                    Button { model.detailTab = tab } label: {
                        Label(tab.rawValue, systemImage: tab.icon)
                            .font(.title3.weight(selected ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .foregroundStyle(selected ? .white : p.text.opacity(0.85))
                            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(selected ? p.blue : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(6)
            Divider().overlay(p.border)
            Group {
                switch model.detailTab {
                case .summary: SummaryTab(video: video)
                case .transcript: TranscriptTab()
                case .downloads: DownloadsTab(video: video)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(p.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.border.opacity(0.8)))
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
        let canRegenerate = model.store.transcriptJob != nil && !model.jobs.isRunning
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
                        .font(.caption).foregroundStyle(p.secondary)
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
                .help(model.store.transcriptJob == nil ? "Needs a saved transcript" : "Make a new summary from the saved transcript (keeps the old ones)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if let s = current?.summary {
                ScrollView {
                    MarkdownView(text: s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 18)
                }
            } else {
                EmptyState(icon: "sparkles", title: "No summary yet",
                           message: model.store.transcriptJob != nil
                               ? "There's a saved transcript. Use Regenerate to summarize it."
                               : (video.url != nil ? "Use Process Again from the ⋮ menu to download, transcribe and summarize it."
                                                   : "This entry only has files; there's nothing to summarize from."))
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

    var body: some View {
        if let job = model.store.transcriptJob, let text = job.transcript {
            let segments = job.segments
            let rows: [(String?, String)] = segments.isEmpty
                ? text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { (nil, $0) }
                : segments.map { (Fmt.timestamp($0.start), $0.text) }
            let shown = query.isEmpty ? rows : rows.filter { $0.1.localizedCaseInsensitiveContains(query) }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SearchField(text: $query, prompt: "Search transcript")
                    if !query.isEmpty { Text("\(shown.count) of \(rows.count)").font(.caption).foregroundStyle(p.secondary).fixedSize() }
                    IconButton(icon: "doc.on.doc", label: "Copy transcript") { FileOps.copy(text); model.notice = "Transcript copied" }
                    IconButton(icon: "square.and.arrow.up", label: "Export transcript as .txt") {
                        if FileOps.export(text, suggestedName: (model.store.selectedVideo?.displayTitle ?? "Video") + " transcript", ext: "txt") {
                            model.notice = "Transcript exported"
                        }
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "translate").foregroundStyle(p.secondary)
                    Text("Original language: \(Fmt.language(job.transcriptLanguage) ?? "unknown")")
                    Text(segments.isEmpty ? "• no timestamps were saved for this transcript" : "• \(segments.count) timestamped segments")
                }
                .font(.caption).foregroundStyle(p.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                if let ts = row.0 {
                                    Text(ts).font(.callout.monospacedDigit()).foregroundStyle(p.blue).frame(minWidth: 52, alignment: .leading)
                                }
                                Text(highlight(row.1)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .environment(\.layoutDirection, Markdown.isRTL(text) ? .rightToLeft : .leftToRight)
        } else {
            EmptyState(icon: "text.bubble", title: "No transcript",
                       message: "Transcripts are saved when a video is summarized. Audio or video downloads don't make one.")
        }
    }

    private func highlight(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        guard !query.isEmpty else { return a }
        var searchRange = a.startIndex..<a.endIndex
        while let r = a[searchRange].range(of: query, options: .caseInsensitive) {
            a[r].backgroundColor = p.blue.opacity(0.35)
            a[r].inlinePresentationIntent = .stronglyEmphasized
            searchRange = r.upperBound..<a.endIndex
        }
        return a
    }
}

struct DownloadsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let video: Video

    var body: some View {
        let files = model.store.files(for: video.id)
        if files.isEmpty {
            EmptyState(icon: "arrow.down.circle", title: "No files recorded",
                       message: "Use Audio or Video above to save this video's files.")
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(files) { item in
                        FileRow(item: item, onDownloadAgain: item.isMedia && video.url != nil
                                ? { model.downloadAgain(video, kind: item.role == .video ? .video : .audio) } : nil)
                    }
                }
                .padding(16)
            }
        }
    }
}
