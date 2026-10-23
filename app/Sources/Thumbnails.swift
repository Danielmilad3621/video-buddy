// Thumbnails saved on this Mac, so the library looks right offline. They're the app's own cache
// (~/Library/Application Support/Video Summarizer/thumbnails/<video id>.jpg), never the user's files.
import AppKit
import AVFoundation
import Foundation

enum Thumbnails {
    static var directory: URL { AppSettings.dataDir.appendingPathComponent("thumbnails") }

    static func path(for videoID: Int64) -> String { directory.appendingPathComponent("\(videoID).jpg").path }

    /// Makes sure the entry has a saved thumbnail: from its thumbnail link when online, otherwise from a frame of
    /// a local video. Returns the saved path, or nil when neither source is available.
    @discardableResult
    static func ensure(_ video: Video, localVideo: String?, db: Database, online: Bool) async -> String? {
        let dest = path(for: video.id)
        if FileManager.default.fileExists(atPath: dest) {
            if video.thumbnailPath != dest { try? await db.setThumbnailPath(video.id, dest) }
            return dest
        }
        var image = online ? await download(video.thumbnailURL) : nil
        if image == nil, let localVideo, FileItem.mediaRole(localVideo) == .video {
            image = await frame(of: localVideo)
        }
        guard let image, let jpeg = jpegData(image, maxWidth: 640) else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try jpeg.write(to: URL(fileURLWithPath: dest), options: .atomic)
            try await db.setThumbnailPath(video.id, dest)
            return dest
        } catch {
            return nil
        }
    }

    /// The image at a link (15 s at most), or nil.
    static func download(_ link: String?) async -> NSImage? {
        guard let link, let url = URL(string: link) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              ((response as? HTTPURLResponse)?.statusCode ?? 0) < 400 else { return nil }
        return NSImage(data: data)
    }

    // MARK: Watch Later (4.0 Phase 3): its own folder, since Clear All History removes `directory` whole

    static var watchLaterDirectory: URL { AppSettings.dataDir.appendingPathComponent("watch-later") }

    static func watchLaterPath(_ youtubeID: String) -> String { watchLaterDirectory.appendingPathComponent("\(youtubeID).jpg").path }

    /// A Watch Later item's thumbnail copy: the library entry's saved one if there is one (works offline), else YouTube's.
    /// It's kept only while the item is still saved: checked again once the file is in place, so a removal meanwhile
    /// never leaves an orphan.
    @discardableResult
    static func saveWatchLater(_ item: WatchLaterItem, libraryCopy: String?, online: Bool, stillSaved: () async -> Bool) async -> Bool {
        let dest = watchLaterPath(item.youtubeID)
        var image = libraryCopy.flatMap { FileManager.default.fileExists(atPath: $0) ? NSImage(contentsOfFile: $0) : nil }
        if image == nil, online { image = await download(item.thumbnailURL) }
        // test runs can slow this down, to remove an item while its thumbnail is still on its way
        if let wait = ProcessInfo.processInfo.environment["VS_TEST_SLOW_THUMBS"].flatMap(Double.init) { try? await Task.sleep(for: .seconds(wait)) }
        guard !Task.isCancelled, let image, let jpeg = jpegData(image, maxWidth: 640), await stillSaved() else { return false }
        do {
            try FileManager.default.createDirectory(at: watchLaterDirectory, withIntermediateDirectories: true)
            try jpeg.write(to: URL(fileURLWithPath: dest), options: .atomic)
        } catch {
            return false
        }
        guard !Task.isCancelled, await stillSaved() else { removeWatchLater(item.youtubeID); return false }
        return true
    }

    static func removeWatchLater(_ youtubeID: String) { try? FileManager.default.removeItem(atPath: watchLaterPath(youtubeID)) }

    /// Removes cached thumbnails for entries that left the history (our cache only).
    static func remove(videoIDs: [Int64]) {
        for id in videoIDs { try? FileManager.default.removeItem(atPath: path(for: id)) }
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func frame(of path: String) async -> NSImage? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let seconds = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        let at = CMTime(seconds: seconds > 0 ? min(seconds * 0.1, 30) : 0, preferredTimescale: 600)
        guard let (cg, _) = try? await generator.image(at: at) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func jpegData(_ image: NSImage, maxWidth: CGFloat) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxWidth / CGFloat(cg.width))
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
}
