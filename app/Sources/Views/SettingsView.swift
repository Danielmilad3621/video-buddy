// Native Settings window (⌘,).
import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("summaryLanguage") private var language = SummaryLanguage.english.rawValue
    @AppStorage("summaryFormat") private var format = SummaryFormat.standard.rawValue
    @AppStorage("downloadDir") private var downloadDir = ""
    @AppStorage("videoQuality") private var videoQuality = VideoQuality.standard.rawValue
    @AppStorage("retentionDays") private var retention = 0
    @AppStorage("appearance") private var appearance = Appearance.dark.rawValue

    var body: some View {
        Form {
            Section("Summaries") {
                Picker("Language", selection: $language) {
                    ForEach(SummaryLanguage.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Picker("Format", selection: $format) {
                    ForEach(SummaryFormat.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Text((SummaryFormat(rawValue: format) ?? .standard).detail).font(.callout).foregroundStyle(.secondary)
                Text("Used for new summaries in the app. Raycast always uses Standard in English.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Downloads") {
                LabeledContent("Save to") {
                    Text(downloadDir.nilIfBlank ?? AppSettings.defaultDownloadDir).lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    Button("Choose…") { choose() }
                    Button("Use Default") { downloadDir = "" }.disabled(downloadDir.isEmpty)
                }
                Picker("Video quality", selection: $videoQuality) {
                    ForEach(VideoQuality.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Text("For Video downloads from the app. 720p is roughly half the size, handy for filling a laptop before a flight.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Raycast commands always save to ~/Downloads/cobalt at the default quality.").font(.caption).foregroundStyle(.secondary)
            }
            Section("History") {
                Picker("Keep history", selection: $retention) {
                    Text("Forever").tag(0)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                }
                Text("Favorites are always kept. Removing history never deletes your files.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Import from Downloads Folder…") { model.runImport() }
                    Button("Show Database in Finder") { model.revealDatabase() }
                }
                if let status = model.importStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: retention) { model.applyRetention() }
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
