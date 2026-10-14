// Plain value types shared by the database, the pipeline and the views.
import Foundation

enum JobKind: String { case summary, audio, video }
enum JobStatus: String { case running, succeeded, failed, cancelled, interrupted }
enum JobSource: String { case app, raycast, imported = "import" }

struct Video: Identifiable, Hashable {
    var id: Int64
    var key: String
    var url: String?
    var platform: String?
    var title: String?
    var channel: String?
    var channelFollowers: Int?
    var thumbnailURL: String?
    var duration: Double?
    var uploadDate: String?     // yyyyMMdd from the platform; nil when unknown
    var favorite: Bool
    var firstProcessed: Date
    var lastProcessed: Date
    var lastOpened: Date?
    // derived from the video's jobs by the list query
    var hasSummary = false
    var hasAudio = false
    var hasVideo = false
    var latestStatus: JobStatus?
    var latestKind: JobKind?
    var language: String?

    var displayTitle: String { title?.nilIfBlank ?? "Untitled video" }
    var displayChannel: String { channel?.nilIfBlank ?? "Unknown channel" }
}

struct Job: Identifiable, Hashable {
    var id: Int64
    var videoID: Int64
    var kind: JobKind
    var status: JobStatus
    var source: JobSource
    var eventID: String?
    var started: Date
    var finished: Date?
    var filePath: String?
    var fileSize: Int?
    var summaryPath: String?
    var transcriptPath: String?
    var summary: String?
    var summaryLanguage: String?
    var summaryFormat: String?
    var transcript: String?
    var segmentsJSON: String?
    var transcriptLanguage: String?
    var error: String?

    var segments: [Segment] {
        guard let s = segmentsJSON, let data = s.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Segment].self, from: data)) ?? []
    }
}

/// Everything a job row can hold; used both to insert jobs and to finish them.
struct NewJob {
    var kind: JobKind
    var status: JobStatus
    var source: JobSource
    var eventID: String? = nil
    var started = Date()
    var finished: Date? = nil
    var filePath: String? = nil
    var fileSize: Int? = nil
    var summaryPath: String? = nil
    var transcriptPath: String? = nil
    var summary: String? = nil
    var summaryLanguage: String? = nil
    var summaryFormat: String? = nil
    var transcript: String? = nil
    var segmentsJSON: String? = nil
    var transcriptLanguage: String? = nil
    var error: String? = nil
}

/// Video metadata from yt-dlp, the filename or ffprobe; nil fields mean "unknown".
struct VideoInfo {
    var title: String? = nil
    var channel: String? = nil
    var followers: Int? = nil
    var thumbnail: String? = nil
    var duration: Double? = nil
    var uploadDate: String? = nil
    var platform: String? = nil
}

struct Segment: Codable, Hashable {
    var start: Double
    var end: Double
    var text: String
}

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "All", summaries = "Summaries", audio = "Audio", downloads = "Downloads", favorites = "Favorites"
    var id: String { rawValue }
}

enum HistorySort: String, CaseIterable, Identifiable {
    case recent = "Recently processed", oldest = "Oldest first", duration = "Duration", title = "Title"
    var id: String { rawValue }
}

struct Stats: Equatable {
    var videos = 0
    var watchSeconds = 0.0
    var summaries = 0
    var downloads = 0
}

/// One file on disk that a job produced.
struct FileItem: Identifiable, Hashable {
    enum Role: String { case audio = "Audio", video = "Video", summary = "Summary", transcript = "Transcript" }
    var path: String
    var role: Role
    var jobID: Int64
    var videoID: Int64
    var size: Int?
    var date: Date
    var videoTitle: String?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
    var isMedia: Bool { role == .audio || role == .video }

    static let audioExtensions: Set<String> = ["mp3", "m4a", "opus", "ogg", "wav", "flac", "aac"]
    static let videoExtensions: Set<String> = ["mp4", "webm", "mkv", "mov", "m4v"]

    static func mediaRole(_ path: String) -> Role {
        videoExtensions.contains((path as NSString).pathExtension.lowercased()) ? .video : .audio
    }
}

/// whisper.cpp `-oj` output: timestamped segments (offsets in ms) and the detected language.
struct WhisperJSON: Decodable {
    struct Item: Decodable {
        struct Offsets: Decodable { let from: Double; let to: Double }
        let offsets: Offsets
        let text: String
    }
    struct Result: Decodable { let language: String? }
    let transcription: [Item]?
    let result: Result?

    static func load(_ url: URL) -> (segments: [Segment], language: String?)? {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONDecoder().decode(WhisperJSON.self, from: data) else { return nil }
        let segments = (parsed.transcription ?? []).compactMap { item -> Segment? in
            let text = item.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("[") else { return nil } // [BLANK_AUDIO], [MUSIC], ...
            return Segment(start: item.offsets.from / 1000, end: item.offsets.to / 1000, text: text)
        }
        return (segments, parsed.result?.language)
    }
}

/// The summary/transcript files that sit next to a media file: `<base>.summary.md`, `<base>.transcript.{txt,json}`.
struct SummaryOutputs {
    var summaryPath: String?
    var summary: String?
    var transcriptPath: String?
    var transcript: String?
    var segments: [Segment] = []
    var language: String?

    var segmentsJSON: String? {
        guard !segments.isEmpty, let data = try? JSONEncoder().encode(segments) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func load(base: String) -> SummaryOutputs {
        func read(_ p: String) -> String? { (try? String(contentsOfFile: p, encoding: .utf8))?.nilIfBlank }
        let summaryPath = base + ".summary.md", textPath = base + ".transcript.txt"
        let whisper = WhisperJSON.load(URL(fileURLWithPath: base + ".transcript.json"))
        let summary = read(summaryPath), transcript = read(textPath)
        return SummaryOutputs(summaryPath: summary == nil ? nil : summaryPath, summary: summary,
                              transcriptPath: transcript == nil ? nil : textPath, transcript: transcript,
                              segments: whisper?.segments ?? [], language: whisper?.language)
    }
}

extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

enum Fmt {
    static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let t = Int(seconds.rounded())
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func timestamp(_ seconds: Double) -> String { duration(max(seconds, 0.001)) ?? "0:00" }

    static func watchTime(_ seconds: Double) -> String {
        if seconds > 0, seconds < 60 { return "\(Int(seconds.rounded())) sec" }
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min"
    }

    static func date(_ d: Date?) -> String { d.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—" }

    static func uploadDate(_ s: String?) -> String? {
        guard let s, s.count == 8 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f.date(from: s).map { $0.formatted(date: .abbreviated, time: .omitted) }
    }

    static func bytes(_ n: Int?) -> String {
        n.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—"
    }

    static func followers(_ n: Int?) -> String? {
        n.map { $0.formatted(.number.notation(.compactName)) + " subscribers" }
    }

    static func language(_ code: String?) -> String? {
        guard let code = code?.nilIfBlank else { return nil }
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }
}
