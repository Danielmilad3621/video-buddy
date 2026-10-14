// Small building blocks shared by every screen.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CardStyle: ViewModifier {
    @Environment(\.palette) private var p
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(p.card))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.border.opacity(0.8)))
    }
}

extension View {
    func cardStyle(padding: CGFloat = 16) -> some View { modifier(CardStyle(padding: padding)) }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    var height: CGFloat = 46
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.white)
            .padding(.horizontal, 26)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(colors: [p.blue, p.blue.opacity(0.82)], startPoint: .top, endPoint: .bottom)))
            .shadow(color: p.blue.opacity(enabled ? 0.35 : 0), radius: 8, y: 2)
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    var height: CGFloat = 46
    var font: Font = .title3
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, height > 40 ? 22 : 12)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(configuration.isPressed ? p.elevated.opacity(0.6) : p.elevated))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(p.border))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// Compact icon-only button with a tooltip and an accessibility label.
struct IconButton: View {
    @Environment(\.palette) private var p
    let icon: String
    let label: String
    var tint: Color?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.body.weight(.medium)).frame(width: 30, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? p.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct ChipButton: View {
    @Environment(\.palette) private var p
    let title: String
    var icon: String?
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 16)
            .frame(height: 32)
            .foregroundStyle(selected ? .white : p.text)
            .background(Capsule().fill(selected ? p.blue : p.elevated.opacity(0.6)))
            .overlay(Capsule().strokeBorder(selected ? .clear : p.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
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
                IconButton(icon: "xmark.circle.fill", label: "Clear search") { text = "" }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(p.bg.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(p.border))
    }
}

struct Thumbnail: View {
    @Environment(\.palette) private var p
    let url: String?
    let duration: Double?
    var cornerRadius: CGFloat = 9
    var badgeFont: Font = .caption.weight(.semibold)
    var icon = "play.rectangle.fill"

    var body: some View {
        Color.clear
            .overlay {
                if let s = url, let u = URL(string: s) {
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
        LinearGradient(colors: [p.elevated, p.blue.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(Image(systemName: icon).font(.title2).foregroundStyle(p.secondary))
    }
}

struct StatusPill: View {
    @Environment(\.palette) private var p
    let video: Video
    var body: some View {
        let (text, icon, color) = style
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
            .overlay(Capsule().strokeBorder(color.opacity(0.45)))
            .fixedSize()
    }

    private var style: (String, String, Color) {
        if video.latestStatus == .running { return ("Processing", "hourglass", p.blue) }
        if video.hasSummary { return ("Summarized", "checkmark.seal.fill", p.green) }
        if video.hasVideo { return ("Downloaded", "checkmark.seal.fill", p.blue) }
        if video.hasAudio { return ("Audio", "waveform", p.purple) }
        switch video.latestStatus {
        case .cancelled: return ("Cancelled", "xmark.circle", p.secondary)
        case .interrupted: return ("Interrupted", "exclamationmark.circle", p.orange)
        default: return ("Failed", "exclamationmark.triangle.fill", p.red)
        }
    }
}

struct Avatar: View {
    @Environment(\.palette) private var p
    let name: String?
    var body: some View {
        Text(String((name?.nilIfBlank ?? "?").prefix(1)).lowercased())
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Circle().fill(LinearGradient(colors: [Color(hex: 0x14B8A6), Color(hex: 0x0E7490)],
                                                     startPoint: .top, endPoint: .bottom)))
            .accessibilityHidden(true)
    }
}

struct MetaRow: View {
    @Environment(\.palette) private var p
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(p.secondary)
            Text(text).foregroundStyle(p.text.opacity(0.9)).lineLimit(2)
        }
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
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(p.blue.opacity(0.8))
            Text(title).font(.title3.weight(.semibold))
            Text(message).foregroundStyle(p.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// Wraps children onto new rows when they don't fit (filter chips).
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
