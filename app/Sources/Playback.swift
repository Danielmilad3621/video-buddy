// The built-in player: one AVPlayer for the whole app, resume positions saved per file, and a Play All list.
import AVFoundation
import Foundation
import Observation

@MainActor @Observable
final class PlaybackController {
    private(set) var player: AVPlayer?
    private(set) var currentPath: String?
    private(set) var currentVideoID: Int64?
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    var rate: Float = 1 { didSet { if isPlaying { player?.rate = rate } } }
    /// Test-only (the `mute` test command), so automated runs don't play sound.
    var muted = false { didSet { player?.isMuted = muted } }
    /// Play All: the remaining entries, played in order when the current one ends.
    private(set) var upNext: [(videoID: Int64, path: String)] = []
    /// Set when Play All moves on, so the window can follow along.
    var onAdvance: (Int64) -> Void = { _ in }

    private let db: Database
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var rateObserver: NSKeyValueObservation?
    private var lastSaved = Date.distantPast

    init(db: Database) { self.db = db }

    func isCurrent(_ path: String?) -> Bool { path != nil && path == currentPath }

    /// Plays a file in the detail panel, picking up where you stopped (unless you'd nearly finished it).
    func play(path: String, videoID: Int64, upNext: [(videoID: Int64, path: String)] = []) {
        if path == currentPath, let player {
            self.upNext = upNext.isEmpty ? self.upNext : upNext
            player.rate = rate
            return
        }
        stop()
        self.upNext = upNext
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        let player = AVPlayer(playerItem: item)
        player.isMuted = muted
        self.player = player
        currentPath = path
        currentVideoID = videoID
        currentTime = 0
        duration = 0
        Task {
            let total = (try? await item.asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
            if total.isFinite { duration = total }
            // "nearly finished" = the last 5% (at most 10 s): those start over, everything else resumes
            let nearEnd = total > 0 ? min(10, total * 0.05) : 0
            if let saved = await db.position(path), saved > 1, total == 0 || saved < total - nearEnd {
                await player.seek(to: CMTime(seconds: saved, preferredTimescale: 600))
                currentTime = saved
            }
            player.rate = rate
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(CMTimeGetSeconds(t)) }
        }
        rateObserver = player.observe(\.rate, options: [.new]) { [weak self] p, _ in
            let playing = p.rate != 0
            Task { @MainActor in
                guard let self else { return }
                if self.isPlaying, !playing { self.savePosition() }
                self.isPlaying = playing
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished() }
        }
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.rate == 0 { player.rate = rate } else { player.pause() }
    }

    func pause() { player?.pause() }

    func seek(to seconds: Double) {
        guard let player else { return }
        let target = max(0, duration > 0 ? min(seconds, duration - 0.5) : seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
        savePosition()
    }

    func skip(_ seconds: Double) { seek(to: currentTime + seconds) }

    /// Saves where you are and releases the player.
    func stop() {
        savePosition()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        rateObserver?.invalidate()
        player?.pause()
        player = nil
        timeObserver = nil
        endObserver = nil
        rateObserver = nil
        currentPath = nil
        currentVideoID = nil
        isPlaying = false
        upNext = []
    }

    /// Saves the position and waits for it to be written (used when quitting).
    func savePositionNow() async {
        guard let path = currentPath, currentTime > 0 else { return }
        try? await db.savePosition(path, position: currentTime, duration: duration > 0 ? duration : nil)
    }

    func savePosition() {
        guard let path = currentPath, currentTime > 0 else { return }
        let (position, total) = (currentTime, duration > 0 ? duration : nil)
        lastSaved = Date()
        Task { try? await db.savePosition(path, position: position, duration: total) }
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        if Date().timeIntervalSince(lastSaved) > 5, isPlaying { savePosition() }
    }

    private func finished() {
        // finished: next time this file starts from the beginning
        if let path = currentPath { Task { try? await db.savePosition(path, position: 0, duration: duration) } }
        currentTime = 0
        guard let next = upNext.first else { isPlaying = false; return }
        let rest = Array(upNext.dropFirst())
        let keepRate = rate
        stop()
        rate = keepRate
        play(path: next.path, videoID: next.videoID, upNext: rest)
        onAdvance(next.videoID)
    }
}
