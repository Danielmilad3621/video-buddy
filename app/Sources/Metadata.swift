// Turning links and filenames into video identities, and fetching real metadata.
import Foundation

/// A parsed video link. `key` identifies the video, so the same video never gets two history entries.
struct VideoRef: Equatable {
    let key: String
    let url: String
    let platform: String
    let youtubeID: String?

    var thumbnailFallback: String? { youtubeID.map { "https://i.ytimg.com/vi/\($0)/mqdefault.jpg" } }

    static func parse(_ raw: String) -> VideoRef? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: text), let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https", var host = comps.host?.lowercased(), host.contains(".") else { return nil }
        for prefix in ["www.", "m.", "music."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        let parts = comps.path.split(separator: "/").map(String.init)

        var id: String?
        if host == "youtu.be" {
            id = parts.first
        } else if host == "youtube.com" || host == "youtube-nocookie.com" {
            if comps.path == "/watch" {
                id = comps.queryItems?.first { $0.name == "v" }?.value
            } else if parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]) {
                id = parts[1]
            }
        }
        if let id, id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil {
            return VideoRef(key: "youtube:\(id)", url: "https://www.youtube.com/watch?v=\(id)", platform: "YouTube", youtubeID: id)
        }
        if host == "youtube.com" || host == "youtu.be" { return nil } // a YouTube page that isn't a video

        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        let query = comps.percentEncodedQuery.map { "?" + $0 } ?? ""
        return VideoRef(key: "url:\(host)\(path)\(query)", url: text, platform: platformName(host: host), youtubeID: nil)
    }

    static func platformName(host: String) -> String {
        let known: [(String, String)] = [
            ("tiktok.com", "TikTok"), ("vimeo.com", "Vimeo"), ("x.com", "X"), ("twitter.com", "X"),
            ("instagram.com", "Instagram"), ("reddit.com", "Reddit"), ("soundcloud.com", "SoundCloud"),
            ("twitch.tv", "Twitch"), ("facebook.com", "Facebook"), ("bilibili.com", "Bilibili"),
            ("dailymotion.com", "Dailymotion"), ("bsky.app", "Bluesky"), ("loom.com", "Loom"),
        ]
        return known.first { host == $0.0 || host.hasSuffix("." + $0.0) }?.1 ?? host
    }
}

/// Reads what cobalt and yt-dlp filenames tell us:
/// cobalt "pretty": `Title - Channel (youtube).mp3`, `Title - Channel (240p, h264, youtube).mp4`;
/// yt-dlp: `Title.mp3`; and our own `… (2).mp3` for repeat downloads.
enum FileNames {
    enum Role { case media, summary, transcriptText, transcriptJSON }

    static let platforms: [String: String] = [
        "youtube": "YouTube", "tiktok": "TikTok", "vimeo": "Vimeo", "twitter": "X", "x": "X",
        "instagram": "Instagram", "reddit": "Reddit", "soundcloud": "SoundCloud", "twitch": "Twitch",
        "facebook": "Facebook", "bilibili": "Bilibili", "dailymotion": "Dailymotion", "bluesky": "Bluesky",
        "loom": "Loom", "tumblr": "Tumblr", "pinterest": "Pinterest", "snapchat": "Snapchat", "vk": "VK",
        "ok": "OK", "rutube": "Rutube", "streamable": "Streamable", "newgrounds": "Newgrounds",
    ]

    /// The file's role and its stem (the name without role suffix or extension), or nil for files we don't track.
    static func role(of name: String) -> (stem: String, role: Role)? {
        let lower = name.lowercased()
        for (suffix, role) in [(".summary.md", Role.summary), (".transcript.txt", .transcriptText), (".transcript.json", .transcriptJSON)]
        where lower.hasSuffix(suffix) {
            return (String(name.dropLast(suffix.count)), role)
        }
        let ext = (name as NSString).pathExtension.lowercased()
        if FileItem.audioExtensions.contains(ext) || FileItem.videoExtensions.contains(ext) {
            return ((name as NSString).deletingPathExtension, .media)
        }
        return nil
    }

    /// groupKey ties together every file of one video; title/channel/platform are what the name reveals.
    static func parse(stem: String) -> (groupKey: String, title: String, channel: String?, platform: String?) {
        var s = stem.replacingOccurrences(of: #"\s\(\d+\)$"#, with: "", options: .regularExpression)
        var platform: String?
        if let r = s.range(of: #"\s\(([^()]*)\)$"#, options: .regularExpression) {
            let inside = s[r].dropFirst(2).dropLast()
            let last = inside.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            if let p = platforms[last] {
                platform = p
                s = String(s[..<r.lowerBound])
            }
        }
        var title = s, channel: String?
        if platform != nil, let dash = s.range(of: " - ", options: .backwards) {
            title = String(s[..<dash.lowerBound])
            channel = String(s[dash.upperBound...])
        }
        return (s.lowercased(), title, channel, platform)
    }
}

/// The parts of `yt-dlp -j` we keep.
private struct YTDLPInfo: Decodable {
    let title: String?
    let uploader: String?
    let channel: String?
    let channel_follower_count: Int?
    let duration: Double?
    let upload_date: String?
    let thumbnail: String?
    let extractor_key: String?

    var info: VideoInfo {
        let platform = extractor_key.map { ["Youtube": "YouTube", "Soundcloud": "SoundCloud", "Twitter": "X"][$0] ?? $0 }
        return VideoInfo(title: title, channel: channel ?? uploader, followers: channel_follower_count, thumbnail: thumbnail,
                         duration: duration, uploadDate: upload_date, platform: platform)
    }
}

enum MetadataFetcher {
    /// Title, channel, duration, upload date and thumbnail from yt-dlp. Nil when unavailable; never guessed.
    static func fetch(_ url: String, onStart: (RunningScript) -> Void = { _ in }) async -> VideoInfo? {
        guard let run = try? RunningScript(["yt-dlp", "-j", "--skip-download", "--no-playlist", "--no-warnings", "--", url]) else {
            return nil
        }
        onStart(run)
        let (status, lines) = await run.collect()
        guard status == 0, let json = lines.last(where: { $0.hasPrefix("{") }),
              let parsed = try? JSONDecoder().decode(YTDLPInfo.self, from: Data(json.utf8)) else { return nil }
        return parsed.info
    }

    /// Real duration of a local media file.
    static func probeDuration(_ path: String) async -> Double? {
        guard FileManager.default.fileExists(atPath: path),
              let run = try? RunningScript(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path])
        else { return nil }
        let (status, lines) = await run.collect()
        guard status == 0, let value = lines.first.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), value > 0 else { return nil }
        return value
    }
}
