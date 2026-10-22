// Runs queued jobs one at a time through the existing scripts and records the results in history.
// The queue is the `queued` rows of the jobs table, so it survives quitting and crashes. Jobs that need the
// internet wait while offline; on-device work (transcribing) runs anyway. The scripts stay the source of truth
// for downloading, transcribing and summarizing.
import Foundation
import Observation

enum StepState { case pending, running, done, failed }

struct JobStep: Identifiable, Equatable {
    let id: Int
    var label: String
    var state = StepState.pending
}

struct RetryInfo: Equatable {
    let action: JobAction
    let videoID: Int64
    var filePath: String?
}

enum Banner: Equatable {
    case running(String)
    case success(title: String, subtitle: String, file: String?)
    case failure(title: String, detail: String, retry: RetryInfo?)
    case cancelled(retry: RetryInfo?)
}

struct QueueItem: Identifiable, Equatable {
    let id: Int64
    let videoID: Int64
    let title: String
    let action: JobAction
}

@MainActor @Observable
final class JobController {
    var steps: [JobStep] = []
    var banner: Banner?
    /// True while the queue runner is working through jobs.
    private(set) var isRunning = false
    private(set) var paused = UserDefaults.standard.bool(forKey: "queuePaused")
    private(set) var queue: [QueueItem] = []
    private(set) var current: QueueItem?
    var onNotice: (String) -> Void = { _ in }

    private var script: RunningScript?
    private var metadataRun: RunningScript?
    private var cancelRequested = false
    let store: HistoryStore
    let network: NetworkMonitor

    init(store: HistoryStore, network: NetworkMonitor) {
        self.store = store
        self.network = network
    }

    var db: Database { store.db }

    // MARK: adding work

    /// Queues work for a pasted link; it starts right away when nothing else is running and the Mac is online.
    func enqueue(_ action: JobAction, link: String) {
        guard let ref = VideoRef.parse(link) else {
            banner = .failure(title: "That doesn't look like a video link",
                              detail: "Paste a full link that starts with https://, for example a YouTube watch link.", retry: nil)
            return
        }
        let (format, language) = action == .summarize ? (AppSettings.format.rawValue, AppSettings.language.rawValue) : (nil, nil)
        Task {
            do {
                let ids = try await db.enqueue(ref, action: action, format: format, language: language)
                await store.reload()
                store.select(ids.video)
                await queued(action)
            } catch let e as AlreadyQueued {
                store.select(e.videoID)
                onNotice("Already in the queue: this \(action.kind.rawValue) is waiting or downloading.")
            } catch {
                banner = .failure(title: "Couldn't add to the queue", detail: "\(error)", retry: nil)
            }
        }
    }

    /// Queues work on an existing entry: transcribe a local file, summarize a saved transcript, download again.
    func enqueue(_ action: JobAction, videoID: Int64, filePath: String? = nil,
                 format: SummaryFormat? = nil, language: SummaryLanguage? = nil) {
        Task {
            do {
                _ = try await db.enqueue(videoID: videoID, action: action, filePath: filePath,
                                         format: format?.rawValue, language: language?.rawValue)
                await store.reload()
                await queued(action)
            } catch is AlreadyQueued {
                onNotice("Already in the queue: this \(action.kind.rawValue) is waiting or downloading.")
            } catch {
                banner = .failure(title: "Couldn't add to the queue", detail: "\(error)", retry: nil)
            }
        }
    }

    func retry(_ r: RetryInfo) { enqueue(r.action, videoID: r.videoID, filePath: r.filePath) }

    private func queued(_ action: JobAction) async {
        await refreshQueue()
        if paused {
            onNotice("Added to the queue. The queue is paused; press Resume to continue.")
        } else if action.needsNetwork, !network.isOnline {
            onNotice("Added to the queue. It starts by itself when you're back online.")
        } else if isRunning {
            onNotice("Added to the queue (\(queue.count) waiting).")
        }
        pump()
    }

    // MARK: queue control

    /// Starts the next job if the runner is idle. Safe to call any time (after adding work, when the
    /// network comes back, on launch).
    func pump() {
        guard !isRunning, !paused else { return }
        isRunning = true            // claimed before any await, so two calls can't start two runners
        Task {
            while !paused, let job = try? await db.nextQueued(networkAvailable: network.isOnline) {
                // the network looked fine but nothing answers (captive Wi-Fi): now offline, look for on-device work
                if job.action.needsNetwork, !(await network.verifyInternet()) { continue }
                await execute(job)
            }
            isRunning = false
            current = nil
            await refreshQueue()
        }
    }

    func pauseQueue() { setPaused(true) }

    func resumeQueue() {
        setPaused(false)
        pump()
    }

    func removeFromQueue(_ id: Int64) {
        Task {
            try? await db.removeQueued(id)
            await refreshQueue()
            await store.reload()
        }
    }

    func clearQueue() {
        Task {
            let n = (try? await db.clearQueue()) ?? 0
            await refreshQueue()
            await store.reload()
            if n > 0 { onNotice("Removed \(n) waiting jobs from the queue.") }
        }
    }

    /// Stops the running job and everything it started, and pauses the queue so nothing else starts.
    func cancel() {
        if current != nil, !cancelRequested {
            cancelRequested = true
            script?.cancel()
            metadataRun?.cancel()
            banner = .running("Cancelling…")
        } else if !queue.isEmpty {
            setPaused(true)
        }
    }

    func dismissBanner() { if current == nil { banner = nil } }

    /// Test hooks only: pretend a job is running (the paused test queue never runs one).
    func testSetCurrent(_ item: QueueItem?) { current = item }

    func refreshQueue() async {
        queue = ((try? await db.queuedJobs()) ?? []).map {
            QueueItem(id: $0.job.id, videoID: $0.job.videoID, title: $0.title ?? "Untitled video", action: $0.job.action)
        }
    }

    private func setPaused(_ on: Bool) {
        paused = on
        UserDefaults.standard.set(on, forKey: "queuePaused")
    }

    // MARK: running one job

    private func execute(_ job: Job) async {
        cancelRequested = false
        guard let video = try? await db.video(job.videoID) else {
            try? await db.removeQueued(job.id)
            return
        }
        guard (try? await db.markRunning(job.id)) == true else { return }   // removed from the queue meanwhile
        current = QueueItem(id: job.id, videoID: video.id, title: video.displayTitle, action: job.action)
        await refreshQueue()
        await store.reload()
        switch job.action {
        case .summarize, .audio, .video, .audioTranscript, .videoTranscript: await runDownload(job, video)
        case .transcribe: await runTranscribe(job, video)
        case .resummarize: await runResummarize(job, video)
        }
        script = nil
        metadataRun = nil
        current = nil
        if cancelRequested { setPaused(true) }
        await store.reload()
    }

    private func runDownload(_ job: Job, _ video: Video) async {
        let kind = job.action.kind
        steps = kind == .summary
            ? [JobStep(id: 0, label: "Download audio"), JobStep(id: 1, label: "Transcribe on-device"),
               JobStep(id: 2, label: "Generate AI summary"), JobStep(id: 3, label: "Save to library")]
            : [JobStep(id: 0, label: kind == .audio ? "Download audio" : "Download video"), JobStep(id: 1, label: "Save to library")]
        steps[0].state = .running
        banner = .running(kind == .summary ? "Summarizing \(video.displayTitle)…" : "Downloading \(video.displayTitle)…")
        let retry = RetryInfo(action: job.action, videoID: video.id)
        let ids = (video: video.id, job: job.id)
        guard let url = video.url else {
            await fail(ids, job: job, title: "This entry has no original link to download from", output: [], retry: nil)
            return
        }
        let format = SummaryFormat(rawValue: job.summaryFormat ?? "") ?? AppSettings.format
        let language = SummaryLanguage(rawValue: job.summaryLanguage ?? "") ?? AppSettings.language
        let outDir = AppSettings.downloadDir

        // metadata runs alongside the download and never decides success
        let metadata = Task { await MetadataFetcher.fetch(url) { self.metadataRun = $0 } }

        let command = kind == .summary
            ? [Paths.summarize, url]
            : [Paths.cobaltDL, url, kind == .audio ? "audio" : "auto", outDir]
        var env = ["VS_FROM_APP": "1", "VS_OUT_DIR": outDir]
        if kind == .summary { env["VS_SUMMARY_PROMPT"] = Prompts.build(format, language) }
        if kind == .video, let q = AppSettings.videoQuality.scriptValue { env["VS_VIDEO_QUALITY"] = q }

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
        // keep real metadata even when the job fails or is cancelled, so the entry isn't left untitled
        if let info { try? await db.applyInfo(video.id, info, override: true) }

        if cancelRequested { await cancelled(ids, job: job, retry: retry); return }
        guard status == 0 else {
            await fail(ids, job: job, title: "Processing failed", output: output, retry: retry)
            return
        }

        // never trust the exit code alone: the expected files must exist and not be empty
        var result = NewJob(kind: kind, status: .succeeded, source: .app)
        let media: URL
        if kind == .summary {
            guard let line = output.last(where: { $0.unicodeScalars.first == "\u{1F4C1}" }) else {
                await fail(ids, job: job, title: "Finished, but the script didn't report its files", output: output, retry: retry)
                return
            }
            media = URL(fileURLWithPath: String(String.UnicodeScalarView(line.unicodeScalars.dropFirst())).trimmingCharacters(in: .whitespaces))
            let outputs = SummaryOutputs.load(base: media.deletingPathExtension().path)
            guard let summary = outputs.summary else {
                await fail(ids, job: job, title: "Finished, but no summary was saved", output: output, retry: retry)
                return
            }
            result.summary = summary
            result.summaryPath = outputs.summaryPath
            result.summaryLanguage = language.rawValue
            result.summaryFormat = format.rawValue
            result.transcript = outputs.transcript
            result.transcriptPath = outputs.transcriptPath
            result.segmentsJSON = outputs.segmentsJSON
            result.transcriptLanguage = outputs.language
        } else {
            guard let path = output.last(where: { $0.hasPrefix("/") }) else {
                await fail(ids, job: job, title: "Finished, but the script didn't report the saved file", output: output, retry: retry)
                return
            }
            media = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespaces))
        }
        guard let size = fileSize(media.path), size > 0 else {
            await fail(ids, job: job, title: "The downloaded file is missing or empty", output: output + [media.path], retry: retry)
            return
        }
        result.filePath = media.path
        result.fileSize = size

        markRunningStep(.done)
        steps[steps.count - 1].state = .running
        do {
            try await save(ids, job: result, metadata: info, media: media)
        } catch {
            steps[steps.count - 1].state = .failed
            banner = .failure(title: "Processed, but saving to history failed",
                              detail: "\(error)\nYour files are safe in \(media.deletingLastPathComponent().path).", retry: retry)
            return
        }
        for i in steps.indices { steps[i].state = .done }
        let saved = (try? await db.video(video.id)) ?? nil
        if let saved { await Thumbnails.ensure(saved, localVideo: kind == .video ? media.path : nil, db: db, online: network.isOnline) }
        // "+ Transcript": the transcript is its own queued job for this exact file, so it's cancel-safe and never
        // blocks the next download (in a playlist, the transcripts run after the waiting downloads)
        var transcriptQueued = false
        if job.action.transcribesAfter {
            transcriptQueued = (try? await db.enqueue(videoID: video.id, action: .transcribe, filePath: media.path)) != nil
            await refreshQueue()
        }
        let duration = saved?.duration.flatMap(Fmt.duration)
        let subtitle = kind == .summary
            ? "Summary saved" + (duration.map { " • \($0) video" } ?? "") + " • \(Fmt.bytes(size)) mp3"
            : "Downloaded successfully • \(Fmt.bytes(size))" + (transcriptQueued ? " • transcript next" : "")
        banner = .success(title: "Saved \(media.lastPathComponent)", subtitle: subtitle, file: media.path)
    }

    /// On-device transcript of a local file. Needs no internet.
    private func runTranscribe(_ job: Job, _ video: Video) async {
        steps = [JobStep(id: 0, label: "Transcribe on this Mac", state: .running), JobStep(id: 1, label: "Save to library")]
        banner = .running("Transcribing \(video.displayTitle) on this Mac…")
        let ids = (video: video.id, job: job.id)
        let media = job.filePath ?? store.mediaFiles(for: video.id).first(where: \.exists)?.path
        let retry = RetryInfo(action: .transcribe, videoID: video.id, filePath: media)
        guard let media, FileManager.default.fileExists(atPath: media) else {
            await fail(ids, job: job, title: "There's no audio or video file on this Mac to transcribe", output: [], retry: nil)
            return
        }
        var output: [String] = []
        var status: Int32 = -1
        do {
            let run = try RunningScript([Paths.transcribe, media])
            script = run
            status = await run.stream { output.append($0) }
        } catch {
            output.append("Could not start the transcriber: \(error)")
        }
        if cancelRequested { await cancelled(ids, job: job, retry: retry); return }
        let outputs = SummaryOutputs.load(base: (media as NSString).deletingPathExtension)
        guard status == 0, let transcript = outputs.transcript else {
            await fail(ids, job: job, title: "Transcribing failed", output: output, retry: retry)
            return
        }
        steps[0].state = .done
        steps[1].state = .running
        do {
            try await db.finishJob(job.id, videoID: video.id,
                                   NewJob(kind: .transcript, status: .succeeded, source: .app, filePath: media, fileSize: fileSize(media),
                                          transcriptPath: outputs.transcriptPath, transcript: transcript,
                                          segmentsJSON: outputs.segmentsJSON, transcriptLanguage: outputs.language))
        } catch {
            steps[1].state = .failed
            banner = .failure(title: "Transcribed, but saving to history failed", detail: "\(error)", retry: retry)
            return
        }
        steps[1].state = .done
        let lang = Fmt.language(outputs.language).map { " • \($0)" } ?? ""
        banner = .success(title: "Transcript saved", subtitle: "\(outputs.segments.count) timestamped lines\(lang)", file: outputs.transcriptPath)
    }

    /// A new summary version from the saved transcript: no download, no transcription. Existing summaries are never
    /// modified, so a failed or cancelled run loses nothing.
    private func runResummarize(_ job: Job, _ video: Video) async {
        let format = SummaryFormat(rawValue: job.summaryFormat ?? "") ?? AppSettings.format
        let language = SummaryLanguage(rawValue: job.summaryLanguage ?? "") ?? AppSettings.language
        steps = [JobStep(id: 0, label: "Generate AI summary (\(format.rawValue), \(language.rawValue))", state: .running),
                 JobStep(id: 1, label: "Save to library")]
        banner = .running("Summarizing the saved transcript of \(video.displayTitle)…")
        let ids = (video: video.id, job: job.id)
        let retry = RetryInfo(action: .resummarize, videoID: video.id)
        let jobs = (try? await db.jobs(for: video.id)) ?? []
        guard let transcript = jobs.first(where: { $0.transcript?.nilIfBlank != nil })?.transcript else {
            await fail(ids, job: job, title: "This entry has no saved transcript to summarize", output: [], retry: nil)
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vs-regen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("transcript.txt"), resultFile = dir.appendingPathComponent("summary.md")
        var output: [String] = []
        var status: Int32 = -1
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try transcript.write(to: input, atomically: true, encoding: .utf8)
            // the guard keeps stdin for its lifeline, so the transcript goes in and out through files
            let run = try RunningScript(["/bin/bash", "-c", #"claude -p --model sonnet "$1" < "$2" > "$3""#, "regen",
                                         Prompts.build(format, language), input.path, resultFile.path])
            script = run
            status = await run.stream { output.append($0) }
        } catch {
            output.append("Could not start claude: \(error)")
        }
        let summary = (try? String(contentsOf: resultFile, encoding: .utf8))?.nilIfBlank
        if cancelRequested { await cancelled(ids, job: job, retry: retry); return }
        guard status == 0, let summary else {
            await fail(ids, job: job, title: "Summarizing failed. Your saved summaries are unchanged.",
                       output: output.isEmpty ? ["Claude returned no summary"] : output, retry: retry)
            return
        }
        steps[0].state = .done
        steps[1].state = .running
        do {
            try await db.finishJob(job.id, videoID: video.id,
                                   NewJob(kind: .summary, status: .succeeded, source: .app, summary: summary,
                                          summaryLanguage: language.rawValue, summaryFormat: format.rawValue))
        } catch {
            steps[1].state = .failed
            banner = .failure(title: "Couldn't save the new summary", detail: "\(error)", retry: retry)
            return
        }
        steps[1].state = .done
        banner = .success(title: "New summary saved", subtitle: "\(format.rawValue) • \(language.rawValue)", file: nil)
    }

    // MARK: helpers

    /// Writes the result; yt-dlp metadata is already saved, so the filename and ffprobe only fill gaps.
    private func save(_ ids: (video: Int64, job: Int64), job: NewJob, metadata: VideoInfo?, media: URL) async throws {
        try await db.finishJob(ids.job, videoID: ids.video, job)
        let parsed = FileNames.parse(stem: media.deletingPathExtension().lastPathComponent)
        var guess = VideoInfo(title: parsed.title, channel: parsed.channel, platform: parsed.platform)
        if metadata?.duration == nil { guess.duration = await MetadataFetcher.probeDuration(media.path) }
        try await db.applyInfo(ids.video, guess, override: false)
        try await db.mergeImportedDuplicates(into: ids.video)
    }

    private func fail(_ ids: (video: Int64, job: Int64), job: Job, title: String, output: [String], retry: RetryInfo?) async {
        markRunningStep(.failed)
        let tail = output.suffix(40).joined(separator: "\n")
        try? await db.finishJob(ids.job, videoID: ids.video, NewJob(kind: job.kind, status: .failed, source: .app, error: tail.nilIfBlank ?? title))
        banner = .failure(title: title, detail: tail.nilIfBlank ?? "No output was captured.", retry: retry)
    }

    private func cancelled(_ ids: (video: Int64, job: Int64), job: Job, retry: RetryInfo) async {
        markRunningStep(.failed)
        try? await db.finishJob(ids.job, videoID: ids.video, NewJob(kind: job.kind, status: .cancelled, source: .app, error: "Cancelled"))
        banner = .cancelled(retry: retry)
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
}
