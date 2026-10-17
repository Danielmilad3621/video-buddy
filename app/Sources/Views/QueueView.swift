// The job queue in the banner: what's waiting, and pause / resume / remove / clear.
import SwiftUI

struct QueueButton: View {
    @Environment(AppModel.self) private var model
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: { Label("Queue (\(model.jobs.queue.count))", systemImage: "list.bullet") }
            .buttonStyle(SecondaryButtonStyle(height: 36, font: .callout))
            .popover(isPresented: $open, arrowEdge: .bottom) { QueueList().environment(model) }
            .help("Jobs waiting to run")
    }
}

struct QueueList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p

    var body: some View {
        let jobs = model.jobs
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Queue").font(.headline)
                Spacer()
                if jobs.paused {
                    Button("Resume") { jobs.resumeQueue() }
                } else {
                    Button("Pause") { jobs.pauseQueue() }.help("Finish the current job, then wait")
                }
                Button("Clear", role: .destructive) { jobs.clearQueue() }.disabled(jobs.queue.isEmpty)
            }
            if let current = jobs.current {
                row(current, running: true)
            }
            if jobs.queue.isEmpty {
                Text("Nothing waiting.").foregroundStyle(.secondary).font(.callout)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(jobs.queue.enumerated()), id: \.element.id) { i, item in row(item, running: false, position: i + 1) }
                    }
                }
                .frame(maxHeight: 320)
            }
            if !model.network.isOnline {
                Label("Offline: jobs that need the internet wait; transcribing on this Mac still runs.", systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private func row(_ item: QueueItem, running: Bool, position: Int = 0) -> some View {
        HStack(spacing: 8) {
            if running { ProgressView().controlSize(.mini) } else { Text("\(position).").monospacedDigit().foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                Text(running ? "\(item.action.label) • running" : item.action.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !running {
                Button { model.jobs.removeFromQueue(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove from the queue")
            }
        }
    }
}

/// Shown when jobs are waiting but nothing runs: the queue is paused, or the Mac is offline.
struct WaitingQueueCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p

    var body: some View {
        let jobs = model.jobs
        let n = jobs.queue.count
        let (icon, title, detail): (String, String, String) = jobs.paused
            ? ("pause.circle.fill", "Queue paused • \(n) waiting", "Press Resume to continue with the next job.")
            : !model.network.isOnline
            ? ("wifi.slash", "Waiting for internet • \(n) in the queue", "They start by themselves when you're back online.")
            : ("hourglass", "\(n) waiting", "Starting…")
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(p.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(p.secondary)
            }
            Spacer()
            if jobs.paused {
                Button { jobs.resumeQueue() } label: { Label("Resume", systemImage: "play.fill") }
                    .buttonStyle(SecondaryButtonStyle(height: 36, font: .callout))
            }
            QueueButton()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(p.elevated.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.border))
    }
}
