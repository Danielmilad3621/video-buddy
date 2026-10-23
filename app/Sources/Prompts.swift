// Summary prompt options and app settings. Standard + English is exactly the prompt summarize.sh uses by default.
import Foundation
import SwiftUI

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
    case p480 = "480p (smallest)", p720 = "720p (smaller)", standard = "1080p (default)", best = "Best available"
    var id: String { rawValue }
    var scriptValue: String? {
        switch self {
        case .p480: "480"
        case .p720: "720"
        case .standard: nil
        case .best: "max"
        }
    }
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
    static var videoQuality: VideoQuality { VideoQuality(rawValue: defaults.string(forKey: "videoQuality") ?? "") ?? .standard }
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
        return "4.0 RC · " + (jobsLockReason == nil ? "live downloads on" : "downloads locked")
            + (defaults.bool(forKey: "rcAISummaries") ? " · AI on" : " · AI locked")
    }

    /// Why this build may not run downloads or AI jobs at all, or nil (then only the Pause button stops the queue).
    static var jobsLockReason: String? {
        if isPreview { return "\(appName) never downloads or runs AI jobs" }
        if isRC, !defaults.bool(forKey: "rcLiveDownloads") { return "live downloads aren't approved yet in \(appName)" }
        return nil
    }

    /// Why this job may not be queued in this build, or nil. Only the RC refuses anything: AI summaries until you've
    /// approved them, and YouTube downloads of videos that aren't on its live-test list. The database asks this
    /// before every queued job, and the runner again before one runs.
    static func queueRefusal(_ action: JobAction, key: String) -> String? {
        guard isRC else { return nil }
        return LiveTestList.refusal(action, key: key, aiApproved: defaults.bool(forKey: "rcAISummaries"),
                                    listed: LiveTestList.ids(in: dataDir), app: appName)
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
