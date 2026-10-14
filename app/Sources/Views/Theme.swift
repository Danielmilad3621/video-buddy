// Colors from the design spec. Dark is the default; the light palette keeps the same roles.
import SwiftUI

struct Palette {
    var bg, sidebar, card, elevated: Color
    var blue, green, purple, orange, gold, red: Color
    var text, secondary, border: Color

    static let dark = Palette(
        bg: Color(hex: 0x0B1220), sidebar: Color(hex: 0x101A2B), card: Color(hex: 0x131F30), elevated: Color(hex: 0x1B2A40),
        blue: Color(hex: 0x087CFF), green: Color(hex: 0x19C785), purple: Color(hex: 0x8E6CFF), orange: Color(hex: 0xF5A524),
        gold: Color(hex: 0xFFC53D), red: Color(hex: 0xFF5C6C),
        text: Color(hex: 0xF5F7FF), secondary: Color(hex: 0xA3B1C6), border: Color(hex: 0x2B3B52))

    static let light = Palette(
        bg: Color(hex: 0xF3F6FB), sidebar: Color(hex: 0xE8EEF6), card: Color(hex: 0xFFFFFF), elevated: Color(hex: 0xEEF2F8),
        blue: Color(hex: 0x0A6CFF), green: Color(hex: 0x0E9F63), purple: Color(hex: 0x6E46E0), orange: Color(hex: 0xD07B00),
        gold: Color(hex: 0xE0A100), red: Color(hex: 0xD93649),
        text: Color(hex: 0x0E1726), secondary: Color(hex: 0x56677F), border: Color(hex: 0xD3DCE8))
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
            content.environment(\.palette, p).tint(p.blue).foregroundStyle(p.text)
        }
    }
}
