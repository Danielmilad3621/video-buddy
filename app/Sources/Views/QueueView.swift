// The processing strip under the toolbar and the Queue section: what runs now, what waits, what failed.
// Only real stages are shown (the scripts report no percentages, so none are made up).
import SwiftUI

/// Under the toolbar while there's work: the running job's stages, its result, or a waiting queue.
struct ProcessingStatus: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let jobs = model.jobs
        VStack(spacing: 8) {
            if let banner = jobs.banner { BannerStrip(banner: banner) }
            if jobs.current == nil, !jobs.queue.isEmpty { WaitingStrip() }
        }
    }
}

struct BannerStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let banner: Banner
    @State private var showDetail = false
    @State private var thumb: Video?

    var body: some View {
        let jobs = model.jobs
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                leading
                VStack(alignment: .leading, spacing: 7) {
                    if case let .running(text) = banner {
                        HStack(spacing: 6) {
                            if let current = jobs.current, text != "Cancelling…" {
                                Text("Processing:").font(.headline)
                                Text(current.title).font(.headline.weight(.regular)).lineLimit(1)
                            } else {
                                Text(text).font(.headline).lineLimit(1)
                            }
                        }
                        StageTrack(steps: jobs.steps)
                    } else {
                        Text(title).font(.headline).lineLimit(2)
                        if let sub = subtitle { Text(sub).font(.callout).foregroundStyle(p.secondary).lineLimit(2) }
                    }
                }
                Spacer(minLength: 8)
                actions
            }
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
        .padding(12)
        .panelStyle()
        .accessibilityElement(children: .contain)
        .onChange(of: banner) { showDetail = false }
        .task(id: jobs.current?.videoID) {
            guard let id = jobs.current?.videoID else { return }
            thumb = (try? await model.store.db.video(id)) ?? nil
        }
    }

    @ViewBuilder private var leading: some View {
        switch banner {
        case .running:
            Thumbnail(url: thumb?.thumbnailURL, localPath: thumb?.thumbnailPath, cornerRadius: 8)
                .frame(width: 78, height: 44)
                .overlay { if thumb == nil { ProgressView().controlSize(.small) } }
        case .success:
            statusIcon("checkmark.circle.fill", p.green)
        case .failure:
            statusIcon("exclamationmark.octagon.fill", p.accent)
        case .cancelled:
            statusIcon("xmark.circle.fill", p.secondary)
        }
    }

    private func statusIcon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 30)).foregroundStyle(color).frame(width: 44, height: 44)
    }

    private var title: String {
        switch banner {
        case let .running(t): t
        case let .success(t, _, _): t
        case let .failure(t, _, _): t
        case .cancelled: "Cancelled. Nothing half-finished was kept."
        }
    }

    private var subtitle: String? {
        switch banner {
        case .running: nil
        case let .success(_, s, _): s
        case let .failure(_, d, _): d.split(separator: "\n").last.map(String.init)
        case .cancelled: "Partial downloads and temporary files were removed."
        }
    }

    @ViewBuilder private var actions: some View {
        let jobs = model.jobs
        HStack(spacing: 8) {
            if !jobs.queue.isEmpty {
                Button { model.section = .queue } label: { Label("Queue (\(jobs.queue.count))", systemImage: "list.bullet") }
                    .buttonStyle(SecondaryButtonStyle(height: 34, font: .callout))
                    .help("See everything waiting")
            }
            switch banner {
            case .running:
                Button("Cancel") { jobs.cancel() }
                    .buttonStyle(OutlineButtonStyle())
                    .help("Stop this job and everything it started, and pause the queue (⌘.)")
            case let .success(_, _, file):
                if let file, FileOps.exists(file) {
                    Button { FileOps.reveal(file) } label: { Label("Show in Finder", systemImage: "folder") }
                        .buttonStyle(SecondaryButtonStyle(height: 34, font: .callout))
                }
                IconButton(icon: "xmark", label: "Dismiss") { jobs.dismissBanner() }
            case let .failure(_, _, retry):
                Button(showDetail ? "Hide Details" : "Details") { showDetail.toggle() }.buttonStyle(.link).tint(p.accent)
                if let retry {
                    Button { model.retry(retry) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                        .buttonStyle(SecondaryButtonStyle(height: 34, font: .callout))
                }
                IconButton(icon: "xmark", label: "Dismiss") { jobs.dismissBanner() }
            case let .cancelled(retry):
                if let retry {
                    Button { model.retry(retry) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                        .buttonStyle(SecondaryButtonStyle(height: 34, font: .callout))
                }
                IconButton(icon: "xmark", label: "Dismiss") { jobs.dismissBanner() }
            }
        }
    }
}

/// The job's real stages, in order: ✓ done, a moving bar for the one running, numbers for the ones to come.
struct StageTrack: View {
    @Environment(\.palette) private var p
    let steps: [JobStep]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, s in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        marker(s, number: i + 1)
                        switch s.state {
                        case .done: Capsule().fill(p.accent).frame(height: 3)
                        case .running: IndeterminateBar()
                        case .pending, .failed: Capsule().fill(p.border).frame(height: 3)
                        }
                    }
                    Text(s.label).font(.caption).foregroundStyle(s.state == .pending ? p.secondary : p.text).lineLimit(1)
                }
                .frame(minWidth: 90, maxWidth: 210, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(i + 1), \(s.label): \(Self.spoken(s.state))")
            }
        }
    }

    static func spoken(_ s: StepState) -> String {
        switch s {
        case .pending: "to do"
        case .running: "in progress"
        case .done: "done"
        case .failed: "stopped"
        }
    }

    @ViewBuilder private func marker(_ s: JobStep, number: Int) -> some View {
        switch s.state {
        case .done:
            Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Circle().fill(p.accent))
        case .running:
            Circle().strokeBorder(p.accent, lineWidth: 2).frame(width: 18, height: 18)
                .overlay(Circle().fill(p.accent).frame(width: 7, height: 7))
        case .pending:
            Text("\(number)").font(.system(size: 10, weight: .bold)).monospacedDigit().foregroundStyle(p.secondary)
                .frame(width: 18, height: 18).overlay(Circle().strokeBorder(p.border, lineWidth: 1.5))
        case .failed:
            Image(systemName: "xmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Circle().fill(p.secondary))
        }
    }
}

/// "Working on it" without a made-up percentage. Still when Reduce Motion is on.
struct IndeterminateBar: View {
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                let w = g.size.width * 0.35
                ZStack(alignment: .leading) {
                    Capsule().fill(p.border)
                    Capsule().fill(p.accent).frame(width: w)
                        .offset(x: reduceMotion ? (g.size.width - w) / 2 : (g.size.width + w) * t - w)
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 3)
    }
}

/// Jobs are waiting but nothing runs: the queue is paused, the Mac is offline, or it's on a network the Wi-Fi-only
/// setting doesn't allow.
struct WaitingStrip: View {
    static let meteredNote = "Wi-Fi or Ethernet only is on, and this network doesn't qualify. If a connection switches to a metered network during a download, that download may finish; the next one waits."

    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p

    var body: some View {
        let jobs = model.jobs
        let n = jobs.queue.count
        let (icon, title, detail): (String, String, String) = jobs.paused
            ? ("pause.circle.fill", "Queue paused • \(n) waiting",
               !JobController.canRun ? "Downloads and AI jobs don't run in Video Buddy 4.0 Preview."
                   : jobs.pauseReason ?? "Press Resume to continue with the next job.")
            : !model.network.isOnline
            ? ("wifi.slash", "Waiting for internet • \(n) in the queue", "They start by themselves when you're back online.")
            : !jobs.downloadsAllowed
            ? ("wifi.exclamationmark", "Waiting for Wi-Fi or Ethernet • \(n) in the queue", Self.meteredNote)
            : ("hourglass", "\(n) waiting", "Starting…")
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(p.secondary).frame(width: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(p.secondary)
            }
            Spacer()
            if jobs.paused, JobController.canRun {
                Button { jobs.resumeQueue() } label: { Label("Resume", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle(height: 34, font: .callout.weight(.semibold)))
                    .testProbe("resumeQueue")
            }
            Button { model.section = .queue } label: { Label("Queue (\(n))", systemImage: "list.bullet") }
                .buttonStyle(SecondaryButtonStyle(height: 34, font: .callout))
        }
        .padding(12)
        .panelStyle()
    }
}

/// The Queue section: running now, waiting (with pause / resume / remove / clear) and failed (with retry).
struct QueueColumn: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p

    var body: some View {
        let jobs = model.jobs
        let failed = model.store.failed
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Queue", icon: "slider.horizontal.3") {
                if !JobController.canRun {
                    Label("Preview: downloads off", systemImage: "lock.fill").font(.callout).foregroundStyle(p.secondary)
                } else if jobs.paused {
                    Button { jobs.resumeQueue() } label: { Label("Resume", systemImage: "play.fill") }
                        .buttonStyle(PrimaryButtonStyle(height: 30, font: .callout.weight(.semibold)))
                } else {
                    Button { jobs.pauseQueue() } label: { Label("Pause", systemImage: "pause.fill") }
                        .buttonStyle(SecondaryButtonStyle(height: 30, font: .callout))
                        .help("Finish the current job, then wait")
                }
                Button("Clear", role: .destructive) { jobs.clearQueue() }
                    .buttonStyle(SecondaryButtonStyle(height: 30, font: .callout))
                    .disabled(jobs.queue.isEmpty)
                    .help("Remove everything waiting (nothing already saved is touched)")
            }
            if jobs.paused || !model.network.isOnline || !jobs.downloadsAllowed {
                Label(jobs.paused ? (!JobController.canRun ? "Video Buddy 4.0 Preview never runs jobs: nothing is downloaded or summarized."
                                                           : jobs.pauseReason ?? "Paused: nothing new starts until you press Resume.")
                                  : !model.network.isOnline ? "Offline: jobs that need the internet wait; transcribing on this Mac still runs."
                                  : WaitingStrip.meteredNote,
                      systemImage: jobs.paused ? "pause.circle" : "wifi.slash")
                    .font(.callout).foregroundStyle(p.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    group("Running now") {
                        if let current = jobs.current {
                            VStack(alignment: .leading, spacing: 10) {
                                row(current.videoID, title: current.title, detail: detail(current.videoID, current.action.label)) {
                                    Button("Cancel") { jobs.cancel() }.buttonStyle(OutlineButtonStyle(height: 28))
                                }
                                StageTrack(steps: jobs.steps)
                            }
                            .cardStyle(padding: 12)
                        } else {
                            Text("Nothing running.").font(.callout).foregroundStyle(p.secondary)
                        }
                    }
                    group("Waiting • \(jobs.queue.count)") {
                        if jobs.queue.isEmpty {
                            Text("Nothing waiting.").font(.callout).foregroundStyle(p.secondary)
                        }
                        // consecutive jobs from one playlist share a header; the numbers are the real FIFO order
                        let runs = Grouping.runs(jobs.queue) { model.store.playlistsOf($0.videoID).first?.id }
                        ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                            VStack(alignment: .leading, spacing: 4) {
                                if let pid = run.playlist { playlistHeader(pid) }
                                ForEach(run.items, id: \.item.id) { n, item in
                                    row(item.videoID, title: item.title, detail: detail(item.videoID, item.action.label + Self.options(item.options)),
                                        position: n) {
                                        IconButton(icon: "xmark.circle.fill", label: "Remove from the queue") { jobs.removeFromQueue(item.id) }
                                    }
                                    .padding(.leading, run.playlist == nil ? 0 : 8)
                                }
                            }
                        }
                    }
                    if !failed.isEmpty {
                        group("Failed • \(failed.count)") {
                            ForEach(failed) { f in
                                row(f.job.videoID, title: f.title,
                                    detail: detail(f.job.videoID, f.job.action.label + (f.job.status == .interrupted ? " • interrupted" : " • failed \(Fmt.date(f.job.finished ?? f.job.started))"))) {
                                    Button { model.retry(f.retry) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                                        .buttonStyle(SecondaryButtonStyle(height: 28, font: .caption.weight(.semibold)))
                                }
                                .help(f.job.error?.split(separator: "\n").last.map(String.init) ?? "")
                            }
                        }
                    }
                }
                .padding(2)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// A prepared download's " • 720p • ≈ 412 MB" (or "size unknown").
    static func options(_ o: JobOptions?) -> String {
        guard let o else { return "" }
        let q = o.quality.map { $0 == "max" ? " • best quality" : " • up to \($0)p" } ?? ""
        return q + " • " + SizeEstimate.text(o.estimatedBytes, o.sizeKind)
    }

    /// "Episode 4 • Download video" for a playlist video, else just the action.
    private func detail(_ videoID: Int64, _ text: String) -> String {
        guard let pl = model.store.playlistsOf(videoID).first, let n = model.store.episode(videoID, in: pl.id) else { return text }
        return "Episode \(n) • \(text)"
    }

    /// A playlist's name with its job counts, straight from the job states.
    private func playlistHeader(_ id: Int64) -> some View {
        let store = model.store, jobs = model.jobs
        let inIt = Set(store.members[id] ?? [])
        let running = jobs.current.map { inIt.contains($0.videoID) } == true
        let waiting = jobs.queue.filter { inIt.contains($0.videoID) }.count
        let failed = store.failed.filter { inIt.contains($0.job.videoID) }.count
        let downloading = running && [.audio, .video].contains(jobs.current!.action.kind)
        return HStack(spacing: 6) {
            Image(systemName: "music.note.list").foregroundStyle(p.accent)
            Text(store.playlists.first { $0.id == id }?.name ?? "Playlist").font(.caption.weight(.semibold)).lineLimit(1)
            Text(([running ? (downloading ? "1 downloading" : "1 running") : nil, "\(waiting) queued",
                   failed > 0 ? "\(failed) failed" : nil, "\(store.offlineCount(id)) of \(inIt.count) offline"] as [String?])
                .compactMap { $0 }.joined(separator: " • "))
                .font(.caption).foregroundStyle(p.secondary).lineLimit(1)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.semibold)).foregroundStyle(p.secondary).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func row<Trailing: View>(_ videoID: Int64, title: String, detail: String, position: Int? = nil,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            if let position { Text("\(position)").font(.callout.monospacedDigit()).foregroundStyle(p.secondary).frame(minWidth: 20) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(p.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(model.store.selectedID == videoID ? p.accentDark.opacity(0.22) : p.card))
        .contentShape(Rectangle())
        .onTapGesture { model.store.select(videoID) }
    }
}
