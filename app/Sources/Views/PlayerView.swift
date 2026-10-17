// The built-in player in the detail panel: Apple's standard player view (controls, full screen, Picture in Picture)
// plus ±10 s and speed controls underneath.
import AVKit
import SwiftUI

/// AVPlayerView for SwiftUI. The full-screen button makes it a proper plane-seat player.
struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer
    var controlsOnly = false   // audio files: just the control bar

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = !controlsOnly
        view.allowsPictureInPicturePlayback = !controlsOnly
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// The thumbnail with a ▶ button, or the playing video, for the selected entry.
struct DetailMedia: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let video: Video
    let maxWidth: CGFloat?

    var body: some View {
        let playback = model.playback
        let file = model.store.playable(for: video.id)
        let playingHere = playback.currentVideoID == video.id && playback.player != nil
        VStack(alignment: .leading, spacing: 8) {
            if playingHere, let player = playback.player, file?.role == .video {
                AVPlayerViewRepresentable(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Thumbnail(url: video.thumbnailURL, localPath: video.thumbnailPath, duration: video.duration,
                          cornerRadius: 12, badgeFont: .callout.weight(.semibold))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        if file != nil, !playingHere {
                            Button { model.play(video) } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 26, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 64, height: 64)
                                    .background(Circle().fill(.black.opacity(0.55)))
                                    .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            .help("Play on this Mac (works offline)")
                            .accessibilityLabel("Play")
                        }
                    }
            }
            if playingHere, let player = playback.player {
                if file?.role == .audio {
                    AVPlayerViewRepresentable(player: player, controlsOnly: true).frame(height: 44)
                }
                PlayerControls()
            }
        }
        .frame(maxWidth: maxWidth ?? .infinity)
    }
}

struct PlayerControls: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p

    var body: some View {
        @Bindable var playback = model.playback
        HStack(spacing: 6) {
            IconButton(icon: "gobackward.10", label: "Back 10 seconds (⌘[)", tint: p.text) { playback.skip(-10) }
            IconButton(icon: playback.isPlaying ? "pause.fill" : "play.fill", label: "Play or pause", tint: p.text) { playback.togglePlayPause() }
            IconButton(icon: "goforward.10", label: "Forward 10 seconds (⌘])", tint: p.text) { playback.skip(10) }
            Text("\(Fmt.timestamp(playback.currentTime)) / \(Fmt.duration(playback.duration) ?? "--:--")")
                .font(.caption.monospacedDigit()).foregroundStyle(p.secondary)
            Spacer(minLength: 4)
            Menu {
                ForEach([0.75, 1, 1.25, 1.5, 1.75, 2] as [Float], id: \.self) { r in
                    Button(r == playback.rate ? "✓ \(speed(r))" : speed(r)) { playback.rate = r }
                }
            } label: {
                Text(speed(playback.rate)).font(.caption.weight(.semibold).monospacedDigit())
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Playback speed")
            if !playback.upNext.isEmpty {
                Text("\(playback.upNext.count) up next").font(.caption).foregroundStyle(p.secondary)
            }
            IconButton(icon: "xmark", label: "Close the player (your place is saved)") { playback.stop() }
        }
    }

    private func speed(_ r: Float) -> String { r == 1 ? "1×" : String(format: "%g×", r) }
}
