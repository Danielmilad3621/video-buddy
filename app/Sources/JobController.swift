// Runs one job at a time through the existing scripts and records the result in history.
// The scripts stay the source of truth for downloading, transcribing and summarizing.
import Foundation
import Observation

enum StepState { case pending, running, done, failed }

struct JobStep: Identifiable, Equatable {
    let id: Int
    var label: String
    var state = StepState.pending
}

struct RetryInfo: Equatable {
    let kind: JobKind
    let url: String
}

enum Banner: Equatable {
    case running(String)
    case success(title: String, subtitle: String, file: String?)
    case failure(title: String, detail: String, retry: RetryInfo?)
    case cancelled(retry: RetryInfo?)
}

@MainActor @Observable
final class JobController {
    var steps: [JobStep] = []
    var banner: Banner?
    var isRunning = false
    private var script: RunningScript?
    private var metadataRun: RunningScript?
    private var cancelRequested = false
    let store: HistoryStore

    init(store: HistoryStore) { self.store = store }

    var db: Database { store.db }

    func start(_ kind: JobKind, link: String) {
        guard !isRunning else { return }
        guard let ref = VideoRef.parse(link) else {
            banner = .failure(title: "That doesn't look like a video link",
                              detail: "Paste a full link that starts with https://, for example a YouTube watch link.", retry: nil)
            return
        }
        run(kind, ref: ref)
    }

    func cancel() {
        guard isRunning, !cancelRequested else { return }
        cancelRequested = true
        script?.cancel()
        metadataRun?.cancel()
        banner = .running("Cancelling…")
    }

    func dismissBanner() { if !isRunning { banner = nil } }

    // MARK: pipeline

    private func run(_ kind: JobKind, ref: VideoRef) {
        isRunning = true
        cancelRequested = false
        steps = kind == .summary
            ? [JobStep(id: 0, label: "Download audio"), JobStep(id: 1, label: "Transcribe on-device"),
               JobStep(id: 2, label: "Generate AI summary"), JobStep(id: 3, label: "Save to history")]
            : [JobStep(id: 0, label: kind == .audio ? "Download audio" : "Download video"), JobStep(id: 1, label: "Save to history")]
        steps[0].state = .running
        banner = .running(kind == .summary ? "Summarizing…" : "Downloading…")
        let format = AppSettings.format, language = AppSettings.language, outDir = AppSettings.downloadDir
        let retry = RetryInfo(kind: kind, url: ref.url)

        Task {
            defer { isRunning = false; script = nil; metadataRun = nil }
            let ids: (video: Int64, job: Int64)
            do {
                ids = try await db.startJob(ref, kind: kind, source: .app)
            } catch {
                steps[0].state = .failed
                banner = .failure(title: "Couldn't write to history", detail: "\(error)", retry: retry)
                return
            }
            await store.reload()
            store.select(ids.video)

            // metadata runs alongside the download and never decides success
            let metadata = Task { await MetadataFetcher.fetch(ref.url) { self.metadataRun = $0 } }

            let command = kind == .summary
                ? ["\(home)/cobalt/raycast/summarize.sh", ref.url]
                : ["\(home)/cobalt/cobalt-dl.sh", ref.url, kind == .audio ? "audio" : "auto", outDir]
            var env = ["VS_FROM_APP": "1", "VS_OUT_DIR": outDir]
            if kind == .summary { env["VS_SUMMARY_PROMPT"] = Prompts.build(format, language) }

            var output: [String] = []
            var status: Int32 = -1
            do {
                let run = try RunningScript(command, env: env)
                script = run
                var summarizing = false
                status = await run.stream { line in
                    output.append(line)
                    if !summarizing { summarizing = self.handleMarker(line) }
                }
            } catch {
                output.append("Could not start \(command[0]): \(error)")
            }
            let info = await metadata.value

            if cancelRequested {
                markRunningStep(.failed)
                try? await db.finishJob(ids.job, videoID: ids.video, NewJob(kind: kind, status: .cancelled, source: .app, error: "Cancelled"))
                banner = .cancelled(retry: retry)
                await store.reload()
                return
            }
            guard status == 0 else {
                await fail(ids, kind: kind, title: "Processing failed", output: output, retry: retry)
                return
            }

            // never trust the exit code alone: the expected files must exist and not be empty
            var job = NewJob(kind: kind, status: .succeeded, source: .app)
            let media: URL
            if kind == .summary {
                guard let line = output.last(where: { $0.unicodeScalars.first == "\u{1F4C1}" }) else {
                    await fail(ids, kind: kind, title: "Finished, but the script didn't report its files", output: output, retry: retry)
                    return
                }
                media = URL(fileURLWithPath: String(String.UnicodeScalarView(line.unicodeScalars.dropFirst())).trimmingCharacters(in: .whitespaces))
                let outputs = SummaryOutputs.load(base: media.deletingPathExtension().path)
                guard let summary = outputs.summary else {
                    await fail(ids, kind: kind, title: "Finished, but no summary was saved", output: output, retry: retry)
                    return
                }
                job.summary = summary
                job.summaryPath = outputs.summaryPath
                job.summaryLanguage = language.rawValue
                job.summaryFormat = format.rawValue
                job.transcript = outputs.transcript
                job.transcriptPath = outputs.transcriptPath
                job.segmentsJSON = outputs.segmentsJSON
                job.transcriptLanguage = outputs.language
            } else {
                guard let path = output.last(where: { $0.hasPrefix("/") }) else {
                    await fail(ids, kind: kind, title: "Finished, but the script didn't report the saved file", output: output, retry: retry)
                    return
                }
                media = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespaces))
            }
            guard let size = fileSize(media.path), size > 0 else {
                await fail(ids, kind: kind, title: "The downloaded file is missing or empty", output: output + [media.path], retry: retry)
                return
            }
            job.filePath = media.path
            job.fileSize = size

            markRunningStep(.done)
            steps[steps.count - 1].state = .running
            do {
                try await save(ids, job: job, metadata: info, media: media)
            } catch {
                steps[steps.count - 1].state = .failed
                banner = .failure(title: "Processed, but saving to history failed",
                                  detail: "\(error)\nYour files are safe in \(media.deletingLastPathComponent().path).", retry: retry)
                return
            }
            for i in steps.indices { steps[i].state = .done }
            let duration = (try? await db.video(ids.video))??.duration.flatMap(Fmt.duration)
            let subtitle = kind == .summary
                ? "Summary saved" + (duration.map { " • \($0) video" } ?? "") + " • \(Fmt.bytes(size)) mp3"
                : "Downloaded successfully • \(Fmt.bytes(size))"
            banner = .success(title: "Saved \(media.lastPathComponent)", subtitle: subtitle, file: media.path)
            await store.reload()
            store.select(ids.video)
        }
    }

    /// Writes the result, then metadata: yt-dlp's values win, the filename and ffprobe only fill gaps.
    private func save(_ ids: (video: Int64, job: Int64), job: NewJob, metadata: VideoInfo?, media: URL) async throws {
        try await db.finishJob(ids.job, videoID: ids.video, job)
        if let metadata { try await db.applyInfo(ids.video, metadata, override: true) }
        let parsed = FileNames.parse(stem: media.deletingPathExtension().lastPathComponent)
        var guess = VideoInfo(title: parsed.title, channel: parsed.channel, platform: parsed.platform)
        if metadata?.duration == nil { guess.duration = await MetadataFetcher.probeDuration(media.path) }
        try await db.applyInfo(ids.video, guess, override: false)
        try await db.mergeImportedDuplicates(into: ids.video)
    }

    private func fail(_ ids: (video: Int64, job: Int64), kind: JobKind, title: String, output: [String], retry: RetryInfo) async {
        markRunningStep(.failed)
        let tail = output.suffix(40).joined(separator: "\n")
        try? await db.finishJob(ids.job, videoID: ids.video, NewJob(kind: kind, status: .failed, source: .app, error: tail))
        banner = .failure(title: title, detail: tail.nilIfBlank ?? "No output was captured.", retry: retry)
        await store.reload()
    }

    /// Only lines that start with the scripts' exact marker emoji count; the summary text after 🧠 is never parsed.
    /// Returns true once summarizing has started.
    private func handleMarker(_ line: String) -> Bool {
        switch line.unicodeScalars.first {
        case "\u{1F399}": advance(to: 1)                       // 🎙️ Transcribing on-device…
        case "\u{1F9E0}": advance(to: 2); return true          // 🧠 Summarizing…
        default:
            if line.hasPrefix("cobalt: "), line.contains("falling back to yt-dlp"), !steps[0].label.contains("yt-dlp") {
                steps[0].label += " (yt-dlp fallback)"
            }
        }
        return false
    }

    private func advance(to i: Int) {
        guard i < steps.count else { return }
        for j in 0..<i { steps[j].state = .done }
        steps[i].state = .running
    }

    private func markRunningStep(_ state: StepState) {
        if let i = steps.firstIndex(where: { $0.state == .running }) { steps[i].state = state }
    }

    private func fileSize(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue
    }

    // MARK: regenerate

    /// A new summary version from the saved transcript: no download, no transcription. Existing summaries are never
    /// modified, so a failed or cancelled regeneration loses nothing.
    func regenerate(videoID: Int64, transcript: String, mediaPath: String?, format: SummaryFormat, language: SummaryLanguage) {
        guard !isRunning, transcript.nilIfBlank != nil else { return }
        isRunning = true
        cancelRequested = false
        steps = [JobStep(id: 0, label: "Generate AI summary (\(format.rawValue), \(language.rawValue))", state: .running),
                 JobStep(id: 1, label: "Save to history")]
        banner = .running("Regenerating summary…")

        Task {
            defer { isRunning = false; script = nil }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vs-regen-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let input = dir.appendingPathComponent("transcript.txt"), result = dir.appendingPathComponent("summary.md")
            let jobID: Int64
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try transcript.write(to: input, atomically: true, encoding: .utf8)
                jobID = try await db.startJob(videoID: videoID, kind: .summary, source: .app)
            } catch {
                steps[0].state = .failed
                banner = .failure(title: "Couldn't start regenerating", detail: "\(error)", retry: nil)
                return
            }
            var output: [String] = []
            var status: Int32 = -1
            do {
                // the guard keeps stdin for its lifeline, so the transcript goes in and out through files
                let run = try RunningScript(["/bin/bash", "-c", #"claude -p --model sonnet "$1" < "$2" > "$3""#, "regen",
                                             Prompts.build(format, language), input.path, result.path])
                script = run
                status = await run.stream { output.append($0) }
            } catch {
                output.append("Could not start claude: \(error)")
            }
            let summary = (try? String(contentsOf: result, encoding: .utf8))?.nilIfBlank
            let ids = (video: videoID, job: jobID)
            if cancelRequested {
                steps[0].state = .failed
                try? await db.finishJob(jobID, videoID: videoID, NewJob(kind: .summary, status: .cancelled, source: .app, error: "Cancelled"))
                banner = .cancelled(retry: nil)
                await store.reload()
                return
            }
            guard status == 0, let summary else {
                steps[0].state = .failed
                let tail = output.suffix(40).joined(separator: "\n")
                try? await db.finishJob(jobID, videoID: videoID,
                                        NewJob(kind: .summary, status: .failed, source: .app, error: tail.nilIfBlank ?? "Claude returned no summary"))
                banner = .failure(title: "Regeneration failed. Your saved summaries are unchanged.",
                                  detail: tail.nilIfBlank ?? "Claude returned no summary.", retry: nil)
                await store.reload()
                return
            }
            steps[0].state = .done
            steps[1].state = .running
            do {
                try await db.finishJob(ids.job, videoID: videoID,
                                       NewJob(kind: .summary, status: .succeeded, source: .app, summary: summary,
                                              summaryLanguage: language.rawValue, summaryFormat: format.rawValue))
            } catch {
                steps[1].state = .failed
                banner = .failure(title: "Couldn't save the new summary", detail: "\(error)", retry: nil)
                return
            }
            steps[1].state = .done
            banner = .success(title: "New summary saved", subtitle: "\(format.rawValue) • \(language.rawValue)", file: nil)
            await store.reload()
        }
    }
}
