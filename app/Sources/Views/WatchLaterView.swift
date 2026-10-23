// 4.0 Phase 3: Watch Later, the library column's page for videos you saved while browsing (apart from the library).
// Each shows what this Mac has for it; Play Offline when the media is here, otherwise it opens on YouTube. Nothing on
// this page downloads or queues anything: downloads go through the browser bar and its authorization checks.
import SwiftUI

struct WatchLaterList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    @AppStorage("watchLaterSort") private var sort = WatchLaterSort.newest.rawValue
    @State private var search = ""
    @State private var selection: Set<String> = []
    @State private var confirmRemove: [String] = []
    @State private var scrollTarget: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        let all = model.store.watchLater
        let items = WatchLater.arrange(all, search: search, sort: WatchLaterSort(rawValue: sort) ?? .newest)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Watch Later").font(.title2.weight(.bold))
                Spacer()
                Text(summary(all)).font(.callout).foregroundStyle(p.secondary)
            }
            HStack(spacing: 8) {
                SearchField(text: $search, prompt: "Search Watch Later…").focused($searchFocused)
                sortMenu
            }
            if all.isEmpty {
                EmptyState(icon: "clock", title: "Nothing saved yet",
                           message: "On a YouTube video, press Save to Watch Later (⌘D). Nothing is downloaded.")
            } else if items.isEmpty {
                EmptyState(icon: "magnifyingglass", title: "No matches", message: "No saved title or channel matches “\(search)”.")
            } else {
                ScrollViewReader { scroller in
                    List(selection: $selection) {
                        ForEach(items) { WatchLaterRow(item: $0).tag($0.key).id($0.key) }
                    }
                    .onChange(of: scrollTarget) { if let k = scrollTarget { scroller.scrollTo(k, anchor: .center); scrollTarget = nil } }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: String.self) { keys in
                    menu(Array(keys), in: items)
                } primaryAction: { keys in
                    if keys.count == 1, let item = items.first(where: { keys.contains($0.key) }) { model.primaryAction(item) }
                }
                .onDeleteCommand { ask(Array(selection)) }
                .testProbe("watchLaterList")
            }
            if selection.count >= 2 { selectionBar(items) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: model.focusSearchToken) { searchFocused = true }
        // one saved video selected: if it's in the library, the right side shows it (and plays it); if not, nothing else does
        .onChange(of: selection) {
            guard selection.count == 1, let k = selection.first else { return }
            model.store.select(model.store.byKey[k]?.id)
        }
        .onChange(of: model.store.savedKeys) { selection.formIntersection(model.store.savedKeys) }
        .onAppear {
            if let k = model.watchLaterFocus { focus(k) }
            Task { await model.store.reload() }      // files may have changed while the page was hidden
        }
        .onChange(of: model.watchLaterFocus) { if let k = model.watchLaterFocus { focus(k) } }
        .alert(confirmRemove.count == 1 ? "Remove this video from Watch Later?" : "Remove \(confirmRemove.count) videos from Watch Later?",
               isPresented: Binding(get: { !confirmRemove.isEmpty }, set: { if !$0 { confirmRemove = [] } })) {
            Button("Remove", role: .destructive) { model.removeFromWatchLater(confirmRemove); confirmRemove = [] }
            Button("Cancel", role: .cancel) { confirmRemove = [] }
        } message: {
            Text("Files on this Mac aren't touched.")
        }
    }

    /// Show in Watch Later: that item, selected and scrolled to.
    private func focus(_ key: String) {
        selection = [key]
        model.watchLaterFocus = nil
        DispatchQueue.main.async { scrollTarget = key }
    }

    private func summary(_ all: [WatchLaterItem]) -> String {
        let total = all.compactMap(\.duration).reduce(0, +)
        return "\(all.count) \(all.count == 1 ? "video" : "videos")" + (total > 0 ? " · \(Fmt.duration(total) ?? "")" : "")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sort) {
                ForEach(WatchLaterSort.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down").font(.body.weight(.semibold))
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(p.card))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(p.border))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Sort: \(sort)")
        .accessibilityLabel("Sort Watch Later")
    }

    /// Removing one asks nothing; more than one asks first.
    private func ask(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        if keys.count == 1 { model.removeFromWatchLater(keys) } else { confirmRemove = keys }
    }

    @ViewBuilder private func menu(_ keys: [String], in items: [WatchLaterItem]) -> some View {
        let chosen = items.filter { keys.contains($0.key) }
        if chosen.count == 1, let item = chosen.first {
            Button("Open in YouTube") { model.openInYouTube(item) }.disabled(!model.network.isOnline)
            Button("Open in Background Tab") { model.openInYouTube(item, background: true) }.disabled(!model.network.isOnline)
            if let v = model.store.byKey[item.key] {
                Button("Show in Library") { model.open(v, tab: .video); model.section = .library }
            }
            Button("Copy Link") { FileOps.copy(item.url) }
            Button("Prepare for Offline…") { model.prepareForOffline([(id: item.youtubeID, title: item.title)], from: "Watch Later") }
            Divider()
        } else if chosen.count > 1 {
            Button("Prepare \(chosen.count) for Offline…") { model.prepareForOffline(chosen.map { (id: $0.youtubeID, title: $0.title) }, from: "Watch Later") }
            Button("Open \(chosen.count) in Tabs") { model.openInTabs(chosen) }.disabled(!model.network.isOnline)
            Divider()
        }
        if !chosen.isEmpty {
            Button(chosen.count == 1 ? "Remove from Watch Later" : "Remove \(chosen.count) from Watch Later") { ask(chosen.map(\.key)) }
        }
    }

    /// Two or more selected. (Phase 4's "Prepare Offline" goes here, through the download checks one video at a time.)
    private func selectionBar(_ items: [WatchLaterItem]) -> some View {
        let chosen = items.filter { selection.contains($0.key) }
        return HStack(spacing: 8) {
            Text("\(chosen.count) selected").font(.callout.weight(.semibold))
            Spacer()
            // 4.0 Phase 4: each through the download checks, one video at a time; nothing starts until you queue it
            Button { model.prepareForOffline(chosen.map { (id: $0.youtubeID, title: $0.title) }, from: "Watch Later") } label: {
                Label("Prepare for Offline", systemImage: "arrow.down.circle")
            }
            .buttonStyle(SecondaryButtonStyle(height: 30, font: .callout))
            .testProbe("prepareSelected")
            Button { model.openInTabs(chosen) } label: { Label("Open in Tabs", systemImage: "plus.square.on.square") }
                .buttonStyle(SecondaryButtonStyle(height: 30, font: .callout)).disabled(!model.network.isOnline)
                .help(model.network.isOnline ? "Opens each in a tab behind (asleep until you select it)" : "Needs internet")
                .testProbe("openInTabs")
            Button(role: .destructive) { ask(chosen.map(\.key)) } label: { Label("Remove", systemImage: "trash") }
                .buttonStyle(SecondaryButtonStyle(height: 30, font: .callout))
                .testProbe("removeSelected")
            Button("Done") { selection = [] }.buttonStyle(.link)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(p.border.opacity(0.7)))
    }
}

private struct WatchLaterRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var p
    let item: WatchLaterItem

    var body: some View {
        let a = model.availability(youtubeID: item.youtubeID)
        let title = WatchLater.displayTitle(item, pending: model.lookupPending.contains(item.key) && model.network.isOnline)
        let local = Thumbnails.watchLaterPath(item.youtubeID)
        HStack(alignment: .top, spacing: 10) {
            Thumbnail(url: item.thumbnailURL, localPath: FileManager.default.fileExists(atPath: local) ? local : nil,
                      duration: item.duration, cornerRadius: 6)
                .frame(width: 112, height: 63)
            VStack(alignment: .leading, spacing: 4) {
                Text(title.text).font(.callout.weight(.semibold)).lineLimit(2)
                    .foregroundStyle(title.placeholder ? p.secondary : p.text).italic(title.placeholder)
                // a placeholder title always comes with the video it stands for
                Text(title.placeholder ? "youtube.com/watch?v=\(item.youtubeID)" : details)
                    .font(title.placeholder ? .caption.monospaced() : .caption).foregroundStyle(p.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    ForEach(a.labels(nothing: "Not downloaded").prefix(2), id: \.text) { label($0) }
                }
                primaryButton(a)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        [item.channel, "Added \(item.added.formatted(.relative(presentation: .named)))"].compactMap { $0 }.joined(separator: " · ")
    }

    private func label(_ l: StatusLabel) -> some View {
        Label(l.text, systemImage: l.icon)
            .font(.caption2.weight(.semibold)).foregroundStyle(p.tone(l.tone)).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(p.tone(l.tone).opacity(0.14)))
            .help(l.text)
    }

    @ViewBuilder private func primaryButton(_ a: VideoAvailability) -> some View {
        switch WatchLater.primary(a) {
        case .playVideo:
            Button { model.primaryAction(item) } label: { Label("Play Offline", systemImage: "play.fill") }
                .buttonStyle(PrimaryButtonStyle(height: 28, font: .caption.weight(.semibold)))
        case .playAudio:
            Button { model.primaryAction(item) } label: { Label("Play Audio", systemImage: "headphones") }
                .buttonStyle(SecondaryButtonStyle(height: 28, font: .caption))
        case .openInYouTube:
            Button { model.primaryAction(item) } label: { Label("Open in YouTube", systemImage: "play.tv") }
                .buttonStyle(SecondaryButtonStyle(height: 28, font: .caption))
                .disabled(!model.network.isOnline)
                .help(model.network.isOnline ? "Opens it in a YouTube tab" : "Needs internet")
        }
    }
}
