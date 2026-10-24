// 4.0 Phase 1b: what Video Buddy has for the browser's current video, whether a download may be requested, and what
// the action bar shows. All pure (and self-tested), except the checker at the end, which only runs a metadata lookup.
import Foundation

/// A declaration you recorded for one video. Video Buddy can't verify download rights, so it never calls this
/// "authorized": it's what you declared, labelled as such.
struct DownloadAuthorization: Equatable {
    enum Basis: String { case ownChannel = "own_channel", writtenPermission = "written_permission" }
    let basis: Basis
    let reference: String?
    let recorded: Date

    var label: String {
        switch basis {
        case .ownChannel: "Own channel — declared, not independently verified"
        case .writtenPermission: "Permission declared — not independently verified"
        }
    }
}

/// The technical restrictions yt-dlp's metadata reveals. It can say a video is live, members-only or protected; it can
/// never say you may download it.
enum PlatformCheck: Equatable {
    case passed(channelID: String?, handle: String?, channel: String?)   // no technical restriction found
    case blocked(String)                                                 // a restriction, with the reason
    case unknown(String)                                                 // couldn't tell: never queue on this

    /// From `yt-dlp -j` (exit status, its JSON, and its last ERROR line).
    static func from(status: Int32, json: Data?, error: String?) -> PlatformCheck {
        struct Raw: Decodable {
            struct Format: Decodable { let has_drm: Bool? }
            let availability: String?
            let live_status: String?
            let is_live: Bool?
            let age_limit: Int?
            let channel_id: String?
            let uploader_id: String?
            let channel: String?
            let formats: [Format]?
        }
        guard status == 0, let json else { return fromError(error) }
        guard let r = try? JSONDecoder().decode(Raw.self, from: json) else { return .unknown("The video's details couldn't be read.") }
        switch r.live_status {
        case "is_live"?: return .blocked("This is a live stream. Video Buddy only saves finished videos.")
        case "is_upcoming"?: return .blocked("This is an upcoming premiere or stream that hasn't started.")
        default: break
        }
        if r.is_live == true { return .blocked("This is a live stream. Video Buddy only saves finished videos.") }
        switch r.availability {
        case "premium_only"?: return .blocked("YouTube Premium content: only YouTube's own apps can keep it offline.")
        case "subscriber_only"?: return .blocked("Members-only content.")
        case "needs_auth"?, "private"?: return .blocked("This video needs a signed-in account; Video Buddy never uses your browser sign-in for downloads.")
        case "public"?, "unlisted"?: break
        default: return .unknown("YouTube didn't say whether this video is public.")
        }
        if (r.age_limit ?? 0) >= 18 { return .blocked("Age-restricted: it needs a signed-in account.") }
        if r.formats?.contains(where: { $0.has_drm == true }) == true { return .blocked("This video is DRM-protected.") }
        if r.live_status == nil || r.formats == nil { return .unknown("The video's details were incomplete.") }
        return .passed(channelID: r.channel_id, handle: r.uploader_id, channel: r.channel)
    }

    private static func fromError(_ line: String?) -> PlatformCheck {
        let e = (line ?? "").lowercased()
        if e.contains("confirm your age") { return .blocked("Age-restricted: it needs a signed-in account.") }
        if e.contains("members") || e.contains("join this channel") { return .blocked("Members-only content.") }
        if e.contains("private video") { return .blocked("This is a private video.") }
        if e.contains("premiere") || e.contains("live event will begin") { return .blocked("This premiere or stream hasn't started.") }
        if e.contains("not available") || e.contains("unavailable") { return .blocked("YouTube says this video isn't available.") }
        return .unknown(line.map { "The check failed: \($0)" } ?? "The check didn't finish.")
    }
}

/// What the library has for one video, from real files and the queue. Several things can be true at once.
struct VideoAvailability: Equatable {
    enum Job: Equatable { case none, queued, running, failed }
    var inLibrary = false
    var videoFile: String?          // a video file that exists, isn't empty and plays here
    var audioFile: String?
    var videoMissing = false        // a video file was saved but none is on disk now
    var audioMissing = false
    var video = Job.none, audio = Job.none, summary = Job.none
    var summarized = false

    /// `usable` is the file check (exists and isn't empty); tests pass their own.
    static func make(inLibrary: Bool, files: [FileItem], usable: (FileItem) -> Bool, queue: [QueueItem], current: QueueItem?,
                     failed: [FailedItem], hasSummary: Bool) -> VideoAvailability {
        var a = VideoAvailability(inLibrary: inLibrary, summarized: hasSummary)
        let media = files.filter(\.isMedia)
        let video = media.filter { $0.role == .video }, audio = media.filter { $0.role == .audio }
        a.videoFile = video.first { $0.isPlayable && usable($0) }?.path
        a.audioFile = audio.first { $0.isPlayable && usable($0) }?.path
        a.videoMissing = a.videoFile == nil && !video.isEmpty && !video.contains(where: usable)
        a.audioMissing = a.audioFile == nil && !audio.isEmpty && !audio.contains(where: usable)
        func state(_ kind: JobKind) -> Job {
            if current?.action.kind == kind { return .running }
            if queue.contains(where: { $0.action.kind == kind }) { return .queued }
            if failed.contains(where: { $0.job.kind == kind }) { return .failed }
            return .none
        }
        (a.video, a.audio, a.summary) = (state(.video), state(.audio), state(.summary))
        return a
    }
}

/// Whether a download (or a summary, which saves the audio) may be requested: technical checks passed **and** a
/// declaration on record. Nil while the check is still running.
enum DownloadGate {
    enum Decision: Equatable {
        case allowed(DownloadAuthorization)
        case needsDeclaration
        case blocked(String)
        case unknown(String)
    }

    static func decide(check: PlatformCheck?, authorization: DownloadAuthorization?) -> Decision? {
        switch check {
        case nil: return nil
        case let .blocked(reason)?: return .blocked(reason)
        case let .unknown(reason)?: return .unknown(reason)
        case .passed?: return authorization.map { .allowed($0) } ?? .needsDeclaration
        }
    }

    /// "Own channel" can only be declared when the video's channel is one you entered (a consistency check, not proof).
    static func channelMatches(_ check: PlatformCheck?, ownChannels: [String]) -> Bool {
        guard case let .passed(id, handle, _)? = check else { return false }
        let mine = Set(ownChannels.map { $0.lowercased() })
        return [id, handle].compactMap { $0?.lowercased() }.contains { mine.contains($0) || mine.contains("@" + $0) }
    }
}

/// 4.0 Phase 4: what yt-dlp's metadata says about a video's formats and length (nothing downloaded), for size estimates.
struct MediaFacts: Equatable {
    struct Format: Equatable {
        var height: Int?
        var vcodec: String?
        var acodec: String?
        var filesize: Int64?
        var filesizeApprox: Int64?
        var tbr: Double?           // kbit/s
        var hasVideo: Bool { (vcodec ?? "none") != "none" && height != nil }
        var hasAudio: Bool { (acodec ?? "none") != "none" }
    }
    var duration: Double?
    var formats: [Format]
    /// The highest resolution it comes in.
    var maxHeight: Int? { formats.filter(\.hasVideo).compactMap(\.height).max() }

    static func from(json: Data?) -> MediaFacts? {
        struct Raw: Decodable {
            struct F: Decodable {
                let height: Int?, vcodec: String?, acodec: String?, filesize: Int64?, filesize_approx: Int64?, tbr: Double?
            }
            let duration: Double?
            let formats: [F]?
        }
        guard let json, let r = try? JSONDecoder().decode(Raw.self, from: json) else { return nil }
        return MediaFacts(duration: r.duration, formats: (r.formats ?? []).map {
            Format(height: $0.height, vcodec: $0.vcodec, acodec: $0.acodec, filesize: $0.filesize, filesizeApprox: $0.filesize_approx, tbr: $0.tbr)
        })
    }
}

/// A check's answer: the technical restrictions, and what it says about sizes (when it could read them).
struct CheckAnswer: Equatable {
    var check: PlatformCheck
    var facts: MediaFacts?
}

/// 4.0 Phase 4: how big a download will be, and how sure that is. Pure (self-tested).
enum SizeEstimate {
    static func text(_ bytes: Int64?, _ kind: SizeKind) -> String {
        switch (bytes, kind) {
        case let (b?, .known): Fmt.bytes(Int(b))
        case let (b?, _): "≈ " + Fmt.bytes(Int(b))
        default: "size unknown"
        }
    }

    /// A format's size: given (known), YouTube's approximation, or bitrate × length (approximate).
    static func size(_ f: MediaFacts.Format, duration: Double?) -> (Int64?, SizeKind) {
        if let b = f.filesize { return (b, .known) }
        if let b = f.filesizeApprox { return (b, .approximate) }
        if let t = f.tbr, let d = duration { return (Int64(t * 1000 / 8 * d), .approximate) }
        return (nil, .unknown)
    }

    /// The least sure of two sizes, added together.
    static func sum(_ a: (Int64?, SizeKind), _ b: (Int64?, SizeKind)) -> (Int64?, SizeKind) {
        guard let x = a.0, let y = b.0 else { return (nil, .unknown) }
        return (x + y, a.1 == .known && b.1 == .known ? .known : .approximate)
    }

    /// Video at `quality` ("480"…"1080", "max", nil = 1080): the best video at or below it, H.264 first (as the
    /// download script asks for), plus the best audio unless the format already has it.
    /// At that height, a stream with a known size comes first, then an approximate one, then the highest bitrate: what
    /// yt-dlp actually picks. (4.0 G1a: a video had a 720p H.264 HLS stream with no size at 1,154 kbit/s beside the DASH
    /// one yt-dlp downloads, 17.9 MB at 238 kbit/s; going by bitrate estimated ≈ 97 MB for a 27.7 MB download.)
    static func video(_ f: MediaFacts, quality: String?) -> (bytes: Int64?, kind: SizeKind, height: Int?) {
        let cap = quality == "max" ? Int.max : Int(quality ?? "") ?? 1080
        let fit = f.formats.filter { $0.hasVideo && ($0.height ?? 0) <= cap }
        let h264 = fit.filter { ($0.vcodec ?? "").hasPrefix("avc1") }
        let pool = h264.isEmpty ? fit : h264
        let sized = { (x: MediaFacts.Format) in x.filesize != nil ? 2 : x.filesizeApprox != nil ? 1 : 0 }
        guard let best = pool.max(by: { (($0.height ?? 0), sized($0), $0.tbr ?? 0) < (($1.height ?? 0), sized($1), $1.tbr ?? 0) })
        else { return (nil, .unknown, nil) }
        var total = size(best, duration: f.duration)
        if !best.hasAudio {
            let audio = f.formats.filter { $0.hasAudio && !$0.hasVideo }.max { ($0.tbr ?? 0) < ($1.tbr ?? 0) }
            total = audio.map { sum(total, size($0, duration: f.duration)) } ?? (nil, .unknown)
        }
        return (total.0, total.1, best.height)
    }

    /// The MP3 bitrate both download paths use (cobalt's audioBitrate, yt-dlp's --audio-quality 128K in cobalt-dl.sh).
    static let mp3Bitrate = 128_000.0

    /// Audio as MP3 (the script converts it at a fixed 128 kbit/s): length × 128 kbit/s; tags and padding add a little.
    static func audio(_ f: MediaFacts) -> (bytes: Int64?, kind: SizeKind) {
        guard let d = f.duration, d > 0 else { return (nil, .unknown) }
        return (Int64(d * mp3Bitrate / 8), .approximate)
    }
}

/// 4.0 Phase 4: what a selection of downloads adds up to, and whether it fits while keeping your reserve. One job runs
/// at a time, so the most room is needed while the last one is put together: everything before it, plus twice it.
struct PrepareTotals: Equatable {
    var bytes: Int64 = 0            // known and approximate sizes together
    var approximate = false
    var unknown = 0                 // how many have no size at all
    var largest: Int64 = 0

    init(_ rows: [(bytes: Int64?, kind: SizeKind)]) {
        for r in rows {
            guard let b = r.bytes else { unknown += 1; continue }
            bytes += b
            largest = max(largest, b)
            if r.kind != .known { approximate = true }
        }
    }

    /// Why it doesn't fit, or nil. Unknown sizes count as nothing here: for them the reserve is best effort.
    func shortfall(tempFree: Int64?, finalFree: Int64?, sameVolume: Bool, reserve: Int64) -> String? {
        if sameVolume {
            guard let f = finalFree, f - reserve < bytes + largest else { return nil }
            return "needs about \(Fmt.bytes(Int(bytes + largest))) with room to put the largest together; \(Fmt.bytes(Int(max(f - reserve, 0)))) is free above your reserve"
        }
        if let f = finalFree, f - reserve < bytes {
            return "needs about \(Fmt.bytes(Int(bytes))) on the downloads disk; \(Fmt.bytes(Int(max(f - reserve, 0)))) is free above your reserve"
        }
        if let t = tempFree, t - reserve < 2 * largest {
            return "the temporary folder's disk needs about \(Fmt.bytes(Int(2 * largest))) to put the largest together"
        }
        return nil
    }
}

/// What you have for a video and what's under way, in words: the action bar and Watch Later show the same ones.
struct StatusLabel: Equatable {
    enum Tone { case good, accent, warning, neutral }
    let text: String
    let icon: String
    let tone: Tone
}

extension VideoAvailability {
    /// `nothing`: what to say when there's nothing (the bar says whether it's in the library).
    func labels(nothing: String? = nil) -> [StatusLabel] {
        var c: [StatusLabel] = []
        if videoFile != nil { c.append(StatusLabel(text: "Video available offline", icon: "checkmark.circle.fill", tone: .good)) }
        if audioFile != nil { c.append(StatusLabel(text: "Audio available offline", icon: "headphones", tone: .good)) }
        if summarized { c.append(StatusLabel(text: "Summary ready", icon: "sparkles", tone: .accent)) }
        for (job, what) in [(video, "video"), (audio, "audio"), (summary, "summary")] {
            switch job {
            case .running: c.append(StatusLabel(text: what == "summary" ? "Summarizing" : "Downloading \(what)", icon: "arrow.down.circle", tone: .accent))
            case .queued: c.append(StatusLabel(text: "\(what.capitalized) queued", icon: "clock", tone: .accent))
            case .failed: c.append(StatusLabel(text: "\(what.capitalized) failed", icon: "exclamationmark.triangle.fill", tone: .warning))
            case .none: break
            }
        }
        if videoMissing { c.append(StatusLabel(text: "Video file missing", icon: "questionmark.folder", tone: .warning)) }
        if audioMissing { c.append(StatusLabel(text: "Audio file missing", icon: "questionmark.folder", tone: .warning)) }
        if c.isEmpty { c.append(StatusLabel(text: nothing ?? (inLibrary ? "Not downloaded" : "Not in your library"), icon: "circle.dashed", tone: .neutral)) }
        return c
    }
}

/// What one slot of the action bar shows (Video, Audio or Summarize).
enum SlotState: Equatable {
    case offline                    // the file is here (Summarize: the summary exists)
    case running, queued
    case checking
    case unavailable(String)
    case unknown(String)
    case authorizationRequired
    case retry                      // the last attempt failed
    case downloadAgain              // it was saved, but the file is gone
    case ready

    /// One order for every slot: what you have, then what's under way, then what the checks say, then what to do.
    static func make(have: Bool, job: VideoAvailability.Job, missing: Bool, gate: DownloadGate.Decision?) -> SlotState {
        if have { return .offline }
        if job == .running { return .running }
        if job == .queued { return .queued }
        switch gate {
        case nil: return .checking
        case let .blocked(r)?: return .unavailable(r)
        case let .unknown(r)?: return .unknown(r)
        case .needsDeclaration?: return .authorizationRequired
        case .allowed?: return job == .failed ? .retry : missing ? .downloadAgain : .ready
        }
    }

    static func video(_ a: VideoAvailability, _ g: DownloadGate.Decision?) -> SlotState {
        make(have: a.videoFile != nil, job: a.video, missing: a.videoMissing, gate: g)
    }
    static func audio(_ a: VideoAvailability, _ g: DownloadGate.Decision?) -> SlotState {
        make(have: a.audioFile != nil, job: a.audio, missing: a.audioMissing, gate: g)
    }
    static func summary(_ a: VideoAvailability, _ g: DownloadGate.Decision?) -> SlotState {
        make(have: a.summarized, job: a.summary, missing: false, gate: g)
    }
}

/// What a click on a bar button does. The button carries the video id it showed; if the tab has moved on to another
/// video since, nothing happens (never the wrong video).
enum BrowserActionOutcome: Equatable {
    case queue(videoID: String)
    case pageChanged
    case declare(videoID: String)
    case explain(String)
    case alreadyHave
    case alreadyQueued

    static func decide(clicked: String, current: String?, slot: SlotState, anotherCopy: Bool = false) -> BrowserActionOutcome {
        guard clicked == current else { return .pageChanged }
        switch slot {
        case .ready, .retry, .downloadAgain: return .queue(videoID: clicked)
        case .offline: return anotherCopy ? .queue(videoID: clicked) : .alreadyHave
        case .queued, .running: return .alreadyQueued
        case .authorizationRequired: return .declare(videoID: clicked)
        case .checking: return .explain("Still checking this video. Try again in a moment.")
        case let .unavailable(r), let .unknown(r): return .explain(r)
        }
    }
}

/// Runs the metadata check for the video on screen, after the address settles, one at a time. Results are stored under
/// the id they belong to, so a late answer for an earlier video can never show up as the current one's.
@MainActor @Observable
final class AvailabilityChecker {
    private(set) var results: [String: PlatformCheck] = [:]
    /// When each result was looked up (the last check before a download looks again when it's old).
    @ObservationIgnored private var checkedAt: [String: Date] = [:]
    private(set) var current: String?
    private(set) var running: String?
    /// 4.0 Phase 4: what each check said about sizes (Prepare for Offline's estimates).
    private(set) var facts: [String: MediaFacts] = [:]
    /// The video Prepare for Offline is checking now (one at a time).
    private(set) var batchRunning: String?
    @ObservationIgnored var fetch: (String) async -> CheckAnswer
    @ObservationIgnored var settle: Duration = .milliseconds(800)
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var batch: Task<Void, Never>?
    @ObservationIgnored private var batchIDs: [String] = []

    init(fetch: @escaping (String) async -> CheckAnswer) { self.fetch = fetch }

    private func store(_ id: String, _ a: CheckAnswer) {
        results[id] = a.check
        if let f = a.facts { facts[id] = f }
        checkedAt[id] = Date()
    }

    /// 4.0 Phase 4: checks several videos one after another (Prepare for Offline), each result under its own id as it
    /// arrives; ones already checked (with sizes) within `maxAge` are skipped. A new batch, or cancelBatch, stops it.
    func checkAll(_ ids: [String], maxAge: TimeInterval = 30 * 60) {
        batchIDs = ids
        batch?.cancel()
        batch = Task { [weak self] in
            for id in ids {
                guard let self, !Task.isCancelled else { return }
                if self.results[id] != nil, self.facts[id] != nil, let at = self.checkedAt[id], Date().timeIntervalSince(at) < maxAge { continue }
                self.batchRunning = id
                let answer = await self.fetch(id)
                guard !Task.isCancelled else { return }
                self.store(id, answer)
            }
            self?.batchRunning = nil
        }
    }

    /// Check Again for some rows: they're looked up afresh, and the rest of the batch carries on.
    func recheckAll(_ ids: [String]) {
        for id in ids { results[id] = nil; facts[id] = nil; checkedAt[id] = nil }
        checkAll(batchIDs.isEmpty ? ids : batchIDs)
    }

    func cancelBatch() {
        batch?.cancel()
        batch = nil
        batchRunning = nil
    }

    /// The tab shows `id` now (nil: not a video). `needed` is false when nothing would be downloaded anyway.
    func show(_ id: String?, needed: Bool) {
        // same video, and its check is running, done, or not needed: nothing to do
        if id == current, task != nil || !needed || id.map({ results[$0] != nil }) ?? true { return }
        current = id
        task?.cancel()
        task = nil
        running = nil
        guard let id, needed, results[id] == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.settle)
            guard !Task.isCancelled else { return }
            self.running = id
            let result = await self.fetch(id)
            guard !Task.isCancelled else { return }
            self.store(id, result)           // under its own id, whatever is on screen by now
            if self.running == id { self.running = nil }
            if self.current == id { self.task = nil }
        }
    }

    /// A result no older than `maxAge`, looked up again if needed (the last check before a download runs).
    func fresh(_ id: String, maxAge: TimeInterval) async -> PlatformCheck {
        if let r = results[id], let at = checkedAt[id], Date().timeIntervalSince(at) < maxAge { return r }
        let r = await fetch(id)
        store(id, r)
        return r.check
    }

    func recheck(_ id: String) {
        results[id] = nil
        let shown = current
        current = nil
        show(shown ?? id, needed: true)
    }
}
