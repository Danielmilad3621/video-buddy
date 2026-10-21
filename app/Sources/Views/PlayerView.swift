// The built-in player (Apple's AVPlayerView: full screen, Picture in Picture) in the video column, and the
// mini-player along the bottom. Both drive the one PlaybackController, so only one thing ever plays.
import AVKit
import SwiftUI

/// AVPlayerView for SwiftUI, with Apple's floating controls over the picture.
struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// The 16:9 surface: the playing video, or the thumbnail with a ▶ button.
struct DetailMedia: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let video: Video

    var body: some View {
        let playback = model.playback
        let file = model.store.playable(for: video.id)
        let playingHere = playback.currentVideoID == video.id && playback.player != nil
        VStack(alignment: .leading, spacing: 8) {
            if playingHere, let player = playback.player, file?.role == .video {
                AVPlayerViewRepresentable(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Thumbnail(url: video.thumbnailURL, localPath: video.thumbnailPath, duration: playingHere ? nil : video.duration,
                          cornerRadius: 12, badgeFont: .callout.weight(.semibold))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        if playingHere {
                            // audio: the picture stays, the mini-player has the controls
                            Label(playback.isPlaying ? "Playing audio" : "Paused", systemImage: playback.isPlaying ? "waveform" : "pause.fill")
                                .font(.headline).foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Capsule().fill(.black.opacity(0.6)))
                        } else if file != nil {
                            Button { model.play(video) } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 26, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 66, height: 66)
                                    .background(Circle().fill(p.accentGradient))
                                    .shadow(color: .black.opacity(0.4), radius: 10)
                            }
                            .buttonStyle(.plain)
                            .help("Play on this Mac (works offline)")
                            .accessibilityLabel("Play")
                        }
                    }
            }
            if playingHere { PlayerControls() }
        }
    }
}

/// ±10 s and speed, under the picture (play, scrubbing, volume, full screen and PiP are in the player itself).
struct PlayerControls: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p

    var body: some View {
        @Bindable var playback = model.playback
        HStack(spacing: 6) {
            IconButton(icon: "gobackward.10", label: "Back 10 seconds (⌘[)", tint: p.text) { playback.skip(-10) }
            IconButton(icon: "goforward.10", label: "Forward 10 seconds (⌘])", tint: p.text) { playback.skip(10) }
            Text("\(Fmt.timestamp(playback.currentTime)) / \(Fmt.duration(playback.duration) ?? "--:--")")
                .font(.caption.monospacedDigit()).foregroundStyle(p.secondary)
            Spacer(minLength: 4)
            Menu {
                ForEach([0.75, 1, 1.25, 1.5, 1.75, 2] as [Float], id: \.self) { r in
                    Button(r == playback.rate ? "✓ \(speed(r))" : speed(r)) { playback.rate = r }
                }
            } label: {
                Label(speed(playback.rate), systemImage: "gauge.with.dots.needle.50percent").font(.caption.weight(.semibold).monospacedDigit())
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Playback speed")
        }
    }

    private func speed(_ r: Float) -> String { r == 1 ? "1×" : String(format: "%g×", r) }
}

/// The bottom bar: whatever is playing, in every section, synced with the player above (same AVPlayer).
struct MiniPlayerBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @State private var video: Video?
    @State private var scrub: Double?
    @State private var showUpNext = false

    var body: some View {
        @Bindable var playback = model.playback
        let total = max(playback.duration, 1)
        HStack(spacing: 14) {
            Button {
                if let id = playback.currentVideoID {
                    if model.section == .settings || model.section == .queue { model.section = .library }
                    model.store.select(id)
                }
            } label: {
                HStack(spacing: 10) {
                    Thumbnail(url: video?.thumbnailURL, localPath: video?.thumbnailPath, cornerRadius: 6)
                        .frame(width: 64, height: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(video?.displayTitle ?? "Playing").font(.callout.weight(.semibold)).lineLimit(1)
                        Text(video?.displayChannel ?? "").font(.caption).foregroundStyle(p.secondary).lineLimit(1)
                    }
                }
                .frame(width: 250, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show this video")

            HStack(spacing: 10) {
                IconButton(icon: "backward.fill", label: playback.hasPrevious ? "Previous (or back to the start)" : "Back to the start",
                           tint: p.text) { playback.previous() }
                Button { playback.togglePlayPause() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(p.bg)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(p.text))
                }
                .buttonStyle(.plain)
                .help("Play or pause (⌘K)")
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                IconButton(icon: "forward.fill", label: "Next in Up Next", tint: p.text) { playback.next() }
                    .disabled(playback.upNext.isEmpty)
                    .opacity(playback.upNext.isEmpty ? 0.35 : 1)
            }

            HStack(spacing: 10) {
                Text(Fmt.timestamp(scrub ?? playback.currentTime)).font(.caption.monospacedDigit()).foregroundStyle(p.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
                Slider(value: Binding(get: { min(scrub ?? playback.currentTime, total) }, set: { scrub = $0 }), in: 0...total, onEditingChanged: { editing in
                    if !editing, let s = scrub { playback.seek(to: s); scrub = nil }
                })
                .controlSize(.small)
                .accessibilityLabel("Playback position")
                Text(Fmt.duration(playback.duration) ?? "--:--").font(.caption.monospacedDigit()).foregroundStyle(p.secondary)
                    .frame(minWidth: 44, alignment: .leading)
            }
            .frame(minWidth: 200, maxWidth: .infinity)

            HStack(spacing: 6) {
                Image(systemName: playback.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill").foregroundStyle(p.secondary)
                    .frame(width: 20)
                Slider(value: $playback.volume, in: 0...1).controlSize(.small).frame(width: 90)
                    .accessibilityLabel("Volume")
            }
            IconButton(icon: "list.bullet", label: playback.upNext.isEmpty ? "Up Next is empty (Play All in a playlist fills it)" : "Up Next (\(playback.upNext.count))",
                       tint: playback.upNext.isEmpty ? p.secondary : p.text) { showUpNext.toggle() }
                .popover(isPresented: $showUpNext, arrowEdge: .top) { UpNextList().environment(model) }
            IconButton(icon: "xmark", label: "Close the player (your place is saved)") { playback.stop() }
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
        .panelStyle()
        .task(id: playback.currentVideoID) {
            guard let id = playback.currentVideoID else { video = nil; return }
            video = (try? await model.store.db.video(id)) ?? nil
        }
    }
}

struct UpNextList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @State private var titles: [Int64: String] = [:]

    var body: some View {
        let items = model.playback.upNext
        VStack(alignment: .leading, spacing: 8) {
            Text("Up Next").font(.headline)
            if items.isEmpty {
                Text("Nothing queued to play. Use Play All in one of My Playlists.").font(.callout).foregroundStyle(p.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            HStack(spacing: 8) {
                                Text("\(i + 1).").monospacedDigit().foregroundStyle(p.secondary)
                                Text(titles[item.videoID] ?? (item.path as NSString).lastPathComponent).lineLimit(1)
                            }
                            .font(.callout)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(14)
        .frame(width: 340)
        .task(id: items.count) {
            for item in items.prefix(50) where titles[item.videoID] == nil {
                if let v = try? await model.store.db.video(item.videoID) { titles[item.videoID] = v.displayTitle }
            }
        }
    }
}
