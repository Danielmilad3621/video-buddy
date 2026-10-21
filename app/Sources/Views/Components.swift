// Small building blocks shared by every screen.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A raised surface: cards inside a panel.
struct CardStyle: ViewModifier {
    @Environment(\.palette) private var p
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.border.opacity(0.7)))
    }
}

/// A column of the window (the video column, the AI panel, the mini-player): one step above the background.
struct PanelStyle: ViewModifier {
    @Environment(\.palette) private var p
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(p.sidebar))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.border.opacity(0.55)))
    }
}

extension View {
    func cardStyle(padding: CGFloat = 16) -> some View { modifier(CardStyle(padding: padding)) }
    func panelStyle() -> some View { modifier(PanelStyle()) }
}

/// The red action (Summarize, Play).
struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 46
    var font: Font = .title3.weight(.semibold)
    var iconOnly = false
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, height: height, font: font, iconOnly: iconOnly)
    }

    // isEnabled must be read inside a view: a ButtonStyle's own environment is where the style was applied
    private struct Styled: View {
        @Environment(\.palette) private var p
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false
        let configuration: Configuration
        let height: CGFloat
        let font: Font
        let iconOnly: Bool
        var body: some View {
            Group {
                if iconOnly { configuration.label.labelStyle(.iconOnly) } else { configuration.label.labelStyle(.titleAndIcon) }
            }
            .font(font)
            .foregroundStyle(.white)
            .padding(.horizontal, iconOnly ? 14 : (height > 40 ? 24 : 14))
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.accentGradient))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hovering && enabled ? 0.08 : 0)))
            .shadow(color: p.accent.opacity(enabled ? 0.35 : 0), radius: 10, y: 2)
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.55)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Charcoal buttons (Video, Audio, Show in Finder…).
struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 46
    var font: Font = .title3
    var iconOnly = false
    var hPadding: CGFloat? = nil
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, height: height, font: font, iconOnly: iconOnly, hPadding: hPadding)
    }

    private struct Styled: View {
        @Environment(\.palette) private var p
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false
        let configuration: Configuration
        let height: CGFloat
        let font: Font
        let iconOnly: Bool
        let hPadding: CGFloat?
        var body: some View {
            Group {
                if iconOnly { configuration.label.labelStyle(.iconOnly) } else { configuration.label.labelStyle(.titleAndIcon) }
            }
            .font(font)
            .padding(.horizontal, hPadding ?? (iconOnly ? 12 : (height > 40 ? 22 : 12)))
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(configuration.isPressed ? p.elevated : hovering && enabled ? p.hover : p.elevated))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.border))
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// The red-outlined Cancel.
struct OutlineButtonStyle: ButtonStyle {
    var height: CGFloat = 36
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, height: height) }

    private struct Styled: View {
        @Environment(\.palette) private var p
        @State private var hovering = false
        let configuration: Configuration
        let height: CGFloat
        var body: some View {
            configuration.label
                .font(.callout.weight(.semibold))
                .foregroundStyle(p.accent)
                .padding(.horizontal, 16)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(p.accent.opacity(hovering ? 0.16 : 0.06)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(p.accent.opacity(0.8)))
                .opacity(configuration.isPressed ? 0.75 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// A checkbox with a red tick, for "+ Transcript". Still a toggle to VoiceOver.
struct AccentCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }

    private struct Styled: View {
        @Environment(\.palette) private var p
        let configuration: Configuration
        var body: some View {
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(configuration.isOn ? AnyShapeStyle(p.accentGradient) : AnyShapeStyle(Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(configuration.isOn ? .clear : p.secondary, lineWidth: 1.5))
                        .overlay {
                            if configuration.isOn { Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(.white) }
                        }
                        .frame(width: 22, height: 22)
                    configuration.label.font(.title3.weight(.medium)).fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
        }
    }
}

/// Compact icon-only button with a tooltip and an accessibility label.
struct IconButton: View {
    @Environment(\.palette) private var p
    let icon: String
    let label: String
    var tint: Color?
    var size: CGFloat = 30
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.body.weight(.medium))
                .frame(width: size, height: size - 2)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? p.hover.opacity(0.7) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? p.secondary)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

struct ChipButton: View {
    @Environment(\.palette) private var p
    let title: String
    var icon: String?
    var iconOnly = false
    var compact = false
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon) }
                if !iconOnly { Text(title) }
            }
            .font(compact ? .caption.weight(.semibold) : .callout.weight(.medium))
            .padding(.horizontal, compact ? 9 : 12)
            .frame(height: compact ? 27 : 30)
            .foregroundStyle(selected ? .white : p.text.opacity(0.9))
            .background(Capsule().fill(selected ? AnyShapeStyle(p.accentGradient) : AnyShapeStyle(hovering ? p.hover : p.elevated)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(iconOnly ? title : "")
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Two or three choices in one capsule (Grouped | All Videos), the selected one raised.
struct SegmentedToggle: View {
    @Environment(\.palette) private var p
    let options: [(title: String, icon: String)]
    @Binding var selection: String
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.title) { o in
                let on = selection == o.title
                Button { selection = o.title } label: {
                    Label(o.title, systemImage: o.icon)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).frame(height: 26)
                        .foregroundStyle(on ? p.text : p.secondary)
                        .background(Capsule().fill(on ? p.hover : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(p.elevated))
        .fixedSize()
    }
}

/// The red round play button on playlist rows and cards.
struct PlayCircle: View {
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    let label: String
    var size: CGFloat = 34
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill").font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(.white)
                .offset(x: size * 0.03)
                .frame(width: size, height: size)
                .background(Circle().fill(p.accentGradient))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A heading for a library column (Queue, Downloads, Playlists) with room for actions on the right.
struct SectionHeader<Trailing: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title3)
            Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 6)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, icon: String) { self.init(title: title, icon: icon) { EmptyView() } }
}

struct SearchField: View {
    @Environment(\.palette) private var p
    @Binding var text: String
    let prompt: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(p.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                IconButton(icon: "xmark.circle.fill", label: "Clear search", size: 24) { text = "" }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(p.card))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(p.border))
    }
}

struct Thumbnail: View {
    @Environment(\.palette) private var p
    let url: String?
    var localPath: String? = nil   // saved copy on this Mac; preferred, so thumbnails show offline
    var duration: Double? = nil    // shown as a badge when set
    var cornerRadius: CGFloat = 9
    var badgeFont: Font = .caption.weight(.semibold)
    var icon = "play.rectangle.fill"

    var body: some View {
        Color.clear
            .overlay {
                if let localPath, let image = NSImage(contentsOfFile: localPath) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else if let s = url, let u = URL(string: s) {
                    AsyncImage(url: u) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() } else { placeholder }
                    }
                } else {
                    placeholder
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let d = Fmt.duration(duration) {
                    Text(d).font(badgeFont).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 5))
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
    }

    private var placeholder: some View {
        LinearGradient(colors: [p.elevated, p.accentDark.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(Image(systemName: icon).font(.title2).foregroundStyle(p.secondary))
    }
}

/// One word for where an entry stands. It only claims a file when that file is on this Mac right now.
struct StatusPill: View {
    @Environment(\.palette) private var p
    let video: Video
    let onMac: Bool
    var audioOnly = false   // only an audio file is here: it plays, but it isn't the video offline
    var compact = false     // icon only, for narrow rows (the word stays as the tooltip and for VoiceOver)
    var body: some View {
        let (text, icon, color) = style
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(color)
            if !compact { Text(text).foregroundStyle(p.text.opacity(0.88)) }
        }
        .help(text)
        .accessibilityLabel(text)
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(p.elevated))
        .overlay(Capsule().strokeBorder(p.border.opacity(0.8)))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var style: (String, String, Color) {
        if video.latestStatus == .running { return ("Processing", "hourglass", p.accent) }
        if video.latestStatus == .queued { return ("Queued", "clock.fill", p.accent) }
        if video.hasSummary { return ("Summarized", "sparkles", p.accent) }
        if onMac { return audioOnly ? ("Audio Offline", "headphones", p.text) : ("Available Offline", "arrow.down.circle.fill", p.text) }
        if video.hasVideo || video.hasAudio { return ("File missing", "questionmark.folder", p.secondary) }
        switch video.latestStatus {
        case .cancelled: return ("Cancelled", "xmark.circle", p.secondary)
        case .interrupted: return ("Interrupted", "exclamationmark.circle", p.orange)
        default: return ("Failed", "exclamationmark.triangle.fill", p.accent)
        }
    }
}

/// The channel's initial: the app never saves channel pictures, so it doesn't pretend to have one.
struct Avatar: View {
    @Environment(\.palette) private var p
    let name: String?
    var size: CGFloat = 40
    var body: some View {
        Text(String((name?.nilIfBlank ?? "?").prefix(1)).uppercased())
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(p.text)
            .frame(width: size, height: size)
            .background(Circle().fill(LinearGradient(colors: [p.hover, p.elevated], startPoint: .top, endPoint: .bottom)))
            .overlay(Circle().strokeBorder(p.border))
            .accessibilityHidden(true)
    }
}

struct MetaRow: View {
    @Environment(\.palette) private var p
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(p.secondary)
            Text(text).foregroundStyle(p.text.opacity(0.9)).lineLimit(2)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

struct EmptyState: View {
    @Environment(\.palette) private var p
    let icon: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 32)).foregroundStyle(p.accent.opacity(0.85))
            Text(title).font(.title3.weight(.semibold))
            Text(message).foregroundStyle(p.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// Wraps children onto new rows when they don't fit (filter chips, tags).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

enum FileOps {
    static func exists(_ path: String?) -> Bool { path.map { FileManager.default.fileExists(atPath: $0) } ?? false }
    static func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    static func open(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    static func openLink(_ s: String?) { if let s, let u = URL(string: s) { NSWorkspace.shared.open(u) } }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Native save dialog; the user picks the place, so nothing is written without their choice.
    @MainActor static func export(_ text: String, suggestedName: String, ext: String) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName.replacingOccurrences(of: "/", with: "-") + "." + ext
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
    }
}
