// Video Buddy colors: black and grey surfaces with one red accent, after Apple Music's dark theme.
// Dark is the default; the light palette keeps the same roles. Green, orange and gold are for status only.
import SwiftUI

struct Palette {
    var bg, sidebar, card, elevated, hover: Color
    var accent, accentDark: Color
    var green, orange, gold: Color
    var text, secondary, border: Color

    static let dark = Palette(
        bg: Color(hex: 0x09090B), sidebar: Color(hex: 0x111114), card: Color(hex: 0x191A1E), elevated: Color(hex: 0x222327),
        hover: Color(hex: 0x2D2E33), accent: Color(hex: 0xFA233B), accentDark: Color(hex: 0xB8132C),
        green: Color(hex: 0x30D158), orange: Color(hex: 0xFF9F0A), gold: Color(hex: 0xFFC53D),
        text: Color(hex: 0xF5F5F7), secondary: Color(hex: 0xA0A0A8), border: Color(hex: 0x33343A))

    static let light = Palette(
        bg: Color(hex: 0xF5F5F7), sidebar: Color(hex: 0xEBEBEF), card: Color(hex: 0xFFFFFF), elevated: Color(hex: 0xF0F0F3),
        hover: Color(hex: 0xE4E4E9), accent: Color(hex: 0xFA233B), accentDark: Color(hex: 0xC0142D),
        green: Color(hex: 0x1F9D49), orange: Color(hex: 0xC86A00), gold: Color(hex: 0xD9A100),
        text: Color(hex: 0x1D1D1F), secondary: Color(hex: 0x6E6E73), border: Color(hex: 0xD2D2D7))

    /// A status label's color (green: on this Mac; red: under way; orange: needs you; grey: nothing yet).
    func tone(_ t: StatusLabel.Tone) -> Color {
        switch t {
        case .good: green
        case .accent: accent
        case .warning: orange
        case .neutral: secondary
        }
    }

    /// The red tile behind the logo and the primary button.
    var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accentDark], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

private struct PaletteKey: EnvironmentKey { static let defaultValue = Palette.dark }

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Applies the chosen appearance and hands the matching palette to everything inside.
struct ThemedRoot<Content: View>: View {
    @AppStorage("appearance") private var appearance = Appearance.dark.rawValue
    @ViewBuilder var content: Content

    var body: some View {
        Inner(content: content).preferredColorScheme((Appearance(rawValue: appearance) ?? .dark).scheme)
    }

    private struct Inner: View {
        @Environment(\.colorScheme) private var scheme
        let content: Content
        var body: some View {
            let p = scheme == .dark ? Palette.dark : Palette.light
            content.environment(\.palette, p).tint(p.accent).foregroundStyle(p.text)
        }
    }
}
