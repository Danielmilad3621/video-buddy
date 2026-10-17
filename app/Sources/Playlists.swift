// YouTube playlist links: recognise them, list their videos with yt-dlp (no download), and turn a selection into
// queued jobs plus one of "My Playlists".
import Foundation

/// A playlist link. `videoID` is set when it was a watch link inside a playlist (`watch?v=…&list=…`).
struct PlaylistLink: Equatable {
    let listID: String
    let url: String
    let videoID: String?

    static func parse(_ raw: String) -> PlaylistLink? {
        guard let comps = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              var host = comps.host?.lowercased() else { return nil }
        for prefix in ["www.", "m.", "music."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        guard host == "youtube.com" || host == "youtu.be",
              let list = comps.queryItems?.first(where: { $0.name == "list" })?.value,
              list.range(of: #"^[A-Za-z0-9_-]{10,}$"#, options: .regularExpression) != nil else { return nil }
        let video = VideoRef.parse(raw)?.youtubeID
        return PlaylistLink(listID: list, url: "https://www.youtube.com/playlist?list=\(list)",
                            videoID: comps.path == "/playlist" ? nil : video)
    }
}

struct PlaylistEntry: Identifiable, Hashable {
    let id: String          // the video id
    let title: String
    let duration: Double?
    let url: String
    let channel: String?
    let available: Bool     // false for "[Private video]" / "[Deleted video]"
}

struct PlaylistPreview: Equatable {
    let title: String
    let url: String
    let entries: [PlaylistEntry]

    var available: [PlaylistEntry] { entries.filter(\.available) }
}

enum PlaylistImport {
    /// Lists a playlist's videos without downloading anything (`yt-dlp --flat-playlist -J`, a few seconds).
    static func fetch(_ url: String, onStart: (RunningScript) -> Void = { _ in }) async -> Result<PlaylistPreview, PlaylistError> {
        guard let run = try? RunningScript(["yt-dlp", "--flat-playlist", "-J", "--no-warnings", "--", url]) else {
            return .failure(PlaylistError(message: "Couldn't start yt-dlp"))
        }
        onStart(run)
        let (status, lines) = await run.collect()
        guard status == 0, let json = lines.last(where: { $0.hasPrefix("{") }), let preview = parse(Data(json.utf8), url: url) else {
            let reason = lines.last(where: { $0.contains("ERROR") }) ?? "yt-dlp couldn't read this playlist"
            return .failure(PlaylistError(message: reason))
        }
        return .success(preview)
    }

    static func parse(_ data: Data, url: String) -> PlaylistPreview? {
        struct Raw: Decodable {
            struct Entry: Decodable {
                let id: String?
                let title: String?
                let duration: Double?
                let url: String?
                let channel: String?
                let uploader: String?
            }
            let title: String?
            let entries: [Entry]?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), let entries = raw.entries else { return nil }
        let parsed: [PlaylistEntry] = entries.compactMap { e in
            guard let id = e.id, id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else { return nil }
            let title = e.title ?? "Untitled video"
            let gone = title == "[Private video]" || title == "[Deleted video]"
            return PlaylistEntry(id: id, title: title, duration: e.duration, url: "https://www.youtube.com/watch?v=\(id)",
                                 channel: e.channel ?? e.uploader, available: !gone)
        }
        return PlaylistPreview(title: raw.title ?? "YouTube playlist", url: url, entries: parsed)
    }
}

struct PlaylistError: Error, Equatable { let message: String }

/// One of "My Playlists", as listed in the sidebar section.
struct PlaylistSummary: Identifiable, Hashable {
    let id: Int64
    var name: String
    var sourceURL: String?
    var count: Int
    var totalDuration: Double
}
