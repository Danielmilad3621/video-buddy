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
    var index = 0           // its place in the YouTube playlist (0 = first)
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
        let parsed: [PlaylistEntry] = entries.enumerated().compactMap { i, e in
            guard let id = e.id, id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else { return nil }
            let title = e.title ?? "Untitled video"
            let gone = title == "[Private video]" || title == "[Deleted video]"
            return PlaylistEntry(id: id, index: i, title: title, duration: e.duration, url: "https://www.youtube.com/watch?v=\(id)",
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
    var coverPath: String? = nil    // the first video's thumbnail, for the sidebar artwork
    var coverURL: String? = nil
}

/// Where the playlist sheet saves: a new playlist, or one you already have (matched by its YouTube link by default).
enum PlaylistTarget: Equatable { case new(String), existing(Int64) }

struct PlaylistImportResult: Equatable {
    let playlist: Int64?
    let jobs: Int       // downloads or summaries queued
    let linked: Int     // videos that joined the playlist
}

enum PlaylistOrder {
    /// Adds the YouTube playlist's videos that aren't members yet, each right after the closest earlier YouTube entry
    /// that is (else right before the closest later one, else at the end). Existing members never move.
    static func merge(current: [Int64], youtube: [Int64]) -> [Int64] {
        var out = current
        for (k, id) in youtube.enumerated() where !out.contains(id) {
            if let prev = youtube[..<k].last(where: out.contains), let i = out.firstIndex(of: prev) {
                out.insert(id, at: i + 1)
            } else if let next = youtube[(k + 1)...].first(where: out.contains), let i = out.firstIndex(of: next) {
                out.insert(id, at: i)
            } else {
                out.append(id)
            }
        }
        return out
    }

    /// Positions for the members `merged` adds, between their neighbours; existing members keep theirs.
    static func newPositions(_ merged: [Int64], existing: [Int64: Double]) -> [(Int64, Double)] {
        var pos = existing, out: [(Int64, Double)] = []
        for (i, id) in merged.enumerated() where pos[id] == nil {
            let before = i > 0 ? pos[merged[i - 1]] : nil
            let after = merged[(i + 1)...].lazy.compactMap { pos[$0] }.first
            let p = switch (before, after) {
            case let (b?, a?): (b + a) / 2
            case let (b?, nil): b + 1
            case let (nil, a?): a - 1
            default: 0.0
            }
            pos[id] = p
            out.append((id, p))
        }
        return out
    }

    /// The episode Continue plays: the last one you played unless you finished it, otherwise the next one after it
    /// that's on this Mac and not finished. Nil when nothing in the playlist was played yet (or everything after is done).
    static func resume(order: [Int64], watch: [Int64: Watch], playable: Set<Int64>) -> Int64? {
        guard let last = order.filter({ watch[$0] != nil }).max(by: { watch[$0]!.updated < watch[$1]!.updated }),
              let i = order.firstIndex(of: last) else { return nil }
        if watch[last]?.state != .finished, playable.contains(last) { return last }
        return order[(i + 1)...].first { playable.contains($0) && watch[$0]?.state != .finished }
    }
}

/// A playlist as it appears in a grouped list: only the videos the list shows, in playlist order.
struct LibraryGroup: Identifiable {
    let playlist: PlaylistSummary
    let videos: [Video]
    var id: String { "playlist-\(playlist.id)" }   // never equal to a video's id in the same list
}

enum Grouping {
    /// Groups whatever the list shows (so search, filters and favorites apply as they do flat). A video in two playlists
    /// appears in both; videos in none are `individual`, in the list's own order. Playlists with no match are left out.
    static func make(_ videos: [Video], playlists: [PlaylistSummary], members: [Int64: [Int64]]) -> (groups: [LibraryGroup], individual: [Video]) {
        let byID = Dictionary(videos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let groups = playlists.compactMap { p -> LibraryGroup? in
            let vs = (members[p.id] ?? []).compactMap { byID[$0] }
            return vs.isEmpty ? nil : LibraryGroup(playlist: p, videos: vs)
        }
        let grouped = Set(members.values.joined())
        return (groups, videos.filter { !grouped.contains($0.id) })
    }

    /// Consecutive queue items from the same playlist share a header; the order (FIFO) is never changed.
    static func runs<T>(_ items: [T], playlist: (T) -> Int64?) -> [(playlist: Int64?, items: [(number: Int, item: T)])] {
        var out: [(playlist: Int64?, items: [(number: Int, item: T)])] = []
        for (i, item) in items.enumerated() {
            let p = playlist(item)
            if let last = out.indices.last, out[last].playlist == p, p != nil { out[last].items.append((i + 1, item)) }
            else { out.append((p, [(i + 1, item)])) }
        }
        return out
    }
}
