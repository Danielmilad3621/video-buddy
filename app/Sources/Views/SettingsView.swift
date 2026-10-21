// Settings: in the window (sidebar → Settings) and in the ⌘, window. Same view, same UserDefaults keys.
import AppKit
import SwiftUI

/// The ⌘, window.
struct SettingsView: View {
    var body: some View {
        ScrollView { SettingsContent().padding(20) }
            .frame(width: 600, height: 640)
    }
}

/// The Settings section inside the main window.
struct SettingsPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Settings", icon: "gearshape")
                SettingsContent()
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct SettingsContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @AppStorage("summaryLanguage") private var language = SummaryLanguage.english.rawValue
    @AppStorage("summaryFormat") private var format = SummaryFormat.standard.rawValue
    @AppStorage("downloadDir") private var downloadDir = ""
    @AppStorage("videoQuality") private var videoQuality = VideoQuality.standard.rawValue
    @AppStorage("retentionDays") private var retention = 0
    @AppStorage("appearance") private var appearance = Appearance.dark.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("Summaries", "sparkles") {
                row("Language") {
                    Picker("Language", selection: $language) {
                        ForEach(SummaryLanguage.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                }
                row("Format") {
                    Picker("Format", selection: $format) {
                        ForEach(SummaryFormat.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                }
                note((SummaryFormat(rawValue: format) ?? .standard).detail)
                note("Used for new summaries in the app. Raycast always uses Standard in English.")
            }
            card("Downloads", "arrow.down.to.line") {
                HStack(spacing: 12) {
                    Text("Save to")
                    Spacer(minLength: 12)
                    Text(downloadDir.nilIfBlank ?? AppSettings.defaultDownloadDir).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(p.secondary).help(downloadDir.nilIfBlank ?? AppSettings.defaultDownloadDir)
                }
                HStack {
                    Button("Choose…") { choose() }
                    Button("Use Default") { downloadDir = "" }.disabled(downloadDir.isEmpty)
                }
                .buttonStyle(SecondaryButtonStyle(height: 30, font: .callout))
                row("Video quality") {
                    Picker("Video quality", selection: $videoQuality) {
                        ForEach(VideoQuality.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                }
                note("For Video downloads from the app. 720p is roughly half the size, handy for filling a laptop before a flight.")
                note("Raycast commands always save to ~/Downloads/cobalt at the default quality.")
            }
            card("Library", "rectangle.stack") {
                row("Keep history") {
                    Picker("Keep history", selection: $retention) {
                        Text("Forever").tag(0)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                    }
                }
                note("Favorites are always kept. Removing history never deletes your files.")
                HStack {
                    Button("Import from Downloads Folder…") { model.runImport() }
                    Button("Show Database in Finder") { model.revealDatabase() }
                }
                .buttonStyle(SecondaryButtonStyle(height: 30, font: .callout))
                if let status = model.importStatus { note(status) }
            }
            card("Appearance", "circle.lefthalf.filled") {
                row("Theme") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
            }
        }
        .onChange(of: retention) { model.applyRetention() }
    }

    private func card<Content: View>(_ title: String, _ icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(p.text)
                .labelStyle(.titleAndIcon)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(label)
            Spacer(minLength: 12)
            control().labelsHidden().fixedSize()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url { downloadDir = url.path }
    }
}
