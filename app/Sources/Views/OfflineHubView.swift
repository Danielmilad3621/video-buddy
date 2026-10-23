// 4.0 Phase 4: the Offline Hub. Prepare for Offline: choose videos, see what each needs, its download checks (one video
// at a time; a declaration is never treated as verified) and its size against your free space and reserve, then queue
// them with one explicit action. Nothing here starts a download by itself.
import SwiftUI

struct PrepareSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let state: PrepareState
    @State private var rows: [PrepareRow] = []
    @State private var quality = AppSettings.videoQuality.scriptValue ?? "1080"
    @AppStorage("offlineReserveGB") private var reserveGB = 10
    @AppStorage("transcribeDownloads") private var transcript = false

    private static let qualities = [("480", "480p"), ("720", "720p"), ("1080", "1080p"), ("max", "Best")]

    var body: some View {
        let statuses = rows.map { model.prepareStatus($0) }
        let estimates = rows.map(estimate)
        let eligible = rows.indices.filter { rows[$0].include && statuses[$0] == .ready }
        let totals = PrepareTotals(eligible.map { (estimates[$0].bytes, estimates[$0].kind) })
        let (temp, out) = (DiskSpace.temporaryFolder, AppSettings.downloadDir)
        let tempFree = DiskSpace.free(at: temp), finalFree = DiskSpace.free(at: out)
        let reserve = Int64(reserveGB) * 1_000_000_000
        let shortfall = totals.shortfall(tempFree: tempFree, finalFree: finalFree, sameVolume: DiskSpace.sameVolume(temp, out), reserve: reserve)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Prepare for Offline").font(.title2.weight(.semibold))
                Text("\(state.source) • \(rows.count) \(rows.count == 1 ? "video" : "videos"). Each is checked first; nothing downloads until you press Queue.")
                    .foregroundStyle(p.secondary)
            }
            List {
                ForEach($rows) { $row in
                    let i = rows.firstIndex { $0.id == row.id } ?? 0
                    PrepareRowView(row: $row, status: statuses[i], estimate: estimates[i], quality: quality)
                }
            }
            .frame(minHeight: 260)
            .testProbe("prepareList")
            HStack(spacing: 14) {
                Picker("Video quality", selection: $quality) {
                    ForEach(Self.qualities, id: \.0) { Text("up to \($0.1)").tag($0.0) }
                }
                .fixedSize()
                Toggle("+ Transcript on this Mac", isOn: $transcript).toggleStyle(.checkbox)
                Spacer()
                Picker("Keep free", selection: $reserveGB) {
                    ForEach([5, 10, 20, 50], id: \.self) { Text("\($0) GB").tag($0) }
                }
                .fixedSize()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(totalsLine(totals, count: eligible.count, finalFree: finalFree)).font(.callout.weight(.semibold))
                if totals.unknown > 0 {
                    Text("The reserve is protected as far as sizes are known; for unknown sizes it's checked while downloading.")
                        .font(.caption).foregroundStyle(p.secondary)
                }
                if let shortfall {
                    Label("Doesn't fit: \(shortfall). Choose fewer videos, a lower quality, or a smaller reserve.", systemImage: "externaldrive.badge.exclamationmark")
                        .font(.caption.weight(.semibold)).foregroundStyle(p.orange)
                }
                if !JobController.canRun {
                    Label("Queued videos wait: \(AppSettings.jobsLockReason ?? "the queue can't run in this build").", systemImage: "lock.fill").font(.caption).foregroundStyle(p.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.prepare = nil; model.browser.checker.cancelBatch() }
                    .keyboardShortcut(.cancelAction).testProbe("prepareCancel")
                Button("Queue \(eligible.count) \(eligible.count == 1 ? "Download" : "Downloads")") {
                    model.queuePrepared(rows, quality: quality, transcript: transcript)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(eligible.isEmpty || shortfall != nil)
                .testProbe("prepareQueue")
            }
        }
        .padding(20)
        .frame(width: 760, height: 640)
        .background(p.bg)
        .onAppear { rows = state.rows }
        // the declaration sheet for one row, over this one
        .sheet(item: Binding(get: { model.declaration }, set: { model.declaration = $0 })) { DeclarationSheet(request: $0).environment(model) }
    }

    private func estimate(_ row: PrepareRow) -> (bytes: Int64?, kind: SizeKind, height: Int?) {
        guard let facts = model.browser.checker.facts[row.id] else { return (nil, .unknown, nil) }
        if row.kind == .video { return SizeEstimate.video(facts, quality: quality) }
        let a = SizeEstimate.audio(facts)
        return (a.bytes, a.kind, nil)
    }

    private func totalsLine(_ t: PrepareTotals, count: Int, finalFree: Int64?) -> String {
        var parts = ["\(count) to queue"]
        if t.bytes > 0 { parts.append((t.approximate ? "≈ " : "") + Fmt.bytes(Int(t.bytes))) }
        if t.unknown > 0 { parts.append("\(t.unknown) of unknown size") }
        if let f = finalFree { parts.append("\(Fmt.bytes(Int(f))) free → \(t.approximate ? "≈ " : "")\(Fmt.bytes(Int(max(f - t.bytes, 0)))) after") }
        parts.append("keeping \(reserveGB) GB")
        return parts.joined(separator: " • ")
    }
}

private struct PrepareRowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @Binding var row: PrepareRow
    let status: PrepareRule.Status
    let estimate: (bytes: Int64?, kind: SizeKind, height: Int?)
    let quality: String

    var body: some View {
        let a = model.availability(youtubeID: row.id)
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $row.include).toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel("Include \(row.title ?? row.id)")
            Thumbnail(url: "https://i.ytimg.com/vi/\(row.id)/mqdefault.jpg", cornerRadius: 5).frame(width: 80, height: 45)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title ?? "youtube.com/watch?v=\(row.id)").font(.callout.weight(.semibold)).lineLimit(1)
                // video, audio and summary separately: what this Mac has for it
                HStack(spacing: 6) {
                    have("Video", a.videoFile != nil, missing: a.videoMissing)
                    have("Audio", a.audioFile != nil, missing: a.audioMissing)
                    have("Summary", a.summarized, missing: false)
                }
                statusLine
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Picker("", selection: $row.kind) {
                    Text("Video").tag(JobKind.video)
                    Text("Audio").tag(JobKind.audio)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                Text(sizeText).font(.caption.monospacedDigit()).foregroundStyle(p.secondary)
            }
        }
        .padding(.vertical, 3)
        .opacity(row.include ? 1 : 0.55)
    }

    private var sizeText: String {
        guard status == .ready || status == .needsDeclaration || status == .checking else { return "" }
        var t = SizeEstimate.text(estimate.bytes, estimate.kind)
        if row.kind == .video, let h = estimate.height {
            let cap = quality == "max" ? Int.max : Int(quality) ?? 1080
            t += h < cap && quality != "max" ? " • \(h)p (its best)" : " • \(h)p"
        }
        return t
    }

    private func have(_ what: String, _ yes: Bool, missing: Bool) -> some View {
        Label(what, systemImage: yes ? "checkmark.circle.fill" : missing ? "questionmark.folder" : "circle.dashed")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(yes ? p.green : missing ? p.orange : p.secondary)
            .help(yes ? "\(what) is on this Mac" : missing ? "\(what) file missing" : "No \(what.lowercased()) on this Mac")
    }

    @ViewBuilder private var statusLine: some View {
        switch status {
        case .haveIt: Label("Already on this Mac: not downloaded again", systemImage: "checkmark.circle").font(.caption).foregroundStyle(p.green)
        case .queued: Label("Already in the queue", systemImage: "clock").font(.caption).foregroundStyle(p.accent)
        case .checking:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(model.browser.checker.batchRunning == row.id ? "Checking…" : "Waiting to be checked").font(.caption).foregroundStyle(p.secondary)
            }
        case .needsDeclaration:
            HStack(spacing: 6) {
                Label("Needs your declaration", systemImage: "hand.raised").font(.caption).foregroundStyle(p.accent)
                Button("Declare…") {
                    model.declaration = DeclarationRequest(videoID: row.id, slot: row.kind == .video ? .video : .audio, title: row.title, after: .prepare)
                }
                .buttonStyle(.link).font(.caption.weight(.semibold))
            }
        case let .unavailable(reason): Label("Unavailable: \(reason)", systemImage: "nosign").font(.caption).foregroundStyle(p.orange).lineLimit(2)
        case let .unknown(reason):
            HStack(spacing: 6) {
                Label("Couldn't check: \(reason)", systemImage: "questionmark.circle").font(.caption).foregroundStyle(p.orange).lineLimit(1)
                Button("Check Again") { model.browser.checker.recheckAll([row.id]) }.buttonStyle(.link).font(.caption.weight(.semibold))
            }
        case .ready:
            if let auth = model.authorizations["youtube:\(row.id)"] {
                Label(auth.label, systemImage: "person.badge.shield.checkmark").font(.caption).foregroundStyle(p.secondary).lineLimit(1)
            }
        }
    }
}
