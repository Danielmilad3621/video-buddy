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
    /// 4.0 Phase 4: a prepared download's quality and size estimate ("720p · ≈ 412 MB").
    var options: JobOptions? = nil
}

@MainActor @Observable
final class JobController {
    var steps: [JobStep] = []
    var banner: Banner?
    /// True while the queue runner is working through jobs.
    private(set) var isRunning = false
    private(set) var paused = locked(UserDefaults.standard.bool(forKey: "queuePaused"))
    private(set) var queue: [QueueItem] = []
    private(set) var current: QueueItem?
    var onNotice: (String) -> Void = { _ in }
    /// 4.0 G1b: the last download's script output (the end of it), for test runs: e.g. why cobalt fell back to yt-dlp.
    private(set) var lastOutput: [String] = []
    /// 4.0 Phase 4: why the queue paused by itself (low disk space), shown with it.
    private(set) var pauseReason: String?
    /// 4.0 Phase 4: the last check before a YouTube download runs (a declaration on record, the technical checks
    /// passed, looked up again when old); returns why it may not, or nil. AppModel provides it.
    @ObservationIgnored var authorize: (Job, Video) async -> String? = { _, _ in nil }
    /// Set by the disk watch while a download runs: the volume that went below the reserve.
    @ObservationIgnored private var lowSpace: SpaceRule.Volume?

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
            } catch let e as QueueRefused {
                onNotice(e.description)
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
            } catch let e as QueueRefused {
                onNotice(e.description)
            } catch {
                banner = .failure(title: "Couldn't add to the queue", detail: "\(error)", retry: nil)
            }
        }
    }

    func retry(_ r: RetryInfo) { enqueue(r.action, videoID: r.videoID, filePath: r.filePath) }

    private func queued(_ action: JobAction) async {
        await refreshQueue()
        if let lock = Self.canRun ? (action.downloadsMedia ? Self.downloadsLock : nil) : AppSettings.jobsLockReason {
            onNotice("Added to the queue, where it waits: \(lock).")
        } else if paused {
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
            while !paused, let job = try? await db.nextQueued(networkAvailable: network.isOnline, downloadsAllowed: downloadsAllowed) {
                // the Preview runs nothing, whatever is pressed
                if !Self.canRun {
                    setPaused(true)
                    break
                }
                // 4.0 G2: each kind of job has its own lock, checked before every job. A download picked just as the RC's
                // live-download window ended isn't started: the next pick leaves it waiting, and other work carries on
                if job.action.downloadsMedia, !downloadsAllowed { continue }
                // the network looked fine but nothing answers (captive Wi-Fi): now offline, look for on-device work
                if job.action.needsNetwork, !FakeRunner.enabled, !(await network.verifyInternet()) { continue }
                await execute(job)
            }
            isRunning = false
            current = nil
            await refreshQueue()
        }
    }

    /// Downloads may run now: online, on Wi-Fi or Ethernet if you asked for that, and not locked in this build (checked
    /// when each job starts).
    var downloadsAllowed: Bool { network.isOnline && (!AppSettings.downloadsUnmeteredOnly || network.isUnmetered) && Self.downloadsLock == nil }

    /// 4.0 G2: why downloads wait in this build, or nil: the Preview never downloads, the RC only inside a live-download
    /// window (the test build's fake runner aside). AI has its own lock (queueRefusal); on-device transcripts need neither.
    nonisolated static var downloadsLock: String? { FakeRunner.enabled ? nil : AppSettings.jobsLockReason ?? AppSettings.downloadsLockReason }

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
            QueueItem(id: $0.job.id, videoID: $0.job.videoID, title: $0.title ?? "Untitled video", action: $0.job.action,
                      options: $0.job.sizeKind.map { [job = $0.job] kind in JobOptions(quality: job.quality, estimatedBytes: job.estimatedBytes, sizeKind: kind) })
        }
    }

    /// The Preview never runs jobs (downloads, transcripts, AI summaries): the queue stays paused whatever is pressed.
    /// (The test build's fake runner, which never downloads anything, is the one exception.) The RC's locks are per job.
    nonisolated static func locked(_ paused: Bool) -> Bool { paused || (AppSettings.jobsLockReason != nil && !FakeRunner.enabled) }
    /// The queue can run at all in this build (not the Preview).
    nonisolated static var canRun: Bool { !locked(false) }

    private func setPaused(_ on: Bool) {
        paused = Self.locked(on)
        UserDefaults.standard.set(on, forKey: "queuePaused")
        if !on { pauseReason = nil }
    }

    /// Paused for a reason the queue shows (low disk space); nothing is retried until you resume.
    private func pause(because reason: String) {
        setPaused(true)
        pauseReason = reason
    }

    /// Before a download starts: room on every volume it uses, keeping your reserve.
    private func spaceShortfall(_ job: Job) -> SpaceRule.Shortfall? {
        let (temp, out) = (DiskSpace.temporaryFolder, AppSettings.downloadDir)
        return SpaceRule.check(estimate: job.estimatedBytes, tempFree: DiskSpace.free(at: temp), finalFree: DiskSpace.free(at: out),
                               sameVolume: DiskSpace.sameVolume(temp, out), reserve: AppSettings.offlineReserveBytes)
    }

    private static func describe(_ s: SpaceRule.Shortfall, estimate: Int64?) -> String {
        "Paused: \(Fmt.bytes(Int(s.free))) free on \(s.volume.rawValue); this download needs "
            + (estimate.map { "about \(Fmt.bytes(Int($0 * 2)))" } ?? "an unknown amount")
            + " while it's put together, and your reserve is \(Fmt.bytes(Int(AppSettings.offlineReserveBytes)))."
    }

    // MARK: running one job

    private func execute(_ job: Job) async {
        cancelRequested = false
        guard let video = try? await db.video(job.videoID) else {
            try? await db.removeQueued(job.id)
            return
        }
        // 4.0: not even started without room for it (the job stays queued; the queue pauses and says why)
        if job.action.downloadsMedia, let short = spaceShortfall(job) {
            pause(because: Self.describe(short, estimate: job.estimatedBytes))
            return
        }
        guard (try? await db.markRunning(job.id)) == true else { return }   // removed from the queue meanwhile
        current = QueueItem(id: job.id, videoID: video.id, title: video.displayTitle, action: job.action)
        // 4.0: the last check before a YouTube download: never one without a declaration and passed technical checks;
        // in the RC, never a video that isn't on its live-test list, nor an AI summary before you've approved them
        var refused = AppSettings.queueRefusal(job.action, key: video.key)
        if refused == nil, job.action.downloadsMedia { refused = await authorize(job, video) }
        if let refused {
            await refreshQueue()
            steps = [JobStep(id: 0, label: "Check the video", state: .failed)]
            await fail((video.id, job.id), job: job, title: "\(job.action.downloadsMedia ? "Not downloaded" : "Not run"): \(refused)", output: [refused],
                       retry: RetryInfo(action: job.action, videoID: video.id))
            current = nil
            await store.reload()
            return
        }
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

        // the test build's fake runner never summarizes (no AI) and never looks anything up (no network)
        if FakeRunner.enabled, kind == .summary {
            await fail(ids, job: job, title: "The test build's fake runner never runs summaries", output: [], retry: nil)
            return
        }
        // metadata runs alongside the download and never decides success
        let metadata = Task { FakeRunner.enabled ? nil : await MetadataFetcher.fetch(url) { self.metadataRun = $0 } }

        let command = kind == .summary
            ? [Paths.summarize, url]
            : [FakeRunner.script ?? Paths.cobaltDL, url, kind == .audio ? "audio" : "auto", outDir]
        var env = ["VS_FROM_APP": "1", "VS_OUT_DIR": outDir]
        if kind == .summary { env["VS_SUMMARY_PROMPT"] = Prompts.build(format, language) }
        // a prepared download keeps the quality it was queued with; others use the setting
        if kind == .video, let q = VideoQuality.usable(script: job.quality ?? AppSettings.videoQuality.scriptValue) { env["VS_VIDEO_QUALITY"] = q }

        // the reserve, watched while it downloads (a size can be unknown or wrong): below it, the download stops
        lowSpace = nil
        let interval: Duration = FakeRunner.enabled ? .milliseconds(300) : .seconds(5)
        let watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                if let v = SpaceRule.belowReserve(tempFree: DiskSpace.free(at: DiskSpace.temporaryFolder), finalFree: DiskSpace.free(at: outDir),
                                                  reserve: AppSettings.offlineReserveBytes) {
                    self.lowSpace = v
                    self.script?.cancel()
                    return
                }
            }
        }

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
        watch.cancel()
        lastOutput = Array(output.suffix(40))
        let info = await metadata.value
        // keep real metadata even when the job fails or is cancelled, so the entry isn't left untitled
        if let info { try? await db.applyInfo(video.id, info, override: true) }

        // low disk space: seen while downloading, or a failure (also while finishing: the merge or the move) that
        // leaves too little: back in the queue the first time, failed the second, and the queue pauses either way
        let outOfSpace = output.contains { $0.localizedCaseInsensitiveContains("no space left") }
        if !cancelRequested, lowSpace != nil || (status != 0 && (outOfSpace || spaceShortfall(job) != nil)) {
            await stoppedForSpace(ids, job: job, output: output, retry: retry)
            return
        }
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
            // the guard keeps stdin for its lifeline, so the transcript goes in and out through files.
            // 4.0: JSON out, so the job's log names the model, the cost and the tokens; an error (or the RC's cap) saves
            // nothing. In the RC one turn at most and a hard $1 limit per summary (the CLI's own budget check).
            let limits = AppSettings.isRC ? "--max-turns 1 --max-budget-usd 1.00 " : ""
            // the RC's paid test can pin an exact model ID (`rcAIModel`, e.g. the cheapest); everything else: the sonnet alias
            let pinned = AppSettings.isRC ? AppSettings.defaults.string(forKey: "rcAIModel") : nil
            let model = pinned.flatMap { $0.range(of: #"^claude-[a-z0-9-]+$"#, options: .regularExpression) != nil ? $0 : nil } ?? "sonnet"
            let command = #"claude -p --model "$4" --output-format json "# + limits + #""$1" < "$2" > "$3.json"; code=$?; jq -r '"AI: \(.modelUsage // {} | keys | join(", ")) · $\(.total_cost_usd) · \((.usage.input_tokens // 0) + (.usage.cache_creation_input_tokens // 0) + (.usage.cache_read_input_tokens // 0)) tokens in, \(.usage.output_tokens // 0) out\(if .is_error then " · error: \(.subtype // .result)" else "" end)"' "$3.json" 2> /dev/null; [[ $code == 0 ]] && jq -e '(.is_error | not) and ((.result // "") | length > 0)' "$3.json" > /dev/null && jq -r .result "$3.json" > "$3""#
            let run = try RunningScript(["/bin/bash", "-c", command, "regen", Prompts.build(format, language), input.path, resultFile.path, model])
            script = run
            status = await run.stream { output.append($0) }
            lastOutput = Array(output.suffix(40))
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

    /// Stopped for low disk space: counted; back in the queue the first time (paused, so it isn't tried again until you
    /// resume), failed the second time, so it can't loop.
    private func stoppedForSpace(_ ids: (video: Int64, job: Int64), job: Job, output: [String], retry: RetryInfo) async {
        let stops = (try? await db.lowSpaceStop(job.id)) ?? 2
        let temp = DiskSpace.free(at: DiskSpace.temporaryFolder), final = DiskSpace.free(at: AppSettings.downloadDir)
        let free = [final.map { "\(Fmt.bytes(Int($0))) free for downloads" }, temp.map { "\(Fmt.bytes(Int($0))) in the temporary folder" }]
            .compactMap { $0 }.joined(separator: ", ")
        let why = "Low disk space (\(free); your reserve is \(Fmt.bytes(Int(AppSettings.offlineReserveBytes))))."
        if stops >= 2 {
            await fail(ids, job: job, title: "Not enough space: stopped twice for low disk space", output: output.suffix(20) + [why], retry: retry)
        } else {
            markRunningStep(.failed)
            banner = .failure(title: "Paused: low disk space",
                              detail: why + " The download is back in the queue; free up space or lower your reserve, then resume.", retry: nil)
        }
        pause(because: "Paused: " + why)
        await refreshQueue()
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
            } else if line.hasPrefix("yt-dlp: "), !steps[0].label.contains("yt-dlp") {
                steps[0].label += " (yt-dlp)"      // 4.0 G1b: YouTube goes straight to yt-dlp
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

/// 4.0 Phase 4: whether a download may start without eating into your reserve, on every volume it uses: about 2× its
/// estimate where it's put together (yt-dlp downloads video and audio separately and merges them; audio is converted
/// to MP3), 1× where it's kept. An unknown size counts as nothing here, so for it the reserve is best effort: the
/// runner keeps checking while it downloads.
enum SpaceRule {
    enum Volume: String { case temporary = "the disk with the temporary folder", downloads = "your downloads folder's disk" }
    struct Shortfall: Equatable { let volume: Volume; let free: Int64; let needed: Int64 }

    static func check(estimate: Int64?, tempFree: Int64?, finalFree: Int64?, sameVolume: Bool, reserve: Int64) -> Shortfall? {
        let e = max(estimate ?? 0, 0)
        if sameVolume {
            if let f = finalFree, f < reserve + 2 * e { return Shortfall(volume: .downloads, free: f, needed: reserve + 2 * e) }
            return nil
        }
        if let t = tempFree, t < reserve + 2 * e { return Shortfall(volume: .temporary, free: t, needed: reserve + 2 * e) }
        if let f = finalFree, f < reserve + e { return Shortfall(volume: .downloads, free: f, needed: reserve + e) }
        return nil
    }

    /// While downloading: a volume below the reserve stops the download.
    static func belowReserve(tempFree: Int64?, finalFree: Int64?, reserve: Int64) -> Volume? {
        if let f = finalFree, f < reserve { return .downloads }
        if let t = tempFree, t < reserve { return .temporary }
        return nil
    }
}

/// 4.0 Phase 4, test builds only: a stand-in for the download script (app/tests/fake-dl.sh) that never uses the
/// network, so the queue can be checked from start to finish. Only the separate test build ("Video Buddy 4.0 Test"),
/// with a throwaway data folder, and only when asked: never the Preview or a real build.
enum FakeRunner {
    static let testBundleID = "local.video-summarizer.preview-test"

    static func allowed(bundleID: String?, env: [String: String]) -> Bool {
        bundleID == testBundleID && env["VS_DATA_DIR"]?.nilIfBlank != nil && env["VS_TEST_FAKE_DOWNLOADS"]?.nilIfBlank != nil
    }

    static let enabled = allowed(bundleID: Bundle.main.bundleIdentifier, env: ProcessInfo.processInfo.environment)
    static var script: String? { enabled ? ProcessInfo.processInfo.environment["VS_TEST_FAKE_DOWNLOADS"] : nil }

    /// Test runs say how much space there is in files they can change while a job runs (bytes, one number).
    static func freeSpace(at path: String) -> Int64? {
        guard enabled else { return nil }
        let env = ProcessInfo.processInfo.environment
        let file = path.hasPrefix(DiskSpace.temporaryFolder) ? env["VS_TEST_FREE_TEMP_FILE"] : env["VS_TEST_FREE_FINAL_FILE"]
        return file.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }.flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// The technical check, from the test's control file ("<id> blocked|unknown|nosize|approx|720max"); otherwise it
    /// passes, with known sizes (a 10-minute video: 480p 60 MB, 720p 120 MB, 1080p 250 MB, audio 9 MB).
    static func check(_ id: String) -> CheckAnswer {
        let lines = (ProcessInfo.processInfo.environment["VS_FAKE_CONTROL"]).flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        let says = lines.split(separator: "\n").last { $0.hasPrefix(id + " ") }.map { $0.split(separator: " ").dropFirst().joined(separator: " ") } ?? ""
        let mb: Int64 = 1_000_000
        var formats = [(480, 60 * mb), (720, 120 * mb), (1080, 250 * mb)].map {
            MediaFacts.Format(height: $0.0, vcodec: "avc1.4d401f", acodec: "none", filesize: $0.1, tbr: Double($0.1 * 8) / 600_000)
        } + [MediaFacts.Format(vcodec: "none", acodec: "mp4a.40.2", filesize: 9 * mb, tbr: 128)]
        switch says {
        case "blocked": return CheckAnswer(check: .blocked("Members-only content. (test)"))
        case "unknown": return CheckAnswer(check: .unknown("The check didn't finish. (test)"))
        case "nosize": formats = formats.map { var f = $0; f.filesize = nil; f.tbr = nil; return f }
        case "approx": formats = formats.map { var f = $0; f.filesizeApprox = f.filesize; f.filesize = nil; return f }
        case "720max": formats = formats.filter { ($0.height ?? 0) <= 720 }
        default: break
        }
        return CheckAnswer(check: .passed(channelID: "UCtest", handle: "@test", channel: "Test channel"),
                           facts: MediaFacts(duration: says == "nosize" ? nil : 600, formats: formats))
    }
}
