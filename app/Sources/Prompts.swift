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
    static let defaultDownloadDir = home + "/Downloads/cobalt"

    /// VS_DATA_DIR lets tests use a throwaway history without touching the real one.
    static var dataDir: URL {
        if let dir = ProcessInfo.processInfo.environment["VS_DATA_DIR"]?.nilIfBlank { return URL(fileURLWithPath: dir) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Video Summarizer")
    }
}
