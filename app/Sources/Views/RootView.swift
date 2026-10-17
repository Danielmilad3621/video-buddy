// Window layout from the mockup: sidebar | toolbar over (history browser | job banner + details).
import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false

    var body: some View {
        @Bindable var model = model
        GeometryReader { geo in
            let compactSidebar = sidebarCollapsed || geo.size.width < 1180
            let sidebarWidth: CGFloat = compactSidebar ? 76 : 236
            let content = geo.size.width - sidebarWidth - 40
            let stacked = content < 1080          // details card goes above the tabs instead of beside them
            let center = min(max(content * (stacked ? 0.42 : 0.33), 340), 500)
            HStack(spacing: 0) {
                Sidebar(compact: compactSidebar) { sidebarCollapsed.toggle() }
                    .frame(width: sidebarWidth)
                VStack(alignment: .leading, spacing: 14) {
                    TitleRow()
                    TopBar()
                    if let warning = model.startupWarning { WarningStrip(text: warning) { model.startupWarning = nil } }
                    if !model.network.isOnline { OfflineStrip() }
                    HStack(alignment: .top, spacing: 16) {
                        CenterColumn().frame(width: center)
                        RightColumn(stacked: stacked)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
            }
        }
        .background(p.bg)
        .ignoresSafeArea()
        .task { await model.launch() }
        .alert("Import your existing downloads?", isPresented: Binding(get: { model.importOffer != nil }, set: { if !$0 { model.importOffer = nil } })) {
            Button("Import") { model.runImport(model.importOffer) }
            Button("Not Now", role: .cancel) { model.declineImport() }
        } message: {
            Text("Found \(model.importOffer?.count ?? 0) videos in \(AppSettings.downloadDir). Their summaries, transcripts and files will appear in History. Files are only read: nothing is moved, renamed or deleted.")
        }
        .confirmationDialog("Remove “\(model.pendingRemoval?.displayTitle ?? "")” from history?",
                            isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
                            titleVisibility: .visible) {
            Button("Remove from History", role: .destructive) { model.confirmRemoval() }
        } message: {
            Text("Its saved summary and transcript are removed from the app. Downloaded files and the files in your downloads folder stay where they are.")
        }
        .overlay(alignment: .bottom) { NoticeToast() }
    }
}

struct TitleRow: View {
    @Environment(\.palette) private var p
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30).accessibilityHidden(true)
            Text("Video Summarizer").font(.title2.weight(.semibold))
            Spacer()
            IconButton(icon: "gearshape", label: "Settings", tint: p.text) { openSettings() }
                .font(.title2)
        }
        .frame(height: 56)
        .padding(.top, 4)
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @Environment(\.openSettings) private var openSettings
    let compact: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.frame(height: 68) // room for the window buttons
            ForEach(AppSection.allCases) { s in
                let selected = model.section == s
                Button {
                    if s == .settings { openSettings() } else { model.section = s }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: s.icon).font(.title3).frame(width: 26)
                        if !compact { Text(s.rawValue).font(.title3) }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 11)
                    .padding(.horizontal, compact ? 12 : 16)
                    .foregroundStyle(selected ? p.text : p.text.opacity(0.82))
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? p.blue.opacity(0.24) : .clear))
                    .overlay(alignment: .leading) {
                        if selected { Capsule().fill(p.blue).frame(width: 3, height: 22).offset(x: 1) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(s.rawValue)
                .accessibilityLabel(s.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 16)
            if !compact { StatsCard() }
            IconButton(icon: compact ? "sidebar.left" : "sidebar.leading", label: compact ? "Expand sidebar" : "Collapse sidebar", action: toggle)
                .padding(.leading, compact ? 10 : 4)
        }
        .padding(.horizontal, compact ? 10 : 14)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity)
        .background(p.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(p.border.opacity(0.6)).frame(width: 1) }
    }
}

struct StatsCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    var body: some View {
        let s = model.store.stats
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.fill").foregroundStyle(p.blue).font(.title3)
                Text("Your Stats").font(.headline)
            }
            stat("clock.fill", p.blue, "\(s.videos)", "Videos processed")
            stat("hourglass", p.purple, Fmt.watchTime(s.watchSeconds), "Watch time summarized")
            stat("doc.text.fill", p.green, "\(s.summaries)", "Summaries saved")
            stat("arrow.down.to.line", p.orange, "\(s.downloads)", "Videos downloaded")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(p.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.border.opacity(0.8)))
    }

    private func stat(_ icon: String, _ color: Color, _ value: String, _ label: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(color.opacity(0.18)))
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.title2.weight(.bold)).monospacedDigit()
                Text(label).font(.caption).foregroundStyle(p.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct TopBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "link").foregroundStyle(p.secondary).font(.title3)
                    TextField("Paste a YouTube or video link", text: $model.link)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($focused)
                        .onSubmit { model.start(.summary) }
                        .accessibilityLabel("Video link")
                    if !model.link.isEmpty {
                        IconButton(icon: "xmark.circle.fill", label: "Clear link") { model.link = "" }
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(p.card))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(focused ? p.blue : p.border, lineWidth: focused ? 2 : 1))
                .shadow(color: p.blue.opacity(focused ? 0.35 : 0), radius: 10)

                Button { model.pasteLink() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .buttonStyle(SecondaryButtonStyle(height: 52))
                    .help("Paste a link from the clipboard (⇧⌘V)")
            }
            HStack(spacing: 12) {
                Button { model.start(.summary) } label: { Label("Summarize", systemImage: "brain") }
                    .buttonStyle(PrimaryButtonStyle())
                    .help("Download, transcribe on-device and summarize (⌘↩)")
                Button { model.start(.audio) } label: { Label("Audio", systemImage: "music.note") }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Save the audio as mp3 (⇧⌘A)")
                Button { model.start(.video) } label: { Label("Video", systemImage: "film") }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Save the video (⇧⌘D)")
                Spacer()
            }
            .disabled(model.link.nilIfBlank == nil)
        }
        .onChange(of: model.focusLinkToken) { focused = true }
    }
}

/// No internet: say what still works, so the app is useful on a plane.
struct OfflineStrip: View {
    @Environment(\.palette) private var p
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash").foregroundStyle(p.blue)
            Text("You're offline: your library, saved summaries and downloaded videos all work. Downloads and new summaries wait in the queue until you're back online.")
                .font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(p.blue.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(p.blue.opacity(0.4)))
        .accessibilityElement(children: .combine)
    }
}

struct WarningStrip: View {
    @Environment(\.palette) private var p
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(p.orange)
            Text(text).font(.callout)
            Spacer()
            IconButton(icon: "xmark", label: "Dismiss", action: dismiss)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(p.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(p.orange.opacity(0.4)))
    }
}

/// Short confirmations ("Summary copied"), gone after a few seconds.
struct NoticeToast: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let notice = model.notice {
                Text(notice)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(p.elevated))
                    .overlay(Capsule().strokeBorder(p.border))
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                    .padding(.bottom, 24)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(3))
                        if model.notice == notice { model.notice = nil }
                    }
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.notice)
    }
}
