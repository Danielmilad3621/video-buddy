// Plain value types shared by the database, the pipeline and the views.
import Foundation

enum JobKind: String { case summary, audio, video, transcript }
enum JobStatus: String { case queued, running, succeeded, failed, cancelled, interrupted }
enum JobSource: String { case app, raycast, imported = "import" }

/// What a job does. `kind` is what it produces; queued jobs wait for the network unless they run on-device.
enum JobAction: String, CaseIterable {
    case summarize, audio, video, transcribe, resummarize
    /// a download followed by an on-device transcript (a second, queued transcribe job), with no summary
    case audioTranscript = "audio_transcript", videoTranscript = "video_transcript"

    var kind: JobKind {
        switch self {
        case .summarize, .resummarize: .summary
        case .audio, .audioTranscript: .audio
        case .video, .videoTranscript: .video
        case .transcribe: .transcript
        }
    }

    var needsNetwork: Bool { self != .transcribe }

    var transcribesAfter: Bool { self == .audioTranscript || self == .videoTranscript }

    var label: String {
        switch self {
        case .summarize: "Summarize"
        case .audio: "Download audio"
        case .video: "Download video"
        case .audioTranscript: "Download audio + transcript"
        case .videoTranscript: "Download video + transcript"
        case .transcribe: "Transcribe on this Mac"
        case .resummarize: "Summarize transcript"
        }
    }

    /// What the Audio / Video buttons queue, depending on the "+ Transcript" checkbox.
    static func download(_ kind: JobKind, transcript: Bool) -> JobAction {
        switch (kind, transcript) {
        case (.audio, true): .audioTranscript
        case (.video, true): .videoTranscript
        default: from(kind: kind)
        }
    }

    static func from(kind: JobKind) -> JobAction {
        switch kind {
        case .summary: .summarize
        case .audio: .audio
        case .video: .video
        case .transcript: .transcribe
        }
    }
}

struct Video: Identifiable, Hashable {
    var id: Int64
    var key: String
    var url: String?
    var platform: String?
    var title: String?
    var channel: String?
    var channelFollowers: Int?
    var thumbnailURL: String?
    var thumbnailPath: String?  // copy saved on this Mac, so the library looks right offline
    var duration: Double?
    var uploadDate: String?     // yyyyMMdd from the platform; nil when unknown
    var description: String?    // the platform's description (3.0); nil until yt-dlp has been asked
    var tags: [String] = []
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
    var action: JobAction
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
    var action: JobAction? = nil        // defaults to the action that produces `kind`
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
    var description: String? = nil
    var tags: [String]? = nil
}

struct Segment: Codable, Hashable {
    var start: Double
    var end: Double
    var text: String
}

extension Array where Element == Segment {
    /// The line being spoken at `t` (segments are in time order); nil before the first one.
    func index(at t: Double) -> Int? {
        var lo = 0, hi = count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if self[mid].start <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }
}

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "All", summaries = "Summaries", audio = "Audio", video = "Video", offline = "Offline", favorites = "Favorites"
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
    /// Formats the built-in player (AVFoundation) can play; others open in QuickTime/VLC.
    var isPlayable: Bool { isMedia && FileItem.playableExtensions.contains((path as NSString).pathExtension.lowercased()) }
    static let playableExtensions: Set<String> = ["mp4", "m4v", "mov", "mp3", "m4a", "aac", "wav"]

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

/// How far you got in a video. Position 0 or an unknown length never counts as finished: only reaching the player's
/// "nearly finished" margin does (the player saves the full length when a file plays to its end).
enum WatchState: Equatable {
    case notStarted, partial(Double), finished   // partial: 0…1, or 0 when the length isn't known

    init(position: Double, duration: Double?) {
        if let d = duration, d > 0, position >= d - WatchState.nearEnd(d) { self = .finished }
        else if position > 1 { self = .partial(duration.map { $0 > 0 ? min(position / $0, 1) : 0 } ?? 0) }
        else { self = .notStarted }
    }

    /// The last 5% of a file, at most 10 s: stopping there counts as finished, and it starts over next time.
    static func nearEnd(_ duration: Double) -> Double { duration > 0 ? min(10, duration * 0.05) : 0 }
}

struct Watch: Equatable {
    let state: WatchState
    let updated: Date
}

/// A download of this kind is already waiting or running for the video, so nothing was queued.
struct AlreadyQueued: Error { let videoID: Int64 }

/// 4.0 Phase 3: a video saved to Watch Later. Its own record, apart from the library (what was processed); joined to
/// it, and to download declarations, by `key` (youtube:<id>).
struct WatchLaterItem: Identifiable, Hashable {
    var key: String
    var url: String
    var title: String?
    var channel: String?
    var duration: Double?
    var thumbnailURL: String?
    var added: Date
    var id: String { key }
    var youtubeID: String { String(key.dropFirst("youtube:".count)) }

    /// A new item for a YouTube video id: the canonical link and YouTube's thumbnail for that id.
    static func new(youtubeID id: String, title: String?, channel: String? = nil, duration: Double? = nil, at: Date = Date()) -> WatchLaterItem {
        WatchLaterItem(key: "youtube:\(id)", url: BrowserPolicy.watchURL(id), title: title?.nilIfBlank, channel: channel?.nilIfBlank,
                       duration: duration, thumbnailURL: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg", added: at)
    }
}

enum WatchLaterSort: String, CaseIterable, Identifiable {
    case newest = "Newest First", oldest = "Oldest First", title = "Title", channel = "Channel", duration = "Longest First"
    var id: String { rawValue }
}

/// The Watch Later page's rules (pure, self-tested).
enum WatchLater {
    /// Search by title or channel (any case, any accents), then sort; unknown values go last.
    static func arrange(_ items: [WatchLaterItem], search: String, sort: WatchLaterSort) -> [WatchLaterItem] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = term.isEmpty ? items : items.filter {
            ($0.title ?? "").localizedStandardContains(term) || ($0.channel ?? "").localizedStandardContains(term)
        }
        let text = { (a: String?, b: String?) -> Bool? in
            switch (a?.nilIfBlank, b?.nilIfBlank) {
            case let (x?, y?): x.localizedStandardCompare(y) == .orderedSame ? nil : x.localizedStandardCompare(y) == .orderedAscending
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): nil
            }
        }
        return found.sorted { a, b in
            let decided: Bool? = switch sort {
            case .newest: a.added == b.added ? nil : a.added > b.added
            case .oldest: a.added == b.added ? nil : a.added < b.added
            case .title: text(a.title, b.title)
            case .channel: text(a.channel, b.channel)
            case .duration: a.duration == b.duration ? nil : (a.duration ?? -1) > (b.duration ?? -1)
            }
            return decided ?? (a.added > b.added)
        }
    }

    /// What a row shows as the title: never empty and never another video's. `pending`: its lookup hasn't answered yet.
    static func displayTitle(_ item: WatchLaterItem, pending: Bool) -> (text: String, placeholder: Bool) {
        if let t = item.title?.nilIfBlank { return (t, false) }
        return (pending ? "Getting details…" : "Title unavailable", true)
    }

    enum Primary: Equatable { case playVideo, playAudio, openInYouTube }

    /// The row's main button: play what's on this Mac, else open the video on YouTube.
    static func primary(_ a: VideoAvailability) -> Primary {
        a.videoFile != nil ? .playVideo : a.audioFile != nil ? .playAudio : .openInYouTube
    }
}
