// Video Summarizer: a thin window over the tested ~/cobalt scripts.
// All download / transcribe / summarize logic lives in those scripts; this file only runs them and shows progress.
import AppKit
import SwiftUI

let home = FileManager.default.homeDirectoryForCurrentUser.path
let outDir = "\(home)/Downloads/cobalt"

enum Job { case summarize, audio, video }

struct Step: Identifiable {
    enum State { case pending, running, done, failed }
    let id: Int
    var label: String
    var state = State.pending
    var icon: String {
        switch state {
        case .pending: "○"
        case .running: "⏳"
        case .done: "✅"
        case .failed: "❌"
        }
    }
}

@MainActor
final class Runner: ObservableObject {
    @Published var steps: [Step] = []
    @Published var running = false
    @Published var failed = false
    @Published var summary = ""
    @Published var resultFile: URL?
    private var output: [String] = []

    func start(_ job: Job, url: String) {
        let args: [String]
        switch job {
        case .summarize:
            args = ["\(home)/cobalt/raycast/summarize.sh", url]
            steps = [Step(id: 0, label: "Download audio"), Step(id: 1, label: "Transcribe on-device"), Step(id: 2, label: "Summarize")]
        case .audio, .video:
            args = ["\(home)/cobalt/cobalt-dl.sh", url, job == .audio ? "audio" : "auto", outDir]
            steps = [Step(id: 0, label: job == .audio ? "Download audio" : "Download video")]
        }
        steps[0].state = .running
        summary = ""
        resultFile = nil
        failed = false
        output = []
        running = true

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            finish(job, status: 1, extra: "Could not start \(args[0]): \(error.localizedDescription)")
            return
        }
        Task {
            do {
                for try await line in pipe.fileHandleForReading.bytes.lines { handle(line) }
            } catch {}
            while process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
            finish(job, status: process.terminationStatus)
        }
    }

    // these markers must match what summarize.sh and cobalt-dl.sh print
    private func handle(_ line: String) {
        output.append(line)
        if line.contains("falling back to yt-dlp"), !steps[0].label.contains("yt-dlp") {
            steps[0].label += " (yt-dlp fallback)"
        } else if line.contains("Transcribing") {
            advance(to: 1)
        } else if line.contains("Summarizing") {
            advance(to: 2)
        }
    }

    private func advance(to i: Int) {
        guard i < steps.count else { return }
        steps[i - 1].state = .done
        steps[i].state = .running
    }

    private func finish(_ job: Job, status: Int32, extra: String? = nil) {
        running = false
        if let extra { output.append(extra) }
        guard status == 0 else {
            failed = true
            if let i = steps.firstIndex(where: { $0.state == .running }) { steps[i].state = .failed }
            summary = output.joined(separator: "\n")
            return
        }
        for i in steps.indices { steps[i].state = .done }
        switch job {
        case .summarize:
            // summarize.sh ends with "📁 <mp3 path>"; the summary sits next to it as <name>.summary.md
            guard let line = output.last(where: { $0.hasPrefix("📁") }) else { return }
            let mp3 = URL(fileURLWithPath: line.dropFirst().trimmingCharacters(in: .whitespaces))
            resultFile = mp3
            summary = (try? String(contentsOf: mp3.deletingPathExtension().appendingPathExtension("summary.md"), encoding: .utf8)) ?? ""
        case .audio, .video:
            // cobalt-dl.sh prints the saved file's path as its last line
            guard let path = output.last(where: { !$0.isEmpty }) else { return }
            resultFile = URL(fileURLWithPath: path)
            steps[0].label = "Saved \(resultFile!.lastPathComponent)"
        }
    }
}

func clipboardLink() -> String? {
    let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.flatMap { $0.hasPrefix("http") ? $0 : nil }
}

struct ContentView: View {
    @StateObject private var runner = Runner()
    @State private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Paste a video link", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { go(.summarize) }
                Button("Paste") { if let s = clipboardLink() { link = s } }
            }
            HStack {
                Button { go(.summarize) } label: { Label("Summarize", systemImage: "brain") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                Button { go(.audio) } label: { Label("Audio", systemImage: "music.note") }
                Button { go(.video) } label: { Label("Video", systemImage: "film") }
                Spacer()
                if runner.running { ProgressView().controlSize(.small) }
            }
            .disabled(runner.running || link.isEmpty)

            ForEach(runner.steps) { Text("\($0.icon)  \($0.label)") }

            ScrollView {
                summaryText
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Show in Finder") {
                    if let f = runner.resultFile { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                }
                .disabled(runner.resultFile == nil)
                Button("Copy summary") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(runner.summary, forType: .string)
                }
                .disabled(runner.summary.isEmpty || runner.failed)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 480)
        .onAppear { if link.isEmpty, let s = clipboardLink() { link = s } }
    }

    private var summaryText: Text {
        if runner.failed { return Text(runner.summary).font(.system(.body, design: .monospaced)) }
        let md = try? AttributedString(markdown: runner.summary,
                                       options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return Text(md ?? AttributedString(runner.summary))
    }

    private func go(_ job: Job) {
        guard !runner.running, !link.isEmpty else { return }
        runner.start(job, url: link)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct VideoSummarizerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Video Summarizer", id: "main") { ContentView() }
            .windowResizability(.contentMinSize)
    }
}
