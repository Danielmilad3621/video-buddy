// Test-only remote control, active only when launched with VS_TEST_HOOKS=1 (and VS_SNAPSHOT_DIR for output).
// It calls the same AppModel methods the buttons call, and dumps state as JSON for the end-to-end checks.
import AppKit
import Foundation
import SwiftUI
import WebKit

/// Test builds only (VS_TEST_HOOKS=1): remembers where a native control is, so `nativeClick <name>` can click it with a
/// real mouse event through its window, the way a person would. Invisible to clicks itself.
struct TestProbe: NSViewRepresentable {
    let name: String
    final class ProbeView: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
    func makeNSView(context: Context) -> NSView { let v = ProbeView(); TestProbes.add(name, v); return v }
    func updateNSView(_ v: NSView, context: Context) { TestProbes.add(name, v) }
}

@MainActor enum TestProbes {
    static let enabled = ProcessInfo.processInfo.environment["VS_TEST_HOOKS"] == "1"
    private final class Weak { weak var view: NSView?; init(_ v: NSView) { view = v } }
    private static var views: [String: [Weak]] = [:]
    static func add(_ name: String, _ v: NSView) {
        var list = (views[name] ?? []).filter { $0.view != nil && $0.view !== v }
        list.append(Weak(v))
        views[name] = list
    }
    /// The on-screen one (ViewThatFits keeps layouts it didn't pick out of the window).
    static func view(_ name: String) -> NSView? {
        views[name]?.compactMap(\.view).last { $0.window != nil && $0.bounds.width > 0 && !$0.isHiddenOrHasHiddenAncestor }
    }
    static var visible: [String] { views.keys.filter { view($0) != nil }.sorted() }
}

extension View {
    @ViewBuilder func testProbe(_ name: String) -> some View {
        if TestProbes.enabled { background(TestProbe(name: name)) } else { self }
    }
}

@MainActor
enum TestHooks {
    static func install() {
        let env = ProcessInfo.processInfo.environment
        guard env["VS_TEST_HOOKS"] == "1", let dir = env["VS_SNAPSHOT_DIR"] else { return }
        // VS_TEST_CHANNEL keeps two test instances apart (each listens only to its own channel)
        let channel = env["VS_TEST_CHANNEL"].map { ".\($0)" } ?? ""
        DistributedNotificationCenter.default().addObserver(forName: .init("local.video-summarizer.test" + channel), object: nil, queue: .main) { note in
            let cmd = note.object as? String ?? ""
            MainActor.assumeIsolated { handle(cmd, dir: dir) }
        }
    }

    private static func handle(_ line: String, dir: String) {
        let model = AppModel.shared, store = model.store
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "link": model.link = arg
        case "start": model.start(JobKind(rawValue: arg) ?? .summary)
        case "cancel": model.jobs.cancel()
        case "select":
            if let v = store.videos.first(where: { $0.displayTitle.localizedCaseInsensitiveContains(arg) }) { model.open(v, tab: model.detailTab) }
        case "favorite": if let v = store.selectedVideo { model.toggleFavorite(v) }
        case "search": store.search = arg
        case "filter": store.filter = HistoryFilter(rawValue: arg) ?? .all
        case "sort": store.sort = HistorySort(rawValue: arg) ?? .recent
        case "section": model.section = AppSection(rawValue: arg) ?? .library
        case "tab": model.detailTab = DetailTab(rawValue: arg) ?? .summary
        case "regenerate":
            let f = arg.split(separator: "|").map(String.init)
            model.regenerate(format: SummaryFormat(rawValue: f.first ?? "") ?? AppSettings.format,
                             language: SummaryLanguage(rawValue: f.count > 1 ? f[1] : "") ?? AppSettings.language)
        case "import": model.runImport(model.importOffer)
        case "declineImport": model.declineImport()
        case "remove": if let v = store.selectedVideo { model.pendingRemoval = v; model.confirmRemoval() }
        case "clearAll": model.clearAll()
        case "reload": Task { await store.reload() }
        case "offline": model.network.forcedOffline = arg == "on"
        case "play": if let v = store.selectedVideo { model.play(v) }
        case "pause": model.playback.pause()
        case "seek": model.playback.seek(to: Double(arg) ?? 0)
        case "seekLine":
            if let v = store.selectedVideo, let segs = store.transcriptJob?.segments, let i = Int(arg), segs.indices.contains(i) {
                model.seek(v, to: segs[i].start)
            }
        case "rate": model.playback.rate = Float(arg) ?? 1
        case "mute": model.playback.muted = arg != "off"
        case "stopPlayer": model.playback.stop()
        case "transcribe": if let v = store.selectedVideo { model.transcribe(v) }
        case "offlineVideo": if let v = store.selectedVideo { model.makeAvailableOffline(v) }
        case "summarizeTranscript": model.regenerate()
        case "pauseQueue": model.jobs.pauseQueue()
        case "resumeQueue": model.jobs.resumeQueue()
        case "clearQueue": model.jobs.clearQueue()
        case "thumbnails": Task { await model.backfillThumbnails() }
        case "playlistPreview":
            if let link = PlaylistLink.parse(arg) { model.readPlaylist(link, kind: .audio) }
        case "playlistImport":
            // "<action>|<how many>|<playlist name or empty>" — picks the shortest available videos, to keep tests quick
            let f = arg.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if let state = model.playlistImport, f.count == 3, let action = JobAction(rawValue: f[0]), let n = Int(f[1]) {
                let picks = state.preview.available.sorted { ($0.duration ?? .infinity) < ($1.duration ?? .infinity) }.prefix(n)
                let ordered = state.preview.entries.filter { e in picks.contains { $0.id == e.id } }
                model.importPlaylist(ordered, all: state.preview.entries, action: action,
                                     into: f[2].nilIfBlank.map { .new($0) }, sourceURL: state.preview.url)
            }
        case "newPlaylist": model.createPlaylist(arg, adding: store.selectedVideo?.id)
        case "addToPlaylist":
            if let pl = store.playlists.first(where: { $0.name == arg }), let v = store.selectedVideo { model.addToPlaylist(pl.id, video: v) }
        case "openPlaylist": store.openPlaylistID = store.playlists.first { $0.name == arg }?.id; model.section = .playlists
        case "movePlaylistItem":
            let f = arg.split(separator: "|").compactMap { Int($0) }
            if f.count == 2 { model.movePlaylistItems(from: IndexSet(integer: f[0]), to: f[1]) }
        case "removeFromPlaylist": if let v = store.selectedVideo { model.removeFromOpenPlaylist(v) }
        case "playAll": model.playAll()
        case "makeAllOffline": model.askDownloadMissing(); model.confirmOfflineBatch()
        case "deletePlaylist":
            if let pl = store.playlists.first(where: { $0.name == arg }) { model.pendingPlaylistDeletion = pl; model.confirmPlaylistDeletion() }
        case "next": model.playback.next()
        case "previous": model.playback.previous()
        case "volume": model.playback.volume = Float(arg) ?? 1
        case "loadDetails": if let v = store.selectedVideo { model.loadDetails(v) }
        case "retryFailed": if let f = store.failed.first { model.retry(f.retry) }
        case "showSteps":
            // test-only: a sample of the 4-stage strip, so its look can be checked without a download or an AI call
            let states: [StepState] = [.done, .running, .pending, .pending]
            model.jobs.steps = ["Download audio", "Transcribe on-device", "Generate AI summary", "Save to library"].enumerated()
                .map { JobStep(id: $0.offset, label: $0.element, state: states[$0.offset]) }
            model.jobs.banner = arg == "off" ? nil : .running("Summarizing (sample)…")
        case "settings": NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        // 3.1: playlists as collections
        case "layout": UserDefaults.standard.set(arg, forKey: "libraryLayout")
        case "expand":
            switch arg {
            case "all": store.expanded = Set(store.playlists.map(\.id))
            case "none": store.expanded = []
            default: if let pl = store.playlists.first(where: { $0.name.contains(arg) }) { store.expanded.insert(pl.id) }
            }
        case "playPlaylist": if let pl = store.playlists.first(where: { $0.name.contains(arg) }) { model.playAll(pl.id) }
        case "continuePlaylist": if let pl = store.playlists.first(where: { $0.name.contains(arg) }) { model.continuePlaylist(pl.id) }
        case "checkPlaylist": if let pl = store.playlists.first(where: { $0.name.contains(arg) }) { model.checkPlaylist(pl) }
        case "linkPlaylist":
            // the sheet's main button in Check mode: nothing ticked, so it only links library videos
            if let state = model.playlistImport, let id = state.checking {
                model.importPlaylist([], all: state.preview.entries, action: .video, into: .existing(id), sourceURL: state.preview.url)
            }
        case "closeSheet": model.playlistImport = nil
        case "downloadMissing": if let pl = store.playlists.first(where: { $0.name.contains(arg) }) { model.askDownloadMissing(pl.id) }
        case "confirmOffline": model.confirmOfflineBatch()
        case "cancelOffline": model.pendingOfflineBatch = nil
        case "selectEpisode":
            // "<playlist name part>|<episode number>"
            let f = arg.split(separator: "|").map(String.init)
            if f.count == 2, let pl = store.playlists.first(where: { $0.name.contains(f[0]) }), let n = Int(f[1]),
               let id = store.members[pl.id].flatMap({ $0.indices.contains(n - 1) ? $0[n - 1] : nil }), let v = store.video(id) {
                model.open(v, tab: model.detailTab)
            }
        // 4.0 Phase 1: the YouTube section. Clicks and keys are real NSEvents sent through the window (the same path as a
        // mouse and keyboard), not JavaScript clicks; webRead runs test-only reads in an isolated script world.
        case "browse": model.section = .youtube; model.browser.go(arg)
        case "back": model.browser.tab?.goBack()
        case "forward": model.browser.tab?.goForward()
        case "pageReload": model.browser.tab?.reload()
        case "webClick":
            let f = arg.split(separator: "|").compactMap { Double($0) }
            if f.count == 2, let web = model.browser.tab?.webView { click(web, at: CGPoint(x: f[0], y: f[1])) }
        case "webClickEl": if let web = model.browser.tab?.webView { clickElement(web, selector: arg) }
        case "webClickElWith":
            // "<c s o m r>|<selector>": a ⌘ (c), ⇧ (s), ⌥ (o) click, a middle (m) or right (r) click on an element
            let f = arg.split(separator: "|", maxSplits: 1).map(String.init)
            if f.count == 2, let web = model.browser.tab?.webView { clickElement(web, selector: f[1], how: f[0]) }
        case "menuItems":
            // the app menu's items under one title: "title [key equivalent + modifier mask]"
            let menu = NSApp.mainMenu?.items.first { $0.title == arg }?.submenu
            webRead = (menu?.items ?? []).map { "\($0.title) [\($0.keyEquivalent.debugDescription) \($0.keyEquivalentModifierMask.rawValue)]" }.joined(separator: "; ")
        case "webKey": if let web = model.browser.tab?.webView { key(web, arg) }
        case "webType": if let web = model.browser.tab?.webView { for c in arg { key(web, String(c)) } }
        case "webRead":
            webRead = "…"
            model.browser.tab?.webView?.evaluateJavaScript(arg, in: nil, in: .world(name: "VBTest")) { result in
                MainActor.assumeIsolated {
                    switch result {
                    case let .success(value): webRead = "\(value)"
                    case let .failure(error): webRead = "error: \(error.localizedDescription)"
                    }
                }
            }
        case "clearBrowsingData": Task { await model.browser.clearBrowsingData() }
        case "menuKey":
            // a shortcut as the keyboard sends it (built from the key code, like hardware events), handled by the app's
            // menu: "<keys>" with ⌘, or "<modifiers>:<keys>" (c ⌘, s ⇧, o ⌥, t ⌃; "tab" for the tab key)
            let f = arg.split(separator: ":", maxSplits: 1).map(String.init)
            let (mods, chars) = f.count == 2 ? (f[0], f[1] == "tab" ? "\t" : f[1]) : ("c", arg)
            var flags: CGEventFlags = []
            if mods.contains("c") { flags.insert(.maskCommand) }
            if mods.contains("s") { flags.insert(.maskShift) }
            if mods.contains("o") { flags.insert(.maskAlternate) }
            if mods.contains("t") { flags.insert(.maskControl) }
            if let cg = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: keyCode(chars), keyDown: true) {
                cg.flags = flags
                let e = NSEvent(cgEvent: cg)
                webRead = "menu handled \(arg) (\(e?.characters ?? "?")/\(e?.charactersIgnoringModifiers ?? "?")): \(e.map { NSApp.mainMenu?.performKeyEquivalent(with: $0) ?? false } ?? false)"
            }
        case "windowKey":
            // a key press sent through the window (the page or a field gets it first, then the menu), "<modifiers>:<keys>"
            let f = arg.split(separator: ":", maxSplits: 1).map(String.init)
            let chars = f.count == 2 ? (f[1] == "tab" ? "\t" : f[1]) : arg
            var flags: NSEvent.ModifierFlags = []
            if f.count == 2, f[0].contains("c") { flags.insert(.command) }
            if f.count == 2, f[0].contains("s") { flags.insert(.shift) }
            if f.count == 2, f[0].contains("t") { flags.insert(.control) }
            if let w = model.browser.tab?.webView?.window ?? NSApp.keyWindow {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                                isARepeat: false, keyCode: keyCode(chars)) { NSApp.sendEvent(e) }
                }
            }
        // 4.0 Phase 2: tabs (numbers are the tab strip's, from 1)
        case "tabNew": model.section = .youtube; model.browser.open(URL(string: arg) ?? BrowserPolicy.home)
        case "tabNewBehind": model.browser.open(URL(string: arg) ?? BrowserPolicy.home, background: true, from: model.browser.tab)
        case "tabSelect": if let t = tab(arg) { model.browser.select(t) }
        case "tabClose": if let t = tab(arg) { model.browser.close(t) }
        case "tabMove":
            let f = arg.split(separator: "|").compactMap { Int($0) }
            if f.count == 2, let t = tab(String(f[0])) { model.browser.move(t, to: f[1] - 1) }
        case "tabDuplicate": if let t = model.browser.tab { model.browser.duplicate(t) }
        case "tabReopen": model.reopenTab()
        // 4.0 Phase 3: Watch Later (the same model calls the buttons make)
        case "wlSave": model.saveToWatchLater(arg, from: model.browser.tabs.first { $0.page.videoID == arg })
        case "wlSaveTab": if let t = tab(arg), let id = t.page.videoID { model.saveToWatchLater(id, from: t) }
        case "wlRemove": model.removeFromWatchLater(arg.split(separator: ",").map { "youtube:\($0)" })
        case "wlOpen":
            let f = arg.split(separator: "|").map(String.init)
            if let item = store.watchLater.first(where: { $0.youtubeID == f.first }) { model.openInYouTube(item, background: f.count > 1) }
        case "wlOpenTabs":
            // "all", or ids separated by commas, in that order
            let ids = arg == "all" ? store.watchLater.map(\.youtubeID) : arg.split(separator: ",").map(String.init)
            model.openInTabs(ids.compactMap { id in store.watchLater.first { $0.youtubeID == id } })
        case "wlPrimary": if let item = store.watchLater.first(where: { $0.youtubeID == arg }) { model.primaryAction(item) }
        case "wlShow": model.showWatchLater(select: arg.isEmpty ? nil : "youtube:\(arg)")
        case "wlCloseReport": model.openReport = nil
        case "fixtureJob":
            // "<youtube id>|summary|failed": a finished job for that video, as if the queue ran (test data only)
            let f = arg.split(separator: "|").map(String.init)
            if f.count == 2, let v = store.all.first(where: { $0.key == "youtube:\(f[0])" }) {
                let now = Date()
                let job = f[1] == "summary"
                    ? NewJob(kind: .summary, status: .succeeded, source: .app, started: now, finished: now,
                             summary: "## TL;DR\nA test summary (synthetic, no AI).", summaryLanguage: "English", summaryFormat: "Standard")
                    : NewJob(kind: .video, status: .failed, source: .app, started: now, finished: now, error: "test: failed on purpose")
                Task {
                    if let id = try? await store.db.startJob(videoID: v.id, kind: job.kind, source: .app) {
                        try? await store.db.finishJob(id, videoID: v.id, job)
                    }
                    await store.reload()
                    webRead = "fixture job \(f[1]) for \(f[0])"
                }
            }
        case "memoryWarning": model.browser.memoryWarning()
        case "cookieNames":
            // the YouTube data store's cookie names and count, never their values (sign-in survives a restart)
            Task {
                let names = await model.browser.cookieNames()
                webRead = "\(names.count) cookies: " + names.joined(separator: " ")
            }
        case "crashTab":
            // what WebKit tells a tab when its page's web process ends (a real crash can't be caused through public API)
            if let t = tab(arg), let web = t.webView { t.webViewWebContentProcessDidTerminate(web) }
        case "pageMedia":
            // "play" / "pause": the active tab's video, muted (test runs stay silent), as a click on the player would
            let js = arg == "play" ? "(() => { const v = document.querySelector('video'); if (!v) return 'no video'; v.muted = true; v.play(); return 'playing'; })()"
                : "(() => { document.querySelectorAll('video').forEach(v => v.pause()); return 'paused'; })()"
            model.browser.tab?.webView?.evaluateJavaScript(js, in: nil, in: .world(name: "VBTest")) { r in
                MainActor.assumeIsolated { webRead = "\((try? r.get()) ?? "error")" }
            }
        case "backgroundAudio": UserDefaults.standard.set(arg == "on", forKey: "browserBackgroundAudio")
        case "pasteText": model.paste(arg)      // what ⌘⇧V does with this text (the real clipboard is left alone)
        case "tabNext": model.browser.selectTab(offset: 1)
        case "tabPrevious": model.browser.selectTab(offset: -1)
        case "captureClick":
            // remembers what a bar button on screen now carries (the tab and its video), for a click delivered later
            captured = model.browser.tab.flatMap { t in t.page.videoID.map { (t.id, $0) } }
            webRead = captured.map { "captured \($0.1)" } ?? "nothing to capture"
        case "deliverSave":
            // a Save to Watch Later click captured earlier (captureClick), delivered now, after the tab may have changed
            if let c = captured { model.saveToWatchLater(c.1, from: model.browser.tabs.first { $0.id == c.0 }) }
        case "deliverClick":
            if let c = captured { model.requestFromBrowser(BarSlot(rawValue: arg) ?? .video, videoID: c.1, tabID: c.0) }
        // 4.0 Phase 1b: the native action bar
        case "nativeClick":
            if let v = TestProbes.view(arg), let w = v.window {
                // a person clicking a window makes it key first; do the same, then click once it is
                w.makeKeyAndOrderFront(nil)
                let wasKey = w.isKeyWindow
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let loc = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
                    let t = ProcessInfo.processInfo.systemUptime
                    for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, 0)] {
                        if let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: t, windowNumber: w.windowNumber,
                                                      context: nil, eventNumber: 0, clickCount: 1, pressure: pressure) { w.sendEvent(e) }
                    }
                    webRead = "native click on \(arg) at \(Int(loc.x)),\(Int(loc.y)); window key before \(wasKey), at click \(w.isKeyWindow)"
                }
            } else {
                webRead = "no visible control \(arg) (visible: \(TestProbes.visible.joined(separator: ", ")))"
            }
        case "nativeType":
            // "<control>|<text>": keys go to that control's window (a sheet is a window of its own), as typing would
            let f = arg.split(separator: "|", maxSplits: 1).map(String.init)
            let target = f.count == 2 ? TestProbes.view(f[0])?.window : NSApp.keyWindow
            let arg = f.count == 2 ? f[1] : arg
            if let w = target {
                w.makeKey()
                for c in arg.map(String.init) {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: w.windowNumber, context: nil, characters: c, charactersIgnoringModifiers: c,
                                                    isARepeat: false, keyCode: 0) { NSApp.sendEvent(e) }
                    }
                }
            }
        case "ownChannels": model.setOwnChannels(arg)
        case "requestVideo": model.requestFromBrowser(.video, videoID: arg, tabID: model.browser.tab?.id)      // a click carrying this id (stale-click test)
        case "declareOnly":
            // "<youtube id>|<reference>": record a written-permission declaration without queueing anything
            let f = arg.split(separator: "|", maxSplits: 1).map(String.init)
            if f.count == 2 {
                let a = DownloadAuthorization(basis: .writtenPermission, reference: f[1], recorded: Date())
                Task { try? await store.db.setAuthorization("youtube:\(f[0])", a); model.authorizations["youtube:\(f[0])"] = a }
            }
        case "recheck": if let id = model.browser.currentVideoID { model.browser.checker.recheck(id) }
        case "fakeRunning":
            // "<youtube id>" pretends that video's download is running; "off" stops pretending
            if arg == "off" { model.jobs.testSetCurrent(nil) }
            else if let v = store.all.first(where: { $0.key == "youtube:\(arg)" }) {
                model.jobs.testSetCurrent(QueueItem(id: -1, videoID: v.id, title: v.displayTitle, action: .video))
            }
        case "loadFixtures": Task { await loadFixtures(arg) }
        case "fixtureComplete": Task { await fixtureComplete(arg) }
        case "focusWindow":
            // brings this test window to the front (only used while nobody is at the keyboard)
            NSApp.activate(ignoringOtherApps: true)
            if let web = model.browser.tab?.webView, let w = web.window { w.makeKeyAndOrderFront(nil); w.makeFirstResponder(web) }
        case "snapshot": Snapshot.save(to: dir)
        case "state": writeState(to: dir)
        default: break
        }
    }

    private static var webRead = ""
    private static var captured: (UUID, String)?

    /// The US keyboard's key code for a character (what a real key press carries).
    private static func keyCode(_ c: String) -> UInt16 {
        let codes: [String: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
                                       "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
                                       "9": 25, "7": 26, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "\r": 36,
                                       "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "\t": 48, " ": 49]
        return codes[c.lowercased()] ?? 0
    }

    /// A tab by its number in the strip (from 1).
    private static func tab(_ n: String) -> BrowserTab? {
        let tabs = AppModel.shared.browser.tabs
        return Int(n).flatMap { tabs.indices.contains($0 - 1) ? tabs[$0 - 1] : nil }
    }

    /// "<sample dir>|<download dir>": library records for real public YouTube ids, with synthetic media (a 14 s clip made
    /// with `say` + ffmpeg), covering every state the action bar has. Only ever used on a throwaway database.
    private static func loadFixtures(_ arg: String) async {
        let f = arg.split(separator: "|").map(String.init)
        guard f.count == 2 else { return }
        let (samples, dl) = (URL(fileURLWithPath: f[0]), URL(fileURLWithPath: f[1]))
        let db = AppModel.shared.store.db
        func copy(_ sample: String, _ name: String) -> String {
            let to = dl.appendingPathComponent(name)
            try? FileManager.default.copyItem(at: samples.appendingPathComponent(sample), to: to)
            return to.path
        }
        func record(_ id: String, _ title: String, _ job: NewJob) async {
            _ = try? await db.recordCompleted(key: "youtube:\(id)", url: BrowserPolicy.watchURL(id), platform: "YouTube",
                                              info: VideoInfo(title: title, channel: "Fixture", thumbnail: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg"),
                                              job: job)
        }
        let at = Date()
        await record("jNQXAC9IVRw", "Me at the zoo [fixture: video on this Mac]",
                     NewJob(kind: .video, status: .succeeded, source: .app, started: at, finished: at, filePath: copy("sample.mp4", "fixture zoo.mp4")))
        await record("aqz-KE-bpKQ", "Big Buck Bunny [fixture: audio only]",
                     NewJob(kind: .audio, status: .succeeded, source: .app, started: at, finished: at, filePath: copy("sample.mp3", "fixture bunny.mp3")))
        await record("Y-rmzh0PI3c", "Cosmos Laundromat [fixture: audio + summary]",
                     NewJob(kind: .summary, status: .succeeded, source: .app, started: at, finished: at, filePath: copy("sample.mp3", "fixture cosmos.mp3"),
                            summary: "## TL;DR\nA fixture summary (synthetic, no AI).", summaryLanguage: "English", summaryFormat: "Standard"))
        await record("QjMwIk6Crbc", "Series episode 3 [fixture: download failed]",
                     NewJob(kind: .video, status: .failed, source: .app, started: at, finished: at, error: "fixture: failed on purpose"))
        await record("LfZN2aRupl8", "Series episode 4 [fixture: file missing]",
                     NewJob(kind: .video, status: .succeeded, source: .app, started: at, finished: at,
                            filePath: dl.appendingPathComponent("fixture missing.mp4").path))
        await record("ih7q2SE5M18", "Cat water moments [fixture: Short on this Mac]",
                     NewJob(kind: .video, status: .succeeded, source: .app, started: at, finished: at, filePath: copy("sample.mp4", "fixture short.mp4")))
        _ = try? await db.enqueue(VideoRef.parse(BrowserPolicy.watchURL("M7E_tARS0hs"))!, action: .video)   // queued (the queue is paused)
        _ = try? await db.applyInfo(try await db.videos().first { $0.key == "youtube:M7E_tARS0hs" }?.id ?? 0,
                                    VideoInfo(title: "Series episode 2 [fixture: queued]"), override: true)
        await AppModel.shared.store.reload()
        await AppModel.shared.jobs.refreshQueue()
        webRead = "fixtures loaded"
    }

    /// "<youtube id>|<sample dir>|<download dir>": that video's download finished (a sample clip appears), as if the queue ran.
    private static func fixtureComplete(_ arg: String) async {
        let f = arg.split(separator: "|").map(String.init)
        guard f.count == 3 else { return }
        let to = URL(fileURLWithPath: f[2]).appendingPathComponent("fixture completed \(f[0]).mp4")
        try? FileManager.default.copyItem(at: URL(fileURLWithPath: f[1]).appendingPathComponent("sample.mp4"), to: to)
        let now = Date()
        _ = try? await AppModel.shared.store.db.recordCompleted(key: "youtube:\(f[0])", url: BrowserPolicy.watchURL(f[0]), platform: "YouTube",
                                                                 info: nil, job: NewJob(kind: .video, status: .succeeded, source: .app,
                                                                                        started: now, finished: now, filePath: to.path))
        await AppModel.shared.store.reload()
        webRead = "completed \(f[0])"
    }

    /// A click at a point of the page (points, top-left origin), as the window would deliver it. `how`: "c" ⌘, "s" ⇧,
    /// "o" ⌥, "m" the middle button, "r" the right button.
    private static func click(_ web: WKWebView, at p: CGPoint, how: String = "") {
        guard let window = web.window else { return }
        let local = web.isFlipped ? p : CGPoint(x: p.x, y: web.bounds.height - p.y)
        let loc = web.convert(local, to: nil)
        let t = ProcessInfo.processInfo.systemUptime
        var flags: NSEvent.ModifierFlags = []
        if how.contains("c") { flags.insert(.command) }
        if how.contains("s") { flags.insert(.shift) }
        if how.contains("o") { flags.insert(.option) }
        let (down, up): (NSEvent.EventType, NSEvent.EventType) = how.contains("m") ? (.otherMouseDown, .otherMouseUp)
            : how.contains("r") ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        for (type, pressure) in [(down, Float(1)), (up, 0)] {
            if how.contains("m") {
                // a real middle-button event (NSEvent's own constructor can't set the button)
                let screen = window.convertPoint(toScreen: loc)
                let flipped = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
                if let cg = CGEvent(mouseEventSource: nil, mouseType: type == down ? .otherMouseDown : .otherMouseUp,
                                    mouseCursorPosition: flipped, mouseButton: .center),
                   let e = { () -> NSEvent? in
                       cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                       cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
                       return NSEvent(cgEvent: cg)
                   }() { window.sendEvent(e) }
            } else if let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: flags, timestamp: t, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: pressure) {
                window.sendEvent(e)
            }
        }
    }

    /// Finds an element's centre with a test-only read, then clicks there with a real mouse event.
    private static func clickElement(_ web: WKWebView, selector: String, how: String = "") {
        let literal = (try? String(data: JSONEncoder().encode(selector), encoding: .utf8)) ?? "\"\""
        let js = "(() => { const e = document.querySelector(\(literal)); if (!e) return null; e.scrollIntoView({block: 'center'}); " +
                 "const r = e.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()"
        web.evaluateJavaScript(js, in: nil, in: .world(name: "VBTest")) { result in
            MainActor.assumeIsolated {
                guard case let .success(value) = result, let xy = value as? [Double], xy.count == 2 else {
                    webRead = "no element for \(selector)"
                    return
                }
                webRead = "clicked \(selector) at \(Int(xy[0])),\(Int(xy[1]))"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { click(web, at: CGPoint(x: xy[0], y: xy[1]), how: how) }
            }
        }
    }

    /// A key press (a character, or return/tab/escape/space/left/right/up/down) sent to the page.
    private static func key(_ web: WKWebView, _ name: String) {
        guard let window = web.window else { return }
        if window.firstResponder !== web, !(window.firstResponder is NSView && (window.firstResponder as? NSView)?.isDescendant(of: web) == true) {
            window.makeFirstResponder(web)
        }
        let named: [String: (String, UInt16)] = ["return": ("\r", 36), "tab": ("\t", 48), "escape": ("\u{1b}", 53), "space": (" ", 49),
                                                 "left": ("\u{F702}", 123), "right": ("\u{F703}", 124), "up": ("\u{F700}", 126), "down": ("\u{F701}", 125)]
        let codes: [Character: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
                                          "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
                                          "k": 40, "n": 45, "m": 46, " ": 49]
        let (chars, code) = named[name] ?? (name, name.first.flatMap { codes[Character($0.lowercased())] } ?? 0)
        let t = ProcessInfo.processInfo.systemUptime
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: t, windowNumber: window.windowNumber,
                                        context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                window.sendEvent(e)
            }
        }
    }

    private static func writeState(to dir: String) {
        let model = AppModel.shared, store = model.store, jobs = model.jobs
        let selected = store.selectedVideo
        var banner: [String: String] = [:]
        switch jobs.banner {
        case let .running(t)?: banner = ["kind": "running", "title": t]
        case let .success(t, s, f)?: banner = ["kind": "success", "title": t, "subtitle": s, "file": f ?? ""]
        case let .failure(t, d, _)?: banner = ["kind": "failure", "title": t, "detail": String(d.suffix(600))]
        case .cancelled?: banner = ["kind": "cancelled"]
        case nil: break
        }
        let state: [String: Any] = [
            "section": model.section.rawValue, "filter": store.filter.rawValue, "sort": store.sort.rawValue, "search": store.search,
            "tab": model.detailTab.rawValue, "isRunning": jobs.isRunning, "notice": model.notice ?? "",
            "importOffer": model.importOffer?.count ?? -1, "importStatus": model.importStatus ?? "",
            "visible": store.videos.map { ["title": $0.displayTitle, "favorite": $0.favorite, "summary": $0.hasSummary,
                                           "audio": $0.hasAudio, "video": $0.hasVideo, "status": $0.latestStatus?.rawValue ?? ""] },
            "selected": selected.map { ["title": $0.displayTitle, "channel": $0.displayChannel, "favorite": $0.favorite,
                                        "duration": $0.duration ?? -1, "upload": $0.uploadDate ?? "", "url": $0.url ?? "",
                                        "platform": $0.platform ?? "", "language": $0.language ?? ""] } ?? [:],
            "selectedJobs": store.selectedJobs.map { ["kind": $0.kind.rawValue, "status": $0.status.rawValue, "format": $0.summaryFormat ?? "",
                                                      "language": $0.summaryLanguage ?? "", "summaryChars": $0.summary?.count ?? 0,
                                                      "segments": $0.segments.count, "file": $0.filePath ?? ""] },
            "files": store.selectedID.map { id in store.files(for: id).map { ["name": $0.name, "role": $0.role.rawValue, "exists": $0.exists] } } ?? [],
            "steps": jobs.steps.map { "\($0.label)=\($0.state)" },
            "banner": banner,
            "stats": ["videos": store.stats.videos, "watch": store.stats.watchSeconds, "summaries": store.stats.summaries, "downloads": store.stats.downloads],
            "existingMedia": selected.flatMap { model.existingMedia($0)?.name } ?? "",
            "lastError": store.lastError ?? "",
            "isOnline": model.network.isOnline,
            "playlists": store.playlists.map { "\($0.name) (\($0.count))" },
            "openPlaylist": store.playlistVideos.map(\.displayTitle),
            "upNext": model.playback.upNext.count,
            "played": model.playback.played.count,
            "bar": { () -> [String: Any] in
                guard let id = model.browser.currentVideoID else { return ["video": "none"] }
                let a = model.availability(youtubeID: id)
                return ["id": id, "video": "\(model.slotState(.video, id))", "audio": "\(model.slotState(.audio, id))",
                        "summary": "\(model.slotState(.summary, id))", "gate": model.browserGate(id).map { "\($0)" } ?? "checking",
                        "check": model.browser.checker.results[id].map { "\($0)" } ?? "none", "checking": model.browser.checker.running ?? "",
                        "videoFile": a.videoFile ?? "", "audioFile": a.audioFile ?? "", "videoMissing": a.videoMissing,
                        "jobs": "video \(a.video) audio \(a.audio) summary \(a.summary)", "summarized": a.summarized,
                        "declaration": model.declaration.map { "\($0.slot.rawValue) for \($0.videoID)" } ?? "",
                        "probes": TestProbes.visible] as [String: Any]
            }(),
            "tabs": model.browser.tabs.enumerated().map { i, t in
                ["n": i + 1, "url": t.url?.absoluteString ?? "", "title": t.title, "page": t.page.label, "videoID": t.page.videoID ?? "",
                 "active": t.id == model.browser.activeID, "asleep": t.isAsleep, "media": t.media, "audioTab": t.id == model.browser.audioTabID,
                 "loadError": t.loadError ?? "",
                 "opener": t.openerID.flatMap { id in model.browser.tabs.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0] as [String: Any]
            },
            "watchLater": store.watchLater.map { i in
                let a = model.availability(youtubeID: i.youtubeID)
                return ["id": i.youtubeID, "title": i.title ?? "", "shown": WatchLater.displayTitle(i, pending: model.lookupPending.contains(i.key) && model.network.isOnline).text,
                        "channel": i.channel ?? "", "duration": i.duration ?? -1, "url": i.url, "thumbnailURL": i.thumbnailURL ?? "",
                        "thumbFile": FileManager.default.fileExists(atPath: Thumbnails.watchLaterPath(i.youtubeID)),
                        "status": a.labels(nothing: "Not downloaded").map(\.text), "primary": "\(WatchLater.primary(a))",
                        "pending": model.lookupPending.contains(i.key)] as [String: Any]
            },
            "watchLaterThumbFiles": ((try? FileManager.default.contentsOfDirectory(atPath: Thumbnails.watchLaterDirectory.path)) ?? []).sorted(),
            "openReport": model.openReport ?? "",
            "watchedFolders": store.watchedFolders,
            "onMacCount": store.onMacIDs.count, "reloads": store.reloads,
            "closedTabs": model.browser.closed.count,
            "contextMenu": TabWebView.lastMenu,
            "liveTabs": model.browser.tabs.filter { !$0.isAsleep }.count,
            "declarationTitle": model.declaration?.title ?? "",
            "playlistSheet": model.playlistImport.map { ["linkOnly": $0.linkOnly, "entries": $0.preview.entries.count] as [String: Any] } ?? [:],
            "browser": { () -> [String: Any] in
                let b = model.browser
                guard let t = b.tab else { return ["tab": "none", "storeID": b.existingStoreID ?? "", "clearReport": b.clearReport ?? ""] }
                return ["url": t.url?.absoluteString ?? "", "title": t.title, "loading": t.isLoading, "progress": t.progress,
                        "back": t.canGoBack, "forward": t.canGoForward, "page": t.page.label, "videoID": t.page.videoID ?? "",
                        "fullscreen": t.isFullscreen, "media": b.mediaState, "webkitMedia": b.webkitMediaState, "loadError": t.loadError ?? "",
                        "log": Array(t.log.suffix(30)), "external": t.externalOpens, "webRead": webRead,
                        "storeID": b.existingStoreID ?? "", "clearReport": b.clearReport ?? "",
                        "webSuperview": t.webView?.superview.map { "\(type(of: $0)) \(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "none",
                        "webInWindow": t.webView?.window != nil,
                        "appActive": NSApp.isActive, "windowKey": t.webView?.window?.isKeyWindow ?? false,
                        "webIsFirstResponder": t.webView.map { w in w.window?.firstResponder === w || (w.window?.firstResponder as? NSView)?.isDescendant(of: w) == true } ?? false
                       ] as [String: Any]
            }(),
            "layout": UserDefaults.standard.string(forKey: "libraryLayout") ?? "Grouped",
            "groups": { () -> [[String: Any]] in
                let g = Grouping.make(store.videos, playlists: store.playlists, members: store.members)
                return g.groups.map { grp in
                    let id = grp.playlist.id
                    return ["name": grp.playlist.name, "members": store.members[id]?.count ?? 0, "shown": grp.videos.count,
                            "offline": store.offlineCount(id), "audioOnly": store.audioOnlyCount(id),
                            "expanded": store.expanded.contains(id), "first": grp.videos.first?.displayTitle ?? "",
                            "episodes": grp.videos.map { store.episode($0.id, in: id) ?? 0 },
                            "resume": store.resumeTarget(id).flatMap { store.episode($0, in: id) } ?? 0] as [String: Any]
                } + [["name": "Individual Videos", "titles": g.individual.map(\.displayTitle)]]
            }(),
            "watch": selected.flatMap { store.watch[$0.id] }.map { "\($0.state)" } ?? "none",
            "videoOnMac": store.videoOnMacIDs.count,
            "offlineBatch": model.pendingOfflineBatch?.videoIDs.count ?? -1,
            "previewChecking": model.playlistImport?.checking ?? -1,
            "context": model.playback.context.map { ["name": $0.name, "count": $0.count,
                                                     "episode": model.playback.currentVideoID.flatMap { store.episode($0, in: model.playback.context!.id) } ?? 0] as [String: Any] } ?? [:],
            "preview": model.playlistImport.map { ["title": $0.preview.title, "count": $0.preview.entries.count,
                                                   "available": $0.preview.available.count,
                                                   "entries": $0.preview.entries.prefix(8).map { "\($0.title) [\(Fmt.duration($0.duration) ?? "?")]" }] as [String: Any] } ?? [:],
            "queuePaused": jobs.paused,
            "failed": store.failed.map { "\($0.job.action.rawValue): \($0.title)" },
            "continueWatching": store.continueWatching.map { "\($0.video.displayTitle) \(Int($0.progress * 100))%" },
            "description": selected?.description ?? "",
            "tags": selected?.tags ?? [],
            "queueBadge": jobs.queue.count + (jobs.current == nil ? 0 : 1),
            "current": jobs.current.map { "\($0.action.rawValue): \($0.title)" } ?? "",
            "queue": jobs.queue.map { "\($0.action.rawValue): \($0.title)" },
            // which videos are queued, by their YouTube id (the wrong-tab checks compare these exactly)
            "queueKeys": jobs.queue.map { q in "\(q.action.rawValue) \(store.video(q.videoID)?.key ?? "?")" },
            "onMac": store.videos.filter { store.onMacIDs.contains($0.id) }.map(\.displayTitle),
            "thumbnailPath": selected?.thumbnailPath ?? "",
            "playback": ["path": model.playback.currentPath ?? "", "time": model.playback.currentTime,
                         "duration": model.playback.duration, "playing": model.playback.isPlaying, "rate": model.playback.rate,
                         "volume": model.playback.volume, "hasPrevious": model.playback.hasPrevious,
                         "line": (model.playback.currentVideoID == selected?.id ? store.transcriptJob?.segments.index(at: model.playback.currentTime) : nil) ?? -1],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("state.json"))
        }
    }
}
