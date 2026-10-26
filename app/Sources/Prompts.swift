// Summary prompt options and app settings. Standard + English is exactly the prompt summarize.sh uses by default.
import Foundation
import SwiftUI
import VideoToolbox

enum SummaryFormat: String, CaseIterable, Identifiable {
    case standard = "Standard", brief = "Brief", detailed = "Detailed", bullets = "Bullets", adhd = "ADHD-Friendly"
    var id: String { rawValue }

    var detail: String {
        switch self {
        case .standard: "3-sentence TL;DR, key points, actionable takeaways."
        case .brief: "One short paragraph."
        case .detailed: "Overview, a section per topic, useful details, takeaways."
        case .bullets: "Just the key points as a bulleted list."
        case .adhd: "Simple headings, short single-idea bullets, key takeaways, no filler."
        }
    }

    var instruction: String {
        switch self {
        case .standard: Prompts.standard
        case .brief: "Summarize this video transcript in one short paragraph of at most 4 sentences."
        case .detailed: "Summarize this video transcript in detail. Start with a short overview paragraph, then one Markdown section per main topic with bullet points, then a section of useful details (names, numbers, tools and resources mentioned), then actionable takeaways."
        case .bullets: "Summarize this video transcript as a concise bulleted list of its key points only."
        case .adhd: "Summarize this video transcript in an ADHD-friendly way. Use short, simple Markdown headings. Under each heading give 2 to 4 short bullet points, one idea per bullet and at most about 12 words each. End with a section titled \"⭐ Key takeaways\" listing the 3 most important points. Skip filler, tangents and unnecessary detail."
        }
    }
}

enum SummaryLanguage: String, CaseIterable, Identifiable {
    case english = "English", sameAsVideo = "Same as video", masri = "Egyptian Arabic (Masri)", arabic = "Arabic (MSA)",
         french = "French", spanish = "Spanish", german = "German"
    var id: String { rawValue }

    /// nil for English, so Standard + English stays identical to the Raycast prompt
    var instruction: String? {
        switch self {
        case .english: nil
        case .sameAsVideo: "Write the summary in the same language as the transcript."
        case .masri: "Write the entire summary in Egyptian Arabic (Masri): the colloquial Egyptian dialect as spoken in Cairo, in Arabic script, not Modern Standard Arabic. Keep names and technical terms in their original form when that is clearer."
        case .arabic: "Write the summary in Modern Standard Arabic."
        case .french, .spanish, .german: "Write the summary in \(rawValue)."
        }
    }
}

enum Prompts {
    static let standard = "Summarize this video transcript. Start with a 3-sentence TL;DR, then the key points as bullets, then any actionable takeaways."

    static func build(_ format: SummaryFormat, _ language: SummaryLanguage) -> String {
        [format.instruction, language.instruction].compactMap { $0 }.joined(separator: " ")
    }
}

/// Video downloads from the app. "1080p (default)" sends nothing, so the scripts behave exactly as they always have.
enum VideoQuality: String, CaseIterable, Identifiable {
    case p480 = "480p (smallest)", p720 = "720p (smaller)", standard = "1080p (default)", best = "Best available",
         highest = "Highest available"
    var id: String { rawValue }
    /// What Settings and the app show. "Best available" is stored as before (3.1's setting), and shown as what it is: the
    /// highest H.264, which plays everywhere (1080p on YouTube). 4.0 G2: "Highest available" is the separate, higher choice.
    var label: String {
        switch self {
        case .best: "Best compatible (H.264)"
        case .highest: "Highest available (up to 4K, AV1)"
        default: rawValue
        }
    }
    var scriptValue: String? {
        switch self {
        case .p480: "480"
        case .p720: "720"
        case .standard: nil
        case .best: "max"
        case .highest: "highest"
        }
    }

    /// 4.0 G2: whether this Mac decodes AV1 in hardware, asked at run time (not assumed from the chip). YouTube's streams
    /// above 1080p are AV1 or VP9; AV1 plays in AVFoundation where it's decoded in hardware, VP9 isn't reliable there.
    static let av1Decodes = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    static let noAV1 = "Highest available needs AV1 decoding in hardware, which this Mac doesn't have"
    /// What a download uses: Highest available only where AV1 decodes in hardware, otherwise Best compatible (H.264),
    /// which is always available.
    func usable(av1: Bool = av1Decodes) -> VideoQuality { self == .highest && !av1 ? .best : self }
    /// A stored script value made usable on this Mac ("highest" → "max" without AV1 decoding).
    static func usable(script q: String?, av1: Bool = av1Decodes) -> String? { q == "highest" && !av1 ? "max" : q }
}

enum Appearance: String, CaseIterable, Identifiable {
    case dark = "Dark", system = "System", light = "Light"
    var id: String { rawValue }
    var scheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .system: nil
        case .light: .light
        }
    }
}

/// Settings live in UserDefaults (they're preferences, not history). Keys match the @AppStorage names in SettingsView.
enum AppSettings {
    static var defaults: UserDefaults { .standard }
    static var language: SummaryLanguage { SummaryLanguage(rawValue: defaults.string(forKey: "summaryLanguage") ?? "") ?? .english }
    static var format: SummaryFormat { SummaryFormat(rawValue: defaults.string(forKey: "summaryFormat") ?? "") ?? .standard }
    static var downloadDir: String { defaults.string(forKey: "downloadDir")?.nilIfBlank ?? defaultDownloadDir }
    static var retentionDays: Int { defaults.integer(forKey: "retentionDays") }
    static var videoQuality: VideoQuality { (VideoQuality(rawValue: defaults.string(forKey: "videoQuality") ?? "") ?? .standard).usable() }
    /// 4.0 Phase 4: free space to keep on the download volumes (best effort for downloads of unknown size).
    static var offlineReserveBytes: Int64 { Int64(defaults.object(forKey: "offlineReserveGB") as? Int ?? 10) * 1_000_000_000 }
    /// 4.0 Phase 4: downloads only on Wi-Fi or Ethernet that macOS doesn't mark as expensive or Low Data Mode.
    static var downloadsUnmeteredOnly: Bool { defaults.bool(forKey: "downloadsUnmeteredOnly") }
    /// the "+ Transcript" checkbox: Audio and Video downloads also get an on-device transcript
    static var transcribeDownloads: Bool { defaults.bool(forKey: "transcribeDownloads") }
    /// the preview and the release candidate keep their downloads inside their own data folders, away from 3.1's (and out
    /// of ~/Downloads, which macOS guards with a permission prompt and which may sync to a cloud drive)
    static var defaultDownloadDir: String { isolated ? dataDir.appendingPathComponent("Downloads").path : home + "/Downloads/cobalt" }
    /// Video Buddy 4.0 Preview.app (app/tools/preview.sh sets VBPreview): its own data folder, downloads and AI jobs locked off.
    static let isPreview = Bundle.main.object(forInfoDictionaryKey: "VBPreview") as? Bool == true
    /// 4.0 Phase 5: Video Buddy 4.0 RC.app (preview.sh --rc sets VBReleaseCandidate): its own folders like the Preview,
    /// real downloads only once you've approved the live tests (rcLiveDownloads), AI summaries only once you've approved
    /// those (rcAISummaries), and only the videos on its live-test list. Both settings are off when it's installed.
    static let isRC = Bundle.main.object(forInfoDictionaryKey: "VBReleaseCandidate") as? Bool == true
    /// Its own data folder, downloads, settings and YouTube data: never 3.1's.
    static var isolated: Bool { isPreview || isRC }
    /// An isolated build's data folder is named after the app, so the test build ("Video Buddy 4.0 Test") has its own too.
    static let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Video Buddy"

    /// VS_DATA_DIR lets tests use a throwaway history without touching the real one.
    static var dataDir: URL {
        if let dir = ProcessInfo.processInfo.environment["VS_DATA_DIR"]?.nilIfBlank { return URL(fileURLWithPath: dir) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(isolated ? appName : "Video Summarizer")
    }

    /// The sidebar's line under the name in an isolated build: which build it is and what's locked.
    static var buildBadge: String? {
        if isPreview { return "4.0 Preview · downloads off" }
        guard isRC else { return nil }
        return "4.0 RC · " + (downloadsLockReason == nil ? "live downloads on until \(LiveGrant.until?.formatted(date: .omitted, time: .shortened) ?? "?")" : "downloads locked")
            + (defaults.bool(forKey: "rcAISummaries") ? " · AI on" : " · AI locked")
    }

    /// Why this build may not run any job at all (the Preview), or nil (then only the Pause button stops the queue).
    static var jobsLockReason: String? { isPreview ? "\(appName) never downloads or runs AI jobs" : nil }

    /// 4.0 G2: why downloads wait in this build, or nil. The RC downloads only inside a live-download window you approved.
    /// Its AI lock is separate (queueRefusal), and on-device transcripts of files already here need neither.
    static var downloadsLockReason: String? { isRC && !LiveGrant.active() ? "live downloads aren't approved in \(appName) right now" : nil }

    /// 4.0: AI summaries are paid per request (billed to your Claude account), so they're off until you allow them:
    /// Settings → Summaries → Allow AI summaries (`aiSummariesApproved`), and in the RC its own `rcAISummaries`.
    static var aiApproved: Bool { defaults.bool(forKey: isRC ? "rcAISummaries" : "aiSummariesApproved") }
    /// Where ai-summary.sh records each request: an isolated build's own data folder; nil = its default
    /// (~/Library/Logs/Video Buddy/ai-usage.log, shared with Raycast).
    static var aiLog: String? { isolated ? dataDir.appendingPathComponent("ai-usage.log").path : nil }

    /// Why this job may not be queued in this build, or nil. In every build an AI summary until you've allowed them;
    /// in the RC also YouTube downloads of videos that aren't on its live-test list. The database asks this before
    /// every queued job, and the runner again before one runs.
    static func queueRefusal(_ action: JobAction, key: String) -> String? {
        if action.usesAI, !aiApproved, !isRC { return "AI summaries are off (Settings → Summaries → Allow AI summaries)" }
        guard isRC else { return nil }
        return LiveTestList.refusal(action, key: key, aiApproved: defaults.bool(forKey: "rcAISummaries"),
                                    listed: LiveTestList.ids(in: dataDir), app: appName)
    }
}

/// 4.0 G1a: the RC's live downloads come only in a window you approved: `rcLiveDownloads` plus `rcLiveGrantUntil` (written
/// by app/tools/rc-live-window.sh, at most 90 minutes ahead), good for one launch. The launch after that (a restart,
/// expected or not), an expired window or no window at all locks downloads again and pauses the queue.
enum LiveGrant {
    static let enabledKey = "rcLiveDownloads", untilKey = "rcLiveGrantUntil", claimedKey = "rcLiveGrantClaimed"
    /// This launch claimed the window (set once, at launch, by `claimAtLaunch`; never by a self-test).
    nonisolated(unsafe) private(set) static var claimedByThisLaunch = false

    static var until: Date? {
        // whole seconds (`defaults write -int`): a float setting loses up to a minute at today's timestamps
        (AppSettings.defaults.object(forKey: untilKey) as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    /// At launch: claim the window if there's one nobody has used; otherwise make sure everything is locked.
    /// Returns whether this launch may download.
    @discardableResult static func claimAtLaunch(now: Date = Date()) -> Bool {
        let d = AppSettings.defaults
        let outcome = claim(enabled: d.bool(forKey: enabledKey), until: until, claimed: d.bool(forKey: claimedKey), now: now)
        if outcome.claim { d.set(true, forKey: claimedKey); claimedByThisLaunch = true }
        if outcome.relock { relock() }
        return outcome.claim
    }

    static func claim(enabled: Bool, until: Date?, claimed: Bool, now: Date) -> (claim: Bool, relock: Bool) {
        guard enabled else { return (false, false) }
        guard let until, until > now, until.timeIntervalSince(now) <= 90 * 60 + 60, !claimed else { return (false, true) }
        return (true, false)
    }

    /// Live downloads allowed right now: this launch's window, not yet over.
    static func active(now: Date = Date()) -> Bool {
        claimedByThisLaunch && AppSettings.defaults.bool(forKey: enabledKey) && (until.map { $0 > now } ?? false)
    }

    /// Everything off: no live downloads, the queue paused, the window gone.
    static func relock() {
        let d = AppSettings.defaults
        d.set(false, forKey: enabledKey)
        d.set(true, forKey: "queuePaused")
        d.removeObject(forKey: untilKey)
        d.removeObject(forKey: claimedKey)
    }
}

/// 4.0 Phase 5: the RC's live-test list, live-test-videos.txt in its data folder: what you approved for the live tests,
/// one per line, as a YouTube video ID or a full link (any site); anything after # is a note. Written by hand, never by
/// the app. In the RC, every download of anything not on it is refused, whichever site it's from.
enum LiveTestList {
    static let fileName = "live-test-videos.txt"

    /// The listed videos, as library keys ("youtube:<id>", "url:<host/path>").
    static func ids(in dir: URL) -> Set<String> {
        guard let text = try? String(contentsOf: dir.appendingPathComponent(fileName), encoding: .utf8) else { return [] }
        return parse(text)
    }

    /// The RC's rule: no AI summary until you've approved them; no download of anything that isn't listed.
    static func refusal(_ action: JobAction, key: String, aiApproved: Bool, listed: Set<String>, app: String) -> String? {
        if action.usesAI, !aiApproved { return "AI summaries aren't approved yet in \(app)" }
        if action.downloadsMedia, !listed.contains(key) {
            return key.hasPrefix("youtube:") ? "\(key.dropFirst("youtube:".count)) isn't on \(app)'s live-test list"
                                             : "this link isn't on \(app)'s live-test list"
        }
        return nil
    }

    static func parse(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline).compactMap { line in
            let entry = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first?.trimmingCharacters(in: .whitespaces) ?? ""
            if entry.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil { return "youtube:\(entry)" }
            return VideoRef.parse(entry)?.key
        })
    }
}
