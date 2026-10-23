// 4.0 Phase 4: is a registered media file really usable here? Read-only, one file at a time. The quick check reads the
// container with ffprobe and asks macOS's own player (AVFoundation) to open it; only the optional deep check decodes
// every frame with ffmpeg. Neither moves, renames, changes or deletes a file, and the quick check never claims "no
// corruption".
import AVFoundation
import Foundation
import Observation

/// What a check found (nothing is stored: results are kept for this session, by path, size and modification date).
enum MediaState: Equatable {
    case notChecked
    case checking
    case missing
    /// Opens and plays in Video Buddy's player (quick check).
    case opensHere(MediaInfo)
    /// ffprobe reads it, but macOS's player can't open it (a format like WebM or MKV): it opens in another app.
    case opensElsewhere(MediaInfo)
    /// The deep check decoded the whole file without an error.
    case fullyChecked(MediaInfo)
    case damaged(String)

    var info: MediaInfo? {
        switch self {
        case let .opensHere(i), let .opensElsewhere(i), let .fullyChecked(i): i
        default: nil
        }
    }

    var usable: Bool { info != nil }

    var label: String {
        switch self {
        case .notChecked: "Not checked yet"
        case .checking: "Checking…"
        case .missing: "Missing"
        case .opensHere: "Opens and plays on this Mac (quick check)"
        case .opensElsewhere: "Opens in another app (Video Buddy's player can't play this format)"
        case .fullyChecked: "Fully checked: no decoding errors"
        case let .damaged(why): "Can't be played: \(why)"
        }
    }
}

struct MediaInfo: Equatable {
    var duration: Double?
    var width: Int?
    var height: Int?
    var videoCodec: String?
    var audioCodec: String?

    /// "720p" for a video, nil for audio.
    var quality: String? { height.map { "\($0)p" } }

    /// From `ffprobe -show_entries format=duration:stream=codec_type,codec_name,width,height -of json`.
    static func from(ffprobe json: Data) -> MediaInfo? {
        struct Raw: Decodable {
            struct S: Decodable { let codec_type: String?, codec_name: String?, width: Int?, height: Int? }
            struct F: Decodable { let duration: String? }
            let streams: [S]?
            let format: F?
        }
        guard let r = try? JSONDecoder().decode(Raw.self, from: json) else { return nil }
        let video = r.streams?.first { $0.codec_type == "video" && ($0.height ?? 0) > 0 && $0.codec_name != "mjpeg" && $0.codec_name != "png" }
        let audio = r.streams?.first { $0.codec_type == "audio" }
        guard video != nil || audio != nil else { return nil }
        return MediaInfo(duration: r.format?.duration.flatMap(Double.init), width: video?.width, height: video?.height,
                         videoCodec: video?.codec_name, audioCodec: audio?.codec_name)
    }
}

@MainActor @Observable
final class MediaChecker {
    private(set) var states: [String: MediaState] = [:]
    /// A file of the same name found in the downloads folder for a missing one ("it moved here?"); you decide.
    private(set) var foundElsewhere: [String: String] = [:]
    private(set) var running: String?
    @ObservationIgnored private var signatures: [String: String] = [:]
    @ObservationIgnored private var waiting: [(path: String, deep: Bool)] = []
    @ObservationIgnored private var worker: Task<Void, Never>?

    /// The state now: a file that changed since it was checked counts as not checked.
    func state(_ path: String) -> MediaState {
        guard let sig = Self.signature(path) else { return .missing }
        if running == path { return .checking }
        guard let s = states[path], signatures[path] == sig else { return .notChecked }
        return s
    }

    /// Checks these files one after another (skipping ones already checked, unless asked again).
    func check(_ paths: [String], deep: Bool = false, again: Bool = false) {
        for p in paths where !waiting.contains(where: { $0.path == p }) {
            let s = state(p)
            if s == .missing { continue }
            if !again, deep ? s.isFullyChecked : s != .notChecked { continue }
            waiting.append((p, deep))
        }
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, !self.waiting.isEmpty {
                let next = self.waiting.removeFirst()
                self.running = next.path
                let sig = Self.signature(next.path)
                let result = next.deep ? await Self.deepCheck(next.path) : await Self.quickCheck(next.path)
                guard !Task.isCancelled else { break }
                self.states[next.path] = result
                self.signatures[next.path] = sig
                self.running = nil
            }
            self?.running = nil
            self?.worker = nil
        }
    }

    func cancel() {
        waiting = []
        worker?.cancel()
        worker = nil
        running = nil
    }

    /// For missing files: a file of the same name (and size, when known) in the downloads folder or a subfolder.
    func lookForMoved(_ files: [FileItem], in folder: String) {
        let missing = files.filter { !$0.exists && foundElsewhere[$0.path] == nil }
        guard !missing.isEmpty else { return }
        Task {
            let found = await Task.detached { Self.search(missing.map { ($0.path, $0.size) }, in: folder) }.value
            for (old, new) in found { foundElsewhere[old] = new }
        }
    }

    func forget(_ path: String) {
        foundElsewhere[path] = nil
        states[path] = nil
    }

    // MARK: the checks (read-only)

    nonisolated static func signature(_ path: String) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return "\((a[.size] as? NSNumber)?.int64Value ?? -1)-\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }

    nonisolated static func quickCheck(_ path: String) async -> MediaState {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value, size > 0 else {
            return .damaged("the file is empty")
        }
        guard let run = try? RunningScript(["ffprobe", "-v", "error", "-show_entries", "format=duration:stream=codec_type,codec_name,width,height",
                                            "-of", "json", "--", path]) else { return .damaged("ffprobe couldn't be started") }
        let (status, lines) = await run.collect()
        let json = Data(lines.filter { !$0.hasPrefix("[") || $0.hasPrefix("[{") }.joined(separator: "\n").utf8)
        guard status == 0, let info = MediaInfo.from(ffprobe: json) else {
            let why = lines.first { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("{") && !$0.contains("\"") }?.trimmingCharacters(in: .whitespaces)
            // without ffprobe's "[mov,mp4,… @ 0x…]" prefix
            let plain = why?.replacingOccurrences(of: #"^\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
            return .damaged(plain.map { "\($0) (damaged or incomplete)" } ?? "it has no readable audio or video")
        }
        if (info.duration ?? 0) <= 0 { return .damaged("it has no length (damaged or incomplete)") }
        return await opensNatively(path) ? .opensHere(info) : .opensElsewhere(info)
    }

    /// Whether macOS's player (AVFoundation) can open and play it.
    nonisolated static func opensNatively(_ path: String) async -> Bool {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard (try? await asset.load(.isPlayable)) == true else { return false }
        let tracks = (try? await asset.load(.tracks)) ?? []
        let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        return !tracks.isEmpty && seconds > 0
    }

    /// Decodes every frame (ffmpeg to nowhere): slow, and still read-only.
    nonisolated static func deepCheck(_ path: String) async -> MediaState {
        let quick = await quickCheck(path)
        guard let info = quick.info else { return quick }
        guard let run = try? RunningScript(["ffmpeg", "-nostdin", "-v", "error", "-i", path, "-f", "null", "-"]) else {
            return .damaged("ffmpeg couldn't be started")
        }
        let (status, lines) = await withTaskCancellationHandler { await run.collect() } onCancel: { run.cancel() }
        let errors = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if status != 0 || !errors.isEmpty { return .damaged("decoding errors (\(errors.first ?? "ffmpeg stopped with \(status)"))") }
        return .fullyChecked(info)
    }

    nonisolated static func search(_ missing: [(path: String, size: Int?)], in folder: String) -> [String: String] {
        var byName: [String: [(String, Int?)]] = [:]
        for m in missing { byName[(m.path as NSString).lastPathComponent, default: []].append(m) }
        var found: [String: String] = [:]
        // paths relative to the folder, so what's found is named in the folder's own form
        guard let e = FileManager.default.enumerator(atPath: folder) else { return [:] }
        var looked = 0
        while let rel = e.nextObject() as? String {
            looked += 1
            if looked > 50_000 { break }          // ponytail: a bounded look; a huge folder is left to Locate…
            let name = (rel as NSString).lastPathComponent
            if name.hasPrefix(".") { if e.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { e.skipDescendants() }; continue }
            guard let wanted = byName[name] else { continue }
            let path = (folder as NSString).appendingPathComponent(rel)
            let size = (e.fileAttributes?[.size] as? NSNumber)?.intValue
            for (old, s) in wanted where found[old] == nil && old != path && (s == nil || s == size) { found[old] = path }
        }
        return found
    }
}

extension MediaState {
    var isFullyChecked: Bool { if case .fullyChecked = self { true } else { false } }
    var opensElsewhere: Bool { if case .opensElsewhere = self { true } else { false } }
}
